import type {
  NetworkStatus,
  TunHandle,
  TunRuntimeFailure,
  TunRuntimeFailureCode,
  TunRuntimeSnapshot,
  TunStartOptions,
  VpnFailure,
  VpnCaptureConfig,
  VpnControllerStartResult,
  VpnControllerStopResult,
  VpnRuntimeEvent,
  VpnRuntimeSnapshot
} from './VpnModels';
import type { VpnRpcGuards } from './rpc/VpnRpcModels';
import type { VpnProxyRuntimeLifecyclePort } from '../proxy/ProxyPorts';
import { createTunRuntimeFailure, createVpnFailure } from './VpnModels';

export type VpnPlatformErrorCode =
  | 'ALREADY_ACTIVE'
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

export class OwnershipStoreCorruptError extends Error {
  constructor() {
    super('VPN ownership store is corrupt.');
  }
}

export class TunRuntimePortError extends Error {
  failure: TunRuntimeFailure;
  nativeCode: string;

  constructor(code: TunRuntimeFailureCode, detail: string, nativeCode: string = code) {
    const failure: TunRuntimeFailure = createTunRuntimeFailure(code, detail);
    super(failure.detail);
    this.failure = failure;
    this.nativeCode = nativeCode.trim().length > 0 ? nativeCode : code;
  }
}

export interface VpnControllerPort {
  start(profileId: string, versionId: string, sessionId: string): Promise<VpnControllerStartResult>;
  stop(sessionId?: string): Promise<VpnControllerStopResult>;
  initializeRuntimeMirror?(): Promise<void>;
  dispose?(): Promise<void> | void;
  snapshot(): VpnRuntimeSnapshot;
  subscribe(listener: (event: VpnRuntimeEvent) => void): number;
  unsubscribe(subscriptionId: number): void;
}

export interface VpnRpcClientContext {
  sessionGeneration: number;
  guards: VpnRpcGuards;
}

export interface VpnPlatformSessionPort {
  create(config: VpnCaptureConfig): Promise<TunHandle>;
  protectProcess(): Promise<void>;
  protectSocket(fd: number): Promise<void>;
  destroy(vpnId: string): Promise<void>;
}

export type VpnPlatformOwnershipPhase = 'PREPARED' | 'ACTIVE' | 'RELEASED';
export type VpnPlatformOwnershipBinding = 'PLATFORM_ID' | 'LEGACY_GLOBAL';

export interface VpnPlatformOwnershipRecord {
  phase: VpnPlatformOwnershipPhase;
  vpnId: string;
  binding: VpnPlatformOwnershipBinding;
}

export interface VpnPlatformOwnershipStorePort {
  read(): Promise<VpnPlatformOwnershipRecord | null>;
  write(ownership: VpnPlatformOwnershipRecord): Promise<void>;
  clearExpected(ownership: VpnPlatformOwnershipRecord): Promise<void>;
}

export interface TunRuntimeEvent {
  sessionId: string;
  snapshot: TunRuntimeSnapshot;
  diagnosticStage?: string;
}

export interface TunRuntimePort {
  start(handle: TunHandle, options: TunStartOptions): Promise<TunRuntimeSnapshot>;
  stop(): Promise<void>;
  closeStaleOutboundConnections(sessionId: string): Promise<void>;
  recover(sessionId: string): Promise<TunRuntimeSnapshot>;
  snapshot(): TunRuntimeSnapshot;
  subscribe(listener: (event: TunRuntimeEvent) => void): number;
  unsubscribe(subscriptionId: number): void;
  dispose(): void;
}

export interface NetworkRecoveryPort {
  currentNetwork(): NetworkStatus;
  subscribeUsableNetwork(listener: (status: NetworkStatus) => void): number;
  unsubscribeUsableNetwork(subscriptionId: number): void;
  dispose?(): Promise<void> | void;
}

export interface ContinuousNotificationPort {
  start(sessionId: string): Promise<void>;
  stop(sessionId: string): Promise<void>;
  updateTraffic(
    sessionId: string,
    uploadBytesPerSecond: number,
    downloadBytesPerSecond: number
  ): Promise<void>;
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

export type OneClickVpnConfirmationResultKind =
  | 'RUNNING'
  | 'STOPPED'
  | 'ERROR'
  | 'SESSION_CHANGED'
  | 'TIMEOUT'
  | 'CANCELLED';

export interface OneClickVpnConfirmationResult {
  kind: OneClickVpnConfirmationResultKind;
}

export interface OneClickVpnConfirmationHandle {
  wait(): Promise<OneClickVpnConfirmationResult>;
  markStartAccepted(): void;
  cancel(): void;
}

export interface OneClickVpnConfirmationPort {
  arm(expectedSessionId: string, timeoutMs: number): OneClickVpnConfirmationHandle;
}

export interface VpnRuntimeCoordinatorDependencies {
  resolver: CommittedProfileResolverPort;
  platform: VpnPlatformSessionPort;
  tunRuntime: TunRuntimePort;
  networkRecovery: NetworkRecoveryPort;
  notification: ContinuousNotificationPort;
  proxyLifecycle: VpnProxyRuntimeLifecyclePort;
  scheduler: BoundedDelaySchedulerPort;
  clock: ClockPort;
  reportStageLifecycle?: (stage: string) => void;
}
