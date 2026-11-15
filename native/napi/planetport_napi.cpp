// planetport NAPI 绑定 — 控制流与状态流入口（不过包，规格 D2）
#include "napi/native_api.h"
#include "bridge/CoreBridge.h"

static napi_value GetCoreVersion(napi_env env, napi_callback_info info)
{
    const char *v = pp::coreVersion();
    napi_value result = nullptr;
    napi_create_string_utf8(env, v, NAPI_AUTO_LENGTH, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "getCoreVersion", nullptr, GetCoreVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
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
