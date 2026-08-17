import { describe, expect, it } from '@ohos/hypium';
import directTrafficProbeTestsuite from './DirectTrafficProbe.test';
import probeAbilityTestsuite from './ProbeAbility.test';

export default function testsuite() {
  directTrafficProbeTestsuite();
  probeAbilityTestsuite();
  describe('ProbeEntryListTest', () => {
    it('containsABaselinePassingCase', 0, () => {
      expect(true).assertTrue();
    });
  });
}
