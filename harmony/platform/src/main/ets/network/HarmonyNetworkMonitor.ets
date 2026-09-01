import type { NetworkRecoveryPort, NetworkStatus } from '@cmfa/shared';
import type {
  DriverNetworkState,
  NetworkConnectionDriver,
  NetworkConnectionListener,
  NetworkConnectionRegistration
} from './NetworkConnectionDriver';

class NetworkStatusValue implements NetworkStatus {
  networkId: string;
  usable: boolean;

  constructor(networkId: string, usable: boolean) {
    this.networkId = networkId;
    this.usable = usable;
  }
}

class ConnectionEventBridge implements NetworkConnectionListener {
  private readonly monitor: HarmonyNetworkMonitor;

  constructor(monitor: HarmonyNetworkMonitor) {
    this.monitor = monitor;
  }

  netAvailable(networkId: string): void {
    this.monitor.markCandidateNetwork(networkId);
  }

  netLost(networkId: string): void {
    const wasCurrent: boolean = this.monitor.isCurrentNetwork(networkId);
    if (!wasCurrent && !this.monitor.isCandidateNetwork(networkId)) {
      return;
    }
    this.monitor.forgetCandidateNetwork(networkId);
    if (wasCurrent) {
      this.monitor.publish(new NetworkStatusValue('', false));
    }
  }

  netCapabilitiesChange(state: DriverNetworkState): void {
    if (!this.monitor.isCurrentNetwork(state.networkId) && !this.monitor.isCandidateNetwork(state.networkId)) {
      return;
    }
    this.monitor.publish(new NetworkStatusValue(state.networkId, state.hasInternet));
  }

  netUnavailable(): void {
    if (this.monitor.isDisposed()) {
      return;
    }
    this.monitor.clearCandidateNetwork();
    this.monitor.publish(new NetworkStatusValue('', false));
  }
}

class OpaqueNetworkConnectionRegistration implements NetworkConnectionRegistration {
  async register(_callback: () => void): Promise<void> {
  }

  async unregister(_callback: () => void): Promise<void> {
  }
}

class OpaqueNetworkConnectionDriver implements NetworkConnectionDriver {
  async getDefaultNetwork(): Promise<DriverNetworkState | null> {
    return null;
  }

  openDefaultConnection(_listener: NetworkConnectionListener): NetworkConnectionRegistration {
    return new OpaqueNetworkConnectionRegistration();
  }
}

export class HarmonyNetworkMonitor implements NetworkRecoveryPort {
  private readonly driver: NetworkConnectionDriver;
  private readonly listeners: Map<number, (status: NetworkStatus) => void> = new Map();
  private readonly registerCallback: () => void = () => {
  };
  private readonly connectionListener: NetworkConnectionListener;
  private nextSubscriptionId: number = 1;
  private currentStatusValue: NetworkStatus = new NetworkStatusValue('', false);
  private candidateNetworkId: string = '';
  private registration?: NetworkConnectionRegistration;
  private initializePromise?: Promise<void>;
  private disposePromise?: Promise<void>;
  private disposed: boolean = false;

  constructor(driver?: NetworkConnectionDriver) {
    this.driver = driver ?? new OpaqueNetworkConnectionDriver();
    this.connectionListener = new ConnectionEventBridge(this);
  }

  initialize(): Promise<void> {
    if (this.initializePromise !== undefined) {
      return this.initializePromise;
    }
    if (this.disposed) {
      return Promise.resolve();
    }
    const initializePromise: Promise<void> = this.initializeInternal().catch(() => {
      this.updateCurrentStatus(new NetworkStatusValue('', false));
    });
    this.initializePromise = initializePromise;
    return initializePromise;
  }

  currentNetwork(): NetworkStatus {
    return cloneStatus(this.currentStatusValue);
  }

  subscribeUsableNetwork(listener: (status: NetworkStatus) => void): number {
    const subscriptionId: number = this.nextSubscriptionId;
    this.nextSubscriptionId += 1;
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribeUsableNetwork(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }

  async dispose(): Promise<void> {
    if (this.disposePromise !== undefined) {
      await this.disposePromise;
      return;
    }
    this.disposed = true;
    const disposePromise: Promise<void> = this.disposeInternal();
    this.disposePromise = disposePromise;
    await disposePromise;
  }

  private async disposeInternal(): Promise<void> {
    const initializePromise: Promise<void> | undefined = this.initializePromise;
    if (initializePromise !== undefined) {
      await initializePromise;
    }
    const registration: NetworkConnectionRegistration | undefined = this.registration;
    if (registration === undefined) {
      return;
    }
    try {
      await registration.unregister(this.registerCallback);
    } catch (_) {
    }
  }

  private async initializeInternal(): Promise<void> {
    const registration: NetworkConnectionRegistration = this.driver.openDefaultConnection(this.connectionListener);
    this.registration = registration;
    try {
      await registration.register(this.registerCallback);
      if (this.disposed) {
        return;
      }
      const currentState: DriverNetworkState | null = await this.driver.getDefaultNetwork();
      if (this.disposed) {
        return;
      }
      this.updateCurrentStatus(toNetworkStatus(currentState));
    } catch (_) {
      this.updateCurrentStatus(new NetworkStatusValue('', false));
    }
  }

  isDisposed(): boolean {
    return this.disposed;
  }

  isCurrentNetwork(networkId: string): boolean {
    return networkId.length > 0 && this.currentStatusValue.networkId === networkId;
  }

  isCandidateNetwork(networkId: string): boolean {
    return networkId.length > 0 && this.candidateNetworkId === networkId;
  }

  markCandidateNetwork(networkId: string): void {
    if (this.disposed || networkId.length === 0) {
      return;
    }
    this.candidateNetworkId = networkId;
  }

  forgetCandidateNetwork(networkId: string): void {
    if (this.candidateNetworkId === networkId) {
      this.candidateNetworkId = '';
    }
  }

  clearCandidateNetwork(): void {
    this.candidateNetworkId = '';
  }

  updateCurrentStatus(status: NetworkStatus): void {
    this.currentStatusValue = cloneStatus(status);
    this.candidateNetworkId = status.networkId;
  }

  publish(status: NetworkStatus): void {
    if (this.disposed) {
      return;
    }
    this.currentStatusValue = cloneStatus(status);
    const snapshotListeners: Array<(status: NetworkStatus) => void> = [];
    this.listeners.forEach((listener: (status: NetworkStatus) => void) => {
      snapshotListeners.push(listener);
    });
    for (let index: number = 0; index < snapshotListeners.length; index += 1) {
      snapshotListeners[index](cloneStatus(this.currentStatusValue));
    }
  }
}

function toNetworkStatus(state: DriverNetworkState | null): NetworkStatus {
  if (state === null) {
    return new NetworkStatusValue('', false);
  }
  return new NetworkStatusValue(state.networkId, state.hasInternet);
}

function cloneStatus(status: NetworkStatus): NetworkStatus {
  return new NetworkStatusValue(status.networkId, status.usable);
}
