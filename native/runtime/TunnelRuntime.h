// TunnelRuntime.h — 隧道编排状态机（A3 计划 Task 8）
//
// 直译源：tunnel/TunnelManager.kt（429 行）+ tunnel/NodeRuntime.kt（388 行，装配/
// 事件映射半区）+ tunnel/TunnelStateBus.kt（状态镜像与 40 条滚动日志）。
// Android 三者的分工在此收敛为一个类：CoreBridge（NodeRuntime 的 C API 包装，A2）、
// UdpCom/Dataplane/FrameConverter（A2 数据面）已各自成类，本类只做编排——
// 装配顺序、netconf 聚合、冲突排除、establish 幂等签名、热重配增量、错误路径、
// 快照 JSON（TunnelContract.ets 契约）。
//
// 线程模型（对齐 Kotlin Channel 投递语义）：
//   - CoreBridge 的回调（onFrame/onNetConf/onEvent/sendPacket）跑在 ZT 核心线程，
//     实现只做深拷贝入队，禁止阻塞（A2 红线：回调路径禁 static 缓冲复用）；
//   - 单 worker 线程（zt-rt-worker）消费队列：netconf 快照登记 → 聚合 → 回调。
//     Kotlin 的 300ms 去抖在此以「连续事件排空后聚合一次」等义实现（一处聚合
//     每突发，效果同 debounce 合并，host 时序确定性更好）；
//   - 单 timer 线程（zt-rt-timer）：45s 闲置保活广播 + 5s Peer 快照轮询（存活
//     三态即轮询——F3 放宽，Starting 期不再零轮询），对齐 peersJob 语义；
//   - Hooks 一律在 m_lock 外触发（回调内可安全回入 swapFd/applyConfig 等入口）；
//   - 析构先 stop()（join worker → 收口 dp/udp/core，防 UAF）。
//
// 与 brief 接口稿的差异（见 task-8 报告申报）：
//   ① state() 改为按值返回（m_state 受 m_lock 保护，引用返回对并发读者是数据竞
//      争——Kotlin StateFlow 读即快照语义，按值是安全直译）；
//   ② m_nets 不落地：网络隔离状态已由 FrameConverter 内部 NetworkContext 承载
//      （A2 单一事实源），本类经 updateNetworkInfo/retainOnly 驱动，不再复制一份。
#pragma once

#include "bridge/CoreBridge.h"
#include "dataplane/Dataplane.h"
#include "dataplane/FrameConverter.h"
#include "dataplane/UdpCom.h"

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace pp {

// 启动配置（ArkTS 从 store 读出后经 JSON 传入；字段名 = NAPI JSON 契约）
struct TunnelConfig {
    std::string dataStoreRoot; // filesDir/zt
    std::string planetDir;     // planetStateDir(activePlanetId)（含 planet 文件根语义）
    std::string planetFile;    // planets/<uuid>.planet 全路径；空 = 官方
    bool identityPerPlanet = false;
    bool disableIpv6 = false;
    struct Net {
        uint64_t nwid = 0;
        bool routeViaZeroTier = false;
    };
    std::vector<Net> networks; // 激活网络（按激活序）
    struct Moon {
        uint64_t worldId = 0;
        uint64_t seed = 0;
    };
    std::vector<Moon> moons;
};

// 聚合结果 → 壳组装 VpnConfig（D8：v4/v6 聚合单 VpnConfig、MTU clamp 1500）
struct EstablishRequest {
    std::vector<std::string> v4Addrs; // "ip/prefix"
    std::vector<std::string> v6Addrs;
    std::vector<std::string> routes4; // "dest/prefix"（LPM 聚合后；A3 无网关表达——Expand 差集输出无 via）
    std::vector<std::string> routes6;
    std::vector<std::string> dns; // DnsMode=custom 的并集（A3 TunnelConfig 未携带每网络 DNS 模式，恒空——契约缺口，Task 9/10 扩展）
    int mtu = 28000;              // 网络声明值取最小（调用方 clamp [576,1500]）
};

// 状态快照（snapshotJson 的内存形态；JSON 序列化在 .cpp）
struct RuntimeState {
    // kind: idle|starting|running|reconnecting|stopped|failed（对齐 TunnelContract）
    std::string kind = "idle";
    std::string reason;       // reconnecting: network_change；failed: 错误码
    bool recoverable = false; // failed 专用
    bool online = false;
    std::string nodeId;     // 10 位 hex；空 = 未上线
    std::string coreVersion; // 停机不清（TunnelStateBus 缓存语义）
    std::map<uint64_t, int> networkStatuses;          // nwid → ZT status 原始码
    std::map<uint64_t, std::string> networkConflicts; // nwid → "address"|"subnet"
    std::map<uint64_t, NetConf> networkConfigs;
    std::vector<PeerInfo> peers;
    std::string applyTrace;
    std::vector<std::string> eventLog; // 滚动 40 条（带时间戳，TunnelStateBus.log 同源）
};

class TunnelRuntime {
public:
    // 回调全部在 runtime 内部线程触发——实现只做投递/建 VPN 等自身事务；回调内
    // 禁止回入 start/stop/restartCore（restartCore 会 join 触发它的 worker 线程，
    // 回调内回入即自等待死锁）。全部可空：未注入时对应路径静默跳过（protect 缺省
    // 放行 true——host/早期壳无 protect 通道）。
    struct Hooks {
        // 聚合就绪需要建/换 TUN（D3）：壳组 VpnConfig → create() → swapFd(fd)。
        // 第一次 = establish；后续 = 换代（旧 fd 由 runtime close）
        std::function<void(const EstablishRequest &)> onEstablish;
        // 全部网络失效：壳 destroy VPN（路由自动撤销），runtime 实例保持可用
        std::function<void()> onTeardown;
        // 状态/快照已变化（壳择机调 snapshotJson 落盘 + 发 commonEvent）
        std::function<void()> onStateChanged;
        // 物理发包出口（UdpCom 直接桥接）：缺省时 runtime 直连 m_udp->send（Kotlin
        // PacketSender=UdpCom 同构）；注入时以注入为准（NAPI/host 测试捕获用）
        std::function<int(const uint8_t *, size_t, const WireEndpoint &)> sendPacket;
        // protect 钩子（UdpCom start 注入；D4/D14——NAPI tsfn 回调 ArkTS）；缺省放行
        std::function<bool(int fd)> protect;
    };

    Hooks hooks;

    TunnelRuntime();
    ~TunnelRuntime(); // stop() 兜底（先 join worker/timer，再收口 dp/udp/core）
    TunnelRuntime(const TunnelRuntime &) = delete;
    TunnelRuntime &operator=(const TunnelRuntime &) = delete;

    // 装配：CoreBridge 构造（身份 seed 由壳层在 start 前完成）→ hooks 装配 →
    // core.start() → worker/timer 线程 → UdpCom.start（protect 注入）→ 首启
    // join/orbit（tm.applyConfig 直译）→ Starting 态。
    // 幂等：存活态（running/starting/reconnecting）返回 false；装配失败返回 false
    // 且置 Failed 终态（原因码见 state().reason——调用方以快照为准）。
    bool start(const TunnelConfig &cfg);

    // 幂等停机：join worker → dp.shutdown → udp.shutdown → core.shutdown →
    // 置 Stopped 终态（statuses/configs/conflicts/peers 清空，nodeId 清空，
    // coreVersion 留存，pathSatisfied 复位 true——stopTunnel 直译）。
    void stop();

    // D3/D9：进程内换代（stop+start 保配置；身份经 dataStoreRoot 复用）。仅存活态
    // 生效（未跑 no-op）；入口置 Reconnecting(network_change)，随后走完整装配
    // （Kotlin reconnectForNetworkChange 的 stop→awaitSettled→start 编排中，等待
    // 停机终态一段归壳层职责——本类内部串行完成）。
    void restartCore();

    // establish 回应（Dataplane.swap 语义）：fd<0 / 未启动 → false 且不接管 fd
    // （调用方持有）；Dataplane 闩锁拒绝 → false（fd 已由 Dataplane 关闭，A2 语义，
    // 本类不重复 close）。swap 成功即提交幂等签名（状态盲，对齐 Kotlin 注释）；
    // kind 仅存活态翻成 running——Failed 存活态的迟到 swap 不掩盖失败（F2）。
    bool swapFd(int fd);

    // 热重配：join/leave/orbit 增量 + appliedEntries 比对（routeVia/disableIpv6
    // 变更经 core.networkConf 刷新快照）→ 重聚合（幂等签名闸门兜底）。未启动 no-op。
    void applyConfig(const TunnelConfig &cfg);

    // 壳 NetWatch 透出（写快照）。值仅留存（TunnelSnapshot 的 pathSatisfied 由写方
    // ExtStateBus 注入——计划裁决，Task 8 序列化不含）；仍发 onStateChanged 供壳落盘。
    void setPathSatisfied(bool ok);

    // TunnelSnapshot 契约的 C++ 侧序列化（键名对齐 TunnelContract.ets，禁改）。
    // 不含 pathSatisfied/writtenAt（写方注入）。
    std::string snapshotJson() const;

    // 状态快照（按值——m_state 受锁保护，引用返回对并发读者是数据竞争，见头注释①）
    RuntimeState state() const;

    // running|starting|reconnecting（对齐 TunnelController.isRunning）
    bool isAlive() const;

    // ---- 仅供测试的注入通道（PP_TUNNELRUNTIME_TEST_HOOKS 编译守卫，OHOS 侧不编） ----
    // CoreBridge 的 netconf/事件回调在 host 无网络许可/时延不可控，无法等真实回调——
    // 注入通道与真实回调汇入同一条事件队列，驱动同一套状态机。
#ifdef PP_TUNNELRUNTIME_TEST_HOOKS
    int testUdpPort = -1; // -1 = 生产 9994；测试注入空闲回环端口（host 可能装 ZeroTier One）
    // 直投事件队列（op 恒 UP=1——首份完整 netconf 以 UP 回调的核心语义）
    void testFeedNetConf(uint64_t nwid, const NetConf &conf);
    // 直投事件队列（ZT_Event 原始码 / ≤-100 驱动失败 -(ZT_ResultCode)，对齐 CoreBridge）
    void testFeedEvent(int event);
    // join/leave/orbit/deorbit 动作记录（CoreBridge 无拦截点，经此锁定装配行为）
    std::function<void(const char *action, uint64_t a, uint64_t b)> testOnCoreAction;
    // 直调 pollPeers（F3 门控回归：存活三态即轮询，不等 Running；host peersNow
    // 恒空列表无内容可断言，以 onStateChanged 触发为轮询发生的可观测信号）
    void testPollPeers();
#endif

private:
    // ---- 事件（值语义深拷贝；核心线程只入队不阻塞） ----
    struct Evt {
        // K 前缀：枚举值不遮蔽 pp::NetConf 类型名（类作用域枚举值会隐藏同名类型）
        enum Kind { KNetConf, KFrame, KApply, KEvent, KStop } kind = KStop;
        // NetConf
        uint64_t nwid = 0;
        int op = 0;
        NetConf conf;
        // Frame
        uint64_t srcMac = 0, dstMac = 0;
        uint16_t etherType = 0, vlanId = 0;
        std::vector<uint8_t> frame;
        // Event
        int event = 0;
    };
    void pushEvt(Evt &&ev);
    void pushApply();

    // worker：netconf/apply 突发排空后聚合一次（Kotlin 300ms 去抖的等义实现）
    void workerLoop();
    void handleFrame(const Evt &ev);
    void handleNetConf(uint64_t nwid, int op, const NetConf &conf);
    void handleEvent(int event);
    void applyAggregated();   // 冲突检测 → 转换器上下文 → 合并 → 幂等签名 → 回调

    // 配置增量（m_lock 内）：join/leave/orbit/deorbit + appliedEntries 比对
    void applyConfigDiffLocked(const TunnelConfig &cfg);
    void upsertSnapshotLocked(uint64_t nwid, const NetConf &conf);
    void syncNetworkConfigsLocked();

    // 生命周期（m_lifeLock 内；不得持 m_lock 调用）
    bool startInternal(const TunnelConfig &cfg); // start/restartCore 共用（life 锁由外层持）
    bool isAliveKindLocked() const;              // 调用方持 m_lock
    void teardownPipeline();
    void startTimer();
    void stopTimer(); // m_timerLock 不与其它锁嵌套
    void timerLoop();
    void pollPeers();

    // 事件日志（TunnelStateBus.log 直译：HH:mm:ss.SSS 时间戳 + takeLast(40)）
    void log(const std::string &line);          // 自取 m_lock
    void logLocked(const std::string &line);    // 调用方持 m_lock

    // ---- 成员（声明序 = 构造依赖序：m_fc 先于 m_dp） ----
    mutable std::mutex m_lock; // 快照/状态/聚合（回调只投递不持此锁）
    RuntimeState m_state;
    TunnelConfig m_cfg;
    std::map<uint64_t, NetConf> m_snapshots;   // TunnelManager.snapshots 直译
    std::string m_appliedSignature;            // 最近一次成功 establish 的配置签名（幂等闸门）
    std::string m_pendingSignature;            // 本次已发出 establish 待 swapFd 提交的签名
    std::vector<uint64_t> m_joined;            // joinedNetworks（激活序，配对 m_cfg.networks）
    std::vector<uint64_t> m_orbited;           // orbitedMoons
    struct AppliedKey {                        // 用户侧配置比较键（A3 无每网络 DNS 模式）
        bool routeVia = false;
        bool disableIpv6 = false;
        bool operator==(const AppliedKey &o) const { return routeVia == o.routeVia && disableIpv6 == o.disableIpv6; }
    };
    std::map<uint64_t, AppliedKey> m_applied;  // appliedEntries 直译
    bool m_pathSatisfied = true;               // NetWatch 透出（序列化不含，见 setPathSatisfied）

    FrameConverter m_fc; // 网络隔离状态单一事实源（NetworkContext 在其内部）
    // Dataplane 闩锁不可逆（shutdown 后永拒）——每次装配换新实例（对齐 Kotlin 换代
    // 即换新 TUN 消费者）；停机后保留实例：迟到 swapFd 经闩锁拒绝并关 fd 防 fd 泄漏。
    // shared_ptr（F1）：swapFd 在 m_lock 内拷贝强引用、锁外经强引用调用 swap——
    // startInternal/restartCore 在 m_lifeLock 下换代重建 m_dp 时，在途 swap 仍持有
    // 旧实例（shutdown 已先行，闩锁拒绝 + 延迟析构安全），unique_ptr 释放即 UAF
    std::shared_ptr<Dataplane> m_dp;

    mutable std::mutex m_lifeLock; // start/stop/restartCore 生命周期串行化
    std::unique_ptr<CoreBridge> m_core;
    std::unique_ptr<UdpCom> m_udp;
    uint16_t m_udpPort = 9994;

    // 事件队列 + worker（zt-rt-worker）
    std::mutex m_qLock;
    std::condition_variable m_qCv;
    std::deque<Evt> m_queue;
    bool m_qClosed = false;
    std::thread m_worker;

    // 定时器（zt-rt-timer：45s 保活 + 5s Peer 轮询）
    std::mutex m_timerLock;
    std::condition_variable m_timerCv;
    bool m_timerQuit = false;
    std::thread m_timer;
};

} // namespace pp
