import { createAppError, type AppError, type AppErrorStage } from './AppErrors';
import type { ImportProfileResult, ImportProfileUseCase, RemoteImportCommand } from './ImportProfileUseCase';
import type {
  LocalRuntimeCoordinator,
  LocalRuntimeCoordinatorListener,
  LocalRuntimeCoordinatorSnapshot,
  LocalRuntimeStartResult,
  LocalRuntimeStopResult
} from './LocalRuntimeCoordinator';
import type { ManageDeleteResult, ManageEnableResult, ManageProfileUseCases, ManageReplaceResult } from './ManageProfileUseCases';
import type { ProfileCommitService } from './ProfileCommitService';
import { redactSensitiveText } from './SecretRedactor';
import type {
  RefreshProfileFailedResult,
  RefreshProfileResult,
  RefreshProfileUseCase
} from './RefreshProfileUseCase';
import type { LocalAcquireCommand, ProfileRepository } from './ProfilePorts';
import type { Profile, ProfileAvailability } from './ProfileModels';

export interface ProfileApplicationDependencies {
  importUseCase: ImportProfileUseCase;
  refreshUseCase: RefreshProfileUseCase;
  manageProfileUseCases: ManageProfileUseCases;
  runtimeCoordinator: LocalRuntimeCoordinator;
  commitService: ProfileCommitService;
  repository: ProfileRepository;
}

export interface ProfileApplicationSnapshot {
  status: 'LOADING' | 'READY' | 'ERROR';
  profiles: ProfileApplicationProfileSnapshot[];
  activeProfileId?: string;
  runtime: ProfileApplicationRuntimeSnapshot;
  error: ProfileApplicationErrorSnapshot | null;
}

export interface ProfileApplicationProfileSnapshot {
  id: string;
  name: string;
  sourceDisplay: string;
  availability: ProfileAvailability;
  updatedAt: string;
  hasCurrentRevision: boolean;
}

export interface ProfileApplicationRuntimeSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
  latest: ProfileApplicationRuntimeLatestSnapshot;
  lastError: ProfileApplicationErrorSnapshot | null;
}

export interface ProfileApplicationRuntimeLatestSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
  httpAddress: string;
  socksAddress: string;
  lastError: string;
  mixedPort: number;
}

export interface ProfileApplicationErrorSnapshot {
  code: string;
  stage: AppErrorStage;
  userMessageResource: string;
  technicalDetail: string;
  timestamp: string;
  retryable: boolean;
}

export type ProfileApplicationListener = (snapshot: ProfileApplicationSnapshot) => void;

class RefreshFailedResultValue implements RefreshProfileFailedResult {
  kind: 'FAILED' = 'FAILED';
  error: AppError;

  constructor(error: AppError) {
    this.error = error;
  }
}

export class ProfileApplication {
  private readonly importUseCase: ImportProfileUseCase;
  private readonly refreshUseCase: RefreshProfileUseCase;
  private readonly manageProfileUseCases: ManageProfileUseCases;
  private readonly runtimeCoordinator: LocalRuntimeCoordinator;
  private readonly commitService: ProfileCommitService;
  private readonly repository: ProfileRepository;
  private readonly runtimeListener: LocalRuntimeCoordinatorListener;
  private readonly listeners: Map<number, ProfileApplicationListener> = new Map();
  private initializePromise?: Promise<void>;
  private nextListenerId: number = 0;
  private runtimeSubscriptionId: number;
  private disposed: boolean = false;
  private snapshot: ProfileApplicationSnapshot = createProfileApplicationSnapshot(
    'LOADING',
    [],
    undefined,
    createProfileApplicationRuntimeSnapshot(thisRuntimeStoppedSnapshot()),
    null
  );

  constructor(dependencies: ProfileApplicationDependencies) {
    this.importUseCase = dependencies.importUseCase;
    this.refreshUseCase = dependencies.refreshUseCase;
    this.manageProfileUseCases = dependencies.manageProfileUseCases;
    this.runtimeCoordinator = dependencies.runtimeCoordinator;
    this.commitService = dependencies.commitService;
    this.repository = dependencies.repository;
    this.runtimeListener = (runtimeSnapshot: LocalRuntimeCoordinatorSnapshot): void => {
      this.publish(
        createProfileApplicationSnapshot(
          this.snapshot.status,
          this.snapshot.profiles,
          this.snapshot.activeProfileId,
          createProfileApplicationRuntimeSnapshot(runtimeSnapshot),
          this.snapshot.error
        )
      );
    };
    this.runtimeSubscriptionId = this.runtimeCoordinator.subscribe(this.runtimeListener);
  }

  initialize(): Promise<void> {
    if (this.initializePromise !== undefined) {
      return this.initializePromise;
    }
    const initializePromise: Promise<void> = this.initializeInternal();
    this.initializePromise = initializePromise;
    return initializePromise;
  }

  current(): ProfileApplicationSnapshot {
    return cloneProfileApplicationSnapshot(this.snapshot);
  }

  subscribe(listener: ProfileApplicationListener): number {
    this.nextListenerId += 1;
    this.listeners.set(this.nextListenerId, listener);
    return this.nextListenerId;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  async importLocal(command: LocalAcquireCommand): Promise<ImportProfileResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const result: ImportProfileResult = await this.importUseCase.executeLocal(command);
    await this.refreshSnapshotFromRepository(undefined);
    return result;
  }

  async importUrl(command: RemoteImportCommand): Promise<ImportProfileResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const result: ImportProfileResult = await this.importUseCase.executeRemote(command);
    await this.refreshSnapshotFromRepository(undefined);
    return result;
  }

  async refresh(profileId: string): Promise<RefreshProfileResult> {
    try {
      if (this.snapshot.status !== 'READY') {
        await this.initialize();
      }
      const admission = this.runtimeCoordinator.acquireMutationLease('REFRESH');
      if (admission.error !== undefined) {
        return new RefreshFailedResultValue(admission.error);
      }
      try {
        const result: RefreshProfileResult = await this.refreshUseCase.execute({
          profileId
        });
        await this.refreshSnapshotFromRepository(undefined);
        return result;
      } finally {
        admission.lease?.release();
      }
    } catch (error) {
      const appError: AppError = createAppError('RUNTIME_START', resolveErrorMessage(error, 'Runtime must be stopped before refresh.'), {
        retryable: false
      });
      await this.refreshSnapshotFromRepository(appError);
      return new RefreshFailedResultValue(appError);
    }
  }

  async enable(profileId: string): Promise<ManageEnableResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const result: ManageEnableResult = await this.manageProfileUseCases.enable(profileId);
    await this.refreshSnapshotFromRepository(undefined);
    return result;
  }

  async delete(profileId: string): Promise<ManageDeleteResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const result: ManageDeleteResult = await this.manageProfileUseCases.delete(profileId);
    await this.refreshSnapshotFromRepository(undefined);
    return result;
  }

  async replaceSubscriptionUrl(profileId: string, sourceUrl: string): Promise<ManageReplaceResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const result: ManageReplaceResult = await this.manageProfileUseCases.replaceSubscriptionUrl(profileId, sourceUrl);
    await this.refreshSnapshotFromRepository(undefined);
    return result;
  }

  async startLocal(): Promise<LocalRuntimeStartResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const result: LocalRuntimeStartResult = await this.runtimeCoordinator.start();
    await this.refreshSnapshotFromRepository(undefined);
    return result;
  }

  async stopLocal(): Promise<LocalRuntimeStopResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const result: LocalRuntimeStopResult = await this.runtimeCoordinator.stop();
    await this.refreshSnapshotFromRepository(undefined);
    return result;
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.runtimeCoordinator.unsubscribe(this.runtimeSubscriptionId);
    this.listeners.clear();
    this.runtimeCoordinator.dispose();
  }

  private async initializeInternal(): Promise<void> {
    try {
      await this.commitService.reconcileStoredContent();
      await this.runtimeCoordinator.initialize();
      await this.refreshSnapshotFromRepository(undefined);
    } catch (error) {
      const appError: AppError = createAppError('PERSISTENCE', resolveErrorMessage(error, 'Profile application initialization failed.'), {
        retryable: false
      });
      await this.refreshSnapshotFromRepository(appError);
      throw toError(error, 'Profile application initialization failed.');
    } finally {
      if (this.snapshot.status !== 'READY') {
        this.initializePromise = undefined;
      }
    }
  }

  private async refreshSnapshotFromRepository(error?: AppError): Promise<void> {
    let profiles: ProfileApplicationProfileSnapshot[] = this.snapshot.profiles;
    let activeProfileId: string | undefined = this.snapshot.activeProfileId;
    let status: 'LOADING' | 'READY' | 'ERROR' = error === undefined ? 'READY' : 'ERROR';
    let snapshotError: ProfileApplicationErrorSnapshot | null = error === undefined ? null : createProfileApplicationErrorSnapshot(error);
    try {
      const listedProfiles: Profile[] = await this.repository.list();
      const nextProfiles: ProfileApplicationProfileSnapshot[] = [];
      for (let index: number = 0; index < listedProfiles.length; index += 1) {
        nextProfiles.push(createProfileApplicationProfileSnapshot(listedProfiles[index]));
      }
      sortProfileApplicationSnapshots(nextProfiles);
      profiles = nextProfiles;
      activeProfileId = await this.repository.getActiveId();
      if (snapshotError === null) {
        status = 'READY';
      }
    } catch (refreshError) {
      status = 'ERROR';
      snapshotError = createProfileApplicationErrorSnapshot(
        error ?? createAppError('PERSISTENCE', resolveErrorMessage(refreshError, 'Profile snapshot refresh failed.'), {
          retryable: false
        })
      );
    }
    this.publish(
      createProfileApplicationSnapshot(
        status,
        profiles,
        activeProfileId,
        createProfileApplicationRuntimeSnapshot(this.runtimeCoordinator.current()),
        snapshotError
      )
    );
  }

  private publish(snapshot: ProfileApplicationSnapshot): void {
    this.snapshot = cloneProfileApplicationSnapshot(snapshot);
    if (this.listeners.size === 0) {
      return;
    }
    const listeners: ProfileApplicationListener[] = [];
    this.listeners.forEach((listener: ProfileApplicationListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneProfileApplicationSnapshot(this.snapshot));
    }
  }
}

class ProfileApplicationProfileSnapshotValue implements ProfileApplicationProfileSnapshot {
  id: string = '';
  name: string = '';
  sourceDisplay: string = '';
  availability: ProfileAvailability = 'INVALID';
  updatedAt: string = '';
  hasCurrentRevision: boolean = false;
}

class ProfileApplicationSnapshotValue implements ProfileApplicationSnapshot {
  status: 'LOADING' | 'READY' | 'ERROR' = 'LOADING';
  profiles: ProfileApplicationProfileSnapshot[] = [];
  activeProfileId?: string;
  runtime: ProfileApplicationRuntimeSnapshot = createProfileApplicationRuntimeSnapshot(thisRuntimeStoppedSnapshot());
  error: ProfileApplicationErrorSnapshot | null = null;
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

class ProfileApplicationErrorSnapshotValue implements ProfileApplicationErrorSnapshot {
  code: string;
  stage: AppErrorStage;
  userMessageResource: string;
  technicalDetail: string;
  timestamp: string;
  retryable: boolean;

  constructor(error: AppError) {
    this.code = error.code;
    this.stage = error.stage;
    this.userMessageResource = error.userMessageResource;
    this.technicalDetail = redactSensitiveText(error.technicalDetail);
    this.timestamp = error.timestamp;
    this.retryable = error.retryable;
  }
}

function createProfileApplicationRuntimeLatestSnapshot(runtime: LocalRuntimeCoordinatorSnapshot): ProfileApplicationRuntimeLatestSnapshot {
  const snapshot: ProfileApplicationRuntimeLatestSnapshotValue = new ProfileApplicationRuntimeLatestSnapshotValue();
  snapshot.state = runtime.latest.state;
  snapshot.httpAddress = redactSensitiveText(runtime.latest.httpAddress);
  snapshot.socksAddress = redactSensitiveText(runtime.latest.socksAddress);
  snapshot.lastError = redactSensitiveText(runtime.latest.lastError);
  snapshot.mixedPort = runtime.latest.mixedPort;
  return snapshot;
}

function createProfileApplicationRuntimeSnapshot(runtime: LocalRuntimeCoordinatorSnapshot): ProfileApplicationRuntimeSnapshot {
  const snapshot: ProfileApplicationRuntimeSnapshotValue = new ProfileApplicationRuntimeSnapshotValue();
  snapshot.state = runtime.state;
  snapshot.latest = createProfileApplicationRuntimeLatestSnapshot(runtime);
  snapshot.lastError = runtime.lastError === null ? null : createProfileApplicationErrorSnapshot(runtime.lastError);
  return snapshot;
}

function createProfileApplicationErrorSnapshot(error: AppError): ProfileApplicationErrorSnapshot {
  return new ProfileApplicationErrorSnapshotValue(error);
}

function createProfileApplicationProfileSnapshot(profile: Profile): ProfileApplicationProfileSnapshot {
  const snapshot: ProfileApplicationProfileSnapshotValue = new ProfileApplicationProfileSnapshotValue();
  snapshot.id = profile.id;
  snapshot.name = profile.name;
  snapshot.sourceDisplay = profile.sourceDisplay;
  snapshot.availability = profile.availability;
  snapshot.updatedAt = profile.updatedAt;
  snapshot.hasCurrentRevision = profile.currentRevision !== null;
  return snapshot;
}

function createProfileApplicationSnapshot(
  status: 'LOADING' | 'READY' | 'ERROR',
  profiles: ProfileApplicationProfileSnapshot[],
  activeProfileId: string | undefined,
  runtime: ProfileApplicationRuntimeSnapshot,
  error: ProfileApplicationErrorSnapshot | null
): ProfileApplicationSnapshot {
  const snapshot: ProfileApplicationSnapshotValue = new ProfileApplicationSnapshotValue();
  snapshot.status = status;
  snapshot.profiles = cloneProfileApplicationProfiles(profiles);
  snapshot.activeProfileId = activeProfileId;
  snapshot.runtime = cloneProfileApplicationRuntimeSnapshot(runtime);
  snapshot.error = error === null ? null : cloneProfileApplicationErrorSnapshot(error);
  return snapshot;
}

function cloneProfileApplicationSnapshot(snapshot: ProfileApplicationSnapshot): ProfileApplicationSnapshot {
  return createProfileApplicationSnapshot(
    snapshot.status,
    snapshot.profiles,
    snapshot.activeProfileId,
    snapshot.runtime,
    snapshot.error
  );
}

function cloneProfileApplicationProfiles(profiles: ProfileApplicationProfileSnapshot[]): ProfileApplicationProfileSnapshot[] {
  const cloned: ProfileApplicationProfileSnapshot[] = [];
  for (let index: number = 0; index < profiles.length; index += 1) {
    const source: ProfileApplicationProfileSnapshot = profiles[index];
    const snapshot: ProfileApplicationProfileSnapshotValue = new ProfileApplicationProfileSnapshotValue();
    snapshot.id = source.id;
    snapshot.name = source.name;
    snapshot.sourceDisplay = source.sourceDisplay;
    snapshot.availability = source.availability;
    snapshot.updatedAt = source.updatedAt;
    snapshot.hasCurrentRevision = source.hasCurrentRevision;
    cloned.push(snapshot);
  }
  return cloned;
}

function cloneProfileApplicationRuntimeSnapshot(runtime: ProfileApplicationRuntimeSnapshot): ProfileApplicationRuntimeSnapshot {
  const snapshot: ProfileApplicationRuntimeSnapshotValue = new ProfileApplicationRuntimeSnapshotValue();
  snapshot.state = runtime.state;
  snapshot.latest = cloneProfileApplicationRuntimeLatestSnapshot(runtime.latest);
  snapshot.lastError = runtime.lastError === null ? null : cloneProfileApplicationErrorSnapshot(runtime.lastError);
  return snapshot;
}

function cloneProfileApplicationRuntimeLatestSnapshot(runtime: ProfileApplicationRuntimeLatestSnapshot): ProfileApplicationRuntimeLatestSnapshot {
  const snapshot: ProfileApplicationRuntimeLatestSnapshotValue = new ProfileApplicationRuntimeLatestSnapshotValue();
  snapshot.state = runtime.state;
  snapshot.httpAddress = runtime.httpAddress;
  snapshot.socksAddress = runtime.socksAddress;
  snapshot.lastError = runtime.lastError;
  snapshot.mixedPort = runtime.mixedPort;
  return snapshot;
}

function cloneProfileApplicationErrorSnapshot(error: ProfileApplicationErrorSnapshot): ProfileApplicationErrorSnapshot {
  return new ProfileApplicationErrorSnapshotValue({
    code: error.code,
    stage: error.stage,
    userMessageResource: error.userMessageResource,
    technicalDetail: error.technicalDetail,
    timestamp: error.timestamp,
    retryable: error.retryable
  });
}

function sortProfileApplicationSnapshots(profiles: ProfileApplicationProfileSnapshot[]): void {
  profiles.sort((left: ProfileApplicationProfileSnapshot, right: ProfileApplicationProfileSnapshot): number => {
    if (left.updatedAt !== right.updatedAt) {
      return right.updatedAt.localeCompare(left.updatedAt);
    }
    if (left.name !== right.name) {
      return left.name.localeCompare(right.name);
    }
    return left.id.localeCompare(right.id);
  });
}

function thisRuntimeStoppedSnapshot(): LocalRuntimeCoordinatorSnapshot {
  return {
    state: 'STOPPED',
    latest: {
      state: 'STOPPED',
      activeConfigPath: '',
      httpAddress: '',
      socksAddress: '',
      lastError: '',
      mixedPort: 0
    },
    lastError: null
  };
}

function resolveErrorMessage(error: Object | undefined, fallback: string): string {
  return error instanceof Error && error.message.trim().length > 0 ? error.message : fallback;
}

function toError(error: Object | undefined, fallback: string): Error {
  return error instanceof Error ? error : new Error(resolveErrorMessage(error, fallback));
}
