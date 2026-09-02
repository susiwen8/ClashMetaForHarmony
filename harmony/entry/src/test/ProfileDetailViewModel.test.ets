import { describe, expect, it } from '@ohos/hypium';
import type { ManageDeleteResult, ManageEnableResult, UpdateProfileResult } from '@cmfa/shared';
import {
  ProfileDetailViewModel,
  type ProfileDetailEffect,
  type ProfileDetailNavigationIntent
} from '../main/ets/presentation/ProfileDetailViewModel';
import {
  DeferredResult,
  PresentationTestApplication,
  createApplicationSnapshot,
  createDeletedResult,
  createFailedManageResult,
  createFailedUpdateResult,
  createProfileSnapshot,
  createSafeError,
  createUpdatedProfileRefreshFailedResult,
  createUpdatedProfileResult,
  createUpdatedRefreshResult
} from './fakes/PresentationFakes';

function serialize(value: Object): string {
  return JSON.stringify(value);
}

function assertNoUnsafeDetailLeak(serialized: string): void {
  expect(serialized.includes('token=secret')).assertFalse();
  expect(serialized.includes('fixtures/')).assertFalse();
  expect(serialized.includes('sourceSecretRef')).assertFalse();
  expect(serialized.includes('proxies:')).assertFalse();
  expect(serialized.includes('deep/path.yaml')).assertFalse();
}

export default function profileDetailViewModelTestsuite() {
  describe('ProfileDetailViewModelTest', () => {
    it('derivesActionAvailabilityFromProfileConditionsWithoutRuntimeLocks', 0, () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/subscription.yaml', 'INVALID', '2026-08-11T12:31:00.000Z', false, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      const viewModel = new ProfileDetailViewModel(application, 'alpha');

      expect(viewModel.current().canEnable).assertFalse();
      expect(viewModel.current().canRefresh).assertTrue();
      expect(viewModel.current().canDelete).assertTrue();
      expect(viewModel.current().canReplaceSubscriptionUrl).assertFalse();
      expect(viewModel.current().editing).assertFalse();

      application.emitSnapshot(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/subscription.yaml', 'VALID', '2026-08-11T12:32:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          'alpha',
          'RUNNING'
        )
      );

      expect(viewModel.current().canEnable).assertFalse();
      expect(viewModel.current().canRefresh).assertTrue();
      expect(viewModel.current().canDelete).assertTrue();
      expect(viewModel.current().canReplaceSubscriptionUrl).assertFalse();

      application.emitSnapshot(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/subscription.yaml', 'VALID', '2026-08-11T12:33:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );

      expect(viewModel.current().canEnable).assertTrue();
    });

    it('mapsIntervalMetadataForRemoteAndLocalProfilesWithoutLeakingAnythingElse', 0, () => {
      const remoteApplication = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('remote', 'Remote', 'https://remote.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL',
              autoUpdateIntervalMs: 2 * 60 * 60 * 1000,
              lastSuccessfulUpdateAt: '2026-08-11T13:45:00.000Z'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      const localApplication = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('local', 'Local', '/storage/local.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'LOCAL_FILE',
              autoUpdateIntervalMs: 0
            })
          ],
          undefined,
          'STOPPED'
        )
      );

      const remoteViewModel = new ProfileDetailViewModel(remoteApplication, 'remote');
      const localViewModel = new ProfileDetailViewModel(localApplication, 'local');

      expect(remoteViewModel.current().profile?.autoUpdateIntervalMs ?? -1).assertEqual(2 * 60 * 60 * 1000);
      expect(remoteViewModel.current().profile?.lastSuccessfulUpdateAt).assertEqual('2026-08-11T13:45:00.000Z');
      expect(localViewModel.current().profile?.autoUpdateIntervalMs ?? -1).assertEqual(0);
      expect(localViewModel.current().profile?.lastSuccessfulUpdateAt).assertUndefined();
      assertNoUnsafeDetailLeak(serialize(remoteViewModel.current()));
      assertNoUnsafeDetailLeak(serialize(localViewModel.current()));
    });

    it('submitsRemoteAutoUpdateIntervalAndCompletesFromLatestApplicationSnapshot', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('remote-interval', 'Remote Interval', 'https://remote.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL',
              autoUpdateIntervalMs: 0
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      const deferred = new DeferredResult<UpdateProfileResult>();
      application.queueUpdateAutoUpdateIntervalResult(deferred.promise);
      const viewModel = new ProfileDetailViewModel(application, 'remote-interval');

      const command = viewModel.requestAutoUpdateInterval(2 * 60 * 60 * 1000);

      expect(viewModel.current().status).assertEqual('SUBMITTING');
      expect(application.updateAutoUpdateIntervalCommands.length).assertEqual(1);
      expect(application.updateAutoUpdateIntervalCommands[0].profileId).assertEqual('remote-interval');
      expect(application.updateAutoUpdateIntervalCommands[0].intervalMs).assertEqual(2 * 60 * 60 * 1000);

      application.emitSnapshot(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('remote-interval', 'Remote Interval', 'https://remote.example.com/subscription.yaml', 'VALID', '2026-08-11T12:32:00.000Z', true, {
              sourceKind: 'REMOTE_URL',
              autoUpdateIntervalMs: 2 * 60 * 60 * 1000,
              lastSuccessfulUpdateAt: '2026-08-11T13:45:00.000Z'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      deferred.resolve(createUpdatedProfileResult('remote-interval'));
      await command;

      expect(viewModel.current().status).assertEqual('COMPLETED');
      expect(viewModel.current().error).assertUndefined();
      expect(viewModel.current().profile?.autoUpdateIntervalMs ?? -1).assertEqual(2 * 60 * 60 * 1000);
      expect(viewModel.current().profile?.lastSuccessfulUpdateAt).assertEqual('2026-08-11T13:45:00.000Z');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('showsSavedIntervalFromSnapshotWhenScheduleRefreshFailsAfterAutoUpdateSave', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('partial-interval', 'Partial Interval', 'https://partial.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL',
              autoUpdateIntervalMs: 0
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      const deferred = new DeferredResult<UpdateProfileResult>();
      application.queueUpdateAutoUpdateIntervalResult(deferred.promise);
      const viewModel = new ProfileDetailViewModel(application, 'partial-interval');

      const command = viewModel.requestAutoUpdateInterval(2 * 60 * 60 * 1000);
      application.emitSnapshot(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('partial-interval', 'Partial Interval', 'https://partial.example.com/subscription.yaml', 'VALID', '2026-08-11T12:32:00.000Z', true, {
              sourceKind: 'REMOTE_URL',
              autoUpdateIntervalMs: 2 * 60 * 60 * 1000
            })
          ],
          undefined,
          'STOPPED',
          {
            error: createSafeError('SUBSCRIPTION_SCHEDULE_FAILED', 'PERSISTENCE', 'schedule reconcile failed for partial.example.com')
          }
        )
      );
      deferred.resolve(
        createUpdatedProfileRefreshFailedResult(
          'partial-interval',
          'SUBSCRIPTION_SCHEDULE_FAILED',
          'PERSISTENCE',
          'schedule reconcile failed for partial.example.com'
        )
      );
      await command;

      expect(viewModel.current().status).assertEqual('ERROR');
      expect(viewModel.current().profile?.autoUpdateIntervalMs ?? -1).assertEqual(2 * 60 * 60 * 1000);
      expect(viewModel.current().error?.code).assertEqual('SUBSCRIPTION_SCHEDULE_FAILED');
      expect(viewModel.current().error?.technicalDetail).assertEqual('schedule reconcile failed for partial.example.com');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('keepsPreviousIntervalWhenAutoUpdateSaveFails', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('failed-interval', 'Failed Interval', 'https://failed.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL',
              autoUpdateIntervalMs: 30 * 60 * 1000
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      application.queueUpdateAutoUpdateIntervalResult(
        createFailedUpdateResult('SUBSCRIPTION_INTERVAL_SAVE_FAILED', 'PERSISTENCE', 'interval save failed for failed.example.com')
      );
      const viewModel = new ProfileDetailViewModel(application, 'failed-interval');

      await viewModel.requestAutoUpdateInterval(2 * 60 * 60 * 1000);

      expect(viewModel.current().status).assertEqual('ERROR');
      expect(viewModel.current().profile?.autoUpdateIntervalMs ?? -1).assertEqual(30 * 60 * 1000);
      expect(viewModel.current().error?.technicalDetail).assertEqual('interval save failed for failed.example.com');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('ignoresLocalOrConcurrentAutoUpdateIntervalRequests', 0, async () => {
      const localApplication = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('local-interval', 'Local Interval', '/storage/local.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'LOCAL_FILE'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      const localViewModel = new ProfileDetailViewModel(localApplication, 'local-interval');

      await localViewModel.requestAutoUpdateInterval(2 * 60 * 60 * 1000);
      expect(localApplication.updateAutoUpdateIntervalCommands.length).assertEqual(0);

      const remoteApplication = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('busy-interval', 'Busy Interval', 'https://busy.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      const deferred = new DeferredResult<UpdateProfileResult>();
      remoteApplication.queueUpdateAutoUpdateIntervalResult(deferred.promise);
      const remoteViewModel = new ProfileDetailViewModel(remoteApplication, 'busy-interval');

      const first = remoteViewModel.requestAutoUpdateInterval(2 * 60 * 60 * 1000);
      const second = remoteViewModel.requestAutoUpdateInterval(0);
      deferred.resolve(createUpdatedProfileResult('busy-interval'));
      await first;
      await second;

      expect(remoteApplication.updateAutoUpdateIntervalCommands.length).assertEqual(1);
      expect(remoteApplication.updateAutoUpdateIntervalCommands[0].intervalMs).assertEqual(2 * 60 * 60 * 1000);
      assertNoUnsafeDetailLeak(serialize(remoteViewModel.current()));
    });

    it('ignoresLateAutoUpdateIntervalCompletionAfterDispose', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('dispose-interval', 'Dispose Interval', 'https://dispose.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL',
              autoUpdateIntervalMs: 0
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      const deferred = new DeferredResult<UpdateProfileResult>();
      application.queueUpdateAutoUpdateIntervalResult(deferred.promise);
      const viewModel = new ProfileDetailViewModel(application, 'dispose-interval');

      const command = viewModel.requestAutoUpdateInterval(2 * 60 * 60 * 1000);
      viewModel.dispose();
      application.emitSnapshot(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('dispose-interval', 'Dispose Interval', 'https://dispose.example.com/subscription.yaml', 'VALID', '2026-08-11T12:32:00.000Z', true, {
              sourceKind: 'REMOTE_URL',
              autoUpdateIntervalMs: 2 * 60 * 60 * 1000
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      deferred.resolve(createUpdatedProfileResult('dispose-interval'));
      await command;

      expect(viewModel.current().status).assertEqual('SUBMITTING');
      expect(viewModel.current().profile?.autoUpdateIntervalMs ?? -1).assertEqual(0);
      expect(application.updateAutoUpdateIntervalCommands.length).assertEqual(1);
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('delegatesEnableToFacadeAndUsesApplicationErrorInsteadOfRepeatingDomainMutationRules', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('load-fail', 'Load Fail', 'https://load.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      const deferred = new DeferredResult<ManageEnableResult>();
      application.queueEnableResult(deferred.promise);
      const viewModel = new ProfileDetailViewModel(application, 'load-fail');

      const command = viewModel.requestEnable();
      expect(application.commandLog.length).assertEqual(1);
      expect(application.commandLog[0]).assertEqual('enable:load-fail');

      application.emitSnapshot(
        createApplicationSnapshot(
          'ERROR',
          [
            createProfileSnapshot('load-fail', 'Load Fail', 'https://load.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED',
          {
            error: createSafeError('CMFA_CORE_LOAD', 'CORE_LOAD', 'core load failed for load.example.com')
          }
        )
      );
      deferred.resolve(createFailedManageResult('CMFA_CORE_LOAD', 'CORE_LOAD', 'core load failed for opaque://load.example.com'));
      await command;

      expect(viewModel.current().error?.technicalDetail).assertEqual('core load failed for opaque://load.example.com');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('seedsEditDraftsAndCancelClearsEditingIssuesAndPrivateDrafts', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      const viewModel = new ProfileDetailViewModel(application, 'alpha');

      viewModel.requestEdit();
      expect(viewModel.current().editing).assertTrue();
      expect(viewModel.currentEditNameDraft()).assertEqual('Alpha');
      expect(viewModel.currentEditUrlDraft()).assertEqual('');

      viewModel.updateEditNameDraft('');
      viewModel.updateEditUrlDraft('ftp://alpha.example.com/subscription.yaml');
      await viewModel.requestSaveEdits();
      expect(viewModel.current().editNameIssue).assertEqual('REQUIRED');
      expect(viewModel.current().editUrlIssue).assertEqual('INVALID_SCHEME');

      viewModel.cancelEdit();
      expect(viewModel.current().editing).assertFalse();
      expect(viewModel.current().editNameIssue).assertUndefined();
      expect(viewModel.current().editUrlIssue).assertUndefined();
      expect(viewModel.currentEditNameDraft()).assertEqual('');
      expect(viewModel.currentEditUrlDraft()).assertEqual('');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('savesNameOnlyEditsWithoutSendingSourceUrl', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('alpha', 'Alpha', 'https://alpha.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      application.queueUpdateProfileResult(createUpdatedProfileResult('alpha'));
      const viewModel = new ProfileDetailViewModel(application, 'alpha');

      viewModel.requestEdit();
      viewModel.updateEditNameDraft('Renamed Alpha');
      await viewModel.requestSaveEdits();

      expect(application.updateProfileCommands.length).assertEqual(1);
      expect(application.updateProfileCommands[0].profileId).assertEqual('alpha');
      expect(application.updateProfileCommands[0].name).assertEqual('Renamed Alpha');
      expect(application.updateProfileCommands[0].sourceChanged).assertFalse();
      expect(application.updateProfileCommands[0].sourceDisplay).assertUndefined();
      expect(application.updateProfileCommands[0].allowPlainHttp).assertFalse();
      expect(viewModel.current().status).assertEqual('COMPLETED');
      expect(viewModel.current().editing).assertFalse();
      expect(viewModel.currentEditNameDraft()).assertEqual('');
      expect(viewModel.currentEditUrlDraft()).assertEqual('');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
      expect(application.commandLog.join('|').includes('token=secret')).assertFalse();
    });

    it('savesHttpsSourceEditsWithoutLeakingRawUrl', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('secure-edit', 'Secure Edit', 'https://secure.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      application.queueUpdateProfileResult(createUpdatedProfileResult('secure-edit'));
      const viewModel = new ProfileDetailViewModel(application, 'secure-edit');

      viewModel.requestEdit();
      viewModel.updateEditNameDraft('Secure Edit');
      viewModel.updateEditUrlDraft('https://user:pass@secure.example.com/deep/path.yaml?token=secret#fragment');
      await viewModel.requestSaveEdits();

      expect(application.updateProfileCommands.length).assertEqual(1);
      expect(application.updateProfileCommands[0].sourceChanged).assertTrue();
      expect(application.updateProfileCommands[0].sourceDisplay).assertEqual('https://secure.example.com');
      expect(application.updateProfileCommands[0].allowPlainHttp).assertFalse();
      expect(viewModel.current().status).assertEqual('COMPLETED');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
      expect(application.commandLog.join('|').includes('deep/path.yaml')).assertFalse();
      expect(application.commandLog.join('|').includes('token=secret')).assertFalse();
    });

    it('validatesEditInputsAndClearsStaleCommandErrorOnDraftChange', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('validate', 'Validate', 'https://validate.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      application.queueUpdateProfileResult(createFailedUpdateResult('CMFA_IMPORT', 'IMPORT', 'stale save error for validate.example.com'));
      const viewModel = new ProfileDetailViewModel(application, 'validate');

      viewModel.requestEdit();
      viewModel.updateEditNameDraft('');
      viewModel.updateEditUrlDraft('ftp://validate.example.com/subscription.yaml');
      await viewModel.requestSaveEdits();

      expect(viewModel.current().editNameIssue).assertEqual('REQUIRED');
      expect(viewModel.current().editUrlIssue).assertEqual('INVALID_SCHEME');
      expect(application.updateProfileCommands.length).assertEqual(0);

      viewModel.updateEditNameDraft('Validate Again');
      viewModel.updateEditUrlDraft('');
      await viewModel.requestSaveEdits();
      expect(viewModel.current().status).assertEqual('ERROR');
      expect(viewModel.current().error?.technicalDetail).assertEqual('stale save error for validate.example.com');

      viewModel.updateEditUrlDraft('https://validate.example.com/next.yaml');
      expect(viewModel.current().editUrlIssue).assertUndefined();
      expect(viewModel.current().status).assertEqual('IDLE');
      expect(viewModel.current().error).assertUndefined();
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('requiresSourceUrlWhenRepairIsRequired', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('repair', 'Repair', 'https://repair.example.com', 'INVALID', '2026-08-11T12:31:00.000Z', false, {
              sourceKind: 'REMOTE_URL',
              lastError: createSafeError('SOURCE_SECRET_MISSING', 'PERSISTENCE', 'encrypted source is unavailable')
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      const viewModel = new ProfileDetailViewModel(application, 'repair');

      expect(viewModel.current().sourceRepairRequired).assertTrue();
      expect(viewModel.current().canReplaceSubscriptionUrl).assertTrue();

      viewModel.requestEdit();
      expect(viewModel.currentEditNameDraft()).assertEqual('Repair');
      expect(viewModel.currentEditUrlDraft()).assertEqual('');
      await viewModel.requestSaveEdits();

      expect(viewModel.current().editing).assertTrue();
      expect(viewModel.current().editUrlIssue).assertEqual('REQUIRED');
      expect(application.updateProfileCommands.length).assertEqual(0);
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('routesPlainHttpRefreshThroughGenericConfirmationAction', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('plain-remote', 'Plain Remote', 'http://user:pass@legacy.example.com:8080/deep/path.yaml?token=secret#fragment', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      application.queueRefreshResult(createUpdatedRefreshResult('plain-remote'));
      const viewModel = new ProfileDetailViewModel(application, 'plain-remote');

      await viewModel.requestRefresh();
      expect(viewModel.current().status).assertEqual('CONFIRMING_HTTP');
      expect(viewModel.current().httpConfirmationHost).assertEqual('legacy.example.com:8080');
      expect(application.refreshCommands.length).assertEqual(0);

      await viewModel.confirmPlainHttpAction();
      expect(application.refreshCommands.length).assertEqual(1);
      expect(application.refreshCommands[0].allowPlainHttp).assertTrue();

      await viewModel.requestRefresh();
      viewModel.cancelPlainHttpConfirmation();
      expect(viewModel.current().status).assertEqual('IDLE');
      expect(application.refreshCommands.length).assertEqual(1);
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('preservesEditDraftsWhenCancellingAndConfirmingPlainHttpSourceChanges', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('plain-edit', 'Plain Edit', 'https://plain-edit.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      application.queueUpdateProfileResult(createUpdatedProfileResult('plain-edit'));
      const viewModel = new ProfileDetailViewModel(application, 'plain-edit');

      viewModel.requestEdit();
      viewModel.updateEditNameDraft('Plain Edit');
      viewModel.updateEditUrlDraft('http://user:pass@legacy.example.com:8080/deep/path.yaml?token=secret#fragment');
      await viewModel.requestSaveEdits();

      expect(viewModel.current().status).assertEqual('CONFIRMING_HTTP');
      expect(viewModel.current().editing).assertTrue();
      expect(viewModel.current().httpConfirmationHost).assertEqual('legacy.example.com:8080');
      expect(application.updateProfileCommands.length).assertEqual(0);

      viewModel.cancelPlainHttpConfirmation();
      expect(viewModel.current().status).assertEqual('IDLE');
      expect(viewModel.current().editing).assertTrue();
      expect(viewModel.currentEditUrlDraft()).assertEqual('http://user:pass@legacy.example.com:8080/deep/path.yaml?token=secret#fragment');

      await viewModel.requestSaveEdits();
      await viewModel.confirmPlainHttpAction();
      expect(application.updateProfileCommands.length).assertEqual(1);
      expect(application.updateProfileCommands[0].allowPlainHttp).assertTrue();
      expect(application.updateProfileCommands[0].sourceDisplay).assertEqual('http://legacy.example.com:8080');
      expect(viewModel.current().status).assertEqual('COMPLETED');
      expect(viewModel.current().editing).assertFalse();
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('clearsEditingDraftsButKeepsErrorWhenUpdateRefreshFails', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('partial', 'Partial', 'https://partial.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      application.queueUpdateProfileResult(
        createUpdatedProfileRefreshFailedResult('partial', 'CMFA_IMPORT', 'IMPORT', 'refresh retry failed for partial.example.com')
      );
      const viewModel = new ProfileDetailViewModel(application, 'partial');

      viewModel.requestEdit();
      viewModel.updateEditNameDraft('Partial Rename');
      viewModel.updateEditUrlDraft('https://partial.example.com/next.yaml');
      await viewModel.requestSaveEdits();

      expect(viewModel.current().status).assertEqual('ERROR');
      expect(viewModel.current().editing).assertFalse();
      expect(viewModel.current().error?.technicalDetail).assertEqual('refresh retry failed for partial.example.com');
      expect(viewModel.currentEditNameDraft()).assertEqual('');
      expect(viewModel.currentEditUrlDraft()).assertEqual('');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('keepsEditingAndDraftsWhenUpdateFails', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('failed-save', 'Failed Save', 'https://failed.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      application.queueUpdateProfileResult(createFailedUpdateResult('CMFA_IMPORT', 'IMPORT', 'update failed for failed.example.com'));
      const viewModel = new ProfileDetailViewModel(application, 'failed-save');

      viewModel.requestEdit();
      viewModel.updateEditNameDraft('Failed Save 2');
      await viewModel.requestSaveEdits();

      expect(viewModel.current().status).assertEqual('ERROR');
      expect(viewModel.current().editing).assertTrue();
      expect(viewModel.current().error?.technicalDetail).assertEqual('update failed for failed.example.com');
      expect(viewModel.currentEditNameDraft()).assertEqual('Failed Save 2');
      expect(viewModel.currentEditUrlDraft()).assertEqual('');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('ignoresLateUpdateCompletionAfterDispose', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('dispose', 'Dispose', 'https://dispose.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      const deferred = new DeferredResult<UpdateProfileResult>();
      application.queueUpdateProfileResult(deferred.promise);
      const viewModel = new ProfileDetailViewModel(application, 'dispose');

      viewModel.requestEdit();
      viewModel.updateEditNameDraft('Dispose Later');
      const command: Promise<void> = viewModel.requestSaveEdits();
      viewModel.dispose();
      deferred.resolve(createUpdatedProfileResult('dispose'));
      await command;

      expect(viewModel.current().status).assertEqual('SUBMITTING');
      expect(viewModel.current().editing).assertTrue();
      expect(viewModel.currentEditNameDraft()).assertEqual('Dispose Later');
      expect(application.updateProfileCommands.length).assertEqual(1);
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('routesCompatibilityReplacementWrappersThroughPlainHttpConfirmation', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('wrapper', 'Wrapper', 'https://wrapper.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      application.queueUpdateProfileResult(createUpdatedProfileResult('wrapper'));
      const viewModel = new ProfileDetailViewModel(application, 'wrapper');

      expect(viewModel.currentReplacementUrlDraft()).assertEqual('');

      viewModel.updateReplacementUrlDraft('http://user:pass@legacy.example.com:8080/deep/path.yaml?token=secret#fragment');
      expect(viewModel.current().editing).assertTrue();
      expect(viewModel.currentReplacementUrlDraft()).assertEqual('http://user:pass@legacy.example.com:8080/deep/path.yaml?token=secret#fragment');

      await viewModel.requestReplaceSubscriptionUrl();
      expect(viewModel.current().status).assertEqual('CONFIRMING_HTTP');
      expect(viewModel.current().httpConfirmationHost).assertEqual('legacy.example.com:8080');
      expect(application.updateProfileCommands.length).assertEqual(0);

      await viewModel.confirmPlainHttpRefresh();
      expect(application.updateProfileCommands.length).assertEqual(1);
      expect(application.updateProfileCommands[0].allowPlainHttp).assertTrue();
      expect(application.updateProfileCommands[0].sourceDisplay).assertEqual('http://legacy.example.com:8080');
      expect(viewModel.current().editing).assertFalse();
      expect(viewModel.currentReplacementUrlDraft()).assertEqual('');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
      expect(application.commandLog.join('|').includes('deep/path.yaml')).assertFalse();
      expect(application.commandLog.join('|').includes('token=secret')).assertFalse();
    });

    it('copiesOnlyRedactedTechnicalDetailAndNavigatesBackOnceAfterConfirmedDelete', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('delete-me', 'Delete Me', 'https://delete.example.com', 'INVALID', '2026-08-11T12:31:00.000Z', false, {
              sourceKind: 'REMOTE_URL',
              lastError: createSafeError('CMFA_IMPORT', 'IMPORT', 'validation failed for delete.example.com')
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      application.queueDeleteResult(createDeletedResult('delete-me'));
      const viewModel = new ProfileDetailViewModel(application, 'delete-me');
      const effects: ProfileDetailEffect[] = [];
      const intents: ProfileDetailNavigationIntent[] = [];
      viewModel.subscribeEffect((effect: ProfileDetailEffect): void => {
        effects.push(effect);
      });
      viewModel.subscribeNavigation((intent: ProfileDetailNavigationIntent): void => {
        intents.push(intent);
      });

      viewModel.requestCopyTechnicalDetail();
      expect(effects.length).assertEqual(1);
      expect(effects[0].kind).assertEqual('COPY_TECHNICAL_DETAIL');
      expect(effects[0].value).assertEqual('validation failed for delete.example.com');

      viewModel.requestDelete();
      expect(viewModel.current().confirmingDelete).assertTrue();
      expect(application.commandLog.length).assertEqual(0);

      await viewModel.confirmDelete();
      expect(application.commandLog[0]).assertEqual('delete:delete-me');
      expect(intents.length).assertEqual(1);
      expect(intents[0].destination).assertEqual('BACK');

      application.emitSnapshot(createApplicationSnapshot('READY', [], undefined, 'STOPPED'));
      expect(intents.length).assertEqual(1);
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('keepsFacadeFailureErrorAndIgnoresDisposeCompletionForDelete', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('load-fail', 'Load Fail', 'https://load.example.com/subscription.yaml', 'VALID', '2026-08-11T12:31:00.000Z', true, {
              sourceKind: 'REMOTE_URL'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      const failedDeferred = new DeferredResult<ManageEnableResult>();
      application.queueEnableResult(failedDeferred.promise);
      const viewModel = new ProfileDetailViewModel(application, 'load-fail');
      const effects: ProfileDetailEffect[] = [];
      viewModel.subscribeEffect((effect: ProfileDetailEffect): void => {
        effects.push(effect);
      });

      const failedCommand = viewModel.requestEnable();
      failedDeferred.resolve(createFailedManageResult('CMFA_CORE_LOAD', 'CORE_LOAD', 'core load failed for opaque://load.example.com'));
      await failedCommand;

      expect(viewModel.current().status).assertEqual('ERROR');
      expect(viewModel.current().error?.technicalDetail).assertEqual('core load failed for opaque://load.example.com');

      const deleteDeferred = new DeferredResult<ManageDeleteResult>();
      application.queueDeleteResult(deleteDeferred.promise);
      const intents: ProfileDetailNavigationIntent[] = [];
      viewModel.subscribeNavigation((intent: ProfileDetailNavigationIntent): void => {
        intents.push(intent);
      });
      viewModel.requestDelete();
      const deleteCommand = viewModel.confirmDelete();
      viewModel.dispose();
      deleteDeferred.resolve(createDeletedResult('load-fail'));
      await deleteCommand;

      expect(viewModel.current().status).assertEqual('SUBMITTING');
      expect(intents.length).assertEqual(0);
      expect(effects.length).assertEqual(0);
      expect(application.commandLog.filter((entry: string): boolean => entry.startsWith('delete:')).length).assertEqual(1);
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });
  });
}
