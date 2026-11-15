// NetworkCardView.ets 状态机纯函数段的 node 镜像（T3 模式）：
// 与 ../NetworkCardView.ets 的 MIRROR-BEGIN..MIRROR-END 切片逐行同构，
// 改一处必须同步另一处（../mirror-check.sh 骨架比对校验）。
// 直译源：iOS NetworkCardView.swift:8-83（NetworkCardStatus 全量分支）。
// 本文件零依赖：无 import、无 ArkTS/UI 特性，node --test 直跑。

// ZT_VirtualNetworkStatus 原始码（Core/include/ZeroTierOne.h 0..6；跨进程契约）
export const ZT_STATUS_REQUESTING_CONFIGURATION = 0;
export const ZT_STATUS_OK = 1;
export const ZT_STATUS_ACCESS_DENIED = 2;
export const ZT_STATUS_NOT_FOUND = 3;
export const ZT_STATUS_PORT_ERROR = 4;
export const ZT_STATUS_CLIENT_TOO_OLD = 5;
export const ZT_STATUS_AUTHENTICATION_REQUIRED = 6;

// lastConflict 原始码（Shared/Models.swift ConflictCode 直译）
export const CONFLICT_ADDRESS = 'address';
export const CONFLICT_SUBNET = 'subnet';
export const CONFLICT_TIMEOUT = 'timeout';

// 状态机颜色域（secondary/warn/danger/success；dark 分支由调用方求值）。
// class 承载数据结构对齐 T3 镜像惯例（.mjs 同构可比）。
export class NetworkCardPalette {
  secondary = 0;
  warn = 0;
  danger = 0;
  success = 0;

  constructor(secondary, warn, danger, success) {
    this.secondary = secondary;
    this.warn = warn;
    this.danger = danger;
    this.success = success;
  }
}

// 状态机输入：卡片所在行星是否活跃 + 网络开关/遗留冲突 + 隧道快照投影
export class NetworkCardStatusInput {
  isActivePlanet = false;
  lastActivated = false;
  lastConflict = null;
  snapshotConflict = null;
  vpnRunning = false;
  pathSatisfied = false;
  online = false;
  netStatus = null;

  constructor(isActivePlanet, lastActivated, lastConflict,
    snapshotConflict, vpnRunning, pathSatisfied,
    online, netStatus) {
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

// 状态机输出：文案查表键（含 %@ 占位时 textArg 非空）+ 文字/圆点色
export class NetworkCardStatusOutput {
  textKey = '';
  textArg = null;
  color = 0;
  dotColor = 0;

  constructor(textKey, textArg, color, dotColor) {
    this.textKey = textKey;
    this.textArg = textArg;
    this.color = color;
    this.dotColor = dotColor;
  }
}

// 核心实时状态码 → 展示文案键（iOS ZTNetworkStatus.displayName 直译）；
// 域外码（核心未来新增）统一落 unknown 兜底键。
export function ztStatusKey(code) {
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

// 首次加入待控制器授权：核心报「需要认证」或「拒绝访问」均属正常流程
// （iOS isPendingAuthorization 直译）；域外码非待授权。
export function isPendingAuthorization(code) {
  return code === ZT_STATUS_AUTHENTICATION_REQUIRED || code === ZT_STATUS_ACCESS_DENIED;
}

// 冲突原始码 → 展示文案键（iOS conflictText 直译）：仅 UI 层使用，
// 非 address 一律按 subnet（快照契约只产生这两类）。
export function conflictTextKey(code) {
  return code === CONFLICT_ADDRESS ? 'card.conflict.address' : 'card.conflict.subnet';
}

// 状态机输出构造（dotColor 与文字色同源——iOS Circle .fill(cardStatus.color)）
function statusOut(textKey, textArg,
  color) {
  return new NetworkCardStatusOutput(textKey, textArg, color, color);
}

// 网络卡片状态机（iOS NetworkCardStatus.init 全量直译）。状态只有：未连接 /
// 建立隧道 / 待授权 / 核心实时状态（连接服务器、请求网络配置、在线等）。
// 分支优先级序即 iOS if-else 链序，逐分支见行内对照。
export function networkCardStatus(inp,
  pal) {
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
