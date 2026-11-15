// test_ndptable.cpp — NDP 邻居表/NS-NA 构造/伪头校验和/解析向量（Task 2）
//
// 直译源：tunnel/NdpTable.kt（上游修复版：链路层地址选项类型按报文分派，
// NS=SLL type 1、NA=TLL type 2，解析侧 NA 宽限收 1）。校验和期望值为手算
// 硬编码（RFC 1071 三种独立实现交叉验证一致：逐字求和 / 8-bit 交替位权和 /
// 逐步折叠），NA 向量按修复后载荷（选项字节 p[24]=2）计算。
#include "dataplane/NdpTable.h"
#include <gtest/gtest.h>

#include <string>

using namespace pp;

namespace {

Ipv6Address v6(const std::string& s) { return *parseIpv6(s); }

std::string hex(const std::vector<uint8_t>& b) {
    static const char* d = "0123456789abcdef";
    std::string s;
    for (uint8_t x : b) {
        s += d[x >> 4];
        s += d[x & 0xf];
    }
    return s;
}

// 回写校验和（对齐 FrameConverter.kt 调用方式）
void applyCksum(std::vector<uint8_t>& icmp, const Ipv6Address& src, const Ipv6Address& dst) {
    const uint16_t c = icmpv6Checksum(src, dst, icmp.data(), icmp.size());
    icmp[2] = uint8_t(c >> 8);
    icmp[3] = uint8_t(c & 0xff);
}

// 最小 IPv6 包（next header 58、hop limit 255，对齐 FrameConverter.ipv6Packet）
std::vector<uint8_t> ipv6Packet(const std::vector<uint8_t>& payload,
                                const Ipv6Address& src, const Ipv6Address& dst) {
    std::vector<uint8_t> p(40 + payload.size(), 0);
    p[0] = 0x60; // version 6
    p[4] = uint8_t((payload.size() >> 8) & 0xff);
    p[5] = uint8_t(payload.size() & 0xff);
    p[6] = 58; // next header = ICMPv6
    p[7] = 255; // hop limit
    std::copy(src.bytes.begin(), src.bytes.end(), p.begin() + 8);
    std::copy(dst.bytes.begin(), dst.bytes.end(), p.begin() + 24);
    std::copy(payload.begin(), payload.end(), p.begin() + 40);
    return p;
}

constexpr uint64_t kMac = 0x112233445566ULL;

} // namespace

// 场景①：NS 布局（总长 32、type=135、含 SLL 选项）
TEST(NdpTable, NeighborSolicitationLayout) {
    auto ns = neighborSolicitation(v6("fe80::1"), 0xAABBCCDDEEFFULL);
    ASSERT_EQ(ns.size(), 32u);
    EXPECT_EQ(ns[0], 135); // type
    EXPECT_EQ(ns[1], 0);   // code
    EXPECT_EQ(ns[2], 0);   // 校验和字段由调用方回写
    EXPECT_EQ(ns[3], 0);
    EXPECT_EQ(ns[4], 0); // NS flags 恒 0
    for (int i = 5; i < 8; ++i) EXPECT_EQ(ns[size_t(i)], 0); // 保留
    auto target = v6("fe80::1");
    for (int i = 0; i < 16; ++i) EXPECT_EQ(ns[size_t(8 + i)], target.bytes[size_t(i)]);
    EXPECT_EQ(ns[24], 1); // NS 携带源链路层地址选项（SLL type=1，选项类型按报文分派）
    EXPECT_EQ(ns[25], 1); // 选项长度=1（8 字节单位）
    const uint8_t want[6] = {0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF};
    for (int i = 0; i < 6; ++i) EXPECT_EQ(ns[size_t(26 + i)], want[i]); // MAC 大端
    EXPECT_EQ(hex(ns),
              "8700000000000000"      // type/code/cksum/flags+保留
              "fe800000000000000000000000000001" // target fe80::1
              "0101aabbccddeeff");    // SLL + MAC
}

// 场景②：NA flags=0x60（Solicited+Override 单播）与 0x20（仅 Override，DAD 组播形态）
TEST(NdpTable, NeighborAdvertisementFlags) {
    auto target = v6("fe80::1234:5678");
    auto naU = neighborAdvertisement(target, kMac, 0x60);
    ASSERT_EQ(naU.size(), 32u);
    EXPECT_EQ(naU[0], 136);
    EXPECT_EQ(naU[1], 0);
    EXPECT_EQ(naU[4], 0x60);
    // NA 携带目标链路层地址选项（type 2，RFC 4861 §4.6.2）——内核 ndisc 按类型
    // 读选项，误写 SLL(type 1) 的 NA 被真实内核丢弃（上游修复点）
    EXPECT_EQ(naU[24], 2);
    EXPECT_EQ(naU[25], 1); // 选项长度=1（8 字节单位）
    const uint8_t wantMac[6] = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66};
    for (int i = 0; i < 6; ++i) EXPECT_EQ(naU[size_t(26 + i)], wantMac[i]); // MAC 大端

    auto naD = neighborAdvertisement(target, kMac, 0x20);
    ASSERT_EQ(naD.size(), 32u);
    EXPECT_EQ(naD[0], 136);
    EXPECT_EQ(naD[4], 0x20);
    EXPECT_EQ(naD[24], 2); // DAD 组播形态同样携带目标选项 type 2

    // 缺省 flags 对齐 Kotlin solicited=true 的 0x60
    auto naDefault = neighborAdvertisement(target, kMac);
    EXPECT_EQ(naDefault[4], 0x60);
    EXPECT_EQ(naDefault[24], 2);
}

// 场景③：请求节点组播 ff02::1:ffXX:XXXX（取 target 低 24 位）
TEST(NdpTable, SolicitedNodeMulticast) {
    auto m = solicitedNodeMulticast(v6("fe80::1234:5678"));
    EXPECT_EQ(formatV6(m), "ff02::1:ff34:5678");
    EXPECT_EQ(m, v6("ff02::1:ff34:5678"));
    // 非 fe80 前缀同样只取低 24 位
    auto m2 = solicitedNodeMulticast(v6("2001:db8::abcd:ef01"));
    EXPECT_EQ(formatV6(m2), "ff02::1:ffcd:ef01");
}

// 场景④：组播 MAC（0x3333 + 低 32 位）
TEST(NdpTable, MulticastMAC) {
    auto mac = multicastMAC(v6("ff02::1:ff34:5678"));
    EXPECT_EQ(mac >> 32, uint64_t(0x3333)); // 高 16 位恒 0x3333
    EXPECT_EQ(mac & 0xffffffffULL, uint64_t(0xff345678)); // 低 32 位 = 地址低 32 位
    EXPECT_EQ(mac, 0x3333ff345678ULL);
    // 全节点组播（直译字节 …01）→ 低 32 位 0x00000001
    EXPECT_EQ(multicastMAC(allNodesMulticast()), 0x333300000001ULL);
}

// allNodesMulticast 直译字节固化：Kotlin 仅置 it[1]=0x02、it[15]=0x01（漏设
// it[0]=0xff），所得地址为 2::1 而非其注释所称 ff02::1——按行为规格唯一来源
// 原样复现，此处锁定字节防回归/防「顺手修正」
TEST(NdpTable, AllNodesMulticastLiteralBytes) {
    auto m = allNodesMulticast();
    const uint8_t want[16] = {0x00, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01};
    for (int i = 0; i < 16; ++i) EXPECT_EQ(m.bytes[size_t(i)], want[i]);
    EXPECT_EQ(formatV6(m), "2::1");
}

// 场景⑤：ICMPv6 伪头校验和（期望值手算硬编码）。NA 期望值按修复后载荷计算
// ——选项字节 p[24]=2（目标选项）参与求和，与修复前 type 1 的旧值（0xaffa/
// 0xee79/0x05a8）不同
TEST(NdpTable, Icmpv6Checksum) {
    // NS：src=本机地址 fe80::1，dst=请求节点组播（RFC 4861 出站形态；NS 选项
    // 仍为 SLL type 1，期望值不受分派修复影响）
    auto target = v6("fe80::1234:5678");
    auto src = v6("fe80::1");
    auto dst = solicitedNodeMulticast(target);
    auto ns = neighborSolicitation(target, kMac);
    EXPECT_EQ(icmpv6Checksum(src, dst, ns.data(), ns.size()), uint16_t(0x2377));

    // NA 单播形态：src=被解析的本机地址（=target），dst=请求方 fe80::1
    auto naU = neighborAdvertisement(target, kMac, 0x60);
    EXPECT_EQ(icmpv6Checksum(target, v6("fe80::1"), naU.data(), naU.size()),
              uint16_t(0xaefa));

    // NA DAD 组播形态：dst=allNodesMulticast（直译字节 2::1，见
    // AllNodesMulticastLiteralBytes——期望值按该真实伪头手算，等于 Android
    // 实际发出的校验和）
    auto naD = neighborAdvertisement(target, kMac, 0x20);
    EXPECT_EQ(icmpv6Checksum(target, allNodesMulticast(), naD.data(), naD.size()),
              uint16_t(0xed79));

    // 校验和字段预填垃圾值不影响结果（计算前逻辑清零）
    auto nsDirty = ns;
    nsDirty[2] = 0xaa;
    nsDirty[3] = 0x55;
    EXPECT_EQ(icmpv6Checksum(src, dst, nsDirty.data(), nsDirty.size()), uint16_t(0x2377));

    // 奇数长度载荷：尾字节补零成字（29B = NA 前 29 字节，含目标选项头 2 字节）
    std::vector<uint8_t> odd(naU.begin(), naU.begin() + 29);
    EXPECT_EQ(icmpv6Checksum(target, v6("fe80::1"), odd.data(), odd.size()),
              uint16_t(0x04a8));
}

// 场景⑤续：回写后整包十六进制固化（含校验和的完整 NA 载荷，选项 type=2）
TEST(NdpTable, NeighborAdvertisementWithChecksum) {
    auto target = v6("fe80::1234:5678");
    auto na = neighborAdvertisement(target, kMac, 0x60);
    applyCksum(na, target, v6("fe80::1"));
    EXPECT_EQ(hex(na),
              "8800aefa"                              // type(136=0x88)/code/cksum
              "60000000"                              // Solicited+Override + 保留
              "fe800000000000000000000012345678"      // target
              "0201112233445566");                    // TLL(type 2) + MAC
}

// 场景⑤续：回写后整包十六进制固化（含校验和的完整 NS 载荷）
TEST(NdpTable, NeighborSolicitationWithChecksum) {
    auto target = v6("fe80::1234:5678");
    auto src = v6("fe80::1");
    auto dst = solicitedNodeMulticast(target);
    auto ns = neighborSolicitation(target, kMac);
    applyCksum(ns, src, dst);
    EXPECT_EQ(hex(ns),
              "8700237700000000"                       // type/code/cksum/flags+保留
              "fe800000000000000000000012345678"       // target
              "0101112233445566");                     // SLL + MAC
}

// 解析侧选项类型分派（上游修复版语义）：NA 认目标选项(2)并宽限收 1（兼容仍按
// 未修复构造发 type 1 的软件姊妹端）；NS 只认源选项(1)。类型错配时报文仍解析
// 成功、仅 senderMac 保持空（对齐源，不因选项类型拒绝整包）
TEST(NdpTable, ParseNdpOptionTypeDispatch) {
    auto target = v6("fe80::1234:5678");

    // 内核标准 NA：目标选项 type=2 → 解析出 MAC
    auto na = neighborAdvertisement(target, kMac, 0x60);
    ASSERT_EQ(na[24], 2);
    auto p = parseNdp(na.data(), na.size());
    ASSERT_TRUE(p);
    EXPECT_EQ(p->type, 136);
    EXPECT_EQ(p->target, target);
    ASSERT_TRUE(p->senderMac);
    EXPECT_EQ(*p->senderMac, kMac);

    // 旧式 NA（未修复姊妹端发源选项 type=1，宽限）→ 同样解析出 MAC
    auto naLegacy = na;
    naLegacy[24] = 1;
    auto pLegacy = parseNdp(naLegacy.data(), naLegacy.size());
    ASSERT_TRUE(pLegacy);
    ASSERT_TRUE(pLegacy->senderMac);
    EXPECT_EQ(*pLegacy->senderMac, kMac);

    // NA 选项长度非 1 → 选项视为不存在（senderMac 空，报文仍成功）
    auto naBadLen = na;
    naBadLen[25] = 2;
    auto pBadLen = parseNdp(naBadLen.data(), naBadLen.size());
    ASSERT_TRUE(pBadLen);
    EXPECT_FALSE(pBadLen->senderMac);

    // NS 误带目标选项 type=2 → 拒绝取 MAC，报文仍解析成功
    auto nsWrong = neighborSolicitation(target, kMac);
    nsWrong[24] = 2;
    auto pWrong = parseNdp(nsWrong.data(), nsWrong.size());
    ASSERT_TRUE(pWrong);
    EXPECT_EQ(pWrong->type, 135);
    EXPECT_EQ(pWrong->target, target);
    EXPECT_FALSE(pWrong->senderMac);
}

// 场景⑥：parseNdp 往返 + 截断/非法拒绝
TEST(NdpTable, ParseNdpRoundTrip) {
    auto target = v6("fe80::1234:5678");
    auto ns = neighborSolicitation(target, kMac);
    applyCksum(ns, v6("fe80::1"), solicitedNodeMulticast(target));
    auto p = parseNdp(ns.data(), ns.size());
    ASSERT_TRUE(p);
    EXPECT_EQ(p->type, 135);
    EXPECT_EQ(p->target, target);
    ASSERT_TRUE(p->senderMac);
    EXPECT_EQ(*p->senderMac, kMac);

    // 回写校验和不改变解析结果（parse 不参与校验；NdpPacket 无 ==，逐字段比）
    auto p2 = parseNdp(neighborSolicitation(target, kMac).data(), 32);
    ASSERT_TRUE(p2);
    EXPECT_EQ(p2->type, p->type);
    EXPECT_EQ(p2->target, p->target);
    EXPECT_EQ(p2->senderMac, p->senderMac);

    // 23B 截断 → nullopt
    EXPECT_EQ(parseNdp(ns.data(), 23), std::nullopt);
    // 24B（无 SLL 选项）→ target 可解析、senderMac 为空
    auto p3 = parseNdp(ns.data(), 24);
    ASSERT_TRUE(p3);
    EXPECT_EQ(p3->target, target);
    EXPECT_FALSE(p3->senderMac);
    // 非 NDP type（ICMPv6 Echo Request=128）→ nullopt
    std::vector<uint8_t> echo(32, 0);
    echo[0] = 128;
    EXPECT_EQ(parseNdp(echo.data(), echo.size()), std::nullopt);
    // 31B：SLL 头在但 MAC 不全 → 选项视为不存在（Kotlin 要求 size>=32）
    auto p4 = parseNdp(ns.data(), 31);
    ASSERT_TRUE(p4);
    EXPECT_FALSE(p4->senderMac);
}

// 场景⑦：全零校验和的 NA 也能 parse（parse 不验校验和——内核已验，对齐 Android；
// 此处 NA 选项为目标选项 type 2，等同内核标准 NA 的解析路径）
TEST(NdpTable, ParseNdpIgnoresChecksum) {
    auto target = v6("fe80::1234:5678");
    auto na = neighborAdvertisement(target, kMac, 0x60); // cksum 字段恒 0
    EXPECT_EQ(na[2], 0);
    EXPECT_EQ(na[3], 0);
    EXPECT_EQ(na[24], 2);
    auto p = parseNdp(na.data(), na.size());
    ASSERT_TRUE(p);
    EXPECT_EQ(p->type, 136);
    EXPECT_EQ(p->target, target);
    ASSERT_TRUE(p->senderMac);
    EXPECT_EQ(*p->senderMac, kMac);
}

// isNDP：next header==58 且 ICMPv6 type 135/136（完整 IPv6 包）
TEST(NdpTable, IsNDP) {
    auto target = v6("fe80::1234:5678");
    auto src = v6("fe80::1");
    auto ns = neighborSolicitation(target, kMac);
    auto pkt = ipv6Packet(ns, src, solicitedNodeMulticast(target));
    ASSERT_EQ(pkt.size(), 72u); // 40 + 32
    EXPECT_TRUE(isNDP(pkt));

    auto na = neighborAdvertisement(target, kMac, 0x60);
    EXPECT_TRUE(isNDP(ipv6Packet(na, target, src)));

    // TCP（next header 6）→ false
    auto tcp = pkt;
    tcp[6] = 6;
    EXPECT_FALSE(isNDP(tcp));
    // ICMPv6 Echo（type 128）→ false
    std::vector<uint8_t> echo(8, 0);
    echo[0] = 128;
    EXPECT_FALSE(isNDP(ipv6Packet(echo, src, target)));
    // 47B 截断（IPv6 头 40 + 7）→ false
    EXPECT_FALSE(isNDP(std::vector<uint8_t>(pkt.begin(), pkt.begin() + 47)));
    EXPECT_FALSE(isNDP(std::vector<uint8_t>(40, 0)));
}

// 邻居表实例行为（Kotlin lookup/update/count）
TEST(NdpTable, LookupUpdateCount) {
    NdpTable t;
    EXPECT_EQ(t.size(), 0u);
    EXPECT_EQ(t.lookup(v6("fe80::1")), std::nullopt);

    t.update(v6("fe80::1"), 0xAABBCCDDEEFFULL);
    EXPECT_EQ(t.size(), 1u);
    ASSERT_TRUE(t.lookup(v6("fe80::1")));
    EXPECT_EQ(*t.lookup(v6("fe80::1")), 0xAABBCCDDEEFFULL);

    // 按内容判等：展开形式与缩写形式命中同一表项
    t.update(v6("fe80:0000:0000:0000:0000:0000:0000:0002"), 0x2ULL);
    EXPECT_EQ(t.size(), 2u);
    ASSERT_TRUE(t.lookup(v6("fe80::2")));
    EXPECT_EQ(*t.lookup(v6("fe80::2")), 0x2ULL);

    // 同地址覆盖不增项
    t.update(v6("fe80::1"), 0x1ULL);
    EXPECT_EQ(t.size(), 2u);
    ASSERT_TRUE(t.lookup(v6("fe80::1")));
    EXPECT_EQ(*t.lookup(v6("fe80::1")), 0x1ULL);
}
