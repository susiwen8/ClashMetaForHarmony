import type { Want } from '@kit.AbilityKit';
import common from '@ohos.app.ability.common';
import { describe, expect, it } from '@ohos/hypium';
import type { HarmonyVpnRpcPlatformBundle, PlatformGraph } from '@cmfa/platform';
import {
  createProxyDelayNodeResult,
  createProxyDelaySnapshotResult,
  createProxyGroupListQuerySnapshot,
  createProxyGroupQuerySnapshot,
  createProxyGroupSnapshot,
  createProxyRuntimeIdentity,
  createProxySelectionAppliedNowResult,
  createProxySelectionRecord,
  createVpnRpcBodyRequest,
  createVpnRpcDelayGroupRequestPayload,
  createVpnRpcDelayJobRequestPayload,
  createVpnRpcEmptyPayload,
  createVpnRpcGuards,
  createVpnRpcQueryGroupRequestPayload,
  createVpnRpcSelectNodeRequestPayload,
  encodeVpnRpcBodyToText,
  VpnRpcServer,
  VpnProxyCommandBus,
  type CoreProxyGroupList,
  type CoreProxyGroupRef,
  type CoreProxyGroupResult,
  type CoreProxyGroupSnapshot,
  type CoreProxyNodeSummary,
  VpnRuntimeCoordinator,
  createProfile,
  createProfileRevision,
  createTunHandle,
  createVpnRuntimeEvent,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  createTunRuntimeSnapshot,
  createVpnCaptureConfig,
  createVpnCounters,
  createVpnFailure,
  type BoundedDelaySchedulerPort,
  type CancelableDelayTask,
  type ClockPort,
  type ContinuousNotificationPort,
  type CoreProxyDelaySnapshot,
  type NetworkRecoveryPort,
  type NetworkStatus,
  type Profile,
  type ProxyDelayResult,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyRuntimeIdentity,
  type ProxySelectionResult,
  type CoreProxyQueryContext,
  type CoreProxySelectionApplied,
  type CoreService,
  type ProfileContentStore,
  type ProxyIdentityHasher,
  type ProxySelectionPair,
  type ProxySelectionRecord,
  type ProxySelectionRepository,
  type ProfileRepository,
  type ProfileRevision,
  type ProfileSourceGateway,
  type StagedSource,
  type SubscriptionSecretStore,
  type TunHandle,
  type TunRuntimeEvent,
  type TunRuntimePort,
  type TunRuntimeSnapshot,
  type TunStartOptions,
  type VpnCaptureConfig,
  type VpnRuntimeCoordinatorDependencies,
  type VpnProxyRuntimeLifecyclePort,
  type VpnControllerPort,
  type VpnFailure,
  type VpnPlatformSessionPort,
  type VpnProxyCommandHandler,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot,
  type VpnRuntimeState,
  type VpnRpcBody,
  type VpnRpcCryptoPort,
  type VpnRpcGuards,
  type VpnRpcMethod,
  type VpnRpcPayload,
  type VpnRpcRandomPort,
  type VpnRpcRuntimeDispatchPort,
  type VpnRpcSchedulerPort,
  type VpnRpcServerPort,
  type VpnRpcServerSessionPort,
  type VpnRpcSocketClientFactoryPort,
  type VpnRpcSocketConnectionPort,
  type VpnRpcSocketServerPort,
  type VpnStartRequest
} from '@cmfa/shared';
import CmfaVpnExtensionAbility from '../main/ets/vpn/CmfaVpnExtensionAbility';
import {
  cloneValidatedVpnReplayWant,
  VpnExtensionCompositionRunner,
  VpnExtensionComposition,
  installVpnExtensionCompositionFactoryForTesting,
  parseVpnStartWant,
  resetVpnExtensionCompositionForTesting,
  type VpnExtensionCompositionDependencies
} from '../main/ets/vpn/VpnExtensionComposition';
import {
  VpnEvidenceJournal,
  type VpnEvidenceJournalClock,
  type VpnEvidenceJournalPort,
  type VpnEvidenceJournalStorage
} from '../main/ets/vpn/VpnEvidenceJournal';
import { VpnSessionRegistry } from '../main/ets/vpn/VpnSessionRegistry';

const EVIDENCE_RUN_ID_KEY: string = 'cmfa.phase1.runId';
const VALID_EVIDENCE_RUN_ID: string = '00000000-0000-4000-8000-000000000123';

class ImmediateDelayTask implements CancelableDelayTask {
  cancel(): void {
  }
}

class PassiveDelayTask implements CancelableDelayTask {
  cancel(): void {
  }
}

class PassiveScheduler implements BoundedDelaySchedulerPort {
  schedule(_delayMs: number, _runner: () => Promise<void>): CancelableDelayTask {
    return new PassiveDelayTask();
  }
}

class ImmediateScheduler implements BoundedDelaySchedulerPort {
  schedule(_delayMs: number, runner: () => Promise<void>): CancelableDelayTask {
    void runner();
    return new ImmediateDelayTask();
  }
}

class FixedClock implements ClockPort {
  nowMs(): number {
    return 100;
  }
}

class SilentNetworkRecovery implements NetworkRecoveryPort {
  currentNetwork(): NetworkStatus {
    return {
      usable: false,
      networkId: ''
    };
  }

  subscribeUsableNetwork(_listener: (status: NetworkStatus) => void): number {
    return 1;
  }

  unsubscribeUsableNetwork(_subscriptionId: number): void {
  }
}

class MemoryRepository implements ProfileRepository {
  private readonly profile?: Profile;

  constructor(profile?: Profile) {
    this.profile = profile;
  }

  async list(): Promise<Profile[]> {
    return this.profile === undefined ? [] : [this.profile];
  }

  async get(id: string): Promise<Profile | undefined> {
    if (this.profile === undefined || this.profile.id !== id) {
      return undefined;
    }
    return this.profile;
  }

  async save(_profile: Profile): Promise<void> {
  }

  async deleteAndClearActive(_id: string): Promise<void> {
  }

  async getActiveId(): Promise<string | undefined> {
    return undefined;
  }

  async setActiveId(_id: string | undefined): Promise<void> {
  }
}

class MemoryContentStore implements ProfileContentStore {
  resolveCorePath(revision: ProfileRevision): string {
    return `/sandbox/${revision.relativePath}`;
  }

  async retain(_profileId: string, _staged: StagedSource, _kind: 'CURRENT' | 'FAILED_CANDIDATE'): Promise<ProfileRevision> {
    throw new Error('retain unused');
  }

  async discard(_staged: StagedSource): Promise<void> {
  }

  async removeRevision(_revision: ProfileRevision): Promise<void> {
  }

  async removeProfile(_profileId: string): Promise<void> {
  }

  async reconcile(_referenced: ProfileRevision[]): Promise<void> {
  }
}

class InertSourceGateway implements ProfileSourceGateway {
  async acquireLocal(): Promise<never> {
    throw new Error('unused');
  }

  async acquireRemote(): Promise<never> {
    throw new Error('unused');
  }
}

class InertSecretStore implements SubscriptionSecretStore {
  async encrypt(_plaintext: string): Promise<string> {
    return 'secret-ref';
  }

  async decrypt(_secretRef: string): Promise<string> {
    return 'secret-value';
  }

  async remove(_secretRef: string): Promise<void> {
  }
}

class InertProxySelectionRepository implements ProxySelectionRepository {
  async listByProfile(_profileId: string): Promise<ProxySelectionRecord[]> {
    return [];
  }

  async get(_profileId: string, _groupName: string): Promise<ProxySelectionRecord | undefined> {
    return undefined;
  }

  async upsert(_record: ProxySelectionRecord): Promise<void> {
  }

  async delete(_profileId: string, _groupName: string): Promise<void> {
  }

  async deleteProfile(_profileId: string): Promise<void> {
  }

  async reconcileProfile(_profileId: string, _newRevisionId: string, _validPairs: ProxySelectionPair[]): Promise<void> {
  }
}

class InertProxyIdentityHasher implements ProxyIdentityHasher {
  async sha256(_value: string): Promise<string> {
    return 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  }
}

class RecordingPlatformGraph implements PlatformGraph {
  readonly repository: ProfileRepository;
  readonly proxySelectionRepository: ProxySelectionRepository = new InertProxySelectionRepository();
  readonly proxyIdentityHasher: ProxyIdentityHasher = new InertProxyIdentityHasher();
  readonly contentStore: ProfileContentStore;
  readonly sourceGateway: ProfileSourceGateway = new InertSourceGateway();
  readonly secretStore: SubscriptionSecretStore = new InertSecretStore();
  readonly clock: GraphClock = new GraphClock();
  readonly idGenerator: GraphIdGenerator = new GraphIdGenerator();
  closeCalls: number = 0;

  constructor(profile?: Profile) {
    this.repository = new MemoryRepository(profile);
    this.contentStore = new MemoryContentStore();
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
  }
}

class RecordingNotification implements ContinuousNotificationPort {
  readonly log: string[];
  startError?: Error;
  stopError?: Error;

  constructor(log: string[]) {
    this.log = log;
  }

  async start(sessionId: string): Promise<void> {
    this.log.push(`notification.start:${sessionId}`);
    if (this.startError !== undefined) {
      throw this.startError;
    }
  }

  async stop(sessionId: string): Promise<void> {
    this.log.push(`notification.stop:${sessionId}`);
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
  }

  async updateTraffic(
    _sessionId: string,
    _uploadBytesPerSecond: number,
    _downloadBytesPerSecond: number
  ): Promise<void> {
  }

  subscribeCancellation(_listener: (sessionId: string) => void): number {
    return 1;
  }

  unsubscribeCancellation(_subscriptionId: number): void {
  }
}

class RecordingProxyLifecycle implements VpnProxyRuntimeLifecyclePort {
  readonly log: string[];
  activateError?: Error;
  deactivateError?: Error;
  drainError?: Error;

  constructor(log: string[]) {
    this.log = log;
  }

  async activate(request: VpnStartRequest): Promise<void> {
    this.log.push(`proxy.activate:${request.sessionId}`);
    if (this.activateError !== undefined) {
      throw this.activateError;
    }
  }

  invalidate(sessionId: string): void {
    this.log.push(`proxy.invalidate:${sessionId}`);
  }

  async deactivate(sessionId: string): Promise<void> {
    this.log.push(`proxy.deactivate:${sessionId}`);
    if (this.deactivateError !== undefined) {
      throw this.deactivateError;
    }
  }

  async cancelAndDrainDelayTest(sessionId: string): Promise<void> {
    this.log.push(`proxy.drain:${sessionId}`);
    if (this.drainError !== undefined) {
      throw this.drainError;
    }
  }
}

class GraphClock {
  now(): string {
    return '2026-08-16T12:00:00.000Z';
  }
}

class GraphIdGenerator {
  nextId(): string {
    return 'generated-id';
  }
}

class FakeCompositionRunner implements VpnExtensionCompositionRunner {
  startCalls: number = 0;
  stopCalls: number = 0;
  recordedFailures: VpnFailure[] = [];
  private resolveStartRef?: () => void;
  private readonly startGate: Promise<void>;

  constructor() {
    this.startGate = new Promise<void>((resolve) => {
      this.resolveStartRef = resolve;
    });
  }

  async start(_want: Want): Promise<void> {
    this.startCalls += 1;
    await this.startGate;
  }

  async stopForDestroy(): Promise<void> {
    this.stopCalls += 1;
  }

  async recordUnexpectedFailure(failure: VpnFailure): Promise<void> {
    this.recordedFailures.push(failure);
  }

  releaseStart(): void {
    this.resolveStartRef?.();
  }
}

class DeferredStopCompositionRunner implements VpnExtensionCompositionRunner {
  readonly contextTag: string;
  startCalls: number = 0;
  stopCalls: number = 0;
  recordedFailures: VpnFailure[] = [];
  startedWants: Want[] = [];
  private resolveStopRef?: () => void;
  private readonly stopGate: Promise<void>;

  constructor(contextTag: string) {
    this.contextTag = contextTag;
    this.stopGate = new Promise<void>((resolve) => {
      this.resolveStopRef = resolve;
    });
  }

  async start(_want: Want): Promise<void> {
    this.startCalls += 1;
    this.startedWants.push(_want);
  }

  async stopForDestroy(): Promise<void> {
    this.stopCalls += 1;
    await this.stopGate;
  }

  async recordUnexpectedFailure(failure: VpnFailure): Promise<void> {
    this.recordedFailures.push(failure);
  }

  releaseStop(): void {
    this.resolveStopRef?.();
  }
}

class FakeAbilityInfoRecord {
  bundleName: string;
  name: string;

  constructor(bundleName: string, name: string) {
    this.bundleName = bundleName;
    this.name = name;
  }
}

class FakeHapModuleInfoRecord {
  name: string;

  constructor(name: string) {
    this.name = name;
  }
}

class EmptyResourceManagerRecord {
}

class EmptyApplicationInfoRecord {
}

class EmptyConfigurationRecord {
}

class FakeVpnExtensionContextRecord {
  readonly stageMode: boolean = true;
  readonly resourceManager: EmptyResourceManagerRecord = new EmptyResourceManagerRecord();
  readonly applicationInfo: EmptyApplicationInfoRecord = new EmptyApplicationInfoRecord();
  readonly cacheDir: string;
  readonly tempDir: string;
  readonly filesDir: string;
  readonly currentHapModuleInfo: FakeHapModuleInfoRecord;
  readonly config: EmptyConfigurationRecord = new EmptyConfigurationRecord();
  readonly extensionAbilityInfo: FakeAbilityInfoRecord;

  constructor(tag: string) {
    this.cacheDir = `/sandbox/${tag}/cache`;
    this.tempDir = `/sandbox/${tag}/tmp`;
    this.filesDir = `/sandbox/${tag}/files`;
    this.currentHapModuleInfo = new FakeHapModuleInfoRecord(`${tag}-module`);
    this.extensionAbilityInfo = new FakeAbilityInfoRecord('com.github.kr328.clash.harmony', tag);
  }
}

class NullParametersWantRecord {
  bundleName?: string;
  abilityName?: string;
  parameters?: Record<string, Object> | null;

  constructor(profileId: string, versionId: string, sessionId: string) {
    this.bundleName = 'com.github.kr328.clash.harmony';
    this.abilityName = 'CmfaVpnExtensionAbility';
    void profileId;
    void versionId;
    void sessionId;
    this.parameters = null;
  }
}

class WantParametersRecord {
  profileId: string = '';
  versionId: string = '';
  sessionId: string = '';
}

class RejectingCompositionRunner implements VpnExtensionCompositionRunner {
  readonly registry: VpnSessionRegistry;
  startCalls: number = 0;
  stopCalls: number = 0;
  recordedFailures: VpnFailure[] = [];
  startError: Error = new Error('raw ability start secret 77');

  constructor(registry: VpnSessionRegistry) {
    this.registry = registry;
  }

  async start(_want: Want): Promise<void> {
    this.startCalls += 1;
    throw this.startError;
  }

  async stopForDestroy(): Promise<void> {
    this.stopCalls += 1;
  }

  async recordUnexpectedFailure(failure: VpnFailure): Promise<void> {
    this.recordedFailures.push(failure);
    const sessionId: string | undefined = this.registry.currentSessionId();
    if (sessionId !== undefined) {
      this.registry.completeStop(sessionId, failure);
    }
  }
}

class RecordingEvidenceJournal implements VpnEvidenceJournalPort {
  coordinatorEvents: VpnRuntimeEvent[] = [];

  rotateSession(_sessionId: string, _runId: string): void {
  }

  recordCoordinatorEvent(event: VpnRuntimeEvent): void {
    this.coordinatorEvents.push(createVpnRuntimeEvent(event.type, event.snapshot));
  }

  recordTunEvent(_event: TunRuntimeEvent): void {
  }

  recordDiagnosticStage(_stage: string): void {
  }

  recordLifecycleFact(_state: string, _detail: string): void {
  }

  recordTunCounters(_counters: import('../main/ets/vpn/VpnEvidenceJournal').VpnEvidenceCounters): void {
  }

  recordObservationAdapter(_record: import('../main/ets/vpn/VpnEvidenceJournal').VpnEvidenceObservationRecord): void {
  }

  finalizeStop(_event: VpnRuntimeEvent | null): void {
  }

  finalizeStopWithDetail(_sessionId: string, _detail: string): void {
  }

  createObservationRecordForTesting(
    _sessionId: string,
    _kind: import('../main/ets/vpn/VpnEvidenceJournal').VpnEvidenceRecordKind,
    _ingress: string,
    _traceAlias: string,
    _coreAlias: string,
    _flowId: string,
    _linkageStatus: import('../main/ets/vpn/VpnEvidenceJournal').VpnEvidenceLinkageStatus
  ): import('../main/ets/vpn/VpnEvidenceJournal').VpnEvidenceObservationRecord {
    throw new Error('unused');
  }

  snapshot(): import('../main/ets/vpn/VpnEvidenceJournal').VpnEvidenceJournalDocument {
    throw new Error('unused');
  }
}

class CompositionJournalStorage implements VpnEvidenceJournalStorage {
  writes: string[] = [];

  writeAtomic(_targetPath: string, content: string): void {
    this.writes.push(content);
  }
}

class CompositionJournalClock implements VpnEvidenceJournalClock {
  isoNow(): string {
    return '2026-08-28T08:00:00.000Z';
  }
}

class ManualCoordinator implements VpnControllerPort {
  readonly expectedRequest: VpnStartRequest;
  readonly startEvents: VpnRuntimeEvent[];
  readonly stopEvents: VpnRuntimeEvent[];
  startCalls: number = 0;
  stopCalls: number = 0;
  private readonly listeners: Map<number, (event: VpnRuntimeEvent) => void> = new Map();
  private nextListenerId: number = 1;
  private snapshotValue: VpnRuntimeSnapshot;

  constructor(expectedRequest: VpnStartRequest, startEvents: VpnRuntimeEvent[] = [], stopEvents: VpnRuntimeEvent[] = []) {
    this.expectedRequest = expectedRequest;
    this.startEvents = startEvents;
    this.stopEvents = stopEvents;
    this.snapshotValue = buildRuntimeSnapshot('STOPPED', null);
  }

  async start(profileId: string, versionId: string, sessionId: string): Promise<import('@cmfa/shared').VpnControllerStartResult> {
    this.startCalls += 1;
    expect(profileId).assertEqual(this.expectedRequest.profileId);
    expect(versionId).assertEqual(this.expectedRequest.versionId);
    expect(sessionId).assertEqual(this.expectedRequest.sessionId);
    this.startEvents.forEach((event: VpnRuntimeEvent) => {
      this.emit(event);
    });
    return {
      kind: 'STARTED',
      snapshot: this.snapshot()
    };
  }

  async stop(sessionId?: string): Promise<import('@cmfa/shared').VpnControllerStopResult> {
    this.stopCalls += 1;
    expect(sessionId ?? '').assertEqual(this.expectedRequest.sessionId);
    this.stopEvents.forEach((event: VpnRuntimeEvent) => {
      this.emit(event);
    });
    return {
      kind: 'STOPPED',
      snapshot: this.snapshot()
    };
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

  unsubscribe(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }

  emit(event: VpnRuntimeEvent): void {
    this.snapshotValue = createVpnRuntimeSnapshot({
      state: event.snapshot.state,
      activeRequest: event.snapshot.activeRequest,
      activeHandle: event.snapshot.activeHandle,
      captureConfig: event.snapshot.captureConfig,
      tunSnapshot: event.snapshot.tunSnapshot,
      notificationActive: event.snapshot.notificationActive,
      recoveryAttempt: event.snapshot.recoveryAttempt,
      scheduledRetryDelayMs: event.snapshot.scheduledRetryDelayMs,
      lastFailure: event.snapshot.lastFailure
    });
    const clonedEvent: VpnRuntimeEvent = createVpnRuntimeEvent(event.type, event.snapshot);
    this.listeners.forEach((listener: (event: VpnRuntimeEvent) => void) => {
      listener(clonedEvent);
    });
  }
}

class BlockingStartCoordinator extends ManualCoordinator {
  private readonly startGate: Promise<void>;
  private resolveStartRef?: () => void;

  constructor(expectedRequest: VpnStartRequest, startEvents: VpnRuntimeEvent[] = [], stopEvents: VpnRuntimeEvent[] = []) {
    super(expectedRequest, startEvents, stopEvents);
    this.startGate = new Promise<void>((resolve: () => void) => {
      this.resolveStartRef = resolve;
    });
  }

  async start(profileId: string, versionId: string, sessionId: string): Promise<import('@cmfa/shared').VpnControllerStartResult> {
    this.startCalls += 1;
    expect(profileId).assertEqual(this.expectedRequest.profileId);
    expect(versionId).assertEqual(this.expectedRequest.versionId);
    expect(sessionId).assertEqual(this.expectedRequest.sessionId);
    this.startEvents.forEach((event: VpnRuntimeEvent) => {
      this.emit(event);
    });
    await this.startGate;
    return {
      kind: 'STARTED',
      snapshot: this.snapshot()
    };
  }

  releaseStart(): void {
    this.resolveStartRef?.();
  }
}

class RecordingPlatformPort implements VpnPlatformSessionPort {
  readonly log: string[];
  createError?: Error;
  protectProcessError?: Error;
  destroyError?: Error;
  nextHandle: TunHandle = createTunHandle(31, 'vpn-1', 'session-1');

  constructor(log: string[]) {
    this.log = log;
  }

  async protectProcess(): Promise<void> {
    this.log.push('platform.protectProcess');
    if (this.protectProcessError !== undefined) {
      throw this.protectProcessError;
    }
  }

  async create(_config: VpnCaptureConfig): Promise<TunHandle> {
    this.log.push(`platform.create:${this.nextHandle.sessionId}`);
    if (this.createError !== undefined) {
      throw this.createError;
    }
    return createTunHandle(this.nextHandle.fd, this.nextHandle.vpnId, this.nextHandle.sessionId);
  }

  async protectSocket(fd: number): Promise<void> {
    this.log.push(`platform.protectSocket:${fd}`);
  }

  async destroy(vpnId: string): Promise<void> {
    this.log.push(`platform.destroy:${vpnId}`);
    if (this.destroyError !== undefined) {
      throw this.destroyError;
    }
  }
}

class RecordingTunRuntime implements TunRuntimePort {
  readonly log: string[];
  startError?: Error;
  stopError?: Error;
  disposeCalls: number = 0;
  private readonly listeners: Map<number, (event: TunRuntimeEvent) => void> = new Map();
  private nextListenerId: number = 1;
  snapshotValue: TunRuntimeSnapshot = createTunRuntimeSnapshot({
    sessionId: 'session-1',
    state: 'READY',
    counters: createVpnCounters(0, 0, 0, 0),
    ingressTraces: [],
    failure: null
  });

  constructor(log: string[]) {
    this.log = log;
  }

  async start(handle: TunHandle, _options: TunStartOptions): Promise<TunRuntimeSnapshot> {
    this.log.push('core.runtime.create');
    this.log.push(`tun.start:${handle.sessionId}`);
    if (this.startError !== undefined) {
      throw this.startError;
    }
    return this.snapshot();
  }

  async stop(): Promise<void> {
    this.log.push('tun.stop');
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
  }

  async closeStaleOutboundConnections(sessionId: string): Promise<void> {
    this.log.push(`tun.closeStale:${sessionId}`);
  }

  async recover(sessionId: string): Promise<TunRuntimeSnapshot> {
    this.log.push(`tun.recover:${sessionId}`);
    return this.snapshot();
  }

  snapshot(): TunRuntimeSnapshot {
    return createTunRuntimeSnapshot({
      sessionId: this.snapshotValue.sessionId,
      state: this.snapshotValue.state,
      counters: this.snapshotValue.counters,
      ingressTraces: this.snapshotValue.ingressTraces,
      failure: this.snapshotValue.failure
    });
  }

  subscribe(listener: (event: TunRuntimeEvent) => void): number {
    const id: number = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(id, listener);
    return id;
  }

  unsubscribe(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }

  emit(event: TunRuntimeEvent): void {
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
    this.listeners.forEach((listener: (event: TunRuntimeEvent) => void) => {
      listener(clonedEvent);
    });
  }

  dispose(): void {
    this.disposeCalls += 1;
    this.log.push('tun.dispose');
    this.listeners.clear();
  }

  listenerCount(): number {
    return this.listeners.size;
  }
}

class RecordingPlatformFactory {
  readonly graph: RecordingPlatformGraph;
  readonly notification: RecordingNotification;
  readonly networkRecovery: SilentNetworkRecovery = new SilentNetworkRecovery();
  readonly log: string[];

  constructor(log: string[], profile?: Profile) {
    this.log = log;
    this.graph = new RecordingPlatformGraph(profile);
    this.notification = new RecordingNotification(log);
  }

  async create(): Promise<PlatformGraph> {
    this.log.push('platform.adapters.graph');
    return this.graph;
  }

  async createNetworkRecoveryPort(): Promise<NetworkRecoveryPort> {
    this.log.push('platform.adapters.network');
    return this.networkRecovery;
  }

  createContinuousNotificationPort(): ContinuousNotificationPort {
    this.log.push('platform.adapters.notification');
    return this.notification;
  }
}

class CountingPlatformFactory extends RecordingPlatformFactory {
  readonly countingNetworkRecovery: CountingNetworkRecovery;
  readonly countingNotification: CountingNotification;

  constructor(log: string[], profile?: Profile) {
    super(log, profile);
    this.countingNetworkRecovery = new CountingNetworkRecovery();
    this.countingNotification = new CountingNotification(log);
  }

  async createNetworkRecoveryPort(): Promise<NetworkRecoveryPort> {
    this.log.push('platform.adapters.network');
    return this.countingNetworkRecovery;
  }

  createContinuousNotificationPort(): ContinuousNotificationPort {
    this.log.push('platform.adapters.notification');
    return this.countingNotification;
  }
}

class RpcHashCryptoPort implements VpnRpcCryptoPort {
  async prepare(): Promise<void> {
  }

  async rootHmac(input: Uint8Array): Promise<Uint8Array> {
    return this.hash(17, new Uint8Array(0), input);
  }

  async derivedHmac(key: Uint8Array, input: Uint8Array): Promise<Uint8Array> {
    return this.hash(53, key, input);
  }

  private hash(seed: number, key: Uint8Array, input: Uint8Array): Uint8Array {
    const bytes: Uint8Array = new Uint8Array(32);
    let accumulator: number = seed;
    for (let index: number = 0; index < key.length; index += 1) {
      accumulator = (accumulator + key[index] + index + 3) & 0xff;
    }
    for (let index: number = 0; index < input.length; index += 1) {
      accumulator = (accumulator + input[index] + index + 11) & 0xff;
    }
    for (let index: number = 0; index < bytes.length; index += 1) {
      const keyByte: number = key.length === 0 ? seed : key[index % key.length];
      const inputByte: number = input.length === 0 ? seed : input[index % input.length];
      accumulator = (accumulator + keyByte + inputByte + (index * 13)) & 0xff;
      bytes[index] = accumulator ^ ((keyByte + inputByte + index) & 0xff);
    }
    return bytes;
  }
}

class QueueRandomPort implements VpnRpcRandomPort {
  private readonly chunks: Uint8Array[];

  constructor(chunks: Uint8Array[]) {
    this.chunks = chunks.map((chunk: Uint8Array) => chunk.slice());
  }

  bytes(length: number): Uint8Array {
    const next: Uint8Array | undefined = this.chunks.shift();
    if (next === undefined || next.length !== length) {
      throw new Error('Missing random bytes.');
    }
    return next.slice();
  }
}

class UnusedRpcSocketConnection implements VpnRpcSocketConnectionPort {
  async send(_bytes: Uint8Array): Promise<void> {
    throw new Error('unused');
  }

  subscribeData(_listener: (bytes: Uint8Array) => void): number {
    return 1;
  }

  unsubscribeData(_id: number): void {
  }

  subscribeClose(_listener: () => void): number {
    return 2;
  }

  unsubscribeClose(_id: number): void {
  }

  subscribeError(_listener: () => void): number {
    return 3;
  }

  unsubscribeError(_id: number): void {
  }

  async close(): Promise<void> {
  }
}

class UnusedRpcClientFactory implements VpnRpcSocketClientFactoryPort {
  async connect(_address: string, _timeoutMs: number): Promise<VpnRpcSocketConnectionPort> {
    return new UnusedRpcSocketConnection();
  }
}

class UnusedRpcSocketServer implements VpnRpcSocketServerPort {
  async listen(_address: string, _listener: (connection: VpnRpcSocketConnectionPort) => void | Promise<void>): Promise<void> {
  }

  async close(): Promise<void> {
  }
}

class RecordingRpcPlatformBundle implements HarmonyVpnRpcPlatformBundle {
  readonly crypto: VpnRpcCryptoPort;
  readonly clientFactory: VpnRpcSocketClientFactoryPort;
  readonly server: VpnRpcSocketServerPort;
  readonly random: VpnRpcRandomPort;

  constructor(crypto: VpnRpcCryptoPort, random: VpnRpcRandomPort) {
    this.crypto = crypto;
    this.clientFactory = new UnusedRpcClientFactory();
    this.server = new UnusedRpcSocketServer();
    this.random = random;
  }
}

class RecordedRpcEvent {
  method: VpnRpcMethod = 'PING';
  sessionGeneration: number = 0;
  payloadText: string = '';
}

class RecordingRpcServerSession implements VpnRpcServerSessionPort {
  readonly log: string[];
  readonly events: RecordedRpcEvent[] = [];
  listenCalls: number = 0;
  closeCalls: number = 0;
  listenError?: Error;

  constructor(log: string[]) {
    this.log = log;
  }

  async listen(): Promise<void> {
    this.listenCalls += 1;
    this.log.push('rpc.listen');
    if (this.listenError !== undefined) {
      throw this.listenError;
    }
  }

  async publishEvent(method: VpnRpcMethod, sessionGeneration: number, _guards: VpnRpcGuards, payload: VpnRpcPayload): Promise<boolean> {
    const event: RecordedRpcEvent = new RecordedRpcEvent();
    event.method = method;
    event.sessionGeneration = sessionGeneration;
    event.payloadText = encodeVpnRpcBodyToText(payload);
    this.events.push(event);
    this.log.push(`rpc.event:${method}`);
    return true;
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
    this.log.push('rpc.close');
  }
}

class RecordingCoreProxyService implements CoreService {
  readonly queryGroupsCalls: CoreProxyQueryContext[] = [];
  readonly queryGroupCalls: string[] = [];
  readonly loadConfigurationCalls: string[] = [];
  readonly groups: CoreProxyGroupRef[];
  readonly groupSnapshots: Map<string, CoreProxyGroupSnapshot>;

  constructor(groups: CoreProxyGroupRef[], groupSnapshots: Map<string, CoreProxyGroupSnapshot>) {
    this.groups = groups;
    this.groupSnapshots = groupSnapshots;
  }

  async loadConfiguration(path: string): Promise<void> {
    this.loadConfigurationCalls.push(path);
  }

  hello(): string {
    return 'core';
  }

  async coreVersion(): Promise<string> {
    return 'test-core';
  }

  async validateConfiguration(_path: string): Promise<void> {
  }

  async startLocal(_options: import('@cmfa/shared').LocalOptions): Promise<import('@cmfa/shared').RuntimeSnapshot> {
    throw new Error('unused');
  }

  async stopRuntime(): Promise<import('@cmfa/shared').RuntimeSnapshot> {
    throw new Error('unused');
  }

  runtimeSnapshot(): import('@cmfa/shared').RuntimeSnapshot {
    throw new Error('unused');
  }

  async queryProxyGroups(context: CoreProxyQueryContext, _selectableOnly: boolean): Promise<CoreProxyGroupList> {
    this.queryGroupsCalls.push(context);
    const result = new CoreProxyGroupListRecord();
    result.profileHash = context.profileHash;
    result.revisionHash = context.revisionHash;
    result.sessionHash = context.sessionHash;
    result.generation = context.generation;
    result.groups = this.groups.map((group: CoreProxyGroupRef) => {
      const clone = new CoreProxyGroupRefRecord();
      clone.name = group.name;
      clone.type = group.type;
      return clone;
    });
    return result;
  }

  async queryProxyGroup(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyGroupResult> {
    this.queryGroupCalls.push(groupName);
    const group: CoreProxyGroupSnapshot | undefined = this.groupSnapshots.get(groupName);
    if (group === undefined) {
      throw new Error('missing group snapshot');
    }
    const result = new CoreProxyGroupResultRecord();
    result.profileHash = context.profileHash;
    result.revisionHash = context.revisionHash;
    result.sessionHash = context.sessionHash;
    result.generation = context.generation;
    const groupSnapshot = new CoreProxyGroupSnapshotRecord();
    groupSnapshot.name = group.name;
    groupSnapshot.type = group.type;
    groupSnapshot.selectedName = group.selectedName;
    groupSnapshot.nodes = group.nodes.map((node: CoreProxyNodeSummary) => {
      const clone = new CoreProxyNodeSummaryRecord();
      clone.name = node.name;
      clone.type = node.type;
      clone.isGroup = node.isGroup;
      clone.selected = node.selected;
      return clone;
    });
    result.group = groupSnapshot;
    return result;
  }

  async selectProxy(_context: CoreProxyQueryContext, _groupName: string, _memberName: string): Promise<CoreProxySelectionApplied> {
    throw new Error('unused');
  }

  async startProxyDelayTest(_context: CoreProxyQueryContext, _groupName: string): Promise<CoreProxyDelaySnapshot> {
    throw new Error('unused');
  }

  async readProxyDelayTest(_jobId: string): Promise<CoreProxyDelaySnapshot> {
    throw new Error('unused');
  }

  async cancelProxyDelayTest(_jobId: string): Promise<CoreProxyDelaySnapshot> {
    throw new Error('unused');
  }

  subscribe(_callback: (event: import('@cmfa/shared').CoreEvent) => void): number {
    return 1;
  }

  unsubscribe(_subscriptionId: number): void {
  }
}

class GraphCoreProxyService extends RecordingCoreProxyService {
  readonly topLevel: CoreProxyGroupRef[];
  readonly snapshots: Map<string, CoreProxyGroupSnapshot>;

  constructor(topLevel: CoreProxyGroupRef[], snapshots: Map<string, CoreProxyGroupSnapshot>) {
    super(topLevel, snapshots);
    this.topLevel = topLevel;
    this.snapshots = snapshots;
  }
}

class CountingNetworkRecovery implements NetworkRecoveryPort {
  private readonly listeners: Map<number, (status: NetworkStatus) => void> = new Map();
  private nextListenerId: number = 1;
  subscribeCalls: number = 0;
  unsubscribeCalls: number = 0;
  disposeCalls: number = 0;
  status: NetworkStatus = { usable: false, networkId: '' };

  currentNetwork(): NetworkStatus {
    return {
      usable: this.status.usable,
      networkId: this.status.networkId
    };
  }

  subscribeUsableNetwork(listener: (status: NetworkStatus) => void): number {
    const id: number = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(id, listener);
    this.subscribeCalls += 1;
    return id;
  }

  unsubscribeUsableNetwork(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
    this.unsubscribeCalls += 1;
  }

  async dispose(): Promise<void> {
    this.disposeCalls += 1;
    this.listeners.clear();
  }

  emitUsable(networkId: string): void {
    this.status = { usable: true, networkId };
    const listeners: Array<(status: NetworkStatus) => void> = [];
    this.listeners.forEach((listener: (status: NetworkStatus) => void) => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](this.currentNetwork());
    }
  }
}

class CountingNotification extends RecordingNotification {
  subscribeCalls: number = 0;
  unsubscribeCalls: number = 0;

  subscribeCancellation(listener: (sessionId: string) => void): number {
    this.subscribeCalls += 1;
    return super.subscribeCancellation(listener);
  }

  unsubscribeCancellation(subscriptionId: number): void {
    this.unsubscribeCalls += 1;
    super.unsubscribeCancellation(subscriptionId);
  }
}

class CountingTunRuntime extends RecordingTunRuntime {
  subscribeCalls: number = 0;
  unsubscribeCalls: number = 0;

  subscribe(listener: (event: TunRuntimeEvent) => void): number {
    this.subscribeCalls += 1;
    return super.subscribe(listener);
  }

  unsubscribe(subscriptionId: number): void {
    this.unsubscribeCalls += 1;
    super.unsubscribe(subscriptionId);
  }
}

class RecordingProxyCommandHandler implements VpnProxyCommandHandler {
  readonly queryGroupsCalls: ProxyRuntimeIdentity[] = [];
  readonly queryGroupCalls: string[] = [];
  readonly selectCalls: string[] = [];
  readonly startDelayCalls: string[] = [];
  readonly readDelayCalls: string[] = [];
  readonly cancelDelayCalls: string[] = [];
  readonly identity: ProxyRuntimeIdentity;
  readonly revisionHash: string;

  constructor(request: VpnStartRequest, revisionHash: string) {
    this.identity = createProxyRuntimeIdentity(request.profileId, request.versionId, revisionHash, request.sessionId);
    this.revisionHash = revisionHash;
  }

  async queryGroups(command: import('@cmfa/shared').VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult> {
    this.queryGroupsCalls.push(command.identity);
    return createProxyGroupListQuerySnapshot(command.identity, command.generation, [
      { name: 'Group A', type: 'Selector' }
    ]);
  }

  async queryGroup(command: import('@cmfa/shared').VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult> {
    this.queryGroupCalls.push(command.groupName);
    return createProxyGroupQuerySnapshot(createProxyGroupSnapshot(command.identity, command.generation, {
      name: 'Group A',
      type: 'Selector',
      selectedName: 'Node Alpha',
      nodes: [
        { name: 'Node Alpha', type: 'Direct', isGroup: false, selected: true },
        { name: 'Nested Group', type: 'Fallback', isGroup: true, selected: false }
      ]
    }));
  }

  async select(command: import('@cmfa/shared').VpnProxySelectCommand): Promise<ProxySelectionResult> {
    this.selectCalls.push(`${command.groupName}:${command.memberName}`);
    const snapshot = createProxyGroupSnapshot(command.identity, command.generation, {
      name: command.groupName,
      type: 'Selector',
      selectedName: command.memberName,
      nodes: [
        { name: 'Node Alpha', type: 'Direct', isGroup: false, selected: command.memberName === 'Node Alpha' },
        { name: 'Nested Group', type: 'Fallback', isGroup: true, selected: false }
      ]
    });
    return createProxySelectionAppliedNowResult(
      snapshot,
      createProxySelectionRecord(command.identity.profileId, command.groupName, command.memberName, command.identity.revisionId, '2026-08-16T12:00:00.000Z'),
      '2026-08-16T12:00:00.000Z'
    );
  }

  async startDelayTest(command: import('@cmfa/shared').VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> {
    this.startDelayCalls.push(command.groupName);
    return createProxyDelaySnapshotResult(
      command.identity,
      command.generation,
      command.groupName,
      'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
      'RUNNING',
      1,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      null,
      [createProxyDelayNodeResult(0, 'Node Alpha', 'Direct', 'TESTING', null, false)]
    );
  }

  async readDelayTest(command: import('@cmfa/shared').VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> {
    this.readDelayCalls.push(command.jobId);
    return createProxyDelaySnapshotResult(
      command.identity,
      command.generation,
      'Group A',
      command.jobId,
      'COMPLETED',
      1,
      1,
      1,
      1,
      0,
      0,
      0,
      0,
      0,
      [createProxyDelayNodeResult(0, 'Node Alpha', 'Direct', 'AVAILABLE', 42, true)]
    );
  }

  async cancelDelayTest(command: import('@cmfa/shared').VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> {
    this.cancelDelayCalls.push(command.jobId);
    return createProxyDelaySnapshotResult(
      command.identity,
      command.generation,
      'Group A',
      command.jobId,
      'CANCELLED',
      1,
      1,
      1,
      0,
      0,
      0,
      1,
      0,
      null,
      [createProxyDelayNodeResult(0, 'Node Alpha', 'Direct', 'CANCELLED', null, false)]
    );
  }
}

class BindingProxyLifecycle implements VpnProxyRuntimeLifecyclePort {
  readonly log: string[];
  readonly commandBus: VpnProxyCommandBus;
  readonly handler: RecordingProxyCommandHandler;

  constructor(log: string[], commandBus: VpnProxyCommandBus, handler: RecordingProxyCommandHandler) {
    this.log = log;
    this.commandBus = commandBus;
    this.handler = handler;
  }

  async activate(request: VpnStartRequest): Promise<void> {
    this.log.push(`proxy.activate:${request.sessionId}`);
    this.commandBus.bind(
      createProxyRuntimeIdentity(request.profileId, request.versionId, this.handler.revisionHash, request.sessionId),
      this.handler
    );
  }

  invalidate(sessionId: string): void {
    this.log.push(`proxy.invalidate:${sessionId}`);
    this.commandBus.invalidate(sessionId);
  }

  async cancelAndDrainDelayTest(sessionId: string): Promise<void> {
    this.log.push(`proxy.drain:${sessionId}`);
  }

  async deactivate(sessionId: string): Promise<void> {
    this.log.push(`proxy.deactivate:${sessionId}`);
    await this.commandBus.deactivate(sessionId);
  }
}

interface RpcEnabledCompositionDependencies extends VpnExtensionCompositionDependencies {
  createVpnRpcPlatformBundle?: () => HarmonyVpnRpcPlatformBundle;
  createVpnRpcServerSession?: (
    crypto: VpnRpcCryptoPort,
    random: VpnRpcRandomPort,
    scheduler: VpnRpcSchedulerPort,
    socketServer: VpnRpcSocketServerPort,
    address: string,
    handler: (request: VpnRpcBody) => Promise<VpnRpcBody>
  ) => VpnRpcServerSessionPort;
  createVpnRpcServer?: (
    session: VpnRpcServerSessionPort,
    runtime: VpnRpcRuntimeDispatchPort,
    scheduler: VpnRpcSchedulerPort,
    random: VpnRpcRandomPort,
    serverInstance: string
  ) => VpnRpcServerPort;
}

class CoreProxyGroupRefRecord implements CoreProxyGroupRef {
  name: string = '';
  type: import('@cmfa/shared').CoreProxyType = 'Direct';
}

class CoreProxyNodeSummaryRecord implements CoreProxyNodeSummary {
  name: string = '';
  type: import('@cmfa/shared').CoreProxyType = 'Direct';
  isGroup: boolean = false;
  selected: boolean = false;
}

class CoreProxyGroupSnapshotRecord implements CoreProxyGroupSnapshot {
  name: string = '';
  type: import('@cmfa/shared').CoreProxyType = 'Direct';
  selectedName: string = '';
  nodes: CoreProxyNodeSummary[] = [];
}

class CoreProxyGroupListRecord implements CoreProxyGroupList {
  schemaVersion: '1.0.0' = '1.0.0';
  kind: 'GROUP_LIST' = 'GROUP_LIST';
  profileHash: string = '';
  revisionHash: string = '';
  sessionHash: string | null = null;
  generation: number = 0;
  groups: CoreProxyGroupRef[] = [];
}

class CoreProxyGroupResultRecord implements CoreProxyGroupResult {
  schemaVersion: '1.0.0' = '1.0.0';
  kind: 'GROUP_SNAPSHOT' = 'GROUP_SNAPSHOT';
  profileHash: string = '';
  revisionHash: string = '';
  sessionHash: string | null = null;
  generation: number = 0;
  group: CoreProxyGroupSnapshot = new CoreProxyGroupSnapshotRecord();
}

interface TestPlatformFactoryLike {
  create(): Promise<PlatformGraph>;
  createNetworkRecoveryPort(): Promise<NetworkRecoveryPort>;
  createContinuousNotificationPort(): ContinuousNotificationPort;
}

class RpcEnabledCompositionDependenciesRecord implements RpcEnabledCompositionDependencies {
  registry?: VpnSessionRegistry;
  commandBus?: VpnProxyCommandBus;
  createPlatformFactory?: (context: common.VpnExtensionContext | undefined) => TestPlatformFactoryLike;
  createPlatformPort?: (sessionId: string, createOperationId: () => string) => VpnPlatformSessionPort;
  createTunRuntime?: (configPath: string) => TunRuntimePort;
  createCoreService?: () => CoreService;
  createProxyLifecycle?: (graph: PlatformGraph, commandBus: VpnProxyCommandBus) => VpnProxyRuntimeLifecyclePort;
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
    handler: (request: VpnRpcBody) => Promise<VpnRpcBody>
  ) => VpnRpcServerSessionPort;
  createVpnRpcServer?: (
    session: VpnRpcServerSessionPort,
    runtime: VpnRpcRuntimeDispatchPort,
    scheduler: VpnRpcSchedulerPort,
    random: VpnRpcRandomPort,
    serverInstance: string
  ) => VpnRpcServerPort;

  constructor(base: VpnExtensionCompositionDependencies) {
    this.registry = base.registry;
    this.commandBus = base.commandBus;
    this.createPlatformFactory = base.createPlatformFactory;
    this.createPlatformPort = base.createPlatformPort;
    this.createTunRuntime = base.createTunRuntime;
    this.createCoreService = base.createCoreService;
    this.createProxyLifecycle = base.createProxyLifecycle;
    this.createCoordinator = base.createCoordinator;
    this.createClock = base.createClock;
    this.createScheduler = base.createScheduler;
    this.createEvidenceJournal = base.createEvidenceJournal;
  }
}

class RpcServerHolder {
  server?: VpnRpcServer;

  require(): VpnRpcServer {
    const server: VpnRpcServer | undefined = this.server;
    if (server === undefined) {
      throw new Error('VPN RPC server was not created.');
    }
    return server;
  }
}

class RpcTopologyRecord {
  groups: CoreProxyGroupRef[] = [];
  groupSnapshots: Map<string, CoreProxyGroupSnapshot> = new Map<string, CoreProxyGroupSnapshot>();
}

function createGroupRef(name: string, type: import('@cmfa/shared').CoreProxyType): CoreProxyGroupRef {
  const group = new CoreProxyGroupRefRecord();
  group.name = name;
  group.type = type;
  return group;
}

function createNode(name: string, type: import('@cmfa/shared').CoreProxyType, isGroup: boolean, selected: boolean): CoreProxyNodeSummary {
  const node = new CoreProxyNodeSummaryRecord();
  node.name = name;
  node.type = type;
  node.isGroup = isGroup;
  node.selected = selected;
  return node;
}

function createGroupSnapshot(name: string, type: import('@cmfa/shared').CoreProxyType, selectedName: string, nodes: CoreProxyNodeSummary[]): CoreProxyGroupSnapshot {
  const group = new CoreProxyGroupSnapshotRecord();
  group.name = name;
  group.type = type;
  group.selectedName = selectedName;
  group.nodes = nodes;
  return group;
}

function buildChainGraph(groupCount: number): RpcTopologyRecord {
  const topology = new RpcTopologyRecord();
  if (groupCount <= 0) {
    return topology;
  }
  topology.groups = [createGroupRef('Group-0', 'Selector')];
  for (let index: number = 0; index < groupCount; index += 1) {
    const name: string = `Group-${index}`;
    const nextName: string = `Group-${index + 1}`;
    const nodes: CoreProxyNodeSummary[] = [];
    if (index + 1 < groupCount) {
      nodes.push(createNode(nextName, 'Selector', true, false));
    } else {
      nodes.push(createNode(`Node-${index}`, 'Direct', false, true));
    }
    topology.groupSnapshots.set(name, createGroupSnapshot(name, 'Selector', nodes[0].name, nodes));
  }
  return topology;
}

function buildWideGraph(topLevelCount: number): RpcTopologyRecord {
  const topology = new RpcTopologyRecord();
  const topLevel: CoreProxyGroupRef[] = [];
  for (let index: number = 0; index < topLevelCount; index += 1) {
    const name: string = `Wide-${index}`;
    topLevel.push(createGroupRef(name, 'Selector'));
    topology.groupSnapshots.set(name, createGroupSnapshot(name, 'Selector', '', []));
  }
  topology.groups = topLevel;
  return topology;
}

function buildSharedCycleGraph(): RpcTopologyRecord {
  const topology = new RpcTopologyRecord();
  topology.groups = [createGroupRef('Root A', 'Selector'), createGroupRef('Root B', 'Selector')];
  topology.groupSnapshots.set('Root A', createGroupSnapshot('Root A', 'Selector', 'Shared C', [
    createNode('Shared C', 'Fallback', true, true)
  ]));
  topology.groupSnapshots.set('Root B', createGroupSnapshot('Root B', 'Selector', 'Shared C', [
    createNode('Shared C', 'Fallback', true, true)
  ]));
  topology.groupSnapshots.set('Shared C', createGroupSnapshot('Shared C', 'Fallback', 'Root A', [
    createNode('Root A', 'Selector', true, true)
  ]));
  return topology;
}

function createRpcTopology(): RpcTopologyRecord {
  const topology = new RpcTopologyRecord();
  const topLevelGroup = new CoreProxyGroupRefRecord();
  topLevelGroup.name = 'Group A';
  topLevelGroup.type = 'Selector';
  topology.groups = [topLevelGroup];

  const topLevelSnapshot = new CoreProxyGroupSnapshotRecord();
  topLevelSnapshot.name = 'Group A';
  topLevelSnapshot.type = 'Selector';
  topLevelSnapshot.selectedName = 'Node Alpha';
  const topLevelNode = new CoreProxyNodeSummaryRecord();
  topLevelNode.name = 'Node Alpha';
  topLevelNode.type = 'Direct';
  topLevelNode.isGroup = false;
  topLevelNode.selected = true;
  const nestedNode = new CoreProxyNodeSummaryRecord();
  nestedNode.name = 'Nested Group';
  nestedNode.type = 'Fallback';
  nestedNode.isGroup = true;
  nestedNode.selected = false;
  topLevelSnapshot.nodes = [topLevelNode, nestedNode];
  topology.groupSnapshots.set('Group A', topLevelSnapshot);

  const nestedSnapshot = new CoreProxyGroupSnapshotRecord();
  nestedSnapshot.name = 'Nested Group';
  nestedSnapshot.type = 'Fallback';
  nestedSnapshot.selectedName = 'Node Beta';
  const nestedLeaf = new CoreProxyNodeSummaryRecord();
  nestedLeaf.name = 'Node Beta';
  nestedLeaf.type = 'Reject';
  nestedLeaf.isGroup = false;
  nestedLeaf.selected = true;
  nestedSnapshot.nodes = [nestedLeaf];
  topology.groupSnapshots.set('Nested Group', nestedSnapshot);
  return topology;
}

function createRpcRequest(
  requestOrdinal: number,
  method: VpnRpcMethod,
  sessionGeneration: number,
  guards: VpnRpcGuards,
  payload: VpnRpcPayload
): VpnRpcBody {
  return createVpnRpcBodyRequest(
    requestOrdinal,
    7,
    requestOrdinal,
    `00000000-0000-4000-8000-${requestOrdinal.toString().padStart(12, '0')}`,
    method,
    sessionGeneration,
    guards,
    payload
  );
}

function extractField(text: string, pattern: RegExp): string {
  const match: RegExpMatchArray | null = text.match(pattern);
  return match?.[1] ?? '';
}

class ThrowingPlatformFactory {
  async create(): Promise<PlatformGraph> {
    throw new Error('raw setup secret 12');
  }

  async createNetworkRecoveryPort(): Promise<NetworkRecoveryPort> {
    throw new Error('unused');
  }

  createContinuousNotificationPort(): ContinuousNotificationPort {
    throw new Error('unused');
  }
}

function buildProfile(profileId: string, versionId: string, availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID' = 'VALID'): Profile {
  return createProfile({
    id: profileId,
    name: `Profile ${profileId}`,
    sourceKind: 'REMOTE_URL',
    sourceDisplay: `https://${profileId}.example.com/subscription.yaml`,
    sourceSecretRef: `secret-${profileId}`,
    currentRevision: availability === 'INVALID'
      ? null
      : createProfileRevision(`profiles/${profileId}.yaml`, repeatDigest(profileId), 256, versionId),
    failedCandidate: null,
    availability,
    lastError: null,
    createdAt: '2026-08-16T12:00:00.000Z',
    updatedAt: '2026-08-16T12:00:00.000Z',
    lastSuccessfulUpdateAt: availability === 'INVALID' ? null : '2026-08-16T12:00:00.000Z'
  });
}

function repeatDigest(seed: string): string {
  let digest: string = '';
  while (digest.length < 64) {
    digest += seed;
  }
  return digest.substring(0, 64).replace(/[^0-9a-f]/gi, 'a');
}

function createWantParameters(profileId: string, versionId: string, sessionId: string): Record<string, Object> {
  const parameters = new WantParametersRecord() as Object as Record<string, Object>;
  parameters.profileId = profileId;
  parameters.versionId = versionId;
  parameters.sessionId = sessionId;
  return parameters;
}

function buildExactWant(
  profileId: string,
  versionId: string,
  sessionId: string,
  runId?: string
): Want {
  const parameters: Record<string, Object> = createWantParameters(profileId, versionId, sessionId);
  if (runId !== undefined) {
    parameters[EVIDENCE_RUN_ID_KEY] = runId;
  }
  return {
    bundleName: 'com.github.kr328.clash.harmony',
    abilityName: 'CmfaVpnExtensionAbility',
    parameters
  };
}

function buildWantWithParameters(parameters: Record<string, Object>): Want {
  return {
    bundleName: 'com.github.kr328.clash.harmony',
    abilityName: 'CmfaVpnExtensionAbility',
    parameters
  };
}

function buildRuntimeSnapshot(
  state: VpnRuntimeState,
  request: VpnStartRequest | null,
  failure: VpnFailure | null = null
): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state,
    activeRequest: request,
    activeHandle: request === null ? null : createTunHandle(31, 'vpn-1', request.sessionId),
    captureConfig: request === null ? null : createVpnCaptureConfig({
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
    tunSnapshot: null,
    notificationActive: state === 'RUNNING' || state === 'RECOVERING' || state === 'STOPPING',
    recoveryAttempt: state === 'RECOVERING' ? 1 : 0,
    scheduledRetryDelayMs: null,
    lastFailure: failure
  });
}

function buildRuntimeEvent(
  type: 'SNAPSHOT' | 'STATE_CHANGED' | 'FAILED' | 'RECOVERY_SCHEDULED' | 'STOPPED',
  state: VpnRuntimeState,
  request: VpnStartRequest,
  failure: VpnFailure | null = null
): VpnRuntimeEvent {
  return createVpnRuntimeEvent(type, buildRuntimeSnapshot(state, request, failure));
}

function buildRuntimeEventWithOptionalRequest(
  type: 'SNAPSHOT' | 'STATE_CHANGED' | 'FAILED' | 'RECOVERY_SCHEDULED' | 'STOPPED',
  state: VpnRuntimeState,
  request: VpnStartRequest | null,
  failure: VpnFailure | null = null
): VpnRuntimeEvent {
  return createVpnRuntimeEvent(type, buildRuntimeSnapshot(state, request, failure));
}

function createDependencies(
  registry: VpnSessionRegistry,
  platformFactory: RecordingPlatformFactory,
  platformPort: RecordingPlatformPort,
  tunRuntime: RecordingTunRuntime,
  createCoordinator?: (dependencies: VpnRuntimeCoordinatorDependencies) => VpnControllerPort,
  proxyLifecycle?: RecordingProxyLifecycle,
  commandBus?: VpnProxyCommandBus,
  evidenceJournal?: VpnEvidenceJournalPort
): VpnExtensionCompositionDependencies {
  const resolvedCommandBus: VpnProxyCommandBus = commandBus ?? new VpnProxyCommandBus();
  const resolvedProxyLifecycle: RecordingProxyLifecycle = proxyLifecycle ?? new RecordingProxyLifecycle(platformPort.log);
  return {
    registry,
    commandBus: resolvedCommandBus,
    createPlatformFactory: (_context: common.VpnExtensionContext | undefined) => {
      return platformFactory;
    },
    createPlatformPort: (_sessionId: string, _createOperationId: () => string) => {
      return platformPort;
    },
    createTunRuntime: (_configPath: string) => {
      return tunRuntime;
    },
    createProxyLifecycle: (_graph, bus) => {
      expect(bus === resolvedCommandBus).assertTrue();
      return resolvedProxyLifecycle;
    },
    createCoordinator: createCoordinator ?? ((dependencies) => {
      return new VpnRuntimeCoordinator(dependencies);
    }),
    createEvidenceJournal: () => {
      return evidenceJournal ?? new RecordingEvidenceJournal();
    },
    createClock: () => {
      return new FixedClock();
    },
    createScheduler: () => {
      return new ImmediateScheduler();
    }
  };
}

async function waitForCondition(predicate: () => boolean, maxTurns: number = 20): Promise<void> {
  for (let turn = 0; turn < maxTurns; turn += 1) {
    if (predicate()) {
      return;
    }
    await Promise.resolve();
  }
  expect().assertFail();
}

async function settleMicrotasks(turns: number = 6): Promise<void> {
  for (let turn = 0; turn < turns; turn += 1) {
    await Promise.resolve();
  }
}

function assertSubsequence(actual: string[], expected: string[]): void {
  let actualIndex: number = 0;
  for (let expectedIndex = 0; expectedIndex < expected.length; expectedIndex += 1) {
    while (actualIndex < actual.length && actual[actualIndex] !== expected[expectedIndex]) {
      actualIndex += 1;
    }
    expect(actualIndex < actual.length).assertTrue();
    actualIndex += 1;
  }
}

export default function vpnExtensionCompositionTestsuite() {
  describe('VpnExtensionCompositionTest', () => {
    it('startsWithTheExactCommittedVersionAndFollowsCoordinatorOrder', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const platformPort = new RecordingPlatformPort(log);
      const tunRuntime = new RecordingTunRuntime(log);
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(registry, platformFactory, platformPort, tunRuntime)
      );

      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      assertSubsequence(log, [
        'platform.adapters.graph',
        'platform.adapters.network',
        'platform.adapters.notification',
        'platform.protectProcess',
        'platform.create:session-1',
        'core.runtime.create',
        'tun.start:session-1',
        'notification.start:session-1'
      ]);
      expect(registry.snapshot().state).assertEqual('RUNNING');
      expect(registry.snapshot().lastFailure).assertNull();
    });

    it('injectsAStageLifecycleReporterIntoCoordinatorDependencies', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      let reporterInjected: boolean = false;
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(
          registry,
          platformFactory,
          new RecordingPlatformPort(log),
          new RecordingTunRuntime(log),
          (dependencies: VpnRuntimeCoordinatorDependencies) => {
            reporterInjected = dependencies.reportStageLifecycle !== undefined;
            return new VpnRuntimeCoordinator(dependencies);
          }
        )
      );

      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      expect(reporterInjected).assertTrue();
      expect(registry.snapshot().state).assertEqual('RUNNING');
    });

    it('claimsTheValidatedWantWhenTheVpnExtensionStartsInAFreshProcess', 0, async () => {
      const registry = new VpnSessionRegistry();
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(
          registry,
          platformFactory,
          new RecordingPlatformPort(log),
          new RecordingTunRuntime(log)
        )
      );

      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      expect(log.includes('platform.adapters.graph')).assertTrue();
      expect(log.includes('platform.create:session-1')).assertTrue();
      expect(log.includes('tun.start:session-1')).assertTrue();
      expect(registry.snapshot().state).assertEqual('RUNNING');
    });

    it('usesLocalDefaultsBeforePlatformSetupWhenRegistryAndCommandBusAreNotInjected', 0, async () => {
      const log: string[] = [];
      const request = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-1');
      const platformFactory = new RecordingPlatformFactory(log, buildProfile(request.profileId, request.versionId));
      const platformPort = new RecordingPlatformPort(log);
      const tunRuntime = new RecordingTunRuntime(log);
      const composition = new VpnExtensionComposition(undefined, {
        createPlatformFactory: (_context: common.VpnExtensionContext | undefined) => {
          return platformFactory;
        },
        createPlatformPort: (_sessionId: string, _createOperationId: () => string) => {
          return platformPort;
        },
        createTunRuntime: (_configPath: string) => {
          return tunRuntime;
        },
        createProxyLifecycle: (_graph, bus) => {
          expect(bus instanceof VpnProxyCommandBus).assertTrue();
          log.push('proxy.lifecycle.created');
          return new RecordingProxyLifecycle(log);
        },
        createClock: () => {
          return new FixedClock();
        },
        createScheduler: () => {
          return new ImmediateScheduler();
        }
      });

      await composition.start(buildExactWant(request.profileId, request.versionId, request.sessionId));

      assertSubsequence(log, [
        'platform.adapters.graph',
        'proxy.lifecycle.created',
        'proxy.activate:session-1'
      ]);
    });

    it('listensRpcBeforeBusinessReadinessAndServesStartingSnapshotsWithoutRawNames', 0, async () => {
      const request = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-rpc-starting');
      const registry = new VpnSessionRegistry();
      registry.beginPending(request);
      const log: string[] = [];
      const tunRuntime = new RecordingTunRuntime(log);
      tunRuntime.snapshotValue = createTunRuntimeSnapshot({
        sessionId: request.sessionId,
        state: 'STARTING',
        counters: createVpnCounters(0, 0, 0, 0),
        ingressTraces: [],
        failure: null
      });
      const platformFactory = new RecordingPlatformFactory(log, buildProfile(request.profileId, request.versionId));
      const topology = createRpcTopology();
      const rpcSession = new RecordingRpcServerSession(log);
      const rpcServerHolder = new RpcServerHolder();
      const coordinator = new BlockingStartCoordinator(
        request,
        [buildRuntimeEvent('STATE_CHANGED', 'STARTING', request), buildRuntimeEvent('STATE_CHANGED', 'RUNNING', request)]
      );
      const rpcBundle = new RecordingRpcPlatformBundle(
        new RpcHashCryptoPort(),
        new QueueRandomPort([new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 17, 18, 19, 20, 21, 22, 23, 24])])
      );
      const dependencies = new RpcEnabledCompositionDependenciesRecord(
        createDependencies(
          registry,
          platformFactory,
          new RecordingPlatformPort(log),
          tunRuntime,
          (_dependencies: VpnRuntimeCoordinatorDependencies) => coordinator
        )
      );
      dependencies.createCoreService = () => new RecordingCoreProxyService(topology.groups, topology.groupSnapshots);
      dependencies.createVpnRpcPlatformBundle = () => rpcBundle;
      dependencies.createVpnRpcServerSession = (_crypto, _random, _scheduler, _socketServer, _address, _handler) => rpcSession;
      dependencies.createVpnRpcServer = (session, runtime, scheduler, random, serverInstance) => {
        const server = new VpnRpcServer(session, runtime, scheduler, random, serverInstance);
        rpcServerHolder.server = server;
        return server;
      };
      const composition = new VpnExtensionComposition(undefined, dependencies);
      const startPromise: Promise<void> = composition.start(buildExactWant(request.profileId, request.versionId, request.sessionId));

      await waitForCondition(() => rpcSession.listenCalls === 1, 80);
      expect(log.indexOf('rpc.listen') >= 0).assertTrue();
      const startingSnapshot = await rpcServerHolder.require().handleRequest(
        createRpcRequest(1, 'GET_SNAPSHOT', 0, createVpnRpcGuards(null, null, null), createVpnRpcEmptyPayload())
      );
      expect(startingSnapshot.ok).assertTrue();
      const startingPayloadText: string = encodeVpnRpcBodyToText(startingSnapshot.payload);
      expect(startingPayloadText).assertContain('"state":"STARTING"');
      expect(startingPayloadText).assertContain('"catalogDigest":"');
      expect(startingPayloadText.includes('Group A')).assertFalse();
      expect(startingPayloadText.includes('Node Alpha')).assertFalse();
      coordinator.releaseStart();
      await startPromise;

      expect(rpcSession.events.length > 0).assertTrue();
      expect(rpcSession.events[0].method).assertEqual('RUNTIME_CHANGED');
      expect(rpcSession.events[0].payloadText).assertContain('"state":"STARTING"');
      expect(rpcSession.events.some((event: RecordedRpcEvent) => event.payloadText.includes('"state":"RUNNING"'))).assertTrue();
    });

    it('updatesCachedRpcSnapshotWhenCoordinatorPublishesStoppedWithoutAnActiveRequest', 0, async () => {
      const request = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-rpc-cache');
      const registry = new VpnSessionRegistry();
      registry.beginPending(request);
      const log: string[] = [];
      const tunRuntime = new RecordingTunRuntime(log);
      const platformFactory = new RecordingPlatformFactory(log, buildProfile(request.profileId, request.versionId));
      const topology = createRpcTopology();
      const rpcSession = new RecordingRpcServerSession(log);
      const rpcServerHolder = new RpcServerHolder();
      const coordinator = new ManualCoordinator(
        request,
        [buildRuntimeEvent('STATE_CHANGED', 'RUNNING', request)]
      );
      const rpcBundle = new RecordingRpcPlatformBundle(
        new RpcHashCryptoPort(),
        new QueueRandomPort([new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 17, 18, 19, 20, 21, 22, 23, 24])])
      );
      const dependencies = new RpcEnabledCompositionDependenciesRecord(
        createDependencies(
          registry,
          platformFactory,
          new RecordingPlatformPort(log),
          tunRuntime,
          (_dependencies: VpnRuntimeCoordinatorDependencies) => coordinator
        )
      );
      dependencies.createCoreService = () => new RecordingCoreProxyService(topology.groups, topology.groupSnapshots);
      dependencies.createVpnRpcPlatformBundle = () => rpcBundle;
      dependencies.createVpnRpcServerSession = (_crypto, _random, _scheduler, _socketServer, _address, _handler) => rpcSession;
      dependencies.createVpnRpcServer = (session, runtime, scheduler, random, serverInstance) => {
        const server = new VpnRpcServer(session, runtime, scheduler, random, serverInstance);
        rpcServerHolder.server = server;
        return server;
      };

      const composition = new VpnExtensionComposition(undefined, dependencies);
      await composition.start(buildExactWant(request.profileId, request.versionId, request.sessionId));
      const runningEvent: RecordedRpcEvent | undefined = rpcSession.events.find((event: RecordedRpcEvent) => {
        return event.payloadText.includes('"state":"RUNNING"');
      });
      expect(runningEvent !== undefined).assertTrue();
      if (runningEvent === undefined) {
        expect().assertFail();
        return;
      }

      coordinator.emit(buildRuntimeEventWithOptionalRequest('STOPPED', 'STOPPED', null));
      const snapshotResponse = await rpcServerHolder.require().handleRequest(
        createRpcRequest(1, 'GET_SNAPSHOT', runningEvent.sessionGeneration, createVpnRpcGuards(null, null, null), createVpnRpcEmptyPayload())
      );
      expect(snapshotResponse.ok).assertTrue();
      const payloadText: string = encodeVpnRpcBodyToText(snapshotResponse.payload);
      expect(payloadText).assertContain('"state":"STOPPED"');
      expect(payloadText.includes(`"sessionId":"${request.sessionId}"`)).assertFalse();
    });

    it('routesRpcCommandsThroughExtensionAuthorityAndDoesNotTreatTunReadyAsRunningEvent', 0, async () => {
      const request = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-rpc-running');
      const registry = new VpnSessionRegistry();
      registry.beginPending(request);
      const log: string[] = [];
      const tunRuntime = new RecordingTunRuntime(log);
      const platformFactory = new RecordingPlatformFactory(log, buildProfile(request.profileId, request.versionId));
      const commandBus = new VpnProxyCommandBus();
      const proxyHandler = new RecordingProxyCommandHandler(request, buildProfile(request.profileId, request.versionId).currentRevision!.sha256Digest);
      const topology = createRpcTopology();
      const rpcSession = new RecordingRpcServerSession(log);
      const rpcBundle = new RecordingRpcPlatformBundle(
        new RpcHashCryptoPort(),
        new QueueRandomPort([
          new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 17, 18, 19, 20, 21, 22, 23, 24]),
          new Uint8Array([
            31, 32, 33, 34, 35, 36, 37, 38,
            41, 42, 43, 44, 45, 46, 47, 48,
            51, 52, 53, 54, 55, 56, 57, 58,
            61, 62, 63, 64, 65, 66, 67, 68
          ])
        ])
      );
      const rpcServerHolder = new RpcServerHolder();
      const dependencies = new RpcEnabledCompositionDependenciesRecord(
        createDependencies(
          registry,
          platformFactory,
          new RecordingPlatformPort(log),
          tunRuntime,
          undefined,
          undefined,
          commandBus
        )
      );
      dependencies.createCoreService = () => new RecordingCoreProxyService(topology.groups, topology.groupSnapshots);
      dependencies.createProxyLifecycle = (_graph: PlatformGraph, bus: VpnProxyCommandBus) => new BindingProxyLifecycle(log, bus, proxyHandler);
      dependencies.createScheduler = () => new PassiveScheduler();
      dependencies.createVpnRpcPlatformBundle = () => rpcBundle;
      dependencies.createVpnRpcServerSession = (_crypto, _random, _scheduler, _socketServer, _address, _handler) => rpcSession;
      dependencies.createVpnRpcServer = (session, runtime, scheduler, random, serverInstance) => {
        const server = new VpnRpcServer(session, runtime, scheduler, random, serverInstance);
        rpcServerHolder.server = server;
        return server;
      };
      const composition = new VpnExtensionComposition(undefined, dependencies);
      await composition.start(buildExactWant(request.profileId, request.versionId, request.sessionId));
      const rpcServer: VpnRpcServer = rpcServerHolder.require();
      const runningEvent: RecordedRpcEvent | undefined = rpcSession.events.find((event: RecordedRpcEvent) => {
        return event.payloadText.includes('"state":"RUNNING"');
      });
      expect(runningEvent !== undefined).assertTrue();
      if (runningEvent === undefined) {
        expect().assertFail();
        return;
      }
      const profileHash: string = extractField(runningEvent.payloadText, /"profileHash":"([0-9a-f]{64})"/u);
      const revisionHash: string = extractField(runningEvent.payloadText, /"revisionHash":"([0-9a-f]{64})"/u);
      const catalogDigest: string = extractField(runningEvent.payloadText, /"catalogDigest":"([0-9a-f]{64})"/u);
      const sessionGeneration: number = runningEvent.sessionGeneration;
      const activeGuards = createVpnRpcGuards(profileHash, revisionHash, catalogDigest);
      const eventCountBeforeTunReady: number = rpcSession.events.length;
      tunRuntime.emit({
        sessionId: request.sessionId,
        snapshot: createTunRuntimeSnapshot({
          sessionId: request.sessionId,
          state: 'READY',
          counters: createVpnCounters(1, 2, 3, 4),
          ingressTraces: [],
          failure: null
        })
      });
      await settleMicrotasks();
      expect(rpcSession.events.length).assertEqual(eventCountBeforeTunReady);

      const catalogDigestResponse = await rpcServer.handleRequest(
        createRpcRequest(1, 'GET_CATALOG_DIGEST', sessionGeneration, createVpnRpcGuards(profileHash, revisionHash, null), createVpnRpcEmptyPayload())
      );
      expect(catalogDigestResponse.ok).assertTrue();

      const queryGroups = await rpcServer.handleRequest(
        createRpcRequest(2, 'QUERY_GROUPS', sessionGeneration, activeGuards, createVpnRpcEmptyPayload())
      );
      expect(queryGroups.ok).assertTrue();
      const groupId: string = extractField(encodeVpnRpcBodyToText(queryGroups.payload), /"groupId":"([0-9a-f]{64})"/u);
      expect(groupId.length).assertEqual(64);
      expect(encodeVpnRpcBodyToText(queryGroups.payload).includes('Group A')).assertFalse();

      const queryGroup = await rpcServer.handleRequest(
        createRpcRequest(3, 'QUERY_GROUP', sessionGeneration, activeGuards, createVpnRpcQueryGroupRequestPayload(groupId))
      );
      expect(queryGroup.ok).assertTrue();
      const nodeId: string = extractField(encodeVpnRpcBodyToText(queryGroup.payload), /"nodeId":"([0-9a-f]{64})"/u);
      expect(nodeId.length).assertEqual(64);
      expect(encodeVpnRpcBodyToText(queryGroup.payload).includes('Node Alpha')).assertFalse();

      const select = await rpcServer.handleRequest(
        createRpcRequest(4, 'SELECT_NODE', sessionGeneration, activeGuards, createVpnRpcSelectNodeRequestPayload(sessionGeneration, groupId, nodeId))
      );
      expect(select.ok).assertTrue();

      const startDelay = await rpcServer.handleRequest(
        createRpcRequest(5, 'START_DELAY_TEST', sessionGeneration, activeGuards, createVpnRpcDelayGroupRequestPayload(sessionGeneration, groupId))
      );
      expect(startDelay.ok).assertTrue();
      const rpcJobId: string = extractField(encodeVpnRpcBodyToText(startDelay.payload), /"jobId":"([0-9a-f]{64})"/u);
      expect(rpcJobId.length).assertEqual(64);

      const readDelay = await rpcServer.handleRequest(
        createRpcRequest(6, 'READ_DELAY_TEST', sessionGeneration, activeGuards, createVpnRpcDelayJobRequestPayload(rpcJobId))
      );
      expect(readDelay.ok).assertTrue();

      const stop = await rpcServer.handleRequest(
        createRpcRequest(7, 'STOP_VPN', sessionGeneration, activeGuards, createVpnRpcEmptyPayload())
      );
      expect(stop.ok).assertTrue();
      expect(proxyHandler.queryGroupsCalls.length).assertEqual(1);
      expect(proxyHandler.queryGroupCalls[0]).assertEqual('Group A');
      expect(proxyHandler.selectCalls[0]).assertEqual('Group A:Node Alpha');
      expect(proxyHandler.startDelayCalls[0]).assertEqual('Group A');
      expect(proxyHandler.readDelayCalls[0]).assertEqual('dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd');
    });

    it('rollsBackWhenRpcListenFailsAndClosesBeforeResourceRelease', 0, async () => {
      const request = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-rpc-fail');
      const registry = new VpnSessionRegistry();
      registry.beginPending(request);
      const log: string[] = [];
      const tunRuntime = new RecordingTunRuntime(log);
      const platformFactory = new RecordingPlatformFactory(log, buildProfile(request.profileId, request.versionId));
      const rpcSession = new RecordingRpcServerSession(log);
      rpcSession.listenError = new Error('address in use');
      const topology = createRpcTopology();
      const dependencies = new RpcEnabledCompositionDependenciesRecord(
        createDependencies(
          registry,
          platformFactory,
          new RecordingPlatformPort(log),
          tunRuntime
        )
      );
      dependencies.createCoreService = () => new RecordingCoreProxyService(topology.groups, topology.groupSnapshots);
      dependencies.createVpnRpcPlatformBundle = () => new RecordingRpcPlatformBundle(
        new RpcHashCryptoPort(),
        new QueueRandomPort([new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 17, 18, 19, 20, 21, 22, 23, 24])])
      );
      dependencies.createVpnRpcServerSession = (_crypto, _random, _scheduler, _socketServer, _address, _handler) => rpcSession;
      dependencies.createVpnRpcServer = (session, runtime, scheduler, random, serverInstance) =>
        new VpnRpcServer(session, runtime, scheduler, random, serverInstance);
      const composition = new VpnExtensionComposition(undefined, dependencies);

      await composition.start(buildExactWant(request.profileId, request.versionId, request.sessionId));

      expect(rpcSession.listenCalls).assertEqual(1);
      expect(rpcSession.closeCalls).assertEqual(1);
      assertSubsequence(log, ['rpc.listen', 'rpc.close']);
      expect(platformFactory.graph.closeCalls).assertEqual(1);
      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_CREATE_FAILED');
    });

    it('closesRpcServerBeforeCleanupAndDrainsServerOwnedDelayJobsOnDestroy', 0, async () => {
      const request = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-rpc-stop');
      const registry = new VpnSessionRegistry();
      registry.beginPending(request);
      const log: string[] = [];
      const tunRuntime = new RecordingTunRuntime(log);
      const platformFactory = new RecordingPlatformFactory(log, buildProfile(request.profileId, request.versionId));
      const commandBus = new VpnProxyCommandBus();
      const proxyHandler = new RecordingProxyCommandHandler(request, buildProfile(request.profileId, request.versionId).currentRevision!.sha256Digest);
      const topology = createRpcTopology();
      const rpcSession = new RecordingRpcServerSession(log);
      const rpcBundle = new RecordingRpcPlatformBundle(
        new RpcHashCryptoPort(),
        new QueueRandomPort([
          new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 17, 18, 19, 20, 21, 22, 23, 24]),
          new Uint8Array([
            31, 32, 33, 34, 35, 36, 37, 38,
            41, 42, 43, 44, 45, 46, 47, 48,
            51, 52, 53, 54, 55, 56, 57, 58,
            61, 62, 63, 64, 65, 66, 67, 68
          ])
        ])
      );
      const rpcServerHolder = new RpcServerHolder();
      const dependencies = new RpcEnabledCompositionDependenciesRecord(
        createDependencies(
          registry,
          platformFactory,
          new RecordingPlatformPort(log),
          tunRuntime,
          undefined,
          undefined,
          commandBus
        )
      );
      dependencies.createCoreService = () => new RecordingCoreProxyService(topology.groups, topology.groupSnapshots);
      dependencies.createProxyLifecycle = (_graph: PlatformGraph, bus: VpnProxyCommandBus) => new BindingProxyLifecycle(log, bus, proxyHandler);
      dependencies.createScheduler = () => new PassiveScheduler();
      dependencies.createVpnRpcPlatformBundle = () => rpcBundle;
      dependencies.createVpnRpcServerSession = (_crypto, _random, _scheduler, _socketServer, _address, _handler) => rpcSession;
      dependencies.createVpnRpcServer = (session, runtime, scheduler, random, serverInstance) => {
        const server = new VpnRpcServer(session, runtime, scheduler, random, serverInstance);
        rpcServerHolder.server = server;
        return server;
      };
      const composition = new VpnExtensionComposition(undefined, dependencies);
      await composition.start(buildExactWant(request.profileId, request.versionId, request.sessionId));
      const rpcServer: VpnRpcServer = rpcServerHolder.require();
      const runningEvent: RecordedRpcEvent | undefined = rpcSession.events.find((event: RecordedRpcEvent) => {
        return event.payloadText.includes('"state":"RUNNING"');
      });
      expect(runningEvent !== undefined).assertTrue();
      if (runningEvent === undefined) {
        expect().assertFail();
        return;
      }
      const profileHash: string = extractField(runningEvent.payloadText, /"profileHash":"([0-9a-f]{64})"/u);
      const revisionHash: string = extractField(runningEvent.payloadText, /"revisionHash":"([0-9a-f]{64})"/u);
      const catalogDigest: string = extractField(runningEvent.payloadText, /"catalogDigest":"([0-9a-f]{64})"/u);
      const sessionGeneration: number = runningEvent.sessionGeneration;
      const activeGuards = createVpnRpcGuards(profileHash, revisionHash, catalogDigest);
      const queryGroups = await rpcServer.handleRequest(
        createRpcRequest(1, 'QUERY_GROUPS', sessionGeneration, activeGuards, createVpnRpcEmptyPayload())
      );
      const groupId: string = extractField(encodeVpnRpcBodyToText(queryGroups.payload), /"groupId":"([0-9a-f]{64})"/u);
      await rpcServer.handleRequest(
        createRpcRequest(2, 'START_DELAY_TEST', sessionGeneration, activeGuards, createVpnRpcDelayGroupRequestPayload(sessionGeneration, groupId))
      );

      log.length = 0;
      await composition.stopForDestroy();

      expect(rpcSession.closeCalls).assertEqual(1);
      expect(proxyHandler.cancelDelayCalls.length).assertEqual(1);
      assertSubsequence(log, ['rpc.close', 'proxy.invalidate:session-rpc-stop', 'proxy.drain:session-rpc-stop', 'proxy.deactivate:session-rpc-stop', 'tun.dispose']);
      expect(registry.snapshot().state).assertEqual('STOPPED');
    });

    it('finalizesStopJournalBeforeReturningRpcStopAndDoesNotDuplicateDestroyStopRecords', 0, async () => {
      const request = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-rpc-journal-stop');
      const registry = new VpnSessionRegistry();
      registry.beginPending(request);
      const log: string[] = [];
      const tunRuntime = new RecordingTunRuntime(log);
      const platformFactory = new RecordingPlatformFactory(log, buildProfile(request.profileId, request.versionId));
      const topology = createRpcTopology();
      const rpcSession = new RecordingRpcServerSession(log);
      const rpcBundle = new RecordingRpcPlatformBundle(
        new RpcHashCryptoPort(),
        new QueueRandomPort([
          new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 17, 18, 19, 20, 21, 22, 23, 24]),
          new Uint8Array([
            31, 32, 33, 34, 35, 36, 37, 38,
            41, 42, 43, 44, 45, 46, 47, 48,
            51, 52, 53, 54, 55, 56, 57, 58,
            61, 62, 63, 64, 65, 66, 67, 68
          ])
        ])
      );
      const rpcServerHolder = new RpcServerHolder();
      const journalStorage = new CompositionJournalStorage();
      const evidenceJournal = new VpnEvidenceJournal(journalStorage, new CompositionJournalClock());
      const dependencies = new RpcEnabledCompositionDependenciesRecord(
        createDependencies(
          registry,
          platformFactory,
          new RecordingPlatformPort(log),
          tunRuntime,
          undefined,
          undefined,
          new VpnProxyCommandBus(),
          evidenceJournal
        )
      );
      dependencies.createCoreService = () => new RecordingCoreProxyService(topology.groups, topology.groupSnapshots);
      dependencies.createVpnRpcPlatformBundle = () => rpcBundle;
      dependencies.createVpnRpcServerSession = (_crypto, _random, _scheduler, _socketServer, _address, _handler) => rpcSession;
      dependencies.createVpnRpcServer = (session, runtime, scheduler, random, serverInstance) => {
        const server = new VpnRpcServer(session, runtime, scheduler, random, serverInstance);
        rpcServerHolder.server = server;
        return server;
      };
      const composition = new VpnExtensionComposition(undefined, dependencies);
      await composition.start(buildExactWant(request.profileId, request.versionId, request.sessionId));
      const rpcServer: VpnRpcServer = rpcServerHolder.require();
      const runningEvent: RecordedRpcEvent | undefined = rpcSession.events.find((event: RecordedRpcEvent) => {
        return event.payloadText.includes('"state":"RUNNING"');
      });
      expect(runningEvent !== undefined).assertTrue();
      if (runningEvent === undefined) {
        expect().assertFail();
        return;
      }
      const profileHash: string = extractField(runningEvent.payloadText, /"profileHash":"([0-9a-f]{64})"/u);
      const revisionHash: string = extractField(runningEvent.payloadText, /"revisionHash":"([0-9a-f]{64})"/u);
      const catalogDigest: string = extractField(runningEvent.payloadText, /"catalogDigest":"([0-9a-f]{64})"/u);
      const sessionGeneration: number = runningEvent.sessionGeneration;
      const activeGuards = createVpnRpcGuards(profileHash, revisionHash, catalogDigest);

      const stop = await rpcServer.handleRequest(
        createRpcRequest(1, 'STOP_VPN', sessionGeneration, activeGuards, createVpnRpcEmptyPayload())
      );
      expect(stop.ok).assertTrue();

      const afterRpcStop = evidenceJournal.snapshot();
      expect(afterRpcStop.lifecycle.state).assertEqual('stopped');
      expect(afterRpcStop.lifecycle.stopped).assertTrue();
      expect(afterRpcStop.records.filter((record) => record.kind === 'stop').length).assertEqual(1);

      await composition.stopForDestroy();
      await composition.stopForDestroy();

      const afterDestroy = evidenceJournal.snapshot();
      expect(afterDestroy.records.filter((record) => record.kind === 'stop').length).assertEqual(1);
      expect(journalStorage.writes.length > 0).assertTrue();
    });

    it('failsWideCatalogBeforeAnyChildQueryAndKeepsTraversalErrorRedacted', 0, async () => {
      const request = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-wide');
      const registry = new VpnSessionRegistry();
      registry.beginPending(request);
      const topology = buildWideGraph(4097);
      const coreService = new GraphCoreProxyService(topology.groups, topology.groupSnapshots);
      const dependencies = new RpcEnabledCompositionDependenciesRecord(
        createDependencies(
          registry,
          new RecordingPlatformFactory([], buildProfile(request.profileId, request.versionId)),
          new RecordingPlatformPort([]),
          new RecordingTunRuntime([])
        )
      );
      dependencies.createCoreService = () => coreService;
      const composition = new VpnExtensionComposition(undefined, dependencies);

      await composition.start(buildExactWant(request.profileId, request.versionId, request.sessionId));

      expect(coreService.queryGroupsCalls.length).assertEqual(1);
      expect(coreService.queryGroupCalls.length).assertEqual(0);
      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_CREATE_FAILED');
      expect(registry.snapshot().lastFailure?.detail.includes('Wide-4096') ?? false).assertFalse();
    });

    it('failsDeepCatalogBeforeQueryingPastDepthLimitAndKeepsCountsBounded', 0, async () => {
      const request = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-deep');
      const registry = new VpnSessionRegistry();
      registry.beginPending(request);
      const topology = buildChainGraph(18);
      const coreService = new GraphCoreProxyService(topology.groups, topology.groupSnapshots);
      const dependencies = new RpcEnabledCompositionDependenciesRecord(
        createDependencies(
          registry,
          new RecordingPlatformFactory([], buildProfile(request.profileId, request.versionId)),
          new RecordingPlatformPort([]),
          new RecordingTunRuntime([])
        )
      );
      dependencies.createCoreService = () => coreService;
      const composition = new VpnExtensionComposition(undefined, dependencies);

      await composition.start(buildExactWant(request.profileId, request.versionId, request.sessionId));

      expect(coreService.queryGroupCalls.length < 18).assertTrue();
      expect(coreService.queryGroupCalls.includes('Group-17')).assertFalse();
      expect(registry.snapshot().lastFailure?.detail.includes('Group-17') ?? false).assertFalse();
    });

    it('reusesCachedCycleTargetsAndAcceptsExactDepth16AndEntry4096Boundaries', 0, async () => {
      const cycleRequest = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-cycle');
      const cycleRegistry = new VpnSessionRegistry();
      cycleRegistry.beginPending(cycleRequest);
      const cycleTopology = buildSharedCycleGraph();
      const cycleCoreService = new GraphCoreProxyService(cycleTopology.groups, cycleTopology.groupSnapshots);
      const cycleCoordinator = new BlockingStartCoordinator(
        cycleRequest,
        [buildRuntimeEvent('STATE_CHANGED', 'STARTING', cycleRequest), buildRuntimeEvent('STATE_CHANGED', 'RUNNING', cycleRequest)]
      );
      const cycleDependencies = new RpcEnabledCompositionDependenciesRecord(
        createDependencies(
          cycleRegistry,
          new RecordingPlatformFactory([], buildProfile(cycleRequest.profileId, cycleRequest.versionId)),
          new RecordingPlatformPort([]),
          new RecordingTunRuntime([]),
          (_dependencies: VpnRuntimeCoordinatorDependencies) => cycleCoordinator
        )
      );
      cycleDependencies.createCoreService = () => cycleCoreService;
      const cycleComposition = new VpnExtensionComposition(undefined, cycleDependencies);
      const cycleStart = cycleComposition.start(buildExactWant(cycleRequest.profileId, cycleRequest.versionId, cycleRequest.sessionId));
      cycleCoordinator.releaseStart();
      await cycleStart;

      expect(cycleCoreService.queryGroupCalls.filter((name: string) => name === 'Shared C').length).assertEqual(1);
      expect(cycleCoreService.queryGroupCalls.filter((name: string) => name === 'Root A').length).assertEqual(1);

      const exactDepthRequest = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-depth16');
      const exactDepthRegistry = new VpnSessionRegistry();
      exactDepthRegistry.beginPending(exactDepthRequest);
      const exactDepthTopology = buildChainGraph(17);
      const exactDepthCoreService = new GraphCoreProxyService(exactDepthTopology.groups, exactDepthTopology.groupSnapshots);
      const exactDepthCoordinator = new BlockingStartCoordinator(
        exactDepthRequest,
        [buildRuntimeEvent('STATE_CHANGED', 'STARTING', exactDepthRequest), buildRuntimeEvent('STATE_CHANGED', 'RUNNING', exactDepthRequest)]
      );
      const exactDepthDependencies = new RpcEnabledCompositionDependenciesRecord(
        createDependencies(
          exactDepthRegistry,
          new RecordingPlatformFactory([], buildProfile(exactDepthRequest.profileId, exactDepthRequest.versionId)),
          new RecordingPlatformPort([]),
          new RecordingTunRuntime([]),
          (_dependencies: VpnRuntimeCoordinatorDependencies) => exactDepthCoordinator
        )
      );
      exactDepthDependencies.createCoreService = () => exactDepthCoreService;
      const exactDepthComposition = new VpnExtensionComposition(undefined, exactDepthDependencies);
      const depthStart = exactDepthComposition.start(buildExactWant(exactDepthRequest.profileId, exactDepthRequest.versionId, exactDepthRequest.sessionId));
      exactDepthCoordinator.releaseStart();
      await depthStart;
      expect(exactDepthCoreService.queryGroupCalls.length).assertEqual(17);

      const exactWideRequest = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-wide4096');
      const exactWideRegistry = new VpnSessionRegistry();
      exactWideRegistry.beginPending(exactWideRequest);
      const exactWideTopology = buildWideGraph(4096);
      const exactWideCoreService = new GraphCoreProxyService(exactWideTopology.groups, exactWideTopology.groupSnapshots);
      const exactWideCoordinator = new BlockingStartCoordinator(
        exactWideRequest,
        [buildRuntimeEvent('STATE_CHANGED', 'STARTING', exactWideRequest), buildRuntimeEvent('STATE_CHANGED', 'RUNNING', exactWideRequest)]
      );
      const exactWideDependencies = new RpcEnabledCompositionDependenciesRecord(
        createDependencies(
          exactWideRegistry,
          new RecordingPlatformFactory([], buildProfile(exactWideRequest.profileId, exactWideRequest.versionId)),
          new RecordingPlatformPort([]),
          new RecordingTunRuntime([]),
          (_dependencies: VpnRuntimeCoordinatorDependencies) => exactWideCoordinator
        )
      );
      exactWideDependencies.createCoreService = () => exactWideCoreService;
      const exactWideComposition = new VpnExtensionComposition(undefined, exactWideDependencies);
      const wideStart = exactWideComposition.start(buildExactWant(exactWideRequest.profileId, exactWideRequest.versionId, exactWideRequest.sessionId));
      exactWideCoordinator.releaseStart();
      await wideStart;
      expect(exactWideCoreService.queryGroupCalls.length).assertEqual(4096);
    });

    it('failsClosedForMalformedAndStaleWants', 0, async () => {
      const missingRegistry = new VpnSessionRegistry();
      const missingLog: string[] = [];
      const missingFactory = new RecordingPlatformFactory(missingLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const missingComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(missingRegistry, missingFactory, new RecordingPlatformPort(missingLog), new RecordingTunRuntime(missingLog))
      );

      await missingComposition.start({
        bundleName: 'com.github.kr328.clash.harmony',
        abilityName: 'CmfaVpnExtensionAbility',
        parameters: {
          profileId: 'profile-1',
          sessionId: 'session-1'
        }
      });
      expect(missingLog.length).assertEqual(0);
      expect(missingRegistry.snapshot().state).assertEqual('STOPPED');

      const blankRegistry = new VpnSessionRegistry();
      blankRegistry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const blankLog: string[] = [];
      const blankComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(blankRegistry, new RecordingPlatformFactory(blankLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z')), new RecordingPlatformPort(blankLog), new RecordingTunRuntime(blankLog))
      );

      await blankComposition.start({
        bundleName: 'com.github.kr328.clash.harmony',
        abilityName: 'CmfaVpnExtensionAbility',
        parameters: {
          profileId: 'profile-1',
          versionId: '2026-08-16T12:00:00.000Z',
          sessionId: ''
        }
      });
      expect(blankLog.length).assertEqual(0);
      expect(blankRegistry.snapshot().state).assertEqual('STOPPED');
      expect(blankRegistry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_CONFIG_INVALID');

      const nullRegistry = new VpnSessionRegistry();
      nullRegistry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const nullLog: string[] = [];
      const nullComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(nullRegistry, new RecordingPlatformFactory(nullLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z')), new RecordingPlatformPort(nullLog), new RecordingTunRuntime(nullLog))
      );

      await nullComposition.start(new NullParametersWantRecord('profile-1', '2026-08-16T12:00:00.000Z', 'session-1') as Want);
      expect(nullLog.length).assertEqual(0);
      expect(nullRegistry.snapshot().state).assertEqual('STOPPED');
      expect(nullRegistry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_CONFIG_INVALID');

      const staleRegistry = new VpnSessionRegistry();
      staleRegistry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-live'
      });
      const staleLog: string[] = [];
      const staleComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(staleRegistry, new RecordingPlatformFactory(staleLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z')), new RecordingPlatformPort(staleLog), new RecordingTunRuntime(staleLog))
      );

      await staleComposition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-stale'));
      expect(staleLog.length).assertEqual(0);
      expect(staleRegistry.snapshot().state).assertEqual('AWAITING_CONSENT');
    });

    it('cloneValidatedVpnReplayWantPreservesTheValidatedRunIdOnly', 0, () => {
      const validReplay = cloneValidatedVpnReplayWant(
        buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1', VALID_EVIDENCE_RUN_ID)
      );
      const validParameters = validReplay?.parameters as Record<string, Object> | undefined;
      expect(validParameters?.[EVIDENCE_RUN_ID_KEY] as string ?? '').assertEqual(VALID_EVIDENCE_RUN_ID);

      const absentReplay = cloneValidatedVpnReplayWant(
        buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1', VALID_EVIDENCE_RUN_ID)
      );
      const absentParameters = absentReplay?.parameters as Record<string, Object> | undefined;
      expect(typeof absentParameters?.[EVIDENCE_RUN_ID_KEY] === 'string').assertTrue();
    });

    it('reversesCleanupAndPublishesRedactedFailureWhenInjectedStartStepsFail', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      platformFactory.notification.startError = new Error('raw notification secret 55');
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(registry, platformFactory, new RecordingPlatformPort(log), new RecordingTunRuntime(log))
      );

      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      assertSubsequence(log, [
        'platform.protectProcess',
        'platform.create:session-1',
        'core.runtime.create',
        'tun.start:session-1',
        'notification.start:session-1',
        'tun.stop',
        'platform.destroy:vpn-1',
        'notification.stop:session-1'
      ]);
      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(registry.snapshot().lastFailure?.detail.includes('raw notification secret 55') ?? false).assertFalse();
    });

    it('usesTheSameCleanupSequenceForUserRequestedAndSystemDestroy', 0, async () => {
      const firstRegistry = new VpnSessionRegistry();
      firstRegistry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const firstLog: string[] = [];
      const firstComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(firstRegistry, new RecordingPlatformFactory(firstLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z')), new RecordingPlatformPort(firstLog), new RecordingTunRuntime(firstLog))
      );
      await firstComposition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));
      firstRegistry.markUserStopRequested('session-1');

      firstLog.length = 0;
      await firstComposition.stopForDestroy();
      const userSequence: string = firstLog.join('>');

      const secondRegistry = new VpnSessionRegistry();
      secondRegistry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const secondLog: string[] = [];
      const secondComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(secondRegistry, new RecordingPlatformFactory(secondLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z')), new RecordingPlatformPort(secondLog), new RecordingTunRuntime(secondLog))
      );
      await secondComposition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      secondLog.length = 0;
      await secondComposition.stopForDestroy();
      const systemSequence: string = secondLog.join('>');

      expect(userSequence).assertEqual(systemSequence);
      expect(firstRegistry.snapshot().lastFailure).assertNull();
      expect(secondRegistry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_SYSTEM_REVOKED');
    });

    it('drainsDelayBeforeDeactivateTunDisposeAndGraphCloseDuringDestroy', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const proxyLifecycle = new RecordingProxyLifecycle(log);
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(
          registry,
          platformFactory,
          new RecordingPlatformPort(log),
          new RecordingTunRuntime(log),
          undefined,
          proxyLifecycle
        )
      );

      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));
      log.length = 0;
      await composition.stopForDestroy();

      assertSubsequence(log, [
        'proxy.invalidate:session-1',
        'proxy.drain:session-1',
        'proxy.deactivate:session-1',
        'tun.dispose'
      ]);
      expect(platformFactory.graph.closeCalls).assertEqual(1);
    });

    it('drainFailureBlocksDestroyResourceMutationAndAllowsRetry', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const proxyLifecycle = new RecordingProxyLifecycle(log);
      proxyLifecycle.drainError = new Error('delay drain leaked session-1');
      const tunRuntime = new RecordingTunRuntime(log);
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(
          registry,
          platformFactory,
          new RecordingPlatformPort(log),
          tunRuntime,
          undefined,
          proxyLifecycle
        )
      );

      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));
      log.length = 0;

      let firstError: Error | undefined = undefined;
      try {
        await composition.stopForDestroy();
      } catch (error) {
        firstError = error as Error;
      }

      expect(firstError !== undefined).assertTrue();
      expect(log.join('>')).assertContain('proxy.invalidate:session-1>proxy.drain:session-1');
      expect(log.includes('proxy.deactivate:session-1')).assertFalse();
      expect(log.includes('tun.dispose')).assertFalse();
      expect(platformFactory.graph.closeCalls).assertEqual(0);
      expect(registry.snapshot().state).assertEqual('ERROR');

      proxyLifecycle.drainError = undefined;
      await composition.stopForDestroy();

      expect(log.includes('proxy.deactivate:session-1')).assertTrue();
      expect(log.includes('tun.dispose')).assertTrue();
      expect(platformFactory.graph.closeCalls).assertEqual(1);
      expect(registry.snapshot().state).assertEqual('STOPPED');
    });

    it('deactivateFailureRejectsDestroyCleanupWithoutCompletingStopAndAllowsRetry', 0, async () => {
      const request = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-1');
      const registry = new VpnSessionRegistry();
      registry.beginPending(request);
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile(request.profileId, request.versionId));
      const proxyLifecycle = new RecordingProxyLifecycle(log);
      proxyLifecycle.deactivateError = new Error('raw deactivate secret 77');
      const coordinator = new ManualCoordinator(
        request,
        [buildRuntimeEvent('STATE_CHANGED', 'RUNNING', request)],
        [buildRuntimeEvent('STATE_CHANGED', 'STOPPING', request)]
      );
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(
          registry,
          platformFactory,
          new RecordingPlatformPort(log),
          new RecordingTunRuntime(log),
          (_dependencies: VpnRuntimeCoordinatorDependencies) => {
            return coordinator;
          },
          proxyLifecycle
        )
      );

      await composition.start(buildExactWant(request.profileId, request.versionId, request.sessionId));
      log.length = 0;

      let firstError: Error | undefined = undefined;
      try {
        await composition.stopForDestroy();
      } catch (error) {
        firstError = error as Error;
      }

      expect(firstError !== undefined).assertTrue();
      if (firstError !== undefined) {
        expect(firstError.message).assertEqual('VPN proxy lifecycle deactivation failed during composition cleanup.');
        expect(firstError.message.includes('raw deactivate secret 77')).assertFalse();
      }
      assertSubsequence(log, [
        'proxy.invalidate:session-1',
        'proxy.drain:session-1',
        'proxy.deactivate:session-1'
      ]);
      expect(platformFactory.graph.closeCalls).assertEqual(1);
      expect(registry.snapshot().state).assertEqual('STOPPING');

      proxyLifecycle.deactivateError = undefined;
      log.length = 0;
      await composition.stopForDestroy();

      expect(log.filter((entry) => entry === 'proxy.deactivate:session-1').length).assertEqual(1);
      expect(registry.snapshot().state).assertEqual('STOPPED');
    });

    it('sameSessionStartRetriesFailedStartCleanupBeforeCreatingFreshResources', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const platformPort = new RecordingPlatformPort(log);
      const tunRuntime = new RecordingTunRuntime(log);
      const proxyLifecycle = new RecordingProxyLifecycle(log);
      proxyLifecycle.activateError = new Error('activate failed');
      proxyLifecycle.drainError = new Error('delay drain leaked session-1');
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(
          registry,
          platformFactory,
          platformPort,
          tunRuntime,
          undefined,
          proxyLifecycle
        )
      );

      let firstError: Error | undefined = undefined;
      try {
        await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));
      } catch (error) {
        firstError = error as Error;
      }

      expect(firstError !== undefined).assertTrue();
      expect(log.filter((entry) => entry === 'platform.adapters.graph').length).assertEqual(1);
      expect(log.filter((entry) => entry === 'platform.adapters.notification').length).assertEqual(1);
      expect(log.filter((entry) => entry === 'tun.dispose').length).assertEqual(0);

      proxyLifecycle.activateError = undefined;
      proxyLifecycle.drainError = undefined;

      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      expect(log.filter((entry) => entry === 'platform.adapters.graph').length).assertEqual(2);
      expect(log.filter((entry) => entry === 'platform.adapters.notification').length).assertEqual(2);
      expect(log.filter((entry) => entry === 'tun.dispose').length).assertEqual(1);
      assertSubsequence(log, [
        'proxy.activate:session-1',
        'proxy.invalidate:session-1',
        'proxy.drain:session-1',
        'proxy.deactivate:session-1',
        'tun.dispose',
        'platform.adapters.graph',
        'platform.adapters.network',
        'platform.adapters.notification'
      ]);
      expect(registry.snapshot().state).assertEqual('RUNNING');
      expect(registry.snapshot().lastFailure).assertNull();
    });

    it('sameSessionStartRetriesDeactivateFailedCleanupBeforeFreshStartup', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const platformPort = new RecordingPlatformPort(log);
      const tunRuntime = new RecordingTunRuntime(log);
      const proxyLifecycle = new RecordingProxyLifecycle(log);
      proxyLifecycle.activateError = new Error('activate failed');
      proxyLifecycle.deactivateError = new Error('raw deactivate secret 66');
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(
          registry,
          platformFactory,
          platformPort,
          tunRuntime,
          undefined,
          proxyLifecycle
        )
      );

      let firstError: Error | undefined = undefined;
      try {
        await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));
      } catch (error) {
        firstError = error as Error;
      }

      expect(firstError !== undefined).assertTrue();
      if (firstError !== undefined) {
        expect(firstError.message).assertEqual('VPN proxy lifecycle deactivation failed during composition cleanup.');
        expect(firstError.message.includes('raw deactivate secret 66')).assertFalse();
      }
      assertSubsequence(log, [
        'proxy.activate:session-1',
        'proxy.invalidate:session-1',
        'proxy.drain:session-1',
        'proxy.deactivate:session-1'
      ]);
      expect(log.includes('tun.dispose')).assertTrue();
      expect(platformFactory.graph.closeCalls).assertEqual(1);
      expect(registry.snapshot().activeRequest?.sessionId ?? '').assertEqual('session-1');

      proxyLifecycle.activateError = undefined;
      proxyLifecycle.deactivateError = undefined;
      log.length = 0;
      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      expect(log.filter((entry) => entry === 'proxy.deactivate:session-1').length).assertEqual(1);
      expect(registry.snapshot().state).assertEqual('RUNNING');
    });

    it('recordUnexpectedFailureIsNonThrowingAndPreservesRetryableStartCleanupState', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const platformPort = new RecordingPlatformPort(log);
      const tunRuntime = new RecordingTunRuntime(log);
      const proxyLifecycle = new RecordingProxyLifecycle(log);
      proxyLifecycle.activateError = new Error('activate failed');
      proxyLifecycle.drainError = new Error('delay drain leaked session-1');
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(
          registry,
          platformFactory,
          platformPort,
          tunRuntime,
          undefined,
          proxyLifecycle
        )
      );

      try {
        await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));
      } catch (_) {
      }

      const drainCallsBeforeUnexpectedFailure: number = log.filter((entry) => entry === 'proxy.drain:session-1').length;
      await composition.recordUnexpectedFailure(createVpnFailure('VPN_CREATE_FAILED', 'unexpected failed-start boundary'));

      expect(log.filter((entry) => entry === 'proxy.drain:session-1').length).assertEqual(drainCallsBeforeUnexpectedFailure);
      expect(log.filter((entry) => entry === 'tun.dispose').length).assertEqual(0);
      expect(platformFactory.graph.closeCalls).assertEqual(0);
      expect(registry.snapshot().activeRequest?.sessionId ?? '').assertEqual('session-1');

      proxyLifecycle.activateError = undefined;
      proxyLifecycle.drainError = undefined;
      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      expect(log.filter((entry) => entry === 'proxy.drain:session-1').length).assertEqual(drainCallsBeforeUnexpectedFailure + 1);
      expect(log.filter((entry) => entry === 'tun.dispose').length).assertEqual(1);
      expect(platformFactory.graph.closeCalls).assertEqual(1);
      expect(registry.snapshot().state).assertEqual('RUNNING');
    });

    it('keepsRedactedStopCleanupFailureInsteadOfOverwritingItDuringDestroy', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const platformPort = new RecordingPlatformPort(log);
      const tunRuntime = new RecordingTunRuntime(log);
      tunRuntime.stopError = new Error('raw tun stop secret 88');
      platformPort.destroyError = new Error('raw platform destroy secret 99');
      platformFactory.notification.stopError = new Error('raw notification stop secret 111');
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(registry, platformFactory, platformPort, tunRuntime)
      );

      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));
      log.length = 0;

      await composition.stopForDestroy();

      assertSubsequence(log, [
        'tun.stop',
        'platform.destroy:vpn-1',
        'notification.stop:session-1'
      ]);
      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_STOP_FAILED');
      expect(registry.snapshot().lastFailure?.detail.includes('raw tun stop secret 88') ?? false).assertFalse();
      expect(registry.snapshot().lastFailure?.detail.includes('raw platform destroy secret 99') ?? false).assertFalse();
      expect(registry.snapshot().lastFailure?.detail.includes('raw notification stop secret 111') ?? false).assertFalse();
    });

    it('disposesTunRuntimeOnceOnStopAndUnexpectedFailureAndClearsBridgeListeners', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const tunRuntime = new RecordingTunRuntime(log);
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(
          registry,
          new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z')),
          new RecordingPlatformPort(log),
          tunRuntime
        )
      );

      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));
      expect(tunRuntime.listenerCount() > 0).assertTrue();
      await composition.stopForDestroy();

      expect(tunRuntime.disposeCalls).assertEqual(1);
      expect(tunRuntime.listenerCount()).assertEqual(0);
      assertSubsequence(log, ['tun.stop', 'tun.dispose']);

      const failedRegistry = new VpnSessionRegistry();
      failedRegistry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-2'
      });
      const failedLog: string[] = [];
      const failedTunRuntime = new RecordingTunRuntime(failedLog);
      const proxyLifecycle = new RecordingProxyLifecycle(failedLog);
      proxyLifecycle.activateError = new Error('replay failed');
      const failedComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(
          failedRegistry,
          new RecordingPlatformFactory(failedLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z')),
          new RecordingPlatformPort(failedLog),
          failedTunRuntime,
          undefined,
          proxyLifecycle
        )
      );

      await failedComposition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-2'));

      expect(failedTunRuntime.disposeCalls).assertEqual(1);
      expect(failedTunRuntime.listenerCount()).assertEqual(0);
      assertSubsequence(failedLog, ['proxy.activate:session-2', 'proxy.deactivate:session-2', 'tun.dispose']);
    });

    it('abilityStartsOnlyOneCompositionAndAwaitsStopUntilStartSettles', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const fakeRunner = new FakeCompositionRunner();
      installVpnExtensionCompositionFactoryForTesting((_context) => {
        return fakeRunner;
      });

      const ability = new CmfaVpnExtensionAbility();
      const want = buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1');

      ability.onCreate(want);
      ability.onCreate(want);
      expect(fakeRunner.startCalls).assertEqual(1);

      ability.onDestroy();
      expect(fakeRunner.stopCalls).assertEqual(0);

      fakeRunner.releaseStart();
      await waitForCondition(() => fakeRunner.stopCalls === 1);
      resetVpnExtensionCompositionForTesting();
    });

    it('abilityStartsFromHarmonyOs6OnRequestWhenOnCreateHasNoLaunchParameters', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const fakeRunner = new FakeCompositionRunner();
      installVpnExtensionCompositionFactoryForTesting((_context) => {
        return fakeRunner;
      });
      const ability = new CmfaVpnExtensionAbility();
      const initializationWant: Want = {
        bundleName: 'com.github.kr328.clash.harmony',
        abilityName: 'CmfaVpnExtensionAbility',
        parameters: {}
      };

      ability.onCreate(initializationWant);
      ability.onRequest(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'), 1);

      expect(fakeRunner.startCalls).assertEqual(1);
      fakeRunner.releaseStart();
      await settleMicrotasks();
      resetVpnExtensionCompositionForTesting();
    });

    it('abilityStartsFromHarmonyOs6OnRequestWhenTheSystemAddsTransportMetadata', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const fakeRunner = new FakeCompositionRunner();
      installVpnExtensionCompositionFactoryForTesting((_context) => {
        return fakeRunner;
      });
      const ability = new CmfaVpnExtensionAbility();
      const requestWant: Want = {
        bundleName: 'com.github.kr328.clash.harmony',
        abilityName: 'CmfaVpnExtensionAbility',
        parameters: {
          profileId: 'profile-1',
          versionId: '2026-08-16T12:00:00.000Z',
          sessionId: 'session-1',
          abilityContextId: 1
        }
      };

      ability.onRequest(requestWant, 1);

      expect(fakeRunner.startCalls).assertEqual(1);
      fakeRunner.releaseStart();
      await settleMicrotasks();
      resetVpnExtensionCompositionForTesting();
    });

    it('abilityRecordsUnexpectedOnCreateRejectionsThroughTheRunnerSurface', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const fakeRunner = new RejectingCompositionRunner(registry);
      installVpnExtensionCompositionFactoryForTesting((_context) => {
        return fakeRunner;
      });

      const ability = new CmfaVpnExtensionAbility();
      const want = buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1');

      ability.onCreate(want);

      await waitForCondition(() => fakeRunner.recordedFailures.length === 1);
      expect(fakeRunner.startCalls).assertEqual(1);
      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_CREATE_FAILED');
      expect(registry.snapshot().lastFailure?.detail.includes('raw ability start secret 77') ?? false).assertFalse();
      resetVpnExtensionCompositionForTesting();
    });

    it('replaysLatestValidWantAfterDrainReleaseWithoutRequiringAThirdCallback', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const runnerByTag: Map<string, DeferredStopCompositionRunner> = new Map();
      const createdTags: string[] = [];
      installVpnExtensionCompositionFactoryForTesting((context) => {
        const tag: string = (context?.extensionAbilityInfo.name ?? 'missing') as string;
        createdTags.push(tag);
        const runner = new DeferredStopCompositionRunner(tag);
        runnerByTag.set(tag, runner);
        return runner;
      });

      const firstAbility = new CmfaVpnExtensionAbility();
      firstAbility.context = new FakeVpnExtensionContextRecord('first') as common.VpnExtensionContext;
      firstAbility.onCreate(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      const firstRunner = runnerByTag.get('first');
      expect(firstRunner !== undefined).assertTrue();
      firstAbility.onDestroy();
      await waitForCondition(() => (firstRunner?.stopCalls ?? 0) === 1);

      const secondAbility = new CmfaVpnExtensionAbility();
      secondAbility.context = new FakeVpnExtensionContextRecord('second') as common.VpnExtensionContext;
      secondAbility.onCreate(buildExactWant('profile-2', '2026-08-16T12:00:00.000Z', 'session-2a'));
      secondAbility.onRequest(
        buildExactWant(
          'profile-2',
          '2026-08-16T12:00:00.000Z',
          'session-2b',
          VALID_EVIDENCE_RUN_ID
        ),
        2
      );

      expect(createdTags.join('>')).assertEqual('first');
      expect(firstRunner?.startCalls ?? 0).assertEqual(1);

      firstRunner?.releaseStop();
      await waitForCondition(() => runnerByTag.has('second'));

      const secondRunner = runnerByTag.get('second');
      expect(secondRunner !== undefined).assertTrue();
      expect(createdTags.join('>')).assertEqual('first>second');
      expect(secondRunner?.startCalls ?? 0).assertEqual(1);
      const replayedWant = secondRunner?.startedWants[0];
      expect(parseVpnStartWant(replayedWant)?.sessionId ?? '').assertEqual('session-2b');
      const replayedParameters = replayedWant?.parameters as Record<string, Object> | undefined;
      expect(replayedParameters?.[EVIDENCE_RUN_ID_KEY] as string ?? '').assertEqual(VALID_EVIDENCE_RUN_ID);

      secondAbility.onDestroy();
      await waitForCondition(() => (secondRunner?.stopCalls ?? 0) === 1);
      secondRunner?.releaseStop();
      resetVpnExtensionCompositionForTesting();
    });

    it('cancelsQueuedDrainReplayWhenTheWaitingAbilityIsDestroyed', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const runnerByTag: Map<string, DeferredStopCompositionRunner> = new Map();
      installVpnExtensionCompositionFactoryForTesting((context) => {
        const tag: string = (context?.extensionAbilityInfo.name ?? 'missing') as string;
        const runner = new DeferredStopCompositionRunner(tag);
        runnerByTag.set(tag, runner);
        return runner;
      });

      const firstAbility = new CmfaVpnExtensionAbility();
      firstAbility.context = new FakeVpnExtensionContextRecord('first') as common.VpnExtensionContext;
      firstAbility.onCreate(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));
      const firstRunner = runnerByTag.get('first');
      expect(firstRunner !== undefined).assertTrue();
      firstAbility.onDestroy();
      await waitForCondition(() => (firstRunner?.stopCalls ?? 0) === 1);

      const secondAbility = new CmfaVpnExtensionAbility();
      secondAbility.context = new FakeVpnExtensionContextRecord('second') as common.VpnExtensionContext;
      secondAbility.onCreate(buildExactWant('profile-2', '2026-08-16T12:00:00.000Z', 'session-2'));
      secondAbility.onDestroy();
      firstRunner?.releaseStop();
      await settleMicrotasks(10);

      expect(runnerByTag.has('second')).assertFalse();
      resetVpnExtensionCompositionForTesting();
    });

    it('releasesCoordinatorAndNetworkSubscriptionsExactlyOnceAcrossDestroyAndFailedStart', 0, async () => {
      const request = createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-cleanup');
      const registry = new VpnSessionRegistry();
      registry.beginPending(request);
      const log: string[] = [];
      const platformFactory = new CountingPlatformFactory(log, buildProfile(request.profileId, request.versionId));
      const tunRuntime = new CountingTunRuntime(log);
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(registry, platformFactory, new RecordingPlatformPort(log), tunRuntime)
      );

      await composition.start(buildExactWant(request.profileId, request.versionId, request.sessionId));
      await composition.stopForDestroy();
      await composition.stopForDestroy();

      expect(platformFactory.countingNetworkRecovery.subscribeCalls).assertEqual(1);
      expect(platformFactory.countingNetworkRecovery.unsubscribeCalls).assertEqual(1);
      expect(platformFactory.countingNetworkRecovery.disposeCalls).assertEqual(1);
      expect(platformFactory.countingNotification.subscribeCalls).assertEqual(1);
      expect(platformFactory.countingNotification.unsubscribeCalls).assertEqual(1);
      expect(tunRuntime.subscribeCalls).assertEqual(1);
      expect(tunRuntime.unsubscribeCalls).assertEqual(1);
      platformFactory.countingNetworkRecovery.emitUsable('late-net');
      expect(registry.snapshot().state).assertEqual('STOPPED');

      const failedRegistry = new VpnSessionRegistry();
      failedRegistry.beginPending(createVpnStartRequest('profile-1', '2026-08-16T12:00:00.000Z', 'session-fail'));
      const failedLog: string[] = [];
      const failedPlatformFactory = new CountingPlatformFactory(failedLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const failedTunRuntime = new CountingTunRuntime(failedLog);
      failedPlatformFactory.countingNotification.startError = new Error('notification failed');
      const failedComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(failedRegistry, failedPlatformFactory, new RecordingPlatformPort(failedLog), failedTunRuntime)
      );

      await failedComposition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-fail'));

      expect(failedPlatformFactory.countingNetworkRecovery.unsubscribeCalls).assertEqual(1);
      expect(failedPlatformFactory.countingNetworkRecovery.disposeCalls).assertEqual(1);
      expect(failedPlatformFactory.countingNotification.unsubscribeCalls).assertEqual(1);
      expect(failedTunRuntime.unsubscribeCalls).assertEqual(1);
    });
  });
}
