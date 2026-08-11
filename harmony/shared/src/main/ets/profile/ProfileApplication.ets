import { createAppError, type AppError } from './AppErrors';
import type { ImportProfileResult, ImportProfileUseCase, RemoteImportCommand } from './ImportProfileUseCase';
import type {
  LocalRuntimeCoordinator,
  LocalRuntimeCoordinatorSnapshot,
  LocalRuntimeStartResult,
  LocalRuntimeStopResult
} from './LocalRuntimeCoordinator';
import type { ManageDeleteResult, ManageEnableResult, ManageProfileUseCases, ManageReplaceResult } from './ManageProfileUseCases';
import type { ProfileCommitService } from './ProfileCommitService';
import type {
  RefreshProfileFailedResult,
  RefreshProfileResult,
  RefreshProfileUseCase
} from './RefreshProfileUseCase';
import type { LocalAcquireCommand } from './ProfilePorts';

export interface ProfileApplicationDependencies {
  importUseCase: ImportProfileUseCase;
  refreshUseCase: RefreshProfileUseCase;
  manageProfileUseCases: ManageProfileUseCases;
  runtimeCoordinator: LocalRuntimeCoordinator;
  commitService: ProfileCommitService;
}

export interface ProfileApplicationSnapshot {
  runtime: ProfileApplicationRuntimeSnapshot;
}

export interface ProfileApplicationRuntimeSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
  latest: ProfileApplicationRuntimeLatestSnapshot;
  lastError: ProfileApplicationRuntimeErrorSnapshot | null;
}

export interface ProfileApplicationRuntimeLatestSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
  activeConfigPath: string;
  httpAddress: string;
  socksAddress: string;
  lastError: string;
  mixedPort: number;
}

export interface ProfileApplicationRuntimeErrorSnapshot {
  code: string;
  stage: string;
  userMessageResource: string;
  technicalDetail: string;
  timestamp: string;
  retryable: boolean;
}

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
  private initializePromise?: Promise<void>;

  constructor(dependencies: ProfileApplicationDependencies) {
    this.importUseCase = dependencies.importUseCase;
    this.refreshUseCase = dependencies.refreshUseCase;
    this.manageProfileUseCases = dependencies.manageProfileUseCases;
    this.runtimeCoordinator = dependencies.runtimeCoordinator;
    this.commitService = dependencies.commitService;
  }

  initialize(): Promise<void> {
    if (this.initializePromise !== undefined) {
      return this.initializePromise;
    }
    this.initializePromise = this.initializeInternal();
    return this.initializePromise;
  }

  current(): ProfileApplicationSnapshot {
    return new ProfileApplicationSnapshotValue(this.runtimeCoordinator.current());
  }

  importLocal(command: LocalAcquireCommand): Promise<ImportProfileResult> {
    return this.importUseCase.executeLocal(command);
  }

  importUrl(command: RemoteImportCommand): Promise<ImportProfileResult> {
    return this.importUseCase.executeRemote(command);
  }

  async refresh(profileId: string): Promise<RefreshProfileResult> {
    await this.initialize();
    if (this.runtimeCoordinator.current().state !== 'STOPPED') {
      return new RefreshFailedResultValue(createAppError('RUNTIME_START', 'Runtime must be stopped before refresh.', {
        retryable: false
      }));
    }
    return await this.refreshUseCase.execute({
      profileId
    });
  }

  enable(profileId: string): Promise<ManageEnableResult> {
    return this.manageProfileUseCases.enable(profileId);
  }

  delete(profileId: string): Promise<ManageDeleteResult> {
    return this.manageProfileUseCases.delete(profileId);
  }

  replaceSubscriptionUrl(profileId: string, sourceUrl: string): Promise<ManageReplaceResult> {
    return this.manageProfileUseCases.replaceSubscriptionUrl(profileId, sourceUrl);
  }

  startLocal(): Promise<LocalRuntimeStartResult> {
    return this.runtimeCoordinator.start();
  }

  stopLocal(): Promise<LocalRuntimeStopResult> {
    return this.runtimeCoordinator.stop();
  }

  dispose(): void {
    this.runtimeCoordinator.dispose();
  }

  private async initializeInternal(): Promise<void> {
    await this.commitService.reconcileStoredContent();
    await this.runtimeCoordinator.initialize();
  }
}

class ProfileApplicationSnapshotValue implements ProfileApplicationSnapshot {
  runtime: ProfileApplicationRuntimeSnapshot;

  constructor(runtime: LocalRuntimeCoordinatorSnapshot) {
    this.runtime = new ProfileApplicationRuntimeSnapshotValue(runtime);
  }
}

class ProfileApplicationRuntimeSnapshotValue implements ProfileApplicationRuntimeSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
  latest: ProfileApplicationRuntimeLatestSnapshot;
  lastError: ProfileApplicationRuntimeErrorSnapshot | null;

  constructor(runtime: LocalRuntimeCoordinatorSnapshot) {
    this.state = runtime.state;
    this.latest = createProfileApplicationRuntimeLatestSnapshot(runtime);
    this.lastError = runtime.lastError === null ? null : new ProfileApplicationRuntimeErrorSnapshotValue(runtime.lastError);
  }
}

class ProfileApplicationRuntimeLatestSnapshotValue implements ProfileApplicationRuntimeLatestSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR' = 'STOPPED';
  activeConfigPath: string = '';
  httpAddress: string = '';
  socksAddress: string = '';
  lastError: string = '';
  mixedPort: number = 0;

}

class ProfileApplicationRuntimeErrorSnapshotValue implements ProfileApplicationRuntimeErrorSnapshot {
  code: string;
  stage: string;
  userMessageResource: string;
  technicalDetail: string;
  timestamp: string;
  retryable: boolean;

  constructor(error: AppError) {
    this.code = error.code;
    this.stage = error.stage;
    this.userMessageResource = error.userMessageResource;
    this.technicalDetail = error.technicalDetail;
    this.timestamp = error.timestamp;
    this.retryable = error.retryable;
  }
}

function createProfileApplicationRuntimeLatestSnapshot(
  runtime: LocalRuntimeCoordinatorSnapshot
): ProfileApplicationRuntimeLatestSnapshotValue {
  const snapshot: ProfileApplicationRuntimeLatestSnapshotValue = new ProfileApplicationRuntimeLatestSnapshotValue();
  snapshot.state = runtime.latest.state;
  snapshot.activeConfigPath = runtime.latest.activeConfigPath;
  snapshot.httpAddress = runtime.latest.httpAddress;
  snapshot.socksAddress = runtime.latest.socksAddress;
  snapshot.lastError = runtime.latest.lastError;
  snapshot.mixedPort = runtime.latest.mixedPort;
  return snapshot;
}
