import { describe, expect, it } from '@ohos/hypium';
import {
  CORE_PROXY_DELAY_SCHEMA_VERSION,
  cloneCoreProxyDelayNodeResult,
  cloneCoreProxyDelaySnapshot,
  createActiveProxyProfile,
  createProxyGroupListQuerySnapshot,
  createProxyDelaySnapshotResultFromCoreSnapshot,
  createProxyGroupQuerySnapshot,
  createProxyGroupSnapshot,
  createProxyRejectedError,
  createProxyRejectedResult,
  createProxyReconcileResult,
  createProxyDelayNodeResult,
  createProxyRuntimeIdentity,
  createProxySelectionAppliedNotPersistedResult,
  createProxySelectionAppliedNowResult,
  createProxySelectionRecord,
  createProxySelectionSavedForNextStartResult,
  createVpnProxyCancelDelayTestCommand,
  createVpnProxyQueryGroupCommand,
  createVpnProxyQueryGroupsCommand,
  createVpnProxyReadDelayTestCommand,
  createVpnProxyStartDelayTestCommand,
  createVpnProxySelectCommand,
  listCoreProxyDelayJobStates,
  listCoreProxyDelayNodeStates,
  listCoreProxyDelayURLSources,
  normalizeProxyDelayJobId,
  listProxyRejectedErrorCodes,
  listProxySelectionResultKinds,
  type ActiveProfileProxyPort,
  type ActiveProxyProfile,
  type CoreProxyDelayNodeResult,
  type CoreProxyDelaySnapshot,
  type CoreProxyPort,
  type CoreProxyQueryContext,
  type CoreProxyGroupList,
  type CoreProxyGroupResult,
  type CoreProxySelectionApplied,
  type CoreProxyGroupSnapshot,
  type CoreProxyGroupRef,
  type ProxyApplicationPort,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyIdentityHasher,
  type ProxyRejectedError,
  type ProxyRejectedResult,
  type ProxyDelaySnapshotResult,
  type ProxyReconcileResult,
  type ProxyRuntimeIdentity,
  type ProxySelectionRecord,
  type ProxySelectionRepository,
  type ProxySelectionResult,
  type VpnProxyCancelDelayTestCommand,
  type VpnProxyCommandHandler,
  type VpnProxyReadDelayTestCommand,
  type VpnProxyQueryGroupCommand,
  type VpnProxyQueryGroupsCommand,
  type VpnProxyRuntimeLifecyclePort,
  type VpnProxyStartDelayTestCommand,
  type VpnProxySelectCommand,
  type VpnStartRequest,
  type VpnStoppedProxyLease,
  type VpnRuntimeSnapshot,
  type VpnRuntimeSnapshotPort
} from '../../Index';
import { expectThrowsMessage } from './fakes/ProfileFakes';

const CANONICAL_TIMESTAMP: string = '2026-08-07T00:00:00.000Z';
const SECOND_TIMESTAMP: string = '2026-08-07T01:00:00.000Z';
const REVISION_HASH: string = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const PROFILE_HASH: string = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

interface ReconcilePair {
  groupName: string;
  selectedNodeName: string;
}

class FakeActiveProfilePort implements ActiveProfileProxyPort {
  async resolve(): Promise<ActiveProxyProfile | undefined> {
    return createActiveProxyProfile('profile-1', CANONICAL_TIMESTAMP, REVISION_HASH, 'sandbox/profiles/current.yaml');
  }
}

class FakeCoreProxyPort implements CoreProxyPort {
  async loadConfiguration(_path: string): Promise<void> {
    return;
  }

  async queryProxyGroups(_context: CoreProxyQueryContext, _selectableOnly: boolean): Promise<CoreProxyGroupList> {
    return await Promise.reject(new Error('not implemented'));
  }

  async queryProxyGroup(_context: CoreProxyQueryContext, _groupName: string): Promise<CoreProxyGroupResult> {
    return await Promise.reject(new Error('not implemented'));
  }

  async selectProxy(
    _context: CoreProxyQueryContext,
    _groupName: string,
    _memberName: string
  ): Promise<CoreProxySelectionApplied> {
    return await Promise.reject(new Error('not implemented'));
  }

  async startProxyDelayTest(_context: CoreProxyQueryContext, _groupName: string): Promise<CoreProxyDelaySnapshot> {
    return await Promise.reject(new Error('not implemented'));
  }

  async readProxyDelayTest(_jobId: string): Promise<CoreProxyDelaySnapshot> {
    return await Promise.reject(new Error('not implemented'));
  }

  async cancelProxyDelayTest(_jobId: string): Promise<CoreProxyDelaySnapshot> {
    return await Promise.reject(new Error('not implemented'));
  }
}

class FakeSelectionRepository implements ProxySelectionRepository {
  async listByProfile(_profileId: string): Promise<ProxySelectionRecord[]> {
    return [];
  }

  async get(_profileId: string, _groupName: string): Promise<ProxySelectionRecord | undefined> {
    return undefined;
  }

  async upsert(_record: ProxySelectionRecord): Promise<void> {
    return;
  }

  async delete(_profileId: string, _groupName: string): Promise<void> {
    return;
  }

  async deleteProfile(_profileId: string): Promise<void> {
    return;
  }

  async reconcileProfile(
    _profileId: string,
    _newRevisionId: string,
    _validPairs: ReconcilePair[]
  ): Promise<void> {
    return;
  }
}

class FakeIdentityHasher implements ProxyIdentityHasher {
  async sha256(_value: string): Promise<string> {
    return REVISION_HASH;
  }
}

class FakeVpnRuntimeSnapshotPort implements VpnRuntimeSnapshotPort {
  snapshot(): VpnRuntimeSnapshot {
    return {
      state: 'STOPPED',
      activeRequest: null,
      activeHandle: null,
      captureConfig: null,
      tunSnapshot: null,
      notificationActive: false,
      recoveryAttempt: 0,
      scheduledRetryDelayMs: null,
      lastFailure: null
    };
  }

  acquireStoppedProxyLease(): VpnStoppedProxyLease | undefined {
    return undefined;
  }
}

class FakeVpnCommandHandler implements VpnProxyCommandHandler {
  async queryGroups(command: VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult> {
    return createProxyGroupListQuerySnapshot(command.identity, command.generation, buildGroupRefs());
  }

  async queryGroup(command: VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult> {
    return createProxyGroupQuerySnapshot(createProxyGroupSnapshot(command.identity, command.generation, buildGroupSnapshot()));
  }

  async select(command: VpnProxySelectCommand): Promise<ProxySelectionResult> {
    return createProxySelectionSavedForNextStartResult(
      createProxySelectionRecord(command.identity.profileId, command.groupName, command.memberName, command.identity.revisionId, CANONICAL_TIMESTAMP),
      CANONICAL_TIMESTAMP
    );
  }

  async startDelayTest(command: VpnProxyStartDelayTestCommand): Promise<ProxyDelaySnapshotResult> {
    return createProxyDelaySnapshotResultFromCoreSnapshot(
      command.identity,
      command.generation,
      'GroupA',
      buildDelaySnapshot()
    );
  }

  async readDelayTest(command: VpnProxyReadDelayTestCommand): Promise<ProxyDelaySnapshotResult> {
    return createProxyDelaySnapshotResultFromCoreSnapshot(
      command.identity,
      command.generation,
      'GroupA',
      buildDelaySnapshot()
    );
  }

  async cancelDelayTest(command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelaySnapshotResult> {
    const snapshot: CoreProxyDelaySnapshot = buildDelaySnapshot();
    snapshot.state = 'CANCELLED';
    snapshot.jobId = command.jobId;
    snapshot.generation = command.generation;
    return createProxyDelaySnapshotResultFromCoreSnapshot(command.identity, command.generation, 'GroupA', snapshot);
  }
}

class FakeVpnRuntimeLifecyclePort implements VpnProxyRuntimeLifecyclePort {
  async activate(_request: VpnStartRequest): Promise<void> {
    return;
  }

  invalidate(_sessionId: string): void {}

  async deactivate(_sessionId: string): Promise<void> {
    return;
  }

  async cancelAndDrainDelayTest(_sessionId: string): Promise<void> {
    return;
  }
}

class FakeProxyApplicationPort implements ProxyApplicationPort {
  async listGroups(): Promise<ProxyGroupListQueryResult> {
    return createProxyGroupListQuerySnapshot(buildRuntimeIdentity('session-1'), 7, buildGroupRefs());
  }

  async queryGroup(_groupName: string, _groupPath?: string[]): Promise<ProxyGroupQueryResult> {
    return createProxyGroupQuerySnapshot(createProxyGroupSnapshot(buildRuntimeIdentity('session-1'), 8, buildGroupSnapshot()));
  }

  async select(
    groupName: string,
    memberName: string,
    _snapshotGeneration: number,
    _groupPath?: string[]
  ): Promise<ProxySelectionResult> {
    return createProxySelectionSavedForNextStartResult(
      createProxySelectionRecord('profile-1', groupName, memberName, CANONICAL_TIMESTAMP, SECOND_TIMESTAMP),
      SECOND_TIMESTAMP
    );
  }

  async reconcileActiveSelections(): Promise<ProxyReconcileResult> {
    return createProxyReconcileResult(PROFILE_HASH, REVISION_HASH, 1, 0);
  }

  async startDelayTest(groupName: string, snapshotGeneration: number, _groupPath?: string[]): Promise<ProxyDelaySnapshotResult> {
    return createProxyDelaySnapshotResultFromCoreSnapshot(
      buildRuntimeIdentity('session-1'),
      snapshotGeneration,
      groupName,
      buildDelaySnapshot()
    );
  }

  async readDelayTest(jobId: string): Promise<ProxyDelaySnapshotResult> {
    const snapshot: CoreProxyDelaySnapshot = buildDelaySnapshot();
    snapshot.jobId = jobId;
    return createProxyDelaySnapshotResultFromCoreSnapshot(buildRuntimeIdentity('session-1'), snapshot.generation, 'GroupA', snapshot);
  }

  async cancelDelayTest(jobId: string): Promise<ProxyDelaySnapshotResult> {
    const snapshot: CoreProxyDelaySnapshot = buildDelaySnapshot();
    snapshot.jobId = jobId;
    snapshot.state = 'CANCELLED';
    return createProxyDelaySnapshotResultFromCoreSnapshot(buildRuntimeIdentity('session-1'), snapshot.generation, 'GroupA', snapshot);
  }

  async cancelAndDrainDelayTest(): Promise<ProxyRejectedResult | undefined> {
    return undefined;
  }
}

function buildGroupRefs(): CoreProxyGroupRef[] {
  return [
    {
      name: 'GroupA',
      type: 'Selector'
    }
  ];
}

function buildGroupSnapshot(): CoreProxyGroupSnapshot {
  return {
    name: 'GroupA',
    type: 'Selector',
    selectedName: 'NodeA',
    nodes: [
      {
        name: 'NodeA',
        type: 'Shadowsocks',
        isGroup: false,
        selected: true
      }
    ]
  };
}

function buildRuntimeIdentity(sessionId: string | null): ProxyRuntimeIdentity {
  return createProxyRuntimeIdentity('profile-1', CANONICAL_TIMESTAMP, REVISION_HASH, sessionId);
}

function buildDelayNode(
  index: number,
  name: string,
  state: 'WAITING' | 'TESTING' | 'AVAILABLE' | 'TIMEOUT' | 'FAILED' | 'CANCELLED' | 'UNSUPPORTED',
  delayMs: number | null,
  source: 'PROVIDER' | 'FALLBACK' | null,
  fastest: boolean
): CoreProxyDelayNodeResult {
  return {
    index,
    name,
    type: index === 0 ? 'URLTest' : 'Trojan',
    state,
    delayMs,
    source,
    fastest
  };
}

function buildDelaySnapshot(): CoreProxyDelaySnapshot {
  return {
    schemaVersion: CORE_PROXY_DELAY_SCHEMA_VERSION,
    jobId: '0123456789abcdef0123456789abcdef',
    state: 'COMPLETED',
    profileHash: PROFILE_HASH,
    revisionHash: REVISION_HASH,
    sessionHash: null,
    generation: 12,
    groupName: 'url-test',
    totalCount: 3,
    testableCount: 2,
    completedCount: 3,
    availableCount: 1,
    timeoutCount: 1,
    failedCount: 0,
    cancelledCount: 0,
    unsupportedCount: 1,
    fastestNodeIndex: 1,
    nodes: [
      buildDelayNode(0, 'unsupported', 'UNSUPPORTED', null, null, false),
      buildDelayNode(1, 'node-a', 'AVAILABLE', 92, 'PROVIDER', true),
      buildDelayNode(2, 'node-b', 'TIMEOUT', null, 'FALLBACK', false)
    ]
  };
}

function repeatCharacter(character: string, count: number): string {
  let result: string = '';
  for (let index: number = 0; index < count; index += 1) {
    result += character;
  }
  return result;
}

function expectRejectedPrivacy(error: ProxyRejectedError): void {
  expect(`${JSON.stringify(error)}`.includes('vpn://')).assertFalse();
  expect(`${JSON.stringify(error)}`.includes('/sandbox/')).assertFalse();
  expect(`${JSON.stringify(error)}`.includes('token')).assertFalse();
}

export default function proxyModelsTestsuite() {
  describe('ProxyModelsTest', () => {
    it('exposesExactErrorCodesAndSelectionKindsViaFreshAccessors', 0, () => {
      const rejectedCodes: string[] = listProxyRejectedErrorCodes();
      const selectionKinds: string[] = listProxySelectionResultKinds();
      rejectedCodes[0] = 'mutated';
      selectionKinds[0] = 'mutated';

      expect(listProxyRejectedErrorCodes().join(',')).assertEqual(
        'PROXY_PROFILE_UNAVAILABLE,PROXY_RUNTIME_NOT_READY,PROXY_SELECTION_STALE,PROXY_QUERY_FAILED,PROXY_SELECTION_FAILED,PROXY_PERSISTENCE_FAILED,PROXY_DELAY_TEST_FAILED,PROXY_DELAY_DRAIN_FAILED,VPN_SESSION_CHANGED'
      );
      expect(listProxySelectionResultKinds().join(',')).assertEqual(
        'APPLIED_NOW,SAVED_FOR_NEXT_START,APPLIED_NOT_PERSISTED,REJECTED'
      );
      expect(rejectedCodes[0]).assertEqual('mutated');
      expect(selectionKinds[0]).assertEqual('mutated');
      expect(createProxyRejectedError('PROXY_QUERY_FAILED', true, CANONICAL_TIMESTAMP).code).assertEqual('PROXY_QUERY_FAILED');
    });

    it('createsImmutableProxyProfileIdentityAndSelectionRecords', 0, () => {
      const revisionHashSource: string[] = [REVISION_HASH];
      const sessionIdSource: string[] = ['session-1'];
      const updatedAtSource: string[] = [SECOND_TIMESTAMP];
      const profile: ActiveProxyProfile = createActiveProxyProfile(
        'profile-1',
        CANONICAL_TIMESTAMP,
        revisionHashSource[0],
        'sandbox/profiles/current.yaml'
      );
      const identity: ProxyRuntimeIdentity = createProxyRuntimeIdentity(
        'profile-1',
        CANONICAL_TIMESTAMP,
        revisionHashSource[0],
        sessionIdSource[0]
      );
      const record: ProxySelectionRecord = createProxySelectionRecord(
        'profile-1',
        'GroupA',
        'NodeA',
        CANONICAL_TIMESTAMP,
        updatedAtSource[0]
      );
      const groupSource: CoreProxyGroupSnapshot = buildGroupSnapshot();
      const snapshot = createProxyGroupSnapshot(identity, 11, groupSource);

      revisionHashSource[0] = PROFILE_HASH;
      sessionIdSource[0] = 'session-2';
      updatedAtSource[0] = CANONICAL_TIMESTAMP;
      groupSource.nodes[0].name = 'NodeMutated';

      expect(profile.profileId).assertEqual('profile-1');
      expect(profile.revisionHash).assertEqual(REVISION_HASH);
      expect(profile.revisionId).assertEqual(CANONICAL_TIMESTAMP);
      expect(identity.sessionId).assertEqual('session-1');
      expect(identity.revisionHash).assertEqual(REVISION_HASH);
      expect(record.selectedNodeName).assertEqual('NodeA');
      expect(record.updatedAt).assertEqual(SECOND_TIMESTAMP);
      expect(snapshot.group.nodes[0].name).assertEqual('NodeA');
      expect(buildGroupSnapshot().nodes[0].name).assertEqual('NodeA');
    });

    it('exposesDelayEnumsAndDeepClonesDelaySnapshots', 0, () => {
      const jobStates: string[] = listCoreProxyDelayJobStates();
      const nodeStates: string[] = listCoreProxyDelayNodeStates();
      const urlSources: string[] = listCoreProxyDelayURLSources();
      jobStates[0] = 'mutated';
      nodeStates[0] = 'mutated';
      urlSources[0] = 'mutated';

      expect(listCoreProxyDelayJobStates().join(',')).assertEqual('RUNNING,COMPLETED,CANCELLED,FAILED');
      expect(listCoreProxyDelayNodeStates().join(',')).assertEqual(
        'WAITING,TESTING,AVAILABLE,TIMEOUT,FAILED,CANCELLED,UNSUPPORTED'
      );
      expect(listCoreProxyDelayURLSources().join(',')).assertEqual('PROVIDER,FALLBACK');

      const source: CoreProxyDelaySnapshot = buildDelaySnapshot();
      const clonedNode: CoreProxyDelayNodeResult = cloneCoreProxyDelayNodeResult(source.nodes[1]);
      const clonedSnapshot: CoreProxyDelaySnapshot = cloneCoreProxyDelaySnapshot(source);

      source.nodes[1].name = 'mutated-source';
      source.nodes[1].delayMs = 321;
      source.nodes[1].source = 'FALLBACK';
      source.nodes[1].fastest = false;
      source.nodes.push(buildDelayNode(3, 'late-node', 'FAILED', null, 'PROVIDER', false));
      source.fastestNodeIndex = null;

      expect(clonedNode.name).assertEqual('node-a');
      expect(clonedNode.delayMs).assertEqual(92);
      expect(clonedNode.source).assertEqual('PROVIDER');
      expect(clonedNode.fastest).assertTrue();
      expect(clonedSnapshot.schemaVersion).assertEqual('1.0.0');
      expect(clonedSnapshot.nodes.length).assertEqual(3);
      expect(clonedSnapshot.nodes[1].name).assertEqual('node-a');
      expect(clonedSnapshot.nodes[1].delayMs).assertEqual(92);
      expect(clonedSnapshot.nodes[1].source).assertEqual('PROVIDER');
      expect(clonedSnapshot.fastestNodeIndex).assertEqual(1);

      clonedSnapshot.nodes[1].name = 'mutated-clone';
      expect(source.nodes[1].name).assertEqual('mutated-source');
    });

    it('createsClosedQueryReconcileAndSelectionResultUnionsWithDeepClones', 0, () => {
      const identity: ProxyRuntimeIdentity = buildRuntimeIdentity('session-1');
      const record: ProxySelectionRecord = createProxySelectionRecord(
        'profile-1',
        'GroupA',
        'NodeA',
        CANONICAL_TIMESTAMP,
        SECOND_TIMESTAMP
      );
      const snapshot = createProxyGroupSnapshot(identity, 13, buildGroupSnapshot());
      const rejected: ProxyRejectedResult = createProxyRejectedResult(
        createProxyRejectedError('PROXY_QUERY_FAILED', true, CANONICAL_TIMESTAMP)
      );
      const listResult: ProxyGroupListQueryResult = createProxyGroupListQuerySnapshot(identity, 9, buildGroupRefs());
      const groupResult: ProxyGroupQueryResult = createProxyGroupQuerySnapshot(snapshot);
      const reconcileResult: ProxyReconcileResult = createProxyReconcileResult(PROFILE_HASH, REVISION_HASH, 3, 2);
      const appliedNow: ProxySelectionResult = createProxySelectionAppliedNowResult(snapshot, record, SECOND_TIMESTAMP);
      const savedForNextStart: ProxySelectionResult = createProxySelectionSavedForNextStartResult(record, SECOND_TIMESTAMP);
      const appliedNotPersisted: ProxySelectionResult = createProxySelectionAppliedNotPersistedResult(
        snapshot,
        record,
        createProxyRejectedError('PROXY_PERSISTENCE_FAILED', false, SECOND_TIMESTAMP),
        SECOND_TIMESTAMP
      );

      snapshot.group.nodes[0].name = 'MutatedSnapshotSource';
      record.selectedNodeName = 'MutatedRecordSource';
      if (listResult.kind === 'SNAPSHOT') {
        identity.sessionId = 'session-mutated';
      }
      if (groupResult.kind === 'SNAPSHOT') {
        snapshot.group.nodes[0].name = 'MutatedAgain';
      }
      if (appliedNow.kind === 'APPLIED_NOW') {
        record.groupName = 'MutatedGroupSource';
      }
      if (savedForNextStart.kind === 'SAVED_FOR_NEXT_START') {
        record.selectedNodeName = 'MutatedSavedSource';
      }
      if (appliedNotPersisted.kind === 'APPLIED_NOT_PERSISTED') {
        snapshot.group.nodes[0].name = 'MutatedPersistedSource';
      }

      expect(rejected.kind).assertEqual('REJECTED');
      expect(listResult.kind).assertEqual('SNAPSHOT');
      expect(groupResult.kind).assertEqual('SNAPSHOT');
      expect(reconcileResult.kind).assertEqual('RECONCILED');
      expect(appliedNow.kind).assertEqual('APPLIED_NOW');
      expect(savedForNextStart.kind).assertEqual('SAVED_FOR_NEXT_START');
      expect(appliedNotPersisted.kind).assertEqual('APPLIED_NOT_PERSISTED');
      if (listResult.kind === 'SNAPSHOT') {
        expect(listResult.identity.sessionId).assertEqual('session-1');
      }
      if (groupResult.kind === 'SNAPSHOT') {
        expect(groupResult.snapshot.group.nodes[0].name).assertEqual('NodeA');
      }
      if (appliedNow.kind === 'APPLIED_NOW') {
        expect(appliedNow.snapshot.group.nodes[0].name).assertEqual('NodeA');
        expect(appliedNow.record.groupName).assertEqual('GroupA');
      }
      if (savedForNextStart.kind === 'SAVED_FOR_NEXT_START') {
        expect(savedForNextStart.record.selectedNodeName).assertEqual('NodeA');
      }
      if (appliedNotPersisted.kind === 'APPLIED_NOT_PERSISTED') {
        expect(appliedNotPersisted.error.code).assertEqual('PROXY_PERSISTENCE_FAILED');
        expect(appliedNotPersisted.snapshot.group.nodes[0].name).assertEqual('NodeA');
      }
    });

    it('rejectsInvalidIdsHashesNamesGenerationCountsAndTimestamps', 0, () => {
      expectThrowsMessage(() => {
        createActiveProxyProfile(' ', CANONICAL_TIMESTAMP, REVISION_HASH, 'sandbox/profiles/current.yaml');
      }, 'must not be blank');
      expectThrowsMessage(() => {
        createActiveProxyProfile(' profile-1 ', CANONICAL_TIMESTAMP, REVISION_HASH, 'sandbox/profiles/current.yaml');
      }, 'leading or trailing whitespace');
      expectThrowsMessage(() => {
        createProxyRuntimeIdentity('profile-1', CANONICAL_TIMESTAMP, 'ABC', 'session-1');
      }, 'SHA-256');
      expectThrowsMessage(() => {
        createProxyRuntimeIdentity(' profile-1 ', CANONICAL_TIMESTAMP, REVISION_HASH, 'session-1');
      }, 'leading or trailing whitespace');
      expectThrowsMessage(() => {
        createProxyRuntimeIdentity('profile-1', CANONICAL_TIMESTAMP, REVISION_HASH, ' session-1 ');
      }, 'leading or trailing whitespace');
      expectThrowsMessage(() => {
        createProxySelectionRecord('profile-1', '', 'NodeA', CANONICAL_TIMESTAMP, SECOND_TIMESTAMP);
      }, 'must not be blank');
      expectThrowsMessage(() => {
        createProxySelectionRecord('profile-1', 'GroupA', 'Node\u0007', CANONICAL_TIMESTAMP, SECOND_TIMESTAMP);
      }, 'control');
      expectThrowsMessage(() => {
        createProxyGroupSnapshot(buildRuntimeIdentity('session-1'), 0, buildGroupSnapshot());
      }, 'positive integer');
      expectThrowsMessage(() => {
        createProxyReconcileResult(PROFILE_HASH, REVISION_HASH, -1, 0);
      }, 'non-negative');
      expectThrowsMessage(() => {
        createProxyRejectedError('PROXY_QUERY_FAILED', true, '2026-08-07');
      }, 'ISO-8601');
    });

    it('acceptsExactBoundaryLabelsAndRejectsOverflowControlAndInvalidUnicodeShapes', 0, () => {
      const ascii256: string = repeatCharacter('a', 256);
      const ascii257: string = repeatCharacter('a', 257);
      const emoji64: string = repeatCharacter('😀', 64);
      const validPair64: string = repeatCharacter('😀', 64);
      const loneHighSurrogate: string = '\uD83D';
      const loneLowSurrogate: string = '\uDC00';
      const c1ControlName: string = `Node${'\u0085'}`;

      expect(createProxySelectionRecord('profile-1', ascii256, emoji64, CANONICAL_TIMESTAMP, SECOND_TIMESTAMP).groupName)
        .assertEqual(ascii256);
      expect(createProxySelectionRecord('profile-1', 'GroupA', validPair64, CANONICAL_TIMESTAMP, SECOND_TIMESTAMP).selectedNodeName)
        .assertEqual(validPair64);
      expect(createVpnProxySelectCommand(buildRuntimeIdentity('session-1'), 1, 'GroupA', emoji64).memberName)
        .assertEqual(emoji64);

      expectThrowsMessage(() => {
        createProxySelectionRecord('profile-1', ascii257, 'NodeA', CANONICAL_TIMESTAMP, SECOND_TIMESTAMP);
      }, '256 UTF-8 bytes');
      expectThrowsMessage(() => {
        createProxySelectionRecord('profile-1', 'GroupA', loneHighSurrogate, CANONICAL_TIMESTAMP, SECOND_TIMESTAMP);
      }, 'well-formed Unicode');
      expectThrowsMessage(() => {
        createProxySelectionRecord('profile-1', 'GroupA', loneLowSurrogate, CANONICAL_TIMESTAMP, SECOND_TIMESTAMP);
      }, 'well-formed Unicode');
      expectThrowsMessage(() => {
        createProxySelectionRecord('profile-1', 'GroupA', c1ControlName, CANONICAL_TIMESTAMP, SECOND_TIMESTAMP);
      }, 'control');
      expectThrowsMessage(() => {
        createProxyRuntimeIdentity('profile-1', CANONICAL_TIMESTAMP, REVISION_HASH, loneHighSurrogate);
      }, 'well-formed Unicode');
      expectThrowsMessage(() => {
        createActiveProxyProfile('profile-1', CANONICAL_TIMESTAMP, REVISION_HASH, `/tmp/${loneLowSurrogate}.yaml`);
      }, 'well-formed Unicode');
    });

    it('acceptsSafeIntegerBoundsAndRejectsUnsafeGenerationAndCounts', 0, () => {
      const maximumGenerationSnapshot = createProxyGroupSnapshot(
        buildRuntimeIdentity('session-1'),
        Number.MAX_SAFE_INTEGER,
        buildGroupSnapshot()
      );
      const maximumCountsResult = createProxyReconcileResult(
        PROFILE_HASH,
        REVISION_HASH,
        Number.MAX_SAFE_INTEGER,
        Number.MAX_SAFE_INTEGER
      );

      expect(maximumGenerationSnapshot.generation).assertEqual(Number.MAX_SAFE_INTEGER);
      if (maximumCountsResult.kind === 'RECONCILED') {
        expect(maximumCountsResult.keptCount).assertEqual(Number.MAX_SAFE_INTEGER);
        expect(maximumCountsResult.deletedCount).assertEqual(Number.MAX_SAFE_INTEGER);
      }

      expectThrowsMessage(() => {
        createProxyGroupSnapshot(buildRuntimeIdentity('session-1'), Number.MAX_SAFE_INTEGER + 1, buildGroupSnapshot());
      }, 'safe positive integer');
      expectThrowsMessage(() => {
        createProxyReconcileResult(PROFILE_HASH, REVISION_HASH, Number.MAX_SAFE_INTEGER + 1, 0);
      }, 'safe non-negative integer');
      expectThrowsMessage(() => {
        createProxyReconcileResult(PROFILE_HASH, REVISION_HASH, 0, Number.MAX_SAFE_INTEGER + 1);
      }, 'safe non-negative integer');
    });

    it('keepsRejectedErrorsSanitizedAndDetailFree', 0, () => {
      const error: ProxyRejectedError = createProxyRejectedError(
        'PROXY_SELECTION_FAILED',
        false,
        CANONICAL_TIMESTAMP
      );
      const rejected: ProxyRejectedResult = createProxyRejectedResult(error);

      expect(error.code).assertEqual('PROXY_SELECTION_FAILED');
      expect(error.retryable).assertFalse();
      expectRejectedPrivacy(error);
      expect(JSON.stringify(error).includes('"detail"')).assertFalse();
      expect(rejected.error.timestamp).assertEqual(CANONICAL_TIMESTAMP);
    });

    it('validatesSessionBoundVpnCommandsAndPortShapes', 0, () => {
      const queryGroupsIdentity: ProxyRuntimeIdentity = buildRuntimeIdentity('session-1');
      const queryGroupIdentity: ProxyRuntimeIdentity = buildRuntimeIdentity('session-1');
      const selectIdentity: ProxyRuntimeIdentity = buildRuntimeIdentity('session-1');
      const startDelayIdentity: ProxyRuntimeIdentity = buildRuntimeIdentity('session-1');
      const readDelayIdentity: ProxyRuntimeIdentity = buildRuntimeIdentity('session-1');
      const cancelDelayIdentity: ProxyRuntimeIdentity = buildRuntimeIdentity('session-1');
      const queryGroups: VpnProxyQueryGroupsCommand = createVpnProxyQueryGroupsCommand(
        queryGroupsIdentity,
        17,
        true
      );
      const queryGroup: VpnProxyQueryGroupCommand = createVpnProxyQueryGroupCommand(
        queryGroupIdentity,
        19,
        'GroupA'
      );
      const select: VpnProxySelectCommand = createVpnProxySelectCommand(
        selectIdentity,
        23,
        'GroupA',
        'NodeA'
      );
      const startDelay: VpnProxyStartDelayTestCommand = createVpnProxyStartDelayTestCommand(
        startDelayIdentity,
        29,
        'GroupA'
      );
      const readDelay: VpnProxyReadDelayTestCommand = createVpnProxyReadDelayTestCommand(
        readDelayIdentity,
        31,
        'delay-job-1'
      );
      const cancelDelay: VpnProxyCancelDelayTestCommand = createVpnProxyCancelDelayTestCommand(
        cancelDelayIdentity,
        37,
        'delay-job-1'
      );
      const ports: Object[] = [
        new FakeActiveProfilePort(),
        new FakeCoreProxyPort(),
        new FakeSelectionRepository(),
        new FakeIdentityHasher(),
        new FakeVpnRuntimeSnapshotPort(),
        new FakeVpnCommandHandler(),
        new FakeVpnRuntimeLifecyclePort(),
        new FakeProxyApplicationPort()
      ];
      const corePort: CoreProxyPort = new FakeCoreProxyPort();

      queryGroupsIdentity.sessionId = 'mutated';
      queryGroupIdentity.sessionId = 'mutated';
      selectIdentity.sessionId = 'mutated';
      startDelayIdentity.sessionId = 'mutated';
      readDelayIdentity.sessionId = 'mutated';
      cancelDelayIdentity.sessionId = 'mutated';

      expect(queryGroups.identity.sessionId).assertEqual('session-1');
      expect(queryGroup.groupName).assertEqual('GroupA');
      expect(select.memberName).assertEqual('NodeA');
      expect(startDelay.groupName).assertEqual('GroupA');
      expect(readDelay.jobId).assertEqual('delay-job-1');
      expect(cancelDelay.jobId).assertEqual('delay-job-1');
      expect(ports.length).assertEqual(8);
      expect(corePort !== undefined).assertTrue();

      expectThrowsMessage(() => {
        createVpnProxyQueryGroupsCommand(buildRuntimeIdentity(null), 17, false);
      }, 'session');
      expectThrowsMessage(() => {
        createVpnProxyQueryGroupCommand(buildRuntimeIdentity('session-1'), 0, 'GroupA');
      }, 'positive integer');
      expectThrowsMessage(() => {
        createVpnProxySelectCommand(buildRuntimeIdentity('session-1'), 1, 'GroupA', 'Node\u0000');
      }, 'control');
      expectThrowsMessage(() => {
        createVpnProxyStartDelayTestCommand(buildRuntimeIdentity(null), 1, 'GroupA');
      }, 'non-null running session');
      expectThrowsMessage(() => {
        createVpnProxyReadDelayTestCommand(buildRuntimeIdentity('session-1'), 0, 'delay-job-1');
      }, 'safe positive integer');
      expectThrowsMessage(() => {
        createVpnProxyCancelDelayTestCommand(buildRuntimeIdentity('session-1'), 1, ' ');
      }, 'must not be blank');
    });

    it('sanitizesDelaySnapshotResultsClonesAndInvalidShapes', 0, () => {
      const source: CoreProxyDelaySnapshot = buildDelaySnapshot();
      source.state = 'RUNNING';
      source.sessionHash = PROFILE_HASH;
      const result: ProxyDelaySnapshotResult = createProxyDelaySnapshotResultFromCoreSnapshot(
        buildRuntimeIdentity('session-1'),
        12,
        'url-test',
        source
      );

      source.nodes[1].name = 'Mutated';
      source.nodes[1].source = 'FALLBACK';

      expect(result.kind).assertEqual('SNAPSHOT');
      expect(result.groupName).assertEqual('url-test');
      expect(result.nodes[1].name).assertEqual('node-a');
      expect(JSON.stringify(result.nodes[1]).includes('source')).assertFalse();

      expectThrowsMessage(() => {
        createProxyDelayNodeResult(1, 'NodeA', 'Trojan', 'AVAILABLE', null, false);
      }, 'delayMs');
      expectThrowsMessage(() => {
        normalizeProxyDelayJobId(' ');
      }, 'must not be blank');
    });
  });
}
