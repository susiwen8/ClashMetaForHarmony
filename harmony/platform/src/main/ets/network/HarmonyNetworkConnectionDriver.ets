import { connection } from '@kit.NetworkKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import type {
  DriverNetworkState,
  NetworkConnectionDriver,
  NetworkConnectionListener,
  NetworkConnectionRegistration
} from './NetworkConnectionDriver';

export interface HarmonyNetworkHandle {
  netId: number;
}

export interface HarmonyNetworkCapabilities {
  networkCap?: number[];
}

export interface HarmonySystemNetConnection {
  onAvailable(callback: (handle: HarmonyNetworkHandle) => void): void;
  onLost(callback: (handle: HarmonyNetworkHandle) => void): void;
  onCapabilitiesChange(
    callback: (handle: HarmonyNetworkHandle, capabilities: HarmonyNetworkCapabilities) => void
  ): void;
  onUnavailable(callback: () => void): void;
  register(): Promise<void>;
  unregister(): Promise<void>;
}

export interface HarmonyNetworkConnectionApi {
  getDefaultNet(): Promise<HarmonyNetworkHandle>;
  getNetCapabilities(handle: HarmonyNetworkHandle): Promise<HarmonyNetworkCapabilities>;
  createNetConnection(): HarmonySystemNetConnection;
}

class DriverNetworkStateValue implements DriverNetworkState {
  networkId: string;
  hasInternet: boolean;

  constructor(networkId: string, hasInternet: boolean) {
    this.networkId = networkId;
    this.hasInternet = hasInternet;
  }
}

class HarmonyNetworkHandleValue implements HarmonyNetworkHandle {
  netId: number;

  constructor(netId: number) {
    this.netId = netId;
  }
}

class HarmonyNetworkCapabilitiesValue implements HarmonyNetworkCapabilities {
  networkCap?: number[];

  constructor(networkCap?: number[]) {
    this.networkCap = networkCap === undefined ? undefined : networkCap.slice();
  }
}

class NetworkKitHandleValue extends HarmonyNetworkHandleValue {
  readonly nativeHandle: connection.NetHandle;

  constructor(nativeHandle: connection.NetHandle) {
    super(nativeHandle.netId);
    this.nativeHandle = nativeHandle;
  }
}

class NetworkKitSystemConnection implements HarmonySystemNetConnection {
  private readonly nativeConnection: connection.NetConnection;

  constructor(nativeConnection: connection.NetConnection) {
    this.nativeConnection = nativeConnection;
  }

  onAvailable(callback: (handle: HarmonyNetworkHandle) => void): void {
    this.nativeConnection.on('netAvailable', (handle: connection.NetHandle): void => {
      callback(new NetworkKitHandleValue(handle));
    });
  }

  onLost(callback: (handle: HarmonyNetworkHandle) => void): void {
    this.nativeConnection.on('netLost', (handle: connection.NetHandle): void => {
      callback(new NetworkKitHandleValue(handle));
    });
  }

  onCapabilitiesChange(
    callback: (handle: HarmonyNetworkHandle, capabilities: HarmonyNetworkCapabilities) => void
  ): void {
    this.nativeConnection.on('netCapabilitiesChange', (info: connection.NetCapabilityInfo): void => {
      callback(
        new NetworkKitHandleValue(info.netHandle),
        new HarmonyNetworkCapabilitiesValue(copyCapabilities(info.netCap))
      );
    });
  }

  onUnavailable(callback: () => void): void {
    this.nativeConnection.on('netUnavailable', callback);
  }

  register(): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      try {
        this.nativeConnection.register((error: BusinessError): void => {
          if (error !== undefined && error.code !== 0) {
            reject(new Error('Default network listener registration failed.'));
            return;
          }
          resolve();
        });
      } catch (_) {
        reject(new Error('Default network listener registration failed.'));
      }
    });
  }

  unregister(): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      try {
        this.nativeConnection.unregister((error: BusinessError): void => {
          if (error !== undefined && error.code !== 0) {
            reject(new Error('Default network listener unregistration failed.'));
            return;
          }
          resolve();
        });
      } catch (_) {
        reject(new Error('Default network listener unregistration failed.'));
      }
    });
  }
}

class NetworkKitConnectionApi implements HarmonyNetworkConnectionApi {
  async getDefaultNet(): Promise<HarmonyNetworkHandle> {
    const handle: connection.NetHandle = await connection.getDefaultNet();
    return new NetworkKitHandleValue(handle);
  }

  async getNetCapabilities(handle: HarmonyNetworkHandle): Promise<HarmonyNetworkCapabilities> {
    if (!(handle instanceof NetworkKitHandleValue)) {
      throw new Error('Default network handle was not created by NetworkKit.');
    }
    const capabilities: connection.NetCapabilities = await connection.getNetCapabilities(handle.nativeHandle);
    return new HarmonyNetworkCapabilitiesValue(copyCapabilities(capabilities));
  }

  createNetConnection(): HarmonySystemNetConnection {
    return new NetworkKitSystemConnection(connection.createNetConnection());
  }
}

class HarmonyNetworkConnectionRegistration implements NetworkConnectionRegistration {
  private readonly api: HarmonyNetworkConnectionApi;
  private readonly listener: NetworkConnectionListener;
  private readonly connection: HarmonySystemNetConnection;
  private registered: boolean = false;
  private registerPromise?: Promise<void>;
  private unregisterPromise?: Promise<void>;

  constructor(api: HarmonyNetworkConnectionApi, listener: NetworkConnectionListener) {
    this.api = api;
    this.listener = listener;
    this.connection = api.createNetConnection();
    this.bindEvents();
  }

  register(callback: () => void): Promise<void> {
    if (this.registered) {
      return Promise.resolve();
    }
    if (this.registerPromise !== undefined) {
      return this.registerPromise;
    }
    const promise: Promise<void> = this.connection.register().then((): void => {
      this.registered = true;
      callback();
    }).finally((): void => {
      if (this.registerPromise === promise) {
        this.registerPromise = undefined;
      }
    });
    this.registerPromise = promise;
    return promise;
  }

  unregister(callback: () => void): Promise<void> {
    if (this.unregisterPromise !== undefined) {
      return this.unregisterPromise;
    }
    if (!this.registered && this.registerPromise === undefined) {
      return Promise.resolve();
    }
    const awaitRegistration: Promise<void> = this.registerPromise ?? Promise.resolve();
    const promise: Promise<void> = awaitRegistration.then(async (): Promise<void> => {
      if (!this.registered) {
        return;
      }
      await this.connection.unregister();
      this.registered = false;
      callback();
    }).finally((): void => {
      if (this.unregisterPromise === promise) {
        this.unregisterPromise = undefined;
      }
    });
    this.unregisterPromise = promise;
    return promise;
  }

  private bindEvents(): void {
    this.connection.onAvailable((handle: HarmonyNetworkHandle): void => {
      void this.handleAvailable(handle);
    });
    this.connection.onLost((handle: HarmonyNetworkHandle): void => {
      this.listener.netLost(networkIdOf(handle));
    });
    this.connection.onCapabilitiesChange((handle: HarmonyNetworkHandle, capabilities: HarmonyNetworkCapabilities): void => {
      this.listener.netCapabilitiesChange(
        new DriverNetworkStateValue(networkIdOf(handle), hasValidatedInternet(capabilities))
      );
    });
    this.connection.onUnavailable((): void => {
      this.listener.netUnavailable();
    });
  }

  private async handleAvailable(handle: HarmonyNetworkHandle): Promise<void> {
    const networkId: string = networkIdOf(handle);
    this.listener.netAvailable(networkId);
    try {
      const capabilities: HarmonyNetworkCapabilities = await this.api.getNetCapabilities(handle);
      this.listener.netCapabilitiesChange(
        new DriverNetworkStateValue(networkId, hasValidatedInternet(capabilities))
      );
      return;
    } catch (_) {
    }
    this.listener.netCapabilitiesChange(new DriverNetworkStateValue(networkId, false));
  }
}

export class HarmonyNetworkConnectionDriver implements NetworkConnectionDriver {
  private readonly api: HarmonyNetworkConnectionApi;

  constructor(api?: HarmonyNetworkConnectionApi) {
    this.api = api ?? new NetworkKitConnectionApi();
  }

  async getDefaultNetwork(): Promise<DriverNetworkState | null> {
    const handle: HarmonyNetworkHandle = await this.api.getDefaultNet();
    if (!isUsableNetId(handle.netId)) {
      return null;
    }
    const capabilities: HarmonyNetworkCapabilities = await this.api.getNetCapabilities(handle);
    return new DriverNetworkStateValue(networkIdOf(handle), hasValidatedInternet(capabilities));
  }

  openDefaultConnection(listener: NetworkConnectionListener): NetworkConnectionRegistration {
    return new HarmonyNetworkConnectionRegistration(this.api, listener);
  }
}

function isUsableNetId(netId: number): boolean {
  return Number.isSafeInteger(netId) && netId > 0;
}

function networkIdOf(handle: HarmonyNetworkHandle): string {
  return isUsableNetId(handle.netId) ? `${handle.netId}` : '';
}

function hasValidatedInternet(capabilities: HarmonyNetworkCapabilities): boolean {
  const values: number[] = capabilities.networkCap ?? [];
  return containsCapability(values, connection.NetCap.NET_CAPABILITY_INTERNET) &&
    containsCapability(values, connection.NetCap.NET_CAPABILITY_VALIDATED);
}

function containsCapability(values: number[], expected: number): boolean {
  for (let index: number = 0; index < values.length; index += 1) {
    if (values[index] === expected) {
      return true;
    }
  }
  return false;
}

function copyCapabilities(capabilities: connection.NetCapabilities): number[] {
  const source: connection.NetCap[] = capabilities.networkCap ?? [];
  const copy: number[] = [];
  for (let index: number = 0; index < source.length; index += 1) {
    copy.push(source[index]);
  }
  return copy;
}
