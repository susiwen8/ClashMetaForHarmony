import type { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import common from '@ohos.app.ability.common';
import { CoreTunRuntime, createCoreService, type CoreTunRuntimeConfig } from '@cmfa/core';
import {
  HarmonyVpnRpcPlatformFactory,
  PlatformFactory,
  createHarmonyRuntimeLogStore,
  type HarmonyVpnRpcPlatformBundle,
  type PlatformGraph
} from '@cmfa/platform';
import {
  buildVpnRpcCatalogFromCore,
  createProxyRejectedError,
  createProxyRejectedResult,
  createProxyRuntimeIdentity,
  deriveVpnRpcSocketAddress,
  encodeVpnRpcLowercaseHex,
  VpnRpcServer,
  VpnRpcServerSession,
  VpnRuntimeCoordinator,
  createVpnStartRequest,
  createVpnRuntimeSnapshot,
  createTunRuntimeSnapshot,
  createVpnCaptureConfig,
  createVpnCounters,
  createVpnFailure,
  type BoundedDelaySchedulerPort,
  type CancelableDelayTask,
  type ClockPort,
  type CommittedProfileResolverPort,
  type ContinuousNotificationPort,
  type CoreProxyDelaySnapshot,
  type CoreProxyGroupList,
  type CoreProxyGroupResult,
  type CoreProxyPort,
  type CoreProxyQueryContext,
  type CoreProxySelectionApplied,
  type CoreRuntimeMode,
  type CoreService,
  type NetworkRecoveryPort,
  type Profile,
  type ProxyDelayResult,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyRejectedResult,
  type ProxyRuntimeIdentity,
  type ProxySelectionResult,
  type TunHandle,
  type TunRuntimeEvent,
  type TunRuntimePort,
  type TunRuntimeSnapshot,
  type TunStartOptions,
  type VpnCaptureConfig,
  type VpnControllerFailedResult,
  type VpnControllerPort,
  type VpnControllerRejectedResult,
  type VpnControllerStartResult,
  type VpnControllerStopResult,
  type VpnFailure,
  type VpnPlatformSessionPort,
  VpnProxyCommandBus,
  VpnProxyRuntimeHandler,
  type VpnProxyRuntimeLifecyclePort,
  type VpnRuntimeCoordinatorDependencies,
  type VpnRuntimeEvent,
  type VpnRpcCryptoPort,
  type VpnRpcCancelableTaskPort,
  type VpnRpcRandomPort,
  type VpnRpcRuntimeDispatchPort,
  type VpnRpcSchedulerPort,
  type VpnRpcServerPort,
  type VpnRpcServerSessionPort,
  type VpnRpcSocketServerPort,
  type VpnStartRequest
} from '@cmfa/shared';
import { defaultSdkApiVersionResolver, HarmonyVpnConnectionApi } from './VpnConnectionApi';
import { HarmonyVpnConnectionDriver } from './HarmonyVpnConnectionDriver';
import { VpnEvidenceJournal, type VpnEvidenceJournalPort } from './VpnEvidenceJournal';
import { VpnSessionRegistry } from './VpnSessionRegistry';
import { CoreRuntimeLogCollector, CoreServiceLogSubscriptionAdapter } from './CoreRuntimeLogCollector';

const EXACT_CAPTURE_CONFIG: VpnCaptureConfig = createVpnCaptureConfig({
  addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
  routes: ['0.0.0.0/0', '::/0'],
  dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
  mtu: 1500,
  ipv4: true,
  ipv6: true,
  isBlocking: false,
  blockedApplications: ['com.github.kr328.clash.harmony'],
  trustedApplications: []
});

const VPN_STAGE_LOG_DOMAIN: number = 0x0000;
const VPN_STAGE_LOG_TAG: string = 'CMFAVpn';
const EVIDENCE_RUN_ID_KEY: string = 'cmfa.phase1.runId';
const UUID_PATTERN: RegExp = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

function reportVpnStartStage(stage: string): void {
  hilog.info(VPN_STAGE_LOG_DOMAIN, VPN_STAGE_LOG_TAG, '%{public}s', stage);
}

class CoreProxyServiceAdapter implements CoreProxyPort {
  private readonly coreService: CoreService;

  constructor(coreService: CoreService) {
    this.coreService = coreService;
  }

  async loadConfiguration(path: string): Promise<void> {
    await this.coreService.loadConfiguration(path);
  }

  async queryProxyGroups(context: CoreProxyQueryContext, selectableOnly: boolean): Promise<CoreProxyGroupList> {
    return await this.coreService.queryProxyGroups(context, selectableOnly);
  }

  async queryProxyGroup(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyGroupResult> {
    return await this.coreService.queryProxyGroup(context, groupName);
  }

  async selectProxy(context: CoreProxyQueryContext, groupName: string, memberName: string): Promise<CoreProxySelectionApplied> {
    return await this.coreService.selectProxy(context, groupName, memberName);
  }

  async startProxyDelayTest(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyDelaySnapshot> {
    return await this.coreService.startProxyDelayTest(context, groupName);
  }

  async readProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot> {
    return await this.coreService.readProxyDelayTest(jobId);
  }

  async cancelProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot> {
    return await this.coreService.cancelProxyDelayTest(jobId);
  }
}

interface PlatformFactoryLike {
  create(): Promise<PlatformGraph>;
  createNetworkRecoveryPort(): Promise<NetworkRecoveryPort>;
  createContinuousNotificationPort(): ContinuousNotificationPort;
}

export interface VpnExtensionCompositionRunner {
  start(want: Want): Promise<void>;
  stopForDestroy(): Promise<void>;
  recordUnexpectedFailure(failure: VpnFailure): Promise<void>;
}

export interface VpnExtensionCompositionDependencies {
  registry?: VpnSessionRegistry;
  commandBus?: VpnProxyCommandBus;
  createPlatformFactory?: (context: common.VpnExtensionContext | undefined) => PlatformFactoryLike;
  createPlatformPort?: (sessionId: string) => VpnPlatformSessionPort;
  createTunRuntime?: (configPath: string) => TunRuntimePort;
  createCoreService?: () => CoreService;
  createProxyLifecycle?: (
    graph: PlatformGraph,
    commandBus: VpnProxyCommandBus
  ) => VpnProxyRuntimeLifecyclePort;
  createCoordinator?: (dependencies: VpnRuntimeCoordinatorDependencies) => VpnControllerPort;
  createClock?: () => ClockPort;
  createScheduler?: () => BoundedDelaySchedulerPort;
  createEvidenceJournal?: () => VpnEvidenceJournalPort;
  createVpnRpcPlatformBundle?: () => HarmonyVpnRpcPlatformBundle;
  createVpnRpcServerSession?: (
    crypto: VpnRpcCryptoPort,
    random: VpnRpcRandomPort,
    scheduler: VpnRpcSchedulerPort,
    socketServer: VpnRpcSocketServerPort,
    address: string,
    handler: (request: import('@cmfa/shared').VpnRpcBody) => Promise<import('@cmfa/shared').VpnRpcBody>
  ) => VpnRpcServerSessionPort;
  createVpnRpcServer?: (
    session: VpnRpcServerSessionPort,
    runtime: VpnRpcRuntimeDispatchPort,
    scheduler: VpnRpcSchedulerPort,
    random: VpnRpcRandomPort,
    serverInstance: string
  ) => VpnRpcServerPort;
}

class CompositionClock implements ClockPort {
  nowMs(): number {
    return Date.now();
  }
}

class TimeoutDelayTask implements CancelableDelayTask {
  private readonly timerId: number;

  constructor(timerId: number) {
    this.timerId = timerId;
  }

  cancel(): void {
    clearTimeout(this.timerId);
  }
}

class TimeoutDelayScheduler implements BoundedDelaySchedulerPort {
  schedule(delayMs: number, runner: () => Promise<void>): CancelableDelayTask {
    const timerId: number = setTimeout(() => {
      void runner();
    }, delayMs);
    return new TimeoutDelayTask(timerId);
  }
}

class VpnRpcCancelableTaskAdapter implements VpnRpcCancelableTaskPort {
  private readonly task: CancelableDelayTask;

  constructor(task: CancelableDelayTask) {
    this.task = task;
  }

  cancel(): void {
    this.task.cancel();
  }
}

class VpnRpcSchedulerAdapter implements VpnRpcSchedulerPort {
  private readonly scheduler: BoundedDelaySchedulerPort;

  constructor(scheduler: BoundedDelaySchedulerPort) {
    this.scheduler = scheduler;
  }

  schedule(delayMs: number, runner: () => Promise<void>): VpnRpcCancelableTaskPort {
    return new VpnRpcCancelableTaskAdapter(this.scheduler.schedule(delayMs, runner));
  }
}

const RPC_SERVER_INSTANCE_BYTES: number = 16;
const HASH64_PATTERN: RegExp = /^[0-9a-f]{64}$/u;

interface VpnRpcCatalogSeed {
  profileHash: string;
  revisionHash: string;
  sessionHash: string;
}

interface VpnRpcRuntimeEventSnapshot {
  state: 'STARTING' | 'RUNNING' | 'RECOVERING' | 'STOPPING' | 'STOPPED' | 'ERROR';
  snapshot: import('@cmfa/shared').VpnRuntimeSnapshot;
}

class CoreProxyQueryContextValue implements CoreProxyQueryContext {
  profileHash: string;
  revisionHash: string;
  sessionHash: string | null;
  generation: number;

  constructor(profileHash: string, revisionHash: string, sessionHash: string, generation: number) {
    this.profileHash = profileHash;
    this.revisionHash = revisionHash;
    this.sessionHash = sessionHash;
    this.generation = generation;
  }
}

class VpnRpcRuntimeDispatchRecord implements VpnRpcRuntimeDispatchPort {
  private readonly commandBus: VpnProxyCommandBus;
  private readonly coreService: CoreService;
  private readonly now: () => string;
  private readonly resolveCoordinator: () => VpnControllerPort | undefined;
  private readonly onStopped: (result: VpnControllerStopResult) => void;
  private readonly request: VpnStartRequest;
  private readonly catalogValue: import('@cmfa/shared').VpnOpaqueCatalog;
  private lastSnapshot: import('@cmfa/shared').VpnRuntimeSnapshot;

  constructor(
    commandBus: VpnProxyCommandBus,
    coreService: CoreService,
    now: () => string,
    resolveCoordinator: () => VpnControllerPort | undefined,
    onStopped: (result: VpnControllerStopResult) => void,
    request: VpnStartRequest,
    catalog: import('@cmfa/shared').VpnOpaqueCatalog,
    initialSnapshot: import('@cmfa/shared').VpnRuntimeSnapshot
  ) {
    this.commandBus = commandBus;
    this.coreService = coreService;
    this.now = now;
    this.resolveCoordinator = resolveCoordinator;
    this.onStopped = onStopped;
    this.request = request;
    this.catalogValue = catalog;
    this.lastSnapshot = cloneRuntimeSnapshot(initialSnapshot);
  }

  snapshot(): import('@cmfa/shared').VpnRuntimeSnapshot {
    const coordinator: VpnControllerPort | undefined = this.resolveCoordinator();
    if (coordinator === undefined) {
      return cloneRuntimeSnapshot(this.lastSnapshot);
    }
    const snapshot = coordinator.snapshot();
    if (snapshot.activeRequest === null && snapshot.state === 'STOPPED' && this.lastSnapshot.activeRequest !== null) {
      return cloneRuntimeSnapshot(this.lastSnapshot);
    }
    this.lastSnapshot = cloneRuntimeSnapshot(snapshot);
    return cloneRuntimeSnapshot(snapshot);
  }

  catalog(): import('@cmfa/shared').VpnOpaqueCatalog {
    const snapshot = this.snapshot();
    if (!this.matchesCurrentRequest(snapshot.activeRequest)) {
      throw new Error('VPN RPC catalog unavailable.');
    }
    return this.catalogValue;
  }

  queryGroups(command: import('@cmfa/shared').VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult> {
    if (!this.matchesCurrentIdentity(command.identity)) {
      return Promise.resolve(this.createSessionChangedResult());
    }
    if (!this.isRuntimeReadyForCommands()) {
      return Promise.resolve(this.createRuntimeNotReadyResult());
    }
    return this.commandBus.submitQueryGroups(command);
  }

  queryGroup(command: import('@cmfa/shared').VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult> {
    if (!this.matchesCurrentIdentity(command.identity)) {
      return Promise.resolve(this.createSessionChangedResult());
    }
    if (!this.isRuntimeReadyForCommands()) {
      return Promise.resolve(this.createRuntimeNotReadyResult());
    }
    return this.commandBus.submitQueryGroup(command);
  }

  select(command: import('@cmfa/shared').VpnProxySelectCommand): Promise<ProxySelectionResult> {
    if (!this.matchesCurrentIdentity(command.identity)) {
      return Promise.resolve(this.createSessionChangedResult());
    }
    if (!this.isRuntimeReadyForCommands()) {
      return Promise.resolve(this.createRuntimeNotReadyResult());
    }
    return this.commandBus.submitSelect(command);
  }

  startDelay(command: import('@cmfa/shared').VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> {
    if (!this.matchesCurrentIdentity(command.identity)) {
      return Promise.resolve(this.createSessionChangedResult());
    }
    if (!this.isRuntimeReadyForCommands()) {
      return Promise.resolve(this.createRuntimeNotReadyResult());
    }
    return this.commandBus.submitStartDelayTest(command);
  }

  readDelay(command: import('@cmfa/shared').VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> {
    if (!this.matchesCurrentIdentity(command.identity)) {
      return Promise.resolve(this.createSessionChangedResult());
    }
    if (!this.isRuntimeReadyForCommands()) {
      return Promise.resolve(this.createRuntimeNotReadyResult());
    }
    return this.commandBus.submitReadDelayTest(command);
  }

  cancelDelay(command: import('@cmfa/shared').VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> {
    if (!this.matchesCurrentIdentity(command.identity)) {
      return Promise.resolve(this.createSessionChangedResult());
    }
    if (!this.isRuntimeReadyForCommands()) {
      return Promise.resolve(this.createRuntimeNotReadyResult());
    }
    return this.commandBus.submitCancelDelayTest(command);
  }

  async queryMode(): Promise<CoreRuntimeMode> {
    if (!this.isRuntimeReadyForCommands() || this.coreService.queryRuntimeMode === undefined) {
      throw new Error('VPN runtime mode is unavailable.');
    }
    return this.coreService.queryRuntimeMode();
  }

  async setMode(mode: CoreRuntimeMode): Promise<CoreRuntimeMode> {
    if (!this.isRuntimeReadyForCommands() || this.coreService.setRuntimeMode === undefined) {
      throw new Error('VPN runtime mode is unavailable.');
    }
    return this.coreService.setRuntimeMode(mode);
  }

  async stop(): Promise<VpnControllerStopResult> {
    const coordinator: VpnControllerPort | undefined = this.resolveCoordinator();
    if (coordinator === undefined) {
      return {
        kind: 'STOPPED',
        snapshot: createStoppedRuntimeSnapshot(null)
      };
    }
    const result: VpnControllerStopResult = await coordinator.stop(this.request.sessionId);
    this.lastSnapshot = cloneRuntimeSnapshot(result.snapshot);
    if (result.kind === 'STOPPED') {
      this.onStopped(result);
    }
    return result;
  }

  updateSnapshot(snapshot: import('@cmfa/shared').VpnRuntimeSnapshot): void {
    this.lastSnapshot = cloneRuntimeSnapshot(snapshot);
  }

  private matchesCurrentRequest(request: VpnStartRequest | null): boolean {
    return request !== null &&
      request.sessionId === this.request.sessionId &&
      request.profileId === this.request.profileId &&
      request.versionId === this.request.versionId;
  }

  private matchesCurrentIdentity(identity: ProxyRuntimeIdentity): boolean {
    return identity.sessionId === this.request.sessionId &&
      identity.profileId === this.request.profileId &&
      identity.revisionId === this.request.versionId &&
      identity.revisionHash === this.catalogValue.revisionHash;
  }

  private isRuntimeReadyForCommands(): boolean {
    return this.snapshot().state === 'RUNNING';
  }

  private createRuntimeNotReadyResult(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_RUNTIME_NOT_READY', true, this.now())
    );
  }

  private createSessionChangedResult(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('VPN_SESSION_CHANGED', false, this.now())
    );
  }
}

class CompositionResolveError extends Error {
  readonly code: 'VPN_PROFILE_UNAVAILABLE' | 'VPN_CREATE_FAILED';

  constructor(code: 'VPN_PROFILE_UNAVAILABLE' | 'VPN_CREATE_FAILED', detail: string) {
    super(detail);
    this.code = code;
  }
}

class ResolvedConfigPath {
  private value?: string;

  set(path: string): void {
    this.value = path;
  }

  require(): string {
    if (this.value === undefined || this.value.trim().length === 0) {
      throw new CompositionResolveError('VPN_PROFILE_UNAVAILABLE', 'Committed VPN profile config path was unavailable.');
    }
    return this.value;
  }
}

class CommittedProfileResolverRecord implements CommittedProfileResolverPort {
  private readonly graph: PlatformGraph;
  private readonly configPath: ResolvedConfigPath;

  constructor(graph: PlatformGraph, configPath: ResolvedConfigPath) {
    this.graph = graph;
    this.configPath = configPath;
  }

  async resolve(profileId: string, versionId: string): Promise<VpnCaptureConfig> {
    const profile: Profile | undefined = await this.graph.repository.get(profileId);
    if (profile === undefined || profile.currentRevision === null) {
      throw new CompositionResolveError('VPN_PROFILE_UNAVAILABLE', 'Committed VPN profile was unavailable.');
    }
    if ((profile.availability !== 'VALID' && profile.availability !== 'UPDATE_FAILED_USING_VALID') ||
      profile.currentRevision.validatedAt !== versionId) {
      throw new CompositionResolveError('VPN_PROFILE_UNAVAILABLE', 'Committed VPN profile version was unavailable.');
    }
    this.configPath.set(this.graph.contentStore.resolveCorePath(profile.currentRevision));
    return createVpnCaptureConfig({
      addresses: EXACT_CAPTURE_CONFIG.addresses,
      routes: EXACT_CAPTURE_CONFIG.routes,
      dnsServers: EXACT_CAPTURE_CONFIG.dnsServers,
      mtu: EXACT_CAPTURE_CONFIG.mtu,
      ipv4: EXACT_CAPTURE_CONFIG.ipv4,
      ipv6: EXACT_CAPTURE_CONFIG.ipv6,
      isBlocking: EXACT_CAPTURE_CONFIG.isBlocking,
      blockedApplications: EXACT_CAPTURE_CONFIG.blockedApplications,
      trustedApplications: EXACT_CAPTURE_CONFIG.trustedApplications
    });
  }
}

class DeferredTunRuntime implements TunRuntimePort {
  private readonly createRuntime: () => TunRuntimePort;
  private readonly listeners: Map<number, (event: TunRuntimeEvent) => void> = new Map();
  private nextListenerId: number = 1;
  private runtime?: TunRuntimePort;
  private bridgeSubscriptionId?: number;
  private disposed: boolean = false;
  private runtimeDisposed: boolean = false;

  constructor(createRuntime: () => TunRuntimePort) {
    this.createRuntime = createRuntime;
  }

  async start(handle: TunHandle, options: TunStartOptions): Promise<TunRuntimeSnapshot> {
    return await this.resolveRuntime().start(handle, options);
  }

  async stop(): Promise<void> {
    if (this.runtime === undefined) {
      return;
    }
    await this.runtime.stop();
  }

  async closeStaleOutboundConnections(sessionId: string): Promise<void> {
    return await this.resolveRuntime().closeStaleOutboundConnections(sessionId);
  }

  async recover(sessionId: string): Promise<TunRuntimeSnapshot> {
    return await this.resolveRuntime().recover(sessionId);
  }

  snapshot(): TunRuntimeSnapshot {
    if (this.runtime === undefined) {
      return createTunRuntimeSnapshot({
        sessionId: 'tun-runtime',
        state: 'STOPPED',
        counters: createVpnCounters(0, 0, 0, 0),
        ingressTraces: [],
        failure: null
      });
    }
    return this.runtime.snapshot();
  }

  subscribe(listener: (event: TunRuntimeEvent) => void): number {
    const subscriptionId: number = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.listeners.clear();
    const runtime: TunRuntimePort | undefined = this.runtime;
    if (runtime === undefined) {
      return;
    }
    if (this.bridgeSubscriptionId !== undefined) {
      runtime.unsubscribe(this.bridgeSubscriptionId);
      this.bridgeSubscriptionId = undefined;
    }
    if (!this.runtimeDisposed) {
      this.runtimeDisposed = true;
      runtime.dispose();
    }
    this.runtime = undefined;
  }

  private resolveRuntime(): TunRuntimePort {
    if (this.disposed) {
      throw new Error('Tun runtime is unavailable after dispose.');
    }
    if (this.runtime !== undefined) {
      return this.runtime;
    }
    const runtime: TunRuntimePort = this.createRuntime();
    this.runtime = runtime;
    this.bridgeSubscriptionId = runtime.subscribe((event: TunRuntimeEvent) => {
      this.publish(event);
    });
    return runtime;
  }

  private publish(event: TunRuntimeEvent): void {
    const listeners: Array<(event: TunRuntimeEvent) => void> = [];
    this.listeners.forEach((listener: (event: TunRuntimeEvent) => void) => {
      listeners.push(listener);
    });
    const clonedEvent: TunRuntimeEvent = {
      sessionId: event.sessionId,
      snapshot: createTunRuntimeSnapshot({
        sessionId: event.snapshot.sessionId,
        state: event.snapshot.state,
        counters: event.snapshot.counters,
        ingressTraces: event.snapshot.ingressTraces,
        failure: event.snapshot.failure
      }),
      diagnosticStage: event.diagnosticStage
    };
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](clonedEvent);
    }
  }
}

function createMalformedWantFailure(): VpnFailure {
  return createVpnFailure('VPN_CONFIG_INVALID', 'VPN extension launch parameters were invalid.');
}

function createProfileUnavailableFailure(): VpnFailure {
  return createVpnFailure('VPN_PROFILE_UNAVAILABLE', 'Committed VPN profile version was unavailable.');
}

function createCreateFailure(): VpnFailure {
  return createVpnFailure('VPN_CREATE_FAILED', 'VPN extension startup failed before runtime handoff.');
}

function createSystemRevokedFailure(): VpnFailure {
  return createVpnFailure('VPN_SYSTEM_REVOKED', 'HarmonyOS VPN session was revoked by the system.');
}

function createStoppedRuntimeSnapshot(failure: VpnFailure | null): import('@cmfa/shared').VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state: 'STOPPED',
    activeRequest: null,
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: false,
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure: failure
  });
}

function createDelayDrainCleanupError(): Error {
  return new Error('VPN proxy delay drain failed during composition cleanup.');
}

function createProxyDeactivateCleanupError(): Error {
  return new Error('VPN proxy lifecycle deactivation failed during composition cleanup.');
}

function sanitizeFailure(failure: VpnFailure | null): VpnFailure | null {
  if (failure === null) {
    return null;
  }
  switch (failure.code) {
    case 'VPN_BACKGROUND_TASK_FAILED':
      return createVpnFailure(failure.code, 'VPN continuous task startup failed.');
    case 'VPN_CREATE_FAILED':
      return createVpnFailure(failure.code, 'HarmonyOS VPN extension start failed.');
    case 'VPN_TUN_START_FAILED':
      return createVpnFailure(failure.code, 'VPN tun runtime start failed.');
    case 'VPN_STOP_FAILED':
      return createVpnFailure(failure.code, 'HarmonyOS VPN extension stop failed.');
    case 'VPN_PROFILE_UNAVAILABLE':
      return createProfileUnavailableFailure();
    case 'VPN_CONFIG_INVALID':
      return createMalformedWantFailure();
    case 'VPN_SYSTEM_REVOKED':
      return createSystemRevokedFailure();
    default:
      return createVpnFailure(failure.code, failure.detail);
  }
}

function extractFailure(result: VpnControllerStartResult | VpnControllerStopResult): VpnFailure | null {
  if (result.kind === 'FAILED') {
    return (result as VpnControllerFailedResult).failure;
  }
  if (result.kind === 'REJECTED') {
    return (result as VpnControllerRejectedResult).failure;
  }
  return result.snapshot.lastFailure;
}

function cloneExactCaptureConfig(): VpnCaptureConfig {
  return createVpnCaptureConfig({
    addresses: EXACT_CAPTURE_CONFIG.addresses,
    routes: EXACT_CAPTURE_CONFIG.routes,
    dnsServers: EXACT_CAPTURE_CONFIG.dnsServers,
    mtu: EXACT_CAPTURE_CONFIG.mtu,
    ipv4: EXACT_CAPTURE_CONFIG.ipv4,
    ipv6: EXACT_CAPTURE_CONFIG.ipv6,
    isBlocking: EXACT_CAPTURE_CONFIG.isBlocking,
    blockedApplications: EXACT_CAPTURE_CONFIG.blockedApplications,
    trustedApplications: EXACT_CAPTURE_CONFIG.trustedApplications
  });
}

function cloneRuntimeSnapshot(snapshot: import('@cmfa/shared').VpnRuntimeSnapshot): import('@cmfa/shared').VpnRuntimeSnapshot {
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

function requireHash64(value: string, label: string): string {
  if (!HASH64_PATTERN.test(value)) {
    throw new CompositionResolveError('VPN_CREATE_FAILED', `${label} was invalid.`);
  }
  return value;
}

function createVpnRpcServerInstance(random: VpnRpcRandomPort): string {
  const bytes: Uint8Array = random.bytes(RPC_SERVER_INSTANCE_BYTES);
  if (bytes.length !== RPC_SERVER_INSTANCE_BYTES) {
    throw new CompositionResolveError('VPN_CREATE_FAILED', 'VPN RPC server instance generation failed.');
  }
  return encodeVpnRpcLowercaseHex(bytes);
}

export function parseVpnStartWant(want: Want | undefined | null): VpnStartRequest | undefined {
  if (want === undefined || want === null) {
    return undefined;
  }
  const parameters: Record<string, Object> | null | undefined =
    want.parameters as Record<string, Object> | null | undefined;
  if (parameters === undefined || parameters === null) {
    return undefined;
  }
  const keys: string[] = Object.keys(parameters);
  if (!keys.includes('profileId') || !keys.includes('versionId') || !keys.includes('sessionId')) {
    return undefined;
  }
  const rawProfileId: Object | undefined = parameters.profileId;
  const rawVersionId: Object | undefined = parameters.versionId;
  const rawSessionId: Object | undefined = parameters.sessionId;
  if (typeof rawProfileId !== 'string' || typeof rawVersionId !== 'string' || typeof rawSessionId !== 'string') {
    return undefined;
  }
  if (rawProfileId.trim().length === 0 || rawVersionId.trim().length === 0 || rawSessionId.trim().length === 0) {
    return undefined;
  }
  return {
    profileId: rawProfileId,
    versionId: rawVersionId,
    sessionId: rawSessionId
  };
}

function parseEvidenceRunId(want: Want): string {
  const parameters: Record<string, Object> | null | undefined =
    want.parameters as Record<string, Object> | null | undefined;
  const rawRunId: Object | undefined = parameters?.[EVIDENCE_RUN_ID_KEY];
  if (typeof rawRunId !== 'string' || !UUID_PATTERN.test(rawRunId)) {
    return '';
  }
  return rawRunId;
}

async function resolveCommittedProfile(graph: PlatformGraph, profileId: string, versionId: string): Promise<Profile> {
  const profile: Profile | undefined = await graph.repository.get(profileId);
  if (profile === undefined || profile.currentRevision === null) {
    throw new CompositionResolveError('VPN_PROFILE_UNAVAILABLE', 'Committed VPN profile was unavailable.');
  }
  if ((profile.availability !== 'VALID' && profile.availability !== 'UPDATE_FAILED_USING_VALID') ||
    profile.currentRevision.validatedAt !== versionId) {
    throw new CompositionResolveError('VPN_PROFILE_UNAVAILABLE', 'Committed VPN profile version was unavailable.');
  }
  return profile;
}

async function resolveVpnRpcCatalogSeed(graph: PlatformGraph, request: VpnStartRequest): Promise<VpnRpcCatalogSeed> {
  const profile: Profile = await resolveCommittedProfile(graph, request.profileId, request.versionId);
  return {
    profileHash: requireHash64(await graph.proxyIdentityHasher.sha256(profile.id), 'VPN RPC profile hash'),
    revisionHash: requireHash64(profile.currentRevision!.sha256Digest, 'VPN RPC revision hash'),
    sessionHash: requireHash64(await graph.proxyIdentityHasher.sha256(request.sessionId), 'VPN RPC session hash')
  };
}

async function buildVpnRpcCatalog(
  crypto: VpnRpcCryptoPort,
  coreProxy: CoreProxyPort,
  graph: PlatformGraph,
  request: VpnStartRequest,
  configPath: string,
  reportStage: (stage: string) => void
): Promise<import('@cmfa/shared').VpnOpaqueCatalog> {
  const seed: VpnRpcCatalogSeed = await resolveVpnRpcCatalogSeed(graph, request);
  return await buildVpnRpcCatalogFromCore(
    crypto,
    coreProxy,
    seed.profileHash,
    seed.revisionHash,
    seed.sessionHash,
    configPath,
    reportStage
  );
}

let installedFactory: ((context: common.VpnExtensionContext | undefined) => VpnExtensionCompositionRunner) | undefined = undefined;
let sharedComposition: VpnExtensionCompositionRunner | undefined = undefined;
let drainingComposition: VpnExtensionCompositionRunner | undefined = undefined;
let drainingReleasePromise: Promise<void> | undefined = undefined;
let resolveDrainingRelease: (() => void) | undefined = undefined;

export function installVpnExtensionCompositionFactoryForTesting(
  factory?: (context: common.VpnExtensionContext | undefined) => VpnExtensionCompositionRunner
): void {
  installedFactory = factory;
  sharedComposition = undefined;
  drainingReleasePromise = undefined;
  resolveDrainingRelease = undefined;
}

export function resetVpnExtensionCompositionForTesting(): void {
  installedFactory = undefined;
  sharedComposition = undefined;
  drainingComposition = undefined;
  drainingReleasePromise = undefined;
  resolveDrainingRelease = undefined;
}

export function markVpnExtensionCompositionDraining(runner: VpnExtensionCompositionRunner): void {
  if (sharedComposition === runner) {
    drainingComposition = runner;
    if (drainingReleasePromise === undefined) {
      drainingReleasePromise = new Promise<void>((resolve: () => void) => {
        resolveDrainingRelease = resolve;
      });
    }
  }
}

export function isVpnExtensionCompositionDraining(runner: VpnExtensionCompositionRunner): boolean {
  return drainingComposition === runner;
}

export function releaseVpnExtensionComposition(runner: VpnExtensionCompositionRunner): void {
  if (sharedComposition === runner) {
    sharedComposition = undefined;
  }
  if (drainingComposition === runner) {
    drainingComposition = undefined;
    const resolve: (() => void) | undefined = resolveDrainingRelease;
    drainingReleasePromise = undefined;
    resolveDrainingRelease = undefined;
    resolve?.();
  }
}

export function waitForVpnExtensionCompositionDrainRelease(): Promise<void> {
  return drainingReleasePromise ?? Promise.resolve();
}

export function cloneValidatedVpnReplayWant(want: Want): Want | undefined {
  const request: VpnStartRequest | undefined = parseVpnStartWant(want);
  if (request === undefined) {
    return undefined;
  }
  const evidenceRunId: string = parseEvidenceRunId(want);
  const replayWant: Want = {
    bundleName: want.bundleName,
    abilityName: want.abilityName,
    parameters: {}
  };
  const replayParameters: Record<string, Object> = replayWant.parameters as Record<string, Object>;
  replayParameters.profileId = request.profileId;
  replayParameters.versionId = request.versionId;
  replayParameters.sessionId = request.sessionId;
  if (evidenceRunId.length > 0) {
    replayParameters[EVIDENCE_RUN_ID_KEY] = evidenceRunId;
  }
  return replayWant;
}

export function resolveVpnExtensionComposition(context: common.VpnExtensionContext): VpnExtensionCompositionRunner {
  if (sharedComposition !== undefined) {
    return sharedComposition;
  }
  sharedComposition = installedFactory !== undefined
    ? installedFactory(context)
    : new VpnExtensionComposition(context);
  return sharedComposition;
}

export class VpnExtensionComposition implements VpnExtensionCompositionRunner {
  private readonly context?: common.VpnExtensionContext;
  private readonly dependencies: VpnExtensionCompositionDependencies;
  private readonly registry: VpnSessionRegistry;
  private readonly commandBus: VpnProxyCommandBus;
  private platformGraph?: PlatformGraph;
  private networkRecovery?: NetworkRecoveryPort;
  private coordinator?: VpnControllerPort;
  private coordinatorSubscriptionId: number = 0;
  private proxyLifecycle?: VpnProxyRuntimeLifecyclePort;
  private tunRuntime?: TunRuntimePort;
  private rpcServer?: VpnRpcServerPort;
  private tunJournalSubscriptionId: number = 0;
  private evidenceJournal?: VpnEvidenceJournalPort;
  private runtimeLogCollector?: CoreRuntimeLogCollector;
  private currentRequest?: VpnStartRequest;
  private retryableStartCleanupSessionId?: string;
  private retryableStartFailure: VpnFailure | null = null;
  private startPromise?: Promise<void>;
  private stopPromise?: Promise<void>;
  private rpcEventTail: Promise<void> = Promise.resolve();

  constructor(context: common.VpnExtensionContext | undefined, dependencies?: VpnExtensionCompositionDependencies) {
    this.context = context;
    this.dependencies = dependencies ?? {};
    this.registry = this.dependencies.registry ?? new VpnSessionRegistry();
    this.commandBus = this.dependencies.commandBus ?? new VpnProxyCommandBus();
  }

  async start(want: Want): Promise<void> {
    if (this.stopPromise !== undefined) {
      return;
    }
    if (this.startPromise !== undefined) {
      return await this.startPromise;
    }
    const request: VpnStartRequest | undefined = parseVpnStartWant(want);
    if (request === undefined) {
      this.completeMalformedPendingSession();
      return;
    }
    const evidenceRunId: string = parseEvidenceRunId(want);
    if (this.currentRequest !== undefined && this.currentRequest.sessionId === request.sessionId) {
      if (this.retryableStartCleanupSessionId === request.sessionId) {
        await this.retryFailedStartCleanup(request.sessionId);
      } else {
        return;
      }
    }
    if (this.currentRequest !== undefined && this.currentRequest.sessionId === request.sessionId) {
      return;
    }
    if (this.registry.currentSessionId() === undefined) {
      try {
        this.registry.beginPending(request);
      } catch (_) {
        return;
      }
    }
    const claimed: VpnStartRequest | undefined = this.registry.activatePending(request.sessionId, 'STARTING');
    if (claimed === undefined) {
      return;
    }
    this.currentRequest = claimed;
    const startPromise: Promise<void> = this.startInternal(claimed, evidenceRunId).finally(() => {
      if (this.startPromise === startPromise) {
        this.startPromise = undefined;
      }
    });
    this.startPromise = startPromise;
    await startPromise;
  }

  async stopForDestroy(): Promise<void> {
    if (this.stopPromise !== undefined) {
      await this.stopPromise;
      return;
    }
    const stopPromise: Promise<void> = this.stopInternal().finally(() => {
      if (this.stopPromise === stopPromise) {
        this.stopPromise = undefined;
      }
    });
    this.stopPromise = stopPromise;
    await stopPromise;
  }

  async recordUnexpectedFailure(failure: VpnFailure): Promise<void> {
    const sessionId: string | undefined = this.currentRequest?.sessionId ?? this.registry.currentSessionId();
    const sanitized: VpnFailure = sanitizeFailure(failure) ?? createCreateFailure();
    if (sessionId === undefined) {
      return;
    }
    if (this.retryableStartCleanupSessionId === sessionId) {
      this.retryableStartFailure = this.retryableStartFailure ?? sanitized;
      return;
    }
    try {
      await this.closeRpcServer();
      await this.disposeOwnedResources(sessionId);
      this.registry.completeStop(sessionId, sanitized);
      this.currentRequest = undefined;
      this.coordinator = undefined;
    } catch (_) {
      this.retryableStartCleanupSessionId = sessionId;
      this.retryableStartFailure = sanitized;
    }
  }

  private async startInternal(request: VpnStartRequest, evidenceRunId: string): Promise<void> {
    const platformFactory: PlatformFactoryLike = this.createPlatformFactory();
    try {
      const platformGraph: PlatformGraph = await platformFactory.create();
      this.platformGraph = platformGraph;
      const scheduler: BoundedDelaySchedulerPort = this.dependencies.createScheduler?.() ?? new TimeoutDelayScheduler();
      const networkRecovery: NetworkRecoveryPort = await platformFactory.createNetworkRecoveryPort();
      this.networkRecovery = networkRecovery;
      const notification: ContinuousNotificationPort = platformFactory.createContinuousNotificationPort();
      const configPath: ResolvedConfigPath = new ResolvedConfigPath();
      const resolver: CommittedProfileResolverPort = new CommittedProfileResolverRecord(platformGraph, configPath);
      const resolvedCaptureConfig: VpnCaptureConfig = await resolver.resolve(request.profileId, request.versionId);
      const tunRuntime: TunRuntimePort = new DeferredTunRuntime(() => {
        return this.createTunRuntime(configPath.require());
      });
      this.tunRuntime = tunRuntime;
      const runtimeCoreService: CoreService = this.dependencies.createCoreService?.() ?? createCoreService();
      if (this.context !== undefined && this.context.filesDir.trim().length > 0) {
        const runtimeLogCollector = new CoreRuntimeLogCollector(
          new CoreServiceLogSubscriptionAdapter(runtimeCoreService),
          createHarmonyRuntimeLogStore(this.context.filesDir),
          (): string => platformGraph.clock.now()
        );
        runtimeLogCollector.start();
        this.runtimeLogCollector = runtimeLogCollector;
      }
      let rpcRuntime: VpnRpcRuntimeDispatchRecord | undefined = undefined;
      if (this.shouldInitializeRpc()) {
        const rpcScheduler: VpnRpcSchedulerPort = new VpnRpcSchedulerAdapter(scheduler);
        const coreProxy: CoreProxyPort = new CoreProxyServiceAdapter(runtimeCoreService);
        const rpcBundle: HarmonyVpnRpcPlatformBundle = this.createVpnRpcPlatformBundle();
        reportVpnStartStage('rpc.catalog.begin');
        const rpcCatalog = await buildVpnRpcCatalog(
          rpcBundle.crypto,
          coreProxy,
          platformGraph,
          request,
          configPath.require(),
          (stage: string): void => {
            reportVpnStartStage(stage);
          }
        );
        reportVpnStartStage('rpc.catalog.ok');
        reportVpnStartStage('rpc.address.begin');
        const rpcAddress: string = await deriveVpnRpcSocketAddress(rpcBundle.crypto);
        reportVpnStartStage('rpc.address.ok');
        rpcRuntime = new VpnRpcRuntimeDispatchRecord(
          this.commandBus,
          runtimeCoreService,
          () => platformGraph.clock.now(),
          () => this.coordinator,
          (stopResult: VpnControllerStopResult) => {
            this.evidenceJournal?.finalizeStop({
              type: 'STOPPED',
              snapshot: stopResult.snapshot
            });
          },
          request,
          rpcCatalog,
          createVpnRuntimeSnapshot({
            state: 'STARTING',
            activeRequest: request,
            activeHandle: null,
            captureConfig: resolvedCaptureConfig,
            tunSnapshot: null,
            notificationActive: false,
            recoveryAttempt: 0,
            scheduledRetryDelayMs: null,
            lastFailure: null
          })
        );
        let rpcServerRef: VpnRpcServerPort | undefined = undefined;
        const rpcSession: VpnRpcServerSessionPort = this.createVpnRpcServerSession(
          rpcBundle.crypto,
          rpcBundle.random,
          rpcScheduler,
          rpcBundle.server,
          rpcAddress,
          async (body: import('@cmfa/shared').VpnRpcBody): Promise<import('@cmfa/shared').VpnRpcBody> => {
            const server: VpnRpcServerPort | undefined = rpcServerRef;
            if (server === undefined) {
              throw new Error('VPN RPC server unavailable.');
            }
            return await server.handleRequest(body);
          }
        );
        const rpcServer: VpnRpcServerPort = this.createVpnRpcServer(
          rpcSession,
          rpcRuntime,
          rpcScheduler,
          rpcBundle.random,
          createVpnRpcServerInstance(rpcBundle.random)
        );
        rpcServerRef = rpcServer;
        this.rpcServer = rpcServer;
        reportVpnStartStage('rpc.server.listen.begin');
        await rpcServer.listen();
        reportVpnStartStage('rpc.server.listen.ok');
      }
      this.evidenceJournal = this.dependencies.createEvidenceJournal?.() ?? new VpnEvidenceJournal();
      this.evidenceJournal.rotateSession(request.sessionId, evidenceRunId);
      reportVpnStartStage('rpc.journal.ready');
      this.tunJournalSubscriptionId = tunRuntime.subscribe((event: TunRuntimeEvent) => {
        if (event.diagnosticStage !== undefined) {
          this.recordVpnPacketDiagnosticStage(event.diagnosticStage);
        }
        this.evidenceJournal?.recordTunEvent(event);
      });
      const proxyLifecycle: VpnProxyRuntimeLifecyclePort = this.createProxyLifecycle(platformGraph, this.commandBus);
      this.proxyLifecycle = proxyLifecycle;
      const coordinator: VpnControllerPort = this.createCoordinator({
        resolver,
        platform: this.createPlatformPort(request.sessionId),
        tunRuntime,
        networkRecovery,
        notification,
        proxyLifecycle,
        scheduler,
        clock: this.dependencies.createClock?.() ?? new CompositionClock(),
        reportStageLifecycle: (stage: string) => {
          this.recordVpnStartStage(stage);
        }
      });
      this.coordinator = coordinator;
      this.coordinatorSubscriptionId = coordinator.subscribe((event: VpnRuntimeEvent) => {
        rpcRuntime?.updateSnapshot(event.snapshot);
        this.enqueueRpcRuntimeEvent(event);
        this.evidenceJournal?.recordCoordinatorEvent(event);
        if (event.snapshot.activeRequest === null) {
          return;
        }
        this.registry.publish({
          sessionId: event.snapshot.activeRequest.sessionId,
          state: event.snapshot.state,
          activeHandle: event.snapshot.activeHandle,
          captureConfig: event.snapshot.captureConfig,
          tunSnapshot: event.snapshot.tunSnapshot,
          notificationActive: event.snapshot.notificationActive,
          recoveryAttempt: event.snapshot.recoveryAttempt,
          scheduledRetryDelayMs: event.snapshot.scheduledRetryDelayMs,
          lastFailure: sanitizeFailure(event.snapshot.lastFailure)
        });
      });
      const result: VpnControllerStartResult = await coordinator.start(request.profileId, request.versionId, request.sessionId);
      if (result.kind === 'STARTED') {
        return;
      }
      const failure: VpnFailure | null = sanitizeFailure(extractFailure(result));
      await this.finalizeFailedStart(request.sessionId, failure);
    } catch (error) {
      const failure: VpnFailure = sanitizeFailure(this.mapCompositionFailure(error as Error | Object | undefined))!;
      await this.finalizeFailedStart(request.sessionId, failure);
    }
  }

  private async stopInternal(): Promise<void> {
    const pendingStart: Promise<void> | undefined = this.startPromise;
    if (pendingStart !== undefined) {
      try {
        await pendingStart;
      } catch (_) {
      }
    }
    const request: VpnStartRequest | undefined = this.currentRequest;
    if (request === undefined) {
      return;
    }
    await this.closeRpcServer();
    const userRequested: boolean = this.registry.isUserStopRequested(request.sessionId);
    let stopFailure: VpnFailure | null = null;
    if (this.coordinator !== undefined) {
      const stopResult: VpnControllerStopResult = await this.coordinator.stop(request.sessionId);
      stopFailure = sanitizeFailure(extractFailure(stopResult));
      this.evidenceJournal?.finalizeStop({
        type: 'STOPPED',
        snapshot: stopResult.snapshot
      });
    }
    await this.disposeOwnedResources(request.sessionId);
    this.registry.completeStop(
      request.sessionId,
      stopFailure ?? (userRequested ? null : sanitizeFailure(createSystemRevokedFailure()))
    );
    this.currentRequest = undefined;
    this.coordinator = undefined;
  }

  private completeMalformedPendingSession(): void {
    const sessionId: string | undefined = this.registry.currentSessionId();
    if (sessionId === undefined) {
      return;
    }
    this.registry.completeStop(sessionId, createMalformedWantFailure());
  }

  private createPlatformFactory(): PlatformFactoryLike {
    if (this.dependencies.createPlatformFactory !== undefined) {
      return this.dependencies.createPlatformFactory(this.context);
    }
    if (this.context === undefined) {
      throw new CompositionResolveError('VPN_CREATE_FAILED', 'VPN extension context was unavailable.');
    }
    return new PlatformFactory(this.context);
  }

  private createPlatformPort(sessionId: string): VpnPlatformSessionPort {
    if (this.dependencies.createPlatformPort !== undefined) {
      return this.dependencies.createPlatformPort(sessionId);
    }
    if (this.context === undefined) {
      throw new CompositionResolveError('VPN_CREATE_FAILED', 'VPN extension context was unavailable.');
    }
    return new HarmonyVpnConnectionDriver(
      new HarmonyVpnConnectionApi(this.context, defaultSdkApiVersionResolver),
      sessionId,
      (stage: string) => {
        this.recordVpnStartStage(stage);
      }
    );
  }

  private recordVpnStartStage(stage: string): void {
    reportVpnStartStage(stage);
    this.evidenceJournal?.recordLifecycleFact('starting', stage.split('.').join('-'));
  }

  private recordVpnPacketDiagnosticStage(stage: string): void {
    this.evidenceJournal?.recordDiagnosticStage(stage.split('.').join('-'));
  }

  private createTunRuntime(configPath: string): TunRuntimePort {
    if (this.dependencies.createTunRuntime !== undefined) {
      return this.dependencies.createTunRuntime(configPath);
    }
    if (this.context === undefined) {
      throw new CompositionResolveError('VPN_CREATE_FAILED', 'VPN extension context was unavailable.');
    }
    const runtimeConfig: CoreTunRuntimeConfig = {
      configPath,
      mixedPort: 7890,
      platformApiLevel: defaultSdkApiVersionResolver(this.context),
      processProtected: true
    };
    return new CoreTunRuntime(runtimeConfig);
  }

  private createProxyLifecycle(graph: PlatformGraph, commandBus: VpnProxyCommandBus): VpnProxyRuntimeLifecyclePort {
    if (this.dependencies.createProxyLifecycle !== undefined) {
      return this.dependencies.createProxyLifecycle(graph, commandBus);
    }
    return new VpnProxyRuntimeHandler(
      graph.repository,
      graph.proxySelectionRepository,
      graph.proxyIdentityHasher,
      new CoreProxyServiceAdapter(this.dependencies.createCoreService?.() ?? createCoreService()),
      graph.clock,
      commandBus
    );
  }

  private createCoordinator(dependencies: VpnRuntimeCoordinatorDependencies): VpnControllerPort {
    if (this.dependencies.createCoordinator !== undefined) {
      return this.dependencies.createCoordinator(dependencies);
    }
    return new VpnRuntimeCoordinator(dependencies);
  }

  private shouldInitializeRpc(): boolean {
    return this.dependencies.createCoreService !== undefined || this.dependencies.createProxyLifecycle === undefined;
  }

  private createVpnRpcPlatformBundle(): HarmonyVpnRpcPlatformBundle {
    if (this.dependencies.createVpnRpcPlatformBundle !== undefined) {
      return this.dependencies.createVpnRpcPlatformBundle();
    }
    return new HarmonyVpnRpcPlatformFactory(undefined, this.context?.filesDir ?? '').create();
  }

  private createVpnRpcServerSession(
    crypto: VpnRpcCryptoPort,
    random: VpnRpcRandomPort,
    scheduler: VpnRpcSchedulerPort,
    socketServer: VpnRpcSocketServerPort,
    address: string,
    handler: (request: import('@cmfa/shared').VpnRpcBody) => Promise<import('@cmfa/shared').VpnRpcBody>
  ): VpnRpcServerSessionPort {
    if (this.dependencies.createVpnRpcServerSession !== undefined) {
      return this.dependencies.createVpnRpcServerSession(crypto, random, scheduler, socketServer, address, handler);
    }
    return new VpnRpcServerSession(crypto, random, scheduler, socketServer, address, handler);
  }

  private createVpnRpcServer(
    session: VpnRpcServerSessionPort,
    runtime: VpnRpcRuntimeDispatchPort,
    scheduler: VpnRpcSchedulerPort,
    random: VpnRpcRandomPort,
    serverInstance: string
  ): VpnRpcServerPort {
    if (this.dependencies.createVpnRpcServer !== undefined) {
      return this.dependencies.createVpnRpcServer(session, runtime, scheduler, random, serverInstance);
    }
    return new VpnRpcServer(session, runtime, scheduler, random, serverInstance);
  }

  private enqueueRpcRuntimeEvent(event: VpnRuntimeEvent): void {
    if (!this.shouldPublishRpcRuntimeEvent(event)) {
      return;
    }
    const server: VpnRpcServerPort | undefined = this.rpcServer;
    if (server === undefined) {
      return;
    }
    const previous: Promise<void> = this.rpcEventTail;
    this.rpcEventTail = previous
      .catch(() => {
      })
      .then(async (): Promise<void> => {
        try {
          await server.publishRuntimeChanged(event.snapshot);
        } catch (_) {
        }
      });
  }

  private shouldPublishRpcRuntimeEvent(event: VpnRuntimeEvent): boolean {
    if (event.type === 'SNAPSHOT') {
      return false;
    }
    const currentRequest: VpnStartRequest | undefined = this.currentRequest;
    if (currentRequest === undefined) {
      return false;
    }
    const activeRequest: VpnStartRequest | null = event.snapshot.activeRequest;
    if (activeRequest !== null) {
      return activeRequest.sessionId === currentRequest.sessionId &&
        activeRequest.profileId === currentRequest.profileId &&
        activeRequest.versionId === currentRequest.versionId;
    }
    switch (event.snapshot.state) {
      case 'STOPPED':
      case 'ERROR':
        return true;
      default:
        return false;
    }
  }

  private async closeRpcServer(): Promise<void> {
    const rpcServer: VpnRpcServerPort | undefined = this.rpcServer;
    this.rpcServer = undefined;
    if (rpcServer === undefined) {
      return;
    }
    try {
      await rpcServer.close();
    } catch (_) {
    }
  }

  private async releaseCoordinatorResources(): Promise<void> {
    const coordinator: VpnControllerPort | undefined = this.coordinator;
    const subscriptionId: number = this.coordinatorSubscriptionId;
    this.coordinatorSubscriptionId = 0;
    this.coordinator = undefined;
    if (coordinator === undefined) {
      return;
    }
    if (subscriptionId > 0) {
      try {
        coordinator.unsubscribe(subscriptionId);
      } catch (_) {
      }
    }
    try {
      await coordinator.dispose?.();
    } catch (_) {
    }
  }

  private async releaseNetworkRecovery(): Promise<void> {
    const networkRecovery: NetworkRecoveryPort | undefined = this.networkRecovery;
    this.networkRecovery = undefined;
    if (networkRecovery === undefined) {
      return;
    }
    try {
      await networkRecovery.dispose?.();
    } catch (_) {
    }
  }

  private mapCompositionFailure(error: Error | Object | undefined): VpnFailure {
    if (error instanceof CompositionResolveError) {
      return error.code === 'VPN_PROFILE_UNAVAILABLE'
        ? createProfileUnavailableFailure()
        : createCreateFailure();
    }
    return createCreateFailure();
  }

  private async finalizeFailedStart(sessionId: string, failure: VpnFailure | null): Promise<void> {
    try {
      await this.closeRpcServer();
      await this.disposeOwnedResources(sessionId);
      this.registry.completeStop(sessionId, failure);
      this.clearRetryableStartCleanupState();
      this.currentRequest = undefined;
      this.coordinator = undefined;
    } catch (error) {
      this.retryableStartCleanupSessionId = sessionId;
      this.retryableStartFailure = failure;
      throw error instanceof Error ? error : createDelayDrainCleanupError();
    }
  }

  private async retryFailedStartCleanup(sessionId: string): Promise<void> {
    if (this.retryableStartCleanupSessionId !== sessionId) {
      return;
    }
    await this.closeRpcServer();
    await this.disposeOwnedResources(sessionId);
    this.registry.completeStop(sessionId, this.retryableStartFailure);
    this.clearRetryableStartCleanupState();
    this.currentRequest = undefined;
    this.coordinator = undefined;
  }

  private clearRetryableStartCleanupState(): void {
    this.retryableStartCleanupSessionId = undefined;
    this.retryableStartFailure = null;
  }

  private async disposeOwnedResources(sessionId?: string): Promise<void> {
    const tunRuntime: TunRuntimePort | undefined = this.tunRuntime;
    const lifecycle: VpnProxyRuntimeLifecyclePort | undefined = this.proxyLifecycle;
    let cleanupError: Error | undefined = undefined;
    let retainProxyLifecycle: boolean = false;
    const runtimeLogCollector: CoreRuntimeLogCollector | undefined = this.runtimeLogCollector;
    this.runtimeLogCollector = undefined;
    if (runtimeLogCollector !== undefined) {
      await runtimeLogCollector.close();
    }
    await this.releaseCoordinatorResources();
    await this.releaseNetworkRecovery();
    if (lifecycle !== undefined && sessionId !== undefined) {
      lifecycle.invalidate(sessionId);
      try {
        await lifecycle.cancelAndDrainDelayTest(sessionId);
      } catch (_) {
        throw createDelayDrainCleanupError();
      }
      try {
        await lifecycle.deactivate(sessionId);
      } catch (_) {
        cleanupError = createProxyDeactivateCleanupError();
        retainProxyLifecycle = true;
      }
    }
    if (tunRuntime !== undefined && this.tunJournalSubscriptionId !== 0) {
      tunRuntime.unsubscribe(this.tunJournalSubscriptionId);
      this.tunJournalSubscriptionId = 0;
    }
    this.tunRuntime = undefined;
    this.evidenceJournal = undefined;
    if (!retainProxyLifecycle) {
      this.proxyLifecycle = undefined;
    }
    tunRuntime?.dispose();
    const graph: PlatformGraph | undefined = this.platformGraph;
    this.platformGraph = undefined;
    if (graph !== undefined) {
      try {
        await graph.close();
      } catch (_) {
      }
    }
    if (cleanupError !== undefined) {
      throw cleanupError;
    }
  }
}
