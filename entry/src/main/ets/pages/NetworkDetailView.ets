// NetworkDetailView.ets — 网络详情页（静态 + 实时配置合并展示；iOS 341 行直译）
//
// 直译源：iOS NetworkDetailView.swift（ID/名称/状态/类型/MAC/MTU/广播/桥接行 +
// 地址列表编号标签 + 路由列表 via 网关点击切换 + DNS 三模式段 + 默认路由开关
// 多网络锁定 + 删除行锚定气泡）+ DNSConfigSection.swift（三模式形态，组件复用）。
//
// PageNetworkDetail 单字段裁决收口（T5 契约 + 控制器裁决 2）：页面入参只有
// networkId，行星归属由消费方经 AppState 推断——本页 aboutToAppear 时快照
// AppState.shared.activePlanetId 为 anchorPlanetId，此后所有读数一律
// readNetworks(anchorPlanetId) 过滤，绝不跨行星聚合同名 networkId
// （不同行星可加入同 ID 网络，聚合同名条目会数据串台）；实时快照只对隧道
// 行星有意义，netConf() 以 anchorPlanetId === activePlanetId 门控
// （iOS refresh() 的行星守卫直译），门关时详情区统一 "—"。
// 删除锚定气泡（iOS ConfirmBubble + GlobalAnchorReader 直译）：删除行
// onAreaChange 持续上报全局 y（GlobalAnchorReader 对应物），宿主层根节点同步
// 上报自身全局 y，锚定换算全部在 ConfirmBubble 内完成。
// DNS / 默认路由写回：store.writeNetworks 整组替换并内部 fireConfig
// （CONFIG_CHANGED 唤醒 VpnExt 热重读，DNS 运行中热生效不断连——footer 文案
// 承诺的语义由 VpnExt applyConfigChange 增量重配承载，无需 CMD_RESTART 换代）；
// 删除走 store.deleteNetwork，删空启用网络时停隧道（iOS stopVPNIfNoActiveNetworks
// 直译）。多网软上限 alert 只存在于激活路径（HomeView 开关侧），本页无。
import { image } from '@kit.ImageKit';
import { AppNav } from '../ui/AppRoot';
import { AppState } from '../ui/AppState';
import { StoreRepo } from '../store/StoreRepo';
import { DnsMode, NetworkEntry, PlanetProfile } from '../store/Models';
import { NetConfSnapshot, TunnelSnapshot } from '../common/TunnelContract';
import { StatusStore } from '../tunnel/StatusStore';
import { TunnelController } from '../tunnel/TunnelController';
import { L10n, l10nSignal } from '../components/L10n';
import { DesignTokens, colorModeSignal, ColorModeSignal } from '../components/DesignTokens';
import { themeSignal } from '../store/ThemeManager';
import { CopyableValue } from '../components/CopyableValue';
import { ztStatusKey, ZT_STATUS_REQUESTING_CONFIGURATION } from '../components/NetworkCardView';
import { ConfirmBubble } from '../components/ConfirmBubble';
import { DnsEditor, DnsConfigSection } from '../components/JoinNetworkSheet';
import { QRRender } from '../qrtransfer/QRRender';

/** 表单字号（iOS .body 17 / .footnote 13 / .caption2 11） */
const FS_BODY: number = 17;
const FS_FOOTNOTE: number = 13;
const FS_SECTION_HEADER: number = 11;
/** 表单行高（iOS Form 行标准 44pt） */
const ROW_HEIGHT: number = 44;
/** 表单区水平边距（iOS Form grouped inset = 页边距 20） */
const FORM_MARGIN: number = DesignTokens.MARGIN_PAGE;
/** Form 区间距（iOS Form grouped inset 相邻 section 间距近似） */
const FORM_SECTION_GAP: number = 20;
/** 路由行 via 切换图标（iOS arrow.left.arrow.right 11pt） */
const FS_VIA_ICON: number = 11;
/** ID 行二维码图标（iOS 15 medium） */
const FS_QR_ICON: number = 15;
/** QR 分享出图边长（iOS 200×200） */
const QR_SIZE_PX: number = 200;
/** 气泡转场（iOS .opacity + .scale(0.95, anchor: .bottom) + easeOut 0.15 直译） */
const BUBBLE_TRANSITION: TransitionEffect = TransitionEffect.OPACITY
  .combine(TransitionEffect.scale({ x: 0.95, y: 0.95, centerX: '50%', centerY: '100%' }))
  .animation({ duration: 150, curve: Curve.EaseOut });

@ComponentV2
export struct NetworkDetailView {
  /** 页面入参（T5 契约：单字段；归属见文件头单字段裁决） */
  @Param networkId: string = '';

  /** 全局 UI 状态（vpnRunning/pathSatisfied/online/activePlanetId 触踪） */
  @Local app: AppState = AppState.shared;
  /** 深浅色触踪 */
  @Local cm: ColorModeSignal = colorModeSignal;
  /** 隧道快照（实时配置投影源；整体替换触踪） */
  @Local snap: TunnelSnapshot | null = StatusStore.current();
  /** 归属行星的网络条目（readNetworks(anchorPlanetId) 按本 ID 过滤） */
  @Local entry: NetworkEntry | null = null;
  /** DNS 编辑状态（entry 首次载入时初始化一次，此后不随 configChanged 覆写） */
  @Local dns: DnsEditor = new DnsEditor();
  /** 已切到 via 网关视图的路由下标（点击值区域切换；整体替换触踪） */
  @Local viaExpandedRoutes: Set<number> = new Set<number>();
  /** 默认路由开关是否锁定（多网同时连接唯一性无解；reloadEntry 派生） */
  @Local routeViaLocked: boolean = false;
  /** 删除行全局 y（onAreaChange 上报；气泡锚点） */
  @Local deleteAnchorY: number = 0;
  /** 宿主层根节点全局 y（iOS geo.frame(in: .global).minY 对应物；满幅恒 0） */
  @Local layerTopY: number = 0;
  @Local showDeleteBubble: boolean = false;
  @Local showQR: boolean = false;
  /** QR 位图（出图失败保持 null：降级只展示名称与 ID） */
  @Local qrPixels: image.PixelMap | null = null;

  /** 归属行星（跨入时快照 activePlanetId；单字段裁决收口，见文件头） */
  private anchorPlanetId: string = PlanetProfile.OFFICIAL_ID;
  /** DNS 编辑器仅初始化一次的闸（iOS onAppear 同语义） */
  private dnsInited: boolean = false;
  private unsubSnap: (() => void) | null = null;
  private unsubCfg: (() => void) | null = null;

  aboutToAppear(): void {
    this.anchorPlanetId = this.app.activePlanetId;
    this.unsubSnap = StatusStore.subscribe((s: TunnelSnapshot | null) => {
      this.snap = s;
    });
    this.unsubCfg = StoreRepo.store.onConfigChanged(() => void this.reloadEntry());
    void this.reloadEntry();
  }

  aboutToDisappear(): void {
    if (this.unsubSnap !== null) {
      this.unsubSnap();
      this.unsubSnap = null;
    }
    if (this.unsubCfg !== null) {
      this.unsubCfg();
      this.unsubCfg = null;
    }
    this.releaseQr();
  }

  // ---- 数据域 ----

  /** 归属行星条目重读 + 锁定派生 + DNS 首载（configChanged / 跨入共用） */
  private async reloadEntry(): Promise<void> {
    const nets = await StoreRepo.store.readNetworks(this.anchorPlanetId);
    this.entry = nets.find((n: NetworkEntry): boolean => n.networkId === this.networkId)
      ?? null;
    // 多网同时连接时默认路由的唯一性无解，锁定开关（iOS routeViaLocked 直译：
    // 只有隧道行星下才存在"同时连接"的其他网络）
    this.routeViaLocked = this.anchorPlanetId === this.app.activePlanetId
      && nets.some((n: NetworkEntry): boolean =>
        n.networkId !== this.networkId && n.lastActivated);
    if (!this.dnsInited && this.entry !== null) {
      this.dns = new DnsEditor(this.entry.dnsMode, this.entry.customDns);
      this.dnsInited = true;
    }
  }

  /** 实时配置快照（iOS snapshot 直译）：只对隧道行星的网络有意义（iOS refresh
   *  的行星守卫直译）——不同行星可能加入同 ID 网络，非隧道行星不消费，避免串台 */
  private netConf(): NetConfSnapshot | null {
    if (this.anchorPlanetId !== this.app.activePlanetId) {
      return null;
    }
    const s = this.snap;
    if (s === null) {
      return null;
    }
    const hit = s.networkConfigs.find(
      (c: NetConfSnapshot): boolean => c.nwid === this.networkId);
    return hit === undefined ? null : hit;
  }

  /** 详情区状态行（iOS :25-31 直译）：无快照 "—"；物理断网显示"无网络"；
   *  REQUESTING_CONFIGURATION 按 online 分段（连接服务器/请求网络配置） */
  private statusText(): string {
    const cfg = this.netConf();
    if (cfg === null) {
      return '—';
    }
    if (this.app.vpnRunning && !this.app.pathSatisfied) {
      return this.loc('status.noNetwork');
    }
    if (cfg.status === ZT_STATUS_REQUESTING_CONFIGURATION) {
      return this.loc(this.app.online
        ? 'network.status.requestingConfig'
        : 'network.status.connectingServer');
    }
    return this.loc(ztStatusKey(cfg.status));
  }

  /** 名称（iOS :22 直译）：实时快照名优先，回退本地条目名 */
  private nameText(): string {
    const cfg = this.netConf();
    if (cfg === null) {
      return this.entry !== null ? this.entry.networkName : '—';
    }
    return cfg.name;
  }

  /** MAC 展示：隧道进程传 48 位数值，UI 层格式化 aa:bb:cc:dd:ee:ff
   *  （iOS :172-188 注释直译；快照契约 mac 为 JSON 数值，见 TunnelRuntime.cpp） */
  private macText(): string {
    const cfg = this.netConf();
    if (cfg === null) {
      return '—';
    }
    return NetworkDetailView.formatMAC(cfg.mac);
  }

  /** 48 位数值 MAC → 小写 12 位 hex 分组（aa:bb:cc:dd:ee:ff）；取位循环与
   *  MoonEntry.formatWorldId 同构（双精度 <2^53 精确，域外截断防御） */
  static formatMAC(mac: number): string {
    let v = Math.floor(mac);
    if (!Number.isFinite(v) || v < 0) {
      return '—';
    }
    if (v > 0xFFFFFFFFFFFF) {
      v = v % 0x1000000000000;
    }
    let hex = '';
    while (hex.length < 12) {
      hex = (v % 16).toString(16) + hex;
      v = Math.floor(v / 16);
    }
    let out = '';
    for (let i = 0; i < 12; i += 2) {
      out += i > 0 ? ':' : '';
      out += hex.substring(i, i + 2);
    }
    return out;
  }

  /** 地址列表（无快照 → 空列表渲染 "—" 占位行） */
  private assignedAddrs(): string[] {
    const cfg = this.netConf();
    return cfg === null ? [] : cfg.assignedAddrs;
  }

  /** 路由列表 */
  private routes(): string[] {
    const cfg = this.netConf();
    return cfg === null ? [] : cfg.routes;
  }

  /** 网络模式下的 ZT 下发 DNS 服务器列表 */
  private dnsServers(): string[] {
    const cfg = this.netConf();
    return cfg === null ? [] : cfg.dns;
  }

  /** "192.168.8.0/24 via 152.124.13.2" → "192.168.8.0/24"（iOS RouteRow 直译） */
  private routeTarget(route: string): string {
    const parts = route.split(' via ');
    return parts[0];
  }

  /** via 网关；null = 直连路由不可切换、不显示图标 */
  private routeVia(route: string): string | null {
    const parts = route.split(' via ');
    return parts.length > 1 ? parts[1] : null;
  }

  private toggleVia(index: number): void {
    const next = new Set<number>(this.viaExpandedRoutes);
    if (next.has(index)) {
      next.delete(index);
    } else {
      next.add(index);
    }
    this.viaExpandedRoutes = next; // 整体替换触踪（@Local Set 不追踪成员变更）
  }

  /** 编辑中的 DNS 与已保存配置是否存在差异（iOS dnsDirty 直译） */
  private dnsDirty(): boolean {
    const e = this.entry;
    if (e === null) {
      return false;
    }
    if (this.dns.mode !== e.dnsMode) {
      return true;
    }
    const saved = e.customDns;
    const cur = this.dns.customServers();
    if (saved.length !== cur.length) {
      return true;
    }
    for (let i = 0; i < saved.length; i++) {
      if (saved[i] !== cur[i]) {
        return true;
      }
    }
    return false;
  }

  // ---- 写回域 ----

  /** DNS 应用（iOS applyDNS 直译）：写回归属行星 + fireConfig 热重配（VpnExt
   *  增量重配不断连）；写盘即 fireConfig，无需显式通知 */
  private async applyDns(): Promise<void> {
    if (!this.dns.isValid()) {
      return;
    }
    const store = StoreRepo.store;
    const nets = await store.readNetworks(this.anchorPlanetId);
    const target = nets.find((n: NetworkEntry): boolean => n.networkId === this.networkId);
    if (target === undefined) {
      return;
    }
    target.dnsMode = this.dns.mode;
    target.customDns = this.dns.mode === DnsMode.Custom ? this.dns.customServers() : [];
    await store.writeNetworks(nets, this.anchorPlanetId);
  }

  /** 默认路由开关写回（iOS updateRouteViaZeroTier 直译）：UI 只落开关值，
   *  多网数据面/控制面双侧拦截归隧道侧 RoutePlanner 既有能力 */
  private async updateRouteVia(on: boolean): Promise<void> {
    const store = StoreRepo.store;
    const nets = await store.readNetworks(this.anchorPlanetId);
    const target = nets.find((n: NetworkEntry): boolean => n.networkId === this.networkId);
    if (target === undefined) {
      // 列表与盘面错位（外部删除在途）：吞掉本次拨动；本分支不触发 reloadEntry，
      // 对齐依赖外部删除方 writeNetworks→fireConfig→onConfigChanged→reloadEntry 回流
      return;
    }
    target.routeViaZeroTier = on;
    await store.writeNetworks(nets, this.anchorPlanetId);
  }

  /** 删除（iOS deleteNetwork 直译）：store.deleteNetwork（内部 fireConfig）→
   *  删掉的是最后一个启用的网络时 VPN 随之关闭不空跑 → pop 返回 */
  private async deleteNetwork(): Promise<void> {
    await StoreRepo.store.deleteNetwork(this.networkId, this.anchorPlanetId);
    const active = await StoreRepo.store.readActiveNetworks();
    if (!active.some((n: NetworkEntry): boolean => n.lastActivated)) {
      await TunnelController.stop();
    }
    AppNav.pop();
  }

  // ---- QR 分享（iOS NetworkQRSheet 直译：内容 = 网络 ID 纯文本）----

  /** render 在途闸：前次渲染未完成时忽略重复触发（iOS sheet 模态天然单飞——
   *  sheet 打开后入口被覆盖不可再点；无闸时前次结果会被后完成者覆盖且不
   *  release，泄漏一张位图） */
  private qrRendering: boolean = false;

  private async openQr(): Promise<void> {
    if (this.qrRendering) {
      return;
    }
    this.qrRendering = true;
    this.releaseQr();
    this.qrPixels = null;
    this.showQR = true;
    try {
      this.qrPixels = await QRRender.render(this.networkId, QR_SIZE_PX);
    } catch (_e) {
      // 无 generateBarcode 服务（host/模拟器）：降级只展示名称与 ID（iOS
      // qrImage 出图返回 nil 不渲染 Image 同语义）
    } finally {
      this.qrRendering = false;
    }
  }

  private releaseQr(): void {
    const pm = this.qrPixels;
    if (pm !== null) {
      void pm.release().catch(() => {});
      this.qrPixels = null;
    }
  }

  /** QR 分享名（iOS :325 直译）：快照名优先、条目名次之、最后回退 ID */
  private qrName(): string {
    const cfg = this.netConf();
    const snapName = cfg !== null ? cfg.name : '';
    const name = snapName !== '' ? snapName
      : (this.entry !== null ? this.entry.networkName : '');
    return name !== '' ? name : this.networkId;
  }

  // ---- 文案域 ----

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

  // ---- 渲染 ----

  build() {
    Stack() {
      Column() {
        this.titleBar()
        Scroll() {
          Column({ space: FORM_SECTION_GAP }) {
            this.identitySection()
            this.addrsSection()
            this.routesSection()
            this.dnsSection()
            this.routeViaSection()
            this.deleteSection()
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

      // 删除确认锚定气泡（iOS .overlay ZStack 直译；转场在宿主挂接）
      if (this.showDeleteBubble) {
        ConfirmBubble({
          anchorY: this.deleteAnchorY,
          layerTopY: this.layerTopY,
          titleKey: 'network.delete.confirmTitle',
          messageKey: 'network.delete.confirmMessage',
          confirmKey: 'network.delete',
          onConfirm: (): void => {
            this.showDeleteBubble = false;
            void this.deleteNetwork();
          },
          onDismiss: (): void => {
            this.showDeleteBubble = false;
          },
        })
          .transition(BUBBLE_TRANSITION)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.pageBg(this.cm.dark))
    // 宿主层全局 y（iOS geo.frame(in: .global).minY 对应物；锚定换算输入）
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.layerTopY = newValue.globalPosition.y as number;
    })
    // QR 分享 sheet（iOS .sheet(isPresented: $showQR) + .medium detent 直译）
    .bindSheet(this.showQR, (): void => {
      this.qrSheetContent()
    }, {
      height: SheetSize.MEDIUM,
      showClose: false,
      backgroundColor: DesignTokens.pageBg(this.cm.dark),
      onWillDismiss: (_action: DismissSheetAction): void => {
        this.showQR = false;
      },
    })
  }

  /** 自绘标题栏（T5 骨架沿用：返回热区 44×44 + 标题居中 + 右平衡占位） */
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
      Text(this.loc('network.detailTitle'))
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
      .fontSize(FS_FOOTNOTE) // iOS .footnote（详情页 footer 与加入 sheet 略异，
      //  iOS 此处用 Section footer 默认字号）
      .fontColor(DesignTokens.textSecondary(this.cm.dark))
      .width('100%')
      .padding({ left: FORM_MARGIN, right: FORM_MARGIN, top: 6 })
  }

  /** 静态行（iOS row(_, _) 直译）：标题 + 右对齐次要等宽值 */
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
    }
    .width('100%')
    .height(ROW_HEIGHT)
  }

  /** 静态信息卡（iOS Section 直译）：ID/名称/状态/类型/MAC/MTU/广播/桥接 */
  @Builder
  identitySection() {
    Column() {
      this.sectionHeader('network.id')
      Column() {
        // 网络 ID 行：点击复制（无常驻图标，仅二维码入口，避免双图标；iOS :153-169）
        Row() {
          Text(this.loc('network.id'))
            .fontSize(FS_BODY)
            .fontColor(DesignTokens.textPrimary(this.cm.dark))
          Blank()
          CopyableValue({
            text: this.networkId,
            showsIcon: false,
            color: DesignTokens.textSecondary(this.cm.dark),
          })
          SymbolGlyph($r('sys.symbol.qrcode'))
            .fontSize(FS_QR_ICON)
            .fontWeight(500)
            .fontColor([DesignTokens.textTertiary(this.cm.dark)])
            .onClick((): void => void this.openQr())
            .padding(8)
            .accessibilityText(this.loc('qrcode.title'))
        }
        .width('100%')
        .height(ROW_HEIGHT)
        this.row(this.loc('common.name'), this.nameText())
        this.row(this.loc('common.status'), this.statusText())
        this.row(this.loc('common.type'),
          this.netConf() === null ? '—' : (this.netConf() as NetConfSnapshot).type)
        // MAC（iOS CopyableRow 直译：值可复制）
        Row() {
          Text('MAC')
            .fontSize(FS_BODY)
            .fontColor(DesignTokens.textPrimary(this.cm.dark))
          Blank()
          CopyableValue({
            text: this.macText(),
            color: DesignTokens.textSecondary(this.cm.dark),
          })
        }
        .width('100%')
        .height(ROW_HEIGHT)
        this.row('MTU',
          this.netConf() === null ? '—' : String((this.netConf() as NetConfSnapshot).mtu))
        this.row(this.loc('network.broadcast'), this.netConf() === null ? '—'
          : ((this.netConf() as NetConfSnapshot).broadcastEnabled
            ? this.loc('common.allowed')
            : this.loc('common.forbidden')))
        this.row(this.loc('network.bridge'), this.netConf() === null ? '—'
          : ((this.netConf() as NetConfSnapshot).bridge
            ? this.loc('common.yes')
            : this.loc('common.no')))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
    }
    .width('100%')
  }

  /** 托管地址区（iOS Section("network.assignedAddrs") 直译）：编号标签 + 可复制 */
  @Builder
  addrsSection() {
    Column() {
      this.sectionHeader('network.assignedAddrs')
      Column() {
        if (this.assignedAddrs().length === 0) {
          this.row(this.loc('network.addr'), '—')
        } else {
          ForEach(this.assignedAddrs(), (addr: string, index: number) => {
            Row() {
              Text(this.locFmt('network.addrLabel %lld', [index + 1]))
                .fontSize(FS_BODY)
                .fontColor(DesignTokens.textPrimary(this.cm.dark))
              Blank()
              CopyableValue({
                text: addr,
                color: DesignTokens.textSecondary(this.cm.dark),
              })
            }
            .width('100%')
            .height(ROW_HEIGHT)
          }, (addr: string) => addr)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
    }
    .width('100%')
  }

  /** 路由行（iOS RouteRow 直译）：默认显示目标网段，直连路由不可切换；
   *  有 via 网关时点击值区域切换为 "via 网关" 视图（图标仅作可切换暗示，
   *  值文字与其它行同色不用主色——iOS :285 注释直译） */
  @Builder
  routeRow(index: number, route: string) {
    Row() {
      Text(this.locFmt('network.routeLabel %lld', [index + 1]))
        .fontSize(FS_BODY)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
      Blank()
      if (this.routeVia(route) !== null) {
        Row({ space: 4 }) {
          Text(this.viaExpandedRoutes.has(index)
            ? `via ${this.routeVia(route) as string}`
            : this.routeTarget(route))
            .fontSize(FS_BODY)
            .fontFamily(DesignTokens.FONT_MONO)
            .fontColor(DesignTokens.textSecondary(this.cm.dark))
            .maxLines(1)
          SymbolGlyph($r('sys.symbol.arrow_left_arrow_right'))
            .fontSize(FS_VIA_ICON)
            .fontColor([DesignTokens.textSecondary(this.cm.dark)])
        }
        .alignItems(VerticalAlign.Center)
        .onClick((): void => this.toggleVia(index))
        .accessibilityText(this.loc('network.managedRoutes'))
        .accessibilityDescription(route)
      } else {
        Text(this.routeTarget(route))
          .fontSize(FS_BODY)
          .fontFamily(DesignTokens.FONT_MONO)
          .fontColor(DesignTokens.textSecondary(this.cm.dark))
          .maxLines(1)
      }
    }
    .width('100%')
    .height(ROW_HEIGHT)
  }

  /** 托管路由区（iOS Section("network.managedRoutes") 直译）：id 用下标，
   *  路由字符串可能重复且展开状态按下标追踪 */
  @Builder
  routesSection() {
    Column() {
      this.sectionHeader('network.managedRoutes')
      Column() {
        if (this.routes().length === 0) {
          this.row(this.loc('network.route'), '—')
        } else {
          ForEach(this.routes(), (route: string, index: number) => {
            this.routeRow(index, route)
          }, (route: string, index: number) => `${index}:${route}`)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
    }
    .width('100%')
  }

  /** DNS 区（iOS :71-93 直译）：三模式段 + 网络模式只读服务器列表 +
   *  显式"应用"确认（改 DNS 热重配隧道，不做静默生效） */
  @Builder
  dnsSection() {
    Column() {
      this.sectionHeader('DNS')
      Column({ space: 8 }) {
        DnsConfigSection({ config: this.dns })
        // 网络模式下 ZT 下发的服务器只读展示，与自定义输入区分（iOS :73-81）
        if (this.dns.mode === DnsMode.Network) {
          if (this.dnsServers().length > 0) {
            ForEach(this.dnsServers(), (server: string) => {
              Text(server)
                .fontSize(FS_BODY)
                .fontFamily(DesignTokens.FONT_MONO)
                .fontColor(DesignTokens.textPrimary(this.cm.dark))
                .width('100%')
                .maxLines(1)
            }, (server: string) => server)
          } else {
            Text(this.loc('network.dnsPending'))
              .fontSize(FS_BODY)
              .fontColor(DesignTokens.textSecondary(this.cm.dark))
              .width('100%')
          }
        }
        if (this.dnsDirty()) {
          Text(this.loc('network.applyDns'))
            .fontSize(FS_BODY)
            .fontColor(themeSignal.accent)
            .opacity(this.dns.isValid() ? 1 : 0.35) // .disabled(!dns.isValid) 直译
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .onClick((): void => void this.applyDns())
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
      this.sectionFooter('network.dnsFooter')
    }
    .width('100%')
  }

  /** 默认路由区（iOS :94-105 直译）：多网锁定时禁用 + 锁定文案 */
  @Builder
  routeViaSection() {
    Column() {
      Column() {
        Row() {
          Text(this.loc('network.routeVia'))
            .fontSize(FS_BODY)
            .fontColor(DesignTokens.textPrimary(this.cm.dark))
          Blank()
          Toggle({
            type: ToggleType.Switch,
            isOn: this.entry !== null ? this.entry.routeViaZeroTier : false,
          })
            // iOS .disabled(routeViaLocked) 直译：ArkUI 禁用态入口是 enabled 反向
            .enabled(!this.routeViaLocked)
            .onChange((on: boolean): void => void this.updateRouteVia(on))
        }
        .width('100%')
        .height(ROW_HEIGHT)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
      if (this.routeViaLocked) {
        this.sectionFooter('network.routeVia.lockedFooter')
      } else {
        this.sectionFooter('network.routeVia.footer')
      }
    }
    .width('100%')
  }

  /** 删除区（iOS :106-117 直译）：红字居中 + onAreaChange 上报锚点 + 点击弹
   *  锚定气泡（ConfirmBubble 锚定本行顶边） */
  @Builder
  deleteSection() {
    Column() {
      Column() {
        Text(this.loc('network.delete'))
          .fontSize(FS_BODY)
          .fontColor(DesignTokens.danger(this.cm.dark))
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(ROW_HEIGHT)
          // 锚点上报（iOS GlobalAnchorReader 对应物）：布局/滚动变化持续上报
          .onAreaChange((_oldValue: Area, newValue: Area) => {
            this.deleteAnchorY = newValue.globalPosition.y as number;
          })
          .onClick((): void => {
            this.showDeleteBubble = true;
          })
          .accessibilityText(this.loc('network.delete'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(DesignTokens.cardBg(this.cm.dark))
      .borderRadius(DesignTokens.RADIUS_SM)
      .margin({ left: FORM_MARGIN, right: FORM_MARGIN })
    }
    .width('100%')
  }

  /** QR 分享 sheet 内容（iOS NetworkQRSheet 直译）：二维码（内容 = 网络 ID
   *  纯文本，与 App 内扫码填 ID 互逆）+ 名称 + ID（点击/图标均可复制） */
  @Builder
  qrSheetContent() {
    Column({ space: 16 }) {
      Text(this.loc('qrcode.title'))
        .fontSize(17)
        .fontWeight(600)
        .fontColor(DesignTokens.textPrimary(this.cm.dark))
      if (this.qrPixels !== null) {
        Image(this.qrPixels)
          .width(QR_SIZE_PX)
          .height(QR_SIZE_PX)
          .interpolation(ImageInterpolation.None) // iOS .interpolation(.none)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      }
      Column({ space: 6 }) {
        Text(this.qrName())
          .fontSize(FS_BODY)
          .fontWeight(600) // iOS .subheadline.weight(.semibold)
          .fontColor(DesignTokens.textPrimary(this.cm.dark))
          .maxLines(1)
        CopyableValue({
          text: this.networkId,
          fontSize: FS_FOOTNOTE, // iOS .footnote mono
          color: DesignTokens.textSecondary(this.cm.dark),
          iconSize: 9,
        })
      }
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(DesignTokens.pageBg(this.cm.dark))
  }
}
