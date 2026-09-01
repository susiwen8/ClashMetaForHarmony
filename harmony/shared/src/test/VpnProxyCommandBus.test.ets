import { describe, expect, it } from '@ohos/hypium';
import {
  VpnProxyCommandBus,
  createProxyDelaySnapshotResultFromCoreSnapshot,
  createProxyGroupListQuerySnapshot,
  createProxyGroupQuerySnapshot,
  createProxyGroupSnapshot,
  createProxyRuntimeIdentity,
  createProxySelectionRecord,
  createProxySelectionSavedForNextStartResult,
  createVpnProxyCancelDelayTestCommand,
  createVpnProxyQueryGroupCommand,
  createVpnProxyQueryGroupsCommand,
  createVpnProxyReadDelayTestCommand,
  createVpnProxyStartDelayTestCommand,
  createVpnProxySelectCommand,
  type CoreProxyDelaySnapshot,
  type CoreProxyGroupRef,
  type CoreProxyGroupSnapshot,
  type ProxyDelayResult,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyRuntimeIdentity,
  type ProxySelectionResult,
  type VpnProxyCancelDelayTestCommand,
  type VpnProxyCommandHandler,
  type VpnProxyReadDelayTestCommand,
  type VpnProxyQueryGroupCommand,
  type VpnProxyQueryGroupsCommand,
  type VpnProxyStartDelayTestCommand,
  type VpnProxySelectCommand
} from '../../Index';
import { createDeferred, expectThrowsMessage, type Deferred } from './fakes/ProfileFakes';

const NOW_TIMESTAMP: string = '2026-08-22T09:00:00.000Z';
const NEXT_TIMESTAMP: string = '2026-08-22T09:00:01.000Z';
const REVISION_ID_A: string = '2026-08-22T08:00:00.000Z';
const REVISION_ID_B: string = '2026-08-22T08:30:00.000Z';
const REVISION_HASH_A: string = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const REVISION_HASH_B: string = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

class ScriptedHandler implements VpnProxyCommandHandler {
  readonly queryGroupsInputs: VpnProxyQueryGroupsCommand[] = [];
  readonly queryGroupInputs: VpnProxyQueryGroupCommand[] = [];
  readonly selectInputs: VpnProxySelectCommand[] = [];
  readonly startDelayInputs: VpnProxyStartDelayTestCommand[] = [];
  readonly readDelayInputs: VpnProxyReadDelayTestCommand[] = [];
  readonly cancelDelayInputs: VpnProxyCancelDelayTestCommand[] = [];
  queryGroupsHook?: (
    command: VpnProxyQueryGroupsCommand,
    callIndex: number
  ) => Promise<ProxyGroupListQueryResult>;
  queryGroupHook?: (
    command: VpnProxyQueryGroupCommand,
    callIndex: number
  ) => Promise<ProxyGroupQueryResult>;
  selectHook?: (
    command: VpnProxySelectCommand,
    callIndex: number
  ) => Promise<ProxySelectionResult>;
  startDelayHook?: (
    command: VpnProxyStartDelayTestCommand,
    callIndex: number
  ) => Promise<ProxyDelayResult>;
  readDelayHook?: (
    command: VpnProxyReadDelayTestCommand,
    callIndex: number
  ) => Promise<ProxyDelayResult>;
  cancelDelayHook?: (
    command: VpnProxyCancelDelayTestCommand,
    callIndex: number
  ) => Promise<ProxyDelayResult>;

  async queryGroups(command: VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult> {
    this.queryGroupsInputs.push(command);
    if (this.queryGroupsHook !== undefined) {
      return await this.queryGroupsHook(command, this.queryGroupsInputs.length);
    }
    return buildQueryGroupsResult(command.identity, command.generation, command.selectableOnly ? 'Selectable' : 'All');
  }

  async queryGroup(command: VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult> {
    this.queryGroupInputs.push(command);
    if (this.queryGroupHook !== undefined) {
      return await this.queryGroupHook(command, this.queryGroupInputs.length);
    }
    return buildQueryGroupResult(command.identity, command.generation, command.groupName);
  }

  async select(command: VpnProxySelectCommand): Promise<ProxySelectionResult> {
    this.selectInputs.push(command);
    if (this.selectHook !== undefined) {
      return await this.selectHook(command, this.selectInputs.length);
    }
    return buildSelectResult(command.identity, command.groupName, command.memberName);
  }

  async startDelayTest(command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> {
    this.startDelayInputs.push(command);
    if (this.startDelayHook !== undefined) {
      return await this.startDelayHook(command, this.startDelayInputs.length);
    }
    return buildDelayResult(command.identity, command.generation, command.groupName, 'delay-job-1', 'RUNNING');
  }

  async readDelayTest(command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> {
    this.readDelayInputs.push(command);
    if (this.readDelayHook !== undefined) {
      return await this.readDelayHook(command, this.readDelayInputs.length);
    }
    return buildDelayResult(command.identity, command.generation, 'GroupA', command.jobId, 'RUNNING');
  }

  async cancelDelayTest(command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> {
    this.cancelDelayInputs.push(command);
    if (this.cancelDelayHook !== undefined) {
      return await this.cancelDelayHook(command, this.cancelDelayInputs.length);
    }
    return buildDelayResult(command.identity, command.generation, 'GroupA', command.jobId, 'CANCELLED');
  }
}

function buildIdentity(
  sessionId: string | null,
  profileId: string = 'profile-1',
  revisionId: string = REVISION_ID_A,
  revisionHash: string = REVISION_HASH_A
): ProxyRuntimeIdentity {
  return createProxyRuntimeIdentity(profileId, revisionId, revisionHash, sessionId);
}

function buildGroupRefs(groupName: string): CoreProxyGroupRef[] {
  return [
    {
      name: groupName,
      type: 'Selector'
    }
  ];
}

function buildGroupSnapshot(groupName: string, selectedNodeName: string): CoreProxyGroupSnapshot {
  return {
    name: groupName,
    type: 'Selector',
    selectedName: selectedNodeName,
    nodes: [
      {
        name: selectedNodeName,
        type: 'Shadowsocks',
        isGroup: false,
        selected: true
      }
    ]
  };
}

function buildQueryGroupsResult(
  identity: ProxyRuntimeIdentity,
  generation: number,
  groupName: string = 'GroupA'
): ProxyGroupListQueryResult {
  return createProxyGroupListQuerySnapshot(identity, generation, buildGroupRefs(groupName));
}

function buildQueryGroupResult(
  identity: ProxyRuntimeIdentity,
  generation: number,
  groupName: string = 'GroupA',
  selectedNodeName: string = 'NodeA'
): ProxyGroupQueryResult {
  return createProxyGroupQuerySnapshot(
    createProxyGroupSnapshot(identity, generation, buildGroupSnapshot(groupName, selectedNodeName))
  );
}

function buildSelectResult(
  identity: ProxyRuntimeIdentity,
  groupName: string = 'GroupA',
  memberName: string = 'NodeA'
): ProxySelectionResult {
  return createProxySelectionSavedForNextStartResult(
    createProxySelectionRecord(identity.profileId, groupName, memberName, identity.revisionId, NOW_TIMESTAMP),
    NOW_TIMESTAMP
  );
}

function buildCoreDelaySnapshot(
  generation: number,
  groupName: string,
  jobId: string,
  state: 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED'
): CoreProxyDelaySnapshot {
  const trailingState: 'TESTING' | 'TIMEOUT' | 'CANCELLED' | 'FAILED' = state === 'RUNNING'
    ? 'TESTING'
    : state === 'COMPLETED'
      ? 'TIMEOUT'
      : state === 'CANCELLED'
        ? 'CANCELLED'
        : 'FAILED';
  return {
    schemaVersion: '1.0.0',
    jobId,
    state,
    profileHash: REVISION_HASH_A,
    revisionHash: REVISION_HASH_A,
    sessionHash: REVISION_HASH_B,
    generation,
    groupName,
    totalCount: 2,
    testableCount: 2,
    completedCount: state === 'RUNNING' ? 1 : 2,
    availableCount: 1,
    timeoutCount: trailingState === 'TIMEOUT' ? 1 : 0,
    failedCount: trailingState === 'FAILED' ? 1 : 0,
    cancelledCount: trailingState === 'CANCELLED' ? 1 : 0,
    unsupportedCount: 0,
    fastestNodeIndex: 0,
    nodes: [
      {
        index: 0,
        name: 'NodeA',
        type: 'Trojan',
        state: 'AVAILABLE',
        delayMs: 48,
        source: 'PROVIDER',
        fastest: true
      },
      {
        index: 1,
        name: 'NodeB',
        type: 'Shadowsocks',
        state: trailingState,
        delayMs: null,
        source: null,
        fastest: false
      }
    ]
  };
}

function buildDelayResult(
  identity: ProxyRuntimeIdentity,
  generation: number,
  groupName: string,
  jobId: string,
  state: 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED'
): ProxyDelayResult {
  return createProxyDelaySnapshotResultFromCoreSnapshot(
    identity,
    generation,
    groupName,
    buildCoreDelaySnapshot(generation, groupName, jobId, state)
  );
}

function expectRejected(
  result: ProxyGroupListQueryResult | ProxyGroupQueryResult | ProxySelectionResult | ProxyDelayResult,
  code: string,
  timestamp: string
): void {
  expect(result.kind).assertEqual('REJECTED');
  if (result.kind !== 'REJECTED') {
    throw new Error(`Expected rejected result but received ${result.kind}.`);
  }
  expect(result.error.code).assertEqual(code);
  expect(result.error.timestamp).assertEqual(timestamp);
}

function expectNoFragments(message: string, fragments: string[]): void {
  for (let index: number = 0; index < fragments.length; index += 1) {
    expect(message.includes(fragments[index])).assertFalse();
  }
}

function createBus(now: () => string = () => NOW_TIMESTAMP, initialEpoch?: number): VpnProxyCommandBus {
  if (initialEpoch === undefined) {
    return new VpnProxyCommandBus(now);
  }
  return new VpnProxyCommandBus(now, initialEpoch);
}

export default function vpnProxyCommandBusTestsuite() {
  describe('VpnProxyCommandBusTest', () => {
    it('bindsOneSessionAndDispatchesAllThreeCommandShapes', 0, async () => {
      const bus = createBus();
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');

      const generation = bus.bind(identity, handler);
      const groupsResult = await bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, true)
      );
      const groupResult = await bus.submitQueryGroup(
        createVpnProxyQueryGroupCommand(identity, generation, 'GroupA')
      );
      const selectionResult = await bus.submitSelect(
        createVpnProxySelectCommand(identity, generation, 'GroupA', 'NodeA')
      );

      expect(generation).assertEqual(1);
      expect(handler.queryGroupsInputs.length).assertEqual(1);
      expect(handler.queryGroupInputs.length).assertEqual(1);
      expect(handler.selectInputs.length).assertEqual(1);
      expect(handler.queryGroupsInputs[0].selectableOnly).assertTrue();
      expect(handler.queryGroupInputs[0].groupName).assertEqual('GroupA');
      expect(handler.selectInputs[0].memberName).assertEqual('NodeA');
      expect(groupsResult.kind).assertEqual('SNAPSHOT');
      expect(groupResult.kind).assertEqual('SNAPSHOT');
      expect(selectionResult.kind).assertEqual('SAVED_FOR_NEXT_START');
    });

    it('exposesAuthoritativeSessionGenerationOnlyForTheExactActiveBinding', 0, () => {
      const bus = createBus();
      const identity = buildIdentity('session-1');

      bus.bind(identity, new ScriptedHandler(), 7);

      expect(bus.activeSessionGeneration(identity) ?? 0).assertEqual(7);
      expect(bus.activeSessionGeneration(buildIdentity('session-2')) === undefined).assertTrue();
      bus.invalidate('session-1');
      expect(bus.activeSessionGeneration(identity) === undefined).assertTrue();
    });

    it('rejectsInvalidAuthoritativeSessionGenerationWithoutConsumingTheBindingEpoch', 0, () => {
      const bus = createBus();
      const identity = buildIdentity('session-1');

      expectThrowsMessage(() => {
        bus.bind(identity, new ScriptedHandler(), 0);
      }, 'must be positive');

      const epoch = bus.bind(identity, new ScriptedHandler(), 3);
      expect(epoch).assertEqual(1);
      expect(bus.activeSessionGeneration(identity) ?? 0).assertEqual(3);
    });

    it('rejectsDuplicateLiveBindWithoutReplacingActiveHandler', 0, async () => {
      const bus = createBus();
      const originalHandler = new ScriptedHandler();
      const originalIdentity = buildIdentity('session-1');
      const duplicateIdentity = buildIdentity('session-2', 'profile-2', REVISION_ID_B, REVISION_HASH_B);

      const generation = bus.bind(originalIdentity, originalHandler);

      let thrownMessage: string = '';
      try {
        bus.bind(duplicateIdentity, new ScriptedHandler());
      } catch (error) {
        thrownMessage = error instanceof Error ? error.message : `${error}`;
      }

      const result = await bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(originalIdentity, generation, false)
      );

      expect(thrownMessage.length > 0).assertTrue();
      expectNoFragments(thrownMessage, ['profile-2', 'session-2', REVISION_ID_B]);
      expect(originalHandler.queryGroupsInputs.length).assertEqual(1);
      expect(result.kind).assertEqual('SNAPSHOT');
    });

    it('rejectsUnboundAndExactIdentityMismatchCommandsWithoutInvokingHandler', 0, async () => {
      const boundBus = createBus(() => NEXT_TIMESTAMP);
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const bindingEpoch = boundBus.bind(identity, handler);
      const unboundBus = createBus();

      const unboundResult = await unboundBus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, 99, false)
      );
      const profileMismatchResult = await boundBus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(buildIdentity('session-1', 'profile-2'), 11, false)
      );
      const revisionMismatchResult = await boundBus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(
          buildIdentity('session-1', 'profile-1', REVISION_ID_B, REVISION_HASH_A),
          12,
          false
        )
      );
      const revisionHashMismatchResult = await boundBus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(
          buildIdentity('session-1', 'profile-1', REVISION_ID_A, REVISION_HASH_B),
          13,
          false
        )
      );
      const sessionMismatchResult = await boundBus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(buildIdentity('session-2'), 14, false)
      );

      expectRejected(unboundResult, 'VPN_SESSION_CHANGED', NOW_TIMESTAMP);
      expectRejected(profileMismatchResult, 'VPN_SESSION_CHANGED', NEXT_TIMESTAMP);
      expectRejected(revisionMismatchResult, 'VPN_SESSION_CHANGED', NEXT_TIMESTAMP);
      expectRejected(revisionHashMismatchResult, 'VPN_SESSION_CHANGED', NEXT_TIMESTAMP);
      expectRejected(sessionMismatchResult, 'VPN_SESSION_CHANGED', NEXT_TIMESTAMP);
      expect(bindingEpoch).assertEqual(1);
      expect(handler.queryGroupsInputs.length).assertEqual(0);
    });

    it('passesArbitraryExactGenerationValuesToHandlersUnchanged', 0, async () => {
      const bus = createBus();
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const bindingEpoch = bus.bind(identity, handler);

      const groupsGeneration = 42;
      const groupGeneration = Number.MAX_SAFE_INTEGER;
      const selectGeneration = 777;

      const groupsResult = await bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, groupsGeneration, false)
      );
      const groupResult = await bus.submitQueryGroup(
        createVpnProxyQueryGroupCommand(identity, groupGeneration, 'GroupA')
      );
      const selectResult = await bus.submitSelect(
        createVpnProxySelectCommand(identity, selectGeneration, 'GroupA', 'NodeA')
      );

      expect(bindingEpoch).assertEqual(1);
      expect(handler.queryGroupsInputs[0].generation).assertEqual(groupsGeneration);
      expect(handler.queryGroupInputs[0].generation).assertEqual(groupGeneration);
      expect(handler.selectInputs[0].generation).assertEqual(selectGeneration);
      expect(groupsResult.kind).assertEqual('SNAPSHOT');
      expect(groupResult.kind).assertEqual('SNAPSHOT');
      expect(selectResult.kind).assertEqual('SAVED_FOR_NEXT_START');
    });

    it('dispatchesDelayStartReadAndCancelCommandsThroughTheSharedSerialBus', 0, async () => {
      const bus = createBus();
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const generation = bus.bind(identity, handler);

      const started = await bus.submitStartDelayTest(
        createVpnProxyStartDelayTestCommand(identity, generation, 'GroupA')
      );
      const read = await bus.submitReadDelayTest(
        createVpnProxyReadDelayTestCommand(identity, generation + 1, 'delay-job-1')
      );
      const cancelled = await bus.submitCancelDelayTest(
        createVpnProxyCancelDelayTestCommand(identity, generation + 2, 'delay-job-1')
      );

      expect(handler.startDelayInputs.length).assertEqual(1);
      expect(handler.readDelayInputs.length).assertEqual(1);
      expect(handler.cancelDelayInputs.length).assertEqual(1);
      expect(handler.startDelayInputs[0].groupName).assertEqual('GroupA');
      expect(handler.readDelayInputs[0].jobId).assertEqual('delay-job-1');
      expect(handler.cancelDelayInputs[0].jobId).assertEqual('delay-job-1');
      expect(started.kind).assertEqual('SNAPSHOT');
      expect(read.kind).assertEqual('SNAPSHOT');
      expect(cancelled.kind).assertEqual('SNAPSHOT');
    });

    it('mapsDelayHandlerFailuresAndCapturedBindingInvalidationToClosedRejectedResults', 0, async () => {
      const bus = createBus();
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const generation = bus.bind(identity, handler);

      handler.startDelayHook = async (_command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> => {
        throw new Error('raw delay failure');
      };
      const failed = await bus.submitStartDelayTest(
        createVpnProxyStartDelayTestCommand(identity, generation, 'GroupA')
      );

      handler.readDelayHook = async (command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> => {
        bus.invalidate(identity.sessionId!);
        return buildDelayResult(command.identity, command.generation, 'GroupA', command.jobId, 'RUNNING');
      };
      const stale = await bus.submitReadDelayTest(
        createVpnProxyReadDelayTestCommand(identity, generation + 1, 'delay-job-1')
      );

      expectRejected(failed, 'PROXY_DELAY_TEST_FAILED', NOW_TIMESTAMP);
      expectRejected(stale, 'VPN_SESSION_CHANGED', NOW_TIMESTAMP);
    });

    it('serializesConcurrentCommandsWithoutStartingTheNextHandlerEarly', 0, async () => {
      const bus = createBus();
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const generation = bus.bind(identity, handler);
      const firstStarted: Deferred<void> = createDeferred<void>();
      const releaseFirst: Deferred<void> = createDeferred<void>();
      let secondStarted: boolean = false;

      handler.queryGroupsHook = async (command: VpnProxyQueryGroupsCommand, callIndex: number) => {
        if (callIndex === 1) {
          firstStarted.resolve();
          await releaseFirst.promise;
          return buildQueryGroupsResult(command.identity, command.generation, 'First');
        }
        secondStarted = true;
        return buildQueryGroupsResult(command.identity, command.generation, 'Second');
      };

      const firstPromise = bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, false)
      );
      const secondPromise = bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, true)
      );

      await firstStarted.promise;
      await Promise.resolve();
      expect(secondStarted).assertFalse();

      releaseFirst.resolve();

      const firstResult = await firstPromise;
      const secondResult = await secondPromise;
      expect(secondStarted).assertTrue();
      expect(firstResult.kind).assertEqual('SNAPSHOT');
      expect(secondResult.kind).assertEqual('SNAPSHOT');
    });

    it('invalidatesQueuedAndInFlightCommandsForTheExactSession', 0, async () => {
      const bus = createBus();
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const generation = bus.bind(identity, handler);
      const firstStarted: Deferred<void> = createDeferred<void>();
      const releaseFirst: Deferred<void> = createDeferred<void>();

      handler.queryGroupsHook = async (command: VpnProxyQueryGroupsCommand, callIndex: number) => {
        if (callIndex === 1) {
          firstStarted.resolve();
          await releaseFirst.promise;
        }
        return buildQueryGroupsResult(command.identity, command.generation, `Group-${callIndex}`);
      };

      const firstPromise = bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, false)
      );
      const secondPromise = bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, true)
      );

      await firstStarted.promise;
      bus.invalidate('session-1');
      releaseFirst.resolve();

      const firstResult = await firstPromise;
      const secondResult = await secondPromise;

      expectRejected(firstResult, 'VPN_SESSION_CHANGED', NOW_TIMESTAMP);
      expectRejected(secondResult, 'VPN_SESSION_CHANGED', NOW_TIMESTAMP);
      expect(handler.queryGroupsInputs.length).assertEqual(1);
    });

    it('awaitsDeactivateUntilQueuedAndRunningCommandsDrain', 0, async () => {
      const bus = createBus();
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const generation = bus.bind(identity, handler);
      const firstStarted: Deferred<void> = createDeferred<void>();
      const releaseFirst: Deferred<void> = createDeferred<void>();
      let deactivateResolved: boolean = false;

      handler.queryGroupsHook = async (command: VpnProxyQueryGroupsCommand, callIndex: number) => {
        if (callIndex === 1) {
          firstStarted.resolve();
          await releaseFirst.promise;
        }
        return buildQueryGroupsResult(command.identity, command.generation, `Queued-${callIndex}`);
      };

      const firstPromise = bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, false)
      );
      const secondPromise = bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, true)
      );

      await firstStarted.promise;
      const deactivatePromise = bus.deactivate('session-1').then(() => {
        deactivateResolved = true;
      });

      await Promise.resolve();
      expect(deactivateResolved).assertFalse();

      releaseFirst.resolve();

      const firstResult = await firstPromise;
      const secondResult = await secondPromise;
      await deactivatePromise;

      expectRejected(firstResult, 'VPN_SESSION_CHANGED', NOW_TIMESTAMP);
      expectRejected(secondResult, 'VPN_SESSION_CHANGED', NOW_TIMESTAMP);
      expect(deactivateResolved).assertTrue();
      expect(handler.queryGroupsInputs.length).assertEqual(1);
    });

    it('keepsActiveBindingWhenInvalidateReceivesAnotherSessionId', 0, async () => {
      const bus = createBus();
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const generation = bus.bind(identity, handler);

      bus.invalidate('session-2');

      const result = await bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, false)
      );

      expect(handler.queryGroupsInputs.length).assertEqual(1);
      expect(result.kind).assertEqual('SNAPSHOT');
    });

    it('rebindsLaterSessionsOnANewerEpochAndRejectsOldCommands', 0, async () => {
      const bus = createBus();
      const firstHandler = new ScriptedHandler();
      const secondHandler = new ScriptedHandler();
      const firstIdentity = buildIdentity('session-1');
      const firstGeneration = bus.bind(firstIdentity, firstHandler);

      bus.invalidate('session-1');

      const secondIdentity = buildIdentity('session-2', 'profile-2', REVISION_ID_B, REVISION_HASH_B);
      const secondGeneration = bus.bind(secondIdentity, secondHandler);
      const staleResult = await bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(firstIdentity, firstGeneration, false)
      );
      const currentResult = await bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(secondIdentity, secondGeneration, false)
      );

      expect(firstGeneration).assertEqual(1);
      expect(secondGeneration).assertEqual(3);
      expectRejected(staleResult, 'VPN_SESSION_CHANGED', NOW_TIMESTAMP);
      expect(currentResult.kind).assertEqual('SNAPSHOT');
      expect(firstHandler.queryGroupsInputs.length).assertEqual(0);
      expect(secondHandler.queryGroupsInputs.length).assertEqual(1);
    });

    it('rejectsQueuedCommandsCapturedUnderAnOldEpochEvenWhenGenerationMatchesTheNewEpoch', 0, async () => {
      const bus = createBus(() => NEXT_TIMESTAMP, 41);
      const firstHandler = new ScriptedHandler();
      const secondHandler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const firstBindingEpoch = bus.bind(identity, firstHandler);
      const firstStarted: Deferred<void> = createDeferred<void>();
      const releaseFirst: Deferred<void> = createDeferred<void>();

      firstHandler.queryGroupsHook = async (command: VpnProxyQueryGroupsCommand, callIndex: number) => {
        if (callIndex === 1) {
          firstStarted.resolve();
          await releaseFirst.promise;
        }
        return buildQueryGroupsResult(command.identity, command.generation, `Old-${callIndex}`);
      };

      const firstPromise = bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, 42, false)
      );
      const staleQueuedPromise = bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, 44, true)
      );

      await firstStarted.promise;
      bus.invalidate('session-1');
      const reboundEpoch = bus.bind(identity, secondHandler);
      releaseFirst.resolve();

      const staleQueuedResult = await staleQueuedPromise;
      const reboundResult = await bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, 44, false)
      );
      await firstPromise;

      expect(firstBindingEpoch).assertEqual(42);
      expect(reboundEpoch).assertEqual(44);
      expect(firstHandler.queryGroupsInputs.length).assertEqual(1);
      expect(secondHandler.queryGroupsInputs.length).assertEqual(1);
      expectRejected(staleQueuedResult, 'VPN_SESSION_CHANGED', NEXT_TIMESTAMP);
      expect(reboundResult.kind).assertEqual('SNAPSHOT');
    });

    it('mapsHandlerThrowsToSanitizedAllowlistedErrors', 0, async () => {
      const bus = createBus(() => NEXT_TIMESTAMP);
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const generation = bus.bind(identity, handler);

      handler.queryGroupsHook = async (_command: VpnProxyQueryGroupsCommand) => {
        throw new Error('query exploded for GroupA session-1 token=secret');
      };
      handler.selectHook = async (_command: VpnProxySelectCommand) => {
        throw new Error('select exploded for NodeA session-1 token=secret');
      };

      const queryResult = await bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, false)
      );
      const selectResult = await bus.submitSelect(
        createVpnProxySelectCommand(identity, generation, 'GroupA', 'NodeA')
      );

      expectRejected(queryResult, 'PROXY_QUERY_FAILED', NEXT_TIMESTAMP);
      expectRejected(selectResult, 'PROXY_SELECTION_FAILED', NEXT_TIMESTAMP);
      expectNoFragments(JSON.stringify(queryResult), ['GroupA', 'session-1', 'secret']);
      expectNoFragments(JSON.stringify(selectResult), ['NodeA', 'session-1', 'secret']);
    });

    it('clonesHandlerResultsBeforeReturningThem', 0, async () => {
      const bus = createBus();
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const generation = bus.bind(identity, handler);
      const sourceResult = buildQueryGroupsResult(identity, generation, 'Mutable');

      handler.queryGroupsHook = async (_command: VpnProxyQueryGroupsCommand) => sourceResult;

      const result = await bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, false)
      );

      if (sourceResult.kind === 'SNAPSHOT') {
        sourceResult.groups[0].name = 'Mutated';
      }

      expect(result.kind).assertEqual('SNAPSHOT');
      if (result.kind === 'SNAPSHOT') {
        expect(result.groups[0].name).assertEqual('Mutable');
      }
    });

    it('clonesSubmittedCommandsImmediatelyBeforeQueueExecution', 0, async () => {
      const bus = createBus();
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const generation = bus.bind(identity, handler);
      const started: Deferred<void> = createDeferred<void>();
      const release: Deferred<void> = createDeferred<void>();
      const command = createVpnProxyQueryGroupsCommand(identity, generation, false);

      handler.queryGroupsHook = async (received: VpnProxyQueryGroupsCommand) => {
        started.resolve();
        await release.promise;
        return buildQueryGroupsResult(received.identity, received.generation, received.selectableOnly ? 'Selectable' : 'Original');
      };

      const resultPromise = bus.submitQueryGroups(command);
      command.identity.profileId = 'profile-9';
      command.identity.revisionId = REVISION_ID_B;
      command.identity.revisionHash = REVISION_HASH_B;
      command.identity.sessionId = 'session-9';
      command.generation = generation + 9;
      command.selectableOnly = true;

      await started.promise;

      expect(handler.queryGroupsInputs[0].identity.profileId).assertEqual('profile-1');
      expect(handler.queryGroupsInputs[0].identity.revisionId).assertEqual(REVISION_ID_A);
      expect(handler.queryGroupsInputs[0].identity.revisionHash).assertEqual(REVISION_HASH_A);
      expect(handler.queryGroupsInputs[0].identity.sessionId).assertEqual('session-1');
      expect(handler.queryGroupsInputs[0].generation).assertEqual(generation);
      expect(handler.queryGroupsInputs[0].selectableOnly).assertFalse();

      release.resolve();
      await resultPromise;
    });

    it('validatesCommandNamesGenerationAndRunningSessionAtSubmissionBoundary', 0, async () => {
      const bus = createBus();
      const unboundBus = createBus();
      const handler = new ScriptedHandler();
      const generation = bus.bind(buildIdentity('session-1'), handler);

      expectThrowsMessage(() => {
        unboundBus.bind({
          profileId: 'profile-1',
          revisionId: REVISION_ID_A,
          revisionHash: REVISION_HASH_A,
          sessionId: ' session-2 '
        }, new ScriptedHandler());
      }, 'leading or trailing whitespace');
      expectThrowsMessage(() => {
        bus.submitQueryGroup({
          identity: buildIdentity('session-1'),
          generation,
          groupName: '   '
        });
      }, 'must not be blank');
      expectThrowsMessage(() => {
        bus.submitQueryGroups({
          identity: buildIdentity('session-1'),
          generation: 0,
          selectableOnly: false
        });
      }, 'safe positive integer');
      expectThrowsMessage(() => {
        bus.submitQueryGroups({
          identity: {
            profileId: ' profile-1 ',
            revisionId: REVISION_ID_A,
            revisionHash: REVISION_HASH_A,
            sessionId: 'session-1'
          },
          generation,
          selectableOnly: false
        });
      }, 'leading or trailing whitespace');
      expectThrowsMessage(() => {
        bus.submitQueryGroups({
          identity: {
            profileId: 'profile-1',
            revisionId: REVISION_ID_A,
            revisionHash: REVISION_HASH_A,
            sessionId: ' session-1 '
          },
          generation,
          selectableOnly: false
        });
      }, 'leading or trailing whitespace');
      expectThrowsMessage(() => {
        bus.submitSelect({
          identity: {
            profileId: 'profile-1',
            revisionId: REVISION_ID_A,
            revisionHash: REVISION_HASH_A,
            sessionId: null
          },
          generation,
          groupName: 'GroupA',
          memberName: 'NodeA'
        });
      }, 'non-null running session identity');
      expect(handler.queryGroupsInputs.length).assertEqual(0);
    });

    it('doesNotLeakRawIdentityFragmentsThroughThrownOrRejectedErrors', 0, async () => {
      const bus = createBus(() => NEXT_TIMESTAMP);
      const identity = buildIdentity('session-1', 'profile-sensitive');
      const generation = bus.bind(identity, new ScriptedHandler());
      const unboundBus = createBus(() => NEXT_TIMESTAMP);

      const rejected = await unboundBus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, false)
      );

      let thrownMessage: string = '';
      try {
        bus.bind(buildIdentity('session-2', 'profile-2'), new ScriptedHandler());
      } catch (error) {
        thrownMessage = error instanceof Error ? error.message : `${error}`;
      }

      expectRejected(rejected, 'VPN_SESSION_CHANGED', NEXT_TIMESTAMP);
      expectNoFragments(JSON.stringify(rejected), ['profile-sensitive', 'session-1', REVISION_HASH_A]);
      expect(thrownMessage.length > 0).assertTrue();
      expectNoFragments(thrownMessage, ['profile-sensitive', 'session-1', REVISION_HASH_A]);
    });

    it('supportsExplicitDeactivateOfAnAlreadyDrainedQueue', 0, async () => {
      const bus = createBus();
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const generation = bus.bind(identity, handler);

      await bus.deactivate('session-2');

      const result = await bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, false)
      );

      expect(result.kind).assertEqual('SNAPSHOT');
    });

    it('keepsReturnedPromisesRejectedWhenHandlerThrowsAfterAQueuedDeactivate', 0, async () => {
      const bus = createBus(() => NEXT_TIMESTAMP);
      const handler = new ScriptedHandler();
      const identity = buildIdentity('session-1');
      const generation = bus.bind(identity, handler);
      const started: Deferred<void> = createDeferred<void>();
      const release: Deferred<void> = createDeferred<void>();

      handler.queryGroupsHook = async (_command: VpnProxyQueryGroupsCommand) => {
        started.resolve();
        await release.promise;
        throw new Error('late explosion');
      };

      const resultPromise = bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(identity, generation, false)
      );
      await started.promise;
      const deactivatePromise = bus.deactivate('session-1');
      release.resolve();

      const result = await resultPromise;
      await deactivatePromise;

      expectRejected(result, 'VPN_SESSION_CHANGED', NEXT_TIMESTAMP);
    });

    it('validatesInitialEpochSeamAndSealsAtMaxSafeIntegerWithoutWrapping', 0, () => {
      expectThrowsMessage(() => {
        createBus(() => NOW_TIMESTAMP, -1);
      }, 'safe non-negative integer');
      expectThrowsMessage(() => {
        createBus(() => NOW_TIMESTAMP, 1.5);
      }, 'safe non-negative integer');
      expectThrowsMessage(() => {
        createBus(() => NOW_TIMESTAMP, Number.MAX_SAFE_INTEGER + 1);
      }, 'safe non-negative integer');

      const bus = createBus(() => NOW_TIMESTAMP, Number.MAX_SAFE_INTEGER - 1);
      const epoch = bus.bind(buildIdentity('session-1'), new ScriptedHandler());

      expect(epoch).assertEqual(Number.MAX_SAFE_INTEGER);
      bus.invalidate('session-1');
      expectThrowsMessage(() => {
        bus.bind(buildIdentity('session-2'), new ScriptedHandler());
      }, 'cannot allocate another binding');
    });

  });
}
