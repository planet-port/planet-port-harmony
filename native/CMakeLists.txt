# native/CMakeLists.txt — libplanetport_core 构建入口
#
# 零补丁原则：Core/（bootstrap 拉取）不做任何修改；平台适配只经 -D 注入。
# 三个目标：
#   zt_core        — ZeroTier 核心（OHOS 交叉 / macOS host 通用）
#   planetport_core — NAPI 动态库（仅 OHOS 工具链下编）
#   smoke          — host 冒烟可执行（仅 -DPP_BUILD_SMOKE=ON；Task 6）
cmake_minimum_required(VERSION 3.18.1)
project(planetport_core C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(ZT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../Core)

# ---- 平台适配（零补丁：仅编译定义，禁改 Core/ 源码） ----
# 注：不定义 ZT_SDK——定义它（含 =0）会把 ZT_PEER_ACTIVITY_TIMEOUT 切到 SDK
# 分支的 30s（Constants.hpp #ifndef 测试的是 defined-ness），Android 版未定义。
add_compile_definitions(
    ZT_NO_PEER_METRICS=1 # 见 Android CMakeLists 注释：Metrics.cpp 必须保留在编译集
)

# 关闭 ZeroTier 老代码的无害警告
add_compile_options(
    -Wno-unused-function
    -Wno-unused-variable
    -Wno-unused-parameter
    -Wno-sign-compare
    -Wno-deprecated-declarations
    -Wno-implicit-fallthrough
)

# ---- ZeroTier 核心（对齐 Android 版编译清单：node 全集 GLOB + OSUtils） ----
file(GLOB ZT_NODE_SRC CONFIGURE_DEPENDS ${ZT_DIR}/node/*.cpp)
# 不排除 EmbeddedNetworkController.cpp：官方 tarball 中该文件位于 nonfree/controller/，
# bootstrap 从不拷贝 nonfree/，node/ 内本无此文件，原 REMOVE_ITEM 是对空集的无操作，已删

add_library(zt_core OBJECT
    ${ZT_NODE_SRC}
    ${ZT_DIR}/osdep/OSUtils.cpp
)
target_include_directories(zt_core PUBLIC
    ${ZT_DIR}/include/
    ${ZT_DIR}/node/
    ${ZT_DIR}/ext/
    ${ZT_DIR}/ext/prometheus-cpp-lite-1.0/core/include/
    ${ZT_DIR}/ext/prometheus-cpp-lite-1.0/simpleapi/include/
)

# ---- NAPI 动态库（仅 OHOS 工具链下链接 libace_napi） ----
if(CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    add_library(planetport_core SHARED
        napi/planetport_napi.cpp
        bridge/CoreBridge.cpp
        # A2 数据面八模块（与 pp_tests 源集一致；A3 NAPI 接线前暂无调用者，
        # SHARED 目标全量编入，符号为 A3 备好）
        dataplane/ArpTable.cpp dataplane/NdpTable.cpp dataplane/NAT44.cpp
        dataplane/NetworkContext.cpp dataplane/RoutePlanner.cpp
        dataplane/FrameConverter.cpp dataplane/Dataplane.cpp dataplane/UdpCom.cpp
        runtime/TunnelRuntime.cpp
        theme/ColorMath.cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/../entry/src/main/cpp/anchor.cpp # hvigor native 探测锚点，见文件头注释
        $<TARGET_OBJECTS:zt_core>
    )
    # 与 smoke 同款：$<TARGET_OBJECTS> 不传递对象库的 PUBLIC include 目录，
    # 链接对象库以继承 ZeroTierOne.h（CoreBridge.cpp）等头文件路径；
    # PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} 供 napi 源找 bridge/CoreBridge.h
    target_include_directories(planetport_core PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_link_libraries(planetport_core PRIVATE zt_core)
    if(NOT DEFINED OHOS_NDK_HOME)
        set(OHOS_NDK_HOME "$ENV{OHOS_NDK_HOME}")
    endif()
    if(NOT OHOS_NDK_HOME)
        set(OHOS_NDK_HOME "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native")
    endif()
    if(OHOS_ARCH STREQUAL "arm64-v8a")
        set(OHOS_LLVM aarch64-linux-ohos)
    else()
        set(OHOS_LLVM arm-linux-ohos)
    endif()
    set(OHOS_SYSROOT_LIB ${OHOS_NDK_HOME}/sysroot/usr/lib/${OHOS_LLVM})
    target_link_libraries(planetport_core PRIVATE
        ${OHOS_SYSROOT_LIB}/libace_napi.z.so
        ${OHOS_SYSROOT_LIB}/libhilog_ndk.z.so
        -lpthread -ldl -lm
    )
endif()

# ---- host 冒烟（Task 6） ----
if(PP_BUILD_SMOKE)
    add_executable(smoke
        smoke/smoke_main.cpp
        bridge/CoreBridge.cpp
        $<TARGET_OBJECTS:zt_core>
    )
    target_include_directories(smoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    # 链接对象库以继承 zt_core 的 PUBLIC include 目录（ZeroTierOne.h 等）
    target_link_libraries(smoke PRIVATE zt_core)
endif()

# ---- host 单测（A2：gtest 经 FetchContent；仅非 OHOS 工具链） ----
if(PP_BUILD_TESTS AND NOT CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    include(FetchContent)
    FetchContent_Declare(googletest
        URL https://github.com/google/googletest/archive/refs/tags/v1.14.0.tar.gz)
    set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(googletest)
    # 测试源 GLOB 吸收：模块任务只落 tests/test_*.cpp，不改本文件
    file(GLOB PP_TEST_SRC CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/tests/*.cpp)
    add_executable(pp_tests
        ${PP_TEST_SRC}
        dataplane/ArpTable.cpp dataplane/NdpTable.cpp dataplane/NAT44.cpp
        dataplane/NetworkContext.cpp dataplane/RoutePlanner.cpp
        dataplane/FrameConverter.cpp dataplane/Dataplane.cpp dataplane/UdpCom.cpp
        runtime/TunnelRuntime.cpp
        theme/ColorMath.cpp
        bridge/CoreBridge.cpp $<TARGET_OBJECTS:zt_core>
    )
    target_include_directories(pp_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    # TunnelRuntime 测试注入通道（testFeedNetConf/testFeedEvent/testOnCoreAction）
    # 仅测试目标可见——OHOS 侧 planetport_core 不定义，生产路径零影响
    target_compile_definitions(pp_tests PRIVATE PP_TUNNELRUNTIME_TEST_HOOKS)
    target_link_libraries(pp_tests PRIVATE zt_core GTest::gtest_main)
    # enable_testing 是 ctest 入口（gtest_discover_tests 只注册不生成根
    # CTestTestfile——A2 起 ctest 报 No tests were found 的根因，T6 补上）
    enable_testing()
    include(GoogleTest)
    gtest_discover_tests(pp_tests)
endif()
