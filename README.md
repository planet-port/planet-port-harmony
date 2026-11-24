# Planet Port - HarmonyOS 🪐

简体中文

**Planet Port** 是开源的鸿蒙 ZeroTier 客户端，基于 ZeroTier 1.16.2 官方核心构建，
ArkUI 原生写成。多行星并存、多网络同连、默认路由与 DNS 均可控。

> 非官方客户端，与 ZeroTier, Inc. 无隶属关系。
> 开发中（轨道 A），功能对齐 [planet-port-ios](../planet-port-ios) v1.5.0。

## 从源码构建

前置：DevEco Studio 5.0+（含 HarmonyOS SDK 与 NDK）。

```bash
./scripts/bootstrap.sh   # 拉取 ZeroTier 1.16.2 核心（SHA256 锁定，不入库）
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
# hvigorw 为 DevEco 默认安装路径，按实际位置调整
"/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw" \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

host 冒烟与单测（macOS 本机验证核心与数据面，无需真机）：

```bash
cmake -B native/build-host -S native -DCMAKE_BUILD_TYPE=Debug \
  -DPP_BUILD_SMOKE=ON -DPP_BUILD_TESTS=ON
cmake --build native/build-host -j8
./native/build-host/pp_tests   # 数据面金标向量（gtest，首次构建自动下载）
./native/build-host/smoke      # 核心版本 + 身份生成链路
```

## 许可

- ZeroTier 核心：MPL-2.0（构建时拉取，零补丁）
- 本项目代码：MIT
