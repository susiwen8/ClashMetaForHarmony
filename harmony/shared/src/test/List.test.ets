import { describe, expect, it } from '@ohos/hypium';
import profileDomainTestsuite from './ProfileDomain.test';
import profileImportUseCasesTestsuite from './ProfileImportUseCases.test';

export default function testsuite() {
  profileDomainTestsuite();
  profileImportUseCasesTestsuite();
  describe('SharedListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
