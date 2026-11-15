// PlanetSettingsView.ets — 行星设置页（iOS PlanetSettingsView.swift 全文直译）
//
// 四区 Form → 卡片列直译：名称与图标（官方只读）→ 只读信息（World ID/Node ID/
// 类型/文件大小/修订时间/分享）→ 诊断入口（Peers/Moon/Trace）→ 删除（仅自定义，
// 锚定确认气泡）。删除编排红线（控制器裁决）：删除 → ConfirmBubble → 停隧道
// （若活跃行星）→ store 级联删除 → restartIfRunning() 显式换代——正常停机收口
// 后 isRunning=false 该调用为 no-op（对齐 iOS stopAndWait 停机语义），兜住
// awaitSettled 超时隧道仍活的残余窗口，绝不静默跑在已删除行星上。
//
// 平台差异（详见任务报告）：
//   ① harmony PlanetImporter 无 rename/updateIcon（store/ 领地禁改）——两操作
//      在页面内联实现（readPlanets → 改字段 → writePlanets，writePlanets 发
//      planetsChanged → AppState.reload → 本页订阅跟进刷新）。
//   ② 分享行仅保留二维码通道（系统文件分享面 @kit.ShareKit 在 OpenHarmony
//      SDK 缺位，iOS ActivityShareSheet 通道降级不落码）。
//   ③ 诊断三入口按控制器裁决统一「仅活跃行星可用」（iOS 仅 Peers 行 disabled）。
//   ④ World ID/Node ID 值来源：官方行星 World ID 取 ZT_WORLD_ID_EARTH 常量
//      种子（iOS app.planetWorldIds 同语义）；Node ID 实时值只对活跃行星显示
//      （快照回填），其余行星回退身份文件缓存（IdentityStore.planetNodeIds）。
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { AppNav, PagePeers, PageMoon, PageApplyTrace } from '../ui/AppRoot';
import { AppState } from '../ui/AppState';
import { StoreRepo } from '../store/StoreRepo';
import { PlanetProfile, PlanetKind } from '../store/Models';
import { LanguageManager } from '../store/LanguageManager';
import { PlanetImporter, hex16FromNumber, ZT_WORLD_ID_EARTH } from '../store/PlanetImporter';
import { IdentityStore } from '../store/IdentityStore';
import { TunnelController } from '../tunnel/TunnelController';
import { StatusStore } from '../tunnel/StatusStore';
import { TunnelSnapshot } from '../common/TunnelContract';
import { PlanetIcon } from '../components/PlanetIcon';
import { IconPickerSheet } from '../components/IconPickerSheet';
import { ConfirmBubble } from '../components/ConfirmBubble';
import { CopyableValue } from '../components/CopyableValue';
import { QRShareSheet } from '../qrtransfer/QRShareSheet';
import { PayloadContainer, PayloadField } from '../qrtransfer/PayloadContainer';
import { ThemeManager, themeSignal, ThemeSignal } from '../store/ThemeManager';
import { DesignTokens, colorModeSignal, ColorModeSignal } from '../components/DesignTokens';
import { L10n, l10nSignal } from '../components/L10n';
import { AppAlert, AppAlertButton } from '../components/AppAlert';

/** 表单字号（iOS .body 17 / .footnote 13 / .caption2 11） */
const FS_BODY: number = 17;
const FS_FOOTNOTE: number = 13;
const FS_SECTION_HEADER: number = 11;
/** 表单行高（iOS Form 行标准 44pt）与区间距/页边距（NetworkDetailView 同款） */
const ROW_HEIGHT: number = 44;
const FORM_MARGIN: number = DesignTokens.MARGIN_PAGE;
const FORM_SECTION_GAP: number = 20;
/** 图标行小磁贴（iOS 24×24 圆角 7 内 14 直译） */
const ICON_TILE: number = 24;
const ICON_TILE_RADIUS: number = 7;
const ICON_TILE_CONTENT: number = 14;
/** 分享行按钮图标（iOS .system(size: 11) 直译） */
const FS_SHARE_ICON: number = 11;
/** 诊断行符号（iOS Label systemImage 17pt 同族实名核验见任务报告） */
const FS_ROW_ICON: number = 17;
/** 气泡转场（iOS .opacity + .scale(0.95, anchor: .bottom) + easeOut 0.15 直译） */
const BUBBLE_TRANSITION: TransitionEffect = TransitionEffect.OPACITY
  .combine(TransitionEffect.scale({ x: 0.95, y: 0.95, centerX: '50%', centerY: '100%' }))
  .animation({ duration: 150, curve: Curve.EaseOut });
/** 诊断入口禁用态整体透明度（iOS .disabled 自动置灰近似） */
const DISABLED_OPACITY: number = 0.35;
/** ZTP KV 容器 key 约定（iOS PlanetPayload.swift 直译，与 PlanetImporter 同表） */
const KEY_PLANET: number = 1;
const KEY_NAME: number = 2;
const KEY_ICON: number = 3;
const KEY_ICON_COLOR: number = 4;

/** 文件大小分级项（iOS locFileSize units 直译，十进制 KB=1000） */
interface FileSizeUnit {
  factor: number;
  unit: string;
}

@ComponentV2
export struct PlanetSettingsView {
  @Param planetId: string = '';

  /** 全局 UI 状态（activePlanetId/vpnRunning 触踪——诊断入口门控依赖） */
  @Local app: AppState = AppState.shared;
  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;
  @Local theme: ThemeSignal = themeSignal;
  /** 归属行星（整实例替换触踪； planetsChanged/configChanged 订阅重读） */
  @Local planet: PlanetProfile | null = null;
  /** 名称草稿（仅自定义行星可编辑；iOS @State name 直译） */
  @Local name: string = '';
  /** 图标设置弹层 */
  @Local showIconPicker: boolean = false;
  /** 二维码分享弹层 + 已编码载荷 */
  @Local showQR: boolean = false;
  @Local qrPayload: Uint8Array = new Uint8Array(0);
  /** 删除锚定气泡 */
  @Local deleteAnchorY: number = 0;
  @Local layerTopY: number = 0;
  @Local showDeleteBubble: boolean = false;
  /** 错误提示（iOS .alert(common.notice) 直译） */
  @Local alertMsg: string = '';
  /** 主题派生域：行星色盘（图标磁贴底色） */
  @Local tints: number[] = [];
  /** 只读信息域（-1/0 = 不可解读时的占位哨兵） */
  @Local worldIdHex: string = '—';
  @Local fileSize: number = -1;
  @Local revisionMs: number = 0;
  /** 各行星身份文件缓存 nodeId（iOS app.planetNodeIds 直译） */
  @Local cachedNodeIds: Map<string, string> = new Map();

  private themeRef: ThemeManager | null = null;
  /** planet 文件只读解读（iOS 静态 inspectPlanetFile 的鸿蒙实例化对应物，
   *  AddPlanetPage 同款构造） */
  private importer: PlanetImporter = new PlanetImporter(StoreRepo.store);
  /** 名称草稿仅首载初始化一次（iOS onAppear 同语义） */
  private nameInited: boolean = false;
  /** 快照 Node ID 差分基准（'' = 离线/缺失；M-2 门控） */
  private lastSnapNodeId: string = '';
  private unsubPlanets: (() => void) | null = null;
  private unsubCfg: (() => void) | null = null;
  private unsubSnap: (() => void) | null = null;

  aboutToAppear(): void {
    this.unsubPlanets = StoreRepo.store.onPlanetsChanged(() => void this.reloadPlanet());
    this.unsubCfg = StoreRepo.store.onConfigChanged(() => void this.reloadPlanet());
    // 快照域轻量触踪：仅活跃行星 Node ID 实时值变化才回流触踪——快照 10s 兜底
    // 轮询每次重推都全表重读身份缓存无谓且整页重渲染，差分门控拦掉（M-2）
    this.unsubSnap = StatusStore.subscribe((s: TunnelSnapshot | null) => {
      const nid = s === null ? '' : s.nodeStatus?.nodeId ?? '';
      if (nid === this.lastSnapNodeId) {
        return;
      }
      this.lastSnapNodeId = nid;
      void this.refreshNodeIdCache();
    });
    void ThemeManager.shared().then((t: ThemeManager) => {
      this.themeRef = t;
      this.applyTheme();
    });
    void this.reloadPlanet();
  }

  aboutToDisappear(): void {
    if (this.unsubPlanets !== null) {
      this.unsubPlanets();
      this.unsubPlanets = null;
    }
    if (this.unsubCfg !== null) {
      this.unsubCfg();
      this.unsubCfg = null;
    }
    if (this.unsubSnap !== null) {
      this.unsubSnap();
      this.unsubSnap = null;
    }
  }

  /** 主题/深浅色变化 → 重算行星色盘（HomeView 同款派生） */
  @Monitor('theme.rev', 'cm.dark')
  applyTheme(): void {
    const t = this.themeRef;
    if (t === null) {
      return;
    }
    this.tints = t.planetTintsHex();
  }

  // ---- 数据域 ----

  /** 行星档案 + 只读信息域重读（跨入/信号共用） */
  private async reloadPlanet(): Promise<void> {
    const planets = this.app.planets;
    const found = planets.find((p: PlanetProfile): boolean => p.id === this.planetId);
    this.planet = found === undefined ? null : found;
    if (!this.nameInited && this.planet !== null) {
      this.name = this.planet.name; // iOS onAppear { name = planet?.name ?? "" } 直译
      this.nameInited = true;
    }
    await this.reloadPlanetFile();
    await this.refreshNodeIdCache();
  }

  /** 只读文件域：World ID/文件大小/修订时间（iOS inspectPlanetFile 段直译）。
   *  官方行星无 .planet 文件实体——World ID 取内置地球常量种子，其余 '—'。 */
  private async reloadPlanetFile(): Promise<void> {
    const p = this.planet;
    if (p === null) {
      this.worldIdHex = '—';
      this.fileSize = -1;
      this.revisionMs = 0;
      return;
    }
    if (p.kind === PlanetKind.Official) {
      this.worldIdHex = hex16FromNumber(ZT_WORLD_ID_EARTH);
      this.fileSize = -1;
      this.revisionMs = 0;
      return;
    }
    const info = await this.importer.inspectPlanetFile(p);
    if (info === null) {
      this.worldIdHex = '—';
      this.fileSize = -1;
      this.revisionMs = 0;
      return;
    }
    this.worldIdHex = info.worldIdHex;
    this.fileSize = info.fileSize;
    this.revisionMs = info.timestamp;
  }

  /** 身份文件缓存 nodeId 全表（iOS app.planetNodeIds 直译；快照回流触发重读） */
  private async refreshNodeIdCache(): Promise<void> {
    const store = StoreRepo.store;
    const prefs = await store.readPrefs();
    this.cachedNodeIds =
      await IdentityStore.planetNodeIds(store.paths, this.app.planets, prefs.identityPerPlanet);
  }

  /**
   * Node ID 展示值（iOS nodeIDText 直译）：活跃行星优先实时值（快照回填），
   * 其余/离线回退身份文件缓存，缺失 '—'。
   */
  private nodeIdText(): string {
    if (this.planetId === this.app.activePlanetId) {
      const snap = StatusStore.current();
      const node = snap === null ? null : snap.nodeStatus;
      if (node !== null && node.nodeId !== '') {
        return node.nodeId;
      }
    }
    return this.cachedNodeIds.get(this.planetId) ?? '—';
  }

  /** 有可读 .planet 文件（分享行显隐；iOS planetFileURL != nil 同语义） */
  private hasPlanetFile(): boolean {
    return this.planet !== null && this.planet.kind === PlanetKind.Custom
      && this.planet.fileName !== null && this.fileSize >= 0;
  }

  /** 行星展示名（官方走本地化名，HomeView.displayNameOf 同款） */
  private displayName(): string {
    const p = this.planet;
    if (p === null) {
      return this.loc('planet.title');
    }
    return p.id === PlanetProfile.OFFICIAL_ID ? this.loc('planet.official.name') : p.name;
  }

  private isOfficial(): boolean {
    return this.planet !== null && this.planet.kind === PlanetKind.Official;
  }

  /** 诊断三入口门控（控制器裁决：仅活跃行星可用） */
  private diagnosticsEnabled(): boolean {
    return this.planetId === this.app.activePlanetId;
  }

  // ---- 操作域 ----

  /**
   * 保存名称（iOS saveName 直译）：未变更直接返回；trim 空提示 emptyName；
   * 否则表内改名后 writePlanets（信号驱动本页与全局刷新）。
   */
  private async saveName(): Promise<void> {
    const p = this.planet;
    if (p === null || this.name === p.name) {
      return;
    }
    const normalized = this.name.trim();
    if (normalized === '') {
      this.alertMsg = this.loc('error.planet.emptyName'); // iOS ImportError.emptyName 同位
      return;
    }
    const profiles = await StoreRepo.store.readPlanets();
    const hit = profiles.find((q: PlanetProfile): boolean => q.id === p.id);
    if (hit === undefined) {
      return;
    }
    hit.name = normalized;
    await StoreRepo.store.writePlanets(profiles);
    void this.app.reload();
  }

  /**
   * 更新图标（iOS PlanetImporter.updateIcon 直译，页面内联——平台差异①）：
   * 图标/底色一并写入，writePlanets 发 planetsChanged 驱动刷新。
   */
  private async updateIcon(animal: string, colorHex: string): Promise<void> {
    const p = this.planet;
    if (p === null) {
      return;
    }
    try {
      const profiles = await StoreRepo.store.readPlanets();
      const hit = profiles.find((q: PlanetProfile): boolean => q.id === p.id);
      if (hit === undefined) {
        return;
      }
      hit.icon = animal;
      hit.iconColor = colorHex;
      await StoreRepo.store.writePlanets(profiles);
      void this.app.reload();
    } catch (e) {
      // iOS error.localizedDescription 同位：异常消息直显，非 Error 兜底通用标题
      this.alertMsg = e instanceof Error ? e.message : this.loc('common.notice');
    }
  }

  /**
   * 分享二维码（iOS shareQR 直译）：读 planet 文件 + 名称/图标/底色组成 ZTP
   * 容器进入分享弹层；读取失败（并发删除）静默不弹页。
   */
  private async shareQR(): Promise<void> {
    const p = this.planet;
    if (p === null || p.fileName === null) {
      return;
    }
    const bytes = await this.readPlanetBytes(
      `${StoreRepo.store.paths.planetsDir}/${p.fileName}`);
    if (bytes === null) {
      return;
    }
    const fields: PayloadField[] = [new PayloadField(KEY_PLANET, bytes)];
    if (p.name !== '') {
      fields.push(new PayloadField(KEY_NAME, utf8(p.name)));
    }
    if (p.icon !== null) {
      fields.push(new PayloadField(KEY_ICON, utf8(p.icon)));
    }
    if (p.iconColor !== null) {
      fields.push(new PayloadField(KEY_ICON_COLOR, utf8(p.iconColor)));
    }
    this.qrPayload = PayloadContainer.encode(fields);
    this.showQR = true;
  }

  /**
   * 删除行星（iOS deletePlanet 全序直译 + 控制裁决红线）：
   *   非活跃 → 直接级联删除；
   *   活跃 → ① 断开全部网络（lastActivated=false 写回触发隧道 diff 逐网 leave）
   *          ② 停用行星（TunnelController.stop = 优雅停机 + awaitSettled 收口 +
   *             进程停止双保险，stopAndWait 的鸿蒙对应物）
   *          ③ 级联删除配置（AppConfigStore.deletePlanet：网络/卫星/状态目录）
   *          ④ restartIfRunning() 显式换代（正常停机后为 no-op；兜底超时残余，
   *             见文件头删除编排红线注）。
   */
  private async deletePlanet(): Promise<void> {
    const p = this.planet;
    if (p === null) {
      return;
    }
    const store = StoreRepo.store;
    if (p.id !== this.app.activePlanetId) {
      await store.deletePlanet(p);
      await this.app.reload();
      AppNav.pop();
      return;
    }
    // 1. 断开所有网络
    const networks = await store.readNetworks(p.id);
    if (networks.some((n): boolean => n.lastActivated)) {
      for (const n of networks) {
        n.lastActivated = false;
      }
      await store.writeNetworks(networks, p.id);
      await this.app.reload();
    }
    // 2. 停用行星（等系统确认断开，给隧道留出处理 leave 的时间窗）
    await TunnelController.stop();
    // 3. 级联删除配置
    await store.deletePlanet(p);
    await this.app.reload();
    // 4. 显式换代（绝不静默）：跑在已删除行星上的残余隧道切回官方行星
    await TunnelController.restartIfRunning();
    AppNav.pop();
  }

  // ---- 工具 ----

  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  /** 沙盒整文件读（字节级）→ 恰长 Uint8Array；失败 null（PlanetImporter 同款） */
  private async readPlanetBytes(path: string): Promise<Uint8Array | null> {
    let fd = -1;
    try {
      const f = await fs.open(path, fs.OpenMode.READ_ONLY);
      fd = f.fd;
      const st = await fs.stat(fd);
      const size = st.size;
      if (size <= 0) {
        return null;
      }
      const ab = new ArrayBuffer(size);
      const n = await fs.read(fd, ab, { offset: 0, length: size });
      return new Uint8Array(ab.slice(0, n));
    } catch (_e) {
      return null;
    } finally {
      if (fd >= 0) {
        try { await fs.close(fd); } catch (_ignored) { /* 关闭失败不放大 */ }
      }
    }
  }

  /** 文件大小展示（iOS locFileSize 直译：十进制分级 %.1f，不足 1KB 显 B） */
  private fileSizeText(bytes: number): string {
    const units: FileSizeUnit[] = [
      { factor: 1000000000000, unit: 'TB' },
      { factor: 1000000000, unit: 'GB' },
      { factor: 1000000, unit: 'MB' },
      { factor: 1000, unit: 'KB' },
    ];
    for (const u of units) {
      if (bytes >= u.factor) {
        return (Math.round((bytes / u.factor) * 10) / 10).toFixed(1) + ' ' + u.unit;
      }
    }
    return `${bytes} B`;
  }

  /**
   * 修订时间（iOS timestampText 直译）：ZeroTier World 时间戳为毫秒；格式化器
   * 显式带应用语言（不走系统 locale 环境）；解析失败兜底 ISO 形态。
   */
  private timestampText(tsMs: number): string {
    if (tsMs <= 0) {
      return '—';
    }
    const date = new Date(tsMs);
    try {
      return new Intl.DateTimeFormat(LanguageManager.resolved() as string, {
        dateStyle: 'short',
        timeStyle: 'short',
      }).format(date);
    } catch (_e) {
      return date.toISOString();
    }
  }

  /** 有效图标底色 hex（iOS PlanetIcon.effectiveColorHex 直译）：自定义优先，
   *  回退按 id 哈希的当前色盘（IconPickerSheet 草稿初值用） */
  private effectiveColorHex(p: PlanetProfile): string | null {
    if (p.iconColor !== null) {
      return p.iconColor;
    }
    const tint = PlanetIcon.tintHex(p, this.tints);
    const r = (tint >> 16) & 0xFF;
    const g = (tint >> 8) & 0xFF;
    const b = tint & 0xFF;
    const hex2 = (v: number): string => v.toString(16).padStart(2, '0');
    return `#${hex2(r)}${hex2(g)}${hex2(b)}`;
  }

  // ---- 渲染 ----

  build() {
    Stack() {
      Column() {
        this.titleBar()
        Scroll() {
          Column({ space: FORM_SECTION_GAP }) {
            this.nameAndIconSection()
            this.infoSection()
            this.diagnosticsSection()
            if (!this.isOfficial()) {
              this.deleteSection()
            }
          }
          .width('100%')
          .padding({ top: 4, bottom: 40 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      // 图标设置 sheet（iOS .sheet(isPresented: $showIconPicker) 直译；SheetSize.LARGE
      // = iOS 全高 sheet。挂内层内容列，避免与根节点 QR sheet 同节点互覆）
      .bindSheet(this.showIconPicker, (): void => {
        this.iconPickerSheet()
      }, {
        height: SheetSize.LARGE,
        showClose: false,
        backgroundColor: DesignTokens.pageBg(this.cm.dark),
        onWillDismiss: (_action: DismissSheetAction): void => {
          this.showIconPicker = false;
        },
      })

      // 删除确认锚定气泡（iOS .overlay ZStack 直译）
      if (this.showDeleteBubble) {
        ConfirmBubble({
          anchorY: this.deleteAnchorY,
          layerTopY: this.layerTopY,
          titleKey: 'planet.delete.confirmTitle',
          messageKey: 'planet.delete.confirmMessage',
          confirmKey: 'planet.delete.confirmAction',
          onConfirm: (): void => {
            this.showDeleteBubble = false;
            void this.deletePlanet();
          },
          onDismiss: (): void => {
            this.showDeleteBubble = false;
          },
        })
          .transition(BUBBLE_TRANSITION)
      }

      // 错误提示（iOS .alert(common.notice) 直译）
      if (this.alertMsg !== '') {
        AppAlert({
          title: this.loc('common.notice'),
          message: this.alertMsg,
          buttons: [new AppAlertButton(this.loc('common.ok'), false, (): void => {
            this.alertMsg = '';
          })],
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.pageBg(this.cm.dark))
    // 宿主层全局 y（锚定换算输入，NetworkDetailView 同款）
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.layerTopY = newValue.globalPosition.y as number;
    })
    // 二维码分享 sheet（iOS .sheet(item: $qrShareSession) 直译）
    .bindSheet(this.showQR, (): void => {
      this.qrShareSheet()
    }, {
      height: SheetSize.LARGE,
      showClose: false,
      backgroundColor: DesignTokens.pageBg(this.cm.dark),
      onWillDismiss: (_action: DismissSheetAction): void => {
        this.showQR = false;
      },
    })
  }

  /** 自绘标题栏（T5 骨架沿用）：标题 = 行星展示名 ?? planet.title */
  @Builder
  titleBar() {
    Row() {
      Row() {
        Image($r('sys.media.ohos_ic_back'))
          .width(24)
          .height(24)
          .fillColor(DesignTokens.textPrimary(this.cm.dark))
      }
      .width(44)
      .height(44)
      .onClick(() => AppNav.pop())
      Text(this.displayName())
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .layoutWeight(1)
      Row().width(44)
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 8 })
    .margin({ top: 12 })
  }

  /** 区头/区脚（iOS Form Section header/footer 直译，NetworkDetailView 同款） */
  @Builder
  sectionHeader(key: string) {
    Text(this.loc(key))
      .fontSize(FS_SECTION_HEADER)
      .fontColor(DesignTokens.textSecondary(this.cm.dark))
      .width('100%')
      .padding({ left: FORM_MARGIN, right: FORM_MARGIN, bottom: 4 })
  }

  @Builder
  sectionFooter(key: string) {
    Text(this.loc(key))
      .fontSize(FS_FOOTNOTE)
      .fontColor(DesignTokens.textSecondary(this.cm.dark))
      .width('100%')
      .padding({ left: FORM_MARGIN, right: FORM_MARGIN, top: 6 })
  }

  /** 静态行（iOS row(_, _) 直译）：标题 + 右对齐次要等宽值（单行中截断） */
  @Builder
  row(title: string, value: string) {
    Row() {
      Text(title)
        .fontSize(FS_BODY)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
      Blank()
      Text(value)
        .fontSize(FS_BODY)
        .fontFamily(DesignTokens.FONT_MONO)
        .fontColor(DesignTokens.textSecondary(this.cm.dark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }) // ArkUI 无 middle 档（Ellipsis 近似，AddPlanetPage 同注）
    }
    .width('100%')
    .height(ROW_HEIGHT)
  }

  /** 名称与图标区（iOS nameAndIconSection 直译）：官方名称只读展示；图标行
   *  24×24 磁贴（圆角 7 内 14）+ 非官方 chevron；官方禁用 + 只读脚注 */
  @Builder
  nameAndIconSection() {
    Column() {
      Column() {
        // 名称行
        Row() {
          Text(this.loc('common.name'))
            .fontSize(FS_BODY)
            .fontColor(DesignTokens.textPrimary(this.cm.dark))
          Blank()
          if (this.isOfficial()) {
            Text(this.displayName())
              .fontSize(FS_BODY)
              .fontColor(DesignTokens.textSecondary(this.cm.dark))
              .maxLines(1)
          } else {
            TextInput({ text: this.name, placeholder: this.loc('common.name') })
              .fontSize(FS_BODY)
              .fontColor(DesignTokens.textPrimary(this.cm.dark))
              .placeholderColor(DesignTokens.textTertiary(this.cm.dark))
              .textAlign(TextAlign.End) // iOS .multilineTextAlignment(.trailing) 直译
              .enterKeyType(EnterKeyType.Done)
              .backgroundColor(Color.Transparent)
              .padding({ left: 0, right: 0, top: 4, bottom: 4 })
              .layoutWeight(1)
              .onChange((v: string) => {
                this.name = v;
              })
              .onSubmit((): void => {
                void this.saveName(); // iOS .onSubmit(saveName) 直译
              })
              .onBlur((): void => {
                void this.saveName(); // iOS 失焦保存直译
              })
          }
        }
        .width('100%')
        .height(ROW_HEIGHT)
        // 图标行（官方 disabled：不响应且无 chevron）
        Row() {
          Text(this.loc('common.icon'))
            .fontSize(FS_BODY)
            .fontColor(this.isOfficial() ? DesignTokens.textSecondary(this.cm.dark)
              : DesignTokens.textPrimary(this.cm.dark))
          Blank()
          if (this.planet !== null) {
            this.iconTile(this.planet)
          }
          if (!this.isOfficial()) {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(FS_SECTION_HEADER)
              .fontWeight(600) // iOS .caption.weight(.semibold) 直译
              .fontColor([DesignTokens.textTertiary(this.cm.dark)])
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .height(ROW_HEIGHT)
        .opacity(this.isOfficial() ? DISABLED_OPACITY : 1)
        .onClick((): void => {
          if (!this.isOfficial()) {
            this.showIconPicker = true;
          }
        })
        .accessibilityText(this.loc('common.icon'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
      if (this.isOfficial()) {
        // 官方行星只读脚注（iOS nameAndIconSection footer 直译，Form 语义在区下方）
        this.sectionFooter('planet.info.officialOnly')
      }
    }
    .width('100%')
  }

  /** 图标行小磁贴（iOS 24×24 圆角 7 内 14 直译；PlanetIconView 的 20 圆角
   *  是 72 磁贴规格，小尺寸按 iOS 行内规格手绘） */
  @Builder
  iconTile(p: PlanetProfile) {
    Stack({ alignContent: Alignment.Center }) {
      if (PlanetIcon.src(PlanetIcon.animalKey(p), getContext()) !== '') {
        Image(PlanetIcon.src(PlanetIcon.animalKey(p), getContext()))
          .width(ICON_TILE_CONTENT)
          .height(ICON_TILE_CONTENT)
          .objectFit(ImageFit.Contain)
      }
    }
    .width(ICON_TILE)
    .height(ICON_TILE)
    .borderRadius(ICON_TILE_RADIUS)
    .backgroundColor(PlanetIcon.tintHex(p, this.tints))
    .clip(true)
  }

  /** 只读信息区（iOS infoSection 直译）：World ID/Node ID（可复制）/类型/
   *  文件大小/修订时间/分享（文件通道平台缺位，仅二维码，见文件头差异②） */
  @Builder
  infoSection() {
    Column() {
      Column() {
        this.row('World ID', this.worldIdHex)
        // Node ID 行（iOS CopyableRow 直译）
        Row() {
          Text(this.loc('planet.info.nodeId'))
            .fontSize(FS_BODY)
            .fontColor(DesignTokens.textPrimary(this.cm.dark))
          Blank()
          CopyableValue({
            text: this.nodeIdText(),
            showsIcon: true,
            color: DesignTokens.textSecondary(this.cm.dark),
          })
        }
        .width('100%')
        .height(ROW_HEIGHT)
        if (this.planet !== null) {
          this.row(this.loc('common.type'), this.isOfficial()
            ? this.loc('planet.info.officialKind')
            : this.loc('planet.info.customKind'))
        }
        if (this.fileSize >= 0) {
          this.row(this.loc('planet.info.fileSize'), this.fileSizeText(this.fileSize))
        }
        if (this.revisionMs > 0) {
          this.row(this.loc('planet.info.revision'), this.timestampText(this.revisionMs))
        }
        if (!this.isOfficial() && this.hasPlanetFile()) {
          // 分享行（iOS 文件+二维码双按钮；文件通道平台缺位仅落二维码）
          Row() {
            Text(this.loc('common.share'))
              .fontSize(FS_BODY)
              .fontColor(DesignTokens.textPrimary(this.cm.dark))
            Blank()
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.qrcode'))
                .fontSize(FS_SHARE_ICON)
                .fontColor([DesignTokens.textPrimary(this.cm.dark)])
              Text(this.loc('planet.share.qr'))
                .fontSize(FS_BODY)
                .fontColor(DesignTokens.textPrimary(this.cm.dark))
            }
            .onClick((): void => {
              void this.shareQR();
            })
            .accessibilityText(this.loc('planet.share.qr'))
          }
          .width('100%')
          .height(ROW_HEIGHT)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
      this.sectionFooter('planet.info.footer')
    }
    .width('100%')
  }

  /** 诊断入口区（iOS diagnosticsSection 直译）：三行导航；按控制器裁决统一
   *  「仅活跃行星可用」（iOS 仅 Peers 行 disabled，差异③） */
  @Builder
  diagnosticsSection() {
    Column() {
      Column() {
        this.diagNavRow('planet.diagnostics.peers', 'person_2', (): void => {
          const page: PagePeers = { kind: 'peers', planetId: this.planetId };
          AppNav.push(page);
        })
        this.diagNavRow('planet.diagnostics.moons', 'star_2_moon', (): void => {
          const page: PageMoon = { kind: 'moon', planetId: this.planetId };
          AppNav.push(page);
        })
        this.diagNavRow('planet.diagnostics.trace', 'waveform_path_ecg_heart', (): void => {
          const page: PageApplyTrace = { kind: 'applyTrace', planetId: this.planetId };
          AppNav.push(page);
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
      .opacity(this.diagnosticsEnabled() ? 1 : DISABLED_OPACITY)
      this.sectionFooter('planet.diagnostics.footer')
    }
    .width('100%')
  }

  /** 诊断导航行（iOS Label + NavigationLink 直译）：符号 + 文案 + chevron */
  @Builder
  diagNavRow(labelKey: string, symbol: string, go: () => void) {
    Row() {
      SymbolGlyph($r('sys.symbol.' + symbol))
        .fontSize(FS_ROW_ICON)
        .fontColor([DesignTokens.textPrimary(this.cm.dark)])
      Text(this.loc(labelKey))
        .fontSize(FS_BODY)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .margin({ left: 12 })
      Blank()
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(FS_SECTION_HEADER)
        .fontWeight(600)
        .fontColor([DesignTokens.textTertiary(this.cm.dark)])
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .enabled(this.diagnosticsEnabled())
    .onClick((): void => {
      if (this.diagnosticsEnabled()) {
        go();
      }
    })
    .accessibilityText(this.loc(labelKey))
  }

  /** 删除区（iOS deleteSection 直译）：红字居中 + 锚点上报 + 确认气泡 */
  @Builder
  deleteSection() {
    Column() {
      Column() {
        Text(this.loc('planet.delete'))
          .fontSize(FS_BODY)
          .fontColor(DesignTokens.danger(this.cm.dark))
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(ROW_HEIGHT)
          // 锚点上报（iOS GlobalAnchorReader 对应物）
          .onAreaChange((_oldValue: Area, newValue: Area) => {
            this.deleteAnchorY = newValue.globalPosition.y as number;
          })
          .onClick((): void => {
            this.showDeleteBubble = true;
          })
          .accessibilityText(this.loc('planet.delete'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
      this.sectionFooter('planet.delete.footer')
    }
    .width('100%')
  }

  /** 图标设置 sheet 内容（iOS IconPickerSheet(animal:color:) 直译） */
  @Builder
  iconPickerSheet() {
    IconPickerSheet({
      animal: PlanetIcon.animalKey(this.planet ?? PlanetProfile.OFFICIAL),
      color: this.planet === null ? null : this.effectiveColorHex(this.planet),
      onSelect: (animal: string, colorHex: string): void => {
        void this.updateIcon(animal, colorHex);
      },
      onClose: (): void => {
        this.showIconPicker = false;
      },
    })
  }

  /** 二维码分享 sheet 内容（iOS QRShareView 直译） */
  @Builder
  qrShareSheet() {
    QRShareSheet({
      payload: this.qrPayload,
      titleKey: 'planet.share.qr.title',
      onClose: (): void => {
        this.showQR = false;
      },
    })
  }
}

/** UTF-8 编码（util.TextEncoder，PlanetImporter 同款出口） */
function utf8(text: string): Uint8Array {
  return util.TextEncoder.create('utf-8').encodeInto(text);
}
