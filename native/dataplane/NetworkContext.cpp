// NetworkContext.cpp — 单网络数据面隔离状态与聚合数学实现（A2 Task 4）
//
// 直译源：tunnel/NetworkContext.kt（NetworkContext + NetworkContextMath，192 行）。
// 逐段对照：
//   IPv4RouteEntry/IPv6RouteEntry::matches   → 同名类方法
//   NetworkContext init/update               → 构造 / update（ARP/NDP/pending 跨回调保留）
//   NetworkContextMath.detectConflicts       → 后进入者让路（地址冲突优先于网段冲突）
//   buildAggregateV4/V6                      → 前缀降序、同前缀按激活顺序（stable_sort 保序等价）
//   parseIPv4Route/parseIPv6Route/ipOnly     → 同名函数
//   RoutePlanner.networkCIDR4/6/prefixLen    → 文件本地 helper（Kotlin update/detectConflicts
//                                              依赖；C++ RoutePlanner 接口未导出，见头注释）
#include "dataplane/NetworkContext.h"

#include <algorithm>
#include <set>

namespace pp {
namespace {

// Kotlin String.split(delimiter)（limit=0：去尾随空段、保留段间空段）
std::vector<std::string> splitChar(const std::string& s, char delim) {
    std::vector<std::string> out;
    std::string cur;
    for (char c : s) {
        if (c == delim) {
            out.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(c);
        }
    }
    out.push_back(cur);
    while (!out.empty() && out.back().empty()) out.pop_back();
    return out;
}

size_t indexOf(const std::vector<std::string>& v, const std::string& s) {
    for (size_t i = 0; i < v.size(); ++i)
        if (v[i] == s) return i;
    return std::string::npos;
}

// Kotlin String.toIntOrNull：可选符号 + 纯数字；空串/杂字符/Int 溢出 → nullopt
std::optional<int> toIntOrNull(const std::string& s) {
    if (s.empty()) return std::nullopt;
    size_t i = 0;
    bool neg = false;
    if (s[0] == '+' || s[0] == '-') {
        neg = (s[0] == '-');
        i = 1;
    }
    if (i >= s.size()) return std::nullopt;
    long v = 0;
    for (; i < s.size(); ++i) {
        if (s[i] < '0' || s[i] > '9') return std::nullopt;
        v = v * 10 + (s[i] - '0');
        if (v > 2147483647L) return std::nullopt;
    }
    return int(neg ? -v : v);
}

// Kotlin substringBefore('/')：无 '/' 返回原串
std::string ipOnlyRaw(const std::string& cidr) {
    size_t p = cidr.find('/');
    return (p == std::string::npos) ? cidr : cidr.substr(0, p);
}

// RoutePlanner.prefixLen 直译：substringAfter('/', "64").toIntOrNull() ?: 64
// ——无 '/' 或 '/' 后非数字一律按 64（对齐 Kotlin/iOS 约定，两族同缺省）
int prefixLenRaw(const std::string& cidr) {
    size_t p = cidr.find('/');
    std::string tail = (p == std::string::npos) ? std::string("64") : cidr.substr(p + 1);
    std::optional<int> v = toIntOrNull(tail);
    return v ? *v : 64;
}

// RoutePlanner.networkCIDR4 直译：地址掩网回 "network/prefix"；地址非法原样返回。
// Kotlin `UInt.MAX_VALUE shl (32 - prefix)`——prefix==0 时位移 32 在 C++ 是 UB，单独分支。
std::string networkCidr4(const std::string& cidr) {
    int prefix = prefixLenRaw(cidr);
    if (prefix > 32) prefix = 32; // Kotlin coerceAtMost(32)
    std::optional<uint32_t> ip = parseIpv4(ipOnlyRaw(cidr));
    if (!ip) return cidr;
    uint32_t mask = (prefix <= 0) ? 0u : (0xffffffffu << (32 - prefix));
    return dottedV4(*ip & mask) + "/" + std::to_string(prefix);
}

// RoutePlanner.maskBytes 直译：从 prefix 位起逐位清零（prefix 先 coerceAtLeast(0)）
Ipv6Address maskBytes6(const Ipv6Address& in, int prefix) {
    Ipv6Address out;
    out.bytes = in.bytes;
    for (int bit = prefix > 0 ? prefix : 0; bit < 128; ++bit) {
        uint8_t& b = out.bytes[size_t(bit / 8)];
        b = uint8_t(b & uint8_t(~(1u << (7 - bit % 8)) & 0xffu));
    }
    return out;
}

// RoutePlanner.networkCIDR6 直译（v6String 的 C++ 落地即 Net.h formatV6）
std::string networkCidr6(const std::string& cidr) {
    int prefix = prefixLenRaw(cidr);
    if (prefix > 128) prefix = 128; // Kotlin coerceAtMost(128)
    std::optional<Ipv6Address> addr = parseIpv6(ipOnlyRaw(cidr));
    if (!addr) return cidr;
    return formatV6(maskBytes6(*addr, prefix)) + "/" + std::to_string(prefix);
}

} // namespace

// ---- 路由条目（NetworkContext.kt IPv4RouteEntry/IPv6RouteEntry） ----

// mask = 0（/0 恒真）或高位连续 prefix 个 1；比较按掩网后的网络号
bool IPv4RouteEntry::matches(uint32_t address) const {
    uint32_t mask = (prefix == 0) ? 0u : (0xffffffffu << (32 - prefix));
    return (address & mask) == (network & mask);
}

// 先整字节比对，再比对剩余位（剩余位掩码 (0xff << (8-remaining))；对齐 Kotlin）
bool IPv6RouteEntry::matches(const Ipv6Address& address) const {
    int fullBytes = prefix / 8;
    for (int i = 0; i < fullBytes; ++i)
        if (network.bytes[size_t(i)] != address.bytes[size_t(i)]) return false;
    int remaining = prefix % 8;
    if (remaining == 0) return true;
    uint8_t mask = uint8_t(0xffu << (8 - remaining));
    return (network.bytes[size_t(fullBytes)] & mask) == (address.bytes[size_t(fullBytes)] & mask);
}

// ---- 单网络上下文（NetworkContext.kt class NetworkContext） ----

NetworkContext::NetworkContext(uint64_t nwidArg, uint64_t macArg, const std::vector<std::string>& ipv4s,
                               const std::vector<std::string>& ipv6s, const std::vector<std::string>& routes)
    : nwid(nwidArg), pendingV4(std::make_unique<PendingQueue>()), pendingV6(std::make_unique<PendingQueue>()) {
    update(macArg, ipv4s, ipv6s, routes); // Kotlin init { update(...) }
}

void NetworkContext::update(uint64_t macArg, const std::vector<std::string>& ipv4s,
                            const std::vector<std::string>& ipv6s, const std::vector<std::string>& routes) {
    mac = macArg;
    // 仅刷新 MAC/地址/路由；arp/ndp/pending 是成员对象/指针，跨回调原样保留
    ipv4.clear();
    ipv6.clear();
    routes4.clear();
    routes6.clear();

    for (const std::string& s : ipv4s) // mapNotNull { parseIPv4(ipOnly(it)) }
        if (std::optional<uint32_t> a = parseIpv4(ipOnlyRaw(s))) ipv4.push_back(*a);
    for (const std::string& s : ipv6s) // mapNotNull { parseIPv6(ipOnly(it)) }
        if (std::optional<Ipv6Address> a = parseIpv6(ipOnlyRaw(s))) ipv6.push_back(*a);

    // routesV4 = (ipv4Strings.map { networkCIDR4(it) } + routes).mapNotNull(::parseIPv4Route)
    for (const std::string& s : ipv4s)
        if (std::optional<IPv4RouteEntry> e = NetworkContextMath::parseIPv4Route(networkCidr4(s)))
            routes4.push_back(*e);
    for (const std::string& s : routes)
        if (std::optional<IPv4RouteEntry> e = NetworkContextMath::parseIPv4Route(s)) routes4.push_back(*e);
    for (const std::string& s : ipv6s)
        if (std::optional<IPv6RouteEntry> e = NetworkContextMath::parseIPv6Route(networkCidr6(s)))
            routes6.push_back(*e);
    for (const std::string& s : routes)
        if (std::optional<IPv6RouteEntry> e = NetworkContextMath::parseIPv6Route(s)) routes6.push_back(*e);

    // sortedByDescending { it.prefix }——稳定排序，等价 Kotlin「前缀降序、同前缀保持
    // 输入序（自身网段在前、managed 路由次之）」
    std::stable_sort(routes4.begin(), routes4.end(),
                     [](const IPv4RouteEntry& a, const IPv4RouteEntry& b) { return a.prefix > b.prefix; });
    std::stable_sort(routes6.begin(), routes6.end(),
                     [](const IPv6RouteEntry& a, const IPv6RouteEntry& b) { return a.prefix > b.prefix; });
}

// ---- 待决包队列（FrameConverter.kt pendingV4/pendingV6 语义落地） ----

size_t PendingQueue::total() const {
    size_t n = 0;
    for (const auto& kv : v4) n += kv.second.size();
    for (const auto& kv : v6) n += kv.second.size();
    return n;
}

// ---- 聚合数学（NetworkContext.kt object NetworkContextMath） ----

namespace NetworkContextMath {

std::map<uint64_t, std::string> detectConflicts(
    const std::vector<std::tuple<uint64_t, const std::vector<std::string>*,
                                 const std::vector<std::string>*>>& ordered) {
    std::set<uint32_t> claimedIp4;    // Kt HashSet<UInt>
    std::set<Ipv6Address> claimedIp6; // Kt HashSet<Ipv6Address>（按内容判等）
    std::set<std::string> claimedSubnets;
    std::map<uint64_t, std::string> conflicts;
    for (const auto& item : ordered) {
        const uint64_t nwid = std::get<0>(item);
        static const std::vector<std::string> kEmpty; // 指针判空兜底（Kotlin 侧恒非空）
        const std::vector<std::string>& v4 = std::get<1>(item) ? *std::get<1>(item) : kEmpty;
        const std::vector<std::string>& v6 = std::get<2>(item) ? *std::get<2>(item) : kEmpty;

        // subnets = v4.map { networkCIDR4(it) } + v6.map { networkCIDR6(it) }
        std::vector<std::string> subnets;
        subnets.reserve(v4.size() + v6.size());
        for (const std::string& s : v4) subnets.push_back(networkCidr4(s));
        for (const std::string& s : v6) subnets.push_back(networkCidr6(s));
        // ips4/ips6 = mapNotNull { parse(ipOnly(it)) }
        std::vector<uint32_t> ips4;
        for (const std::string& s : v4)
            if (std::optional<uint32_t> a = parseIpv4(ipOnlyRaw(s))) ips4.push_back(*a);
        std::vector<Ipv6Address> ips6;
        for (const std::string& s : v6)
            if (std::optional<Ipv6Address> a = parseIpv6(ipOnlyRaw(s))) ips6.push_back(*a);

        // 地址冲突优先于网段冲突
        const char* conflict = nullptr;
        const bool addrHit =
            std::any_of(ips4.begin(), ips4.end(),
                        [&](uint32_t ip) { return claimedIp4.count(ip) > 0; }) ||
            std::any_of(ips6.begin(), ips6.end(),
                        [&](const Ipv6Address& ip) { return claimedIp6.count(ip) > 0; });
        if (addrHit) {
            conflict = CONFLICT_ADDRESS;
        } else if (std::any_of(subnets.begin(), subnets.end(),
                               [&](const std::string& sn) { return claimedSubnets.count(sn) > 0; })) {
            conflict = CONFLICT_SUBNET;
        }
        if (conflict != nullptr) {
            conflicts[nwid] = conflict;
            continue; // 撞车者的 IP/网段不登记
        }
        claimedIp4.insert(ips4.begin(), ips4.end());
        claimedIp6.insert(ips6.begin(), ips6.end());
        claimedSubnets.insert(subnets.begin(), subnets.end());
    }
    return conflicts;
}

// Kt flatMapIndexed + sortedWith(compareByDescending{prefix}.thenBy{index})：
// 按激活顺序收集后做稳定的前缀降序排序，等前缀自然保持先到者在前
std::vector<AggregateV4Entry> buildAggregateV4(const std::vector<const NetworkContext*>& ordered) {
    std::vector<AggregateV4Entry> out;
    for (const NetworkContext* ctx : ordered)
        for (const IPv4RouteEntry& r : ctx->routes4) out.push_back(AggregateV4Entry{ctx->nwid, r});
    std::stable_sort(out.begin(), out.end(),
                     [](const AggregateV4Entry& a, const AggregateV4Entry& b) {
                         return a.route.prefix > b.route.prefix;
                     });
    return out;
}

std::vector<AggregateV6Entry> buildAggregateV6(const std::vector<const NetworkContext*>& ordered) {
    std::vector<AggregateV6Entry> out;
    for (const NetworkContext* ctx : ordered)
        for (const IPv6RouteEntry& r : ctx->routes6) out.push_back(AggregateV6Entry{ctx->nwid, r});
    std::stable_sort(out.begin(), out.end(),
                     [](const AggregateV6Entry& a, const AggregateV6Entry& b) {
                         return a.route.prefix > b.route.prefix;
                     });
    return out;
}

std::optional<std::string> ipOnly(const std::string& cidr) {
    return ipOnlyRaw(cidr);
}

// Kt：fields.indexOf("via").takeIf{it>=0}?.let{fields.getOrNull(it+1)}?.let{parseIPv4(ipOnly(it))}
// ——via 缺失/越位/解析失败都落成无网关；全零网关归一为无网关（brief 约定，
// 见头注释 ④：0 网关会让 FrameConverter 对 0.0.0.0 发起 ARP）
std::optional<IPv4RouteEntry> parseIPv4Route(const std::string& value) {
    std::vector<std::string> fields = splitChar(value, ' ');
    if (fields.empty()) return std::nullopt; // Kt firstOrNull ?: return null
    std::vector<std::string> parts = splitChar(fields[0], '/');
    if (parts.size() != 2) return std::nullopt;
    std::optional<uint32_t> address = parseIpv4(parts[0]);
    if (!address) return std::nullopt;
    std::optional<int> prefix = toIntOrNull(parts[1]);
    if (!prefix || *prefix < 0 || *prefix > 32) return std::nullopt;
    std::optional<uint32_t> gateway;
    size_t via = indexOf(fields, "via");
    if (via != std::string::npos && via + 1 < fields.size()) {
        std::optional<uint32_t> g = parseIpv4(ipOnlyRaw(fields[via + 1]));
        if (g && *g != 0) gateway = *g;
    }
    return IPv4RouteEntry{*address, *prefix, gateway};
}

std::optional<IPv6RouteEntry> parseIPv6Route(const std::string& value) {
    std::vector<std::string> fields = splitChar(value, ' ');
    if (fields.empty()) return std::nullopt;
    std::vector<std::string> parts = splitChar(fields[0], '/');
    if (parts.size() != 2) return std::nullopt;
    std::optional<Ipv6Address> address = parseIpv6(parts[0]);
    if (!address) return std::nullopt;
    std::optional<int> prefix = toIntOrNull(parts[1]);
    if (!prefix || *prefix < 0 || *prefix > 128) return std::nullopt;
    std::optional<Ipv6Address> gateway;
    size_t via = indexOf(fields, "via");
    if (via != std::string::npos && via + 1 < fields.size()) {
        std::optional<Ipv6Address> g = parseIpv6(ipOnlyRaw(fields[via + 1]));
        bool allZero = g && *g == Ipv6Address{}; // 全零（::）网关归一为无网关，同 v4
        if (g && !allZero) gateway = *g;
    }
    return IPv6RouteEntry{*address, *prefix, gateway};
}

} // namespace NetworkContextMath

} // namespace pp
