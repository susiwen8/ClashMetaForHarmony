import { describe, expect, it } from '@ohos/hypium';
import directTrafficProbeTestsuite from './DirectTrafficProbe.test';

export default function testsuite() {
  directTrafficProbeTestsuite();
  describe('ProbeEntryListTest', () => {
    it('containsABaselinePassingCase', 0, () => {
      expect(true).assertTrue();
    });
  });
}
