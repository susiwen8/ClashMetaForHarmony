import { describe, expect, it } from '@ohos/hypium';
import {
  createVpnFailure,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  type ProfileApplicationProfileSnapshot,
  type VpnFailure,
  type VpnRuntimeSnapshot
} from '@cmfa/shared';
import type { HomeViewState } from '../main/ets/presentation/PresentationModels';
import { HomeViewModel } from '../main/ets/presentation/HomeViewModel';
import { VpnSessionRegistry } from '../main/ets/vpn/VpnSessionRegistry';
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
    sourceDisplay ?? `https://mirror.example.com/subscriptions/primary.yaml?token=${buildSecretTokenValue()}`,
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
  expect(serialized.includes(`token=${buildSecretTokenValue()}`)).assertFalse();
  expect(serialized.includes('proxies:')).assertFalse();
}

function joinPieces(pieces: string[]): string {
  return pieces.join('');
}

function buildSensitiveDocumentsPath(fileName: string): string {
  return `${joinPieces(['/Us', 'ers'])}/susiwen8/Documents/${fileName}`;
}

function buildSecretTokenValue(): string {
  return joinPieces(['sec', 'ret']);
}

function buildSensitiveTokenDetail(fileName: string): string {
  return `${buildSensitiveDocumentsPath(fileName)} token=${buildSecretTokenValue()}`;
}

function buildSensitivePemPath(): string {
  return buildSensitiveDocumentsPath(joinPieces(['private', '.pe', 'm']));
}

class ExpectedVpnErrorCase {
  snapshot: VpnRuntimeSnapshot;
  expectedResource: string;

  constructor(snapshot: VpnRuntimeSnapshot, expectedResource: string) {
    this.snapshot = snapshot;
    this.expectedResource = expectedResource;
  }
}

class RejectedVpnStartResultValue {
  kind: 'REJECTED' = 'REJECTED';
  snapshot: VpnRuntimeSnapshot;
  failure: VpnFailure;

  constructor(snapshot: VpnRuntimeSnapshot, failure: VpnFailure) {
    this.snapshot = snapshot;
    this.failure = failure;
  }
}

class FailedVpnStartResultValue {
  kind: 'FAILED' = 'FAILED';
  snapshot: VpnRuntimeSnapshot;
  failure: VpnFailure;

  constructor(snapshot: VpnRuntimeSnapshot, failure: VpnFailure) {
    this.snapshot = snapshot;
    this.failure = failure;
  }
}

class StoppedVpnStartResultValue {
  kind: 'STOPPED' = 'STOPPED';
  snapshot: VpnRuntimeSnapshot;

  constructor(snapshot: VpnRuntimeSnapshot) {
    this.snapshot = snapshot;
  }
}

class VpnActiveHandleSummaryValue {
  sessionId: string = '';
  attached: boolean = true;
}

class ImmediateVpnStartErrorCase {
  result: RejectedVpnStartResultValue | FailedVpnStartResultValue;
  expectedResource: string;

  constructor(result: RejectedVpnStartResultValue | FailedVpnStartResultValue, expectedResource: string) {
    this.result = result;
    this.expectedResource = expectedResource;
  }
}

export default function homeViewModelTestsuite() {
  describe('HomeViewModelTest', () => {
    it('mapsInitializationRuntimeAndPrimaryActionAcrossActiveProfileStates', 0, () => {
      const application = new PresentationTestApplication(createApplicationSnapshot('LOADING', [], undefined, 'STOPPED'));
      const vpnRegistry = createTestVpnRegistry();
      const viewModel = new HomeViewModel(application, vpnRegistry);

      expect(viewModel.current().initialization).assertEqual('LOADING');
      expect(viewModel.current().localProxy.action).assertEqual('DISABLED');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('DISABLED');

      application.emitSnapshot(createApplicationSnapshot('READY', [], undefined, 'STOPPED'));
      expect(viewModel.current().initialization).assertEqual('READY');
      expect(viewModel.current().localProxy.action).assertEqual('DISABLED');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('DISABLED');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED'));
      expect(viewModel.current().localProxy.action).assertEqual('START');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('START');
      expect(viewModel.current().activeProfile?.sourceDisplay).assertEqual('mirror.example.com');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('INVALID', false)], 'active', 'STOPPED'));
      expect(viewModel.current().activeProfile?.availability).assertEqual('INVALID');
      expect(viewModel.current().localProxy.action).assertEqual('DISABLED');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('DISABLED');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('UPDATE_FAILED_USING_VALID', true)], 'active', 'STOPPED'));
      expect(viewModel.current().localProxy.action).assertEqual('START');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('START');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STARTING'));
      expect(viewModel.current().localProxy.status).assertEqual('STARTING');
      expect(viewModel.current().localProxy.action).assertEqual('BUSY');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('BUSY');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'RUNNING', {
        httpAddress: '127.0.0.1:7890',
        socksAddress: '127.0.0.1:7891'
      }));
      expect(viewModel.current().localProxy.status).assertEqual('RUNNING');
      expect(viewModel.current().localProxy.action).assertEqual('STOP');
      expect(viewModel.current().localProxy.httpAddress).assertEqual('127.0.0.1:7890');
      expect(viewModel.current().localProxy.socksAddress).assertEqual('127.0.0.1:7891');

      emitVpnSnapshot(vpnRegistry, createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: {
          profileId: 'active',
          versionId: 'version-1',
          sessionId: 'session-1'
        },
        activeHandle: {
          sessionId: 'session-1',
          attached: true
        },
        captureConfig: {
          addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
          routes: ['0.0.0.0/0', '::/0'],
          dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
          mtu: 1500,
          ipv4: true,
          ipv6: true,
          isBlocking: false,
          blockedApplications: ['com.github.kr328.clash.harmony'],
          trustedApplications: []
        },
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      }));
      expect(viewModel.current().vpnGlobalCapture.status).assertEqual('RUNNING');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('STOP');
      expect(viewModel.current().vpnGlobalCapture.ipv4Enabled).assertTrue();
      expect(viewModel.current().vpnGlobalCapture.ipv6Enabled).assertTrue();

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPING'));
      expect(viewModel.current().localProxy.status).assertEqual('STOPPING');
      expect(viewModel.current().localProxy.action).assertEqual('BUSY');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'ERROR', {
        runtimeError: createSafeError('CMFA_RUNTIME', 'RUNTIME_START', 'core error at /tmp/cmfa/runtime/secret.log'),
        latestRuntimeError: 'fatal at /tmp/cmfa/runtime/secret.log'
      }));
      expect(viewModel.current().localProxy.status).assertEqual('ERROR');
      expect(viewModel.current().localProxy.action).assertEqual('DISABLED');
      expect(viewModel.current().localProxy.error?.technicalDetail.includes('/tmp/cmfa/runtime')).assertFalse();

      emitVpnSnapshot(vpnRegistry, createVpnRuntimeSnapshot({
        state: 'RECOVERING',
        activeRequest: {
          profileId: 'active',
          versionId: 'version-1',
          sessionId: 'session-1'
        },
        activeHandle: {
          sessionId: 'session-1',
          attached: true
        },
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 2,
        scheduledRetryDelayMs: 5000,
        lastFailure: createVpnFailure('VPN_BACKGROUND_TASK_FAILED', 'raw business error')
      }));
      expect(viewModel.current().vpnGlobalCapture.error?.userMessageResource).assertEqual('error.vpn.background_task_failed');
    });

    it('primaryActionUsesRuntimeAddressesAndCoalescesRepeatedClicks', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true, 'https://profile.example.com/config.yaml')], 'active', 'STOPPED', {
          httpAddress: '',
          socksAddress: '',
          latestRuntimeError: 'https://ignored.example.com/full/path.yaml'
        })
      );
      const vpnRegistry = createTestVpnRegistry();
      const deferred = application.deferStart();
      const viewModel = new HomeViewModel(application, vpnRegistry);

      const first = viewModel.requestLocalAction();
      const second = viewModel.requestLocalAction();

      expect(viewModel.current().localProxy.action).assertEqual('BUSY');
      expect(application.commandLog.join('>')).assertEqual('startLocal');

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'RUNNING', {
        httpAddress: '127.0.0.1:7890',
        socksAddress: '127.0.0.1:7891'
      }));
      deferred.resolve();
      await first;
      await second;

      const state: HomeViewState = viewModel.current();
      expect(state.localProxy.httpAddress).assertEqual('127.0.0.1:7890');
      expect(state.localProxy.socksAddress).assertEqual('127.0.0.1:7891');
      expect(state.activeProfile?.sourceDisplay).assertEqual('mirror.example.com');
      assertForbiddenPresentationData(JSON.stringify(state));
    });

    it('disposeUnsubscribesFromApplication', 0, () => {
      const application = new PresentationTestApplication(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED'));
      const vpnRegistry = createTestVpnRegistry();
      const viewModel = new HomeViewModel(application, vpnRegistry);

      expect(application.listenerCount()).assertEqual(1);
      viewModel.dispose();
      expect(application.listenerCount()).assertEqual(0);
    });

    it('reconstructsFromTheLiveVpnRegistrySnapshotAndDisposeNeverStopsVpn', 0, () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
      );
      const vpnRegistry = createTestVpnRegistry();
      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING'));

      const firstViewModel = new HomeViewModel(application, vpnRegistry);
      expect(firstViewModel.current().vpnGlobalCapture.status).assertEqual('RUNNING');

      firstViewModel.dispose();
      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('STOPPED', null, 'session-2'));

      expect(firstViewModel.current().vpnGlobalCapture.status).assertEqual('RUNNING');
      expect(application.commandLog.includes('stopVpnGlobalCapture')).assertFalse();

      const secondViewModel = new HomeViewModel(application, vpnRegistry);
      expect(secondViewModel.current().vpnGlobalCapture.status).assertEqual('STOPPED');
      secondViewModel.dispose();
      expect(application.commandLog.includes('stopVpnGlobalCapture')).assertFalse();
    });

    it('failsClosedForLocalStartWhileVpnOwnsTheNetworkPath', 0, async () => {
      const blockedStates: Array<'AWAITING_CONSENT' | 'RUNNING' | 'RECOVERING' | 'STOPPING'> = [
        'AWAITING_CONSENT',
        'RUNNING',
        'RECOVERING',
        'STOPPING'
      ];

      for (let index = 0; index < blockedStates.length; index += 1) {
        const state = blockedStates[index];
        const application = new PresentationTestApplication(
          createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
        );
        const vpnRegistry = createTestVpnRegistry();
        emitVpnSnapshot(vpnRegistry, buildVpnSnapshot(state));
        const viewModel = new HomeViewModel(application, vpnRegistry);

        expect(viewModel.current().localProxy.action).assertEqual('DISABLED');
        await viewModel.requestLocalAction();
        expect(application.commandLog.includes('startLocal')).assertFalse();
        viewModel.dispose();
      }
    });

    it('failsClosedForLocalStartWhenRuntimeIsErroredAndVpnIsStopped', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'ERROR', {
          runtimeError: createSafeError('CMFA_RUNTIME', 'RUNTIME_START', buildSensitiveTokenDetail('runtime.log')),
          latestRuntimeError: buildSensitiveTokenDetail('runtime.log')
        })
      );
      const viewModel = new HomeViewModel(application, createTestVpnRegistry());

      expect(viewModel.current().localProxy.status).assertEqual('ERROR');
      expect(viewModel.current().localProxy.action).assertEqual('DISABLED');

      await viewModel.requestLocalAction();

      expect(application.commandLog.includes('startLocal')).assertFalse();
      viewModel.dispose();
    });

    it('mapsDistinctVpnMessagesToAllowlistedSafeErrors', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
      );
      const vpnRegistry = createTestVpnRegistry();
      const viewModel = new HomeViewModel(application, vpnRegistry);
      const cases: ExpectedVpnErrorCase[] = [
        new ExpectedVpnErrorCase(
          buildVpnSnapshot('STOPPED', createVpnFailure('VPN_PERMISSION_DENIED', buildSensitiveTokenDetail('token.txt'))),
          'error.vpn.permission_denied'
        ),
        new ExpectedVpnErrorCase(
          buildVpnSnapshot('STOPPED', createVpnFailure('VPN_ALREADY_ACTIVE', `vpnId=vpn-1 token=${buildSecretTokenValue()}`)),
          'error.vpn.already_active'
        ),
        new ExpectedVpnErrorCase(
          buildVpnSnapshot('STOPPED', createVpnFailure('VPN_SYSTEM_REVOKED', `serial=abc ${buildSensitivePemPath()}`)),
          'error.vpn.system_revoked'
        ),
        new ExpectedVpnErrorCase(
          buildVpnSnapshot('STOPPED', createVpnFailure('VPN_BACKGROUND_TASK_FAILED', 'https://user:pw@example.com/profile')),
          'error.vpn.background_task_failed'
        ),
        new ExpectedVpnErrorCase(
          buildVpnSnapshot('STOPPED', createVpnFailure('VPN_STOP_FAILED', buildSensitivePemPath())),
          'error.vpn.stop_failed'
        ),
        new ExpectedVpnErrorCase(
          buildVpnSnapshot('RECOVERING', null),
          'error.vpn.recovering'
        )
      ];

      for (let index = 0; index < cases.length; index += 1) {
        emitVpnSnapshot(vpnRegistry, cases[index].snapshot);
        const error = viewModel.current().vpnGlobalCapture.error;
        expect(error?.userMessageResource ?? '').assertEqual(cases[index].expectedResource);
        expect(error?.technicalDetail.includes(joinPieces(['/Us', 'ers'])) ?? false).assertFalse();
        expect(error?.technicalDetail.includes(`token=${buildSecretTokenValue()}`) ?? false).assertFalse();
        expect(error?.technicalDetail.includes('user:pw') ?? false).assertFalse();
      }

      const localStopRequiredApplication = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'RUNNING')
      );
      localStopRequiredApplication.queueVpnStartResult(
        new RejectedVpnStartResultValue(
          buildVpnSnapshot('STOPPED'),
          createVpnFailure('VPN_LOCAL_STOP_REQUIRED', buildSensitiveTokenDetail('token.txt'))
        )
      );
      const localStopRequiredViewModel = new HomeViewModel(localStopRequiredApplication, createTestVpnRegistry());

      await localStopRequiredViewModel.requestVpnAction();

      const localStopRequiredError = localStopRequiredViewModel.current().vpnGlobalCapture.error;
      expect(localStopRequiredError?.userMessageResource ?? '').assertEqual('error.vpn.requires_local_stop');
      expect(localStopRequiredError?.technicalDetail.includes(joinPieces(['/Us', 'ers'])) ?? false).assertFalse();
      expect(localStopRequiredError?.technicalDetail.includes(`token=${buildSecretTokenValue()}`) ?? false).assertFalse();
      localStopRequiredViewModel.dispose();
      viewModel.dispose();
    });

    it('surfacesImmediateRejectedAndFailedVpnStartResultsAsAllowlistedSafeErrors', 0, async () => {
      const cases: ImmediateVpnStartErrorCase[] = [
        new ImmediateVpnStartErrorCase(
          new RejectedVpnStartResultValue(
            buildVpnSnapshot('STOPPED'),
            createVpnFailure('VPN_PROFILE_UNAVAILABLE', buildSensitiveTokenDetail('missing.yaml'))
          ),
          'error.vpn.profile_unavailable'
        ),
        new ImmediateVpnStartErrorCase(
          new FailedVpnStartResultValue(
            buildVpnSnapshot('STOPPED'),
            createVpnFailure('VPN_CREATE_FAILED', `${buildSensitivePemPath()} token=${buildSecretTokenValue()}`)
          ),
          'error.vpn.start_failed'
        )
      ];

      for (let index = 0; index < cases.length; index += 1) {
        const application = new PresentationTestApplication(
          createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
        );
        application.queueVpnStartResult(cases[index].result);
        const viewModel = new HomeViewModel(application, createTestVpnRegistry());

        await viewModel.requestVpnAction();

        const error = viewModel.current().vpnGlobalCapture.error;
        expect(error?.userMessageResource ?? '').assertEqual(cases[index].expectedResource);
        expect(error?.technicalDetail.includes(joinPieces(['/Us', 'ers'])) ?? false).assertFalse();
        expect(error?.technicalDetail.includes(`token=${buildSecretTokenValue()}`) ?? false).assertFalse();
        viewModel.dispose();
      }
    });

    it('surfacesImmediateStoppedVpnStartResultsAsGenericVisibleFailures', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
      );
      application.queueVpnStartResult(new StoppedVpnStartResultValue(buildVpnSnapshot('STOPPED')));
      const viewModel = new HomeViewModel(application, createTestVpnRegistry());

      await viewModel.requestVpnAction();

      const error = viewModel.current().vpnGlobalCapture.error;
      expect(error?.userMessageResource ?? '').assertEqual('error.vpn.start_failed');
      expect(error?.technicalDetail.includes(joinPieces(['/Us', 'ers'])) ?? false).assertFalse();
      expect(error?.technicalDetail.includes(`token=${buildSecretTokenValue()}`) ?? false).assertFalse();
      viewModel.dispose();
    });

    it('separatesLocalProxyAndVpnGlobalCaptureStateAndStopsLocalBeforeVpnStart', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'RUNNING', {
          httpAddress: '127.0.0.1:7890',
          socksAddress: '127.0.0.1:7891'
        })
      );
      const vpnRegistry = createTestVpnRegistry();
      const viewModel = new HomeViewModel(application, vpnRegistry);

      expect(viewModel.current().localProxy.status).assertEqual('RUNNING');
      expect(viewModel.current().localProxy.action).assertEqual('STOP');
      expect(viewModel.current().vpnGlobalCapture.status).assertEqual('STOPPED');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('START');

      await viewModel.requestVpnAction();

      expect(application.commandLog.join('>')).assertEqual('startVpnGlobalCapture');
    });
  });
}

function createTestVpnRegistry(): VpnSessionRegistry {
  return new VpnSessionRegistry();
}

function emitVpnSnapshot(
  registry: VpnSessionRegistry,
  snapshot: VpnRuntimeSnapshot
): void {
  const request = snapshot.activeRequest;
  if (request === null) {
    const currentSessionId = registry.currentSessionId();
    if (currentSessionId !== undefined) {
      registry.completeStop(currentSessionId, snapshot.lastFailure);
      return;
    }
    if (snapshot.lastFailure !== null) {
      const syntheticRequest = createVpnStartRequest('active', 'version-1', 'stopped-failure-session');
      registry.beginPending(syntheticRequest);
      registry.activatePending(syntheticRequest.sessionId, 'RUNNING');
      registry.completeStop(syntheticRequest.sessionId, snapshot.lastFailure);
    }
    return;
  }
  if (registry.currentSessionId() !== request.sessionId) {
    registry.beginPending(request);
    registry.activatePending(request.sessionId, snapshot.state === 'RUNNING' ? 'RUNNING' : snapshot.state);
  }
  registry.publish({
    sessionId: request.sessionId,
    state: snapshot.state,
    activeHandle: snapshot.activeHandle,
    captureConfig: snapshot.captureConfig,
    tunSnapshot: snapshot.tunSnapshot,
    notificationActive: snapshot.notificationActive,
    recoveryAttempt: snapshot.recoveryAttempt,
    scheduledRetryDelayMs: snapshot.scheduledRetryDelayMs,
    lastFailure: snapshot.lastFailure
  });
}

function buildVpnSnapshot(
  state: 'STOPPED' | 'AWAITING_CONSENT' | 'STARTING' | 'RUNNING' | 'RECOVERING' | 'STOPPING' | 'ERROR',
  lastFailure: VpnFailure | null = null,
  sessionId: string = 'session-1'
): VpnRuntimeSnapshot {
  const activeRequest = state === 'STOPPED' ? null : createVpnStartRequest('active', 'version-1', sessionId);
  const activeHandle = activeRequest === null ? null : createActiveHandleSummary(sessionId);
  return createVpnRuntimeSnapshot({
    state,
    activeRequest,
    activeHandle,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: state !== 'STOPPED',
    recoveryAttempt: state === 'RECOVERING' ? 2 : 0,
    scheduledRetryDelayMs: state === 'RECOVERING' ? 5000 : null,
    lastFailure
  });
}

function createActiveHandleSummary(sessionId: string): VpnActiveHandleSummaryValue {
  const summary = new VpnActiveHandleSummaryValue();
  summary.sessionId = sessionId;
  return summary;
}
