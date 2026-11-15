// HomeView.ets — 首页：Swiper 分页 + 头区 + 视差背景 + FAB + 行星/网络卡（A5-T7）
//
// 直译源：iOS HomeView.swift:80-108（层级）/196-336（头区与圆点）/342-383
// （行星页）/415-434（计数行分桶）+ Android HomeView.kt（分页三时机的同构
// 映射范式）+ Android HomeViewModel.kt setNetworkActive/deactivate/activate
// （开关编排）。
//
// 层级（iOS .overlay 链直译）：视差背景（最底）→ Swiper 分页 → 头区（顶部
// overlay，页面内容从其下方滚过）→ FAB overlay → 弹窗宿主（T12 落）。
// 分页三时机（计划 Global Constraints ③直译拆解）：
//   落位提交选中（iOS settledPage）→ Swiper .onAnimationEnd：写
//   AppState.shared.pagerSelection（@ObservedV2 @Trace 直接赋值）+
//   AppConfigStore.selectPlanet 同步持久化（iOS onChange(of: pagerSelection)
//   → app.selectPlanet 直译）；
//   过半驱动 chip（iOS currentPage）→ Swiper .onChange（browsingIdx，chip
//   动画与页面滑动同步起；settledPage 要等停稳才翻转，chip 会滞后半页）；
//   旁页不销毁（beyondViewportPageCount）→ Swiper .cachedCount 全保活。
// T7 插槽：行星身份卡（PlanetCardView）+ 网络卡列表/空态（NetworkCardView）+
// 开关编排（setNetworkActive：开关即连接，Android HomeViewModel 直译；pending
// 转圈由快照回流驱动）；FAB 点击（JoinNetworkSheet，T9）。
// T12 收口（iOS HomeView.swift:13-23/471-531/533-621/124-162 直译）：
//   ① 跨行星切换双阶段弹窗（switchPhase confirm → disconnecting，AppAlert
//      emphasis/loading 两扩展承载；confirmSwitchPlanet：stop await → 关弹窗 →
//      100ms 稳定窗口 → performNetworkActivate）；
//   ② 并发软上限确认弹窗（setNetworkActive 开路径 gate，iOS limitConfirmTarget
//      直译——软上限 alert 只作用激活路径，JoinNetworkSheet 无此弹窗见其头注）；
//   ③ 网络状态异常 alert（快照订阅内评 notFound/portError/clientTooOld 三态）。
import { curves } from '@kit.ArkUI';
import { AppNav, PagePrefs, PageAddPlanet, PagePlanetSettings, PageNetworkDetail } from '../ui/AppRoot';
import { AppState } from '../ui/AppState';
import { StoreRepo } from '../store/StoreRepo';
import { PlanetProfile, NetworkEntry } from '../store/Models';
import { IdentityStore } from '../store/IdentityStore';
import { ThemeManager, themeSignal, ThemeSignal } from '../store/ThemeManager';
import { StatusStore } from '../tunnel/StatusStore';
import { TunnelController } from '../tunnel/TunnelController';
import { TunnelSnapshot } from '../common/TunnelContract';
import { L10n, l10nSignal } from '../components/L10n';
import { DesignTokens, colorModeSignal, ColorModeSignal } from '../components/DesignTokens';
import { HomeMetrics } from '../components/HomeMetrics';
import { HomeParallaxBackground } from '../components/HomeParallaxBackground';
import { BackgroundImageStore, backgroundImageSignal } from '../store/BackgroundImageStore';
import { FabButton } from '../components/FabButton';
import { PlanetCardView } from '../components/PlanetCardView';
import { NetworkCardView, ztStatusKey,
  ZT_STATUS_NOT_FOUND, ZT_STATUS_PORT_ERROR, ZT_STATUS_CLIENT_TOO_OLD,
} from '../components/NetworkCardView';
import { JoinNetworkSheet } from '../components/JoinNetworkSheet';
import { AppAlert, AppAlertButton } from '../components/AppAlert';

/** 添加页标（iOS addTag 直译；store 侧行星 id 不会撞该字面） */
const ADD_TAG: string = '__add__';
/** chip 点击逐页接力的单页步进延时（iOS asyncAfter 0.1s） */
const RELAY_STEP_MS: number = 100;
/** 跨行星切换弹窗两阶段（iOS SwitchPlanetPhase 直译；'' = 关闭） */
const PHASE_CONFIRM: string = 'confirm';
const PHASE_DISCONNECTING: string = 'disconnecting';
/** 确认断开后到启动新行星的稳定窗口（iOS Task.sleep 100_000_000ns 直译） */
const SWITCH_SETTLE_MS: number = 100;

/** 网络状态异常弹窗判定（iOS ZTNetworkStatus.isAlertable 直译）：notFound/
 *  portError/clientTooOld 三态；待授权（accessDenied/authRequired）是首次加入
 *  待控制器授权的正常流程，不弹窗（状态行显示「待授权」） */
function isAlertableNetStatus(code: number): boolean {
  return code === ZT_STATUS_NOT_FOUND || code === ZT_STATUS_PORT_ERROR
    || code === ZT_STATUS_CLIENT_TOO_OLD;
}
/** 计数行字号（iOS footnote 13pt；token 表未设档，就近直取） */
const FS_FOOTNOTE: number = 13;
/** iOS .semibold → 600（ArkUI 无 Semibold 枚举档，数值字重直取） */
const FW_SEMIBOLD: number = 600;
/** 活跃行星 chip：emoji 缩至字号 2/3（22*0.65*2/3）、名称 22*0.65（brief 定值） */
const CHIP_EMOJI_FS: number = 22 * 0.65 * 2 / 3;
const CHIP_NAME_FS: number = 22 * 0.65;

const PREFS_PAGE: PagePrefs = { kind: 'prefs' };
const ADD_PLANET_PAGE: PageAddPlanet = { kind: 'addPlanet' };

@ComponentV2
export struct HomeView {
  /** 全局 UI 状态单例（@ObservedV2；build 内读 @Trace 字段即被追踪） */
  @Local app: AppState = AppState.shared;
  /** 过半翻页索引（Swiper onChange，currentPage 语义；驱动 chip 显隐） */
  @Local browsingIdx: number = 0;
  /** 各行星网络列表（计数行/卡片列表取 length；readNetworksByPlanet + 双信号刷新） */
  @Local netCounts: Map<string, NetworkEntry[]> = new Map();
  /** 行星 → 节点地址（身份文件派生 + 活跃行星快照回填；身份卡 ID 行） */
  @Local nodeIds: Map<string, string> = new Map();
  /** 行星 → 卫星数（moon.planetId ?? pagerSelection 归属；身份卡 ID 行尾缀） */
  @Local moonCounts: Map<string, number> = new Map();
  /** 隧道快照（计数行分桶/状态域投影源；整体替换触踪） */
  @Local snap: TunnelSnapshot | null = StatusStore.current();
  /** 主题派生行星色盘（0xAARRGGBB 8 元素；theme.rev/cm.dark 触踪重算） */
  @Local tints: number[] = [];
  /** 主题派生对勾成功色（身份卡/网络卡复制反馈与 ok 态共用） */
  @Local successColor: number = 0xFF009830;
  /** 主题信号触踪锚（@Monitor('theme.rev') 挂点；值本身不直接消费） */
  @Local theme: ThemeSignal = themeSignal;
  /** 深浅色信号触踪锚（@Monitor('cm.dark') 挂点；build 内仍读全局同源值） */
  @Local cm: ColorModeSignal = colorModeSignal;
  /** 加入网络半模态显隐（T9：FAB → bindSheet 宿主 JoinNetworkSheet） */
  @Local showJoinSheet: boolean = false;
  /** 跨行星切换弹窗阶段（iOS switchPhase 直译；'' = 关闭） */
  @Local switchPhase: string = '';
  /** 切换目标网络与其归属行星（两阶段共用，iOS SwitchPlanetPhase.target 直译） */
  @Local switchEntry: NetworkEntry | null = null;
  @Local switchPlanet: PlanetProfile | null = null;
  /** 软上限确认弹窗目标（iOS limitConfirmTarget 直译） */
  @Local limitEntry: NetworkEntry | null = null;
  @Local limitPlanet: PlanetProfile | null = null;
  /** 网络状态异常 alert 正文（iOS errorAlert 直译；'' = 隐藏） */
  @Local errorAlertMsg: string = '';
  /** 弹窗打开代际：拼入 networkCardKey——ForEach key 复用契约下，被弹窗拒绝的
   *  拨动靠子树重建回弹 Toggle 视觉态（iOS appearsActive 派生 binding 即时回弹
   *  的等价物，keyer 契约见 networkCardKey 注） */
  @Local reboundEpoch: number = 0;

  /** 落位索引（settledPage 语义；纯命令域，圆点/FAB 显隐锚 pagerSelection 派生） */
  private settledIdx: number = 0;
  /** 外部选中回读的回声闸（onAnimationEnd 提交写 pagerSelection 时置位） */
  private echoGuard: boolean = false;
  /** chip 接力定时器句柄（重复点击/页面销毁时清理） */
  private relayTimers: number[] = [];
  private swiperCtrl: SwiperController = new SwiperController();
  /** 初始定位索引（普通字段：仅供 .index() 首帧读取，不参与后续追踪——
   *  绑响应式表达式会让外部选中同时触发 .index 跳页与 changeIndex 动画） */
  private initialIdx: number = 0;
  /** 主题管理器实例（异步单例；就绪后 applyTheme 派生色盘/成功色） */
  private themeRef: ThemeManager | null = null;
  private unsubCfg: (() => void) | null = null;
  private unsubPlanets: (() => void) | null = null;
  private unsubSnap: (() => void) | null = null;
  /** 网络状态异常去重签名（iOS onChange 字典值变化触发语义的快照轮询近似：
   *  存活期 10s 轮询重推同值快照，不去重会每 10s 重弹） */
  private lastAlertSig: string = '';

  aboutToAppear(): void {
    this.initialIdx = this.indexOfId(this.app.pagerSelection);
    // 冷启动落位对齐（评审 I-1）：onAnimationEnd 构造性不触发，settledIdx/
    // browsingIdx 若保持 0，恢复到非首页时 chip 误显且接力起点错页——iOS 原版
    // 实时读 pagerSelection 无此缺口，随 initialIdx 一并初始化
    this.settledIdx = this.initialIdx;
    this.browsingIdx = this.initialIdx;
    this.unsubCfg = StoreRepo.store.onConfigChanged(() => void this.refreshPlanetData());
    this.unsubPlanets = StoreRepo.store.onPlanetsChanged(() => void this.refreshPlanetData());
    // 快照域：只做轻量触踪 + 节点 ID 回填（全量刷新走双信号；STATE_CHANGED
    // 频率低且 10s 轮询仅在存活态——不做每次全量身份文件重读）
    this.unsubSnap = StatusStore.subscribe((s: TunnelSnapshot | null) => {
      this.snap = s;
      this.evaluateNetworkStatusAlert(s); // 网络状态异常 alert（T12）
      const node = s === null ? null : s.nodeStatus;
      if (node !== null && this.nodeIds.get(this.app.activePlanetId) !== node.nodeId) {
        const next = new Map<string, string>();
        this.nodeIds.forEach((v: string, k: string) => next.set(k, v));
        next.set(this.app.activePlanetId, node.nodeId);
        this.nodeIds = next;
      }
    });
    void this.refreshPlanetData();
    // T10：背景图真值装载（沙盒文件 → 降采样位图 → backgroundImageSignal）
    void BackgroundImageStore.refresh();
    void ThemeManager.shared().then((t: ThemeManager) => {
      this.themeRef = t;
      this.applyTheme();
    });
  }

  aboutToDisappear(): void {
    if (this.unsubCfg !== null) {
      this.unsubCfg();
    }
    if (this.unsubPlanets !== null) {
      this.unsubPlanets();
    }
    if (this.unsubSnap !== null) {
      this.unsubSnap();
    }
    this.clearRelay();
  }

  /** 主题/深浅色变化 → 重算行星色盘与对勾成功色（成功色分深浅两档；
   *  ColorMath 出口无 alpha 位，按 0xFFFFFF 上界归一为 0xAARRGGBB） */
  @Monitor('theme.rev', 'cm.dark')
  applyTheme(): void {
    const t = this.themeRef;
    if (t === null) {
      return;
    }
    this.tints = t.planetTintsHex();
    const raw = this.cm.dark ? t.successDarkHex() : t.successLightHex();
    this.successColor = raw > 0xFFFFFF ? raw : 0xFF000000 + raw;
  }

  /** 外部选中变化（如设置页删除行星后 AppState.reload 回读）→ 跟随定位分页
   *  （iOS onChange(of: app.selectedPlanetId) 直译）；echoGuard 放过提交自身 */
  @Monitor('app.pagerSelection')
  onExternalSelectionChange(): void {
    if (this.echoGuard) {
      return;
    }
    const idx = this.indexOfId(this.app.pagerSelection);
    if (idx !== this.settledIdx) {
      this.swiperCtrl.changeIndex(Math.max(0, idx), true);
    }
  }

  /** 行星页数据域刷新（Android HomeViewModel refresh 直译同构）：网络列表 +
   * 卫星计数 + 节点地址三域，整体替换 @Local 触踪 */
  private async refreshPlanetData(): Promise<void> {
    const store = StoreRepo.store;
    const planets = this.app.planets;
    const prefs = await store.readPrefs();
    const nets = await store.readNetworksByPlanet();
    const moons = await store.readAllMoons();
    const ids = await IdentityStore.planetNodeIds(store.paths, planets, prefs.identityPerPlanet);
    // 快照回填：隧道上报的 nodeId 只属于活跃行星（iOS planetNodeID 直译）
    const node = this.snap === null ? null : this.snap.nodeStatus;
    if (node !== null) {
      ids.set(this.app.activePlanetId, node.nodeId);
    }
    // 卫星归属：moon.planetId 为 null（编辑中未落定）按当前选中页归属
    const counts = new Map<string, number>();
    for (const m of moons) {
      const key = m.planetId !== null ? m.planetId : this.app.pagerSelection;
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
    this.netCounts = nets;
    this.moonCounts = counts;
    this.nodeIds = ids;
  }

  // ---- 索引/文案域 ----

  /** id → 页索引：行星页取表内下标，添加页/未知 id → 末位（planets.length） */
  private indexOfId(id: string): number {
    const idx = this.app.planets.findIndex((p: PlanetProfile) => p.id === id);
    return idx >= 0 ? idx : this.app.planets.length;
  }

  /** 页索引全集（末位 = 添加页，iOS ids = planets + addTag 同构） */
  private pageIds(): string[] {
    const ids: string[] = this.app.planets.map((p: PlanetProfile): string => p.id);
    ids.push(ADD_TAG);
    return ids;
  }

  /** 过半浏览中的页 id（onChange 索引越界/添加页 → ADD_TAG） */
  private browsingId(): string {
    return this.browsingIdx >= 0 && this.browsingIdx < this.app.planets.length
      ? this.app.planets[this.browsingIdx].id
      : ADD_TAG;
  }

  /** 当前行星提示显隐：有活跃连接且浏览的不是活跃 Planet（iOS :306-308 直译） */
  private chipVisible(): boolean {
    return this.app.vpnRunning && this.browsingId() !== this.app.activePlanetId;
  }

  /** 行星展示名：官方行星走本地化名（iOS PlanetProfile.displayName 直译） */
  private displayNameOf(planet: PlanetProfile): string {
    return planet.id === PlanetProfile.OFFICIAL_ID
      ? this.loc('planet.official.name')
      : planet.name;
  }

  /** 网络展示名（iOS displayName(_:) 直译）：名为空回退 networkId（弹窗参数用） */
  private networkDisplayNameOf(entry: NetworkEntry | null): string {
    return entry === null ? ''
      : (entry.networkName === '' ? entry.networkId : entry.networkName);
  }

  /**
   * 网络状态异常 alert（iOS onChange(of: app.networkStatuses) 直译）：仅活跃
   * 行星页在位时评（iOS guard selectedPlanetId == activePlanetId），首个异常态
   * 网络弹「网络名：状态名」；同一异常持续期间不重复弹（iOS 由字典值变化触发，
   * 快照存活期 10s 轮询重推同值，lastAlertSig 去重为其等价语义）。
   * 去重两补（评审 I-1）：同 sig 网络 continue 看下一个——先到异常已弹期间
   * 新出现的异常不被吞；全部网络恢复正常清签名——「异常→恢复→再异常」对齐
   * iOS 字典两次变化各弹一次。
   */
  private evaluateNetworkStatusAlert(snap: TunnelSnapshot | null): void {
    if (snap === null || this.app.pagerSelection !== this.app.activePlanetId) {
      return;
    }
    const nets = this.netCounts.get(this.app.pagerSelection);
    if (nets === undefined) {
      return;
    }
    let alertable = false; // 本轮是否存在异常态网络
    for (const nwid of Object.keys(snap.networkStatuses)) {
      const code = snap.networkStatuses[nwid];
      if (!isAlertableNetStatus(code)) {
        continue;
      }
      const entry = nets.find((n: NetworkEntry): boolean => n.networkId === nwid);
      if (entry === undefined) {
        continue;
      }
      alertable = true;
      const sig = nwid + ':' + code.toString();
      if (sig === this.lastAlertSig) {
        continue; // 同一异常持续：不重复弹，继续看后续网络（勿吞新异常）
      }
      this.lastAlertSig = sig;
      this.errorAlertMsg = this.locFmt('home.alert.networkStatus %@: %@',
        [this.networkDisplayNameOf(entry), this.loc(ztStatusKey(code))]);
      return;
    }
    if (!alertable) {
      this.lastAlertSig = ''; // 全部恢复正常：清签名，允许再异常重弹
    }
  }

  /**
   * L10n 查表 + l10nSignal.rev 触踪：@ComponentV2 build 内读到该 @Trace 即被
   * 追踪，语言切换（rev 自增）驱动本组件重渲染——值本身恒 ≥ 0，不参与文案结果
   * （本组件所有文案经此出口，T5 骨架期「语言切换不重渲染」缺口在首个真实页收口）。
   */
  private loc(key: string): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.get(key);
  }

  /** 带占位符查表（'home.network.header %lld' 等），同 rev 触踪 */
  private locFmt(key: string, args: (string | number)[]): string {
    if (l10nSignal.rev < 0) { // 恒假分支仅为读取 @Trace 注册追踪
      return key;
    }
    return L10n.format(key, args);
  }

  private dotLabel(id: string): string {
    if (id === ADD_TAG) {
      return this.loc('planet.add.title');
    }
    const planet = this.app.planets.find((p: PlanetProfile) => p.id === id);
    return planet === undefined ? id
      : this.locFmt('home.a11y.browsePlanet %@', [this.displayNameOf(planet)]);
  }

  /** 计数行：`网络 · N`；活跃行星且隧道在跑时按快照分桶追加
   *  「 · 连接中 X | 已连接 Y」（iOS networkHeader :415-434 直译）——启用且
   *  无快照冲突的网络中，核心报 OK 计已连接、其余计连接中；0 桶隐藏 */
  private countRowText(planet: PlanetProfile): string {
    const nets = this.netCounts.get(planet.id);
    const n = nets === undefined ? 0 : nets.length;
    let text = this.locFmt('home.network.header %lld', [n]);
    if (planet.id === this.app.activePlanetId && this.app.vpnRunning) {
      const snap = this.snap;
      let connecting = 0;
      let connected = 0;
      for (const e of nets ?? []) {
        if (!e.lastActivated) {
          continue;
        }
        const conflict = snap === null ? undefined : snap.networkConflicts[e.networkId];
        if (conflict !== undefined) {
          continue; // 快照冲突（自动断开前窗口）不进桶
        }
        const status = snap === null ? undefined : snap.networkStatuses[e.networkId];
        if (status === 1) {
          connected++;
        } else {
          connecting++;
        }
      }
      const parts: string[] = [];
      if (connecting > 0) {
        parts.push(this.locFmt('home.network.connecting %lld', [connecting]));
      }
      if (connected > 0) {
        parts.push(this.locFmt('home.network.connected %lld', [connected]));
      }
      if (parts.length > 0) {
        text += ' · ' + parts.join(' | ');
      }
    }
    return text;
  }

  // ---- 交互域 ----

  /** 落位提交（onAnimationEnd，settledPage 语义）：写 AppState 共享态 + 落盘 */
  private commitSettled(index: number): void {
    this.settledIdx = index;
    const id = index >= 0 && index < this.app.planets.length
      ? this.app.planets[index].id
      : ADD_TAG;
    if (this.app.pagerSelection !== id) {
      this.echoGuard = true;
      this.app.pagerSelection = id;
      this.echoGuard = false;
      if (id !== ADD_TAG) {
        // iOS onChange(of: pagerSelection) → app.selectPlanet 直译（store 契约：
        // 只写 selected 静默落盘，不发光）
        void StoreRepo.store.selectPlanet(id);
      }
    }
  }

  /** chip 点击快速切回活跃行星：跳到不相邻页时逐页接力（全程连续平移，
   *  iOS switchPager 直译；0.1s/页步进） */
  private relayTo(targetId: string): void {
    this.clearRelay();
    const from = this.settledIdx;
    const to = this.indexOfId(targetId);
    if (from === to) {
      return;
    }
    const step = from < to ? 1 : -1;
    for (let i = 1; i <= Math.abs(to - from); i++) {
      const targetIdx = from + i * step;
      const timerId = setTimeout(() => {
        this.swiperCtrl.changeIndex(targetIdx, true);
      }, i * RELAY_STEP_MS);
      this.relayTimers.push(timerId);
    }
  }

  private clearRelay(): void {
    for (const t of this.relayTimers) {
      clearTimeout(t);
    }
    this.relayTimers = [];
  }

  /** FAB 点击（iOS showJoin = true）：bindSheet 半模态弹起 JoinNetworkSheet
   *  （确认加入后写回归属行星 + reloadConfig 语义由 sheet 内部收口并 onClose） */
  private onFabTap(): void {
    this.showJoinSheet = true;
  }

  /** 行星卡点击（iOS PlanetCardView Button action 直译）：选中 + 进行星设置。
   *  跨页时与落位提交同构（echoGuard 放过自身）+ changeIndex 平滑跳页 */
  private onPlanetCardTap(planet: PlanetProfile): void {
    const idx = this.indexOfId(planet.id);
    if (idx >= 0 && idx !== this.settledIdx && this.app.pagerSelection !== planet.id) {
      this.echoGuard = true;
      this.app.pagerSelection = planet.id;
      this.echoGuard = false;
      void StoreRepo.store.selectPlanet(planet.id);
      this.swiperCtrl.changeIndex(idx, true);
    }
    const page: PagePlanetSettings = { kind: 'planetSettings', planetId: planet.id };
    AppNav.push(page);
  }

  /** 行星是否有启用（lastActivated）网络——「连接中」角标的第二态锚 */
  private hasActiveNetwork(planetId: string): boolean {
    const nets = this.netCounts.get(planetId);
    if (nets === undefined) {
      return false;
    }
    return nets.some((e: NetworkEntry): boolean => e.lastActivated);
  }

  /**
   * 网络开关编排（开关即连接，Android HomeViewModel setNetworkActive 直译）：
   *  off → 置 false 落盘；活跃行星且无剩余启用网络 → 停隧道；非活跃行星关闭
   *  不做隧道编排（iOS off 分支同此——原 T7 版共享尾段落入激活编排，提取
   *  performNetworkActivate 时按直译源收正）；
   *  on → ①跨行星且在跑：确认弹窗（iOS switchPhase = .confirm 直译，T12——
   *  行星互斥，切换会断开当前行星全部连接）；②软上限 gate（iOS :490-495 直译，
   *  可强制开启）；③performNetworkActivate：置 true + 清遗留冲突 + 多网联动
   *  全关默认路由 → 落盘；活跃行星且隧道未跑 → 起隧道，在跑热生效
   *  （CMD_RESTART 换代，iOS fireConfig 对应物）；非活跃行星 → 切活跃 + 拉起。
   *  pending 转圈由快照回流驱动（NetworkCardView）。
   */
  private async setNetworkActive(planet: PlanetProfile, entry: NetworkEntry,
    active: boolean): Promise<void> {
    const store = StoreRepo.store;
    const pid = planet.id;
    if (active && pid !== this.app.activePlanetId && this.app.vpnRunning) {
      // 跨行星在跑切换：先记目标再确认（T12 双阶段弹窗，见 confirmSwitchPlanet）；
      // 拨动不落盘，reboundEpoch 驱动卡片重建让 Toggle 视觉回弹
      this.switchEntry = entry;
      this.switchPlanet = planet;
      this.switchPhase = PHASE_CONFIRM;
      this.reboundEpoch++;
      void this.refreshPlanetData(); // 回流刷新让被拒的拨动回弹
      return;
    }
    const nets = await store.readNetworks(pid);
    const target = nets.find((n: NetworkEntry): boolean => n.networkId === entry.networkId);
    if (target === undefined) {
      return; // 列表与盘面错位（外部删除在途）：吞掉本次拨动，刷新对齐
    }
    if (!active) {
      target.lastActivated = false;
      await store.writeNetworks(nets, pid);
      void this.refreshPlanetData();
      if (pid === this.app.activePlanetId) {
        if (!nets.some((n: NetworkEntry): boolean => n.lastActivated)) {
          await TunnelController.stop(); // 最后一个启用网络被关：停隧道（deactivate 直译）
          return;
        }
        if (!TunnelController.isRunning) {
          TunnelController.ensureStarted();
          return;
        }
        void TunnelController.restartIfRunning();
      }
      return;
    }
    // 软上限：新开网络会超出并发上限时先确认耗电（iOS 直译，可强制开启；
    // 只作用激活路径——跨行星在跑的切换确认在上一个 gate 已先行）
    const prefs = await store.readPrefs();
    const activeCount = nets.filter((n: NetworkEntry): boolean =>
      n.lastActivated && n.networkId !== entry.networkId).length;
    if (activeCount >= Math.max(2, prefs.maxNetworks)) {
      this.limitEntry = entry;
      this.limitPlanet = planet;
      this.reboundEpoch++; // 被拒拨动回弹（同跨行星 gate）
      void this.refreshPlanetData();
      return;
    }
    await this.performNetworkActivate(planet, target);
  }

  /**
   * 确认后的直接激活编排（iOS performNetworkActivate 直译；软上限放行与跨行星
   * 切换两条确认路径共用，不再复查软上限——iOS confirm 路径同此）。
   */
  private async performNetworkActivate(planet: PlanetProfile,
    entry: NetworkEntry): Promise<void> {
    const store = StoreRepo.store;
    const pid = planet.id;
    const nets = await store.readNetworks(pid);
    const target = nets.find((n: NetworkEntry): boolean => n.networkId === entry.networkId);
    if (target === undefined) {
      return; // 列表与盘面错位（外部删除在途）：吞掉
    }
    target.lastActivated = true;
    target.lastConflict = null; // 重新连接即视为重试（Android 直译）
    const enabledCount = nets.filter((n: NetworkEntry): boolean => n.lastActivated).length;
    if (enabledCount > 1) {
      // 多网同时启用不抢占默认路由（iOS/Android 行为直译）
      for (const n of nets) {
        n.routeViaZeroTier = false;
      }
    }
    await store.writeNetworks(nets, pid);
    void this.refreshPlanetData();
    if (pid === this.app.activePlanetId) {
      if (!TunnelController.isRunning) {
        TunnelController.ensureStarted();
        return;
      }
      void TunnelController.restartIfRunning();
      return;
    }
    // 非活跃行星：切活跃行星 + 拉起（iOS applyPlanetAndStartVPN 直译）。不以
    // vpnRunning 缓存为门——切换编排刚 stop 过，缓存尚未回流（iOS 无门同此）
    const changed = await store.activatePlanet(pid);
    if (changed) {
      await AppState.shared.reload();
    }
    TunnelController.ensureStarted();
    void this.refreshPlanetData();
  }

  /**
   * 确认跨行星切换（iOS confirmSwitchPlanet 直译）：弹窗转断开阶段保持展示，
   * 先断开当前 VPN（直接 stop 后立刻启动会让旧会话的拆除与新启动竞争），
   * 确认断开后关弹窗，留一个稳定窗口再激活新行星网络并拉起。
   */
  private async confirmSwitchPlanet(): Promise<void> {
    const entry = this.switchEntry;
    const planet = this.switchPlanet;
    if (this.switchPhase !== PHASE_CONFIRM || entry === null || planet === null) {
      return;
    }
    this.switchPhase = PHASE_DISCONNECTING;
    await TunnelController.stop(); // iOS VPNManager.stopAndWait 直译（双保险停机）
    this.closeSwitchDialog();
    await new Promise<void>(res => setTimeout(res, SWITCH_SETTLE_MS));
    await this.performNetworkActivate(planet, entry);
  }

  private closeSwitchDialog(): void {
    this.switchPhase = '';
    this.switchEntry = null;
    this.switchPlanet = null;
  }

  /** 确认超出软上限开启（耗电提示后仍要开启，iOS confirmOpenBeyondLimit 直译：
   *  直接激活，不复查软上限） */
  private confirmOpenBeyondLimit(): void {
    const planet = this.limitPlanet;
    const entry = this.limitEntry;
    this.limitPlanet = null;
    this.limitEntry = null;
    if (planet === null || entry === null) {
      return;
    }
    void this.performNetworkActivate(planet, entry);
  }

  // ---- 渲染 ----

  /**
   * 行星页 ForEach keyer（数据指纹版，评审 C-1）：key 基座 planet.id 之外拼
   * planetPage 内 PlanetCardView 全部 @Param 输入的随时间可变指纹——planet
   * 渲染消费字段（name/icon/iconColor，id 即基座）+ nodeIds/moonCounts 两 Map
   * 派生值 + 角标三布尔锚（showBadge/badgeInUse/badgeConnecting）+ 主题输入
   * （theme.rev：tints 由 applyTheme 从它派生；successColor 深浅分档另覆盖
   * cm.dark 维度）。指纹变化 = 该项子树重建（itemGenerator 重跑 → @Param 拿
   * 到新值）——冷启动 nodeIds 回填、VPN 启停角标翻转、改名/换图标/换底色均经
   * 此生效。ArkUI ForEach 非首次渲染 key 相同即复用整棵子树不重跑 itemGenerator、
   * @Param 不更新；本页数据流是「文件读 → 新实例 → Map 整体替换、无人 mutate」，
   * @ObservedV2 不闭环——数据指纹 keyer 是该数据流下的 ForEach 正确渲染契约
   * （评审 C-1 裁决）。重建丢弃的仅卡片内瞬时 @Local 态（按压缩放），可接受。
   */
  private planetPageKey(planet: PlanetProfile): string {
    return planet.id
      + '|' + planet.name
      + '|' + (planet.icon ?? '')
      + '|' + (planet.iconColor ?? '')
      + '|' + (this.nodeIds.get(planet.id) ?? '-')
      + '|' + (this.moonCounts.get(planet.id) ?? 0).toString()
      + '|' + (planet.id === this.app.activePlanetId && this.app.hasActivatedPlanet ? '1' : '0')
      + '|' + (this.app.vpnRunning ? '1' : '0')
      + '|' + (this.hasActiveNetwork(planet.id) ? '1' : '0')
      + '|' + this.theme.rev.toString()
      + '|' + this.successColor.toString(16);
  }

  /**
   * 网络卡 ForEach keyer（数据指纹版，评审 C-1）：key 基座 networkId 之外拼
   * NetworkCardView 渲染实际消费的 entry 字段（lastActivated/lastConflict/
   * networkName）+ 父级 @Param 输入（isActivePlanet、successColor）。指纹变化
   * = 该项子树重建 → 卡片拿到新 entry（拨动开关落盘后 refreshPlanetData 新实
   * 例数组整体替换，key 随 lastActivated 翻转 → 重建 → appearsActive/isPending
   * 收敛，Toggle pending 场景闭环）。快照域（netStatus/conflict/config 投影）
   * 不入指纹：卡片内订阅 StatusStore 自触踪闭环，入指纹反而随快照回流高频重
   * 建（丢复制对勾态+转圈闪烁）；dnsMode/customDns/routeViaZeroTier 卡片不渲
   * 染，同不入。数据流与渲染契约依据同 planetPageKey（评审 C-1）。
   */
  private networkCardKey(planet: PlanetProfile, entry: NetworkEntry): string {
    return entry.networkId
      + '|' + (entry.lastActivated ? '1' : '0')
      + '|' + (entry.lastConflict ?? '')
      + '|' + entry.networkName
      + '|' + (planet.id === this.app.activePlanetId ? '1' : '0')
      + '|' + this.successColor.toString(16)
      // T12：弹窗拒绝的拨动不落盘（lastActivated 不变 → key 不变 → 子树复用、
      // Toggle 视觉残留），开弹窗 bump reboundEpoch 强制重建回弹
      + '|' + this.reboundEpoch.toString();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景：自定义背景图 + 蒙纱 + 重力视差（无图退化为页面底色；T10 真值接线：
      // backgroundImageSignal @Trace 在 build 内读即追踪，设置/清除即时生效）
      HomeParallaxBackground({
        image: backgroundImageSignal.pixelMap,
        parallaxEnabled: backgroundImageSignal.parallax,
      })

      // 分页容器：全屏（内容从头区下方滚过），行星页×N + 末位添加页
      Swiper(this.swiperCtrl) {
        ForEach(this.app.planets, (planet: PlanetProfile) => {
          this.planetPage(planet)
        }, (planet: PlanetProfile) => this.planetPageKey(planet))
        this.addPage()
      }
      // 初始定位（首帧一次性读取；后续定位全部走 changeIndex，见 @Monitor）
      .index(this.initialIdx)
      .cachedCount(this.app.planets.length + 1)
      .indicator(false)
      .onChange((index: number) => {
        // 过半驱动：chip 显隐随页面滑动同步翻转（currentPage 语义）
        this.browsingIdx = index;
      })
      .onAnimationEnd((index: number) => {
        // 落位提交（settledPage 语义）
        this.commitSettled(index);
      })
      .width('100%')
      .height('100%')

      // 顶部 overlay 头区（标题 + chip + 设置 + 圆点指示器）
      this.headerZone()

      // FAB：非添加页显示（落位语义，iOS pagerSelection != addTag 直译）
      if (this.app.pagerSelection !== ADD_TAG) {
        FabButton({ action: (): void => this.onFabTap() })
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 250, curve: Curve.EaseInOut }))
      }

      // 跨行星切换双阶段弹窗（iOS switchPlanetDialog 直译）：确认阶段 headline
      // 标题 + footnote ** 加粗说明（目标网络名/当前行星名）+ footer 双按钮
      // （取消 secondary 常规/确认 accent semibold，竖分隔线按钮行）→ 断开阶段
      // 大转圈 + subheadline 文案（AppAlert loading 形态，无标题无按钮）
      if (this.switchPhase === PHASE_CONFIRM && this.switchEntry !== null) {
        AppAlert({
          title: this.loc('home.alert.switchPlanet'),
          message: this.locFmt('home.alert.switchPlanetMessage %@ %@',
            [this.networkDisplayNameOf(this.switchEntry), this.activePlanetName()]),
          emphasis: true,
          buttons: [
            new AppAlertButton(this.loc('common.cancel'), false,
              (): void => this.closeSwitchDialog(), true),
            new AppAlertButton(this.loc('home.alert.openAnyway'), false,
              (): void => void this.confirmSwitchPlanet()),
          ],
        })
      } else if (this.switchPhase === PHASE_DISCONNECTING) {
        AppAlert({
          loading: true,
          message: this.loc('home.switch.disconnecting'),
        })
      }

      // 并发软上限确认（软上限：多开增加耗电，可强制开启；iOS limitConfirmTarget
      // 直译，确认档 destructive 红字）
      if (this.limitEntry !== null) {
        AppAlert({
          title: this.loc('home.alert.openMore'),
          message: this.locFmt('home.alert.limitConfirm %@',
            [this.networkDisplayNameOf(this.limitEntry)]),
          buttons: [
            new AppAlertButton(this.loc('common.cancel'), false,
              (): void => {
                this.limitEntry = null;
                this.limitPlanet = null;
              }),
            new AppAlertButton(this.loc('home.alert.openAnyway'), true,
              (): void => this.confirmOpenBeyondLimit()),
          ],
        })
      }

      // 网络状态异常 alert（iOS .alert(errorTitle) 直译：单 OK）
      if (this.errorAlertMsg !== '') {
        AppAlert({
          title: this.loc('home.alert.networkStatusError'),
          message: this.errorAlertMsg,
          buttons: [new AppAlertButton(this.loc('common.ok'), false, (): void => {
            this.errorAlertMsg = '';
          })],
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.pageBg(colorModeSignal.dark))
    // 加入网络半模态宿主（iOS .sheet(isPresented: $showJoin) 直译；dragBar 保留
    // 默认 = iOS sheet grabber；下滑/点外经 onWillDismiss 走同一条关闭路径）
    .bindSheet(this.showJoinSheet, (): void => {
      JoinNetworkSheet({
        onClose: (): void => {
          this.showJoinSheet = false;
        },
      })
    }, {
      height: SheetSize.LARGE,
      showClose: false,
      backgroundColor: DesignTokens.pageBg(colorModeSignal.dark),
      onWillDismiss: (_action: DismissSheetAction): void => {
        this.showJoinSheet = false;
      },
    })
  }

  /** 头区（iOS headerZone :196-283）：左 Logo 40×40 圆角 9 + 右列（高锁 40：
   *  标题行在顶，圆点指示器沉底 offset -2）；背景全透明 + 三段渐变 mask 结构
   *  保留（iOS 实态即透明填充，仅弹窗宿主 T12 若需毛玻璃在此层替换） */
  @Builder
  headerZone() {
    Column() {
      Row() {
        // Logo 同图样复用 App 图标资产（iOS PlanetPortLogo；真资产入库归 T10 资产域）
        Image($r('app.media.app_icon'))
          .width(40)
          .height(40)
          .borderRadius(9)
          .clip(true)
        Column() {
          Row() {
            Text('Planet Port') // 非查表键：与 iOS .navigationTitle 字面同源（评审 M-3）
              .fontSize(DesignTokens.FS_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor(DesignTokens.textPrimary(colorModeSignal.dark))
            Blank()
            // 活跃行星 chip（有活跃连接且浏览的不是活跃 Planet 才显；点击逐页
            // 接力切回；flyFromPlanetCard 转场：下 10pt 淡入上移，iOS :706-721）
            if (this.chipVisible()) {
              Row({ space: 3 }) {
                // emoji 比同字号文字显大：单独缩小到 2/3（iOS :217）
                Text('🔗').fontSize(CHIP_EMOJI_FS)
                Text(this.activePlanetName())
                  .fontSize(CHIP_NAME_FS)
                  .fontWeight(FW_SEMIBOLD)
                  .fontColor(DesignTokens.textSecondary(colorModeSignal.dark))
                  .maxLines(1)
              }
              .alignItems(VerticalAlign.Center)
              .padding({ left: 9, right: 9, top: 4, bottom: 4 })
              .backgroundColor(DesignTokens.cardBg(colorModeSignal.dark))
              .borderRadius(100) // Capsule = 完全圆角（计划 Global Constraints ②）
              .border({
                width: DesignTokens.HAIRLINE_WIDTH,
                color: DesignTokens.textTertiary(colorModeSignal.dark),
              })
              .margin({ right: 8 })
              .onClick(() => this.relayTo(this.app.activePlanetId))
              .accessibilityTextHint(this.loc('home.a11y.activePlanetHint'))
              // 翻页事务的 easeInOut 会盖掉隐式动画：强制 easeOut 0.28s（iOS :238）
              .transition(TransitionEffect.OPACITY
                .combine(TransitionEffect.translate({ y: 10 }))
                .animation({ duration: 280, curve: Curve.EaseOut }))
            }
            // 齿轮 36×36 热区 + gearshape 20pt 主色（iOS :240-249）
            Column() {
              SymbolGlyph($r('sys.symbol.gearshape'))
                .fontSize(20)
                .fontColor([themeSignal.accent])
            }
            .width(36)
            .height(36)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .onClick(() => AppNav.push(PREFS_PAGE))
            .accessibilityText(this.loc('common.settings'))
          }
          .width('100%')
          // 圆点指示器（iOS :312-336）：数量比行星多一（末位添加页）；选中
          // 20×6 accent 胶囊 / 未选 6×6 三级文字色、间距 7、44vp 热区（不撑布局，
          // responseRegion 越界扩展）、spring 0.3/0.8
          Row({ space: 7 }) {
            ForEach(this.pageIds(), (id: string, idx: number) => {
              Row()
                .width(id === this.app.pagerSelection ? 20 : 6)
                .height(6)
                .borderRadius(3)
                .backgroundColor(id === this.app.pagerSelection
                  ? themeSignal.accent
                  : DesignTokens.textTertiary(colorModeSignal.dark))
                .animation({ curve: curves.springMotion(0.3, 0.8) })
                // 背景方式补足 44pt 热区不撑大布局的 ArkUI 等价物（iOS :332）
                .responseRegion({ x: '-100%', y: -19, width: 44, height: 44 })
                .onClick(() => this.swiperCtrl.changeIndex(idx, true))
                .accessibilityText(this.dotLabel(id))
            }, (id: string) => id)
          }
          .offset({ y: -2 })
        }
        .height(40) // 右列高度锁死与 logo 等高：内部沉底/位移才有确定参照系
        .layoutWeight(1)
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(HorizontalAlign.Start)
      }
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 6, bottom: 12 })
    // 三段渐变 mask（0/0.85/1）结构保留、填充全透明（iOS :272-280 实态直译）
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [['#00FFFFFF', 0], ['#00FFFFFF', 0.85], ['#00FFFFFF', 1]],
    })
  }

  /** 单行星页（iOS planetPage :342-383）：pageTopPadding 88 → 身份卡 → 0.5pt
   *  分隔线 + 计数行 → Scroll（卡距 12 / top 12 / bottom 148 预留 FAB+Home 条） */
  @Builder
  planetPage(planet: PlanetProfile) {
    Column() {
      // 身份卡（PlanetCardView）：角标三态锚定活跃行星（滑页不扰动），点击
      // 选中并进行星设置
      Column() {
        PlanetCardView({
          planet: planet,
          nodeId: this.nodeIds.get(planet.id) ?? '-',
          moonCount: this.moonCounts.get(planet.id) ?? 0,
          showBadge: planet.id === this.app.activePlanetId && this.app.hasActivatedPlanet,
          badgeInUse: this.app.vpnRunning,
          badgeConnecting: !this.app.vpnRunning && this.hasActiveNetwork(planet.id),
          tints: this.tints,
          successColor: this.successColor,
          onTap: (): void => this.onPlanetCardTap(planet),
        })
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 24 })

      // 网络区头部：细分隔线 + 计数行（iOS :349-355 + networkHeader :415-434）
      Column({ space: 10 }) {
        Divider()
          .strokeWidth(DesignTokens.HAIRLINE_WIDTH)
          .color(DesignTokens.hairline(colorModeSignal.dark))
        Text(this.countRowText(planet))
          .fontSize(FS_FOOTNOTE)
          .fontWeight(FW_SEMIBOLD)
          .fontColor(DesignTokens.textSecondary(colorModeSignal.dark))
          .width('100%')
      }
      .width('100%')
      .padding({ left: 20, right: 20 })

      // 网络列表（NetworkCardView/空态卡；仅此区滚动）
      Scroll() {
        Column({ space: DesignTokens.GAP_CARD }) {
          if ((this.netCounts.get(planet.id) ?? []).length === 0) {
            this.networkEmptyState()
          } else {
            ForEach(this.netCounts.get(planet.id) ?? [], (entry: NetworkEntry) => {
              NetworkCardView({
                entry: entry,
                isActivePlanet: planet.id === this.app.activePlanetId,
                successColor: this.successColor,
                onToggle: (on: boolean): void => void this.setNetworkActive(planet, entry, on),
                onTap: (): void => {
                  const page: PageNetworkDetail = { kind: 'networkDetail', networkId: entry.networkId };
                  AppNav.push(page);
                },
              })
            }, (entry: NetworkEntry) => this.networkCardKey(planet, entry))
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 12, bottom: 148 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ top: HomeMetrics.pageTopPadding })
  }

  /** 网络空态卡（iOS emptyState 直译）：network.slash 图标 + 标题 + 提示，
   *  整卡点击 = FAB 等效（加网络入口；JoinNetworkSheet 归 T9）。
   *  iOS network.slash 在鸿蒙 symbol 表无对应名，取语义最近 link_slash。 */
  @Builder
  networkEmptyState() {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.link_slash'))
        .fontSize(32)
        .fontWeight(FontWeight.Lighter)
        .fontColor([DesignTokens.textSecondary(colorModeSignal.dark)])
      Text(this.loc('home.network.emptyTitle'))
        .fontSize(DesignTokens.FS_ROW_TITLE) // iOS subheadline 15 → 行标题档
        .fontWeight(FontWeight.Medium)
        .fontColor(DesignTokens.textPrimary(colorModeSignal.dark))
      Text(this.loc('home.network.emptyHint'))
        .fontSize(FS_FOOTNOTE)
        .fontColor(DesignTokens.textSecondary(colorModeSignal.dark))
    }
    .alignItems(HorizontalAlign.Center)
    .width('100%')
    .padding({ top: 36, bottom: 36 })
    .backgroundColor(DesignTokens.cardBg(colorModeSignal.dark))
    .borderRadius(DesignTokens.RADIUS_CARD)
    .onClick(() => this.onFabTap())
  }

  /** 末位添加页（iOS TabView 末位整页形态）：骨架占位，整页点击进 AddPlanetPage */
  @Builder
  addPage() {
    Column() {
      Column({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(32)
          .fontColor([DesignTokens.textSecondary(colorModeSignal.dark)])
        Text(this.loc('planet.add.title'))
          .fontSize(DesignTokens.FS_ROW_TITLE)
          .fontWeight(FW_SEMIBOLD)
          .fontColor(DesignTokens.textPrimary(colorModeSignal.dark))
      }
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 24, right: 24, top: 20, bottom: 20 })
      .backgroundColor(DesignTokens.cardBg(colorModeSignal.dark))
      .borderRadius(DesignTokens.RADIUS_CARD)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: HomeMetrics.pageTopPadding })
    .onClick(() => AppNav.push(ADD_PLANET_PAGE))
  }

  /** 活跃行星展示名（chip 文案；官方行星走本地化名） */
  private activePlanetName(): string {
    const planet = this.app.planets.find(
      (p: PlanetProfile) => p.id === this.app.activePlanetId);
    return planet === undefined ? '' : this.displayNameOf(planet);
  }
}
