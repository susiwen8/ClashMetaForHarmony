import common from '@ohos.app.ability.common';
import type { Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { CORE_BRIDGE_VERSION, createCoreService } from '@cmfa/core';
import { PlatformFactory, type PlatformGraph } from '@cmfa/platform';
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
  type CoreService,
  type VpnControllerPort
} from '@cmfa/shared';
import type { ApplicationComposition, ApplicationCompositionState } from './ApplicationComposition';
import { HarmonyVpnController, type VpnExtensionAbilityApi } from '../vpn/HarmonyVpnController';
import { VpnExtensionComposition, installVpnExtensionCompositionFactoryForTesting } from '../vpn/VpnExtensionComposition';
import { VpnSessionRegistry } from '../vpn/VpnSessionRegistry';

export interface Phase1LaunchContext {
  selfTest: boolean;
  runId: string;
  runnerStartedAt: string;
  filesDir: string;
  probeOriginRunId: string;
  probeOriginUrl: string;
  probeCaPem: string;
  probeExpectedBodySha256: string;
  probeFixturePath: string;
  probeFixtureSha256: string;
}

export type Phase1LaunchListener = (context: Phase1LaunchContext) => void;

export interface Phase2SelfTestProbeRequest {
  probeRunId: string;
  protocol: string;
  listenerAddress: string;
  originUrl: string;
  caPem: string;
  expectedBodySha256: string;
}

export interface Phase2SelfTestProbeTrackerRecord {
  connectionId: string;
  sourceAddress: string;
  destinationAddress: string;
  inboundType: string;
  openedAt: string;
}

export interface Phase2SelfTestProbeError {
  code: string;
  stage: string;
  detail: string;
}

export interface Phase2SelfTestProbeResult {
  ok: boolean;
  protocol: string;
  httpStatus: number;
  bodyBytes: number;
  probeRunId: string;
  requestIdEcho: string;
  originId: string;
  responseSha256: string;
  tlsPeerSha256: string;
  startedAt: string;
  completedAt: string;
  clientLocalAddress: string;
  clientRemoteAddress: string;
  tracker: Phase2SelfTestProbeTrackerRecord;
  error: Phase2SelfTestProbeError;
}

export interface Phase2SelfTestCoreService extends CoreService {
  probeHttpsForSelfTest(request: Phase2SelfTestProbeRequest): Promise<Phase2SelfTestProbeResult>;
}

interface AppStorageBridge {
  setOrCreate<T>(key: string, value: T): void;
  get<T>(key: string): T | undefined;
}

const PHASE1_LAUNCH_CONTEXT_KEY: string = '__cmfa_phase1_launch_context__';
const APPLICATION_COMPOSITION_STORAGE_KEY: string = '__cmfa_application_composition__';
const SELF_TEST_KEY = 'cmfa.phase1.selfTest';
const RUN_ID_KEY = 'cmfa.phase1.runId';
const RUNNER_STARTED_AT_KEY = 'cmfa.phase1.runnerStartedAt';
const PROBE_ORIGIN_RUN_ID_KEY = 'cmfa.phase2.originRunId';
const PROBE_ORIGIN_URL_KEY = 'cmfa.phase2.originUrl';
const PROBE_CA_PEM_KEY = 'cmfa.phase2.caPem';
const PROBE_EXPECTED_BODY_SHA256_KEY = 'cmfa.phase2.expectedBodySha256';
const PROBE_FIXTURE_PATH_KEY = 'cmfa.phase2.fixturePath';
const PROBE_FIXTURE_SHA256_KEY = 'cmfa.phase2.fixtureSha256';
declare const AppStorage: AppStorageBridge;
const phase1DefaultContext: Phase1LaunchContext = {
  selfTest: false,
  runId: '',
  runnerStartedAt: '',
  filesDir: '',
  probeOriginRunId: '',
  probeOriginUrl: '',
  probeCaPem: '',
  probeExpectedBodySha256: '',
  probeFixturePath: '',
  probeFixtureSha256: ''
};
const sharedCoreService: CoreService = createCoreService();
let phase1LaunchListener: Phase1LaunchListener | undefined = undefined;
let phase1LaunchListenerId: number = 0;
let sharedVpnRegistry: VpnSessionRegistry | undefined = undefined;
let sharedVpnController: HarmonyVpnController | undefined = undefined;
let vpnExtensionRegistryResolver: (() => VpnSessionRegistry) | undefined = undefined;

export interface ApplicationCompositionDependencies {
  coreService?: CoreService;
  createPlatformGraph?: (context: common.UIAbilityContext) => Promise<PlatformGraph>;
  createProfileApplication?: (
    graph: PlatformGraph,
    coreService: CoreService,
    vpnRegistry: VpnSessionRegistry
  ) => ProfileApplication;
  vpnRegistry?: VpnSessionRegistry;
  createVpnController?: (registry: VpnSessionRegistry) => VpnControllerPort;
}

export function getCoreService(): CoreService {
  return sharedCoreService;
}

export function getSelfTestCoreService(): Phase2SelfTestCoreService {
  return sharedCoreService as Phase2SelfTestCoreService;
}

export function getBridgeVersion(): string {
  return CORE_BRIDGE_VERSION;
}

export function applyPhase1LaunchWant(context: common.UIAbilityContext, want: Want): Phase1LaunchContext {
  const launchContext: Phase1LaunchContext = createPhase1LaunchContext(context, want);
  setPhase1LaunchContext(launchContext);
  return launchContext;
}

export function setPhase1LaunchContext(context: Phase1LaunchContext): void {
  AppStorage.setOrCreate<Phase1LaunchContext>(PHASE1_LAUNCH_CONTEXT_KEY, context);
  phase1LaunchListener?.(context);
}

export function subscribePhase1LaunchContext(listener: Phase1LaunchListener): number {
  phase1LaunchListenerId += 1;
  phase1LaunchListener = listener;
  return phase1LaunchListenerId;
}

export function unsubscribePhase1LaunchContext(subscriptionId: number): void {
  if (subscriptionId === phase1LaunchListenerId) {
    phase1LaunchListener = undefined;
  }
}

export function getPhase1LaunchContext(): Phase1LaunchContext {
  const raw: Phase1LaunchContext | undefined = AppStorage.get<Phase1LaunchContext>(PHASE1_LAUNCH_CONTEXT_KEY);
  if (raw === undefined) {
    return phase1DefaultContext;
  }
  return {
    selfTest: raw.selfTest === true,
    runId: raw.runId,
    runnerStartedAt: raw.runnerStartedAt,
    filesDir: raw.filesDir,
    probeOriginRunId: raw.probeOriginRunId ?? '',
    probeOriginUrl: raw.probeOriginUrl ?? '',
    probeCaPem: raw.probeCaPem ?? '',
    probeExpectedBodySha256: raw.probeExpectedBodySha256 ?? '',
    probeFixturePath: raw.probeFixturePath ?? '',
    probeFixtureSha256: raw.probeFixtureSha256 ?? ''
  };
}

export function createApplicationCompositionStorage(composition: ApplicationComposition): LocalStorage {
  const storage = new LocalStorage();
  storage.setOrCreate<ApplicationComposition>(APPLICATION_COMPOSITION_STORAGE_KEY, composition);
  return storage;
}

export function getApplicationCompositionFromStorage(storage: LocalStorage | undefined): ApplicationComposition | undefined {
  return storage?.get<ApplicationComposition>(APPLICATION_COMPOSITION_STORAGE_KEY);
}

export function createApplicationComposition(
  context: common.UIAbilityContext,
  dependencies?: ApplicationCompositionDependencies
): ApplicationComposition {
  return new ApplicationCompositionRecord(context, dependencies ?? {});
}

class SystemVpnExtensionAbilityApi implements VpnExtensionAbilityApi {
  private lastWant?: Want;
  private onStopped?: () => void;

  async startVpnExtensionAbility(want: Want): Promise<void> {
    this.lastWant = want;
    await vpnExtension.startVpnExtensionAbility(want);
  }

  async stopVpnExtensionAbility(): Promise<void> {
    const stopWant: Want | undefined = this.lastWant;
    if (stopWant === undefined) {
      return;
    }
    await vpnExtension.stopVpnExtensionAbility(stopWant);
    this.onStopped?.();
  }

  bindStopHandler(handler: () => void): void {
    this.onStopped = handler;
  }
}

class ApplicationCompositionRecord implements ApplicationComposition {
  private readonly context: common.UIAbilityContext;
  private readonly dependencies: ApplicationCompositionDependencies;
  private readonly listeners: Map<number, (state: ApplicationCompositionState) => void> = new Map();
  private readonly coreService: CoreService;
  private listenerId: number = 0;
  private currentState: ApplicationCompositionState = createLoadingState();
  private initializePromise?: Promise<void>;
  private closePromise?: Promise<void>;
  private graph?: PlatformGraph;
  private application?: ProfileApplication;
  private vpnRegistry?: VpnSessionRegistry;

  constructor(context: common.UIAbilityContext, dependencies: ApplicationCompositionDependencies) {
    this.context = context;
    this.dependencies = dependencies;
    this.coreService = dependencies.coreService ?? sharedCoreService;
  }

  initialize(): Promise<void> {
    if (this.currentState.status === 'READY') {
      return Promise.resolve();
    }
    if (this.initializePromise !== undefined) {
      return this.initializePromise;
    }
    const loadingState: ApplicationCompositionState = createLoadingState();
    this.publish(loadingState);
    const initializePromise: Promise<void> = this.initializeInternal();
    this.initializePromise = initializePromise;
    return initializePromise;
  }

  state(): ApplicationCompositionState {
    return this.currentState;
  }

  subscribe(listener: (state: ApplicationCompositionState) => void): number {
    this.listenerId += 1;
    this.listeners.set(this.listenerId, listener);
    return this.listenerId;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  async close(): Promise<void> {
    if (this.closePromise !== undefined) {
      await this.closePromise;
      return;
    }
    const closePromise: Promise<void> = this.closeInternal();
    this.closePromise = closePromise;
    await closePromise;
  }

  private async initializeInternal(): Promise<void> {
    try {
      const graph: PlatformGraph = await this.createPlatformGraph(this.context);
      this.graph = graph;
      const vpnRegistry: VpnSessionRegistry = this.resolveVpnRegistry();
      this.vpnRegistry = vpnRegistry;
      setVpnExtensionRegistryResolver(() => vpnRegistry);
      ensureVpnExtensionFactoryInstalled();
      const application: ProfileApplication = this.createProfileApplication(graph, this.coreService, vpnRegistry);
      this.application = application;
      await application.initialize();
      const readyState: ApplicationCompositionState = createReadyState(application, vpnRegistry);
      this.publish(readyState);
    } catch (_error) {
      await this.closeResources();
      const appError: ApplicationCompositionPersistenceError = new ApplicationCompositionPersistenceError(
        'Application composition initialization failed.'
      );
      const errorState: ApplicationCompositionState = createErrorState(appError);
      this.publish(errorState);
      throw appError;
    } finally {
      if (this.currentState.status !== 'READY') {
        this.initializePromise = undefined;
      }
    }
  }

  private async closeInternal(): Promise<void> {
    await this.initializePromise?.catch(() => {
    });
    const cleanupError: ApplicationCompositionPersistenceError | null = await this.closeResources();
    this.initializePromise = undefined;
    if (cleanupError !== null) {
      throw cleanupError;
    }
  }

  private async closeResources(): Promise<ApplicationCompositionPersistenceError | null> {
    const application: ProfileApplication | undefined = this.application;
    const graph: PlatformGraph | undefined = this.graph;
    this.application = undefined;
    this.graph = undefined;
    let cleanupError: ApplicationCompositionPersistenceError | null = null;
    if (application !== undefined) {
      try {
        application.dispose();
      } catch (_) {
        cleanupError = createCleanupError();
      }
    }
    if (graph !== undefined) {
      try {
        await graph.close();
      } catch (_) {
        cleanupError = cleanupError ?? createCleanupError();
      }
    }
    return cleanupError;
  }

  private createPlatformGraph(context: common.UIAbilityContext): Promise<PlatformGraph> {
    if (this.dependencies.createPlatformGraph !== undefined) {
      return this.dependencies.createPlatformGraph(context);
    }
    return new PlatformFactory(context).create();
  }

  private createProfileApplication(
    graph: PlatformGraph,
    coreService: CoreService,
    vpnRegistry: VpnSessionRegistry
  ): ProfileApplication {
    if (this.dependencies.createProfileApplication !== undefined) {
      return this.dependencies.createProfileApplication(graph, coreService, vpnRegistry);
    }
    const runtimeCoordinator: LocalRuntimeCoordinator = new LocalRuntimeCoordinator({
      repository: graph.repository,
      contentStore: graph.contentStore,
      coreService,
      clock: graph.clock
    });
    const queue = new SerialCommandQueue();
    const commitService = new ProfileCommitService({
      repository: graph.repository,
      contentStore: graph.contentStore,
      clock: graph.clock
    });
    const importUseCase = new ImportProfileUseCase({
      repository: graph.repository,
      contentStore: graph.contentStore,
      sourceGateway: graph.sourceGateway,
      secretStore: graph.secretStore,
      coreService,
      clock: graph.clock,
      idGenerator: graph.idGenerator,
      queue,
      commitService
    });
    const refreshUseCase = new RefreshProfileUseCase({
      repository: graph.repository,
      contentStore: graph.contentStore,
      sourceGateway: graph.sourceGateway,
      secretStore: graph.secretStore,
      coreService,
      clock: graph.clock,
      queue,
      commitService
    });
    const manageProfileUseCases = new ManageProfileUseCases({
      repository: graph.repository,
      contentStore: graph.contentStore,
      secretStore: graph.secretStore,
      coreService,
      clock: graph.clock,
      runtimeCoordinator
    });
    return new ProfileApplication({
      importUseCase,
      refreshUseCase,
      manageProfileUseCases,
      runtimeCoordinator,
      commitService,
      repository: graph.repository,
      vpnController: this.createVpnController(vpnRegistry),
      idGenerator: graph.idGenerator
    });
  }

  private resolveVpnRegistry(): VpnSessionRegistry {
    return this.dependencies.vpnRegistry ?? resolveSharedVpnRegistry();
  }

  private createVpnController(registry: VpnSessionRegistry): VpnControllerPort {
    if (this.dependencies.createVpnController !== undefined) {
      return this.dependencies.createVpnController(registry);
    }
    if (registry === resolveSharedVpnRegistry()) {
      return resolveSharedVpnController();
    }
    return createBoundHarmonyVpnController(registry);
  }

  private publish(state: ApplicationCompositionState): void {
    this.currentState = state;
    const listeners: Array<(state: ApplicationCompositionState) => void> = [];
    this.listeners.forEach((listener) => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](state);
    }
  }
}

function createPhase1LaunchContext(context: common.UIAbilityContext, want: Want): Phase1LaunchContext {
  const parameters: Record<string, Object> = want.parameters ?? {};
  const selfTestValue: string = `${parameters[SELF_TEST_KEY] ?? ''}`;
  return {
    selfTest: selfTestValue === 'true',
    runId: `${parameters[RUN_ID_KEY] ?? ''}`,
    runnerStartedAt: `${parameters[RUNNER_STARTED_AT_KEY] ?? ''}`,
    filesDir: context.filesDir,
    probeOriginRunId: `${parameters[PROBE_ORIGIN_RUN_ID_KEY] ?? ''}`,
    probeOriginUrl: `${parameters[PROBE_ORIGIN_URL_KEY] ?? ''}`,
    probeCaPem: `${parameters[PROBE_CA_PEM_KEY] ?? ''}`,
    probeExpectedBodySha256: `${parameters[PROBE_EXPECTED_BODY_SHA256_KEY] ?? ''}`,
    probeFixturePath: `${parameters[PROBE_FIXTURE_PATH_KEY] ?? ''}`,
    probeFixtureSha256: `${parameters[PROBE_FIXTURE_SHA256_KEY] ?? ''}`
  };
}

function createCleanupError(): ApplicationCompositionPersistenceError {
  return new ApplicationCompositionPersistenceError('Application composition cleanup failed.');
}

class ApplicationCompositionPersistenceError extends Error implements AppError {
  readonly code: string;
  readonly stage: 'PERSISTENCE' = 'PERSISTENCE';
  readonly userMessageResource: string;
  readonly technicalDetail: string;
  readonly timestamp: string;
  readonly retryable: boolean;

  constructor(detail: string) {
    const appError: AppError = createAppError('PERSISTENCE', detail, {
      retryable: true
    });
    super(appError.technicalDetail);
    this.code = appError.code;
    this.userMessageResource = appError.userMessageResource;
    this.technicalDetail = appError.technicalDetail;
    this.timestamp = appError.timestamp;
    this.retryable = appError.retryable;
  }
}

function createLoadingState(): ApplicationCompositionState {
  return {
    status: 'LOADING'
  };
}

function createReadyState(application: ProfileApplication, vpnRegistry: VpnSessionRegistry): ApplicationCompositionState {
  return {
    status: 'READY',
    application,
    vpnRegistry
  };
}

function createErrorState(error: AppError): ApplicationCompositionState {
  return {
    status: 'ERROR',
    error
  };
}

function ensureVpnExtensionFactoryInstalled(): void {
  installVpnExtensionCompositionFactoryForTesting((context: common.VpnExtensionContext | undefined) => {
    return new VpnExtensionComposition(context, {
      registry: resolveInstalledVpnExtensionRegistry()
    });
  });
}

function setVpnExtensionRegistryResolver(resolver: () => VpnSessionRegistry): void {
  vpnExtensionRegistryResolver = resolver;
}

function resolveSharedVpnRegistry(): VpnSessionRegistry {
  if (sharedVpnRegistry !== undefined) {
    return sharedVpnRegistry;
  }
  sharedVpnRegistry = new VpnSessionRegistry();
  return sharedVpnRegistry;
}

function resolveInstalledVpnExtensionRegistry(): VpnSessionRegistry {
  if (vpnExtensionRegistryResolver !== undefined) {
    return vpnExtensionRegistryResolver();
  }
  return resolveSharedVpnRegistry();
}

function resolveSharedVpnController(): HarmonyVpnController {
  if (sharedVpnController !== undefined) {
    return sharedVpnController;
  }
  sharedVpnController = createBoundHarmonyVpnController(resolveSharedVpnRegistry());
  ensureVpnExtensionFactoryInstalled();
  return sharedVpnController;
}

function createBoundHarmonyVpnController(registry: VpnSessionRegistry): HarmonyVpnController {
  const api = new SystemVpnExtensionAbilityApi();
  const controller = new HarmonyVpnController(registry, api);
  api.bindStopHandler(() => {
    controller.handleExtensionDestroyed();
  });
  return controller;
}
