import { describe, expect, it } from '@ohos/hypium';
import {
  createVpnFailure,
  createVpnStartRequest,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot
} from '@cmfa/shared';
import { VpnSessionRegistry, VpnSessionRegistryError } from '../main/ets/vpn/VpnSessionRegistry';

function snapshotSessionId(snapshot: VpnRuntimeSnapshot): string {
  return snapshot.activeRequest?.sessionId ?? '';
}

function latestEvent(events: VpnRuntimeEvent[]): VpnRuntimeEvent {
  const event: VpnRuntimeEvent | undefined = events[events.length - 1];
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

async function expectRejects(action: () => Promise<void> | void): Promise<Error> {
  try {
    await action();
    expect().assertFail();
  } catch (error) {
    return error as Error;
  }
  return new Error('Expected rejection.');
}

export default function vpnSessionRegistryTestsuite() {
  describe('VpnSessionRegistryTest', () => {
    it('startsStoppedAndClonesSnapshotsAndEvents', 0, () => {
      const registry = new VpnSessionRegistry();
      const events: VpnRuntimeEvent[] = [];

      registry.subscribe((event: VpnRuntimeEvent) => {
        events.push(event);
      });

      const initial = registry.snapshot();
      expect(initial.state).assertEqual('STOPPED');
      expect(initial.activeRequest).assertNull();
      expect(initial.lastFailure).assertNull();

      registry.beginPending(createVpnStartRequest('profile-1', 'version-1', 'session-1'));
      const pending = registry.snapshot();
      expect(pending.state).assertEqual('AWAITING_CONSENT');
      expect(snapshotSessionId(pending)).assertEqual('session-1');

      initial.state = 'ERROR';
      pending.activeRequest!.sessionId = 'mutated';
      const firstEvent = latestEvent(events);
      firstEvent.snapshot.activeRequest!.sessionId = 'mutated-event';
      firstEvent.snapshot.state = 'ERROR';
      registry.activatePending('session-1', 'STARTING');

      const fresh = registry.snapshot();
      expect(fresh.state).assertEqual('STARTING');
      expect(snapshotSessionId(fresh)).assertEqual('session-1');
      expect(snapshotSessionId(latestEvent(events).snapshot)).assertEqual('session-1');
    });

    it('assignsUniqueSubscriptionIdsAndRejectsDuplicateLiveSessions', 0, async () => {
      const registry = new VpnSessionRegistry();

      const firstId = registry.subscribe((_event: VpnRuntimeEvent) => {
      });
      const secondId = registry.subscribe((_event: VpnRuntimeEvent) => {
      });

      expect(firstId === secondId).assertFalse();

      registry.beginPending(createVpnStartRequest('profile-1', 'version-1', 'session-1'));

      const duplicatePending = await expectRejects(() => {
        registry.beginPending(createVpnStartRequest('profile-1', 'version-1', 'session-1'));
      });
      expectRegistryError(duplicatePending, 'SESSION_ALREADY_LIVE');

      registry.activatePending('session-1', 'STARTING');

      const duplicateActive = await expectRejects(() => {
        registry.beginPending(createVpnStartRequest('profile-2', 'version-2', 'session-2'));
      });
      expectRegistryError(duplicateActive, 'SESSION_ALREADY_LIVE');
    });

    it('acceptsUpdatesOnlyForTheLiveOwnerAndTreatsOlderSessionsAsStale', 0, () => {
      const registry = new VpnSessionRegistry();
      const events: VpnRuntimeEvent[] = [];

      registry.subscribe((event: VpnRuntimeEvent) => {
        events.push(event);
      });

      registry.beginPending(createVpnStartRequest('profile-1', 'version-1', 'session-1'));
      const claimed = registry.activatePending('session-1', 'STARTING');
      expect(claimed?.sessionId ?? '').assertEqual('session-1');

      const runningApplied = registry.publish({
        sessionId: 'session-1',
        state: 'RUNNING',
        notificationActive: true
      });
      expect(runningApplied).assertTrue();
      expect(registry.snapshot().state).assertEqual('RUNNING');

      const eventCountBeforeStale = events.length;
      const staleApplied = registry.publish({
        sessionId: 'session-stale',
        state: 'ERROR',
        lastFailure: createVpnFailure('VPN_SYSTEM_REVOKED', 'stale replacement')
      });
      expect(staleApplied).assertFalse();
      expect(events.length).assertEqual(eventCountBeforeStale);
      expect(registry.snapshot().state).assertEqual('RUNNING');

      const completed = registry.completeStop('session-1');
      expect(completed).assertTrue();
      expect(registry.snapshot().state).assertEqual('STOPPED');

      const lateUpdateApplied = registry.publish({
        sessionId: 'session-1',
        state: 'RUNNING',
        notificationActive: true
      });
      expect(lateUpdateApplied).assertFalse();
      expect(registry.snapshot().state).assertEqual('STOPPED');
    });
  });
}
