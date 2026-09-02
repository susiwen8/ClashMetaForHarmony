import { describe, expect, it } from '@ohos/hypium';
import type {
  Clock,
  IdGenerator,
  LeasedRemoteProfileRefresher,
  ImportProfileUseCaseDependencies as PortImportProfileUseCaseDependencies,
  LocalAcquireCommand as PortLocalAcquireCommand,
  Profile,
  ProfileCommitServiceDependencies as PortProfileCommitServiceDependencies,
  ProfileContentStore,
  ProfileRefreshLeasePort,
  ProfileRepository,
  ProfileSourceGateway,
  RefreshProfileCommand as PortRefreshProfileCommand,
  RefreshProfileUseCaseDependencies as PortRefreshProfileUseCaseDependencies,
  RemoteImportCommand as PortRemoteImportCommand,
  SubscriptionSecretStore
} from '../../Index';
import {
  LeasedRemoteProfileRefresher as ProductionLeasedRemoteProfileRefresher,
  SerialCommandQueue,
  ProfileCommitService,
  ImportProfileUseCase,
  RefreshProfileUseCase,
  createProfile
} from '../../Index';
import {
  AcquiredLocalSource,
  AcquiredRemoteSource,
  CancelledLocalSource,
  Deferred,
  FailedLocalSource,
  FailedRemoteSource,
  FakeClock,
  FakeCoreService,
  FakeIdGenerator,
  FakeOperationTimeline,
  FakeProfileContentStore,
  FakeProfileRepository,
  FakeProfileSourceGateway,
  FakeSubscriptionSecretStore,
  FixtureClock,
  FixtureIdGenerator,
  FixtureProfileContentStore,
  FixtureProfileRepository,
  FixtureProfileSourceGateway,
  FixtureSubscriptionSecretStore,
  ProfileFixtureOptions,
  ScriptedStringFailure,
  ScriptedVoidFailure,
  buildAppError,
  buildJsonStateSnapshot,
  buildCoreError,
  buildProfile,
  buildRevision,
  buildSecretError,
  buildStagedSource,
  createDeferred
} from './fakes/ProfileFakes';

class LocalImportCommand implements PortLocalAcquireCommand {
  preferredName?: string;

  constructor(preferredName?: string) {
    this.preferredName = preferredName;
  }
}

class RemoteImportArgs implements PortRemoteImportCommand {
  readonly sourceUrl: string;
  readonly name: string;
  readonly allowPlainHttp: boolean;

  constructor(sourceUrl: string, name: string, allowPlainHttp: boolean) {
    this.sourceUrl = sourceUrl;
    this.name = name;
    this.allowPlainHttp = allowPlainHttp;
  }
}

class RefreshCommand implements PortRefreshProfileCommand {
  readonly profileId: string;
  readonly allowPlainHttp?: boolean;

  constructor(profileId: string, allowPlainHttp?: boolean) {
    this.profileId = profileId;
    this.allowPlainHttp = allowPlainHttp;
  }
}

class ImportUseCaseDependencies implements PortImportProfileUseCaseDependencies {
  readonly repository: ProfileRepository;
  readonly contentStore: ProfileContentStore;
  readonly sourceGateway: ProfileSourceGateway;
  readonly secretStore: SubscriptionSecretStore;
  readonly coreService: FakeCoreService;
  readonly clock: Clock;
  readonly idGenerator: IdGenerator;
  readonly queue: SerialCommandQueue;
  readonly commitService: ProfileCommitService;

  constructor(
    repository: ProfileRepository,
    contentStore: ProfileContentStore,
    sourceGateway: ProfileSourceGateway,
    secretStore: SubscriptionSecretStore,
    coreService: FakeCoreService,
    clock: Clock,
    idGenerator: IdGenerator,
    queue: SerialCommandQueue,
    commitService: ProfileCommitService
  ) {
    this.repository = repository;
    this.contentStore = contentStore;
    this.sourceGateway = sourceGateway;
    this.secretStore = secretStore;
    this.coreService = coreService;
    this.clock = clock;
    this.idGenerator = idGenerator;
    this.queue = queue;
    this.commitService = commitService;
  }
}

class RefreshUseCaseDependencies implements PortRefreshProfileUseCaseDependencies {
  readonly repository: ProfileRepository;
  readonly contentStore: ProfileContentStore;
  readonly sourceGateway: ProfileSourceGateway;
  readonly secretStore: SubscriptionSecretStore;
  readonly coreService: FakeCoreService;
  readonly clock: Clock;
  readonly queue: SerialCommandQueue;
  readonly commitService: ProfileCommitService;
  readonly leasedRemoteRefresher: LeasedRemoteProfileRefresher;

  constructor(
    repository: ProfileRepository,
    contentStore: ProfileContentStore,
    sourceGateway: ProfileSourceGateway,
    secretStore: SubscriptionSecretStore,
    coreService: FakeCoreService,
    clock: Clock,
    queue: SerialCommandQueue,
    commitService: ProfileCommitService,
    leasedRemoteRefresher: LeasedRemoteProfileRefresher
  ) {
    this.repository = repository;
    this.contentStore = contentStore;
    this.sourceGateway = sourceGateway;
    this.secretStore = secretStore;
    this.coreService = coreService;
    this.clock = clock;
    this.queue = queue;
    this.commitService = commitService;
    this.leasedRemoteRefresher = leasedRemoteRefresher;
  }
}

class LeaseAcquireCall {
  readonly profileId: string;
  readonly ownerToken: string;
  readonly nowMs: number;
  readonly expiresAtMs: number;

  constructor(profileId: string, ownerToken: string, nowMs: number, expiresAtMs: number) {
    this.profileId = profileId;
    this.ownerToken = ownerToken;
    this.nowMs = nowMs;
    this.expiresAtMs = expiresAtMs;
  }
}

class LeaseReleaseCall {
  readonly profileId: string;
  readonly ownerToken: string;

  constructor(profileId: string, ownerToken: string) {
    this.profileId = profileId;
    this.ownerToken = ownerToken;
  }
}

class FakeProfileRefreshLeasePort implements ProfileRefreshLeasePort {
  readonly tryAcquireCalls: LeaseAcquireCall[] = [];
  readonly releaseCalls: LeaseReleaseCall[] = [];
  tryAcquireResult: boolean = true;
  releaseResult: boolean = true;
  tryAcquireError?: Error;
  releaseError?: Error;
  private readonly timeline?: FakeOperationTimeline;

  constructor(timeline?: FakeOperationTimeline) {
    this.timeline = timeline;
  }

  async tryAcquire(profileId: string, ownerToken: string, nowMs: number, expiresAtMs: number): Promise<boolean> {
    this.timeline?.record('leaseTryAcquire');
    this.tryAcquireCalls.push(new LeaseAcquireCall(profileId, ownerToken, nowMs, expiresAtMs));
    if (this.tryAcquireError !== undefined) {
      throw this.tryAcquireError;
    }
    return this.tryAcquireResult;
  }

  async renew(_profileId: string, _ownerToken: string, _nowMs: number, _expiresAtMs: number): Promise<boolean> {
    return true;
  }

  async release(profileId: string, ownerToken: string): Promise<boolean> {
    this.timeline?.record('leaseRelease');
    this.releaseCalls.push(new LeaseReleaseCall(profileId, ownerToken));
    if (this.releaseError !== undefined) {
      throw this.releaseError;
    }
    return this.releaseResult;
  }
}

class CommitServiceDependencies implements PortProfileCommitServiceDependencies {
  readonly repository: ProfileRepository;
  readonly contentStore: ProfileContentStore;
  readonly clock: Clock;

  constructor(repository: ProfileRepository, contentStore: ProfileContentStore, clock: Clock) {
    this.repository = repository;
    this.contentStore = contentStore;
    this.clock = clock;
  }
}

function collapseTimeline(entries: string[]): string {
  const collapsed: string[] = [];
  for (let index = 0; index < entries.length; index += 1) {
    const current: string = entries[index];
    if (current === 'removeRevision') {
      if (collapsed[collapsed.length - 1] !== 'removeSuperseded') {
        collapsed.push('removeSuperseded');
      }
      continue;
    }
    collapsed.push(current);
  }
  return collapsed.join('>');
}

function assertNoPlaintextLeak(snapshot: string, forbiddenFragments: string[]): void {
  for (let index = 0; index < forbiddenFragments.length; index += 1) {
    expect(snapshot.includes(forbiddenFragments[index])).assertFalse();
  }
}

function buildRemoteStateSnapshot(
  gateway: FakeProfileSourceGateway,
  secretStore: FakeSubscriptionSecretStore,
  repository?: FakeProfileRepository
): string {
  const parts: Object[] = [
    gateway.remoteCommands,
    secretStore.decryptCalls,
    secretStore.storedRefs,
    secretStore.removedRefs
  ];
  if (repository !== undefined) {
    parts.push(repository.savedProfiles);
  }
  return buildJsonStateSnapshot(parts);
}

function cloneProfileWithInterval(profile: Profile): Profile {
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

function buildProfileWithInterval(options: ProfileFixtureOptions, autoUpdateIntervalMs: number): Profile {
  return createProfile({
    id: options.id ?? 'profile-1',
    name: options.name ?? 'Profile 1',
    sourceKind: options.sourceKind ?? 'LOCAL_FILE',
    sourceDisplay: options.sourceDisplay ?? 'profile.yaml',
    sourceSecretRef: options.sourceSecretRef,
    currentRevision: options.currentRevision ?? null,
    failedCandidate: options.failedCandidate ?? null,
    availability: options.availability ?? 'INVALID',
    lastError: options.lastError ?? null,
    createdAt: options.createdAt ?? '2026-08-07T00:00:00.000Z',
    updatedAt: options.updatedAt ?? '2026-08-07T00:00:00.000Z',
    lastSuccessfulUpdateAt: options.lastSuccessfulUpdateAt ?? null,
    autoUpdateIntervalMs
  });
}

class IntervalPreservingProfileRepository implements ProfileRepository {
  readonly savedProfiles: Profile[] = [];
  readonly scriptedGetResults: (Profile | undefined)[] = [];
  private readonly profiles: Map<string, Profile> = new Map<string, Profile>();
  private activeIdValue: string | undefined;
  private readonly timeline?: FakeOperationTimeline;

  constructor(initialProfiles: Profile[], activeId?: string, timeline?: FakeOperationTimeline) {
    for (let index = 0; index < initialProfiles.length; index += 1) {
      const profile: Profile = initialProfiles[index];
      this.profiles.set(profile.id, cloneProfileWithInterval(profile));
    }
    this.activeIdValue = activeId;
    this.timeline = timeline;
  }

  async list(): Promise<Profile[]> {
    const result: Profile[] = [];
    for (const profile of this.profiles.values()) {
      result.push(cloneProfileWithInterval(profile));
    }
    return result;
  }

  async get(id: string): Promise<Profile | undefined> {
    this.timeline?.record('getProfile');
    if (this.scriptedGetResults.length > 0) {
      const scripted: Profile | undefined = this.scriptedGetResults.shift();
      return scripted === undefined ? undefined : cloneProfileWithInterval(scripted);
    }
    const profile: Profile | undefined = this.profiles.get(id);
    return profile === undefined ? undefined : cloneProfileWithInterval(profile);
  }

  async save(profile: Profile): Promise<void> {
    this.timeline?.record('saveProfile');
    this.savedProfiles.push(cloneProfileWithInterval(profile));
    this.profiles.set(profile.id, cloneProfileWithInterval(profile));
  }

  async deleteAndClearActive(id: string): Promise<void> {
    this.profiles.delete(id);
    if (this.activeIdValue === id) {
      this.activeIdValue = undefined;
    }
  }

  async getActiveId(): Promise<string | undefined> {
    return this.activeIdValue;
  }

  async setActiveId(id: string | undefined): Promise<void> {
    this.activeIdValue = id;
  }
}

export default function profileImportUseCasesTestsuite() {
  describe('ProfileImportUseCasesTest', () => {
    it('importsValidLocalProfileInTransactionalOrder', 0, async () => {
      const timeline = new FakeOperationTimeline();
      const repository = new FakeProfileRepository(undefined, undefined, timeline);
      const contentStore = new FakeProfileContentStore(timeline);
      const gateway = new FakeProfileSourceGateway(timeline);
      const coreService = new FakeCoreService(timeline);
      const clock = new FakeClock(['2026-08-07T00:00:00.000Z', '2026-08-07T00:01:00.000Z']);
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(timeline),
        coreService,
        clock,
        new FakeIdGenerator(['profile-local-1']),
        createQueue()
      );

      gateway.localResults.push(new AcquiredLocalSource('Home', 'home.yaml', buildStagedSource('local-home', '/sandbox/cache/local-home.yaml')));

      const result = await useCase.executeLocal(new LocalImportCommand());

      expect(result.kind).assertEqual('CREATED');
      if (result.kind !== 'CREATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.availability).assertEqual('VALID');
      expect(result.profile.currentRevision !== null).assertTrue();
      expect(result.profile.failedCandidate === null).assertTrue();
      expect(result.profile.sourceDisplay).assertEqual('home.yaml');
      expect(result.profile.lastSuccessfulUpdateAt).assertEqual('2026-08-07T00:01:00.000Z');
      expect(result.profile.autoUpdateIntervalMs).assertEqual(0);
      expect(collapseTimeline(timeline.entries)).assertEqual('acquire>validate>retainRevision>saveProfile');
    });

    it('retainsInvalidLocalImportAsInvalidProfile', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const coreService = new FakeCoreService();
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(),
        coreService,
        new FakeClock(['2026-08-07T00:00:00.000Z', '2026-08-07T00:01:00.000Z']),
        new FakeIdGenerator(['profile-local-invalid']),
        createQueue()
      );

      gateway.localResults.push(new AcquiredLocalSource(
        'Broken Local',
        'broken.yaml',
        buildStagedSource('local-invalid', '/sandbox/cache/broken.yaml')
      ));
      coreService.scriptedResults.push(new ScriptedVoidFailure(true, buildCoreError('CMFA_INVALID_ARGUMENT', 'parse token=secret failed', false)));

      const result = await useCase.executeLocal(new LocalImportCommand());

      expect(result.kind).assertEqual('CREATED');
      if (result.kind !== 'CREATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.availability).assertEqual('INVALID');
      expect(result.profile.currentRevision === null).assertTrue();
      expect(result.profile.failedCandidate !== null).assertTrue();
      expect(result.profile.lastError?.stage).assertEqual('VALIDATION');
      expect(contentStore.retainedKinds.join(',')).assertEqual('FAILED_CANDIDATE');
      expect(repository.savedProfiles.length).assertEqual(1);
    });

    it('retainsInvalidRemoteImportAsInvalidProfileWithEncryptedSecretRef', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const secretStore = new FakeSubscriptionSecretStore();
      const coreService = new FakeCoreService();
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        coreService,
        new FakeClock(['2026-08-07T00:00:00.000Z', '2026-08-07T00:01:00.000Z']),
        new FakeIdGenerator(['profile-remote-invalid']),
        createQueue()
      );

      gateway.remoteResults.push(new AcquiredRemoteSource(
        'Remote Broken',
        'https://remote.example.com',
        buildStagedSource('remote-invalid', '/sandbox/cache/remote-invalid.yaml')
      ));
      coreService.scriptedResults.push(new ScriptedVoidFailure(true, buildCoreError('CMFA_INVALID_ARGUMENT', 'invalid token=hunter2', false)));

      const result = await useCase.executeRemote(new RemoteImportArgs(
        'https://user:secret@remote.example.com/path?token=abc123',
        'Remote Broken',
        false
      ));

      expect(result.kind).assertEqual('CREATED');
      if (result.kind !== 'CREATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.availability).assertEqual('INVALID');
      expect(result.profile.currentRevision === null).assertTrue();
      expect(result.profile.failedCandidate !== null).assertTrue();
      expect(result.profile.sourceDisplay).assertEqual('https://remote.example.com');
      expect(result.profile.sourceSecretRef).assertEqual('secret-1');
      expect(secretStore.encryptCallCount).assertEqual(1);
    });

    it('persistsRemoteDownloadFailureWithOpaqueSecretRefAndNoPlaintextLeak', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const secretStore = new FakeSubscriptionSecretStore();
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T00:00:00.000Z', '2026-08-07T00:01:00.000Z']),
        new FakeIdGenerator(['profile-remote-download-failure']),
        createQueue()
      );

      gateway.remoteResults.push(new FailedRemoteSource(
        buildAppError('DOWNLOAD', 'download https://user:secret@remote.example.com/path?token=abc123 failed', true, 'APP_PLATFORM_TIMEOUT'),
        'Remote Download Failure',
        'https://remote.example.com',
        true
      ));

      const result = await useCase.executeRemote(new RemoteImportArgs(
        'https://user:secret@remote.example.com/path?token=abc123',
        'Remote Download Failure',
        false
      ));

      expect(result.kind).assertEqual('CREATED');
      if (result.kind !== 'CREATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.availability).assertEqual('INVALID');
      expect(result.profile.currentRevision === null).assertTrue();
      expect(result.profile.failedCandidate === null).assertTrue();
      expect(result.profile.sourceDisplay).assertEqual('https://remote.example.com');
      expect(result.profile.sourceSecretRef).assertEqual('secret-1');
      const snapshot = buildRemoteStateSnapshot(gateway, secretStore, repository);
      expect(snapshot.includes('https://remote.example.com')).assertTrue();
      assertNoPlaintextLeak(snapshot, ['user:secret', 'abc123', '/path', 'token=', 'subscription']);
    });

    it('mapsUnexpectedLocalAcquireThrowsToFailedImportResultWithoutPersistingRows', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        new FakeClock(['2026-08-07T00:00:00.000Z']),
        new FakeIdGenerator(['profile-local-acquire-throw']),
        createQueue()
      );

      gateway.scriptedLocalAcquireFailures.push(
        new ScriptedVoidFailure(true, new Error('local picker failed near /tmp/local-import-source'))
      );

      const result = await useCase.executeLocal(new LocalImportCommand('Local'));

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('IMPORT');
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(contentStore.retainedKinds.length).assertEqual(0);
      assertNoPlaintextLeak(result.error.technicalDetail, ['/tmp/local-import-source']);
    });

    it('mapsUnexpectedRemoteAcquireThrowsToFailedDownloadResultAndCleansOpaqueSecret', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const secretStore = new FakeSubscriptionSecretStore();
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T00:00:00.000Z']),
        new FakeIdGenerator(['profile-remote-acquire-throw']),
        createQueue()
      );

      gateway.scriptedRemoteAcquireFailures.push(
        new ScriptedVoidFailure(
          true,
          new Error('download https://user:secret@remote.example.com/path?token=abc123 failed near /tmp/remote-import')
        )
      );

      const result = await useCase.executeRemote(new RemoteImportArgs(
        'https://user:secret@remote.example.com/path?token=abc123',
        'Remote Acquire Throw',
        false
      ));

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('DOWNLOAD');
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(secretStore.removedRefs.join(',')).assertEqual('secret-1');
      const snapshot = buildRemoteStateSnapshot(gateway, secretStore, repository);
      expect(snapshot.includes('https://remote.example.com')).assertTrue();
      assertNoPlaintextLeak(snapshot, ['user:secret', 'abc123', '/path', 'token=', '/tmp/remote-import']);
    });

    it('mapsUnexpectedCurrentRetainThrowsToFailedImportResultAndDiscardsStagedLocalSource', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        new FakeClock(['2026-08-07T00:00:00.000Z']),
        new FakeIdGenerator(['profile-local-retain-throw']),
        createQueue()
      );

      gateway.localResults.push(new AcquiredLocalSource(
        'Local Retain Throw',
        'retain-throw.yaml',
        buildStagedSource('retain-throw-local', '/sandbox/cache/retain-throw-local.yaml')
      ));
      contentStore.scriptedRetainFailures.push(
        new ScriptedVoidFailure(true, new Error('retain current from /sandbox/cache/retain-throw-local.yaml failed'))
      );

      const result = await useCase.executeLocal(new LocalImportCommand());

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('PERSISTENCE');
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(contentStore.discardedStages.length).assertEqual(1);
      assertNoPlaintextLeak(result.error.technicalDetail, ['/sandbox/cache/retain-throw-local.yaml']);
    });

    it('mapsUnexpectedFailedCandidateRetainThrowsToFailedImportResultWhilePreservingPrimaryCleanup', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const secretStore = new FakeSubscriptionSecretStore();
      const coreService = new FakeCoreService();
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        coreService,
        new FakeClock(['2026-08-07T00:00:00.000Z']),
        new FakeIdGenerator(['profile-remote-failed-retain-throw']),
        createQueue()
      );

      gateway.remoteResults.push(new AcquiredRemoteSource(
        'Remote Failed Candidate Throw',
        'https://remote.example.com',
        buildStagedSource('retain-throw-remote', '/sandbox/cache/retain-throw-remote.yaml')
      ));
      coreService.scriptedResults.push(
        new ScriptedVoidFailure(true, buildCoreError('CMFA_INVALID_ARGUMENT', 'invalid token=hunter2', false))
      );
      contentStore.scriptedRetainFailures.push(
        new ScriptedVoidFailure(
          true,
          new Error('retain failed candidate for https://user:secret@remote.example.com/path?token=abc123 failed')
        )
      );
      contentStore.scriptedDiscardFailures.push(
        new ScriptedVoidFailure(true, new Error('discard /sandbox/cache/retain-throw-remote.yaml also failed'))
      );

      const result = await useCase.executeRemote(new RemoteImportArgs(
        'https://user:secret@remote.example.com/path?token=abc123',
        'Remote Failed Candidate Throw',
        false
      ));

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('PERSISTENCE');
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(contentStore.discardedStages.length).assertEqual(1);
      expect(secretStore.removedRefs.join(',')).assertEqual('secret-1');
      const snapshot = buildRemoteStateSnapshot(gateway, secretStore, repository);
      assertNoPlaintextLeak(snapshot, ['user:secret', 'abc123', '/path', 'token=']);
      assertNoPlaintextLeak(result.error.technicalDetail, ['user:secret', 'abc123', '/path', 'token=']);
    });

    it('returnsCancelledWithoutPersistingWhenLocalPickerCancels', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        new FakeClock(['2026-08-07T00:00:00.000Z']),
        new FakeIdGenerator(['profile-cancelled']),
        createQueue()
      );

      gateway.localResults.push(new CancelledLocalSource());

      const result = await useCase.executeLocal(new LocalImportCommand());

      expect(result.kind).assertEqual('CANCELLED');
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(contentStore.retainedKinds.length).assertEqual(0);
    });

    it('persistsRetryableInvalidLocalProfileWhenCopyFailsAfterPickerSelection', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        new FakeClock(['2026-08-07T00:00:00.000Z', '2026-08-07T00:01:00.000Z']),
        new FakeIdGenerator(['profile-copy-failed']),
        createQueue()
      );

      gateway.localResults.push(new FailedLocalSource(
        buildAppError('IMPORT', 'copy source failed', true, 'CMFA_IMPORT_COPY_FAILED'),
        true
      ));

      const result = await useCase.executeLocal(new LocalImportCommand());

      expect(result.kind).assertEqual('CREATED');
      if (result.kind !== 'CREATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.name).assertEqual('本地配置');
      expect(result.profile.sourceDisplay).assertEqual('本地配置');
      expect(result.profile.availability).assertEqual('INVALID');
      expect(result.profile.currentRevision === null).assertTrue();
      expect(result.profile.failedCandidate === null).assertTrue();
      expect(result.profile.lastError?.retryable).assertTrue();
      expect(contentStore.retainedKinds.length).assertEqual(0);
    });

    it('doesNotPersistProfileOrSecretWhenRemoteEncryptionFails', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const secretStore = new FakeSubscriptionSecretStore();
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T00:00:00.000Z']),
        new FakeIdGenerator(['profile-encrypt-fail']),
        createQueue()
      );

      secretStore.scriptedEncryptResults.push(new ScriptedStringFailure(true, undefined, buildSecretError('SOURCE_SECRET_WRITE_FAILED', 'encrypt failure')));

      const result = await useCase.executeRemote(new RemoteImportArgs(
        'https://demo.example.com/sub',
        'Remote',
        false
      ));

      expect(result.kind).assertEqual('FAILED');
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(secretStore.storedRefs.length).assertEqual(0);
      expect(gateway.remoteCommands.length).assertEqual(0);
    });

    it('returnsCancelledWithoutAnyMutationWhenHttpImportIsNotExplicitlyAllowed', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const secretStore = new FakeSubscriptionSecretStore();
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T00:00:00.000Z']),
        new FakeIdGenerator(['profile-http-blocked']),
        createQueue()
      );

      const result = await useCase.executeRemote(new RemoteImportArgs(
        'http://plain.example.com/subscription',
        'Remote',
        false
      ));

      expect(result.kind).assertEqual('CANCELLED');
      expect(secretStore.encryptCallCount).assertEqual(0);
      expect(gateway.remoteCommands.length).assertEqual(0);
      expect(repository.savedProfiles.length).assertEqual(0);
    });

    it('refreshesValidProfileAndRemovesSupersededRevisionsOnlyAfterCommit', 0, async () => {
      const previousCurrent = buildRevision('profiles/refresh/current.yaml', '2026-08-07T00:00:00.000Z');
      const previousFailed = buildRevision('profiles/refresh/failed.yaml', '2026-08-07T00:00:30.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-refresh-valid';
      existingOptions.name = 'Refreshable';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.failedCandidate = previousFailed;
      existingOptions.availability = 'VALID';
      existingOptions.sourceDisplay = 'refresh.yaml';
      existingOptions.createdAt = '2026-08-07T00:00:00.000Z';
      existingOptions.updatedAt = '2026-08-07T00:00:30.000Z';
      existingOptions.lastSuccessfulUpdateAt = '2026-08-07T00:00:00.000Z';
      const existingProfile: Profile = buildProfileWithInterval(existingOptions, 300000);
      const timeline = new FakeOperationTimeline();
      const repository = new IntervalPreservingProfileRepository([existingProfile], 'profile-refresh-valid', timeline);
      const contentStore = new FakeProfileContentStore(timeline);
      const gateway = new FakeProfileSourceGateway(timeline);
      const coreService = new FakeCoreService(timeline);
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(timeline),
        coreService,
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z'])
      );

      gateway.localResults.push(new AcquiredLocalSource(
        'Refreshable',
        'refresh-new.yaml',
        buildStagedSource('refresh-valid', '/sandbox/cache/refresh-valid.yaml')
      ));

      const pending = useCase.execute(new RefreshCommand('profile-refresh-valid'));
      await Promise.resolve();

      expect(contentStore.removedRevisions.length).assertEqual(0);
      const result = await pending;

      expect(result.kind).assertEqual('UPDATED');
      if (result.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.availability).assertEqual('VALID');
      expect(result.profile.currentRevision?.relativePath.includes('refresh-valid')).assertTrue();
      expect(result.profile.failedCandidate === null).assertTrue();
      expect(result.profile.autoUpdateIntervalMs).assertEqual(300000);
      expect(contentStore.removedRevisions.length).assertEqual(2);
      expect(collapseTimeline(timeline.entries)).assertEqual(
        'getProfile>acquire>validate>retainRevision>saveProfile>removeSuperseded'
      );
    });

    it('keepsPriorValidRevisionAndRecordsFailedCandidateWhenRefreshValidationFails', 0, async () => {
      const previousCurrent = buildRevision('profiles/refresh/current.yaml', '2026-08-07T00:00:00.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-refresh-invalid';
      existingOptions.name = 'Refreshable';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.availability = 'VALID';
      existingOptions.sourceDisplay = 'refresh.yaml';
      existingOptions.createdAt = '2026-08-07T00:00:00.000Z';
      existingOptions.updatedAt = '2026-08-07T00:00:30.000Z';
      existingOptions.lastSuccessfulUpdateAt = '2026-08-07T00:00:00.000Z';
      const repository = new IntervalPreservingProfileRepository(
        [buildProfileWithInterval(existingOptions, 900000)],
        'profile-refresh-invalid'
      );
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const coreService = new FakeCoreService();
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(),
        coreService,
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z'])
      );

      gateway.localResults.push(new AcquiredLocalSource(
        'Refreshable',
        'refresh-bad.yaml',
        buildStagedSource('refresh-invalid', '/sandbox/cache/refresh-invalid.yaml')
      ));
      coreService.scriptedResults.push(new ScriptedVoidFailure(true, buildCoreError('CMFA_INVALID_ARGUMENT', 'invalid bearer hunter2', false)));

      const result = await useCase.execute(new RefreshCommand('profile-refresh-invalid'));

      expect(result.kind).assertEqual('UPDATED');
      if (result.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.availability).assertEqual('UPDATE_FAILED_USING_VALID');
      expect(result.profile.currentRevision?.relativePath).assertEqual(previousCurrent.relativePath);
      expect(result.profile.failedCandidate !== null).assertTrue();
      expect(result.profile.lastError?.stage).assertEqual('VALIDATION');
      expect(result.profile.autoUpdateIntervalMs).assertEqual(900000);
      expect(contentStore.removedRevisions.length).assertEqual(0);
    });

    it('removesNewRevisionAndPreservesOldReferencesWhenRepositoryCommitFails', 0, async () => {
      const previousCurrent = buildRevision('profiles/refresh/current.yaml', '2026-08-07T00:00:00.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-refresh-save-fail';
      existingOptions.name = 'Refreshable';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.availability = 'VALID';
      existingOptions.sourceDisplay = 'refresh.yaml';
      existingOptions.createdAt = '2026-08-07T00:00:00.000Z';
      existingOptions.updatedAt = '2026-08-07T00:00:30.000Z';
      existingOptions.lastSuccessfulUpdateAt = '2026-08-07T00:00:00.000Z';
      const timeline = new FakeOperationTimeline();
      const repository = new FakeProfileRepository([buildProfile(existingOptions)], 'profile-refresh-save-fail', timeline);
      repository.scriptedSaveResults.push(new ScriptedVoidFailure(true, new Error('sqlite write failed')));
      const contentStore = new FakeProfileContentStore(timeline);
      const gateway = new FakeProfileSourceGateway(timeline);
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(timeline),
        new FakeCoreService(timeline),
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z'])
      );

      gateway.localResults.push(new AcquiredLocalSource(
        'Refreshable',
        'refresh-new.yaml',
        buildStagedSource('refresh-save-fail', '/sandbox/cache/refresh-save-fail.yaml')
      ));

      const result = await useCase.execute(new RefreshCommand('profile-refresh-save-fail'));

      expect(result.kind).assertEqual('FAILED');
      expect(contentStore.removedRevisions.length).assertEqual(1);
      expect(contentStore.removedRevisions[0].relativePath.includes('refresh-save-fail')).assertTrue();
      expect(repository.currentProfile('profile-refresh-save-fail')?.currentRevision?.relativePath).assertEqual(
        previousCurrent.relativePath
      );
      expect(contentStore.removedRevisions[0].relativePath === previousCurrent.relativePath).assertFalse();
      expect(timeline.joined()).assertEqual(
        'getProfile>acquire>validate>retainRevision>saveProfile>saveProfileFailed>removeRevision'
      );
    });

    it('mapsRemoteRefreshSecretFailuresToExactPersistenceCodesWithoutAcquisition', 0, async () => {
      const previousCurrent = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-remote-refresh';
      existingOptions.name = 'Remote';
      existingOptions.sourceKind = 'REMOTE_URL';
      existingOptions.sourceDisplay = 'https://remote.example.com';
      existingOptions.sourceSecretRef = 'secret-remote-1';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.availability = 'VALID';
      existingOptions.createdAt = '2026-08-07T00:00:00.000Z';
      existingOptions.updatedAt = '2026-08-07T00:00:30.000Z';
      existingOptions.lastSuccessfulUpdateAt = '2026-08-07T00:00:00.000Z';
      const repository = new IntervalPreservingProfileRepository(
        [buildProfileWithInterval(existingOptions, 120000)],
        'profile-remote-refresh'
      );
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const secretStore = new FakeSubscriptionSecretStore();
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z'])
      );

      secretStore.scriptedDecryptResults.push(new ScriptedStringFailure(true, undefined, buildSecretError('SOURCE_SECRET_MISSING', 'secret missing')));

      const result = await useCase.execute(new RefreshCommand('profile-remote-refresh', false));

      expect(result.kind).assertEqual('UPDATED');
      if (result.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.availability).assertEqual('UPDATE_FAILED_USING_VALID');
      expect(result.profile.currentRevision?.relativePath).assertEqual(previousCurrent.relativePath);
      expect(result.profile.failedCandidate === null).assertTrue();
      expect(result.profile.autoUpdateIntervalMs).assertEqual(120000);
      expect(result.profile.lastError?.code).assertEqual('SOURCE_SECRET_MISSING');
      expect(result.profile.lastError?.stage).assertEqual('PERSISTENCE');
      expect(result.profile.lastError?.retryable).assertFalse();
      expect(gateway.remoteCommands.length).assertEqual(0);
    });

    it('acquiresLeaseBeforeRemoteDecryptAndReleasesAfterSuccessfulRefreshCommit', 0, async () => {
      const previousCurrent = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-remote-refresh-leased';
      existingOptions.name = 'Remote Lease';
      existingOptions.sourceKind = 'REMOTE_URL';
      existingOptions.sourceDisplay = 'https://remote.example.com';
      existingOptions.sourceSecretRef = 'secret-remote-leased';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.availability = 'VALID';
      existingOptions.createdAt = '2026-08-07T00:00:00.000Z';
      existingOptions.updatedAt = '2026-08-07T00:00:30.000Z';
      existingOptions.lastSuccessfulUpdateAt = '2026-08-07T00:00:00.000Z';
      const timeline = new FakeOperationTimeline();
      const repository = new IntervalPreservingProfileRepository(
        [buildProfileWithInterval(existingOptions, 120000)],
        'profile-remote-refresh-leased',
        timeline
      );
      repository.scriptedGetResults.push(buildProfileWithInterval(existingOptions, 120000));
      repository.scriptedGetResults.push(buildProfileWithInterval(existingOptions, 120000));
      const contentStore = new FakeProfileContentStore(timeline);
      const gateway = new FakeProfileSourceGateway(timeline);
      const secretStore = new FakeSubscriptionSecretStore(timeline);
      const coreService = new FakeCoreService(timeline);
      const leasePort = new FakeProfileRefreshLeasePort(timeline);
      const idGenerator = new FakeIdGenerator(['lease-owner-remote-success']);
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        coreService,
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z', '2026-08-07T01:02:00.000Z']),
        leasePort,
        idGenerator
      );

      secretStore.scriptedDecryptResults.push(new ScriptedStringFailure(false, 'HTTPS_SUBSCRIPTION_CREDENTIALS'));
      gateway.remoteResults.push(new AcquiredRemoteSource(
        'Remote Lease',
        'https://remote.example.com',
        buildStagedSource('refresh-remote-leased', '/sandbox/cache/refresh-remote-leased.yaml')
      ));

      const result = await useCase.execute(new RefreshCommand('profile-remote-refresh-leased', false));

      expect(result.kind).assertEqual('UPDATED');
      expect(result.leaseReleased).assertTrue();
      expect(leasePort.tryAcquireCalls.length).assertEqual(1);
      expect(leasePort.releaseCalls.length).assertEqual(1);
      expect(leasePort.tryAcquireCalls[0].profileId).assertEqual('profile-remote-refresh-leased');
      expect(leasePort.tryAcquireCalls[0].ownerToken).assertEqual('lease-owner-remote-success');
      expect(leasePort.releaseCalls[0].ownerToken).assertEqual('lease-owner-remote-success');
      expect(collapseTimeline(timeline.entries)).assertEqual(
        'getProfile>leaseTryAcquire>getProfile>decryptSource>acquire>validate>retainRevision>saveProfile>removeSuperseded>leaseRelease'
      );
    });

    it('failsRemoteRefreshWithBusyCodeWithoutDecryptGatewaySaveOrReleaseWhenLeaseBusy', 0, async () => {
      const previousCurrent = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-remote-refresh-busy';
      existingOptions.name = 'Remote Busy';
      existingOptions.sourceKind = 'REMOTE_URL';
      existingOptions.sourceDisplay = 'https://remote.example.com';
      existingOptions.sourceSecretRef = 'secret-remote-busy';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.availability = 'VALID';
      const repository = new IntervalPreservingProfileRepository(
        [buildProfileWithInterval(existingOptions, 60000)],
        'profile-remote-refresh-busy'
      );
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const secretStore = new FakeSubscriptionSecretStore();
      const leasePort = new FakeProfileRefreshLeasePort();
      leasePort.tryAcquireResult = false;
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T01:00:00.000Z']),
        leasePort,
        new FakeIdGenerator(['lease-owner-remote-busy'])
      );

      const result = await useCase.execute(new RefreshCommand('profile-remote-refresh-busy', false));

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('PERSISTENCE');
      expect(result.error.code).assertEqual('PROFILE_REFRESH_BUSY');
      expect(result.error.retryable).assertTrue();
      expect(result.error.technicalDetail).assertEqual('Profile refresh is already in progress.');
      expect(result.leaseReleased).assertUndefined();
      expect(secretStore.decryptCalls.length).assertEqual(0);
      expect(gateway.remoteCommands.length).assertEqual(0);
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(leasePort.releaseCalls.length).assertEqual(0);
      expect(contentStore.retainedKinds.length).assertEqual(0);
    });

    it('mapsLeaseAcquireThrowToSafeFailedCodeWithoutDecryptOrUrlLeak', 0, async () => {
      const previousCurrent = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-remote-refresh-lease-throw';
      existingOptions.name = 'Remote Throw';
      existingOptions.sourceKind = 'REMOTE_URL';
      existingOptions.sourceDisplay = 'https://remote.example.com';
      existingOptions.sourceSecretRef = 'secret-remote-throw';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.availability = 'VALID';
      const repository = new FakeProfileRepository([buildProfile(existingOptions)], 'profile-remote-refresh-lease-throw');
      const gateway = new FakeProfileSourceGateway();
      const secretStore = new FakeSubscriptionSecretStore();
      const leasePort = new FakeProfileRefreshLeasePort();
      leasePort.tryAcquireError = new Error(
        'lease failed for profile-remote-refresh-lease-throw url=https://user:secret@remote.example.com/path?token=abc123'
      );
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        new FakeProfileContentStore(),
        gateway,
        secretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T01:00:00.000Z']),
        leasePort,
        new FakeIdGenerator(['lease-owner-remote-throw'])
      );

      const result = await useCase.execute(new RefreshCommand('profile-remote-refresh-lease-throw', false));

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('PERSISTENCE');
      expect(result.error.code).assertEqual('PROFILE_REFRESH_LEASE_FAILED');
      expect(result.error.retryable).assertTrue();
      expect(result.error.technicalDetail).assertEqual('Profile refresh lease failed.');
      expect(result.leaseReleased).assertUndefined();
      assertNoPlaintextLeak(result.error.technicalDetail, ['profile-remote-refresh-lease-throw', 'user:secret', 'abc123', '/path', 'token=']);
      expect(secretStore.decryptCalls.length).assertEqual(0);
      expect(gateway.remoteCommands.length).assertEqual(0);
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(leasePort.releaseCalls.length).assertEqual(0);
    });

    it('releasesLeaseWhenRemoteRefreshFailsOrCancelsWithoutChangingBusinessResult', 0, async () => {
      const failureOptions = new ProfileFixtureOptions();
      failureOptions.id = 'profile-remote-refresh-release-failure';
      failureOptions.name = 'Remote Release Failure';
      failureOptions.sourceKind = 'REMOTE_URL';
      failureOptions.sourceDisplay = 'https://remote.example.com';
      failureOptions.sourceSecretRef = 'secret-remote-release-failure';
      failureOptions.currentRevision = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      failureOptions.availability = 'VALID';
      const failureLeasePort = new FakeProfileRefreshLeasePort();
      const failureSecretStore = new FakeSubscriptionSecretStore();
      const failureGateway = new FakeProfileSourceGateway();
      failureGateway.remoteResults.push(new FailedRemoteSource(
        buildAppError('DOWNLOAD', 'Remote timed out.', true, 'APP_PLATFORM_TIMEOUT'),
        'Remote Release Failure',
        'https://remote.example.com',
        false
      ));
      failureSecretStore.scriptedDecryptResults.push(new ScriptedStringFailure(false, 'HTTPS_SUBSCRIPTION_CREDENTIALS'));
      const failureUseCase = createRefreshUseCase(
        new FakeProfileRepository([buildProfile(failureOptions)], 'profile-remote-refresh-release-failure'),
        new FakeProfileContentStore(),
        failureGateway,
        failureSecretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z']),
        failureLeasePort,
        new FakeIdGenerator(['lease-owner-release-failure'])
      );

      const failureResult = await failureUseCase.execute(new RefreshCommand('profile-remote-refresh-release-failure', false));

      expect(failureResult.kind).assertEqual('UPDATED');
      expect(failureResult.leaseReleased).assertTrue();
      expect(failureLeasePort.releaseCalls.length).assertEqual(1);

      const cancelOptions = new ProfileFixtureOptions();
      cancelOptions.id = 'profile-remote-refresh-release-cancel';
      cancelOptions.name = 'Remote Release Cancel';
      cancelOptions.sourceKind = 'REMOTE_URL';
      cancelOptions.sourceDisplay = 'http://plain.example.com';
      cancelOptions.sourceSecretRef = 'secret-remote-release-cancel';
      cancelOptions.currentRevision = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      cancelOptions.availability = 'VALID';
      const cancelLeasePort = new FakeProfileRefreshLeasePort();
      const cancelSecretStore = new FakeSubscriptionSecretStore();
      cancelSecretStore.scriptedDecryptResults.push(new ScriptedStringFailure(false, 'HTTP_SUBSCRIPTION_CREDENTIALS'));
      const cancelGateway = new FakeProfileSourceGateway();
      const cancelUseCase = createRefreshUseCase(
        new FakeProfileRepository([buildProfile(cancelOptions)], 'profile-remote-refresh-release-cancel'),
        new FakeProfileContentStore(),
        cancelGateway,
        cancelSecretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T01:02:00.000Z']),
        cancelLeasePort,
        new FakeIdGenerator(['lease-owner-release-cancel'])
      );

      const cancelResult = await cancelUseCase.execute(new RefreshCommand('profile-remote-refresh-release-cancel', false));

      expect(cancelResult.kind).assertEqual('CANCELLED');
      expect(cancelResult.leaseReleased).assertTrue();
      expect(cancelLeasePort.releaseCalls.length).assertEqual(1);
      expect(cancelGateway.remoteCommands.length).assertEqual(0);
    });

    it('rechecksProfileAfterLeaseAndUsesNewerRemoteSecretAndBaseState', 0, async () => {
      const oldCurrent = buildRevision('profiles/remote/old-current.yaml', '2026-08-07T00:00:00.000Z');
      const newerCurrent = buildRevision('profiles/remote/newer-current.yaml', '2026-08-07T00:10:00.000Z');
      const firstOptions = new ProfileFixtureOptions();
      firstOptions.id = 'profile-remote-refresh-reread';
      firstOptions.name = 'Remote Old';
      firstOptions.sourceKind = 'REMOTE_URL';
      firstOptions.sourceDisplay = 'https://old.example.com';
      firstOptions.sourceSecretRef = 'secret-old';
      firstOptions.currentRevision = oldCurrent;
      firstOptions.availability = 'VALID';
      const secondOptions = new ProfileFixtureOptions();
      secondOptions.id = 'profile-remote-refresh-reread';
      secondOptions.name = 'Remote New';
      secondOptions.sourceKind = 'REMOTE_URL';
      secondOptions.sourceDisplay = 'https://new.example.com';
      secondOptions.sourceSecretRef = 'secret-new';
      secondOptions.currentRevision = newerCurrent;
      secondOptions.availability = 'VALID';
      const timeline = new FakeOperationTimeline();
      const repository = new IntervalPreservingProfileRepository(
        [buildProfileWithInterval(secondOptions, 180000)],
        'profile-remote-refresh-reread',
        timeline
      );
      repository.scriptedGetResults.push(buildProfileWithInterval(firstOptions, 180000));
      repository.scriptedGetResults.push(buildProfileWithInterval(secondOptions, 180000));
      const gateway = new FakeProfileSourceGateway(timeline);
      gateway.remoteResults.push(new FailedRemoteSource(
        buildAppError('DOWNLOAD', 'Retry later.', true, 'APP_PLATFORM_TIMEOUT'),
        'Remote New',
        'https://new.example.com',
        false
      ));
      const secretStore = new FakeSubscriptionSecretStore(timeline);
      secretStore.scriptedDecryptResults.push(new ScriptedStringFailure(false, 'HTTPS_SUBSCRIPTION_CREDENTIALS_NEXT'));
      const useCase = createRefreshUseCase(
        repository,
        new FakeProfileContentStore(timeline),
        gateway,
        secretStore,
        new FakeCoreService(timeline),
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z', '2026-08-07T01:02:00.000Z']),
        new FakeProfileRefreshLeasePort(timeline),
        new FakeIdGenerator(['lease-owner-reread'])
      );

      const result = await useCase.execute(new RefreshCommand('profile-remote-refresh-reread', false));

      expect(result.kind).assertEqual('UPDATED');
      if (result.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.leaseReleased).assertTrue();
      expect(secretStore.decryptCalls[0]).assertEqual('secret-new');
      expect(result.profile.currentRevision?.relativePath).assertEqual(newerCurrent.relativePath);
      expect(result.profile.sourceDisplay).assertEqual('https://new.example.com');
      expect(collapseTimeline(timeline.entries).startsWith('getProfile>leaseTryAcquire>getProfile>decryptSource')).assertTrue();
    });

    it('returnsChangedFailureWithoutDecryptOrSaveWhenRemoteProfileDisappearsAfterLease', 0, async () => {
      const firstOptions = new ProfileFixtureOptions();
      firstOptions.id = 'profile-remote-refresh-missing-after-lease';
      firstOptions.name = 'Remote Missing';
      firstOptions.sourceKind = 'REMOTE_URL';
      firstOptions.sourceDisplay = 'https://remote.example.com';
      firstOptions.sourceSecretRef = 'secret-missing-after-lease';
      firstOptions.currentRevision = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      firstOptions.availability = 'VALID';
      const timeline = new FakeOperationTimeline();
      const repository = new IntervalPreservingProfileRepository([], undefined, timeline);
      repository.scriptedGetResults.push(buildProfileWithInterval(firstOptions, 60000));
      repository.scriptedGetResults.push(undefined);
      const gateway = new FakeProfileSourceGateway(timeline);
      const secretStore = new FakeSubscriptionSecretStore(timeline);
      const useCase = createRefreshUseCase(
        repository,
        new FakeProfileContentStore(timeline),
        gateway,
        secretStore,
        new FakeCoreService(timeline),
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z']),
        new FakeProfileRefreshLeasePort(timeline),
        new FakeIdGenerator(['lease-owner-missing-after-lease'])
      );

      const result = await useCase.execute(new RefreshCommand('profile-remote-refresh-missing-after-lease', false));

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.code).assertEqual('PROFILE_REFRESH_CHANGED');
      expect(result.error.retryable).assertTrue();
      expect(result.leaseReleased).assertTrue();
      expect(secretStore.decryptCalls.length).assertEqual(0);
      expect(gateway.remoteCommands.length).assertEqual(0);
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(collapseTimeline(timeline.entries)).assertEqual('getProfile>leaseTryAcquire>getProfile>leaseRelease');
    });

    it('returnsChangedFailureWithoutAnyAcquireWhenRemoteBecomesLocalAfterLease', 0, async () => {
      const firstOptions = new ProfileFixtureOptions();
      firstOptions.id = 'profile-remote-refresh-became-local';
      firstOptions.name = 'Remote Then Local';
      firstOptions.sourceKind = 'REMOTE_URL';
      firstOptions.sourceDisplay = 'https://remote.example.com';
      firstOptions.sourceSecretRef = 'secret-became-local';
      firstOptions.currentRevision = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      firstOptions.availability = 'VALID';
      const secondOptions = new ProfileFixtureOptions();
      secondOptions.id = 'profile-remote-refresh-became-local';
      secondOptions.name = 'Now Local';
      secondOptions.sourceKind = 'LOCAL_FILE';
      secondOptions.sourceDisplay = 'local.yaml';
      secondOptions.currentRevision = buildRevision('profiles/local/current.yaml', '2026-08-07T00:01:00.000Z');
      secondOptions.availability = 'VALID';
      const timeline = new FakeOperationTimeline();
      const repository = new IntervalPreservingProfileRepository(
        [buildProfileWithInterval(secondOptions, 60000)],
        'profile-remote-refresh-became-local',
        timeline
      );
      repository.scriptedGetResults.push(buildProfileWithInterval(firstOptions, 60000));
      repository.scriptedGetResults.push(buildProfileWithInterval(secondOptions, 60000));
      const gateway = new FakeProfileSourceGateway(timeline);
      const useCase = createRefreshUseCase(
        repository,
        new FakeProfileContentStore(timeline),
        gateway,
        new FakeSubscriptionSecretStore(timeline),
        new FakeCoreService(timeline),
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z']),
        new FakeProfileRefreshLeasePort(timeline),
        new FakeIdGenerator(['lease-owner-became-local'])
      );

      const result = await useCase.execute(new RefreshCommand('profile-remote-refresh-became-local', false));

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.code).assertEqual('PROFILE_REFRESH_CHANGED');
      expect(result.leaseReleased).assertTrue();
      expect(gateway.remoteCommands.length).assertEqual(0);
      expect(gateway.localCommands.length).assertEqual(0);
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(collapseTimeline(timeline.entries)).assertEqual('getProfile>leaseTryAcquire>getProfile>leaseRelease');
    });

    it('keepsLocalRefreshFreeOfLeaseCalls', 0, async () => {
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-local-refresh-no-lease';
      existingOptions.name = 'Local No Lease';
      existingOptions.sourceKind = 'LOCAL_FILE';
      existingOptions.sourceDisplay = 'local.yaml';
      existingOptions.currentRevision = buildRevision('profiles/local/current.yaml', '2026-08-07T00:00:00.000Z');
      existingOptions.availability = 'VALID';
      const leasePort = new FakeProfileRefreshLeasePort();
      const gateway = new FakeProfileSourceGateway();
      gateway.localResults.push(new AcquiredLocalSource(
        'Local No Lease',
        'local-next.yaml',
        buildStagedSource('local-no-lease', '/sandbox/cache/local-no-lease.yaml')
      ));
      const useCase = createRefreshUseCase(
        new FakeProfileRepository([buildProfile(existingOptions)], 'profile-local-refresh-no-lease'),
        new FakeProfileContentStore(),
        gateway,
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z']),
        leasePort,
        new FakeIdGenerator(['lease-owner-local-unused'])
      );

      const result = await useCase.execute(new RefreshCommand('profile-local-refresh-no-lease'));

      expect(result.kind).assertEqual('UPDATED');
      expect(result.leaseReleased).assertUndefined();
      expect(leasePort.tryAcquireCalls.length).assertEqual(0);
      expect(leasePort.releaseCalls.length).assertEqual(0);
    });

    it('preservesBusinessResultWhenLeaseReleaseReturnsFalseOrThrows', 0, async () => {
      const successOptions = new ProfileFixtureOptions();
      successOptions.id = 'profile-remote-refresh-release-false';
      successOptions.name = 'Remote Release False';
      successOptions.sourceKind = 'REMOTE_URL';
      successOptions.sourceDisplay = 'https://remote.example.com';
      successOptions.sourceSecretRef = 'secret-remote-release-false';
      successOptions.currentRevision = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      successOptions.availability = 'VALID';
      const falseLeasePort = new FakeProfileRefreshLeasePort();
      falseLeasePort.releaseResult = false;
      const falseGateway = new FakeProfileSourceGateway();
      falseGateway.remoteResults.push(new AcquiredRemoteSource(
        'Remote Release False',
        'https://remote.example.com',
        buildStagedSource('refresh-release-false', '/sandbox/cache/refresh-release-false.yaml')
      ));
      const falseSecretStore = new FakeSubscriptionSecretStore();
      falseSecretStore.scriptedDecryptResults.push(new ScriptedStringFailure(false, 'HTTPS_SUBSCRIPTION_CREDENTIALS'));
      const falseResult = await createRefreshUseCase(
        new FakeProfileRepository([buildProfile(successOptions)], 'profile-remote-refresh-release-false'),
        new FakeProfileContentStore(),
        falseGateway,
        falseSecretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z', '2026-08-07T01:02:00.000Z']),
        falseLeasePort,
        new FakeIdGenerator(['lease-owner-release-false'])
      ).execute(new RefreshCommand('profile-remote-refresh-release-false', false));
      expect(falseResult.kind).assertEqual('UPDATED');
      expect(falseResult.leaseReleased).assertFalse();

      const throwOptions = new ProfileFixtureOptions();
      throwOptions.id = 'profile-remote-refresh-release-throw';
      throwOptions.name = 'Remote Release Throw';
      throwOptions.sourceKind = 'REMOTE_URL';
      throwOptions.sourceDisplay = 'https://remote.example.com';
      throwOptions.sourceSecretRef = 'secret-remote-release-throw';
      throwOptions.currentRevision = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      throwOptions.availability = 'VALID';
      const throwLeasePort = new FakeProfileRefreshLeasePort();
      throwLeasePort.releaseError = new Error('release threw');
      const throwGateway = new FakeProfileSourceGateway();
      throwGateway.remoteResults.push(new FailedRemoteSource(
        buildAppError('DOWNLOAD', 'Remote retry later.', true, 'APP_PLATFORM_TIMEOUT'),
        'Remote Release Throw',
        'https://remote.example.com',
        false
      ));
      const throwSecretStore = new FakeSubscriptionSecretStore();
      throwSecretStore.scriptedDecryptResults.push(new ScriptedStringFailure(false, 'HTTPS_SUBSCRIPTION_CREDENTIALS'));
      const throwResult = await createRefreshUseCase(
        new FakeProfileRepository([buildProfile(throwOptions)], 'profile-remote-refresh-release-throw'),
        new FakeProfileContentStore(),
        throwGateway,
        throwSecretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T01:03:00.000Z', '2026-08-07T01:04:00.000Z']),
        throwLeasePort,
        new FakeIdGenerator(['lease-owner-release-throw'])
      ).execute(new RefreshCommand('profile-remote-refresh-release-throw', false));
      expect(throwResult.kind).assertEqual('UPDATED');
      expect(throwResult.leaseReleased).assertFalse();
    });

    it('preservesAutoUpdateIntervalWhenRefreshingInvalidProfileFailure', 0, async () => {
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-refresh-invalid-no-current';
      existingOptions.name = 'Refreshable Invalid';
      existingOptions.sourceKind = 'LOCAL_FILE';
      existingOptions.sourceDisplay = 'refresh-invalid.yaml';
      existingOptions.currentRevision = null;
      existingOptions.failedCandidate = null;
      existingOptions.availability = 'INVALID';
      existingOptions.createdAt = '2026-08-07T00:00:00.000Z';
      existingOptions.updatedAt = '2026-08-07T00:00:30.000Z';
      existingOptions.lastSuccessfulUpdateAt = null;
      const repository = new IntervalPreservingProfileRepository(
        [buildProfileWithInterval(existingOptions, 45000)],
        'profile-refresh-invalid-no-current'
      );
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const coreService = new FakeCoreService();
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(),
        coreService,
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z'])
      );

      gateway.localResults.push(new AcquiredLocalSource(
        'Refreshable Invalid',
        'refresh-invalid.yaml',
        buildStagedSource('refresh-invalid-no-current', '/sandbox/cache/refresh-invalid-no-current.yaml')
      ));
      coreService.scriptedResults.push(new ScriptedVoidFailure(true, buildCoreError('CMFA_INVALID_ARGUMENT', 'invalid bearer hunter2', false)));

      const result = await useCase.execute(new RefreshCommand('profile-refresh-invalid-no-current'));

      expect(result.kind).assertEqual('UPDATED');
      if (result.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.availability).assertEqual('INVALID');
      expect(result.profile.currentRevision).assertNull();
      expect(result.profile.failedCandidate !== null).assertTrue();
      expect(result.profile.autoUpdateIntervalMs).assertEqual(45000);
    });

    it('preservesSourceSecretVersionUnsupportedDuringRemoteRefreshWithoutAcquisitionOrNewCandidate', 0, async () => {
      const previousCurrent = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-remote-refresh-version';
      existingOptions.name = 'Remote';
      existingOptions.sourceKind = 'REMOTE_URL';
      existingOptions.sourceDisplay = 'https://remote.example.com';
      existingOptions.sourceSecretRef = 'secret-remote-version';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.availability = 'VALID';
      existingOptions.createdAt = '2026-08-07T00:00:00.000Z';
      existingOptions.updatedAt = '2026-08-07T00:00:30.000Z';
      existingOptions.lastSuccessfulUpdateAt = '2026-08-07T00:00:00.000Z';
      const timeline = new FakeOperationTimeline();
      const repository = new FakeProfileRepository(
        [buildProfile(existingOptions)],
        'profile-remote-refresh-version',
        timeline
      );
      const contentStore = new FakeProfileContentStore(timeline);
      const gateway = new FakeProfileSourceGateway(timeline);
      const secretStore = new FakeSubscriptionSecretStore(timeline);
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        new FakeCoreService(timeline),
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z'])
      );

      secretStore.scriptedDecryptResults.push(new ScriptedStringFailure(
        true,
        undefined,
        buildSecretError('SOURCE_SECRET_VERSION_UNSUPPORTED', 'version 0 secret unsupported')
      ));

      const result = await useCase.execute(new RefreshCommand('profile-remote-refresh-version', false));

      expect(result.kind).assertEqual('UPDATED');
      if (result.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.availability).assertEqual('UPDATE_FAILED_USING_VALID');
      expect(result.profile.currentRevision?.relativePath).assertEqual(previousCurrent.relativePath);
      expect(result.profile.failedCandidate === null).assertTrue();
      expect(result.profile.lastError?.code).assertEqual('SOURCE_SECRET_VERSION_UNSUPPORTED');
      expect(result.profile.lastError?.stage).assertEqual('PERSISTENCE');
      expect(result.profile.lastError?.retryable).assertFalse();
      expect(gateway.remoteCommands.length).assertEqual(0);
      expect(contentStore.retainedKinds.length).assertEqual(0);
      expect(timeline.joined()).assertEqual('getProfile>getProfile>decryptSource>saveProfile');
    });

    it('fallsBackToSafeDecryptFailureCodeWithoutLeakingPlaintextDuringRemoteRefresh', 0, async () => {
      const previousCurrent = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-remote-refresh-generic';
      existingOptions.name = 'Remote';
      existingOptions.sourceKind = 'REMOTE_URL';
      existingOptions.sourceDisplay = 'https://remote.example.com';
      existingOptions.sourceSecretRef = 'secret-remote-generic';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.availability = 'VALID';
      existingOptions.createdAt = '2026-08-07T00:00:00.000Z';
      existingOptions.updatedAt = '2026-08-07T00:00:30.000Z';
      existingOptions.lastSuccessfulUpdateAt = '2026-08-07T00:00:00.000Z';
      const repository = new FakeProfileRepository([buildProfile(existingOptions)], 'profile-remote-refresh-generic');
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const secretStore = new FakeSubscriptionSecretStore();
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T01:00:00.000Z', '2026-08-07T01:01:00.000Z'])
      );

      secretStore.scriptedDecryptResults.push(new ScriptedStringFailure(
        true,
        undefined,
        new Error(
          'decrypt https://user:secret@remote.example.com/path?token=abc123 failed near /tmp/private-cache'
        )
      ));

      const result = await useCase.execute(new RefreshCommand('profile-remote-refresh-generic', false));

      expect(result.kind).assertEqual('UPDATED');
      if (result.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.availability).assertEqual('UPDATE_FAILED_USING_VALID');
      expect(result.profile.currentRevision?.relativePath).assertEqual(previousCurrent.relativePath);
      expect(result.profile.failedCandidate === null).assertTrue();
      expect(result.profile.lastError?.code).assertEqual('SOURCE_DECRYPT_FAILED');
      expect(result.profile.lastError?.technicalDetail.includes('https://remote.example.com')).assertTrue();
      assertNoPlaintextLeak(result.profile.lastError?.technicalDetail ?? '', ['user:secret', 'abc123', '/path', 'token=', '/tmp/private-cache']);
      expect(gateway.remoteCommands.length).assertEqual(0);
      const snapshot = buildRemoteStateSnapshot(gateway, secretStore, repository);
      assertNoPlaintextLeak(snapshot, ['user:secret', 'abc123', '/path', 'token=']);
    });

    it('mapsUnexpectedLocalRefreshAcquireThrowsToFailedImportResultWithoutMutatingExistingRows', 0, async () => {
      const previousCurrent = buildRevision('profiles/refresh/current.yaml', '2026-08-07T00:00:00.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-refresh-acquire-throw';
      existingOptions.name = 'Refreshable';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.availability = 'VALID';
      existingOptions.sourceDisplay = 'refresh.yaml';
      existingOptions.createdAt = '2026-08-07T00:00:00.000Z';
      existingOptions.updatedAt = '2026-08-07T00:00:30.000Z';
      existingOptions.lastSuccessfulUpdateAt = '2026-08-07T00:00:00.000Z';
      const repository = new FakeProfileRepository([buildProfile(existingOptions)], 'profile-refresh-acquire-throw');
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        new FakeClock(['2026-08-07T01:00:00.000Z'])
      );

      gateway.scriptedLocalAcquireFailures.push(
        new ScriptedVoidFailure(true, new Error('refresh picker failed near /tmp/refresh-local'))
      );

      const result = await useCase.execute(new RefreshCommand('profile-refresh-acquire-throw'));

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('IMPORT');
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(repository.currentProfile('profile-refresh-acquire-throw')?.currentRevision?.relativePath).assertEqual(
        previousCurrent.relativePath
      );
      assertNoPlaintextLeak(result.error.technicalDetail, ['/tmp/refresh-local']);
    });

    it('mapsUnexpectedRemoteRefreshAcquireThrowsToFailedDownloadResultWithoutDeletingExistingSecret', 0, async () => {
      const previousCurrent = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-remote-refresh-acquire-throw';
      existingOptions.name = 'Remote';
      existingOptions.sourceKind = 'REMOTE_URL';
      existingOptions.sourceDisplay = 'https://remote.example.com';
      existingOptions.sourceSecretRef = 'secret-remote-existing';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.availability = 'VALID';
      existingOptions.createdAt = '2026-08-07T00:00:00.000Z';
      existingOptions.updatedAt = '2026-08-07T00:00:30.000Z';
      existingOptions.lastSuccessfulUpdateAt = '2026-08-07T00:00:00.000Z';
      const repository = new FakeProfileRepository([buildProfile(existingOptions)], 'profile-remote-refresh-acquire-throw');
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const secretStore = new FakeSubscriptionSecretStore();
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        new FakeCoreService(),
        new FakeClock(['2026-08-07T01:00:00.000Z'])
      );

      secretStore.scriptedDecryptResults.push(new ScriptedStringFailure(false, 'HTTPS_SUBSCRIPTION_CREDENTIALS'));
      gateway.scriptedRemoteAcquireFailures.push(
        new ScriptedVoidFailure(
          true,
          new Error('download https://user:secret@remote.example.com/path?token=abc123 failed near /tmp/refresh-remote')
        )
      );

      const result = await useCase.execute(new RefreshCommand('profile-remote-refresh-acquire-throw', false));

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('DOWNLOAD');
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(secretStore.removedRefs.length).assertEqual(0);
      expect(repository.currentProfile('profile-remote-refresh-acquire-throw')?.currentRevision?.relativePath).assertEqual(
        previousCurrent.relativePath
      );
      const snapshot = buildRemoteStateSnapshot(gateway, secretStore, repository);
      assertNoPlaintextLeak(snapshot, ['user:secret', 'abc123', '/path', 'token=', '/tmp/refresh-remote']);
      assertNoPlaintextLeak(result.error.technicalDetail, ['user:secret', 'abc123', '/path', 'token=', '/tmp/refresh-remote']);
    });

    it('mapsUnexpectedRefreshCurrentRetainThrowsToFailedPersistenceResultAndDiscardsStage', 0, async () => {
      const previousCurrent = buildRevision('profiles/refresh/current.yaml', '2026-08-07T00:00:00.000Z');
      const previousFailed = buildRevision('profiles/refresh/failed.yaml', '2026-08-07T00:00:10.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-refresh-retain-throw';
      existingOptions.name = 'Refreshable';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.failedCandidate = previousFailed;
      existingOptions.availability = 'VALID';
      existingOptions.sourceDisplay = 'refresh.yaml';
      existingOptions.createdAt = '2026-08-07T00:00:00.000Z';
      existingOptions.updatedAt = '2026-08-07T00:00:30.000Z';
      existingOptions.lastSuccessfulUpdateAt = '2026-08-07T00:00:00.000Z';
      const repository = new FakeProfileRepository([buildProfile(existingOptions)], 'profile-refresh-retain-throw');
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(),
        new FakeCoreService(),
        new FakeClock(['2026-08-07T01:00:00.000Z'])
      );

      gateway.localResults.push(new AcquiredLocalSource(
        'Refreshable',
        'refresh-retain-throw.yaml',
        buildStagedSource('refresh-retain-throw', '/sandbox/cache/refresh-retain-throw.yaml')
      ));
      contentStore.scriptedRetainFailures.push(
        new ScriptedVoidFailure(true, new Error('retain current refresh from /sandbox/cache/refresh-retain-throw.yaml failed'))
      );

      const result = await useCase.execute(new RefreshCommand('profile-refresh-retain-throw'));

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('PERSISTENCE');
      expect(contentStore.discardedStages.length).assertEqual(1);
      expect(repository.savedProfiles.length).assertEqual(0);
      const currentProfile = repository.currentProfile('profile-refresh-retain-throw');
      expect(currentProfile?.currentRevision?.relativePath).assertEqual(previousCurrent.relativePath);
      expect(currentProfile?.failedCandidate?.relativePath).assertEqual(previousFailed.relativePath);
      assertNoPlaintextLeak(result.error.technicalDetail, ['/sandbox/cache/refresh-retain-throw.yaml']);
    });

    it('mapsUnexpectedRefreshFailedCandidateRetainThrowsToFailedPersistenceResultWithoutDroppingExistingRefs', 0, async () => {
      const previousCurrent = buildRevision('profiles/remote/current.yaml', '2026-08-07T00:00:00.000Z');
      const previousFailed = buildRevision('profiles/remote/failed.yaml', '2026-08-07T00:00:10.000Z');
      const existingOptions = new ProfileFixtureOptions();
      existingOptions.id = 'profile-remote-refresh-failed-retain-throw';
      existingOptions.name = 'Remote';
      existingOptions.sourceKind = 'REMOTE_URL';
      existingOptions.sourceDisplay = 'https://remote.example.com';
      existingOptions.sourceSecretRef = 'secret-remote-existing';
      existingOptions.currentRevision = previousCurrent;
      existingOptions.failedCandidate = previousFailed;
      existingOptions.availability = 'VALID';
      existingOptions.createdAt = '2026-08-07T00:00:00.000Z';
      existingOptions.updatedAt = '2026-08-07T00:00:30.000Z';
      existingOptions.lastSuccessfulUpdateAt = '2026-08-07T00:00:00.000Z';
      const repository = new FakeProfileRepository(
        [buildProfile(existingOptions)],
        'profile-remote-refresh-failed-retain-throw'
      );
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const secretStore = new FakeSubscriptionSecretStore();
      const coreService = new FakeCoreService();
      const useCase: RefreshProfileUseCase = createRefreshUseCase(
        repository,
        contentStore,
        gateway,
        secretStore,
        coreService,
        new FakeClock(['2026-08-07T01:00:00.000Z'])
      );

      secretStore.scriptedDecryptResults.push(new ScriptedStringFailure(false, 'HTTPS_SUBSCRIPTION_CREDENTIALS'));
      gateway.remoteResults.push(new AcquiredRemoteSource(
        'Remote',
        'https://remote.example.com',
        buildStagedSource('refresh-remote-failed-retain', '/sandbox/cache/refresh-remote-failed-retain.yaml')
      ));
      coreService.scriptedResults.push(
        new ScriptedVoidFailure(true, buildCoreError('CMFA_INVALID_ARGUMENT', 'invalid bearer hunter2', false))
      );
      contentStore.scriptedRetainFailures.push(
        new ScriptedVoidFailure(
          true,
          new Error('retain failed candidate for https://user:secret@remote.example.com/path?token=abc123 failed')
        )
      );

      const result = await useCase.execute(new RefreshCommand('profile-remote-refresh-failed-retain-throw', false));

      expect(result.kind).assertEqual('FAILED');
      if (result.kind !== 'FAILED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.error.stage).assertEqual('PERSISTENCE');
      expect(contentStore.discardedStages.length).assertEqual(1);
      expect(repository.savedProfiles.length).assertEqual(0);
      expect(secretStore.removedRefs.length).assertEqual(0);
      const currentProfile = repository.currentProfile('profile-remote-refresh-failed-retain-throw');
      expect(currentProfile?.currentRevision?.relativePath).assertEqual(previousCurrent.relativePath);
      expect(currentProfile?.failedCandidate?.relativePath).assertEqual(previousFailed.relativePath);
      const snapshot = buildRemoteStateSnapshot(gateway, secretStore, repository);
      assertNoPlaintextLeak(snapshot, ['user:secret', 'abc123', '/path', 'token=']);
      assertNoPlaintextLeak(result.error.technicalDetail, ['user:secret', 'abc123', '/path', 'token=']);
    });

    it('serializesConcurrentMutationsThroughTheCommandQueue', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const gateway = new FakeProfileSourceGateway();
      const coreService = new FakeCoreService();
      const firstSave = createDeferred<void>();
      const firstSaveStarted = createDeferred<void>();
      repository.saveDeferreds.push(firstSave);
      repository.saveStartedDeferreds.push(firstSaveStarted);
      const useCase: ImportProfileUseCase = createImportUseCase(
        repository,
        contentStore,
        gateway,
        new FakeSubscriptionSecretStore(),
        coreService,
        new FakeClock([
          '2026-08-07T00:00:00.000Z',
          '2026-08-07T00:00:01.000Z',
          '2026-08-07T00:00:02.000Z',
          '2026-08-07T00:00:03.000Z'
        ]),
        new FakeIdGenerator(['profile-queue-1', 'profile-queue-2']),
        createQueue()
      );

      gateway.localResults.push(new AcquiredLocalSource('One', 'one.yaml', buildStagedSource('queue-one', '/sandbox/cache/queue-one.yaml')));
      gateway.localResults.push(new AcquiredLocalSource('Two', 'two.yaml', buildStagedSource('queue-two', '/sandbox/cache/queue-two.yaml')));

      const first = useCase.executeLocal(new LocalImportCommand());
      const second = useCase.executeLocal(new LocalImportCommand());
      await firstSaveStarted.promise;

      expect(gateway.localCommands.length).assertEqual(1);
      expect(repository.maxSaveConcurrency).assertEqual(1);

      firstSave.resolve(undefined);
      const firstResult = await first;
      const secondResult = await second;

      expect(firstResult.kind).assertEqual('CREATED');
      expect(secondResult.kind).assertEqual('CREATED');
      if (firstResult.kind !== 'CREATED' || secondResult.kind !== 'CREATED') {
        expect(false).assertTrue();
        return;
      }
      expect(gateway.localCommands.length).assertEqual(2);
      expect(repository.maxSaveConcurrency).assertEqual(1);
    });

    it('continuesProcessingQueuedCommandsAfterTheFirstCommandRejects', 0, async () => {
      const queue = createQueue();
      const firstStarted = createDeferred<void>();
      const releaseFirst = createDeferred<void>();
      let currentOverlap = 0;
      let maxOverlap = 0;
      let secondRan = false;

      const first = queue.execute(async () => {
        currentOverlap += 1;
        maxOverlap = Math.max(maxOverlap, currentOverlap);
        firstStarted.resolve(undefined);
        await releaseFirst.promise;
        currentOverlap -= 1;
        throw new Error('first failed');
      });
      const second = queue.execute(async () => {
        currentOverlap += 1;
        maxOverlap = Math.max(maxOverlap, currentOverlap);
        secondRan = true;
        currentOverlap -= 1;
        return 'second-result';
      });

      await firstStarted.promise;
      expect(secondRan).assertFalse();

      releaseFirst.resolve(undefined);

      let firstMessage = '';
      try {
        await first;
      } catch (error) {
        firstMessage = error instanceof Error ? error.message : '';
      }
      const secondResult = await second;

      expect(firstMessage).assertEqual('first failed');
      expect(secondResult).assertEqual('second-result');
      expect(secondRan).assertTrue();
      expect(maxOverlap).assertEqual(1);
    });

    it('reconcilesEveryCurrentAndFailedRevisionFromRepositoryOnStartup', 0, async () => {
      const firstCurrent = buildRevision('profiles/one/current.yaml', '2026-08-07T00:00:00.000Z');
      const firstFailed = buildRevision('profiles/one/failed.yaml', '2026-08-07T00:00:10.000Z');
      const secondCurrent = buildRevision('profiles/two/current.yaml', '2026-08-07T00:00:20.000Z');

      const firstOptions = new ProfileFixtureOptions();
      firstOptions.id = 'one';
      firstOptions.name = 'One';
      firstOptions.currentRevision = firstCurrent;
      firstOptions.failedCandidate = firstFailed;
      firstOptions.availability = 'UPDATE_FAILED_USING_VALID';
      firstOptions.sourceDisplay = 'one.yaml';

      const secondOptions = new ProfileFixtureOptions();
      secondOptions.id = 'two';
      secondOptions.name = 'Two';
      secondOptions.currentRevision = secondCurrent;
      secondOptions.failedCandidate = null;
      secondOptions.availability = 'VALID';
      secondOptions.sourceDisplay = 'two.yaml';

      const repository = new FakeProfileRepository([buildProfile(firstOptions), buildProfile(secondOptions)]);
      const contentStore = new FakeProfileContentStore();
      const service: ProfileCommitService = createCommitService(
        createCommitServiceDependencies(repository, contentStore, new FakeClock(['2026-08-07T01:00:00.000Z']))
      );

      await service.reconcileStoredContent();

      expect(contentStore.reconcileCalls.length).assertEqual(1);
      const revisions = contentStore.reconcileCalls[0];
      expect(revisions.length).assertEqual(3);
      expect(revisions[0].relativePath).assertEqual(firstCurrent.relativePath);
      expect(revisions[1].relativePath).assertEqual(firstFailed.relativePath);
      expect(revisions[2].relativePath).assertEqual(secondCurrent.relativePath);
    });

    it('deduplicatesReferencedRevisionPathsBeforeReconcilingStoredContent', 0, async () => {
      const duplicateCurrent = buildRevision('profiles/shared/current.yaml', '2026-08-07T00:00:00.000Z');
      const duplicateFailed = buildRevision('profiles/shared/current.yaml', '2026-08-07T00:00:00.000Z');
      const uniqueRevision = buildRevision('profiles/shared/failed.yaml', '2026-08-07T00:00:10.000Z');

      const firstOptions = new ProfileFixtureOptions();
      firstOptions.id = 'one';
      firstOptions.name = 'One';
      firstOptions.currentRevision = duplicateCurrent;
      firstOptions.failedCandidate = duplicateFailed;
      firstOptions.availability = 'UPDATE_FAILED_USING_VALID';
      firstOptions.sourceDisplay = 'one.yaml';

      const secondOptions = new ProfileFixtureOptions();
      secondOptions.id = 'two';
      secondOptions.name = 'Two';
      secondOptions.currentRevision = buildRevision('profiles/shared/current.yaml', '2026-08-07T00:00:00.000Z');
      secondOptions.failedCandidate = uniqueRevision;
      secondOptions.availability = 'UPDATE_FAILED_USING_VALID';
      secondOptions.sourceDisplay = 'two.yaml';

      const repository = new FakeProfileRepository([buildProfile(firstOptions), buildProfile(secondOptions)]);
      const contentStore = new FakeProfileContentStore();
      const service: ProfileCommitService = createCommitService(
        createCommitServiceDependencies(repository, contentStore, new FakeClock(['2026-08-07T01:00:00.000Z']))
      );

      await service.reconcileStoredContent();

      expect(contentStore.reconcileCalls.length).assertEqual(1);
      const revisions = contentStore.reconcileCalls[0];
      expect(revisions.length).assertEqual(2);
      expect(revisions[0].relativePath).assertEqual('profiles/shared/current.yaml');
      expect(revisions[1].relativePath).assertEqual(uniqueRevision.relativePath);
    });

    it('buildSavedProfilePreservesAutoUpdateInterval', 0, () => {
      const current = buildRevision('profiles/saved/current.yaml', '2026-08-07T00:00:00.000Z');
      const options = new ProfileFixtureOptions();
      options.id = 'saved-profile';
      options.name = 'Saved Profile';
      options.sourceKind = 'REMOTE_URL';
      options.sourceDisplay = 'https://saved.example.com';
      options.sourceSecretRef = 'secret-saved';
      options.currentRevision = current;
      options.availability = 'VALID';
      options.createdAt = '2026-08-07T00:00:00.000Z';
      options.updatedAt = '2026-08-07T00:01:00.000Z';
      options.lastSuccessfulUpdateAt = '2026-08-07T00:01:00.000Z';
      const repository = new FakeProfileRepository([buildProfile(options)]);
      const contentStore = new FakeProfileContentStore();
      const service: ProfileCommitService = createCommitService(
        createCommitServiceDependencies(repository, contentStore, new FakeClock(['2026-08-07T01:00:00.000Z']))
      );

      const saved = service.buildSavedProfile(buildProfileWithInterval(options, 180000));

      expect(saved.autoUpdateIntervalMs).assertEqual(180000);
    });
  });
}

function createCommitServiceDependencies(
  repository: ProfileRepository,
  contentStore: ProfileContentStore,
  clock: Clock
): CommitServiceDependencies {
  return new CommitServiceDependencies(repository, contentStore, clock);
}

function createQueue(): SerialCommandQueue {
  return new SerialCommandQueue();
}

function createCommitService(dependencies: CommitServiceDependencies): ProfileCommitService {
  return new ProfileCommitService(dependencies);
}

function createImportUseCase(
  repository: ProfileRepository,
  contentStore: ProfileContentStore,
  gateway: ProfileSourceGateway,
  secretStore: SubscriptionSecretStore,
  coreService: FakeCoreService,
  clock: Clock,
  idGenerator: IdGenerator,
  queue: SerialCommandQueue
): ImportProfileUseCase {
  return new ImportProfileUseCase(new ImportUseCaseDependencies(
    repository,
    contentStore,
    gateway,
    secretStore,
    coreService,
    clock,
    idGenerator,
    queue,
    createCommitService(createCommitServiceDependencies(repository, contentStore, clock))
  ));
}

function createRefreshUseCase(
  repository: ProfileRepository,
  contentStore: ProfileContentStore,
  gateway: ProfileSourceGateway,
  secretStore: SubscriptionSecretStore,
  coreService: FakeCoreService,
  clock: Clock,
  leasePort: ProfileRefreshLeasePort = new FakeProfileRefreshLeasePort(),
  idGenerator: IdGenerator = new FakeIdGenerator(['lease-owner-default'])
): RefreshProfileUseCase {
  return new RefreshProfileUseCase(new RefreshUseCaseDependencies(
    repository,
    contentStore,
    gateway,
    secretStore,
    coreService,
    clock,
    createQueue(),
    createCommitService(createCommitServiceDependencies(repository, contentStore, clock)),
    new ProductionLeasedRemoteProfileRefresher({
      leasePort,
      clock,
      idGenerator
    })
  ));
}
