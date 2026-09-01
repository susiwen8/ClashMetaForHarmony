import {
  cloneVpnRpcBody,
  cloneVpnRpcClientAuthBody,
  cloneVpnRpcServerAuthBody,
  cloneVpnRpcServerHelloBody,
  createVpnRpcClientAuthBody,
  createVpnRpcBodyErrorResponse,
  createVpnRpcBodyEvent,
  createVpnRpcBodyRequest,
  createVpnRpcBodySuccessResponse,
  createVpnRpcError,
  createVpnRpcGuards,
  createVpnRpcServerAuthBody,
  createVpnRpcServerHelloBody,
  type VpnRpcBody,
  type VpnRpcClientAuthBody,
  type VpnRpcError,
  type VpnRpcGuards,
  type VpnRpcServerAuthBody,
  type VpnRpcServerHelloBody
} from './VpnRpcModels';
import {
  cloneVpnRpcCatalogDigestPayload,
  cloneVpnRpcDelayGroupRequestPayload,
  cloneVpnRpcDelayJobRequestPayload,
  cloneVpnRpcDelaySnapshotPayload,
  cloneVpnRpcEmptyPayload,
  cloneVpnRpcPingSuccessPayload,
  cloneVpnRpcQueryGroupPayload,
  cloneVpnRpcQueryGroupRequestPayload,
  cloneVpnRpcQueryGroupsPayload,
  cloneVpnRpcRuntimeSnapshotPayload,
  cloneVpnRpcRuntimeModePayload,
  cloneVpnRpcSelectNodeRequestPayload,
  cloneVpnRpcSelectNodeResultPayload,
  createVpnRpcCatalogDigestPayload,
  createVpnRpcDelayGroupRequestPayload,
  createVpnRpcDelayJobRequestPayload,
  createVpnRpcDelayResult,
  createVpnRpcDelaySnapshotPayload,
  createVpnRpcEmptyPayload,
  createVpnRpcGroupNode,
  createVpnRpcGroupRef,
  createVpnRpcPingSuccessPayload,
  createVpnRpcQueryGroupPayload,
  createVpnRpcQueryGroupRequestPayload,
  createVpnRpcQueryGroupsPayload,
  createVpnRpcRuntimeSnapshotPayload,
  createVpnRpcRuntimeModePayload,
  createVpnRpcSelectNodeRequestPayload,
  createVpnRpcSelectNodeResultPayload,
  type VpnRpcCatalogDigestPayload,
  type VpnRpcDelayGroupRequestPayload,
  type VpnRpcDelayJobRequestPayload,
  type VpnRpcDelayResult,
  type VpnRpcDelaySnapshotPayload,
  type VpnRpcEmptyPayload,
  type VpnRpcGroupNode,
  type VpnRpcGroupRef,
  type VpnRpcPayload,
  type VpnRpcPingSuccessPayload,
  type VpnRpcQueryGroupPayload,
  type VpnRpcQueryGroupRequestPayload,
  type VpnRpcQueryGroupsPayload,
  type VpnRpcRuntimeSnapshotPayload,
  type VpnRpcRuntimeModePayload,
  type VpnRpcSelectNodeRequestPayload,
  type VpnRpcSelectNodeResultPayload
} from './VpnRpcPayloads';

const BODY_KEYS: string[] = [
  'protocolVersion',
  'kind',
  'sequence',
  'clientEpoch',
  'requestOrdinal',
  'requestId',
  'method',
  'sessionGeneration',
  'guards',
  'ok',
  'error',
  'payload'
];
const GUARDS_KEYS: string[] = ['profileHash', 'revisionHash', 'catalogDigest'];
const ERROR_KEYS: string[] = ['code', 'retryable'];
const RUNTIME_SNAPSHOT_KEYS: string[] = [
  'state',
  'profileHash',
  'revisionHash',
  'catalogDigest',
  'notificationActive',
  'recoveryAttempt',
  'scheduledRetryDelayMs',
  'runtimeFailureCode',
  'txBytes',
  'rxBytes'
];
const RUNTIME_MODE_KEYS: string[] = ['mode'];
const QUERY_GROUPS_KEYS: string[] = ['proxyGeneration', 'groups'];
const GROUP_REF_KEYS: string[] = ['groupId', 'type', 'isSelectable'];
const QUERY_GROUP_KEYS: string[] = ['proxyGeneration', 'groupId', 'selectedNodeId', 'nodes'];
const GROUP_NODE_KEYS: string[] = ['nodeId', 'kind', 'type', 'selected'];
const SELECT_NODE_RESULT_KEYS: string[] = ['proxyGeneration', 'groupId', 'selectedNodeId', 'persisted'];
const CATALOG_DIGEST_KEYS: string[] = ['catalogDigest', 'entryCount'];
const PING_SUCCESS_KEYS: string[] = ['serverInstance'];
const DELAY_SNAPSHOT_KEYS: string[] = [
  'jobId',
  'delayRevision',
  'proxyGeneration',
  'groupId',
  'state',
  'totalCount',
  'completedCount',
  'results'
];
const DELAY_RESULT_KEYS: string[] = ['nodeId', 'status', 'delayMs'];
const REQUEST_QUERY_GROUP_KEYS: string[] = ['groupId'];
const REQUEST_SELECT_NODE_KEYS: string[] = ['proxyGeneration', 'groupId', 'nodeId'];
const REQUEST_DELAY_GROUP_KEYS: string[] = ['proxyGeneration', 'groupId'];
const REQUEST_DELAY_JOB_KEYS: string[] = ['jobId'];
const EMPTY_KEYS: string[] = [];
const SERVER_HELLO_KEYS: string[] = ['protocolVersion', 'serverNonce', 'serverInstance'];
const CLIENT_AUTH_KEYS: string[] = ['protocolVersion', 'clientNonce', 'clientProof'];
const SERVER_AUTH_KEYS: string[] = ['protocolVersion', 'clientEpoch', 'serverProof'];
class JsonStringScanValue {
  value: string = '';
  nextIndex: number = 0;
}

function failBody(reason: string = 'body'): never {
  throw new Error(`Invalid VPN RPC body: ${reason}.`);
}

function failBytes(reason: string = 'bytes'): never {
  throw new Error(`Invalid VPN RPC body bytes: ${reason}.`);
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
  return containsKey(keys, '__proto__') || containsKey(keys, 'constructor') || containsKey(keys, 'proto' + 'type');
}

function requirePlainObject(value: Object | null | undefined, expectedKeys: string[]): Record<string, Object> {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    failBody('object');
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  const actualKeys: string[] = Object.keys(record);
  if (hasForbiddenMetaKey(actualKeys)) {
    failBody('forbiddenKey');
  }
  for (let index: number = 0; index < actualKeys.length; index += 1) {
    if (!containsKey(expectedKeys, actualKeys[index])) {
      failBody('extra');
    }
  }
  for (let index: number = 0; index < expectedKeys.length; index += 1) {
    if (!containsKey(actualKeys, expectedKeys[index])) {
      failBody('missing');
    }
  }
  for (let index: number = 0; index < expectedKeys.length; index += 1) {
    if (actualKeys[index] !== expectedKeys[index]) {
      failBody('keyOrder');
    }
  }
  return record;
}

function requireArray(value: Object | undefined): Object[] {
  if (!Array.isArray(value)) {
    failBody();
  }
  return value as Object[];
}

function requireString(value: Object | undefined): string {
  if (typeof value !== 'string') {
    failBody();
  }
  return value;
}

function requireBoolean(value: Object | undefined): boolean {
  if (typeof value !== 'boolean') {
    failBody();
  }
  return value;
}

function requireNullableBoolean(value: Object | undefined): boolean | null {
  if (value === null) {
    return null;
  }
  return requireBoolean(value);
}

function requireNumber(value: Object | undefined): number {
  if (typeof value !== 'number') {
    failBody();
  }
  if (!Number.isSafeInteger(value)) {
    failBody();
  }
  return value;
}

function requirePositiveInteger(value: Object | undefined): number {
  const numberValue: number = requireNumber(value);
  if (numberValue <= 0) {
    failBody();
  }
  return numberValue;
}

function requireNonNegativeInteger(value: Object | undefined): number {
  const numberValue: number = requireNumber(value);
  if (numberValue < 0) {
    failBody();
  }
  return numberValue;
}

function requireNullablePositiveInteger(value: Object | undefined): number | null {
  if (value === null) {
    return null;
  }
  return requirePositiveInteger(value);
}

function requireNull(value: Object | undefined): null {
  if (value !== null) {
    failBody();
  }
  return null;
}

function requireNullableString(value: Object | undefined): string | null {
  if (value === null) {
    return null;
  }
  return requireString(value);
}

function skipWhitespace(raw: string, start: number): number {
  let index: number = start;
  while (index < raw.length) {
    const codeUnit: number = raw.charCodeAt(index);
    if (codeUnit !== 0x20 && codeUnit !== 0x0a && codeUnit !== 0x0d && codeUnit !== 0x09) {
      break;
    }
    index += 1;
  }
  return index;
}

function decodeHexDigit(codeUnit: number): number {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) {
    return codeUnit - 0x30;
  }
  if (codeUnit >= 0x41 && codeUnit <= 0x46) {
    return codeUnit - 0x41 + 10;
  }
  if (codeUnit >= 0x61 && codeUnit <= 0x66) {
    return codeUnit - 0x61 + 10;
  }
  failBody();
}

function scanJsonString(raw: string, start: number): JsonStringScanValue {
  if (raw.charCodeAt(start) !== 0x22) {
    failBody();
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
        failBody();
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
          failBody();
        }
        let scalar: number = 0;
        for (let offset: number = 1; offset <= 4; offset += 1) {
          scalar = (scalar << 4) + decodeHexDigit(raw.charCodeAt(index + offset));
        }
        value += String.fromCharCode(scalar);
        index += 5;
        continue;
      }
      failBody();
    }
    if (codeUnit <= 0x1f) {
      failBody();
    }
    value += raw[index];
    index += 1;
  }
  failBody();
}

function scanJsonLiteral(raw: string, start: number, expected: string): number {
  for (let index: number = 0; index < expected.length; index += 1) {
    if (start + index >= raw.length || raw[start + index] !== expected[index]) {
      failBody();
    }
  }
  return start + expected.length;
}

function scanJsonNumber(raw: string, start: number): number {
  let index: number = start;
  if (raw[index] === '-') {
    index += 1;
  }
  if (index >= raw.length) {
    failBody();
  }
  const firstDigit: number = raw.charCodeAt(index);
  if (firstDigit < 0x30 || firstDigit > 0x39) {
    failBody();
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
    failBody();
  }
  if (index < raw.length && (raw[index] === 'e' || raw[index] === 'E')) {
    failBody();
  }
  return index;
}

function scanJsonValue(raw: string, start: number): number {
  const index: number = skipWhitespace(raw, start);
  if (index >= raw.length) {
    failBody();
  }
  const marker: string = raw[index];
  if (marker === '{') {
    return scanJsonObject(raw, index);
  }
  if (marker === '[') {
    return scanJsonArray(raw, index);
  }
  if (marker === '"') {
    return scanJsonString(raw, index).nextIndex;
  }
  if (marker === 't') {
    return scanJsonLiteral(raw, index, 'true');
  }
  if (marker === 'f') {
    return scanJsonLiteral(raw, index, 'false');
  }
  if (marker === 'n') {
    return scanJsonLiteral(raw, index, 'null');
  }
  if (marker === '-' || (marker >= '0' && marker <= '9')) {
    return scanJsonNumber(raw, index);
  }
  failBody();
}

function scanJsonArray(raw: string, start: number): number {
  let index: number = skipWhitespace(raw, start + 1);
  if (index >= raw.length) {
    failBody();
  }
  if (raw[index] === ']') {
    return index + 1;
  }
  while (index < raw.length) {
    index = scanJsonValue(raw, index);
    index = skipWhitespace(raw, index);
    if (index >= raw.length) {
      failBody();
    }
    if (raw[index] === ',') {
      index = skipWhitespace(raw, index + 1);
      continue;
    }
    if (raw[index] === ']') {
      return index + 1;
    }
    failBody();
  }
  failBody();
}

function scanJsonObject(raw: string, start: number): number {
  let index: number = skipWhitespace(raw, start + 1);
  const keys: string[] = [];
  if (index >= raw.length) {
    failBody();
  }
  if (raw[index] === '}') {
    return index + 1;
  }
  while (index < raw.length) {
    const keyResult: JsonStringScanValue = scanJsonString(raw, index);
    if (containsKey(keys, keyResult.value)) {
      failBody();
    }
    keys.push(keyResult.value);
    index = skipWhitespace(raw, keyResult.nextIndex);
    if (index >= raw.length || raw[index] !== ':') {
      failBody();
    }
    index = scanJsonValue(raw, index + 1);
    index = skipWhitespace(raw, index);
    if (index >= raw.length) {
      failBody();
    }
    if (raw[index] === ',') {
      index = skipWhitespace(raw, index + 1);
      continue;
    }
    if (raw[index] === '}') {
      return index + 1;
    }
    failBody();
  }
  failBody();
}

function validateNoDuplicateObjectKeys(raw: string): void {
  const endIndex: number = scanJsonValue(raw, 0);
  if (skipWhitespace(raw, endIndex) !== raw.length) {
    failBody('syntax');
  }
}

function validateCanonicalText(raw: string): void {
  if (raw.length === 0) {
    failBody('empty');
  }
  if (raw.charCodeAt(0) === 0xfeff) {
    failBody('bom');
  }
  for (let index: number = 0; index < raw.length; index += 1) {
    const codeUnit: number = raw.charCodeAt(index);
    if (codeUnit === 0x00) {
      failBody('nul');
    }
    if (codeUnit <= 0x20) {
      failBody('whitespace');
    }
    if (codeUnit > 0x7e) {
      failBody('utf8');
    }
    if (codeUnit === 0x5c) {
      failBody('escape');
    }
  }
}

function encodeAscii(text: string): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(text.length);
  for (let index: number = 0; index < text.length; index += 1) {
    bytes[index] = text.charCodeAt(index);
  }
  return bytes;
}

function decodeAscii(bytes: Uint8Array): string {
  if (bytes.length === 0) {
    failBytes('empty');
  }
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    failBytes('bom');
  }
  let text: string = '';
  for (let index: number = 0; index < bytes.length; index += 1) {
    const byteValue: number = bytes[index];
    if (byteValue === 0x00) {
      failBytes('nul');
    }
    if (byteValue <= 0x20) {
      failBytes('whitespace');
    }
    if (byteValue > 0x7e) {
      failBytes('utf8');
    }
    if (byteValue === 0x5c) {
      failBytes('escape');
    }
    text += String.fromCharCode(byteValue);
  }
  return text;
}

function quote(value: string): string {
  return `"${value}"`;
}

function encodeNullableString(value: string | null): string {
  return value === null ? 'null' : quote(value);
}

function encodeNullableBoolean(value: boolean | null): string {
  if (value === null) {
    return 'null';
  }
  return value ? 'true' : 'false';
}

function encodeGuards(guards: VpnRpcGuards): string {
  return `{"profileHash":${encodeNullableString(guards.profileHash)},"revisionHash":${encodeNullableString(guards.revisionHash)},"catalogDigest":${encodeNullableString(guards.catalogDigest)}}`;
}

function encodeError(error: VpnRpcError | null): string {
  if (error === null) {
    return 'null';
  }
  return `{"code":${quote(error.code)},"retryable":${error.retryable ? 'true' : 'false'}}`;
}

function encodeRuntimeSnapshotPayload(payload: VpnRpcRuntimeSnapshotPayload): string {
  return `{"state":${quote(payload.state)},"profileHash":${encodeNullableString(payload.profileHash)},"revisionHash":${encodeNullableString(payload.revisionHash)},"catalogDigest":${encodeNullableString(payload.catalogDigest)},"notificationActive":${payload.notificationActive ? 'true' : 'false'},"recoveryAttempt":${payload.recoveryAttempt},"scheduledRetryDelayMs":${payload.scheduledRetryDelayMs === null ? 'null' : String(payload.scheduledRetryDelayMs)},"runtimeFailureCode":${encodeNullableString(payload.runtimeFailureCode)},"txBytes":${payload.txBytes},"rxBytes":${payload.rxBytes}}`;
}

function encodeQueryGroupsPayload(payload: VpnRpcQueryGroupsPayload): string {
  let groupsText: string = '[';
  for (let index: number = 0; index < payload.groups.length; index += 1) {
    const group: VpnRpcGroupRef = payload.groups[index];
    if (index > 0) {
      groupsText += ',';
    }
    groupsText += `{"groupId":${quote(group.groupId)},"type":${quote(group.type)},"isSelectable":${group.isSelectable ? 'true' : 'false'}}`;
  }
  groupsText += ']';
  return `{"proxyGeneration":${payload.proxyGeneration},"groups":${groupsText}}`;
}

function encodeQueryGroupPayload(payload: VpnRpcQueryGroupPayload): string {
  let nodesText: string = '[';
  for (let index: number = 0; index < payload.nodes.length; index += 1) {
    const node: VpnRpcGroupNode = payload.nodes[index];
    if (index > 0) {
      nodesText += ',';
    }
    nodesText += `{"nodeId":${quote(node.nodeId)},"kind":${quote(node.kind)},"type":${quote(node.type)},"selected":${node.selected ? 'true' : 'false'}}`;
  }
  nodesText += ']';
  return `{"proxyGeneration":${payload.proxyGeneration},"groupId":${quote(payload.groupId)},"selectedNodeId":${encodeNullableString(payload.selectedNodeId)},"nodes":${nodesText}}`;
}

function encodeSelectNodeResultPayload(payload: VpnRpcSelectNodeResultPayload): string {
  return `{"proxyGeneration":${payload.proxyGeneration},"groupId":${quote(payload.groupId)},"selectedNodeId":${encodeNullableString(payload.selectedNodeId)},"persisted":${payload.persisted ? 'true' : 'false'}}`;
}

function encodeDelaySnapshotPayload(payload: VpnRpcDelaySnapshotPayload): string {
  let resultsText: string = '[';
  for (let index: number = 0; index < payload.results.length; index += 1) {
    const result: VpnRpcDelayResult = payload.results[index];
    if (index > 0) {
      resultsText += ',';
    }
    resultsText += `{"nodeId":${quote(result.nodeId)},"status":${quote(result.status)},"delayMs":${result.delayMs === null ? 'null' : String(result.delayMs)}}`;
  }
  resultsText += ']';
  return `{"jobId":${quote(payload.jobId)},"delayRevision":${payload.delayRevision},"proxyGeneration":${payload.proxyGeneration},"groupId":${quote(payload.groupId)},"state":${quote(payload.state)},"totalCount":${payload.totalCount},"completedCount":${payload.completedCount},"results":${resultsText}}`;
}

function encodeVpnRpcServerHelloBodyTextValue(body: VpnRpcServerHelloBody): string {
  const normalized: VpnRpcServerHelloBody = cloneVpnRpcServerHelloBody(body);
  return `{"protocolVersion":1,"serverNonce":${quote(normalized.serverNonce)},"serverInstance":${quote(normalized.serverInstance)}}`;
}

function encodeVpnRpcClientAuthBodyTextValue(body: VpnRpcClientAuthBody): string {
  const normalized: VpnRpcClientAuthBody = cloneVpnRpcClientAuthBody(body);
  return `{"protocolVersion":1,"clientNonce":${quote(normalized.clientNonce)},"clientProof":${quote(normalized.clientProof)}}`;
}

function encodeVpnRpcServerAuthBodyTextValue(body: VpnRpcServerAuthBody): string {
  const normalized: VpnRpcServerAuthBody = cloneVpnRpcServerAuthBody(body);
  return `{"protocolVersion":1,"clientEpoch":${normalized.clientEpoch},"serverProof":${quote(normalized.serverProof)}}`;
}

function decodeVpnRpcServerHelloBodyRecord(record: Record<string, Object>): VpnRpcServerHelloBody {
  if (requireNumber(record.protocolVersion) !== 1) {
    failBody('protocolVersion');
  }
  return createVpnRpcServerHelloBody(1, requireString(record.serverNonce), requireString(record.serverInstance));
}

function decodeVpnRpcClientAuthBodyRecord(record: Record<string, Object>): VpnRpcClientAuthBody {
  if (requireNumber(record.protocolVersion) !== 1) {
    failBody('protocolVersion');
  }
  return createVpnRpcClientAuthBody(1, requireString(record.clientNonce), requireString(record.clientProof));
}

function decodeVpnRpcServerAuthBodyRecord(record: Record<string, Object>): VpnRpcServerAuthBody {
  if (requireNumber(record.protocolVersion) !== 1) {
    failBody('protocolVersion');
  }
  return createVpnRpcServerAuthBody(1, requirePositiveInteger(record.clientEpoch), requireString(record.serverProof));
}

function encodePayload(body: VpnRpcBody): string {
  const payload: VpnRpcPayload = body.payload;
  if (body.kind === 'REQUEST') {
    switch (body.method) {
      case 'PING':
      case 'GET_SNAPSHOT':
      case 'GET_CATALOG_DIGEST':
      case 'GET_MODE':
      case 'QUERY_GROUPS':
      case 'STOP_VPN':
        return '{}';
      case 'SET_MODE':
        return `{"mode":${quote((payload as VpnRpcRuntimeModePayload).mode)}}`;
      case 'QUERY_GROUP': {
        const requestPayload: VpnRpcQueryGroupRequestPayload = payload as VpnRpcQueryGroupRequestPayload;
        return `{"groupId":${quote(requestPayload.groupId)}}`;
      }
      case 'SELECT_NODE': {
        const requestPayload: VpnRpcSelectNodeRequestPayload = payload as VpnRpcSelectNodeRequestPayload;
        return `{"proxyGeneration":${requestPayload.proxyGeneration},"groupId":${quote(requestPayload.groupId)},"nodeId":${quote(requestPayload.nodeId)}}`;
      }
      case 'START_DELAY_TEST': {
        const requestPayload: VpnRpcDelayGroupRequestPayload = payload as VpnRpcDelayGroupRequestPayload;
        return `{"proxyGeneration":${requestPayload.proxyGeneration},"groupId":${quote(requestPayload.groupId)}}`;
      }
      case 'READ_DELAY_TEST':
      case 'CANCEL_DELAY_TEST': {
        const requestPayload: VpnRpcDelayJobRequestPayload = payload as VpnRpcDelayJobRequestPayload;
        return `{"jobId":${quote(requestPayload.jobId)}}`;
      }
      default:
        failBody('method');
    }
  }
  if (body.kind === 'EVENT') {
    switch (body.method) {
      case 'RUNTIME_CHANGED':
        return encodeRuntimeSnapshotPayload(payload as VpnRpcRuntimeSnapshotPayload);
      case 'DELAY_CHANGED':
        return encodeDelaySnapshotPayload(payload as VpnRpcDelaySnapshotPayload);
      case 'SERVER_STOPPING':
        return '{}';
      default:
        failBody('method');
    }
  }
  if (body.ok === false) {
    return '{}';
  }
  switch (body.method) {
    case 'PING':
      return `{"serverInstance":${quote((payload as VpnRpcPingSuccessPayload).serverInstance)}}`;
    case 'GET_SNAPSHOT':
    case 'STOP_VPN':
      return encodeRuntimeSnapshotPayload(payload as VpnRpcRuntimeSnapshotPayload);
    case 'GET_CATALOG_DIGEST': {
      const successPayload: VpnRpcCatalogDigestPayload = payload as VpnRpcCatalogDigestPayload;
      return `{"catalogDigest":${quote(successPayload.catalogDigest)},"entryCount":${successPayload.entryCount}}`;
    }
    case 'GET_MODE':
    case 'SET_MODE':
      return `{"mode":${quote((payload as VpnRpcRuntimeModePayload).mode)}}`;
    case 'QUERY_GROUPS':
      return encodeQueryGroupsPayload(payload as VpnRpcQueryGroupsPayload);
    case 'QUERY_GROUP':
      return encodeQueryGroupPayload(payload as VpnRpcQueryGroupPayload);
    case 'SELECT_NODE':
      return encodeSelectNodeResultPayload(payload as VpnRpcSelectNodeResultPayload);
    case 'START_DELAY_TEST':
    case 'READ_DELAY_TEST':
    case 'CANCEL_DELAY_TEST':
      return encodeDelaySnapshotPayload(payload as VpnRpcDelaySnapshotPayload);
    default:
      failBody('method');
  }
}

function encodeLoosePayloadText(payload: VpnRpcPayload): string {
  try {
    cloneVpnRpcEmptyPayload(payload);
    return '{}';
  } catch (_) {
  }
  try {
    return `{"serverInstance":${quote(cloneVpnRpcPingSuccessPayload(payload as VpnRpcPingSuccessPayload).serverInstance)}}`;
  } catch (_) {
  }
  try {
    return encodeRuntimeSnapshotPayload(cloneVpnRpcRuntimeSnapshotPayload(payload as VpnRpcRuntimeSnapshotPayload));
  } catch (_) {
  }
  try {
    return `{"mode":${quote(cloneVpnRpcRuntimeModePayload(payload as VpnRpcRuntimeModePayload).mode)}}`;
  } catch (_) {
  }
  try {
    const catalogPayload: VpnRpcCatalogDigestPayload = cloneVpnRpcCatalogDigestPayload(payload as VpnRpcCatalogDigestPayload);
    return `{"catalogDigest":${quote(catalogPayload.catalogDigest)},"entryCount":${catalogPayload.entryCount}}`;
  } catch (_) {
  }
  try {
    return `{"groupId":${quote(cloneVpnRpcQueryGroupRequestPayload(payload as VpnRpcQueryGroupRequestPayload).groupId)}}`;
  } catch (_) {
  }
  try {
    const selectNodeRequest: VpnRpcSelectNodeRequestPayload = cloneVpnRpcSelectNodeRequestPayload(payload as VpnRpcSelectNodeRequestPayload);
    return `{"proxyGeneration":${selectNodeRequest.proxyGeneration},"groupId":${quote(selectNodeRequest.groupId)},"nodeId":${quote(selectNodeRequest.nodeId)}}`;
  } catch (_) {
  }
  try {
    const delayGroupRequest: VpnRpcDelayGroupRequestPayload = cloneVpnRpcDelayGroupRequestPayload(payload as VpnRpcDelayGroupRequestPayload);
    return `{"proxyGeneration":${delayGroupRequest.proxyGeneration},"groupId":${quote(delayGroupRequest.groupId)}}`;
  } catch (_) {
  }
  try {
    return `{"jobId":${quote(cloneVpnRpcDelayJobRequestPayload(payload as VpnRpcDelayJobRequestPayload).jobId)}}`;
  } catch (_) {
  }
  try {
    return encodeQueryGroupsPayload(cloneVpnRpcQueryGroupsPayload(payload as VpnRpcQueryGroupsPayload));
  } catch (_) {
  }
  try {
    return encodeQueryGroupPayload(cloneVpnRpcQueryGroupPayload(payload as VpnRpcQueryGroupPayload));
  } catch (_) {
  }
  try {
    return encodeSelectNodeResultPayload(cloneVpnRpcSelectNodeResultPayload(payload as VpnRpcSelectNodeResultPayload));
  } catch (_) {
  }
  try {
    return encodeDelaySnapshotPayload(cloneVpnRpcDelaySnapshotPayload(payload as VpnRpcDelaySnapshotPayload));
  } catch (_) {
  }
  failBody();
}

function decodeGuards(value: Object | undefined): VpnRpcGuards {
  const record: Record<string, Object> = requirePlainObject(value, GUARDS_KEYS);
  return createVpnRpcGuards(
    requireNullableString(record.profileHash),
    requireNullableString(record.revisionHash),
    requireNullableString(record.catalogDigest)
  );
}

function decodeErrorRecord(value: Object | undefined): VpnRpcError {
  const record: Record<string, Object> = requirePlainObject(value, ERROR_KEYS);
  return createVpnRpcError(requireString(record.code), requireBoolean(record.retryable));
}

function decodeEmptyPayload(value: Object | undefined): VpnRpcEmptyPayload {
  requirePlainObject(value, EMPTY_KEYS);
  return createVpnRpcEmptyPayload();
}

function decodeRuntimeSnapshotPayload(value: Object | undefined): VpnRpcRuntimeSnapshotPayload {
  const record: Record<string, Object> = requirePlainObject(value, RUNTIME_SNAPSHOT_KEYS);
  return createVpnRpcRuntimeSnapshotPayload(
    requireString(record.state),
    requireNullableString(record.profileHash),
    requireNullableString(record.revisionHash),
    requireNullableString(record.catalogDigest),
    requireBoolean(record.notificationActive),
    requireNonNegativeInteger(record.recoveryAttempt),
    record.scheduledRetryDelayMs === null ? null : requirePositiveInteger(record.scheduledRetryDelayMs),
    requireNullableString(record.runtimeFailureCode),
    requireNonNegativeInteger(record.txBytes),
    requireNonNegativeInteger(record.rxBytes)
  );
}

function decodeQueryGroupsPayload(value: Object | undefined): VpnRpcQueryGroupsPayload {
  const record: Record<string, Object> = requirePlainObject(value, QUERY_GROUPS_KEYS);
  const rawGroups: Object[] = requireArray(record.groups);
  const groups: VpnRpcGroupRef[] = [];
  for (let index: number = 0; index < rawGroups.length; index += 1) {
    const item: Record<string, Object> = requirePlainObject(rawGroups[index], GROUP_REF_KEYS);
    groups.push(createVpnRpcGroupRef(requireString(item.groupId), requireString(item.type), requireBoolean(item.isSelectable)));
  }
  return createVpnRpcQueryGroupsPayload(requirePositiveInteger(record.proxyGeneration), groups);
}

function decodeQueryGroupPayload(value: Object | undefined): VpnRpcQueryGroupPayload {
  const record: Record<string, Object> = requirePlainObject(value, QUERY_GROUP_KEYS);
  const rawNodes: Object[] = requireArray(record.nodes);
  const nodes: VpnRpcGroupNode[] = [];
  for (let index: number = 0; index < rawNodes.length; index += 1) {
    const item: Record<string, Object> = requirePlainObject(rawNodes[index], GROUP_NODE_KEYS);
    nodes.push(
      createVpnRpcGroupNode(
        requireString(item.nodeId),
        requireString(item.kind),
        requireString(item.type),
        requireBoolean(item.selected)
      )
    );
  }
  return createVpnRpcQueryGroupPayload(
    requirePositiveInteger(record.proxyGeneration),
    requireString(record.groupId),
    requireNullableString(record.selectedNodeId),
    nodes
  );
}

function decodeSelectNodeResultPayload(value: Object | undefined): VpnRpcSelectNodeResultPayload {
  const record: Record<string, Object> = requirePlainObject(value, SELECT_NODE_RESULT_KEYS);
  return createVpnRpcSelectNodeResultPayload(
    requirePositiveInteger(record.proxyGeneration),
    requireString(record.groupId),
    requireNullableString(record.selectedNodeId),
    requireBoolean(record.persisted)
  );
}

function decodeDelaySnapshotPayload(value: Object | undefined): VpnRpcDelaySnapshotPayload {
  const record: Record<string, Object> = requirePlainObject(value, DELAY_SNAPSHOT_KEYS);
  const rawResults: Object[] = requireArray(record.results);
  const results: VpnRpcDelayResult[] = [];
  for (let index: number = 0; index < rawResults.length; index += 1) {
    const item: Record<string, Object> = requirePlainObject(rawResults[index], DELAY_RESULT_KEYS);
    const delayMs: number | null = item.delayMs === null ? null : requirePositiveInteger(item.delayMs);
    results.push(createVpnRpcDelayResult(requireString(item.nodeId), requireString(item.status), delayMs));
  }
  return createVpnRpcDelaySnapshotPayload(
    requireString(record.jobId),
    requirePositiveInteger(record.delayRevision),
    requirePositiveInteger(record.proxyGeneration),
    requireString(record.groupId),
    requireString(record.state),
    requireNonNegativeInteger(record.totalCount),
    requireNonNegativeInteger(record.completedCount),
    results
  );
}

function decodeRuntimeModePayload(value: Object | undefined): VpnRpcRuntimeModePayload {
  const record: Record<string, Object> = requirePlainObject(value, RUNTIME_MODE_KEYS);
  return createVpnRpcRuntimeModePayload(requireString(record.mode));
}

function decodeRequestPayload(method: string, value: Object | undefined): VpnRpcPayload {
  switch (method) {
    case 'PING':
    case 'GET_SNAPSHOT':
    case 'GET_CATALOG_DIGEST':
    case 'GET_MODE':
    case 'QUERY_GROUPS':
    case 'STOP_VPN':
      return decodeEmptyPayload(value);
    case 'SET_MODE':
      return decodeRuntimeModePayload(value);
    case 'QUERY_GROUP': {
      const record: Record<string, Object> = requirePlainObject(value, REQUEST_QUERY_GROUP_KEYS);
      return createVpnRpcQueryGroupRequestPayload(requireString(record.groupId));
    }
    case 'SELECT_NODE': {
      const record: Record<string, Object> = requirePlainObject(value, REQUEST_SELECT_NODE_KEYS);
      return createVpnRpcSelectNodeRequestPayload(
        requirePositiveInteger(record.proxyGeneration),
        requireString(record.groupId),
        requireString(record.nodeId)
      );
    }
    case 'START_DELAY_TEST': {
      const record: Record<string, Object> = requirePlainObject(value, REQUEST_DELAY_GROUP_KEYS);
      return createVpnRpcDelayGroupRequestPayload(requirePositiveInteger(record.proxyGeneration), requireString(record.groupId));
    }
    case 'READ_DELAY_TEST':
    case 'CANCEL_DELAY_TEST': {
      const record: Record<string, Object> = requirePlainObject(value, REQUEST_DELAY_JOB_KEYS);
      return createVpnRpcDelayJobRequestPayload(requireString(record.jobId));
    }
    default:
      failBody('method');
  }
}

function decodeSuccessPayload(method: string, value: Object | undefined): VpnRpcPayload {
  switch (method) {
    case 'PING': {
      const record: Record<string, Object> = requirePlainObject(value, PING_SUCCESS_KEYS);
      return createVpnRpcPingSuccessPayload(requireString(record.serverInstance));
    }
    case 'GET_SNAPSHOT':
    case 'STOP_VPN':
      return decodeRuntimeSnapshotPayload(value);
    case 'GET_CATALOG_DIGEST': {
      const record: Record<string, Object> = requirePlainObject(value, CATALOG_DIGEST_KEYS);
      return createVpnRpcCatalogDigestPayload(requireString(record.catalogDigest), requireNonNegativeInteger(record.entryCount));
    }
    case 'GET_MODE':
    case 'SET_MODE':
      return decodeRuntimeModePayload(value);
    case 'QUERY_GROUPS':
      return decodeQueryGroupsPayload(value);
    case 'QUERY_GROUP':
      return decodeQueryGroupPayload(value);
    case 'SELECT_NODE':
      return decodeSelectNodeResultPayload(value);
    case 'START_DELAY_TEST':
    case 'READ_DELAY_TEST':
    case 'CANCEL_DELAY_TEST':
      return decodeDelaySnapshotPayload(value);
    default:
      failBody('method');
  }
}

function requireResponseMethod(method: string): void {
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
      return;
    default:
      failBody('method');
  }
}

export function encodeVpnRpcBodyToText(body: VpnRpcBody): string;
export function encodeVpnRpcBodyToText(payload: VpnRpcPayload): string;
export function encodeVpnRpcBodyToText(value: VpnRpcBody | VpnRpcPayload): string {
  try {
    const normalized: VpnRpcBody = cloneVpnRpcBody(value as VpnRpcBody);
    return `{"protocolVersion":1,"kind":${quote(normalized.kind)},"sequence":${normalized.sequence},"clientEpoch":${normalized.clientEpoch},"requestOrdinal":${normalized.requestOrdinal === null ? 'null' : String(normalized.requestOrdinal)},"requestId":${encodeNullableString(normalized.requestId)},"method":${quote(normalized.method)},"sessionGeneration":${normalized.sessionGeneration},"guards":${encodeGuards(normalized.guards)},"ok":${encodeNullableBoolean(normalized.ok)},"error":${encodeError(normalized.error)},"payload":${encodePayload(normalized)}}`;
  } catch (_) {
  }
  return encodeLoosePayloadText(value as VpnRpcPayload);
}

export function encodeVpnRpcBody(body: VpnRpcBody): Uint8Array {
  return encodeAscii(encodeVpnRpcBodyToText(body));
}

export function encodeVpnRpcServerHelloBodyToText(body: VpnRpcServerHelloBody): string {
  return encodeVpnRpcServerHelloBodyTextValue(body);
}

export function encodeVpnRpcServerHelloBody(body: VpnRpcServerHelloBody): Uint8Array {
  return encodeAscii(encodeVpnRpcServerHelloBodyToText(body));
}

export function decodeVpnRpcServerHelloBodyText(text: string): VpnRpcServerHelloBody {
  validateCanonicalText(text);
  validateNoDuplicateObjectKeys(text);

  let parsed: Object | null = null;
  try {
    parsed = JSON.parse(text);
  } catch (_) {
    failBody();
  }
  return decodeVpnRpcServerHelloBodyRecord(requirePlainObject(parsed, SERVER_HELLO_KEYS));
}

export function decodeVpnRpcServerHelloBodyBytes(bytes: Uint8Array): VpnRpcServerHelloBody {
  return decodeVpnRpcServerHelloBodyText(decodeAscii(bytes));
}

export function encodeVpnRpcClientAuthBodyToText(body: VpnRpcClientAuthBody): string {
  return encodeVpnRpcClientAuthBodyTextValue(body);
}

export function encodeVpnRpcClientAuthBody(body: VpnRpcClientAuthBody): Uint8Array {
  return encodeAscii(encodeVpnRpcClientAuthBodyToText(body));
}

export function decodeVpnRpcClientAuthBodyText(text: string): VpnRpcClientAuthBody {
  validateCanonicalText(text);
  validateNoDuplicateObjectKeys(text);

  let parsed: Object | null = null;
  try {
    parsed = JSON.parse(text);
  } catch (_) {
    failBody();
  }
  return decodeVpnRpcClientAuthBodyRecord(requirePlainObject(parsed, CLIENT_AUTH_KEYS));
}

export function decodeVpnRpcClientAuthBodyBytes(bytes: Uint8Array): VpnRpcClientAuthBody {
  return decodeVpnRpcClientAuthBodyText(decodeAscii(bytes));
}

export function encodeVpnRpcServerAuthBodyToText(body: VpnRpcServerAuthBody): string {
  return encodeVpnRpcServerAuthBodyTextValue(body);
}

export function encodeVpnRpcServerAuthBody(body: VpnRpcServerAuthBody): Uint8Array {
  return encodeAscii(encodeVpnRpcServerAuthBodyToText(body));
}

export function decodeVpnRpcServerAuthBodyText(text: string): VpnRpcServerAuthBody {
  validateCanonicalText(text);
  validateNoDuplicateObjectKeys(text);

  let parsed: Object | null = null;
  try {
    parsed = JSON.parse(text);
  } catch (_) {
    failBody();
  }
  return decodeVpnRpcServerAuthBodyRecord(requirePlainObject(parsed, SERVER_AUTH_KEYS));
}

export function decodeVpnRpcServerAuthBodyBytes(bytes: Uint8Array): VpnRpcServerAuthBody {
  return decodeVpnRpcServerAuthBodyText(decodeAscii(bytes));
}

export function decodeVpnRpcBodyText(text: string): VpnRpcBody {
  validateCanonicalText(text);
  validateNoDuplicateObjectKeys(text);

  let parsed: Object | null = null;
  try {
    parsed = JSON.parse(text) as Object | null;
  } catch (_) {
    failBody();
  }

  const record: Record<string, Object> = requirePlainObject(parsed, BODY_KEYS);
  if (requireNumber(record.protocolVersion) !== 1) {
    failBody();
  }

  const kind: string = requireString(record.kind);
  const sequence: number = requirePositiveInteger(record.sequence);
  const clientEpoch: number = requirePositiveInteger(record.clientEpoch);
  const requestOrdinal: number | null = requireNullablePositiveInteger(record.requestOrdinal);
  const requestId: string | null = requireNullableString(record.requestId);
  const method: string = requireString(record.method);
  const sessionGeneration: number = requireNonNegativeInteger(record.sessionGeneration);
  const guards: VpnRpcGuards = decodeGuards(record.guards);

  if (kind === 'REQUEST') {
    requireNull(record.ok);
    requireNull(record.error);
    if (requestOrdinal === null || requestId === null) {
      failBody();
    }
    return createVpnRpcBodyRequest(
      sequence,
      clientEpoch,
      requestOrdinal,
      requestId,
      method,
      sessionGeneration,
      guards,
      decodeRequestPayload(method, record.payload)
    );
  }

  if (kind === 'EVENT') {
    requireNull(record.ok);
    requireNull(record.error);
    if (requestOrdinal !== null || requestId !== null) {
      failBody();
    }
    switch (method) {
      case 'RUNTIME_CHANGED':
        return createVpnRpcBodyEvent(sequence, clientEpoch, method, sessionGeneration, guards, decodeRuntimeSnapshotPayload(record.payload));
      case 'DELAY_CHANGED':
        return createVpnRpcBodyEvent(sequence, clientEpoch, method, sessionGeneration, guards, decodeDelaySnapshotPayload(record.payload));
      case 'SERVER_STOPPING':
        return createVpnRpcBodyEvent(sequence, clientEpoch, method, sessionGeneration, guards, decodeEmptyPayload(record.payload));
      default:
        failBody('method');
    }
  }

  if (kind !== 'RESPONSE' || requestOrdinal === null || requestId === null) {
    failBody(kind === 'RESPONSE' ? 'request' : 'kind');
  }

  const ok: boolean | null = requireNullableBoolean(record.ok);
  if (ok === true) {
    requireResponseMethod(method);
    requireNull(record.error);
    return createVpnRpcBodySuccessResponse(
      sequence,
      clientEpoch,
      requestOrdinal,
      requestId,
      method,
      sessionGeneration,
      guards,
      decodeSuccessPayload(method, record.payload)
    );
  }

  if (ok === false) {
    requireResponseMethod(method);
    decodeEmptyPayload(record.payload);
    return createVpnRpcBodyErrorResponse(
      sequence,
      clientEpoch,
      requestOrdinal,
      requestId,
      method,
      sessionGeneration,
      guards,
      decodeErrorRecord(record.error)
    );
  }

  failBody('ok');
}

export function decodeVpnRpcBodyBytes(bytes: Uint8Array): VpnRpcBody {
  return decodeVpnRpcBodyText(decodeAscii(bytes));
}
