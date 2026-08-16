import { SerialCommandQueue } from '../profile/SerialCommandQueue';
import {
  createTunRuntimeFailure,
  createTunRuntimeSnapshot,
  createTunStartOptions,
  createVpnCaptureConfig,
  createVpnCounters,
  createVpnFailure,
  createVpnRuntimeEvent,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  type TunHandle,
  type TunRuntimeFailure,
  type TunRuntimeSnapshot,
  type VpnCaptureConfig,
  type VpnControllerFailedResult,
  type VpnControllerRejectedResult,
  type VpnControllerStartResult,
  type VpnControllerStopResult,
  type VpnFailure,
  type VpnFailureCode,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot
} from './VpnModels';
import {
  ContinuousNotificationPortError,
  TunRuntimePortError,
  VpnPlatformPortError,
  type CancelableDelayTask,
  type TunRuntimeEvent as TunPortEvent,
  type VpnControllerPort,
  type VpnRuntimeCoordinatorDependencies
} from './VpnPorts';

interface ActiveSession {
  request: import('./VpnModels').VpnStartRequest;
  config: VpnCaptureConfig;
  handle?: TunHandle;
  tunSnapshot?: TunRuntimeSnapshot;
  notificationOwned: boolean;
  tunStarted: boolean;
  tunReady: boolean;
}

interface RecoveryContext {
  retryCount: number;
  scheduledRetry?: CancelableDelayTask;
  attemptInFlight: boolean;
}

interface ReadyWaiter {
  sessionId: string;
  resolve(snapshot: TunRuntimeSnapshot): void;
  reject(failure: VpnFailure): void;
}

interface PendingStopResult {
  sessionId: string;
  promise: Promise<VpnControllerStopResult>;
  resolve(result: VpnControllerStopResult): void;
}

class ReadyWaiterValue implements ReadyWaiter {
  sessionId: string;
  private readonly resolveRef: (snapshot: TunRuntimeSnapshot) => void;
  private readonly rejectRef: (failure: VpnFailure) => void;

  constructor(
    sessionId: string,
    resolveRef: (snapshot: TunRuntimeSnapshot) => void,
    rejectRef: (failure: VpnFailure) => void
  ) {
    this.sessionId = sessionId;
    this.resolveRef = resolveRef;
    this.rejectRef = rejectRef;
  }

  resolve(snapshot: TunRuntimeSnapshot): void {
    this.resolveRef(snapshot);
  }

  reject(failure: VpnFailure): void {
    this.rejectRef(failure);
  }
}

class PendingStopResultValue implements PendingStopResult {
  sessionId: string;
  promise: Promise<VpnControllerStopResult>;
  private readonly resolveRef: (result: VpnControllerStopResult) => void;

  constructor(sessionId: string, resolveRef: (result: VpnControllerStopResult) => void, promise: Promise<VpnControllerStopResult>) {
    this.sessionId = sessionId;
    this.resolveRef = resolveRef;
    this.promise = promise;
  }

  resolve(result: VpnControllerStopResult): void {
    this.resolveRef(result);
  }
}

const RECOVERY_DELAYS_MS: number[] = [250, 500, 1000, 2000, 4000];

function cloneCaptureConfig(config: VpnCaptureConfig): VpnCaptureConfig {
  return createVpnCaptureConfig({
    addresses: config.addresses,
    routes: config.routes,
    dnsServers: config.dnsServers,
    mtu: config.mtu,
    ipv4: config.ipv4,
    ipv6: config.ipv6,
    isBlocking: config.isBlocking,
    blockedApplications: config.blockedApplications,
    trustedApplications: config.trustedApplications
  });
}

function cloneTunSnapshot(snapshot: TunRuntimeSnapshot): TunRuntimeSnapshot {
  return createTunRuntimeSnapshot({
    sessionId: snapshot.sessionId,
    state: snapshot.state,
    counters: snapshot.counters,
    ingressTraces: snapshot.ingressTraces,
    failure: snapshot.failure
  });
}

function cloneFailure(failure: VpnFailure | null): VpnFailure | null {
  if (failure === null) {
    return null;
  }
  return createVpnFailure(failure.code, failure.detail);
}

function buildStoppedSnapshot(lastFailure: VpnFailure | null): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state: 'STOPPED',
    activeRequest: null,
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: false,
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure
  });
}

function buildErrorSnapshot(failure: VpnFailure, recoveryAttempt: number = 0): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state: 'ERROR',
    activeRequest: null,
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: false,
    recoveryAttempt,
    scheduledRetryDelayMs: null,
    lastFailure: failure
  });
}

function buildActiveSnapshot(
  state: import('./VpnModels').VpnRuntimeState,
  active: ActiveSession | undefined,
  recoveryAttempt: number,
  scheduledRetryDelayMs: number | null,
  lastFailure: VpnFailure | null
): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state,
    activeRequest: active?.request ?? null,
    activeHandle: active?.handle ?? null,
    captureConfig: active?.config ?? null,
    tunSnapshot: active?.tunSnapshot ?? null,
    notificationActive: active?.notificationOwned ?? false,
    recoveryAttempt,
    scheduledRetryDelayMs,
    lastFailure
  });
}

function buildFailedResult(snapshot: VpnRuntimeSnapshot, failure: VpnFailure): VpnControllerFailedResult {
  return {
    kind: 'FAILED',
    snapshot: createVpnRuntimeSnapshot({
      state: snapshot.state,
      activeRequest: snapshot.activeRequest,
      activeHandle: snapshot.activeHandle,
      captureConfig: snapshot.captureConfig,
      tunSnapshot: snapshot.tunSnapshot,
      notificationActive: snapshot.notificationActive,
      recoveryAttempt: snapshot.recoveryAttempt,
      scheduledRetryDelayMs: snapshot.scheduledRetryDelayMs,
      lastFailure: snapshot.lastFailure
    }),
    failure: cloneFailure(failure)!
  };
}

function buildRejectedResult(snapshot: VpnRuntimeSnapshot, failure: VpnFailure): VpnControllerRejectedResult {
  return {
    kind: 'REJECTED',
    snapshot: createVpnRuntimeSnapshot({
      state: snapshot.state,
      activeRequest: snapshot.activeRequest,
      activeHandle: snapshot.activeHandle,
      captureConfig: snapshot.captureConfig,
      tunSnapshot: snapshot.tunSnapshot,
      notificationActive: snapshot.notificationActive,
      recoveryAttempt: snapshot.recoveryAttempt,
      scheduledRetryDelayMs: snapshot.scheduledRetryDelayMs,
      lastFailure: snapshot.lastFailure
    }),
    failure: cloneFailure(failure)!
  };
}

export class VpnRuntimeCoordinator implements VpnControllerPort {
  private readonly queue: SerialCommandQueue = new SerialCommandQueue();
  private readonly dependencies: VpnRuntimeCoordinatorDependencies;
  private readonly listeners: Map<number, (event: VpnRuntimeEvent) => void> = new Map();
  private nextListenerId: number = 1;
  private snapshotValue: VpnRuntimeSnapshot = buildStoppedSnapshot(null);
  private ownedRequest?: import('./VpnModels').VpnStartRequest;
  private activeSession?: ActiveSession;
  private recovery?: RecoveryContext;
  private readyWaiter?: ReadyWaiter;
  private requestedStopSessionId?: string;
  private pendingStopResult?: PendingStopResult;
  private cleanupQueued: boolean = false;

  constructor(dependencies: VpnRuntimeCoordinatorDependencies) {
    this.dependencies = dependencies;
    this.dependencies.tunRuntime.subscribe((event: TunPortEvent) => {
      this.handleTunRuntimeEvent(event);
    });
    this.dependencies.networkRecovery.subscribeUsableNetwork((status) => {
      this.handleUsableNetwork(status.usable);
    });
    this.dependencies.notification.subscribeCancellation((sessionId: string) => {
      if (this.resolveCurrentSessionId() !== sessionId) {
        return;
      }
      void this.stop(sessionId);
    });
  }

  async start(profileId: string, versionId: string, sessionId: string): Promise<VpnControllerStartResult> {
    const request = createVpnStartRequest(profileId, versionId, sessionId);
    if (this.ownedRequest !== undefined || this.activeSession !== undefined) {
      return buildRejectedResult(this.snapshotValue, createVpnFailure('VPN_ALREADY_ACTIVE', 'Vpn runtime already owns a live or pending session.'));
    }
    this.ownedRequest = request;
    this.publish(buildActiveSnapshot('STARTING', {
      request,
      config: createVpnCaptureConfig({
        addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
        routes: ['0.0.0.0/0', '::/0'],
        dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
        mtu: 1500,
        ipv4: true,
        ipv6: true,
        isBlocking: false,
        blockedApplications: ['com.github.kr328.clash.harmony'],
        trustedApplications: []
      }),
      notificationOwned: false,
      tunStarted: false,
      tunReady: false
    }, 0, null, null), 'STATE_CHANGED');
    return this.queue.execute(() => this.startInternal(request));
  }

  async stop(sessionId?: string): Promise<VpnControllerStopResult> {
    const currentSessionId: string | undefined = this.resolveCurrentSessionId();
    if (sessionId !== undefined && currentSessionId === undefined) {
      return {
        kind: 'STOPPED',
        snapshot: this.snapshot()
      };
    }
    if (sessionId !== undefined && currentSessionId !== undefined && sessionId !== currentSessionId) {
      return {
        kind: 'STOPPED',
        snapshot: this.snapshot()
      };
    }
    const visibleSessionId: string | undefined = sessionId ?? currentSessionId;
    const shouldSharePendingStopResult: boolean =
      visibleSessionId !== undefined &&
      currentSessionId !== undefined &&
      visibleSessionId === currentSessionId &&
      this.snapshotValue.state === 'STARTING';
    if (visibleSessionId !== undefined && (currentSessionId === undefined || visibleSessionId === currentSessionId)) {
      this.requestedStopSessionId = visibleSessionId;
      this.cancelReadyWaiterForStop(visibleSessionId);
      if (this.snapshotValue.state !== 'STOPPING' && this.snapshotValue.state !== 'ERROR') {
        if (this.activeSession !== undefined) {
          this.publish(buildActiveSnapshot('STOPPING', this.activeSession, this.recovery?.retryCount ?? 0, null, this.snapshotValue.lastFailure), 'STATE_CHANGED');
        } else {
          this.publish(createVpnRuntimeSnapshot({
            state: 'STOPPING',
            activeRequest: this.snapshotValue.activeRequest,
            activeHandle: this.snapshotValue.activeHandle,
            captureConfig: this.snapshotValue.captureConfig,
            tunSnapshot: this.snapshotValue.tunSnapshot,
            notificationActive: this.snapshotValue.notificationActive,
            recoveryAttempt: this.snapshotValue.recoveryAttempt,
            scheduledRetryDelayMs: null,
            lastFailure: this.snapshotValue.lastFailure
          }), 'STATE_CHANGED');
        }
      }
      if (shouldSharePendingStopResult) {
        return this.ensurePendingStopResult(visibleSessionId);
      }
    }
    return this.queue.execute(() => this.finishStopInternal(sessionId));
  }

  snapshot(): VpnRuntimeSnapshot {
    return createVpnRuntimeSnapshot({
      state: this.snapshotValue.state,
      activeRequest: this.snapshotValue.activeRequest,
      activeHandle: this.snapshotValue.activeHandle,
      captureConfig: this.snapshotValue.captureConfig,
      tunSnapshot: this.snapshotValue.tunSnapshot,
      notificationActive: this.snapshotValue.notificationActive,
      recoveryAttempt: this.snapshotValue.recoveryAttempt,
      scheduledRetryDelayMs: this.snapshotValue.scheduledRetryDelayMs,
      lastFailure: this.snapshotValue.lastFailure
    });
  }

  subscribe(listener: (event: VpnRuntimeEvent) => void): number {
    const subscriptionId: number = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  private async startInternal(request: import('./VpnModels').VpnStartRequest): Promise<VpnControllerStartResult> {
    let config: VpnCaptureConfig;
    try {
      config = await this.dependencies.resolver.resolve(request.profileId, request.versionId);
    } catch (error) {
      const failure: VpnFailure = createVpnFailure('VPN_PROFILE_UNAVAILABLE', this.describeError(error, 'Profile resolution failed.'));
      const pendingStopResult: PendingStopResult | undefined = this.takePendingStopResult(request.sessionId);
      this.clearOwnedState();
      this.publish(buildStoppedSnapshot(failure), 'FAILED');
      this.resolveTakenPendingStopResult(pendingStopResult);
      return buildFailedResult(this.snapshotValue, failure);
    }

    const active: ActiveSession = {
      request,
      config: cloneCaptureConfig(config),
      notificationOwned: false,
      tunStarted: false,
      tunReady: false
    };
    this.activeSession = active;
    this.publish(buildActiveSnapshot('STARTING', active, 0, null, null), 'STATE_CHANGED');

    if (this.isStopRequested(active.request.sessionId)) {
      return this.finishStopInternal(active.request.sessionId);
    }

    try {
      await this.dependencies.platform.protectProcess();
    } catch (error) {
      const failure: VpnFailure = createVpnFailure('VPN_SOCKET_PROTECT_FAILED', this.describeError(error, 'Process protection failed.'));
      await this.failStartAndCleanup(active, failure);
      return buildFailedResult(this.snapshotValue, failure);
    }

    try {
      active.handle = await this.dependencies.platform.create(active.config);
    } catch (error) {
      if (error instanceof VpnPlatformPortError && error.code === 'CONSENT_DENIED') {
        const pendingStopResult: PendingStopResult | undefined = this.takePendingStopResult(active.request.sessionId);
        this.clearOwnedState();
        this.publish(buildStoppedSnapshot(null), 'STOPPED');
        this.resolveTakenPendingStopResult(pendingStopResult);
        return {
          kind: 'STOPPED',
          snapshot: this.snapshot()
        };
      }
      const failure: VpnFailure = createVpnFailure('VPN_CREATE_FAILED', this.describeError(error, 'Platform session creation failed.'));
      await this.failStartAndCleanup(active, failure);
      return buildFailedResult(this.snapshotValue, failure);
    }

    try {
      active.tunStarted = true;
      active.tunSnapshot = await this.dependencies.tunRuntime.start(
        active.handle,
        createTunStartOptions(active.config, active.config.dnsServers)
      );
      active.tunReady = active.tunSnapshot.state === 'READY';
    } catch (error) {
      const failure: VpnFailure = this.resolveTunFailure(error, 'Tun runtime start failed.', 'VPN_TUN_START_FAILED');
      await this.failStartAndCleanup(active, failure);
      return buildFailedResult(this.snapshotValue, failure);
    }

    this.publish(buildActiveSnapshot('STARTING', active, 0, null, null), 'STATE_CHANGED');

    try {
      active.notificationOwned = true;
      await this.dependencies.notification.start(active.request.sessionId);
    } catch (error) {
      const failure: VpnFailure = createVpnFailure('VPN_BACKGROUND_TASK_FAILED', this.describeError(error, 'Notification start failed.'));
      await this.failStartAndCleanup(active, failure);
      return buildFailedResult(this.snapshotValue, failure);
    }

    if (this.isStopRequested(active.request.sessionId)) {
      return this.finishStopInternal(active.request.sessionId);
    }

    if (!active.tunReady) {
      try {
        active.tunSnapshot = await this.awaitTunReady(active.request.sessionId);
        active.tunReady = true;
      } catch (failure) {
        await this.failStartAndCleanup(active, failure);
        return buildFailedResult(this.snapshotValue, failure);
      }
    }

    if (this.isStopRequested(active.request.sessionId)) {
      return this.finishStopInternal(active.request.sessionId);
    }

    this.publish(buildActiveSnapshot('RUNNING', active, 0, null, null), 'STATE_CHANGED');
    return {
      kind: 'STARTED',
      snapshot: this.snapshot()
    };
  }

  private async stopInternal(sessionId?: string): Promise<VpnControllerStopResult> {
    if (this.recovery?.scheduledRetry !== undefined) {
      this.recovery.scheduledRetry.cancel();
      this.recovery.scheduledRetry = undefined;
    }
    if (this.activeSession === undefined) {
      this.clearOwnedState();
      this.publish(buildStoppedSnapshot(this.snapshotValue.lastFailure), 'STOPPED');
      return {
        kind: 'STOPPED',
        snapshot: this.snapshot()
      };
    }
    const active: ActiveSession = this.activeSession;
    const cleanupErrors: string[] = await this.cleanupActiveSession(active);
    this.clearOwnedState();
    if (cleanupErrors.length > 0) {
      const failure: VpnFailure = createVpnFailure('VPN_STOP_FAILED', cleanupErrors.join(' | '));
      this.publish(buildStoppedSnapshot(failure), 'FAILED');
      return buildFailedResult(this.snapshotValue, failure);
    }
    this.publish(buildStoppedSnapshot(null), 'STOPPED');
    return {
      kind: 'STOPPED',
      snapshot: this.snapshot()
    };
  }

  private finishStopInternal(sessionId?: string): Promise<VpnControllerStopResult> {
    const pendingStopResult: PendingStopResult | undefined =
      sessionId !== undefined && this.pendingStopResult?.sessionId === sessionId
        ? this.pendingStopResult
        : undefined;
    return this.stopInternal(sessionId).then((result) => {
      if (pendingStopResult !== undefined) {
        this.pendingStopResult = undefined;
        pendingStopResult.resolve(result);
      } else {
        this.resolvePendingStopResult(result, sessionId ?? this.resolveCurrentSessionId());
      }
      return result;
    });
  }

  private handleTunRuntimeEvent(event: TunPortEvent): void {
    if (this.activeSession === undefined || event.sessionId !== this.activeSession.request.sessionId) {
      return;
    }
    this.activeSession.tunSnapshot = cloneTunSnapshot(event.snapshot);
    this.activeSession.tunReady = event.snapshot.state === 'READY';

    if (event.snapshot.state === 'READY') {
      if (this.readyWaiter !== undefined && this.readyWaiter.sessionId === event.sessionId) {
        const resolve = this.readyWaiter.resolve;
        this.readyWaiter = undefined;
        resolve(cloneTunSnapshot(event.snapshot));
        return;
      }
      if (this.snapshotValue.state === 'RUNNING') {
        this.publish(buildActiveSnapshot('RUNNING', this.activeSession, 0, null, null), 'SNAPSHOT');
      }
      return;
    }

    if (event.snapshot.state !== 'ERROR') {
      return;
    }

    const tunFailure: TunRuntimeFailure = event.snapshot.failure === null
      ? createTunRuntimeFailure('VPN_TUN_START_FAILED', 'Tun runtime emitted an error without a failure payload.')
      : event.snapshot.failure;
    const publicFailure: VpnFailure = this.mapTunFailureToPublic(tunFailure, 'VPN_TUN_START_FAILED');

    if (this.readyWaiter !== undefined && this.readyWaiter.sessionId === event.sessionId) {
      const reject = this.readyWaiter.reject;
      this.readyWaiter = undefined;
      reject(publicFailure);
      return;
    }

    if (this.snapshotValue.state === 'STOPPING' || this.cleanupQueued) {
      return;
    }

    if (tunFailure.code === 'NETWORK_LOST') {
      this.enterRecovery();
      return;
    }

    this.publish(buildActiveSnapshot('ERROR', this.activeSession, this.recovery?.retryCount ?? 0, null, publicFailure), 'FAILED');
    this.scheduleTerminalCleanup(publicFailure);
  }

  private handleUsableNetwork(usable: boolean): void {
    if (!usable || this.recovery === undefined || this.activeSession === undefined || this.cleanupQueued) {
      return;
    }
    if (this.recovery.scheduledRetry !== undefined || this.recovery.attemptInFlight || this.isStopRequested(this.activeSession.request.sessionId)) {
      return;
    }
    this.scheduleRecoveryRetry(this.activeSession.request.sessionId);
  }

  private enterRecovery(): void {
    if (this.activeSession === undefined || this.recovery !== undefined) {
      return;
    }
    this.activeSession.tunReady = false;
    this.recovery = {
      retryCount: 0,
      attemptInFlight: false
    };
    this.publish(buildActiveSnapshot('RECOVERING', this.activeSession, 0, null, this.snapshotValue.lastFailure), 'STATE_CHANGED');
    const sessionId: string = this.activeSession.request.sessionId;
    void this.queue.execute(() => this.runCloseStale(sessionId));
  }

  private async runCloseStale(sessionId: string): Promise<void> {
    if (this.activeSession === undefined || this.recovery === undefined || this.activeSession.request.sessionId !== sessionId || this.cleanupQueued) {
      return;
    }
    try {
      await this.dependencies.tunRuntime.closeStaleOutboundConnections(sessionId);
      this.maybeScheduleRecoveryRetryFromCurrentNetwork(sessionId);
    } catch (error) {
      const failure: VpnFailure = this.resolveTunFailure(error, 'Failed to close stale outbound connections.', 'VPN_TUN_START_FAILED');
      this.publish(buildActiveSnapshot('ERROR', this.activeSession, this.recovery.retryCount, null, failure), 'FAILED');
      await this.performTerminalCleanup(failure);
    }
  }

  private async runRecoveryAttempt(sessionId: string): Promise<void> {
    if (this.activeSession === undefined || this.recovery === undefined || this.activeSession.request.sessionId !== sessionId || this.cleanupQueued) {
      return;
    }
    const recoveryContext: RecoveryContext = this.recovery;
    if (this.recovery.attemptInFlight) {
      return;
    }
    if (this.isStopRequested(sessionId)) {
      return;
    }
    this.recovery.scheduledRetry = undefined;
    this.recovery.attemptInFlight = true;
    try {
      const recoveredSnapshot: TunRuntimeSnapshot = await this.dependencies.tunRuntime.recover(sessionId);
      if (!this.isRecoveryAttemptStillLive(sessionId, recoveryContext)) {
        if (this.recovery === recoveryContext) {
          this.recovery.attemptInFlight = false;
        }
        return;
      }
      if (recoveredSnapshot.sessionId !== sessionId) {
        const mismatchFailure: VpnFailure = createVpnFailure('VPN_TUN_START_FAILED', `Tun recovery returned a stale session snapshot for ${recoveredSnapshot.sessionId}.`);
        this.recovery.attemptInFlight = false;
        this.publish(buildActiveSnapshot('ERROR', this.activeSession, this.recovery.retryCount, null, mismatchFailure), 'FAILED');
        await this.performTerminalCleanup(mismatchFailure);
        return;
      }
      this.activeSession.tunSnapshot = cloneTunSnapshot(recoveredSnapshot);
      this.activeSession.tunReady = recoveredSnapshot.state === 'READY';
      if (recoveredSnapshot.state === 'READY') {
        this.recovery.attemptInFlight = false;
        this.recovery = undefined;
        this.publish(buildActiveSnapshot('RUNNING', this.activeSession, 0, null, null), 'STATE_CHANGED');
        return;
      }
      const failure: TunRuntimeFailure = recoveredSnapshot.failure ?? createTunRuntimeFailure('VPN_TUN_START_FAILED', 'Tun recovery returned without readiness.');
      await this.handleRecoveryFailure(failure);
    } catch (error) {
      if (!this.isRecoveryAttemptStillLive(sessionId, recoveryContext)) {
        if (this.recovery === recoveryContext) {
          this.recovery.attemptInFlight = false;
        }
        return;
      }
      const failure: TunRuntimeFailure = error instanceof TunRuntimePortError
        ? error.failure
        : createTunRuntimeFailure('VPN_TUN_START_FAILED', this.describeError(error, 'Tun recovery failed.'));
      await this.handleRecoveryFailure(failure);
    }
  }

  private async handleRecoveryFailure(failure: TunRuntimeFailure): Promise<void> {
    if (this.activeSession === undefined || this.recovery === undefined) {
      return;
    }
    this.recovery.attemptInFlight = false;
    if (failure.code === 'NETWORK_LOST') {
      this.recovery.retryCount += 1;
      if (this.recovery.retryCount >= RECOVERY_DELAYS_MS.length) {
        const publicFailure: VpnFailure = createVpnFailure('VPN_TUN_START_FAILED', failure.detail);
        this.publish(buildActiveSnapshot('ERROR', this.activeSession, this.recovery.retryCount, null, publicFailure), 'FAILED');
        await this.performTerminalCleanup(publicFailure);
        return;
      }
      this.publish(buildActiveSnapshot('RECOVERING', this.activeSession, this.recovery.retryCount, null, this.snapshotValue.lastFailure), 'STATE_CHANGED');
      this.maybeScheduleRecoveryRetryFromCurrentNetwork(this.activeSession.request.sessionId);
      return;
    }
    const publicFailure: VpnFailure = this.mapTunFailureToPublic(failure, 'VPN_TUN_START_FAILED');
    this.publish(buildActiveSnapshot('ERROR', this.activeSession, this.recovery.retryCount, null, publicFailure), 'FAILED');
    await this.performTerminalCleanup(publicFailure);
  }

  private scheduleTerminalCleanup(failure: VpnFailure): void {
    if (this.cleanupQueued) {
      return;
    }
    this.cleanupQueued = true;
    void this.queue.execute(() => this.performTerminalCleanup(failure));
  }

  private async performTerminalCleanup(failure: VpnFailure): Promise<void> {
    if (!this.cleanupQueued) {
      this.cleanupQueued = true;
    }
    let finalFailure: VpnFailure = failure;
    if (this.activeSession !== undefined) {
      const cleanupErrors: string[] = await this.cleanupActiveSession(this.activeSession);
      if (cleanupErrors.length > 0) {
        finalFailure = createVpnFailure(finalFailure.code, `${finalFailure.detail} | cleanup: ${cleanupErrors.join(' | ')}`);
      }
    }
    const recoveryAttempt: number = this.recovery?.retryCount ?? 0;
    this.clearOwnedState();
    this.publish(buildErrorSnapshot(finalFailure, recoveryAttempt), 'FAILED');
  }

  private async failStartAndCleanup(active: ActiveSession, failure: VpnFailure): Promise<void> {
    const cleanupErrors: string[] = await this.cleanupActiveSession(active);
    const pendingStopResult: PendingStopResult | undefined = this.takePendingStopResult(active.request.sessionId);
    this.clearOwnedState();
    const finalFailure: VpnFailure = cleanupErrors.length === 0
      ? failure
      : createVpnFailure(failure.code, `${failure.detail} | cleanup: ${cleanupErrors.join(' | ')}`);
    this.publish(buildStoppedSnapshot(finalFailure), 'FAILED');
    this.resolveTakenPendingStopResult(pendingStopResult);
  }

  private async cleanupActiveSession(active: ActiveSession): Promise<string[]> {
    const cleanupErrors: string[] = [];
    if (active.tunStarted) {
      try {
        await this.dependencies.tunRuntime.stop();
      } catch (error) {
        cleanupErrors.push(this.describeError(error, 'Tun stop failed.'));
      }
    }
    if (active.handle !== undefined) {
      try {
        await this.dependencies.platform.destroy(active.handle.vpnId);
      } catch (error) {
        cleanupErrors.push(this.describeError(error, 'Platform destroy failed.'));
      }
    }
    if (active.notificationOwned) {
      try {
        await this.dependencies.notification.stop(active.request.sessionId);
      } catch (error) {
        cleanupErrors.push(this.describeError(error, 'Notification stop failed.'));
      }
    }
    return cleanupErrors;
  }

  private async awaitTunReady(sessionId: string): Promise<TunRuntimeSnapshot> {
    return await new Promise<TunRuntimeSnapshot>((resolve, reject) => {
      this.readyWaiter = new ReadyWaiterValue(sessionId, resolve, reject);
      if (this.isStopRequested(sessionId)) {
        this.cancelReadyWaiterForStop(sessionId);
      }
    });
  }

  private mapTunFailureToPublic(failure: TunRuntimeFailure, fallbackCode: VpnFailureCode): VpnFailure {
    if (failure.code === 'NETWORK_LOST') {
      return createVpnFailure(fallbackCode, failure.detail);
    }
    return createVpnFailure(failure.code, failure.detail);
  }

  private resolveTunFailure(error: Object | undefined, fallbackMessage: string, fallbackCode: VpnFailureCode): VpnFailure {
    if (error instanceof TunRuntimePortError) {
      return this.mapTunFailureToPublic(error.failure, fallbackCode);
    }
    return createVpnFailure(fallbackCode, this.describeError(error, fallbackMessage));
  }

  private describeError(error: Object | undefined, fallbackMessage: string): string {
    if (error instanceof TunRuntimePortError) {
      return error.failure.detail;
    }
    if (error instanceof VpnPlatformPortError || error instanceof ContinuousNotificationPortError) {
      return error.message;
    }
    if (error instanceof Error) {
      return error.message;
    }
    return fallbackMessage;
  }

  private isStopRequested(sessionId: string): boolean {
    return this.requestedStopSessionId === sessionId;
  }

  private resolveCurrentSessionId(): string | undefined {
    return this.activeSession?.request.sessionId ?? this.ownedRequest?.sessionId;
  }

  private ensurePendingStopResult(sessionId: string): Promise<VpnControllerStopResult> {
    if (this.pendingStopResult !== undefined && this.pendingStopResult.sessionId === sessionId) {
      return this.pendingStopResult.promise;
    }
    let resolveRef: ((result: VpnControllerStopResult) => void) | undefined = undefined;
    const promise: Promise<VpnControllerStopResult> = new Promise((resolve) => {
      resolveRef = resolve;
    });
    this.pendingStopResult = new PendingStopResultValue(sessionId, resolveRef!, promise);
    return promise;
  }

  private takePendingStopResult(sessionId: string | undefined): PendingStopResult | undefined {
    if (sessionId === undefined || this.pendingStopResult === undefined || this.pendingStopResult.sessionId !== sessionId) {
      return undefined;
    }
    const pendingStopResult: PendingStopResult = this.pendingStopResult;
    this.pendingStopResult = undefined;
    return pendingStopResult;
  }

  private resolvePendingStopResult(result: VpnControllerStopResult, sessionId: string | undefined): void {
    if (sessionId === undefined || this.pendingStopResult === undefined || this.pendingStopResult.sessionId !== sessionId) {
      return;
    }
    const resolve = this.pendingStopResult.resolve;
    this.pendingStopResult = undefined;
    resolve(result);
  }

  private resolveTakenPendingStopResult(pendingStopResult: PendingStopResult | undefined): void {
    if (pendingStopResult === undefined) {
      return;
    }
    pendingStopResult.resolve({
      kind: 'STOPPED',
      snapshot: this.snapshot()
    });
  }

  private cancelReadyWaiterForStop(sessionId: string): void {
    if (this.readyWaiter === undefined || this.readyWaiter.sessionId !== sessionId) {
      return;
    }
    const snapshotToResolve: TunRuntimeSnapshot = this.activeSession?.tunSnapshot !== undefined
      ? cloneTunSnapshot(this.activeSession.tunSnapshot)
      : createTunRuntimeSnapshot({
        sessionId,
        state: 'STARTING',
        counters: createVpnCounters(0, 0, 0, 0),
        ingressTraces: [],
        failure: null
      });
    const resolve = this.readyWaiter.resolve;
    this.readyWaiter = undefined;
    resolve(snapshotToResolve);
  }

  private maybeScheduleRecoveryRetryFromCurrentNetwork(sessionId: string): void {
    if (this.activeSession === undefined || this.recovery === undefined || this.cleanupQueued) {
      return;
    }
    if (this.activeSession.request.sessionId !== sessionId || this.recovery.scheduledRetry !== undefined || this.recovery.attemptInFlight) {
      return;
    }
    if (this.isStopRequested(sessionId) || this.recovery.retryCount >= RECOVERY_DELAYS_MS.length) {
      return;
    }
    const currentStatus = this.dependencies.networkRecovery.currentNetwork();
    if (!currentStatus.usable) {
      return;
    }
    this.scheduleRecoveryRetry(sessionId);
  }

  private isRecoveryAttemptStillLive(sessionId: string, recoveryContext: RecoveryContext): boolean {
    return this.activeSession !== undefined &&
      this.recovery === recoveryContext &&
      this.activeSession.request.sessionId === sessionId &&
      !this.cleanupQueued &&
      !this.isStopRequested(sessionId);
  }

  private scheduleRecoveryRetry(sessionId: string): void {
    if (this.activeSession === undefined || this.recovery === undefined || this.cleanupQueued) {
      return;
    }
    if (this.activeSession.request.sessionId !== sessionId || this.recovery.scheduledRetry !== undefined || this.recovery.attemptInFlight) {
      return;
    }
    if (this.recovery.retryCount >= RECOVERY_DELAYS_MS.length) {
      return;
    }
    const delayMs: number = RECOVERY_DELAYS_MS[this.recovery.retryCount];
    this.recovery.scheduledRetry = this.dependencies.scheduler.schedule(delayMs, async () => {
      await this.queue.execute(() => this.runRecoveryAttempt(sessionId));
    });
    this.publish(buildActiveSnapshot('RECOVERING', this.activeSession, this.recovery.retryCount, delayMs, this.snapshotValue.lastFailure), 'RECOVERY_SCHEDULED');
  }

  private clearOwnedState(): void {
    if (this.recovery?.scheduledRetry !== undefined) {
      this.recovery.scheduledRetry.cancel();
    }
    this.ownedRequest = undefined;
    this.activeSession = undefined;
    this.recovery = undefined;
    this.readyWaiter = undefined;
    this.requestedStopSessionId = undefined;
    this.pendingStopResult = undefined;
    this.cleanupQueued = false;
  }

  private publish(snapshot: VpnRuntimeSnapshot, eventType: import('./VpnModels').VpnRuntimeEventType): void {
    this.snapshotValue = createVpnRuntimeSnapshot({
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
    const event: VpnRuntimeEvent = createVpnRuntimeEvent(eventType, this.snapshotValue);
    this.listeners.forEach((listener) => {
      listener(event);
    });
  }
}
