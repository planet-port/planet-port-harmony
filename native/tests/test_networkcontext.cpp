// test_networkcontext.cpp — NetworkContext + NetworkContextMath 向量（A2 Task 4）
//
// 对齐 brief 五场景：① update 二次调用保留 ARP/NDP/pending；② 聚合表前缀降序 +
// 同前缀先到者胜；③ 冲突检测（地址/网段/地址优先）；④ 路由解析（via/全零网关/
// 非法输入）；⑤ matches 边界（/24、/0、/32、/128）。
#include "dataplane/NetworkContext.h"

#include <gtest/gtest.h>

#include <initializer_list>
#include <string>
#include <tuple>
#include <vector>

using namespace pp;

namespace {

uint32_t v4(const char* s) { return parseIpv4(s).value_or(0); }

Ipv6Address v6(const char* s) { return parseIpv6(s).value_or(Ipv6Address{}); }

std::vector<std::string> S(std::initializer_list<const char*> l) {
    std::vector<std::string> out;
    for (const char* p : l) out.emplace_back(p);
    return out;
}

using ConflictInput =
    std::vector<std::tuple<uint64_t, const std::vector<std::string>*, const std::vector<std::string>*>>;

} // namespace

// ---- 场景 ①：update 仅刷新 MAC/地址/路由，ARP/NDP/pending 跨回调保留 ----

TEST(NetworkContext, UpdateKeepsArpNdpPending) {
    NetworkContext ctx(0x1111ULL, 0xaabbccddeeffULL, S({"10.0.0.5/24"}), S({"fd00::5/64"}), {});
    const uint32_t peer = v4("10.0.0.2");
    const Ipv6Address peer6 = v6("fd00::6");
    ctx.arp.update(peer, 0x112233445566ULL);
    ctx.ndp.update(peer6, 0x112233445566ULL);
    ctx.pendingV4->v4[peer].push_back({1, 2, 3});
    ctx.pendingV6->v6[peer6].push_back({4, 5});

    // 二次回调（MAC 变化模拟成员刷新）：整建重建会清缓存 → ARP 风暴 + 丢待决包
    ctx.update(0x99aabbccddeeffULL, S({"10.0.0.5/24"}), S({"fd00::5/64"}), {});

    EXPECT_EQ(ctx.mac, 0x99aabbccddeeffULL);
    ASSERT_TRUE(ctx.arp.lookup(peer));
    EXPECT_EQ(*ctx.arp.lookup(peer), 0x112233445566ULL);
    ASSERT_TRUE(ctx.ndp.lookup(peer6));
    EXPECT_EQ(*ctx.ndp.lookup(peer6), 0x112233445566ULL);
    EXPECT_EQ(ctx.pendingV4->total(), 1u);
    EXPECT_EQ(ctx.pendingV6->total(), 1u);
    ASSERT_EQ(ctx.pendingV4->v4[peer].size(), 1u);
    ASSERT_EQ(ctx.pendingV4->v4[peer][0].size(), 3u);
    EXPECT_EQ(ctx.pendingV4->v4[peer][0][2], 3);

    // 地址/路由照常刷新
    ASSERT_EQ(ctx.ipv4.size(), 1u);
    EXPECT_EQ(ctx.ipv4[0], v4("10.0.0.5"));
    ASSERT_EQ(ctx.ipv6.size(), 1u);
    EXPECT_EQ(ctx.ipv6[0], v6("fd00::5"));
    ASSERT_EQ(ctx.routes4.size(), 1u);
    EXPECT_EQ(ctx.routes4[0].prefix, 24);
    ASSERT_EQ(ctx.routes6.size(), 1u);
    EXPECT_EQ(ctx.routes6[0].prefix, 64);
}

TEST(NetworkContext, UpdateReplacesRoutesWithoutAccumulating) {
    NetworkContext ctx(1, 0xaabbccddeeffULL, S({"10.0.0.5/24"}), {}, S({"172.16.0.0/16 via 10.0.0.1"}));
    ASSERT_EQ(ctx.routes4.size(), 2u); // 自身网段 /24 + managed /16，降序
    EXPECT_EQ(ctx.routes4[0].prefix, 24);
    EXPECT_EQ(ctx.routes4[0].network, v4("10.0.0.0"));
    ASSERT_EQ(ctx.routes4[1].prefix, 16);
    ASSERT_TRUE(ctx.routes4[1].gateway);
    EXPECT_EQ(*ctx.routes4[1].gateway, v4("10.0.0.1"));

    // 二次回调 routes 清空：managed 路由消失，自身网段重建（全量替换不累积）
    ctx.update(0xaabbccddeeffULL, S({"10.0.0.5/24"}), {}, {});
    ASSERT_EQ(ctx.routes4.size(), 1u);
    EXPECT_EQ(ctx.routes4[0].network, v4("10.0.0.0"));
    EXPECT_EQ(ctx.routes4[0].prefix, 24);
    EXPECT_FALSE(ctx.routes4[0].gateway);

    // 裸地址无 '/'：prefixLen 缺省 64 → coerceAtMost(32) → /32 自身路由（对齐 Kotlin）
    ctx.update(0xaabbccddeeffULL, S({"10.9.0.7"}), {}, {});
    ASSERT_EQ(ctx.routes4.size(), 1u);
    EXPECT_EQ(ctx.routes4[0].network, v4("10.9.0.7"));
    EXPECT_EQ(ctx.routes4[0].prefix, 32);
}

TEST(NetworkContext, ConstructorDefaultsDiagnostics) {
    NetworkContext ctx(0xfeedULL, 1, S({"10.0.0.5/24"}), {}, {});
    EXPECT_EQ(ctx.nwid, 0xfeedULL);
    EXPECT_EQ(ctx.statFwdV4, 0u);
    EXPECT_EQ(ctx.statArpReq, 0u);
    EXPECT_EQ(ctx.statArpReply, 0u);
    EXPECT_EQ(ctx.statInV4, 0u);
    EXPECT_EQ(ctx.statKeepalive, 0u);
    EXPECT_EQ(ctx.statNatOut, 0u);
    EXPECT_EQ(ctx.statNatIn, 0u);
    EXPECT_EQ(ctx.statSrcMismatch, 0u);
    EXPECT_FALSE(ctx.lastSrcMismatch);
    EXPECT_FALSE(ctx.arp.lookup(v4("10.0.0.2")));
    EXPECT_EQ(ctx.arp.size(), 0u);
    EXPECT_EQ(ctx.ndp.size(), 0u);
    EXPECT_EQ(ctx.pendingV4->total(), 0u);
    EXPECT_EQ(ctx.pendingV6->total(), 0u);
}

// ---- 场景 ②：聚合表前缀降序、同前缀按激活顺序（先到者胜） ----

TEST(NetworkContext, BuildAggregateV4PrefixDescendingFirstWins) {
    NetworkContext a(0xAAAAULL, 1, S({"10.0.0.5/24"}), {}, S({"172.16.0.0/16 via 10.0.0.1"}));
    NetworkContext b(0xBBBBULL, 1, S({"10.0.1.6/24"}), {}, S({"10.9.0.0/24"}));
    NetworkContext c(0xCCCCULL, 1, {}, {}, {}); // 无地址无路由：不产出条目
    std::vector<const NetworkContext*> ordered{&a, &b, &c};
    const std::vector<AggregateV4Entry> agg = NetworkContextMath::buildAggregateV4(ordered);

    ASSERT_EQ(agg.size(), 4u);
    // 同前缀（24）三条：A 自身网段 → B 自身网段 → B managed，先到者在前
    EXPECT_EQ(agg[0].nwid, 0xAAAAULL);
    EXPECT_EQ(agg[0].route.network, v4("10.0.0.0"));
    EXPECT_EQ(agg[0].route.prefix, 24);
    EXPECT_FALSE(agg[0].route.gateway);
    EXPECT_EQ(agg[1].nwid, 0xBBBBULL);
    EXPECT_EQ(agg[1].route.network, v4("10.0.1.0"));
    EXPECT_EQ(agg[2].nwid, 0xBBBBULL);
    EXPECT_EQ(agg[2].route.network, v4("10.9.0.0"));
    // 更长前缀在前；网关随条目保留
    EXPECT_EQ(agg[3].nwid, 0xAAAAULL);
    EXPECT_EQ(agg[3].route.network, v4("172.16.0.0"));
    EXPECT_EQ(agg[3].route.prefix, 16);
    ASSERT_TRUE(agg[3].route.gateway);
    EXPECT_EQ(*agg[3].route.gateway, v4("10.0.0.1"));
    for (size_t i = 1; i < agg.size(); ++i)
        EXPECT_GE(agg[i - 1].route.prefix, agg[i].route.prefix) << "前缀必须降序 @" << i;
}

TEST(NetworkContext, BuildAggregateV6PrefixDescendingFirstWins) {
    NetworkContext a(1, 1, {}, S({"fd11::5/64"}), S({"fd22::/48 via fd11::1"}));
    NetworkContext b(2, 1, {}, S({"fd11::6/64"}), S({"fd33::/64"}));
    std::vector<const NetworkContext*> ordered{&a, &b};
    const std::vector<AggregateV6Entry> agg = NetworkContextMath::buildAggregateV6(ordered);

    ASSERT_EQ(agg.size(), 4u);
    EXPECT_EQ(agg[0].nwid, 1u);
    EXPECT_EQ(agg[0].route.network, v6("fd11::"));
    EXPECT_EQ(agg[0].route.prefix, 64);
    EXPECT_EQ(agg[1].nwid, 2u);
    EXPECT_EQ(agg[1].route.network, v6("fd11::"));
    EXPECT_EQ(agg[2].nwid, 2u);
    EXPECT_EQ(agg[2].route.network, v6("fd33::"));
    EXPECT_EQ(agg[3].nwid, 1u);
    EXPECT_EQ(agg[3].route.network, v6("fd22::"));
    EXPECT_EQ(agg[3].route.prefix, 48);
    ASSERT_TRUE(agg[3].route.gateway);
    EXPECT_EQ(*agg[3].route.gateway, v6("fd11::1"));
    for (size_t i = 1; i < agg.size(); ++i)
        EXPECT_GE(agg[i - 1].route.prefix, agg[i].route.prefix) << "前缀必须降序 @" << i;
}

// ---- 场景 ③：冲突检测（后进入者让路；地址冲突优先于网段冲突） ----

TEST(NetworkContext, DetectConflictsAddressAndSkipsRegistration) {
    auto n1 = S({"10.0.0.5/24"});
    auto n2 = S({"10.0.0.5/24", "192.168.50.7/24"});
    auto n3 = S({"192.168.50.8/24"});
    ConflictInput ordered{{1, &n1, nullptr}, {2, &n2, nullptr}, {3, &n3, nullptr}};
    const std::map<uint64_t, std::string> conflicts = NetworkContextMath::detectConflicts(ordered);

    ASSERT_EQ(conflicts.size(), 1u);
    EXPECT_EQ(conflicts.count(2), 1u);
    EXPECT_EQ(conflicts.at(2), std::string(NetworkContextMath::CONFLICT_ADDRESS));
    EXPECT_EQ(conflicts.count(1), 0u); // 先到者无冲突
    // n2 撞车后其地址/网段不登记 → n3（同 n2 的网段但不同 IP）不受牵连
    EXPECT_EQ(conflicts.count(3), 0u);
}

TEST(NetworkContext, DetectConflictsSubnet) {
    auto n1 = S({"10.0.0.5/24"});
    auto n2 = S({"10.0.0.6/24"}); // 同网段不同 IP
    ConflictInput ordered{{1, &n1, nullptr}, {2, &n2, nullptr}};
    const auto conflicts = NetworkContextMath::detectConflicts(ordered);
    ASSERT_EQ(conflicts.size(), 1u);
    EXPECT_EQ(conflicts.at(2), std::string(NetworkContextMath::CONFLICT_SUBNET));
}

TEST(NetworkContext, DetectConflictsIpv6AddressAndSubnet) {
    auto a1 = S({"fd00::5/64"});
    auto a2 = S({"fd00::5/64"}); // 同 v6 地址
    auto s2 = S({"fd00::6/64"}); // 同 v6 网段不同地址（掩网 fd00::/64）
    ConflictInput ordered{{1, nullptr, &a1}, {2, nullptr, &a2}};
    std::map<uint64_t, std::string> conflicts = NetworkContextMath::detectConflicts(ordered);
    ASSERT_EQ(conflicts.size(), 1u);
    EXPECT_EQ(conflicts.at(2), std::string(NetworkContextMath::CONFLICT_ADDRESS));

    ConflictInput ordered2{{1, nullptr, &a1}, {2, nullptr, &s2}};
    conflicts = NetworkContextMath::detectConflicts(ordered2);
    ASSERT_EQ(conflicts.size(), 1u);
    EXPECT_EQ(conflicts.at(2), std::string(NetworkContextMath::CONFLICT_SUBNET));
}

TEST(NetworkContext, DetectConflictsAddressWinsOverSubnet) {
    auto n1 = S({"10.0.0.5/24", "10.5.0.5/24"});
    auto n2 = S({"10.0.0.5/24", "10.5.0.6/24"}); // 同时撞地址(.5)与网段(10.5.0.0/24)
    ConflictInput ordered{{1, &n1, nullptr}, {2, &n2, nullptr}};
    const auto conflicts = NetworkContextMath::detectConflicts(ordered);
    ASSERT_EQ(conflicts.size(), 1u);
    EXPECT_EQ(conflicts.at(2), std::string(NetworkContextMath::CONFLICT_ADDRESS));
}

TEST(NetworkContext, DetectConflictsCrossFamilyAndGarbageClean) {
    auto v4only = S({"10.20.0.5/24"});
    auto v6only = S({"fd99::5/64"});
    auto garbage = S({"bogus/24"}); // 解析失败：映射为空，原样网段登记但不撞车
    ConflictInput ordered{{1, &v4only, nullptr}, {2, nullptr, &v6only}, {3, &garbage, nullptr}};
    const auto conflicts = NetworkContextMath::detectConflicts(ordered);
    EXPECT_TRUE(conflicts.empty());
}

// ---- 场景 ④：路由解析 ----

TEST(NetworkContext, ParseIPv4RouteViaGateway) {
    const auto r = NetworkContextMath::parseIPv4Route("10.0.0.0/24 via 10.0.0.1");
    ASSERT_TRUE(r);
    EXPECT_EQ(r->network, v4("10.0.0.0"));
    EXPECT_EQ(r->prefix, 24);
    ASSERT_TRUE(r->gateway);
    EXPECT_EQ(*r->gateway, v4("10.0.0.1"));
}

TEST(NetworkContext, ParseIPv4RouteZeroGatewayMeansNone) {
    const auto z = NetworkContextMath::parseIPv4Route("10.0.0.0/24 via 0.0.0.0");
    ASSERT_TRUE(z); // 目标仍解析成功
    EXPECT_EQ(z->network, v4("10.0.0.0"));
    EXPECT_EQ(z->prefix, 24);
    EXPECT_FALSE(z->gateway); // 全零网关归一为无网关（brief 约定）
}

TEST(NetworkContext, ParseIPv4RouteRejects) {
    const auto plain = NetworkContextMath::parseIPv4Route("10.0.0.0/24");
    ASSERT_TRUE(plain);
    EXPECT_FALSE(plain->gateway); // via 缺失 → 无网关

    EXPECT_FALSE(NetworkContextMath::parseIPv4Route(""));                  // 空串
    EXPECT_FALSE(NetworkContextMath::parseIPv4Route("10.0.0.5"));          // 无 '/'
    EXPECT_FALSE(NetworkContextMath::parseIPv4Route("10.0.0.0/33"));       // 前缀越界
    EXPECT_FALSE(NetworkContextMath::parseIPv4Route("10.0.0.0/-1"));       // 负前缀
    EXPECT_FALSE(NetworkContextMath::parseIPv4Route("10.0.0.0/abc"));      // 非数字前缀
    EXPECT_FALSE(NetworkContextMath::parseIPv4Route("10.0.0/24"));         // 地址段数不足
    EXPECT_FALSE(NetworkContextMath::parseIPv4Route("10.0.0.0/24/16")); // 多 '/'
    // via 后越位：条目有效、网关为空（Kotlin getOrNull(2) 为 null 的落点）
    const auto dangling = NetworkContextMath::parseIPv4Route("10.0.0.0/24 via");
    ASSERT_TRUE(dangling);
    EXPECT_EQ(dangling->network, v4("10.0.0.0"));
    EXPECT_EQ(dangling->prefix, 24);
    EXPECT_FALSE(dangling->gateway);
    const auto alien = NetworkContextMath::parseIPv4Route("10.0.0.0/24 via fd00::1");
    ASSERT_TRUE(alien); // 异族网关：目标保留、网关为空
    EXPECT_FALSE(alien->gateway);
}

TEST(NetworkContext, ParseIPv6Route) {
    const auto r = NetworkContextMath::parseIPv6Route("fd00::/64 via fe80::1");
    ASSERT_TRUE(r);
    EXPECT_EQ(r->network, v6("fd00::"));
    EXPECT_EQ(r->prefix, 64);
    ASSERT_TRUE(r->gateway);
    EXPECT_EQ(*r->gateway, v6("fe80::1"));

    const auto z = NetworkContextMath::parseIPv6Route("fd00::/64 via ::");
    ASSERT_TRUE(z);
    EXPECT_FALSE(z->gateway); // 全零网关归一为无网关

    const auto d = NetworkContextMath::parseIPv6Route("::/0");
    ASSERT_TRUE(d);
    EXPECT_EQ(d->prefix, 0);
    EXPECT_FALSE(d->gateway);

    EXPECT_FALSE(NetworkContextMath::parseIPv6Route("fd00::/129")); // 前缀越界
    EXPECT_FALSE(NetworkContextMath::parseIPv6Route("10.0.0.5/24")); // 无 ':' → 防 DNS 拒绝
}

// ---- 场景 ⑤：matches 边界 ----

TEST(NetworkContext, IPv4MatchesBoundaries) {
    const IPv4RouteEntry r24{v4("10.0.0.0"), 24, std::nullopt};
    EXPECT_TRUE(r24.matches(v4("10.0.0.0")));   // 网络号本身
    EXPECT_TRUE(r24.matches(v4("10.0.0.128"))); // 边界内
    EXPECT_TRUE(r24.matches(v4("10.0.0.255"))); // 广播地址
    EXPECT_FALSE(r24.matches(v4("10.0.1.0")));
    EXPECT_FALSE(r24.matches(v4("10.1.0.0")));

    const IPv4RouteEntry r0{0, 0, std::nullopt};
    EXPECT_TRUE(r0.matches(0)); // /0 恒真
    EXPECT_TRUE(r0.matches(v4("8.8.8.8")));
    EXPECT_TRUE(r0.matches(v4("255.255.255.255")));

    const IPv4RouteEntry r32{v4("10.0.0.7"), 32, std::nullopt};
    EXPECT_TRUE(r32.matches(v4("10.0.0.7"))); // /32 恒等
    EXPECT_FALSE(r32.matches(v4("10.0.0.8")));
}

TEST(NetworkContext, IPv6MatchesBoundaries) {
    const IPv6RouteEntry m32{v6("fd00:1234::"), 32, std::nullopt};
    EXPECT_TRUE(m32.matches(v6("fd00:1234::1")));
    EXPECT_TRUE(m32.matches(v6("fd00:1234:ffff::9")));
    EXPECT_FALSE(m32.matches(v6("fd00:1235::1")));

    const IPv6RouteEntry m0{Ipv6Address{}, 0, std::nullopt};
    EXPECT_TRUE(m0.matches(v6("2001:db8::1"))); // /0 恒真
    EXPECT_TRUE(m0.matches(v6("::")));

    const IPv6RouteEntry m128{v6("fe80::1"), 128, std::nullopt};
    EXPECT_TRUE(m128.matches(v6("fe80::1"))); // /128 恒等
    EXPECT_FALSE(m128.matches(v6("fe80::2")));

    // 位级边界：/9 只保留首字节最高位（0x80）
    const IPv6RouteEntry m9{v6("2001:db8::"), 9, std::nullopt};
    EXPECT_TRUE(m9.matches(v6("2001:ffff::1"))); // 首字节 0x20 → 掩后 0x00
    EXPECT_FALSE(m9.matches(v6("8000::1")));     // 首字节 0x80 → 掩后 0x80
}

// ---- ipOnly 与 PendingQueue ----

TEST(NetworkContext, IpOnly) {
    const auto a = NetworkContextMath::ipOnly("10.0.0.5/24");
    ASSERT_TRUE(a);
    EXPECT_EQ(*a, "10.0.0.5");
    const auto b = NetworkContextMath::ipOnly("10.0.0.5");
    ASSERT_TRUE(b);
    EXPECT_EQ(*b, "10.0.0.5"); // 无 '/' 返回原串
    const auto c = NetworkContextMath::ipOnly("fd00::5/64");
    ASSERT_TRUE(c);
    EXPECT_EQ(*c, "fd00::5");
    const auto d = NetworkContextMath::ipOnly("a/b/c");
    ASSERT_TRUE(d);
    EXPECT_EQ(*d, "a"); // substringBefore 首个 '/'
}

TEST(NetworkContext, PendingQueueTotal) {
    PendingQueue q;
    EXPECT_EQ(q.total(), 0u);
    q.v4[v4("10.0.0.2")].push_back({1});
    q.v4[v4("10.0.0.2")].push_back({2});
    q.v4[v4("10.0.0.3")].push_back({3});
    q.v6[v6("fd00::6")].push_back({4});
    EXPECT_EQ(q.total(), 4u); // 两族帧数合计
}
