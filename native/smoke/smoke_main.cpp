// host 冒烟：macOS 本机验证 ZeroTier 核心 + CoreBridge 链接可跑（S1 无真机部分）
#include "bridge/CoreBridge.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

int main()
{
    int failures = 0;

    const char *v = pp::coreVersion();
    if (strcmp(v, "1.16.2") != 0) {
        std::fprintf(stderr, "FAIL coreVersion: 期望 1.16.2，实际 %s\n", v);
        ++failures;
    } else {
        std::printf("PASS coreVersion = %s\n", v);
    }

    const char *addr = pp::smokeIdentityGen("/tmp/pp-smoke-home");
    if (strlen(addr) != 10) {
        std::fprintf(stderr, "FAIL identityGen: 节点地址应为 10 位，实际 \"%s\"\n", addr);
        ++failures;
    } else {
        std::printf("PASS identityGen addr = %s\n", addr);
    }

    if (failures == 0) {
        std::printf("SMOKE PASS\n");
        return 0;
    }
    return 1;
}
