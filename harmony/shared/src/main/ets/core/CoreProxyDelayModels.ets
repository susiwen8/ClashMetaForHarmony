import { type CoreProxyQueryContext, type CoreProxyType } from './CoreProxyModels';

export type CoreProxyDelayJobState = 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED';
export type CoreProxyDelayNodeState = 'WAITING' | 'TESTING' | 'AVAILABLE' | 'TIMEOUT' | 'FAILED' | 'CANCELLED' | 'UNSUPPORTED';
export type CoreProxyDelayURLSource = 'PROVIDER' | 'FALLBACK';

export const CORE_PROXY_DELAY_SCHEMA_VERSION: '1.0.0' = '1.0.0';

const CORE_PROXY_DELAY_JOB_STATES: CoreProxyDelayJobState[] = [
  'RUNNING',
  'COMPLETED',
  'CANCELLED',
  'FAILED'
];

const CORE_PROXY_DELAY_NODE_STATES: CoreProxyDelayNodeState[] = [
  'WAITING',
  'TESTING',
  'AVAILABLE',
  'TIMEOUT',
  'FAILED',
  'CANCELLED',
  'UNSUPPORTED'
];

const CORE_PROXY_DELAY_URL_SOURCES: CoreProxyDelayURLSource[] = [
  'PROVIDER',
  'FALLBACK'
];

export interface CoreProxyDelayNodeResult {
  index: number;
  name: string;
  type: CoreProxyType;
  state: CoreProxyDelayNodeState;
  delayMs: number | null;
  source: CoreProxyDelayURLSource | null;
  fastest: boolean;
}

export interface CoreProxyDelaySnapshot extends CoreProxyQueryContext {
  schemaVersion: '1.0.0';
  jobId: string;
  state: CoreProxyDelayJobState;
  groupName: string;
  totalCount: number;
  testableCount: number;
  completedCount: number;
  availableCount: number;
  timeoutCount: number;
  failedCount: number;
  cancelledCount: number;
  unsupportedCount: number;
  fastestNodeIndex: number | null;
  nodes: CoreProxyDelayNodeResult[];
}

class CoreProxyDelayNodeResultValue implements CoreProxyDelayNodeResult {
  index: number = 0;
  name: string = '';
  type: CoreProxyType = 'Direct';
  state: CoreProxyDelayNodeState = 'WAITING';
  delayMs: number | null = null;
  source: CoreProxyDelayURLSource | null = null;
  fastest: boolean = false;
}

class CoreProxyDelaySnapshotValue implements CoreProxyDelaySnapshot {
  schemaVersion: '1.0.0' = CORE_PROXY_DELAY_SCHEMA_VERSION;
  jobId: string = '';
  state: CoreProxyDelayJobState = 'RUNNING';
  profileHash: string = '';
  revisionHash: string = '';
  sessionHash: string | null = null;
  generation: number = 0;
  groupName: string = '';
  totalCount: number = 0;
  testableCount: number = 0;
  completedCount: number = 0;
  availableCount: number = 0;
  timeoutCount: number = 0;
  failedCount: number = 0;
  cancelledCount: number = 0;
  unsupportedCount: number = 0;
  fastestNodeIndex: number | null = null;
  nodes: CoreProxyDelayNodeResult[] = [];
}

export function listCoreProxyDelayJobStates(): CoreProxyDelayJobState[] {
  return CORE_PROXY_DELAY_JOB_STATES.slice();
}

export function listCoreProxyDelayNodeStates(): CoreProxyDelayNodeState[] {
  return CORE_PROXY_DELAY_NODE_STATES.slice();
}

export function listCoreProxyDelayURLSources(): CoreProxyDelayURLSource[] {
  return CORE_PROXY_DELAY_URL_SOURCES.slice();
}

export function cloneCoreProxyDelayNodeResult(node: CoreProxyDelayNodeResult): CoreProxyDelayNodeResult {
  const clone = new CoreProxyDelayNodeResultValue();
  clone.index = node.index;
  clone.name = node.name;
  clone.type = node.type;
  clone.state = node.state;
  clone.delayMs = node.delayMs;
  clone.source = node.source;
  clone.fastest = node.fastest;
  return clone;
}

export function cloneCoreProxyDelaySnapshot(snapshot: CoreProxyDelaySnapshot): CoreProxyDelaySnapshot {
  const clone = new CoreProxyDelaySnapshotValue();
  clone.jobId = snapshot.jobId;
  clone.state = snapshot.state;
  clone.profileHash = snapshot.profileHash;
  clone.revisionHash = snapshot.revisionHash;
  clone.sessionHash = snapshot.sessionHash;
  clone.generation = snapshot.generation;
  clone.groupName = snapshot.groupName;
  clone.totalCount = snapshot.totalCount;
  clone.testableCount = snapshot.testableCount;
  clone.completedCount = snapshot.completedCount;
  clone.availableCount = snapshot.availableCount;
  clone.timeoutCount = snapshot.timeoutCount;
  clone.failedCount = snapshot.failedCount;
  clone.cancelledCount = snapshot.cancelledCount;
  clone.unsupportedCount = snapshot.unsupportedCount;
  clone.fastestNodeIndex = snapshot.fastestNodeIndex;
  const nodes: CoreProxyDelayNodeResult[] = [];
  for (let index: number = 0; index < snapshot.nodes.length; index += 1) {
    nodes.push(cloneCoreProxyDelayNodeResult(snapshot.nodes[index]));
  }
  clone.nodes = nodes;
  return clone;
}
