import { describe, expect, it } from '@ohos/hypium';
import type { NetworkStatus } from '@cmfa/shared';
import { HarmonyNetworkMonitor } from '../main/ets/network/HarmonyNetworkMonitor';
import type {
  DriverNetworkState,
  NetworkConnectionDriver,
  NetworkConnectionListener,
  NetworkConnectionRegistration
} from '../main/ets/network/NetworkConnectionDriver';

class DriverNetworkStateValue implements DriverNetworkState {
  readonly networkId: string;
  readonly hasInternet: boolean;

  constructor(networkId: string, hasInternet: boolean) {
    this.networkId = networkId;
    this.hasInternet = hasInternet;
  }
}

class NetworkStatusValue implements NetworkStatus {
  networkId: string;
  usable: boolean;

  constructor(networkId: string, usable: boolean) {
    this.networkId = networkId;
    this.usable = usable;
  }
}

class DeferredVoid {
  readonly promise: Promise<void>;
  private resolveRef?: () => void;

  constructor() {
    this.promise = new Promise<void>((resolve) => {
      this.resolveRef = resolve;
    });
  }

  resolve(): void {
    this.resolveRef!();
  }
}

class FakeNetworkConnectionRegistration implements NetworkConnectionRegistration {
  readonly registerCallbacks: Array<() => void> = [];
  readonly unregisterCallbacks: Array<() => void> = [];
  listener?: NetworkConnectionListener;
  registerCallCount: number = 0;
  unregisterCallCount: number = 0;
  registerGate?: DeferredVoid;

  async register(callback: () => void): Promise<void> {
    this.registerCallCount += 1;
    this.registerCallbacks.push(callback);
    if (this.registerGate !== undefined) {
      await this.registerGate.promise;
    }
  }

  async unregister(callback: () => void): Promise<void> {
    this.unregisterCallCount += 1;
    this.unregisterCallbacks.push(callback);
  }

  emitAvailable(networkId: string): void {
    this.listener?.netAvailable(networkId);
  }

  emitLost(networkId: string): void {
    this.listener?.netLost(networkId);
  }

  emitCapabilitiesChange(networkId: string, hasInternet: boolean): void {
    this.listener?.netCapabilitiesChange({
      networkId,
      hasInternet
    });
  }

  emitUnavailable(): void {
    this.listener?.netUnavailable();
  }
}

class FakeNetworkConnectionDriver implements NetworkConnectionDriver {
  defaultNetwork: DriverNetworkState | null = null;
  readonly registration: FakeNetworkConnectionRegistration = new FakeNetworkConnectionRegistration();
  getDefaultNetworkCallCount: number = 0;
  openDefaultConnectionCallCount: number = 0;

  async getDefaultNetwork(): Promise<DriverNetworkState | null> {
    this.getDefaultNetworkCallCount += 1;
    if (this.defaultNetwork === null) {
      return null;
    }
    return new DriverNetworkStateValue(this.defaultNetwork.networkId, this.defaultNetwork.hasInternet);
  }

  openDefaultConnection(listener: NetworkConnectionListener): NetworkConnectionRegistration {
    this.openDefaultConnectionCallCount += 1;
    this.registration.listener = listener;
    return this.registration;
  }
}

function assertStatus(status: NetworkStatus, networkId: string, usable: boolean): void {
  expect(status.networkId).assertEqual(networkId);
  expect(status.usable).assertEqual(usable);
}

function cloneStatus(status: NetworkStatus): NetworkStatus {
  return new NetworkStatusValue(status.networkId, status.usable);
}

export default function harmonyNetworkMonitorTestsuite() {
  describe('HarmonyNetworkMonitorTest', () => {
    it('returnsClonedCurrentNetworkAndDistinguishesUnavailableNetworks', 0, async () => {
      const driver = new FakeNetworkConnectionDriver();
      driver.defaultNetwork = new DriverNetworkStateValue('net-100', true);
      const usableMonitor = new HarmonyNetworkMonitor(driver);

      await usableMonitor.initialize();

      const firstStatus = usableMonitor.currentNetwork();
      assertStatus(firstStatus, 'net-100', true);
      firstStatus.networkId = 'mutated';
      firstStatus.usable = false;

      const secondStatus = usableMonitor.currentNetwork();
      assertStatus(secondStatus, 'net-100', true);

      const unavailableDriver = new FakeNetworkConnectionDriver();
      unavailableDriver.defaultNetwork = new DriverNetworkStateValue('net-200', false);
      const unavailableMonitor = new HarmonyNetworkMonitor(unavailableDriver);

      await unavailableMonitor.initialize();

      assertStatus(unavailableMonitor.currentNetwork(), 'net-200', false);
      await usableMonitor.dispose();
      await unavailableMonitor.dispose();
    });

    it('sharesOneUnderlyingRegistrationAcrossSubscribersAndClonesNotifications', 0, async () => {
      const driver = new FakeNetworkConnectionDriver();
      driver.defaultNetwork = new DriverNetworkStateValue('net-100', true);
      const monitor = new HarmonyNetworkMonitor(driver);
      const firstEvents: NetworkStatus[] = [];
      const secondEvents: NetworkStatus[] = [];

      await monitor.initialize();
      const firstSubscription = monitor.subscribeUsableNetwork((status: NetworkStatus) => {
        firstEvents.push(cloneStatus(status));
      });
      const secondSubscription = monitor.subscribeUsableNetwork((status: NetworkStatus) => {
        secondEvents.push(cloneStatus(status));
      });

      expect(driver.openDefaultConnectionCallCount).assertEqual(1);
      expect(driver.registration.registerCallCount).assertEqual(1);

      driver.registration.emitAvailable('net-101');
      driver.registration.emitLost('net-101');
      driver.registration.emitCapabilitiesChange('net-102', true);
      driver.registration.emitCapabilitiesChange('net-103', false);

      expect(firstEvents.length).assertEqual(4);
      expect(secondEvents.length).assertEqual(4);
      assertStatus(firstEvents[0], 'net-101', true);
      assertStatus(firstEvents[1], 'net-101', false);
      assertStatus(firstEvents[2], 'net-102', true);
      assertStatus(firstEvents[3], 'net-103', false);
      assertStatus(secondEvents[0], 'net-101', true);
      assertStatus(secondEvents[1], 'net-101', false);
      assertStatus(secondEvents[2], 'net-102', true);
      assertStatus(secondEvents[3], 'net-103', false);

      firstEvents[0].networkId = 'mutated';
      firstEvents[0].usable = false;
      assertStatus(secondEvents[0], 'net-101', true);
      assertStatus(monitor.currentNetwork(), 'net-103', false);

      monitor.unsubscribeUsableNetwork(firstSubscription);
      monitor.unsubscribeUsableNetwork(secondSubscription);
      await monitor.dispose();
    });

    it('disposesIdempotentlyUnregistersTheExactCallbackAndIgnoresLateCallbacks', 0, async () => {
      const driver = new FakeNetworkConnectionDriver();
      driver.defaultNetwork = new DriverNetworkStateValue('net-100', true);
      const monitor = new HarmonyNetworkMonitor(driver);
      const received: NetworkStatus[] = [];

      await monitor.initialize();
      monitor.subscribeUsableNetwork((status: NetworkStatus) => {
        received.push(cloneStatus(status));
      });

      const registeredCallback = driver.registration.registerCallbacks[0];
      expect(registeredCallback !== undefined).assertTrue();

      await monitor.dispose();
      await monitor.dispose();

      expect(driver.registration.unregisterCallCount).assertEqual(1);
      expect(driver.registration.unregisterCallbacks.length).assertEqual(1);
      expect(driver.registration.unregisterCallbacks[0] === registeredCallback).assertTrue();

      driver.registration.emitAvailable('late-net');
      driver.registration.emitLost('late-net');
      driver.registration.emitCapabilitiesChange('late-net', true);
      driver.registration.emitUnavailable();

      expect(received.length).assertEqual(0);
      assertStatus(monitor.currentNetwork(), 'net-100', true);
    });

    it('waitsForInFlightInitializationBeforeUnregisteringDuringDispose', 0, async () => {
      const driver = new FakeNetworkConnectionDriver();
      driver.defaultNetwork = new DriverNetworkStateValue('net-100', true);
      const gate = new DeferredVoid();
      driver.registration.registerGate = gate;
      const monitor = new HarmonyNetworkMonitor(driver);

      const initializePromise: Promise<void> = monitor.initialize();
      expect(driver.registration.registerCallCount).assertEqual(1);
      const disposePromise: Promise<void> = monitor.dispose();
      expect(driver.registration.unregisterCallCount).assertEqual(0);

      gate.resolve();
      await initializePromise;
      await disposePromise;

      expect(driver.registration.unregisterCallCount).assertEqual(1);
      expect(driver.registration.unregisterCallbacks[0] === driver.registration.registerCallbacks[0]).assertTrue();
    });

    it('doesNotInitializeAfterItWasDisposed', 0, async () => {
      const driver = new FakeNetworkConnectionDriver();
      const monitor = new HarmonyNetworkMonitor(driver);

      await monitor.dispose();
      await monitor.initialize();

      expect(driver.openDefaultConnectionCallCount).assertEqual(0);
      expect(driver.registration.registerCallCount).assertEqual(0);
    });
  });
}
