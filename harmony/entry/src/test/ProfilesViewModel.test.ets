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
      expect(current.refreshAllSummary).assertUndefined();
      expect(current.refreshAllPending).assertFalse();
      expect(current.completedRefreshCount).assertEqual(0);
      expect(current.remainingRefreshCount).assertEqual(0);
      expect(current.totalRefreshCount).assertEqual(0);
      expect(current.refreshAllInterrupted).assertFalse();

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
      expect(current.refreshAllSummary).assertUndefined();
      expect(current.refreshAllPending).assertFalse();
      expect(current.remainingRefreshCount).assertEqual(0);
      expect(current.totalRefreshCount).assertEqual(0);
      expect(current.refreshAllInterrupted).assertFalse();
      expect(current.refreshAllError).assertUndefined();
    });

    it('requestRefreshAllIgnoresReentryWhileRefreshAllPending', 0, async () => {
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
      expect(pending.refreshAllPending).assertTrue();
      expect(pending.completedRefreshCount).assertEqual(0);
      expect(pending.remainingRefreshCount).assertEqual(1);
      expect(pending.totalRefreshCount).assertEqual(1);
      expect(pending.refreshAllInterrupted).assertFalse();

      deferred.resolve(createRefreshAllSubscriptionsCompletedResult([
        { profileId: 'alpha', status: 'SUCCESS' }
      ]));
      await first;
      await second;

      expect(application.refreshAllSubscriptionsCallCount()).assertEqual(1);
      expect(viewModel.current().refreshAllPending).assertFalse();
    });

    it('requestRefreshAllPublishesFullBatchCompletionWithoutInterruption', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/config.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true),
            createProfileSnapshot('beta', 'Beta', 'https://beta.example.com/config.yaml', 'UPDATE_FAILED_USING_VALID', '2026-08-11T12:32:00.000Z', true),
            createProfileSnapshot('gamma', 'Gamma', 'https://gamma.example.com/config.yaml', 'INVALID', '2026-08-11T12:33:00.000Z', false),
            createProfileSnapshot('delta', 'Delta', 'https://delta.example.com/config.yaml', 'VALID', '2026-08-11T12:34:00.000Z', true),
            createProfileSnapshot('epsilon', 'Epsilon', 'https://epsilon.example.com/config.yaml', 'VALID', '2026-08-11T12:35:00.000Z', true),
            createProfileSnapshot('zeta', 'Zeta', 'https://zeta.example.com/config.yaml', 'VALID', '2026-08-11T12:36:00.000Z', true)
          ],
          'alpha',
          'STOPPED'
        )
      );
      application.queueRefreshAllSubscriptionsResult(
        createRefreshAllSubscriptionsCompletedResult([
          { profileId: 'alpha', status: 'SUCCESS' },
          { profileId: 'beta', status: 'FAILED_USING_CURRENT' },
          { profileId: 'gamma', status: 'FAILED' },
          { profileId: 'delta', status: 'SKIPPED_HTTP' },
          { profileId: 'epsilon', status: 'SKIPPED_NOT_DUE' },
          { profileId: 'zeta', status: 'BUSY' }
        ])
      );
      const viewModel = new ProfilesViewModel(application);

      await viewModel.requestRefreshAll();

      const current = viewModel.current();
      expect(application.refreshAllSubscriptionsCallCount()).assertEqual(1);
      expect(current.refreshAllPending).assertFalse();
      expect(current.completedRefreshCount).assertEqual(6);
      expect(current.remainingRefreshCount).assertEqual(0);
      expect(current.totalRefreshCount).assertEqual(6);
      expect(current.refreshAllInterrupted).assertFalse();
      expect(current.refreshAllSummary?.success).assertEqual(1);
      expect(current.refreshAllSummary?.failedUsingCurrent).assertEqual(1);
      expect(current.refreshAllSummary?.failed).assertEqual(1);
      expect(current.refreshAllSummary?.skippedHttp).assertEqual(1);
      expect(current.refreshAllSummary?.skippedNotDue).assertEqual(1);
      expect(current.refreshAllSummary?.busy).assertEqual(1);
      expect(serialize(current.refreshAllSummary as Object).includes('profileId')).assertFalse();
      expect(serialize(current.refreshAllSummary as Object).includes('https://')).assertFalse();
      expect(serialize(current.refreshAllSummary as Object).includes('.example.com')).assertFalse();
      expect(current.refreshAllError).assertUndefined();

      application.emitSnapshot(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha 2', 'https://alpha.example.com/config.yaml?secret=1', 'VALID', '2026-08-11T12:37:00.000Z', true)
          ],
          'alpha',
          'RUNNING'
        )
      );

      expect(viewModel.current().refreshAllSummary?.success).assertEqual(1);
      expect(viewModel.current().refreshAllSummary?.failedUsingCurrent).assertEqual(1);
      expect(viewModel.current().refreshAllSummary?.failed).assertEqual(1);
    });

    it('requestRefreshAllPublishesDeadlineInterruptedBatchCounts', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/config.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true),
            createProfileSnapshot('beta', 'Beta', 'https://beta.example.com/config.yaml', 'UPDATE_FAILED_USING_VALID', '2026-08-11T12:32:00.000Z', true),
            createProfileSnapshot('gamma', 'Gamma', 'https://gamma.example.com/config.yaml', 'INVALID', '2026-08-11T12:33:00.000Z', false),
            createProfileSnapshot('delta', 'Delta', 'https://delta.example.com/config.yaml', 'VALID', '2026-08-11T12:34:00.000Z', true),
            createProfileSnapshot('epsilon', 'Epsilon', 'https://epsilon.example.com/config.yaml', 'VALID', '2026-08-11T12:35:00.000Z', true)
          ],
          'alpha',
          'STOPPED'
        )
      );
      application.queueRefreshAllSubscriptionsResult(
        createRefreshAllSubscriptionsCompletedResult(
          [
            { profileId: 'alpha', status: 'SUCCESS' },
            { profileId: 'beta', status: 'SKIPPED_HTTP' }
          ],
          true,
          false,
          3
        )
      );
      const viewModel = new ProfilesViewModel(application);

      await viewModel.requestRefreshAll();

      const current = viewModel.current();
      expect(current.refreshAllPending).assertFalse();
      expect(current.completedRefreshCount).assertEqual(2);
      expect(current.remainingRefreshCount).assertEqual(3);
      expect(current.totalRefreshCount).assertEqual(5);
      expect(current.refreshAllInterrupted).assertTrue();
      expect(current.refreshAllSummary?.success).assertEqual(1);
      expect(current.refreshAllSummary?.failedUsingCurrent).assertEqual(0);
      expect(current.refreshAllSummary?.failed).assertEqual(0);
      expect(current.refreshAllSummary?.skippedHttp).assertEqual(1);
      expect(current.refreshAllSummary?.skippedNotDue).assertEqual(0);
      expect(current.refreshAllSummary?.busy).assertEqual(0);
      expect(serialize(current.refreshAllSummary as Object).includes('profileId')).assertFalse();
      expect(serialize(current.refreshAllSummary as Object).includes('https://')).assertFalse();
    });

    it('requestRefreshAllPublishesCancelledBatchAsInterrupted', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/config.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true),
            createProfileSnapshot('beta', 'Beta', 'https://beta.example.com/config.yaml', 'UPDATE_FAILED_USING_VALID', '2026-08-11T12:32:00.000Z', true)
          ],
          'alpha',
          'STOPPED'
        )
      );
      application.queueRefreshAllSubscriptionsResult(
        createRefreshAllSubscriptionsCompletedResult(
          [{ profileId: 'alpha', status: 'SUCCESS' }],
          false,
          true,
          1
        )
      );
      const viewModel = new ProfilesViewModel(application);

      await viewModel.requestRefreshAll();

      const current = viewModel.current();
      expect(current.refreshAllPending).assertFalse();
      expect(current.completedRefreshCount).assertEqual(1);
      expect(current.remainingRefreshCount).assertEqual(1);
      expect(current.totalRefreshCount).assertEqual(2);
      expect(current.refreshAllInterrupted).assertTrue();
      expect(current.refreshAllSummary?.success).assertEqual(1);
      expect(current.refreshAllSummary?.failedUsingCurrent).assertEqual(0);
      expect(current.refreshAllSummary?.failed).assertEqual(0);
      expect(current.refreshAllSummary?.skippedHttp).assertEqual(0);
      expect(current.refreshAllSummary?.skippedNotDue).assertEqual(0);
      expect(current.refreshAllSummary?.busy).assertEqual(0);
    });

    it('requestRefreshAllPublishesSafeFailureErrorAndRetainsRemainingRemoteCount', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/config.yaml?secret=1', 'VALID', '2026-08-11T12:31:00.000Z', true),
            createProfileSnapshot('beta', 'Beta', 'https://beta.example.com/config.yaml?secret=2', 'UPDATE_FAILED_USING_VALID', '2026-08-11T12:32:00.000Z', true)
          ],
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
      expect(current.refreshAllPending).assertFalse();
      expect(current.completedRefreshCount).assertEqual(0);
      expect(current.remainingRefreshCount).assertEqual(2);
      expect(current.totalRefreshCount).assertEqual(2);
      expect(current.refreshAllInterrupted).assertTrue();
      expect(current.refreshAllSummary).assertUndefined();
      expect(current.refreshAllError?.code).assertEqual('SUBSCRIPTION_REFRESH_ALL_FAILED');
      expect(serialize(current.refreshAllError as Object).includes('secret=1')).assertFalse();
      expect(serialize(current).includes('secret=1')).assertFalse();
      expect(serialize(current).includes('secret=2')).assertFalse();
    });

    it('requestRefreshAllPublishesFixedSafeErrorWhenPromiseRejects', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/config.yaml?secret=1', 'VALID', '2026-08-11T12:31:00.000Z', true),
            createProfileSnapshot('beta', 'Beta', 'https://beta.example.com/config.yaml?secret=2', 'VALID', '2026-08-11T12:32:00.000Z', true)
          ],
          'alpha',
          'STOPPED'
        )
      );
      application.queueRefreshAllSubscriptionsRejection();
      const viewModel = new ProfilesViewModel(application);

      await viewModel.requestRefreshAll();

      const current = viewModel.current();
      expect(current.refreshAllPending).assertFalse();
      expect(current.completedRefreshCount).assertEqual(0);
      expect(current.remainingRefreshCount).assertEqual(2);
      expect(current.totalRefreshCount).assertEqual(2);
      expect(current.refreshAllInterrupted).assertTrue();
      expect(current.refreshAllSummary).assertUndefined();
      expect(current.refreshAllError?.code).assertEqual('SUBSCRIPTION_REFRESH_ALL_FAILED');
      expect(current.refreshAllError?.retryable).assertTrue();
      expect(current.refreshAllError?.technicalDetail).assertEqual('Subscription refresh failed before completion.');
      expect(serialize(current.refreshAllError as Object).includes('refresh-all rejected')).assertFalse();
      expect(serialize(current.refreshAllError as Object).includes('secret=1')).assertFalse();
      expect(serialize(current.refreshAllError as Object).includes('secret=2')).assertFalse();
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
      expect(pending.refreshAllPending).assertTrue();
      expect(pending.totalRefreshCount).assertEqual(1);
      expect(pending.completedRefreshCount).assertEqual(0);
      expect(pending.remainingRefreshCount).assertEqual(1);
      expect(pending.refreshAllInterrupted).assertFalse();
      expect(pending.profiles[0].name).assertEqual('Alpha 2');
      expect(pending.profiles[0].sourceDisplay).assertEqual('alpha.example.com');
      expect(serialize(pending).includes('secret=2')).assertFalse();

      deferred.resolve(createRefreshAllSubscriptionsCompletedResult([
        { profileId: 'alpha', status: 'SUCCESS' }
      ]));
      await refreshPromise;

      expect(viewModel.current().refreshAllPending).assertFalse();
      expect(viewModel.current().completedRefreshCount).assertEqual(1);
      expect(viewModel.current().remainingRefreshCount).assertEqual(0);
      expect(viewModel.current().refreshAllSummary?.success).assertEqual(1);
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
      expect(viewModel.current().refreshAllPending).assertTrue();
      expect(viewModel.current().completedRefreshCount).assertEqual(0);
      expect(viewModel.current().remainingRefreshCount).assertEqual(1);
      expect(viewModel.current().refreshAllInterrupted).assertFalse();
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
