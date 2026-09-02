import common from '@ohos.app.ability.common';
import { describe, expect, it } from '@ohos/hypium';
import type { Want } from '@kit.AbilityKit';
import { WorkSchedulerDriver, type PlatformGraph } from '@cmfa/platform';
import {
  ActiveProfileProxyResolver,
  buildVpnRpcCatalogFromCore,
  createAppError,
  createProfile,
  createProxyGroupQuerySnapshot,
  createProxyGroupSnapshot,
  createVpnRpcGuards,
  createVpnRpcBodyRequest,
  createProxyRuntimeIdentity,
  createProxyRejectedError,
  createProxyRejectedResult,
  createProfileRevision,
  createProxyRuntimeNotReadyError,
  createVpnRpcEmptyPayload,
  createVpnFailure,
  createVpnRpcRuntimeSnapshotPayload,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  ImportProfileUseCase,
  LeasedRemoteProfileRefresher,
  LocalRuntimeCoordinator,
  ManageProfileUseCases,
  ProfileApplication,
  ProfileCommitService,
  ProxyService,
  RefreshProfileUseCase,
  RefreshProfilesUseCase,
  type RefreshProfilesUseCaseDependencies,
  SerialCommandQueue,
  VpnProxyCommandBus,
  type AppError,
  type Clock,
  type CoreEvent,
  type CoreProxyDelaySnapshot,
  type CoreProxyGroupList,
  type CoreProxyGroupResult,
  type CoreProxyPort,
  type CoreProxyQueryContext,
  type CoreProxySelectionApplied,
  type CoreService,
  type IdGenerator,
  type LocalAcquireCommand,
  type LocalOptions,
  type LocalProfileAcquisition,
  type OneClickVpnConfirmationHandle,
  type OneClickVpnConfirmationResult,
  type OneClickVpnConfirmationPort,
  type ProfileApplicationDependencies,
  type Profile,
  type ProxyApplicationPort,
  type ProxyDelayResult,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyIdentityHasher,
  type ProxyRejectedResult,
  type ProxyReconcileResult,
  type ProxyRuntimeIdentity,
  type ProxySelectionPair,
  type ProxySelectionRecord,
  type ProxySelectionRepository,
  type ProxySelectionResult,
  type ProfileContentStore,
  type ProfileRefreshLeasePort,
  type ProfileRepository,
  type ProfileRevision,
  type ProfileSourceGateway,
  type RemoteAcquireCommand,
  type RemoteProfileAcquisition,
  type RuntimeSnapshot,
  type StagedSource,
  type SubscriptionSecretStore,
  type VpnControllerPort,
  type VpnRpcBody,
  type VpnRpcCryptoPort,
  type VpnRpcClientContext,
  type VpnRpcClientPort,
  type VpnRpcEventListener,
  type VpnRpcGuards,
  type VpnRpcMethod,
  type VpnRpcPayload,
  type VpnRpcTrafficCounters,
  type VpnRpcRandomPort,
  type VpnRpcSocketClientFactoryPort,
  type VpnRpcSocketConnectionPort,
  type VpnRpcSocketServerPort,
  type VpnProxyCancelDelayTestCommand,
  type VpnProxyCommandHandler,
  type VpnControllerStartResult,
  type VpnControllerStopResult,
  type VpnProxyQueryGroupCommand,
  type VpnProxyQueryGroupsCommand,
  type VpnProxyReadDelayTestCommand,
  type VpnProxySelectCommand,
  type VpnProxyStartDelayTestCommand,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot,
  type VpnStartRequest
} from '@cmfa/shared';
import type { HarmonyVpnRpcPlatformBundle } from '@cmfa/platform';
import type { ApplicationComposition, ApplicationCompositionState } from '../main/ets/bootstrap/ApplicationComposition';
import {
  applyPhase1LaunchWant,
  buildForwardedVpnExtensionWant,
  createApplicationComposition,
  getPhase1LaunchContext,
  type ApplicationCompositionDependencies,
  type Phase1LaunchContext
} from '../main/ets/bootstrap/CoreComposition';
import { HarmonyVpnController, type VpnExtensionAbilityApi } from '../main/ets/vpn/HarmonyVpnController';
import { VpnSessionRegistry } from '../main/ets/vpn/VpnSessionRegistry';
import {
  installVpnExtensionCompositionFactoryForTesting,
  resolveVpnExtensionComposition,
  resetVpnExtensionCompositionForTesting,
  VpnExtensionComposition
} from '../main/ets/vpn/VpnExtensionComposition';

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private resolveRef?: (value: T) => void;
  private rejectRef?: (error: Error) => void;

  constructor() {
    this.promise = new Promise<T>((resolve, reject) => {
      this.resolveRef = resolve;
      this.rejectRef = reject;
    });
  }

  resolve(value: T): void {
    this.resolveRef?.(value);
  }

  reject(error: Error): void {
    this.rejectRef?.(error);
  }
}

class FixedClock implements Clock {
  private readonly timestamps: string[];
  private index: number = 0;

  constructor(...timestamps: string[]) {
    this.timestamps = timestamps;
  }

  now(): string {
    const safeIndex: number = Math.min(this.index, this.timestamps.length - 1);
    const next: string = this.timestamps[safeIndex];
    this.index += 1;
    return next;
  }
}

class FixedIdGenerator implements IdGenerator {
  nextId(): string {
    return 'generated-id';
  }
}

class InertRepository implements ProfileRepository {
  async list(): Promise<Profile[]> {
    return [];
  }

  async get(_id: string): Promise<Profile | undefined> {
    return undefined;
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

class SeededRepository implements ProfileRepository {
  private readonly profile: Profile;
  private readonly activeId: string;

  constructor(profile: Profile) {
    this.profile = profile;
    this.activeId = profile.id;
  }

  async list(): Promise<Profile[]> {
    return [this.profile];
  }

  async get(id: string): Promise<Profile | undefined> {
    return id === this.profile.id ? this.profile : undefined;
  }

  async save(_profile: Profile): Promise<void> {
  }

  async deleteAndClearActive(_id: string): Promise<void> {
  }

  async getActiveId(): Promise<string | undefined> {
    return this.activeId;
  }

  async setActiveId(_id: string | undefined): Promise<void> {
  }
}

class InertContentStore implements ProfileContentStore {
  reconcileCallCount: number = 0;

  async retain(_profileId: string, _staged: StagedSource, _kind: 'CURRENT' | 'FAILED_CANDIDATE'): Promise<ProfileRevision> {
    throw new Error('retain should stay unused in composition tests');
  }

  async discard(_staged: StagedSource): Promise<void> {
  }

  async removeRevision(_revision: ProfileRevision): Promise<void> {
  }

  async removeProfile(_profileId: string): Promise<void> {
  }

  async reconcile(_referenced: ProfileRevision[]): Promise<void> {
    this.reconcileCallCount += 1;
  }

  resolveCorePath(revision: ProfileRevision): string {
    return revision.relativePath;
  }
}

class InertSourceGateway implements ProfileSourceGateway {
  async acquireLocal(_command: LocalAcquireCommand): Promise<LocalProfileAcquisition> {
    throw new Error('local acquire should stay unused in composition tests');
  }

  async acquireRemote(_command: RemoteAcquireCommand): Promise<RemoteProfileAcquisition> {
    throw new Error('remote acquire should stay unused in composition tests');
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

class InertProfileRefreshLeasePort implements ProfileRefreshLeasePort {
  tryAcquireCallCount: number = 0;

  async tryAcquire(_profileId: string, _ownerToken: string, _nowMs: number, _expiresAtMs: number): Promise<boolean> {
    this.tryAcquireCallCount += 1;
    return true;
  }

  async renew(_profileId: string, _ownerToken: string, _nowMs: number, _expiresAtMs: number): Promise<boolean> {
    return true;
  }

  async release(_profileId: string, _ownerToken: string): Promise<boolean> {
    return true;
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

class InertProxyApplicationPort implements ProxyApplicationPort {
  async listGroups(): Promise<ProxyGroupListQueryResult> {
    return createProxyRejectedResult(createProxyRejectedError('PROXY_RUNTIME_NOT_READY', true, '2026-08-11T12:00:00.000Z'));
  }

  async queryGroup(_groupName: string, _groupPath?: string[]): Promise<ProxyGroupQueryResult> {
    return createProxyRejectedResult(createProxyRejectedError('PROXY_RUNTIME_NOT_READY', true, '2026-08-11T12:00:00.000Z'));
  }

  async select(
    _groupName: string,
    _memberName: string,
    _snapshotGeneration: number,
    _groupPath?: string[]
  ): Promise<ProxySelectionResult> {
    return createProxyRejectedResult(createProxyRejectedError('PROXY_RUNTIME_NOT_READY', true, '2026-08-11T12:00:00.000Z'));
  }

  async reconcileActiveSelections(): Promise<ProxyReconcileResult> {
    return createProxyRejectedResult(createProxyRejectedError('PROXY_RUNTIME_NOT_READY', true, '2026-08-11T12:00:00.000Z'));
  }

  async startDelayTest(_groupName: string, _snapshotGeneration: number, _groupPath?: string[]): Promise<ProxyDelayResult> {
    return createProxyRejectedResult(createProxyRejectedError('PROXY_RUNTIME_NOT_READY', true, '2026-08-11T12:00:00.000Z'));
  }

  async readDelayTest(_jobId: string): Promise<ProxyDelayResult> {
    return createProxyRejectedResult(createProxyRejectedError('PROXY_RUNTIME_NOT_READY', true, '2026-08-11T12:00:00.000Z'));
  }

  async cancelDelayTest(_jobId: string): Promise<ProxyDelayResult> {
    return createProxyRejectedResult(createProxyRejectedError('PROXY_RUNTIME_NOT_READY', true, '2026-08-11T12:00:00.000Z'));
  }

  async cancelAndDrainDelayTest(): Promise<ProxyRejectedResult | undefined> {
    return undefined;
  }
}

class CancelledRecordingOneClickVpnConfirmationResult implements OneClickVpnConfirmationResult {
  kind: 'CANCELLED' = 'CANCELLED';
}

class RecordingOneClickVpnConfirmationHandle implements OneClickVpnConfirmationHandle {
  async wait(): Promise<OneClickVpnConfirmationResult> {
    return new CancelledRecordingOneClickVpnConfirmationResult();
  }

  markStartAccepted(): void {
  }

  cancel(): void {
  }
}

class RecordingOneClickVpnConfirmation implements OneClickVpnConfirmationPort {
  readonly armCalls: string[] = [];

  arm(expectedSessionId: string, timeoutMs: number): OneClickVpnConfirmationHandle {
    this.armCalls.push(`${expectedSessionId}:${timeoutMs}`);
    return new RecordingOneClickVpnConfirmationHandle();
  }
}

class RecordingPlatformGraph implements PlatformGraph {
  readonly repository: ProfileRepository;
  readonly profileRefreshLeasePort: InertProfileRefreshLeasePort;
  readonly proxySelectionRepository: ProxySelectionRepository;
  readonly proxyIdentityHasher: ProxyIdentityHasher;
  readonly contentStore: ProfileContentStore;
  readonly sourceGateway: ProfileSourceGateway;
  readonly secretStore: SubscriptionSecretStore;
  readonly clock: Clock;
  readonly idGenerator: IdGenerator;
  closeCallCount: number = 0;
  closeError?: Error;

  constructor(
    repository?: ProfileRepository,
    contentStore?: ProfileContentStore,
    sourceGateway?: ProfileSourceGateway,
    secretStore?: SubscriptionSecretStore
  ) {
    this.repository = repository ?? new InertRepository();
    this.profileRefreshLeasePort = new InertProfileRefreshLeasePort();
    this.proxySelectionRepository = new InertProxySelectionRepository();
    this.proxyIdentityHasher = new InertProxyIdentityHasher();
    this.contentStore = contentStore ?? new InertContentStore();
    this.sourceGateway = sourceGateway ?? new InertSourceGateway();
    this.secretStore = secretStore ?? new InertSecretStore();
    this.clock = new FixedClock('2026-08-11T12:00:00.000Z');
    this.idGenerator = new FixedIdGenerator();
  }

  async close(): Promise<void> {
    this.closeCallCount += 1;
    if (this.closeError !== undefined) {
      throw this.closeError;
    }
  }
}

class RecordingApplication extends ProfileApplication {
  initializeCallCount: number = 0;
  closeCallCount: number = 0;
  disposeCallCount: number = 0;
  initializeError?: Error;
  closeError?: Error;
  disposeError?: Error;

  constructor() {
    super(createProfileApplicationDependencies(new RuntimeAwareCoreService(), new RecordingPlatformGraph()));
  }

  async initialize(): Promise<void> {
    this.initializeCallCount += 1;
    if (this.initializeError !== undefined) {
      throw this.initializeError;
    }
  }

  async close(): Promise<void> {
    this.closeCallCount += 1;
    if (this.closeError !== undefined) {
      throw this.closeError;
    }
  }

  dispose(): void {
    this.disposeCallCount += 1;
    if (this.disposeError !== undefined) {
      throw this.disposeError;
    }
  }
}

class VpnStartCallRecord {
  profileId: string = '';
  versionId: string = '';
  sessionId: string = '';
}

class RecordingVpnController implements VpnControllerPort {
  readonly subscribeIds: number[] = [];
  readonly unsubscribeIds: number[] = [];
  readonly startCalls: VpnStartCallRecord[] = [];
  private nextSubscriptionId: number = 1;

  async start(profileId: string, versionId: string, sessionId: string): Promise<VpnControllerStartResult> {
    const callRecord: VpnStartCallRecord = new VpnStartCallRecord();
    callRecord.profileId = profileId;
    callRecord.versionId = versionId;
    callRecord.sessionId = sessionId;
    this.startCalls.push(callRecord);
    return {
      kind: 'STARTED',
      snapshot: this.snapshot()
    };
  }

  async stop(_sessionId?: string): Promise<VpnControllerStopResult> {
    return {
      kind: 'STOPPED',
      snapshot: this.snapshot()
    };
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

  subscribe(_listener: (event: VpnRuntimeEvent) => void): number {
    const subscriptionId: number = this.nextSubscriptionId;
    this.nextSubscriptionId += 1;
    this.subscribeIds.push(subscriptionId);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.unsubscribeIds.push(subscriptionId);
  }
}

class DisposableRecordingVpnController extends RecordingVpnController {
  disposeCallCount: number = 0;

  dispose(): void {
    this.disposeCallCount += 1;
  }
}

class LoggingApplication extends RecordingApplication {
  private readonly events: string[];

  constructor(events: string[]) {
    super();
    this.events = events;
  }

  async initialize(): Promise<void> {
    this.events.push('application.initialize');
    await super.initialize();
  }
}

class QueryBackedRecordingApplication extends RecordingApplication {
  private readonly queryProxyService: ProxyApplicationPort;

  constructor(proxyService: ProxyApplicationPort) {
    super();
    this.queryProxyService = proxyService;
  }

  async queryGroup(groupName: string): Promise<ProxyGroupQueryResult> {
    return await this.queryProxyService.queryGroup(groupName);
  }
}

class QueryOnlyRunningHandler implements VpnProxyCommandHandler {
  readonly queryGroupGenerations: number[] = [];

  async queryGroups(_command: VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult> {
    throw new Error('unused');
  }

  async queryGroup(command: VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult> {
    this.queryGroupGenerations.push(command.generation);
    return createProxyGroupQuerySnapshot(
      createProxyGroupSnapshot(command.identity, command.generation, {
        name: command.groupName,
        type: 'Selector',
        selectedName: 'Node A',
        nodes: [{
          name: 'Node A',
          type: 'Direct',
          isGroup: false,
          selected: true
        }]
      })
    );
  }

  async select(_command: VpnProxySelectCommand): Promise<ProxySelectionResult> {
    throw new Error('unused');
  }

  async startDelayTest(_command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> {
    throw new Error('unused');
  }

  async readDelayTest(_command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> {
    throw new Error('unused');
  }

  async cancelDelayTest(_command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> {
    throw new Error('unused');
  }
}

class DeferredRuntimeMirrorController extends RecordingVpnController {
  readonly events: string[];
  readonly initializeDeferred: DeferredValue<void> = new DeferredValue<void>();

  constructor(events: string[]) {
    super();
    this.events = events;
  }

  async initializeRuntimeMirror(): Promise<void> {
    this.events.push('controller.initialize.start');
    await this.initializeDeferred.promise;
    this.events.push('controller.initialize.done');
  }
}

class HydratingRuntimeMirrorController extends RecordingVpnController {
  private readonly registry: VpnSessionRegistry;
  private readonly commandBus: VpnProxyCommandBus;
  private readonly request: VpnStartRequest;

  constructor(registry: VpnSessionRegistry, commandBus: VpnProxyCommandBus, request: VpnStartRequest) {
    super();
    this.registry = registry;
    this.commandBus = commandBus;
    this.request = request;
  }

  async initializeRuntimeMirror(): Promise<void> {
    const identity: ProxyRuntimeIdentity = createProxyRuntimeIdentity(
      this.request.profileId,
      this.request.versionId,
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      this.request.sessionId
    );
    this.commandBus.bind(identity, new QueryOnlyRunningHandler());
    this.registry.hydrateBridgeState(this.request, 'RUNNING');
  }
}

class FailingRuntimeMirrorController extends RecordingVpnController {
  private readonly registry: VpnSessionRegistry;
  private readonly request: VpnStartRequest;

  constructor(registry: VpnSessionRegistry, request: VpnStartRequest) {
    super();
    this.registry = registry;
    this.request = request;
  }

  async initializeRuntimeMirror(): Promise<void> {
    this.registry.hydrateFailure(createVpnFailure('VPN_PROXY_REPLAY_FAILED', 'mirror hydration failed'), this.request);
  }
}

class DeferredRuntimeMirrorPort {
  readonly events: string[];
  readonly bindDeferred: DeferredValue<void> = new DeferredValue<void>();

  constructor(events: string[]) {
    this.events = events;
  }

  async bindExistingSession(_request: VpnStartRequest): Promise<void> {
    this.events.push('controller.initialize.start');
    await this.bindDeferred.promise;
    this.events.push('controller.initialize.done');
  }

  async deactivate(_sessionId: string): Promise<void> {
  }
}

class StaticVpnRpcCryptoPort implements VpnRpcCryptoPort {
  async prepare(): Promise<void> {
  }

  async rootHmac(input: Uint8Array): Promise<Uint8Array> {
    return this.digest(17, new Uint8Array(0), input);
  }

  async derivedHmac(_key: Uint8Array, input: Uint8Array): Promise<Uint8Array> {
    return this.digest(53, _key, input);
  }

  private digest(seed: number, key: Uint8Array, input: Uint8Array): Uint8Array {
    const bytes: Uint8Array = new Uint8Array(32);
    let acc: number = seed;
    for (let index: number = 0; index < key.length; index += 1) {
      acc = (acc + key[index] + index + 3) & 0xff;
    }
    for (let index: number = 0; index < input.length; index += 1) {
      acc = (acc + input[index] + index + 11) & 0xff;
    }
    for (let index: number = 0; index < bytes.length; index += 1) {
      const keyByte: number = key.length === 0 ? seed : key[index % key.length];
      const inputByte: number = input.length === 0 ? seed : input[index % input.length];
      acc = (acc + keyByte + inputByte + (index * 13)) & 0xff;
      bytes[index] = acc ^ ((keyByte + inputByte + index) & 0xff);
    }
    return bytes;
  }
}

class StaticVpnRpcSocketConnectionPort implements VpnRpcSocketConnectionPort {
  async send(_bytes: Uint8Array): Promise<void> {
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

class StaticVpnRpcSocketClientFactoryPort implements VpnRpcSocketClientFactoryPort {
  async connect(_address: string, _timeoutMs: number): Promise<VpnRpcSocketConnectionPort> {
    return new StaticVpnRpcSocketConnectionPort();
  }
}

class StaticVpnRpcSocketServerPort implements VpnRpcSocketServerPort {
  async listen(_address: string, _listener: (connection: VpnRpcSocketConnectionPort) => void): Promise<void> {
  }

  async close(): Promise<void> {
  }
}

class StaticVpnRpcRandomPort implements VpnRpcRandomPort {
  bytes(length: number): Uint8Array {
    return new Uint8Array(length);
  }
}

class StaticHarmonyVpnRpcPlatformBundle implements HarmonyVpnRpcPlatformBundle {
  readonly crypto: VpnRpcCryptoPort;
  readonly clientFactory: VpnRpcSocketClientFactoryPort;
  readonly server: VpnRpcSocketServerPort;
  readonly random: VpnRpcRandomPort;

  constructor() {
    this.crypto = new StaticVpnRpcCryptoPort();
    this.clientFactory = new StaticVpnRpcSocketClientFactoryPort();
    this.server = new StaticVpnRpcSocketServerPort();
    this.random = new StaticVpnRpcRandomPort();
  }
}

class CompositionRpcClientContextValue implements VpnRpcClientContext {
  sessionGeneration: number = 0;
  guards: VpnRpcGuards = createVpnRpcGuards(null, null, null);
}

class CompositionRpcRequestPayloadValue {
}

class CompositionRpcBodyValue implements VpnRpcBody {
  protocolVersion: 1 = 1;
  kind: 'REQUEST' | 'RESPONSE' | 'EVENT' = 'REQUEST';
  sequence: number = 0;
  clientEpoch: number = 0;
  requestOrdinal: number = 0;
  requestId: string = '';
  method: VpnRpcMethod = 'PING';
  sessionGeneration: number = 0;
  guards: VpnRpcGuards = createVpnRpcGuards(null, null, null);
  ok: boolean | null = null;
  error: null = null;
  payload: VpnRpcPayload = createVpnRpcEmptyPayload();

  constructor(method: VpnRpcMethod, guards: VpnRpcGuards, generation: number, payload: VpnRpcPayload) {
    this.protocolVersion = 1;
    this.kind = 'REQUEST';
    this.sequence = 1;
    this.clientEpoch = 1;
    this.requestOrdinal = 1;
    this.requestId = '00000000-0000-4000-8000-000000000001';
    this.method = method;
    this.sessionGeneration = generation;
    this.guards = guards;
    this.ok = null;
    this.error = null;
    this.payload = payload;
  }
}

class CompositionRpcClient implements VpnRpcClientPort {
  connectOnceCalls: number = 0;
  connectCalls: number = 0;
  closeCalls: number = 0;
  unsubscribeCalls: number = 0;
  closeError?: Error;
  stateValue: 'DISCONNECTED' | 'CONNECTING' | 'AUTHENTICATING' | 'READY' | 'RECONNECTING' | 'CLOSED' = 'DISCONNECTED';
  snapshotValue: VpnRuntimeSnapshot = createVpnRuntimeSnapshot({
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
  contextValue: VpnRpcClientContext | null = null;
  connectOnceError?: Error;
  connectError?: Error;
  connectOnceDeferred?: DeferredValue<void>;
  connectDeferred?: DeferredValue<void>;
  private readonly listeners: Map<number, VpnRpcEventListener> = new Map();
  private nextListenerId: number = 1;

  async connectOnce(): Promise<void> {
    this.connectOnceCalls += 1;
    if (this.connectOnceError !== undefined) {
      const error = this.connectOnceError;
      this.connectOnceError = undefined;
      throw error;
    }
    if (this.connectOnceDeferred !== undefined) {
      await this.connectOnceDeferred.promise;
    }
    this.stateValue = 'READY';
  }

  async connect(): Promise<void> {
    this.connectCalls += 1;
    if (this.connectError !== undefined) {
      throw this.connectError;
    }
    if (this.connectDeferred !== undefined) {
      await this.connectDeferred.promise;
    }
    this.stateValue = 'READY';
  }

  async request(method: VpnRpcMethod, guards: VpnRpcGuards, generation: number, payload: VpnRpcPayload): Promise<VpnRpcBody> {
    return new CompositionRpcBodyValue(method, guards, generation, payload);
  }

  async refreshTrafficCounters(): Promise<VpnRpcTrafficCounters> {
    const counters: VpnRpcTrafficCounters = {
      txBytes: this.snapshotValue.tunSnapshot?.counters.txBytes ?? 0,
      rxBytes: this.snapshotValue.tunSnapshot?.counters.rxBytes ?? 0
    };
    return counters;
  }

  state() {
    return this.stateValue;
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

  activeContext(): VpnRpcClientContext | null {
    if (this.contextValue === null) {
      return null;
    }
    return {
      sessionGeneration: this.contextValue.sessionGeneration,
      guards: createVpnRpcGuards(
        this.contextValue.guards.profileHash,
        this.contextValue.guards.revisionHash,
        this.contextValue.guards.catalogDigest
      )
    };
  }

  subscribe(listener: VpnRpcEventListener): number {
    const nextId: number = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(nextId, listener);
    return nextId;
  }

  unsubscribe(id: number): void {
    if (this.listeners.delete(id)) {
      this.unsubscribeCalls += 1;
    }
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
    this.stateValue = 'CLOSED';
    if (this.closeError !== undefined) {
      throw this.closeError;
    }
  }
}

function createCompositionRpcContext(
  generation: number,
  profileHash: string,
  revisionHash: string,
  catalogDigest: string
): VpnRpcClientContext {
  const context: CompositionRpcClientContextValue = new CompositionRpcClientContextValue();
  context.sessionGeneration = generation;
  context.guards = createVpnRpcGuards(
    profileHash,
    revisionHash,
    catalogDigest
  );
  return context;
}

async function resolveCatalogDigest(graph: PlatformGraph, coreService: CoreService, request: VpnStartRequest): Promise<string> {
  const profile: Profile | undefined = await graph.repository.get(request.profileId);
  if (profile === undefined || profile.currentRevision === null) {
    throw new Error('Missing profile revision for catalog digest fixture.');
  }
  const bundle: StaticHarmonyVpnRpcPlatformBundle = new StaticHarmonyVpnRpcPlatformBundle();
  const catalog = await buildVpnRpcCatalogFromCore(
    bundle.crypto,
    new TestCoreProxyServiceAdapter(coreService),
    await graph.proxyIdentityHasher.sha256(request.profileId),
    profile.currentRevision.sha256Digest,
    await graph.proxyIdentityHasher.sha256(request.sessionId),
    graph.contentStore.resolveCorePath(profile.currentRevision)
  );
  return catalog.catalogDigest;
}

class TestCoreProxyServiceAdapter implements CoreProxyPort {
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

  async selectProxy(
    context: CoreProxyQueryContext,
    groupName: string,
    memberName: string
  ): Promise<CoreProxySelectionApplied> {
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

class BindingRuntimeMirrorPort {
  private readonly commandBus: VpnProxyCommandBus;
  private readonly revisionHash: string;

  constructor(commandBus: VpnProxyCommandBus, revisionHash: string) {
    this.commandBus = commandBus;
    this.revisionHash = revisionHash;
  }

  async bindExistingSession(request: VpnStartRequest): Promise<void> {
    this.commandBus.bind(
      createProxyRuntimeIdentity(request.profileId, request.versionId, this.revisionHash, request.sessionId),
      new QueryOnlyRunningHandler()
    );
  }

  async deactivate(_sessionId: string): Promise<void> {
  }
}

class InertVpnExtensionAbilityApi implements VpnExtensionAbilityApi {
  async startVpnExtensionAbility(): Promise<void> {
  }

  async stopVpnExtensionAbility(): Promise<void> {
  }

  async updateTraffic(
    _sessionId: string,
    _uploadBytesPerSecond: number,
    _downloadBytesPerSecond: number
  ): Promise<void> {
  }

  bindStopHandler(_handler: () => void): void {
  }
}

class EmptyResourceManagerRecord {
}

class EmptyApplicationInfoRecord {
}

class EmptyConfigurationRecord {
}

class FakeHapModuleInfoRecord {
  readonly name: string;

  constructor(name: string) {
    this.name = name;
  }
}

class FakeAbilityInfoRecord {
  readonly bundleName: string;
  readonly name: string;

  constructor(bundleName: string, name: string) {
    this.bundleName = bundleName;
    this.name = name;
  }
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
  bundleName?: string = 'com.github.kr328.clash.harmony';
  abilityName?: string = 'CmfaVpnExtensionAbility';
  parameters?: Record<string, Object> | null = null;
}

class TimeoutPromiseRecord<T> {
  readonly promise: Promise<T>;

  constructor(value: T, delayMs: number) {
    this.promise = new Promise<T>((resolve) => {
      setTimeout(() => resolve(value), delayMs);
    });
  }
}

async function settleMicrotasks(turns: number = 8): Promise<void> {
  for (let index = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

class RuntimeAwareCoreService implements CoreService {
  readonly subscribeIds: number[] = [];
  readonly unsubscribeIds: number[] = [];
  private readonly callbacks: Map<number, (event: CoreEvent) => void> = new Map();
  private nextSubscriptionId: number = 1;
  private snapshotValue: RuntimeSnapshot = buildRuntimeSnapshot('STOPPED');

  hello(): string {
    return 'hello';
  }

  async coreVersion(): Promise<string> {
    return 'core';
  }

  async validateConfiguration(_path: string): Promise<void> {
  }

  async loadConfiguration(_path: string): Promise<void> {
  }

  async startLocal(_options: LocalOptions): Promise<RuntimeSnapshot> {
    return this.runtimeSnapshot();
  }

  async stopRuntime(): Promise<RuntimeSnapshot> {
    return this.runtimeSnapshot();
  }

  runtimeSnapshot(): RuntimeSnapshot {
    return {
      state: this.snapshotValue.state,
      activeConfigPath: this.snapshotValue.activeConfigPath,
      httpAddress: this.snapshotValue.httpAddress,
      socksAddress: this.snapshotValue.socksAddress,
      lastError: this.snapshotValue.lastError,
      mixedPort: this.snapshotValue.mixedPort
    };
  }

  async queryProxyGroups(_context: CoreProxyQueryContext, _selectableOnly: boolean): Promise<CoreProxyGroupList> {
    return await Promise.reject(createProxyRuntimeNotReadyError('queryProxyGroups'));
  }

  async queryProxyGroup(_context: CoreProxyQueryContext, _groupName: string): Promise<CoreProxyGroupResult> {
    return await Promise.reject(createProxyRuntimeNotReadyError('queryProxyGroup'));
  }

  async selectProxy(
    _context: CoreProxyQueryContext,
    _groupName: string,
    _memberName: string
  ): Promise<CoreProxySelectionApplied> {
    return await Promise.reject(createProxyRuntimeNotReadyError('selectProxy'));
  }

  async startProxyDelayTest(_context: CoreProxyQueryContext, _groupName: string): Promise<CoreProxyDelaySnapshot> {
    return await Promise.reject(createProxyRuntimeNotReadyError('startProxyDelayTest'));
  }

  async readProxyDelayTest(_jobId: string): Promise<CoreProxyDelaySnapshot> {
    return await Promise.reject(createProxyRuntimeNotReadyError('readProxyDelayTest'));
  }

  async cancelProxyDelayTest(_jobId: string): Promise<CoreProxyDelaySnapshot> {
    return await Promise.reject(createProxyRuntimeNotReadyError('cancelProxyDelayTest'));
  }

  subscribe(callback: (event: CoreEvent) => void): number {
    const subscriptionId: number = this.nextSubscriptionId;
    this.nextSubscriptionId += 1;
    this.subscribeIds.push(subscriptionId);
    this.callbacks.set(subscriptionId, callback);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.unsubscribeIds.push(subscriptionId);
    this.callbacks.delete(subscriptionId);
  }
}

class CoreProxyGroupRefFixture {
  name: string = '';
  type: 'Selector' = 'Selector';
}

class CoreProxyNodeSummaryFixture {
  name: string = '';
  type: 'Direct' = 'Direct';
  isGroup: boolean = false;
  selected: boolean = false;
}

class CoreProxyGroupSnapshotFixture {
  name: string = '';
  type: 'Selector' = 'Selector';
  selectedName: string = '';
  nodes: CoreProxyNodeSummaryFixture[] = [];
}

const RUN_ID_KEY = 'cmfa.phase1.runId';

class DynamicObjectRecord {
}

class LaunchContextFixture implements Phase1LaunchContext {
  selfTest: boolean = true;
  runId: string = 'run-id-1';
  runnerStartedAt: string = '2026-08-28T09:00:00.000Z';
  filesDir: string = '/sandbox/app/files';
  probeOriginRunId: string = 'probe-origin-run';
  probeOriginUrl: string = 'https://origin.example.test';
  probeCaPem: string = '-----BEGIN CERTIFICATE-----';
  probeExpectedBodySha256: string = 'expected-body-sha';
  probeFixturePath: string = '/fixtures/probe.json';
  probeFixtureSha256: string = 'fixture-sha';
}

class WantFixture {
  deviceId?: string = 'device-1';
  bundleName?: string = 'bundle.name';
  abilityName?: string = 'AbilityName';
  parameters?: Record<string, Object> = undefined;
}

class CoreProxyGroupListFixture implements CoreProxyGroupList {
  schemaVersion: '1.0.0' = '1.0.0';
  kind: 'GROUP_LIST' = 'GROUP_LIST';
  profileHash: string = '';
  revisionHash: string = '';
  sessionHash: string | null = null;
  generation: number = 0;
  groups: CoreProxyGroupRefFixture[] = [];
}

class CoreProxyGroupResultFixture implements CoreProxyGroupResult {
  schemaVersion: '1.0.0' = '1.0.0';
  kind: 'GROUP_SNAPSHOT' = 'GROUP_SNAPSHOT';
  profileHash: string = '';
  revisionHash: string = '';
  sessionHash: string | null = null;
  generation: number = 0;
  group: CoreProxyGroupSnapshotFixture = new CoreProxyGroupSnapshotFixture();
}

class ProxyCapableRuntimeCoreService extends RuntimeAwareCoreService {
  async queryProxyGroups(context: CoreProxyQueryContext, _selectableOnly: boolean): Promise<CoreProxyGroupList> {
    const result: CoreProxyGroupListFixture = new CoreProxyGroupListFixture();
    result.profileHash = context.profileHash;
    result.revisionHash = context.revisionHash;
    result.sessionHash = context.sessionHash;
    result.generation = context.generation;
    const group: CoreProxyGroupRefFixture = new CoreProxyGroupRefFixture();
    group.name = 'Group A';
    result.groups = [group];
    return result;
  }

  async queryProxyGroup(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyGroupResult> {
    const result: CoreProxyGroupResultFixture = new CoreProxyGroupResultFixture();
    result.profileHash = context.profileHash;
    result.revisionHash = context.revisionHash;
    result.sessionHash = context.sessionHash;
    result.generation = context.generation;
    result.group.name = groupName;
    result.group.selectedName = 'Node A';
    const node: CoreProxyNodeSummaryFixture = new CoreProxyNodeSummaryFixture();
    node.name = 'Node A';
    node.selected = true;
    result.group.nodes = [node];
    return result;
  }
}

function buildRuntimeSnapshot(state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR'): RuntimeSnapshot {
  return {
    state,
    activeConfigPath: '',
    httpAddress: '',
    socksAddress: '',
    lastError: '',
    mixedPort: 0
  };
}

function createEligibleProfile(profileId: string): Profile {
  return createProfile({
    id: profileId,
    name: 'Profile',
    sourceKind: 'REMOTE_URL',
    sourceDisplay: 'https://mirror.example.com/config.yaml',
    sourceSecretRef: 'secret-ref',
    currentRevision: createProfileRevision(`profiles/${profileId}.yaml`, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 128, '2026-08-11T12:00:00.000Z'),
    failedCandidate: null,
    availability: 'VALID',
    lastError: null,
    createdAt: '2026-08-11T12:00:00.000Z',
    updatedAt: '2026-08-11T12:00:00.000Z',
    lastSuccessfulUpdateAt: '2026-08-11T12:00:00.000Z'
  });
}

function createContext(): common.UIAbilityContext {
  return {
    filesDir: '/sandbox/app/files'
  } as common.UIAbilityContext;
}

function createLaunchContextFixture(): Phase1LaunchContext {
  return new LaunchContextFixture() as Object as Phase1LaunchContext;
}

function createDynamicParameters(): Record<string, Object> {
  return new DynamicObjectRecord() as Object as Record<string, Object>;
}

function setDynamicParameter(parameters: Record<string, Object>, key: string, value: Object): void {
  parameters[key] = value;
}

function createVpnExtensionWant(parameters?: Record<string, Object> | null): Want {
  const want = new WantFixture();
  want.parameters = parameters ?? createDynamicParameters();
  return want;
}

function collectStatuses(history: ApplicationCompositionState[]): string {
  const statuses: string[] = [];
  for (let index: number = 0; index < history.length; index += 1) {
    statuses.push(history[index].status);
  }
  return statuses.join('>');
}

class RefreshProfilesUseCaseDependenciesRecord implements RefreshProfilesUseCaseDependencies {
  readonly repository: ProfileRepository;
  readonly executor: RefreshProfileUseCase;
  readonly clock: Clock;

  constructor(repository: ProfileRepository, executor: RefreshProfileUseCase, clock: Clock) {
    this.repository = repository;
    this.executor = executor;
    this.clock = clock;
  }
}

class ProfileApplicationDependenciesRecord implements ProfileApplicationDependencies {
  readonly importUseCase: ImportProfileUseCase;
  readonly refreshUseCase: RefreshProfileUseCase;
  readonly refreshProfilesUseCase?: RefreshProfilesUseCase;
  readonly profileRefreshSchedule?: WorkSchedulerDriver;
  readonly manageProfileUseCases: ManageProfileUseCases;
  readonly runtimeCoordinator: LocalRuntimeCoordinator;
  readonly commitService: ProfileCommitService;
  readonly repository: ProfileRepository;
  readonly oneClickVpnConfirmation: OneClickVpnConfirmationPort;
  readonly proxyService: ProxyApplicationPort;
  readonly vpnController?: VpnControllerPort;
  readonly idGenerator?: IdGenerator;

  constructor(
    importUseCase: ImportProfileUseCase,
    refreshUseCase: RefreshProfileUseCase,
    refreshProfilesUseCase: RefreshProfilesUseCase,
    manageProfileUseCases: ManageProfileUseCases,
    runtimeCoordinator: LocalRuntimeCoordinator,
    commitService: ProfileCommitService,
    repository: ProfileRepository,
    oneClickVpnConfirmation: OneClickVpnConfirmationPort,
    proxyService: ProxyApplicationPort,
    vpnController?: VpnControllerPort,
    idGenerator?: IdGenerator
  ) {
    this.importUseCase = importUseCase;
    this.refreshUseCase = refreshUseCase;
    this.refreshProfilesUseCase = refreshProfilesUseCase;
    this.profileRefreshSchedule = new WorkSchedulerDriver();
    this.manageProfileUseCases = manageProfileUseCases;
    this.runtimeCoordinator = runtimeCoordinator;
    this.commitService = commitService;
    this.repository = repository;
    this.oneClickVpnConfirmation = oneClickVpnConfirmation;
    this.proxyService = proxyService;
    this.vpnController = vpnController;
    this.idGenerator = idGenerator;
  }
}

function createProfileApplicationDependencies(
  coreService: CoreService,
  graph: PlatformGraph,
  vpnController?: VpnControllerPort,
  oneClickVpnConfirmation?: OneClickVpnConfirmationPort,
  proxyService?: ProxyApplicationPort
): ProfileApplicationDependencies {
  const runtimeCoordinator = new LocalRuntimeCoordinator({
    repository: graph.repository,
    contentStore: graph.contentStore,
    coreService,
    clock: new FixedClock(
      '2026-08-11T12:01:00.000Z',
      '2026-08-11T12:01:01.000Z',
      '2026-08-11T12:01:02.000Z'
    )
  });
  const queue = new SerialCommandQueue();
  const commitService = new ProfileCommitService({
    repository: graph.repository,
    contentStore: graph.contentStore,
    clock: new FixedClock(
      '2026-08-11T12:02:00.000Z',
      '2026-08-11T12:02:01.000Z',
      '2026-08-11T12:02:02.000Z'
    )
  });
  const sourceGateway = graph.sourceGateway;
  const secretStore = graph.secretStore;
  const importUseCase = new ImportProfileUseCase({
    repository: graph.repository,
    contentStore: graph.contentStore,
    sourceGateway,
    secretStore,
    coreService,
    clock: new FixedClock('2026-08-11T12:03:00.000Z', '2026-08-11T12:03:01.000Z'),
    idGenerator: graph.idGenerator,
    queue,
    commitService
  });
  const refreshClock = new FixedClock(
    '2026-08-11T12:04:00.000Z',
    '2026-08-11T12:04:01.000Z',
    '2026-08-11T12:04:02.000Z'
  );
  const refreshUseCase = new RefreshProfileUseCase({
    repository: graph.repository,
    contentStore: graph.contentStore,
    sourceGateway,
    secretStore,
    coreService,
    clock: refreshClock,
    queue,
    commitService,
    leasedRemoteRefresher: createLeasedRemoteProfileRefresher(
      graph.profileRefreshLeasePort,
      refreshClock,
      graph.idGenerator
    )
  });
  const refreshProfilesUseCase = new RefreshProfilesUseCase(
    new RefreshProfilesUseCaseDependenciesRecord(graph.repository, refreshUseCase, graph.clock)
  );
  const manageProfileUseCases = new ManageProfileUseCases({
    repository: graph.repository,
    contentStore: graph.contentStore,
    secretStore,
    coreService,
    clock: new FixedClock(
      '2026-08-11T12:05:00.000Z',
      '2026-08-11T12:05:01.000Z',
      '2026-08-11T12:05:02.000Z'
    ),
    runtimeCoordinator
  });

  return new ProfileApplicationDependenciesRecord(
    importUseCase,
    refreshUseCase,
    refreshProfilesUseCase,
    manageProfileUseCases,
    runtimeCoordinator,
    commitService,
    graph.repository,
    oneClickVpnConfirmation ?? new RecordingOneClickVpnConfirmation(),
    proxyService ?? new InertProxyApplicationPort(),
    vpnController,
    graph.idGenerator
  );
}

function createLeasedRemoteProfileRefresher(
  leasePort: ProfileRefreshLeasePort,
  clock: Clock,
  idGenerator: IdGenerator
): LeasedRemoteProfileRefresher {
  return new LeasedRemoteProfileRefresher({
    leasePort,
    clock,
    idGenerator
  });
}

function createRealProfileApplication(
  coreService: CoreService,
  graph: PlatformGraph,
  vpnController?: VpnControllerPort,
  oneClickVpnConfirmation?: OneClickVpnConfirmationPort
): ProfileApplication {
  return new ProfileApplication(createProfileApplicationDependencies(coreService, graph, vpnController, oneClickVpnConfirmation));
}

function createRealProfileApplicationWithProxyService(
  coreService: CoreService,
  graph: PlatformGraph,
  vpnRegistry: VpnSessionRegistry,
  commandBus: VpnProxyCommandBus,
  vpnController?: VpnControllerPort,
  oneClickVpnConfirmation?: OneClickVpnConfirmationPort
): ProfileApplication {
  const proxyService = new ProxyService(
    new ActiveProfileProxyResolver(graph.repository, graph.contentStore),
    new TestCoreProxyServiceAdapter(coreService),
    graph.proxySelectionRepository,
    graph.proxyIdentityHasher,
    vpnRegistry,
    commandBus,
    graph.clock
  );
  return new ProfileApplication(createProfileApplicationDependencies(
    coreService,
    graph,
    vpnController,
    oneClickVpnConfirmation,
    proxyService
  ));
}

function createComposition(
  dependencies: ApplicationCompositionDependencies
): ApplicationComposition {
  const mergedDependencies: ApplicationCompositionDependencies = dependencies;
  if (mergedDependencies.createVpnRpcPlatformBundle === undefined) {
    mergedDependencies.createVpnRpcPlatformBundle = (): HarmonyVpnRpcPlatformBundle => new StaticHarmonyVpnRpcPlatformBundle();
  }
  return createApplicationComposition(createContext(), mergedDependencies);
}

function expectThrows(action: () => void): void {
  let threw: boolean = false;
  try {
    action();
  } catch (_) {
    threw = true;
  }
  expect(threw).assertTrue();
}

export default function applicationCompositionTestsuite() {
  describe('ApplicationCompositionTest', () => {
    it('applyPhase1LaunchWantCapturesLaunchContextAndGetReturnsACopyWithoutRegressingExistingFields', 0, () => {
      const parameters = createDynamicParameters();
      setDynamicParameter(parameters, 'cmfa.phase1.selfTest', 'true');
      setDynamicParameter(parameters, RUN_ID_KEY, 'launch-run-id');
      setDynamicParameter(parameters, 'cmfa.phase1.runnerStartedAt', '2026-08-28T10:00:00.000Z');
      setDynamicParameter(parameters, 'cmfa.phase2.originRunId', 'probe-origin-id');
      setDynamicParameter(parameters, 'cmfa.phase2.originUrl', 'https://probe.example.test');
      setDynamicParameter(parameters, 'cmfa.phase2.caPem', '-----BEGIN PROBE CERTIFICATE-----');
      setDynamicParameter(parameters, 'cmfa.phase2.expectedBodySha256', 'probe-body-sha');
      setDynamicParameter(parameters, 'cmfa.phase2.fixturePath', '/fixtures/probe-body.json');
      setDynamicParameter(parameters, 'cmfa.phase2.fixtureSha256', 'probe-fixture-sha');
      const want: Want = createVpnExtensionWant(parameters);

      const applied = applyPhase1LaunchWant(createContext(), want);
      expect(applied.selfTest).assertTrue();
      expect(applied.runId).assertEqual('launch-run-id');
      expect(applied.runnerStartedAt).assertEqual('2026-08-28T10:00:00.000Z');
      expect(applied.probeOriginRunId).assertEqual('probe-origin-id');
      expect(applied.probeOriginUrl).assertEqual('https://probe.example.test');
      expect(applied.probeCaPem).assertEqual('-----BEGIN PROBE CERTIFICATE-----');
      expect(applied.probeExpectedBodySha256).assertEqual('probe-body-sha');
      expect(applied.probeFixturePath).assertEqual('/fixtures/probe-body.json');
      expect(applied.probeFixtureSha256).assertEqual('probe-fixture-sha');

      const firstRead = getPhase1LaunchContext();
      firstRead.runId = '';
      firstRead.probeOriginUrl = '';
      firstRead.selfTest = false;

      const secondRead = getPhase1LaunchContext();
      expect(secondRead.runId).assertEqual('launch-run-id');
      expect(secondRead.probeOriginUrl).assertEqual('https://probe.example.test');
      expect(secondRead.selfTest).assertTrue();
    });

    it('buildForwardedVpnExtensionWantKeepsLegacyWantByteForByteWhenLaunchContextAddsNothing', 0, () => {
      const sourceParameters = createDynamicParameters();
      setDynamicParameter(sourceParameters, 'profileId', 'profile-1');
      setDynamicParameter(sourceParameters, 'sessionId', 'session-1');
      const sourceWant: Want = createVpnExtensionWant(sourceParameters);
      const launchContext = createLaunchContextFixture();
      launchContext.runId = '';

      const forwardedWant = buildForwardedVpnExtensionWant(sourceWant, launchContext);

      expect(forwardedWant).assertDeepEquals(sourceWant);
      expect(forwardedWant === sourceWant).assertFalse();
      expect(forwardedWant.parameters === sourceWant.parameters).assertFalse();
    });

    it('buildForwardedVpnExtensionWantRestoresLegacyEmptyDeviceIdFallbackWhenSourceWantOmitsIt', 0, () => {
      const sourceParameters = createDynamicParameters();
      setDynamicParameter(sourceParameters, 'profileId', 'profile-device-fallback');
      setDynamicParameter(sourceParameters, 'sessionId', 'session-device-fallback');
      const sourceWant: Want = createVpnExtensionWant(sourceParameters);
      sourceWant.deviceId = undefined;
      const launchContext = createLaunchContextFixture();
      launchContext.runId = '';

      const forwardedWant = buildForwardedVpnExtensionWant(sourceWant, launchContext);

      expect(forwardedWant.deviceId).assertEqual('');
      expect(forwardedWant.bundleName).assertEqual(sourceWant.bundleName);
      expect(forwardedWant.abilityName).assertEqual(sourceWant.abilityName);
      expect(forwardedWant.parameters).assertDeepEquals(sourceParameters);
    });

    it('buildForwardedVpnExtensionWantForwardsRunIdWithoutMutatingTheSourceWant', 0, () => {
      const sourceParameters = createDynamicParameters();
      setDynamicParameter(sourceParameters, 'profileId', 'profile-9');
      setDynamicParameter(sourceParameters, 'sessionId', 'session-9');
      const sourceWant: Want = createVpnExtensionWant(sourceParameters);
      const sourceSnapshot = JSON.stringify(sourceWant);
      const launchContext = createLaunchContextFixture();

      const forwardedWant = buildForwardedVpnExtensionWant(sourceWant, launchContext);
      const expectedForwardedParameters = createDynamicParameters();
      setDynamicParameter(expectedForwardedParameters, 'profileId', 'profile-9');
      setDynamicParameter(expectedForwardedParameters, 'sessionId', 'session-9');
      setDynamicParameter(expectedForwardedParameters, RUN_ID_KEY, 'run-id-1');
      expect(forwardedWant.parameters).assertDeepEquals(expectedForwardedParameters);
      expect(JSON.stringify(sourceWant)).assertEqual(sourceSnapshot);

      launchContext.runId = '';
      const withoutRunId = buildForwardedVpnExtensionWant(sourceWant, launchContext);
      const expectedWithoutRunId = createDynamicParameters();
      setDynamicParameter(expectedWithoutRunId, 'profileId', 'profile-9');
      setDynamicParameter(expectedWithoutRunId, 'sessionId', 'session-9');
      expect(withoutRunId.parameters).assertDeepEquals(expectedWithoutRunId);
    });

    it('concurrentInitializeTransitionsLoadingToReadyOnce', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const application = new RecordingApplication();
      const vpnRegistry = new VpnSessionRegistry();
      const states: ApplicationCompositionState[] = [];
      const graphDeferred = new DeferredValue<PlatformGraph>();
      let createPlatformGraphCallCount: number = 0;
      const composition = createComposition({
        vpnRegistry,
        createPlatformGraph: async (_context: common.UIAbilityContext): Promise<PlatformGraph> => {
          createPlatformGraphCallCount += 1;
          return await graphDeferred.promise;
        },
        createProfileApplication: (_graph: PlatformGraph, _coreService: CoreService): ProfileApplication => {
          return application;
        }
      });
      composition.subscribe((state: ApplicationCompositionState): void => {
        states.push(state);
      });

      const first = composition.initialize();
      const second = composition.initialize();

      expect(createPlatformGraphCallCount).assertEqual(1);
      expect(composition.state().status).assertEqual('LOADING');
      expect(collectStatuses(states)).assertEqual('LOADING');

      graphDeferred.resolve(graph);
      await Promise.all([first, second]);

      expect(application.initializeCallCount).assertEqual(1);
      expect(collectStatuses(states)).assertEqual('LOADING>READY');
      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status === 'READY') {
        expect(compositionState.vpnRegistry === vpnRegistry).assertTrue();
      }
      await composition.close();
    });

    it('passesTheExactInjectedRegistryThroughReadyStateControllerFactoryAndCustomApplicationFactory', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const vpnRegistry = new VpnSessionRegistry();
      const application = new RecordingApplication();
      let applicationFactoryRegistry: VpnSessionRegistry | undefined = undefined;
      const composition = createComposition({
        vpnRegistry,
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createProfileApplication: (_graph: PlatformGraph, _coreService: CoreService, registry: VpnSessionRegistry): ProfileApplication => {
          applicationFactoryRegistry = registry;
          return application;
        }
      });

      await composition.initialize();

      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status === 'READY') {
        expect(compositionState.vpnRegistry === vpnRegistry).assertTrue();
      }
      expect(applicationFactoryRegistry === vpnRegistry).assertTrue();
      await composition.close();
    });

    it('passesTheExactVpnControllerInstanceIntoOneClickConfirmationFactoryAndProfileApplicationFactory', 0, async () => {
      const graph = new RecordingPlatformGraph(new SeededRepository(createEligibleProfile('ready')));
      const vpnController = new RecordingVpnController();
      const oneClickConfirmation = new RecordingOneClickVpnConfirmation();
      const application = new RecordingApplication();
      let confirmationFactoryController: VpnControllerPort | undefined = undefined;
      let applicationFactoryController: VpnControllerPort | undefined = undefined;
      let applicationFactoryConfirmation: OneClickVpnConfirmationPort | undefined = undefined;
      const composition = createComposition({
        createPlatformGraph: async (): Promise<PlatformGraph> => graph,
        createVpnController: (): VpnControllerPort => vpnController,
        createOneClickVpnConfirmation: (controller: VpnControllerPort): OneClickVpnConfirmationPort => {
          confirmationFactoryController = controller;
          return oneClickConfirmation;
        },
        createProfileApplication: (
          platformGraph: PlatformGraph,
          injectedCoreService: CoreService,
          registry: VpnSessionRegistry,
          _commandBus: VpnProxyCommandBus,
          controller?: VpnControllerPort,
          confirmation?: OneClickVpnConfirmationPort
        ): ProfileApplication => {
          expect(controller !== undefined).assertTrue();
          expect(confirmation !== undefined).assertTrue();
          if (controller === undefined || confirmation === undefined) {
            throw new Error('Expected controller wiring for one-click confirmation seam test.');
          }
          applicationFactoryController = controller;
          applicationFactoryConfirmation = confirmation;
          expect(registry instanceof VpnSessionRegistry).assertTrue();
          return application;
        }
      });

      await composition.initialize();

      expect(confirmationFactoryController === vpnController).assertTrue();
      expect(applicationFactoryController === vpnController).assertTrue();
      expect(applicationFactoryController === confirmationFactoryController).assertTrue();
      expect(applicationFactoryConfirmation === oneClickConfirmation).assertTrue();

      await composition.close();
    });

    it('customApplicationFactoryCanReuseTheExactRegistryForTheControllerAndReadyState', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const coreService = new ProxyCapableRuntimeCoreService();
      const vpnRegistry = new VpnSessionRegistry();
      let controllerRegistry: VpnSessionRegistry | undefined = undefined;
      const composition = createComposition({
        coreService,
        vpnRegistry,
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createProfileApplication: (platformGraph: PlatformGraph, injectedCoreService: CoreService, registry: VpnSessionRegistry): ProfileApplication => {
          controllerRegistry = registry;
          const controller = new HarmonyVpnController(registry, new InertVpnExtensionAbilityApi());
          return createRealProfileApplication(injectedCoreService, platformGraph, controller);
        }
      });

      await composition.initialize();

      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status === 'READY') {
        expect(compositionState.vpnRegistry === vpnRegistry).assertTrue();
      }
      expect(controllerRegistry === vpnRegistry).assertTrue();
      await composition.close();
    });

    it('defaultApplicationWiringUsesTheInjectedRegistryAcrossControllerFactoryAndReadyState', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const coreService = new ProxyCapableRuntimeCoreService();
      const vpnRegistry = new VpnSessionRegistry();
      let controllerFactoryRegistry: VpnSessionRegistry | undefined = undefined;
      const composition = createComposition({
        coreService,
        vpnRegistry,
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createVpnController: (registry: VpnSessionRegistry): VpnControllerPort => {
          controllerFactoryRegistry = registry;
          return new HarmonyVpnController(registry, new InertVpnExtensionAbilityApi());
        }
      });

      await composition.initialize();

      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status === 'READY') {
        expect(compositionState.vpnRegistry === vpnRegistry).assertTrue();
      }
      expect(controllerFactoryRegistry === vpnRegistry).assertTrue();
      await composition.close();
    });

    it('entryCompositionProfileApplicationSurfaceIncludesDelayOperations', 0, async () => {
      const application = createRealProfileApplication(
        new RuntimeAwareCoreService(),
        new RecordingPlatformGraph()
      );

      await application.initialize();
      const started = await application.startDelayTest('Selector', 1);
      const finished = await application.readDelayTest('delay-job-1');
      const cancelled = await application.cancelDelayTest('delay-job-1');
      const drained = await application.cancelAndDrainDelayTest();

      expect(started.kind).assertEqual('REJECTED');
      expect(finished.kind).assertEqual('REJECTED');
      expect(cancelled.kind).assertEqual('REJECTED');
      expect(drained).assertUndefined();
      application.dispose();
    });

    it('entryCompositionProfileApplicationDependenciesWireBatchRefreshUseCaseAndScheduler', 0, async () => {
      const dependencies = createProfileApplicationDependencies(
        new RuntimeAwareCoreService(),
        new RecordingPlatformGraph()
      );
      const refreshProfilesUseCase = dependencies.refreshProfilesUseCase;
      expect(refreshProfilesUseCase !== undefined).assertTrue();
      if (refreshProfilesUseCase === undefined) {
        throw new Error('refreshProfilesUseCase was unexpectedly missing.');
      }
      const batchUseCaseRecord = Reflect.get(refreshProfilesUseCase, 'executor') as RefreshProfileUseCase;

      expect(dependencies.refreshProfilesUseCase instanceof RefreshProfilesUseCase).assertTrue();
      expect(dependencies.profileRefreshSchedule instanceof WorkSchedulerDriver).assertTrue();
      expect(batchUseCaseRecord === dependencies.refreshUseCase).assertTrue();
    });

    it('explicitExtensionFactoryTestSeamCanStillUseTheExactInjectedRegistryAndCommandBus', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const vpnRegistry = new VpnSessionRegistry();
      const commandBus = new VpnProxyCommandBus();
      vpnRegistry.beginPending(createVpnStartRequest('profile-1', 'version-1', 'session-1'));
      installVpnExtensionCompositionFactoryForTesting((context: common.VpnExtensionContext | undefined) => {
        return new VpnExtensionComposition(context, {
          registry: vpnRegistry,
          commandBus
        });
      });
      const runner = resolveVpnExtensionComposition(new FakeVpnExtensionContextRecord('app-composition') as common.VpnExtensionContext);
      await runner.start(new NullParametersWantRecord() as Want);

      expect(vpnRegistry.snapshot().state).assertEqual('STOPPED');
      expect(vpnRegistry.snapshot().activeRequest).assertNull();
      resetVpnExtensionCompositionForTesting();
    });

    it('awaitsRuntimeMirrorInitializationBeforeApplicationInitializationAndReadyPublication', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const applicationEvents: string[] = [];
      const states: string[] = [];
      const controller = new DeferredRuntimeMirrorController(applicationEvents);
      const composition = createComposition({
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          applicationEvents.push('graph.create');
          return graph;
        },
        createVpnController: (): VpnControllerPort => {
          return controller;
        },
        createOneClickVpnConfirmation: (_controller: VpnControllerPort): OneClickVpnConfirmationPort => {
          return new RecordingOneClickVpnConfirmation();
        },
        createVpnExtensionAbilityApi: (): InertVpnExtensionAbilityApi => {
          return new InertVpnExtensionAbilityApi();
        },
        createProfileApplication: (): ProfileApplication => {
          applicationEvents.push('application.factory');
          return new LoggingApplication(applicationEvents);
        }
      });
      composition.subscribe((state: ApplicationCompositionState): void => {
        if (state.status === 'READY') {
          applicationEvents.push('state.ready');
          states.push(state.status);
        }
      });

      const initializePromise = composition.initialize();
      const pendingOutcome = await Promise.race([
        initializePromise.then(() => 'resolved'),
        new TimeoutPromiseRecord('timeout', 20).promise
      ]);

      expect(pendingOutcome).assertEqual('timeout');
      expect(applicationEvents.join('>')).assertEqual('graph.create>controller.initialize.start');

      controller.initializeDeferred.resolve(undefined);
      await initializePromise;

      expect(states.join('>')).assertEqual('READY');
      expect(applicationEvents.join('>')).assertEqual(
        'graph.create>controller.initialize.start>controller.initialize.done>application.factory>application.initialize>state.ready'
      );
      await composition.close();
    });

    it('hydratesRunningMirrorBeforeFirstReadyAndRoutesQueryGroupThroughTheSharedCommandBus', 0, async () => {
      const profile = createEligibleProfile('running-profile');
      const graph = new RecordingPlatformGraph(new SeededRepository(profile));
      const vpnRegistry = new VpnSessionRegistry();
      const commandBus = new VpnProxyCommandBus();
      const request = createVpnStartRequest(profile.id, profile.currentRevision?.validatedAt ?? '', 'session-running');
      const controller = new HydratingRuntimeMirrorController(vpnRegistry, commandBus, request);
      const composition = createComposition({
        vpnRegistry,
        commandBus,
        createPlatformGraph: async (): Promise<PlatformGraph> => graph,
        createVpnController: (): VpnControllerPort => {
          return controller;
        },
        createVpnExtensionAbilityApi: (): InertVpnExtensionAbilityApi => {
          return new InertVpnExtensionAbilityApi();
        },
        createProfileApplication: (
          platformGraph: PlatformGraph,
          injectedCoreService: CoreService,
          registry: VpnSessionRegistry,
          commandBus: VpnProxyCommandBus
        ): ProfileApplication => {
          const proxyService = new ProxyService(
            new ActiveProfileProxyResolver(platformGraph.repository, platformGraph.contentStore),
            new TestCoreProxyServiceAdapter(injectedCoreService),
            platformGraph.proxySelectionRepository,
            platformGraph.proxyIdentityHasher,
            registry,
            commandBus,
            platformGraph.clock
          );
          return new QueryBackedRecordingApplication(proxyService);
        }
      });

      await composition.initialize();

      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status !== 'READY') {
        return;
      }
      expect(compositionState.vpnRegistry.snapshot().state).assertEqual('RUNNING');
      const result = await compositionState.application.queryGroup('Group A');
      if (result.kind === 'REJECTED') {
        throw new Error(`queryGroup rejected with ${result.error.code}`);
      }
      expect(result.kind).assertEqual('SNAPSHOT');
      if (result.kind === 'SNAPSHOT') {
        expect(result.snapshot.identity.sessionId ?? '').assertEqual(request.sessionId);
        expect(result.snapshot.group.selectedName).assertEqual('Node A');
      }
      await composition.close();
    });

    it('createsOneSharedVpnRpcClientAndBindsKnownRegistryRequestBeforeReadyUsingConnectOnce', 0, async () => {
      const profile = createEligibleProfile('rpc-running-profile');
      const graph = new RecordingPlatformGraph(new SeededRepository(profile));
      const coreService = new ProxyCapableRuntimeCoreService();
      const vpnRegistry = new VpnSessionRegistry();
      const commandBus = new VpnProxyCommandBus();
      const rpcClient = new CompositionRpcClient();
      const request = createVpnStartRequest(profile.id, profile.currentRevision?.validatedAt ?? '', 'rpc-session-1');
      vpnRegistry.beginPending(request);
      const catalogDigest: string = await resolveCatalogDigest(graph, coreService, request);
      rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      rpcClient.contextValue = createCompositionRpcContext(
        5,
        await graph.proxyIdentityHasher.sha256(profile.id),
        profile.currentRevision?.sha256Digest ?? '',
        catalogDigest
      );
      let handlerClient: VpnRpcClientPort | undefined = undefined;
      const runningHandler = new QueryOnlyRunningHandler();
      const composition = createComposition({
        coreService,
        vpnRegistry,
        commandBus,
        createPlatformGraph: async (): Promise<PlatformGraph> => graph,
        createVpnExtensionAbilityApi: (): InertVpnExtensionAbilityApi => new InertVpnExtensionAbilityApi(),
        createProfileApplication: (
          platformGraph: PlatformGraph,
          injectedCoreService: CoreService,
          registry: VpnSessionRegistry,
          commandBus: VpnProxyCommandBus
        ): ProfileApplication => {
          return createRealProfileApplicationWithProxyService(injectedCoreService, platformGraph, registry, commandBus);
        },
        createVpnRpcPlatformBundle: (): HarmonyVpnRpcPlatformBundle => new StaticHarmonyVpnRpcPlatformBundle(),
        createVpnRpcClient: (): VpnRpcClientPort => rpcClient,
        createVpnRpcHandler: (client: VpnRpcClientPort): VpnProxyCommandHandler => {
          handlerClient = client;
          return runningHandler;
        }
      });

      await composition.initialize();

      expect(rpcClient.connectOnceCalls).assertEqual(1);
      expect(rpcClient.connectCalls).assertEqual(0);
      expect(handlerClient === rpcClient).assertTrue();
      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status !== 'READY') {
        return;
      }
      expect(compositionState.vpnRegistry.snapshot().state).assertEqual('RUNNING');
      const queryResult = await compositionState.application.queryGroup('Group A');
      expect(queryResult.kind).assertEqual('SNAPSHOT');
      expect(runningHandler.queryGroupGenerations.join(',')).assertEqual('5');
      await composition.close();
      expect(rpcClient.closeCalls).assertEqual(1);
    });

    it('oneShotRpcHydrationFailureStillPublishesReadyKeepsRegistryRecoveringAndFallsBackOnlyAfterFullConnectExhausts', 0, async () => {
      const profile = createEligibleProfile('rpc-stopped-profile');
      const graph = new RecordingPlatformGraph(new SeededRepository(profile));
      const vpnRegistry = new VpnSessionRegistry();
      const commandBus = new VpnProxyCommandBus();
      const rpcClient = new CompositionRpcClient();
      rpcClient.connectOnceError = new Error('rpc unavailable');
      rpcClient.connectDeferred = new DeferredValue<void>();
      const composition = createComposition({
        coreService: new ProxyCapableRuntimeCoreService(),
        vpnRegistry,
        commandBus,
        createPlatformGraph: async (): Promise<PlatformGraph> => graph,
        createVpnExtensionAbilityApi: (): InertVpnExtensionAbilityApi => new InertVpnExtensionAbilityApi(),
        createProfileApplication: (
          platformGraph: PlatformGraph,
          injectedCoreService: CoreService,
          registry: VpnSessionRegistry,
          commandBus: VpnProxyCommandBus
        ): ProfileApplication => {
          return createRealProfileApplicationWithProxyService(injectedCoreService, platformGraph, registry, commandBus);
        },
        createVpnRpcPlatformBundle: (): HarmonyVpnRpcPlatformBundle => new StaticHarmonyVpnRpcPlatformBundle(),
        createVpnRpcClient: (): VpnRpcClientPort => rpcClient
      });

      await composition.initialize();

      const compositionState = composition.state();
      expect(rpcClient.connectOnceCalls).assertEqual(1);
      expect(rpcClient.connectCalls).assertEqual(1);
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status !== 'READY') {
        return;
      }
      expect(compositionState.vpnRegistry.snapshot().state).assertEqual('RECOVERING');
      const recoveringQuery = await compositionState.application.queryGroup('Group A');
      expect(recoveringQuery.kind).assertEqual('REJECTED');
      if (recoveringQuery.kind === 'REJECTED') {
        expect(recoveringQuery.error.code).assertEqual('PROXY_RUNTIME_NOT_READY');
      }

      rpcClient.connectDeferred.reject(new Error('full connect exhausted'));
      await settleMicrotasks(16);

      expect(compositionState.vpnRegistry.snapshot().state).assertEqual('STOPPED');
      const fallbackQuery = await compositionState.application.queryGroup('Group A');
      expect(fallbackQuery.kind).assertEqual('SNAPSHOT');
      if (fallbackQuery.kind === 'SNAPSHOT') {
        expect(fallbackQuery.snapshot.identity.sessionId).assertNull();
      }

      await composition.close();
      expect(rpcClient.closeCalls).assertEqual(1);
    });

    it('recreationClosesTheOldRpcClientAndHydratesTheNewSessionBeforeReady', 0, async () => {
      const profile = createEligibleProfile('rpc-recreate-profile');
      const graph = new RecordingPlatformGraph(new SeededRepository(profile));
      const coreService = new ProxyCapableRuntimeCoreService();
      const vpnRegistry = new VpnSessionRegistry();
      const commandBus = new VpnProxyCommandBus();
      const firstClient = new CompositionRpcClient();
      const secondClient = new CompositionRpcClient();
      const firstRequest = createVpnStartRequest(profile.id, profile.currentRevision?.validatedAt ?? '', 'rpc-session-old');
      const secondRequest = createVpnStartRequest(profile.id, profile.currentRevision?.validatedAt ?? '', 'rpc-session-new');
      const firstCatalogDigest: string = await resolveCatalogDigest(graph, coreService, firstRequest);
      const secondCatalogDigest: string = await resolveCatalogDigest(graph, coreService, secondRequest);
      firstClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: firstRequest,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      secondClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: secondRequest,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      firstClient.contextValue = createCompositionRpcContext(
        4,
        await graph.proxyIdentityHasher.sha256(profile.id),
        profile.currentRevision?.sha256Digest ?? '',
        firstCatalogDigest
      );
      secondClient.contextValue = createCompositionRpcContext(
        7,
        await graph.proxyIdentityHasher.sha256(profile.id),
        profile.currentRevision?.sha256Digest ?? '',
        secondCatalogDigest
      );
      let nextClient: CompositionRpcClient = firstClient;
      const dependencies: ApplicationCompositionDependencies = {
        coreService,
        vpnRegistry,
        commandBus,
        createPlatformGraph: async (): Promise<PlatformGraph> => graph,
        createVpnExtensionAbilityApi: (): InertVpnExtensionAbilityApi => new InertVpnExtensionAbilityApi(),
        createProfileApplication: (
          platformGraph: PlatformGraph,
          injectedCoreService: CoreService,
          registry: VpnSessionRegistry,
          commandBus: VpnProxyCommandBus
        ): ProfileApplication => {
          return createRealProfileApplicationWithProxyService(injectedCoreService, platformGraph, registry, commandBus);
        },
        createVpnRpcPlatformBundle: (): HarmonyVpnRpcPlatformBundle => new StaticHarmonyVpnRpcPlatformBundle(),
        createVpnRpcClient: (): VpnRpcClientPort => nextClient,
        createVpnRpcHandler: (): VpnProxyCommandHandler => new QueryOnlyRunningHandler()
      };
      const firstComposition = createComposition(dependencies);

      await firstComposition.initialize();
      await firstComposition.close();

      nextClient = secondClient;
      const secondComposition = createComposition(dependencies);
      await secondComposition.initialize();

      expect(firstClient.closeCalls).assertEqual(1);
      expect(secondClient.connectOnceCalls).assertEqual(1);
      expect(secondClient.connectCalls).assertEqual(0);
      const compositionState = secondComposition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status !== 'READY') {
        return;
      }
      expect(compositionState.vpnRegistry.snapshot().activeRequest?.sessionId ?? '').assertEqual('rpc-session-new');
      await secondComposition.close();
      expect(secondClient.closeCalls).assertEqual(1);
    });

    it('defaultControllerReadyStatePublishesTrafficMonitorReadPortForHomeConsumers', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const composition = createComposition({
        coreService: new ProxyCapableRuntimeCoreService(),
        createPlatformGraph: async (): Promise<PlatformGraph> => graph,
        createVpnExtensionAbilityApi: (): InertVpnExtensionAbilityApi => new InertVpnExtensionAbilityApi(),
        createVpnRpcPlatformBundle: (): HarmonyVpnRpcPlatformBundle => new StaticHarmonyVpnRpcPlatformBundle(),
        createVpnRpcClient: (): VpnRpcClientPort => new CompositionRpcClient()
      });

      await composition.initialize();

      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status !== 'READY') {
        return;
      }
      expect(compositionState.trafficMonitor === undefined).assertFalse();
      const trafficMonitor = compositionState.trafficMonitor;
      const initialSnapshot = trafficMonitor?.snapshot();
      expect(initialSnapshot?.available ?? true).assertFalse();
      const subscriptionId = trafficMonitor?.subscribe((): void => {}) ?? 0;
      expect(subscriptionId > 0).assertTrue();
      trafficMonitor?.unsubscribe(subscriptionId);

      await composition.close();
    });

    it('customControllerReadyStateLeavesTrafficMonitorUndefinedWhenCompositionDoesNotOwnOne', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const composition = createComposition({
        coreService: new ProxyCapableRuntimeCoreService(),
        createPlatformGraph: async (): Promise<PlatformGraph> => graph,
        createVpnController: (registry: VpnSessionRegistry): VpnControllerPort => {
          return new HarmonyVpnController(registry, new InertVpnExtensionAbilityApi());
        }
      });

      await composition.initialize();

      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status !== 'READY') {
        return;
      }
      expect(compositionState.trafficMonitor).assertUndefined();

      await composition.close();
    });

    it('runtimeMirrorHydrationFailureStillPublishesReadyAndSurfacesRegistryError', 0, async () => {
      const profile = createEligibleProfile('error-profile');
      const graph = new RecordingPlatformGraph(new SeededRepository(profile));
      const vpnRegistry = new VpnSessionRegistry();
      const commandBus = new VpnProxyCommandBus();
      const request = createVpnStartRequest(profile.id, profile.currentRevision?.validatedAt ?? '', 'session-error');
      const controller = new FailingRuntimeMirrorController(vpnRegistry, request);
      const composition = createComposition({
        vpnRegistry,
        commandBus,
        createPlatformGraph: async (): Promise<PlatformGraph> => graph,
        createVpnController: (): VpnControllerPort => {
          return controller;
        },
        createVpnExtensionAbilityApi: (): InertVpnExtensionAbilityApi => {
          return new InertVpnExtensionAbilityApi();
        },
        createProfileApplication: (): ProfileApplication => {
          return new RecordingApplication();
        }
      });

      await composition.initialize();

      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status !== 'READY') {
        return;
      }
      expect(compositionState.vpnRegistry.snapshot().state).assertEqual('ERROR');
      expect(compositionState.vpnRegistry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_PROXY_REPLAY_FAILED');
      await composition.close();
    });

    it('selfContainedExtensionFailureDoesNotMutateASeparateUiRegistryDirectly', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const uiRegistry = new VpnSessionRegistry();
      uiRegistry.beginPending(createVpnStartRequest('ui-profile', 'ui-version', 'ui-session'));
      const extensionRegistry = new VpnSessionRegistry();
      extensionRegistry.beginPending(createVpnStartRequest('ext-profile', 'ext-version', 'ext-session'));
      installVpnExtensionCompositionFactoryForTesting((context: common.VpnExtensionContext | undefined) => {
        return new VpnExtensionComposition(context, {
          registry: extensionRegistry,
          commandBus: new VpnProxyCommandBus()
        });
      });

      const runner = resolveVpnExtensionComposition(new FakeVpnExtensionContextRecord('isolated-extension') as common.VpnExtensionContext);
      await runner.start(new NullParametersWantRecord() as Want);

      expect(extensionRegistry.snapshot().state).assertEqual('STOPPED');
      expect(uiRegistry.snapshot().state).assertEqual('AWAITING_CONSENT');
      resetVpnExtensionCompositionForTesting();
    });

    it('defaultExtensionCompositionRemainsSelfContainedWithoutInstalledFactory', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const runner = resolveVpnExtensionComposition(new FakeVpnExtensionContextRecord('isolated-runtime') as common.VpnExtensionContext);

      expect(runner instanceof VpnExtensionComposition).assertTrue();

      const sameRunner = resolveVpnExtensionComposition(new FakeVpnExtensionContextRecord('isolated-runtime') as common.VpnExtensionContext);
      expect(sameRunner === runner).assertTrue();
      resetVpnExtensionCompositionForTesting();
    });

    it('doesNotDisposeInjectedControllersOnClose', 0, async () => {
      const controller = new DisposableRecordingVpnController();
      const composition = createComposition({
        coreService: new RuntimeAwareCoreService(),
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return new RecordingPlatformGraph();
        },
        createVpnController: (_registry: VpnSessionRegistry): VpnControllerPort => {
          return controller;
        }
      });

      await composition.initialize();
      await composition.close();

      expect(controller.disposeCallCount).assertEqual(0);
    });

    it('failedInitializePublishesPersistenceErrorClosesTheGraphAndAllowsExplicitRetry', 0, async () => {
      const firstGraph = new RecordingPlatformGraph();
      const secondGraph = new RecordingPlatformGraph();
      const firstApplication = new RecordingApplication();
      const secondApplication = new RecordingApplication();
      const states: ApplicationCompositionState[] = [];
      firstApplication.initializeError = new Error('https://profiles.example.com/import.yaml?token=secret-value');
      let useSecondAttempt: boolean = false;
      const composition = createComposition({
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return useSecondAttempt ? secondGraph : firstGraph;
        },
        createProfileApplication: (_graph: PlatformGraph, _coreService: CoreService): ProfileApplication => {
          return useSecondAttempt ? secondApplication : firstApplication;
        }
      });
      composition.subscribe((state: ApplicationCompositionState): void => {
        states.push(state);
      });

      let thrownError: AppError | undefined = undefined;
      try {
        await composition.initialize();
      } catch (error) {
        thrownError = error as AppError;
      }

      expect(thrownError !== undefined).assertTrue();
      if (thrownError === undefined) {
        return;
      }
      expect(thrownError.stage).assertEqual('PERSISTENCE');
      expect(firstGraph.closeCallCount).assertEqual(1);
      expect(thrownError.technicalDetail.includes('profiles.example.com')).assertFalse();
      expect(thrownError.technicalDetail.includes('secret-value')).assertFalse();
      expect(collectStatuses(states)).assertEqual('LOADING>ERROR');
      expect(composition.state().status).assertEqual('ERROR');

      useSecondAttempt = true;
      await composition.initialize();

      expect(secondApplication.initializeCallCount).assertEqual(1);
      expect(secondGraph.closeCallCount).assertEqual(0);
      expect(collectStatuses(states)).assertEqual('LOADING>ERROR>LOADING>READY');
      expect(composition.state().status).assertEqual('READY');
      await composition.close();
    });

    it('realRuntimeSubscriptionInitializesOnceAndCloseIsIdempotent', 0, async () => {
      const coreService = new RuntimeAwareCoreService();
      const contentStore = new InertContentStore();
      const graph = new RecordingPlatformGraph(
        new InertRepository(),
        contentStore,
        new InertSourceGateway(),
        new InertSecretStore()
      );
      const composition = createComposition({
        coreService,
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createProfileApplication: (platformGraph: PlatformGraph, injectedCoreService: CoreService): ProfileApplication => {
          return createRealProfileApplication(injectedCoreService, platformGraph);
        }
      });

      await Promise.all([composition.initialize(), composition.initialize()]);

      expect(contentStore.reconcileCallCount).assertEqual(1);
      expect(coreService.subscribeIds.length).assertEqual(1);
      expect(composition.state().status).assertEqual('READY');

      await composition.close();
      await composition.close();

      expect(coreService.unsubscribeIds.length).assertEqual(1);
      expect(graph.closeCallCount).assertEqual(1);
    });

    it('sanitizeInitializeFailureWhenDisposeThrowsAndStillClosesGraph', 0, async () => {
      const graph = new RecordingPlatformGraph();
      graph.closeError = new Error('close should not win');
      const application = new RecordingApplication();
      application.initializeError = new Error('initialize failed');
      application.disposeError = new Error('dispose leaked https://profiles.example.com/raw?token=secret-value');
      const states: ApplicationCompositionState[] = [];
      const composition = createComposition({
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createProfileApplication: (): ProfileApplication => {
          return application;
        }
      });
      composition.subscribe((state: ApplicationCompositionState): void => {
        states.push(state);
      });

      let thrownError: AppError | undefined = undefined;
      try {
        await composition.initialize();
      } catch (error) {
        thrownError = error as AppError;
      }

      expect(application.closeCallCount).assertEqual(1);
      expect(application.disposeCallCount).assertEqual(0);
      expect(graph.closeCallCount).assertEqual(1);
      expect(collectStatuses(states)).assertEqual('LOADING>ERROR');
      expect(composition.state().status).assertEqual('ERROR');
      expect(thrownError !== undefined).assertTrue();
      if (thrownError === undefined) {
        return;
      }
      expect(thrownError.stage).assertEqual('PERSISTENCE');
      expect(thrownError.technicalDetail.includes('profiles.example.com')).assertFalse();
      expect(thrownError.technicalDetail.includes('secret-value')).assertFalse();
    });

    it('sanitizeInitializeFailureWhenGraphCloseThrows', 0, async () => {
      const graph = new RecordingPlatformGraph();
      graph.closeError = new Error('close leaked https://profiles.example.com/close?token=secret-close');
      const application = new RecordingApplication();
      application.initializeError = new Error('initialize failed');
      const states: ApplicationCompositionState[] = [];
      const composition = createComposition({
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createProfileApplication: (): ProfileApplication => {
          return application;
        }
      });
      composition.subscribe((state: ApplicationCompositionState): void => {
        states.push(state);
      });

      let thrownError: AppError | undefined = undefined;
      try {
        await composition.initialize();
      } catch (error) {
        thrownError = error as AppError;
      }

      expect(application.closeCallCount).assertEqual(1);
      expect(application.disposeCallCount).assertEqual(0);
      expect(graph.closeCallCount).assertEqual(1);
      expect(collectStatuses(states)).assertEqual('LOADING>ERROR');
      expect(composition.state().status).assertEqual('ERROR');
      expect(thrownError !== undefined).assertTrue();
      if (thrownError === undefined) {
        return;
      }
      expect(thrownError.stage).assertEqual('PERSISTENCE');
      expect(thrownError.technicalDetail.includes('profiles.example.com')).assertFalse();
      expect(thrownError.technicalDetail.includes('secret-close')).assertFalse();
    });

    it('closeAwaitsApplicationCloseBeforeClosingOwnedControllerAndGraph', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const application = new RecordingApplication();
      const composition = createComposition({
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createProfileApplication: (): ProfileApplication => {
          return application;
        }
      });

      await composition.initialize();
      await composition.close();

      expect(application.closeCallCount).assertEqual(1);
      expect(application.disposeCallCount).assertEqual(0);
      expect(graph.closeCallCount).assertEqual(1);
    });

    it('closeFailureLeavesOwnedResourcesIntactSoRetryCanDrainAndClose', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const application = new RecordingApplication();
      application.closeError = new Error('close leaked https://profiles.example.com/close?token=secret-close');
      const composition = createComposition({
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createProfileApplication: (): ProfileApplication => {
          return application;
        }
      });

      await composition.initialize();

      let firstError: AppError | undefined = undefined;
      try {
        await composition.close();
      } catch (error) {
        firstError = error as AppError;
      }

      expect(firstError !== undefined).assertTrue();
      expect(application.closeCallCount).assertEqual(1);
      expect(graph.closeCallCount).assertEqual(0);

      application.closeError = undefined;
      await composition.close();

      expect(application.closeCallCount).assertEqual(2);
      expect(graph.closeCallCount).assertEqual(1);
    });

    it('ownedRpcCloseFailurePublishesLoadingAndRetryInitializeCreatesFreshTrafficWiring', 0, async () => {
      const firstGraph = new RecordingPlatformGraph();
      const secondGraph = new RecordingPlatformGraph();
      const firstApplication = new RecordingApplication();
      const secondApplication = new RecordingApplication();
      const bundles: HarmonyVpnRpcPlatformBundle[] = [];
      const rpcClients: CompositionRpcClient[] = [];
      const invalidatedStates: ApplicationCompositionState[] = [];
      let reuseSecondAttempt: boolean = false;
      const composition = createComposition({
        coreService: new ProxyCapableRuntimeCoreService(),
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return reuseSecondAttempt ? secondGraph : firstGraph;
        },
        createProfileApplication: (): ProfileApplication => {
          return reuseSecondAttempt ? secondApplication : firstApplication;
        },
        createVpnExtensionAbilityApi: (): InertVpnExtensionAbilityApi => {
          return new InertVpnExtensionAbilityApi();
        },
        createVpnRpcPlatformBundle: (): HarmonyVpnRpcPlatformBundle => {
          const bundle = new StaticHarmonyVpnRpcPlatformBundle();
          bundles.push(bundle);
          return bundle;
        },
        createVpnRpcClient: (): VpnRpcClientPort => {
          const client = new CompositionRpcClient();
          client.closeError = reuseSecondAttempt
            ? undefined
            : new Error('rpc close failed after controller dispose');
          rpcClients.push(client);
          return client;
        }
      });

      await composition.initialize();
      composition.subscribe((state: ApplicationCompositionState): void => {
        invalidatedStates.push(state);
      });

      const firstReadyState = composition.state();
      expect(firstReadyState.status).assertEqual('READY');
      if (firstReadyState.status !== 'READY') {
        return;
      }
      const firstTrafficMonitor = firstReadyState.trafficMonitor;
      expect(firstTrafficMonitor === undefined).assertFalse();

      let firstCloseError: AppError | undefined = undefined;
      try {
        await composition.close();
      } catch (error) {
        firstCloseError = error as AppError;
      }

      expect(firstCloseError !== undefined).assertTrue();
      expect(bundles.length).assertEqual(1);
      expect(rpcClients[0].closeCalls).assertEqual(1);
      expect(firstGraph.closeCallCount).assertEqual(1);
      expect(invalidatedStates.length).assertEqual(1);
      expect(invalidatedStates[0].status).assertEqual('LOADING');
      expect(composition.state().status).assertEqual('LOADING');

      reuseSecondAttempt = true;
      await composition.initialize();

      const secondReadyState = composition.state();
      expect(secondReadyState.status).assertEqual('READY');
      if (secondReadyState.status !== 'READY') {
        return;
      }
      expect(bundles.length).assertEqual(2);
      expect(rpcClients.length).assertEqual(2);
      expect(secondReadyState.trafficMonitor === undefined).assertFalse();
      expect(secondReadyState.trafficMonitor === firstTrafficMonitor).assertFalse();
      expect(rpcClients[1] === rpcClients[0]).assertFalse();
      expect(bundles[1] === bundles[0]).assertFalse();

      await composition.close();

      expect(rpcClients[1].closeCalls).assertEqual(1);
      expect(secondGraph.closeCallCount).assertEqual(1);
    });

  });
}
