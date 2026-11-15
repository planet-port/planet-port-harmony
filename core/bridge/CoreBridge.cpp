#include "CoreBridge.h"

#include <ZeroTierOne.h>

namespace pp {

const char *coreVersion()
{
    int major = 0, minor = 0, revision = 0;
    ZT_version(&major, &minor, &revision);
    static char buf[32];
    snprintf(buf, sizeof(buf), "%d.%d.%d", major, minor, revision);
    return buf;
}

} // namespace pp
