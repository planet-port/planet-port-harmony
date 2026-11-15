// NAT44.h — 多网络源地址 NAT（IPv4，不换端口纯地址改写）
//
// 直译源：tunnel/NAT44.kt（Android，1:1 移植自 iOS NAT44.swift）。
// 单 tun 多地址时路由层无 per-route src 绑定，源按接口主地址选择，只能在
// 数据面改包：
// - 出站：源 IP 不属于所选网络时改写为该网络地址（增量修正 IP 头与 TCP/UDP
//   校验和，RFC 1624），TCP/UDP 登记流表（proto + 远端 IP/端口 + 本地端口 →
//   原始源）
// - 入站：命中流表的回包把目的地址回写为原始源——否则应用 socket（本地地址
//   是错误的原始源）匹配不上，TCP 握手无法完成
// - ICMP 无需回写：echo 回包按 id 匹配 raw socket，不按目的地址
// - 分片包不进流表（非首片无端口无法匹配；ZT 内部 MTU 内基本不分片）
// - 流键带 nwid：嵌套子网（如 10.0.0.0/8 与 10.0.0.0/24 两网共存）时同一
//   四元组可能分属两网的不同流且原始源不同，按网络隔离流键即根除串流
// 线程：无锁，仅在 FrameConverter 的锁内使用（对齐 Kotlin）。
#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <unordered_map>
#include <utility>
#include <vector>
namespace pp {

struct FlowKey { // nwid + 四元组（不换端口，纯地址改写）
    uint64_t nwid;
    uint8_t proto; // 6 TCP / 17 UDP
    uint32_t remoteIp; // host order
    uint16_t remotePort;
    uint16_t localPort;
    bool operator==(const FlowKey& o) const; // C++17：手写，defaulted == 不可用
    bool operator!=(const FlowKey& o) const { return !(*this == o); }
};

struct FlowKeyHash {
    size_t operator()(const FlowKey& k) const;
};

class NAT44 {
public:
    using Clock = std::function<int64_t(void)>; // 毫秒，注入（Android=SystemClock.elapsedRealtime）
    explicit NAT44(Clock clock) : m_clock(std::move(clock)) {}

    /** 出站登记/刷新（改写源前调用）：已存在仅刷新活跃时间，保留原 origSrc */
    void record(const FlowKey& key, uint32_t origSrc);

    /** 入站查询：命中刷新 LRU 活跃时间；空闲超时（TCP 6h / UDP 60s）视为未命中。
     * 注：Kotlin lookup 不做超时判定（老化仅在逐出时生效）；此处按 A2 计划
     * 向量⑥「UDP 61s 后 lookup 未中」增加超时判定，防陈旧流回写原始源。 */
    std::optional<uint32_t> lookup(const FlowKey& key);

    /** 表项数（诊断输出用） */
    size_t size() const;

    // 纯函数（向量测试主目标）
    /** 出站 IPv4 包提取 TCP/UDP 流键；非 TCP/UDP 或分片返回 nullopt（ICMP 无需流表） */
    static std::optional<FlowKey> outboundKey(const std::vector<uint8_t>& pkt, uint64_t nwid);
    /** 入站 IPv4 包提取流键（方向翻转：对端为源）；非 TCP/UDP 或分片返回 nullopt */
    static std::optional<FlowKey> inboundKey(const std::vector<uint8_t>& pkt, uint64_t nwid);
    /** 改写 IPv4 包 [ipOffset] 处地址（12=源 / 16=目的），增量修正 IP 头与 L4
     * 校验和（RFC 1624）。非首片分片（片偏移≠0）只修 IP 头——其 ihl 之后是
     * 用户载荷不是 L4 头，按 L4 校验和位置写回会破坏载荷；首片（MF=1 且偏移 0）
     * 含完整 L4 头可全量修正。ICMP 校验和不覆盖 IP 地址，无需修正。
     * 返回是否发生改写（包长 < 20 不动包返回 false）；调用方保证 v4、地址确实位于 ipOffset。 */
    static bool rewriteAddress(std::vector<uint8_t>& pkt, size_t ipOffset,
                               uint32_t oldIp, uint32_t newIp);

private:
    // 表上限 + LRU + 按协议空闲老化（服务进程内存约束）。TCP 拉长到小时级
    // （对齐 conntrack established 思路：真实保活间隔均为分钟级，空闲超时后
    // 「对端先发包」才断流，长连接场景需覆盖其空闲窗口）；UDP 无连接语义，
    // 短老化靠新出站重建。双向任一包都刷新活跃时间。
    static constexpr size_t kMaxEntries = 512;               // MAX_ENTRIES
    static constexpr int64_t kIdleTimeoutTcpMs = 6 * 3600 * 1000;  // IDLE_TIMEOUT_TCP_MS
    static constexpr int64_t kIdleTimeoutUdpMs = 60 * 1000;        // IDLE_TIMEOUT_UDP_MS

    /** 清理：先淘汰过期（按各流协议老化时间），仍满则逐最旧（512 条 O(n) 可忽略） */
    void evictLocked();
    static int64_t timeoutOf(const FlowKey& key);
    int64_t now() const { return m_clock ? m_clock() : 0; }

    Clock m_clock;
    // (origSrc, lastUsed)
    std::unordered_map<FlowKey, std::pair<uint32_t, int64_t>, FlowKeyHash> m_map;
};

} // namespace pp
