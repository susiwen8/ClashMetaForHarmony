import { describe, expect, it } from '@ohos/hypium';
import profileRowCodecTestsuite from './ProfileRowCodec.test';
import rdbProfileRepositoryTestsuite from './RdbProfileRepository.test';
import rdbProfileRefreshLeaseStoreTestsuite from './RdbProfileRefreshLeaseStore.test';
import rdbProxySelectionRepositoryTestsuite from './RdbProxySelectionRepository.test';
import harmonyProxyIdentityHasherTestsuite from './HarmonyProxyIdentityHasher.test';
import harmonyVpnRpcKeyProviderTestsuite from './HarmonyVpnRpcKeyProvider.test';
import harmonyVpnLocalSocketClientTestsuite from './HarmonyVpnLocalSocketClient.test';
import harmonyVpnLocalSocketServerTestsuite from './HarmonyVpnLocalSocketServer.test';
import harmonyVpnRpcPlatformFactoryTestsuite from './HarmonyVpnRpcPlatformFactory.test';
import sandboxProfileContentStoreTestsuite from './SandboxProfileContentStore.test';
import harmonyFilePickerTestsuite from './HarmonyFilePicker.test';
import harmonyNetworkMonitorTestsuite from './HarmonyNetworkMonitor.test';
import harmonyNetworkConnectionDriverTestsuite from './HarmonyNetworkConnectionDriver.test';
import harmonyRuntimeLogStoreTestsuite from './HarmonyRuntimeLogStore.test';
import harmonyRuntimeLogExporterTestsuite from './HarmonyRuntimeLogExporter.test';
import harmonyVpnNotificationDriverTestsuite from './HarmonyVpnNotificationDriver.test';
import huksSubscriptionSecretStoreTestsuite from './HuksSubscriptionSecretStore.test';
import subscriptionDownloaderTestsuite from './SubscriptionDownloader.test';
import harmonyGeodataInstallerTestsuite from './HarmonyGeodataInstaller.test';
import platformFactoryTestsuite from './PlatformFactory.test';
import harmonyFileDriverTestsuite from './HarmonyFileDriver.test';
import harmonyVpnOwnershipStoreTestsuite from './HarmonyVpnOwnershipStore.test';

export default function testsuite() {
  profileRowCodecTestsuite();
  rdbProfileRepositoryTestsuite();
  rdbProfileRefreshLeaseStoreTestsuite();
  rdbProxySelectionRepositoryTestsuite();
  harmonyProxyIdentityHasherTestsuite();
  harmonyVpnRpcKeyProviderTestsuite();
  harmonyVpnLocalSocketClientTestsuite();
  harmonyVpnLocalSocketServerTestsuite();
  harmonyVpnRpcPlatformFactoryTestsuite();
  sandboxProfileContentStoreTestsuite();
  harmonyFilePickerTestsuite();
  harmonyNetworkMonitorTestsuite();
  harmonyNetworkConnectionDriverTestsuite();
  harmonyRuntimeLogStoreTestsuite();
  harmonyRuntimeLogExporterTestsuite();
  harmonyVpnNotificationDriverTestsuite();
  huksSubscriptionSecretStoreTestsuite();
  subscriptionDownloaderTestsuite();
  harmonyGeodataInstallerTestsuite();
  harmonyFileDriverTestsuite();
  harmonyVpnOwnershipStoreTestsuite();
  platformFactoryTestsuite();
  describe('PlatformListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
