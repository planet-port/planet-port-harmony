# Planet Port 鸿蒙版 · 计划 1（A0+A1 地基）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立鸿蒙工程地基——DevEco 工具链就绪、工程骨架可构建 HAP、bootstrap 拉取 ZeroTier 1.16.2、arm64 交叉编译通过、host 冒烟验证核心可跑（S1 的无真机部分）。

**Architecture:** 沿用规格 §2 方案 B。本计划只建地基：单 native 库 `libplanetport_core.so`（ZeroTier 核心 GLOB + OSUtils + CoreBridge 最小骨架 + NAPI 壳）经 entry 模块 externalNativeOptions 集成；host 冒烟二进制复用同一份 C++ 源（不含 NAPI 层）在 macOS 直接编译运行。

**Tech Stack:** DevEco Studio 5.0+（含 SDK/NDK/hvigor）、CMake（ohos.toolchain.cmake）、C++17、ArkTS/ArkUI（Stage 模型）、bash。

**规格:** docs/superpowers/specs/2026-11-15-planet-port-harmony-design.md （本计划覆盖 §6 轨道 A 的 A0+A1）

## Global Constraints

- ZeroTier 核心来源：官方 1.16.2 tarball，SHA256 `2c607f573c6e38815433af289d364a689a203b18b51125f06c4472014d0657f0`，bootstrap 拉取不入库，**零本地补丁**（红线：禁止修改 `Core/` 内任何文件；平台适配只允许 `-D` 编译定义；若 `-D` 不可达，停下报告用户裁决）
- GPL 血统零引入：不参考任何 GPL 分支项目（kaaass/ZerotierFix 等）
- 基线：minAPI 12（OHOS_PLATFORM_LEVEL=12）/ targetAPI 23 / arm64-v8a，C++17
- 编译定义：`ZT_SDK=0`、`ZT_NO_PEER_METRICS=1`（Metrics.cpp 必须保留在编译集，见 Android CMakeLists 注释）
- 仓库结构对齐规格 §4：`Core/`（拉取产物）、`core/`（自研 C++）、`entry/`、`scripts/`
- 提交信息：Conventional Commits，中文 description/Body，禁止 Co-authored-by
- git 一律 `--no-pager`
- 提交时机：每任务完成并验证后提交，禁止 git push

## 已知风险与回退路径（执行时先读）

| # | 风险 | 回退 |
|---|---|---|
| K1 | `brew install --cask deveco-studio` 不存在（调研与先例 BUILD.md 说法冲突） | 官网手动下载 DMG：需用户从 https://developer.huawei.com/consumer/cn/deveco-studio/download 下载拖入 /Applications（一次性 GUI 操作，向用户说明） |
| K2 | SDK 未随 IDE 预装、命令行找不到 ohos.toolchain.cmake | 请用户打开一次 DevEco Studio 完成首次 SDK 下载（GUI 一次），之后回到命令行 |
| K3 | hvigor 配置 schema 随版本变化导致 assembleHap 报错 | 按报错逐项修配置文件，不改任务边界 |
| K4 | ZeroTier 源码在 OHOS musl 下平台检测失败（先例改了 Constants.hpp，我们不许） | 仅允许 `-D` 宏注入（如 `-DZT_...`）；不可达则**停止并报告用户**，不得擅自给 Core/ 打补丁 |
| K5 | entry 模块 externalNativeOptions 不接受跨目录（`../core/`）CMake 路径 | 在 entry/src/main/cpp/CMakeLists.txt 放一行 `add_subdirectory` 指回根级 core/ |
| K6 | ZeroTier 1.16.2 编译还需 Http.cpp/http-parser（先例编了，Android 没编） | bootstrap 增拷对应文件并加入编译集；仍是对官方源码的子集选取，不算补丁 |

---

### Task 1: 安装 DevEco Studio 工具链（A0）

**Files:**
- 无仓库文件变更（系统级安装）

**Interfaces:**
- Produces: 环境变量约定 `DEVECO_HOME=/Applications/DevEco-Studio.app`、`OHOS_NDK_HOME=$DEVECO_HOME/Contents/sdk/default/openharmony/native`、`HVIGORW=$DEVECO_HOME/Contents/tools/hvigor/bin/hvigorw`（后续任务全部使用这三个路径）

- [ ] **Step 1: 尝试 Homebrew 安装**

```bash
brew install --cask deveco-studio
```

Expected: 安装完成无报错。若报 `No available formula`（K1），执行 Step 2；否则跳到 Step 3。

- [ ] **Step 2:（K1 回退）提示用户手动安装**

向用户说明：请从 https://developer.huawei.com/consumer/cn/deveco-studio/download 下载 macOS 版 DMG 并拖入 /Applications（建议用户用 `! ` 前缀执行命令或手动操作）。等待用户确认完成。

- [ ] **Step 3: 验证 IDE 与 NDK 工具链存在**

```bash
ls /Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/build/cmake/ohos.toolchain.cmake \
  && ls "/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/"
```

Expected: 两个路径都存在（输出 ohos.toolchain.cmake 与 hvigorw 等）。若 NDK 路径不存在（K2），请用户打开一次 DevEco Studio 完成首次 SDK 下载后重试本步。

- [ ] **Step 4: 验证 NDK cmake 可执行**

```bash
OHOS_NDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
"$OHOS_NDK_HOME/build-tools/cmake/bin/cmake" --version
```

Expected: 输出 cmake version ≥ 3.18。

- [ ] **Step 5: 记录并向用户确认账号事项（非阻塞）**

输出提示：注册华为个人开发者账号（ https://developer.huawei.com/consumer/cn/ ）为 B 轨真机签名前置项，可与开发并行办理，不阻塞轨道 A。同时提醒真机采购（B 轨硬依赖）。

**本任务无 commit（无仓库变更）。**

---

### Task 2: 工程骨架 + 首次可构建 HAP

**Files:**
- Create: `.gitignore`
- Create: `oh-package.json5`（工程根元数据）
- Create: `build-profile.json5`（工程级）
- Create: `hvigor/hvigor-config.json5`
- Create: `AppScope/app.json5`
- Create: `AppScope/resources/base/element/string.json`
- Create: `entry/oh-package.json5`
- Create: `entry/build-profile.json5`
- Create: `entry/src/main/module.json5`
- Create: `entry/src/main/ets/entryability/EntryAbility.ets`
- Create: `entry/src/main/ets/pages/Index.ets`
- Create: `entry/src/main/resources/base/profile/main_pages.json`
- Create: `entry/src/main/resources/base/element/string.json`
- Create: `entry/src/main/resources/base/element/color.json`
- Create: `entry/src/main/resources/base/media/app_icon.png`（占位图标，后续资产任务替换）

**Interfaces:**
- Produces: bundleName `com.planetport.harmony`；可构建的空 HAP，产物路径 `entry/build/default/outputs/default/entry-default-unsigned.hap`；页面路由 `pages/Index`。后续任务在此基础上叠加 native 集成。

- [ ] **Step 1: 写工程根配置**

`.gitignore`：

```gitignore
# ZeroTier 核心源码（bootstrap 拉取，不入库）
Core/

# 构建产物
/build/
/entry/build/
/entry/.cxx/
/core/build/
*.hap
*.so
*.a

# hvigor / ohpm
/.hvigor/
/oh_modules/
/entry/oh_modules/
**/oh_modules/

# 本地环境
/local.properties
/.idea/
*.DS_Store

# 签名材料（永不入库）
*.p12
*.p7b
*.cer
/signing/
```

`oh-package.json5`：

```json5
{
  "modelVersion": "5.0.0",
  "description": "Planet Port - HarmonyOS",
  "dependencies": {},
  "devDependencies": {
    "@ohos/hypium": "1.0.19"
  }
}
```

`build-profile.json5`：

```json5
{
  "app": {
    "signingConfigs": []
  },
  "products": [
    {
      "name": "default",
      "signingConfig": "default",
      "compatibleSdkVersion": "5.0.0(12)",
      "runtimeOS": "HarmonyOS",
      "buildOption": {
        "strictMode": {
          "caseSensitiveCheck": true,
          "useNormalizedOHMUrl": true
        }
      }
    }
  ],
  "modules": [
    {
      "name": "entry",
      "srcPath": "./entry",
      "targets": [
        {
          "name": "default",
          "applyToProducts": ["default"]
        }
      ]
    }
  ]
}
```

> 注：`compatibleSdkVersion` 字段名可能因 DevEco 版本为 `"5.0.0(12)"` 或 `"5.0.5(17)"` 等格式；若 assembleHap 报 schema 错误（K3），按报错提示调整。

`hvigor/hvigor-config.json5`：

```json5
{
  "modelVersion": "5.0.0",
  "dependencies": {},
  "execution": {},
  "logging": {},
  "debugging": {},
  "nodeOptions": {}
}
```

- [ ] **Step 2: 写 AppScope**

`AppScope/app.json5`：

```json5
{
  "app": {
    "bundleName": "com.planetport.harmony",
    "vendor": "planetport",
    "versionCode": 1,
    "versionName": "0.1.0",
    "icon": "$media:app_icon",
    "label": "$string:app_name"
  }
}
```

`AppScope/resources/base/element/string.json`：

```json
{
  "string": [
    { "name": "app_name", "value": "Planet Port" }
  ]
}
```

- [ ] **Step 3: 写 entry 模块配置**

`entry/oh-package.json5`：

```json5
{
  "name": "entry",
  "version": "1.0.0",
  "description": "Planet Port entry module",
  "main": "",
  "author": "",
  "license": "MIT",
  "dependencies": {}
}
```

`entry/build-profile.json5`：

```json5
{
  "apiType": "stageMode",
  "buildOption": {},
  "buildOptionSet": [
    {
      "name": "release",
      "arkOptions": {
        "obfuscation": {
          "ruleOptions": {
            "enable": false,
            "files": ["./obfuscation-rules.txt"]
          }
        }
      },
      "nativeLib": {
        "debugSymbol": {
          "strip": true,
          "exclude": []
        }
      }
    }
  ],
  "targets": [
    { "name": "default" }
  ]
}
```

`entry/src/main/module.json5`（对齐规格 §4 与先例 VpnExtension 注册模板；vpnext 壳 A3 才实现，本任务先注册占位入口文件）：

```json5
{
  "module": {
    "name": "entry",
    "type": "entry",
    "description": "$string:module_desc",
    "mainElement": "EntryAbility",
    "deviceTypes": ["phone", "tablet"],
    "deliveryWithInstall": true,
    "installationFree": false,
    "pages": "$profile:main_pages",
    "abilities": [
      {
        "name": "EntryAbility",
        "srcEntry": "./ets/entryability/EntryAbility.ets",
        "description": "$string:EntryAbility_desc",
        "icon": "$media:app_icon",
        "label": "$string:app_name",
        "startWindowIcon": "$media:app_icon",
        "startWindowBackground": "$color:start_window_background",
        "exported": true,
        "skills": [
          {
            "entities": ["entity.system.home"],
            "actions": ["action.system.home"]
          }
        ]
      }
    ],
    "requestPermissions": [
      { "name": "ohos.permission.INTERNET" },
      { "name": "ohos.permission.GET_NETWORK_INFO" }
    ]
  }
}
```

> 注：`extensionAbilities` 的 vpn 注册在 A3（壳实现时）一并加入，避免本任务存在无实体的注册。

- [ ] **Step 4: 写 Ability 与页面**

`entry/src/main/ets/entryability/EntryAbility.ets`：

```typescript
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const TAG = 'PlanetPort';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'Failed to load content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, 'Succeeded in loading content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onWindowStageDestroy');
  }
}
```

`entry/src/main/ets/pages/Index.ets`（临时占位页，Task 5 改为显示核心版本）：

```typescript
@Entry
@Component
struct Index {
  build() {
    Column({ space: 12 }) {
      Text('Planet Port')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Text('工程骨架占位页')
        .fontSize(14)
        .fontColor('#666666')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
```

`entry/src/main/resources/base/profile/main_pages.json`：

```json
{
  "src": ["pages/Index"]
}
```

`entry/src/main/resources/base/element/string.json`：

```json
{
  "string": [
    { "name": "module_desc", "value": "Planet Port 主模块" },
    { "name": "EntryAbility_desc", "value": "Planet Port" }
  ]
}
```

`entry/src/main/resources/base/element/color.json`：

```json
{
  "color": [
    { "name": "start_window_background", "value": "#FFFFFF" }
  ]
}
```

- [ ] **Step 5: 生成占位图标**

```bash
mkdir -p entry/src/main/resources/base/media AppScope/resources/base/media
python3 -c "
import struct, zlib
def png(w, h, rgb):
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
open('AppScope/resources/base/media/app_icon.png', 'wb').write(png(216, 216, (32, 96, 168)))
open('entry/src/main/resources/base/media/app_icon.png', 'wb').write(png(216, 216, (32, 96, 168)))
"
```

Expected: 两个目录各出现 app_icon.png（纯色占位，正式 logo 后续资产任务替换）。

- [ ] **Step 6: 首次构建 HAP**

```bash
DEVECO_HOME="/Applications/DevEco-Studio.app"
"$DEVECO_HOME/Contents/tools/hvigor/bin/hvigorw" --sync
"$DEVECO_HOME/Contents/tools/hvigor/bin/hvigorw" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

Expected: BUILD SUCCESSFUL；`entry/build/default/outputs/default/entry-default-unsigned.hap` 存在。schema 报错按 K3 修复后重试。

- [ ] **Step 7: 验证产物**

```bash
unzip -l entry/build/default/outputs/default/entry-default-unsigned.hap | head -30
```

Expected: 列出 resources.pb、module.json 等条目。

- [ ] **Step 8: Commit**

```bash
git add .gitignore oh-package.json5 build-profile.json5 hvigor/ AppScope/ entry/
git commit -m "build: 鸿蒙工程骨架与首次可构建 HAP

Stage 模型最小工程：AppScope + entry 模块 + 占位首页，
bundleName com.planetport.harmony，兼容 SDK 5.0.0(API 12)。
构建产物与 hvigor/ohpm 缓存全部 gitignore。
VPN 扩展注册与 native 集成留给后续任务。"
```

---

### Task 3: bootstrap.sh 拉取 ZeroTier 1.16.2（对齐 Android 版，去 java 段）

**Files:**
- Create: `scripts/bootstrap.sh`
- Modify: `.gitignore`（确认 `Core/` 已忽略，无改动则跳过）

**Interfaces:**
- Produces: `Core/` 目录（node/、include/、osdep/ 子集、ext/ 依赖、version.h、.fetched-tag），幂等可重跑；环境变量口子 `ZT_TARBALL_URL`、`ZT_CACHE_DIR`。Task 4 的 CMake 依赖 `Core/node/*.cpp`、`Core/osdep/OSUtils.cpp`、`Core/include/`、`Core/ext/`。

- [ ] **Step 1: 写 bootstrap.sh**

`scripts/bootstrap.sh`（基于 Android 版平移：CORE_DIR 改 `Core/`、删除 java SDK 拷贝段、保持校验/缓存/幂等逻辑原样）：

```bash
#!/usr/bin/env bash
# 拉取 ZeroTier 核心源码（新克隆后执行一次即可）。
#
# 用法：
#   ./scripts/bootstrap.sh
#
# 网络不畅时：
#   1. 换镜像：ZT_TARBALL_URL=<镜像地址> ./scripts/bootstrap.sh
#   2. 完全手动：浏览器下载 tarball 放到缓存目录（默认 ~/Library/Caches/PlanetPort/
#      ZeroTierOne-<版本>.tar.gz）后重跑本脚本，校验通过则离线使用。
#
# 升级 ZeroTier 版本：修改下方 ZT_VERSION 与 ZT_SHA256 两个变量后重跑。
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ZT_VERSION=1.16.2
ZT_SHA256=2c607f573c6e38815433af289d364a689a203b18b51125f06c4472014d0657f0
ZT_URL="https://codeload.github.com/zerotier/ZeroTierOne/tar.gz/${ZT_VERSION}"

CACHE_DIR="${ZT_CACHE_DIR:-$HOME/Library/Caches/PlanetPort}"
TARBALL="${CACHE_DIR}/ZeroTierOne-${ZT_VERSION}.tar.gz"
CORE_DIR=Core
STAMP="${CORE_DIR}/.fetched-tag"

err() { echo "错误：$*" >&2; exit 1; }

verify_tarball() {
    echo "${ZT_SHA256}  ${TARBALL}" | shasum -a 256 --check - >/dev/null 2>&1
}

# ---- 拉取 ZeroTier 核心（已就绪则跳过） ----
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$ZT_VERSION" ]]; then
    echo "ZeroTier 核心 ${ZT_VERSION} 已就绪，跳过拉取"
else
    mkdir -p "$CACHE_DIR"

    # 缓存损坏则清除重下
    if [[ -s "$TARBALL" ]] && ! verify_tarball; then
        echo "缓存 tarball 校验失败，清除后重新下载"
        rm -f "$TARBALL"
    fi

    if [[ ! -s "$TARBALL" ]]; then
        echo "下载 ZeroTierOne ${ZT_VERSION} ..."
        curl -fL --retry 3 -o "$TARBALL" "${ZT_TARBALL_URL:-$ZT_URL}" || {
            rm -f "$TARBALL"
            err "下载失败。可用镜像：ZT_TARBALL_URL=<镜像地址> ./scripts/bootstrap.sh；或手动下载 tarball 放到 ${TARBALL} 后重跑"
        }
    fi

    verify_tarball || err "SHA256 校验失败（可能被镜像篡改或下载不完整），已保留缓存供排查：${TARBALL}"

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    tar -xzf "$TARBALL" -C "$TMP"
    SRC="${TMP}/ZeroTierOne-${ZT_VERSION}"

    # 只取工程所需子集：node/include 整目录，osdep 仅参与编译的源与 node 引用的头，
    # ext 仅 nlohmann/json.hpp 与 prometheus-cpp-lite 头目录、两个 salsa2012 汇编目录
    rm -rf "$CORE_DIR"
    mkdir -p "$CORE_DIR"
    cp -R "$SRC/node" "$CORE_DIR/"
    mkdir -p "$CORE_DIR/include"
    cp "$SRC/include/ZeroTierOne.h" "$SRC/include/ZeroTierDebug.h" "$CORE_DIR/include/"
    mkdir -p "$CORE_DIR/osdep"
    for f in Binder.hpp BlockingQueue.hpp ExtOsdep.hpp OSUtils.cpp OSUtils.hpp Phy.hpp; do
        cp "$SRC/osdep/$f" "$CORE_DIR/osdep/"
    done
    cp "$SRC/version.h" "$CORE_DIR/"
    mkdir -p "$CORE_DIR/ext/nlohmann" \
        "$CORE_DIR/ext/prometheus-cpp-lite-1.0/core/include" \
        "$CORE_DIR/ext/prometheus-cpp-lite-1.0/simpleapi/include"
    cp "$SRC/ext/nlohmann/json.hpp" "$CORE_DIR/ext/nlohmann/"
    cp -R "$SRC/ext/prometheus-cpp-lite-1.0/core/include/prometheus" \
        "$CORE_DIR/ext/prometheus-cpp-lite-1.0/core/include/"
    cp -R "$SRC/ext/prometheus-cpp-lite-1.0/simpleapi/include/prometheus" \
        "$CORE_DIR/ext/prometheus-cpp-lite-1.0/simpleapi/include/"
    cp -R "$SRC/ext/arm32-neon-salsa2012-asm" "$SRC/ext/x64-salsa2012-asm" "$CORE_DIR/ext/"

    echo "$ZT_VERSION" > "$STAMP"
    echo "ZeroTier 核心 ${ZT_VERSION} 就绪"
fi
```

- [ ] **Step 2: 赋权并执行**

```bash
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

Expected: `ZeroTier 核心 1.16.2 就绪`；`ls Core/` 显示 node、include、osdep、ext、version.h、.fetched-tag。

- [ ] **Step 3: 验证 git 忽略与幂等**

```bash
git status --short | head -5
./scripts/bootstrap.sh
```

Expected: git status 不出现 `Core/`（已在 .gitignore）；重跑输出「已就绪，跳过拉取」。

- [ ] **Step 4: 验证 SHA 校验失败路径**

```bash
sed -i '' 's/^ZT_SHA256=.*/ZT_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' scripts/bootstrap.sh
rm Core/.fetched-tag
./scripts/bootstrap.sh; echo "exit=$?"
# 文件尚未提交，不能用 git 还原；用 sed 改回正确值：
sed -i '' 's/^ZT_SHA256=.*/ZT_SHA256=2c607f573c6e38815433af289d364a689a203b18b51125f06c4472014d0657f0/' scripts/bootstrap.sh
```

Expected: 输出「SHA256 校验失败」且 `exit=1`（校验防线有效）；改回后 `grep ZT_SHA256 scripts/bootstrap.sh` 显示正确值。注意：删 stamp 后重跑会走校验失败分支（缓存 tarball 与假 SHA 不匹配）。

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.sh
git commit -m "build: ZeroTier 1.16.2 核心拉取脚本

对齐 Android 版 bootstrap：官方 tag tarball + SHA256 锁定 +
缓存复用 + 幂等标记；子集拷贝 node/include/osdep/ext。
差异：核心目录改为 Core/，去除官方 java SDK 拷贝段（鸿蒙不用 JNI）。"
```

---

### Task 4: CMake 交叉编译 ZeroTier 核心（arm64-v8a，S1 编译验证）

**Files:**
- Create: `core/CMakeLists.txt`
- Create: `core/bridge/CoreBridge.h`（最小骨架头，本任务只含版本查询；Task 5/6 扩展）
- Create: `core/bridge/CoreBridge.cpp`

**Interfaces:**
- Consumes: `Core/node/*.cpp`、`Core/osdep/OSUtils.cpp`、`Core/include/`、`Core/ext/`（Task 3 产出）
- Produces: CMake 目标 `zt_core`（ZeroTier 核心 OBJECT 库）；CMake 函数 `pp_core_version()`（CoreBridge，返回 `const char*`，如 `"1.16.2"`）；交叉编译入口 `core/CMakeLists.txt`。Task 5 在此之上加 NAPI 壳，Task 6 加 host 冒烟目标。

- [ ] **Step 1: 写 CoreBridge 最小骨架**

`core/bridge/CoreBridge.h`：

```cpp
// CoreBridge — ZeroTier C API 的 C++ 包装（直译自 iOS ZTBridge.mm 的最小骨架）。
// A2 阶段扩展：节点生命周期、行星状态目录重定向 hook、身份按行星分流。
#pragma once

namespace pp {

// ZeroTier 核心版本号（ZT_version），如 "1.16.2"
const char *coreVersion();

} // namespace pp
```

`core/bridge/CoreBridge.cpp`：

```cpp
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
```

> `snprintf` 需要 `<cstdio>`，ZeroTierOne.h 传递包含；若编译报缺声明，在文件头补 `#include <cstdio>`。

- [ ] **Step 2: 写 core/CMakeLists.txt**

```cmake
# core/CMakeLists.txt — libplanetport_core 构建入口
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
```

- [ ] **Step 3: 首次交叉编译探测（零补丁直编）**

```bash
cmake -B core/build-ohos -S core \
  -DCMAKE_TOOLCHAIN_FILE="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/build/cmake/ohos.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DOHOS_ARCH=arm64-v8a \
  -DOHOS_PLATFORM_LEVEL=12 \
  -DOHOS_STL=c++_shared
cmake --build core/build-ohos -j8
```

Expected: 编译完成（K4/K6 处置见 Step 4）。产物为对象文件集合（zt_core OBJECT 库无链接产物，本步验证 = 全部 .cpp 编译通过）。

- [ ] **Step 4:（按需）处置平台检测失败**

若 Step 3 报错：
- 缺 `Http.cpp`/`http_parser`（K6）：bootstrap.sh 的 osdep 拷贝循环加入 `Http.cpp`，ext 拷贝加 `http-parser` 目录，CMake zt_core 源集加 `${ZT_DIR}/osdep/Http.cpp` 与 `${ZT_DIR}/ext/http-parser/http_parser.c`（需要 `enable_language(C)`）
- 平台检测类错误（K4）：在 `add_compile_definitions` 注入对应 `-D`（如 musl 下 `_GNU_SOURCE`）。**禁止修改 Core/ 内文件**；若 -D 无法解决，停止并报告用户（零补丁红线，需用户裁决）

每处调整后在 `core/CMakeLists.txt` 头部注释区记录一行原因。

- [ ] **Step 5: 验证对象产物为 arm64**

```bash
find core/build-ohos -name 'Node.cpp.o' -exec file {} \;
```

Expected: 输出含 `arm64`（aarch64）。若无 .o 文件，用 `find core/build-ohos -name '*.o' | head` 定位实际产物名再 file。

- [ ] **Step 6: Commit**

```bash
git add core/ scripts/bootstrap.sh
git commit -m "build(core): ZeroTier 1.16.2 核心 OHOS arm64 交叉编译通过

对齐 Android 编译清单（node 全集 GLOB + OSUtils.cpp，
排除 EmbeddedNetworkController），ZT_SDK=0 与 ZT_NO_PEER_METRICS。
附 CoreBridge 最小骨架（coreVersion）。
零补丁：平台适配仅经编译定义注入。<如有 K4/K6 处置，在此行概述>"
```

---

### Task 5: NAPI 壳 + entry 集成 + HAP 内含 native 库

**Files:**
- Create: `core/napi/planetport_napi.cpp`
- Modify: `core/CMakeLists.txt`（NAPI SHARED 目标落地）
- Modify: `entry/build-profile.json5`（externalNativeOptions）
- Modify: `entry/src/main/ets/pages/Index.ets`（显示核心版本）
- Create: `entry/src/main/ets/common/CoreRuntime.ets`（native 模块 ArkTS 包装）

**Interfaces:**
- Consumes: `pp::coreVersion()`（Task 4）
- Produces: ArkTS 模块 `libplanetport_core.so` 导出 `getCoreVersion(): string`；`CoreRuntime.getCoreVersion()`。A2 扩展同一模块（start/stop/snapshot 函数族）。

- [ ] **Step 1: 写 NAPI 绑定**

`core/napi/planetport_napi.cpp`：

```cpp
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
```

- [ ] **Step 2: CMake 加 SHARED 目标**

`core/CMakeLists.txt` 中将「NAPI 动态库占位」注释段替换为：

```cmake
# ---- NAPI 动态库（仅 OHOS 工具链下链接 libace_napi） ----
if(CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    add_library(planetport_core SHARED
        napi/planetport_napi.cpp
        bridge/CoreBridge.cpp
        $<TARGET_OBJECTS:zt_core>
    )
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
```

- [ ] **Step 3: entry 集成**

`entry/build-profile.json5` 的 `"buildOption": {}` 替换为：

```json5
{
  "buildOption": {
    "externalNativeOptions": {
      "path": "../core/CMakeLists.txt",
      "arguments": "-DOHOS_STL=c++_shared -DOHOS_PLATFORM_LEVEL=12",
      "abiFilters": ["arm64-v8a"],
      "cppFlags": ""
    }
  },
  "buildOptionSet": [
    {
      "name": "release",
      "arkOptions": {
        "obfuscation": {
          "ruleOptions": {
            "enable": false,
            "files": ["./obfuscation-rules.txt"]
          }
        }
      },
      "nativeLib": {
        "debugSymbol": {
          "strip": true,
          "exclude": []
        }
      }
    }
  ],
  "targets": [
    { "name": "default" }
  ]
}
```

> 若 hvigor 不接受跨目录 CMake 路径（K5）：在 `entry/src/main/cpp/CMakeLists.txt` 写 `add_subdirectory(../../../../core core)`（相对路径以实际层级为准），externalNativeOptions.path 改指该文件。

- [ ] **Step 4: 写 ArkTS 包装与版本页**

`entry/src/main/ets/common/CoreRuntime.ets`：

```typescript
// native 模块 ArkTS 包装（A2 扩展为完整函数族）
import core from 'libplanetport_core.so';

export namespace CoreRuntime {
  export function getCoreVersion(): string {
    return core.getCoreVersion() as string;
  }
}
```

`entry/src/main/ets/pages/Index.ets` 整体替换为：

```typescript
import { CoreRuntime } from '../common/CoreRuntime';

@Entry
@Component
struct Index {
  private version: string = '未加载';

  aboutToAppear(): void {
    this.version = CoreRuntime.getCoreVersion();
  }

  build() {
    Column({ space: 12 }) {
      Text('Planet Port')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Text(`ZeroTier 核心 ${this.version}`)
        .fontSize(14)
        .fontColor('#666666')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
```

- [ ] **Step 5: 构建 HAP 并验证 native 库已打包**

```bash
DEVECO_HOME="/Applications/DevEco-Studio.app"
"$DEVECO_HOME/Contents/tools/hvigor/bin/hvigorw" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
unzip -l entry/build/default/outputs/default/entry-default-unsigned.hap | grep -E 'libs/arm64-v8a|module.json'
```

Expected: BUILD SUCCESSFUL；unzip 列表含 `libs/arm64-v8a/libplanetport_core.so`。

- [ ] **Step 6: Commit**

```bash
git add core/ entry/
git commit -m "feat(core): NAPI 壳接入工程，HAP 打包 libplanetport_core.so

napi 模块 planetport_core 导出 getCoreVersion，首页展示
ZeroTier 核心版本号（S1 验收的逻辑链路，真机内验证待 B 轨）。"
```

---

### Task 6: host 冒烟测试（macOS 本机验证核心可跑）

**Files:**
- Create: `core/smoke/smoke_main.cpp`
- Modify: `core/bridge/CoreBridge.h`、`core/bridge/CoreBridge.cpp`（加 identity 冒烟函数）
- Modify: `core/CMakeLists.txt`（smoke 目标）

**Interfaces:**
- Consumes: `zt_core` 对象库（Task 4）
- Produces: `pp::smokeIdentityGen(const char *homeDir)`（CoreBridge：生成节点身份到 homeDir，返回 10 位节点地址字符串；错误返回空串）——A2 的 CoreBridge 完整版在此基础上生长
- Produces: host 冒烟二进制 `core/build-host/smoke`

- [ ] **Step 1: CoreBridge 加身份生成**

`core/bridge/CoreBridge.h` 在 `coreVersion()` 声明后追加：

```cpp
// 生成节点身份到 homeDir/identity.secret（已存在则复用）。
// 返回 10 位节点地址（十进制字符串）；失败返回空串。
const char *smokeIdentityGen(const char *homeDir);
```

`core/bridge/CoreBridge.cpp` 追加（ZT_Node_new 需要的最小回调集——全部空实现，冒烟只验证核心链接与身份生成路径）：

```cpp
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/stat.h>

namespace pp {

namespace {

// 最小回调 stub：冒烟不进入网络路径，只需非空回调指针满足 ZT_Node_new 契约
void cbVirtualNetworkFrame(void *, void *, uint64_t, void **, uint64_t, const void *, unsigned int, unsigned int,
                           const void *, unsigned int, unsigned int, int) {}
int cbEventCallback(void *, void *, unsigned long, const void *) { return 0; }
void cbStatePutFunction(void *, void *, enum ZT_StateObjectType, const void *, int, const void *, unsigned int) {}
int cbStateGetFunction(void *, void *, enum ZT_StateObjectType, const void *, int, void *, unsigned int *)
{
    return 0;
}
void cbWirePacketSendFunction(void *, void **, int, const struct sockaddr_storage *, const void *, unsigned int,
                              unsigned int) {}
int cbPathCheckFunction(void *, void **, const struct sockaddr_storage *, const struct sockaddr_storage *) { return 0; }
int cbPathLookupFunction(void *, void **, uint64_t, int, struct sockaddr_storage *) { return 0; }
void cbVirtualNetworkConfigFunction(void *, void **, uint64_t, void **, enum ZT_VirtualNetworkConfigOperation,
                                    const ZT_VirtualNetworkConfig *) {}

ZT_Node *makeNode(void *ctx)
{
    return ZT_Node_new(
        ctx,
        nullptr,
        cbVirtualNetworkFrame,
        cbEventCallback,
        cbStatePutFunction,
        cbStateGetFunction,
        cbWirePacketSendFunction,
        cbPathCheckFunction,
        cbPathLookupFunction,
        cbVirtualNetworkConfigFunction);
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
    snprintf(addrBuf, sizeof(addrBuf), "%llu", (unsigned long long)addr);
    ZT_Node_delete(node);
    return addrBuf;
}

} // namespace pp
```

> 注：回调签名以 `Core/include/ZeroTierOne.h` 实际声明为准（1.16.2 的 C API 回调形参可能与上述有出入，编译报错时对齐头文件签名调整 stub——这是对官方头文件的适配，不算改源码）。ZT_Node_new 不带持久化回调上下文时身份仅存内存——冒烟验证点改为「节点地址稳定非零 + 二次创建同 identity 复用逻辑留 A2」；本冒烟以「node 可创建、地址 10 位、coreVersion 正确」为通过线。

- [ ] **Step 2: 写冒烟 main**

`core/smoke/smoke_main.cpp`：

```cpp
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
```

- [ ] **Step 3: CMake 加 smoke 目标**

`core/CMakeLists.txt` 的 `if(PP_BUILD_SMOKE)` 段替换为：

```cmake
if(PP_BUILD_SMOKE)
    add_executable(smoke
        smoke/smoke_main.cpp
        bridge/CoreBridge.cpp
        $<TARGET_OBJECTS:zt_core>
    )
    target_include_directories(smoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
endif()
```

- [ ] **Step 4: 构建 host 冒烟（macOS 原生工具链，非交叉）**

```bash
cmake -B core/build-host -S core -DCMAKE_BUILD_TYPE=Debug -DPP_BUILD_SMOKE=ON
cmake --build core/build-host -j8
./core/build-host/smoke
```

Expected: 输出 `PASS coreVersion = 1.16.2`、`PASS identityGen addr = <10位>`、`SMOKE PASS`，退出码 0。
（host 下 ZeroTier 走 macOS 分支编译——与 OHOS 分支不同，冒烟验证的是「核心源码+CoreBridge 链接与身份路径」，平台分支正确性由 Task 4 交叉编译保证。）

- [ ] **Step 5: 验证交叉编译仍通过（防 host 改动破坏 OHOS 路径）**

```bash
cmake --build core/build-ohos -j8
```

Expected: BUILD SUCCESSFUL。

- [ ] **Step 6: Commit**

```bash
git add core/ .gitignore
git commit -m "test(core): host 冒烟验证核心与 CoreBridge 身份路径

macOS 本机编译同一份 zt_core + CoreBridge（规格 D13）：
coreVersion 断言 1.16.2、ZT_Node 创建且节点地址 10 位。
交叉编译路径回归通过。"
```

---

### Task 7: 工程文档与 A1 收尾

**Files:**
- Create: `README.md`
- Create: `docs/build-notes.md`（构建事实记录）

**Interfaces:**
- Produces: 面向贡献者的构建说明；平台适配处置记录（Task 4 实际发生的 K4/K6 处置与结论，供 A2 与 B 轨查阅）

- [ ] **Step 1: 写 README.md**

```markdown
# Planet Port - HarmonyOS 🪐

简体中文

**Planet Port** 是开源的鸿蒙 ZeroTier 客户端，基于 ZeroTier 1.16.2 官方核心构建，
ArkUI 原生写成。多行星并存、多网络同连、默认路由与 DNS 均可控。

> 非官方客户端，与 ZeroTier, Inc. 无隶属关系。
> 开发中（轨道 A），功能对齐 [planet-port-ios](../planet-port-ios) v1.4.0。

## 从源码构建

前置：DevEco Studio 5.0+（含 HarmonyOS SDK 与 NDK）。

​```bash
./scripts/bootstrap.sh   # 拉取 ZeroTier 1.16.2 核心（SHA256 锁定，不入库）
"/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw" \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
​```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

host 冒烟（macOS 本机验证核心，无需真机）：

​```bash
cmake -B core/build-host -S core -DCMAKE_BUILD_TYPE=Debug -DPP_BUILD_SMOKE=ON
cmake --build core/build-host -j8 && ./core/build-host/smoke
​```

## 许可

- ZeroTier 核心：MPL-2.0（构建时拉取，零补丁）
- 本项目代码：MIT
​```

（写入文件时把 ​``` 转义符还原为三反引号。）

- [ ] **Step 2: 写 docs/build-notes.md**

记录内容（按 Task 4 实际处置如实填写）：

```markdown
# 构建事实记录

## ZeroTier 1.16.2 OHOS 交叉编译处置（A1）

- 平台检测：<直编通过 / 注入了哪些 -D 宏 / K6 增拷了哪些文件>
- 与先例（HarmonyRun/ZeroTier-HarmonyOS 修改 Constants.hpp）的差异与原因：零补丁原则
- host 冒烟结论：coreVersion / identityGen 结果
- 已知未验证项（待 B 轨真机）：.so 在真机加载、TUN、protect
```

- [ ] **Step 3: 全量回归三链路**

```bash
./core/build-host/smoke                                    # host 冒烟
cmake --build core/build-ohos -j8                          # OHOS 交叉编译
"/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw" \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon  # HAP
```

Expected: 三链路全部成功。

- [ ] **Step 4: Commit**

```bash
git add README.md docs/build-notes.md
git commit -m "docs: 构建说明与 A1 平台适配事实记录

README 收录 bootstrap/hvigorw/host 冒烟三链路构建方法；
build-notes 落档零补丁处置过程与 B 轨待验证项。"
```

---

## 计划完成标准（A1 验收）

1. `./scripts/bootstrap.sh` 幂等可用，SHA256 防线验证过
2. `core/build-ohos` arm64 交叉编译通过（ZeroTier 核心 + CoreBridge + NAPI）
3. `entry-default-unsigned.hap` 内含 `libs/arm64-v8a/libplanetport_core.so`
4. `./core/build-host/smoke` 输出 SMOKE PASS（coreVersion=1.16.2 + 身份生成 10 位地址）
5. ZeroTier 核心零补丁（Core/ 与官方 tarball 逐字节一致，子集拷贝除外）
6. 全部提交符合 Conventional Commits 中文规范，未 push

> S1 的「App 内 startNode/身份生成/核心版本号可读」在真机上的最终确认属于 B 轨（Spike S1 收尾），本计划完成其全部代码与逻辑验证部分。

## 后续计划（本计划完成后编写）

- 计划 2（A2）：CoreBridge 完整版（planet 状态重定向 hook、身份分流、串行队列）+ 数据面 C++ 直译 + host 金标向量单测
- 计划 3（A3+A4）：VpnExt 壳 + TunnelController + store 层
- 计划 4（A5）：UI 7 页 + qrtransfer + 三语 + 主题
- 计划 5（A6+B 轨）：CI + Spike + 真机联调验收
