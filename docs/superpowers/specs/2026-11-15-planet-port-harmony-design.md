# Planet Port · HarmonyOS 版设计规格

> 日期：2026-11-15
> 前置调研： [2026-10-28-鸿蒙迁移深度调研.md](../../2026-10-28-鸿蒙迁移深度调研.md) （可行性已定稿，本规格在其基础上收敛实施设计）
> 功能基线： **iOS v1.4.0**（planet-port-ios main，2026-11-07）
> 行为规格源： iOS v1.4.0（隧道语义/UI 行为）+ Android v1.6.0（数据面领先项与迁移范式）；两者冲突时以 iOS 行为为最终裁决

---

## 1. 背景与目标

planet-port-harmony 是 Planet Port 的鸿蒙生态版本。参考 planet-port-ios 的功能，在 HarmonyOS NEXT 上交付全功能对齐的 ZeroTier 客户端：多行星管理、多网络同连、路由/DNS 热重配、Peers/Moon/诊断、主题/三语/二维码传输全量体验。

**核心验收原则：功能不遗漏。** 以本规格 §3 的 36 项功能清单为闭环验收清单。

### 1.1 已定决策（2026-11-15 与用户确认）

| 决策点 | 结论 |
|---|---|
| 实施路径 | 先 Spike 再正式开发；Spike 结论为架构参数（D3/D4/D5）定稿依据 |
| 功能基线 | 全量对齐 iOS v1.4.0，仅接受 3 项既定平台降级（§3.G） |
| UI 策略 | 视觉/布局/交互对齐 iOS DESIGN.md 设计锚，用 ArkUI 实现（沿用 Android 版实践） |
| 开发环境 | DevEco/真机/开发者账号均未就绪 → 实施采用双轨并行编排（§6） |

---

## 2. 总体架构

沿用调研定稿的方案 B：**ArkTS 壳 + C++ 核心/数据面**，双进程模型对齐 iOS。

```
┌─ UIAbility 进程（ArkTS/ArkUI）─────────────┐
│ 页面(对齐iOS 7页) │ TunnelController 门面   │
│ AppConfigStore    │ 主题/语言/导入导出       │
└──────┬─────────────────────────────────────┘
       │ startVpnExtensionAbility + 共享沙盒 config/*.json
       │ commonEvent 双向（状态回传/命令下发）
┌──────▼─────────────────────────────────────┐
│ VpnExtensionAbility 进程（独立）             │
│ VpnConnection.create→TUN fd │ protect双轨    │
│ NAPI 边界（控制+状态流，不过包）             │
├─────────────────────────────────────────────┤
│ libplanetport_core.so（C++17, arm64-v8a）   │
│ CoreBridge(直译ZTBridge+行星目录重定向hook) │
│ ZeroTier 1.16.2 C API（零补丁）             │
│ 数据面: FrameConverter/ARP/NDP/NAT44/LPM    │
│ TUN epoll 读写线程 + swap() 换代 │ UDP:9994 │
└─────────────────────────────────────────────┘
```

相对调研文档的微调：数据面直译以 **Android v1.6.0 为规格**（NDP 合规实现、Dataplane.swap、establish 幂等闸门等 20+ 项数据面修复 iOS 侧尚未同步）。

基线：minAPI 12 / targetAPI 23 / arm64-v8a；MTU clamp 1500。

---

## 3. 功能对齐清单（iOS v1.4.0 → 鸿蒙，36 项全量）

### A. 行星管理（10 项）

| # | 功能 | 鸿蒙实现要点 |
|---|---|---|
| 1 | 官方 Planet 开箱即用 + 多私有 Planet 并存（隧道同一时刻只应用一套） | planets.json 模型直译 |
| 2 | 导入·文件 | 文件选择器 API |
| 3 | 导入·URL（进度模态 + 失败轻提示） | @ohos.net.http |
| 4 | 导入·动态二维码分片（ZTQR1：Deflate+Base45+CRC32 自适应分片） | ArkTS 直译 + 跨端金标向量 |
| 5 | 扫码单入口自动识别链接/分片 + 相册图片识别 | ScanKit（相机+相册） |
| 6 | ZTP KV 容器（分享携带名称/图标/底色元数据，扫码预填身份表单） | ArkTS 直译 |
| 7 | 分享·文件 / 二维码（分片方块阵列展示） | scanCore generateBarcode |
| 8 | World ID + 节点 ID 双查重 | 直译 |
| 9 | 行星即世界（planet-state/\<planetId\>/ 独立缓存隔离） | CoreBridge ztHookedPath 直译 |
| 10 | 跨行星切换确认流（自绘弹窗先断后启） | 直译 |

### B. 节点身份（1 项）

| # | 功能 | 鸿蒙实现要点 |
|---|---|---|
| 11 | 共享身份 / 每行星独立身份（互不可关联），切换即生效、切回恢复 | Android v1.4.0 存储层 + 核心身份路径分流直译（D11） |

### C. 网络连接（8 项）

| # | 功能 | 鸿蒙实现要点 |
|---|---|---|
| 12 | 多网络同连（软上限默认 2，2–6 可调，超上限确认放行） | NetworkContext 聚合 |
| 13 | 地址/网段冲突自动断开 + 卡片原因展示 | 冲突检测纯逻辑直译 |
| 14 | 开关即连接 + pending 进度指示 | 直译 |
| 15 | 状态细化：正在初始化→连接服务器→在线，阶段文案拆分 | 直译（含周期终结锚定重试计数） |
| 16 | 连接超时可配置（默认 45s / 步进 5s）+ 固定间隔无感重试 | 直译 |
| 17 | 飞行模式/断网即时「无网络」 | @ohos.net.connection |
| 18 | 加入网络（16 位 ID 输入 / 扫码） | 直译 |
| 19 | 一键复制（managed IP/节点 ID/网络 ID）+ 网络 ID 二维码 | 直译 |

### D. 路由与 DNS（4 项）

| # | 功能 | 鸿蒙实现要点 |
|---|---|---|
| 20 | 默认路由开关 + 多网络时强制关 + allow-lan 挖洞（物理网段前缀差集展开） | RoutePlanner 数学直译（鸿蒙无 excludedRoutes，天然适配） |
| 21 | DNS 三模式（网络下发/自定义/不使用；多网络同连不设 DNS） | VpnConfig.dnsAddresses（Spike S4 验证回退行为） |
| 22 | 路由/DNS 隧道内热重配不断开 | destroy+create 换代 + swap(fd)（D3） |
| 23 | IPv6 可禁用 | VpnConfig.isIPv6Accepted |

### E. Peers / Moon / 诊断 / 详情（4 项）

| # | 功能 | 鸿蒙实现要点 |
|---|---|---|
| 24 | Peers 实时列表（延迟语义色 <30ms 绿/<100ms 橙/≥100ms 红、relay 橙胶囊、三态空态） | 状态快照 JSON |
| 25 | Moon 管理（添加/文件导入/删除/缓存徽标/首页「卫星 x n」） | 直译 |
| 26 | 数据面诊断（出入站流量/ARP 问答/无路由丢弃计数/事件日志 40 条滚动） | 直译 |
| 27 | 网络详情页（地址/托管路由编号标签、网段网关点击切换、空态占位、删除网络） | 直译 |

### F. 体验（9 项）

| # | 功能 | 鸿蒙实现要点 |
|---|---|---|
| 28 | 保持在线：切网自愈（防抖 1.5s/代际计数/整核重启）+ 开 App 自动恢复 | 直译 + §3.G 降级 |
| 29 | 主题定制（HSL 色盘选主色/状态色派生开关/行星装饰盘派生） | 取色算法直译 |
| 30 | 自定义背景图 + 视差动画（可关） | 传感器服务替代 CoreMotion |
| 31 | 三语（zh-Hans/zh-Hant/EN）+ 应用内切换 | resources 多语言目录 + LanguageManager 查表 |
| 32 | 动物图标体系（92 图标 + 24 色板 + 名称哈希回退） | 资产复用 planet-animal-icons |
| 33 | 首页分页相册式翻页 + 固定毛玻璃区 + FAB + 活跃行星 🔗 提示 | ArkUI Swiper + 自绘 |
| 34 | 删除确认自绘锚定气泡 + 行星角标「使用中/上次使用/连接中」 | 直译 |
| 35 | 关于页（构建时间/代码版本）+ 商标保护校验（默认隐藏） | 隐藏采用 `if(false)` 条件，不删除代码 |
| 36 | 单 VPN 互斥 → 被其它 VPN 挤掉后回落掉线状态 | 直译 |

### G. 既定平台降级（3 项，文案管理预期）

1. 无 On Demand 保活（iOS NEOnDemandRuleConnect 无等价物）
2. 无开机自启（重启手机后需手动打开 App 重连；打开 App 即自动恢复）
3. 系统单 VPN 互斥（与 iOS 行为一致，非降级，文案说明）

---

## 4. 代码结构

```
planet-port-harmony/
├─ entry/                    # 主 HAP（UIAbility + VpnExtensionAbility）
│  ├─ src/main/ets/
│  │  ├─ pages/              # 7 页对齐 iOS（Home/PlanetSettings/NetworkDetail/Peers/Moon/Prefs/AddPlanet）
│  │  ├─ components/         # NetworkCard/PlanetIcon/CopyableValue/FabButton/ConfirmBubble/分片阵列…
│  │  ├─ tunnel/             # TunnelController（5 方法门面）+ 状态快照消费
│  │  ├─ store/              # AppConfigStore/IdentityStore/StatusStore/ThemeManager/LanguageManager
│  │  ├─ qrtransfer/         # ZTQR1 + ZTP 容器（~400 行）
│  │  ├─ vpnext/             # ZeroTierVpnExt.ets（VpnExtensionAbility 壳）
│  │  └─ common/             # IPC 事件契约/共享沙盒路径
│  └─ resources/             # 三语 + 图标资产 + 背景图
├─ core/                     # C++（CMake → libplanetport_core.so）
│  ├─ bridge/                # CoreBridge.cpp（直译 ZTBridge.mm 529 行）
│  ├─ dataplane/             # FrameConverter/ARP/NDP/NAT44/NetworkContext/LPM/RoutePlanner + swap()
│  ├─ napi/                  # NAPI 绑定（3 函数族，~500 行）
│  └─ CMakeLists.txt         # ohos.toolchain.cmake
├─ Core/                     # ZeroTier 1.16.2 tarball（bootstrap 拉取，不入库）
├─ scripts/bootstrap.sh      # tarball/SHA256/.fetched-tag 全套平移
├─ docs/superpowers/         # 规格+计划
└─ .github/workflows/        # macOS runner CI（对齐 Android 版模式）
```

预估 ~15,000–18,000 行新代码（调研 §7 估算 + v1.3/v1.4 新功能增量）。

---

## 5. 关键设计决策

调研 D1–D10 全部沿用，摘要：

| 决策 | 一句话内容 |
|---|---|
| D1 | 核心宿主在扩展进程（对齐 iOS 双进程）；快照文件 + 事件唤醒跨进程契约 |
| D2 | NAPI 三函数族（start/stop/protect 回调/snapshot JSON），零包路径 |
| D3 | 热重配 = destroy + create 同进程换代 + Dataplane.swap(fd)，核心不重启 |
| D4 | protect 双轨：API≥22 用 protectProcessNet()，否则 per-socket protect(fd) |
| D5 | 配置主路径 = 共享沙盒 config/*.json + commonEvent 唤醒 + level-triggered 全量重读 |
| D6 | DNS 三模式经 VpnConfig.dnsAddresses；不设置时回退行为待 Spike S4 |
| D7 | 默认路由 + allow-lan 前缀差集挖洞直译 |
| D8 | MTU clamp 1500；v4/v6 地址聚合进单 VpnConfig |
| D9 | 扩展进程内 @ohos.net.connection 切网自愈；心跳 + UI 看门狗 |
| D10 | 核心状态落 datastore（chmod 0600 直译）；planet-state 分目录隔离 |

新增决策（本规格引入）：

### D11 身份按行星分流（直译 Android v1.4.0 方案）

`identity.secret` 路径按当前身份模式解析：共享模式 → `identity/identity.shared`；独立模式 → `identity/identity.<planetId>`。CoreBridge 启动前由 ArkTS 写入 `config/runtime.json`（activePlanetId + identityMode），native 读该文件决定重定向目标。切换模式 = 停核心 → 改 runtime.json → 起核心；各行星身份文件永久保留，切回即恢复（对齐 iOS 行为）。

### D12 ZTQR1/ZTP 字节兼容硬约束

二维码分片协议三端互通是硬验收：鸿蒙 ArkTS 实现必须通过 iOS/Android 的金标向量（Base45/CRC32/Deflate raw/帧格式/ZTP KV 编解码）。跨端真机互扫验证进 M3 验收。Deflate 用 zlib raw 模式（Android 已趟通字节兼容）。

### D13 无真机轨道的「可编译可单测」标准

轨道 A 每阶段产物必须满足：hvigorw assembleHap 通过 + CMake arm64 交叉编译通过 + 纯逻辑（数据面/协议/路由数学/取色算法）在 macOS host 上跑金标向量单测。真机到位前用 host 单测守住直译保真度。

### D14 Spike 结论的返工隔离面

受 Spike S2–S5 结论影响、可能返工的代码收敛到两处：`vpnext/ZeroTierVpnExt.ets`（壳，~400 行）与 `napi/` 的 protect 回调路径。数据面、CoreBridge、UI、store、qrtransfer、主题算法全部与 Spike 结论无关。code review 时任何「Spike 依赖逻辑」越界都要打回。

---

## 6. 双轨实施计划

```
轨道 A（立即开工，无真机）              轨道 B（真机+账号到位后）
─────────────────────────            ─────────────────────────
A0 环境准备（装 DevEco/注册账号）       B0 真机采购到位（外部依赖，尽早启动）
A1 工程脚手架 + bootstrap.sh          B1 Spike S1–S3
    + S1 核心编译验证                     （编译→TUN→protect→端到端 ping）
A2 CoreBridge + NAPI + 数据面 C++    B2 Spike S4–S5
    （直译 + host 金标向量单测）            （DNS 回退/换代/事件/存活矩阵）
A3 VpnExt 壳 + TunnelController      B3 数据面联调
A4 store 层（配置/身份/状态/主题/语言）     （多网络 LPM/冲突/挖洞/热重配实测）
A5 UI 7 页全量 + qrtransfer + 三语    B4 端到端验收
A6 CI + 签名链                            （36 项功能清单逐项过 + 三端二维码互扫）
```

- 轨道 A 内部串行（A0→A6），A2/A4 与 A3 弱耦合可穿插。
- 轨道 B 启动时间取决于真机；B1–B2 若推翻 D3/D4/D5，按 D14 隔离面返工，A 轨其余产物不动。
- 两轨在 B3 汇合进入联调；里程碑 M1 隧道 / M2 功能 / M3 体验 / M4 发布映射到 B3–B4 验收段。

---

## 7. 风险与验收

### 7.1 风险（新增/升级项；调研 R1–R11 沿用）

| # | 风险 | 等级 | 缓解 |
|---|---|---|---|
| R12 | 真机到位晚，轨道 A 代码无真机反馈积压 | 中 | D13 host 单测守底；B 轨到位即集中验证 |
| R13 | iOS v1.4.0 新功能（身份模式/ZTP/重试计数）与 Android 实现存在语义细微差异 | 低 | 双规格源冲突时以 iOS 行为为最终裁决 |
| R14 | ArkUI 无 1:1 组件（毛玻璃/Capsule/分页手势细节） | 中 | Android 版 Compose 已趟过同构映射，沿用其组件映射结论 |

### 7.2 验收标准（最终发布门槛）

1. §3 全部 36 项功能逐项通过（含 3 项降级的文案落地）
2. 端到端：真机连官方 Planet 入网，与另一 ZT 节点 IPv4/IPv6 双向 ping 通
3. 二维码三端互通：鸿蒙↔iOS、鸿蒙↔Android 真机互扫导入导出
4. 存活性：24h 挂机、锁屏 8h、WiFi↔蜂窝切换 10 次自愈、杀 UI 进程隧道存活
5. 全部金标向量单测通过（ZTQR1/ZTP/NAT44/路由数学/取色算法）
6. GPL 血统零引入，ZeroTier MPL-2.0 声明齐备，自研代码 MIT

---

## 8. 参考资料

- 调研文档： [docs/2026-10-28-鸿蒙迁移深度调研.md](../../2026-10-28-鸿蒙迁移深度调研.md)
- iOS 行为规格： /Users/zivyuan/GoziLib/Zerotier/planet-port-ios （README / DESIGN.md / docs/PlanetPort.md / CHANGELOG v1.4.0）
- Android 迁移范式与数据面规格： /Users/zivyuan/GoziLib/Zerotier/planet-port-android （v1.6.0）
- @ohos.net.vpnExtension API： https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-net-vpnextension
- 先例工程： HarmonyRun/ZeroTier-HarmonyOS、flypigJ/Tailscale-OHOS（MeshArc）、Henry-Fox/OhosXray（详见调研 §3.4）
