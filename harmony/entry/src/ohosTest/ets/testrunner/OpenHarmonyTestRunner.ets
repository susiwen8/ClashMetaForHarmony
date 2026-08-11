import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
import testsuite from '../test/List.test';
import {
  appendEvidenceFailure,
  appendEvidenceTrace,
  flushEvidence,
  TASK14_TEST_ABILITY_NAME,
  TASK14_TEST_MODULE_NAME,
  waitForTestAbilityContext
} from '../testability/TestAbility';

const DOMAIN: number = 0x0000;
const TAG: string = 'Task14Runner';

export default class OpenHarmonyTestRunner implements TestRunner {
  onPrepare(): void {
    appendEvidenceTrace('runner.onPrepare');
    void flushEvidence();
    hilog.info(DOMAIN, TAG, '%{public}s', 'OpenHarmonyTestRunner onPrepare');
  }

  async onRun(): Promise<void> {
    const abilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
    const abilityDelegatorArguments = abilityDelegatorRegistry.getArguments();
    appendEvidenceTrace('runner.onRun');
    await flushEvidence();
    try {
      const want: Want = {
        bundleName: abilityDelegatorArguments.bundleName,
        moduleName: TASK14_TEST_MODULE_NAME,
        abilityName: TASK14_TEST_ABILITY_NAME
      };
      await abilityDelegator.startAbility(want);
      appendEvidenceTrace('runner.startAbility');
      await waitForTestAbilityContext();
      appendEvidenceTrace('runner.contextReady');
      await flushEvidence();
      Hypium.hypiumTest(abilityDelegator, abilityDelegatorArguments, testsuite);
    } catch (error) {
      appendEvidenceFailure('OpenHarmonyTestRunner', describeBusinessError(error));
      await flushEvidence();
      throw toError(error);
    }
  }
}

function describeBusinessError(error: Object | undefined): string {
  const record = error as BusinessError;
  if (record !== undefined && typeof record.message === 'string' && record.message.length > 0) {
    return record.message;
  }
  return `${error}`;
}

function toError(error: Object | undefined): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(`${error}`);
}
