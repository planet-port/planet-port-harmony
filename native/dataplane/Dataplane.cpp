// Dataplane.cpp — TUN fd 换代读写直译（A2 计划 Task 8）
//
// 直译源：tunnel/Dataplane.kt + TunFdUtils.kt / core/jni/ZT_tunfd.cpp（33 行）。
// 与 Kotlin 的落地差异（行为等价申报，见头文件与本文件注释）：
//   ① FileInputStream/FileOutputStream 不拥有底层 fd（Java 层 fd 引用计数），
//      C++ 侧 fd 唯一归属 Dataplane，close 点仅 swap/teardownTun——读线程退出
//      时无需关 fd；
//   ② 阻塞 read 的唤醒：POSIX close(2) 不唤醒他线程阻塞中的 read（Kotlin 注释
//      「关旧 fd 使读线程退出」依赖内核对 TUN 设备的 close 唤醒），C++ 侧在
//      close 前先 shutdown(fd)（socketpair/UDP 类生效；TUN 字符设备返 ENOTSOCK
//      无害，仍由 close 后内核唤醒兜底）；
//   ③ std::thread 无超时 join：Kotlin join(500) 超时残窗以 GenBarrier 等待 +
//      detach 等义落地（残窗线程只回引堆控制块，不回引宿主——读循环因此为
//      static 自由函数，fd/barrier/onPacket 全部按值随线程，见匿名命名空间）；
//      POSIX 原生 read 的非阻塞空读是 -1/EAGAIN（Java FileInputStream.read 同一
//      事件表现为返回 0），故读循环把 EAGAIN/EWOULDBLOCK 与 n==0 并入同一退避
//      轮询路径，与 Kotlin n==0 分支等义；
//   ④ Kotlin onTunPacket(buf.copyOf(n)) 的拷贝防 buf 复用竞争——C++ 回调在读
//      线程内同步执行、buf 为线程局部，直接传指针；回调若异步转手需自行拷贝；
//   ⑤ TunnelStateBus.log 三处日志点（setBlocking 异常 / 恢复阻塞失败 / 退避
//      轮询）在 OHOS 日志通道（A3 接线）前静默，以注释标记直译位置；
//   ⑥ 线程命名 zt-tun-read-$gen / zt-tun-write-$gen 以注释承载（pthread 线程名
//      不跨平台，行为无差异）。
#include "dataplane/Dataplane.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

namespace pp {
namespace {

// TunFdUtils.setBlocking / core/jni/ZT_tunfd.cpp 直译：清除 O_NONBLOCK。
// 返回 0=成功转为阻塞，1=本就阻塞，负值=失败 errno
int tunSetBlocking(int fd) {
    const int fl = ::fcntl(fd, F_GETFL);
    if (fl < 0) return -errno;
    if (!(fl & O_NONBLOCK)) return 1;
    return ::fcntl(fd, F_SETFL, fl & ~O_NONBLOCK) == 0 ? 0 : -errno;
}

// Kotlin Thread.sleep(1)（非阻塞空读退避）
void sleep1ms() {
    const struct timespec ts {0, 1000 * 1000};
    ::nanosleep(&ts, nullptr);
}

// 读循环直译（Kotlin swap 内联 Thread { while (generation == gen) ... }）。
// static 自由函数：fd/barrier/onPacket 全部按值随线程持有，detach 残窗线程不回引
// 宿主对象——宿主析构后若以 this 调用非静态成员函数即 [basic.life] UB，与
// GenBarrier「堆控制块保活」申报语义配套。命名 tunReadLoop：读循环为匿名命名
// 空间自由函数，Dataplane.h 无对应成员声明（与 UdpCom 的 udpRecvLoop 同构）
void tunReadLoop(int fd, std::shared_ptr<GenBarrier> barrier, Dataplane::TunPacket onPacket) {
    const size_t kBufSize = 65536; // Kotlin ByteArray(65536)
    uint8_t buf[kBufSize];
    bool polled = false;
    while (!barrier->quit.load()) { // while (generation == gen)
        const ssize_t n = ::read(fd, buf, kBufSize);
        if (n == 0) {
            // 非阻塞空读在 Java 层表现为返回 0（内核 EAGAIN 被 FileInputStream.read
            // 折叠为 0；TUN 某些平台的 0 返回同此语义）：退避后重试。
            // Kotlin: if (!polled) { polled = true; log("tun fd 仍非阻塞，退避轮询 gen=…") }
            //（OHOS 日志通道接线前静默）
            if (!polled) polled = true;
            sleep1ms();
            continue;
        }
        if (n < 0) {
            if (errno == EINTR) continue; // Java InputStream.read 对 EINTR 自动重试，等价直译
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                // POSIX 原生 read 对同一「非阻塞空读」事件的信号是 -1/EAGAIN，而非
                // Java 层的返回 0——与 Kotlin n==0 分支同义，并入退避轮询。若在此
                // break，tunSetBlocking 失败（OEM 出厂即 O_NONBLOCK）时读线程静默
                // 死亡、TUN 上行断流
                if (!polled) polled = true;
                sleep1ms();
                continue;
            }
            break; // IOException → break（fd 关闭）
        }
        onPacket(buf, size_t(n)); // buf.copyOf(n) 的拷贝不再必要（头差异④）
    }
    barrier->signal();
}

} // namespace

Dataplane::Dataplane(TunPacket onTunPacket) : m_onPacket(std::move(onTunPacket)) {}

Dataplane::~Dataplane() { shutdown(); }

bool Dataplane::swap(int fd) {
    std::lock_guard<std::mutex> lk(m_lock); // @Synchronized
    if (m_stopped.load()) {
        // 停机后迟到的 establish（withContext(IO) 内不可取消）：拒绝并关闭新 fd 防泄漏
        ::close(fd);
        return false;
    }
    // generation += 1（Kotlin val gen 另用于线程命名 zt-tun-read-$gen，见头差异⑥）
    m_gen.fetch_add(1);
    stopWriteThreadLocked(); // writeExecutor?.shutdownNow()

    // 停旧代读线程：先置换代退出标志（barrier->quit 承载 generation == gen 失效），
    // 再关旧 fd 使阻塞 read 退出（POSIX 落实见文件头差异②）
    const std::shared_ptr<GenBarrier> barrier = m_readBarrier;
    if (barrier) barrier->quit.store(true);
    const int oldFd = m_fd;
    if (oldFd >= 0) {
        ::shutdown(oldFd, SHUT_RDWR); // ENOTSOCK 忽略；socketpair 等即刻唤醒阻塞 read
        ::close(oldFd);               // 先关旧 fd——阻塞在 read() 的旧读线程随即退出
    }
    m_fd = -1;
    // join 旧代读线程：fd 关闭唤醒 read 退出；若正处 onTunPacket 的回调内，
    // 等回调返回落地（终审 Minor：换代窗口残窗）
    if (m_readThread.joinable()) {
        if (GenBarrier::waitFor(barrier, 500))
            m_readThread.join();
        else
            m_readThread.detach(); // 残窗：放弃等待，线程跑完自退（Kotlin join(500) 超时同义）
    }
    m_readBarrier.reset();

    m_fd = fd;
    // 部分 OEM TUN fd 出厂即 O_NONBLOCK，空读令「n<=0 退出」的阻塞语义失效
    // （MIUI/Android 9 实测；Java 层空读表现为返回 0，POSIX 原生为 -1/EAGAIN）。
    // 恢复阻塞模式；失败则读循环退避轮询兜底（见 tunReadLoop），不让空读杀死读线程。
    const int blockResult = tunSetBlocking(fd);
    if (blockResult < 0) {
        // Kotlin: TunnelStateBus.log("tun fd 恢复阻塞失败 errno=$blockResult，
        // 读循环将以退避轮询兜底")——OHOS 日志通道接线前静默（头差异⑤）
    }
    startWriteThreadLocked(fd); // 新一代专职写线程（zt-tun-write-$gen 语义）
    m_readBarrier = std::make_shared<GenBarrier>();
    // static 自由函数：上下文全按值随线程，detach 残窗不持 this（[basic.life]）
    m_readThread = std::thread(&tunReadLoop, fd, m_readBarrier, m_onPacket);
    return true;
}

void Dataplane::writePackets(const std::vector<std::vector<uint8_t>>& packets) {
    if (packets.empty()) return;
    std::lock_guard<std::mutex> wl(m_writeLock);
    if (!m_writeAlive) return; // Kotlin: val exec = writeExecutor ?: return
    if (m_writeQuit) return;   // 与 shutdown 的 shutdownNow 竞态：停机中丢包符合语义，静默返回
    m_writeQueue.push(packets);
    m_writeCv.notify_one();
}

void Dataplane::teardownTun() {
    std::lock_guard<std::mutex> lk(m_lock); // @Synchronized
    m_gen.fetch_add(1);                     // generation += 1
    stopWriteThreadLocked();                // shutdownNow + 置空（Kotlin writeExecutor = null）
    const std::shared_ptr<GenBarrier> barrier = m_readBarrier;
    if (barrier) barrier->quit.store(true);
    const int oldFd = m_fd;
    if (oldFd >= 0) {
        ::shutdown(oldFd, SHUT_RDWR);
        ::close(oldFd);
    }
    m_fd = -1;
    if (m_readThread.joinable()) {
        if (GenBarrier::waitFor(barrier, 500))
            m_readThread.join();
        else
            m_readThread.detach(); // 残窗：同 swap 的 join(500) 超时语义
    }
    m_readBarrier.reset(); // readThread = null
}

void Dataplane::shutdown() {
    m_stopped.store(true); // 置闩锁拒绝一切后续 swap
    teardownTun();         // Kotlin shutdown 内直接调 @Synchronized teardownTun（可重入锁）；
                           // std::mutex 不可重入，此处不持锁进入（teardownTun 自行加锁）
}

void Dataplane::stopWriteThreadLocked() {
    {
        std::lock_guard<std::mutex> wl(m_writeLock);
        m_writeQuit = true;
        m_writeAlive = false;
        m_writeFd = -1;
        // shutdownNow：队列残量随换代丢弃（writePackets 投递后未消费的批次同此）
        std::queue<std::vector<std::vector<uint8_t>>>().swap(m_writeQueue);
        m_writeCv.notify_all();
    }
    // 写线程只碰 m_writeLock（fd 快照取自 m_writeLock 保护），与 m_lock 无锁序环，
    // 持 m_lock join 安全；写线程非 detach 生命周期，join 必定返回
    if (m_writeThread.joinable()) m_writeThread.join();
    m_writeThread = std::thread();
}

void Dataplane::startWriteThreadLocked(int fd) {
    {
        std::lock_guard<std::mutex> wl(m_writeLock);
        m_writeQuit = false;
        m_writeAlive = true;
        m_writeFd = fd;
    }
    m_writeThread = std::thread(&Dataplane::writeLoop, this);
}

void Dataplane::writeLoop() { // 成员函数：写线程永 join 不 detach，残窗不涉 this 生命周期
    for (;;) {
        std::vector<std::vector<uint8_t>> batch;
        {
            std::unique_lock<std::mutex> wl(m_writeLock);
            m_writeCv.wait(wl, [this] { return m_writeQuit || !m_writeQueue.empty(); });
            if (m_writeQuit) return; // shutdownNow：队列残量不消费（Kotlin execute 投递被拒同义）
            batch = std::move(m_writeQueue.front());
            m_writeQueue.pop();
        }
        int fd;
        {
            std::lock_guard<std::mutex> wl(m_writeLock);
            fd = m_writeFd; // Kotlin: val out = outputStream ?: return@execute（执行时取最新流）
        }
        if (fd < 0) continue;
        for (const std::vector<uint8_t>& p : batch) {
            // OutputStream.write 全量语义：部分写续写；失败中断整批剩余
            //（对齐 Kotlin catch IOException 后跳出 for 循环）
            size_t off = 0;
            bool failed = false;
            while (off < p.size()) {
                const ssize_t n = ::write(fd, p.data() + off, p.size() - off);
                if (n <= 0) {
                    if (n < 0 && errno == EINTR) continue;
                    failed = true; // IOException：fd 换代瞬间的写入失败可接受（下次 establish 已重排）
                    break;
                }
                off += size_t(n);
            }
            if (failed) break;
        }
    }
}

} // namespace pp
