// planetport NAPI 绑定 — 控制流与状态流入口（不过包，规格 D2；A3 Task 9 完整函数族）
//
// 三函数族（D2 粗粒度决策；D14 隔离面：本文件是 VpnExt 进程内 C++ 编排与 ArkTS
// 壳之间的唯一通道，壳只见 string/number/boolean/回调，不见任何 C++ 类型）：
//   CoreRuntime — getCoreVersion
//   ColorMath   — accentLight/accentDark/successLight/successDark/planetTints/hslOf
//   TunnelNapi  — start/stop/restartCore/swapFd/applyConfig/setPathSatisfied/snapshot
//                 + setCallbacks/setProtectHandler/protectFd/protectResult
//                 （protectFd 为 native 内部 tsfn 目标，exports 保留供调试，
//                  ArkTS 包装层不声明——壳勿在 CoreRuntime.ets 找它）
// ArkTS 侧声明同源文件：entry/src/main/ets/common/CoreRuntime.ets（禁改键名）。
//
// smokeIdentityGen 不进 NAPI 面：host 冒烟走 smoke 可执行（smoke/smoke_main.cpp），
// 符号经 bridge/CoreBridge.cpp 编入本 .so 保留。
//
// ========================== 硬契约（评审传递，T10 壳实现依赖，禁改） ==========================
// ① swapFd(fd) 返回 false 时，fd 已被 Dataplane 闩锁分支关闭（A2 Dataplane::swap
//    拒绝即关 fd）——调用方一律不得再 close，double-close 是真实风险。返回 true =
//    runtime 已接管 fd（换代时旧 fd 由 runtime close）。
// ② 回调 onEstablish/onTeardown/onStateChanged（brief 的 onSnapshotUpdate 落位为
//    onStateChanged——壳择机拉 snapshot 落盘 + 发事件，level-triggered）经
//    napi_threadsafe_function 跨线程投递到 JS 线程；队列无界（max_queue_size=0）、
//    非阻塞投递，仅在 tsfn 正在关闭时可能拒投并丢弃本条（onStateChanged 语义允许）。
//    壳必须容忍停机排空窗口内的迟到 onEstablish：stop 后队列残留的最后一次聚合仍会
//    送达，壳内 create/swapFd 按幂等失败处理即可，native 不代为拦截。
// ③ protect 路径同步等待（std::promise/future，超时 2s）：默认放行（宁通勿断，对齐
//    Android 兜底）。壳未注册处理器时（默认态）投递无人应答 → 恒走 2s 超时放行，
//    壳另以进程级 protectProcessNet 一次调用兜底（Global Constraints UNVERIFIED-1
//    的最稳假设）。已知代价：start() 在 JS 线程执行，而 UdpCom::start→protect 是
//    start 调用链上的同步段——JS 线程被阻塞，tsfn 回调无法及时执行，故每次启动的
//    首个 protect 必然等满 2s 后放行。这是「同步等待」设计的固有成本，不是缺陷；
//    Task 10 壳不要为此另开线程。超时放行后，迟到的 Protect 任务仍会在 JS 线程
//    空闲时送达壳处理器（对已放行 fd 补保护，幂等无害；此时壳调 protectResult
//    会因 token 已摘除而被忽略）——壳不得假设「超时后处理器不再被调」。
// ④ setCallbacks 为壳一次性注册（VpnExt 进程生命周期内复用）：stop() 不释放 tsfn，
//    stop/start 重入仍可投递；重复 setCallbacks 会先释放旧束再装新束（非主路径）。
// ⑤ 进程级单例：TunnelRuntime 实例全进程唯一（g_runtime）。VpnExt 进程专用——主
//    进程不得调用 TunnelNapi 族（会白装配一份 runtime，主进程无隧道职责）。
//
// ============================== JSON 契约（字段名即契约，禁改） ==============================
// start/applyConfig 入参（ArkTS 从 store 读出后组串；缺 dataStoreRoot → throw）：
//   {
//     "dataStoreRoot": "...",            // 必填，filesDir/zt
//     "planetDir": "...",                // activePlanetId 行星状态目录
//     "planetFile": "...",               // planets/<uuid>.planet 全路径；空 = 官方
//     "identityPerPlanet": false,
//     "disableIpv6": false,
//     "networks": [ { "nwid": "0123456789abcdef",       // 16 位 hex（亦容十进制串/数值）
//                     "routeViaZeroTier": false } ],
//     "moons":     [ { "worldId": 199, "seed": 6996 } ] // 数值或字符串（十进制/0x hex）
//   }
// onEstablish 出参（跨线程传对象一律字符串化，解析在 ArkTS 包装层 CoreRuntime.ets）：
//   { "v4Addrs": ["ip/prefix", ...], "v6Addrs": [...],
//     "routes4": ["dest/prefix", ...], "routes6": [...], "dns": [...], "mtu": 28000 }
// snapshot() 返回 TunnelSnapshot 契约 JSON（键名对齐 TunnelContract.ets，禁改；
// 不含 pathSatisfied/writtenAt——写方注入）。

#include "napi/native_api.h"
#include <hilog/log.h>

#include "bridge/CoreBridge.h"
#include "runtime/TunnelRuntime.h"
#include "theme/ColorMath.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <future>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr unsigned int kLogDomain = 0x3200;
constexpr const char *kLogTag = "PlanetPortNapi";
// protect 同步等待上限：宁通勿断（对齐 Android 兜底；UNVERIFIED-1 最稳假设）
constexpr int64_t kProtectTimeoutMs = 2000;

// ================================ 基础 NAPI 助手 ================================

napi_value Undefined(napi_env env)
{
    napi_value v = nullptr;
    napi_get_undefined(env, &v);
    return v;
}

napi_value MakeStr(napi_env env, const std::string &s)
{
    napi_value v = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &v);
    return v;
}

napi_value MakeU32(napi_env env, uint32_t v)
{
    napi_value r = nullptr;
    napi_create_uint32(env, v, &r);
    return r;
}

napi_value MakeI32(napi_env env, int32_t v)
{
    napi_value r = nullptr;
    napi_create_int32(env, v, &r);
    return r;
}

napi_value MakeDouble(napi_env env, double v)
{
    napi_value r = nullptr;
    napi_create_double(env, v, &r);
    return r;
}

napi_value MakeBool(napi_env env, bool v)
{
    napi_value r = nullptr;
    napi_get_boolean(env, v, &r);
    return r;
}

// 取齐 want 个入参；不足即 throw TypeError（调用方返回 nullptr 使异常上抛）
bool ArgsOf(napi_env env, napi_callback_info info, size_t want, napi_value *argv)
{
    size_t argc = want;
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok) return false;
    if (argc < want) {
        napi_throw_type_error(env, nullptr, "missing argument");
        return false;
    }
    return true;
}

bool ArgStr(napi_env env, napi_callback_info info, std::string &out)
{
    napi_value argv[1];
    if (!ArgsOf(env, info, 1, argv)) return false;
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, argv[0], &t) != napi_ok || t != napi_string) {
        napi_throw_type_error(env, nullptr, "expected string");
        return false;
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len) != napi_ok) return false;
    out.assign(len, '\0');
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, argv[0], out.data(), len + 1, &copied) != napi_ok) return false;
    out.resize(copied);
    return true;
}

// uint32 入参（ColorMath 主色等）
bool ArgU32(napi_env env, napi_callback_info info, uint32_t &out)
{
    napi_value argv[1];
    if (!ArgsOf(env, info, 1, argv)) return false;
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, argv[0], &t) != napi_ok || t != napi_number) {
        napi_throw_type_error(env, nullptr, "expected number");
        return false;
    }
    if (napi_get_value_uint32(env, argv[0], &out) != napi_ok) {
        napi_throw_type_error(env, nullptr, "expected uint32");
        return false;
    }
    return true;
}

bool ArgI32(napi_env env, napi_callback_info info, int32_t &out)
{
    napi_value argv[1];
    if (!ArgsOf(env, info, 1, argv)) return false;
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, argv[0], &t) != napi_ok || t != napi_number) {
        napi_throw_type_error(env, nullptr, "expected number");
        return false;
    }
    if (napi_get_value_int32(env, argv[0], &out) != napi_ok) {
        napi_throw_type_error(env, nullptr, "expected int32");
        return false;
    }
    return true;
}

bool ArgBool(napi_env env, napi_callback_info info, bool &out)
{
    napi_value argv[1];
    if (!ArgsOf(env, info, 1, argv)) return false;
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, argv[0], &t) != napi_ok || t != napi_boolean) {
        napi_throw_type_error(env, nullptr, "expected boolean");
        return false;
    }
    return napi_get_value_bool(env, argv[0], &out) == napi_ok;
}

bool ArgDouble(napi_env env, napi_value v, double &out)
{
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, v, &t) != napi_ok || t != napi_number) return false;
    return napi_get_value_double(env, v, &out) == napi_ok;
}

// JS 线程上的回调调用 + 异常隔离：壳回调抛错只清异常落日志，不破产 uv 循环
// （VpnExt 进程崩溃即断网，宁可丢一次事件）
void CallJsSafe(napi_env env, napi_value fn, size_t argc, const napi_value *argv, const char *tag)
{
    napi_value undef = Undefined(env);
    napi_value res = nullptr;
    napi_status st = napi_call_function(env, undef, fn, argc, argv, &res);
    if (st != napi_ok) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, kLogDomain, kLogTag, "%s: call failed (%d)", tag, (int)st);
        return;
    }
    bool pending = false;
    if (napi_is_exception_pending(env, &pending) == napi_ok && pending) {
        napi_value ex = nullptr;
        napi_get_and_clear_last_exception(env, &ex);
        OH_LOG_Print(LOG_APP, LOG_ERROR, kLogDomain, kLogTag, "%s: callback threw, exception cleared", tag);
    }
}

// ================================= 极简 JSON（手写，不引第三方库） =================================
// 只为 start/applyConfig 的 TunnelConfig 契约字段服务（字段名即契约，见头注释），
// 不追求通用性；onEstablish 出参是序列化方向（下方 EstablishJson），不走本解析器。

namespace mj {

struct Val {
    enum Kind { NUL, BOOL, NUM, STR, ARR, OBJ };
    Kind kind = NUL;
    bool b = false;
    double num = 0;
    std::string str;
    std::vector<Val> arr;
    std::map<std::string, Val> obj;
};

struct Parser {
    const char *p;
    const char *end;
    bool ok = true;

    Parser(const char *s, size_t n) : p(s), end(s + n) {}

    bool fail() { ok = false; return false; }
    void ws() { while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) ++p; }
    bool eat(char c) { ws(); if (p < end && *p == c) { ++p; return true; } return fail(); }
    bool lit(const char *s, size_t n) {
        if (end - p >= static_cast<ptrdiff_t>(n) && std::strncmp(p, s, n) == 0) { p += n; return true; }
        return fail();
    }

    static void utf8(std::string &out, unsigned cp)
    {
        if (cp < 0x80) { out.push_back(static_cast<char>(cp)); }
        else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }

    bool hex4(unsigned &out)
    {
        if (end - p < 4) return fail();
        for (int i = 0; i < 4; ++i) {
            char c = p[i];
            unsigned d;
            if (c >= '0' && c <= '9') d = static_cast<unsigned>(c - '0');
            else if (c >= 'a' && c <= 'f') d = static_cast<unsigned>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') d = static_cast<unsigned>(c - 'A' + 10);
            else return fail();
            out = (out << 4) | d;
        }
        p += 4;
        return true;
    }

    bool string(std::string &out)
    {
        if (p >= end || *p != '"') return fail();
        ++p;
        while (p < end) {
            unsigned char c = static_cast<unsigned char>(*p++);
            if (c == '"') return true;
            if (c != '\\') { out.push_back(static_cast<char>(c)); continue; }
            if (p >= end) return fail();
            char e = *p++;
            switch (e) {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case '/': out.push_back('/'); break;
            case 'b': out.push_back('\b'); break;
            case 'f': out.push_back('\f'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            case 'u': {
                unsigned cp = 0;
                if (!hex4(cp)) return false;
                // 代理对：高代理后跟 \uDC00-\uDFFF 才合并，否则按原码点编码
                if (cp >= 0xD800 && cp <= 0xDBFF && end - p >= 6 && p[0] == '\\' && p[1] == 'u') {
                    p += 2;
                    unsigned lo = 0;
                    if (!hex4(lo)) return false;
                    if (lo >= 0xDC00 && lo <= 0xDFFF) cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                }
                utf8(out, cp);
                break;
            }
            default: return fail();
            }
        }
        return fail(); // 未闭合
    }

    bool number(double &out)
    {
        ws();
        char *e2 = nullptr;
        double v = std::strtod(p, &e2);
        if (e2 == p) return fail();
        p = e2;
        out = v;
        return true;
    }

    bool value(Val &out)
    {
        ws();
        if (p >= end) return fail();
        char c = *p;
        if (c == '{') {
            ++p;
            out.kind = Val::OBJ;
            ws();
            if (p < end && *p == '}') { ++p; return true; }
            for (;;) {
                ws();
                std::string key;
                if (!string(key)) return false;
                if (!eat(':')) return false;
                Val v;
                if (!value(v)) return false;
                out.obj[key] = std::move(v);
                ws();
                if (p < end && *p == ',') { ++p; continue; }
                return eat('}');
            }
        }
        if (c == '[') {
            ++p;
            out.kind = Val::ARR;
            ws();
            if (p < end && *p == ']') { ++p; return true; }
            for (;;) {
                Val v;
                if (!value(v)) return false;
                out.arr.push_back(std::move(v));
                ws();
                if (p < end && *p == ',') { ++p; continue; }
                return eat(']');
            }
        }
        if (c == '"') { out.kind = Val::STR; return string(out.str); }
        if (c == 't') { out.kind = Val::BOOL; out.b = true; return lit("true", 4); }
        if (c == 'f') { out.kind = Val::BOOL; out.b = false; return lit("false", 5); }
        if (c == 'n') { out.kind = Val::NUL; return lit("null", 4); }
        out.kind = Val::NUM;
        return number(out.num);
    }
};

inline bool parse(const char *s, size_t n, Val &out)
{
    Parser ps(s, n);
    if (!ps.value(out)) return false;
    ps.ws();
    return ps.ok && ps.p == ps.end;
}

inline const Val *field(const Val &v, const char *key)
{
    if (v.kind != Val::OBJ) return nullptr;
    auto it = v.obj.find(key);
    return it == v.obj.end() ? nullptr : &it->second;
}

inline bool asBool(const Val *v, bool dflt) { return (v && v->kind == Val::BOOL) ? v->b : dflt; }

inline std::string asStr(const Val *v) { return (v && v->kind == Val::STR) ? v->str : std::string(); }

// 数值语义：数值直取；字符串按 0x 前缀 → hex、恰 16 位 → hex（nwid 契约）、其余 → 十进制。
// 精度域：NUM 分支经 double 有损（>2^53 丢精度）、十进制串分支恰 16 位会误判 hex——
// 两者仅小值可靠，契约主形态是 16 位 hex 串（壳组串，受控输入），不按通用解析用。
inline uint64_t asU64(const Val *v)
{
    if (!v) return 0;
    if (v->kind == Val::NUM) return static_cast<uint64_t>(v->num);
    if (v->kind == Val::STR) {
        const std::string &s = v->str;
        if (s.size() > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
            return std::strtoull(s.c_str() + 2, nullptr, 16);
        if (s.size() == 16) return std::strtoull(s.c_str(), nullptr, 16);
        return std::strtoull(s.c_str(), nullptr, 10);
    }
    return 0;
}

} // namespace mj

// start/applyConfig 入参 → TunnelConfig（字段名即契约；缺 dataStoreRoot 视为格式错误）
bool ParseTunnelConfig(const std::string &json, pp::TunnelConfig &cfg, std::string &err)
{
    mj::Val root;
    if (!mj::parse(json.data(), json.size(), root) || root.kind != mj::Val::OBJ) {
        err = "not a JSON object";
        return false;
    }
    const mj::Val *ds = mj::field(root, "dataStoreRoot");
    if (ds == nullptr || ds->kind != mj::Val::STR || ds->str.empty()) {
        err = "dataStoreRoot required";
        return false;
    }
    cfg.dataStoreRoot = ds->str;
    cfg.planetDir = mj::asStr(mj::field(root, "planetDir"));
    cfg.planetFile = mj::asStr(mj::field(root, "planetFile"));
    cfg.identityPerPlanet = mj::asBool(mj::field(root, "identityPerPlanet"), false);
    cfg.disableIpv6 = mj::asBool(mj::field(root, "disableIpv6"), false);
    if (const mj::Val *nets = mj::field(root, "networks"); nets != nullptr && nets->kind == mj::Val::ARR) {
        for (const mj::Val &n : nets->arr) {
            if (n.kind != mj::Val::OBJ) continue;
            pp::TunnelConfig::Net net;
            net.nwid = mj::asU64(mj::field(n, "nwid"));
            net.routeViaZeroTier = mj::asBool(mj::field(n, "routeViaZeroTier"), false);
            cfg.networks.push_back(net);
        }
    }
    if (const mj::Val *moons = mj::field(root, "moons"); moons != nullptr && moons->kind == mj::Val::ARR) {
        for (const mj::Val &m : moons->arr) {
            if (m.kind != mj::Val::OBJ) continue;
            pp::TunnelConfig::Moon moon;
            moon.worldId = mj::asU64(mj::field(m, "worldId"));
            moon.seed = mj::asU64(mj::field(m, "seed"));
            cfg.moons.push_back(moon);
        }
    }
    return true;
}

// onEstablish 出参序列化（键名对齐 CoreRuntime.ets EstablishRequest，禁改）
void AppendQuoted(std::string &out, const std::string &s)
{
    out.push_back('"');
    for (char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof(buf), "\\u%04X", static_cast<unsigned char>(c));
                out += buf;
            } else {
                out.push_back(c);
            }
        }
    }
    out.push_back('"');
}

void AppendStringList(std::string &out, const std::vector<std::string> &v)
{
    out.push_back('[');
    for (size_t i = 0; i < v.size(); ++i) {
        if (i != 0) out.push_back(',');
        AppendQuoted(out, v[i]);
    }
    out.push_back(']');
}

std::string EstablishJson(const pp::EstablishRequest &r)
{
    std::string o = "{\"v4Addrs\":";
    AppendStringList(o, r.v4Addrs);
    o += ",\"v6Addrs\":";
    AppendStringList(o, r.v6Addrs);
    o += ",\"routes4\":";
    AppendStringList(o, r.routes4);
    o += ",\"routes6\":";
    AppendStringList(o, r.routes6);
    o += ",\"dns\":";
    AppendStringList(o, r.dns);
    o += ",\"mtu\":" + std::to_string(r.mtu) + "}";
    return o;
}

// ================================== 回调 tsfn 束 ==================================
// 线程模型：钩子（runtime 内部线程）与 setCallbacks（JS 线程）都持 g_cbLock——
// Post 在锁内取裸 tsfn 并投递，替换/释放在锁外不可能并发发生，杜绝「release 后
// 仍 call」的竞态。未注册回调（g_cbs 全空）时钩子静默跳过。

struct JsTask {
    enum Kind { Establish, Teardown, State, Protect };
    Kind kind = State;
    std::string json; // Establish：EstablishRequest JSON
    int fd = 0;       // Protect
    uint64_t token = 0; // Protect
};

struct TsfnBundle {
    napi_threadsafe_function establish = nullptr;
    napi_threadsafe_function teardown = nullptr;
    napi_threadsafe_function state = nullptr;
    napi_threadsafe_function protect = nullptr;
};

std::mutex g_cbLock;
TsfnBundle g_cbs;

// 进程级单例（硬契约⑤）：VpnExt 进程唯一 TunnelRuntime；主进程不调 TunnelNapi 族
std::once_flag g_rtOnce;
std::unique_ptr<pp::TunnelRuntime> g_runtime;

// 统一 call_js_cb：按任务形态组参调用壳回调
void CallJs(napi_env env, napi_value jsCb, void * /*context*/, void *data)
{
    std::unique_ptr<JsTask> task(static_cast<JsTask *>(data));
    if (env == nullptr || jsCb == nullptr) return; // 环境正在拆除：只回收载荷
    napi_value args[2] = { nullptr, nullptr };
    size_t argc = 0;
    switch (task->kind) {
    case JsTask::Establish:
        args[0] = MakeStr(env, task->json);
        if (args[0] == nullptr) return;
        argc = 1;
        break;
    case JsTask::Protect:
        args[0] = MakeI32(env, task->fd);
        args[1] = MakeDouble(env, static_cast<double>(task->token));
        if (args[0] == nullptr || args[1] == nullptr) return;
        argc = 2;
        break;
    case JsTask::Teardown:
    case JsTask::State:
    default:
        argc = 0;
        break;
    }
    CallJsSafe(env, jsCb, argc, args, task->kind == JsTask::Establish ? "onEstablish"
             : (task->kind == JsTask::Protect ? "protectFd"
              : (task->kind == JsTask::Teardown ? "onTeardown" : "onStateChanged")));
}

// tsfn 工厂：无界队列（max_queue_size=0）+ 初始线程计数 1（tsfn 存活）
napi_threadsafe_function MakeTsfn(napi_env env, napi_value jsFn, const char *name)
{
    napi_value uname = nullptr;
    napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &uname);
    napi_threadsafe_function f = nullptr;
    napi_status st = napi_create_threadsafe_function(env, jsFn, nullptr, uname, 0, 1, nullptr, nullptr,
                                                     nullptr, CallJs, &f);
    if (st != napi_ok) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, kLogDomain, kLogTag, "tsfn %s create failed (%d)", name, (int)st);
        return nullptr;
    }
    return f;
}

// 锁内投递（调用方必须已持 g_cbLock）；拒投（tsfn 正在关闭）即丢本条并回收载荷
void PostLocked(JsTask::Kind kind, std::string json, int fd, uint64_t token)
{
    napi_threadsafe_function f = nullptr;
    switch (kind) {
    case JsTask::Establish: f = g_cbs.establish; break;
    case JsTask::Teardown: f = g_cbs.teardown; break;
    case JsTask::State: f = g_cbs.state; break;
    case JsTask::Protect: f = g_cbs.protect; break;
    }
    if (f == nullptr) return; // 未注册回调 → 静默跳过
    JsTask *t = new JsTask{kind, std::move(json), fd, token};
    if (napi_call_threadsafe_function(f, t, napi_tsfn_nonblocking) != napi_ok) delete t;
}

void ReleaseBundleLocked()
{
    napi_threadsafe_function old[4] = { g_cbs.establish, g_cbs.teardown, g_cbs.state, g_cbs.protect };
    g_cbs = TsfnBundle{};
    for (napi_threadsafe_function f : old) {
        if (f != nullptr) napi_release_threadsafe_function(f, napi_tsfn_release);
    }
}

// ================================= protect 同步通道 =================================
// 投递 (fd, token) → JS 线程 protectFd → 壳处理器（vpnConnection.protect(fd)）→
// 壳调 protectResult(token, ok) → 此处 set_value。2s 内未应答按放行（宁通勿断）。

std::mutex g_protectLock;
std::map<uint64_t, std::shared_ptr<std::promise<bool>>> g_pendingProtect;
uint64_t g_nextProtectToken = 1;

std::mutex g_protectFnLock; // 壳 protect 处理器（JS 线程读改；napi_ref 只在 JS 线程解引）
napi_ref g_protectHandlerRef = nullptr;

// Hooks::protect 直译位（UdpCom::start 在 bind 后同步调用）
bool ProtectSync(int fd)
{
    auto pr = std::make_shared<std::promise<bool>>();
    std::future<bool> fut = pr->get_future();
    uint64_t token = 0;
    {
        std::lock_guard<std::mutex> lk(g_protectLock);
        token = g_nextProtectToken++;
        g_pendingProtect[token] = pr;
    }
    bool delivered = false;
    {
        std::lock_guard<std::mutex> lk(g_cbLock);
        if (g_cbs.protect != nullptr) {
            JsTask *t = new JsTask{JsTask::Protect, std::string(), fd, token};
            delivered = napi_call_threadsafe_function(g_cbs.protect, t, napi_tsfn_nonblocking) == napi_ok;
            if (!delivered) delete t;
        }
    }
    bool ok = true; // 缺省放行（未注册处理器 / 拒投 / 超时，一律 true——宁通勿断）
    if (delivered && fut.wait_for(std::chrono::milliseconds(kProtectTimeoutMs)) == std::future_status::ready) {
        ok = fut.get();
    }
    // 摘除挂起项：迟到的 protectResult 查不到 token 即忽略
    std::lock_guard<std::mutex> lk(g_protectLock);
    g_pendingProtect.erase(token);
    return ok;
}

// TunnelNapi.protectFd(fd, token) — protect tsfn 的 JS 目标（native 自建函数包装）。
// 查壳处理器并转调 (fd, token)；处理器未注册时不作答 → C++ 侧 2s 超时放行（默认态）。
napi_value TunnelProtectFd(napi_env env, napi_callback_info info)
{
    napi_value argv[2];
    if (!ArgsOf(env, info, 2, argv)) return nullptr;
    napi_ref ref = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_protectFnLock);
        ref = g_protectHandlerRef;
    }
    if (ref == nullptr) return Undefined(env);
    napi_value fn = nullptr;
    if (napi_get_reference_value(env, ref, &fn) != napi_ok || fn == nullptr) return Undefined(env);
    CallJsSafe(env, fn, 2, argv, "protectHandler");
    return Undefined(env);
}

// TunnelNapi.protectResult(token, ok) — 壳处理器完成后回投；已超时摘除的迟到应答忽略
napi_value TunnelProtectResult(napi_env env, napi_callback_info info)
{
    napi_value argv[2];
    if (!ArgsOf(env, info, 2, argv)) return nullptr;
    double token = 0;
    bool ok = false;
    napi_valuetype tb = napi_undefined;
    if (!ArgDouble(env, argv[0], token) || napi_typeof(env, argv[1], &tb) != napi_ok || tb != napi_boolean
        || napi_get_value_bool(env, argv[1], &ok) != napi_ok) {
        napi_throw_type_error(env, nullptr, "protectResult: expected (number, boolean)");
        return nullptr;
    }
    std::lock_guard<std::mutex> lk(g_protectLock);
    auto it = g_pendingProtect.find(static_cast<uint64_t>(token));
    if (it != g_pendingProtect.end()) {
        it->second->set_value(ok);
        g_pendingProtect.erase(it);
    }
    return Undefined(env);
}

// ==================================== 单例装配 ====================================

pp::TunnelRuntime &Runtime()
{
    std::call_once(g_rtOnce, [] {
        g_runtime.reset(new pp::TunnelRuntime());
        pp::TunnelRuntime::Hooks &h = g_runtime->hooks;
        // 全部钩子只投递不阻塞（CoreBridge 红线：回调路径禁阻塞/禁 static 缓冲复用——
        // protect 是唯一例外，它由 UdpCom 在自己的装配线程同步等待，非收包路径）
        h.onEstablish = [](const pp::EstablishRequest &req) {
            std::lock_guard<std::mutex> lk(g_cbLock);
            PostLocked(JsTask::Establish, EstablishJson(req), 0, 0);
        };
        h.onTeardown = []() {
            std::lock_guard<std::mutex> lk(g_cbLock);
            PostLocked(JsTask::Teardown, std::string(), 0, 0);
        };
        h.onStateChanged = []() {
            std::lock_guard<std::mutex> lk(g_cbLock);
            PostLocked(JsTask::State, std::string(), 0, 0);
        };
        h.protect = [](int fd) -> bool { return ProtectSync(fd); };
        // sendPacket 不注入：runtime 缺省直连 m_udp->send（Kotlin PacketSender=UdpCom 同构）
    });
    return *g_runtime;
}

// ==================================== NAPI 函数 ====================================
// ---- CoreRuntime ----

napi_value GetCoreVersion(napi_env env, napi_callback_info /*info*/)
{
    const char *v = pp::coreVersion();
    return MakeStr(env, v);
}

// ---- ColorMath（pp::ColorMath 直通；主色 ≤ 0xFFFFFF，uint32 承载充分） ----

napi_value ColorAccentLight(napi_env env, napi_callback_info info)
{
    uint32_t hex = 0;
    if (!ArgU32(env, info, hex)) return nullptr;
    return MakeU32(env, pp::accentLight(hex));
}

napi_value ColorAccentDark(napi_env env, napi_callback_info info)
{
    uint32_t hex = 0;
    if (!ArgU32(env, info, hex)) return nullptr;
    return MakeU32(env, pp::accentDark(hex));
}

napi_value ColorSuccessLight(napi_env env, napi_callback_info info)
{
    uint32_t hex = 0;
    if (!ArgU32(env, info, hex)) return nullptr;
    return MakeU32(env, pp::successLight(hex));
}

napi_value ColorSuccessDark(napi_env env, napi_callback_info info)
{
    uint32_t hex = 0;
    if (!ArgU32(env, info, hex)) return nullptr;
    return MakeU32(env, pp::successDark(hex));
}

napi_value ColorPlanetTints(napi_env env, napi_callback_info info)
{
    uint32_t hex = 0;
    if (!ArgU32(env, info, hex)) return nullptr;
    uint32_t tints[8];
    pp::planetTints(hex, tints);
    napi_value arr = nullptr;
    napi_create_array_with_length(env, 8, &arr);
    for (uint32_t i = 0; i < 8; ++i) napi_set_element(env, arr, i, MakeU32(env, tints[i]));
    return arr;
}

napi_value ColorHslOf(napi_env env, napi_callback_info info)
{
    uint32_t hex = 0;
    if (!ArgU32(env, info, hex)) return nullptr;
    pp::Hsl h = pp::hslOf(hex);
    napi_value arr = nullptr;
    napi_create_array_with_length(env, 3, &arr);
    napi_set_element(env, arr, 0, MakeDouble(env, h.h));
    napi_set_element(env, arr, 1, MakeDouble(env, h.s));
    napi_set_element(env, arr, 2, MakeDouble(env, h.l));
    return arr;
}

// ---- TunnelNapi ----

// start(configJson): boolean — 重复启动 false；装配失败 false 且置 Failed 终态
// （原因码以 snapshot() 为准）；configJson 缺 dataStoreRoot / 非 JSON 对象 → throw
napi_value TunnelStart(napi_env env, napi_callback_info info)
{
    std::string json;
    if (!ArgStr(env, info, json)) return nullptr;
    pp::TunnelConfig cfg;
    std::string err;
    if (!ParseTunnelConfig(json, cfg, err)) {
        std::string msg = "start: invalid config JSON: " + err;
        napi_throw_type_error(env, nullptr, msg.c_str());
        return nullptr;
    }
    return MakeBool(env, Runtime().start(cfg));
}

// stop() — 幂等。tsfn 不在此释放（硬契约④：壳一次性注册，stop/start 重入复用）
napi_value TunnelStop(napi_env env, napi_callback_info /*info*/)
{
    Runtime().stop();
    return Undefined(env);
}

// restartCore() — 进程内换代（stop+start 保配置；仅存活态生效）
napi_value TunnelRestartCore(napi_env env, napi_callback_info /*info*/)
{
    Runtime().restartCore();
    return Undefined(env);
}

// swapFd(fd): boolean — 硬契约①：false 时 fd 已被 Dataplane 闩锁关闭，调用方不得再 close
napi_value TunnelSwapFd(napi_env env, napi_callback_info info)
{
    int32_t fd = 0;
    if (!ArgI32(env, info, fd)) return nullptr;
    return MakeBool(env, Runtime().swapFd(fd));
}

// applyConfig(configJson) — 热重配；未启动 no-op；格式错误 throw
napi_value TunnelApplyConfig(napi_env env, napi_callback_info info)
{
    std::string json;
    if (!ArgStr(env, info, json)) return nullptr;
    pp::TunnelConfig cfg;
    std::string err;
    if (!ParseTunnelConfig(json, cfg, err)) {
        std::string msg = "applyConfig: invalid config JSON: " + err;
        napi_throw_type_error(env, nullptr, msg.c_str());
        return nullptr;
    }
    Runtime().applyConfig(cfg);
    return Undefined(env);
}

// setPathSatisfied(ok) — 壳 NetWatch 透出（仍发 onStateChanged 供壳落盘）
napi_value TunnelSetPathSatisfied(napi_env env, napi_callback_info info)
{
    bool ok = false;
    if (!ArgBool(env, info, ok)) return nullptr;
    Runtime().setPathSatisfied(ok);
    return Undefined(env);
}

// snapshot(): string — TunnelSnapshot 契约 JSON（不含 pathSatisfied/writtenAt）
napi_value TunnelSnapshot(napi_env env, napi_callback_info /*info*/)
{
    return MakeStr(env, Runtime().snapshotJson());
}

// setCallbacks(cbs) — 壳一次性注册。native 侧原始回调形态：onEstablish 收 JSON 字符串
// （跨线程一律字符串化，解析在 ArkTS 包装层 CoreRuntime.ets）；onTeardown/onStateChanged
// 无参。重复调用先释放旧束再装新束（非主路径）。
napi_value TunnelSetCallbacks(napi_env env, napi_callback_info info)
{
    napi_value argv[1];
    if (!ArgsOf(env, info, 1, argv)) return nullptr;
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, argv[0], &t) != napi_ok || t != napi_object) {
        napi_throw_type_error(env, nullptr, "setCallbacks: expected object");
        return nullptr;
    }
    static const char *kKeys[3] = { "onEstablish", "onTeardown", "onStateChanged" };
    const char *kNames[3] = { "ppOnEstablish", "ppOnTeardown", "ppOnStateChanged" };
    napi_value fns[3] = { nullptr, nullptr, nullptr };
    for (int i = 0; i < 3; ++i) {
        napi_value v = nullptr;
        napi_valuetype ft = napi_undefined;
        if (napi_get_named_property(env, argv[0], kKeys[i], &v) != napi_ok || napi_typeof(env, v, &ft) != napi_ok
            || ft != napi_function) {
            napi_throw_type_error(env, nullptr, kKeys[i]);
            return nullptr;
        }
        fns[i] = v;
    }
    napi_threadsafe_function fresh[3] = { nullptr, nullptr, nullptr };
    auto failCreate = [&]() {
        for (int j = 0; j < 3; ++j) {
            if (fresh[j] != nullptr) napi_release_threadsafe_function(fresh[j], napi_tsfn_release);
        }
        napi_throw_error(env, nullptr, "setCallbacks: threadsafe function creation failed");
    };
    for (int i = 0; i < 3; ++i) {
        fresh[i] = MakeTsfn(env, fns[i], kNames[i]);
        if (fresh[i] == nullptr) {
            failCreate();
            return nullptr;
        }
    }
    // protect 通道：tsfn 包一层本地创建的 protectFd 函数（壳处理器在 TunnelProtectFd 内查表转调）
    napi_value protectFn = nullptr;
    napi_threadsafe_function protectTsfn = nullptr;
    if (napi_create_function(env, "protectFd", NAPI_AUTO_LENGTH, TunnelProtectFd, nullptr, &protectFn) == napi_ok)
        protectTsfn = MakeTsfn(env, protectFn, "ppProtect");
    if (protectTsfn == nullptr) {
        failCreate();
        return nullptr;
    }

    {
        std::lock_guard<std::mutex> lk(g_cbLock);
        ReleaseBundleLocked();
        g_cbs.establish = fresh[0];
        g_cbs.teardown = fresh[1];
        g_cbs.state = fresh[2];
        g_cbs.protect = protectTsfn;
    }
    return Undefined(env);
}

// setProtectHandler(handler | null) — 注册/取消壳 protect 处理器。null = 回到默认态
// （protectFd 不作答 → 2s 超时放行）。
napi_value TunnelSetProtectHandler(napi_env env, napi_callback_info info)
{
    napi_value argv[1];
    if (!ArgsOf(env, info, 1, argv)) return nullptr;
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, argv[0], &t) != napi_ok) return nullptr;
    if (t != napi_function && t != napi_null && t != napi_undefined) {
        napi_throw_type_error(env, nullptr, "setProtectHandler: expected function or null");
        return nullptr;
    }
    std::lock_guard<std::mutex> lk(g_protectFnLock);
    if (g_protectHandlerRef != nullptr) {
        napi_delete_reference(env, g_protectHandlerRef);
        g_protectHandlerRef = nullptr;
    }
    if (t == napi_function) napi_create_reference(env, argv[0], 1, &g_protectHandlerRef);
    return Undefined(env);
}

} // namespace

EXTERN_C_START
napi_value Init(napi_env env, napi_value exports)
{
    const napi_property_descriptor desc[] = {
        // ---- CoreRuntime ----
        { "getCoreVersion", nullptr, GetCoreVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
        // ---- ColorMath ----
        { "accentLight", nullptr, ColorAccentLight, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "accentDark", nullptr, ColorAccentDark, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "successLight", nullptr, ColorSuccessLight, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "successDark", nullptr, ColorSuccessDark, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "planetTints", nullptr, ColorPlanetTints, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "hslOf", nullptr, ColorHslOf, nullptr, nullptr, nullptr, napi_default, nullptr },
        // ---- TunnelNapi ----
        { "start", nullptr, TunnelStart, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stop", nullptr, TunnelStop, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "restartCore", nullptr, TunnelRestartCore, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "swapFd", nullptr, TunnelSwapFd, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "applyConfig", nullptr, TunnelApplyConfig, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setPathSatisfied", nullptr, TunnelSetPathSatisfied, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "snapshot", nullptr, TunnelSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setCallbacks", nullptr, TunnelSetCallbacks, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setProtectHandler", nullptr, TunnelSetProtectHandler, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "protectFd", nullptr, TunnelProtectFd, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "protectResult", nullptr, TunnelProtectResult, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module planetportModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "planetport_core",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterPlanetportModule(void)
{
    napi_module_register(&planetportModule);
}
