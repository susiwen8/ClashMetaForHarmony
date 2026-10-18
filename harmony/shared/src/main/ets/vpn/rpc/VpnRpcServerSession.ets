import {
  VpnRpcServerAuthenticator,
  VpnRpcTransportFailure,
  type VpnRpcAuthenticatedConnection,
  type VpnRpcServerAuthenticationResult
} from './VpnRpcAuthenticator';
import {
  decodeVpnRpcClientAuthBodyBytes,
  encodeVpnRpcBody,
  encodeVpnRpcServerAuthBody,
  encodeVpnRpcServerHelloBody
} from './VpnRpcBodyCodec';
import { encodeVpnRpcU32BE } from './VpnRpcBinaryCodec';
import { VpnRpcFramer, type VpnRpcDecodedFrame } from './VpnRpcFramer';
import {
  cloneVpnRpcBody,
  cloneVpnRpcGuards,
  createVpnRpcBodyErrorResponse,
  createVpnRpcBodyEvent,
  createVpnRpcBodyRequest,
  createVpnRpcBodySuccessResponse,
  createVpnRpcError,
  createVpnRpcGuards,
  type VpnRpcBody,
  type VpnRpcError,
  type VpnRpcGuards,
  type VpnRpcMethod,
  type VpnRpcTransportErrorCode
} from './VpnRpcModels';
import {
  cloneVpnRpcPayloadForEnvelope,
  createVpnRpcEmptyPayload,
  type VpnRpcPayload
} from './VpnRpcPayloads';
import {
  VpnRpcSocketFailure,
  type VpnRpcCancelableTaskPort,
  type VpnRpcCryptoPort,
  type VpnRpcRandomPort,
  type VpnRpcSchedulerPort,
  type VpnRpcSocketConnectionPort,
  type VpnRpcSocketServerPort
} from './VpnRpcPorts';

const MESSAGE_RPC_UNAVAILABLE: string = 'VPN RPC unavailable.';
const MESSAGE_RPC_DISCONNECTED: string = 'VPN RPC disconnected.';
const MESSAGE_FRAME_INVALID: string = 'VPN RPC authenticated frame invalid.';
const MESSAGE_AUTH_FAILED: string = 'VPN RPC authentication failed.';
const MESSAGE_COMMAND_BUSY: string = 'VPN RPC command busy.';
const RESPONSE_CACHE_LIMIT: number = 256;
const PENDING_LIMIT: number = 64;
const INBOUND_QUEUE_BYTES_LIMIT: number = 524360;
const INBOUND_QUEUE_CHUNKS_LIMIT: number = 64;
const BUSINESS_EVENT_QUEUE_LIMIT: number = 64;
const BUSINESS_EVENT_QUEUE_BYTES_LIMIT: number = 524360;
const CANDIDATE_AUTH_TIMEOUT_MS: number = 3000;

type InboundQueueReserveResult = 'ACCEPTED' | 'CLOSED' | 'OVERFLOW';

class VpnRpcSerialGate {
  private tail: Promise<void> = Promise.resolve();

  async runExclusive<T>(runner: () => Promise<T>): Promise<T> {
    const waitFor: Promise<void> = this.tail;
    const release: DeferredValue<void> = new DeferredValue<void>();
    this.tail = release.promise;
    await waitFor;
    try {
      return await runner();
    } finally {
      release.resolve();
    }
  }
}

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

class OutboundEventQueueBudget {
  private queuedEvents: number = 0;
  private queuedBytes: number = 0;
  private closed: boolean = false;

  tryReserve(encodedBodyBytes: number): boolean {
    if (this.closed) {
      return false;
    }
    if (!Number.isSafeInteger(encodedBodyBytes) || encodedBodyBytes < 0) {
      return false;
    }
    if (this.queuedEvents >= BUSINESS_EVENT_QUEUE_LIMIT ||
      this.queuedBytes > BUSINESS_EVENT_QUEUE_BYTES_LIMIT ||
      this.queuedBytes > Number.MAX_SAFE_INTEGER - encodedBodyBytes ||
      this.queuedBytes + encodedBodyBytes > BUSINESS_EVENT_QUEUE_BYTES_LIMIT) {
      return false;
    }
    this.queuedEvents += 1;
    this.queuedBytes += encodedBodyBytes;
    return true;
  }

  release(encodedBodyBytes: number): void {
    if (this.queuedEvents > 0) {
      this.queuedEvents -= 1;
    }
    if (Number.isSafeInteger(encodedBodyBytes) && encodedBodyBytes >= 0 && this.queuedBytes >= encodedBodyBytes) {
      this.queuedBytes -= encodedBodyBytes;
    } else if (this.queuedBytes > 0) {
      this.queuedBytes = 0;
    }
  }

  close(): void {
    this.closed = true;
  }
}

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private resolveValue: ((value: T) => void) | null = null;

  constructor() {
    this.promise = new Promise<T>((resolve: (value: T) => void): void => {
      this.resolveValue = resolve;
    });
  }

  resolve(value: T): void {
    this.resolveValue?.(value);
  }
}

class CachedResponseValue {
  readonly ordinal: number;
  readonly requestFingerprint: Uint8Array;
  readonly frameBytes: Uint8Array;

  constructor(ordinal: number, requestFingerprint: Uint8Array, frameBytes: Uint8Array) {
    this.ordinal = ordinal;
    this.requestFingerprint = requestFingerprint.slice();
    this.frameBytes = frameBytes.slice();
  }
}

class InFlightRequestValue {
  readonly ordinal: number;
  readonly requestFingerprint: Uint8Array;

  constructor(ordinal: number, requestFingerprint: Uint8Array) {
    this.ordinal = ordinal;
    this.requestFingerprint = requestFingerprint.slice();
  }
}

class SessionContextValue {
  readonly token: number;
  readonly socket: VpnRpcSocketConnectionPort;
  readonly framer: VpnRpcFramer = new VpnRpcFramer();
  readonly authenticator: VpnRpcServerAuthenticator;
  readonly inboundGate: VpnRpcSerialGate = new VpnRpcSerialGate();
  readonly outboundGate: VpnRpcSerialGate = new VpnRpcSerialGate();
  readonly inboundBudget: InboundQueueBudget = new InboundQueueBudget();
  readonly eventBudget: OutboundEventQueueBudget = new OutboundEventQueueBudget();
  readonly responseCache: Map<number, CachedResponseValue> = new Map<number, CachedResponseValue>();
  readonly cacheOrder: number[] = [];
  readonly inFlight: Map<number, InFlightRequestValue> = new Map<number, InFlightRequestValue>();
  connection: VpnRpcAuthenticatedConnection | null = null;
  highestAcceptedOrdinal: number = 0;
  latestGeneration: number = 0;
  latestGuards: VpnRpcGuards = createVpnRpcGuards(null, null, null);
  hasLatestContext: boolean = false;
  authenticated: boolean = false;
  disposed: boolean = false;
  dataId: number = 0;
  closeId: number = 0;
  errorId: number = 0;
  candidateTimeoutTask: VpnRpcCancelableTaskPort | null = null;
  candidateTimeoutCanceled: boolean = false;

  constructor(
    token: number,
    socket: VpnRpcSocketConnectionPort,
    authenticator: VpnRpcServerAuthenticator
  ) {
    this.token = token;
    this.socket = socket;
    this.authenticator = authenticator;
  }
}

function copyBytes(bytes: Uint8Array): Uint8Array {
  return bytes.slice();
}

function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index: number = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) {
      return false;
    }
  }
  return true;
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

function createTransportFailure(code: VpnRpcTransportErrorCode, retryable: boolean): VpnRpcTransportFailure {
  switch (code) {
    case 'AUTH_FAILED':
      return new VpnRpcTransportFailure(MESSAGE_AUTH_FAILED, code, retryable);
    case 'FRAME_INVALID':
      return new VpnRpcTransportFailure(MESSAGE_FRAME_INVALID, code, retryable);
    case 'RPC_DISCONNECTED':
      return new VpnRpcTransportFailure(MESSAGE_RPC_DISCONNECTED, code, retryable);
    case 'COMMAND_BUSY':
      return new VpnRpcTransportFailure(MESSAGE_COMMAND_BUSY, code, retryable);
    default:
      return new VpnRpcTransportFailure(MESSAGE_RPC_UNAVAILABLE, code, retryable);
  }
}

function normalizeUnknownError(error: Error, fallbackCode: VpnRpcTransportErrorCode): VpnRpcTransportFailure {
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
  if (fallbackCode === 'AUTH_FAILED') {
    return createTransportFailure('AUTH_FAILED', false);
  }
  if (fallbackCode === 'RPC_DISCONNECTED') {
    return createTransportFailure('RPC_DISCONNECTED', false);
  }
  if (fallbackCode === 'COMMAND_BUSY') {
    return createTransportFailure('COMMAND_BUSY', true);
  }
  return createTransportFailure('RPC_UNAVAILABLE', true);
}

function createCoreOperationFailedResponse(request: VpnRpcBody): VpnRpcBody {
  return createVpnRpcBodyErrorResponse(
    1,
    1,
    requireRequestOrdinal(request),
    requireRequestId(request),
    request.method,
    request.sessionGeneration,
    request.guards,
    createVpnRpcError('CORE_OPERATION_FAILED', false)
  );
}

function createReplayExpiredResponse(request: VpnRpcBody): VpnRpcBody {
  return createVpnRpcBodyErrorResponse(
    1,
    1,
    requireRequestOrdinal(request),
    requireRequestId(request),
    request.method,
    request.sessionGeneration,
    request.guards,
    createVpnRpcError('REQUEST_REPLAY_EXPIRED', false)
  );
}

function createServerStoppingResponse(request: VpnRpcBody): VpnRpcBody {
  return createVpnRpcBodyErrorResponse(
    1,
    1,
    requireRequestOrdinal(request),
    requireRequestId(request),
    request.method,
    request.sessionGeneration,
    request.guards,
    createVpnRpcError('SERVER_STOPPING', true)
  );
}

function createCommandBusyResponse(request: VpnRpcBody): VpnRpcBody {
  return createVpnRpcBodyErrorResponse(
    1,
    1,
    requireRequestOrdinal(request),
    requireRequestId(request),
    request.method,
    request.sessionGeneration,
    request.guards,
    createVpnRpcError('COMMAND_BUSY', true)
  );
}

function requireRequestOrdinal(request: VpnRpcBody): number {
  if (request.requestOrdinal === null) {
    throw createTransportFailure('FRAME_INVALID', false);
  }
  return request.requestOrdinal;
}

function requireRequestId(request: VpnRpcBody): string {
  if (request.requestId === null) {
    throw createTransportFailure('FRAME_INVALID', false);
  }
  return request.requestId;
}

function validateRequestBody(body: VpnRpcBody): VpnRpcBody {
  if (body.kind !== 'REQUEST' || body.requestOrdinal === null || body.requestId === null || body.ok !== null || body.error !== null) {
    throw createTransportFailure('FRAME_INVALID', false);
  }
  return cloneVpnRpcBody(body);
}

function validateResponseBody(request: VpnRpcBody, response: VpnRpcBody): VpnRpcBody {
  if (response.kind !== 'RESPONSE') {
    throw createTransportFailure('FRAME_INVALID', false);
  }
  if (response.requestOrdinal !== request.requestOrdinal ||
    response.requestId !== request.requestId ||
    response.method !== request.method) {
    throw createTransportFailure('FRAME_INVALID', false);
  }
  if (response.ok === true) {
    if (response.error !== null) {
      throw createTransportFailure('FRAME_INVALID', false);
    }
    return cloneVpnRpcBody(response);
  }
  if (response.ok === false) {
    if (response.error === null) {
      throw createTransportFailure('FRAME_INVALID', false);
    }
    return cloneVpnRpcBody(response);
  }
  throw createTransportFailure('FRAME_INVALID', false);
}

function rebuildResponseBody(request: VpnRpcBody, response: VpnRpcBody, sequence: number, clientEpoch: number): VpnRpcBody {
  if (response.ok === true) {
    return createVpnRpcBodySuccessResponse(
      sequence,
      clientEpoch,
      requireRequestOrdinal(request),
      requireRequestId(request),
      request.method,
      response.sessionGeneration,
      response.guards,
      response.payload
    );
  }
  const error: VpnRpcError | null = response.error;
  if (error === null) {
    throw createTransportFailure('FRAME_INVALID', false);
  }
  return createVpnRpcBodyErrorResponse(
    sequence,
    clientEpoch,
    requireRequestOrdinal(request),
    requireRequestId(request),
    request.method,
    response.sessionGeneration,
    response.guards,
    error
  );
}

function fingerprintRequest(request: VpnRpcBody): Uint8Array {
  const canonicalBody: VpnRpcBody = createVpnRpcBodyRequest(
    1,
    request.clientEpoch,
    requireRequestOrdinal(request),
    requireRequestId(request),
    request.method,
    request.sessionGeneration,
    request.guards,
    request.payload
  );
  return encodeVpnRpcBody(canonicalBody);
}

function fingerprintsMatch(request: VpnRpcBody, fingerprint: Uint8Array): boolean {
  return equalBytes(fingerprintRequest(request), fingerprint);
}

function swallowError(_error: Error): void {}

export type VpnRpcServerSessionHandler = (request: VpnRpcBody) => Promise<VpnRpcBody>;

export interface VpnRpcServerSessionPort {
  listen(): Promise<void>;
  publishEvent(method: VpnRpcMethod, sessionGeneration: number, guards: VpnRpcGuards, payload: VpnRpcPayload): Promise<boolean>;
  close(): Promise<void>;
}

export class VpnRpcServerSession implements VpnRpcServerSessionPort {
  private readonly crypto: VpnRpcCryptoPort;
  private readonly random: VpnRpcRandomPort;
  private readonly scheduler: VpnRpcSchedulerPort;
  private readonly server: VpnRpcSocketServerPort;
  private readonly address: string;
  private readonly handler: VpnRpcServerSessionHandler;
  private activeContext: SessionContextValue | null = null;
  private candidateContext: SessionContextValue | null = null;
  private nextContextToken: number = 0;
  private nextClientEpoch: number = 0;
  private listening: boolean = false;
  private closed: boolean = false;
  private closePromise: Promise<void> | null = null;
  private serverClosed: boolean = false;

  constructor(
    crypto: VpnRpcCryptoPort,
    random: VpnRpcRandomPort,
    scheduler: VpnRpcSchedulerPort,
    server: VpnRpcSocketServerPort,
    address: string,
    handler: VpnRpcServerSessionHandler
  ) {
    this.crypto = crypto;
    this.random = random;
    this.scheduler = scheduler;
    this.server = server;
    this.address = address;
    this.handler = handler;
  }

  async listen(): Promise<void> {
    if (this.closed) {
      throw createTransportFailure('RPC_DISCONNECTED', false);
    }
    if (this.listening) {
      return;
    }
    this.listening = true;
    try {
      await this.server.listen(this.address, (connection: VpnRpcSocketConnectionPort): void => {
        const pending: Promise<void> = this.acceptConnection(connection);
        pending.catch(swallowError);
      });
    } catch (error) {
      this.listening = false;
      this.closed = true;
      await this.closeServerOnce();
      throw normalizeUnknownError(error instanceof Error ? error : new Error('vpn-rpc-server-listen'), 'RPC_UNAVAILABLE');
    }
  }

  async publishEvent(
    method: VpnRpcMethod,
    sessionGeneration: number,
    guards: VpnRpcGuards,
    payload: VpnRpcPayload
  ): Promise<boolean> {
    const context: SessionContextValue | null = this.activeContext;
    if (context === null || this.closed) {
      return false;
    }
    if (method !== 'RUNTIME_CHANGED' && method !== 'DELAY_CHANGED') {
      return false;
    }
    let clonedGuards: VpnRpcGuards;
    let clonedPayload: VpnRpcPayload;
    let previewBytesLength: number;
    try {
      clonedGuards = cloneVpnRpcGuards(guards);
      clonedPayload = cloneVpnRpcPayloadForEnvelope('EVENT', method, null, payload);
      previewBytesLength = encodeVpnRpcBody(
        createVpnRpcBodyEvent(
          Number.MAX_SAFE_INTEGER,
          Number.MAX_SAFE_INTEGER,
          method,
          sessionGeneration,
          clonedGuards,
          clonedPayload
        )
      ).length;
    } catch {
      return false;
    }
    if (!context.eventBudget.tryReserve(previewBytesLength)) {
      return false;
    }
    try {
      return await this.sendEventFrame(context, method, sessionGeneration, clonedGuards, clonedPayload);
    } finally {
      context.eventBudget.release(previewBytesLength);
    }
  }

  async close(): Promise<void> {
    if (this.closePromise !== null) {
      return await this.closePromise;
    }
    this.closed = true;
    const promise: Promise<void> = this.shutdown().finally((): void => {
      if (this.closePromise === promise) {
        this.closePromise = null;
      }
    });
    this.closePromise = promise;
    return await promise;
  }

  private async shutdown(): Promise<void> {
    const activeContext: SessionContextValue | null = this.activeContext;
    const candidateContext: SessionContextValue | null = this.candidateContext;
    if (activeContext !== null &&
      activeContext.authenticated &&
      activeContext.connection !== null &&
      !activeContext.disposed) {
      try {
        await this.sendEventFrame(
          activeContext,
          'SERVER_STOPPING',
          activeContext.hasLatestContext ? activeContext.latestGeneration : 0,
          activeContext.hasLatestContext ? activeContext.latestGuards : createVpnRpcGuards(null, null, null),
          createVpnRpcEmptyPayload()
        );
      } catch {}
    }
    if (candidateContext !== null) {
      await this.disposeContext(candidateContext, true);
    }
    if (activeContext !== null) {
      await this.disposeContext(activeContext, true);
    }
    await this.closeServerOnce();
  }

  private async acceptConnection(socket: VpnRpcSocketConnectionPort): Promise<void> {
    if (this.closed) {
      try {
        await socket.close();
      } catch {}
      return;
    }
    // Network-visible transports must not let later unauthenticated peers
    // repeatedly cancel an existing handshake. Local transports keep their
    // previous replacement policy unless they explicitly opt in.
    if (this.server.preservePendingCandidate === true && this.candidateContext !== null) {
      try {
        await socket.close();
      } catch {}
      return;
    }
    const previousCandidateContext: SessionContextValue | null = this.candidateContext;
    const context: SessionContextValue = new SessionContextValue(
      this.nextContextToken + 1,
      socket,
      new VpnRpcServerAuthenticator(this.crypto, this.random, this.scheduler)
    );
    this.nextContextToken = context.token;
    this.candidateContext = context;
    context.dataId = socket.subscribeData((bytes: Uint8Array): void => {
      const reserveResult: InboundQueueReserveResult = context.inboundBudget.tryReserve(bytes.length);
      if (reserveResult === 'CLOSED') {
        return;
      }
      if (reserveResult === 'OVERFLOW') {
        const pendingOverflow: Promise<void> = this.failCloseContext(context, createTransportFailure('FRAME_INVALID', false));
        pendingOverflow.catch(swallowError);
        return;
      }
      const copiedBytes: Uint8Array = copyBytes(bytes);
      const pending: Promise<void> = context.inboundGate.runExclusive(async (): Promise<void> => {
        try {
          await this.handleSocketData(context, copiedBytes);
        } finally {
          context.inboundBudget.release(copiedBytes.length);
        }
      });
      pending.catch(swallowError);
    });
    context.closeId = socket.subscribeClose((): void => {
      const pending: Promise<void> = this.handleSocketClosed(context);
      pending.catch(swallowError);
    });
    context.errorId = socket.subscribeError((): void => {
      const pending: Promise<void> = this.handleSocketClosed(context);
      pending.catch(swallowError);
    });
    if (previousCandidateContext !== null) {
      await this.disposeContext(previousCandidateContext, true);
    }
    try {
      this.startCandidateTimeout(context);
      const hello = await context.authenticator.begin();
      if (!this.isCandidateContext(context)) {
        return;
      }
      await socket.send(frameBytes(encodeVpnRpcServerHelloBody(hello), null));
    } catch (error) {
      if (!this.isCandidateContext(context)) {
        return;
      }
      await this.failCloseContext(context, normalizeUnknownError(error instanceof Error ? error : new Error('vpn-rpc-server-begin'), 'AUTH_FAILED'));
    }
  }

  private async handleSocketData(context: SessionContextValue, bytes: Uint8Array): Promise<void> {
    if (!this.isLiveContext(context) || context.disposed) {
      return;
    }
    try {
      if (!context.authenticated) {
        if (!this.isCandidateContext(context)) {
          return;
        }
        const preauthFrames: VpnRpcDecodedFrame[] = context.framer.push(bytes, false);
        for (let index: number = 0; index < preauthFrames.length; index += 1) {
          await this.handleClientAuthFrame(context, preauthFrames[index].bodyBytes);
        }
        return;
      }
      if (!this.isActiveContext(context)) {
        return;
      }
      const frames: VpnRpcDecodedFrame[] = context.framer.push(bytes, true);
      for (let index: number = 0; index < frames.length; index += 1) {
        if (!this.isActiveContext(context) || context.connection === null || context.disposed) {
          return;
        }
        const frame: VpnRpcDecodedFrame = frames[index];
        if (frame.macBytes === null) {
          throw createTransportFailure('FRAME_INVALID', false);
        }
        const decodedBody: VpnRpcBody = await context.connection.decodeIncomingFrame(frame.bodyBytes, frame.macBytes);
        await this.handleRequestBody(context, validateRequestBody(decodedBody));
      }
    } catch (error) {
      if (!this.isLiveContext(context)) {
        return;
      }
      await this.failCloseContext(context, normalizeUnknownError(error instanceof Error ? error : new Error('vpn-rpc-server-frame'), 'FRAME_INVALID'));
    }
  }

  private async handleClientAuthFrame(context: SessionContextValue, bodyBytes: Uint8Array): Promise<void> {
    if (!this.isCandidateContext(context) || context.disposed) {
      return;
    }
    const clientAuth = decodeVpnRpcClientAuthBodyBytes(bodyBytes);
    const clientEpoch: number = this.nextClientEpoch + 1;
    const authentication: VpnRpcServerAuthenticationResult = await context.authenticator.acceptClientAuth(clientAuth, clientEpoch);
    if (!this.isCandidateContext(context) || context.disposed) {
      authentication.connection.dispose();
      return;
    }
    try {
      await context.socket.send(frameBytes(encodeVpnRpcServerAuthBody(authentication.serverAuth), null));
    } catch (error) {
      authentication.connection.dispose();
      if (!this.isCandidateContext(context) || context.disposed) {
        return;
      }
      await this.failCloseContext(
        context,
        normalizeUnknownError(error instanceof Error ? error : new Error('vpn-rpc-server-auth-send'), 'RPC_DISCONNECTED')
      );
      return;
    }
    if (!this.isCandidateContext(context) || context.disposed) {
      authentication.connection.dispose();
      return;
    }
    this.cancelCandidateTimeoutOnce(context);
    const previousActiveContext: SessionContextValue | null = this.activeContext;
    this.nextClientEpoch = clientEpoch;
    context.connection = authentication.connection;
    context.authenticated = true;
    context.framer.reset();
    this.activeContext = context;
    this.candidateContext = null;
    if (previousActiveContext !== null && previousActiveContext !== context) {
      await this.disposeContext(previousActiveContext, true);
    }
  }

  private async handleRequestBody(context: SessionContextValue, request: VpnRpcBody): Promise<void> {
    if (!this.isActiveContext(context) || context.connection === null || context.disposed) {
      return;
    }
    if (this.closed) {
      await this.sendFreshResponse(context, request, createServerStoppingResponse(request));
      return;
    }
    const requestOrdinal: number = requireRequestOrdinal(request);
    const requestFingerprint: Uint8Array = fingerprintRequest(request);

    const inFlight: InFlightRequestValue | undefined = context.inFlight.get(requestOrdinal);
    if (inFlight !== undefined) {
      if (!equalBytes(inFlight.requestFingerprint, requestFingerprint)) {
        throw createTransportFailure('FRAME_INVALID', false);
      }
      return;
    }

    const cached: CachedResponseValue | undefined = context.responseCache.get(requestOrdinal);
    if (cached !== undefined) {
      if (!equalBytes(cached.requestFingerprint, requestFingerprint)) {
        throw createTransportFailure('FRAME_INVALID', false);
      }
      await this.sendRawFrameOrdered(context, cached.frameBytes);
      return;
    }

    if (requestOrdinal <= context.highestAcceptedOrdinal) {
      await this.sendFreshResponse(context, request, createReplayExpiredResponse(request));
      return;
    }
    if (requestOrdinal !== context.highestAcceptedOrdinal + 1) {
      throw createTransportFailure('FRAME_INVALID', false);
    }
    if (context.inFlight.size >= PENDING_LIMIT) {
      await this.sendFreshResponse(context, request, createCommandBusyResponse(request));
      return;
    }

    context.highestAcceptedOrdinal = requestOrdinal;
    context.latestGeneration = request.sessionGeneration;
    context.latestGuards = cloneVpnRpcGuards(request.guards);
    context.hasLatestContext = true;
    context.inFlight.set(requestOrdinal, new InFlightRequestValue(requestOrdinal, requestFingerprint));
    const pending: Promise<void> = this.dispatchRequest(context, request, requestFingerprint);
    pending.catch(swallowError);
  }

  private async dispatchRequest(context: SessionContextValue, request: VpnRpcBody, requestFingerprint: Uint8Array): Promise<void> {
    let response: VpnRpcBody;
    try {
      response = validateResponseBody(request, await this.handler(cloneVpnRpcBody(request)));
    } catch (error) {
      if (error instanceof VpnRpcTransportFailure) {
        await this.failCloseContext(context, error);
        return;
      }
      response = createCoreOperationFailedResponse(request);
    }
    if (!this.isActiveContext(context) || context.connection === null || context.disposed) {
      context.inFlight.delete(requireRequestOrdinal(request));
      return;
    }
    const responseFrameBytes: Uint8Array | null = await this.sendBuiltFrame(
      context,
      (sequence: number, clientEpoch: number): VpnRpcBody => rebuildResponseBody(request, response, sequence, clientEpoch)
    );
    if (!this.isActiveContext(context) || context.disposed) {
      context.inFlight.delete(requireRequestOrdinal(request));
      return;
    }
    if (responseFrameBytes === null) {
      context.inFlight.delete(requireRequestOrdinal(request));
      return;
    }
    this.storeCachedResponse(context, new CachedResponseValue(requireRequestOrdinal(request), requestFingerprint, responseFrameBytes));
    context.latestGeneration = response.sessionGeneration;
    context.latestGuards = cloneVpnRpcGuards(response.guards);
    context.hasLatestContext = true;
    context.inFlight.delete(requireRequestOrdinal(request));
  }

  private async sendFreshResponse(context: SessionContextValue, request: VpnRpcBody, response: VpnRpcBody): Promise<void> {
    await this.sendBuiltFrame(
      context,
      (sequence: number, clientEpoch: number): VpnRpcBody => rebuildResponseBody(request, response, sequence, clientEpoch)
    );
  }

  private storeCachedResponse(context: SessionContextValue, cached: CachedResponseValue): void {
    context.responseCache.set(cached.ordinal, cached);
    context.cacheOrder.push(cached.ordinal);
    while (context.cacheOrder.length > RESPONSE_CACHE_LIMIT) {
      const expiredOrdinal: number | undefined = context.cacheOrder.shift();
      if (expiredOrdinal === undefined) {
        return;
      }
      context.responseCache.delete(expiredOrdinal);
    }
  }

  private async sendEventFrame(
    context: SessionContextValue,
    method: VpnRpcMethod,
    sessionGeneration: number,
    guards: VpnRpcGuards,
    payload: VpnRpcPayload
  ): Promise<boolean> {
    const eventFrame: Uint8Array | null = await this.sendBuiltFrame(
      context,
      (sequence: number, clientEpoch: number): VpnRpcBody => createVpnRpcBodyEvent(
        sequence,
        clientEpoch,
        method,
        sessionGeneration,
        guards,
        payload
      )
    );
    return eventFrame !== null;
  }

  private async sendBuiltFrame(
    context: SessionContextValue,
    builder: (sequence: number, clientEpoch: number) => VpnRpcBody
  ): Promise<Uint8Array | null> {
    return await context.outboundGate.runExclusive(async (): Promise<Uint8Array | null> => {
      if (!this.isActiveContext(context) || context.connection === null || context.disposed) {
        return null;
      }
      try {
        const protectedBody = await context.connection.encodeOutgoingBody(builder);
        if (!this.isActiveContext(context) || context.disposed) {
          return null;
        }
        const bytes: Uint8Array = frameBytes(protectedBody.bodyBytes, protectedBody.macBytes);
        await context.socket.send(copyBytes(bytes));
        return bytes;
      } catch (error) {
        if (!this.isActiveContext(context)) {
          return null;
        }
        await this.failCloseContext(
          context,
          normalizeUnknownError(error instanceof Error ? error : new Error('vpn-rpc-server-outbound'), 'RPC_DISCONNECTED')
        );
        return null;
      }
    });
  }

  private async sendRawFrameOrdered(context: SessionContextValue, bytes: Uint8Array): Promise<boolean> {
    return await context.outboundGate.runExclusive(async (): Promise<boolean> => {
      if (!this.isActiveContext(context) || context.disposed) {
        return false;
      }
      try {
        await context.socket.send(copyBytes(bytes));
        return true;
      } catch (error) {
        if (!this.isActiveContext(context)) {
          return false;
        }
        await this.failCloseContext(
          context,
          normalizeUnknownError(error instanceof Error ? error : new Error('vpn-rpc-server-cached-response'), 'RPC_DISCONNECTED')
        );
        return false;
      }
    });
  }

  private async handleSocketClosed(context: SessionContextValue): Promise<void> {
    if (!this.isLiveContext(context)) {
      return;
    }
    await this.disposeContext(context, false);
  }

  private async failCloseContext(context: SessionContextValue, _failure: VpnRpcTransportFailure): Promise<void> {
    await this.disposeContext(context, true);
  }

  private async disposeContext(context: SessionContextValue, closeSocket: boolean): Promise<void> {
    if (context.disposed) {
      return;
    }
    context.disposed = true;
    context.inboundBudget.close();
    context.eventBudget.close();
    this.cancelCandidateTimeoutOnce(context);
    if (this.activeContext === context) {
      this.activeContext = null;
    }
    if (this.candidateContext === context) {
      this.candidateContext = null;
    }
    context.authenticator.dispose();
    context.connection?.dispose();
    context.connection = null;
    context.socket.unsubscribeData(context.dataId);
    context.socket.unsubscribeClose(context.closeId);
    context.socket.unsubscribeError(context.errorId);
    context.framer.reset();
    context.inFlight.clear();
    if (closeSocket) {
      try {
        await context.socket.close();
      } catch {}
    }
  }

  private startCandidateTimeout(context: SessionContextValue): void {
    try {
      context.candidateTimeoutTask = this.scheduler.schedule(CANDIDATE_AUTH_TIMEOUT_MS, async (): Promise<void> => {
        if (!this.isCandidateContext(context) || context.authenticated || context.disposed) {
          return;
        }
        const pending: Promise<void> = this.failCloseContext(context, createTransportFailure('AUTH_FAILED', false));
        pending.catch(swallowError);
      });
    } catch (error) {
      throw normalizeUnknownError(
        error instanceof Error ? error : new Error('vpn-rpc-server-candidate-timeout'),
        'RPC_UNAVAILABLE'
      );
    }
  }

  private cancelCandidateTimeoutOnce(context: SessionContextValue): void {
    if (context.candidateTimeoutCanceled) {
      return;
    }
    context.candidateTimeoutCanceled = true;
    if (context.candidateTimeoutTask !== null) {
      context.candidateTimeoutTask.cancel();
    }
  }

  private async closeServerOnce(): Promise<void> {
    if (this.serverClosed) {
      return;
    }
    this.serverClosed = true;
    try {
      await this.server.close();
    } catch {}
  }

  private isCurrentContext(context: SessionContextValue): boolean {
    return this.isActiveContext(context);
  }

  private isActiveContext(context: SessionContextValue): boolean {
    return this.activeContext === context && !context.disposed;
  }

  private isCandidateContext(context: SessionContextValue): boolean {
    return this.candidateContext === context && !context.disposed;
  }

  private isLiveContext(context: SessionContextValue): boolean {
    return this.isActiveContext(context) || this.isCandidateContext(context);
  }
}
