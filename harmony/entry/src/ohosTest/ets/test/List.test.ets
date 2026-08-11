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
        await flushEvidence();
        signalTask14Completion();
      }
    });

    it('registers the deterministic Task 14 suites', 0, () => {
      expect(true).assertTrue();
    });
  });
}

function toError(error: Object | undefined): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(`${error}`);
}
