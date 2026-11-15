// test_corebridge.cpp — CoreBridge 完整版 host 单测（A2 Task 6）
//
// brief 测试策略（host，无网络）：不起真实隧道，只测可控面——
//   ① start 后 address() 非零（身份生成即地址非 0）
//   ② identity.secret 落 dataStoreRoot 且 0600
//   ③ identityPerPlanet=true 时落 planetDir
//   ④ 二次 start（先 shutdown）地址不变（身份复用）
//   ⑤ stateFile 映射（moons.d/x → planetDir；planet → planetFile）
//   ⑥ putFileAtomic 失败路径（只读目录）不残留 .tmp
// 另补守卫行为：未启动 no-op、shutdown 幂等、空 hooks 不崩、ZT_EVENT_UP 同步投递、版本串、
// 驱动线程 hook 内 shutdown 自 join 防御。
// 全部测试挂在 CoreBridge 套件下，--gtest_filter='CoreBridge.*' 一网打尽。

#include "bridge/CoreBridge.h"

#include <gtest/gtest.h>

#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

namespace {

namespace fs = std::filesystem;

std::string makeTempDir(const char *tag)
{
    const fs::path base = fs::temp_directory_path() /
                          ("pp-t6-" + std::string(tag) + "-" + std::to_string(::getpid()));
    fs::create_directories(base);
    return base.string();
}

bool fileExists(const std::string &p)
{
    return fs::exists(fs::path(p));
}

// 取权限位（不存在返回 0）
mode_t fileMode(const std::string &p)
{
    struct stat st;
    if (::stat(p.c_str(), &st) != 0)
        return 0;
    return (mode_t)(st.st_mode & 07777);
}

std::string readFile(const std::string &p)
{
    std::FILE *f = std::fopen(p.c_str(), "rb");
    if (!f)
        return std::string();
    std::string out;
    char buf[4096];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0)
        out.append(buf, n);
    std::fclose(f);
    return out;
}

// RAII 临时目录：析构时先恢复权限（只读目录实验）再递归清理
struct TempDir {
    std::string path;
    explicit TempDir(const char *tag) : path(makeTempDir(tag)) {}
    ~TempDir()
    {
        std::error_code ec;
        if (fs::exists(path)) {
            for (fs::recursive_directory_iterator it(path, fs::directory_options::skip_permission_denied, ec), end;
                 it != end; it.increment(ec)) {
                fs::permissions(it->path(), fs::perms::owner_all, ec);
            }
            fs::permissions(path, fs::perms::owner_all, ec);
            fs::remove_all(path, ec);
        }
    }
    TempDir(const TempDir &) = delete;
    TempDir &operator=(const TempDir &) = delete;
};

} // namespace

// ① start 后 address() 非零：身份生成即产生 40 位节点地址
TEST(CoreBridge, StartGeneratesNonZeroAddress)
{
    TempDir td("addr");
    pp::CoreBridge b(td.path + "/ds", td.path + "/pd", "", false);
    ASSERT_TRUE(b.start());
    const auto addr = b.address();
    ASSERT_TRUE(addr);
    EXPECT_NE(*addr, 0u);
    EXPECT_LE(*addr, 0xffffffffffULL); // 40 位地址上界
    b.shutdown();
}

// ② 共享身份模式：identity.secret 落 dataStoreRoot 且收紧 0600，不落 planetDir
TEST(CoreBridge, IdentitySecretInDataStoreWith0600)
{
    TempDir td("idshared");
    const std::string ds = td.path + "/ds";
    const std::string pd = td.path + "/pd";
    pp::CoreBridge b(ds, pd, "", false);
    ASSERT_TRUE(b.start());
    b.shutdown(); // 立即停机：身份在 start() 内已生成并落盘
    EXPECT_TRUE(fileExists(ds + "/identity.secret"));
    EXPECT_TRUE(fileExists(ds + "/identity.public"));
    EXPECT_EQ(fileMode(ds + "/identity.secret"), 0600); // 敏感对象 owner-only
    EXPECT_FALSE(fileExists(pd + "/identity.secret"));
}

// ③ 独立身份模式：identity.* 跟随 planetDir（每行星一身份）
TEST(CoreBridge, IdentityPerPlanetGoesToPlanetDir)
{
    TempDir td("idplanet");
    const std::string ds = td.path + "/ds";
    const std::string pd = td.path + "/pd";
    pp::CoreBridge b(ds, pd, "", true);
    ASSERT_TRUE(b.start());
    const auto addr = b.address();
    b.shutdown();
    ASSERT_TRUE(addr);
    EXPECT_TRUE(fileExists(pd + "/identity.secret"));
    EXPECT_EQ(fileMode(pd + "/identity.secret"), 0600);
    EXPECT_FALSE(fileExists(ds + "/identity.secret")); // 共享位置必须无残留
}

// ④ 身份复用：先 shutdown 再以同一 dataStoreRoot 二次 start，地址不变
TEST(CoreBridge, IdentityReusedAcrossRestart)
{
    TempDir td("idreuse");
    const std::string ds = td.path + "/ds";
    const std::string pd = td.path + "/pd";
    uint64_t first = 0;
    {
        pp::CoreBridge b(ds, pd, "", false);
        ASSERT_TRUE(b.start());
        const auto a = b.address();
        ASSERT_TRUE(a);
        first = *a;
        EXPECT_NE(first, 0u);
        b.shutdown();
    }
    {
        pp::CoreBridge b(ds, pd, "", false);
        ASSERT_TRUE(b.start());
        const auto a = b.address();
        ASSERT_TRUE(a);
        EXPECT_EQ(*a, first); // identity.secret 持久化 → 核心装载而非重新生成
        b.shutdown();
    }
}

// 附加：hooks 未注入（全空）时 start/控制面/数据面入口全程不崩——回调路径必须判空
TEST(CoreBridge, EmptyHooksSurviveStartAndDataPlane)
{
    TempDir td("emptyhooks");
    pp::CoreBridge b(td.path + "/ds", td.path + "/pd", "", false);
    ASSERT_TRUE(b.start());
    const uint8_t pkt[8] = {0};
    const pp::WireEndpoint ep{"127.0.0.1", 9993};
    // 合法端点 + 任意字节：核心内部丢弃垃圾包仍返回 OK（入口返回值 = 核心调用成败，
    // 非「包被处理」语义）；无 sendPacket 出口不产生崩溃
    EXPECT_TRUE(b.processWirePacket(pkt, sizeof(pkt), ep));
    b.processVirtualNetworkFrame(1, 2, 3, 0x0800, 0, pkt, sizeof(pkt));
    b.join(0x123456789aULL);
    b.leave(0x123456789aULL);
    b.orbit(1, 2);
    b.deorbit(1);
    b.multicastSubscribe(0x123456789aULL, 0xffffffffffffULL, 0);
    EXPECT_TRUE(b.networkConf(0x123456789aULL) == std::nullopt); // 未加入网络
    b.shutdown();
}

// 附加：ZT_EVENT_UP（=0）在 Node 构造期同步投递，start() 返回前即可确定性收到
TEST(CoreBridge, EventHookDeliversUpEventSynchronously)
{
    TempDir td("upevent");
    pp::CoreBridge b(td.path + "/ds", td.path + "/pd", "", false);
    std::mutex m;
    std::vector<int> events;
    b.hooks.onEvent = [&](int e) {
        std::lock_guard<std::mutex> g(m);
        events.push_back(e);
    };
    ASSERT_TRUE(b.start());
    b.shutdown();
    std::lock_guard<std::mutex> g(m);
    ASSERT_FALSE(events.empty());
    EXPECT_EQ(events.front(), 0); // ZT_EVENT_UP = 0（核心首事件）
}

// 附加：未启动守卫 + shutdown 幂等 + 非法端点拒绝
TEST(CoreBridge, GuardsBeforeStartAndIdempotentShutdown)
{
    TempDir td("guards");
    pp::CoreBridge b(td.path + "/ds", td.path + "/pd", "", false);
    EXPECT_FALSE(b.address().has_value());
    EXPECT_EQ(b.networkConf(1), std::nullopt);
    EXPECT_TRUE(b.peersNow().empty());
    const uint8_t pkt[8] = {0};
    EXPECT_FALSE(b.processWirePacket(pkt, sizeof(pkt), pp::WireEndpoint{"192.168.1.10", 9993}));
    EXPECT_FALSE(b.processWirePacket(pkt, sizeof(pkt), pp::WireEndpoint{"not-an-ip", 1}));
    EXPECT_FALSE(b.processWirePacket(pkt, sizeof(pkt), pp::WireEndpoint{"12345", 1})); // 纯数字串防 DNS 语义
    EXPECT_FALSE(b.processWirePacket(nullptr, 0, pp::WireEndpoint{"1.2.3.4", 1}));
    b.processVirtualNetworkFrame(1, 2, 3, 0x0800, 0, pkt, sizeof(pkt)); // no-op 不崩
    b.join(1);
    b.leave(1);
    b.orbit(1, 2);
    b.deorbit(1);
    b.multicastSubscribe(1, 2, 3);
    b.shutdown(); // 未启动 shutdown 幂等
    ASSERT_TRUE(b.start());
    ASSERT_TRUE(b.address().has_value());
    b.shutdown();
    b.shutdown(); // 二次 shutdown 幂等
}

// ⑤ stateFile 映射（NodeRuntime.stateFile 分流直译）
TEST(CoreBridge, StateFileMapping)
{
    const std::string ds = "/ds-root";
    const std::string pd = "/planet-dir";
    const std::string pf = "/custom/planet.bin";

    // identity 跟随模式分流
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, "", false, "identity.public"),
              std::optional<std::string>(ds + "/identity.public"));
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, "", false, "identity.secret"),
              std::optional<std::string>(ds + "/identity.secret"));
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, "", true, "identity.public"),
              std::optional<std::string>(pd + "/identity.public"));
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, "", true, "identity.secret"),
              std::optional<std::string>(pd + "/identity.secret"));

    // planet：自定义文件优先；空则落 dataStoreRoot（仍缺失时核心用内置 planet）
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, pf, false, "planet"), std::optional<std::string>(pf));
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, "", false, "planet"), std::optional<std::string>(ds + "/planet"));

    // moon/peer/netconf 一律隔离到 planetDir（防同 ID 跨世界串数据）
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, pf, false, "moons.d/00000000deadbeef.moon"),
              std::optional<std::string>(pd + "/moons.d/00000000deadbeef.moon"));
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, pf, false, "networks.d/0123456789abcdef.conf"),
              std::optional<std::string>(pd + "/networks.d/0123456789abcdef.conf"));
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, pf, false, "peers.d/0a1b2c3d4e"),
              std::optional<std::string>(pd + "/peers.d/0a1b2c3d4e"));

    // 未知对象 → nullopt（stateGet -1 / statePut 忽略）
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, pf, false, "something.else"), std::nullopt);
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, pf, false, ""), std::nullopt);
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, pf, false, "moons.d.x"), std::nullopt); // 前缀必须带 '/'
    EXPECT_EQ(pp::stateFilePathFor(ds, pd, pf, false, "networks2.d/x"), std::nullopt);
}

// ⑥ putFileAtomic 失败路径：只读目录下无文件也无 .tmp 残留
TEST(CoreBridge, PutFileAtomicNoTmpResidueOnUnwritableDir)
{
    TempDir td("putfail");
    const std::string roDir = td.path + "/ro";
    fs::create_directories(roDir);
    ::chmod(roDir.c_str(), 0500); // 只读：fopen(.tmp) 必败
    const uint8_t data[] = {1, 2, 3, 4};
    pp::putFileAtomic(roDir + "/state.obj", data, sizeof(data), false);
    EXPECT_FALSE(fileExists(roDir + "/state.obj"));
    EXPECT_FALSE(fileExists(roDir + "/state.obj.tmp")); // 红线断言：失败不残留 .tmp
    pp::putFileAtomic(roDir + "/state.obj", nullptr, 0, false); // 空数据同样走失败路径
    EXPECT_FALSE(fileExists(roDir + "/state.obj.tmp"));
    // 权限恢复交给 TempDir 析构
}

// 附加：正常路径——父目录自动创建、内容一致、secure 收紧 0600、覆写替换且不留 .tmp
TEST(CoreBridge, PutFileAtomicSecureWriteCreatesOverwritesAndChmods)
{
    TempDir td("putok");
    const std::string p = td.path + "/sub/identity.secret"; // 父目录不存在 → 逐级创建
    const uint8_t a[] = "hello-identity";
    pp::putFileAtomic(p, a, sizeof(a) - 1, true);
    ASSERT_TRUE(fileExists(p));
    EXPECT_FALSE(fileExists(p + ".tmp"));
    EXPECT_EQ(readFile(p), std::string("hello-identity"));
    EXPECT_EQ(fileMode(p), 0600);

    const uint8_t b2[] = "rotated"; // identity 重写亦覆盖（rename 替换既有文件）
    pp::putFileAtomic(p, b2, sizeof(b2) - 1, true);
    EXPECT_EQ(readFile(p), std::string("rotated"));
    EXPECT_EQ(fileMode(p), 0600);
    EXPECT_FALSE(fileExists(p + ".tmp"));
}

// 附加：版本串——coreVersion() 与 CoreBridge::version() 同源；锁定冒烟基线（核心升级时同步改）
TEST(CoreBridge, VersionFormatsCoreVersion)
{
    EXPECT_STREQ(pp::coreVersion(), pp::CoreBridge::version());
    EXPECT_STREQ(pp::coreVersion(), "1.16.2");
}

// M1 防御向量：驱动线程 hook 内同步调用 shutdown 不 self-join、不 terminate。
// 驱动线程上可确定性触发的 hook 是 sendPacket：核心对 planet 根发 HELLO 时
// putPacket 直达出口回调（Node.cpp _PingPeersThatNeedPing → Peer::sendHELLO，
// 无需任何已学习路径）。首个 ping check 在 start() 内同步驱动（测试线程执行），
// 后续每 ZT_PING_CHECK_INTERVAL(5s) 周期由驱动线程执行——hook 线程 id 一旦
// 变化即驱动线程 hook，在其内调用 shutdown 走守卫路径（只置停机标志立即返回），
// 随后测试线程 shutdown 完整收口、节点可重启（未防御时本测试在 hook 内抛
// std::system_error → terminate，整个测试进程直接死）。
TEST(CoreBridge, ShutdownFromDriverThreadHookDoesNotSelfJoin)
{
    TempDir td("hookshutdown");
    pp::CoreBridge b(td.path + "/ds", td.path + "/pd", "", false);

    std::mutex m;
    std::thread::id firstId;           // 首个 sendPacket 的线程（start() 同步驱动 = 测试线程）
    std::thread::id driverId;          // 驱动线程 id（hook 线程 id 与首个不同时锁定）
    bool hookShutdownReturned = false; // 驱动线程 hook 内 shutdown 已返回
    b.hooks.sendPacket = [&](const uint8_t *, size_t, const pp::WireEndpoint &) -> int {
        std::lock_guard<std::mutex> g(m);
        const std::thread::id self = std::this_thread::get_id();
        if (firstId == std::thread::id()) {
            firstId = self;
        } else if (self != firstId && driverId == std::thread::id()) {
            driverId = self;
            b.shutdown(); // 守卫路径：只置 stopDriver 即返回（不 join 不删节点）
            hookShutdownReturned = true;
        }
        return 0;
    };
    ASSERT_TRUE(b.start());

    // 等待驱动线程 hook：首个 ping check 在 start() 内同步发生，驱动线程的下一
    // 次落在 5s 周期上（驱动循环 50-100ms 步进），上限 10s 留裕量
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    for (;;) {
        bool done = false;
        {
            std::lock_guard<std::mutex> g(m);
            done = hookShutdownReturned;
        }
        if (done)
            break;
        ASSERT_LT(std::chrono::steady_clock::now(), deadline)
            << "驱动线程 sendPacket hook 未在时限内触发（核心 ping check 异常）";
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    // 守卫语义断言：首个 sendPacket 确在测试线程；触发 shutdown 的 hook 来自
    // 驱动线程；hook 内 shutdown 未删节点（守卫只置标志，节点仍存活）
    EXPECT_EQ(firstId, std::this_thread::get_id());
    EXPECT_NE(driverId, std::this_thread::get_id());
    EXPECT_TRUE(b.address().has_value());

    // 完整收口：真实停机线程 join（非自 join）+ delete
    b.shutdown();
    EXPECT_FALSE(b.address().has_value());

    // 进程存活且状态可复用：重启一个新节点
    ASSERT_TRUE(b.start());
    const auto addr2 = b.address();
    ASSERT_TRUE(addr2);
    EXPECT_NE(*addr2, 0u);
    b.shutdown();
}
