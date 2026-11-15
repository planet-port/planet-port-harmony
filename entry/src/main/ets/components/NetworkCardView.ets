// NetworkCardView.ets — 网络卡片（纯展示组件）+ NetworkCardStatus 状态机
//
// 直译源：iOS NetworkCardView.swift 全文件（状态机 :8-83 / 卡片 :106-171 /
// IP 复制 :190-206）。状态、开关值、地址均由外部/快照传入，开关与点击经回调
// 交还 HomeView 编排（切换确认弹窗、VPN 启动流程均在上层）；行内导航用点击
// （iOS onTapGesture 同款：位移即失败，滑动不会误开详情页）。
//
// 状态机（networkCardStatus）是无 UI 依赖的纯函数：文案在此处只产出查表键
// （status.* 前缀，含 %@ 占位），颜色产出 number——展示文案的本地化在组件
// 渲染层经 L10n 完成（对齐 iOS「跨进程契约禁止文案字符串做逻辑判断」）。
// 镜像自测：components/tests/mirror/networkcardstatus.mjs 与本文件纯函数段
// 逐行同构（scripts 模式的 components/tests/mirror-check.sh 校验）。
import { l10nSignal, L10n } from './L10n';
import { DesignTokens, colorModeSignal, ColorModeSignal } from './DesignTokens';
import { AppState } from '../ui/AppState';
import { NetworkEntry, DnsMode } from '../store/Models';
import { TunnelSnapshot, NetConfSnapshot, aliveFresh } from '../common/TunnelContract';
import pasteboard from '@ohos.pasteboard';
import { StatusStore } from '../tunnel/StatusStore';

// ============================================================================
// 状态机纯函数段（无 UI / 无 L10n 依赖；镜像 .mjs 逐行同构，改一处必须同步
// 另一处——components/tests/mirror-check.sh 按 MIRROR 标记切片校验）
// >>> MIRROR-BEGIN（镜像切片起点：其后至 MIRROR-END 的逻辑行与 .mjs 全文对应）
// ============================================================================

/** ZT_VirtualNetworkStatus 原始码（Core/include/ZeroTierOne.h 0..6；跨进程契约） */
export const ZT_STATUS_REQUESTING_CONFIGURATION: number = 0;
export const ZT_STATUS_OK: number = 1;
export const ZT_STATUS_ACCESS_DENIED: number = 2;
export const ZT_STATUS_NOT_FOUND: number = 3;
export const ZT_STATUS_PORT_ERROR: number = 4;
export const ZT_STATUS_CLIENT_TOO_OLD: number = 5;
export const ZT_STATUS_AUTHENTICATION_REQUIRED: number = 6;

/** lastConflict 原始码（Shared/Models.swift ConflictCode 直译） */
export const CONFLICT_ADDRESS: string = 'address';
export const CONFLICT_SUBNET: string = 'subnet';
export const CONFLICT_TIMEOUT: string = 'timeout';

/** 状态机颜色域（secondary/warn/danger/success；dark 分支由调用方求值）。
 *  class 承载数据结构对齐 T3 镜像惯例（.mjs 同构可比）。 */
export class NetworkCardPalette {
  secondary: number = 0;
  warn: number = 0;
  danger: number = 0;
  success: number = 0;

  constructor(secondary: number, warn: number, danger: number, success: number) {
    this.secondary = secondary;
    this.warn = warn;
    this.danger = danger;
    this.success = success;
  }
}

/** 状态机输入：卡片所在行星是否活跃 + 网络开关/遗留冲突 + 隧道快照投影 */
export class NetworkCardStatusInput {
  isActivePlanet: boolean = false;
  lastActivated: boolean = false;
  /** 最近一次断开原因（"address"|"subnet"|"timeout"）；null=无 */
  lastConflict: string | null = null;
  /** 快照侧冲突原始码（app.networkConflicts[id]）；null=无 */
  snapshotConflict: string | null = null;
  vpnRunning: boolean = false;
  pathSatisfied: boolean = false;
  /** 节点已连上行星根服务器（REQUESTING_CONFIGURATION 分段锚） */
  online: boolean = false;
  /** 快照侧核心实时状态码（app.networkStatuses[id]）；null=无条目 */
  netStatus: number | null = null;

  constructor(isActivePlanet: boolean, lastActivated: boolean, lastConflict: string | null,
    snapshotConflict: string | null, vpnRunning: boolean, pathSatisfied: boolean,
    online: boolean, netStatus: number | null) {
    this.isActivePlanet = isActivePlanet;
    this.lastActivated = lastActivated;
    this.lastConflict = lastConflict;
    this.snapshotConflict = snapshotConflict;
    this.vpnRunning = vpnRunning;
    this.pathSatisfied = pathSatisfied;
    this.online = online;
    this.netStatus = netStatus;
  }
}

/** 状态机输出：文案查表键（含 %@ 占位时 textArg 非空）+ 文字/圆点色 */
export class NetworkCardStatusOutput {
  textKey: string = '';
  textArg: string | null = null;
  color: number = 0;
  dotColor: number = 0;

  constructor(textKey: string, textArg: string | null, color: number, dotColor: number) {
    this.textKey = textKey;
    this.textArg = textArg;
    this.color = color;
    this.dotColor = dotColor;
  }
}

/**
 * 核心实时状态码 → 展示文案键（iOS ZTNetworkStatus.displayName 直译）；
 * 域外码（核心未来新增）统一落 unknown 兜底键。
 */
export function ztStatusKey(code: number): string {
  switch (code) {
    case ZT_STATUS_REQUESTING_CONFIGURATION:
      return 'network.status.requestingConfiguration';
    case ZT_STATUS_OK:
      return 'network.status.ok';
    case ZT_STATUS_ACCESS_DENIED:
      return 'network.status.accessDenied';
    case ZT_STATUS_NOT_FOUND:
      return 'network.status.notFound';
    case ZT_STATUS_PORT_ERROR:
      return 'network.status.portError';
    case ZT_STATUS_CLIENT_TOO_OLD:
      return 'network.status.clientTooOld';
    case ZT_STATUS_AUTHENTICATION_REQUIRED:
      return 'network.status.authRequired';
    default:
      return 'network.status.unknown';
  }
}

/**
 * 首次加入待控制器授权：核心报「需要认证」或「拒绝访问」均属正常流程
 * （iOS isPendingAuthorization 直译）；域外码非待授权。
 */
export function isPendingAuthorization(code: number): boolean {
  return code === ZT_STATUS_AUTHENTICATION_REQUIRED || code === ZT_STATUS_ACCESS_DENIED;
}

/**
 * 冲突原始码 → 展示文案键（iOS conflictText 直译）：仅 UI 层使用，
 * 非 address 一律按 subnet（快照契约只产生这两类）。
 */
export function conflictTextKey(code: string): string {
  return code === CONFLICT_ADDRESS ? 'card.conflict.address' : 'card.conflict.subnet';
}

/** 状态机输出构造（dotColor 与文字色同源——iOS Circle .fill(cardStatus.color)） */
function statusOut(textKey: string, textArg: string | null,
  color: number): NetworkCardStatusOutput {
  return new NetworkCardStatusOutput(textKey, textArg, color, color);
}

/**
 * 网络卡片状态机（iOS NetworkCardStatus.init 全量直译）。状态只有：未连接 /
 * 建立隧道 / 待授权 / 核心实时状态（连接服务器、请求网络配置、在线等）。
 * 分支优先级序即 iOS if-else 链序，逐分支见行内对照。
 */
export function networkCardStatus(inp: NetworkCardStatusInput,
  pal: NetworkCardPalette): NetworkCardStatusOutput {
  // 非当前隧道行星的网络一律「未连接」——开关为关，打开即切换行星，无需
  // 中间状态。判断锚定卡片自己的行星而非全局选中页：滑页过程中 selection
  // 先行变化，全局判断会让旁页卡片瞬时取错显示值。
  if (!inp.isActivePlanet) {
    return statusOut('status.disconnected', null, pal.secondary);
  }
  // 快照冲突（address/subnet）优先于开关判定：自动断开前的瞬时窗口
  if (inp.snapshotConflict !== null && inp.lastActivated) {
    return statusOut(conflictTextKey(inp.snapshotConflict), null, pal.danger);
  }
  if (!inp.lastActivated) {
    // 断开态优先于 vpnRunning 判定：冲突自动断开通常伴随停 VPN，若先判
    // vpnRunning 会把原因吞掉显示成「未连接」。
    if (inp.lastConflict !== null) {
      // 连接超时是共享故障，直接显示「连接超时」，不套「冲突,断开」模板。
      if (inp.lastConflict === CONFLICT_TIMEOUT) {
        return statusOut('card.timeout.offline', null, pal.danger);
      }
      return statusOut('card.conflict.offline %@', conflictTextKey(inp.lastConflict), pal.danger);
    }
    return statusOut('status.disconnected', null, pal.secondary);
  }
  if (!inp.vpnRunning) {
    return statusOut('status.establishing', null, pal.warn);
  }
  // 物理网络不可用（飞行模式/断网）：优先于核心状态展示——核心 netconf 缓存
  // 仍是 ok 会假亮「在线」。仅改显示，开关与 VPN 状态不动。
  if (!inp.pathSatisfied) {
    return statusOut('status.noNetwork', null, pal.warn);
  }
  if (inp.netStatus !== null) {
    // 首次加入需控制器授权：统一显示「待授权」
    if (isPendingAuthorization(inp.netStatus)) {
      return statusOut('status.pendingAuth', null, pal.warn);
    }
    // 核心等待链按 online 拆段：未连根服务器=「连接服务器」，已连但未拿到
    // 配置=「请求网络配置」（超时重试在编排层无感循环，全程显示进行中文案）
    if (inp.netStatus === ZT_STATUS_REQUESTING_CONFIGURATION) {
      const phase = inp.online ? 'network.status.requestingConfig' : 'network.status.connectingServer';
      return statusOut(phase, null, pal.warn);
    }
    if (inp.netStatus === ZT_STATUS_OK) {
      return statusOut('network.status.ok', null, pal.success);
    }
    return statusOut(ztStatusKey(inp.netStatus), null, pal.warn);
  }
  return statusOut('status.waitingNode', null, pal.secondary);
}

// <<< MIRROR-END（镜像切片终点）
// ============================================================================
// 卡片组件（快照侧状态经 StatusStore 订阅回流，不自旋）
// ============================================================================

/** 名称/chevron 等本地字号（iOS 15 semibold / caption 12 / caption2 11 / footnote 13） */
const FS_FOOTNOTE: number = 13;
/** IP 复制图标（iOS 7pt 原尺寸放大 25% → 9pt） */
const FS_COPY_ICON: number = 9;
/** 开关/pending 列宽（iOS frame(width: 44)） */
const TOGGLE_COL: number = 44;
/** pending 转圈直径（iOS ProgressView 默认 ≈20pt 的就近档） */
const PENDING_SPINNER: number = 24;
/** 对勾反馈停留时长（iOS asyncAfter 0.8s） */
const CHECKMARK_MS: number = 800;

@ComponentV2
export struct NetworkCardView {
  /** 网络条目（归属行星、开关值、遗留冲突均在此） */
  @Param entry: NetworkEntry = new NetworkEntry('', '', false, false, DnsMode.None, []);
  /** 卡片所在行星是否隧道活跃行星（状态/开关值/地址的显示锚） */
  @Param isActivePlanet: boolean = false;
  /** ok 状态的 success 色（0xAARRGGBB；主题派生值由父级 applyTheme 传入） */
  @Param successColor: number = 0xFF009830;
  /** 开关回调（开=连接/关=断开编排归 HomeView） */
  @Param onToggle: (active: boolean) => void = (active: boolean) => {};
  /** 卡片点击（进网络详情） */
  @Param onTap: () => void = () => {};

  /** 全局 UI 状态（vpnRunning/pathSatisfied 触踪） */
  @Local app: AppState = AppState.shared;
  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;
  /** 隧道快照（networkStatuses/networkConflicts/networkConfigs 投影源） */
  @Local snap: TunnelSnapshot | null = StatusStore.current();
  /** 复制反馈：图标短暂变对勾 */
  @Local copied: boolean = false;
  private unsub: (() => void) | null = null;
  private copyTimer: number = -1;

  aboutToAppear(): void {
    // 订阅即推当前值；STATE_CHANGED 唤醒 + 10s 存活期轮询持续重推——pending
    // 态由快照回流自然消失，无自旋定时器
    this.unsub = StatusStore.subscribe((s: TunnelSnapshot | null) => {
      this.snap = s;
    });
  }

  aboutToDisappear(): void {
    if (this.unsub !== null) {
      this.unsub();
    }
    if (this.copyTimer >= 0) {
      clearTimeout(this.copyTimer);
      this.copyTimer = -1;
    }
  }

  // ---- 快照投影 ----

  /** 快照侧核心状态码（无条目 = null） */
  private statusOf(): number | null {
    const s = this.snap;
    if (s === null) {
      return null;
    }
    const v = s.networkStatuses[this.entry.networkId];
    return v === undefined ? null : v as number;
  }

  /** 快照侧冲突原始码（无条目 = null） */
  private conflictOf(): string | null {
    const s = this.snap;
    if (s === null) {
      return null;
    }
    const v = s.networkConflicts[this.entry.networkId];
    return v === undefined ? null : v as string;
  }

  /**
   * 分配 IP（iOS addresses 直译）：nil = 无数据/非活跃行星显示 "-"；
   * assignedAddrs 是 "ip/prefix"，取前缀段。
   */
  private addresses(): string[] | null {
    if (!this.isActivePlanet) {
      return null;
    }
    const s = this.snap;
    if (s === null) {
      return null;
    }
    const cfg = s.networkConfigs.find((c: NetConfSnapshot) => c.nwid === this.entry.networkId);
    if (cfg === undefined) {
      return null;
    }
    return cfg.assignedAddrs.map((a: string): string => {
      const seg = a.split('/')[0];
      return seg === undefined ? a : seg;
    });
  }

  /** 开关显示值（非当前隧道行星的网络统一显示为关，iOS appearsActive 直译） */
  private appearsActive(): boolean {
    return this.isActivePlanet && this.entry.lastActivated;
  }

  /**
   * 开关请求处理中（iOS isPending 的快照回流形态）：拨动开关后、核心尚未
   * 回流确认前显示转圈。判定 = 隧道存活且新鲜，且「开关意图值」≠「快照确认
   * 值」（开等核心 join：快照尚无该网络状态条目；关等核心 leave：条目仍在）。
   * 隧道不跑/快照冻结时恒 false（Toggle 直显）——不自旋、不会卡死开关。
   */
  private isPending(): boolean {
    if (!this.isActivePlanet) {
      return false;
    }
    const s = this.snap;
    if (s === null || !aliveFresh(s)) {
      return false;
    }
    const confirmed = this.statusOf() !== null;
    return this.appearsActive() !== confirmed;
  }

  /** 展示名：名称空回退 ID（iOS 直译） */
  private displayName(): string {
    return this.entry.networkName === '' ? this.entry.networkId : this.entry.networkName;
  }

  /** 状态机求值（状态行文本与颜色同源一次算） */
  private cardStatus(): NetworkCardStatusOutput {
    const pal = new NetworkCardPalette(
      DesignTokens.textSecondary(this.cm.dark),
      DesignTokens.warn(this.cm.dark),
      DesignTokens.danger(this.cm.dark),
      this.successColor);
    const inp = new NetworkCardStatusInput(
      this.isActivePlanet,
      this.entry.lastActivated,
      this.entry.lastConflict,
      this.conflictOf(),
      this.app.vpnRunning,
      this.app.pathSatisfied,
      this.app.online,
      this.statusOf());
    return networkCardStatus(inp, pal);
  }

  // ---- 复制域 ----

  private copyIp(addresses: string[]): void {
    const text = addresses.length > 0 ? addresses[0] : '';
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setDataSync(data);
    this.flashCopied();
  }

  private copyId(): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.entry.networkId);
    pasteboard.getSystemPasteboard().setDataSync(data);
    this.flashCopied();
  }

  /** 复制反馈（iOS withAnimation 0.8s 复位直译；句柄可重入/可清理） */
  private flashCopied(): void {
    if (this.copyTimer >= 0) {
      clearTimeout(this.copyTimer);
    }
    this.copied = true;
    this.copyTimer = setTimeout(() => {
      this.copied = false;
      this.copyTimer = -1;
    }, CHECKMARK_MS);
  }

  // ---- 文案域 ----

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

  build() {
    Row({ space: 12 }) {
      Column({ space: 5 }) {
        Text(this.displayName())
          .fontSize(DesignTokens.FS_ROW_TITLE)
          .fontWeight(600) // iOS .semibold
          .fontColor(DesignTokens.textPrimary(this.cm.dark))
          .maxLines(1)
        Text(this.entry.networkId)
          .fontSize(DesignTokens.FS_CAPTION)
          .fontFamily(DesignTokens.FONT_MONO)
          .fontColor(DesignTokens.textTertiary(this.cm.dark))
          .maxLines(1)
        this.statusRow()
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // 行内导航：点击进详情（位移即失败，滑动不误开；iOS onTapGesture 直译）
      .onClick(() => this.onTap())
      // 长按菜单：复制网络 ID（iOS contextMenu Label common.copyId 直译）
      .bindContextMenu(this.idMenu(), ResponseType.LongPress)

      if (this.isPending()) {
        // 开关请求处理中：转圈替代 Toggle（快照回流后自动恢复）
        Column() {
          LoadingProgress()
            .width(PENDING_SPINNER)
            .height(PENDING_SPINNER)
            .color(DesignTokens.textTertiary(this.cm.dark))
        }
        .width(TOGGLE_COL)
        .height(TOGGLE_COL)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        Column() {
          Toggle({ type: ToggleType.Switch, isOn: this.appearsActive() })
            .onChange((on: boolean) => this.onToggle(on))
            .accessibilityText(this.locFmt('card.a11yToggle %@', [this.displayName()]))
        }
        .width(TOGGLE_COL)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      // 「更多」箭头固定在最右（iOS .footnote.weight(.semibold) ≈13/600）
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(FS_FOOTNOTE)
        .fontWeight(600)
        .fontColor([DesignTokens.textTertiary(this.cm.dark)])
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding(DesignTokens.PAD_CARD)
    .backgroundColor(DesignTokens.cardBg(this.cm.dark))
    .borderRadius(DesignTokens.RADIUS_CARD)
  }

  /** 状态行：6pt 点 + caption 文本 + IP（caption2 mono tertiary，前 2 个双
   *  空格分隔）+ 9pt 复制图标；无地址数据用 "-" 占位（iOS :117-139 直译） */
  @Builder
  statusRow() {
    Row({ space: 8 }) {
      Row()
        .width(6)
        .height(6)
        .borderRadius(3)
        .backgroundColor(this.cardStatus().dotColor)
      Text(this.statusText())
        .fontSize(DesignTokens.FS_CAPTION)
        .fontColor(this.cardStatus().color)
        .maxLines(1)
      if (this.ipText() !== null) {
        // IP 与复制图标单独成组：组内间距 4（原 8 的一半），点击均可复制；
        // 热区外扩 5（padding 扩区 + 负 margin 抵消占位，CopyableValue 同款）
        Row({ space: 4 }) {
          Text(this.ipText() as string)
            .fontSize(DesignTokens.FS_CAPTION2)
            .fontFamily(DesignTokens.FONT_MONO)
            .fontColor(DesignTokens.textTertiary(this.cm.dark))
            .maxLines(1)
          this.copyGlyph()
        }
        .alignItems(VerticalAlign.Center)
        .padding(5)
        .margin(-5)
        .onClick(() => {
          const addrs = this.addresses();
          if (addrs !== null) {
            this.copyIp(addrs);
          }
        })
        .accessibilityText(this.loc('common.copyIp'))
      } else {
        Text('-')
          .fontSize(DesignTokens.FS_CAPTION2)
          .fontFamily(DesignTokens.FONT_MONO)
          .fontColor(DesignTokens.textTertiary(this.cm.dark))
      }
    }
    .alignItems(VerticalAlign.Center)
    .padding({ top: 2 })
  }

  /** IP 展示文本（前 2 个双空格分隔）；无数据 null */
  private ipText(): string | null {
    const addrs = this.addresses();
    if (addrs === null || addrs.length === 0) {
      return null;
    }
    return addrs.slice(0, 2).join('  ');
  }

  /** 复制图标：与 IP 文字同色（tertiary），原尺寸放大 25%（7 → 9）；复制成功
   *  瞬间变对勾（success 色 semibold）——iOS copyIcon 直译 */
  @Builder
  copyGlyph() {
    // iOS doc.on.doc 鸿蒙 symbol 表无对应名，取同形 doc_filled_on_doc
    SymbolGlyph(this.copied ? $r('sys.symbol.checkmark') : $r('sys.symbol.doc_filled_on_doc'))
      .fontSize(FS_COPY_ICON)
      .fontWeight(this.copied ? 600 : 400) // iOS .semibold/.regular
      .fontColor([this.copied ? this.successColor : DesignTokens.textTertiary(this.cm.dark)])
  }

  /** 长按菜单：复制网络 ID */
  @Builder
  idMenu() {
    Menu() {
      MenuItem({ content: this.loc('common.copyId') })
        .onClick(() => this.copyId())
    }
  }

  /** 状态行文案：查表键 → 本地化（含 %@ 占位分支）。%@ 参数（conflictTextKey
   *  产出的 'card.conflict.*' 查表键）先本地化再进格式化——L10n.format 只做
   *  占位替换不本地化参数，直接传键会显示成裸键（C-2）；对齐 iOS 侧参数在
   *  String(localized:) 求值前已是本地化文本。 */
  private statusText(): string {
    const st = this.cardStatus();
    if (st.textArg !== null) {
      return this.locFmt(st.textKey, [this.loc(st.textArg)]);
    }
    return this.loc(st.textKey);
  }
}
