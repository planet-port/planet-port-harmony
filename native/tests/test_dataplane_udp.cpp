// test_dataplane_udp.cpp — Dataplane / UdpCom 直译向量（A2 计划 Task 8 brief 场景）
//
// host 无 TUN：Dataplane 用 socketpair fd 模拟（一端作 TUN 交 swap，另一端作
// 内核侧读写）；UdpCom 用构造端口参数注入本地回环端口（不抢真实 9994）。
#include "dataplane/Dataplane.h"
#include "dataplane/UdpCom.h"

#include <gtest/gtest.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <tuple>
#include <utility>
#include <vector>

using namespace pp;
using namespace std::chrono_literals;

namespace {

// socketpair 模拟 TUN：{tun 端（swap 给 Dataplane）, 内核端（测试读写）}
std::pair<int, int> makeTunPair() {
    int sv[2] = {-1, -1};
    EXPECT_EQ(::socketpair(AF_UNIX, SOCK_STREAM, 0, sv), 0) << "socketpair 失败";
    return {sv[0], sv[1]};
}

// 结构化绑定不能被 lambda 捕获（C++20 特性，禁用）——显式展开
void splitPair(const std::pair<int, int>& p, int& tun, int& host) {
    tun = p.first;
    host = p.second;
}

void setNonBlocking(int fd) {
    const int fl = ::fcntl(fd, F_GETFL, 0);
    ::fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

// 单次非阻塞读（无数据返回空）
std::vector<uint8_t> drain(int fd) {
    uint8_t buf[65536];
    const ssize_t n = ::read(fd, buf, sizeof(buf));
    if (n <= 0) return {};
    return std::vector<uint8_t>(buf, buf + n);
}

// 轮询谓词直至成立（线程异步投递的确定性等待）
template <typename Pred>
bool waitUntil(Pred pred, int timeoutMs = 2000) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (std::chrono::steady_clock::now() < deadline) {
        if (pred()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return pred();
}

sockaddr_in v4Addr(const std::string& ip, uint16_t port) {
    sockaddr_in a {};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    ::inet_pton(AF_INET, ip.c_str(), &a.sin_addr);
    return a;
}

// 探测一个空闲回环 UDP 端口（bind :0 → getsockname → close；测试不抢真实 9994）
uint16_t freeUdpPort() {
    const int s = ::socket(AF_INET, SOCK_DGRAM, 0);
    EXPECT_GE(s, 0);
    sockaddr_in a = v4Addr("127.0.0.1", 0);
    EXPECT_EQ(::bind(s, reinterpret_cast<const sockaddr*>(&a), sizeof(a)), 0);
    socklen_t len = sizeof(a);
    EXPECT_EQ(::getsockname(s, reinterpret_cast<sockaddr*>(&a), &len), 0);
    ::close(s);
    return ntohs(a.sin_port);
}

// Dataplane 回调收包计数器（读线程异步投递，加锁存取）
struct PacketCounter {
    std::mutex lock;
    std::vector<std::vector<uint8_t>> packets;

    void push(const uint8_t* d, size_t n) {
        std::lock_guard<std::mutex> lk(lock);
        packets.emplace_back(d, d + n);
    }
    size_t size() {
        std::lock_guard<std::mutex> lk(lock);
        return packets.size();
    }
    std::vector<uint8_t> at(size_t i) {
        std::lock_guard<std::mutex> lk(lock);
        return packets[i];
    }
};

// 进程级忽略 SIGPIPE：向量「旧 fd shutdown 后内核端写入须返回 EPIPE 错误」
// 要求 write 走错误返回而非信号终止进程（JVM/ArkTS 进程默认忽略 SIGPIPE，
// Android 版数据面等价运行环境；host 测试自行声明同一前提）
class SigpipeIgnoreEnv : public ::testing::Environment {
public:
    void SetUp() override { ::signal(SIGPIPE, SIG_IGN); }
};

} // namespace

[[maybe_unused]] const ::testing::Environment* const kSigpipeEnv =
    ::testing::AddGlobalTestEnvironment(new SigpipeIgnoreEnv);

// ======================= Dataplane =======================

// ---- 场景①：socketpair fd swap → 写端写包 → onTunPacket 收到（读线程活） ----
TEST(Dataplane, SwapDeliversPacketsToCallback) {
    int tun = -1, host = -1;
    splitPair(makeTunPair(), tun, host);
    PacketCounter got;
    Dataplane dp([&](const uint8_t* d, size_t n) { got.push(d, n); });
    ASSERT_TRUE(dp.swap(tun));
    EXPECT_EQ(dp.generation(), 1);

    const uint8_t pkt[] = {0x45, 0x00, 0x00, 0x14, 0x01, 0x02, 0x03, 0x04, 0x00, 0x00,
                           0x40, 0x11, 0x00, 0x00, 0x00, 0x00, 10, 0, 0, 1};
    ASSERT_EQ(::write(host, pkt, sizeof(pkt)), static_cast<ssize_t>(sizeof(pkt)));
    ASSERT_TRUE(waitUntil([&] { return got.size() >= 1; })) << "读线程未收到写端数据";
    EXPECT_EQ(got.at(0), std::vector<uint8_t>(pkt, pkt + sizeof(pkt)));
    dp.shutdown();
    ::close(host);
}

// ---- 场景①补：swap 新 fd → 旧 fd 数据不再来、新 fd 来（换代生效） ----
TEST(Dataplane, SwapReplacesGenerationAndStopsOldFd) {
    int tunA = -1, hostA = -1;
    splitPair(makeTunPair(), tunA, hostA);
    int tunB = -1, hostB = -1;
    splitPair(makeTunPair(), tunB, hostB);
    PacketCounter got;
    Dataplane dp([&](const uint8_t* d, size_t n) { got.push(d, n); });
    ASSERT_TRUE(dp.swap(tunA));
    const uint8_t p1[] = {1};
    ASSERT_EQ(::write(hostA, p1, 1), 1);
    ASSERT_TRUE(waitUntil([&] { return got.size() == 1; })) << "第一代数据未落地（先于换代稳定）";

    ASSERT_TRUE(dp.swap(tunB)); // 换代
    EXPECT_EQ(dp.generation(), 2);

    // 旧 fd 数据不再来：A 端已 shutdown，内核端写入即 EPIPE
    errno = 0;
    ASSERT_EQ(::write(hostA, p1, 1), -1);
    EXPECT_EQ(errno, EPIPE);

    // 新 fd 到来
    const uint8_t p2[] = {2};
    ASSERT_EQ(::write(hostB, p2, 1), 1);
    ASSERT_TRUE(waitUntil([&] { return got.size() == 2; }));
    EXPECT_EQ(got.at(1), std::vector<uint8_t>{2});
    std::this_thread::sleep_for(100ms);
    EXPECT_EQ(got.size(), 2u) << "旧 fd 迟到包（换代残窗不应出现）";
    dp.shutdown();
    ::close(hostA);
    ::close(hostB);
}

// ---- 场景①补：swap 后 writePackets 落到新 fd ----
TEST(Dataplane, WritePacketsFollowGeneration) {
    int tunA = -1, hostA = -1;
    splitPair(makeTunPair(), tunA, hostA);
    int tunB = -1, hostB = -1;
    splitPair(makeTunPair(), tunB, hostB);
    setNonBlocking(hostA);
    setNonBlocking(hostB);
    Dataplane dp([](const uint8_t*, size_t) {});
    ASSERT_TRUE(dp.swap(tunA));

    const std::vector<uint8_t> pkt1 {'a', 'b'};
    dp.writePackets({pkt1});
    std::vector<uint8_t> receivedA;
    ASSERT_TRUE(waitUntil([&] {
        const std::vector<uint8_t> d = drain(hostA);
        receivedA.insert(receivedA.end(), d.begin(), d.end());
        return receivedA == pkt1;
    })) << "专职写线程未把上行包写到 TUN";

    ASSERT_TRUE(dp.swap(tunB));
    EXPECT_EQ(dp.generation(), 2);
    const std::vector<uint8_t> pkt2 {'c', 'd'};
    dp.writePackets({pkt2});
    std::vector<uint8_t> receivedB;
    ASSERT_TRUE(waitUntil([&] {
        const std::vector<uint8_t> d = drain(hostB);
        receivedB.insert(receivedB.end(), d.begin(), d.end());
        return receivedB == pkt2;
    })) << "换代后写包未落到新 fd";

    // 旧 fd 不再新增（换代后写线程只认新 fd）
    std::this_thread::sleep_for(100ms);
    EXPECT_EQ(drain(hostA).size(), 0u) << "换代后旧 fd 收到多余写入";
    dp.shutdown();
    ::close(hostA);
    ::close(hostB);
}

// ---- 场景①补：teardownTun 后 swap 仍可用（无闩锁） ----
TEST(Dataplane, TeardownTunThenSwapStillWorks) {
    int tunA = -1, hostA = -1;
    splitPair(makeTunPair(), tunA, hostA);
    int tunB = -1, hostB = -1;
    splitPair(makeTunPair(), tunB, hostB);
    PacketCounter got;
    Dataplane dp([&](const uint8_t* d, size_t n) { got.push(d, n); });
    ASSERT_TRUE(dp.swap(tunA));
    const uint8_t p[] = {9};
    ASSERT_EQ(::write(hostA, p, 1), 1);
    ASSERT_TRUE(waitUntil([&] { return got.size() == 1; }));

    dp.teardownTun(); // 不带停机闩锁（teardown ≠ 终局）
    EXPECT_EQ(dp.generation(), 2);
    errno = 0;
    ASSERT_EQ(::write(hostA, p, 1), -1);
    EXPECT_EQ(errno, EPIPE) << "teardown 后旧 TUN fd 未关闭";
    dp.writePackets({std::vector<uint8_t> {'x'}}); // 无写线程：静默丢，不崩

    ASSERT_TRUE(dp.swap(tunB)) << "teardown ≠ 终局，swap 应可重建";
    EXPECT_EQ(dp.generation(), 3);
    ASSERT_EQ(::write(hostB, p, 1), 1);
    ASSERT_TRUE(waitUntil([&] { return got.size() == 2; }));
    dp.shutdown();
    ::close(hostA);
    ::close(hostB);
}

// ---- 场景①补：shutdown 闩锁——swap 返 false、新 fd 被关闭（防滞留 fd 泄漏） ----
TEST(Dataplane, ShutdownLatchesSwapAndClosesRejectedFd) {
    int tunA = -1, hostA = -1;
    splitPair(makeTunPair(), tunA, hostA);
    int tunB = -1, hostB = -1;
    splitPair(makeTunPair(), tunB, hostB);
    Dataplane dp([](const uint8_t*, size_t) {});
    ASSERT_TRUE(dp.swap(tunA));
    dp.shutdown();
    EXPECT_EQ(dp.generation(), 2); // 终局换代一次

    ASSERT_FALSE(dp.swap(tunB)) << "shutdown 后迟到 swap 未被闩锁拒绝";
    EXPECT_EQ(dp.generation(), 2) << "被拒绝的 swap 不应换代";
    errno = 0;
    EXPECT_EQ(::fcntl(tunB, F_GETFL), -1) << "被拒 swap 的新 fd 未关闭（establish 滞留泄漏）";
    EXPECT_EQ(errno, EBADF);

    // 收尾调用无副作用
    dp.writePackets({std::vector<uint8_t> {'y'}});
    dp.teardownTun();
    const std::pair<int, int> tunC_pair = makeTunPair();
    const int tunC = tunC_pair.first, hostC = tunC_pair.second;
    ASSERT_FALSE(dp.swap(tunC)) << "teardown 不解除终局闩锁";
    errno = 0;
    EXPECT_EQ(::fcntl(tunC, F_GETFL), -1);
    EXPECT_EQ(errno, EBADF);
    ::close(hostA);
    ::close(hostB);
    ::close(hostC);
}

// ---- 场景①补：tunSetBlocking 失败兜底——非阻塞空读（EAGAIN）走退避轮询而非读线程死亡 ----
// POSIX 原生 read 的非阻塞空读是 -1/EAGAIN（Java FileInputStream.read 同一事件表现为
// 返回 0，Kotlin 直译源据此退避）。swap 内 tunSetBlocking 已清 O_NONBLOCK、无法从外部
// 注入「清除失败」；改为 swap 后用 F_SETFL 重置 O_NONBLOCK 复现同款现场：在途阻塞 read
// 不受影响，其后的空读必为 EAGAIN——须走退避轮询（修复前落 n<0 break，读线程静默死亡）
TEST(Dataplane, NonBlockingFdFallsBackToBackoffPolling) {
    int tun = -1, host = -1;
    splitPair(makeTunPair(), tun, host);
    PacketCounter got;
    Dataplane dp([&](const uint8_t* d, size_t n) { got.push(d, n); });
    ASSERT_TRUE(dp.swap(tun));

    // 首包先稳定消费（此刻读线程处阻塞 read），再重置 O_NONBLOCK
    const uint8_t p1[] = {1};
    ASSERT_EQ(::write(host, p1, 1), 1);
    ASSERT_TRUE(waitUntil([&] { return got.size() >= 1; })) << "读线程未消费首包";
    setNonBlocking(tun); // 模拟 tunSetBlocking 失败现场：fd 保持 O_NONBLOCK

    // 50ms 静默：其后启动的 read 必为非阻塞空读（EAGAIN）→ 退避轮询路径
    std::this_thread::sleep_for(50ms);

    // 第二包：证明读线程在 EAGAIN 后仍存活（修复前 n<0 break 即死，此断言超时）
    const uint8_t p2[] = {2};
    ASSERT_EQ(::write(host, p2, 1), 1);
    ASSERT_TRUE(waitUntil([&] { return got.size() >= 2; }))
        << "非阻塞空读（EAGAIN）后读线程死亡——兜底退避未生效";
    EXPECT_EQ(got.at(1), std::vector<uint8_t>{2});

    // 30ms 静默后注入第三包：覆盖「第二包被在途阻塞 read 消费」的交错——此刻起空读
    // 已必为 EAGAIN，此包只能经退避轮询送达
    std::this_thread::sleep_for(30ms);
    const uint8_t p3[] = {3};
    ASSERT_EQ(::write(host, p3, 1), 1);
    ASSERT_TRUE(waitUntil([&] { return got.size() >= 3; })) << "退避轮询未送达后续包";
    EXPECT_EQ(got.at(2), std::vector<uint8_t>{3});

    dp.shutdown();
    ::close(host);
}

// ---- shutdown 后读线程已停（析构不挂起、旧 fd 不再回调） ----
TEST(Dataplane, ShutdownStopsReadThread) {
    int tun = -1, host = -1;
    splitPair(makeTunPair(), tun, host);
    PacketCounter got;
    {
        Dataplane dp([&](const uint8_t* d, size_t n) { got.push(d, n); });
        ASSERT_TRUE(dp.swap(tun));
        const uint8_t p[] = {1, 2};
        ASSERT_EQ(::write(host, p, 2), 2);
        ASSERT_TRUE(waitUntil([&] { return got.size() == 1; }));
    } // 析构 = shutdown：读线程须已 join（快速返回，无 500ms 残窗）
    const uint8_t p2[] = {3};
    ASSERT_EQ(::write(host, p2, 1), -1); // tun 端已关，内核端写入 EPIPE
    EXPECT_EQ(errno, EPIPE);
    ::close(host);
}

// ======================= UdpCom =======================

// ---- 场景②：start（protect 恒 true）→ 本机发注入端口 → OnPacket 收到；send 回发对端收到 ----
TEST(UdpCom, StartReceiveAndSendLoopback) {
    const uint16_t port = freeUdpPort();
    UdpCom u(port);
    std::mutex lock;
    std::condition_variable cv;
    std::vector<std::tuple<std::vector<uint8_t>, std::string, uint16_t>> got;
    ASSERT_TRUE(u.start(
        [](int) { return true; },
        [&](const uint8_t* d, size_t n, const std::string& ip, uint16_t p) {
            std::lock_guard<std::mutex> lk(lock);
            got.emplace_back(std::vector<uint8_t>(d, d + n), ip, p);
            cv.notify_all();
        }));

    // 测试 socket bind 临时回环端口（回发目的地；0 = 系统分配）
    const int s = ::socket(AF_INET, SOCK_DGRAM, 0);
    ASSERT_GE(s, 0);
    sockaddr_in a = v4Addr("127.0.0.1", 0);
    ASSERT_EQ(::bind(s, reinterpret_cast<const sockaddr*>(&a), sizeof(a)), 0);
    socklen_t alen = sizeof(a);
    ASSERT_EQ(::getsockname(s, reinterpret_cast<sockaddr*>(&a), &alen), 0);
    const uint16_t sport = ntohs(a.sin_port);

    // 发到 UdpCom 的收包线程
    const sockaddr_in dst = v4Addr("127.0.0.1", port);
    ASSERT_EQ(::sendto(s, "ping", 4, 0, reinterpret_cast<const sockaddr*>(&dst), sizeof(dst)), 4);
    {
        std::unique_lock<std::mutex> lk(lock);
        ASSERT_TRUE(cv.wait_for(lk, 2s, [&] { return !got.empty(); })) << "OnPacket 未收到回环包";
        EXPECT_EQ(std::get<0>(got[0]), std::vector<uint8_t>({'p', 'i', 'n', 'g'}));
        EXPECT_EQ(std::get<1>(got[0]), "127.0.0.1"); // recvfrom 反解的源地址
        EXPECT_EQ(std::get<2>(got[0]), sport);       // recvfrom 反解的源端口
    }

    // PacketSender 语义：send → 0；对端（测试 socket）收到回发
    const uint8_t pong[] = {'p', 'o', 'n', 'g'};
    EXPECT_EQ(u.send("127.0.0.1", sport, pong, sizeof(pong)), 0);
    const struct timeval tv {2, 0};
    ASSERT_EQ(::setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)), 0);
    uint8_t rbuf[64] = {};
    sockaddr_in from {};
    socklen_t flen = sizeof(from);
    const ssize_t rn = ::recvfrom(s, rbuf, sizeof(rbuf), 0, reinterpret_cast<sockaddr*>(&from), &flen);
    ASSERT_EQ(rn, 4) << "send 回发未到达对端";
    EXPECT_EQ(std::vector<uint8_t>(rbuf, rbuf + 4), std::vector<uint8_t>({'p', 'o', 'n', 'g'}));

    // send 失败路径：地址解析失败 → -1（Kotlin remote.address ?: return -1）
    EXPECT_EQ(u.send("not-an-ip", sport, pong, 4), -1);
    ::close(s);
    u.shutdown();
}

// ---- 场景②补：protect 返 false → start 失败；时序锁定：bind 后立即调用 protect ----
TEST(UdpCom, ProtectFalseFailsStart) {
    const uint16_t port = freeUdpPort();
    UdpCom u(port);
    std::atomic<bool> boundToInjectedPort {false};
    EXPECT_FALSE(u.start(
        [&](int fd) {
            // protect 钩子拿到的 fd 必已 bind 注入端口（未 bind 的 socket
            // getsockname 返回 :0）——锁定 bind→protect 时序
            sockaddr_in a {};
            socklen_t alen = sizeof(a);
            if (::getsockname(fd, reinterpret_cast<sockaddr*>(&a), &alen) == 0)
                boundToInjectedPort.store(ntohs(a.sin_port) == port);
            return false;
        },
        [](const uint8_t*, size_t, const std::string&, uint16_t) {}))
        << "protect 失败应走绑定失败路径";
    EXPECT_TRUE(boundToInjectedPort.load())
        << "protect 钩子执行时 fd 未 bind 注入端口（bind→protect 时序不符）";
    u.shutdown(); // 失败路径收尾安全（无 socket 无线程）
}

// ---- 场景②补：注入端口被占 → start 失败返 false；释放后可成功 ----
TEST(UdpCom, PortBusyFailsStart) {
    const uint16_t port = freeUdpPort();
    // 占口 socket 不设 SO_REUSEADDR：macOS 的 SO_REUSEADDR 有近似 SO_REUSEPORT
    // 的怪癖，占用方不设置才能在 macOS/Linux 稳定触发 EADDRINUSE
    const int holder = ::socket(AF_INET, SOCK_DGRAM, 0);
    ASSERT_GE(holder, 0);
    sockaddr_in a = v4Addr("0.0.0.0", port);
    ASSERT_EQ(::bind(holder, reinterpret_cast<const sockaddr*>(&a), sizeof(a)), 0);

    UdpCom u(port);
    EXPECT_FALSE(u.start(
        [](int) { return true; },
        [](const uint8_t*, size_t, const std::string&, uint16_t) {}))
        << "端口被占应返回 false（udpBindFailed, recoverable），不崩进程";
    u.shutdown();

    // 释放后同端口可成功（bind 失败是可恢复态）
    ASSERT_EQ(::close(holder), 0);
    UdpCom u2(port);
    std::atomic<int> count {0};
    ASSERT_TRUE(u2.start([](int) { return true; },
                         [&](const uint8_t*, size_t, const std::string&, uint16_t) { ++count; }));
    const int s = ::socket(AF_INET, SOCK_DGRAM, 0);
    ASSERT_GE(s, 0);
    const sockaddr_in dst = v4Addr("127.0.0.1", port);
    ASSERT_EQ(::sendto(s, "ok", 2, 0, reinterpret_cast<const sockaddr*>(&dst), sizeof(dst)), 2);
    EXPECT_TRUE(waitUntil([&] { return count.load() >= 1; }));
    ::close(s);
    u2.shutdown();
}

// ---- 场景②补：shutdown 后收包线程退出（join 完成）：同端口可立即重启、send 失效 ----
TEST(UdpCom, ShutdownJoinsAndAllowsImmediateRestart) {
    const uint16_t port = freeUdpPort();
    UdpCom u(port);
    std::atomic<int> count1 {0};
    ASSERT_TRUE(u.start([](int) { return true; },
                        [&](const uint8_t*, size_t, const std::string&, uint16_t) { ++count1; }));
    const int s = ::socket(AF_INET, SOCK_DGRAM, 0);
    ASSERT_GE(s, 0);
    sockaddr_in a = v4Addr("127.0.0.1", 0);
    ASSERT_EQ(::bind(s, reinterpret_cast<const sockaddr*>(&a), sizeof(a)), 0);
    socklen_t alen = sizeof(a);
    ASSERT_EQ(::getsockname(s, reinterpret_cast<sockaddr*>(&a), &alen), 0);
    const uint16_t sport = ntohs(a.sin_port);

    const sockaddr_in dst = v4Addr("127.0.0.1", port);
    ASSERT_EQ(::sendto(s, "x", 1, 0, reinterpret_cast<const sockaddr*>(&dst), sizeof(dst)), 1);
    ASSERT_TRUE(waitUntil([&] { return count1.load() >= 1; }));

    u.shutdown();
    // join 完成的行为验证：旧 socket 已释放，同端口立即重启成功（否则 bind EADDRINUSE）
    std::atomic<int> count2 {0};
    ASSERT_TRUE(u.start([](int) { return true; },
                        [&](const uint8_t*, size_t, const std::string&, uint16_t) { ++count2; }))
        << "shutdown 后同端口重启失败（收包线程/socket 未释放）";
    ASSERT_EQ(::sendto(s, "y", 1, 0, reinterpret_cast<const sockaddr*>(&dst), sizeof(dst)), 1);
    EXPECT_TRUE(waitUntil([&] { return count2.load() >= 1; }));
    EXPECT_EQ(count1.load(), 1) << "shutdown 后旧代不应再收包";

    // 终局：shutdown 后 socket 快照清空，send 失败
    u.shutdown();
    const uint8_t z = 'z';
    EXPECT_EQ(u.send("127.0.0.1", sport, &z, 1), -1);
    ::close(s);
    u.shutdown(); // 幂等收尾
}
