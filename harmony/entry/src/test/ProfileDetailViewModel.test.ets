import { describe, expect, it } from '@ohos/hypium';
import type { ManageDeleteResult, ManageEnableResult } from '@cmfa/shared';
import {
  ProfileDetailViewModel,
  type ProfileDetailEffect,
  type ProfileDetailNavigationIntent
} from '../main/ets/presentation/ProfileDetailViewModel';
import {
  DeferredResult,
  PresentationTestApplication,
  createApplicationSnapshot,
  createCancelledRefreshResult,
  createDeletedResult,
  createFailedManageResult,
  createProfileSnapshot,
  createReplacedResult,
  createSafeError,
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
}

export default function profileDetailViewModelTestsuite() {
  describe('ProfileDetailViewModelTest', () => {
    it('derivesActionAvailabilityFromProfileValidityAndCanonicalRuntimeState', 0, () => {
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
      expect(viewModel.current().canRefresh).assertFalse();
      expect(viewModel.current().canDelete).assertFalse();
      expect(viewModel.current().canReplaceSubscriptionUrl).assertFalse();
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

      expect(viewModel.current().error?.technicalDetail).assertEqual('core load failed for load.example.com');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('reopensLocalPickerWhenRefreshingLocalProfilesAndHandlesCancellation', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot('local', 'Local', 'fixtures/local.yaml', 'INVALID', '2026-08-11T12:31:00.000Z', false, {
              sourceKind: 'LOCAL_FILE'
            })
          ],
          undefined,
          'STOPPED'
        )
      );
      application.queueRefreshResult(createCancelledRefreshResult());
      const viewModel = new ProfileDetailViewModel(application, 'local');

      await viewModel.requestRefresh();

      expect(application.refreshCommands.length).assertEqual(1);
      expect(application.refreshCommands[0].profileId).assertEqual('local');
      expect(application.refreshCommands[0].allowPlainHttp).assertFalse();
      expect(viewModel.current().status).assertEqual('IDLE');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
    });

    it('requiresFreshPlainHttpConsentForRemoteRefreshAttempts', 0, async () => {
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

      viewModel.cancelPlainHttpConfirmation();
      expect(viewModel.current().status).assertEqual('IDLE');
      expect(application.refreshCommands.length).assertEqual(0);

      await viewModel.confirmPlainHttpRefresh();
      expect(application.refreshCommands.length).assertEqual(0);

      await viewModel.requestRefresh();
      expect(viewModel.current().httpConfirmationHost).assertEqual('legacy.example.com:8080');
      await viewModel.confirmPlainHttpRefresh();
      expect(application.refreshCommands.length).assertEqual(1);
      expect(application.refreshCommands[0].allowPlainHttp).assertTrue();

      await viewModel.requestRefresh();
      expect(viewModel.current().status).assertEqual('CONFIRMING_HTTP');
      expect(application.refreshCommands.length).assertEqual(1);
    });

    it('keepsFacadeFailureErrorAndIgnoresDisposeCompletion', 0, async () => {
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

    it('allowsRepairingCorruptRemoteSecretsThroughReplacementUrl', 0, async () => {
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
      application.queueReplaceResult(createReplacedResult('repair'));
      const viewModel = new ProfileDetailViewModel(application, 'repair');

      expect(viewModel.current().sourceRepairRequired).assertTrue();
      expect(viewModel.current().canReplaceSubscriptionUrl).assertTrue();

      viewModel.updateReplacementUrlDraft('https://repair.example.com/deep/path.yaml?token=secret');
      await viewModel.requestReplaceSubscriptionUrl();

      expect(application.replaceCommands.length).assertEqual(1);
      expect(application.replaceCommands[0].profileId).assertEqual('repair');
      expect(application.replaceCommands[0].sourceDisplay.includes('token=secret')).assertFalse();
      expect(viewModel.current().status).assertEqual('COMPLETED');
      assertNoUnsafeDetailLeak(serialize(viewModel.current()));
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
  });
}
