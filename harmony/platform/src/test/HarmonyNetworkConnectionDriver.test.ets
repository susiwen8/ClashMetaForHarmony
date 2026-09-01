import { describe, expect, it } from '@ohos/hypium';
import {
  HarmonyNetworkConnectionDriver,
  type HarmonyNetworkCapabilities,
  type HarmonyNetworkConnectionApi,
  type HarmonyNetworkHandle,
  type HarmonySystemNetConnection
} from '../main/ets/network/HarmonyNetworkConnectionDriver';
import type { NetworkConnectionListener, NetworkConnectionRegistration } from '../main/ets/network/NetworkConnectionDriver';

const INTERNET: number = 12;
const VALIDATED: number = 16;

class TestHandle implements HarmonyNetworkHandle {
  netId: number;

  constructor(netId: number) {
    this.netId = netId;
  }
}

class TestCapabilities implements HarmonyNetworkCapabilities {
  networkCap: number[];

  constructor(networkCap: number[]) {
    this.networkCap = networkCap.slice();
  }
}

class FakeSystemConnection implements HarmonySystemNetConnection {
  available?: (handle: HarmonyNetworkHandle) => void;
  lost?: (handle: HarmonyNetworkHandle) => void;
  capabilities?: (handle: HarmonyNetworkHandle, capabilities: HarmonyNetworkCapabilities) => void;
  unavailable?: () => void;
  registerCount: number = 0;
  unregisterCount: number = 0;

  onAvailable(callback: (handle: HarmonyNetworkHandle) => void): void {
    this.available = callback;
  }

  onLost(callback: (handle: HarmonyNetworkHandle) => void): void {
    this.lost = callback;
  }

  onCapabilitiesChange(callback: (handle: HarmonyNetworkHandle, capabilities: HarmonyNetworkCapabilities) => void): void {
    this.capabilities = callback;
  }

  onUnavailable(callback: () => void): void {
    this.unavailable = callback;
  }

  async register(): Promise<void> {
    this.registerCount += 1;
  }

  async unregister(): Promise<void> {
    this.unregisterCount += 1;
  }
}

class FakeNetworkApi implements HarmonyNetworkConnectionApi {
  defaultHandle: HarmonyNetworkHandle = new TestHandle(0);
  capabilitiesByNetId: Map<number, HarmonyNetworkCapabilities> = new Map();
  connection: FakeSystemConnection = new FakeSystemConnection();

  async getDefaultNet(): Promise<HarmonyNetworkHandle> {
    return new TestHandle(this.defaultHandle.netId);
  }

  async getNetCapabilities(handle: HarmonyNetworkHandle): Promise<HarmonyNetworkCapabilities> {
    return this.capabilitiesByNetId.get(handle.netId) ?? new TestCapabilities([]);
  }

  createNetConnection(): HarmonySystemNetConnection {
    return this.connection;
  }
}

class RecordingListener implements NetworkConnectionListener {
  readonly events: string[] = [];

  netAvailable(networkId: string): void {
    this.events.push(`available:${networkId}`);
  }

  netLost(networkId: string): void {
    this.events.push(`lost:${networkId}`);
  }

  netCapabilitiesChange(state: import('../main/ets/network/NetworkConnectionDriver').DriverNetworkState): void {
    this.events.push(`capabilities:${state.networkId}:${state.hasInternet}`);
  }

  netUnavailable(): void {
    this.events.push('unavailable');
  }
}

export default function harmonyNetworkConnectionDriverTestsuite() {
  describe('HarmonyNetworkConnectionDriverTest', () => {
    it('mapsDefaultNetworkOnlyWhenInternetIsValidated', 0, async () => {
      const api = new FakeNetworkApi();
      const driver = new HarmonyNetworkConnectionDriver(api);

      expect((await driver.getDefaultNetwork()) === null).assertTrue();

      api.defaultHandle = new TestHandle(100);
      api.capabilitiesByNetId.set(100, new TestCapabilities([INTERNET]));
      const internetOnly = await driver.getDefaultNetwork();
      expect(internetOnly?.networkId).assertEqual('100');
      expect(internetOnly?.hasInternet).assertFalse();

      api.capabilitiesByNetId.set(100, new TestCapabilities([INTERNET, VALIDATED]));
      const validated = await driver.getDefaultNetwork();
      expect(validated?.networkId).assertEqual('100');
      expect(validated?.hasInternet).assertTrue();
    });

    it('forwardsEventsAndKeepsRegistrationIdempotent', 0, async () => {
      const api = new FakeNetworkApi();
      api.capabilitiesByNetId.set(101, new TestCapabilities([INTERNET, VALIDATED]));
      const driver = new HarmonyNetworkConnectionDriver(api);
      const listener = new RecordingListener();
      const registration: NetworkConnectionRegistration = driver.openDefaultConnection(listener);
      const completed = (): void => {
      };

      await registration.register(completed);
      await registration.register(completed);
      api.connection.available?.(new TestHandle(101));
      await Promise.resolve();
      api.connection.capabilities?.(new TestHandle(102), new TestCapabilities([INTERNET]));
      api.connection.lost?.(new TestHandle(101));
      api.connection.unavailable?.();
      await registration.unregister(completed);
      await registration.unregister(completed);

      expect(api.connection.registerCount).assertEqual(1);
      expect(api.connection.unregisterCount).assertEqual(1);
      expect(listener.events.join('|')).assertEqual(
        'available:101|capabilities:101:true|capabilities:102:false|lost:101|unavailable'
      );
    });
  });
}
