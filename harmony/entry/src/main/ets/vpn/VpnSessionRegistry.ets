import {
  createVpnRuntimeEvent,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  type TunHandle,
  type TunRuntimeSnapshot,
  type VpnActiveHandleSummary,
  type VpnCaptureConfig,
  type VpnFailure,
  type VpnRpcClientContext,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot,
  type VpnRuntimeState,
  type VpnRuntimeEventType,
  type VpnStartRequest
} from '@cmfa/shared';
import type { VpnRuntimeSnapshotPort, VpnStoppedProxyLease } from '@cmfa/shared';

export type VpnSessionRegistryErrorCode = 'SESSION_ALREADY_LIVE' | 'PROXY_MUTATION_IN_PROGRESS';

export class VpnSessionRegistryError extends Error {
  code: VpnSessionRegistryErrorCode;

  constructor(code: VpnSessionRegistryErrorCode, detail: string) {
    super(detail);
    this.code = code;
  }
}

class VpnStoppedProxyLeaseRecord implements VpnStoppedProxyLease {
  private readonly registry: VpnSessionRegistry;
  private readonly snapshotValue: VpnRuntimeSnapshot;
  private released: boolean = false;

  constructor(registry: VpnSessionRegistry, snapshotValue: VpnRuntimeSnapshot) {
    this.registry = registry;
    this.snapshotValue = cloneSnapshot(snapshotValue);
  }

  snapshot(): VpnRuntimeSnapshot {
    return cloneSnapshot(this.snapshotValue);
  }

  release(): void {
    if (this.released) {
      return;
    }
    this.released = true;
    this.registry.releaseStoppedProxyLease();
  }
}

export interface VpnSessionRegistryUpdate {
  sessionId: string;
  state: VpnRuntimeState;
  activeHandle?: TunHandle | VpnActiveHandleSummary | null;
  captureConfig?: VpnCaptureConfig | null;
  tunSnapshot?: TunRuntimeSnapshot | null;
  notificationActive?: boolean;
  recoveryAttempt?: number;
  scheduledRetryDelayMs?: number | null;
  lastFailure?: VpnFailure | null;
}

type HydratableBridgeState = 'STARTING' | 'RECOVERING' | 'STOPPING' | 'RUNNING';

function buildStoppedSnapshot(lastFailure: VpnFailure | null = null): VpnRuntimeSnapshot {
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

function cloneRequest(request: VpnStartRequest): VpnStartRequest {
  return createVpnStartRequest(request.profileId, request.versionId, request.sessionId);
}

function isSameRequest(left: VpnStartRequest | null | undefined, right: VpnStartRequest | null | undefined): boolean {
  if (left === null || left === undefined || right === null || right === undefined) {
    return false;
  }
  return left.sessionId === right.sessionId &&
    left.profileId === right.profileId &&
    left.versionId === right.versionId;
}

function buildHydratedSnapshot(
  state: VpnRuntimeState,
  activeRequest: VpnStartRequest | null,
  lastFailure: VpnFailure | null
): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state,
    activeRequest,
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: false,
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure
  });
}

function requiresAuthenticatedRpcContext(state: VpnRuntimeState): boolean {
  return state === 'STARTING' || state === 'RUNNING' || state === 'RECOVERING' || state === 'STOPPING';
}

export class VpnSessionRegistry implements VpnRuntimeSnapshotPort {
  private readonly listeners: Map<number, (event: VpnRuntimeEvent) => void> = new Map();
  private nextListenerId: number = 1;
  private snapshotValue: VpnRuntimeSnapshot = buildStoppedSnapshot();
  private userStopRequestedSessionId?: string;
  private liveStoppedProxyLeaseCount: number = 0;
  private liveSessionId?: string;
  private nextAnonymousSessionOrdinal: number = 1;
  private runtimeMirrorHydrationPending: boolean = false;

  snapshot(): VpnRuntimeSnapshot {
    return cloneSnapshot(this.snapshotValue);
  }

  subscribe(listener: (event: VpnRuntimeEvent) => void): number {
    const subscriptionId: number = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }

  acquireStoppedProxyLease(): VpnStoppedProxyLease | undefined {
    if (this.runtimeMirrorHydrationPending || this.snapshotValue.state !== 'STOPPED' || this.liveSessionId !== undefined) {
      return undefined;
    }
    this.liveStoppedProxyLeaseCount += 1;
    return new VpnStoppedProxyLeaseRecord(this, this.snapshotValue);
  }

  beginRuntimeMirrorHydration(): void {
    if (this.runtimeMirrorHydrationPending) {
      return;
    }
    this.runtimeMirrorHydrationPending = true;
    const nextSnapshot: VpnRuntimeSnapshot = createVpnRuntimeSnapshot({
      state: 'RECOVERING',
      activeRequest: this.snapshotValue.activeRequest,
      activeHandle: this.snapshotValue.activeHandle,
      captureConfig: this.snapshotValue.captureConfig,
      tunSnapshot: this.snapshotValue.tunSnapshot,
      notificationActive: this.snapshotValue.notificationActive,
      recoveryAttempt: this.snapshotValue.recoveryAttempt,
      scheduledRetryDelayMs: this.snapshotValue.scheduledRetryDelayMs,
      lastFailure: this.snapshotValue.lastFailure
    });
    this.publishSnapshot(nextSnapshot, inferEventType(this.snapshotValue, nextSnapshot));
  }

  completeRuntimeMirrorHydrationUnavailable(): void {
    if (!this.runtimeMirrorHydrationPending) {
      return;
    }
    this.runtimeMirrorHydrationPending = false;
    this.liveSessionId = undefined;
    this.userStopRequestedSessionId = undefined;
    this.publishSnapshot(buildStoppedSnapshot(this.snapshotValue.lastFailure), 'STOPPED');
  }

  beginPending(request: VpnStartRequest): VpnRuntimeSnapshot {
    if (this.liveStoppedProxyLeaseCount > 0) {
      throw new VpnSessionRegistryError(
        'PROXY_MUTATION_IN_PROGRESS',
        'VPN proxy mutation is still reading the stopped runtime snapshot.'
      );
    }
    if (this.runtimeMirrorHydrationPending || this.liveSessionId !== undefined) {
      throw new VpnSessionRegistryError('SESSION_ALREADY_LIVE', 'Vpn registry already owns a pending or active session.');
    }
    this.liveSessionId = request.sessionId;
    this.publishSnapshot(
      createVpnRuntimeSnapshot({
        state: 'AWAITING_CONSENT',
        activeRequest: request,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: false,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      }),
      'STATE_CHANGED'
    );
    return this.snapshot();
  }

  activatePending(sessionId: string, state: VpnRuntimeState = 'STARTING'): VpnStartRequest | undefined {
    if (this.snapshotValue.state !== 'AWAITING_CONSENT' || this.liveSessionId !== sessionId) {
      return undefined;
    }
    const request: VpnStartRequest | null = this.snapshotValue.activeRequest;
    if (request === null || request.sessionId !== sessionId) {
      return undefined;
    }
    this.publishSnapshot(
      createVpnRuntimeSnapshot({
        state,
        activeRequest: request,
        activeHandle: this.snapshotValue.activeHandle,
        captureConfig: this.snapshotValue.captureConfig,
        tunSnapshot: this.snapshotValue.tunSnapshot,
        notificationActive: this.snapshotValue.notificationActive,
        recoveryAttempt: this.snapshotValue.recoveryAttempt,
        scheduledRetryDelayMs: this.snapshotValue.scheduledRetryDelayMs,
        lastFailure: this.snapshotValue.lastFailure
      }),
      'STATE_CHANGED'
    );
    return cloneRequest(request);
  }

  publish(update: VpnSessionRegistryUpdate): boolean {
    const request: VpnStartRequest | null = this.snapshotValue.activeRequest;
    if (this.liveSessionId === undefined || this.liveSessionId !== update.sessionId || request === null) {
      return false;
    }
    const eventType: VpnRuntimeEventType = update.lastFailure !== undefined && update.lastFailure !== null
      ? 'FAILED'
      : update.state !== this.snapshotValue.state
        ? 'STATE_CHANGED'
        : 'SNAPSHOT';
    this.publishSnapshot(
      createVpnRuntimeSnapshot({
        state: update.state,
        activeRequest: request,
        activeHandle: update.activeHandle !== undefined ? update.activeHandle : this.snapshotValue.activeHandle,
        captureConfig: update.captureConfig !== undefined ? update.captureConfig : this.snapshotValue.captureConfig,
        tunSnapshot: update.tunSnapshot !== undefined ? update.tunSnapshot : this.snapshotValue.tunSnapshot,
        notificationActive: update.notificationActive !== undefined
          ? update.notificationActive
          : this.snapshotValue.notificationActive,
        recoveryAttempt: update.recoveryAttempt !== undefined ? update.recoveryAttempt : this.snapshotValue.recoveryAttempt,
        scheduledRetryDelayMs: update.scheduledRetryDelayMs !== undefined
          ? update.scheduledRetryDelayMs
          : this.snapshotValue.scheduledRetryDelayMs,
        lastFailure: update.lastFailure !== undefined ? update.lastFailure : this.snapshotValue.lastFailure
      }),
      eventType
    );
    return true;
  }

  hydrateRpcSnapshot(
    snapshot: VpnRuntimeSnapshot,
    context: VpnRpcClientContext | null,
    knownRequest?: VpnStartRequest
  ): boolean {
    if (requiresAuthenticatedRpcContext(snapshot.state) && context === null) {
      return false;
    }
    const currentRequest: VpnStartRequest | null = this.snapshotValue.activeRequest;
    if (knownRequest !== undefined && currentRequest !== null && !isSameRequest(currentRequest, knownRequest)) {
      return false;
    }
    this.runtimeMirrorHydrationPending = false;
    let nextRequest: VpnStartRequest | null = null;
    if (knownRequest !== undefined) {
      nextRequest = cloneRequest(knownRequest);
    } else if (currentRequest !== null && this.liveSessionId !== undefined) {
      nextRequest = cloneRequest(currentRequest);
    }

    if (snapshot.state === 'STOPPED') {
      this.liveSessionId = undefined;
      this.userStopRequestedSessionId = undefined;
      this.publishSnapshot(buildStoppedSnapshot(snapshot.lastFailure), 'STOPPED');
      return true;
    }

    if (snapshot.state === 'ERROR' && context === null && nextRequest === null) {
      this.liveSessionId = undefined;
      this.userStopRequestedSessionId = undefined;
    } else if (nextRequest !== null) {
      this.liveSessionId = nextRequest.sessionId;
    } else if (context !== null && this.liveSessionId === undefined) {
      this.liveSessionId = this.allocateAnonymousSessionId(context);
    }

    const nextSnapshot: VpnRuntimeSnapshot = createVpnRuntimeSnapshot({
      state: snapshot.state,
      activeRequest: nextRequest,
      activeHandle: snapshot.activeHandle,
      captureConfig: snapshot.captureConfig,
      tunSnapshot: snapshot.tunSnapshot,
      notificationActive: snapshot.notificationActive,
      recoveryAttempt: snapshot.recoveryAttempt,
      scheduledRetryDelayMs: snapshot.scheduledRetryDelayMs,
      lastFailure: snapshot.lastFailure
    });
    this.publishSnapshot(nextSnapshot, inferEventType(this.snapshotValue, nextSnapshot));
    return true;
  }

  hydrateBridgeState(request: VpnStartRequest, state: HydratableBridgeState): boolean {
    const currentRequest: VpnStartRequest | null = this.snapshotValue.activeRequest;
    if (currentRequest !== null && !isSameRequest(currentRequest, request)) {
      return false;
    }
    this.runtimeMirrorHydrationPending = false;
    this.liveSessionId = request.sessionId;
    this.publishSnapshot(
      buildHydratedSnapshot(state, cloneRequest(request), null),
      state === this.snapshotValue.state ? 'SNAPSHOT' : 'STATE_CHANGED'
    );
    return true;
  }

  hydrateFailure(failure: VpnFailure, request?: VpnStartRequest, clearActiveRequest: boolean = false): boolean {
    const currentRequest: VpnStartRequest | null = this.snapshotValue.activeRequest;
    const matchRequest: VpnStartRequest | null = request ?? currentRequest;
    if (currentRequest !== null && !isSameRequest(currentRequest, matchRequest)) {
      return false;
    }
    this.runtimeMirrorHydrationPending = false;
    const nextRequest: VpnStartRequest | null = clearActiveRequest
      ? null
      : request !== undefined
        ? cloneRequest(request)
        : null;
    if (nextRequest === null) {
      this.liveSessionId = undefined;
      this.userStopRequestedSessionId = undefined;
    } else {
      this.liveSessionId = nextRequest.sessionId;
    }
    this.publishSnapshot(buildHydratedSnapshot('ERROR', nextRequest, failure), 'FAILED');
    return true;
  }

  markUserStopRequested(sessionId?: string): string | undefined {
    if (this.liveSessionId === undefined) {
      return undefined;
    }
    const request: VpnStartRequest | null = this.snapshotValue.activeRequest;
    if (sessionId !== undefined && request !== null && request.sessionId !== sessionId) {
      return undefined;
    }
    this.userStopRequestedSessionId = this.liveSessionId;
    return this.liveSessionId;
  }

  isUserStopRequested(sessionId: string): boolean {
    return this.userStopRequestedSessionId === sessionId;
  }

  currentSessionId(): string | undefined {
    return this.liveSessionId;
  }

  completeStop(sessionId?: string, lastFailure: VpnFailure | null = null): boolean {
    if (this.liveSessionId === undefined) {
      return false;
    }
    if (sessionId !== undefined && this.liveSessionId !== sessionId) {
      return false;
    }
    this.runtimeMirrorHydrationPending = false;
    this.liveSessionId = undefined;
    if (this.userStopRequestedSessionId !== undefined) {
      this.userStopRequestedSessionId = undefined;
    }
    this.publishSnapshot(buildStoppedSnapshot(lastFailure), 'STOPPED');
    return true;
  }

  releaseStoppedProxyLease(): void {
    if (this.liveStoppedProxyLeaseCount <= 0) {
      return;
    }
    this.liveStoppedProxyLeaseCount -= 1;
  }

  private allocateAnonymousSessionId(context: VpnRpcClientContext): string {
    const generationLabel: string = `${context.sessionGeneration}`;
    const ordinalLabel: string = `${this.nextAnonymousSessionOrdinal}`;
    this.nextAnonymousSessionOrdinal += 1;
    return `rpc:${generationLabel}:${ordinalLabel}`;
  }

  private publishSnapshot(snapshot: VpnRuntimeSnapshot, type: VpnRuntimeEventType): void {
    this.snapshotValue = cloneSnapshot(snapshot);
    const event: VpnRuntimeEvent = createVpnRuntimeEvent(type, this.snapshotValue);
    const listeners: Array<(event: VpnRuntimeEvent) => void> = [];
    this.listeners.forEach((listener: (event: VpnRuntimeEvent) => void) => {
      listeners.push(listener);
    });
    for (let index = 0; index < listeners.length; index += 1) {
      listeners[index](createVpnRuntimeEvent(event.type, event.snapshot));
    }
  }
}

function inferEventType(previous: VpnRuntimeSnapshot, next: VpnRuntimeSnapshot): VpnRuntimeEventType {
  if (next.state === 'STOPPED') {
    return 'STOPPED';
  }
  if (next.lastFailure !== null) {
    return 'FAILED';
  }
  if (next.state !== previous.state) {
    return 'STATE_CHANGED';
  }
  return 'SNAPSHOT';
}
