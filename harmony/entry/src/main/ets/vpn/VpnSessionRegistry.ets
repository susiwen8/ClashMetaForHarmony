import {
  createVpnRuntimeEvent,
  createVpnRuntimeSnapshot,
  type TunHandle,
  type TunRuntimeSnapshot,
  type VpnActiveHandleSummary,
  type VpnCaptureConfig,
  type VpnFailure,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot,
  type VpnRuntimeState,
  type VpnRuntimeEventType,
  type VpnStartRequest
} from '@cmfa/shared';

export type VpnSessionRegistryErrorCode = 'SESSION_ALREADY_LIVE';

export class VpnSessionRegistryError extends Error {
  code: VpnSessionRegistryErrorCode;

  constructor(code: VpnSessionRegistryErrorCode, detail: string) {
    super(detail);
    this.code = code;
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

export class VpnSessionRegistry {
  private readonly listeners: Map<number, (event: VpnRuntimeEvent) => void> = new Map();
  private nextListenerId: number = 1;
  private snapshotValue: VpnRuntimeSnapshot = buildStoppedSnapshot();
  private userStopRequestedSessionId?: string;

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

  beginPending(request: VpnStartRequest): VpnRuntimeSnapshot {
    if (this.snapshotValue.activeRequest !== null) {
      throw new VpnSessionRegistryError('SESSION_ALREADY_LIVE', 'Vpn registry already owns a pending or active session.');
    }
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
    if (this.snapshotValue.state !== 'AWAITING_CONSENT') {
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
    return {
      profileId: request.profileId,
      versionId: request.versionId,
      sessionId: request.sessionId
    };
  }

  publish(update: VpnSessionRegistryUpdate): boolean {
    const request: VpnStartRequest | null = this.snapshotValue.activeRequest;
    if (request === null || request.sessionId !== update.sessionId) {
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

  markUserStopRequested(sessionId?: string): string | undefined {
    const request: VpnStartRequest | null = this.snapshotValue.activeRequest;
    if (request === null) {
      return undefined;
    }
    if (sessionId !== undefined && request.sessionId !== sessionId) {
      return undefined;
    }
    this.userStopRequestedSessionId = request.sessionId;
    return request.sessionId;
  }

  isUserStopRequested(sessionId: string): boolean {
    return this.userStopRequestedSessionId === sessionId;
  }

  currentSessionId(): string | undefined {
    const request: VpnStartRequest | null = this.snapshotValue.activeRequest;
    return request === null ? undefined : request.sessionId;
  }

  completeStop(sessionId: string, lastFailure: VpnFailure | null = null): boolean {
    const request: VpnStartRequest | null = this.snapshotValue.activeRequest;
    if (request === null || request.sessionId !== sessionId) {
      return false;
    }
    if (this.userStopRequestedSessionId === sessionId) {
      this.userStopRequestedSessionId = undefined;
    }
    this.publishSnapshot(buildStoppedSnapshot(lastFailure), 'STOPPED');
    return true;
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
