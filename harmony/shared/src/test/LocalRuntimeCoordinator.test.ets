import { describe, expect, it } from '@ohos/hypium';
import {
  type AppError,
  createProfile,
  createProfileRevision,
  LocalRuntimeCoordinator,
  type Clock,
  type CoreEvent,
  type CoreService,
  type LocalRuntimeCoordinatorDependencies,
  type LocalOptions,
  type Profile,
  type ProfileContentStore,
  type ProfileRepository,
  type ProfileRevision,
  type StagedSource,
  type RuntimeSnapshot
} from '../../Index';

interface RuntimeCoordinatorFailedResultContract {
  kind: 'FAILED';
}

interface RuntimeCoordinatorStartedResultContract {
  kind: 'STARTED';
  snapshot: RuntimeCoordinatorStartedSnapshotContract;
}

interface RuntimeCoordinatorStartedSnapshotContract {
  latest: RuntimeSnapshot;
}

interface RuntimeCoordinatorStoppedResultContract {
  kind: 'STOPPED';
}

type RuntimeCoordinatorStartResultContract =
  | RuntimeCoordinatorStartedResultContract
  | RuntimeCoordinatorFailedResultContract;

type RuntimeCoordinatorStopResultContract =
  | RuntimeCoordinatorStoppedResultContract
  | RuntimeCoordinatorFailedResultContract;

interface RuntimeCoordinatorSnapshotContract {
  state: string;
  latest: RuntimeSnapshot;
  lastError?: AppError | null;
}

interface RuntimeCoordinatorContract {
  initialize(): Promise<void>;
  current(): RuntimeCoordinatorSnapshotContract;
  start(): Promise<RuntimeCoordinatorStartResultContract>;
  stop(): Promise<RuntimeCoordinatorStopResultContract>;
  dispose(): void;
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

class FakeProfileRepository implements ProfileRepository {
  readonly log: string[] = [];
  private readonly profiles: Map<string, Profile> = new Map();
  private activeIdValue: string | undefined;

  constructor(seedProfiles: Profile[], activeId?: string) {
    for (let index = 0; index < seedProfiles.length; index += 1) {
      this.profiles.set(seedProfiles[index].id, cloneProfile(seedProfiles[index]));
    }
    this.activeIdValue = activeId;
  }

  async list(): Promise<Profile[]> {
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
    this.profiles.set(profile.id, cloneProfile(profile));
  }

  async deleteAndClearActive(_id: string): Promise<void> {
  }

  async getActiveId(): Promise<string | undefined> {
    this.log.push('repository.getActiveId');
    return this.activeIdValue;
  }

  async setActiveId(id: string | undefined): Promise<void> {
    this.activeIdValue = id;
  }

  readActiveId(): string | undefined {
    return this.activeIdValue;
  }
}

class FakeProfileContentStore implements ProfileContentStore {
  readonly log: string[] = [];
  readonly resolvedPaths: Map<string, string> = new Map();

  async retain(_profileId: string, _staged: StagedSource, _kind: 'CURRENT' | 'FAILED_CANDIDATE'): Promise<ProfileRevision> {
    throw new Error('retain should stay unused in runtime tests');
  }

  async discard(_staged: StagedSource): Promise<void> {
  }

  async removeRevision(_revision: ProfileRevision): Promise<void> {
  }

  async removeProfile(_profileId: string): Promise<void> {
  }

  async reconcile(_referenced: ProfileRevision[]): Promise<void> {
  }

  resolveCorePath(revision: ProfileRevision): string {
    this.log.push(`content.resolveCorePath:${revision.relativePath}`);
    const resolved: string | undefined = this.resolvedPaths.get(revision.relativePath);
    return resolved ?? `/sandbox/${revision.relativePath}`;
  }
}

class FakeCoreService implements CoreService {
  readonly log: string[] = [];
  readonly startCalls: LocalOptions[] = [];
  readonly stopCalls: number[] = [];
  readonly subscribeIds: number[] = [];
  readonly unsubscribeIds: number[] = [];
  readonly callbacks: Map<number, (event: CoreEvent) => void> = new Map();
  runtimeSnapshotValue: RuntimeSnapshot = buildRuntimeSnapshot('STOPPED', '', '', '', 0);
  startDeferred?: DeferredRuntimeSnapshot;
  stopDeferred?: DeferredRuntimeSnapshot;
  validateError?: Error;
  loadError?: Error;
  private nextSubscriptionId: number = 1;

  hello(): string {
    return 'hello';
  }

  async coreVersion(): Promise<string> {
    return 'core';
  }

  async validateConfiguration(path: string): Promise<void> {
    this.log.push(`core.validate:${path}`);
    if (this.validateError !== undefined) {
      throw this.validateError;
    }
  }

  async loadConfiguration(path: string): Promise<void> {
    this.log.push(`core.load:${path}`);
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
    this.log.push('core.stopRuntime');
    this.stopCalls.push(this.stopCalls.length + 1);
    if (this.stopDeferred !== undefined) {
      return await this.stopDeferred.promise;
    }
    return cloneRuntimeSnapshot(this.runtimeSnapshotValue);
  }

  runtimeSnapshot(): RuntimeSnapshot {
    this.log.push('core.runtimeSnapshot');
    return cloneRuntimeSnapshot(this.runtimeSnapshotValue);
  }

  subscribe(callback: (event: CoreEvent) => void): number {
    const subscriptionId: number = this.nextSubscriptionId;
    this.nextSubscriptionId += 1;
    this.subscribeIds.push(subscriptionId);
    this.log.push(`core.subscribe:${subscriptionId}`);
    this.callbacks.set(subscriptionId, callback);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.unsubscribeIds.push(subscriptionId);
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
  return `2026-08-11T13:${minuteText}:00.000Z`;
}

function buildDigest(seed: string): string {
  const hexAlphabet: string = '0123456789abcdef';
  let digest: string = '';
  let offset: number = seed.length % hexAlphabet.length;
  while (digest.length < 64) {
    digest += hexAlphabet[offset];
    offset = (offset + 5) % hexAlphabet.length;
  }
  return digest;
}

function buildRevision(id: string): ProfileRevision {
  return createProfileRevision(`profiles/${id}.yaml`, buildDigest(id), 64, buildTimestamp(1));
}

function buildProfileRecord(id: string, currentRevision: ProfileRevision | null): Profile {
  return createProfile({
    id,
    name: `Profile ${id}`,
    sourceKind: 'LOCAL_FILE',
    sourceDisplay: `${id}.yaml`,
    currentRevision,
    failedCandidate: null,
    availability: currentRevision === null ? 'INVALID' : 'VALID',
    lastError: null,
    createdAt: buildTimestamp(2),
    updatedAt: buildTimestamp(3),
    lastSuccessfulUpdateAt: currentRevision === null ? null : buildTimestamp(3)
  });
}

function buildRuntimeSnapshot(
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR',
  activeConfigPath: string,
  httpAddress: string,
  socksAddress: string,
  mixedPort: number,
  lastError?: string
): RuntimeSnapshot {
  return {
    state,
    activeConfigPath,
    httpAddress,
    socksAddress,
    lastError: lastError ?? '',
    mixedPort
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

function createCoordinator(
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

export default function localRuntimeCoordinatorTestsuite() {
  describe('LocalRuntimeCoordinatorTest', () => {
    it('coldStartPublishesStoppedWhilePreservingActiveProfileAndAvoidingAutoStart', 0, async () => {
      const revision = buildRevision('active');
      const repository = new FakeProfileRepository([buildProfileRecord('active', revision)], 'active');
      const contentStore = new FakeProfileContentStore();
      const coreService = new FakeCoreService();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING', '/sandbox/profiles/active.yaml', '127.0.0.1:9000', '127.0.0.1:9001', 7890);
      const coordinator = createCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(4), buildTimestamp(5)]
      );

      await coordinator.initialize();
      const snapshot = coordinator.current();

      expect(snapshot.state).assertEqual('STOPPED');
      expect(snapshot.latest.httpAddress).assertEqual('');
      expect(repository.readActiveId()).assertEqual('active');
      expect(contentStore.log.length).assertEqual(0);
      expect(coreService.startCalls.length).assertEqual(0);
      expect(coreService.subscribeIds.length).assertEqual(1);
      expect(coreService.startCalls.length).assertEqual(0);
    });

    it('startResolvesValidatesLoadsAndStartsOnPort7890', 0, async () => {
      const revision = buildRevision('active');
      const repository = new FakeProfileRepository([buildProfileRecord('active', revision)], 'active');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/active.yaml');
      const coreService = new FakeCoreService();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING', '/sandbox/profiles/active.yaml', '127.0.0.1:8080', '127.0.0.1:1080', 7890);
      const coordinator = createCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(6), buildTimestamp(7), buildTimestamp(8)]
      );

      await coordinator.initialize();
      const result = await coordinator.start();

      expect(result.kind).assertEqual('STARTED');
      if (result.kind !== 'STARTED') {
        expect(false).assertTrue();
        return;
      }
      expect(coreService.startCalls.length).assertEqual(1);
      expect(coreService.startCalls[0].mixedPort).assertEqual(7890);
      expect(result.snapshot.latest.httpAddress).assertEqual('127.0.0.1:8080');
    });

    it('duplicateStartSharesOneCoreInvocationAndStopDuringStartIsRejected', 0, async () => {
      const revision = buildRevision('active');
      const repository = new FakeProfileRepository([buildProfileRecord('active', revision)], 'active');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/active.yaml');
      const coreService = new FakeCoreService();
      coreService.startDeferred = new DeferredRuntimeSnapshot();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING', '/sandbox/profiles/active.yaml', '127.0.0.1:8080', '127.0.0.1:1080', 7890);
      const coordinator = createCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(9), buildTimestamp(10), buildTimestamp(11), buildTimestamp(12)]
      );

      await coordinator.initialize();
      const first = coordinator.start();
      const second = coordinator.start();
      const stopWhileStarting = await coordinator.stop();
      coreService.startDeferred.resolve(buildRuntimeSnapshot('RUNNING', '/sandbox/ignored.yaml', '127.0.0.1:1', '127.0.0.1:2', 7890));
      const firstResult = await first;
      const secondResult = await second;

      expect(firstResult.kind).assertEqual('STARTED');
      expect(secondResult.kind).assertEqual('STARTED');
      expect(stopWhileStarting.kind).assertEqual('FAILED');
      expect(coreService.startCalls.length).assertEqual(1);
      expect(coreService.stopCalls.length).assertEqual(0);
    });

    it('runtimeSnapshotAddressesBeatStaleCommandResultsAndErrorEventStaysSafe', 0, async () => {
      const revision = buildRevision('active');
      const repository = new FakeProfileRepository([buildProfileRecord('active', revision)], 'active');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/active.yaml');
      const coreService = new FakeCoreService();
      coreService.startDeferred = new DeferredRuntimeSnapshot();
      const coordinator = createCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(13), buildTimestamp(14), buildTimestamp(15), buildTimestamp(16), buildTimestamp(17)]
      );

      await coordinator.initialize();
      const start = coordinator.start();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING', '/sandbox/profiles/from-event.yaml', '127.0.0.1:8080', '127.0.0.1:1080', 7890);
      coreService.emitRuntime('RUNNING', 'started');
      coreService.startDeferred.resolve(buildRuntimeSnapshot('STOPPED', '', '', '', 0));
      await start;

      const runningSnapshot = coordinator.current();
      expect(runningSnapshot.latest.activeConfigPath).assertEqual('/sandbox/profiles/from-event.yaml');

      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('ERROR', '/sandbox/profiles/from-event.yaml', '127.0.0.1:8080', '127.0.0.1:1080', 7890, '/Users/demo/secret');
      coreService.emitRuntime('ERROR', '/Users/demo/secret');
      const errorSnapshot = coordinator.current();

      expect(errorSnapshot.state).assertEqual('ERROR');
      expect(errorSnapshot.lastError?.technicalDetail.includes('/Users/demo')).assertFalse();
    });

    it('duplicateStopSharesOneCoreInvocationAndStoppedEventWinsOverStaleStopResult', 0, async () => {
      const revision = buildRevision('active');
      const repository = new FakeProfileRepository([buildProfileRecord('active', revision)], 'active');
      const contentStore = new FakeProfileContentStore();
      contentStore.resolvedPaths.set(revision.relativePath, '/sandbox/profiles/active.yaml');
      const coreService = new FakeCoreService();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('RUNNING', '/sandbox/profiles/active.yaml', '127.0.0.1:8080', '127.0.0.1:1080', 7890);
      coreService.stopDeferred = new DeferredRuntimeSnapshot();
      const coordinator = createCoordinator(
        repository,
        contentStore,
        coreService,
        [buildTimestamp(18), buildTimestamp(19), buildTimestamp(20), buildTimestamp(21)]
      );

      await coordinator.initialize();
      coreService.emitRuntime('RUNNING', 'running');
      const first = coordinator.stop();
      const second = coordinator.stop();
      coreService.runtimeSnapshotValue = buildRuntimeSnapshot('STOPPED', '', '', '', 0);
      coreService.emitRuntime('STOPPED', 'stopped');
      coreService.stopDeferred.resolve(buildRuntimeSnapshot('RUNNING', '/sandbox/stale.yaml', '127.0.0.1:1', '127.0.0.1:2', 7890));
      const firstResult = await first;
      const secondResult = await second;

      expect(firstResult.kind).assertEqual('STOPPED');
      expect(secondResult.kind).assertEqual('STOPPED');
      expect(coreService.stopCalls.length).assertEqual(1);
      expect(coordinator.current().state).assertEqual('STOPPED');
    });

    it('initializeSubscribesOnceAndDisposeUnsubscribesOnceWithoutFurtherCallbacks', 0, async () => {
      const revision = buildRevision('active');
      const repository = new FakeProfileRepository([buildProfileRecord('active', revision)], 'active');
      const coreService = new FakeCoreService();
      const coordinator = createCoordinator(
        repository,
        new FakeProfileContentStore(),
        coreService,
        [buildTimestamp(22), buildTimestamp(23), buildTimestamp(24)]
      );

      await coordinator.initialize();
      await coordinator.initialize();
      coordinator.dispose();
      coordinator.dispose();

      expect(coreService.subscribeIds.length).assertEqual(1);
      expect(coreService.unsubscribeIds.length).assertEqual(1);
    });
  });
}
