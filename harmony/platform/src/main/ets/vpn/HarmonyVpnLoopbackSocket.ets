import { socket } from '@kit.NetworkKit';
import {
  createVpnRpcSocketFailure,
  VpnRpcSocketFailure,
  type VpnRpcSocketClientFactoryPort,
  type VpnRpcSocketConnectionPort,
  type VpnRpcSocketServerPort
} from '@cmfa/shared';
import {
  HarmonyVpnLocalSocketConnectionAdapter,
  type HarmonyVpnLocalSocketConnectionDriver,
  type HarmonyVpnLocalSocketMessageInfoPort,
  type HarmonyVpnLocalSocketSendOptionsPort
} from './HarmonyVpnLocalSocketClient';

const MAX_CONNECTIONS: number = 4;
const MAX_EARLY_BYTES: number = 262180;
const MAX_EARLY_CHUNKS: number = 64;
const TCP_ADDRESS_IN_USE: number = 2303198;
const TCP_CONNECT_REFUSED: number = 2301111;
const SDK_FAILURE: string = 'VPN RPC loopback socket SDK call failed.';

export interface HarmonyVpnLoopbackAddress {
  readonly address: string;
  readonly family: number;
  readonly port: number;
}

export interface HarmonyVpnLoopbackConnectOptions {
  readonly address: HarmonyVpnLoopbackAddress;
  readonly timeout: number;
}

export interface HarmonyVpnLoopbackClientDriver extends HarmonyVpnLocalSocketConnectionDriver {
  bind(address: HarmonyVpnLoopbackAddress): Promise<void>;
  connect(options: HarmonyVpnLoopbackConnectOptions): Promise<void>;
}

export interface HarmonyVpnLoopbackClientDriverFactory {
  create(): HarmonyVpnLoopbackClientDriver;
}

export interface HarmonyVpnLoopbackServerDriver {
  listen(address: HarmonyVpnLoopbackAddress): Promise<void>;
  close(): Promise<void>;
  onConnection(callback: (connection: HarmonyVpnLocalSocketConnectionDriver) => void): void;
  offConnection(callback?: (connection: HarmonyVpnLocalSocketConnectionDriver) => void): void;
  onError(callback: () => void): void;
  offError(callback?: () => void): void;
}

export interface HarmonyVpnLoopbackServerDriverFactory {
  create(): HarmonyVpnLoopbackServerDriver;
}

export function deriveVpnRpcLoopbackPort(address: string): number {
  if (!/^cmfa_vpn_rpc_v1_[0-9a-f]{32}$/.test(address)) {
    throw createVpnRpcSocketFailure('PLATFORM_FAILED');
  }
  return 30000 + Number.parseInt(address.slice(16, 24), 16) % 30000;
}

class LoopbackAddress implements HarmonyVpnLoopbackAddress, socket.NetAddress {
  readonly address: string = '127.0.0.1';
  readonly family: number = 1;
  readonly port: number;
  constructor(port: number) { this.port = port; }
}

class LoopbackConnectOptions implements HarmonyVpnLoopbackConnectOptions, socket.TCPConnectOptions {
  readonly address: HarmonyVpnLoopbackAddress;
  readonly timeout: number;
  constructor(port: number, timeout: number) {
    this.address = new LoopbackAddress(port);
    this.timeout = timeout;
  }
}

// The existing adapter supplies owned receive buffers, terminal handling and
// ordered sends. Hold only bounded early handshake bytes until the RPC session
// installs its data subscriber after connect() resolves.
class LoopbackConnection implements VpnRpcSocketConnectionPort {
  private readonly adapter: HarmonyVpnLocalSocketConnectionAdapter;
  private readonly dataListeners: Map<number, (bytes: Uint8Array) => void> = new Map<number, (bytes: Uint8Array) => void>();
  private readonly closeListeners: Map<number, () => void> = new Map<number, () => void>();
  private readonly errorListeners: Map<number, () => void> = new Map<number, () => void>();
  private readonly early: Uint8Array[] = [];
  private earlyBytes: number = 0;
  private nextId: number = 1;
  private closed: boolean = false;
  private failed: boolean = false;
  private flushPending: boolean = false;

  constructor(raw: HarmonyVpnLocalSocketConnectionDriver) {
    this.adapter = new HarmonyVpnLocalSocketConnectionAdapter(raw);
    this.adapter.subscribeData((bytes: Uint8Array): void => { this.receive(bytes); });
    this.adapter.subscribeError((): void => {
      this.failed = true;
      this.notify(this.errorListeners);
    });
    this.adapter.subscribeClose((): void => {
      this.closed = true;
      this.wipeEarly();
      this.notify(this.closeListeners);
      this.dataListeners.clear();
    });
  }

  isClosed(): boolean { return this.closed; }

  async send(bytes: Uint8Array): Promise<void> { await this.adapter.send(bytes); }

  subscribeData(listener: (bytes: Uint8Array) => void): number {
    const id: number = this.nextId++;
    if (!this.closed) {
      this.dataListeners.set(id, listener);
      this.scheduleFlush();
    }
    return id;
  }
  unsubscribeData(id: number): void { this.dataListeners.delete(id); }
  subscribeClose(listener: () => void): number {
    const id: number = this.nextId++;
    if (this.closed) {
      void Promise.resolve().then((): void => { listener(); }).catch((): void => {});
    } else {
      this.closeListeners.set(id, listener);
    }
    return id;
  }
  unsubscribeClose(id: number): void { this.closeListeners.delete(id); }
  subscribeError(listener: () => void): number {
    const id: number = this.nextId++;
    if (this.failed) {
      void Promise.resolve().then((): void => { listener(); }).catch((): void => {});
    } else if (!this.closed) {
      this.errorListeners.set(id, listener);
    }
    return id;
  }
  unsubscribeError(id: number): void { this.errorListeners.delete(id); }
  async close(): Promise<void> { await this.adapter.close(); }

  private receive(bytes: Uint8Array): void {
    if (this.closed) { return; }
    if (this.dataListeners.size === 0 || this.early.length > 0) {
      if (this.earlyBytes + bytes.length > MAX_EARLY_BYTES || this.early.length >= MAX_EARLY_CHUNKS) {
        this.failed = true;
        this.notify(this.errorListeners);
        void this.close();
        return;
      }
      this.early.push(bytes.slice());
      this.earlyBytes += bytes.length;
      this.scheduleFlush();
      return;
    }
    this.publishBytes(bytes);
  }

  private scheduleFlush(): void {
    if (this.flushPending || this.closed || this.dataListeners.size === 0 || this.early.length === 0) { return; }
    this.flushPending = true;
    void Promise.resolve().then((): void => {
      this.flushPending = false;
      while (!this.closed && this.dataListeners.size > 0 && this.early.length > 0) {
        const bytes: Uint8Array = this.early.shift()!;
        this.earlyBytes -= bytes.length;
        this.publishBytes(bytes);
        bytes.fill(0);
      }
    });
  }

  private publishBytes(bytes: Uint8Array): void {
    const listeners: Array<(bytes: Uint8Array) => void> = Array.from(this.dataListeners.values());
    for (const listener of listeners) {
      try { listener(bytes.slice()); } catch (_) {}
    }
  }
  private wipeEarly(): void {
    for (const bytes of this.early) { bytes.fill(0); }
    this.early.length = 0;
    this.earlyBytes = 0;
  }
  private notify(listeners: Map<number, () => void>): void {
    const callbacks: Array<() => void> = Array.from(listeners.values());
    listeners.clear();
    for (const callback of callbacks) { try { callback(); } catch (_) {} }
  }
}

export class HarmonyVpnLoopbackSocketClient implements VpnRpcSocketClientFactoryPort {
  private readonly factory: HarmonyVpnLoopbackClientDriverFactory;
  constructor(factory?: HarmonyVpnLoopbackClientDriverFactory) {
    this.factory = factory ?? new SdkClientFactory();
  }
  async connect(address: string, timeoutMs: number): Promise<VpnRpcSocketConnectionPort> {
    const port: number = deriveVpnRpcLoopbackPort(address);
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > 30000) {
      throw createVpnRpcSocketFailure('PLATFORM_FAILED');
    }
    let raw: HarmonyVpnLoopbackClientDriver | undefined;
    let connection: LoopbackConnection | undefined;
    try {
      raw = this.factory.create();
      connection = new LoopbackConnection(raw);
      await raw.bind(new LoopbackAddress(0));
      if (connection.isClosed()) { throw createVpnRpcSocketFailure('CLOSED'); }
      await raw.connect(new LoopbackConnectOptions(port, timeoutMs));
      if (connection.isClosed()) { throw createVpnRpcSocketFailure('CLOSED'); }
      return connection;
    } catch (error) {
      if (connection !== undefined) { await connection.close(); }
      else if (raw !== undefined) { await closeRaw(raw); }
      if (error instanceof VpnRpcSocketFailure) { throw error; }
      throw createVpnRpcSocketFailure(readCode(error as Object) === TCP_CONNECT_REFUSED ? 'CONNECT_REFUSED' : 'PLATFORM_FAILED');
    }
  }
}

export class HarmonyVpnLoopbackSocketServer implements VpnRpcSocketServerPort {
  readonly preservePendingCandidate: boolean = true;
  private readonly factory: HarmonyVpnLoopbackServerDriverFactory;
  private readonly connections: Set<LoopbackConnection> = new Set<LoopbackConnection>();
  private driver?: HarmonyVpnLoopbackServerDriver;
  private listener?: (connection: VpnRpcSocketConnectionPort) => void | Promise<void>;
  private state: 'IDLE' | 'LISTENING' | 'ACTIVE' | 'CLOSED' = 'IDLE';
  private listenOperation?: Promise<void>;
  private closeOperation?: Promise<void>;
  private connectionRegistered: boolean = false;
  private errorRegistered: boolean = false;
  private readonly accept: (raw: HarmonyVpnLocalSocketConnectionDriver) => void;
  private readonly error: () => void;

  constructor(factory?: HarmonyVpnLoopbackServerDriverFactory) {
    this.factory = factory ?? new SdkServerFactory();
    this.accept = (raw: HarmonyVpnLocalSocketConnectionDriver): void => { this.acceptConnection(raw); };
    this.error = (): void => { void this.close().catch((): void => {}); };
  }

  async listen(address: string, listener: (connection: VpnRpcSocketConnectionPort) => void | Promise<void>): Promise<void> {
    if (this.state === 'CLOSED') { throw createVpnRpcSocketFailure('CLOSED'); }
    if (this.state !== 'IDLE') { throw createVpnRpcSocketFailure('PLATFORM_FAILED'); }
    const port: number = deriveVpnRpcLoopbackPort(address);
    this.state = 'LISTENING';
    this.listener = listener;
    try {
      const driver: HarmonyVpnLoopbackServerDriver = this.factory.create();
      this.driver = driver;
      this.connectionRegistered = true;
      driver.onConnection(this.accept);
      this.errorRegistered = true;
      driver.onError(this.error);
      if (this.isClosed()) { throw createVpnRpcSocketFailure('CLOSED'); }
      this.listenOperation = driver.listen(new LoopbackAddress(port));
      await this.listenOperation;
      if (this.isClosed()) { throw createVpnRpcSocketFailure('CLOSED'); }
      this.state = 'ACTIVE';
    } catch (error) {
      const wasClosed: boolean = this.isClosed();
      try { await this.close(); } catch (_) {}
      if (wasClosed) { throw createVpnRpcSocketFailure('CLOSED'); }
      if (error instanceof VpnRpcSocketFailure) { throw error; }
      throw createVpnRpcSocketFailure(readCode(error as Object) === TCP_ADDRESS_IN_USE ? 'ADDRESS_IN_USE' : 'PLATFORM_FAILED');
    }
  }

  async close(): Promise<void> {
    if (this.closeOperation !== undefined) { return await this.closeOperation; }
    this.state = 'CLOSED';
    this.listener = undefined;
    this.closeOperation = this.closeInternal();
    return await this.closeOperation;
  }

  private isClosed(): boolean { return this.state === 'CLOSED'; }

  private acceptConnection(raw: HarmonyVpnLocalSocketConnectionDriver): void {
    // Reserve admitted slots synchronously, including connections still closing.
    // Authentication promotion remains exclusively with VpnRpcServerSession.
    if (this.isClosed() || this.connections.size >= MAX_CONNECTIONS) {
      void closeRaw(raw);
      return;
    }
    let connection: LoopbackConnection;
    try { connection = new LoopbackConnection(raw); } catch (_) { void closeRaw(raw); return; }
    this.connections.add(connection);
    connection.subscribeClose((): void => { void this.retire(connection); });
    const listener = this.listener;
    if (listener === undefined) { void this.retire(connection); return; }
    try {
      const result: void | Promise<void> = listener(connection);
      void Promise.resolve(result).catch((): void => { void this.retire(connection); });
    } catch (_) { void this.retire(connection); }
  }

  private async retire(connection: LoopbackConnection): Promise<void> {
    try { await connection.close(); } finally { this.connections.delete(connection); }
  }

  private async closeInternal(): Promise<void> {
    // Also covers synchronous error callbacks during registration/listen: let the
    // current stack publish listenOperation before waiting for its completion.
    await Promise.resolve();
    try { await this.listenOperation; } catch (_) {}
    const driver = this.driver;
    if (driver !== undefined) {
      if (this.connectionRegistered) {
        this.connectionRegistered = false;
        try { driver.offConnection(this.accept); } catch (_) {}
      }
      if (this.errorRegistered) {
        this.errorRegistered = false;
        try { driver.offError(this.error); } catch (_) {}
      }
    }
    let failed: boolean = false;
    if (driver !== undefined) {
      try { await driver.close(); } catch (_) { failed = true; }
    }
    const connections: LoopbackConnection[] = Array.from(this.connections.values());
    for (const connection of connections) { await this.retire(connection); }
    if (failed) { throw createVpnRpcSocketFailure('PLATFORM_FAILED'); }
  }
}

interface ErrorCode { code?: number; }
function readCode(error: Object | undefined): number {
  if (error === undefined || typeof error !== 'object') { return 0; }
  const code: number | undefined = (error as ErrorCode).code;
  return typeof code === 'number' && Number.isSafeInteger(code) ? code : 0;
}
class LoopbackSdkFailure extends Error {
  readonly code: number;
  constructor(error: Object | undefined) { super(SDK_FAILURE); this.code = readCode(error); }
}
async function closeRaw(raw: HarmonyVpnLocalSocketConnectionDriver): Promise<void> {
  try { await raw.close(); } catch (_) {}
}
class SdkSendOptions implements socket.TCPSendOptions {
  readonly data: ArrayBuffer;
  constructor(data: ArrayBuffer) { this.data = data; }
}
class SdkMessage implements HarmonyVpnLocalSocketMessageInfoPort {
  readonly message: ArrayBuffer;
  readonly size: number;
  constructor(message: ArrayBuffer) { this.message = message; this.size = message.byteLength; }
}
class SdkConnection implements HarmonyVpnLocalSocketConnectionDriver {
  private readonly raw: socket.TCPSocket | socket.TCPSocketConnection;
  private readonly messages: Map<(info: HarmonyVpnLocalSocketMessageInfoPort) => void, (info: socket.SocketMessageInfo) => void> = new Map<(info: HarmonyVpnLocalSocketMessageInfoPort) => void, (info: socket.SocketMessageInfo) => void>();
  private readonly closes: Map<() => void, () => void> = new Map<() => void, () => void>();
  private readonly errors: Map<() => void, (error: Error) => void> = new Map<() => void, (error: Error) => void>();
  constructor(raw: socket.TCPSocket | socket.TCPSocketConnection) { this.raw = raw; }
  async send(options: HarmonyVpnLocalSocketSendOptionsPort): Promise<void> {
    try { await this.raw.send(new SdkSendOptions(options.data)); } catch (error) { throw new LoopbackSdkFailure(error as Object); }
  }
  async close(): Promise<void> {
    try { await this.raw.close(); } catch (error) { throw new LoopbackSdkFailure(error as Object); }
  }
  onMessage(callback: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void {
    const binding = (info: socket.SocketMessageInfo): void => { callback(new SdkMessage(info.message)); };
    this.messages.set(callback, binding);
    this.raw.on('message', binding);
  }
  offMessage(callback?: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void {
    if (callback === undefined) { this.messages.clear(); this.raw.off('message'); return; }
    const binding = this.messages.get(callback); this.messages.delete(callback); this.raw.off('message', binding);
  }
  onClose(callback: () => void): void {
    const binding = (): void => { callback(); }; this.closes.set(callback, binding); this.raw.on('close', binding);
  }
  offClose(callback?: () => void): void {
    if (callback === undefined) { this.closes.clear(); this.raw.off('close'); return; }
    const binding = this.closes.get(callback); this.closes.delete(callback); this.raw.off('close', binding);
  }
  onError(callback: () => void): void {
    const binding = (_: Error): void => { callback(); }; this.errors.set(callback, binding); this.raw.on('error', binding);
  }
  offError(callback?: () => void): void {
    if (callback === undefined) { this.errors.clear(); this.raw.off('error'); return; }
    const binding = this.errors.get(callback); this.errors.delete(callback); this.raw.off('error', binding);
  }
}
class SdkClient extends SdkConnection implements HarmonyVpnLoopbackClientDriver {
  private readonly client: socket.TCPSocket;
  constructor(raw: socket.TCPSocket) { super(raw); this.client = raw; }
  async bind(address: HarmonyVpnLoopbackAddress): Promise<void> {
    try { await this.client.bind(address); } catch (error) { throw new LoopbackSdkFailure(error as Object); }
  }
  async connect(options: HarmonyVpnLoopbackConnectOptions): Promise<void> {
    try { await this.client.connect(options); } catch (error) { throw new LoopbackSdkFailure(error as Object); }
  }
}
class SdkClientFactory implements HarmonyVpnLoopbackClientDriverFactory {
  create(): HarmonyVpnLoopbackClientDriver { return new SdkClient(socket.constructTCPSocketInstance()); }
}
class SdkServer implements HarmonyVpnLoopbackServerDriver {
  private readonly raw: socket.TCPSocketServer;
  private readonly connections: Map<(connection: HarmonyVpnLocalSocketConnectionDriver) => void, (raw: socket.TCPSocketConnection) => void> = new Map<(connection: HarmonyVpnLocalSocketConnectionDriver) => void, (raw: socket.TCPSocketConnection) => void>();
  private readonly errors: Map<() => void, (error: Error) => void> = new Map<() => void, (error: Error) => void>();
  constructor(raw: socket.TCPSocketServer) { this.raw = raw; }
  async listen(address: HarmonyVpnLoopbackAddress): Promise<void> {
    try { await this.raw.listen(address); } catch (error) { throw new LoopbackSdkFailure(error as Object); }
  }
  async close(): Promise<void> {
    try { await this.raw.close(); } catch (error) { throw new LoopbackSdkFailure(error as Object); }
  }
  onConnection(callback: (connection: HarmonyVpnLocalSocketConnectionDriver) => void): void {
    const binding = (raw: socket.TCPSocketConnection): void => { callback(new SdkConnection(raw)); };
    this.connections.set(callback, binding); this.raw.on('connect', binding);
  }
  offConnection(callback?: (connection: HarmonyVpnLocalSocketConnectionDriver) => void): void {
    if (callback === undefined) { this.connections.clear(); this.raw.off('connect'); return; }
    const binding = this.connections.get(callback); this.connections.delete(callback); this.raw.off('connect', binding);
  }
  onError(callback: () => void): void {
    const binding = (_: Error): void => { callback(); }; this.errors.set(callback, binding); this.raw.on('error', binding);
  }
  offError(callback?: () => void): void {
    if (callback === undefined) { this.errors.clear(); this.raw.off('error'); return; }
    const binding = this.errors.get(callback); this.errors.delete(callback); this.raw.off('error', binding);
  }
}
class SdkServerFactory implements HarmonyVpnLoopbackServerDriverFactory {
  create(): HarmonyVpnLoopbackServerDriver { return new SdkServer(socket.constructTCPSocketServerInstance()); }
}
