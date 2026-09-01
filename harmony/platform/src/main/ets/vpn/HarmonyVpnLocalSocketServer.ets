import { socket } from '@kit.NetworkKit';
import {
  createVpnRpcSocketFailure,
  VpnRpcSocketFailure,
  type VpnRpcSocketConnectionPort,
  type VpnRpcSocketServerPort
} from '@cmfa/shared';
import {
  HarmonyVpnLocalSocketConnectionAdapter,
  HarmonyVpnSdkLocalSocketConnectionDriver,
  resolveLocalSocketAddress,
  type HarmonyVpnLocalSocketConnectionDriver
} from './HarmonyVpnLocalSocketClient';

const STATE_IDLE: number = 0;
const STATE_LISTENING: number = 1;
const STATE_ACTIVE: number = 2;
const STATE_CLOSED: number = 3;

const ADDRESS_IN_USE_ERROR_CODE: number = 2301098;
const SDK_BOUNDARY_FAILURE_CODE: number = 0;
const SDK_BOUNDARY_FAILURE_MESSAGE: string = 'VPN RPC local socket server SDK call failed.';

export interface HarmonyVpnLocalSocketServerDriver {
  listen(address: string): Promise<void>;
  close(): Promise<void>;
  onConnection(callback: (connection: HarmonyVpnLocalSocketConnectionDriver) => void): void;
  offConnection(callback?: (connection: HarmonyVpnLocalSocketConnectionDriver) => void): void;
  onError(callback: () => void): void;
  offError(callback?: () => void): void;
}

export interface HarmonyVpnLocalSocketServerDriverFactory {
  create(): HarmonyVpnLocalSocketServerDriver;
}

export class HarmonyVpnLocalSocketServer implements VpnRpcSocketServerPort {
  private readonly driverFactory: HarmonyVpnLocalSocketServerDriverFactory;
  private readonly socketRootDir: string;
  private readonly rawConnectListener: (connection: HarmonyVpnLocalSocketConnectionDriver) => void;
  private readonly rawErrorListener: () => void;
  private readonly trackedConnections: Set<HarmonyVpnLocalSocketConnectionAdapter> = new Set<HarmonyVpnLocalSocketConnectionAdapter>();
  private state: number = STATE_IDLE;
  private registeredDriver?: HarmonyVpnLocalSocketServerDriver;
  private pendingDriver?: HarmonyVpnLocalSocketServerDriver;
  private listener?: (connection: VpnRpcSocketConnectionPort) => void;
  private activeConnection?: HarmonyVpnLocalSocketConnectionAdapter;
  private acceptTail: Promise<void> = Promise.resolve();
  private closePromise?: Promise<void>;

  constructor(driverFactory?: HarmonyVpnLocalSocketServerDriverFactory, socketRootDir: string = '') {
    this.driverFactory = driverFactory ?? new HarmonyVpnSdkLocalSocketServerDriverFactory();
    this.socketRootDir = socketRootDir;
    this.rawConnectListener = (connection: HarmonyVpnLocalSocketConnectionDriver): void => {
      this.enqueueAcceptedConnection(connection);
    };
    this.rawErrorListener = (): void => {
      void this.failCloseServer();
    };
  }

  async listen(address: string, listener: (connection: VpnRpcSocketConnectionPort) => void): Promise<void> {
    if (this.state === STATE_CLOSED) {
      throw createVpnRpcSocketFailure('CLOSED');
    }
    if (this.state !== STATE_IDLE) {
      throw createVpnRpcSocketFailure('PLATFORM_FAILED');
    }
    this.state = STATE_LISTENING;
    this.listener = listener;
    let driver: HarmonyVpnLocalSocketServerDriver | undefined = undefined;
    try {
      if (!isValidSocketAddress(address)) {
        throw createVpnRpcSocketFailure('PLATFORM_FAILED');
      }
      const resolvedAddress: string = resolveLocalSocketAddress(this.socketRootDir, address);
      driver = this.driverFactory.create();
      this.pendingDriver = driver;
      this.registerCallbacks(driver);
      await driver.listen(resolvedAddress);
      if (this.state === STATE_CLOSED) {
        throw createVpnRpcSocketFailure('CLOSED');
      }
      this.pendingDriver = undefined;
      this.state = STATE_ACTIVE;
    } catch (error) {
      const typedError: Error = normalizeError(error);
      const wasClosed: boolean = this.state === STATE_CLOSED;
      if (!wasClosed && driver !== undefined) {
        this.unregisterCallbacks(driver);
        await safeCloseServer(driver);
      }
      this.pendingDriver = undefined;
      this.registeredDriver = undefined;
      this.listener = undefined;
      this.state = STATE_CLOSED;
      throw wasClosed ? createVpnRpcSocketFailure('CLOSED') : mapListenFailure(typedError);
    }
  }

  async close(): Promise<void> {
    if (this.closePromise !== undefined) {
      return await this.closePromise;
    }
    if (this.state === STATE_CLOSED) {
      return;
    }
    if (this.state === STATE_IDLE) {
      this.state = STATE_CLOSED;
      return;
    }
    this.state = STATE_CLOSED;
    this.closePromise = this.closeInternal();
    return await this.closePromise;
  }

  private registerCallbacks(driver: HarmonyVpnLocalSocketServerDriver): void {
    try {
      driver.onConnection(this.rawConnectListener);
      driver.onError(this.rawErrorListener);
      this.registeredDriver = driver;
    } catch (_) {
      this.unregisterCallbacks(driver);
      throw createVpnRpcSocketFailure('PLATFORM_FAILED');
    }
  }

  private unregisterCallbacks(driver: HarmonyVpnLocalSocketServerDriver): void {
    if (this.registeredDriver !== driver) {
      return;
    }
    this.registeredDriver = undefined;
    try {
      driver.offConnection(this.rawConnectListener);
    } catch (_) {
    }
    try {
      driver.offError(this.rawErrorListener);
    } catch (_) {
    }
  }

  private enqueueAcceptedConnection(connection: HarmonyVpnLocalSocketConnectionDriver): void {
    this.acceptTail = this.acceptTail
      .catch((): void => {
      })
      .then(async (): Promise<void> => {
        await this.acceptConnection(connection);
      })
      .catch((): void => {
      });
  }

  private async acceptConnection(rawConnection: HarmonyVpnLocalSocketConnectionDriver): Promise<void> {
    if (this.state === STATE_CLOSED) {
      await safeCloseRawConnection(rawConnection);
      return;
    }
    let adapter: HarmonyVpnLocalSocketConnectionAdapter;
    try {
      adapter = new HarmonyVpnLocalSocketConnectionAdapter(rawConnection);
    } catch (_) {
      await safeCloseRawConnection(rawConnection);
      return;
    }
    if (this.activeConnection !== undefined) {
      const previous: HarmonyVpnLocalSocketConnectionAdapter = this.activeConnection;
      this.trackedConnections.delete(previous);
      await previous.close();
    }
    if (this.state === STATE_CLOSED) {
      await adapter.close();
      return;
    }
    this.activeConnection = adapter;
    this.trackedConnections.add(adapter);
    const closeSubscriptionId: number = adapter.subscribeClose((): void => {
      if (this.activeConnection === adapter) {
        this.activeConnection = undefined;
      }
      this.trackedConnections.delete(adapter);
      adapter.unsubscribeClose(closeSubscriptionId);
    });
    try {
      const listener: ((connection: VpnRpcSocketConnectionPort) => void) | undefined = this.listener;
      listener?.(adapter);
    } catch (_) {
      if (this.activeConnection === adapter) {
        this.activeConnection = undefined;
      }
      this.trackedConnections.delete(adapter);
      adapter.unsubscribeClose(closeSubscriptionId);
      await adapter.close();
      this.failCloseServer();
    }
  }

  private failCloseServer(): void {
    void this.close();
  }

  private async closeInternal(): Promise<void> {
    const driver: HarmonyVpnLocalSocketServerDriver | undefined = this.pendingDriver ?? this.registeredDriver;
    this.pendingDriver = undefined;
    this.listener = undefined;
    if (driver !== undefined) {
      await safeCloseServer(driver);
    }
    if (this.registeredDriver !== undefined) {
      this.unregisterCallbacks(this.registeredDriver);
    } else if (driver !== undefined) {
      this.unregisterCallbacks(driver);
    }
    await this.acceptTail;
    const connections: HarmonyVpnLocalSocketConnectionAdapter[] = Array.from(this.trackedConnections.values());
    this.trackedConnections.clear();
    this.activeConnection = undefined;
    for (let index: number = 0; index < connections.length; index += 1) {
      await connections[index].close();
    }
  }
}

class HarmonyVpnSdkLocalSocketServerDriverFactory implements HarmonyVpnLocalSocketServerDriverFactory {
  create(): HarmonyVpnLocalSocketServerDriver {
    return new HarmonyVpnSdkLocalSocketServerDriver(socket.constructLocalSocketServerInstance());
  }
}

class HarmonyVpnSdkLocalSocketServerDriver implements HarmonyVpnLocalSocketServerDriver {
  private readonly raw: socket.LocalSocketServer;
  private readonly connectionBindings: Map<(connection: HarmonyVpnLocalSocketConnectionDriver) => void, (connection: socket.LocalSocketConnection) => void> =
    new Map<(connection: HarmonyVpnLocalSocketConnectionDriver) => void, (connection: socket.LocalSocketConnection) => void>();
  private readonly errorBindings: Map<() => void, (error: Error) => void> = new Map<() => void, (error: Error) => void>();

  constructor(raw: socket.LocalSocketServer) {
    this.raw = raw;
  }

  async listen(address: string): Promise<void> {
    try {
      await this.raw.listen(new HarmonyVpnSdkLocalAddressRecord(address));
    } catch (error) {
      throw createSdkBoundaryFailure(readBusinessErrorCarrier(error));
    }
  }

  async close(): Promise<void> {
    try {
      await this.raw.close();
    } catch (error) {
      throw createSdkBoundaryFailure(readBusinessErrorCarrier(error));
    }
  }

  onConnection(callback: (connection: HarmonyVpnLocalSocketConnectionDriver) => void): void {
    const sdkCallback = (connection: socket.LocalSocketConnection): void => {
      callback(new HarmonyVpnSdkLocalSocketConnectionDriver(connection));
    };
    this.connectionBindings.set(callback, sdkCallback);
    this.raw.on('connect', sdkCallback);
  }

  offConnection(callback?: (connection: HarmonyVpnLocalSocketConnectionDriver) => void): void {
    if (callback === undefined) {
      this.connectionBindings.clear();
      this.raw.off('connect');
      return;
    }
    const binding = this.connectionBindings.get(callback);
    this.connectionBindings.delete(callback);
    this.raw.off('connect', binding);
  }

  onError(callback: () => void): void {
    const sdkCallback = (_: Error): void => {
      callback();
    };
    this.errorBindings.set(callback, sdkCallback);
    this.raw.on('error', sdkCallback);
  }

  offError(callback?: () => void): void {
    if (callback === undefined) {
      this.errorBindings.clear();
      this.raw.off('error');
      return;
    }
    const binding = this.errorBindings.get(callback);
    this.errorBindings.delete(callback);
    this.raw.off('error', binding);
  }
}

class HarmonyVpnSdkLocalAddressRecord implements socket.LocalAddress {
  readonly address: string;

  constructor(address: string) {
    this.address = address;
  }
}

function isValidSocketAddress(address: string): boolean {
  if (address.length === 0) {
    return false;
  }
  for (let index: number = 0; index < address.length; index += 1) {
    const code: number = address.charCodeAt(index);
    if (code <= 0x20 || code === 0x7f) {
      return false;
    }
  }
  return true;
}

function mapListenFailure(error: Error): Error {
  if (error instanceof VpnRpcSocketFailure) {
    return error;
  }
  if (error instanceof HarmonyVpnLocalSocketServerSdkBoundaryFailure && error.code === ADDRESS_IN_USE_ERROR_CODE) {
    return createVpnRpcSocketFailure('ADDRESS_IN_USE');
  }
  const directCode: number = readBusinessErrorCode(readBusinessErrorCarrier(error));
  if (directCode === ADDRESS_IN_USE_ERROR_CODE) {
    return createVpnRpcSocketFailure('ADDRESS_IN_USE');
  }
  return createVpnRpcSocketFailure('PLATFORM_FAILED');
}

function normalizeError(error: Object | undefined): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(SDK_BOUNDARY_FAILURE_MESSAGE);
}

async function safeCloseServer(driver: HarmonyVpnLocalSocketServerDriver): Promise<void> {
  try {
    await driver.close();
  } catch (_) {
  }
}

async function safeCloseRawConnection(connection: HarmonyVpnLocalSocketConnectionDriver): Promise<void> {
  try {
    await connection.close();
  } catch (_) {
  }
}

function createSdkBoundaryFailure(error: BusinessErrorCarrier | undefined): HarmonyVpnLocalSocketServerSdkBoundaryFailure {
  return new HarmonyVpnLocalSocketServerSdkBoundaryFailure(readBusinessErrorCode(error));
}

function readBusinessErrorCarrier(error: Error | object | undefined): BusinessErrorCarrier | undefined {
  if (error === undefined || typeof error !== 'object') {
    return undefined;
  }
  return error as BusinessErrorCarrier;
}

class HarmonyVpnLocalSocketServerSdkBoundaryFailure extends Error {
  readonly code: number;

  constructor(code: number) {
    super(SDK_BOUNDARY_FAILURE_MESSAGE);
    this.code = code;
  }
}

interface BusinessErrorCarrier {
  code?: number;
}

function readBusinessErrorCode(error: BusinessErrorCarrier | undefined): number {
  if (error === undefined || error.code === undefined || !Number.isSafeInteger(error.code)) {
    return SDK_BOUNDARY_FAILURE_CODE;
  }
  return error.code;
}
