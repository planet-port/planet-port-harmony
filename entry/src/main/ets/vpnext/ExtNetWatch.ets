// ExtNetWatch.ets — 物理网络监听（D9；NetWatch.kt 防抖语义直译）
//
// 平台差异（有意）：Android registerNetworkCallback(NetworkRequest) 可同时观测
// 多张物理网卡，候选表多行；鸿蒙 createNetConnection() 缺省只跟踪默认数据网络，
// 候选表退化为 0/1 行——判定/防抖/基线/触发逻辑逐行对齐 NetWatch.kt，QF-1 修法
// 三点全保留：① caps 记表（VPN/失格网络出表，自反馈过滤）② 表实际变化才重置
// 防抖 ③ 读数与判定都压到防抖到期（切换瞬态不作读数）。
//
// 防抖 1500ms（对齐 Android NET_CHANGE_DEBOUNCE_MS / iOS asyncAfter(1.5s)）：
// regained（断网恢复）或 switched（在线且传输介质变化）才触发切网自愈；断网
// 只记基线不触发——断网时无从重连，恢复时由 regained 兜住（iOS 同语义）。
// pathSatisfied 不等防抖：表变化即时透出（onPathSatisfied），卡片「无网络」
// 即时显示，不等核心 30s 超时的 OFFLINE 事件（对齐 iOS 55945a7 /
// NetWatch.kt exposeSatisfied）。
import { connection } from '@kit.NetworkKit';

const NET_CHANGE_DEBOUNCE_MS = 1500;

// 传输介质码（对齐 NetWatch.kt 常量；触发优先级单独映射，与码值解耦）
const TRANSPORT_NONE = -1;
const TRANSPORT_WIFI = 0;
const TRANSPORT_CELLULAR = 1;
const TRANSPORT_ETHERNET = 2;
const TRANSPORT_OTHER = 3;

/** 切网自愈感知端：onPathSatisfied 即时透出可用性（表变化即调）；onPathChange
 * 防抖到期后触发（仅 regained/switched），是否在跑由实现方自判 */
export class ExtNetWatch {
  private conn: connection.NetConnection | null = null;
  private debounceTimer = -1;
  private running = false;
  // 候选物理网络表（netId → 传输码）；「当前路径」由表求值，不由默认网络快照断言
  private candidates: Map<number, number> = new Map();
  // 最近一次防抖到期时的基线；null satisfied = 尚无基线（首次判定仅记基线）
  private lastSatisfied: boolean | null = null;
  private lastTransport = TRANSPORT_NONE;
  private readonly onPathSatisfied: (ok: boolean) => void;
  private readonly onPathChange: () => void;

  constructor(onPathSatisfied: (ok: boolean) => void, onPathChange: () => void) {
    this.onPathSatisfied = onPathSatisfied; // ArkTS 禁构造器参数属性（arkts-no-ctor-prop-decls）
    this.onPathChange = onPathChange;
  }

  /** 注册路径监听（幂等：已注册时忽略）；注册失败只损失切网自愈能力，不抛 */
  start(): void {
    if (this.conn !== null) return;
    this.running = true;
    this.lastSatisfied = null; // 新一轮监听重新记基线
    this.candidates.clear();
    const c = connection.createNetConnection();
    // 不订阅 netAvailable：available 后必跟 netCapabilitiesChange，表项以 caps
    // 为准（NetWatch.kt「不覆写 onAvailable」同语义）
    // 三回调入口均先查 running（评审 M3）：shutdown 后 unregister 异步完成前的
    // 回调窗口内，recordCandidate 仍会重灌 candidates → exposeSatisfied 误报
    // true + 重设防抖 timer——守卫闭死该窗口（金标 NetWatch.kt 同病，壳侧可闭）
    c.on('netCapabilitiesChange', (info: connection.NetCapabilityInfo): void => {
      if (!this.running) return;
      if (this.recordCandidate(info.netHandle.netId, info.netCap)) {
        this.onTableChanged();
      }
    });
    c.on('netLost', (handle: connection.NetHandle): void => {
      if (!this.running) return;
      if (this.removeCandidate(handle.netId)) {
        this.onTableChanged();
      }
    });
    // 默认网络不存在（或丢失而无 netLost 前置）→ 全表清空
    c.on('netUnavailable', (): void => {
      if (!this.running) return;
      if (this.candidates.size > 0) {
        this.candidates.clear();
        this.onTableChanged();
      }
    });
    c.register((err): void => {
      if (err) {
        // 注册失败回滚引用保持未注册态（NetWatch.kt 同语义）；告警不放大
        this.running = false;
        this.conn = null;
      }
    });
    this.conn = c;
  }

  /** 注销（幂等，重复调用无害）；先摘引用再反注册，杜绝回调窗口期再入 */
  shutdown(): void {
    this.running = false;
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
    const c = this.conn;
    this.conn = null;
    this.candidates.clear();
    this.lastSatisfied = null;
    if (c !== null) {
      try {
        c.unregister((): void => { /* 结果不敏感：注销失败的最坏结果是系统侧残留 */ });
      } catch (_e) { /* 未注册等异常一律吞掉：本侧引用已清，动作不会执行 */ }
    }
  }

  /** 表实际变化才走这条路：即时透出可用性 + 重置防抖 */
  private onTableChanged(): void {
    this.exposeSatisfied();
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout((): void => {
      this.debounceTimer = -1;
      this.evaluate();
    }, NET_CHANGE_DEBOUNCE_MS);
  }

  /** 物理路径可用性即时透出：satisfied = 候选表非空，与防抖/重启判定无关 */
  private exposeSatisfied(): void {
    this.onPathSatisfied(this.candidates.size > 0);
  }

  /** 记表：VPN/失格网络出表（自反馈过滤）；返回表是否实际变化。
   * 鸿蒙把「非 VPN」表达为 capability（NET_CAPABILITY_NOT_VPN）而非 transport，
   * 等价意图：物理网进表、VPN/失格网络出表（NetWatch.kt recordCandidate） */
  private recordCandidate(netId: number, caps: connection.NetCapabilities): boolean {
    const capsArr = caps.networkCap;
    const usable = capsArr !== undefined
      && capsArr.includes(connection.NetCap.NET_CAPABILITY_INTERNET)
      && capsArr.includes(connection.NetCap.NET_CAPABILITY_NOT_VPN);
    if (!usable) {
      return this.candidates.delete(netId);
    }
    const transport = this.transportOf(caps);
    const changed = this.candidates.get(netId) !== transport;
    if (changed) {
      this.candidates.set(netId, transport);
    }
    return changed;
  }

  /** 出表；返回表是否实际变化 */
  private removeCandidate(netId: number): boolean {
    return this.candidates.delete(netId);
  }

  private transportOf(caps: connection.NetCapabilities): number {
    const bears = caps.bearerTypes;
    if (bears.includes(connection.NetBearType.BEARER_ETHERNET)) {
      return TRANSPORT_ETHERNET;
    }
    if (bears.includes(connection.NetBearType.BEARER_WIFI)) {
      return TRANSPORT_WIFI;
    }
    if (bears.includes(connection.NetBearType.BEARER_CELLULAR)) {
      return TRANSPORT_CELLULAR;
    }
    return TRANSPORT_OTHER;
  }

  /** 取表内最强者的优先级：ethernet > wifi > cellular > other（同级任一） */
  private priorityOf(transport: number): number {
    if (transport === TRANSPORT_ETHERNET) return 3;
    if (transport === TRANSPORT_WIFI) return 2;
    if (transport === TRANSPORT_CELLULAR) return 1;
    return 0;
  }

  /** 防抖到期执行：候选表最强者求值，与基线比较，regained/switched 才触发 */
  private evaluate(): void {
    if (!this.running) return;
    let best = TRANSPORT_NONE;
    this.candidates.forEach((transport: number): void => {
      if (this.priorityOf(transport) > this.priorityOf(best)) {
        best = transport;
      }
    });
    const satisfied = this.candidates.size > 0;
    const newTransport = satisfied ? best : TRANSPORT_NONE;
    const last = this.lastSatisfied;
    const lastTransport = this.lastTransport;
    // 基线更新时机与读数同点：防抖到期判定后（QF-1 修法第 3 点）
    this.lastSatisfied = satisfied;
    this.lastTransport = newTransport;
    if (last === null) return; // 首次判定仅记基线（iOS :591-594 直译）
    const regained = !last && satisfied;
    const switched = last && satisfied && lastTransport !== newTransport;
    if (!regained && !switched) return; // 断网只记基线不触发——恢复由 regained 兜住
    this.onPathChange();
  }
}
