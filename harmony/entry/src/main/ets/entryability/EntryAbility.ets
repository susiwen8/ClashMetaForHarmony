import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

import { Phase1LaunchContext, setPhase1LaunchContext } from '../bootstrap/CoreComposition';

const DOMAIN = 0x0000;

const SELF_TEST_KEY = 'cmfa.phase1.selfTest';
const RUN_ID_KEY = 'cmfa.phase1.runId';
const RUNNER_STARTED_AT_KEY = 'cmfa.phase1.runnerStartedAt';
const FILES_DIR_KEY = 'cmfa.phase1.filesDir';
const PROBE_ORIGIN_URL_KEY = 'cmfa.phase2.originUrl';
const PROBE_CA_PEM_KEY = 'cmfa.phase2.caPem';
const PROBE_EXPECTED_BODY_SHA256_KEY = 'cmfa.phase2.expectedBodySha256';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyPhase1Parameters(want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyPhase1Parameters(want);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/CoreDebugPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
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

  private applyPhase1Parameters(want: Want): void {
    const parameters: Record<string, Object> = want.parameters ?? {};
    const selfTestValue: string = `${parameters[SELF_TEST_KEY] ?? ''}`;
    const launchContext: Phase1LaunchContext = {
      selfTest: selfTestValue === 'true',
      runId: `${parameters[RUN_ID_KEY] ?? ''}`,
      runnerStartedAt: `${parameters[RUNNER_STARTED_AT_KEY] ?? ''}`,
      filesDir: this.context.filesDir,
      probeOriginUrl: `${parameters[PROBE_ORIGIN_URL_KEY] ?? ''}`,
      probeCaPem: `${parameters[PROBE_CA_PEM_KEY] ?? ''}`,
      probeExpectedBodySha256: `${parameters[PROBE_EXPECTED_BODY_SHA256_KEY] ?? ''}`
    };
    setPhase1LaunchContext(launchContext);
  }
}
