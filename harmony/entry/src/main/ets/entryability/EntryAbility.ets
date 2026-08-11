import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

import type { ApplicationComposition } from '../bootstrap/ApplicationComposition';
import {
  applyPhase1LaunchWant,
  createApplicationComposition,
  getPhase1LaunchContext
} from '../bootstrap/CoreComposition';

const DOMAIN = 0x0000;
const PRODUCTION_ROUTE = 'pages/Index';
const SELF_TEST_ROUTE = 'pages/CoreDebugPage';

export default class EntryAbility extends UIAbility {
  private windowStage?: window.WindowStage;
  private applicationComposition?: ApplicationComposition;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    applyPhase1LaunchWant(this.context, want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    applyPhase1LaunchWant(this.context, want);
    void this.loadTargetPage();
  }

  onDestroy(): void {
    void this.closeApplicationComposition();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    void this.loadTargetPage();
  }

  onWindowStageDestroy(): void {
    this.windowStage = undefined;
    void this.closeApplicationComposition();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  private async loadTargetPage(): Promise<void> {
    const currentWindowStage: window.WindowStage | undefined = this.windowStage;
    if (currentWindowStage === undefined) {
      return;
    }
    const launchContext = getPhase1LaunchContext();
    if (launchContext.selfTest) {
      await this.closeApplicationComposition();
      await this.loadPage(currentWindowStage, SELF_TEST_ROUTE);
      return;
    }
    const applicationComposition: ApplicationComposition = this.applicationComposition ?? createApplicationComposition(this.context);
    this.applicationComposition = applicationComposition;
    void applicationComposition.initialize().catch(() => {
    });
    await this.loadPage(currentWindowStage, PRODUCTION_ROUTE);
  }

  private async closeApplicationComposition(): Promise<void> {
    const applicationComposition: ApplicationComposition | undefined = this.applicationComposition;
    this.applicationComposition = undefined;
    if (applicationComposition === undefined) {
      return;
    }
    await applicationComposition.close();
  }

  private async loadPage(windowStage: window.WindowStage, route: string): Promise<void> {
    await new Promise<void>((resolve) => {
      windowStage.loadContent(route, (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load the content.');
          resolve();
          return;
        }
        hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
        resolve();
      });
    });
  }
}
