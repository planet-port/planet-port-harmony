// test_routeplanner.cpp — RoutePlanner 直译向量（A2 计划 Task 5 brief 五场景 + CIDR 换算）
//
// 场景⑤（physicalOnLinkPrefixes）依赖 host 真实接口（getifaddrs 在 macOS 返回
// lo0/en0……），要求宿主机 en0 存在 IPv4 地址——macOS 开发机恒成立。
#include "dataplane/RoutePlanner.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <cstring>
#include <net/if.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <optional>
#include <set>
#include <string>
#include <vector>

using namespace pp;

namespace {

/** "a.b.c.d/p" → IPPrefix（bytes 取 IP 原字节，不掩网络位——对齐 Kotlin IPPrefix 语义） */
IPPrefix v4Prefix(const std::string& cidr) {
    const size_t slash = cidr.find('/');
    const std::string ip = slash == std::string::npos ? cidr : cidr.substr(0, slash);
    const int len = slash == std::string::npos ? 32 : std::stoi(cidr.substr(slash + 1));
    const std::optional<uint32_t> v = parseIpv4(ip);
    IPPrefix p;
    if (!v) {
        ADD_FAILURE() << "测试向量非法: " << cidr;
        return p;
    }
    p.bytes = {uint8_t(*v >> 24), uint8_t(*v >> 16), uint8_t(*v >> 8), uint8_t(*v & 0xff)};
    p.length = len;
    return p;
}

/** "x::y/p" → IPPrefix（同上，16 字节） */
IPPrefix v6Prefix(const std::string& cidr) {
    const size_t slash = cidr.find('/');
    const std::string ip = slash == std::string::npos ? cidr : cidr.substr(0, slash);
    const int len = slash == std::string::npos ? 128 : std::stoi(cidr.substr(slash + 1));
    const std::optional<Ipv6Address> v = parseIpv6(ip);
    IPPrefix p;
    if (!v) {
        ADD_FAILURE() << "测试向量非法: " << cidr;
        return p;
    }
    p.bytes.assign(v->bytes.begin(), v->bytes.end());
    p.length = len;
    return p;
}

/** 前缀集合是否包含给定地址前缀（并集覆盖性采样用） */
bool covered(const std::vector<IPPrefix>& ps, const IPPrefix& addr) {
    for (const IPPrefix& p : ps)
        if (p.contains(addr)) return true;
    return false;
}

/** IPPrefix → "网络地址/前缀" 串（与实现同一格式化口径：dottedV4/formatV6） */
std::string cidrOf(const IPPrefix& p) {
    if (p.bytes.size() == 4) {
        uint32_t v = 0;
        for (uint8_t b : p.bytes) v = (v << 8) | b;
        return dottedV4(v) + "/" + std::to_string(p.length);
    }
    Ipv6Address a;
    for (size_t i = 0; i < p.bytes.size() && i < 16; ++i) a.bytes[i] = p.bytes[i];
    return formatV6(a) + "/" + std::to_string(p.length);
}

/** 测试侧独立掩码实现（bit ∈ [prefix, 位数) 清零），用于交叉验证实现已掩网络位 */
std::vector<uint8_t> maskedBytes(std::vector<uint8_t> in, int prefix) {
    const int total = int(in.size()) * 8;
    for (int bit = prefix < 0 ? 0 : prefix; bit < total; ++bit)
        in[static_cast<size_t>(bit / 8)] &= uint8_t(~(1 << (7 - bit % 8)));
    return in;
}

/** ifa_netmask → 前缀长度（连续前导 1）；测试侧独立实现 */
int testNetmaskPrefix(const sockaddr* nm, int family) {
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
    for (size_t i = 0; i < n; ++i)
        for (int b = 7; b >= 0; --b) {
            if (p[i] & (1u << b)) {
                if (zeroSeen) return -1;
                ++prefix;
            } else {
                zeroSeen = true;
            }
        }
    return prefix;
}

/** 独立 getifaddrs 扫描：按名前缀取首个物理接口的 on-link v4 网段（场景⑤交叉验证用） */
std::optional<IPPrefix> firstPhysicalV4Network(const char* namePrefix) {
    struct ifaddrs* list = nullptr;
    if (getifaddrs(&list) != 0) return std::nullopt;
    std::optional<IPPrefix> found;
    for (struct ifaddrs* ia = list; ia && !found; ia = ia->ifa_next) {
        if (!ia->ifa_name || !ia->ifa_addr || ia->ifa_addr->sa_family != AF_INET) continue;
        if (!(ia->ifa_flags & IFF_UP) || (ia->ifa_flags & IFF_LOOPBACK)) continue;
        if (std::strncmp(ia->ifa_name, namePrefix, std::strlen(namePrefix)) != 0) continue;
        const int prefix = testNetmaskPrefix(ia->ifa_netmask, AF_INET);
        if (prefix <= 0) continue;
        std::vector<uint8_t> b(4);
        std::memcpy(b.data(), &reinterpret_cast<const sockaddr_in*>(ia->ifa_addr)->sin_addr, 4);
        found = IPPrefix{maskedBytes(b, prefix), prefix};
    }
    freeifaddrs(list);
    return found;
}

} // namespace

// ---- 场景①：0.0.0.0/0 挖去 192.168.1.0/24 —— 差集二叉分解 ----
TEST(RoutePlanner, ExpandV4DefaultRouteMinusHole) {
    const IPPrefix hole = v4Prefix("192.168.1.0/24");
    const std::vector<IPPrefix> out =
        RoutePlanner::expandV4(RouteEntry{std::string("0.0.0.0/0"), 0}, {hole});

    // /0 下钻到 /24 每层恰好产出一个兄弟前缀 → 共 24 个，长度 ∈ [1,24]
    ASSERT_EQ(out.size(), 24u);
    for (const IPPrefix& p : out) {
        EXPECT_GT(p.length, 0);
        EXPECT_LE(p.length, 24);
        EXPECT_EQ(p.bytes.size(), 4u);
        EXPECT_FALSE(p.contains(hole)) << cidrOf(p); // 无一输出包含 hole
    }

    // 输出互不相交（等长 contains 即全等）
    for (size_t i = 0; i < out.size(); ++i)
        for (size_t j = i + 1; j < out.size(); ++j) {
            EXPECT_FALSE(out[i].contains(out[j])) << cidrOf(out[i]) << " vs " << cidrOf(out[j]);
            EXPECT_FALSE(out[j].contains(out[i])) << cidrOf(out[j]) << " vs " << cidrOf(out[i]);
        }

    // 精确值：0.0.0.0/1（hole 首位 1，左半整体保留）；最深层的兄弟 = 192.168.0.0/24
    // （hole 第 23 位 = 1，兄弟翻转该位为 0，即 192.168.1.0/24 的相邻 /24）
    EXPECT_NE(std::find(out.begin(), out.end(), v4Prefix("0.0.0.0/1")), out.end());
    EXPECT_EQ(std::find(out.begin(), out.end(), v4Prefix("128.0.0.0/1")), out.end());
    EXPECT_NE(std::find(out.begin(), out.end(), v4Prefix("192.168.0.0/24")), out.end());

    // 并集覆盖性采样 = 全空间减 hole
    EXPECT_FALSE(covered(out, v4Prefix("192.168.1.5/32")));       // hole 内不覆盖
    EXPECT_FALSE(covered(out, hole));                             // hole 前缀本身不覆盖
    EXPECT_TRUE(covered(out, v4Prefix("8.8.8.8/32")));
    EXPECT_TRUE(covered(out, v4Prefix("192.168.2.1/32")));        // 同 /16 相邻 /24
    EXPECT_TRUE(covered(out, v4Prefix("192.168.0.1/32")));
    EXPECT_TRUE(covered(out, v4Prefix("0.0.0.0/32")));
    EXPECT_TRUE(covered(out, v4Prefix("255.255.255.255/32")));
    EXPECT_TRUE(covered(out, v4Prefix("10.147.20.97/32")));
}

// ---- 场景②：无 holes → 原样单元素 ----
TEST(RoutePlanner, ExpandV4NoHolesIdentity) {
    const std::vector<IPPrefix> out =
        RoutePlanner::expandV4(RouteEntry{std::string("192.168.1.1/24"), 24}, {});
    ASSERT_EQ(out.size(), 1u);
    EXPECT_EQ(out[0], v4Prefix("192.168.1.1/24")); // bytes 不掩网络位（对齐 Kotlin）

    // " via 网关" 形式：取首空格前目的段
    const std::vector<IPPrefix> via = RoutePlanner::expandV4(
        RouteEntry{std::string("10.0.0.5/32 via 192.168.1.1"), 32}, {});
    ASSERT_EQ(via.size(), 1u);
    EXPECT_EQ(via[0], v4Prefix("10.0.0.5/32"));

    // addr 未带 "/p"：用 RouteEntry.prefix
    const std::vector<IPPrefix> bare =
        RoutePlanner::expandV4(RouteEntry{std::string("192.168.1.7"), 16}, {});
    ASSERT_EQ(bare.size(), 1u);
    EXPECT_EQ(bare[0].length, 16);
    EXPECT_EQ(bare[0], v4Prefix("192.168.1.7/16"));

    // 族门禁/解析失败 → 空
    EXPECT_TRUE(RoutePlanner::expandV4(RouteEntry{std::string("::/0"), 0}, {}).empty());
    EXPECT_TRUE(RoutePlanner::expandV4(RouteEntry{std::string("not-an-ip/24"), 24}, {}).empty());
}

// ---- 场景③：split 两半互斥且并集=父 ----
TEST(RoutePlanner, SplitHalvesPartitionParent) {
    const IPPrefix parent = v4Prefix("192.168.1.0/24");
    const std::pair<IPPrefix, IPPrefix> halves = parent.split();
    EXPECT_EQ(halves.first, v4Prefix("192.168.1.0/25"));
    EXPECT_EQ(halves.second, v4Prefix("192.168.1.128/25"));
    EXPECT_FALSE(halves.first.contains(halves.second)); // 互斥
    EXPECT_FALSE(halves.second.contains(halves.first));
    EXPECT_TRUE(parent.contains(halves.first));         // 均被父包含
    EXPECT_TRUE(parent.contains(halves.second));
    EXPECT_EQ(halves.first.length, 25);
    EXPECT_EQ(halves.second.length, 25);

    // 并集=父：父内采样地址恰被一半包含，且不在父内的地址两半都不含
    for (const char* ip :
         {"192.168.1.0", "192.168.1.127", "192.168.1.128", "192.168.1.255", "192.168.1.77"}) {
        const IPPrefix a = v4Prefix(std::string(ip) + "/32");
        EXPECT_NE(covered({halves.first}, a), covered({halves.second}, a)) << ip;
        EXPECT_TRUE(covered({halves.first, halves.second}, a)) << ip;
    }
    for (const char* ip : {"192.168.0.1", "192.168.2.1", "10.0.0.1"}) {
        const IPPrefix a = v4Prefix(std::string(ip) + "/32");
        EXPECT_FALSE(covered({halves.first, halves.second}, a)) << ip;
    }

    // v6 同构：fe80::/10 翻转第 9 位（byte1 bit5）→ fe80::/11 + fea0::/11
    const IPPrefix p6 = v6Prefix("fe80::/10");
    const std::pair<IPPrefix, IPPrefix> h6 = p6.split();
    EXPECT_EQ(h6.first, v6Prefix("fe80::/11"));
    EXPECT_EQ(h6.second, v6Prefix("fea0::/11"));
    EXPECT_TRUE(p6.contains(h6.first));
    EXPECT_TRUE(p6.contains(h6.second));
}

// ---- 场景④：isDefaultRoute 两侧族 ----
TEST(RoutePlanner, IsDefaultRoute) {
    EXPECT_TRUE(RoutePlanner::isDefaultRoute(RouteEntry{std::string("0.0.0.0/0"), 0}));
    EXPECT_TRUE(RoutePlanner::isDefaultRoute(RouteEntry{std::string("::/0"), 0}));
    EXPECT_TRUE(RoutePlanner::isDefaultRoute(RouteEntry{std::string("0.0.0.0/0 via 10.0.0.1"), 0}));
    EXPECT_TRUE(RoutePlanner::isDefaultRoute(RouteEntry{std::string("::/0 via fe80::1"), 0}));
    EXPECT_FALSE(RoutePlanner::isDefaultRoute(RouteEntry{std::string("10.0.0.0/8"), 8}));
    EXPECT_FALSE(RoutePlanner::isDefaultRoute(RouteEntry{std::string("::/1"), 1}));
    EXPECT_FALSE(RoutePlanner::isDefaultRoute(RouteEntry{std::string("0.0.0.0/1"), 1}));
}

// ---- 场景⑤：host 物理网段枚举（macOS 必含 en0 网段、不含 lo0 127/8） ----
TEST(RoutePlanner, PhysicalOnLinkPrefixes4OnHost) {
    const std::vector<IPPrefix> out = RoutePlanner::physicalOnLinkPrefixes4({});
    ASSERT_FALSE(out.empty()) << "host 物理网段枚举不应为空（en0）";

    std::set<std::string> cidrs;
    for (const IPPrefix& p : out) {
        EXPECT_GT(p.length, 0);                                    // 点对点/无效前缀已丢弃
        EXPECT_EQ(p.bytes.size(), 4u);
        EXPECT_EQ(p.bytes, maskedBytes(p.bytes, p.length));        // 已掩到网络位
        EXPECT_NE(p.bytes[0], 127);                                // 无 lo0（127.0.0.0/8）
        EXPECT_TRUE(cidrs.insert(cidrOf(p)).second);               // 无重复网段
    }

    // 必含 en0 网段（测试侧独立 getifaddrs 交叉验证）
    const std::optional<IPPrefix> en0 = firstPhysicalV4Network("en");
    ASSERT_TRUE(en0) << "宿主机缺 en0 IPv4 地址，场景⑤前提不成立";
    EXPECT_NE(cidrs.find(cidrOf(*en0)), cidrs.end()) << "en0 网段: " << cidrOf(*en0);

    // excludingNetworksOf：与 ZT 分配地址同段跳过（恰移除该网段一条）
    const std::vector<IPPrefix> out2 = RoutePlanner::physicalOnLinkPrefixes4({*en0});
    std::set<std::string> cidrs2;
    for (const IPPrefix& p : out2) cidrs2.insert(cidrOf(p));
    EXPECT_EQ(cidrs2.find(cidrOf(*en0)), cidrs2.end());
    EXPECT_EQ(out2.size(), out.size() - 1);
}

// ---- 场景⑤补：v6 跳过 fe80::/10 链路本地 ----
TEST(RoutePlanner, PhysicalOnLinkPrefixes6SkipsLinkLocal) {
    const std::vector<IPPrefix> out = RoutePlanner::physicalOnLinkPrefixes6({});
    for (const IPPrefix& p : out) {
        EXPECT_GT(p.length, 0);
        EXPECT_EQ(p.bytes.size(), 16u);
        EXPECT_EQ(p.bytes, maskedBytes(p.bytes, p.length));
        // 无 fe80::/10 链路本地（本就不经默认路由）
        EXPECT_FALSE(p.bytes[0] == 0xfe && (p.bytes[1] & 0xc0) == 0x80) << cidrOf(p);
    }
}

// ---- expandV6：holes 同构差集分解 ----
TEST(RoutePlanner, ExpandV6MinusLinkLocal) {
    const IPPrefix hole = v6Prefix("fe80::/10");
    const std::vector<IPPrefix> out =
        RoutePlanner::expandV6(RouteEntry{std::string("::/0"), 0}, {hole});
    // /0 下钻到 /10 每层一个兄弟前缀 → 共 10 个
    ASSERT_EQ(out.size(), 10u);
    for (const IPPrefix& p : out) {
        EXPECT_EQ(p.bytes.size(), 16u);
        EXPECT_FALSE(p.contains(hole));
    }
    // 精确值：hole 在右半（fe80 首位 1），::/1 整体保留、8000::/1 被细分
    EXPECT_NE(std::find(out.begin(), out.end(), v6Prefix("::/1")), out.end());
    EXPECT_EQ(std::find(out.begin(), out.end(), v6Prefix("8000::/1")), out.end());

    // 并集覆盖性采样
    EXPECT_FALSE(covered(out, v6Prefix("fe80::1/128")));
    EXPECT_FALSE(covered(out, hole));
    EXPECT_TRUE(covered(out, v6Prefix("2001:db8::1/128")));
    EXPECT_TRUE(covered(out, v6Prefix("fec0::1/128"))); // fe80::/10 邻段（fec0::/10）
    EXPECT_TRUE(covered(out, v6Prefix("::1/128")));

    // 族门禁：v4 路由串进 expandV6 → 空
    EXPECT_TRUE(RoutePlanner::expandV6(RouteEntry{std::string("0.0.0.0/0"), 0}, {}).empty());
}

// ---- 差集边界：hole 吞掉 dest / 互不包含 / 多 hole 链式 ----
TEST(RoutePlanner, SubtractBoundariesAndMultiHoles) {
    // hole ⊇ dest → 整条路由被吞
    EXPECT_TRUE(
        RoutePlanner::expandV4(RouteEntry{std::string("192.168.1.0/24"), 24}, {v4Prefix("0.0.0.0/0")})
            .empty());
    EXPECT_TRUE(RoutePlanner::expandV4(RouteEntry{std::string("192.168.1.0/24"), 24},
                                       {v4Prefix("192.168.1.0/24")})
                    .empty());
    // hole ⊄ dest 且 dest ⊉ hole → dest 原样保留
    const std::vector<IPPrefix> sep =
        RoutePlanner::expandV4(RouteEntry{std::string("10.0.0.0/24"), 24}, {v4Prefix("192.168.1.0/24")});
    ASSERT_EQ(sep.size(), 1u);
    EXPECT_EQ(sep[0], v4Prefix("10.0.0.0/24"));
    // 多 hole 链式挖除（TunnelManager 同款调用形态）
    const std::vector<IPPrefix> multi = RoutePlanner::expandV4(
        RouteEntry{std::string("0.0.0.0/0"), 0},
        {v4Prefix("192.168.1.0/24"), v4Prefix("10.0.0.0/8")});
    EXPECT_FALSE(covered(multi, v4Prefix("10.20.30.40/32")));
    EXPECT_FALSE(covered(multi, v4Prefix("192.168.1.200/32")));
    EXPECT_FALSE(covered(multi, v4Prefix("10.0.0.5/32")));
    EXPECT_TRUE(covered(multi, v4Prefix("8.8.8.8/32")));
}

// ---- CIDR 换算：prefixLen / ipOnly ----
TEST(RoutePlanner, PrefixLenAndIpOnly) {
    EXPECT_EQ(RoutePlanner::prefixLen("fd00::/24"), 24);
    EXPECT_EQ(RoutePlanner::prefixLen("10.0.0.0/8"), 8);
    EXPECT_EQ(RoutePlanner::prefixLen("10.0.0.0/32"), 32);
    EXPECT_EQ(RoutePlanner::prefixLen("1.2.3.4"), 64);      // 无前缀缺省 64（对齐 iOS）
    EXPECT_EQ(RoutePlanner::prefixLen("fd00::"), 64);
    EXPECT_EQ(RoutePlanner::prefixLen("10.0.0.0/abc"), 64); // toIntOrNull 失败 → 64
    EXPECT_EQ(RoutePlanner::prefixLen("10.0.0.0/"), 64);    // 空段 → 64
    EXPECT_EQ(RoutePlanner::prefixLen("10.0.0.0/-4"), -4);  // 带符号直译（对齐 Kotlin）

    ASSERT_TRUE(RoutePlanner::ipOnly("10.0.0.5/24"));
    EXPECT_EQ(*RoutePlanner::ipOnly("10.0.0.5/24"), "10.0.0.5");
    ASSERT_TRUE(RoutePlanner::ipOnly("fd00::1/64"));
    EXPECT_EQ(*RoutePlanner::ipOnly("fd00::1/64"), "fd00::1");
    ASSERT_TRUE(RoutePlanner::ipOnly("10.0.0.5")); // 无 '/' 整串即 IP
    EXPECT_EQ(*RoutePlanner::ipOnly("10.0.0.5"), "10.0.0.5");
    EXPECT_EQ(RoutePlanner::ipOnly(""), std::nullopt);  // 空结果 → nullopt（Kotlin ""，下游解析必失败）
    EXPECT_EQ(RoutePlanner::ipOnly("/24"), std::nullopt);
}
