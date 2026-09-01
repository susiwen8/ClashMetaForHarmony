import type {
  CoreProxyDelayJobState,
  CoreProxyDelayNodeState,
  CoreProxyDelaySnapshot
} from '../core/CoreProxyDelayModels';
import type { CoreProxyType } from '../core/CoreProxyModels';
import {
  cloneProxyRejectedResult,
  cloneProxyRuntimeIdentity,
  normalizeProxyLabel,
  type ProxyRejectedResult,
  type ProxyRuntimeIdentity
} from './ProxyModels';

const proxyDelayJobStates: CoreProxyDelayJobState[] = [
  'RUNNING',
  'COMPLETED',
  'CANCELLED',
  'FAILED'
];

const proxyDelayNodeStates: CoreProxyDelayNodeState[] = [
  'WAITING',
  'TESTING',
  'AVAILABLE',
  'TIMEOUT',
  'FAILED',
  'CANCELLED',
  'UNSUPPORTED'
];

const MAX_PRIVATE_ID_BYTES: number = 256;

export type ProxyDelayJobState = CoreProxyDelayJobState;
export type ProxyDelayNodeState = CoreProxyDelayNodeState;

export interface ProxyDelayNodeResult {
  index: number;
  name: string;
  type: CoreProxyType;
  state: ProxyDelayNodeState;
  delayMs: number | null;
  fastest: boolean;
}

export interface ProxyDelaySnapshotResult {
  kind: 'SNAPSHOT';
  identity: ProxyRuntimeIdentity;
  generation: number;
  groupName: string;
  jobId: string;
  state: ProxyDelayJobState;
  totalCount: number;
  testableCount: number;
  completedCount: number;
  availableCount: number;
  timeoutCount: number;
  failedCount: number;
  cancelledCount: number;
  unsupportedCount: number;
  fastestNodeIndex: number | null;
  nodes: ProxyDelayNodeResult[];
}

export type ProxyDelayResult = ProxyDelaySnapshotResult | ProxyRejectedResult;

function utf8ByteLength(value: string): number {
  let total: number = 0;
  for (let index: number = 0; index < value.length; index += 1) {
    const code: number = value.charCodeAt(index);
    if (code <= 0x7f) {
      total += 1;
      continue;
    }
    if (code <= 0x7ff) {
      total += 2;
      continue;
    }
    if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length) {
      const next: number = value.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        total += 4;
        index += 1;
        continue;
      }
    }
    total += 3;
  }
  return total;
}

function containsUnicodeCc(value: string): boolean {
  for (let index: number = 0; index < value.length; index += 1) {
    const code: number = value.charCodeAt(index);
    if ((code >= 0x0000 && code <= 0x001f) || (code >= 0x007f && code <= 0x009f)) {
      return true;
    }
  }
  return false;
}

function isWellFormedUnicode(value: string): boolean {
  for (let index: number = 0; index < value.length; index += 1) {
    const code: number = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      if (index + 1 >= value.length) {
        return false;
      }
      const next: number = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) {
        return false;
      }
      index += 1;
      continue;
    }
    if (code >= 0xdc00 && code <= 0xdfff) {
      return false;
    }
  }
  return true;
}

function requireSafePositiveInteger(value: number, label: string): number {
  if (!Number.isInteger(value) || value <= 0 || value > Number.MAX_SAFE_INTEGER) {
    throw new Error(`${label} must be a safe positive integer.`);
  }
  return value;
}

function requireSafeNonNegativeInteger(value: number, label: string): number {
  if (!Number.isInteger(value) || value < 0 || value > Number.MAX_SAFE_INTEGER) {
    throw new Error(`${label} must be a safe non-negative integer.`);
  }
  return value;
}

function normalizeJobState(state: ProxyDelayJobState): ProxyDelayJobState {
  for (let index: number = 0; index < proxyDelayJobStates.length; index += 1) {
    if (proxyDelayJobStates[index] === state) {
      return state;
    }
  }
  throw new Error('Proxy delay job state must stay inside the allowlisted public contract.');
}

function normalizeNodeState(state: ProxyDelayNodeState): ProxyDelayNodeState {
  for (let index: number = 0; index < proxyDelayNodeStates.length; index += 1) {
    if (proxyDelayNodeStates[index] === state) {
      return state;
    }
  }
  throw new Error('Proxy delay node state must stay inside the allowlisted public contract.');
}

export function normalizeProxyDelayJobId(rawValue: string): string {
  const trimmed: string = rawValue.trim();
  if (trimmed.length === 0) {
    throw new Error('Proxy delay jobId must not be blank.');
  }
  if (rawValue !== trimmed) {
    throw new Error('Proxy delay jobId must not contain leading or trailing whitespace.');
  }
  if (!isWellFormedUnicode(rawValue)) {
    throw new Error('Proxy delay jobId must be well-formed Unicode.');
  }
  if (containsUnicodeCc(rawValue)) {
    throw new Error('Proxy delay jobId must not contain control characters.');
  }
  if (utf8ByteLength(rawValue) > MAX_PRIVATE_ID_BYTES) {
    throw new Error(`Proxy delay jobId must stay within ${MAX_PRIVATE_ID_BYTES} UTF-8 bytes.`);
  }
  return rawValue;
}

function normalizeFastestNodeIndex(fastestNodeIndex: number | null, totalCount: number): number | null {
  if (fastestNodeIndex === null) {
    return null;
  }
  const normalized: number = requireSafeNonNegativeInteger(fastestNodeIndex, 'Proxy delay fastestNodeIndex');
  if (normalized >= totalCount) {
    throw new Error('Proxy delay fastestNodeIndex must stay inside the node list bounds.');
  }
  return normalized;
}

export function listProxyDelayJobStates(): ProxyDelayJobState[] {
  return proxyDelayJobStates.slice();
}

export function listProxyDelayNodeStates(): ProxyDelayNodeState[] {
  return proxyDelayNodeStates.slice();
}

export function createProxyDelayNodeResult(
  index: number,
  name: string,
  type: CoreProxyType,
  state: ProxyDelayNodeState,
  delayMs: number | null,
  fastest: boolean
): ProxyDelayNodeResult {
  const normalizedState: ProxyDelayNodeState = normalizeNodeState(state);
  const normalizedDelayMs: number | null = delayMs === null
    ? null
    : requireSafePositiveInteger(delayMs, 'Proxy delay node delayMs');
  if (normalizedState === 'AVAILABLE') {
    if (normalizedDelayMs === null) {
      throw new Error('AVAILABLE proxy delay nodes require a positive delayMs value.');
    }
  } else if (normalizedDelayMs !== null) {
    throw new Error('Non-AVAILABLE proxy delay nodes must not publish delayMs values.');
  }
  if (fastest && normalizedState !== 'AVAILABLE') {
    throw new Error('Only AVAILABLE proxy delay nodes can be marked fastest.');
  }
  return {
    index: requireSafeNonNegativeInteger(index, 'Proxy delay node index'),
    name: normalizeProxyLabel(name, 'Proxy delay node name'),
    type,
    state: normalizedState,
    delayMs: normalizedDelayMs,
    fastest
  };
}

export function cloneProxyDelayNodeResult(node: ProxyDelayNodeResult): ProxyDelayNodeResult {
  return createProxyDelayNodeResult(node.index, node.name, node.type, node.state, node.delayMs, node.fastest);
}

export function createProxyDelaySnapshotResult(
  identity: ProxyRuntimeIdentity,
  generation: number,
  groupName: string,
  jobId: string,
  state: ProxyDelayJobState,
  totalCount: number,
  testableCount: number,
  completedCount: number,
  availableCount: number,
  timeoutCount: number,
  failedCount: number,
  cancelledCount: number,
  unsupportedCount: number,
  fastestNodeIndex: number | null,
  nodes: ProxyDelayNodeResult[]
): ProxyDelaySnapshotResult {
  const clones: ProxyDelayNodeResult[] = [];
  let availableNodeCount: number = 0;
  let timeoutNodeCount: number = 0;
  let failedNodeCount: number = 0;
  let cancelledNodeCount: number = 0;
  let unsupportedNodeCount: number = 0;
  let fastestNodeCount: number = 0;
  for (let index: number = 0; index < nodes.length; index += 1) {
    const clone: ProxyDelayNodeResult = cloneProxyDelayNodeResult(nodes[index]);
    if (clone.index !== index) {
      throw new Error('Proxy delay node indexes must stay contiguous and ordered.');
    }
    if (clone.state === 'AVAILABLE') {
      availableNodeCount += 1;
    } else if (clone.state === 'TIMEOUT') {
      timeoutNodeCount += 1;
    } else if (clone.state === 'FAILED') {
      failedNodeCount += 1;
    } else if (clone.state === 'CANCELLED') {
      cancelledNodeCount += 1;
    } else if (clone.state === 'UNSUPPORTED') {
      unsupportedNodeCount += 1;
    }
    if (clone.fastest) {
      fastestNodeCount += 1;
    }
    clones.push(clone);
  }

  const normalizedTotalCount: number = requireSafeNonNegativeInteger(totalCount, 'Proxy delay totalCount');
  if (normalizedTotalCount !== clones.length) {
    throw new Error('Proxy delay totalCount must match the published node list length.');
  }
  const normalizedUnsupportedCount: number = requireSafeNonNegativeInteger(
    unsupportedCount,
    'Proxy delay unsupportedCount'
  );
  const normalizedTestableCount: number = requireSafeNonNegativeInteger(testableCount, 'Proxy delay testableCount');
  if (normalizedUnsupportedCount !== unsupportedNodeCount) {
    throw new Error('Proxy delay unsupportedCount must match the UNSUPPORTED node count.');
  }
  if (normalizedTestableCount !== normalizedTotalCount - normalizedUnsupportedCount) {
    throw new Error('Proxy delay testableCount must equal totalCount minus unsupportedCount.');
  }

  const normalizedAvailableCount: number = requireSafeNonNegativeInteger(availableCount, 'Proxy delay availableCount');
  const normalizedTimeoutCount: number = requireSafeNonNegativeInteger(timeoutCount, 'Proxy delay timeoutCount');
  const normalizedFailedCount: number = requireSafeNonNegativeInteger(failedCount, 'Proxy delay failedCount');
  const normalizedCancelledCount: number = requireSafeNonNegativeInteger(cancelledCount, 'Proxy delay cancelledCount');
  if (normalizedAvailableCount !== availableNodeCount) {
    throw new Error('Proxy delay availableCount must match the AVAILABLE node count.');
  }
  if (normalizedTimeoutCount !== timeoutNodeCount) {
    throw new Error('Proxy delay timeoutCount must match the TIMEOUT node count.');
  }
  if (normalizedFailedCount !== failedNodeCount) {
    throw new Error('Proxy delay failedCount must match the FAILED node count.');
  }
  if (normalizedCancelledCount !== cancelledNodeCount) {
    throw new Error('Proxy delay cancelledCount must match the CANCELLED node count.');
  }

  const normalizedCompletedCount: number = requireSafeNonNegativeInteger(
    completedCount,
    'Proxy delay completedCount'
  );
  if (normalizedCompletedCount !==
    normalizedAvailableCount + normalizedTimeoutCount + normalizedFailedCount + normalizedCancelledCount +
      normalizedUnsupportedCount) {
    throw new Error('Proxy delay completedCount must match the terminal node count.');
  }

  const normalizedFastestNodeIndex: number | null = normalizeFastestNodeIndex(fastestNodeIndex, normalizedTotalCount);
  if (normalizedFastestNodeIndex === null) {
    if (fastestNodeCount !== 0) {
      throw new Error('Proxy delay fastest nodes require a matching fastestNodeIndex.');
    }
  } else {
    if (fastestNodeCount !== 1) {
      throw new Error('Proxy delay fastestNodeIndex requires exactly one fastest node.');
    }
    const fastestNode: ProxyDelayNodeResult = clones[normalizedFastestNodeIndex];
    if (!fastestNode.fastest || fastestNode.state !== 'AVAILABLE') {
      throw new Error('Proxy delay fastestNodeIndex must point at one AVAILABLE fastest node.');
    }
  }

  return {
    kind: 'SNAPSHOT',
    identity: cloneProxyRuntimeIdentity(identity),
    generation: requireSafePositiveInteger(generation, 'Proxy generation'),
    groupName: normalizeProxyLabel(groupName, 'Proxy group name'),
    jobId: normalizeProxyDelayJobId(jobId),
    state: normalizeJobState(state),
    totalCount: normalizedTotalCount,
    testableCount: normalizedTestableCount,
    completedCount: normalizedCompletedCount,
    availableCount: normalizedAvailableCount,
    timeoutCount: normalizedTimeoutCount,
    failedCount: normalizedFailedCount,
    cancelledCount: normalizedCancelledCount,
    unsupportedCount: normalizedUnsupportedCount,
    fastestNodeIndex: normalizedFastestNodeIndex,
    nodes: clones
  };
}

export function createProxyDelaySnapshotResultFromCoreSnapshot(
  identity: ProxyRuntimeIdentity,
  generation: number,
  expectedGroupName: string,
  snapshot: CoreProxyDelaySnapshot
): ProxyDelaySnapshotResult {
  if (snapshot.generation !== generation) {
    throw new Error('Proxy delay snapshot generation must match the command generation.');
  }
  if (snapshot.groupName !== expectedGroupName) {
    throw new Error('Proxy delay snapshot group must match the requested group.');
  }
  const nodes: ProxyDelayNodeResult[] = [];
  for (let index: number = 0; index < snapshot.nodes.length; index += 1) {
    nodes.push(
      createProxyDelayNodeResult(
        snapshot.nodes[index].index,
        snapshot.nodes[index].name,
        snapshot.nodes[index].type,
        snapshot.nodes[index].state,
        snapshot.nodes[index].delayMs,
        snapshot.nodes[index].fastest
      )
    );
  }
  return createProxyDelaySnapshotResult(
    identity,
    generation,
    snapshot.groupName,
    snapshot.jobId,
    snapshot.state,
    snapshot.totalCount,
    snapshot.testableCount,
    snapshot.completedCount,
    snapshot.availableCount,
    snapshot.timeoutCount,
    snapshot.failedCount,
    snapshot.cancelledCount,
    snapshot.unsupportedCount,
    snapshot.fastestNodeIndex,
    nodes
  );
}

export function cloneProxyDelaySnapshotResult(result: ProxyDelaySnapshotResult): ProxyDelaySnapshotResult {
  return createProxyDelaySnapshotResult(
    result.identity,
    result.generation,
    result.groupName,
    result.jobId,
    result.state,
    result.totalCount,
    result.testableCount,
    result.completedCount,
    result.availableCount,
    result.timeoutCount,
    result.failedCount,
    result.cancelledCount,
    result.unsupportedCount,
    result.fastestNodeIndex,
    result.nodes
  );
}

export function cloneProxyDelayResult(result: ProxyDelayResult): ProxyDelayResult {
  if (result.kind === 'REJECTED') {
    return cloneProxyRejectedResult(result);
  }
  return cloneProxyDelaySnapshotResult(result);
}
