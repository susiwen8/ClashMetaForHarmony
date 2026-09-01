import { describe, expect, it } from '@ohos/hypium';
import {
  createAppError,
  createProxyDelaySnapshotResultFromCoreSnapshot,
  createProfile,
  createProxyGroupListQuerySnapshot,
  createProxyGroupQuerySnapshot,
  createProxyGroupSnapshot,
  createProxyRejectedError,
  createProxyRejectedResult,
  createProxyReconcileResult,
  createProxyRuntimeIdentity,
  createProxySelectionAppliedNowResult,
  createProxySelectionAppliedNotPersistedResult,
  createProxySelectionRecord,
  createProxySelectionSavedForNextStartResult,
  createProxyRuntimeNotReadyError,
  createProfileRevision,
  ImportProfileUseCase,
  LeasedRemoteProfileRefresher,
  LocalRuntimeCoordinator,
  type LocalRuntimeCoordinatorDependencies,
  ManageProfileUseCases,
  type ManageProfileUseCasesDependencies,
  ProfileApplication,
  type ProfileApplicationDependencies,
  type ProfileApplicationProfileSnapshot,
  type ProfileApplicationSnapshot,
  ProfileCommitService,
  RefreshProfileUseCase,
  RefreshProfilesUseCase,
  type RefreshProfilesCommand,
  type RefreshProfilesResult,
  SerialCommandQueue,
  createVpnFailure,
  createVpnRuntimeSnapshot,
  type AppError,
  type Clock,
  type CoreEvent,
  type CoreProxyDelaySnapshot,
  type CoreProxyGroupList,
  type CoreProxyGroupResult,
  type CoreProxyQueryContext,
  type CoreProxySelectionApplied,
  type CoreService,
  type IdGenerator,
  type LocalAcquireCommand,
  type LocalOptions,
  type LocalProfileAcquisition,
  type LocalProfileAcquisitionCancelled,
  type LocalRuntimeStartResult,
  type LocalRuntimeStopResult,
  type Profile,
  type ProfileContentStore,
  type ProfileRefreshLeasePort,
  type ProfileRefreshSchedulePort,
  type ProfileRepository,
  type ProfileRevision,
  type ProxyApplicationPort,
  type ProxyDelayResult,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyGroupSnapshot,
  type ProxyRuntimeIdentity,
  type OneClickVpnConfirmationHandle,
  type OneClickVpnConfirmationResult,
  type OneClickVpnConfirmationPort,
  type OneClickVpnOperationListener,
  type OneClickVpnOperationSnapshot,
  type ProxyReconcileResult,
  type ProxyRejectedResult,
  type ProxySelectionResult,
  type SelectNodeAndEnsureVpnResult,
  type ProfileSourceGateway,
  type RemoteAcquireCommand,
  type RemoteProfileAcquisition,
  type RemoteProfileAcquisitionFailure,
  type RuntimeSnapshot,
  type StagedSource,
  type SubscriptionSecretStore,
  type VpnFailure,
  type VpnControllerPort,
  type VpnControllerStartResult,
  type VpnControllerStopResult,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot
} from '../../Index';

interface ManageFailedResultContract {
  kind: 'FAILED';
  error: AppError;
}

interface ManageEnabledResultContract {
  kind: 'ENABLED';
  profile: Profile;
}

interface ManageDeletedResultContract {
  kind: 'DELETED';
  profileId: string;
}

interface ManageReplacedResultContract {
  kind: 'REPLACED';
  profile: Profile;
}

interface ManageUpdatedResultContract {
  kind: 'UPDATED';
  profile: Profile;
  sourceChanged: boolean;
}

type ManageEnableResultContract = ManageEnabledResultContract | ManageFailedResultContract;
type ManageDeleteResultContract = ManageDeletedResultContract | ManageFailedResultContract;
type ManageReplaceResultContract = ManageReplacedResultContract | ManageFailedResultContract;
type ManageUpdateResultContract = ManageUpdatedResultContract | ManageFailedResultContract;

interface ManageProfileUseCasesContract {
  enable(profileId: string): Promise<ManageEnableResultContract>;
  delete(profileId: string): Promise<ManageDeleteResultContract>;
  updateMetadata(profileId: string, name: string, sourceUrl?: string): Promise<ManageUpdateResultContract>;
  replaceSubscriptionUrl(profileId: string, sourceUrl: string): Promise<ManageReplaceResultContract>;
}

interface RefreshFailedResultContract {
  kind: 'FAILED';
  error: AppError;
}

interface RefreshResultContract {
  kind: string;
}

interface UpdateProfileUpdatedResultContract {
  kind: 'UPDATED';
  profile: Profile;
}

interface UpdateProfileRefreshFailedResultContract {
  kind: 'UPDATED_REFRESH_FAILED';
  profile: Profile;
  error: AppError;
}

interface UpdateProfileFailedResultContract {
  kind: 'FAILED';
  error: AppError;
}

type UpdateProfileResultContract =
  | UpdateProfileUpdatedResultContract
  | UpdateProfileRefreshFailedResultContract
  | UpdateProfileFailedResultContract;

interface RefreshAllSubscriptionsCompletedResultContract {
  kind: 'COMPLETED';
  result: RefreshProfilesResult;
}

interface RefreshAllSubscriptionsFailedResultContract {
  kind: 'FAILED';
  error: AppError;
}

type RefreshAllSubscriptionsResultContract =
  | RefreshAllSubscriptionsCompletedResultContract
  | RefreshAllSubscriptionsFailedResultContract;

interface ProfileApplicationSubscriptionTask5AContract {
  refreshAllSubscriptions(): Promise<RefreshAllSubscriptionsResultContract>;
  updateAutoUpdateInterval(profileId: string, intervalMs: number): Promise<UpdateProfileResultContract>;
  reloadFromRepository(): Promise<void>;
}

class RuntimeCoordinatorDependencyBag implements LocalRuntimeCoordinatorDependencies {
  readonly repository: FakeProfileRepository;
  readonly contentStore: FakeProfileContentStore;
  readonly coreService: FakeCoreService;
  readonly clock: FakeClock;

  constructor(
    repository: FakeProfileRepository,
    contentStore: FakeProfileContentStore,
    coreService: FakeCoreService,
    clock: FakeClock
  ) {
    this.repository = repository;
    this.contentStore = contentStore;
    this.coreService = coreService;
    this.clock = clock;
  }
}

class ManageProfileUseCasesDependencyBag implements ManageProfileUseCasesDependencies {
  readonly repository: FakeProfileRepository;
  readonly contentStore: FakeProfileContentStore;
  readonly secretStore: FakeSubscriptionSecretStore;
  readonly coreService: FakeCoreService;
  readonly clock: FakeClock;
  readonly runtimeCoordinator: LocalRuntimeCoordinator;

  constructor(
    repository: FakeProfileRepository,
    contentStore: FakeProfileContentStore,
    secretStore: FakeSubscriptionSecretStore,
    coreService: FakeCoreService,
    clock: FakeClock,
    runtimeCoordinator: LocalRuntimeCoordinator
  ) {
    this.repository = repository;
    this.contentStore = contentStore;
    this.secretStore = secretStore;
    this.coreService = coreService;
    this.clock = clock;
    this.runtimeCoordinator = runtimeCoordinator;
  }
}

class ProfileApplicationDependencyBag implements ProfileApplicationDependencies {
  readonly importUseCase: ImportProfileUseCase;
  readonly refreshUseCase: RefreshProfileUseCase;
  readonly refreshProfilesUseCase?: FakeRefreshProfilesUseCase;
  readonly profileRefreshSchedule?: ProfileRefreshSchedulePort;
  readonly manageProfileUseCases: ManageProfileUseCases;
  readonly runtimeCoordinator: LocalRuntimeCoordinator;
  readonly commitService: ProfileCommitService;
  readonly repository: FakeProfileRepository;
  readonly vpnController?: VpnControllerPort;
  readonly oneClickVpnConfirmation: OneClickVpnConfirmationPort;
  readonly proxyService: ProxyApplicationPort;
  readonly idGenerator?: IdGenerator;

  constructor(
    importUseCase: ImportProfileUseCase,
    refreshUseCase: RefreshProfileUseCase,
    refreshProfilesUseCase: FakeRefreshProfilesUseCase | undefined,
    profileRefreshSchedule: ProfileRefreshSchedulePort | undefined,
    manageProfileUseCases: ManageProfileUseCases,
    runtimeCoordinator: LocalRuntimeCoordinator,
    commitService: ProfileCommitService,
    repository: FakeProfileRepository,
    oneClickVpnConfirmation: OneClickVpnConfirmationPort,
    proxyService: ProxyApplicationPort,
    vpnController?: VpnControllerPort,
    idGenerator?: IdGenerator
  ) {
    this.importUseCase = importUseCase;
    this.refreshUseCase = refreshUseCase;
    this.refreshProfilesUseCase = refreshProfilesUseCase;
    this.profileRefreshSchedule = profileRefreshSchedule;
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

class FakeClock implements Clock {
  private readonly timestamps: string[];
  private index: number = 0;

  constructor(timestamps: string[]) {
    this.timestamps = timestamps.slice();
  }

  now(): string {
    const safeIndex: number = Math.min(this.index, this.timestamps.length - 1);
    const value: string = this.timestamps[safeIndex];
    this.index += 1;
    return value;
  }
}

class FakeIdGenerator implements IdGenerator {
  private readonly ids: string[];
  private index: number = 0;

  constructor(ids: string[]) {
    this.ids = ids.slice();
  }

  nextId(): string {
    const safeIndex: number = Math.min(this.index, this.ids.length - 1);
    const value: string = this.ids[safeIndex];
    this.index += 1;
    return value;
  }
}

class CancelledLocalAcquisition implements LocalProfileAcquisitionCancelled {
  kind: 'CANCELLED' = 'CANCELLED';
}

class RemoteFailureAcquisition implements RemoteProfileAcquisitionFailure {
  kind: 'FAILED' = 'FAILED';
  error: AppError;
  profileName: string;
  sourceDisplay: string;
  shouldPersistInvalidProfile: boolean;

  constructor(error: AppError, profileName: string, sourceDisplay: string) {
    this.error = error;
    this.profileName = profileName;
    this.sourceDisplay = sourceDisplay;
    this.shouldPersistInvalidProfile = false;
  }
}

class FakeSourceGateway implements ProfileSourceGateway {
  readonly localCommands: LocalAcquireCommand[] = [];
  readonly remoteCommands: RemoteAcquireCommand[] = [];
  sharedLog?: string[];
  private readonly queuedRemoteAcquisitions: RemoteProfileAcquisition[] = [];

  async acquireLocal(command: LocalAcquireCommand): Promise<LocalProfileAcquisition> {
    this.sharedLog?.push(`source.acquireLocal:${command.preferredName}`);
    this.localCommands.push(command);
    return new CancelledLocalAcquisition();
  }

  async acquireRemote(command: RemoteAcquireCommand): Promise<RemoteProfileAcquisition> {
    this.sharedLog?.push(`source.acquireRemote:${command.profileName}`);
    this.remoteCommands.push(command);
    if (this.queuedRemoteAcquisitions.length > 0) {
      return this.queuedRemoteAcquisitions.shift()!;
    }
    return new RemoteFailureAcquisition(
      createAppError('DOWNLOAD', 'remote gateway should stay unused in this test', {
        timestamp: buildTimestamp(59),
        retryable: false
      }),
      command.profileName,
      command.sourceDisplay
    );
  }

  queueRemoteAcquisition(acquisition: RemoteProfileAcquisition): void {
    this.queuedRemoteAcquisitions.push(acquisition);
  }
}

class FakeProfileRefreshLeasePort implements ProfileRefreshLeasePort {
  sharedLog?: string[];
  tryAcquireCallCount: number = 0;

  async tryAcquire(profileId: string, _ownerToken: string, _nowMs: number, _expiresAtMs: number): Promise<boolean> {
    this.tryAcquireCallCount += 1;
    this.sharedLog?.push(`lease.tryAcquire:${profileId}`);
    return true;
  }

  async renew(_profileId: string, _ownerToken: string, _nowMs: number, _expiresAtMs: number): Promise<boolean> {
    return true;
  }

  async release(profileId: string, _ownerToken: string): Promise<boolean> {
    this.sharedLog?.push(`lease.release:${profileId}`);
    return true;
  }
}

class FakeRefreshProfilesUseCase extends RefreshProfilesUseCase {
  readonly commands: RefreshProfilesCommand[] = [];
  sharedLog?: string[];
  error?: Error;
  executeDeferred?: DeferredVoid;
  executeEntered?: DeferredVoid;
  result: RefreshProfilesResult = {
    items: [],
    deadlineReached: false,
    cancelled: false,
    remainingCount: 0
  };

  constructor() {
    super({
      repository: new FakeProfileRepository([]),
      executor: {
        async execute() {
          throw new Error('fake batch executor should stay unused');
        }
      },
      clock: new FakeClock([buildTimestamp(0)])
    });
  }

  async execute(command: RefreshProfilesCommand): Promise<RefreshProfilesResult> {
    this.sharedLog?.push(`batch.execute:${command.mode}`);
    this.commands.push({
      mode: command.mode,
      deadlineMs: command.deadlineMs,
      isCancelled: command.isCancelled
    });
    if (this.error !== undefined) {
      throw this.error;
    }
    if (this.executeEntered !== undefined) {
      this.executeEntered.resolve();
    }
    if (this.executeDeferred !== undefined) {
      await this.executeDeferred.promise;
    }
    return cloneRefreshProfilesResult(this.result);
  }
}

class FakeProfileRefreshSchedulePort implements ProfileRefreshSchedulePort {
  readonly reconcileCalls: boolean[] = [];
  sharedLog?: string[];
  error?: Error;

  async reconcile(enabled: boolean): Promise<void> {
    this.sharedLog?.push(`schedule.reconcile:${enabled}`);
    this.reconcileCalls.push(enabled);
    if (this.error !== undefined) {
      throw this.error;
    }
  }
}

class FakeProfileRepository implements ProfileRepository {
  readonly log: string[] = [];
  readonly savedProfiles: Profile[] = [];
  readonly deletedIds: string[] = [];
  readonly setActiveIdCalls: (string | undefined)[] = [];
  sharedLog?: string[];
  private readonly profiles: Map<string, Profile> = new Map();
  private activeIdValue: string | undefined;
  saveError?: Error;
  deleteError?: Error;
  getError?: Error;
  setActiveIdError?: Error;
  saveDeferred?: DeferredVoid;
  saveEntered?: DeferredVoid;

  constructor(seedProfiles: Profile[], activeId?: string) {
    for (let index = 0; index < seedProfiles.length; index += 1) {
      this.profiles.set(seedProfiles[index].id, cloneProfile(seedProfiles[index]));
    }
    this.activeIdValue = activeId;
  }

  async list(): Promise<Profile[]> {
    this.log.push('repository.list');
    this.sharedLog?.push('repository.list');
    const profiles: Profile[] = [];
    this.profiles.forEach((profile) => {
      profiles.push(cloneProfile(profile));
    });
    return profiles;
  }

  async get(id: string): Promise<Profile | undefined> {
    this.log.push(`repository.get:${id}`);
    this.sharedLog?.push(`repository.get:${id}`);
    if (this.getError !== undefined) {
      throw this.getError;
    }
    const profile: Profile | undefined = this.profiles.get(id);
    return profile === undefined ? undefined : cloneProfile(profile);
  }

  async save(profile: Profile): Promise<void> {
    this.log.push(`repository.save:${profile.id}`);
    this.sharedLog?.push(`repository.save:${profile.id}`);
    if (this.saveError !== undefined) {
      throw this.saveError;
    }
    if (this.saveEntered !== undefined) {
      this.saveEntered.resolve();
    }
    if (this.saveDeferred !== undefined) {
      await this.saveDeferred.promise;
    }
    this.profiles.set(profile.id, cloneProfile(profile));
    this.savedProfiles.push(cloneProfile(profile));
  }

  async deleteAndClearActive(id: string): Promise<void> {
    this.log.push(`repository.deleteAndClearActive:${id}`);
    this.sharedLog?.push(`repository.deleteAndClearActive:${id}`);
    if (this.deleteError !== undefined) {
      throw this.deleteError;
    }
    this.deletedIds.push(id);
    this.profiles.delete(id);
    if (this.activeIdValue === id) {
      this.activeIdValue = undefined;
    }
  }

  async getActiveId(): Promise<string | undefined> {
    this.log.push('repository.getActiveId');
    this.sharedLog?.push('repository.getActiveId');
    return this.activeIdValue;
  }

  async setActiveId(id: string | undefined): Promise<void> {
    this.log.push(`repository.setActiveId:${id ?? 'undefined'}`);
    this.sharedLog?.push(`repository.setActiveId:${id ?? 'undefined'}`);
    if (this.setActiveIdError !== undefined) {
      throw this.setActiveIdError;
    }
    this.activeIdValue = id;
    this.setActiveIdCalls.push(id);
  }

  readProfile(id: string): Profile | undefined {
    const profile: Profile | undefined = this.profiles.get(id);
    return profile === undefined ? undefined : cloneProfile(profile);
  }

  readActiveId(): string | undefined {
    return this.activeIdValue;
  }

  overwriteProfile(profile: Profile): void {
    this.profiles.set(profile.id, cloneProfile(profile));
  }
}

class FakeProfileContentStore implements ProfileContentStore {
  readonly log: string[] = [];
  readonly retainCalls: string[] = [];
  readonly resolvedPaths: Map<string, string> = new Map();
  readonly removedProfiles: string[] = [];
  readonly reconciledPaths: string[][] = [];
  resolveError?: Error;
  removeProfileError?: Error;
  private readonly queuedRetainResults: ProfileRevision[] = [];

  async retain(profileId: string, _staged: StagedSource, kind: 'CURRENT' | 'FAILED_CANDIDATE'): Promise<ProfileRevision> {
    this.log.push(`content.retain:${profileId}:${kind}`);
    this.retainCalls.push(`${profileId}:${kind}`);
    if (this.queuedRetainResults.length > 0) {
      return this.queuedRetainResults.shift()!;
    }
    throw new Error('retain should stay unused in Task4 management tests');
  }

  async discard(_staged: StagedSource): Promise<void> {
  }

  async removeRevision(_revision: ProfileRevision): Promise<void> {
  }

  async removeProfile(profileId: string): Promise<void> {
    this.log.push(`content.removeProfile:${profileId}`);
    if (this.removeProfileError !== undefined) {
      throw this.removeProfileError;
    }
    this.removedProfiles.push(profileId);
  }

  async reconcile(referenced: ProfileRevision[]): Promise<void> {
    this.log.push('content.reconcile');
    const paths: string[] = [];
    for (let index = 0; index < referenced.length; index += 1) {
      paths.push(referenced[index].relativePath);
    }
    this.reconciledPaths.push(paths);
  }

  resolveCorePath(revision: ProfileRevision): string {
    this.log.push(`content.resolveCorePath:${revision.relativePath}`);
    if (this.resolveError !== undefined) {
      throw this.resolveError;
    }
    const resolved: string | undefined = this.resolvedPaths.get(revision.relativePath);
    return resolved ?? `/sandbox/${revision.relativePath}`;
  }

  queueRetainResult(revision: ProfileRevision): void {
    this.queuedRetainResults.push(revision);
  }
}

class FakeSubscriptionSecretStore implements SubscriptionSecretStore {
  readonly encryptCalls: string[] = [];
  readonly removeCalls: string[] = [];
  readonly storedSecrets: Map<string, string> = new Map();
  encryptError?: Error;
  encryptDeferred?: DeferredString;
  encryptEntered?: DeferredVoid;
  removeError?: Error;
  removeErrorSecretRef?: string;

  async encrypt(plaintext: string): Promise<string> {
    this.encryptCalls.push(plaintext);
    if (this.encryptError !== undefined) {
      throw this.encryptError;
    }
    if (this.encryptEntered !== undefined) {
      this.encryptEntered.resolve();
    }
    if (this.encryptDeferred !== undefined) {
      return await this.encryptDeferred.promise;
    }
    const secretRef: string = `secret-${this.encryptCalls.length}`;
    this.storedSecrets.set(secretRef, plaintext);
    return secretRef;
  }

  async decrypt(secretRef: string): Promise<string> {
    const storedValue: string | undefined = this.storedSecrets.get(secretRef);
    if (storedValue === undefined) {
      throw new Error('secret missing');
    }
    return storedValue;
  }

  async remove(secretRef: string): Promise<void> {
    this.removeCalls.push(secretRef);
    if (this.removeError !== undefined &&
      (this.removeErrorSecretRef === undefined || this.removeErrorSecretRef === secretRef)) {
      throw this.removeError;
    }
    this.storedSecrets.delete(secretRef);
  }
}

class DeferredRuntimeSnapshot {
  readonly promise: Promise<RuntimeSnapshot>;
  private resolveRef?: (value: RuntimeSnapshot) => void;

  constructor() {
    this.promise = new Promise<RuntimeSnapshot>((resolve) => {
      this.resolveRef = resolve;
    });
  }

  resolve(value: RuntimeSnapshot): void {
    this.resolveRef!(value);
  }
}

class DeferredVoid {
  readonly promise: Promise<void>;
  private resolveRef?: () => void;

  constructor() {
    this.promise = new Promise<void>((resolve) => {
      this.resolveRef = resolve;
    });
  }

  resolve(): void {
    this.resolveRef!();
  }
}

class DeferredString {
  readonly promise: Promise<string>;
  private resolveRef?: (value: string) => void;

  constructor() {
    this.promise = new Promise<string>((resolve) => {
      this.resolveRef = resolve;
    });
  }

  resolve(value: string): void {
    this.resolveRef!(value);
  }
}

class FakeCoreService implements CoreService {
  readonly log: string[] = [];
  readonly validateCalls: string[] = [];
  readonly loadCalls: string[] = [];
  readonly startCalls: LocalOptions[] = [];
  readonly stopCalls: string[] = [];
  readonly subscribeIds: number[] = [];
  readonly callbacks: Map<number, (event: CoreEvent) => void> = new Map();
  sharedLog?: string[];
  runtimeSnapshotValue: RuntimeSnapshot = buildRuntimeSnapshot('STOPPED');
  validateError?: Error;
  loadError?: Error;
  stopError?: Error;
  startDeferred?: DeferredRuntimeSnapshot;
  stopDeferred?: DeferredRuntimeSnapshot;
  validateDeferred?: DeferredVoid;
  validateEntered?: DeferredVoid;
  stopEntered?: DeferredVoid;
  private nextSubscriptionId: number = 1;

  hello(): string {
    return 'hello';
  }

  async coreVersion(): Promise<string> {
    return 'core';
  }

  async validateConfiguration(path: string): Promise<void> {
    this.log.push(`core.validate:${path}`);
    this.sharedLog?.push(`core.validate:${path}`);
    this.validateCalls.push(path);
    if (this.validateError !== undefined) {
      throw this.validateError;
    }
    if (this.validateEntered !== undefined) {
      this.validateEntered.resolve();
    }
    if (this.validateDeferred !== undefined) {
      await this.validateDeferred.promise;
    }
  }

  async loadConfiguration(path: string): Promise<void> {
    this.log.push(`core.load:${path}`);
    this.sharedLog?.push(`core.load:${path}`);
    this.loadCalls.push(path);
    if (this.loadError !== undefined) {
      throw this.loadError;
    }
  }

  async startLocal(options: LocalOptions): Promise<RuntimeSnapshot> {
    this.log.push(`core.startLocal:${options.configPath}:${options.mixedPort}`);
    this.sharedLog?.push(`core.startLocal:${options.configPath}:${options.mixedPort}`);
    this.startCalls.push(options);
    if (this.startDeferred !== undefined) {
      return await this.startDeferred.promise;
    }
    return cloneRuntimeSnapshot(this.runtimeSnapshotValue);
  }

  async stopRuntime(): Promise<RuntimeSnapshot> {
    this.log.push('core.stopRuntime');
    this.sharedLog?.push('core.stopRuntime');
    this.stopCalls.push('stop');
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
    if (this.stopEntered !== undefined) {
      this.stopEntered.resolve();
    }
    if (this.stopDeferred !== undefined) {
      return await this.stopDeferred.promise;
    }
    return cloneRuntimeSnapshot(this.runtimeSnapshotValue);
  }

  runtimeSnapshot(): RuntimeSnapshot {
    this.log.push('core.runtimeSnapshot');
    this.sharedLog?.push('core.runtimeSnapshot');
    return cloneRuntimeSnapshot(this.runtimeSnapshotValue);
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

  subscribe(_callback: (event: CoreEvent) => void): number {
    const callback: (event: CoreEvent) => void = _callback;
    const subscriptionId: number = this.nextSubscriptionId;
    this.nextSubscriptionId += 1;
    this.log.push(`core.subscribe:${subscriptionId}`);
    this.subscribeIds.push(subscriptionId);
    this.callbacks.set(subscriptionId, callback);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.log.push(`core.unsubscribe:${subscriptionId}`);
    this.callbacks.delete(subscriptionId);
  }

  emitRuntime(state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR', message: string): void {
    const callbacks: Array<(event: CoreEvent) => void> = [];
    this.callbacks.forEach((callback) => {
      callbacks.push(callback);
    });
    for (let index = 0; index < callbacks.length; index += 1) {
      callbacks[index]({
        type: 'runtime',
        state,
        message
      });
    }
  }
}

class VpnStartCallRecord {
  profileId: string = '';
  versionId: string = '';
  sessionId: string = '';
}

class UnavailableVpnCase {
  repository: FakeProfileRepository;
  contentStore: FakeProfileContentStore;
  secretStore: FakeSubscriptionSecretStore;

  constructor(
    repository: FakeProfileRepository,
    contentStore: FakeProfileContentStore,
    secretStore: FakeSubscriptionSecretStore
  ) {
    this.repository = repository;
    this.contentStore = contentStore;
    this.secretStore = secretStore;
  }
}

class FakeVpnController implements VpnControllerPort {
  readonly startCalls: VpnStartCallRecord[] = [];
  readonly stopCalls: (string | undefined)[] = [];
  readonly subscribeIds: number[] = [];
  readonly unsubscribeIds: number[] = [];
  sharedLog?: string[];
  private readonly listeners: Map<number, (event: VpnRuntimeEvent) => void> = new Map();
  private readonly queuedStartResults: VpnControllerStartResult[] = [];
  private readonly queuedStopResults: VpnControllerStopResult[] = [];
  private nextSubscriptionId: number = 1;
  startError?: Error;
  private snapshotValue: VpnRuntimeSnapshot = createVpnRuntimeSnapshot({
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

  async start(profileId: string, versionId: string, sessionId: string): Promise<VpnControllerStartResult> {
    this.sharedLog?.push(`vpn.start:${profileId}:${versionId}:${sessionId}`);
    const callRecord: VpnStartCallRecord = new VpnStartCallRecord();
    callRecord.profileId = profileId;
    callRecord.versionId = versionId;
    callRecord.sessionId = sessionId;
    this.startCalls.push(callRecord);
    if (this.startError !== undefined) {
      throw this.startError;
    }
    if (this.queuedStartResults.length > 0) {
      const result: VpnControllerStartResult = this.queuedStartResults.shift()!;
      this.snapshotValue = result.snapshot;
      return result;
    }
    this.snapshotValue = createVpnRuntimeSnapshot({
      state: 'RUNNING',
      activeRequest: {
        profileId,
        versionId,
        sessionId
      },
      activeHandle: {
        sessionId,
        attached: true
      },
      captureConfig: null,
      tunSnapshot: null,
      notificationActive: true,
      recoveryAttempt: 0,
      scheduledRetryDelayMs: null,
      lastFailure: null
    });
    return {
      kind: 'STARTED',
      snapshot: this.snapshot()
    };
  }

  async stop(sessionId?: string): Promise<VpnControllerStopResult> {
    this.sharedLog?.push(`vpn.stop:${sessionId ?? 'current'}`);
    this.stopCalls.push(sessionId);
    if (this.queuedStopResults.length > 0) {
      const result: VpnControllerStopResult = this.queuedStopResults.shift()!;
      this.snapshotValue = result.snapshot;
      return result;
    }
    this.snapshotValue = createVpnRuntimeSnapshot({
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
    const subscriptionId: number = this.nextSubscriptionId;
    this.nextSubscriptionId += 1;
    this.subscribeIds.push(subscriptionId);
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.unsubscribeIds.push(subscriptionId);
    this.listeners.delete(subscriptionId);
  }

  queueStartResult(result: VpnControllerStartResult): void {
    this.queuedStartResults.push(result);
  }

  queueStopResult(result: VpnControllerStopResult): void {
    this.queuedStopResults.push(result);
  }

  setSnapshot(snapshot: VpnRuntimeSnapshot): void {
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
  }

  emit(
    snapshot: VpnRuntimeSnapshot,
    type: 'SNAPSHOT' | 'STATE_CHANGED' | 'FAILED' | 'RECOVERY_SCHEDULED' | 'STOPPED' = 'SNAPSHOT'
  ): void {
    this.setSnapshot(snapshot);
    const listeners: Array<(event: VpnRuntimeEvent) => void> = [];
    this.listeners.forEach((listener) => {
      listeners.push(listener);
    });
    for (let index = 0; index < listeners.length; index += 1) {
      listeners[index]({
        type,
        snapshot: this.snapshot()
      });
    }
  }
}

class CancelledOneClickVpnConfirmationResultValue implements OneClickVpnConfirmationResult {
  kind: 'CANCELLED' = 'CANCELLED';
}

class DeferredOneClickVpnConfirmationResult {
  readonly promise: Promise<OneClickVpnConfirmationResult>;
  private resolved: boolean = false;
  private resolveRef?: (value: OneClickVpnConfirmationResult) => void;

  constructor() {
    this.promise = new Promise<OneClickVpnConfirmationResult>((resolve) => {
      this.resolveRef = resolve;
    });
  }

  resolve(value: OneClickVpnConfirmationResult): void {
    if (this.resolved) {
      return;
    }
    this.resolved = true;
    this.resolveRef!(value);
  }
}

function createOneClickConfirmationResult(
  kind: 'RUNNING' | 'STOPPED' | 'ERROR' | 'SESSION_CHANGED' | 'TIMEOUT' | 'CANCELLED'
): OneClickVpnConfirmationResult {
  return { kind };
}

class FakeOneClickVpnConfirmationHandle implements OneClickVpnConfirmationHandle {
  readonly waitDeferred: DeferredOneClickVpnConfirmationResult = new DeferredOneClickVpnConfirmationResult();
  waitCalls: number = 0;
  markStartAcceptedCalls: number = 0;
  cancelCalls: number = 0;
  sharedLog?: string[];
  markError?: Error;
  waitError?: Error;

  constructor(initialKind?: 'RUNNING' | 'STOPPED' | 'ERROR' | 'SESSION_CHANGED' | 'TIMEOUT' | 'CANCELLED') {
    if (initialKind !== undefined) {
      this.waitDeferred.resolve(createOneClickConfirmationResult(initialKind));
    }
  }

  async wait(): Promise<OneClickVpnConfirmationResult> {
    this.waitCalls += 1;
    if (this.waitError !== undefined) {
      return await Promise.reject(this.waitError);
    }
    return await this.waitDeferred.promise;
  }

  markStartAccepted(): void {
    this.markStartAcceptedCalls += 1;
    this.sharedLog?.push('confirm.accepted');
    if (this.markError !== undefined) {
      throw this.markError;
    }
  }

  cancel(): void {
    this.cancelCalls += 1;
    this.sharedLog?.push('confirm.cancel');
  }

  resolve(kind: 'RUNNING' | 'STOPPED' | 'ERROR' | 'SESSION_CHANGED' | 'TIMEOUT' | 'CANCELLED'): void {
    this.waitDeferred.resolve(createOneClickConfirmationResult(kind));
  }
}

class FakeOneClickVpnConfirmation implements OneClickVpnConfirmationPort {
  readonly armCalls: string[] = [];
  readonly handles: FakeOneClickVpnConfirmationHandle[] = [];
  sharedLog?: string[];
  armError?: Error;
  private readonly queuedHandles: FakeOneClickVpnConfirmationHandle[] = [];

  queueHandle(handle: FakeOneClickVpnConfirmationHandle): void {
    this.queuedHandles.push(handle);
  }

  arm(expectedSessionId: string, timeoutMs: number): OneClickVpnConfirmationHandle {
    this.armCalls.push(`${expectedSessionId}:${timeoutMs}`);
    this.sharedLog?.push(`confirm.arm:${expectedSessionId}`);
    if (this.armError !== undefined) {
      throw this.armError;
    }
    const handle: FakeOneClickVpnConfirmationHandle = this.queuedHandles.shift() ?? new FakeOneClickVpnConfirmationHandle('CANCELLED');
    handle.sharedLog = this.sharedLog;
    this.handles.push(handle);
    return handle;
  }
}

class FakeProxyApplication implements ProxyApplicationPort {
  listGroupsCalls: number = 0;
  readonly queryGroupCalls: string[] = [];
  readonly queryGroupRequests: FakeQueryGroupRequest[] = [];
  readonly selectCalls: string[] = [];
  readonly startDelayCalls: string[] = [];
  readonly readDelayCalls: string[] = [];
  readonly cancelDelayCalls: string[] = [];
  cancelAndDrainCalls: number = 0;
  reconcileCalls: number = 0;
  sharedLog?: string[];
  listGroupsError?: Error;
  queryGroupError?: Error;
  drainResult?: ProxyRejectedResult;
  drainError?: Error;
  drainDeferred?: DeferredVoid;
  drainEntered?: DeferredVoid;
  reconcileResult: ProxyReconcileResult = createProxyReconcileResult(buildDigest('proxy-profile'), buildDigest('proxy-revision'), 2, 1);
  private readonly queuedListGroupsResults: ProxyGroupListQueryResult[] = [];
  private readonly queuedQueryGroupResults: Map<string, ProxyGroupQueryResult[]> = new Map();
  private readonly queuedSelectResults: ProxySelectionResult[] = [];

  async listGroups(): Promise<ProxyGroupListQueryResult> {
    this.listGroupsCalls += 1;
    if (this.listGroupsError !== undefined) {
      throw this.listGroupsError;
    }
    if (this.queuedListGroupsResults.length > 0) {
      return this.queuedListGroupsResults.shift()!;
    }
    return createProxyGroupListQuerySnapshot(
      createProxyRuntimeIdentity('active', buildTimestamp(1), buildDigest('proxy-revision'), null),
      1,
      [{ name: 'Selector', type: 'Selector' }]
    );
  }

  async queryGroup(groupName: string, groupPath?: string[]): Promise<ProxyGroupQueryResult> {
    this.sharedLog?.push(`proxy.query:${groupName}`);
    this.queryGroupCalls.push(groupName);
    this.queryGroupRequests.push(new FakeQueryGroupRequest(groupName, groupPath === undefined ? [] : groupPath.slice()));
    if (this.queryGroupError !== undefined) {
      throw this.queryGroupError;
    }
    const queuedQueryResults: ProxyGroupQueryResult[] | undefined = this.queuedQueryGroupResults.get(groupName);
    if (queuedQueryResults !== undefined && queuedQueryResults.length > 0) {
      return queuedQueryResults.shift()!;
    }
    return createProxyGroupQuerySnapshot(
      createProxyGroupSnapshot(
        createProxyRuntimeIdentity('active', buildTimestamp(1), buildDigest('proxy-revision'), null),
        2,
        {
          name: groupName,
          type: 'Selector',
          selectedName: 'Node A',
          nodes: [{ name: 'Node A', type: 'Shadowsocks', isGroup: false, selected: true }]
        }
      )
    );
  }

  async select(
    groupName: string,
    memberName: string,
    snapshotGeneration: number,
    _groupPath?: string[]
  ): Promise<ProxySelectionResult> {
    this.sharedLog?.push(`proxy.select:${groupName}:${memberName}:${snapshotGeneration}`);
    this.selectCalls.push(`${groupName}:${memberName}:${snapshotGeneration}`);
    if (this.queuedSelectResults.length > 0) {
      return this.queuedSelectResults.shift()!;
    }
    return createProxySelectionSavedForNextStartResult(
      createProxySelectionRecord('active', groupName, memberName, buildTimestamp(1), buildTimestamp(26)),
      buildTimestamp(27)
    );
  }

  async startDelayTest(groupName: string, snapshotGeneration: number, _groupPath?: string[]): Promise<ProxyDelayResult> {
    this.startDelayCalls.push(`${groupName}:${snapshotGeneration}`);
    return createProxyDelaySnapshotResultFromCoreSnapshot(
      createProxyRuntimeIdentity('active', buildTimestamp(1), buildDigest('proxy-revision'), null),
      snapshotGeneration,
      groupName,
      buildDelaySnapshot(groupName, snapshotGeneration, 'delay-job-1', 'RUNNING')
    );
  }

  async readDelayTest(jobId: string): Promise<ProxyDelayResult> {
    this.readDelayCalls.push(jobId);
    return createProxyDelaySnapshotResultFromCoreSnapshot(
      createProxyRuntimeIdentity('active', buildTimestamp(1), buildDigest('proxy-revision'), null),
      3,
      'Selector',
      buildDelaySnapshot('Selector', 3, jobId, 'COMPLETED')
    );
  }

  async cancelDelayTest(jobId: string): Promise<ProxyDelayResult> {
    this.cancelDelayCalls.push(jobId);
    return createProxyDelaySnapshotResultFromCoreSnapshot(
      createProxyRuntimeIdentity('active', buildTimestamp(1), buildDigest('proxy-revision'), null),
      4,
      'Selector',
      buildDelaySnapshot('Selector', 4, jobId, 'CANCELLED')
    );
  }

  async cancelAndDrainDelayTest(): Promise<ProxyRejectedResult | undefined> {
    this.sharedLog?.push('proxy.drain');
    this.cancelAndDrainCalls += 1;
    if (this.drainError !== undefined) {
      throw this.drainError;
    }
    if (this.drainEntered !== undefined) {
      this.drainEntered.resolve();
      this.drainEntered = undefined;
    }
    if (this.drainDeferred !== undefined) {
      const deferred: DeferredVoid = this.drainDeferred;
      this.drainDeferred = undefined;
      await deferred.promise;
    }
    return this.drainResult;
  }

  async reconcileActiveSelections(): Promise<ProxyReconcileResult> {
    this.sharedLog?.push('proxy.reconcile');
    this.reconcileCalls += 1;
    return this.reconcileResult;
  }

  queueListGroupsResult(result: ProxyGroupListQueryResult): void {
    this.queuedListGroupsResults.push(result);
  }

  queueQueryGroupResult(groupName: string, result: ProxyGroupQueryResult): void {
    const queuedResults: ProxyGroupQueryResult[] = this.queuedQueryGroupResults.get(groupName) ?? [];
    queuedResults.push(result);
    this.queuedQueryGroupResults.set(groupName, queuedResults);
  }

  queueSelectResult(result: ProxySelectionResult): void {
    this.queuedSelectResults.push(result);
  }
}

class FakeQueryGroupRequest {
  groupName: string;
  groupPath: string[];

  constructor(groupName: string, groupPath: string[]) {
    this.groupName = groupName;
    this.groupPath = groupPath.slice();
  }
}

function buildDelaySnapshot(
  groupName: string,
  generation: number,
  jobId: string,
  state: 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED'
): CoreProxyDelaySnapshot {
  const nodeState: 'TESTING' | 'AVAILABLE' | 'CANCELLED' | 'FAILED' = state === 'RUNNING'
    ? 'TESTING'
    : state === 'CANCELLED'
      ? 'CANCELLED'
      : state === 'FAILED'
        ? 'FAILED'
        : 'AVAILABLE';
  return {
    schemaVersion: '1.0.0',
    profileHash: buildDigest('proxy-profile'),
    revisionHash: buildDigest('proxy-revision'),
    sessionHash: null,
    generation,
    groupName,
    jobId,
    state,
    totalCount: 1,
    testableCount: 1,
    completedCount: state === 'RUNNING' ? 0 : 1,
    availableCount: nodeState === 'AVAILABLE' ? 1 : 0,
    timeoutCount: 0,
    failedCount: nodeState === 'FAILED' ? 1 : 0,
    cancelledCount: nodeState === 'CANCELLED' ? 1 : 0,
    unsupportedCount: 0,
    fastestNodeIndex: nodeState === 'AVAILABLE' ? 0 : null,
    nodes: [{
      index: 0,
      name: 'Node A',
      type: 'Shadowsocks',
      state: nodeState,
      delayMs: nodeState === 'AVAILABLE' ? 88 : null,
      source: nodeState === 'AVAILABLE' ? 'PROVIDER' : null,
      fastest: nodeState === 'AVAILABLE'
    }]
  };
}

interface ProxyNodeSelectionInput {
  name: string;
  selected: boolean;
  isGroup: boolean;
}

class ProxyNodeSelectionInputValue implements ProxyNodeSelectionInput {
  name: string;
  selected: boolean;
  isGroup: boolean;

  constructor(name: string, selected: boolean, isGroup: boolean = false) {
    this.name = name;
    this.selected = selected;
    this.isGroup = isGroup;
  }
}

class CoreProxyNodeSummaryValue {
  name: string = '';
  type: 'Shadowsocks' = 'Shadowsocks';
  isGroup: boolean = false;
  selected: boolean = false;
}

class CoreProxyGroupRefValue {
  name: string = '';
  type: 'Selector' = 'Selector';
}

class RawCoreProxyGroupSnapshotValue {
  name: string = '';
  type: 'Selector' = 'Selector';
  selectedName: string = '';
  nodes: CoreProxyNodeSummaryValue[] = [];
}

class RawProxyGroupSnapshotValue implements ProxyGroupSnapshot {
  identity: ProxyRuntimeIdentity = createProxyRuntimeIdentity('one-click', buildTimestamp(1), buildDigest('proxy-revision'), null);
  generation: number = 0;
  group: RawCoreProxyGroupSnapshotValue = new RawCoreProxyGroupSnapshotValue();
}

class RawProxyGroupQuerySnapshotResultValue {
  kind: 'SNAPSHOT' = 'SNAPSHOT';
  snapshot: ProxyGroupSnapshot = new RawProxyGroupSnapshotValue();
}

function buildProxyNodeSelectionInput(name: string, selected: boolean, isGroup: boolean = false): ProxyNodeSelectionInput {
  return new ProxyNodeSelectionInputValue(name, selected, isGroup);
}

function buildCoreProxyNodeSummaries(nodes: ProxyNodeSelectionInput[]): CoreProxyNodeSummaryValue[] {
  const summaries: CoreProxyNodeSummaryValue[] = [];
  for (let index = 0; index < nodes.length; index += 1) {
    const summary: CoreProxyNodeSummaryValue = new CoreProxyNodeSummaryValue();
    summary.name = nodes[index].name;
    summary.isGroup = nodes[index].isGroup;
    summary.selected = nodes[index].selected;
    summaries.push(summary);
  }
  return summaries;
}

function buildProxyGroupListQueryResult(
  groupNames: string[],
  generation: number,
  sessionId: string | null = null,
  profileId: string = 'one-click',
  revisionId: string = buildTimestamp(1),
  revisionHash: string = buildDigest('proxy-revision')
): ProxyGroupListQueryResult {
  const groups: CoreProxyGroupRefValue[] = [];
  for (let index = 0; index < groupNames.length; index += 1) {
    const group: CoreProxyGroupRefValue = new CoreProxyGroupRefValue();
    group.name = groupNames[index];
    groups.push(group);
  }
  return createProxyGroupListQuerySnapshot(
    createProxyRuntimeIdentity(profileId, revisionId, revisionHash, sessionId),
    generation,
    groups
  );
}

function buildProxyGroupSnapshotValue(
  groupName: string,
  generation: number,
  selectedName: string,
  nodes: ProxyNodeSelectionInput[],
  sessionId: string | null = null,
  profileId: string = 'one-click',
  revisionId: string = buildTimestamp(1),
  revisionHash: string = buildDigest('proxy-revision')
): ProxyGroupSnapshot {
  return createProxyGroupSnapshot(
    createProxyRuntimeIdentity(profileId, revisionId, revisionHash, sessionId),
    generation,
    {
      name: groupName,
      type: 'Selector',
      selectedName,
      nodes: buildCoreProxyNodeSummaries(nodes)
    }
  );
}

function buildProxyGroupQueryResult(
  groupName: string,
  generation: number,
  selectedName: string,
  nodes: ProxyNodeSelectionInput[],
  sessionId: string | null = null,
  profileId: string = 'one-click',
  revisionId: string = buildTimestamp(1),
  revisionHash: string = buildDigest('proxy-revision')
): ProxyGroupQueryResult {
  return createProxyGroupQuerySnapshot(
    buildProxyGroupSnapshotValue(groupName, generation, selectedName, nodes, sessionId, profileId, revisionId, revisionHash)
  );
}

function buildRawProxyGroupQueryResultWithSelectedName(
  groupName: string,
  generation: number,
  selectedName: string,
  nodes: ProxyNodeSelectionInput[],
  sessionId: string | null = null,
  profileId: string = 'one-click',
  revisionId: string = buildTimestamp(1),
  revisionHash: string = buildDigest('proxy-revision')
): ProxyGroupQueryResult {
  const result: RawProxyGroupQuerySnapshotResultValue = new RawProxyGroupQuerySnapshotResultValue();
  const snapshot: RawProxyGroupSnapshotValue = new RawProxyGroupSnapshotValue();
  const group: RawCoreProxyGroupSnapshotValue = new RawCoreProxyGroupSnapshotValue();
  snapshot.identity = createProxyRuntimeIdentity(profileId, revisionId, revisionHash, sessionId);
  snapshot.generation = generation;
  group.name = groupName;
  group.selectedName = selectedName;
  group.nodes = buildCoreProxyNodeSummaries(nodes);
  snapshot.group = group;
  result.snapshot = snapshot;
  return result;
}

function buildVpnSnapshot(
  state: 'STOPPED' | 'AWAITING_CONSENT' | 'STARTING' | 'RUNNING' | 'RECOVERING' | 'STOPPING' | 'ERROR',
  sessionId: string | null,
  profileId: string = 'one-click',
  versionId: string = buildTimestamp(1),
  lastFailure: VpnFailure | null = null
): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state,
    activeRequest: sessionId === null ? null : {
      profileId,
      versionId,
      sessionId
    },
    activeHandle: sessionId === null ? null : {
      sessionId,
      attached: state === 'RUNNING'
    },
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: state === 'RUNNING',
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure
  });
}

function assertOneClickFailure(
  result: SelectNodeAndEnsureVpnResult,
  stage: 'ADMISSION' | 'SELECTION' | 'VPN_START' | 'VPN_CONFIRMATION',
  code:
    | 'OPERATION_BUSY'
    | 'PROXY_SELECTION_STALE'
    | 'PROXY_SELECTION_FAILED'
    | 'PROXY_PERSISTENCE_FAILED'
    | 'VPN_PROFILE_UNAVAILABLE'
    | 'VPN_PERMISSION_DENIED'
    | 'VPN_START_FAILED'
    | 'VPN_STOPPED_BEFORE_RUNNING'
    | 'VPN_CONFIRMATION_TIMEOUT'
    | 'VPN_SESSION_CHANGED',
  resourceId:
    | 'proxies_one_click_busy'
    | 'proxies_error_selection_stale'
    | 'proxies_error_selection_failed'
    | 'proxies_error_persistence_failed'
    | 'error_vpn_profile_unavailable'
    | 'error_vpn_permission_denied'
    | 'error_vpn_start_failed'
    | 'proxies_one_click_confirmation_timeout'
    | 'proxies_error_session_changed',
  retryable: boolean,
  savedForNextStart: boolean
): void {
  expect(result.kind).assertEqual('FAILED');
  if (result.kind !== 'FAILED') {
    return;
  }
  expect(result.stage).assertEqual(stage);
  expect(result.code).assertEqual(code);
  expect(result.resourceId).assertEqual(resourceId);
  expect(result.retryable).assertEqual(retryable);
  expect(result.savedForNextStart).assertEqual(savedForNextStart);
}

function buildTimestamp(minute: number): string {
  const minuteText: string = `${minute}`.padStart(2, '0');
  return `2026-08-11T12:${minuteText}:00.000Z`;
}

function joinPieces(pieces: string[]): string {
  return pieces.join('');
}

function buildSensitiveDocumentsPath(fileName: string): string {
  return `${joinPieces(['/Us', 'ers'])}/susiwen8/Documents/${fileName}`;
}

function buildSecretTokenValue(): string {
  return joinPieces(['sec', 'ret-beta']);
}

function buildUsersPrefix(): string {
  return joinPieces(['/Us', 'ers']);
}

function buildDigest(seed: string): string {
  const hexAlphabet: string = '0123456789abcdef';
  let digest: string = '';
  let offset: number = seed.length % hexAlphabet.length;
  while (digest.length < 64) {
    digest += hexAlphabet[offset];
    offset = (offset + 3) % hexAlphabet.length;
  }
  return digest;
}

function buildRevision(id: string): ProfileRevision {
  return createProfileRevision(`profiles/${id}.yaml`, buildDigest(id), 64, buildTimestamp(1));
}

function buildStagedSource(id: string, validatedAtMinute: number = 58): StagedSource {
  return {
    stagingId: `staging-${id}`,
    validationPath: `/sandbox/staged/${id}.yaml`,
    sha256Digest: buildDigest(`staged-${id}`),
    byteLength: 96,
    validatedAt: buildTimestamp(validatedAtMinute)
  };
}

function buildProfileRecord(
  id: string,
  availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID',
  sourceKind: 'LOCAL_FILE' | 'REMOTE_URL',
  currentRevision: ProfileRevision | null,
  sourceSecretRef?: string,
  lastError: AppError | null = null,
  autoUpdateIntervalMs: number = 0
): Profile {
  return createProfile({
    id,
    name: `Profile ${id}`,
    sourceKind,
    sourceDisplay: sourceKind === 'REMOTE_URL' ? 'https://origin.example.com' : `${id}.yaml`,
    sourceSecretRef,
    currentRevision,
    failedCandidate: null,
    availability,
    lastError,
    createdAt: buildTimestamp(2),
    updatedAt: buildTimestamp(3),
    lastSuccessfulUpdateAt: currentRevision === null ? null : buildTimestamp(3),
    autoUpdateIntervalMs
  });
}

function buildRuntimeSnapshot(state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR'): RuntimeSnapshot {
  return {
    state,
    activeConfigPath: state === 'RUNNING' ? '/sandbox/profiles/active.yaml' : '',
    httpAddress: state === 'RUNNING' ? '127.0.0.1:8080' : '',
    socksAddress: state === 'RUNNING' ? '127.0.0.1:1080' : '',
    lastError: state === 'ERROR' ? 'backend failed' : '',
    mixedPort: state === 'RUNNING' ? 7890 : 0
  };
}

function cloneRuntimeSnapshot(snapshot: RuntimeSnapshot): RuntimeSnapshot {
  return {
    state: snapshot.state,
    activeConfigPath: snapshot.activeConfigPath,
    httpAddress: snapshot.httpAddress,
    socksAddress: snapshot.socksAddress,
    lastError: snapshot.lastError,
    mixedPort: snapshot.mixedPort
  };
}

function cloneProfile(profile: Profile): Profile {
  return createProfile({
    id: profile.id,
    name: profile.name,
    sourceKind: profile.sourceKind,
    sourceDisplay: profile.sourceDisplay,
    sourceSecretRef: profile.sourceSecretRef,
    currentRevision: profile.currentRevision,
    failedCandidate: profile.failedCandidate,
    availability: profile.availability,
    lastError: profile.lastError,
    createdAt: profile.createdAt,
    updatedAt: profile.updatedAt,
    lastSuccessfulUpdateAt: profile.lastSuccessfulUpdateAt,
    autoUpdateIntervalMs: profile.autoUpdateIntervalMs
  });
}

function cloneRefreshProfilesResult(result: RefreshProfilesResult): RefreshProfilesResult {
  return {
    items: result.items.map((item) => ({
      profileId: item.profileId,
      status: item.status
    })),
    deadlineReached: result.deadlineReached,
    cancelled: result.cancelled,
    remainingCount: result.remainingCount
  };
}

function createManagement(
  repository: FakeProfileRepository,
  contentStore: FakeProfileContentStore,
  secretStore: FakeSubscriptionSecretStore,
  coreService: FakeCoreService
): ManageProfileUseCases {
  const runtimeCoordinator = createRuntimeCoordinator(
    repository,
    contentStore,
    coreService,
    [buildTimestamp(4), buildTimestamp(5), buildTimestamp(6), buildTimestamp(7)]
  );
  return new ManageProfileUseCases(
    new ManageProfileUseCasesDependencyBag(
      repository,
      contentStore,
      secretStore,
      coreService,
      new FakeClock([buildTimestamp(8), buildTimestamp(9), buildTimestamp(10), buildTimestamp(11)]),
      runtimeCoordinator
    )
  );
}

function createRuntimeCoordinator(
  repository: FakeProfileRepository,
  contentStore: FakeProfileContentStore,
  coreService: FakeCoreService,
  timestamps: string[]
): LocalRuntimeCoordinator {
  return new LocalRuntimeCoordinator(
    new RuntimeCoordinatorDependencyBag(
      repository,
      contentStore,
      coreService,
      new FakeClock(timestamps)
    )
  );
}

function createCommitService(
  repository: FakeProfileRepository,
  contentStore: FakeProfileContentStore
): ProfileCommitService {
  return new ProfileCommitService({
    repository,
    contentStore,
    clock: new FakeClock([buildTimestamp(12), buildTimestamp(13), buildTimestamp(14)])
  });
}

function createApplication(
  repository: FakeProfileRepository,
  contentStore: FakeProfileContentStore,
  secretStore: FakeSubscriptionSecretStore,
  coreService: FakeCoreService,
  sourceGateway?: FakeSourceGateway,
  vpnController?: VpnControllerPort,
  idGenerator?: IdGenerator,
  proxyService?: ProxyApplicationPort,
  oneClickVpnConfirmation?: OneClickVpnConfirmationPort,
  batchUseCase?: FakeRefreshProfilesUseCase,
  schedulePort?: FakeProfileRefreshSchedulePort
): ProfileApplication {
  const runtimeCoordinator = createRuntimeCoordinator(
    repository,
    contentStore,
    coreService,
    [buildTimestamp(20), buildTimestamp(21), buildTimestamp(22)]
  );
  return createApplicationWithCoordinator(
    repository,
    contentStore,
    secretStore,
    coreService,
    runtimeCoordinator,
    sourceGateway,
    vpnController,
    idGenerator,
    proxyService,
    oneClickVpnConfirmation,
    new FakeProfileRefreshLeasePort(),
    batchUseCase,
    schedulePort
  );
}

function createApplicationWithCoordinator(
  repository: FakeProfileRepository,
  contentStore: FakeProfileContentStore,
  secretStore: FakeSubscriptionSecretStore,
  coreService: FakeCoreService,
  runtimeCoordinator: LocalRuntimeCoordinator,
  sourceGateway?: FakeSourceGateway,
  vpnController?: VpnControllerPort,
  idGenerator?: IdGenerator,
  proxyService?: ProxyApplicationPort,
  oneClickVpnConfirmation?: OneClickVpnConfirmationPort,
  leasePort: ProfileRefreshLeasePort = new FakeProfileRefreshLeasePort(),
  batchUseCase?: FakeRefreshProfilesUseCase,
  schedulePort?: FakeProfileRefreshSchedulePort
): ProfileApplication {
  const gateway: FakeSourceGateway = sourceGateway ?? new FakeSourceGateway();
  const queue = new SerialCommandQueue();
  const commitService = createCommitService(repository, contentStore);
  const importUseCase = new ImportProfileUseCase({
    repository,
    contentStore,
    sourceGateway: gateway,
    secretStore,
    coreService,
    clock: new FakeClock([buildTimestamp(15), buildTimestamp(16)]),
    idGenerator: new FakeIdGenerator(['new-profile']),
    queue,
    commitService
  });
  const refreshClock = new FakeClock([buildTimestamp(17), buildTimestamp(18), buildTimestamp(19)]);
  const refreshUseCase = new RefreshProfileUseCase({
    repository,
    contentStore,
    sourceGateway: gateway,
    secretStore,
    coreService,
    clock: refreshClock,
    queue,
    commitService,
    leasedRemoteRefresher: createLeasedRemoteProfileRefresher(
      leasePort,
      refreshClock,
      new FakeIdGenerator(['refresh-lease-owner'])
    )
  });
  const manageProfileUseCases = new ManageProfileUseCases(
    new ManageProfileUseCasesDependencyBag(
      repository,
      contentStore,
      secretStore,
      coreService,
      new FakeClock([buildTimestamp(23), buildTimestamp(24), buildTimestamp(25)]),
      runtimeCoordinator
    )
  );
  return new ProfileApplication(
    new ProfileApplicationDependencyBag(
      importUseCase,
      refreshUseCase,
      batchUseCase,
      schedulePort,
      manageProfileUseCases,
      runtimeCoordinator,
      commitService,
      repository,
      oneClickVpnConfirmation ?? new FakeOneClickVpnConfirmation(),
      proxyService ?? new FakeProxyApplication(),
      vpnController,
      idGenerator
    )
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

async function waitForCondition(predicate: () => boolean, maxTurns: number = 20): Promise<void> {
  for (let turn = 0; turn < maxTurns; turn += 1) {
    if (predicate()) {
      return;
    }
    await Promise.resolve();
  }
  throw new Error('Condition was not satisfied within bounded microtask turns.');
}

export default function profileManagementTestsuite() {
  describe('ProfileManagementTest', () => {
    it('enableValidProfileValidatesThenLoadsThenPersistsActiveId', 0, async () => {
      const revision = buildRevision('target');
      const previous = buildProfileRecord('previous', 'VALID', 'LOCAL_FILE', revision);
      const target = buildProfileRecord('target', 'VALID', 'LOCAL_FILE', revision);
      const repository = new FakeProfileRepository([previous, target], 'previous');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/target.yaml');
      const management = createManagement(repository, contentStore, new FakeSubscriptionSecretStore(), new FakeCoreService());

      const result = await management.enable('target');

      expect(result.kind).assertEqual('ENABLED');
      expect(repository.readActiveId()).assertEqual('target');
      expect(repository.log.join('>')).assertEqual('repository.getActiveId>repository.get:target>repository.setActiveId:target');
    });

    it('enableLoadFailureKeepsPreviousActiveId', 0, async () => {
      const revision = buildRevision('target');
      const previous = buildProfileRecord('previous', 'VALID', 'LOCAL_FILE', revision);
      const target = buildProfileRecord('target', 'VALID', 'LOCAL_FILE', revision);
      const repository = new FakeProfileRepository([previous, target], 'previous');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/target.yaml');
      const coreService = new FakeCoreService();
      coreService.loadError = new Error('load failed');
      const management = createManagement(repository, contentStore, new FakeSubscriptionSecretStore(), coreService);

      const result = await management.enable('target');

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('CORE_LOAD');
      expect(contentStore.log.join('>')).assertEqual(`content.resolveCorePath:${revision.relativePath}`);
      expect(coreService.validateCalls.join('>')).assertEqual('/sandbox/profiles/target.yaml');
      expect(coreService.loadCalls.join('>')).assertEqual('/sandbox/profiles/target.yaml');
      expect(repository.readActiveId()).assertEqual('previous');
      expect(repository.setActiveIdCalls.length).assertEqual(0);
    });

    it('enableSameActiveProfileIsIdempotentWithoutReload', 0, async () => {
      const revision = buildRevision('same');
      const profile = buildProfileRecord('same', 'VALID', 'LOCAL_FILE', revision);
      const repository = new FakeProfileRepository([profile], 'same');
      const contentStore = new FakeProfileContentStore();
      const coreService = new FakeCoreService();
      const management = createManagement(repository, contentStore, new FakeSubscriptionSecretStore(), coreService);

      const result = await management.enable('same');

      expect(result.kind).assertEqual('ENABLED');
      expect(coreService.validateCalls.length).assertEqual(0);
      expect(coreService.loadCalls.length).assertEqual(0);
    });

    it('enableRejectsInvalidProfile', 0, async () => {
      const revision = buildRevision('invalid');
      const invalidProfile = buildProfileRecord('invalid', 'VALID', 'LOCAL_FILE', revision);
      const repository = new FakeProfileRepository([invalidProfile]);
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/invalid.yaml');
      const coreService = new FakeCoreService();
      coreService.validateError = new Error('validation failed');
      const management = createManagement(repository, contentStore, new FakeSubscriptionSecretStore(), coreService);

      const result = await management.enable('invalid');

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('VALIDATION');
      expect(contentStore.log.join('>')).assertEqual(`content.resolveCorePath:${revision.relativePath}`);
      expect(coreService.validateCalls.join('>')).assertEqual('/sandbox/profiles/invalid.yaml');
      expect(coreService.loadCalls.length).assertEqual(0);
      expect(repository.setActiveIdCalls.length).assertEqual(0);
    });

    it('startingRuntimeRejectsEnableDeleteReplaceAndRefreshWhileCoreSnapshotStillStopped', 0, async () => {
      const revision = buildRevision('running');
      const profile = buildProfileRecord('running', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'running');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/running.yaml');
      const coreService = new FakeCoreService();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('STOPPED');
      coreService.startDeferred = new DeferredRuntimeSnapshot();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const runtimeCoordinator = createRuntimeCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(20), buildTimestamp(21), buildTimestamp(22), buildTimestamp(23), buildTimestamp(24)]
      );
      const management = new ManageProfileUseCases(
        new ManageProfileUseCasesDependencyBag(
          repository,
          contentStore,
          secretStore,
          coreService,
          new FakeClock([buildTimestamp(25), buildTimestamp(26), buildTimestamp(27), buildTimestamp(28)]),
          runtimeCoordinator
        )
      );
      const application = createApplicationWithCoordinator(
        repository,
        contentStore,
        secretStore,
        coreService,
        runtimeCoordinator
      );

      await application.initialize();
      const startPromise = runtimeCoordinator.start();
      await waitForCondition(() => coreService.startCalls.length === 1);
      const enableResult = await management.enable('running');
      const deleteResult = await management.delete('running');
      const replaceResult = await management.replaceSubscriptionUrl('running', 'https://next.example.com/subscription.yaml');
      const refreshResult = await application.refresh('running');
      coreService.startDeferred.resolve(buildRuntimeSnapshot('RUNNING'));
      await startPromise;

      expect(enableResult.kind).assertEqual('FAILED');
      expect(deleteResult.kind).assertEqual('FAILED');
      expect(replaceResult.kind).assertEqual('FAILED');
      expect(refreshResult.kind).assertEqual('FAILED');
      expect(repository.setActiveIdCalls.length).assertEqual(0);
      expect(repository.deletedIds.length).assertEqual(0);
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(contentStore.removedProfiles.length).assertEqual(0);
      expect(secretStore.encryptCalls.length).assertEqual(0);
      expect(secretStore.removeCalls.length).assertEqual(0);
      expect(coreService.validateCalls.length).assertEqual(1);
      expect(coreService.loadCalls.length).assertEqual(1);
      expect(coreService.startCalls.length).assertEqual(1);
    });

    it('enableLeaseRejectsConcurrentStartUntilMutationFinishes', 0, async () => {
      const revision = buildRevision('lease');
      const profile = buildProfileRecord('lease', 'VALID', 'LOCAL_FILE', revision);
      const repository = new FakeProfileRepository([profile], undefined);
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/lease.yaml');
      const coreService = new FakeCoreService();
      coreService.validateDeferred = new DeferredVoid();
      coreService.validateEntered = new DeferredVoid();
      const runtimeCoordinator = createRuntimeCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(29), buildTimestamp(30), buildTimestamp(31), buildTimestamp(32), buildTimestamp(33)]
      );
      const management = new ManageProfileUseCases(
        new ManageProfileUseCasesDependencyBag(
          repository,
          contentStore,
          new FakeSubscriptionSecretStore(),
          coreService,
          new FakeClock([buildTimestamp(34), buildTimestamp(35), buildTimestamp(36)]),
          runtimeCoordinator
        )
      );

      await runtimeCoordinator.initialize();
      const enablePromise = management.enable('lease');
      await coreService.validateEntered.promise;
      const startResult = await runtimeCoordinator.start();
      coreService.validateDeferred.resolve();
      const enableResult = await enablePromise;

      expect(startResult.kind).assertEqual('FAILED');
      expect(coreService.startCalls.length).assertEqual(0);
      expect(enableResult.kind).assertEqual('ENABLED');
    });

    it('errorPolicyAllowsEnableOnlyForRecoverableErrorAndBlocksOtherMutations', 0, async () => {
      const revision = buildRevision('error');
      const profile = buildProfileRecord('error', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'error');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/error.yaml');
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const coreService = new FakeCoreService();
      const runtimeCoordinator = createRuntimeCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(37), buildTimestamp(38), buildTimestamp(39), buildTimestamp(40)]
      );
      const management = new ManageProfileUseCases(
        new ManageProfileUseCasesDependencyBag(
          repository,
          contentStore,
          secretStore,
          coreService,
          new FakeClock([buildTimestamp(41), buildTimestamp(42), buildTimestamp(43), buildTimestamp(44)]),
          runtimeCoordinator
        )
      );
      const application = createApplicationWithCoordinator(
        repository,
        contentStore,
        secretStore,
        coreService,
        runtimeCoordinator
      );

      await runtimeCoordinator.initialize();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('ERROR');
      coreService.emitRuntime('ERROR', 'recoverable');
      const enableResult = await management.enable('error');
      const deleteResult = await management.delete('error');
      const replaceResult = await management.replaceSubscriptionUrl('error', 'https://next.example.com/subscription.yaml');
      const refreshResult = await application.refresh('error');

      expect(enableResult.kind).assertEqual('ENABLED');
      expect(deleteResult.kind).assertEqual('FAILED');
      expect(replaceResult.kind).assertEqual('FAILED');
      expect(refreshResult.kind).assertEqual('FAILED');
    });

    it('inFlightErrorDoesNotPermitEnableWhileStartPromiseOwnsAdmission', 0, async () => {
      const revision = buildRevision('blocked');
      const profile = buildProfileRecord('blocked', 'VALID', 'LOCAL_FILE', revision);
      const repository = new FakeProfileRepository([profile], 'blocked');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/blocked.yaml');
      const coreService = new FakeCoreService();
      coreService.startDeferred = new DeferredRuntimeSnapshot();
      const runtimeCoordinator = createRuntimeCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(45), buildTimestamp(46), buildTimestamp(47), buildTimestamp(48), buildTimestamp(49)]
      );
      const management = new ManageProfileUseCases(
        new ManageProfileUseCasesDependencyBag(
          repository,
          contentStore,
          new FakeSubscriptionSecretStore(),
          coreService,
          new FakeClock([buildTimestamp(50), buildTimestamp(51), buildTimestamp(52)]),
          runtimeCoordinator
        )
      );

      await runtimeCoordinator.initialize();
      const startPromise = runtimeCoordinator.start();
      coreService.emitRuntime('ERROR', 'transitional');
      const enableResult = await management.enable('blocked');
      coreService.startDeferred.resolve(buildRuntimeSnapshot('ERROR'));
      await startPromise;

      expect(enableResult.kind).assertEqual('FAILED');
    });

    it('deleteUsesRepositoryTransactionBeforeCleanupAndSkipsCleanupOnRepositoryFailure', 0, async () => {
      const revision = buildRevision('remote');
      const profile = buildProfileRecord('remote', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'remote');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      const management = createManagement(repository, contentStore, secretStore, new FakeCoreService());

      const deleted = await management.delete('remote');

      expect(deleted.kind).assertEqual('DELETED');
      expect(contentStore.log.join('>')).assertEqual('content.removeProfile:remote');
      expect(secretStore.removeCalls.join('>')).assertEqual('secret-old');

      const failingRepository = new FakeProfileRepository([profile], 'remote');
      failingRepository.deleteError = new Error('repo delete failed');
      const failingContentStore = new FakeProfileContentStore();
      const failingSecretStore = new FakeSubscriptionSecretStore();
      const failed = await createManagement(
        failingRepository,
        failingContentStore,
        failingSecretStore,
        new FakeCoreService()
      ).delete('remote');

      expect(failed.kind).assertEqual('FAILED');
      expect(failingContentStore.log.length).assertEqual(0);
      expect(failingSecretStore.removeCalls.length).assertEqual(0);
    });

    it('replaceEncryptsThenSavesThenRemovesOldSecretAndCompensatesNewSecretOnSaveFailure', 0, async () => {
      const revision = buildRevision('remote');
      const profile = buildProfileRecord('remote', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'remote');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const management = createManagement(repository, contentStore, secretStore, new FakeCoreService());

      const replaced = await management.replaceSubscriptionUrl('remote', 'https://next.example.com/subscription.yaml');

      expect(replaced.kind).assertEqual('REPLACED');
      expect(secretStore.encryptCalls.join('>')).assertEqual('https://next.example.com/subscription.yaml');
      expect(secretStore.removeCalls.join('>')).assertEqual('secret-old');

      const failingRepository = new FakeProfileRepository([profile], 'remote');
      failingRepository.saveError = new Error('save failed');
      const failingSecretStore = new FakeSubscriptionSecretStore();
      failingSecretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const failed = await createManagement(
        failingRepository,
        new FakeProfileContentStore(),
        failingSecretStore,
        new FakeCoreService()
      ).replaceSubscriptionUrl('remote', 'https://broken.example.com/subscription.yaml');

      expect(failed.kind).assertEqual('FAILED');
      expect(failingSecretStore.removeCalls.join('>')).assertEqual('secret-1');
    });

    it('updateMetadataRenamesWithoutSecretMutationAndMarksSourceUnchanged', 0, async () => {
      const revision = buildRevision('remote-update-name');
      const profile = buildProfileRecord('remote-update-name', 'VALID', 'REMOTE_URL', revision, 'secret-old', null, 300000);
      const repository = new FakeProfileRepository([profile], 'remote-update-name');
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml?token=secret');

      const updated = await createManagement(
        repository,
        new FakeProfileContentStore(),
        secretStore,
        new FakeCoreService()
      ).updateMetadata('remote-update-name', '  Renamed remote profile  ');

      expect(updated.kind).assertEqual('UPDATED');
      if (updated.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(updated.profile.name).assertEqual('Renamed remote profile');
      expect(updated.profile.sourceDisplay).assertEqual('https://origin.example.com');
      expect(updated.profile.autoUpdateIntervalMs).assertEqual(300000);
      expect(updated.sourceChanged).assertFalse();
      expect(secretStore.encryptCalls.length).assertEqual(0);
      expect(secretStore.removeCalls.length).assertEqual(0);
      expect(repository.readProfile('remote-update-name')?.sourceSecretRef).assertEqual('secret-old');
      expect(repository.readProfile('remote-update-name')?.autoUpdateIntervalMs).assertEqual(300000);
    });

    it('updateMetadataEncryptsNewRemoteUrlAndCompensatesValidationOrLocalFailures', 0, async () => {
      const revision = buildRevision('remote-update-url');
      const profile = buildProfileRecord('remote-update-url', 'VALID', 'REMOTE_URL', revision, 'secret-old', null, 600000);
      const repository = new FakeProfileRepository([profile], 'remote-update-url');
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');

      const updated = await createManagement(
        repository,
        new FakeProfileContentStore(),
        secretStore,
        new FakeCoreService()
      ).updateMetadata('remote-update-url', '  Renamed remote profile  ', ' https://next.example.com/subscription.yaml?token=next ');

      expect(updated.kind).assertEqual('UPDATED');
      if (updated.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(updated.profile.name).assertEqual('Renamed remote profile');
      expect(updated.profile.sourceDisplay).assertEqual('https://next.example.com');
      expect(updated.profile.autoUpdateIntervalMs).assertEqual(600000);
      expect(updated.sourceChanged).assertTrue();
      expect(secretStore.encryptCalls.join('>')).assertEqual('https://next.example.com/subscription.yaml?token=next');
      expect(secretStore.removeCalls.join('>')).assertEqual('secret-old');

      const invalidSecretStore = new FakeSubscriptionSecretStore();
      invalidSecretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const invalid = await createManagement(
        new FakeProfileRepository([profile], 'remote-update-url'),
        new FakeProfileContentStore(),
        invalidSecretStore,
        new FakeCoreService()
      ).updateMetadata('remote-update-url', 'Renamed remote profile', 'not-a-url');

      expect(invalid.kind).assertEqual('FAILED');
      expect(invalidSecretStore.removeCalls.join('>')).assertEqual('secret-1');

      const localRevision = buildRevision('local-update-url');
      const localProfile = buildProfileRecord('local-update-url', 'VALID', 'LOCAL_FILE', localRevision);
      const localSecretStore = new FakeSubscriptionSecretStore();
      const local = await createManagement(
        new FakeProfileRepository([localProfile], 'local-update-url'),
        new FakeProfileContentStore(),
        localSecretStore,
        new FakeCoreService()
      ).updateMetadata('local-update-url', 'Local name', 'https://next.example.com/subscription.yaml');

      expect(local.kind).assertEqual('FAILED');
      expect(localSecretStore.encryptCalls.length).assertEqual(0);
      expect(localSecretStore.removeCalls.length).assertEqual(0);
    });

    it('replaceRejectsLocalProfilesAndEncryptFailuresAsTypedFailures', 0, async () => {
      const revision = buildRevision('local');
      const localProfile = buildProfileRecord('local', 'VALID', 'LOCAL_FILE', revision);
      const localRepository = new FakeProfileRepository([localProfile], 'local');
      const localSecretStore = new FakeSubscriptionSecretStore();
      const localResult = await createManagement(
        localRepository,
        new FakeProfileContentStore(),
        localSecretStore,
        new FakeCoreService()
      ).replaceSubscriptionUrl('local', 'https://next.example.com/subscription.yaml');

      expect(localResult.kind).assertEqual('FAILED');
      expect(localSecretStore.encryptCalls.length).assertEqual(0);

      const remoteProfile = buildProfileRecord('remote-encrypt', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const encryptRepository = new FakeProfileRepository([remoteProfile], 'remote-encrypt');
      const encryptSecretStore = new FakeSubscriptionSecretStore();
      encryptSecretStore.encryptError = new Error('encrypt failed');
      const encryptResult = await createManagement(
        encryptRepository,
        new FakeProfileContentStore(),
        encryptSecretStore,
        new FakeCoreService()
      ).replaceSubscriptionUrl('remote-encrypt', 'https://next.example.com/subscription.yaml');

      expect(encryptResult.kind).assertEqual('FAILED');
    });

    it('replaceInvalidUrlAndCleanupFailuresStayTypedAndBestEffort', 0, async () => {
      const revision = buildRevision('remote-invalid');
      const profile = buildProfileRecord('remote-invalid', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'remote-invalid');
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const invalidResult = await createManagement(
        repository,
        new FakeProfileContentStore(),
        secretStore,
        new FakeCoreService()
      ).replaceSubscriptionUrl('remote-invalid', 'not-a-url');

      expect(invalidResult.kind).assertEqual('FAILED');
      expect(secretStore.removeCalls.join('>')).assertEqual('secret-1');

      const failingRepository = new FakeProfileRepository([profile], 'remote-invalid');
      failingRepository.saveError = new Error('save failed');
      const removeFailSecretStore = new FakeSubscriptionSecretStore();
      removeFailSecretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      removeFailSecretStore.removeError = new Error('cleanup failed');
      removeFailSecretStore.removeErrorSecretRef = 'secret-1';
      const failed = await createManagement(
        failingRepository,
        new FakeProfileContentStore(),
        removeFailSecretStore,
        new FakeCoreService()
      ).replaceSubscriptionUrl('remote-invalid', 'https://next.example.com/subscription.yaml');

      expect(failed.kind).assertEqual('FAILED');
      if (failed.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(failed.error.stage).assertEqual('PERSISTENCE');

      const successRepository = new FakeProfileRepository([profile], 'remote-invalid');
      const oldCleanupFailSecretStore = new FakeSubscriptionSecretStore();
      oldCleanupFailSecretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      oldCleanupFailSecretStore.removeError = new Error('old cleanup failed');
      oldCleanupFailSecretStore.removeErrorSecretRef = 'secret-old';
      const replaced = await createManagement(
        successRepository,
        new FakeProfileContentStore(),
        oldCleanupFailSecretStore,
        new FakeCoreService()
      ).replaceSubscriptionUrl('remote-invalid', 'https://next.example.com/subscription.yaml');

      expect(replaced.kind).assertEqual('REPLACED');
    });

    it('replaceRejectsBlankUrlAndKeepsTypedSecretFlow', 0, async () => {
      const revision = buildRevision('replace-once');
      const profile = buildProfileRecord('replace-once', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'replace-once');
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const management = createManagement(repository, new FakeProfileContentStore(), secretStore, new FakeCoreService());

      const blankResult = await management.replaceSubscriptionUrl('replace-once', '   ');
      const replaced = await management.replaceSubscriptionUrl('replace-once', 'https://next.example.com/subscription.yaml');

      expect(blankResult.kind).assertEqual('FAILED');
      expect(replaced.kind).assertEqual('REPLACED');
      expect(repository.savedProfiles.length).assertEqual(1);
      expect(secretStore.encryptCalls.join('>')).assertEqual('https://next.example.com/subscription.yaml');
    });

    it('deleteCleanupFailuresAndRepositoryThrowsRemainTypedResults', 0, async () => {
      const revision = buildRevision('delete');
      const profile = buildProfileRecord('delete', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const cleanupContentStore = new FakeProfileContentStore();
      cleanupContentStore.removeProfileError = new Error('remove profile failed');
      const cleanupSecretStore = new FakeSubscriptionSecretStore();
      cleanupSecretStore.removeError = new Error('remove secret failed');
      cleanupSecretStore.removeErrorSecretRef = 'secret-old';
      const deleted = await createManagement(
        new FakeProfileRepository([profile], 'delete'),
        cleanupContentStore,
        cleanupSecretStore,
        new FakeCoreService()
      ).delete('delete');

      expect(deleted.kind).assertEqual('DELETED');

      const throwingRepository = new FakeProfileRepository([profile], 'delete');
      throwingRepository.getError = new Error('get failed');
      const failed = await createManagement(
        throwingRepository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService()
      ).delete('delete');

      expect(failed.kind).assertEqual('FAILED');
    });

    it('enableAndReplaceUnexpectedThrowsResolveTypedFailuresWithoutRejecting', 0, async () => {
      const revision = buildRevision('typed');
      const profile = buildProfileRecord('typed', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const getThrowRepository = new FakeProfileRepository([profile], 'typed');
      getThrowRepository.getError = new Error('get failed');
      const getFailed = await createManagement(
        getThrowRepository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService()
      ).enable('typed');
      expect(getFailed.kind).assertEqual('FAILED');

      const resolveThrowStore = new FakeProfileContentStore();
      resolveThrowStore.resolveError = new Error('resolve failed');
      const resolveFailed = await createManagement(
        new FakeProfileRepository([profile], undefined),
        resolveThrowStore,
        new FakeSubscriptionSecretStore(),
        new FakeCoreService()
      ).enable('typed');
      expect(resolveFailed.kind).assertEqual('FAILED');

      const setActiveRepository = new FakeProfileRepository([profile], undefined);
      setActiveRepository.setActiveIdError = new Error('persist failed');
      const setActiveFailed = await createManagement(
        setActiveRepository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService()
      ).enable('typed');
      expect(setActiveFailed.kind).assertEqual('FAILED');

      const replaceGetThrowRepository = new FakeProfileRepository([profile], 'typed');
      replaceGetThrowRepository.getError = new Error('get failed');
      const replaceFailed = await createManagement(
        replaceGetThrowRepository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService()
      ).replaceSubscriptionUrl('typed', 'https://next.example.com/subscription.yaml');
      expect(replaceFailed.kind).assertEqual('FAILED');
    });

    it('applicationCurrentPublishesSafeProfilesAndActiveSelectionAfterInitialize', 0, async () => {
      const alphaRevision = buildRevision('alpha');
      const betaRevision = buildRevision('beta');
      const alpha = buildProfileRecord('alpha', 'VALID', 'LOCAL_FILE', alphaRevision);
      const beta = buildProfileRecord('beta', 'UPDATE_FAILED_USING_VALID', 'REMOTE_URL', betaRevision, 'secret-beta', null, 300000);
      const repository = new FakeProfileRepository([alpha, beta], 'beta');
      const contentStore = new FakeProfileContentStore();
      const coreService = new FakeCoreService();
      const application = createApplication(
        repository,
        contentStore,
        new FakeSubscriptionSecretStore(),
        coreService
      );

      await application.initialize();
      const snapshot: ProfileApplicationSnapshot = application.current();
      const serialized = JSON.stringify(snapshot);

      expect(snapshot.status).assertEqual('READY');
      expect(snapshot.activeProfileId).assertEqual('beta');
      expect(snapshot.profiles.length).assertEqual(2);
      expect(snapshot.profiles[0].id).assertEqual('alpha');
      expect(snapshot.profiles[1].id).assertEqual('beta');
      expect(snapshot.profiles[1].availability).assertEqual('UPDATE_FAILED_USING_VALID');
      expect(snapshot.profiles[0].autoUpdateIntervalMs).assertEqual(0);
      expect(snapshot.profiles[0].lastSuccessfulUpdateAt).assertEqual(buildTimestamp(3));
      expect(snapshot.profiles[1].autoUpdateIntervalMs).assertEqual(300000);
      expect(snapshot.profiles[1].lastSuccessfulUpdateAt).assertEqual(buildTimestamp(3));
      snapshot.profiles[1].autoUpdateIntervalMs = 1;
      snapshot.profiles[1].lastSuccessfulUpdateAt = 'mutated';
      const clonedSnapshot: ProfileApplicationSnapshot = application.current();
      expect(clonedSnapshot.profiles[1].autoUpdateIntervalMs).assertEqual(300000);
      expect(clonedSnapshot.profiles[1].lastSuccessfulUpdateAt).assertEqual(buildTimestamp(3));
      expect(serialized.includes('sourceSecretRef')).assertFalse();
      expect(serialized.includes('/sandbox/profiles')).assertFalse();
      expect(serialized.includes('https://origin.example.com/subscription.yaml')).assertFalse();
      expect(serialized.includes('profiles/alpha.yaml')).assertFalse();
      expect(serialized.includes('technicalDetail')).assertFalse();
    });

    it('applicationCurrentPublishesSafeSourceKindRepairFlagAndRedactedProfileError', 0, async () => {
      const revision = buildRevision('repair');
      const repairError = createAppError('PERSISTENCE', 'decrypt https://repair.example.com/path?token=secret failed near /private/cache', {
        code: 'SOURCE_SECRET_VERSION_UNSUPPORTED',
        retryable: false,
        timestamp: buildTimestamp(4)
      });
      const repair = buildProfileRecord('repair', 'INVALID', 'REMOTE_URL', null, 'secret-repair', repairError);
      const localRepair = buildProfileRecord('local', 'INVALID', 'LOCAL_FILE', null, undefined, repairError);
      const repository = new FakeProfileRepository([localRepair, repair], 'local');
      const contentStore = new FakeProfileContentStore();
      const application = createApplication(
        repository,
        contentStore,
        new FakeSubscriptionSecretStore(),
        new FakeCoreService()
      );

      await application.initialize();
      const snapshot: ProfileApplicationSnapshot = application.current();
      const repairSnapshot: ProfileApplicationProfileSnapshot = snapshot.profiles[0].id === 'repair'
        ? snapshot.profiles[0]
        : snapshot.profiles[1];
      const localSnapshot: ProfileApplicationProfileSnapshot = snapshot.profiles[0].id === 'local'
        ? snapshot.profiles[0]
        : snapshot.profiles[1];
      const serialized = JSON.stringify(repairSnapshot);

      expect(repairSnapshot.sourceKind).assertEqual('REMOTE_URL');
      expect(repairSnapshot.sourceRepairRequired).assertTrue();
      expect(repairSnapshot.lastError?.code).assertEqual('SOURCE_SECRET_VERSION_UNSUPPORTED');
      expect(repairSnapshot.autoUpdateIntervalMs).assertEqual(0);
      expect(repairSnapshot.lastSuccessfulUpdateAt).assertEqual(undefined);
      expect(localSnapshot.sourceKind).assertEqual('LOCAL_FILE');
      expect(localSnapshot.sourceRepairRequired).assertFalse();
      expect(localSnapshot.autoUpdateIntervalMs).assertEqual(0);
      expect(localSnapshot.lastSuccessfulUpdateAt).assertEqual(undefined);
      expect(repairSnapshot.lastError?.technicalDetail.includes('https://repair.example.com')).assertTrue();
      expect(serialized.includes('token=secret')).assertFalse();
      expect(serialized.includes('/path')).assertFalse();
      expect(serialized.includes('/private/cache')).assertFalse();
    });

    it('refreshRequiresPerCallPlainHttpConsentWithoutPersistingApproval', 0, async () => {
      const revision = buildRevision('plain-http');
      const profile = buildProfileRecord('plain-http', 'VALID', 'REMOTE_URL', revision, 'secret-plain');
      const repository = new FakeProfileRepository([profile], 'plain-http');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-plain', 'http://legacy.example.com/subscription.yaml?token=secret');
      const gateway = new FakeSourceGateway();
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        gateway
      );

      await application.initialize();
      const first = await application.refresh('plain-http');
      const second = await application.refresh('plain-http', true);
      const third = await application.refresh('plain-http');

      expect(first.kind).assertEqual('CANCELLED');
      expect(second.kind).assertEqual('UPDATED');
      expect(third.kind).assertEqual('CANCELLED');
      expect(gateway.remoteCommands.length).assertEqual(1);
      expect(gateway.remoteCommands[0].allowPlainHttp).assertTrue();
      expect(gateway.remoteCommands[0].sourceDisplay).assertEqual('http://legacy.example.com');
    });

    it('applicationInitializeReconcilesSubscriptionScheduleFromRepositorySnapshot', 0, async () => {
      const scheduledProfile = buildProfileRecord('scheduled', 'VALID', 'REMOTE_URL', buildRevision('scheduled'), 'secret-scheduled', null, 2 * 60 * 60 * 1000);
      const idleProfile = buildProfileRecord('idle', 'VALID', 'REMOTE_URL', buildRevision('idle'), 'secret-idle', null, 0);
      const scheduledSchedule = new FakeProfileRefreshSchedulePort();
      const idleSchedule = new FakeProfileRefreshSchedulePort();

      const scheduledApplication = createApplication(
        new FakeProfileRepository([scheduledProfile], 'scheduled'),
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        scheduledSchedule
      ) as ProfileApplicationSubscriptionTask5AContract;
      const idleApplication = createApplication(
        new FakeProfileRepository([idleProfile], 'idle'),
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        idleSchedule
      ) as ProfileApplicationSubscriptionTask5AContract;

      await scheduledApplication.reloadFromRepository();
      await idleApplication.reloadFromRepository();

      expect(scheduledSchedule.reconcileCalls.join(',')).assertEqual('true');
      expect(idleSchedule.reconcileCalls.join(',')).assertEqual('false');
    });

    it('applicationInitializePublishesReadySnapshotErrorWhenScheduleReconcileFails', 0, async () => {
      const profile = buildProfileRecord('scheduled-init-error', 'VALID', 'REMOTE_URL', buildRevision('scheduled-init-error'), 'secret-init', null, 2 * 60 * 60 * 1000);
      const schedulePort = new FakeProfileRefreshSchedulePort();
      schedulePort.error = new Error('schedule init boom');
      const application = createApplication(
        new FakeProfileRepository([profile], 'scheduled-init-error'),
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        schedulePort
      ) as ProfileApplication;

      await application.initialize();
      const snapshot = application.current();

      expect(snapshot.status).assertEqual('READY');
      expect(snapshot.error?.code ?? '').assertEqual('SUBSCRIPTION_SCHEDULE_FAILED');
      expect(snapshot.profiles.length).assertEqual(1);
      expect(snapshot.runtime.state).assertEqual('STOPPED');
    });

    it('applicationUpdateAutoUpdateIntervalSavesRemoteMetadataAndReconcilesSchedule', 0, async () => {
      const revision = buildRevision('remote-interval');
      const original = buildProfileRecord('remote-interval', 'VALID', 'REMOTE_URL', revision, 'secret-remote');
      const repository = new FakeProfileRepository([original], 'remote-interval');
      const schedulePort = new FakeProfileRefreshSchedulePort();
      const application = createApplication(
        repository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        schedulePort
      ) as ProfileApplicationSubscriptionTask5AContract;

      await application.reloadFromRepository();
      const result = await application.updateAutoUpdateInterval('remote-interval', 2 * 60 * 60 * 1000);

      expect(result.kind).assertEqual('UPDATED');
      if (result.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.id).assertEqual(original.id);
      expect(result.profile.name).assertEqual(original.name);
      expect(result.profile.sourceDisplay).assertEqual(original.sourceDisplay);
      expect(result.profile.sourceSecretRef).assertEqual(original.sourceSecretRef);
      expect(result.profile.currentRevision?.relativePath ?? '').assertEqual(original.currentRevision?.relativePath ?? '');
      expect(result.profile.createdAt).assertEqual(original.createdAt);
      expect(result.profile.updatedAt).assertEqual(buildTimestamp(12));
      expect(result.profile.autoUpdateIntervalMs).assertEqual(2 * 60 * 60 * 1000);
      expect(repository.readProfile('remote-interval')?.autoUpdateIntervalMs).assertEqual(2 * 60 * 60 * 1000);
      expect(schedulePort.reconcileCalls.join(',')).assertEqual('false,true');
    });

    it('applicationUpdateAutoUpdateIntervalDisablesScheduleWhenLastRemoteIntervalBecomesZero', 0, async () => {
      const revision = buildRevision('remote-last-zero');
      const profile = buildProfileRecord('remote-last-zero', 'VALID', 'REMOTE_URL', revision, 'secret-remote', null, 2 * 60 * 60 * 1000);
      const repository = new FakeProfileRepository([profile], 'remote-last-zero');
      const schedulePort = new FakeProfileRefreshSchedulePort();
      const application = createApplication(
        repository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        schedulePort
      ) as ProfileApplicationSubscriptionTask5AContract;

      await application.reloadFromRepository();
      const result = await application.updateAutoUpdateInterval('remote-last-zero', 0);

      expect(result.kind).assertEqual('UPDATED');
      expect(repository.readProfile('remote-last-zero')?.autoUpdateIntervalMs).assertEqual(0);
      expect(schedulePort.reconcileCalls.join(',')).assertEqual('true,false');
    });

    it('applicationUpdateAutoUpdateIntervalRejectsInvalidIntervalsAndLocalProfilesBeforeSaving', 0, async () => {
      const remoteRevision = buildRevision('remote-invalid-interval');
      const localRevision = buildRevision('local-interval');
      const remoteRepository = new FakeProfileRepository([
        buildProfileRecord('remote-invalid-interval', 'VALID', 'REMOTE_URL', remoteRevision, 'secret-remote')
      ], 'remote-invalid-interval');
      const localRepository = new FakeProfileRepository([
        buildProfileRecord('local-interval', 'VALID', 'LOCAL_FILE', localRevision)
      ], 'local-interval');
      const invalidSchedule = new FakeProfileRefreshSchedulePort();
      const localSchedule = new FakeProfileRefreshSchedulePort();
      const invalidApplication = createApplication(
        remoteRepository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        invalidSchedule
      ) as ProfileApplicationSubscriptionTask5AContract;
      const localApplication = createApplication(
        localRepository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        localSchedule
      ) as ProfileApplicationSubscriptionTask5AContract;

      await invalidApplication.reloadFromRepository();
      await localApplication.reloadFromRepository();
      const invalidResult = await invalidApplication.updateAutoUpdateInterval('remote-invalid-interval', 123);
      const localResult = await localApplication.updateAutoUpdateInterval('local-interval', 2 * 60 * 60 * 1000);

      expect(invalidResult.kind).assertEqual('FAILED');
      expect(localResult.kind).assertEqual('FAILED');
      expect(remoteRepository.savedProfiles.length).assertEqual(0);
      expect(localRepository.savedProfiles.length).assertEqual(0);
      expect(invalidSchedule.reconcileCalls.join(',')).assertEqual('false');
      expect(localSchedule.reconcileCalls.join(',')).assertEqual('false');
    });

    it('applicationUpdateAutoUpdateIntervalReturnsPartialFailureWhenScheduleReconcileFailsAfterSave', 0, async () => {
      const revision = buildRevision('schedule-failure');
      const repository = new FakeProfileRepository([
        buildProfileRecord('schedule-failure', 'VALID', 'REMOTE_URL', revision, 'secret-schedule')
      ], 'schedule-failure');
      const schedulePort = new FakeProfileRefreshSchedulePort();
      schedulePort.error = new Error('schedule boom');
      const application = createApplication(
        repository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        schedulePort
      ) as ProfileApplicationSubscriptionTask5AContract;

      await application.reloadFromRepository();
      const result = await application.updateAutoUpdateInterval('schedule-failure', 2 * 60 * 60 * 1000);

      expect(result.kind).assertEqual('UPDATED_REFRESH_FAILED');
      if (result.kind !== 'UPDATED_REFRESH_FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.code).assertEqual('SUBSCRIPTION_SCHEDULE_FAILED');
      expect(repository.readProfile('schedule-failure')?.autoUpdateIntervalMs).assertEqual(2 * 60 * 60 * 1000);
      expect(schedulePort.reconcileCalls.join(',')).assertEqual('false,true');
      expect((application as ProfileApplication).current().status).assertEqual('READY');
      expect((application as ProfileApplication).current().error?.code ?? '').assertEqual('SUBSCRIPTION_SCHEDULE_FAILED');
    });

    it('applicationRefreshAllSubscriptionsRunsBatchWithoutRuntimeOrVpnMutation', 0, async () => {
      const revision = buildRevision('batch-refresh');
      const repository = new FakeProfileRepository([
        buildProfileRecord('batch-refresh', 'VALID', 'REMOTE_URL', revision, 'secret-batch')
      ], 'batch-refresh');
      const coreService = new FakeCoreService();
      const vpnController = new FakeVpnController();
      const proxyService = new FakeProxyApplication();
      const batchUseCase = new FakeRefreshProfilesUseCase();
      batchUseCase.result = {
        items: [{ profileId: 'batch-refresh', status: 'SUCCESS' }],
        deadlineReached: false,
        cancelled: false,
        remainingCount: 0
      };
      const application = createApplication(
        repository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        coreService,
        undefined,
        vpnController,
        undefined,
        proxyService,
        undefined,
        batchUseCase
      ) as ProfileApplicationSubscriptionTask5AContract;

      await application.reloadFromRepository();
      const result = await application.refreshAllSubscriptions();

      expect(result.kind).assertEqual('COMPLETED');
      if (result.kind !== 'COMPLETED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.result.items.length).assertEqual(1);
      expect(batchUseCase.commands.length).assertEqual(1);
      expect(batchUseCase.commands[0].mode).assertEqual('ALL');
      expect(coreService.loadCalls.length).assertEqual(0);
      expect(coreService.startCalls.length).assertEqual(0);
      expect(coreService.stopCalls.length).assertEqual(0);
      expect(vpnController.startCalls.length).assertEqual(0);
      expect(vpnController.stopCalls.length).assertEqual(0);
      expect(proxyService.reconcileCalls).assertEqual(0);
    });

    it('applicationRefreshAllSubscriptionsFailsClosedWhenRuntimeIsBusy', 0, async () => {
      const revision = buildRevision('busy-batch');
      const profile = buildProfileRecord('busy-batch', 'VALID', 'REMOTE_URL', revision, 'secret-busy');
      const repository = new FakeProfileRepository([profile], 'busy-batch');
      const contentStore = new FakeProfileContentStore();
      const coreService = new FakeCoreService();
      coreService.startDeferred = new DeferredRuntimeSnapshot();
      const runtimeCoordinator = createRuntimeCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(20), buildTimestamp(21), buildTimestamp(22), buildTimestamp(23), buildTimestamp(24)]
      );
      const batchUseCase = new FakeRefreshProfilesUseCase();
      const application = createApplicationWithCoordinator(
        repository,
        contentStore,
        new FakeSubscriptionSecretStore(),
        coreService,
        runtimeCoordinator,
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        new FakeProfileRefreshLeasePort(),
        batchUseCase
      ) as ProfileApplicationSubscriptionTask5AContract;

      await application.reloadFromRepository();
      const startPromise = runtimeCoordinator.start();
      await waitForCondition(() => coreService.startCalls.length === 1);
      const result = await application.refreshAllSubscriptions();
      coreService.startDeferred.resolve(buildRuntimeSnapshot('RUNNING'));
      await startPromise;

      expect(result.kind).assertEqual('FAILED');
      if (result.kind === 'FAILED') {
        expect(result.error.code).assertEqual('SUBSCRIPTION_REFRESH_ALL_BUSY');
        expect(result.error.retryable).assertTrue();
      }
      expect(batchUseCase.commands.length).assertEqual(0);
    });

    it('applicationRefreshAllSubscriptionsAndUpdateIntervalShareTheSameMutationOwner', 0, async () => {
      const revision = buildRevision('batch-lock');
      const repository = new FakeProfileRepository([
        buildProfileRecord('batch-lock', 'VALID', 'REMOTE_URL', revision, 'secret-batch-lock')
      ], 'batch-lock');
      const batchUseCase = new FakeRefreshProfilesUseCase();
      batchUseCase.executeEntered = new DeferredVoid();
      batchUseCase.executeDeferred = new DeferredVoid();
      const schedulePort = new FakeProfileRefreshSchedulePort();
      const application = createApplication(
        repository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        batchUseCase,
        schedulePort
      ) as ProfileApplication & ProfileApplicationSubscriptionTask5AContract;

      await application.reloadFromRepository();
      const batchPromise = application.refreshAllSubscriptions();
      await batchUseCase.executeEntered.promise;
      const intervalResult = await application.updateAutoUpdateInterval('batch-lock', 2 * 60 * 60 * 1000);
      batchUseCase.executeDeferred.resolve();
      const batchResult = await batchPromise;

      expect(intervalResult.kind).assertEqual('FAILED');
      if (intervalResult.kind === 'FAILED') {
        expect(intervalResult.error.stage).assertEqual('RUNTIME_STOP');
      }
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(schedulePort.reconcileCalls.join(',')).assertEqual('false');
      expect(batchResult.kind).assertEqual('COMPLETED');
      expect(batchUseCase.commands.length).assertEqual(1);
    });

    it('applicationReloadFromRepositoryReflectsExternalRepositoryChangesWithoutRuntimeMutation', 0, async () => {
      const revision = buildRevision('reloadable');
      const initial = buildProfileRecord('reloadable', 'VALID', 'REMOTE_URL', revision, 'secret-reload');
      const repository = new FakeProfileRepository([initial], 'reloadable');
      const coreService = new FakeCoreService();
      const vpnController = new FakeVpnController();
      const proxyService = new FakeProxyApplication();
      const schedulePort = new FakeProfileRefreshSchedulePort();
      const application = createApplication(
        repository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        coreService,
        undefined,
        vpnController,
        undefined,
        proxyService,
        undefined,
        undefined,
        schedulePort
      ) as ProfileApplication & ProfileApplicationSubscriptionTask5AContract;

      await application.reloadFromRepository();
      repository.overwriteProfile(createProfile({
        id: initial.id,
        name: 'Reloaded Name',
        sourceKind: initial.sourceKind,
        sourceDisplay: initial.sourceDisplay,
        sourceSecretRef: initial.sourceSecretRef,
        currentRevision: initial.currentRevision,
        failedCandidate: initial.failedCandidate,
        availability: initial.availability,
        lastError: initial.lastError,
        createdAt: initial.createdAt,
        updatedAt: buildTimestamp(44),
        lastSuccessfulUpdateAt: initial.lastSuccessfulUpdateAt,
        autoUpdateIntervalMs: 12 * 60 * 60 * 1000
      }));

      await application.reloadFromRepository();
      const snapshot = application.current();

      expect(snapshot.profiles[0].name).assertEqual('Reloaded Name');
      expect(snapshot.profiles[0].autoUpdateIntervalMs).assertEqual(12 * 60 * 60 * 1000);
      expect(coreService.loadCalls.length).assertEqual(0);
      expect(coreService.startCalls.length).assertEqual(0);
      expect(coreService.stopCalls.length).assertEqual(0);
      expect(vpnController.startCalls.length).assertEqual(0);
      expect(vpnController.stopCalls.length).assertEqual(0);
      expect(proxyService.reconcileCalls).assertEqual(0);
      expect(schedulePort.reconcileCalls.join(',')).assertEqual('false,true');
    });

    it('applicationReloadFromRepositoryPublishesReadySnapshotErrorWhenScheduleReconcileFails', 0, async () => {
      const revision = buildRevision('reload-schedule-error');
      const repository = new FakeProfileRepository([
        buildProfileRecord('reload-schedule-error', 'VALID', 'REMOTE_URL', revision, 'secret-reload', null, 2 * 60 * 60 * 1000)
      ], 'reload-schedule-error');
      const schedulePort = new FakeProfileRefreshSchedulePort();
      const application = createApplication(
        repository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        schedulePort
      ) as ProfileApplication & ProfileApplicationSubscriptionTask5AContract;

      await application.reloadFromRepository();
      schedulePort.error = new Error('reload schedule boom');

      await application.reloadFromRepository();
      const snapshot = application.current();

      expect(snapshot.status).assertEqual('READY');
      expect(snapshot.error?.code ?? '').assertEqual('SUBSCRIPTION_SCHEDULE_FAILED');
      expect(snapshot.profiles[0].id).assertEqual('reload-schedule-error');
      expect(snapshot.runtime.state).assertEqual('STOPPED');
    });

    it('applicationDeleteDisablesSubscriptionScheduleAfterRemovingLastScheduledProfile', 0, async () => {
      const revision = buildRevision('scheduled-delete');
      const repository = new FakeProfileRepository([
        buildProfileRecord('scheduled-delete', 'VALID', 'REMOTE_URL', revision, 'secret-delete', null, 2 * 60 * 60 * 1000)
      ], 'scheduled-delete');
      const schedulePort = new FakeProfileRefreshSchedulePort();
      const application = createApplication(
        repository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        schedulePort
      ) as ProfileApplication & ProfileApplicationSubscriptionTask5AContract;

      await application.reloadFromRepository();
      const result = await application.delete('scheduled-delete');

      expect(result.kind).assertEqual('DELETED');
      expect(schedulePort.reconcileCalls.join(',')).assertEqual('true,false');
    });

    it('applicationDeleteReturnsFailedButKeepsDeletionWhenScheduleReconcileFails', 0, async () => {
      const revision = buildRevision('scheduled-delete-fail');
      const repository = new FakeProfileRepository([
        buildProfileRecord('scheduled-delete-fail', 'VALID', 'REMOTE_URL', revision, 'secret-delete-fail', null, 2 * 60 * 60 * 1000)
      ], 'scheduled-delete-fail');
      const schedulePort = new FakeProfileRefreshSchedulePort();
      const application = createApplication(
        repository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        schedulePort
      ) as ProfileApplication & ProfileApplicationSubscriptionTask5AContract;

      await application.reloadFromRepository();
      schedulePort.error = new Error('delete schedule boom');
      const result = await application.delete('scheduled-delete-fail');
      const snapshot = application.current();

      expect(result.kind).assertEqual('FAILED');
      if (result.kind === 'FAILED') {
        expect(result.error.code).assertEqual('SUBSCRIPTION_SCHEDULE_FAILED');
      }
      expect(repository.readProfile('scheduled-delete-fail')).assertUndefined();
      expect(snapshot.status).assertEqual('READY');
      expect(snapshot.error?.code ?? '').assertEqual('SUBSCRIPTION_SCHEDULE_FAILED');
      expect(snapshot.profiles.length).assertEqual(0);
      expect(schedulePort.reconcileCalls.join(',')).assertEqual('true,false');
    });

    it('applicationUpdateIntervalBlocksRefreshAllSubscriptionsWhileMetadataSaveIsInFlight', 0, async () => {
      const revision = buildRevision('interval-lock');
      const repository = new FakeProfileRepository([
        buildProfileRecord('interval-lock', 'VALID', 'REMOTE_URL', revision, 'secret-interval-lock')
      ], 'interval-lock');
      repository.saveEntered = new DeferredVoid();
      repository.saveDeferred = new DeferredVoid();
      const batchUseCase = new FakeRefreshProfilesUseCase();
      const schedulePort = new FakeProfileRefreshSchedulePort();
      const application = createApplication(
        repository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        batchUseCase,
        schedulePort
      ) as ProfileApplication & ProfileApplicationSubscriptionTask5AContract;

      await application.reloadFromRepository();
      const updatePromise = application.updateAutoUpdateInterval('interval-lock', 2 * 60 * 60 * 1000);
      await repository.saveEntered.promise;
      const batchResult = await application.refreshAllSubscriptions();
      repository.saveDeferred.resolve();
      const updateResult = await updatePromise;

      expect(batchResult.kind).assertEqual('FAILED');
      if (batchResult.kind === 'FAILED') {
        expect(batchResult.error.code).assertEqual('SUBSCRIPTION_REFRESH_ALL_BUSY');
        expect(batchResult.error.retryable).assertTrue();
      }
      expect(batchUseCase.commands.length).assertEqual(0);
      expect(updateResult.kind).assertEqual('UPDATED');
      expect(repository.readProfile('interval-lock')?.autoUpdateIntervalMs).assertEqual(2 * 60 * 60 * 1000);
    });

    it('applicationUpdateProfileRejectsPlainHttpBeforePersistingMetadata', 0, async () => {
      const revision = buildRevision('plain-http-edit');
      const profile = buildProfileRecord('plain-http-edit', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'plain-http-edit');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const gateway = new FakeSourceGateway();
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        gateway
      );

      await application.initialize();
      const result = await application.updateProfile(
        'plain-http-edit',
        'Renamed plain profile',
        'http://legacy.example.com/subscription.yaml'
      );

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('IMPORT');
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(secretStore.encryptCalls.length).assertEqual(0);
      expect(gateway.remoteCommands.length).assertEqual(0);
    });

    it('applicationUpdateProfileAllowsNameOnlyWhileSystemVpnIsRunningWithoutRefresh', 0, async () => {
      const revision = buildRevision('vpn-name-only');
      const profile = buildProfileRecord('vpn-name-only', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'vpn-name-only');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const gateway = new FakeSourceGateway();
      const vpnController = new FakeVpnController();
      vpnController.setSnapshot(
        createVpnRuntimeSnapshot({
          state: 'RUNNING',
          activeRequest: {
            profileId: 'vpn-name-only',
            versionId: revision.validatedAt,
            sessionId: 'vpn-session-name-only'
          },
          activeHandle: {
            sessionId: 'vpn-session-name-only',
            attached: true
          },
          captureConfig: null,
          tunSnapshot: null,
          notificationActive: true,
          recoveryAttempt: 0,
          scheduledRetryDelayMs: null,
          lastFailure: null
        })
      );
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        gateway,
        vpnController
      );

      await application.initialize();
      const result = await application.updateProfile(
        'vpn-name-only',
        '  VPN name only  '
      );

      expect(result.kind).assertEqual('UPDATED');
      if (result.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.name).assertEqual('VPN name only');
      expect(gateway.remoteCommands.length).assertEqual(0);
      expect(secretStore.encryptCalls.length).assertEqual(0);
      expect(repository.readProfile('vpn-name-only')?.name).assertEqual('VPN name only');
    });

    it('applicationUpdateProfileRejectsSourceUrlEditWhileSystemVpnIsNotStopped', 0, async () => {
      const revision = buildRevision('vpn-url-edit');
      const profile = buildProfileRecord('vpn-url-edit', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'vpn-url-edit');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const gateway = new FakeSourceGateway();
      const vpnController = new FakeVpnController();
      vpnController.setSnapshot(
        createVpnRuntimeSnapshot({
          state: 'RUNNING',
          activeRequest: {
            profileId: 'vpn-url-edit',
            versionId: revision.validatedAt,
            sessionId: 'vpn-session-url-edit'
          },
          activeHandle: {
            sessionId: 'vpn-session-url-edit',
            attached: true
          },
          captureConfig: null,
          tunSnapshot: null,
          notificationActive: true,
          recoveryAttempt: 0,
          scheduledRetryDelayMs: null,
          lastFailure: null
        })
      );
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        gateway,
        vpnController
      );

      await application.initialize();
      const result = await application.updateProfile(
        'vpn-url-edit',
        'VPN name edit',
        'https://next.example.com/subscription.yaml'
      );

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('RUNTIME_STOP');
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(secretStore.encryptCalls.length).assertEqual(0);
      expect(gateway.remoteCommands.length).assertEqual(0);
    });

    it('applicationUpdateProfileSavesMetadataBeforeRefreshAndReturnsPartialFailureSafely', 0, async () => {
      const revision = buildRevision('refresh-failure');
      const profile = buildProfileRecord('refresh-failure', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'refresh-failure');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml?token=old');
      const gateway = new FakeSourceGateway();
      const sharedLog: string[] = [];
      repository.sharedLog = sharedLog;
      gateway.sharedLog = sharedLog;
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        gateway
      );

      await application.initialize();
      sharedLog.length = 0;
      const result = await application.updateProfile(
        'refresh-failure',
        '  Renamed refresh failure  ',
        'https://next.example.com/subscription.yaml?token=next'
      );

      expect(result.kind).assertEqual('UPDATED_REFRESH_FAILED');
      if (result.kind !== 'UPDATED_REFRESH_FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.name).assertEqual('Renamed refresh failure');
      expect(result.profile.availability).assertEqual('UPDATE_FAILED_USING_VALID');
      expect(result.profile.lastError !== null).assertTrue();
      expect(result.error.stage).assertEqual('DOWNLOAD');
      expect(result.error.technicalDetail.includes('token=')).assertFalse();
      expect(result.error.technicalDetail.includes('https://next.example.com')).assertFalse();
      expect(gateway.remoteCommands.length).assertEqual(1);
      expect(gateway.remoteCommands[0].profileName).assertEqual('Renamed refresh failure');
      expect(sharedLog.indexOf('repository.save:refresh-failure') >= 0).assertTrue();
      expect(sharedLog.indexOf('source.acquireRemote:Renamed refresh failure') >= 0).assertTrue();
      expect(
        sharedLog.indexOf('repository.save:refresh-failure') < sharedLog.indexOf('source.acquireRemote:Renamed refresh failure')
      ).assertTrue();
    });

    it('applicationUpdateProfileReturnsUpdatedAfterSuccessfulRefresh', 0, async () => {
      const revision = buildRevision('refresh-success');
      const refreshedRevision = createProfileRevision(
        'profiles/refresh-success-updated.yaml',
        buildDigest('refresh-success-updated'),
        88,
        buildTimestamp(41)
      );
      const profile = buildProfileRecord('refresh-success', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'refresh-success');
      const contentStore = new FakeProfileContentStore();
      contentStore.queueRetainResult(refreshedRevision);
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const gateway = new FakeSourceGateway();
      gateway.queueRemoteAcquisition({
        kind: 'ACQUIRED',
        profileName: 'Renamed refresh success',
        sourceDisplay: 'https://next.example.com',
        staged: buildStagedSource('refresh-success')
      });
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        gateway
      );

      await application.initialize();
      const result = await application.updateProfile(
        'refresh-success',
        '  Renamed refresh success  ',
        'https://next.example.com/subscription.yaml'
      );

      expect(result.kind).assertEqual('UPDATED');
      if (result.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.name).assertEqual('Renamed refresh success');
      expect(result.profile.currentRevision?.relativePath).assertEqual(refreshedRevision.relativePath);
      expect(result.profile.availability).assertEqual('VALID');
      expect(gateway.remoteCommands.length).assertEqual(1);
      expect(contentStore.retainCalls.join('>')).assertEqual('refresh-success:CURRENT');
    });

    it('applicationReplaceSubscriptionUrlAppliesHttpAndVpnSafetyAndAllowsConfirmedHttp', 0, async () => {
      const httpRevision = buildRevision('replace-http');
      const httpProfile = buildProfileRecord('replace-http', 'VALID', 'REMOTE_URL', httpRevision, 'secret-http');
      const httpRepository = new FakeProfileRepository([httpProfile], 'replace-http');
      const httpSecretStore = new FakeSubscriptionSecretStore();
      httpSecretStore.storedSecrets.set('secret-http', 'https://origin.example.com/subscription.yaml');
      const httpGateway = new FakeSourceGateway();
      const httpApp = createApplication(
        httpRepository,
        new FakeProfileContentStore(),
        httpSecretStore,
        new FakeCoreService(),
        httpGateway
      );
      await httpApp.initialize();
      const unconfirmed = await httpApp.replaceSubscriptionUrl('replace-http', 'http://legacy.example.com/subscription.yaml');

      expect(unconfirmed.kind).assertEqual('FAILED');
      expect(httpRepository.savedProfiles.length).assertEqual(0);
      expect(httpGateway.remoteCommands.length).assertEqual(0);

      const vpnRevision = buildRevision('replace-vpn');
      const vpnProfile = buildProfileRecord('replace-vpn', 'VALID', 'REMOTE_URL', vpnRevision, 'secret-vpn');
      const vpnRepository = new FakeProfileRepository([vpnProfile], 'replace-vpn');
      const vpnSecretStore = new FakeSubscriptionSecretStore();
      vpnSecretStore.storedSecrets.set('secret-vpn', 'https://origin.example.com/subscription.yaml');
      const vpnGateway = new FakeSourceGateway();
      const vpnController = new FakeVpnController();
      vpnController.setSnapshot(buildVpnSnapshot('RUNNING', 'replace-vpn', 'vpn-session-replace', vpnRevision.validatedAt));
      const vpnApp = createApplication(
        vpnRepository,
        new FakeProfileContentStore(),
        vpnSecretStore,
        new FakeCoreService(),
        vpnGateway,
        vpnController
      );
      await vpnApp.initialize();
      const blocked = await vpnApp.replaceSubscriptionUrl('replace-vpn', 'https://next.example.com/subscription.yaml');

      expect(blocked.kind).assertEqual('FAILED');
      expect(vpnRepository.savedProfiles.length).assertEqual(0);
      expect(vpnGateway.remoteCommands.length).assertEqual(0);

      const okRevision = buildRevision('replace-ok');
      const okProfile = buildProfileRecord('replace-ok', 'VALID', 'REMOTE_URL', okRevision, 'secret-ok');
      const okRepository = new FakeProfileRepository([okProfile], 'replace-ok');
      const okContentStore = new FakeProfileContentStore();
      const refreshedRevision = createProfileRevision(
        'profiles/replace-ok-updated.yaml',
        buildDigest('replace-ok-updated'),
        99,
        buildTimestamp(42)
      );
      okContentStore.queueRetainResult(refreshedRevision);
      const okSecretStore = new FakeSubscriptionSecretStore();
      okSecretStore.storedSecrets.set('secret-ok', 'https://origin.example.com/subscription.yaml');
      const okGateway = new FakeSourceGateway();
      okGateway.queueRemoteAcquisition({
        kind: 'ACQUIRED',
        profileName: okProfile.name,
        sourceDisplay: 'http://legacy.example.com',
        staged: buildStagedSource('replace-ok', 43)
      });
      const okApp = createApplication(
        okRepository,
        okContentStore,
        okSecretStore,
        new FakeCoreService(),
        okGateway
      );
      await okApp.initialize();
      const confirmed = await okApp.replaceSubscriptionUrl(
        'replace-ok',
        'http://legacy.example.com/subscription.yaml',
        true
      );

      expect(confirmed.kind).assertEqual('REPLACED');
      if (confirmed.kind !== 'REPLACED') {
        expect(false).assertTrue();
        return;
      }
      expect(confirmed.profile.currentRevision?.relativePath).assertEqual(refreshedRevision.relativePath);
      expect(okGateway.remoteCommands.length).assertEqual(1);
      expect(okGateway.remoteCommands[0].allowPlainHttp).assertTrue();
    });

    it('sourceChangingUpdateBlocksConcurrentStartVpnButNameOnlyUpdateDoesNot', 0, async () => {
      const revision = buildRevision('edit-lock');
      const profile = buildProfileRecord('edit-lock', 'VALID', 'REMOTE_URL', revision, 'secret-lock');
      const repository = new FakeProfileRepository([profile], 'edit-lock');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-lock', 'https://origin.example.com/subscription.yaml');
      secretStore.encryptEntered = new DeferredVoid();
      secretStore.encryptDeferred = new DeferredString();
      const gateway = new FakeSourceGateway();
      const vpnController = new FakeVpnController();
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        gateway,
        vpnController
      );

      await application.initialize();
      const sourceChangePromise = application.updateProfile(
        'edit-lock',
        'Renamed lock profile',
        'https://next.example.com/subscription.yaml'
      );
      await secretStore.encryptEntered.promise;
      const blockedStart = await application.startVpnGlobalCapture();
      secretStore.encryptDeferred.resolve('secret-1');
      const sourceChangeResult = await sourceChangePromise;

      expect(blockedStart.kind).assertEqual('REJECTED');
      if (blockedStart.kind === 'REJECTED') {
        expect(blockedStart.failure.code).assertEqual('VPN_CREATE_FAILED');
      }
      expect(vpnController.startCalls.length).assertEqual(0);
      expect(sourceChangeResult.kind).assertEqual('UPDATED_REFRESH_FAILED');

      const nameOnlyRevision = buildRevision('name-only-concurrent');
      const nameOnlyProfile = buildProfileRecord('name-only-concurrent', 'VALID', 'REMOTE_URL', nameOnlyRevision, 'secret-name-only');
      const nameOnlyRepository = new FakeProfileRepository([nameOnlyProfile], 'name-only-concurrent');
      nameOnlyRepository.saveEntered = new DeferredVoid();
      nameOnlyRepository.saveDeferred = new DeferredVoid();
      const nameOnlyContentStore = new FakeProfileContentStore();
      const nameOnlySecretStore = new FakeSubscriptionSecretStore();
      nameOnlySecretStore.storedSecrets.set('secret-name-only', 'https://origin.example.com/subscription.yaml');
      const nameOnlyVpn = new FakeVpnController();
      const nameOnlyApp = createApplication(
        nameOnlyRepository,
        nameOnlyContentStore,
        nameOnlySecretStore,
        new FakeCoreService(),
        new FakeSourceGateway(),
        nameOnlyVpn
      );

      await nameOnlyApp.initialize();
      const nameOnlyPromise = nameOnlyApp.updateProfile('name-only-concurrent', 'Name Only Concurrent');
      await nameOnlyRepository.saveEntered.promise;
      const allowedStart = await nameOnlyApp.startVpnGlobalCapture();
      nameOnlyRepository.saveDeferred.resolve();
      const nameOnlyResult = await nameOnlyPromise;

      expect(allowedStart.kind).assertEqual('STARTED');
      expect(nameOnlyVpn.startCalls.length).assertEqual(1);
      expect(nameOnlyResult.kind).assertEqual('UPDATED');
    });

    it('legacyReplaceWhileNameOnlyRenameCompletesPreservesNewerName', 0, async () => {
      const revision = buildRevision('legacy-replace-race');
      const profile = buildProfileRecord('legacy-replace-race', 'VALID', 'REMOTE_URL', revision, 'secret-race');
      const repository = new FakeProfileRepository([profile], 'legacy-replace-race');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-race', 'https://origin.example.com/subscription.yaml');
      const proxyService = new FakeProxyApplication();
      const replaceDrainEntered = new DeferredVoid();
      proxyService.drainEntered = replaceDrainEntered;
      const replaceDrainDeferred = new DeferredVoid();
      proxyService.drainDeferred = replaceDrainDeferred;
      const refreshedRevision = createProfileRevision(
        'profiles/legacy-replace-race-updated.yaml',
        buildDigest('legacy-replace-race-updated'),
        77,
        buildTimestamp(44)
      );
      contentStore.queueRetainResult(refreshedRevision);
      const gateway = new FakeSourceGateway();
      gateway.queueRemoteAcquisition({
        kind: 'ACQUIRED',
        profileName: 'Newer Profile Name',
        sourceDisplay: 'https://next.example.com',
        staged: buildStagedSource('legacy-replace-race', 45)
      });
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        gateway,
        undefined,
        undefined,
        proxyService
      );

      await application.initialize();
      const replacePromise = application.replaceSubscriptionUrl(
        'legacy-replace-race',
        'https://next.example.com/subscription.yaml'
      );
      await replaceDrainEntered.promise;
      const renameResult = await application.updateProfile('legacy-replace-race', 'Newer Profile Name');
      replaceDrainDeferred.resolve();
      const replaceResult = await replacePromise;

      expect(renameResult.kind).assertEqual('UPDATED');
      expect(replaceResult.kind).assertEqual('REPLACED');
      if (replaceResult.kind !== 'REPLACED') {
        expect(false).assertTrue();
        return;
      }
      expect(replaceResult.profile.name).assertEqual('Newer Profile Name');
      const persisted: Profile | undefined = repository.readProfile('legacy-replace-race');
      expect(persisted !== undefined).assertTrue();
      if (persisted === undefined) {
        expect(false).assertTrue();
        return;
      }
      expect(persisted.name).assertEqual('Newer Profile Name');
    });

    it('applicationObserversSeeMutationAndRuntimeRefreshWhileCoreKeepsSingleSubscription', 0, async () => {
      const revision = buildRevision('active');
      const remoteRevision = buildRevision('remote');
      const active = buildProfileRecord('active', 'VALID', 'LOCAL_FILE', revision);
      const remote = buildProfileRecord('remote', 'VALID', 'REMOTE_URL', remoteRevision, 'secret-remote');
      const repository = new FakeProfileRepository([active, remote], 'active');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/active.yaml');
      contentStore.resolvedPaths.set(remoteRevision.relativePath, '/sandbox/profiles/remote.yaml');
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-remote', 'https://origin.example.com/subscription.yaml');
      const coreService = new FakeCoreService();
      const runtimeCoordinator = createRuntimeCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(20), buildTimestamp(21), buildTimestamp(22), buildTimestamp(23), buildTimestamp(24)]
      );
      const application = createApplicationWithCoordinator(
        repository,
        contentStore,
        secretStore,
        coreService,
        runtimeCoordinator
      );
      const observed: ProfileApplicationSnapshot[] = [];

      await application.initialize();
      const subscriptionId = application.subscribe((snapshot: ProfileApplicationSnapshot): void => {
        observed.push(snapshot);
      });

      await application.enable('remote');
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING');
      await runtimeCoordinator.start();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('STOPPED');
      await runtimeCoordinator.stop();
      await application.delete('active');
      await application.replaceSubscriptionUrl('remote', 'https://next.example.com/subscription.yaml');
      application.unsubscribe(subscriptionId);
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('ERROR');
      coreService.emitRuntime('ERROR', 'ignored-after-unsubscribe');
      const runtimeStates: string[] = [];
      for (let index: number = 0; index < observed.length; index += 1) {
        runtimeStates.push(observed[index].runtime.state);
      }

      expect(observed.length >= 4).assertTrue();
      expect(observed[0] === observed[1]).assertFalse();
      expect(observed[0].activeProfileId).assertEqual('remote');
      expect(runtimeStates.includes('STARTING')).assertTrue();
      expect(runtimeStates.includes('RUNNING')).assertTrue();
      expect(runtimeStates.includes('STOPPING')).assertTrue();
      expect(runtimeStates.includes('STOPPED')).assertTrue();
      expect(observed[observed.length - 1].profiles.length).assertEqual(1);
      expect(coreService.subscribeIds.length).assertEqual(1);
      expect(application.current().profiles[0].sourceDisplay).assertEqual('https://next.example.com');
    });

    it('profileApplicationInitializesReconcileBeforeCoordinatorAndDelegatesWithoutRepositoryExposure', 0, async () => {
      const revision = buildRevision('app');
      const profile = buildProfileRecord('app', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'app');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const coreService = new FakeCoreService();
      const application = createApplication(repository, contentStore, secretStore, coreService);

      await application.initialize();
      const snapshot = application.current();

      expect(contentStore.reconciledPaths.length).assertEqual(1);
      expect(snapshot.runtime.state).assertEqual('STOPPED');
    });

    it('applicationStartVpnCallsControllerSynchronouslyFromReadyStoppedStateWithCommittedVersion', 0, async () => {
      const revision = buildRevision('vpn');
      const profile = buildProfileRecord('vpn', 'VALID', 'REMOTE_URL', revision, 'secret-vpn');
      const repository = new FakeProfileRepository([profile], 'vpn');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/vpn.yaml');
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-vpn', 'https://origin.example.com/subscription.yaml');
      const coreService = new FakeCoreService();
      const vpnController = new FakeVpnController();
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        coreService,
        undefined,
        vpnController,
        new FakeIdGenerator(['vpn-session-1'])
      );

      await application.initialize();
      const startPromise: Promise<VpnControllerStartResult> = application.startVpnGlobalCapture();
      const result: VpnControllerStartResult = await startPromise;

      expect(result.kind).assertEqual('STARTED');
      expect(vpnController.startCalls.length).assertEqual(1);
      expect(coreService.stopCalls.length).assertEqual(0);
      expect(vpnController.startCalls[0].profileId).assertEqual('vpn');
      expect(vpnController.startCalls[0].versionId).assertEqual(revision.validatedAt);
      expect(vpnController.startCalls[0].sessionId).assertEqual('vpn-session-vpn-session-1');
    });

    it('applicationStartVpnDrainsBeforeSharedRuntimeUpgradeAndMapsDrainFailure', 0, async () => {
      const revision = buildRevision('vpn-drain');
      const profile = buildProfileRecord('vpn-drain', 'VALID', 'REMOTE_URL', revision, 'secret-vpn-drain');
      const repository = new FakeProfileRepository([profile], 'vpn-drain');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-vpn-drain', 'https://origin.example.com/subscription.yaml');
      const coreService = new FakeCoreService();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING');
      const vpnController = new FakeVpnController();
      const proxyService = new FakeProxyApplication();
      const runtimeCoordinator = createRuntimeCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(20), buildTimestamp(21), buildTimestamp(22), buildTimestamp(23)]
      );
      const application = createApplicationWithCoordinator(
        repository,
        contentStore,
        secretStore,
        coreService,
        runtimeCoordinator,
        undefined,
        vpnController,
        new FakeIdGenerator(['vpn-session-drain']),
        proxyService
      );

      await application.initialize();
      const startedRuntime: LocalRuntimeStartResult = await runtimeCoordinator.start();
      expect(startedRuntime.kind).assertEqual('STARTED');
      const drainCallsBeforeVpnStart: number = proxyService.cancelAndDrainCalls;
      const upgradedResult: VpnControllerStartResult = await application.startVpnGlobalCapture();

      expect(proxyService.cancelAndDrainCalls).assertEqual(drainCallsBeforeVpnStart + 1);
      expect(upgradedResult.kind).assertEqual('STARTED');
      expect(vpnController.startCalls.length).assertEqual(1);

      proxyService.drainResult = createProxyRejectedResult(
        createProxyRejectedError('PROXY_DELAY_DRAIN_FAILED', true, buildTimestamp(42))
      );
      const drainFailureResult: VpnControllerStartResult = await application.startVpnGlobalCapture();

      expect(proxyService.cancelAndDrainCalls).assertEqual(drainCallsBeforeVpnStart + 2);
      expect(drainFailureResult.kind).assertEqual('REJECTED');
      if (drainFailureResult.kind === 'REJECTED') {
        expect(drainFailureResult.failure.code).assertEqual('VPN_CREATE_FAILED');
      }
      expect(vpnController.startCalls.length).assertEqual(1);
    });

    it('applicationStartVpnGeneratesDistinctOpaqueSessionIdsAcrossSeparateRuns', 0, async () => {
      const revision = buildRevision('alpha');
      const profile = buildProfileRecord('alpha', 'VALID', 'REMOTE_URL', revision, 'secret-alpha');
      const repository = new FakeProfileRepository([profile], 'alpha');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/alpha.yaml');
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-alpha', 'https://origin.example.com/subscription.yaml?token=secret-alpha');
      const coreService = new FakeCoreService();
      const vpnController = new FakeVpnController();
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        coreService,
        undefined,
        vpnController,
        new FakeIdGenerator(['run-1', 'run-2'])
      );

      await application.initialize();
      await application.startVpnGlobalCapture();
      await application.stopVpnGlobalCapture();
      await application.startVpnGlobalCapture();

      expect(vpnController.startCalls.length).assertEqual(2);
      expect(vpnController.startCalls[0].sessionId === vpnController.startCalls[1].sessionId).assertFalse();
      expect(vpnController.startCalls[0].sessionId.includes('alpha')).assertFalse();
      expect(vpnController.startCalls[1].sessionId.includes('alpha')).assertFalse();
      expect(vpnController.startCalls[0].sessionId.includes(revision.validatedAt)).assertFalse();
      expect(vpnController.startCalls[1].sessionId.includes(revision.validatedAt)).assertFalse();
      expect(vpnController.startCalls[0].sessionId.includes('secret-alpha')).assertFalse();
      expect(vpnController.startCalls[1].sessionId.includes('origin.example.com')).assertFalse();
    });

    it('applicationStartVpnFailsClosedWhenTheSelectedProfileCannotProduceACommittedRevision', 0, async () => {
      const unavailableCases: UnavailableVpnCase[] = [
        new UnavailableVpnCase(
          new FakeProfileRepository([], 'missing'),
          new FakeProfileContentStore(),
          new FakeSubscriptionSecretStore()
        ),
        new UnavailableVpnCase(
          new FakeProfileRepository([buildProfileRecord('invalid', 'INVALID', 'LOCAL_FILE', buildRevision('invalid'))], 'invalid'),
          new FakeProfileContentStore(),
          new FakeSubscriptionSecretStore()
        ),
        new UnavailableVpnCase(
          new FakeProfileRepository([buildProfileRecord('empty', 'INVALID', 'LOCAL_FILE', null)], 'empty'),
          new FakeProfileContentStore(),
          new FakeSubscriptionSecretStore()
        )
      ];

      for (let index = 0; index < unavailableCases.length; index += 1) {
        const vpnController = new FakeVpnController();
        const application = createApplication(
          unavailableCases[index].repository,
          unavailableCases[index].contentStore,
          unavailableCases[index].secretStore,
          new FakeCoreService(),
          undefined,
          vpnController
        );

        await application.initialize();
        const result = await application.startVpnGlobalCapture();

        expect(result.kind).assertEqual('REJECTED');
        if (result.kind === 'REJECTED') {
          expect(result.failure.code).assertEqual('VPN_PROFILE_UNAVAILABLE');
        }
        expect(vpnController.startCalls.length).assertEqual(0);
      }
    });

    it('applicationStartVpnAllowsRunningSharedRuntimeWithoutStoppingIt', 0, async () => {
      const revision = buildRevision('beta');
      const profile = buildProfileRecord('beta', 'VALID', 'REMOTE_URL', revision, 'secret-beta');
      const repository = new FakeProfileRepository([profile], 'beta');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/beta.yaml');
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-beta', `https://origin.example.com/subscription.yaml?token=${buildSecretTokenValue()}`);
      const coreService = new FakeCoreService();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING');
      const vpnController = new FakeVpnController();
      const runtimeCoordinator = createRuntimeCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(20), buildTimestamp(21), buildTimestamp(22), buildTimestamp(23)]
      );
      const application = createApplicationWithCoordinator(
        repository,
        contentStore,
        secretStore,
        coreService,
        runtimeCoordinator,
        undefined,
        vpnController,
        new FakeIdGenerator(['run-blocked'])
      );

      await application.initialize();
      const startedRuntime: LocalRuntimeStartResult = await runtimeCoordinator.start();
      expect(startedRuntime.kind).assertEqual('STARTED');
      const result = await application.startVpnGlobalCapture();

      expect(result.kind).assertEqual('STARTED');
      expect(coreService.stopCalls.length).assertEqual(0);
      expect(vpnController.startCalls.length).assertEqual(1);
    });

    it('applicationStartVpnFailsClosedWhileSharedRuntimeTransitionIsInFlight', 0, async () => {
      const transitionStates: Array<'STARTING' | 'STOPPING'> = ['STARTING', 'STOPPING'];

      for (let index = 0; index < transitionStates.length; index += 1) {
        const transitionState: 'STARTING' | 'STOPPING' = transitionStates[index];
        const revision = buildRevision(`transition-${transitionState.toLowerCase()}`);
        const profile = buildProfileRecord(
          `transition-${transitionState.toLowerCase()}`,
          'VALID',
          'REMOTE_URL',
          revision,
          `secret-transition-${transitionState.toLowerCase()}`
        );
        const repository = new FakeProfileRepository([profile], `transition-${transitionState.toLowerCase()}`);
        const contentStore = new FakeProfileContentStore();
        const secretStore = new FakeSubscriptionSecretStore();
        secretStore.storedSecrets.set(
          `secret-transition-${transitionState.toLowerCase()}`,
          `https://origin.example.com/transition-${transitionState.toLowerCase()}.yaml`
        );
        const coreService = new FakeCoreService();
        const vpnController = new FakeVpnController();
        const runtimeCoordinator = createRuntimeCoordinator(
          repository,
          contentStore,
          coreService,
          [buildTimestamp(20), buildTimestamp(21), buildTimestamp(22), buildTimestamp(23)]
        );
        const application = createApplicationWithCoordinator(
          repository,
          contentStore,
          secretStore,
          coreService,
          runtimeCoordinator,
          undefined,
          vpnController,
          new FakeIdGenerator([`transition-${transitionState.toLowerCase()}`])
        );

        await application.initialize();
        if (transitionState === 'STARTING') {
          coreService.startDeferred = new DeferredRuntimeSnapshot();
          const startPromise: Promise<LocalRuntimeStartResult> = runtimeCoordinator.start();
          await waitForCondition(() => coreService.startCalls.length === 1);

          const result: VpnControllerStartResult = await application.startVpnGlobalCapture();

          expect(result.kind).assertEqual('REJECTED');
          if (result.kind === 'REJECTED') {
            expect(result.failure.code).assertEqual('VPN_CREATE_FAILED');
          }
          expect(vpnController.startCalls.length).assertEqual(0);
          coreService.startDeferred.resolve(buildRuntimeSnapshot('RUNNING'));
          await startPromise;
          continue;
        }

        coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING');
        const startedRuntime: LocalRuntimeStartResult = await runtimeCoordinator.start();
        expect(startedRuntime.kind).assertEqual('STARTED');
        coreService.stopDeferred = new DeferredRuntimeSnapshot();
        const stopPromise: Promise<LocalRuntimeStopResult> = runtimeCoordinator.stop();
        await waitForCondition(() => coreService.stopCalls.length === 1);

        const result: VpnControllerStartResult = await application.startVpnGlobalCapture();

        expect(result.kind).assertEqual('REJECTED');
        if (result.kind === 'REJECTED') {
          expect(result.failure.code).assertEqual('VPN_CREATE_FAILED');
        }
        expect(vpnController.startCalls.length).assertEqual(0);
        coreService.stopDeferred.resolve(buildRuntimeSnapshot('STOPPED'));
        await stopPromise;
      }
    });

    it('applicationStartVpnFailsClosedBeforeApplicationIsReady', 0, async () => {
      const revision = buildRevision('loading');
      const profile = buildProfileRecord('loading', 'VALID', 'LOCAL_FILE', revision);
      const repository = new FakeProfileRepository([profile], 'loading');
      const vpnController = new FakeVpnController();
      const application = createApplication(
        repository,
        new FakeProfileContentStore(),
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        undefined,
        vpnController
      );

      const result: VpnControllerStartResult = await application.startVpnGlobalCapture();

      expect(result.kind).assertEqual('REJECTED');
      if (result.kind === 'REJECTED') {
        expect(result.failure.code).assertEqual('VPN_PROFILE_UNAVAILABLE');
      }
      expect(repository.log.length).assertEqual(0);
      expect(vpnController.startCalls.length).assertEqual(0);
    });

    it('profileApplicationDelegatesProxyOperationsAndClonesProxyReconciliationSnapshots', 0, async () => {
      const revision = buildRevision('active');
      const profile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', revision, 'secret-active');
      const repository = new FakeProfileRepository([profile], 'active');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const proxyService = new FakeProxyApplication();
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        proxyService
      );

      await application.initialize();
      await application.listGroups();
      await application.queryGroup('Selector');
      await application.select('Selector', 'Node A', 2);
      const reconcileResult = await application.reconcileActiveSelections();
      const snapshot = application.current();

      expect(proxyService.listGroupsCalls).assertEqual(1);
      expect(proxyService.queryGroupCalls.join(',')).assertEqual('Selector');
      expect(proxyService.selectCalls.join(',')).assertEqual('Selector:Node A:2');
      expect(proxyService.reconcileCalls).assertEqual(1);
      expect(reconcileResult.kind).assertEqual('RECONCILED');
      expect(snapshot.proxyReconciliation?.kind ?? '').assertEqual('RECONCILED');

      if (snapshot.proxyReconciliation?.kind === 'RECONCILED') {
        snapshot.proxyReconciliation.keptCount = 999;
      }
      const currentReconciliation = application.current().proxyReconciliation;
      expect(currentReconciliation?.kind ?? '').assertEqual('RECONCILED');
      if (currentReconciliation?.kind === 'RECONCILED') {
        expect(currentReconciliation.keptCount).assertEqual(2);
      }
    });

    it('profileApplicationQueryHomeProxySelectionReturnsPrimaryGroupAndDirectTerminalNode', 0, async () => {
      const revision = buildRevision('active');
      const profile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', revision, 'secret-active');
      const repository = new FakeProfileRepository([profile], 'active');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const proxyService = new FakeProxyApplication();
      proxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult(['Primary', 'Secondary'], 3, null, 'active', revision.validatedAt, revision.sha256Digest)
      );
      proxyService.queueQueryGroupResult(
        'Primary',
        buildProxyGroupQueryResult(
          'Primary',
          3,
          'Node A',
          [buildProxyNodeSelectionInput('Node A', true)],
          null,
          'active',
          revision.validatedAt,
          revision.sha256Digest
        )
      );
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        proxyService
      );

      const summary = await application.queryHomeProxySelection();

      expect(summary?.groupName ?? '').assertEqual('Primary');
      expect(summary?.nodeName ?? '').assertEqual('Node A');
      expect(proxyService.listGroupsCalls).assertEqual(1);
      expect(proxyService.queryGroupRequests.length).assertEqual(1);
      expect(proxyService.queryGroupRequests[0].groupName).assertEqual('Primary');
      expect(proxyService.queryGroupRequests[0].groupPath.join(',')).assertEqual('Primary');
    });

    it('profileApplicationQueryHomeProxySelectionTraversesNestedSelectedGroupsWithInclusivePaths', 0, async () => {
      const revision = buildRevision('active');
      const profile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', revision, 'secret-active');
      const repository = new FakeProfileRepository([profile], 'active');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const proxyService = new FakeProxyApplication();
      proxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult(['Primary', 'Secondary'], 4, null, 'active', revision.validatedAt, revision.sha256Digest)
      );
      proxyService.queueQueryGroupResult(
        'Primary',
        buildProxyGroupQueryResult(
          'Primary',
          4,
          'Nested',
          [buildProxyNodeSelectionInput('Nested', true, true)],
          null,
          'active',
          revision.validatedAt,
          revision.sha256Digest
        )
      );
      proxyService.queueQueryGroupResult(
        'Nested',
        buildProxyGroupQueryResult(
          'Nested',
          4,
          'Node B',
          [buildProxyNodeSelectionInput('Node B', true)],
          null,
          'active',
          revision.validatedAt,
          revision.sha256Digest
        )
      );
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        proxyService
      );

      await application.initialize();
      const summary = await application.queryHomeProxySelection();

      expect(summary?.groupName ?? '').assertEqual('Primary');
      expect(summary?.nodeName ?? '').assertEqual('Node B');
      expect(proxyService.queryGroupRequests.length).assertEqual(2);
      expect(proxyService.queryGroupRequests[0].groupName).assertEqual('Primary');
      expect(proxyService.queryGroupRequests[0].groupPath.join(',')).assertEqual('Primary');
      expect(proxyService.queryGroupRequests[1].groupName).assertEqual('Nested');
      expect(proxyService.queryGroupRequests[1].groupPath.join(',')).assertEqual('Primary,Nested');
    });

    it('profileApplicationQueryHomeProxySelectionReturnsUndefinedWhenGroupListIsUnavailable', 0, async () => {
      const emptyRevision = buildRevision('active');
      const emptyProfile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', emptyRevision, 'secret-active');
      const emptyRepository = new FakeProfileRepository([emptyProfile], 'active');
      const emptyContentStore = new FakeProfileContentStore();
      const emptySecretStore = new FakeSubscriptionSecretStore();
      emptySecretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const emptyProxyService = new FakeProxyApplication();
      emptyProxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult([], 5, null, 'active', emptyRevision.validatedAt, emptyRevision.sha256Digest)
      );
      const emptyApplication = createApplication(
        emptyRepository,
        emptyContentStore,
        emptySecretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        emptyProxyService
      );

      const emptySummary = await emptyApplication.queryHomeProxySelection();

      expect(emptySummary === undefined).assertTrue();
      expect(emptyProxyService.queryGroupRequests.length).assertEqual(0);

      const rejectedRevision = buildRevision('active');
      const rejectedProfile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', rejectedRevision, 'secret-active');
      const rejectedRepository = new FakeProfileRepository([rejectedProfile], 'active');
      const rejectedContentStore = new FakeProfileContentStore();
      const rejectedSecretStore = new FakeSubscriptionSecretStore();
      rejectedSecretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const rejectedProxyService = new FakeProxyApplication();
      rejectedProxyService.queueListGroupsResult(
        createProxyRejectedResult(createProxyRejectedError('PROXY_RUNTIME_NOT_READY', true, buildTimestamp(40)))
      );
      const rejectedApplication = createApplication(
        rejectedRepository,
        rejectedContentStore,
        rejectedSecretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        rejectedProxyService
      );

      const rejectedSummary = await rejectedApplication.queryHomeProxySelection();

      expect(rejectedSummary === undefined).assertTrue();
      expect(rejectedProxyService.queryGroupRequests.length).assertEqual(0);

      const thrownRevision = buildRevision('active');
      const thrownProfile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', thrownRevision, 'secret-active');
      const thrownRepository = new FakeProfileRepository([thrownProfile], 'active');
      const thrownContentStore = new FakeProfileContentStore();
      const thrownSecretStore = new FakeSubscriptionSecretStore();
      thrownSecretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const thrownProxyService = new FakeProxyApplication();
      thrownProxyService.listGroupsError = new Error('list exploded');
      const thrownApplication = createApplication(
        thrownRepository,
        thrownContentStore,
        thrownSecretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        thrownProxyService
      );

      const thrownSummary = await thrownApplication.queryHomeProxySelection();

      expect(thrownSummary === undefined).assertTrue();
      expect(thrownProxyService.queryGroupRequests.length).assertEqual(0);
    });

    it('profileApplicationQueryHomeProxySelectionReturnsUndefinedWhenDirectQueryIsRejectedOrThrows', 0, async () => {
      const rejectedRevision = buildRevision('active');
      const rejectedProfile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', rejectedRevision, 'secret-active');
      const rejectedRepository = new FakeProfileRepository([rejectedProfile], 'active');
      const rejectedContentStore = new FakeProfileContentStore();
      const rejectedSecretStore = new FakeSubscriptionSecretStore();
      rejectedSecretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const rejectedProxyService = new FakeProxyApplication();
      rejectedProxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult(['Primary'], 6, null, 'active', rejectedRevision.validatedAt, rejectedRevision.sha256Digest)
      );
      rejectedProxyService.queueQueryGroupResult(
        'Primary',
        createProxyRejectedResult(createProxyRejectedError('PROXY_QUERY_FAILED', true, buildTimestamp(41)))
      );
      const rejectedApplication = createApplication(
        rejectedRepository,
        rejectedContentStore,
        rejectedSecretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        rejectedProxyService
      );

      const rejectedSummary = await rejectedApplication.queryHomeProxySelection();

      expect(rejectedSummary === undefined).assertTrue();
      expect(rejectedProxyService.queryGroupRequests.length).assertEqual(1);

      const thrownRevision = buildRevision('active');
      const thrownProfile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', thrownRevision, 'secret-active');
      const thrownRepository = new FakeProfileRepository([thrownProfile], 'active');
      const thrownContentStore = new FakeProfileContentStore();
      const thrownSecretStore = new FakeSubscriptionSecretStore();
      thrownSecretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const thrownProxyService = new FakeProxyApplication();
      thrownProxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult(['Primary'], 6, null, 'active', thrownRevision.validatedAt, thrownRevision.sha256Digest)
      );
      thrownProxyService.queryGroupError = new Error('query exploded');
      const thrownApplication = createApplication(
        thrownRepository,
        thrownContentStore,
        thrownSecretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        thrownProxyService
      );

      const thrownSummary = await thrownApplication.queryHomeProxySelection();

      expect(thrownSummary === undefined).assertTrue();
      expect(thrownProxyService.queryGroupRequests.length).assertEqual(1);
    });

    it('profileApplicationQueryHomeProxySelectionReturnsUndefinedWhenSelectedNodeIsMissingBlankOrNotSelected', 0, async () => {
      const blankRevision = buildRevision('active');
      const blankProfile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', blankRevision, 'secret-active');
      const blankRepository = new FakeProfileRepository([blankProfile], 'active');
      const blankContentStore = new FakeProfileContentStore();
      const blankSecretStore = new FakeSubscriptionSecretStore();
      blankSecretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const blankProxyService = new FakeProxyApplication();
      blankProxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult(['Primary'], 7, null, 'active', blankRevision.validatedAt, blankRevision.sha256Digest)
      );
      blankProxyService.queueQueryGroupResult(
        'Primary',
        buildRawProxyGroupQueryResultWithSelectedName(
          'Primary',
          7,
          '',
          [buildProxyNodeSelectionInput('Node A', true)],
          null,
          'active',
          blankRevision.validatedAt,
          blankRevision.sha256Digest
        )
      );
      const blankApplication = createApplication(
        blankRepository,
        blankContentStore,
        blankSecretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        blankProxyService
      );

      const blankSummary = await blankApplication.queryHomeProxySelection();

      expect(blankSummary === undefined).assertTrue();

      const missingRevision = buildRevision('active');
      const missingProfile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', missingRevision, 'secret-active');
      const missingRepository = new FakeProfileRepository([missingProfile], 'active');
      const missingContentStore = new FakeProfileContentStore();
      const missingSecretStore = new FakeSubscriptionSecretStore();
      missingSecretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const missingProxyService = new FakeProxyApplication();
      missingProxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult(['Primary'], 7, null, 'active', missingRevision.validatedAt, missingRevision.sha256Digest)
      );
      missingProxyService.queueQueryGroupResult(
        'Primary',
        buildProxyGroupQueryResult(
          'Primary',
          7,
          'Node Missing',
          [buildProxyNodeSelectionInput('Node A', true)],
          null,
          'active',
          missingRevision.validatedAt,
          missingRevision.sha256Digest
        )
      );
      const missingApplication = createApplication(
        missingRepository,
        missingContentStore,
        missingSecretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        missingProxyService
      );

      const missingSummary = await missingApplication.queryHomeProxySelection();

      expect(missingSummary === undefined).assertTrue();

      const falseSelectedRevision = buildRevision('active');
      const falseSelectedProfile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', falseSelectedRevision, 'secret-active');
      const falseSelectedRepository = new FakeProfileRepository([falseSelectedProfile], 'active');
      const falseSelectedContentStore = new FakeProfileContentStore();
      const falseSelectedSecretStore = new FakeSubscriptionSecretStore();
      falseSelectedSecretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const falseSelectedProxyService = new FakeProxyApplication();
      falseSelectedProxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult(['Primary'], 7, null, 'active', falseSelectedRevision.validatedAt, falseSelectedRevision.sha256Digest)
      );
      falseSelectedProxyService.queueQueryGroupResult(
        'Primary',
        buildProxyGroupQueryResult(
          'Primary',
          7,
          'Node A',
          [buildProxyNodeSelectionInput('Node A', false)],
          null,
          'active',
          falseSelectedRevision.validatedAt,
          falseSelectedRevision.sha256Digest
        )
      );
      const falseSelectedApplication = createApplication(
        falseSelectedRepository,
        falseSelectedContentStore,
        falseSelectedSecretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        falseSelectedProxyService
      );

      const falseSelectedSummary = await falseSelectedApplication.queryHomeProxySelection();

      expect(falseSelectedSummary === undefined).assertTrue();
    });

    it('profileApplicationQueryHomeProxySelectionReturnsUndefinedWhenAnotherNodeIsAlsoSelected', 0, async () => {
      const revision = buildRevision('active');
      const profile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', revision, 'secret-active');
      const repository = new FakeProfileRepository([profile], 'active');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const proxyService = new FakeProxyApplication();
      proxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult(['Primary'], 8, null, 'active', revision.validatedAt, revision.sha256Digest)
      );
      proxyService.queueQueryGroupResult(
        'Primary',
        buildProxyGroupQueryResult(
          'Primary',
          8,
          'Node A',
          [
            buildProxyNodeSelectionInput('Node A', true),
            buildProxyNodeSelectionInput('Node B', true)
          ],
          null,
          'active',
          revision.validatedAt,
          revision.sha256Digest
        )
      );
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        proxyService
      );

      const summary = await application.queryHomeProxySelection();

      expect(summary === undefined).assertTrue();
    });

    it('profileApplicationQueryHomeProxySelectionReturnsUndefinedWhenNestedSelectionFormsAncestorCycle', 0, async () => {
      const revision = buildRevision('active');
      const profile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', revision, 'secret-active');
      const repository = new FakeProfileRepository([profile], 'active');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const proxyService = new FakeProxyApplication();
      proxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult(['Primary'], 8, null, 'active', revision.validatedAt, revision.sha256Digest)
      );
      proxyService.queueQueryGroupResult(
        'Primary',
        buildProxyGroupQueryResult(
          'Primary',
          8,
          'Nested',
          [buildProxyNodeSelectionInput('Nested', true, true)],
          null,
          'active',
          revision.validatedAt,
          revision.sha256Digest
        )
      );
      proxyService.queueQueryGroupResult(
        'Nested',
        buildProxyGroupQueryResult(
          'Nested',
          8,
          'Primary',
          [buildProxyNodeSelectionInput('Primary', true, true)],
          null,
          'active',
          revision.validatedAt,
          revision.sha256Digest
        )
      );
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        proxyService
      );

      const summary = await application.queryHomeProxySelection();

      expect(summary === undefined).assertTrue();
      expect(proxyService.queryGroupRequests.length).assertEqual(2);
      expect(proxyService.queryGroupRequests[1].groupPath.join(',')).assertEqual('Primary,Nested');
    });

    it('profileApplicationQueryHomeProxySelectionReturnsUndefinedWhenNestedSelectionNeedsASeventeenthSegment', 0, async () => {
      const revision = buildRevision('active');
      const profile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', revision, 'secret-active');
      const repository = new FakeProfileRepository([profile], 'active');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const proxyService = new FakeProxyApplication();
      proxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult(['Primary'], 9, null, 'active', revision.validatedAt, revision.sha256Digest)
      );
      for (let index = 0; index < 16; index += 1) {
        const currentGroupName: string = index === 0 ? 'Primary' : `Nested${index}`;
        const nextGroupName: string = `Nested${index + 1}`;
        proxyService.queueQueryGroupResult(
          currentGroupName,
          buildProxyGroupQueryResult(
            currentGroupName,
            9,
            nextGroupName,
            [buildProxyNodeSelectionInput(nextGroupName, true, true)],
            null,
            'active',
            revision.validatedAt,
            revision.sha256Digest
          )
        );
      }
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        proxyService
      );

      const summary = await application.queryHomeProxySelection();

      expect(summary === undefined).assertTrue();
      expect(proxyService.queryGroupRequests.length).assertEqual(16);
      expect(proxyService.queryGroupRequests[15].groupName).assertEqual('Nested15');
      expect(proxyService.queryGroupRequests[15].groupPath.join(',')).assertEqual(
        'Primary,Nested1,Nested2,Nested3,Nested4,Nested5,Nested6,Nested7,Nested8,Nested9,Nested10,Nested11,Nested12,Nested13,Nested14,Nested15'
      );
    });

    it('profileApplicationQueryHomeProxySelectionReturnsUndefinedWhenProxyIdentityDriftsAcrossQueries', 0, async () => {
      const directRevision = buildRevision('active');
      const directProfile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', directRevision, 'secret-active');
      const directRepository = new FakeProfileRepository([directProfile], 'active');
      const directContentStore = new FakeProfileContentStore();
      const directSecretStore = new FakeSubscriptionSecretStore();
      directSecretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const directProxyService = new FakeProxyApplication();
      directProxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult(['Primary'], 10, null, 'active', directRevision.validatedAt, directRevision.sha256Digest)
      );
      directProxyService.queueQueryGroupResult(
        'Primary',
        buildProxyGroupQueryResult(
          'Primary',
          10,
          'Node A',
          [buildProxyNodeSelectionInput('Node A', true)],
          null,
          'active',
          directRevision.validatedAt,
          buildDigest('drifted-revision')
        )
      );
      const directApplication = createApplication(
        directRepository,
        directContentStore,
        directSecretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        directProxyService
      );

      const directSummary = await directApplication.queryHomeProxySelection();

      expect(directSummary === undefined).assertTrue();

      const nestedRevision = buildRevision('active');
      const nestedProfile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', nestedRevision, 'secret-active');
      const nestedRepository = new FakeProfileRepository([nestedProfile], 'active');
      const nestedContentStore = new FakeProfileContentStore();
      const nestedSecretStore = new FakeSubscriptionSecretStore();
      nestedSecretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const nestedProxyService = new FakeProxyApplication();
      nestedProxyService.queueListGroupsResult(
        buildProxyGroupListQueryResult(['Primary'], 10, null, 'active', nestedRevision.validatedAt, nestedRevision.sha256Digest)
      );
      nestedProxyService.queueQueryGroupResult(
        'Primary',
        buildProxyGroupQueryResult(
          'Primary',
          10,
          'Nested',
          [buildProxyNodeSelectionInput('Nested', true, true)],
          null,
          'active',
          nestedRevision.validatedAt,
          nestedRevision.sha256Digest
        )
      );
      nestedProxyService.queueQueryGroupResult(
        'Nested',
        buildProxyGroupQueryResult(
          'Nested',
          10,
          'Node B',
          [buildProxyNodeSelectionInput('Node B', true)],
          'other-session',
          'active',
          nestedRevision.validatedAt,
          nestedRevision.sha256Digest
        )
      );
      const nestedApplication = createApplication(
        nestedRepository,
        nestedContentStore,
        nestedSecretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        nestedProxyService
      );

      const nestedSummary = await nestedApplication.queryHomeProxySelection();

      expect(nestedSummary === undefined).assertTrue();
      expect(nestedProxyService.queryGroupRequests.length).assertEqual(2);
    });

    it('profileApplicationDelegatesDelayOperationsAndClonesDelaySnapshots', 0, async () => {
      const revision = buildRevision('active');
      const profile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', revision, 'secret-active');
      const repository = new FakeProfileRepository([profile], 'active');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const proxyService = new FakeProxyApplication();
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        undefined,
        undefined,
        undefined,
        proxyService
      );

      await application.initialize();
      const started = await application.startDelayTest('Selector', 2);
      const finished = await application.readDelayTest('delay-job-1');
      const cancelled = await application.cancelDelayTest('delay-job-1');
      const drained = await application.cancelAndDrainDelayTest();

      expect(proxyService.startDelayCalls.join(',')).assertEqual('Selector:2');
      expect(proxyService.readDelayCalls.join(',')).assertEqual('delay-job-1');
      expect(proxyService.cancelDelayCalls.join(',')).assertEqual('delay-job-1');
      expect(proxyService.cancelAndDrainCalls).assertEqual(1);
      expect(drained).assertUndefined();

      expect(started.kind).assertEqual('SNAPSHOT');
      expect(finished.kind).assertEqual('SNAPSHOT');
      expect(cancelled.kind).assertEqual('SNAPSHOT');
      if (finished.kind === 'SNAPSHOT') {
        finished.nodes[0].name = 'Mutated';
      }
      const currentFinished = await application.readDelayTest('delay-job-1');
      expect(currentFinished.kind).assertEqual('SNAPSHOT');
      if (currentFinished.kind === 'SNAPSHOT') {
        expect(currentFinished.nodes[0].name).assertEqual('Node A');
      }
    });

    it('profileApplicationRejectsOneClickWhileSharedRuntimeTransitionIsInFlightAndKeepsIdleSnapshotCloned', 0, async () => {
      const transitionStates: Array<'STARTING' | 'STOPPING'> = ['STARTING', 'STOPPING'];

      for (let index = 0; index < transitionStates.length; index += 1) {
        const transitionState: 'STARTING' | 'STOPPING' = transitionStates[index];
        const revision = buildRevision(`one-click-${transitionState.toLowerCase()}`);
        const profile = buildProfileRecord(
          `one-click-${transitionState.toLowerCase()}`,
          'VALID',
          'REMOTE_URL',
          revision,
          `secret-one-click-${transitionState.toLowerCase()}`
        );
        const repository = new FakeProfileRepository([profile], `one-click-${transitionState.toLowerCase()}`);
        const contentStore = new FakeProfileContentStore();
        const secretStore = new FakeSubscriptionSecretStore();
        secretStore.storedSecrets.set(
          `secret-one-click-${transitionState.toLowerCase()}`,
          `https://origin.example.com/one-click-${transitionState.toLowerCase()}.yaml`
        );
        const coreService = new FakeCoreService();
        const confirmation = new FakeOneClickVpnConfirmation();
        const vpnController = new FakeVpnController();
        const proxyService = new FakeProxyApplication();
        const runtimeCoordinator = createRuntimeCoordinator(
          repository,
          contentStore,
          coreService,
          [buildTimestamp(20), buildTimestamp(21), buildTimestamp(22), buildTimestamp(23)]
        );
        const application = createApplicationWithCoordinator(
          repository,
          contentStore,
          secretStore,
          coreService,
          runtimeCoordinator,
          undefined,
          vpnController,
          undefined,
          proxyService,
          confirmation
        );
        const observed: OneClickVpnOperationSnapshot[] = [];

        await application.initialize();
        const initialSnapshot: OneClickVpnOperationSnapshot = application.currentOneClickVpnOperation();
        const listener: OneClickVpnOperationListener = (snapshot: OneClickVpnOperationSnapshot): void => {
          observed.push(snapshot);
        };
        const subscriptionId: number = application.subscribeOneClickVpnOperation(listener);

        if (transitionState === 'STARTING') {
          coreService.startDeferred = new DeferredRuntimeSnapshot();
          const startPromise: Promise<LocalRuntimeStartResult> = runtimeCoordinator.start();
          await waitForCondition(() => coreService.startCalls.length === 1);
          const result: SelectNodeAndEnsureVpnResult = await application.selectNodeAndEnsureVpn('Selector', 'Node A', 2);
          coreService.startDeferred.resolve(buildRuntimeSnapshot('RUNNING'));
          await startPromise;

          expect(initialSnapshot.stage).assertEqual('IDLE');
          expect(initialSnapshot.busy).assertFalse();
          expect(initialSnapshot.outcome).assertEqual('NONE');
          initialSnapshot.stage = 'SWITCHING_VPN';
          expect(application.currentOneClickVpnOperation().stage).assertEqual('IDLE');
          expect(observed.length).assertEqual(1);
          expect(observed[0].stage).assertEqual('IDLE');
          expect(observed[0].busy).assertFalse();
          expect(observed[0].outcome).assertEqual('FAILED');
          expect(confirmation.armCalls.length).assertEqual(0);
          expect(proxyService.selectCalls.length).assertEqual(0);
          expect(vpnController.startCalls.length).assertEqual(0);
          assertOneClickFailure(result, 'ADMISSION', 'OPERATION_BUSY', 'proxies_one_click_busy', true, false);
          application.unsubscribeOneClickVpnOperation(subscriptionId);
          continue;
        }

        coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING');
        const startedRuntime: LocalRuntimeStartResult = await runtimeCoordinator.start();
        expect(startedRuntime.kind).assertEqual('STARTED');
        coreService.stopDeferred = new DeferredRuntimeSnapshot();
        const stopPromise: Promise<LocalRuntimeStopResult> = runtimeCoordinator.stop();
        await waitForCondition(() => coreService.stopCalls.length === 1);
        const result: SelectNodeAndEnsureVpnResult = await application.selectNodeAndEnsureVpn('Selector', 'Node A', 2);
        coreService.stopDeferred.resolve(buildRuntimeSnapshot('STOPPED'));
        await stopPromise;

        expect(initialSnapshot.stage).assertEqual('IDLE');
        expect(initialSnapshot.busy).assertFalse();
        expect(initialSnapshot.outcome).assertEqual('NONE');
        initialSnapshot.stage = 'SWITCHING_VPN';
        expect(application.currentOneClickVpnOperation().stage).assertEqual('IDLE');
        expect(observed.length).assertEqual(1);
        expect(observed[0].stage).assertEqual('IDLE');
        expect(observed[0].busy).assertFalse();
        expect(observed[0].outcome).assertEqual('FAILED');
        expect(confirmation.armCalls.length).assertEqual(0);
        expect(proxyService.selectCalls.length).assertEqual(0);
        expect(vpnController.startCalls.length).assertEqual(0);
        assertOneClickFailure(result, 'ADMISSION', 'OPERATION_BUSY', 'proxies_one_click_busy', true, false);
        application.unsubscribeOneClickVpnOperation(subscriptionId);
      }
    });

    it('profileApplicationStartsVpnAfterPersistedSelectionPublishesProgressAndBlocksConcurrentMutations', 0, async () => {
      const sharedLog: string[] = [];
      const revision = buildRevision('one-click-flow');
      const profile = buildProfileRecord('one-click-flow', 'VALID', 'REMOTE_URL', revision, 'secret-one-click-flow');
      const repository = new FakeProfileRepository([profile], 'one-click-flow');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-one-click-flow', 'https://origin.example.com/one-click-flow.yaml');
      const coreService = new FakeCoreService();
      const proxyService = new FakeProxyApplication();
      proxyService.sharedLog = sharedLog;
      proxyService.queueSelectResult(
        createProxySelectionSavedForNextStartResult(
          createProxySelectionRecord('one-click-flow', 'Selector', 'Node B', revision.validatedAt, buildTimestamp(31)),
          buildTimestamp(32)
        )
      );
      proxyService.queueQueryGroupResult(
        'Selector',
        buildProxyGroupQueryResult(
          'Selector',
          3,
          'Node B',
          [
            buildProxyNodeSelectionInput('Node A', false),
            buildProxyNodeSelectionInput('Node B', true)
          ],
          'vpn-session-flow',
          'one-click-flow',
          revision.validatedAt
        )
      );
      const vpnController = new FakeVpnController();
      vpnController.sharedLog = sharedLog;
      vpnController.queueStartResult({
        kind: 'STARTED',
        snapshot: buildVpnSnapshot('STARTING', 'vpn-session-flow', 'one-click-flow', revision.validatedAt)
      });
      const confirmation = new FakeOneClickVpnConfirmation();
      confirmation.sharedLog = sharedLog;
      const confirmationHandle = new FakeOneClickVpnConfirmationHandle();
      confirmation.queueHandle(confirmationHandle);
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        coreService,
        undefined,
        vpnController,
        new FakeIdGenerator(['flow']),
        proxyService,
        confirmation
      );
      const observed: OneClickVpnOperationSnapshot[] = [];

      await application.initialize();
      application.subscribeOneClickVpnOperation((snapshot: OneClickVpnOperationSnapshot): void => {
        observed.push(snapshot);
      });

      const resultPromise: Promise<SelectNodeAndEnsureVpnResult> = application.selectNodeAndEnsureVpn('Selector', 'Node B', 2);
      await waitForCondition(() => confirmationHandle.waitCalls === 1);

      const duplicateTapResult: SelectNodeAndEnsureVpnResult = await application.selectNodeAndEnsureVpn('Selector', 'Node B', 2);
      const blockedStartVpn = await application.startVpnGlobalCapture();
      const blockedStopVpn = await application.stopVpnGlobalCapture();

      assertOneClickFailure(duplicateTapResult, 'ADMISSION', 'OPERATION_BUSY', 'proxies_one_click_busy', true, false);
      expect(blockedStartVpn.kind).assertEqual('REJECTED');
      expect(blockedStopVpn.kind).assertEqual('FAILED');
      expect(vpnController.startCalls.length).assertEqual(1);
      expect(vpnController.stopCalls.length).assertEqual(0);

      confirmationHandle.resolve('RUNNING');
      const result: SelectNodeAndEnsureVpnResult = await resultPromise;
      const releasedStopVpnResult: VpnControllerStopResult = await application.stopVpnGlobalCapture();

      expect(result.kind).assertEqual('VPN_STARTED');
      expect(proxyService.selectCalls.join(',')).assertEqual('Selector:Node B:2');
      expect(proxyService.queryGroupCalls.join(',')).assertEqual('Selector');
      expect(confirmation.armCalls[0].startsWith('vpn-session-flow:')).assertTrue();
      expect(confirmationHandle.markStartAcceptedCalls).assertEqual(1);
      expect(confirmationHandle.cancelCalls).assertEqual(1);
      expect(releasedStopVpnResult.kind).assertEqual('STOPPED');
      expect(vpnController.stopCalls.length).assertEqual(1);
      expect(sharedLog.join('>')).assertContain(
        `proxy.select:Selector:Node B:2>confirm.arm:vpn-session-flow>vpn.start:one-click-flow:${revision.validatedAt}:vpn-session-flow>confirm.accepted>proxy.query:Selector>confirm.cancel`
      );
      const progressSequence: string = observed.map((snapshot) => `${snapshot.stage}:${snapshot.busy}:${snapshot.outcome}`).join('>');
      expect(progressSequence).assertEqual(
        'SAVING_SELECTION:true:NONE>STARTING_VPN:true:NONE>CONFIRMING_SELECTION:true:NONE>IDLE:false:SUCCEEDED'
      );
      observed[0].stage = 'IDLE';
      expect(application.currentOneClickVpnOperation().stage).assertEqual('IDLE');
      expect(application.currentOneClickVpnOperation().outcome).assertEqual('SUCCEEDED');
    });

    it('profileApplicationIgnoresThrowingOneClickListenersAndStillCompletesFlow', 0, async () => {
      const revision = buildRevision('one-click-listener-safe');
      const profile = buildProfileRecord('one-click-listener-safe', 'VALID', 'REMOTE_URL', revision, 'secret-one-click-listener-safe');
      const repository = new FakeProfileRepository([profile], 'one-click-listener-safe');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-one-click-listener-safe', 'https://origin.example.com/one-click-listener-safe.yaml');
      const proxyService = new FakeProxyApplication();
      proxyService.queueSelectResult(
        createProxySelectionSavedForNextStartResult(
          createProxySelectionRecord('one-click-listener-safe', 'Selector', 'Node B', revision.validatedAt, buildTimestamp(51)),
          buildTimestamp(52)
        )
      );
      proxyService.queueQueryGroupResult(
        'Selector',
        buildProxyGroupQueryResult(
          'Selector',
          3,
          'Node B',
          [
            buildProxyNodeSelectionInput('Node A', false),
            buildProxyNodeSelectionInput('Node B', true)
          ],
          'vpn-session-listener-safe',
          'one-click-listener-safe',
          revision.validatedAt
        )
      );
      const vpnController = new FakeVpnController();
      vpnController.queueStartResult({
        kind: 'STARTED',
        snapshot: buildVpnSnapshot('STARTING', 'vpn-session-listener-safe', 'one-click-listener-safe', revision.validatedAt)
      });
      const confirmation = new FakeOneClickVpnConfirmation();
      confirmation.queueHandle(new FakeOneClickVpnConfirmationHandle('RUNNING'));
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        undefined,
        vpnController,
        new FakeIdGenerator(['listener-safe']),
        proxyService,
        confirmation
      );
      const observed: OneClickVpnOperationSnapshot[] = [];

      await application.initialize();
      application.subscribeOneClickVpnOperation((_snapshot: OneClickVpnOperationSnapshot): void => {
        throw new Error('listener exploded');
      });
      application.subscribeOneClickVpnOperation((snapshot: OneClickVpnOperationSnapshot): void => {
        observed.push(snapshot);
      });

      const result: SelectNodeAndEnsureVpnResult = await application.selectNodeAndEnsureVpn('Selector', 'Node B', 2);

      expect(result.kind).assertEqual('VPN_STARTED');
      expect(observed[observed.length - 1].stage).assertEqual('IDLE');
      expect(observed[observed.length - 1].outcome).assertEqual('SUCCEEDED');
    });

    it('profileApplicationStartsVpnFromRunningSharedRuntimeWithDirectSelectionStartAndConfirmationProgress', 0, async () => {
      const sharedLog: string[] = [];
      const revision = buildRevision('one-click-running');
      const profile = buildProfileRecord('one-click-running', 'VALID', 'REMOTE_URL', revision, 'secret-one-click-running');
      const repository = new FakeProfileRepository([profile], 'one-click-running');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-one-click-running', 'https://origin.example.com/one-click-running.yaml');
      const coreService = new FakeCoreService();
      coreService.sharedLog = sharedLog;
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING');
      const proxyService = new FakeProxyApplication();
      proxyService.sharedLog = sharedLog;
      proxyService.queueSelectResult(
        createProxySelectionSavedForNextStartResult(
          createProxySelectionRecord('one-click-running', 'Selector', 'Node B', revision.validatedAt, buildTimestamp(33)),
          buildTimestamp(34)
        )
      );
      proxyService.queueQueryGroupResult(
        'Selector',
        buildProxyGroupQueryResult(
          'Selector',
          6,
          'Node B',
          [
            buildProxyNodeSelectionInput('Node A', false),
            buildProxyNodeSelectionInput('Node B', true)
          ],
          'vpn-session-refresh',
          'one-click-running',
          revision.validatedAt
        )
      );
      const vpnController = new FakeVpnController();
      vpnController.sharedLog = sharedLog;
      vpnController.queueStartResult({
        kind: 'STARTED',
        snapshot: buildVpnSnapshot('STARTING', 'vpn-session-refresh', 'one-click-running', revision.validatedAt)
      });
      const confirmation = new FakeOneClickVpnConfirmation();
      confirmation.sharedLog = sharedLog;
      confirmation.queueHandle(new FakeOneClickVpnConfirmationHandle('RUNNING'));
      const runtimeCoordinator = createRuntimeCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(20), buildTimestamp(21), buildTimestamp(22), buildTimestamp(23)]
      );
      const application = createApplicationWithCoordinator(
        repository,
        contentStore,
        secretStore,
        coreService,
        runtimeCoordinator,
        undefined,
        vpnController,
        new FakeIdGenerator(['refresh']),
        proxyService,
        confirmation
      );
      const observed: OneClickVpnOperationSnapshot[] = [];

      await application.initialize();
      application.subscribeOneClickVpnOperation((snapshot: OneClickVpnOperationSnapshot): void => {
        observed.push(snapshot);
      });
      const startedRuntime: LocalRuntimeStartResult = await runtimeCoordinator.start();
      expect(startedRuntime.kind).assertEqual('STARTED');

      const result: SelectNodeAndEnsureVpnResult = await application.selectNodeAndEnsureVpn('Selector', 'Node B', 2);

      expect(result.kind).assertEqual('VPN_STARTED');
      expect(proxyService.selectCalls.join(',')).assertEqual('Selector:Node B:2');
      expect(coreService.stopCalls.length).assertEqual(0);
      expect(observed.map((snapshot: OneClickVpnOperationSnapshot) => `${snapshot.stage}:${snapshot.busy}:${snapshot.outcome}`).join('>')).assertEqual(
        'SAVING_SELECTION:true:NONE>STARTING_VPN:true:NONE>CONFIRMING_SELECTION:true:NONE>IDLE:false:SUCCEEDED'
      );
      const combinedLog: string = sharedLog.join('>');
      expect(combinedLog.includes('core.stopRuntime')).assertFalse();
      expect(combinedLog).assertContain('proxy.select:Selector:Node B:2');
      expect(combinedLog).assertContain(
        `confirm.arm:vpn-session-refresh>vpn.start:one-click-running:${revision.validatedAt}:vpn-session-refresh>confirm.accepted>proxy.query:Selector>confirm.cancel`
      );
    });

    it('profileApplicationHotSwitchesRunningVpnAndDetectsAlreadyActiveSelection', 0, async () => {
      const revision = buildRevision('vpn-live');
      const profile = buildProfileRecord('vpn-live', 'VALID', 'REMOTE_URL', revision, 'secret-vpn-live');
      const repository = new FakeProfileRepository([profile], 'vpn-live');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-vpn-live', 'https://origin.example.com/vpn-live.yaml');
      const proxyService = new FakeProxyApplication();
      proxyService.queueQueryGroupResult(
        'Selector',
        buildProxyGroupQueryResult(
          'Selector',
          7,
          'Node A',
          [
            buildProxyNodeSelectionInput('Node A', true),
            buildProxyNodeSelectionInput('Node B', false)
          ],
          'vpn-session-live',
          'vpn-live',
          revision.validatedAt
        )
      );
      proxyService.queueQueryGroupResult(
        'Selector',
        buildProxyGroupQueryResult(
          'Selector',
          8,
          'Node A',
          [
            buildProxyNodeSelectionInput('Node A', true),
            buildProxyNodeSelectionInput('Node B', false)
          ],
          'vpn-session-live',
          'vpn-live',
          revision.validatedAt
        )
      );
      proxyService.queueSelectResult(
        createProxySelectionAppliedNowResult(
          buildProxyGroupSnapshotValue(
            'Selector',
            8,
            'Node B',
            [
              buildProxyNodeSelectionInput('Node A', false),
              buildProxyNodeSelectionInput('Node B', true)
            ],
            'vpn-session-live',
            'vpn-live',
            revision.validatedAt
          ),
          createProxySelectionRecord('vpn-live', 'Selector', 'Node B', revision.validatedAt, buildTimestamp(35)),
          buildTimestamp(36)
        )
      );
      const vpnController = new FakeVpnController();
      vpnController.setSnapshot(buildVpnSnapshot('RUNNING', 'vpn-session-live', 'vpn-live', revision.validatedAt));
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        undefined,
        vpnController,
        new FakeIdGenerator(['live']),
        proxyService,
        new FakeOneClickVpnConfirmation()
      );

      await application.initialize();

      const alreadyActiveResult: SelectNodeAndEnsureVpnResult = await application.selectNodeAndEnsureVpn('Selector', 'Node A', 7);
      const hotSwitchResult: SelectNodeAndEnsureVpnResult = await application.selectNodeAndEnsureVpn('Selector', 'Node B', 7);

      expect(alreadyActiveResult.kind).assertEqual('ALREADY_ACTIVE');
      expect(hotSwitchResult.kind).assertEqual('APPLIED_TO_RUNNING_VPN');
      expect(proxyService.selectCalls.join(',')).assertEqual('Selector:Node B:7');
      expect(vpnController.startCalls.length).assertEqual(0);
      expect(vpnController.stopCalls.length).assertEqual(0);
    });

    it('profileApplicationMapsRunningVpnPreQueryRejectedWithoutSessionChangeToSelectionFailure', 0, async () => {
      const revision = buildRevision('vpn-live-query-fail');
      const profile = buildProfileRecord('vpn-live-query-fail', 'VALID', 'REMOTE_URL', revision, 'secret-vpn-live-query-fail');
      const repository = new FakeProfileRepository([profile], 'vpn-live-query-fail');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-vpn-live-query-fail', 'https://origin.example.com/vpn-live-query-fail.yaml');
      const proxyService = new FakeProxyApplication();
      proxyService.queueQueryGroupResult(
        'Selector',
        createProxyRejectedResult(createProxyRejectedError('PROXY_QUERY_FAILED', true, buildTimestamp(53)))
      );
      const vpnController = new FakeVpnController();
      vpnController.setSnapshot(buildVpnSnapshot('RUNNING', 'vpn-session-live-query-fail', 'vpn-live-query-fail', revision.validatedAt));
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        undefined,
        vpnController,
        new FakeIdGenerator(['live-query-fail']),
        proxyService,
        new FakeOneClickVpnConfirmation()
      );

      await application.initialize();
      const result: SelectNodeAndEnsureVpnResult = await application.selectNodeAndEnsureVpn('Selector', 'Node B', 7);

      assertOneClickFailure(
        result,
        'SELECTION',
        'PROXY_SELECTION_FAILED',
        'proxies_error_selection_failed',
        true,
        false
      );
    });

    it('profileApplicationMapsRunningVpnAppliedNotPersistedToSuccessWarningAndSettlesProgress', 0, async () => {
      const revision = buildRevision('vpn-live-not-persisted');
      const profile = buildProfileRecord('vpn-live-not-persisted', 'VALID', 'REMOTE_URL', revision, 'secret-vpn-live-not-persisted');
      const repository = new FakeProfileRepository([profile], 'vpn-live-not-persisted');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-vpn-live-not-persisted', 'https://origin.example.com/vpn-live-not-persisted.yaml');
      const proxyService = new FakeProxyApplication();
      proxyService.queueQueryGroupResult(
        'Selector',
        buildProxyGroupQueryResult(
          'Selector',
          10,
          'Node A',
          [
            buildProxyNodeSelectionInput('Node A', true),
            buildProxyNodeSelectionInput('Node B', false)
          ],
          'vpn-session-live-not-persisted',
          'vpn-live-not-persisted',
          revision.validatedAt
        )
      );
      proxyService.queueSelectResult(
        createProxySelectionAppliedNotPersistedResult(
          buildProxyGroupSnapshotValue(
            'Selector',
            10,
            'Node B',
            [
              buildProxyNodeSelectionInput('Node A', false),
              buildProxyNodeSelectionInput('Node B', true)
            ],
            'vpn-session-live-not-persisted',
            'vpn-live-not-persisted',
            revision.validatedAt
          ),
          createProxySelectionRecord('vpn-live-not-persisted', 'Selector', 'Node B', revision.validatedAt, buildTimestamp(46)),
          createProxyRejectedError('PROXY_PERSISTENCE_FAILED', true, buildTimestamp(47)),
          buildTimestamp(48)
        )
      );
      const vpnController = new FakeVpnController();
      vpnController.setSnapshot(
        buildVpnSnapshot('RUNNING', 'vpn-session-live-not-persisted', 'vpn-live-not-persisted', revision.validatedAt)
      );
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        new FakeCoreService(),
        undefined,
        vpnController,
        new FakeIdGenerator(['live-not-persisted']),
        proxyService,
        new FakeOneClickVpnConfirmation()
      );
      const observed: OneClickVpnOperationSnapshot[] = [];

      await application.initialize();
      application.subscribeOneClickVpnOperation((snapshot: OneClickVpnOperationSnapshot): void => {
        observed.push(snapshot);
      });

      const result: SelectNodeAndEnsureVpnResult = await application.selectNodeAndEnsureVpn('Selector', 'Node B', 10);

      expect(result.kind).assertEqual('APPLIED_TO_RUNNING_VPN_NOT_PERSISTED');
      expect(vpnController.startCalls.length).assertEqual(0);
      expect(vpnController.stopCalls.length).assertEqual(0);
      expect(observed.map((snapshot) => `${snapshot.stage}:${snapshot.busy}:${snapshot.outcome}`).join('>')).assertEqual(
        'SWITCHING_VPN:true:NONE>IDLE:false:SUCCEEDED'
      );
    });

    it('profileApplicationMapsOneClickFailuresAcrossStopSelectionAndConfirmationStages', 0, async () => {
      const persistenceRevision = buildRevision('persist-fail');
      const persistenceProfile = buildProfileRecord('persist-fail', 'VALID', 'REMOTE_URL', persistenceRevision, 'secret-persist-fail');
      const persistenceRepository = new FakeProfileRepository([persistenceProfile], 'persist-fail');
      const persistenceContentStore = new FakeProfileContentStore();
      const persistenceSecretStore = new FakeSubscriptionSecretStore();
      persistenceSecretStore.storedSecrets.set('secret-persist-fail', 'https://origin.example.com/persist-fail.yaml');
      const persistenceProxyService = new FakeProxyApplication();
      persistenceProxyService.queueSelectResult(
        createProxySelectionAppliedNotPersistedResult(
          buildProxyGroupSnapshotValue(
            'Selector',
            2,
            'Node B',
            [
              buildProxyNodeSelectionInput('Node A', false),
              buildProxyNodeSelectionInput('Node B', true)
            ],
            'vpn-session-persist',
            'persist-fail',
            persistenceRevision.validatedAt
          ),
          createProxySelectionRecord('persist-fail', 'Selector', 'Node B', persistenceRevision.validatedAt, buildTimestamp(37)),
          createProxyRejectedError('PROXY_PERSISTENCE_FAILED', true, buildTimestamp(38)),
          buildTimestamp(39)
        )
      );
      const persistenceApplication = createApplication(
        persistenceRepository,
        persistenceContentStore,
        persistenceSecretStore,
        new FakeCoreService(),
        undefined,
        new FakeVpnController(),
        new FakeIdGenerator(['persist']),
        persistenceProxyService,
        new FakeOneClickVpnConfirmation()
      );

      await persistenceApplication.initialize();
      const persistenceResult = await persistenceApplication.selectNodeAndEnsureVpn('Selector', 'Node B', 2);
      assertOneClickFailure(
        persistenceResult,
        'SELECTION',
        'PROXY_PERSISTENCE_FAILED',
        'proxies_error_persistence_failed',
        true,
        false
      );

      const confirmationRevision = buildRevision('confirm-stop');
      const confirmationProfile = buildProfileRecord('confirm-stop', 'VALID', 'REMOTE_URL', confirmationRevision, 'secret-confirm-stop');
      const confirmationRepository = new FakeProfileRepository([confirmationProfile], 'confirm-stop');
      const confirmationContentStore = new FakeProfileContentStore();
      const confirmationSecretStore = new FakeSubscriptionSecretStore();
      confirmationSecretStore.storedSecrets.set('secret-confirm-stop', 'https://origin.example.com/confirm-stop.yaml');
      const confirmationProxyService = new FakeProxyApplication();
      confirmationProxyService.queueSelectResult(
        createProxySelectionSavedForNextStartResult(
          createProxySelectionRecord('confirm-stop', 'Selector', 'Node B', confirmationRevision.validatedAt, buildTimestamp(40)),
          buildTimestamp(41)
        )
      );
      const confirmationController = new FakeVpnController();
      confirmationController.queueStartResult({
        kind: 'STARTED',
        snapshot: buildVpnSnapshot('STARTING', 'vpn-session-stop', 'confirm-stop', confirmationRevision.validatedAt)
      });
      const confirmation = new FakeOneClickVpnConfirmation();
      const stoppedHandle = new FakeOneClickVpnConfirmationHandle('STOPPED');
      confirmation.queueHandle(stoppedHandle);
      const confirmationApplication = createApplication(
        confirmationRepository,
        confirmationContentStore,
        confirmationSecretStore,
        new FakeCoreService(),
        undefined,
        confirmationController,
        new FakeIdGenerator(['confirm-stop']),
        confirmationProxyService,
        confirmation
      );

      await confirmationApplication.initialize();
      const stoppedBeforeRunningResult = await confirmationApplication.selectNodeAndEnsureVpn('Selector', 'Node B', 2);
      assertOneClickFailure(
        stoppedBeforeRunningResult,
        'VPN_START',
        'VPN_STOPPED_BEFORE_RUNNING',
        'error_vpn_start_failed',
        true,
        true
      );

      const assertSavedVpnStartFailedOutcome = async (
        caseId: string,
        configureController: (controller: FakeVpnController, revisionId: string) => void
      ): Promise<void> => {
        const savedStartRevision = buildRevision(caseId);
        const savedStartProfile = buildProfileRecord(caseId, 'VALID', 'REMOTE_URL', savedStartRevision, `secret-${caseId}`);
        const savedStartRepository = new FakeProfileRepository([savedStartProfile], caseId);
        const savedStartContentStore = new FakeProfileContentStore();
        const savedStartSecretStore = new FakeSubscriptionSecretStore();
        savedStartSecretStore.storedSecrets.set(`secret-${caseId}`, `https://origin.example.com/${caseId}.yaml`);
        const savedStartProxyService = new FakeProxyApplication();
        savedStartProxyService.queueSelectResult(
          createProxySelectionSavedForNextStartResult(
            createProxySelectionRecord(caseId, 'Selector', 'Node B', savedStartRevision.validatedAt, buildTimestamp(49)),
            buildTimestamp(50)
          )
        );
        const savedStartController = new FakeVpnController();
        configureController(savedStartController, savedStartRevision.validatedAt);
        const savedStartConfirmation = new FakeOneClickVpnConfirmation();
        const savedStartHandle = new FakeOneClickVpnConfirmationHandle();
        savedStartConfirmation.queueHandle(savedStartHandle);
        const savedStartApplication = createApplication(
          savedStartRepository,
          savedStartContentStore,
          savedStartSecretStore,
          new FakeCoreService(),
          undefined,
          savedStartController,
          new FakeIdGenerator([caseId]),
          savedStartProxyService,
          savedStartConfirmation
        );
        const savedStartObserved: OneClickVpnOperationSnapshot[] = [];

        await savedStartApplication.initialize();
        savedStartApplication.subscribeOneClickVpnOperation((snapshot: OneClickVpnOperationSnapshot): void => {
          savedStartObserved.push(snapshot);
        });

        const savedStartResult = await savedStartApplication.selectNodeAndEnsureVpn('Selector', 'Node B', 2);

        expect(savedStartResult.kind).assertEqual('SAVED_VPN_START_FAILED');
        expect(savedStartHandle.markStartAcceptedCalls).assertEqual(0);
        expect(savedStartHandle.waitCalls).assertEqual(0);
        expect(savedStartHandle.cancelCalls).assertEqual(1);
        expect(savedStartObserved.map((snapshot) => `${snapshot.stage}:${snapshot.busy}:${snapshot.outcome}`).join('>')).assertEqual(
          'SAVING_SELECTION:true:NONE>STARTING_VPN:true:NONE>IDLE:false:FAILED'
        );
      };

      await assertSavedVpnStartFailedOutcome('saved-vpn-start-failed-rejected', (controller: FakeVpnController, revisionId: string): void => {
        controller.queueStartResult({
          kind: 'REJECTED',
          snapshot: buildVpnSnapshot('STOPPED', null, 'saved-vpn-start-failed-rejected', revisionId),
          failure: createVpnFailure('VPN_CREATE_FAILED', 'platform rejected')
        });
      });

      await assertSavedVpnStartFailedOutcome('saved-vpn-start-failed-failed', (controller: FakeVpnController, revisionId: string): void => {
        controller.queueStartResult({
          kind: 'FAILED',
          snapshot: buildVpnSnapshot('ERROR', null, 'saved-vpn-start-failed-failed', revisionId, createVpnFailure('VPN_CREATE_FAILED', 'platform failed')),
          failure: createVpnFailure('VPN_CREATE_FAILED', 'platform failed')
        });
      });

      await assertSavedVpnStartFailedOutcome('saved-vpn-start-failed-throw', (controller: FakeVpnController, _revisionId: string): void => {
        controller.startError = new Error('start threw');
      });

      const assertSavedVpnStartFailedFromConfirmationException = async (
        caseId: string,
        configureHandle: (handle: FakeOneClickVpnConfirmationHandle) => void,
        configureConfirmation?: (confirmation: FakeOneClickVpnConfirmation) => void
      ): Promise<void> => {
        const revision = buildRevision(caseId);
        const profile = buildProfileRecord(caseId, 'VALID', 'REMOTE_URL', revision, `secret-${caseId}`);
        const repository = new FakeProfileRepository([profile], caseId);
        const contentStore = new FakeProfileContentStore();
        const secretStore = new FakeSubscriptionSecretStore();
        secretStore.storedSecrets.set(`secret-${caseId}`, `https://origin.example.com/${caseId}.yaml`);
        const proxyService = new FakeProxyApplication();
        proxyService.queueSelectResult(
          createProxySelectionSavedForNextStartResult(
            createProxySelectionRecord(caseId, 'Selector', 'Node B', revision.validatedAt, buildTimestamp(54)),
            buildTimestamp(55)
          )
        );
        const controller = new FakeVpnController();
        controller.queueStartResult({
          kind: 'STARTED',
          snapshot: buildVpnSnapshot('STARTING', `vpn-session-${caseId}`, caseId, revision.validatedAt)
        });
        const confirmation = new FakeOneClickVpnConfirmation();
        const handle = new FakeOneClickVpnConfirmationHandle();
        configureHandle(handle);
        confirmation.queueHandle(handle);
        configureConfirmation?.(confirmation);
        const application = createApplication(
          repository,
          contentStore,
          secretStore,
          new FakeCoreService(),
          undefined,
          controller,
          new FakeIdGenerator([caseId]),
          proxyService,
          confirmation
        );
        const observed: OneClickVpnOperationSnapshot[] = [];

        await application.initialize();
        application.subscribeOneClickVpnOperation((snapshot: OneClickVpnOperationSnapshot): void => {
          observed.push(snapshot);
        });

        const result = await application.selectNodeAndEnsureVpn('Selector', 'Node B', 2);
        const releasedStopVpnResult: VpnControllerStopResult = await application.stopVpnGlobalCapture();

        expect(result.kind).assertEqual('SAVED_VPN_START_FAILED');
        expect(observed[observed.length - 1].stage).assertEqual('IDLE');
        expect(observed[observed.length - 1].outcome).assertEqual('FAILED');
        expect(releasedStopVpnResult.kind).assertEqual('STOPPED');
      };

      await assertSavedVpnStartFailedFromConfirmationException(
        'saved-vpn-start-failed-arm-throw',
        (_handle: FakeOneClickVpnConfirmationHandle): void => {
        },
        (confirmation: FakeOneClickVpnConfirmation): void => {
          confirmation.armError = new Error('arm exploded');
        }
      );

      await assertSavedVpnStartFailedFromConfirmationException(
        'saved-vpn-start-failed-mark-throw',
        (handle: FakeOneClickVpnConfirmationHandle): void => {
          handle.markError = new Error('mark exploded');
        }
      );

      await assertSavedVpnStartFailedFromConfirmationException(
        'saved-vpn-start-failed-wait-reject',
        (handle: FakeOneClickVpnConfirmationHandle): void => {
          handle.waitError = new Error('wait exploded');
        }
      );

      const timeoutRevision = buildRevision('confirm-timeout');
      const timeoutProfile = buildProfileRecord('confirm-timeout', 'VALID', 'REMOTE_URL', timeoutRevision, 'secret-confirm-timeout');
      const timeoutRepository = new FakeProfileRepository([timeoutProfile], 'confirm-timeout');
      const timeoutContentStore = new FakeProfileContentStore();
      const timeoutSecretStore = new FakeSubscriptionSecretStore();
      timeoutSecretStore.storedSecrets.set('secret-confirm-timeout', 'https://origin.example.com/confirm-timeout.yaml');
      const timeoutProxyService = new FakeProxyApplication();
      timeoutProxyService.queueSelectResult(
        createProxySelectionSavedForNextStartResult(
          createProxySelectionRecord('confirm-timeout', 'Selector', 'Node B', timeoutRevision.validatedAt, buildTimestamp(42)),
          buildTimestamp(43)
        )
      );
      const timeoutController = new FakeVpnController();
      timeoutController.queueStartResult({
        kind: 'STARTED',
        snapshot: buildVpnSnapshot('STARTING', 'vpn-session-timeout', 'confirm-timeout', timeoutRevision.validatedAt)
      });
      const timeoutConfirmation = new FakeOneClickVpnConfirmation();
      timeoutConfirmation.queueHandle(new FakeOneClickVpnConfirmationHandle('TIMEOUT'));
      const timeoutApplication = createApplication(
        timeoutRepository,
        timeoutContentStore,
        timeoutSecretStore,
        new FakeCoreService(),
        undefined,
        timeoutController,
        new FakeIdGenerator(['confirm-timeout']),
        timeoutProxyService,
        timeoutConfirmation
      );

      await timeoutApplication.initialize();
      const timeoutResult = await timeoutApplication.selectNodeAndEnsureVpn('Selector', 'Node B', 2);
      assertOneClickFailure(
        timeoutResult,
        'VPN_CONFIRMATION',
        'VPN_CONFIRMATION_TIMEOUT',
        'proxies_one_click_confirmation_timeout',
        true,
        true
      );

      const postQueryFailRevision = buildRevision('confirm-query-fail');
      const postQueryFailProfile = buildProfileRecord('confirm-query-fail', 'VALID', 'REMOTE_URL', postQueryFailRevision, 'secret-confirm-query-fail');
      const postQueryFailRepository = new FakeProfileRepository([postQueryFailProfile], 'confirm-query-fail');
      const postQueryFailContentStore = new FakeProfileContentStore();
      const postQueryFailSecretStore = new FakeSubscriptionSecretStore();
      postQueryFailSecretStore.storedSecrets.set('secret-confirm-query-fail', 'https://origin.example.com/confirm-query-fail.yaml');
      const postQueryFailProxyService = new FakeProxyApplication();
      postQueryFailProxyService.queueSelectResult(
        createProxySelectionSavedForNextStartResult(
          createProxySelectionRecord('confirm-query-fail', 'Selector', 'Node B', postQueryFailRevision.validatedAt, buildTimestamp(56)),
          buildTimestamp(57)
        )
      );
      postQueryFailProxyService.queueQueryGroupResult(
        'Selector',
        createProxyRejectedResult(createProxyRejectedError('PROXY_QUERY_FAILED', true, buildTimestamp(58)))
      );
      const postQueryFailController = new FakeVpnController();
      postQueryFailController.queueStartResult({
        kind: 'STARTED',
        snapshot: buildVpnSnapshot('STARTING', 'vpn-session-confirm-query-fail', 'confirm-query-fail', postQueryFailRevision.validatedAt)
      });
      const postQueryFailConfirmation = new FakeOneClickVpnConfirmation();
      postQueryFailConfirmation.queueHandle(new FakeOneClickVpnConfirmationHandle('RUNNING'));
      const postQueryFailApplication = createApplication(
        postQueryFailRepository,
        postQueryFailContentStore,
        postQueryFailSecretStore,
        new FakeCoreService(),
        undefined,
        postQueryFailController,
        new FakeIdGenerator(['confirm-query-fail']),
        postQueryFailProxyService,
        postQueryFailConfirmation
      );

      await postQueryFailApplication.initialize();
      const postQueryFailResult = await postQueryFailApplication.selectNodeAndEnsureVpn('Selector', 'Node B', 2);
      assertOneClickFailure(
        postQueryFailResult,
        'SELECTION',
        'PROXY_SELECTION_FAILED',
        'proxies_error_selection_failed',
        true,
        false
      );

      const permissionRevision = buildRevision('confirm-permission');
      const permissionProfile = buildProfileRecord('confirm-permission', 'VALID', 'REMOTE_URL', permissionRevision, 'secret-confirm-permission');
      const permissionRepository = new FakeProfileRepository([permissionProfile], 'confirm-permission');
      const permissionContentStore = new FakeProfileContentStore();
      const permissionSecretStore = new FakeSubscriptionSecretStore();
      permissionSecretStore.storedSecrets.set('secret-confirm-permission', 'https://origin.example.com/confirm-permission.yaml');
      const permissionProxyService = new FakeProxyApplication();
      permissionProxyService.queueSelectResult(
        createProxySelectionSavedForNextStartResult(
          createProxySelectionRecord('confirm-permission', 'Selector', 'Node B', permissionRevision.validatedAt, buildTimestamp(44)),
          buildTimestamp(45)
        )
      );
      const permissionController = new FakeVpnController();
      permissionController.queueStartResult({
        kind: 'STARTED',
        snapshot: buildVpnSnapshot('STARTING', 'vpn-session-permission', 'confirm-permission', permissionRevision.validatedAt)
      });
      const permissionConfirmation = new FakeOneClickVpnConfirmation();
      const permissionHandle = new FakeOneClickVpnConfirmationHandle();
      permissionConfirmation.queueHandle(permissionHandle);
      const permissionApplication = createApplication(
        permissionRepository,
        permissionContentStore,
        permissionSecretStore,
        new FakeCoreService(),
        undefined,
        permissionController,
        new FakeIdGenerator(['confirm-permission']),
        permissionProxyService,
        permissionConfirmation
      );

      await permissionApplication.initialize();
      const permissionResultPromise = permissionApplication.selectNodeAndEnsureVpn('Selector', 'Node B', 2);
      await waitForCondition(() => permissionHandle.waitCalls === 1);
      permissionController.setSnapshot(
        buildVpnSnapshot(
          'ERROR',
          'vpn-session-permission',
          'confirm-permission',
          permissionRevision.validatedAt,
          createVpnFailure('VPN_PERMISSION_DENIED', 'permission denied')
        )
      );
      permissionHandle.resolve('ERROR');
      const permissionResult = await permissionResultPromise;
      assertOneClickFailure(
        permissionResult,
        'VPN_START',
        'VPN_PERMISSION_DENIED',
        'error_vpn_permission_denied',
        true,
        true
      );
    });

    it('profileApplicationDrainsDelayBeforeRefreshLocalRuntimeVpnAndReconcileMutations', 0, async () => {
      const sharedLog: string[] = [];
      const revision = buildRevision('active');
      const profile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', revision, 'secret-active');
      const repository = new FakeProfileRepository([profile], 'active');
      repository.sharedLog = sharedLog;
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const sourceGateway = new FakeSourceGateway();
      sourceGateway.sharedLog = sharedLog;
      const coreService = new FakeCoreService();
      coreService.sharedLog = sharedLog;
      const vpnController = new FakeVpnController();
      vpnController.sharedLog = sharedLog;
      const proxyService = new FakeProxyApplication();
      proxyService.sharedLog = sharedLog;
      const leasePort = new FakeProfileRefreshLeasePort();
      leasePort.sharedLog = sharedLog;
      const runtimeCoordinator = createRuntimeCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(20), buildTimestamp(21), buildTimestamp(22), buildTimestamp(23)]
      );
      const application = createApplicationWithCoordinator(
        repository,
        contentStore,
        secretStore,
        coreService,
        runtimeCoordinator,
        sourceGateway,
        vpnController,
        new FakeIdGenerator(['vpn-session-1']),
        proxyService,
        undefined,
        leasePort
      );

      await application.initialize();
      await application.refresh('active');
      await application.replaceSubscriptionUrl('active', 'https://next.example.com/subscription.yaml');
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING');
      await runtimeCoordinator.start();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('STOPPED');
      await runtimeCoordinator.stop();
      await application.startVpnGlobalCapture();
      await application.stopVpnGlobalCapture();
      await application.reconcileActiveSelections();

      const combined: string = sharedLog.join('>');
      expect(leasePort.tryAcquireCallCount).assertEqual(1);
      expect(combined).assertContain('proxy.drain>repository.get:active>lease.tryAcquire:active>source.acquireRemote:Profile active');
      expect(combined).assertContain('proxy.drain>repository.get:active>source.acquireRemote:Profile active');
      expect(combined).assertContain('proxy.drain>repository.get:active');
      expect(combined).assertContain(
        'repository.getActiveId>repository.get:active>core.validate:/sandbox/profiles/active.yaml>core.load:/sandbox/profiles/active.yaml>core.startLocal:/sandbox/profiles/active.yaml:7890'
      );
      expect(combined).assertContain('core.runtimeSnapshot>core.stopRuntime');
      expect(combined).assertContain('proxy.drain>vpn.stop:current');
      expect(combined).assertContain('proxy.drain>proxy.reconcile');
    });

    it('profileApplicationMapsDelayDrainFailureToRetryableSafeFailuresWithoutTouchingCollaborators', 0, async () => {
      const revision = buildRevision('active');
      const profile = buildProfileRecord('active', 'VALID', 'REMOTE_URL', revision, 'secret-active');
      const repository = new FakeProfileRepository([profile], 'active');
      const contentStore = new FakeProfileContentStore();
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-active', 'https://origin.example.com/active.yaml');
      const coreService = new FakeCoreService();
      const vpnController = new FakeVpnController();
      const proxyService = new FakeProxyApplication();
      proxyService.drainResult = createProxyRejectedResult(
        createProxyRejectedError('PROXY_DELAY_DRAIN_FAILED', true, buildTimestamp(41))
      );
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        coreService,
        undefined,
        vpnController,
        new FakeIdGenerator(['vpn-session-2']),
        proxyService
      );

      await application.initialize();

      const enableResult = await application.enable('active');
      const startVpnResult = await application.startVpnGlobalCapture();
      const reconcileResult = await application.reconcileActiveSelections();

      expect(enableResult.kind).assertEqual('FAILED');
      if (enableResult.kind === 'FAILED') {
        expect(enableResult.error.code).assertEqual('CMFA_PROXY_DELAY_DRAIN_FAILED');
        expect(enableResult.error.retryable).assertTrue();
      }
      expect(startVpnResult.kind).assertEqual('REJECTED');
      if (startVpnResult.kind === 'REJECTED') {
        expect(startVpnResult.failure.detail.includes('active')).assertFalse();
        expect(startVpnResult.failure.detail.includes('delay-job')).assertFalse();
      }
      expect(reconcileResult.kind).assertEqual('REJECTED');
      if (reconcileResult.kind === 'REJECTED') {
        expect(reconcileResult.error.code).assertEqual('PROXY_DELAY_DRAIN_FAILED');
        expect(reconcileResult.error.retryable).assertTrue();
      }
      expect(repository.log.join('>')).assertEqual('repository.list>repository.list>repository.getActiveId');
      expect(coreService.startCalls.length).assertEqual(0);
      expect(vpnController.startCalls.length).assertEqual(0);
      expect(proxyService.reconcileCalls).assertEqual(0);
    });
  });
}
