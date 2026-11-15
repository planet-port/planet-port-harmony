// ArpTable.h — IPv4 ARP 表 + RFC 826 报文构造/解析（A2 Task 1）
//
// 直译源：tunnel/ArpTable.kt（ArpTable + companion request/reply/parse）。
// IP 统一 host order uint32_t；MAC 用 uint64_t 低 48 位（对齐 Kotlin Long）。
// 报文固定 28 字节：htype=1 ptype=0x0800 hlen=6 plen=4，16/32 位字段大端线序。
#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <unordered_map>
#include <vector>
namespace pp {

struct ArpPacket { // IP 一律 host order uint32_t
    uint16_t op;   // 1 请求 2 应答
    uint64_t senderMac, targetMac;
    uint32_t senderIp, targetIp;
};

class ArpTable {
public:
    std::optional<uint64_t> lookup(uint32_t ip) const;
    void update(uint32_t ip, uint64_t mac);
    size_t size() const;

private:
    std::unordered_map<uint32_t, uint64_t> m_map;
};

// RFC 826 报文：htype=1 ptype=0x0800 hlen=6 plen=4，28 字节
std::vector<uint8_t> arpRequest(uint32_t senderIp, uint64_t senderMac, uint32_t targetIp);
std::vector<uint8_t> arpReply(uint32_t senderIp, uint64_t senderMac, uint32_t targetIp, uint64_t targetMac);
// 校验头 6 字节 + op∈{1,2} + len≥28，任一不满足返回 nullopt
std::optional<ArpPacket> parseArp(const uint8_t* payload, size_t len);

} // namespace pp
