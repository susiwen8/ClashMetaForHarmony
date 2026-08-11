import { describe, expect, it } from '@ohos/hypium';
import applicationCompositionTestsuite from './ApplicationComposition.test';
import homeViewModelTestsuite from './HomeViewModel.test';
import profilesViewModelTestsuite from './ProfilesViewModel.test';

export default function testsuite() {
  applicationCompositionTestsuite();
  homeViewModelTestsuite();
  profilesViewModelTestsuite();
  describe('EntryListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
