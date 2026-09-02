import type { Want } from '@kit.AbilityKit';
import {
  createVpnFailure,
  createVpnRpcEmptyPayload,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  type BoundedDelaySchedulerPort,
  type CancelableDelayTask,
  type VpnControllerFailedResult,
  type VpnControllerPort,
  type VpnControllerRejectedResult,
  type VpnControllerStartResult,
  type VpnControllerStopResult,
  type VpnFailure,
  type VpnProxyRuntimeMirrorPort,
  type VpnRpcBody,
  type VpnRpcClientContext,
  type VpnRpcClientPort,
  type VpnRpcTrafficCounters,
  type VpnRuntimeSnapshot,
  type VpnStartRequest
} from '@cmfa/shared';
import { VpnSessionRegistry, VpnSessionRegistryError } from './VpnSessionRegistry';
import {
  VpnTrafficNotificationCoordinator,
  type VpnTrafficNotificationSinkPort
} from './VpnTrafficNotificationCoordinator';
import type {
  VpnTrafficMonitorLifecyclePort,
  VpnTrafficMonitorReadPort
} from './VpnTrafficMonitor';

const BUNDLE_NAME: string = 'com.github.kr328.clash.harmony';
const ABILITY_NAME: string = 'CmfaVpnExtensionAbility';
const CONSENT_DENIED_ERROR_CODE: number = 2203001;
const RUNTIME_MIRROR_RETRY_DELAYS_MS: number[] = [250, 500, 1000, 2000, 4000];

export interface VpnExtensionAbilityApi {
  startVpnExtensionAbility(want: Want): Promise<void>;
  stopVpnExtensionAbility(): Promise<void>;
  updateTraffic(
    sessionId: string,
    uploadBytesPerSecond: number,
    downloadBytesPerSecond: number
  ): Promise<void>;
  dispose?(): void;
}

export interface HarmonyVpnControllerDependencies {
  runtimeMirror?: VpnProxyRuntimeMirrorPort;
  scheduler?: BoundedDelaySchedulerPort;
  trafficMonitor?: HarmonyVpnTrafficMonitorPort;
  trafficReportStage?: (stage: string) => void;
  rpcClient?: VpnRpcClientPort;
}

export interface HarmonyVpnTrafficMonitorPort extends VpnTrafficMonitorReadPort, VpnTrafficMonitorLifecyclePort {}

interface BusinessErrorShape {
  code?: number;
}

interface PendingStartCompletion {
  token: number;
  request: VpnStartRequest;
  awaitingAuthoritativeSnapshot: boolean;
  promise: Promise<VpnControllerStartResult>;
  resolve(result: VpnControllerStartResult): void;
}

class PendingStartCompletionRecord implements PendingStartCompletion {
  readonly token: number;
  readonly request: VpnStartRequest;
  awaitingAuthoritativeSnapshot: boolean = false;
  readonly promise: Promise<VpnControllerStartResult>;
  private readonly resolveRef: (result: VpnControllerStartResult) => void;

  constructor(
    token: number,
    request: VpnStartRequest,
    promise: Promise<VpnControllerStartResult>,
    resolveRef: (result: VpnControllerStartResult) => void
  ) {
    this.token = token;
    this.request = cloneRequest(request);
    this.promise = promise;
    this.resolveRef = resolveRef;
  }

  resolve(result: VpnControllerStartResult): void {
    this.resolveRef(result);
  }
}

interface PendingStopCompletion {
  token: number;
  sessionId: string;
  promise: Promise<VpnControllerStopResult>;
  resolve(result: VpnControllerStopResult): void;
}

class PendingStopCompletionRecord implements PendingStopCompletion {
  readonly token: number;
  readonly sessionId: string;
  readonly promise: Promise<VpnControllerStopResult>;
  private readonly resolveRef: (result: VpnControllerStopResult) => void;

  constructor(
    token: number,
    sessionId: string,
    promise: Promise<VpnControllerStopResult>,
    resolveRef: (result: VpnControllerStopResult) => void
  ) {
    this.token = token;
    this.sessionId = sessionId;
    this.promise = promise;
    this.resolveRef = resolveRef;
  }

  resolve(result: VpnControllerStopResult): void {
    this.resolveRef(result);
  }
}

class UnavailableVpnRpcClient implements VpnRpcClientPort {
  async connectOnce(): Promise<void> {
    throw new Error('vpn rpc unavailable');
  }

  async connect(): Promise<void> {
    throw new Error('vpn rpc unavailable');
  }

  async request(): Promise<VpnRpcBody> {
    throw new Error('vpn rpc unavailable');
  }

  async refreshTrafficCounters(): Promise<VpnRpcTrafficCounters> {
    throw new Error('vpn rpc unavailable');
  }

  state(): 'DISCONNECTED' {
    return 'DISCONNECTED';
  }

  snapshot(): VpnRuntimeSnapshot {
    return createVpnRuntimeSnapshot({
      state: 'STOPPED',
      activeRequest: null,
      activeHandle: null,
      captureConfig: null,
      tunSnapshot: null,
      notificationActive: false,
      recoveryAttempt: 0,
      scheduledRetryDelayMs: null,
      lastFailure: null
    });
  }

  activeContext(): VpnRpcClientContext | null {
    return null;
  }

  subscribe(_listener: (event: VpnRpcBody) => void): number {
    return 0;
  }

  unsubscribe(_id: number): void {}

  async close(): Promise<void> {}
}

class VpnTrafficNotificationSinkRecord implements VpnTrafficNotificationSinkPort {
  private readonly vpnExtension: VpnExtensionAbilityApi;

  constructor(vpnExtension: VpnExtensionAbilityApi) {
    this.vpnExtension = vpnExtension;
  }

  async updateTraffic(
    sessionId: string,
    uploadBytesPerSecond: number,
    downloadBytesPerSecond: number
  ): Promise<void> {
    await this.vpnExtension.updateTraffic(sessionId, uploadBytesPerSecond, downloadBytesPerSecond);
  }
}

function cloneSnapshot(snapshot: VpnRuntimeSnapshot): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state: snapshot.state,
    activeRequest: snapshot.activeRequest,
    activeHandle: snapshot.activeHandle,
    captureConfig: snapshot.captureConfig,
    tunSnapshot: snapshot.tunSnapshot,
    notificationActive: snapshot.notificationActive,
    recoveryAttempt: snapshot.recoveryAttempt,
    scheduledRetryDelayMs: snapshot.scheduledRetryDelayMs,
    lastFailure: snapshot.lastFailure
  });
}

function createStartedResult(snapshot: VpnRuntimeSnapshot): VpnControllerStartResult {
  return {
    kind: 'STARTED',
    snapshot: cloneSnapshot(snapshot)
  };
}

function createRejectedResult(snapshot: VpnRuntimeSnapshot, failure: VpnFailure): VpnControllerRejectedResult {
  return {
    kind: 'REJECTED',
    snapshot: cloneSnapshot(snapshot),
    failure
  };
}

function createStoppedResult(snapshot: VpnRuntimeSnapshot): VpnControllerStopResult {
  return {
    kind: 'STOPPED',
    snapshot: cloneSnapshot(snapshot)
  };
}

function createFailedStopResult(snapshot: VpnRuntimeSnapshot, failure: VpnFailure): VpnControllerFailedResult {
  return {
    kind: 'FAILED',
    snapshot: cloneSnapshot(snapshot),
    failure
  };
}

function createStartWant(request: VpnStartRequest): Want {
  return {
    deviceId: '',
    bundleName: BUNDLE_NAME,
    abilityName: ABILITY_NAME,
    parameters: {
      profileId: request.profileId,
      versionId: request.versionId,
      sessionId: request.sessionId
    }
  };
}

function isBusinessErrorWithCode(error: Object | Error | undefined | null, code: number): boolean {
  if (typeof error !== 'object' || error === null) {
    return false;
  }
  const record: BusinessErrorShape = error as BusinessErrorShape;
  return record.code === code;
}

function createInvalidStartFailure(): VpnFailure {
  return createVpnFailure('VPN_CONFIG_INVALID', 'Vpn start requires non-empty profile, version, and session ids.');
}

function createAlreadyActiveFailure(): VpnFailure {
  return createVpnFailure('VPN_ALREADY_ACTIVE', 'Vpn registry already owns a pending or active session.');
}

function createProxyMutationBusyFailure(): VpnFailure {
  return createVpnFailure('VPN_ALREADY_ACTIVE', 'VPN runtime is busy. Retry after current proxy mutation finishes.');
}

function createConsentDeniedFailure(): VpnFailure {
  return createVpnFailure('VPN_PERMISSION_DENIED', 'HarmonyOS VPN consent was denied.');
}

function createStartFailure(): VpnFailure {
  return createVpnFailure('VPN_CREATE_FAILED', 'HarmonyOS VPN extension start failed.');
}

function createStopFailure(): VpnFailure {
  return createVpnFailure('VPN_STOP_FAILED', 'HarmonyOS VPN extension stop failed.');
}

function createSystemRevokedFailure(): VpnFailure {
  return createVpnFailure('VPN_SYSTEM_REVOKED', 'HarmonyOS VPN session was revoked by the system.');
}

function isSameRequest(left: VpnStartRequest | null | undefined, right: VpnStartRequest | null | undefined): boolean {
  if (left === null || left === undefined || right === null || right === undefined) {
    return false;
  }
  return left.sessionId === right.sessionId &&
    left.profileId === right.profileId &&
    left.versionId === right.versionId;
}

function cloneRequest(request: VpnStartRequest): VpnStartRequest {
  return createVpnStartRequest(request.profileId, request.versionId, request.sessionId);
}

function requiresLiveRpcContext(snapshot: VpnRuntimeSnapshot, context: VpnRpcClientContext | null): boolean {
  return snapshot.state === 'RUNNING' && context !== null;
}

function isTransitionalRpcState(snapshot: VpnRuntimeSnapshot, context: VpnRpcClientContext | null): boolean {
  return context !== null &&
    (snapshot.state === 'STARTING' || snapshot.state === 'RECOVERING');
}

function stopGenerationForContext(context: VpnRpcClientContext): number {
  return context.sessionGeneration > 0 ? context.sessionGeneration : 1;
}

export class HarmonyVpnController implements VpnControllerPort {
  private readonly registry: VpnSessionRegistry;
  private readonly vpnExtension: VpnExtensionAbilityApi;
  private readonly rpcClient: VpnRpcClientPort;
  private readonly runtimeMirror?: VpnProxyRuntimeMirrorPort;
  private readonly scheduler?: BoundedDelaySchedulerPort;
  private readonly trafficMonitor?: HarmonyVpnTrafficMonitorPort;
  private readonly trafficNotificationCoordinator?: VpnTrafficNotificationCoordinator;
  private rpcSubscriptionId: number = 0;
  private stopRequestInFlight?: Promise<void>;
  private pendingStartCompletion?: PendingStartCompletion;
  private pendingStopCompletion?: PendingStopCompletion;
  private nextOperationToken: number = 0;
  private rollbackStartToken: number = 0;
  private suppressOrphanRpcToken: number = 0;
  private knownRequest?: VpnStartRequest;
  private mirroredBindingKey?: string;
  private bindingRuntimeMirrorKey?: string;
  private bindingRuntimeMirrorPromise?: Promise<boolean>;
  private nextRuntimeMirrorHydrationToken: number = 0;
  private runtimeMirrorHydrationToken: number = 0;
  private completeRuntimeMirrorHydrationToken: number = 0;
  private completeRuntimeMirrorHydrationPromise?: Promise<void>;
  private runtimeMirrorRetryTask?: CancelableDelayTask;
  private runtimeMirrorRetryAttempt: number = 0;
  private runtimeMirrorRecoveryPromise?: Promise<void>;
  private trafficSessionId?: string;
  private disposed: boolean = false;

  constructor(
    registry: VpnSessionRegistry,
    vpnExtension: VpnExtensionAbilityApi,
    dependencies?: HarmonyVpnControllerDependencies
  ) {
    this.registry = registry;
    this.vpnExtension = vpnExtension;
    this.rpcClient = dependencies?.rpcClient ?? new UnavailableVpnRpcClient();
    this.runtimeMirror = dependencies?.runtimeMirror;
    this.scheduler = dependencies?.scheduler;
    this.trafficMonitor = dependencies?.trafficMonitor;
    if (dependencies?.trafficMonitor !== undefined) {
      this.trafficNotificationCoordinator = new VpnTrafficNotificationCoordinator(
        dependencies.trafficMonitor,
        new VpnTrafficNotificationSinkRecord(this.vpnExtension),
        dependencies.trafficReportStage
      );
    }
    this.rpcSubscriptionId = this.rpcClient.subscribe((event: VpnRpcBody): void => {
      this.handleRpcEvent(event);
    });
  }

  async start(profileId: string, versionId: string, sessionId: string): Promise<VpnControllerStartResult> {
    let request: VpnStartRequest;
    try {
      request = createVpnStartRequest(profileId, versionId, sessionId);
    } catch (_) {
      return createRejectedResult(this.registry.snapshot(), createInvalidStartFailure());
    }

    try {
      this.registry.beginPending(request);
    } catch (error) {
      if (error instanceof VpnSessionRegistryError && error.code === 'SESSION_ALREADY_LIVE') {
        return createRejectedResult(this.registry.snapshot(), createAlreadyActiveFailure());
      }
      if (error instanceof VpnSessionRegistryError && error.code === 'PROXY_MUTATION_IN_PROGRESS') {
        return createRejectedResult(this.registry.snapshot(), createProxyMutationBusyFailure());
      }
      return createRejectedResult(this.registry.snapshot(), createStartFailure());
    }

    const token: number = this.nextToken();
    const pendingStart: PendingStartCompletion = this.createPendingStartCompletion(token, request);
    this.pendingStartCompletion = pendingStart;
    this.knownRequest = cloneRequest(request);
    this.pendingStopCompletion = undefined;
    this.stopRequestInFlight = undefined;
    this.suppressOrphanRpcToken = 0;

    try {
      await this.vpnExtension.startVpnExtensionAbility(createStartWant(request));
    } catch (error) {
      const failure: VpnFailure = this.mapStartFailure(error);
      this.finishPendingStart(token, request, failure);
      return createRejectedResult(this.registry.snapshot(), failure);
    }

    void this.runStartConnectFlow(token, request);
    return await pendingStart.promise;
  }

  async stop(sessionId?: string): Promise<VpnControllerStopResult> {
    this.cancelRuntimeMirrorRetry();
    const targetSessionId: string | undefined = this.registry.markUserStopRequested(sessionId);
    if (targetSessionId === undefined) {
      return createStoppedResult(this.registry.snapshot());
    }
    this.stopTrafficLoop(targetSessionId);

    const existingCompletion: PendingStopCompletion | undefined = this.pendingStopCompletion;
    if (existingCompletion !== undefined && existingCompletion.sessionId === targetSessionId) {
      return await existingCompletion.promise;
    }

    const token: number = this.nextToken();
    const completion: PendingStopCompletion = this.createPendingStopCompletion(token, targetSessionId);
    this.pendingStopCompletion = completion;
    this.publishStoppingSnapshot();
    this.stopRequestInFlight = this.issueStopSequence(completion).finally((): void => {
      if (this.stopRequestInFlight !== undefined && this.pendingStopCompletion !== completion) {
        this.stopRequestInFlight = undefined;
      }
    });
    return await completion.promise;
  }

  async initializeRuntimeMirror(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.runtimeMirrorHydrationToken !== 0) {
      return;
    }
    this.registry.beginRuntimeMirrorHydration();
    const token: number = this.beginOwnedRuntimeMirrorHydration();
    if (this.rpcClient.state() !== 'READY') {
      try {
        await this.rpcClient.connectOnce();
      } catch (_) {
        this.launchRuntimeMirrorRecovery();
        return;
      }
    }
    await this.completeRuntimeMirrorHydrationFromRpc(token);
  }

  snapshot(): VpnRuntimeSnapshot {
    return this.registry.snapshot();
  }

  subscribe(listener: (event: import('@cmfa/shared').VpnRuntimeEvent) => void): number {
    return this.registry.subscribe(listener);
  }

  unsubscribe(subscriptionId: number): void {
    this.registry.unsubscribe(subscriptionId);
  }

  isUserStopRequested(sessionId: string): boolean {
    return this.registry.isUserStopRequested(sessionId);
  }

  handleExtensionDestroyed(): void {
    const currentSessionId: string | undefined =
      this.pendingStopCompletion?.sessionId ?? this.registry.currentSessionId();
    if (currentSessionId === undefined) {
      this.stopTrafficLoop();
      return;
    }

    const pendingStart: PendingStartCompletion | undefined = this.pendingStartCompletion;
    if (pendingStart !== undefined) {
      const failure: VpnFailure = createStartFailure();
      this.finishPendingStart(pendingStart.token, pendingStart.request, failure);
      pendingStart.resolve(createRejectedResult(this.registry.snapshot(), failure));
      this.pendingStartCompletion = undefined;
      this.knownRequest = undefined;
      this.stopTrafficLoop(currentSessionId);
      void this.deactivateRuntimeMirror(currentSessionId);
      return;
    }

    const pendingStop: PendingStopCompletion | undefined = this.pendingStopCompletion;
    const currentFailure: VpnFailure | null = this.registry.snapshot().lastFailure;
    if (pendingStop !== undefined && pendingStop.sessionId === currentSessionId) {
      this.registry.completeStop(currentSessionId, currentFailure);
      this.pendingStopCompletion = undefined;
      this.stopRequestInFlight = undefined;
      this.knownRequest = undefined;
      this.stopTrafficLoop(currentSessionId);
      void this.deactivateRuntimeMirror(currentSessionId);
      pendingStop.resolve(createStoppedResult(this.registry.snapshot()));
      return;
    }

    if (this.registry.isUserStopRequested(currentSessionId)) {
      this.registry.completeStop(currentSessionId, currentFailure);
      this.knownRequest = undefined;
      this.stopTrafficLoop(currentSessionId);
      void this.deactivateRuntimeMirror(currentSessionId);
      return;
    }

    this.registry.completeStop(currentSessionId, createSystemRevokedFailure());
    this.knownRequest = undefined;
    this.stopTrafficLoop(currentSessionId);
    void this.deactivateRuntimeMirror(currentSessionId);
  }

  async dispose(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.cancelRuntimeMirrorRetry();
    this.runtimeMirrorHydrationToken = 0;
    const activeSessionId: string | undefined = this.registry.currentSessionId() ?? this.knownRequest?.sessionId;
    this.disposeTrafficLoop();
    if (activeSessionId !== undefined) {
      await this.deactivateRuntimeMirror(activeSessionId);
    }
    if (this.rpcSubscriptionId !== 0) {
      this.rpcClient.unsubscribe(this.rpcSubscriptionId);
      this.rpcSubscriptionId = 0;
    }
    this.vpnExtension.dispose?.();
  }

  private nextToken(): number {
    this.nextOperationToken += 1;
    return this.nextOperationToken;
  }

  private mapStartFailure(error: Object | Error | undefined | null): VpnFailure {
    if (isBusinessErrorWithCode(error, CONSENT_DENIED_ERROR_CODE)) {
      return createConsentDeniedFailure();
    }
    return createStartFailure();
  }

  private createPendingStartCompletion(token: number, request: VpnStartRequest): PendingStartCompletion {
    let resolveRef: ((result: VpnControllerStartResult) => void) | undefined = undefined;
    const promise: Promise<VpnControllerStartResult> = new Promise<VpnControllerStartResult>((resolve) => {
      resolveRef = resolve;
    });
    return new PendingStartCompletionRecord(token, request, promise, (result: VpnControllerStartResult) => {
      resolveRef?.(result);
    });
  }

  private createPendingStopCompletion(token: number, sessionId: string): PendingStopCompletion {
    let resolveRef: ((result: VpnControllerStopResult) => void) | undefined = undefined;
    const promise: Promise<VpnControllerStopResult> = new Promise<VpnControllerStopResult>((resolve) => {
      resolveRef = resolve;
    });
    return new PendingStopCompletionRecord(token, sessionId, promise, (result: VpnControllerStopResult) => {
      resolveRef?.(result);
    });
  }

  private beginOwnedRuntimeMirrorHydration(): number {
    if (this.runtimeMirrorHydrationToken !== 0) {
      return this.runtimeMirrorHydrationToken;
    }
    this.nextRuntimeMirrorHydrationToken += 1;
    this.runtimeMirrorHydrationToken = this.nextRuntimeMirrorHydrationToken;
    return this.runtimeMirrorHydrationToken;
  }

  private isCurrentRuntimeMirrorHydration(token: number): boolean {
    return !this.disposed &&
      token !== 0 &&
      this.runtimeMirrorHydrationToken === token;
  }

  private clearRuntimeMirrorHydration(token: number): void {
    if (this.runtimeMirrorHydrationToken === token) {
      this.runtimeMirrorHydrationToken = 0;
    }
  }

  private finishPendingStart(token: number, request: VpnStartRequest, failure: VpnFailure): void {
    const activeStart: PendingStartCompletion | undefined = this.pendingStartCompletion;
    if (activeStart === undefined || activeStart.token !== token || !isSameRequest(activeStart.request, request)) {
      return;
    }
    this.registry.completeStop(request.sessionId, failure);
    this.pendingStartCompletion = undefined;
  }

  private isCurrentPendingStart(token: number, request: VpnStartRequest): boolean {
    const activeStart: PendingStartCompletion | undefined = this.pendingStartCompletion;
    return activeStart !== undefined &&
      activeStart.token === token &&
      isSameRequest(activeStart.request, request);
  }

  private async runStartConnectFlow(token: number, request: VpnStartRequest): Promise<void> {
    try {
      await this.rpcClient.connect();
    } catch (_) {
      await this.failPendingStart(token, request, createStartFailure());
      return;
    }
    if (!this.isCurrentPendingStart(token, request)) {
      return;
    }
    const immediate = await this.consumeCurrentRpcSnapshotForStart(token, request);
    if (immediate !== undefined) {
      if (immediate.kind === 'REJECTED') {
        await this.failPendingStart(token, request, immediate.failure);
        return;
      }
      this.resolvePendingStartIfCurrent(token, request, immediate);
    }
  }

  private resolvePendingStartIfCurrent(token: number, request: VpnStartRequest, result: VpnControllerStartResult): void {
    const activeStart: PendingStartCompletion | undefined = this.pendingStartCompletion;
    if (activeStart === undefined || activeStart.token !== token || !isSameRequest(activeStart.request, request)) {
      return;
    }
    this.pendingStartCompletion = undefined;
    activeStart.resolve(result);
  }

  private async failPendingStart(token: number, request: VpnStartRequest, failure: VpnFailure): Promise<void> {
    const activeStart: PendingStartCompletion | undefined = this.pendingStartCompletion;
    if (activeStart === undefined || activeStart.token !== token || !isSameRequest(activeStart.request, request)) {
      return;
    }
    this.pendingStartCompletion = undefined;
    this.suppressOrphanRpcToken = token;
    const result: VpnControllerStartResult = await this.rollbackStartedSession(token, request, failure);
    activeStart.resolve(result);
  }

  private async rollbackStartedSession(
    token: number,
    request: VpnStartRequest,
    failure: VpnFailure
  ): Promise<VpnControllerStartResult> {
    if (this.rollbackStartToken !== token) {
      this.rollbackStartToken = token;
      try {
        await this.vpnExtension.stopVpnExtensionAbility();
      } catch {}
    }
    this.stopTrafficLoop(request.sessionId);
    await this.deactivateRuntimeMirror(request.sessionId);
    this.registry.completeStop(request.sessionId, failure);
    this.knownRequest = undefined;
    return createRejectedResult(this.registry.snapshot(), failure);
  }

  private async consumeCurrentRpcSnapshotForStart(
    token: number,
    request: VpnStartRequest
  ): Promise<VpnControllerStartResult | undefined> {
    const snapshot: VpnRuntimeSnapshot = this.rpcClient.snapshot();
    const context: VpnRpcClientContext | null = this.rpcClient.activeContext();
    if (requiresLiveRpcContext(snapshot, context)) {
      const mirrorSynchronized: boolean = await this.syncRuntimeMirror(snapshot, context, request);
      if (!mirrorSynchronized) {
        return createRejectedResult(this.registry.snapshot(), createStartFailure());
      }
      this.registry.hydrateRpcSnapshot(snapshot, context, request);
      this.knownRequest = cloneRequest(request);
      this.startTrafficLoop(request.sessionId);
      return createStartedResult(this.registry.snapshot());
    }
    if (isTransitionalRpcState(snapshot, context)) {
      const mirrorSynchronized: boolean = await this.syncRuntimeMirror(snapshot, context, request);
      if (!mirrorSynchronized) {
        return createRejectedResult(this.registry.snapshot(), createStartFailure());
      }
      this.registry.hydrateRpcSnapshot(snapshot, context, request);
      const activeStart = this.pendingStartCompletion;
      if (activeStart !== undefined && activeStart.token === token && isSameRequest(activeStart.request, request)) {
        activeStart.awaitingAuthoritativeSnapshot = true;
      }
      return undefined;
    }
    if (snapshot.state === 'ERROR' && snapshot.lastFailure !== null) {
      return createRejectedResult(this.registry.snapshot(), sanitizeRuntimeFailure(snapshot.lastFailure, createStartFailure()));
    }
    return createRejectedResult(this.registry.snapshot(), createStartFailure());
  }

  private publishStoppingSnapshot(): void {
    const snapshot: VpnRuntimeSnapshot = this.registry.snapshot();
    const context: VpnRpcClientContext | null = this.rpcClient.activeContext();
    const knownRequest: VpnStartRequest | undefined = snapshot.activeRequest ?? this.knownRequest;
    this.registry.hydrateRpcSnapshot(
      createVpnRuntimeSnapshot({
        state: 'STOPPING',
        activeRequest: snapshot.activeRequest,
        activeHandle: snapshot.activeHandle,
        captureConfig: snapshot.captureConfig,
        tunSnapshot: snapshot.tunSnapshot,
        notificationActive: snapshot.notificationActive,
        recoveryAttempt: snapshot.recoveryAttempt,
        scheduledRetryDelayMs: snapshot.scheduledRetryDelayMs,
        lastFailure: snapshot.lastFailure
      }),
      context,
      knownRequest
    );
  }

  private async issueStopSequence(completion: PendingStopCompletion): Promise<void> {
    const context: VpnRpcClientContext | null = this.rpcClient.activeContext();
    let rpcSucceeded: boolean = false;
    if (context !== null && this.rpcClient.state() === 'READY') {
      try {
        const response: VpnRpcBody = await this.rpcClient.request(
          'STOP_VPN',
          context.guards,
          stopGenerationForContext(context),
          createVpnRpcEmptyPayload()
        );
        if (this.pendingStopCompletion !== completion) {
          return;
        }
        if (response.ok === true) {
          this.hydrateRegistryFromRpc(this.knownRequest);
          rpcSucceeded = true;
        }
      } catch {}
    }
    await this.issuePlatformStopRequest(completion, rpcSucceeded);
  }

  private async issuePlatformStopRequest(completion: PendingStopCompletion, _rpcSucceeded: boolean): Promise<void> {
    try {
      await this.vpnExtension.stopVpnExtensionAbility();
      if (this.pendingStopCompletion !== completion) {
        return;
      }
      const currentFailure: VpnFailure | null = this.registry.snapshot().lastFailure;
      await this.deactivateRuntimeMirror(completion.sessionId);
      this.registry.completeStop(completion.sessionId, currentFailure);
      this.pendingStopCompletion = undefined;
      this.stopRequestInFlight = undefined;
      this.knownRequest = undefined;
      completion.resolve(createStoppedResult(this.registry.snapshot()));
    } catch (_) {
      if (this.pendingStopCompletion !== completion) {
        return;
      }
      const failure: VpnFailure = createStopFailure();
      const snapshot: VpnRuntimeSnapshot = this.registry.snapshot();
      const context: VpnRpcClientContext | null = this.rpcClient.activeContext();
      this.registry.hydrateRpcSnapshot(
        createVpnRuntimeSnapshot({
          state: 'ERROR',
          activeRequest: snapshot.activeRequest,
          activeHandle: snapshot.activeHandle,
          captureConfig: snapshot.captureConfig,
          tunSnapshot: snapshot.tunSnapshot,
          notificationActive: snapshot.notificationActive,
          recoveryAttempt: snapshot.recoveryAttempt,
          scheduledRetryDelayMs: snapshot.scheduledRetryDelayMs,
          lastFailure: failure
        }),
        context,
        snapshot.activeRequest ?? this.knownRequest
      );
      await this.deactivateRuntimeMirror(completion.sessionId);
      this.pendingStopCompletion = undefined;
      this.stopRequestInFlight = undefined;
      completion.resolve(createFailedStopResult(this.registry.snapshot(), failure));
    }
  }

  private handleRpcEvent(event: VpnRpcBody): void {
    if (this.disposed) {
      return;
    }
    if (event.method === 'RUNTIME_CHANGED') {
      void this.handleRuntimeChanged();
      return;
    }
    if (event.method === 'SERVER_STOPPING') {
      void this.handleServerStopping();
    }
  }

  private async handleRuntimeChanged(): Promise<void> {
    const snapshot: VpnRuntimeSnapshot = this.rpcClient.snapshot();
    const context: VpnRpcClientContext | null = this.rpcClient.activeContext();
    const pendingStart: PendingStartCompletion | undefined = this.pendingStartCompletion;
    if (pendingStart !== undefined) {
      if (requiresLiveRpcContext(snapshot, context)) {
        const mirrorSynchronized: boolean = await this.syncRuntimeMirror(snapshot, context, pendingStart.request);
        if (!mirrorSynchronized) {
          void this.failPendingStart(pendingStart.token, pendingStart.request, createStartFailure());
          return;
        }
        this.registry.hydrateRpcSnapshot(snapshot, context, pendingStart.request);
        this.knownRequest = cloneRequest(pendingStart.request);
        this.startTrafficLoop(pendingStart.request.sessionId);
        this.pendingStartCompletion = undefined;
        pendingStart.resolve(createStartedResult(this.registry.snapshot()));
        return;
      }
      if (isTransitionalRpcState(snapshot, context)) {
        const mirrorSynchronized: boolean = await this.syncRuntimeMirror(snapshot, context, pendingStart.request);
        if (!mirrorSynchronized) {
          void this.failPendingStart(pendingStart.token, pendingStart.request, createStartFailure());
          return;
        }
        this.registry.hydrateRpcSnapshot(snapshot, context, pendingStart.request);
        pendingStart.awaitingAuthoritativeSnapshot = true;
        return;
      }
      const failure: VpnFailure = this.mapPendingStartTerminalFailure(snapshot);
      void this.failPendingStart(pendingStart.token, pendingStart.request, failure);
      return;
    }

    if (this.shouldIgnoreOrphanRpcEvent()) {
      return;
    }
    const knownRequest: VpnStartRequest | undefined = snapshot.activeRequest ?? this.knownRequest;
    if (this.runtimeMirrorHydrationToken !== 0) {
      await this.completeRuntimeMirrorHydrationFromRpc(this.runtimeMirrorHydrationToken);
      return;
    }
    if (requiresLiveRpcContext(snapshot, context) || isTransitionalRpcState(snapshot, context)) {
      this.registry.beginRuntimeMirrorHydration();
      const token: number = this.beginOwnedRuntimeMirrorHydration();
      await this.completeRuntimeMirrorHydrationFromRpc(token);
      return;
    }
    this.hydrateRegistryWithAuthoritativeSnapshot(snapshot, context, knownRequest);
    if (snapshot.state === 'STOPPED') {
      this.knownRequest = undefined;
    }
    await this.syncRuntimeMirror(snapshot, context, knownRequest);
  }

  private async handleServerStopping(): Promise<void> {
    const pendingStart: PendingStartCompletion | undefined = this.pendingStartCompletion;
    if (pendingStart !== undefined) {
      void this.failPendingStart(pendingStart.token, pendingStart.request, createStartFailure());
      return;
    }
    const pendingStop: PendingStopCompletion | undefined = this.pendingStopCompletion;
    if (pendingStop !== undefined && this.stopRequestInFlight === undefined) {
      this.stopRequestInFlight = this.issuePlatformStopRequest(pendingStop, false);
    }
    const activeSessionId: string | undefined =
      this.registry.currentSessionId() ?? this.knownRequest?.sessionId ?? this.trafficSessionId;
    if (activeSessionId !== undefined) {
      this.stopTrafficLoop(activeSessionId);
      await this.deactivateRuntimeMirror(activeSessionId);
    }
  }

  private hydrateRegistryFromRpc(knownRequest?: VpnStartRequest): void {
    this.suppressOrphanRpcToken = 0;
    const snapshot: VpnRuntimeSnapshot = this.rpcClient.snapshot();
    const context: VpnRpcClientContext | null = this.rpcClient.activeContext();
    this.hydrateRegistryWithAuthoritativeSnapshot(snapshot, context, snapshot.activeRequest ?? knownRequest);
    if (snapshot.state === 'STOPPED') {
      this.knownRequest = undefined;
      return;
    }
    const effectiveRequest: VpnStartRequest | undefined = snapshot.activeRequest ?? knownRequest;
    if (effectiveRequest !== undefined) {
      this.knownRequest = cloneRequest(effectiveRequest);
    }
  }

  private launchRuntimeMirrorRecovery(): void {
    if (this.disposed || this.runtimeMirrorRecoveryPromise !== undefined) {
      return;
    }
    const token: number = this.runtimeMirrorHydrationToken;
    if (token === 0) {
      return;
    }
    let recoveryPromise: Promise<void>;
    recoveryPromise = this.runRuntimeMirrorRecovery(token).finally((): void => {
      if (this.runtimeMirrorRecoveryPromise === recoveryPromise) {
        this.runtimeMirrorRecoveryPromise = undefined;
      }
    });
    this.runtimeMirrorRecoveryPromise = recoveryPromise;
    void recoveryPromise.catch((): void => {});
  }

  private async runRuntimeMirrorRecovery(token: number): Promise<void> {
    try {
      await this.rpcClient.connect();
    } catch (_) {
      await this.completeRuntimeMirrorHydrationUnavailableSafely(token);
      return;
    }
    await this.completeRuntimeMirrorHydrationFromRpc(token);
  }

  private async completeRuntimeMirrorHydrationFromRpc(token: number): Promise<void> {
    if (!this.isCurrentRuntimeMirrorHydration(token)) {
      return;
    }
    if (this.completeRuntimeMirrorHydrationPromise !== undefined &&
      this.completeRuntimeMirrorHydrationToken === token) {
      return await this.completeRuntimeMirrorHydrationPromise;
    }
    let completionPromise: Promise<void>;
    completionPromise = this.runCompleteRuntimeMirrorHydrationFromRpc(token).finally((): void => {
      if (this.completeRuntimeMirrorHydrationPromise === completionPromise) {
        this.completeRuntimeMirrorHydrationPromise = undefined;
        this.completeRuntimeMirrorHydrationToken = 0;
      }
    });
    this.completeRuntimeMirrorHydrationToken = token;
    this.completeRuntimeMirrorHydrationPromise = completionPromise;
    return await completionPromise;
  }

  private async runCompleteRuntimeMirrorHydrationFromRpc(token: number): Promise<void> {
    while (this.isCurrentRuntimeMirrorHydration(token)) {
      const candidateSnapshot: VpnRuntimeSnapshot = this.rpcClient.snapshot();
      const candidateContext: VpnRpcClientContext | null = this.rpcClient.activeContext();
      const candidateKnownRequest: VpnStartRequest | undefined =
        candidateSnapshot.activeRequest ?? this.registry.snapshot().activeRequest ?? this.knownRequest;
      const mirrorSynchronized: boolean = await this.syncRuntimeMirror(
        candidateSnapshot,
        candidateContext,
        candidateKnownRequest
      );
      if (!mirrorSynchronized) {
        this.scheduleRuntimeMirrorRetry(token, candidateKnownRequest);
        return;
      }
      if (!this.isCurrentRuntimeMirrorHydration(token)) {
        return;
      }
      const latestSnapshot: VpnRuntimeSnapshot = this.rpcClient.snapshot();
      const latestContext: VpnRpcClientContext | null = this.rpcClient.activeContext();
      const latestKnownRequest: VpnStartRequest | undefined =
        latestSnapshot.activeRequest ?? this.registry.snapshot().activeRequest ?? this.knownRequest;
      if (!this.isStableRuntimeMirrorHydrationCandidate(
        candidateSnapshot,
        candidateContext,
        candidateKnownRequest,
        latestSnapshot,
        latestContext,
        latestKnownRequest
      )) {
        continue;
      }
      this.resetRuntimeMirrorRetry();
      this.hydrateRegistryFromReadyRpc(latestSnapshot, latestContext, latestKnownRequest);
      this.clearRuntimeMirrorHydration(token);
      return;
    }
  }

  private scheduleRuntimeMirrorRetry(token: number, knownRequest?: VpnStartRequest): void {
    if (!this.isCurrentRuntimeMirrorHydration(token) || this.runtimeMirrorRetryTask !== undefined) {
      return;
    }
    if (this.runtimeMirrorRetryAttempt >= RUNTIME_MIRROR_RETRY_DELAYS_MS.length) {
      this.resetRuntimeMirrorRetry();
      this.clearRuntimeMirrorHydration(token);
      this.stopTrafficLoop(knownRequest?.sessionId);
      this.registry.hydrateFailure(
        createVpnFailure('VPN_PROXY_REPLAY_FAILED', 'Proxy runtime mirror hydration failed.'),
        knownRequest
      );
      return;
    }
    const scheduler: BoundedDelaySchedulerPort | undefined = this.scheduler;
    if (scheduler === undefined) {
      return;
    }
    const delayMs: number = RUNTIME_MIRROR_RETRY_DELAYS_MS[this.runtimeMirrorRetryAttempt];
    this.runtimeMirrorRetryAttempt += 1;
    this.runtimeMirrorRetryTask = scheduler.schedule(delayMs, async (): Promise<void> => {
      if (this.runtimeMirrorRetryTask !== undefined) {
        this.runtimeMirrorRetryTask = undefined;
      }
      try {
        await this.completeRuntimeMirrorHydrationFromRpc(token);
      } catch (_) {
      }
    });
  }

  private resetRuntimeMirrorRetry(): void {
    this.runtimeMirrorRetryTask?.cancel();
    this.runtimeMirrorRetryTask = undefined;
    this.runtimeMirrorRetryAttempt = 0;
  }

  private cancelRuntimeMirrorRetry(): void {
    this.resetRuntimeMirrorRetry();
  }

  private hydrateRegistryFromReadyRpc(
    snapshot: VpnRuntimeSnapshot,
    context: VpnRpcClientContext | null,
    knownRequest?: VpnStartRequest
  ): void {
    this.suppressOrphanRpcToken = 0;
    this.hydrateRegistryWithAuthoritativeSnapshot(snapshot, context, snapshot.activeRequest ?? knownRequest);
    if (snapshot.state === 'STOPPED') {
      this.knownRequest = undefined;
      return;
    }
    const effectiveRequest: VpnStartRequest | undefined = snapshot.activeRequest ?? knownRequest;
    if (effectiveRequest !== undefined) {
      this.knownRequest = cloneRequest(effectiveRequest);
    }
  }

  private async completeRuntimeMirrorHydrationUnavailableSafely(token: number): Promise<void> {
    if (!this.isCurrentRuntimeMirrorHydration(token)) {
      return;
    }
    this.resetRuntimeMirrorRetry();
    this.clearRuntimeMirrorHydration(token);
    this.stopTrafficLoop();
    try {
      this.registry.completeRuntimeMirrorHydrationUnavailable();
    } catch (_) {
    }
  }

  private hydrateRegistryWithAuthoritativeSnapshot(
    snapshot: VpnRuntimeSnapshot,
    context: VpnRpcClientContext | null,
    knownRequest?: VpnStartRequest
  ): void {
    const effectiveRequest: VpnStartRequest | undefined = snapshot.activeRequest ?? knownRequest;
    if (this.registry.hydrateRpcSnapshot(snapshot, context, effectiveRequest)) {
      this.syncTrafficLoop(snapshot, effectiveRequest);
      return;
    }
    const currentSessionId: string | undefined = this.registry.currentSessionId();
    if (currentSessionId === undefined) {
      this.syncTrafficLoop(snapshot, effectiveRequest);
      return;
    }
    this.registry.completeStop(currentSessionId, null);
    this.stopTrafficLoop(currentSessionId);
    this.registry.hydrateRpcSnapshot(snapshot, context, effectiveRequest);
    this.syncTrafficLoop(snapshot, effectiveRequest);
  }

  private async syncRuntimeMirror(
    snapshot: VpnRuntimeSnapshot,
    context: VpnRpcClientContext | null,
    knownRequest?: VpnStartRequest
  ): Promise<boolean> {
    const runtimeMirror: VpnProxyRuntimeMirrorPort | undefined = this.runtimeMirror;
    if (runtimeMirror === undefined) {
      return true;
    }
    const request: VpnStartRequest | undefined = snapshot.activeRequest ?? knownRequest ?? this.knownRequest;
    if (request === undefined || context === null || snapshot.state === 'STOPPED' || snapshot.state === 'ERROR') {
      const activeSessionId: string | undefined = this.mirroredBindingKey === undefined ? undefined : this.extractMirroredSessionId();
      if (activeSessionId !== undefined) {
        await this.deactivateRuntimeMirror(activeSessionId);
      }
      return true;
    }
    const nextKey: string =
      `${request.profileId}\u0000${request.versionId}\u0000${request.sessionId}\u0000${context.guards.catalogDigest ?? ''}\u0000${context.sessionGeneration}`;
    if (this.mirroredBindingKey === nextKey) {
      return true;
    }
    if (this.bindingRuntimeMirrorPromise !== undefined && this.bindingRuntimeMirrorKey === nextKey) {
      return await this.bindingRuntimeMirrorPromise;
    }
    if (this.mirroredBindingKey !== undefined) {
      const activeSessionId: string | undefined = this.extractMirroredSessionId();
      if (activeSessionId !== undefined) {
        await this.deactivateRuntimeMirror(activeSessionId);
      }
    }
    let bindPromise: Promise<boolean>;
    bindPromise = (async (): Promise<boolean> => {
      try {
        await runtimeMirror.bindExistingSession(request);
        this.mirroredBindingKey = nextKey;
        if (this.disposed) {
          await this.deactivateRuntimeMirror(request.sessionId);
          return false;
        }
        return true;
      } catch (_) {
        this.mirroredBindingKey = undefined;
        return false;
      }
    })().finally((): void => {
      if (this.bindingRuntimeMirrorPromise === bindPromise) {
        this.bindingRuntimeMirrorPromise = undefined;
        this.bindingRuntimeMirrorKey = undefined;
      }
    });
    this.bindingRuntimeMirrorKey = nextKey;
    this.bindingRuntimeMirrorPromise = bindPromise;
    return await bindPromise;
  }

  private isStableRuntimeMirrorHydrationCandidate(
    candidateSnapshot: VpnRuntimeSnapshot,
    candidateContext: VpnRpcClientContext | null,
    candidateKnownRequest: VpnStartRequest | undefined,
    latestSnapshot: VpnRuntimeSnapshot,
    latestContext: VpnRpcClientContext | null,
    latestKnownRequest: VpnStartRequest | undefined
  ): boolean {
    if (candidateSnapshot.state !== latestSnapshot.state) {
      return false;
    }
    if (!this.isSameHydrationRequest(
      candidateSnapshot.activeRequest ?? candidateKnownRequest,
      latestSnapshot.activeRequest ?? latestKnownRequest
    )) {
      return false;
    }
    return this.isSameHydrationContext(candidateContext, latestContext);
  }

  private isSameHydrationRequest(
    left: VpnStartRequest | null | undefined,
    right: VpnStartRequest | null | undefined
  ): boolean {
    if (left === undefined || left === null) {
      return right === undefined || right === null;
    }
    return isSameRequest(left, right);
  }

  private isSameHydrationContext(left: VpnRpcClientContext | null, right: VpnRpcClientContext | null): boolean {
    if (left === null || right === null) {
      return left === right;
    }
    return left.sessionGeneration === right.sessionGeneration &&
      left.guards.profileHash === right.guards.profileHash &&
      left.guards.revisionHash === right.guards.revisionHash &&
      left.guards.catalogDigest === right.guards.catalogDigest;
  }

  private async deactivateRuntimeMirror(sessionId: string): Promise<void> {
    if (this.runtimeMirror === undefined) {
      return;
    }
    this.mirroredBindingKey = undefined;
    await this.runtimeMirror.deactivate(sessionId);
  }

  private extractMirroredSessionId(): string | undefined {
    const key: string | undefined = this.mirroredBindingKey;
    if (key === undefined) {
      return undefined;
    }
    const segments: string[] = key.split('\u0000');
    return segments.length < 3 ? undefined : segments[2];
  }

  private mapPendingStartTerminalFailure(snapshot: VpnRuntimeSnapshot): VpnFailure {
    return createStartFailure();
  }

  private shouldIgnoreOrphanRpcEvent(): boolean {
    return this.suppressOrphanRpcToken !== 0 &&
      this.suppressOrphanRpcToken === this.nextOperationToken &&
      this.pendingStartCompletion === undefined &&
      this.pendingStopCompletion === undefined &&
      this.knownRequest === undefined &&
      this.registry.currentSessionId() === undefined;
  }

  private startTrafficLoop(sessionId: string): void {
    if (sessionId.length === 0) {
      return;
    }
    const activeSessionId: string | undefined = this.trafficSessionId;
    if (activeSessionId !== undefined && activeSessionId !== sessionId) {
      this.trafficNotificationCoordinator?.stop(activeSessionId);
    }
    this.trafficMonitor?.start(sessionId);
    this.trafficNotificationCoordinator?.start(sessionId);
    this.trafficSessionId = sessionId;
  }

  private markTrafficRecovering(sessionId?: string): void {
    const activeSessionId: string | undefined = this.trafficSessionId;
    if (activeSessionId === undefined) {
      return;
    }
    if (sessionId !== undefined) {
      if (sessionId !== activeSessionId) {
        return;
      }
      this.trafficMonitor?.markRecovering(sessionId);
      return;
    }
    this.trafficMonitor?.markRecovering(activeSessionId);
  }

  private stopTrafficLoop(sessionId?: string): void {
    const activeSessionId: string | undefined = this.trafficSessionId;
    if (activeSessionId === undefined) {
      if (sessionId === undefined) {
        return;
      }
      this.trafficNotificationCoordinator?.stop(sessionId);
      this.trafficMonitor?.stop(sessionId);
      return;
    }
    if (sessionId !== undefined && sessionId !== activeSessionId) {
      return;
    }
    this.trafficNotificationCoordinator?.stop(activeSessionId);
    this.trafficMonitor?.stop(activeSessionId);
    this.trafficSessionId = undefined;
  }

  private disposeTrafficLoop(): void {
    this.trafficNotificationCoordinator?.dispose();
    this.trafficMonitor?.dispose();
    this.trafficSessionId = undefined;
  }

  private syncTrafficLoop(snapshot: VpnRuntimeSnapshot, knownRequest?: VpnStartRequest): void {
    const sessionId: string | undefined =
      snapshot.activeRequest?.sessionId ??
      knownRequest?.sessionId ??
      this.knownRequest?.sessionId ??
      this.trafficSessionId;
    if (snapshot.state === 'RUNNING' && sessionId !== undefined) {
      this.startTrafficLoop(sessionId);
      return;
    }
    if (snapshot.state === 'RECOVERING') {
      this.markTrafficRecovering(sessionId);
      return;
    }
    this.stopTrafficLoop(sessionId);
  }
}

function sanitizeRuntimeFailure(failure: VpnFailure, fallback: VpnFailure): VpnFailure {
  switch (failure.code) {
    case 'VPN_PERMISSION_DENIED':
    case 'VPN_ALREADY_ACTIVE':
    case 'VPN_PROFILE_UNAVAILABLE':
    case 'VPN_CONFIG_INVALID':
    case 'VPN_CREATE_FAILED':
    case 'VPN_TUN_FD_INVALID':
    case 'VPN_TUN_START_FAILED':
    case 'VPN_SOCKET_PROTECT_FAILED':
    case 'VPN_LOCAL_PORT_CONFLICT':
    case 'VPN_BACKGROUND_TASK_FAILED':
    case 'VPN_PROXY_REPLAY_FAILED':
    case 'VPN_SYSTEM_REVOKED':
    case 'VPN_STOP_FAILED':
      return createVpnFailure(failure.code, fallback.detail);
    default:
      return fallback;
  }
}
