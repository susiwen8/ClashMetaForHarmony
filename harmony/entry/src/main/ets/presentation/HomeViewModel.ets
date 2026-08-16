import {
  ProfileApplication,
  type ProfileApplicationListener,
  type ProfileApplicationProfileSnapshot,
  type ProfileApplicationSnapshot,
  type VpnControllerStartResult,
  type VpnFailure,
  type VpnRuntimeSnapshot
} from '@cmfa/shared';
import {
  cloneHomeViewState,
  createHomeViewState,
  createLocalProxyState,
  createProfileSummaryState,
  createSafeErrorState,
  createVpnGlobalCaptureState,
  isProfileStartEligible,
  type HomeViewState,
  type SafeErrorState
} from './PresentationModels';
import { VpnSessionRegistry } from '../vpn/VpnSessionRegistry';
export type HomeViewListener = (state: HomeViewState) => void;

export class HomeViewModel {
  private readonly application: ProfileApplication;
  private readonly vpnRegistry: VpnSessionRegistry;
  private readonly applicationListener: ProfileApplicationListener;
  private readonly listeners: Map<number, HomeViewListener> = new Map();
  private readonly snapshotById: Map<string, ProfileApplicationProfileSnapshot> = new Map();
  private state: HomeViewState;
  private applicationSnapshot: ProfileApplicationSnapshot;
  private vpnSnapshot: VpnRuntimeSnapshot;
  private applicationSubscriptionId: number;
  private vpnSubscriptionId: number;
  private nextListenerId: number = 0;
  private localCommandPending: boolean = false;
  private vpnCommandPending: boolean = false;
  private disposed: boolean = false;
  private vpnCommandError?: SafeErrorState;

  constructor(application: ProfileApplication, vpnRegistry: VpnSessionRegistry) {
    this.application = application;
    this.vpnRegistry = vpnRegistry;
    this.applicationSnapshot = application.current();
    this.vpnSnapshot = vpnRegistry.snapshot();
    this.state = createState(
      this.applicationSnapshot,
      this.vpnSnapshot,
      false,
      false,
      this.snapshotById,
      undefined
    );
    this.applicationListener = (snapshot: ProfileApplicationSnapshot): void => {
      this.applicationSnapshot = snapshot;
      this.publishCurrent(undefined);
    };
    this.applicationSubscriptionId = this.application.subscribe(this.applicationListener);
    this.vpnSubscriptionId = this.vpnRegistry.subscribe((event) => {
      this.vpnSnapshot = event.snapshot;
      this.publishCurrent(undefined);
    });
  }

  current(): HomeViewState {
    return cloneHomeViewState(this.state);
  }

  subscribe(listener: HomeViewListener): number {
    this.nextListenerId += 1;
    this.listeners.set(this.nextListenerId, listener);
    return this.nextListenerId;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  async requestPrimaryAction(): Promise<void> {
    await this.requestLocalAction();
  }

  async requestLocalAction(): Promise<void> {
    if (this.localCommandPending || this.vpnCommandPending) {
      return;
    }
    const localAction: 'DISABLED' | 'START' | 'STOP' | 'BUSY' = resolveLocalAction(
      this.applicationSnapshot,
      this.vpnSnapshot,
      false,
      this.snapshotById
    );
    if (localAction !== 'START' && localAction !== 'STOP') {
      return;
    }
    this.localCommandPending = true;
    this.publishCurrent(undefined);
    try {
      if (localAction === 'START') {
        await this.application.startLocal();
      } else {
        await this.application.stopLocal();
      }
    } finally {
      this.localCommandPending = false;
      this.publishCurrent(undefined);
    }
  }

  async requestVpnAction(): Promise<void> {
    if (this.localCommandPending || this.vpnCommandPending) {
      return;
    }
    this.vpnCommandError = undefined;
    const vpnAction: 'DISABLED' | 'START' | 'STOP' | 'BUSY' = resolveVpnAction(
      this.applicationSnapshot,
      this.vpnSnapshot,
      false,
      this.snapshotById
    );
    if (vpnAction !== 'START' && vpnAction !== 'STOP') {
      return;
    }
    this.vpnCommandPending = true;
    this.publishCurrent(undefined);
    try {
      if (vpnAction === 'START') {
        const result: VpnControllerStartResult = await this.application.startVpnGlobalCapture();
        if (result.kind !== 'STARTED') {
          this.vpnCommandError = resolveVpnStartCommandError(result);
          this.publishCurrent(this.vpnCommandError);
          return;
        }
      } else {
        await this.application.stopVpnGlobalCapture();
      }
    } finally {
      this.vpnCommandPending = false;
      this.publishCurrent(this.vpnCommandError);
    }
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.application.unsubscribe(this.applicationSubscriptionId);
    this.vpnRegistry.unsubscribe(this.vpnSubscriptionId);
    this.listeners.clear();
    this.snapshotById.clear();
  }

  private publishCurrent(vpnCommandError: SafeErrorState | undefined): void {
    this.vpnCommandError = vpnCommandError ?? resolveVpnErrorState(this.vpnSnapshot);
    this.publish(createState(
      this.applicationSnapshot,
      this.vpnSnapshot,
      this.localCommandPending,
      this.vpnCommandPending,
      this.snapshotById,
      this.vpnCommandError
    ));
  }

  private publish(state: HomeViewState): void {
    this.state = cloneHomeViewState(state);
    if (this.listeners.size === 0) {
      return;
    }
    const listeners: HomeViewListener[] = [];
    this.listeners.forEach((listener: HomeViewListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneHomeViewState(this.state));
    }
  }
}

function createState(
  snapshot: ProfileApplicationSnapshot,
  vpnSnapshot: VpnRuntimeSnapshot,
  localPending: boolean,
  vpnPending: boolean,
  cache: Map<string, ProfileApplicationProfileSnapshot>,
  vpnCommandError: SafeErrorState | undefined
): HomeViewState {
  updateProfileCache(cache, snapshot.profiles);
  const activeProfile: ProfileApplicationProfileSnapshot | undefined = snapshot.activeProfileId === undefined
    ? undefined
    : cache.get(snapshot.activeProfileId);
  const localError: SafeErrorState | undefined = snapshot.runtime.lastError !== null
    ? createSafeErrorState(snapshot.runtime.lastError)
    : undefined;
  const localHttpAddress: string | undefined = snapshot.runtime.latest.httpAddress.trim().length > 0
    ? snapshot.runtime.latest.httpAddress
    : undefined;
  const localSocksAddress: string | undefined = snapshot.runtime.latest.socksAddress.trim().length > 0
    ? snapshot.runtime.latest.socksAddress
    : undefined;

  return createHomeViewState(
    snapshot.status,
    activeProfile === undefined ? undefined : createProfileSummaryState(activeProfile),
    createLocalProxyState(
      snapshot.runtime.state,
      resolveLocalAction(snapshot, vpnSnapshot, localPending, cache),
      localHttpAddress,
      localSocksAddress,
      localError
    ),
    createVpnGlobalCaptureState(
      vpnSnapshot.state,
      resolveVpnAction(snapshot, vpnSnapshot, vpnPending, cache),
      vpnSnapshot.captureConfig?.ipv4 === true,
      vpnSnapshot.captureConfig?.ipv6 === true,
      vpnSnapshot.captureConfig?.dnsServers ?? [],
      vpnSnapshot.captureConfig?.mtu,
      vpnSnapshot.notificationActive,
      vpnSnapshot.recoveryAttempt,
      vpnSnapshot.scheduledRetryDelayMs === null ? undefined : vpnSnapshot.scheduledRetryDelayMs,
      vpnCommandError
    ),
    snapshot.error !== null ? createSafeErrorState(snapshot.error) : undefined
  );
}

function resolveLocalAction(
  snapshot: ProfileApplicationSnapshot,
  vpnSnapshot: VpnRuntimeSnapshot,
  pending: boolean,
  cache: Map<string, ProfileApplicationProfileSnapshot>
): 'DISABLED' | 'START' | 'STOP' | 'BUSY' {
  if (snapshot.status !== 'READY') {
    return 'DISABLED';
  }
  if (pending || snapshot.runtime.state === 'STARTING' || snapshot.runtime.state === 'STOPPING') {
    return 'BUSY';
  }
  if (snapshot.runtime.state === 'RUNNING') {
    return 'STOP';
  }
  if (snapshot.runtime.state === 'ERROR') {
    return 'DISABLED';
  }
  if (isVpnBlockingLocalStart(vpnSnapshot.state)) {
    return 'DISABLED';
  }
  const activeProfile: ProfileApplicationProfileSnapshot | undefined = snapshot.activeProfileId === undefined
    ? undefined
    : cache.get(snapshot.activeProfileId);
  if (!isProfileStartEligible(activeProfile)) {
    return 'DISABLED';
  }
  return 'START';
}

function resolveVpnAction(
  snapshot: ProfileApplicationSnapshot,
  vpnSnapshot: VpnRuntimeSnapshot,
  pending: boolean,
  cache: Map<string, ProfileApplicationProfileSnapshot>
): 'DISABLED' | 'START' | 'STOP' | 'BUSY' {
  if (snapshot.status !== 'READY') {
    return 'DISABLED';
  }
  if (pending ||
    vpnSnapshot.state === 'AWAITING_CONSENT' ||
    vpnSnapshot.state === 'STARTING' ||
    vpnSnapshot.state === 'RECOVERING' ||
    vpnSnapshot.state === 'STOPPING') {
    return 'BUSY';
  }
  if (vpnSnapshot.state === 'RUNNING') {
    return 'STOP';
  }
  if (snapshot.runtime.state === 'STARTING' || snapshot.runtime.state === 'STOPPING') {
    return 'BUSY';
  }
  const activeProfile: ProfileApplicationProfileSnapshot | undefined = snapshot.activeProfileId === undefined
    ? undefined
    : cache.get(snapshot.activeProfileId);
  if (!isProfileStartEligible(activeProfile)) {
    return 'DISABLED';
  }
  return 'START';
}

function resolveVpnErrorState(snapshot: VpnRuntimeSnapshot): SafeErrorState | undefined {
  if (snapshot.lastFailure !== null) {
    return resolveVpnFailureError(snapshot.lastFailure);
  }
  if (snapshot.state === 'RECOVERING') {
    return createSafeRuntimeError(
      'CMFA_VPN_RECOVERING',
      'error.vpn.recovering',
      'RUNTIME_START',
      'VPN global capture is recovering after a network change.'
    );
  }
  return undefined;
}

function resolveVpnStartCommandError(result: VpnControllerStartResult): SafeErrorState {
  if (result.kind === 'FAILED' || result.kind === 'REJECTED') {
    return resolveVpnFailureError(result.failure);
  }
  return createSafeRuntimeError(
    'CMFA_VPN_START_FAILED',
    'error.vpn.start_failed',
    'RUNTIME_START',
    'VPN global capture could not start with the selected profile.'
  );
}

function resolveVpnFailureError(failure: VpnFailure): SafeErrorState {
  switch (failure.code) {
    case 'VPN_PERMISSION_DENIED':
      return createSafeRuntimeError(
        'CMFA_VPN_PERMISSION_DENIED',
        'error.vpn.permission_denied',
        'RUNTIME_START',
        'VPN global capture permission was denied.'
      );
    case 'VPN_ALREADY_ACTIVE':
      return createSafeRuntimeError(
        'CMFA_VPN_ALREADY_ACTIVE',
        'error.vpn.already_active',
        'RUNTIME_START',
        'VPN global capture is already active.'
      );
    case 'VPN_SYSTEM_REVOKED':
      return createSafeRuntimeError(
        'CMFA_VPN_SYSTEM_REVOKED',
        'error.vpn.system_revoked',
        'RUNTIME_STOP',
        'VPN global capture was revoked or replaced by the system.'
      );
    case 'VPN_BACKGROUND_TASK_FAILED':
      return createSafeRuntimeError(
        'CMFA_VPN_BACKGROUND_TASK_FAILED',
        'error.vpn.background_task_failed',
        'RUNTIME_START',
        'VPN global capture could not keep its background task active.'
      );
    case 'VPN_STOP_FAILED':
      return createSafeRuntimeError(
        'CMFA_VPN_STOP_FAILED',
        'error.vpn.stop_failed',
        'RUNTIME_STOP',
        'VPN global capture could not stop cleanly.'
      );
    case 'VPN_PROFILE_UNAVAILABLE':
      return createSafeRuntimeError(
        'CMFA_VPN_PROFILE_UNAVAILABLE',
        'error.vpn.profile_unavailable',
        'RUNTIME_START',
        'The selected profile does not have a committed version for VPN global capture.'
      );
    case 'VPN_LOCAL_STOP_REQUIRED':
      return createSafeRuntimeError(
        'CMFA_VPN_REQUIRES_LOCAL_STOP',
        'error.vpn.requires_local_stop',
        'RUNTIME_STOP',
        'Stop the local proxy before starting VPN global capture.'
      );
    default:
      return createSafeRuntimeError(
        `CMFA_${failure.code}`,
        'error.vpn.start_failed',
        'RUNTIME_START',
        'VPN global capture could not start with the selected profile.'
      );
  }
}

function createSafeRuntimeError(
  code: string,
  userMessageResource: string,
  stage: 'RUNTIME_START' | 'RUNTIME_STOP',
  technicalDetail: string
): SafeErrorState {
  return createSafeErrorState({
    code,
    stage,
    userMessageResource,
    technicalDetail,
    timestamp: '2026-08-16T00:00:00.000Z',
    retryable: stage === 'RUNTIME_START'
  })!;
}

function isVpnBlockingLocalStart(state: 'STOPPED' | 'AWAITING_CONSENT' | 'STARTING' | 'RUNNING' | 'RECOVERING' | 'STOPPING' | 'ERROR'): boolean {
  return state === 'AWAITING_CONSENT' ||
    state === 'STARTING' ||
    state === 'RUNNING' ||
    state === 'RECOVERING' ||
    state === 'STOPPING';
}

function updateProfileCache(
  cache: Map<string, ProfileApplicationProfileSnapshot>,
  profiles: ProfileApplicationProfileSnapshot[]
): void {
  cache.clear();
  for (let index: number = 0; index < profiles.length; index += 1) {
    cache.set(profiles[index].id, profiles[index]);
  }
}
