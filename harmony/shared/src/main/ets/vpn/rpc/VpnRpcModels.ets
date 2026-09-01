import {
  cloneVpnRpcPayloadForEnvelope,
  createVpnRpcEmptyPayload,
  type VpnRpcPayload
} from './VpnRpcPayloads';

const HASH_64_PATTERN: RegExp = /^[0-9a-f]{64}$/u;
const HASH_32_PATTERN: RegExp = /^[0-9a-f]{32}$/u;
const UUID_PATTERN: RegExp = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

export type VpnRpcKind = 'REQUEST' | 'RESPONSE' | 'EVENT';
export type VpnRpcMethod =
  | 'PING'
  | 'GET_SNAPSHOT'
  | 'GET_CATALOG_DIGEST'
  | 'GET_MODE'
  | 'SET_MODE'
  | 'QUERY_GROUPS'
  | 'QUERY_GROUP'
  | 'SELECT_NODE'
  | 'START_DELAY_TEST'
  | 'READ_DELAY_TEST'
  | 'CANCEL_DELAY_TEST'
  | 'STOP_VPN'
  | 'RUNTIME_CHANGED'
  | 'DELAY_CHANGED'
  | 'SERVER_STOPPING';
export type VpnRpcTransportErrorCode =
  | 'RPC_UNAVAILABLE'
  | 'RPC_DISCONNECTED'
  | 'AUTH_FAILED'
  | 'PROTOCOL_MISMATCH'
  | 'FRAME_INVALID'
  | 'SESSION_CHANGED'
  | 'CATALOG_MISMATCH'
  | 'COMMAND_BUSY'
  | 'COMMAND_TIMEOUT'
  | 'CORE_OPERATION_FAILED'
  | 'REQUEST_REPLAY_EXPIRED'
  | 'SERVER_STOPPING';

export const VPN_RPC_KINDS: VpnRpcKind[] = ['REQUEST', 'RESPONSE', 'EVENT'];
export const VPN_RPC_REQUEST_METHODS: VpnRpcMethod[] = [
  'PING',
  'GET_SNAPSHOT',
  'GET_CATALOG_DIGEST',
  'GET_MODE',
  'SET_MODE',
  'QUERY_GROUPS',
  'QUERY_GROUP',
  'SELECT_NODE',
  'START_DELAY_TEST',
  'READ_DELAY_TEST',
  'CANCEL_DELAY_TEST',
  'STOP_VPN'
];
export const VPN_RPC_RESPONSE_METHODS: VpnRpcMethod[] = [
  'PING',
  'GET_SNAPSHOT',
  'GET_CATALOG_DIGEST',
  'GET_MODE',
  'SET_MODE',
  'QUERY_GROUPS',
  'QUERY_GROUP',
  'SELECT_NODE',
  'START_DELAY_TEST',
  'READ_DELAY_TEST',
  'CANCEL_DELAY_TEST',
  'STOP_VPN'
];
export const VPN_RPC_EVENT_METHODS: VpnRpcMethod[] = ['RUNTIME_CHANGED', 'DELAY_CHANGED', 'SERVER_STOPPING'];
export const VPN_RPC_METHODS: VpnRpcMethod[] = [
  'PING',
  'GET_SNAPSHOT',
  'GET_CATALOG_DIGEST',
  'GET_MODE',
  'SET_MODE',
  'QUERY_GROUPS',
  'QUERY_GROUP',
  'SELECT_NODE',
  'START_DELAY_TEST',
  'READ_DELAY_TEST',
  'CANCEL_DELAY_TEST',
  'STOP_VPN',
  'RUNTIME_CHANGED',
  'DELAY_CHANGED',
  'SERVER_STOPPING'
];
export const VPN_RPC_TRANSPORT_ERROR_CODES: VpnRpcTransportErrorCode[] = [
  'RPC_UNAVAILABLE',
  'RPC_DISCONNECTED',
  'AUTH_FAILED',
  'PROTOCOL_MISMATCH',
  'FRAME_INVALID',
  'SESSION_CHANGED',
  'CATALOG_MISMATCH',
  'COMMAND_BUSY',
  'COMMAND_TIMEOUT',
  'CORE_OPERATION_FAILED',
  'REQUEST_REPLAY_EXPIRED',
  'SERVER_STOPPING'
];

export interface VpnRpcServerHelloBody {
  protocolVersion: 1;
  serverNonce: string;
  serverInstance: string;
}

export interface VpnRpcClientAuthBody {
  protocolVersion: 1;
  clientNonce: string;
  clientProof: string;
}

export interface VpnRpcServerAuthBody {
  protocolVersion: 1;
  clientEpoch: number;
  serverProof: string;
}

export interface VpnRpcError {
  code: VpnRpcTransportErrorCode;
  retryable: boolean;
}

export interface VpnRpcGuards {
  profileHash: string | null;
  revisionHash: string | null;
  catalogDigest: string | null;
}

export interface VpnRpcBody {
  protocolVersion: 1;
  kind: VpnRpcKind;
  sequence: number;
  clientEpoch: number;
  requestOrdinal: number | null;
  requestId: string | null;
  method: VpnRpcMethod;
  sessionGeneration: number;
  guards: VpnRpcGuards;
  ok: boolean | null;
  error: VpnRpcError | null;
  payload: VpnRpcPayload;
}

class VpnRpcServerHelloBodyValue implements VpnRpcServerHelloBody {
  protocolVersion: 1 = 1;
  serverNonce: string = '';
  serverInstance: string = '';
}

class VpnRpcClientAuthBodyValue implements VpnRpcClientAuthBody {
  protocolVersion: 1 = 1;
  clientNonce: string = '';
  clientProof: string = '';
}

class VpnRpcServerAuthBodyValue implements VpnRpcServerAuthBody {
  protocolVersion: 1 = 1;
  clientEpoch: number = 0;
  serverProof: string = '';
}

class VpnRpcErrorValue implements VpnRpcError {
  code: VpnRpcTransportErrorCode = 'RPC_UNAVAILABLE';
  retryable: boolean = false;
}

class VpnRpcGuardsValue implements VpnRpcGuards {
  profileHash: string | null = null;
  revisionHash: string | null = null;
  catalogDigest: string | null = null;
}

class VpnRpcBodyValue implements VpnRpcBody {
  protocolVersion: 1 = 1;
  kind: VpnRpcKind = 'REQUEST';
  sequence: number = 0;
  clientEpoch: number = 0;
  requestOrdinal: number | null = null;
  requestId: string | null = null;
  method: VpnRpcMethod = 'PING';
  sessionGeneration: number = 0;
  guards: VpnRpcGuards = new VpnRpcGuardsValue();
  ok: boolean | null = null;
  error: VpnRpcError | null = null;
  payload: VpnRpcPayload = createVpnRpcEmptyPayload();
}

function requireProtocolVersion(protocolVersion: 1): void {
  if (protocolVersion !== 1) {
    throw new Error('VpnRpc protocolVersion must equal 1.');
  }
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

function requireLowercaseHex(rawValue: string, label: string, expectedLength: number): string {
  if (rawValue.length !== expectedLength) {
    throw new Error(`${label} must be exactly ${expectedLength} lowercase hex characters.`);
  }
  const pattern: RegExp = expectedLength === 32 ? HASH_32_PATTERN : HASH_64_PATTERN;
  if (!pattern.test(rawValue)) {
    throw new Error(`${label} must be lowercase hexadecimal.`);
  }
  return rawValue;
}

function requireCanonicalUuid(rawValue: string, label: string): string {
  if (!UUID_PATTERN.test(rawValue)) {
    throw new Error(`${label} must be a canonical lowercase UUID.`);
  }
  return rawValue;
}

function normalizeNullableHash(rawValue: string | null, label: string): string | null {
  return rawValue === null ? null : requireLowercaseHex(rawValue, label, 64);
}

function requireKind(rawValue: string): VpnRpcKind {
  switch (rawValue) {
    case 'REQUEST':
      return 'REQUEST';
    case 'RESPONSE':
      return 'RESPONSE';
    case 'EVENT':
      return 'EVENT';
    default:
      throw new Error('VpnRpc kind must stay inside the closed RPC contract.');
  }
}

function requireMethod(rawValue: string): VpnRpcMethod {
  switch (rawValue) {
    case 'PING':
      return 'PING';
    case 'GET_SNAPSHOT':
      return 'GET_SNAPSHOT';
    case 'GET_CATALOG_DIGEST':
      return 'GET_CATALOG_DIGEST';
    case 'GET_MODE':
      return 'GET_MODE';
    case 'SET_MODE':
      return 'SET_MODE';
    case 'QUERY_GROUPS':
      return 'QUERY_GROUPS';
    case 'QUERY_GROUP':
      return 'QUERY_GROUP';
    case 'SELECT_NODE':
      return 'SELECT_NODE';
    case 'START_DELAY_TEST':
      return 'START_DELAY_TEST';
    case 'READ_DELAY_TEST':
      return 'READ_DELAY_TEST';
    case 'CANCEL_DELAY_TEST':
      return 'CANCEL_DELAY_TEST';
    case 'STOP_VPN':
      return 'STOP_VPN';
    case 'RUNTIME_CHANGED':
      return 'RUNTIME_CHANGED';
    case 'DELAY_CHANGED':
      return 'DELAY_CHANGED';
    case 'SERVER_STOPPING':
      return 'SERVER_STOPPING';
    default:
      throw new Error('VpnRpc method must stay inside the closed RPC contract.');
  }
}

function requireTransportErrorCode(rawValue: string): VpnRpcTransportErrorCode {
  switch (rawValue) {
    case 'RPC_UNAVAILABLE':
      return 'RPC_UNAVAILABLE';
    case 'RPC_DISCONNECTED':
      return 'RPC_DISCONNECTED';
    case 'AUTH_FAILED':
      return 'AUTH_FAILED';
    case 'PROTOCOL_MISMATCH':
      return 'PROTOCOL_MISMATCH';
    case 'FRAME_INVALID':
      return 'FRAME_INVALID';
    case 'SESSION_CHANGED':
      return 'SESSION_CHANGED';
    case 'CATALOG_MISMATCH':
      return 'CATALOG_MISMATCH';
    case 'COMMAND_BUSY':
      return 'COMMAND_BUSY';
    case 'COMMAND_TIMEOUT':
      return 'COMMAND_TIMEOUT';
    case 'CORE_OPERATION_FAILED':
      return 'CORE_OPERATION_FAILED';
    case 'REQUEST_REPLAY_EXPIRED':
      return 'REQUEST_REPLAY_EXPIRED';
    case 'SERVER_STOPPING':
      return 'SERVER_STOPPING';
    default:
      throw new Error('VpnRpcError code must stay inside the closed transport error contract.');
  }
}

function cloneValidatedGuards(guards: VpnRpcGuards): VpnRpcGuards {
  if (!(guards instanceof VpnRpcGuardsValue)) {
    throw new Error('VpnRpcGuards values must come from createVpnRpcGuards.');
  }
  return createVpnRpcGuards(guards.profileHash, guards.revisionHash, guards.catalogDigest);
}

function hasAllNullGuards(guards: VpnRpcGuards): boolean {
  return guards.profileHash === null && guards.revisionHash === null && guards.catalogDigest === null;
}

function hasFullyActiveGuards(guards: VpnRpcGuards): boolean {
  return guards.profileHash !== null && guards.revisionHash !== null && guards.catalogDigest !== null;
}

function validateEnvelopeGuards(method: VpnRpcMethod, sessionGeneration: number, guards: VpnRpcGuards): VpnRpcGuards {
  const normalized: VpnRpcGuards = cloneValidatedGuards(guards);
  if (method === 'PING' || method === 'GET_SNAPSHOT') {
    if (!hasAllNullGuards(normalized)) {
      throw new Error(`${method} requires null guards.`);
    }
    return normalized;
  }
  if (method === 'GET_CATALOG_DIGEST') {
    if (normalized.profileHash === null || normalized.revisionHash === null || normalized.catalogDigest !== null) {
      throw new Error('GET_CATALOG_DIGEST requires profile/revision guards and null catalogDigest.');
    }
    if (sessionGeneration <= 0) {
      throw new Error('GET_CATALOG_DIGEST requires a positive sessionGeneration.');
    }
    return normalized;
  }
  if (method === 'SERVER_STOPPING') {
    if (sessionGeneration === 0) {
      if (!hasAllNullGuards(normalized)) {
        throw new Error('SERVER_STOPPING with generation zero requires null guards.');
      }
      return normalized;
    }
    if (!hasFullyActiveGuards(normalized)) {
      throw new Error('SERVER_STOPPING with active generation requires active guards.');
    }
    return normalized;
  }
  if (!hasFullyActiveGuards(normalized)) {
    if (normalized.profileHash === null) {
      throw new Error(`${method} requires profileHash.`);
    }
    if (normalized.revisionHash === null) {
      throw new Error(`${method} requires revisionHash.`);
    }
    throw new Error(`${method} requires catalogDigest.`);
  }
  if (sessionGeneration <= 0) {
    throw new Error(`${method} requires a positive sessionGeneration.`);
  }
  return normalized;
}

function createBodyInternal(
  kindText: string,
  sequence: number,
  clientEpoch: number,
  requestOrdinal: number | null,
  requestId: string | null,
  methodText: string,
  sessionGeneration: number,
  guards: VpnRpcGuards,
  ok: boolean | null,
  error: VpnRpcError | null,
  payload: VpnRpcPayload
): VpnRpcBody {
  const body = new VpnRpcBodyValue();
  body.kind = requireKind(kindText);
  body.sequence = requireSafePositiveInteger(sequence, 'VpnRpcBody sequence');
  body.clientEpoch = requireSafePositiveInteger(clientEpoch, 'VpnRpcBody clientEpoch');
  body.requestOrdinal = requestOrdinal === null ? null : requireSafePositiveInteger(requestOrdinal, 'VpnRpcBody requestOrdinal');
  body.requestId = requestId === null ? null : requireCanonicalUuid(requestId, 'VpnRpcBody requestId');
  body.method = requireMethod(methodText);
  body.sessionGeneration = requireSafeNonNegativeInteger(sessionGeneration, 'VpnRpcBody sessionGeneration');
  body.guards = validateEnvelopeGuards(body.method, body.sessionGeneration, guards);
  body.ok = ok;
  body.error = error === null ? null : cloneVpnRpcError(error);
  body.payload = cloneVpnRpcPayloadForEnvelope(body.kind, body.method, ok, payload);

  if (body.kind === 'REQUEST') {
    if (body.requestOrdinal === null || body.requestId === null) {
      throw new Error('REQUEST bodies require requestOrdinal and requestId.');
    }
    if (body.ok !== null || body.error !== null) {
      throw new Error('REQUEST bodies require ok:null and error:null.');
    }
    return body;
  }
  if (body.kind === 'EVENT') {
    if (body.requestOrdinal !== null || body.requestId !== null) {
      throw new Error('EVENT bodies require requestOrdinal:null and requestId:null.');
    }
    if (body.ok !== null || body.error !== null) {
      throw new Error('EVENT bodies require ok:null and error:null.');
    }
    if (body.method !== 'RUNTIME_CHANGED' && body.method !== 'DELAY_CHANGED' && body.method !== 'SERVER_STOPPING') {
      throw new Error(`EVENT bodies do not support method ${body.method}.`);
    }
    return body;
  }
  if (body.requestOrdinal === null || body.requestId === null) {
    throw new Error('RESPONSE bodies require requestOrdinal and requestId.');
  }
  if (body.method !== 'PING' &&
    body.method !== 'GET_SNAPSHOT' &&
    body.method !== 'GET_CATALOG_DIGEST' &&
    body.method !== 'GET_MODE' &&
    body.method !== 'SET_MODE' &&
    body.method !== 'QUERY_GROUPS' &&
    body.method !== 'QUERY_GROUP' &&
    body.method !== 'SELECT_NODE' &&
    body.method !== 'START_DELAY_TEST' &&
    body.method !== 'READ_DELAY_TEST' &&
    body.method !== 'CANCEL_DELAY_TEST' &&
    body.method !== 'STOP_VPN') {
    throw new Error(`RESPONSE bodies do not support method ${body.method}.`);
  }
  if (body.ok === true) {
    if (body.error !== null) {
      throw new Error('Successful RESPONSE bodies require error:null.');
    }
    return body;
  }
  if (body.ok === false) {
    if (body.error === null) {
      throw new Error('Failed RESPONSE bodies require an error object.');
    }
    return body;
  }
  throw new Error('RESPONSE bodies require ok to be true or false.');
}

export function listVpnRpcKinds(): VpnRpcKind[] {
  return VPN_RPC_KINDS.slice();
}

export function listVpnRpcMethods(): VpnRpcMethod[] {
  return VPN_RPC_METHODS.slice();
}

export function listVpnRpcRequestMethods(): VpnRpcMethod[] {
  return VPN_RPC_REQUEST_METHODS.slice();
}

export function listVpnRpcResponseMethods(): VpnRpcMethod[] {
  return VPN_RPC_RESPONSE_METHODS.slice();
}

export function listVpnRpcEventMethods(): VpnRpcMethod[] {
  return VPN_RPC_EVENT_METHODS.slice();
}

export function listVpnRpcErrorCodes(): VpnRpcTransportErrorCode[] {
  return VPN_RPC_TRANSPORT_ERROR_CODES.slice();
}

export function createVpnRpcServerHelloBody(protocolVersion: 1, serverNonce: string, serverInstance: string): VpnRpcServerHelloBody {
  requireProtocolVersion(protocolVersion);
  const body = new VpnRpcServerHelloBodyValue();
  body.serverNonce = requireLowercaseHex(serverNonce, 'VpnRpcServerHelloBody serverNonce', 64);
  body.serverInstance = requireLowercaseHex(serverInstance, 'VpnRpcServerHelloBody serverInstance', 32);
  return body;
}

export function cloneVpnRpcServerHelloBody(body: VpnRpcServerHelloBody): VpnRpcServerHelloBody {
  if (!(body instanceof VpnRpcServerHelloBodyValue)) {
    throw new Error('VpnRpcServerHelloBody values must come from createVpnRpcServerHelloBody.');
  }
  return createVpnRpcServerHelloBody(1, body.serverNonce, body.serverInstance);
}

export function createVpnRpcClientAuthBody(protocolVersion: 1, clientNonce: string, clientProof: string): VpnRpcClientAuthBody {
  requireProtocolVersion(protocolVersion);
  const body = new VpnRpcClientAuthBodyValue();
  body.clientNonce = requireLowercaseHex(clientNonce, 'VpnRpcClientAuthBody clientNonce', 64);
  body.clientProof = requireLowercaseHex(clientProof, 'VpnRpcClientAuthBody clientProof', 64);
  return body;
}

export function cloneVpnRpcClientAuthBody(body: VpnRpcClientAuthBody): VpnRpcClientAuthBody {
  if (!(body instanceof VpnRpcClientAuthBodyValue)) {
    throw new Error('VpnRpcClientAuthBody values must come from createVpnRpcClientAuthBody.');
  }
  return createVpnRpcClientAuthBody(1, body.clientNonce, body.clientProof);
}

export function createVpnRpcServerAuthBody(protocolVersion: 1, clientEpoch: number, serverProof: string): VpnRpcServerAuthBody {
  requireProtocolVersion(protocolVersion);
  const body = new VpnRpcServerAuthBodyValue();
  body.clientEpoch = requireSafePositiveInteger(clientEpoch, 'VpnRpcServerAuthBody clientEpoch');
  body.serverProof = requireLowercaseHex(serverProof, 'VpnRpcServerAuthBody serverProof', 64);
  return body;
}

export function cloneVpnRpcServerAuthBody(body: VpnRpcServerAuthBody): VpnRpcServerAuthBody {
  if (!(body instanceof VpnRpcServerAuthBodyValue)) {
    throw new Error('VpnRpcServerAuthBody values must come from createVpnRpcServerAuthBody.');
  }
  return createVpnRpcServerAuthBody(1, body.clientEpoch, body.serverProof);
}

export function createVpnRpcError(code: string, retryable: boolean): VpnRpcError {
  const error = new VpnRpcErrorValue();
  error.code = requireTransportErrorCode(code);
  error.retryable = retryable;
  return error;
}

export function cloneVpnRpcError(error: VpnRpcError): VpnRpcError {
  if (!(error instanceof VpnRpcErrorValue)) {
    throw new Error('VpnRpcError values must come from createVpnRpcError.');
  }
  return createVpnRpcError(error.code, error.retryable);
}

export function createVpnRpcGuards(profileHash: string | null, revisionHash: string | null, catalogDigest: string | null): VpnRpcGuards {
  const guards = new VpnRpcGuardsValue();
  guards.profileHash = normalizeNullableHash(profileHash, 'VpnRpcGuards profileHash');
  guards.revisionHash = normalizeNullableHash(revisionHash, 'VpnRpcGuards revisionHash');
  guards.catalogDigest = normalizeNullableHash(catalogDigest, 'VpnRpcGuards catalogDigest');
  const nullCount: number =
    (guards.profileHash === null ? 1 : 0) +
    (guards.revisionHash === null ? 1 : 0) +
    (guards.catalogDigest === null ? 1 : 0);
  if (nullCount !== 0 && nullCount !== 3 && !(guards.profileHash !== null && guards.revisionHash !== null && guards.catalogDigest === null)) {
    throw new Error('VpnRpcGuards must be all-null, fully active, or GET_CATALOG_DIGEST compatible.');
  }
  return guards;
}

export function cloneVpnRpcGuards(guards: VpnRpcGuards): VpnRpcGuards {
  return cloneValidatedGuards(guards);
}

export function createVpnRpcBodyRequest(
  sequence: number,
  clientEpoch: number,
  requestOrdinal: number,
  requestId: string,
  method: string,
  sessionGeneration: number,
  guards: VpnRpcGuards,
  payload: VpnRpcPayload
): VpnRpcBody {
  return createBodyInternal('REQUEST', sequence, clientEpoch, requestOrdinal, requestId, method, sessionGeneration, guards, null, null, payload);
}

export function createVpnRpcBodySuccessResponse(
  sequence: number,
  clientEpoch: number,
  requestOrdinal: number,
  requestId: string,
  method: string,
  sessionGeneration: number,
  guards: VpnRpcGuards,
  payload: VpnRpcPayload
): VpnRpcBody {
  return createBodyInternal('RESPONSE', sequence, clientEpoch, requestOrdinal, requestId, method, sessionGeneration, guards, true, null, payload);
}

export function createVpnRpcBodyErrorResponse(
  sequence: number,
  clientEpoch: number,
  requestOrdinal: number,
  requestId: string,
  method: string,
  sessionGeneration: number,
  guards: VpnRpcGuards,
  error: VpnRpcError
): VpnRpcBody {
  return createBodyInternal(
    'RESPONSE',
    sequence,
    clientEpoch,
    requestOrdinal,
    requestId,
    method,
    sessionGeneration,
    guards,
    false,
    error,
    createVpnRpcEmptyPayload()
  );
}

export function createVpnRpcBodyEvent(
  sequence: number,
  clientEpoch: number,
  method: string,
  sessionGeneration: number,
  guards: VpnRpcGuards,
  payload: VpnRpcPayload
): VpnRpcBody {
  return createBodyInternal('EVENT', sequence, clientEpoch, null, null, method, sessionGeneration, guards, null, null, payload);
}

export function cloneVpnRpcBody(body: VpnRpcBody): VpnRpcBody {
  if (!(body instanceof VpnRpcBodyValue)) {
    throw new Error('VpnRpcBody values must come from constructors or decoder.');
  }
  return createBodyInternal(
    body.kind,
    body.sequence,
    body.clientEpoch,
    body.requestOrdinal,
    body.requestId,
    body.method,
    body.sessionGeneration,
    body.guards,
    body.ok,
    body.error,
    body.payload
  );
}
