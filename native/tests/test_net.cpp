// test_net.cpp — IP 解析/格式化向量（Task 0 地基）
#include "dataplane/Net.h"
#include <gtest/gtest.h>

using namespace pp;

TEST(Net, ParseIpv4Ok) {
    EXPECT_EQ(parseIpv4("192.168.1.1"), uint32_t(0xC0A80101u));
    EXPECT_EQ(parseIpv4("0.0.0.0"), uint32_t(0));
    EXPECT_EQ(parseIpv4("255.255.255.255"), uint32_t(0xFFFFFFFFu));
    EXPECT_EQ(parseIpv4("1.2.3.4"), uint32_t(0x01020304u));
}

TEST(Net, ParseIpv4Rejects) {
    EXPECT_EQ(parseIpv4("192.168.01.1"), std::nullopt); // 前导零
    EXPECT_EQ(parseIpv4("1.2.3"), std::nullopt);        // 段数不足
    EXPECT_EQ(parseIpv4("1.2.3.4.5"), std::nullopt);    // 段数超
    EXPECT_EQ(parseIpv4("256.1.1.1"), std::nullopt);    // 越界
    EXPECT_EQ(parseIpv4("1.2.3."), std::nullopt);       // 空尾段
    EXPECT_EQ(parseIpv4(".1.2.3"), std::nullopt);       // 空首段
    EXPECT_EQ(parseIpv4("1.2.3.a"), std::nullopt);      // 非数字
    EXPECT_EQ(parseIpv4(""), std::nullopt);
}

TEST(Net, DottedV4) {
    EXPECT_EQ(dottedV4(0xC0A80101u), "192.168.1.1");
    EXPECT_EQ(dottedV4(0), "0.0.0.0");
    EXPECT_EQ(dottedV4(0xFFFFFFFFu), "255.255.255.255");
}

TEST(Net, ParseIpv6Ok) {
    auto a = parseIpv6("::1");
    ASSERT_TRUE(a);
    EXPECT_EQ(a->bytes[15], 1); // 其余全零
    EXPECT_EQ(a->bytes[0], 0);

    auto b = parseIpv6("fe80::1");
    ASSERT_TRUE(b);
    EXPECT_EQ(b->bytes[0], 0xfe);
    EXPECT_EQ(b->bytes[1], 0x80);
    EXPECT_EQ(b->bytes[15], 1);

    auto c = parseIpv6("::ffff:192.168.1.1"); // 内嵌 IPv4 尾段
    ASSERT_TRUE(c);
    EXPECT_EQ(c->bytes[10], 0xff);
    EXPECT_EQ(c->bytes[11], 0xff);
    EXPECT_EQ(c->bytes[12], 192);
    EXPECT_EQ(c->bytes[15], 1);

    auto d = parseIpv6("2001:db8:85a3:0:0:8a2e:370:7334");
    ASSERT_TRUE(d);
    EXPECT_EQ(d->bytes[0], 0x20);
    EXPECT_EQ(d->bytes[1], 0x01);
    EXPECT_EQ(d->bytes[2], 0x0d);
    EXPECT_EQ(d->bytes[3], 0xb8);

    auto e = parseIpv6("::"); // 全零
    ASSERT_TRUE(e);
    for (auto x : e->bytes) EXPECT_EQ(x, 0);
}

TEST(Net, ParseIpv6Rejects) {
    EXPECT_EQ(parseIpv6("12345"), std::nullopt);        // 无 ':' —— 防 DNS 语义
    EXPECT_EQ(parseIpv6("192.168.1.1"), std::nullopt);  // 无 ':'
    EXPECT_EQ(parseIpv6(":::1"), std::nullopt);         // 多段 ::
    EXPECT_EQ(parseIpv6("1::2::3"), std::nullopt);
    EXPECT_EQ(parseIpv6("1:2:3:4:5:6:7:8:9"), std::nullopt); // 组数超
    EXPECT_EQ(parseIpv6("1:2:3:4:5:6:7"), std::nullopt);     // 无 :: 时不足 8 组
    EXPECT_EQ(parseIpv6(":1::2"), std::nullopt);        // 前导单冒号
    EXPECT_EQ(parseIpv6("1::2:"), std::nullopt);        // 尾随单冒号
    EXPECT_EQ(parseIpv6("1::2:zzzz"), std::nullopt);    // 非法 hex
}

TEST(Net, FormatV6) {
    Ipv6Address a{};
    a.bytes[15] = 1;
    EXPECT_EQ(formatV6(a), "::1");

    Ipv6Address b{};
    for (auto& x : b.bytes) x = 0;
    EXPECT_EQ(formatV6(b), "::");

    auto c = parseIpv6("2001:db8::8a2e:370:7334");
    ASSERT_TRUE(c);
    EXPECT_EQ(formatV6(*c), "2001:db8::8a2e:370:7334");

    Ipv6Address d{}; // 零 run 只在组 2-7（组 0=0x0100、组 1=0x0001）
    d.bytes[0] = 1;  // 组 0 = 0x0100 → "100"
    d.bytes[3] = 1;  // 组 1 = 0x0001 → "1"
    auto s = formatV6(d);
    EXPECT_EQ(s, "100:1::");
}

TEST(Net, Ipv6Equality) {
    auto a = parseIpv6("fe80::1");
    auto b = parseIpv6("fe80:0:0:0:0:0:0:1");
    ASSERT_TRUE(a && b);
    EXPECT_EQ(*a, *b); // 展开形式与缩写形式判等
    EXPECT_FALSE(*a < *b || b < *a);
}
