import { describe, expect, it } from '@ohos/hypium';
import localRuntimeCoordinatorTestsuite from './LocalRuntimeCoordinator.test';
import profileDomainTestsuite from './ProfileDomain.test';
import profileImportUseCasesTestsuite from './ProfileImportUseCases.test';
import profileManagementTestsuite from './ProfileManagement.test';
import vpnModelsTestsuite from './VpnModels.test';
import vpnRuntimeCoordinatorTestsuite from './VpnRuntimeCoordinator.test';

export default function testsuite() {
  profileDomainTestsuite();
  profileImportUseCasesTestsuite();
  profileManagementTestsuite();
  localRuntimeCoordinatorTestsuite();
  vpnModelsTestsuite();
  vpnRuntimeCoordinatorTestsuite();
  describe('SharedListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
