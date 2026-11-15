# 构建事实记录

记录 A1 阶段（轨道 A 地基）ZeroTier 1.16.2 核心在本仓库的构建与验证事实，
供 A2（CoreBridge 完整版）与 B 轨（真机 Spike）查阅。

## ZeroTier 1.16.2 OHOS 交叉编译处置（A1）

### 平台检测处置：尚未执行（待 DevEco）

OHOS 交叉编译（`native/build-ohos`，arm64-v8a）**尚未执行**——DevEco Studio
工具链（含 OHOS SDK/NDK）尚未就绪，平台适配探测随之待补。因此：

- 是否直编通过：未知，未验证
- 是否需要注入 `-D` 宏（K4 类，如 musl 下平台检测失败）：未知，未发生任何注入
- 是否需要增拷 osdep/ext 文件（K6 类，如 `Http.cpp`/`http-parser`）：未知，未发生任何增拷
  （bootstrap 子集拷贝清单按 Android 版先例预设：node 全集 + include + osdep 六文件
  + version.h + ext 四项；CMake 编译集为 node 全集 GLOB 排除
  `EmbeddedNetworkController.cpp` + `osdep/OSUtils.cpp`）

当前唯一的编译定义注入是**先例对齐项**而非平台探测产物：

- `ZT_NO_PEER_METRICS=1`（Android 版 CMakeLists 注释：Metrics.cpp 必须保留在编译集）
- ~~`ZT_SDK=0`~~ **已移除**（2026-11-15 审查修正）：Android 版从未定义该宏；
  且 `-DZT_SDK=0` 是"定义了它"——`Constants.hpp` 的 `#ifndef ZT_SDK` 测试
  defined-ness，会把 `ZT_PEER_ACTIVITY_TIMEOUT` 切到 SDK 分支的 30s，
  与 controller 编译无关（controller 代码在官方 tarball 的 `nonfree/controller/`，
  本就不在 node/ 内、bootstrap 也从不拷贝 nonfree/，GPL 血统零引入由此保证）

DevEco 就绪后的补跑路径（按计划 Task 4 Step 3~5）：

```bash
cmake -B native/build-ohos -S native \
  -DCMAKE_TOOLCHAIN_FILE="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/build/cmake/ohos.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release -DOHOS_ARCH=arm64-v8a -DOHOS_PLATFORM_LEVEL=12 -DOHOS_STL=c++_shared
cmake --build native/build-ohos -j8
```

零补丁红线不变：平台检测失败只允许 `-D` 宏注入；`-D` 不可达则停止并上报裁决，
禁止修改 `Core/` 内任何文件。若走 K6 增拷，仍是对官方源码的子集选取，不算补丁。

### 与先例（HarmonyRun/ZeroTier-HarmonyOS）的差异与原因

先例直接修改 `Constants.hpp` 适配平台，本仓库**不采用**，原因：零补丁原则。
`Core/` 由 `scripts/bootstrap.sh` 从官方 tarball 拉取（SHA256 锁定
`2c607f573c6e38815433af289d364a689a203b18b51125f06c4472014d0657f0`），
逐字节保持官方内容；所有适配收敛到仓库自有层：编译定义（`native/CMakeLists.txt`）、
桥接层（`native/bridge/`）、状态回调实现（A2）。收益是升级 ZeroTier 版本只需改
bootstrap 两个变量重跑，无补丁重放成本。

### host 冒烟结论（macOS，2026-11-15）

`cmake -B native/build-host -S native -DCMAKE_BUILD_TYPE=Debug -DPP_BUILD_SMOKE=ON`
构建并运行 `./native/build-host/smoke`，输出 SMOKE PASS，退出码 0：

- **coreVersion = 1.16.2**：核心编译、链接、`ZT_version()` 全链路可跑
- **identityGen 地址恒定 10 位十六进制**：节点地址是 40 位整数，核心规范字符串形式是
  `Address::toString()` → `Utils::hex10()`（逐 nibble 编码，恒定 10 字符小写 hex），
  不是十进制——十进制表示位数随机（1~13 位），不能做长度断言
- **ZT_Node_new 走 `ZT_Node_Callbacks` 结构体 API**（1.16.2 现行签名），不是旧版
  逐回调指针签名；两个硬约束：`callbacks.version` 必须为 0（非 0 抛
  ZT_EXCEPTION_INVALID_ARGUMENT）、`config` 不可传 nullptr（构造函数直接 memcpy 解引用，
  需传零初始化的 `ZT_Node_Config`）；回调 8 个 stub 签名均含 node/uptr/tptr 前三参，
  `statePut/stateGet` 的对象 ID 为 `const uint64_t[2]`；`now` 为毫秒时钟
- **身份仅存内存，不落盘**：冒烟状态回调为空实现，`stateGet` 返回 -1 → 核心每次运行
  `identity.generate()` 生成新身份 → `stateObjectPut`（IDENTITY_SECRET/PUBLIC）送达
  stub 被丢弃；两次运行地址不同，homeDir 目录被创建但保持为空。
  真正的 identity.secret 落盘复用（0600）在 A2 的状态目录重定向 hook 中实现

### 已知未验证项（待 B 轨真机）

- `libplanetport_core.so` 在真机加载（NAPI 模块注册、ArkTS `import` 可用）
- TUN 数据面（VpnExt 壳 + TunnelController，计划 3 范围）
- protect（底层 socket 绑定物理网卡，防路由环）
- OHOS musl 下交叉编译本身的平台检测结论（见上文，待 DevEco 补跑）
