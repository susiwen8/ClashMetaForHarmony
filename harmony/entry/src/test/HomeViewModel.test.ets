import { describe, expect, it } from '@ohos/hypium';
import {
  createOneClickVpnOperationSnapshot,
  createVpnFailure,
  type HomeProxySelectionSummary,
  type OneClickVpnOperationSnapshot,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  type ProfileApplicationProfileSnapshot,
  type CoreRuntimeMode,
  type VpnRpcRuntimeModeClientPort,
  type VpnFailure,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot
} from '@cmfa/shared';
import type { HomeViewState } from '../main/ets/presentation/PresentationModels';
import { HomeViewModel } from '../main/ets/presentation/HomeViewModel';
import { VpnSessionRegistry } from '../main/ets/vpn/VpnSessionRegistry';
import {
  createApplicationSnapshot,
  createProfileSnapshot,
  createSafeError,
  DeferredResult,
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

function assertVpnOnlyHomeState(state: HomeViewState): void {
  const serialized: string = JSON.stringify(state);
  expect(serialized.includes('localProxy')).assertFalse();
  expect(serialized.includes('127.0.0.1:7890')).assertFalse();
  expect(serialized.includes('127.0.0.1:7891')).assertFalse();
  expect(serialized.includes('/tmp/cmfa/runtime')).assertFalse();
}

function joinPieces(pieces: string[]): string {
  return pieces.join('');
}

function createHomeProxySelectionSummary(groupName: string, nodeName: string): HomeProxySelectionSummary {
  return {
    groupName,
    nodeName
  };
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

async function flushPromises(turns: number = 6): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

class FakeRuntimeModeClient implements VpnRpcRuntimeModeClientPort {
  mode: CoreRuntimeMode = 'RULE';
  readonly queryCalls: string[] = [];
  readonly setCalls: CoreRuntimeMode[] = [];

  async queryMode(): Promise<CoreRuntimeMode> {
    this.queryCalls.push('query');
    return this.mode;
  }

  async setMode(mode: CoreRuntimeMode): Promise<CoreRuntimeMode> {
    this.setCalls.push(mode);
    this.mode = mode;
    return mode;
  }
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

class RecordingVpnSessionRegistry extends VpnSessionRegistry {
  private listenerCountValue: number = 0;

  subscribe(listener: (event: VpnRuntimeEvent) => void): number {
    const subscriptionId = super.subscribe(listener);
    this.listenerCountValue += 1;
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    super.unsubscribe(subscriptionId);
    this.listenerCountValue = Math.max(0, this.listenerCountValue - 1);
  }

  listenerCount(): number {
    return this.listenerCountValue;
  }
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
    it('loadsAndSwitchesTheCurrentSessionModeOnlyWhileVpnIsRunning', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
      );
      const vpnRegistry = createTestVpnRegistry();
      const runtimeMode = new FakeRuntimeModeClient();
      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING', null, 'mode-session'));
      const viewModel = new HomeViewModel(application, vpnRegistry, runtimeMode);

      await flushPromises();
      expect(viewModel.current().runtimeMode.available).assertTrue();
      expect(viewModel.current().runtimeMode.mode).assertEqual('RULE');
      expect(runtimeMode.queryCalls.length).assertEqual(1);

      await viewModel.requestRuntimeMode('GLOBAL');
      expect(runtimeMode.setCalls.join(',')).assertEqual('GLOBAL');
      expect(viewModel.current().runtimeMode.mode).assertEqual('GLOBAL');
      expect(viewModel.current().runtimeMode.pending).assertFalse();

      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('STOPPED', null, 'mode-session'));
      await viewModel.requestRuntimeMode('DIRECT');
      expect(viewModel.current().runtimeMode.available).assertFalse();
      expect(runtimeMode.setCalls.join(',')).assertEqual('GLOBAL');
      viewModel.dispose();
    });

    it('mapsInitializationAndVpnOnlyHomeStateAcrossActiveProfileStates', 0, () => {
      const application = new PresentationTestApplication(createApplicationSnapshot('LOADING', [], undefined, 'STOPPED'));
      const vpnRegistry = createTestVpnRegistry();
      const viewModel = new HomeViewModel(application, vpnRegistry);

      expect(viewModel.current().initialization).assertEqual('LOADING');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('DISABLED');
      assertVpnOnlyHomeState(viewModel.current());

      application.emitSnapshot(createApplicationSnapshot('READY', [], undefined, 'STOPPED'));
      expect(viewModel.current().initialization).assertEqual('READY');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('DISABLED');
      assertVpnOnlyHomeState(viewModel.current());

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED'));
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('START');
      expect(viewModel.current().activeProfile?.sourceDisplay).assertEqual('mirror.example.com');
      assertVpnOnlyHomeState(viewModel.current());

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('INVALID', false)], 'active', 'STOPPED'));
      expect(viewModel.current().activeProfile?.availability).assertEqual('INVALID');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('DISABLED');
      assertVpnOnlyHomeState(viewModel.current());

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('UPDATE_FAILED_USING_VALID', true)], 'active', 'STOPPED'));
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('START');
      assertVpnOnlyHomeState(viewModel.current());

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STARTING'));
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('START');
      assertVpnOnlyHomeState(viewModel.current());

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'RUNNING', {
        httpAddress: '127.0.0.1:7890',
        socksAddress: '127.0.0.1:7891'
      }));
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('START');
      assertVpnOnlyHomeState(viewModel.current());

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
      assertVpnOnlyHomeState(viewModel.current());

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPING'));
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('STOP');
      assertVpnOnlyHomeState(viewModel.current());

      application.emitSnapshot(createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'ERROR', {
        runtimeError: createSafeError('CMFA_RUNTIME', 'RUNTIME_START', 'core error at /tmp/cmfa/runtime/secret.log'),
        latestRuntimeError: 'fatal at /tmp/cmfa/runtime/secret.log'
      }));
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('STOP');
      expect(viewModel.current().vpnGlobalCapture.error === undefined).assertTrue();
      assertVpnOnlyHomeState(viewModel.current());

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
      assertVpnOnlyHomeState(viewModel.current());
    });

    it('disablesVpnStartAndProxyManagementWithoutCurrentRevision', 0, () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', false)], 'active', 'STOPPED')
      );
      const viewModel = new HomeViewModel(application, createTestVpnRegistry());

      const state: HomeViewState = viewModel.current();
      expect(state.activeProfile?.availability).assertEqual('VALID');
      expect(state.vpnGlobalCapture.action).assertEqual('DISABLED');
      expect(state.canManageProxies).assertFalse();
      assertVpnOnlyHomeState(state);

      viewModel.dispose();
    });

    it('blocksProxyManagementWhileRuntimeMirrorHydrationIsRecoveringButRestoresItForStoppedAndRunningStates', 0, () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
      );
      const vpnRegistry = createTestVpnRegistry();
      const viewModel = new HomeViewModel(application, vpnRegistry);

      expect(viewModel.current().vpnGlobalCapture.status).assertEqual('STOPPED');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('START');
      expect(viewModel.current().canManageProxies).assertTrue();

      vpnRegistry.beginRuntimeMirrorHydration();

      expect(viewModel.current().vpnGlobalCapture.status).assertEqual('RECOVERING');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('BUSY');
      expect(viewModel.current().canManageProxies).assertFalse();

      vpnRegistry.completeRuntimeMirrorHydrationUnavailable();

      expect(viewModel.current().vpnGlobalCapture.status).assertEqual('STOPPED');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('START');
      expect(viewModel.current().canManageProxies).assertTrue();

      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING'));

      expect(viewModel.current().vpnGlobalCapture.status).assertEqual('RUNNING');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('STOP');
      expect(viewModel.current().canManageProxies).assertTrue();

      viewModel.dispose();
    });

    it('keepsStopAvailableForActiveVpnErrorAfterMirrorReplayFailureButStillAllowsRetryWhenNoActiveRequestRemains', 0, () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
      );
      const vpnRegistry = createTestVpnRegistry();
      const request = createVpnStartRequest('active', 'version-1', 'session-replay');
      const viewModel = new HomeViewModel(application, vpnRegistry);

      vpnRegistry.beginPending(request);
      expect(vpnRegistry.hydrateFailure(createVpnFailure('VPN_PROXY_REPLAY_FAILED', 'mirror retry exhausted'), request))
        .assertTrue();

      expect(viewModel.current().vpnGlobalCapture.status).assertEqual('ERROR');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('STOP');
      expect(viewModel.current().canManageProxies).assertFalse();

      expect(vpnRegistry.hydrateFailure(createVpnFailure('VPN_PROXY_REPLAY_FAILED', 'mirror retry exhausted'), request, true))
        .assertTrue();

      expect(viewModel.current().vpnGlobalCapture.status).assertEqual('ERROR');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('START');
      expect(viewModel.current().canManageProxies).assertFalse();

      viewModel.dispose();
    });

    it('vpnActionCoalescesRepeatedClicksAndIgnoresLegacyLocalRuntimeAddresses', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true, 'https://profile.example.com/config.yaml')], 'active', 'STOPPED', {
          httpAddress: '127.0.0.1:7890',
          socksAddress: '127.0.0.1:7891',
          latestRuntimeError: 'https://ignored.example.com/full/path.yaml'
        })
      );
      const vpnRegistry = createTestVpnRegistry();
      application.queueVpnStartResult(new Promise<RejectedVpnStartResultValue>(() => {
      }));
      const viewModel = new HomeViewModel(application, vpnRegistry);

      void viewModel.requestVpnAction();
      void viewModel.requestVpnAction();

      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('BUSY');
      expect(application.commandLog.join('>')).assertEqual('startVpnGlobalCapture');
      assertVpnOnlyHomeState(viewModel.current());
      expect(viewModel.current().activeProfile?.sourceDisplay).assertEqual('profile.example.com');

      const startedSnapshot = createVpnRuntimeSnapshot({
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
      });
      emitVpnSnapshot(vpnRegistry, startedSnapshot);

      const state: HomeViewState = viewModel.current();
      expect(state.activeProfile?.sourceDisplay).assertEqual('profile.example.com');
      expect(state.vpnGlobalCapture.status).assertEqual('RUNNING');
      expect(state.vpnGlobalCapture.ipv4Enabled).assertTrue();
      expect(state.vpnGlobalCapture.ipv6Enabled).assertTrue();
      assertVpnOnlyHomeState(state);
      assertForbiddenPresentationData(JSON.stringify(state));
      viewModel.dispose();
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

    it('allowsVpnStartEvenWhenLegacyLocalRuntimeSnapshotIsErrored', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'ERROR', {
          runtimeError: createSafeError('CMFA_RUNTIME', 'RUNTIME_START', buildSensitiveTokenDetail('runtime.log')),
          latestRuntimeError: buildSensitiveTokenDetail('runtime.log')
        })
      );
      const viewModel = new HomeViewModel(application, createTestVpnRegistry());

      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('START');
      assertVpnOnlyHomeState(viewModel.current());

      await viewModel.requestVpnAction();

      expect(application.commandLog.includes('startVpnGlobalCapture')).assertTrue();
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

    it('startsVpnEvenWhenLegacyLocalRuntimeSnapshotIsRunning', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'RUNNING', {
          httpAddress: '127.0.0.1:7890',
          socksAddress: '127.0.0.1:7891'
        })
      );
      const vpnRegistry = createTestVpnRegistry();
      const viewModel = new HomeViewModel(application, vpnRegistry);

      assertVpnOnlyHomeState(viewModel.current());
      expect(viewModel.current().vpnGlobalCapture.status).assertEqual('STOPPED');
      expect(viewModel.current().vpnGlobalCapture.action).assertEqual('START');

      await viewModel.requestVpnAction();

      expect(application.commandLog.join('>')).assertEqual('startVpnGlobalCapture');
    });

    it('publishesSelectedProxySummaryAfterAsyncQueryWhenConstructedWithReadyRunningVpn', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
      );
      const vpnRegistry = createTestVpnRegistry();
      const deferred = new DeferredResult<HomeProxySelectionSummary | undefined>();
      const published: HomeViewState[] = [];
      application.queueHomeProxySelectionResult(deferred.promise);
      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING', null, 'session-home-1'));

      const viewModel = new HomeViewModel(application, vpnRegistry);
      viewModel.subscribe((state: HomeViewState): void => {
        published.push(state);
      });

      expect(viewModel.current().selectedProxyGroupName).assertEqual('');
      expect(viewModel.current().selectedProxyNodeName).assertEqual('');
      expect(application.commandLog.join('>')).assertEqual('queryHomeProxySelection');

      deferred.resolve(createHomeProxySelectionSummary('Primary', 'Tokyo'));
      await flushPromises();

      const state: HomeViewState = viewModel.current();
      expect(state.selectedProxyGroupName).assertEqual('Primary');
      expect(state.selectedProxyNodeName).assertEqual('Tokyo');
      expect(published.some((publishedState: HomeViewState) => {
        return publishedState.selectedProxyGroupName === 'Primary' && publishedState.selectedProxyNodeName === 'Tokyo';
      })).assertTrue();
      viewModel.dispose();
    });

    it('clearsSelectedProxySummaryImmediatelyForNonRunningVpnStates', 0, async () => {
      const clearedStates: Array<'STOPPED' | 'AWAITING_CONSENT' | 'STARTING' | 'RECOVERING' | 'STOPPING' | 'ERROR'> = [
        'STOPPED',
        'AWAITING_CONSENT',
        'STARTING',
        'RECOVERING',
        'STOPPING',
        'ERROR'
      ];

      for (let index: number = 0; index < clearedStates.length; index += 1) {
        const sessionId = `running-${index}`;
        const application = new PresentationTestApplication(
          createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
        );
        const vpnRegistry = createTestVpnRegistry();
        application.queueHomeProxySelectionResult(createHomeProxySelectionSummary('Primary', 'Tokyo'));
        emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING', null, sessionId));
        const viewModel = new HomeViewModel(application, vpnRegistry);
        await flushPromises();

        expect(viewModel.current().selectedProxyGroupName).assertEqual('Primary');
        expect(viewModel.current().selectedProxyNodeName).assertEqual('Tokyo');

        emitVpnSnapshot(vpnRegistry, buildVpnSnapshot(clearedStates[index], null, sessionId));

        expect(viewModel.current().selectedProxyGroupName).assertEqual('');
        expect(viewModel.current().selectedProxyNodeName).assertEqual('');
        viewModel.dispose();
      }
    });

    it('clearsSelectedProxySummaryWhenQueryIsUnavailableOrThrowsWithoutCreatingNewErrorCard', 0, async () => {
      const unavailableCases: Array<Promise<HomeProxySelectionSummary | undefined> | undefined> = [
        undefined,
        Promise.reject(new Error('queryHomeProxySelection failed'))
      ];

      for (let index: number = 0; index < unavailableCases.length; index += 1) {
        const application = new PresentationTestApplication(
          createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
        );
        const vpnRegistry = createTestVpnRegistry();
        application.queueHomeProxySelectionResult(unavailableCases[index]);
        emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING', null, `missing-${index}`));
        const viewModel = new HomeViewModel(application, vpnRegistry);

        await flushPromises();

        const state: HomeViewState = viewModel.current();
        expect(state.selectedProxyGroupName).assertEqual('');
        expect(state.selectedProxyNodeName).assertEqual('');
        expect(state.error === undefined).assertTrue();
        viewModel.dispose();
      }
    });

    it('retriesSelectionQueryOnOrdinaryRunningEventAfterSameSessionUndefinedOrThrownResult', 0, async () => {
      const unavailableCases: Array<HomeProxySelectionSummary | Promise<HomeProxySelectionSummary | undefined> | undefined> = [
        undefined,
        Promise.reject(new Error('queryHomeProxySelection failed'))
      ];

      for (let index: number = 0; index < unavailableCases.length; index += 1) {
        const sessionId = `retry-session-${index}`;
        const application = new PresentationTestApplication(
          createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
        );
        const vpnRegistry = createTestVpnRegistry();
        application.queueHomeProxySelectionResult(unavailableCases[index]);
        emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING', null, sessionId));
        const viewModel = new HomeViewModel(application, vpnRegistry);

        await flushPromises();

        expect(viewModel.current().selectedProxyGroupName).assertEqual('');
        expect(viewModel.current().selectedProxyNodeName).assertEqual('');
        expect(application.commandLog.join('>')).assertEqual('queryHomeProxySelection');

        application.queueHomeProxySelectionResult(createHomeProxySelectionSummary('Primary', 'Retry Winner'));
        emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING', null, sessionId));
        await flushPromises();

        expect(application.commandLog.join('>')).assertEqual('queryHomeProxySelection>queryHomeProxySelection');
        expect(viewModel.current().selectedProxyGroupName).assertEqual('Primary');
        expect(viewModel.current().selectedProxyNodeName).assertEqual('Retry Winner');
        viewModel.dispose();
      }
    });

    it('serializesOnlySafeSelectedProxyDisplayFields', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED', {
          httpAddress: '127.0.0.1:7890'
        })
      );
      const vpnRegistry = createTestVpnRegistry();
      application.queueHomeProxySelectionResult(createHomeProxySelectionSummary('Primary', 'Tokyo'));
      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING', null, 'session-sensitive-home'));
      const viewModel = new HomeViewModel(application, vpnRegistry);

      await flushPromises();

      const serialized: string = JSON.stringify(viewModel.current());
      expect(serialized.includes('"selectedProxyGroupName":"Primary"')).assertTrue();
      expect(serialized.includes('"selectedProxyNodeName":"Tokyo"')).assertTrue();
      expect(serialized.includes('session-sensitive-home')).assertFalse();
      expect(serialized.includes('Gateway/Shared/Terminal')).assertFalse();
      expect(serialized.includes('revision-secret')).assertFalse();
      expect(serialized.includes(`token=${buildSecretTokenValue()}`)).assertFalse();
      expect(serialized.includes('127.0.0.1:7890')).assertFalse();
      expect(serialized.includes('listener.local:8080')).assertFalse();
      viewModel.dispose();
    });

    it('ignoresStaleSelectionResultWhenASlowerPreviousSessionCompletesAfterSessionBPublishes', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
      );
      const vpnRegistry = createTestVpnRegistry();
      const sessionAResult = new DeferredResult<HomeProxySelectionSummary | undefined>();
      application.queueHomeProxySelectionResult(sessionAResult.promise);
      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING', null, 'session-A'));
      const viewModel = new HomeViewModel(application, vpnRegistry);

      application.queueHomeProxySelectionResult(createHomeProxySelectionSummary('Primary', 'Osaka'));
      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('STOPPED', null, 'session-A'));
      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING', null, 'session-B'));
      await flushPromises();

      expect(viewModel.current().selectedProxyNodeName).assertEqual('Osaka');

      sessionAResult.resolve(createHomeProxySelectionSummary('Primary', 'Tokyo'));
      await flushPromises();

      expect(viewModel.current().selectedProxyGroupName).assertEqual('Primary');
      expect(viewModel.current().selectedProxyNodeName).assertEqual('Osaka');
      viewModel.dispose();
    });

    it('keepsSelectedProxySummaryClearedWhenStoppedBeforeSlowQueryCompletes', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
      );
      const vpnRegistry = createTestVpnRegistry();
      const deferred = new DeferredResult<HomeProxySelectionSummary | undefined>();
      application.queueHomeProxySelectionResult(deferred.promise);
      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING', null, 'session-stop-late'));
      const viewModel = new HomeViewModel(application, vpnRegistry);

      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('STOPPED', null, 'session-stop-late'));
      expect(viewModel.current().selectedProxyGroupName).assertEqual('');
      expect(viewModel.current().selectedProxyNodeName).assertEqual('');

      deferred.resolve(createHomeProxySelectionSummary('Primary', 'Tokyo'));
      await flushPromises();

      expect(viewModel.current().selectedProxyGroupName).assertEqual('');
      expect(viewModel.current().selectedProxyNodeName).assertEqual('');
      viewModel.dispose();
    });

    it('disposePreventsPendingSelectionPublishAndUnsubscribesApplicationVpnAndOneClickListeners', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
      );
      const vpnRegistry = createTestVpnRegistry();
      const deferred = new DeferredResult<HomeProxySelectionSummary | undefined>();
      const published: HomeViewState[] = [];
      application.queueHomeProxySelectionResult(deferred.promise);
      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING', null, 'session-dispose'));
      const viewModel = new HomeViewModel(application, vpnRegistry);
      viewModel.subscribe((state: HomeViewState): void => {
        published.push(state);
      });

      expect(application.listenerCount()).assertEqual(1);
      expect(application.oneClickListenerCount()).assertEqual(1);
      expect(vpnRegistry.listenerCount()).assertEqual(1);

      viewModel.dispose();

      expect(application.listenerCount()).assertEqual(0);
      expect(application.oneClickListenerCount()).assertEqual(0);
      expect(vpnRegistry.listenerCount()).assertEqual(0);

      deferred.resolve(createHomeProxySelectionSummary('Primary', 'Tokyo'));
      application.emitOneClickVpnOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('STOPPED', null, 'session-dispose'));
      await flushPromises();

      expect(published.length).assertEqual(0);
      expect(viewModel.current().selectedProxyGroupName).assertEqual('');
      expect(viewModel.current().selectedProxyNodeName).assertEqual('');
    });

    it('refreshesSelectedProxySummaryOnlyAfterSucceededIdleOneClickOperation', 0, async () => {
      const application = new PresentationTestApplication(
        createApplicationSnapshot('READY', [createActiveProfile('VALID', true)], 'active', 'STOPPED')
      );
      const vpnRegistry = createTestVpnRegistry();
      const published: HomeViewState[] = [];
      application.queueHomeProxySelectionResult(createHomeProxySelectionSummary('Primary', 'Tokyo'));
      emitVpnSnapshot(vpnRegistry, buildVpnSnapshot('RUNNING', null, 'session-one-click'));
      const viewModel = new HomeViewModel(application, vpnRegistry);
      viewModel.subscribe((state: HomeViewState): void => {
        published.push(state);
      });

      await flushPromises();
      expect(application.oneClickListenerCount()).assertEqual(1);

      const nonRefreshSnapshots: OneClickVpnOperationSnapshot[] = [
        createOneClickVpnOperationSnapshot('IDLE', false, 'FAILED'),
        createOneClickVpnOperationSnapshot('IDLE', false, 'NONE'),
        createOneClickVpnOperationSnapshot('SAVING_SELECTION', true, 'NONE'),
        createOneClickVpnOperationSnapshot('CONFIRMING_SELECTION', true, 'NONE')
      ];
      for (let index: number = 0; index < nonRefreshSnapshots.length; index += 1) {
        application.emitOneClickVpnOperation(nonRefreshSnapshots[index]);
      }

      expect(application.commandLog.join('>')).assertEqual('queryHomeProxySelection');

      application.queueHomeProxySelectionResult(createHomeProxySelectionSummary('Primary', 'Osaka'));
      application.emitOneClickVpnOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      await flushPromises();

      expect(application.commandLog.join('>')).assertEqual('queryHomeProxySelection>queryHomeProxySelection');
      expect(viewModel.current().selectedProxyNodeName).assertEqual('Osaka');
      expect(published.some((publishedState: HomeViewState) => {
        return publishedState.selectedProxyGroupName === 'Primary' && publishedState.selectedProxyNodeName === 'Osaka';
      })).assertTrue();
      viewModel.dispose();
    });

  });
}

function createTestVpnRegistry(): RecordingVpnSessionRegistry {
  return new RecordingVpnSessionRegistry();
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
