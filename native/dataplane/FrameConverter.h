// FrameConverter.h — IP 包 ↔ 虚拟网帧转换层（A2 计划 Task 7）
//
// 直译源：tunnel/FrameConverter.kt（361 行，tunnel/ 最大件）。
// - 下行（tun→核心）：L3 IP 包 → 聚合路由表最长前缀匹配选网络 → 查该网 ARP/NDP
//   → 经 CoreSend 注入核心（Kotlin NodeRuntime.processVirtualNetworkFrame 的
//   挂起回调在此退化为注入函数，CoreBridge::processVirtualNetworkFrame 直连）
// - 上行（核心→tun）：帧回调按 nwid 分流到对应 NetworkContext；返回应写 TUN 的
//   IP 包（调用方 = Dataplane 消费线程）
// 多网络隔离：MAC/地址/ARP/NDP/pending/路由全部按网络存放，互不串网。
// 全方法持单一锁（对齐 iOS NSLock 模型）；锁内调用 CoreSend（核心内部有锁，
// 不构成反向进入本类的路径）。
//
// 与 brief 接口稿的差异（见 task-7 报告）：
//   ① 补充 m_order（激活顺序）——buildAggregateV4/V6 的「同前缀先到者胜」与
//      debugSummary 的遍历序都依赖它，brief 稿未列出但 Kotlin 原文有（order 列表）。
//   ② 补充 m_nat 与可选 clock 构造参数——NAT44 实例为 FrameConverter 私有成员
//      （Kotlin 同）；Clock 缺省用 steady_clock 毫秒（对齐 SystemClock.elapsedRealtime），
//      注入口供测试固定时钟。
//   ③ 构造函数第二参带缺省值，brief 的单参形态照常可用。
#pragma once
#include "NAT44.h"
#include "NetworkContext.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace pp {

class FrameConverter {
public:
    /** core 帧上送注入（CoreBridge::processVirtualNetworkFrame 直连，tun→core 方向；vlanId 恒 0，
     *  对齐 Kotlin。注意 Hooks.onFrame 是 core→tun 反向回调，两者签名恰好相同不可混接——
     *  onFrame 须入队消费，直调 handleFrameFromCore 会形成 ABBA 死锁） */
    using CoreSend = std::function<void(uint64_t nwid, uint64_t srcMac, uint64_t dstMac,
                                        uint16_t etherType, uint16_t vlanId,
                                        const uint8_t* frame, size_t len)>;

    /** clock：NAT44 的毫秒时钟注入；缺省 steady_clock 毫秒（对齐 Kotlin elapsedRealtime） */
    explicit FrameConverter(CoreSend coreSend, NAT44::Clock clock = nullptr);

    // ---- 上下文管理（TunnelManager.applyConfig 调用序） ----

    // enabled=false 即视同移除（冲突网络不建上下文，对齐 Kotlin）
    void updateNetworkInfo(uint64_t nwid, bool enabled, uint64_t mac,
                           const std::vector<std::string>& ipv4,
                           const std::vector<std::string>& ipv6,
                           const std::vector<std::string>& routes);
    void removeNetwork(uint64_t nwid);
    // reconcile：仅保留给定网络集合，清理幽灵上下文（读文件与 leave 并发时防残留）
    void retainOnly(const std::vector<uint64_t>& nwids);

    // ---- 数据面 ----

    // tun → core（Dataplane 读线程调用）；<20B 跳过，按 IP 版本分流
    void handlePacketsFromTun(const std::vector<std::vector<uint8_t>>& packets);

    // core → tun；返回应写 TUN 的 IP 包（ARP/NDP 控制帧在锁内自答，返回空）
    std::vector<std::vector<uint8_t>> handleFrameFromCore(uint64_t nwid, uint64_t srcMac,
                                                          uint64_t dstMac, uint16_t etherType,
                                                          const uint8_t* frame, size_t len);

    // 闲置保活：每活跃网络广播一个 ARP 探测帧（防 peer 路径/NAT 冷却死亡）
    void sendKeepalive();

    // 诊断快照（验证页/排查用；格式对齐 FrameConverter/TunnelStateBus 跨端心智）
    std::string debugSummary();

    /** 每下一跳待决包上限（超出丢新包，防移动端内存失控）——MAX_PENDING_PER_TARGET */
    static constexpr size_t kMaxPendingPerTarget = 16;

private:
    // Kotlin 私有方法逐一对应（*Locked = 调用方已持 m_lock）
    void removeNetworkLocked(uint64_t nwid);
    void rebuildAggregatesLocked();
    std::vector<NetworkContext*> orderedContextsLocked();
    void handleV4Locked(const std::vector<uint8_t>& raw);
    void handleV6Locked(const std::vector<uint8_t>& pkt);
    void handleARPLocked(NetworkContext& ctx, const uint8_t* payload, size_t len,
                         uint64_t senderMac);
    void handleNDPLocked(NetworkContext& ctx, const std::vector<uint8_t>& packet,
                         uint64_t senderMac);
    void sendARPRequestLocked(NetworkContext& ctx, uint32_t target);
    void sendNeighborSolicitationLocked(NetworkContext& ctx, const Ipv6Address& target);
    static std::vector<uint8_t> ipv6Packet(const std::vector<uint8_t>& payload,
                                           const Ipv6Address& src, const Ipv6Address& dst);

    // ---- 地址工具（Kotlin 文件底部私有工具） ----
    static uint32_t bigEndianIP32(const std::vector<uint8_t>& pkt, size_t offset);
    static bool isIPv4Multicast(uint32_t ip);
    bool isLocalIPv4Locked(uint32_t ip) const;
    static bool isIPv6Multicast(const Ipv6Address& a);
    static uint64_t ipv4MulticastMAC(uint32_t ip);

    std::mutex m_lock; // 全方法持单一锁（对齐 iOS NSLock 语义）
    CoreSend m_coreSend;
    // 激活顺序（首次 upsert 追加；聚合表同前缀先到者胜的裁决依据 + 诊断遍历序）
    std::vector<uint64_t> m_order;
    std::map<uint64_t, std::unique_ptr<NetworkContext>> m_contexts;
    std::vector<AggregateV4Entry> m_aggV4; // updateNetworkInfo 后由 Math 重建
    std::vector<AggregateV6Entry> m_aggV6;
    NAT44 m_nat; // 多网络源地址 NAT（仅本类锁内使用，对齐 iOS FrameConverter）
    uint64_t m_statNoRoute = 0;
};

} // namespace pp
