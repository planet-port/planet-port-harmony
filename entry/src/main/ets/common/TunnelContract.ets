// TunnelContract.ets — 隧道状态与快照 JSON 契约（D1：快照文件 + 事件唤醒）
//
// 直译源：TunnelStateBus.kt sealed interface TunnelState（5 态）与全部 StateFlow
// 字段。跨进程序列化形态：tunnelState 用 {kind, reason?, recoverable?} 判别对象；
// networkStatuses 存 ZT_VirtualNetworkStatus 原始码（键 16 位十六进制 nwid）——
// 不在隧道侧生成文案，文案由 UI 层生成（对齐 iOS 跨进程契约约定）。
// ArkTS 无 sealed interface：kind 用字符串字面量联合约束，编解码函数收窄。

// 状态判别字面量（对齐 TunnelStateBus.kt:11-18；kind 即序列化值）
export type TunnelStateKind = 'idle' | 'starting' | 'running' | 'reconnecting'
  | 'stopped' | 'failed';

export interface TunnelState {
  kind: TunnelStateKind;
  /** reconnecting: 'network_change'；stopped/failed: 原因码（UI 层生成文案） */
  reason?: string;
  /** 仅 failed：是否可恢复（对齐 Failed(reason, recoverable)） */
  recoverable?: boolean;
}

/** 存活判定：Running/Starting/Reconnecting 视为在跑（TunnelController.kt:82-86） */
export function alive(s: TunnelState | null): boolean {
  if (!s) return false; // null/undefined 双拦（评审 Minor 加固）
  return s.kind === 'running' || s.kind === 'starting' || s.kind === 'reconnecting';
}

/** 快照新鲜度阈值：VpnExt 存活时 5s pollPeers 周期性刷新 writtenAt；落后
 * 45s（9 倍周期余量）= 写方进程已死，快照冻结不可再信 */
export const SNAPSHOT_FRESH_MS = 45_000;

/** 存活且新鲜（终审发现 1）：仅 kind 判定时，VpnExt 死亡（native crash/系统
 * 回收）后快照冻结在 running → 主进程永久假在线——ensureStarted 幂等拦截
 * 起不来、stop() 放行后 CMD_STOP 无接收方 15s 超时，用户既启不了也停不了。
 * 叠加 writtenAt 新鲜度后冻结快照按非存活收口：isRunning=false → 重新拉起
 * 自愈；授权拒绝（starting 冻结）同机制兜住。轮询门控仍用 alive()（继续
 * 重读无害，防的是"声明在跑就刷新"） */
export function aliveFresh(snap: TunnelSnapshot): boolean {
  return alive(snap.tunnelState) && Date.now() - snap.writtenAt <= SNAPSHOT_FRESH_MS;
}

/** 节点信息快照（TunnelStateBus.kt:21-25；nodeId 十位十六进制） */
export interface NodeStatusInfo {
  nodeId: string;
  online: boolean;
  coreVersion: string;
}

/** Peer 快照（TunnelStateBus.kt:33-39；address 为 ZT 40 位节点地址数值） */
export interface PeerEntry {
  address: number;
  version: string; // "v1.14.0"；版本未知 "v-1.-1.-1"
  latency: number;
  role: string; // "LEAF"/"MOON"/"PLANET"
  paths: string[]; // "ip:port"；空 = relay 中转
}

/** 网络配置快照（对齐 NetConf 跨进程投影；UI 详情页消费） */
export interface NetConfSnapshot {
  nwid: string; // 16 位十六进制
  name: string;
  status: number; // ZT_VirtualNetworkStatus 原始码
  type: string; // "PRIVATE"/"PUBLIC"
  mac: number;
  mtu: number;
  broadcastEnabled: boolean;
  bridge: boolean;
  dhcp: boolean;
  assignedAddrs: string[]; // "ip/prefix"
  routes: string[]; // "dest/prefix" 或 "dest/prefix via gw"
  dns: string[];
}

/** 快照文件根结构（VpnExt 写、主进程读；字段名即契约，禁改） */
export interface TunnelSnapshot {
  tunnelState: TunnelState;
  nodeStatus: NodeStatusInfo | null;
  pathSatisfied: boolean; // ExtNetWatch 透出（停机复位 true 防跨会话残留）
  coreVersion: string; // 缓存：停机不清，UI 显示最后已知版本
  networkStatuses: Record<string, number>; // nwid hex → status 原始码
  networkConflicts: Record<string, string>; // nwid hex → "address"|"subnet"
  networkConfigs: NetConfSnapshot[];
  peers: PeerEntry[];
  applyTrace: string;
  eventLog: string; // 最近 40 条滚动（TunnelStateBus.log 同源格式）
  writtenAt: number; // Date.now()，主进程侧陈旧性判定用
}

// ---- JSON 编解码（手写字段收窄，不引第三方库） ----

// kind 白名单（T1 挂账）：快照文件可能被截断/篡改/版本漂移，未知 kind 一律
// 回退 idle（读方按「从未启动」消费），不得让非法字面量流入 TunnelState 类型域
const KIND_WHITELIST: string[] = ['idle', 'starting', 'running', 'reconnecting',
  'stopped', 'failed'];

/** kind 收窄：非字符串或不在白名单 → 回退 idle */
function parseKind(v: Object): TunnelStateKind {
  if (typeof v !== 'string') return 'idle';
  const s: string = v;
  if (KIND_WHITELIST.indexOf(s) < 0) return 'idle';
  return s as TunnelStateKind;
}

/** writtenAt 收窄（T1 挂账）：非 number → 0（陈旧判定自然走兜底重读） */
function parseWrittenAt(v: Object): number {
  if (typeof v === 'number') return v;
  return 0;
}

export function parseSnapshot(text: string): TunnelSnapshot | null {
  try {
    const o: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
    const st = o['tunnelState'] as Record<string, Object>;
    const state: TunnelState = { kind: parseKind(st['kind']) };
    if (st['reason'] !== undefined) state.reason = st['reason'] as string;
    if (st['recoverable'] !== undefined) state.recoverable = st['recoverable'] as boolean;
    const snap: TunnelSnapshot = {
      tunnelState: state,
      nodeStatus: o['nodeStatus'] === null ? null
        : o['nodeStatus'] as NodeStatusInfo,
      pathSatisfied: o['pathSatisfied'] as boolean,
      coreVersion: o['coreVersion'] as string,
      networkStatuses: o['networkStatuses'] as Record<string, number>,
      networkConflicts: o['networkConflicts'] as Record<string, string>,
      networkConfigs: o['networkConfigs'] as NetConfSnapshot[],
      peers: o['peers'] as PeerEntry[],
      applyTrace: o['applyTrace'] as string,
      eventLog: o['eventLog'] as string,
      writtenAt: parseWrittenAt(o['writtenAt']),
    };
    return snap;
  } catch (_e) {
    return null; // 半截/损坏快照 → 调用方按 Idle 处理
  }
}
