import type { CoreEvent, RuntimeSnapshot, RuntimeState } from '../core/CoreModels';
import type { CoreService } from '../core/CoreService';
import { createAppError, type AppError } from './AppErrors';
import { isProfileEligibleForActivation, type Profile } from './ProfileModels';
import type { Clock, ProfileContentStore, ProfileRepository } from './ProfilePorts';

export interface LocalRuntimeCoordinatorDependencies {
  repository: ProfileRepository;
  contentStore: ProfileContentStore;
  coreService: CoreService;
  clock: Clock;
}

export interface LocalRuntimeCoordinatorSnapshot {
  state: RuntimeState;
  latest: RuntimeSnapshot;
  lastError: AppError | null;
}

export interface LocalRuntimeStartedResult {
  kind: 'STARTED';
  snapshot: LocalRuntimeCoordinatorSnapshot;
}

export interface LocalRuntimeStoppedResult {
  kind: 'STOPPED';
  snapshot: LocalRuntimeCoordinatorSnapshot;
}

export interface LocalRuntimeFailedResult {
  kind: 'FAILED';
  error: AppError;
  snapshot: LocalRuntimeCoordinatorSnapshot;
}

export type LocalRuntimeStartResult = LocalRuntimeStartedResult | LocalRuntimeFailedResult;
export type LocalRuntimeStopResult = LocalRuntimeStoppedResult | LocalRuntimeFailedResult;

class LocalRuntimeStartedResultValue implements LocalRuntimeStartedResult {
  kind: 'STARTED' = 'STARTED';
  snapshot: LocalRuntimeCoordinatorSnapshot;

  constructor(snapshot: LocalRuntimeCoordinatorSnapshot) {
    this.snapshot = snapshot;
  }
}

class LocalRuntimeStoppedResultValue implements LocalRuntimeStoppedResult {
  kind: 'STOPPED' = 'STOPPED';
  snapshot: LocalRuntimeCoordinatorSnapshot;

  constructor(snapshot: LocalRuntimeCoordinatorSnapshot) {
    this.snapshot = snapshot;
  }
}

class LocalRuntimeFailedResultValue implements LocalRuntimeFailedResult {
  kind: 'FAILED' = 'FAILED';
  error: AppError;
  snapshot: LocalRuntimeCoordinatorSnapshot;

  constructor(error: AppError, snapshot: LocalRuntimeCoordinatorSnapshot) {
    this.error = error;
    this.snapshot = snapshot;
  }
}

export class LocalRuntimeCoordinator {
  private readonly repository: ProfileRepository;
  private readonly contentStore: ProfileContentStore;
  private readonly coreService: CoreService;
  private readonly clock: Clock;
  private snapshot: LocalRuntimeCoordinatorSnapshot = createStoppedSnapshot(null);
  private subscriptionId?: number;
  private initializePromise?: Promise<void>;
  private startPromise?: Promise<LocalRuntimeStartResult>;
  private stopPromise?: Promise<LocalRuntimeStopResult>;
  private disposed: boolean = false;

  constructor(dependencies: LocalRuntimeCoordinatorDependencies) {
    this.repository = dependencies.repository;
    this.contentStore = dependencies.contentStore;
    this.coreService = dependencies.coreService;
    this.clock = dependencies.clock;
  }

  initialize(): Promise<void> {
    if (this.initializePromise !== undefined) {
      return this.initializePromise;
    }
    this.initializePromise = this.initializeInternal();
    return this.initializePromise;
  }

  current(): LocalRuntimeCoordinatorSnapshot {
    return cloneCoordinatorSnapshot(this.snapshot);
  }

  async start(): Promise<LocalRuntimeStartResult> {
    await this.initialize();
    if (this.startPromise !== undefined) {
      return await this.startPromise;
    }
    if (this.stopPromise !== undefined) {
      return this.failStart(createAppError('RUNTIME_STOP', 'Runtime stop is already in progress.', {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }
    this.snapshot = {
      state: 'STARTING',
      latest: this.snapshot.latest,
      lastError: null
    };
    const startPromise: Promise<LocalRuntimeStartResult> = this.startInternal();
    this.startPromise = startPromise;
    try {
      return await startPromise;
    } finally {
      if (this.startPromise === startPromise) {
        this.startPromise = undefined;
      }
    }
  }

  async stop(): Promise<LocalRuntimeStopResult> {
    await this.initialize();
    if (this.stopPromise !== undefined) {
      return await this.stopPromise;
    }
    if (this.startPromise !== undefined) {
      return new LocalRuntimeFailedResultValue(
        createAppError('RUNTIME_STOP', 'Runtime start is already in progress.', {
          retryable: false,
          timestamp: this.clock.now()
        }),
        this.current()
      );
    }
    this.stopPromise = this.stopInternal();
    try {
      return await this.stopPromise;
    } finally {
      this.stopPromise = undefined;
    }
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    if (this.subscriptionId !== undefined) {
      this.coreService.unsubscribe(this.subscriptionId);
      this.subscriptionId = undefined;
    }
  }

  private async initializeInternal(): Promise<void> {
    const callback = (event: CoreEvent): void => {
      if (this.disposed || event.type !== 'runtime') {
        return;
      }
      if (event.state === 'STOPPED') {
        this.snapshot = createStoppedSnapshot(this.snapshot.lastError);
        return;
      }
      const latest: RuntimeSnapshot = this.coreService.runtimeSnapshot();
      if (event.state === 'ERROR') {
        this.snapshot = {
          state: 'ERROR',
          latest,
          lastError: createAppError('RUNTIME_START', event.message, {
            retryable: false,
            timestamp: this.clock.now()
          })
        };
        return;
      }
      this.snapshot = {
        state: latest.state,
        latest,
        lastError: null
      };
    };
    this.subscriptionId = this.coreService.subscribe(callback);
    this.coreService.runtimeSnapshot();
    this.snapshot = createStoppedSnapshot(null);
  }

  private async startInternal(): Promise<LocalRuntimeStartResult> {
    const activeId: string | undefined = await this.repository.getActiveId();
    if (activeId === undefined) {
      return this.failStart(createAppError('RUNTIME_START', 'No active profile selected.', {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }

    const profile: Profile | undefined = await this.repository.get(activeId);
    if (profile === undefined || profile.currentRevision === null || !isProfileEligibleForActivation(profile)) {
      return this.failStart(createAppError('VALIDATION', 'Active profile is not eligible for activation.', {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }

    const configPath: string = this.contentStore.resolveCorePath(profile.currentRevision);
    try {
      await this.coreService.validateConfiguration(configPath);
    } catch (error) {
      return this.failStart(createAppError('VALIDATION', resolveErrorMessage(error, 'Profile validation failed.'), {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }
    try {
      await this.coreService.loadConfiguration(configPath);
    } catch (error) {
      return this.failStart(createAppError('CORE_LOAD', resolveErrorMessage(error, 'Core configuration load failed.'), {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }

    try {
      await this.coreService.startLocal({
        configPath,
        mixedPort: 7890
      });
    } catch (error) {
      return this.failStart(createAppError('RUNTIME_START', resolveErrorMessage(error, 'Runtime start failed.'), {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }

    const latest: RuntimeSnapshot = this.coreService.runtimeSnapshot();
    this.snapshot = {
      state: latest.state,
      latest,
      lastError: null
    };
    return new LocalRuntimeStartedResultValue(this.current());
  }

  private async stopInternal(): Promise<LocalRuntimeStopResult> {
    this.snapshot = {
      state: 'STOPPING',
      latest: this.snapshot.latest,
      lastError: this.snapshot.lastError
    };
    try {
      await this.coreService.stopRuntime();
    } catch (error) {
      const appError: AppError = createAppError('RUNTIME_STOP', resolveErrorMessage(error, 'Runtime stop failed.'), {
        retryable: false,
        timestamp: this.clock.now()
      });
      this.snapshot = {
        state: 'ERROR',
        latest: this.snapshot.latest,
        lastError: appError
      };
      return new LocalRuntimeFailedResultValue(appError, this.current());
    }

    const latest: RuntimeSnapshot = this.coreService.runtimeSnapshot();
    if (latest.state === 'STOPPED') {
      this.snapshot = createStoppedSnapshot(this.snapshot.lastError);
    } else {
      this.snapshot = {
        state: latest.state,
        latest,
        lastError: this.snapshot.lastError
      };
    }
    return new LocalRuntimeStoppedResultValue(this.current());
  }

  private failStart(error: AppError): LocalRuntimeFailedResult {
    this.snapshot = {
      state: 'ERROR',
      latest: this.snapshot.latest,
      lastError: error
    };
    return new LocalRuntimeFailedResultValue(error, this.current());
  }
}

function createStoppedSnapshot(lastError: AppError | null): LocalRuntimeCoordinatorSnapshot {
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
    lastError
  };
}

function cloneCoordinatorSnapshot(snapshot: LocalRuntimeCoordinatorSnapshot): LocalRuntimeCoordinatorSnapshot {
  return {
    state: snapshot.state,
    latest: {
      state: snapshot.latest.state,
      activeConfigPath: snapshot.latest.activeConfigPath,
      httpAddress: snapshot.latest.httpAddress,
      socksAddress: snapshot.latest.socksAddress,
      lastError: snapshot.latest.lastError,
      mixedPort: snapshot.latest.mixedPort
    },
    lastError: snapshot.lastError
  };
}

function resolveErrorMessage(error: Object | undefined, fallback: string): string {
  return error instanceof Error && error.message.trim().length > 0 ? error.message : fallback;
}
