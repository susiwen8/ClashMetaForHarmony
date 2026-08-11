import { describe, expect, it } from '@ohos/hypium';
import type {
  Clock,
  IdGenerator,
  ImportProfileUseCaseDependencies as PortImportProfileUseCaseDependencies,
  LocalAcquireCommand as PortLocalAcquireCommand,
  ProfileCommitServiceDependencies as PortProfileCommitServiceDependencies,
  ProfileContentStore,
  ProfileRepository,
  ProfileSourceGateway,
  RefreshProfileCommand as PortRefreshProfileCommand,
  RefreshProfileUseCaseDependencies as PortRefreshProfileUseCaseDependencies,
  RemoteImportCommand as PortRemoteImportCommand,
  SubscriptionSecretStore
} from '../../Index';
import { SerialCommandQueue, ProfileCommitService, ImportProfileUseCase, RefreshProfileUseCase } from '../../Index';
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

  constructor(
    repository: ProfileRepository,
    contentStore: ProfileContentStore,
    sourceGateway: ProfileSourceGateway,
    secretStore: SubscriptionSecretStore,
    coreService: FakeCoreService,
    clock: Clock,
    queue: SerialCommandQueue,
    commitService: ProfileCommitService
  ) {
    this.repository = repository;
    this.contentStore = contentStore;
    this.sourceGateway = sourceGateway;
    this.secretStore = secretStore;
    this.coreService = coreService;
    this.clock = clock;
    this.queue = queue;
    this.commitService = commitService;
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
      const timeline = new FakeOperationTimeline();
      const repository = new FakeProfileRepository([buildProfile(existingOptions)], 'profile-refresh-valid', timeline);
      const contentStore = new FakeProfileContentStore(timeline);
      const gateway = new FakeProfileSourceGateway(timeline);
      const coreService = new FakeCoreService(timeline);
      const firstSave: Deferred<void> = createDeferred<void>();
      repository.saveDeferreds.push(firstSave);
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
      firstSave.resolve(undefined);
      const result = await pending;

      expect(result.kind).assertEqual('UPDATED');
      if (result.kind !== 'UPDATED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.profile.availability).assertEqual('VALID');
      expect(result.profile.currentRevision?.relativePath.includes('refresh-valid')).assertTrue();
      expect(result.profile.failedCandidate === null).assertTrue();
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
      const repository = new FakeProfileRepository([buildProfile(existingOptions)], 'profile-refresh-invalid');
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
      const repository = new FakeProfileRepository([buildProfile(existingOptions)], 'profile-remote-refresh');
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
      expect(result.profile.lastError?.code).assertEqual('SOURCE_SECRET_MISSING');
      expect(result.profile.lastError?.stage).assertEqual('PERSISTENCE');
      expect(result.profile.lastError?.retryable).assertFalse();
      expect(gateway.remoteCommands.length).assertEqual(0);
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
      expect(timeline.joined()).assertEqual('getProfile>decryptSource>saveProfile');
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
  clock: Clock
): RefreshProfileUseCase {
  return new RefreshProfileUseCase(new RefreshUseCaseDependencies(
    repository,
    contentStore,
    gateway,
    secretStore,
    coreService,
    clock,
    createQueue(),
    createCommitService(createCommitServiceDependencies(repository, contentStore, clock))
  ));
}
