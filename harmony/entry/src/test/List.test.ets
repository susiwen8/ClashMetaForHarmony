import { describe, expect, it } from '@ohos/hypium';
import applicationCompositionTestsuite from './ApplicationComposition.test';
import homeViewModelTestsuite from './HomeViewModel.test';
import harmonyVpnControllerTestsuite from './HarmonyVpnController.test';
import uiOwnedVpnExtensionAbilityApiTestsuite from './UiOwnedVpnExtensionAbilityApi.test';
import harmonyVpnConnectionDriverTestsuite from './HarmonyVpnConnectionDriver.test';
import importProfileViewModelTestsuite from './ImportProfileViewModel.test';
import profilesViewModelTestsuite from './ProfilesViewModel.test';
import profileDetailViewModelTestsuite from './ProfileDetailViewModel.test';
import proxyPresentationModelsTestsuite from './ProxyPresentationModels.test';
import proxyViewModelTestsuite from './ProxyViewModel.test';
import vpnEvidenceJournalTestsuite from './VpnEvidenceJournal.test';
import vpnExtensionCompositionTestsuite from './VpnExtensionComposition.test';
import vpnSessionRegistryTestsuite from './VpnSessionRegistry.test';
import vpnTrafficMonitorTestsuite from './VpnTrafficMonitor.test';
import subscriptionRefreshWorkAbilityTestsuite from './SubscriptionRefreshWorkAbility.test';
import vpnTrafficNotificationCoordinatorTestsuite from './VpnTrafficNotificationCoordinator.test';
import coreRuntimeLogCollectorTestsuite from './CoreRuntimeLogCollector.test';
import logsViewModelTestsuite from './LogsViewModel.test';

export default function testsuite() {
  applicationCompositionTestsuite();
  homeViewModelTestsuite();
  harmonyVpnControllerTestsuite();
  uiOwnedVpnExtensionAbilityApiTestsuite();
  harmonyVpnConnectionDriverTestsuite();
  importProfileViewModelTestsuite();
  profilesViewModelTestsuite();
  profileDetailViewModelTestsuite();
  proxyPresentationModelsTestsuite();
  proxyViewModelTestsuite();
  vpnEvidenceJournalTestsuite();
  vpnExtensionCompositionTestsuite();
  vpnSessionRegistryTestsuite();
  vpnTrafficMonitorTestsuite();
  subscriptionRefreshWorkAbilityTestsuite();
  vpnTrafficNotificationCoordinatorTestsuite();
  coreRuntimeLogCollectorTestsuite();
  logsViewModelTestsuite();
  describe('EntryListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
