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
  setEvidenceStatus,
  TASK14_TEST_ABILITY_NAME,
  TASK14_TEST_MODULE_NAME,
  waitForTask14Completion,
  waitForTestAbilityContext
} from '../testability/TestAbility';

const DOMAIN: number = 0x0000;
const TAG: string = 'Task14Runner';
const TASK14_COMPLETION_TIMEOUT_MS: number = 120000;

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
      await waitForTask14CompletionOrTimeout();
      appendEvidenceTrace('runner.completionObserved');
      await flushEvidence();
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

async function waitForTask14CompletionOrTimeout(): Promise<void> {
  let timeoutId: number = -1;
  const barrier: Promise<void> = waitForTask14Completion().then(() => {
    if (timeoutId >= 0) {
      clearTimeout(timeoutId);
    }
  });
  const timeout: Promise<void> = new Promise<void>((_resolve, reject) => {
    timeoutId = setTimeout(() => {
      void failTask14CompletionTimeout(reject);
    }, TASK14_COMPLETION_TIMEOUT_MS) as number;
  });
  await Promise.race([barrier, timeout]);
}

async function failTask14CompletionTimeout(reject: (error: Error) => void): Promise<void> {
  setEvidenceStatus('FAIL');
  appendEvidenceFailure('OpenHarmonyTestRunner', 'Task 14 completion barrier timeout.');
  await flushEvidence();
  reject(new Error('Task 14 completion barrier timeout.'));
}

function toError(error: Object | undefined): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(`${error}`);
}
