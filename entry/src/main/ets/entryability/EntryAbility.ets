import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { StoreRepo } from '../store/StoreRepo';
import { LanguageManager } from '../store/LanguageManager';
import { StatusStore } from '../tunnel/StatusStore';

const TAG = 'PlanetPort';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onCreate');
    // 主进程侧启动接线：store 门面 → 快照读方（STATE_CHANGED 订阅 + 兜底轮询）
    // → 语言表（Task 7）。StoreRepo.init 幂等，StatusStore.init 内部亦会补 init。
    StoreRepo.init(this.context);
    StatusStore.init(this.context);
    void LanguageManager.init();
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
