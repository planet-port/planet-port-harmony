# Planet Port 鸿蒙版 A5 UI 实施计划（计划 4）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS v1.4.0 的 36 项功能清单 UI 主体全量落地：7 页 + 组件体系 + QRTransfer（ZTQR1/ZTP）+ 三语 + 92 动物图标 + 背景视差 + 主题接线。

**Architecture:** 单 @Entry + 手写页面栈条件渲染（对齐 Android `ui/AppRoot.kt` 模式，不用 Navigation 组件——转场全自绘可控）；状态用 ArkTS 状态 V2（@ObservedV2/@Trace/@Local）；纯逻辑（QRTransfer 编解码）node host 金标向量单测；UI 任务验收 = 全量编译 + 评审（D13）。

**Tech Stack:** ArkUI（Swiper/Canvas/gesture）、@ohos.sensor（重力视差）、@kit.ScanKit（generateBarcode + 扫码）、pako（Deflate raw，MIT）、@ohos.file.picker、@ohos.pasteboard、@ohos.net.http。

## Global Constraints

- **行为规格源**：iOS v1.4.0（UI 行为/视觉）+ Android v1.6.0（同构映射已趟通的实现范式）；冲突以 iOS 裁决。iOS 源 `../planet-port-ios`，Android 源 `../planet-port-android`（均在 /Users/zivyuan/GoziLib/Zerotier/ 下）。
- **视觉锚**：iOS `DESIGN.md`（8pt 网格/边距 20/卡片内边距 14/卡距 12/区块距 28；圆角小 10/卡 14/大表单 20；字号 身份区 20 semibold/行标题 15/ID·IP monospaced caption/徽标 caption2 Capsule；阴影全 App 仅 FAB black 0.25 r10 y5，弹窗卡 0.15 r12 y4）。DESIGN.md 与代码分歧处以**代码实况**为准（标题 22pt bold、Logo 40/圆角 9、卡片主标题 15pt semibold）。
- **三硬映射结论**（Android 已趟通，直接沿用）：①毛玻璃不做真模糊的头区——iOS 实态本就是「全透明填充 + 三段渐变 mask」（HomeView.swift:272-280），照抄；弹窗卡 `.regularMaterial` → ArkUI `backgroundBlurStyle(MaterialBlurStyle.Regular)`（真等价）。②Capsule = 完全圆角（RoundedCornerShape 50% 同义）。③相册翻页三时机拆解：落位提交选中（iOS settledPage）→ Swiper `onAnimationEnd`；过半驱动 chip（currentPage）→ Swiper `onChange`；旁页不销毁（beyondViewportPageCount）→ Swiper `cachedCount` 全保活。
- **零补丁红线**：Core/（ZeroTier tarball）与 native/（C++ 已收口）禁改；本计划只动 entry/src/main/ets/{pages,components,qrtransfer}、resources/、ohos 依赖配置。store/tunnel/vpnext 已收口层只在计划明确处小改（T2 ThemeManager 接线、T12 少量）。
- **D12 字节兼容硬约束**：ZTQR1/ZTP 必须通过 iOS `Tests/QRTransferCodecTests.swift` + `QRTransferFrameTests.swift` 的金标向量（node 直跑同码单测）。
- **D14**：UI 不受 Spike 结论影响；任何 Spike 依赖逻辑越界打回。
- **既有挂账随任务收口**：xcstrings 356 键扩表（T1）；peers paths 恒空——UI 勿做连通性判断（T11）；行星切换/身份模式切换后须显式 `TunnelController.restartIfRunning()`（T10）。
- **ArkTS 硬约束**（已踩坑全集）：禁构造器参数属性；对象字面量须显式类型（interface/Record 承载）；null 不赋 Object；fs.access 不存在时 reject（`.then(()=>true).catch(()=>false)`）；UI 组件每任务完成后必须**全量编译**验证（`rm -f .hvigor/cache/task-cache.json` + 确认 `N executed, 0 up-to-date`）——无引用方的新文件不进编译图是假绿，pages 下文件经 Index/路由链天然在图内。
- **隐藏 ≠ 删除**：商标保护校验等未启用 UI 用 `if (false)` 条件，不删代码。
- **不加测试用例**（用户全局规则）——唯一例外：QRTransfer 纯逻辑（D12 硬验收）的 node 金标向量单测，属直译保真度验证，放 qrtransfer/tests/（不进 hvigor 编译图）。

## File Structure

```
entry/src/main/ets/
├─ pages/                  # 7 页（对齐 iOS Views/）
│  ├─ Index.ets            # @Entry 根：改造成 AppRoot（页面栈宿主）
│  ├─ HomeView.ets         # 首页（Swiper 分页 + 头区 + FAB + 弹窗宿主）
│  ├─ NetworkDetailView.ets
│  ├─ PrefsView.ets
│  ├─ PlanetSettingsView.ets
│  ├─ PeerListView.ets
│  ├─ MoonView.ets
│  └─ AddPlanetPage.ets    #（含 AddPlanetForm 内嵌）
├─ components/             # 复用组件
│  ├─ DesignTokens.ets     # 栅格/字号/圆角/语义色/暗色适配
│  ├─ L10n.ets             # L(key) 运行时查表（三语 map + 语言切换通知）
│  ├─ PlanetIcon.ets       # 92 图标 key 表 + djb2 回退 + 24 色板
│  ├─ PlanetCardView.ets
│  ├─ NetworkCardView.ets  #（含 NetworkCardStatus 状态机）
│  ├─ CopyableValue.ets
│  ├─ FabButton.ets
│  ├─ ConfirmBubble.ets    # 锚定气泡
│  ├─ JoinNetworkSheet.ets
│  ├─ IconPickerSheet.ets
│  ├─ BackgroundImagePickerSheet.ets
│  ├─ AppAlert.ets         # 系统 alert 群 + toast + 进度模态
│  ├─ HomeParallaxBackground.ets
│  └─ HomeMetrics.ets
├─ qrtransfer/
│  ├─ Base45.ets / CRC32.ets / Deflate.ets / QRFrame.ets /
│  ├─ ChunkPlanner.ets / PayloadContainer.ets / QRTransfer.ets
│  ├─ QRRender.ets         # generateBarcode 封装 + 模块数探测
│  ├─ QRShareSheet.ets / QRReceiveSheet.ets / ShardGrid.ets / AlbumQrPicker.ets
│  └─ tests/               # node 金标向量（iOS 测试直译，D12）
├─ ui/                     # 路由与全局状态
│  ├─ AppRoot.ets          # Page 枚举 + 页面栈（AppRoot.kt 直译）
│  └─ AppState.ets         # iOS AppState.swift 直译（@ObservedV2）
└─ store/...               # 已收口（T2 小改 ThemeManager 接线）
resources/
├─ base/media/animal-*.png # 92 图标（PDF→PNG 脚本产出）
└─ rawfile/i18n/{en,zh-Hans,zh-Hant}.json   # 356+20 键查表
```

---

### Task 1: 资产管线 + 三语查表（L10n）

**Files:**
- Create: `scripts/assets-convert.sh`（92 PDF→PNG + xcstrings→3 JSON，macOS host 跑）
- Create: `entry/src/main/resources/base/media/animal-*.png`（92 个）
- Create: `entry/src/main/resources/rawfile/i18n/{en,zh-Hans,zh-Hant}.json`
- Create: `entry/src/main/ets/components/L10n.ets`

**Interfaces:**
- Consumes: T7 `LanguageManager`（LanguageManager.ets 已有 resolve/get 语义）。
- Produces: `L10n.get(key: string): string`（缺键回退 key 本身）；`L10n.notify(): void`（语言切换后广播重渲染）；92 PNG 命名 `animal-<key>.png`；`IconCatalog.keys: string[]`（92 键顺序 = iOS PlanetIcon.swift:10-23 catalog 数组）。

**直译源对照**：iOS `Shared/Localization/Localizable.xcstrings`（356 键×3 语）+ `Modules/QRTransfer/Resources/QRTransfer.xcstrings`（20 键）→ 合并为单表（键冲突无：qrtransfer.* 自带前缀）。转换脚本用 python3 + json（xcstrings 本体是 JSON）。图标：`../planet-port-ios/PlanetPort/Assets.xcassets/animal-*.imageset/*.pdf` → `qlmanage -t -s 256 -o`（白底渲染保留白图）→ 重命名入库。

- [ ] **Step 1: 转换脚本 + 产出**（脚本一次性工具，跑完产物入库，脚本本身也入库备资产更新）
- [ ] **Step 2: L10n.ets**——三个 map 从 rawfile 读（启动一次 fs.readText 解析）+ `L10n.get` 查当前语言表，缺键回退 en 再回退 key；`notify()` 经 AppStorage 键 `l10n.rev` 自增触发依赖方重算
- [ ] **Step 3: 编译验证**（L10n 经后续任务接线；本任务挂接 Index 临时引用验证后还原）
- [ ] **Step 4: Commit** `feat(assets): 92 动物图标与三语查表落地`

---

### Task 2: 设计 token 层 + 主题响应式接线

**Files:**
- Create: `entry/src/main/ets/components/DesignTokens.ets`
- Modify: `entry/src/main/ets/store/ThemeManager.ets`（补 ArkUI 响应式出口，改动收敛在文件尾）

**Interfaces:**
- Consumes: T7 `ThemeManager`（accent/success/derive 五方法已在）。
- Produces: `DesignTokens` 静态类：`pageBg(dark)`/`cardBg(dark)`/`hairline(dark)`（0.5pt 发丝线）/`textPrimary|Secondary|Tertiary(dark)`/`mono(caption)` 字号常量/`grid8`；`ThemeReactive.accentHex: string`（AppStorageV2 链接，accent 变更全 UI 重组）。

**直译源对照**：色值对齐 Android `ui/theme/PlanetTheme.kt:129-134` 注释的 M3 槽位映射表（浅 0xFFF2F2F7/深 0xFF1C1C1E 页面底；0xFFFFFFFF/0xFF2C2C2E 卡片底）。字号/圆角/阴影照 iOS DESIGN.md（代码实况版）。

- [ ] **Step 1: DesignTokens.ets**（纯静态常量 + dark 判定走 `@ohos.app.ability.ConfigurationConstant` 或 AppStorage 的 colorMode）
- [ ] **Step 2: ThemeManager 接线**——`applyPrefs` 后写 AppStorage `theme.accent`，UI 侧 `@StorageProp('theme.accent')` 消费（换色即时生效，对齐 Android `collectAsState` 重组）
- [ ] **Step 3: 编译验证 + Commit** `feat(ui): 设计 token 层与主题响应式接线`

---

### Task 3: QRTransfer 纯逻辑直译 + 金标向量

**Files:**
- Create: `entry/src/main/ets/qrtransfer/{Base45,CRC32,Deflate,QRFrame,ChunkPlanner,PayloadContainer,QRTransfer}.ets`
- Create: `entry/src/main/ets/qrtransfer/tests/{codec.test.mjs,frame.test.mjs,golden.mjs}`（node，不进 hvigor 图）
- Create: `ohos-package 配置`：`oh-package.json5` 增 pako 依赖（`ohpm install`）

**Interfaces:**
- Produces: `QRTransfer.encode(data: Uint8Array, maxModules?: number, maxFrames?: number): string[]`；`QRTransfer.parse(text: string): QRFrame | null`；`QRTransfer.decode(frames: QRFrame[]): Uint8Array | null`（齐全+CRC 一致才过）；`PayloadContainer.encode(entries)/parse(data)`；`QRFrame { total, index, crc32, payload }`。
- 帧格式硬契约（D12）：`ZTQR1|total(2位)|index(2位,1起)|crc32(8位hex)|len(5位,Base45全长)|chunk`，头长 27 字符；maxFrames 32、模块硬顶 v25=117 / 下限 v9=53；Deflate = 4 字节小端原始长度 + zlib raw deflate（pako `deflateRaw`/`inflateRaw`）；Base45 RFC 9285 字母表（不含 `|`）；CRC32 IEEE 反射 0xEDB88320 查表；ChunkPlanner 二分探测 probePrefix `"ZTQR1|99|99|ffffffff|00000|"` + 'z' 填充。

**直译源对照**：iOS `Modules/QRTransfer/Sources/`（Base45.swift:5-59 / CRC32.swift:4-22 / Deflate.swift:6-44 / QRFrame.swift:3-13 / ChunkPlanner.swift:7-31 / PayloadContainer.swift:7-51 / QRTransfer.swift:5-82）逐文件直译；金标向量直译 iOS `Tests/QRTransferCodecTests.swift` + `QRTransferFrameTests.swift` 全部用例（含跨端边界：单字节/空载荷/多帧补 '0' 对齐/未知 ZTP key 跳过/重复 key 取后值）。

**pako 选型依据**：MIT、纯 JS 无依赖、deflateRaw 字节兼容 Android zlib raw 已验证的模式；ohpm 上 `pako` 为社区标准包。若 ohpm 解析失败，降级方案：vendor pako 的 deflateRaw/inflateRaw 单文件进 qrtransfer/vendor/（保留版权头）。

- [ ] **Step 1: 先写金标向量测试**（golden.mjs 载 iOS 测试数据；node 跑红）
- [ ] **Step 2: 七文件直译**（ArkTS 语法适配：Uint8Array 承载 Data；静态函数导出）
- [ ] **Step 3: node 跑绿**——`node --test entry/src/main/ets/qrtransfer/tests/`（.mjs import .ets 不行——**注意**：测试 import 的是逻辑同构副本。方案：qrtransfer 逻辑写成「无 ArkTS 特性」的纯 TS（无装饰器无 import ohos），经 esbuild/tsc 旁路转 .mjs 供 node 测，.ets 文件本体 `export` 同内容。实现者落位：每文件顶部注释「与 tests/ 同构镜像，改一处必须同步另一处」，并写 scripts/qr-mirror-check.sh（sed 去 .ets 后缀 import 对比）保证镜像一致）
- [ ] **Step 4: 全量编译验证（qrtransfer 经 T5 路由或临时挂接）**
- [ ] **Step 5: Commit** `feat(qrtransfer): ZTQR1/ZTP 编解码直译与金标向量全绿`

---

### Task 4: 二维码渲染 + 分享/接收 UI + 扫码

**Files:**
- Create: `entry/src/main/ets/qrtransfer/{QRRender,QRShareSheet,QRReceiveSheet,ShardGrid,AlbumQrPicker,QrScannerSheet}.ets`
- Modify: `entry/src/main/module.json5`（requestPermissions 增 `ohos.permission.CAMERA`）

**Interfaces:**
- Consumes: T3 QRTransfer 全 API。
- Produces: `QRRender.render(text, sizePx): Promise<PixelMap>`（@kit.ScanKit `generateBarcode`，纠错 M 等价项按 SDK 枚举就近映射）；`QRRender.moduleCount(text): Promise<number>`（生成后测 PixelMap 尺寸反推，供 ChunkPlanner fits 探测——ScanKit 无「仅探测」API，以生成代替探测，ChunkPlanner 二分次数 ≤5 可接受）；`QRShareSheet`（props: payload Uint8Array；单帧静态 / 多帧四档速度 0.3/0.5/0.8/1.2s 自动轮播 + 手动点跳；二维码边长 = 屏宽 72%）；`QRReceiveSheet`（连续 parse 聚合 + 会话切换清空 + 底部状态栏）；`ShardGrid`（方块 30×22vp 圆角 6 间距 6，三态 current=accent 实底/received=accent 0.35/missing=cardBg+描边，块内分片号 mono 10）；`QrScannerSheet`（ScanKit 相机扫码 + 相册图片识别，识别到 `ZTQR1|` 前缀或 URL/文件 scheme 即回调）。

**直译源对照**：iOS `Modules/QRTransfer/Sources/Views/`（QRShareView 130 行/QRReceiveView 181 行/ShardGridView 102 行/AlbumQRPicker 82 行）+ `ContinuousScanner.swift`；Android `qrtransfer/ShardGrid.kt`（三态色值）与 `home/QrScannerSheet.kt`（扫码 sheet 宿主形态）。ZTP KV 扫码预填身份表单的 App 层 key 约定：1=planet 二进制(必备)/2=名称/3=图标 key/4=底色 hex（iOS PlanetPayload.swift:5-9）。

- [ ] **Step 1: QRRender 封装 + moduleCount 反推验证**（生成 'ZTQR1|01|01|...' 最小帧测得模块数，与公式 17+4v 互验）
- [ ] **Step 2: ShardGrid + QRShareSheet**（轮播 setInterval 清理于 aboutToDisappear）
- [ ] **Step 3: QRReceiveSheet + QrScannerSheet**（ScanKit `scanBarcode` 相机流；相册 PhotoViewPicker 选图 → ScanKit 图像识别，多选串行限流对齐 Android AlbumQr.kt）
- [ ] **Step 4: 编译验证 + Commit** `feat(qrtransfer): 二维码渲染分享接收与扫码 UI`

---

### Task 5: AppRoot 路由壳 + AppState + 7 页骨架

**Files:**
- Create: `entry/src/main/ets/ui/{AppRoot,AppState}.ets`
- Create: `entry/src/main/ets/pages/{HomeView,NetworkDetailView,PrefsView,PlanetSettingsView,PeerListView,MoonView,AddPlanetPage}.ets`（骨架：空页 + 标题 + 返回，内容后续任务填）
- Modify: `entry/src/main/ets/pages/Index.ets`（改为 AppRoot 宿主）
- Modify: `entry/src/main/ets/entryability/EntryAbility.ets`（接线 AppState.init）

**Interfaces:**
- Consumes: T11 StatusStore.subscribe、TunnelController 门面；T1 L10n。
- Produces: `Page` 寻的枚举 `{ kind: 'home' } | { kind: 'networkDetail', networkId: string } | { kind: 'prefs' } | { kind: 'planetSettings', planetId: string } | { kind: 'peers', planetId: string } | { kind: 'moon', planetId: string } | { kind: 'applyTrace', planetId: string } | { kind: 'addPlanet' }`（Android AppRoot.kt:22 sealed interface 直译）；`AppRoot` 组件持 `@Trace stack: Page[]`（push/pop/backHander 语义）；`AppState`（iOS AppState.swift 直译，@ObservedV2）：`planets/activePlanetId/vpnRunning/online/pathSatisfied` 派生自 StatusStore 订阅。

**直译源对照**：Android `ui/AppRoot.kt`（单 Activity 手写栈、when(page) 全屏渲染、BackHandler pop）；iOS `AppState.swift`（字段与派生语义）。页面转场：push 用 iOS navigation push 等价（右侧滑入 300ms 曲线 friction）自绘 transition；返回手势暂以系统返回键为准（侧滑返回 ArkUI 默认关闭自绘页——由 onPageHide/backpress 事件 pop）。

- [ ] **Step 1: AppState**（StatusStore.subscribe → @Trace 字段刷新；隧道态→vpnRunning/online 派生对齐 iOS）
- [ ] **Step 2: AppRoot + 7 页骨架**（每页空壳：自绘标题栏 + 返回箭头 + 内容占位）
- [ ] **Step 3: Index.ets 改宿主 + EntryAbility 接线**
- [ ] **Step 4: 全量编译（7 页天然在图内）+ Commit** `feat(ui): 路由壳与七页骨架`

---

### Task 6: 首页骨架——Swiper 分页 + 头区 + 视差背景 + FAB

**Files:**
- Create: `entry/src/main/ets/components/{HomeMetrics,HomeParallaxBackground,FabButton}.ets`
- Modify: `entry/src/main/ets/pages/HomeView.ets`（骨架填充）

**Interfaces:**
- Consumes: T5 AppState/Page；T2 DesignTokens/ThemeReactive；T1 L10n/PlanetIcon。
- Produces: `HomeMetrics.pageTopPadding = 88`；`FabButton`（56×56 accent 圆形 + 白 plus；PanGesture 跟手拖动 + 左右 spring 吸附（侧距 22/底距 54/上限 88）+ 位置持久化 AppStorage 键 `HomeView.fab.x/y`；拖动缩放 0.95）；`HomeParallaxBackground`（背景图 Image 出血 1.12 + translationX/Y = 归一化重力 ×20vp；蒙纱浅 0.4/深 0.78；@ohos.sensor gravity 30Hz 低通 α=0.1 归一化除 GRAVITY_EARTH，x 取负；无传感器静止；aboutToDisappear 注销）。

**直译源对照**（含三时机落地）：
- 分页容器：iOS HomeView.swift:80-108 层级（TabView.page → overlay header → background 视差 → overlay FAB → overlay 弹窗）→ ArkUI `Swiper{ planetPage×N + addPage }.cachedCount(N)`（全保活）+ `.onAnimationEnd`（落位提交选中 planetId——settledPage 语义）+ `.onChange`（过半驱动 chip 过渡动画——currentPage 语义）；`.indicator(false)` 自绘圆点（选中 20×6 胶囊/未选 6×6、间距 7、44vp 热区、spring 0.3/0.8——iOS HomeView.swift:312-336）。
- 头区 headerZone：iOS HomeView.swift:196-283——左 Logo 40×40 圆角 9；右列：`Planet Port` 22 bold + 活跃行星 chip（`vpnRunning && pagerSelection != activePlanetId` 才显；🔗 2/3 + 名称 14.3 semibold、Capsule、0.5pt 描边；点击逐页接力 0.1s/页 + flyFromPlanetCard 转场下 10pt 淡入上移 spring 0.45/0.85）+ 齿轮 36×36；背景全透明 + 三段渐变 mask（0/0.85/1）；内边距 h20/top6/bottom12。
- 视差：iOS HomeParallaxBackground.swift:9-85 + Android HomeParallaxBackground.kt（传感器实现范式）。
- FAB：iOS FabButton.swift + Android FabButton.kt（拖动/吸附/持久化范式）。
- 单行星页 planetPage：iOS HomeView.swift:342-383——pageTopPadding 88 → 身份卡（h20/bottom24，内容 T7 填）→ 0.5pt 分隔线 + 计数行（`网络 · N` footnote semibold secondary；活跃+运行时追加 ` · 连接中 X | 已连接 Y`，0 桶隐藏——HomeView.swift:415-434）→ Scroll（卡距 12/top12/bottom 148 预留）。
- 添加页末位：`Page kind addPlanet` 或 Swiper 末位 placeholder（点击进 AddPlanetPage——iOS 是 TabView 末位 tag `__add__` 整页，**鸿蒙采用 Swiper 末位独立页**对齐 iOS）。

- [ ] **Step 1: HomeMetrics + HomeParallaxBackground**
- [ ] **Step 2: FabButton**（手势 + 吸附 + 持久化）
- [ ] **Step 3: HomeView 骨架**（Swiper 三时机 + 头区 + 圆点 + 单行星页布局 + 末位添加页占位；身份卡/网络卡内容留 T7 插槽）
- [ ] **Step 4: 编译 + Commit** `feat(ui): 首页分页骨架与视差背景 FAB`

---

### Task 7: 行星卡 + 网络卡（状态机）+ CopyableValue + 身份卡

**Files:**
- Create: `entry/src/main/ets/components/{PlanetCardView,NetworkCardView,CopyableValue,PlanetIcon}.ets`
- Modify: `entry/src/main/ets/pages/HomeView.ets`（插槽填充）

**Interfaces:**
- Consumes: T6 首页插槽；T2 tokens；T1 PlanetIcon 资产；StatusStore 快照（networkStatuses/networkConfigs）。
- Produces: `PlanetIcon`（`view(key, tintHex, size)`：92 键 catalog + djb2 名称回退（seed 5381 乘 33 %1_000_003）+ tints djb2(id) 底色回退 + HSL 随机色 sat 0.45-0.85/light 0.32-0.55 + Color(hex) 解析）；`NetworkCardView`（props: networkId；内部从 StatusStore 取态）；`NetworkCardStatus` 状态机（输入 networkStatus/appState → { text, color, dotColor }）；`CopyableValue`（值 + copy 可选；热区外扩 5；@ohos.pasteboard 写入 + 对勾 0.8s 反馈；占位 "—"/"-" 不可复制）。

**直译源对照**：
- PlanetIcon：iOS PlanetIcon.swift 全文件（catalog 数组 :10-23 / djb2 :101-105 / 底色 :38-42 / 随机色 :60-64 / hex :108-117）。
- 网络卡形态：iOS NetworkCardView.swift:106-171——名称 15 semibold（空回退 ID）；ID caption mono tertiary；状态行 6pt 点 + caption 文本 + IP（caption2 mono tertiary，前 2 个双空格分隔）+ 9pt 复制图标；右侧 44 宽 Toggle/pending 转圈；最右 chevron semibold tertiary；padding 14 圆角 14。
- **状态机全量直译**（iOS NetworkCardView.swift:8-83，36 项清单 #13/#14/#15/#17 的卡片侧）：非活跃行星→「未连接」secondary；冲突（address/subnet/timeout）→红；未激活有 lastConflict→红；!vpnRunning→「建立隧道」orange；!pathSatisfied→「无网络」orange；待授权→orange；REQUESTING_CONFIGURATION 按 online 分段（「连接服务器」/「请求网络配置」）orange；ok→success 其余 orange；兜底「等待节点」secondary。文案键走 L10n（status.* 前缀）。
- Toggle 开关即连接（#14）：开关 on → AppConfigStore.upsertNetwork（active=true）+ fireConfig；off → active=false + fireConfig；pending 态由快照回流驱动。
- IP 点击复制 + 图标 7→9pt 放大 25%（NetworkCardView.swift:190-206）。
- 身份卡（PlanetCardView）：iOS PlanetCardView.swift——行星图标（32×32 tint 底圆角 + 白图标）+ 名称 20 semibold + 节点 ID caption mono（CopyableValue）+ 角标（使用中/上次使用/连接中——#34）。

- [ ] **Step 1: PlanetIcon + PlanetCardView**
- [ ] **Step 2: NetworkCardStatus 状态机 + NetworkCardView**（状态机纯函数可 node 镜像自测——同 T3 模式，可选）
- [ ] **Step 3: CopyableValue + HomeView 插槽填充**
- [ ] **Step 4: 编译 + Commit** `feat(ui): 行星卡网络卡状态机与复制组件`

---

### Task 8: 添加行星页 + 导入四通道 + ZTP 预填

**Files:**
- Create: `entry/src/main/ets/pages/AddPlanetPage.ets`（含 AddPlanetForm 区块）
- Modify: `entry/src/main/ets/qrtransfer/`（QrScannerSheet 回调接线）

**Interfaces:**
- Consumes: T3 PayloadContainer/QRTransfer；T4 QrScannerSheet；T1 L10n；AppConfigStore（importPlanet 挂账：store 层已有 importPlanet？——**无**，A4 范围未含。本任务在 AddPlanetForm 内实现导入编排：写 planet 文件 + planets.json upsert + 双查重）。
- Produces: `AddPlanetPage`（身份预览区 + 表单：名称/图标/底色 + 导入按钮组）；导入四通道：①文件（DocumentViewPicker → planet 二进制解析 → 预填）②URL（@ohos.net.http 下载 + 进度模态 180 高 [Content-Length 时 linear 进度/否则转圈] + interactiveDismissDisabled + 失败 toast 顶部 Capsule black0.75 白字 2.5s）③动态二维码（QrScannerSheet 分片聚合 → decode → PayloadContainer.parse → key1 planet/key2 名称/key3 图标/key4 底色预填——#6 ZTP KV 容器）④扫码链接（http(s) URL → 走 ② 通道）；双查重（World ID + 节点 ID——#8：identity.secret 解节点地址 vs 既有行星）。

**直译源对照**：iOS AddPlanetPage.swift（151 行）+ AddPlanetForm.swift（331 行，进度模态 :81-100 / toast :48-61 / alert :72）+ PlanetPayload.swift:5-9（ZTP key 约定）+ PlanetImporter.swift（四通道编排与查重顺序）。planet 二进制格式解析：对齐 iOS PlanetImporter 的字节布局读取（worldId/节点身份段）。

- [ ] **Step 1: planet 二进制解析 + 双查重逻辑**（纯逻辑，与 UI 分离）
- [ ] **Step 2: 表单 + 四通道接线 + 进度模态 + toast**
- [ ] **Step 3: 编译 + Commit** `feat(ui): 添加行星页与导入四通道`

---

### Task 9: JoinNetworkSheet + 网络详情页 + 删除锚定气泡

**Files:**
- Create: `entry/src/main/ets/components/{JoinNetworkSheet,ConfirmBubble,AppAlert}.ets`
- Create: `entry/src/main/ets/pages/NetworkDetailView.ets`

**Interfaces:**
- Consumes: T7 CopyableValue；T4 QrScannerSheet（扫码加入）；AppConfigStore networks 域。
- Produces: `JoinNetworkSheet`（半模态：16 位 hex ID 输入（大写转换/粘贴解析）+ 扫码按钮；重复加入 alert；确认 → networks upsert + fireConfig）；`ConfirmBubble`（**锚定气泡**——锚点行 onAreaChange 上报 y；盒高 max(60, anchorTop) bottom 对齐尾尖贴行卡顶边；宽 260/padding 16/圆角 20/backgroundBlurStyle Regular/阴影 0.18 r14 y5；尾尖三角 18×9 下探 9 自绘 Path；确认红字 semibold + quaternary Capsule；转场 opacity + scale 0.95 anchor bottom + 呼吸间距 10）；`AppAlert`（自绘 alert 群宿主：标题必须具体 + 双按钮；遮罩 black 0.35；卡片 maxWidth 300/padding 20/圆角 16/blur Regular/阴影 0.15 r12 y4/scale 0.95 转场）；`NetworkDetailView`（网络 ID/名称/状态/MAC/MTU/地址列表（托管 IP 编号标签 + CopyableValue）/路由列表（dest/prefix 编号标签、via 网关点击切换）/DNS 段（三模式 segmented）/默认路由开关（多网络强制关提示）/删除按钮 → ConfirmBubble——#19/#20/#21/#27/#34）。

**直译源对照**：iOS ConfirmBubble.swift（111 行全直译）+ HomeView.swift:600-621（dialogCard 视觉参数）+ JoinNetworkSheet.swift（100 行）+ NetworkDetailView.swift（341 行：地址/路由标签与点击切换语义）+ DNSConfigSection.swift（三模式 UI 形态）。DNS 三模式落库 → prefs/networks 域字段（AppConfigStore 已有模型字段对齐 Android NetworkEntry）；默认路由开关 + allow-lan 挖洞是 C++ 侧已有能力（RoutePlanner），UI 只落开关值。

- [ ] **Step 1: ConfirmBubble + AppAlert**（弹窗基建）
- [ ] **Step 2: JoinNetworkSheet**
- [ ] **Step 3: NetworkDetailView 全量**
- [ ] **Step 4: 编译 + Commit** `feat(ui): 网络详情页与加入网络锚定气泡弹窗基建`

---

### Task 10: PrefsView 全局设置页（含身份模式/主题/语言/背景图/关于）

**Files:**
- Create: `entry/src/main/ets/pages/PrefsView.ets`
- Create: `entry/src/main/ets/components/{IconPickerSheet,BackgroundImagePickerSheet}.ets`
- Create: `entry/src/main/ets/components/HSLColorPicker.ets`（自绘取色器）

**Interfaces:**
- Consumes: T2 ThemeReactive；T7 LanguageManager；AppConfigStore prefs 域 + IdentityStore；BackgroundImageStore（**新建**——背景图管理：PhotoViewPicker 选图 → 拷贝沙盒 `files/background.jpg` + 六条硬规则校验 ≥1290×2796/≤3MB；Android BackgroundImageStore 同构）。
- Produces: `PrefsView` 六段：①网络段（连接超时 45s 步进 5 / 软上限 2-6 可调——#16/#12）②身份模式段（共享/独立切换：确认 alert（互不可关联说明）→ prefs 落盘 → **`TunnelController.restartIfRunning()`**——终审挂账：身份模式/行星切换必须显式换代）③语言段（三语 + 跟随系统——#31，切换后 `L10n.notify()`）④主题段（8 预设国画色 swatch + 自定义 HSL 取色器 + 状态色派生开关 + 行星装饰盘开关——#29；双写：prefs 落盘 + ThemeManager.applyPrefs → AppStorage）⑤外观段（背景图选择/清除 + 视差开关——#30）⑥关于段（构建时间/代码版本——#35；商标保护校验 `if (false)` 隐藏不删）。

**直译源对照**：iOS PrefsView.swift（521 行：段结构与行形态）+ HSLColorPicker（:313 起自绘：色相环/饱和度明度双滑杆）+ IconPickerSheet.swift（图标网格 4 列磁贴 48×48 圆角 12 选中 26——**本页不直接用，归 PlanetSettings 但同文件范式，组件一并建**）+ BackgroundImagePickerSheet.swift。背景图六规则文案在 DESIGN.md:83-94。构建信息：BuildInfo.swift 直译（构建时间戳注入——hvigor 无 RunScript 注入惯例则用 `buildProfile` 自定义参数或静态占位 + A6 CI 注入，本任务先静态可显示）。

- [ ] **Step 1: BackgroundImageStore + BackgroundImagePickerSheet**
- [ ] **Step 2: HSLColorPicker + 主题段**
- [ ] **Step 3: 六段全量 + restartIfRunning 接线**
- [ ] **Step 4: 编译 + Commit** `feat(ui): 全局设置页与主题取色器背景图管理`

---

### Task 11: PlanetSettings + Peers + Moon + ApplyTrace 诊断

**Files:**
- Create: `entry/src/main/ets/pages/{PlanetSettingsView,PeerListView,MoonView}.ets`
- Create: `entry/src/main/ets/pages/ApplyTraceView.ets`（或 components——对齐 Android diag/ 归 pages）

**Interfaces:**
- Consumes: T7 PlanetIcon/CopyableValue；T9 ConfirmBubble；T1 L10n；StatusStore（peers/eventLog/applyTrace）。
- Produces:
  - `PlanetSettingsView`（#10/#25/#34：名称编辑/图标选择（IconPickerSheet 92 格 + 24 色板）/只读信息（worldId/节点 ID/身份模式）/分享按钮 → QRShareSheet（planet 二进制 + 名称 + 图标 + 底色 ZTP 封装）/Peers·Moon·Trace 三个 push 入口（仅活跃行星可用）/删除 → ConfirmBubble → 停隧道（若活跃）+ store 删除 + `restartIfRunning`）
  - `PeerListView`（#24：行 = 地址 body mono + 角色 Capsule（accent 0.12 底）+ v 版本 caption + 延迟（6pt 点语义色 + caption semibold：**<30ms success/<100ms orange/≥100ms red**）+ paths 空时橙色「中转 relay」胶囊（orange 0.12）否则 path caption mono tertiary——**paths 恒空是已知事实（T8 恒账），relay 胶囊将恒显，属预期**；三态空态卡：查询中/隧道未运行/空列表）
  - `MoonView`（#25：行 = 32×32 accent 底圆角 10 白 moon 图标 + worldId body mono + `seed 0x…` caption（仅手动添加）+ 缓存徽标 Capsule（已缓存 success 0.12/未缓存 secondary，文件导入附 doc 图标）；SwipeGesture 左滑删除 + 长按菜单（删除/复制地址/删缓存）；添加 = 手动 worldId/seed 表单 + 文件导入）
  - `ApplyTraceView`（#26：出入站流量/ARP 问答/无路由丢弃计数 + eventLog 40 条滚动列表——快照 eventLog 字段透传）

**直译源对照**：iOS PlanetSettingsView.swift（352 行）/ PeerListView.swift（153 行：行字段与三态 :41-74、延迟色 :139-143、relay :104-115）/ MoonView.swift（249 行：行 :113-158、swipe :27-33、contextMenu :34-52）/ ApplyTraceView.swift（40 行）；Android MoonView.kt（SwipeToDismissBox 范式 → ArkUI List 的 swipeAction）。

- [ ] **Step 1: PlanetSettingsView + IconPickerSheet 接线 + 分享（ZTP 封装走 T3 PayloadContainer）**
- [ ] **Step 2: PeerListView**（延迟色/relay 胶囊/三态空态）
- [ ] **Step 3: MoonView + ApplyTraceView**
- [ ] **Step 4: 编译 + Commit** `feat(ui): 行星设置 Peers Moon 与诊断页`

---

### Task 12: 跨行星切换弹窗 + alert 群收口 + 集成回归

**Files:**
- Modify: `entry/src/main/ets/pages/HomeView.ets`（切换弹窗宿主 + alert 群）
- Modify: `entry/src/main/ets/ui/AppState.ets`（切换编排）
- Create: 无新文件（弹窗在 T9 AppAlert 基建上落）

**Interfaces:**
- Consumes: T9 AppAlert；TunnelController（stop 双保险/ensureStarted）；AppConfigStore activatePlanet。
- Produces: **跨行星切换确认双阶段弹窗**（#10 核心交互——`SwitchPlanetPhase confirm → disconnecting`：确认阶段 headline 标题 + footnote markdown 加粗说明 + footer 全出血双按钮（取消 secondary/确认 accent semibold，0.5pt 竖分隔线，minHeight 44）；断开阶段大转圈 + subheadline 文案；编排 `confirmSwitchPlanet`：`TunnelController.stop()` await → 关弹窗 0.15s → 100ms 停顿 → activatePlanet + `TunnelController.ensureStarted()`）；**alert 群收口**（网络状态异常/并发软上限确认放行/加入重复/导入失败/身份模式确认——各页已有零散 alert 统一 AppAlert 形态）；**开 App 自动恢复**（#28：EntryAbility onCreate 若曾有活跃行星 + 停机非用户主动 → ensureStarted——prefs.autoRestore 键）。

**直译源对照**：iOS HomeView.swift:13-23（SwitchPlanetPhase）+ :516-531（confirmSwitchPlanet 编排）+ :533-621（弹窗视觉）；alert 群：HomeView.swift:124-162（网络状态异常/软上限/权限限流 2h——**鸿蒙无无线数据权限检查，该项降级不实现， CellularPermissionChecker 留平台差异**）。

- [ ] **Step 1: 切换双阶段弹窗 + 编排**
- [ ] **Step 2: alert 群收口 + 自动恢复**
- [ ] **Step 3: 集成回归**——①全量编译 0 error（`N executed, 0 up-to-date`）②node QRTransfer 金标向量仍绿 ③host ctest 143/143 不受影响（native 未动的证明）④三语表完整性校验（脚本对比 356+20 键三语无缺）⑤36 项清单 UI 侧逐项 grep 标记覆盖（输出清单到 report）
- [ ] **Step 4: Commit** `feat(ui): 跨行星切换弹窗与 A5 集成回归收口`

---

## Self-Review

**1. Spec 覆盖（36 项 → 任务映射）**
- A 行星管理 10 项：#1 planets 模型（A4 已有）/#2 文件导入 T8/#3 URL 导入 T8/#4 二维码分片 T3+T4/#5 扫码 T4/#6 ZTP KV T3+T8/#7 分享 T4+T11/#8 双查重 T8/#9 planet-state 隔离（A3 已有）/#10 切换确认流 T12 ✓
- B 身份 1 项：#11 模式切换 T10（restartIfRunning 挂账收口）✓
- C 网络连接 8 项：#12 软上限 T10/#13 冲突断开+卡片原因 T7（状态机）/（冲突自动断开数据面 A2 已有）/#14 开关即连接 T7/#15 阶段文案 T7/#16 超时可配 T10/#17 无网络即时 T7（pathSatisfied）/#18 加入 T9/#19 复制+二维码 T7+T4 ✓
- D 路由 DNS 4 项：#20 默认路由开关 T9（数学 A2 RoutePlanner 已有）/#21 DNS 三模式 T9/#22 热重配（A3 D3 已有，UI 入口 T9 开关落库即触发）/#23 IPv6 T10 prefs ✓
- E Peers/Moon/诊断/详情 4 项：#24 T11/#25 T11/#26 T11/#27 T9 ✓
- F 体验 9 项：#28 T12（切网自愈 A3 D9 已有；自动恢复 T12）/#29 T2+T10/#30 T6+T10/#31 T1+T10/#32 T1+T7（PlanetIcon）/#33 T6/#34 T7+T9+T11/#35 T10（if false 隐藏）/#36 单 VPN 互斥（A3 已有 2203002 处理 + UI 状态回流 T7 状态机）✓
- G 3 项降级文案：#1 On Demand 降级/#2 开机自启降级/#3 单 VPN 互斥说明——三语文案表 T1 落键，UI 提示位 T10 关于段/T7 状态机 ✓
- **缺口检查**：#12「超上限确认放行」在 T10 软上限设置 + JoinNetworkSheet 触发时 alert——T9 与 T10 交叉，实现时 alert 放 JoinNetworkSheet（T9 范围补一句：加入时超软上限 → AppAlert 确认放行）。已并入 T9 步骤描述。

**2. 占位符扫描**：无 TBD/TODO；「静态占位 + A6 CI 注入」（T10 构建时间）与「降级不实现」（T12 蜂窝权限）均为明确决策非拖延。

**3. 类型一致性**：`Page` 枚举 T5 定义与 T6-T12 push 调用一致；`L10n.get` 全 UI 统一；`ThemeReactive.accentHex` 经 AppStorage 键 `theme.accent`（T2 定义、T6/T7/T9/T10/T11 消费）；QRTransfer API 签名 T3 定义与 T4/T8/T11 消费一致；`restartIfRunning` 调用点 T10（身份模式）/T11（行星删除与切换）——**T11 行星切换实为 T12 弹窗编排，删除场景在 T11** ✓

**执行顺序**（依赖驱动，支持波次并行）：T1 → T2 → {T3, T5} → T4 → T6 → T7 → {T8, T9, T10} → T11 → T12。T3 与 T5 无依赖可并行；T8/T9/T10 三页在 T7 后可并行（文件不相交；AppAlert 基建在 T9——T8/T10 的 alert 需求若先行，把 AppAlert 提前到并行波次首日或 T8/T10 暂用内联简版、T9 统一收口——**裁决：AppAlert/ConfirmBubble 归 T9 先行实现，T8/T10 依赖之，故实际波次：T7 → T9 → {T8, T10} → T11 → T12**）。
