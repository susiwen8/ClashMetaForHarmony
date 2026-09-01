import type {
  CoreProxyGroupList,
  CoreProxyGroupResult,
  CoreProxyQueryContext,
  CoreProxySelectionApplied
} from '../core/CoreProxyModels';
import type { CoreProxyDelaySnapshot } from '../core/CoreProxyDelayModels';
import type { VpnStartRequest, VpnRuntimeSnapshot } from '../vpn/VpnModels';
import {
  cloneProxyRuntimeIdentity,
  normalizeProxyLabel,
  type ActiveProxyProfile,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyRejectedResult,
  type ProxyReconcileResult,
  type ProxyRuntimeIdentity,
  type ProxySelectionRecord,
  type ProxySelectionResult
} from './ProxyModels';
import type { OneClickVpnOperationSnapshot, SelectNodeAndEnsureVpnResult } from './ProxyOneClickVpnModels';
import {
  normalizeProxyDelayJobId,
  type ProxyDelayResult
} from './ProxyDelayModels';

export interface ActiveProfileProxyPort {
  resolve(): Promise<ActiveProxyProfile | undefined>;
}

export interface CoreProxyPort {
  loadConfiguration(path: string): Promise<void>;
  queryProxyGroups(context: CoreProxyQueryContext, selectableOnly: boolean): Promise<CoreProxyGroupList>;
  queryProxyGroup(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyGroupResult>;
  selectProxy(context: CoreProxyQueryContext, groupName: string, memberName: string): Promise<CoreProxySelectionApplied>;
  startProxyDelayTest(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyDelaySnapshot>;
  readProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot>;
  cancelProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot>;
}

export interface ProxySelectionPair {
  groupName: string;
  selectedNodeName: string;
}

export interface ProxySelectionRepository {
  listByProfile(profileId: string): Promise<ProxySelectionRecord[]>;
  get(profileId: string, groupName: string): Promise<ProxySelectionRecord | undefined>;
  upsert(record: ProxySelectionRecord): Promise<void>;
  delete(profileId: string, groupName: string): Promise<void>;
  deleteProfile(profileId: string): Promise<void>;
  reconcileProfile(profileId: string, newRevisionId: string, validPairs: ProxySelectionPair[]): Promise<void>;
}

export interface ProxyIdentityHasher {
  sha256(value: string): Promise<string>;
}

export interface VpnStoppedProxyLease {
  snapshot(): VpnRuntimeSnapshot;
  release(): void;
}

export interface VpnRuntimeSnapshotPort {
  snapshot(): VpnRuntimeSnapshot;
  acquireStoppedProxyLease(): VpnStoppedProxyLease | undefined;
}

export interface VpnProxyQueryGroupsCommand {
  identity: ProxyRuntimeIdentity;
  generation: number;
  selectableOnly: boolean;
}

export interface VpnProxyQueryGroupCommand {
  identity: ProxyRuntimeIdentity;
  generation: number;
  groupName: string;
  groupPath?: string[];
}

export interface VpnProxySelectCommand {
  identity: ProxyRuntimeIdentity;
  generation: number;
  groupName: string;
  groupPath?: string[];
  memberName: string;
}

export interface VpnProxyStartDelayTestCommand {
  identity: ProxyRuntimeIdentity;
  generation: number;
  groupName: string;
  groupPath?: string[];
}

export interface VpnProxyReadDelayTestCommand {
  identity: ProxyRuntimeIdentity;
  generation: number;
  jobId: string;
}

export interface VpnProxyCancelDelayTestCommand {
  identity: ProxyRuntimeIdentity;
  generation: number;
  jobId: string;
}

// Handler methods are invoked by the extension-owned runtime.
// They must not call bind/invalidate/deactivate on their owning VpnProxyCommandBus.
// Lifecycle transitions are owned externally by the VPN session lifecycle.
export interface VpnProxyCommandHandler {
  queryGroups(command: VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult>;
  queryGroup(command: VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult>;
  select(command: VpnProxySelectCommand): Promise<ProxySelectionResult>;
  startDelayTest(command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult>;
  readDelayTest(command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult>;
  cancelDelayTest(command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult>;
}

export interface VpnProxyRuntimeLifecyclePort {
  activate(request: VpnStartRequest): Promise<void>;
  invalidate(sessionId: string): void;
  cancelAndDrainDelayTest(sessionId: string): Promise<void>;
  // Idempotent: repeated calls for the same inactive/already-deactivated session
  // must resolve without extra side effects or errors.
  deactivate(sessionId: string): Promise<void>;
}

export interface VpnProxyRuntimeMirrorPort {
  bindExistingSession(request: VpnStartRequest): Promise<void>;
  deactivate(sessionId: string): Promise<void>;
}

export interface ProxyApplicationPort {
  listGroups(): Promise<ProxyGroupListQueryResult>;
  queryGroup(groupName: string, groupPath?: string[]): Promise<ProxyGroupQueryResult>;
  select(
    groupName: string,
    memberName: string,
    snapshotGeneration: number,
    groupPath?: string[]
  ): Promise<ProxySelectionResult>;
  reconcileActiveSelections(): Promise<ProxyReconcileResult>;
  startDelayTest(groupName: string, snapshotGeneration: number, groupPath?: string[]): Promise<ProxyDelayResult>;
  readDelayTest(jobId: string): Promise<ProxyDelayResult>;
  cancelDelayTest(jobId: string): Promise<ProxyDelayResult>;
  cancelAndDrainDelayTest(): Promise<ProxyRejectedResult | undefined>;
}

export type OneClickVpnOperationListener = (snapshot: OneClickVpnOperationSnapshot) => void;

export interface ProxyOneClickVpnApplicationPort extends ProxyApplicationPort {
  currentOneClickVpnOperation(): OneClickVpnOperationSnapshot;
  subscribeOneClickVpnOperation(listener: OneClickVpnOperationListener): number;
  unsubscribeOneClickVpnOperation(id: number): void;
  selectNodeAndEnsureVpn(
    groupName: string,
    memberName: string,
    snapshotGeneration: number,
    groupPath?: string[]
  ): Promise<SelectNodeAndEnsureVpnResult>;
}

function requireRunningIdentity(identity: ProxyRuntimeIdentity): ProxyRuntimeIdentity {
  const clone: ProxyRuntimeIdentity = cloneProxyRuntimeIdentity(identity);
  if (clone.sessionId === null) {
    throw new Error('Vpn proxy commands require a non-null running session identity.');
  }
  return clone;
}

function requireSafePositiveInteger(value: number, label: string): number {
  if (!Number.isInteger(value) || value <= 0 || value > Number.MAX_SAFE_INTEGER) {
    throw new Error(`${label} must be a safe positive integer.`);
  }
  return value;
}

function cloneStringArray(values: string[]): string[] {
  const copy: string[] = [];
  for (let index: number = 0; index < values.length; index += 1) {
    copy.push(values[index]);
  }
  return copy;
}

export function cloneVpnProxyGroupPath(groupPath: string[] | undefined, groupName: string): string[] {
  const normalizedGroupName: string = normalizeProxyLabel(groupName, 'Proxy group name');
  const source: string[] = groupPath === undefined ? [normalizedGroupName] : cloneStringArray(groupPath);
  if (source.length < 1 || source.length > 16) {
    throw new Error('Proxy command path must contain between 1 and 16 segments.');
  }
  const normalizedPath: string[] = [];
  for (let index: number = 0; index < source.length; index += 1) {
    normalizedPath.push(normalizeProxyLabel(source[index], 'Proxy groupPath segment'));
  }
  if (normalizedPath[normalizedPath.length - 1] !== normalizedGroupName) {
    throw new Error('Proxy command path terminal segment must match the requested target.');
  }
  return normalizedPath;
}

export function createVpnProxyQueryGroupsCommand(
  identity: ProxyRuntimeIdentity,
  generation: number,
  selectableOnly: boolean
): VpnProxyQueryGroupsCommand {
  return {
    identity: requireRunningIdentity(identity),
    generation: requireSafePositiveInteger(generation, 'Proxy generation'),
    selectableOnly
  };
}

export function cloneVpnProxyQueryGroupsCommand(command: VpnProxyQueryGroupsCommand): VpnProxyQueryGroupsCommand {
  return createVpnProxyQueryGroupsCommand(command.identity, command.generation, command.selectableOnly);
}

export function createVpnProxyQueryGroupCommand(
  identity: ProxyRuntimeIdentity,
  generation: number,
  groupName: string,
  groupPath: string[] | undefined = undefined
): VpnProxyQueryGroupCommand {
  const normalizedGroupName: string = normalizeProxyLabel(groupName, 'Proxy group name');
  return {
    identity: requireRunningIdentity(identity),
    generation: requireSafePositiveInteger(generation, 'Proxy generation'),
    groupName: normalizedGroupName,
    groupPath: cloneVpnProxyGroupPath(groupPath, normalizedGroupName)
  };
}

export function cloneVpnProxyQueryGroupCommand(command: VpnProxyQueryGroupCommand): VpnProxyQueryGroupCommand {
  return createVpnProxyQueryGroupCommand(command.identity, command.generation, command.groupName, command.groupPath);
}

export function createVpnProxySelectCommand(
  identity: ProxyRuntimeIdentity,
  generation: number,
  groupName: string,
  memberName: string,
  groupPath: string[] | undefined = undefined
): VpnProxySelectCommand {
  const normalizedGroupName: string = normalizeProxyLabel(groupName, 'Proxy group name');
  return {
    identity: requireRunningIdentity(identity),
    generation: requireSafePositiveInteger(generation, 'Proxy generation'),
    groupName: normalizedGroupName,
    groupPath: cloneVpnProxyGroupPath(groupPath, normalizedGroupName),
    memberName: normalizeProxyLabel(memberName, 'Proxy selected node name')
  };
}

export function cloneVpnProxySelectCommand(command: VpnProxySelectCommand): VpnProxySelectCommand {
  return createVpnProxySelectCommand(
    command.identity,
    command.generation,
    command.groupName,
    command.memberName,
    command.groupPath
  );
}

export function createVpnProxyStartDelayTestCommand(
  identity: ProxyRuntimeIdentity,
  generation: number,
  groupName: string,
  groupPath: string[] | undefined = undefined
): VpnProxyStartDelayTestCommand {
  const normalizedGroupName: string = normalizeProxyLabel(groupName, 'Proxy group name');
  return {
    identity: requireRunningIdentity(identity),
    generation: requireSafePositiveInteger(generation, 'Proxy generation'),
    groupName: normalizedGroupName,
    groupPath: cloneVpnProxyGroupPath(groupPath, normalizedGroupName)
  };
}

export function cloneVpnProxyStartDelayTestCommand(
  command: VpnProxyStartDelayTestCommand
): VpnProxyStartDelayTestCommand {
  return createVpnProxyStartDelayTestCommand(command.identity, command.generation, command.groupName, command.groupPath);
}

export function createVpnProxyReadDelayTestCommand(
  identity: ProxyRuntimeIdentity,
  generation: number,
  jobId: string
): VpnProxyReadDelayTestCommand {
  return {
    identity: requireRunningIdentity(identity),
    generation: requireSafePositiveInteger(generation, 'Proxy generation'),
    jobId: normalizeProxyDelayJobId(jobId)
  };
}

export function cloneVpnProxyReadDelayTestCommand(
  command: VpnProxyReadDelayTestCommand
): VpnProxyReadDelayTestCommand {
  return createVpnProxyReadDelayTestCommand(command.identity, command.generation, command.jobId);
}

export function createVpnProxyCancelDelayTestCommand(
  identity: ProxyRuntimeIdentity,
  generation: number,
  jobId: string
): VpnProxyCancelDelayTestCommand {
  return {
    identity: requireRunningIdentity(identity),
    generation: requireSafePositiveInteger(generation, 'Proxy generation'),
    jobId: normalizeProxyDelayJobId(jobId)
  };
}

export function cloneVpnProxyCancelDelayTestCommand(
  command: VpnProxyCancelDelayTestCommand
): VpnProxyCancelDelayTestCommand {
  return createVpnProxyCancelDelayTestCommand(command.identity, command.generation, command.jobId);
}
