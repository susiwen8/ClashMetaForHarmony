import { describe, expect, it } from '@ohos/hypium';
import {
  createVpnRpcSocketFailure,
  VpnRpcSocketFailure,
  type VpnRpcSocketConnectionPort,
  type VpnRpcSocketFailureCode
} from '@cmfa/shared';
import {
  type HarmonyVpnLocalSocketConnectionDriver,
  type HarmonyVpnLocalSocketMessageInfoPort,
  type HarmonyVpnLocalSocketSendOptionsPort
} from '../main/ets/vpn/HarmonyVpnLocalSocketClient';
import {
  HarmonyVpnLocalSocketServer,
  type HarmonyVpnLocalSocketServerDriver,
  type HarmonyVpnLocalSocketServerDriverFactory
} from '../main/ets/vpn/HarmonyVpnLocalSocketServer';

const FILES_DIR: string = '/sandbox/shared/files';

class DeferredVoid {
  readonly promise: Promise<void>;
  private readonly resolveFn: () => void;
  private readonly rejectFn: (error: Error) => void;

  constructor() {
    let resolveRef: (() => void) | undefined = undefined;
    let rejectRef: ((error: Error) => void) | undefined = undefined;
    this.promise = new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      resolveRef = resolve;
      rejectRef = reject;
    });
    this.resolveFn = (): void => {
      resolveRef?.();
    };
    this.rejectFn = (error: Error): void => {
      rejectRef?.(error);
    };
  }

  resolve(): void {
    this.resolveFn();
  }

  reject(error: Error): void {
    this.rejectFn(error);
  }
}

class FakeBusinessError extends Error {
  readonly code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

class RecordingConnectionDriver implements HarmonyVpnLocalSocketConnectionDriver {
  closeCalls: number = 0;
  closeDeferred?: DeferredVoid;

  async send(_: HarmonyVpnLocalSocketSendOptionsPort): Promise<void> {
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
    if (this.closeDeferred !== undefined) {
      await this.closeDeferred.promise;
    }
  }

  onMessage(_: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void {
  }

  offMessage(_: ((info: HarmonyVpnLocalSocketMessageInfoPort) => void) | undefined = undefined): void {
  }

  onClose(_: () => void): void {
  }

  offClose(_: (() => void) | undefined = undefined): void {
  }

  onError(_: () => void): void {
  }

  offError(_: (() => void) | undefined = undefined): void {
  }
}

class RecordingServerDriver implements HarmonyVpnLocalSocketServerDriver {
  readonly onCalls: string[] = [];
  readonly offCalls: string[] = [];
  readonly listenAddresses: string[] = [];
  closeCalls: number = 0;
  listenErrorCode: number = 0;
  listenError?: Error;
  listenHook?: () => void;
  listenDeferred?: DeferredVoid;
  private readonly connectionListeners: Array<(connection: HarmonyVpnLocalSocketConnectionDriver) => void> = [];
  private readonly errorListeners: Array<() => void> = [];

  async listen(address: string): Promise<void> {
    this.listenAddresses.push(address);
    this.listenHook?.();
    if (this.listenDeferred !== undefined) {
      await this.listenDeferred.promise;
    }
    if (this.listenErrorCode !== 0) {
      throw new FakeBusinessError(this.listenErrorCode, 'recorded server listen failure');
    }
    if (this.listenError !== undefined) {
      throw this.listenError;
    }
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
  }

  onConnection(callback: (connection: HarmonyVpnLocalSocketConnectionDriver) => void): void {
    this.onCalls.push('connect');
    this.connectionListeners.push(callback);
  }

  offConnection(callback?: (connection: HarmonyVpnLocalSocketConnectionDriver) => void): void {
    this.offCalls.push('connect');
    removeConnectionListener(this.connectionListeners, callback);
  }

  onError(callback: () => void): void {
    this.onCalls.push('error');
    this.errorListeners.push(callback);
  }

  offError(callback?: () => void): void {
    this.offCalls.push('error');
    removeVoidListener(this.errorListeners, callback);
  }

  emitConnect(connection: HarmonyVpnLocalSocketConnectionDriver): void {
    for (let index: number = 0; index < this.connectionListeners.length; index += 1) {
      this.connectionListeners[index](connection);
    }
  }

  emitError(): void {
    for (let index: number = 0; index < this.errorListeners.length; index += 1) {
      this.errorListeners[index]();
    }
  }
}

class RecordingServerDriverFactory implements HarmonyVpnLocalSocketServerDriverFactory {
  readonly servers: RecordingServerDriver[] = [];
  createCount: number = 0;

  create(): HarmonyVpnLocalSocketServerDriver {
    this.createCount += 1;
    const server = new RecordingServerDriver();
    this.servers.push(server);
    return server;
  }
}

class FixedServerDriverFactory implements HarmonyVpnLocalSocketServerDriverFactory {
  readonly server: RecordingServerDriver;
  createCount: number = 0;

  constructor(server: RecordingServerDriver) {
    this.server = server;
  }

  create(): HarmonyVpnLocalSocketServerDriver {
    this.createCount += 1;
    return this.server;
  }
}

class ThrowingServerDriverFactory implements HarmonyVpnLocalSocketServerDriverFactory {
  readonly error: Error;
  createCount: number = 0;

  constructor(error: Error) {
    this.error = error;
  }

  create(): HarmonyVpnLocalSocketServerDriver {
    this.createCount += 1;
    throw this.error;
  }
}

async function flushAsyncTurns(turns: number = 6): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await Promise.resolve();
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

function removeConnectionListener(
  items: Array<(connection: HarmonyVpnLocalSocketConnectionDriver) => void>,
  callback?: (connection: HarmonyVpnLocalSocketConnectionDriver) => void
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

function requireSocketFailure(error: Error): VpnRpcSocketFailure {
  if (error instanceof VpnRpcSocketFailure) {
    return error;
  }
  throw new Error('Expected VpnRpcSocketFailure.');
}

function expectSocketFailure(error: Error, code: VpnRpcSocketFailureCode): void {
  const failure = requireSocketFailure(error);
  const expected = createVpnRpcSocketFailure(code);
  expect(failure.code).assertEqual(expected.code);
  expect(failure.message).assertEqual(expected.message);
  expect(failure.retryable).assertEqual(expected.retryable);
}

async function expectSocketFailureAsync(
  runner: () => Promise<void>,
  code: VpnRpcSocketFailureCode
): Promise<void> {
  try {
    await runner();
    expect(false).assertTrue();
  } catch (error) {
    const failure = error instanceof Error ? error : new Error('Expected Error.');
    expectSocketFailure(failure, code);
  }
}

export default function harmonyVpnLocalSocketServerTestsuite() {
  describe('HarmonyVpnLocalSocketServerTest', () => {
    it('registersListenersBeforeListenResolvesAbsolutePathAndDoesNotLoseSynchronousAcceptedConnections', 0, async () => {
      const listenDriver = new RecordingServerDriver();
      const server: HarmonyVpnLocalSocketServer = new HarmonyVpnLocalSocketServer(new FixedServerDriverFactory(listenDriver), FILES_DIR);
      const accepted: VpnRpcSocketConnectionPort[] = [];
      const rawConnection = new RecordingConnectionDriver();
      listenDriver.listenHook = (): void => {
        listenDriver.emitConnect(rawConnection);
      };

      await server.listen('cmfa_vpn_rpc_v1_server', (connection: VpnRpcSocketConnectionPort): void => {
        accepted.push(connection);
      });
      await flushAsyncTurns();

      expect(listenDriver.onCalls.join(',')).assertEqual('connect,error');
      expect(listenDriver.listenAddresses[0]).assertEqual('/sandbox/shared/files/cmfa_vpn_rpc_v1_server');
      expect(accepted.length).assertEqual(1);
    });

    it('mapsAddressInUseAndPlatformFailuresAndFailedListenIsTerminal', 0, async () => {
      const addressDriver = new RecordingServerDriver();
      addressDriver.listenErrorCode = 2301098;
      const addressFactory = new FixedServerDriverFactory(addressDriver);
      const addressServer: HarmonyVpnLocalSocketServer = new HarmonyVpnLocalSocketServer(addressFactory, FILES_DIR);
      await expectSocketFailureAsync(
        (): Promise<void> => addressServer.listen('cmfa_vpn_rpc_v1_server', (): void => {}),
        'ADDRESS_IN_USE'
      );
      await expectSocketFailureAsync(
        (): Promise<void> => addressServer.listen('cmfa_vpn_rpc_v1_server_2', (): void => {}),
        'CLOSED'
      );
      expect(addressFactory.createCount).assertEqual(1);

      const platformDriver = new RecordingServerDriver();
      platformDriver.listenError = new Error('other platform secret');
      const platformServer: HarmonyVpnLocalSocketServer = new HarmonyVpnLocalSocketServer(
        new FixedServerDriverFactory(platformDriver),
        FILES_DIR
      );
      await expectSocketFailureAsync(
        (): Promise<void> => platformServer.listen('cmfa_vpn_rpc_v1_server', (): void => {}),
        'PLATFORM_FAILED'
      );

      const relativeBaseFactory = new RecordingServerDriverFactory();
      const relativeBaseServer: HarmonyVpnLocalSocketServer = new HarmonyVpnLocalSocketServer(relativeBaseFactory, 'sandbox/shared/files');
      await expectSocketFailureAsync(
        (): Promise<void> => relativeBaseServer.listen('cmfa_vpn_rpc_v1_server', (): void => {}),
        'PLATFORM_FAILED'
      );
      expect(relativeBaseFactory.createCount).assertEqual(0);

      const traversalFactory = new RecordingServerDriverFactory();
      const traversalServer: HarmonyVpnLocalSocketServer = new HarmonyVpnLocalSocketServer(traversalFactory, FILES_DIR);
      await expectSocketFailureAsync(
        (): Promise<void> => traversalServer.listen('../escape', (): void => {}),
        'PLATFORM_FAILED'
      );
      expect(traversalFactory.createCount).assertEqual(0);
    });

    it('closesPendingListenAndRejectsLateResolveAsClosedWithoutRevivingState', 0, async () => {
      const listenDriver = new RecordingServerDriver();
      const pendingListen = new DeferredVoid();
      const firstAccepted = new RecordingConnectionDriver();
      const lateAccepted = new RecordingConnectionDriver();
      const accepted: VpnRpcSocketConnectionPort[] = [];
      listenDriver.listenDeferred = pendingListen;
      listenDriver.listenHook = (): void => {
        listenDriver.emitConnect(firstAccepted);
      };
      const factory = new FixedServerDriverFactory(listenDriver);
      const server: HarmonyVpnLocalSocketServer = new HarmonyVpnLocalSocketServer(factory);

      const listenPromise: Promise<void> = server.listen('cmfa_vpn_rpc_v1_server', (connection: VpnRpcSocketConnectionPort): void => {
        accepted.push(connection);
      });
      await flushAsyncTurns();

      const closePromise: Promise<void> = server.close();
      listenDriver.emitConnect(lateAccepted);
      pendingListen.resolve();
      await closePromise;
      await expectSocketFailureAsync((): Promise<void> => listenPromise, 'CLOSED');
      await flushAsyncTurns();

      expect(listenDriver.closeCalls).assertEqual(1);
      expect(firstAccepted.closeCalls).assertEqual(1);
      expect(lateAccepted.closeCalls).assertEqual(1);
      expect(accepted.length).assertEqual(1);
      await expectSocketFailureAsync(
        (): Promise<void> => server.listen('cmfa_vpn_rpc_v1_server_2', (): void => {}),
        'CLOSED'
      );
      await server.close();
      expect(factory.createCount).assertEqual(1);
    });

    it('closeThenRelistenRejectsClosedAndDoesNotCreateSecondRawDriver', 0, async () => {
      const factory = new RecordingServerDriverFactory();
      const server: HarmonyVpnLocalSocketServer = new HarmonyVpnLocalSocketServer(factory);

      await server.listen('cmfa_vpn_rpc_v1_server', (): void => {});
      await server.close();
      await expectSocketFailureAsync(
        (): Promise<void> => server.listen('cmfa_vpn_rpc_v1_server_2', (): void => {}),
        'CLOSED'
      );
      await server.close();

      expect(factory.createCount).assertEqual(1);
      expect(factory.servers[0].closeCalls).assertEqual(1);
    });

    it('mapsDriverFactoryCreateThrowToFixedPlatformFailureAndBecomesClosed', 0, async () => {
      const factory = new ThrowingServerDriverFactory(new Error('raw constructor secret'));
      const server: HarmonyVpnLocalSocketServer = new HarmonyVpnLocalSocketServer(factory);

      await expectSocketFailureAsync(
        (): Promise<void> => server.listen('cmfa_vpn_rpc_v1_server', (): void => {}),
        'PLATFORM_FAILED'
      );
      await expectSocketFailureAsync(
        (): Promise<void> => server.listen('cmfa_vpn_rpc_v1_server_2', (): void => {}),
        'CLOSED'
      );
      expect(factory.createCount).assertEqual(1);
    });

    it('listenerThrowClosesBrokenConnectionAndFailClosesServerWithoutUnhandledFollowupConnections', 0, async () => {
      const driver = new RecordingServerDriver();
      const server: HarmonyVpnLocalSocketServer = new HarmonyVpnLocalSocketServer(new FixedServerDriverFactory(driver));
      const firstRaw = new RecordingConnectionDriver();
      const secondRaw = new RecordingConnectionDriver();
      let callbackCount = 0;

      await server.listen('cmfa_vpn_rpc_v1_server', (_connection: VpnRpcSocketConnectionPort): void => {
        callbackCount += 1;
        throw new Error('raw-secret-listener-failure');
      });

      driver.emitConnect(firstRaw);
      driver.emitConnect(secondRaw);
      await flushAsyncTurns(10);

      expect(callbackCount).assertEqual(1);
      expect(firstRaw.closeCalls).assertEqual(1);
      expect(secondRaw.closeCalls).assertEqual(1);
      expect(driver.closeCalls).assertEqual(1);
      expect(driver.offCalls.join(',')).assertEqual('connect,error');
      await server.close();
      await expectSocketFailureAsync(
        (): Promise<void> => server.listen('cmfa_vpn_rpc_v1_server_2', (): void => {}),
        'CLOSED'
      );
    });

    it('keepsAtMostOneAcceptedAdapterAndClosesQueuedReplacementsAfterServerClose', 0, async () => {
      const factory = new RecordingServerDriverFactory();
      const server: HarmonyVpnLocalSocketServer = new HarmonyVpnLocalSocketServer(factory);
      const accepted: VpnRpcSocketConnectionPort[] = [];
      const firstRaw = new RecordingConnectionDriver();
      const secondRaw = new RecordingConnectionDriver();
      const firstCloseDeferred = new DeferredVoid();
      firstRaw.closeDeferred = firstCloseDeferred;
      await server.listen('cmfa_vpn_rpc_v1_server', (connection: VpnRpcSocketConnectionPort): void => {
        accepted.push(connection);
      });

      factory.servers[0].emitConnect(firstRaw);
      factory.servers[0].emitConnect(secondRaw);
      await flushAsyncTurns();
      expect(accepted.length).assertEqual(1);

      const closePromise = server.close();
      firstCloseDeferred.resolve();
      await closePromise;
      await flushAsyncTurns();

      expect(firstRaw.closeCalls).assertEqual(1);
      expect(secondRaw.closeCalls).assertEqual(1);
      expect(factory.servers[0].closeCalls).assertEqual(1);
      expect(factory.servers[0].offCalls.join(',')).assertEqual('connect,error');
    });

    it('closeBeforeListenIsIdempotentAndLeavesAdapterClosed', 0, async () => {
      const factory = new RecordingServerDriverFactory();
      const server: HarmonyVpnLocalSocketServer = new HarmonyVpnLocalSocketServer(factory);

      await server.close();
      await server.close();
      await expectSocketFailureAsync(
        (): Promise<void> => server.listen('cmfa_vpn_rpc_v1_server', (): void => {}),
        'CLOSED'
      );

      expect(factory.createCount).assertEqual(0);
    });
  });
}
