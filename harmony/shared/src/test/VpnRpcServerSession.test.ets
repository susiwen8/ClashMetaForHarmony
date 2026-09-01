import { describe, expect, it } from '@ohos/hypium';
import {
  VpnRpcClient as BarrelVpnRpcClient
} from '../../Index';
import {
  VpnRpcServerSession as BarrelVpnRpcServerSession
} from '../../Index';
import {
  VpnRpcClientAuthenticator,
  VpnRpcTransportFailure,
  type VpnRpcAuthenticatedConnection
} from '../main/ets/vpn/rpc/VpnRpcAuthenticator';
import {
  encodeVpnRpcClientAuthBody,
  decodeVpnRpcServerAuthBodyBytes,
  decodeVpnRpcServerHelloBodyBytes,
  encodeVpnRpcBodyToText
} from '../main/ets/vpn/rpc/VpnRpcBodyCodec';
import { encodeVpnRpcU32BE } from '../main/ets/vpn/rpc/VpnRpcBinaryCodec';
import { VpnRpcFramer, type VpnRpcDecodedFrame } from '../main/ets/vpn/rpc/VpnRpcFramer';
import {
  createVpnRpcBodyErrorResponse,
  createVpnRpcBodyRequest,
  createVpnRpcBodySuccessResponse,
  createVpnRpcError,
  createVpnRpcGuards,
  type VpnRpcBody,
  type VpnRpcGuards,
  type VpnRpcMethod
} from '../main/ets/vpn/rpc/VpnRpcModels';
import {
  createVpnRpcEmptyPayload,
  createVpnRpcPingSuccessPayload,
  createVpnRpcQueryGroupsPayload,
  createVpnRpcQueryGroupPayload,
  createVpnRpcQueryGroupRequestPayload,
  createVpnRpcRuntimeSnapshotPayload,
  createVpnRpcSelectNodeRequestPayload,
  type VpnRpcPayload
} from '../main/ets/vpn/rpc/VpnRpcPayloads';
import type {
  VpnRpcClockPort,
  VpnRpcCryptoPort,
  VpnRpcRandomPort,
  VpnRpcSchedulerPort,
  VpnRpcSocketClientFactoryPort,
  VpnRpcSocketConnectionPort,
  VpnRpcSocketServerPort
} from '../main/ets/vpn/rpc/VpnRpcPorts';
import { VpnRpcSocketFailure } from '../main/ets/vpn/rpc/VpnRpcPorts';
import { FixtureVpnRpcSchedulerPort } from './fakes/VpnRpcFakes';

const SERVER_ADDRESS: string = 'cmfa_vpn_rpc_v1_test';
const SERVER_INSTANCE_HEX: string = '303132333435363738393a3b3c3d3e3f';
const PROFILE_HASH: string = '1111111111111111111111111111111111111111111111111111111111111111';
const REVISION_HASH: string = '2222222222222222222222222222222222222222222222222222222222222222';
const CATALOG_DIGEST: string = '3333333333333333333333333333333333333333333333333333333333333333';
const ALT_PROFILE_HASH: string = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const ALT_REVISION_HASH: string = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const ALT_CATALOG_DIGEST: string = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const THIRD_PROFILE_HASH: string = '1212121212121212121212121212121212121212121212121212121212121212';
const THIRD_REVISION_HASH: string = '3434343434343434343434343434343434343434343434343434343434343434';
const THIRD_CATALOG_DIGEST: string = '5656565656565656565656565656565656565656565656565656565656565656';
const GROUP_ID: string = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

class DeferredBody {
  readonly promise: Promise<VpnRpcBody>;
  private resolveValue: ((value: VpnRpcBody) => void) | null = null;

  constructor() {
    this.promise = new Promise<VpnRpcBody>((resolve: (value: VpnRpcBody) => void): void => {
      this.resolveValue = resolve;
    });
  }

  resolve(value: VpnRpcBody): void {
    this.resolveValue?.(value);
  }
}

class DeferredBytes {
  readonly promise: Promise<Uint8Array>;
  private readonly result: Uint8Array;
  private resolveValue: ((value: Uint8Array) => void) | null = null;

  constructor(result: Uint8Array) {
    this.result = result.slice();
    this.promise = new Promise<Uint8Array>((resolve: (value: Uint8Array) => void): void => {
      this.resolveValue = resolve;
    });
  }

  resolve(): void {
    this.resolveValue?.(this.result.slice());
  }
}

class DeferredVoid {
  readonly promise: Promise<void>;
  private resolveValue: (() => void) | null = null;

  constructor() {
    this.promise = new Promise<void>((resolve: () => void): void => {
      this.resolveValue = resolve;
    });
  }

  resolve(): void {
    this.resolveValue?.();
  }
}

class ManualClockPort implements VpnRpcClockPort {
  nowValue: number = 0;

  nowMs(): number {
    return this.nowValue;
  }

  advanceBy(ms: number): void {
    this.nowValue += ms;
  }
}

class ManualTask {
  cancelCount: number = 0;
  canceled: boolean = false;

  cancel(): void {
    this.cancelCount += 1;
    this.canceled = true;
  }
}

class ScheduledRunner {
  readonly delayMs: number;
  readonly dueAt: number;
  readonly runner: () => Promise<void>;
  readonly cancelable: ManualTask;
  ran: boolean = false;

  constructor(delayMs: number, dueAt: number, runner: () => Promise<void>, cancelable: ManualTask) {
    this.delayMs = delayMs;
    this.dueAt = dueAt;
    this.runner = runner;
    this.cancelable = cancelable;
  }

  async run(): Promise<void> {
    if (this.ran || this.cancelable.canceled) {
      return;
    }
    this.ran = true;
    await this.runner();
  }
}

class ManualSchedulerPort implements VpnRpcSchedulerPort {
  readonly delays: number[] = [];
  readonly tasks: ScheduledRunner[] = [];
  readonly clock: ManualClockPort;

  constructor(clock: ManualClockPort) {
    this.clock = clock;
  }

  schedule(delayMs: number, runner: () => Promise<void>): ManualTask {
    this.delays.push(delayMs);
    const cancelable: ManualTask = new ManualTask();
    this.tasks.push(new ScheduledRunner(delayMs, this.clock.nowMs() + delayMs, runner, cancelable));
    return cancelable;
  }

  async advanceAndRun(ms: number): Promise<void> {
    this.clock.advanceBy(ms);
    await this.runDue();
  }

  async runDue(): Promise<void> {
    while (true) {
      let nextTask: ScheduledRunner | null = null;
      for (let index: number = 0; index < this.tasks.length; index += 1) {
        const task: ScheduledRunner = this.tasks[index];
        if (task.ran || task.cancelable.canceled || task.dueAt > this.clock.nowMs()) {
          continue;
        }
        if (nextTask === null || task.dueAt < nextTask.dueAt) {
          nextTask = task;
        }
      }
      if (nextTask === null) {
        return;
      }
      await nextTask.run();
    }
  }
}

class TestCryptoPort implements VpnRpcCryptoPort {
  async prepare(): Promise<void> {}

  async rootHmac(input: Uint8Array): Promise<Uint8Array> {
    return this.hash(17, new Uint8Array(0), input);
  }

  async derivedHmac(key: Uint8Array, input: Uint8Array): Promise<Uint8Array> {
    return this.hash(53, key, input);
  }

  private hash(seed: number, key: Uint8Array, input: Uint8Array): Uint8Array {
    const bytes: Uint8Array = new Uint8Array(32);
    let acc: number = seed;
    for (let index: number = 0; index < key.length; index += 1) {
      acc = (acc + key[index] + index + 3) & 0xff;
    }
    for (let index: number = 0; index < input.length; index += 1) {
      acc = (acc + input[index] + index + 11) & 0xff;
    }
    for (let index: number = 0; index < bytes.length; index += 1) {
      const keyByte: number = key.length === 0 ? seed : key[index % key.length];
      const inputByte: number = input.length === 0 ? seed : input[index % input.length];
      acc = (acc + keyByte + inputByte + (index * 13)) & 0xff;
      bytes[index] = acc ^ ((keyByte + inputByte + index) & 0xff);
    }
    return bytes;
  }
}

class BlockingDerivedCryptoPort extends TestCryptoPort {
  private deferredBlocksRemaining: number = 0;
  readonly deferredCalls: DeferredBytes[] = [];

  blockNextDerivedCalls(count: number): void {
    this.deferredBlocksRemaining += count;
  }

  async derivedHmac(key: Uint8Array, input: Uint8Array): Promise<Uint8Array> {
    const result: Uint8Array = await super.derivedHmac(key, input);
    if (this.deferredBlocksRemaining <= 0) {
      return result;
    }
    this.deferredBlocksRemaining -= 1;
    const deferred: DeferredBytes = new DeferredBytes(result);
    this.deferredCalls.push(deferred);
    return await deferred.promise;
  }
}

class ScriptedRandomPort implements VpnRpcRandomPort {
  private readonly chunks: Uint8Array[];

  constructor(chunks: Uint8Array[]) {
    this.chunks = chunks.map((chunk: Uint8Array): Uint8Array => chunk.slice());
  }

  bytes(length: number): Uint8Array {
    const next: Uint8Array | undefined = this.chunks.shift();
    if (next === undefined || next.length !== length) {
      throw new Error('Missing scripted random bytes.');
    }
    return next.slice();
  }
}

class LinkedSocketConnection implements VpnRpcSocketConnectionPort {
  readonly sentFrames: Uint8Array[] = [];
  readonly unsubscribedDataIds: number[] = [];
  readonly unsubscribedCloseIds: number[] = [];
  readonly unsubscribedErrorIds: number[] = [];
  private readonly dataListeners: Map<number, (bytes: Uint8Array) => void> = new Map();
  private readonly closeListeners: Map<number, () => void> = new Map();
  private readonly errorListeners: Map<number, () => void> = new Map();
  private nextId: number = 1;
  private nextSendBlocker: DeferredVoid | null = null;
  peer: LinkedSocketConnection | null = null;
  closeCalls: number = 0;

  async send(bytes: Uint8Array): Promise<void> {
    const blocker: DeferredVoid | null = this.nextSendBlocker;
    this.nextSendBlocker = null;
    if (blocker !== null) {
      await blocker.promise;
    }
    this.sentFrames.push(bytes.slice());
    this.peer?.deliver(bytes.slice());
  }

  blockNextSend(): DeferredVoid {
    const blocker: DeferredVoid = new DeferredVoid();
    this.nextSendBlocker = blocker;
    return blocker;
  }

  subscribeData(listener: (bytes: Uint8Array) => void): number {
    const id: number = this.nextId;
    this.nextId += 1;
    this.dataListeners.set(id, listener);
    return id;
  }

  unsubscribeData(id: number): void {
    this.unsubscribedDataIds.push(id);
    this.dataListeners.delete(id);
  }

  subscribeClose(listener: () => void): number {
    const id: number = this.nextId;
    this.nextId += 1;
    this.closeListeners.set(id, listener);
    return id;
  }

  unsubscribeClose(id: number): void {
    this.unsubscribedCloseIds.push(id);
    this.closeListeners.delete(id);
  }

  subscribeError(listener: () => void): number {
    const id: number = this.nextId;
    this.nextId += 1;
    this.errorListeners.set(id, listener);
    return id;
  }

  unsubscribeError(id: number): void {
    this.unsubscribedErrorIds.push(id);
    this.errorListeners.delete(id);
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
  }

  deliver(bytes: Uint8Array, chunks?: number[]): void {
    const listeners: Array<(bytes: Uint8Array) => void> = Array.from(this.dataListeners.values());
    const slices: Uint8Array[] = splitBytes(bytes, chunks);
    for (let sliceIndex: number = 0; sliceIndex < slices.length; sliceIndex += 1) {
      for (let listenerIndex: number = 0; listenerIndex < listeners.length; listenerIndex += 1) {
        listeners[listenerIndex](slices[sliceIndex].slice());
      }
    }
  }

  signalClose(): void {
    const listeners: Array<() => void> = Array.from(this.closeListeners.values());
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index]();
    }
  }
}

class SocketPair {
  readonly client: LinkedSocketConnection;
  readonly server: LinkedSocketConnection;

  constructor() {
    this.client = new LinkedSocketConnection();
    this.server = new LinkedSocketConnection();
    this.client.peer = this.server;
    this.server.peer = this.client;
  }
}

class TestSocketServer implements VpnRpcSocketServerPort {
  readonly listenCalls: string[] = [];
  readonly pairs: SocketPair[] = [];
  private listener: ((connection: VpnRpcSocketConnectionPort) => void) | null = null;
  closeCalls: number = 0;
  listenFailure: VpnRpcSocketFailure | Error | null = null;

  async listen(address: string, listener: (connection: VpnRpcSocketConnectionPort) => void): Promise<void> {
    this.listenCalls.push(address);
    if (this.listenFailure !== null) {
      if (this.listenFailure instanceof VpnRpcSocketFailure) {
        throw new VpnRpcSocketFailure(this.listenFailure.code);
      }
      throw new Error(this.listenFailure.message);
    }
    this.listener = listener;
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
  }

  accept(): SocketPair {
    if (this.listener === null) {
      throw new Error('Server listener is missing.');
    }
    const pair: SocketPair = new SocketPair();
    this.pairs.push(pair);
    this.listener(pair.server);
    return pair;
  }
}

class ServerBackedSocketFactory implements VpnRpcSocketClientFactoryPort {
  readonly server: TestSocketServer;
  readonly sockets: LinkedSocketConnection[] = [];

  constructor(server: TestSocketServer) {
    this.server = server;
  }

  async connect(_address: string, _timeoutMs: number): Promise<VpnRpcSocketConnectionPort> {
    const pair: SocketPair = this.server.accept();
    this.sockets.push(pair.client);
    return pair.client;
  }
}

class RpcClientPeer {
  readonly clientCrypto: TestCryptoPort;
  readonly clientRandom: ScriptedRandomPort;
  readonly scheduler: FixtureVpnRpcSchedulerPort;
  readonly authenticator: VpnRpcClientAuthenticator;
  readonly preauthFramer: VpnRpcFramer = new VpnRpcFramer();
  readonly businessFramer: VpnRpcFramer = new VpnRpcFramer();
  readonly rawBusinessFrames: VpnRpcDecodedFrame[] = [];
  readonly receivedHellos: Uint8Array[] = [];
  readonly receivedServerAuths: Uint8Array[] = [];
  socket: LinkedSocketConnection | null = null;
  connection: VpnRpcAuthenticatedConnection | null = null;
  assignedClientEpoch: number = 0;
  private sawHello: boolean = false;

  constructor(clientRandomBytes: Uint8Array[]) {
    this.clientCrypto = new TestCryptoPort();
    this.clientRandom = new ScriptedRandomPort(clientRandomBytes);
    this.scheduler = new FixtureVpnRpcSchedulerPort();
    this.authenticator = new VpnRpcClientAuthenticator(this.clientCrypto, this.clientRandom, this.scheduler);
  }

  attach(socket: LinkedSocketConnection): void {
    this.socket = socket;
    socket.subscribeData((bytes: Uint8Array): void => {
      if (this.connection === null) {
        const frames: VpnRpcDecodedFrame[] = this.preauthFramer.push(bytes, false);
        for (let index: number = 0; index < frames.length; index += 1) {
          if (!this.sawHello) {
            this.receivedHellos.push(frames[index].bodyBytes);
            this.sawHello = true;
          } else {
            this.receivedServerAuths.push(frames[index].bodyBytes);
          }
        }
        return;
      }
      const frames: VpnRpcDecodedFrame[] = this.businessFramer.push(bytes, true);
      for (let index: number = 0; index < frames.length; index += 1) {
        this.rawBusinessFrames.push(frames[index]);
      }
    });
  }

  async authenticate(): Promise<void> {
    await waitForCondition((): boolean => this.receivedHellos.length >= 1, 'server hello');
    const helloBodyBytes: Uint8Array | undefined = this.receivedHellos.shift();
    if (helloBodyBytes === undefined) {
      throw new Error('Server hello body is missing.');
    }
    const hello = decodeVpnRpcServerHelloBodyBytes(helloBodyBytes);
    const clientAuth = await this.authenticator.begin(hello);
    await this.requireSocket().send(frameBytes(encodeVpnRpcClientAuthBody(clientAuth), null));
    await waitForCondition((): boolean => this.receivedServerAuths.length >= 1, 'server auth');
    const serverAuthBodyBytes: Uint8Array | undefined = this.receivedServerAuths.shift();
    if (serverAuthBodyBytes === undefined) {
      throw new Error('Server auth body is missing.');
    }
    const serverAuth = decodeVpnRpcServerAuthBodyBytes(serverAuthBodyBytes);
    this.assignedClientEpoch = serverAuth.clientEpoch;
    this.connection = await this.authenticator.acceptServerAuth(serverAuth);
  }

  async sendRequest(
    requestOrdinal: number,
    requestId: string,
    generation: number,
    guards: VpnRpcGuards = createActiveGuards(),
    method: string = 'QUERY_GROUP'
  ): Promise<void> {
    await this.sendCustomRequest(
      requestOrdinal,
      requestId,
      generation,
      guards,
      method as VpnRpcMethod,
      createRequestPayloadForMethod(method)
    );
  }

  async sendCustomRequest(
    requestOrdinal: number,
    requestId: string,
    generation: number,
    guards: VpnRpcGuards,
    method: VpnRpcMethod,
    payload: VpnRpcPayload
  ): Promise<void> {
    const connection: VpnRpcAuthenticatedConnection = this.requireConnection();
    const protectedBody = await connection.encodeOutgoingBody((sequence: number, clientEpoch: number): VpnRpcBody =>
      createVpnRpcBodyRequest(
        sequence,
        clientEpoch,
        requestOrdinal,
        requestId,
        method,
        generation,
        guards,
        payload
      )
    );
    await this.requireSocket().send(frameBytes(protectedBody.bodyBytes, protectedBody.macBytes));
  }

  async buildRequestFrame(
    requestOrdinal: number,
    requestId: string,
    generation: number,
    guards: VpnRpcGuards,
    method: VpnRpcMethod,
    payload: VpnRpcPayload
  ): Promise<Uint8Array> {
    const connection: VpnRpcAuthenticatedConnection = this.requireConnection();
    const protectedBody = await connection.encodeOutgoingBody((sequence: number, clientEpoch: number): VpnRpcBody =>
      createVpnRpcBodyRequest(
        sequence,
        clientEpoch,
        requestOrdinal,
        requestId,
        method,
        generation,
        guards,
        payload
      )
    );
    return frameBytes(protectedBody.bodyBytes, protectedBody.macBytes);
  }

  async decodeNextResponse(): Promise<VpnRpcBody> {
    await waitForCondition((): boolean => this.rawBusinessFrames.length >= 1, 'business response');
    const frame: VpnRpcDecodedFrame | undefined = this.rawBusinessFrames.shift();
    if (frame === undefined || frame.macBytes === null) {
      throw new Error('Business response frame is missing.');
    }
    return await this.requireConnection().decodeIncomingFrame(frame.bodyBytes, frame.macBytes);
  }

  private requireSocket(): LinkedSocketConnection {
    if (this.socket === null) {
      throw new Error('Socket missing.');
    }
    return this.socket;
  }

  private requireConnection(): VpnRpcAuthenticatedConnection {
    if (this.connection === null) {
      throw new Error('Authenticated connection missing.');
    }
    return this.connection;
  }
}

function createServerRandom(sessionIndex: number): Uint8Array[] {
  return [
    sequentialBytes(32, sessionIndex * 0x20 + 0x10),
    sequentialBytes(16, sessionIndex * 0x20 + 0x80)
  ];
}

function sequentialBytes(length: number, seed: number): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(length);
  for (let index: number = 0; index < length; index += 1) {
    bytes[index] = (seed + index) & 0xff;
  }
  return bytes;
}

function frameBytes(bodyBytes: Uint8Array, macBytes: Uint8Array | null): Uint8Array {
  const header: Uint8Array = encodeVpnRpcU32BE(bodyBytes.length);
  const macLength: number = macBytes === null ? 0 : macBytes.length;
  const bytes: Uint8Array = new Uint8Array(header.length + bodyBytes.length + macLength);
  bytes.set(header, 0);
  bytes.set(bodyBytes, header.length);
  if (macBytes !== null) {
    bytes.set(macBytes, header.length + bodyBytes.length);
  }
  return bytes;
}

function splitBytes(bytes: Uint8Array, chunks?: number[]): Uint8Array[] {
  if (chunks === undefined || chunks.length === 0) {
    return [bytes.slice()];
  }
  const slices: Uint8Array[] = [];
  let offset: number = 0;
  for (let index: number = 0; index < chunks.length && offset < bytes.length; index += 1) {
    const nextOffset: number = Math.min(offset + chunks[index], bytes.length);
    slices.push(bytes.slice(offset, nextOffset));
    offset = nextOffset;
  }
  if (offset < bytes.length) {
    slices.push(bytes.slice(offset));
  }
  return slices;
}

function asciiBytes(raw: string): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(raw.length);
  for (let index: number = 0; index < raw.length; index += 1) {
    bytes[index] = raw.charCodeAt(index);
  }
  return bytes;
}

function createActiveGuards(): VpnRpcGuards {
  return createVpnRpcGuards(PROFILE_HASH, REVISION_HASH, CATALOG_DIGEST);
}

function createAlternateGuards(): VpnRpcGuards {
  return createVpnRpcGuards(ALT_PROFILE_HASH, ALT_REVISION_HASH, ALT_CATALOG_DIGEST);
}

function createThirdGuards(): VpnRpcGuards {
  return createVpnRpcGuards(THIRD_PROFILE_HASH, THIRD_REVISION_HASH, THIRD_CATALOG_DIGEST);
}

function createRequestId(ordinal: number): string {
  return `00000000-0000-4000-8000-${`${ordinal}`.padStart(12, '0')}`;
}

function createSuccessFor(request: VpnRpcBody, guards: VpnRpcGuards = request.guards): VpnRpcBody {
  return createVpnRpcBodySuccessResponse(
    1,
    1,
    request.requestOrdinal!,
    request.requestId!,
    request.method,
    request.sessionGeneration,
    guards,
    createSuccessPayloadForMethod(request.method)
  );
}

function createRequestPayloadForMethod(method: string) {
  if (method === 'QUERY_GROUP') {
    return createVpnRpcQueryGroupRequestPayload(GROUP_ID);
  }
  return createVpnRpcEmptyPayload();
}

function createSuccessPayloadForMethod(method: string) {
  if (method === 'PING') {
    return createVpnRpcPingSuccessPayload(SERVER_INSTANCE_HEX);
  }
  if (method === 'QUERY_GROUP') {
    return createVpnRpcQueryGroupPayload(4, GROUP_ID, null, []);
  }
  if (method === 'QUERY_GROUPS') {
    return createVpnRpcQueryGroupsPayload(4, []);
  }
  return createVpnRpcEmptyPayload();
}

function createRuntimeSnapshotPayload() {
  return createVpnRpcRuntimeSnapshotPayload(
    'RUNNING',
    PROFILE_HASH,
    REVISION_HASH,
    CATALOG_DIGEST,
    true,
    0,
    null,
    null,
    0,
    0
  );
}

function createRuntimeSuccessFor(request: VpnRpcBody): VpnRpcBody {
  return createVpnRpcBodySuccessResponse(
    1,
    1,
    request.requestOrdinal!,
    request.requestId!,
    request.method,
    0,
    createVpnRpcGuards(null, null, null),
    createRuntimeSnapshotPayload()
  );
}

function createPingGuards(): VpnRpcGuards {
  return createVpnRpcGuards(null, null, null);
}

async function sendPingRequest(client: RpcClientPeer, ordinal: number): Promise<void> {
  await client.sendCustomRequest(
    ordinal,
    createRequestId(ordinal),
    0,
    createPingGuards(),
    'PING',
    createVpnRpcEmptyPayload()
  );
}

async function sendBadClientAuth(peer: RpcClientPeer, socket: LinkedSocketConnection): Promise<void> {
  await waitForCondition((): boolean => peer.receivedHellos.length >= 1, 'server hello for bad auth');
  const helloBodyBytes: Uint8Array | undefined = peer.receivedHellos.shift();
  if (helloBodyBytes === undefined) {
    throw new Error('Server hello body is missing for bad auth.');
  }
  const hello = decodeVpnRpcServerHelloBodyBytes(helloBodyBytes);
  const clientAuth = await peer.authenticator.begin(hello);
  clientAuth.clientProof = clientAuth.clientProof.endsWith('0')
    ? `${clientAuth.clientProof.slice(0, clientAuth.clientProof.length - 1)}1`
    : `${clientAuth.clientProof.slice(0, clientAuth.clientProof.length - 1)}0`;
  await socket.send(frameBytes(encodeVpnRpcClientAuthBody(clientAuth), null));
}

async function waitForCondition(predicate: () => boolean, label: string, maxTurns: number = 40): Promise<void> {
  for (let index: number = 0; index < maxTurns; index += 1) {
    if (predicate()) {
      return;
    }
    await Promise.resolve();
  }
  throw new Error(`Condition not satisfied: ${label}.`);
}

async function flushAsync(turns: number = 8): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

async function expectFailure<T>(promise: Promise<T>, code: string): Promise<VpnRpcTransportFailure> {
  let failure: VpnRpcTransportFailure | null = null;
  try {
    await promise;
  } catch (error) {
    if (error instanceof VpnRpcTransportFailure) {
      failure = error;
    } else if (error instanceof Error) {
      throw error;
    } else {
      throw new Error('Expected transport failure.');
    }
  }
  expect(failure === null).assertFalse();
  if (failure === null) {
    throw new Error('Expected transport failure.');
  }
  expect(failure.code).assertEqual(code);
  return failure;
}

export default function vpnRpcServerSessionTestsuite() {
  describe('VpnRpcServerSessionTest', () => {
    it('listensAuthenticatesAndDispatchesValidatedRequests', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const requests: VpnRpcBody[] = [];
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          requests.push(request);
          return createSuccessFor(request);
        }
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x40)]);
      client.attach(pair.client);
      await client.authenticate();
      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      const response: VpnRpcBody = await client.decodeNextResponse();

      expect(serverPort.listenCalls.join(',')).assertEqual(SERVER_ADDRESS);
      expect(client.assignedClientEpoch).assertEqual(1);
      expect(requests.length).assertEqual(1);
      expect(requests[0].requestOrdinal).assertEqual(1);
      expect(requests[0].requestId).assertEqual(createRequestId(1));
      expect(requests[0].sessionGeneration).assertEqual(4);
      expect(requests[0].guards.profileHash).assertEqual(PROFILE_HASH);
      expect(response.ok).assertEqual(true);
      expect(response.requestOrdinal).assertEqual(1);
      expect(response.requestId).assertEqual(createRequestId(1));
    });

    it('keepsAuthenticatedActiveClientAliveAcrossBadProofAndTimedOutCandidates', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(new ManualClockPort());
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort([
          ...createServerRandom(1),
          ...createServerRandom(2),
          ...createServerRandom(3),
          ...createServerRandom(4)
        ]),
        scheduler,
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      await session.listen();
      const activePair: SocketPair = serverPort.accept();
      const activeClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x44)]);
      activeClient.attach(activePair.client);
      await activeClient.authenticate();
      await sendPingRequest(activeClient, 1);
      const baselinePing: VpnRpcBody = await activeClient.decodeNextResponse();
      expect(baselinePing.ok).assertTrue();
      expect(activeClient.assignedClientEpoch).assertEqual(1);

      const badProofPair: SocketPair = serverPort.accept();
      const badProofClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x54)]);
      badProofClient.attach(badProofPair.client);
      await sendBadClientAuth(badProofClient, badProofPair.client);
      await waitForCondition((): boolean => badProofPair.server.closeCalls === 1, 'bad proof candidate close');

      await sendPingRequest(activeClient, 2);
      const postBadProofPing: VpnRpcBody = await activeClient.decodeNextResponse();
      const publishedAfterBadProof: boolean = await session.publishEvent(
        'RUNTIME_CHANGED',
        4,
        createActiveGuards(),
        createRuntimeSnapshotPayload()
      );
      const badProofEvent: VpnRpcBody = await activeClient.decodeNextResponse();

      expect(postBadProofPing.ok).assertTrue();
      expect(postBadProofPing.method).assertEqual('PING');
      expect(publishedAfterBadProof).assertTrue();
      expect(badProofEvent.kind).assertEqual('EVENT');
      expect(badProofEvent.method).assertEqual('RUNTIME_CHANGED');
      expect(activePair.server.closeCalls).assertEqual(0);

      const timeoutPair: SocketPair = serverPort.accept();
      const timeoutClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x64)]);
      timeoutClient.attach(timeoutPair.client);
      await waitForCondition((): boolean => timeoutClient.receivedHellos.length >= 1, 'timed candidate hello');
      await scheduler.advanceAndRun(3000);
      await flushAsync(12);
      await waitForCondition((): boolean => timeoutPair.server.closeCalls === 1, 'timed candidate close');

      await sendPingRequest(activeClient, 3);
      const postTimeoutPing: VpnRpcBody = await activeClient.decodeNextResponse();
      const publishedAfterTimeout: boolean = await session.publishEvent(
        'RUNTIME_CHANGED',
        4,
        createActiveGuards(),
        createRuntimeSnapshotPayload()
      );
      const timeoutEvent: VpnRpcBody = await activeClient.decodeNextResponse();

      expect(postTimeoutPing.ok).assertTrue();
      expect(publishedAfterTimeout).assertTrue();
      expect(timeoutEvent.kind).assertEqual('EVENT');
      expect(timeoutEvent.method).assertEqual('RUNTIME_CHANGED');
      expect(activeClient.assignedClientEpoch).assertEqual(1);

      const promotedPair: SocketPair = serverPort.accept();
      const promotedClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x74)]);
      promotedClient.attach(promotedPair.client);
      await promotedClient.authenticate();

      expect(promotedClient.assignedClientEpoch).assertEqual(2);
      expect(activePair.server.closeCalls).assertEqual(1);
    });

    it('replacesOnlyPreviousUnauthenticatedCandidateAndKeepsActiveHealthy', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort([
          ...createServerRandom(1),
          ...createServerRandom(2),
          ...createServerRandom(3),
          ...createServerRandom(4)
        ]),
        new ManualSchedulerPort(new ManualClockPort()),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      await session.listen();
      const activePair: SocketPair = serverPort.accept();
      const activeClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x46)]);
      activeClient.attach(activePair.client);
      await activeClient.authenticate();

      const rogue1: SocketPair = serverPort.accept();
      const rogueClient1: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x56)]);
      rogueClient1.attach(rogue1.client);
      await waitForCondition((): boolean => rogueClient1.receivedHellos.length >= 1, 'rogue1 hello');

      const rogue2: SocketPair = serverPort.accept();
      const rogueClient2: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x66)]);
      rogueClient2.attach(rogue2.client);
      await waitForCondition((): boolean => rogue1.server.closeCalls === 1, 'rogue1 replaced close');
      await waitForCondition((): boolean => rogueClient2.receivedHellos.length >= 1, 'rogue2 hello');

      const rogue3: SocketPair = serverPort.accept();
      const rogueClient3: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x76)]);
      rogueClient3.attach(rogue3.client);
      await waitForCondition((): boolean => rogue2.server.closeCalls === 1, 'rogue2 replaced close');
      await waitForCondition((): boolean => rogueClient3.receivedHellos.length >= 1, 'rogue3 hello');

      await sendPingRequest(activeClient, 1);
      const activePing: VpnRpcBody = await activeClient.decodeNextResponse();
      const published: boolean = await session.publishEvent(
        'RUNTIME_CHANGED',
        4,
        createActiveGuards(),
        createRuntimeSnapshotPayload()
      );
      const activeEvent: VpnRpcBody = await activeClient.decodeNextResponse();

      expect(activePing.ok).assertTrue();
      expect(published).assertTrue();
      expect(activeEvent.method).assertEqual('RUNTIME_CHANGED');
      expect(activePair.server.closeCalls).assertEqual(0);
      expect(rogue1.server.closeCalls).assertEqual(1);
      expect(rogue2.server.closeCalls).assertEqual(1);
      expect(rogue3.server.closeCalls).assertEqual(0);
    });

    it('replacesOldClientAllocatesFreshEpochsAndIgnoresStaleCallbacks', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const firstResponse: DeferredBody = new DeferredBody();
      const handled: string[] = [];
      let holdFirstResponse: boolean = true;
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort([
          ...createServerRandom(1),
          ...createServerRandom(2)
        ]),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          handled.push(`${request.requestOrdinal}:${request.requestId}`);
          if (holdFirstResponse) {
            holdFirstResponse = false;
            return await firstResponse.promise;
          }
          return createSuccessFor(request, createAlternateGuards());
        }
      );

      await session.listen();
      const firstPair: SocketPair = serverPort.accept();
      const firstClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x50)]);
      firstClient.attach(firstPair.client);
      await firstClient.authenticate();
      await firstClient.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      const firstResponseFramesBefore: number = firstPair.server.sentFrames.length;

      const secondPair: SocketPair = serverPort.accept();
      const secondClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x70)]);
      secondClient.attach(secondPair.client);
      await secondClient.authenticate();

      firstResponse.resolve(createSuccessFor(createVpnRpcBodyRequest(
        1,
        1,
        1,
        createRequestId(1),
        'QUERY_GROUP',
        4,
        createActiveGuards(),
        createVpnRpcQueryGroupRequestPayload(GROUP_ID)
      )));
      await Promise.resolve();

      firstPair.server.deliver(firstPair.client.sentFrames[firstPair.client.sentFrames.length - 1]);
      await Promise.resolve();
      await secondClient.sendRequest(1, createRequestId(1), 5, createAlternateGuards());
      const secondResponse: VpnRpcBody = await secondClient.decodeNextResponse();

      expect(firstClient.assignedClientEpoch).assertEqual(1);
      expect(secondClient.assignedClientEpoch).assertEqual(2);
      expect(firstPair.server.closeCalls).assertEqual(1);
      expect(firstPair.server.sentFrames.length).assertEqual(firstResponseFramesBefore);
      expect(secondResponse.ok).assertEqual(true);
    });

    it('promotesOnlyLatestValidatedCandidateAndIgnoresStaleAsyncAuthCompletion', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort([
          ...createServerRandom(1),
          ...createServerRandom(2),
          ...createServerRandom(3)
        ]),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      await session.listen();
      const activePair: SocketPair = serverPort.accept();
      const activeClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x48)]);
      activeClient.attach(activePair.client);
      await activeClient.authenticate();

      const blockedCandidatePair: SocketPair = serverPort.accept();
      const blockedCandidate: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x58)]);
      blockedCandidate.attach(blockedCandidatePair.client);
      await waitForCondition((): boolean => blockedCandidate.receivedHellos.length >= 1, 'blocked candidate hello');
      const blockedServerAuthSend: DeferredVoid = blockedCandidatePair.server.blockNextSend();
      const blockedCandidateAuth: Promise<void> = blockedCandidate.authenticate();
      await flushAsync(12);
      expect(blockedCandidate.receivedServerAuths.length).assertEqual(0);

      const promotedPair: SocketPair = serverPort.accept();
      const promotedClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x68)]);
      promotedClient.attach(promotedPair.client);
      await waitForCondition((): boolean => blockedCandidatePair.server.closeCalls === 1, 'blocked candidate replaced');
      await promotedClient.authenticate();

      expect(promotedClient.assignedClientEpoch).assertEqual(2);
      expect(activePair.server.closeCalls).assertEqual(1);
      expect(blockedCandidate.receivedServerAuths.length).assertEqual(0);

      blockedServerAuthSend.resolve();
      let blockedCandidateFailure: Error | null = null;
      try {
        await blockedCandidateAuth;
      } catch (error) {
        if (error instanceof Error) {
          blockedCandidateFailure = error;
        } else {
          throw new Error('Blocked candidate failure missing.');
        }
      }
      await flushAsync(12);

      await sendPingRequest(promotedClient, 1);
      const promotedPing: VpnRpcBody = await promotedClient.decodeNextResponse();

      expect(blockedCandidateFailure === null).assertFalse();
      if (blockedCandidateFailure !== null) {
        expect(blockedCandidateFailure.message.includes('server auth')).assertTrue();
      }
      expect(promotedPing.ok).assertTrue();
      expect(blockedCandidatePair.server.closeCalls).assertEqual(1);
      expect(promotedPair.server.closeCalls).assertEqual(0);
    });

    it('failClosesOnInvalidPreauthBodyAndOrdinalGap', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort([
          ...createServerRandom(1),
          ...createServerRandom(2)
        ]),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      await session.listen();
      const badPreauthPair: SocketPair = serverPort.accept();
      badPreauthPair.server.deliver(frameBytes(asciiBytes('{}'), null));
      await waitForCondition((): boolean => badPreauthPair.server.closeCalls === 1, 'bad preauth close');

      const gapPair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x90)]);
      client.attach(gapPair.client);
      await client.authenticate();
      await client.sendRequest(2, createRequestId(2), 4, createActiveGuards());
      await waitForCondition((): boolean => gapPair.server.closeCalls === 1, 'ordinal gap close');
    });

    it('replaysCachedResponseBytesForCompletedRetry', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      let dispatchCount: number = 0;
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          dispatchCount += 1;
          return createSuccessFor(request);
        }
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xa0)]);
      client.attach(pair.client);
      await client.authenticate();
      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      await waitForCondition((): boolean => pair.server.sentFrames.length >= 3, 'first response frame');
      const firstResponseFrame: Uint8Array = pair.server.sentFrames[pair.server.sentFrames.length - 1].slice();

      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      await waitForCondition((): boolean => pair.server.sentFrames.length >= 4, 'duplicate response frame');
      const secondResponseFrame: Uint8Array = pair.server.sentFrames[pair.server.sentFrames.length - 1].slice();

      expect(dispatchCount).assertEqual(1);
      expect(bytesEqual(firstResponseFrame, secondResponseFrame)).assertTrue();
    });

    it('coalescesInFlightRetryForRealClientWithoutDisconnecting', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const clientClock: ManualClockPort = new ManualClockPort();
      const clientScheduler: ManualSchedulerPort = new ManualSchedulerPort(clientClock);
      const responseDeferred: DeferredBody = new DeferredBody();
      let observedQuery: VpnRpcBody | null = null;
      let queryDispatchCount: number = 0;
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          if (request.method === 'GET_SNAPSHOT') {
            return createRuntimeSuccessFor(request);
          }
          queryDispatchCount += 1;
          if (queryDispatchCount === 1) {
            observedQuery = request;
            return await responseDeferred.promise;
          }
          return createSuccessFor(request);
        }
      );
      await session.listen();
      const client = new BarrelVpnRpcClient(
        new TestCryptoPort(),
        new ScriptedRandomPort([
          sequentialBytes(32, 0x21),
          sequentialBytes(16, 0x31),
          sequentialBytes(16, 0x41),
          sequentialBytes(16, 0x51)
        ]),
        clientScheduler,
        clientClock,
        new ServerBackedSocketFactory(serverPort)
      );

      await client.connect();
      const requestPromise: Promise<VpnRpcBody> = client.request(
        'QUERY_GROUP',
        createActiveGuards(),
        4,
        createVpnRpcQueryGroupRequestPayload(GROUP_ID)
      );
      await flushAsync();
      await clientScheduler.advanceAndRun(250);
      await flushAsync();
      if (observedQuery === null) {
        throw new Error('Observed client query is missing.');
      }
      responseDeferred.resolve(createSuccessFor(observedQuery));
      const firstResponse: VpnRpcBody = await requestPromise;
      await flushAsync();

      expect(firstResponse.ok).assertEqual(true);
      expect(client.state()).assertEqual('READY');
      expect(queryDispatchCount).assertEqual(1);

      const secondResponse: VpnRpcBody = await client.request(
        'QUERY_GROUP',
        createActiveGuards(),
        4,
        createVpnRpcQueryGroupRequestPayload(GROUP_ID)
      );
      expect(secondResponse.ok).assertEqual(true);
      expect(client.state()).assertEqual('READY');
    });

    it('keepsRequestInFlightUntilFirstResponseSendCompletes', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const clientClock: ManualClockPort = new ManualClockPort();
      const clientScheduler: ManualSchedulerPort = new ManualSchedulerPort(clientClock);
      let queryDispatchCount: number = 0;
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          if (request.method === 'GET_SNAPSHOT') {
            return createRuntimeSuccessFor(request);
          }
          queryDispatchCount += 1;
          return createSuccessFor(request);
        }
      );
      await session.listen();
      const factory: ServerBackedSocketFactory = new ServerBackedSocketFactory(serverPort);
      const client = new BarrelVpnRpcClient(
        new TestCryptoPort(),
        new ScriptedRandomPort([
          sequentialBytes(32, 0x22),
          sequentialBytes(16, 0x32),
          sequentialBytes(16, 0x42),
          sequentialBytes(16, 0x52)
        ]),
        clientScheduler,
        clientClock,
        factory
      );

      await client.connect();
      const pair: SocketPair = serverPort.pairs[0];
      const blockedSend: DeferredVoid = pair.server.blockNextSend();
      const baselineServerSends: number = pair.server.sentFrames.length;
      const baselineClientSends: number = pair.client.sentFrames.length;

      const requestPromise: Promise<VpnRpcBody> = client.request(
        'QUERY_GROUP',
        createActiveGuards(),
        4,
        createVpnRpcQueryGroupRequestPayload(GROUP_ID)
      );
      await waitForCondition((): boolean => queryDispatchCount === 1, 'query dispatch');
      await flushAsync();
      await clientScheduler.advanceAndRun(250);
      await flushAsync();
      await waitForCondition((): boolean => pair.client.sentFrames.length >= baselineClientSends + 2, 'retry sent');

      expect(queryDispatchCount).assertEqual(1);
      expect(pair.server.sentFrames.length).assertEqual(baselineServerSends);

      blockedSend.resolve();
      const response: VpnRpcBody = await requestPromise;
      await flushAsync();

      expect(pair.server.sentFrames.length).assertEqual(baselineServerSends + 1);
      expect(response.ok).assertEqual(true);
      expect(client.state()).assertEqual('READY');

      const nextResponse: VpnRpcBody = await client.request(
        'QUERY_GROUP',
        createActiveGuards(),
        4,
        createVpnRpcQueryGroupRequestPayload(GROUP_ID)
      );
      expect(nextResponse.ok).assertEqual(true);
      expect(client.state()).assertEqual('READY');
    });

    it('closesOnSameOrdinalWithDifferentRequestId', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      let dispatchCount: number = 0;
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          dispatchCount += 1;
          return createSuccessFor(request);
        }
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xb0)]);
      client.attach(pair.client);
      await client.authenticate();
      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      await client.decodeNextResponse();
      await client.sendRequest(1, createRequestId(999), 4, createActiveGuards());
      await waitForCondition((): boolean => pair.server.closeCalls === 1, 'different request id close');

      expect(dispatchCount).assertEqual(1);
      expect(pair.server.closeCalls).assertEqual(1);
    });

    it('evictsOldestCachedResponseAt257AndReturnsReplayExpiredWithoutRedispatch', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      let dispatchCount: number = 0;
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          dispatchCount += 1;
          return createSuccessFor(request);
        }
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xc0)]);
      client.attach(pair.client);
      await client.authenticate();
      for (let ordinal: number = 1; ordinal <= 257; ordinal += 1) {
        await client.sendRequest(ordinal, createRequestId(ordinal), 4, createActiveGuards());
        await client.decodeNextResponse();
      }

      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      const replayExpired: VpnRpcBody = await client.decodeNextResponse();

      expect(dispatchCount).assertEqual(257);
      expect(replayExpired.ok).assertEqual(false);
      expect(replayExpired.error?.code ?? '').assertEqual('REQUEST_REPLAY_EXPIRED');
      expect(replayExpired.error?.retryable ?? true).assertFalse();
    });

    it('doesNotDispatchInFlightDuplicateTwice', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const deferred: DeferredBody = new DeferredBody();
      let dispatchCount: number = 0;
      let observedRequest: VpnRpcBody | null = null;
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          dispatchCount += 1;
          observedRequest = request;
          return await deferred.promise;
        }
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xd0)]);
      client.attach(pair.client);
      await client.authenticate();
      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      await Promise.resolve();
      if (observedRequest === null) {
        throw new Error('Observed request is missing.');
      }
      deferred.resolve(createSuccessFor(observedRequest));
      await waitForCondition((): boolean => pair.server.sentFrames.length >= 3, 'single in-flight reply');
      expect(dispatchCount).assertEqual(1);
      expect(pair.server.sentFrames.length).assertEqual(3);
    });

    it('failClosesBurstBeyondInboundQueueBudgetBeforeDrainAndKeepsReplacementHealthy', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const serverCrypto: BlockingDerivedCryptoPort = new BlockingDerivedCryptoPort();
      let dispatchCount: number = 0;
      const session = new BarrelVpnRpcServerSession(
        serverCrypto,
        new ScriptedRandomPort([
          ...createServerRandom(1),
          ...createServerRandom(2)
        ]),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          dispatchCount += 1;
          return createSuccessFor(request);
        }
      );

      await session.listen();
      const firstPair: SocketPair = serverPort.accept();
      const firstClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x61)]);
      firstClient.attach(firstPair.client);
      await firstClient.authenticate();
      serverCrypto.blockNextDerivedCalls(1);

      const firstFrame: Uint8Array = await firstClient.buildRequestFrame(
        1,
        createRequestId(1),
        4,
        createActiveGuards(),
        'QUERY_GROUP',
        createVpnRpcQueryGroupRequestPayload(GROUP_ID)
      );
      firstPair.server.deliver(firstFrame);
      for (let ordinal: number = 2; ordinal <= 65; ordinal += 1) {
        const requestFrame: Uint8Array = await firstClient.buildRequestFrame(
          ordinal,
          createRequestId(ordinal),
          4,
          createActiveGuards(),
          'QUERY_GROUP',
          createVpnRpcQueryGroupRequestPayload(GROUP_ID)
        );
        firstPair.server.deliver(requestFrame);
      }
      await waitForCondition((): boolean => firstPair.server.closeCalls === 1, 'burst overflow close');

      const staleSentCount: number = firstPair.server.sentFrames.length;
      if (serverCrypto.deferredCalls.length === 0) {
        throw new Error('Blocked derived call is missing.');
      }
      serverCrypto.deferredCalls[0].resolve();
      await flushAsync();

      expect(dispatchCount).assertEqual(0);
      expect(firstPair.server.sentFrames.length).assertEqual(staleSentCount);

      const secondPair: SocketPair = serverPort.accept();
      const secondClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x81)]);
      secondClient.attach(secondPair.client);
      await secondClient.authenticate();
      await secondClient.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      const secondResponse: VpnRpcBody = await secondClient.decodeNextResponse();
      expect(secondResponse.ok).assertEqual(true);
    });

    it('returnsReplayExpiredForEvictedOrdinalEvenWithDifferentRequestIdAfterLargeHistory', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      let dispatchCount: number = 0;
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          dispatchCount += 1;
          return createSuccessFor(request);
        }
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0x91)]);
      client.attach(pair.client);
      await client.authenticate();
      for (let ordinal: number = 1; ordinal <= 10000; ordinal += 1) {
        await client.sendRequest(ordinal, createRequestId(ordinal), 4, createActiveGuards());
        await client.decodeNextResponse();
      }

      await client.sendRequest(1, createRequestId(10001), 4, createActiveGuards());
      const expiredResponse: VpnRpcBody = await client.decodeNextResponse();

      expect(expiredResponse.ok).assertEqual(false);
      expect(expiredResponse.error?.code ?? '').assertEqual('REQUEST_REPLAY_EXPIRED');
      expect(pair.server.closeCalls).assertEqual(0);
      expect(dispatchCount).assertEqual(10000);
    });

    it('rejectsSixtyFifthConcurrentNewRequestWithCommandBusy', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const deferred: DeferredBody = new DeferredBody();
      let dispatchCount: number = 0;
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          dispatchCount += 1;
          return await deferred.promise;
        }
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xa1)]);
      client.attach(pair.client);
      await client.authenticate();

      for (let ordinal: number = 1; ordinal <= 65; ordinal += 1) {
        await client.sendRequest(ordinal, createRequestId(ordinal), 4, createActiveGuards());
      }
      await waitForCondition((): boolean => pair.server.sentFrames.length >= 3, 'sixty fifth response', 1200);
      const busyResponse: VpnRpcBody = await client.decodeNextResponse();

      expect(busyResponse.ok).assertEqual(false);
      expect(busyResponse.error?.code ?? '').assertEqual('COMMAND_BUSY');
      expect(dispatchCount).assertEqual(64);
    });

    it('failClosesWhenDuplicateFingerprintChangesAcrossMethodGenerationGuardsOrPayload', 0, async () => {
      const server1: TestSocketServer = new TestSocketServer();
      const session1 = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        server1,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );
      await session1.listen();
      const pair1: SocketPair = server1.accept();
      const client1: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xb1)]);
      client1.attach(pair1.client);
      await client1.authenticate();
      await client1.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      await client1.sendCustomRequest(
        1,
        createRequestId(1),
        4,
        createActiveGuards(),
        'QUERY_GROUPS',
        createVpnRpcEmptyPayload()
      );
      await waitForCondition((): boolean => pair1.server.closeCalls === 1, 'method mismatch close');

      const session2Server: TestSocketServer = new TestSocketServer();
      const deferred2: DeferredBody = new DeferredBody();
      let request2: VpnRpcBody | null = null;
      const session2 = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(2)),
        new FixtureVpnRpcSchedulerPort(),
        session2Server,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          request2 = request;
          return await deferred2.promise;
        }
      );
      await session2.listen();
      const pair2: SocketPair = session2Server.accept();
      const client2: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xc1)]);
      client2.attach(pair2.client);
      await client2.authenticate();
      await client2.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      await client2.sendCustomRequest(
        1,
        createRequestId(1),
        5,
        createAlternateGuards(),
        'QUERY_GROUP',
        createVpnRpcQueryGroupRequestPayload(GROUP_ID)
      );
      await waitForCondition((): boolean => pair2.server.closeCalls === 1, 'generation guards mismatch close');
      const pair2SentBeforeResolve: number = pair2.server.sentFrames.length;
      if (request2 === null) {
        throw new Error('Second request body is missing.');
      }
      deferred2.resolve(createSuccessFor(request2));
      await flushAsync();
      expect(pair2.server.sentFrames.length).assertEqual(pair2SentBeforeResolve);

      const session3Server: TestSocketServer = new TestSocketServer();
      const session3 = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(3)),
        new FixtureVpnRpcSchedulerPort(),
        session3Server,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );
      await session3.listen();
      const pair3: SocketPair = session3Server.accept();
      const client3: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xd1)]);
      client3.attach(pair3.client);
      await client3.authenticate();
      await client3.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      await client3.sendCustomRequest(
        1,
        createRequestId(1),
        4,
        createActiveGuards(),
        'QUERY_GROUP',
        createVpnRpcQueryGroupRequestPayload(ALT_PROFILE_HASH)
      );
      await waitForCondition((): boolean => pair3.server.closeCalls === 1, 'payload mismatch close');
    });

    it('publishesBusinessEventsOnlyForLiveAuthenticatedClients', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      await session.listen();
      const unpublishedBeforeClient: boolean = await session.publishEvent(
        'RUNTIME_CHANGED',
        4,
        createActiveGuards(),
        createRuntimeSnapshotPayload()
      );
      expect(unpublishedBeforeClient).assertFalse();

      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xdf)]);
      client.attach(pair.client);
      await client.authenticate();

      const publishRuntime: boolean = await session.publishEvent(
        'RUNTIME_CHANGED',
        4,
        createActiveGuards(),
        createRuntimeSnapshotPayload()
      );
      const runtimeEvent: VpnRpcBody = await client.decodeNextResponse();

      expect(publishRuntime).assertTrue();
      expect(runtimeEvent.kind).assertEqual('EVENT');
      expect(runtimeEvent.method).assertEqual('RUNTIME_CHANGED');
      expect(runtimeEvent.sessionGeneration).assertEqual(4);
      expect(runtimeEvent.guards.profileHash).assertEqual(PROFILE_HASH);

      const sentFrameCountBeforeRejectedEvent: number = pair.server.sentFrames.length;
      const rejectedStoppingPublish: boolean = await session.publishEvent(
        'SERVER_STOPPING',
        4,
        createActiveGuards(),
        createVpnRpcEmptyPayload()
      );

      expect(rejectedStoppingPublish).assertFalse();
      expect(pair.server.sentFrames.length).assertEqual(sentFrameCountBeforeRejectedEvent);

      await session.close();
      await client.decodeNextResponse();

      const unpublishedAfterClose: boolean = await session.publishEvent(
        'DELAY_CHANGED',
        4,
        createActiveGuards(),
        createRuntimeSnapshotPayload()
      );
      expect(unpublishedAfterClose).assertFalse();
    });

    it('capturesCallerOwnedEventInputsBeforeAwaitingOutboundSend', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xde)]);
      client.attach(pair.client);
      await client.authenticate();

      const blockedSend: DeferredVoid = pair.server.blockNextSend();
      const guards: VpnRpcGuards = createActiveGuards();
      const payload = createRuntimeSnapshotPayload();
      const publishPromise: Promise<boolean> = session.publishEvent('RUNTIME_CHANGED', 4, guards, payload);

      guards.profileHash = ALT_PROFILE_HASH;
      guards.revisionHash = ALT_REVISION_HASH;
      guards.catalogDigest = ALT_CATALOG_DIGEST;
      payload.profileHash = ALT_PROFILE_HASH;
      payload.revisionHash = ALT_REVISION_HASH;
      payload.catalogDigest = ALT_CATALOG_DIGEST;
      payload.recoveryAttempt = 7;

      blockedSend.resolve();
      const published: boolean = await publishPromise;
      const event: VpnRpcBody = await client.decodeNextResponse();

      expect(published).assertTrue();
      expect(event.guards.profileHash).assertEqual(PROFILE_HASH);
      expect(event.guards.revisionHash).assertEqual(REVISION_HASH);
      expect(event.guards.catalogDigest).assertEqual(CATALOG_DIGEST);
      expect(encodeVpnRpcBodyToText(event.payload).includes(ALT_PROFILE_HASH)).assertFalse();
      expect(encodeVpnRpcBodyToText(event.payload).includes('"recoveryAttempt":7')).assertFalse();

      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      const response: VpnRpcBody = await client.decodeNextResponse();
      expect(response.ok).assertTrue();
      expect(pair.server.closeCalls).assertEqual(0);
    });

    it('serializesFreshResponsesAndPublishedEventsThroughOneOutboundGate', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      let dispatchCount: number = 0;
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          dispatchCount += 1;
          return createSuccessFor(request);
        }
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xe4)]);
      client.attach(pair.client);
      await client.authenticate();

      const blockedSend: DeferredVoid = pair.server.blockNextSend();
      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      await waitForCondition((): boolean => dispatchCount === 1, 'first dispatch');

      const publishPromise: Promise<boolean> = session.publishEvent(
        'RUNTIME_CHANGED',
        4,
        createActiveGuards(),
        createRuntimeSnapshotPayload()
      );
      await client.sendRequest(2, createRequestId(2), 4, createActiveGuards());
      await waitForCondition((): boolean => dispatchCount === 2, 'second dispatch');
      await flushAsync();

      expect(client.rawBusinessFrames.length).assertEqual(0);

      blockedSend.resolve();
      const publishResult: boolean = await publishPromise;
      const firstResponse: VpnRpcBody = await client.decodeNextResponse();
      const runtimeEvent: VpnRpcBody = await client.decodeNextResponse();
      const secondResponse: VpnRpcBody = await client.decodeNextResponse();

      expect(publishResult).assertTrue();
      expect(firstResponse.kind).assertEqual('RESPONSE');
      expect(firstResponse.sequence).assertEqual(1);
      expect(runtimeEvent.kind).assertEqual('EVENT');
      expect(runtimeEvent.method).assertEqual('RUNTIME_CHANGED');
      expect(runtimeEvent.sequence).assertEqual(2);
      expect(secondResponse.kind).assertEqual('RESPONSE');
      expect(secondResponse.sequence).assertEqual(3);
    });

    it('serializesCachedReplayAndPublishedEventsThroughOneOutboundGate', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      let dispatchCount: number = 0;
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          dispatchCount += 1;
          return createSuccessFor(request);
        }
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xe5)]);
      client.attach(pair.client);
      await client.authenticate();

      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      const firstResponse: VpnRpcBody = await client.decodeNextResponse();
      const firstResponseFrame: Uint8Array = pair.server.sentFrames[pair.server.sentFrames.length - 1].slice();
      expect(firstResponse.sequence).assertEqual(1);

      const blockedSend: DeferredVoid = pair.server.blockNextSend();
      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      await flushAsync();

      const publishPromise: Promise<boolean> = session.publishEvent(
        'RUNTIME_CHANGED',
        4,
        createActiveGuards(),
        createRuntimeSnapshotPayload()
      );
      await flushAsync();

      expect(client.rawBusinessFrames.length).assertEqual(0);

      blockedSend.resolve();
      const publishResult: boolean = await publishPromise;
      await waitForCondition((): boolean => client.rawBusinessFrames.length >= 2, 'cached replay plus event');
      const replayedFrame: VpnRpcDecodedFrame | undefined = client.rawBusinessFrames.shift();
      if (replayedFrame === undefined || replayedFrame.macBytes === null) {
        throw new Error('Replayed response frame is missing.');
      }
      const runtimeEvent: VpnRpcBody = await client.decodeNextResponse();

      expect(publishResult).assertTrue();
      expect(dispatchCount).assertEqual(1);
      expect(bytesEqual(frameBytes(replayedFrame.bodyBytes, replayedFrame.macBytes), firstResponseFrame)).assertTrue();
      expect(runtimeEvent.kind).assertEqual('EVENT');
      expect(runtimeEvent.method).assertEqual('RUNTIME_CHANGED');
      expect(runtimeEvent.sequence).assertEqual(2);
    });

    it('boundsQueuedBusinessEventsWithoutFailClosingTheSession', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xe6)]);
      client.attach(pair.client);
      await client.authenticate();

      const blockedSend: DeferredVoid = pair.server.blockNextSend();
      const acceptedPublishes: Promise<boolean>[] = [];
      for (let index: number = 0; index < 64; index += 1) {
        acceptedPublishes.push(
          session.publishEvent('RUNTIME_CHANGED', 4, createActiveGuards(), createRuntimeSnapshotPayload())
        );
      }

      let overflowResolved: boolean = false;
      let overflowValue: boolean = true;
      const overflowPublish: Promise<void> = session.publishEvent(
        'RUNTIME_CHANGED',
        4,
        createActiveGuards(),
        createRuntimeSnapshotPayload()
      ).then((value: boolean): void => {
        overflowResolved = true;
        overflowValue = value;
      });

      await flushAsync(12);
      expect(overflowResolved).assertTrue();
      expect(overflowValue).assertFalse();

      blockedSend.resolve();
      const acceptedResults: boolean[] = await Promise.all(acceptedPublishes);
      await overflowPublish;
      for (let index: number = 0; index < acceptedResults.length; index += 1) {
        expect(acceptedResults[index]).assertTrue();
      }
      for (let index: number = 0; index < acceptedResults.length; index += 1) {
        const event: VpnRpcBody = await client.decodeNextResponse();
        expect(event.kind).assertEqual('EVENT');
      }

      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      const response: VpnRpcBody = await client.decodeNextResponse();
      expect(response.ok).assertTrue();
      expect(pair.server.closeCalls).assertEqual(0);
    });

    it('sendsServerStoppingEventDuringShutdown', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xe0)]);
      client.attach(pair.client);
      await client.authenticate();
      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      await client.decodeNextResponse();

      await session.close();
      const stoppingEvent: VpnRpcBody = await client.decodeNextResponse();

      expect(stoppingEvent.kind).assertEqual('EVENT');
      expect(stoppingEvent.method).assertEqual('SERVER_STOPPING');
      expect(stoppingEvent.sessionGeneration).assertEqual(4);
      expect(stoppingEvent.guards.profileHash).assertEqual(PROFILE_HASH);
      expect(pair.server.closeCalls).assertEqual(1);
    });

    it('keepsAuthoritativeContextAcrossCommandBusyAndShutdown', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const deferred: DeferredBody = new DeferredBody();
      let dispatchCount: number = 0;
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => {
          dispatchCount += 1;
          if (dispatchCount === 1) {
            return createSuccessFor(request);
          }
          return await deferred.promise;
        }
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xe1)]);
      client.attach(pair.client);
      await client.authenticate();

      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      const acceptedResponse: VpnRpcBody = await client.decodeNextResponse();
      expect(acceptedResponse.ok).assertEqual(true);

      for (let ordinal: number = 2; ordinal <= 65; ordinal += 1) {
        await client.sendRequest(ordinal, createRequestId(ordinal), 4, createActiveGuards());
      }
      await client.sendRequest(66, createRequestId(66), 5, createAlternateGuards());
      await waitForCondition((): boolean => client.rawBusinessFrames.length >= 1, 'busy response frame', 1200);
      const busyResponse: VpnRpcBody = await client.decodeNextResponse();
      expect(busyResponse.ok).assertEqual(false);
      expect(busyResponse.error?.code ?? '').assertEqual('COMMAND_BUSY');
      expect(dispatchCount).assertEqual(65);

      await session.close();
      const stoppingEvent: VpnRpcBody = await client.decodeNextResponse();
      expect(stoppingEvent.method).assertEqual('SERVER_STOPPING');
      expect(stoppingEvent.sessionGeneration).assertEqual(4);
      expect(stoppingEvent.guards.profileHash).assertEqual(PROFILE_HASH);
      expect(stoppingEvent.guards.revisionHash).assertEqual(REVISION_HASH);
      expect(stoppingEvent.guards.catalogDigest).assertEqual(CATALOG_DIGEST);
    });

    it('keepsLastAcceptedContextAcrossReplayExpiredAndShutdown', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xe2)]);
      client.attach(pair.client);
      await client.authenticate();

      await client.sendRequest(1, createRequestId(1), 4, createActiveGuards());
      await client.decodeNextResponse();
      for (let ordinal: number = 2; ordinal <= 257; ordinal += 1) {
        await client.sendRequest(ordinal, createRequestId(ordinal), 5, createAlternateGuards());
        await client.decodeNextResponse();
      }

      await client.sendRequest(1, createRequestId(1), 6, createThirdGuards());
      const replayExpired: VpnRpcBody = await client.decodeNextResponse();
      expect(replayExpired.ok).assertEqual(false);
      expect(replayExpired.error?.code ?? '').assertEqual('REQUEST_REPLAY_EXPIRED');

      await session.close();
      const stoppingEvent: VpnRpcBody = await client.decodeNextResponse();
      expect(stoppingEvent.method).assertEqual('SERVER_STOPPING');
      expect(stoppingEvent.sessionGeneration).assertEqual(5);
      expect(stoppingEvent.guards.profileHash).assertEqual(ALT_PROFILE_HASH);
      expect(stoppingEvent.guards.revisionHash).assertEqual(ALT_REVISION_HASH);
      expect(stoppingEvent.guards.catalogDigest).assertEqual(ALT_CATALOG_DIGEST);
    });

    it('usesZeroAndNullGuardsForShutdownWithoutAcceptedWork', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xe3)]);
      client.attach(pair.client);
      await client.authenticate();

      await session.close();
      const stoppingEvent: VpnRpcBody = await client.decodeNextResponse();
      expect(stoppingEvent.method).assertEqual('SERVER_STOPPING');
      expect(stoppingEvent.sessionGeneration).assertEqual(0);
      expect(stoppingEvent.guards.profileHash === null).assertTrue();
      expect(stoppingEvent.guards.revisionHash === null).assertTrue();
      expect(stoppingEvent.guards.catalogDigest === null).assertTrue();
    });

    it('normalizesAddressInUseAndClosesServerOnce', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      serverPort.listenFailure = new VpnRpcSocketFailure('ADDRESS_IN_USE');
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        new FixtureVpnRpcSchedulerPort(),
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      const failure: VpnRpcTransportFailure = await expectFailure<void>(session.listen(), 'RPC_UNAVAILABLE');

      expect(failure.retryable).assertTrue();
      expect(serverPort.closeCalls).assertEqual(1);
    });

    it('keepsCleanupExactlyOnceAcrossIdempotentClose', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const scheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort(createServerRandom(1)),
        scheduler,
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      await session.listen();
      const pair: SocketPair = serverPort.accept();
      const client: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xf0)]);
      client.attach(pair.client);
      await client.authenticate();

      await session.close();
      await session.close();

      expect(serverPort.closeCalls).assertEqual(1);
      expect(pair.server.closeCalls).assertEqual(1);
      expect(pair.server.unsubscribedDataIds.length).assertEqual(1);
      expect(pair.server.unsubscribedCloseIds.length).assertEqual(1);
      expect(pair.server.unsubscribedErrorIds.length).assertEqual(1);
      expect(scheduler.tasks.length).assertEqual(2);
      expect(scheduler.tasks[0].cancelable.cancelCount).assertEqual(1);
      expect(scheduler.tasks[1].cancelable.cancelCount).assertEqual(1);
    });

    it('closesActiveAndCandidateListenersAndAuthTimersExactlyOnce', 0, async () => {
      const serverPort: TestSocketServer = new TestSocketServer();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(new ManualClockPort());
      const session = new BarrelVpnRpcServerSession(
        new TestCryptoPort(),
        new ScriptedRandomPort([
          ...createServerRandom(1),
          ...createServerRandom(2)
        ]),
        scheduler,
        serverPort,
        SERVER_ADDRESS,
        async (request: VpnRpcBody): Promise<VpnRpcBody> => createSuccessFor(request)
      );

      await session.listen();
      const activePair: SocketPair = serverPort.accept();
      const activeClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xf2)]);
      activeClient.attach(activePair.client);
      await activeClient.authenticate();

      const candidatePair: SocketPair = serverPort.accept();
      const candidateClient: RpcClientPeer = new RpcClientPeer([sequentialBytes(32, 0xf4)]);
      candidateClient.attach(candidatePair.client);
      await waitForCondition((): boolean => candidateClient.receivedHellos.length >= 1, 'candidate hello before close');

      await session.close();
      await session.close();
      const stoppingEvent: VpnRpcBody = await activeClient.decodeNextResponse();

      expect(stoppingEvent.method).assertEqual('SERVER_STOPPING');
      expect(serverPort.closeCalls).assertEqual(1);
      expect(activePair.server.closeCalls).assertEqual(1);
      expect(candidatePair.server.closeCalls).assertEqual(1);
      expect(activePair.server.unsubscribedDataIds.length).assertEqual(1);
      expect(activePair.server.unsubscribedCloseIds.length).assertEqual(1);
      expect(activePair.server.unsubscribedErrorIds.length).assertEqual(1);
      expect(candidatePair.server.unsubscribedDataIds.length).assertEqual(1);
      expect(candidatePair.server.unsubscribedCloseIds.length).assertEqual(1);
      expect(candidatePair.server.unsubscribedErrorIds.length).assertEqual(1);
      expect(scheduler.tasks.length).assertEqual(4);
      expect(scheduler.tasks[0].cancelable.cancelCount).assertEqual(1);
      expect(scheduler.tasks[1].cancelable.cancelCount).assertEqual(1);
      expect(scheduler.tasks[2].cancelable.cancelCount).assertEqual(1);
      expect(scheduler.tasks[3].cancelable.cancelCount).assertEqual(1);
    });
  });
}

function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
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
