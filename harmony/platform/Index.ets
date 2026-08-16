export { PlatformFactory } from './src/main/ets/PlatformFactory';
export type { PlatformGraph } from './src/main/ets/PlatformFactory';
export { HarmonyNetworkMonitor } from './src/main/ets/network/HarmonyNetworkMonitor';
export type {
  DriverNetworkState,
  NetworkConnectionDriver,
  NetworkConnectionListener,
  NetworkConnectionRegistration
} from './src/main/ets/network/NetworkConnectionDriver';
export { HarmonyVpnNotificationDriver } from './src/main/ets/background/HarmonyVpnNotificationDriver';
export type {
  ContinuousTaskCancelInfo,
  ContinuousTaskDriver,
  ContinuousTaskNotificationInfo,
  ContinuousTaskWantRequest,
  PlatformAbilityIdentity,
  PlatformContinuousTaskContext
} from './src/main/ets/background/ContinuousTaskDriver';
