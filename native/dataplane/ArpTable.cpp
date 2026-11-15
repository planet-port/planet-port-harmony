// ArpTable.cpp — IPv4 ARP 表 + RFC 826 报文构造/解析（A2 Task 1）
//
// 直译源：tunnel/ArpTable.kt（ArpTable 与 companion 的 request/reply/parse）。
// Kotlin 内联的 ByteWriter 已抽到 dataplane/ByteWriter.h，此处直接复用。
#include "dataplane/ArpTable.h"

#include "dataplane/ByteWriter.h"

namespace pp {
namespace {

// HEADER = byteArrayOf(0, 1, 0x08, 0, 6, 4)：htype=1 ptype=IPv4 hlen=6 plen=4
constexpr uint8_t kHeader[6] = {0x00, 0x01, 0x08, 0x00, 0x06, 0x04};
constexpr size_t kArpLen = 28; // 8 头 + 6+4 发送方 + 6+4 目标方

uint64_t readMac(const uint8_t* p, size_t o) { // 大端 6 字节 → 低 48 位
    uint64_t v = 0;
    for (size_t i = 0; i < 6; ++i) v = (v << 8) | p[o + i];
    return v;
}

uint32_t readIp(const uint8_t* p, size_t o) { // 大端 4 字节 → host order
    return (uint32_t(p[o]) << 24) | (uint32_t(p[o + 1]) << 16) |
           (uint32_t(p[o + 2]) << 8) | uint32_t(p[o + 3]);
}

} // namespace

std::optional<uint64_t> ArpTable::lookup(uint32_t ip) const {
    auto it = m_map.find(ip);
    if (it == m_map.end()) return std::nullopt;
    return it->second;
}

void ArpTable::update(uint32_t ip, uint64_t mac) { m_map[ip] = mac; }

size_t ArpTable::size() const { return m_map.size(); }

std::vector<uint8_t> arpRequest(uint32_t senderIp, uint64_t senderMac, uint32_t targetIp) {
    ByteWriter w(kArpLen);
    w.bytes(kHeader, 6);
    w.u16(1);                            // op=request
    w.mac(senderMac);                    // 发送方 MAC/IP 紧跟 ARP 头
    w.ip(senderIp);
    w.mac(0);                            // request 的 targetMac 填 0
    w.ip(targetIp);
    return w.build();
}

std::vector<uint8_t> arpReply(uint32_t senderIp, uint64_t senderMac, uint32_t targetIp, uint64_t targetMac) {
    ByteWriter w(kArpLen);
    w.bytes(kHeader, 6);
    w.u16(2);                            // op=reply，字段全填
    w.mac(senderMac);
    w.ip(senderIp);
    w.mac(targetMac);
    w.ip(targetIp);
    return w.build();
}

std::optional<ArpPacket> parseArp(const uint8_t* payload, size_t len) {
    if (!payload || len < kArpLen) return std::nullopt;
    for (size_t i = 0; i < 6; ++i) // 头 6 字节逐字节比对（对齐 Kotlin 逐项判等）
        if (payload[i] != kHeader[i]) return std::nullopt;
    uint16_t op = uint16_t((uint16_t(payload[6]) << 8) | payload[7]);
    if (op != 1 && op != 2) return std::nullopt;
    // 成员顺序：op, senderMac, targetMac, senderIp, targetIp
    return ArpPacket{
        op,
        readMac(payload, 8),
        readMac(payload, 18),
        readIp(payload, 14),
        readIp(payload, 24),
    };
}

} // namespace pp
