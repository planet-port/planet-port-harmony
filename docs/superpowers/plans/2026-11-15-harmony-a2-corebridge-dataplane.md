# Planet Port 鸿蒙版 · 计划 2（A2）：CoreBridge 完整版 + 数据面 C++ 直译 + host 金标向量单测

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. 本计划按用户指令采用**并行波次**执行：波内任务文件集严格不相交，可同时 dispatch 多个 implementer。Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Android v1.6.0 的 tunnel/ 数据面（Kotlin，17 文件 3377 行中的 C++ 归属部分）与 NodeRuntime 桥接层直译为 C++17（libplanetport_core.so 内），全部纯逻辑模块配 host 金标向量单测（gtest）。

**Architecture:** native/dataplane/（8 模块）+ native/bridge/CoreBridge.cpp 完整版。平台绑定全部抽象掉：时钟注入（NAT44）、core 帧回调注入（FrameConverter）、protect 钩子注入（UdpCom）、fd 裸 POSIX（Dataplane）。线程模型：std::thread + std::mutex（对应 Kotlin 单锁/专职线程语义）。

**Tech Stack:** C++17、ZeroTier 1.16.2 C API（ZeroTierOne.h，已在 Core/include）、gtest（FetchContent）、CMake ≥3.18。

## 直译口径（全局）

- **行为规格源 = Android v1.6.0**（20+ 数据面修复领先 iOS）；**接口签名参考 = iOS ZTBridge.mm**（C API 语义两侧同源）。冲突时以 Android 行为为准。
- 直译保真的定义：字节级行为一致（报文构造/解析/校验和/改写）、计数语义一致、锁语义一致（FrameConverter 全方法单锁）、错误码路径一致。
- Kotlin→C++ 类型映射：`UInt`→`uint32_t`（host order，绝不 network order 存储）、`Long`(MAC)→`uint64_t`、`ByteArray`→`std::vector<uint8_t>`、`ULong`(nwid/worldId)→`uint64_t`、Channel→注入回调、协程→std::thread。
- **每个模块的直译源文件路径在任务里给出，implementer 必须先读 Android 源文件再写**；本计划给出目标接口（精确签名）+ 行为要点 + 向量场景，源码细节以 Android 文件为准。

## Global Constraints

- 零补丁：`Core/` 禁改；本计划全部新文件在 `native/` 下，不改 Core/
- C++17，无异常（`-fno-exceptions` 不强制，但不得 throw 跨模块边界；错误用返回值/optional）
- 无 Android/JVM 依赖：禁 include 任何 Android 头；时间一律注入（`Clock = std::function<int64_t(void)>` 毫秒）
- host 单测必须在 macOS 直接编译运行（clang，无交叉）；同源码同时编入 OHOS 交叉目标
- 测试源 `native/tests/*.cpp` 由 CMake `file(GLOB ... CONFIGURE_DEPENDS)` 吸收——**模块任务只落文件，不改 CMakeLists**（地基任务已建 GLOB）
- 提交规范：Conventional Commits，type/scope 英文、description/Body 中文、必须 Body、禁止 Co-authored-by；git 一律 `--no-pager`；**严禁 push**
- 挂账继承（progress.md A2 桶）：CoreBridge 完整版禁止 static 缓冲返回（本次必须遵守）；napi 层错误约定留给 A3

## 文件结构（A2 终态）

```
native/
├─ dataplane/
│  ├─ Net.h                 # Ipv6Address/IP 解析格式化/Ethernet 常量（地基）
│  ├─ ByteWriter.h          # 大端流构造器（地基；Arp/Ndp 共用）
│  ├─ ArpTable.{h,cpp}      # 含 ArpPacket + request/reply/parse
│  ├─ NdpTable.{h,cpp}      # 含 NdpPacket + NS/NA + ICMPv6 校验和 + 组播工具
│  ├─ NAT44.{h,cpp}         # FlowKey + 增量校验和改写 + LRU 流表
│  ├─ NetworkContext.{h,cpp}# Context + Math（LPM 聚合/冲突检测/解析）
│  ├─ RoutePlanner.{h,cpp}  # CIDR 差集挖洞 + getifaddrs 物理网段
│  ├─ FrameConverter.{h,cpp}# IP↔帧 + LPM 转发 + pending + NAT 源改写 + 诊断
│  ├─ Dataplane.{h,cpp}     # TUN fd swap 换代 + 读写线程（POSIX）
│  └─ UdpCom.{h,cpp}        # UDP:9994 + protect 钩子 + 收发线程
├─ bridge/CoreBridge.{h,cpp}# NodeRuntime.kt 直译（完整版）
└─ tests/                   # gtest；test_<模块>.cpp 一一对应
```

## 执行波次

- **波 1（6 并行）**：Task 1 ARP、Task 2 NDP、Task 3 NAT44、Task 4 NetworkContext+Math、Task 5 RoutePlanner、Task 6 CoreBridge
- **波 2（2 并行）**：Task 7 FrameConverter（依赖波 1 的 Task 1-4 真实实现）、Task 8 Dataplane+UdpCom（仅依赖地基）
- **波 3（串行）**：Task 9 集成收尾（全量回归 + assembleHap + smoke 扩展）
- Task 0（地基）先行串行，是所有任务的公共依赖
- 每任务完成后立即并行 dispatch 对应 reviewer；波 3 前确认波内全部 review clean

---

### Task 0: 地基——公共头 + gtest + CMake 测试骨架

**Files:**
- Create: `native/dataplane/Net.h`、`native/dataplane/ByteWriter.h`
- Modify: `native/CMakeLists.txt`（gtest FetchContent + tests GLOB + host-only 测试目标）
- Test: `native/tests/test_net.cpp`、`native/tests/test_bytewriter.cpp`

**Interfaces（Produces，头文件精确内容）:**

```cpp
// native/dataplane/Net.h
#pragma once
#include <array>
#include <cstdint>
#include <optional>
#include <string>
namespace pp {
constexpr uint16_t ETH_TYPE_IPV4 = 0x0800;
constexpr uint16_t ETH_TYPE_ARP  = 0x0806;
constexpr uint16_t ETH_TYPE_IPV6 = 0x86DD;
constexpr uint64_t BROADCAST_MAC = 0xffffffffffffULL; // 必须 ULL 字面量（Android Ethernet.kt 注释：负补码会截断）

struct Ipv6Address {                       // 按内容判等（作 map key，对齐 NdpTable.kt）
    std::array<uint8_t, 16> bytes{};
    bool operator==(const Ipv6Address& o) const { return bytes == o.bytes; } // 手写：defaulted == 是 C++20
    bool operator<(const Ipv6Address& o) const { return bytes < o.bytes; }
};
// 手写解析（对齐 NetworkContextMath.parseIPv6）：必须含 ':' 才解析（防纯数字串触发 DNS）；
// 支持 :: 缩写与内嵌 IPv4 尾段；非法返回 nullopt
std::optional<Ipv6Address> parseIpv6(const std::string&);
// 对齐 NetworkContextMath.parseIPv4：拒绝前导零/超 3 位/越界段
std::optional<uint32_t> parseIpv4(const std::string&);
std::string dottedV4(uint32_t ip);         // NetworkContextMath.dotted
std::string formatV6(const Ipv6Address&);  // RoutePlanner.v6String 语义：最短合法形式（:: 缩写），禁用 getaddrinfo
}
```

```cpp
// native/dataplane/ByteWriter.h  —— 对齐 ArpTable.kt 内联 ByteWriter
#pragma once
#include <cstdint>
#include <vector>
namespace pp {
class ByteWriter {
public:
    explicit ByteWriter(size_t cap = 64) { m_buf.reserve(cap); }
    void u8(uint8_t v)  { m_buf.push_back(v); }
    void u16(uint16_t v){ m_buf.push_back(uint8_t(v >> 8)); m_buf.push_back(uint8_t(v)); }
    void u32(uint32_t v){ u16(uint16_t(v >> 16)); u16(uint16_t(v)); }
    void mac(uint64_t m){ for (int i = 5; i >= 0; --i) m_buf.push_back(uint8_t(m >> (8 * i))); }
    void ip(uint32_t v) { u8(uint8_t(v >> 24)); u8(uint8_t(v >> 16)); u8(uint8_t(v >> 8)); u8(uint8_t(v)); }
    void bytes(const uint8_t* p, size_t n) { m_buf.insert(m_buf.end(), p, p + n); }
    std::vector<uint8_t> build() { return std::move(m_buf); }
private:
    std::vector<uint8_t> m_buf;
};
}
```

**CMake 追加（host-only 分支，PP_BUILD_TESTS=ON 时）：**

```cmake
# ---- host 单测（gtest 经 FetchContent；仅非 OHOS 工具链） ----
if(PP_BUILD_TESTS AND NOT CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    include(FetchContent)
    FetchContent_Declare(googletest
        URL https://github.com/google/googletest/archive/refs/tags/v1.14.0.tar.gz)
    set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(googletest)
    file(GLOB PP_TEST_SRC CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/tests/*.cpp)
    add_executable(pp_tests ${PP_TEST_SRC}
        dataplane/ArpTable.cpp dataplane/NdpTable.cpp dataplane/NAT44.cpp
        dataplane/NetworkContext.cpp dataplane/RoutePlanner.cpp
        dataplane/FrameConverter.cpp dataplane/Dataplane.cpp dataplane/UdpCom.cpp
        bridge/CoreBridge.cpp $<TARGET_OBJECTS:zt_core>)
    target_include_directories(pp_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_link_libraries(pp_tests PRIVATE zt_core GTest::gtest_main)
    # 波 1 时部分 .cpp 尚不存在：先用 touch 占位空文件，模块任务落真实文件覆盖
endif()
```

- [ ] Step 1: 落 Net.h/ByteWriter.h + CMake 追加；对 8 个 dataplane .cpp 与 bridge/CoreBridge.cpp（已存在）逐个 `touch` 占位（若不存在），使 pp_tests 可编译链接（空 TU）
- [ ] Step 2: 写 test_net.cpp（parseIpv4：`192.168.1.1`→ok、`192.168.01.1`→nullopt、`1.2.3`→nullopt、`256.1.1.1`→nullopt；parseIpv6：`::1`/`fe80::1`/`::ffff:192.168.1.1`→ok、`12345`→nullopt；dottedV4(0xC0A80101)=="192.168.1.1"；formatV6(::1)=="::1"）与 test_bytewriter.cpp（u16/u32/mac/ip 字节序断言：mac(0xAABBCCDDEEFF)→AA BB CC DD EE FF）
- [ ] Step 3: `cmake -B native/build-tests -S native -DCMAKE_BUILD_TYPE=Debug -DPP_BUILD_SMOKE=ON -DPP_BUILD_TESTS=ON && cmake --build native/build-tests -j8 && ./native/build-tests/pp_tests` → 全 PASS
- [ ] Step 4: host smoke 回归（build-host 全新树）仍 PASS；Commit `build(dataplane): host 单测地基与公共头`

---

### Task 1: ArpTable 直译（波 1 并行）

**Files:** Create `native/dataplane/ArpTable.{h,cpp}`、`native/tests/test_arp.cpp`
**直译源（必读）:** `../planet-port-android/app/src/main/java/cn/imgozi/planetport/tunnel/ArpTable.kt`（83 行）

**Interfaces:**

```cpp
// ArpTable.h
#pragma once
#include <cstdint>
#include <optional>
#include <unordered_map>
namespace pp {
struct ArpPacket {                      // IP 一律 host order uint32_t
    uint16_t op;                        // 1=request 2=reply
    uint64_t senderMac, targetMac;
    uint32_t senderIp, targetIp;
};
class ArpTable {
public:
    std::optional<uint64_t> lookup(uint32_t ip) const;
    void update(uint32_t ip, uint64_t mac);
    size_t size() const;
private:
    std::unordered_map<uint32_t, uint64_t> m_map;
};
// RFC 826 报文：htype=1 ptype=0x0800 hlen=6 plen=4，28 字节
std::vector<uint8_t> arpRequest(uint32_t senderIp, uint64_t senderMac, uint32_t targetIp);
std::vector<uint8_t> arpReply(uint32_t senderIp, uint64_t senderMac, uint32_t targetIp, uint64_t targetMac);
std::optional<ArpPacket> parseArp(const uint8_t* payload, size_t len); // 校验头 6 字节+op∈{1,2}+len≥28
}
```

**行为要点（直译保真）:** request 的 targetMac 填 0；reply 全填；发送方 MAC/IP 在 ARP 头后紧跟。所有 16/32 位字段大端线序。
**向量场景:** ① request(10.0.0.1, MAC AA.., 10.0.0.2) 首字节 `00 01 08 00 06 04 00 01`、targetMac 段全 0、op=1；② reply 同参 op=2 targetMac 填实；③ parseArp 往返（构造→parse→字段相等）；④ parseArp 截断 27B→nullopt；⑤ op=3→nullopt；⑥ 表 lookup 未中→nullopt、update 后命中。
- [ ] 读源 → 实现 → 测试六场景 → host 跑 PASS → Commit `feat(dataplane): ArpTable 直译与向量`

### Task 2: NdpTable 直译（波 1 并行）

**Files:** Create `native/dataplane/NdpTable.{h,cpp}`、`native/tests/test_ndp.cpp`
**直译源:** `.../tunnel/NdpTable.kt`（130 行）

**Interfaces:**

```cpp
// NdpTable.h（关键静态工具一并导出，FrameConverter 依赖）
#pragma once
#include "Net.h"
namespace pp {
struct NdpPacket { uint8_t type; /*135 NS /136 NA*/ Ipv6Address target; std::optional<uint64_t> senderMac; };
class NdpTable {
public:
    std::optional<uint64_t> lookup(const Ipv6Address&) const;
    void update(const Ipv6Address&, uint64_t mac);
    size_t size() const;
private:
    std::map<Ipv6Address, uint64_t> m_map;
};
// NS：ICMPv6(4)+保留(4)+target(16)+SLL 选项(8)=32B；type=135 code=0
std::vector<uint8_t> neighborSolicitation(const Ipv6Address& target, uint64_t senderMac);
// NA：flags=0x60（Solicited+Override，单播）；DAD 场景由调用方换 dst+flags——提供 flags 参数
std::vector<uint8_t> neighborAdvertisement(const Ipv6Address& target, uint64_t senderMac, uint8_t flags);
Ipv6Address solicitedNodeMulticast(const Ipv6Address& target); // ff02::1:ffXX:XXXX（低 24 位）
Ipv6Address allNodesMulticast();                               // ff02::1
uint64_t multicastMAC(const Ipv6Address&);                     // 0x3333 + 低 32 位
// RFC 4443 §8.1 伪头校验和（src16+dst16+len32+3零+nxt=58），计算前清零 cksum 字段
uint16_t icmpv6Checksum(const Ipv6Address& src, const Ipv6Address& dst, const uint8_t* payload, size_t len);
std::optional<NdpPacket> parseNdp(const uint8_t* payload, size_t len); // ≥24B（SLL 选项可选）
bool isNDP(const std::vector<uint8_t>& ipv6Packet);           // next header==58
}
```

**行为要点:** 这是 Android 领先 iOS 的修复点（真实内核校验和，恒 0 报文被丢）——校验和实现必须严格 RFC 1071 折叠；NS 目的 = 请求节点组播（非 target 单播，RFC 4861）；NS 源 MAC 选项类型 1 长 1（8 字节单位）。
**向量场景:** ① NS(target=fe80::1, mac) 总长 32、type=135、含 SLL；② NA flags=0x60 与 0x20 各构造一次；③ solicitedNodeMulticast(fe80::1234:5678)==ff02::1:ff34:5678；④ multicastMAC(ff02::1:ff34:5678) 高 24 位==0x333333；⑤ icmpv6Checksum 对自造 NS+已知伪头 == 手算期望值（向量里写死十六进制）；⑥ parseNdp 往返 + 23B 截断 nullopt；⑦ 全零 cksum 的 NA 也能 parse（parse 不验校验和——内核已验，对齐 Android）。
- [ ] 读源 → 实现 → 七场景 → PASS → Commit `feat(dataplane): NdpTable 直译与向量`

### Task 3: NAT44 直译（波 1 并行）

**Files:** Create `native/dataplane/NAT44.{h,cpp}`、`native/tests/test_nat44.cpp`
**直译源:** `.../tunnel/NAT44.kt`（185 行）

**Interfaces:**

```cpp
// NAT44.h
#pragma once
#include <cstdint>
#include <functional>
#include <optional>
#include <unordered_map>
namespace pp {
struct FlowKey {                       // 带 nwid（根除嵌套子网串流）
    uint64_t nwid; uint8_t proto;      // 6 TCP / 17 UDP
    uint32_t remoteIp; uint16_t remotePort, localPort;
    bool operator==(const FlowKey& o) const;   // C++17：手写，defaulted == 不可用
};
struct FlowKeyHash { size_t operator()(const FlowKey&) const; };
class NAT44 {
public:
    using Clock = std::function<int64_t(void)>;   // 毫秒，注入（Android=SystemClock.elapsedRealtime）
    explicit NAT44(Clock clock) : m_clock(std::move(clock)) {}
    void record(const FlowKey&, uint32_t origSrc);
    std::optional<uint32_t> lookup(const FlowKey&);          // 命中刷新 LRU 时间
    size_t size() const;
    // 纯函数（向量测试主目标）
    static std::optional<FlowKey> outboundKey(const std::vector<uint8_t>& pkt, uint64_t nwid);
    static std::optional<FlowKey> inboundKey(const std::vector<uint8_t>& pkt, uint64_t nwid); // 方向翻转
    static bool rewriteAddress(std::vector<uint8_t>& pkt, size_t ipOffset /*12 src|16 dst*/,
                               uint32_t oldIp, uint32_t newIp);
private:
    // MAX_ENTRIES=512；IDLE_TIMEOUT_TCP=6h、UDP=60s；超限/超时逐出（对齐 Kotlin 实现）
    Clock m_clock; std::unordered_map<FlowKey, std::pair<uint32_t,int64_t>, FlowKeyHash> m_map;
};
}
```

**行为要点:** 不换端口纯地址改写；**RFC 1624 增量校验和** `HC' = ~(~HC + ~m + m')`；UDP cksum==0（卸载）保持 0 不修、非 0 按 zeroAsFFFF（RFC 768，校验和字段覆盖 0xFFFF 位）；**非首片（片偏移≠0）只修 IP 头校验和**（其后是载荷非 L4 头）；ICMP 不改写；分片包不进流表。
**向量场景:** ① 构造 TCP SYN 包（伪头写死）→ outboundKey 字段断言 → rewriteAddress(12, old, new) 后 IP 头校验和按 RFC 1624 重算一致（向量给期望十六进制）；② UDP cksum=0 改写后仍 0；③ UDP cksum≠0 改写后正确；④ 非首片（flags MF+off≠0）只修 IP 头；⑤ inboundKey 是 outboundKey 的翻转；⑥ record+固定时钟前进 61s 后 UDP 流 lookup 未中、59s 命中；⑦ TCP 流 6h 边界；⑧ 513 条流上限逐出（固定时钟）。
- [ ] 读源 → 实现 → 八场景 → PASS → Commit `feat(dataplane): NAT44 直译与向量`

### Task 4: NetworkContext + Math 直译（波 1 并行）

**Files:** Create `native/dataplane/NetworkContext.{h,cpp}`、`native/tests/test_networkcontext.cpp`
**直译源:** `.../tunnel/NetworkContext.kt`（192 行）

**Interfaces:**

```cpp
// NetworkContext.h
#pragma once
#include "ArpTable.h"
#include "NdpTable.h"
#include <map>
#include <optional>
#include <string>
#include <vector>
namespace pp {
struct IPv4RouteEntry { uint32_t network; int prefix; std::optional<uint32_t> gateway; bool matches(uint32_t) const; };
struct IPv6RouteEntry { Ipv6Address network; int prefix; std::optional<Ipv6Address> gateway; bool matches(const Ipv6Address&) const; };
struct AggregateV4Entry { uint64_t nwid; IPv4RouteEntry route; };
struct AggregateV6Entry { uint64_t nwid; IPv6RouteEntry route; };
struct PendingQueue;   // FrameConverter 任务定义；此处仅前向声明 + unique_ptr
class NetworkContext {
public:
    NetworkContext(uint64_t nwid, uint64_t mac,
                   const std::vector<std::string>& ipv4s, const std::vector<std::string>& ipv6s,
                   const std::vector<std::string>& routes);
    // 仅刷新 MAC/地址/路由——ARP/NDP/pending 跨回调保留（Android 注释：整建重建=ARP 风暴+丢待决包）
    void update(uint64_t mac, const std::vector<std::string>& ipv4s,
                const std::vector<std::string>& ipv6s, const std::vector<std::string>& routes);
    uint64_t nwid; uint64_t mac;
    std::vector<uint32_t> ipv4;                  // 解析后 host order
    std::vector<Ipv6Address> ipv6;
    std::vector<IPv4RouteEntry> routes4;         // 自身地址网段 + managed routes，前缀降序
    std::vector<IPv6RouteEntry> routes6;
    ArpTable arp; NdpTable ndp;
    std::unique_ptr<PendingQueue> pendingV4, pendingV6;   // 每个 ≤16 包/下一跳
    // 诊断字段（语义对齐 NetworkContext.kt）
    uint64_t statFwdV4=0, statArpReq=0, statArpReply=0, statInV4=0, statKeepalive=0,
             statNatOut=0, statNatIn=0, statSrcMismatch=0;
    std::optional<uint32_t> lastSrcMismatch;
};
namespace NetworkContextMath {
inline constexpr const char* CONFLICT_ADDRESS = "address";   // 实际值对齐 Kotlin 常量
inline constexpr const char* CONFLICT_SUBNET  = "subnet";
// 先到者登记，后进者撞车标记冲突且不登记；地址冲突优先于网段冲突
std::map<uint64_t, std::string> detectConflicts(const std::vector<std::tuple<uint64_t,
    const std::vector<uint32_t>*, const std::vector<Ipv6Address>*>>& ordered);
std::vector<AggregateV4Entry> buildAggregateV4(const std::vector<const NetworkContext*>& ordered);
std::vector<AggregateV6Entry> buildAggregateV6(const std::vector<const NetworkContext*>& ordered);
// "x/p via g" 解析；via 缺失/family=0/全零 → nullopt gateway
std::optional<IPv4RouteEntry> parseIPv4Route(const std::string&);
std::optional<IPv6RouteEntry> parseIPv6Route(const std::string&);
std::optional<std::string> ipOnly(const std::string&);   // "a.b.c.d/24"→"a.b.c.d"
}
}
```

**PendingQueue 定义（放在 NetworkContext.h 尾部，FrameConverter 共用）:**

```cpp
struct PendingQueue {
    // key=下一跳 IP；值=待发帧；MAX_PENDING_PER_TARGET=16 满则丢最旧（对齐 FrameConverter.kt）
    std::map<uint32_t, std::vector<std::vector<uint8_t>>> v4;
    std::map<Ipv6Address, std::vector<std::vector<uint8_t>>> v6;
    size_t total() const;
};
```

**向量场景:** ① update() 二次调用后 arp 表内容保留（先 update(ip,mac) 再 update() 断言 arp.lookup 命中）；② buildAggregateV4：两网络各带路由 + 各自地址网段 → 输出前缀降序、同前缀先到者胜；③ detectConflicts：两网同 IP→后者标 address 冲突且不登记；同网段不同 IP→subnet 冲突；地址优先于网段（同时撞时标 address）；④ parseIPv4Route("10.0.0.0/24 via 10.0.0.1") gateway==10.0.0.1；"10.0.0.0/24 via 0.0.0.0"→gateway nullopt；⑤ matches：/24 边界地址、/0 恒真、/32 恒等。
- [ ] 读源 → 实现 → 五场景 → PASS → Commit `feat(dataplane): NetworkContext 与聚合数学直译`

### Task 5: RoutePlanner 直译（波 1 并行）

**Files:** Create `native/dataplane/RoutePlanner.{h,cpp}`、`native/tests/test_routeplanner.cpp`
**直译源:** `.../tunnel/RoutePlanner.kt`（180 行）

**Interfaces:**

```cpp
// RoutePlanner.h
#pragma once
#include "Net.h"
#include <optional>
#include <string>
#include <utility>
#include <vector>
namespace pp {
struct IPPrefix {
    std::vector<uint8_t> bytes; int length;   // bytes 尺寸=4 或 16；length -1 表示无效（点对点）
    bool contains(const IPPrefix&) const;
    std::pair<IPPrefix, IPPrefix> split() const;
};
struct RouteEntry { std::string addr; int prefix; };
namespace RoutePlanner {
// CIDR 差集展开：route 挖去 holes（物理网段）；逐 hole 递归二分分解（对齐 expandV4/V6）
std::vector<IPPrefix> expandV4(const RouteEntry&, const std::vector<IPPrefix>& holes);
std::vector<IPPrefix> expandV6(const RouteEntry&, const std::vector<IPPrefix>& holes);
// getifaddrs 枚举物理网段；接口名前缀限定 wlan/eth/rmint/usb…（排除 lo/tun）；v6 跳过 fe80::；
// 点对点 prefix==-1 丢弃（contains 恒真会挖空全部路由——Android 注释的雷）
std::vector<IPPrefix> physicalOnLinkPrefixes4(const std::vector<IPPrefix>& excludingNetworksOf);
std::vector<IPPrefix> physicalOnLinkPrefixes6(const std::vector<IPPrefix>& excludingNetworksOf);
bool isDefaultRoute(const RouteEntry&);       // 0.0.0.0/0 或 ::/0
int prefixLen(const std::string& cidr);       // 缺省 v4→32? 对齐 Kotlin：缺省按族（IPv6→64）
std::optional<std::string> ipOnly(const std::string&);
}
}
```

**行为要点:** `excludingNetworksOf` = ZT 分配地址所在网段同段跳过（防反向打断 ZT 路由）；差集分解是 split 二叉树减法；expandV6 的 holes 同构。
**向量场景（host 可测——getifaddrs 在 macOS 真实返回 lo0/en0）:** ① expandV4("0.0.0.0/0", holes=[192.168.1.0/24]) 输出为 /1..的前缀集合，并集 ⊇ 全空间减 hole、且无一包含 hole（用 contains 验证 hole 不被任何输出包含、输出互不相交、并集测若干采样点）；② expandV4 无 holes → 原样单元素；③ split() 的两半互斥且并集=父；④ isDefaultRoute 两侧族；⑤ physicalOnLinkPrefixes4 在 macOS 上必含 en0 网段且不含 lo0（127.0.0.0/8）——断言非空 + 无 127/8。
- [ ] 读源 → 实现 → 五场景 → PASS → Commit `feat(dataplane): RoutePlanner 差集挖洞直译`

### Task 6: CoreBridge 完整版直译（波 1 并行）

**Files:** Modify `native/bridge/CoreBridge.{h,cpp}`（替换现有最小骨架，coreVersion/smokeIdentityGen 语义保留——smokeIdentityGen 可重构为 CoreBridge 内部能力）；Create `native/tests/test_corebridge.cpp`
**直译源（两份必读）:** `.../tunnel/NodeRuntime.kt`（388 行，行为规格）+ `../planet-port-ios/ZTBridge/ZTBridge.mm`（523 行，接口参考）+ `Core/include/ZeroTierOne.h`（C API 事实）

**Interfaces:**

```cpp
// CoreBridge.h
#pragma once
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>
namespace pp {
struct NetConf {                              // 对齐 NodeRuntime.NetConf
    uint64_t nwid; std::string name; int status; std::string type;
    uint64_t mac; int mtu; bool broadcastEnabled, bridge, dhcp;
    std::vector<std::string> assignedAddrs;   // "ip/prefix"
    std::vector<std::string> routes;          // "dest/prefix[ via gw]"
    std::vector<std::string> dns;
};
struct PeerInfo { uint64_t address; std::string version; int latency; std::string role; /*LEAF/MOON/PLANET*/ };
struct WireEndpoint { std::string ip; uint16_t port; };   // 物理端点（UDP 收包上报）

class CoreBridge {
public:
    // 回调注入（对齐 Kotlin Channel 投递语义：回调线程只做投递，禁止阻塞/锁等待）
    struct Hooks {
        std::function<void(uint64_t nwid, uint64_t srcMac, uint64_t dstMac, uint16_t etherType,
                           uint16_t vlanId, const uint8_t* frame, size_t len)> onFrame;
        std::function<void(uint64_t nwid, int op, const NetConf&)> onNetConf;   // op=ZT VirtualNetworkConfigOperation
        std::function<void(int event)> onEvent;                                 // ONLINE/OFFLINE/FATAL...
        std::function<void(const PeerInfo*, size_t)> onPeers;                    // 快照批量
        std::function<int(const uint8_t* data, size_t len, const WireEndpoint&)> sendPacket; // 0 成功/-1 失败
    };
    CoreBridge(std::string dataStoreRoot, std::string planetDir,
               std::string planetFile /*可空*/, bool identityPerPlanet);
    bool start();                // @Synchronized 语义；Node 创建→init→processBackgroundTasks 立即驱动一次
    void shutdown();             // 先停驱动线程 join，再 node close（防 UAF），全程持锁
    // 控制面（等价 NodeRuntime 同名方法）
    void join(uint64_t nwid); void leave(uint64_t nwid);
    void orbit(uint64_t moonWorldId, uint64_t seed); void deorbit(uint64_t moonWorldId);
    void multicastSubscribe(uint64_t nwid, uint64_t multicastGroup, uint64_t multicastAdi);
    std::optional<uint64_t> address();         // 10 位 hex 的整数值源（40 位地址）
    static const char* version();
    // 数据面入口（UDP 收包 / TUN 帧上行）
    bool processWirePacket(const uint8_t* data, size_t len, const WireEndpoint&);
    void processVirtualNetworkFrame(uint64_t nwid, uint64_t srcMac, uint64_t dstMac,
                                    uint16_t etherType, uint16_t vlanId, const uint8_t* frame, size_t len);
    std::optional<NetConf> networkConf(uint64_t nwid);
    std::vector<PeerInfo> peersNow();
private:
    // stateFile 重定向表（对齐 NodeRuntime.stateFile 分流）：
    //   identity.public/secret → identityPerPlanet ? planetDir/ : dataStoreRoot/
    //   planet → planetFile 非空则用之，否则 dataStoreRoot/planet
    //   moons.d/ networks.d/ peers.d/ 前缀 → planetDir/
    //   其它 → nullopt（stateGet 返回 -1）
    std::optional<std::string> stateFile(const std::string& name);
    static void putFileAtomic(const std::string& path, const uint8_t* data, size_t len,
                              bool secure /*true 或 identity.secret → 0600*/);   // .tmp→rename，失败删 tmp
    struct Impl; std::unique_ptr<Impl> m_impl;   // ZT_Node* 与驱动线程藏在 Impl（头文件不引 ZeroTierOne.h）
};
}
```

**行为要点（直译保真，全部来自 NodeRuntime.kt）:**
- start：`ZT_Node_new`（Callbacks 结构体，version=0，config 零初始化）→ 失败 close 返 false → **立即 processBackgroundTasks 一次**（身份生成在此发生）→ 起驱动线程
- 驱动线程：`ZT_Node_processBackgroundTasks` 循环，wait = clamp(deadline-now, 50, 100) ms；rc≠OK → 退出（错误经 Hooks 语义上报）；跨线程调 ZT_* 必须"外部序列化"——驱动线程之外的控制面调用持同一把大锁
- shutdown：先停驱动线程（join，超时 500ms 兜底）→ `ZT_Node_delete`；全程持锁
- 状态写回调：原子写 + secure/identity.secret→0600；stateGet 用 stateFile 映射，nullopt→-1
- netconf 回调过滤：UP(1)/CONFIG_UPDATE(2) 全量投递（首网络走 UP，仅认 CONFIG_UPDATE 会漏首网）；DOWN(3)/DESTROY(4) 不投 netconf 快照（对齐 TunnelManager 拒收，但事件仍上报）
- toNetConf：SDK prefix 装在 InetSocketAddress port 的语义在 C API 是 `ZT_VirtualNetworkRoute.target` 的 `bits`（/位数）+ `via` family=0 即无网关
- **禁止 static 缓冲**（A2 挂账红线）：所有返回经参数/值传递
- virtual frame 回调进入时**只做 Hooks 投递**（不得在回调线程做 ARP 等处理——那是 FrameConverter 在自己线程做的事）

**测试策略（host，无网络）:** gtest 里起 CoreBridge（dataStoreRoot=tmpdir）→ start() → 轮询 Hooks.onEvent 等 ONLINE 不可行（无网络）——**测可控面**：① start 后 address() 非零（身份生成即地址非 0）；② identity.secret 落在 dataStoreRoot 且 0600；③ identityPerPlanet=true 时落 planetDir；④ 二次 start（先 shutdown）地址不变（身份复用）；⑤ stateFile 映射单测（moons.d/x → planetDir；planet → planetFile）；⑥ putFileAtomic 失败路径（只读目录）不残留 .tmp。
- [ ] 读两份源 + ZeroTierOne.h → 实现 → 六场景 → PASS → host smoke 回归（现有 smoke_main 仍 PASS，必要时适配新 CoreBridge 接口）→ Commit `feat(bridge): CoreBridge 完整版直译（NodeRuntime 规格对齐）`

### Task 7: FrameConverter 直译（波 2 并行，依赖 Task 1-4 实现）

**Files:** Create `native/dataplane/FrameConverter.{h,cpp}`、`native/tests/test_frameconverter.cpp`
**直译源:** `.../tunnel/FrameConverter.kt`（361 行，最大件）+ `.../tunnel/TunnelManager.kt` 的聚合调用序（仅理解用途）

**Interfaces:**

```cpp
// FrameConverter.h
#pragma once
#include "NetworkContext.h"
#include <map>
#include <mutex>
#include <string>
namespace pp {
class FrameConverter {
public:
    // core 帧上送注入（CoreBridge::processVirtualNetworkFrame 直连，tun→core 方向；
    // Hooks.onFrame 是 core→tun 反向回调，两者签名恰好相同不可混接——onFrame 须
    // 入队消费，直调 handleFrameFromCore 会形成 ABBA 死锁）
    using CoreSend = std::function<void(uint64_t nwid, uint64_t srcMac, uint64_t dstMac,
                                        uint16_t etherType, uint16_t vlanId, const uint8_t*, size_t)>;
    explicit FrameConverter(CoreSend coreSend);
    // 上下文管理（TunnelManager 调用）
    void updateNetworkInfo(uint64_t nwid, bool enabled, uint64_t mac,
                           const std::vector<std::string>& ipv4, const std::vector<std::string>& ipv6,
                           const std::vector<std::string>& routes);
    void removeNetwork(uint64_t nwid);
    void retainOnly(const std::vector<uint64_t>& nwids);
    // 数据面
    void handlePacketsFromTun(const std::vector<std::vector<uint8_t>>& packets);  // <20B 跳过，按 IP 版本分流
    // 返回应写 TUN 的 IP 包（调用方=Dataplane 消费线程）
    std::vector<std::vector<uint8_t>> handleFrameFromCore(uint64_t nwid, uint64_t srcMac,
                                                          uint64_t dstMac, uint16_t etherType,
                                                          const uint8_t* frame, size_t len);
    void sendKeepalive();                     // 每活跃网广播 ARP 探测（statKeepalive）
    std::string debugSummary();               // 格式对齐 FrameConverter/TunnelStateBus（见下）
private:
    std::mutex m_lock;                        // 全方法持单一锁（对齐 iOS NSLock 语义）
    // tun→core v4：广播/组播→全网泛发（组播 MAC=低 23 位最高位清零）→ LPM（first match，无命中 statNoRoute++）
    //   → 多网络源地址 NAT（源不在本网且是本机另一网地址→改写+登记；外来地址→statSrcMismatch 不改写）
    //   → nextHop=gateway?:dst → ARP 查表，未中 pending(≤16)+发 ARP 请求
    // v6 同构：NS 目的=请求节点组播，源=本机真实接口地址
    // core→tun：ARP op1 target 属本网→reply；op2→更新表+冲刷 pendingV4；NDP 同构（DAD 判别：源 ::→
    //   NA 用 allNodesMulticast+flags 0x20；普通 NS→单播+0x60）
    CoreSend m_coreSend;
    std::map<uint64_t, std::unique_ptr<NetworkContext>> m_contexts;
    std::vector<AggregateV4Entry> m_aggV4;    // updateNetworkInfo 后由 Math 重建
    std::vector<AggregateV6Entry> m_aggV6;
    uint64_t m_statNoRoute = 0;
};
}
```

**debugSummary 输出格式（跨端排查心智对齐）:**
```
contexts=N aggV4=N aggV6=N 无路由丢弃=N NAT流表=N
ctx <nwid16hex> mac=<mac12hex> v4=[a.b.c.d,...] routes=n/m 出站=N 入站=N ARP问=N ARP答=N
保活=N ARP表=N 待决=N 源不符=N(x.x.x.d) NAT出=N NAT入=N
```
**向量场景（host 全链——CoreSend 记录到 vector 断言）:** ① 上下文 A(10.1.0.1/24 gw 10.1.0.254) 装载 → TUN 注入 `10.1.0.99` 的包 → 收到 ARP request（statArpReq=1、pending 记录）→ 伪造 ARP reply 上行 → core 收到原帧（泛发路径）；② 多网络 NAT：网 A/B 装载，TUN 注源=B 地址经网 A 路由的包 → 帧源 IP 被改写为 A 地址（statNatOut=1）→ 注回包（远程→改写后地址）→ 还原为 B 地址写 TUN（statNatIn=1）；③ 源不符：源=陌生 IP → 不改写、statSrcMismatch=1、lastSrcMismatch 记录；④ 无路由：目的不属任何网 → statNoRoute=1、core 不收帧；⑤ 广播：dst=255.255.255.255 → 全活跃网泛发；⑥ v6 链路：NDP NS→NA 回复（DAD 与普通两分支 flags 断言）+ solicited node 组播目的 MAC；⑦ retainOnly 清理后 debugSummary 规模正确；⑧ sendKeepalive 每活跃网发 ARP（statKeepalive=网数）。
- [ ] 读源 → 实现 → 八场景 → PASS → Commit `feat(dataplane): FrameConverter 直译与转发向量`

### Task 8: Dataplane + UdpCom 直译（波 2 并行，仅依赖地基）

**Files:** Create `native/dataplane/Dataplane.{h,cpp}`、`native/dataplane/UdpCom.{h,cpp}`、`native/tests/test_dataplane_udp.cpp`
**直译源:** `.../tunnel/Dataplane.kt`（125 行）+ `.../tunnel/UdpCom.kt`（79 行）+ `.../core/jni/ZT_tunfd.cpp`（33 行）

**Interfaces:**

```cpp
// Dataplane.h —— TUN fd 换代（swap 语义是热重配核心，D3）
#pragma once
#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
namespace pp {
class Dataplane {
public:
    using TunPacket = std::function<void(const uint8_t*, size_t)>;
    explicit Dataplane(TunPacket onTunPacket);
    bool swap(int fd);            // stopped 闩锁拒绝迟到 swap（关新 fd 返 false）；
                                  // gen+1 → 停旧读线程 → 关旧 fd → join(500ms) →
                                  // fcntl 清 O_NONBLOCK（失败读循环退避轮询兜底）→ 起新读线程
    void writePackets(const std::vector<std::vector<uint8_t>>&);  // 专职写线程顺序化；停机中静默丢包
    void teardownTun();           // 不带闩锁（teardown≠终局）
    void shutdown();              // 闩锁+teardown
    int generation() const;
private:
    // 读线程 buf 65536；host 单测用 socketpair fd 模拟 TUN
    std::mutex m_lock; std::atomic<bool> m_stopped{false}; std::atomic<int> m_gen{0};
    TunPacket m_onPacket;
    /* 读线程句柄 + fd + 写队列（专职写线程，命名 zt-tun-write-$gen 语义） */
};
}

// UdpCom.h —— UDP:9994 + protect 钩子（D4 双轨的 Android 轨规格源）
#pragma once
#include <functional>
#include <string>
namespace pp {
class UdpCom {
public:
    // protect 钩子：NAPI 层注入（API≥22 用 protectProcessNet，否则 per-socket）；返回 false 走绑定失败路径
    using Protect = std::function<bool(int fd)>;
    using OnPacket = std::function<void(const uint8_t*, size_t, const std::string& remoteIp, uint16_t remotePort)>;
    // bind 失败（9994 被占）返回 false，调用方转 Failed(udpBindFailed, recoverable) —— 不崩进程
    bool start(Protect protect, OnPacket onPacket);
    // shutdown 顺序：generation+1 → close socket（阻塞 recv 退出）→ join(500) —— 防 UAF
    void shutdown();
    int send(const std::string& remoteIp, uint16_t remotePort, const uint8_t* data, size_t len); // 0/-1
private:
    // socket: AF_INET SOCK_DGRAM, SO_REUSEADDR, bind *:9994, protect 在 bind 后立即调用；
    // 不 bind 出口源 IP（Android 轨语义：protect 后内核按物理路由选源）
};
}
```

**行为要点:** Dataplane.swap 与 UdpCom 生命周期解耦（swap 换代不影响 UDP socket）；UdpCom 的 PacketSender 语义 = `send→0/-1`；TUN fd 在 OHOS 由 VpnExtensionAbility 的 TUN fd 传入（A3 接线），本任务只做 fd 无关的 POSIX 层。
**向量场景（host 用 socketpair/localhost UDP 真实测）:** ① Dataplane：socketpair fd swap → 写端写包 → onTunPacket 收到（读线程活）；再 swap 新 fd → 旧 fd 数据不再来、新 fd 来（换代生效）；swap 后 writePackets 落到新 fd；teardownTun 后 swap 仍可用（无闩锁）；shutdown 后 swap 返 false（闩锁）且 close 新 fd；② UdpCom：start（protect 恒 true）→ 本机另一 socket 发 9994 → OnPacket 收到（127.0.0.1）；send 回发对端收到；protect 返 false → start 失败；9994 占用（先绑一个）→ start 失败返 false；shutdown 后收包线程退出（join 完成）。
- [ ] 读源 → 实现 → 场景 → PASS → Commit `feat(dataplane): TUN 换代与 UDP protect 钩子直译`

### Task 9: 集成收尾（波 3 串行）

**Files:** Modify `native/CMakeLists.txt`（清理 Task 0 占位 touch 注释）、`native/smoke/smoke_main.cpp`（可选：身份断言改走 CoreBridge 新接口）、`docs/build-notes.md`（A2 事实）、`README.md`（单测命令）

- [ ] Step 1: 全量回归：`rm -rf native/build-tests && cmake -B native/build-tests -S native -DCMAKE_BUILD_TYPE=Debug -DPP_BUILD_SMOKE=ON -DPP_BUILD_TESTS=ON && cmake --build native/build-tests -j8 && ./native/build-tests/pp_tests && ./native/build-tests/smoke` → 全 PASS（pp_tests 含全部模块 gtest + smoke 身份链路）
- [ ] Step 2: OHOS 交叉编译回归：build-ohos 全新树（Task 4b 命令）通过——dataplane 源编入 .so（CMake GLOB/源集已含）
- [ ] Step 3: assembleHap 回归（DEVECO_SDK_HOME + hvigorw）BUILD SUCCESSFUL 且 HAP 含 .so
- [ ] Step 4: build-notes 增补 A2 段（直译范围/向量覆盖/getifaddrs 在 musl 的注意点如有）；README 补单测命令
- [ ] Step 5: Commit `build: A2 数据面集成回归与文档`；ledger 记录；整分支 review（opus）

---

## Self-Review 记录

- 覆盖：规格 §2 数据面清单（FrameConverter/ARP/NDP/NAT44/LPM/TUN+swap/UDP）+ D11 身份分流（CoreBridge stateFile）+ D13 host 单测标准 ✅；store 层/TunnelManager/VpnExt/TunnelController/NAPI 扩展 → A3/A4（D14 隔离面外）✅
- 波次依赖：Task 7 依赖 1-4（真实 .cpp 链接）；Task 6/8 仅依赖地基 → 与 1-5 同波 ✅
- 类型一致性：Ipv6Address/FlowKey/NetConf/AggregateV*Entry 跨任务引用一致；PendingQueue 定义唯一（Task 4）✅
- 冲突面：模块任务仅新建自有文件 + tests/test_*.cpp；CMakeLists 仅 Task 0/9 触碰 ✅
