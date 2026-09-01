import { describe, expect, it } from '@ohos/hypium';
import {
  CORE_PROXY_DELAY_SCHEMA_VERSION,
  createProxyDelayNodeResult,
  createProxyDelaySnapshotResultFromCoreSnapshot,
  listProxyDelayJobStates,
  listProxyDelayNodeStates,
  type CoreProxyDelaySnapshot,
  type ProxyDelayNodeResult,
  type ProxyDelaySnapshotResult,
  type ProxyRuntimeIdentity
} from '../../Index';
import { createProxyRuntimeIdentity } from '../../Index';
import { expectThrowsMessage } from './fakes/ProfileFakes';

const REVISION_HASH: string = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const PROFILE_HASH: string = '1111111111111111111111111111111111111111111111111111111111111111';
const SESSION_HASH: string = '2222222222222222222222222222222222222222222222222222222222222222';

function buildIdentity(): ProxyRuntimeIdentity {
  return createProxyRuntimeIdentity('profile-1', '2026-08-23T08:00:00.000Z', REVISION_HASH, 'session-1');
}

function buildCoreDelaySnapshot(): CoreProxyDelaySnapshot {
  return {
    schemaVersion: CORE_PROXY_DELAY_SCHEMA_VERSION,
    jobId: 'delay-job-1',
    state: 'RUNNING',
    profileHash: PROFILE_HASH,
    revisionHash: REVISION_HASH,
    sessionHash: SESSION_HASH,
    generation: 19,
    groupName: 'Group Alpha',
    totalCount: 3,
    testableCount: 2,
    completedCount: 2,
    availableCount: 1,
    timeoutCount: 0,
    failedCount: 0,
    cancelledCount: 0,
    unsupportedCount: 1,
    fastestNodeIndex: 1,
    nodes: [
      {
        index: 0,
        name: 'Node Waiting',
        type: 'Shadowsocks',
        state: 'WAITING',
        delayMs: null,
        source: null,
        fastest: false
      },
      {
        index: 1,
        name: 'Node Fastest',
        type: 'Trojan',
        state: 'AVAILABLE',
        delayMs: 42,
        source: 'PROVIDER',
        fastest: true
      },
      {
        index: 2,
        name: 'Node Unsupported',
        type: 'Selector',
        state: 'UNSUPPORTED',
        delayMs: null,
        source: null,
        fastest: false
      }
    ]
  };
}

export default function proxyDelayModelsTestsuite() {
  describe('ProxyDelayModelsTest', () => {
    it('mapsCoreDelaySnapshotsIntoDeepClonedApplicationSnapshotsWithoutSources', 0, () => {
      const source: CoreProxyDelaySnapshot = buildCoreDelaySnapshot();
      const result: ProxyDelaySnapshotResult = createProxyDelaySnapshotResultFromCoreSnapshot(
        buildIdentity(),
        19,
        'Group Alpha',
        source
      );

      source.groupName = 'Mutated Group';
      source.jobId = 'mutated-job';
      source.nodes[1].name = 'Mutated Node';
      source.nodes[1].delayMs = 999;
      source.nodes[1].source = 'FALLBACK';

      expect(result.kind).assertEqual('SNAPSHOT');
      expect(result.identity.sessionId).assertEqual('session-1');
      expect(result.generation).assertEqual(19);
      expect(result.groupName).assertEqual('Group Alpha');
      expect(result.jobId).assertEqual('delay-job-1');
      expect(result.fastestNodeIndex).assertEqual(1);
      expect(result.nodes.length).assertEqual(3);
      expect(result.nodes[1].name).assertEqual('Node Fastest');
      expect(result.nodes[1].delayMs).assertEqual(42);
      expect(JSON.stringify(result.nodes[1]).includes('source')).assertFalse();
    });

    it('exposesClosedDelayEnumsAndValidatesDelayNodeInvariants', 0, () => {
      const jobStates: string[] = listProxyDelayJobStates();
      const nodeStates: string[] = listProxyDelayNodeStates();
      jobStates[0] = 'mutated';
      nodeStates[0] = 'mutated';

      expect(listProxyDelayJobStates().join(',')).assertEqual('RUNNING,COMPLETED,CANCELLED,FAILED');
      expect(listProxyDelayNodeStates().join(',')).assertEqual(
        'WAITING,TESTING,AVAILABLE,TIMEOUT,FAILED,CANCELLED,UNSUPPORTED'
      );

      const available: ProxyDelayNodeResult = createProxyDelayNodeResult(2, 'NodeA', 'Trojan', 'AVAILABLE', 55, true);
      expect(available.delayMs).assertEqual(55);
      expect(available.fastest).assertTrue();

      expectThrowsMessage(() => {
        createProxyDelayNodeResult(1, 'NodeB', 'Trojan', 'AVAILABLE', null, false);
      }, 'delayMs');
      expectThrowsMessage(() => {
        createProxyDelayNodeResult(1, 'NodeB', 'Trojan', 'FAILED', 12, false);
      }, 'delayMs');
      expectThrowsMessage(() => {
        createProxyDelayNodeResult(1, 'NodeB', 'Trojan', 'WAITING', null, true);
      }, 'fastest');
    });

    it('rejectsMismatchedCoreContextGroupAndFastestNodeShapes', 0, () => {
      const wrongGroup: CoreProxyDelaySnapshot = buildCoreDelaySnapshot();
      wrongGroup.groupName = 'Other Group';
      expectThrowsMessage(() => {
        createProxyDelaySnapshotResultFromCoreSnapshot(buildIdentity(), 19, 'Group Alpha', wrongGroup);
      }, 'group');

      const wrongGeneration: CoreProxyDelaySnapshot = buildCoreDelaySnapshot();
      wrongGeneration.generation = 20;
      expectThrowsMessage(() => {
        createProxyDelaySnapshotResultFromCoreSnapshot(buildIdentity(), 19, 'Group Alpha', wrongGeneration);
      }, 'generation');

      const invalidFastest: CoreProxyDelaySnapshot = buildCoreDelaySnapshot();
      invalidFastest.fastestNodeIndex = 0;
      expectThrowsMessage(() => {
        createProxyDelaySnapshotResultFromCoreSnapshot(buildIdentity(), 19, 'Group Alpha', invalidFastest);
      }, 'fastest');
    });

    it('acceptsCompletedCountThatIncludesUnsupportedTerminalNodes', 0, () => {
      const source: CoreProxyDelaySnapshot = buildCoreDelaySnapshot();
      source.state = 'COMPLETED';
      source.completedCount = 2;

      const result: ProxyDelaySnapshotResult = createProxyDelaySnapshotResultFromCoreSnapshot(
        buildIdentity(),
        19,
        'Group Alpha',
        source
      );

      expect(result.kind).assertEqual('SNAPSHOT');
      expect(result.completedCount).assertEqual(2);
      expect(result.unsupportedCount).assertEqual(1);
    });
  });
}
