import { describe, expect, it } from '@ohos/hypium';
import type { ProfileApplicationProfileSnapshot } from '@cmfa/shared';
import type { HomeViewState } from '../main/ets/presentation/PresentationModels';
import { HomeViewModel } from '../main/ets/presentation/HomeViewModel';
import {
  createApplicationSnapshot,
  createProfileSnapshot,
  createSafeError,
  PresentationTestApplication
} from './fakes/PresentationFakes';

function createActiveProfile(
  availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID',
  hasCurrentRevision: boolean,
  sourceDisplay?: string
): ProfileApplicationProfileSnapshot {
  return createProfileSnapshot(
    'active',
    'Primary',
    sourceDisplay ?? 'https://mirror.example.com/subscriptions/primary.yaml?token=secret',
    availability,
    '2026-08-11T12:31:00.000Z',
    hasCurrentRevision
  );
}

function assertForbiddenPresentationData(serialized: string): void {
  expect(serialized.includes('repository')).assertFalse();
  expect(serialized.includes('contentStore')).assertFalse();
  expect(serialized.includes('sourceSecretRef')).assertFalse();
  expect(serialized.includes('CoreEvent')).assertFalse();
  expect(serialized.includes('file://')).assertFalse();
  expect(serialized.includes('/subscriptions/primary.yaml')).assertFalse();
  expect(serialized.includes('token=secret')).assertFalse();
  expect(serialized.includes('proxies:')).assertFalse();
}

export default function homeViewModelTestsuite() {
  describe('HomeViewModelTest', () => {
    it('mapsInitializationRuntimeAndPrimaryActionAcrossActiveProfileStates', 0, () => {
      const application = new PresentationTestApplication(createApplicationSnapshot('LOADING', [], undefined, 'STOPPED'));
      const viewModel = new HomeViewModel(application);

      expect(viewModel.current().initialization).assertEqual('LOADING');
      expect(viewModel.current().primaryAction).assertEqual('DISABLED');

      application.emitSnapshot(createApplicationSnapshot('READY', [], undefined, 'STOPPED'));
      expect(viewModel.current().initialization).assertEqual('READY');
      expect(viewModel.current().primaryAction).assertEqual('DISABLED');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED'));
      expect(viewModel.current().primaryAction).assertEqual('START');
      expect(viewModel.current().activeProfile?.sourceDisplay).assertEqual('mirror.example.com');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('INVALID', false)], 'active', 'STOPPED'));
      expect(viewModel.current().activeProfile?.availability).assertEqual('INVALID');
      expect(viewModel.current().primaryAction).assertEqual('DISABLED');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('UPDATE_FAILED_USING_VALID', true)], 'active', 'STOPPED'));
      expect(viewModel.current().primaryAction).assertEqual('START');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STARTING'));
      expect(viewModel.current().runtime).assertEqual('STARTING');
      expect(viewModel.current().primaryAction).assertEqual('BUSY');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'RUNNING', {
        httpAddress: '127.0.0.1:7890',
        socksAddress: '127.0.0.1:7891'
      }));
      expect(viewModel.current().runtime).assertEqual('RUNNING');
      expect(viewModel.current().primaryAction).assertEqual('STOP');
      expect(viewModel.current().httpAddress).assertEqual('127.0.0.1:7890');
      expect(viewModel.current().socksAddress).assertEqual('127.0.0.1:7891');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPING'));
      expect(viewModel.current().runtime).assertEqual('STOPPING');
      expect(viewModel.current().primaryAction).assertEqual('BUSY');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'ERROR', {
        runtimeError: createSafeError('CMFA_RUNTIME', 'RUNTIME_START', 'core error at /Users/demo/secrets'),
        latestRuntimeError: 'fatal at /Users/demo/secrets'
      }));
      expect(viewModel.current().runtime).assertEqual('ERROR');
      expect(viewModel.current().primaryAction).assertEqual('START');
      expect(viewModel.current().error?.technicalDetail.includes('/Users/demo')).assertFalse();
    });

    it('primaryActionUsesRuntimeAddressesAndCoalescesRepeatedClicks', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true, 'https://profile.example.com/config.yaml')], 'active', 'STOPPED', {
          httpAddress: '',
          socksAddress: '',
          latestRuntimeError: 'https://ignored.example.com/full/path.yaml'
        })
      );
      const deferred = application.deferStart();
      const viewModel = new HomeViewModel(application);

      const first = viewModel.requestPrimaryAction();
      const second = viewModel.requestPrimaryAction();

      expect(viewModel.current().primaryAction).assertEqual('BUSY');
      expect(application.commandLog.join('>')).assertEqual('startLocal');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'RUNNING', {
        httpAddress: '127.0.0.1:7890',
        socksAddress: '127.0.0.1:7891'
      }));
      deferred.resolve();
      await first;
      await second;

      const state: HomeViewState = viewModel.current();
      expect(state.httpAddress).assertEqual('127.0.0.1:7890');
      expect(state.socksAddress).assertEqual('127.0.0.1:7891');
      expect(state.activeProfile?.sourceDisplay).assertEqual('mirror.example.com');
      assertForbiddenPresentationData(JSON.stringify(state));
    });

    it('disposeUnsubscribesFromApplication', 0, () => {
      const application = new PresentationTestApplication(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED'));
      const viewModel = new HomeViewModel(application);

      expect(application.listenerCount()).assertEqual(1);
      viewModel.dispose();
      expect(application.listenerCount()).assertEqual(0);
    });
  });
}
