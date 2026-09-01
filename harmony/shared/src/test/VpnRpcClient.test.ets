import { describe, expect, it } from '@ohos/hypium';
import {
  VpnRpcClient as BarrelVpnRpcClient
} from '../../Index';
import {
  VpnRpcServerAuthenticator,
  VpnRpcTransportFailure,
  type VpnRpcAuthenticatedConnection
} from '../main/ets/vpn/rpc/VpnRpcAuthenticator';
import {
  decodeVpnRpcClientAuthBodyBytes,
  encodeVpnRpcBodyToText,
  encodeVpnRpcServerAuthBody,
  encodeVpnRpcServerHelloBody
} from '../main/ets/vpn/rpc/VpnRpcBodyCodec';
import { encodeVpnRpcU32BE } from '../main/ets/vpn/rpc/VpnRpcBinaryCodec';
import { type VpnRpcClientPort, type VpnRpcClientState, type VpnRpcEventListener } from '../main/ets/vpn/rpc/VpnRpcClient';
import { VpnRpcFramer } from '../main/ets/vpn/rpc/VpnRpcFramer';
import {
  createVpnRpcBodyErrorResponse,
  createVpnRpcBodyEvent,
  createVpnRpcBodySuccessResponse,
  createVpnRpcError,
  createVpnRpcGuards,
  createVpnRpcServerHelloBody,
  type VpnRpcBody,
  type VpnRpcGuards,
  type VpnRpcMethod
} from '../main/ets/vpn/rpc/VpnRpcModels';
import {
  createVpnRpcDelayJobRequestPayload,
  createVpnRpcDelayResult,
  createVpnRpcDelaySnapshotPayload,
  createVpnRpcEmptyPayload,
  createVpnRpcPingSuccessPayload,
  createVpnRpcQueryGroupsPayload,
  createVpnRpcQueryGroupRequestPayload,
  createVpnRpcRuntimeSnapshotPayload,
  type VpnRpcPayload,
  type VpnRpcRuntimeSnapshotPayload
} from '../main/ets/vpn/rpc/VpnRpcPayloads';
import {
  VpnRpcSocketFailure,
  type VpnRpcCancelableTaskPort,
  type VpnRpcClockPort,
  type VpnRpcCryptoPort,
  type VpnRpcRandomPort,
  type VpnRpcSchedulerPort,
  type VpnRpcSocketClientFactoryPort,
  type VpnRpcSocketConnectionPort
} from '../main/ets/vpn/rpc/VpnRpcPorts';

const PROFILE_HASH: string = '1111111111111111111111111111111111111111111111111111111111111111';
const PROFILE_HASH_NEXT: string = '2222222222222222222222222222222222222222222222222222222222222222';
const REVISION_HASH: string = '3333333333333333333333333333333333333333333333333333333333333333';
const REVISION_HASH_NEXT: string = '5555555555555555555555555555555555555555555555555555555555555555';
const CATALOG_DIGEST: string = '4444444444444444444444444444444444444444444444444444444444444444';
const CATALOG_DIGEST_NEXT: string = '6666666666666666666666666666666666666666666666666666666666666666';
const GROUP_ID: string = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const JOB_ID: string = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const JOB_ID_NEXT: string = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const JOB_ID_THIRD: string = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
const SERVER_NONCE_HEX: string = '101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f';
const SERVER_INSTANCE_HEX: string = '303132333435363738393a3b3c3d3e3f';
const CLIENT_NONCE_HEX: string = '404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f';
const BAD_SERVER_PROOF_HEX: string = 'abababababababababababababababababababababababababababababababab';
const BURST_CHUNK_BYTES: number = 8192;
const BURST_CHUNK_COUNT: number = 65;
const INITIAL_TX_BYTES: number = 11;
const INITIAL_RX_BYTES: number = 22;
const REFRESHED_TX_BYTES: number = 33;
const REFRESHED_RX_BYTES: number = 44;
const EVENT_TX_BYTES: number = 77;
const EVENT_RX_BYTES: number = 88;

interface StateReadableClient extends VpnRpcClientPort {
  state(): VpnRpcClientState;
}

interface InspectableActiveContext {
  generation: number;
  guards: VpnRpcGuards;
}

interface InspectableRememberedDelay {
  jobId: string;
  generation: number;
  guards: VpnRpcGuards;
  delayRevision: number;
  terminal: boolean;
}

interface InspectableTrafficCounters {
  txBytes: number;
  rxBytes: number;
}

interface InspectableClient extends StateReadableClient {
  rememberedDelay: InspectableRememberedDelay | null;
  trafficCountersValue: InspectableTrafficCounters;
}

interface ConnectOnceCapableClient extends StateReadableClient {
  connectOnce(): Promise<void>;
}

class TestCryptoPort implements VpnRpcCryptoPort {
  prepareCalls: number = 0;

  async prepare(): Promise<void> {
    this.prepareCalls += 1;
  }

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

class ScriptedRandomPort implements VpnRpcRandomPort {
  readonly requests: number[] = [];
  private readonly chunks: Uint8Array[];

  constructor(chunks: Uint8Array[]) {
    this.chunks = chunks.map((chunk: Uint8Array): Uint8Array => chunk.slice());
  }

  bytes(length: number): Uint8Array {
    this.requests.push(length);
    const next: Uint8Array | undefined = this.chunks.shift();
    if (next === undefined) {
      throw new Error('Missing scripted random bytes.');
    }
    if (next.length !== length) {
      throw new Error(`Expected scripted random length ${length}.`);
    }
    return next.slice();
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

class ManualTask implements VpnRpcCancelableTaskPort {
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
  throwOnSchedule: boolean = false;
  readonly throwOnCalls: number[] = [];
  scheduleCalls: number = 0;

  constructor(clock: ManualClockPort) {
    this.clock = clock;
  }

  schedule(delayMs: number, runner: () => Promise<void>): VpnRpcCancelableTaskPort {
    this.scheduleCalls += 1;
    this.delays.push(delayMs);
    if (this.throwOnSchedule || this.shouldThrowOnCall(this.scheduleCalls)) {
      throw new Error('scheduler-failed');
    }
    const cancelable: ManualTask = new ManualTask();
    this.tasks.push(new ScheduledRunner(delayMs, this.clock.nowMs() + delayMs, runner, cancelable));
    return cancelable;
  }

  private shouldThrowOnCall(call: number): boolean {
    for (let index: number = 0; index < this.throwOnCalls.length; index += 1) {
      if (this.throwOnCalls[index] === call) {
        return true;
      }
    }
    return false;
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

class TestSocketConnection implements VpnRpcSocketConnectionPort {
  readonly sentFrames: Uint8Array[] = [];
  readonly unsubscribedDataIds: number[] = [];
  readonly unsubscribedCloseIds: number[] = [];
  readonly unsubscribedErrorIds: number[] = [];
  private readonly dataListeners: Map<number, (bytes: Uint8Array) => void> = new Map();
  private readonly closeListeners: Map<number, () => void> = new Map();
  private readonly errorListeners: Map<number, () => void> = new Map();
  private nextId: number = 1;
  closeCalls: number = 0;
  receiveDelegate: ((bytes: Uint8Array) => Promise<void>) | null = null;

  async send(bytes: Uint8Array): Promise<void> {
    const copy: Uint8Array = bytes.slice();
    this.sentFrames.push(copy);
    if (this.receiveDelegate !== null) {
      await this.receiveDelegate(copy);
    }
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
    const slices: Uint8Array[] = splitBytes(bytes, chunks);
    const listeners: Array<(bytes: Uint8Array) => void> = Array.from(this.dataListeners.values());
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

  signalError(): void {
    const listeners: Array<() => void> = Array.from(this.errorListeners.values());
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index]();
    }
  }

  captureCurrentDataListener(): ((bytes: Uint8Array) => void) | null {
    const listeners: Array<(bytes: Uint8Array) => void> = Array.from(this.dataListeners.values());
    if (listeners.length === 0) {
      return null;
    }
    return listeners[0];
  }

  captureCurrentCloseListener(): (() => void) | null {
    const listeners: Array<() => void> = Array.from(this.closeListeners.values());
    if (listeners.length === 0) {
      return null;
    }
    return listeners[0];
  }
}

class TestServerHarness {
  readonly crypto: TestCryptoPort = new TestCryptoPort();
  readonly random: ScriptedRandomPort;
  readonly clock: ManualClockPort;
  readonly scheduler: ManualSchedulerPort;
  readonly authenticator: VpnRpcServerAuthenticator;
  readonly bootstrapPayload: VpnRpcRuntimeSnapshotPayload;
  readonly clientAuthFramer: VpnRpcFramer = new VpnRpcFramer();
  readonly businessFramer: VpnRpcFramer = new VpnRpcFramer();
  readonly requests: VpnRpcBody[] = [];
  readonly assignedEpoch: number;
  autoRespondToBootstrap: boolean = true;
  helloChunks?: number[];
  serverAuthChunks?: number[];
  serverAuthProofOverride: string | null = null;
  private socket: TestSocketConnection | null = null;
  private connection: VpnRpcAuthenticatedConnection | null = null;
  private handshakeStarted: boolean = false;

  constructor(
    assignedEpoch: number,
    bootstrapPayload: VpnRpcRuntimeSnapshotPayload,
    serverRandomChunks: Uint8Array[],
    clock: ManualClockPort
  ) {
    this.assignedEpoch = assignedEpoch;
    this.bootstrapPayload = bootstrapPayload;
    this.random = new ScriptedRandomPort(serverRandomChunks);
    this.clock = clock;
    this.scheduler = new ManualSchedulerPort(clock);
    this.authenticator = new VpnRpcServerAuthenticator(this.crypto, this.random, this.scheduler);
  }

  attach(socket: TestSocketConnection): void {
    this.socket = socket;
    socket.receiveDelegate = async (bytes: Uint8Array): Promise<void> => {
      await this.receiveFromClient(bytes);
    };
  }

  async startHandshake(): Promise<void> {
    if (this.handshakeStarted) {
      return;
    }
    this.handshakeStarted = true;
    const serverHello = await this.authenticator.begin();
    this.requireSocket().deliver(frameBytes(encodeVpnRpcServerHelloBody(serverHello), null), this.helloChunks);
  }

  async startHandshakeWithProtocolMismatch(protocolVersion: number): Promise<void> {
    if (this.handshakeStarted) {
      return;
    }
    this.handshakeStarted = true;
    const serverHello = await this.authenticator.begin();
    const bodyText: string =
      `{"protocolVersion":${protocolVersion},"serverNonce":"${serverHello.serverNonce}","serverInstance":"${serverHello.serverInstance}"}`;
    this.requireSocket().deliver(frameBytes(asciiBytes(bodyText), null), this.helloChunks);
  }

  deliverPreauthBodyBytes(bodyBytes: Uint8Array, chunks?: number[]): void {
    this.requireSocket().deliver(frameBytes(bodyBytes, null), chunks);
  }

  socketCloseCalls(): number {
    return this.requireSocket().closeCalls;
  }

  async respondSuccess(request: VpnRpcBody, payload: VpnRpcPayload, chunks?: number[]): Promise<void> {
    await this.sendAuthenticated(
      (sequence: number, clientEpoch: number): VpnRpcBody => createVpnRpcBodySuccessResponse(
        sequence,
        clientEpoch,
        request.requestOrdinal!,
        request.requestId!,
        request.method,
        request.sessionGeneration,
        request.guards,
        payload
      ),
      chunks
    );
  }

  async respondSuccessWithEnvelope(
    request: VpnRpcBody,
    payload: VpnRpcPayload,
    sessionGeneration: number,
    guards: VpnRpcGuards,
    chunks?: number[]
  ): Promise<void> {
    await this.sendAuthenticated(
      (sequence: number, clientEpoch: number): VpnRpcBody => createVpnRpcBodySuccessResponse(
        sequence,
        clientEpoch,
        request.requestOrdinal!,
        request.requestId!,
        request.method,
        sessionGeneration,
        guards,
        payload
      ),
      chunks
    );
  }

  async respondError(request: VpnRpcBody, code: string, retryable: boolean): Promise<void> {
    await this.sendAuthenticated((sequence: number, clientEpoch: number): VpnRpcBody => createVpnRpcBodyErrorResponse(
      sequence,
      clientEpoch,
      request.requestOrdinal!,
      request.requestId!,
      request.method,
      request.sessionGeneration,
      request.guards,
      createVpnRpcError(code, retryable)
    ));
  }

  async respondWithWrongMethodError(request: VpnRpcBody): Promise<void> {
    await this.sendAuthenticated((sequence: number, clientEpoch: number): VpnRpcBody => createVpnRpcBodyErrorResponse(
      sequence,
      clientEpoch,
      request.requestOrdinal!,
      request.requestId!,
      'SELECT_NODE',
      request.sessionGeneration,
      request.guards,
      createVpnRpcError('CORE_OPERATION_FAILED', false)
    ));
  }

  async respondWithWrongMethodErrorAndContext(request: VpnRpcBody, generation: number, guards: VpnRpcGuards): Promise<void> {
    await this.sendAuthenticated((sequence: number, clientEpoch: number): VpnRpcBody => createVpnRpcBodyErrorResponse(
      sequence,
      clientEpoch,
      request.requestOrdinal!,
      request.requestId!,
      'SELECT_NODE',
      generation,
      guards,
      createVpnRpcError('CORE_OPERATION_FAILED', false)
    ));
  }

  async respondWithWrongOrdinal(request: VpnRpcBody): Promise<void> {
    await this.sendAuthenticated((sequence: number, clientEpoch: number): VpnRpcBody => createVpnRpcBodySuccessResponse(
      sequence,
      clientEpoch,
      (request.requestOrdinal ?? 0) + 1,
      request.requestId!,
      request.method,
      request.sessionGeneration,
      request.guards,
      createVpnRpcPingSuccessPayload(SERVER_INSTANCE_HEX)
    ));
  }

  async respondWithWrongOrdinalAndContext(
    request: VpnRpcBody,
    payload: VpnRpcPayload,
    generation: number,
    guards: VpnRpcGuards
  ): Promise<void> {
    await this.sendAuthenticated((sequence: number, clientEpoch: number): VpnRpcBody => createVpnRpcBodySuccessResponse(
      sequence,
      clientEpoch,
      (request.requestOrdinal ?? 0) + 1,
      request.requestId!,
      request.method,
      generation,
      guards,
      payload
    ));
  }

  async respondDuplicate(request: VpnRpcBody): Promise<void> {
    await this.respondSuccess(request, createVpnRpcPingSuccessPayload(SERVER_INSTANCE_HEX));
    await this.respondSuccess(request, createVpnRpcPingSuccessPayload(SERVER_INSTANCE_HEX));
  }

  async respondDuplicateWithTrailingContext(
    request: VpnRpcBody,
    firstPayload: VpnRpcPayload,
    secondPayload: VpnRpcPayload,
    generation: number,
    guards: VpnRpcGuards
  ): Promise<void> {
    await this.respondSuccess(request, firstPayload);
    await this.sendAuthenticated((sequence: number, clientEpoch: number): VpnRpcBody => createVpnRpcBodySuccessResponse(
      sequence,
      clientEpoch,
      request.requestOrdinal!,
      request.requestId!,
      request.method,
      generation,
      guards,
      secondPayload
    ));
  }

  async sendRuntimeEvent(
    payload: VpnRpcRuntimeSnapshotPayload,
    generation: number,
    guards: VpnRpcGuards,
    chunks?: number[]
  ): Promise<void> {
    await this.sendAuthenticated((sequence: number, clientEpoch: number): VpnRpcBody => createVpnRpcBodyEvent(
      sequence,
      clientEpoch,
      'RUNTIME_CHANGED',
      generation,
      guards,
      payload
    ), chunks);
  }

  async sendDelayEvent(
    payload: VpnRpcPayload,
    generation: number,
    guards: VpnRpcGuards,
    chunks?: number[]
  ): Promise<void> {
    await this.sendAuthenticated((sequence: number, clientEpoch: number): VpnRpcBody => createVpnRpcBodyEvent(
      sequence,
      clientEpoch,
      'DELAY_CHANGED',
      generation,
      guards,
      payload
    ), chunks);
  }

  async buildRuntimeEventFrame(
    payload: VpnRpcRuntimeSnapshotPayload,
    generation: number,
    guards: VpnRpcGuards
  ): Promise<Uint8Array> {
    return await this.buildAuthenticatedFrame((sequence: number, clientEpoch: number): VpnRpcBody => createVpnRpcBodyEvent(
      sequence,
      clientEpoch,
      'RUNTIME_CHANGED',
      generation,
      guards,
      payload
    ));
  }

  signalClose(): void {
    this.requireSocket().signalClose();
  }

  private async receiveFromClient(bytes: Uint8Array): Promise<void> {
    if (this.connection === null) {
      const frames = this.clientAuthFramer.push(bytes, false);
      for (let index: number = 0; index < frames.length; index += 1) {
        const clientAuth = decodeVpnRpcClientAuthBodyBytes(frames[index].bodyBytes);
        const serverResult = await this.authenticator.acceptClientAuth(clientAuth, this.assignedEpoch);
        this.connection = serverResult.connection;
        this.clientAuthFramer.reset();
        const serverAuthBytes: Uint8Array = this.serverAuthProofOverride === null
          ? encodeVpnRpcServerAuthBody(serverResult.serverAuth)
          : asciiBytes(
            `{"protocolVersion":1,"clientEpoch":${serverResult.serverAuth.clientEpoch},"serverProof":"${this.serverAuthProofOverride}"}`
          );
        this.requireSocket().deliver(frameBytes(serverAuthBytes, null), this.serverAuthChunks);
      }
      return;
    }
    const frames = this.businessFramer.push(bytes, true);
    for (let index: number = 0; index < frames.length; index += 1) {
      const body: VpnRpcBody = await this.connection.decodeIncomingFrame(frames[index].bodyBytes, frames[index].macBytes!);
      this.requests.push(body);
      if (body.method === 'GET_SNAPSHOT' && this.autoRespondToBootstrap) {
        await this.respondSuccess(body, this.bootstrapPayload);
      }
    }
  }

  private async sendAuthenticated(
    builder: (sequence: number, clientEpoch: number) => VpnRpcBody,
    chunks?: number[]
  ): Promise<void> {
    const frameBytesValue: Uint8Array = await this.buildAuthenticatedFrame(builder);
    this.requireSocket().deliver(frameBytesValue, chunks);
  }

  private async buildAuthenticatedFrame(
    builder: (sequence: number, clientEpoch: number) => VpnRpcBody
  ): Promise<Uint8Array> {
    const connection: VpnRpcAuthenticatedConnection | null = this.connection;
    if (connection === null) {
      throw new Error('Server connection is missing.');
    }
    const protectedBody = await connection.encodeOutgoingBody(builder);
    return frameBytes(protectedBody.bodyBytes, protectedBody.macBytes);
  }

  private requireSocket(): TestSocketConnection {
    if (this.socket === null) {
      throw new Error('Client socket is missing.');
    }
    return this.socket;
  }
}

class ConnectScenario {
  readonly server: TestServerHarness | null;
  readonly failure: VpnRpcSocketFailure | null;

  constructor(server: TestServerHarness | null, failure: VpnRpcSocketFailure | null) {
    this.server = server;
    this.failure = failure;
  }
}

class TestSocketFactory implements VpnRpcSocketClientFactoryPort {
  readonly scenarios: ConnectScenario[];
  readonly connectCalls: string[] = [];
  readonly sockets: TestSocketConnection[] = [];

  constructor(scenarios: ConnectScenario[]) {
    this.scenarios = scenarios.slice();
  }

  async connect(address: string, timeoutMs: number): Promise<VpnRpcSocketConnectionPort> {
    this.connectCalls.push(`${address}|${timeoutMs}`);
    const next: ConnectScenario | undefined = this.scenarios.shift();
    if (next === undefined) {
      throw new VpnRpcSocketFailure('CONNECT_REFUSED');
    }
    if (next.failure !== null) {
      throw next.failure;
    }
    if (next.server === null) {
      throw new VpnRpcSocketFailure('CONNECT_REFUSED');
    }
    const socket: TestSocketConnection = new TestSocketConnection();
    next.server.attach(socket);
    this.sockets.push(socket);
    return socket;
  }
}

function frameBytes(bodyBytes: Uint8Array, macBytes: Uint8Array | null): Uint8Array {
  const header: Uint8Array = encodeVpnRpcU32BE(bodyBytes.length);
  const macLength: number = macBytes === null ? 0 : macBytes.length;
  const frame: Uint8Array = new Uint8Array(header.length + bodyBytes.length + macLength);
  frame.set(header, 0);
  frame.set(bodyBytes, header.length);
  if (macBytes !== null) {
    frame.set(macBytes, header.length + bodyBytes.length);
  }
  return frame;
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

function hexBytes(length: number, offset: number): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(length);
  for (let index: number = 0; index < length; index += 1) {
    bytes[index] = (offset + index) & 0xff;
  }
  return bytes;
}

function decodeHex(raw: string): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(raw.length / 2);
  for (let index: number = 0; index < raw.length; index += 2) {
    bytes[index / 2] = Number.parseInt(raw.slice(index, index + 2), 16);
  }
  return bytes;
}

function asciiBytes(raw: string): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(raw.length);
  for (let index: number = 0; index < raw.length; index += 1) {
    bytes[index] = raw.charCodeAt(index);
  }
  return bytes;
}

function buildExpectedUuid(bytes: Uint8Array): string {
  const copied: Uint8Array = bytes.slice();
  copied[6] = (copied[6] & 0x0f) | 0x40;
  copied[8] = (copied[8] & 0x3f) | 0x80;
  let hex: string = '';
  const alphabet: string = '0123456789abcdef';
  for (let index: number = 0; index < copied.length; index += 1) {
    hex += alphabet[(copied[index] >>> 4) & 0x0f];
    hex += alphabet[copied[index] & 0x0f];
  }
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function activeGuards(): VpnRpcGuards {
  return createVpnRpcGuards(PROFILE_HASH, REVISION_HASH, CATALOG_DIGEST);
}

function alternateGuards(): VpnRpcGuards {
  return createVpnRpcGuards(PROFILE_HASH_NEXT, REVISION_HASH_NEXT, CATALOG_DIGEST_NEXT);
}

function buildRuntimePayload(
  state: 'STARTING' | 'RUNNING' | 'RECOVERING' | 'STOPPED',
  failureCode: string | null = null,
  txBytes: number = 0,
  rxBytes: number = 0
): VpnRpcRuntimeSnapshotPayload {
  return createVpnRpcRuntimeSnapshotPayload(
    state,
    state === 'STOPPED' ? null : PROFILE_HASH,
    state === 'STOPPED' ? null : REVISION_HASH,
    state === 'STOPPED' ? null : CATALOG_DIGEST,
    state === 'RUNNING',
    state === 'RECOVERING' ? 2 : 0,
    state === 'RECOVERING' ? 250 : null,
    failureCode,
    txBytes,
    rxBytes
  );
}

function buildDelayPayload(jobId: string, revision: number, state: 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED') {
  return createVpnRpcDelaySnapshotPayload(
    jobId,
    revision,
    4,
    GROUP_ID,
    state,
    1,
    state === 'RUNNING' ? 0 : 1,
    [createVpnRpcDelayResult(GROUP_ID, state === 'RUNNING' ? 'WAITING' : 'CANCELLED', null)]
  );
}

function buildServerHelloFrame(serverNonce: string, serverInstance: string): Uint8Array {
  return frameBytes(
    encodeVpnRpcServerHelloBody(createVpnRpcServerHelloBody(1, serverNonce, serverInstance)),
    null
  );
}

function inspectClient(client: StateReadableClient): InspectableClient {
  return client as InspectableClient;
}

function connectOnceClient(client: StateReadableClient): ConnectOnceCapableClient {
  return client as ConnectOnceCapableClient;
}

function repeatBytesToLength(seed: Uint8Array, length: number): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(length);
  let offset: number = 0;
  while (offset < bytes.length) {
    const chunkLength: number = Math.min(seed.length, bytes.length - offset);
    bytes.set(seed.slice(0, chunkLength), offset);
    offset += chunkLength;
  }
  return bytes;
}

function createClientFixture(
  factory: TestSocketFactory,
  randomChunks: Uint8Array[],
  clock: ManualClockPort,
  scheduler: ManualSchedulerPort
): StateReadableClient {
  return new BarrelVpnRpcClient(new TestCryptoPort(), new ScriptedRandomPort(randomChunks), scheduler, clock, factory);
}

async function flushAsync(turns: number = 6): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

async function expectFailure<T>(promise: Promise<T>, code: string): Promise<VpnRpcTransportFailure> {
  const failure: VpnRpcTransportFailure = await captureFailure(promise);
  expect(failure.code).assertEqual(code);
  return failure;
}

async function captureFailure<T>(promise: Promise<T>): Promise<VpnRpcTransportFailure> {
  let failure: VpnRpcTransportFailure | null = null;
  try {
    await promise;
  } catch (error) {
    if (error instanceof VpnRpcTransportFailure) {
      failure = error;
    } else if (error instanceof Error) {
      throw error;
    } else {
      throw new Error('Expected VpnRpcTransportFailure.');
    }
  }
  expect(failure === null).assertFalse();
  if (failure === null) {
    throw new Error('Expected transport failure to be captured.');
  }
  return failure;
}

async function waitForRequestCount(server: TestServerHarness, expectedCount: number, label: string = 'request count'): Promise<void> {
  for (let index: number = 0; index < 20; index += 1) {
    if (server.requests.length >= expectedCount) {
      return;
    }
    await flushAsync();
  }
  throw new Error(`Expected ${expectedCount} requests for ${label}.`);
}

async function waitForCondition(predicate: () => boolean, maxTurns: number = 30, label: string = 'condition'): Promise<void> {
  for (let index: number = 0; index < maxTurns; index += 1) {
    if (predicate()) {
      return;
    }
    await flushAsync();
  }
  throw new Error(`Condition did not become true: ${label}.`);
}

async function advanceSchedulerSteps(scheduler: ManualSchedulerPort, steps: number[]): Promise<void> {
  for (let index: number = 0; index < steps.length; index += 1) {
    await scheduler.advanceAndRun(steps[index]);
    await flushAsync();
  }
}

async function waitForRejectedPromises(promises: Array<Promise<VpnRpcBody>>): Promise<void> {
  for (let index: number = 0; index < promises.length; index += 1) {
    let rejected: boolean = false;
    try {
      await promises[index];
    } catch (_error) {
      rejected = true;
    }
    expect(rejected).assertTrue();
  }
}

async function connectReady(client: VpnRpcClientPort, server: TestServerHarness): Promise<void> {
  const pending: Promise<void> = client.connect();
  await flushAsync();
  await server.startHandshake();
  await pending;
}

function latestState(client: StateReadableClient): VpnRpcClientState {
  return client.state();
}

export default function vpnRpcClientTestsuite() {
  describe('VpnRpcClientTest', () => {
    it('connectsHydratesSnapshotAndDeliversFragmentedRuntimeEvents', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const server = new TestServerHarness(7, buildRuntimePayload('STARTING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      server.helloChunks = [5, 7];
      server.serverAuthChunks = [3, 11];
      const factory = new TestSocketFactory([new ConnectScenario(server, null)]);
      const bootstrapRequestIdBytes: Uint8Array = hexBytes(16, 0x10);
      const client = createClientFixture(factory, [decodeHex(CLIENT_NONCE_HEX), bootstrapRequestIdBytes], clock, scheduler);
      const events: string[] = [];
      let thrownListenerCalls: number = 0;
      let selfRemovingId: number = 0;
      client.subscribe((_event: VpnRpcBody): void => {
        thrownListenerCalls += 1;
        throw new Error('listener exploded');
      });
      selfRemovingId = client.subscribe((event: VpnRpcBody): void => {
        events.push(event.method);
        client.unsubscribe(selfRemovingId);
      });
      client.subscribe((event: VpnRpcBody): void => {
        events.push(`${event.method}:${event.sessionGeneration}`);
      });

      await connectReady(client, server);
      expect(latestState(client)).assertEqual('READY');
      expect(client.snapshot().state).assertEqual('STARTING');
      expect(client.snapshot().activeRequest === null).assertTrue();
      expect(server.requests.length).assertEqual(1);
      expect(server.requests[0].method).assertEqual('GET_SNAPSHOT');
      expect(server.requests[0].requestId).assertEqual(buildExpectedUuid(bootstrapRequestIdBytes));

      await server.sendRuntimeEvent(buildRuntimePayload('RUNNING', 'VPN_STOP_FAILED'), 4, activeGuards(), [4, 9]);
      await waitForCondition((): boolean => client.snapshot().state === 'RUNNING');
      expect(client.snapshot().state).assertEqual('RUNNING');
      expect(client.snapshot().lastFailure?.code ?? '').assertEqual('VPN_STOP_FAILED');
      expect(events.join(',')).assertEqual('RUNTIME_CHANGED,RUNTIME_CHANGED:4');
      expect(thrownListenerCalls).assertEqual(1);
    });

    it('refreshTrafficCountersUsesBootstrapEnvelopeAcceptanceUpdatesCacheAndReturnsClone', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const server = new TestServerHarness(
        7,
        buildRuntimePayload('RUNNING', null, INITIAL_TX_BYTES, INITIAL_RX_BYTES),
        [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)],
        clock
      );
      const factory = new TestSocketFactory([new ConnectScenario(server, null)]);
      const client = createClientFixture(
        factory,
        [
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0x30),
          hexBytes(16, 0x31),
          hexBytes(16, 0x32)
        ],
        clock,
        scheduler
      );
      const inspectable: InspectableClient = inspectClient(client);

      await connectReady(client, server);
      expect(inspectable.trafficCountersValue.txBytes).assertEqual(INITIAL_TX_BYTES);
      expect(inspectable.trafficCountersValue.rxBytes).assertEqual(INITIAL_RX_BYTES);

      server.autoRespondToBootstrap = false;
      const firstRefresh: Promise<InspectableTrafficCounters> = inspectable.refreshTrafficCounters();
      await waitForRequestCount(server, 2, 'first refresh request');
      expect(server.requests[1].method).assertEqual('GET_SNAPSHOT');
      expect(server.requests[1].sessionGeneration).assertEqual(0);
      expect(server.requests[1].guards.profileHash).assertNull();
      await server.respondSuccessWithEnvelope(
        server.requests[1],
        buildRuntimePayload('RUNNING', null, REFRESHED_TX_BYTES, REFRESHED_RX_BYTES),
        4,
        createVpnRpcGuards(null, null, null)
      );
      const firstCounters: InspectableTrafficCounters = await firstRefresh;
      expect(firstCounters.txBytes).assertEqual(REFRESHED_TX_BYTES);
      expect(firstCounters.rxBytes).assertEqual(REFRESHED_RX_BYTES);
      expect(inspectable.trafficCountersValue.txBytes).assertEqual(REFRESHED_TX_BYTES);
      expect(inspectable.trafficCountersValue.rxBytes).assertEqual(REFRESHED_RX_BYTES);
      expect(client.activeContext()?.sessionGeneration ?? 0).assertEqual(4);

      const secondRefresh: Promise<InspectableTrafficCounters> = inspectable.refreshTrafficCounters();
      await waitForRequestCount(server, 3, 'second refresh request');
      await server.respondSuccessWithEnvelope(
        server.requests[2],
        buildRuntimePayload('RUNNING', null, REFRESHED_TX_BYTES, REFRESHED_RX_BYTES),
        4,
        createVpnRpcGuards(null, null, null)
      );
      const secondCounters: InspectableTrafficCounters = await secondRefresh;
      expect(firstCounters === secondCounters).assertFalse();
      firstCounters.txBytes = 999;
      firstCounters.rxBytes = 1000;
      expect(inspectable.trafficCountersValue.txBytes).assertEqual(REFRESHED_TX_BYTES);
      expect(inspectable.trafficCountersValue.rxBytes).assertEqual(REFRESHED_RX_BYTES);
    });

    it('updatesTrafficCounterCacheFromEventsAndClearsItOnDisconnectAndClose', 0, async () => {
      const reconnectClock: ManualClockPort = new ManualClockPort();
      const reconnectScheduler: ManualSchedulerPort = new ManualSchedulerPort(reconnectClock);
      const firstServer = new TestServerHarness(
        7,
        buildRuntimePayload('RUNNING', null, INITIAL_TX_BYTES, INITIAL_RX_BYTES),
        [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)],
        reconnectClock
      );
      const secondServer = new TestServerHarness(
        9,
        buildRuntimePayload('RUNNING', null, REFRESHED_TX_BYTES, REFRESHED_RX_BYTES),
        [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)],
        reconnectClock
      );
      const reconnectFactory = new TestSocketFactory([
        new ConnectScenario(firstServer, null),
        new ConnectScenario(secondServer, null)
      ]);
      const reconnectingClient = createClientFixture(
        reconnectFactory,
        [
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0x40),
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0x41)
        ],
        reconnectClock,
        reconnectScheduler
      );
      const reconnectInspectable: InspectableClient = inspectClient(reconnectingClient);

      await connectReady(reconnectingClient, firstServer);
      await firstServer.sendRuntimeEvent(buildRuntimePayload('RUNNING', null, EVENT_TX_BYTES, EVENT_RX_BYTES), 4, activeGuards());
      await waitForCondition(
        (): boolean => reconnectInspectable.trafficCountersValue.txBytes === EVENT_TX_BYTES &&
          reconnectInspectable.trafficCountersValue.rxBytes === EVENT_RX_BYTES,
        120,
        'runtime event traffic cache'
      );
      firstServer.signalClose();
      await waitForCondition(
        (): boolean => reconnectInspectable.trafficCountersValue.txBytes === 0 &&
          reconnectInspectable.trafficCountersValue.rxBytes === 0 &&
          reconnectingClient.state() !== 'READY',
        120,
        'traffic cache cleared after disconnect'
      );
      expect(reconnectInspectable.trafficCountersValue.txBytes).assertEqual(0);
      expect(reconnectInspectable.trafficCountersValue.rxBytes).assertEqual(0);
      await secondServer.startHandshake();
      await waitForCondition((): boolean => reconnectingClient.state() === 'READY', 120, 'reconnected ready');

      const closeClock: ManualClockPort = new ManualClockPort();
      const closeScheduler: ManualSchedulerPort = new ManualSchedulerPort(closeClock);
      const closeServer = new TestServerHarness(
        7,
        buildRuntimePayload('RUNNING', null, INITIAL_TX_BYTES, INITIAL_RX_BYTES),
        [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)],
        closeClock
      );
      const closeFactory = new TestSocketFactory([new ConnectScenario(closeServer, null)]);
      const closingClient = createClientFixture(
        closeFactory,
        [
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0x50)
        ],
        closeClock,
        closeScheduler
      );
      const closeInspectable: InspectableClient = inspectClient(closingClient);
      await connectReady(closingClient, closeServer);
      expect(closeInspectable.trafficCountersValue.txBytes).assertEqual(INITIAL_TX_BYTES);
      expect(closeInspectable.trafficCountersValue.rxBytes).assertEqual(INITIAL_RX_BYTES);
      await closingClient.close();
      expect(closeInspectable.trafficCountersValue.txBytes).assertEqual(0);
      expect(closeInspectable.trafficCountersValue.rxBytes).assertEqual(0);
      await expectFailure<InspectableTrafficCounters>(closeInspectable.refreshTrafficCounters(), 'RPC_DISCONNECTED');
    });

    it('retriesConnectUntilSuccessAndExhaustsUnavailableWindow', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const server = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(null, new VpnRpcSocketFailure('CONNECT_REFUSED')),
        new ConnectScenario(null, new VpnRpcSocketFailure('PLATFORM_FAILED')),
        new ConnectScenario(server, null)
      ]);
      const client = createClientFixture(factory, [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0x21)], clock, scheduler);
      const connectPromise: Promise<void> = client.connect();
      await flushAsync();
      await scheduler.advanceAndRun(250);
      await flushAsync();
      await scheduler.advanceAndRun(500);
      await flushAsync();
      await server.startHandshake();
      await connectPromise;

      expect(factory.connectCalls.length).assertEqual(3);
      expect(latestState(client)).assertEqual('READY');

      const exhaustedClock: ManualClockPort = new ManualClockPort();
      const exhaustedScheduler: ManualSchedulerPort = new ManualSchedulerPort(exhaustedClock);
      const exhaustedFactory = new TestSocketFactory([
        new ConnectScenario(null, new VpnRpcSocketFailure('CONNECT_REFUSED')),
        new ConnectScenario(null, new VpnRpcSocketFailure('PLATFORM_FAILED')),
        new ConnectScenario(null, new VpnRpcSocketFailure('CONNECT_REFUSED')),
        new ConnectScenario(null, new VpnRpcSocketFailure('PLATFORM_FAILED')),
        new ConnectScenario(null, new VpnRpcSocketFailure('CONNECT_REFUSED')),
        new ConnectScenario(null, new VpnRpcSocketFailure('PLATFORM_FAILED'))
      ]);
      const exhaustedClient = createClientFixture(
        exhaustedFactory,
        [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0x31)],
        exhaustedClock,
        exhaustedScheduler
      );
      const failedConnect: Promise<void> = exhaustedClient.connect();
      for (let index: number = 0; index < 6; index += 1) {
        await flushAsync();
        await exhaustedScheduler.advanceAndRun(index < 1 ? 250 : index === 1 ? 500 : index === 2 ? 1000 : index === 3 ? 2000 : 4000);
      }
      await flushAsync();
      await exhaustedScheduler.advanceAndRun(4000);
      await expectFailure(failedConnect, 'RPC_UNAVAILABLE');
      expect(exhaustedClient.state()).assertEqual('DISCONNECTED');
    });

    it('connectOnceAttemptsConnectRefusedOnlyOnceWithoutSchedulingBackoff', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const factory = new TestSocketFactory([new ConnectScenario(null, new VpnRpcSocketFailure('CONNECT_REFUSED'))]);
      const client: ConnectOnceCapableClient = connectOnceClient(
        createClientFixture(factory, [decodeHex(CLIENT_NONCE_HEX)], clock, scheduler)
      );

      const failure: VpnRpcTransportFailure = await expectFailure(client.connectOnce(), 'RPC_UNAVAILABLE');

      expect(failure.retryable).assertTrue();
      expect(factory.connectCalls.length).assertEqual(1);
      expect(scheduler.scheduleCalls).assertEqual(0);
      expect(client.state()).assertEqual('DISCONNECTED');
    });

    it('connectOnceFailureDoesNotPreventLaterBoundedRetryConnectFromReachingReady', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const server = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(null, new VpnRpcSocketFailure('CONNECT_REFUSED')),
        new ConnectScenario(null, new VpnRpcSocketFailure('PLATFORM_FAILED')),
        new ConnectScenario(server, null)
      ]);
      const clientPort: StateReadableClient = createClientFixture(
        factory,
        [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0x91)],
        clock,
        scheduler
      );
      const client: ConnectOnceCapableClient = connectOnceClient(clientPort);

      await expectFailure(client.connectOnce(), 'RPC_UNAVAILABLE');
      expect(factory.connectCalls.length).assertEqual(1);
      expect(scheduler.scheduleCalls).assertEqual(0);
      expect(client.state()).assertEqual('DISCONNECTED');

      const connectPromise: Promise<void> = client.connect();
      await flushAsync();
      await scheduler.advanceAndRun(250);
      await flushAsync();
      await server.startHandshake();
      await connectPromise;

      expect(factory.connectCalls.length).assertEqual(3);
      expect(client.state()).assertEqual('READY');
    });

    it('connectOnceJoinsExistingFullConnectWithoutCreatingAnotherSocketOrBackoff', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const server = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([new ConnectScenario(server, null)]);
      const clientPort: StateReadableClient = createClientFixture(
        factory,
        [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0x99)],
        clock,
        scheduler
      );
      const client: ConnectOnceCapableClient = connectOnceClient(clientPort);

      const fullConnectPromise: Promise<void> = client.connect();
      await waitForCondition(
        (): boolean => factory.sockets.length === 1 && client.state() === 'AUTHENTICATING',
        120,
        'full connect auth stage'
      );
      const scheduleCallsBeforeJoin: number = scheduler.scheduleCalls;
      let connectOnceSettled: boolean = false;
      const connectOncePromise: Promise<void> = client.connectOnce();
      connectOncePromise.then((): void => {
        connectOnceSettled = true;
      }).catch((): void => {
        connectOnceSettled = true;
      });

      await flushAsync();
      expect(connectOnceSettled).assertFalse();
      expect(factory.connectCalls.length).assertEqual(1);
      expect(factory.sockets.length).assertEqual(1);
      expect(scheduler.scheduleCalls).assertEqual(scheduleCallsBeforeJoin);

      await server.startHandshake();
      await fullConnectPromise;
      await connectOncePromise;

      expect(connectOnceSettled).assertTrue();
      expect(factory.connectCalls.length).assertEqual(1);
      expect(server.requests.length).assertEqual(1);
      expect(server.requests[0].method).assertEqual('GET_SNAPSHOT');
      expect(client.state()).assertEqual('READY');
    });

    it('fullConnectWaitsForInflightConnectOnceThenContinuesWithBoundedRetryAfterOneShotFailure', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const silentServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const successServer = new TestServerHarness(9, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(silentServer, null),
        new ConnectScenario(successServer, null)
      ]);
      const clientPort: StateReadableClient = createClientFixture(
        factory,
        [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0xa1)],
        clock,
        scheduler
      );
      const client: ConnectOnceCapableClient = connectOnceClient(clientPort);

      const oneShotPromise: Promise<void> = client.connectOnce();
      await flushAsync();
      expect(factory.connectCalls.length).assertEqual(1);

      const fullConnectPromise: Promise<void> = client.connect();
      await flushAsync();
      expect(factory.connectCalls.length).assertEqual(1);

      await scheduler.advanceAndRun(3000);
      await flushAsync();
      await expectFailure(oneShotPromise, 'RPC_UNAVAILABLE');

      await waitForCondition((): boolean => factory.connectCalls.length === 2, 120, 'full connect retries after one-shot failure');
      await waitForCondition((): boolean => factory.sockets.length === 2, 120, 'second socket allocation');
      await waitForCondition(
        (): boolean => factory.sockets[1].captureCurrentDataListener() !== null,
        120,
        'second socket data listener'
      );
      await successServer.startHandshake();
      await waitForRequestCount(successServer, 1, 'second attempt bootstrap request');
      await waitForCondition((): boolean => client.state() === 'READY', 120, 'full connect ready after one-shot failure');
      await fullConnectPromise;

      expect(factory.connectCalls.length).assertEqual(2);
      expect(client.state()).assertEqual('READY');
    });

    it('secondConnectOnceInFirstOneShotFailureCallbackJoinsUpgradedFullBoundedRetry', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const silentServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const successServer = new TestServerHarness(9, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(silentServer, null),
        new ConnectScenario(null, new VpnRpcSocketFailure('CONNECT_REFUSED')),
        new ConnectScenario(successServer, null)
      ]);
      const clientPort: StateReadableClient = createClientFixture(
        factory,
        [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0xb1)],
        clock,
        scheduler
      );
      const client: ConnectOnceCapableClient = connectOnceClient(clientPort);

      const firstOneShotPromise: Promise<void> = client.connectOnce();
      await flushAsync();
      const fullConnectPromise: Promise<void> = client.connect();
      let secondConnectOncePromise: Promise<void> | null = null;
      let secondConnectOnceCreated: boolean = false;
      const firstOneShotFailureObserved: Promise<void> = firstOneShotPromise.catch((): Promise<void> => {
        secondConnectOnceCreated = true;
        secondConnectOncePromise = client.connectOnce();
        return Promise.resolve();
      });

      await scheduler.advanceAndRun(3000);
      await firstOneShotFailureObserved;
      const schedulerCallsBeforeSecondAttempt: number = scheduler.scheduleCalls;
      await waitForCondition((): boolean => factory.connectCalls.length === 2, 120, 'full connect upgraded after one-shot failure');
      expect(secondConnectOnceCreated).assertTrue();
      expect(secondConnectOncePromise === null).assertFalse();

      await waitForCondition(
        (): boolean => scheduler.scheduleCalls > schedulerCallsBeforeSecondAttempt,
        120,
        'bounded retry scheduled after second attempt failure'
      );
      const schedulerCallsAfterUpgrade: number = scheduler.scheduleCalls;
      await scheduler.advanceAndRun(250);
      await waitForCondition((): boolean => factory.connectCalls.length === 3, 120, 'bounded retry third connect call');
      expect(scheduler.scheduleCalls >= schedulerCallsAfterUpgrade).assertTrue();

      await waitForCondition((): boolean => factory.sockets.length === 2, 120, 'upgraded full success socket');
      await waitForCondition(
        (): boolean => factory.sockets[1].captureCurrentDataListener() !== null,
        120,
        'upgraded full success socket listener'
      );
      await successServer.startHandshake();
      await waitForRequestCount(successServer, 1, 'upgraded full bootstrap request');
      await fullConnectPromise;
      await secondConnectOncePromise!;

      expect(factory.connectCalls.length).assertEqual(3);
      expect(successServer.requests.length).assertEqual(1);
      expect(successServer.requests[0].method).assertEqual('GET_SNAPSHOT');
      expect(client.state()).assertEqual('READY');
    });

    it('closeBeatsInflightConnectOnceAndLateFailureCannotOverrideClosedState', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const silentServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([new ConnectScenario(silentServer, null)]);
      const clientPort: StateReadableClient = createClientFixture(factory, [decodeHex(CLIENT_NONCE_HEX)], clock, scheduler);
      const client: ConnectOnceCapableClient = connectOnceClient(clientPort);

      const connectPromise: Promise<void> = client.connectOnce();
      await waitForCondition(
        (): boolean => factory.sockets.length === 1 && client.state() === 'AUTHENTICATING',
        120,
        'connectOnce auth stage'
      );
      const lateClose = factory.sockets[0].captureCurrentCloseListener();
      expect(lateClose === null).assertFalse();

      const closePromise: Promise<void> = client.close();
      await closePromise;
      const failure: VpnRpcTransportFailure = await expectFailure(connectPromise, 'RPC_DISCONNECTED');
      expect(failure.retryable).assertFalse();

      lateClose!();
      await flushAsync();

      expect(client.state()).assertEqual('CLOSED');
      expect(factory.sockets[0].closeCalls).assertEqual(1);
    });

    it('retriesAuthTimeoutUntilDeadlineAndNormalizesAsRpcUnavailable', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const silentServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([new ConnectScenario(silentServer, null)]);
      const client = createClientFixture(factory, [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0x41)], clock, scheduler);

      const connectPromise: Promise<void> = client.connect();
      await flushAsync();
      await scheduler.advanceAndRun(3000);
      await flushAsync();
      expect(factory.connectCalls.length).assertEqual(1);

      await scheduler.advanceAndRun(250);
      await flushAsync();
      expect(factory.connectCalls.length).assertEqual(2);

      await advanceSchedulerSteps(scheduler, [500, 1000, 2000, 4000, 4000, 250]);
      const failure: VpnRpcTransportFailure = await expectFailure(connectPromise, 'RPC_UNAVAILABLE');
      expect(failure.retryable).assertTrue();
      expect(client.state()).assertEqual('DISCONNECTED');
      expect(silentServer.socketCloseCalls()).assertEqual(1);
    });

    it('retriesBadServerProofUntilDeadlineAndDoesNotLeakAuthFailure', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const wrongProofServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      wrongProofServer.serverAuthProofOverride = BAD_SERVER_PROOF_HEX;
      const factory = new TestSocketFactory([new ConnectScenario(wrongProofServer, null)]);
      const client = createClientFixture(
        factory,
        [decodeHex(CLIENT_NONCE_HEX)],
        clock,
        scheduler
      );

      const connectPromise: Promise<void> = client.connect();
      await flushAsync();
      await wrongProofServer.startHandshake();
      await flushAsync();
      expect(factory.connectCalls.length).assertEqual(1);

      await waitForCondition((): boolean => scheduler.scheduleCalls >= 2, 120);
      await advanceSchedulerSteps(scheduler, [250, 500, 1000, 2000, 4000, 4000, 3250]);
      const failure: VpnRpcTransportFailure = await expectFailure(connectPromise, 'RPC_UNAVAILABLE');
      expect(failure.retryable).assertTrue();
      expect(factory.connectCalls.length >= 2).assertTrue();
      expect(client.state()).assertEqual('DISCONNECTED');
    });

    it('retriesCanonicalProtocolMismatchUntilDeadlineAndNormalizesAsRpcUnavailable', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const mismatchedServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([new ConnectScenario(mismatchedServer, null)]);
      const client = createClientFixture(factory, [decodeHex(CLIENT_NONCE_HEX)], clock, scheduler);

      const connectPromise: Promise<void> = client.connect();
      await flushAsync();
      await mismatchedServer.startHandshakeWithProtocolMismatch(2);
      await flushAsync();
      expect(factory.connectCalls.length).assertEqual(1);

      await scheduler.advanceAndRun(250);
      await flushAsync();
      expect(factory.connectCalls.length).assertEqual(2);

      await advanceSchedulerSteps(scheduler, [500, 1000, 2000, 4000, 4000, 3250]);
      const failure: VpnRpcTransportFailure = await expectFailure(connectPromise, 'RPC_UNAVAILABLE');
      expect(failure.retryable).assertTrue();
      expect(client.state()).assertEqual('DISCONNECTED');
    });

    it('retriesMalformedPreauthFrameUntilDeadlineAndNormalizesAsRpcUnavailable', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const malformedServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([new ConnectScenario(malformedServer, null)]);
      const client = createClientFixture(factory, [decodeHex(CLIENT_NONCE_HEX)], clock, scheduler);

      const connectPromise: Promise<void> = client.connect();
      await flushAsync();
      malformedServer.deliverPreauthBodyBytes(asciiBytes('{}'));
      await flushAsync();
      expect(factory.connectCalls.length).assertEqual(1);

      await scheduler.advanceAndRun(250);
      await flushAsync();
      expect(factory.connectCalls.length).assertEqual(2);

      await advanceSchedulerSteps(scheduler, [500, 1000, 2000, 4000, 4000, 3250]);
      const failure: VpnRpcTransportFailure = await expectFailure(connectPromise, 'RPC_UNAVAILABLE');
      expect(failure.retryable).assertTrue();
      expect(client.state()).assertEqual('DISCONNECTED');
    });

    it('normalizesSchedulerFailureDuringBackoffWait', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      scheduler.throwOnSchedule = true;
      const factory = new TestSocketFactory([new ConnectScenario(null, new VpnRpcSocketFailure('CONNECT_REFUSED'))]);
      const client = createClientFixture(factory, [decodeHex(CLIENT_NONCE_HEX)], clock, scheduler);

      const failure: VpnRpcTransportFailure = await expectFailure(client.connect(), 'RPC_UNAVAILABLE');
      expect(failure.retryable).assertTrue();
      expect(client.state()).assertEqual('DISCONNECTED');
      expect(scheduler.tasks.length).assertEqual(0);
    });

    it('normalizesCanceledBackoffWaitWhenCloseWinsTheLifecycle', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const silentServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([new ConnectScenario(silentServer, null)]);
      const client = createClientFixture(factory, [decodeHex(CLIENT_NONCE_HEX)], clock, scheduler);

      const connectPromise: Promise<void> = client.connect();
      await flushAsync();
      await scheduler.advanceAndRun(3000);
      await flushAsync();
      const backoffTask: ScheduledRunner = scheduler.tasks[scheduler.tasks.length - 1];
      const closePromise: Promise<void> = client.close();

      await closePromise;
      const failure: VpnRpcTransportFailure = await expectFailure(connectPromise, 'RPC_DISCONNECTED');
      expect(failure.retryable).assertFalse();
      expect(client.state()).assertEqual('CLOSED');
      expect(backoffTask.cancelable.cancelCount).assertEqual(1);
      expect(factory.sockets[0].closeCalls).assertEqual(1);
      expect(factory.sockets[0].unsubscribedDataIds.length).assertEqual(1);
      expect(factory.sockets[0].unsubscribedCloseIds.length).assertEqual(1);
      expect(factory.sockets[0].unsubscribedErrorIds.length).assertEqual(1);
    });

    it('clonesInputsRetriesOnceAndRejectsTheSixtyFifthPendingRequest', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const server = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const randomChunks: Uint8Array[] = [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0x50)];
      for (let index: number = 0; index < 64; index += 1) {
        randomChunks.push(hexBytes(16, 0x60 + index));
      }
      const factory = new TestSocketFactory([new ConnectScenario(server, null)]);
      const client = createClientFixture(factory, randomChunks, clock, scheduler);
      await connectReady(client, server);

      const guards: VpnRpcGuards = activeGuards();
      const payload = createVpnRpcQueryGroupRequestPayload(GROUP_ID);
      const requestPromise: Promise<VpnRpcBody> = client.request('QUERY_GROUP', guards, 4, payload);
      guards.profileHash = PROFILE_HASH_NEXT;
      payload.groupId = PROFILE_HASH_NEXT;
      await waitForRequestCount(server, 2);
      expect(server.requests[1].requestId).assertEqual(buildExpectedUuid(hexBytes(16, 0x60)));
      expect(server.requests[1].requestOrdinal).assertEqual(2);
      expect(server.requests[1].guards.profileHash).assertEqual(PROFILE_HASH);
      expect(encodeVpnRpcBodyToText(server.requests[1]).includes(`"groupId":"${GROUP_ID}"`)).assertTrue();
      expect(encodeVpnRpcBodyToText(server.requests[1]).includes(PROFILE_HASH_NEXT)).assertFalse();

      await scheduler.advanceAndRun(250);
      await waitForRequestCount(server, 3);
      expect(server.requests[2].requestId).assertEqual(server.requests[1].requestId ?? '');
      expect(server.requests[2].requestOrdinal).assertEqual(server.requests[1].requestOrdinal ?? 0);

      const pending: Promise<VpnRpcBody>[] = [requestPromise];
      for (let index: number = 0; index < 63; index += 1) {
        pending.push(client.request('PING', createVpnRpcGuards(null, null, null), 0, createVpnRpcEmptyPayload()));
      }
      await flushAsync();
      await expectFailure(client.request('PING', createVpnRpcGuards(null, null, null), 0, createVpnRpcEmptyPayload()), 'COMMAND_BUSY');
      expect(pending.length).assertEqual(64);
    });

    it('rejectsSchedulerThrowForRequestAndCleansPendingState', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const server = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([new ConnectScenario(server, null)]);
      const client = createClientFixture(
        factory,
        [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0xa1), hexBytes(16, 0xa2), hexBytes(16, 0xa3)],
        clock,
        scheduler
      );
      await connectReady(client, server);
      const taskStart: number = scheduler.tasks.length;

      scheduler.throwOnCalls.push(scheduler.scheduleCalls + 2);
      await expectFailure(client.request('PING', createVpnRpcGuards(null, null, null), 0, createVpnRpcEmptyPayload()), 'RPC_UNAVAILABLE');
      expect(scheduler.tasks.length).assertEqual(taskStart + 1);
      expect(scheduler.tasks[taskStart].cancelable.cancelCount).assertEqual(1);
      expect(server.requests.length).assertEqual(1);

      const recoveryRequest: Promise<VpnRpcBody> = client.request('PING', createVpnRpcGuards(null, null, null), 0, createVpnRpcEmptyPayload());
      await waitForRequestCount(server, 2);
      await server.respondSuccess(server.requests[1], createVpnRpcPingSuccessPayload(SERVER_INSTANCE_HEX));
      await recoveryRequest;
    });

    it('cancelsRetryAndTimeoutTasksWhenResponseArrivesBeforeRetry', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const server = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([new ConnectScenario(server, null)]);
      const client = createClientFixture(factory, [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0xb1), hexBytes(16, 0xb2)], clock, scheduler);
      await connectReady(client, server);
      const taskStart: number = scheduler.tasks.length;

      const request: Promise<VpnRpcBody> = client.request('PING', createVpnRpcGuards(null, null, null), 0, createVpnRpcEmptyPayload());
      await waitForRequestCount(server, 2);
      await server.respondSuccess(server.requests[1], createVpnRpcPingSuccessPayload(SERVER_INSTANCE_HEX));
      await request;

      expect(scheduler.tasks[taskStart].cancelable.cancelCount).assertEqual(1);
      expect(scheduler.tasks[taskStart + 1].cancelable.cancelCount).assertEqual(1);
    });

    it('timesOutAfterOneRetryAndDoesNotReplayAgain', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const server = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([new ConnectScenario(server, null)]);
      const client = createClientFixture(factory, [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0xc1), hexBytes(16, 0xc2)], clock, scheduler);
      await connectReady(client, server);
      const taskStart: number = scheduler.tasks.length;

      const request: Promise<VpnRpcBody> = client.request('PING', createVpnRpcGuards(null, null, null), 0, createVpnRpcEmptyPayload());
      await waitForRequestCount(server, 2);
      await scheduler.advanceAndRun(250);
      await waitForRequestCount(server, 3);
      await scheduler.advanceAndRun(5000);
      await expectFailure(request, 'COMMAND_TIMEOUT');
      expect(server.requests.length).assertEqual(3);
      expect(scheduler.tasks[taskStart].ran).assertTrue();
      expect(scheduler.tasks[taskStart].cancelable.cancelCount).assertEqual(0);
      expect(scheduler.tasks[taskStart + 1].ran).assertTrue();
      await scheduler.advanceAndRun(5000);
      expect(server.requests.length).assertEqual(3);
    });

    it('failClosesOnWrongMethodThenReconnectsWithFreshEpochAndIgnoresLateOldFrames', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const firstServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const secondServer = new TestServerHarness(11, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(firstServer, null),
        new ConnectScenario(secondServer, null)
      ]);
      const client = createClientFixture(
        factory,
        [
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0x70),
          hexBytes(16, 0x71),
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0x72),
          hexBytes(16, 0x73)
        ],
        clock,
        scheduler
      );
      await connectReady(client, firstServer);

      const failingRequest: Promise<VpnRpcBody> = client.request(
        'READ_DELAY_TEST',
        activeGuards(),
        4,
        createVpnRpcDelayJobRequestPayload(JOB_ID)
      );
      await waitForRequestCount(firstServer, 2);
      await firstServer.respondWithWrongMethodError(firstServer.requests[1]);
      await expectFailure(failingRequest, 'FRAME_INVALID');

      const reconnectPromise: Promise<void> = client.connect();
      await flushAsync();
      await secondServer.startHandshake();
      await reconnectPromise;
      expect(client.state()).assertEqual('READY');

      if (firstServer.requests.length >= 2) {
        await firstServer.respondError(firstServer.requests[1], 'CORE_OPERATION_FAILED', false);
      }
      await flushAsync();
      const nextRequest: Promise<VpnRpcBody> = client.request('PING', createVpnRpcGuards(null, null, null), 0, createVpnRpcEmptyPayload());
      await waitForRequestCount(secondServer, 2);
      await secondServer.respondSuccess(secondServer.requests[1], createVpnRpcPingSuccessPayload(SERVER_INSTANCE_HEX));
      const response: VpnRpcBody = await nextRequest;
      expect(response.method).assertEqual('PING');
      expect(firstServer.requests[1].clientEpoch === secondServer.requests[1].clientEpoch).assertFalse();
    });

    it('ignoresStaleSocketCallbacksAcrossRetriedConnectAttempts', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const firstServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const secondServer = new TestServerHarness(11, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(firstServer, null),
        new ConnectScenario(secondServer, null)
      ]);
      const client = createClientFixture(
        factory,
        [
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xa1)
        ],
        clock,
        scheduler
      );

      const connectPromise: Promise<void> = client.connect();
      await flushAsync();
      const lateAttemptOneData = factory.sockets[0].captureCurrentDataListener();
      const lateAttemptOneClose = factory.sockets[0].captureCurrentCloseListener();
      expect(lateAttemptOneData === null).assertFalse();
      expect(lateAttemptOneClose === null).assertFalse();

      firstServer.deliverPreauthBodyBytes(asciiBytes('{'));
      await flushAsync();
      await advanceSchedulerSteps(scheduler, [250]);
      await waitForCondition((): boolean => factory.connectCalls.length === 2, 120, 'second connect call');
      await waitForCondition((): boolean => factory.sockets.length === 2, 120, 'second socket allocation');
      await waitForCondition((): boolean => factory.sockets[1].captureCurrentDataListener() !== null, 120, 'second socket data listener');
      await waitForCondition((): boolean => factory.sockets[1].captureCurrentCloseListener() !== null, 120, 'second socket close listener');
      expect(factory.sockets[0].closeCalls).assertEqual(1);

      const staleHelloFrame: Uint8Array = buildServerHelloFrame(SERVER_NONCE_HEX, SERVER_INSTANCE_HEX);
      lateAttemptOneData!(staleHelloFrame.slice());
      lateAttemptOneClose!();
      await flushAsync();

      await secondServer.startHandshake();
      await waitForCondition((): boolean => secondServer.requests.length === 1, 120, 'second attempt bootstrap request');
      await waitForCondition((): boolean => client.state() === 'READY', 120, 'client ready after stale callbacks');
      await connectPromise;

      expect(client.state()).assertEqual('READY');
      expect(factory.sockets[1].closeCalls).assertEqual(0);
      expect(factory.connectCalls.length).assertEqual(2);
      expect(secondServer.requests.length).assertEqual(1);
      expect(secondServer.requests[0].method).assertEqual('GET_SNAPSHOT');
    });

    it('failClosesBurstOverflowWithoutDeliveringQueuedEventsAndReconnectsOnFreshAttempt', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const firstServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const secondServer = new TestServerHarness(11, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(firstServer, null),
        new ConnectScenario(secondServer, null)
      ]);
      const client = createClientFixture(
        factory,
        [
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xb1),
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xb2)
        ],
        clock,
        scheduler
      );
      let listenerCalls: number = 0;
      client.subscribe((_event: VpnRpcBody): void => {
        listenerCalls += 1;
      });
      await connectReady(client, firstServer);
      const burstListener = factory.sockets[0].captureCurrentDataListener();
      expect(burstListener === null).assertFalse();
      const eventFrame: Uint8Array = await firstServer.buildRuntimeEventFrame(buildRuntimePayload('RUNNING'), 4, activeGuards());
      const burstBytes: Uint8Array = repeatBytesToLength(eventFrame, BURST_CHUNK_BYTES * BURST_CHUNK_COUNT);
      for (let index: number = 0; index < BURST_CHUNK_COUNT; index += 1) {
        const chunkStart: number = index * BURST_CHUNK_BYTES;
        burstListener!(burstBytes.slice(chunkStart, chunkStart + BURST_CHUNK_BYTES));
      }
      await flushAsync();
      await waitForCondition((): boolean => factory.sockets[0].closeCalls === 1, 120, 'overflow closes first socket');
      await waitForCondition((): boolean => factory.connectCalls.length === 2, 120, 'overflow reconnect attempt');
      await secondServer.startHandshake();
      await waitForCondition((): boolean => client.state() === 'READY', 120, 'client ready after overflow reconnect');

      expect(listenerCalls).assertEqual(0);
      expect(factory.sockets[1].closeCalls).assertEqual(0);
      expect(secondServer.requests.length).assertEqual(1);
      expect(secondServer.requests[0].method).assertEqual('GET_SNAPSHOT');
    });

    it('cancelsBootstrapPendingAcrossReconnectAndIgnoresOldRetryTimeoutCallbacks', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const firstServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const secondServer = new TestServerHarness(11, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      firstServer.autoRespondToBootstrap = false;
      secondServer.autoRespondToBootstrap = false;
      const factory = new TestSocketFactory([
        new ConnectScenario(firstServer, null),
        new ConnectScenario(secondServer, null)
      ]);
      const randomChunks: Uint8Array[] = [
        decodeHex(CLIENT_NONCE_HEX),
        hexBytes(16, 0xe1),
        decodeHex(CLIENT_NONCE_HEX),
        hexBytes(16, 0xe2)
      ];
      for (let index: number = 0; index < 64; index += 1) {
        randomChunks.push(hexBytes(16, 0x20 + index));
      }
      const client = createClientFixture(factory, randomChunks, clock, scheduler);

      const connectPromise: Promise<void> = client.connect();
      await flushAsync();
      await firstServer.startHandshake();
      await waitForRequestCount(firstServer, 1, 'first attempt bootstrap request');
      const firstBootstrapRequest: VpnRpcBody = firstServer.requests[0];
      const firstRetryTask: ScheduledRunner = scheduler.tasks[scheduler.tasks.length - 2];
      const firstTimeoutTask: ScheduledRunner = scheduler.tasks[scheduler.tasks.length - 1];

      firstServer.signalClose();
      await flushAsync();
      await waitForCondition((): boolean => scheduler.tasks.length >= 4, 120, 'reconnect backoff scheduled');
      await scheduler.advanceAndRun(250);
      await waitForCondition((): boolean => factory.connectCalls.length === 2, 120, 'second connect call');
      await secondServer.startHandshake();
      await waitForRequestCount(secondServer, 1, 'second attempt bootstrap request');

      const secondBootstrapRequest: VpnRpcBody = secondServer.requests[0];
      expect(secondBootstrapRequest.requestId === firstBootstrapRequest.requestId).assertFalse();

      await firstRetryTask.run();
      await firstTimeoutTask.run();
      await flushAsync();

      expect(firstRetryTask.cancelable.canceled || firstRetryTask.ran).assertTrue();
      expect(firstTimeoutTask.cancelable.canceled || firstTimeoutTask.ran).assertTrue();
      expect(secondServer.requests.length).assertEqual(1);
      expect(secondServer.requests[0].requestId).assertEqual(secondBootstrapRequest.requestId ?? '');
      expect(secondServer.requests[0].requestOrdinal).assertEqual(secondBootstrapRequest.requestOrdinal ?? 0);
      expect(factory.connectCalls.length).assertEqual(2);

      await secondServer.respondSuccess(secondBootstrapRequest, buildRuntimePayload('RUNNING'));
      await connectPromise;
      expect(client.state()).assertEqual('READY');

      const pending: Promise<VpnRpcBody>[] = [];
      for (let index: number = 0; index < 64; index += 1) {
        pending.push(client.request('PING', createVpnRpcGuards(null, null, null), 0, createVpnRpcEmptyPayload()));
      }
      await flushAsync();
      await expectFailure(client.request('PING', createVpnRpcGuards(null, null, null), 0, createVpnRpcEmptyPayload()), 'COMMAND_BUSY');
      expect(pending.length).assertEqual(64);

      const closePromise: Promise<void> = client.close();
      await closePromise;
      await waitForRejectedPromises(pending);
    });

    it('failClosesOnWrongOrdinalAndDuplicateResponse', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const firstServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const secondServer = new TestServerHarness(13, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const thirdServer = new TestServerHarness(17, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(firstServer, null),
        new ConnectScenario(secondServer, null),
        new ConnectScenario(thirdServer, null)
      ]);
      const client = createClientFixture(
        factory,
        [
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xd1),
          hexBytes(16, 0xd2),
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xd3),
          hexBytes(16, 0xd4),
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xd5)
        ],
        clock,
        scheduler
      );
      await connectReady(client, firstServer);

      const wrongOrdinalRequest: Promise<VpnRpcBody> = client.request('PING', createVpnRpcGuards(null, null, null), 0, createVpnRpcEmptyPayload());
      await waitForRequestCount(firstServer, 2);
      await firstServer.respondWithWrongOrdinal(firstServer.requests[1]);
      await expectFailure(wrongOrdinalRequest, 'FRAME_INVALID');

      const reconnectAfterOrdinal: Promise<void> = client.connect();
      await flushAsync();
      await secondServer.startHandshake();
      await reconnectAfterOrdinal;

      const duplicateRequest: Promise<VpnRpcBody> = client.request('PING', createVpnRpcGuards(null, null, null), 0, createVpnRpcEmptyPayload());
      await waitForRequestCount(secondServer, 2);
      await secondServer.respondDuplicate(secondServer.requests[1]);
      const duplicateResponse: VpnRpcBody = await duplicateRequest;
      expect(duplicateResponse.method).assertEqual('PING');
      await waitForCondition((): boolean => factory.sockets[1].closeCalls === 1, 120);
      await waitForCondition((): boolean => factory.connectCalls.length === 3, 120);

      const reconnectAfterDuplicate: Promise<void> = client.connect();
      await flushAsync();
      await thirdServer.startHandshake();
      await reconnectAfterDuplicate;
      expect(client.state()).assertEqual('READY');
    });

    it('replacesRememberedDelayAcrossJobGenerationAndGuardChangesRefreshesLatestContextAndDrainsClose', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const firstServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const secondServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(firstServer, null),
        new ConnectScenario(secondServer, null)
      ]);
      const client = createClientFixture(
        factory,
        [
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0x81),
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0x82),
          hexBytes(16, 0x83),
          hexBytes(16, 0x84)
        ],
        clock,
        scheduler
      );
      const seenEvents: string[] = [];
      const nextGuards: VpnRpcGuards = alternateGuards();
      const listener: VpnRpcEventListener = (event: VpnRpcBody): void => {
        let suffix: string = '';
        if (event.method === 'DELAY_CHANGED') {
          suffix = `:${encodeVpnRpcBodyToText(event.payload)}`;
        }
        seenEvents.push(`${event.method}:${event.sessionGeneration}${suffix}`);
      };
      client.subscribe(listener);
      await connectReady(client, firstServer);
      await firstServer.sendRuntimeEvent(buildRuntimePayload('RUNNING'), 4, activeGuards());
      await firstServer.sendDelayEvent(buildDelayPayload(JOB_ID, 10, 'RUNNING'), 4, activeGuards());
      await firstServer.sendDelayEvent(buildDelayPayload(JOB_ID_NEXT, 1, 'RUNNING'), 4, activeGuards());
      await firstServer.sendDelayEvent(buildDelayPayload(JOB_ID_NEXT, 1, 'RUNNING'), 4, activeGuards());
      await firstServer.sendDelayEvent(buildDelayPayload(JOB_ID_THIRD, 1, 'RUNNING'), 5, nextGuards);
      await waitForCondition((): boolean => seenEvents.length === 4);
      expect(seenEvents[0]).assertEqual('RUNTIME_CHANGED:4');
      expect(seenEvents[1].includes(`"jobId":"${JOB_ID}"`)).assertTrue();
      expect(seenEvents[2].includes(`"jobId":"${JOB_ID_NEXT}"`)).assertTrue();
      expect(seenEvents[3].startsWith('DELAY_CHANGED:5:')).assertTrue();
      expect(seenEvents[3].includes(`"jobId":"${JOB_ID_THIRD}"`)).assertTrue();

      firstServer.signalClose();
      const reconnectPromise: Promise<void> = client.connect();
      await flushAsync();
      await secondServer.startHandshake();
      await reconnectPromise;
      await waitForRequestCount(secondServer, 2);
      expect(secondServer.requests[1].method).assertEqual('READ_DELAY_TEST');
      expect(secondServer.requests[1].sessionGeneration).assertEqual(5);
      expect(secondServer.requests[1].guards.profileHash).assertEqual(PROFILE_HASH_NEXT);
      expect(encodeVpnRpcBodyToText(secondServer.requests[1]).includes(`"jobId":"${JOB_ID_THIRD}"`)).assertTrue();
      await secondServer.respondSuccess(secondServer.requests[1], buildDelayPayload(JOB_ID_THIRD, 1, 'RUNNING'));
      await waitForCondition((): boolean => client.snapshot().state === 'RUNNING');

      const closePromise: Promise<void> = client.close();
      await waitForRequestCount(secondServer, 3);
      expect(secondServer.requests[2].method).assertEqual('CANCEL_DELAY_TEST');
      expect(secondServer.requests[2].sessionGeneration).assertEqual(5);
      expect(secondServer.requests[2].guards.profileHash).assertEqual(PROFILE_HASH_NEXT);
      expect(encodeVpnRpcBodyToText(secondServer.requests[2]).includes(`"jobId":"${JOB_ID_THIRD}"`)).assertTrue();
      await secondServer.respondSuccess(secondServer.requests[2], buildDelayPayload(JOB_ID_THIRD, 2, 'CANCELLED'));
      await closePromise;
      expect(client.state()).assertEqual('CLOSED');
      expect(factory.sockets[1].closeCalls).assertEqual(1);
    });

    it('suppressesStaleTerminalDelayFromOldContextAndKeepsLatestLiveJobAuthoritativeAcrossReconnectAndClose', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const firstServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const secondServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(firstServer, null),
        new ConnectScenario(secondServer, null)
      ]);
      const client = createClientFixture(
        factory,
        [
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xa1),
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xa2),
          hexBytes(16, 0xa3),
          hexBytes(16, 0xa4)
        ],
        clock,
        scheduler
      );
      const inspectable: InspectableClient = inspectClient(client);
      const nextGuards: VpnRpcGuards = alternateGuards();
      const seenEvents: string[] = [];
      client.subscribe((event: VpnRpcBody): void => {
        if (event.method === 'DELAY_CHANGED') {
          seenEvents.push(`${event.method}:${event.sessionGeneration}:${encodeVpnRpcBodyToText(event.payload)}`);
          return;
        }
        seenEvents.push(`${event.method}:${event.sessionGeneration}`);
      });

      await connectReady(client, firstServer);
      await firstServer.sendRuntimeEvent(buildRuntimePayload('RUNNING'), 4, activeGuards());
      await waitForCondition((): boolean => (client.activeContext()?.sessionGeneration ?? 0) === 4, 120, 'seeded context A');
      await firstServer.sendDelayEvent(buildDelayPayload(JOB_ID, 10, 'RUNNING'), 4, activeGuards());
      await waitForCondition((): boolean => inspectable.rememberedDelay?.jobId === JOB_ID, 120, 'remembered job A');
      await firstServer.sendDelayEvent(buildDelayPayload(JOB_ID_NEXT, 1, 'RUNNING'), 5, nextGuards);
      await waitForCondition((): boolean => inspectable.rememberedDelay?.jobId === JOB_ID_NEXT, 120, 'remembered job B');
      await waitForCondition((): boolean => (client.activeContext()?.sessionGeneration ?? 0) === 5, 120, 'authoritative context B');

      await firstServer.sendDelayEvent(buildDelayPayload(JOB_ID, 11, 'CANCELLED'), 4, activeGuards());
      await flushAsync();

      expect(seenEvents.length).assertEqual(3);
      expect(seenEvents[0]).assertEqual('RUNTIME_CHANGED:4');
      expect(seenEvents[1].includes(`"jobId":"${JOB_ID}"`)).assertTrue();
      expect(seenEvents[2].startsWith('DELAY_CHANGED:5:')).assertTrue();
      expect(seenEvents[2].includes(`"jobId":"${JOB_ID_NEXT}"`)).assertTrue();
      expect(client.activeContext()?.sessionGeneration ?? 0).assertEqual(5);
      expect(client.activeContext()?.guards.profileHash ?? '').assertEqual(PROFILE_HASH_NEXT);
      expect(inspectable.rememberedDelay?.jobId ?? '').assertEqual(JOB_ID_NEXT);
      expect(inspectable.rememberedDelay?.generation ?? 0).assertEqual(5);
      expect(inspectable.rememberedDelay?.guards.profileHash ?? '').assertEqual(PROFILE_HASH_NEXT);
      expect(inspectable.rememberedDelay?.delayRevision ?? 0).assertEqual(1);

      firstServer.signalClose();
      const reconnectPromise: Promise<void> = client.connect();
      await flushAsync();
      await secondServer.startHandshake();
      await reconnectPromise;
      await waitForRequestCount(secondServer, 2);
      expect(secondServer.requests[1].method).assertEqual('READ_DELAY_TEST');
      expect(secondServer.requests[1].sessionGeneration).assertEqual(5);
      expect(secondServer.requests[1].guards.profileHash).assertEqual(PROFILE_HASH_NEXT);
      expect(encodeVpnRpcBodyToText(secondServer.requests[1]).includes(`"jobId":"${JOB_ID_NEXT}"`)).assertTrue();
      await secondServer.respondSuccess(secondServer.requests[1], buildDelayPayload(JOB_ID_NEXT, 1, 'RUNNING'));

      const closePromise: Promise<void> = client.close();
      await waitForRequestCount(secondServer, 3);
      expect(secondServer.requests[2].method).assertEqual('CANCEL_DELAY_TEST');
      expect(secondServer.requests[2].sessionGeneration).assertEqual(5);
      expect(secondServer.requests[2].guards.profileHash).assertEqual(PROFILE_HASH_NEXT);
      expect(encodeVpnRpcBodyToText(secondServer.requests[2]).includes(`"jobId":"${JOB_ID_NEXT}"`)).assertTrue();
      await secondServer.respondSuccess(secondServer.requests[2], buildDelayPayload(JOB_ID_NEXT, 2, 'CANCELLED'));
      await closePromise;

      expect(inspectable.rememberedDelay === null).assertTrue();
      expect(client.state()).assertEqual('CLOSED');
      expect(secondServer.requests.length).assertEqual(3);
      expect(factory.sockets[1].closeCalls).assertEqual(1);
    });

    it('doesNotCaptureContextFromMismatchedResponsesOrTrailingDuplicateFrames', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const firstServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const secondServer = new TestServerHarness(11, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const thirdServer = new TestServerHarness(13, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(firstServer, null),
        new ConnectScenario(secondServer, null),
        new ConnectScenario(thirdServer, null)
      ]);
      const client = createClientFixture(
        factory,
        [
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xd1),
          hexBytes(16, 0xd2),
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xd3),
          hexBytes(16, 0xd4),
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xd5)
        ],
        clock,
        scheduler
      );
      const inspectable: InspectableClient = inspectClient(client);
      const nextGuards: VpnRpcGuards = alternateGuards();
      await connectReady(client, firstServer);
      await firstServer.sendRuntimeEvent(buildRuntimePayload('RUNNING'), 4, activeGuards());
      await waitForCondition((): boolean => (client.activeContext()?.sessionGeneration ?? 0) === 4, 120, 'active context seeded');
      expect(client.activeContext()?.sessionGeneration ?? 0).assertEqual(4);
      expect(client.activeContext()?.guards.profileHash ?? '').assertEqual(PROFILE_HASH);

      const wrongOrdinalRequest: Promise<VpnRpcBody> = client.request(
        'READ_DELAY_TEST',
        activeGuards(),
        4,
        createVpnRpcDelayJobRequestPayload(JOB_ID)
      );
      await waitForRequestCount(firstServer, 2);
      await firstServer.respondWithWrongOrdinalAndContext(
        firstServer.requests[1],
        buildDelayPayload(JOB_ID_NEXT, 1, 'RUNNING'),
        5,
        nextGuards
      );
      await expectFailure(wrongOrdinalRequest, 'FRAME_INVALID');
      expect(client.activeContext()).assertNull();

      const reconnectAfterOrdinal: Promise<void> = client.connect();
      await flushAsync();
      await secondServer.startHandshake();
      await reconnectAfterOrdinal;
      await secondServer.sendRuntimeEvent(buildRuntimePayload('RUNNING'), 4, activeGuards());
      await waitForCondition((): boolean => (client.activeContext()?.sessionGeneration ?? 0) === 4, 120, 'post-reconnect active context');

      const duplicateRequest: Promise<VpnRpcBody> = client.request(
        'READ_DELAY_TEST',
        activeGuards(),
        4,
        createVpnRpcDelayJobRequestPayload(JOB_ID)
      );
      await waitForRequestCount(secondServer, 2);
      await secondServer.respondDuplicateWithTrailingContext(
        secondServer.requests[1],
        buildDelayPayload(JOB_ID, 2, 'RUNNING'),
        buildDelayPayload(JOB_ID_NEXT, 1, 'RUNNING'),
        6,
        nextGuards
      );
      const duplicateResponse: VpnRpcBody = await duplicateRequest;
      expect(duplicateResponse.method).assertEqual('READ_DELAY_TEST');
      await waitForCondition((): boolean => factory.sockets[1].closeCalls === 1, 120, 'duplicate frame closes second socket');
      expect(client.activeContext()).assertNull();

      const reconnectAfterDuplicate: Promise<void> = client.connect();
      await flushAsync();
      await thirdServer.startHandshake();
      await reconnectAfterDuplicate;
      expect(client.state()).assertEqual('READY');
      expect(client.activeContext()?.sessionGeneration ?? 0).assertEqual(0);
      expect(client.activeContext()?.guards.profileHash ?? '').assertEqual(PROFILE_HASH);
    });

    it('keepsCloseIdempotentAndUnsubscribesSocketCallbacksExactlyOnce', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const server = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([new ConnectScenario(server, null)]);
      const client = createClientFixture(factory, [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0x91)], clock, scheduler);
      await connectReady(client, server);

      const firstClose: Promise<void> = client.close();
      const secondClose: Promise<void> = client.close();
      await firstClose;
      await secondClose;

      expect(factory.sockets[0].unsubscribedDataIds.length).assertEqual(1);
      expect(factory.sockets[0].unsubscribedCloseIds.length).assertEqual(1);
      expect(factory.sockets[0].unsubscribedErrorIds.length).assertEqual(1);
      expect(factory.sockets[0].closeCalls).assertEqual(1);
      expect(client.snapshot().state).assertEqual('RECOVERING');
    });

    it('capturesCallerOwnedActiveContextFromBootstrapAndClearsItOnStoppedBootstrap', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const runningServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const stoppedServer = new TestServerHarness(9, buildRuntimePayload('STOPPED'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(runningServer, null),
        new ConnectScenario(stoppedServer, null)
      ]);
      const client = createClientFixture(
        factory,
        [decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0xb1), decodeHex(CLIENT_NONCE_HEX), hexBytes(16, 0xb2)],
        clock,
        scheduler
      );

      await connectReady(client, runningServer);
      const activeContext = client.activeContext();
      expect(activeContext === null).assertFalse();
      expect(activeContext?.sessionGeneration ?? -1).assertEqual(0);
      expect(activeContext?.guards.profileHash ?? '').assertEqual(PROFILE_HASH);
      expect(activeContext?.guards.revisionHash ?? '').assertEqual(REVISION_HASH);
      expect(activeContext?.guards.catalogDigest ?? '').assertEqual(CATALOG_DIGEST);

      activeContext!.sessionGeneration = 44;
      activeContext!.guards.profileHash = PROFILE_HASH_NEXT;
      const freshContext = client.activeContext();
      expect(freshContext?.sessionGeneration ?? -1).assertEqual(0);
      expect(freshContext?.guards.profileHash ?? '').assertEqual(PROFILE_HASH);

      runningServer.signalClose();
      expect(client.activeContext()).assertNull();
      const reconnectPromise: Promise<void> = client.connect();
      await flushAsync();
      await stoppedServer.startHandshake();
      await reconnectPromise;
      expect(client.activeContext()).assertNull();
    });

    it('promotesBootstrapContextGenerationOnFirstActiveRequestAndRefreshesItAcrossReconnect', 0, async () => {
      const clock: ManualClockPort = new ManualClockPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort(clock);
      const firstServer = new TestServerHarness(7, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const secondServer = new TestServerHarness(9, buildRuntimePayload('RUNNING'), [decodeHex(SERVER_NONCE_HEX), decodeHex(SERVER_INSTANCE_HEX)], clock);
      const factory = new TestSocketFactory([
        new ConnectScenario(firstServer, null),
        new ConnectScenario(secondServer, null)
      ]);
      const client = createClientFixture(
        factory,
        [
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xc1),
          hexBytes(16, 0xc2),
          decodeHex(CLIENT_NONCE_HEX),
          hexBytes(16, 0xc3),
          hexBytes(16, 0xc4)
        ],
        clock,
        scheduler
      );

      await connectReady(client, firstServer);
      const bootstrapContext = client.activeContext();
      expect(bootstrapContext?.sessionGeneration ?? -1).assertEqual(0);

      const requestPromise: Promise<VpnRpcBody> = client.request('QUERY_GROUPS', activeGuards(), 1, createVpnRpcEmptyPayload());
      await waitForRequestCount(firstServer, 2);
      expect(firstServer.requests[1].sessionGeneration).assertEqual(1);
      await firstServer.respondSuccess(firstServer.requests[1], createVpnRpcQueryGroupsPayload(1, []));
      await requestPromise;

      const promotedContext = client.activeContext();
      expect(promotedContext?.sessionGeneration ?? -1).assertEqual(1);
      expect(promotedContext?.guards.profileHash ?? '').assertEqual(PROFILE_HASH);

      firstServer.signalClose();
      expect(client.activeContext()).assertNull();
      secondServer.autoRespondToBootstrap = false;
      const reconnectPromise: Promise<void> = client.connect();
      await flushAsync();
      await secondServer.startHandshake();
      await waitForRequestCount(secondServer, 1);
      await secondServer.respondSuccessWithEnvelope(
        secondServer.requests[0],
        buildRuntimePayload('RUNNING'),
        1,
        createVpnRpcGuards(null, null, null)
      );
      await reconnectPromise;
      await waitForCondition((): boolean => (client.activeContext()?.sessionGeneration ?? -1) === 1, 120, 'refreshed bootstrap context');
      const refreshedContext = client.activeContext();
      expect(refreshedContext?.sessionGeneration ?? -1).assertEqual(1);
      expect(refreshedContext?.guards.profileHash ?? '').assertEqual(PROFILE_HASH);
    });
  });
}
