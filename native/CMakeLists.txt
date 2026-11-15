# native/CMakeLists.txt — libplanetport_core 构建入口
#
# 零补丁原则：Core/（bootstrap 拉取）不做任何修改；平台适配只经 -D 注入。
# 三个目标：
#   zt_core        — ZeroTier 核心（OHOS 交叉 / macOS host 通用）
#   planetport_core — NAPI 动态库（仅 OHOS 工具链下编；Task 5 完成 napi 源后启用）
#   smoke          — host 冒烟可执行（仅 -DPP_BUILD_SMOKE=ON；Task 6）
cmake_minimum_required(VERSION 3.18.1)
project(planetport_core C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(ZT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../Core)

# ---- 平台适配（零补丁：仅编译定义，禁改 Core/ 源码） ----
add_compile_definitions(
    ZT_SDK=0            # 不编译 controller
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
list(REMOVE_ITEM ZT_NODE_SRC "${ZT_DIR}/node/EmbeddedNetworkController.cpp")

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

# ---- NAPI 动态库（Task 5 填充 napi 源；本任务先验证核心可编） ----
# 暂以 INTERFACE 占位，Task 5 替换为 SHARED 目标。

# ---- host 冒烟（Task 6） ----
if(PP_BUILD_SMOKE)
    # Task 6 填充
endif()
