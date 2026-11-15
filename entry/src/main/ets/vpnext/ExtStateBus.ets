// ExtStateBus.ets — 扩展进程状态聚合与快照写方（TunnelStateBus 跨进程投影）
//
// 进程内无 UI，TunnelStateBus 的 StateFlow 投影退化为：NAPI onStateChanged →
// flush()（拉 snapshot() → 补 pathSatisfied/writtenAt → 写快照文件 → 发
// STATE_CHANGED）。快照 11 字段契约见 TunnelContract.ets——pathSatisfied/
// writtenAt 为写方注入（Task 8 的 snapshotJson 序列化不含）；eventLog 40 条
// 滚动在 C++ 侧（TunnelRuntime::log），此处只透传。落盘走 tmp+rename 原子替换
// （对齐 JsonFileStore.writeLocked 语义：失败清 tmp，不留半截文件）。
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { IpcEvents } from '../common/IpcEvents';
import { StoreRepo } from '../store/StoreRepo';
import { TunnelNapi } from '../common/CoreRuntime';

const TAG = 'PlanetPortVpnExt';

export class ExtStateBus {
  private pathSatisfied = true; // NetWatch 透出；缺省 true（TunnelStateBus 同语义）
  private flushing = false;
  // flush 在途期间又有状态到达时置位（评审 F2：简单互斥会直接丢弃后到事件，
  // fs IO 耗时内背靠背的状态置位将致最终态永不落盘——金标 StateFlow 的
  // conflating 保证最终值必达，dirty 即同语义的有损合并）
  private dirty = false;
  // 快照写串行链（评审 M4：flush 与 writeTerminal 共用同一 .tmp，并发交错
  // rename 取最后成功者——串行化后 tmp 竞态不可能）
  private writeChain: Promise<void> = Promise.resolve();

  constructor() {
  }

  setPathSatisfied(ok: boolean): void {
    this.pathSatisfied = ok;
    TunnelNapi.setPathSatisfied(ok); // native 亦发 onStateChanged → flush 合并落盘
    void this.flush(); // 即时落盘不等 tsfn 回程（「无网络」卡片即时性）
  }

  /** 停机复位（直译 ZeroTierVpnService.stopTunnel 的 setPathSatisfied(true)）：
   * 防跨会话残留误显「无网络」；runtime 已停，不触 native */
  resetPathSatisfied(): void {
    this.pathSatisfied = true;
  }

  /** 快照落盘 + 通知主进程（level-triggered：主进程重读全量） */
  async flush(): Promise<void> {
    if (this.flushing) {
      this.dirty = true; // 在途——记脏，finally 补排（最终值必达）
      return;
    }
    this.flushing = true;
    try {
      const snap = JSON.parse(TunnelNapi.snapshot()) as Record<string, Object | null>;
      snap['pathSatisfied'] = this.pathSatisfied;
      snap['writtenAt'] = Date.now();
      await this.writeSnapshot(snap);
      commonEventManager.publish(IpcEvents.STATE_CHANGED,
        (): void => { /* 结果不敏感 */ });
    } catch (e) {
      hilog.warn(0x0000, TAG, `快照落盘失败: ${JSON.stringify(e)}`);
    } finally {
      this.flushing = false;
      if (this.dirty) {
        this.dirty = false;
        void this.flush(); // 补排一轮（期间再到达则再置 dirty，必达闭环）
      }
    }
  }

  /** 终态化（onDestroy/CMD_STOP 兜底）：写 Stopped 快照（runtime 已停，
   * snapshot() 仍返回最后状态——由壳改写 kind 后落盘）；尽力而为，失败不抛 */
  async writeTerminal(kind: string, reason: string | undefined,
    recoverable: boolean | undefined): Promise<void> {
    try {
      const snap = JSON.parse(TunnelNapi.snapshot()) as Record<string, Object | null>;
      const raw: Object | null | undefined = snap['tunnelState'];
      const st: Record<string, Object | null> = raw === undefined || raw === null
        ? {} : raw as Record<string, Object | null>;
      st['kind'] = kind;
      if (reason !== undefined) st['reason'] = reason;
      if (recoverable !== undefined) st['recoverable'] = recoverable;
      snap['tunnelState'] = st;
      if (kind === 'stopped') {
        // 停机清运行态（评审 M2：对齐金标 stopTunnel 的 setNodeStatus(null)+
        // clearNetworkStatuses()——持久快照残留最后在线态且跨进程重启存活，
        // 主进程会一直显示已停隧道的旧数据）；coreVersion 按契约保留（UI
        // 显示最后已知版本），eventLog/applyTrace 属诊断轨迹一并保留
        snap['nodeStatus'] = null;
        const noStatuses: Record<string, Object> = {};
        snap['networkStatuses'] = noStatuses;
        snap['networkConfigs'] = [];
        snap['peers'] = [];
      }
      snap['pathSatisfied'] = this.pathSatisfied; // 停机复位 true 随快照闭环（契约注释）
      snap['writtenAt'] = Date.now();
      await this.writeSnapshot(snap);
      commonEventManager.publish(IpcEvents.STATE_CHANGED,
        (): void => { /* 结果不敏感 */ });
    } catch (_e) { /* 尽力而为 */ }
  }

  /** tmp + rename 原子替换；失败清 tmp 后抛（调用方按需吞掉）。
   * 经 writeChain 串行（评审 M4）：所有写方（flush/writeTerminal）互斥排队，
   * 共用 .tmp 的交错 rename 竞态不可能 */
  private async writeSnapshot(snap: Record<string, Object | null>): Promise<void> {
    const run = this.writeChain
      .then((): Promise<void> => this.writeSnapshotLocked(snap));
    this.writeChain = run.then((): void => {}, (): void => {}); // 失败不断链
    return run;
  }

  private async writeSnapshotLocked(snap: Record<string, Object | null>): Promise<void> {
    const file = StoreRepo.store.paths.snapshotFile;
    const tmp = `${file}.tmp`;
    const f = await fs.open(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE
      | fs.OpenMode.TRUNC);
    let fd = f.fd;
    try {
      await fs.write(fd, JSON.stringify(snap));
      await fs.close(fd);
      fd = -1;
      await fs.rename(tmp, file);
    } catch (e) {
      if (fd >= 0) {
        try { await fs.close(fd); } catch (_ignored) { /* 关闭失败不放大 */ }
      }
      try { await fs.unlink(tmp); } catch (_ignored) { /* 无 tmp 可清 */ }
      throw new Error(`snapshot write failed: ${file}: ${JSON.stringify(e)}`);
    }
  }
}
