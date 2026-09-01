import common from '@ohos.app.ability.common';
import type { Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CORE_BRIDGE_VERSION, createCoreService } from '@cmfa/core';
import {
  HarmonyVpnRpcPlatformFactory,
  PlatformFactory,
  createHarmonyRuntimeLogExporter,
  createHarmonyRuntimeLogStore,
  type HarmonyVpnRpcPlatformBundle,
  type PlatformGraph
} from '@cmfa/platform';
import {
  ActiveProfileProxyResolver,
  buildVpnRpcCatalogFromCore,
  createAppError,
  createProxyRuntimeIdentity,
  ImportProfileUseCase,
  LocalRuntimeCoordinator,
  ManageProfileUseCases,
  ProfileApplication,
  ProfileCommitService,
  ProxyService,
  RefreshProfileUseCase,
  SerialCommandQueue,
  SubscriptionOneClickVpnConfirmation,
  VpnProxyCommandBus,
  VpnRpcClient,
  VpnRpcProxyHandler,
  VpnRpcRuntimeToolsClient,
  type AppError,
  type BoundedDelaySchedulerPort,
  type CancelableDelayTask,
  type ClockPort,
  type CoreProxyDelaySnapshot,
  type CoreProxyGroupList,
  type CoreProxyGroupResult,
  type CoreProxyPort,
  type CoreProxyQueryContext,
  type CoreProxySelectionApplied,
  type CoreService,
  type OneClickVpnConfirmationPort,
  type Profile,
  type VpnOpaqueCatalog,
  type VpnControllerPort,
  type VpnProxyCommandHandler,
  type VpnProxyRuntimeMirrorPort,
  type VpnRpcCancelableTaskPort,
  type VpnRpcClientContext,
  type VpnRpcClientPort,
  type VpnRpcClockPort,
  type VpnRpcTrafficCounters,
  type VpnRpcSchedulerPort
} from '@cmfa/shared';
import type { ApplicationComposition, ApplicationCompositionState } from './ApplicationComposition';
import {
  HarmonyVpnController,
  type HarmonyVpnControllerDependencies,
  type VpnExtensionAbilityApi
} from '../vpn/HarmonyVpnController';
import {
  VpnTrafficMonitor,
  type VpnTrafficCounterSourcePort,
  type VpnTrafficMonitorLifecyclePort,
  type VpnTrafficMonitorReadPort
} from '../vpn/VpnTrafficMonitor';
import { UiOwnedVpnExtensionAbilityApi } from '../vpn/UiOwnedVpnExtensionAbilityApi';
import { VpnSessionRegistry } from '../vpn/VpnSessionRegistry';

const INITIALIZATION_LOG_DOMAIN: number = 0x0000;
const INITIALIZATION_LOG_TAG: string = 'CMFAInit';
const VPN_UI_LOG_DOMAIN: number = 0x0000;
const VPN_UI_LOG_TAG: string = 'CMFAVpn';

function reportVpnUiStage(stage: string): void {
  hilog.warn(VPN_UI_LOG_DOMAIN, VPN_UI_LOG_TAG, '%{public}s', stage);
}

class CoreProxyServiceAdapter implements CoreProxyPort {
  private readonly coreService: CoreService;

  constructor(coreService: CoreService) {
    this.coreService = coreService;
  }

  async loadConfiguration(path: string): Promise<void> {
    await this.coreService.loadConfiguration(path);
  }

  async queryProxyGroups(context: CoreProxyQueryContext, selectableOnly: boolean): Promise<CoreProxyGroupList> {
    return await this.coreService.queryProxyGroups(context, selectableOnly);
  }

  async queryProxyGroup(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyGroupResult> {
    return await this.coreService.queryProxyGroup(context, groupName);
  }

  async selectProxy(context: CoreProxyQueryContext, groupName: string, memberName: string): Promise<CoreProxySelectionApplied> {
    return await this.coreService.selectProxy(context, groupName, memberName);
  }

  async startProxyDelayTest(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyDelaySnapshot> {
    return await this.coreService.startProxyDelayTest(context, groupName);
  }

  async readProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot> {
    return await this.coreService.readProxyDelayTest(jobId);
  }

  async cancelProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot> {
    return await this.coreService.cancelProxyDelayTest(jobId);
  }
}

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
const BUNDLE_NAME: string = 'com.github.kr328.clash.harmony';
const ABILITY_NAME: string = 'CmfaVpnExtensionAbility';
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
let sharedVpnCommandBus: VpnProxyCommandBus | undefined = undefined;

class TimeoutDelayTask implements CancelableDelayTask {
  private readonly timerId: number;

  constructor(timerId: number) {
    this.timerId = timerId;
  }

  cancel(): void {
    clearTimeout(this.timerId);
  }
}

class TimeoutDelayScheduler implements BoundedDelaySchedulerPort {
  schedule(delayMs: number, runner: () => Promise<void>): CancelableDelayTask {
    const timerId: number = setTimeout(() => {
      void runner();
    }, delayMs);
    return new TimeoutDelayTask(timerId);
  }
}

interface RuntimeMirrorInitializableController {
  initializeRuntimeMirror?(): Promise<void>;
}

interface UiOwnedVpnExtensionAbilityApiLike extends VpnExtensionAbilityApi {
  bindStopHandler(handler: () => void): void;
}

interface VpnRpcCatalogInputs {
  profileHash: string;
  revisionHash: string;
  sessionHash: string;
  configPath: string;
}

class VpnRpcCatalogInputsValue implements VpnRpcCatalogInputs {
  profileHash: string = '';
  revisionHash: string = '';
  sessionHash: string = '';
  configPath: string = '';
}

interface BoundHarmonyVpnControllerResult {
  controller: HarmonyVpnController;
  trafficMonitor: VpnTrafficMonitorReadPort;
}

class HarmonyVpnControllerDependenciesRecord implements HarmonyVpnControllerDependencies {
  runtimeMirror?: VpnProxyRuntimeMirrorPort;
  scheduler?: BoundedDelaySchedulerPort;
  trafficMonitor?: VpnTrafficMonitorReadPort & VpnTrafficMonitorLifecyclePort;
  trafficReportStage?: (stage: string) => void;
  rpcClient?: VpnRpcClientPort;
}

class VpnRpcTrafficCounterSourceRecord implements VpnTrafficCounterSourcePort {
  private readonly rpcClient: VpnRpcClientPort;

  constructor(rpcClient: VpnRpcClientPort) {
    this.rpcClient = rpcClient;
  }

  async refreshTrafficCounters(): Promise<VpnRpcTrafficCounters> {
    return await this.rpcClient.refreshTrafficCounters();
  }
}

class VpnRpcCancelableTaskAdapter implements VpnRpcCancelableTaskPort {
  private readonly task: CancelableDelayTask;

  constructor(task: CancelableDelayTask) {
    this.task = task;
  }

  cancel(): void {
    this.task.cancel();
  }
}

class VpnRpcSchedulerAdapter implements VpnRpcSchedulerPort {
  private readonly scheduler: BoundedDelaySchedulerPort;

  constructor(scheduler: BoundedDelaySchedulerPort) {
    this.scheduler = scheduler;
  }

  schedule(delayMs: number, runner: () => Promise<void>): VpnRpcCancelableTaskPort {
    return new VpnRpcCancelableTaskAdapter(this.scheduler.schedule(delayMs, runner));
  }
}

class SystemVpnRpcClock implements VpnRpcClockPort, ClockPort {
  nowMs(): number {
    return Date.now();
  }
}

class UiVpnRpcRuntimeMirror implements VpnProxyRuntimeMirrorPort {
  private readonly graph: PlatformGraph;
  private readonly coreProxy: CoreProxyPort;
  private readonly commandBus: VpnProxyCommandBus;
  private readonly bundle: HarmonyVpnRpcPlatformBundle;
  private readonly client: VpnRpcClientPort;
  private readonly handlerFactory: (client: VpnRpcClientPort, catalog: VpnOpaqueCatalog) => VpnProxyCommandHandler;
  private activeBindingKey?: string;
  private activeSessionId?: string;

  constructor(
    graph: PlatformGraph,
    coreProxy: CoreProxyPort,
    commandBus: VpnProxyCommandBus,
    bundle: HarmonyVpnRpcPlatformBundle,
    client: VpnRpcClientPort,
    handlerFactory: (client: VpnRpcClientPort, catalog: VpnOpaqueCatalog) => VpnProxyCommandHandler
  ) {
    this.graph = graph;
    this.coreProxy = coreProxy;
    this.commandBus = commandBus;
    this.bundle = bundle;
    this.client = client;
    this.handlerFactory = handlerFactory;
  }

  async bindExistingSession(request: import('@cmfa/shared').VpnStartRequest): Promise<void> {
    const context: VpnRpcClientContext | null = this.client.activeContext();
    if (this.client.state() !== 'READY' ||
      context === null ||
      context.guards.profileHash === null ||
      context.guards.revisionHash === null ||
      context.guards.catalogDigest === null) {
      throw new Error('VPN RPC UI runtime mirror unavailable.');
    }
    const bindingKey: string =
      `${request.profileId}\u0000${request.versionId}\u0000${request.sessionId}\u0000${context.guards.catalogDigest}\u0000${context.sessionGeneration}`;
    if (this.activeBindingKey === bindingKey) {
      return;
    }
    if (this.activeSessionId !== undefined) {
      await this.commandBus.deactivate(this.activeSessionId);
      this.activeSessionId = undefined;
      this.activeBindingKey = undefined;
    }
    const inputs: VpnRpcCatalogInputs = await resolveVpnRpcCatalogInputs(this.graph, request);
    const catalog: VpnOpaqueCatalog = await buildVpnRpcCatalogFromCore(
      this.bundle.crypto,
      this.coreProxy,
      inputs.profileHash,
      inputs.revisionHash,
      inputs.sessionHash,
      inputs.configPath
    );
    if (catalog.profileHash !== context.guards.profileHash ||
      catalog.revisionHash !== context.guards.revisionHash ||
      catalog.catalogDigest !== context.guards.catalogDigest) {
      throw new Error('VPN RPC catalog mismatch.');
    }
    const handler: VpnProxyCommandHandler = this.handlerFactory(this.client, catalog);
    this.commandBus.bind(
      createProxyRuntimeIdentity(request.profileId, request.versionId, catalog.revisionHash, request.sessionId),
      handler,
      context.sessionGeneration
    );
    this.activeSessionId = request.sessionId;
    this.activeBindingKey = bindingKey;
  }

  async deactivate(sessionId: string): Promise<void> {
    if (this.activeSessionId !== sessionId) {
      return;
    }
    await this.commandBus.deactivate(sessionId);
    this.activeSessionId = undefined;
    this.activeBindingKey = undefined;
  }
}

export interface ApplicationCompositionDependencies {
  coreService?: CoreService;
  createPlatformGraph?: (context: common.UIAbilityContext) => Promise<PlatformGraph>;
  createProfileApplication?: (
    graph: PlatformGraph,
    coreService: CoreService,
    vpnRegistry: VpnSessionRegistry,
    commandBus: VpnProxyCommandBus,
    vpnController?: VpnControllerPort,
    oneClickVpnConfirmation?: OneClickVpnConfirmationPort
  ) => ProfileApplication;
  vpnRegistry?: VpnSessionRegistry;
  commandBus?: VpnProxyCommandBus;
  createVpnController?: (registry: VpnSessionRegistry) => VpnControllerPort;
  createOneClickVpnConfirmation?: (controller: VpnControllerPort) => OneClickVpnConfirmationPort;
  createVpnRuntimeMirror?: (
    graph: PlatformGraph,
    coreService: CoreService,
    commandBus: VpnProxyCommandBus
  ) => VpnProxyRuntimeMirrorPort;
  createVpnRpcPlatformBundle?: () => HarmonyVpnRpcPlatformBundle;
  createVpnRpcClient?: (
    bundle: HarmonyVpnRpcPlatformBundle,
    scheduler: VpnRpcSchedulerPort,
    clock: VpnRpcClockPort
  ) => VpnRpcClientPort;
  createVpnRpcHandler?: (client: VpnRpcClientPort, catalog: VpnOpaqueCatalog, clock: import('@cmfa/shared').Clock) => VpnProxyCommandHandler;
  createVpnExtensionAbilityApi?: (context: common.UIAbilityContext) => UiOwnedVpnExtensionAbilityApiLike;
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

export function buildForwardedVpnExtensionWant(sourceWant: Want, launchContext: Phase1LaunchContext): Want {
  const sourceParameters: Record<string, Object> | undefined = sourceWant.parameters;
  let forwardedParameters: Record<string, Object> | undefined = undefined;
  if (sourceParameters !== undefined) {
    forwardedParameters = {};
    const parameterKeys: string[] = Object.keys(sourceParameters);
    for (let index: number = 0; index < parameterKeys.length; index += 1) {
      const key: string = parameterKeys[index];
      forwardedParameters[key] = sourceParameters[key];
    }
  }
  if (launchContext.runId.length > 0) {
    if (forwardedParameters === undefined) {
      forwardedParameters = {};
    }
    forwardedParameters[RUN_ID_KEY] = launchContext.runId;
  }
  return {
    deviceId: sourceWant.deviceId ?? '',
    bundleName: sourceWant.bundleName,
    abilityName: sourceWant.abilityName,
    parameters: forwardedParameters
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
  async startVpnExtensionAbility(want: Want): Promise<void> {
    const forwardedWant: Want = buildForwardedVpnExtensionWant(want, getPhase1LaunchContext());
    reportVpnUiStage('ui.extension.start.invoke');
    try {
      const startPromise: Promise<void> = vpnExtension.startVpnExtensionAbility(forwardedWant);
      reportVpnUiStage('ui.extension.start.returned');
      await startPromise;
      reportVpnUiStage('ui.extension.start.resolved');
    } catch (error) {
      reportVpnUiStage('ui.extension.start.rejected');
      throw error as Error;
    }
  }

  async stopVpnExtensionAbility(): Promise<void> {
    const stopWant: Want = {
      deviceId: '',
      bundleName: BUNDLE_NAME,
      abilityName: ABILITY_NAME
    };
    reportVpnUiStage('ui.extension.stop.invoke');
    try {
      const stopPromise: Promise<void> = vpnExtension.stopVpnExtensionAbility(stopWant);
      reportVpnUiStage('ui.extension.stop.returned');
      await stopPromise;
      reportVpnUiStage('ui.extension.stop.resolved');
    } catch (error) {
      reportVpnUiStage('ui.extension.stop.rejected');
      throw error as Error;
    }
  }

  async updateTraffic(
    _sessionId: string,
    _uploadBytesPerSecond: number,
    _downloadBytesPerSecond: number
  ): Promise<void> {
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
  private ownedVpnController?: HarmonyVpnController;
  private ownedVpnTrafficMonitor?: VpnTrafficMonitorReadPort;
  private ownedVpnRpcPlatformBundle?: HarmonyVpnRpcPlatformBundle;
  private ownedVpnRpcClient?: VpnRpcClientPort;

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
    const closePromise: Promise<void> = this.closeInternal().finally(() => {
      this.closePromise = undefined;
    });
    this.closePromise = closePromise;
    await closePromise;
  }

  private async initializeInternal(): Promise<void> {
    try {
      const graph: PlatformGraph = await this.createPlatformGraph(this.context);
      this.graph = graph;
      const vpnRegistry: VpnSessionRegistry = this.resolveVpnRegistry();
      this.vpnRegistry = vpnRegistry;
      const commandBus: VpnProxyCommandBus = this.resolveVpnCommandBus();
      const vpnRpcClient: VpnRpcClientPort | undefined = this.shouldCreateVpnController()
        ? this.resolveVpnRpcClient()
        : undefined;
      let vpnController: VpnControllerPort | undefined = undefined;
      let oneClickVpnConfirmation: OneClickVpnConfirmationPort | undefined = undefined;
      if (this.shouldCreateVpnController()) {
        vpnController = this.createVpnController(
          vpnRegistry,
          graph,
          this.coreService,
          commandBus,
          vpnRpcClient,
          this.ownedVpnRpcPlatformBundle
        );
        await this.initializeRuntimeMirror(vpnController);
        oneClickVpnConfirmation = this.createOneClickVpnConfirmation(vpnController);
      }
      const application: ProfileApplication = this.createProfileApplication(
        graph,
        this.coreService,
        vpnRegistry,
        commandBus,
        vpnController,
        oneClickVpnConfirmation
      );
      this.application = application;
      await application.initialize();
      const runtimeModeClient = vpnRpcClient === undefined
        ? undefined
        : new VpnRpcRuntimeToolsClient(vpnRpcClient);
      const readyState: ApplicationCompositionState = createReadyState(
        application,
        vpnRegistry,
        runtimeModeClient,
        this.ownedVpnTrafficMonitor,
        createHarmonyRuntimeLogStore(this.context.filesDir),
        createHarmonyRuntimeLogExporter(this.context)
      );
      this.publish(readyState);
    } catch (error) {
      hilog.error(INITIALIZATION_LOG_DOMAIN, INITIALIZATION_LOG_TAG, '%{public}s', 'application.initialize:failed');
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
    this.resetReadyStateAfterClose();
    if (cleanupError !== null) {
      throw cleanupError;
    }
  }

  private async closeResources(): Promise<ApplicationCompositionPersistenceError | null> {
    const application: ProfileApplication | undefined = this.application;
    const ownedVpnController: HarmonyVpnController | undefined = this.ownedVpnController;
    const ownedVpnRpcClient: VpnRpcClientPort | undefined = this.ownedVpnRpcClient;
    const graph: PlatformGraph | undefined = this.graph;
    let cleanupError: ApplicationCompositionPersistenceError | null = null;
    if (application !== undefined) {
      try {
        await application.close();
        this.application = undefined;
      } catch (_) {
        return createCleanupError();
      }
    }
    if (ownedVpnController !== undefined) {
      try {
        await ownedVpnController.dispose();
      } catch (_) {
        cleanupError = cleanupError ?? createCleanupError();
      } finally {
        this.ownedVpnController = undefined;
        this.ownedVpnTrafficMonitor = undefined;
      }
    }
    if (ownedVpnRpcClient !== undefined) {
      try {
        await ownedVpnRpcClient.close();
      } catch (_) {
        cleanupError = cleanupError ?? createCleanupError();
      } finally {
        this.ownedVpnRpcClient = undefined;
        this.ownedVpnRpcPlatformBundle = undefined;
      }
    }
    if (graph !== undefined) {
      try {
        await graph.close();
        this.graph = undefined;
      } catch (_) {
        cleanupError = cleanupError ?? createCleanupError();
      }
    }
    return cleanupError;
  }

  private resetReadyStateAfterClose(): void {
    if (this.application !== undefined || this.currentState.status !== 'READY') {
      return;
    }
    this.publish(createLoadingState());
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
    vpnRegistry: VpnSessionRegistry,
    commandBus: VpnProxyCommandBus,
    vpnController?: VpnControllerPort,
    oneClickVpnConfirmation?: OneClickVpnConfirmationPort
  ): ProfileApplication {
    if (this.dependencies.createProfileApplication !== undefined) {
      return this.dependencies.createProfileApplication(
        graph,
        coreService,
        vpnRegistry,
        commandBus,
        vpnController,
        oneClickVpnConfirmation
      );
    }
    if (vpnController === undefined || oneClickVpnConfirmation === undefined) {
      throw new Error('Profile application creation requires VPN controller wiring.');
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
    const proxyService = new ProxyService(
      new ActiveProfileProxyResolver(graph.repository, graph.contentStore),
      new CoreProxyServiceAdapter(coreService),
      graph.proxySelectionRepository,
      graph.proxyIdentityHasher,
      vpnRegistry,
      commandBus,
      graph.clock
    );
    return new ProfileApplication({
      importUseCase,
      refreshUseCase,
      manageProfileUseCases,
      runtimeCoordinator,
      commitService,
      repository: graph.repository,
      oneClickVpnConfirmation,
      proxyService,
      vpnController,
      idGenerator: graph.idGenerator
    });
  }

  private resolveVpnRegistry(): VpnSessionRegistry {
    return this.dependencies.vpnRegistry ?? resolveSharedVpnRegistry();
  }

  private resolveVpnCommandBus(): VpnProxyCommandBus {
    return this.dependencies.commandBus ?? resolveSharedVpnCommandBus();
  }

  private createVpnController(
    registry: VpnSessionRegistry,
    graph: PlatformGraph,
    coreService: CoreService,
    commandBus: VpnProxyCommandBus,
    vpnRpcClient?: VpnRpcClientPort,
    vpnRpcBundle?: HarmonyVpnRpcPlatformBundle
  ): VpnControllerPort {
    if (this.dependencies.createVpnController !== undefined) {
      return this.dependencies.createVpnController(registry);
    }
    if (this.ownedVpnController !== undefined) {
      return this.ownedVpnController;
    }
    const ownedController = createBoundHarmonyVpnController(
      registry,
      this.context,
      graph,
      coreService,
      commandBus,
      vpnRpcClient,
      vpnRpcBundle,
      this.dependencies
    );
    this.ownedVpnController = ownedController.controller;
    this.ownedVpnTrafficMonitor = ownedController.trafficMonitor;
    return this.ownedVpnController;
  }

  private async initializeRuntimeMirror(controller: VpnControllerPort): Promise<void> {
    await (controller as RuntimeMirrorInitializableController).initializeRuntimeMirror?.();
  }

  private shouldCreateVpnController(): boolean {
    return this.dependencies.createProfileApplication === undefined ||
      this.dependencies.createOneClickVpnConfirmation !== undefined ||
      this.dependencies.createVpnController !== undefined ||
      this.dependencies.createVpnRuntimeMirror !== undefined ||
      this.dependencies.createVpnRpcClient !== undefined ||
      this.dependencies.createVpnRpcHandler !== undefined ||
      this.dependencies.createVpnExtensionAbilityApi !== undefined;
  }

  private resolveVpnRpcClient(): VpnRpcClientPort {
    if (this.ownedVpnRpcClient !== undefined) {
      return this.ownedVpnRpcClient;
    }
    const scheduler = new VpnRpcSchedulerAdapter(new TimeoutDelayScheduler());
    const clock: VpnRpcClockPort = new SystemVpnRpcClock();
    const bundle: HarmonyVpnRpcPlatformBundle = this.ownedVpnRpcPlatformBundle ??
      this.dependencies.createVpnRpcPlatformBundle?.() ??
      new HarmonyVpnRpcPlatformFactory(undefined, this.context.filesDir).create();
    this.ownedVpnRpcPlatformBundle = bundle;
    const client: VpnRpcClientPort = this.dependencies.createVpnRpcClient?.(bundle, scheduler, clock) ??
      new VpnRpcClient(bundle.crypto, bundle.random, scheduler, clock, bundle.clientFactory);
    this.ownedVpnRpcClient = client;
    return client;
  }

  private createOneClickVpnConfirmation(controller: VpnControllerPort): OneClickVpnConfirmationPort {
    if (this.dependencies.createOneClickVpnConfirmation !== undefined) {
      return this.dependencies.createOneClickVpnConfirmation(controller);
    }
    return new SubscriptionOneClickVpnConfirmation(controller, new TimeoutDelayScheduler());
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

function createReadyState(
  application: ProfileApplication,
  vpnRegistry: VpnSessionRegistry,
  runtimeModeClient?: import('@cmfa/shared').VpnRpcRuntimeModeClientPort,
  trafficMonitor?: VpnTrafficMonitorReadPort,
  runtimeLogStore?: import('@cmfa/shared').RuntimeLogStorePort,
  runtimeLogExporter?: import('@cmfa/shared').RuntimeLogExportPort
): ApplicationCompositionState {
  return {
    status: 'READY',
    application,
    vpnRegistry,
    runtimeModeClient,
    trafficMonitor,
    runtimeLogStore,
    runtimeLogExporter
  };
}

function createErrorState(error: AppError): ApplicationCompositionState {
  return {
    status: 'ERROR',
    error
  };
}

function resolveSharedVpnRegistry(): VpnSessionRegistry {
  if (sharedVpnRegistry !== undefined) {
    return sharedVpnRegistry;
  }
  sharedVpnRegistry = new VpnSessionRegistry();
  return sharedVpnRegistry;
}

function resolveSharedVpnCommandBus(): VpnProxyCommandBus {
  if (sharedVpnCommandBus !== undefined) {
    return sharedVpnCommandBus;
  }
  sharedVpnCommandBus = new VpnProxyCommandBus();
  return sharedVpnCommandBus;
}

async function resolveVpnRpcCatalogInputs(
  graph: PlatformGraph,
  request: import('@cmfa/shared').VpnStartRequest
): Promise<VpnRpcCatalogInputs> {
  const profile: Profile | undefined = await graph.repository.get(request.profileId);
  if (profile === undefined || profile.currentRevision === null || profile.currentRevision.validatedAt !== request.versionId) {
    throw new Error('Committed VPN profile was unavailable.');
  }
  const inputs: VpnRpcCatalogInputsValue = new VpnRpcCatalogInputsValue();
  inputs.profileHash = await graph.proxyIdentityHasher.sha256(profile.id);
  inputs.revisionHash = profile.currentRevision.sha256Digest;
  inputs.sessionHash = await graph.proxyIdentityHasher.sha256(request.sessionId);
  inputs.configPath = graph.contentStore.resolveCorePath(profile.currentRevision);
  return inputs;
}

function createBoundHarmonyVpnController(
  registry: VpnSessionRegistry,
  context: common.UIAbilityContext,
  graph: PlatformGraph,
  coreService: CoreService,
  commandBus: VpnProxyCommandBus,
  vpnRpcClient: VpnRpcClientPort | undefined,
  vpnRpcBundle: HarmonyVpnRpcPlatformBundle | undefined,
  dependencies: ApplicationCompositionDependencies
): BoundHarmonyVpnControllerResult {
  const api: UiOwnedVpnExtensionAbilityApiLike = dependencies.createVpnExtensionAbilityApi !== undefined
    ? dependencies.createVpnExtensionAbilityApi(context)
    : new UiOwnedVpnExtensionAbilityApi(
      new SystemVpnExtensionAbilityApi(),
      new PlatformFactory(context).createContinuousNotificationPort()
    );
  const bundle: HarmonyVpnRpcPlatformBundle = vpnRpcBundle ??
    dependencies.createVpnRpcPlatformBundle?.() ??
    new HarmonyVpnRpcPlatformFactory(undefined, context.filesDir).create();
  const client: VpnRpcClientPort = vpnRpcClient ?? (
    dependencies.createVpnRpcClient?.(bundle, new VpnRpcSchedulerAdapter(new TimeoutDelayScheduler()), new SystemVpnRpcClock()) ??
    new VpnRpcClient(bundle.crypto, bundle.random, new VpnRpcSchedulerAdapter(new TimeoutDelayScheduler()), new SystemVpnRpcClock(), bundle.clientFactory)
  );
  const mirror = dependencies.createVpnRuntimeMirror !== undefined
    ? dependencies.createVpnRuntimeMirror(graph, coreService, commandBus)
    : new UiVpnRpcRuntimeMirror(
      graph,
      new CoreProxyServiceAdapter(coreService),
      commandBus,
      bundle,
      client,
      (runtimeClient: VpnRpcClientPort, catalog: VpnOpaqueCatalog): VpnProxyCommandHandler => {
        return dependencies.createVpnRpcHandler?.(runtimeClient, catalog, graph.clock) ??
          new VpnRpcProxyHandler(runtimeClient, catalog, graph.clock);
      }
    );
  const controllerDependencies = new HarmonyVpnControllerDependenciesRecord();
  controllerDependencies.runtimeMirror = mirror;
  controllerDependencies.scheduler = new TimeoutDelayScheduler();
  const trafficMonitor = new VpnTrafficMonitor(
    new VpnRpcTrafficCounterSourceRecord(client),
    new SystemVpnRpcClock(),
    new TimeoutDelayScheduler()
  );
  controllerDependencies.trafficMonitor = trafficMonitor;
  controllerDependencies.trafficReportStage = reportVpnUiStage;
  controllerDependencies.rpcClient = client;
  const controller = new HarmonyVpnController(registry, api, controllerDependencies);
  api.bindStopHandler(() => {
    controller.handleExtensionDestroyed();
  });
  return {
    controller,
    trafficMonitor
  };
}
