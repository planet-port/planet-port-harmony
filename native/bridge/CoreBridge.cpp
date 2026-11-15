#include "CoreBridge.h"

#include <ZeroTierOne.h>

#include "dataplane/Net.h"

#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/types.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>

namespace pp {

namespace {

// 墙钟毫秒（对齐 iOS ztNowMillis / Kotlin System.currentTimeMillis——核心 now 参数为毫秒时钟）
int64_t nowMs()
{
    return (int64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

// 逐级建目录（对齐 Kotlin File.mkdirs()）；已存在时 EEXIST 无害
void mkdirs(const std::string &path)
{
    if (path.empty())
        return;
    for (size_t i = 1; i <= path.size(); ++i) {
        if (i == path.size() || path[i] == '/')
            ::mkdir(path.substr(0, i).c_str(), 0700);
    }
}

std::string parentDir(const std::string &path)
{
    const size_t p = path.find_last_of('/');
    if (p == std::string::npos)
        return std::string();
    return path.substr(0, p);
}

std::string joinPath(const std::string &dir, const std::string &name)
{
    if (dir.empty())
        return name;
    if (dir.back() == '/')
        return dir + name;
    return dir + "/" + name;
}

// 仅取 IP 文本（assigned/routes 的 prefix 装在 port 字段、via 的 port 无意义、DNS 不带端口）。
// 复用 Net.h 手写格式化（与数据面同一套 v4/v6 语义），每调用栈上构造，无 static 缓冲。
std::string sockaddrIpString(const struct sockaddr_storage *ss)
{
    if (!ss)
        return std::string();
    if (ss->ss_family == AF_INET) {
        uint32_t a = 0;
        std::memcpy(&a, &reinterpret_cast<const struct sockaddr_in *>(ss)->sin_addr, sizeof(a));
        return dottedV4(ntohl(a));
    }
    if (ss->ss_family == AF_INET6) {
        Ipv6Address a;
        std::memcpy(a.bytes.data(), &reinterpret_cast<const struct sockaddr_in6 *>(ss)->sin6_addr, 16);
        return formatV6(a);
    }
    return std::string(); // family==0（如无网关的 route.via）= 空 → 调用侧按「无」处理
}

// C API 约定：prefix/netmask bits 装在 sockaddr port 字段，网络字节序（核心 Utils::hton 写入）
unsigned int sockaddrPrefixBits(const struct sockaddr_storage *ss)
{
    if (!ss)
        return 0;
    if (ss->ss_family == AF_INET)
        return ntohs(reinterpret_cast<const struct sockaddr_in *>(ss)->sin_port);
    if (ss->ss_family == AF_INET6)
        return ntohs(reinterpret_cast<const struct sockaddr_in6 *>(ss)->sin6_port);
    return 0;
}

bool endpointToSockaddr(const WireEndpoint &endpoint, struct sockaddr_storage &ss)
{
    std::memset(&ss, 0, sizeof(ss));
    // 手写解析（Net.h）：必须含 ':' 才按 v6——防纯数字串触发 DNS 的既定语义
    if (endpoint.ip.find(':') != std::string::npos) {
        const auto v6 = parseIpv6(endpoint.ip);
        if (!v6)
            return false;
        auto *sa6 = reinterpret_cast<struct sockaddr_in6 *>(&ss);
        sa6->sin6_family = AF_INET6;
        std::memcpy(&sa6->sin6_addr, v6->bytes.data(), 16);
        sa6->sin6_port = htons(endpoint.port);
        return true;
    }
    const auto v4 = parseIpv4(endpoint.ip);
    if (!v4)
        return false;
    auto *sa4 = reinterpret_cast<struct sockaddr_in *>(&ss);
    sa4->sin_family = AF_INET;
    const uint32_t be = htonl(*v4);
    std::memcpy(&sa4->sin_addr, &be, sizeof(be));
    sa4->sin_port = htons(endpoint.port);
    return true;
}

WireEndpoint sockaddrToEndpoint(const struct sockaddr_storage *ss)
{
    WireEndpoint ep;
    if (!ss)
        return ep;
    ep.ip = sockaddrIpString(ss);
    if (ss->ss_family == AF_INET)
        ep.port = ntohs(reinterpret_cast<const struct sockaddr_in *>(ss)->sin_port);
    else if (ss->ss_family == AF_INET6)
        ep.port = ntohs(reinterpret_cast<const struct sockaddr_in6 *>(ss)->sin6_port);
    return ep;
}

// ZT_VirtualNetworkConfig → NetConf（对齐 Kotlin VirtualNetworkConfig.toNetConf / iOS ztConvertNetworkConfig）。
// 每次调用构造全新值对象（含全部 std::string/vector），回调线程间零共享可变状态（红线）。
NetConf toNetConf(const ZT_VirtualNetworkConfig *cfg)
{
    NetConf out;
    out.nwid = cfg->nwid;
    out.name.assign(cfg->name, strnlen(cfg->name, ZT_MAX_NETWORK_SHORT_NAME_LENGTH));
    out.status = (int)cfg->status;
    switch (cfg->type) {
        case ZT_NETWORK_TYPE_PRIVATE:
            out.type = "PRIVATE";
            break;
        case ZT_NETWORK_TYPE_PUBLIC:
            out.type = "PUBLIC";
            break;
        default:
            break; // 未知类型为空串（对齐 Kotlin removePrefix 后的空语义）
    }
    out.mac = cfg->mac;
    out.mtu = (int)cfg->mtu;
    out.broadcastEnabled = cfg->broadcastEnabled != 0;
    out.bridge = cfg->bridge != 0;
    out.dhcp = cfg->dhcp != 0;

    for (unsigned int i = 0; i < cfg->assignedAddressCount && i < ZT_MAX_ZT_ASSIGNED_ADDRESSES; ++i) {
        const std::string ip = sockaddrIpString(&cfg->assignedAddresses[i]);
        if (ip.empty())
            continue;
        out.assignedAddrs.push_back(ip + "/" + std::to_string(sockaddrPrefixBits(&cfg->assignedAddresses[i])));
    }
    for (unsigned int i = 0; i < cfg->routeCount && i < ZT_MAX_NETWORK_ROUTES; ++i) {
        const ZT_VirtualNetworkRoute *r = &cfg->routes[i];
        const std::string target = sockaddrIpString(&r->target);
        if (target.empty())
            continue;
        std::string s = target + "/" + std::to_string(sockaddrPrefixBits(&r->target));
        // C API 约定：via 的 family==0 即 LAN-local 无网关；IP 装地址字段、port 无意义
        const std::string via = sockaddrIpString(&r->via);
        if (!via.empty())
            s += " via " + via;
        out.routes.push_back(std::move(s));
    }
    // DNS：ZT_VirtualNetworkDNS.server_addr，空 family 即结束（对齐 iOS ztConvertNetworkConfig）
    for (unsigned int i = 0; i < ZT_MAX_DNS_SERVERS; ++i) {
        const struct sockaddr_storage *s = &cfg->dns.server_addr[i];
        if (s->ss_family != AF_INET && s->ss_family != AF_INET6)
            break;
        std::string ip = sockaddrIpString(s);
        if (!ip.empty())
            out.dns.push_back(std::move(ip));
    }
    return out;
}

std::string peerRoleString(int role)
{
    switch (role) {
        case ZT_PEER_ROLE_LEAF:
            return "LEAF";
        case ZT_PEER_ROLE_MOON:
            return "MOON";
        case ZT_PEER_ROLE_PLANET:
            return "PLANET";
        default:
            return std::string();
    }
}

// 状态对象 → 规范对象名（ZeroTierOne.h 各 Canonical path；C API 只有 type+id，
// 文件名布局是宿主侧约定，对齐 iOS ztStateFilePath：moon 16 位 hex、peer 10 位 hex、
// netconf 16 位 hex.conf）。栈上 buf 每调用自持（线程安全）。
std::string stateObjectName(enum ZT_StateObjectType type, const uint64_t id[2])
{
    char buf[48];
    switch (type) {
        case ZT_STATE_OBJECT_IDENTITY_PUBLIC:
            return "identity.public";
        case ZT_STATE_OBJECT_IDENTITY_SECRET:
            return "identity.secret";
        case ZT_STATE_OBJECT_PLANET:
            return "planet";
        case ZT_STATE_OBJECT_MOON:
            std::snprintf(buf, sizeof(buf), "moons.d/%016llx.moon", (unsigned long long)id[0]);
            return std::string(buf);
        case ZT_STATE_OBJECT_PEER:
            std::snprintf(buf, sizeof(buf), "peers.d/%010llx", (unsigned long long)id[0]);
            return std::string(buf);
        case ZT_STATE_OBJECT_NETWORK_CONFIG:
            std::snprintf(buf, sizeof(buf), "networks.d/%016llx.conf", (unsigned long long)id[0]);
            return std::string(buf);
        default:
            return std::string(); // NULL 等未知对象：statePut 忽略 / stateGet 返回 -1
    }
}

} // namespace

// ---- 纯函数（公开，供单测与复用） ----

std::optional<std::string> stateFilePathFor(const std::string &dataStoreRoot, const std::string &planetDir,
                                            const std::string &planetFile, bool identityPerPlanet,
                                            const std::string &name)
{
    // NodeRuntime.stateFile 分流直译：
    //   identity.* → 独立模式落 planetDir（每行星一身份），共享模式落 dataStoreRoot（全行星共用）
    //   planet → 自定义 planetFile 优先；否则 dataStoreRoot/planet（仍缺失时核心用内置 planet）
    //   moons.d/networks.d/peers.d → planetDir（moon/peer/netconf 按激活 planet 隔离，
    //     防相同 ID 在不同世界间串数据）
    //   其它 → nullopt（stateGet 返回 -1 / statePut 忽略）
    if (name == "identity.public" || name == "identity.secret")
        return joinPath(identityPerPlanet ? planetDir : dataStoreRoot, name);
    if (name == "planet") {
        if (!planetFile.empty())
            return planetFile;
        return joinPath(dataStoreRoot, "planet");
    }
    if (name.compare(0, 8, "moons.d/") == 0 || name.compare(0, 11, "networks.d/") == 0 ||
        name.compare(0, 8, "peers.d/") == 0)
        return joinPath(planetDir, name);
    return std::nullopt;
}

void putFileAtomic(const std::string &path, const uint8_t *data, size_t len, bool secure)
{
    if (path.empty())
        return;
    mkdirs(parentDir(path));
    const std::string tmp = path + ".tmp";
    std::FILE *f = std::fopen(tmp.c_str(), "wb");
    if (!f)
        return; // 目录不可写等：无 .tmp 也无目标文件（失败即放弃，核心按错误计）
    bool ok = true;
    if (len > 0 && data)
        ok = std::fwrite(data, 1, len, f) == len;
    ok = (std::fclose(f) == 0) && ok;
    if (!ok) {
        std::remove(tmp.c_str()); // 半文件危害：崩溃残留会让下次启动解析失败（NodeRuntime 注释）
        return;
    }
    if (secure)
        ::chmod(tmp.c_str(), 0600); // rename 前收紧：目标文件权限继承 tmp，无双权限窗口
    if (std::rename(tmp.c_str(), path.c_str()) != 0)
        std::remove(tmp.c_str()); // rename 失败（跨设备等）同样不残留 .tmp
}

// ---- Impl：ZT_Node* 与驱动线程 ----

struct CoreBridge::Impl {
    std::string dataStoreRoot;
    std::string planetDir;
    std::string planetFile;
    bool identityPerPlanet = false;
    CoreBridge *owner = nullptr; // 回调经 owner 读 hooks（public 成员，无访问性问题）

    // 节点大锁：一切 ZT_Node_* 调用的外部序列化点，驱动线程同锁参与（「跨线程调 ZT_*
    // 必须外部序列化」）。用递归锁：ZT 回调在锁内同步触发 hooks，消费侧若在同线程
    // 回入控制面（如 sendPacket 处理中再调 processWirePacket）不会自锁死（对齐 iOS
    // ZTBridge 的 NSRecursiveLock 语义）。
    std::recursive_mutex lock;
    ZT_Node *node = nullptr;

    std::thread driver;
    // 驱动线程身份（driverLoop 进入即记录，完整停机 join 后清零）：shutdown 的
    // self-join 防御判定源。atomic 化的原因：driverLoop 在首次取锁前写入，而
    // 其它线程的 shutdown 可在锁内读——裸 thread::id 即数据竞争
    std::atomic<std::thread::id> driverThreadId{std::thread::id()};
    std::atomic<bool> stopDriver{false};    // loop 顶部免锁检查：shutdown 置位后驱动线程可退出
    std::atomic<bool> driverExited{false};  // shutdown join 的完成信号
    std::mutex exitMtx;
    std::condition_variable exitCv;

    Impl(std::string dsRoot, std::string pDir, std::string pFile, bool perPlanet, CoreBridge *o)
        : dataStoreRoot(std::move(dsRoot)), planetDir(std::move(pDir)), planetFile(std::move(pFile)),
          identityPerPlanet(perPlanet), owner(o)
    {
    }

    // ZT_Node_new + C 回调注册。回调必须是无捕获 lambda（可隐式转函数指针），函数体
    // 继承本成员函数的访问权——C 类型由此只活在 .cpp，头文件保持 ZeroTierOne.h-free。
    static ZT_Node *createNode(Impl *im)
    {
        ZT_Node_Config config;
        std::memset(&config, 0, sizeof(config)); // 不可传 nullptr：核心构造时逐字段拷贝直接解引用

        ZT_Node_Callbacks cb;
        std::memset(&cb, 0, sizeof(cb));
        cb.version = 0; // 1.16.2 校验 callbacks->version 必须为 0

        // statePut：写状态文件（C API 无 secure 标志，identity.secret 按 type 收紧 0600，
        // 对齐 Kotlin `secure || name == "identity.secret"` 的并集语义）；len<0 = 删除
        cb.statePutFunction = +[](ZT_Node *, void *uptr, void *, enum ZT_StateObjectType type,
                                  const uint64_t id[2], const void *data, int len) {
            auto *b = static_cast<CoreBridge *>(uptr);
            if (!b || !b->m_impl)
                return;
            const std::string name = stateObjectName(type, id);
            if (name.empty())
                return;
            const auto path = stateFilePathFor(b->m_impl->dataStoreRoot, b->m_impl->planetDir,
                                               b->m_impl->planetFile, b->m_impl->identityPerPlanet, name);
            if (!path)
                return;
            if (len < 0) {
                std::remove(path->c_str()); // -1 = 删除（对齐 Kotlin onDelete / iOS len<0）
                return;
            }
            putFileAtomic(*path, static_cast<const uint8_t *>(data), (size_t)len,
                          type == ZT_STATE_OBJECT_IDENTITY_SECRET);
        };

        // stateGet：读状态文件；对象名未知 / 文件不存在 / 缓冲不足 → -1（头文件契约：
        // 核心视作不存在——identity 缺失即生成新身份，planet 缺失即用内置 planet）
        cb.stateGetFunction = +[](ZT_Node *, void *uptr, void *, enum ZT_StateObjectType type,
                                  const uint64_t id[2], void *buf, unsigned int buflen) -> int {
            auto *b = static_cast<CoreBridge *>(uptr);
            if (!b || !b->m_impl)
                return -1;
            const std::string name = stateObjectName(type, id);
            if (name.empty())
                return -1; // brief：nullopt → -1
            const auto path = stateFilePathFor(b->m_impl->dataStoreRoot, b->m_impl->planetDir,
                                               b->m_impl->planetFile, b->m_impl->identityPerPlanet, name);
            if (!path)
                return -1;
            std::FILE *f = std::fopen(path->c_str(), "rb");
            if (!f)
                return -1;
            std::string data; // 每回调自持缓冲（线程安全，红线：禁 static 复用）
            char chunk[4096];
            size_t n;
            while ((n = std::fread(chunk, 1, sizeof(chunk), f)) > 0)
                data.append(chunk, n);
            std::fclose(f);
            if (data.empty() || data.size() > buflen)
                return -1;
            std::memcpy(buf, data.data(), data.size());
            return (int)data.size();
        };

        // 物理发包出口：直接转发 hooks.sendPacket（返回值语义 0 成功/非 0 失败原样透传）
        cb.wirePacketSendFunction = +[](ZT_Node *, void *uptr, void *, int64_t,
                                        const struct sockaddr_storage *remoteAddr, const void *data,
                                        unsigned int len, unsigned int) -> int {
            auto *b = static_cast<CoreBridge *>(uptr);
            if (!b || !b->hooks.sendPacket)
                return -1; // 对齐 iOS：无出口视作失败
            const WireEndpoint ep = sockaddrToEndpoint(remoteAddr); // 每回调自持值对象
            return b->hooks.sendPacket(static_cast<const uint8_t *>(data), len, ep);
        };

        // 虚网帧上行：进入即只做 Hooks 投递（帧指针仅回调期内有效）——ARP/解析是
        // FrameConverter 在自己线程的事，不得在核心回调线程做（NodeRuntime 语义）
        cb.virtualNetworkFrameFunction = +[](ZT_Node *, void *uptr, void *, uint64_t nwid, void **,
                                             uint64_t srcMac, uint64_t dstMac, unsigned int etherType,
                                             unsigned int vlanId, const void *frame, unsigned int len) {
            auto *b = static_cast<CoreBridge *>(uptr);
            if (!b || !b->hooks.onFrame)
                return;
            b->hooks.onFrame(nwid, srcMac, dstMac, (uint16_t)etherType, (uint16_t)vlanId,
                             static_cast<const uint8_t *>(frame), len);
        };

        // netconf：UP(1)/CONFIG_UPDATE(2) 全量投递快照（首网络走 UP，仅认 CONFIG_UPDATE
        // 会漏首网）；DOWN(3)/DESTROY(4) 不投快照（可能仍带旧地址，对齐 TunnelManager
        // 拒收），事件仍上报（-op）。返回 0=成功；非 0 会把网络置 PORT_ERROR（iOS 注释）。
        cb.virtualNetworkConfigFunction =
            +[](ZT_Node *, void *uptr, void *, uint64_t nwid, void **,
                enum ZT_VirtualNetworkConfigOperation op, const ZT_VirtualNetworkConfig *cfg) -> int {
            auto *b = static_cast<CoreBridge *>(uptr);
            if (!b)
                return 0;
            if (cfg && (op == ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_UP ||
                        op == ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_CONFIG_UPDATE)) {
                if (b->hooks.onNetConf)
                    b->hooks.onNetConf(nwid, (int)op, toNetConf(cfg));
            } else if (b->hooks.onEvent) {
                b->hooks.onEvent(-(int)op);
            }
            return 0;
        };

        // 事件：原生 ZT_Event 原始值透传（UP 在 Node 构造期同步投递，消费侧可确定性收到）
        cb.eventCallback = +[](ZT_Node *, void *uptr, void *, enum ZT_Event event, const void *) {
            auto *b = static_cast<CoreBridge *>(uptr);
            if (!b || !b->hooks.onEvent)
                return;
            b->hooks.onEvent((int)event);
        };

        // pathCheck/pathLookup 不注册：iOS/Android 同款缺省（头文件注明核心对 ZT 自管
        // 网段自带防环；隧道侧 TUN 网段由数据面自行排除）

        ZT_Node *node = nullptr;
        if (ZT_Node_new(&node, &config, im->owner, nullptr, &cb, nowMs()) != ZT_RESULT_OK)
            return nullptr; // 失败时 *node 不产出，无需 close（对齐 Kotlin 失败路径无泄漏）
        return node;
    }

    // 后台任务驱动线程：processBackgroundTasks 循环，wait = clamp(deadline-now, 50, 100)ms
    // （对齐 iOS bgTimer / Kotlin coerceIn）。每次驱动前拿节点大锁（与控制面外部序列化），
    // 锁内二次确认 stop——shutdown 可能在等锁期间已置位，此刻不得再进核心。
    static void driverLoop(Impl *im)
    {
        // 记录驱动线程身份：hook 内 shutdown 的 self-join 防御比对源（停机后清零）
        im->driverThreadId.store(std::this_thread::get_id(), std::memory_order_release);
        int64_t deadline = 0;
        for (;;) {
            if (im->stopDriver.load(std::memory_order_relaxed))
                break;
            int rc;
            {
                std::lock_guard<std::recursive_mutex> g(im->lock);
                if (im->stopDriver.load(std::memory_order_relaxed) || !im->node)
                    break;
                rc = (int)ZT_Node_processBackgroundTasks(im->node, nullptr, nowMs(), &deadline);
            }
            if (rc != (int)ZT_RESULT_OK) {
                // 对齐 NodeRuntime 驱动循环（P4 终审 B-3）：静默 break 会把状态悬在假在线；
                // 错误经 Hooks 上报（-(ZT_ResultCode)，负值与 ZT_Event 0..7 不冲突）后退出
                if (im->owner->hooks.onEvent)
                    im->owner->hooks.onEvent(-rc);
                break;
            }
            int64_t wait = deadline - nowMs();
            if (wait < 50)
                wait = 50;
            if (wait > 100)
                wait = 100;
            std::this_thread::sleep_for(std::chrono::milliseconds(wait));
        }
        im->driverExited.store(true, std::memory_order_release);
        {
            std::lock_guard<std::mutex> g(im->exitMtx);
            im->exitCv.notify_all();
        }
    }
};

// ---- CoreBridge 生命周期 ----

CoreBridge::CoreBridge(std::string dataStoreRoot, std::string planetDir,
                       std::string planetFile, bool identityPerPlanet)
    : m_impl(new Impl(std::move(dataStoreRoot), std::move(planetDir), std::move(planetFile),
                      identityPerPlanet, this))
{
}

CoreBridge::~CoreBridge()
{
    // 析构兜底停机：驱动线程必须先于 Impl 消亡（否则 join 悬空线程 + 节点泄漏/UAF）
    shutdown();
}

bool CoreBridge::start()
{
    if (!m_impl)
        return false;
    Impl &im = *m_impl;
    std::lock_guard<std::recursive_mutex> g(im.lock);
    if (im.node)
        return false; // 已启动（@Synchronized 幂等语义）
    mkdirs(im.dataStoreRoot);
    mkdirs(im.planetDir);
    im.stopDriver.store(false, std::memory_order_relaxed);
    im.driverExited.store(false, std::memory_order_relaxed);
    im.driverThreadId.store(std::thread::id(), std::memory_order_relaxed); // 残留 id 不得跨代匹配

    ZT_Node *node = Impl::createNode(&im);
    if (!node)
        return false;
    im.node = node;

    // 启动即驱动一次后台任务：身份生成/装载在此发生（对齐 iOS startWithDataStorePath
    // / Kotlin start 的「identity 生成/装载在此发生」注释）
    int64_t deadline = 0;
    ZT_Node_processBackgroundTasks(node, nullptr, nowMs(), &deadline);

    try {
        im.driver = std::thread(&Impl::driverLoop, &im);
    } catch (...) {
        // 线程创建失败：无驱动 = 永远 offline，按启动失败回滚（不留半可用状态）
        im.node = nullptr;
        ZT_Node_delete(node);
        return false;
    }
    return true;
}

void CoreBridge::shutdown()
{
    if (!m_impl)
        return;
    Impl &im = *m_impl;
    {
        std::lock_guard<std::recursive_mutex> g(im.lock);
        // 驱动线程 hook 内同步回入（A3 高概率形态：onEvent 收到致命错误后走停机链）：
        // 此时 join 必是 join 自己（std::system_error resource_deadlock_would_occur
        // → 未捕获 → terminate 进程死），exitCv 也永远等不到（driverExited 只能由
        // 本线程置位）。防御：只置停机标志立即返回——驱动线程返回 hook 后由 loop
        // 顶部检查退出，完整收口（join + delete）留给真实停机线程或析构兜底 shutdown
        if (std::this_thread::get_id() == im.driverThreadId.load(std::memory_order_acquire)) {
            im.stopDriver.store(true, std::memory_order_relaxed);
            return;
        }
        if (!im.node)
            return; // 幂等：未启动/已停机自然 no-op（Kotlin @Synchronized 二次进入语义）
        // 只置位不 join：join 必须在锁外等——驱动线程若正等锁进下一次驱动，
        // 持锁 join 会与它互相等待成死锁
        im.stopDriver.store(true, std::memory_order_relaxed);
    }
    // 先停驱动线程再 delete（核心契约：processXXX 在飞时 delete 会崩溃）。500ms 为
    // 快路径兜底；hook 卡死等病理场景退化为阻塞 join——宁可停机慢也不冒 UAF 风险
    // （Kotlin runBlocking join 同语义）
    {
        std::unique_lock<std::mutex> lg(im.exitMtx);
        im.exitCv.wait_for(lg, std::chrono::milliseconds(500),
                           [&im] { return im.driverExited.load(std::memory_order_acquire); });
    }
    std::lock_guard<std::recursive_mutex> g(im.lock);
    if (im.driver.joinable()) {
        im.driver.join();
        // 停机后清零：线程 id 可能被实现复用，残留值不得再匹配后续启动的驱动线程
        im.driverThreadId.store(std::thread::id(), std::memory_order_relaxed);
    }
    if (im.node) {
        ZT_Node_delete(im.node); // 核心析构会发 ZT_EVENT_DOWN → cbEvent 投递后返回（持锁内）
        im.node = nullptr;
    }
}

// ---- 控制面 ----

void CoreBridge::join(uint64_t nwid)
{
    if (!m_impl)
        return;
    std::lock_guard<std::recursive_mutex> g(m_impl->lock);
    if (m_impl->node)
        ZT_Node_join(m_impl->node, nwid, nullptr, nullptr);
}

void CoreBridge::leave(uint64_t nwid)
{
    if (!m_impl)
        return;
    std::lock_guard<std::recursive_mutex> g(m_impl->lock);
    if (m_impl->node) {
        void *networkUserPtr = nullptr;
        ZT_Node_leave(m_impl->node, nwid, &networkUserPtr, nullptr);
    }
}

void CoreBridge::orbit(uint64_t moonWorldId, uint64_t seed)
{
    if (!m_impl)
        return;
    std::lock_guard<std::recursive_mutex> g(m_impl->lock);
    if (m_impl->node)
        ZT_Node_orbit(m_impl->node, nullptr, moonWorldId, seed);
}

void CoreBridge::deorbit(uint64_t moonWorldId)
{
    if (!m_impl)
        return;
    std::lock_guard<std::recursive_mutex> g(m_impl->lock);
    if (m_impl->node)
        ZT_Node_deorbit(m_impl->node, nullptr, moonWorldId);
}

void CoreBridge::multicastSubscribe(uint64_t nwid, uint64_t multicastGroup, uint64_t multicastAdi)
{
    if (!m_impl)
        return;
    std::lock_guard<std::recursive_mutex> g(m_impl->lock);
    if (m_impl->node)
        ZT_Node_multicastSubscribe(m_impl->node, nullptr, nwid, multicastGroup, (unsigned long)multicastAdi);
}

std::optional<uint64_t> CoreBridge::address()
{
    if (!m_impl)
        return std::nullopt;
    std::lock_guard<std::recursive_mutex> g(m_impl->lock);
    if (!m_impl->node)
        return std::nullopt;
    return ZT_Node_address(m_impl->node);
}

const char *CoreBridge::version()
{
    // 内容恒定的静态串：函数级 static 初始化（C++11 魔法静态，线程安全），只初始化
    // 一次后并发读安全——不落可写 static 缓冲（A2 挂账 #3）
    static const std::string v = [] {
        int major = 0, minor = 0, revision = 0;
        ZT_version(&major, &minor, &revision);
        char buf[32];
        std::snprintf(buf, sizeof(buf), "%d.%d.%d", major, minor, revision);
        return std::string(buf);
    }();
    return v.c_str();
}

// ---- 数据面入口 ----

bool CoreBridge::processWirePacket(const uint8_t *data, size_t len, const WireEndpoint &endpoint)
{
    if (!m_impl || !data || len == 0)
        return false;
    struct sockaddr_storage ss;
    if (!endpointToSockaddr(endpoint, ss))
        return false; // 非法端点（含「必须含 ':' 才按 v6」防 DNS 语义）
    std::lock_guard<std::recursive_mutex> g(m_impl->lock);
    if (!m_impl->node)
        return false;
    int64_t deadline = 0;
    // localSocket=-1：任意本地 socket 发出（对齐 Kotlin/iOS）
    return ZT_Node_processWirePacket(m_impl->node, nullptr, nowMs(), -1, &ss, data, (unsigned int)len,
                                     &deadline) == ZT_RESULT_OK;
}

void CoreBridge::processVirtualNetworkFrame(uint64_t nwid, uint64_t srcMac, uint64_t dstMac,
                                            uint16_t etherType, uint16_t vlanId, const uint8_t *frame,
                                            size_t len)
{
    if (!m_impl || !frame || len == 0)
        return;
    std::lock_guard<std::recursive_mutex> g(m_impl->lock);
    if (!m_impl->node)
        return;
    int64_t deadline = 0;
    // 返回码忽略：对齐 Kotlin（void 语义），错误由驱动循环/事件面暴露
    ZT_Node_processVirtualNetworkFrame(m_impl->node, nullptr, nowMs(), nwid, srcMac, dstMac, etherType,
                                       vlanId, frame, (unsigned int)len, &deadline);
}

std::optional<NetConf> CoreBridge::networkConf(uint64_t nwid)
{
    if (!m_impl)
        return std::nullopt;
    std::lock_guard<std::recursive_mutex> g(m_impl->lock);
    if (!m_impl->node)
        return std::nullopt;
    ZT_VirtualNetworkConfig *cfg = ZT_Node_networkConfig(m_impl->node, nwid);
    if (!cfg)
        return std::nullopt; // 未加入该网络
    NetConf out = toNetConf(cfg);
    ZT_Node_freeQueryResult(m_impl->node, cfg);
    return out;
}

std::vector<PeerInfo> CoreBridge::peersNow()
{
    if (!m_impl)
        return {};
    std::lock_guard<std::recursive_mutex> g(m_impl->lock);
    if (!m_impl->node)
        return {};
    ZT_PeerList *list = ZT_Node_peers(m_impl->node);
    if (!list)
        return {};
    std::vector<PeerInfo> out;
    out.reserve(list->peerCount);
    for (unsigned long i = 0; i < list->peerCount; ++i) {
        const ZT_Peer &p = list->peers[i];
        PeerInfo pi;
        pi.address = p.address;
        // 版本三段直拼；未知 -1 时为 "v-1.-1.-1"（对齐 Kotlin/iOS 注释：语义为「版本未知」）
        char buf[32];
        std::snprintf(buf, sizeof(buf), "v%d.%d.%d", p.versionMajor, p.versionMinor, p.versionRev);
        pi.version = buf;
        pi.latency = p.latency;
        pi.role = peerRoleString((int)p.role);
        out.push_back(std::move(pi));
    }
    ZT_Node_freeQueryResult(m_impl->node, list);
    return out;
}

// ---- 自由函数 ----

const char *coreVersion()
{
    return CoreBridge::version(); // 单一来源
}

const char *smokeIdentityGen(const char *homeDir)
{
    if (!homeDir || homeDir[0] == '\0')
        return "";
    CoreBridge b(homeDir, homeDir, std::string(), false);
    if (!b.start())
        return "";
    const auto addr = b.address();
    b.shutdown();
    if (!addr)
        return "";
    char buf[16];
    // 节点地址规范形式 = 10 位小写十六进制（对齐核心 Address::toString / Utils::hex10）
    std::snprintf(buf, sizeof(buf), "%010llx", (unsigned long long)*addr);
    // 返回裸指针的既有签名要求稳定存储：追加式串竞技场（deque 元素地址稳定）+ 互斥，
    // 每次调用独立存储、不复用缓冲（A2 挂账 #3 精神）；smoke 专用路径，每进程调用
    // 个位数，内存有界
    static std::mutex arenaMtx;
    static std::deque<std::string> arena;
    std::lock_guard<std::mutex> g(arenaMtx);
    arena.emplace_back(buf);
    return arena.back().c_str();
}

} // namespace pp
