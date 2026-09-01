import {
  CORE_PROXY_SCHEMA_VERSION,
  cloneCoreProxyGroupList,
  cloneCoreProxyGroupResult,
  cloneCoreProxyGroupSnapshot,
  cloneCoreProxyNodeSummary,
  cloneCoreProxyQueryContext,
  cloneCoreProxySelectionApplied,
  createProxyBridgeInvalidError,
  type CoreProxyGroupList,
  type CoreProxyGroupRef,
  type CoreProxyGroupResult,
  type CoreProxyGroupSnapshot,
  type CoreProxyNodeSummary,
  type CoreProxyQueryContext,
  type CoreProxySelectionApplied,
  type CoreProxyType
} from '@cmfa/shared';

const HASH_PATTERN: RegExp = /^[0-9a-f]{64}$/u;
const CONTROL_PATTERN: RegExp = /[\u0000-\u001F\u007F-\u009F]/u;
const MAX_RAW_BYTES: number = 1024 * 1024;
const MAX_NAME_BYTES: number = 256;
const MAX_GROUPS: number = 128;
const MAX_NODES: number = 1024;
const PROXY_TYPE_ALLOWLIST: CoreProxyType[] = [
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

class ProxyGroupRefValue implements CoreProxyGroupRef {
  name: string = '';
  type: CoreProxyType = 'Direct';
}

class ProxyNodeSummaryValue implements CoreProxyNodeSummary {
  name: string = '';
  type: CoreProxyType = 'Direct';
  isGroup: boolean = false;
  selected: boolean = false;
}

class ProxyGroupSnapshotValue implements CoreProxyGroupSnapshot {
  name: string = '';
  type: CoreProxyType = 'Direct';
  selectedName: string = '';
  nodes: CoreProxyNodeSummary[] = [];
}

function fail(operation: string): never {
  throw createProxyBridgeInvalidError(operation);
}

function utf8ByteLength(value: string): number {
  let length: number = 0;
  let index: number = 0;
  while (index < value.length) {
    const codeUnit: number = value.charCodeAt(index);
    if (codeUnit < 0x80) {
      length += 1;
      index += 1;
      continue;
    }
    if (codeUnit < 0x800) {
      length += 2;
      index += 1;
      continue;
    }
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff && index + 1 < value.length) {
      const nextCodeUnit: number = value.charCodeAt(index + 1);
      if (nextCodeUnit >= 0xdc00 && nextCodeUnit <= 0xdfff) {
        length += 4;
        index += 2;
        continue;
      }
    }
    length += 3;
    index += 1;
  }
  return length;
}

function isSafePositiveInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function containsKey(keys: string[], expected: string): boolean {
  for (let index: number = 0; index < keys.length; index += 1) {
    if (keys[index] === expected) {
      return true;
    }
  }
  return false;
}

function hasForbiddenMetaKey(keys: string[]): boolean {
  return containsKey(keys, '__proto__') || containsKey(keys, 'constructor') || containsKey(keys, 'prototype');
}

function requirePlainObject(value: Object | null | undefined, expectedKeys: string[], operation: string): Record<string, Object> {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(operation);
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  const actualKeys: string[] = Object.keys(record);
  if (hasForbiddenMetaKey(actualKeys) || actualKeys.length !== expectedKeys.length) {
    fail(operation);
  }
  for (let index: number = 0; index < actualKeys.length; index += 1) {
    if (!containsKey(expectedKeys, actualKeys[index])) {
      fail(operation);
    }
  }
  return record;
}

function requireString(value: Object | undefined, operation: string): string {
  if (typeof value !== 'string') {
    fail(operation);
  }
  return value;
}

function requireBoolean(value: Object | undefined, operation: string): boolean {
  if (typeof value !== 'boolean') {
    fail(operation);
  }
  return value;
}

function requireNumber(value: Object | undefined, operation: string): number {
  if (typeof value !== 'number') {
    fail(operation);
  }
  return value;
}

function requireArray(value: Object | undefined, operation: string): Object[] {
  if (!Array.isArray(value)) {
    fail(operation);
  }
  return value as Object[];
}

function requireName(value: Object | undefined, operation: string, allowEmpty: boolean = false): string {
  const name: string = requireString(value, operation);
  if ((!allowEmpty && name.length === 0) ||
    utf8ByteLength(name) > MAX_NAME_BYTES ||
    CONTROL_PATTERN.test(name)) {
    fail(operation);
  }
  return name;
}

function requireHash(value: Object | undefined, operation: string): string {
  const hash: string = requireString(value, operation);
  if (!HASH_PATTERN.test(hash)) {
    fail(operation);
  }
  return hash;
}

function requireNullableHash(value: Object | undefined, operation: string): string | null {
  if (value === null) {
    return null;
  }
  return requireHash(value, operation);
}

function requireGeneration(value: Object | undefined, operation: string): number {
  const generation: number = requireNumber(value, operation);
  if (!isSafePositiveInteger(generation)) {
    fail(operation);
  }
  return generation;
}

function requireProxyType(value: Object | undefined, operation: string): CoreProxyType {
  const rawType: string = requireString(value, operation);
  for (let index: number = 0; index < PROXY_TYPE_ALLOWLIST.length; index += 1) {
    if (PROXY_TYPE_ALLOWLIST[index] === rawType) {
      return rawType as CoreProxyType;
    }
  }
  fail(operation);
}

function normalizeExpectedContext(operation: string, expected: CoreProxyQueryContext): CoreProxyQueryContext {
  const clone: CoreProxyQueryContext = cloneCoreProxyQueryContext(expected);
  if (!HASH_PATTERN.test(clone.profileHash) ||
    !HASH_PATTERN.test(clone.revisionHash) ||
    (clone.sessionHash !== null && !HASH_PATTERN.test(clone.sessionHash)) ||
    !isSafePositiveInteger(clone.generation)) {
    fail(operation);
  }
  return clone;
}

function requireMatchingContext(record: Record<string, Object>, expected: CoreProxyQueryContext, operation: string): CoreProxyQueryContext {
  const actual: CoreProxyQueryContext = cloneCoreProxyQueryContext({
    profileHash: requireHash(record.profileHash, operation),
    revisionHash: requireHash(record.revisionHash, operation),
    sessionHash: requireNullableHash(record.sessionHash, operation),
    generation: requireGeneration(record.generation, operation)
  });
  if (actual.profileHash !== expected.profileHash ||
    actual.revisionHash !== expected.revisionHash ||
    actual.sessionHash !== expected.sessionHash ||
    actual.generation !== expected.generation) {
    fail(operation);
  }
  return actual;
}

function requireSchemaAndKind(record: Record<string, Object>, expectedKind: string, operation: string): void {
  if (requireString(record.schemaVersion, operation) !== CORE_PROXY_SCHEMA_VERSION ||
    requireString(record.kind, operation) !== expectedKind) {
    fail(operation);
  }
}

function requireUniqueName(existing: Set<string>, name: string, operation: string): void {
  if (existing.has(name)) {
    fail(operation);
  }
  existing.add(name);
}

function decodeGroupRef(value: Object | undefined, operation: string): CoreProxyGroupRef {
  const record: Record<string, Object> = requirePlainObject(value as Object | undefined, ['name', 'type'], operation);
  const group = new ProxyGroupRefValue();
  group.name = requireName(record.name, operation);
  group.type = requireProxyType(record.type, operation);
  return group;
}

function decodeNodeSummary(value: Object | undefined, operation: string): CoreProxyNodeSummary {
  const record: Record<string, Object> = requirePlainObject(value as Object | undefined, ['name', 'type', 'isGroup', 'selected'], operation);
  const node = new ProxyNodeSummaryValue();
  node.name = requireName(record.name, operation);
  node.type = requireProxyType(record.type, operation);
  node.isGroup = requireBoolean(record.isGroup, operation);
  node.selected = requireBoolean(record.selected, operation);
  return cloneCoreProxyNodeSummary(node);
}

function decodeGroupSnapshot(value: Object | undefined, operation: string): CoreProxyGroupSnapshot {
  const record: Record<string, Object> = requirePlainObject(value as Object | undefined, ['name', 'type', 'selectedName', 'nodes'], operation);
  const snapshot = new ProxyGroupSnapshotValue();
  snapshot.name = requireName(record.name, operation);
  snapshot.type = requireProxyType(record.type, operation);
  snapshot.selectedName = requireName(record.selectedName, operation, true);

  const rawNodes: Object[] = requireArray(record.nodes, operation);
  if (rawNodes.length > MAX_NODES) {
    fail(operation);
  }
  const nodes: CoreProxyNodeSummary[] = [];
  const names: Set<string> = new Set<string>();
  let selectedCount: number = 0;
  let selectedNameSeen: string = '';
  for (let index: number = 0; index < rawNodes.length; index += 1) {
    const node: CoreProxyNodeSummary = decodeNodeSummary(rawNodes[index], operation);
    requireUniqueName(names, node.name, operation);
    if (node.selected) {
      selectedCount += 1;
      selectedNameSeen = node.name;
    }
    nodes.push(node);
  }
  if (snapshot.selectedName.length === 0) {
    if (selectedCount !== 0) {
      fail(operation);
    }
  } else if (selectedCount !== 1 || selectedNameSeen !== snapshot.selectedName || !names.has(snapshot.selectedName)) {
    fail(operation);
  }
  snapshot.nodes = nodes;
  return cloneCoreProxyGroupSnapshot(snapshot);
}

function parseRoot(raw: Object | string | undefined, operation: string): Record<string, Object> {
  if (typeof raw !== 'string') {
    fail(operation);
  }
  if (utf8ByteLength(raw) > MAX_RAW_BYTES) {
    fail(operation);
  }
  try {
    const parsed: Object = JSON.parse(raw) as Object;
    return requirePlainObject(parsed, [
      'schemaVersion',
      'kind',
      'profileHash',
      'revisionHash',
      'sessionHash',
      'generation',
      operation === 'queryProxyGroups' ? 'groups' : operation === 'queryProxyGroup' ? 'group' : 'previousName',
      operation === 'selectProxy' ? 'group' : operation === 'queryProxyGroups' ? '' : ''
    ].filter((key: string): boolean => key.length > 0), operation);
  } catch (_) {
    fail(operation);
  }
}

export function decodeProxyGroupList(raw: Object | string | undefined, expectedContext: CoreProxyQueryContext): CoreProxyGroupList {
  const operation: string = 'queryProxyGroups';
  const expected: CoreProxyQueryContext = normalizeExpectedContext(operation, expectedContext);
  const root: Record<string, Object> = parseRoot(raw, operation);
  requireSchemaAndKind(root, 'GROUP_LIST', operation);
  const context: CoreProxyQueryContext = requireMatchingContext(root, expected, operation);
  const rawGroups: Object[] = requireArray(root.groups, operation);
  if (rawGroups.length > MAX_GROUPS) {
    fail(operation);
  }
  const groups: CoreProxyGroupRef[] = [];
  const names: Set<string> = new Set<string>();
  for (let index: number = 0; index < rawGroups.length; index += 1) {
    const group: CoreProxyGroupRef = decodeGroupRef(rawGroups[index], operation);
    requireUniqueName(names, group.name, operation);
    groups.push(group);
  }
  return cloneCoreProxyGroupList({
    schemaVersion: CORE_PROXY_SCHEMA_VERSION,
    kind: 'GROUP_LIST',
    profileHash: context.profileHash,
    revisionHash: context.revisionHash,
    sessionHash: context.sessionHash,
    generation: context.generation,
    groups
  });
}

export function decodeProxyGroupResult(raw: Object | string | undefined, expectedContext: CoreProxyQueryContext): CoreProxyGroupResult {
  const operation: string = 'queryProxyGroup';
  const expected: CoreProxyQueryContext = normalizeExpectedContext(operation, expectedContext);
  const root: Record<string, Object> = parseRoot(raw, operation);
  requireSchemaAndKind(root, 'GROUP_SNAPSHOT', operation);
  const context: CoreProxyQueryContext = requireMatchingContext(root, expected, operation);
  const group: CoreProxyGroupSnapshot = decodeGroupSnapshot(root.group, operation);
  return cloneCoreProxyGroupResult({
    schemaVersion: CORE_PROXY_SCHEMA_VERSION,
    kind: 'GROUP_SNAPSHOT',
    profileHash: context.profileHash,
    revisionHash: context.revisionHash,
    sessionHash: context.sessionHash,
    generation: context.generation,
    group
  });
}

export function decodeProxySelectionApplied(
  raw: Object | string | undefined,
  expectedContext: CoreProxyQueryContext
): CoreProxySelectionApplied {
  const operation: string = 'selectProxy';
  const expected: CoreProxyQueryContext = normalizeExpectedContext(operation, expectedContext);
  const root: Record<string, Object> = parseRoot(raw, operation);
  requireSchemaAndKind(root, 'SELECTION_APPLIED', operation);
  const context: CoreProxyQueryContext = requireMatchingContext(root, expected, operation);
  const previousName: string = requireName(root.previousName, operation, true);
  const group: CoreProxyGroupSnapshot = decodeGroupSnapshot(root.group, operation);
  return cloneCoreProxySelectionApplied({
    schemaVersion: CORE_PROXY_SCHEMA_VERSION,
    kind: 'SELECTION_APPLIED',
    profileHash: context.profileHash,
    revisionHash: context.revisionHash,
    sessionHash: context.sessionHash,
    generation: context.generation,
    previousName,
    group
  });
}
