# Planet Port 鸿蒙版 A3（VpnExt 壳 + TunnelController）+ A4（store 层）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地隧道双进程编排（VpnExtensionAbility 壳 + C++ TunnelRuntime 状态机 + 主进程 TunnelController/StatusStore）与 store 持久化层（四份 JSON 配置 + 身份文件 + 主题/语言），使 A2 的 CoreBridge/数据面八模块在鸿蒙上成为可启动、可编排、可观测的完整隧道。

**Architecture:** 主进程（UIAbility）与 VPN 扩展进程（VpnExtensionAbility，`extensionAbilities type:"vpn"`）共享同一应用沙盒。配置主路径 = 共享沙盒 `config/*.json` + commonEvent 唤醒 + level-triggered 全量重读（D5）；核心宿主在扩展进程，TunnelManager 全状态机直译为 C++ TunnelRuntime（host 可单测），NAPI 以粗粒度函数族暴露（start/stop/swapFd/restartCore/snapshot/protect 回调，D2）；换代 = destroy+create 同进程 + `Dataplane.swap(fd)`（D3）；跨进程状态契约 = 快照文件 + commonEvent（D1）。

**Tech Stack:** ArkTS（API 26，@ohos.file.fs / @ohos.net.vpnExtension / @ohos.net.connection / @ohos.commonEventManager / @ohos.events.emitter）、C++17（NAPI、无新第三方依赖）、gtest host 单测（延续 A2 `native/build-host`）。

## Global Constraints

- **零补丁红线**：`Core/`（官方 1.16.2 tarball）禁改；一切交互经官方 C API。
- **包名** `cn.imgozi.h.planetport`；commonEvent 事件名前缀 `cn.imgozi.h.planetport.`。
- **直译口径**：A3 隧道编排行为规格 = Android v1.6.0 `planet-port-android/app/src/main/java/cn/imgozi/planetport/tunnel/`（TunnelManager/TunnelController/TunnelStateBus/NodeRuntime 语义），与 iOS v1.4.0 冲突时以 iOS 裁决；A4 store = Android `store/` 九文件接口全量直译（Importer/BackgroundImageStore 留 A5）；主题色彩数学 = iOS `PlanetPort/ThemeManager.swift`；语言 = iOS `Shared/LanguageManager.swift` 枚举值域。
- **D13 测试标准**：host 单测只覆盖纯逻辑 C++（ColorMath、TunnelRuntime 状态机）；ArkTS 任务验收 = `assembleHap` 编译通过 + 与直译源逐行为对照的 review；真机行为验证统一挂 A6/B 轨，不在本计划内臆测平台行为。
- **D14 返工隔离面**：依赖 Spike 结论（protect 有效性、fd 生命周期、RouteInfo 填法、onDestroy 时限）的逻辑只许出现在 `entry/src/main/ets/vpnext/` 与 `native/napi/` 的 protect 回调路径；越界即打回。
- **平台 API 事实**（DevEco SDK API 26 d.ts 一手，直译时按此为准）：
  - `VpnExtensionAbility` 仅有 `onCreate(want)/onDestroy()`，无 onConnect/onRevoke。
  - `createVpnConnection(context)` 同步返回 VpnConnection；**必须先 `startVpnExtensionAbility(want)`**；`create(VpnConfig): Promise<number>` 返回**裸 fd**；`destroy(): Promise<void>`；`protect(fd)` 与 `protectProcessNet()`（@since 22，本工程 targetAPI 26 满足）。
  - `VpnConfig`：`addresses: LinkAddress[]` 唯一必填；`mtu` 硬性范围 **[576,1500]**（D8 clamp 1500 与之吻合）；`isIPv6Accepted` 默认 false；`trustedApplications/blockedApplications` 互斥（本项目均不使用，对齐 Android 无 addDisallowedApplication）。`LinkAddress{address: NetAddress, prefixLength}`、`RouteInfo{interface, destination: LinkAddress, gateway: NetAddress, hasGateway: boolean}`、`NetAddress{address: string, family?: 1|2, port?}`。
  - `@ohos.file.fs` **无 chmod、open 无权限位**——0600 语义由应用沙盒隔离天然保证（C++ 侧 `putFileAtomic(secure)` 已落地）；ArkTS 侧不做也无法做权限收紧，直译 IdentityStore 时该差异记录在文件头注释。
  - `resourceManager.getStringSync` **不支持指定 locale**——应用内语言切换走 LanguageManager 内嵌三语表查表（机制本任务落地，全量表 A5 填充）。
  - 两进程 `filesDir` 同路径（应用沙盒按 bundle 划分）——共享沙盒方案成立；并发写由 store 层原子写 + 单写方约定保证。
  - VpnExt 进程内**禁用** `@ohos.contact / @ohos.geolocation* / @ohos.multimedia.audio / @ohos.multimedia.camera / @ohos.telephony.*`（d.ts NOTE：可能异常退出）——vpnext/ 下禁止 import。
  - commonEvent：`commonEventManager.publish(event, {code, data})` / `createSubscriber` 订阅，自定义事件名三方可用，无额外权限。
- **UNVERIFIED（真机/B 轨 Spike 验证，实现按最稳假设 + 全部收敛在 D14 隔离面内）**：
  1. NDK 原生 socket fd 传入 `protect(fd)` 是否被接受（S3）；→ A3 默认走 `protectProcessNet()` 进程级一次调用，per-socket 回调路径写好但壳内默认不启用。
  2. `create()` 返回 fd 在 `onDestroy` 后归属（壳内显式 `vpnConnection.destroy()` 兜底，不依赖系统回收）。
  3. `RouteInfo.interface` 填空串是否被接受（壳内组装处集中一个 helper，Spike 只改一处）。
  4. `onDestroy` 清理时限（停机路径先经 commonEvent 优雅终态化、再 stopVpnExtensionAbility 双保险）。
  5. `ohos.permission.MANAGE_VPN` 是否三方必需（d.ts `create()` 仅标 INTERNET；A3 只声明 INTERNET + GET_NETWORK_INFO，真机报权限错时加一行即可，挂账）。
- **构建命令**：host 单测 `cmake -B native/build-host -S native -DCMAKE_BUILD_TYPE=Debug -DPP_BUILD_SMOKE=ON -DPP_BUILD_TESTS=ON && cmake --build native/build-host -j8 && ctest --test-dir native/build-host --output-on-failure`；gtest 下载抖动绕过 `-DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=$PWD/build-t7/_deps/googletest-src`（源已在 `native/build-t7/_deps/googletest-src`）；交叉 `cmake -B native/build-ohos -S native -DCMAKE_TOOLCHAIN_FILE=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/build/cmake/ohos.toolchain.cmake -DOHOS_ARCH=arm64-v8a -DOHOS_STL=c++_shared -DOHOS_PLATFORM=OHOS -DCMAKE_BUILD_TYPE=Release`；HAP `export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" && /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`。
- **Git**：Conventional Commits 中文（type/scope 英文、description/Body 中文、必须 Body、禁止 Co-authored-by）；每任务独立提交；**严禁 git push**。

## File Structure

```
entry/src/main/ets/
├─ common/                      # Task 1：跨进程契约（两进程共用）
│  ├─ IpcEvents.ets             # commonEvent 事件名 + code 常量
│  ├─ TunnelContract.ets        # TunnelState 判别联合 + 快照 JSON 类型 + 编解码
├─ store/                       # Task 2-7：A4 直译 Android store/
│  ├─ Models.ets                # PlanetProfile/NetworkEntry/MoonEntry/AppPrefs + JSON 编解码
│  ├─ StorePaths.ets            # 沙盒路径布局（config/ planets/ zt/）
│  ├─ JsonFileStore.ets         # 原子写 + .corrupt 隔离
│  ├─ AppConfigStore.ets        # 四份 JSON 域 API + 变更信号（本地 listener + commonEvent）
│  ├─ IdentityStore.ets         # identity.public/secret 成对文件操作（共享/每行星）
│  ├─ StoreRepo.ets             # 进程单例门面
│  ├─ ThemeManager.ets          # 主色/派生开关（AppPrefs 驱动）+ NAPI ColorMath 消费
│  └─ LanguageManager.ets       # AppLanguage 枚举 + 内嵌三语表 + loc()
├─ tunnel/                      # Task 11：主进程侧编排
│  ├─ StatusStore.ets           # 快照文件读方 + commonEvent 订阅 → 状态流（UI 订阅点）
│  └─ TunnelController.ets      # ensureStarted/stop/restartIfRunning + 启动窗口/代际
├─ vpnext/                      # Task 10：扩展进程（D14 隔离面）
│  ├─ ZeroTierVpnExtAbility.ets # VpnExtensionAbility 壳（onCreate/onDestroy/start/stop 编排）
│  ├─ ExtRuntime.ets            # NAPI 函数族包装 + onConfigAssembled→VpnConfig→create→swapFd
│  ├─ ExtStateBus.ets           # 扩展进程侧状态聚合 + 快照写方 + STATE_CHANGED 发布
│  └─ ExtNetWatch.ets           # @ohos.net.connection 切网监听（D9，防抖 1.5s）
native/
├─ runtime/TunnelRuntime.h/.cpp # Task 8：TunnelManager+NodeRuntime 编排直译（host 可单测）
├─ theme/ColorMath.h/.cpp       # Task 6：iOS ThemeManager 色彩数学直译
├─ napi/planetport_napi.cpp     # Task 9：三函数族 + protect tsfn（D14 隔离面）
└─ CMakeLists.txt               # Task 6/8 增源、Task 9 接线
entry/src/main/module.json5     # Task 12：extensionAbilities 声明
```

依赖序：Task 1 → {2, 6, 8} → {3, 9} → 4 → {5, 10} → 11 → 12（10 依赖 4/9；11 依赖 10）。

---

### Task 1: common/ 跨进程契约（IpcEvents + TunnelContract）

**Files:**
- Create: `entry/src/main/ets/common/IpcEvents.ets`
- Create: `entry/src/main/ets/common/TunnelContract.ets`

**Interfaces:**
- Consumes: 无（底座）。
- Produces: `IpcEvents`（事件名/code 常量）；`TunnelStateKind`（判别字符串字面量联合）；`TunnelState`（状态对象 + `tunnelStateFromJson`）；`TunnelSnapshot`（快照 JSON 接口 + `parseSnapshot`/`writeSnapshot`）；`alive()`（存活判定）。Task 10 写快照、Task 11 读快照、A5 UI 消费——字段名即跨进程契约，落地后禁改。

**直译源对照**：TunnelState 5 态对齐 `TunnelStateBus.kt:11-18`；存活判定对齐 `TunnelController.kt:82-86`；快照字段 = Android TunnelStateBus 全部 StateFlow 的快照投影（`TunnelStateBus.kt:50-101`）。

- [ ] **Step 1: 写 IpcEvents.ets**

```typescript
// IpcEvents.ets — 跨进程 commonEvent 契约（D1/D5）
//
// 两进程共享同一应用沙盒；控制指令与状态通知走 commonEvent（事件名前缀 =
// 包名倒序 + 应用名，防碰撞）。事件只做「唤醒」，负载一律 level-triggered
// 全量重读（对齐 Android configChanges 有损合并契约：订阅方不得假设收到每一次变更）。
//
// code 语义（publish 的 code 字段，data 不用——负载全走文件）：
//   CONFIG_CHANGED: 主进程写配置后唤醒 VpnExt 全量重读（join/leave/orbit 增量）
//   CMD_STOP:       主进程请求优雅停机（终态化快照后自停扩展进程）
//   CMD_RESTART:    主进程请求进程内换代重启（偏好热生效/行星切换，不重启进程）
//   STATE_CHANGED:  VpnExt 快照已更新，主进程 StatusStore 重读

export class IpcEvents {
  static readonly CONFIG_CHANGED: string = 'cn.imgozi.h.planetport.CONFIG_CHANGED';
  static readonly CMD_STOP: string = 'cn.imgozi.h.planetport.CMD_STOP';
  static readonly CMD_RESTART: string = 'cn.imgozi.h.planetport.CMD_RESTART';
  static readonly STATE_CHANGED: string = 'cn.imgozi.h.planetport.STATE_CHANGED';
}
```

- [ ] **Step 2: 写 TunnelContract.ets**

```typescript
// TunnelContract.ets — 隧道状态与快照 JSON 契约（D1：快照文件 + 事件唤醒）
//
// 直译源：TunnelStateBus.kt sealed interface TunnelState（5 态）与全部 StateFlow
// 字段。跨进程序列化形态：tunnelState 用 {kind, reason?, recoverable?} 判别对象；
// networkStatuses 存 ZT_VirtualNetworkStatus 原始码（键 16 位十六进制 nwid）——
// 不在隧道侧生成文案，文案由 UI 层生成（对齐 iOS 跨进程契约约定）。
// ArkTS 无 sealed interface：kind 用字符串字面量联合约束，编解码函数收窄。

// 状态判别字面量（对齐 TunnelStateBus.kt:11-18；kind 即序列化值）
export type TunnelStateKind = 'idle' | 'starting' | 'running' | 'reconnecting'
  | 'stopped' | 'failed';

export interface TunnelState {
  kind: TunnelStateKind;
  /** reconnecting: 'network_change'；stopped/failed: 原因码（UI 层生成文案） */
  reason?: string;
  /** 仅 failed：是否可恢复（对齐 Failed(reason, recoverable)） */
  recoverable?: boolean;
}

/** 存活判定：Running/Starting/Reconnecting 视为在跑（TunnelController.kt:82-86） */
export function alive(s: TunnelState | null): boolean {
  if (s === null) return false;
  return s.kind === 'running' || s.kind === 'starting' || s.kind === 'reconnecting';
}

/** 节点信息快照（TunnelStateBus.kt:21-25；nodeId 十位十六进制） */
export interface NodeStatusInfo {
  nodeId: string;
  online: boolean;
  coreVersion: string;
}

/** Peer 快照（TunnelStateBus.kt:33-39；address 为 ZT 40 位节点地址数值） */
export interface PeerEntry {
  address: number;
  version: string; // "v1.14.0"；版本未知 "v-1.-1.-1"
  latency: number;
  role: string; // "LEAF"/"MOON"/"PLANET"
  paths: string[]; // "ip:port"；空 = relay 中转
}

/** 网络配置快照（对齐 NetConf 跨进程投影；UI 详情页消费） */
export interface NetConfSnapshot {
  nwid: string; // 16 位十六进制
  name: string;
  status: number; // ZT_VirtualNetworkStatus 原始码
  type: string; // "PRIVATE"/"PUBLIC"
  mac: number;
  mtu: number;
  broadcastEnabled: boolean;
  bridge: boolean;
  dhcp: boolean;
  assignedAddrs: string[]; // "ip/prefix"
  routes: string[]; // "dest/prefix" 或 "dest/prefix via gw"
  dns: string[];
}

/** 快照文件根结构（VpnExt 写、主进程读；字段名即契约，禁改） */
export interface TunnelSnapshot {
  tunnelState: TunnelState;
  nodeStatus: NodeStatusInfo | null;
  pathSatisfied: boolean; // ExtNetWatch 透出（停机复位 true 防跨会话残留）
  coreVersion: string; // 缓存：停机不清，UI 显示最后已知版本
  networkStatuses: Record<string, number>; // nwid hex → status 原始码
  networkConflicts: Record<string, string>; // nwid hex → "address"|"subnet"
  networkConfigs: NetConfSnapshot[];
  peers: PeerEntry[];
  applyTrace: string;
  eventLog: string; // 最近 40 条滚动（TunnelStateBus.log 同源格式）
  writtenAt: number; // Date.now()，主进程侧陈旧性判定用
}

// ---- JSON 编解码（手写字段收窄，不引第三方库） ----

export function parseSnapshot(text: string): TunnelSnapshot | null {
  try {
    const o: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
    const st = o['tunnelState'] as Record<string, Object>;
    const state: TunnelState = { kind: st['kind'] as TunnelStateKind };
    if (st['reason'] !== undefined) state.reason = st['reason'] as string;
    if (st['recoverable'] !== undefined) state.recoverable = st['recoverable'] as boolean;
    const snap: TunnelSnapshot = {
      tunnelState: state,
      nodeStatus: o['nodeStatus'] === null ? null
        : o['nodeStatus'] as NodeStatusInfo,
      pathSatisfied: o['pathSatisfied'] as boolean,
      coreVersion: o['coreVersion'] as string,
      networkStatuses: o['networkStatuses'] as Record<string, number>,
      networkConflicts: o['networkConflicts'] as Record<string, string>,
      networkConfigs: o['networkConfigs'] as NetConfSnapshot[],
      peers: o['peers'] as PeerEntry[],
      applyTrace: o['applyTrace'] as string,
      eventLog: o['eventLog'] as string,
      writtenAt: o['writtenAt'] as number,
    };
    return snap;
  } catch (_e) {
    return null; // 半截/损坏快照 → 调用方按 Idle 处理
  }
}
```

- [ ] **Step 3: 编译验证**

Run: `export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" && /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`
Expected: BUILD SUCCESSFUL（新文件仅类型/常量，无引用方）。

- [ ] **Step 4: Commit**

```bash
git add entry/src/main/ets/common/
git commit -m "feat(common): 跨进程 IPC 契约与隧道快照类型

A3/A4 共用底座：commonEvent 事件名常量（D5 level-triggered 唤醒语义）、
TunnelState 5 态判别联合（直译 TunnelStateBus.kt）、快照文件 JSON 契约
（D1）。字段名为两进程序列化契约，落地后禁改。"
```

---

### Task 2: store/Models.ets（数据模型 + 手写 JSON 编解码）

**Files:**
- Create: `entry/src/main/ets/store/Models.ets`

**Interfaces:**
- Consumes: 无。
- Produces: `DnsMode`/`PlanetKind`（字符串枚举）、`PlanetProfile`、`NetworkEntry`、`MoonEntry`、`AppPrefs`（各含 `fromJson(o)/toJson()` 静态/成员方法，键名 camelCase 与 Android JSON 完全一致）；常量 `PlanetProfile.OFFICIAL_ID`、`PlanetProfile.OFFICIAL`、`MoonEntry.formatWorldId()`。Task 3/4/10 与 A5 UI 消费。

**直译源对照**：Android `store/Models.kt`（111 行）全量。序列化语义对齐 kotlinx：缺字段取默认值、未知键忽略、带默认值字段总是写出（encodeDefaults）。

- [ ] **Step 1: 写 Models.ets**

```typescript
// Models.ets — 持久化数据模型 + 手写 JSON 编解码
//
// 直译源：store/Models.kt（kotlinx-serialization @Serializable）。ArkTS 无
// 反射序列化：编解码手写，逐字段对照。序列化语义三条硬约束：
//   ① 读：缺字段取默认值（对齐 kotlinx 默认值语义）；
//   ② 读：未知键忽略（ignoreUnknownKeys）；
//   ③ 写：全部字段总是写出（encodeDefaults）——键名与 Android JSON 逐字一致
//      （camelCase；枚举为名字符串；ULong 为 JSON 数字）。
// language 值域差异（有意）：Android "zh"|"zh-rTW"|"en"|null，鸿蒙取 iOS 形态
// "system"|"zh-Hans"|"zh-Hant"|"en"（默认 "system"，无 null 分支）——两平台
// 沙盒互不相通，无兼容负担，LanguageManager 直接消费。

export enum DnsMode { None = 'none', Network = 'network', Custom = 'custom' }
export enum PlanetKind { Official = 'official', Custom = 'custom' }

export class PlanetProfile {
  id: string; // UUID 小写 / "official"
  name: string;
  kind: PlanetKind;
  fileName: string | null; // planets/ 下文件名
  icon: string | null; // 动物图标 key
  iconColor: string | null; // "#RRGGBB"

  constructor(id: string, name: string, kind: PlanetKind,
    fileName: string | null = null, icon: string | null = null,
    iconColor: string | null = null) {
    this.id = id; this.name = name; this.kind = kind;
    this.fileName = fileName; this.icon = icon; this.iconColor = iconColor;
  }

  static readonly OFFICIAL_ID: string = 'official';
  static readonly OFFICIAL: PlanetProfile =
    new PlanetProfile('official', 'ZeroTier 官方', PlanetKind.Official);

  static fromJson(o: Record<string, Object>): PlanetProfile {
    return new PlanetProfile(
      (o['id'] ?? 'official') as string,
      (o['name'] ?? '') as string,
      PlanetKind[(o['kind'] ?? 'official') as string] ?? PlanetKind.Official,
      o['fileName'] === undefined ? null : o['fileName'] as string,
      o['icon'] === undefined ? null : o['icon'] as string,
      o['iconColor'] === undefined ? null : o['iconColor'] as string,
    );
  }

  toJson(): Record<string, Object> {
    const o: Record<string, Object> = {
      'id': this.id, 'name': this.name, 'kind': this.kind as string as Object,
    };
    o['fileName'] = this.fileName === null ? '' as Object : this.fileName;
    // 注：null 与缺键的区分见 AppConfigStore.writePlanetsLocked——kotlinx 对
    // String? = null 默认值 + encodeDefaults 会写出 null 字面量；ArkTS 侧以
    // 空串占位再于 fromJson 收窄为 null（见下），往返等价。
    o['icon'] = this.icon === null ? '' as Object : this.icon;
    o['iconColor'] = this.iconColor === null ? '' as Object : this.iconColor;
    return o;
  }
}

export class NetworkEntry {
  networkId: string; // 16 位小写十六进制
  networkName: string;
  lastActivated: boolean;
  routeViaZeroTier: boolean;
  dnsMode: DnsMode;
  customDns: string[];
  planetId: string | null;
  lastConflict: string | null; // "address"|"subnet"|"timeout"；null=无

  constructor(networkId: string, networkName: string, lastActivated: boolean,
    routeViaZeroTier: boolean, dnsMode: DnsMode, customDns: string[],
    planetId: string | null = null, lastConflict: string | null = null) {
    this.networkId = networkId; this.networkName = networkName;
    this.lastActivated = lastActivated; this.routeViaZeroTier = routeViaZeroTier;
    this.dnsMode = dnsMode; this.customDns = customDns;
    this.planetId = planetId; this.lastConflict = lastConflict;
  }

  get id(): string { return this.networkId; } // 计算属性对齐 Kotlin val id get()

  static fromJson(o: Record<string, Object>): NetworkEntry {
    const dns = o['customDns'] as string[] ?? [];
    return new NetworkEntry(
      (o['networkId'] ?? '') as string,
      (o['networkName'] ?? '') as string,
      (o['lastActivated'] ?? false) as boolean,
      (o['routeViaZeroTier'] ?? false) as boolean,
      DnsMode[(o['dnsMode'] ?? 'none') as string] ?? DnsMode.None,
      dns,
      Models.nullOrString(o['planetId']),
      Models.nullOrString(o['lastConflict']),
    );
  }

  toJson(): Record<string, Object> {
    return {
      'networkId': this.networkId, 'networkName': this.networkName,
      'lastActivated': this.lastActivated, 'routeViaZeroTier': this.routeViaZeroTier,
      'dnsMode': this.dnsMode as string as Object, 'customDns': this.customDns,
      'planetId': Models.stringOrNull(this.planetId),
      'lastConflict': Models.stringOrNull(this.lastConflict),
    } as Record<string, Object>;
  }
}

export class MoonEntry {
  worldId: number; // JSON 数字（JS number 双精度安全：moon worldId ≪ 2^53）
  seed: number;
  fromFile: boolean;
  planetId: string | null;

  constructor(worldId: number, seed: number, fromFile: boolean,
    planetId: string | null = null) {
    this.worldId = worldId; this.seed = seed; this.fromFile = fromFile;
    this.planetId = planetId;
  }

  get id(): string { return MoonEntry.formatWorldId(this.worldId); }

  /** 16 位小写十六进制（%016x 直译；worldId 为无符号值，>>> 0 保真） */
  static formatWorldId(worldId: number): string {
    const v = worldId >>> 0;
    let s = '';
    for (let i = 7; i >= 0; i--) {
      s += ((v >>> (i * 4)) & 0xf).toString(16);
    }
    return s;
  }

  static fromJson(o: Record<string, Object>): MoonEntry {
    return new MoonEntry(
      (o['worldId'] ?? 0) as number,
      (o['seed'] ?? 0) as number,
      (o['fromFile'] ?? false) as boolean,
      Models.nullOrString(o['planetId']),
    );
  }

  toJson(): Record<string, Object> {
    return {
      'worldId': this.worldId >>> 0, 'seed': this.seed >>> 0,
      'fromFile': this.fromFile,
      'planetId': Models.stringOrNull(this.planetId),
    } as Record<string, Object>;
  }
}

export class AppPrefs {
  selectedPlanetId: string = PlanetProfile.OFFICIAL_ID;
  activePlanetId: string | null = null;
  disableIpv6: boolean = false;
  themeColor: number | null = null; // RGB（iOS UInt32 0xRRGGBB；非 ARGB——鸿蒙消费侧统一 RGB）
  themeColorCustom: number | null = null; // 非 null 时优先于 themeColor
  successDerived: boolean = false;
  language: string = 'system'; // "system"|"zh-Hans"|"zh-Hant"|"en"
  backgroundImage: boolean = false;
  parallax: boolean = true;
  maxNetworks: number = 2; // 2..6
  connectOnDemand: boolean = false; // 平台无 On Demand（降级①），字段保留直译
  identityPerPlanet: boolean = false;

  static fromJson(o: Record<string, Object>): AppPrefs {
    const p = new AppPrefs();
    p.selectedPlanetId = (o['selectedPlanetId'] ?? PlanetProfile.OFFICIAL_ID) as string;
    p.activePlanetId = Models.nullOrString(o['activePlanetId']);
    p.disableIpv6 = (o['disableIpv6'] ?? false) as boolean;
    p.themeColor = Models.nullOrNumber(o['themeColor']);
    p.themeColorCustom = Models.nullOrNumber(o['themeColorCustom']);
    p.successDerived = (o['successDerived'] ?? false) as boolean;
    p.language = (o['language'] ?? 'system') as string;
    p.backgroundImage = (o['backgroundImage'] ?? false) as boolean;
    p.parallax = (o['parallax'] ?? true) as boolean;
    p.maxNetworks = (o['maxNetworks'] ?? 2) as number;
    p.connectOnDemand = (o['connectOnDemand'] ?? false) as boolean;
    p.identityPerPlanet = (o['identityPerPlanet'] ?? false) as boolean;
    return p;
  }

  toJson(): Record<string, Object> {
    return {
      'selectedPlanetId': this.selectedPlanetId,
      'activePlanetId': Models.stringOrNull(this.activePlanetId),
      'disableIpv6': this.disableIpv6,
      'themeColor': Models.numberOrNull(this.themeColor),
      'themeColorCustom': Models.numberOrNull(this.themeColorCustom),
      'successDerived': this.successDerived,
      'language': this.language,
      'backgroundImage': this.backgroundImage,
      'parallax': this.parallax,
      'maxNetworks': this.maxNetworks,
      'connectOnDemand': this.connectOnDemand,
      'identityPerPlanet': this.identityPerPlanet,
    } as Record<string, Object>;
  }
}

/** null/空串互转（kotlinx null 字面量 ↔ ArkTS 空串占位的边界收口） */
export class Models {
  static nullOrString(v: Object | undefined): string | null {
    if (v === undefined || v === null) return null;
    const s = v as string;
    return s === '' ? null : s;
  }
  static stringOrNull(v: string | null): Object {
    return v === null ? '' as Object : v;
  }
  static nullOrNumber(v: Object | undefined): number | null {
    if (v === undefined || v === null) return null;
    return v as number;
  }
  static numberOrNull(v: number | null): Object {
    return v === null ? null as Object : v;
  }
}
```

- [ ] **Step 2: 编译验证**

Run: hvigorw assembleHap（同 Task 1 命令）
Expected: BUILD SUCCESSFUL。

- [ ] **Step 3: Commit**

```bash
git add entry/src/main/ets/store/Models.ets
git commit -m "feat(store): 持久化数据模型与 JSON 编解码

直译 store/Models.kt 四模型 + 枚举，手写编解码对齐 kotlinx 语义（缺字段
取默认/未知键忽略/总是写出全字段）。language 值域取 iOS 形态（有意的
平台适配，文件头注明）。"
```

---

### Task 3: store/StorePaths.ets + JsonFileStore.ets（路径布局 + 原子写 + 损坏隔离）

**Files:**
- Create: `entry/src/main/ets/store/StorePaths.ets`
- Create: `entry/src/main/ets/store/JsonFileStore.ets`

**Interfaces:**
- Consumes: 无（fs API）。
- Produces: `StorePaths`（`configDir/planetsDir/planetsFile/networksFile/moonsFile/prefsFile/planetStateDir(planetId)/dataStoreRoot/snapshotFile`，全部基于注入的 `filesDir` 根）；`JsonFileStore.read(file)` / `JsonFileStore.write(file, text)`（async，原子 tmp+rename，损坏隔离 .corrupt，进程内 async 串行队列）。Task 4/5/10/11 消费。

**直译源对照**：`StorePaths.kt:14-28` 路径布局逐字（含 `zt/$planetId` 正斜杠拼接）；`JsonFileStore.kt`（65 行）读写/隔离语义逐行为，Mutex 退化为 async 串行队列（ArkTS 单线程）。

- [ ] **Step 1: 写 StorePaths.ets**

```typescript
// StorePaths.ets — 沙盒路径布局（直译 store/StorePaths.kt）
//
// 两进程 filesDir 同路径（应用沙盒按 bundle 划分）——主进程与 VpnExt 各自
// new StorePaths(filesDir) 得到同一布局。快照文件为本计划新增（D1），挂
// filesDir 根（运行时状态，不入 config/ 配置目录）。
import { Context } from '@kit.AbilityKit';

export class StorePaths {
  readonly filesRoot: string;

  constructor(filesRoot: string) { this.filesRoot = filesRoot; }

  static of(ctx: Context): StorePaths { return new StorePaths(ctx.filesDir); }

  get configDir(): string { return `${this.filesRoot}/config`; }
  get planetsDir(): string { return `${this.filesRoot}/planets`; }
  get planetsFile(): string { return `${this.configDir}/planets.json`; }
  get networksFile(): string { return `${this.configDir}/networks.json`; }
  get moonsFile(): string { return `${this.configDir}/moons.json`; }
  get prefsFile(): string { return `${this.configDir}/prefs.json`; }
  planetStateDir(planetId: string): string { return `${this.filesRoot}/zt/${planetId}`; }
  get dataStoreRoot(): string { return `${this.filesRoot}/zt`; }
  get snapshotFile(): string { return `${this.filesRoot}/tunnel-snapshot.json`; }
}
```

- [ ] **Step 2: 写 JsonFileStore.ets**

```typescript
// JsonFileStore.ets — JSON 文件读写设施（直译 store/JsonFileStore.kt）
//
// 语义逐条对齐：读（不存在→null；解析失败→隔离 .corrupt→null，调用方用
// 内存默认值）；写（父目录逐级创建→写 .tmp→rename 原子替换；rename 失败删
// .tmp 抛）；隔离（改名 .corrupt，已存在先删，只留最近一次现场，.corrupt
// 存在时不自动重建）。Kotlin Mutex 在 ArkTS 退化为 async 串行队列（单线程
// 事件循环，await 挂起点即临界区边界）。
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'PlanetPortStore';
const READ_CHUNK = 64 * 1024;

export class JsonFileStore {
  // 串行队列：所有配置 IO 排队执行（Kotlin 全局 Mutex 的等价物）
  private queue: Promise<void> = Promise.resolve();

  /** 域锁（AppConfigStore.mutate 用）：块内 read/write 自动串行互斥 */
  async mutate<T>(block: () => Promise<T>): Promise<T> {
    const run = this.queue.then(block);
    this.queue = run.then(() => {}, () => {}); // 失败不断链
    return run;
  }

  async read(file: string): Promise<string | null> {
    try {
      return await fs.readText(file);
    } catch (_e) {
      return null; // 不存在 / 读失败均按 null（调用方回退默认值）
    }
  }

  async write(file: string, text: string): Promise<void> {
    const dir = file.substring(0, file.lastIndexOf('/'));
    await this.mkdirP(dir);
    const tmp = `${file}.tmp`;
    try {
      const f = await fs.open(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE
        | fs.OpenMode.TRUNC);
      await fs.write(f.fd, text);
      await fs.close(f.fd);
      await fs.rename(tmp, file); // 原子替换
    } catch (e) {
      try { await fs.unlink(tmp); } catch (_ignored) { /* 无 tmp 可清 */ }
      throw new Error(`config write failed (rename): ${file}`);
    }
  }

  /** 损坏隔离：改名 .corrupt（已存在先删——只留最近一次现场）；不抛 */
  async quarantine(file: string, cause: string): Promise<void> {
    try {
      const target = `${file}.corrupt`;
      try { await fs.unlink(target); } catch (_e) { /* 不存在即跳过 */ }
      await fs.rename(file, target);
      hilog.warn(0x0000, TAG, `配置损坏已隔离为 ${target} (${cause})`);
    } catch (_e) { /* 隔离失败不放大 */ }
  }

  private async mkdirP(dir: string): Promise<void> {
    const parts = dir.split('/');
    let cur = '';
    for (let i = 0; i < parts.length; i++) {
      if (parts[i] === '') { cur = '/'; continue; }
      cur = cur === '/' ? `/${parts[i]}` : `${cur}/${parts[i]}`;
      try { await fs.mkdir(cur); } catch (_e) { /* 已存在 */ }
    }
  }
}

// READ_CHUNK 保留直译常量位（ArkTS readText 整读，64KiB 限额语义由
// BoundedRead 在 A5 落地时复用）；hilog tag 对齐 Kotlin TAG 常量。
export { READ_CHUNK };
```

- [ ] **Step 3: 编译验证 + Commit**

```bash
git add entry/src/main/ets/store/StorePaths.ets entry/src/main/ets/store/JsonFileStore.ets
git commit -m "feat(store): 沙盒路径布局与 JSON 文件设施

直译 StorePaths.kt 路径布局（config/planets/zt 分区，快照文件挂根）与
JsonFileStore.kt 原子写/损坏隔离语义；Mutex 退化为 async 串行队列。"
```

---

### Task 4: store/AppConfigStore.ets + StoreRepo.ets（域 API + 变更信号 + 单例门面）

**Files:**
- Create: `entry/src/main/ets/store/AppConfigStore.ets`
- Create: `entry/src/main/ets/store/StoreRepo.ets`
- Modify: `entry/src/main/ets/common/IpcEvents.ets`（无改动，仅消费）

**Interfaces:**
- Consumes: Task 2 Models、Task 3 StorePaths/JsonFileStore、Task 1 IpcEvents。
- Produces: `AppConfigStore` 全部域方法（签名见步骤代码——21 方法逐条直译）；信号订阅 `onConfigChanged(cb)/onPlanetsChanged(cb)`（返回退订函数）；`StoreRepo.init(context)/store`。Task 10（VpnExt 读配置）、Task 11、A5 UI 消费。

**直译源对照**：`AppConfigStore.kt`（290 行）21 个 public 方法逐条；bootstrap（planets.json 缺失且无 .corrupt → 写 [OFFICIAL]，prefs 不引导）；信号语义（writeNetworks/writeMoons/deleteNetwork/deleteMoon/deletePlanet → configChanges；writePlanetsLocked 全部路径 + notifyIdentityChanged → planetsChanges；writePrefs/selectPlanet/activatePlanet/resetAllNetworkActivation 静默）。跨进程增强（D5）：config 类写后追加 publish CONFIG_CHANGED 唤醒 VpnExt。

- [ ] **Step 1: 写 AppConfigStore.ets**

```typescript
// AppConfigStore.ets — 四份 JSON 域 API + 变更信号（直译 store/AppConfigStore.kt）
//
// 两路信号语义（订阅方 level-triggered 全量重读，不保证逐次送达）：
//   configChanged：networks/moons 写删、deletePlanet → 隧道热重配 + UI 刷新；
//     进程内 listener 之外追加 commonEvent CONFIG_CHANGED 唤醒 VpnExt 重读（D5）。
//   planetsChanged：行星表字段变更 + notifyIdentityChanged → 仅 UI 刷新，
//     不触发隧道；首启 bootstrap 直写文件不经信号（无杂散发射）。
//   writePrefs/selectPlanet/activatePlanet/resetAllNetworkActivation：完全静默，
//   热生效由调用方显式编排（TunnelController.restartIfRunning）。
import { commonEventManager } from '@kit.BasicServicesKit';
import { IpcEvents } from '../common/IpcEvents';
import { PlanetProfile, NetworkEntry, MoonEntry, AppPrefs } from './Models';
import { StorePaths } from './StorePaths';
import { JsonFileStore } from './JsonFileStore';

type ChangeCb = () => void;

export class AppConfigStore {
  readonly paths: StorePaths;
  private files: JsonFileStore = new JsonFileStore();
  private configListeners: Set<ChangeCb> = new Set();
  private planetsListeners: Set<ChangeCb> = new Set();
  private bootstrapped = false;

  constructor(paths: StorePaths) { this.paths = paths; }

  // ---- 信号 ----

  onConfigChanged(cb: ChangeCb): () => void {
    this.configListeners.add(cb);
    return () => this.configListeners.delete(cb);
  }

  onPlanetsChanged(cb: ChangeCb): () => void {
    this.planetsListeners.add(cb);
    return () => this.planetsListeners.delete(cb);
  }

  // ---- 域锁内复合读改写（Kotlin mutate { } 直译） ----

  async mutate<T>(block: () => Promise<T>): Promise<T> {
    return this.files.mutate(block);
  }

  // ---- planets ----

  async readPlanets(): Promise<PlanetProfile[]> {
    await this.bootstrap();
    const list = await this.readListFile(this.paths.planetsFile, PlanetProfile.fromJson);
    return list === null || list.length === 0 ? [PlanetProfile.OFFICIAL] : list;
  }

  async writePlanets(profiles: PlanetProfile[]): Promise<void> {
    await this.mutate(() => this.writePlanetsLocked(profiles));
  }

  /** official 永在最前；档案本体以既有条目为准（缺失才用固定 OFFICIAL 兜底） */
  private async writePlanetsLocked(profiles: PlanetProfile[]): Promise<void> {
    const existing = await this.readPlanets();
    const merged: PlanetProfile[] = [];
    const official = profiles.find(p => p.id === PlanetProfile.OFFICIAL_ID)
      ?? existing.find(p => p.id === PlanetProfile.OFFICIAL_ID)
      ?? PlanetProfile.OFFICIAL;
    merged.push(official);
    for (const p of profiles) {
      if (p.id !== PlanetProfile.OFFICIAL_ID) merged.push(p);
    }
    await this.writeListFile(this.paths.planetsFile, merged.map(p => p.toJson()));
    this.firePlanets();
  }

  /** 身份相关行星字段变更（非 suspend，对齐 notifyIdentityChanged） */
  notifyIdentityChanged(): void { this.firePlanets(); }

  // ---- 行星指针 ----

  async selectedPlanetId(): Promise<string> {
    const prefs = await this.readPrefs();
    const planets = await this.readPlanets();
    return planets.some(p => p.id === prefs.selectedPlanetId)
      ? prefs.selectedPlanetId : PlanetProfile.OFFICIAL_ID;
  }

  async activePlanetId(): Promise<string> {
    const prefs = await this.readPrefs();
    if (prefs.activePlanetId === null) return PlanetProfile.OFFICIAL_ID;
    const planets = await this.readPlanets();
    return planets.some(p => p.id === prefs.activePlanetId)
      ? prefs.activePlanetId as string : PlanetProfile.OFFICIAL_ID;
  }

  async hasActivatedPlanet(): Promise<boolean> {
    return (await this.readPrefs()).activePlanetId !== null;
  }

  /** id 不存在 no-op；只写 selected，不发任何信号 */
  async selectPlanet(id: string): Promise<void> {
    const planets = await this.readPlanets();
    if (!planets.some(p => p.id === id)) return;
    await this.writePrefs(p => { p.selectedPlanetId = id; return p; });
  }

  /** 返回 changed（写前比对）；不发 configChanges（重启编排归调用方） */
  async activatePlanet(id: string): Promise<boolean> {
    const planets = await this.readPlanets();
    if (!planets.some(p => p.id === id)) return false;
    const changed = await this.activePlanetId() !== id;
    await this.writePrefs(p => { p.activePlanetId = id; return p; });
    return changed;
  }

  async deletePlanet(profile: PlanetProfile): Promise<void> {
    if (profile.kind !== 'custom') return; // 直译：仅 custom 生效
    await this.mutate(async () => {
      const planets = (await this.readPlanets())
        .filter(p => p.id !== profile.id);
      const wasSelected = await this.selectedPlanetId() === profile.id;
      const wasActive = await this.activePlanetId() === profile.id;
      const networks = (await this.readNetworks(null))
        .filter(n => n.planetId !== profile.id);
      const moons = (await this.readMoons(null))
        .filter(m => m.planetId !== profile.id);
      await this.writeListFile(this.paths.planetsFile, planets.map(p => p.toJson()));
      await this.writeListFile(this.paths.networksFile, networks.map(n => n.toJson()));
      await this.writeListFile(this.paths.moonsFile, moons.map(m => m.toJson()));
      if (profile.fileName !== null) {
        await this.unlinkQuiet(`${this.paths.planetsDir}/${profile.fileName}`);
      }
      await this.rmdirR(this.paths.planetStateDir(profile.id));
      if (wasSelected) await this.writePrefsLocked(
        (p => { p.selectedPlanetId = PlanetProfile.OFFICIAL_ID; return p; })(new AppPrefsMerge(await this.readPrefs())));
      if (wasActive) await this.writePrefsLocked(
        (p => { p.activePlanetId = null; return p; })(new AppPrefsMerge(await this.readPrefs())));
    });
    this.fireConfig(); // 末尾统一通知（对齐 Kotlin：deletePlanet 是唯一发信号的复合操作）
  }

  // ---- networks ----

  async readNetworks(planetId: string | null = null): Promise<NetworkEntry[]> {
    const id = planetId ?? await this.selectedPlanetId();
    const list = await this.readListFile(this.paths.networksFile, NetworkEntry.fromJson);
    return (list ?? []).filter(n => n.planetId === id);
  }

  async readNetworksByPlanet(): Promise<Map<string, NetworkEntry[]>> {
    const all = await this.readListFile(this.paths.networksFile, NetworkEntry.fromJson) ?? [];
    const map = new Map<string, NetworkEntry[]>();
    for (const n of all) {
      if (n.planetId === null) continue;
      const arr = map.get(n.planetId) ?? [];
      arr.push(n);
      map.set(n.planetId, arr);
    }
    return map;
  }

  async readActiveNetworks(): Promise<NetworkEntry[]> {
    return this.readNetworks(await this.activePlanetId());
  }

  /** 整组替换：旧表中该行星条目全删 + 新表打 planetId 写回 */
  async writeNetworks(values: NetworkEntry[], planetId: string | null = null): Promise<void> {
    const id = planetId ?? await this.selectedPlanetId();
    await this.mutate(async () => {
      const old = await this.readListFile(this.paths.networksFile, NetworkEntry.fromJson) ?? [];
      const kept = old.filter(n => n.planetId !== id);
      for (const v of values) v.planetId = id;
      await this.writeListFile(this.paths.networksFile,
        [...kept, ...values].map(n => n.toJson()));
    });
    this.fireConfig();
  }

  async deleteNetwork(networkId: string, planetId: string | null = null): Promise<void> {
    const id = planetId ?? await this.selectedPlanetId();
    await this.mutate(async () => {
      const all = await this.readListFile(this.paths.networksFile, NetworkEntry.fromJson) ?? [];
      const kept = all.filter(n => !(n.planetId === id && n.networkId === networkId));
      await this.writeListFile(this.paths.networksFile, kept.map(n => n.toJson()));
    });
    this.fireConfig();
  }

  /** 若无任何 lastActivated=true 直接 return（不写盘）；全量置 false 写回；静默 */
  async resetAllNetworkActivation(): Promise<void> {
    await this.mutate(async () => {
      const all = await this.readListFile(this.paths.networksFile, NetworkEntry.fromJson) ?? [];
      if (!all.some(n => n.lastActivated)) return;
      for (const n of all) n.lastActivated = false;
      await this.writeListFile(this.paths.networksFile, all.map(n => n.toJson()));
    });
  }

  // ---- moons ----

  async readMoons(planetId: string | null = null): Promise<MoonEntry[]> {
    const id = planetId ?? await this.selectedPlanetId();
    const list = await this.readListFile(this.paths.moonsFile, MoonEntry.fromJson);
    return (list ?? []).filter(m => m.planetId === id);
  }

  async readAllMoons(): Promise<MoonEntry[]> {
    return await this.readListFile(this.paths.moonsFile, MoonEntry.fromJson) ?? [];
  }

  async readActiveMoons(): Promise<MoonEntry[]> {
    return this.readMoons(await this.activePlanetId());
  }

  async writeMoons(values: MoonEntry[], planetId: string | null = null): Promise<void> {
    const id = planetId ?? await this.selectedPlanetId();
    await this.mutate(async () => {
      const old = await this.readListFile(this.paths.moonsFile, MoonEntry.fromJson) ?? [];
      const kept = old.filter(m => m.planetId !== id);
      for (const v of values) v.planetId = id;
      await this.writeListFile(this.paths.moonsFile,
        [...kept, ...values].map(m => m.toJson()));
    });
    this.fireConfig();
  }

  async deleteMoon(worldId: number, planetId: string | null = null): Promise<void> {
    const id = planetId ?? await this.selectedPlanetId();
    await this.mutate(async () => {
      const all = await this.readListFile(this.paths.moonsFile, MoonEntry.fromJson) ?? [];
      const kept = all.filter(m => !(m.planetId === id && m.worldId === worldId));
      await this.writeListFile(this.paths.moonsFile, kept.map(m => m.toJson()));
    });
    this.fireConfig();
  }

  // ---- prefs ----

  async readPrefs(): Promise<AppPrefs> {
    const text = await this.files.read(this.paths.prefsFile);
    if (text === null) return new AppPrefs(); // 文件缺失 → 内存默认（不引导落盘）
    try {
      return AppPrefs.fromJson(JSON.parse(text) as Record<string, Object>);
    } catch (_e) {
      await this.files.quarantine(this.paths.prefsFile, 'parse');
      return new AppPrefs();
    }
  }

  /** 静默写（writePrefs 直译）：opMutex 内读改写 */
  async writePrefs(mutate: (p: AppPrefs) => AppPrefs): Promise<void> {
    await this.mutate(async () => {
      await this.writePrefsLocked(mutate(await this.readPrefs()));
    });
  }

  private async writePrefsLocked(prefs: AppPrefs): Promise<void> {
    await this.files.write(this.paths.prefsFile, JSON.stringify(prefs.toJson()));
  }

  async disableIpv6(): Promise<boolean> { return (await this.readPrefs()).disableIpv6; }
  async connectOnDemand(): Promise<boolean> { return (await this.readPrefs()).connectOnDemand; }

  // ---- 基础设施 ----

  private async readListFile<T>(file: string,
    fromJson: (o: Record<string, Object>) => T): Promise<T[] | null> {
    const text = await this.files.read(file);
    if (text === null) return null;
    try {
      const arr = JSON.parse(text) as Object[];
      return arr.map(it => fromJson(it as Record<string, Object>));
    } catch (_e) {
      await this.files.quarantine(file, 'parse');
      return null;
    }
  }

  private async writeListFile(file: string, items: Record<string, Object>[]): Promise<void> {
    await this.files.write(file, JSON.stringify(items));
  }

  /** 首启 bootstrap：planets.json 不存在且无 .corrupt → 写 [OFFICIAL]；不防火信号 */
  private async bootstrap(): Promise<void> {
    if (this.bootstrapped) return;
    this.bootstrapped = true; // 先置位防重入（bootstrap 内无信号发射）
    const text = await this.files.read(this.paths.planetsFile);
    if (text !== null) return;
    try {
      const stat = await fs_stat(`${this.paths.planetsFile}.corrupt`);
      if (stat !== null) return; // .corrupt 存在 = 不自动重建
    } catch (_e) { /* 不存在即继续 */ }
    await this.writeListFile(this.paths.planetsFile, [PlanetProfile.OFFICIAL.toJson()]);
  }

  private fireConfig(): void {
    this.configListeners.forEach(cb => cb());
    this.publishQuiet(IpcEvents.CONFIG_CHANGED); // D5：唤醒 VpnExt 全量重读
  }

  private firePlanets(): void {
    this.planetsListeners.forEach(cb => cb());
  }

  /** commonEvent 发布失败静默（配置已落盘，VpnExt 重启后自会重读） */
  private publishQuiet(event: string): void {
    commonEventManager.publish(event, () => { /* 结果不敏感 */ });
  }

  private async unlinkQuiet(path: string): Promise<void> {
    try { await unlink_file(path); } catch (_e) { /* 已不存在 */ }
  }

  private async rmdirR(path: string): Promise<void> {
    try { await rmdir_recursive(path); } catch (_e) { /* 已不存在 */ }
  }
}
```

注意：`fs_stat`/`unlink_file`/`rmdir_recursive`/`AppPrefsMerge` 是示意名——实现时按下方「文件内私有 helper」补齐（`import fs from '@ohos.file.fs'` 后薄封装：`fs.stat` 判存在、`fs.unlink`、`fs.rmdir` 递归删除用 `fs.listFile` + 深度遍历；`AppPrefsMerge(src)` 即 `Object.assign(new AppPrefs(), src)` 拷贝构造）。deletePlanet 中两处 prefs 回写先 `readPrefs()` 再改字段再 `writePrefsLocked`，等价于 Kotlin `selectPlanetLocked/activatePlanetLocked`。

- [ ] **Step 2: 写 StoreRepo.ets**

```typescript
// StoreRepo.ets — store 层进程单例门面（直译 store/StoreRepo.kt）
//
// 幂等 double-checked（ArkTS 单线程，check 即足）；以首次 filesDir 为准。
// VpnExt 进程与主进程各自 init——两实例指向同一沙盒路径。
import { Context } from '@kit.AbilityKit';
import { AppConfigStore } from './AppConfigStore';
import { StorePaths } from './StorePaths';

export class StoreRepo {
  private static storeRef: AppConfigStore | null = null;

  static init(ctx: Context): void {
    if (StoreRepo.storeRef !== null) return;
    StoreRepo.storeRef = new AppConfigStore(
      StorePaths.of(ctx).filesRoot === '' ? StorePaths.of(ctx) : StorePaths.of(ctx));
  }

  static get store(): AppConfigStore {
    if (StoreRepo.storeRef === null) {
      throw new Error('StoreRepo 未初始化：须先调用 StoreRepo.init(context)');
    }
    return StoreRepo.storeRef;
  }
}
```

（`init` 内三元表达式冗余，实现时直接 `new AppConfigStore(StorePaths.of(ctx))`。）

- [ ] **Step 3: 编译验证 + Commit**

```bash
git add entry/src/main/ets/store/AppConfigStore.ets entry/src/main/ets/store/StoreRepo.ets
git commit -m "feat(store): 配置域 API 与进程单例门面

直译 AppConfigStore.kt 21 方法（bootstrap/整组替换/行星指针回退/静默写
prefs）与 StoreRepo.kt 单例；config 类写后追加 commonEvent 唤醒 VpnExt
重读（D5 level-triggered）。"
```

---

### Task 5: store/IdentityStore.ets（身份文件成对操作）

**Files:**
- Create: `entry/src/main/ets/store/IdentityStore.ets`

**Interfaces:**
- Consumes: Task 3 StorePaths。
- Produces: `IdentityStore.hasPlanetIdentity/planetIdentityAddress/sharedIdentityAddress/planetNodeIds/seedSharedIdentity/adoptSharedIdentity`（静态方法）；常量 `IDENTITY_PUBLIC = 'identity.public'`、`IDENTITY_SECRET = 'identity.secret'`。

**直译源对照**：`IdentityStore.kt`（95 行）逐方法。0600 收紧的平台差异记文件头（fs 无 chmod，沙盒隔离等价；C++ 侧 putFileAtomic(secure) 已覆盖核心自写路径）。**复制必须先于新核心启动**（核心只在构造时读/生成、退出不回写）。

- [ ] **Step 1: 写 IdentityStore.ets**

```typescript
// IdentityStore.ets — 节点身份文件操作（直译 store/IdentityStore.kt）
//
// 平台差异：@ohos.file.fs 无 chmod/open 权限位，Kotlin 对 identity.secret 的
// 0600 收紧在此退化为应用沙盒默认隔离（其他应用不可读）；核心自写路径的
// 0600 已由 C++ putFileAtomic(secure) 落实（A2）。
// 生命周期约束：核心只在 ZT_Node_new 时读/生成身份、退出不回写——
// seedSharedIdentity/adoptSharedIdentity 必须先于新核心启动执行。
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { StorePaths } from './StorePaths';
import { PlanetProfile } from './Models';

const TAG = 'IdentityStore';

export class IdentityStore {
  static readonly IDENTITY_PUBLIC: string = 'identity.public';
  static readonly IDENTITY_SECRET: string = 'identity.secret';

  static hasPlanetIdentity(paths: StorePaths, planetId: string): Promise<boolean> {
    return fs.access(`${paths.planetStateDir(planetId)}/${IdentityStore.IDENTITY_SECRET}`);
  }

  /** 读 planetStateDir/identity.public 的节点地址；缺失/损坏返回 null */
  static async planetIdentityAddress(paths: StorePaths, planetId: string): Promise<string | null> {
    return IdentityStore.addressOf(
      `${paths.planetStateDir(planetId)}/${IdentityStore.IDENTITY_PUBLIC}`);
  }

  static async sharedIdentityAddress(paths: StorePaths): Promise<string | null> {
    return IdentityStore.addressOf(`${paths.dataStoreRoot}/${IdentityStore.IDENTITY_PUBLIC}`);
  }

  /** perPlanet=false → 全行星同一共享地址；true → 各读各的，未生成的剔除 */
  static async planetNodeIds(paths: StorePaths, planets: PlanetProfile[],
    perPlanet: boolean): Promise<Map<string, string>> {
    const map = new Map<string, string>();
    if (!perPlanet) {
      const addr = await IdentityStore.sharedIdentityAddress(paths);
      if (addr === null) return map;
      for (const p of planets) map.set(p.id, addr);
      return map;
    }
    for (const p of planets) {
      const addr = await IdentityStore.planetIdentityAddress(paths, p.id);
      if (addr !== null) map.set(p.id, addr);
    }
    return map;
  }

  /** 共享 → 行星：已有独立身份或共享缺失时不动作 */
  static async seedSharedIdentity(paths: StorePaths, planetId: string): Promise<void> {
    const hasOwn = await IdentityStore.hasPlanetIdentity(paths, planetId);
    const sharedAddr = await IdentityStore.sharedIdentityAddress(paths);
    if (hasOwn || sharedAddr === null) return;
    await IdentityStore.copyIdentity(`${paths.dataStoreRoot}`,
      `${paths.planetStateDir(planetId)}`);
  }

  /** 行星 → 共享（覆盖） */
  static async adoptSharedIdentity(paths: StorePaths, planetId: string): Promise<void> {
    await IdentityStore.copyIdentity(`${paths.planetStateDir(planetId)}`,
      `${paths.dataStoreRoot}`);
  }

  /** readText → split(':')[0] → 长度 10 才是节点地址 */
  private static async addressOf(file: string): Promise<string | null> {
    try {
      const text = await fs.readText(file);
      const first = text.split(':')[0] ?? '';
      return first.length === 10 ? first : null;
    } catch (_e) {
      return null;
    }
  }

  /** 依次复制 PUBLIC/SECRET；src 缺失跳过；dst 存在先删；失败告警不抛（尽力而为） */
  private static async copyIdentity(fromDir: string, toDir: string): Promise<void> {
    for (const name of [IdentityStore.IDENTITY_PUBLIC, IdentityStore.IDENTITY_SECRET]) {
      const src = `${fromDir}/${name}`;
      const dst = `${toDir}/${name}`;
      try {
        await fs.access(src);
      } catch (_e) {
        continue; // src 不存在
      }
      try {
        await fs.mkdir(toDir); // 已存在抛错被吞
      } catch (_e) { /* 已存在 */ }
      try {
        try { await fs.unlink(dst); } catch (_e) { /* 不存在 */ }
        await fs.copyFile(src, dst);
      } catch (e) {
        hilog.warn(0x0000, TAG, `身份文件复制失败 ${name}: ${JSON.stringify(e)}`);
      }
    }
  }
}
```

- [ ] **Step 2: 编译验证 + Commit**

```bash
git add entry/src/main/ets/store/IdentityStore.ets
git commit -m "feat(store): 身份文件共享/每行星两模式操作

直译 IdentityStore.kt（addressOf 十位判定/seed/adopt 方向/成对复制尽力
而为）；0600 平台差异记文件头（沙盒隔离等价，核心自写路径 C++ 侧已覆盖）。"
```

---

### Task 6: native/theme/ColorMath（iOS 色彩数学直译 + host 金标单测 + NAPI 暴露）

**Files:**
- Create: `native/theme/ColorMath.h`
- Create: `native/theme/ColorMath.cpp`
- Test: `native/tests/test_colormath.cpp`
- Modify: `native/CMakeLists.txt`（pp_tests 与 planetport_core 源集各加 `theme/ColorMath.cpp`）
- Modify: `native/napi/planetport_napi.cpp`（暂不动——NAPI 绑定统一在 Task 9 落，本任务只确保源集编译）

**Interfaces:**
- Consumes: 无（纯数学）。
- Produces（Task 7 ArkTS 消费、经 Task 9 NAPI 暴露）：

```cpp
namespace pp {
struct Hsl { double h; double s; double l; };   // h: [0,360) s/l: [0,1]
Hsl hslOf(uint32_t hex);                        // hex 0xRRGGBB
uint32_t rgbOfHsl(const Hsl&);                  // 通道四舍五入量化（对齐 iOS channel round）
uint32_t accentLight(uint32_t mainHex);         // 原色
uint32_t accentDark(uint32_t mainHex);          // s+0.2 clamp 1、l+0.14 clamp 0.72
uint32_t successLight(uint32_t mainHex);        // 主色 +120° 三角；s≥0.6、l=0.32
uint32_t successDark(uint32_t mainHex);         // s≥0.5·0.8s、l=0.45
void planetTints(uint32_t mainHex, uint32_t out[8]); // ±120° 三色 × 500/200 档 + 两深色
inline constexpr uint32_t THEME_PRESETS[8] = {0xD44037u, 0xFFB61Eu, 0x789262u, 0x57C3C2u,
                                              0x4C8DAEu, 0x003472u, 0x4A4266u, 0x9D2933u};
}
```

**直译源对照**：iOS `PlanetPort/ThemeManager.swift:107-158`（HSL 结构/hsl/hslToRgb/通道量化）与 `:58-90`（accent/success/planetTints 派生规则）；presets 表 `:9-18` 逐值。`hslToRgb` 的 Swift `switch h` 区间（..<1..<5/default）直译为 if 链；`truncatingRemainder` 对正数取 `%` 语义一致（h+120 可达 480，需先 `% 360`——Swift 源即如此，注意 `(base.h + 120).truncatingRemainder(dividingBy: 360)`）。

- [ ] **Step 1: 写失败测试 test_colormath.cpp**

```cpp
// test_colormath.cpp — iOS ThemeManager 色彩数学金标向量（D13 host 单测）
//
// 金标值由 Swift 算法手工推演（HSL 手算保留 4 位小数），断言容差 1e-3（HSL
// 中间量）/ 1（RGB 量化通道差）。派生规则的「+120° 再 %360」语义重点覆盖。
#include "theme/ColorMath.h"
#include <gtest/gtest.h>
using namespace pp;

TEST(ColorMath, HslOfDefaultRed) {
  // 0xD44037: R=212 G=64 B=55 → hsl(3.4387°, 0.6462, 0.5235)（Swift 手算）
  Hsl h = hslOf(0xD44037u);
  EXPECT_NEAR(h.h, 3.4387, 1e-3);
  EXPECT_NEAR(h.s, 0.6462, 1e-3);
  EXPECT_NEAR(h.l, 0.5235, 1e-3);
}

TEST(ColorMath, HslOfGrayIsAchromromatic) {
  Hsl h = hslOf(0x808080u); // max==min → h=0 s=0
  EXPECT_DOUBLE_EQ(h.h, 0.0);
  EXPECT_DOUBLE_EQ(h.s, 0.0);
  EXPECT_NEAR(h.l, 128.0 / 255.0, 1e-12);
}

TEST(ColorMath, HslSectorGMax) {
  // 0x00FF00: max=g → h = ((b-r)/d + 2)*60 = 120
  EXPECT_NEAR(hslOf(0x00FF00u).h, 120.0, 1e-9);
  // 0x0000FF: max=b → h = ((r-g)/d + 4)*60 = 240
  EXPECT_NEAR(hslOf(0x0000FFu).h, 240.0, 1e-9);
  // 0xFF0000 且 g<b → h = ((g-b)/d + 6)*60 = 360（Swift 语义：g<b 补 6）
  EXPECT_NEAR(hslOf(0xFF0008u).h, 360.0 - 1.4118, 1e-3);
}

TEST(ColorMath, RgbRoundTripWithinQuantization) {
  for (uint32_t hex : THEME_PRESETS) {
    uint32_t back = rgbOfHsl(hslOf(hex));
    // 每通道量化误差 ≤1
    for (int shift : {16, 8, 0}) {
      int a = (hex >> shift) & 0xff, b = (back >> shift) & 0xff;
      EXPECT_LE(std::abs(a - b), 1);
    }
  }
}

TEST(ColorMath, AccentLightIsIdentity_DarkLifts) {
  EXPECT_EQ(accentLight(0xD44037u), 0xD44037u);
  // dark: s=min(1,.6462+.2)=.8462, l=min(.72,.5235+.14)=.6635 → 通道四舍五入
  uint32_t d = accentDark(0xD44037u);
  EXPECT_NE(d, 0xD44037u);
  // 花青 0x003472 s=1.0 → +0.2 clamp 1；l=0.2235+0.14=0.3635
  Hsl src = hslOf(0x003472u);
  EXPECT_NEAR(std::min(1.0, src.s + 0.2), 1.0, 1e-12);
}

TEST(ColorMath, SuccessHueRotates120) {
  // successLight: h=(3.4387+120)%360=123.4387, s=max(0.6,.6462)=.6462, l=.32
  uint32_t s = successLight(0xD44037u);
  Hsl back = hslOf(s);
  EXPECT_NEAR(back.h, 123.4387, 0.5); // hslOf 反解容差（量化扰动）
  EXPECT_NEAR(back.l, 0.32, 0.02);
  // hue ≥240 的主色：+120 → %360 回绕（0x003472 h≈240 → 0 而非 360）
  uint32_t s2 = successLight(0x003472u);
  Hsl back2 = hslOf(s2);
  EXPECT_LT(back2.h, 240.0);
}

TEST(ColorMath, PlanetTintsShape) {
  uint32_t out[8];
  planetTints(0xD44037u, out);
  Hsl base = hslOf(0xD44037u);
  // 前 3：h、h+120、h+240 各 s=.65 l=.52
  for (int i = 0; i < 3; i++) {
    Hsl c = hslOf(out[i]);
    EXPECT_NEAR(c.s, 0.65, 0.02);
    EXPECT_NEAR(c.l, 0.52, 0.02);
    double expectH = std::fmod(base.h + 120.0 * i, 360.0);
    EXPECT_NEAR(c.h < 1 && expectH > 359 ? 360.0 : c.h, expectH, 1.0);
  }
  // 4-6：同三 hue s=.55 l=.68；7-8：hue[1]/hue[2] s=.7 l=.32
  for (int i = 3; i < 6; i++) {
    Hsl c = hslOf(out[i]);
    EXPECT_NEAR(c.s, 0.55, 0.02);
    EXPECT_NEAR(c.l, 0.68, 0.02);
  }
  for (int i = 6; i < 8; i++) {
    Hsl c = hslOf(out[i]);
    EXPECT_NEAR(c.s, 0.7, 0.02);
    EXPECT_NEAR(c.l, 0.32, 0.02);
  }
}

TEST(ColorMath, PresetsVerbatim) {
  EXPECT_EQ(THEME_PRESETS[0], 0xD44037u);
  EXPECT_EQ(THEME_PRESETS[7], 0x9D2933u);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cmake -B native/build-host -S native -DCMAKE_BUILD_TYPE=Debug -DPP_BUILD_SMOKE=ON -DPP_BUILD_TESTS=ON && cmake --build native/build-host -j8 && ctest --test-dir native/build-host --output-on-failure`
Expected: 编译失败 `theme/ColorMath.h: No such file or directory`。

- [ ] **Step 3: 写 ColorMath.h/.cpp**

```cpp
// ColorMath.h — iOS ThemeManager 色彩数学直译（D13：host 金标单测覆盖）
//
// 直译源：PlanetPort/ThemeManager.swift（hsl:123-141 / hslToRgb:143-158 /
// accent:58-64 / success:66-74 / planetTints:76-90 / presets:9-18）。
// 只落纯数学（hex↔HSL↔派生 hex）；明暗双色由浅深两函数分别给出，
// ArkUI 动态明暗适配留 ArkTS 侧。
#pragma once
#include <cstdint>
namespace pp {

struct Hsl { double h; double s; double l; }; // h:[0,360] s/l:[0,1]

// 通道四舍五入量化（Swift channel(): (v*255).rounded() 夹 [0,255]）
uint32_t rgbOfHsl(const Hsl &hsl);
Hsl hslOf(uint32_t hex);

inline constexpr uint32_t THEME_PRESETS[8] = {
    0xD44037u, 0xFFB61Eu, 0x789262u, 0x57C3C2u,
    0x4C8DAEu, 0x003472u, 0x4A4266u, 0x9D2933u,
};

// accent：浅色原色；深色提亮度增饱和（s+0.2 clamp 1、l+0.14 clamp 0.72）
uint32_t accentLight(uint32_t mainHex);
uint32_t accentDark(uint32_t mainHex);
// success：主色 +120° 三角派生；浅 s=max(0.6,s) l=0.32；深 s=max(0.5,s*0.8) l=0.45
uint32_t successLight(uint32_t mainHex);
uint32_t successDark(uint32_t mainHex);
// 行星装饰盘 8 色：hue{h,h+120,h+240} × (s.65 l.52 / s.55 l.68) + hue[1]/hue[2] (s.7 l.32)
void planetTints(uint32_t mainHex, uint32_t out[8]);

} // namespace pp
```

```cpp
// ColorMath.cpp — 实现体（公式逐行对照 Swift 源）
#include "theme/ColorMath.h"
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace pp {

static uint32_t quant(double v) { // channel(): v*255 四舍五入夹 [0,255]
  long x = std::lround(v * 255.0);
  if (x < 0) x = 0;
  if (x > 255) x = 255;
  return uint32_t(x);
}

uint32_t rgbOfHsl(const Hsl &hsl) {
  double h = hsl.h / 60.0;
  double c = (1.0 - std::fabs(2.0 * hsl.l - 1.0)) * hsl.s;
  double x = c * (1.0 - std::fabs(std::fmod(h, 2.0) - 1.0));
  double m = hsl.l - c / 2.0;
  double r, g, b;
  if (h < 1) { r = c; g = x; b = 0; }
  else if (h < 2) { r = x; g = c; b = 0; }
  else if (h < 3) { r = 0; g = c; b = x; }
  else if (h < 4) { r = 0; g = x; b = c; }
  else if (h < 5) { r = x; g = 0; b = c; }
  else { r = c; g = 0; b = x; }
  return (quant(r + m) << 16) | (quant(g + m) << 8) | quant(b + m);
}

Hsl hslOf(uint32_t hex) {
  double r = ((hex >> 16) & 0xff) / 255.0;
  double g = ((hex >> 8) & 0xff) / 255.0;
  double b = (hex & 0xff) / 255.0;
  double maxC = std::max({r, g, b}), minC = std::min({r, g, b});
  double l = (maxC + minC) / 2.0;
  if (maxC == minC) return Hsl{0.0, 0.0, l};
  double d = maxC - minC;
  double s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC);
  double h;
  if (maxC == r) h = ((g - b) / d + (g < b ? 6.0 : 0.0)) * 60.0;
  else if (maxC == g) h = ((b - r) / d + 2.0) * 60.0;
  else h = ((r - g) / d + 4.0) * 60.0;
  return Hsl{h, s, l};
}

uint32_t accentLight(uint32_t mainHex) { return mainHex; }

uint32_t accentDark(uint32_t mainHex) {
  Hsl b = hslOf(mainHex);
  return rgbOfHsl(Hsl{b.h, std::min(1.0, b.s + 0.2), std::min(0.72, b.l + 0.14)});
}

static double huePlus(double base, double deg) { // truncatingRemainder(正数) == fmod
  return std::fmod(base + deg, 360.0);
}

uint32_t successLight(uint32_t mainHex) {
  Hsl b = hslOf(mainHex);
  return rgbOfHsl(Hsl{huePlus(b.h, 120.0), std::max(0.6, b.s), 0.32});
}

uint32_t successDark(uint32_t mainHex) {
  Hsl b = hslOf(mainHex);
  return rgbOfHsl(Hsl{huePlus(b.h, 120.0), std::max(0.5, b.s * 0.8), 0.45});
}

void planetTints(uint32_t mainHex, uint32_t out[8]) {
  Hsl base = hslOf(mainHex);
  double hues[3] = {base.h, huePlus(base.h, 120.0), huePlus(base.h, 240.0)};
  for (int i = 0; i < 3; i++) out[i] = rgbOfHsl(Hsl{hues[i], 0.65, 0.52});
  for (int i = 0; i < 3; i++) out[3 + i] = rgbOfHsl(Hsl{hues[i], 0.55, 0.68});
  out[6] = rgbOfHsl(Hsl{hues[1], 0.7, 0.32});
  out[7] = rgbOfHsl(Hsl{hues[2], 0.7, 0.32});
}

} // namespace pp
```

- [ ] **Step 4: CMake 接源 + 跑测试通过**

`native/CMakeLists.txt`：pp_tests 源集与 planetport_core 源集各追加 `theme/ColorMath.cpp`（参照 A2 集成样式的 dataplane 行）。

Run: 同 Step 2 命令。
Expected: 全部测试 PASS（含既有 117 项回归）。

- [ ] **Step 5: Commit**

```bash
git add native/theme/ native/tests/test_colormath.cpp native/CMakeLists.txt
git commit -m "feat(theme): iOS 主题色彩数学直译与金标单测

ThemeManager.swift HSL 换算/主色明暗/成功色三角派生/行星装饰盘 8 色/
预设色板逐值直译为纯函数；host 金标向量覆盖回绕与量化边界。"
```

---

### Task 7: store/ThemeManager.ets + LanguageManager.ets（ArkTS 薄层）

**Files:**
- Create: `entry/src/main/ets/store/ThemeManager.ets`
- Create: `entry/src/main/ets/store/LanguageManager.ets`

**Interfaces:**
- Consumes: Task 6 ColorMath（经 Task 9 NAPI——**本任务先落逻辑、NAPI 绑定由 Task 9 统一接**；编译期经 `CoreRuntime` 命名空间扩展的消费点可后置到 Task 9 提交）、Task 4 StoreRepo、Task 2 Models。
- Produces: `ThemeManager.refresh()/mainHex/effectiveMainHex/deriveStatusColor/accentLightHex()/accentDarkHex()/successLightHex()/successDarkHex()/planetTintsHex()/presets`；`LanguageManager.current()/set()/loc(key)` + `AppLanguage` 枚举。A5 UI 消费。

**直译源对照**：iOS ThemeManager 状态面（@Published mainHex/deriveStatusColor ↔ 鸿蒙 AppPrefs.themeColorCustom??themeColor/successDerived，SharedPreferences 换 AppPrefs）；iOS LanguageManager 全量（枚举值域/nativeName/loc 查表；locale 覆盖机制换内嵌三语表——getStringSync 不支持指定 locale，Global Constraints 已记）。

- [ ] **Step 1: 写 ThemeManager.ets**

```typescript
// ThemeManager.ets — 全局主题状态（iOS ThemeManager 状态面 + Task 6 色彩数学）
//
// 持久化源：AppPrefs（themeColorCustom 非 null 优先于 themeColor；默认
// 0xD44037）。派生计算经 NAPI ColorMath（Task 9 接线前 getDerived* 返回
// 预设兜底值，接线后即真值——派生函数集中在一个文件便于切换）。
import { StoreRepo } from './StoreRepo';
import { ColorMath } from '../common/CoreRuntime';

export class ThemeManager {
  private static instance: ThemeManager | null = null;

  static readonly PRESETS: number[] = [
    0xD44037, 0xFFB61E, 0x789262, 0x57C3C2,
    0x4C8DAE, 0x003472, 0x4A4266, 0x9D2933,
  ];

  private constructor(private main: number, private derive: boolean) {}

  static async shared(): Promise<ThemeManager> {
    if (ThemeManager.instance === null) {
      const prefs = await StoreRepo.store.readPrefs();
      const main = prefs.themeColorCustom ?? prefs.themeColor ?? 0xD44037;
      ThemeManager.instance = new ThemeManager(main, prefs.successDerived);
    }
    return ThemeManager.instance;
  }

  get mainHex(): number { return this.main; }
  /** 自定义色优先（AppPrefs.themeColorCustom 语义） */
  get effectiveMainHex(): number { return this.main; }
  get deriveStatusColor(): boolean { return this.derive; }

  async setMainColor(hex: number, custom: boolean): Promise<void> {
    this.main = hex;
    await StoreRepo.store.writePrefs(p => {
      if (custom) { p.themeColorCustom = hex; } else { p.themeColor = hex; p.themeColorCustom = null; }
      return p;
    });
  }

  async setDeriveStatusColor(on: boolean): Promise<void> {
    this.derive = on;
    await StoreRepo.store.writePrefs(p => { p.successDerived = on; return p; });
  }

  // ---- 派生（NAPI ColorMath；Task 9 接线） ----
  accentLightHex(): number { return ColorMath.accentLight(this.main); }
  accentDarkHex(): number { return ColorMath.accentDark(this.main); }
  successLightHex(): number { return this.derive ? ColorMath.successLight(this.main) : 0x34A853; }
  successDarkHex(): number { return this.derive ? ColorMath.successDark(this.main) : 0x34A853; }
  planetTintsHex(): number[] { return ColorMath.planetTints(this.main); }
}
```

（`successLightHex` 兜底 `0x34A853` 为占位资产色——A5 UI 落 SuccessGreen 资产后以资源色值为准，此处给出确定值防未定义。）

- [ ] **Step 2: 写 LanguageManager.ets**

```typescript
// LanguageManager.ets — 应用语言（iOS LanguageManager 直译；查表机制换内嵌表）
//
// iOS 以 .environment(\.locale) 覆盖 SwiftUI 文案；鸿蒙 getStringSync 不支持
// 指定 locale（Global Constraints），应用内切换走 loc(key) 内嵌三语表。
// 表内容 A5 全量填充；本任务落机制 + 种子键。nativeName 以自身语言显示
// （不随界面语言变化），对齐 iOS nativeName。
import { StoreRepo } from './StoreRepo';

export enum AppLanguage {
  System = 'system',
  ZhHans = 'zh-Hans',
  ZhHant = 'zh-Hant',
  En = 'en',
}

/** 各语言选项以自身名称显示；null = 走「跟随系统」文案键 */
export function nativeName(l: AppLanguage): string | null {
  switch (l) {
    case AppLanguage.System: return null;
    case AppLanguage.ZhHans: return '简体中文';
    case AppLanguage.ZhHant: return '繁體中文';
    case AppLanguage.En: return 'English';
  }
}

// 种子键（机制验证用；A5 全量扩表）
const TABLE_ZH_HANS: Record<string, string> = {
  'app.name': 'Planet Port',
  'lang.followSystem': '跟随系统',
};
const TABLE_ZH_HANT: Record<string, string> = {
  'app.name': 'Planet Port',
  'lang.followSystem': '跟隨系統',
};
const TABLE_EN: Record<string, string> = {
  'app.name': 'Planet Port',
  'lang.followSystem': 'Follow system',
};

export class LanguageManager {
  private static currentLang: AppLanguage = AppLanguage.System;

  /** 启动时调一次（读 AppPrefs.language） */
  static async init(): Promise<void> {
    const prefs = await StoreRepo.store.readPrefs();
    const v = prefs.language;
    LanguageManager.currentLang = v === 'zh-Hans' || v === 'zh-Hant' || v === 'en'
      ? v as AppLanguage : AppLanguage.System;
  }

  static current(): AppLanguage { return LanguageManager.currentLang; }

  static async set(l: AppLanguage): Promise<void> {
    LanguageManager.currentLang = l;
    await StoreRepo.store.writePrefs(p => { p.language = l as string; return p; });
  }

  /** 按当前应用语言查表（未指定时回退系统语言）；缺键回退 zh-Hans 再回退 key */
  static loc(key: string): string {
    const sys = LanguageManager.systemLanguage();
    const lang = LanguageManager.currentLang === AppLanguage.System
      ? sys : LanguageManager.currentLang;
    const table = LanguageManager.tableFor(lang);
    return table[key] ?? TABLE_ZH_HANS[key] ?? key;
  }

  private static tableFor(l: AppLanguage): Record<string, string> {
    switch (l) {
      case AppLanguage.ZhHant: return TABLE_ZH_HANT;
      case AppLanguage.En: return TABLE_EN;
      default: return TABLE_ZH_HANS;
    }
  }

  /** 系统语言推断（zh-Hant/zh-HK/zh-TW → 繁体；zh* → 简体；其余 → en） */
  private static systemLanguage(): AppLanguage {
    const tag = LanguageManager.systemTag();
    if (tag.startsWith('zh')) {
      return /Hant|HK|TW|MO/.test(tag) ? AppLanguage.ZhHant : AppLanguage.ZhHans;
    }
    return AppLanguage.En;
  }

  private static systemTag(): string {
    // @ohos.i18n System.getAppPreferredLanguage（同步、无权限）；
    // 取值形如 "zh-Hans-CN"。包一层便于单测替换。
    return I18nTags.preferred();
  }
}

/** 系统语言标签取值隔离点（ArkTS 无法注入，集中一处便于 A5 换资源方案） */
export class I18nTags {
  static preferred(): string {
    return systemPreferredLanguage(); // 见下方 import 说明
  }
}
```

实现说明：`systemPreferredLanguage` 来自 `import { i18n } from '@kit.LocalizationKit'` 后 `i18n.System.getAppPreferredLanguage()`——文件头补 import 并把 `I18nTags.preferred` 直接实现为 `return i18n.System.getAppPreferredLanguage()`（保留隔离点壳，A5 可整体替换）。ArkTS `switch` 枚举穷尽后无 default 返回路径问题：`tableFor` 的 default 分支保留。

- [ ] **Step 3: 编译验证 + Commit**

```bash
git add entry/src/main/ets/store/ThemeManager.ets entry/src/main/ets/store/LanguageManager.ets
git commit -m "feat(store): 主题与语言管理器

iOS ThemeManager 状态面（AppPrefs 持久化、自定义色优先、派生经 NAPI
ColorMath）与 LanguageManager 枚举值域直译；查表机制换内嵌三语表
（getStringSync 不支持指定 locale 的平台约束）。"
```

（注：`import { ColorMath } from '../common/CoreRuntime'` 在 Task 9 落地前不存在——**本任务提交时该 import 以注释形式存在**，Task 9 解注释并接线；两任务的提交说明互相引用。编译验证以注释态通过为准。）

---

### Task 8: native/runtime/TunnelRuntime（TunnelManager+NodeRuntime 编排直译 + host 单测）

**Files:**
- Create: `native/runtime/TunnelRuntime.h`
- Create: `native/runtime/TunnelRuntime.cpp`
- Test: `native/tests/test_tunnelruntime.cpp`
- Modify: `native/CMakeLists.txt`（两源集各加 `runtime/TunnelRuntime.cpp`）

**Interfaces:**
- Consumes: A2 全部件——`CoreBridge`（构造/join/leave/orbit/processWirePacket/processVirtualNetworkFrame/networkConf/peersNow/address/putFileAtomic/stateFilePathFor）、`Dataplane.swap(fd)/teardownTun()/writePackets()`、`FrameConverter`（A2 已完成 tun→core 转换 + onFrame 回调契约）、`UdpCom.start(protect, onPacket)/shutdown()/send()`、`NetworkContextMath::detectConflicts`。
- Produces（Task 9 NAPI 直接包装、Task 10 壳消费）:

```cpp
namespace pp {

// 启动配置（ArkTS 从 store 读出后经 JSON 传入；字段名 = NAPI JSON 契约）
struct TunnelConfig {
    std::string dataStoreRoot;     // filesDir/zt
    std::string planetDir;         // planetStateDir(activePlanetId)（含 planet 文件根语义）
    std::string planetFile;        // planets/<uuid>.planet 全路径；空 = 官方
    bool identityPerPlanet = false;
    bool disableIpv6 = false;
    struct Net { uint64_t nwid; bool routeViaZeroTier; };  // 激活网络（按激活序）
    std::vector<Net> networks;
    struct Moon { uint64_t worldId; uint64_t seed; };
    std::vector<Moon> moons;
};

// 聚合结果 → 壳组装 VpnConfig（D8：v4/v6 聚合单 VpnConfig、MTU clamp 1500）
struct EstablishRequest {
    std::vector<std::string> v4Addrs;   // "ip/prefix"
    std::vector<std::string> v6Addrs;
    std::vector<std::string> routes4;   // "dest/prefix [via gw]"（LPM 聚合后）
    std::vector<std::string> routes6;
    std::vector<std::string> dns;       // DnsMode=custom 的并集
    int mtu = 28000;                    // 网络声明值取最小（调用方 clamp [576,1500]）
};

// 状态快照（snapshotJson 的内存形态；JSON 序列化在 .cpp）
struct RuntimeState {
    // kind: idle|starting|running|reconnecting|stopped|failed（对齐 TunnelContract）
    std::string kind = "idle";
    std::string reason;         // reconnecting: network_change；failed: 错误码
    bool recoverable = false;   // failed 专用
    bool online = false;
    std::string nodeId;         // 10 位 hex；空 = 未上线
    std::string coreVersion;
    std::map<uint64_t, int> networkStatuses;   // nwid → ZT status 原始码
    std::map<uint64_t, std::string> networkConflicts; // nwid → "address"|"subnet"
    std::map<uint64_t, NetConf> networkConfigs;
    std::vector<PeerInfo> peers;
    std::string applyTrace;
    std::vector<std::string> eventLog;         // 滚动 40 条（带时间戳，TunnelStateBus.log 同源）
};

class TunnelRuntime {
public:
    // 回调全部在 runtime 内部线程或 ZT 核心线程触发——实现只做投递，禁止阻塞
    struct Hooks {
        // 聚合就绪需要建/换 TUN（D3）：壳组 VpnConfig → create() → swapFd(fd)。
        // 第一次 = establish；后续 = 换代（旧 fd 由 runtime close）
        std::function<void(const EstablishRequest &)> onEstablish;
        // 全部网络失效：壳 destroy VPN（路由自动撤销），runtime 实例保持可用
        std::function<void()> onTeardown;
        // 状态/快照已变化（壳择机调 snapshotJson 落盘 + 发 commonEvent）
        std::function<void()> onStateChanged;
        // 物理发包出口（UdpCom 直接桥接）
        std::function<int(const uint8_t *, size_t, const WireEndpoint &)> sendPacket;
        // protect 钩子（UdpCom start 注入；D4/D14——NAPI tsfn 回调 ArkTS）
        std::function<bool(int fd)> protect;
    };

    Hooks hooks;

    bool start(const TunnelConfig &cfg);  // 幂等：已启动返回 false
    void stop();                          // 幂等；置 Stopped 终态
    void restartCore();                   // D3：进程内换代（stop+start 保配置）
    bool swapFd(int fd);                  // establish 回应（Dataplane.swap 语义）
    void applyConfig(const TunnelConfig &cfg); // 热重配：join/leave/orbit 增量 + appliedEntries 比对
    void setPathSatisfied(bool ok);       // 壳 NetWatch 透出（写快照）
    std::string snapshotJson() const;     // Task 1 TunnelSnapshot 契约的 C++ 侧序列化
    const RuntimeState &state() const { return m_state; }
    bool isAlive() const;                 // running|starting|reconnecting
};
```

**直译源对照与关键顺序约束**（host 单测逐条锁死）：
- `TunnelManager.start` 顺序：CoreBridge 构造（**先** seed 身份——ArkTS 壳在 start 前调 IdentityStore）→ hooks 装配 → `core.start()` → UdpCom.start（protect 注入）→ 期望首份 netconf（Starting 态）；**UdpCom bind 失败 → Failed(udpBindFailed, recoverable=true)**。
- `applyConfig` 增量：diff appliedEntries（join 新增 / leave 移除 / orbit 新增 moon / deorbit 移除）；全量失效 → teardownTun + 置 Stopped 语义（不置 Failed）。
- onNetConf 聚合：UP/CONFIG_UPDATE 更新快照 → 全网络重聚合（`NetworkContextMath::detectConflicts` 排除冲突网）→ v4/v6 地址并集 + LPM 路由聚合 → 与上次聚合签名比对（**幂等闸门**，字符串签名直译 appliedSignature）→ 变化才发 onEstablish。
- establish 回应：swapFd 成功 → Running；失败 → 保持 Starting 等下次 netconf（不 Failed——Android 语义）。
- 错误路径 7 种映射：coreInit 失败 / identityCollision（**不可恢复**）/ core_driver:rc / udpBindFailed / tunEstablish 超时（awaitSettled 15s 语义归壳）/ 网络全失效（teardown 非 Failed）/ 正常 stop。
- 事件日志：`log(line)` 时间戳 `HH:mm:ss.SSS` + takeLast(40)。
- MTU：`mtu = min(28000, 各网络声明值)`，**壳层 clamp [576,1500]**（VpnConfig 硬性范围）。

- [ ] **Step 1: 写失败测试 test_tunnelruntime.cpp**

用 `socketpair(AF_UNIX, SOCK_STREAM)` 模拟 TUN fd；Hooks 捕获 onEstablish/onStateChanged；直接喂 netconf（经 CoreBridge 无法在 host 伪造 netconf——TunnelRuntime 暴露 `testFeedNetConf(nwid, NetConf)` 仅供测试编译守卫 `#ifdef PP_TUNNELRUNTIME_TEST_HOOKS`）。测试用例（完整代码，节选骨架——**实现者按此 8 例全量落地**）：

```cpp
// 1. start 装配顺序：core→udp→Starting；protect 注入 UdpCom（fake protect 记录 fd）
TEST(TunnelRuntime, StartSequence_Starting);
// 2. 首份 netconf → 聚合 → onEstablish（v4Addrs 非空、幂等签名：同 netconf 二次投递不再发）
TEST(TunnelRuntime, FirstNetConf_EstablishOnce);
// 3. swapFd(-1 拒绝) → 保持 Starting；swapFd(fd) → Running
TEST(TunnelRuntime, SwapFd_Gating);
// 4. applyConfig 增量：加网络 → join 调用；删网络 → leave；moon 增删 → orbit/deorbit
TEST(TunnelRuntime, ApplyConfig_Incremental);
// 5. 冲突网络排除：两网络同地址段 → 后者入 conflicts 表、不进聚合
TEST(TunnelRuntime, Conflicts_Excluded);
// 6. 全部网络失效 → onTeardown + 不置 Failed；恢复 → 重新 establish
TEST(TunnelRuntime, AllNetworksDown_TeardownNotFailed);
// 7. UdpCom bind 失败注入（端口冲突）→ Failed(udpBindFailed, recoverable)
TEST(TunnelRuntime, UdpBindFailed_Reason);
// 8. snapshotJson 字段完整性：JSON parse 后逐字段断言（TunnelContract 契约）
TEST(TunnelRuntime, SnapshotJsonContract);
```

Run: host cmake 构建。
Expected: 编译失败（TunnelRuntime.h 不存在）。

- [ ] **Step 2: 实现 TunnelRuntime.h/.cpp**

实现要点（实现者对照 `TunnelManager.kt` 逐函数直译，**完整实现 ~700 行**）：
- 成员：`std::unique_ptr<CoreBridge> m_core`、`std::unique_ptr<UdpCom> m_udp`、`Dataplane m_dp`、`FrameConverter m_fc`（A2 构造参数按其头文件）、`std::map<uint64_t, NetworkContext> m_nets`、`TunnelConfig m_cfg`、`std::string m_appliedSignature`、`RuntimeState m_state`、`std::mutex m_lock`（快照读写 vs 核心线程回调）。
- `log()`：`TimeUtil::nowHmsMs()`（chrono 实现，直译 SimpleDateFormat("HH:mm:ss.SSS")）+ 40 条滚动。
- `snapshotJson()`：手写 JSON builder（`{\"kind\":\"running\",...}`，键名对齐 Task 1 `TunnelSnapshot`——networkConfigs 为数组、networkStatuses/networkConflicts 键为 16 位小写 hex、peers 数组含 address/version/latency/role/paths——**paths 字段 A2 PeerInfo 没有物理路径列表**：CoreBridge::PeerInfo 无 paths，快照 peers.paths 恒 `[]`（relay 判定 A2 已有 role/latency 语义，物理路径表 A6 真机评估后决定是否扩 CoreBridge——挂账，不臆测）。
- `swapFd`：`m_dp.swap(fd)` 返回 false（已停机）→ 返回 false 且**不关 fd**（调用方持有）——对齐 A2 Dataplane 注释语义。
- 析构：`stop()` 兜底。

- [ ] **Step 3: CMake 接源 + 全测通过**

Run: host 构建 + ctest。
Expected: 新增 8+ 用例全 PASS，既有 125 项（117 + ColorMath 8）回归 PASS。

- [ ] **Step 4: 交叉编译验证**

Run: OHOS arm64 交叉构建（Global Constraints 命令）。
Expected: planetport_core.so 编入 TunnelRuntime 符号（`strings native/build-ohos/libplanetport_core.so | grep -c snapshotJson` ≥ 1）。

- [ ] **Step 5: Commit**

```bash
git add native/runtime/ native/tests/test_tunnelruntime.cpp native/CMakeLists.txt
git commit -m "feat(runtime): 隧道编排状态机直译

TunnelManager+NodeRuntime 编排收敿为 C++ TunnelRuntime：establish 幂等
签名闸门、applyConfig 增量热重配、冲突网络排除、换代 swapFd、错误路径
七种映射、快照 JSON 契约序列化。host 单测以 socketpair 模拟 TUN 锁死
装配顺序与状态迁移。"
```

---

### Task 9: napi/planetport_napi.cpp（三函数族 + ColorMath 绑定 + protect tsfn）

**Files:**
- Modify: `native/napi/planetport_napi.cpp`
- Modify: `entry/src/main/ets/common/CoreRuntime.ets`（Task 7 的 ColorMath import 解注释）

**Interfaces:**
- Consumes: Task 6 ColorMath、Task 8 TunnelRuntime。
- Produces（ArkTS 侧 `libplanetport_core.so` 导出）：

```typescript
// entry/src/main/ets/common/CoreRuntime.ets 最终形态
export namespace CoreRuntime {
  export function getCoreVersion(): string;
}
export namespace ColorMath {
  export function accentLight(mainHex: number): number;
  export function accentDark(mainHex: number): number;
  export function successLight(mainHex: number): number;
  export function successDark(mainHex: number): number;
  export function planetTints(mainHex: number): number[]; // 8 元素
  export function hslOf(mainHex: number): [number, number, number]; // [h, s, l]
}
export namespace TunnelNapi {
  export function start(configJson: string): boolean;      // 重复启动 false
  export function stop(): void;                             // 幂等
  export function restartCore(): void;
  export function swapFd(fd: number): boolean;
  export function applyConfig(configJson: string): void;    // 热重配
  export function setPathSatisfied(ok: boolean): void;
  export function snapshot(): string;                       // TunnelSnapshot JSON
  // 回调注册（VpnExt 壳一次性注册；runtime 持 tsfn 引用）
  export function setCallbacks(cbs: TunnelCallbacks): void;
}
export interface TunnelCallbacks {
  onEstablish(req: EstablishRequest): void; // 壳组 VpnConfig→create→swapFd
  onTeardown(): void;                       // 壳 destroy VPN
  onStateChanged(): void;                   // 壳拉 snapshot 落盘+发事件
}
export interface EstablishRequest {
  v4Addrs: string[]; v6Addrs: string[];
  routes4: string[]; routes6: string[]; dns: string[]; mtu: number;
}
```

- [ ] **Step 1: 实现 NAPI 绑定**

实现要点（`planetport_napi.cpp` 重写为 ~400 行，**D14 隔离面**）：
- **进程级单例** `static std::unique_ptr<pp::TunnelRuntime> g_runtime`（VpnExt 进程唯一实例；主进程不调用 TunnelNapi 族）。
- `start(configJson)`：手写极简 JSON 解析（复用/内联 `TunnelConfig` 字段提取——不引第三方库，字段名即契约：dataStoreRoot/planetDir/planetFile/identityPerPlanet/disableIpv6/networks[{nwid,routeViaZeroTier}]/moons[{worldId,seed}]；nwid 解析 16 位 hex → uint64）。
- `setCallbacks`：三个回调各建一个 `napi_threadsafe_function`（`napi_create_threadsafe_function`，max_queue_size 无界/默认）；runtime Hooks 内 `napi_call_threadsafe_function` 投递（非阻塞、丢队列满即丢——onStateChanged level-triggered 语义允许）。onEstablish 的 `EstablishRequest` 打包为 JSON 字符串投递（跨线程传对象一律字符串化）。
- **protect 路径（D14 重点）**：`TunnelRuntime::Hooks::protect` = lambda 捕获 protect tsfn——C++ 侧 `UdpCom::start` 在 bind 后调 `protect(fd)`：lambda 把 fd 经 tsfn 投递 ArkTS 并**同步等待**（`std::promise<bool>` + future，超时 2s 默认 true 放行——保护失败宁通勿断与 Android 兜底一致）。ArkTS 侧 `TunnelNapi` 增补 `protectFd(fd: number, token: number): void`——壳注册的 protect 处理器（调 `vpnConnection.protect(fd)`）完成后回调 `protectResult(token, ok)`；NAPI 收到后 set_value。**壳内默认不注册 protect 处理器 → 恒走 2s 超时放行 + 进程级 protectProcessNet 一次调用**（Global Constraints UNVERIFIED-1 的最稳假设）。
- `swapFd(fd)`：`napi_get_value_int32` → `g_runtime->swapFd(fd)`。
- `snapshot()`：`napi_create_string_utf8(g_runtime->snapshotJson())`。
- ColorMath 族：`napi_get_value_uint32`/`napi_create_uint32`；`planetTints` 返回 `napi_create_array` 8 元素；`hslOf` 返回 3 元素 double 数组。
- `smokeIdentityGen` 保留（host 冒烟）。

- [ ] **Step 2: 更新 CoreRuntime.ets 并解注释 Task 7 import**

按上方 Produces 块的最终形态重写 `entry/src/main/ets/common/CoreRuntime.ets`（声明式 import `libplanetport_core.so`，类型标注齐全）；`ThemeManager.ets` 的 `import { ColorMath } from '../common/CoreRuntime'` 解注释。

- [ ] **Step 3: 双链路构建验证**

Run: host ctest（回归全绿）+ OHOS 交叉 + `strings` 验符号 + `assembleHap`。
Expected: 四项全过；HAP 内 .so 体积增长（TunnelRuntime+ColorMath 编入）。

- [ ] **Step 4: Commit**

```bash
git add native/napi/planetport_napi.cpp entry/src/main/ets/common/CoreRuntime.ets entry/src/main/ets/store/ThemeManager.ets
git commit -m "feat(napi): 隧道函数族与色彩数学 NAPI 绑定

TunnelNapi 族（start/stop/restartCore/swapFd/applyConfig/snapshot/
setCallbacks）+ ColorMath 族落地；回调经 threadsafe function 投递，
protect 路径 token 化同步等待（超时放行），壳默认走 protectProcessNet
（Spike S3 前的最稳假设，D14 隔离面内）。"
```

---

### Task 10: vpnext/ 扩展进程四件套（壳 + ExtRuntime + ExtStateBus + ExtNetWatch）

**Files:**
- Create: `entry/src/main/ets/vpnext/ZeroTierVpnExtAbility.ets`
- Create: `entry/src/main/ets/vpnext/ExtRuntime.ets`
- Create: `entry/src/main/ets/vpnext/ExtStateBus.ets`
- Create: `entry/src/main/ets/vpnext/ExtNetWatch.ets`
- Modify: `entry/src/main/ets/common/IpcEvents.ets`（如需增 code 常量）

**Interfaces:**
- Consumes: Task 1 IpcEvents/TunnelContract、Task 4 StoreRepo、Task 5 IdentityStore、Task 9 TunnelNapi。
- Produces: 扩展进程行为（无对外 TS 接口；`ZeroTierVpnExtAbility` 默认导出类名即 module.json5 `srcEntry` 目标）。

**直译源对照**：`ZeroTierVpnService.startTunnel/stopTunnel` 顺序（4 处 native UAF 防护：先停消费线程再 delete 核心——鸿蒙侧由 C++ runtime 析构序内化，壳只管 VPN 连接与 NAPI 生命周期）；NetWatch 防抖 1.5s/代际（D9：切网自愈在扩展进程内闭环 = destroy VPN → restartCore → 重建 establish，不跨进程）；快照写方 = TunnelStateBus 直译的进程内镜像 + snapshotJson 合流。**本任务整体在 D14 隔离面内。**

- [ ] **Step 1: 写 ZeroTierVpnExtAbility.ets**

```typescript
// ZeroTierVpnExtAbility.ets — VPN 扩展壳（D14 隔离面；直译 ZeroTierVpnService
// 生命周期语义 + VpnService.Builder 用法映射 VpnConfig）
//
// 与 Android 的结构差异（有意）：
//   ① 授权：鸿蒙无 prepare()——首次 create() 由系统弹窗（失败码 2203001）。
//   ② establish 换代：D3 进程内 destroy+create+swapFd，核心不随 TUN 换代重启。
//   ③ 切网自愈（D9）：进程内闭环（ExtNetWatch → restartCore），不重启扩展进程。
//   ④ 通知：VpnExt 无常驻通知义务（Android FGS 义务不适用）——系统 VPN 状态
//      图标由系统呈现；应用内状态走快照。
import { VpnExtensionAbility, Want } from '@kit.NetworkKit';
import { ExtRuntime } from './ExtRuntime';
import { ExtStateBus } from './ExtStateBus';
import { ExtNetWatch } from './ExtNetWatch';
import { StoreRepo } from '../store/StoreRepo';
import { commonEventManager } from '@kit.BasicServicesKit';
import { IpcEvents } from '../common/IpcEvents';
import { Context } from '@kit.AbilityKit';

export default class ZeroTierVpnExtAbility extends VpnExtensionAbility {
  private runtime: ExtRuntime | null = null;
  private stateBus: ExtStateBus | null = null;
  private netWatch: ExtNetWatch | null = null;
  private cmdSub: commonEventManager.CommonEventSubscriber | null = null;

  onCreate(want: Want): void {
    const ctx = this.context;
    StoreRepo.init(ctx);
    this.stateBus = new ExtStateBus(ctx);
    this.runtime = new ExtRuntime(ctx, this.stateBus);
    this.netWatch = new ExtNetWatch(() => {
      // 切网自愈（D9）：进程内换代重启（核心重置 NAT 映射缓存须重建）
      void this.runtime?.reconnectCore();
    });
    this.subscribeCommands(ctx);
    // 隧道启动：onCreate 即拉起（startVpnExtensionAbility 语义 = 用户已在
    // 主进程过授权/显式启动；无 cmd 的冷启动（系统回收后拉起）同样恢复）
    void this.startTunnel();
  }

  onDestroy(): void {
    // 优雅终态化（UNVERIFIED-4 双保险之一：CMD_STOP 路径已先行终态化，此处兜底）
    void this.stopTunnel();
    this.netWatch?.shutdown();
    this.unsubscribeCommands();
  }

  private async startTunnel(): Promise<void> {
    // 直译 ZeroTierVpnService.startTunnel 顺序：
    // ① 读配置（activePlanetId → planet 档案 → identityPerPlanet → 身份 seed）
    // ② NAPI start（核心装载身份/planet、Starting 态）
    // ③ establish 由 onEstablish 回调驱动（VpnConfig 组装 → create → swapFd）
    // ④ protectProcessNet 一次（create 成功后；UNVERIFIED-1 最稳路径）
    await this.runtime?.start();
  }

  private async stopTunnel(): Promise<void> {
    // 直译 stopTunnel 顺序（幂等）：NAPI stop（先停数据面消费线程）→
    // destroy VPN 连接 → 终态化快照（Stopped）→ 发 STATE_CHANGED
    await this.runtime?.shutdown();
    this.stateBus?.writeTerminal('stopped', undefined, undefined);
  }

  private subscribeCommands(ctx: Context): void {
    // 主进程指令：CMD_STOP（优雅停机后自停扩展）、CMD_RESTART（换代重启）
    const info: commonEventManager.CommonEventPublishData = { events: [IpcEvents.CMD_STOP, IpcEvents.CMD_RESTART] };
    commonEventManager.createSubscriber(info, (err, sub) => {
      if (err || !sub) return;
      this.cmdSub = sub;
      commonEventManager.subscribe(sub, (e, data) => {
        if (data?.event === IpcEvents.CMD_STOP) {
          void this.stopTunnel().then(() => {
            // 自停扩展进程（终态快照已落盘）
            // 注意：stopVpnExtensionAbility 需要 want——进程内经 context 无法
            // 构造完整 want；主进程在发布 CMD_STOP 后自行调用
            // stopVpnExtensionAbility（双保险：指令 + 进程停止各一次）
          });
        } else if (data?.event === IpcEvents.CMD_RESTART) {
          void this.runtime?.restartFromConfig();
        }
      });
    });
  }

  private unsubscribeCommands(): void {
    if (this.cmdSub !== null) {
      commonEventManager.unsubscribe(this.cmdSub);
      this.cmdSub = null;
    }
  }
}
```

（`CommonEventPublishData`/`createSubscriber` 参数形态为 `CommonEventSubscribeInfo`——实现时按 d.ts 修正类型名：`new commonEventManager.CommonEventSubscribeInfo({ events: [...] })`。）

- [ ] **Step 2: 写 ExtRuntime.ets**

```typescript
// ExtRuntime.ets — NAPI 隧道函数族的扩展进程包装（D14 隔离面）
//
// 职责：config 组装（store → TunnelConfig JSON）、回调接线
// （onEstablish → VpnConfig 组装 → create → protectProcessNet → swapFd；
//  onTeardown → destroy）、重建/换代编排。
import { vpnExtension } from '@kit.NetworkKit';
import { Context } from '@kit.AbilityKit';
import { TunnelNapi, EstablishRequest } from '../common/CoreRuntime';
import { StoreRepo } from '../store/StoreRepo';
import { IdentityStore } from '../store/IdentityStore';
import { ExtStateBus } from './ExtStateBus';

export class ExtRuntime {
  private conn: vpnExtension.VpnConnection | null = null;
  private destroyed = false;

  constructor(private ctx: Context, private bus: ExtStateBus) {}

  /** 冷启动/重建：读 store → 身份 seed → NAPI start（幂等由 NAPI 保证） */
  async start(): Promise<void> {
    const store = StoreRepo.store;
    const planetId = await store.activePlanetId();
    const planets = await store.readPlanets();
    const planet = planets.find(p => p.id === planetId) ?? null;
    const prefs = await store.readPrefs();
    const networks = await store.readActiveNetworks();
    const moons = await store.readActiveMoons();
    // 身份分流：独立模式切行星须把共享身份 seed 到该行星目录（核心构造读那里）
    if (prefs.identityPerPlanet) {
      await IdentityStore.seedSharedIdentity(store.paths, planetId);
    }
    const config = {
      dataStoreRoot: store.paths.dataStoreRoot,
      planetDir: store.paths.planetStateDir(planetId),
      planetFile: planet !== null && planet.fileName !== null
        ? `${store.paths.planetsDir}/${planet.fileName}` : '',
      identityPerPlanet: prefs.identityPerPlanet,
      disableIpv6: prefs.disableIpv6,
      networks: networks.map(n => ({
        nwid: n.networkId, routeViaZeroTier: n.routeViaZeroTier,
      })),
      moons: moons.map(m => ({ worldId: m.worldId, seed: m.seed })),
    };
    TunnelNapi.setCallbacks({
      onEstablish: (req: EstablishRequest) => { void this.establish(req); },
      onTeardown: () => { void this.teardownVpn(); },
      onStateChanged: () => { void this.bus.flush(); },
    });
    TunnelNapi.start(JSON.stringify(config));
  }

  /** onEstablish：VpnConfig 组装（D8）→ create → protectProcessNet → swapFd */
  private async establish(req: EstablishRequest): Promise<void> {
    try {
      if (this.conn !== null) {
        await this.destroyVpnQuiet(); // 换代（D3）：旧连接先拆
      }
      const addresses: Array<vpnExtension.LinkAddress> = [];
      for (const a of req.v4Addrs) addresses.push(this.linkAddress(a, 1));
      if (!this.disableIpv6Effective()) {
        for (const a of req.v6Addrs) addresses.push(this.linkAddress(a, 2));
      }
      const routes: Array<vpnExtension.RouteInfo> = [];
      for (const r of req.routes4) routes.push(this.routeInfo(r, 1));
      if (!this.disableIpv6Effective()) {
        for (const r of req.routes6) routes.push(this.routeInfo(r, 2));
      }
      const config: vpnExtension.VpnConfig = {
        addresses,
        routes,
        dnsAddresses: req.dns.length > 0 ? req.dns : undefined,
        mtu: Math.max(576, Math.min(1500, req.mtu)), // VpnConfig 硬性范围 clamp（D8）
        isIPv6Accepted: !this.disableIpv6Effective(),
        isInternal: false,
        isBlocking: false,
      };
      if (this.conn === null) {
        this.conn = vpnExtension.createVpnConnection(this.context());
      }
      const fd = await this.conn.create(config);
      // 进程级 protect（D4/UNVERIFIED-1 最稳路径：一次调用护全进程 socket）
      try { await this.conn.protectProcessNet(); } catch (_e) { /* 拒绝不阻断 */ }
      TunnelNapi.swapFd(fd);
    } catch (e) {
      // create 失败（含 2203002 已存在）→ 拆净重试一次；再失败保持 Starting，
      // 等下次 netconf 聚合重发（对齐 Android establish 失败不 Failed 语义）
      await this.destroyVpnQuiet();
      try {
        const fd2 = await (this.conn as vpnExtension.VpnConnection).create(config2(config));
        try { await (this.conn as vpnExtension.VpnConnection).protectProcessNet(); } catch (_e) {}
        TunnelNapi.swapFd(fd2);
      } catch (_e2) { /* 放弃本次，等重发 */ }
    }
  }

  /** onTeardown：全部网络失效——destroy VPN（路由自动撤销），实例保持可用 */
  private async teardownVpn(): Promise<void> {
    await this.destroyVpnQuiet();
  }

  /** 切网自愈（D9）：destroy VPN → restartCore（C++ 内 stop+start 保配置）→
   *  等 netconf 重聚合 establish */
  async reconnectCore(): Promise<void> {
    await this.destroyVpnQuiet();
    TunnelNapi.restartCore();
  }

  /** CMD_RESTART：重读 store 起核（行星切换/偏好热生效路径） */
  async restartFromConfig(): Promise<void> {
    TunnelNapi.stop();
    await this.destroyVpnQuiet();
    await this.start();
  }

  async shutdown(): Promise<void> {
    TunnelNapi.stop();
    await this.destroyVpnQuiet();
  }

  private async destroyVpnQuiet(): Promise<void> {
    if (this.conn !== null) {
      try { await this.conn.destroy(); } catch (_e) { /* 已销毁 */ }
      this.conn = null; // UNVERIFIED-2：不依赖系统回收，显式 destroy
    }
  }

  // ---- VpnConfig 组装 helper（RouteInfo.interface 填法集中此一处，UNVERIFIED-3） ----

  private disableIpv6Effective(): boolean {
    return this.prefsDisableIpv6; // start() 时快照（核心构造参数语义，对齐 NodeRuntime）
  }
  private prefsDisableIpv6: boolean = false; // start() 内赋值（实现时接线）

  private context(): Context { return this.ctx; }

  /** "ip/prefix" → LinkAddress（prefix 缺省按 64 直译 NetworkContextMath 语义） */
  private linkAddress(cidr: string, family: number): vpnExtension.LinkAddress {
    const [addr, prefixStr] = cidr.split('/');
    const prefix = prefixStr !== undefined ? Number(prefixStr)
      : (family === 1 ? 32 : 64);
    return {
      address: { address: addr, family },
      prefixLength: prefix,
    };
  }

  /** "dest/prefix [via gw]" → RouteInfo（hasGateway 由 via 段判定） */
  private routeInfo(route: string, family: number): vpnExtension.RouteInfo {
    const viaIdx = route.indexOf(' via ');
    const dest = viaIdx >= 0 ? route.substring(0, viaIdx) : route;
    const gw = viaIdx >= 0 ? route.substring(viaIdx + 5) : '';
    const [addr, prefixStr] = dest.split('/');
    const prefix = prefixStr !== undefined ? Number(prefixStr)
      : (family === 1 ? 32 : 64);
    return {
      interface: '', // UNVERIFIED-3：先空串（Spike 验证；被拒则改 vNIC 名——集中此一处）
      destination: { address: { address: addr, family }, prefixLength: prefix },
      gateway: { address: gw === '' ? '0.0.0.0' : gw, family },
      hasGateway: gw !== '',
    };
  }
}
```

（`config2(config)` 与 `this.prefsDisableIpv6` 接线为实现期收口点：catch 分支复用外层 `config` 变量即可（把组装提到 try 外）；`prefsDisableIpv6` 在 `start()` 读 prefs 后赋值。`vpnExtension.LinkAddress` 实际从 `@ohos.net.connection` 导入——实现时按 `import { connection } from '@kit.NetworkKit'` 修正类型命名空间。）

- [ ] **Step 3: 写 ExtStateBus.ets + ExtNetWatch.ets**

```typescript
// ExtStateBus.ets — 扩展进程状态聚合与快照写方（TunnelStateBus 跨进程投影）
//
// 进程内无 UI，TunnelStateBus 的 StateFlow 投影退化为：NAPI onStateChanged →
// flush()（拉 snapshot() → 补 pathSatisfied → 写快照文件 → 发 STATE_CHANGED）。
// eventLog 40 条滚动在 C++ 侧（TunnelRuntime::log），此处只透传。
import { Context } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { commonEventManager } from '@kit.BasicServicesKit';
import { IpcEvents } from '../common/IpcEvents';
import { StoreRepo } from '../store/StoreRepo';
import { TunnelNapi } from '../common/CoreRuntime';

export class ExtStateBus {
  private pathSatisfied = true; // NetWatch 透出；缺省 true（TunnelStateBus 同语义）
  private flushing = false;

  constructor(private ctx: Context) {}

  setPathSatisfied(ok: boolean): void {
    this.pathSatisfied = ok;
    TunnelNapi.setPathSatisfied(ok);
    void this.flush();
  }

  /** 快照落盘 + 通知主进程（level-triggered：主进程重读全量） */
  async flush(): Promise<void> {
    if (this.flushing) return; // 合并在途（有损语义允许）
    this.flushing = true;
    try {
      const snap = JSON.parse(TunnelNapi.snapshot()) as Record<string, Object>;
      snap['pathSatisfied'] = this.pathSatisfied;
      snap['writtenAt'] = Date.now();
      const file = StoreRepo.store.paths.snapshotFile;
      const tmp = `${file}.tmp`;
      const f = await fs.open(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE
        | fs.OpenMode.TRUNC);
      await fs.write(f.fd, JSON.stringify(snap));
      await fs.close(f.fd);
      await fs.rename(tmp, file);
      commonEventManager.publish(IpcEvents.STATE_CHANGED, () => {});
    } finally {
      this.flushing = false;
    }
  }

  /** 终态化（onDestroy/CMD_STOP 兜底）：写 Stopped 快照（runtime 已停，snapshot
   *  仍可返回最后状态——由壳改写 kind 后落盘） */
  async writeTerminal(kind: string, reason: string | undefined,
    recoverable: boolean | undefined): Promise<void> {
    try {
      const snap = JSON.parse(TunnelNapi.snapshot()) as Record<string, Object>;
      const st = (snap['tunnelState'] ?? {}) as Record<string, Object>;
      st['kind'] = kind;
      if (reason !== undefined) st['reason'] = reason;
      if (recoverable !== undefined) st['recoverable'] = recoverable;
      snap['tunnelState'] = st;
      snap['writtenAt'] = Date.now();
      const file = StoreRepo.store.paths.snapshotFile;
      const tmp = `${file}.tmp`;
      const f = await fs.open(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE
        | fs.OpenMode.TRUNC);
      await fs.write(f.fd, JSON.stringify(snap));
      await fs.close(f.fd);
      await fs.rename(tmp, file);
      commonEventManager.publish(IpcEvents.STATE_CHANGED, () => {});
    } catch (_e) { /* 尽力而为 */ }
  }
}
```

```typescript
// ExtNetWatch.ets — 物理网络监听（D9；NetWatch.kt 防抖语义直译）
//
// 防抖 1500ms（对齐 Android NET_CHANGE_DEBOUNCE_MS）：网络可用边沿后等表
// 稳定再触发自愈；不可用即时透出 pathSatisfied=false（卡片「无网络」）。
import { connection } from '@kit.NetworkKit';

const NET_CHANGE_DEBOUNCE_MS = 1500;

export class ExtNetWatch {
  private conn: connection.NetConnection | null = null;
  private debounceTimer = -1;
  private running = true;

  constructor(private onNetworkChange: () => void) {}

  start(): void {
    this.conn = connection.createNetConnection();
    this.conn.register('netAvailable', () => this.scheduleDebounce());
    this.conn.register('netUnavailable', () => {
      // 即时路径断言（不防抖——「无网络」卡片须即时）
      // pathSatisfied 经 ExtStateBus 透出；网络恢复由 netAvailable 走防抖
    });
    this.conn.register('netCapabilitiesChange', () => this.scheduleDebounce());
  }

  private scheduleDebounce(): void {
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = -1;
      if (this.running) this.onNetworkChange();
    }, NET_CHANGE_DEBOUNCE_MS);
  }

  shutdown(): void {
    this.running = false;
    if (this.debounceTimer >= 0) clearTimeout(this.debounceTimer);
    this.conn?.unregister(() => {});
    this.conn = null;
  }
}
```

（`ExtNetWatch.start()` 由 ZeroTierVpnExtAbility.onCreate 构造后调用——实现时在壳的 onCreate 补 `this.netWatch?.start()`；pathSatisfied 透出与 bus.setPathSatisfied 的接线同处收口。`netUnavailable/netAvailable` 判定 pathSatisfied 的正反路径按 NetWatch.kt 逐行对照收口。）

- [ ] **Step 4: 编译验证 + Commit**

Run: assembleHap。
Expected: BUILD SUCCESSFUL。

```bash
git add entry/src/main/ets/vpnext/
git commit -m "feat(vpnext): VPN 扩展进程四件套

VpnExtensionAbility 壳（onCreate 拉起/优雅终态化/指令订阅）、ExtRuntime
（store→config 组装、onEstablish→VpnConfig→create→protectProcessNet→
swapFd、2203002 重试、换代 destroy+create）、ExtStateBus（快照落盘 +
STATE_CHANGED）、ExtNetWatch（1.5s 防抖切网自愈进程内闭环）。D14 隔离面。"
```

---

### Task 11: tunnel/StatusStore.ets + TunnelController.ets（主进程侧）

**Files:**
- Create: `entry/src/main/ets/tunnel/StatusStore.ets`
- Create: `entry/src/main/ets/tunnel/TunnelController.ets`

**Interfaces:**
- Consumes: Task 1 IpcEvents/TunnelContract、Task 4 StoreRepo。
- Produces: `StatusStore.current(): TunnelSnapshot | null`、`StatusStore.subscribe(cb): () => void`、`StatusStore.refresh()`；`TunnelController.ensureStarted()/stop()/restartIfRunning()/isRunning/markStartIntent/startIntentActive/clearStartIntent`（A5 UI 唯一入口）。

**直译源对照**：TunnelController.kt 全量语义（启动窗口 30s/代际互斥/awaitSettled 15s/幂等门控），映射差异：状态读走 StatusStore 快照（跨进程）而非同进程 StateFlow；`VpnService.prepare` 无等价（鸿蒙首次 create() 系统弹窗——ensureStarted 不经授权器直接 startVpnExtensionAbility，失败态经快照回流）；`ZeroTierVpnService.start/stop` → `vpnExtension.startVpnExtensionAbility/stopVpnExtensionAbility`。

- [ ] **Step 1: 写 StatusStore.ets**

```typescript
// StatusStore.ets — 快照读方（主进程；对齐 iOS StatusStore 跨进程消费语义）
//
// 启动读一次 + 订阅 STATE_CHANGED 全量重读（level-triggered）；快照陈旧
// （writtenAt 落后系统时间 30s+ 且隧道存活）时定时器兜底重读（VpnExt 被杀
// 的「假在线」防线——A6 真机调参，先 10s 轮询兜底）。
import fs from '@ohos.file.fs';
import { commonEventManager } from '@kit.BasicServicesKit';
import { Context } from '@kit.AbilityKit';
import { IpcEvents } from '../common/IpcEvents';
import { TunnelSnapshot, parseSnapshot, alive } from '../common/TunnelContract';
import { StoreRepo } from '../store/StoreRepo';

type ChangeCb = (s: TunnelSnapshot | null) => void;

export class StatusStore {
  private static snap: TunnelSnapshot | null = null;
  private static listeners: Set<ChangeCb> = new Set();
  private static sub: commonEventManager.CommonEventSubscriber | null = null;
  private static pollTimer = -1;

  static init(ctx: Context): void {
    StoreRepo.init(ctx);
    void StatusStore.refresh();
    const info = new commonEventManager.CommonEventSubscribeInfo(
      { events: [IpcEvents.STATE_CHANGED] });
    commonEventManager.createSubscriber(info, (err, s) => {
      if (err || !s) return;
      StatusStore.sub = s;
      commonEventManager.subscribe(s, () => void StatusStore.refresh());
    });
    // 兜底轮询：10s（VpnExt 异常死亡时 STATE_CHANGED 永不再来）
    StatusStore.pollTimer = setInterval(() => {
      if (StatusStore.snap !== null && alive(StatusStore.snap.tunnelState)) {
        void StatusStore.refresh();
      }
    }, 10_000);
  }

  static async refresh(): Promise<void> {
    try {
      const text = await fs.readText(StoreRepo.store.paths.snapshotFile);
      StatusStore.snap = parseSnapshot(text);
    } catch (_e) {
      StatusStore.snap = null; // 快照不存在 = 从未启动
    }
    StatusStore.listeners.forEach(cb => cb(StatusStore.snap));
  }

  static current(): TunnelSnapshot | null { return StatusStore.snap; }

  static subscribe(cb: ChangeCb): () => void {
    StatusStore.listeners.add(cb);
    cb(StatusStore.snap); // 订阅即推当前值（StateFlow 语义）
    return () => StatusStore.listeners.delete(cb);
  }
}
```

- [ ] **Step 2: 写 TunnelController.ets**

```typescript
// TunnelController.ets — 启停编排门面（直译 tunnel/TunnelController.kt；
// UI 层唯一入口，对齐 iOS VPNManager 职责）
//
// 映射差异：① 状态读 StatusStore 快照（跨进程）非同进程 StateFlow；
// ② 无 prepare() 授权器——鸿蒙授权在首次 create() 系统弹窗，ensureStarted
// 直起扩展进程，拒绝态经快照回流；③ 停启编排等待以快照 tunnelState 为准。
import { vpnExtension } from '@kit.NetworkKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { Context, Want } from '@kit.AbilityKit';
import { IpcEvents } from '../common/IpcEvents';
import { alive } from '../common/TunnelContract';
import { StatusStore } from './StatusStore';

const START_INTENT_WINDOW_MS = 30_000;
const SETTLE_TIMEOUT_MS = 15_000;
const SETTLE_POLL_MS = 200;

/** 扩展进程 want（module.json5 声明名对齐） */
function tunnelWant(): Want {
  return {
    deviceId: '',
    bundleName: 'cn.imgozi.h.planetport',
    abilityName: 'ZeroTierVpnExtAbility',
  } as Want;
}

export class TunnelController {
  private static startIntentAtMs = 0;
  private static gen = 0; // 停启代际（stopGeneration 直译）
  private static reconnectInFlight = false;

  static markStartIntent(): void { TunnelController.startIntentAtMs = Date.now(); }
  static get startIntentActive(): boolean {
    return Date.now() - TunnelController.startIntentAtMs < START_INTENT_WINDOW_MS;
  }
  static clearStartIntent(): void { TunnelController.startIntentAtMs = 0; }

  static get isRunning(): boolean {
    const snap = StatusStore.current();
    return snap !== null && alive(snap.tunnelState);
  }

  /** 幂等启动（授权经系统首次 create() 弹窗；拒绝态由快照回流呈现） */
  static ensureStarted(): void {
    if (TunnelController.isRunning) return;
    TunnelController.markStartIntent();
    vpnExtension.startVpnExtensionAbility(tunnelWant()).catch(() => {
      // 启动失败：窗口内无快照更新 → UI 按窗口外判定回落
    });
  }

  /** 幂等停止：终态 no-op；存活/Failed 放行——代际自增 + 优雅指令 + 进程停止双保险 */
  static async stop(): Promise<void> {
    const snap = StatusStore.current();
    if (snap !== null && !alive(snap.tunnelState)
      && snap.tunnelState.kind !== 'failed') return;
    TunnelController.gen++;
    // 双保险：先指令优雅终态化（等快照 Stopped），再停扩展进程
    commonEventManager.publish(IpcEvents.CMD_STOP, () => {});
    const settled = await TunnelController.awaitSettled();
    if (settled) {
      vpnExtension.stopVpnExtensionAbility(tunnelWant()).catch(() => {});
    } else {
      // 优雅路径超时：直接停进程（onDestroy 兜底终态化，UNVERIFIED-4）
      vpnExtension.stopVpnExtensionAbility(tunnelWant()).catch(() => {});
    }
  }

  /** 等离开存活态（15s 超时）；快照轮询（200ms）近似 StateFlow first{} */
  static async awaitSettled(timeoutMs: number = SETTLE_TIMEOUT_MS): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const snap = StatusStore.current();
      if (snap !== null && !alive(snap.tunnelState)) return true;
      await new Promise<void>(res => setTimeout(res, SETTLE_POLL_MS));
    }
    const snap = StatusStore.current();
    return snap !== null && !alive(snap.tunnelState);
  }

  /** 偏好热生效/行星切换（在跑才重启；未跑 no-op——偏好已落盘下次启动生效） */
  static async restartIfRunning(): Promise<void> {
    if (!TunnelController.isRunning) return;
    TunnelController.markStartIntent();
    if (TunnelController.reconnectInFlight) {
      // 排队补发（行星切换不可丢——直译 QF-3 排队语义）：等在飞收口后重发
      const waited = Date.now();
      while (TunnelController.reconnectInFlight && Date.now() - waited < 20_000) {
        await new Promise<void>(res => setTimeout(res, 200));
      }
      if (TunnelController.reconnectInFlight) return; // 放弃
      if (!TunnelController.isRunning) { TunnelController.ensureStarted(); return; }
      return TunnelController.restartIfRunning();
    }
    TunnelController.reconnectInFlight = true;
    try {
      const generationAtStop = TunnelController.gen;
      commonEventManager.publish(IpcEvents.CMD_RESTART, () => {});
      // 代际比对：窗口内用户停止则放弃迟到启动（VpnExt 已在指令内停机）
      if (TunnelController.gen !== generationAtStop) return;
    } finally {
      TunnelController.reconnectInFlight = false;
    }
  }
}
```

（`restartIfRunning` 的代际窗口语义在鸿蒙收窄：换代重启全在 VpnExt 进程内完成（CMD_RESTART 一发即收口），主进程不再有 STOP→START 两段下发——代际失效窗口仅覆盖指令在途瞬间；「窗口内用户停止」由 VpnExt 内 stopTunnel 幂等与 CMD_STOP 后到先到竞争兜底（stop 一定后到则进程已停，CMD_RESTART 落空无害）。实现时把这段映射差异写进类头注释。）

- [ ] **Step 3: EntryAbility 接线 + 编译验证**

`entry/src/main/ets/entryability/EntryAbility.ets` 的 `onCreate` 追加：

```typescript
import { StoreRepo } from '../store/StoreRepo';
import { StatusStore } from '../tunnel/StatusStore';
// onCreate 内：
StoreRepo.init(this.context);
StatusStore.init(this.context);
void LanguageManager.init(); // Task 7 的 LanguageManager（import 补齐）
```

Run: assembleHap。
Expected: BUILD SUCCESSFUL。

- [ ] **Step 4: Commit**

```bash
git add entry/src/main/ets/tunnel/ entry/src/main/ets/entryability/EntryAbility.ets
git commit -m "feat(tunnel): 主进程状态消费与启停编排门面

StatusStore 快照读方（STATE_CHANGED 订阅 + 10s 兜底轮询防假在线）；
TunnelController 直译启动窗口/代际/awaitSettled 语义，停止走优雅指令
+进程停止双保险，换代重启收敛为 CMD_RESTART 进程内闭环。"
```

---

### Task 12: module.json5 扩展声明 + 集成回归

**Files:**
- Modify: `entry/src/main/module.json5`

**Interfaces:**
- Consumes: Task 10 的 `ZeroTierVpnExtAbility` 类名。
- Produces: HAP 内合法声明 `extensionAbilities`（type:"vpn"）。

- [ ] **Step 1: module.json5 增 extensionAbilities**

在 `"abilities": [...]` 之后追加：

```json5
"extensionAbilities": [
  {
    "name": "ZeroTierVpnExtAbility",
    "srcEntry": "./ets/vpnext/ZeroTierVpnExtAbility.ets",
    "type": "vpn",
    "exported": true
  }
]
```

- [ ] **Step 2: 三链路集成回归**

Run（顺序）：
1. host：`cmake --build native/build-host -j8 && ctest --test-dir native/build-host --output-on-failure` → 全 PASS（125+ 全量回归）。
2. OHOS arm64 交叉构建 → 成功。
3. `assembleHap` → BUILD SUCCESSFUL；产物 HAP 内 `.so` 含 `TunnelRuntime/snapshotJson` 符号（`strings` 验证）。

- [ ] **Step 3: Commit**

```bash
git add entry/src/main/module.json5
git commit -m "feat(module): VPN 扩展能力声明

extensionAbilities 增 type:vpn 的 ZeroTierVpnExtAbility（exported，
双进程模型成立）；MANAGE_VPN 暂不声明（d.ts create() 仅标 INTERNET，
真机验证后按需补，挂账 A6）。"
```

---

## Self-Review

**1. Spec 覆盖**
- D1（快照文件+事件唤醒）：Task 1 契约、Task 10 写方、Task 11 读方 ✓
- D2（NAPI 函数族）：Task 9（start/stop/restartCore/swapFd/applyConfig/snapshot/setCallbacks + protect tsfn）✓
- D3（destroy+create 换代 + swap(fd)）：Task 8 swapFd/restartCore、Task 10 establish 换代分支 ✓
- D4（protect 双轨）：Task 9 protect token 同步等待 + Task 10 protectProcessNet 主路径（per-socket 备而不用，UNVERIFIED-1）✓
- D5（共享沙盒 + commonEvent + level-triggered）：Task 1 IpcEvents、Task 3 StorePaths、Task 4 fireConfig 发布、Task 10 CONFIG 订阅（在 ExtRuntime.start 的 config 重读路径经 CMD/CONFIG 事件驱动——**缺口**：Task 10 壳未显式订阅 CONFIG_CHANGED 触发 applyConfig。**修复**：Task 10 Step 1 的 subscribeCommands 的 info.events 数组已含 CMD_STOP/CMD_RESTART，实现时把 `IpcEvents.CONFIG_CHANGED` 一并加入并在回调里 `TunnelNapi.applyConfig(重读序列化)`——已并入 Task 10 实现说明）✓
- D8（MTU clamp 1500、v4/v6 聚合单 VpnConfig）：Task 10 establish（clamp 在 VpnConfig 组装处，TunnelRuntime 给原始值）✓
- D9（扩展进程内切网自愈）：Task 10 ExtNetWatch + reconnectCore ✓
- D10（datastore 0600、planet-state 分目录）：A2 已落地（putFileAtomic secure/stateFilePathFor）；Task 5 记平台差异 ✓
- D11（身份按行星分流）：Task 10 start（seedSharedIdentity + planetDir/identityPerPlanet 构造参数）——**与设计文档的差异**：runtime.json 中转未采用，A2 已裁决为构造参数直传（对齐 NodeRuntime 构造），计划 Global Constraints 之直译口径已含 ✓
- D13（host 单测标准）：Task 6/8 host 金标向量；ArkTS 任务编译+review ✓
- D14（Spike 隔离面）：Task 9 napi protect 路径 + Task 10 vpnext/ 全部——无越界（TunnelRuntime/ColorMath/store 均不依赖 Spike 结论）✓
- A4 范围（配置/身份/状态/主题/语言）：Task 2-7 全覆盖；Importer/BackgroundImageStore 明确留 A5（计划开头声明）✓

**2. 占位符扫描**
- Task 8 Step 1 测试用例为骨架列举（8 例名+一行语义）——TDD 完整代码要求下属边缘：已注明「实现者按此 8 例全量落地」且实现体在 Step 2 详述；host 测试代码由实现者按用例名+断言语义展开，验收以 8 例全过为准。
- Task 4 Step 1 尾部「示意名 helper」与 Task 10 的 `config2/prefsDisableIpv6` 收口说明——均为实现期收口点（有明确目标形态），非 TBD。
- 无 "TBD/TODO/稍后实现" 残留。

**3. 类型一致性**
- `TunnelSnapshot` 字段（Task 1）与 `RuntimeState`→`snapshotJson()`（Task 8）、`ExtStateBus.flush` 补丁字段（Task 10）、`StatusStore.refresh` 解析（Task 11）四方对齐（pathSatisfied/writtenAt 由写方补——Task 8 序列化不含，Task 10 注入）✓
- `EstablishRequest`：Task 8 C++ 结构 ↔ Task 9 NAPI JSON 字符串 ↔ Task 10 ArkTS interface 字段名一致（v4Addrs/v6Addrs/routes4/routes6/dns/mtu）✓
- `TunnelConfig` JSON 字段：Task 8 结构 ↔ Task 10 start() 组装（dataStoreRoot/planetDir/planetFile/identityPerPlanet/disableIpv6/networks/moons）✓
- `nwid` 形态：store 层 16 位 hex 字符串（NetworkEntry.networkId）→ Task 10 组装时传 hex 字符串、Task 9 NAPI 解析 hex→uint64 ✓（实现时 start() 的 `nwid: n.networkId` 保持字符串，NAPI 侧 strtoull(base 16)）
- module.json5 abilityName（Task 12）= Task 10 类名 = Task 11 tunnelWant ✓

**执行顺序**（依赖驱动，支持波次并行）：Task 1 → {2, 6} → 3 → {4, 8} → {5, 7} → 9 → 10 → 11 → 12。Task 7 的 ColorMath import 注释态在 Task 9 解开——两任务提交说明互引。
