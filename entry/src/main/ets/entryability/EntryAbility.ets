import { AbilityConstant, UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { StoreRepo } from '../store/StoreRepo';
import { LanguageManager } from '../store/LanguageManager';
import { StatusStore } from '../tunnel/StatusStore';
import { TunnelController } from '../tunnel/TunnelController';
import { L10n } from '../components/L10n';
import { ThemeReactive } from '../store/ThemeManager';
import { colorModeSignal } from '../components/DesignTokens';
import { AppState } from '../ui/AppState';

const TAG = 'PlanetPort';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onCreate');
    // 主进程侧启动接线：store 门面 → 快照读方（STATE_CHANGED 订阅 + 兜底轮询）
    // → 语言表（Task 7）。StoreRepo.init 幂等，StatusStore.init 内部亦会补 init。
    StoreRepo.init(this.context);
    StatusStore.init(this.context);
    void LanguageManager.init();
    // A5-T5 接线①：三语查表装载 + 主题响应式种子（均幂等；L10n 异步落表后自
    // 广播 l10n.rev，晚于首帧的裸 key 文案随 rev 重算；须在 StoreRepo.init 后——
    // ThemeReactive 经 ThemeManager.shared() 读 prefs）
    void L10n.init(this.context);
    ThemeReactive.ensureReactive();
    // A5-T5 接线②（A5-T6 迁移）：深浅色 → colorModeSignal.dark（AppStorageV2
    // 域，DesignTokens.dark() 唯一读出口，@ComponentV2 build 内读即追踪）；
    // 系统切换经 onConfigurationUpdate 持续同步（EntryAbility → DesignTokens
    // 单向导入，无环）
    this.syncColorMode(this.context.config.colorMode);
    // A5-T5（brief）：全局 UI 状态接线（planets/activePlanetId 读盘 + 快照订阅派生）
    void AppState.shared.init();
    // A5-T12（#28）：开 App 自动恢复
    void this.autoRestoreOnLaunch();
  }

  /**
   * #28 开 App 自动恢复（iOS NEOnDemandRuleConnect 无等价物的替代门控，降级②
   * 文案「打开 App 即自动恢复」的实现位）：曾有活跃行星 + 停机非用户主动 →
   * ensureStarted（幂等，在跑即 no-op——VpnExt 进程被系统回收后 UI 侧拉起、
   * VpnExt 自身 onCreate 也会恢复，双通道互不冲突）。
   * 「停机非用户主动」判定（评审 I-2）：快照 Stopped + reason='user' = CMD_STOP
   * 用户停机（VpnExt stopTunnel 唯一 user 写点），不恢复；onDestroy 兜底落
   * reason='lifecycle'（系统优雅回收）→ 恢复；进程死亡不走 onDestroy，快照
   * 冻结在运行态（新鲜度过期）→ 恢复。null = 从未启动过，不恢复。
   */
  private async autoRestoreOnLaunch(): Promise<void> {
    const prefs = await StoreRepo.store.readPrefs();
    if (!prefs.autoRestore || prefs.activePlanetId === null) {
      return; // 门控关闭 / 从未有过活跃行星
    }
    await StatusStore.refresh(); // 订阅首读异步在途，先收口再判形态
    const snap = StatusStore.current();
    if (snap === null) {
      return; // 从未启动过
    }
    if (snap.tunnelState.kind === 'stopped'
      && snap.tunnelState.reason === 'user') {
      return; // 用户主动停机：不恢复（lifecycle/异常回收均恢复）
    }
    TunnelController.ensureStarted();
  }

  /** 系统配置变更（深浅色/语言等）→ colorMode 同步（接线②持续链路） */
  onConfigurationUpdate(newConfig: Configuration): void {
    this.syncColorMode(newConfig.colorMode);
  }

  /** ConfigurationConstant.ColorMode → dark 布尔（undefined 一律按 light，
   * 对齐 DesignTokens.dark() 的缺省契约） */
  private syncColorMode(mode: ConfigurationConstant.ColorMode | undefined): void {
    colorModeSignal.dark = mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'Failed to load content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, 'Succeeded in loading content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onWindowStageDestroy');
  }
}
