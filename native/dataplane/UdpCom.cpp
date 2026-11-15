// UdpCom.cpp — UDP:9994 物理收发 + protect 钩子直译（A2 计划 Task 8）
//
// 直译源：tunnel/UdpCom.kt。
// 与 Kotlin 的落地差异（行为等价申报）：
//   ① DatagramSocket 构造/绑定异常在 Kotlin 侧会抛出（进程崩），brief 约定
//      「bind 失败返回 false 不崩进程」——socket 建立失败统一走 false 路径；
//   ② 阻塞 receive 的唤醒：POSIX close(2) 不唤醒他线程阻塞中的 recvfrom
//      （Kotlin 注释「close 使阻塞的 receive 抛 SocketException 退出」依赖 JVM
//      内部处理），shutdown 顺序落实为 generation+1 → 置退出标志 → shutdown(fd)
//      （唤醒阻塞读）→ close(fd) → 等待退出确认(500ms)；
//   ③ std::thread 无超时 join：join(500) 超时残窗以 GenBarrier + detach 等义；
//   ④ 端口构造参数化（默认 9994）仅 host 单测注入回环端口用，生产值不变；
//   ⑤ buf.copyOf 拷贝投递的防竞争——同步回调下 buf 为读线程局部，直接传指针
//      （Dataplane 同款申报）；
//   ⑥ recvfrom 错误分派：Kotlin 的 SocketException→break / IOException→continue
//      映射为「fd 失效（EBADF/EINVAL）即停线程，其余错误继续」；
//   ⑦ 收包循环为 static 自由函数（同 Dataplane 读循环）：fd/barrier/onPacket
//      全部按值随线程持有，detach 残窗线程不回引宿主对象——否则宿主析构后以
//      this 调用非静态成员函数即 [basic.life] UB。
#include "dataplane/UdpCom.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include "dataplane/Net.h"

namespace pp {
namespace {

// 收包循环直译（Kotlin start 内联 Thread { while (generation == gen) ... }）。
// static 自由函数：上下文全按值随线程，detach 残窗不持 this（差异⑦）。命名
// udpRecvLoop：读循环为匿名命名空间自由函数，UdpCom.h 无对应成员声明
// （与 Dataplane 的 tunReadLoop 同构）
void udpRecvLoop(int fd, std::shared_ptr<GenBarrier> barrier, UdpCom::OnPacket onPacket) {
    const size_t kBufSize = 65536; // Kotlin ByteArray(65536)
    uint8_t buf[kBufSize];
    while (!barrier->quit.load()) { // while (generation == gen)
        sockaddr_in from {};
        socklen_t fromLen = sizeof(from);
        const ssize_t n =
            ::recvfrom(fd, buf, kBufSize, 0, reinterpret_cast<sockaddr*>(&from), &fromLen);
        if (n < 0) {
            if (errno == EINTR) continue;
            // Kotlin: SocketException → break（shutdown 关闭 socket 触发）；
            // IOException → continue。fd 失效（close 后）即停线程，其余错误继续（差异⑥）
            if (errno == EBADF || errno == EINVAL) break;
            continue;
        }
        if (n == 0) continue; // pkt.length <= 0（0 长报文 / shutdown 后 EOF）
        // 拷贝后投递，避免 buf 复用竞争（对齐 iOS udpReceiveLoop）——同步回调下
        // buf 为读线程局部，直接传指针（差异⑤）
        onPacket(buf, size_t(n), dottedV4(ntohl(from.sin_addr.s_addr)), ntohs(from.sin_port));
    }
    barrier->signal();
}

} // namespace

UdpCom::UdpCom(uint16_t port) : m_port(port) {}

UdpCom::~UdpCom() { shutdown(); }

bool UdpCom::start(Protect protect, OnPacket onPacket) {
    shutdown(); // Kotlin start() 首行 shutdown()
    // Kotlin 回调参数为非空类型，无「空回调」路径；空 std::function 属调用方编程
    // 错误而非可恢复的绑定失败——不走 false（避免 A3 误报 udpBindFailed 触发重试）
    // val gen = ++generation（gen 另用于读线程代际判定，此处由 barrier->quit 承载）
    m_generation.fetch_add(1);
    const int s = ::socket(AF_INET, SOCK_DGRAM, 0); // DatagramSocket(null)
    if (s < 0) return false;                        // 差异①：Kotlin 抛异常，此处走绑定失败路径
    const int reuse = 1;
    ::setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)); // s.reuseAddress = true
    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY); // bind *:9994（不 bind 出口源 IP）
    addr.sin_port = htons(m_port);
    if (::bind(s, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(s);
        return false; // 9994 被占 → false，调用方转 Failed(udpBindFailed, recoverable)
    }
    if (!protect(s)) { // vpnService.protect(s)：bind 后立即调用
        ::close(s);
        return false; // protect 失败 → 绑定失败路径（默认路由指向自家 TUN 会环回黑洞）
    }
    m_sock.store(s);
    const std::shared_ptr<GenBarrier> barrier = std::make_shared<GenBarrier>();
    {
        std::lock_guard<std::mutex> lk(m_threadLock);
        m_barrier = barrier;
        // static 自由函数：上下文全按值随线程，detach 残窗不持 this（[basic.life]）
        m_thread = std::thread(&udpRecvLoop, s, barrier, std::move(onPacket));
    }
    return true;
}

int UdpCom::send(const std::string& remoteIp, uint16_t remotePort, const uint8_t* data,
                 size_t len) {
    const int fd = m_sock.load(); // val s = socket ?: return -1（@Volatile 快照）
    if (fd < 0) return -1;
    const auto ip = parseIpv4(remoteIp); // val host = remote.address ?: return -1
    if (!ip) return -1;
    sockaddr_in to {};
    to.sin_family = AF_INET;
    to.sin_addr.s_addr = htonl(*ip);
    to.sin_port = htons(remotePort);
    const ssize_t n =
        ::sendto(fd, data, len, 0, reinterpret_cast<const sockaddr*>(&to), sizeof(to));
    return n == static_cast<ssize_t>(len) ? 0 : -1; // IOException → -1；成功 0（sendto 语义）
}

void UdpCom::shutdown() {
    m_generation.fetch_add(1); // generation += 1
    std::shared_ptr<GenBarrier> barrier;
    std::thread t;
    {
        std::lock_guard<std::mutex> lk(m_threadLock);
        barrier = m_barrier;
        m_barrier.reset();
        t = std::move(m_thread);
        m_thread = std::thread();
    }
    if (barrier) barrier->quit.store(true); // while (generation == gen) 失效
    const int fd = m_sock.exchange(-1);     // socket = null
    if (fd >= 0) {
        ::shutdown(fd, SHUT_RDWR); // 差异②：唤醒阻塞 recvfrom
        ::close(fd);               // socket?.close()：使阻塞的 receive 抛 SocketException 退出
    }
    if (t.joinable()) {
        // join 收包线程：close 后线程可能仍在 onPacket → processWirePacket 回调内，
        // 直接放行到 node.close() 会 native UAF；join(500) 上限阻塞，停机路径可接受
        if (GenBarrier::waitFor(barrier, 500))
            t.join();
        else
            t.detach(); // 残窗：放弃等待，线程跑完自退（Kotlin join(500) 超时同义）
    }
}

} // namespace pp
