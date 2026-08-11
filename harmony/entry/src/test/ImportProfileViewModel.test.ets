import { describe, expect, it } from '@ohos/hypium';
import type { ImportProfileResult } from '@cmfa/shared';
import {
  ImportProfileViewModel,
  type ImportNavigationIntent
} from '../main/ets/presentation/ImportProfileViewModel';
import {
  DeferredResult,
  PresentationTestApplication,
  createApplicationSnapshot,
  createCancelledImportResult,
  createCreatedImportResult,
  createFailedImportResult,
  createProfileSnapshot,
  createSafeError
} from './fakes/PresentationFakes';

function serialize(value: Object): string {
  return JSON.stringify(value);
}

function assertNoPlaintextLeak(serialized: string): void {
  expect(serialized.includes('token=secret')).assertFalse();
  expect(serialized.includes('/deep/path.yaml')).assertFalse();
  expect(serialized.includes('fixtures/')).assertFalse();
  expect(serialized.includes('opaque://')).assertFalse();
  expect(serialized.includes('proxies:')).assertFalse();
}

export default function importProfileViewModelTestsuite() {
  describe('ImportProfileViewModelTest', () => {
    it('validatesTrimmedNameLengthAndRemoteUrlSchemeBeforeSubmitting', 0, async () => {
      const application = new PresentationTestApplication(createApplicationSnapshot('READY', [], undefined, 'STOPPED'));
      const viewModel = new ImportProfileViewModel(application);

      viewModel.updateNameDraft('   ');
      viewModel.updateUrlDraft('ftp://legacy.example.com/config.yaml');
      await viewModel.requestImportUrl();

      expect(viewModel.current().status).assertEqual('IDLE');
      expect(viewModel.current().nameIssue).assertEqual('REQUIRED');
      expect(viewModel.current().urlIssue).assertEqual('INVALID_SCHEME');
      expect(application.commandLog.length).assertEqual(0);

      viewModel.updateNameDraft(' 12345678901234567890123456789012345678901234567890123456789012345678901234567890x ');
      viewModel.updateUrlDraft('not-a-url');
      await viewModel.requestImportUrl();

      expect(viewModel.current().nameIssue).assertEqual('TOO_LONG');
      expect(viewModel.current().urlIssue).assertEqual('INVALID_URL');
      assertNoPlaintextLeak(serialize(viewModel.current()));
    });

    it('submitsHttpsImportsAndClearsTransientDraftAfterCompletion', 0, async () => {
      const application = new PresentationTestApplication(createApplicationSnapshot('READY', [], undefined, 'STOPPED'));
      application.queueImportUrlResult(createCreatedImportResult('created-https'));
      const viewModel = new ImportProfileViewModel(application);
      const intents: ImportNavigationIntent[] = [];
      viewModel.subscribeNavigation((intent: ImportNavigationIntent): void => {
        intents.push(intent);
      });

      viewModel.updateNameDraft('  Example HTTPS  ');
      viewModel.updateUrlDraft('https://profiles.example.com/deep/path.yaml?token=secret');
      await viewModel.requestImportUrl();

      expect(application.importUrlCommands.length).assertEqual(1);
      expect(application.importUrlCommands[0].sourceDisplay).assertEqual('https://profiles.example.com');
      expect(application.importUrlCommands[0].allowPlainHttp).assertFalse();
      expect(application.importUrlCommands[0].profileName).assertEqual('Example HTTPS');
      expect(intents.length).assertEqual(1);
      expect(intents[0].destination).assertEqual('PROFILE_DETAIL');
      expect(intents[0].profileId).assertEqual('created-https');
      expect(viewModel.current().status).assertEqual('COMPLETED');

      await viewModel.requestImportUrl();
      expect(application.importUrlCommands.length).assertEqual(1);
      expect(viewModel.current().urlIssue).assertEqual('REQUIRED');
      assertNoPlaintextLeak(serialize(viewModel.current()));
      assertNoPlaintextLeak(serialize(intents[0]));
    });

    it('requiresFreshPlainHttpConsentForEveryUrlImportAttempt', 0, async () => {
      const application = new PresentationTestApplication(createApplicationSnapshot('READY', [], undefined, 'STOPPED'));
      application.queueImportUrlResult(createCreatedImportResult('plain-created'));
      const viewModel = new ImportProfileViewModel(application);

      viewModel.updateNameDraft('Plain HTTP');
      viewModel.updateUrlDraft('http://user:pass@legacy.example.com:8080/deep/path.yaml?token=secret#fragment');
      await viewModel.requestImportUrl();

      expect(viewModel.current().status).assertEqual('CONFIRMING_HTTP');
      expect(viewModel.current().httpConfirmationHost).assertEqual('legacy.example.com:8080');
      expect(application.importUrlCommands.length).assertEqual(0);

      viewModel.cancelPlainHttpConfirmation();
      expect(viewModel.current().status).assertEqual('IDLE');
      expect(viewModel.current().httpConfirmationHost).assertEqual(undefined);
      expect(viewModel.current().error).assertEqual(undefined);
      expect(application.importUrlCommands.length).assertEqual(0);

      await viewModel.confirmPlainHttpImport();
      expect(application.importUrlCommands.length).assertEqual(0);
      expect(viewModel.current().urlIssue).assertEqual('REQUIRED');

      viewModel.updateUrlDraft('http://user:pass@legacy.example.com:8080/deep/path.yaml?token=secret#fragment');
      await viewModel.requestImportUrl();
      expect(viewModel.current().httpConfirmationHost).assertEqual('legacy.example.com:8080');
      expect(application.importUrlCommands.length).assertEqual(0);

      await viewModel.confirmPlainHttpImport();
      expect(application.importUrlCommands.length).assertEqual(1);
      expect(application.importUrlCommands[0].allowPlainHttp).assertTrue();
      expect(application.importUrlCommands[0].sourceDisplay).assertEqual('http://legacy.example.com:8080');
      expect(viewModel.current().httpConfirmationHost).assertEqual(undefined);

      viewModel.updateUrlDraft('http://user:pass@legacy.example.com:8080/deep/path.yaml?token=secret#fragment');
      await viewModel.requestImportUrl();
      expect(viewModel.current().status).assertEqual('CONFIRMING_HTTP');
      expect(application.importUrlCommands.length).assertEqual(1);
      assertNoPlaintextLeak(serialize(viewModel.current()));
    });

    it('ignoresRepeatedConfirmWhilePlainHttpImportIsInFlight', 0, async () => {
      const application = new PresentationTestApplication(createApplicationSnapshot('READY', [], undefined, 'STOPPED'));
      const deferred = new DeferredResult<ImportProfileResult>();
      application.queueImportUrlResult(deferred.promise);
      const viewModel = new ImportProfileViewModel(application);

      viewModel.updateNameDraft('Plain HTTP');
      viewModel.updateUrlDraft('http://user:pass@legacy.example.com:8080/deep/path.yaml?token=secret#fragment');
      await viewModel.requestImportUrl();
      const firstConfirm = viewModel.confirmPlainHttpImport();
      await viewModel.confirmPlainHttpImport();

      expect(application.importUrlCommands.length).assertEqual(1);
      expect(viewModel.current().status).assertEqual('SUBMITTING');
      expect(viewModel.current().urlIssue).assertEqual(undefined);

      deferred.resolve(createCreatedImportResult('plain-created'));
      await firstConfirm;
      expect(viewModel.current().status).assertEqual('COMPLETED');
    });

    it('reopensLocalPickerAfterCancellationAndNavigatesToRetainedInvalidLocalProfile', 0, async () => {
      const application = new PresentationTestApplication(createApplicationSnapshot('READY', [], undefined, 'STOPPED'));
      application.queueImportLocalResult(createCancelledImportResult());
      application.queueImportLocalResult(createCreatedImportResult('invalid-local', 'LOCAL_FILE'));
      const viewModel = new ImportProfileViewModel(application);
      const intents: ImportNavigationIntent[] = [];
      viewModel.subscribeNavigation((intent: ImportNavigationIntent): void => {
        intents.push(intent);
      });

      await viewModel.requestImportLocal();
      expect(viewModel.current().status).assertEqual('IDLE');
      expect(intents.length).assertEqual(0);
      expect(application.commandLog[0]).assertEqual('importLocal:');

      application.emitSnapshot(
        createApplicationSnapshot(
          'READY',
          [
            createProfileSnapshot(
              'invalid-local',
              'Broken Local',
              'fixtures/broken-local.yaml',
              'INVALID',
              '2026-08-11T12:31:00.000Z',
              false,
              {
                sourceKind: 'LOCAL_FILE',
                lastError: createSafeError('CMFA_IMPORT', 'IMPORT', 'broken-local.yaml is invalid')
              }
            )
          ],
          undefined,
          'STOPPED'
        )
      );
      await viewModel.requestImportLocal();

      expect(application.commandLog[1]).assertEqual('importLocal:');
      expect(intents.length).assertEqual(1);
      expect(intents[0].profileId).assertEqual('invalid-local');
      assertNoPlaintextLeak(serialize(viewModel.current()));
      assertNoPlaintextLeak(serialize(intents[0]));
    });

    it('blocksDuplicateSubmissionsAndNavigatesUsingRetainedProfileFromApplicationFailureState', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot(
          'READY',
          [createProfileSnapshot('existing', 'Existing', 'https://existing.example.com/root.yaml', 'VALID', '2026-08-11T12:30:00.000Z', true)],
          undefined,
          'STOPPED'
        )
      );
      const deferred = new DeferredResult<ImportProfileResult>();
      application.queueImportUrlResult(deferred.promise);
      const viewModel = new ImportProfileViewModel(application);
      const intents: ImportNavigationIntent[] = [];
      viewModel.subscribeNavigation((intent: ImportNavigationIntent): void => {
        intents.push(intent);
      });

      viewModel.updateNameDraft('Broken Remote');
      viewModel.updateUrlDraft('https://broken.example.com/deep/path.yaml?token=secret');
      const first = viewModel.requestImportUrl();
      const second = viewModel.requestImportUrl();

      expect(viewModel.current().status).assertEqual('SUBMITTING');
      expect(application.importUrlCommands.length).assertEqual(1);

      application.emitSnapshot(
        createApplicationSnapshot(
          'ERROR',
          [
            createProfileSnapshot('existing', 'Existing', 'https://existing.example.com/root.yaml', 'VALID', '2026-08-11T12:30:00.000Z', true),
            createProfileSnapshot(
              'retained-invalid',
              'Broken Remote',
              'https://broken.example.com',
              'INVALID',
              '2026-08-11T12:32:00.000Z',
              false,
              {
                sourceKind: 'REMOTE_URL',
                lastError: createSafeError('CMFA_IMPORT', 'IMPORT', 'download failed for broken.example.com')
              }
            )
          ],
          undefined,
          'STOPPED',
          {
            error: createSafeError('CMFA_IMPORT', 'IMPORT', 'download failed for broken.example.com')
          }
        )
      );
      deferred.resolve(createFailedImportResult('CMFA_IMPORT', 'IMPORT', 'download failed for https://broken.example.com/deep/path.yaml?token=secret'));
      await first;
      await second;

      expect(intents.length).assertEqual(1);
      expect(intents[0].profileId).assertEqual('retained-invalid');
      expect(viewModel.current().status).assertEqual('COMPLETED');
      assertNoPlaintextLeak(serialize(viewModel.current()));
    });

    it('preservesFailedImportErrorWithoutSnapshotErrorAndIgnoresDisposeCompletion', 0, async () => {
      const application = new PresentationTestApplication(createApplicationSnapshot('READY', [], undefined, 'STOPPED'));
      const deferred = new DeferredResult<ImportProfileResult>();
      application.queueImportUrlResult(deferred.promise);
      const viewModel = new ImportProfileViewModel(application);
      const intents: ImportNavigationIntent[] = [];
      viewModel.subscribeNavigation((intent: ImportNavigationIntent): void => {
        intents.push(intent);
      });

      viewModel.updateNameDraft('Broken Remote');
      viewModel.updateUrlDraft('https://broken.example.com/deep/path.yaml?token=secret');
      const command = viewModel.requestImportUrl();

      expect(viewModel.current().status).assertEqual('SUBMITTING');
      deferred.resolve(createFailedImportResult('CMFA_IMPORT', 'IMPORT', 'download failed for https://broken.example.com/deep/path.yaml?token=secret'));
      await command;

      expect(viewModel.current().status).assertEqual('ERROR');
      expect(viewModel.current().error?.technicalDetail).assertEqual('download failed for https://broken.example.com');
      expect(intents.length).assertEqual(0);

      const disposedDeferred = new DeferredResult<ImportProfileResult>();
      application.queueImportUrlResult(disposedDeferred.promise);
      viewModel.updateUrlDraft('https://created.example.com/deep/path.yaml?token=secret');
      const disposedCommand = viewModel.requestImportUrl();
      viewModel.dispose();
      disposedDeferred.resolve(createCreatedImportResult('disposed-created'));
      await disposedCommand;

      expect(viewModel.current().status).assertEqual('SUBMITTING');
      expect(intents.length).assertEqual(0);
      expect(application.importUrlCommands.length).assertEqual(2);
      expect(application.commandLog.filter((entry: string): boolean => entry.startsWith('importUrl:')).length).assertEqual(2);
      assertNoPlaintextLeak(serialize(viewModel.current()));
    });
  });
}
