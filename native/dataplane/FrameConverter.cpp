// FrameConverter.cpp — IP 包 ↔ 虚拟网帧转换层实现（A2 计划 Task 7）
//
// 直译源：tunnel/FrameConverter.kt（361 行）。逐段对照：
//   updateNetworkInfo/removeNetwork/retainOnly/removeNetworkLocked → 同名（enabled=false 即移除）
//   rebuildAggregatesLocked/orderedContextsLocked                  → 同名（order 驱动）
//   debugSummary                                                   → 诊断行逐字段对齐
//   handlePacketsFromTun/handleV4Locked/handleV6Locked             → tun→core 三段
//   handleFrameFromCore/handleARPLocked/handleNDPLocked            → core→tun 三段
//   sendKeepalive/sendARPRequestLocked/sendNeighborSolicitationLocked → 控制帧
//   ipv6Packet/bigEndianIP32/isIPv4Multicast/isLocalIPv4Locked/
//   isIPv6Multicast/ipv4MulticastMAC                                → 地址工具
// 集成差异（均已在对应位置注释）：
//   ① handleV4 的 NAT 改写需就地变更包体：Kotlin 直接改调用方 ByteArray，本层
//      入参为 const 引用，仅在确需改写时拷贝一份（常态路径零拷贝）。
//   ② icmpv6Checksum 为纯函数返回校验和（不回写载荷），调用方写回 [2..3]。
//   ③ 诊断行「待决」按 Kotlin 原文仅统计 pendingV4（C++ 侧 pendingV4/pendingV6
//      是两个 PendingQueue 实例、各持一族；波 1 头注释所称「total() 合计两族」
//      指单实例内两张表，见 debugSummary 内注释）。
//   ④ NAT44.record 对已存在流仅刷新保留旧 origSrc——Kotlin 同行为，直译不改写。
#include "dataplane/FrameConverter.h"

#include <algorithm>
#include <chrono>
#include <cstdio>

namespace pp {
namespace {

// 缺省 NAT44 时钟：进程内单调毫秒（对齐 SystemClock.elapsedRealtime 语义）
int64_t steadyMillis() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

// CoreSend 简写：Kotlin runtime.processVirtualNetworkFrame(nwid, src, dst, type, 0, frame)
void sendCore(const FrameConverter::CoreSend& send, uint64_t nwid, uint64_t srcMac,
              uint64_t dstMac, uint16_t etherType, const std::vector<uint8_t>& frame) {
    send(nwid, srcMac, dstMac, etherType, 0, frame.data(), frame.size());
}

} // namespace

FrameConverter::FrameConverter(CoreSend coreSend, NAT44::Clock clock)
    : m_coreSend(std::move(coreSend))
    , m_nat(clock ? std::move(clock)
                  : NAT44::Clock([] { return steadyMillis(); })) {}

// ---- 上下文管理（配置回调路径） ----

void FrameConverter::updateNetworkInfo(uint64_t nwid, bool enabled, uint64_t mac,
                                       const std::vector<std::string>& ipv4,
                                       const std::vector<std::string>& ipv6,
                                       const std::vector<std::string>& routes) {
    std::lock_guard<std::mutex> lk(m_lock);
    if (!enabled) {
        removeNetworkLocked(nwid);
        return;
    }
    auto it = m_contexts.find(nwid);
    if (it != m_contexts.end()) {
        it->second->update(mac, ipv4, ipv6, routes);
    } else {
        m_order.push_back(nwid); // 激活顺序：首次 upsert 追加
        m_contexts[nwid] = std::make_unique<NetworkContext>(nwid, mac, ipv4, ipv6, routes);
    }
    rebuildAggregatesLocked();
}

void FrameConverter::removeNetwork(uint64_t nwid) {
    std::lock_guard<std::mutex> lk(m_lock);
    removeNetworkLocked(nwid);
}

void FrameConverter::retainOnly(const std::vector<uint64_t>& nwids) {
    std::lock_guard<std::mutex> lk(m_lock);
    auto contained = [&nwids](uint64_t nwid) {
        return std::find(nwids.begin(), nwids.end(), nwid) != nwids.end();
    };
    std::vector<uint64_t> removed;
    for (const auto& kv : m_contexts)
        if (!contained(kv.first)) removed.push_back(kv.first);
    if (removed.empty()) return;
    for (uint64_t nwid : removed) {
        m_contexts.erase(nwid);
        m_order.erase(std::remove(m_order.begin(), m_order.end(), nwid), m_order.end());
    }
    rebuildAggregatesLocked();
}

void FrameConverter::removeNetworkLocked(uint64_t nwid) {
    if (m_contexts.erase(nwid) == 0) return;
    m_order.erase(std::remove(m_order.begin(), m_order.end(), nwid), m_order.end());
    rebuildAggregatesLocked();
}

void FrameConverter::rebuildAggregatesLocked() {
    std::vector<const NetworkContext*> ordered;
    ordered.reserve(m_order.size());
    for (uint64_t nwid : m_order) {
        auto it = m_contexts.find(nwid);
        if (it != m_contexts.end()) ordered.push_back(it->second.get());
    }
    m_aggV4 = NetworkContextMath::buildAggregateV4(ordered);
    m_aggV6 = NetworkContextMath::buildAggregateV6(ordered);
}

std::vector<NetworkContext*> FrameConverter::orderedContextsLocked() {
    std::vector<NetworkContext*> out;
    out.reserve(m_order.size());
    for (uint64_t nwid : m_order) {
        auto it = m_contexts.find(nwid);
        if (it != m_contexts.end()) out.push_back(it->second.get());
    }
    return out;
}

// 诊断快照（验证页/排查用）
std::string FrameConverter::debugSummary() {
    std::lock_guard<std::mutex> lk(m_lock);
    std::string out = "contexts=" + std::to_string(m_contexts.size()) +
                      " aggV4=" + std::to_string(m_aggV4.size()) +
                      " aggV6=" + std::to_string(m_aggV6.size()) +
                      " 无路由丢弃=" + std::to_string(m_statNoRoute) +
                      " NAT流表=" + std::to_string(m_nat.size());
    for (uint64_t nwid : m_order) {
        auto it = m_contexts.find(nwid);
        if (it == m_contexts.end()) continue;
        const NetworkContext& c = *it->second;
        char head[48];
        std::snprintf(head, sizeof(head), "\nctx %016llx mac=%012llx v4=[",
                      static_cast<unsigned long long>(c.nwid),
                      static_cast<unsigned long long>(c.mac));
        out += head;
        for (size_t i = 0; i < c.ipv4.size(); ++i) {
            if (i != 0) out += ',';
            out += dottedV4(c.ipv4[i]);
        }
        out += "] routes=" + std::to_string(c.routes4.size()) + "/" +
               std::to_string(c.routes6.size()) + " 出站=" + std::to_string(c.statFwdV4) +
               " 入站=" + std::to_string(c.statInV4) + " ARP问=" + std::to_string(c.statArpReq) +
               " ARP答=" + std::to_string(c.statArpReply) +
               " 保活=" + std::to_string(c.statKeepalive) + " ARP表=" + std::to_string(c.arp.size()) +
               // Kotlin 诊断行只统计 pendingV4；C++ 侧 pendingV4/pendingV6 是两个
               // PendingQueue 实例、各持一族（波 1 头注释「total() 合计两族」指单实例
               // 内两张表）——按 Kotlin 原文口径仅取 pendingV4，v6 待决不进诊断行
               " 待决=" + std::to_string(c.pendingV4->total()) +
               " 源不符=" + std::to_string(c.statSrcMismatch) +
               (c.lastSrcMismatch ? "(" + dottedV4(*c.lastSrcMismatch) + ")" : std::string()) +
               " NAT出=" + std::to_string(c.statNatOut) + " NAT入=" + std::to_string(c.statNatIn);
    }
    return out;
}

// ---- tun -> core（Dataplane 读线程调用） ----

void FrameConverter::handlePacketsFromTun(const std::vector<std::vector<uint8_t>>& packets) {
    std::lock_guard<std::mutex> lk(m_lock);
    if (m_contexts.empty()) return;
    for (const std::vector<uint8_t>& pkt : packets) {
        if (pkt.size() < 20) continue;
        const unsigned ver = (pkt[0] >> 4) & 0xfu;
        if (ver == 4) {
            handleV4Locked(pkt);
        } else if (ver == 6 && pkt.size() >= 40) {
            handleV6Locked(pkt);
        }
    }
}

void FrameConverter::handleV4Locked(const std::vector<uint8_t>& raw) {
    const uint32_t dst = bigEndianIP32(raw, 16);
    // 广播/组播直送所有有 IPv4 地址的网络（组播包发对应组播 MAC）
    if (dst == 0xffffffffu || isIPv4Multicast(dst)) {
        const uint64_t dstMac = (dst == 0xffffffffu) ? BROADCAST_MAC : ipv4MulticastMAC(dst);
        for (NetworkContext* ctx : orderedContextsLocked()) {
            if (ctx->ipv4.empty() || ctx->mac == 0) continue;
            sendCore(m_coreSend, ctx->nwid, ctx->mac, dstMac, ETH_TYPE_IPV4, raw);
        }
        return;
    }
    // 聚合表最长前缀匹配（前缀降序、同前缀先激活者胜）；无命中丢弃
    const AggregateV4Entry* match = nullptr;
    for (const AggregateV4Entry& e : m_aggV4)
        if (e.route.matches(dst)) {
            match = &e;
            break;
        }
    if (match == nullptr) {
        ++m_statNoRoute;
        return;
    }
    auto it = m_contexts.find(match->nwid);
    if (it == m_contexts.end()) return;
    NetworkContext& ctx = *it->second;
    if (ctx.mac == 0) return;
    // 多网络源地址 NAT（iOS FrameConverter 同构）：内核按接口主地址选源，目的属于
    // 另一网络时源是错的。源不属于本网时：是本机另一网络地址则改写为本网地址
    // （优先取命中路由网段的）并登记流表；单网络源恒在列表内，一次比较都不改写
    //（零回归直通）
    const uint32_t src = bigEndianIP32(raw, 12);
    const bool srcOwned =
        std::find(ctx.ipv4.begin(), ctx.ipv4.end(), src) != ctx.ipv4.end();
    // 改写需就地变更包体：Kotlin 直接改调用方 ByteArray，本层入参 const，仅在
    // 确需改写时拷贝（此后本函数一律用 pkt，待决表/上送帧与 Kotlin 同为改写后内容）
    std::vector<uint8_t> rewritten;
    const std::vector<uint8_t>* payload = &raw;
    if (!srcOwned) {
        if (isLocalIPv4Locked(src)) {
            uint32_t newSrc = 0;
            bool found = false;
            for (uint32_t a : ctx.ipv4) // 优先取命中路由网段的地址
                if (match->route.matches(a)) {
                    newSrc = a;
                    found = true;
                    break;
                }
            if (!found) {
                if (ctx.ipv4.empty()) return;
                newSrc = ctx.ipv4.front();
            }
            rewritten = raw;
            if (std::optional<FlowKey> key = NAT44::outboundKey(rewritten, ctx.nwid))
                m_nat.record(*key, src); // 已存在仅刷新保留旧 origSrc（Kotlin 同，直译不改写）
            NAT44::rewriteAddress(rewritten, 12, src, newSrc);
            ++ctx.statNatOut;
            payload = &rewritten;
        } else {
            ++ctx.statSrcMismatch;
            ctx.lastSrcMismatch = src;
        }
    }
    const std::vector<uint8_t>& pkt = *payload;
    const uint32_t nextHop =
        match->route.gateway ? *match->route.gateway : dst; // gateway ?: dst
    if (std::optional<uint64_t> mac = ctx.arp.lookup(nextHop)) {
        sendCore(m_coreSend, ctx.nwid, ctx.mac, *mac, ETH_TYPE_IPV4, pkt);
        ++ctx.statFwdV4;
        return;
    }
    // 未中：挂起待决（超上限丢新包）+ 发 ARP 请求
    std::vector<std::vector<uint8_t>>& pending = ctx.pendingV4->v4[nextHop];
    if (pending.size() < kMaxPendingPerTarget) pending.push_back(pkt);
    ++ctx.statArpReq;
    sendARPRequestLocked(ctx, nextHop);
}

void FrameConverter::handleV6Locked(const std::vector<uint8_t>& pkt) {
    Ipv6Address dst;
    std::copy(pkt.begin() + 24, pkt.begin() + 40, dst.bytes.begin());
    if (isIPv6Multicast(dst)) {
        const uint64_t mac = multicastMAC(dst);
        for (NetworkContext* ctx : orderedContextsLocked()) {
            if (ctx->ipv6.empty() || ctx->mac == 0) continue;
            sendCore(m_coreSend, ctx->nwid, ctx->mac, mac, ETH_TYPE_IPV6, pkt);
        }
        return;
    }
    const AggregateV6Entry* match = nullptr;
    for (const AggregateV6Entry& e : m_aggV6)
        if (e.route.matches(dst)) {
            match = &e;
            break;
        }
    if (match == nullptr) return; // v6 无命中静默丢弃（不计数，对齐 Kotlin）
    auto it = m_contexts.find(match->nwid);
    if (it == m_contexts.end()) return;
    NetworkContext& ctx = *it->second;
    if (ctx.mac == 0) return;
    const Ipv6Address nextHop = match->route.gateway ? *match->route.gateway : dst;
    if (std::optional<uint64_t> mac = ctx.ndp.lookup(nextHop)) {
        sendCore(m_coreSend, ctx.nwid, ctx.mac, *mac, ETH_TYPE_IPV6, pkt);
        return;
    }
    std::vector<std::vector<uint8_t>>& pending = ctx.pendingV6->v6[nextHop];
    if (pending.size() < kMaxPendingPerTarget) pending.push_back(pkt);
    sendNeighborSolicitationLocked(ctx, nextHop);
}

// ---- core -> tun（消费协程调用）；返回 IP 包列表写入 tun ----

std::vector<std::vector<uint8_t>> FrameConverter::handleFrameFromCore(
    uint64_t nwid, uint64_t srcMac, uint64_t dstMac, uint16_t etherType,
    const uint8_t* frame, size_t len) {
    std::lock_guard<std::mutex> lk(m_lock);
    (void)dstMac; // Kotlin 同款：目的 MAC 仅入参对齐帧头，软件路径不消费
    auto it = m_contexts.find(nwid);
    if (it == m_contexts.end()) return {};
    NetworkContext& ctx = *it->second;
    switch (etherType) {
    case ETH_TYPE_ARP: {
        handleARPLocked(ctx, frame, len, srcMac);
        return {};
    }
    case ETH_TYPE_IPV6: {
        std::vector<uint8_t> pkt(frame, frame + len);
        if (isNDP(pkt)) {
            handleNDPLocked(ctx, pkt, srcMac);
            return {};
        }
        return {std::move(pkt)};
    }
    case ETH_TYPE_IPV4: {
        ++ctx.statInV4;
        std::vector<uint8_t> pkt(frame, frame + len);
        // NAT44 入站回写：命中流表的回包把目的地址回写为原始源，否则应用 socket
        //（本地地址=原始错误源）匹配不上
        if (std::optional<FlowKey> key = NAT44::inboundKey(pkt, nwid)) {
            if (std::optional<uint32_t> orig = m_nat.lookup(*key)) {
                NAT44::rewriteAddress(pkt, 16, bigEndianIP32(pkt, 16), *orig);
                ++ctx.statNatIn;
            }
        }
        return {std::move(pkt)};
    }
    default:
        return {};
    }
}

/** ARP 处理（仅更新本网络缓存）：请求对本网持有地址应答；应答更新表并冲刷待决 */
void FrameConverter::handleARPLocked(NetworkContext& ctx, const uint8_t* payload, size_t len,
                                     uint64_t senderMac) {
    std::optional<ArpPacket> p = parseArp(payload, len);
    if (!p) return;
    if (p->op == 1) {
        if (std::find(ctx.ipv4.begin(), ctx.ipv4.end(), p->targetIp) == ctx.ipv4.end()) return;
        // 字段序对齐 Kotlin reply(target, 本机, sender, senderMac)：sender=被请求的本机地址
        std::vector<uint8_t> reply = arpReply(p->targetIp, ctx.mac, p->senderIp, p->senderMac);
        sendCore(m_coreSend, ctx.nwid, ctx.mac, senderMac, ETH_TYPE_ARP, reply);
        return;
    }
    if (p->op == 2) {
        ++ctx.statArpReply;
        ctx.arp.update(p->senderIp, p->senderMac);
        auto wait = ctx.pendingV4->v4.find(p->senderIp);
        if (wait == ctx.pendingV4->v4.end()) return;
        std::vector<std::vector<uint8_t>> waiting = std::move(wait->second);
        ctx.pendingV4->v4.erase(wait);
        for (const std::vector<uint8_t>& pkt : waiting)
            sendCore(m_coreSend, ctx.nwid, ctx.mac, p->senderMac, ETH_TYPE_IPV4, pkt);
    }
}

void FrameConverter::handleNDPLocked(NetworkContext& ctx, const std::vector<uint8_t>& packet,
                                     uint64_t senderMac) {
    std::vector<uint8_t> icmp6(packet.begin() + 40, packet.end());
    Ipv6Address srcIPv6;
    std::copy(packet.begin() + 8, packet.begin() + 24, srcIPv6.bytes.begin());
    std::optional<NdpPacket> p = parseNdp(icmp6.data(), icmp6.size());
    if (!p) return;
    if (p->type == 135) {
        if (std::find(ctx.ipv6.begin(), ctx.ipv6.end(), p->target) == ctx.ipv6.end()) return;
        // DAD 探测（NS 源为未指定地址 ::）：请求方在自查该地址是否已被占用，按
        // RFC 4861 §7.2.4 回全节点组播 NA——目的 ff02::1、Solicited 清零仅 Override
        //（0x20），DAD 方收到「已被持有」的宣告即放弃自配。普通 NS 维持单播
        // Solicited+Override（0x60）。两种形态 NA 源地址均 = 被解析的本机地址，
        // 校验和伪头用真实 src/dst，恒 0 会被真实节点内核丢弃
        const bool dad = std::all_of(srcIPv6.bytes.begin(), srcIPv6.bytes.end(),
                                     [](uint8_t b) { return b == 0; });
        std::vector<uint8_t> na =
            neighborAdvertisement(p->target, ctx.mac, dad ? 0x20 : 0x60); // solicited = !dad
        const Ipv6Address dst = dad ? allNodesMulticast() : srcIPv6;
        const uint16_t ck = icmpv6Checksum(p->target, dst, na.data(), na.size());
        na[2] = static_cast<uint8_t>(ck >> 8); // 纯函数返回值回写校验和字段（见头注释②）
        na[3] = static_cast<uint8_t>(ck & 0xffu);
        std::vector<uint8_t> ipPkt = ipv6Packet(na, p->target, dst);
        const uint64_t dstMac = dad ? multicastMAC(dst) : senderMac;
        sendCore(m_coreSend, ctx.nwid, ctx.mac, dstMac, ETH_TYPE_IPV6, ipPkt);
        return;
    }
    if (p->type == 136) {
        if (!p->senderMac) return;
        const uint64_t mac = *p->senderMac;
        ctx.ndp.update(p->target, mac);
        auto wait = ctx.pendingV6->v6.find(p->target);
        if (wait == ctx.pendingV6->v6.end()) return;
        std::vector<std::vector<uint8_t>> waiting = std::move(wait->second);
        ctx.pendingV6->v6.erase(wait);
        for (const std::vector<uint8_t>& pkt : waiting)
            sendCore(m_coreSend, ctx.nwid, ctx.mac, mac, ETH_TYPE_IPV6, pkt);
    }
}

/** 闲置保活：每活跃网络广播一个 ARP 探测帧（防 peer 路径/NAT 冷却死亡） */
void FrameConverter::sendKeepalive() {
    std::lock_guard<std::mutex> lk(m_lock);
    for (NetworkContext* ctx : orderedContextsLocked()) {
        if (ctx->mac == 0) continue;
        if (ctx->ipv4.empty()) continue;
        const uint32_t probeIp = ctx->ipv4.front();
        ++ctx->statKeepalive;
        sendARPRequestLocked(*ctx, probeIp);
    }
}

// ---- 控制帧 ----

void FrameConverter::sendARPRequestLocked(NetworkContext& ctx, uint32_t target) {
    const uint32_t senderIp = ctx.ipv4.empty() ? 0u : ctx.ipv4.front();
    std::vector<uint8_t> req = arpRequest(senderIp, ctx.mac, target);
    sendCore(m_coreSend, ctx.nwid, ctx.mac, BROADCAST_MAC, ETH_TYPE_ARP, req);
}

void FrameConverter::sendNeighborSolicitationLocked(NetworkContext& ctx, const Ipv6Address& target) {
    if (ctx.ipv6.empty()) return;
    const Ipv6Address src = ctx.ipv6.front();
    std::vector<uint8_t> ns = neighborSolicitation(target, ctx.mac);
    // RFC 4861：NS 的 L3 目的 = 请求节点组播地址（此前误用 target 单播，组播只在
    // L2），源 = 本机接口地址（:: 仅 DAD 合法）
    const Ipv6Address dst = solicitedNodeMulticast(target);
    const uint16_t ck = icmpv6Checksum(src, dst, ns.data(), ns.size());
    ns[2] = static_cast<uint8_t>(ck >> 8);
    ns[3] = static_cast<uint8_t>(ck & 0xffu);
    std::vector<uint8_t> pkt = ipv6Packet(ns, src, dst);
    sendCore(m_coreSend, ctx.nwid, ctx.mac, multicastMAC(dst), ETH_TYPE_IPV6, pkt);
}

/** ICMPv6 载荷包成最小 IPv6 包（next header 58，hop limit 255） */
std::vector<uint8_t> FrameConverter::ipv6Packet(const std::vector<uint8_t>& payload,
                                                const Ipv6Address& src, const Ipv6Address& dst) {
    std::vector<uint8_t> p(40 + payload.size(), 0);
    p[0] = 0x60;
    p[4] = static_cast<uint8_t>((payload.size() >> 8) & 0xffu);
    p[5] = static_cast<uint8_t>(payload.size() & 0xffu);
    p[6] = 58;
    p[7] = 255;
    std::copy(src.bytes.begin(), src.bytes.end(), p.begin() + 8);
    std::copy(dst.bytes.begin(), dst.bytes.end(), p.begin() + 24);
    std::copy(payload.begin(), payload.end(), p.begin() + 40);
    return p;
}

// ---- 地址工具 ----

uint32_t FrameConverter::bigEndianIP32(const std::vector<uint8_t>& pkt, size_t offset) {
    return (uint32_t(pkt[offset]) << 24) | (uint32_t(pkt[offset + 1]) << 16) |
           (uint32_t(pkt[offset + 2]) << 8) | uint32_t(pkt[offset + 3]);
}

bool FrameConverter::isIPv4Multicast(uint32_t ip) {
    return (ip >> 28) == 0xEu;
}

/** 地址是否为本机任一网络持有（NAT44：出站源是另一网络地址才改写） */
bool FrameConverter::isLocalIPv4Locked(uint32_t ip) const {
    for (const auto& kv : m_contexts)
        if (std::find(kv.second->ipv4.begin(), kv.second->ipv4.end(), ip) != kv.second->ipv4.end())
            return true;
    return false;
}

bool FrameConverter::isIPv6Multicast(const Ipv6Address& a) {
    return a.bytes[0] == 0xff;
}

/** IPv4 组播 → 01:00:5e:0f:ff:ff 系组播 MAC（低 23 位，最高位清零） */
uint64_t FrameConverter::ipv4MulticastMAC(uint32_t ip) {
    return 0x01005e000000ULL | static_cast<uint64_t>(ip & 0x7fffffu);
}

} // namespace pp
