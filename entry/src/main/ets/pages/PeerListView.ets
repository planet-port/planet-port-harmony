// PeerListView.ets — Peers 列表页（iOS PeerListView.swift 全文直译）
//
// 下拉刷新（Refresh ≈ iOS .refreshable，无定时器）；快照 peers 透传（C++ 不
// 透传 paths —— 恒空，relay 胶囊恒显属预期，控制器裁决照直译落）。行视觉：
// 地址 body mono + 角色 Capsule（accent 0.12 底）+ 版本 caption（harmony 快照
// version 已含 v 前缀 "v1.14.0"，直接显示原串；iOS 源为 "v\(version)" 拼前缀
// ——避免 "vv"，见任务报告偏差）+ 延迟（6pt 圆点语义色 + caption semibold：
// <30ms 成功绿 / <100ms 橙 / ≥100ms 红）；paths 空橙色 relay 胶囊（arrow 分叉
// 图标 + caption2 semibold，橙 0.12 底）。查询中/隧道未运行/空三态复用空态卡。
// 卡片语言与首页一致：透明 List 行 + 灰底圆角卡（水平 20 对齐页边距，卡间 12
// 视觉间隙 = 行上下 6 margin）。
import { AppNav } from '../ui/AppRoot';
import { AppState } from '../ui/AppState';
import { StatusStore } from '../tunnel/StatusStore';
import { PeerEntry, TunnelSnapshot } from '../common/TunnelContract';
import { PlanetProfile } from '../store/Models';
import { ThemeManager, themeSignal, ThemeSignal } from '../store/ThemeManager';
import { DesignTokens, colorModeSignal, ColorModeSignal } from '../components/DesignTokens';
import { L10n, l10nSignal } from '../components/L10n';

/** 字号（iOS .body 17 / .caption 12 / .caption2 11 / .subheadline 15 /
 *  .footnote 13；32 为空态图标） */
const FS_BODY: number = 17;
const FS_CAPTION: number = 12;
const FS_CAPTION2: number = 11;
const FS_SUBHEADLINE: number = 15;
const FS_FOOTNOTE: number = 13;
const FS_EMPTY_ICON: number = 32;
/** 行卡片边距（iOS cardInsets：水平 20 / 上下 6）与卡内衬（iOS padding 14） */
const CARD_MARGIN_H: number = 20;
const CARD_MARGIN_V: number = 6;
const CARD_PAD: number = 14;
/** 延迟圆点（iOS Circle 6×6）与徽标胶囊圆角 = 高度一半 */
const LATENCY_DOT: number = 6;
const BADGE_RADIUS: number = 999;
/** 延迟语义分档（iOS latencyColor 直译：<30 好 / <100 一般 / 其余差） */
const LATENCY_GOOD_MS: number = 30;
const LATENCY_FAIR_MS: number = 100;
/** 成功色兜底（applyTheme 派生前首帧；HomeView 同款） */
const FALLBACK_SUCCESS: number = 0xFF009830;

@ComponentV2
export struct PeerListView {
  /** 页面入参（T5 契约；直译源无入参——归属由消费方推断，见 AppRoot 注） */
  @Param planetId: string = '';

  /** 全局 UI 状态（vpnRunning 触踪——空态分档门槛） */
  @Local app: AppState = AppState.shared;
  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;
  @Local theme: ThemeSignal = themeSignal;
  /** 隧道快照（peers 唯一来源；整体替换触踪） */
  @Local snap: TunnelSnapshot | null = StatusStore.current();
  /** 首次读取完成（iOS @State loaded 直译：三态空态分档门槛） */
  @Local loaded: boolean = false;
  /** 下拉刷新态（Refresh 组件要求；收口在 refresh 末尾置 false） */
  @Local refreshing: boolean = false;
  /** 成功色（主题派生，延迟「好」档与空态无关） */
  @Local successColor: number = FALLBACK_SUCCESS;

  private themeRef: ThemeManager | null = null;
  private unsubSnap: (() => void) | null = null;

  aboutToAppear(): void {
    this.unsubSnap = StatusStore.subscribe((s: TunnelSnapshot | null) => {
      this.snap = s;
      this.loaded = true;
    });
    void ThemeManager.shared().then((t: ThemeManager) => {
      this.themeRef = t;
      this.applyTheme();
    });
    void this.refresh();
  }

  aboutToDisappear(): void {
    if (this.unsubSnap !== null) {
      this.unsubSnap();
      this.unsubSnap = null;
    }
  }

  @Monitor('theme.rev', 'cm.dark')
  applyTheme(): void {
    const t = this.themeRef;
    if (t === null) {
      return;
    }
    const raw = this.cm.dark ? t.successDarkHex() : t.successLightHex();
    this.successColor = raw > 0xFFFFFF ? raw : 0xFF000000 + raw;
  }

  // ---- 数据域 ----

  /** 刷新（iOS refresh 直译）：快照文件重读 + loaded 收口（鸿蒙无跨进程实时
   *  查询通道，最近似等价 = 重读 VpnExt 周期刷新的快照文件） */
  private async refresh(): Promise<void> {
    this.refreshing = true; // 置真起步：指示器收口靠 true→false 状态迁移驱动
    try {
      await StatusStore.refresh();
      this.snap = StatusStore.current();
      this.loaded = true;
    } finally {
      this.refreshing = false;
    }
  }

  private peers(): PeerEntry[] {
    return this.snap === null ? [] : this.snap.peers;
  }

  /** 活跃行星展示名（iOS app.activePlanet.displayName 直译；Peers 数据是
   *  隧道全局视图，归属永远是活跃行星） */
  private activePlanetName(): string {
    const p = this.app.planets.find(
      (q: PlanetProfile): boolean => q.id === this.app.activePlanetId);
    if (p === undefined) {
      return this.loc('planet.official.name');
    }
    return p.id === PlanetProfile.OFFICIAL_ID ? this.loc('planet.official.name') : p.name;
  }

  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  private locFmt(key: string, args: (string | number)[]): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.format(key, args);
  }

  /** 节点地址（iOS "%010llx" 直译）：40 位地址 → 10 位小写 hex 零填充 */
  private addressText(p: PeerEntry): string {
    return p.address.toString(16).padStart(10, '0');
  }

  /** 延迟语义色（iOS latencyColor 直译） */
  private latencyColor(ms: number): number {
    if (ms < LATENCY_GOOD_MS) {
      return this.successColor;
    }
    if (ms < LATENCY_FAIR_MS) {
      return DesignTokens.warn(this.cm.dark);
    }
    return DesignTokens.danger(this.cm.dark);
  }

  // ---- 渲染 ----

  build() {
    Column() {
      this.titleBar()
      Refresh({ refreshing: this.refreshing }) {
        List() {
          if (this.peers().length === 0) {
            ListItem() {
              this.statusCard()
            }
          }
          ForEach(this.peers(), (peer: PeerEntry) => {
            ListItem() {
              this.peerCard(peer)
            }
          }, (peer: PeerEntry) => `${peer.address}:${peer.version}:${peer.latency}:`
            + `${peer.role}:${peer.paths.length}`
            + `:${this.theme.rev}:${this.cm.dark ? '1' : '0'}:${l10nSignal.rev}`) // 数据指纹 keyer
          // （T7 C-1 教训）：key 相同即复用整棵子树不重跑 itemGenerator——除数据
          // 字段外必须拼入行渲染消费的主题/深浅/语言指纹（accent 徽标、语义色、
          // relay 文案），否则切主题/语言时存量行滞留旧视觉直到数据指纹变化
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .layoutWeight(1)
      .onRefreshing((): void => {
        void this.refresh();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.pageBg(this.cm.dark))
  }

  /** 自绘标题栏（T5 骨架沿用；标题直书 'Peers' = iOS 硬编码字面量） */
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
      Text('Peers')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Row().width(44)
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 8 })
    .margin({ top: 12 })
  }

  /** 状态卡（iOS statusCard 直译）：查询中 / 隧道未运行 / 空三态 */
  @Builder
  statusCard() {
    Column({ space: 10 }) {
      if (!this.loaded) {
        LoadingProgress()
          .width(FS_EMPTY_ICON)
          .height(FS_EMPTY_ICON)
          .color(DesignTokens.textSecondary(this.cm.dark))
        Text(this.loc('peers.loading'))
          .fontSize(FS_SUBHEADLINE)
          .fontWeight(FontWeight.Medium)
          .fontColor(DesignTokens.textPrimary(this.cm.dark))
      } else if (!this.app.vpnRunning) {
        SymbolGlyph($r('sys.symbol.phone_radiowaves_left_and_right_slash'))
          .fontSize(FS_EMPTY_ICON)
          .fontWeight(FontWeight.Lighter) // iOS .system(size: 32, weight: .light) 直译
          .fontColor([DesignTokens.textSecondary(this.cm.dark)])
        Text(this.loc('peers.tunnelDown'))
          .fontSize(FS_SUBHEADLINE)
          .fontWeight(FontWeight.Medium)
          .fontColor(DesignTokens.textPrimary(this.cm.dark))
        Text(this.loc('peers.tunnelDownHint'))
          .fontSize(FS_FOOTNOTE)
          .fontColor(DesignTokens.textSecondary(this.cm.dark))
      } else {
        SymbolGlyph($r('sys.symbol.person_2'))
          .fontSize(FS_EMPTY_ICON)
          .fontWeight(FontWeight.Lighter)
          .fontColor([DesignTokens.textSecondary(this.cm.dark)])
        Text(this.locFmt('peers.emptyTitle %@', [this.activePlanetName()]))
          .fontSize(FS_SUBHEADLINE)
          .fontWeight(FontWeight.Medium)
          .fontColor(DesignTokens.textPrimary(this.cm.dark))
        Text(this.loc('peers.refreshHint'))
          .fontSize(FS_FOOTNOTE)
          .fontColor(DesignTokens.textSecondary(this.cm.dark))
      }
    }
    .width('100%')
    .padding({ top: 36, bottom: 36 })
    .backgroundColor(DesignTokens.cardBg(this.cm.dark))
    .borderRadius(DesignTokens.RADIUS_CARD)
    .margin({
      left: CARD_MARGIN_H, right: CARD_MARGIN_H,
      top: CARD_MARGIN_V, bottom: CARD_MARGIN_V,
    })
  }

  /** Peer 卡（iOS peerCard 直译）：地址+角色徽标 / 版本+延迟 / relay 胶囊或路径 */
  @Builder
  peerCard(peer: PeerEntry) {
    Column({ space: 5 }) {
      Row({ space: 8 }) {
        Text(this.addressText(peer))
          .fontSize(FS_BODY)
          .fontFamily(DesignTokens.FONT_MONO)
          .fontColor(DesignTokens.textPrimary(this.cm.dark))
          .maxLines(1)
        Blank()
        this.roleBadge(peer.role)
      }
      .width('100%')
      Row({ space: 8 }) {
        Text(peer.version) // 快照已带 v 前缀，直接显示（iOS 源 "v\(version)" 拼前缀）
          .fontSize(FS_CAPTION)
          .fontColor(DesignTokens.textSecondary(this.cm.dark))
        Blank()
        if (peer.latency >= 0) {
          Row({ space: 4 }) {
            Column()
              .width(LATENCY_DOT)
              .height(LATENCY_DOT)
              .borderRadius(LATENCY_DOT / 2)
              .backgroundColor(this.latencyColor(peer.latency))
            Text(`${peer.latency} ms`)
              .fontSize(FS_CAPTION)
              .fontWeight(600) // iOS .caption.weight(.semibold) 直译
              .fontColor(this.latencyColor(peer.latency))
          }
        }
      }
      .width('100%')
      if (peer.paths.length === 0) {
        // 无直连路径 = 经 planet/root 中转，是性能劣化信号，橙色标识
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.arrow_triangle_divide'))
            .fontSize(FS_CAPTION2)
            .fontColor([DesignTokens.warn(this.cm.dark)])
          Text(this.loc('peers.relay'))
            .fontSize(FS_CAPTION2)
            .fontWeight(600)
            .fontColor(DesignTokens.warn(this.cm.dark))
        }
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(BADGE_RADIUS)
        .backgroundColor(this.relayAlphaBg())
      } else {
        Text(peer.paths[0])
          .fontSize(FS_CAPTION)
          .fontFamily(DesignTokens.FONT_MONO)
          .fontColor(DesignTokens.textTertiary(this.cm.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(CARD_PAD)
    .backgroundColor(DesignTokens.cardBg(this.cm.dark))
    .borderRadius(DesignTokens.RADIUS_CARD)
    .margin({
      left: CARD_MARGIN_H, right: CARD_MARGIN_H,
      top: CARD_MARGIN_V, bottom: CARD_MARGIN_V,
    })
  }

  /** 角色徽标（iOS roleBadge 直译）：accent 0.12 底 + accent 字色胶囊 */
  @Builder
  roleBadge(role: string) {
    Text(role.toUpperCase())
      .fontSize(FS_CAPTION2)
      .fontWeight(600)
      .fontColor(this.accent())
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .borderRadius(BADGE_RADIUS)
      .backgroundColor(this.accentAlphaBg(0x1F000000))
  }

  /** 主题 accent（themeSignal.accent '#AARRGGBB' → 渲染域 number） */
  private accent(): number {
    return parseInt(this.theme.accent.slice(2), 16) + 0xFF000000;
  }

  /** accent 低透明度底（IconPickerSheet.accentAlphaBg 同款加法重组） */
  private accentAlphaBg(alphaHex: number): number {
    return alphaHex + parseInt(this.theme.accent.slice(2), 16);
  }

  /** relay 橙 0.12 底（iOS .orange.opacity(0.12)：0.12 → 0x1F） */
  private relayAlphaBg(): number {
    return 0x1F000000 + (DesignTokens.warn(this.cm.dark) & 0xFFFFFF);
  }
}
