import { SerialCommandQueue } from '../profile/SerialCommandQueue';
import {
  createTunRuntimeSnapshot,
  createTunStartOptions,
  createVpnCaptureConfig,
  createVpnFailure,
  createVpnRuntimeEvent,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  type TunHandle,
  type TunRuntimeSnapshot,
  type VpnCaptureConfig,
  type VpnControllerFailedResult,
  type VpnControllerRejectedResult,
  type VpnControllerStartResult,
  type VpnControllerStopResult,
  type VpnFailure,
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
  request: import('./VpnModels').VpnStartRequest;
  config: VpnCaptureConfig;
  retryCount: number;
  scheduledRetry?: CancelableDelayTask;
}

interface ReadyWaiter {
  sessionId: string;
  resolve(snapshot: TunRuntimeSnapshot): void;
  reject(failure: VpnFailure): void;
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

const RECOVERY_DELAYS_MS: number[] = [250, 500, 1000, 2000, 4000];

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

function buildStartingSnapshot(
  request: import('./VpnModels').VpnStartRequest,
  config: VpnCaptureConfig | null,
  handle: TunHandle | null,
  tunSnapshot: TunRuntimeSnapshot | null,
  notificationActive: boolean
): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state: 'STARTING',
    activeRequest: request,
    activeHandle: handle,
    captureConfig: config,
    tunSnapshot,
    notificationActive,
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure: null
  });
}

function buildRecoveringSnapshot(
  request: import('./VpnModels').VpnStartRequest,
  config: VpnCaptureConfig,
  recoveryAttempt: number,
  scheduledRetryDelayMs: number | null,
  failure: VpnFailure
): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state: 'RECOVERING',
    activeRequest: request,
    activeHandle: null,
    captureConfig: config,
    tunSnapshot: null,
    notificationActive: false,
    recoveryAttempt,
    scheduledRetryDelayMs,
    lastFailure: failure
  });
}

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

  constructor(dependencies: VpnRuntimeCoordinatorDependencies) {
    this.dependencies = dependencies;
    this.dependencies.tunRuntime.subscribe((event: TunPortEvent) => {
      void this.handleTunRuntimeEvent(event);
    });
    this.dependencies.networkRecovery.subscribeUsableNetwork((status) => {
      void this.handleUsableNetwork(status.usable);
    });
    this.dependencies.notification.subscribeCancellation((sessionId: string) => {
      this.requestedStopSessionId = sessionId;
      void this.stop(sessionId);
    });
  }

  async start(profileId: string, versionId: string, sessionId: string): Promise<VpnControllerStartResult> {
    const request = createVpnStartRequest(profileId, versionId, sessionId);
    if (this.ownedRequest !== undefined || this.activeSession !== undefined || this.recovery !== undefined) {
      return buildRejectedResult(this.snapshotValue, createVpnFailure('ALREADY_ACTIVE', 'Vpn runtime already owns a live or recovering session.'));
    }
    this.ownedRequest = request;
    this.publish(buildStartingSnapshot(request, null, null, null, false), 'STATE_CHANGED');
    return await this.queue.execute(async () => {
      return await this.startInternal(request);
    });
  }

  async stop(sessionId?: string): Promise<VpnControllerStopResult> {
    const visibleSessionId: string | undefined =
      sessionId
      ?? this.activeSession?.request.sessionId
      ?? this.recovery?.request.sessionId
      ?? this.ownedRequest?.sessionId;
    if (visibleSessionId !== undefined) {
      this.requestedStopSessionId = visibleSessionId;
    }
    return await this.queue.execute(async () => {
      return await this.stopInternal(sessionId);
    });
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
      const failure: VpnFailure = createVpnFailure('RESOLVE_FAILED', this.describeError(error, 'Profile resolution failed.'));
      this.ownedRequest = undefined;
      this.publish(buildStoppedSnapshot(failure), 'FAILED');
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
    this.publish(buildStartingSnapshot(active.request, active.config, null, null, false), 'STATE_CHANGED');

    if (this.isStopRequested(active.request.sessionId)) {
      await this.cleanupActiveSession(active);
      this.activeSession = undefined;
      this.ownedRequest = undefined;
      this.clearStopRequest(active.request.sessionId);
      this.publish(buildStoppedSnapshot(null), 'STOPPED');
      return {
        kind: 'STOPPED',
        snapshot: this.snapshot()
      };
    }

    try {
      await this.dependencies.platform.protectProcess();
    } catch (error) {
      const failure: VpnFailure = createVpnFailure('PROCESS_PROTECT_FAILED', this.describeError(error, 'Process protection failed.'));
      await this.failStartAndCleanup(active, failure);
      return buildFailedResult(this.snapshotValue, failure);
    }

    try {
      active.handle = await this.dependencies.platform.create(active.config);
    } catch (error) {
      if (error instanceof VpnPlatformPortError && error.code === 'CONSENT_DENIED') {
        await this.cleanupActiveSession(active);
        this.activeSession = undefined;
        this.ownedRequest = undefined;
        this.publish(buildStoppedSnapshot(null), 'STOPPED');
        return {
          kind: 'STOPPED',
          snapshot: this.snapshot()
        };
      }
      const failure: VpnFailure = createVpnFailure('PLATFORM_CREATE_FAILED', this.describeError(error, 'Platform session creation failed.'));
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
      const failure: VpnFailure = this.resolveTunFailure(error, 'Tun runtime start failed.', 'TUN_START_FAILED');
      await this.failStartAndCleanup(active, failure);
      return buildFailedResult(this.snapshotValue, failure);
    }

    this.publish(buildStartingSnapshot(
      active.request,
      active.config,
      active.handle,
      active.tunSnapshot ?? null,
      false
    ), 'STATE_CHANGED');

    try {
      active.notificationOwned = true;
      await this.dependencies.notification.start(active.request.sessionId);
    } catch (error) {
      const failure: VpnFailure = createVpnFailure('NOTIFICATION_START_FAILED', this.describeError(error, 'Notification start failed.'));
      await this.failStartAndCleanup(active, failure);
      return buildFailedResult(this.snapshotValue, failure);
    }

    if (this.isStopRequested(active.request.sessionId)) {
      await this.cleanupActiveSession(active);
      this.activeSession = undefined;
      this.ownedRequest = undefined;
      this.clearStopRequest(active.request.sessionId);
      this.publish(buildStoppedSnapshot(null), 'STOPPED');
      return {
        kind: 'STOPPED',
        snapshot: this.snapshot()
      };
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
      await this.cleanupActiveSession(active);
      this.activeSession = undefined;
      this.ownedRequest = undefined;
      this.clearStopRequest(active.request.sessionId);
      this.publish(buildStoppedSnapshot(null), 'STOPPED');
      return {
        kind: 'STOPPED',
        snapshot: this.snapshot()
      };
    }

    this.publish(createVpnRuntimeSnapshot({
      state: 'RUNNING',
      activeRequest: active.request,
      activeHandle: active.handle,
      captureConfig: active.config,
      tunSnapshot: active.tunSnapshot ?? null,
      notificationActive: true,
      recoveryAttempt: 0,
      scheduledRetryDelayMs: null,
      lastFailure: null
    }), 'STATE_CHANGED');
    return {
      kind: 'STARTED',
      snapshot: this.snapshot()
    };
  }

  private async stopInternal(sessionId?: string): Promise<VpnControllerStopResult> {
    const expectedSessionId: string | undefined = sessionId ?? this.activeSession?.request.sessionId ?? this.recovery?.request.sessionId;
    if (this.recovery !== undefined) {
      this.recovery.scheduledRetry?.cancel();
      this.recovery = undefined;
    }
    if (this.activeSession === undefined) {
      this.ownedRequest = undefined;
      this.clearStopRequest(expectedSessionId);
      this.publish(buildStoppedSnapshot(this.snapshotValue.lastFailure), 'STOPPED');
      return {
        kind: 'STOPPED',
        snapshot: this.snapshot()
      };
    }
    const active: ActiveSession = this.activeSession;
    const cleanupErrors: string[] = await this.cleanupActiveSession(active);
    this.activeSession = undefined;
    this.ownedRequest = undefined;
    this.clearStopRequest(active.request.sessionId);
    if (cleanupErrors.length > 0) {
      const failure: VpnFailure = createVpnFailure('STOP_FAILED', cleanupErrors.join(' | '));
      this.publish(buildStoppedSnapshot(failure), 'FAILED');
      return buildFailedResult(this.snapshotValue, failure);
    }
    this.publish(buildStoppedSnapshot(null), 'STOPPED');
    return {
      kind: 'STOPPED',
      snapshot: this.snapshot()
    };
  }

  private async handleTunRuntimeEvent(event: TunPortEvent): Promise<void> {
    if (this.activeSession === undefined) {
      return;
    }
    if (event.sessionId !== this.activeSession.request.sessionId) {
      return;
    }
    this.activeSession.tunSnapshot = cloneTunSnapshot(event.snapshot);
    this.activeSession.tunReady = event.snapshot.state === 'READY';

    if (event.snapshot.state === 'READY') {
      if (this.readyWaiter !== undefined && this.readyWaiter.sessionId === event.sessionId) {
        const resolve = this.readyWaiter.resolve;
        this.readyWaiter = undefined;
        resolve(cloneTunSnapshot(event.snapshot));
      }
      if (this.snapshotValue.state === 'RUNNING') {
        this.publish(createVpnRuntimeSnapshot({
          state: 'RUNNING',
          activeRequest: this.activeSession.request,
          activeHandle: this.activeSession.handle ?? null,
          captureConfig: this.activeSession.config,
          tunSnapshot: this.activeSession.tunSnapshot,
          notificationActive: this.activeSession.notificationOwned,
          recoveryAttempt: 0,
          scheduledRetryDelayMs: null,
          lastFailure: null
        }), 'SNAPSHOT');
      }
      return;
    }

    if (event.snapshot.state !== 'ERROR') {
      return;
    }

    const failure: VpnFailure = event.snapshot.failure === null
      ? createVpnFailure('TUN_START_FAILED', 'Tun runtime emitted an error without a failure payload.')
      : cloneFailure(event.snapshot.failure)!;

    if (this.readyWaiter !== undefined && this.readyWaiter.sessionId === event.sessionId) {
      const reject = this.readyWaiter.reject;
      this.readyWaiter = undefined;
      reject(failure);
      return;
    }

    if (failure.code === 'NETWORK_LOST') {
      await this.enterRecovery(failure);
      return;
    }

    this.publish(createVpnRuntimeSnapshot({
      state: 'ERROR',
      activeRequest: this.activeSession.request,
      activeHandle: this.activeSession.handle ?? null,
      captureConfig: this.activeSession.config,
      tunSnapshot: this.activeSession.tunSnapshot,
      notificationActive: this.activeSession.notificationOwned,
      recoveryAttempt: 0,
      scheduledRetryDelayMs: null,
      lastFailure: failure
    }), 'FAILED');
  }

  private async handleUsableNetwork(usable: boolean): Promise<void> {
    if (!usable || this.recovery === undefined) {
      return;
    }
    if (this.recovery.scheduledRetry !== undefined) {
      return;
    }
    if (this.isStopRequested(this.recovery.request.sessionId)) {
      return;
    }
    if (this.recovery.retryCount >= RECOVERY_DELAYS_MS.length) {
      const failure: VpnFailure = createVpnFailure('RECOVERY_EXHAUSTED', 'Vpn recovery retry budget exhausted.');
      this.recovery = undefined;
      this.publish(buildStoppedSnapshot(failure), 'FAILED');
      this.publish(createVpnRuntimeSnapshot({
        state: 'ERROR',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: false,
        recoveryAttempt: RECOVERY_DELAYS_MS.length,
        scheduledRetryDelayMs: null,
        lastFailure: failure
      }), 'FAILED');
      return;
    }
    const delayMs: number = RECOVERY_DELAYS_MS[this.recovery.retryCount];
    const requestSessionId: string = this.recovery.request.sessionId;
    this.recovery.scheduledRetry = this.dependencies.scheduler.schedule(delayMs, async () => {
      await this.queue.execute(async () => {
        await this.runRecoveryRetry(requestSessionId);
      });
    });
    this.publish(buildRecoveringSnapshot(
      this.recovery.request,
      this.recovery.config,
      this.recovery.retryCount,
      delayMs,
      this.snapshotValue.lastFailure ?? createVpnFailure('NETWORK_LOST', 'Vpn recovery is waiting for a usable network.')
    ), 'RECOVERY_SCHEDULED');
  }

  private async runRecoveryRetry(sessionId: string): Promise<void> {
    if (this.recovery === undefined || this.recovery.request.sessionId !== sessionId) {
      return;
    }
    if (this.isStopRequested(sessionId)) {
      this.recovery.scheduledRetry?.cancel();
      this.recovery = undefined;
      this.publish(buildStoppedSnapshot(null), 'STOPPED');
      return;
    }
    const retryContext: RecoveryContext = this.recovery;
    retryContext.scheduledRetry = undefined;
    this.recovery = undefined;
    const result: VpnControllerStartResult = await this.startInternal(retryContext.request);
    if (result.kind === 'STARTED') {
      return;
    }
    if (result.kind === 'FAILED' && result.failure.code === 'NETWORK_LOST') {
      retryContext.retryCount += 1;
      if (retryContext.retryCount >= RECOVERY_DELAYS_MS.length) {
        const failure: VpnFailure = createVpnFailure('RECOVERY_EXHAUSTED', 'Vpn recovery retry budget exhausted.');
        this.recovery = undefined;
        this.publish(createVpnRuntimeSnapshot({
          state: 'ERROR',
          activeRequest: null,
          activeHandle: null,
          captureConfig: null,
          tunSnapshot: null,
          notificationActive: false,
          recoveryAttempt: RECOVERY_DELAYS_MS.length,
          scheduledRetryDelayMs: null,
          lastFailure: failure
        }), 'FAILED');
      } else {
        this.recovery = retryContext;
        this.publish(buildRecoveringSnapshot(
          retryContext.request,
          retryContext.config,
          retryContext.retryCount,
          null,
          result.failure
        ), 'STATE_CHANGED');
      }
      return;
    }
    this.ownedRequest = undefined;
  }

  private async enterRecovery(failure: VpnFailure): Promise<void> {
    if (this.activeSession === undefined) {
      return;
    }
    const active: ActiveSession = this.activeSession;
    const request = active.request;
    const config = active.config;
    this.activeSession = undefined;
    this.recovery = {
      request: createVpnStartRequest(request.profileId, request.versionId, request.sessionId),
      config: cloneCaptureConfig(config),
      retryCount: 0
    };
    this.publish(buildRecoveringSnapshot(
      this.recovery.request,
      this.recovery.config,
      0,
      null,
      failure
    ), 'STATE_CHANGED');
    await this.cleanupActiveSession(active);
  }

  private async failStartAndCleanup(active: ActiveSession, failure: VpnFailure): Promise<void> {
    const cleanupErrors: string[] = await this.cleanupActiveSession(active);
    this.activeSession = undefined;
    const finalFailure: VpnFailure = cleanupErrors.length === 0
      ? failure
      : createVpnFailure(failure.code, `${failure.detail} | cleanup: ${cleanupErrors.join(' | ')}`);
    if (finalFailure.code === 'NETWORK_LOST') {
      this.recovery = {
        request: createVpnStartRequest(active.request.profileId, active.request.versionId, active.request.sessionId),
        config: cloneCaptureConfig(active.config),
        retryCount: this.recovery?.retryCount ?? 0
      };
      this.publish(buildRecoveringSnapshot(
        this.recovery.request,
        this.recovery.config,
        this.recovery.retryCount,
        null,
        finalFailure
      ), 'FAILED');
      return;
    }
    this.ownedRequest = undefined;
    this.publish(buildStoppedSnapshot(finalFailure), 'FAILED');
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
    });
  }

  private resolveTunFailure(error: Object | undefined, fallbackMessage: string, fallbackCode: 'TUN_START_FAILED' | 'NETWORK_LOST'): VpnFailure {
    if (error instanceof TunRuntimePortError) {
      return cloneFailure(error.failure)!;
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

  private clearStopRequest(sessionId: string | undefined): void {
    if (sessionId === undefined) {
      this.requestedStopSessionId = undefined;
      return;
    }
    if (this.requestedStopSessionId === sessionId) {
      this.requestedStopSessionId = undefined;
    }
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
