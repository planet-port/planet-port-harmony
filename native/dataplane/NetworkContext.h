// NetworkContext.h — 单网络数据面隔离状态（MAC/地址/路由/ARP/NDP/待决包）与聚合数学
//
// 直译源：tunnel/NetworkContext.kt（NetworkContext + NetworkContextMath，192 行）。
// 纯配置期逻辑（转发路径不碰，对齐 Kotlin 注释）。与 Kotlin 的映射差异：
//   ① parseIPv4/parseIPv6/dotted 已由 Net.h 落地（Task 0 直译自 NetworkContextMath），
//      此处复用不重复定义；IPv6 文本格式化用 formatV6（RoutePlanner.v6String 直译）。
//   ② RoutePlanner.networkCIDR4/6 的掩网换算在 .cpp 内以文件本地 helper 落地
//      （C++ RoutePlanner 接口未导出这两者，仅 update/detectConflicts 需要），
//      prefixLen 的 Kotlin 语义（无 '/' 视为 64）一并保留。
//   ③ detectConflicts 入参用 CIDR 字符串而非已解析地址，理由见该函数注释。
//   ④ 网关解析把「全零网关」归一为无网关（Kotlin 保留 0 值），理由见 parseIPv4Route 注释。
// 数据面单线程驱动：Kotlin synchronized/HashMap 在此退化为普通容器，无锁。
#pragma once
#include "ArpTable.h"
#include "NdpTable.h"
#include "Net.h"

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <tuple>
#include <vector>

namespace pp {

// FrameConverter 共用的待决包队列（定义在本头尾部；类内仅前向声明 + unique_ptr）
struct PendingQueue;

// IPv4 路由条目（地址均 host order uint32_t）——NetworkContext.kt IPv4RouteEntry
struct IPv4RouteEntry {
    uint32_t network;
    int prefix;
    std::optional<uint32_t> gateway;
    bool matches(uint32_t address) const;
};

// IPv6 路由条目——NetworkContext.kt IPv6RouteEntry
struct IPv6RouteEntry {
    Ipv6Address network;
    int prefix;
    std::optional<Ipv6Address> gateway;
    bool matches(const Ipv6Address& address) const;
};

// 聚合表条目：路由 + 归属网络（出站最长前缀匹配选网络）
struct AggregateV4Entry {
    uint64_t nwid;
    IPv4RouteEntry route;
};
struct AggregateV6Entry {
    uint64_t nwid;
    IPv6RouteEntry route;
};

// 单个网络在数据面的全部隔离状态：MAC、地址、ARP/NDP、待决包、路由
// 互不串网——多网络隔离的最小单元（NetworkContext.kt class NetworkContext）。
class NetworkContext {
public:
    NetworkContext(uint64_t nwid, uint64_t mac, const std::vector<std::string>& ipv4s,
                   const std::vector<std::string>& ipv6s, const std::vector<std::string>& routes);

    // 配置回调更新：仅刷新 MAC/地址/路由；ARP/NDP/pending 跨回调保留——
    // ZT 配置回调并不稀少（成员/路径变化即触发），整建重建会清缓存导致
    // ARP 风暴重放、在途待决包被静默丢弃（对齐 Kotlin update 注释）。
    void update(uint64_t mac, const std::vector<std::string>& ipv4s,
                const std::vector<std::string>& ipv6s, const std::vector<std::string>& routes);

    uint64_t nwid;
    uint64_t mac = 0;
    std::vector<uint32_t> ipv4; // 解析后 host order
    std::vector<Ipv6Address> ipv6;
    std::vector<IPv4RouteEntry> routes4; // 自身地址网段 + managed routes，前缀降序
    std::vector<IPv6RouteEntry> routes6;
    ArpTable arp;
    NdpTable ndp;
    // 等 ARP/NA 应答的包（每下一跳上限 FrameConverter 的 MAX_PENDING_PER_TARGET=16，
    // 满则丢新包——上限语义归 FrameConverter；Task 7 勘误：Kotlin 原文满时丢新到包）
    std::unique_ptr<PendingQueue> pendingV4, pendingV6;
    // 诊断计数（FrameConverter 锁内递增，仅诊断展示；NAT44 对齐 iOS 同名诊断：
    // 出站源不符却非本机地址（不改写仅计数）/改写与入站回写量）
    uint64_t statFwdV4 = 0, statArpReq = 0, statArpReply = 0, statInV4 = 0, statKeepalive = 0,
             statNatOut = 0, statNatIn = 0, statSrcMismatch = 0;
    std::optional<uint32_t> lastSrcMismatch;
};

namespace NetworkContextMath {

// 冲突原因原始码（文案 UI 层生成，对齐 iOS NetworkConflict）
inline constexpr const char* CONFLICT_ADDRESS = "address";
inline constexpr const char* CONFLICT_SUBNET = "subnet";

// 冲突检测：输入按激活顺序。先到者登记已占 IP 与直连网段；后进入者撞车标记冲突
// （地址冲突优先于网段冲突）且不登记先占。冲突网络由调用方排除出数据面，
// 保留 join 仅展示状态（对齐 Kotlin 注释）。
//
// 接口与 brief 稿的差异：入参用 CIDR 字符串而非已解析地址。Kotlin（行为规格唯一
// 来源）需要 RoutePlanner.networkCIDR4/6 从 "a.b.c.d/p" 推导直连网段做 subnet
// 冲突判定——纯地址无法还原前缀，brief 的地址列表签名表达不了其自定向量 ③
// 「同网段不同 IP→subnet 冲突」，故按 Kotlin 的 List<String> 形态落地。
std::map<uint64_t, std::string> detectConflicts(
    const std::vector<std::tuple<uint64_t, const std::vector<std::string>*,
                                 const std::vector<std::string>*>>& ordered);

// IPv4 聚合表：全部网络路由，前缀降序、同前缀按激活顺序（先到者胜）
std::vector<AggregateV4Entry> buildAggregateV4(const std::vector<const NetworkContext*>& ordered);
std::vector<AggregateV6Entry> buildAggregateV6(const std::vector<const NetworkContext*>& ordered);

// "x.x.x.x" 手写解析已在 Net.h（parseIpv4，不走任何解析服务）——此处不重复
// IPv6 同理（parseIpv6 保留「必须含 ':' 才解析」的防 DNS 语义）。

// "10.0.0.0/24" 或 "10.0.0.0/24 via 10.0.0.1" → IPv4RouteEntry。
// via 缺失/无法按本族解析/全零 → 无网关（全零归一无网关是 brief 约定，
// Kotlin 保留 0 值——0 网关会让 FrameConverter 对 0.0.0.0 发起 ARP）。
std::optional<IPv4RouteEntry> parseIPv4Route(const std::string& value);
std::optional<IPv6RouteEntry> parseIPv6Route(const std::string& value);

// "a.b.c.d/24"→"a.b.c.d"（无 '/' 返回原串；对齐 Kotlin substringBefore('/')）
std::optional<std::string> ipOnly(const std::string& cidr);

} // namespace NetworkContextMath

// 待决包队列（FrameConverter 共用）：key=下一跳 IP；值=待发帧
struct PendingQueue {
    std::map<uint32_t, std::vector<std::vector<uint8_t>>> v4; // Kt HashMap<UInt, MutableList<ByteArray>>
    std::map<Ipv6Address, std::vector<std::vector<uint8_t>>> v6;
    size_t total() const; // 仅 pendingV4 帧数合计（Kt 诊断行 pendingV4.values.sumOf { it.size }
                          // 同源——只统计 v4 实例；Task 7 勘误：原注释「两族」有误）
};

} // namespace pp
