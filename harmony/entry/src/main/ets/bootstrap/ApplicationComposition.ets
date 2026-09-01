import type {
  AppError,
  ProfileApplication,
  RuntimeLogExportPort,
  RuntimeLogStorePort,
  VpnRpcRuntimeModeClientPort
} from '@cmfa/shared';
import type { VpnTrafficMonitorReadPort } from '../vpn/VpnTrafficMonitor';
import type { VpnSessionRegistry } from '../vpn/VpnSessionRegistry';

interface ApplicationCompositionLoadingState {
  status: 'LOADING';
}

interface ApplicationCompositionReadyState {
  status: 'READY';
  application: ProfileApplication;
  vpnRegistry: VpnSessionRegistry;
  runtimeModeClient?: VpnRpcRuntimeModeClientPort;
  trafficMonitor?: VpnTrafficMonitorReadPort;
  runtimeLogStore?: RuntimeLogStorePort;
  runtimeLogExporter?: RuntimeLogExportPort;
}

interface ApplicationCompositionErrorState {
  status: 'ERROR';
  error: AppError;
}

export type ApplicationCompositionState =
  | ApplicationCompositionLoadingState
  | ApplicationCompositionReadyState
  | ApplicationCompositionErrorState;

export interface ApplicationComposition {
  initialize(): Promise<void>;
  state(): ApplicationCompositionState;
  subscribe(listener: (state: ApplicationCompositionState) => void): number;
  unsubscribe(id: number): void;
  close(): Promise<void>;
}
