import { describe, expect, it } from '@ohos/hypium';
import coreTunRuntimeTestsuite from './CoreTunRuntime.test';

export default function testsuite() {
  coreTunRuntimeTestsuite();
  describe('CoreListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
