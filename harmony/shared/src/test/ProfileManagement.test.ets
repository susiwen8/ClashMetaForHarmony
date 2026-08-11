import { describe, expect, it } from '@ohos/hypium';
import {
  createAppError,
  createProfile,
  createProfileRevision,
  ImportProfileUseCase,
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
  SerialCommandQueue,
  type AppError,
  type Clock,
  type CoreEvent,
  type CoreService,
  type IdGenerator,
  type LocalAcquireCommand,
  type LocalOptions,
  type LocalProfileAcquisition,
  type LocalProfileAcquisitionCancelled,
  type Profile,
  type ProfileContentStore,
  type ProfileRepository,
  type ProfileRevision,
  type ProfileSourceGateway,
  type RemoteAcquireCommand,
  type RemoteProfileAcquisition,
  type RemoteProfileAcquisitionFailure,
  type RuntimeSnapshot,
  type StagedSource,
  type SubscriptionSecretStore
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

type ManageEnableResultContract = ManageEnabledResultContract | ManageFailedResultContract;
type ManageDeleteResultContract = ManageDeletedResultContract | ManageFailedResultContract;
type ManageReplaceResultContract = ManageReplacedResultContract | ManageFailedResultContract;

interface ManageProfileUseCasesContract {
  enable(profileId: string): Promise<ManageEnableResultContract>;
  delete(profileId: string): Promise<ManageDeleteResultContract>;
  replaceSubscriptionUrl(profileId: string, sourceUrl: string): Promise<ManageReplaceResultContract>;
}

interface RefreshFailedResultContract {
  kind: 'FAILED';
  error: AppError;
}

interface RefreshResultContract {
  kind: string;
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
  readonly manageProfileUseCases: ManageProfileUseCases;
  readonly runtimeCoordinator: LocalRuntimeCoordinator;
  readonly commitService: ProfileCommitService;
  readonly repository: FakeProfileRepository;

  constructor(
    importUseCase: ImportProfileUseCase,
    refreshUseCase: RefreshProfileUseCase,
    manageProfileUseCases: ManageProfileUseCases,
    runtimeCoordinator: LocalRuntimeCoordinator,
    commitService: ProfileCommitService,
    repository: FakeProfileRepository
  ) {
    this.importUseCase = importUseCase;
    this.refreshUseCase = refreshUseCase;
    this.manageProfileUseCases = manageProfileUseCases;
    this.runtimeCoordinator = runtimeCoordinator;
    this.commitService = commitService;
    this.repository = repository;
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

  async acquireLocal(command: LocalAcquireCommand): Promise<LocalProfileAcquisition> {
    this.localCommands.push(command);
    return new CancelledLocalAcquisition();
  }

  async acquireRemote(command: RemoteAcquireCommand): Promise<RemoteProfileAcquisition> {
    this.remoteCommands.push(command);
    return new RemoteFailureAcquisition(
      createAppError('DOWNLOAD', 'remote gateway should stay unused in this test', {
        timestamp: buildTimestamp(59),
        retryable: false
      }),
      command.profileName,
      command.sourceDisplay
    );
  }
}

class FakeProfileRepository implements ProfileRepository {
  readonly log: string[] = [];
  readonly savedProfiles: Profile[] = [];
  readonly deletedIds: string[] = [];
  readonly setActiveIdCalls: (string | undefined)[] = [];
  private readonly profiles: Map<string, Profile> = new Map();
  private activeIdValue: string | undefined;
  saveError?: Error;
  deleteError?: Error;
  getError?: Error;
  setActiveIdError?: Error;

  constructor(seedProfiles: Profile[], activeId?: string) {
    for (let index = 0; index < seedProfiles.length; index += 1) {
      this.profiles.set(seedProfiles[index].id, cloneProfile(seedProfiles[index]));
    }
    this.activeIdValue = activeId;
  }

  async list(): Promise<Profile[]> {
    this.log.push('repository.list');
    const profiles: Profile[] = [];
    this.profiles.forEach((profile) => {
      profiles.push(cloneProfile(profile));
    });
    return profiles;
  }

  async get(id: string): Promise<Profile | undefined> {
    this.log.push(`repository.get:${id}`);
    if (this.getError !== undefined) {
      throw this.getError;
    }
    const profile: Profile | undefined = this.profiles.get(id);
    return profile === undefined ? undefined : cloneProfile(profile);
  }

  async save(profile: Profile): Promise<void> {
    this.log.push(`repository.save:${profile.id}`);
    if (this.saveError !== undefined) {
      throw this.saveError;
    }
    this.profiles.set(profile.id, cloneProfile(profile));
    this.savedProfiles.push(cloneProfile(profile));
  }

  async deleteAndClearActive(id: string): Promise<void> {
    this.log.push(`repository.deleteAndClearActive:${id}`);
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
    return this.activeIdValue;
  }

  async setActiveId(id: string | undefined): Promise<void> {
    this.log.push(`repository.setActiveId:${id ?? 'undefined'}`);
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
}

class FakeProfileContentStore implements ProfileContentStore {
  readonly log: string[] = [];
  readonly resolvedPaths: Map<string, string> = new Map();
  readonly removedProfiles: string[] = [];
  readonly reconciledPaths: string[][] = [];
  resolveError?: Error;
  removeProfileError?: Error;

  async retain(_profileId: string, _staged: StagedSource, _kind: 'CURRENT' | 'FAILED_CANDIDATE'): Promise<ProfileRevision> {
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
}

class FakeSubscriptionSecretStore implements SubscriptionSecretStore {
  readonly encryptCalls: string[] = [];
  readonly removeCalls: string[] = [];
  readonly storedSecrets: Map<string, string> = new Map();
  encryptError?: Error;
  removeError?: Error;
  removeErrorSecretRef?: string;

  async encrypt(plaintext: string): Promise<string> {
    this.encryptCalls.push(plaintext);
    if (this.encryptError !== undefined) {
      throw this.encryptError;
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

class FakeCoreService implements CoreService {
  readonly log: string[] = [];
  readonly validateCalls: string[] = [];
  readonly loadCalls: string[] = [];
  readonly startCalls: LocalOptions[] = [];
  readonly subscribeIds: number[] = [];
  readonly callbacks: Map<number, (event: CoreEvent) => void> = new Map();
  runtimeSnapshotValue: RuntimeSnapshot = buildRuntimeSnapshot('STOPPED');
  validateError?: Error;
  loadError?: Error;
  startDeferred?: DeferredRuntimeSnapshot;
  validateDeferred?: DeferredVoid;
  validateEntered?: DeferredVoid;
  private nextSubscriptionId: number = 1;

  hello(): string {
    return 'hello';
  }

  async coreVersion(): Promise<string> {
    return 'core';
  }

  async validateConfiguration(path: string): Promise<void> {
    this.log.push(`core.validate:${path}`);
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
    this.loadCalls.push(path);
    if (this.loadError !== undefined) {
      throw this.loadError;
    }
  }

  async startLocal(options: LocalOptions): Promise<RuntimeSnapshot> {
    this.log.push(`core.startLocal:${options.configPath}:${options.mixedPort}`);
    this.startCalls.push(options);
    if (this.startDeferred !== undefined) {
      return await this.startDeferred.promise;
    }
    return cloneRuntimeSnapshot(this.runtimeSnapshotValue);
  }

  async stopRuntime(): Promise<RuntimeSnapshot> {
    return cloneRuntimeSnapshot(this.runtimeSnapshotValue);
  }

  runtimeSnapshot(): RuntimeSnapshot {
    this.log.push('core.runtimeSnapshot');
    return cloneRuntimeSnapshot(this.runtimeSnapshotValue);
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

function buildTimestamp(minute: number): string {
  const minuteText: string = `${minute}`.padStart(2, '0');
  return `2026-08-11T12:${minuteText}:00.000Z`;
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

function buildProfileRecord(
  id: string,
  availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID',
  sourceKind: 'LOCAL_FILE' | 'REMOTE_URL',
  currentRevision: ProfileRevision | null,
  sourceSecretRef?: string,
  lastError: AppError | null = null
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
    lastSuccessfulUpdateAt: currentRevision === null ? null : buildTimestamp(3)
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
    lastSuccessfulUpdateAt: profile.lastSuccessfulUpdateAt
  });
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
  sourceGateway?: FakeSourceGateway
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
    sourceGateway
  );
}

function createApplicationWithCoordinator(
  repository: FakeProfileRepository,
  contentStore: FakeProfileContentStore,
  secretStore: FakeSubscriptionSecretStore,
  coreService: FakeCoreService,
  runtimeCoordinator: LocalRuntimeCoordinator,
  sourceGateway?: FakeSourceGateway
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
  const refreshUseCase = new RefreshProfileUseCase({
    repository,
    contentStore,
    sourceGateway: gateway,
    secretStore,
    coreService,
    clock: new FakeClock([buildTimestamp(17), buildTimestamp(18), buildTimestamp(19)]),
    queue,
    commitService
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
      manageProfileUseCases,
      runtimeCoordinator,
      commitService,
      repository
    )
  );
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
      const startPromise = application.startLocal();
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
      const beta = buildProfileRecord('beta', 'UPDATE_FAILED_USING_VALID', 'REMOTE_URL', betaRevision, 'secret-beta');
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
      expect(serialized.includes('sourceSecretRef')).assertFalse();
      expect(serialized.includes('/sandbox/profiles')).assertFalse();
      expect(serialized.includes('https://origin.example.com/subscription.yaml')).assertFalse();
      expect(serialized.includes('profiles/alpha.yaml')).assertFalse();
      expect(serialized.includes('technicalDetail')).assertFalse();
    });

    it('applicationCurrentPublishesSafeSourceKindRepairFlagAndRedactedProfileError', 0, async () => {
      const revision = buildRevision('repair');
      const repairError = createAppError('PERSISTENCE', 'decrypt https://repair.example.com/path?token=secret failed near /private/cache', {
        code: 'SOURCE_DECRYPT_FAILED',
        retryable: false,
        timestamp: buildTimestamp(4)
      });
      const repair = buildProfileRecord('repair', 'INVALID', 'REMOTE_URL', null, 'secret-repair', repairError);
      const local = buildProfileRecord('local', 'VALID', 'LOCAL_FILE', revision);
      const repository = new FakeProfileRepository([local, repair], 'local');
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
      const serialized = JSON.stringify(repairSnapshot);

      expect(repairSnapshot.sourceKind).assertEqual('REMOTE_URL');
      expect(repairSnapshot.sourceRepairRequired).assertTrue();
      expect(repairSnapshot.lastError?.code).assertEqual('SOURCE_DECRYPT_FAILED');
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
      const application = createApplication(
        repository,
        contentStore,
        secretStore,
        coreService
      );
      const observed: ProfileApplicationSnapshot[] = [];

      await application.initialize();
      const subscriptionId = application.subscribe((snapshot: ProfileApplicationSnapshot): void => {
        observed.push(snapshot);
      });

      await application.enable('remote');
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING');
      await application.startLocal();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('STOPPED');
      await application.stopLocal();
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
  });
}
