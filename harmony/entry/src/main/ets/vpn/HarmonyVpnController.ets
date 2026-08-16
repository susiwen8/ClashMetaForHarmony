import type { Want } from '@kit.AbilityKit';
import {
  createVpnFailure,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  type VpnControllerFailedResult,
  type VpnControllerPort,
  type VpnControllerRejectedResult,
  type VpnControllerStartResult,
  type VpnControllerStopResult,
  type VpnFailure,
  type VpnRuntimeSnapshot,
  type VpnStartRequest
} from '@cmfa/shared';
import { VpnSessionRegistry, VpnSessionRegistryError } from './VpnSessionRegistry';

const BUNDLE_NAME: string = 'com.github.kr328.clash.harmony';
const ABILITY_NAME: string = 'CmfaVpnExtensionAbility';
const CONSENT_DENIED_ERROR_CODE: number = 2203001;

export interface VpnExtensionAbilityApi {
  startVpnExtensionAbility(want: Want): Promise<void>;
  stopVpnExtensionAbility(): Promise<void>;
}

interface BusinessErrorShape {
  code?: number;
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

interface PendingStopCompletion {
  sessionId: string;
  promise: Promise<VpnControllerStopResult>;
  resolve(result: VpnControllerStopResult): void;
}

class PendingStopCompletionRecord implements PendingStopCompletion {
  readonly sessionId: string;
  readonly promise: Promise<VpnControllerStopResult>;
  private readonly resolveRef: (result: VpnControllerStopResult) => void;

  constructor(sessionId: string, promise: Promise<VpnControllerStopResult>, resolveRef: (result: VpnControllerStopResult) => void) {
    this.sessionId = sessionId;
    this.promise = promise;
    this.resolveRef = resolveRef;
  }

  resolve(result: VpnControllerStopResult): void {
    this.resolveRef(result);
  }
}

export class HarmonyVpnController implements VpnControllerPort {
  private readonly registry: VpnSessionRegistry;
  private readonly vpnExtension: VpnExtensionAbilityApi;
  private stopRequestInFlight?: Promise<void>;
  private pendingStopCompletion?: PendingStopCompletion;

  constructor(registry: VpnSessionRegistry, vpnExtension: VpnExtensionAbilityApi) {
    this.registry = registry;
    this.vpnExtension = vpnExtension;
  }

  async start(profileId: string, versionId: string, sessionId: string): Promise<VpnControllerStartResult> {
    let request: VpnStartRequest;
    try {
      request = createVpnStartRequest(profileId, versionId, sessionId);
    } catch (_) {
      const failure: VpnFailure = createInvalidStartFailure();
      return createRejectedResult(this.registry.snapshot(), failure);
    }

    try {
      this.registry.beginPending(request);
    } catch (error) {
      if (error instanceof VpnSessionRegistryError && error.code === 'SESSION_ALREADY_LIVE') {
        return createRejectedResult(this.registry.snapshot(), createAlreadyActiveFailure());
      }
      return createRejectedResult(this.registry.snapshot(), createStartFailure());
    }

    try {
      await this.vpnExtension.startVpnExtensionAbility(createStartWant(request));
      this.pendingStopCompletion = undefined;
      this.stopRequestInFlight = undefined;
      return createStartedResult(this.registry.snapshot());
    } catch (error) {
      const failure: VpnFailure = this.mapStartFailure(error);
      this.registry.completeStop(request.sessionId, failure);
      return createRejectedResult(this.registry.snapshot(), failure);
    }
  }

  async stop(sessionId?: string): Promise<VpnControllerStopResult> {
    const targetSessionId: string | undefined = this.registry.markUserStopRequested(sessionId);
    if (targetSessionId === undefined) {
      return createStoppedResult(this.registry.snapshot());
    }

    this.registry.publish({
      sessionId: targetSessionId,
      state: 'STOPPING'
    });

    const existingCompletion: PendingStopCompletion | undefined = this.pendingStopCompletion;
    if (existingCompletion !== undefined && existingCompletion.sessionId === targetSessionId) {
      return await existingCompletion.promise;
    }
    const completion: PendingStopCompletion = this.createPendingStopCompletion(targetSessionId);
    this.pendingStopCompletion = completion;
    if (this.stopRequestInFlight === undefined) {
      this.stopRequestInFlight = this.issuePlatformStopRequest(targetSessionId, completion);
    }
    return await completion.promise;
  }

  snapshot(): VpnRuntimeSnapshot {
    return this.registry.snapshot();
  }

  subscribe(listener: (event: import('@cmfa/shared').VpnRuntimeEvent) => void): number {
    return this.registry.subscribe(listener);
  }

  isUserStopRequested(sessionId: string): boolean {
    return this.registry.isUserStopRequested(sessionId);
  }

  handleExtensionDestroyed(): void {
    const sessionId: string | undefined = this.registry.currentSessionId();
    if (sessionId === undefined) {
      return;
    }
    const currentFailure: VpnFailure | null = this.registry.snapshot().lastFailure;
    const pendingCompletion: PendingStopCompletion | undefined =
      this.pendingStopCompletion?.sessionId === sessionId ? this.pendingStopCompletion : undefined;
    if (this.registry.isUserStopRequested(sessionId)) {
      this.registry.completeStop(sessionId, currentFailure);
      if (pendingCompletion !== undefined) {
        this.pendingStopCompletion = undefined;
        pendingCompletion.resolve(createStoppedResult(this.registry.snapshot()));
      }
    } else {
      const failure: VpnFailure = createSystemRevokedFailure();
      this.registry.completeStop(sessionId, failure);
    }
  }

  private mapStartFailure(error: Object | Error | undefined | null): VpnFailure {
    if (isBusinessErrorWithCode(error, CONSENT_DENIED_ERROR_CODE)) {
      return createConsentDeniedFailure();
    }
    return createStartFailure();
  }

  private createPendingStopCompletion(sessionId: string): PendingStopCompletion {
    let resolveRef: ((result: VpnControllerStopResult) => void) | undefined = undefined;
    const promise: Promise<VpnControllerStopResult> = new Promise<VpnControllerStopResult>((resolve) => {
      resolveRef = resolve;
    });
    return new PendingStopCompletionRecord(sessionId, promise, (result: VpnControllerStopResult) => {
      resolveRef?.(result);
    });
  }

  private issuePlatformStopRequest(sessionId: string, completion: PendingStopCompletion): Promise<void> {
    return this.vpnExtension.stopVpnExtensionAbility()
      .then(() => {
        if (this.pendingStopCompletion !== completion) {
          return;
        }
      })
      .catch((_error: Error) => {
        if (this.pendingStopCompletion !== completion) {
          return;
        }
        const failure: VpnFailure = createStopFailure();
        this.registry.publish({
          sessionId,
          state: 'ERROR',
          lastFailure: failure
        });
        this.pendingStopCompletion = undefined;
        completion.resolve(createFailedStopResult(this.registry.snapshot(), failure));
      })
      .finally(() => {
        if (this.stopRequestInFlight !== undefined) {
          this.stopRequestInFlight = undefined;
        }
      });
  }
}
