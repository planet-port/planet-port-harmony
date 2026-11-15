// CoreBridge — ZeroTier C API 的 C++ 包装（A2 Task 6 完整版）。
//
// 行为规格直译自 Android NodeRuntime.kt（388 行），接口形态参考 iOS ZTBridge.mm；
// C API 事实源为 Core/include/ZeroTierOne.h（Core/ 零补丁红线：只经官方 C API 交互）。
//
// 职责：节点生命周期（start/shutdown + 后台驱动线程）、dataStore 状态读写
// （planet 重定向 + 身份按行星分流）、控制面（join/leave/orbit/multicast）、
// 数据面入口（UDP 收包 / TUN 帧上行）与回调投递。回调对齐 Kotlin Channel
// 投递语义：hook 在 ZT 核心线程同步调用，实现方只做投递/入队，禁止阻塞——
// ARP/帧转换等重处理由消费侧（FrameConverter/Dataplane）在自己线程做。
//
// 红线（A2 挂账 #3）：回调路径禁止 static/thread_local 缓冲复用——每次回调
// 自持缓冲（栈上对象/值语义），多 NAPI worker 线程 + 扩展进程并发安全。
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace pp {

// ZeroTier 核心版本号（ZT_version），如 "1.16.2"。与 CoreBridge::version() 同源。
const char *coreVersion();

// host 冒烟专用：生成节点身份到 homeDir（已存在则复用——身份持久化经状态回调
// 落盘 homeDir/identity.secret，0600；A1 阶段"仅存内存"的限制已由 A2 完整版解除）。
// 返回 10 位节点地址（小写十六进制字符串，对齐核心 Address::toString 规范形式）；
// 失败返回空串。内部即一个最小 Hooks 的 CoreBridge 实例。
const char *smokeIdentityGen(const char *homeDir);

// 网络配置快照（字段契约对齐 NodeRuntime.NetConf / iOS ZTNetworkConfigData；
// status 存原始码，type 为枚举名）
struct NetConf {
    uint64_t nwid = 0;
    std::string name;
    int status = -1; // ZT_VirtualNetworkStatus 原始码（0=REQUESTING_CONFIGURATION 1=OK ...）
    std::string type; // "PRIVATE"/"PUBLIC"（ZT_VirtualNetworkType 去 NETWORK_TYPE_ 前缀；未知为空串）
    uint64_t mac = 0;
    int mtu = 0;
    bool broadcastEnabled = false;
    bool bridge = false;
    bool dhcp = false;
    std::vector<std::string> assignedAddrs; // "ip/prefix"（prefix 在 C API 是 sockaddr 的 port 字段）
    std::vector<std::string> routes;        // "dest/prefix" 或 "dest/prefix via gw"（via family=0 即无网关）
    std::vector<std::string> dns;           // DNS server IP（不含端口）
};

// Peer 快照条目（对齐 NodeRuntime.peersNow）
struct PeerInfo {
    uint64_t address = 0;
    std::string version; // "v<major>.<minor>.<rev>"；版本未知时为 "v-1.-1.-1"（对齐 Kotlin/iOS：语义为「版本未知」）
    int latency = -1;
    std::string role; // "LEAF"/"MOON"/"PLANET"（ZT_PeerRole 去 PEER_ROLE_ 前缀；未知为空串）
};

// 物理端点（UDP 收包/发包）。ip 为纯地址文本：v4 点分十进制 / v6 冒号形式（不含方括号）
struct WireEndpoint {
    std::string ip;
    uint16_t port = 0;
};

// stateFile 纯映射（NodeRuntime.stateFile 分流直译）。返回 nullopt = 未知状态对象
// （stateGet 按不存在返回 -1，statePut 忽略）。公开为纯函数便于单测——头文件不可引
// gtest_prod（OHOS NAPI 构建无 gtest），私有成员无法被 gtest 直测。
std::optional<std::string> stateFilePathFor(const std::string &dataStoreRoot, const std::string &planetDir,
                                            const std::string &planetFile, bool identityPerPlanet,
                                            const std::string &name);

// 原子写文件（NodeRuntime.DataStorePutListener 直译）：path.tmp 写入 → rename；写失败
// 或 rename 失败都删 tmp 返回（不残留 .tmp——半文件会让下次启动解析失败）。secure=true
// 时收紧 0600，且先 chmod tmp 再 rename，避免目标文件以默认权限短暂可见（比 Kotlin
// rename 后逐次收紧多一道无窗口保障）。父目录不存在时逐级创建。公开为纯函数便于单测。
void putFileAtomic(const std::string &path, const uint8_t *data, size_t len, bool secure);

class CoreBridge {
public:
    // 回调注入。调用方在 start() 前填好（start 后再改由调用方自行保证与核心线程互斥）。
    // 全部 hook 在 ZT 核心线程同步调用：实现必须只做投递/入队，禁止阻塞或重处理。
    struct Hooks {
        // 虚网帧上行（核心 → TUN）。frame 指针仅在回调期内有效（同步投递语义）。
        std::function<void(uint64_t nwid, uint64_t srcMac, uint64_t dstMac, uint16_t etherType,
                           uint16_t vlanId, const uint8_t *frame, size_t len)> onFrame;
        // netconf 更新。CoreBridge 只投递 UP(1)/CONFIG_UPDATE(2)——端口首份完整 netconf
        // 以 UP 回调，仅认 CONFIG_UPDATE 会漏首网络；DOWN(3)/DESTROY(4) 的快照可能仍带
        // 旧地址，误存会把已离开网络的残留配置塞回快照（对齐 TunnelManager 拒收），
        // 改经 onEvent(-op) 上报事件。
        std::function<void(uint64_t nwid, int op, const NetConf &)> onNetConf;
        // 事件值域：≥0 为原生 ZT_Event 原始值；-3/-4 = 网络 DOWN/DESTROY（快照不投递）；
        // ≤-100 = 驱动循环异常退出，取 -(ZT_ResultCode)（对齐 NodeRuntime 驱动失败上报，
        // 静默退出会把状态悬在假在线）。负值与 ZT_Event 0..7 不冲突。
        std::function<void(int event)> onEvent;
        // 预留：ZT C API 无 peers 推送回调，CoreBridge 自身不触发；
        // 供上层 peersNow() 拉取后自行批量投递。
        std::function<void(const PeerInfo *, size_t)> onPeers;
        // 物理发包出口（UDP socket 由上层持有）；返回 0 成功 / 非 0 失败（核心按错误码计）。
        std::function<int(const uint8_t *data, size_t len, const WireEndpoint &)> sendPacket;
    };

    Hooks hooks;

    // planetFile 空串 = 未自定义 planet（读 dataStoreRoot/planet，仍缺失时核心用内置 planet）。
    // identityPerPlanet 为构造时快照（对齐 NodeRuntime：回调线程只读快照，不查运行时配置；
    // 模式切换经整体重启——重新装配本实例——生效）。
    CoreBridge(std::string dataStoreRoot, std::string planetDir,
               std::string planetFile /*可空*/, bool identityPerPlanet);
    ~CoreBridge(); // 隐式停机兜底：析构即 shutdown（驱动线程必须先于节点对象消亡）
    CoreBridge(const CoreBridge &) = delete;
    CoreBridge &operator=(const CoreBridge &) = delete;

    // @Synchronized 语义（对齐 NodeRuntime.start）：ZT_Node_new → 立即驱动一次
    // processBackgroundTasks（身份生成/装载在此发生）→ 起驱动线程。
    // 已启动时再次调用返回 false；失败时无残留（核心对象已回收）。
    bool start();
    // 先停驱动线程（join）再 ZT_Node_delete（防 UAF：核心契约禁止 processXXX 在飞时
    // delete）。全程以节点大锁串行化；可重复调用（幂等）。自驱动线程的 hook 内
    // 同步调用（如 onEvent 收到致命错误后走停机链）时只置停机标志并立即返回——
    // 不 join（join 自己必抛 system_error）也不删节点，完整停机由真实停机线程
    // 或析构兜底完成。
    void shutdown();

    // 控制面（等价 NodeRuntime 同名方法；节点未启动时全部 no-op）
    void join(uint64_t nwid);
    void leave(uint64_t nwid);
    void orbit(uint64_t moonWorldId, uint64_t seed);
    void deorbit(uint64_t moonWorldId);
    void multicastSubscribe(uint64_t nwid, uint64_t multicastGroup, uint64_t multicastAdi);

    // 节点 40 位地址（10 位 hex 的整数值源）；未启动返回 nullopt
    std::optional<uint64_t> address();

    // ZeroTier 核心版本号，如 "1.16.2"（内容恒定的静态串，线程安全）
    static const char *version();

    // 数据面入口：UDP 收包（UdpCom 收包线程调用）。端点解析失败或未启动返回 false。
    bool processWirePacket(const uint8_t *data, size_t len, const WireEndpoint &endpoint);
    // TUN 帧上行（Dataplane 读线程经 FrameConverter 调用；未启动 no-op）
    void processVirtualNetworkFrame(uint64_t nwid, uint64_t srcMac, uint64_t dstMac,
                                    uint16_t etherType, uint16_t vlanId, const uint8_t *frame, size_t len);

    // 当前网络配置快照（applyConfig 热重配路径用，对齐 iOS bridge.networkConfig）；
    // 未加入该网络 / 未启动返回 nullopt
    std::optional<NetConf> networkConf(uint64_t nwid);
    // 当前 peer 快照；未启动返回空列表（对齐 NodeRuntime.peersNow）
    std::vector<PeerInfo> peersNow();

private:
    // ZT_Node* 与驱动线程藏在 Impl（头文件不引 ZeroTierOne.h）。C 回调以
    // captureless lambda（可转函数指针）注册在 Impl::createNode 内——lambda 体
    // 继承所在成员函数的访问权，免把 C 类型泄漏进头文件。
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace pp
