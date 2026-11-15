// JoinNetworkSheet.ets — 加入网络半模态（iOS JoinNetworkSheet.swift 100 行直译）
//
// 直译源：iOS JoinNetworkSheet.swift（16 位 hex ID 输入 + 尾部扫码按钮 +
// routeVia 开关 + DNS 三模式段）+ DNSConfigSection.swift（DNS 编辑区共用布局，
// v4×2/v6×2 四槽位模型 + inet_pton 校验语义）。
//
// 宿主契约：由 HomeView 经 bindSheet 半模态挂载（iOS sheet 形态等价），确认
// 加入后 networks 域 upsert + fireConfig（writeNetworks 内部发射 configChanged
// + CONFIG_CHANGED 唤醒 VpnExt 热重读，即 iOS writeNetworks→notifyConfigChanged
// 的鸿蒙对应物）后 onClose 收起。
// planetId 落库统一（T7 concern 4 收口，控制器裁决 3）：归属一律写
// AppState.shared.activePlanetId（iOS 写 selectedPlanetId，裁决改锚活跃行星）；
// 存量 null 条目不做迁移扫描，新增条目天然带 planetId。
// 软上限：iOS/Android 加入路径均无软上限 alert（Android JoinNetworkSheet.kt:91
// 「软上限只作用于激活路径」；iOS HomeView.swift:496 在开关激活路径）——按直译
// 源口径加入侧不加（控制器裁决 4 的「源里没有就不加」分支）。
// 扫码语义（控制器裁决 5，以 iOS JoinNetworkSheet.swift 为准）：扫码只填网络
// ID——回调文本经 extractNetworkId（iOS QRScannerView.swift:127 直译）取 16 位
// hex（内容本身合法直接用，否则找子串）；识别后仅关扫码层，停留在加入弹窗。
// ZTQR1 的 ZTP KV 解析（1=planet/2=名称/3=图标/4=底色）只在扫码导入行星场景
// 消费，本 sheet 不解析。
import { DnsMode, NetworkEntry } from '../store/Models';
import { StoreRepo } from '../store/StoreRepo';
import { AppState } from '../ui/AppState';
import { l10nSignal, L10n } from './L10n';
import { DesignTokens, colorModeSignal, ColorModeSignal } from './DesignTokens';
import { themeSignal } from '../store/ThemeManager';
import { AppAlert, AppAlertButton } from './AppAlert';
import { QrScannerSheet } from '../qrtransfer/QrScannerSheet';

/** 网络 ID 定长（16 位 hex） */
const NWID_LEN: number = 16;
/** 表单字号（iOS .body 17 / .caption 12 / .caption2 11） */
const FS_BODY: number = 17;
const FS_CAPTION: number = 12;
const FS_SECTION_HEADER: number = 11;
/** 表单行高（iOS Form 行标准 44pt） */
const ROW_HEIGHT: number = 44;
/** 分段控件（iOS .pickerStyle(.segmented)）：轨高 28 + 内衬 2 + 段圆角 7 */
const SEG_TRACK_H: number = 28;
const SEG_PAD: number = 2;
const SEG_RADIUS: number = 7;
const SEG_TRACK_RADIUS: number = 9;
/** 表单区水平边距（iOS Form grouped inset = 页边距 20） */
const FORM_MARGIN: number = DesignTokens.MARGIN_PAGE;
/** Form 区间距（iOS Form grouped inset 相邻 section 间距近似） */
const FORM_SECTION_GAP: number = 20;

/** DNS 三模式分段项（对象字面量显式类型） */
interface DnsModeSeg {
  mode: DnsMode;
  labelKey: string;
}

/** hex 字符判定（isHexDigit 直译；0-9 a-f A-F） */
function isHexDigit(c: string): boolean {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

/**
 * DNS 配置编辑状态（iOS DNSConfig.swift 直译；加入网络 / 网络详情共用）。
 * 四槽位模型（v4×2 + v6×2），持久化时合并为 string[]。@ObservedV2 + @Trace：
 * V2 组件（本 sheet / 详情页 / DnsConfigSection）对槽位/模式字段的读写均被
 * 追踪，输入即时反映到校验提示与「应用」按钮显隐。
 */
@ObservedV2
export class DnsEditor {
  @Trace mode: DnsMode = DnsMode.None;
  @Trace v4a: string = '';
  @Trace v4b: string = '';
  @Trace v6a: string = '';
  @Trace v6b: string = '';

  constructor(mode: DnsMode = DnsMode.None, customDns: string[] = []) {
    this.mode = mode;
    // v4/v6 按是否含 ":" 区分（iOS init 直译）
    const v4 = customDns.filter((s: string): boolean => !s.includes(':'));
    const v6 = customDns.filter((s: string): boolean => s.includes(':'));
    this.v4a = v4.length > 0 ? v4[0] : '';
    this.v4b = v4.length > 1 ? v4[1] : '';
    this.v6a = v6.length > 0 ? v6[0] : '';
    this.v6b = v6.length > 1 ? v6[1] : '';
  }

  /** 自定义模式下要保存的服务器列表（空槽位丢弃，顺序 v4 在前；iOS 直译） */
  customServers(): string[] {
    const out: string[] = [];
    if (this.v4a !== '') {
      out.push(this.v4a);
    }
    if (this.v4b !== '') {
      out.push(this.v4b);
    }
    if (this.v6a !== '') {
      out.push(this.v6a);
    }
    if (this.v6b !== '') {
      out.push(this.v6b);
    }
    return out;
  }

  /** 自定义模式要求四槽位全合法且列表非空；其余模式恒合法（iOS isValid 直译） */
  isValid(): boolean {
    if (this.mode !== DnsMode.Custom) {
      return true;
    }
    const v4ok = DnsEditor.isValidIPv4OrEmpty(this.v4a)
      && DnsEditor.isValidIPv4OrEmpty(this.v4b);
    const v6ok = DnsEditor.isValidIPv6OrEmpty(this.v6a)
      && DnsEditor.isValidIPv6OrEmpty(this.v6b);
    return v4ok && v6ok && this.customServers().length > 0;
  }

  /** 全 hex 串判定（ID 校验/提取共用） */
  static isHexString(s: string): boolean {
    if (s.length === 0) {
      return false;
    }
    for (let i = 0; i < s.length; i++) {
      if (!isHexDigit(s[i])) {
        return false;
      }
    }
    return true;
  }

  /** inet_pton(AF_INET) 语义：四段 0..255、拒绝前导零与超长段 */
  static isValidIPv4(s: string): boolean {
    const parts = s.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const p of parts) {
      if (p.length === 0 || p.length > 3) {
        return false;
      }
      for (const c of p) {
        if (c < '0' || c > '9') {
          return false;
        }
      }
      if (p.length > 1 && p[0] === '0') {
        return false;
      }
      if (parseInt(p, 10) > 255) {
        return false;
      }
    }
    return true;
  }

  /** inet_pton(AF_INET6) 语义：组 1-4 位 hex；:: 压缩至多一次（压缩时总组数
   *  ≤7，无压缩时恒 8）；IPv4 尾段只允许在末位且按 2 组计 */
  static isValidIPv6(s: string): boolean {
    if (s.length === 0) {
      return false;
    }
    const halves = s.split('::');
    if (halves.length > 2) {
      return false;
    }
    const compressed = halves.length === 2;
    const head = halves[0] === '' ? [] : halves[0].split(':');
    const tail = compressed && halves[1] !== '' ? halves[1].split(':') : [];
    const groups = head.concat(tail);
    let count = 0;
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      if (g.indexOf('.') >= 0) {
        if (i !== groups.length - 1 || !DnsEditor.isValidIPv4(g)) {
          return false;
        }
        count += 2;
      } else {
        if (!DnsEditor.isHexGroup(g)) {
          return false;
        }
        count += 1;
      }
    }
    return compressed ? count <= 7 : count === 8;
  }

  private static isHexGroup(g: string): boolean {
    if (g.length < 1 || g.length > 4) {
      return false;
    }
    for (const c of g) {
      if (!isHexDigit(c)) {
        return false;
      }
    }
    return true;
  }

  private static isValidIPv4OrEmpty(s: string): boolean {
    return s === '' || DnsEditor.isValidIPv4(s);
  }

  private static isValidIPv6OrEmpty(s: string): boolean {
    return s === '' || DnsEditor.isValidIPv6(s);
  }
}

/**
 * 网络 ID 提取（iOS QRScannerView.extractNetworkId 直译）：内容本身是 16 位
 * hex 直接用；否则找首个 16 位 hex 子串（二维码里常是
 * "https://join.zerotier.com/xxxxxxxxxxxxxxxx" 之类）；无 → null 继续扫。
 */
export function extractNetworkId(value: string): string | null {
  const lowered = value.toLowerCase();
  if (lowered.length === NWID_LEN && DnsEditor.isHexString(lowered)) {
    return lowered;
  }
  for (let i = 0; i + NWID_LEN <= lowered.length; i++) {
    const seg = lowered.substring(i, i + NWID_LEN);
    if (DnsEditor.isHexString(seg)) {
      return seg;
    }
  }
  return null;
}

/**
 * DNS 配置编辑区（iOS DNSConfigSection.swift 直译；加入网络 sheet 与网络详情页
 * 共用同一布局）：模式三段 segmented + 自定义四槽位 + 校验失败提示。
 */
@ComponentV2
export struct DnsConfigSection {
  /** 编辑状态（@ObservedV2 DnsEditor；字段变更即重渲染） */
  @Param config: DnsEditor = new DnsEditor();

  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;
  /** 三模式段定义（iOS Picker 三 Text(tag:) 直译，序即源序） */
  private readonly modes: DnsModeSeg[] = [
    { mode: DnsMode.None, labelKey: 'dns.mode.none' },
    { mode: DnsMode.Network, labelKey: 'dns.mode.network' },
    { mode: DnsMode.Custom, labelKey: 'dns.mode.custom' },
  ];

  /** 分段轨底色（iOS .segmented 灰轨近似，label 色 12% 透明） */
  private segTrack(): number {
    return this.cm.dark ? 0x1FEBEBF5 : 0x1F3C3C43;
  }

  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  /** 单槽位输入（iOS TextField(key, text:) 直译；IPv4 槽位数字+小数点键盘） */
  @Builder
  slot(placeholder: string, value: string, v4Keyboard: boolean) {
    TextInput({ text: value, placeholder: placeholder })
      .fontSize(FS_BODY)
      .placeholderColor(DesignTokens.textTertiary(this.cm.dark))
      .fontColor(DesignTokens.textPrimary(this.cm.dark))
      .backgroundColor(Color.Transparent)
      .padding({ left: 0, right: 0 })
      .height(ROW_HEIGHT)
      .type(v4Keyboard ? InputType.NUMBER_DECIMAL : InputType.Normal)
      .onChange((v: string): void => {
        this.writeSlot(placeholder, v);
      })
  }

  /** 槽位写回（占位文案即 iOS TextField 的 key 身份，映射回对应槽位） */
  private writeSlot(placeholder: string, v: string): void {
    if (placeholder === this.loc('dns.v4a')) {
      this.config.v4a = v;
    } else if (placeholder === this.loc('dns.v4b')) {
      this.config.v4b = v;
    } else if (placeholder === this.loc('dns.v6a')) {
      this.config.v6a = v;
    } else if (placeholder === this.loc('dns.v6b')) {
      this.config.v6b = v;
    }
  }

  build() {
    Column({ space: 12 }) {
      // 模式分段（iOS .pickerStyle(.segmented) 直译：灰轨 + 选中白块）
      Row() {
        ForEach(this.modes, (seg: DnsModeSeg) => {
          Text(this.loc(seg.labelKey))
            .fontSize(FS_CAPTION)
            .fontWeight(this.config.mode === seg.mode ? 600 : 400)
            .fontColor(this.config.mode === seg.mode
              ? DesignTokens.textPrimary(this.cm.dark)
              : DesignTokens.textSecondary(this.cm.dark))
            .textAlign(TextAlign.Center)
            .height('100%')
            .layoutWeight(1)
            .borderRadius(SEG_RADIUS)
            .backgroundColor(this.config.mode === seg.mode
              ? DesignTokens.cardBg(this.cm.dark)
              : Color.Transparent)
            .onClick((): void => {
              this.config.mode = seg.mode;
            })
        }, (seg: DnsModeSeg) => seg.mode)
      }
      .width('100%')
      .height(SEG_TRACK_H)
      .padding(SEG_PAD)
      .borderRadius(SEG_TRACK_RADIUS)
      .backgroundColor(this.segTrack())

      if (this.config.mode === DnsMode.Custom) {
        this.slot(this.loc('dns.v4a'), this.config.v4a, true)
        this.slot(this.loc('dns.v4b'), this.config.v4b, true)
        this.slot(this.loc('dns.v6a'), this.config.v6a, false)
        this.slot(this.loc('dns.v6b'), this.config.v6b, false)
        if (!this.config.isValid()) {
          Text(this.loc('dns.invalid'))
            .fontSize(FS_CAPTION) // iOS .caption
            .fontColor(DesignTokens.danger(this.cm.dark))
            .width('100%')
        }
      }
    }
    .width('100%')
  }
}

/**
 * 加入网络 sheet 内容（宿主经 bindSheet 半模态挂载）。
 */
@ComponentV2
export struct JoinNetworkSheet {
  /** 收起回调（iOS dismiss()；宿主收起 sheet） */
  @Param onClose: () => void = () => {};

  /** 全局 UI 状态（activePlanetId 归属锚） */
  @Local app: AppState = AppState.shared;
  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;
  /** 网络 ID 输入（展示态大写；落库小写，iOS 同裁决） */
  @Local networkId: string = '';
  /** 默认路由经 ZeroTier（iOS routeViaZeroTier） */
  @Local routeViaZeroTier: boolean = false;
  /** DNS 编辑状态 */
  @Local dns: DnsEditor = new DnsEditor();
  /** 扫码层显隐 */
  @Local showScanner: boolean = false;
  /** 重复加入 alert 显隐 */
  @Local duplicateAlert: boolean = false;
  /** 重复提示用的小写 ID（iOS message 直译参数） */
  @Local duplicateId: string = '';
  /** join 在途闸（await 窗口内重复点击防御） */
  private joining: boolean = false;

  /** ID 合法性：16 位全 hex（iOS idValid 直译） */
  private idValid(): boolean {
    return this.networkId.length === NWID_LEN && DnsEditor.isHexString(this.networkId);
  }

  /** L10n 查表 + l10nSignal.rev 触踪（HomeView.loc 恒假分支惯用形） */
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

  /**
   * ID 输入回写：大写展示（iOS textInputAutocapitalization(.characters) 直译，
   * API 12 TextInput 无该属性，onChange 归一等价）；粘贴解析（brief 契约）——
   * raw 含非 hex 字符（URL/空格等）且内嵌 16 位 hex 子串时提取，纯 hex 输入
   * /粘贴恒不受影响（iOS TextField 原样收帖，本解析是其超集）。
   * 键入态直译（iOS JoinNetworkSheet.swift:37-41）：相对上一次值仅追加单个
   * 字符（满 16 位后继续敲是主场景）时保留原文，非法交给 join.idInvalid 红字，
   * 不做静默滑窗截断——否则非法字符被吞且红字消失，偏离 iOS 语义。
   */
  private onIdInput(raw: string): void {
    let v = raw.toUpperCase();
    if (!DnsEditor.isHexString(v)) {
      // 追加单字符 = 键入态（onChange 只给终值，与上一次值差分判定键入/粘贴）
      const prev = this.networkId;
      const typedAppend = v.length === prev.length + 1 && v.startsWith(prev);
      if (!typedAppend) {
        const hit = extractNetworkId(v);
        if (hit !== null) {
          v = hit.toUpperCase();
        }
      }
    }
    this.networkId = v;
  }

  /** 扫码回调：识别二维码中的网络 ID 填入（iOS :27-35 注释直译）；无法解析出
   *  ID 时留在扫码层继续（iOS extract 返回 nil → 继续扫同语义）。回填原文
   *  （extractNetworkId 返回小写原文，iOS `networkId = id` 直译——iOS 只键盘
   *  大写化，程序回填不过键盘、显示原文；后续键入经 onChange 归一大写） */
  private onScanned(text: string): void {
    const hit = extractNetworkId(text);
    if (hit === null) {
      return;
    }
    this.networkId = hit;
    // 回填 ID 并停留在加入弹窗，只关闭扫码层（iOS :70-72 注释直译）
    this.showScanner = false;
  }

  /** 加入（iOS join() 直译）：查重 → 构造条目（仅保存不自动连接）→ upsert +
   *  fireConfig → 收起 */
  private async join(): Promise<void> {
    if (this.joining || !this.idValid() || !this.dns.isValid()) {
      return;
    }
    this.joining = true;
    try {
      const newId = this.networkId.toLowerCase();
      // 归属锚定活跃行星（控制器裁决 3；iOS 写 selectedPlanetId，裁决改锚）
      const planetId = this.app.activePlanetId;
      const store = StoreRepo.store;
      const nets = await store.readNetworks(planetId);
      // 网络 ID 查重：已存在视为同一网络，禁止重复添加（iOS :80-84 直译）
      if (nets.some((n: NetworkEntry): boolean => n.networkId === newId)) {
        this.duplicateId = newId;
        this.duplicateAlert = true;
        return;
      }
      // 仅保存不自动连接，由用户手动打开开关（iOS :85-91 直译）
      nets.push(new NetworkEntry(newId, newId, false, this.routeViaZeroTier,
        this.dns.mode,
        this.dns.mode === DnsMode.Custom ? this.dns.customServers() : [], planetId));
      // writeNetworks 整组替换 + fireConfig（configChanged 监听 + CONFIG_CHANGED
      // 唤醒 VpnExt 热重读）——「networks upsert + fireConfig」契约；存量 null
      // planetId 条目不做迁移扫描（裁决 3）
      await store.writeNetworks(nets, planetId);
      this.onClose();
    } finally {
      this.joining = false;
    }
  }

  /** 导航行（iOS toolbar cancellationAction/confirmationAction 直译） */
  @Builder
  navBar() {
    Row() {
      Text(this.loc('common.cancel'))
        .fontSize(FS_BODY)
        .fontColor(themeSignal.accent)
        .onClick((): void => this.onClose())
        .padding({ left: 12, top: 12, bottom: 12, right: 4 })
      Text(this.loc('join.title'))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Text(this.loc('join.action'))
        .fontSize(FS_BODY)
        .fontWeight(600)
        .fontColor(themeSignal.accent)
        .opacity(this.idValid() && this.dns.isValid() ? 1 : 0.35) // .disabled 直译
        .onClick((): void => void this.join())
        .padding({ right: 12, top: 12, bottom: 12, left: 4 })
    }
    .width('100%')
    .height(48)
  }

  /** 区头（iOS Form Section header：小号灰字） */
  @Builder
  sectionHeader(key: string) {
    Text(this.loc(key))
      .fontSize(FS_SECTION_HEADER) // iOS .caption2
      .fontColor(DesignTokens.textSecondary(this.cm.dark))
      .width('100%')
      .padding({ left: FORM_MARGIN, right: FORM_MARGIN, bottom: 4 })
  }

  /** 区脚（iOS Form Section footer：小号灰字说明） */
  @Builder
  sectionFooter(key: string) {
    Text(this.loc(key))
      .fontSize(FS_CAPTION) // iOS .caption
      .fontColor(DesignTokens.textSecondary(this.cm.dark))
      .width('100%')
      .padding({ left: FORM_MARGIN, right: FORM_MARGIN, top: 6 })
  }

  build() {
    Stack() {
      Column() {
        this.navBar()
        Scroll() {
          Column({ space: FORM_SECTION_GAP }) {
            // ---- 网络 ID 区（iOS Section("network.id") 直译）----
            Column() {
              this.sectionHeader('network.id')
              // 卡片壳（iOS Form inset 卡）
              Column() {
                Row({ space: 8 }) {
                  TextInput({ text: this.networkId, placeholder: this.loc('join.idPlaceholder') })
                    .fontSize(FS_BODY)
                    .placeholderColor(DesignTokens.textTertiary(this.cm.dark))
                    .fontColor(DesignTokens.textPrimary(this.cm.dark))
                    .fontFamily(DesignTokens.FONT_MONO) // iOS design: .monospaced
                    .backgroundColor(Color.Transparent)
                    .padding({ left: 0, right: 0 })
                    .height(ROW_HEIGHT)
                    .layoutWeight(1)
                    .onChange((raw: string): void => this.onIdInput(raw))
                  // 输入框尾部扫码按钮：识别二维码中的网络 ID 填入（iOS :27 注释直译）
                  SymbolGlyph($r('sys.symbol.qrcode'))
                    .fontSize(20)
                    .fontColor([themeSignal.accent])
                    .padding(8)
                    .onClick((): void => {
                      this.showScanner = true;
                    })
                    .accessibilityText(this.loc('join.a11yScan'))
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                if (this.networkId !== '' && !this.idValid()) {
                  Text(this.loc('join.idInvalid'))
                    .fontSize(FS_CAPTION)
                    .fontColor(DesignTokens.danger(this.cm.dark))
                    .width('100%')
                    .padding({ top: 2, bottom: 6 })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
              .backgroundColor(DesignTokens.cardBg(this.cm.dark))
              .borderRadius(DesignTokens.RADIUS_SM)
              .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
            }
            .width('100%')

            // ---- 默认路由区（iOS Section { Toggle } footer 直译）----
            Column() {
              Column() {
                Row() {
                  Text(this.loc('join.routeVia'))
                    .fontSize(FS_BODY)
                    .fontColor(DesignTokens.textPrimary(this.cm.dark))
                  Blank()
                  Toggle({ type: ToggleType.Switch, isOn: this.routeViaZeroTier })
                    .onChange((on: boolean): void => {
                      this.routeViaZeroTier = on;
                    })
                }
                .width('100%')
                .height(ROW_HEIGHT)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
              .backgroundColor(DesignTokens.cardBg(this.cm.dark))
              .borderRadius(DesignTokens.RADIUS_SM)
              .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
              this.sectionFooter('join.routeViaFooter')
            }
            .width('100%')

            // ---- DNS 区（iOS Section("DNS") 直译）----
            Column() {
              this.sectionHeader('DNS')
              Column() {
                DnsConfigSection({ config: this.dns })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor(DesignTokens.cardBg(this.cm.dark))
              .borderRadius(DesignTokens.RADIUS_SM)
              .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
            }
            .width('100%')
          }
          .width('100%')
          .padding({ top: 8, bottom: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')

      // 重复加入 alert（iOS .alert(join.duplicateTitle) 直译）：AppAlert 宿主
      // （遮罩/卡片转场由 AppAlert 内部分层挂接，宿主只管 if 出入）
      if (this.duplicateAlert) {
        AppAlert({
          title: this.loc('join.duplicateTitle'),
          message: this.locFmt('join.duplicateMessage %@', [this.duplicateId]),
          buttons: [new AppAlertButton(this.loc('common.ok'), false, (): void => {
            this.duplicateAlert = false;
          })],
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.pageBg(this.cm.dark))
    // 扫码层（iOS .sheet(isPresented: $showScanner) 直译）
    .bindSheet(this.showScanner, (): void => {
      QrScannerSheet({
        onScanned: (text: string): void => this.onScanned(text),
        onClose: (): void => {
          this.showScanner = false;
        },
      })
    }, {
      height: SheetSize.LARGE,
      dragBar: false,
      showClose: false, // iOS sheet 无系统关闭钮（取消走 QrScannerSheet 头部）
      backgroundColor: DesignTokens.pageBg(this.cm.dark),
      onWillDismiss: (_action: DismissSheetAction): void => {
        this.showScanner = false;
      },
    })
  }
}
