// test_frameconverter.cpp — FrameConverter 全链向量（A2 Task 7，直译源 tunnel/FrameConverter.kt）
//
// 对照 brief 八场景（host 全链：CoreSend 记录到 vector 断言）：
//   ① ARP 解析闭环：请求广播 + pending 记录 → 伪造 reply 上行 → 待决冲刷到核心
//   ② 多网络 NAT：出站改写（校验和独立重算交叉验证）+ 入站还原为原始源
//   ③ 源不符：外来源不改写，仅计数并记录 lastSrcMismatch
//   ④ 无路由：v4 丢弃计数；v6 无命中静默（不计数）
//   ⑤ 广播/组播：全网泛发（v4 组播 MAC 低 23 位映射、v6 组播 0x3333 前缀）
//   ⑥ v6 NDP：NS→NA 两分支 flags（普通 0x60 单播 / DAD 0x20 组播）+ 待决冲刷
//   ⑦ retainOnly 清理后 debugSummary 规模正确
//   ⑧ sendKeepalive 每活跃网发 ARP（statKeepalive=网数）
// 附带：网关路由的 ARP 目标=网关、待决上限 16、ARP 请求应答、畸形输入吸收。
#include "dataplane/FrameConverter.h"

#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <string>
#include <vector>

using namespace pp;

namespace {

// ---- CoreSend 录制器：全链断言的数据源（brief「CoreSend 记录到 vector 断言」） ----

struct SentFrame {
    uint64_t nwid, srcMac, dstMac;
    uint16_t etherType, vlanId;
    std::vector<uint8_t> payload;
};

struct Recorder {
    std::vector<SentFrame> frames;
    void clear() { frames.clear(); }
    FrameConverter::CoreSend fn() {
        return [this](uint64_t nwid, uint64_t srcMac, uint64_t dstMac, uint16_t etherType,
                      uint16_t vlanId, const uint8_t* data, size_t len) {
            frames.push_back(SentFrame{nwid, srcMac, dstMac, etherType, vlanId,
                                       std::vector<uint8_t>(data, data + len)});
        };
    }
};

// ---- 小工具 ----

const size_t kNpos = std::string::npos;

uint32_t v4(const char* s) { return parseIpv4(s).value_or(0); }

Ipv6Address v6(const char* s) { return parseIpv6(s).value_or(Ipv6Address{}); }

std::vector<std::string> S(std::initializer_list<const char*> l) {
    std::vector<std::string> out;
    for (const char* p : l) out.emplace_back(p);
    return out;
}

void put16(std::vector<uint8_t>& p, size_t o, uint16_t v) {
    p[o] = uint8_t(v >> 8);
    p[o + 1] = uint8_t(v & 0xffu);
}

void put32(std::vector<uint8_t>& p, size_t o, uint32_t v) {
    p[o] = uint8_t(v >> 24);
    p[o + 1] = uint8_t((v >> 16) & 0xffu);
    p[o + 2] = uint8_t((v >> 8) & 0xffu);
    p[o + 3] = uint8_t(v & 0xffu);
}

uint16_t read16(const std::vector<uint8_t>& p, size_t o) {
    return uint16_t((uint16_t(p[o]) << 8) | p[o + 1]);
}

uint32_t read32(const std::vector<uint8_t>& p, size_t o) {
    return (uint32_t(p[o]) << 24) | (uint32_t(p[o + 1]) << 16) | (uint32_t(p[o + 2]) << 8) |
           uint32_t(p[o + 3]);
}

uint32_t readAddr32(const Ipv6Address& a, int byteOff) {
    return (uint32_t(a.bytes[size_t(byteOff)]) << 24) | (uint32_t(a.bytes[size_t(byteOff) + 1]) << 16) |
           (uint32_t(a.bytes[size_t(byteOff) + 2]) << 8) | uint32_t(a.bytes[size_t(byteOff) + 3]);
}

uint32_t fold32(uint32_t s) {
    while (s > 0xffffu) s = (s & 0xffffu) + (s >> 16);
    return s;
}

/** 独立实现的全量 IPv4 头校验和（与 NAT44 增量路径交叉验证用） */
uint16_t ipHeaderChecksum(const std::vector<uint8_t>& p) {
    const size_t ihl = size_t(p[0] & 0x0fu) * 4;
    uint32_t s = 0;
    for (size_t i = 0; i < ihl; i += 2)
        s += (uint32_t(p[i]) << 8) | p[i + 1];
    s -= (uint32_t(p[10]) << 8) | p[11]; // 校验和字段剔除
    return uint16_t((~fold32(s)) & 0xffffu);
}

/** 独立实现的全量 TCP 校验和（伪头 + 段，校验和字段清零） */
uint16_t tcpChecksum(const std::vector<uint8_t>& p) {
    const size_t ihl = size_t(p[0] & 0x0fu) * 4;
    const size_t l4len = ((size_t(p[2]) << 8) | p[3]) - ihl;
    uint32_t s = 0;
    for (size_t i = 12; i < 20; i += 2) s += (uint32_t(p[i]) << 8) | p[i + 1]; // 伪头 src/dst
    s += p[9] + (l4len & 0xffu) + (l4len >> 8);                               // proto + 长度
    for (size_t i = 0; i < l4len; i += 2) {
        const size_t o = ihl + i;
        if (o == ihl + 16) continue; // TCP 校验和字段剔除
        s += (uint32_t(p[o]) << 8) | ((o + 1 < ihl + l4len) ? p[o + 1] : 0);
    }
    return uint16_t((~fold32(s)) & 0xffffu);
}

/** 独立实现的 RFC 4443/1071 ICMPv6 校验和（伪头 + 载荷） */
uint16_t icmpv6FullChecksum(const Ipv6Address& src, const Ipv6Address& dst,
                            std::vector<uint8_t> d) {
    d[2] = 0;
    d[3] = 0;
    uint32_t s = 0;
    auto addAddr = [&](const Ipv6Address& a) {
        for (int i = 0; i < 16; i += 2)
            s += (uint32_t(a.bytes[size_t(i)]) << 8) | a.bytes[size_t(i) + 1];
    };
    addAddr(src);
    addAddr(dst);
    s += uint32_t(d.size() & 0xffffu);
    s += 58; // nextHeader
    for (size_t i = 0; i < d.size(); i += 2)
        s += (uint32_t(d[i]) << 8) | ((i + 1 < d.size()) ? d[i + 1] : 0);
    return uint16_t((~fold32(s)) & 0xffffu);
}

/** 20B IP 头 + 20B TCP 段，校验和按当前地址全量预填 */
std::vector<uint8_t> mkTcp4(uint32_t src, uint32_t dst, uint16_t sport, uint16_t dport) {
    std::vector<uint8_t> p(40, 0);
    p[0] = 0x45; // v4 ihl=5
    put16(p, 2, 40);
    p[4] = 0x12;
    p[5] = 0x34;
    p[6] = 0x40; // DF
    p[8] = 64;
    p[9] = 6; // TCP
    put32(p, 12, src);
    put32(p, 16, dst);
    put16(p, 20, sport);
    put16(p, 22, dport);
    put32(p, 24, 0x11223344);
    p[32] = 0x50; // data offset 5
    p[33] = 0x02; // SYN
    put16(p, 34, 0xffff);
    put16(p, 36, tcpChecksum(p));
    put16(p, 10, ipHeaderChecksum(p));
    return p;
}

/** 20B IP 头 + 8B UDP 段，校验和 0（未计算，合法） */
std::vector<uint8_t> mkUdp4(uint32_t src, uint32_t dst, uint16_t sport, uint16_t dport) {
    std::vector<uint8_t> p(28, 0);
    p[0] = 0x45;
    put16(p, 2, 28);
    p[8] = 64;
    p[9] = 17;
    put32(p, 12, src);
    put32(p, 16, dst);
    put16(p, 20, sport);
    put16(p, 22, dport);
    put16(p, 24, 8);
    put16(p, 10, ipHeaderChecksum(p));
    return p;
}

/** 40B IPv6 头 + 8B UDP 段（UDP 校验和 0 未计算——转发路径不校验） */
std::vector<uint8_t> mkUdp6(const Ipv6Address& src, const Ipv6Address& dst, uint16_t sport,
                            uint16_t dport) {
    std::vector<uint8_t> p(48, 0);
    p[0] = 0x60;
    put16(p, 4, 8);
    p[6] = 17; // UDP
    p[7] = 255;
    for (int i = 0; i < 16; ++i) {
        p[size_t(8) + size_t(i)] = src.bytes[size_t(i)];
        p[size_t(24) + size_t(i)] = dst.bytes[size_t(i)];
    }
    put16(p, 40, sport);
    put16(p, 42, dport);
    put16(p, 44, 8);
    return p;
}

/** 40B IPv6 头 + ICMPv6 载荷，校验和按真实 src/dst 预填（nextHeader=58 hop=255） */
std::vector<uint8_t> wrapV6(std::vector<uint8_t> payload, const Ipv6Address& src,
                            const Ipv6Address& dst) {
    const uint16_t ck = icmpv6FullChecksum(src, dst, payload);
    payload[2] = uint8_t(ck >> 8);
    payload[3] = uint8_t(ck & 0xffu);
    std::vector<uint8_t> p(40 + payload.size(), 0);
    p[0] = 0x60;
    p[4] = uint8_t((payload.size() >> 8) & 0xffu);
    p[5] = uint8_t(payload.size() & 0xffu);
    p[6] = 58;
    p[7] = 255;
    for (int i = 0; i < 16; ++i) {
        p[size_t(8) + size_t(i)] = src.bytes[size_t(i)];
        p[size_t(24) + size_t(i)] = dst.bytes[size_t(i)];
    }
    for (size_t i = 0; i < payload.size(); ++i) p[40 + i] = payload[i];
    return p;
}

/** 测试侧自拼 NS/NA 载荷：模拟真实节点把校验和按真实 src/dst 预填 */
std::vector<uint8_t> icmp6WithChecksum(const Ipv6Address& src, const Ipv6Address& dst,
                                       std::vector<uint8_t> payload) {
    const uint16_t ck = icmpv6FullChecksum(src, dst, payload);
    payload[2] = uint8_t(ck >> 8);
    payload[3] = uint8_t(ck & 0xffu);
    return payload;
}

bool contains(const std::string& s, const std::string& sub) { return s.find(sub) != kNpos; }

// 常用身份
constexpr uint64_t kNwidA = 0xaaaa0001ULL;
constexpr uint64_t kNwidB = 0xbbbb0002ULL;
constexpr uint64_t kNwidC = 0xcccc0003ULL;
constexpr uint64_t kMacA = 0xaabbccddeeffULL;
constexpr uint64_t kMacB = 0x998877665544ULL;
constexpr uint64_t kMacC = 0x001122334455ULL;
constexpr uint64_t kPeerMac = 0x112233445566ULL;
constexpr uint64_t kGwMac = 0x66778899aabbULL;

} // namespace

// ---- 场景 ①：ARP 解析闭环（请求广播 → pending → reply 上行 → 冲刷到核心） ----

TEST(FrameConverter, ArpResolutionFlushesPendingPacket) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({"10.1.0.1/24"}), S({}), S({}));

    const std::vector<uint8_t> pkt = mkUdp4(v4("10.1.0.1"), v4("10.1.0.99"), 5000, 6000);
    fc.handlePacketsFromTun({pkt});

    // 未解析 → 广播 ARP request（statArpReq=1、pending 记录）
    ASSERT_EQ(rec.frames.size(), 1u);
    const SentFrame& f = rec.frames[0];
    EXPECT_EQ(f.nwid, kNwidA);
    EXPECT_EQ(f.srcMac, kMacA);
    EXPECT_EQ(f.dstMac, BROADCAST_MAC);
    EXPECT_EQ(f.etherType, ETH_TYPE_ARP);
    EXPECT_EQ(f.vlanId, 0);
    std::optional<ArpPacket> arp = parseArp(f.payload.data(), f.payload.size());
    ASSERT_TRUE(arp);
    EXPECT_EQ(arp->op, 1u);
    EXPECT_EQ(arp->senderIp, v4("10.1.0.1"));
    EXPECT_EQ(arp->senderMac, kMacA);
    EXPECT_EQ(arp->targetIp, v4("10.1.0.99"));
    std::string s = fc.debugSummary();
    EXPECT_TRUE(contains(s, "ARP问=1"));
    EXPECT_TRUE(contains(s, "待决=1"));

    // 伪造 ARP reply 上行 → 待决冲刷，core 收到原帧
    rec.clear();
    std::vector<uint8_t> reply = arpReply(v4("10.1.0.99"), kPeerMac, v4("10.1.0.1"), kMacA);
    EXPECT_TRUE(
        fc.handleFrameFromCore(kNwidA, kPeerMac, kMacA, ETH_TYPE_ARP, reply.data(), reply.size())
            .empty());
    ASSERT_EQ(rec.frames.size(), 1u);
    EXPECT_EQ(rec.frames[0].nwid, kNwidA);
    EXPECT_EQ(rec.frames[0].srcMac, kMacA);
    EXPECT_EQ(rec.frames[0].dstMac, kPeerMac); // 冲刷用应答里的 senderMac
    EXPECT_EQ(rec.frames[0].etherType, ETH_TYPE_IPV4);
    EXPECT_EQ(rec.frames[0].payload, pkt); // 原帧逐字节（源在本网内不改写）
    s = fc.debugSummary();
    EXPECT_TRUE(contains(s, "ARP答=1"));
    EXPECT_TRUE(contains(s, "ARP表=1"));
    EXPECT_TRUE(contains(s, "待决=0"));
    EXPECT_TRUE(contains(s, "出站=0")); // 冲刷不计出站（对齐 Kotlin：仅直发路径 ++）
    EXPECT_TRUE(contains(s, "NAT出=0 NAT入=0"));

    // 表已热：第二个包直发（出站计数）
    rec.clear();
    fc.handlePacketsFromTun({mkUdp4(v4("10.1.0.1"), v4("10.1.0.99"), 5000, 6001)});
    ASSERT_EQ(rec.frames.size(), 1u);
    EXPECT_EQ(rec.frames[0].dstMac, kPeerMac);
    EXPECT_TRUE(contains(fc.debugSummary(), "出站=1"));
}

// ---- 场景 ②：多网络 NAT（出站改写 + 入站还原） ----

TEST(FrameConverter, MultiNetworkNatRewritesOutboundAndRestoresInbound) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({"10.1.0.1/24"}), S({}),
                         S({"10.1.0.0/16 via 10.1.0.254"}));
    fc.updateNetworkInfo(kNwidB, true, kMacB, S({"10.9.0.1/24"}), S({}), S({}));

    // 预热网关 ARP（op=2 应答登记）
    std::vector<uint8_t> gwReply = arpReply(v4("10.1.0.254"), kGwMac, v4("10.1.0.1"), kMacA);
    ASSERT_TRUE(
        fc.handleFrameFromCore(kNwidA, kGwMac, kMacA, ETH_TYPE_ARP, gwReply.data(), gwReply.size())
            .empty());
    rec.clear();

    // TUN 注源=B 地址经网 A 路由的包
    const std::vector<uint8_t> pkt = mkTcp4(v4("10.9.0.1"), v4("10.1.9.9"), 5000, 443);
    fc.handlePacketsFromTun({pkt});
    ASSERT_EQ(rec.frames.size(), 1u);
    const SentFrame& f = rec.frames[0];
    EXPECT_EQ(f.nwid, kNwidA);
    EXPECT_EQ(f.srcMac, kMacA);
    EXPECT_EQ(f.dstMac, kGwMac); // 命中 /16 managed 路由 → 下一跳=网关
    EXPECT_EQ(f.etherType, ETH_TYPE_IPV4);
    EXPECT_EQ(read32(f.payload, 12), v4("10.1.0.1")); // 源改写为 A 地址
    EXPECT_EQ(read32(f.payload, 16), v4("10.1.9.9"));
    EXPECT_EQ(read16(f.payload, 10), ipHeaderChecksum(f.payload)); // 校验和独立重算一致
    EXPECT_EQ(read16(f.payload, 36), tcpChecksum(f.payload));
    std::string s = fc.debugSummary();
    EXPECT_TRUE(contains(s, "NAT出=1"));
    EXPECT_TRUE(contains(s, "NAT流表=1"));
    EXPECT_TRUE(contains(s, "出站=1"));

    // 注回包（远程 → 改写后地址）→ 还原为 B 地址写 TUN
    std::vector<uint8_t> back = mkTcp4(v4("10.1.9.9"), v4("10.1.0.1"), 443, 5000);
    std::vector<std::vector<uint8_t>> tun =
        fc.handleFrameFromCore(kNwidA, kGwMac, kMacA, ETH_TYPE_IPV4, back.data(), back.size());
    ASSERT_EQ(tun.size(), 1u);
    EXPECT_EQ(read32(tun[0], 12), v4("10.1.9.9"));
    EXPECT_EQ(read32(tun[0], 16), v4("10.9.0.1")); // 目的回写为原始源
    EXPECT_EQ(read16(tun[0], 10), ipHeaderChecksum(tun[0]));
    EXPECT_EQ(read16(tun[0], 36), tcpChecksum(tun[0]));
    s = fc.debugSummary();
    EXPECT_TRUE(contains(s, "NAT入=1"));
    EXPECT_TRUE(contains(s, "入站=1"));
    EXPECT_TRUE(contains(s, "NAT流表=1")); // 命中不新增
}

// ---- 场景 ③：源不符（外来源不改写，仅计数） ----

TEST(FrameConverter, ForeignSourceCountedAsMismatchWithoutRewrite) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({"10.1.0.1/24"}), S({}), S({}));
    std::vector<uint8_t> peerReply = arpReply(v4("10.1.0.99"), kPeerMac, v4("10.1.0.1"), kMacA);
    ASSERT_TRUE(fc.handleFrameFromCore(kNwidA, kPeerMac, kMacA, ETH_TYPE_ARP, peerReply.data(),
                                       peerReply.size())
                    .empty());
    rec.clear();

    const std::vector<uint8_t> pkt = mkUdp4(v4("172.16.5.5"), v4("10.1.0.99"), 4000, 53);
    fc.handlePacketsFromTun({pkt});
    ASSERT_EQ(rec.frames.size(), 1u);
    EXPECT_EQ(rec.frames[0].dstMac, kPeerMac);
    EXPECT_EQ(rec.frames[0].payload, pkt); // 不改写直送
    std::string s = fc.debugSummary();
    EXPECT_TRUE(contains(s, "源不符=1(172.16.5.5)"));
    EXPECT_TRUE(contains(s, "NAT出=0"));
    // 第二次同源：计数累计、lastSrcMismatch 不变
    fc.handlePacketsFromTun({pkt});
    EXPECT_TRUE(contains(fc.debugSummary(), "源不符=2(172.16.5.5)"));
}

// ---- 场景 ④：无路由（v4 计数丢弃；v6 静默） ----

TEST(FrameConverter, NoRouteDropsIpv4AndCountsIpv6Silently) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({"10.1.0.1/24"}), S({"fd11::1/64"}), S({}));

    fc.handlePacketsFromTun({mkUdp4(v4("10.1.0.1"), v4("99.9.9.9"), 5000, 80)});
    EXPECT_TRUE(rec.frames.empty()); // core 不收帧
    EXPECT_TRUE(contains(fc.debugSummary(), "无路由丢弃=1"));

    // v6 无命中不计数（对齐 Kotlin：仅 v4 路径 ++）
    fc.handlePacketsFromTun(
        {wrapV6(std::vector<uint8_t>(8, 0), v6("fd11::1"), v6("2001:db8::1"))});
    EXPECT_TRUE(rec.frames.empty());
    EXPECT_TRUE(contains(fc.debugSummary(), "无路由丢弃=1"));
}

// ---- 场景 ⑤：广播/组播全网泛发 ----

TEST(FrameConverter, BroadcastAndMulticastFanOut) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({"10.1.0.1/24"}), S({"fd11::1/64"}), S({}));
    fc.updateNetworkInfo(kNwidB, true, kMacB, S({"10.9.0.1/24"}), S({}), S({}));
    fc.updateNetworkInfo(kNwidC, true, kMacC, S({}), S({"fdaa::1/64"}), S({})); // v6-only

    // 广播 → 两个 v4 网泛发（v6-only 网跳过）
    fc.handlePacketsFromTun({mkUdp4(v4("10.1.0.1"), v4("255.255.255.255"), 5000, 6000)});
    ASSERT_EQ(rec.frames.size(), 2u);
    EXPECT_EQ(rec.frames[0].nwid, kNwidA);
    EXPECT_EQ(rec.frames[0].srcMac, kMacA);
    EXPECT_EQ(rec.frames[0].dstMac, BROADCAST_MAC);
    EXPECT_EQ(rec.frames[1].nwid, kNwidB);
    EXPECT_EQ(rec.frames[1].srcMac, kMacB);
    EXPECT_EQ(rec.frames[1].dstMac, BROADCAST_MAC);

    // v4 组播（224.0.0.251 mDNS）→ 组播 MAC 低 23 位映射 01:00:5e:00:00:fb
    rec.clear();
    fc.handlePacketsFromTun({mkUdp4(v4("10.1.0.1"), v4("224.0.0.251"), 5353, 5353)});
    ASSERT_EQ(rec.frames.size(), 2u);
    EXPECT_EQ(rec.frames[0].dstMac, 0x01005e0000fbULL);
    EXPECT_EQ(rec.frames[1].dstMac, 0x01005e0000fbULL);

    // v6 组播（ff02::1）→ 有 v6 地址的网泛发，MAC = 0x3333 + 低 32 位
    rec.clear();
    fc.handlePacketsFromTun({wrapV6(std::vector<uint8_t>(8, 0), v6("fd11::1"), v6("ff02::1"))});
    ASSERT_EQ(rec.frames.size(), 2u);
    EXPECT_EQ(rec.frames[0].nwid, kNwidA);
    EXPECT_EQ(rec.frames[0].dstMac, 0x333300000001ULL);
    EXPECT_EQ(rec.frames[1].nwid, kNwidC);
    EXPECT_EQ(rec.frames[1].dstMac, 0x333300000001ULL);
}

// ---- 场景 ⑥：NDP（普通 NS 单播 0x60 / DAD 组播 0x20 / NA 表更新与待决冲刷） ----

TEST(FrameConverter, NdpNormalSolicitationUnicastReply) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({"10.1.0.1/24"}), S({"fd11::1/64"}), S({}));

    // 普通 NS：源=真实地址，目的=本机持有地址
    const Ipv6Address target = v6("fd11::1");
    const Ipv6Address peerAddr = v6("fd11::5");
    std::vector<uint8_t> ns = icmp6WithChecksum(peerAddr, solicitedNodeMulticast(target),
                                                neighborSolicitation(target, kPeerMac));
    std::vector<uint8_t> req = wrapV6(ns, peerAddr, solicitedNodeMulticast(target));
    EXPECT_TRUE(
        fc.handleFrameFromCore(kNwidA, kPeerMac, kMacA, ETH_TYPE_IPV6, req.data(), req.size())
            .empty());

    // NA 单播回请求方：flags 0x60、源地址=被解析地址、校验和伪头用真实 src/dst
    ASSERT_EQ(rec.frames.size(), 1u);
    const SentFrame& f = rec.frames[0];
    EXPECT_EQ(f.dstMac, kPeerMac);
    EXPECT_EQ(f.etherType, ETH_TYPE_IPV6);
    EXPECT_EQ(read32(f.payload, 24), 0xfd110000u); // L3 目的=请求方（fd11::5）
    EXPECT_EQ(read32(f.payload, 28), 0u);
    EXPECT_EQ(read32(f.payload, 36), 0x00000005u);
    std::vector<uint8_t> icmp6(f.payload.begin() + 40, f.payload.end());
    ASSERT_GE(icmp6.size(), 32u);
    EXPECT_EQ(icmp6[0], 136);
    EXPECT_EQ(icmp6[4], 0x60); // Solicited+Override
    Ipv6Address naTarget;
    for (int i = 0; i < 16; ++i) naTarget.bytes[size_t(i)] = icmp6[size_t(8) + size_t(i)];
    EXPECT_EQ(naTarget, target);
    EXPECT_EQ(icmp6[24], 2); // TLL 选项
    uint64_t optMac = 0;
    for (int i = 2; i < 8; ++i) optMac = (optMac << 8) | icmp6[size_t(24) + size_t(i)];
    EXPECT_EQ(optMac, kMacA);
    EXPECT_EQ(read16(icmp6, 2),
              icmpv6FullChecksum(target, peerAddr, icmp6)); // 伪头 src=target dst=请求方
}

TEST(FrameConverter, NdpDuplicateAddressDetectionOverrideOnly) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({}), S({"fd11::1/64"}), S({}));

    // DAD 探测：NS 源=:: → NA 目的=全节点组播、flags 仅 Override
    const Ipv6Address target = v6("fd11::1");
    std::vector<uint8_t> ns = icmp6WithChecksum(Ipv6Address{}, solicitedNodeMulticast(target),
                                                neighborSolicitation(target, kPeerMac));
    std::vector<uint8_t> req = wrapV6(ns, Ipv6Address{}, solicitedNodeMulticast(target));
    EXPECT_TRUE(
        fc.handleFrameFromCore(kNwidA, kPeerMac, kMacA, ETH_TYPE_IPV6, req.data(), req.size())
            .empty());

    ASSERT_EQ(rec.frames.size(), 1u);
    const SentFrame& f = rec.frames[0];
    const Ipv6Address allNodes = allNodesMulticast(); // 直译 Kotlin 字面值（2::1，见 NdpTable.h）
    EXPECT_EQ(f.dstMac, multicastMAC(allNodes));      // 0x3333 + 低 32 位 = 0x333300000001
    EXPECT_EQ(f.dstMac, 0x333300000001ULL);
    EXPECT_EQ(read32(f.payload, 24), readAddr32(allNodes, 0));
    EXPECT_EQ(read32(f.payload, 28), readAddr32(allNodes, 4));
    EXPECT_EQ(read32(f.payload, 36), readAddr32(allNodes, 12));
    std::vector<uint8_t> icmp6(f.payload.begin() + 40, f.payload.end());
    ASSERT_GE(icmp6.size(), 32u);
    EXPECT_EQ(icmp6[0], 136);
    EXPECT_EQ(icmp6[4], 0x20); // Solicited 清零仅 Override（RFC 4861 §7.2.4）
    EXPECT_EQ(read16(icmp6, 2), icmpv6FullChecksum(target, allNodes, icmp6));
}

TEST(FrameConverter, NdpResolutionFlushesPendingAndCaches) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({}), S({"fd11::1/64"}), S({}));

    const std::vector<uint8_t> pkt = mkUdp6(v6("fd11::1"), v6("fd11::9"), 5000, 6000);
    fc.handlePacketsFromTun({pkt});

    // 未解析 → NS 发往请求节点组播（L3 目的=组播地址，L2=对应组播 MAC）
    ASSERT_EQ(rec.frames.size(), 1u);
    const SentFrame& nsFrame = rec.frames[0];
    EXPECT_EQ(nsFrame.etherType, ETH_TYPE_IPV6);
    EXPECT_EQ(nsFrame.dstMac, 0x3333ff000009ULL); // ff02::1:ff00:9 → 组播 MAC
    EXPECT_EQ(read32(nsFrame.payload, 24), 0xff020000u);
    EXPECT_EQ(read32(nsFrame.payload, 36), 0xff000009u);
    std::vector<uint8_t> icmp6(nsFrame.payload.begin() + 40, nsFrame.payload.end());
    EXPECT_EQ(icmp6[0], 135);
    // 诊断行「待决」按 Kotlin 原文仅统计 pendingV4——v6 待决不进诊断，
    // 由下方 NA 冲刷行为断言覆盖（冲刷前 frames=1、冲刷后原帧直达核心）
    EXPECT_TRUE(contains(fc.debugSummary(), "待决=0"));

    // NA 上行 → 表登记 + 待决冲刷（dstMac=NA 的 senderMac）
    rec.clear();
    std::vector<uint8_t> na = icmp6WithChecksum(v6("fd11::9"), v6("fd11::1"),
                                                neighborAdvertisement(v6("fd11::9"), kPeerMac));
    std::vector<uint8_t> naPkt = wrapV6(na, v6("fd11::9"), v6("fd11::1"));
    EXPECT_TRUE(
        fc.handleFrameFromCore(kNwidA, kPeerMac, kMacA, ETH_TYPE_IPV6, naPkt.data(), naPkt.size())
            .empty());
    ASSERT_EQ(rec.frames.size(), 1u);
    EXPECT_EQ(rec.frames[0].dstMac, kPeerMac);
    EXPECT_EQ(rec.frames[0].payload, pkt);
    EXPECT_TRUE(contains(fc.debugSummary(), "待决=0"));

    // 表已热：直发不再发 NS
    rec.clear();
    fc.handlePacketsFromTun({mkUdp6(v6("fd11::1"), v6("fd11::9"), 5000, 6001)});
    ASSERT_EQ(rec.frames.size(), 1u);
    EXPECT_EQ(rec.frames[0].dstMac, kPeerMac);
    EXPECT_EQ(rec.frames[0].etherType, ETH_TYPE_IPV6);
}

// ---- 场景 ⑦：retainOnly 清理 + debugSummary 规模 ----

TEST(FrameConverter, RetainOnlyCleansGhostContextsAndSummaryScale) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({"10.1.0.1/24"}), S({}),
                         S({"10.1.0.0/16 via 10.1.0.254"}));                         // routes4=2
    fc.updateNetworkInfo(kNwidB, true, kMacB, S({"10.9.0.1/24"}), S({}), S({}));    // routes4=1
    fc.updateNetworkInfo(kNwidC, true, kMacC, S({}), S({"fdaa::1/64"}), S({}));     // routes6=1
    std::string s = fc.debugSummary();
    EXPECT_TRUE(contains(s, "contexts=3 aggV4=3 aggV6=1"));
    EXPECT_TRUE(contains(s, "ctx 00000000aaaa0001 mac=aabbccddeeff"));
    EXPECT_TRUE(contains(s, "ctx 00000000bbbb0002"));
    EXPECT_TRUE(contains(s, "ctx 00000000cccc0003"));

    fc.retainOnly({kNwidA, kNwidC});
    s = fc.debugSummary();
    EXPECT_TRUE(contains(s, "contexts=2 aggV4=2 aggV6=1")); // 聚合表随重建收敛
    EXPECT_TRUE(contains(s, "ctx 00000000aaaa0001"));
    EXPECT_TRUE(contains(s, "ctx 00000000cccc0003"));
    EXPECT_EQ(s.find("ctx 00000000bbbb0002"), kNpos); // 幽灵上下文已清

    // enabled=false 等价移除；重复 retainOnly 为无害空操作
    fc.updateNetworkInfo(kNwidA, false, kMacA, S({"10.1.0.1/24"}), S({}), S({}));
    fc.retainOnly({kNwidA, kNwidC});
    s = fc.debugSummary();
    EXPECT_TRUE(contains(s, "contexts=1 aggV4=0 aggV6=1"));
    EXPECT_TRUE(contains(s, "ctx 00000000cccc0003"));
}

// ---- 场景 ⑧：保活（每活跃网一个 ARP 探测帧） ----

TEST(FrameConverter, KeepaliveProbesEveryActiveNetwork) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({"10.1.0.1/24"}), S({}), S({}));
    fc.updateNetworkInfo(kNwidB, true, kMacB, S({"10.9.0.1/24"}), S({}), S({}));
    fc.updateNetworkInfo(kNwidC, true, 0, S({"172.16.9.1/24"}), S({}), S({})); // mac=0 跳过

    fc.sendKeepalive();
    ASSERT_EQ(rec.frames.size(), 2u);
    EXPECT_EQ(rec.frames[0].nwid, kNwidA);
    EXPECT_EQ(rec.frames[0].dstMac, BROADCAST_MAC);
    EXPECT_EQ(rec.frames[1].nwid, kNwidB);
    std::optional<ArpPacket> probe =
        parseArp(rec.frames[1].payload.data(), rec.frames[1].payload.size());
    ASSERT_TRUE(probe);
    EXPECT_EQ(probe->op, 1u);
    EXPECT_EQ(probe->senderIp, v4("10.9.0.1")); // 探测地址=各网首地址
    EXPECT_EQ(probe->targetIp, v4("10.9.0.1"));
    EXPECT_TRUE(contains(fc.debugSummary(), "保活=1"));

    fc.sendKeepalive();
    ASSERT_EQ(rec.frames.size(), 4u);
    EXPECT_TRUE(contains(fc.debugSummary(), "保活=2"));
}

// ---- 补充：网关路由 / 待决上限 / ARP 请求应答 / 畸形输入吸收 ----

TEST(FrameConverter, GatewayRouteArpTargetsGateway) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({"10.1.0.1/24"}), S({}),
                         S({"10.1.0.0/16 via 10.1.0.254"}));

    // 目的在 /24 外、/16 内 → LPM 落 /16 managed 路由，下一跳=网关
    fc.handlePacketsFromTun({mkUdp4(v4("10.1.0.1"), v4("10.1.9.9"), 5000, 80)});
    ASSERT_EQ(rec.frames.size(), 1u);
    std::optional<ArpPacket> arp =
        parseArp(rec.frames[0].payload.data(), rec.frames[0].payload.size());
    ASSERT_TRUE(arp);
    EXPECT_EQ(arp->targetIp, v4("10.1.0.254")); // 对网关发 ARP，不对目的地址
    EXPECT_TRUE(contains(fc.debugSummary(), "待决=1"));
}

TEST(FrameConverter, PendingQueueCapsAtSixteenPerTarget) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({"10.1.0.1/24"}), S({}), S({}));

    for (int i = 0; i < 17; ++i)
        fc.handlePacketsFromTun(
            {mkUdp4(v4("10.1.0.1"), v4("10.1.0.99"), 5000, uint16_t(6000 + i))});
    // 每包仍触发 ARP 请求与计数；待决表封顶 16（超限丢新包）
    EXPECT_EQ(rec.frames.size(), 17u);
    std::string s = fc.debugSummary();
    EXPECT_TRUE(contains(s, "ARP问=17"));
    EXPECT_TRUE(contains(s, "待决=16"));
}

TEST(FrameConverter, ArpRequestForOwnedAddressGetsReply) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({"10.1.0.1/24"}), S({}), S({}));
    rec.clear();

    std::vector<uint8_t> req = arpRequest(v4("10.1.0.99"), kPeerMac, v4("10.1.0.1"));
    EXPECT_TRUE(
        fc.handleFrameFromCore(kNwidA, kPeerMac, kMacA, ETH_TYPE_ARP, req.data(), req.size())
            .empty());
    ASSERT_EQ(rec.frames.size(), 1u);
    const SentFrame& f = rec.frames[0];
    EXPECT_EQ(f.dstMac, kPeerMac);
    EXPECT_EQ(f.etherType, ETH_TYPE_ARP);
    std::optional<ArpPacket> rep = parseArp(f.payload.data(), f.payload.size());
    ASSERT_TRUE(rep);
    EXPECT_EQ(rep->op, 2u);
    EXPECT_EQ(rep->senderIp, v4("10.1.0.1")); // sender=被请求的本机地址
    EXPECT_EQ(rep->senderMac, kMacA);
    EXPECT_EQ(rep->targetIp, v4("10.1.0.99"));
    EXPECT_EQ(rep->targetMac, kPeerMac);
    EXPECT_TRUE(contains(fc.debugSummary(), "ARP答=0")); // 应答不计数（对齐 Kotlin：仅 op2 ++）
}

TEST(FrameConverter, MalformedAndForeignInputsIgnored) {
    Recorder rec;
    FrameConverter fc(rec.fn());
    fc.updateNetworkInfo(kNwidA, true, kMacA, S({"10.1.0.1/24"}), S({"fd11::1/64"}), S({}));

    // 未知网络的帧直接丢弃
    std::vector<uint8_t> ok = mkUdp4(v4("10.1.0.1"), v4("10.1.0.99"), 1, 2);
    EXPECT_TRUE(
        fc.handleFrameFromCore(0xdeadULL, kPeerMac, kMacA, ETH_TYPE_IPV4, ok.data(), ok.size())
            .empty());
    // 畸形 ARP（头不匹配）/ 非以太类型 → 无输出
    std::vector<uint8_t> badArp(28, 0);
    EXPECT_TRUE(
        fc.handleFrameFromCore(kNwidA, kPeerMac, kMacA, ETH_TYPE_ARP, badArp.data(), badArp.size())
            .empty());
    EXPECT_TRUE(fc.handleFrameFromCore(kNwidA, kPeerMac, kMacA, 0x8100, ok.data(), ok.size())
                    .empty());
    // TUN 侧：<20B 与 v6<40B 吸收；不产生任何帧、不计数
    fc.handlePacketsFromTun({std::vector<uint8_t>(10, 0x45), std::vector<uint8_t>(30, 0x60)});
    EXPECT_TRUE(rec.frames.empty());
    EXPECT_FALSE(contains(fc.debugSummary(), "无路由丢弃=1"));

    // v6 帧（非 NDP）原样透传写 TUN，且不计入站
    std::vector<uint8_t> udp6 = mkUdp6(v6("fd11::9"), v6("fd11::1"), 7000, 8000);
    std::vector<std::vector<uint8_t>> tun =
        fc.handleFrameFromCore(kNwidA, kPeerMac, kMacA, ETH_TYPE_IPV6, udp6.data(), udp6.size());
    ASSERT_EQ(tun.size(), 1u);
    EXPECT_EQ(tun[0], udp6);
    EXPECT_FALSE(contains(fc.debugSummary(), "入站=1")); // statInV4 仅 v4 帧计数
    // v4 帧透传 + 入站计数
    tun = fc.handleFrameFromCore(kNwidA, kPeerMac, kMacA, ETH_TYPE_IPV4, ok.data(), ok.size());
    ASSERT_EQ(tun.size(), 1u);
    EXPECT_EQ(tun[0], ok);
    EXPECT_TRUE(contains(fc.debugSummary(), "入站=1"));
}
