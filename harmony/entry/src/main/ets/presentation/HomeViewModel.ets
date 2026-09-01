import {
  type HomeProxySelectionSummary,
  type CoreRuntimeMode,
  type OneClickVpnOperationSnapshot,
  ProfileApplication,
  type ProfileApplicationListener,
  type ProfileApplicationProfileSnapshot,
  type ProfileApplicationSnapshot,
  type VpnControllerStartResult,
  type VpnFailure,
  type VpnRuntimeSnapshot,
  type VpnRpcRuntimeModeClientPort
} from '@cmfa/shared';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  cloneHomeViewState,
  createHomeTrafficState,
  createHomeViewState,
  createProfileSummaryState,
  createRuntimeModeState,
  createSafeErrorState,
  createVpnGlobalCaptureState,
  isProfileStartEligible,
  type HomeTrafficState,
  type HomeViewState,
  type SafeErrorState,
  type RuntimeModeState
} from './PresentationModels';
import type {
  VpnTrafficMonitorReadPort,
  VpnTrafficMonitorSnapshot
} from '../vpn/VpnTrafficMonitor';
import { VpnSessionRegistry } from '../vpn/VpnSessionRegistry';

const VPN_COMMAND_LOG_DOMAIN: number = 0x0000;
const VPN_COMMAND_LOG_TAG: string = 'CMFAVpn';

function reportVpnCommandStage(stage: string): void {
  hilog.warn(VPN_COMMAND_LOG_DOMAIN, VPN_COMMAND_LOG_TAG, '%{public}s', stage);
}

function reportVpnStartResultStage(result: VpnControllerStartResult): void {
  if (result.kind === 'STARTED') {
    reportVpnCommandStage('ui.command.start.started');
    return;
  }
  if (result.kind === 'STOPPED') {
    reportVpnCommandStage('ui.command.start.other-failed');
    return;
  }
  if (result.failure.code === 'VPN_PROFILE_UNAVAILABLE') {
    reportVpnCommandStage('ui.command.start.profile-unavailable');
    return;
  }
  if (result.failure.code === 'VPN_CREATE_FAILED' ||
    result.failure.code === 'VPN_PERMISSION_DENIED' ||
    result.failure.code === 'VPN_ALREADY_ACTIVE' ||
    result.failure.code === 'VPN_CONFIG_INVALID') {
    reportVpnCommandStage('ui.command.start.controller-failed');
    return;
  }
  reportVpnCommandStage('ui.command.start.other-failed');
}

export type HomeViewListener = (state: HomeViewState) => void;

export class HomeViewModel {
  private readonly application: ProfileApplication;
  private readonly vpnRegistry: VpnSessionRegistry;
  private readonly runtimeModeClient?: VpnRpcRuntimeModeClientPort;
  private readonly trafficMonitor?: VpnTrafficMonitorReadPort;
  private readonly applicationListener: ProfileApplicationListener;
  private readonly listeners: Map<number, HomeViewListener> = new Map();
  private readonly snapshotById: Map<string, ProfileApplicationProfileSnapshot> = new Map();
  private state: HomeViewState;
  private applicationSnapshot: ProfileApplicationSnapshot;
  private vpnSnapshot: VpnRuntimeSnapshot;
  private applicationSubscriptionId: number;
  private vpnSubscriptionId: number;
  private oneClickSubscriptionId: number;
  private nextListenerId: number = 0;
  private vpnCommandPending: boolean = false;
  private disposed: boolean = false;
  private vpnCommandError?: SafeErrorState;
  private selectedProxyGroupName: string = '';
  private selectedProxyNodeName: string = '';
  private homeProxySelectionEpoch: number = 0;
  private inFlightSelectedProxySessionId?: string;
  private resolvedSelectedProxySessionId?: string;
  private runtimeModeState: RuntimeModeState = createRuntimeModeState(undefined, false, false, undefined);
  private runtimeModeEpoch: number = 0;
  private resolvedRuntimeModeSessionId?: string;
  private runtimeModePendingSessionId?: string;
  private trafficState: HomeTrafficState = createHomeTrafficState(false, false, 0, 0, 0, 0, false);
  private trafficSubscriptionId: number = 0;
  private activeTrafficSessionId?: string;

  constructor(
    application: ProfileApplication,
    vpnRegistry: VpnSessionRegistry,
    runtimeModeClient?: VpnRpcRuntimeModeClientPort,
    trafficMonitor?: VpnTrafficMonitorReadPort
  ) {
    this.application = application;
    this.vpnRegistry = vpnRegistry;
    this.runtimeModeClient = runtimeModeClient;
    this.trafficMonitor = trafficMonitor;
    this.applicationSnapshot = application.current();
    this.vpnSnapshot = vpnRegistry.snapshot();
    this.state = createState(
      this.applicationSnapshot,
      this.vpnSnapshot,
      false,
      '',
      '',
      this.snapshotById,
      undefined,
      this.runtimeModeState,
      this.trafficState
    );
    this.applicationListener = (snapshot: ProfileApplicationSnapshot): void => {
      this.applicationSnapshot = snapshot;
      this.refreshSelectedProxySummary(true);
    };
    this.applicationSubscriptionId = this.application.subscribe(this.applicationListener);
    this.vpnSubscriptionId = this.vpnRegistry.subscribe((event) => {
      this.vpnSnapshot = event.snapshot;
      this.refreshTrafficState();
      this.refreshSelectedProxySummary(false);
      this.refreshRuntimeMode(false);
    });
    this.oneClickSubscriptionId = this.application.subscribeOneClickVpnOperation((snapshot: OneClickVpnOperationSnapshot): void => {
      this.handleOneClickVpnOperation(snapshot);
    });
    if (trafficMonitor !== undefined) {
      this.trafficSubscriptionId = trafficMonitor.subscribe((snapshot: VpnTrafficMonitorSnapshot): void => {
        this.handleTrafficSnapshot(snapshot);
      });
    }
    this.handleOneClickVpnOperation(this.application.currentOneClickVpnOperation());
    this.refreshTrafficState();
    this.refreshSelectedProxySummary(false);
    this.refreshRuntimeMode(false);
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

  async requestVpnAction(): Promise<void> {
    reportVpnCommandStage('ui.command.enter');
    if (this.vpnCommandPending) {
      reportVpnCommandStage('ui.command.pending');
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
      reportVpnCommandStage('ui.command.action-unavailable');
      return;
    }
    this.vpnCommandPending = true;
    this.publishCurrent(undefined);
    try {
      if (vpnAction === 'START') {
        reportVpnCommandStage('ui.command.start.invoke');
        const startPromise: Promise<VpnControllerStartResult> = this.application.startVpnGlobalCapture();
        reportVpnCommandStage('ui.command.start.returned');
        const result: VpnControllerStartResult = await startPromise;
        reportVpnStartResultStage(result);
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

  async requestRuntimeMode(mode: CoreRuntimeMode): Promise<void> {
    const client: VpnRpcRuntimeModeClientPort | undefined = this.runtimeModeClient;
    const sessionId: string | undefined = this.activeRunningSessionId();
    if (client === undefined || sessionId === undefined || this.runtimeModeState.pending) {
      return;
    }
    const epoch: number = this.runtimeModeEpoch + 1;
    this.runtimeModeEpoch = epoch;
    this.runtimeModePendingSessionId = sessionId;
    this.runtimeModeState = createRuntimeModeState(this.runtimeModeState.mode, true, true, undefined);
    this.publishCurrent(undefined);
    try {
      const appliedMode: CoreRuntimeMode = await client.setMode(mode);
      if (!this.canPublishRuntimeMode(epoch, sessionId)) {
        return;
      }
      this.resolvedRuntimeModeSessionId = sessionId;
      this.runtimeModePendingSessionId = undefined;
      this.runtimeModeState = createRuntimeModeState(appliedMode, true, false, undefined);
    } catch (_) {
      if (!this.canPublishRuntimeMode(epoch, sessionId)) {
        return;
      }
      this.runtimeModeState = createRuntimeModeState(
        this.runtimeModeState.mode,
        true,
        false,
        createRuntimeModeError()
      );
      this.runtimeModePendingSessionId = undefined;
    }
    this.publishCurrent(undefined);
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.homeProxySelectionEpoch += 1;
    this.runtimeModeEpoch += 1;
    this.runtimeModePendingSessionId = undefined;
    this.inFlightSelectedProxySessionId = undefined;
    this.resolvedSelectedProxySessionId = undefined;
    this.application.unsubscribe(this.applicationSubscriptionId);
    this.vpnRegistry.unsubscribe(this.vpnSubscriptionId);
    this.application.unsubscribeOneClickVpnOperation(this.oneClickSubscriptionId);
    const trafficMonitor = this.trafficMonitor;
    if (trafficMonitor !== undefined && this.trafficSubscriptionId !== 0) {
      trafficMonitor.unsubscribe(this.trafficSubscriptionId);
      this.trafficSubscriptionId = 0;
    }
    this.listeners.clear();
    this.snapshotById.clear();
  }

  private publishCurrent(vpnCommandError: SafeErrorState | undefined): void {
    this.vpnCommandError = vpnCommandError ?? resolveVpnErrorState(this.vpnSnapshot);
    this.publish(createState(
      this.applicationSnapshot,
      this.vpnSnapshot,
      this.vpnCommandPending,
      this.selectedProxyGroupName,
      this.selectedProxyNodeName,
      this.snapshotById,
      this.vpnCommandError,
      this.runtimeModeState,
      this.trafficState
    ));
  }

  private refreshRuntimeMode(forceReload: boolean): void {
    const client: VpnRpcRuntimeModeClientPort | undefined = this.runtimeModeClient;
    const sessionId: string | undefined = this.activeRunningSessionId();
    if (client === undefined || sessionId === undefined) {
      this.runtimeModeEpoch += 1;
      this.resolvedRuntimeModeSessionId = undefined;
      this.runtimeModePendingSessionId = undefined;
      this.runtimeModeState = createRuntimeModeState(this.runtimeModeState.mode, false, false, undefined);
      this.publishCurrent(undefined);
      return;
    }
    if (!forceReload && (
      (this.runtimeModeState.pending && this.runtimeModePendingSessionId === sessionId) ||
      this.resolvedRuntimeModeSessionId === sessionId
    )) {
      this.runtimeModeState = createRuntimeModeState(this.runtimeModeState.mode, true, this.runtimeModeState.pending, this.runtimeModeState.error);
      this.publishCurrent(undefined);
      return;
    }
    const epoch: number = this.runtimeModeEpoch + 1;
    this.runtimeModeEpoch = epoch;
    this.runtimeModePendingSessionId = sessionId;
    this.runtimeModeState = createRuntimeModeState(this.runtimeModeState.mode, true, true, undefined);
    this.publishCurrent(undefined);
    void this.loadRuntimeMode(client, epoch, sessionId);
  }

  private async loadRuntimeMode(
    client: VpnRpcRuntimeModeClientPort,
    epoch: number,
    sessionId: string
  ): Promise<void> {
    try {
      const mode: CoreRuntimeMode = await client.queryMode();
      if (!this.canPublishRuntimeMode(epoch, sessionId)) {
        return;
      }
      this.resolvedRuntimeModeSessionId = sessionId;
      this.runtimeModePendingSessionId = undefined;
      this.runtimeModeState = createRuntimeModeState(mode, true, false, undefined);
    } catch (_) {
      if (!this.canPublishRuntimeMode(epoch, sessionId)) {
        return;
      }
      this.runtimeModeState = createRuntimeModeState(undefined, true, false, createRuntimeModeError());
      this.runtimeModePendingSessionId = undefined;
    }
    this.publishCurrent(undefined);
  }

  private activeRunningSessionId(): string | undefined {
    if (this.disposed || this.applicationSnapshot.status !== 'READY' ||
      this.vpnSnapshot.state !== 'RUNNING' || this.vpnSnapshot.activeRequest === null) {
      return undefined;
    }
    return this.vpnSnapshot.activeRequest.sessionId;
  }

  private canPublishRuntimeMode(epoch: number, sessionId: string): boolean {
    return !this.disposed &&
      this.runtimeModeEpoch === epoch &&
      this.activeRunningSessionId() === sessionId;
  }

  private refreshTrafficState(): void {
    if (this.disposed) {
      return;
    }
    if (this.vpnSnapshot.state !== 'RUNNING' && this.vpnSnapshot.state !== 'RECOVERING') {
      this.activeTrafficSessionId = undefined;
      this.trafficState = createHomeTrafficState(false, false, 0, 0, 0, 0, false);
      this.publishCurrent(undefined);
      return;
    }

    if (this.vpnSnapshot.state === 'RECOVERING') {
      const sessionId = this.vpnSnapshot.activeRequest?.sessionId;
      const sessionChanged: boolean = sessionId !== undefined &&
        this.activeTrafficSessionId !== undefined &&
        this.activeTrafficSessionId !== sessionId;
      const preservedTxBytes: number = sessionChanged ? 0 : this.trafficState.txBytes;
      const preservedRxBytes: number = sessionChanged ? 0 : this.trafficState.rxBytes;
      if (sessionId !== undefined) {
        this.activeTrafficSessionId = sessionId;
      }
      this.trafficState = createHomeTrafficState(
        true,
        false,
        preservedTxBytes,
        preservedRxBytes,
        0,
        0,
        true
      );
      this.publishCurrent(undefined);
      return;
    }

    const sessionId = this.vpnSnapshot.activeRequest?.sessionId;
    const sessionChanged: boolean = sessionId !== undefined &&
      this.activeTrafficSessionId !== undefined &&
      this.activeTrafficSessionId !== sessionId;
    const shouldReseed: boolean = !this.trafficState.visible || this.trafficState.recovering || sessionChanged;
    if (sessionId !== undefined) {
      this.activeTrafficSessionId = sessionId;
    }
    if (shouldReseed) {
      const preservedTxBytes: number = this.trafficState.recovering && !sessionChanged ? this.trafficState.txBytes : 0;
      const preservedRxBytes: number = this.trafficState.recovering && !sessionChanged ? this.trafficState.rxBytes : 0;
      this.trafficState = createHomeTrafficState(true, false, preservedTxBytes, preservedRxBytes, 0, 0, false);
      this.publishCurrent(undefined);
      return;
    }

    this.trafficState = createHomeTrafficState(
      true,
      this.trafficState.available,
      this.trafficState.txBytes,
      this.trafficState.rxBytes,
      this.trafficState.available ? this.trafficState.uploadBytesPerSecond : 0,
      this.trafficState.available ? this.trafficState.downloadBytesPerSecond : 0,
      false
    );
    this.publishCurrent(undefined);
  }

  private handleTrafficSnapshot(snapshot: VpnTrafficMonitorSnapshot): void {
    if (this.disposed || this.vpnSnapshot.state !== 'RUNNING') {
      return;
    }
    if (snapshot.available) {
      this.trafficState = createHomeTrafficState(
        true,
        true,
        snapshot.txBytes,
        snapshot.rxBytes,
        snapshot.uploadBytesPerSecond,
        snapshot.downloadBytesPerSecond,
        false
      );
    } else {
      this.trafficState = createHomeTrafficState(
        true,
        false,
        this.trafficState.txBytes,
        this.trafficState.rxBytes,
        0,
        0,
        false
      );
    }
    this.publishCurrent(undefined);
  }

  private refreshSelectedProxySummary(forceReload: boolean): void {
    if (!this.isSelectedProxySummaryEligible()) {
      this.homeProxySelectionEpoch += 1;
      this.inFlightSelectedProxySessionId = undefined;
      this.resolvedSelectedProxySessionId = undefined;
      this.selectedProxyGroupName = '';
      this.selectedProxyNodeName = '';
      this.publishCurrent(undefined);
      return;
    }

    const activeRequest = this.vpnSnapshot.activeRequest;
    if (activeRequest === null) {
      this.homeProxySelectionEpoch += 1;
      this.inFlightSelectedProxySessionId = undefined;
      this.resolvedSelectedProxySessionId = undefined;
      this.selectedProxyGroupName = '';
      this.selectedProxyNodeName = '';
      this.publishCurrent(undefined);
      return;
    }

    if (!forceReload && this.inFlightSelectedProxySessionId === activeRequest.sessionId) {
      this.publishCurrent(undefined);
      return;
    }

    if (!forceReload && this.resolvedSelectedProxySessionId === activeRequest.sessionId) {
      this.publishCurrent(undefined);
      return;
    }

    const epoch: number = this.homeProxySelectionEpoch + 1;
    this.homeProxySelectionEpoch = epoch;
    this.inFlightSelectedProxySessionId = activeRequest.sessionId;
    this.resolvedSelectedProxySessionId = undefined;
    this.selectedProxyGroupName = '';
    this.selectedProxyNodeName = '';
    this.publishCurrent(undefined);
    void this.loadSelectedProxySummary(epoch, activeRequest.sessionId);
  }

  private isSelectedProxySummaryEligible(): boolean {
    return this.applicationSnapshot.status === 'READY' &&
      this.vpnSnapshot.state === 'RUNNING' &&
      this.vpnSnapshot.activeRequest !== null;
  }

  private async loadSelectedProxySummary(epoch: number, sessionId: string): Promise<void> {
    let summary: HomeProxySelectionSummary | undefined;
    try {
      summary = await this.application.queryHomeProxySelection();
    } catch (_) {
      summary = undefined;
    }
    if (!this.canPublishSelectedProxySummary(epoch, sessionId)) {
      return;
    }
    this.inFlightSelectedProxySessionId = undefined;
    if (summary === undefined) {
      this.resolvedSelectedProxySessionId = undefined;
      this.selectedProxyGroupName = '';
      this.selectedProxyNodeName = '';
      this.publishCurrent(undefined);
      return;
    }
    this.resolvedSelectedProxySessionId = sessionId;
    this.selectedProxyGroupName = summary?.groupName ?? '';
    this.selectedProxyNodeName = summary?.nodeName ?? '';
    this.publishCurrent(undefined);
  }

  private canPublishSelectedProxySummary(epoch: number, sessionId: string): boolean {
    if (this.disposed || this.homeProxySelectionEpoch !== epoch) {
      return false;
    }
    if (this.applicationSnapshot.status !== 'READY' || this.vpnSnapshot.state !== 'RUNNING') {
      return false;
    }
    const activeRequest = this.vpnSnapshot.activeRequest;
    return activeRequest !== null && activeRequest.sessionId === sessionId;
  }

  private handleOneClickVpnOperation(snapshot: OneClickVpnOperationSnapshot): void {
    if (snapshot.stage !== 'IDLE' || snapshot.busy || snapshot.outcome !== 'SUCCEEDED') {
      return;
    }
    this.refreshSelectedProxySummary(true);
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
  vpnPending: boolean,
  selectedProxyGroupName: string,
  selectedProxyNodeName: string,
  cache: Map<string, ProfileApplicationProfileSnapshot>,
  vpnCommandError: SafeErrorState | undefined,
  runtimeMode: RuntimeModeState,
  trafficState: HomeTrafficState
): HomeViewState {
  updateProfileCache(cache, snapshot.profiles);
  const activeProfile: ProfileApplicationProfileSnapshot | undefined = snapshot.activeProfileId === undefined
    ? undefined
    : cache.get(snapshot.activeProfileId);
  const canManageProxies: boolean = snapshot.status === 'READY' &&
    isProfileStartEligible(activeProfile) &&
    (vpnSnapshot.state === 'STOPPED' || vpnSnapshot.state === 'RUNNING');

  return createHomeViewState(
    snapshot.status,
    activeProfile === undefined ? undefined : createProfileSummaryState(activeProfile),
    canManageProxies,
    selectedProxyGroupName,
    selectedProxyNodeName,
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
    trafficState,
    snapshot.error !== null ? createSafeErrorState(snapshot.error) : undefined,
    runtimeMode
  );
}

function createRuntimeModeError(): SafeErrorState {
  return createSafeRuntimeError(
    'CMFA_RUNTIME_MODE_FAILED',
    'error.runtime.mode',
    'RUNTIME_START',
    'VPN runtime mode operation failed.'
  );
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
  if (vpnSnapshot.state === 'ERROR' && vpnSnapshot.activeRequest !== null) {
    return 'STOP';
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
      'VPN global capture state is being restored.'
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

function updateProfileCache(
  cache: Map<string, ProfileApplicationProfileSnapshot>,
  profiles: ProfileApplicationProfileSnapshot[]
): void {
  cache.clear();
  for (let index: number = 0; index < profiles.length; index += 1) {
    cache.set(profiles[index].id, profiles[index]);
  }
}
