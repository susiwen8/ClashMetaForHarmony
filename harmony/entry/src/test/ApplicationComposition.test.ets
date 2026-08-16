import common from '@ohos.app.ability.common';
import { describe, expect, it } from '@ohos/hypium';
import type { Want } from '@kit.AbilityKit';
import type { PlatformGraph } from '@cmfa/platform';
import {
  createAppError,
  createProfile,
  createProfileRevision,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
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
  type ProfileApplicationDependencies,
  type Profile,
  type ProfileContentStore,
  type ProfileRepository,
  type ProfileRevision,
  type ProfileSourceGateway,
  type RemoteAcquireCommand,
  type RemoteProfileAcquisition,
  type RuntimeSnapshot,
  type StagedSource,
  type SubscriptionSecretStore,
  type VpnControllerPort,
  type VpnControllerStartResult,
  type VpnControllerStopResult,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot
} from '@cmfa/shared';
import type { ApplicationComposition, ApplicationCompositionState } from '../main/ets/bootstrap/ApplicationComposition';
import { createApplicationComposition, type ApplicationCompositionDependencies } from '../main/ets/bootstrap/CoreComposition';
import { HarmonyVpnController, type VpnExtensionAbilityApi } from '../main/ets/vpn/HarmonyVpnController';
import { VpnSessionRegistry } from '../main/ets/vpn/VpnSessionRegistry';
import {
  resolveVpnExtensionComposition,
  resetVpnExtensionCompositionForTesting
} from '../main/ets/vpn/VpnExtensionComposition';

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

class SeededRepository implements ProfileRepository {
  private readonly profile: Profile;
  private readonly activeId: string;

  constructor(profile: Profile) {
    this.profile = profile;
    this.activeId = profile.id;
  }

  async list(): Promise<Profile[]> {
    return [this.profile];
  }

  async get(id: string): Promise<Profile | undefined> {
    return id === this.profile.id ? this.profile : undefined;
  }

  async save(_profile: Profile): Promise<void> {
  }

  async deleteAndClearActive(_id: string): Promise<void> {
  }

  async getActiveId(): Promise<string | undefined> {
    return this.activeId;
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
  closeError?: Error;

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
    if (this.closeError !== undefined) {
      throw this.closeError;
    }
  }
}

class RecordingApplication extends ProfileApplication {
  initializeCallCount: number = 0;
  disposeCallCount: number = 0;
  initializeError?: Error;
  disposeError?: Error;

  constructor() {
    super(createProfileApplicationDependencies(new RuntimeAwareCoreService(), new RecordingPlatformGraph()));
  }

  async initialize(): Promise<void> {
    this.initializeCallCount += 1;
    if (this.initializeError !== undefined) {
      throw this.initializeError;
    }
  }

  dispose(): void {
    this.disposeCallCount += 1;
    if (this.disposeError !== undefined) {
      throw this.disposeError;
    }
  }
}

class VpnStartCallRecord {
  profileId: string = '';
  versionId: string = '';
  sessionId: string = '';
}

class RecordingVpnController implements VpnControllerPort {
  readonly subscribeIds: number[] = [];
  readonly startCalls: VpnStartCallRecord[] = [];
  private nextSubscriptionId: number = 1;

  async start(profileId: string, versionId: string, sessionId: string): Promise<VpnControllerStartResult> {
    const callRecord: VpnStartCallRecord = new VpnStartCallRecord();
    callRecord.profileId = profileId;
    callRecord.versionId = versionId;
    callRecord.sessionId = sessionId;
    this.startCalls.push(callRecord);
    return {
      kind: 'STARTED',
      snapshot: this.snapshot()
    };
  }

  async stop(_sessionId?: string): Promise<VpnControllerStopResult> {
    return {
      kind: 'STOPPED',
      snapshot: this.snapshot()
    };
  }

  snapshot(): VpnRuntimeSnapshot {
    return createVpnRuntimeSnapshot({
      state: 'STOPPED',
      activeRequest: null,
      activeHandle: null,
      captureConfig: null,
      tunSnapshot: null,
      notificationActive: false,
      recoveryAttempt: 0,
      scheduledRetryDelayMs: null,
      lastFailure: null
    });
  }

  subscribe(_listener: (event: VpnRuntimeEvent) => void): number {
    const subscriptionId: number = this.nextSubscriptionId;
    this.nextSubscriptionId += 1;
    this.subscribeIds.push(subscriptionId);
    return subscriptionId;
  }
}

class InertVpnExtensionAbilityApi implements VpnExtensionAbilityApi {
  async startVpnExtensionAbility(): Promise<void> {
  }

  async stopVpnExtensionAbility(): Promise<void> {
  }
}

class EmptyResourceManagerRecord {
}

class EmptyApplicationInfoRecord {
}

class EmptyConfigurationRecord {
}

class FakeHapModuleInfoRecord {
  readonly name: string;

  constructor(name: string) {
    this.name = name;
  }
}

class FakeAbilityInfoRecord {
  readonly bundleName: string;
  readonly name: string;

  constructor(bundleName: string, name: string) {
    this.bundleName = bundleName;
    this.name = name;
  }
}

class FakeVpnExtensionContextRecord {
  readonly stageMode: boolean = true;
  readonly resourceManager: EmptyResourceManagerRecord = new EmptyResourceManagerRecord();
  readonly applicationInfo: EmptyApplicationInfoRecord = new EmptyApplicationInfoRecord();
  readonly cacheDir: string;
  readonly tempDir: string;
  readonly filesDir: string;
  readonly currentHapModuleInfo: FakeHapModuleInfoRecord;
  readonly config: EmptyConfigurationRecord = new EmptyConfigurationRecord();
  readonly extensionAbilityInfo: FakeAbilityInfoRecord;

  constructor(tag: string) {
    this.cacheDir = `/sandbox/${tag}/cache`;
    this.tempDir = `/sandbox/${tag}/tmp`;
    this.filesDir = `/sandbox/${tag}/files`;
    this.currentHapModuleInfo = new FakeHapModuleInfoRecord(`${tag}-module`);
    this.extensionAbilityInfo = new FakeAbilityInfoRecord('com.github.kr328.clash.harmony', tag);
  }
}

class NullParametersWantRecord {
  bundleName?: string = 'com.github.kr328.clash.harmony';
  abilityName?: string = 'CmfaVpnExtensionAbility';
  parameters?: Record<string, Object> | null = null;
}

class TimeoutPromiseRecord<T> {
  readonly promise: Promise<T>;

  constructor(value: T, delayMs: number) {
    this.promise = new Promise<T>((resolve) => {
      setTimeout(() => resolve(value), delayMs);
    });
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

function createEligibleProfile(profileId: string): Profile {
  return createProfile({
    id: profileId,
    name: 'Profile',
    sourceKind: 'REMOTE_URL',
    sourceDisplay: 'https://mirror.example.com/config.yaml',
    sourceSecretRef: 'secret-ref',
    currentRevision: createProfileRevision(`profiles/${profileId}.yaml`, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 128, '2026-08-11T12:00:00.000Z'),
    failedCandidate: null,
    availability: 'VALID',
    lastError: null,
    createdAt: '2026-08-11T12:00:00.000Z',
    updatedAt: '2026-08-11T12:00:00.000Z',
    lastSuccessfulUpdateAt: '2026-08-11T12:00:00.000Z'
  });
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

function createProfileApplicationDependencies(
  coreService: CoreService,
  graph: PlatformGraph,
  vpnController?: VpnControllerPort
): ProfileApplicationDependencies {
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

  return {
    importUseCase,
    refreshUseCase,
    manageProfileUseCases,
    runtimeCoordinator,
    commitService,
    repository: graph.repository,
    vpnController,
    idGenerator: graph.idGenerator
  };
}

function createRealProfileApplication(
  coreService: CoreService,
  graph: PlatformGraph,
  vpnController?: VpnControllerPort
): ProfileApplication {
  return new ProfileApplication(createProfileApplicationDependencies(coreService, graph, vpnController));
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
      const vpnRegistry = new VpnSessionRegistry();
      const states: ApplicationCompositionState[] = [];
      const graphDeferred = new DeferredValue<PlatformGraph>();
      let createPlatformGraphCallCount: number = 0;
      const composition = createComposition({
        vpnRegistry,
        createPlatformGraph: async (_context: common.UIAbilityContext): Promise<PlatformGraph> => {
          createPlatformGraphCallCount += 1;
          return await graphDeferred.promise;
        },
        createProfileApplication: (_graph: PlatformGraph, _coreService: CoreService): ProfileApplication => {
          return application;
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
      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status === 'READY') {
        expect(compositionState.vpnRegistry === vpnRegistry).assertTrue();
      }
      await composition.close();
    });

    it('passesTheExactInjectedRegistryThroughReadyStateControllerFactoryAndCustomApplicationFactory', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const vpnRegistry = new VpnSessionRegistry();
      const application = new RecordingApplication();
      let applicationFactoryRegistry: VpnSessionRegistry | undefined = undefined;
      const composition = createComposition({
        vpnRegistry,
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createProfileApplication: (_graph: PlatformGraph, _coreService: CoreService, registry: VpnSessionRegistry): ProfileApplication => {
          applicationFactoryRegistry = registry;
          return application;
        }
      });

      await composition.initialize();

      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status === 'READY') {
        expect(compositionState.vpnRegistry === vpnRegistry).assertTrue();
      }
      expect(applicationFactoryRegistry === vpnRegistry).assertTrue();
      await composition.close();
    });

    it('customApplicationFactoryCanReuseTheExactRegistryForTheControllerAndReadyState', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const coreService = new RuntimeAwareCoreService();
      const vpnRegistry = new VpnSessionRegistry();
      let controllerRegistry: VpnSessionRegistry | undefined = undefined;
      const composition = createComposition({
        coreService,
        vpnRegistry,
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createProfileApplication: (platformGraph: PlatformGraph, injectedCoreService: CoreService, registry: VpnSessionRegistry): ProfileApplication => {
          controllerRegistry = registry;
          const controller = new HarmonyVpnController(registry, new InertVpnExtensionAbilityApi());
          return createRealProfileApplication(injectedCoreService, platformGraph, controller);
        }
      });

      await composition.initialize();

      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status === 'READY') {
        expect(compositionState.vpnRegistry === vpnRegistry).assertTrue();
      }
      expect(controllerRegistry === vpnRegistry).assertTrue();
      await composition.close();
    });

    it('defaultApplicationWiringUsesTheInjectedRegistryAcrossControllerFactoryAndReadyState', 0, async () => {
      const graph = new RecordingPlatformGraph();
      const coreService = new RuntimeAwareCoreService();
      const vpnRegistry = new VpnSessionRegistry();
      let controllerFactoryRegistry: VpnSessionRegistry | undefined = undefined;
      const composition = createComposition({
        coreService,
        vpnRegistry,
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createVpnController: (registry: VpnSessionRegistry): VpnControllerPort => {
          controllerFactoryRegistry = registry;
          return new HarmonyVpnController(registry, new InertVpnExtensionAbilityApi());
        }
      });

      await composition.initialize();

      const compositionState = composition.state();
      expect(compositionState.status).assertEqual('READY');
      if (compositionState.status === 'READY') {
        expect(compositionState.vpnRegistry === vpnRegistry).assertTrue();
      }
      expect(controllerFactoryRegistry === vpnRegistry).assertTrue();
      await composition.close();
    });

    it('extensionFactoryUsesTheExactInjectedRegistryForUnexpectedFailureCleanup', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const graph = new RecordingPlatformGraph();
      const coreService = new RuntimeAwareCoreService();
      const vpnRegistry = new VpnSessionRegistry();
      const pendingRequest = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      vpnRegistry.beginPending(pendingRequest);
      const composition = createComposition({
        coreService,
        vpnRegistry,
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        }
      });

      await composition.initialize();

      const runner = resolveVpnExtensionComposition(new FakeVpnExtensionContextRecord('app-composition') as common.VpnExtensionContext);
      await runner.start(new NullParametersWantRecord() as Want);

      expect(vpnRegistry.snapshot().state).assertEqual('STOPPED');
      expect(vpnRegistry.snapshot().activeRequest).assertNull();
      await composition.close();
      resetVpnExtensionCompositionForTesting();
    });

    it('nonSharedStopResolvesWithoutTouchingTheSharedRegistry', 0, async () => {
      const sharedGraph = new RecordingPlatformGraph();
      const sharedCoreService = new RuntimeAwareCoreService();
      const sharedComposition = createComposition({
        coreService: sharedCoreService,
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return sharedGraph;
        }
      });
      await sharedComposition.initialize();
      const sharedState = sharedComposition.state();
      expect(sharedState.status).assertEqual('READY');
      if (sharedState.status !== 'READY') {
        return;
      }
      const sharedRegistry = sharedState.vpnRegistry;
      sharedRegistry.beginPending(createVpnStartRequest('shared-profile', 'shared-version', 'shared-session'));

      const customGraph = new RecordingPlatformGraph(new SeededRepository(createEligibleProfile('custom-profile')));
      const customCoreService = new RuntimeAwareCoreService();
      const customRegistry = new VpnSessionRegistry();
      const customComposition = createComposition({
        coreService: customCoreService,
        vpnRegistry: customRegistry,
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return customGraph;
        }
      });
      await customComposition.initialize();
      const customState = customComposition.state();
      expect(customState.status).assertEqual('READY');
      if (customState.status !== 'READY') {
        return;
      }
      const startResult = await customState.application.startVpnGlobalCapture();
      expect(startResult.kind).assertEqual('STARTED');

      const stopOutcome = await Promise.race([
        customState.application.stopVpnGlobalCapture().then(() => 'resolved'),
        new TimeoutPromiseRecord('timeout', 20).promise
      ]);

      expect(stopOutcome).assertEqual('resolved');
      expect(customRegistry.snapshot().state).assertEqual('STOPPED');
      expect(sharedRegistry.snapshot().state).assertEqual('AWAITING_CONSENT');
      await customComposition.close();
      await sharedComposition.close();
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
          return useSecondAttempt ? secondApplication : firstApplication;
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

    it('sanitizeInitializeFailureWhenDisposeThrowsAndStillClosesGraph', 0, async () => {
      const graph = new RecordingPlatformGraph();
      graph.closeError = new Error('close should not win');
      const application = new RecordingApplication();
      application.initializeError = new Error('initialize failed');
      application.disposeError = new Error('dispose leaked https://profiles.example.com/raw?token=secret-value');
      const states: ApplicationCompositionState[] = [];
      const composition = createComposition({
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createProfileApplication: (): ProfileApplication => {
          return application;
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

      expect(application.disposeCallCount).assertEqual(1);
      expect(graph.closeCallCount).assertEqual(1);
      expect(collectStatuses(states)).assertEqual('LOADING>ERROR');
      expect(composition.state().status).assertEqual('ERROR');
      expect(thrownError !== undefined).assertTrue();
      if (thrownError === undefined) {
        return;
      }
      expect(thrownError.stage).assertEqual('PERSISTENCE');
      expect(thrownError.technicalDetail.includes('profiles.example.com')).assertFalse();
      expect(thrownError.technicalDetail.includes('secret-value')).assertFalse();
    });

    it('sanitizeInitializeFailureWhenGraphCloseThrows', 0, async () => {
      const graph = new RecordingPlatformGraph();
      graph.closeError = new Error('close leaked https://profiles.example.com/close?token=secret-close');
      const application = new RecordingApplication();
      application.initializeError = new Error('initialize failed');
      const states: ApplicationCompositionState[] = [];
      const composition = createComposition({
        createPlatformGraph: async (): Promise<PlatformGraph> => {
          return graph;
        },
        createProfileApplication: (): ProfileApplication => {
          return application;
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

      expect(application.disposeCallCount).assertEqual(1);
      expect(graph.closeCallCount).assertEqual(1);
      expect(collectStatuses(states)).assertEqual('LOADING>ERROR');
      expect(composition.state().status).assertEqual('ERROR');
      expect(thrownError !== undefined).assertTrue();
      if (thrownError === undefined) {
        return;
      }
      expect(thrownError.stage).assertEqual('PERSISTENCE');
      expect(thrownError.technicalDetail.includes('profiles.example.com')).assertFalse();
      expect(thrownError.technicalDetail.includes('secret-close')).assertFalse();
    });
  });
}
