import { describe, expect, it } from '@ohos/hypium';
import profileDomainTestsuite from './ProfileDomain.test';

export default function testsuite() {
  profileDomainTestsuite();
  describe('SharedListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
