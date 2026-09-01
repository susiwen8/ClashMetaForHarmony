import { describe, expect, it } from '@ohos/hypium';
import proxyDelayNativeCodecTestsuite from './ProxyDelayNativeCodec.test';
import proxyNativeCodecTestsuite from './ProxyNativeCodec.test';
import coreTunRuntimeTestsuite from './CoreTunRuntime.test';

export default function testsuite() {
  coreTunRuntimeTestsuite();
  proxyDelayNativeCodecTestsuite();
  proxyNativeCodecTestsuite();
  describe('CoreListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
