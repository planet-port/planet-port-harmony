// test_bytewriter.cpp — 大端流构造器向量（Task 0 地基）
#include "dataplane/ByteWriter.h"
#include <gtest/gtest.h>

using namespace pp;

TEST(ByteWriter, U16BigEndian) {
    ByteWriter w;
    w.u16(0x1234);
    auto b = w.build();
    ASSERT_EQ(b.size(), 2u);
    EXPECT_EQ(b[0], 0x12);
    EXPECT_EQ(b[1], 0x34);
}

TEST(ByteWriter, U32BigEndian) {
    ByteWriter w;
    w.u32(0x11223344u);
    auto b = w.build();
    ASSERT_EQ(b.size(), 4u);
    EXPECT_EQ(b[0], 0x11);
    EXPECT_EQ(b[1], 0x22);
    EXPECT_EQ(b[2], 0x33);
    EXPECT_EQ(b[3], 0x44);
}

TEST(ByteWriter, MacHighByteFirst) {
    ByteWriter w;
    w.mac(0xAABBCCDDEEFFULL);
    auto b = w.build();
    ASSERT_EQ(b.size(), 6u);
    const uint8_t want[6] = {0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF};
    for (int i = 0; i < 6; ++i) EXPECT_EQ(b[size_t(i)], want[i]);
}

TEST(ByteWriter, IpNetworkOrder) {
    ByteWriter w;
    w.ip(0xC0A80101u);
    auto b = w.build();
    ASSERT_EQ(b.size(), 4u);
    EXPECT_EQ(b[0], 192);
    EXPECT_EQ(b[1], 168);
    EXPECT_EQ(b[2], 1);
    EXPECT_EQ(b[3], 1);
}

TEST(ByteWriter, Sequence) {
    ByteWriter w;
    w.u8(1);
    w.u16(2);
    w.u32(3);
    w.bytes(reinterpret_cast<const uint8_t*>("xy"), 2);
    auto b = w.build();
    ASSERT_EQ(b.size(), 9u); // 1+2+4+2
    EXPECT_EQ(b[0], 1);
    EXPECT_EQ(b[1], 0); // u16(2) → 00 02
    EXPECT_EQ(b[2], 2);
    EXPECT_EQ(b[3], 0); // u32(3) → 00 00 00 03
    EXPECT_EQ(b[4], 0);
    EXPECT_EQ(b[5], 0);
    EXPECT_EQ(b[6], 3);
    EXPECT_EQ(b[7], 'x');
    EXPECT_EQ(b[8], 'y');
}
