// StatusStore.ets — 快照读方（主进程；对齐 iOS StatusStore 跨进程消费语义）
//
// 启动读一次 + 订阅 STATE_CHANGED 全量重读（level-triggered：事件只做唤醒，
// 负载一律重读快照文件——订阅方不得假设收到每一次变更）；隧道存活期间 10s
// 兜底轮询（VpnExt 异常死亡时 STATE_CHANGED 永不再来的「假在线」防线）。
// brief 头注的「writtenAt 落后 30s+」陈旧判定在此收敛为无条件存活期轮询：
// 轮询本身已覆盖陈旧窗口，无需再加时间阈值（A6 真机调参时按需收紧）。
// 快照解析白名单/字段校验收窄在 TunnelContract.parseSnapshot（T1 挂账在此收口）。
import fs from '@ohos.file.fs';
import { commonEventManager } from '@kit.BasicServicesKit';
import { Context } from '@kit.AbilityKit';
import { IpcEvents } from '../common/IpcEvents';
import { TunnelSnapshot, parseSnapshot, alive } from '../common/TunnelContract';
import { StoreRepo } from '../store/StoreRepo';

type ChangeCb = (s: TunnelSnapshot | null) => void;

export class StatusStore {
  private static snap: TunnelSnapshot | null = null;
  private static listeners: Set<ChangeCb> = new Set();
  private static sub: commonEventManager.CommonEventSubscriber | null = null;
  private static pollTimer: number = -1;

  static init(ctx: Context): void {
    if (StatusStore.pollTimer >= 0) return; // 幂等护栏（评审 M-3）：重复 init 会叠加订阅与轮询
    StoreRepo.init(ctx);
    void StatusStore.refresh();
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [IpcEvents.STATE_CHANGED],
      // 终审发现 2：事件名前缀只防碰撞不防伪造——第三方 publish 同名事件即可
      // 扰动状态读方；按真实发布者 bundle 过滤（API9+）
      publisherBundleName: 'cn.imgozi.h.planetport',
    };
    commonEventManager.createSubscriber(info, (err, s) => {
      if (err || !s) return;
      StatusStore.sub = s;
      commonEventManager.subscribe(s, () => void StatusStore.refresh());
    });
    // 兜底轮询：10s（VpnExt 异常死亡时 STATE_CHANGED 永不再来；仅在存活态轮询，
    // 停机态快照终态不会变，无轮询意义）
    StatusStore.pollTimer = setInterval(() => {
      const snap = StatusStore.snap;
      if (snap !== null && alive(snap.tunnelState)) {
        void StatusStore.refresh();
      }
    }, 10_000);
  }

  static async refresh(): Promise<void> {
    try {
      const text = await fs.readText(StoreRepo.store.paths.snapshotFile);
      StatusStore.snap = parseSnapshot(text);
    } catch (_e) {
      StatusStore.snap = null; // 快照不存在/不可读 = 从未启动
    }
    StatusStore.listeners.forEach(cb => cb(StatusStore.snap));
  }

  static current(): TunnelSnapshot | null { return StatusStore.snap; }

  /** 订阅即推当前值（StateFlow 语义）；返回退订函数 */
  static subscribe(cb: ChangeCb): () => void {
    StatusStore.listeners.add(cb);
    cb(StatusStore.snap);
    return () => { StatusStore.listeners.delete(cb); };
  }
}
