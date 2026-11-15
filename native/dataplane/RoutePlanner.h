// RoutePlanner.h — 路由数学与物理接口探测（A2 计划 Task 5）
//
// 直译源：RoutePlanner.kt（Android tunnel/RoutePlanner.kt，180 行）：
// IPPrefix/RouteEntry、subtract 前缀差集（挖除物理 on-link 子网）、
// expandV4/expandV6、physicalOnLinkPrefixes4/6、CIDR 换算。
// 纯函数无状态（对齐 iOS RoutePlanner）。Android 无 excludedRoutes 概念
// ——挖洞用差集展开：Builder 只会 addRoute「抓进 TUN」的前缀，差集展开后
// 物理网段自然留在物理网卡。
//
// 与 Kotlin 签名的差异（以 brief 接口为准）：
//   - expand 入参从「原始路由串」改为已拆好的 RouteEntry，出参保留 IPPrefix
//     （字节形式，供上层直接构造 Builder.addRoute）；
//   - physicalOnLinkPrefixes* 的 excludingNetworksOf 从 CIDR 串列表改为
//     IPPrefix 列表（ZT 分配地址所在网段同段跳过，防反向打断 ZeroTier）。
// 接口枚举在 host/OHOS 上以 getifaddrs(3) 对齐 NetworkInterface 语义，
// 实现见 RoutePlanner.cpp。
#pragma once
#include "Net.h"
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>
namespace pp {

/** 网络序 IP 前缀（IPv4 用 4 字节，IPv6 用 16 字节；length -1 表示无效，点对点） */
struct IPPrefix {
    std::vector<uint8_t> bytes;
    int length;

    // 按内容判等（Kotlin equals/hashCode；C++17 无 defaulted 比较，手写）
    bool operator==(const IPPrefix& o) const;
    bool operator!=(const IPPrefix& o) const;

    /** self ⊇ other（other 完全落在 self 网段内） */
    bool contains(const IPPrefix& other) const;

    /** 一分为二（二叉前缀分解用；length < 字节位数 保证不越界） */
    std::pair<IPPrefix, IPPrefix> split() const;
};

/** Builder.addRoute 直接可用的路由条目 */
struct RouteEntry {
    std::string addr; // 地址或 CIDR 串；expand/isDefaultRoute 兼容 "a.b.c.d/p via 网关" 形式（取首空格前目的段）
    int prefix;       // 前缀长度；addr 未带 "/p" 时生效（对齐 Kotlin 从串上取前缀的缺省路径）
};

namespace RoutePlanner {

// CIDR 差集展开：route 挖去 holes（物理网段）；逐 hole 递归二分分解（对齐 expandV4/V6）
std::vector<IPPrefix> expandV4(const RouteEntry& r, const std::vector<IPPrefix>& holes);
std::vector<IPPrefix> expandV6(const RouteEntry& r, const std::vector<IPPrefix>& holes);

// getifaddrs 枚举物理网段；接口名前缀限定 wlan/eth/rmnet/usb…（排除 lo/tun）；v6 跳过 fe80::；
// 点对点 prefix==-1 丢弃（contains 恒真会挖空全部路由——Android 注释的雷）
std::vector<IPPrefix> physicalOnLinkPrefixes4(const std::vector<IPPrefix>& excludingNetworksOf);
std::vector<IPPrefix> physicalOnLinkPrefixes6(const std::vector<IPPrefix>& excludingNetworksOf);

/** 0.0.0.0/0 或 ::/0（可带 " via 网关" 后缀）判默认路由 */
bool isDefaultRoute(const RouteEntry& r);

/** "fd00::/24" → 24（无前缀按 64，对齐 iOS；解析失败也按 64，对齐 Kotlin toIntOrNull） */
int prefixLen(const std::string& cidr);

/** CIDR 取 IP 段（substringBefore('/')）；无 '/' 时整串即 IP；结果为空返回 nullopt */
std::optional<std::string> ipOnly(const std::string& cidr);

} // namespace RoutePlanner
} // namespace pp
