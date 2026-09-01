import {
  constantTimeEqualVpnRpcBytes,
  decodeVpnRpcLowercaseHex,
  decodeVpnRpcUtf8,
  encodeVpnRpcLowercaseHex,
  encodeVpnRpcU32BE,
  encodeVpnRpcU64BE,
  encodeVpnRpcUtf8
} from './VpnRpcBinaryCodec';
import { decodeVpnRpcBodyBytes, decodeVpnRpcBodyText, encodeVpnRpcBody } from './VpnRpcBodyCodec';
import {
  cloneVpnRpcBody,
  createVpnRpcClientAuthBody,
  createVpnRpcServerAuthBody,
  createVpnRpcServerHelloBody,
  type VpnRpcBody,
  type VpnRpcClientAuthBody,
  type VpnRpcServerAuthBody,
  type VpnRpcServerHelloBody,
  type VpnRpcTransportErrorCode
} from './VpnRpcModels';
import type {
  VpnRpcCancelableTaskPort,
  VpnRpcCryptoPort,
  VpnRpcRandomPort,
  VpnRpcSchedulerPort
} from './VpnRpcPorts';

const VPN_RPC_AUTH_TIMEOUT_MS: number = 3000;
const STATE_IDLE: number = 0;
const STATE_STARTING: number = 1;
const STATE_BEGUN: number = 2;
const STATE_AUTHENTICATING: number = 3;
const STATE_AUTHENTICATED: number = 4;
const STATE_FAILED: number = 5;
const STATE_TIMED_OUT: number = 6;
const STATE_DISPOSED: number = 7;
const FRAME_MAC_BYTES: number = 32;
const NONCE_BYTES: number = 32;
const INSTANCE_BYTES: number = 16;
const MAX_AUTHENTICATED_PENDING_PER_DIRECTION: number = 64;
const TERMINAL_NONE: number = 0;
const TERMINAL_AUTH: number = 1;
const TERMINAL_FRAME: number = 2;
const TERMINAL_PROTOCOL: number = 3;
const VPN_RPC_AUTH_FAILED_MESSAGE: string = 'VPN RPC authentication failed.';
const VPN_RPC_FRAME_INVALID_MESSAGE: string = 'VPN RPC authenticated frame invalid.';
const VPN_RPC_PROTOCOL_MISMATCH_MESSAGE: string = 'VPN RPC protocol mismatch.';
const VPN_RPC_TIMEOUT_MESSAGE: string = 'VPN RPC authentication timed out.';
const VPN_RPC_RPC_UNAVAILABLE_MESSAGE: string = 'VPN RPC unavailable.';
const SOCKET_ADDRESS_LABEL: string = 'cmfa-vpn-rpc/socket-address/v1';
const CLIENT_AUTH_LABEL: string = 'CMFA-VPN-RPC/CLIENT-AUTH/v1';
const SERVER_AUTH_LABEL: string = 'CMFA-VPN-RPC/SERVER-AUTH/v1';
const C2S_KEY_LABEL: string = 'CMFA-VPN-RPC/C2S-KEY/v1';
const S2C_KEY_LABEL: string = 'CMFA-VPN-RPC/S2C-KEY/v1';
const FRAME_MAC_LABEL: string = 'CMFA-VPN-RPC/FRAME/v1';
const PROTOCOL_VERSION_PREFIX: string = '{"protocolVersion":';

export class VpnRpcTransportFailure extends Error {
  code: VpnRpcTransportErrorCode;
  retryable: boolean;

  constructor(message: string, code: VpnRpcTransportErrorCode, retryable: boolean) {
    super(message);
    this.code = code;
    this.retryable = retryable;
  }
}

export interface VpnRpcProtectedBody {
  bodyBytes: Uint8Array;
  macBytes: Uint8Array;
}

export type VpnRpcOutgoingBodyBuilder = (sequence: number, clientEpoch: number) => VpnRpcBody;

export interface VpnRpcAuthenticatedConnection {
  encodeOutgoingBody(builder: VpnRpcOutgoingBodyBuilder): Promise<VpnRpcProtectedBody>;
  decodeIncomingFrame(bodyBytes: Uint8Array, macBytes: Uint8Array): Promise<VpnRpcBody>;
  dispose(): void;
}

export interface VpnRpcServerAuthenticationResult {
  serverAuth: VpnRpcServerAuthBody;
  connection: VpnRpcAuthenticatedConnection;
}

class VpnRpcProtectedBodyValue implements VpnRpcProtectedBody {
  bodyBytes: Uint8Array;
  macBytes: Uint8Array;

  constructor(bodyBytes: Uint8Array, macBytes: Uint8Array) {
    this.bodyBytes = copyBytes(bodyBytes);
    this.macBytes = copyBytes(macBytes);
  }
}

class VpnRpcServerAuthenticationResultValue implements VpnRpcServerAuthenticationResult {
  serverAuth: VpnRpcServerAuthBody;
  connection: VpnRpcAuthenticatedConnection;

  constructor(serverAuth: VpnRpcServerAuthBody, connection: VpnRpcAuthenticatedConnection) {
    this.serverAuth = createVpnRpcServerAuthBody(1, serverAuth.clientEpoch, serverAuth.serverProof);
    this.connection = connection;
  }
}

function copyBytes(bytes: Uint8Array): Uint8Array {
  return bytes.slice();
}

function joinBytes(parts: Uint8Array[]): Uint8Array {
  let totalLength: number = 0;
  for (let index: number = 0; index < parts.length; index += 1) {
    totalLength += parts[index].length;
  }
  const joined: Uint8Array = new Uint8Array(totalLength);
  let offset: number = 0;
  for (let index: number = 0; index < parts.length; index += 1) {
    joined.set(parts[index], offset);
    offset += parts[index].length;
  }
  return joined;
}

function zeroBytes(bytes: Uint8Array | null): void {
  if (bytes === null) {
    return;
  }
  bytes.fill(0);
}

function authFailed(): never {
  throw new VpnRpcTransportFailure(VPN_RPC_AUTH_FAILED_MESSAGE, 'AUTH_FAILED', false);
}

function frameInvalid(): never {
  throw new VpnRpcTransportFailure(VPN_RPC_FRAME_INVALID_MESSAGE, 'FRAME_INVALID', false);
}

function protocolMismatch(): never {
  throw new VpnRpcTransportFailure(VPN_RPC_PROTOCOL_MISMATCH_MESSAGE, 'PROTOCOL_MISMATCH', false);
}

function timeoutFailed(): never {
  throw new VpnRpcTransportFailure(VPN_RPC_TIMEOUT_MESSAGE, 'AUTH_FAILED', false);
}

function rpcUnavailable(): never {
  throw new VpnRpcTransportFailure(VPN_RPC_RPC_UNAVAILABLE_MESSAGE, 'RPC_UNAVAILABLE', true);
}

function internalMarkerError(): Error {
  return new Error('vpn-rpc-error');
}

function isTransportFailure(error: Error): boolean {
  return error instanceof VpnRpcTransportFailure;
}

function decodeExactHex(rawValue: string, expectedLength: number): Uint8Array {
  try {
    const decoded: Uint8Array = decodeVpnRpcLowercaseHex(rawValue);
    if (decoded.length !== expectedLength) {
      authFailed();
    }
    return decoded;
  } catch (error) {
    if (error instanceof VpnRpcTransportFailure) {
      throw error;
    }
    authFailed();
  }
}

function normalizeHmacResult(bytes: Uint8Array): Uint8Array {
  if (bytes.length !== FRAME_MAC_BYTES) {
    authFailed();
  }
  return copyBytes(bytes);
}

function copyOwnedHmacResultAndZero(bytes: Uint8Array): Uint8Array {
  const copiedBytes: Uint8Array = copyBytes(bytes);
  zeroBytes(bytes);
  if (copiedBytes.length !== FRAME_MAC_BYTES) {
    zeroBytes(copiedBytes);
    authFailed();
  }
  return copiedBytes;
}

async function computeOwnedRootHmac(crypto: VpnRpcCryptoPort, inputBytes: Uint8Array): Promise<Uint8Array> {
  let rawResult: Uint8Array | null = null;
  try {
    rawResult = await crypto.rootHmac(inputBytes);
    return copyOwnedHmacResultAndZero(rawResult);
  } finally {
    zeroBytes(inputBytes);
    zeroBytes(rawResult);
  }
}

async function computeOwnedDerivedHmac(crypto: VpnRpcCryptoPort, keyBytes: Uint8Array, inputBytes: Uint8Array): Promise<Uint8Array> {
  let rawResult: Uint8Array | null = null;
  try {
    rawResult = await crypto.derivedHmac(keyBytes, inputBytes);
    return copyOwnedHmacResultAndZero(rawResult);
  } finally {
    zeroBytes(keyBytes);
    zeroBytes(inputBytes);
    zeroBytes(rawResult);
  }
}

function requireProtocolVersion(protocolVersion: number): void {
  if (protocolVersion !== 1) {
    protocolMismatch();
  }
}

function requireSafePositiveInteger(value: number): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    authFailed();
  }
  return value;
}

function socketAddressInput(): Uint8Array {
  return encodeVpnRpcUtf8(SOCKET_ADDRESS_LABEL);
}

function buildProofInput(label: string, first: Uint8Array, second: Uint8Array, third: Uint8Array): Uint8Array {
  return joinBytes([
    encodeVpnRpcUtf8(label),
    new Uint8Array([0x00]),
    first,
    second,
    third
  ]);
}

function buildDerivedKeyInput(label: string, serverNonce: Uint8Array, clientNonce: Uint8Array, serverInstance: Uint8Array, clientEpoch: number): Uint8Array {
  return joinBytes([
    encodeVpnRpcUtf8(label),
    new Uint8Array([0x00]),
    serverNonce,
    clientNonce,
    serverInstance,
    encodeVpnRpcU64BE(clientEpoch)
  ]);
}

function buildFrameMacInput(bodyBytes: Uint8Array): Uint8Array {
  return joinBytes([
    encodeVpnRpcUtf8(FRAME_MAC_LABEL),
    new Uint8Array([0x00]),
    encodeVpnRpcU32BE(bodyBytes.length),
    bodyBytes
  ]);
}

function isCanonicalSafeIntegerToken(token: string): boolean {
  if (token.length === 0) {
    return false;
  }
  if (token === '0') {
    return true;
  }
  if (token.charCodeAt(0) === 0x30) {
    return false;
  }
  for (let index: number = 0; index < token.length; index += 1) {
    const codeUnit: number = token.charCodeAt(index);
    if (codeUnit < 0x30 || codeUnit > 0x39) {
      return false;
    }
  }
  const value: number = Number.parseInt(token, 10);
  return Number.isSafeInteger(value) && `${value}` === token;
}

function matchesProtocolMismatchBody(bodyBytes: Uint8Array): boolean {
  let bodyText: string = '';
  try {
    bodyText = decodeVpnRpcUtf8(bodyBytes);
  } catch (_) {
    return false;
  }
  if (!bodyText.startsWith(PROTOCOL_VERSION_PREFIX)) {
    return false;
  }
  const tokenStart: number = PROTOCOL_VERSION_PREFIX.length;
  const tokenEnd: number = bodyText.indexOf(',', tokenStart);
  if (tokenEnd < 0) {
    return false;
  }
  const token: string = bodyText.slice(tokenStart, tokenEnd);
  if (!isCanonicalSafeIntegerToken(token) || token === '1') {
    return false;
  }
  const candidateText: string = `${PROTOCOL_VERSION_PREFIX}1${bodyText.slice(tokenEnd)}`;
  try {
    decodeVpnRpcBodyText(candidateText);
    return true;
  } catch (_) {
    return false;
  }
}

class VpnRpcSerialGate {
  private tail: Promise<void> = Promise.resolve();

  async runExclusive<T>(runner: () => Promise<T>): Promise<T> {
    const previousTail: Promise<void> = this.tail;
    const nextTail: VpnRpcDeferredVoid = new VpnRpcDeferredVoid();
    this.tail = nextTail.promise;
    await previousTail;
    try {
      return await runner();
    } finally {
      nextTail.release();
    }
  }
}

class VpnRpcDeferredVoid {
  readonly promise: Promise<void>;
  private resolveValue: () => void = (): void => {};

  constructor() {
    this.promise = new Promise<void>((resolve: () => void): void => {
      this.resolveValue = resolve;
    });
  }

  release(): void {
    this.resolveValue();
  }
}

class VpnRpcAuthenticatedConnectionValue implements VpnRpcAuthenticatedConnection {
  private readonly crypto: VpnRpcCryptoPort;
  private readonly clientEpoch: number;
  private readonly outgoingGate: VpnRpcSerialGate = new VpnRpcSerialGate();
  private readonly incomingGate: VpnRpcSerialGate = new VpnRpcSerialGate();
  private sendKey: Uint8Array | null;
  private receiveKey: Uint8Array | null;
  private expectedOutgoingSequence: number = 1;
  private expectedIncomingSequence: number = 1;
  private pendingOutgoingCount: number = 0;
  private pendingIncomingCount: number = 0;
  private generation: number = 0;
  private disposed: boolean = false;
  private terminalFailure: number = TERMINAL_NONE;

  constructor(crypto: VpnRpcCryptoPort, sendKey: Uint8Array, receiveKey: Uint8Array, clientEpoch: number) {
    this.crypto = crypto;
    this.sendKey = copyBytes(sendKey);
    this.receiveKey = copyBytes(receiveKey);
    this.clientEpoch = requireSafePositiveInteger(clientEpoch);
  }

  async encodeOutgoingBody(builder: VpnRpcOutgoingBodyBuilder): Promise<VpnRpcProtectedBody> {
    this.reserveOutgoingPending();
    return this.outgoingGate.runExclusive(async (): Promise<VpnRpcProtectedBody> => {
      let builtBody: VpnRpcBody | null = null;
      let copiedBody: VpnRpcBody | null = null;
      let bodyBytes: Uint8Array | null = null;
      let macBytes: Uint8Array | null = null;
      let sendKey: Uint8Array | null = null;
      this.ensureUsable();
      const capturedGeneration: number = this.generation;
      try {
        builtBody = builder(this.expectedOutgoingSequence, this.clientEpoch);
        copiedBody = cloneVpnRpcBody(builtBody);
        requireProtocolVersion(copiedBody.protocolVersion);
        if (copiedBody.clientEpoch !== this.clientEpoch || copiedBody.sequence !== this.expectedOutgoingSequence) {
          this.failAndDisposeFrame();
        }
        bodyBytes = encodeVpnRpcBody(copiedBody);
        sendKey = copyBytes(this.requireSendKey());
        try {
          macBytes = await computeOwnedDerivedHmac(this.crypto, sendKey, buildFrameMacInput(bodyBytes));
        } catch (error) {
          const typedDependencyError: Error = error instanceof Error ? error : internalMarkerError();
          if (isTransportFailure(typedDependencyError)) {
            throw typedDependencyError;
          }
          this.failAndDisposeAuth();
        }
        this.ensureOperationActive(capturedGeneration);
        this.expectedOutgoingSequence += 1;
        return new VpnRpcProtectedBodyValue(bodyBytes, macBytes);
      } catch (error) {
        const typedError: Error = error instanceof Error ? error : internalMarkerError();
        if (isTransportFailure(typedError)) {
          throw typedError;
        }
        this.failAndDisposeFrame();
      } finally {
        builtBody = null;
        copiedBody = null;
        zeroBytes(sendKey);
        zeroBytes(bodyBytes);
        zeroBytes(macBytes);
        this.releaseOutgoingPending();
      }
    });
  }

  async decodeIncomingFrame(bodyBytes: Uint8Array, macBytes: Uint8Array): Promise<VpnRpcBody> {
    this.reserveIncomingPending();
    return this.incomingGate.runExclusive(async (): Promise<VpnRpcBody> => {
      let copiedBody: Uint8Array | null = null;
      let copiedMac: Uint8Array | null = null;
      let expectedMac: Uint8Array | null = null;
      let receiveKey: Uint8Array | null = null;
      this.ensureUsable();
      const capturedGeneration: number = this.generation;
      copiedBody = copyBytes(bodyBytes);
      copiedMac = copyBytes(macBytes);
      if (copiedMac.length !== FRAME_MAC_BYTES) {
        this.failAndDisposeFrame();
      }
      try {
        receiveKey = copyBytes(this.requireReceiveKey());
        expectedMac = await computeOwnedDerivedHmac(this.crypto, receiveKey, buildFrameMacInput(copiedBody));
        this.ensureOperationActive(capturedGeneration);
        if (!constantTimeEqualVpnRpcBytes(expectedMac, copiedMac)) {
          this.failAndDisposeFrame();
        }
        const decoded: VpnRpcBody = decodeVpnRpcBodyBytes(copiedBody);
        requireProtocolVersion(decoded.protocolVersion);
        if (decoded.clientEpoch !== this.clientEpoch || decoded.sequence !== this.expectedIncomingSequence) {
          this.failAndDisposeFrame();
        }
        this.expectedIncomingSequence += 1;
        return decoded;
      } catch (error) {
        const typedError: Error = error instanceof Error ? error : internalMarkerError();
        if (isTransportFailure(typedError)) {
          throw typedError;
        }
        if (matchesProtocolMismatchBody(copiedBody)) {
          this.failAndDisposeProtocol();
        }
        this.failAndDisposeDecodedBodyError(typedError);
      } finally {
        zeroBytes(receiveKey);
        zeroBytes(copiedBody);
        zeroBytes(copiedMac);
        zeroBytes(expectedMac);
        this.releaseIncomingPending();
      }
    });
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.generation += 1;
    zeroBytes(this.sendKey);
    zeroBytes(this.receiveKey);
    this.sendKey = null;
    this.receiveKey = null;
  }

  private ensureUsable(): void {
    if (this.disposed) {
      if (this.terminalFailure === TERMINAL_AUTH) {
        authFailed();
      }
      if (this.terminalFailure === TERMINAL_PROTOCOL) {
        protocolMismatch();
      }
      frameInvalid();
    }
  }

  private requireSendKey(): Uint8Array {
    if (this.sendKey === null) {
      frameInvalid();
    }
    return this.sendKey;
  }

  private requireReceiveKey(): Uint8Array {
    if (this.receiveKey === null) {
      frameInvalid();
    }
    return this.receiveKey;
  }

  private ensureOperationActive(capturedGeneration: number): void {
    if (this.disposed || this.generation !== capturedGeneration) {
      this.failClosedForTerminalState();
    }
  }

  private reserveOutgoingPending(): void {
    this.pendingOutgoingCount += 1;
    if (this.pendingOutgoingCount > MAX_AUTHENTICATED_PENDING_PER_DIRECTION) {
      this.releaseOutgoingPending();
      this.failAndDisposeFrame();
    }
  }

  private releaseOutgoingPending(): void {
    if (this.pendingOutgoingCount > 0) {
      this.pendingOutgoingCount -= 1;
    }
  }

  private reserveIncomingPending(): void {
    this.pendingIncomingCount += 1;
    if (this.pendingIncomingCount > MAX_AUTHENTICATED_PENDING_PER_DIRECTION) {
      this.releaseIncomingPending();
      this.failAndDisposeFrame();
    }
  }

  private releaseIncomingPending(): void {
    if (this.pendingIncomingCount > 0) {
      this.pendingIncomingCount -= 1;
    }
  }

  private failClosedForTerminalState(): never {
    if (this.terminalFailure === TERMINAL_AUTH) {
      authFailed();
    }
    if (this.terminalFailure === TERMINAL_PROTOCOL) {
      protocolMismatch();
    }
    frameInvalid();
  }

  private failAndDisposeFrame(): never {
    this.terminalFailure = TERMINAL_FRAME;
    this.dispose();
    frameInvalid();
  }

  private failAndDisposeAuth(): never {
    this.terminalFailure = TERMINAL_AUTH;
    this.dispose();
    authFailed();
  }

  private failAndDisposeProtocol(): never {
    this.terminalFailure = TERMINAL_PROTOCOL;
    this.dispose();
    protocolMismatch();
  }

  private failAndDisposeDecodedBodyError(error: Error): never {
    this.failAndDisposeFrame();
  }
}

export async function deriveVpnRpcSocketAddress(crypto: VpnRpcCryptoPort): Promise<string> {
  let hmacBytes: Uint8Array | null = null;
  try {
    await crypto.prepare();
    hmacBytes = await computeOwnedRootHmac(crypto, socketAddressInput());
    return `cmfa_vpn_rpc_v1_${encodeVpnRpcLowercaseHex(hmacBytes).slice(0, 32)}`;
  } catch (error) {
    if (error instanceof VpnRpcTransportFailure) {
      throw error;
    }
    authFailed();
  } finally {
    zeroBytes(hmacBytes);
  }
}

export class VpnRpcClientAuthenticator {
  private readonly crypto: VpnRpcCryptoPort;
  private readonly random: VpnRpcRandomPort;
  private readonly scheduler: VpnRpcSchedulerPort;
  private state: number = STATE_IDLE;
  private timeoutTask: VpnRpcCancelableTaskPort | null = null;
  private timeoutCanceled: boolean = false;
  private serverNonce: Uint8Array | null = null;
  private serverInstance: Uint8Array | null = null;
  private clientNonce: Uint8Array | null = null;

  constructor(crypto: VpnRpcCryptoPort, random: VpnRpcRandomPort, scheduler: VpnRpcSchedulerPort) {
    this.crypto = crypto;
    this.random = random;
    this.scheduler = scheduler;
  }

  async begin(serverHello: VpnRpcServerHelloBody): Promise<VpnRpcClientAuthBody> {
    let serverNonce: Uint8Array | null = null;
    let serverInstance: Uint8Array | null = null;
    let clientNonceSource: Uint8Array | null = null;
    let clientNonce: Uint8Array | null = null;
    let clientProof: Uint8Array | null = null;
    this.ensureIdle();
    this.state = STATE_STARTING;
    try {
      this.startTimeout();
      requireProtocolVersion(serverHello.protocolVersion);
      await this.crypto.prepare();
      this.requireContinuationState(STATE_STARTING);
      serverNonce = decodeExactHex(serverHello.serverNonce, NONCE_BYTES);
      serverInstance = decodeExactHex(serverHello.serverInstance, INSTANCE_BYTES);
      clientNonceSource = this.random.bytes(NONCE_BYTES);
      if (clientNonceSource.length !== NONCE_BYTES) {
        this.failAndDispose();
      }
      clientNonce = copyBytes(clientNonceSource);
      clientProof = await computeOwnedRootHmac(this.crypto, buildProofInput(CLIENT_AUTH_LABEL, serverNonce, clientNonce, serverInstance));
      this.requireContinuationState(STATE_STARTING);
      this.serverNonce = copyBytes(serverNonce);
      this.serverInstance = copyBytes(serverInstance);
      this.clientNonce = copyBytes(clientNonce);
      this.state = STATE_BEGUN;
      return createVpnRpcClientAuthBody(1, encodeVpnRpcLowercaseHex(clientNonce), encodeVpnRpcLowercaseHex(clientProof));
    } catch (error) {
      const typedError: Error = error instanceof Error ? error : internalMarkerError();
      if (isTransportFailure(typedError)) {
        this.rethrowAfterCleanup(typedError);
      }
      this.failAndDispose();
    } finally {
      zeroBytes(serverNonce);
      zeroBytes(serverInstance);
      zeroBytes(clientNonceSource);
      zeroBytes(clientNonce);
      zeroBytes(clientProof);
    }
  }

  async acceptServerAuth(serverAuth: VpnRpcServerAuthBody): Promise<VpnRpcAuthenticatedConnection> {
    let serverNonce: Uint8Array | null = null;
    let clientNonce: Uint8Array | null = null;
    let serverInstance: Uint8Array | null = null;
    let expectedServerProof: Uint8Array | null = null;
    let actualServerProof: Uint8Array | null = null;
    let c2sKey: Uint8Array | null = null;
    let s2cKey: Uint8Array | null = null;
    this.ensureBegun();
    this.state = STATE_AUTHENTICATING;
    try {
      requireProtocolVersion(serverAuth.protocolVersion);
      const clientEpoch: number = requireSafePositiveInteger(serverAuth.clientEpoch);
      serverNonce = copyBytes(this.requireServerNonce());
      clientNonce = copyBytes(this.requireClientNonce());
      serverInstance = copyBytes(this.requireServerInstance());
      expectedServerProof = await computeOwnedRootHmac(this.crypto, buildProofInput(SERVER_AUTH_LABEL, clientNonce, serverNonce, serverInstance));
      this.requireContinuationState(STATE_AUTHENTICATING);
      actualServerProof = decodeExactHex(serverAuth.serverProof, FRAME_MAC_BYTES);
      if (!constantTimeEqualVpnRpcBytes(expectedServerProof, actualServerProof)) {
        this.failAndDispose();
      }
      c2sKey = await computeOwnedRootHmac(this.crypto, buildDerivedKeyInput(C2S_KEY_LABEL, serverNonce, clientNonce, serverInstance, clientEpoch));
      this.requireContinuationState(STATE_AUTHENTICATING);
      s2cKey = await computeOwnedRootHmac(this.crypto, buildDerivedKeyInput(S2C_KEY_LABEL, serverNonce, clientNonce, serverInstance, clientEpoch));
      this.requireContinuationState(STATE_AUTHENTICATING);
      const connection: VpnRpcAuthenticatedConnection = new VpnRpcAuthenticatedConnectionValue(
        this.crypto,
        c2sKey,
        s2cKey,
        clientEpoch
      );
      this.state = STATE_AUTHENTICATED;
      this.cancelTimeoutOnce();
      this.clearHandshakeState();
      return connection;
    } catch (error) {
      const typedError: Error = error instanceof Error ? error : internalMarkerError();
      if (isTransportFailure(typedError)) {
        this.rethrowAfterCleanup(typedError);
      }
      this.failAndDispose();
    } finally {
      zeroBytes(serverNonce);
      zeroBytes(clientNonce);
      zeroBytes(serverInstance);
      zeroBytes(expectedServerProof);
      zeroBytes(actualServerProof);
      zeroBytes(c2sKey);
      zeroBytes(s2cKey);
    }
  }

  dispose(): void {
    if (this.state === STATE_DISPOSED) {
      return;
    }
    this.state = STATE_DISPOSED;
    this.cancelTimeoutOnce();
    this.clearHandshakeState();
  }

  private ensureIdle(): void {
    if (this.state === STATE_TIMED_OUT) {
      timeoutFailed();
    }
    if (this.state !== STATE_IDLE) {
      authFailed();
    }
  }

  private ensureBegun(): void {
    if (this.state === STATE_TIMED_OUT) {
      timeoutFailed();
    }
    if (this.state !== STATE_BEGUN) {
      authFailed();
    }
  }

  private requireContinuationState(expectedState: number): void {
    if (this.state === STATE_TIMED_OUT) {
      timeoutFailed();
    }
    if (this.state !== expectedState) {
      authFailed();
    }
  }

  private startTimeout(): void {
    try {
      this.timeoutTask = this.scheduler.schedule(VPN_RPC_AUTH_TIMEOUT_MS, async (): Promise<void> => {
        if (this.state === STATE_DISPOSED || this.state === STATE_AUTHENTICATED || this.state === STATE_FAILED || this.state === STATE_TIMED_OUT) {
          return;
        }
        this.state = STATE_TIMED_OUT;
        this.cancelTimeoutOnce();
        this.clearHandshakeState();
      });
    } catch (error) {
      const typedError: Error = error instanceof Error ? error : internalMarkerError();
      if (isTransportFailure(typedError)) {
        throw typedError;
      }
      rpcUnavailable();
    }
  }

  private cancelTimeoutOnce(): void {
    if (this.timeoutCanceled) {
      return;
    }
    this.timeoutCanceled = true;
    if (this.timeoutTask !== null) {
      this.timeoutTask.cancel();
    }
  }

  private requireServerNonce(): Uint8Array {
    if (this.serverNonce === null) {
      authFailed();
    }
    return this.serverNonce;
  }

  private requireServerInstance(): Uint8Array {
    if (this.serverInstance === null) {
      authFailed();
    }
    return this.serverInstance;
  }

  private requireClientNonce(): Uint8Array {
    if (this.clientNonce === null) {
      authFailed();
    }
    return this.clientNonce;
  }

  private clearHandshakeState(): void {
    zeroBytes(this.serverNonce);
    zeroBytes(this.serverInstance);
    zeroBytes(this.clientNonce);
    this.serverNonce = null;
    this.serverInstance = null;
    this.clientNonce = null;
  }

  private rethrowAfterCleanup(error: Error): never {
    if (this.state !== STATE_TIMED_OUT && this.state !== STATE_DISPOSED) {
      this.state = STATE_FAILED;
    }
    this.cancelTimeoutOnce();
    this.clearHandshakeState();
    throw error;
  }

  private failAndDispose(): never {
    this.state = STATE_FAILED;
    this.cancelTimeoutOnce();
    this.clearHandshakeState();
    authFailed();
  }
}

export class VpnRpcServerAuthenticator {
  private readonly crypto: VpnRpcCryptoPort;
  private readonly random: VpnRpcRandomPort;
  private readonly scheduler: VpnRpcSchedulerPort;
  private state: number = STATE_IDLE;
  private timeoutTask: VpnRpcCancelableTaskPort | null = null;
  private timeoutCanceled: boolean = false;
  private serverNonce: Uint8Array | null = null;
  private serverInstance: Uint8Array | null = null;

  constructor(crypto: VpnRpcCryptoPort, random: VpnRpcRandomPort, scheduler: VpnRpcSchedulerPort) {
    this.crypto = crypto;
    this.random = random;
    this.scheduler = scheduler;
  }

  async begin(): Promise<VpnRpcServerHelloBody> {
    let serverNonceSource: Uint8Array | null = null;
    let serverInstanceSource: Uint8Array | null = null;
    let serverNonce: Uint8Array | null = null;
    let serverInstance: Uint8Array | null = null;
    this.ensureIdle();
    this.state = STATE_STARTING;
    try {
      this.startTimeout();
      await this.crypto.prepare();
      this.requireContinuationState(STATE_STARTING);
      serverNonceSource = this.random.bytes(NONCE_BYTES);
      serverInstanceSource = this.random.bytes(INSTANCE_BYTES);
      if (serverNonceSource.length !== NONCE_BYTES || serverInstanceSource.length !== INSTANCE_BYTES) {
        this.failAndDispose();
      }
      serverNonce = copyBytes(serverNonceSource);
      serverInstance = copyBytes(serverInstanceSource);
      this.requireContinuationState(STATE_STARTING);
      this.serverNonce = copyBytes(serverNonce);
      this.serverInstance = copyBytes(serverInstance);
      this.state = STATE_BEGUN;
      return createVpnRpcServerHelloBody(1, encodeVpnRpcLowercaseHex(serverNonce), encodeVpnRpcLowercaseHex(serverInstance));
    } catch (error) {
      const typedError: Error = error instanceof Error ? error : internalMarkerError();
      if (isTransportFailure(typedError)) {
        this.rethrowAfterCleanup(typedError);
      }
      this.failAndDispose();
    } finally {
      zeroBytes(serverNonceSource);
      zeroBytes(serverInstanceSource);
      zeroBytes(serverNonce);
      zeroBytes(serverInstance);
    }
  }

  async acceptClientAuth(clientAuth: VpnRpcClientAuthBody, clientEpoch: number): Promise<VpnRpcServerAuthenticationResult> {
    let serverNonce: Uint8Array | null = null;
    let serverInstance: Uint8Array | null = null;
    let clientNonce: Uint8Array | null = null;
    let expectedClientProof: Uint8Array | null = null;
    let actualClientProof: Uint8Array | null = null;
    let serverProof: Uint8Array | null = null;
    let c2sKey: Uint8Array | null = null;
    let s2cKey: Uint8Array | null = null;
    this.ensureBegun();
    this.state = STATE_AUTHENTICATING;
    try {
      requireProtocolVersion(clientAuth.protocolVersion);
      const safeClientEpoch: number = requireSafePositiveInteger(clientEpoch);
      serverNonce = copyBytes(this.requireServerNonce());
      serverInstance = copyBytes(this.requireServerInstance());
      clientNonce = decodeExactHex(clientAuth.clientNonce, NONCE_BYTES);
      expectedClientProof = await computeOwnedRootHmac(this.crypto, buildProofInput(CLIENT_AUTH_LABEL, serverNonce, clientNonce, serverInstance));
      this.requireContinuationState(STATE_AUTHENTICATING);
      actualClientProof = decodeExactHex(clientAuth.clientProof, FRAME_MAC_BYTES);
      if (!constantTimeEqualVpnRpcBytes(expectedClientProof, actualClientProof)) {
        this.failAndDispose();
      }
      serverProof = await computeOwnedRootHmac(this.crypto, buildProofInput(SERVER_AUTH_LABEL, clientNonce, serverNonce, serverInstance));
      this.requireContinuationState(STATE_AUTHENTICATING);
      c2sKey = await computeOwnedRootHmac(this.crypto, buildDerivedKeyInput(C2S_KEY_LABEL, serverNonce, clientNonce, serverInstance, safeClientEpoch));
      this.requireContinuationState(STATE_AUTHENTICATING);
      s2cKey = await computeOwnedRootHmac(this.crypto, buildDerivedKeyInput(S2C_KEY_LABEL, serverNonce, clientNonce, serverInstance, safeClientEpoch));
      this.requireContinuationState(STATE_AUTHENTICATING);
      const serverAuth: VpnRpcServerAuthBody = createVpnRpcServerAuthBody(
        1,
        safeClientEpoch,
        encodeVpnRpcLowercaseHex(serverProof)
      );
      const connection: VpnRpcAuthenticatedConnection = new VpnRpcAuthenticatedConnectionValue(
        this.crypto,
        s2cKey,
        c2sKey,
        safeClientEpoch
      );
      this.state = STATE_AUTHENTICATED;
      this.cancelTimeoutOnce();
      this.clearHandshakeState();
      return new VpnRpcServerAuthenticationResultValue(serverAuth, connection);
    } catch (error) {
      const typedError: Error = error instanceof Error ? error : internalMarkerError();
      if (isTransportFailure(typedError)) {
        this.rethrowAfterCleanup(typedError);
      }
      this.failAndDispose();
    } finally {
      zeroBytes(serverNonce);
      zeroBytes(serverInstance);
      zeroBytes(clientNonce);
      zeroBytes(expectedClientProof);
      zeroBytes(actualClientProof);
      zeroBytes(serverProof);
      zeroBytes(c2sKey);
      zeroBytes(s2cKey);
    }
  }

  dispose(): void {
    if (this.state === STATE_DISPOSED) {
      return;
    }
    this.state = STATE_DISPOSED;
    this.cancelTimeoutOnce();
    this.clearHandshakeState();
  }

  private ensureIdle(): void {
    if (this.state === STATE_TIMED_OUT) {
      timeoutFailed();
    }
    if (this.state !== STATE_IDLE) {
      authFailed();
    }
  }

  private ensureBegun(): void {
    if (this.state === STATE_TIMED_OUT) {
      timeoutFailed();
    }
    if (this.state !== STATE_BEGUN) {
      authFailed();
    }
  }

  private requireContinuationState(expectedState: number): void {
    if (this.state === STATE_TIMED_OUT) {
      timeoutFailed();
    }
    if (this.state !== expectedState) {
      authFailed();
    }
  }

  private startTimeout(): void {
    try {
      this.timeoutTask = this.scheduler.schedule(VPN_RPC_AUTH_TIMEOUT_MS, async (): Promise<void> => {
        if (this.state === STATE_DISPOSED || this.state === STATE_AUTHENTICATED || this.state === STATE_FAILED || this.state === STATE_TIMED_OUT) {
          return;
        }
        this.state = STATE_TIMED_OUT;
        this.cancelTimeoutOnce();
        this.clearHandshakeState();
      });
    } catch (error) {
      const typedError: Error = error instanceof Error ? error : internalMarkerError();
      if (isTransportFailure(typedError)) {
        throw typedError;
      }
      rpcUnavailable();
    }
  }

  private cancelTimeoutOnce(): void {
    if (this.timeoutCanceled) {
      return;
    }
    this.timeoutCanceled = true;
    if (this.timeoutTask !== null) {
      this.timeoutTask.cancel();
    }
  }

  private requireServerNonce(): Uint8Array {
    if (this.serverNonce === null) {
      authFailed();
    }
    return this.serverNonce;
  }

  private requireServerInstance(): Uint8Array {
    if (this.serverInstance === null) {
      authFailed();
    }
    return this.serverInstance;
  }

  private clearHandshakeState(): void {
    zeroBytes(this.serverNonce);
    zeroBytes(this.serverInstance);
    this.serverNonce = null;
    this.serverInstance = null;
  }

  private rethrowAfterCleanup(error: Error): never {
    if (this.state !== STATE_TIMED_OUT && this.state !== STATE_DISPOSED) {
      this.state = STATE_FAILED;
    }
    this.cancelTimeoutOnce();
    this.clearHandshakeState();
    throw error;
  }

  private failAndDispose(): never {
    this.state = STATE_FAILED;
    this.cancelTimeoutOnce();
    this.clearHandshakeState();
    authFailed();
  }
}
