// test_tunnelruntime.cpp — TunnelRuntime 编排状态机 host 单测（A3 计划 Task 8）
//
// host 无 TUN/无网络许可：
//   - TUN fd 用 socketpair(AF_UNIX, SOCK_STREAM) 模拟（A2 test_dataplane_udp 同款）；
//   - netconf/事件无法等 CoreBridge 真实回调（无网络许可、时延不可控）——经
//     PP_TUNNELRUNTIME_TEST_HOOKS 注入通道 testFeedNetConf/testFeedEvent 直喂，
//     通道与 CoreBridge onNetConf/onEvent 汇入同一条事件队列，驱动同一套状态机；
//   - join/leave/orbit/deorbit 走真实 CoreBridge（host 可跑通），经 testOnCoreAction
//     记录钩子锁定装配行为（CoreBridge 无拦截点，C++ 无法伪造 netconf 回调）；
//   - UDP 端口全部经 testUdpPort 注入空闲回环端口——host 可能装着 ZeroTier One
//     占用 9994，测试绝不抢真实端口。
#include "runtime/TunnelRuntime.h"

#include <gtest/gtest.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

namespace {

namespace fs = std::filesystem;

// ---- 通用工具（A2 测试同款） ----

std::string makeTempDir(const char *tag)
{
    const fs::path base = fs::temp_directory_path() /
                          ("pp-t8-" + std::string(tag) + "-" + std::to_string(::getpid()));
    fs::create_directories(base);
    return base.string();
}

// RAII 临时目录
struct TempDir {
    std::string path;
    explicit TempDir(const char *tag) : path(makeTempDir(tag)) {}
    ~TempDir()
    {
        std::error_code ec;
        if (fs::exists(path))
            fs::remove_all(path, ec);
    }
    TempDir(const TempDir &) = delete;
    TempDir &operator=(const TempDir &) = delete;
};

// socketpair 模拟 TUN：first = swap 给 runtime（Dataplane 读端），second = 内核端
std::pair<int, int> makeTunPair()
{
    int sv[2] = {-1, -1};
    EXPECT_EQ(::socketpair(AF_UNIX, SOCK_STREAM, 0, sv), 0) << "socketpair 失败";
    return {sv[0], sv[1]};
}

template <typename Pred>
bool waitUntil(Pred pred, int timeoutMs = 3000)
{
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (std::chrono::steady_clock::now() < deadline) {
        if (pred())
            return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return pred();
}

uint16_t freeUdpPort()
{
    const int s = ::socket(AF_INET, SOCK_DGRAM, 0);
    EXPECT_GE(s, 0);
    sockaddr_in a {};
    a.sin_family = AF_INET;
    a.sin_port = 0;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    EXPECT_EQ(::bind(s, reinterpret_cast<const sockaddr *>(&a), sizeof(a)), 0);
    socklen_t len = sizeof(a);
    EXPECT_EQ(::getsockname(s, reinterpret_cast<sockaddr *>(&a), &len), 0);
    ::close(s);
    return ntohs(a.sin_port);
}

// ---- 构造器 ----

pp::NetConf mkConf(uint64_t nwid, const std::vector<std::string> &v4,
                   const std::vector<std::string> &v6,
                   const std::vector<std::string> &routes = {}, int mtu = 2800, int status = 1)
{
    pp::NetConf c;
    c.nwid = nwid;
    c.name = "net-" + std::to_string(nwid);
    c.status = status;
    c.type = "PRIVATE";
    c.mac = 0x9a1b2c3d4e5fULL;
    c.mtu = mtu;
    c.broadcastEnabled = true;
    for (const std::string &a : v4)
        c.assignedAddrs.push_back(a);
    for (const std::string &a : v6)
        c.assignedAddrs.push_back(a);
    c.routes = routes;
    return c;
}

pp::TunnelConfig mkCfg(const std::string &root, const std::vector<uint64_t> &nwids,
                       const std::vector<std::pair<uint64_t, uint64_t>> &moons = {},
                       bool disableIpv6 = false)
{
    pp::TunnelConfig cfg;
    cfg.dataStoreRoot = root + "/ds";
    cfg.planetDir = root + "/pd";
    cfg.planetFile = "";
    cfg.identityPerPlanet = false;
    cfg.disableIpv6 = disableIpv6;
    for (uint64_t n : nwids)
        cfg.networks.push_back({n, false});
    for (const auto &m : moons)
        cfg.moons.push_back({m.first, m.second});
    return cfg;
}

// ---- Hooks 捕获（回调在 runtime 内部线程触发，加锁存取） ----

struct CoreAction {
    std::string act;
    uint64_t a = 0;
    uint64_t b = 0;
};

struct Capture {
    std::mutex lock;
    std::vector<pp::EstablishRequest> establishes;
    int teardowns = 0;
    int stateChanges = 0;
    std::vector<int> protectFds;
    std::vector<CoreAction> actions;

    size_t establishCount()
    {
        std::lock_guard<std::mutex> lk(lock);
        return establishes.size();
    }
    pp::EstablishRequest establishAt(size_t i)
    {
        std::lock_guard<std::mutex> lk(lock);
        return establishes.at(i);
    }
    int teardownCount()
    {
        std::lock_guard<std::mutex> lk(lock);
        return teardowns;
    }
    std::vector<CoreAction> actionSnapshot()
    {
        std::lock_guard<std::mutex> lk(lock);
        return actions;
    }
    void clearActions()
    {
        std::lock_guard<std::mutex> lk(lock);
        actions.clear();
    }
    bool hasAction(const std::string &act, uint64_t a, uint64_t b = 0)
    {
        std::lock_guard<std::mutex> lk(lock);
        for (const CoreAction &c : actions)
            if (c.act == act && c.a == a && (b == 0 || c.b == b))
                return true;
        return false;
    }
};

// 装配好的 runtime：hooks 全捕获、UDP 注入空闲端口、动作记录钩子就绪。
// 声明序 cap 在前 rt 在后——rt 析构（stop 兜底）时 cap 仍存活。
struct Rig {
    TempDir dir;
    Capture cap;
    pp::TunnelRuntime rt;

    explicit Rig(const char *tag) : dir(tag) { wire(); }

    Rig(const std::vector<uint64_t> &nwids, const char *tag = "rt")
        : dir(tag), cap(), rt()
    {
        wire();
        start(mkCfg(dir.path, nwids));
    }

    void wire()
    {
        rt.hooks.onEstablish = [this](const pp::EstablishRequest &req) {
            std::lock_guard<std::mutex> lk(cap.lock);
            cap.establishes.push_back(req);
        };
        rt.hooks.onTeardown = [this]() {
            std::lock_guard<std::mutex> lk(cap.lock);
            ++cap.teardowns;
        };
        rt.hooks.onStateChanged = [this]() {
            std::lock_guard<std::mutex> lk(cap.lock);
            ++cap.stateChanges;
        };
        rt.hooks.protect = [this](int fd) {
            std::lock_guard<std::mutex> lk(cap.lock);
            cap.protectFds.push_back(fd);
            return true;
        };
#ifdef PP_TUNNELRUNTIME_TEST_HOOKS
        rt.testUdpPort = static_cast<int>(freeUdpPort()); // 不抢真实 9994
        rt.testOnCoreAction = [this](const char *act, uint64_t a, uint64_t b) {
            std::lock_guard<std::mutex> lk(cap.lock);
            cap.actions.push_back({act, a, b});
        };
#endif
    }

    bool start(const pp::TunnelConfig &cfg) { return rt.start(cfg); }
    void feed(uint64_t nwid, const pp::NetConf &conf) { rt.testFeedNetConf(nwid, conf); }
    void feedEvent(int e) { rt.testFeedEvent(e); }
};

// ---- 极简 JSON 解析器（仅测试用；对象/数组/字符串/数/布尔/null） ----

struct JValue {
    enum Type { Null, Bool, Num, Str, Arr, Obj } type = Null;
    bool b = false;
    double num = 0;
    std::string str;
    std::vector<JValue> arr;
    std::map<std::string, JValue> obj;

    const JValue *at(const std::string &key) const
    {
        auto it = obj.find(key);
        return it == obj.end() ? nullptr : &it->second;
    }
};

class JParser {
public:
    static bool parse(const std::string &text, JValue &out)
    {
        size_t i = 0;
        return value(text, i, out) && skipWs(text, i) && i == text.size();
    }

private:
    static bool skipWs(const std::string &t, size_t &i)
    {
        while (i < t.size() && (t[i] == ' ' || t[i] == '\t' || t[i] == '\n' || t[i] == '\r'))
            ++i;
        return true;
    }
    static bool value(const std::string &t, size_t &i, JValue &out)
    {
        skipWs(t, i);
        if (i >= t.size())
            return false;
        const char c = t[i];
        if (c == '{') return object(t, i, out);
        if (c == '[') return array(t, i, out);
        if (c == '"') { out.type = JValue::Str; return string(t, i, out.str); }
        if (c == 't') { return lit(t, i, "true", out, true); }
        if (c == 'f') { return lit(t, i, "false", out, false); }
        if (c == 'n') { return lit(t, i, "null", out, false); }
        return number(t, i, out);
    }
    static bool lit(const std::string &t, size_t &i, const char *word, JValue &out, bool val)
    {
        const size_t n = std::strlen(word);
        if (t.compare(i, n, word) != 0)
            return false;
        i += n;
        out.type = val || out.type == JValue::Bool ? JValue::Bool : JValue::Null;
        if (word[0] == 't' || word[0] == 'f')
            out.b = val;
        return true;
    }
    static bool number(const std::string &t, size_t &i, JValue &out)
    {
        size_t j = i;
        if (j < t.size() && (t[j] == '-' || t[j] == '+'))
            ++j;
        bool any = false;
        while (j < t.size() && ((t[j] >= '0' && t[j] <= '9') || t[j] == '.' || t[j] == 'e' ||
                                t[j] == 'E' || t[j] == '-' || t[j] == '+')) {
            ++j;
            any = true;
        }
        if (!any)
            return false;
        out.type = JValue::Num;
        out.num = std::atof(t.substr(i, j - i).c_str());
        i = j;
        return true;
    }
    static bool string(const std::string &t, size_t &i, std::string &out)
    {
        if (i >= t.size() || t[i] != '"')
            return false;
        ++i;
        out.clear();
        while (i < t.size()) {
            const char c = t[i++];
            if (c == '"')
                return true;
            if (c == '\\' && i < t.size()) {
                const char e = t[i++];
                switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'u': {
                    if (i + 4 > t.size()) return false;
                    int code = 0;
                    for (int k = 0; k < 4; ++k) {
                        const char h = t[i++];
                        code = code * 16 + (std::isdigit(unsigned(h))
                                                ? h - '0'
                                                : std::tolower(unsigned(h)) - 'a' + 10);
                    }
                    if (code < 0x80) {
                        out += char(code);
                    } else if (code < 0x800) {
                        out += char(0xc0 | (code >> 6));
                        out += char(0x80 | (code & 0x3f));
                    } else {
                        out += char(0xe0 | (code >> 12));
                        out += char(0x80 | ((code >> 6) & 0x3f));
                        out += char(0x80 | (code & 0x3f));
                    }
                    break;
                }
                default: return false;
                }
                continue;
            }
            out += c;
        }
        return false;
    }
    static bool object(const std::string &t, size_t &i, JValue &out)
    {
        ++i; // '{'
        out.type = JValue::Obj;
        skipWs(t, i);
        if (i < t.size() && t[i] == '}') {
            ++i;
            return true;
        }
        for (;;) {
            skipWs(t, i);
            std::string key;
            if (!string(t, i, key))
                return false;
            skipWs(t, i);
            if (i >= t.size() || t[i] != ':')
                return false;
            ++i;
            JValue v;
            if (!value(t, i, v))
                return false;
            out.obj[key] = std::move(v);
            skipWs(t, i);
            if (i < t.size() && t[i] == ',') {
                ++i;
                continue;
            }
            if (i < t.size() && t[i] == '}') {
                ++i;
                return true;
            }
            return false;
        }
    }
    static bool array(const std::string &t, size_t &i, JValue &out)
    {
        ++i; // '['
        out.type = JValue::Arr;
        skipWs(t, i);
        if (i < t.size() && t[i] == ']') {
            ++i;
            return true;
        }
        for (;;) {
            JValue v;
            if (!value(t, i, v))
                return false;
            out.arr.push_back(std::move(v));
            skipWs(t, i);
            if (i < t.size() && t[i] == ',') {
                ++i;
                continue;
            }
            if (i < t.size() && t[i] == ']') {
                ++i;
                return true;
            }
            return false;
        }
    }
};

bool parseJson(const std::string &text, JValue &out) { return JParser::parse(text, out); }

std::string hex16(uint64_t v)
{
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%016llx", static_cast<unsigned long long>(v));
    return buf;
}

bool looksLikeTimestamp(const std::string &line)
{
    // "HH:MM:SS.mmm " 前缀
    if (line.size() < 13)
        return false;
    for (size_t i = 0; i < 12; ++i) {
        const char c = line[i];
        if (i == 2 || i == 5) {
            if (c != ':') return false;
        } else if (i == 8) {
            if (c != '.') return false;
        } else if (!std::isdigit(unsigned(c))) {
            return false;
        }
    }
    return line[12] == ' ';
}

std::vector<std::string> splitLines(const std::string &s)
{
    std::vector<std::string> out;
    std::string cur;
    for (const char c : s) {
        if (c == '\n') {
            out.push_back(cur);
            cur.clear();
        } else {
            cur += c;
        }
    }
    if (!cur.empty())
        out.push_back(cur);
    return out;
}

constexpr uint64_t kNetA = 0x1111111111ULL;
constexpr uint64_t kNetB = 0x2222222222ULL;
constexpr uint64_t kMoon1 = 0x2aULL;
constexpr uint64_t kMoon2 = 0x2bULL;

} // namespace

// ① start 装配顺序：core→udp→Starting；protect 注入 UdpCom（fake protect 记录 fd）
TEST(TunnelRuntime, StartSequence_Starting)
{
    Rig r("seq");
    const pp::TunnelConfig cfg = mkCfg(r.dir.path, {});
    ASSERT_TRUE(r.rt.start(cfg));

    const pp::RuntimeState st = r.rt.state();
    EXPECT_EQ(st.kind, "starting");
    EXPECT_TRUE(r.rt.isAlive());
    EXPECT_TRUE(st.reason.empty());
    EXPECT_FALSE(st.online); // NodeRuntime.start：在线位待 ONLINE 事件
    // nodeId 十位小写 hex（NodeRuntime "%010x" 直译）
    ASSERT_EQ(st.nodeId.size(), 10u);
    for (const char c : st.nodeId)
        EXPECT_TRUE(std::isdigit(unsigned(c)) || (c >= 'a' && c <= 'f')) << st.nodeId;
    // 核心版本随启动灌入（与 CoreBridge::version 同源）
    EXPECT_EQ(st.coreVersion, std::string(pp::coreVersion()));
    // protect 钩子注入 UdpCom（bind 后回调，记录 fd）
    ASSERT_TRUE(waitUntil([&] {
        std::lock_guard<std::mutex> lk(r.cap.lock);
        return !r.cap.protectFds.empty();
    }));
    {
        std::lock_guard<std::mutex> lk(r.cap.lock);
        EXPECT_GE(r.cap.protectFds.front(), 0);
    }

    // 纪律：cap.lock 只护短促快照读写——runtime 的 worker/回调线程会触发 hooks 抢
    // cap.lock，持它跨入 rt.start/stop 等会 join worker 或触发回调的调用即互等死锁。
    // 幂等：已启动再次 start 返回 false（提前返回，不触发任何 hook）
    EXPECT_FALSE(r.rt.start(cfg));

    r.rt.stop();
    EXPECT_EQ(r.rt.state().kind, "stopped");
    EXPECT_FALSE(r.rt.isAlive());
    // 停机后 nodeId 清空、coreVersion 留存（TunnelStateBus 停机不清语义）
    EXPECT_TRUE(r.rt.state().nodeId.empty());
    EXPECT_EQ(r.rt.state().coreVersion, std::string(pp::coreVersion()));
}

// ② 首份 netconf → 聚合 → onEstablish（v4Addrs 非空、幂等签名：同 netconf 二次投递不再发）
TEST(TunnelRuntime, FirstNetConf_EstablishOnce)
{
    Rig r("establish");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA})));

    const pp::NetConf conf = mkConf(kNetA, {"10.0.0.5/24"}, {"fdaa::5/64"}, {"10.0.0.0/24"});
    r.feed(kNetA, conf);

    ASSERT_TRUE(waitUntil([&] { return r.cap.establishCount() == 1; }));
    const pp::EstablishRequest req = r.cap.establishAt(0);
    EXPECT_EQ(req.v4Addrs, std::vector<std::string>{"10.0.0.5/24"});
    EXPECT_EQ(req.v6Addrs, std::vector<std::string>{"fdaa::5/64"});
    // 直连网段 + managed 路由去重后都含 10.0.0.0/24
    EXPECT_NE(std::find(req.routes4.begin(), req.routes4.end(), "10.0.0.0/24"), req.routes4.end());
    EXPECT_EQ(req.mtu, 2800);
    EXPECT_TRUE(req.dns.empty()); // A3 TunnelConfig 无每网络 DnsMode（契约缺口，快照恒空）

    // swapFd 成功 → Running
    auto tun = makeTunPair();
    ASSERT_TRUE(r.rt.swapFd(tun.first));
    EXPECT_EQ(r.rt.state().kind, "running");

    // 状态镜像：status 原始码 + 配置快照
    const pp::RuntimeState st = r.rt.state();
    ASSERT_NE(st.networkStatuses.find(kNetA), st.networkStatuses.end());
    EXPECT_EQ(st.networkStatuses.at(kNetA), 1);
    ASSERT_NE(st.networkConfigs.find(kNetA), st.networkConfigs.end());
    EXPECT_EQ(st.networkConfigs.at(kNetA).name, conf.name);
    EXPECT_EQ(st.networkConfigs.at(kNetA).assignedAddrs, conf.assignedAddrs);

    // 幂等签名闸门：同 netconf 二次投递不再 establish
    r.feed(kNetA, conf);
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    EXPECT_EQ(r.cap.establishCount(), 1u);
}

// ③ swapFd(-1 拒绝) → 保持 Starting；swapFd(fd) → Running；换代；停机拒收
TEST(TunnelRuntime, SwapFd_Gating)
{
    Rig r("swapfd");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA})));
    r.feed(kNetA, mkConf(kNetA, {"10.0.0.5/24"}, {}, {}));
    ASSERT_TRUE(waitUntil([&] { return r.cap.establishCount() == 1; }));

    // 非法 fd 拒绝且状态不动（Android 语义：保持 Starting 等下次 netconf，不 Failed）
    EXPECT_FALSE(r.rt.swapFd(-1));
    EXPECT_EQ(r.rt.state().kind, "starting");

    // 未启动的实例不接管 fd（调用方持有——fd 仍可关闭）
    {
        pp::TunnelRuntime fresh;
        auto p = makeTunPair();
        EXPECT_FALSE(fresh.swapFd(p.first));
        EXPECT_GE(::fcntl(p.first, F_GETFL), 0); // fd 仍开放：runtime 未接管未误关
        EXPECT_EQ(::close(p.first), 0);
        EXPECT_EQ(::close(p.second), 0);
    }

    // swapFd 成功 → Running
    auto tun = makeTunPair();
    ASSERT_TRUE(r.rt.swapFd(tun.first));
    EXPECT_EQ(r.rt.state().kind, "running");

    // 换代：新 fd swap 成功，旧 fd 被 runtime 关闭（内核端读到 EOF）
    auto tun2 = makeTunPair();
    ASSERT_TRUE(r.rt.swapFd(tun2.first));
    EXPECT_EQ(r.rt.state().kind, "running");
    char buf[16];
    EXPECT_EQ(::read(tun.second, buf, sizeof(buf)), 0); // 旧 fd 关闭 → EOF

    // 停机后迟到 swap 被闩锁拒绝（Dataplane 语义，A2 已锁；此处锁 runtime 转发）
    r.rt.stop();
    auto tun3 = makeTunPair();
    EXPECT_FALSE(r.rt.swapFd(tun3.first));
    // 闩锁拒绝路径已由 Dataplane 关闭 fd（A2 语义防泄漏）——再 close 报 EBADF
    EXPECT_EQ(::close(tun3.first), -1);
    EXPECT_EQ(errno, EBADF);
    EXPECT_EQ(::close(tun3.second), 0);
}

// ④ applyConfig 增量：加网络 → join；删网络 → leave；moon 增删 → orbit/deorbit
TEST(TunnelRuntime, ApplyConfig_Incremental)
{
    Rig r("applycfg");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA}, {{kMoon1, 0x7bULL}})));
    // 初始装配已 join A / orbit M1
    EXPECT_TRUE(r.cap.hasAction("join", kNetA));
    EXPECT_TRUE(r.cap.hasAction("orbit", kMoon1, 0x7bULL));
    r.cap.clearActions();

    // 加网络 B（M1 保留）
    r.rt.applyConfig(mkCfg(r.dir.path, {kNetA, kNetB}, {{kMoon1, 0x7bULL}}));
    EXPECT_TRUE(r.cap.hasAction("join", kNetB));
    EXPECT_FALSE(r.cap.hasAction("leave", kNetB));
    EXPECT_FALSE(r.cap.hasAction("join", kNetA)); // 已 join 不重复
    r.cap.clearActions();

    // 删网络 B
    r.rt.applyConfig(mkCfg(r.dir.path, {kNetA}, {{kMoon1, 0x7bULL}}));
    EXPECT_TRUE(r.cap.hasAction("leave", kNetB));
    EXPECT_FALSE(r.cap.hasAction("join", kNetB));
    r.cap.clearActions();

    // moon 换血：M1 移除 → deorbit；M2 新增 → orbit（brief 授权扩展，Kotlin 无 deorbit）
    r.rt.applyConfig(mkCfg(r.dir.path, {kNetA}, {{kMoon2, 0x7cULL}}));
    EXPECT_TRUE(r.cap.hasAction("orbit", kMoon2, 0x7cULL));
    EXPECT_TRUE(r.cap.hasAction("deorbit", kMoon1));
    EXPECT_FALSE(r.cap.hasAction("deorbit", kMoon2));
}

// ⑤ 冲突网络排除：两网络同地址段 → 后者入 conflicts 表、不进聚合
TEST(TunnelRuntime, Conflicts_Excluded)
{
    Rig r("conflict");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA, kNetB})));
    r.feed(kNetA, mkConf(kNetA, {"10.0.0.5/24"}, {}, {}));
    ASSERT_TRUE(waitUntil([&] { return r.cap.establishCount() == 1; }));
    auto tun = makeTunPair();
    ASSERT_TRUE(r.rt.swapFd(tun.first));
    ASSERT_EQ(r.rt.state().kind, "running");

    // 同网段不同 IP → subnet 冲突（先到者 A 胜，B 让路）
    r.feed(kNetB, mkConf(kNetB, {"10.0.0.9/24"}, {}, {}));
    ASSERT_TRUE(waitUntil([&] {
        const pp::RuntimeState st = r.rt.state();
        return st.networkConflicts.count(kNetB) != 0;
    }));
    EXPECT_EQ(r.rt.state().networkConflicts.at(kNetB), "subnet");
    // 冲突网络不进聚合：签名未变 → 不再 establish
    EXPECT_EQ(r.cap.establishCount(), 1u);
    EXPECT_EQ(r.rt.state().kind, "running"); // 不 Failed
    // 快照仍登记（保留 join 仅展示状态）
    EXPECT_NE(r.rt.state().networkConfigs.find(kNetB), r.rt.state().networkConfigs.end());

    // 同地址 → address 冲突（地址冲突优先于网段冲突）
    r.feed(kNetB, mkConf(kNetB, {"10.0.0.5/24"}, {}, {}));
    ASSERT_TRUE(waitUntil([&] {
        const pp::RuntimeState st = r.rt.state();
        return st.networkConflicts.count(kNetB) != 0 && st.networkConflicts.at(kNetB) == "address";
    }));
    EXPECT_EQ(r.cap.establishCount(), 1u);
}

// ⑥ 全部网络失效 → onTeardown + 不置 Failed；恢复 → 重新 establish
TEST(TunnelRuntime, AllNetworksDown_TeardownNotFailed)
{
    Rig r("teardown");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA})));
    r.feed(kNetA, mkConf(kNetA, {"10.0.0.5/24"}, {}, {}));
    ASSERT_TRUE(waitUntil([&] { return r.cap.establishCount() == 1; }));
    auto tun = makeTunPair();
    ASSERT_TRUE(r.rt.swapFd(tun.first));

    // 无地址的完整配置 = 被控制器剔除：清快照 → 全网络失效 → 拆 TUN
    r.feed(kNetA, mkConf(kNetA, {}, {}, {}));
    ASSERT_TRUE(waitUntil([&] { return r.cap.teardownCount() == 1; }));
    EXPECT_NE(r.rt.state().kind, "failed"); // 拆 TUN 不置 Failed
    EXPECT_EQ(r.rt.state().kind, "running"); // 宏观态不动（服务仍活，仅数据面无网络）
    EXPECT_TRUE(r.rt.isAlive());
    EXPECT_TRUE(r.rt.state().networkConfigs.empty()); // 快照已清

    // 恢复：签名已清 → 重新 establish
    r.feed(kNetA, mkConf(kNetA, {"10.0.0.5/24"}, {}, {}));
    ASSERT_TRUE(waitUntil([&] { return r.cap.establishCount() == 2; }));
    auto tun2 = makeTunPair();
    ASSERT_TRUE(r.rt.swapFd(tun2.first));
    EXPECT_EQ(r.rt.state().kind, "running");
    EXPECT_EQ(r.cap.teardownCount(), 1);
}

// ⑦ UdpCom bind 失败注入（端口冲突）→ Failed(udpBindFailed, recoverable)
TEST(TunnelRuntime, UdpBindFailed_Reason)
{
    const uint16_t busy = freeUdpPort();
    const int holder = ::socket(AF_INET, SOCK_DGRAM, 0);
    ASSERT_GE(holder, 0);
    sockaddr_in a {};
    a.sin_family = AF_INET;
    a.sin_port = htons(busy);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    ASSERT_EQ(::bind(holder, reinterpret_cast<const sockaddr *>(&a), sizeof(a)), 0);

    Rig r("udpbind");
    pp::TunnelConfig cfg = mkCfg(r.dir.path, {kNetA});
    r.rt.testUdpPort = static_cast<int>(busy);
    EXPECT_FALSE(r.rt.start(cfg)); // 装配失败：未发起本次启动
    EXPECT_EQ(r.rt.state().kind, "failed");
    EXPECT_EQ(r.rt.state().reason, "udpBindFailed");
    EXPECT_TRUE(r.rt.state().recoverable);
    EXPECT_FALSE(r.rt.isAlive());

    // 释放端口后可完整重新装配（recoverable 语义）
    EXPECT_EQ(::close(holder), 0);
    ASSERT_TRUE(r.rt.start(cfg));
    EXPECT_EQ(r.rt.state().kind, "starting");
    EXPECT_FALSE(r.rt.state().nodeId.empty());
    r.rt.stop();
}

// ⑧ snapshotJson 字段完整性（TunnelContract 契约逐字段）
TEST(TunnelRuntime, SnapshotJsonContract)
{
    Rig r("snapshot");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA, kNetB})));
    r.feed(kNetA, mkConf(kNetA, {"10.0.0.5/24"}, {"fdaa::5/64"}, {"10.0.0.0/24"}, 1400));
    ASSERT_TRUE(waitUntil([&] { return r.cap.establishCount() >= 1; }));
    auto tun = makeTunPair();
    ASSERT_TRUE(r.rt.swapFd(tun.first));
    r.feed(kNetB, mkConf(kNetB, {"10.0.0.9/24"}, {}, {})); // subnet 冲突
    ASSERT_TRUE(waitUntil([&] {
        const pp::RuntimeState st = r.rt.state();
        return st.networkConflicts.count(kNetB) != 0;
    }));

    JValue root;
    ASSERT_TRUE(parseJson(r.rt.snapshotJson(), root)) << r.rt.snapshotJson();

    // tunnelState {kind, reason?}
    const JValue *st = root.at("tunnelState");
    ASSERT_NE(st, nullptr);
    ASSERT_NE(st->at("kind"), nullptr);
    EXPECT_EQ(st->at("kind")->str, "running");
    EXPECT_EQ(st->at("reason"), nullptr); // running 无 reason
    EXPECT_EQ(st->at("recoverable"), nullptr);

    // nodeStatus {nodeId, online, coreVersion}
    const JValue *ns = root.at("nodeStatus");
    ASSERT_NE(ns, nullptr);
    EXPECT_EQ(ns->at("nodeId")->str, r.rt.state().nodeId);
    EXPECT_FALSE(ns->at("online")->b);
    EXPECT_EQ(ns->at("coreVersion")->str, std::string(pp::coreVersion()));

    // 顶层 coreVersion（停机不清的缓存字段）
    ASSERT_NE(root.at("coreVersion"), nullptr);
    EXPECT_EQ(root.at("coreVersion")->str, std::string(pp::coreVersion()));

    // networkStatuses：键 16 位小写 hex → status 原始码
    const JValue *statuses = root.at("networkStatuses");
    ASSERT_NE(statuses, nullptr);
    ASSERT_NE(statuses->at(hex16(kNetA)), nullptr);
    EXPECT_EQ(statuses->at(hex16(kNetA))->num, 1);
    ASSERT_NE(statuses->at(hex16(kNetB)), nullptr);
    EXPECT_EQ(statuses->at(hex16(kNetB))->num, 1);

    // networkConflicts：键 16 位 hex → "subnet"
    const JValue *conflicts = root.at("networkConflicts");
    ASSERT_NE(conflicts, nullptr);
    ASSERT_NE(conflicts->at(hex16(kNetB)), nullptr);
    EXPECT_EQ(conflicts->at(hex16(kNetB))->str, "subnet");
    EXPECT_EQ(conflicts->at(hex16(kNetA)), nullptr);

    // networkConfigs：数组（非对象），元素字段齐全
    const JValue *configs = root.at("networkConfigs");
    ASSERT_NE(configs, nullptr);
    ASSERT_EQ(configs->type, JValue::Arr);
    ASSERT_EQ(configs->arr.size(), 2u);
    const JValue *ca = configs->arr[0].at("nwid")->str == hex16(kNetA) ? &configs->arr[0] : &configs->arr[1];
    const JValue *cb = ca == &configs->arr[0] ? &configs->arr[1] : &configs->arr[0];
    EXPECT_EQ(ca->at("nwid")->str, hex16(kNetA));
    EXPECT_EQ(ca->at("status")->num, 1);
    EXPECT_EQ(ca->at("type")->str, "PRIVATE");
    EXPECT_EQ(ca->at("mtu")->num, 1400);
    EXPECT_TRUE(ca->at("broadcastEnabled")->b);
    EXPECT_FALSE(ca->at("bridge")->b);
    EXPECT_FALSE(ca->at("dhcp")->b);
    ASSERT_EQ(ca->at("assignedAddrs")->type, JValue::Arr);
    EXPECT_EQ(ca->at("assignedAddrs")->arr.size(), 2u); // v4 + v6
    ASSERT_EQ(ca->at("routes")->type, JValue::Arr);
    ASSERT_EQ(ca->at("dns")->type, JValue::Arr);
    EXPECT_EQ(cb->at("nwid")->str, hex16(kNetB));

    // peers：paths 恒空数组（A2 PeerInfo 无物理路径表，A6 挂账）
    const JValue *peers = root.at("peers");
    ASSERT_NE(peers, nullptr);
    ASSERT_EQ(peers->type, JValue::Arr);
    for (const JValue &p : peers->arr) {
        ASSERT_NE(p.at("address"), nullptr);
        ASSERT_NE(p.at("version"), nullptr);
        ASSERT_NE(p.at("latency"), nullptr);
        ASSERT_NE(p.at("role"), nullptr);
        ASSERT_NE(p.at("paths"), nullptr);
        EXPECT_EQ(p.at("paths")->type, JValue::Arr);
        EXPECT_TRUE(p.at("paths")->arr.empty());
    }

    // applyTrace / eventLog
    const JValue *trace = root.at("applyTrace");
    ASSERT_NE(trace, nullptr);
    EXPECT_NE(trace->str.find("items=2"), std::string::npos);
    const JValue *logv = root.at("eventLog");
    ASSERT_NE(logv, nullptr);
    const std::vector<std::string> lines = splitLines(logv->str);
    ASSERT_FALSE(lines.empty());
    bool sawCfgLog = false;
    for (const std::string &l : lines)
        if (l.find("cfg ") != std::string::npos)
            sawCfgLog = true;
    EXPECT_TRUE(sawCfgLog);
    EXPECT_TRUE(looksLikeTimestamp(lines.back()));

    // pathSatisfied / writtenAt 不在 Task 8 序列化内（写方 ExtStateBus 注入——计划裁决）
    EXPECT_EQ(root.at("pathSatisfied"), nullptr);
    EXPECT_EQ(root.at("writtenAt"), nullptr);

    r.rt.stop();
    // 停机快照：stopped + nodeStatus null + 契约字段仍在
    JValue stopped;
    ASSERT_TRUE(parseJson(r.rt.snapshotJson(), stopped));
    EXPECT_EQ(stopped.at("tunnelState")->at("kind")->str, "stopped");
    ASSERT_EQ(stopped.at("nodeStatus")->type, JValue::Null);
    EXPECT_EQ(stopped.at("networkStatuses")->type, JValue::Obj);
    EXPECT_TRUE(stopped.at("networkStatuses")->obj.empty());
}

// ⑨ disableIpv6 全局位：v6 地址不进聚合（路由过滤由壳层二次把关——Task 10 契约）
TEST(TunnelRuntime, DisableIpv6_FiltersV6Addresses)
{
    Rig r("v6off");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA}, {}, true)));
    r.feed(kNetA, mkConf(kNetA, {"10.0.0.5/24"}, {"fdaa::5/64"}, {}));
    ASSERT_TRUE(waitUntil([&] { return r.cap.establishCount() == 1; }));
    const pp::EstablishRequest req = r.cap.establishAt(0);
    EXPECT_EQ(req.v4Addrs, std::vector<std::string>{"10.0.0.5/24"});
    EXPECT_TRUE(req.v6Addrs.empty());
    // 快照仍保留 v6（仅数据面聚合过滤，展示层不受影响）
    EXPECT_EQ(r.rt.state().networkConfigs.at(kNetA).assignedAddrs.size(), 2u);
}

// ⑩ 多网络：默认路由不生效 + MTU 取最小（min(28000, 声明值)）
TEST(TunnelRuntime, MultiNetwork_NoDefaultRouteAndMtuMin)
{
    Rig r("multi");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA, kNetB})));
    r.feed(kNetA, mkConf(kNetA, {"10.0.0.5/24"}, {}, {"0.0.0.0/0"}, 2800));
    r.feed(kNetB, mkConf(kNetB, {"10.0.1.5/24"}, {}, {"0.0.0.0/0"}, 1400));

    // 先到单网络聚合可能先行发出——等同时含两网络地址的请求
    ASSERT_TRUE(waitUntil([&] {
        std::lock_guard<std::mutex> lk(r.cap.lock);
        for (const pp::EstablishRequest &req : r.cap.establishes) {
            if (req.v4Addrs.size() == 2)
                return true;
        }
        return false;
    }));
    const pp::EstablishRequest req = [&] {
        std::lock_guard<std::mutex> lk(r.cap.lock);
        for (const pp::EstablishRequest &q : r.cap.establishes)
            if (q.v4Addrs.size() == 2)
                return q;
        return pp::EstablishRequest{};
    }();
    // 多网络 routeVia 强制 false：默认路由不进 TUN（仅直连网段）
    EXPECT_EQ(req.routes4, std::vector<std::string>({"10.0.0.0/24", "10.0.1.0/24"}));
    EXPECT_EQ(std::find(req.routes4.begin(), req.routes4.end(), "0.0.0.0/0"), req.routes4.end());
    EXPECT_EQ(req.mtu, 1400); // 声明值取最小
}

// ⑪ 单网络 routeVia：默认路由展开纳入（挖除物理网段后仍至少一项）+ 路由去重
TEST(TunnelRuntime, SingleNetwork_RouteViaExpandsDefault)
{
    Rig r("routevia");
    pp::TunnelConfig cfg = mkCfg(r.dir.path, {kNetA});
    cfg.networks[0].routeViaZeroTier = true;
    ASSERT_TRUE(r.rt.start(cfg));
    r.feed(kNetA, mkConf(kNetA, {"10.0.0.5/24"}, {}, {"0.0.0.0/0", "10.5.0.0/16"}));
    ASSERT_TRUE(waitUntil([&] { return r.cap.establishCount() == 1; }));
    const pp::EstablishRequest req = r.cap.establishAt(0);
    EXPECT_NE(std::find(req.routes4.begin(), req.routes4.end(), "10.0.0.0/24"), req.routes4.end());
    EXPECT_NE(std::find(req.routes4.begin(), req.routes4.end(), "10.5.0.0/16"), req.routes4.end());
    // 默认路由展开（挖除物理 on-link 网段）至少产出 1 项 → 总数 ≥ 3
    EXPECT_GE(req.routes4.size(), 3u);
    // 去重：无重复项
    const std::set<std::string> uniq(req.routes4.begin(), req.routes4.end());
    EXPECT_EQ(uniq.size(), req.routes4.size());
}

// ⑫ 事件日志：时间戳 HH:MM:SS.mmm + takeLast(40)
TEST(TunnelRuntime, EventLog_Rolling40)
{
    Rig r("log40");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA})));
    const pp::NetConf conf = mkConf(kNetA, {"10.0.0.5/24"}, {}, {});
    for (int i = 0; i < 50; ++i)
        r.feed(kNetA, conf); // 每次 cfg 回调都产生一条日志
    ASSERT_TRUE(waitUntil([&] { return r.rt.state().eventLog.size() == 40u; }));
    EXPECT_EQ(r.rt.state().eventLog.size(), 40u);
    // 日志混有启动/join/apply 行（TunnelStateBus 同源语义），全为 cfg 不成立——锁死的是：
    // ① 全行带时间戳；② 50 条 cfg 入 40 窗口 → 窗口首行必为 cfg（早期非 cfg 行已被
    // 滚出）；③ cfg 行占绝对多数
    const std::vector<std::string> logLines = r.rt.state().eventLog;
    size_t cfgLines = 0;
    for (const std::string &line : logLines) {
        EXPECT_TRUE(looksLikeTimestamp(line)) << line;
        if (line.find("cfg ") != std::string::npos)
            ++cfgLines;
    }
    EXPECT_NE(logLines.front().find("cfg "), std::string::npos) << logLines.front();
    EXPECT_GE(cfgLines, 35u);
}

// ⑬ 身份冲突（EVENT_FATAL_ERROR_IDENTITY_COLLISION=4）→ Failed 不可恢复
TEST(TunnelRuntime, IdentityCollision_NotRecoverable)
{
    Rig r("collision");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {})));
    r.feedEvent(4); // ZT_EVENT_FATAL_ERROR_IDENTITY_COLLISION
    ASSERT_TRUE(waitUntil([&] { return r.rt.state().kind == "failed"; }));
    EXPECT_EQ(r.rt.state().reason, "identityCollision");
    EXPECT_FALSE(r.rt.state().recoverable);
    EXPECT_FALSE(r.rt.isAlive());
    r.rt.stop(); // Failed 存活态仍可显式停止
    EXPECT_EQ(r.rt.state().kind, "stopped");
}

// ⑭ 驱动循环异常（onEvent ≤-100 = -(ZT_ResultCode)）→ Failed(core_driver:N, recoverable)
TEST(TunnelRuntime, DriverFailure_Reason)
{
    Rig r("driver");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {})));
    r.feedEvent(-102); // -(ZT_RESULT_FATAL_ERROR_INTERNAL)
    ASSERT_TRUE(waitUntil([&] { return r.rt.state().kind == "failed"; }));
    EXPECT_EQ(r.rt.state().reason, "core_driver:102");
    EXPECT_TRUE(r.rt.state().recoverable);
    // 未跑实例 restartCore no-op（不崩、状态不变）
    r.rt.restartCore();
    EXPECT_EQ(r.rt.state().kind, "failed");
}

// ⑮ restartCore：进程内换代（stop+start 保配置；身份复用；重聚合重建 TUN）
TEST(TunnelRuntime, RestartCore_ReEstablish)
{
    Rig r("restart");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA})));
    r.feed(kNetA, mkConf(kNetA, {"10.0.0.5/24"}, {}, {}));
    ASSERT_TRUE(waitUntil([&] { return r.cap.establishCount() == 1; }));
    auto tun = makeTunPair();
    ASSERT_TRUE(r.rt.swapFd(tun.first));
    const std::string nodeIdBefore = r.rt.state().nodeId;

    r.rt.restartCore();
    // 同一 dataStoreRoot：新核心装载同一身份 → nodeId 不变
    EXPECT_EQ(r.rt.state().nodeId, nodeIdBefore);
    EXPECT_TRUE(r.rt.isAlive());
    // 重新 feed netconf → 再次 establish → swap → Running
    r.feed(kNetA, mkConf(kNetA, {"10.0.0.5/24"}, {}, {}));
    ASSERT_TRUE(waitUntil([&] { return r.cap.establishCount() == 2; }));
    auto tun2 = makeTunPair();
    ASSERT_TRUE(r.rt.swapFd(tun2.first));
    EXPECT_EQ(r.rt.state().kind, "running");
    r.rt.stop();
    EXPECT_EQ(r.rt.state().kind, "stopped");
}

// ⑯ stop：终态化 + 幂等 + 快照清空（网络状态/配置/Peer 清空；coreVersion 留存）
TEST(TunnelRuntime, Stop_TerminalAndIdempotent)
{
    Rig r("stop");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA})));
    r.feed(kNetA, mkConf(kNetA, {"10.0.0.5/24"}, {}, {}));
    ASSERT_TRUE(waitUntil([&] { return r.cap.establishCount() == 1; }));

    r.rt.stop();
    EXPECT_EQ(r.rt.state().kind, "stopped");
    EXPECT_FALSE(r.rt.isAlive());
    EXPECT_TRUE(r.rt.state().networkStatuses.empty());
    EXPECT_TRUE(r.rt.state().networkConfigs.empty());
    EXPECT_TRUE(r.rt.state().networkConflicts.empty());
    EXPECT_TRUE(r.rt.state().peers.empty());
    EXPECT_TRUE(r.rt.state().nodeId.empty());
    EXPECT_FALSE(r.rt.state().coreVersion.empty());
    EXPECT_EQ(r.cap.teardownCount(), 0); // 正常停机不走 onTeardown（壳自会 destroy VPN）

    // 幂等：二次 stop 安全
    r.rt.stop();
    EXPECT_EQ(r.rt.state().kind, "stopped");

    // 终态后可重新装配
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA})));
    EXPECT_EQ(r.rt.state().kind, "starting");
    r.rt.stop();
}

// ⑰ F2 回归：Failed 存活态迟到的 pending establish swap 不把 Failed 翻成 running
//（identityCollision 置 Failed 后 pipeline 未拆——Dataplane 未 shutdown，迟到的
// swap 状态盲成功且签名照常提交，但 kind 必须保持 failed 不掩盖失败）
TEST(TunnelRuntime, Failed_LateSwapFdKeepsKind)
{
    Rig r("failedswap");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA})));
    r.feed(kNetA, mkConf(kNetA, {"10.0.0.5/24"}, {}, {}));
    ASSERT_TRUE(waitUntil([&] { return r.cap.establishCount() == 1; }));

    // 失败态（存活）：pipeline 未拆，Dataplane 闩锁未置
    r.feedEvent(4); // ZT_EVENT_FATAL_ERROR_IDENTITY_COLLISION
    ASSERT_TRUE(waitUntil([&] { return r.rt.state().kind == "failed"; }));

    // 迟到的 pending establish swap：swap 本身成功（状态盲），kind 不翻转
    auto tun = makeTunPair();
    EXPECT_TRUE(r.rt.swapFd(tun.first));
    EXPECT_EQ(r.rt.state().kind, "failed");
    EXPECT_EQ(r.rt.state().reason, "identityCollision");
    EXPECT_FALSE(r.rt.state().recoverable);
    EXPECT_FALSE(r.rt.isAlive());

    // fd 已被 Dataplane 接管：停机收口关闭（内核端读到 EOF，无泄漏）
    r.rt.stop();
    EXPECT_EQ(r.rt.state().kind, "stopped");
    char buf[16];
    EXPECT_EQ(::read(tun.second, buf, sizeof(buf)), 0);

    // 停机后（闩锁已置）的迟到 swap：拒绝且 fd 由 Dataplane 关闭（EBADF 防泄漏）
    auto tun2 = makeTunPair();
    EXPECT_FALSE(r.rt.swapFd(tun2.first));
    EXPECT_EQ(::close(tun2.first), -1);
    EXPECT_EQ(errno, EBADF);
    EXPECT_EQ(::close(tun2.second), 0);
}

// ⑱ F3 回归：Starting 期 Peer 轮询即生效（存活三态均轮询，不等 Running）。
// host peersNow 恒空列表无内容可断言，以「轮询触发 onStateChanged」为可观测信号：
// 旧门控（kind=="running"）在 Starting 期早退 → 计数不增（本用例在旧实现下必红）
TEST(TunnelRuntime, PollPeers_AliveDuringStarting)
{
    Rig r("pollpeers");
    ASSERT_TRUE(r.rt.start(mkCfg(r.dir.path, {kNetA})));
    ASSERT_EQ(r.rt.state().kind, "starting");

    // 静默基线：等启动期初始 apply 的 onStateChanged 落定，再取计数快照
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    int before = 0;
    {
        std::lock_guard<std::mutex> lk(r.cap.lock);
        before = r.cap.stateChanges;
    }

    r.rt.testPollPeers(); // 门控放行（存活态）→ core->peersNow() → onStateChanged
    ASSERT_TRUE(waitUntil([&] {
        std::lock_guard<std::mutex> lk(r.cap.lock);
        return r.cap.stateChanges > before;
    }, 1500));

    // 优雅停机（收口 timer/worker 线程）
    r.rt.stop();
    EXPECT_EQ(r.rt.state().kind, "stopped");
}
