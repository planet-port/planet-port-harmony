// Dataplane.h — TUN fd 换代读写（A2 计划 Task 8）
//
// 直译源：tunnel/Dataplane.kt（125 行）+ TunFdUtils.kt / core/jni/ZT_tunfd.cpp。
// 每次 Builder.establish 返回新 fd（Android 与 iOS 的 packetFlow 常驻不同），
// swap() 负责换代——旧 fd 关闭使读线程退出，新读线程与专职写线程随新代号启动。
// Kotlin 协程/ExecutorService → std::thread 直译：生命周期由 swap/teardownTun/
// shutdown 管理；std::thread 无超时 join，Kotlin join(500) 超时残窗以 GenBarrier
// 等待 + detach 等义落地（见 Dataplane.cpp 文件头差异申报）。
#pragma once
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>
#include <vector>

namespace pp {

// 读线程换代退出屏障（Dataplane 与 UdpCom 共用；单测也可借它确认线程退出）。
// 读线程只回引本控制块（shared_ptr 保活），不回引宿主对象——join(500) 超时放弃
// 后 detached 残窗线程仍会走到 signal()，宿主析构不产生 UAF
// （Kotlin 残窗线程靠 GC 存活性兜底，C++ 侧显式化为堆控制块）。
struct GenBarrier {
    std::mutex lock;
    std::condition_variable cv;
    bool done = false;
    // 承载 Kotlin「generation == gen」换代判定：换代方置 true，读线程循环条件消费
    std::atomic<bool> quit{false};

    // 读线程退出确认（join 目标「已退出」信号）
    void signal() {
        {
            std::lock_guard<std::mutex> lk(lock);
            done = true;
        }
        cv.notify_all();
    }

    // 等待退出确认；超时返回 false——调用方放弃等待并 detach（对齐 Kotlin join(500)）
    static bool waitFor(const std::shared_ptr<GenBarrier>& b, int timeoutMs) {
        if (!b) return false;
        std::unique_lock<std::mutex> lk(b->lock);
        return b->cv.wait_for(lk, std::chrono::milliseconds(timeoutMs), [&] { return b->done; });
    }
};

class Dataplane {
public:
    using TunPacket = std::function<void(const uint8_t*, size_t)>;
    explicit Dataplane(TunPacket onTunPacket);
    ~Dataplane(); // 终局收口走 shutdown()（Kotlin 由服务生命周期负责，C++ 补析构防线）
    Dataplane(const Dataplane&) = delete;
    Dataplane& operator=(const Dataplane&) = delete;

    // 换代：拒绝（已停机）返回 false 且关闭新 fd；成功返回 true。调用方须以
    // 返回值为准决定是否记录「已应用」状态——被拒时 TUN 实际不存在
    bool swap(int fd);

    // 上行 IP 包写入 tun（消费协程投递，专职写线程顺序化）；停机中静默丢包
    void writePackets(const std::vector<std::vector<uint8_t>>& packets);

    // 拆 TUN（全部网络失效时）：关 fd 即接口消失、系统路由自动撤销，实例保持
    // 可用——后续网络恢复可继续 swap 重建。不带停机闩锁（teardown ≠ 终局）。
    void teardownTun();

    // 终局停机：置闩锁拒绝一切后续 swap（服务生命周期收口专用，拆 TUN 用 teardownTun）
    void shutdown();

    int generation() const { return m_gen.load(); }

private:
    void stopWriteThreadLocked();       // 调用方持 m_lock
    void startWriteThreadLocked(int fd); // 调用方持 m_lock

    void writeLoop();

    std::mutex m_lock;                  // Kotlin @Synchronized（swap/teardown/shutdown 同锁）
    std::atomic<bool> m_stopped{false}; // 停机闩锁——拒绝停机后迟到的 swap（establish 滞留 fd 泄漏）
    std::atomic<int> m_gen{0};
    TunPacket m_onPacket;               // 构造期注入（Kotlin val onTunPacket），读线程捕获副本
    int m_fd = -1;                      // currentFd；唯一 close 点在 swap/teardownTun
    std::thread m_readThread;           // zt-tun-read-$gen
    std::shared_ptr<GenBarrier> m_readBarrier;

    // 专职写线程（zt-tun-write-$gen 语义）+ 批次队列。独立锁避免与 m_lock 成环
    // （swap 持 m_lock join 写线程时，写线程只碰 m_writeLock）
    std::thread m_writeThread;
    std::mutex m_writeLock;
    std::condition_variable m_writeCv;
    std::queue<std::vector<std::vector<uint8_t>>> m_writeQueue;
    bool m_writeAlive = false;          // Kotlin writeExecutor != null
    bool m_writeQuit = false;           // ExecutorService.shutdownNow
    int m_writeFd = -1;                 // 写线程的 outputStream 快照（<0 视为 null）
};

} // namespace pp
