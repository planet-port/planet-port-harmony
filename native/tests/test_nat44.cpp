// test_nat44.cpp — NAT44 向量（A2 Task 3，直译源 tunnel/NAT44.kt）
//
// 场景对照（brief 八场景）：
//   ① TCP SYN outboundKey 字段 + rewriteAddress(12) RFC 1624 重算一致（硬编码十六进制）
//   ② UDP cksum=0 改写后仍 0
//   ③ UDP cksum≠0 改写后正确（含 RFC 768 zeroAsFFFF 覆盖 0xFFFF 位）
//   ④ 非首片（MF+片偏移≠0）只修 IP 头校验和
//   ⑤ inboundKey 是 outboundKey 的方向翻转
//   ⑥ UDP 流固定时钟 59s 命中 / 61s 未中（含 59999/60000 边界）
//   ⑦ TCP 流 6h 边界（21599999 命中 / 21600000 未中）
//   ⑧ 513 条流上限逐出（固定时钟，含「先淘汰过期再逐最旧」路径）
//
// 硬编码期望值推导（与实现无关的手工反码求和，测试内另用独立全量重算交叉验证）：
//   TCP SYN 包：IP 头 20B（0x45, len=40, id=0x1234, ttl=64, proto=6,
//     src=10.144.0.5, dst=45.79.100.1）+ TCP 20B（sport=50000, dport=443,
//     seq=0x11223344, flags=SYN, win=0xFFFF）。
//   原 IP 头校验和 = ~(0x4500+0x0028+0x1234+0x4006+0x0A90+0x0005+0x2D4F+0x6401)
//     = ~0x3348 = 0xCCB7
//   原 TCP 校验和（伪头含原源）= ~(0x9BFF + 0x5974) = ~0xF573 = 0x0A8C
//   源改写 10.144.0.5 → 10.147.20.7：m=0x0A95, m'=0x1E9A
//     IP：~0xCCB7+~0x0A95+0x1E9A = 0x474D → 校验和 0xB8B2
//     TCP：~0x0A8C+~0x0A95+0x1E9A = 0x0979 → 校验和 0xF686
#include "dataplane/NAT44.h"
#include <gtest/gtest.h>
#include <cstdint>
#include <vector>

using namespace pp;

namespace {

constexpr uint64_t kWid = 0x7654321ABCDEFULL;
constexpr uint32_t kOldSrc = 0x0A900005u; // 10.144.0.5（选错的源）
constexpr uint32_t kNewSrc = 0x0A931407u; // 10.147.20.7（网络地址）
constexpr uint32_t kDst = 0x2D4F6401u;    // 45.79.100.1

uint32_t fold32(uint32_t s) {
    while (s > 0xffffu) s = (s & 0xffffu) + (s >> 16);
    return s;
}

/** 独立实现的反码校验和（与 NAT44 增量路径互为交叉验证） */
uint16_t csum16(const std::vector<uint8_t>& d) {
    uint32_t s = 0;
    for (size_t i = 0; i + 1 < d.size(); i += 2) s += (uint32_t(d[i]) << 8) | d[i + 1];
    if (d.size() & 1) s += uint32_t(d.back()) << 8;
    return uint16_t((~fold32(s)) & 0xffffu);
}

size_t ihlOf(const std::vector<uint8_t>& p) { return size_t(p[0] & 0x0fu) * 4; }

/** 全量重算 IP 头校验和（校验和字段清零） */
uint16_t ipHeaderChecksum(const std::vector<uint8_t>& p) {
    std::vector<uint8_t> h(p.begin(), p.begin() + long(ihlOf(p)));
    h[10] = 0;
    h[11] = 0;
    return csum16(h);
}

/** 全量重算 L4 校验和：伪头（src/dst/proto/l4len）+ L4 段（校验和字段清零） */
uint16_t l4Checksum(const std::vector<uint8_t>& p, size_t ckOffInSeg) {
    const size_t ihl = ihlOf(p);
    const size_t total = (size_t(p[2]) << 8) | p[3];
    const size_t l4len = total - ihl;
    std::vector<uint8_t> buf;
    buf.reserve(12 + l4len);
    for (int i = 12; i < 20; ++i) buf.push_back(p[size_t(i)]); // src/dst
    buf.push_back(0);
    buf.push_back(p[9]); // proto
    buf.push_back(uint8_t(l4len >> 8));
    buf.push_back(uint8_t(l4len & 0xff));
    for (size_t i = 0; i < l4len; ++i) buf.push_back(p[ihl + i]);
    buf[12 + ckOffInSeg] = 0;
    buf[12 + ckOffInSeg + 1] = 0;
    return csum16(buf);
}

void put32(std::vector<uint8_t>& p, size_t o, uint32_t v) {
    p[o] = uint8_t(v >> 24);
    p[o + 1] = uint8_t((v >> 16) & 0xffu);
    p[o + 2] = uint8_t((v >> 8) & 0xffu);
    p[o + 3] = uint8_t(v & 0xffu);
}

void putIpHeader(std::vector<uint8_t>& p, uint8_t proto, uint16_t totalLen, uint16_t id = 0x1234) {
    p[0] = 0x45; // version 4 + IHL 5
    p[1] = 0x00; // TOS
    p[2] = uint8_t(totalLen >> 8);
    p[3] = uint8_t(totalLen & 0xffu);
    p[4] = uint8_t(id >> 8); // id
    p[5] = uint8_t(id & 0xffu);
    p[6] = 0x00; // flags+frag
    p[7] = 0x00;
    p[8] = 64; // TTL
    p[9] = proto;
    p[10] = 0x00; // 校验和占位
    p[11] = 0x00;
    put32(p, 12, kOldSrc);
    put32(p, 16, kDst);
}

/** 场景① TCP SYN：源=10.144.0.5（错源）→ 目的=45.79.100.1:443 */
std::vector<uint8_t> tcpSyn(uint16_t ipChecksum) {
    std::vector<uint8_t> p(40, 0);
    putIpHeader(p, 6, 40);
    p[10] = uint8_t(ipChecksum >> 8);
    p[11] = uint8_t(ipChecksum & 0xffu);
    p[20] = 0xC3; p[21] = 0x50; // sport 50000
    p[22] = 0x01; p[23] = 0xBB; // dport 443
    p[24] = 0x11; p[25] = 0x22; p[26] = 0x33; p[27] = 0x44; // seq
    p[32] = 0x50; // 数据偏移 5
    p[33] = 0x02; // SYN
    p[34] = 0xFF; p[35] = 0xFF; // window
    p[36] = 0x0A; p[37] = 0x8C; // TCP 校验和（伪头含原源 10.144.0.5）
    return p;
}

/** UDP 包：sport=40000, dport=53, len=8，cksum 由参数给定（id=0x2222） */
std::vector<uint8_t> udpPkt(uint16_t udpChecksum) {
    std::vector<uint8_t> p(28, 0);
    putIpHeader(p, 17, 28, 0x2222);
    p[10] = 0xBC; p[11] = 0xCA; // IP 头校验和（id=0x2222/proto=17 版本，手工求和）
    p[20] = 0x9C; p[21] = 0x40; // sport 40000
    p[22] = 0x00; p[23] = 0x35; // dport 53
    p[24] = 0x00; p[25] = 0x08; // UDP len
    p[26] = uint8_t(udpChecksum >> 8);
    p[27] = uint8_t(udpChecksum & 0xffu);
    return p;
}

/** ICMP echo request（proto=1，ICMP 校验和哨兵 0xABCD 不应被动） */
std::vector<uint8_t> icmpEcho() {
    std::vector<uint8_t> p(28, 0);
    putIpHeader(p, 1, 28);
    p[20] = 8; // type
    p[21] = 0; // code
    p[22] = 0xAB; p[23] = 0xCD; // ICMP 校验和哨兵
    p[24] = 0x00; p[25] = 0x01; // id
    p[26] = 0x00; p[27] = 0x0A; // seq
    return p;
}

/** 取包内校验和字段当前值 */
uint16_t read16At(const std::vector<uint8_t>& p, size_t o) {
    return uint16_t((uint16_t(p[o]) << 8) | p[o + 1]);
}

} // namespace

// ---- 场景①（流键部分）：出站流键字段 ----

TEST(Nat44, OutboundKeyTcpFields) {
    auto pkt = tcpSyn(0xCCB7);
    auto k = NAT44::outboundKey(pkt, kWid);
    ASSERT_TRUE(k.has_value());
    EXPECT_EQ(k->nwid, kWid);
    EXPECT_EQ(k->proto, 6);
    EXPECT_EQ(k->remoteIp, kDst);      // read32(16)
    EXPECT_EQ(k->remotePort, 443);     // read16(ihl+2)
    EXPECT_EQ(k->localPort, 50000);    // read16(ihl)
}

TEST(Nat44, OutboundKeyUdpFields) {
    auto pkt = udpPkt(0x0000);
    auto k = NAT44::outboundKey(pkt, kWid);
    ASSERT_TRUE(k.has_value());
    EXPECT_EQ(k->proto, 17);
    EXPECT_EQ(k->remoteIp, kDst);
    EXPECT_EQ(k->remotePort, 53);
    EXPECT_EQ(k->localPort, 40000);
}

TEST(Nat44, OutboundKeyRejectsNonV4ShortIcmpFragment) {
    // 非 IPv4 版本
    auto bad = tcpSyn(0xCCB7);
    bad[0] = 0x65;
    EXPECT_FALSE(NAT44::outboundKey(bad, kWid).has_value());
    // 过短（<24）
    std::vector<uint8_t> tiny(23, 0);
    tiny[0] = 0x45;
    EXPECT_FALSE(NAT44::outboundKey(tiny, kWid).has_value());
    // ICMP（非 TCP/UDP）
    auto icmp = icmpEcho();
    EXPECT_FALSE(NAT44::outboundKey(icmp, kWid).has_value());
    // 分片（MF 位置位）
    auto frag = udpPkt(0x0000);
    frag[6] = 0x20;
    frag[7] = 0x01;
    EXPECT_FALSE(NAT44::outboundKey(frag, kWid).has_value());
    // 24B 但 IHL=6（需 ihl+4=28 > 24）
    std::vector<uint8_t> opt(24, 0);
    opt[0] = 0x46;
    opt[9] = 6;
    EXPECT_FALSE(NAT44::outboundKey(opt, kWid).has_value());
}

TEST(Nat44, OutboundKeyHonorsIhlOptions) {
    // IHL=6（带选项）：端口从 ihl=24 起读
    std::vector<uint8_t> p(28, 0);
    p[0] = 0x46; // IHL 6
    p[2] = 0x00; p[3] = 28;
    p[8] = 64;
    p[9] = 6;
    put32(p, 12, kOldSrc);
    put32(p, 16, kDst);
    p[24] = 0xC3; p[25] = 0x50; // sport 50000（ihl）
    p[26] = 0x01; p[27] = 0xBB; // dport 443（ihl+2）
    auto k = NAT44::outboundKey(p, kWid);
    ASSERT_TRUE(k.has_value());
    EXPECT_EQ(k->localPort, 50000);
    EXPECT_EQ(k->remotePort, 443);
}

// ---- 场景⑤：入站流键方向翻转 ----

TEST(Nat44, InboundKeyFlipsDirection) {
    auto pkt = tcpSyn(0xCCB7);
    auto in = NAT44::inboundKey(pkt, kWid);
    auto out = NAT44::outboundKey(pkt, kWid);
    ASSERT_TRUE(in.has_value());
    ASSERT_TRUE(out.has_value());
    // 对端为源：remoteIp=src，remotePort=sport，localPort=dport
    EXPECT_EQ(in->nwid, kWid);
    EXPECT_EQ(in->proto, 6);
    EXPECT_EQ(in->remoteIp, kOldSrc);
    EXPECT_EQ(in->remotePort, 50000);
    EXPECT_EQ(in->localPort, 443);
    // 翻转关系：inbound 与 outbound 互换 remote/local
    EXPECT_EQ(in->remoteIp, kOldSrc);
    EXPECT_EQ(in->remotePort, out->localPort);
    EXPECT_EQ(in->localPort, out->remotePort);

    // 回包（源/目的、端口互换）的 outboundKey 与原包 inboundKey 相等
    std::vector<uint8_t> reply = tcpSyn(0xCCB7);
    put32(reply, 12, kDst);
    put32(reply, 16, kOldSrc);
    reply[20] = 0x01; reply[21] = 0xBB; // sport 443
    reply[22] = 0xC3; reply[23] = 0x50; // dport 50000
    auto rev = NAT44::outboundKey(reply, kWid);
    ASSERT_TRUE(rev.has_value());
    EXPECT_TRUE(*rev == *in);
}

TEST(Nat44, InboundKeyRejectsNonV4ShortIcmpFragment) {
    auto bad = tcpSyn(0xCCB7);
    bad[0] = 0x65;
    EXPECT_FALSE(NAT44::inboundKey(bad, kWid).has_value());
    std::vector<uint8_t> tiny(23, 0);
    tiny[0] = 0x45;
    EXPECT_FALSE(NAT44::inboundKey(tiny, kWid).has_value());
    EXPECT_FALSE(NAT44::inboundKey(icmpEcho(), kWid).has_value());
    auto frag = udpPkt(0x0000);
    frag[7] = 0x01; // 片偏移非零
    EXPECT_FALSE(NAT44::inboundKey(frag, kWid).has_value());
}

// ---- 场景①（改写部分）：RFC 1624 增量校验和（硬编码十六进制） ----

TEST(Nat44, RewriteSourceAddressTcpRfc1624) {
    auto pkt = tcpSyn(0xCCB7); // 原 IP 头校验和
    EXPECT_EQ(read16At(pkt, 10), 0xCCB7);
    EXPECT_EQ(read16At(pkt, 36), 0x0A8C); // 原 TCP 校验和（伪头含原源）

    ASSERT_TRUE(NAT44::rewriteAddress(pkt, 12, kOldSrc, kNewSrc));

    // 地址已写
    EXPECT_EQ((uint32_t(pkt[12]) << 24) | (uint32_t(pkt[13]) << 16) |
                  (uint32_t(pkt[14]) << 8) | pkt[15],
              kNewSrc);
    // 增量结果与手工向量一致
    EXPECT_EQ(read16At(pkt, 10), 0xB8B2);
    EXPECT_EQ(read16At(pkt, 36), 0xF686);
    // 与独立全量重算一致（IP 头；TCP 用含新源的伪头）
    EXPECT_EQ(read16At(pkt, 10), ipHeaderChecksum(pkt));
    EXPECT_EQ(read16At(pkt, 36), l4Checksum(pkt, 16));
    // 其余字段不动
    EXPECT_EQ(pkt[20], 0xC3);
    EXPECT_EQ(pkt[33], 0x02);
}

TEST(Nat44, RewriteDestinationAddressTcpRfc1624) {
    // 入站回写：目的 45.79.100.1 → 原始源 10.144.0.5
    // m=ocAdd(0x2D4F,0x6401)=0x9150, m'=0x0A95
    //   IP：~0xCCB7+~0x9150+0x0A95 = 0xAC8C → 0x5373
    //   TCP：~0x0A8C+~0x9150+0x0A95 = 0x6EB8 → 0x9147
    auto pkt = tcpSyn(0xCCB7);
    ASSERT_TRUE(NAT44::rewriteAddress(pkt, 16, kDst, kOldSrc));
    EXPECT_EQ((uint32_t(pkt[16]) << 24) | (uint32_t(pkt[17]) << 16) |
                  (uint32_t(pkt[18]) << 8) | pkt[19],
              kOldSrc);
    EXPECT_EQ(read16At(pkt, 10), 0x5373);
    EXPECT_EQ(read16At(pkt, 36), 0x9147);
    EXPECT_EQ(read16At(pkt, 10), ipHeaderChecksum(pkt));
    EXPECT_EQ(read16At(pkt, 36), l4Checksum(pkt, 16));
}

TEST(Nat44, RewriteTooShortPacketReturnsFalse) {
    std::vector<uint8_t> tiny(19, 0xAA);
    EXPECT_FALSE(NAT44::rewriteAddress(tiny, 12, kOldSrc, kNewSrc));
    for (uint8_t b : tiny) EXPECT_EQ(b, 0xAA); // 不动包
    // 恰 20B（仅 IP 头，proto=0）：改源 + 修 IP 头校验和，无 L4 可修
    std::vector<uint8_t> ok(20, 0);
    ok[0] = 0x45;
    put32(ok, 12, kOldSrc);
    put32(ok, 16, kDst);
    EXPECT_TRUE(NAT44::rewriteAddress(ok, 12, kOldSrc, kNewSrc));
    EXPECT_EQ((uint32_t(ok[12]) << 24) | uint32_t(ok[13]) << 16 | (uint32_t(ok[14]) << 8) |
                  ok[15],
              kNewSrc);
}

// ---- 场景②：UDP 校验和为 0（卸载）保持 0 ----

TEST(Nat44, UdpChecksumZeroStaysZero) {
    auto pkt = udpPkt(0x0000);
    ASSERT_TRUE(NAT44::rewriteAddress(pkt, 12, kOldSrc, kNewSrc));
    EXPECT_EQ(read16At(pkt, 26), 0x0000); // 保持 0 不修
    EXPECT_EQ(read16At(pkt, 10), 0xA8C5); // IP 头仍按 RFC 1624 修正
    EXPECT_EQ(read16At(pkt, 10), ipHeaderChecksum(pkt));
    // UDP 伪头级正确性此时无从谈起（卸载语义），只要求保持 0
    EXPECT_EQ(pkt[24], 0x00);
    EXPECT_EQ(pkt[25], 0x08);
}

// ---- 场景③：UDP 校验和非 0 → 增量修正 + zeroAsFFFF ----

TEST(Nat44, UdpChecksumAdjusted) {
    // 原 UDP 校验和（伪头含原源）= ~(0x9BFE + 0x9C7D) = ~0x387C = 0xC783
    // 改写后 = ~0x387C + ~0x0A95 + 0x1E9A → ~0x4C81 = 0xB37E
    auto pkt = udpPkt(0xC783);
    ASSERT_TRUE(NAT44::rewriteAddress(pkt, 12, kOldSrc, kNewSrc));
    EXPECT_EQ(read16At(pkt, 26), 0xB37E);
    EXPECT_EQ(read16At(pkt, 10), 0xA8C5);
    EXPECT_EQ(read16At(pkt, 26), l4Checksum(pkt, 6)); // 独立伪头全量重算
    EXPECT_EQ(read16At(pkt, 10), ipHeaderChecksum(pkt));
}

TEST(Nat44, UdpChecksumZeroResultBecomesFFFF) {
    // RFC 768：计算值为 0 须传 0xffff。
    // 新源 10.147.199.133 (0x0A93C785)：m'=0xD218 → 全量新校验和恰为 0
    //   UDP：~0xC783+~0x0A95+0xD218 = 0x1FFFE → 折叠 0xFFFF → 结果 0 → 写 0xFFFF
    //   IP ：~0xBCCA+~0x0A95+0xD218 = 0x20AB7 → 0x0AB9 → 0xF546
    const uint32_t newSrc = 0x0A93C785u;
    auto pkt = udpPkt(0xC783);
    ASSERT_TRUE(NAT44::rewriteAddress(pkt, 12, kOldSrc, newSrc));
    EXPECT_EQ(read16At(pkt, 26), 0xFFFF);
    EXPECT_EQ(read16At(pkt, 10), 0xF546);
    // 全量重算本身为 0，证实 0xFFFF 是 RFC 768 的传输表示
    std::vector<uint8_t> ref = pkt;
    ref[26] = 0;
    ref[27] = 0;
    EXPECT_EQ(l4Checksum(ref, 6), 0x0000);
    EXPECT_EQ(read16At(pkt, 10), ipHeaderChecksum(pkt));
}

// ---- 场景④：非首片只修 IP 头 ----

TEST(Nat44, NonFirstFragmentOnlyFixesIpHeader) {
    // flags+frag = 0x2001：MF=1 且片偏移=1（8B）
    auto pkt = udpPkt(0xBEEF); // L4 校验和哨兵
    pkt[6] = 0x20;
    pkt[7] = 0x01;
    // 让 IP 头校验和真实（proto=17、flags=0x2001 版本），供增量后全量比对
    pkt[10] = 0;
    pkt[11] = 0;
    const uint16_t before = ipHeaderChecksum(pkt);
    pkt[10] = uint8_t(before >> 8);
    pkt[11] = uint8_t(before & 0xffu);

    ASSERT_TRUE(NAT44::rewriteAddress(pkt, 12, kOldSrc, kNewSrc));
    // IP 头校验和被修正（与全量重算一致）
    EXPECT_EQ(read16At(pkt, 10), ipHeaderChecksum(pkt));
    EXPECT_NE(read16At(pkt, 10), before);
    // L4 区（20..27）原样：偏移≠0 处 ihl 之后是用户载荷不是 L4 头
    EXPECT_EQ(read16At(pkt, 26), 0xBEEF);
    for (size_t i = 20; i < pkt.size(); ++i) {
        if (i == 26 || i == 27) continue;
        EXPECT_EQ(pkt[i], udpPkt(0xBEEF)[i]) << "byte " << i;
    }
    // 分片包不进流表
    EXPECT_FALSE(NAT44::outboundKey(pkt, kWid).has_value());
    EXPECT_FALSE(NAT44::inboundKey(pkt, kWid).has_value());
}

TEST(Nat44, FirstFragmentWithMfStillFixesL4) {
    // flags+frag = 0x2000：MF=1 但片偏移=0（首片）→ 全量修正 L4
    // MF 变更后的真实 IP 头校验和：~(0x451C+0x2222+0x2000+0x4011+0x0A90+0x0005
    //   +0x2D4F+0x6401) = ~0x6335 = 0x9CCA
    auto pkt = udpPkt(0xC783);
    pkt[6] = 0x20;
    pkt[7] = 0x00;
    pkt[10] = 0x9C;
    pkt[11] = 0xCA;
    // 分片不进流表（MF 置位即判分片）
    EXPECT_FALSE(NAT44::outboundKey(pkt, kWid).has_value());
    ASSERT_TRUE(NAT44::rewriteAddress(pkt, 12, kOldSrc, kNewSrc));
    EXPECT_EQ(read16At(pkt, 26), 0xB37E); // L4 校验和照常增量修正
    EXPECT_EQ(read16At(pkt, 10), 0x88C5); // ~0x6335 + ~0x0A95 + 0x1E9A → ~0x773A
    EXPECT_EQ(read16At(pkt, 10), ipHeaderChecksum(pkt));
    EXPECT_EQ(read16At(pkt, 26), l4Checksum(pkt, 6));
}

// ---- ICMP：不改写 L4 ----

TEST(Nat44, IcmpChecksumUntouched) {
    // IP 头校验和按 proto=1 真实化
    auto pkt = icmpEcho();
    pkt[10] = 0;
    pkt[11] = 0;
    const uint16_t before = ipHeaderChecksum(pkt);
    pkt[10] = uint8_t(before >> 8);
    pkt[11] = uint8_t(before & 0xffu);

    ASSERT_TRUE(NAT44::rewriteAddress(pkt, 12, kOldSrc, kNewSrc));
    EXPECT_EQ(read16At(pkt, 22), 0xABCD); // ICMP 校验和不动
    EXPECT_EQ(read16At(pkt, 10), ipHeaderChecksum(pkt));
    EXPECT_NE(read16At(pkt, 10), before);
    EXPECT_EQ(pkt[20], 8);
}

// ---- 场景⑥：UDP 流空闲老化 ----

TEST(Nat44, UdpFlowIdleTimeout) {
    int64_t t = 1000;
    NAT44 nat([&t] { return t; });
    const FlowKey k{kWid, 17, kDst, 53, 40000};

    nat.record(k, kOldSrc);
    EXPECT_EQ(nat.size(), 1u);
    t += 59000; // 59s：未超 60s，命中
    EXPECT_EQ(nat.lookup(k), std::optional<uint32_t>(kOldSrc));
    t += 59000; // 距上次命中 59s（自登记起 118s）：命中即刷新，仍存活
    EXPECT_EQ(nat.lookup(k), std::optional<uint32_t>(kOldSrc));

    // 新实例：61s 超时未命中
    int64_t t2 = 0;
    NAT44 nat2([&t2] { return t2; });
    nat2.record(k, kOldSrc);
    t2 = 61000;
    EXPECT_FALSE(nat2.lookup(k).has_value());
    EXPECT_EQ(nat2.size(), 1u); // 超时判定不清表，新出站 record 重建

    // 边界：59999 命中 / 恰 60000 判过期（逐出与超时判据同为 >=）
    int64_t t3 = 0;
    NAT44 nat3([&t3] { return t3; });
    nat3.record(k, kOldSrc);
    t3 = 59999;
    EXPECT_TRUE(nat3.lookup(k).has_value());
    int64_t t4 = 0;
    NAT44 nat4([&t4] { return t4; });
    nat4.record(k, kOldSrc);
    t4 = 60000;
    EXPECT_FALSE(nat4.lookup(k).has_value());
}

TEST(Nat44, RecordOnExpiredEntryRefreshesKeepsOrigSrc) {
    // Kotlin 语义：record 对既有表项（含已过时但未被逐出者）只刷新活跃时间，
    // 不覆盖 origSrc；「短老化靠新出站重建」指表项被逐出后由新出站重建
    int64_t t = 0;
    NAT44 nat([&t] { return t; });
    const FlowKey k{kWid, 17, kDst, 53, 40000};
    nat.record(k, kOldSrc);
    t = 61000;
    EXPECT_FALSE(nat.lookup(k).has_value()); // 超时未命中
    nat.record(k, kNewSrc);
    t = 62000;
    EXPECT_EQ(nat.lookup(k), std::optional<uint32_t>(kOldSrc)); // 刷新复活，origSrc 保留
    EXPECT_EQ(nat.size(), 1u);
}

// ---- 场景⑦：TCP 流 6h 边界 ----

TEST(Nat44, TcpFlowSixHourBoundary) {
    int64_t t = 0;
    NAT44 nat([&t] { return t; });
    const FlowKey k{kWid, 6, kDst, 443, 50000};
    nat.record(k, kOldSrc);
    t = 6 * 3600 * 1000 - 1; // 21599999：仍命中
    EXPECT_EQ(nat.lookup(k), std::optional<uint32_t>(kOldSrc));
    EXPECT_EQ(nat.lookup(k), std::optional<uint32_t>(kOldSrc)); // 命中刷新后仍在窗口内

    int64_t t2 = 0;
    NAT44 nat2([&t2] { return t2; });
    nat2.record(k, kOldSrc);
    t2 = 6 * 3600 * 1000; // 恰 21600000：判过期（>=）
    EXPECT_FALSE(nat2.lookup(k).has_value());
    EXPECT_EQ(nat2.size(), 1u);
}

// ---- 场景⑧：513 条流上限逐出 ----

TEST(Nat44, CapEvictionAt513Flows) {
    int64_t t = 0;
    NAT44 nat([&t] { return t; });
    for (uint32_t i = 0; i < 513; ++i) {
        FlowKey k{kWid, 6, 0x0A000000u + i, 443, uint16_t(20000 + i)};
        nat.record(k, 0x11111111u + i);
        t += 1000; // 各流登记时刻错开，最旧者可精确预测
    }
    EXPECT_EQ(nat.size(), 512u); // 上限守住
    // 最旧（i=0）被逐出
    EXPECT_FALSE(nat.lookup(FlowKey{kWid, 6, 0x0A000000u + 0, 443, 20000}).has_value());
    // 其余保留且 origSrc 对应
    EXPECT_EQ(nat.lookup(FlowKey{kWid, 6, 0x0A000000u + 1, 443, 20001}),
              std::optional<uint32_t>(0x11111112u));
    EXPECT_EQ(nat.lookup(FlowKey{kWid, 6, 0x0A000000u + 512, 443, 20512}),
              std::optional<uint32_t>(0x11111111u + 512));
}

TEST(Nat44, CapEvictionPrefersExpiredEntries) {
    // 满 512 后先淘汰过期，再逐最旧
    int64_t t = 0;
    NAT44 nat([&t] { return t; });
    for (uint32_t i = 0; i < 512; ++i) {
        nat.record(FlowKey{kWid, 17, 0x0A000000u + i, 53, uint16_t(30000 + i)}, 0x22222222u);
    }
    EXPECT_EQ(nat.size(), 512u);
    t += 61000; // 全部 UDP 流超时
    nat.record(FlowKey{kWid, 17, 0x0B000000u, 53, 30000}, 0x33333333u);
    EXPECT_EQ(nat.size(), 1u); // 过期全清，只剩新流
    EXPECT_EQ(nat.lookup(FlowKey{kWid, 17, 0x0B000000u, 53, 30000}),
              std::optional<uint32_t>(0x33333333u));
}

// ---- record/lookup 语义补充 ----

TEST(Nat44, RecordRefreshKeepsOrigSrc) {
    int64_t t = 0;
    NAT44 nat([&t] { return t; });
    const FlowKey k{kWid, 6, kDst, 443, 50000};
    nat.record(k, 0x11111111u);
    nat.record(k, 0x22222222u); // 已存在仅刷新，不覆盖 origSrc
    EXPECT_EQ(nat.lookup(k), std::optional<uint32_t>(0x11111111u));
    EXPECT_EQ(nat.size(), 1u);
    // 未登记流查询未中，不影响表
    EXPECT_FALSE(nat.lookup(FlowKey{kWid, 6, kDst, 443, 50001}).has_value());
    EXPECT_EQ(nat.size(), 1u);
}

TEST(Nat44, FlowKeyIsolationByNwid) {
    // 嵌套子网：同一四元组分属两网，流键按 nwid 隔离不串流
    int64_t t = 0;
    NAT44 nat([&t] { return t; });
    const uint64_t nwA = 0xAAAA0001u;
    const uint64_t nwB = 0xBBBB0002u;
    nat.record(FlowKey{nwA, 6, kDst, 443, 50000}, 0x11111111u);
    nat.record(FlowKey{nwB, 6, kDst, 443, 50000}, 0x22222222u);
    EXPECT_EQ(nat.size(), 2u);
    EXPECT_EQ(nat.lookup(FlowKey{nwA, 6, kDst, 443, 50000}),
              std::optional<uint32_t>(0x11111111u));
    EXPECT_EQ(nat.lookup(FlowKey{nwB, 6, kDst, 443, 50000}),
              std::optional<uint32_t>(0x22222222u));
    // 不同 nwid 不互撞（哈希/判等均含 nwid）
    EXPECT_FALSE(nat.lookup(FlowKey{0xCCCC0003u, 6, kDst, 443, 50000}).has_value());
    const FlowKey ka{nwA, 6, kDst, 443, 50000};
    const FlowKey kb{nwB, 6, kDst, 443, 50000};
    EXPECT_TRUE(ka == ka);
    EXPECT_TRUE(ka != kb);
    EXPECT_FALSE(ka == kb);
}
