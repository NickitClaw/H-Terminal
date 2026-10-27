import { UIAbility } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AppLifecycle } from '../lifecycle/AppLifecycle';

export default class EntryAbility extends UIAbility {
  onForeground(): void { AppLifecycle.setForeground(true); }
  onBackground(): void { AppLifecycle.setForeground(false); }
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        hilog.error(0x0000, 'HTerminal', 'Failed to load main page: %{public}s', error.message);
      }
    });
  }
}
