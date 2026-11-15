// NdpTable.cpp — IPv6 邻居发现表实现
//
// 直译源：tunnel/NdpTable.kt（130 行）。逐函数对照：
//   lookup/update/count → NdpTable 实例方法（HashMap+synchronized → std::map）
//   neighborSolicitation/neighborAdvertisement/icmpv6 → companion 静态构造
//   icmpv6Checksum/multicastMAC/solicitedNodeMulticast/allNodesMulticast
//   parse/isNDP → parseNdp/isNDP
// 直译源为上游修复版语义：icmpv6()/parse() 的链路层地址选项类型按报文分派
// （NS=源选项 type 1，NA=目标选项 type 2，解析侧 NA 宽限收 1）
#include "NdpTable.h"

#include <algorithm>

namespace pp {

// ---- 邻居表（Kotlin NdpTable 实例方法） ----

std::optional<uint64_t> NdpTable::lookup(const Ipv6Address& v6) const {
    auto it = m_map.find(v6);
    if (it == m_map.end()) return std::nullopt;
    return it->second;
}

void NdpTable::update(const Ipv6Address& v6, uint64_t mac) { m_map[v6] = mac; }

size_t NdpTable::size() const { return m_map.size(); }

// ---- 报文构造 ----

// RFC 4861 布局：ICMPv6 头(4) + flags/保留(4) + target(16) + 链路层地址选项(8)，
// 与 parseNdp 对齐（Kotlin 私有 icmpv6()）
static std::vector<uint8_t> buildIcmpv6(uint8_t type, const Ipv6Address& target,
                                        uint64_t mac, uint8_t flags) {
    std::vector<uint8_t> p(8 + 16 + 8, 0);
    p[0] = type;
    p[1] = 0; // code
    // p[2..3] 校验和恒 0，由调用方 icmpv6Checksum 求值回写
    p[4] = flags; // NS 恒 0；NA 见 neighborAdvertisement 的 Solicited/Override 语义
    std::copy(target.bytes.begin(), target.bytes.end(), p.begin() + 8);
    // 选项类型按报文分派（RFC 4861 §4.6.1/§4.6.2）：NS 携带源链路层地址选项
    // （type 1），NA 携带目标链路层地址选项（type 2）——真实内核 ndisc 只按
    // 各自类型读取选项，类型错配的报文被丢弃（对端解析永远 INCOMPLETE）
    p[24] = (type == 136) ? 2 : 1;
    p[25] = 1; // 选项长度=1（8 字节单位）
    for (int shift = 40; shift >= 0; shift -= 8) // MAC 大端写入 p[26..31]
        p[26 + size_t(5 - shift / 8)] = uint8_t((mac >> shift) & 0xff);
    return p;
}

std::vector<uint8_t> neighborSolicitation(const Ipv6Address& target, uint64_t senderMac) {
    return buildIcmpv6(135, target, senderMac, 0);
}

std::vector<uint8_t> neighborAdvertisement(const Ipv6Address& target, uint64_t senderMac,
                                           uint8_t flags) {
    return buildIcmpv6(136, target, senderMac, flags);
}

// ---- companion 静态工具 ----

Ipv6Address solicitedNodeMulticast(const Ipv6Address& target) {
    Ipv6Address m{}; // 其余字节恒 0
    m.bytes[0] = 0xff;
    m.bytes[1] = 0x02;
    m.bytes[11] = 0x01;
    m.bytes[12] = 0xff;
    m.bytes[13] = target.bytes[13];
    m.bytes[14] = target.bytes[14];
    m.bytes[15] = target.bytes[15];
    return m;
}

// 直译 Kotlin 字面值：仅 it[1]=0x02、it[15]=0x01，未设 it[0]=0xff——所得地址
// 是 2::1，与其「ff02::1」注释不符（Kotlin 侧笔误）。按行为规格唯一来源原则
// 原样保留（见 NdpTable.h 注释）；低 32 位与 ff02::1 一致，组播 MAC 不受影响。
Ipv6Address allNodesMulticast() {
    Ipv6Address m{}; // 其余字节恒 0
    m.bytes[1] = 0x02;
    m.bytes[15] = 0x01;
    return m;
}

uint64_t multicastMAC(const Ipv6Address& v6) {
    uint64_t low = 0;
    for (int i = 12; i < 16; ++i) low = (low << 8) | v6.bytes[size_t(i)];
    return 0x333300000000ULL | low;
}

// 伪头校验和：RFC 1071 逐 16 位字求和（字节序大端）+ 高位折叠 + 取反。
// max 和 ≈ 0xffff*字数 ≤ 0x7fff8000，uint32_t 不溢出。
uint16_t icmpv6Checksum(const Ipv6Address& src, const Ipv6Address& dst,
                        const uint8_t* payload, size_t len) {
    uint32_t sum = 0;
    for (int i = 0; i < 16; i += 2)
        sum += (uint32_t(src.bytes[size_t(i)]) << 8) | src.bytes[size_t(i + 1)];
    for (int i = 0; i < 16; i += 2)
        sum += (uint32_t(dst.bytes[size_t(i)]) << 8) | dst.bytes[size_t(i + 1)];
    sum += uint32_t(len) & 0xffffu; // 伪头 32bit 长度的高 16 位恒 0，单字相加等价
    sum += 58;                      // nextHeader = ICMPv6
    for (size_t i = 0; i < len; i += 2) {
        if (i == 2) continue; // 校验和字段(2..3)计算前逻辑清零（Kotlin 先置 0 再求和）
        uint32_t hi = payload[i];
        uint32_t lo = (i + 1 < len) ? payload[i + 1] : 0; // 奇数长度尾字节补零
        sum += (hi << 8) | lo;
    }
    while (sum >> 16 != 0) sum = (sum & 0xffffu) + (sum >> 16);
    return uint16_t(~sum & 0xffffu);
}

// ---- 解析 ----

// 解析 NS/NA 载荷；链路层地址选项类型按报文分派：NS 只认源选项(1)，NA 认
// 目标选项(2)——并宽限收 1（兼容仍按未修复构造发 type 1 的软件姊妹端）。
// 未命中时 senderMac 保持空，报文仍解析成功（对齐源，调用方另行处理）。
std::optional<NdpPacket> parseNdp(const uint8_t* payload, size_t len) {
    if (len < 24) return std::nullopt;
    if (payload[0] != 135 && payload[0] != 136) return std::nullopt;
    NdpPacket out;
    out.type = payload[0];
    std::copy(payload + 8, payload + 24, out.target.bytes.begin());
    if (len >= 32 && payload[25] == 1) { // 选项长度=1（8 字节单位）；SLL/TLL 选项可选
        const bool isNA = payload[0] == 136;
        if (isNA ? (payload[24] == 2 || payload[24] == 1) : (payload[24] == 1)) {
            uint64_t v = 0;
            for (int i = 2; i < 8; ++i) v = (v << 8) | payload[24 + size_t(i)];
            out.senderMac = v;
        }
    }
    return out;
}

bool isNDP(const std::vector<uint8_t>& ipv6Packet) {
    if (ipv6Packet.size() < 48) return false; // IPv6 头 40 + ICMPv6 头 8
    if (ipv6Packet[6] != 58) return false;    // next header
    const uint8_t t = ipv6Packet[40];
    return t == 135 || t == 136;
}

} // namespace pp
