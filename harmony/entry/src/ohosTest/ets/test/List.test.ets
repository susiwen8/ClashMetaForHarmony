import { describe, expect, it } from '@ohos/hypium';
import Phase3PlatformAdaptersTestsuite from './Phase3PlatformAdapters.test';
import Phase3RuntimeFlowTestsuite from './Phase3RuntimeFlow.test';
import Phase3UiFlowTestsuite from './Phase3UiFlow.test';
import {
  appendEvidenceFailure,
  flushEvidence,
  getEvidence,
  setEvidenceStatus,
  signalTask14Completion
} from '../testability/TestAbility';

export default function testsuite(): void {
  Phase3PlatformAdaptersTestsuite();
  Phase3RuntimeFlowTestsuite();
  Phase3UiFlowTestsuite();
  describe('Task14Finalization', () => {
    it('flushes evidence and releases the Task 14 completion barrier', 0, async () => {
      let finalizationError: Error | undefined = undefined;
      try {
        if (getEvidence().failures.length === 0) {
          setEvidenceStatus('PASS');
        } else {
          setEvidenceStatus('FAIL');
        }
      } catch (error) {
        setEvidenceStatus('FAIL');
        appendEvidenceFailure('Task14Finalization', `${error}`);
        throw toError(error);
      } finally {
        try {
          await flushEvidence();
        } catch (_) {
          setEvidenceStatus('FAIL');
          appendEvidenceFailure('Task14Finalization', 'Task 14 final evidence flush failed.');
          finalizationError = new Error('Task 14 final evidence flush failed.');
          try {
            await flushEvidence();
          } catch (_) {
          }
        } finally {
          signalTask14Completion();
        }
      }
      if (finalizationError !== undefined) {
        throw finalizationError;
      }
    });
  });
}

function toError(error: Object | undefined): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(`${error}`);
}
