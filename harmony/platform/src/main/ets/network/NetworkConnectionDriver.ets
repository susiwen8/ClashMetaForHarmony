export interface DriverNetworkState {
  networkId: string;
  hasInternet: boolean;
}

export interface NetworkConnectionListener {
  netAvailable(networkId: string): void;
  netLost(networkId: string): void;
  netCapabilitiesChange(state: DriverNetworkState): void;
  netUnavailable(): void;
}

export interface NetworkConnectionRegistration {
  register(callback: () => void): Promise<void>;
  unregister(callback: () => void): Promise<void>;
}

export interface NetworkConnectionDriver {
  getDefaultNetwork(): Promise<DriverNetworkState | null>;
  openDefaultConnection(listener: NetworkConnectionListener): NetworkConnectionRegistration;
}
