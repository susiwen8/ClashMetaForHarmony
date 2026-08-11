import { describe, expect, it } from '@ohos/hypium';
import profileRowCodecTestsuite from './ProfileRowCodec.test';
import rdbProfileRepositoryTestsuite from './RdbProfileRepository.test';

export default function testsuite() {
  profileRowCodecTestsuite();
  rdbProfileRepositoryTestsuite();
  describe('PlatformListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
