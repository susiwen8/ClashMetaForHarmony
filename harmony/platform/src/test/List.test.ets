import { describe, expect, it } from '@ohos/hypium';
import profileRowCodecTestsuite from './ProfileRowCodec.test';
import rdbProfileRepositoryTestsuite from './RdbProfileRepository.test';
import sandboxProfileContentStoreTestsuite from './SandboxProfileContentStore.test';
import harmonyFilePickerTestsuite from './HarmonyFilePicker.test';
import harmonyNetworkMonitorTestsuite from './HarmonyNetworkMonitor.test';
import harmonyVpnNotificationDriverTestsuite from './HarmonyVpnNotificationDriver.test';
import huksSubscriptionSecretStoreTestsuite from './HuksSubscriptionSecretStore.test';
import subscriptionDownloaderTestsuite from './SubscriptionDownloader.test';
import platformFactoryTestsuite from './PlatformFactory.test';

export default function testsuite() {
  profileRowCodecTestsuite();
  rdbProfileRepositoryTestsuite();
  sandboxProfileContentStoreTestsuite();
  harmonyFilePickerTestsuite();
  harmonyNetworkMonitorTestsuite();
  harmonyVpnNotificationDriverTestsuite();
  huksSubscriptionSecretStoreTestsuite();
  subscriptionDownloaderTestsuite();
  platformFactoryTestsuite();
  describe('PlatformListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
