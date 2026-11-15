// test_arptable.cpp — ARP 表与 RFC 826 报文向量（A2 Task 1，直译 ArpTable.kt）
#include "dataplane/ArpTable.h"

#include <gtest/gtest.h>

using namespace pp;

namespace {
constexpr uint32_t kIp1 = 0x0A000001u;  // 10.0.0.1
constexpr uint32_t kIp2 = 0x0A000002u;  // 10.0.0.2
constexpr uint64_t kMacA = 0xAABBCCDDEEFFULL;
constexpr uint64_t kMacB = 0x112233445566ULL;
} // namespace

// ① request：首八字节 `00 01 08 00 06 04 00 01`，targetMac 段全 0
TEST(ArpTable, RequestWireFormat) {
    auto b = arpRequest(kIp1, kMacA, kIp2);
    ASSERT_EQ(b.size(), 28u);
    const uint8_t head[8] = {0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01};
    for (int i = 0; i < 8; ++i) EXPECT_EQ(b[size_t(i)], head[i]) << "offset " << i;
    const uint8_t senderMac[6] = {0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF};
    for (int i = 0; i < 6; ++i) EXPECT_EQ(b[size_t(8 + i)], senderMac[i]);
    EXPECT_EQ(b[14], 10); EXPECT_EQ(b[15], 0); // senderIp = 10.0.0.1（大端）
    EXPECT_EQ(b[16], 0); EXPECT_EQ(b[17], 1);
    for (int i = 18; i < 24; ++i) EXPECT_EQ(b[size_t(i)], 0) << "targetMac 段 offset " << i;
    EXPECT_EQ(b[24], 10); EXPECT_EQ(b[25], 0); // targetIp = 10.0.0.2
    EXPECT_EQ(b[26], 0); EXPECT_EQ(b[27], 2);
}

// ② reply：op=2，targetMac 填实
TEST(ArpTable, ReplyWireFormat) {
    auto b = arpReply(kIp1, kMacA, kIp2, kMacB);
    ASSERT_EQ(b.size(), 28u);
    const uint8_t head[8] = {0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x02};
    for (int i = 0; i < 8; ++i) EXPECT_EQ(b[size_t(i)], head[i]) << "offset " << i;
    const uint8_t targetMac[6] = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66};
    for (int i = 0; i < 6; ++i) EXPECT_EQ(b[size_t(18 + i)], targetMac[i]);
    EXPECT_EQ(b[24], 10); EXPECT_EQ(b[27], 2); // targetIp = 10.0.0.2
}

// ③ 构造 → parse → 字段相等（request 与 reply 各跑一遍）
TEST(ArpTable, ParseRoundTrip) {
    auto req = parseArp(arpRequest(kIp1, kMacA, kIp2).data(), 28);
    ASSERT_TRUE(req);
    EXPECT_EQ(req->op, 1);
    EXPECT_EQ(req->senderMac, kMacA);
    EXPECT_EQ(req->senderIp, kIp1);
    EXPECT_EQ(req->targetMac, 0u);
    EXPECT_EQ(req->targetIp, kIp2);

    auto rep = parseArp(arpReply(kIp1, kMacA, kIp2, kMacB).data(), 28);
    ASSERT_TRUE(rep);
    EXPECT_EQ(rep->op, 2);
    EXPECT_EQ(rep->senderMac, kMacA);
    EXPECT_EQ(rep->senderIp, kIp1);
    EXPECT_EQ(rep->targetMac, kMacB);
    EXPECT_EQ(rep->targetIp, kIp2);
}

// ④ 截断 27B → nullopt
TEST(ArpTable, ParseRejectsTruncated) {
    auto full = arpRequest(kIp1, kMacA, kIp2);
    EXPECT_EQ(parseArp(full.data(), 27), std::nullopt);
    EXPECT_EQ(parseArp(nullptr, 28), std::nullopt);
}

// ⑤ op=3 → nullopt；头 6 字节不符也 → nullopt
TEST(ArpTable, ParseRejectsBadOpOrHeader) {
    auto b = arpRequest(kIp1, kMacA, kIp2);
    b[7] = 3; // op=3
    EXPECT_EQ(parseArp(b.data(), b.size()), std::nullopt);

    auto h = arpRequest(kIp1, kMacA, kIp2);
    h[2] = 0x00; // ptype 非 0x0800
    EXPECT_EQ(parseArp(h.data(), h.size()), std::nullopt);
}

// ⑥ 表：lookup 未中 → nullopt；update 后命中；size 跟随
TEST(ArpTable, TableLookupUpdate) {
    ArpTable t;
    EXPECT_EQ(t.size(), 0u);
    EXPECT_EQ(t.lookup(kIp1), std::nullopt);
    t.update(kIp1, kMacA);
    EXPECT_EQ(t.lookup(kIp1), std::optional<uint64_t>(kMacA));
    t.update(kIp1, kMacB); // 同 IP 覆盖
    EXPECT_EQ(t.lookup(kIp1), std::optional<uint64_t>(kMacB));
    t.update(kIp2, kMacA);
    EXPECT_EQ(t.size(), 2u);
    EXPECT_EQ(t.lookup(kIp2), std::optional<uint64_t>(kMacA));
}
