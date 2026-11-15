// Net.h — 数据面公共类型与 IP 解析/格式化（地基，Task 0）
//
// 直译源：NetworkContextMath.parseIPv4/parseIPv6/dotted（NetworkContext.kt）、
// RoutePlanner.v6String（RoutePlanner.kt）、Ethernet.kt 常量。
// 禁用 getaddrinfo/gethostbyname——解析全部手写，保持「必须含 ':' 才解析 v6」
// 的防 DNS 语义（Android 注释）。header-only（inline）， dataplane 各模块共用。
#pragma once
#include <array>
#include <cstdint>
#include <cstdio>
#include <optional>
#include <string>
#include <vector>
namespace pp {

constexpr uint16_t ETH_TYPE_IPV4 = 0x0800;
constexpr uint16_t ETH_TYPE_ARP  = 0x0806;
constexpr uint16_t ETH_TYPE_IPV6 = 0x86DD;
constexpr uint64_t BROADCAST_MAC = 0xffffffffffffULL; // 必须 ULL 字面量：负补码会截断低 48 位（Ethernet.kt 注释）

struct Ipv6Address { // 按内容判等（作 map key，对齐 NdpTable.kt）
    std::array<uint8_t, 16> bytes{};
    bool operator==(const Ipv6Address& o) const { return bytes == o.bytes; }
    bool operator!=(const Ipv6Address& o) const { return !(*this == o); }
    bool operator<(const Ipv6Address& o) const { return bytes < o.bytes; }
};

// 拒绝前导零/超 3 位/越界段（手写解析，不走 inet_aton——对齐 Kotlin 行为差异）
inline std::optional<uint32_t> parseIpv4(const std::string& s) {
    uint32_t out = 0;
    int seg = 0;
    std::string cur;
    auto flush = [&]() -> bool {
        if (cur.empty() || cur.size() > 3) return false;
        if (cur.size() > 1 && cur[0] == '0') return false; // 前导零
        int v = 0;
        for (char c : cur) {
            if (c < '0' || c > '9') return false;
            v = v * 10 + (c - '0');
        }
        if (v > 255) return false;
        out = (out << 8) | uint32_t(v);
        ++seg;
        cur.clear();
        return true;
    };
    for (char c : s) {
        if (c == '.') {
            if (!flush()) return std::nullopt;
        } else {
            cur.push_back(c);
        }
    }
    if (!flush() || seg != 4) return std::nullopt;
    return out;
}

// 必须含 ':' 才解析（防纯数字串触发 DNS）；支持 :: 缩写与内嵌 IPv4 尾段；非法返回 nullopt
inline std::optional<Ipv6Address> parseIpv6(const std::string& s) {
    if (s.find(':') == std::string::npos) return std::nullopt;
    size_t dc = s.find("::");
    bool hasDc = dc != std::string::npos;
    if (hasDc && s.find("::", dc + 1) != std::string::npos) return std::nullopt;
    std::string left = hasDc ? s.substr(0, dc) : s;
    std::string right = hasDc ? s.substr(dc + 2) : std::string();
    // 前导/尾随单冒号非法（"::" 本身除外：left/right 允许为空）
    if ((!left.empty() && (left.front() == ':' || left.back() == ':')) ||
        (!right.empty() && (right.front() == ':' || right.back() == ':')))
        return std::nullopt;

    // 每半解析为 hex 组列表；末段可为 IPv4 点分形式（展开为两组）
    auto parseHalf = [](const std::string& half, std::vector<uint16_t>& out) -> bool {
        if (half.empty()) return true;
        std::vector<std::string> parts;
        std::string cur;
        for (char c : half) {
            if (c == ':') {
                parts.push_back(cur);
                cur.clear();
            } else {
                cur.push_back(c);
            }
        }
        parts.push_back(cur);
        for (size_t i = 0; i < parts.size(); ++i) {
            const std::string& p = parts[i];
            if (p.empty()) return false;
            bool isV4 = (i + 1 == parts.size()) && p.find('.') != std::string::npos;
            if (isV4) {
                auto ip = parseIpv4(p);
                if (!ip) return false;
                out.push_back(uint16_t(*ip >> 16));
                out.push_back(uint16_t(*ip & 0xffff));
                continue;
            }
            if (p.size() > 4) return false;
            uint16_t v = 0;
            for (char ch : p) {
                char l = char(std::tolower(unsigned(ch)));
                int d;
                if (l >= '0' && l <= '9') d = l - '0';
                else if (l >= 'a' && l <= 'f') d = l - 'a' + 10;
                else return false;
                v = uint16_t((v << 4) | d);
            }
            out.push_back(v);
        }
        return true;
    };
    std::vector<uint16_t> lg, rg;
    if (!parseHalf(left, lg) || !parseHalf(right, rg)) return std::nullopt;
    size_t total = lg.size() + rg.size();
    std::vector<uint16_t> all;
    if (hasDc) {
        if (total > 7) return std::nullopt; // :: 至少展开 1 个零组
        all = lg;
        all.resize(8 - rg.size(), 0); // 中间填零
        all.insert(all.end(), rg.begin(), rg.end());
    } else {
        if (total != 8) return std::nullopt;
        all = lg;
        all.insert(all.end(), rg.begin(), rg.end());
    }
    Ipv6Address out;
    for (int i = 0; i < 8; ++i) {
        out.bytes[size_t(i) * 2] = uint8_t(all[size_t(i)] >> 8);
        out.bytes[size_t(i) * 2 + 1] = uint8_t(all[size_t(i)]);
    }
    return out;
}

inline std::string dottedV4(uint32_t ip) {
    std::string s;
    for (int i = 3; i >= 0; --i) {
        if (i < 3) s += '.';
        s += std::to_string((ip >> (8 * i)) & 0xff);
    }
    return s;
}

// 最短合法形式（:: 缩写；≥2 组连续零才缩写），手写
inline std::string formatV6(const Ipv6Address& a) {
    uint16_t g[8];
    for (int i = 0; i < 8; ++i)
        g[i] = uint16_t((a.bytes[size_t(i) * 2] << 8) | a.bytes[size_t(i) * 2 + 1]);
    int bestStart = -1, bestLen = 0;
    for (int i = 0; i < 8;) {
        if (g[i] != 0) { ++i; continue; }
        int j = i;
        while (j < 8 && g[j] == 0) ++j;
        if (j - i > bestLen) { bestLen = j - i; bestStart = i; }
        i = j;
    }
    if (bestLen < 2) bestStart = -1;
    std::string out;
    char buf[8];
    for (int i = 0; i < 8; ++i) {
        if (bestStart >= 0 && i == bestStart) {
            out += "::"; // 跳过的零 run 由 :: 表达，下一组直接拼接不再加 ':'
            i += bestLen;
            if (i >= 8) break;
            snprintf(buf, sizeof(buf), "%x", g[i]);
            out += buf;
            continue;
        }
        if (!out.empty()) out += ':';
        snprintf(buf, sizeof(buf), "%x", g[i]);
        out += buf;
    }
    return out;
}

} // namespace pp
