import { describe, expect, it } from '@ohos/hypium';
import { VpnRpcSocketFailure, type VpnRpcSocketConnectionPort, type VpnRpcSocketFailureCode } from '@cmfa/shared';
import {
  deriveVpnRpcLoopbackPort,
  HarmonyVpnLoopbackSocketClient,
  HarmonyVpnLoopbackSocketServer,
  type HarmonyVpnLoopbackAddress,
  type HarmonyVpnLoopbackConnectOptions,
  type HarmonyVpnLoopbackClientDriver,
  type HarmonyVpnLoopbackClientDriverFactory,
  type HarmonyVpnLoopbackServerDriver,
  type HarmonyVpnLoopbackServerDriverFactory
} from '../main/ets/vpn/HarmonyVpnLoopbackSocket';
import type {
  HarmonyVpnLocalSocketConnectionDriver,
  HarmonyVpnLocalSocketMessageInfoPort,
  HarmonyVpnLocalSocketSendOptionsPort
} from '../main/ets/vpn/HarmonyVpnLocalSocketClient';

const ADDRESS: string = 'cmfa_vpn_rpc_v1_0123456789abcdef0123456789abcdef';
class Deferred {
  readonly promise: Promise<void>;
  private finish?: () => void;
  constructor() { this.promise = new Promise<void>((resolve: () => void): void => { this.finish = resolve; }); }
  resolve(): void { this.finish?.(); }
}
class BusinessFailure extends Error {
  readonly code: number;
  constructor(code: number) { super('private SDK detail'); this.code = code; }
}
class Message implements HarmonyVpnLocalSocketMessageInfoPort {
  readonly message: ArrayBuffer;
  readonly size: number;
  constructor(bytes: Uint8Array) { this.message = new ArrayBuffer(bytes.byteLength); new Uint8Array(this.message).set(bytes); this.size = bytes.length; }
}
class FakeConnection implements HarmonyVpnLocalSocketConnectionDriver {
  readonly events: string[] = [];
  closeCalls: number = 0;
  closeDeferred?: Deferred;
  sendDeferred?: Deferred;
  registerError: boolean = false;
  private message?: (info: HarmonyVpnLocalSocketMessageInfoPort) => void;
  private closed?: () => void;
  private error?: () => void;
  async send(options: HarmonyVpnLocalSocketSendOptionsPort): Promise<void> {
    this.events.push(`send:${new Uint8Array(options.data)[0]}`);
    if (this.sendDeferred !== undefined) { await this.sendDeferred.promise; }
  }
  async close(): Promise<void> {
    this.closeCalls++;
    if (this.closeDeferred !== undefined) { await this.closeDeferred.promise; }
  }
  onMessage(callback: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void {
    this.events.push('on-message'); this.message = callback;
    if (this.registerError) { throw new Error('private registration failure'); }
  }
  offMessage(_: ((info: HarmonyVpnLocalSocketMessageInfoPort) => void) | undefined = undefined): void { this.message = undefined; }
  onClose(callback: () => void): void { this.events.push('on-close'); this.closed = callback; }
  offClose(_: (() => void) | undefined = undefined): void { this.closed = undefined; }
  onError(callback: () => void): void { this.events.push('on-error'); this.error = callback; }
  offError(_: (() => void) | undefined = undefined): void { this.error = undefined; }
  emit(bytes: Uint8Array): void { this.message?.(new Message(bytes)); }
  emitClose(): void { this.closed?.(); }
  emitError(): void { this.error?.(); }
}
class FakeClient extends FakeConnection implements HarmonyVpnLoopbackClientDriver {
  bound?: HarmonyVpnLoopbackAddress;
  options?: HarmonyVpnLoopbackConnectOptions;
  bindError?: Error;
  connectError?: Error;
  connectHook?: () => void;
  async bind(address: HarmonyVpnLoopbackAddress): Promise<void> {
    this.events.push('bind'); this.bound = address;
    if (this.bindError !== undefined) { throw this.bindError; }
  }
  async connect(options: HarmonyVpnLoopbackConnectOptions): Promise<void> {
    this.events.push('connect'); this.options = options; this.connectHook?.();
    if (this.connectError !== undefined) { throw this.connectError; }
  }
}
class ClientFactory implements HarmonyVpnLoopbackClientDriverFactory {
  readonly raw: FakeClient;
  creates: number = 0;
  constructor(raw: FakeClient = new FakeClient()) { this.raw = raw; }
  create(): HarmonyVpnLoopbackClientDriver { this.creates++; return this.raw; }
}
class FakeServer implements HarmonyVpnLoopbackServerDriver {
  readonly events: string[] = [];
  bound?: HarmonyVpnLoopbackAddress;
  listenError?: Error;
  listenDeferred?: Deferred;
  listenHook?: () => void;
  registrationHook?: () => void;
  closeCalls: number = 0;
  private accept?: (raw: HarmonyVpnLocalSocketConnectionDriver) => void;
  private error?: () => void;
  async listen(address: HarmonyVpnLoopbackAddress): Promise<void> {
    this.events.push('listen'); this.bound = address; this.listenHook?.();
    if (this.listenDeferred !== undefined) { await this.listenDeferred.promise; }
    if (this.listenError !== undefined) { throw this.listenError; }
  }
  async close(): Promise<void> { this.events.push('close'); this.closeCalls++; }
  onConnection(callback: (raw: HarmonyVpnLocalSocketConnectionDriver) => void): void { this.events.push('on-connection'); this.accept = callback; }
  offConnection(_: ((raw: HarmonyVpnLocalSocketConnectionDriver) => void) | undefined = undefined): void { this.events.push('off-connection'); this.accept = undefined; }
  onError(callback: () => void): void { this.events.push('on-error'); this.error = callback; this.registrationHook?.(); }
  offError(_: (() => void) | undefined = undefined): void { this.events.push('off-error'); this.error = undefined; }
  emit(raw: FakeConnection): void { this.accept?.(raw); }
  emitError(): void { this.error?.(); }
}
class ServerFactory implements HarmonyVpnLoopbackServerDriverFactory {
  readonly raw: FakeServer;
  creates: number = 0;
  constructor(raw: FakeServer = new FakeServer()) { this.raw = raw; }
  create(): HarmonyVpnLoopbackServerDriver { this.creates++; return this.raw; }
}
async function turns(): Promise<void> { for (let index: number = 0; index < 12; index++) { await Promise.resolve(); } }
async function failure(operation: () => Promise<void>, code: VpnRpcSocketFailureCode): Promise<void> {
  let caught: Error | undefined;
  try { await operation(); } catch (error) { caught = error as Error; }
  expect(caught instanceof VpnRpcSocketFailure).assertTrue();
  expect((caught as VpnRpcSocketFailure).code).assertEqual(code);
  expect(caught?.message.includes('private') ?? false).assertFalse();
}
function assertLoopback(address: HarmonyVpnLoopbackAddress | undefined, port: number): void {
  expect(address?.address ?? '').assertEqual('127.0.0.1');
  expect(address?.family ?? 0).assertEqual(1);
  expect(address?.port ?? -1).assertEqual(port);
}
export default function harmonyVpnLoopbackSocketTestsuite() {
  describe('HarmonyVpnLoopbackSocketTest', () => {
    it('derivesABoundedDeterministicPortFromOnlyTheValidOpaqueAddress', 0, () => {
      expect(deriveVpnRpcLoopbackPort(ADDRESS)).assertEqual(30000 + 0x01234567 % 30000);
      expect(deriveVpnRpcLoopbackPort('cmfa_vpn_rpc_v1_00000000000000000000000000000000')).assertEqual(30000);
      const last: number = deriveVpnRpcLoopbackPort('cmfa_vpn_rpc_v1_ffffffffffffffffffffffffffffffff');
      expect(last >= 30000 && last < 60000).assertTrue();
      const invalid: string[] = ['', '127.0.0.1:1234', 'cmfa_vpn_rpc_v1_0123456789abcdef0123456789abcdeF', ADDRESS + '/x', '/' + ADDRESS, ADDRESS + '\n'];
      for (const address of invalid) {
        let rejected: boolean = false;
        try { deriveVpnRpcLoopbackPort(address); } catch (_) { rejected = true; }
        expect(rejected).assertTrue();
      }
    });
    it('bindsOnlyLoopbackWithPortZeroBeforeClientConnectAndRegistersFirst', 0, async () => {
      const factory = new ClientFactory();
      const client = new HarmonyVpnLoopbackSocketClient(factory);
      const connection = await client.connect(ADDRESS, 1200);
      assertLoopback(factory.raw.bound, 0);
      assertLoopback(factory.raw.options?.address, deriveVpnRpcLoopbackPort(ADDRESS));
      expect(factory.raw.options?.timeout ?? 0).assertEqual(1200);
      expect(factory.raw.events.join(',')).assertEqual('on-message,on-close,on-error,bind,connect');
      await connection.close();
      await connection.close();
      expect(factory.raw.closeCalls).assertEqual(1);
    });
    it('rejectsInvalidTimeoutOrAddressBeforeCreatingASocket', 0, async () => {
      const factory = new ClientFactory();
      const client = new HarmonyVpnLoopbackSocketClient(factory);
      for (const timeout of [0, -1, 0.5, 30001, Number.NaN]) {
        await failure(async (): Promise<void> => { await client.connect(ADDRESS, timeout); }, 'PLATFORM_FAILED');
      }
      await failure(async (): Promise<void> => { await client.connect('0.0.0.0', 1000); }, 'PLATFORM_FAILED');
      expect(factory.creates).assertEqual(0);
    });
    it('preservesBoundedEarlyHandshakeMessagesBeforeTheCallerSubscribes', 0, async () => {
      const raw = new FakeClient();
      raw.connectHook = (): void => { raw.emit(new Uint8Array([1, 2])); raw.emit(new Uint8Array([3])); };
      const connection = await new HarmonyVpnLoopbackSocketClient(new ClientFactory(raw)).connect(ADDRESS, 1000);
      const received: number[] = [];
      connection.subscribeData((bytes: Uint8Array): void => { for (const byte of bytes) { received.push(byte); } });
      raw.emit(new Uint8Array([4]));
      await turns();
      expect(received.join(',')).assertEqual('1,2,3,4');
      await connection.close();
    });
    it('closesWhenEarlyReceiveBufferExceedsTheFrameBound', 0, async () => {
      const raw = new FakeClient();
      raw.connectHook = (): void => { raw.emit(new Uint8Array(262181)); };
      await failure(async (): Promise<void> => { await new HarmonyVpnLoopbackSocketClient(new ClientFactory(raw)).connect(ADDRESS, 1000); }, 'CLOSED');
      expect(raw.closeCalls).assertEqual(1);
    });
    it('cleansUpBindConnectAndCallbackRegistrationFailuresWithoutRawErrors', 0, async () => {
      const bind = new FakeClient(); bind.bindError = new BusinessFailure(201) as Error;
      await failure(async (): Promise<void> => { await new HarmonyVpnLoopbackSocketClient(new ClientFactory(bind)).connect(ADDRESS, 1000); }, 'PLATFORM_FAILED');
      expect(bind.events.includes('connect')).assertFalse(); expect(bind.closeCalls).assertEqual(1);
      const connect = new FakeClient(); connect.connectError = new BusinessFailure(2301111) as Error;
      await failure(async (): Promise<void> => { await new HarmonyVpnLoopbackSocketClient(new ClientFactory(connect)).connect(ADDRESS, 1000); }, 'CONNECT_REFUSED');
      expect(connect.closeCalls).assertEqual(1);
      const register = new FakeClient(); register.registerError = true;
      await failure(async (): Promise<void> => { await new HarmonyVpnLoopbackSocketClient(new ClientFactory(register)).connect(ADDRESS, 1000); }, 'PLATFORM_FAILED');
      expect(register.closeCalls).assertEqual(1);
    });
    it('retainsTheExistingAdapterSendOrderingAndOwnedBuffers', 0, async () => {
      const raw = new FakeClient();
      const connection = await new HarmonyVpnLoopbackSocketClient(new ClientFactory(raw)).connect(ADDRESS, 1000);
      const pending = new Deferred(); raw.sendDeferred = pending;
      const bytes = new Uint8Array([7]);
      const first = connection.send(bytes); bytes[0] = 99;
      const second = connection.send(new Uint8Array([8]));
      await turns();
      expect(raw.events.filter((event: string): boolean => event.startsWith('send:')).join(',')).assertEqual('send:7');
      pending.resolve(); await first; await second;
      expect(raw.events.filter((event: string): boolean => event.startsWith('send:')).join(',')).assertEqual('send:7,send:8');
      await connection.close();
    });
    it('registersServerCallbacksBeforeListenAndNeverBindsAWildcard', 0, async () => {
      const factory = new ServerFactory();
      const accepted: VpnRpcSocketConnectionPort[] = [];
      const raw = new FakeConnection();
      factory.raw.listenHook = (): void => { factory.raw.emit(raw); };
      const server = new HarmonyVpnLoopbackSocketServer(factory);
      await server.listen(ADDRESS, (connection: VpnRpcSocketConnectionPort): void => { accepted.push(connection); });
      expect(server.preservePendingCandidate).assertTrue();
      expect(factory.raw.events.join(',')).assertEqual('on-connection,on-error,listen');
      assertLoopback(factory.raw.bound, deriveVpnRpcLoopbackPort(ADDRESS));
      expect(accepted.length).assertEqual(1);
      await server.close();
      expect(raw.closeCalls).assertEqual(1);
    });
    it('doesNotDropExistingConnectionsOnUnauthenticatedAcceptAndCapsAtFour', 0, async () => {
      const factory = new ServerFactory();
      const server = new HarmonyVpnLoopbackSocketServer(factory);
      const accepted: VpnRpcSocketConnectionPort[] = [];
      await server.listen(ADDRESS, (connection: VpnRpcSocketConnectionPort): void => { accepted.push(connection); });
      const raws: FakeConnection[] = [];
      for (let index = 0; index < 5; index++) { const raw = new FakeConnection(); raws.push(raw); factory.raw.emit(raw); }
      expect(accepted.length).assertEqual(4);
      for (let index = 0; index < 4; index++) { expect(raws[index].closeCalls).assertEqual(0); }
      expect(raws[4].closeCalls).assertEqual(1);
      await server.close();
    });
    it('countsClosingConnectionsUntilTheirRawCloseCompletes', 0, async () => {
      const factory = new ServerFactory();
      const server = new HarmonyVpnLoopbackSocketServer(factory);
      const accepted: VpnRpcSocketConnectionPort[] = [];
      await server.listen(ADDRESS, (connection: VpnRpcSocketConnectionPort): void => { accepted.push(connection); });
      const pending = new Deferred();
      for (let index = 0; index < 4; index++) { const raw = new FakeConnection(); if (index === 0) { raw.closeDeferred = pending; } factory.raw.emit(raw); }
      const closing = accepted[0].close();
      const overflow = new FakeConnection(); factory.raw.emit(overflow);
      expect(overflow.closeCalls).assertEqual(1); expect(accepted.length).assertEqual(4);
      pending.resolve(); await closing; await turns();
      factory.raw.emit(new FakeConnection()); expect(accepted.length).assertEqual(5);
      await server.close();
    });
    it('mapsPortConflictsWithoutRetryingReclaimingOrChangingPorts', 0, async () => {
      const factory = new ServerFactory(); factory.raw.listenError = new BusinessFailure(2303198) as Error;
      const server = new HarmonyVpnLoopbackSocketServer(factory);
      await failure((): Promise<void> => server.listen(ADDRESS, (): void => {}), 'ADDRESS_IN_USE');
      expect(factory.creates).assertEqual(1); expect(factory.raw.closeCalls).assertEqual(1);
      await failure((): Promise<void> => server.listen(ADDRESS, (): void => {}), 'CLOSED');
    });
    it('doesNotResolveCloseUntilPendingListenSettlesAndClosesTheLateListener', 0, async () => {
      const factory = new ServerFactory(); const pending = new Deferred(); factory.raw.listenDeferred = pending;
      const server = new HarmonyVpnLoopbackSocketServer(factory);
      const listening = server.listen(ADDRESS, (): void => {});
      await turns();
      let closeFinished: boolean = false;
      const closing = server.close().then((): void => { closeFinished = true; });
      await turns(); expect(closeFinished).assertFalse();
      const late = new FakeConnection(); factory.raw.emit(late); expect(late.closeCalls).assertEqual(1);
      pending.resolve(); await closing;
      await failure((): Promise<void> => listening, 'CLOSED');
      expect(factory.raw.closeCalls).assertEqual(1);
    });
    it('synchronousRegistrationErrorCannotStartAListenerAfterClose', 0, async () => {
      const factory = new ServerFactory();
      factory.raw.registrationHook = (): void => { factory.raw.emitError(); };
      const server = new HarmonyVpnLoopbackSocketServer(factory);
      await failure((): Promise<void> => server.listen(ADDRESS, (): void => {}), 'CLOSED');
      expect(factory.raw.events.includes('listen')).assertFalse(); expect(factory.raw.closeCalls).assertEqual(1);
    });
    it('stopsAllConnectionsAndAllowsANewServerInstanceToListenOnTheSamePort', 0, async () => {
      const first = new ServerFactory(); const firstServer = new HarmonyVpnLoopbackSocketServer(first);
      await firstServer.listen(ADDRESS, (): void => {});
      const raw = new FakeConnection(); first.raw.emit(raw);
      await firstServer.close(); await firstServer.close();
      expect(first.raw.closeCalls).assertEqual(1); expect(raw.closeCalls).assertEqual(1);
      const next = new ServerFactory(); const nextServer = new HarmonyVpnLoopbackSocketServer(next);
      await nextServer.listen(ADDRESS, (): void => {});
      assertLoopback(next.raw.bound, first.raw.bound?.port ?? 0);
      await nextServer.close();
    });
  });
}
