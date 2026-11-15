// networkcardstatus.test.mjs — 网络卡状态机分支自测（node --test）
//
// 被测对象：mirror/networkcardstatus.mjs（NetworkCardView.ets 状态机纯函数段
// 的逐行镜像，骨架一致性由 mirror-check.sh 校验）。
// 覆盖：brief 全部分支——非活跃 / 快照冲突（address·subnet）/ 未激活冲突
// （timeout 直显、冲突模板、null）/ !vpnRunning / !pathSatisfied / 待授权
// （6、2）/ REQUESTING_CONFIGURATION 按 online 分段 / OK / 其余码与域外码 /
// waitingNode 兜底 / 分支优先级序互证 / dotColor≡color 不变式 / palette 透传。
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  ZT_STATUS_REQUESTING_CONFIGURATION,
  ZT_STATUS_OK,
  ZT_STATUS_ACCESS_DENIED,
  ZT_STATUS_NOT_FOUND,
  ZT_STATUS_PORT_ERROR,
  ZT_STATUS_CLIENT_TOO_OLD,
  ZT_STATUS_AUTHENTICATION_REQUIRED,
  CONFLICT_ADDRESS,
  CONFLICT_SUBNET,
  CONFLICT_TIMEOUT,
  NetworkCardPalette,
  NetworkCardStatusInput,
  ztStatusKey,
  isPendingAuthorization,
  conflictTextKey,
  networkCardStatus,
} from './mirror/networkcardstatus.mjs';

// 哨兵色：四个色域互不相同，断言输出取的正是声明的那个域
const SEC = 0x111111;
const WARN = 0x222222;
const DANGER = 0x333333;
const SUCCESS = 0x444444;
const pal = new NetworkCardPalette(SEC, WARN, DANGER, SUCCESS);

// 活跃行星 + 无冲突 + 隧道在跑 + 物理网络可用 = 全绿基线，各分支在此基础上单变量偏移
function inp(over = {}) {
  const p = {
    isActivePlanet: true,
    lastActivated: true,
    lastConflict: null,
    snapshotConflict: null,
    vpnRunning: true,
    pathSatisfied: true,
    online: false,
    netStatus: null,
    ...over,
  };
  return new NetworkCardStatusInput(p.isActivePlanet, p.lastActivated, p.lastConflict,
    p.snapshotConflict, p.vpnRunning, p.pathSatisfied, p.online, p.netStatus);
}

// dotColor ≡ color 不变式（iOS Circle .fill(cardStatus.color) 同源直译）
function assertDot(out) {
  assert.equal(out.dotColor, out.color);
  return out;
}

// ---- 非活跃行星：最高优先级 ----
test('非活跃行星恒显示未连接（优先于一切冲突/运行态）', () => {
  // 同时带快照冲突 + 遗留冲突 + 隧道在跑 + 状态 OK，仍取非活跃分支
  const out = assertDot(networkCardStatus(inp({
    isActivePlanet: false,
    snapshotConflict: CONFLICT_ADDRESS,
    lastConflict: CONFLICT_TIMEOUT,
    netStatus: ZT_STATUS_OK,
  }), pal));
  assert.equal(out.textKey, 'status.disconnected');
  assert.equal(out.textArg, null);
  assert.equal(out.color, SEC);
});

// ---- 快照冲突（address/subnet）优先于开关判定 ----
test('快照冲突 address：danger + 冲突文案键', () => {
  const out = assertDot(networkCardStatus(inp({
    snapshotConflict: CONFLICT_ADDRESS,
  }), pal));
  assert.equal(out.textKey, 'card.conflict.address');
  assert.equal(out.textArg, null);
  assert.equal(out.color, DANGER);
});

test('快照冲突 subnet：danger + 冲突文案键', () => {
  const out = assertDot(networkCardStatus(inp({
    snapshotConflict: CONFLICT_SUBNET,
  }), pal));
  assert.equal(out.textKey, 'card.conflict.subnet');
  assert.equal(out.color, DANGER);
});

test('快照冲突必须以 lastActivated 为门槛（关着的不算冲突现场）', () => {
  // snapshotConflict 非空但开关已关：落 !lastActivated 分支的 disconnected
  const out = assertDot(networkCardStatus(inp({
    lastActivated: false,
    snapshotConflict: CONFLICT_ADDRESS,
    lastConflict: null,
  }), pal));
  assert.equal(out.textKey, 'status.disconnected');
  assert.equal(out.color, SEC);
});

// ---- 未激活（!lastActivated）：遗留冲突三态 ----
test('遗留冲突 timeout 直显连接超时（不套冲突离线模板）', () => {
  const out = assertDot(networkCardStatus(inp({
    lastActivated: false,
    lastConflict: CONFLICT_TIMEOUT,
  }), pal));
  assert.equal(out.textKey, 'card.timeout.offline');
  assert.equal(out.textArg, null);
  assert.equal(out.color, DANGER);
});

test('遗留冲突 address：套「冲突,离线」模板，textArg 为冲突键', () => {
  const out = assertDot(networkCardStatus(inp({
    lastActivated: false,
    lastConflict: CONFLICT_ADDRESS,
  }), pal));
  assert.equal(out.textKey, 'card.conflict.offline %@');
  assert.equal(out.textArg, 'card.conflict.address');
  assert.equal(out.color, DANGER);
});

test('遗留冲突 subnet：套「冲突,离线」模板，textArg 为 subnet 键', () => {
  const out = assertDot(networkCardStatus(inp({
    lastActivated: false,
    lastConflict: CONFLICT_SUBNET,
  }), pal));
  assert.equal(out.textKey, 'card.conflict.offline %@');
  assert.equal(out.textArg, 'card.conflict.subnet');
  assert.equal(out.color, DANGER);
});

test('未激活且无遗留冲突：未连接（优先于 vpnRunning 判定）', () => {
  // vpnRunning=true 也不显示「建立隧道」——断开态优先
  const out = assertDot(networkCardStatus(inp({
    lastActivated: false,
    vpnRunning: true,
  }), pal));
  assert.equal(out.textKey, 'status.disconnected');
  assert.equal(out.color, SEC);
});

test('未激活 + vpnRunning=false + 无冲突：仍显示未连接（不吞成建立隧道）', () => {
  const out = assertDot(networkCardStatus(inp({
    lastActivated: false,
    vpnRunning: false,
  }), pal));
  assert.equal(out.textKey, 'status.disconnected');
});

// ---- !vpnRunning ----
test('激活但隧道未跑：建立隧道（warn）', () => {
  const out = assertDot(networkCardStatus(inp({ vpnRunning: false }), pal));
  assert.equal(out.textKey, 'status.establishing');
  assert.equal(out.color, WARN);
});

test('!vpnRunning 优先于 !pathSatisfied（两者同时为假显示建立隧道）', () => {
  const out = assertDot(networkCardStatus(inp({
    vpnRunning: false,
    pathSatisfied: false,
    netStatus: ZT_STATUS_OK,
  }), pal));
  assert.equal(out.textKey, 'status.establishing');
});

// ---- !pathSatisfied ----
test('物理网络不可用：无网络（warn），核心 OK 也不假亮在线', () => {
  const out = assertDot(networkCardStatus(inp({
    pathSatisfied: false,
    netStatus: ZT_STATUS_OK,
  }), pal));
  assert.equal(out.textKey, 'status.noNetwork');
  assert.equal(out.color, WARN);
});

// ---- 待授权（6 / 2）----
test('核心报 AUTHENTICATION_REQUIRED(6)：待授权（warn），优先于分段', () => {
  const out = assertDot(networkCardStatus(inp({
    netStatus: ZT_STATUS_AUTHENTICATION_REQUIRED,
    online: true,
  }), pal));
  assert.equal(out.textKey, 'status.pendingAuth');
  assert.equal(out.color, WARN);
});

test('核心报 ACCESS_DENIED(2)：同样待授权（首次加入的正常流程）', () => {
  const out = assertDot(networkCardStatus(inp({
    netStatus: ZT_STATUS_ACCESS_DENIED,
    online: false,
  }), pal));
  assert.equal(out.textKey, 'status.pendingAuth');
  assert.equal(out.color, WARN);
});

// ---- REQUESTING_CONFIGURATION 按 online 分段 ----
test('REQUESTING_CONFIGURATION(0) 且未连根服务器：连接服务器', () => {
  const out = assertDot(networkCardStatus(inp({
    netStatus: ZT_STATUS_REQUESTING_CONFIGURATION,
    online: false,
  }), pal));
  assert.equal(out.textKey, 'network.status.connectingServer');
  assert.equal(out.color, WARN);
});

test('REQUESTING_CONFIGURATION(0) 且已连根服务器：请求网络配置', () => {
  const out = assertDot(networkCardStatus(inp({
    netStatus: ZT_STATUS_REQUESTING_CONFIGURATION,
    online: true,
  }), pal));
  assert.equal(out.textKey, 'network.status.requestingConfig');
  assert.equal(out.color, WARN);
});

// ---- OK / 其余码 / 域外码 ----
test('OK(1)：在线（success 色）', () => {
  const out = assertDot(networkCardStatus(inp({
    netStatus: ZT_STATUS_OK,
    online: true,
  }), pal));
  assert.equal(out.textKey, 'network.status.ok');
  assert.equal(out.color, SUCCESS);
});

for (const [code, key] of [
  [ZT_STATUS_NOT_FOUND, 'network.status.notFound'],
  [ZT_STATUS_PORT_ERROR, 'network.status.portError'],
  [ZT_STATUS_CLIENT_TOO_OLD, 'network.status.clientTooOld'],
]) {
  test(`核心错误码 ${code} → ${key}（warn 色）`, () => {
    const out = assertDot(networkCardStatus(inp({ netStatus: code }), pal));
    assert.equal(out.textKey, key);
    assert.equal(out.color, WARN);
  });
}

test('域外码 99：unknown 兜底键（且不误判为待授权）', () => {
  assert.equal(isPendingAuthorization(99), false);
  const out = assertDot(networkCardStatus(inp({ netStatus: 99 }), pal));
  assert.equal(out.textKey, 'network.status.unknown');
  assert.equal(out.color, WARN);
});

test('快照无该网络条目（netStatus=null）：等待节点（secondary）', () => {
  const out = assertDot(networkCardStatus(inp({ netStatus: null }), pal));
  assert.equal(out.textKey, 'status.waitingNode');
  assert.equal(out.color, SEC);
});

// ---- 纯函数查表直测 ----
test('ztStatusKey 全码表 + 域外兜底', () => {
  assert.equal(ztStatusKey(0), 'network.status.requestingConfiguration');
  assert.equal(ztStatusKey(1), 'network.status.ok');
  assert.equal(ztStatusKey(2), 'network.status.accessDenied');
  assert.equal(ztStatusKey(3), 'network.status.notFound');
  assert.equal(ztStatusKey(4), 'network.status.portError');
  assert.equal(ztStatusKey(5), 'network.status.clientTooOld');
  assert.equal(ztStatusKey(6), 'network.status.authRequired');
  assert.equal(ztStatusKey(7), 'network.status.unknown');
  assert.equal(ztStatusKey(-1), 'network.status.unknown');
});

test('isPendingAuthorization 只认 6 与 2', () => {
  assert.equal(isPendingAuthorization(6), true);
  assert.equal(isPendingAuthorization(2), true);
  assert.equal(isPendingAuthorization(0), false);
  assert.equal(isPendingAuthorization(1), false);
  assert.equal(isPendingAuthorization(3), false);
  assert.equal(isPendingAuthorization(4), false);
  assert.equal(isPendingAuthorization(5), false);
  assert.equal(isPendingAuthorization(99), false);
});

test('conflictTextKey：仅 address 走 address 键，其余（含垃圾值）按 subnet', () => {
  assert.equal(conflictTextKey(CONFLICT_ADDRESS), 'card.conflict.address');
  assert.equal(conflictTextKey(CONFLICT_SUBNET), 'card.conflict.subnet');
  assert.equal(conflictTextKey(CONFLICT_TIMEOUT), 'card.conflict.subnet'); // 快照契约无 timeout，按兜底
  assert.equal(conflictTextKey(''), 'card.conflict.subnet');
  assert.equal(conflictTextKey('garbage'), 'card.conflict.subnet');
});

test('常量直译值（跨进程契约，UI 侧不得改动）', () => {
  assert.equal(ZT_STATUS_REQUESTING_CONFIGURATION, 0);
  assert.equal(ZT_STATUS_OK, 1);
  assert.equal(ZT_STATUS_ACCESS_DENIED, 2);
  assert.equal(ZT_STATUS_NOT_FOUND, 3);
  assert.equal(ZT_STATUS_PORT_ERROR, 4);
  assert.equal(ZT_STATUS_CLIENT_TOO_OLD, 5);
  assert.equal(ZT_STATUS_AUTHENTICATION_REQUIRED, 6);
  assert.equal(CONFLICT_ADDRESS, 'address');
  assert.equal(CONFLICT_SUBNET, 'subnet');
  assert.equal(CONFLICT_TIMEOUT, 'timeout');
});

test('palette 透传：四个色域各取所声明值', () => {
  const p2 = new NetworkCardPalette(0x0a0a0a, 0x0b0b0b, 0x0c0c0c, 0x0d0d0d);
  assert.equal(networkCardStatus(inp({ isActivePlanet: false }), p2).color, 0x0a0a0a);
  assert.equal(networkCardStatus(inp({ vpnRunning: false }), p2).color, 0x0b0b0b);
  assert.equal(networkCardStatus(inp({ lastConflict: CONFLICT_ADDRESS, lastActivated: false }), p2).color, 0x0c0c0c);
  assert.equal(networkCardStatus(inp({ netStatus: ZT_STATUS_OK }), p2).color, 0x0d0d0d);
});
