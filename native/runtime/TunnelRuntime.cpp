// TunnelRuntime.cpp — 隧道编排状态机实现（A3 计划 Task 8）
//
// 直译对照（函数级）：
//   start/startInternal        ← ZeroTierVpnService.startTunnel + NodeRuntime.start
//   applyConfig(Diff)          ← TunnelManager.applyConfig（join/leave/orbit 增量 +
//                                appliedEntries 比对；deorbit 为 brief 授权的对称扩展）
//   applyAggregated            ← TunnelManager.applyAggregated（冲突检测 → 转换器上下文
//                                → 地址/路由/MTU 合并 → 幂等签名 → establish）
//   handleNetConf              ← TunnelManager.onNetworkConfig（UP/CONFIG_UPDATE 登记、
//                                无地址即剔除）
//   handleEvent                ← NodeRuntime.EventListenerImpl（ONLINE/OFFLINE/身份冲突）
//                                + 驱动失败上报（core_driver:rc）
//   swapFd                     ← applyAggregated 尾段 swap + Running 置位（幂等签名
//                                提交时机：swap 成功才记，对齐 Kotlin 注释）
//   stop/teardownPipeline      ← ZeroTierVpnService.stopTunnel（顺序：消费线程 join →
//                                dp.shutdown → udp.shutdown → runtime.shutdown）
//   restartCore                ← TunnelController.reconnectForNetworkChange 的进程内
//                                收敛（stop+start 保配置；awaitSettled 等待归壳层职责）
//   log                        ← TunnelStateBus.log（HH:mm:ss.SSS + takeLast(40)）
//   snapshotJson               ← TunnelStateBus 各 StateFlow → TunnelContract.ets 契约
//
// 与 Kotlin 的落地差异（行为等价申报，详见各函数注释与 task-8 报告）：
//   ① 300ms 去抖 → worker「连续事件排空后聚合一次」（每突发一次聚合，效果同合并）；
//   ② Builder.establish 同步返回 fd → 异步回调契约：onEstablish 发请求、swapFd 回应，
//      幂等签名在 swapFd 成功时提交（Kotlin 在 applyAggregated 内 swap 后立即记）；
//   ③ 45s 保活 + 5s Peer 轮询协程 → 单 timer 线程（双 deadline）；
//   ④ MTU 兜底：Kotlin 空声明值兜底 2800，本实现按 brief 起始 28000 取 min——两者
//      经壳层 clamp [576,1500] 后结果相同（1500 上界低于两个兜底值）；
//   ⑤ deorbit：Kotlin applyConfig 只 orbit 新增（月壳移除未实现），TunnelConfig 可
//      表达移除 → 按对称语义落地（brief/测试授权）；
//   ⑥ dns：TunnelConfig 未携带每网络 DnsMode/customDns（A3 store 直译边界），
//      EstablishRequest.dns 恒空——NAPI/壳层契约缺口，Task 9/10 扩展后补齐；
//   ⑦ udpBindFailed 终态：Kotlin Failed 后紧接 stopTunnel 会把终态覆盖成 Stopped，
//      本实现按 brief 锁定 Failed(udpBindFailed, recoverable=true) 为终态。
#include "runtime/TunnelRuntime.h"

#include <algorithm>
#include <cstdio>
#include <ctime>
#include <optional>
#include <set>
#include <tuple>

#include "dataplane/Net.h"
#include "dataplane/NdpTable.h"
#include "dataplane/NetworkContext.h"
#include "dataplane/RoutePlanner.h"

namespace pp {
namespace {

// ---- 文本/格式工具 ----

std::string hex16(uint64_t v)
{
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%016llx", static_cast<unsigned long long>(v));
    return buf;
}

std::string hex10(uint64_t v)
{
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%010llx", static_cast<unsigned long long>(v));
    return buf;
}

std::string joinStrings(const std::vector<std::string> &items, const std::string &sep)
{
    std::string out;
    for (size_t i = 0; i < items.size(); ++i) {
        if (i)
            out += sep;
        out += items[i];
    }
    return out;
}

// TunnelStateBus.log 的 SimpleDateFormat("HH:mm:ss.SSS") 直译（本地时区）
std::string nowHmsMs()
{
    const std::chrono::system_clock::time_point now = std::chrono::system_clock::now();
    const std::time_t t = std::chrono::system_clock::to_time_t(now);
    const long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                             now.time_since_epoch()).count() % 1000;
    std::tm tmv {};
    localtime_r(&t, &tmv);
    char buf[16];
    std::snprintf(buf, sizeof(buf), "%02d:%02d:%02d.%03d", tmv.tm_hour, tmv.tm_min, tmv.tm_sec,
                  static_cast<int>(ms));
    return buf;
}

// ---- JSON 序列化工具（手写 builder，键名即 TunnelContract.ets 契约） ----

void jsonStr(const std::string &s, std::string &out)
{
    out += '"';
    for (const unsigned char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += static_cast<char>(c); // UTF-8 原样透传
            }
        }
    }
    out += '"';
}

std::string jsonArr(const std::vector<std::string> &items)
{
    std::string out;
    for (size_t i = 0; i < items.size(); ++i) {
        if (i)
            out += ",";
        jsonStr(items[i], out);
    }
    return out;
}

// ---- RoutePlanner.kt 本文件本地 helper（networkCIDR4/6 未从 C++ RoutePlanner 导出， ----
// ---- 与 NetworkContext.cpp 的文件本地落地同源；掩网语义直译 Kotlin） ----

// "10.0.0.5/24" → "10.0.0.0/24"（解析失败原样返回，对齐 Kotlin networkCIDR4）
std::string networkCidr4(const std::string &cidr)
{
    const int prefix = std::min(RoutePlanner::prefixLen(cidr), 32);
    const std::optional<std::string> ipStr = RoutePlanner::ipOnly(cidr);
    if (!ipStr)
        return cidr;
    const std::optional<uint32_t> ip = parseIpv4(*ipStr);
    if (!ip)
        return cidr;
    const uint32_t mask = prefix <= 0 ? 0u
                                      : (prefix >= 32 ? 0xffffffffu
                                                      : uint32_t(0xffffffffu << (32 - prefix)));
    return dottedV4(*ip & mask) + "/" + std::to_string(prefix);
}

// "fdaa::5/64" → "fdaa::/64"
std::string networkCidr6(const std::string &cidr)
{
    const int prefix = std::min(RoutePlanner::prefixLen(cidr), 128);
    const std::optional<std::string> ipStr = RoutePlanner::ipOnly(cidr);
    if (!ipStr)
        return cidr;
    const std::optional<Ipv6Address> addr = parseIpv6(*ipStr);
    if (!addr)
        return cidr;
    Ipv6Address masked {};
    for (int i = 0; i < 16; ++i) {
        const int take = std::min(std::max(prefix - i * 8, 0), 8);
        masked.bytes[static_cast<size_t>(i)] =
            take == 8 ? addr->bytes[static_cast<size_t>(i)]
                      : static_cast<uint8_t>(addr->bytes[static_cast<size_t>(i)] &
                                             static_cast<uint8_t>(take > 0 ? (0xffu << (8 - take)) : 0u));
    }
    return formatV6(masked) + "/" + std::to_string(prefix);
}

// CIDR → IPPrefix（地址字节 + 前缀；physicalOnLinkPrefixes* 内部自掩网——
// excludingNetworksOf 按 ZT 分配地址所在网段跳过，入参无需预掩）
std::optional<IPPrefix> prefixFromCidr4(const std::string &cidr)
{
    const std::optional<std::string> ipStr = RoutePlanner::ipOnly(cidr);
    if (!ipStr)
        return std::nullopt;
    const std::optional<uint32_t> ip = parseIpv4(*ipStr);
    if (!ip)
        return std::nullopt;
    IPPrefix p;
    p.bytes = {static_cast<uint8_t>(*ip >> 24), static_cast<uint8_t>(*ip >> 16),
               static_cast<uint8_t>(*ip >> 8), static_cast<uint8_t>(*ip)};
    p.length = std::min(RoutePlanner::prefixLen(cidr), 32);
    return p;
}

std::optional<IPPrefix> prefixFromCidr6(const std::string &cidr)
{
    const std::optional<std::string> ipStr = RoutePlanner::ipOnly(cidr);
    if (!ipStr)
        return std::nullopt;
    const std::optional<Ipv6Address> addr = parseIpv6(*ipStr);
    if (!addr)
        return std::nullopt;
    IPPrefix p;
    p.bytes.assign(addr->bytes.begin(), addr->bytes.end());
    p.length = std::min(RoutePlanner::prefixLen(cidr), 128);
    return p;
}

// IPPrefix → RouteEntry.addr（Kotlin expandV4/V6 出参 RouteEntry(addr, length) 同构）
std::string ipPrefixAddr(const IPPrefix &p)
{
    if (p.bytes.size() == 4)
        return dottedV4((uint32_t(p.bytes[0]) << 24) | (uint32_t(p.bytes[1]) << 16) |
                        (uint32_t(p.bytes[2]) << 8) | uint32_t(p.bytes[3]));
    Ipv6Address a {};
    std::copy(p.bytes.begin(), p.bytes.begin() + std::min<size_t>(p.bytes.size(), 16), a.bytes.begin());
    return formatV6(a);
}

std::string routeKey(const RouteEntry &r)
{
    return r.addr + "/" + std::to_string(r.prefix);
}

} // namespace

// ---- 构造/析构 ----

TunnelRuntime::TunnelRuntime()
    : m_fc([this](uint64_t nwid, uint64_t srcMac, uint64_t dstMac, uint16_t etherType,
                  uint16_t vlanId, const uint8_t *frame, size_t len) {
          // FrameConverter CoreSend（tun→core）：Dataplane 读线程/worker/timer 调用；
          // m_core 在 teardown 时先于所有上游线程收口，判空为防御
          (void)vlanId;
          if (CoreBridge *core = m_core.get())
              core->processVirtualNetworkFrame(nwid, srcMac, dstMac, etherType, 0, frame, len);
      })
{
}

TunnelRuntime::~TunnelRuntime()
{
    stop(); // 兜底：先 join worker/timer 再收口 dp/udp/core（防 UAF）
}

// ---- 状态读取 ----

RuntimeState TunnelRuntime::state() const
{
    std::lock_guard<std::mutex> lk(m_lock);
    return m_state;
}

bool TunnelRuntime::isAliveKindLocked() const
{
    const std::string &k = m_state.kind; // running|starting|reconnecting（TunnelController.isRunning）
    return k == "running" || k == "starting" || k == "reconnecting";
}

bool TunnelRuntime::isAlive() const
{
    std::lock_guard<std::mutex> lk(m_lock);
    return isAliveKindLocked();
}

// ---- 事件队列（核心线程只入队，深拷贝值语义——回调红线：禁 static 缓冲复用） ----

void TunnelRuntime::pushEvt(Evt &&ev)
{
    {
        std::lock_guard<std::mutex> lk(m_qLock);
        if (m_qClosed)
            return; // 停机后迟到事件直接丢弃
        m_queue.push_back(std::move(ev));
    }
    m_qCv.notify_one();
}

void TunnelRuntime::pushApply()
{
    Evt ev;
    ev.kind = Evt::KApply;
    pushEvt(std::move(ev));
}

// ---- 装配（ZeroTierVpnService.startTunnel 顺序直译） ----

bool TunnelRuntime::start(const TunnelConfig &cfg)
{
    std::lock_guard<std::mutex> life(m_lifeLock);
    return startInternal(cfg);
}

bool TunnelRuntime::startInternal(const TunnelConfig &cfg)
{
    {
        std::lock_guard<std::mutex> lk(m_lock);
        if (isAliveKindLocked())
            return false; // 幂等：已启动
        m_cfg = cfg;
        m_state.kind = "starting";
        m_state.reason.clear();
        m_state.recoverable = false;
        m_state.online = false;
        m_state.applyTrace.clear();
        m_pathSatisfied = true; // NetWatch 复位（对齐 stopTunnel 的防跨会话残留语义）
    }
    // 重开事件队列（上一轮 teardown 已关闭）
    {
        std::lock_guard<std::mutex> lk(m_qLock);
        m_qClosed = false;
        m_queue.clear();
    }

    // ① CoreBridge 构造（身份 seed 由壳层在 start 前完成——ArkTS IdentityStore）→ hooks 装配
    auto core = std::make_unique<CoreBridge>(cfg.dataStoreRoot, cfg.planetDir, cfg.planetFile,
                                             cfg.identityPerPlanet);
    core->hooks.onFrame =
        [this](uint64_t nwid, uint64_t srcMac, uint64_t dstMac, uint16_t etherType,
               uint16_t vlanId, const uint8_t *frame, size_t len) {
            Evt ev;
            ev.kind = Evt::KFrame;
            ev.nwid = nwid;
            ev.srcMac = srcMac;
            ev.dstMac = dstMac;
            ev.etherType = etherType;
            ev.vlanId = vlanId;
            ev.frame.assign(frame, frame + len); // 深拷贝（同步投递语义，回调外继续持有）
            pushEvt(std::move(ev));
        };
    core->hooks.onNetConf = [this](uint64_t nwid, int op, const NetConf &conf) {
        Evt ev;
        ev.kind = Evt::KNetConf;
        ev.nwid = nwid;
        ev.op = op;
        ev.conf = conf;
        pushEvt(std::move(ev));
    };
    core->hooks.onEvent = [this](int event) {
        Evt ev;
        ev.kind = Evt::KEvent;
        ev.event = event;
        pushEvt(std::move(ev));
    };
    core->hooks.sendPacket = [this](const uint8_t *data, size_t len, const WireEndpoint &ep) -> int {
        // 缺省直连 UdpCom.send（Kotlin PacketSender = UdpCom 同构）；注入时以注入为准
        if (hooks.sendPacket)
            return hooks.sendPacket(data, len, ep);
        if (UdpCom *udp = m_udp.get())
            return udp->send(ep.ip, ep.port, data, len);
        return -1;
    };

    // ② core.start()（NodeRuntime.start：ZT_Node_new → 首次驱动 → 起驱动线程；
    //    身份生成/装载在此发生）
    if (!core->start()) {
        {
            std::lock_guard<std::mutex> lk(m_lock);
            m_state.kind = "failed";
            m_state.reason = "coreInit";
            m_state.recoverable = true;
            logLocked("core init 失败");
        }
        if (hooks.onStateChanged)
            hooks.onStateChanged();
        return false;
    }
    m_core = std::move(core);
    {
        std::lock_guard<std::mutex> lk(m_lock);
        const std::optional<uint64_t> addr = m_core->address();
        m_state.nodeId = addr ? hex10(*addr) : std::string();
        m_state.coreVersion = CoreBridge::version(); // 停机不清的缓存（TunnelStateBus 语义）
        logLocked("核心已启动 nodeId=" + m_state.nodeId + " version=" + m_state.coreVersion);
    }

    // ③ Dataplane 按次装配（闩锁不可逆，换代重建；旧实例已停机无线程，安全替换），
    //    建在读线程之前——TunPacket 回调即 m_fc.handlePacketsFromTun 直译。
    //    换代写入 m_lock 内进行（F1：与 swapFd 的持锁拷贝互斥——shared_ptr 并发
    //    一读一写是数据竞争）；被替换的旧实例已由 teardownPipeline shutdown（闩锁
    //    已置），在途 swapFd 持强引用继续访问只会被闩锁拒绝并关 fd，延迟析构安全
    std::shared_ptr<Dataplane> freshDp =
        std::make_shared<Dataplane>([this](const uint8_t *data, size_t len) {
            m_fc.handlePacketsFromTun({std::vector<uint8_t>(data, data + len)});
        });
    {
        std::lock_guard<std::mutex> lk(m_lock);
        m_dp = std::move(freshDp);
    }

    // ④ worker + timer 线程（帧/netconf 消费；45s 保活 + 5s Peer 轮询）
    m_worker = std::thread(&TunnelRuntime::workerLoop, this);
    startTimer();

    // ⑤ UdpCom.start（protect 注入；bind 失败 → Failed(udpBindFailed, recoverable)）
    uint16_t port = 9994; // 生产值；测试经 testUdpPort 注入空闲回环端口
#ifdef PP_TUNNELRUNTIME_TEST_HOOKS
    if (testUdpPort >= 0)
        port = static_cast<uint16_t>(testUdpPort);
#endif
    m_udpPort = port;
    m_udp = std::make_unique<UdpCom>(port);
    UdpCom::Protect protectFn =
        hooks.protect ? hooks.protect : UdpCom::Protect([](int) { return true; });
    const bool udpOk =
        m_udp->start(std::move(protectFn),
                     [this](const uint8_t *data, size_t len, const std::string &ip, uint16_t rport) {
                         if (CoreBridge *core2 = m_core.get())
                             core2->processWirePacket(data, len, WireEndpoint{ip, rport});
                     });
    if (!udpOk) {
        // 无物理收发不可继续；不崩进程（对齐 Kotlin catch SocketException → Failed）。
        // Kotlin 此处 Failed 后紧接 stopTunnel 会把终态覆盖成 Stopped；brief 锁定
        // Failed(udpBindFailed) 为终态——按 brief（差异申报⑦）
        log("udp bind 失败（端口 " + std::to_string(port) + " 被占）");
        teardownPipeline();
        {
            std::lock_guard<std::mutex> lk(m_lock);
            m_state.kind = "failed";
            m_state.reason = "udpBindFailed";
            m_state.recoverable = true;
        }
        if (hooks.onStateChanged)
            hooks.onStateChanged();
        return false;
    }

    // ⑥ 首启 join 已配置网络 + orbit moons（tm.applyConfig() 直译）→ Starting 期望首份 netconf
    {
        std::lock_guard<std::mutex> lk(m_lock);
        applyConfigDiffLocked(cfg);
    }
    pushApply();
    if (hooks.onStateChanged)
        hooks.onStateChanged();
    return true;
}

// ---- 停机（stopTunnel 直译：消费线程 join → dp → udp → core；幂等） ----

void TunnelRuntime::stop()
{
    {
        std::lock_guard<std::mutex> life(m_lifeLock);
        teardownPipeline();
        {
            std::lock_guard<std::mutex> lk(m_lock);
            m_state.kind = "stopped";
            m_state.reason.clear();
            m_state.recoverable = false;
            m_pathSatisfied = true; // NetWatch 路径态复位（防跨会话残留）
        }
    }
    if (hooks.onStateChanged)
        hooks.onStateChanged();
}

void TunnelRuntime::teardownPipeline()
{
    // 停 worker：关队列（迟到事件丢弃）+ 投递 Stop → join
    {
        std::lock_guard<std::mutex> lk(m_qLock);
        m_qClosed = true;
        Evt stop;
        stop.kind = Evt::KStop;
        m_queue.push_back(std::move(stop));
    }
    m_qCv.notify_all();
    if (m_worker.joinable())
        m_worker.join();
    stopTimer();
    // 数据面收口顺序对齐 stopTunnel：dp.shutdown（读线程退出）→ udp.shutdown（收包
    // 线程退出，先 join 再关 Node 防 native UAF）→ core.shutdown
    if (m_dp)
        m_dp->shutdown(); // 闩锁置位（实例保留——迟到 swapFd 经闩锁拒绝并关 fd；fresh 未装配时为空）
    if (UdpCom *udp = m_udp.get()) {
        udp->shutdown();
        m_udp.reset();
    }
    if (CoreBridge *core = m_core.get()) {
        core->shutdown();
        m_core.reset();
    }
    {
        std::lock_guard<std::mutex> lk(m_lock);
        m_joined.clear();
        m_orbited.clear();
        m_applied.clear();
        m_snapshots.clear();
        syncNetworkConfigsLocked(); // TunnelManager.stop：clearNetworkConfigs
        m_state.networkConflicts.clear(); // clearNetworkConflicts
        m_state.networkStatuses.clear();  // stopTunnel：clearNetworkStatuses
        m_state.peers.clear();            // clearPeers
        m_state.online = false;
        m_state.nodeId.clear(); // setNodeStatus(null)：coreVersion 留存供 UI 展示
        m_appliedSignature.clear();
        m_pendingSignature.clear();
        m_fc.retainOnly({});
    }
}

// ---- 进程内换代（D3/D9：stop+start 保配置） ----

void TunnelRuntime::restartCore()
{
    bool alive = false;
    TunnelConfig cfg;
    {
        std::lock_guard<std::mutex> lk(m_lock);
        alive = isAliveKindLocked();
        cfg = m_cfg;
        if (alive) {
            m_state.kind = "reconnecting";
            m_state.reason = "network_change";
            logLocked("网络切换，重启核心");
        }
    }
    if (!alive)
        return; // 未跑 no-op（Kotlin !isRunning）
    if (hooks.onStateChanged)
        hooks.onStateChanged();
    {
        std::lock_guard<std::mutex> life(m_lifeLock);
        teardownPipeline();
        {
            // 复位为非存活态：startInternal 的幂等闸门（running/starting/reconnecting
            // 拒绝）会挡住换代重装配——kind 此刻仍停留在 reconnecting
            std::lock_guard<std::mutex> lk(m_lock);
            m_state.kind = "idle";
            m_state.reason.clear();
        }
        startInternal(cfg); // 失败即 Failed 终态（与 start 失败路径同构）
    }
    if (hooks.onStateChanged)
        hooks.onStateChanged();
}

// ---- establish 回应（applyAggregated 尾段 swap + Running 直译） ----

bool TunnelRuntime::swapFd(int fd)
{
    if (fd < 0)
        return false; // 非法 fd：保持当前态（Starting 等下次 netconf——不 Failed）
    std::shared_ptr<Dataplane> dp;
    {
        std::lock_guard<std::mutex> lk(m_lock);
        // fresh（从未装配，m_dp 未建）：不接管也不关 fd（调用方持有，自行关闭）；
        // 曾装配但已停机（m_dp 保留在停机闩锁态）：放行给闩锁——拒绝并关 fd 防泄漏。
        // 持锁拷贝强引用（F1）：锁外经强引用调用 swap——startInternal/restartCore
        // 在 m_lifeLock 下换代重建 m_dp 时，本调用仍持旧实例（旧实例 shutdown 已
        // 先行，闩锁拒绝 + 延迟析构安全），锁外裸解引用 unique_ptr 即 use-after-free
        dp = m_dp;
    }
    if (!dp)
        return false;
    const bool swapped = dp->swap(fd);
    {
        std::lock_guard<std::mutex> lk(m_lock);
        if (!swapped) {
            // swap 被拒（Dataplane 已停机的迟到 establish）：TUN 实际不存在，fd 已由
            // Dataplane 关闭（A2 语义，本类不重复 close）；签名不记——否则幂等闸门会
            // 把「无 TUN」误认为已应用
            logLocked("swap 被拒（Dataplane 已停机），本次应用作废");
            return false;
        }
        // swap 成功才记签名——先记后 swap 一旦失败，签名已更新而 fd 未接线，后续
        // apply 全部被闸门跳过（TUN 永不重建）
        m_appliedSignature = m_pendingSignature;
        // 仅存活态翻转 kind（F2）：identityCollision/core_driver 失败后（Failed 存活
        // 态，pipeline 未拆）迟到的 pending establish swap 状态盲成功，但不得把 Failed
        // 翻成 running 掩盖失败；签名照常提交（对齐 Kotlin 的状态盲 swap）
        if (isAliveKindLocked()) {
            m_state.kind = "running";
            m_state.reason.clear();
        }
        logLocked("establish 成功");
    }
    if (hooks.onStateChanged)
        hooks.onStateChanged();
    return true;
}

// ---- 热重配（TunnelManager.applyConfig 直译：level-triggered 全量差分） ----

void TunnelRuntime::applyConfig(const TunnelConfig &cfg)
{
    {
        std::lock_guard<std::mutex> lk(m_lock);
        if (!m_core)
            return; // 未启动 no-op（仅隧道存活期被调用）
        m_cfg = cfg;
        applyConfigDiffLocked(cfg);
    }
    pushApply(); // 重聚合（幂等签名闸门兜底；对齐 Kotlin scheduleApplyLocked）
}

void TunnelRuntime::applyConfigDiffLocked(const TunnelConfig &cfg)
{
    if (!m_core)
        return;
    // join 新增（激活序）
    std::vector<uint64_t> wanted;
    wanted.reserve(cfg.networks.size());
    for (const TunnelConfig::Net &net : cfg.networks) {
        wanted.push_back(net.nwid);
        if (std::find(m_joined.begin(), m_joined.end(), net.nwid) == m_joined.end()) {
            m_core->join(net.nwid);
            m_joined.push_back(net.nwid);
#ifdef PP_TUNNELRUNTIME_TEST_HOOKS
            if (testOnCoreAction)
                testOnCoreAction("join", net.nwid, 0);
#endif
            logLocked("join " + hex16(net.nwid));
        }
    }
    // leave 移除：数据面上下文 + 快照一并清（幽灵路由防线）
    for (auto it = m_joined.begin(); it != m_joined.end();) {
        const uint64_t nwid = *it;
        if (std::find(wanted.begin(), wanted.end(), nwid) == wanted.end()) {
            m_core->leave(nwid);
            m_fc.removeNetwork(nwid);
            m_snapshots.erase(nwid);
            syncNetworkConfigsLocked();
#ifdef PP_TUNNELRUNTIME_TEST_HOOKS
            if (testOnCoreAction)
                testOnCoreAction("leave", nwid, 0);
#endif
            logLocked("leave " + hex16(nwid));
            it = m_joined.erase(it);
        } else {
            ++it;
        }
    }
    // orbit 新增 / deorbit 移除（Kotlin 仅 orbit 新增；deorbit 为 brief 授权的对称扩展）
    std::vector<uint64_t> wantedMoons;
    wantedMoons.reserve(cfg.moons.size());
    for (const TunnelConfig::Moon &moon : cfg.moons) {
        wantedMoons.push_back(moon.worldId);
        if (std::find(m_orbited.begin(), m_orbited.end(), moon.worldId) == m_orbited.end()) {
            m_core->orbit(moon.worldId, moon.seed);
            m_orbited.push_back(moon.worldId);
#ifdef PP_TUNNELRUNTIME_TEST_HOOKS
            if (testOnCoreAction)
                testOnCoreAction("orbit", moon.worldId, moon.seed);
#endif
            logLocked("orbit " + hex16(moon.worldId));
        }
    }
    for (auto it = m_orbited.begin(); it != m_orbited.end();) {
        const uint64_t worldId = *it;
        if (std::find(wantedMoons.begin(), wantedMoons.end(), worldId) == wantedMoons.end()) {
            m_core->deorbit(worldId);
#ifdef PP_TUNNELRUNTIME_TEST_HOOKS
            if (testOnCoreAction)
                testOnCoreAction("deorbit", worldId, 0);
#endif
            logLocked("deorbit " + hex16(worldId));
            it = m_orbited.erase(it);
        } else {
            ++it;
        }
    }
    // 用户侧配置（routeVia/全局 disableIpv6）变更 → 用核心当前配置热重套
    //（appliedEntries 直译；A3 比较键无每网络 DNS 模式——TunnelConfig 契约缺口）
    for (const TunnelConfig::Net &net : cfg.networks) {
        if (std::find(m_joined.begin(), m_joined.end(), net.nwid) == m_joined.end())
            continue;
        const AppliedKey key{net.routeViaZeroTier, cfg.disableIpv6};
        const auto it = m_applied.find(net.nwid);
        if (it == m_applied.end() || !(it->second == key)) {
            m_applied[net.nwid] = key;
            if (const std::optional<NetConf> conf = m_core->networkConf(net.nwid))
                upsertSnapshotLocked(net.nwid, *conf);
        }
    }
}

void TunnelRuntime::upsertSnapshotLocked(uint64_t nwid, const NetConf &conf)
{
    m_state.networkStatuses[nwid] = conf.status;
    if (conf.assignedAddrs.empty())
        return; // 无地址 = 被控制器剔除；首启 REQUESTING 中间态删不到快照，no-op 无害
    m_snapshots[nwid] = conf;
    syncNetworkConfigsLocked();
}

void TunnelRuntime::syncNetworkConfigsLocked()
{
    m_state.networkConfigs = m_snapshots; // TunnelStateBus.setNetworkConfigs 镜像
}

// ---- worker（Kotlin 帧消费/配置消费协程 + 去抖的收敛） ----

void TunnelRuntime::workerLoop()
{
    for (;;) {
        Evt ev;
        {
            std::unique_lock<std::mutex> lk(m_qLock);
            m_qCv.wait(lk, [&] { return !m_queue.empty() || m_qClosed; });
            if (m_queue.empty()) {
                break; // 队列已关且排空（Stop 已在 teardownPipeline 投递）
            }
            ev = std::move(m_queue.front());
            m_queue.pop_front();
        }
        if (ev.kind == Evt::KStop)
            break;
        if (ev.kind == Evt::KFrame) {
            handleFrame(ev);
            continue;
        }
        if (ev.kind == Evt::KEvent) {
            handleEvent(ev.event);
            continue;
        }
        // NetConf / Apply：排空连续突发后聚合一次（Kotlin 300ms 去抖的等义实现——
        // 连续配置回调合并为一次应用，效果同 debounce）
        if (ev.kind == Evt::KNetConf)
            handleNetConf(ev.nwid, ev.op, ev.conf);
        for (;;) {
            std::optional<Evt> more;
            {
                std::lock_guard<std::mutex> lk(m_qLock);
                if (!m_queue.empty() &&
                    (m_queue.front().kind == Evt::KNetConf || m_queue.front().kind == Evt::KApply)) {
                    more = std::move(m_queue.front());
                    m_queue.pop_front();
                }
            }
            if (!more)
                break;
            if (more->kind == Evt::KNetConf)
                handleNetConf(more->nwid, more->op, more->conf);
        }
        applyAggregated();
    }
}

// 核心帧 → 转换器（ARP/NDP 锁内自答）→ 应写 TUN 的 IP 包（帧消费协程直译）
void TunnelRuntime::handleFrame(const Evt &ev)
{
    if (ev.frame.empty())
        return;
    const std::vector<std::vector<uint8_t>> packets =
        m_fc.handleFrameFromCore(ev.nwid, ev.srcMac, ev.dstMac, ev.etherType, ev.frame.data(),
                                 ev.frame.size());
    if (!packets.empty())
        m_dp->writePackets(packets);
}

// netconf 回调消费（TunnelManager.onNetworkConfig 直译）
void TunnelRuntime::handleNetConf(uint64_t nwid, int op, const NetConf &conf)
{
    std::lock_guard<std::mutex> lk(m_lock);
    // 状态所有回调都上报；快照只在 UP(1)/CONFIG_UPDATE(2) 且带地址时登记
    //（首份完整 netconf 以 UP 回调，仅认 CONFIG_UPDATE 会漏首网络——CoreBridge 同语义）
    m_state.networkStatuses[nwid] = conf.status;
    logLocked("cfg " + hex16(nwid) + " op=" + std::to_string(op) +
              " status=" + std::to_string(conf.status) +
              " addrs=" + std::to_string(conf.assignedAddrs.size()));
    if (op != 1 && op != 2) // VIRTUAL_NETWORK_CONFIG_OPERATION_{UP,CONFIG_UPDATE}
        return;
    if (conf.assignedAddrs.empty()) {
        // 无地址的完整配置 = 被控制器剔除（吊销授权/移出网络）：清快照让聚合自然剔除，
        // 否则旧快照保留会路由滞留 TUN 黑洞。首启 REQUESTING 中间态删不到快照，无害
        if (m_snapshots.erase(nwid) != 0)
            syncNetworkConfigsLocked();
        return;
    }
    m_snapshots[nwid] = conf;
    syncNetworkConfigsLocked();
    // 聚合由 worker 突发尾统一触发（scheduleApplyLocked 的等义）
}

// 事件消费（NodeRuntime.EventListenerImpl + 驱动失败上报直译）
void TunnelRuntime::handleEvent(int event)
{
    if (event == 2 || event == 1) { // ZT_EVENT_ONLINE / ZT_EVENT_OFFLINE
        const bool online = event == 2;
        {
            std::lock_guard<std::mutex> lk(m_lock);
            m_state.online = online;
            logLocked(online ? "ONLINE" : "OFFLINE");
        }
        if (hooks.onStateChanged)
            hooks.onStateChanged();
        return;
    }
    if (event == 4) { // ZT_EVENT_FATAL_ERROR_IDENTITY_COLLISION：不可恢复
        {
            std::lock_guard<std::mutex> lk(m_lock);
            m_state.kind = "failed";
            m_state.reason = "identityCollision"; // 原因码，文案 UI 层生成
            m_state.recoverable = false;
            logLocked("FATAL_ERROR_IDENTITY_COLLISION");
        }
        if (hooks.onStateChanged)
            hooks.onStateChanged();
        return;
    }
    if (event <= -100) { // 驱动循环异常退出 -(ZT_ResultCode)：静默退出会假在线
        {
            std::lock_guard<std::mutex> lk(m_lock);
            m_state.kind = "failed";
            m_state.reason = "core_driver:" + std::to_string(-event); // 技术串，UI 映射通用文案
            m_state.recoverable = true;
            logLocked("processBackgroundTasks rc=" + std::to_string(-event) + "，停止驱动");
        }
        if (hooks.onStateChanged)
            hooks.onStateChanged();
        return;
    }
    // 其余（含 CoreBridge 经 onEvent 上报的网络 -3/-4 与 ZT_TRACE 等）不在编排面
}

// ---- 聚合应用（TunnelManager.applyAggregated 直译） ----

void TunnelRuntime::applyAggregated()
{
    bool teardown = false;
    bool needEstablish = false;
    EstablishRequest req;
    {
        std::lock_guard<std::mutex> lk(m_lock);
        if (!m_core)
            return;

        struct Item {
            uint64_t nwid = 0;
            bool routeViaNet = false;
            const NetConf *conf = nullptr;
            std::vector<std::string> v4;
            std::vector<std::string> v6;
        };
        // 没有可用地址的配置不进数据面（残缺设置同样会黑洞物理路由）
        std::vector<Item> items;
        for (const TunnelConfig::Net &net : m_cfg.networks) {
            const auto sit = m_snapshots.find(net.nwid);
            if (sit == m_snapshots.end())
                continue;
            Item it;
            it.nwid = net.nwid;
            it.routeViaNet = net.routeViaZeroTier;
            it.conf = &sit->second;
            for (const std::string &a : sit->second.assignedAddrs) {
                if (a.find('.') != std::string::npos)
                    it.v4.push_back(a);
            }
            if (!m_cfg.disableIpv6) {
                for (const std::string &a : sit->second.assignedAddrs) {
                    if (a.find(':') != std::string::npos)
                        it.v6.push_back(a);
                }
            }
            if (it.v4.empty() && it.v6.empty())
                continue;
            items.push_back(std::move(it));
        }

        // 冲突检测（后进入者让路）→ 冲突透出（原始码，文案 UI 层生成）→ 转换器上下文
        //（冲突网络不建，保留 join 仅展示状态）
        std::vector<std::tuple<uint64_t, const std::vector<std::string> *,
                               const std::vector<std::string> *>>
            ordered;
        ordered.reserve(items.size());
        for (const Item &it : items)
            ordered.emplace_back(it.nwid, &it.v4, &it.v6);
        const std::map<uint64_t, std::string> conflicts = NetworkContextMath::detectConflicts(ordered);
        m_state.networkConflicts = conflicts; // 全量替换：冲突解除的网络自然出表
        for (const Item &it : items) {
            m_fc.updateNetworkInfo(it.nwid, conflicts.find(it.nwid) == conflicts.end(),
                                   it.conf->mac, it.v4, it.v6, it.conf->routes);
        }
        {
            // 收敛：清理本次快照之外的网络上下文（读文件与 leave 并发时的幽灵路由）
            std::vector<uint64_t> nwids;
            nwids.reserve(items.size());
            for (const Item &it : items)
                nwids.push_back(it.nwid);
            m_fc.retainOnly(nwids);
        }
        std::vector<const Item *> valid;
        for (const Item &it : items)
            if (conflicts.find(it.nwid) == conflicts.end())
                valid.push_back(&it);

        std::string trace = "items=" + std::to_string(items.size()) +
                            " valid=" + std::to_string(valid.size()) + "\n";
        for (const Item &it : items) {
            const auto cit = conflicts.find(it.nwid);
            trace += "item " + hex16(it.nwid) + " v4=[" + joinStrings(it.v4, ",") +
                     "] v6=[" + joinStrings(it.v6, ",") + "] conflict=" +
                     (cit == conflicts.end() ? "-" : cit->second) + "\n";
        }

        if (valid.empty()) {
            // 全部网络失效（被踢/无地址）：拆 TUN——fd 关闭即接口消失、系统路由自动撤销。
            // 宏观状态不动（服务仍活，仅数据面暂无网络——Running + 无网络标注语义）；
            // 签名必须同置空：同配置网络恢复时若签名命中会被幂等闸门挡住不重建。
            // onTeardown 仅在曾建立过 TUN 时触发（Kotlin 此路径 teardownTun 对无 TUN 是
            // 无害 no-op 且无回调）——启动期空聚合（netconf 未到先跑 apply）静音，不误
            // 唤壳层 destroy VPN
            const bool hadTun = !m_appliedSignature.empty();
            m_dp->teardownTun();
            m_appliedSignature.clear();
            m_pendingSignature.clear();
            trace += "（无可用网络，已拆 TUN）\n" + m_fc.debugSummary();
            m_state.applyTrace = trace;
            logLocked("apply items=" + std::to_string(items.size()) +
                      " valid=0（无可用网络，已拆 TUN）");
            teardown = hadTun;
        } else {
            // 多网络下默认路由一律不生效；单网络按用户选择（routeVia）
            const bool routeVia = valid.size() == 1 && valid.front()->routeViaNet;
            std::vector<std::string> allV4;
            std::vector<std::string> allV6;
            for (const Item *it : valid) {
                allV4.insert(allV4.end(), it->v4.begin(), it->v4.end());
                allV6.insert(allV6.end(), it->v6.begin(), it->v6.end());
            }
            // 物理 on-link 子网挖除：ZT managed routes 会覆盖本机物理局域网
            std::vector<IPPrefix> v4Holes;
            std::vector<IPPrefix> v6Holes;
            {
                std::vector<IPPrefix> assigned4;
                assigned4.reserve(allV4.size());
                for (const std::string &a : allV4) {
                    if (const std::optional<IPPrefix> p = prefixFromCidr4(a))
                        assigned4.push_back(*p);
                }
                v4Holes = RoutePlanner::physicalOnLinkPrefixes4(assigned4);
                std::vector<IPPrefix> assigned6;
                assigned6.reserve(allV6.size());
                for (const std::string &a : allV6) {
                    if (const std::optional<IPPrefix> p = prefixFromCidr6(a))
                        assigned6.push_back(*p);
                }
                v6Holes = RoutePlanner::physicalOnLinkPrefixes6(assigned6);
            }

            std::vector<RouteEntry> v4Routes;
            std::vector<RouteEntry> v6Routes;
            std::set<std::string> seenV4;
            std::set<std::string> seenV6;
            const auto appendV4 = [&](const std::vector<IPPrefix> &expanded) {
                for (const IPPrefix &p : expanded) {
                    const RouteEntry r{ipPrefixAddr(p), p.length};
                    if (seenV4.insert(routeKey(r)).second)
                        v4Routes.push_back(r);
                }
            };
            const auto appendV6 = [&](const std::vector<IPPrefix> &expanded) {
                for (const IPPrefix &p : expanded) {
                    const RouteEntry r{ipPrefixAddr(p), p.length};
                    if (seenV6.insert(routeKey(r)).second)
                        v6Routes.push_back(r);
                }
            };
            if (routeVia) {
                appendV4(RoutePlanner::expandV4(RouteEntry{"0.0.0.0/0", 0}, v4Holes));
                appendV6(RoutePlanner::expandV6(RouteEntry{"::/0", 0}, v6Holes));
            }
            for (const Item *it : valid) {
                // 分配地址的直连网段（分配地址本身不会自动保证其网段进 TUN；不挖洞直译）
                for (const std::string &a : it->v4) {
                    const std::string cidr = networkCidr4(a);
                    const RouteEntry r{RoutePlanner::ipOnly(cidr).value_or(cidr),
                                       RoutePlanner::prefixLen(cidr)};
                    if (seenV4.insert(routeKey(r)).second)
                        v4Routes.push_back(r);
                }
                for (const std::string &a : it->v6) {
                    const std::string cidr = networkCidr6(a);
                    const RouteEntry r{RoutePlanner::ipOnly(cidr).value_or(cidr),
                                       RoutePlanner::prefixLen(cidr)};
                    if (seenV6.insert(routeKey(r)).second)
                        v6Routes.push_back(r);
                }
                // managed 路由：默认路由仅在 routeVia 时纳入（非 routeVia 不抢物理默认路由）
                for (const std::string &raw : it->conf->routes) {
                    const RouteEntry re{raw, RoutePlanner::prefixLen(raw)};
                    const bool v4ish = raw.find('.') != std::string::npos;
                    const bool v6ish = raw.find(':') != std::string::npos;
                    if (v4ish && (routeVia || !RoutePlanner::isDefaultRoute(re)))
                        appendV4(RoutePlanner::expandV4(re, v4Holes));
                    if (v6ish && (routeVia || !RoutePlanner::isDefaultRoute(re)))
                        appendV6(RoutePlanner::expandV6(re, v6Holes));
                }
            }

            // MTU：min(28000, 各网络声明值)（壳层 clamp [576,1500]——VpnConfig 硬性范围）
            int mtu = 28000;
            for (const Item *it : valid) {
                if (it->conf->mtu > 0)
                    mtu = std::min(mtu, it->conf->mtu);
            }

            // 组播订阅（ARP broadcast + 各 v6 地址的请求节点组播，地址解析可达性的关键）。
            // 每次都发：core 侧按组去重幂等无代价；leave 会连带丢弃订阅记录，rejoin 后须重订
            for (const Item *it : valid) {
                if (!it->v4.empty()) {
                    if (const std::optional<std::string> ipStr = RoutePlanner::ipOnly(it->v4.front())) {
                        if (const std::optional<uint32_t> ip = parseIpv4(*ipStr))
                            m_core->multicastSubscribe(it->nwid, BROADCAST_MAC,
                                                       static_cast<uint64_t>(*ip));
                    }
                }
                for (const std::string &cidr : it->v6) {
                    const std::optional<std::string> ipStr = RoutePlanner::ipOnly(cidr);
                    if (!ipStr)
                        continue;
                    const std::optional<Ipv6Address> addr = parseIpv6(*ipStr);
                    if (!addr)
                        continue;
                    m_core->multicastSubscribe(it->nwid,
                                               multicastMAC(solicitedNodeMulticast(*addr)), 0);
                }
            }

            std::vector<std::string> v4Keys;
            v4Keys.reserve(v4Routes.size());
            for (const RouteEntry &r : v4Routes)
                v4Keys.push_back(routeKey(r));
            std::vector<std::string> v6Keys;
            v6Keys.reserve(v6Routes.size());
            for (const RouteEntry &r : v6Routes)
                v6Keys.push_back(routeKey(r));
            trace += "includedV4=" + joinStrings(v4Keys, ",") + "\n";
            trace += "includedV6=" + joinStrings(v6Keys, ",") + "\n";

            // 核心侧 peer 可达性摘要（A2 PeerInfo 无物理路径表 → 恒 relay，A6 挂账）
            {
                const std::vector<PeerInfo> peers = m_core->peersNow();
                size_t leafs = 0, moons = 0, planets = 0;
                std::string leafLine;
                for (const PeerInfo &p : peers) {
                    if (p.role == "LEAF") {
                        ++leafs;
                        if (leafs <= 10)
                            leafLine += (leafLine.empty() ? "" : " ") + hex10(p.address) +
                                        "(" + std::to_string(p.latency) + "ms,relay)";
                    } else if (p.role == "MOON") {
                        ++moons;
                    } else if (p.role == "PLANET") {
                        ++planets;
                    }
                }
                trace += "peers leaf=" + std::to_string(leafs) + " moon=" + std::to_string(moons) +
                         " planet=" + std::to_string(planets) + " [" + leafLine + "]\n";
            }
            trace += m_fc.debugSummary();

            // 幂等闸门：与当前 TUN 生效配置完全一致则跳过重建（CONFIG_UPDATE 60s 重推）
            const std::string signature = "[" + joinStrings(allV4, ",") + "]|[" +
                                          joinStrings(allV6, ",") + "]|" +
                                          joinStrings(v4Keys, ",") + "|" +
                                          joinStrings(v6Keys, ",") + "|mtu=" +
                                          std::to_string(mtu) + "|dns=[]";
            m_state.applyTrace = trace;
            if (signature == m_appliedSignature) {
                logLocked("apply 幂等跳过（配置无变化）");
                needEstablish = false;
            } else {
                // Builder 组装移交壳层（onEstablish）：签名在 swapFd 成功时提交
                m_pendingSignature = signature;
                req.v4Addrs = allV4;
                req.v6Addrs = allV6;
                req.routes4 = v4Keys;
                req.routes6 = v6Keys;
                req.dns.clear(); // A3 契约缺口（TunnelConfig 未携带每网络 DNS 模式）
                req.mtu = mtu;
                logLocked("apply 建立请求已发出（mtu=" + std::to_string(mtu) + "）");
                needEstablish = true;
            }
        }
    }
    // Hooks 一律在 m_lock 外触发（回调内可安全回入 swapFd 等入口）
    if (teardown) {
        if (hooks.onTeardown)
            hooks.onTeardown();
        if (hooks.onStateChanged)
            hooks.onStateChanged();
        return;
    }
    if (needEstablish && hooks.onEstablish)
        hooks.onEstablish(req);
    if (hooks.onStateChanged)
        hooks.onStateChanged();
}

// ---- timer（keepaliveJob + peersJob 直译：45s 保活 + 5s Peer 轮询） ----

void TunnelRuntime::startTimer()
{
    {
        std::lock_guard<std::mutex> lk(m_timerLock);
        m_timerQuit = false;
    }
    m_timer = std::thread(&TunnelRuntime::timerLoop, this);
}

void TunnelRuntime::stopTimer()
{
    {
        std::lock_guard<std::mutex> lk(m_timerLock);
        m_timerQuit = true;
    }
    m_timerCv.notify_all();
    if (m_timer.joinable())
        m_timer.join();
}

void TunnelRuntime::timerLoop()
{
    using std::chrono::milliseconds;
    using std::chrono::seconds;
    using std::chrono::steady_clock;
    auto lastKeepalive = steady_clock::now();
    auto lastPeers = steady_clock::now();
    for (;;) {
        {
            std::unique_lock<std::mutex> lk(m_timerLock);
            m_timerCv.wait_for(lk, milliseconds(500), [&] { return m_timerQuit; });
            if (m_timerQuit)
                break;
        }
        const steady_clock::time_point now = steady_clock::now();
        if (now - lastKeepalive >= seconds(45)) {
            lastKeepalive = now;
            m_fc.sendKeepalive(); // 闲置保活：每活跃网络广播一个 ARP 探测帧
        }
        if (now - lastPeers >= seconds(5)) {
            lastPeers = now;
            pollPeers();
        }
    }
}

// Peer 快照轮询（peersJob 直译：5s 周期；门控存活三态——F3：running 的 brief
// 重定义是「TUN 已建立」，Starting 期（零网络或 TUN 迟建）按 running 门控会永不
// 轮询，Android 在 pipeline 起来即推流）
void TunnelRuntime::pollPeers()
{
    CoreBridge *core = m_core.get();
    if (!core)
        return;
    {
        std::lock_guard<std::mutex> lk(m_lock);
        if (!isAliveKindLocked())
            return;
    }
    std::vector<PeerInfo> peers = core->peersNow();
    {
        std::lock_guard<std::mutex> lk(m_lock);
        m_state.peers = std::move(peers);
    }
    if (hooks.onStateChanged)
        hooks.onStateChanged();
}

// ---- NetWatch 透出 ----

void TunnelRuntime::setPathSatisfied(bool ok)
{
    {
        std::lock_guard<std::mutex> lk(m_lock);
        m_pathSatisfied = ok; // 序列化不含（TunnelSnapshot 的 pathSatisfied 由写方注入）
    }
    if (hooks.onStateChanged)
        hooks.onStateChanged(); // 供壳层择机落盘
}

// ---- 快照 JSON（TunnelContract.ets 契约；pathSatisfied/writtenAt 由写方注入） ----

std::string TunnelRuntime::snapshotJson() const
{
    const RuntimeState st = state();
    std::string o;
    o.reserve(1024);
    // tunnelState {kind, reason?, recoverable?}
    o = "{\"tunnelState\":{\"kind\":";
    jsonStr(st.kind, o);
    if (!st.reason.empty()) {
        o += ",\"reason\":";
        jsonStr(st.reason, o);
    }
    if (st.kind == "failed") {
        o += ",\"recoverable\":";
        o += st.recoverable ? "true" : "false";
    }
    o += "}";
    // nodeStatus：null（未上线/已停机）或 {nodeId, online, coreVersion}
    if (st.nodeId.empty()) {
        o += ",\"nodeStatus\":null";
    } else {
        o += ",\"nodeStatus\":{\"nodeId\":";
        jsonStr(st.nodeId, o);
        o += ",\"online\":";
        o += st.online ? "true" : "false";
        o += ",\"coreVersion\":";
        jsonStr(st.coreVersion, o);
        o += "}";
    }
    // coreVersion 顶层缓存（停机不清）
    o += ",\"coreVersion\":";
    jsonStr(st.coreVersion, o);
    // networkStatuses：16 位小写 hex → status 原始码
    o += ",\"networkStatuses\":{";
    bool first = true;
    for (const auto &kv : st.networkStatuses) {
        if (!first)
            o += ",";
        first = false;
        o += "\"" + hex16(kv.first) + "\":" + std::to_string(kv.second);
    }
    o += "}";
    // networkConflicts：16 位小写 hex → "address"|"subnet"
    o += ",\"networkConflicts\":{";
    first = true;
    for (const auto &kv : st.networkConflicts) {
        if (!first)
            o += ",";
        first = false;
        o += "\"" + hex16(kv.first) + "\":";
        jsonStr(kv.second, o);
    }
    o += "}";
    // networkConfigs：数组（元素含 nwid 十六进制串）
    o += ",\"networkConfigs\":[";
    first = true;
    for (const auto &kv : st.networkConfigs) {
        if (!first)
            o += ",";
        first = false;
        const NetConf &c = kv.second;
        o += "{\"nwid\":\"" + hex16(kv.first) + "\",\"name\":";
        jsonStr(c.name, o);
        o += ",\"status\":" + std::to_string(c.status);
        o += ",\"type\":";
        jsonStr(c.type, o);
        o += ",\"mac\":" + std::to_string(static_cast<unsigned long long>(c.mac));
        o += ",\"mtu\":" + std::to_string(c.mtu);
        o += ",\"broadcastEnabled\":";
        o += c.broadcastEnabled ? "true" : "false";
        o += ",\"bridge\":";
        o += c.bridge ? "true" : "false";
        o += ",\"dhcp\":";
        o += c.dhcp ? "true" : "false";
        o += ",\"assignedAddrs\":[" + jsonArr(c.assignedAddrs) + "]";
        o += ",\"routes\":[" + jsonArr(c.routes) + "]";
        o += ",\"dns\":[" + jsonArr(c.dns) + "]}";
    }
    o += "]";
    // peers：paths 恒空数组（A2 PeerInfo 无物理路径表，A6 真机评估后决定是否扩 CoreBridge）
    o += ",\"peers\":[";
    first = true;
    for (const PeerInfo &p : st.peers) {
        if (!first)
            o += ",";
        first = false;
        o += "{\"address\":" + std::to_string(static_cast<unsigned long long>(p.address));
        o += ",\"version\":";
        jsonStr(p.version, o);
        o += ",\"latency\":" + std::to_string(p.latency);
        o += ",\"role\":";
        jsonStr(p.role, o);
        o += ",\"paths\":[]}";
    }
    o += "]";
    // applyTrace / eventLog（40 条滚动以 '\n' 连接，TunnelStateBus.eventLog 同源格式）
    o += ",\"applyTrace\":";
    jsonStr(st.applyTrace, o);
    o += ",\"eventLog\":";
    jsonStr(joinStrings(st.eventLog, "\n"), o);
    o += "}";
    return o;
}

// ---- 事件日志（TunnelStateBus.log 直译：HH:mm:ss.SSS 时间戳 + takeLast(40)） ----

void TunnelRuntime::log(const std::string &line)
{
    std::lock_guard<std::mutex> lk(m_lock);
    logLocked(line);
}

void TunnelRuntime::logLocked(const std::string &line)
{
    m_state.eventLog.push_back(nowHmsMs() + " " + line);
    if (m_state.eventLog.size() > 40)
        m_state.eventLog.erase(m_state.eventLog.begin(), m_state.eventLog.end() - 40);
}

// ---- 测试注入通道 ----

#ifdef PP_TUNNELRUNTIME_TEST_HOOKS

void TunnelRuntime::testFeedNetConf(uint64_t nwid, const NetConf &conf)
{
    Evt ev;
    ev.kind = Evt::KNetConf;
    ev.nwid = nwid;
    ev.op = 1; // VIRTUAL_NETWORK_CONFIG_OPERATION_UP（首份完整 netconf 的核心语义）
    ev.conf = conf;
    pushEvt(std::move(ev));
}

void TunnelRuntime::testFeedEvent(int event)
{
    Evt ev;
    ev.kind = Evt::KEvent;
    ev.event = event;
    pushEvt(std::move(ev));
}

void TunnelRuntime::testPollPeers()
{
    pollPeers();
}

#endif // PP_TUNNELRUNTIME_TEST_HOOKS

} // namespace pp
