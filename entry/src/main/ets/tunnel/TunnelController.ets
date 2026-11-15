// TunnelController.ets — 启停编排门面（直译 tunnel/TunnelController.kt；
// UI 层唯一入口，对齐 iOS VPNManager 职责）
//
// 映射差异：
//   ① 状态读走 StatusStore 快照（跨进程文件 + 事件唤醒）而非同进程 StateFlow。
//   ② 无 VpnService.prepare() 授权器——鸿蒙授权在扩展进程首次 create() 的系统
//      弹窗，ensureStarted 直起扩展进程，拒绝态经快照 Failed 回流呈现。
//   ③ 停启编排等待以快照 tunnelState 为准（awaitSettled 轮询近似 first{}）。
//   ④ 换代重启语义收窄：Android 的 reconnect 是 STOP→START 两段下发、代际失效
//      窗口覆盖整个重启过程；鸿蒙换代重启全在 VpnExt 进程内完成（CMD_RESTART
//      一发即收口），主进程不再有两段下发——代际失效窗口仅覆盖指令在途瞬间。
//      「窗口内用户停止」由 VpnExt 内 stopTunnel 幂等与 CMD_STOP/CMD_RESTART
//      后到先到竞争兜底（stop 一定后到则进程已停，迟到的 CMD_RESTART 落空无害）。
//   ⑤ startVpnExtensionAbility/stopVpnExtensionAbility 映射
//      ZeroTierVpnService.start/stop（SDK 签名为单参 want，want 含
//      bundleName + abilityName 定位扩展 Ability）。
import { vpnExtension } from '@kit.NetworkKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { Want } from '@kit.AbilityKit';
import { IpcEvents } from '../common/IpcEvents';
import { aliveFresh } from '../common/TunnelContract';
import { StatusStore } from './StatusStore';

const START_INTENT_WINDOW_MS = 30_000;
const SETTLE_TIMEOUT_MS = 15_000;
const SETTLE_POLL_MS = 200;
const RECONNECT_QUEUE_TIMEOUT_MS = 20_000;
const RECONNECT_QUEUE_POLL_MS = 200;

/** 扩展进程 want（module.json5 声明名对齐） */
function tunnelWant(): Want {
  const w: Want = {
    deviceId: '',
    bundleName: 'cn.imgozi.h.planetport',
    abilityName: 'ZeroTierVpnExtAbility',
  };
  return w;
}

export class TunnelController {
  private static startIntentAtMs: number = 0;
  private static gen: number = 0; // 停启代际（stopGeneration 直译）
  private static reconnectInFlight: boolean = false;

  static markStartIntent(): void { TunnelController.startIntentAtMs = Date.now(); }

  /** 30s 启动意图窗口：窗口内 UI 不因「无快照更新」回落为失败态 */
  static get startIntentActive(): boolean {
    return Date.now() - TunnelController.startIntentAtMs < START_INTENT_WINDOW_MS;
  }

  static clearStartIntent(): void { TunnelController.startIntentAtMs = 0; }

  static get isRunning(): boolean {
    const snap = StatusStore.current();
    return snap !== null && aliveFresh(snap); // 终审发现 1：叠加 writtenAt 新鲜度
  }

  /** 幂等启动（授权经扩展进程首次 create() 系统弹窗；拒绝态由快照回流呈现） */
  static ensureStarted(): void {
    if (TunnelController.isRunning) return;
    TunnelController.markStartIntent();
    // 启动失败（含用户拒授权 2203001）：窗口内无快照更新 → UI 按窗口外判定回落
    void vpnExtension.startVpnExtensionAbility(tunnelWant()).catch(() => {});
  }

  /** 幂等停止：终态 no-op（快照 null = 从未启动，等同终态——评审 I-1：否则
   * 从未启动/授权拒绝后点停止会空转 awaitSettled 满 15s）；存活/Failed 放行
   * ——代际自增 + 优雅指令 + 进程停止双保险 */
  static async stop(): Promise<void> {
    const snap = StatusStore.current();
    if (snap === null) return;
    if (!aliveFresh(snap) && snap.tunnelState.kind !== 'failed') return;
    TunnelController.gen++;
    // 双保险：先发优雅停机指令（VpnExt 终态化快照 → Stopped → STATE_CHANGED），
    // awaitSettled 收口后（无论优雅路径是否在超时内完成——onDestroy 的
    // stopTunnel 兜底幂等，UNVERIFIED-4）再停扩展进程
    commonEventManager.publish(IpcEvents.CMD_STOP, () => {});
    await TunnelController.awaitSettled();
    void vpnExtension.stopVpnExtensionAbility(tunnelWant()).catch(() => {});
  }

  /** 等离开存活态（15s 超时）；快照轮询（200ms）近似 StateFlow first{} */
  static async awaitSettled(timeoutMs: number = SETTLE_TIMEOUT_MS): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const snap = StatusStore.current();
      if (snap !== null && !aliveFresh(snap)) return true;
      await new Promise<void>(res => setTimeout(res, SETTLE_POLL_MS));
    }
    const snap = StatusStore.current();
    return snap !== null && !aliveFresh(snap);
  }

  /** 偏好热生效/行星切换（在跑才重启；未跑 no-op——偏好已落盘下次启动生效） */
  static async restartIfRunning(): Promise<void> {
    if (!TunnelController.isRunning) return;
    TunnelController.markStartIntent();
    if (TunnelController.reconnectInFlight) {
      // 排队补发（行星切换不可丢——直译 QF-3 排队语义）：等在飞收口后重发
      const waited = Date.now();
      while (TunnelController.reconnectInFlight
        && Date.now() - waited < RECONNECT_QUEUE_TIMEOUT_MS) {
        await new Promise<void>(res => setTimeout(res, RECONNECT_QUEUE_POLL_MS));
      }
      if (TunnelController.reconnectInFlight) return; // 放弃
      if (!TunnelController.isRunning) { TunnelController.ensureStarted(); return; }
      return TunnelController.restartIfRunning();
    }
    TunnelController.reconnectInFlight = true;
    try {
      const generationAtRequest = TunnelController.gen;
      // 换代重启全在 VpnExt 进程内闭环（类头注 ④）：CMD_RESTART 一发即收口。
      // 下方代际比对在单线程下无 await 间隙、当前不可达（评审 M-1）——保留为
      // TunnelController.kt 直译防御位；停机互斥的实际保护在 VpnExt 侧
      // ExtRuntime.stopRequested 粘滞标志（停后不复活）
      commonEventManager.publish(IpcEvents.CMD_RESTART, () => {});
      if (TunnelController.gen !== generationAtRequest) return;
    } finally {
      TunnelController.reconnectInFlight = false;
    }
  }
}
