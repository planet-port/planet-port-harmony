// NAT44.cpp — 多网络源地址 NAT 实现（直译源：tunnel/NAT44.kt）
//
// 校验和增量修正严格按 RFC 1624：HC' = ~(~HC + ~m + m')，反码进位回卷；
// UDP 校验和为 0 表示未计算（校验和卸载），保持 0 不修；非 0 时计算值为 0
// 须传 0xffff（RFC 768，zeroAsFFFF 覆盖 0xFFFF 位）。
#include "dataplane/NAT44.h"
#include <cstddef>
namespace pp {
namespace {

uint16_t read16(const std::vector<uint8_t>& pkt, size_t o) {
    return uint16_t((uint16_t(pkt[o]) << 8) | uint16_t(pkt[o + 1]));
}

uint32_t read32(const std::vector<uint8_t>& pkt, size_t o) {
    return (uint32_t(pkt[o]) << 24) | (uint32_t(pkt[o + 1]) << 16) |
           (uint32_t(pkt[o + 2]) << 8) | uint32_t(pkt[o + 3]);
}

void write32(std::vector<uint8_t>& pkt, size_t offset, uint32_t v) {
    pkt[offset] = uint8_t(v >> 24);
    pkt[offset + 1] = uint8_t((v >> 16) & 0xffu);
    pkt[offset + 2] = uint8_t((v >> 8) & 0xffu);
    pkt[offset + 3] = uint8_t(v & 0xffu);
}

/** MF 位置位或片偏移非零（首 4 位以外的 flags+fragment 全域） */
bool isFragment(const std::vector<uint8_t>& pkt) {
    return (read16(pkt, 6) & 0x3fffu) != 0;
}

/** 片偏移（8 字节单位，首片为 0） */
uint16_t fragOffset(const std::vector<uint8_t>& pkt) {
    return uint16_t(read16(pkt, 6) & 0x1fffu);
}

/** 反码加法（端回卷进位）；入参出参均 0..0xffff */
uint32_t ocAdd(uint32_t a, uint32_t b) {
    uint32_t s = a + b;
    while (s > 0xffffu) s = (s & 0xffffu) + (s >> 16);
    return s;
}

/** RFC 1624: HC' = ~(~HC + ~m + m')，反码进位回卷 */
void adjustChecksum(std::vector<uint8_t>& pkt, size_t ckOffset, uint32_t oldIp,
                    uint32_t newIp, bool zeroAsFFFF = false) {
    if (pkt.size() < ckOffset + 2) return;
    const uint32_t hc = read16(pkt, ckOffset);
    const uint32_t m = ocAdd(oldIp >> 16, oldIp & 0xffffu);
    const uint32_t mp = ocAdd(newIp >> 16, newIp & 0xffffu);
    uint32_t sum = ((~hc) & 0xffffu) + ((~m) & 0xffffu) + mp;
    while (sum > 0xffffu) sum = (sum & 0xffffu) + (sum >> 16);
    uint32_t result = (~sum) & 0xffffu;
    if (zeroAsFFFF && result == 0u) result = 0xffffu; // RFC 768：计算值为 0 传 0xffff
    pkt[ckOffset] = uint8_t(result >> 8);
    pkt[ckOffset + 1] = uint8_t(result);
}

} // namespace

bool FlowKey::operator==(const FlowKey& o) const {
    return nwid == o.nwid && proto == o.proto && remoteIp == o.remoteIp &&
           remotePort == o.remotePort && localPort == o.localPort;
}

size_t FlowKeyHash::operator()(const FlowKey& k) const {
    size_t h = std::hash<uint64_t>()(k.nwid);
    auto mix = [&h](size_t v) {
        h ^= v + size_t(0x9e3779b97f4a7c15ULL) + (h << 6) + (h >> 2);
    };
    mix(std::hash<uint8_t>()(k.proto));
    mix(std::hash<uint32_t>()(k.remoteIp));
    mix(std::hash<uint16_t>()(k.remotePort));
    mix(std::hash<uint16_t>()(k.localPort));
    return h;
}

std::optional<FlowKey> NAT44::outboundKey(const std::vector<uint8_t>& pkt, uint64_t nwid) {
    if (pkt.size() < 24 || (pkt[0] >> 4) != 4) return std::nullopt;
    const uint8_t proto = pkt[9];
    if (proto != 6 && proto != 17) return std::nullopt;
    if (isFragment(pkt)) return std::nullopt;
    const size_t ihl = size_t(pkt[0] & 0x0fu) * 4;
    if (pkt.size() < ihl + 4) return std::nullopt;
    return FlowKey{nwid, proto, read32(pkt, 16), read16(pkt, ihl + 2), read16(pkt, ihl)};
}

std::optional<FlowKey> NAT44::inboundKey(const std::vector<uint8_t>& pkt, uint64_t nwid) {
    if (pkt.size() < 24 || (pkt[0] >> 4) != 4) return std::nullopt;
    const uint8_t proto = pkt[9];
    if (proto != 6 && proto != 17) return std::nullopt;
    if (isFragment(pkt)) return std::nullopt;
    const size_t ihl = size_t(pkt[0] & 0x0fu) * 4;
    if (pkt.size() < ihl + 4) return std::nullopt;
    return FlowKey{nwid, proto, read32(pkt, 12), read16(pkt, ihl), read16(pkt, ihl + 2)};
}

bool NAT44::rewriteAddress(std::vector<uint8_t>& pkt, size_t ipOffset, uint32_t oldIp,
                           uint32_t newIp) {
    if (pkt.size() < 20) return false;
    adjustChecksum(pkt, 10, oldIp, newIp);
    write32(pkt, ipOffset, newIp);
    if (fragOffset(pkt) != 0) return true; // 非首片：ihl 之后是用户载荷不是 L4 头
    const size_t ihl = size_t(pkt[0] & 0x0fu) * 4;
    switch (pkt[9]) {
        case 6: // TCP 校验和在 ihl+16
            adjustChecksum(pkt, ihl + 16, oldIp, newIp);
            break;
        case 17:
            // UDP 校验和在 ihl+6；0 表示未计算（卸载），保持
            if (pkt.size() >= ihl + 8 && !(pkt[ihl + 6] == 0 && pkt[ihl + 7] == 0)) {
                adjustChecksum(pkt, ihl + 6, oldIp, newIp, true);
            }
            break;
        default: break; // ICMP 校验和不覆盖 IP 地址，无需修正
    }
    return true;
}

void NAT44::record(const FlowKey& key, uint32_t origSrc) {
    auto it = m_map.find(key);
    if (it != m_map.end()) {
        it->second.second = now();
        return;
    }
    if (m_map.size() >= kMaxEntries) evictLocked();
    m_map[key] = {origSrc, now()};
}

std::optional<uint32_t> NAT44::lookup(const FlowKey& key) {
    auto it = m_map.find(key);
    if (it == m_map.end()) return std::nullopt;
    const int64_t nowMs = now();
    if (nowMs - it->second.second >= timeoutOf(key)) return std::nullopt; // 空闲超时（见头文件注）
    it->second.second = nowMs;
    return it->second.first;
}

size_t NAT44::size() const { return m_map.size(); }

void NAT44::evictLocked() {
    const int64_t nowMs = now();
    for (auto it = m_map.begin(); it != m_map.end();) {
        if (nowMs - it->second.second >= timeoutOf(it->first)) it = m_map.erase(it);
        else ++it;
    }
    while (m_map.size() >= kMaxEntries) {
        auto oldest = m_map.begin();
        for (auto it = m_map.begin(); it != m_map.end(); ++it) {
            if (it->second.second < oldest->second.second) oldest = it;
        }
        m_map.erase(oldest);
    }
}

int64_t NAT44::timeoutOf(const FlowKey& key) {
    return key.proto == 6 ? kIdleTimeoutTcpMs : kIdleTimeoutUdpMs;
}

} // namespace pp
