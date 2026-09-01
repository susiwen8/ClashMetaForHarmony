import {
  CORE_PROXY_DELAY_SCHEMA_VERSION,
  cloneCoreProxyDelaySnapshot,
  cloneCoreProxyQueryContext,
  createProxyBridgeInvalidError,
  type CoreProxyDelayJobState,
  type CoreProxyDelayNodeResult,
  type CoreProxyDelayNodeState,
  type CoreProxyDelaySnapshot,
  type CoreProxyDelayURLSource,
  type CoreProxyQueryContext,
  type CoreProxyType
} from '@cmfa/shared';

const HASH_PATTERN: RegExp = /^[0-9a-f]{64}$/u;
const JOB_ID_PATTERN: RegExp = /^[0-9a-f]{32}$/u;
const CONTROL_PATTERN: RegExp = /[\u0000-\u001F\u007F-\u009F]/u;
const MAX_RAW_BYTES: number = 1024 * 1024;
const MAX_NAME_BYTES: number = 256;
const MAX_NODES: number = 1024;
const MAX_DELAY_MS: number = 65535;
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

class ProxyDelayNodeResultValue implements CoreProxyDelayNodeResult {
  index: number = 0;
  name: string = '';
  type: CoreProxyType = 'Direct';
  state: CoreProxyDelayNodeState = 'WAITING';
  delayMs: number | null = null;
  source: CoreProxyDelayURLSource | null = null;
  fastest: boolean = false;
}

class ProxyDelaySnapshotValue implements CoreProxyDelaySnapshot {
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

class DelayCountsValue {
  totalCount: number = 0;
  testableCount: number = 0;
  completedCount: number = 0;
  availableCount: number = 0;
  timeoutCount: number = 0;
  failedCount: number = 0;
  cancelledCount: number = 0;
  unsupportedCount: number = 0;
  fastestNodeIndex: number | null = null;
}

class JsonStringScanValue {
  value: string = '';
  nextIndex: number = 0;
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

function isSafeNonNegativeInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
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

function isWellFormedUnicode(value: string): boolean {
  let index: number = 0;
  while (index < value.length) {
    const codeUnit: number = value.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      if (index + 1 >= value.length) {
        return false;
      }
      const nextCodeUnit: number = value.charCodeAt(index + 1);
      if (nextCodeUnit < 0xdc00 || nextCodeUnit > 0xdfff) {
        return false;
      }
      index += 2;
      continue;
    }
    if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      return false;
    }
    index += 1;
  }
  return true;
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

function requireName(value: Object | undefined, operation: string): string {
  const name: string = requireString(value, operation);
  if (name.length === 0 ||
    utf8ByteLength(name) > MAX_NAME_BYTES ||
    CONTROL_PATTERN.test(name) ||
    !isWellFormedUnicode(name)) {
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

function requireJobId(value: Object | undefined, operation: string): string {
  const jobId: string = requireString(value, operation);
  if (!JOB_ID_PATTERN.test(jobId)) {
    fail(operation);
  }
  return jobId;
}

function requireNullableIndex(value: Object | undefined, operation: string): number | null {
  if (value === null) {
    return null;
  }
  const index: number = requireNumber(value, operation);
  if (!isSafeNonNegativeInteger(index)) {
    fail(operation);
  }
  return index;
}

function requireNonNegativeCount(value: Object | undefined, operation: string): number {
  const count: number = requireNumber(value, operation);
  if (!isSafeNonNegativeInteger(count)) {
    fail(operation);
  }
  return count;
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

function requireJobState(value: Object | undefined, operation: string): CoreProxyDelayJobState {
  const state: string = requireString(value, operation);
  if (state === 'RUNNING' || state === 'COMPLETED' || state === 'CANCELLED' || state === 'FAILED') {
    return state as CoreProxyDelayJobState;
  }
  fail(operation);
}

function requireNodeState(value: Object | undefined, operation: string): CoreProxyDelayNodeState {
  const state: string = requireString(value, operation);
  if (state === 'WAITING' ||
    state === 'TESTING' ||
    state === 'AVAILABLE' ||
    state === 'TIMEOUT' ||
    state === 'FAILED' ||
    state === 'CANCELLED' ||
    state === 'UNSUPPORTED') {
    return state as CoreProxyDelayNodeState;
  }
  fail(operation);
}

function requireSource(value: Object | undefined, operation: string): CoreProxyDelayURLSource | null {
  if (value === null) {
    return null;
  }
  const source: string = requireString(value, operation);
  if (source === 'PROVIDER' || source === 'FALLBACK') {
    return source as CoreProxyDelayURLSource;
  }
  fail(operation);
}

function requireDelay(value: Object | undefined, operation: string): number | null {
  if (value === null) {
    return null;
  }
  const delay: number = requireNumber(value, operation);
  if (!isSafePositiveInteger(delay) || delay > MAX_DELAY_MS) {
    fail(operation);
  }
  return delay;
}

function skipWhitespace(raw: string, start: number): number {
  let index: number = start;
  while (index < raw.length) {
    const codeUnit: number = raw.charCodeAt(index);
    if (codeUnit !== 0x20 && codeUnit !== 0x09 && codeUnit !== 0x0a && codeUnit !== 0x0d) {
      return index;
    }
    index += 1;
  }
  return index;
}

function decodeHexDigit(codeUnit: number, operation: string): number {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) {
    return codeUnit - 0x30;
  }
  if (codeUnit >= 0x41 && codeUnit <= 0x46) {
    return codeUnit - 0x41 + 10;
  }
  if (codeUnit >= 0x61 && codeUnit <= 0x66) {
    return codeUnit - 0x61 + 10;
  }
  fail(operation);
}

function scanJsonString(raw: string, start: number, operation: string): JsonStringScanValue {
  if (raw.charCodeAt(start) !== 0x22) {
    fail(operation);
  }
  let index: number = start + 1;
  let value: string = '';
  while (index < raw.length) {
    const codeUnit: number = raw.charCodeAt(index);
    if (codeUnit === 0x22) {
      const result = new JsonStringScanValue();
      result.value = value;
      result.nextIndex = index + 1;
      return result;
    }
    if (codeUnit === 0x5c) {
      index += 1;
      if (index >= raw.length) {
        fail(operation);
      }
      const escapedCodeUnit: number = raw.charCodeAt(index);
      if (escapedCodeUnit === 0x22 || escapedCodeUnit === 0x5c || escapedCodeUnit === 0x2f) {
        value += String.fromCharCode(escapedCodeUnit);
        index += 1;
        continue;
      }
      if (escapedCodeUnit === 0x62) {
        value += '\b';
        index += 1;
        continue;
      }
      if (escapedCodeUnit === 0x66) {
        value += '\f';
        index += 1;
        continue;
      }
      if (escapedCodeUnit === 0x6e) {
        value += '\n';
        index += 1;
        continue;
      }
      if (escapedCodeUnit === 0x72) {
        value += '\r';
        index += 1;
        continue;
      }
      if (escapedCodeUnit === 0x74) {
        value += '\t';
        index += 1;
        continue;
      }
      if (escapedCodeUnit === 0x75) {
        if (index + 4 >= raw.length) {
          fail(operation);
        }
        let scalar: number = 0;
        for (let offset: number = 1; offset <= 4; offset += 1) {
          scalar = (scalar << 4) + decodeHexDigit(raw.charCodeAt(index + offset), operation);
        }
        value += String.fromCharCode(scalar);
        index += 5;
        continue;
      }
      fail(operation);
    }
    if (codeUnit <= 0x1f) {
      fail(operation);
    }
    value += raw[index];
    index += 1;
  }
  fail(operation);
}

function scanJsonLiteral(raw: string, start: number, expected: string, operation: string): number {
  for (let index: number = 0; index < expected.length; index += 1) {
    if (start + index >= raw.length || raw[start + index] !== expected[index]) {
      fail(operation);
    }
  }
  return start + expected.length;
}

function scanJsonNumber(raw: string, start: number, operation: string): number {
  let index: number = start;
  if (raw[index] === '-') {
    index += 1;
  }
  if (index >= raw.length) {
    fail(operation);
  }
  const firstDigit: number = raw.charCodeAt(index);
  if (firstDigit < 0x30 || firstDigit > 0x39) {
    fail(operation);
  }
  if (firstDigit === 0x30) {
    index += 1;
  } else {
    while (index < raw.length) {
      const codeUnit: number = raw.charCodeAt(index);
      if (codeUnit < 0x30 || codeUnit > 0x39) {
        break;
      }
      index += 1;
    }
  }
  if (index < raw.length && raw[index] === '.') {
    index += 1;
    if (index >= raw.length) {
      fail(operation);
    }
    const fractionStart: number = index;
    while (index < raw.length) {
      const codeUnit: number = raw.charCodeAt(index);
      if (codeUnit < 0x30 || codeUnit > 0x39) {
        break;
      }
      index += 1;
    }
    if (index === fractionStart) {
      fail(operation);
    }
  }
  if (index < raw.length && (raw[index] === 'e' || raw[index] === 'E')) {
    index += 1;
    if (index < raw.length && (raw[index] === '+' || raw[index] === '-')) {
      index += 1;
    }
    if (index >= raw.length) {
      fail(operation);
    }
    const exponentStart: number = index;
    while (index < raw.length) {
      const codeUnit: number = raw.charCodeAt(index);
      if (codeUnit < 0x30 || codeUnit > 0x39) {
        break;
      }
      index += 1;
    }
    if (index === exponentStart) {
      fail(operation);
    }
  }
  return index;
}

function scanJsonValue(raw: string, start: number, operation: string): number {
  const index: number = skipWhitespace(raw, start);
  if (index >= raw.length) {
    fail(operation);
  }
  const marker: string = raw[index];
  if (marker === '{') {
    return scanJsonObject(raw, index, operation);
  }
  if (marker === '[') {
    return scanJsonArray(raw, index, operation);
  }
  if (marker === '"') {
    return scanJsonString(raw, index, operation).nextIndex;
  }
  if (marker === 't') {
    return scanJsonLiteral(raw, index, 'true', operation);
  }
  if (marker === 'f') {
    return scanJsonLiteral(raw, index, 'false', operation);
  }
  if (marker === 'n') {
    return scanJsonLiteral(raw, index, 'null', operation);
  }
  if (marker === '-' || (marker >= '0' && marker <= '9')) {
    return scanJsonNumber(raw, index, operation);
  }
  fail(operation);
}

function scanJsonArray(raw: string, start: number, operation: string): number {
  let index: number = skipWhitespace(raw, start + 1);
  if (index >= raw.length) {
    fail(operation);
  }
  if (raw[index] === ']') {
    return index + 1;
  }
  while (index < raw.length) {
    index = scanJsonValue(raw, index, operation);
    index = skipWhitespace(raw, index);
    if (index >= raw.length) {
      fail(operation);
    }
    if (raw[index] === ',') {
      index = skipWhitespace(raw, index + 1);
      continue;
    }
    if (raw[index] === ']') {
      return index + 1;
    }
    fail(operation);
  }
  fail(operation);
}

function scanJsonObject(raw: string, start: number, operation: string): number {
  let index: number = skipWhitespace(raw, start + 1);
  const keys: string[] = [];
  if (index >= raw.length) {
    fail(operation);
  }
  if (raw[index] === '}') {
    return index + 1;
  }
  while (index < raw.length) {
    const keyResult: JsonStringScanValue = scanJsonString(raw, index, operation);
    if (containsKey(keys, keyResult.value)) {
      fail(operation);
    }
    keys.push(keyResult.value);
    index = skipWhitespace(raw, keyResult.nextIndex);
    if (index >= raw.length || raw[index] !== ':') {
      fail(operation);
    }
    index = scanJsonValue(raw, index + 1, operation);
    index = skipWhitespace(raw, index);
    if (index >= raw.length) {
      fail(operation);
    }
    if (raw[index] === ',') {
      index = skipWhitespace(raw, index + 1);
      continue;
    }
    if (raw[index] === '}') {
      return index + 1;
    }
    fail(operation);
  }
  fail(operation);
}

function validateNoDuplicateObjectKeys(raw: string, operation: string): void {
  const endIndex: number = scanJsonValue(raw, 0, operation);
  if (skipWhitespace(raw, endIndex) !== raw.length) {
    fail(operation);
  }
}

function requireExpectedContext(operation: string, expected: CoreProxyQueryContext): CoreProxyQueryContext {
  const clone: CoreProxyQueryContext = cloneCoreProxyQueryContext(expected);
  if (!HASH_PATTERN.test(clone.profileHash) ||
    !HASH_PATTERN.test(clone.revisionHash) ||
    (clone.sessionHash !== null && !HASH_PATTERN.test(clone.sessionHash)) ||
    !isSafePositiveInteger(clone.generation)) {
    fail(operation);
  }
  return clone;
}

function requireExpectedGroupName(expectedGroupName: string, operation: string): string {
  if (expectedGroupName.length === 0 ||
    utf8ByteLength(expectedGroupName) > MAX_NAME_BYTES ||
    CONTROL_PATTERN.test(expectedGroupName) ||
    !isWellFormedUnicode(expectedGroupName)) {
    fail(operation);
  }
  return expectedGroupName;
}

function requireExpectedJobId(expectedJobId: string, operation: string): string {
  if (!JOB_ID_PATTERN.test(expectedJobId)) {
    fail(operation);
  }
  return expectedJobId;
}

function isLiveNodeState(state: CoreProxyDelayNodeState): boolean {
  return state === 'WAITING' || state === 'TESTING';
}

function decodeNode(value: Object | undefined, expectedIndex: number, operation: string): CoreProxyDelayNodeResult {
  const record: Record<string, Object> = requirePlainObject(
    value as Object | undefined,
    ['index', 'name', 'type', 'state', 'delayMs', 'source', 'fastest'],
    operation
  );
  const node = new ProxyDelayNodeResultValue();
  node.index = requireNonNegativeCount(record.index, operation);
  if (node.index !== expectedIndex) {
    fail(operation);
  }
  node.name = requireName(record.name, operation);
  node.type = requireProxyType(record.type, operation);
  node.state = requireNodeState(record.state, operation);
  node.delayMs = requireDelay(record.delayMs, operation);
  node.source = requireSource(record.source, operation);
  node.fastest = requireBoolean(record.fastest, operation);

  if (node.state === 'AVAILABLE') {
    if (node.delayMs === null || node.source === null) {
      fail(operation);
    }
  } else if (node.delayMs !== null) {
    fail(operation);
  }

  if (node.state === 'UNSUPPORTED') {
    if (node.source !== null) {
      fail(operation);
    }
  } else if (node.source === null) {
    fail(operation);
  }
  return node;
}

function recomputeCounts(nodes: CoreProxyDelayNodeResult[]): DelayCountsValue {
  const counts = new DelayCountsValue();
  counts.totalCount = nodes.length;
  let fastestDelay: number = 0;
  for (let index: number = 0; index < nodes.length; index += 1) {
    const node: CoreProxyDelayNodeResult = nodes[index];
    if (node.state === 'UNSUPPORTED') {
      counts.unsupportedCount += 1;
    } else {
      counts.testableCount += 1;
    }
    if (!isLiveNodeState(node.state)) {
      counts.completedCount += 1;
    }
    if (node.state === 'AVAILABLE') {
      counts.availableCount += 1;
      const delay: number = node.delayMs as number;
      if (counts.fastestNodeIndex === null || delay < fastestDelay) {
        counts.fastestNodeIndex = index;
        fastestDelay = delay;
      }
    } else if (node.state === 'TIMEOUT') {
      counts.timeoutCount += 1;
    } else if (node.state === 'FAILED') {
      counts.failedCount += 1;
    } else if (node.state === 'CANCELLED') {
      counts.cancelledCount += 1;
    }
  }
  return counts;
}

function parseRoot(raw: Object | string | undefined, operation: string): Record<string, Object> {
  if (typeof raw !== 'string') {
    fail(operation);
  }
  if (utf8ByteLength(raw) > MAX_RAW_BYTES) {
    fail(operation);
  }
  validateNoDuplicateObjectKeys(raw, operation);
  try {
    const parsed: Object = JSON.parse(raw) as Object;
    return requirePlainObject(parsed, [
      'schemaVersion',
      'jobId',
      'state',
      'profileHash',
      'revisionHash',
      'sessionHash',
      'generation',
      'groupName',
      'totalCount',
      'testableCount',
      'completedCount',
      'availableCount',
      'timeoutCount',
      'failedCount',
      'cancelledCount',
      'unsupportedCount',
      'fastestNodeIndex',
      'nodes'
    ], operation);
  } catch (_) {
    fail(operation);
  }
}

function decodeSnapshot(raw: Object | string | undefined, operation: string): CoreProxyDelaySnapshot {
  const root: Record<string, Object> = parseRoot(raw, operation);
  const snapshot = new ProxyDelaySnapshotValue();
  if (requireString(root.schemaVersion, operation) !== CORE_PROXY_DELAY_SCHEMA_VERSION) {
    fail(operation);
  }
  snapshot.jobId = requireJobId(root.jobId, operation);
  snapshot.state = requireJobState(root.state, operation);
  snapshot.profileHash = requireHash(root.profileHash, operation);
  snapshot.revisionHash = requireHash(root.revisionHash, operation);
  snapshot.sessionHash = requireNullableHash(root.sessionHash, operation);
  snapshot.generation = requireGeneration(root.generation, operation);
  snapshot.groupName = requireName(root.groupName, operation);
  snapshot.totalCount = requireNonNegativeCount(root.totalCount, operation);
  snapshot.testableCount = requireNonNegativeCount(root.testableCount, operation);
  snapshot.completedCount = requireNonNegativeCount(root.completedCount, operation);
  snapshot.availableCount = requireNonNegativeCount(root.availableCount, operation);
  snapshot.timeoutCount = requireNonNegativeCount(root.timeoutCount, operation);
  snapshot.failedCount = requireNonNegativeCount(root.failedCount, operation);
  snapshot.cancelledCount = requireNonNegativeCount(root.cancelledCount, operation);
  snapshot.unsupportedCount = requireNonNegativeCount(root.unsupportedCount, operation);
  snapshot.fastestNodeIndex = requireNullableIndex(root.fastestNodeIndex, operation);

  const rawNodes: Object[] = requireArray(root.nodes, operation);
  if (rawNodes.length > MAX_NODES) {
    fail(operation);
  }
  const nodes: CoreProxyDelayNodeResult[] = [];
  for (let index: number = 0; index < rawNodes.length; index += 1) {
    nodes.push(decodeNode(rawNodes[index], index, operation));
  }
  snapshot.nodes = nodes;

  const expectedCounts: DelayCountsValue = recomputeCounts(nodes);
  if (snapshot.totalCount !== expectedCounts.totalCount ||
    snapshot.testableCount !== expectedCounts.testableCount ||
    snapshot.completedCount !== expectedCounts.completedCount ||
    snapshot.availableCount !== expectedCounts.availableCount ||
    snapshot.timeoutCount !== expectedCounts.timeoutCount ||
    snapshot.failedCount !== expectedCounts.failedCount ||
    snapshot.cancelledCount !== expectedCounts.cancelledCount ||
    snapshot.unsupportedCount !== expectedCounts.unsupportedCount ||
    snapshot.fastestNodeIndex !== expectedCounts.fastestNodeIndex) {
    fail(operation);
  }

  let fastestCount: number = 0;
  for (let index: number = 0; index < nodes.length; index += 1) {
    const node: CoreProxyDelayNodeResult = nodes[index];
    const shouldBeFastest: boolean = expectedCounts.fastestNodeIndex !== null && expectedCounts.fastestNodeIndex === index;
    if (node.fastest) {
      fastestCount += 1;
    }
    if (node.fastest !== shouldBeFastest) {
      fail(operation);
    }
    if (snapshot.state !== 'RUNNING' && isLiveNodeState(node.state)) {
      fail(operation);
    }
  }
  if ((expectedCounts.fastestNodeIndex === null && fastestCount !== 0) ||
    (expectedCounts.fastestNodeIndex !== null && fastestCount !== 1)) {
    fail(operation);
  }

  return cloneCoreProxyDelaySnapshot(snapshot);
}

export function decodeStartProxyDelayTest(
  raw: Object | string | undefined,
  expectedContext: CoreProxyQueryContext,
  expectedGroupName: string
): CoreProxyDelaySnapshot {
  const operation: string = 'startProxyDelayTest';
  const expected: CoreProxyQueryContext = requireExpectedContext(operation, expectedContext);
  const groupName: string = requireExpectedGroupName(expectedGroupName, operation);
  const snapshot: CoreProxyDelaySnapshot = decodeSnapshot(raw, operation);
  if (snapshot.groupName !== groupName) {
    fail(operation);
  }
  if (snapshot.profileHash !== expected.profileHash ||
    snapshot.revisionHash !== expected.revisionHash ||
    snapshot.sessionHash !== expected.sessionHash ||
    snapshot.generation !== expected.generation) {
    fail(operation);
  }
  return cloneCoreProxyDelaySnapshot(snapshot);
}

export function decodeReadProxyDelayTest(raw: Object | string | undefined, expectedJobId: string): CoreProxyDelaySnapshot {
  const operation: string = 'readProxyDelayTest';
  const jobId: string = requireExpectedJobId(expectedJobId, operation);
  const snapshot: CoreProxyDelaySnapshot = decodeSnapshot(raw, operation);
  if (snapshot.jobId !== jobId) {
    fail(operation);
  }
  return cloneCoreProxyDelaySnapshot(snapshot);
}

export function decodeCancelProxyDelayTest(raw: Object | string | undefined, expectedJobId: string): CoreProxyDelaySnapshot {
  const operation: string = 'cancelProxyDelayTest';
  const jobId: string = requireExpectedJobId(expectedJobId, operation);
  const snapshot: CoreProxyDelaySnapshot = decodeSnapshot(raw, operation);
  if (snapshot.jobId !== jobId) {
    fail(operation);
  }
  return cloneCoreProxyDelaySnapshot(snapshot);
}
