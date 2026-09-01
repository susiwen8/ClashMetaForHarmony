import { describe, expect, it } from '@ohos/hypium';
import {
  ProfilesViewModel,
  type ProfilesNavigationIntent
} from '../main/ets/presentation/ProfilesViewModel';
import {
  createApplicationSnapshot,
  createFailedRefreshAllSubscriptionsResult,
  createProfileSnapshot,
  createRefreshAllSubscriptionsCompletedResult,
  PresentationTestApplication
} from './fakes/PresentationFakes';

function serialize(value: Object): string {
  return JSON.stringify(value);
}

export default function profilesViewModelTestsuite() {
  describe('ProfilesViewModelTest', () => {
    it('mapsRowsWithoutExposingRuntimeLocks', 0, () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot(
              'zeta',
              'Zeta',
              'https://zeta.example.com/profile.yaml?secret=1',
              'VALID',
              '2026-08-11T12:32:00.000Z',
              true
            ),
            createProfileSnapshot(
              'alpha',
              'Alpha',
              '/tmp/cmfa/profiles/alpha.yaml',
              'INVALID',
              '2026-08-11T12:31:00.000Z',
              false
            ),
            createProfileSnapshot(
              'omega',
              'Omega',
              'https://omega.example.com/subscription.yaml?token=2',
              'UPDATE_FAILED_USING_VALID',
              '2026-08-11T12:33:00.000Z',
              true
            )
          ],
          'alpha',
          'STOPPED'
        )
      );
      const viewModel = new ProfilesViewModel(application);
      const current = viewModel.current();

      expect(current.initialization).assertEqual('READY');
      expect(current.profiles.length).assertEqual(3);
      expect(current.profiles[0].id).assertEqual('zeta');
      expect(current.profiles[0].sourceDisplay).assertEqual('zeta.example.com');
      expect(current.profiles[0].sourceKind).assertEqual('REMOTE_URL');
      expect(current.profiles[0].active).assertFalse();
      expect(current.profiles[1].id).assertEqual('alpha');
      expect(current.profiles[1].sourceKind).assertEqual('LOCAL_FILE');
      expect(current.profiles[1].active).assertTrue();
      expect(current.profiles[1].availability).assertEqual('INVALID');
      expect(current.profiles[2].sourceKind).assertEqual('REMOTE_URL');
      expect(current.summary?.totalCount).assertEqual(3);
      expect(current.summary?.remoteCount).assertEqual(2);
      expect(current.summary?.localCount).assertEqual(1);
      expect(current.summary?.validCount).assertEqual(1);
      expect(current.summary?.invalidCount).assertEqual(1);
      expect(current.summary?.updateFailedUsingValidCount).assertEqual(1);
      expect(current.pendingRefreshCount).assertEqual(0);
      expect(current.completedRefreshCount).assertEqual(0);
      expect(current.totalRefreshCount).assertEqual(0);

      application.emitSnapshot(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot(
              'zeta',
              'Zeta',
              'https://zeta.example.com/profile.yaml?secret=1',
              'VALID',
              '2026-08-11T12:32:00.000Z',
              true
            ),
            createProfileSnapshot(
              'alpha',
              'Alpha',
              '/tmp/cmfa/profiles/alpha.yaml',
              'INVALID',
              '2026-08-11T12:31:00.000Z',
              false
            ),
            createProfileSnapshot(
              'omega',
              'Omega',
              'https://omega.example.com/subscription.yaml?token=2',
              'UPDATE_FAILED_USING_VALID',
              '2026-08-11T12:33:00.000Z',
              true
            )
          ],
          'alpha',
          'RUNNING'
        )
      );

      expect(viewModel.current().profiles[0].active).assertFalse();
      expect(viewModel.current().profiles[1].active).assertTrue();
      expect(viewModel.current().profiles[1].availability).assertEqual('INVALID');
      expect(serialize(viewModel.current()).includes('actionsLockedByRuntime')).assertFalse();
      expect(serialize(viewModel.current()).includes('/tmp/cmfa/profiles')).assertFalse();
      expect(serialize(viewModel.current()).includes('secret=1')).assertFalse();
      expect(serialize(viewModel.current()).includes('token=2')).assertFalse();
      expect(serialize(viewModel.current()).includes('CoreEvent')).assertFalse();
    });

    it('requestRefreshAllSkipsWhenNoRemoteProfilesExist', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha', '/tmp/cmfa/profiles/alpha.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'LOCAL_FILE'
            })
          ],
          'alpha',
          'STOPPED'
        )
      );
      const viewModel = new ProfilesViewModel(application);

      await viewModel.requestRefreshAll();

      const current = viewModel.current();
      expect(application.refreshAllSubscriptionsCallCount()).assertEqual(0);
      expect(current.summary?.remoteCount).assertEqual(0);
      expect(current.pendingRefreshCount).assertEqual(0);
      expect(current.totalRefreshCount).assertEqual(0);
      expect(current.refreshAllError).assertUndefined();
    });

    it('requestRefreshAllIgnoresReentryWhilePending', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/config.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true)],
          'alpha',
          'STOPPED'
        )
      );
      const deferred = application.deferRefreshAllSubscriptions();
      const viewModel = new ProfilesViewModel(application);

      const first = viewModel.requestRefreshAll();
      const pending = viewModel.current();
      const second = viewModel.requestRefreshAll();

      expect(application.refreshAllSubscriptionsCallCount()).assertEqual(1);
      expect(pending.pendingRefreshCount).assertEqual(1);
      expect(pending.totalRefreshCount).assertEqual(1);

      deferred.resolve(createRefreshAllSubscriptionsCompletedResult([
        { profileId: 'alpha', status: 'SUCCESS' }
      ]));
      await first;
      await second;

      expect(application.refreshAllSubscriptionsCallCount()).assertEqual(1);
      expect(viewModel.current().pendingRefreshCount).assertEqual(0);
    });

    it('requestRefreshAllPublishesCompletedCountsFromBatchResult', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/config.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true),
            createProfileSnapshot('beta', 'Beta', 'https://beta.example.com/config.yaml', 'UPDATE_FAILED_USING_VALID', '2026-08-11T12:32:00.000Z', true),
            createProfileSnapshot('gamma', 'Gamma', '/tmp/cmfa/profiles/gamma.yaml', 'INVALID', '2026-08-11T12:33:00.000Z', false, {
              sourceKind: 'LOCAL_FILE'
            })
          ],
          'alpha',
          'STOPPED'
        )
      );
      application.queueRefreshAllSubscriptionsResult(
        createRefreshAllSubscriptionsCompletedResult([
          { profileId: 'alpha', status: 'SUCCESS' },
          { profileId: 'beta', status: 'FAILED_USING_CURRENT' }
        ])
      );
      const viewModel = new ProfilesViewModel(application);

      await viewModel.requestRefreshAll();

      const current = viewModel.current();
      expect(application.refreshAllSubscriptionsCallCount()).assertEqual(1);
      expect(current.pendingRefreshCount).assertEqual(0);
      expect(current.completedRefreshCount).assertEqual(2);
      expect(current.totalRefreshCount).assertEqual(2);
      expect(current.refreshAllError).assertUndefined();
    });

    it('requestRefreshAllPublishesSafeFailureError', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/config.yaml?secret=1', 'VALID', '2026-08-11T12:31:00.000Z', true)],
          'alpha',
          'STOPPED'
        )
      );
      application.queueRefreshAllSubscriptionsResult(
        createFailedRefreshAllSubscriptionsResult(
          'SUBSCRIPTION_REFRESH_ALL_FAILED',
          'RUNTIME_START',
          'refresh alpha with secret=1 failed'
        )
      );
      const viewModel = new ProfilesViewModel(application);

      await viewModel.requestRefreshAll();

      const current = viewModel.current();
      expect(current.pendingRefreshCount).assertEqual(0);
      expect(current.completedRefreshCount).assertEqual(0);
      expect(current.totalRefreshCount).assertEqual(1);
      expect(current.refreshAllError?.code).assertEqual('SUBSCRIPTION_REFRESH_ALL_FAILED');
      expect(serialize(current.refreshAllError as Object).includes('secret=1')).assertFalse();
      expect(serialize(current).includes('alpha.example.com/config.yaml?secret=1')).assertFalse();
    });

    it('keepsRefreshAllPendingStateAcrossApplicationSnapshots', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/config.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true)],
          'alpha',
          'STOPPED'
        )
      );
      const deferred = application.deferRefreshAllSubscriptions();
      const viewModel = new ProfilesViewModel(application);

      const refreshPromise = viewModel.requestRefreshAll();
      application.emitSnapshot(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha 2', 'https://alpha.example.com/config.yaml?secret=2', 'UPDATE_FAILED_USING_VALID', '2026-08-11T12:35:00.000Z', true)
          ],
          'alpha',
          'RUNNING'
        )
      );

      const pending = viewModel.current();
      expect(pending.pendingRefreshCount).assertEqual(1);
      expect(pending.totalRefreshCount).assertEqual(1);
      expect(pending.completedRefreshCount).assertEqual(0);
      expect(pending.profiles[0].name).assertEqual('Alpha 2');
      expect(pending.profiles[0].sourceDisplay).assertEqual('alpha.example.com');
      expect(serialize(pending).includes('secret=2')).assertFalse();

      deferred.resolve(createRefreshAllSubscriptionsCompletedResult([
        { profileId: 'alpha', status: 'SUCCESS' }
      ]));
      await refreshPromise;

      expect(viewModel.current().pendingRefreshCount).assertEqual(0);
      expect(viewModel.current().completedRefreshCount).assertEqual(1);
    });

    it('ignoresDeferredRefreshAllCompletionAfterDispose', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/config.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true)],
          'alpha',
          'STOPPED'
        )
      );
      const deferred = application.deferRefreshAllSubscriptions();
      const viewModel = new ProfilesViewModel(application);

      const refreshPromise = viewModel.requestRefreshAll();
      viewModel.dispose();
      deferred.resolve(createRefreshAllSubscriptionsCompletedResult([
        { profileId: 'alpha', status: 'SUCCESS' }
      ]));
      await refreshPromise;

      expect(application.listenerCount()).assertEqual(0);
      expect(viewModel.current().pendingRefreshCount).assertEqual(1);
      expect(viewModel.current().completedRefreshCount).assertEqual(0);
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
