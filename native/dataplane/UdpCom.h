// UdpCom.h — UDP:9994 物理收发 + protect 钩子直译（A2 计划 Task 8）
//
// 直译源：tunnel/UdpCom.kt（79 行）。UDP 9994 物理收发（对齐 iOS 手写 socket
// 路径；Android 不 bind 出口源 IP——protect 后内核按物理路由选源，iOS 的源 IP
// bind 是 extension 环境特例）。
//
// socket 必须 protect：establish 后默认路由指向自家 TUN，不 protect 的 socket
// 发出的 ZT 物理包会被抓回 TUN，形成环回黑洞。
#pragma once
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "Dataplane.h" // GenBarrier（本任务文件集内共用，见其头注释）

namespace pp {

class UdpCom {
public:
    // protect 钩子：NAPI 层注入（Android API≥22 用 protectProcessNet，否则
    // per-socket；OHOS 由 A3 接线对应 protect 通道）；返回 false 走绑定失败路径
    using Protect = std::function<bool(int fd)>;

    // remoteIp 为点分十进制（recvfrom 反解，Net.h dottedV4 直译 InetSocketAddress）
    using OnPacket = std::function<void(const uint8_t*, size_t, const std::string& remoteIp,
                                        uint16_t remotePort)>;

    // 端口参数化仅 host 单测注入本地回环端口用（不抢真实 9994）；生产走默认
    explicit UdpCom(uint16_t port = 9994);
    ~UdpCom(); // 终局收口走 shutdown()（Kotlin 由服务生命周期负责，C++ 补析构防线）
    UdpCom(const UdpCom&) = delete;
    UdpCom& operator=(const UdpCom&) = delete;

    // bind 失败（9994 被占）返回 false，调用方转 Failed(udpBindFailed, recoverable)
    // —— 不崩进程。socket: AF_INET SOCK_DGRAM、SO_REUSEADDR、bind *:9994；
    // protect 在 bind 后立即调用；不 bind 出口源 IP（Android 轨语义）
    bool start(Protect protect, OnPacket onPacket);

    // shutdown 顺序：generation+1 → close socket（阻塞 recv 退出）→ join(500)
    // —— 防 UAF（POSIX 落实为 shutdown 唤醒 + close 释放，见 UdpCom.cpp 差异②）
    void shutdown();

    // 发物理包（PacketSender 回调语义，ZT 原生线程调用）：0 成功 / -1 失败（sendto）
    int send(const std::string& remoteIp, uint16_t remotePort, const uint8_t* data, size_t len);

private:
    uint16_t m_port; // 生产 9994；host 单测注入回环端口
    std::atomic<int> m_generation{0};
    std::atomic<int> m_sock{-1}; // DatagramSocket? 的 fd 快照（Kotlin @Volatile socket）
    std::mutex m_threadLock;     // start/shutdown 并发下的线程句柄与屏障保护
    std::thread m_thread;        // zt-udp
    std::shared_ptr<GenBarrier> m_barrier;
};

} // namespace pp
