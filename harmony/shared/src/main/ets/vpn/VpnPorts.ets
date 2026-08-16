import type {
  NetworkStatus,
  TunHandle,
  TunRuntimeSnapshot,
  TunStartOptions,
  VpnFailure,
  VpnFailureCode,
  VpnCaptureConfig,
  VpnControllerStartResult,
  VpnControllerStopResult,
  VpnRuntimeEvent,
  VpnRuntimeSnapshot
} from './VpnModels';
import { createVpnFailure } from './VpnModels';

export type VpnPlatformErrorCode =
  | 'CONSENT_DENIED'
  | 'PLATFORM_CREATE_FAILED'
  | 'PROCESS_PROTECT_FAILED'
  | 'PROTECT_SOCKET_FAILED';

export type ContinuousNotificationStopErrorCode = 'NOTIFICATION_STOP_FAILED';

export class VpnPlatformPortError extends Error {
  code: VpnPlatformErrorCode;

  constructor(code: VpnPlatformErrorCode, detail: string) {
    super(detail);
    this.code = code;
  }
}

export class ContinuousNotificationPortError extends Error {
  code: ContinuousNotificationStopErrorCode;

  constructor(code: ContinuousNotificationStopErrorCode, detail: string) {
    super(detail);
    this.code = code;
  }
}

export class TunRuntimePortError extends Error {
  failure: VpnFailure;

  constructor(code: VpnFailureCode, detail: string) {
    const failure: VpnFailure = createVpnFailure(code, detail);
    super(failure.detail);
    this.failure = failure;
  }
}

export interface VpnControllerPort {
  start(profileId: string, versionId: string, sessionId: string): Promise<VpnControllerStartResult>;
  stop(sessionId?: string): Promise<VpnControllerStopResult>;
  snapshot(): VpnRuntimeSnapshot;
  subscribe(listener: (event: VpnRuntimeEvent) => void): number;
}

export interface VpnPlatformSessionPort {
  create(config: VpnCaptureConfig): Promise<TunHandle>;
  protectProcess(): Promise<void>;
  protectSocket(fd: number): Promise<void>;
  destroy(vpnId: string): Promise<void>;
}

export interface TunRuntimeEvent {
  sessionId: string;
  snapshot: TunRuntimeSnapshot;
}

export interface TunRuntimePort {
  start(handle: TunHandle, options: TunStartOptions): Promise<TunRuntimeSnapshot>;
  stop(): Promise<void>;
  snapshot(): TunRuntimeSnapshot;
  subscribe(listener: (event: TunRuntimeEvent) => void): number;
  unsubscribe(subscriptionId: number): void;
}

export interface NetworkRecoveryPort {
  currentNetwork(): NetworkStatus;
  subscribeUsableNetwork(listener: (status: NetworkStatus) => void): number;
  unsubscribeUsableNetwork(subscriptionId: number): void;
}

export interface ContinuousNotificationPort {
  start(sessionId: string): Promise<void>;
  stop(sessionId: string): Promise<void>;
  subscribeCancellation(listener: (sessionId: string) => void): number;
  unsubscribeCancellation(subscriptionId: number): void;
}

export interface CommittedProfileResolverPort {
  resolve(profileId: string, versionId: string): Promise<VpnCaptureConfig>;
}

export interface ClockPort {
  nowMs(): number;
}

export interface CancelableDelayTask {
  cancel(): void;
}

export interface BoundedDelaySchedulerPort {
  schedule(delayMs: number, runner: () => Promise<void>): CancelableDelayTask;
}

export interface VpnRuntimeCoordinatorDependencies {
  resolver: CommittedProfileResolverPort;
  platform: VpnPlatformSessionPort;
  tunRuntime: TunRuntimePort;
  networkRecovery: NetworkRecoveryPort;
  notification: ContinuousNotificationPort;
  scheduler: BoundedDelaySchedulerPort;
  clock: ClockPort;
}
