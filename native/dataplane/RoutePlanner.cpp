// RoutePlanner.cpp — 路由差集规划与物理接口探测（A2 计划 Task 5）
//
// 直译源：RoutePlanner.kt（Android）。路由数学与物理接口探测（纯函数无状态，
// 对齐 iOS RoutePlanner）：CIDR 换算、前缀差集（挖除物理 on-link 子网）、
// 物理接口枚举。Android 无 excludedRoutes 概念——挖洞同样用差集展开
// （Builder 只会 addRoute「抓进 TUN」的前缀，差集展开后物理网段自然留在
// 物理网卡）。
// 接口枚举以 getifaddrs(3) 对齐 NetworkInterface.getNetworkInterfaces() 的
// isUp/isLoopback/接口名前缀/网络前缀长度语义（Android 由 netmask 推前缀，
// 故从 ifa_netmask 数前导 1 是同源译法，天然免疫点对点 -1 前缀坑）。
#include "dataplane/RoutePlanner.h"

#include <cstring>
#include <functional>
#include <net/if.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <set>

namespace pp {

// ---- IPPrefix（直译 RoutePlanner.kt L12-35） ----

bool IPPrefix::operator==(const IPPrefix& o) const {
    return length == o.length && bytes == o.bytes;
}

bool IPPrefix::operator!=(const IPPrefix& o) const { return !(*this == o); }

// Kotlin bit(i) = (bytes[i / 8] shr (7 - i % 8)) and 1
static int prefixBit(const IPPrefix& p, int i) {
    return (p.bytes[static_cast<size_t>(i / 8)] >> (7 - i % 8)) & 1;
}

bool IPPrefix::contains(const IPPrefix& other) const {
    if (length > other.length) return false;
    for (int i = 0; i < length; ++i)
        if (prefixBit(*this, i) != prefixBit(other, i)) return false;
    return true;
}

std::pair<IPPrefix, IPPrefix> IPPrefix::split() const {
    // 防御：差集分解只在 dest 严格包含 hole 时下钻，length 必小于位数，不会走到此；
    // Kotlin 越界会抛异常，C++ 侧直接原样返回避免 UB（不改变正常路径行为）
    if (length < 0 || length >= int(bytes.size()) * 8) return {*this, *this};
    const int byteIndex = length / 8;
    const uint8_t mask = uint8_t(1 << (7 - length % 8));
    IPPrefix left = *this;
    IPPrefix right = *this;
    left.bytes[static_cast<size_t>(byteIndex)] =
        uint8_t(left.bytes[static_cast<size_t>(byteIndex)] & uint8_t(~mask)); // and mask.inv()
    right.bytes[static_cast<size_t>(byteIndex)] =
        uint8_t(right.bytes[static_cast<size_t>(byteIndex)] | mask);          // or mask
    left.length = length + 1;
    right.length = length + 1;
    return {left, right};
}

namespace RoutePlanner {
namespace {

/** Kotlin r.split(' ').firstOrNull() ?: r —— 取首空格前目的段（剥离 " via 网关"） */
std::string firstToken(const std::string& route) {
    const size_t sp = route.find(' ');
    return sp == std::string::npos ? route : route.substr(0, sp);
}

/** Kotlin prefix.coerceAtMost(n) */
int clampAtMost(int v, int max) { return v < max ? v : max; }

/**
 * 前缀差集：dest 挖去 hole，返回互斥前缀列表（split 二叉树减法，直译 subtract）。
 * hole 吞掉 dest → 空；互不包含 → dest 原样；dest 包含 hole → 二分后逐半递归。
 */
std::vector<IPPrefix> subtract(const IPPrefix& dest, const IPPrefix& hole) {
    if (dest == hole || hole.contains(dest)) return {};
    if (!dest.contains(hole)) return {dest};
    const std::pair<IPPrefix, IPPrefix> halves = dest.split();
    std::vector<IPPrefix> out = subtract(halves.first, hole);
    const std::vector<IPPrefix> right = subtract(halves.second, hole);
    out.insert(out.end(), right.begin(), right.end());
    return out;
}

/** 网络序 4 字节 → host 序 uint32 */
uint32_t be32(const std::vector<uint8_t>& b) {
    return (uint32_t(b[0]) << 24) | (uint32_t(b[1]) << 16) | (uint32_t(b[2]) << 8) | uint32_t(b[3]);
}

/** 掩码到指定位：bit ∈ [prefix, size*8) 逐一清零（直译 maskBytes，prefix 负值按 0 起） */
std::vector<uint8_t> maskBytes(std::vector<uint8_t> in, int prefix) {
    const int total = int(in.size()) * 8;
    for (int bit = prefix < 0 ? 0 : prefix; bit < total; ++bit)
        in[static_cast<size_t>(bit / 8)] =
            uint8_t(in[static_cast<size_t>(bit / 8)] & uint8_t(~(1 << (7 - bit % 8))));
    return in;
}

/**
 * IPPrefix → 掩到网络位的 v4 CIDR 串（直译 networkCIDR4 的 IPPrefix 形态：
 * coerceAtMost(32) 后掩网络位）。族不符 / 前缀无效（点对点 -1）返回空串，上层跳过。
 */
std::string networkCidr4(const IPPrefix& p) {
    const int prefix = clampAtMost(p.length, 32);
    if (prefix < 0 || p.bytes.size() != 4) return std::string();
    return dottedV4(be32(maskBytes(p.bytes, prefix))) + "/" + std::to_string(prefix);
}

/** 同 networkCidr4 的 v6 形态（coerceAtMost(128)；formatV6 见 Net.h 直译说明） */
std::string networkCidr6(const IPPrefix& p) {
    const int prefix = clampAtMost(p.length, 128);
    if (prefix < 0 || p.bytes.size() != 16) return std::string();
    Ipv6Address a;
    const std::vector<uint8_t> masked = maskBytes(p.bytes, prefix);
    for (size_t i = 0; i < 16; ++i) a.bytes[i] = masked[i];
    return formatV6(a) + "/" + std::to_string(prefix);
}

/** 已掩网络位的地址字节 → "网络地址/前缀" CIDR 串（v4 点分 / v6 缩写，复用 Net.h） */
std::string networkCidrString(int family, const std::vector<uint8_t>& network, int prefix) {
    if (family == AF_INET) return dottedV4(be32(network)) + "/" + std::to_string(prefix);
    Ipv6Address a;
    for (size_t i = 0; i < 16 && i < network.size(); ++i) a.bytes[i] = network[i];
    return formatV6(a) + "/" + std::to_string(prefix);
}

// 接口名前缀限定：wlan/eth/rmnet/usb 四前缀为 Android 直译；"en" 为 host(macOS/BSD)
// 以太命名（brief 场景⑤要求 host 上含 en0 网段；OHOS 名为 wlan0/eth0 不受影响）。
// lo/utun/feth/awdl/bridge 等虚拟接口天然不被前缀命中（排除 lo/tun）。
const char* const kPhysicalIfPrefixes[] = {"wlan", "eth", "rmnet", "usb", "en"};

bool isPhysicalInterfaceName(const char* name) {
    const std::string n(name);
    for (const char* p : kPhysicalIfPrefixes)
        if (n.rfind(p, 0) == 0) return true;
    return false;
}

/** ifa_netmask → 前缀长度（数连续前导 1，Android 即由 netmask 推前缀）；缺掩码/非连续 → -1 */
int prefixFromNetmask(const sockaddr* nm, int family) {
    if (!nm) return -1;
    const uint8_t* p = nullptr;
    size_t n = 0;
    if (family == AF_INET) {
        p = reinterpret_cast<const uint8_t*>(&reinterpret_cast<const sockaddr_in*>(nm)->sin_addr);
        n = 4;
    } else if (family == AF_INET6) {
        p = reinterpret_cast<const uint8_t*>(&reinterpret_cast<const sockaddr_in6*>(nm)->sin6_addr);
        n = 16;
    } else {
        return -1;
    }
    int prefix = 0;
    bool zeroSeen = false;
    for (size_t i = 0; i < n; ++i) {
        for (int b = 7; b >= 0; --b) {
            if (p[i] & (1u << b)) {
                if (zeroSeen) return -1; // 非连续掩码视为无效（同点对点丢弃）
                ++prefix;
            } else {
                zeroSeen = true;
            }
        }
    }
    return prefix;
}

/**
 * 枚举物理接口（wlan/eth/rmnet/usb/en——排除 lo/tun 等虚拟接口）的全部接口地址，
 * 直译 forEachPhysicalInterfaceAddress：!isUp || isLoopback 跳过；
 * prefix <= 0 跳过（点对点接口返回 -1（含 0 视为无效）——IPPrefix(-1) 的 contains
 * 恒真，会把全部 ZT 路由挖空（iOS 从 netmask 推前缀故免疫此坑））。
 * block(网络序地址字节, 字节数, 前缀长度, AF_INET/AF_INET6)
 */
void forEachPhysicalInterfaceAddress(
    const std::function<void(const uint8_t*, size_t, int, int)>& block) {
    struct ifaddrs* list = nullptr;
    if (getifaddrs(&list) != 0) return; // Kotlin：枚举异常 → 空返回
    for (struct ifaddrs* ia = list; ia; ia = ia->ifa_next) {
        if (!ia->ifa_name || !ia->ifa_addr) continue;
        if (!(ia->ifa_flags & IFF_UP) || (ia->ifa_flags & IFF_LOOPBACK)) continue;
        if (!isPhysicalInterfaceName(ia->ifa_name)) continue;
        const int family = ia->ifa_addr->sa_family;
        if (family != AF_INET && family != AF_INET6) continue;
        const int prefix = prefixFromNetmask(ia->ifa_netmask, family);
        if (prefix <= 0) continue;
        uint8_t buf[16];
        size_t n = 0;
        if (family == AF_INET) {
            n = 4;
            std::memcpy(buf, &reinterpret_cast<const sockaddr_in*>(ia->ifa_addr)->sin_addr, 4);
        } else {
            n = 16;
            std::memcpy(buf, &reinterpret_cast<const sockaddr_in6*>(ia->ifa_addr)->sin6_addr, 16);
        }
        block(buf, n, prefix, family);
    }
    freeifaddrs(list);
}

/** seen/assignedNetworks 去重集合共用的物理网段枚举骨架（直译 physicalOnLinkPrefixes4/6） */
std::vector<IPPrefix> physicalOnLinkPrefixes(const std::vector<IPPrefix>& excludingNetworksOf,
                                            int family) {
    std::set<std::string> assignedNetworks; // excludingNetworksOf 归一化到网络位 CIDR 串
    for (const IPPrefix& p : excludingNetworksOf) {
        const std::string c = family == AF_INET ? networkCidr4(p) : networkCidr6(p);
        if (!c.empty()) assignedNetworks.insert(c);
    }
    std::set<std::string> seen;
    std::vector<IPPrefix> prefixes;
    forEachPhysicalInterfaceAddress([&](const uint8_t* bytes, size_t n, int prefix, int af) {
        if (af != family) return;
        if (family == AF_INET6) {
            // 跳过 fe80:: 链路本地——本就不经默认路由
            // （Inet6Address.isLinkLocalAddress：首字节 0xfe 且次字节高两位 10，fe80::/10）
            if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return;
        }
        const std::vector<uint8_t> addr(bytes, bytes + n);
        const std::vector<uint8_t> network = maskBytes(addr, prefix);
        const std::string cidr = networkCidrString(family, network, prefix);
        if (seen.count(cidr) || assignedNetworks.count(cidr)) return;
        seen.insert(cidr);
        prefixes.push_back(IPPrefix{network, prefix});
    });
    return prefixes;
}

} // namespace

/** 直译 expandV4：「IPv4 CIDR（可带 "via 网关"）挖除若干前缀后展开」。解析失败 → 空 */
std::vector<IPPrefix> expandV4(const RouteEntry& r, const std::vector<IPPrefix>& holes) {
    const std::string dest = firstToken(r.addr);
    const std::optional<std::string> ipStr = ipOnly(dest);
    if (!ipStr) return {};
    const std::optional<uint32_t> ip = parseIpv4(*ipStr);
    if (!ip) return {}; // 族门禁：v6/非法路由串进 expandV4 → 空（对齐 parseIPv4 失败路径）
    // addr 已带 "/p" 时按 Kotlin 从串上取前缀；裸地址时用入参 RouteEntry.prefix
    const int len =
        dest.find('/') == std::string::npos ? r.prefix : prefixLen(dest);
    IPPrefix dest0;
    // Kotlin byteArrayOf(((ip shr 24) and 0xffu).toByte(), …)——host 序 uint32 → 网络序字节
    dest0.bytes = {uint8_t((*ip >> 24) & 0xffu), uint8_t((*ip >> 16) & 0xffu),
                   uint8_t((*ip >> 8) & 0xffu), uint8_t(*ip & 0xffu)};
    dest0.length = clampAtMost(len, 32); // coerceAtMost(32)；缺省 64 → 32（对齐 Kotlin 按族缺省）
    std::vector<IPPrefix> result{dest0};
    for (const IPPrefix& hole : holes) {
        std::vector<IPPrefix> next;
        for (const IPPrefix& p : result) {
            std::vector<IPPrefix> sub = subtract(p, hole);
            next.insert(next.end(), sub.begin(), sub.end());
        }
        result = std::move(next);
    }
    return result;
}

/** 直译 expandV6：holes 同构（v6 族门禁 / clamp 128，其余同 expandV4） */
std::vector<IPPrefix> expandV6(const RouteEntry& r, const std::vector<IPPrefix>& holes) {
    const std::string dest = firstToken(r.addr);
    const std::optional<std::string> ipStr = ipOnly(dest);
    if (!ipStr) return {};
    const std::optional<Ipv6Address> addr = parseIpv6(*ipStr);
    if (!addr) return {};
    const int len =
        dest.find('/') == std::string::npos ? r.prefix : prefixLen(dest);
    IPPrefix dest0;
    dest0.bytes.assign(addr->bytes.begin(), addr->bytes.end());
    dest0.length = clampAtMost(len, 128);
    std::vector<IPPrefix> result{dest0};
    for (const IPPrefix& hole : holes) {
        std::vector<IPPrefix> next;
        for (const IPPrefix& p : result) {
            std::vector<IPPrefix> sub = subtract(p, hole);
            next.insert(next.end(), sub.begin(), sub.end());
        }
        result = std::move(next);
    }
    return result;
}

/** 直译 physicalOnLinkPrefixes4：物理接口 on-link IPv4 子网 → 待挖除前缀集合。
 *  ZT managed routes（如 0.0.0.0/0）会把本地网关/DNS 抓进 TUN 黑洞，挖除后本地
 *  子网仍走物理网卡。excludingNetworksOf：子网与 ZT 分配地址所在网段相同时跳过，
 *  避免反过来打断 ZeroTier。 */
std::vector<IPPrefix> physicalOnLinkPrefixes4(const std::vector<IPPrefix>& excludingNetworksOf) {
    return physicalOnLinkPrefixes(excludingNetworksOf, AF_INET);
}

/** 直译 physicalOnLinkPrefixes6：同上（v6，跳过链路本地） */
std::vector<IPPrefix> physicalOnLinkPrefixes6(const std::vector<IPPrefix>& excludingNetworksOf) {
    return physicalOnLinkPrefixes(excludingNetworksOf, AF_INET6);
}

/** 直译 isDefaultRoute：目的段 == "0.0.0.0/0" 或 "::/0" */
bool isDefaultRoute(const RouteEntry& r) {
    const std::string destination = firstToken(r.addr);
    return destination == "0.0.0.0/0" || destination == "::/0";
}

/** 直译 prefixLen：substringAfter('/', "64") + toIntOrNull ?: 64 */
int prefixLen(const std::string& cidr) {
    const size_t slash = cidr.find('/');
    if (slash == std::string::npos) return 64; // 无前缀缺省 64（对齐 iOS）
    const std::string s = cidr.substr(slash + 1);
    size_t i = 0;
    bool neg = false;
    if (i < s.size() && (s[i] == '+' || s[i] == '-')) { // JVM parseInt 接受单前导符号
        neg = s[i] == '-';
        ++i;
    }
    if (i >= s.size()) return 64; // 空段/纯符号 → toIntOrNull null
    long long v = 0;
    for (; i < s.size(); ++i) {
        if (s[i] < '0' || s[i] > '9') return 64;
        v = v * 10 + (s[i] - '0');
        if (v > 2147483647LL) return 64; // Kotlin Int 越界 → null → 64
    }
    return int(neg ? -v : v);
}

/** 直译 ipOnly：substringBefore('/')；无 '/' 时整串即 IP；空结果以 nullopt 表达
 *  （Kotlin 返回 ""，下游解析必失败——提前失败语义等价） */
std::optional<std::string> ipOnly(const std::string& cidr) {
    const size_t slash = cidr.find('/');
    if (slash == std::string::npos) return cidr.empty() ? std::nullopt : std::optional<std::string>(cidr);
    if (slash == 0) return std::nullopt;
    return cidr.substr(0, slash);
}

} // namespace RoutePlanner
} // namespace pp
