import { describe, expect, it } from '@ohos/hypium';
import applicationCompositionTestsuite from './ApplicationComposition.test';

export default function testsuite() {
  applicationCompositionTestsuite();
  describe('EntryListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
