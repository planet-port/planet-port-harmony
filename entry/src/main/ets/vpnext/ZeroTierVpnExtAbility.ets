// ZeroTierVpnExtAbility.ets — VPN 扩展壳（D14 隔离面；直译 ZeroTierVpnService
// 生命周期语义 + VpnService.Builder 用法映射 VpnConfig）
//
// 与 Android 的结构差异（有意）：
//   ① 授权：鸿蒙无 prepare()——首次 create() 由系统弹窗（失败码 2203001）。
//   ② establish 换代：D3 进程内 destroy+create+swapFd，核心不随 TUN 换代重启。
//   ③ 切网自愈（D9）：进程内闭环（ExtNetWatch → reconnectCore），不重启扩展进程。
//   ④ 通知：VpnExt 无常驻通知义务（Android FGS 义务不适用）——系统 VPN 状态
//      图标由系统呈现；应用内状态走快照。
//   ⑤ 配置热变更：主进程 AppConfigStore.fireConfig 双通道（进程内 listener +
//      commonEvent）的接收端在本壳——CONFIG_CHANGED 重读 store → applyConfig
//      热重配（计划 Self-Review D5 修复项；隧道运行期 join/leave/orbit 增量）。
//   ⑥ 停机：CMD_STOP 优雅终态化后由主进程另行 stopVpnExtensionAbility（双保险：
//      指令 + 进程停止各一次）；onDestroy 的 stopTunnel 兜底幂等，终态快照
//      reason 区分来源（user=用户停机 / lifecycle=系统回收兜底，评审 I-2：
//      主进程 autoRestore 据此判「停机非用户主动」），首写为准不互相覆盖。
import { Want } from '@kit.AbilityKit';
import { VpnExtensionAbility, VpnExtensionContext } from '@kit.NetworkKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { ExtRuntime } from './ExtRuntime';
import { ExtStateBus } from './ExtStateBus';
import { ExtNetWatch } from './ExtNetWatch';
import { StoreRepo } from '../store/StoreRepo';
import { IpcEvents } from '../common/IpcEvents';

export default class ZeroTierVpnExtAbility extends VpnExtensionAbility {
  private runtime: ExtRuntime | null = null;
  private stateBus: ExtStateBus | null = null;
  private netWatch: ExtNetWatch | null = null;
  private cmdSub: commonEventManager.CommonEventSubscriber | null = null;
  /** 终态已落盘（评审 I-2）：CMD_STOP 先落 reason='user'，其后主进程
   *  stopVpnExtensionAbility 触发的 onDestroy 兜底不得用 'lifecycle' 覆盖
   *  （用户停机语义被覆盖会被 autoRestore 误判可恢复）——首写为准 */
  private terminalized: boolean = false;

  onCreate(want: Want): void {
    const ctx: VpnExtensionContext = this.context;
    StoreRepo.init(ctx);
    this.stateBus = new ExtStateBus(); // 评审 M6：ctx 死字段已删，无参构造
    this.runtime = new ExtRuntime(ctx, this.stateBus);
    // 切网感知（D9）正反路径两路接线：pathSatisfied 即时透出（卡片「无网络」），
    // 防抖到期 regained/switched 才走进程内换代自愈
    this.netWatch = new ExtNetWatch((ok: boolean): void => {
      this.stateBus?.setPathSatisfied(ok);
    }, (): void => {
      // 切网自愈（D9）：进程内换代重启（核心重置 NAT 映射缓存须重建）
      void this.runtime?.reconnectCore();
    });
    this.netWatch.start();
    this.subscribeCommands(ctx);
    // 隧道启动：onCreate 即拉起（startVpnExtensionAbility 语义 = 用户已在主进程
    // 过授权/显式启动；无 cmd 的冷启动（系统回收后拉起）同样恢复）
    void this.startTunnel();
  }

  onDestroy(): void {
    // 优雅终态化（UNVERIFIED-4 双保险之一：CMD_STOP 路径已先行终态化，此处兜底
    // 记 'lifecycle'——系统优雅回收场景主进程 autoRestore 据此恢复；stopTunnel
    // 幂等——netWatch 停与 runtime 停均可重入，终态写首写为准）
    void this.stopTunnel('lifecycle');
    this.unsubscribeCommands();
  }

  private async startTunnel(): Promise<void> {
    // 直译 ZeroTierVpnService.startTunnel 顺序：
    // ① 读配置（activePlanetId → planet 档案 → identityPerPlanet → 身份 seed）
    // ② NAPI start（核心装载身份/planet、Starting 态）
    // ③ establish 由 onEstablish 回调驱动（VpnConfig 组装 → create → swapFd）
    // ④ protectProcessNet 一次（create 成功后；UNVERIFIED-1 最稳路径）
    await this.runtime?.start();
  }

  private async stopTunnel(reason: string): Promise<void> {
    // 终态首写为准（评审 I-2）：同步置位防并发窗口——CMD_STOP('user') 与其后
    // 主进程 stopVpnExtensionAbility 触发的 onDestroy('lifecycle') 竞速时先到者
    // 赢，用户停机语义不被回收兜底覆盖（否则 autoRestore 会误判可恢复）
    if (this.terminalized) {
      return;
    }
    this.terminalized = true;
    // 直译 stopTunnel 顺序（幂等）：先摘路径监听（teardown 期间的路径回调不得
    // 再触发重连，NetWatch.stop 同语义）→ NAPI stop（先停数据面消费线程）→
    // destroy VPN 连接 → pathSatisfied 复位 true（防跨会话残留）→ 终态化快照
    // （Stopped，reason 区分 user=用户停机 / lifecycle=系统回收兜底，评审 I-2）
    // → 发 STATE_CHANGED
    this.netWatch?.shutdown();
    await this.runtime?.shutdown();
    this.stateBus?.resetPathSatisfied();
    await this.stateBus?.writeTerminal('stopped', reason, undefined);
  }

  private subscribeCommands(ctx: VpnExtensionContext): void {
    // 主进程指令：CMD_STOP（优雅停机，进程停止由主进程双保险下发）、
    // CMD_RESTART（换代重启：行星切换/偏好热生效）、CONFIG_CHANGED（store 配置
    // 变更 → 热重配——主进程 fireConfig 双通道的接收端闭环，缺了则隧道运行期
    // 收不到配置变更）
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [IpcEvents.CMD_STOP, IpcEvents.CMD_RESTART, IpcEvents.CONFIG_CHANGED],
      // 终审发现 2：指令事件无发布者校验时，第三方 publish 同名 CMD_STOP 即可
      // 停用户 VPN——按真实发布者 bundle 过滤（API9+）
      publisherBundleName: 'cn.imgozi.h.planetport',
    };
    commonEventManager.createSubscriber(info, (err, sub) => {
      if (err || !sub) return;
      this.cmdSub = sub;
      commonEventManager.subscribe(sub, (e, data) => {
        if (e) return;
        if (data?.event === IpcEvents.CMD_STOP) {
          // 用户停机：终态记 reason='user'（评审 I-2，主进程 autoRestore 据此
          // 判不恢复）；stopVpnExtensionAbility 需要 want——进程内经 context
          // 无法构造完整 want，主进程在发布 CMD_STOP 后自行调用（双保险：
          // 指令 + 进程停止各一次，onDestroy 兜底首写为准不再覆盖）
          void this.stopTunnel('user');
        } else if (data?.event === IpcEvents.CMD_RESTART) {
          void this.runtime?.restartFromConfig();
        } else if (data?.event === IpcEvents.CONFIG_CHANGED) {
          void this.runtime?.applyConfigChange();
        }
      });
    });
  }

  private unsubscribeCommands(): void {
    if (this.cmdSub !== null) {
      commonEventManager.unsubscribe(this.cmdSub);
      this.cmdSub = null;
    }
  }
}
