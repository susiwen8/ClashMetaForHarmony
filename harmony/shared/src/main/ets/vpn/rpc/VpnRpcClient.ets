import {
  encodeVpnRpcBodyToText,
  decodeVpnRpcServerAuthBodyBytes,
  decodeVpnRpcServerHelloBodyBytes,
  encodeVpnRpcClientAuthBody
} from './VpnRpcBodyCodec';
import { encodeVpnRpcU32BE } from './VpnRpcBinaryCodec';
import {
  VpnRpcClientAuthenticator,
  VpnRpcTransportFailure,
  deriveVpnRpcSocketAddress,
  type VpnRpcAuthenticatedConnection,
  type VpnRpcProtectedBody
} from './VpnRpcAuthenticator';
import { VpnRpcFramer, type VpnRpcDecodedFrame } from './VpnRpcFramer';
import {
  cloneVpnRpcBody,
  cloneVpnRpcGuards,
  createVpnRpcBodyRequest,
  createVpnRpcGuards,
  type VpnRpcBody,
  type VpnRpcGuards,
  type VpnRpcMethod,
  type VpnRpcTransportErrorCode
} from './VpnRpcModels';
import {
  cloneVpnRpcPayloadForEnvelope,
  createVpnRpcDelayJobRequestPayload,
  createVpnRpcEmptyPayload,
  type VpnRpcPayload,
  type VpnRpcRuntimeSnapshotPayload
} from './VpnRpcPayloads';
import type { VpnRpcClientContext } from '../VpnPorts';
import {
  VpnRpcSocketFailure,
  type VpnRpcCancelableTaskPort,
  type VpnRpcClockPort,
  type VpnRpcCryptoPort,
  type VpnRpcRandomPort,
  type VpnRpcSchedulerPort,
  type VpnRpcSocketClientFactoryPort,
  type VpnRpcSocketConnectionPort
} from './VpnRpcPorts';
import {
  createVpnFailure,
  createVpnRuntimeSnapshot,
  type VpnFailureCode,
  type VpnRuntimeSnapshot,
  type VpnRuntimeState
} from '../VpnModels';

const CONNECT_WINDOW_MS: number = 15000;
const HANDSHAKE_TIMEOUT_MS: number = 3000;
const RETRY_DELAY_MS: number = 250;
const PENDING_LIMIT: number = 64;
const SOCKET_CONNECT_TIMEOUT_MS: number = 3000;
const UUID_BYTE_LENGTH: number = 16;
const INBOUND_QUEUE_BYTES_LIMIT: number = 524360;
const INBOUND_QUEUE_CHUNKS_LIMIT: number = 64;

const MESSAGE_RPC_UNAVAILABLE: string = 'VPN RPC unavailable.';
const MESSAGE_RPC_DISCONNECTED: string = 'VPN RPC disconnected.';
const MESSAGE_CLIENT_CLOSED: string = 'VPN RPC client closed.';
const MESSAGE_FRAME_INVALID: string = 'VPN RPC authenticated frame invalid.';
const MESSAGE_COMMAND_BUSY: string = 'VPN RPC command busy.';
const MESSAGE_COMMAND_TIMEOUT: string = 'VPN RPC command timed out.';
const MESSAGE_AUTH_TIMEOUT: string = 'VPN RPC authentication timed out.';
const MESSAGE_RUNTIME_FAILURE_DETAIL: string = 'VPN RPC runtime reported failure.';
const DELAY_PAYLOAD_PATTERN: RegExp =
  /^\{"jobId":"([0-9a-f]{64})","delayRevision":([0-9]+),"proxyGeneration":[0-9]+,"groupId":"[0-9a-f]{64}","state":"([A-Z]+)"/u;

export type VpnRpcClientState =
  | 'DISCONNECTED'
  | 'CONNECTING'
  | 'AUTHENTICATING'
  | 'READY'
  | 'RECONNECTING'
  | 'CLOSED';

type VpnRpcConnectPolicy = 'ONCE' | 'BOUNDED_RETRY';

export type VpnRpcEventListener = (event: VpnRpcBody) => void;

export interface VpnRpcTrafficCounters {
  txBytes: number;
  rxBytes: number;
}

export interface VpnRpcClientPort {
  connect(): Promise<void>;
  connectOnce(): Promise<void>;
  request(method: VpnRpcMethod, guards: VpnRpcGuards, generation: number, payload: VpnRpcPayload): Promise<VpnRpcBody>;
  refreshTrafficCounters(): Promise<VpnRpcTrafficCounters>;
  state(): VpnRpcClientState;
  snapshot(): VpnRuntimeSnapshot;
  activeContext(): VpnRpcClientContext | null;
  subscribe(listener: VpnRpcEventListener): number;
  unsubscribe(id: number): void;
  close(): Promise<void>;
}

class VpnRpcDeferred<T> {
  readonly promise: Promise<T>;
  private resolveValue: ((value: T) => void) | null = null;
  private rejectValue: ((reason: Error) => void) | null = null;

  constructor() {
    this.promise = new Promise<T>((resolve: (value: T) => void, reject: (reason: Error) => void): void => {
      this.resolveValue = resolve;
      this.rejectValue = reject;
    });
  }

  resolve(value: T): void {
    if (this.resolveValue !== null) {
      this.resolveValue(value);
    }
  }

  reject(error: Error): void {
    if (this.rejectValue !== null) {
      this.rejectValue(error);
    }
  }
}

class VpnRpcTransportDeferred<T> {
  readonly promise: Promise<T>;
  private resolveValue: ((value: T) => void) | null = null;
  private rejectValue: ((reason: VpnRpcTransportFailure) => void) | null = null;

  constructor() {
    this.promise = new Promise<T>((resolve: (value: T) => void, reject: (reason: VpnRpcTransportFailure) => void): void => {
      this.resolveValue = resolve;
      this.rejectValue = reject;
    });
  }

  resolve(value: T): void {
    if (this.resolveValue !== null) {
      this.resolveValue(value);
    }
  }

  reject(error: VpnRpcTransportFailure): void {
    if (this.rejectValue !== null) {
      this.rejectValue(error);
    }
  }
}

class VpnRpcSerialGate {
  private tail: Promise<void> = Promise.resolve();

  async runExclusive<T>(runner: () => Promise<T>): Promise<T> {
    const waitFor: Promise<void> = this.tail;
    const release: VpnRpcDeferred<void> = new VpnRpcDeferred<void>();
    this.tail = release.promise;
    await waitFor;
    try {
      return await runner();
    } finally {
      release.resolve();
    }
  }
}

type InboundQueueReserveResult = 'ACCEPTED' | 'CLOSED' | 'OVERFLOW';

class InboundQueueBudget {
  private queuedBytes: number = 0;
  private queuedChunks: number = 0;
  private closed: boolean = false;
  private overflowed: boolean = false;

  tryReserve(chunkLength: number): InboundQueueReserveResult {
    if (!Number.isSafeInteger(chunkLength) || chunkLength < 0) {
      if (this.closed || this.overflowed) {
        return 'CLOSED';
      }
      this.closed = true;
      this.overflowed = true;
      return 'OVERFLOW';
    }
    if (this.closed || this.overflowed) {
      return 'CLOSED';
    }
    if (this.queuedBytes > INBOUND_QUEUE_BYTES_LIMIT ||
      this.queuedChunks > INBOUND_QUEUE_CHUNKS_LIMIT ||
      this.queuedBytes > Number.MAX_SAFE_INTEGER - chunkLength ||
      this.queuedChunks >= INBOUND_QUEUE_CHUNKS_LIMIT ||
      this.queuedBytes + chunkLength > INBOUND_QUEUE_BYTES_LIMIT) {
      this.closed = true;
      this.overflowed = true;
      return 'OVERFLOW';
    }
    this.queuedBytes += chunkLength;
    this.queuedChunks += 1;
    return 'ACCEPTED';
  }

  release(chunkLength: number): void {
    if (!Number.isSafeInteger(chunkLength) || chunkLength < 0) {
      return;
    }
    if (this.queuedBytes >= chunkLength) {
      this.queuedBytes -= chunkLength;
    } else {
      this.queuedBytes = 0;
    }
    if (this.queuedChunks > 0) {
      this.queuedChunks -= 1;
    }
  }

  close(): void {
    this.closed = true;
  }
}

class ManagedTimer {
  private cancelable: VpnRpcCancelableTaskPort | null = null;
  private readonly deferred: VpnRpcDeferred<void>;
  private readonly onSettled: (() => void) | null;
  private completed: boolean = false;

  constructor(deferred: VpnRpcDeferred<void>, onSettled: (() => void) | null = null) {
    this.deferred = deferred;
    this.onSettled = onSettled;
  }

  bindCancelable(cancelable: VpnRpcCancelableTaskPort): void {
    this.cancelable = cancelable;
  }

  get promise(): Promise<void> {
    return this.deferred.promise;
  }

  complete(): void {
    if (this.completed) {
      return;
    }
    this.completed = true;
    this.onSettled?.();
    this.deferred.resolve();
  }

  cancel(): void {
    if (this.completed) {
      return;
    }
    this.completed = true;
    this.onSettled?.();
    this.cancelable?.cancel();
    this.deferred.reject(new Error('vpn-rpc-timer-cancelled'));
  }
}

class ActiveContextValue {
  readonly sessionGeneration: number;
  readonly guards: VpnRpcGuards;

  constructor(sessionGeneration: number, guards: VpnRpcGuards) {
    this.sessionGeneration = sessionGeneration;
    this.guards = cloneVpnRpcGuards(guards);
  }
}

class VpnRpcClientContextValue implements VpnRpcClientContext {
  sessionGeneration: number;
  guards: VpnRpcGuards;

  constructor(sessionGeneration: number, guards: VpnRpcGuards) {
    this.sessionGeneration = sessionGeneration;
    this.guards = cloneVpnRpcGuards(guards);
  }
}

class RememberedDelayValue {
  readonly jobId: string;
  readonly generation: number;
  readonly guards: VpnRpcGuards;
  readonly delayRevision: number;
  readonly terminal: boolean;

  constructor(jobId: string, generation: number, guards: VpnRpcGuards, delayRevision: number, terminal: boolean) {
    this.jobId = jobId;
    this.generation = generation;
    this.guards = cloneVpnRpcGuards(guards);
    this.delayRevision = delayRevision;
    this.terminal = terminal;
  }
}

class PendingRequestValue {
  readonly key: string;
  readonly ordinal: number;
  readonly requestId: string;
  readonly method: VpnRpcMethod;
  readonly generation: number;
  readonly guards: VpnRpcGuards;
  readonly payload: VpnRpcPayload;
  readonly connectionToken: number;
  readonly socketAttemptToken: number;
  readonly socketIdentity: VpnRpcSocketConnectionPort;
  readonly connectionIdentity: VpnRpcAuthenticatedConnection;
  readonly bootstrap: boolean;
  readonly deferred: VpnRpcTransportDeferred<VpnRpcBody>;
  retried: boolean = false;
  settled: boolean = false;
  retryTimer: ManagedTimer | null = null;
  timeoutTimer: ManagedTimer | null = null;

  constructor(
    ordinal: number,
    requestId: string,
    method: VpnRpcMethod,
    generation: number,
    guards: VpnRpcGuards,
    payload: VpnRpcPayload,
    connectionToken: number,
    socketAttemptToken: number,
    socketIdentity: VpnRpcSocketConnectionPort,
    connectionIdentity: VpnRpcAuthenticatedConnection,
    bootstrap: boolean
  ) {
    this.ordinal = ordinal;
    this.requestId = requestId;
    this.key = `${ordinal}:${requestId}`;
    this.method = method;
    this.generation = generation;
    this.guards = cloneVpnRpcGuards(guards);
    this.payload = cloneVpnRpcPayloadForEnvelope('REQUEST', method, null, payload);
    this.connectionToken = connectionToken;
    this.socketAttemptToken = socketAttemptToken;
    this.socketIdentity = socketIdentity;
    this.connectionIdentity = connectionIdentity;
    this.bootstrap = bootstrap;
    this.deferred = new VpnRpcTransportDeferred<VpnRpcBody>();
  }
}

class ConnectAttemptValue {
  readonly token: number;
  readonly deferred: VpnRpcTransportDeferred<void> = new VpnRpcTransportDeferred<void>();
  handshakeTimer: ManagedTimer | null = null;
  bootstrapKey: string | null = null;
  stage: 'WAIT_SERVER_HELLO' | 'WAIT_SERVER_AUTH' | 'WAIT_BOOTSTRAP' = 'WAIT_SERVER_HELLO';
  settled: boolean = false;

  constructor(token: number) {
    this.token = token;
  }

  resolve(): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.handshakeTimer?.cancel();
    this.handshakeTimer = null;
    this.deferred.resolve();
  }

  reject(error: VpnRpcTransportFailure): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.handshakeTimer?.cancel();
    this.handshakeTimer = null;
    this.deferred.reject(error);
  }
}

class SocketBindingValue {
  readonly dataId: number;
  readonly closeId: number;
  readonly errorId: number;
  readonly inboundGate: VpnRpcSerialGate;
  readonly inboundBudget: InboundQueueBudget;

  constructor(dataId: number, closeId: number, errorId: number, inboundGate: VpnRpcSerialGate, inboundBudget: InboundQueueBudget) {
    this.dataId = dataId;
    this.closeId = closeId;
    this.errorId = errorId;
    this.inboundGate = inboundGate;
    this.inboundBudget = inboundBudget;
  }
}

class DelayPayloadSummary {
  readonly jobId: string;
  readonly delayRevision: number;
  readonly state: string;

  constructor(jobId: string, delayRevision: number, state: string) {
    this.jobId = jobId;
    this.delayRevision = delayRevision;
    this.state = state;
  }
}

class VpnRpcTrafficCountersValue implements VpnRpcTrafficCounters {
  txBytes: number = 0;
  rxBytes: number = 0;
}

function cloneSnapshot(snapshot: VpnRuntimeSnapshot): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state: snapshot.state,
    activeRequest: snapshot.activeRequest,
    activeHandle: snapshot.activeHandle,
    captureConfig: snapshot.captureConfig,
    tunSnapshot: snapshot.tunSnapshot,
    notificationActive: snapshot.notificationActive,
    recoveryAttempt: snapshot.recoveryAttempt,
    scheduledRetryDelayMs: snapshot.scheduledRetryDelayMs,
    lastFailure: snapshot.lastFailure
  });
}

function createBaseSnapshot(state: 'STOPPED' | 'RECOVERING' = 'STOPPED'): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state,
    activeRequest: null,
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: false,
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure: null
  });
}

function internalClientError(): Error {
  return new Error('vpn-rpc-client-error');
}

function parseNullablePayloadString(token: string): string | null {
  if (token === 'null') {
    return null;
  }
  return token.slice(1, token.length - 1);
}

function parseBooleanToken(token: string): boolean {
  if (token === 'true') {
    return true;
  }
  if (token === 'false') {
    return false;
  }
  throw internalClientError();
}

function parseSafeNonNegativeIntegerToken(token: string): number {
  const value: number = Number.parseInt(token, 10);
  if (!Number.isSafeInteger(value) || value < 0 || `${value}` !== token) {
    throw internalClientError();
  }
  return value;
}

function parsePositiveIntegerOrNullToken(token: string): number | null {
  if (token === 'null') {
    return null;
  }
  const value: number = parseSafeNonNegativeIntegerToken(token);
  if (value <= 0) {
    throw internalClientError();
  }
  return value;
}

function createTrafficCounters(txBytes: number, rxBytes: number): VpnRpcTrafficCounters {
  if (!Number.isSafeInteger(txBytes) || txBytes < 0 || !Number.isSafeInteger(rxBytes) || rxBytes < 0) {
    throw internalClientError();
  }
  const counters = new VpnRpcTrafficCountersValue();
  counters.txBytes = txBytes;
  counters.rxBytes = rxBytes;
  return counters;
}

function cloneTrafficCounters(counters: VpnRpcTrafficCounters): VpnRpcTrafficCounters {
  return createTrafficCounters(counters.txBytes, counters.rxBytes);
}

function zeroTrafficCounters(): VpnRpcTrafficCounters {
  return createTrafficCounters(0, 0);
}

function requireRuntimeStateToken(token: string): VpnRuntimeState {
  switch (token) {
    case 'STOPPED':
    case 'AWAITING_CONSENT':
    case 'STARTING':
    case 'RUNNING':
    case 'RECOVERING':
    case 'STOPPING':
    case 'ERROR':
      return token;
    default:
      throw internalClientError();
  }
}

function requireRuntimeFailureCodeToken(token: string | null): VpnFailureCode | null {
  switch (token) {
    case null:
      return null;
    case 'VPN_PERMISSION_DENIED':
    case 'VPN_ALREADY_ACTIVE':
    case 'VPN_PROFILE_UNAVAILABLE':
    case 'VPN_CONFIG_INVALID':
    case 'VPN_CREATE_FAILED':
    case 'VPN_TUN_FD_INVALID':
    case 'VPN_TUN_START_FAILED':
    case 'VPN_SOCKET_PROTECT_FAILED':
    case 'VPN_LOCAL_PORT_CONFLICT':
    case 'VPN_BACKGROUND_TASK_FAILED':
    case 'VPN_PROXY_REPLAY_FAILED':
    case 'VPN_SYSTEM_REVOKED':
    case 'VPN_STOP_FAILED':
      return token;
    default:
      throw internalClientError();
  }
}

function parseRuntimeSnapshotFromBody(body: VpnRpcBody): VpnRuntimeSnapshot {
  const payload: VpnRpcRuntimeSnapshotPayload = body.payload as VpnRpcRuntimeSnapshotPayload;
  const failureCode: VpnFailureCode | null = requireRuntimeFailureCodeToken(payload.runtimeFailureCode);
  return createVpnRuntimeSnapshot({
    state: requireRuntimeStateToken(payload.state),
    activeRequest: null,
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: payload.notificationActive,
    recoveryAttempt: payload.recoveryAttempt,
    scheduledRetryDelayMs: payload.scheduledRetryDelayMs,
    lastFailure: failureCode === null
      ? null
      : createVpnFailure(failureCode, MESSAGE_RUNTIME_FAILURE_DETAIL)
  });
}

function parseRuntimeTrafficCounters(payload: VpnRpcRuntimeSnapshotPayload): VpnRpcTrafficCounters {
  return createTrafficCounters(payload.txBytes, payload.rxBytes);
}

function createActiveContextFromRuntimePayload(
  payload: VpnRpcRuntimeSnapshotPayload,
  sessionGeneration: number
): ActiveContextValue | null {
  if (payload.profileHash === null && payload.revisionHash === null && payload.catalogDigest === null) {
    return null;
  }
  if (payload.profileHash === null || payload.revisionHash === null || payload.catalogDigest === null) {
    throw createTransportFailure('FRAME_INVALID', false);
  }
  return new ActiveContextValue(
    sessionGeneration,
    createVpnRpcGuards(payload.profileHash, payload.revisionHash, payload.catalogDigest)
  );
}

function parseDelayPayloadSummary(payload: VpnRpcPayload): DelayPayloadSummary {
  const payloadText: string = encodeVpnRpcBodyToText(payload);
  const match: RegExpMatchArray | null = payloadText.match(DELAY_PAYLOAD_PATTERN);
  if (match === null) {
    throw createTransportFailure('FRAME_INVALID', false);
  }
  return new DelayPayloadSummary(match[1], parseSafeNonNegativeIntegerToken(match[2]), match[3]);
}

function createTransportFailure(code: VpnRpcTransportErrorCode, retryable: boolean): VpnRpcTransportFailure {
  switch (code) {
    case 'RPC_UNAVAILABLE':
      return new VpnRpcTransportFailure(MESSAGE_RPC_UNAVAILABLE, code, retryable);
    case 'RPC_DISCONNECTED':
      return new VpnRpcTransportFailure(MESSAGE_RPC_DISCONNECTED, code, retryable);
    case 'FRAME_INVALID':
      return new VpnRpcTransportFailure(MESSAGE_FRAME_INVALID, code, retryable);
    case 'COMMAND_BUSY':
      return new VpnRpcTransportFailure(MESSAGE_COMMAND_BUSY, code, retryable);
    case 'COMMAND_TIMEOUT':
      return new VpnRpcTransportFailure(MESSAGE_COMMAND_TIMEOUT, code, retryable);
    case 'AUTH_FAILED':
      return new VpnRpcTransportFailure(MESSAGE_AUTH_TIMEOUT, code, retryable);
    default:
      return new VpnRpcTransportFailure(MESSAGE_RPC_UNAVAILABLE, code, retryable);
  }
}

function createClosedFailure(): VpnRpcTransportFailure {
  return new VpnRpcTransportFailure(MESSAGE_CLIENT_CLOSED, 'RPC_DISCONNECTED', false);
}

function hasActiveGuards(guards: VpnRpcGuards): boolean {
  return guards.profileHash !== null && guards.revisionHash !== null && guards.catalogDigest !== null;
}

function guardsEqual(left: VpnRpcGuards, right: VpnRpcGuards): boolean {
  return left.profileHash === right.profileHash &&
    left.revisionHash === right.revisionHash &&
    left.catalogDigest === right.catalogDigest;
}

function isTerminalDelayState(state: string): boolean {
  return state === 'COMPLETED' || state === 'CANCELLED' || state === 'FAILED';
}

function frameBytes(bodyBytes: Uint8Array, macBytes: Uint8Array | null): Uint8Array {
  const headerBytes: Uint8Array = encodeVpnRpcU32BE(bodyBytes.length);
  const macLength: number = macBytes === null ? 0 : macBytes.length;
  const bytes: Uint8Array = new Uint8Array(headerBytes.length + bodyBytes.length + macLength);
  bytes.set(headerBytes, 0);
  bytes.set(bodyBytes, headerBytes.length);
  if (macBytes !== null) {
    bytes.set(macBytes, headerBytes.length + bodyBytes.length);
  }
  return bytes;
}

function copyBytes(bytes: Uint8Array): Uint8Array {
  return bytes.slice();
}

function methodTimeoutMs(method: VpnRpcMethod): number {
  switch (method) {
    case 'SELECT_NODE':
    case 'SET_MODE':
      return 8000;
    case 'STOP_VPN':
      return 15000;
    case 'START_DELAY_TEST':
    case 'READ_DELAY_TEST':
    case 'CANCEL_DELAY_TEST':
      return 8000;
    default:
      return 5000;
  }
}

function connectBackoffMs(attempt: number): number {
  if (attempt <= 1) {
    return 250;
  }
  if (attempt === 2) {
    return 500;
  }
  if (attempt === 3) {
    return 1000;
  }
  if (attempt === 4) {
    return 2000;
  }
  return 4000;
}

function lowercaseHex(bytes: Uint8Array): string {
  const alphabet: string = '0123456789abcdef';
  let value: string = '';
  for (let index: number = 0; index < bytes.length; index += 1) {
    value += alphabet[(bytes[index] >>> 4) & 0x0f];
    value += alphabet[bytes[index] & 0x0f];
  }
  return value;
}

function buildCanonicalUuid(bytes: Uint8Array): string {
  if (bytes.length !== UUID_BYTE_LENGTH) {
    throw new Error('VPN RPC request ids require exactly 16 random bytes.');
  }
  const copied: Uint8Array = copyBytes(bytes);
  copied[6] = (copied[6] & 0x0f) | 0x40;
  copied[8] = (copied[8] & 0x3f) | 0x80;
  const hex: string = lowercaseHex(copied);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function swallowError(_error: Error): void {}

function isRetryableTransportFailure(error: VpnRpcTransportFailure): boolean {
  return error.code === 'RPC_UNAVAILABLE' || error.code === 'RPC_DISCONNECTED';
}

function isRetryableConnectPreauthFailure(error: VpnRpcTransportFailure): boolean {
  return error.code === 'AUTH_FAILED' || error.code === 'PROTOCOL_MISMATCH' || error.code === 'FRAME_INVALID';
}

export class VpnRpcClient implements VpnRpcClientPort {
  private readonly crypto: VpnRpcCryptoPort;
  private readonly random: VpnRpcRandomPort;
  private readonly scheduler: VpnRpcSchedulerPort;
  private readonly clock: VpnRpcClockPort;
  private readonly sockets: VpnRpcSocketClientFactoryPort;
  private readonly framer: VpnRpcFramer = new VpnRpcFramer();
  private readonly listeners: Map<number, VpnRpcEventListener> = new Map<number, VpnRpcEventListener>();
  private readonly waitTimers: ManagedTimer[] = [];
  private readonly pending: Map<string, PendingRequestValue> = new Map<string, PendingRequestValue>();
  private snapshotValue: VpnRuntimeSnapshot = createBaseSnapshot();
  private trafficCountersValue: VpnRpcTrafficCounters = zeroTrafficCounters();
  private stateValue: VpnRpcClientState = 'DISCONNECTED';
  private listenerId: number = 1;
  private requestOrdinal: number = 1;
  private lifecycleToken: number = 0;
  private nextSocketAttemptToken: number = 0;
  private socketAttemptToken: number = 0;
  private activeContextValue: ActiveContextValue | null = null;
  private rememberedDelay: RememberedDelayValue | null = null;
  private socket: VpnRpcSocketConnectionPort | null = null;
  private binding: SocketBindingValue | null = null;
  private authenticator: VpnRpcClientAuthenticator | null = null;
  private connection: VpnRpcAuthenticatedConnection | null = null;
  private connectAttempt: ConnectAttemptValue | null = null;
  private connectPromise: Promise<void> | null = null;
  private connectPolicy: VpnRpcConnectPolicy | null = null;
  private connectRunId: number = 0;
  private closePromise: Promise<void> | null = null;
  private closing: boolean = false;

  constructor(
    crypto: VpnRpcCryptoPort,
    random: VpnRpcRandomPort,
    scheduler: VpnRpcSchedulerPort,
    clock: VpnRpcClockPort,
    sockets: VpnRpcSocketClientFactoryPort
  ) {
    this.crypto = crypto;
    this.random = random;
    this.scheduler = scheduler;
    this.clock = clock;
    this.sockets = sockets;
  }

  state(): VpnRpcClientState {
    return this.stateValue;
  }

  snapshot(): VpnRuntimeSnapshot {
    return cloneSnapshot(this.snapshotValue);
  }

  activeContext(): VpnRpcClientContext | null {
    const context: ActiveContextValue | null = this.activeContextValue;
    if (context === null) {
      return null;
    }
    return new VpnRpcClientContextValue(context.sessionGeneration, context.guards);
  }

  async connect(): Promise<void> {
    while (true) {
      if (this.stateValue === 'CLOSED') {
        throw createClosedFailure();
      }
      if (this.stateValue === 'READY') {
        return;
      }
      const inFlight: Promise<void> | null = this.connectPromise;
      if (inFlight === null) {
        const reconnecting: boolean = this.stateValue === 'RECONNECTING';
        return await this.startConnect(reconnecting, 'BOUNDED_RETRY');
      }
      if (this.connectPolicy === 'BOUNDED_RETRY') {
        return await inFlight;
      }
      try {
        await inFlight;
      } catch (error) {
        if (this.closing) {
          throw error instanceof VpnRpcTransportFailure ? error : createClosedFailure();
        }
        if (this.connectPromise === inFlight) {
          this.connectPromise = null;
          this.connectPolicy = null;
        }
        continue;
      }
      return;
    }
  }

  async connectOnce(): Promise<void> {
    if (this.stateValue === 'CLOSED') {
      throw createClosedFailure();
    }
    if (this.stateValue === 'READY') {
      return;
    }
    if (this.connectPromise !== null) {
      return await this.connectPromise;
    }
    const reconnecting: boolean = this.stateValue === 'RECONNECTING';
    return await this.startConnect(reconnecting, 'ONCE');
  }

  async request(method: VpnRpcMethod, guards: VpnRpcGuards, generation: number, payload: VpnRpcPayload): Promise<VpnRpcBody> {
    if (this.stateValue === 'CLOSED') {
      throw createClosedFailure();
    }
    if (this.stateValue !== 'READY' || this.connection === null || this.socket === null) {
      throw createTransportFailure('RPC_DISCONNECTED', false);
    }
    return await this.issueRequest(method, guards, generation, payload, false);
  }

  async refreshTrafficCounters(): Promise<VpnRpcTrafficCounters> {
    if (this.stateValue === 'CLOSED') {
      throw createClosedFailure();
    }
    if (this.stateValue !== 'READY' || this.connection === null || this.socket === null) {
      throw createTransportFailure('RPC_DISCONNECTED', false);
    }
    const response: VpnRpcBody = await this.issueRequest(
      'GET_SNAPSHOT',
      createVpnRpcGuards(null, null, null),
      0,
      createVpnRpcEmptyPayload(),
      true
    );
    if (response.ok !== true) {
      throw response.error === null
        ? createTransportFailure('RPC_UNAVAILABLE', true)
        : createTransportFailure(response.error.code, response.error.retryable);
    }
    return cloneTrafficCounters(this.trafficCountersValue);
  }

  subscribe(listener: VpnRpcEventListener): number {
    const id: number = this.listenerId;
    this.listenerId += 1;
    this.listeners.set(id, listener);
    return id;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  async cancelActiveDelay(): Promise<void> {
    const rememberedDelay: RememberedDelayValue | null = this.rememberedDelay;
    if (this.stateValue !== 'READY' || rememberedDelay === null || rememberedDelay.terminal) {
      return;
    }
    const deadlineMs: number = this.clock.nowMs() + methodTimeoutMs('CANCEL_DELAY_TEST');
    let currentJob: RememberedDelayValue | null = rememberedDelay;
    while (currentJob !== null && !currentJob.terminal && this.clock.nowMs() <= deadlineMs && this.stateValue === 'READY') {
      let response: VpnRpcBody;
      try {
        response = await this.issueRequest(
          'CANCEL_DELAY_TEST',
          currentJob.guards,
          currentJob.generation,
          createVpnRpcDelayJobRequestPayload(currentJob.jobId),
          false
        );
      } catch {
        return;
      }
      if (response.ok !== true) {
        return;
      }
      currentJob = this.rememberedDelay;
      if (currentJob === null || currentJob.terminal) {
        return;
      }
      let waitTimer: ManagedTimer;
      try {
        waitTimer = this.scheduleTimer(RETRY_DELAY_MS, (): void => {});
      } catch {
        return;
      }
      try {
        await waitTimer.promise;
      } catch {
        return;
      }
    }
  }

  async close(): Promise<void> {
    if (this.closePromise !== null) {
      return await this.closePromise;
    }
    const promise: Promise<void> = this.closeInternal().finally((): void => {
      if (this.closePromise === promise) {
        this.closePromise = null;
      }
    });
    this.closePromise = promise;
    return await promise;
  }

  private async closeInternal(): Promise<void> {
    if (this.stateValue === 'CLOSED') {
      return;
    }
    this.closing = true;
    const activeDelay: RememberedDelayValue | null = this.rememberedDelay;
    if (this.stateValue === 'READY' && activeDelay !== null && !activeDelay.terminal) {
      await this.cancelActiveDelay();
    }
    this.lifecycleToken += 1;
    this.cancelWaitTimers();
    const disconnectFailure: VpnRpcTransportFailure = createTransportFailure('RPC_DISCONNECTED', false);
    this.rejectConnectAttempt(disconnectFailure);
    this.rejectAllPending(disconnectFailure);
    await this.disposeTransport(true);
    this.listeners.clear();
    this.activeContextValue = null;
    this.rememberedDelay = null;
    this.trafficCountersValue = zeroTrafficCounters();
    this.snapshotValue = createBaseSnapshot(this.snapshotValue.state === 'STOPPED' ? 'STOPPED' : 'RECOVERING');
    this.stateValue = 'CLOSED';
  }

  private async startConnect(reconnecting: boolean, policy: VpnRpcConnectPolicy): Promise<void> {
    if (this.connectPromise !== null) {
      return await this.connectPromise;
    }
    const connectRunId: number = this.connectRunId + 1;
    this.connectRunId = connectRunId;
    const promise: Promise<void> = (async (): Promise<void> => {
      try {
        await this.runConnectLoop(reconnecting, policy);
      } finally {
        if (this.connectRunId === connectRunId) {
          this.connectPromise = null;
          this.connectPolicy = null;
          this.connectRunId = 0;
        }
      }
    })();
    this.connectPolicy = policy;
    this.connectPromise = promise;
    return await promise;
  }

  private async runConnectLoop(reconnecting: boolean, policy: VpnRpcConnectPolicy): Promise<void> {
    const token: number = ++this.lifecycleToken;
    const deadlineMs: number = this.clock.nowMs() + CONNECT_WINDOW_MS;
    let attemptCount: number = 0;
    while (true) {
      if (this.stateValue === 'CLOSED' || this.closing) {
        throw createClosedFailure();
      }
      this.stateValue = reconnecting ? 'RECONNECTING' : 'CONNECTING';
      try {
        await this.establishConnection(token);
        return;
      } catch (error) {
        const failure: VpnRpcTransportFailure = this.normalizeError(
          error instanceof Error ? error : internalClientError(),
          'RPC_UNAVAILABLE'
        );
        if (token !== this.lifecycleToken) {
          throw failure;
        }
        const socketAttemptToken: number = this.socketAttemptToken;
        this.rejectPendingForSocketAttempt(socketAttemptToken, createTransportFailure('RPC_DISCONNECTED', false));
        await this.disposeTransport(true);
        const retryable: boolean = isRetryableTransportFailure(failure) || isRetryableConnectPreauthFailure(failure);
        if (policy === 'ONCE') {
          this.transitionToDisconnectedIfOpen();
          throw retryable
            ? createTransportFailure('RPC_UNAVAILABLE', true)
            : failure;
        }
        if (!retryable || this.clock.nowMs() >= deadlineMs) {
          this.transitionToDisconnectedIfOpen();
          throw retryable
            ? createTransportFailure('RPC_UNAVAILABLE', true)
            : failure;
        }
        attemptCount += 1;
        const remainingMs: number = deadlineMs - this.clock.nowMs();
        const delayMs: number = Math.min(connectBackoffMs(attemptCount), remainingMs);
        if (delayMs <= 0) {
          this.transitionToDisconnectedIfOpen();
          throw createTransportFailure('RPC_UNAVAILABLE', true);
        }
        try {
          await this.wait(delayMs);
        } catch (waitError) {
          const normalized: VpnRpcTransportFailure = this.normalizeConnectWaitError(
            waitError instanceof Error ? waitError : internalClientError()
          );
          this.transitionToDisconnectedIfOpen();
          throw normalized;
        }
      }
    }
  }

  private async establishConnection(token: number): Promise<void> {
    const socketAttemptToken: number = ++this.nextSocketAttemptToken;
    this.socketAttemptToken = socketAttemptToken;
    const address: string = await deriveVpnRpcSocketAddress(this.crypto);
    if (!this.matchesSocketAttemptToken(token, socketAttemptToken)) {
      throw createTransportFailure('RPC_DISCONNECTED', false);
    }
    let socket: VpnRpcSocketConnectionPort;
    try {
      socket = await this.sockets.connect(address, SOCKET_CONNECT_TIMEOUT_MS);
    } catch (error) {
      throw this.normalizeError(error instanceof Error ? error : internalClientError(), 'RPC_UNAVAILABLE');
    }
    if (!this.matchesSocketAttemptToken(token, socketAttemptToken)) {
      await socket.close();
      throw createTransportFailure('RPC_DISCONNECTED', false);
    }
    this.socket = socket;
    this.authenticator = new VpnRpcClientAuthenticator(this.crypto, this.random, this.scheduler);
    const attempt: ConnectAttemptValue = new ConnectAttemptValue(token);
    attempt.handshakeTimer = this.scheduleTimer(HANDSHAKE_TIMEOUT_MS, async (): Promise<void> => {
      await this.handleConnectFailure(socket, token, socketAttemptToken, createTransportFailure('AUTH_FAILED', false));
    });
    this.connectAttempt = attempt;
    this.bindSocket(socket, token, socketAttemptToken);
    this.stateValue = 'AUTHENTICATING';
    return await attempt.deferred.promise;
  }

  private bindSocket(socket: VpnRpcSocketConnectionPort, token: number, socketAttemptToken: number): void {
    const inboundGate: VpnRpcSerialGate = new VpnRpcSerialGate();
    const inboundBudget: InboundQueueBudget = new InboundQueueBudget();
    const dataId: number = socket.subscribeData((bytes: Uint8Array): void => {
      const reserveResult: InboundQueueReserveResult = inboundBudget.tryReserve(bytes.length);
      if (reserveResult === 'CLOSED') {
        return;
      }
      if (reserveResult === 'OVERFLOW') {
        const overflowFailure: Promise<void> = this.handleSocketSignal(
          socket,
          token,
          socketAttemptToken,
          createTransportFailure('FRAME_INVALID', false)
        );
        overflowFailure.catch(swallowError);
        return;
      }
      const copied: Uint8Array = copyBytes(bytes);
      const pending: Promise<void> = inboundGate.runExclusive(async (): Promise<void> => {
        try {
          await this.processIncomingBytes(copied, socket, token, socketAttemptToken);
        } finally {
          inboundBudget.release(copied.length);
        }
      });
      pending.catch(swallowError);
    });
    const closeId: number = socket.subscribeClose((): void => {
      const pending: Promise<void> = this.handleSocketSignal(socket, token, socketAttemptToken, createTransportFailure('RPC_DISCONNECTED', false));
      pending.catch(swallowError);
    });
    const errorId: number = socket.subscribeError((): void => {
      const pending: Promise<void> = this.handleSocketSignal(socket, token, socketAttemptToken, createTransportFailure('RPC_DISCONNECTED', false));
      pending.catch(swallowError);
    });
    this.binding = new SocketBindingValue(dataId, closeId, errorId, inboundGate, inboundBudget);
  }

  private async processIncomingBytes(
    bytes: Uint8Array,
    socket: VpnRpcSocketConnectionPort,
    token: number,
    socketAttemptToken: number
  ): Promise<void> {
    if (!this.matchesSocketAttempt(socket, token, socketAttemptToken)) {
      return;
    }
    try {
      const authenticated: boolean = this.connection !== null;
      const frames: VpnRpcDecodedFrame[] = this.framer.push(bytes, authenticated);
      for (let index: number = 0; index < frames.length; index += 1) {
        if (!this.matchesSocketAttempt(socket, token, socketAttemptToken)) {
          return;
        }
        if (authenticated) {
          await this.processAuthenticatedFrame(frames[index], socket, token, socketAttemptToken);
        } else {
          await this.processPreauthFrame(frames[index], socket, token, socketAttemptToken);
        }
      }
    } catch (error) {
      if (!this.matchesSocketAttempt(socket, token, socketAttemptToken)) {
        return;
      }
      await this.handleInboundFailure(
        token,
        this.normalizeError(error instanceof Error ? error : internalClientError(), 'FRAME_INVALID')
      );
    }
  }

  private async processPreauthFrame(
    frame: VpnRpcDecodedFrame,
    socket: VpnRpcSocketConnectionPort,
    token: number,
    socketAttemptToken: number
  ): Promise<void> {
    const attempt: ConnectAttemptValue | null = this.connectAttempt;
    const authenticator: VpnRpcClientAuthenticator | null = this.authenticator;
    if (attempt === null || authenticator === null || !this.matchesSocketAttempt(socket, token, socketAttemptToken)) {
      throw createTransportFailure('FRAME_INVALID', false);
    }
    if (attempt.stage === 'WAIT_SERVER_HELLO') {
      const serverHello = decodeVpnRpcServerHelloBodyBytes(frame.bodyBytes);
      const clientAuth = await authenticator.begin(serverHello);
      if (!this.matchesSocketAttempt(socket, token, socketAttemptToken)) {
        return;
      }
      await socket.send(frameBytes(encodeVpnRpcClientAuthBody(clientAuth), null));
      if (!this.matchesSocketAttempt(socket, token, socketAttemptToken)) {
        return;
      }
      attempt.stage = 'WAIT_SERVER_AUTH';
      return;
    }
    if (attempt.stage === 'WAIT_SERVER_AUTH') {
      const serverAuth = decodeVpnRpcServerAuthBodyBytes(frame.bodyBytes);
      const connection: VpnRpcAuthenticatedConnection = await authenticator.acceptServerAuth(serverAuth);
      if (!this.matchesSocketAttempt(socket, token, socketAttemptToken)) {
        connection.dispose();
        return;
      }
      this.connection = connection;
      this.requestOrdinal = 1;
      this.framer.reset();
      attempt.stage = 'WAIT_BOOTSTRAP';
      const bootstrapPromise: Promise<VpnRpcBody> = this.issueRequest(
        'GET_SNAPSHOT',
        createVpnRpcGuards(null, null, null),
        0,
        createVpnRpcEmptyPayload(),
        true
      );
      bootstrapPromise.then((bootstrapBody: VpnRpcBody): void => {
        const pending: Promise<void> = this.completeBootstrap(socket, token, socketAttemptToken, bootstrapBody);
        pending.catch(swallowError);
      }).catch((error: Error): void => {
        if (!this.matchesSocketAttempt(socket, token, socketAttemptToken)) {
          return;
        }
        const pending: Promise<void> = this.handleInboundFailure(
          token,
          this.normalizeError(error, 'RPC_UNAVAILABLE')
        );
        pending.catch(swallowError);
      });
      return;
    }
    throw createTransportFailure('FRAME_INVALID', false);
  }

  private async processAuthenticatedFrame(
    frame: VpnRpcDecodedFrame,
    socket: VpnRpcSocketConnectionPort,
    token: number,
    socketAttemptToken: number
  ): Promise<void> {
    const connection: VpnRpcAuthenticatedConnection | null = this.connection;
    if (connection === null || frame.macBytes === null) {
      throw createTransportFailure('FRAME_INVALID', false);
    }
    const body: VpnRpcBody = await connection.decodeIncomingFrame(frame.bodyBytes, frame.macBytes);
    if (!this.matchesSocketAttempt(socket, token, socketAttemptToken)) {
      return;
    }
    if (body.kind === 'EVENT') {
      this.processEventBody(body);
      return;
    }
    if (body.kind !== 'RESPONSE') {
      throw createTransportFailure('FRAME_INVALID', false);
    }
    const requestId: string | null = body.requestId;
    const requestOrdinal: number | null = body.requestOrdinal;
    if (requestId === null || requestOrdinal === null) {
      throw createTransportFailure('FRAME_INVALID', false);
    }
    const key: string = `${requestOrdinal}:${requestId}`;
    const pending: PendingRequestValue | undefined = this.pending.get(key);
    if (pending === undefined ||
      !this.matchesPendingResponseEnvelope(pending, body) ||
      pending.connectionToken !== token ||
      pending.socketAttemptToken !== socketAttemptToken ||
      pending.socketIdentity !== socket ||
      pending.connectionIdentity !== connection ||
      pending.settled) {
      throw createTransportFailure('FRAME_INVALID', false);
    }
    pending.settled = true;
    pending.retryTimer?.cancel();
    pending.timeoutTimer?.cancel();
    this.pending.delete(key);
    this.captureContextFromEnvelope(body);
    this.applyResponseSideEffects(body);
    pending.deferred.resolve(cloneVpnRpcBody(body));
  }

  private processEventBody(body: VpnRpcBody): void {
    if (body.method === 'RUNTIME_CHANGED') {
      this.applyRuntimeSnapshotBody(body);
      this.notifyListeners(body);
      return;
    }
    if (body.method === 'DELAY_CHANGED') {
      const payload: DelayPayloadSummary = parseDelayPayloadSummary(body.payload);
      if (!this.applyDelayPayload(payload.jobId, payload.delayRevision, payload.state, body.sessionGeneration, body.guards)) {
        return;
      }
      this.captureContextFromEnvelope(body);
      this.notifyListeners(body);
      return;
    }
    this.captureContextFromEnvelope(body);
    this.notifyListeners(body);
  }

  private applyResponseSideEffects(body: VpnRpcBody): void {
    if (body.method === 'GET_SNAPSHOT' && body.ok === true) {
      this.applyRuntimeSnapshotBody(body);
      return;
    }
    if (body.method === 'STOP_VPN' && body.ok === true) {
      this.applyRuntimeSnapshotBody(body);
      return;
    }
    if ((body.method === 'START_DELAY_TEST' || body.method === 'READ_DELAY_TEST' || body.method === 'CANCEL_DELAY_TEST') && body.ok === true) {
      const payload: DelayPayloadSummary = parseDelayPayloadSummary(body.payload);
      this.applyDelayPayload(payload.jobId, payload.delayRevision, payload.state, body.sessionGeneration, body.guards);
      return;
    }
    if (body.ok === false && body.error !== null &&
      (body.error.code === 'SESSION_CHANGED' || body.error.code === 'CATALOG_MISMATCH')) {
      this.activeContextValue = null;
      this.rememberedDelay = null;
    }
  }

  private applyDelayPayload(jobId: string, delayRevision: number, state: string, generation: number, guards: VpnRpcGuards): boolean {
    const rememberedDelay: RememberedDelayValue | null = this.rememberedDelay;
    const sameContext: boolean = rememberedDelay !== null &&
      rememberedDelay.jobId === jobId &&
      rememberedDelay.generation === generation &&
      guardsEqual(rememberedDelay.guards, guards);
    const terminal: boolean = isTerminalDelayState(state);
    if (sameContext && rememberedDelay !== null) {
      if (delayRevision <= rememberedDelay.delayRevision) {
        return false;
      }
      if (terminal) {
        this.rememberedDelay = null;
        return true;
      }
      this.rememberedDelay = new RememberedDelayValue(jobId, generation, guards, delayRevision, false);
      return true;
    }
    if (terminal) {
      if (rememberedDelay !== null) {
        return false;
      }
      return true;
    }
    this.rememberedDelay = new RememberedDelayValue(jobId, generation, guards, delayRevision, false);
    return true;
  }

  private notifyListeners(body: VpnRpcBody): void {
    const entries: Array<[number, VpnRpcEventListener]> = Array.from(this.listeners.entries());
    for (let index: number = 0; index < entries.length; index += 1) {
      try {
        entries[index][1](cloneVpnRpcBody(body));
      } catch {}
    }
  }

  private captureContextFromEnvelope(body: VpnRpcBody): void {
    if (body.sessionGeneration > 0 && hasActiveGuards(body.guards)) {
      this.activeContextValue = new ActiveContextValue(body.sessionGeneration, body.guards);
    }
  }

  private async handleInboundFailure(token: number, failure: VpnRpcTransportFailure): Promise<void> {
    if (token !== this.lifecycleToken) {
      return;
    }
    this.activeContextValue = null;
    this.trafficCountersValue = zeroTrafficCounters();
    const attempt: ConnectAttemptValue | null = this.connectAttempt;
    if (attempt !== null) {
      this.connectAttempt = null;
      this.rejectPendingForSocketAttempt(this.socketAttemptToken, createTransportFailure('RPC_DISCONNECTED', false));
      await this.disposeTransport(true);
      attempt.reject(failure);
      return;
    }
    this.rejectAllPending(failure.code === 'FRAME_INVALID' ? failure : createTransportFailure('RPC_DISCONNECTED', false));
    await this.disposeTransport(true);
    if (this.closing || this.stateValue === 'CLOSED') {
      return;
    }
    this.snapshotValue = createBaseSnapshot(this.snapshotValue.state === 'STOPPED' ? 'STOPPED' : 'RECOVERING');
    this.stateValue = 'RECONNECTING';
    const reconnectPromise: Promise<void> = this.connect();
    reconnectPromise.catch(swallowError);
  }

  private async handleSocketSignal(
    socket: VpnRpcSocketConnectionPort,
    token: number,
    socketAttemptToken: number,
    failure: VpnRpcTransportFailure
  ): Promise<void> {
    if (!this.matchesSocketAttempt(socket, token, socketAttemptToken)) {
      return;
    }
    await this.handleInboundFailure(token, failure);
  }

  private rejectConnectAttempt(error: VpnRpcTransportFailure): void {
    const attempt: ConnectAttemptValue | null = this.connectAttempt;
    if (attempt === null) {
      return;
    }
    attempt.reject(error);
    this.connectAttempt = null;
  }

  private rejectAllPending(error: VpnRpcTransportFailure): void {
    const values: PendingRequestValue[] = Array.from(this.pending.values());
    this.pending.clear();
    for (let index: number = 0; index < values.length; index += 1) {
      const pending: PendingRequestValue = values[index];
      if (pending.settled) {
        continue;
      }
      pending.settled = true;
      pending.retryTimer?.cancel();
      pending.timeoutTimer?.cancel();
      pending.deferred.reject(error);
    }
  }

  private rejectPendingForSocketAttempt(socketAttemptToken: number, error: VpnRpcTransportFailure): void {
    if (socketAttemptToken === 0) {
      return;
    }
    const values: PendingRequestValue[] = Array.from(this.pending.values());
    for (let index: number = 0; index < values.length; index += 1) {
      const pending: PendingRequestValue = values[index];
      if (pending.settled ||
        pending.connectionToken !== this.lifecycleToken ||
        pending.socketAttemptToken !== socketAttemptToken) {
        continue;
      }
      this.settlePending(pending, error);
    }
  }

  private async disposeTransport(closeSocket: boolean): Promise<void> {
    this.socketAttemptToken = 0;
    this.connectAttempt = null;
    this.authenticator?.dispose();
    this.authenticator = null;
    this.connection?.dispose();
    this.connection = null;
    this.binding?.inboundBudget.close();
    if (this.binding !== null && this.socket !== null) {
      this.socket.unsubscribeData(this.binding.dataId);
      this.socket.unsubscribeClose(this.binding.closeId);
      this.socket.unsubscribeError(this.binding.errorId);
    }
    this.binding = null;
    const socket: VpnRpcSocketConnectionPort | null = this.socket;
    this.socket = null;
    this.framer.reset();
    if (closeSocket && socket !== null) {
      try {
        await socket.close();
      } catch {}
    }
  }

  private async issueRequest(
    method: VpnRpcMethod,
    guards: VpnRpcGuards,
    generation: number,
    payload: VpnRpcPayload,
    bootstrap: boolean
  ): Promise<VpnRpcBody> {
    const connection: VpnRpcAuthenticatedConnection | null = this.connection;
    const socket: VpnRpcSocketConnectionPort | null = this.socket;
    if (connection === null || socket === null) {
      throw createTransportFailure('RPC_DISCONNECTED', false);
    }
    if (this.pending.size >= PENDING_LIMIT) {
      throw createTransportFailure('COMMAND_BUSY', true);
    }
    const requestId: string = buildCanonicalUuid(this.random.bytes(UUID_BYTE_LENGTH));
    const ordinal: number = this.requestOrdinal;
    this.requestOrdinal += 1;
    const pending: PendingRequestValue = new PendingRequestValue(
      ordinal,
      requestId,
      method,
      generation,
      guards,
      payload,
      this.lifecycleToken,
      this.socketAttemptToken,
      socket,
      connection,
      bootstrap
    );
    this.pending.set(pending.key, pending);
    try {
      pending.retryTimer = this.scheduleTimer(RETRY_DELAY_MS, async (): Promise<void> => {
        await this.retryPendingRequest(pending.key);
      });
      pending.timeoutTimer = this.scheduleTimer(methodTimeoutMs(method), async (): Promise<void> => {
        await this.timeoutPendingRequest(pending.key);
      });
    } catch (error) {
      this.pending.delete(pending.key);
      pending.retryTimer?.cancel();
      pending.timeoutTimer?.cancel();
      throw this.normalizeError(error instanceof Error ? error : internalClientError(), 'RPC_UNAVAILABLE');
    }
    try {
      await this.sendPendingRequest(pending);
    } catch (error) {
      this.pending.delete(pending.key);
      pending.settled = true;
      pending.retryTimer?.cancel();
      pending.timeoutTimer?.cancel();
      throw this.normalizeError(error instanceof Error ? error : internalClientError(), 'RPC_DISCONNECTED');
    }
    return await pending.deferred.promise;
  }

  private async sendPendingRequest(pending: PendingRequestValue): Promise<void> {
    const connection: VpnRpcAuthenticatedConnection = this.requirePendingTransport(pending);
    const socket: VpnRpcSocketConnectionPort = pending.socketIdentity;
    const protectedBody: VpnRpcProtectedBody = await connection.encodeOutgoingBody((sequence: number, clientEpoch: number): VpnRpcBody => {
      return createVpnRpcBodyRequest(
        sequence,
        clientEpoch,
        pending.ordinal,
        pending.requestId,
        pending.method,
        pending.generation,
        pending.guards,
        pending.payload
      );
    });
    this.requirePendingTransport(pending);
    await socket.send(frameBytes(protectedBody.bodyBytes, protectedBody.macBytes));
    this.requirePendingTransport(pending);
  }

  private async retryPendingRequest(key: string): Promise<void> {
    const pending: PendingRequestValue | undefined = this.pending.get(key);
    if (pending === undefined || pending.settled || pending.retried) {
      return;
    }
    if (!this.matchesPendingTransport(pending)) {
      this.settlePending(pending, createTransportFailure('RPC_DISCONNECTED', false));
      return;
    }
    pending.retried = true;
    try {
      await this.sendPendingRequest(pending);
    } catch (error) {
      if (!this.matchesPendingTransport(pending)) {
        this.settlePending(pending, createTransportFailure('RPC_DISCONNECTED', false));
        return;
      }
      const failure: VpnRpcTransportFailure = this.normalizeError(
        error instanceof Error ? error : internalClientError(),
        'RPC_DISCONNECTED'
      );
      this.settlePending(pending, failure, true);
      await this.handleInboundFailure(this.lifecycleToken, failure);
    }
  }

  private async timeoutPendingRequest(key: string): Promise<void> {
    const pending: PendingRequestValue | undefined = this.pending.get(key);
    if (pending === undefined || pending.settled) {
      return;
    }
    if (!this.matchesPendingTransport(pending)) {
      this.settlePending(pending, createTransportFailure('RPC_DISCONNECTED', false));
      return;
    }
    this.settlePending(pending, createTransportFailure('COMMAND_TIMEOUT', true));
  }

  private normalizeError(error: Error, fallbackCode: VpnRpcTransportErrorCode): VpnRpcTransportFailure {
    if (error instanceof VpnRpcTransportFailure) {
      return error;
    }
    if (error instanceof VpnRpcSocketFailure) {
      if (error.code === 'CONNECT_REFUSED' || error.code === 'PLATFORM_FAILED' || error.code === 'ADDRESS_IN_USE' || error.code === 'SEND_FAILED') {
        return createTransportFailure('RPC_UNAVAILABLE', true);
      }
      return createTransportFailure('RPC_DISCONNECTED', false);
    }
    if (fallbackCode === 'FRAME_INVALID') {
      return createTransportFailure('FRAME_INVALID', false);
    }
    if (fallbackCode === 'RPC_DISCONNECTED') {
      return createTransportFailure('RPC_DISCONNECTED', false);
    }
    return createTransportFailure(fallbackCode, fallbackCode === 'RPC_UNAVAILABLE' || fallbackCode === 'COMMAND_TIMEOUT' || fallbackCode === 'COMMAND_BUSY');
  }

  private scheduleTimer(delayMs: number, runner: () => Promise<void> | void): ManagedTimer {
    const deferred: VpnRpcDeferred<void> = new VpnRpcDeferred<void>();
    const timer: ManagedTimer = new ManagedTimer(deferred, (): void => {
      this.removeWaitTimer(timer);
    });
    this.waitTimers.push(timer);
    try {
      const cancelable: VpnRpcCancelableTaskPort = this.scheduler.schedule(delayMs, async (): Promise<void> => {
        try {
          await runner();
        } finally {
          timer.complete();
        }
      });
      timer.bindCancelable(cancelable);
    } catch (error) {
      this.removeWaitTimer(timer);
      throw error instanceof Error ? error : internalClientError();
    }
    return timer;
  }

  private async wait(delayMs: number): Promise<void> {
    const timer: ManagedTimer = this.scheduleTimer(delayMs, (): void => {});
    await timer.promise;
  }

  private cancelWaitTimers(): void {
    while (this.waitTimers.length > 0) {
      const timer: ManagedTimer | undefined = this.waitTimers.pop();
      timer?.cancel();
    }
  }

  private removeWaitTimer(timer: ManagedTimer): void {
    for (let index: number = 0; index < this.waitTimers.length; index += 1) {
      if (this.waitTimers[index] === timer) {
        this.waitTimers.splice(index, 1);
        return;
      }
    }
  }

  private async refreshRememberedDelayAfterReconnect(token: number): Promise<void> {
    const rememberedDelay: RememberedDelayValue | null = this.rememberedDelay;
    if (rememberedDelay === null || rememberedDelay.terminal || token !== this.lifecycleToken || this.stateValue !== 'READY') {
      return;
    }
    try {
      await this.issueRequest(
        'READ_DELAY_TEST',
        rememberedDelay.guards,
        rememberedDelay.generation,
        createVpnRpcDelayJobRequestPayload(rememberedDelay.jobId),
        false
      );
    } catch (error) {
      const failure: VpnRpcTransportFailure = this.normalizeError(
        error instanceof Error ? error : internalClientError(),
        'RPC_UNAVAILABLE'
      );
      if (failure.code === 'SESSION_CHANGED' || failure.code === 'CATALOG_MISMATCH') {
        this.rememberedDelay = null;
      }
    }
  }

  private async handleConnectFailure(
    socket: VpnRpcSocketConnectionPort,
    token: number,
    socketAttemptToken: number,
    failure: VpnRpcTransportFailure
  ): Promise<void> {
    if (!this.matchesSocketAttempt(socket, token, socketAttemptToken)) {
      return;
    }
    const attempt: ConnectAttemptValue | null = this.connectAttempt;
    this.connectAttempt = null;
    this.rejectPendingForSocketAttempt(socketAttemptToken, createTransportFailure('RPC_DISCONNECTED', false));
    await this.disposeTransport(true);
    attempt?.reject(failure);
  }

  private async completeBootstrap(
    socket: VpnRpcSocketConnectionPort,
    token: number,
    socketAttemptToken: number,
    bootstrapBody: VpnRpcBody
  ): Promise<void> {
    if (!this.matchesSocketAttempt(socket, token, socketAttemptToken)) {
      return;
    }
    if (bootstrapBody.ok !== true) {
      await this.handleInboundFailure(
        token,
        bootstrapBody.error === null
          ? createTransportFailure('RPC_UNAVAILABLE', true)
          : createTransportFailure(bootstrapBody.error.code, bootstrapBody.error.retryable)
      );
      return;
    }
    const attempt: ConnectAttemptValue | null = this.connectAttempt;
    if (attempt === null) {
      return;
    }
    this.applyRuntimeSnapshotBody(bootstrapBody);
    this.stateValue = 'READY';
    attempt.resolve();
    this.connectAttempt = null;
    const delayRefresh: Promise<void> = this.refreshRememberedDelayAfterReconnect(token);
    delayRefresh.catch(swallowError);
  }

  private normalizeConnectWaitError(error: Error): VpnRpcTransportFailure {
    if (error instanceof VpnRpcTransportFailure) {
      return error;
    }
    if (error.message === 'vpn-rpc-timer-cancelled') {
      return createTransportFailure('RPC_DISCONNECTED', false);
    }
    return createTransportFailure('RPC_UNAVAILABLE', true);
  }

  private transitionToDisconnectedIfOpen(): void {
    if (this.closing || this.stateValue === 'CLOSED') {
      return;
    }
    this.stateValue = 'DISCONNECTED';
  }

  private matchesSocketAttemptToken(token: number, socketAttemptToken: number): boolean {
    return token === this.lifecycleToken && socketAttemptToken === this.socketAttemptToken;
  }

  private matchesSocketAttempt(
    socket: VpnRpcSocketConnectionPort,
    token: number,
    socketAttemptToken: number
  ): boolean {
    return this.matchesSocketAttemptToken(token, socketAttemptToken) && this.socket === socket;
  }

  private matchesPendingTransport(pending: PendingRequestValue): boolean {
    return pending.connectionToken === this.lifecycleToken &&
      pending.socketAttemptToken === this.socketAttemptToken &&
      this.socket === pending.socketIdentity &&
      this.connection === pending.connectionIdentity;
  }

  private matchesPendingResponseEnvelope(pending: PendingRequestValue, body: VpnRpcBody): boolean {
    if (pending.method !== body.method || !guardsEqual(pending.guards, body.guards)) {
      return false;
    }
    if (pending.bootstrap && pending.method === 'GET_SNAPSHOT') {
      return body.sessionGeneration >= 0;
    }
    return pending.generation === body.sessionGeneration;
  }

  private applyRuntimeSnapshotBody(body: VpnRpcBody): void {
    const snapshot: VpnRuntimeSnapshot = parseRuntimeSnapshotFromBody(body);
    const payload: VpnRpcRuntimeSnapshotPayload = body.payload as VpnRpcRuntimeSnapshotPayload;
    this.trafficCountersValue = parseRuntimeTrafficCounters(payload);
    this.snapshotValue = snapshot;
    const nextContext: ActiveContextValue | null = createActiveContextFromRuntimePayload(payload, body.sessionGeneration);
    this.activeContextValue = nextContext;
    if (nextContext === null) {
      this.rememberedDelay = null;
    }
  }

  private requirePendingTransport(pending: PendingRequestValue): VpnRpcAuthenticatedConnection {
    if (!this.matchesPendingTransport(pending)) {
      throw createTransportFailure('RPC_DISCONNECTED', false);
    }
    const connection: VpnRpcAuthenticatedConnection | null = this.connection;
    if (connection === null) {
      throw createTransportFailure('RPC_DISCONNECTED', false);
    }
    return connection;
  }

  private settlePending(
    pending: PendingRequestValue,
    error: VpnRpcTransportFailure,
    preserveRetryTimer: boolean = false
  ): void {
    if (pending.settled) {
      return;
    }
    pending.settled = true;
    this.pending.delete(pending.key);
    if (!preserveRetryTimer) {
      pending.retryTimer?.cancel();
    }
    pending.timeoutTimer?.cancel();
    pending.deferred.reject(error);
  }
}
