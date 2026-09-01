import {
  cloneCoreProxyGroupRef,
  cloneCoreProxyGroupSnapshot,
  type CoreProxyGroupRef,
  type CoreProxyGroupSnapshot
} from '../core/CoreProxyModels';
import { normalizeCanonicalUtcIsoTimestamp } from '../profile/AppErrors';

export type ProxyRejectedErrorCode =
  | 'PROXY_PROFILE_UNAVAILABLE'
  | 'PROXY_RUNTIME_NOT_READY'
  | 'PROXY_SELECTION_STALE'
  | 'PROXY_QUERY_FAILED'
  | 'PROXY_SELECTION_FAILED'
  | 'PROXY_PERSISTENCE_FAILED'
  | 'PROXY_DELAY_TEST_FAILED'
  | 'PROXY_DELAY_DRAIN_FAILED'
  | 'VPN_SESSION_CHANGED';

export type ProxySelectionResultKind =
  | 'APPLIED_NOW'
  | 'SAVED_FOR_NEXT_START'
  | 'APPLIED_NOT_PERSISTED'
  | 'REJECTED';

const proxyRejectedErrorCodes: ProxyRejectedErrorCode[] = [
  'PROXY_PROFILE_UNAVAILABLE',
  'PROXY_RUNTIME_NOT_READY',
  'PROXY_SELECTION_STALE',
  'PROXY_QUERY_FAILED',
  'PROXY_SELECTION_FAILED',
  'PROXY_PERSISTENCE_FAILED',
  'PROXY_DELAY_TEST_FAILED',
  'PROXY_DELAY_DRAIN_FAILED',
  'VPN_SESSION_CHANGED'
];

const proxySelectionResultKinds: ProxySelectionResultKind[] = [
  'APPLIED_NOW',
  'SAVED_FOR_NEXT_START',
  'APPLIED_NOT_PERSISTED',
  'REJECTED'
];

const SHA256_PATTERN: RegExp = /^[0-9a-f]{64}$/u;
const MAX_PRIVATE_ID_BYTES: number = 256;
const MAX_PROXY_LABEL_BYTES: number = 256;
const MAX_CONFIG_PATH_BYTES: number = 1024;

export interface ActiveProxyProfile {
  profileId: string;
  revisionId: string;
  revisionHash: string;
  configPath: string;
}

export interface ProxyRuntimeIdentity {
  profileId: string;
  revisionId: string;
  revisionHash: string;
  sessionId: string | null;
}

export interface ProxySelectionRecord {
  profileId: string;
  groupName: string;
  selectedNodeName: string;
  revisionId: string;
  updatedAt: string;
}

export interface ProxyGroupSnapshot {
  identity: ProxyRuntimeIdentity;
  generation: number;
  group: CoreProxyGroupSnapshot;
}

export interface ProxyRejectedError {
  code: ProxyRejectedErrorCode;
  retryable: boolean;
  timestamp: string;
}

export interface ProxyRejectedResult {
  kind: 'REJECTED';
  error: ProxyRejectedError;
}

export interface ProxyGroupListSnapshotResult {
  kind: 'SNAPSHOT';
  identity: ProxyRuntimeIdentity;
  generation: number;
  groups: CoreProxyGroupRef[];
}

export interface ProxyGroupQuerySnapshotResult {
  kind: 'SNAPSHOT';
  snapshot: ProxyGroupSnapshot;
}

export interface ProxyReconciledResult {
  kind: 'RECONCILED';
  profileIdHash: string;
  revisionHash: string;
  keptCount: number;
  deletedCount: number;
}

export interface ProxySelectionAppliedNowResult {
  kind: 'APPLIED_NOW';
  snapshot: ProxyGroupSnapshot;
  record: ProxySelectionRecord;
  confirmedAt: string;
}

export interface ProxySelectionSavedForNextStartResult {
  kind: 'SAVED_FOR_NEXT_START';
  record: ProxySelectionRecord;
  savedAt: string;
}

export interface ProxySelectionAppliedNotPersistedResult {
  kind: 'APPLIED_NOT_PERSISTED';
  snapshot: ProxyGroupSnapshot;
  record: ProxySelectionRecord;
  error: ProxyRejectedError;
  confirmedAt: string;
}

export type ProxyGroupListQueryResult = ProxyGroupListSnapshotResult | ProxyRejectedResult;
export type ProxyGroupQueryResult = ProxyGroupQuerySnapshotResult | ProxyRejectedResult;
export type ProxyReconcileResult = ProxyReconciledResult | ProxyRejectedResult;
export type ProxySelectionResult =
  | ProxySelectionAppliedNowResult
  | ProxySelectionSavedForNextStartResult
  | ProxySelectionAppliedNotPersistedResult
  | ProxyRejectedResult;

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

function normalizePrivateId(rawValue: string, label: string): string {
  const trimmed: string = rawValue.trim();
  if (trimmed.length === 0) {
    throw new Error(`${label} must not be blank.`);
  }
  if (rawValue !== trimmed) {
    throw new Error(`${label} must not contain leading or trailing whitespace.`);
  }
  if (!isWellFormedUnicode(rawValue)) {
    throw new Error(`${label} must be well-formed Unicode.`);
  }
  if (containsUnicodeCc(rawValue)) {
    throw new Error(`${label} must not contain control characters.`);
  }
  if (utf8ByteLength(rawValue) > MAX_PRIVATE_ID_BYTES) {
    throw new Error(`${label} must stay within ${MAX_PRIVATE_ID_BYTES} UTF-8 bytes.`);
  }
  return rawValue;
}

function normalizeConfigPath(rawValue: string): string {
  const normalized: string = rawValue.trim();
  if (normalized.length === 0) {
    throw new Error('Proxy configPath must not be blank.');
  }
  if (!isWellFormedUnicode(normalized)) {
    throw new Error('Proxy configPath must be well-formed Unicode.');
  }
  if (containsUnicodeCc(normalized)) {
    throw new Error('Proxy configPath must not contain control characters.');
  }
  if (utf8ByteLength(normalized) > MAX_CONFIG_PATH_BYTES) {
    throw new Error(`Proxy configPath must stay within ${MAX_CONFIG_PATH_BYTES} UTF-8 bytes.`);
  }
  return normalized;
}

export function normalizeProxyLabel(rawValue: string, label: string): string {
  if (rawValue.length === 0 || rawValue.trim().length === 0) {
    throw new Error(`${label} must not be blank.`);
  }
  if (!isWellFormedUnicode(rawValue)) {
    throw new Error(`${label} must be well-formed Unicode.`);
  }
  if (containsUnicodeCc(rawValue)) {
    throw new Error(`${label} must not contain control characters.`);
  }
  if (utf8ByteLength(rawValue) > MAX_PROXY_LABEL_BYTES) {
    throw new Error(`${label} must stay within ${MAX_PROXY_LABEL_BYTES} UTF-8 bytes.`);
  }
  return rawValue;
}

export function listProxyRejectedErrorCodes(): ProxyRejectedErrorCode[] {
  return proxyRejectedErrorCodes.slice();
}

export function listProxySelectionResultKinds(): ProxySelectionResultKind[] {
  return proxySelectionResultKinds.slice();
}

function normalizeRevisionId(rawValue: string, label: string): string {
  return normalizeCanonicalUtcIsoTimestamp(rawValue, label);
}

function normalizeProxyHash(rawValue: string, label: string): string {
  if (!SHA256_PATTERN.test(rawValue)) {
    throw new Error(`${label} must be a 64-character lowercase SHA-256 hex string.`);
  }
  return rawValue;
}

function normalizeOptionalSessionId(sessionId: string | null): string | null {
  if (sessionId === null) {
    return null;
  }
  return normalizePrivateId(sessionId, 'Proxy sessionId');
}

function normalizeSafePositiveInteger(value: number, label: string): number {
  if (!Number.isInteger(value) || value <= 0 || value > Number.MAX_SAFE_INTEGER) {
    throw new Error(`${label} must be a safe positive integer.`);
  }
  return value;
}

function normalizeSafeNonNegativeInteger(value: number, label: string): number {
  if (!Number.isInteger(value) || value < 0 || value > Number.MAX_SAFE_INTEGER) {
    throw new Error(`${label} must be a safe non-negative integer.`);
  }
  return value;
}

function normalizeRejectedCode(code: ProxyRejectedErrorCode): ProxyRejectedErrorCode {
  for (let index: number = 0; index < proxyRejectedErrorCodes.length; index += 1) {
    if (proxyRejectedErrorCodes[index] === code) {
      return code;
    }
  }
  throw new Error('Proxy rejected error code must stay inside the allowlisted public contract.');
}

function validateGroupSnapshotShape(group: CoreProxyGroupSnapshot): void {
  normalizeProxyLabel(group.name, 'Proxy group name');
  normalizeProxyLabel(group.selectedName, 'Proxy selected node name');
  for (let index: number = 0; index < group.nodes.length; index += 1) {
    normalizeProxyLabel(group.nodes[index].name, 'Proxy node name');
  }
}

function validateSnapshotRecordMatch(snapshot: ProxyGroupSnapshot, record: ProxySelectionRecord): void {
  if (snapshot.identity.sessionId === null) {
    throw new Error('Running proxy selection results require a non-null session identity.');
  }
  if (snapshot.identity.profileId !== record.profileId) {
    throw new Error('Proxy selection record must match the snapshot profile identity.');
  }
  if (snapshot.identity.revisionId !== record.revisionId) {
    throw new Error('Proxy selection record must match the snapshot revision identity.');
  }
  if (snapshot.group.name !== record.groupName) {
    throw new Error('Proxy selection record group must match the confirmed snapshot.');
  }
  if (snapshot.group.selectedName !== record.selectedNodeName) {
    throw new Error('Proxy selection record selected node must match the confirmed snapshot.');
  }
}

export function createActiveProxyProfile(
  profileId: string,
  revisionId: string,
  revisionHash: string,
  configPath: string
): ActiveProxyProfile {
  return {
    profileId: normalizePrivateId(profileId, 'Proxy profileId'),
    revisionId: normalizeRevisionId(revisionId, 'Proxy revisionId'),
    revisionHash: normalizeProxyHash(revisionHash, 'Proxy revisionHash'),
    configPath: normalizeConfigPath(configPath)
  };
}

export function cloneActiveProxyProfile(profile: ActiveProxyProfile): ActiveProxyProfile {
  return createActiveProxyProfile(profile.profileId, profile.revisionId, profile.revisionHash, profile.configPath);
}

export function createProxyRuntimeIdentity(
  profileId: string,
  revisionId: string,
  revisionHash: string,
  sessionId: string | null
): ProxyRuntimeIdentity {
  return {
    profileId: normalizePrivateId(profileId, 'Proxy profileId'),
    revisionId: normalizeRevisionId(revisionId, 'Proxy revisionId'),
    revisionHash: normalizeProxyHash(revisionHash, 'Proxy revisionHash'),
    sessionId: normalizeOptionalSessionId(sessionId)
  };
}

export function cloneProxyRuntimeIdentity(identity: ProxyRuntimeIdentity): ProxyRuntimeIdentity {
  return createProxyRuntimeIdentity(
    identity.profileId,
    identity.revisionId,
    identity.revisionHash,
    identity.sessionId
  );
}

export function createProxySelectionRecord(
  profileId: string,
  groupName: string,
  selectedNodeName: string,
  revisionId: string,
  updatedAt: string
): ProxySelectionRecord {
  return {
    profileId: normalizePrivateId(profileId, 'Proxy profileId'),
    groupName: normalizeProxyLabel(groupName, 'Proxy group name'),
    selectedNodeName: normalizeProxyLabel(selectedNodeName, 'Proxy selected node name'),
    revisionId: normalizeRevisionId(revisionId, 'Proxy revisionId'),
    updatedAt: normalizeCanonicalUtcIsoTimestamp(updatedAt, 'Proxy selection updatedAt')
  };
}

export function cloneProxySelectionRecord(record: ProxySelectionRecord): ProxySelectionRecord {
  return createProxySelectionRecord(
    record.profileId,
    record.groupName,
    record.selectedNodeName,
    record.revisionId,
    record.updatedAt
  );
}

export function createProxyGroupSnapshot(
  identity: ProxyRuntimeIdentity,
  generation: number,
  group: CoreProxyGroupSnapshot
): ProxyGroupSnapshot {
  validateGroupSnapshotShape(group);
  return {
    identity: cloneProxyRuntimeIdentity(identity),
    generation: normalizeSafePositiveInteger(generation, 'Proxy generation'),
    group: cloneCoreProxyGroupSnapshot(group)
  };
}

export function cloneProxyGroupSnapshot(snapshot: ProxyGroupSnapshot): ProxyGroupSnapshot {
  return createProxyGroupSnapshot(snapshot.identity, snapshot.generation, snapshot.group);
}

export function createProxyRejectedError(
  code: ProxyRejectedErrorCode,
  retryable: boolean,
  timestamp: string
): ProxyRejectedError {
  return {
    code: normalizeRejectedCode(code),
    retryable,
    timestamp: normalizeCanonicalUtcIsoTimestamp(timestamp, 'Proxy rejection timestamp')
  };
}

export function cloneProxyRejectedError(error: ProxyRejectedError): ProxyRejectedError {
  return createProxyRejectedError(error.code, error.retryable, error.timestamp);
}

export function createProxyRejectedResult(error: ProxyRejectedError): ProxyRejectedResult {
  return {
    kind: 'REJECTED',
    error: cloneProxyRejectedError(error)
  };
}

export function cloneProxyRejectedResult(result: ProxyRejectedResult): ProxyRejectedResult {
  return createProxyRejectedResult(result.error);
}

export function createProxyGroupListQuerySnapshot(
  identity: ProxyRuntimeIdentity,
  generation: number,
  groups: CoreProxyGroupRef[]
): ProxyGroupListQueryResult {
  const clones: CoreProxyGroupRef[] = [];
  for (let index: number = 0; index < groups.length; index += 1) {
    normalizeProxyLabel(groups[index].name, 'Proxy group name');
    clones.push(cloneCoreProxyGroupRef(groups[index]));
  }
  return {
    kind: 'SNAPSHOT',
    identity: cloneProxyRuntimeIdentity(identity),
    generation: normalizeSafePositiveInteger(generation, 'Proxy generation'),
    groups: clones
  };
}

export function createProxyGroupQuerySnapshot(snapshot: ProxyGroupSnapshot): ProxyGroupQueryResult {
  return {
    kind: 'SNAPSHOT',
    snapshot: cloneProxyGroupSnapshot(snapshot)
  };
}

export function createProxyReconcileResult(
  profileIdHash: string,
  revisionHash: string,
  keptCount: number,
  deletedCount: number
): ProxyReconcileResult {
  return {
    kind: 'RECONCILED',
    profileIdHash: normalizeProxyHash(profileIdHash, 'Proxy profileIdHash'),
    revisionHash: normalizeProxyHash(revisionHash, 'Proxy revisionHash'),
    keptCount: normalizeSafeNonNegativeInteger(keptCount, 'Proxy keptCount'),
    deletedCount: normalizeSafeNonNegativeInteger(deletedCount, 'Proxy deletedCount')
  };
}

export function createProxySelectionAppliedNowResult(
  snapshot: ProxyGroupSnapshot,
  record: ProxySelectionRecord,
  confirmedAt: string
): ProxySelectionResult {
  const snapshotClone: ProxyGroupSnapshot = cloneProxyGroupSnapshot(snapshot);
  const recordClone: ProxySelectionRecord = cloneProxySelectionRecord(record);
  validateSnapshotRecordMatch(snapshotClone, recordClone);
  return {
    kind: 'APPLIED_NOW',
    snapshot: snapshotClone,
    record: recordClone,
    confirmedAt: normalizeCanonicalUtcIsoTimestamp(confirmedAt, 'Proxy selection confirmedAt')
  };
}

export function createProxySelectionSavedForNextStartResult(
  record: ProxySelectionRecord,
  savedAt: string
): ProxySelectionResult {
  return {
    kind: 'SAVED_FOR_NEXT_START',
    record: cloneProxySelectionRecord(record),
    savedAt: normalizeCanonicalUtcIsoTimestamp(savedAt, 'Proxy selection savedAt')
  };
}

export function createProxySelectionAppliedNotPersistedResult(
  snapshot: ProxyGroupSnapshot,
  record: ProxySelectionRecord,
  error: ProxyRejectedError,
  confirmedAt: string
): ProxySelectionResult {
  const snapshotClone: ProxyGroupSnapshot = cloneProxyGroupSnapshot(snapshot);
  const recordClone: ProxySelectionRecord = cloneProxySelectionRecord(record);
  const errorClone: ProxyRejectedError = cloneProxyRejectedError(error);
  validateSnapshotRecordMatch(snapshotClone, recordClone);
  if (errorClone.code !== 'PROXY_PERSISTENCE_FAILED') {
    throw new Error('APPLIED_NOT_PERSISTED results require a sanitized proxy persistence error.');
  }
  return {
    kind: 'APPLIED_NOT_PERSISTED',
    snapshot: snapshotClone,
    record: recordClone,
    error: errorClone,
    confirmedAt: normalizeCanonicalUtcIsoTimestamp(confirmedAt, 'Proxy selection confirmedAt')
  };
}

export function cloneProxyGroupListQueryResult(result: ProxyGroupListQueryResult): ProxyGroupListQueryResult {
  if (result.kind === 'REJECTED') {
    return cloneProxyRejectedResult(result);
  }
  return createProxyGroupListQuerySnapshot(result.identity, result.generation, result.groups);
}

export function cloneProxyGroupQueryResult(result: ProxyGroupQueryResult): ProxyGroupQueryResult {
  if (result.kind === 'REJECTED') {
    return cloneProxyRejectedResult(result);
  }
  return createProxyGroupQuerySnapshot(result.snapshot);
}

export function cloneProxyReconcileResult(result: ProxyReconcileResult): ProxyReconcileResult {
  if (result.kind === 'REJECTED') {
    return cloneProxyRejectedResult(result);
  }
  return createProxyReconcileResult(
    result.profileIdHash,
    result.revisionHash,
    result.keptCount,
    result.deletedCount
  );
}

export function cloneProxySelectionResult(result: ProxySelectionResult): ProxySelectionResult {
  switch (result.kind) {
    case 'APPLIED_NOW':
      return createProxySelectionAppliedNowResult(result.snapshot, result.record, result.confirmedAt);
    case 'SAVED_FOR_NEXT_START':
      return createProxySelectionSavedForNextStartResult(result.record, result.savedAt);
    case 'APPLIED_NOT_PERSISTED':
      return createProxySelectionAppliedNotPersistedResult(
        result.snapshot,
        result.record,
        result.error,
        result.confirmedAt
      );
    case 'REJECTED':
      return createProxyRejectedResult(result.error);
    default:
      throw new Error('Unreachable proxy selection result kind.');
  }
}
