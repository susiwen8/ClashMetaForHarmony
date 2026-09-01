import type { CoreProxyType } from '../../core/CoreProxyModels';
import type { CoreRuntimeMode } from '../../core/CoreModels';
import {
  VPN_FAILURE_CODES,
  VPN_RUNTIME_STATES,
  type VpnFailureCode,
  type VpnRuntimeState
} from '../VpnModels';

const HASH_64_PATTERN: RegExp = /^[0-9a-f]{64}$/u;
const HASH_32_PATTERN: RegExp = /^[0-9a-f]{32}$/u;
const PROXY_TYPES: CoreProxyType[] = [
  'Direct',
  'Reject',
  'RejectDrop',
  'Compatible',
  'Pass',
  'PassRule',
  'Rematch',
  'Dns',
  'Relay',
  'Selector',
  'Fallback',
  'URLTest',
  'LoadBalance',
  'Shadowsocks',
  'ShadowsocksR',
  'Snell',
  'Socks5',
  'Http',
  'Vmess',
  'Vless',
  'Trojan',
  'Hysteria',
  'Hysteria2',
  'WireGuard',
  'Tuic',
  'Ssh',
  'Mieru',
  'AnyTLS',
  'Sudoku',
  'Masque',
  'TrustTunnel',
  'ShadowQuic',
  'OpenVPN',
  'Tailscale',
  'GostRelay'
];

export type VpnRpcDelayStatus = 'WAITING' | 'TESTING' | 'AVAILABLE' | 'TIMEOUT' | 'FAILED' | 'CANCELLED' | 'UNSUPPORTED';
export type VpnRpcDelayJobState = 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED';
export type VpnRpcNodeKind = 'GROUP' | 'TERMINAL';

export const VPN_RPC_DELAY_STATUSES: VpnRpcDelayStatus[] = [
  'WAITING',
  'TESTING',
  'AVAILABLE',
  'TIMEOUT',
  'FAILED',
  'CANCELLED',
  'UNSUPPORTED'
];

export interface VpnRpcRuntimeSnapshotPayload {
  state: VpnRuntimeState;
  profileHash: string | null;
  revisionHash: string | null;
  catalogDigest: string | null;
  notificationActive: boolean;
  recoveryAttempt: number;
  scheduledRetryDelayMs: number | null;
  runtimeFailureCode: VpnFailureCode | null;
  txBytes: number;
  rxBytes: number;
}

export interface VpnRpcGroupRef {
  groupId: string;
  type: CoreProxyType;
  isSelectable: boolean;
}

export interface VpnRpcGroupNode {
  nodeId: string;
  kind: VpnRpcNodeKind;
  type: CoreProxyType;
  selected: boolean;
}

export interface VpnRpcDelayResult {
  nodeId: string;
  status: VpnRpcDelayStatus;
  delayMs: number | null;
}

export interface VpnRpcDelaySnapshotPayload {
  jobId: string;
  delayRevision: number;
  proxyGeneration: number;
  groupId: string;
  state: VpnRpcDelayJobState;
  totalCount: number;
  completedCount: number;
  results: VpnRpcDelayResult[];
}

export interface VpnRpcEmptyPayload {}
export interface VpnRpcRuntimeModePayload { mode: CoreRuntimeMode; }
export interface VpnRpcPingSuccessPayload { serverInstance: string; }
export interface VpnRpcCatalogDigestPayload { catalogDigest: string; entryCount: number; }
export interface VpnRpcQueryGroupRequestPayload { groupId: string; }
export interface VpnRpcSelectNodeRequestPayload { proxyGeneration: number; groupId: string; nodeId: string; }
export interface VpnRpcDelayGroupRequestPayload { proxyGeneration: number; groupId: string; }
export interface VpnRpcDelayJobRequestPayload { jobId: string; }
export interface VpnRpcQueryGroupsPayload { proxyGeneration: number; groups: VpnRpcGroupRef[]; }
export interface VpnRpcQueryGroupPayload { proxyGeneration: number; groupId: string; selectedNodeId: string | null; nodes: VpnRpcGroupNode[]; }
export interface VpnRpcSelectNodeResultPayload { proxyGeneration: number; groupId: string; selectedNodeId: string | null; persisted: boolean; }

export type VpnRpcPayload =
  | VpnRpcEmptyPayload
  | VpnRpcRuntimeModePayload
  | VpnRpcPingSuccessPayload
  | VpnRpcRuntimeSnapshotPayload
  | VpnRpcCatalogDigestPayload
  | VpnRpcQueryGroupRequestPayload
  | VpnRpcSelectNodeRequestPayload
  | VpnRpcDelayGroupRequestPayload
  | VpnRpcDelayJobRequestPayload
  | VpnRpcQueryGroupsPayload
  | VpnRpcQueryGroupPayload
  | VpnRpcSelectNodeResultPayload
  | VpnRpcDelaySnapshotPayload;

class VpnRpcRuntimeSnapshotPayloadValue implements VpnRpcRuntimeSnapshotPayload {
  state: VpnRuntimeState = 'STOPPED';
  profileHash: string | null = null;
  revisionHash: string | null = null;
  catalogDigest: string | null = null;
  notificationActive: boolean = false;
  recoveryAttempt: number = 0;
  scheduledRetryDelayMs: number | null = null;
  runtimeFailureCode: VpnFailureCode | null = null;
  txBytes: number = 0;
  rxBytes: number = 0;
}

class VpnRpcGroupRefValue implements VpnRpcGroupRef {
  groupId: string = '';
  type: CoreProxyType = 'Direct';
  isSelectable: boolean = false;
}

class VpnRpcGroupNodeValue implements VpnRpcGroupNode {
  nodeId: string = '';
  kind: VpnRpcNodeKind = 'TERMINAL';
  type: CoreProxyType = 'Direct';
  selected: boolean = false;
}

class VpnRpcDelayResultValue implements VpnRpcDelayResult {
  nodeId: string = '';
  status: VpnRpcDelayStatus = 'WAITING';
  delayMs: number | null = null;
}

class VpnRpcDelaySnapshotPayloadValue implements VpnRpcDelaySnapshotPayload {
  jobId: string = '';
  delayRevision: number = 0;
  proxyGeneration: number = 0;
  groupId: string = '';
  state: VpnRpcDelayJobState = 'RUNNING';
  totalCount: number = 0;
  completedCount: number = 0;
  results: VpnRpcDelayResult[] = [];
}

class VpnRpcEmptyPayloadValue implements VpnRpcEmptyPayload {}
class VpnRpcRuntimeModePayloadValue implements VpnRpcRuntimeModePayload { mode: CoreRuntimeMode = 'RULE'; }
class VpnRpcPingSuccessPayloadValue implements VpnRpcPingSuccessPayload { serverInstance: string = ''; }
class VpnRpcCatalogDigestPayloadValue implements VpnRpcCatalogDigestPayload { catalogDigest: string = ''; entryCount: number = 0; }
class VpnRpcQueryGroupRequestPayloadValue implements VpnRpcQueryGroupRequestPayload { groupId: string = ''; }
class VpnRpcSelectNodeRequestPayloadValue implements VpnRpcSelectNodeRequestPayload { proxyGeneration: number = 0; groupId: string = ''; nodeId: string = ''; }
class VpnRpcDelayGroupRequestPayloadValue implements VpnRpcDelayGroupRequestPayload { proxyGeneration: number = 0; groupId: string = ''; }
class VpnRpcDelayJobRequestPayloadValue implements VpnRpcDelayJobRequestPayload { jobId: string = ''; }
class VpnRpcQueryGroupsPayloadValue implements VpnRpcQueryGroupsPayload { proxyGeneration: number = 0; groups: VpnRpcGroupRef[] = []; }
class VpnRpcQueryGroupPayloadValue implements VpnRpcQueryGroupPayload { proxyGeneration: number = 0; groupId: string = ''; selectedNodeId: string | null = null; nodes: VpnRpcGroupNode[] = []; }
class VpnRpcSelectNodeResultPayloadValue implements VpnRpcSelectNodeResultPayload { proxyGeneration: number = 0; groupId: string = ''; selectedNodeId: string | null = null; persisted: boolean = false; }

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

function requireHash64(rawValue: string, label: string): string {
  if (!HASH_64_PATTERN.test(rawValue)) {
    throw new Error(`${label} must be exactly 64 lowercase hex characters.`);
  }
  return rawValue;
}

function requireHash32(rawValue: string, label: string): string {
  if (!HASH_32_PATTERN.test(rawValue)) {
    throw new Error(`${label} must be exactly 32 lowercase hex characters.`);
  }
  return rawValue;
}

function normalizeNullableHash(rawValue: string | null, label: string): string | null {
  return rawValue === null ? null : requireHash64(rawValue, label);
}

function requireProxyType(rawValue: string, label: string): CoreProxyType {
  for (let index: number = 0; index < PROXY_TYPES.length; index += 1) {
    if (PROXY_TYPES[index] === rawValue) {
      return PROXY_TYPES[index];
    }
  }
  throw new Error(`${label} must stay inside the closed proxy type contract.`);
}

function requireRuntimeState(rawValue: string): VpnRuntimeState {
  for (let index: number = 0; index < VPN_RUNTIME_STATES.length; index += 1) {
    if (VPN_RUNTIME_STATES[index] === rawValue) {
      return VPN_RUNTIME_STATES[index];
    }
  }
  throw new Error('VpnRpcRuntimeSnapshotPayload state must stay inside the closed VpnRuntimeState contract.');
}

function requireRuntimeFailureCode(rawValue: string | null): VpnFailureCode | null {
  if (rawValue === null) {
    return null;
  }
  for (let index: number = 0; index < VPN_FAILURE_CODES.length; index += 1) {
    if (VPN_FAILURE_CODES[index] === rawValue) {
      return VPN_FAILURE_CODES[index];
    }
  }
  throw new Error('VpnRpcRuntimeSnapshotPayload runtimeFailureCode must stay inside the closed VpnFailureCode contract.');
}

function requireDelayStatus(rawValue: string): VpnRpcDelayStatus {
  switch (rawValue) {
    case 'WAITING':
    case 'TESTING':
    case 'AVAILABLE':
    case 'TIMEOUT':
    case 'FAILED':
    case 'CANCELLED':
    case 'UNSUPPORTED':
      return rawValue;
    default:
      throw new Error('VpnRpcDelayResult status must stay inside the closed delay status contract.');
  }
}

function requireDelayJobState(rawValue: string): VpnRpcDelayJobState {
  switch (rawValue) {
    case 'RUNNING':
    case 'COMPLETED':
    case 'CANCELLED':
    case 'FAILED':
      return rawValue;
    default:
      throw new Error('VpnRpcDelaySnapshotPayload state must stay inside the closed delay job state contract.');
  }
}

function requireNodeKind(rawValue: string): VpnRpcNodeKind {
  switch (rawValue) {
    case 'GROUP':
    case 'TERMINAL':
      return rawValue;
    default:
      throw new Error('VpnRpcGroupNode kind must stay inside the closed node kind contract.');
  }
}

function requireRuntimeMode(rawValue: string): CoreRuntimeMode {
  switch (rawValue) {
    case 'RULE':
    case 'GLOBAL':
    case 'DIRECT':
      return rawValue;
    default:
      throw new Error('VpnRpcRuntimeModePayload mode must stay inside the closed runtime mode contract.');
  }
}

function countCompletedDelayResults(results: VpnRpcDelayResult[]): number {
  let completed: number = 0;
  for (let index: number = 0; index < results.length; index += 1) {
    const status: VpnRpcDelayStatus = results[index].status;
    if (status === 'AVAILABLE' || status === 'TIMEOUT' || status === 'FAILED' || status === 'CANCELLED' || status === 'UNSUPPORTED') {
      completed += 1;
    }
  }
  return completed;
}

export function listVpnRpcDelayStatuses(): VpnRpcDelayStatus[] {
  return VPN_RPC_DELAY_STATUSES.slice();
}

export function createVpnRpcRuntimeSnapshotPayload(
  state: string,
  profileHash: string | null,
  revisionHash: string | null,
  catalogDigest: string | null,
  notificationActive: boolean,
  recoveryAttempt: number,
  scheduledRetryDelayMs: number | null,
  runtimeFailureCode: string | null,
  txBytes: number,
  rxBytes: number
): VpnRpcRuntimeSnapshotPayload {
  const payload = new VpnRpcRuntimeSnapshotPayloadValue();
  payload.state = requireRuntimeState(state);
  payload.profileHash = normalizeNullableHash(profileHash, 'VpnRpcRuntimeSnapshotPayload profileHash');
  payload.revisionHash = normalizeNullableHash(revisionHash, 'VpnRpcRuntimeSnapshotPayload revisionHash');
  payload.catalogDigest = normalizeNullableHash(catalogDigest, 'VpnRpcRuntimeSnapshotPayload catalogDigest');
  if ((payload.profileHash === null) !== (payload.revisionHash === null) || (payload.profileHash === null) !== (payload.catalogDigest === null)) {
    throw new Error('VpnRpcRuntimeSnapshotPayload profile/revision/catalog hashes must be all present or all null.');
  }
  payload.notificationActive = notificationActive;
  payload.recoveryAttempt = requireSafeNonNegativeInteger(recoveryAttempt, 'VpnRpcRuntimeSnapshotPayload recoveryAttempt');
  payload.scheduledRetryDelayMs = scheduledRetryDelayMs === null
    ? null
    : requireSafePositiveInteger(scheduledRetryDelayMs, 'VpnRpcRuntimeSnapshotPayload scheduledRetryDelayMs');
  payload.runtimeFailureCode = requireRuntimeFailureCode(runtimeFailureCode);
  payload.txBytes = requireSafeNonNegativeInteger(txBytes, 'VpnRpcRuntimeSnapshotPayload txBytes');
  payload.rxBytes = requireSafeNonNegativeInteger(rxBytes, 'VpnRpcRuntimeSnapshotPayload rxBytes');
  return payload;
}

export function cloneVpnRpcRuntimeSnapshotPayload(payload: VpnRpcRuntimeSnapshotPayload): VpnRpcRuntimeSnapshotPayload {
  if (!(payload instanceof VpnRpcRuntimeSnapshotPayloadValue)) {
    throw new Error('VpnRpcRuntimeSnapshotPayload values must come from createVpnRpcRuntimeSnapshotPayload.');
  }
  return createVpnRpcRuntimeSnapshotPayload(
    payload.state,
    payload.profileHash,
    payload.revisionHash,
    payload.catalogDigest,
    payload.notificationActive,
    payload.recoveryAttempt,
    payload.scheduledRetryDelayMs,
    payload.runtimeFailureCode,
    payload.txBytes,
    payload.rxBytes
  );
}

export function createVpnRpcGroupRef(groupId: string, type: string, isSelectable: boolean): VpnRpcGroupRef {
  const payload = new VpnRpcGroupRefValue();
  payload.groupId = requireHash64(groupId, 'VpnRpcGroupRef groupId');
  payload.type = requireProxyType(type, 'VpnRpcGroupRef type');
  payload.isSelectable = isSelectable;
  return payload;
}

export function cloneVpnRpcGroupRef(payload: VpnRpcGroupRef): VpnRpcGroupRef {
  if (!(payload instanceof VpnRpcGroupRefValue)) {
    throw new Error('VpnRpcGroupRef values must come from createVpnRpcGroupRef.');
  }
  return createVpnRpcGroupRef(payload.groupId, payload.type, payload.isSelectable);
}

export function createVpnRpcGroupNode(nodeId: string, kind: string, type: string, selected: boolean): VpnRpcGroupNode {
  const payload = new VpnRpcGroupNodeValue();
  payload.nodeId = requireHash64(nodeId, 'VpnRpcGroupNode nodeId');
  payload.kind = requireNodeKind(kind);
  payload.type = requireProxyType(type, 'VpnRpcGroupNode type');
  payload.selected = selected;
  return payload;
}

export function cloneVpnRpcGroupNode(payload: VpnRpcGroupNode): VpnRpcGroupNode {
  if (!(payload instanceof VpnRpcGroupNodeValue)) {
    throw new Error('VpnRpcGroupNode values must come from createVpnRpcGroupNode.');
  }
  return createVpnRpcGroupNode(payload.nodeId, payload.kind, payload.type, payload.selected);
}

export function createVpnRpcDelayResult(nodeId: string, status: string, delayMs: number | null): VpnRpcDelayResult {
  const payload = new VpnRpcDelayResultValue();
  payload.nodeId = requireHash64(nodeId, 'VpnRpcDelayResult nodeId');
  payload.status = requireDelayStatus(status);
  payload.delayMs = delayMs === null ? null : requireSafePositiveInteger(delayMs, 'VpnRpcDelayResult delayMs');
  if (payload.status === 'AVAILABLE') {
    if (payload.delayMs === null) {
      throw new Error('AVAILABLE VpnRpcDelayResult values require delayMs.');
    }
  } else if (payload.delayMs !== null) {
    throw new Error('Non-AVAILABLE VpnRpcDelayResult values must not publish delayMs.');
  }
  return payload;
}

export function cloneVpnRpcDelayResult(payload: VpnRpcDelayResult): VpnRpcDelayResult {
  if (!(payload instanceof VpnRpcDelayResultValue)) {
    throw new Error('VpnRpcDelayResult values must come from createVpnRpcDelayResult.');
  }
  return createVpnRpcDelayResult(payload.nodeId, payload.status, payload.delayMs);
}

export function createVpnRpcDelaySnapshotPayload(
  jobId: string,
  delayRevision: number,
  proxyGeneration: number,
  groupId: string,
  state: string,
  totalCount: number,
  completedCount: number,
  results: VpnRpcDelayResult[]
): VpnRpcDelaySnapshotPayload {
  const payload = new VpnRpcDelaySnapshotPayloadValue();
  payload.jobId = requireHash64(jobId, 'VpnRpcDelaySnapshotPayload jobId');
  payload.delayRevision = requireSafePositiveInteger(delayRevision, 'VpnRpcDelaySnapshotPayload delayRevision');
  payload.proxyGeneration = requireSafePositiveInteger(proxyGeneration, 'VpnRpcDelaySnapshotPayload proxyGeneration');
  payload.groupId = requireHash64(groupId, 'VpnRpcDelaySnapshotPayload groupId');
  payload.state = requireDelayJobState(state);
  payload.totalCount = requireSafeNonNegativeInteger(totalCount, 'VpnRpcDelaySnapshotPayload totalCount');
  payload.completedCount = requireSafeNonNegativeInteger(completedCount, 'VpnRpcDelaySnapshotPayload completedCount');
  const clonedResults: VpnRpcDelayResult[] = [];
  for (let index: number = 0; index < results.length; index += 1) {
    clonedResults.push(cloneVpnRpcDelayResult(results[index]));
  }
  payload.results = clonedResults;
  if (payload.results.length !== payload.totalCount) {
    throw new Error('VpnRpcDelaySnapshotPayload results length must match totalCount.');
  }
  if (countCompletedDelayResults(payload.results) !== payload.completedCount) {
    throw new Error('VpnRpcDelaySnapshotPayload completedCount must match terminal result count.');
  }
  return payload;
}

export function cloneVpnRpcDelaySnapshotPayload(payload: VpnRpcDelaySnapshotPayload): VpnRpcDelaySnapshotPayload {
  if (!(payload instanceof VpnRpcDelaySnapshotPayloadValue)) {
    throw new Error('VpnRpcDelaySnapshotPayload values must come from createVpnRpcDelaySnapshotPayload.');
  }
  return createVpnRpcDelaySnapshotPayload(
    payload.jobId,
    payload.delayRevision,
    payload.proxyGeneration,
    payload.groupId,
    payload.state,
    payload.totalCount,
    payload.completedCount,
    payload.results
  );
}

export function createVpnRpcEmptyPayload(): VpnRpcEmptyPayload {
  return new VpnRpcEmptyPayloadValue();
}

export function createVpnRpcRuntimeModePayload(mode: string): VpnRpcRuntimeModePayload {
  const payload = new VpnRpcRuntimeModePayloadValue();
  payload.mode = requireRuntimeMode(mode);
  return payload;
}

export function cloneVpnRpcRuntimeModePayload(payload: VpnRpcRuntimeModePayload): VpnRpcRuntimeModePayload {
  if (!(payload instanceof VpnRpcRuntimeModePayloadValue)) {
    throw new Error('VpnRpcRuntimeModePayload values must come from createVpnRpcRuntimeModePayload.');
  }
  return createVpnRpcRuntimeModePayload(payload.mode);
}

export function cloneVpnRpcEmptyPayload(payload: VpnRpcPayload): VpnRpcEmptyPayload {
  if (!(payload instanceof VpnRpcEmptyPayloadValue)) {
    throw new Error('Empty VpnRpcPayload values must come from createVpnRpcEmptyPayload.');
  }
  return new VpnRpcEmptyPayloadValue();
}

export function createVpnRpcPingSuccessPayload(serverInstance: string): VpnRpcPingSuccessPayload {
  const payload = new VpnRpcPingSuccessPayloadValue();
  payload.serverInstance = requireHash32(serverInstance, 'VpnRpcPingSuccessPayload serverInstance');
  return payload;
}

export function cloneVpnRpcPingSuccessPayload(payload: VpnRpcPingSuccessPayload): VpnRpcPingSuccessPayload {
  if (!(payload instanceof VpnRpcPingSuccessPayloadValue)) {
    throw new Error('VpnRpcPingSuccessPayload values must come from createVpnRpcPingSuccessPayload.');
  }
  return createVpnRpcPingSuccessPayload(payload.serverInstance);
}

export function createVpnRpcCatalogDigestPayload(catalogDigest: string, entryCount: number): VpnRpcCatalogDigestPayload {
  const payload = new VpnRpcCatalogDigestPayloadValue();
  payload.catalogDigest = requireHash64(catalogDigest, 'VpnRpcCatalogDigestPayload catalogDigest');
  payload.entryCount = requireSafeNonNegativeInteger(entryCount, 'VpnRpcCatalogDigestPayload entryCount');
  return payload;
}

export function cloneVpnRpcCatalogDigestPayload(payload: VpnRpcCatalogDigestPayload): VpnRpcCatalogDigestPayload {
  if (!(payload instanceof VpnRpcCatalogDigestPayloadValue)) {
    throw new Error('VpnRpcCatalogDigestPayload values must come from createVpnRpcCatalogDigestPayload.');
  }
  return createVpnRpcCatalogDigestPayload(payload.catalogDigest, payload.entryCount);
}

export function createVpnRpcQueryGroupRequestPayload(groupId: string): VpnRpcQueryGroupRequestPayload {
  const payload = new VpnRpcQueryGroupRequestPayloadValue();
  payload.groupId = requireHash64(groupId, 'VpnRpcQueryGroupRequestPayload groupId');
  return payload;
}

export function cloneVpnRpcQueryGroupRequestPayload(payload: VpnRpcQueryGroupRequestPayload): VpnRpcQueryGroupRequestPayload {
  if (!(payload instanceof VpnRpcQueryGroupRequestPayloadValue)) {
    throw new Error('VpnRpcQueryGroupRequestPayload values must come from createVpnRpcQueryGroupRequestPayload.');
  }
  return createVpnRpcQueryGroupRequestPayload(payload.groupId);
}

export function createVpnRpcSelectNodeRequestPayload(proxyGeneration: number, groupId: string, nodeId: string): VpnRpcSelectNodeRequestPayload {
  const payload = new VpnRpcSelectNodeRequestPayloadValue();
  payload.proxyGeneration = requireSafePositiveInteger(proxyGeneration, 'VpnRpcSelectNodeRequestPayload proxyGeneration');
  payload.groupId = requireHash64(groupId, 'VpnRpcSelectNodeRequestPayload groupId');
  payload.nodeId = requireHash64(nodeId, 'VpnRpcSelectNodeRequestPayload nodeId');
  return payload;
}

export function cloneVpnRpcSelectNodeRequestPayload(payload: VpnRpcSelectNodeRequestPayload): VpnRpcSelectNodeRequestPayload {
  if (!(payload instanceof VpnRpcSelectNodeRequestPayloadValue)) {
    throw new Error('VpnRpcSelectNodeRequestPayload values must come from createVpnRpcSelectNodeRequestPayload.');
  }
  return createVpnRpcSelectNodeRequestPayload(payload.proxyGeneration, payload.groupId, payload.nodeId);
}

export function createVpnRpcDelayGroupRequestPayload(proxyGeneration: number, groupId: string): VpnRpcDelayGroupRequestPayload {
  const payload = new VpnRpcDelayGroupRequestPayloadValue();
  payload.proxyGeneration = requireSafePositiveInteger(proxyGeneration, 'VpnRpcDelayGroupRequestPayload proxyGeneration');
  payload.groupId = requireHash64(groupId, 'VpnRpcDelayGroupRequestPayload groupId');
  return payload;
}

export function cloneVpnRpcDelayGroupRequestPayload(payload: VpnRpcDelayGroupRequestPayload): VpnRpcDelayGroupRequestPayload {
  if (!(payload instanceof VpnRpcDelayGroupRequestPayloadValue)) {
    throw new Error('VpnRpcDelayGroupRequestPayload values must come from createVpnRpcDelayGroupRequestPayload.');
  }
  return createVpnRpcDelayGroupRequestPayload(payload.proxyGeneration, payload.groupId);
}

export function createVpnRpcDelayJobRequestPayload(jobId: string): VpnRpcDelayJobRequestPayload {
  const payload = new VpnRpcDelayJobRequestPayloadValue();
  payload.jobId = requireHash64(jobId, 'VpnRpcDelayJobRequestPayload jobId');
  return payload;
}

export function cloneVpnRpcDelayJobRequestPayload(payload: VpnRpcDelayJobRequestPayload): VpnRpcDelayJobRequestPayload {
  if (!(payload instanceof VpnRpcDelayJobRequestPayloadValue)) {
    throw new Error('VpnRpcDelayJobRequestPayload values must come from createVpnRpcDelayJobRequestPayload.');
  }
  return createVpnRpcDelayJobRequestPayload(payload.jobId);
}

export function createVpnRpcQueryGroupsPayload(proxyGeneration: number, groups: VpnRpcGroupRef[]): VpnRpcQueryGroupsPayload {
  const payload = new VpnRpcQueryGroupsPayloadValue();
  payload.proxyGeneration = requireSafePositiveInteger(proxyGeneration, 'VpnRpcQueryGroupsPayload proxyGeneration');
  const clonedGroups: VpnRpcGroupRef[] = [];
  for (let index: number = 0; index < groups.length; index += 1) {
    clonedGroups.push(cloneVpnRpcGroupRef(groups[index]));
  }
  payload.groups = clonedGroups;
  return payload;
}

export function cloneVpnRpcQueryGroupsPayload(payload: VpnRpcQueryGroupsPayload): VpnRpcQueryGroupsPayload {
  if (!(payload instanceof VpnRpcQueryGroupsPayloadValue)) {
    throw new Error('VpnRpcQueryGroupsPayload values must come from createVpnRpcQueryGroupsPayload.');
  }
  return createVpnRpcQueryGroupsPayload(payload.proxyGeneration, payload.groups);
}

export function createVpnRpcQueryGroupPayload(
  proxyGeneration: number,
  groupId: string,
  selectedNodeId: string | null,
  nodes: VpnRpcGroupNode[]
): VpnRpcQueryGroupPayload {
  const payload = new VpnRpcQueryGroupPayloadValue();
  payload.proxyGeneration = requireSafePositiveInteger(proxyGeneration, 'VpnRpcQueryGroupPayload proxyGeneration');
  payload.groupId = requireHash64(groupId, 'VpnRpcQueryGroupPayload groupId');
  payload.selectedNodeId = selectedNodeId === null ? null : requireHash64(selectedNodeId, 'VpnRpcQueryGroupPayload selectedNodeId');
  const clonedNodes: VpnRpcGroupNode[] = [];
  let selectedCount: number = 0;
  for (let index: number = 0; index < nodes.length; index += 1) {
    const clonedNode: VpnRpcGroupNode = cloneVpnRpcGroupNode(nodes[index]);
    if (clonedNode.selected) {
      selectedCount += 1;
      if (payload.selectedNodeId !== clonedNode.nodeId) {
        throw new Error('VpnRpcQueryGroupPayload selectedNodeId must match the selected node.');
      }
    }
    clonedNodes.push(clonedNode);
  }
  if (payload.selectedNodeId === null && selectedCount !== 0) {
    throw new Error('VpnRpcQueryGroupPayload selectedNodeId must be null when no node is selected.');
  }
  if (payload.selectedNodeId !== null && selectedCount !== 1) {
    throw new Error('VpnRpcQueryGroupPayload selectedNodeId requires exactly one selected node.');
  }
  payload.nodes = clonedNodes;
  return payload;
}

export function cloneVpnRpcQueryGroupPayload(payload: VpnRpcQueryGroupPayload): VpnRpcQueryGroupPayload {
  if (!(payload instanceof VpnRpcQueryGroupPayloadValue)) {
    throw new Error('VpnRpcQueryGroupPayload values must come from createVpnRpcQueryGroupPayload.');
  }
  return createVpnRpcQueryGroupPayload(payload.proxyGeneration, payload.groupId, payload.selectedNodeId, payload.nodes);
}

export function createVpnRpcSelectNodeResultPayload(
  proxyGeneration: number,
  groupId: string,
  selectedNodeId: string | null,
  persisted: boolean
): VpnRpcSelectNodeResultPayload {
  const payload = new VpnRpcSelectNodeResultPayloadValue();
  payload.proxyGeneration = requireSafePositiveInteger(proxyGeneration, 'VpnRpcSelectNodeResultPayload proxyGeneration');
  payload.groupId = requireHash64(groupId, 'VpnRpcSelectNodeResultPayload groupId');
  payload.selectedNodeId = selectedNodeId === null ? null : requireHash64(selectedNodeId, 'VpnRpcSelectNodeResultPayload selectedNodeId');
  payload.persisted = persisted;
  return payload;
}

export function cloneVpnRpcSelectNodeResultPayload(payload: VpnRpcSelectNodeResultPayload): VpnRpcSelectNodeResultPayload {
  if (!(payload instanceof VpnRpcSelectNodeResultPayloadValue)) {
    throw new Error('VpnRpcSelectNodeResultPayload values must come from createVpnRpcSelectNodeResultPayload.');
  }
  return createVpnRpcSelectNodeResultPayload(payload.proxyGeneration, payload.groupId, payload.selectedNodeId, payload.persisted);
}

export function cloneVpnRpcPayloadForEnvelope(kind: string, method: string, ok: boolean | null, payload: VpnRpcPayload): VpnRpcPayload {
  if (kind === 'REQUEST') {
    switch (method) {
      case 'PING':
      case 'GET_SNAPSHOT':
      case 'GET_CATALOG_DIGEST':
      case 'GET_MODE':
      case 'QUERY_GROUPS':
      case 'STOP_VPN':
        return cloneVpnRpcEmptyPayload(payload);
      case 'SET_MODE':
        return cloneVpnRpcRuntimeModePayload(payload as VpnRpcRuntimeModePayload);
      case 'QUERY_GROUP':
        return cloneVpnRpcQueryGroupRequestPayload(payload as VpnRpcQueryGroupRequestPayload);
      case 'SELECT_NODE':
        return cloneVpnRpcSelectNodeRequestPayload(payload as VpnRpcSelectNodeRequestPayload);
      case 'START_DELAY_TEST':
        return cloneVpnRpcDelayGroupRequestPayload(payload as VpnRpcDelayGroupRequestPayload);
      case 'READ_DELAY_TEST':
      case 'CANCEL_DELAY_TEST':
        return cloneVpnRpcDelayJobRequestPayload(payload as VpnRpcDelayJobRequestPayload);
      default:
        throw new Error(`Unsupported REQUEST method ${method}.`);
    }
  }
  if (kind === 'EVENT') {
    switch (method) {
      case 'RUNTIME_CHANGED':
        return cloneVpnRpcRuntimeSnapshotPayload(payload as VpnRpcRuntimeSnapshotPayload);
      case 'DELAY_CHANGED':
        return cloneVpnRpcDelaySnapshotPayload(payload as VpnRpcDelaySnapshotPayload);
      case 'SERVER_STOPPING':
        return cloneVpnRpcEmptyPayload(payload);
      default:
        throw new Error(`Unsupported EVENT method ${method}.`);
    }
  }
  if (ok === true) {
    switch (method) {
      case 'PING':
        return cloneVpnRpcPingSuccessPayload(payload as VpnRpcPingSuccessPayload);
      case 'GET_SNAPSHOT':
      case 'STOP_VPN':
        return cloneVpnRpcRuntimeSnapshotPayload(payload as VpnRpcRuntimeSnapshotPayload);
      case 'GET_CATALOG_DIGEST':
        return cloneVpnRpcCatalogDigestPayload(payload as VpnRpcCatalogDigestPayload);
      case 'GET_MODE':
      case 'SET_MODE':
        return cloneVpnRpcRuntimeModePayload(payload as VpnRpcRuntimeModePayload);
      case 'QUERY_GROUPS':
        return cloneVpnRpcQueryGroupsPayload(payload as VpnRpcQueryGroupsPayload);
      case 'QUERY_GROUP':
        return cloneVpnRpcQueryGroupPayload(payload as VpnRpcQueryGroupPayload);
      case 'SELECT_NODE':
        return cloneVpnRpcSelectNodeResultPayload(payload as VpnRpcSelectNodeResultPayload);
      case 'START_DELAY_TEST':
      case 'READ_DELAY_TEST':
      case 'CANCEL_DELAY_TEST':
        return cloneVpnRpcDelaySnapshotPayload(payload as VpnRpcDelaySnapshotPayload);
      default:
        throw new Error(`Unsupported RESPONSE method ${method}.`);
    }
  }
  if (ok === false) {
    switch (method) {
      case 'PING':
      case 'GET_SNAPSHOT':
      case 'GET_CATALOG_DIGEST':
      case 'GET_MODE':
      case 'SET_MODE':
      case 'QUERY_GROUPS':
      case 'QUERY_GROUP':
      case 'SELECT_NODE':
      case 'START_DELAY_TEST':
      case 'READ_DELAY_TEST':
      case 'CANCEL_DELAY_TEST':
      case 'STOP_VPN':
        return cloneVpnRpcEmptyPayload(payload);
      default:
        throw new Error(`Unsupported RESPONSE method ${method}.`);
    }
  }
  throw new Error('RESPONSE payload cloning requires ok to be true or false.');
}
