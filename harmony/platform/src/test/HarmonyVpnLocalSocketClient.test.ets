import { describe, expect, it } from '@ohos/hypium';
import {
  createVpnRpcSocketFailure,
  VpnRpcSocketFailure,
  type VpnRpcSocketFailureCode,
  type VpnRpcSocketConnectionPort
} from '@cmfa/shared';
import {
  HarmonyVpnLocalSocketClient,
  HarmonyVpnLocalSocketConnectionAdapter,
  type HarmonyVpnLocalSocketClientDriver,
  type HarmonyVpnLocalSocketClientDriverFactory,
  type HarmonyVpnLocalSocketConnectOptionsPort,
  type HarmonyVpnLocalSocketConnectionDriver,
  type HarmonyVpnLocalSocketMessageInfoPort,
  type HarmonyVpnLocalSocketSendOptionsPort
} from '../main/ets/vpn/HarmonyVpnLocalSocketClient';

const FILES_DIR: string = '/sandbox/shared/files';

class DeferredVoid {
  readonly promise: Promise<void>;
  private readonly resolveFn: () => void;

  constructor() {
    let resolveRef: (() => void) | undefined = undefined;
    this.promise = new Promise<void>((resolve: () => void): void => {
      resolveRef = resolve;
    });
    this.resolveFn = (): void => {
      resolveRef?.();
    };
  }

  resolve(): void {
    this.resolveFn();
  }
}

class FakeBusinessError extends Error {
  readonly code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

class LocalSocketSendOptionsRecord implements HarmonyVpnLocalSocketSendOptionsPort {
  readonly data: ArrayBuffer;

  constructor(data: ArrayBuffer) {
    this.data = data;
  }
}

class LocalSocketConnectOptionsRecord implements HarmonyVpnLocalSocketConnectOptionsPort {
  readonly address: string;
  readonly timeoutMs: number;

  constructor(address: string, timeoutMs: number) {
    this.address = address;
    this.timeoutMs = timeoutMs;
  }
}

class LocalSocketMessageInfoRecord implements HarmonyVpnLocalSocketMessageInfoPort {
  readonly message: ArrayBuffer;
  readonly size: number;
  readonly address?: string;

  constructor(message: ArrayBuffer, size: number, address?: string) {
    this.message = message;
    this.size = size;
    this.address = address;
  }
}

class RecordingClientDriverFactory implements HarmonyVpnLocalSocketClientDriverFactory {
  readonly sockets: RecordingClientDriver[] = [];

  create(): HarmonyVpnLocalSocketClientDriver {
    const socket = new RecordingClientDriver();
    this.sockets.push(socket);
    return socket;
  }
}

class FixedClientDriverFactory implements HarmonyVpnLocalSocketClientDriverFactory {
  readonly socket: RecordingClientDriver;

  constructor(socket: RecordingClientDriver) {
    this.socket = socket;
  }

  create(): HarmonyVpnLocalSocketClientDriver {
    return this.socket;
  }
}

class ThrowingClientDriverFactory implements HarmonyVpnLocalSocketClientDriverFactory {
  readonly error: Error;

  constructor(error: Error) {
    this.error = error;
  }

  create(): HarmonyVpnLocalSocketClientDriver {
    throw this.error;
  }
}

class RecordingClientDriver implements HarmonyVpnLocalSocketClientDriver {
  readonly connectOptions: LocalSocketConnectOptionsRecord[] = [];
  readonly sendSnapshots: Uint8Array[] = [];
  readonly sendBuffers: ArrayBuffer[] = [];
  readonly offCalls: string[] = [];
  readonly onCalls: string[] = [];
  connectErrorCode: number = 0;
  sendError?: Error;
  closeError?: Error;
  sendDeferreds: DeferredVoid[] = [];
  closeCalls: number = 0;
  private readonly messageListeners: Array<(info: HarmonyVpnLocalSocketMessageInfoPort) => void> = [];
  private readonly closeListeners: Array<() => void> = [];
  private readonly errorListeners: Array<() => void> = [];
  private readonly connectListeners: Array<() => void> = [];

  async connect(options: HarmonyVpnLocalSocketConnectOptionsPort): Promise<void> {
    this.connectOptions.push(new LocalSocketConnectOptionsRecord(options.address, options.timeoutMs));
    if (this.connectErrorCode !== 0) {
      throw new FakeBusinessError(this.connectErrorCode, 'recorded client connect failure');
    }
    for (let index: number = 0; index < this.connectListeners.length; index += 1) {
      this.connectListeners[index]();
    }
  }

  async send(options: HarmonyVpnLocalSocketSendOptionsPort): Promise<void> {
    this.sendBuffers.push(options.data);
    this.sendSnapshots.push(copyArrayBuffer(options.data));
    const deferred: DeferredVoid | undefined = this.sendDeferreds.shift();
    if (deferred !== undefined) {
      await deferred.promise;
    }
    if (this.sendError !== undefined) {
      throw this.sendError;
    }
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
    if (this.closeError !== undefined) {
      throw this.closeError;
    }
  }

  onMessage(callback: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void {
    this.onCalls.push('message');
    this.messageListeners.push(callback);
  }

  offMessage(callback?: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void {
    this.offCalls.push('message');
    removeMessageListener(this.messageListeners, callback);
  }

  onClose(callback: () => void): void {
    this.onCalls.push('close');
    this.closeListeners.push(callback);
  }

  offClose(callback?: () => void): void {
    this.offCalls.push('close');
    removeVoidListener(this.closeListeners, callback);
  }

  onError(callback: () => void): void {
    this.onCalls.push('error');
    this.errorListeners.push(callback);
  }

  offError(callback?: () => void): void {
    this.offCalls.push('error');
    removeVoidListener(this.errorListeners, callback);
  }

  onConnect(callback: () => void): void {
    this.onCalls.push('connect');
    this.connectListeners.push(callback);
  }

  offConnect(callback?: () => void): void {
    this.offCalls.push('connect');
    removeVoidListener(this.connectListeners, callback);
  }
}

class RecordingConnectionDriver implements HarmonyVpnLocalSocketConnectionDriver {
  readonly sendSnapshots: Uint8Array[] = [];
  readonly sendBuffers: ArrayBuffer[] = [];
  readonly offCalls: string[] = [];
  readonly onCalls: string[] = [];
  sendError?: Error;
  closeError?: Error;
  closeCalls: number = 0;
  private readonly messageListeners: Array<(info: HarmonyVpnLocalSocketMessageInfoPort) => void> = [];
  private readonly closeListeners: Array<() => void> = [];
  private readonly errorListeners: Array<() => void> = [];

  async send(options: HarmonyVpnLocalSocketSendOptionsPort): Promise<void> {
    this.sendBuffers.push(options.data);
    this.sendSnapshots.push(copyArrayBuffer(options.data));
    if (this.sendError !== undefined) {
      throw this.sendError;
    }
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
    if (this.closeError !== undefined) {
      throw this.closeError;
    }
  }

  onMessage(callback: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void {
    this.onCalls.push('message');
    this.messageListeners.push(callback);
  }

  offMessage(callback?: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void {
    this.offCalls.push('message');
    removeMessageListener(this.messageListeners, callback);
  }

  onClose(callback: () => void): void {
    this.onCalls.push('close');
    this.closeListeners.push(callback);
  }

  offClose(callback?: () => void): void {
    this.offCalls.push('close');
    removeVoidListener(this.closeListeners, callback);
  }

  onError(callback: () => void): void {
    this.onCalls.push('error');
    this.errorListeners.push(callback);
  }

  offError(callback?: () => void): void {
    this.offCalls.push('error');
    removeVoidListener(this.errorListeners, callback);
  }

  emitMessage(bytes: Uint8Array, size: number, address?: string): void {
    const info = new LocalSocketMessageInfoRecord(copyToArrayBuffer(bytes), size, address);
    for (let index: number = 0; index < this.messageListeners.length; index += 1) {
      this.messageListeners[index](info);
    }
  }

  emitClose(): void {
    for (let index: number = 0; index < this.closeListeners.length; index += 1) {
      this.closeListeners[index]();
    }
  }

  emitError(): void {
    for (let index: number = 0; index < this.errorListeners.length; index += 1) {
      this.errorListeners[index]();
    }
  }
}

async function flushAsyncTurns(turns: number = 4): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

function removeMessageListener(
  items: Array<(info: HarmonyVpnLocalSocketMessageInfoPort) => void>,
  callback?: (info: HarmonyVpnLocalSocketMessageInfoPort) => void
): void {
  if (callback === undefined) {
    items.length = 0;
    return;
  }
  const index: number = items.indexOf(callback);
  if (index >= 0) {
    items.splice(index, 1);
  }
}

function removeVoidListener(items: Array<() => void>, callback?: () => void): void {
  if (callback === undefined) {
    items.length = 0;
    return;
  }
  const index: number = items.indexOf(callback);
  if (index >= 0) {
    items.splice(index, 1);
  }
}

function copyArrayBuffer(buffer: ArrayBuffer): Uint8Array {
  return new Uint8Array(buffer.slice(0));
}

function copyToArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new ArrayBuffer(bytes.length);
  new Uint8Array(copy).set(bytes);
  return copy;
}

function bytesToCsv(bytes: Uint8Array): string {
  const values: string[] = [];
  for (let index: number = 0; index < bytes.length; index += 1) {
    values.push(`${bytes[index]}`);
  }
  return values.join(',');
}

function requireSocketFailure(error: Error): VpnRpcSocketFailure {
  if (error instanceof VpnRpcSocketFailure) {
    return error;
  }
  throw new Error('Expected VpnRpcSocketFailure.');
}

function expectSocketFailure(
  error: Error,
  code: VpnRpcSocketFailureCode,
  message: string,
  retryable: boolean
): void {
  const failure = requireSocketFailure(error);
  expect(failure.code).assertEqual(code);
  expect(failure.message).assertEqual(message);
  expect(failure.retryable).assertEqual(retryable);
}

async function expectSocketFailureAsync(
  runner: () => Promise<void | VpnRpcSocketConnectionPort>,
  code: VpnRpcSocketFailureCode
): Promise<void> {
  try {
    await runner();
    expect(false).assertTrue();
  } catch (error) {
    const expected = createVpnRpcSocketFailure(code);
    const failure = error instanceof Error ? error : new Error('Expected Error.');
    expectSocketFailure(failure, code, expected.message, expected.retryable);
  }
}

export default function harmonyVpnLocalSocketClientTestsuite() {
  describe('HarmonyVpnLocalSocketClientTest', () => {
    it('connectsWithResolvedAbsoluteAddressAndTimeoutAndMapsConnectRefused', 0, async () => {
      const factory = new RecordingClientDriverFactory();
      const client: HarmonyVpnLocalSocketClient = new HarmonyVpnLocalSocketClient(factory, FILES_DIR);
      const connection: VpnRpcSocketConnectionPort = await client.connect('cmfa_vpn_rpc_v1_exact', 2500);
      const socket: RecordingClientDriver = factory.sockets[0];

      expect(socket.connectOptions.length).assertEqual(1);
      expect(socket.connectOptions[0].address).assertEqual('/sandbox/shared/files/cmfa_vpn_rpc_v1_exact');
      expect(socket.connectOptions[0].timeoutMs).assertEqual(2500);
      expect(connection instanceof HarmonyVpnLocalSocketConnectionAdapter).assertTrue();

      const refusedSocket = new RecordingClientDriver();
      refusedSocket.connectErrorCode = 2301111;
      const refusedClient: HarmonyVpnLocalSocketClient = new HarmonyVpnLocalSocketClient(
        new FixedClientDriverFactory(refusedSocket),
        FILES_DIR
      );

      await expectSocketFailureAsync(
        (): Promise<VpnRpcSocketConnectionPort> => refusedClient.connect('cmfa_vpn_rpc_v1_exact', 2500),
        'CONNECT_REFUSED'
      );
      expect(refusedSocket.closeCalls).assertEqual(1);
    });

    it('mapsConstructAndValidationFailuresToPlatformFailureWithoutLeakingRawDetails', 0, async () => {
      const invalidFactory = new RecordingClientDriverFactory();
      const invalidClient: HarmonyVpnLocalSocketClient = new HarmonyVpnLocalSocketClient(invalidFactory);
      await expectSocketFailureAsync(
        (): Promise<VpnRpcSocketConnectionPort> => invalidClient.connect('', 0),
        'PLATFORM_FAILED'
      );
      expect(invalidFactory.sockets.length).assertEqual(0);

      const relativeBaseFactory = new RecordingClientDriverFactory();
      const relativeBaseClient: HarmonyVpnLocalSocketClient = new HarmonyVpnLocalSocketClient(relativeBaseFactory, 'sandbox/shared/files');
      await expectSocketFailureAsync(
        (): Promise<VpnRpcSocketConnectionPort> => relativeBaseClient.connect('cmfa_vpn_rpc_v1_exact', 1),
        'PLATFORM_FAILED'
      );
      expect(relativeBaseFactory.sockets.length).assertEqual(0);

      const traversalFactory = new RecordingClientDriverFactory();
      const traversalClient: HarmonyVpnLocalSocketClient = new HarmonyVpnLocalSocketClient(traversalFactory, FILES_DIR);
      await expectSocketFailureAsync(
        (): Promise<VpnRpcSocketConnectionPort> => traversalClient.connect('../escape', 1),
        'PLATFORM_FAILED'
      );
      expect(traversalFactory.sockets.length).assertEqual(0);

      const thrown = new Error('construct secret failed');
      const constructClient: HarmonyVpnLocalSocketClient = new HarmonyVpnLocalSocketClient(new ThrowingClientDriverFactory(thrown));

      await expectSocketFailureAsync(
        (): Promise<VpnRpcSocketConnectionPort> => constructClient.connect('cmfa_vpn_rpc_v1_exact', 1),
        'PLATFORM_FAILED'
      );
    });

    it('copiesExactUint8ArraySlicesForSendAndSerializesConcurrentWritesWithoutMutatingInputs', 0, async () => {
      const factory = new RecordingClientDriverFactory();
      const client: HarmonyVpnLocalSocketClient = new HarmonyVpnLocalSocketClient(factory);
      const connection: VpnRpcSocketConnectionPort = await client.connect('cmfa_vpn_rpc_v1_send', 1);
      const socket: RecordingClientDriver = factory.sockets[0];
      const firstDeferred = new DeferredVoid();
      const secondDeferred = new DeferredVoid();
      socket.sendDeferreds.push(firstDeferred, secondDeferred);
      const source = new Uint8Array([91, 1, 2, 3, 92]);
      const secondSource = new Uint8Array([81, 4, 5, 6, 82]);

      const firstSend = connection.send(source.subarray(1, 4));
      const secondSend = connection.send(secondSource.subarray(1, 4));
      source[1] = 77;
      secondSource[2] = 88;
      await flushAsyncTurns();

      expect(socket.sendSnapshots.length).assertEqual(1);
      expect(bytesToCsv(socket.sendSnapshots[0])).assertEqual('1,2,3');
      firstDeferred.resolve();
      await flushAsyncTurns(8);
      expect(socket.sendSnapshots.length).assertEqual(2);
      expect(bytesToCsv(socket.sendSnapshots[1])).assertEqual('4,5,6');
      secondDeferred.resolve();
      await Promise.all([firstSend, secondSend]);
      expect(bytesToCsv(source)).assertEqual('91,77,2,3,92');
      expect(bytesToCsv(secondSource)).assertEqual('81,4,88,6,82');
    });

    it('mapsSendFailureAndRejectsWritesAfterClose', 0, async () => {
      const factory = new RecordingClientDriverFactory();
      const client: HarmonyVpnLocalSocketClient = new HarmonyVpnLocalSocketClient(factory);
      const connection: VpnRpcSocketConnectionPort = await client.connect('cmfa_vpn_rpc_v1_send', 1);
      const socket: RecordingClientDriver = factory.sockets[0];
      socket.sendError = new Error('raw send failed');

      await expectSocketFailureAsync(
        (): Promise<void> => connection.send(new Uint8Array([1, 2, 3])),
        'SEND_FAILED'
      );

      socket.sendError = undefined;
      await connection.close();
      await expectSocketFailureAsync(
        (): Promise<void> => connection.send(new Uint8Array([4, 5, 6])),
        'CLOSED'
      );
    });

    it('maintainsListenerLifecycleAndIsolatesMutationsAndThrownCallbacks', 0, async () => {
      const socket = new RecordingConnectionDriver();
      const connection: HarmonyVpnLocalSocketConnectionAdapter = new HarmonyVpnLocalSocketConnectionAdapter(socket);
      const received: string[] = [];
      let secondId: number = 0;
      const firstId = connection.subscribeData((bytes: Uint8Array): void => {
        received.push(`first:${bytesToCsv(bytes)}`);
        connection.unsubscribeData(secondId);
        throw new Error('ignored listener throw');
      });
      secondId = connection.subscribeData((bytes: Uint8Array): void => {
        received.push(`second:${bytesToCsv(bytes)}`);
      });
      const closeId = connection.subscribeClose((): void => {
        received.push('close');
      });
      const errorId = connection.subscribeError((): void => {
        received.push('error');
      });

      expect(firstId).assertEqual(1);
      expect(secondId).assertEqual(2);
      expect(closeId).assertEqual(3);
      expect(errorId).assertEqual(4);

      socket.emitMessage(new Uint8Array([9, 8, 7, 6]), 3, 'secret-address');
      socket.emitMessage(new Uint8Array([5, 4, 3]), 2, 'ignored-again');
      connection.unsubscribeData(999);
      connection.unsubscribeData(secondId);
      connection.unsubscribeClose(999);
      connection.unsubscribeError(999);

      expect(received.join('|')).assertEqual('first:9,8,7|second:9,8,7|first:5,4');
      socket.emitError();
      socket.emitClose();
      socket.emitMessage(new Uint8Array([1, 1, 1]), 3, 'after-close');
      expect(received.join('|')).assertEqual('first:9,8,7|second:9,8,7|first:5,4|error|close');
    });

    it('treatsMalformedMessageSizeAsTerminalAndMakesCloseIdempotent', 0, async () => {
      const socket = new RecordingConnectionDriver();
      const connection: HarmonyVpnLocalSocketConnectionAdapter = new HarmonyVpnLocalSocketConnectionAdapter(socket);
      let closeCount = 0;
      let errorCount = 0;
      connection.subscribeClose((): void => {
        closeCount += 1;
      });
      connection.subscribeError((): void => {
        errorCount += 1;
      });

      socket.emitMessage(new Uint8Array([1, 2, 3]), 9, 'raw-address-should-not-leak');
      socket.emitClose();
      socket.emitError();
      await connection.close();
      await connection.close();

      expect(errorCount).assertEqual(1);
      expect(closeCount).assertEqual(1);
      expect(socket.closeCalls).assertEqual(1);
      expect(socket.offCalls.join(',')).assertEqual('message,close,error');
    });
  });
}
