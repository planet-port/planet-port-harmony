// AppState.ets — 全局 UI 状态（iOS AppState.swift 直译，骨架子集）
//
// iOS AppState 484 行承载配置重读/网络状态聚合/连接超时编排/行星切换编排等；
// 骨架期（A5-T5）只落 brief 契约的六个字段（planets/activePlanetId/vpnRunning/
// online/pathSatisfied/pagerSelection），其余域随消费任务回填：
//   networks/planetNetworks/planetNodeIds/moons → T7；confirmSwitchPlanet 编排
//   → T12 落 HomeView.performNetworkActivate（本类 reload() 为其挂接点）。
// 数据源映射（iOS App Group 文件 + Darwin 通知 → 鸿蒙等价物）：
//   planets/pagerSelection/activePlanetId ← AppConfigStore（planetsChanged/
//   configChanged 信号触发重读；activatePlanet/selectPlanet 故意静默——切换后
//   由编排方显式调 reload()，与 store 侧「热生效由调用方显式编排」契约同构）
//   vpnRunning/online/pathSatisfied ← StatusStore.subscribe 快照（level-triggered，
//   订阅即推当前值；STATE_CHANGED 唤醒 + 存活期 10s 兜底轮询持续重推）
import { StatusStore } from '../tunnel/StatusStore';
import { TunnelSnapshot, aliveFresh } from '../common/TunnelContract';
import { StoreRepo } from '../store/StoreRepo';
import { PlanetProfile } from '../store/Models';

@ObservedV2
export class AppState {
  static readonly shared: AppState = new AppState();

  @Trace planets: PlanetProfile[] = [];
  /** iOS selectedPlanetId：首页 Swiper 浏览选中（命名取 brief 契约，T6 消费） */
  @Trace pagerSelection: string = PlanetProfile.OFFICIAL_ID;
  @Trace activePlanetId: string = PlanetProfile.OFFICIAL_ID;
  /** iOS hasActivatedPlanet：prefs.activePlanetId 非 null 即「设置过活跃行星」
   *  （身份卡角标显隐门槛，T7 消费；与 activePlanetId 的 null→official 回退区分） */
  @Trace hasActivatedPlanet: boolean = false;
  /** iOS pollRuntime: vpnRunning = connected|connecting|reasserting（快照侧派生见 applySnapshot） */
  @Trace vpnRunning: boolean = false;
  /** iOS StatusStore.online：节点已连上行星根服务器 */
  @Trace online: boolean = false;
  /** 物理网络可用（飞行模式/断网即时 false；初值 true 对齐 iOS @Published 初值） */
  @Trace pathSatisfied: boolean = true;

  private inited: boolean = false;
  // 退订句柄只记不消费（评审 M-1）：进程单例与 Ability 同寿，退订无意义；
  // 留数组形态备未来多实例场景
  private unsubs: (() => void)[] = [];

  /** EntryAbility onCreate 接线（幂等；须在 StoreRepo/StatusStore.init 之后调） */
  async init(): Promise<void> {
    if (this.inited) {
      return;
    }
    this.inited = true;
    this.unsubs.push(StatusStore.subscribe(s => this.applySnapshot(s)));
    this.unsubs.push(StoreRepo.store.onPlanetsChanged(() => void this.reload()));
    this.unsubs.push(StoreRepo.store.onConfigChanged(() => void this.reload()));
    await this.reload();
  }

  /**
   * 行星表/指针重读（T8 导入落盘、T10 行星操作、T12 切换编排后显式调用）。
   * 三域走 AppConfigStore.readUiSnapshot 复合读（T7 收口 M-6：原逐域链式读
   * ≈5 次文件读 → 2 次）；hasActivatedPlanet 是 UiSnapshot 逐字三字段契约外的
   * AppState 域（iOS reloadConfig 同段直译），单独补一次 prefs 读——仍是净减。
   */
  async reload(): Promise<void> {
    const store = StoreRepo.store;
    const snap = await store.readUiSnapshot();
    this.planets = snap.planets;
    this.pagerSelection = snap.selectedPlanetId;
    this.activePlanetId = snap.activePlanetId;
    this.hasActivatedPlanet = (await store.readPrefs()).activePlanetId !== null;
  }

  /** 快照 → 派生字段（iOS refreshStatus/pollRuntime 的快照侧等价；订阅即推 +
   * 轮询重推，故冻结快照的陈旧化也随重读自然回落） */
  private applySnapshot(snap: TunnelSnapshot | null): void {
    // iOS 三态（connected/connecting/reasserting）↔ 快照 alive（running/starting/
    // reconnecting），叠加 writtenAt 新鲜度取 TunnelController.isRunning 同一判定
    // （冻结快照假在线防线：VpnExt 死亡后 45s 起 vpnRunning 回落 false，
    // StatusStore 存活期轮询持续唤醒本回调驱动该收敛，无需额外定时器）
    this.vpnRunning = snap !== null && aliveFresh(snap);
    // 停机终态快照 nodeStatus=null（ExtStateBus.writeTerminal 清运行态）——
    // online 随 vpnRunning 门控，与 iOS「隧道不跑状态区整体失效」语义一致
    const node = snap === null ? null : snap.nodeStatus;
    this.online = this.vpnRunning && node !== null && node.online;
    this.pathSatisfied = snap !== null ? snap.pathSatisfied : true;
  }
}
