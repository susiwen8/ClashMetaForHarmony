import { describe, expect, it } from '@ohos/hypium';
import {
  ProfilesViewModel,
  type ProfilesNavigationIntent
} from '../main/ets/presentation/ProfilesViewModel';
import {
  createApplicationSnapshot,
  createProfileSnapshot,
  PresentationTestApplication
} from './fakes/PresentationFakes';

function serialize(value: Object): string {
  return JSON.stringify(value);
}

export default function profilesViewModelTestsuite() {
  describe('ProfilesViewModelTest', () => {
    it('mapsRowsWithIndependentActiveAvailabilityAndRuntimeLocks', 0, () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('zeta', 'Zeta', 'https://zeta.example.com/profile.yaml?secret=1', 'VALID', '2026-08-11T12:32:00.000Z', true),
            createProfileSnapshot('alpha', 'Alpha', '/tmp/cmfa/profiles/alpha.yaml', 'INVALID', '2026-08-11T12:31:00.000Z', false)
          ],
          'alpha',
          'STOPPED'
        )
      );
      const viewModel = new ProfilesViewModel(application);
      const current = viewModel.current();

      expect(current.initialization).assertEqual('READY');
      expect(current.profiles.length).assertEqual(2);
      expect(current.profiles[0].id).assertEqual('zeta');
      expect(current.profiles[0].sourceDisplay).assertEqual('zeta.example.com');
      expect(current.profiles[0].active).assertFalse();
      expect(current.profiles[0].actionsLockedByRuntime).assertFalse();
      expect(current.profiles[1].id).assertEqual('alpha');
      expect(current.profiles[1].active).assertTrue();
      expect(current.profiles[1].availability).assertEqual('INVALID');
      expect(current.profiles[1].actionsLockedByRuntime).assertFalse();

      application.emitSnapshot(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('zeta', 'Zeta', 'https://zeta.example.com/profile.yaml?secret=1', 'VALID', '2026-08-11T12:32:00.000Z', true),
            createProfileSnapshot('alpha', 'Alpha', '/tmp/cmfa/profiles/alpha.yaml', 'INVALID', '2026-08-11T12:31:00.000Z', false)
          ],
          'alpha',
          'RUNNING'
        )
      );

      expect(viewModel.current().profiles[0].actionsLockedByRuntime).assertTrue();
      expect(viewModel.current().profiles[1].actionsLockedByRuntime).assertTrue();
      expect(serialize(viewModel.current()).includes('/tmp/cmfa/profiles')).assertFalse();
      expect(serialize(viewModel.current()).includes('secret=1')).assertFalse();
      expect(serialize(viewModel.current()).includes('CoreEvent')).assertFalse();
    });

    it('emitsNavigationIntentsLimitedToProfileIdOrAddSheetAndDisposesSubscriptions', 0, () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/config.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true)],
          'alpha',
          'STOPPED'
        )
      );
      const viewModel = new ProfilesViewModel(application);
      const intents: ProfilesNavigationIntent[] = [];
      const navigationId = viewModel.subscribeNavigation((intent: ProfilesNavigationIntent): void => {
        intents.push(intent);
      });

      viewModel.requestOpenProfile('alpha');
      viewModel.requestOpenAddSheet();
      viewModel.unsubscribeNavigation(navigationId);
      viewModel.requestOpenProfile('alpha');

      expect(intents.length).assertEqual(2);
      expect(intents[0].destination).assertEqual('PROFILE_DETAIL');
      expect(intents[0].profileId).assertEqual('alpha');
      expect(intents[1].destination).assertEqual('ADD_SHEET');
      expect(serialize(intents[0]).includes('https://')).assertFalse();
      expect(serialize(intents[1]).includes('yaml')).assertFalse();

      expect(application.listenerCount()).assertEqual(1);
      viewModel.dispose();
      expect(application.listenerCount()).assertEqual(0);
    });
  });
}
