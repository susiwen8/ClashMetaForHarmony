import { describe, expect, it } from '@ohos/hypium';
import {
  createVpnFailure,
  createVpnRpcGuards,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  type VpnRpcClientContext,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot,
  type VpnStartRequest
} from '@cmfa/shared';
import { VpnSessionRegistry, VpnSessionRegistryError } from '../main/ets/vpn/VpnSessionRegistry';

const PROFILE_HASH: string = '1111111111111111111111111111111111111111111111111111111111111111';
const REVISION_HASH: string = '2222222222222222222222222222222222222222222222222222222222222222';
const CATALOG_DIGEST: string = '3333333333333333333333333333333333333333333333333333333333333333';

function createContext(generation: number): VpnRpcClientContext {
  return {
    sessionGeneration: generation,
    guards: createVpnRpcGuards(PROFILE_HASH, REVISION_HASH, CATALOG_DIGEST)
  };
}

function createSnapshot(state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'RECOVERING' | 'STOPPING' | 'ERROR'): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state,
    activeRequest: null,
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: state === 'RUNNING',
    recoveryAttempt: state === 'RECOVERING' ? 1 : 0,
    scheduledRetryDelayMs: null,
    lastFailure: state === 'ERROR' ? createVpnFailure('VPN_STOP_FAILED', 'runtime failure') : null
  });
}

function createRequest(suffix: string): VpnStartRequest {
  return createVpnStartRequest(`profile-${suffix}`, `version-${suffix}`, `session-${suffix}`);
}

function snapshotSessionId(snapshot: VpnRuntimeSnapshot): string {
  return snapshot.activeRequest?.sessionId ?? '';
}

function latestEvent(events: VpnRuntimeEvent[]): VpnRuntimeEvent {
  const event = events[events.length - 1];
  if (event === undefined) {
    expect().assertFail();
  }
  return event as VpnRuntimeEvent;
}

function expectRegistryError(error: Error, code: string): void {
  if (!(error instanceof VpnSessionRegistryError)) {
    expect().assertFail();
  }
  expect((error as VpnSessionRegistryError).code).assertEqual(code);
}

export default function vpnSessionRegistryTestsuite() {
  describe('VpnSessionRegistryTest', () => {
    it('startsStoppedAndClonesSnapshotsAndEvents', 0, () => {
      const registry = new VpnSessionRegistry();
      const events: VpnRuntimeEvent[] = [];
      registry.subscribe((event) => {
        events.push(event);
      });

      const initial = registry.snapshot();
      expect(initial.state).assertEqual('STOPPED');
      expect(initial.activeRequest).assertNull();

      registry.beginPending(createVpnStartRequest('profile-1', 'version-1', 'session-1'));
      registry.activatePending('session-1', 'STARTING');

      initial.state = 'ERROR';
      const firstEvent = latestEvent(events);
      firstEvent.snapshot.state = 'ERROR';
      const fresh = registry.snapshot();
      expect(fresh.state).assertEqual('STARTING');
      expect(snapshotSessionId(fresh)).assertEqual('session-1');
      expect(snapshotSessionId(latestEvent(events).snapshot)).assertEqual('session-1');
    });

    it('rejectsDuplicateLiveSessionsAndStoppedLeaseMutations', 0, () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending(createVpnStartRequest('profile-1', 'version-1', 'session-1'));

      try {
        registry.beginPending(createVpnStartRequest('profile-2', 'version-2', 'session-2'));
        expect().assertFail();
      } catch (error) {
        expectRegistryError(error as Error, 'SESSION_ALREADY_LIVE');
      }

      registry.completeStop('session-1');
      const lease = registry.acquireStoppedProxyLease();
      expect(lease === undefined).assertFalse();
      try {
        registry.beginPending(createVpnStartRequest('profile-3', 'version-3', 'session-3'));
        expect().assertFail();
      } catch (error) {
        expectRegistryError(error as Error, 'PROXY_MUTATION_IN_PROGRESS');
      }
      lease?.release();
      registry.beginPending(createVpnStartRequest('profile-3', 'version-3', 'session-3'));
      expect(registry.snapshot().state).assertEqual('AWAITING_CONSENT');
    });

    it('hydratesAuthenticatedRpcSnapshotsAndKeepsAnonymousOwnershipInternal', 0, () => {
      const registry = new VpnSessionRegistry();
      const events: VpnRuntimeEvent[] = [];
      registry.subscribe((event) => {
        events.push(event);
      });

      const applied = registry.hydrateRpcSnapshot(createSnapshot('RUNNING'), createContext(0));
      expect(applied).assertTrue();
      expect(registry.snapshot().state).assertEqual('RUNNING');
      expect(registry.snapshot().activeRequest).assertNull();
      expect(registry.currentSessionId() === undefined).assertFalse();
      expect(latestEvent(events).type).assertEqual('STATE_CHANGED');
    });

    it('rejectsUnauthenticatedActiveRpcSnapshotsAndCallerMutationDoesNotFlowBack', 0, () => {
      const registry = new VpnSessionRegistry();
      const applied = registry.hydrateRpcSnapshot(createSnapshot('RUNNING'), null);
      expect(applied).assertFalse();
      expect(registry.snapshot().state).assertEqual('STOPPED');

      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      const snapshot = createSnapshot('RECOVERING');
      registry.hydrateRpcSnapshot(snapshot, createContext(4), request);
      const fresh = registry.snapshot();
      expect(fresh.state).assertEqual('RECOVERING');
      expect(snapshotSessionId(fresh)).assertEqual('session-1');

      request.sessionId = 'mutated';
      snapshot.state = 'ERROR';
      const second = registry.snapshot();
      expect(snapshotSessionId(second)).assertEqual('session-1');
      expect(second.state).assertEqual('RECOVERING');
    });

    it('completesAndMarksStopsForAnonymousHydratedSessions', 0, () => {
      const registry = new VpnSessionRegistry();
      registry.hydrateRpcSnapshot(createSnapshot('RUNNING'), createContext(1));
      const liveSessionId = registry.currentSessionId();
      expect(liveSessionId === undefined).assertFalse();

      const marked = registry.markUserStopRequested();
      expect(marked ?? '').assertEqual(liveSessionId ?? '');
      expect(registry.isUserStopRequested(marked ?? '')).assertTrue();

      const completed = registry.completeStop(marked);
      expect(completed).assertTrue();
      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(registry.currentSessionId()).assertUndefined();
    });

    it('preservesLegacyHydrationHelpersForKnownRequests', 0, () => {
      const registry = new VpnSessionRegistry();
      const request = createRequest('1');

      expect(registry.hydrateBridgeState(request, 'STARTING')).assertTrue();
      expect(registry.snapshot().state).assertEqual('STARTING');
      expect(snapshotSessionId(registry.snapshot())).assertEqual('session-1');

      const failure = createVpnFailure('VPN_SYSTEM_REVOKED', 'sanitized');
      expect(registry.hydrateFailure(failure, request)).assertTrue();
      expect(registry.snapshot().state).assertEqual('ERROR');
      expect(snapshotSessionId(registry.snapshot())).assertEqual('session-1');
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_SYSTEM_REVOKED');
    });

    it('entersRecoveringHydrationGateFromStoppedAndBlocksNewOwnership', 0, () => {
      const registry = new VpnSessionRegistry();
      const events: VpnRuntimeEvent[] = [];
      registry.subscribe((event) => {
        events.push(event);
      });

      registry.beginRuntimeMirrorHydration();

      const snapshot = registry.snapshot();
      expect(snapshot.state).assertEqual('RECOVERING');
      expect(snapshot.activeRequest).assertNull();
      expect(snapshotSessionId(latestEvent(events).snapshot)).assertEqual('');
      expect(latestEvent(events).snapshot.state).assertEqual('RECOVERING');
      expect(registry.acquireStoppedProxyLease()).assertUndefined();

      try {
        registry.beginPending(createRequest('gate'));
        expect().assertFail();
      } catch (error) {
        expectRegistryError(error as Error, 'SESSION_ALREADY_LIVE');
      }
    });

    it('preservesLiveRequestWhenRuntimeMirrorHydrationBegins', 0, () => {
      const registry = new VpnSessionRegistry();
      const request = createRequest('live');
      registry.beginPending(request);
      registry.activatePending(request.sessionId, 'RUNNING');

      registry.beginRuntimeMirrorHydration();

      const snapshot = registry.snapshot();
      expect(snapshot.state).assertEqual('RECOVERING');
      expect(snapshotSessionId(snapshot)).assertEqual(request.sessionId);
      expect(registry.currentSessionId()).assertEqual(request.sessionId);
    });

    it('clearsHydrationGateAfterAuthoritativeRpcSnapshots', 0, () => {
      const runningRegistry = new VpnSessionRegistry();
      const runningRequest = createRequest('running');
      runningRegistry.beginRuntimeMirrorHydration();

      expect(runningRegistry.hydrateRpcSnapshot(createSnapshot('RUNNING'), createContext(8), runningRequest)).assertTrue();
      runningRegistry.completeRuntimeMirrorHydrationUnavailable();
      expect(runningRegistry.snapshot().state).assertEqual('RUNNING');
      expect(snapshotSessionId(runningRegistry.snapshot())).assertEqual(runningRequest.sessionId);
      expect(runningRegistry.completeStop(runningRequest.sessionId)).assertTrue();
      runningRegistry.beginPending(createRequest('after-running'));
      expect(snapshotSessionId(runningRegistry.snapshot())).assertEqual('session-after-running');

      const stoppedRegistry = new VpnSessionRegistry();
      stoppedRegistry.beginRuntimeMirrorHydration();
      expect(stoppedRegistry.hydrateRpcSnapshot(createSnapshot('STOPPED'), createContext(9))).assertTrue();
      const lease = stoppedRegistry.acquireStoppedProxyLease();
      expect(lease === undefined).assertFalse();
      lease?.release();
      stoppedRegistry.beginPending(createRequest('after-stopped'));
      expect(snapshotSessionId(stoppedRegistry.snapshot())).assertEqual('session-after-stopped');
    });

    it('clearsHydrationGateAfterBridgeStateHydration', 0, () => {
      const registry = new VpnSessionRegistry();
      const request = createRequest('bridge');

      registry.beginRuntimeMirrorHydration();
      expect(registry.hydrateBridgeState(request, 'STARTING')).assertTrue();

      expect(registry.snapshot().state).assertEqual('STARTING');
      expect(snapshotSessionId(registry.snapshot())).assertEqual(request.sessionId);

      registry.completeRuntimeMirrorHydrationUnavailable();
      expect(registry.snapshot().state).assertEqual('STARTING');
      expect(snapshotSessionId(registry.snapshot())).assertEqual(request.sessionId);
    });

    it('clearsHydrationGateAfterFailureHydration', 0, () => {
      const registry = new VpnSessionRegistry();
      const request = createRequest('failure');
      const failure = createVpnFailure('VPN_SYSTEM_REVOKED', 'hydration failure');

      registry.beginRuntimeMirrorHydration();
      expect(registry.hydrateFailure(failure, request)).assertTrue();

      expect(registry.snapshot().state).assertEqual('ERROR');
      expect(snapshotSessionId(registry.snapshot())).assertEqual(request.sessionId);
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_SYSTEM_REVOKED');

      registry.completeRuntimeMirrorHydrationUnavailable();
      expect(registry.snapshot().state).assertEqual('ERROR');
      expect(snapshotSessionId(registry.snapshot())).assertEqual(request.sessionId);
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_SYSTEM_REVOKED');
    });

    it('completesUnavailableHydrationIdempotentlyWithoutClearingOrdinaryRecoveringSessions', 0, () => {
      const registry = new VpnSessionRegistry();
      const events: VpnRuntimeEvent[] = [];
      registry.subscribe((event) => {
        events.push(event);
      });

      registry.beginRuntimeMirrorHydration();
      registry.completeRuntimeMirrorHydrationUnavailable();
      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(latestEvent(events).type).assertEqual('STOPPED');

      const lease = registry.acquireStoppedProxyLease();
      expect(lease === undefined).assertFalse();
      lease?.release();
      registry.beginPending(createRequest('after-unavailable'));
      expect(registry.snapshot().state).assertEqual('AWAITING_CONSENT');

      registry.completeRuntimeMirrorHydrationUnavailable();
      expect(registry.snapshot().state).assertEqual('AWAITING_CONSENT');
      expect(snapshotSessionId(registry.snapshot())).assertEqual('session-after-unavailable');

      const recoveringRegistry = new VpnSessionRegistry();
      const recoveringRequest = createRequest('recovering');
      recoveringRegistry.beginPending(recoveringRequest);
      recoveringRegistry.activatePending(recoveringRequest.sessionId, 'RECOVERING');
      recoveringRegistry.completeRuntimeMirrorHydrationUnavailable();
      expect(recoveringRegistry.snapshot().state).assertEqual('RECOVERING');
      expect(snapshotSessionId(recoveringRegistry.snapshot())).assertEqual(recoveringRequest.sessionId);
    });

    it('clearsHydrationGateAfterCompleteStop', 0, () => {
      const registry = new VpnSessionRegistry();
      const request = createRequest('complete-stop');
      registry.beginPending(request);
      registry.activatePending(request.sessionId, 'RUNNING');
      registry.beginRuntimeMirrorHydration();

      expect(registry.completeStop(request.sessionId)).assertTrue();
      expect(registry.snapshot().state).assertEqual('STOPPED');

      registry.completeRuntimeMirrorHydrationUnavailable();
      expect(registry.snapshot().state).assertEqual('STOPPED');

      registry.beginPending(createRequest('after-complete-stop'));
      expect(snapshotSessionId(registry.snapshot())).assertEqual('session-after-complete-stop');
    });
  });
}
