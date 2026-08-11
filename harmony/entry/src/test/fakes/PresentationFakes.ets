import {
  ImportProfileUseCase,
  LocalRuntimeCoordinator,
  ManageProfileUseCases,
  ProfileApplication,
  type ProfileApplicationDependencies,
  ProfileCommitService,
  RefreshProfileUseCase,
  SerialCommandQueue,
  type AppError,
  type AppErrorStage,
  type Clock,
  type CoreEvent,
  type CoreService,
  type IdGenerator,
  type LocalAcquireCommand,
  type LocalRuntimeCoordinatorSnapshot,
  type LocalRuntimeStartedResult,
  type LocalRuntimeStoppedResult,
  type LocalOptions,
  type LocalProfileAcquisition,
  type LocalRuntimeStartResult,
  type LocalRuntimeStopResult,
  type Profile,
  type ProfileApplicationErrorSnapshot,
  type ProfileApplicationListener,
  type ProfileApplicationProfileSnapshot,
  type ProfileApplicationSnapshot,
  type ProfileApplicationRuntimeLatestSnapshot,
  type ProfileApplicationRuntimeSnapshot,
  type ProfileContentStore,
  type ProfileRepository,
  type ProfileRevision,
  type ProfileSourceGateway,
  type RemoteAcquireCommand,
  type RemoteProfileAcquisition,
  type RuntimeSnapshot,
  type StagedSource,
  type SubscriptionSecretStore
} from '@cmfa/shared';

interface ApplicationSnapshotOptions {
  httpAddress?: string;
  socksAddress?: string;
  runtimeError?: ProfileApplicationErrorSnapshot | null;
  latestRuntimeError?: string;
  error?: ProfileApplicationErrorSnapshot | null;
}

class DeferredCommand {
  readonly promise: Promise<void>;
  private resolveRef?: () => void;

  constructor() {
    this.promise = new Promise<void>((resolve) => {
      this.resolveRef = resolve;
    });
  }

  resolve(): void {
    this.resolveRef?.();
  }
}

class FixedClock implements Clock {
  now(): string {
    return '2026-08-11T12:30:00.000Z';
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

class InertContentStore implements ProfileContentStore {
  async retain(_profileId: string, _staged: StagedSource, _kind: 'CURRENT' | 'FAILED_CANDIDATE'): Promise<ProfileRevision> {
    throw new Error('retain should stay unused in presentation tests');
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
    return revision.relativePath;
  }
}

class InertSourceGateway implements ProfileSourceGateway {
  async acquireLocal(_command: LocalAcquireCommand): Promise<LocalProfileAcquisition> {
    throw new Error('local acquire should stay unused in presentation tests');
  }

  async acquireRemote(_command: RemoteAcquireCommand): Promise<RemoteProfileAcquisition> {
    throw new Error('remote acquire should stay unused in presentation tests');
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

class InertCoreService implements CoreService {
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
    return createRuntimeModel('STOPPED', '', '', '');
  }

  async stopRuntime(): Promise<RuntimeSnapshot> {
    return createRuntimeModel('STOPPED', '', '', '');
  }

  runtimeSnapshot(): RuntimeSnapshot {
    return createRuntimeModel('STOPPED', '', '', '');
  }

  subscribe(_callback: (event: CoreEvent) => void): number {
    return 1;
  }

  unsubscribe(_subscriptionId: number): void {
  }
}

class ProfileApplicationErrorSnapshotValue implements ProfileApplicationErrorSnapshot {
  code: string = '';
  stage: AppErrorStage = 'PERSISTENCE';
  userMessageResource: string = '';
  technicalDetail: string = '';
  timestamp: string = '';
  retryable: boolean = false;
}

class ProfileApplicationRuntimeLatestSnapshotValue implements ProfileApplicationRuntimeLatestSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR' = 'STOPPED';
  httpAddress: string = '';
  socksAddress: string = '';
  lastError: string = '';
  mixedPort: number = 0;
}

class ProfileApplicationRuntimeSnapshotValue implements ProfileApplicationRuntimeSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR' = 'STOPPED';
  latest: ProfileApplicationRuntimeLatestSnapshot = new ProfileApplicationRuntimeLatestSnapshotValue();
  lastError: ProfileApplicationErrorSnapshot | null = null;
}

class ProfileApplicationProfileSnapshotValue implements ProfileApplicationProfileSnapshot {
  id: string = '';
  name: string = '';
  sourceDisplay: string = '';
  availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID' = 'INVALID';
  updatedAt: string = '';
  hasCurrentRevision: boolean = false;
}

class ProfileApplicationSnapshotValue implements ProfileApplicationSnapshot {
  status: 'LOADING' | 'READY' | 'ERROR' = 'LOADING';
  profiles: ProfileApplicationProfileSnapshot[] = [];
  activeProfileId?: string;
  runtime: ProfileApplicationRuntimeSnapshot = new ProfileApplicationRuntimeSnapshotValue();
  error: ProfileApplicationErrorSnapshot | null = null;
}

class LocalRuntimeCoordinatorSnapshotValue implements LocalRuntimeCoordinatorSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR' = 'STOPPED';
  latest: RuntimeSnapshot = createRuntimeModel('STOPPED', '', '', '');
  lastError: AppError | null = null;
}

class StartedResultValue implements LocalRuntimeStartedResult {
  kind: 'STARTED' = 'STARTED';
  snapshot: LocalRuntimeCoordinatorSnapshot = createCoordinatorSnapshot();
}

class StoppedResultValue implements LocalRuntimeStoppedResult {
  kind: 'STOPPED' = 'STOPPED';
  snapshot: LocalRuntimeCoordinatorSnapshot = createCoordinatorSnapshot();
}

export class PresentationTestApplication extends ProfileApplication {
  readonly commandLog: string[] = [];
  private readonly presentationListeners: Map<number, ProfileApplicationListener> = new Map();
  private nextPresentationListenerId: number = 0;
  private currentSnapshot: ProfileApplicationSnapshot;
  private startDeferred?: DeferredCommand;
  private stopDeferred?: DeferredCommand;

  constructor(snapshot?: ProfileApplicationSnapshot) {
    super(createDependencies());
    this.currentSnapshot = cloneApplicationSnapshot(snapshot ?? createApplicationSnapshot('LOADING', [], undefined, 'STOPPED'));
  }

  async initialize(): Promise<void> {
  }

  current(): ProfileApplicationSnapshot {
    return cloneApplicationSnapshot(this.currentSnapshot);
  }

  subscribe(listener: ProfileApplicationListener): number {
    this.nextPresentationListenerId += 1;
    this.presentationListeners.set(this.nextPresentationListenerId, listener);
    return this.nextPresentationListenerId;
  }

  unsubscribe(id: number): void {
    this.presentationListeners.delete(id);
  }

  listenerCount(): number {
    return this.presentationListeners.size;
  }

  deferStart(): DeferredCommand {
    const deferred: DeferredCommand = new DeferredCommand();
    this.startDeferred = deferred;
    return deferred;
  }

  deferStop(): DeferredCommand {
    const deferred: DeferredCommand = new DeferredCommand();
    this.stopDeferred = deferred;
    return deferred;
  }

  async startLocal(): Promise<LocalRuntimeStartResult> {
    this.commandLog.push('startLocal');
    if (this.startDeferred !== undefined) {
      const deferred: DeferredCommand = this.startDeferred;
      this.startDeferred = undefined;
      await deferred.promise;
    }
    return new StartedResultValue();
  }

  async stopLocal(): Promise<LocalRuntimeStopResult> {
    this.commandLog.push('stopLocal');
    if (this.stopDeferred !== undefined) {
      const deferred: DeferredCommand = this.stopDeferred;
      this.stopDeferred = undefined;
      await deferred.promise;
    }
    return new StoppedResultValue();
  }

  dispose(): void {
    this.presentationListeners.clear();
  }

  emitSnapshot(snapshot: ProfileApplicationSnapshot): void {
    this.currentSnapshot = cloneApplicationSnapshot(snapshot);
    const listeners: ProfileApplicationListener[] = [];
    this.presentationListeners.forEach((listener: ProfileApplicationListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](this.current());
    }
  }
}

export function createApplicationSnapshot(
  status: 'LOADING' | 'READY' | 'ERROR',
  profiles: ProfileApplicationProfileSnapshot[],
  activeProfileId: string | undefined,
  runtimeState: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR',
  options?: ApplicationSnapshotOptions
): ProfileApplicationSnapshot {
  const snapshot: ProfileApplicationSnapshotValue = new ProfileApplicationSnapshotValue();
  snapshot.status = status;
  snapshot.profiles = cloneProfiles(profiles);
  snapshot.activeProfileId = activeProfileId;
  snapshot.runtime = createRuntimeSnapshot(
    runtimeState,
    options?.httpAddress ?? '',
    options?.socksAddress ?? '',
    options?.latestRuntimeError ?? '',
    options?.runtimeError ?? null
  );
  snapshot.error = options?.error ?? null;
  return snapshot;
}

export function createProfileSnapshot(
  id: string,
  name: string,
  sourceDisplay: string,
  availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID',
  updatedAt: string,
  hasCurrentRevision: boolean
): ProfileApplicationProfileSnapshot {
  const snapshot: ProfileApplicationProfileSnapshotValue = new ProfileApplicationProfileSnapshotValue();
  snapshot.id = id;
  snapshot.name = name;
  snapshot.sourceDisplay = sourceDisplay;
  snapshot.availability = availability;
  snapshot.updatedAt = updatedAt;
  snapshot.hasCurrentRevision = hasCurrentRevision;
  return snapshot;
}

export function createRuntimeSnapshot(
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR',
  httpAddress: string,
  socksAddress: string,
  lastError: string,
  error: ProfileApplicationErrorSnapshot | null
): ProfileApplicationRuntimeSnapshot {
  const snapshot: ProfileApplicationRuntimeSnapshotValue = new ProfileApplicationRuntimeSnapshotValue();
  snapshot.state = state;
  snapshot.latest = createRuntimeLatestSnapshot(state, httpAddress, socksAddress, lastError);
  snapshot.lastError = error === null ? null : cloneError(error);
  return snapshot;
}

export function createSafeError(
  code: string,
  stage: 'IMPORT' | 'DOWNLOAD' | 'VALIDATION' | 'PERSISTENCE' | 'CORE_LOAD' | 'RUNTIME_START' | 'RUNTIME_STOP',
  technicalDetail: string
): ProfileApplicationErrorSnapshot {
  const snapshot: ProfileApplicationErrorSnapshotValue = new ProfileApplicationErrorSnapshotValue();
  snapshot.code = code;
  snapshot.stage = stage;
  snapshot.userMessageResource = `error.${stage.toLowerCase()}`;
  snapshot.technicalDetail = technicalDetail;
  snapshot.timestamp = '2026-08-11T12:30:00.000Z';
  snapshot.retryable = false;
  return snapshot;
}

function createDependencies(): ProfileApplicationDependencies {
  const repository: InertRepository = new InertRepository();
  const contentStore: InertContentStore = new InertContentStore();
  const sourceGateway: InertSourceGateway = new InertSourceGateway();
  const secretStore: InertSecretStore = new InertSecretStore();
  const coreService: InertCoreService = new InertCoreService();
  const clock: FixedClock = new FixedClock();
  const runtimeCoordinator = new LocalRuntimeCoordinator({
    repository,
    contentStore,
    coreService,
    clock
  });
  const commitService = new ProfileCommitService({
    repository,
    contentStore,
    clock
  });
  const queue = new SerialCommandQueue();
  const importUseCase = new ImportProfileUseCase({
    repository,
    contentStore,
    sourceGateway,
    secretStore,
    coreService,
    clock,
    idGenerator: new FixedIdGenerator(),
    queue,
    commitService
  });
  const refreshUseCase = new RefreshProfileUseCase({
    repository,
    contentStore,
    sourceGateway,
    secretStore,
    coreService,
    clock,
    queue,
    commitService
  });
  const manageProfileUseCases = new ManageProfileUseCases({
    repository,
    contentStore,
    secretStore,
    coreService,
    clock,
    runtimeCoordinator
  });
  return {
    importUseCase,
    refreshUseCase,
    manageProfileUseCases,
    runtimeCoordinator,
    commitService,
    repository
  };
}

function createRuntimeLatestSnapshot(
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR',
  httpAddress: string,
  socksAddress: string,
  lastError: string
): ProfileApplicationRuntimeLatestSnapshot {
  const snapshot: ProfileApplicationRuntimeLatestSnapshotValue = new ProfileApplicationRuntimeLatestSnapshotValue();
  snapshot.state = state;
  snapshot.httpAddress = httpAddress;
  snapshot.socksAddress = socksAddress;
  snapshot.lastError = lastError;
  snapshot.mixedPort = state === 'RUNNING' ? 7890 : 0;
  return snapshot;
}

function createRuntimeModel(
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR',
  httpAddress: string,
  socksAddress: string,
  lastError: string
): RuntimeSnapshot {
  return {
    state,
    activeConfigPath: '',
    httpAddress,
    socksAddress,
    lastError,
    mixedPort: state === 'RUNNING' ? 7890 : 0
  };
}

function cloneApplicationSnapshot(snapshot: ProfileApplicationSnapshot): ProfileApplicationSnapshot {
  const cloned: ProfileApplicationSnapshotValue = new ProfileApplicationSnapshotValue();
  cloned.status = snapshot.status;
  cloned.profiles = cloneProfiles(snapshot.profiles);
  cloned.activeProfileId = snapshot.activeProfileId;
  cloned.runtime = createRuntimeSnapshot(
    snapshot.runtime.state,
    snapshot.runtime.latest.httpAddress,
    snapshot.runtime.latest.socksAddress,
    snapshot.runtime.latest.lastError,
    snapshot.runtime.lastError
  );
  cloned.error = snapshot.error === null ? null : cloneError(snapshot.error);
  return cloned;
}

function createCoordinatorSnapshot(): LocalRuntimeCoordinatorSnapshot {
  const snapshot: LocalRuntimeCoordinatorSnapshotValue = new LocalRuntimeCoordinatorSnapshotValue();
  snapshot.state = 'STOPPED';
  snapshot.latest = createRuntimeModel('STOPPED', '', '', '');
  snapshot.lastError = null;
  return snapshot;
}

function cloneProfiles(profiles: ProfileApplicationProfileSnapshot[]): ProfileApplicationProfileSnapshot[] {
  const cloned: ProfileApplicationProfileSnapshot[] = [];
  for (let index: number = 0; index < profiles.length; index += 1) {
    cloned.push(
      createProfileSnapshot(
        profiles[index].id,
        profiles[index].name,
        profiles[index].sourceDisplay,
        profiles[index].availability,
        profiles[index].updatedAt,
        profiles[index].hasCurrentRevision
      )
    );
  }
  return cloned;
}

function cloneError(error: ProfileApplicationErrorSnapshot): ProfileApplicationErrorSnapshot {
  return createSafeError(error.code, error.stage, error.technicalDetail);
}
