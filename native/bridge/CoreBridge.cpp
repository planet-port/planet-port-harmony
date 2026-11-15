#include "CoreBridge.h"

#include <ZeroTierOne.h>

#include <cstdio>
#include <cstring>
#include <ctime>
#include <sys/stat.h>

namespace pp {

const char *coreVersion()
{
    int major = 0, minor = 0, revision = 0;
    ZT_version(&major, &minor, &revision);
    static char buf[32];
    snprintf(buf, sizeof(buf), "%d.%d.%d", major, minor, revision);
    return buf;
}

// ---- host 冒烟（Task 6） ----
// 最小回调集：冒烟不进入网络与持久化路径，只需满足 ZT_Node_new 的非空契约。
// 签名对齐 1.16.2 的 Core/include/ZeroTierOne.h（ZT_Node_Callbacks 各 typedef）。

namespace {

void cbVirtualNetworkFrame(ZT_Node *, void *, void *, uint64_t, void **, uint64_t, uint64_t, unsigned int,
                           unsigned int, const void *, unsigned int)
{
}

void cbEventCallback(ZT_Node *, void *, void *, enum ZT_Event, const void *) {}

void cbStatePutFunction(ZT_Node *, void *, void *, enum ZT_StateObjectType, const uint64_t[2], const void *, int) {}

int cbStateGetFunction(ZT_Node *, void *, void *, enum ZT_StateObjectType, const uint64_t[2], void *, unsigned int)
{
    // 状态不存在 → 核心生成新身份（冒烟不持久化，identity.secret 落盘留 A2）
    return -1;
}

int cbWirePacketSendFunction(ZT_Node *, void *, void *, int64_t, const struct sockaddr_storage *, const void *,
                             unsigned int, unsigned int)
{
    return 0;
}

int cbPathCheckFunction(ZT_Node *, void *, void *, uint64_t, int64_t, const struct sockaddr_storage *)
{
    return 0;
}

int cbPathLookupFunction(ZT_Node *, void *, void *, uint64_t, int, struct sockaddr_storage *)
{
    return 0;
}

int cbVirtualNetworkConfigFunction(ZT_Node *, void *, void *, uint64_t, void **,
                                   enum ZT_VirtualNetworkConfigOperation, const ZT_VirtualNetworkConfig *)
{
    return 0;
}

ZT_Node *makeNode(void *ctx)
{
    // ZT_Node_new 契约（1.16.2）：callbacks->version 必须为 0，config 必须非空（构造时逐字段拷贝）
    ZT_Node_Config config;
    memset(&config, 0, sizeof(config));

    ZT_Node_Callbacks cb;
    memset(&cb, 0, sizeof(cb));
    cb.version = 0;
    cb.statePutFunction = cbStatePutFunction;
    cb.stateGetFunction = cbStateGetFunction;
    cb.wirePacketSendFunction = cbWirePacketSendFunction;
    cb.virtualNetworkFrameFunction = cbVirtualNetworkFrame;
    cb.virtualNetworkConfigFunction = cbVirtualNetworkConfigFunction;
    cb.eventCallback = cbEventCallback;
    cb.pathCheckFunction = cbPathCheckFunction;
    cb.pathLookupFunction = cbPathLookupFunction;

    ZT_Node *node = nullptr;
    const int64_t now = (int64_t)time(nullptr) * 1000LL; // 毫秒时钟
    if (ZT_Node_new(&node, &config, ctx, nullptr, &cb, now) != ZT_RESULT_OK) {
        return nullptr;
    }
    return node;
}

} // namespace

const char *smokeIdentityGen(const char *homeDir)
{
    static char addrBuf[16];
    addrBuf[0] = '\0';

    mkdir(homeDir, 0700);

    ZT_Node *node = makeNode(nullptr);
    if (!node) {
        return addrBuf;
    }
    uint64_t addr = ZT_Node_address(node);
    // 节点地址规范形式 = 10 位小写十六进制（对齐核心 Address::toString / Utils::hex10）；
    // 十进制表示位数不定（40 位整数 1~13 位），不可作为断言依据
    snprintf(addrBuf, sizeof(addrBuf), "%010llx", (unsigned long long)addr);
    ZT_Node_delete(node);
    return addrBuf;
}

} // namespace pp
