import { describe, expect, it } from '@ohos/hypium';
import profileRowCodecTestsuite from './ProfileRowCodec.test';
import rdbProfileRepositoryTestsuite from './RdbProfileRepository.test';
import sandboxProfileContentStoreTestsuite from './SandboxProfileContentStore.test';
import harmonyFilePickerTestsuite from './HarmonyFilePicker.test';
import huksSubscriptionSecretStoreTestsuite from './HuksSubscriptionSecretStore.test';
import subscriptionDownloaderTestsuite from './SubscriptionDownloader.test';

export default function testsuite() {
  profileRowCodecTestsuite();
  rdbProfileRepositoryTestsuite();
  sandboxProfileContentStoreTestsuite();
  harmonyFilePickerTestsuite();
  huksSubscriptionSecretStoreTestsuite();
  subscriptionDownloaderTestsuite();
  describe('PlatformListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
