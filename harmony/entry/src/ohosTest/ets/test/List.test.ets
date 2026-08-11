import { describe, expect, it } from '@ohos/hypium';
import Phase3PlatformAdaptersTestsuite from './Phase3PlatformAdapters.test';
import Phase3RuntimeFlowTestsuite from './Phase3RuntimeFlow.test';
import Phase3UiFlowTestsuite from './Phase3UiFlow.test';

export default function testsuite(): void {
  Phase3PlatformAdaptersTestsuite();
  Phase3RuntimeFlowTestsuite();
  Phase3UiFlowTestsuite();
  describe('Task14ListTest', () => {
    it('registers the deterministic Task 14 suites', 0, () => {
      expect(true).assertTrue();
    });
  });
}
