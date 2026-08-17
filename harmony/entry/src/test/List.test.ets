import { describe, expect, it } from '@ohos/hypium';
import applicationCompositionTestsuite from './ApplicationComposition.test';
import homeViewModelTestsuite from './HomeViewModel.test';
import harmonyVpnControllerTestsuite from './HarmonyVpnController.test';
import harmonyVpnConnectionDriverTestsuite from './HarmonyVpnConnectionDriver.test';
import importProfileViewModelTestsuite from './ImportProfileViewModel.test';
import profilesViewModelTestsuite from './ProfilesViewModel.test';
import profileDetailViewModelTestsuite from './ProfileDetailViewModel.test';
import vpnEvidenceJournalTestsuite from './VpnEvidenceJournal.test';
import vpnExtensionCompositionTestsuite from './VpnExtensionComposition.test';
import vpnSessionRegistryTestsuite from './VpnSessionRegistry.test';

export default function testsuite() {
  applicationCompositionTestsuite();
  homeViewModelTestsuite();
  harmonyVpnControllerTestsuite();
  harmonyVpnConnectionDriverTestsuite();
  importProfileViewModelTestsuite();
  profilesViewModelTestsuite();
  profileDetailViewModelTestsuite();
  vpnEvidenceJournalTestsuite();
  vpnExtensionCompositionTestsuite();
  vpnSessionRegistryTestsuite();
  describe('EntryListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
