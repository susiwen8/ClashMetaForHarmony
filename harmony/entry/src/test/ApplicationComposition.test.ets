import common from '@ohos.app.ability.common';
import { describe, expect, it } from '@ohos/hypium';
import type { PlatformGraph } from '@cmfa/platform';
import {
  createAppError,
  ImportProfileUseCase,
  LocalRuntimeCoordinator,
  ManageProfileUseCases,
  ProfileApplication,
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
  type Profile,
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
import type { ApplicationComposition, ApplicationCompositionState } from '../main/ets/bootstrap/ApplicationComposition';
import { createApplicationComposition, type ApplicationCompositionDependencies } from '../main/ets/bootstrap/CoreComposition';

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private resolveRef?: (value: T) => void;
  private rejectRef?: (error: Error) => void;

  constructor() {
    this.promise = new Promise<T>((resolve, reject) => {
      this.resolveRef = resolve;
      this.rejectRef = reject;
    });
  }

  resolve(value: T): void {
    this.resolveRef?.(value);
  }

  reject(error: Error): void {
    this.rejectRef?.(error);
  }
}

class FixedClock implements Clock {
  private readonly timestamps: string[];
  private index: number = 0;

  constructor(...timestamps: string[]) {
    this.timestamps = timestamps;
  }

  now(): string {
    const safeIndex: number = Math.min(this.index, this.timestamps.length - 1);
    const next: string = this.timestamps[safeIndex];
    this.index += 1;
    return next;
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
  reconcileCallCount: number = 0;

  async retain(_profileId: string, _staged: StagedSource, _kind: 'CURRENT' | 'FAILED_CANDIDATE'): Promise<ProfileRevision> {
    throw new Error('retain should stay unused in composition tests');
  }

  async discard(_staged: StagedSource): Promise<void> {
  }

  async removeRevision(_revision: ProfileRevision): Promise<void> {
  }

  async removeProfile(_profileId: string): Promise<void> {
  }

  async reconcile(_referenced: ProfileRevision[]): Promise<void> {
    this.reconcileCallCount += 1;
  }

  resolveCorePath(revision: ProfileRevision): string {
    return revision.relativePath;
  }
}

class InertSourceGateway implements ProfileSourceGateway {
  async acquireLocal(_command: LocalAcquireCommand): Promise<LocalProfileAcquisition> {
    throw new Error('local acquire should stay unused in composition tests');
  }

  async acquireRemote(_command: RemoteAcquireCommand): Promise<RemoteProfileAcquisition> {
    throw new Error('remote acquire should stay unused in composition tests');
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

class RecordingPlatformGraph implements PlatformGraph {
  readonly repository: ProfileRepository;
  readonly contentStore: ProfileContentStore;
  readonly sourceGateway: ProfileSourceGateway;
  readonly secretStore: SubscriptionSecretStore;
  readonly clock: Clock;
  readonly idGenerator: IdGenerator;
  closeCallCount: number = 0;

  constructor(
    repository?: ProfileRepository,
    contentStore?: ProfileContentStore,
    sourceGateway?: ProfileSourceGateway,
    secretStore?: SubscriptionSecretStore
  ) {
    this.repository = repository ?? new InertRepository();
    this.contentStore = contentStore ?? new InertContentStore();
    this.sourceGateway = sourceGateway ?? new InertSourceGateway();
    this.secretStore = secretStore ?? new InertSecretStore();
    this.clock = new FixedClock('2026-08-11T12:00:00.000Z');
    this.idGenerator = new FixedIdGenerator();
  }

  async close(): Promise<void> {
    this.closeCallCount += 1;
  }
}

class RecordingApplication {
  initializeCallCount: number = 0;
  disposeCallCount: number = 0;
  initializeError?: Error;

  async initialize(): Promise<void> {
    this.initializeCallCount += 1;
    if (this.initializeError !== undefined) {
      throw this.initializeError;
    }
  }

  dispose(): void {
    this.disposeCallCount += 1;
  }
}

class RuntimeAwareCoreService implements CoreService {
  readonly subscribeIds: number[] = [];
  readonly unsubscribeIds: number[] = [];
  private readonly callbacks: Map<number, (event: CoreEvent) => void> = new Map();
  private nextSubscriptionId: number = 1;
  private snapshotValue: RuntimeSnapshot = buildRuntimeSnapshot('STOPPED');

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
    return this.runtimeSnapshot();
  }

  async stopRuntime(): Promise<RuntimeSnapshot> {
    return this.runtimeSnapshot();
  }

  runtimeSnapshot(): RuntimeSnapshot {
    return {
      state: this.snapshotValue.state,
      activeConfigPath: this.snapshotValue.activeConfigPath,
      httpAddress: this.snapshotValue.httpAddress,
      socksAddress: this.snapshotValue.socksAddress,
      lastError: this.snapshotValue.lastError,
      mixedPort: this.snapshotValue.mixedPort
    };
  }

  subscribe(callback: (event: CoreEvent) => void): number {
    const subscriptionId: number = this.nextSubscriptionId;
    this.nextSubscriptionId += 1;
    this.subscribeIds.push(subscriptionId);
    this.callbacks.set(subscriptionId, callback);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.unsubscribeIds.push(subscriptionId);
    this.callbacks.delete(subscriptionId);
  }
}

function buildRuntimeSnapshot(state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR'): RuntimeSnapshot {
  return {
    state,
    activeConfigPath: '',
    httpAddress: '',
    socksAddress: '',
    lastError: '',
    mixedPort: 0
  };
}

function createContext(): common.UIAbilityContext {
  return {
    filesDir: '/sandbox/app/files'
  } as common.UIAbilityContext;
}

function collectStatuses(history: ApplicationCompositionState[]): string {
  const statuses: string[] = [];
  for (let index: number = 0; index < history.length; index += 1) {
    statuses.push(history[index].status);
  }
  return statuses.join('>');
}

function createRealProfileApplication(coreService: CoreService, graph: PlatformGraph): ProfileApplication {
  const runtimeCoordinator = new LocalRuntimeCoordinator({
    repository: graph.repository,
    contentStore: graph.contentStore,
    coreService,
    clock: new FixedClock(
      '2026-08-11T12:01:00.000Z',
      '2026-08-11T12:01:01.000Z',
      '2026-08-11T12:01:02.000Z'
    )
  });
  const queue = new SerialCommandQueue();
  const commitService = new ProfileCommitService({
    repository: graph.repository,
    contentStore: graph.contentStore,
    clock: new FixedClock(
      '2026-08-11T12:02:00.000Z',
      '2026-08-11T12:02:01.000Z',
      '2026-08-11T12:02:02.000Z'
    )
  });
  const sourceGateway = graph.sourceGateway;
  const secretStore = graph.secretStore;
  const importUseCase = new ImportProfileUseCase({
    repository: graph.repository,
    contentStore: graph.contentStore,
    sourceGateway,
    secretStore,
    coreService,
    clock: new FixedClock('2026-08-11T12:03:00.000Z', '2026-08-11T12:03:01.000Z'),
    idGenerator: graph.idGenerator,
    queue,
    commitService
  });
  const refreshUseCase = new RefreshProfileUseCase({
    repository: graph.repository,
    contentStore: graph.contentStore,
    sourceGateway,
    secretStore,
    coreService,
    clock: new FixedClock(
      '2026-08-11T12:04:00.000Z',
      '2026-08-11T12:04:01.000Z',
      '2026-08-11T12:04:02.000Z'
    ),
    queue,
    commitService
  });
  const manageProfileUseCases = new ManageProfileUseCases({
    repository: graph.repository,
    contentStore: graph.contentStore,
    secretStore,
    coreService,
    clock: new FixedClock(
      '2026-08-11T12:05:00.000Z',
      '2026-08-11T12:05:01.000Z',
      '2026-08-11T12:05:02.000Z'
    ),
    runtimeCoordinator
  });
  return new ProfileApplication({
    importUseCase,
    refreshUseCase,
    manageProfileUseCases,
    runtimeCoordinator,
    commitService
  });
}

function createComposition(
  dependencies: ApplicationCompositionDependencies
): ApplicationComposition {
  return createApplicationComposition(createContext(), dependencies);
}

export default function applicationCompositionTestsuite() {
  describe('ApplicationCompositionTest', () => {
    it('concurrentInitializeTransitionsLoadingToReadyOnce', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const application = new RecordingApplication();
      const states: ApplicationCompositionState[] = [];
      const graphDeferred = new DeferredValue<PlatformGraph>();
      let createPlatformGraphCallCount: number = 0;
      const composition = createComposition({
        createPlatformGraph: async (_context: common.UIAbilityContext): Promise<PlatformGraph> => {
          createPlatformGraphCallCount += 1;
          return await graphDeferred.promise;
        },
        createProfileApplication: (_graph: PlatformGraph, _coreService: CoreService): ProfileApplication => {
          return application as ProfileApplication;
        }
      });
      composition.subscribe((state: ApplicationCompositionState): void => {
        states.push(state);
      });

      const first = composition.initialize();
      const second = composition.initialize();

      expect(createPlatformGraphCallCount).assertEqual(1);
      expect(composition.state().status).assertEqual('LOADING');
      expect(collectStatuses(states)).assertEqual('LOADING');

      graphDeferred.resolve(graph);
      await Promise.all([first, second]);

      expect(application.initializeCallCount).assertEqual(1);
      expect(collectStatuses(states)).assertEqual('LOADING>READY');
      expect(composition.state().status).assertEqual('READY');
      await composition.close();
    });

    it('failedInitializePublishesPersistenceErrorClosesTheGraphAndAllowsExplicitRetry', 0, async () => {
      const firstGraph = new RecordingPlatformGraph();
      const secondGraph = new RecordingPlatformGraph();
      const firstApplication = new RecordingApplication();
      const secondApplication = new RecordingApplication();
      const states: ApplicationCompositionState[] = [];
      firstApplication.initializeError = new Error('https://profiles.example.com/import.yaml?token=secret-value');
      let useSecondAttempt: boolean = false;
      const composition = createComposition({
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return useSecondAttempt ? secondGraph : firstGraph;
        },
        createProfileApplication: (_graph: PlatformGraph, _coreService: CoreService): ProfileApplication => {
          return (useSecondAttempt ? secondApplication : firstApplication) as ProfileApplication;
        }
      });
      composition.subscribe((state: ApplicationCompositionState): void => {
        states.push(state);
      });

      let thrownError: AppError | undefined = undefined;
      try {
        await composition.initialize();
      } catch (error) {
        thrownError = error as AppError;
      }

      expect(thrownError !== undefined).assertTrue();
      if (thrownError === undefined) {
        return;
      }
      expect(thrownError.stage).assertEqual('PERSISTENCE');
      expect(firstGraph.closeCallCount).assertEqual(1);
      expect(thrownError.technicalDetail.includes('profiles.example.com')).assertFalse();
      expect(thrownError.technicalDetail.includes('secret-value')).assertFalse();
      expect(collectStatuses(states)).assertEqual('LOADING>ERROR');
      expect(composition.state().status).assertEqual('ERROR');

      useSecondAttempt = true;
      await composition.initialize();

      expect(secondApplication.initializeCallCount).assertEqual(1);
      expect(secondGraph.closeCallCount).assertEqual(0);
      expect(collectStatuses(states)).assertEqual('LOADING>ERROR>LOADING>READY');
      expect(composition.state().status).assertEqual('READY');
      await composition.close();
    });

    it('realRuntimeSubscriptionInitializesOnceAndCloseIsIdempotent', 0, async () => {
      const coreService = new RuntimeAwareCoreService();
      const contentStore = new InertContentStore();
      const graph = new RecordingPlatformGraph(
        new InertRepository(),
        contentStore,
        new InertSourceGateway(),
        new InertSecretStore()
      );
      const composition = createComposition({
        coreService,
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createProfileApplication: (platformGraph: PlatformGraph, injectedCoreService: CoreService): ProfileApplication => {
          return createRealProfileApplication(injectedCoreService, platformGraph);
        }
      });

      await Promise.all([composition.initialize(), composition.initialize()]);

      expect(contentStore.reconcileCallCount).assertEqual(1);
      expect(coreService.subscribeIds.length).assertEqual(1);
      expect(composition.state().status).assertEqual('READY');

      await composition.close();
      await composition.close();

      expect(coreService.unsubscribeIds.length).assertEqual(1);
      expect(graph.closeCallCount).assertEqual(1);
    });
  });
}
