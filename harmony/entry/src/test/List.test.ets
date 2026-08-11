import { describe, expect, it } from '@ohos/hypium';
import applicationCompositionTestsuite from './ApplicationComposition.test';
import homeViewModelTestsuite from './HomeViewModel.test';
import importProfileViewModelTestsuite from './ImportProfileViewModel.test';
import profilesViewModelTestsuite from './ProfilesViewModel.test';
import profileDetailViewModelTestsuite from './ProfileDetailViewModel.test';

export default function testsuite() {
  applicationCompositionTestsuite();
  homeViewModelTestsuite();
  importProfileViewModelTestsuite();
  profilesViewModelTestsuite();
  profileDetailViewModelTestsuite();
  describe('EntryListTest', () => {
    it('contains a baseline passing case', 0, () => {
      expect(true).assertTrue();
    });
  });
}
