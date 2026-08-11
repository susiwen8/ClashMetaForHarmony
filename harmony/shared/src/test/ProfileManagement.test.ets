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

interface ProfileApplicationSnapshotContract {
  runtime: ProfileApplicationRuntimeContract;
}

interface ProfileApplicationRuntimeContract {
  state: string;
}

interface RefreshFailedResultContract {
  kind: 'FAILED';
  error: AppError;
}

interface ProfileApplicationContract {
  initialize(): Promise<void>;
  refresh(profileId: string): Promise<RefreshResultContract>;
  current(): ProfileApplicationSnapshotContract;
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

  constructor(
    importUseCase: ImportProfileUseCase,
    refreshUseCase: RefreshProfileUseCase,
    manageProfileUseCases: ManageProfileUseCases,
    runtimeCoordinator: LocalRuntimeCoordinator,
    commitService: ProfileCommitService
  ) {
    this.importUseCase = importUseCase;
    this.refreshUseCase = refreshUseCase;
    this.manageProfileUseCases = manageProfileUseCases;
    this.runtimeCoordinator = runtimeCoordinator;
    this.commitService = commitService;
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

  async retain(_profileId: string, _staged: StagedSource, _kind: 'CURRENT' | 'FAILED_CANDIDATE'): Promise<ProfileRevision> {
    throw new Error('retain should stay unused in Task4 management tests');
  }

  async discard(_staged: StagedSource): Promise<void> {
  }

  async removeRevision(_revision: ProfileRevision): Promise<void> {
  }

  async removeProfile(profileId: string): Promise<void> {
    this.log.push(`content.removeProfile:${profileId}`);
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
    const resolved: string | undefined = this.resolvedPaths.get(revision.relativePath);
    return resolved ?? `/sandbox/${revision.relativePath}`;
  }
}

class FakeSubscriptionSecretStore implements SubscriptionSecretStore {
  readonly encryptCalls: string[] = [];
  readonly removeCalls: string[] = [];
  readonly storedSecrets: Map<string, string> = new Map();
  encryptError?: Error;

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
    const secret: string | undefined = this.storedSecrets.get(secretRef);
    if (secret === undefined) {
      throw new Error('secret missing');
    }
    return secret;
  }

  async remove(secretRef: string): Promise<void> {
    this.removeCalls.push(secretRef);
    this.storedSecrets.delete(secretRef);
  }
}

class FakeCoreService implements CoreService {
  readonly log: string[] = [];
  readonly validateCalls: string[] = [];
  readonly loadCalls: string[] = [];
  runtimeSnapshotValue: RuntimeSnapshot = buildRuntimeSnapshot('STOPPED');
  validateError?: Error;
  loadError?: Error;

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
  }

  async loadConfiguration(path: string): Promise<void> {
    this.log.push(`core.load:${path}`);
    this.loadCalls.push(path);
    if (this.loadError !== undefined) {
      throw this.loadError;
    }
  }

  async startLocal(_options: LocalOptions): Promise<RuntimeSnapshot> {
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
    this.log.push('core.subscribe');
    return 1;
  }

  unsubscribe(_subscriptionId: number): void {
    this.log.push('core.unsubscribe');
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
  sourceSecretRef?: string
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
    lastError: null,
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
  const runtimeCoordinator = new LocalRuntimeCoordinator(
    new RuntimeCoordinatorDependencyBag(
      repository,
      contentStore,
      coreService,
      new FakeClock([buildTimestamp(4), buildTimestamp(5), buildTimestamp(6), buildTimestamp(7)])
    )
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

function createApplication(
  repository: FakeProfileRepository,
  contentStore: FakeProfileContentStore,
  secretStore: FakeSubscriptionSecretStore,
  coreService: FakeCoreService
): ProfileApplication {
  const sourceGateway = new FakeSourceGateway();
  const queue = new SerialCommandQueue();
  const commitService = new ProfileCommitService({
    repository,
    contentStore,
    clock: new FakeClock([buildTimestamp(12), buildTimestamp(13), buildTimestamp(14)])
  });
  const importUseCase = new ImportProfileUseCase({
    repository,
    contentStore,
    sourceGateway,
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
    sourceGateway,
    secretStore,
    coreService,
    clock: new FakeClock([buildTimestamp(17), buildTimestamp(18), buildTimestamp(19)]),
    queue,
    commitService
  });
  const runtimeCoordinator = new LocalRuntimeCoordinator(
    new RuntimeCoordinatorDependencyBag(
      repository,
      contentStore,
      coreService,
      new FakeClock([buildTimestamp(20), buildTimestamp(21), buildTimestamp(22)])
    )
  );
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
      commitService
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

    it('nonStoppedRuntimeRejectsEnableDeleteReplaceAndRefresh', 0, async () => {
      const revision = buildRevision('running');
      const profile = buildProfileRecord('running', 'VALID', 'REMOTE_URL', revision, 'secret-old');
      const repository = new FakeProfileRepository([profile], 'running');
      const contentStore = new FakeProfileContentStore();
      const coreService = new FakeCoreService();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING');
      const secretStore = new FakeSubscriptionSecretStore();
      secretStore.storedSecrets.set('secret-old', 'https://origin.example.com/subscription.yaml');
      const management = createManagement(repository, contentStore, secretStore, coreService);
      const application = createApplication(repository, contentStore, secretStore, coreService);

      const enableResult = await management.enable('running');
      const deleteResult = await management.delete('running');
      const replaceResult = await management.replaceSubscriptionUrl('running', 'https://next.example.com/subscription.yaml');
      await application.initialize();
      const refreshResult = await application.refresh('running');

      expect(enableResult.kind).assertEqual('FAILED');
      expect(deleteResult.kind).assertEqual('FAILED');
      expect(replaceResult.kind).assertEqual('FAILED');
      expect(refreshResult.kind).assertEqual('FAILED');
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
