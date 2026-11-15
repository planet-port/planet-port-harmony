// NdpTable.h — IPv6 邻居发现（NS/NA）表与报文构造/解析
//
// 直译源：tunnel/NdpTable.kt（Android 领先版：较 iOS 多 ICMPv6 伪头校验和、
// 出站 NS 用本机真实源地址、DAD 探测按 RFC 4861 §7.2.4 全节点组播回 NA）。
// 实例方法对应 Kotlin 实例成员；companion 静态工具导出为 namespace pp 自由函数
// （FrameConverter 依赖）。地址类型复用 Net.h 的 Ipv6Address（按内容判等）。
#pragma once
#include <cstddef>
#include <cstdint>
#include <map>
#include <optional>
#include <vector>

#include "Net.h"

namespace pp {

// NS/NA 的 ICMPv6 载荷解析结果（NdpTable.kt 内嵌 NdpPacket）
struct NdpPacket {
    uint8_t type; // 135 NS / 136 NA
    Ipv6Address target;
    std::optional<uint64_t> senderMac; // 无 SLL 选项时为空
};

// IPv6 邻居发现表（NS/NA 软件处理）。Kotlin 侧 HashMap+synchronized 按内容判等，
// C++ 侧 Ipv6Address 自带 operator< 以作 std::map key；数据面单线程驱动，无锁。
class NdpTable {
public:
    std::optional<uint64_t> lookup(const Ipv6Address& v6) const;
    void update(const Ipv6Address& v6, uint64_t mac);
    size_t size() const; // Kotlin val count

private:
    std::map<Ipv6Address, uint64_t> m_map;
};

// ---- 以下对应 NdpTable companion 静态工具 ----

// NS 的 ICMPv6 载荷：ICMPv6 头(4)+flags/保留(4)+target(16)+SLL 选项(8)=32B，
// type=135 code=0 flags=0（RFC 4861）。校验和字段恒 0，由调用方以
// icmpv6Checksum 求值回写（Kotlin 亦如此分工，见 FrameConverter.kt）。
std::vector<uint8_t> neighborSolicitation(const Ipv6Address& target, uint64_t senderMac);

// NA 的 ICMPv6 载荷，type=136 code=0。flags=0x60（Solicited+Override）是应答
// 已知请求方的单播形态；DAD 探测按 RFC 4861 §7.2.4 用 0x20（仅 Override）+
// 目的换 ff02::1——由调用方传 flags 并自选 dst。
std::vector<uint8_t> neighborAdvertisement(const Ipv6Address& target, uint64_t senderMac,
                                           uint8_t flags = 0x60);

// 请求节点组播地址 ff02::1:ffXX:XXXX（取 target 低 24 位）
Ipv6Address solicitedNodeMulticast(const Ipv6Address& target);

// 全节点组播地址（DAD 应答的目的地址，RFC 4861 §7.2.4）。注意：直译 Kotlin
// 源码字面值（仅置 bytes[1]=0x02、bytes[15]=0x01），得到的地址是 2::1 而非其
// 注释所称的 ff02::1（Kotlin 漏设 bytes[0]=0xff）——按行为规格唯一来源原则
// 原样复现，派生的 L2 组播 MAC（低 32 位相同）不受影响。
Ipv6Address allNodesMulticast();

// IPv6 组播地址 → 组播 MAC（0x3333 + 低 32 位）
uint64_t multicastMAC(const Ipv6Address& v6);

// ICMPv6 伪头校验和（RFC 4443 §8.1）：src(16B)+dst(16B)+载荷长度(32bit)+
// 3 零字节+nextHeader(58)，与 ICMPv6 载荷一起按 RFC 1071 互联网校验和折叠。
// 校验和字段（payload[2..3]）计算前按 0 参与求和——真实节点内核会校验，
// 恒 0 的报文被丢弃（Android↔Android 双端软件路径不校验故此前未暴露）。
uint16_t icmpv6Checksum(const Ipv6Address& src, const Ipv6Address& dst,
                        const uint8_t* payload, size_t len);

// 解析 NS/NA 载荷：<24B 或 type 非 135/136 返回 nullopt；链路层地址选项按报文
// 类型分派（对齐 Android 上游修复版语义）：NS 只认 SLL type=1，NA 宽限接受
// type∈{2,1}（TLL 优先语义）；len=1 才取 MAC。不校验 ICMPv6 校验和——内核已验。
std::optional<NdpPacket> parseNdp(const uint8_t* payload, size_t len);

// 是否 NDP 报文（完整 IPv6 包：next header==58 且 ICMPv6 type 135/136）
bool isNDP(const std::vector<uint8_t>& ipv6Packet);

} // namespace pp
