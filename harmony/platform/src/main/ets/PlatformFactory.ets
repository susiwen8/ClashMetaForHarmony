import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import common from '@ohos.app.ability.common';
import {
  createAppError,
  type AppError,
  type Clock,
  type IdGenerator,
  type LocalAcquireCommand,
  type Profile,
  type ProfileContentStore,
  type ProfileRepository,
  type ProfileRevision,
  type ProfileSourceGateway,
  type SubscriptionSecretStore,
  type ContinuousNotificationPort,
  type NetworkRecoveryPort
} from '@cmfa/shared';
import type { ProxyIdentityHasher, ProxySelectionRepository } from '@cmfa/shared';
import {
  HarmonyVpnNotificationDriver,
  UiAbilityOwnedContinuousNotificationPort
} from './background/HarmonyVpnNotificationDriver';
import type { PlatformContinuousTaskContext } from './background/ContinuousTaskDriver';
import type { FileDriver } from './files/FileDriver';
import { HarmonyFileDriver } from './files/HarmonyFileDriver';
import {
  HarmonyGeodataInstaller,
  HilogGeodataDiagnosticSink,
  type GeodataInstaller,
  type HarmonyGeodataInstallerDependencies,
  type PackagedRawfileReader
} from './geodata/HarmonyGeodataInstaller';
import { SandboxProfileContentStore } from './files/SandboxProfileContentStore';
import { HarmonyNetworkMonitor } from './network/HarmonyNetworkMonitor';
import { HarmonyNetworkConnectionDriver } from './network/HarmonyNetworkConnectionDriver';
import { HarmonyRdbDriver } from './rdb/HarmonyRdbDriver';
import { RdbProfileRepository } from './rdb/RdbProfileRepository';
import { RdbProxySelectionRepository } from './rdb/RdbProxySelectionRepository';
import type { RdbDriver } from './rdb/RdbDriver';
import { HarmonyProxyIdentityHasher } from './proxy/HarmonyProxyIdentityHasher';
import { HarmonyHuksDriver } from './secrets/HarmonyHuksDriver';
import type { HuksDriver } from './secrets/HuksDriver';
import { HuksSubscriptionSecretStore } from './secrets/HuksSubscriptionSecretStore';
import { HarmonyFilePicker } from './source/HarmonyFilePicker';
import { NetworkKitHttpTransport } from './source/NetworkKitHttpTransport';
import { RequestAgentRedirectTransport } from './source/RequestAgentRedirectTransport';
import { SubscriptionDownloader } from './source/SubscriptionDownloader';
import { HarmonyProfileSourceGateway, type HarmonyProfileSourceGatewayDependencies, type LocalProfileAcquirer, type RemoteProfileAcquirer } from './source/HarmonyProfileSourceGateway';
import type { HttpTransport } from './source/HttpTransport';

const DEFAULT_DATABASE_NAME: string = 'cmfa_profiles.db';
const GEOIP_METADB_SIZE_BYTES: number = 8593535;
const GEOIP_METADB_SHA256: string = '71def3ab45393093baf9d39b69787b3e0d0685607c13dd135bfdbb603bd475dd';
const GEOIP_METADB_RAWFILE_NAME: string = 'geoip.metadb';
const INITIALIZATION_LOG_DOMAIN: number = 0x0000;
const INITIALIZATION_LOG_TAG: string = 'CMFAInit';

export interface PlatformPaths {
  filesDir: string;
  databaseName: string;
}

export interface CloseableRdbDriver extends RdbDriver {
  close(): Promise<void>;
}

export interface PrepareableHuksDriver extends HuksDriver {
  prepare(): Promise<void>;
}

export interface PlatformSecretStore extends SubscriptionSecretStore {
  reconcile(referencedSecretIds: string[]): Promise<void>;
}

export interface PlatformPickerDependencies {
  context: common.UIAbilityContext;
  fileDriver: FileDriver;
  paths: PlatformPaths;
  clock: Clock;
  idGenerator: IdGenerator;
}

export interface PlatformRequestAgentTransportDependencies {
  context: common.Context;
  fileDriver: FileDriver;
  paths: PlatformPaths;
  idGenerator: IdGenerator;
}

export interface PlatformDownloaderDependencies {
  context: common.Context;
  sdkApiVersion: number;
  fileDriver: FileDriver;
  paths: PlatformPaths;
  clock: Clock;
  idGenerator: IdGenerator;
  networkKitTransport: HttpTransport;
  requestAgentTransport: HttpTransport;
}

export interface PlatformFactoryDependencies {
  resolvePaths?: (context: common.Context) => PlatformPaths;
  resolveSdkApiVersion?: (context: common.Context) => number;
  createClock?: () => Clock;
  createIdGenerator?: () => IdGenerator;
  createFileDriver?: () => FileDriver;
  createGeodataResourceReader?: (context: common.Context) => PackagedRawfileReader;
  createGeodataInstaller?: (dependencies: HarmonyGeodataInstallerDependencies) => GeodataInstaller;
  createRdbDriver?: (context: common.Context, paths: PlatformPaths) => CloseableRdbDriver;
  createHuksDriver?: () => PrepareableHuksDriver;
  createRepository?: (driver: CloseableRdbDriver) => ProfileRepository;
  createProxySelectionRepository?: (driver: CloseableRdbDriver) => ProxySelectionRepository;
  createProxyIdentityHasher?: () => ProxyIdentityHasher;
  createContentStore?: (fileDriver: FileDriver, paths: PlatformPaths) => ProfileContentStore;
  createSecretStore?: (
    huksDriver: PrepareableHuksDriver,
    fileDriver: FileDriver,
    paths: PlatformPaths,
    idGenerator: IdGenerator
  ) => PlatformSecretStore;
  createPicker?: (dependencies: PlatformPickerDependencies) => LocalProfileAcquirer;
  createNetworkKitTransport?: () => HttpTransport;
  createRequestAgentTransport?: (dependencies: PlatformRequestAgentTransportDependencies) => HttpTransport;
  createDownloader?: (dependencies: PlatformDownloaderDependencies) => RemoteProfileAcquirer;
  createSourceGateway?: (dependencies: HarmonyProfileSourceGatewayDependencies) => ProfileSourceGateway;
  createNetworkRecoveryPort?: () => Promise<NetworkRecoveryPort>;
  createContinuousNotificationPort?: (
    context: PlatformContinuousTaskContext,
    sdkApiVersion: number
  ) => ContinuousNotificationPort;
}

export interface PlatformGraph {
  readonly repository: ProfileRepository;
  readonly proxySelectionRepository: ProxySelectionRepository;
  readonly proxyIdentityHasher: ProxyIdentityHasher;
  readonly contentStore: ProfileContentStore;
  readonly sourceGateway: ProfileSourceGateway;
  readonly secretStore: SubscriptionSecretStore;
  readonly clock: Clock;
  readonly idGenerator: IdGenerator;
  close(): Promise<void>;
}

class UnsupportedLocalProfileAcquirer implements LocalProfileAcquirer {
  async acquire(_command: LocalAcquireCommand): Promise<never> {
    throw new Error('Local profile acquisition requires UIAbilityContext.');
  }
}

interface RawfileResourceManager {
  getRawFileContentSync(fileName: string): Uint8Array;
}

interface RawfileCapableContext {
  resourceManager?: RawfileResourceManager;
}

class ContextPackagedRawfileReader implements PackagedRawfileReader {
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  async readRawfile(name: string): Promise<Uint8Array> {
    const manager: RawfileResourceManager | undefined = (this.context as RawfileCapableContext).resourceManager;
    if (manager === undefined || typeof manager.getRawFileContentSync !== 'function') {
      throw new Error('Packaged rawfile access was unavailable.');
    }
    return manager.getRawFileContentSync(name);
  }
}

class SystemClock implements Clock {
  now(): string {
    return new Date().toISOString();
  }
}

class SystemIdGenerator implements IdGenerator {
  nextId(): string {
    return util.generateRandomUUID();
  }
}

class PlatformInitializationError extends Error implements AppError {
  readonly code: string;
  readonly stage: 'PERSISTENCE' = 'PERSISTENCE';
  readonly userMessageResource: string;
  readonly technicalDetail: string;
  readonly timestamp: string;
  readonly retryable: boolean;

  constructor() {
    const appError: AppError = createAppError('PERSISTENCE', 'Platform initialization failed.', {
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

const GRAPH_CLOSE_ACTIONS: WeakMap<PlatformGraphRecord, () => Promise<void>> = new WeakMap();
const GRAPH_CLOSE_PROMISES: WeakMap<PlatformGraphRecord, Promise<void>> = new WeakMap();
const GRAPH_CLOSED_FLAGS: WeakMap<PlatformGraphRecord, boolean> = new WeakMap();

class PlatformGraphRecord implements PlatformGraph {
  readonly repository: ProfileRepository;
  readonly proxySelectionRepository: ProxySelectionRepository;
  readonly proxyIdentityHasher: ProxyIdentityHasher;
  readonly contentStore: ProfileContentStore;
  readonly sourceGateway: ProfileSourceGateway;
  readonly secretStore: SubscriptionSecretStore;
  readonly clock: Clock;
  readonly idGenerator: IdGenerator;

  constructor(
    repository: ProfileRepository,
    proxySelectionRepository: ProxySelectionRepository,
    proxyIdentityHasher: ProxyIdentityHasher,
    contentStore: ProfileContentStore,
    sourceGateway: ProfileSourceGateway,
    secretStore: SubscriptionSecretStore,
    clock: Clock,
    idGenerator: IdGenerator,
    closeRdb: () => Promise<void>
  ) {
    this.repository = repository;
    this.proxySelectionRepository = proxySelectionRepository;
    this.proxyIdentityHasher = proxyIdentityHasher;
    this.contentStore = contentStore;
    this.sourceGateway = sourceGateway;
    this.secretStore = secretStore;
    this.clock = clock;
    this.idGenerator = idGenerator;
    GRAPH_CLOSE_ACTIONS.set(this, closeRdb);
    GRAPH_CLOSED_FLAGS.set(this, false);
  }

  async close(): Promise<void> {
    const existing: Promise<void> | undefined = GRAPH_CLOSE_PROMISES.get(this);
    if (existing !== undefined) {
      await existing;
      return;
    }
    if (GRAPH_CLOSED_FLAGS.get(this) === true) {
      return;
    }
    const closeAction: (() => Promise<void>) | undefined = GRAPH_CLOSE_ACTIONS.get(this);
    if (closeAction === undefined) {
      return;
    }
    const nextClose: Promise<void> = closeAction().finally(() => {
      GRAPH_CLOSED_FLAGS.set(this, true);
    });
    GRAPH_CLOSE_PROMISES.set(this, nextClose);
    await nextClose;
  }
}

export class PlatformFactory {
  private readonly context: common.Context;
  private readonly dependencies: PlatformFactoryDependencies;
  private inFlight?: Promise<PlatformGraph>;
  private readyGraph?: PlatformGraph;

  constructor(context: common.Context, dependencies?: PlatformFactoryDependencies) {
    this.context = context;
    this.dependencies = dependencies ?? {};
  }

  async create(): Promise<PlatformGraph> {
    if (this.readyGraph !== undefined) {
      return this.readyGraph;
    }
    if (this.inFlight !== undefined) {
      return await this.inFlight;
    }
    const inFlight: Promise<PlatformGraph> = this.buildGraph();
    this.inFlight = inFlight;
    try {
      const graph: PlatformGraph = await inFlight;
      this.readyGraph = graph;
      return graph;
    } catch (_error) {
      throw sanitizeInitializationError();
    } finally {
      if (this.readyGraph === undefined && this.inFlight === inFlight) {
        this.inFlight = undefined;
      }
    }
  }

  async createNetworkRecoveryPort(): Promise<NetworkRecoveryPort> {
    if (this.dependencies.createNetworkRecoveryPort !== undefined) {
      return await this.dependencies.createNetworkRecoveryPort();
    }
    const monitor = new HarmonyNetworkMonitor(new HarmonyNetworkConnectionDriver());
    await monitor.initialize();
    return monitor;
  }

  createContinuousNotificationPort(): ContinuousNotificationPort {
    const sdkApiVersion: number = resolveSdkApiVersion(this.context, this.dependencies.resolveSdkApiVersion);
    if (this.dependencies.createContinuousNotificationPort !== undefined) {
      return this.dependencies.createContinuousNotificationPort(
        toPlatformContinuousTaskContext(this.context),
        sdkApiVersion
      );
    }
    if (!hasUiAbilityInfo(this.context)) {
      return new UiAbilityOwnedContinuousNotificationPort();
    }
    return new HarmonyVpnNotificationDriver(
      toPlatformContinuousTaskContext(this.context),
      undefined,
      this.context
    );
  }

  private async buildGraph(): Promise<PlatformGraph> {
    const paths: PlatformPaths = this.resolvePaths(this.context);
    const clock: Clock = this.dependencies.createClock?.() ?? new SystemClock();
    const idGenerator: IdGenerator = this.dependencies.createIdGenerator?.() ?? new SystemIdGenerator();
    const fileDriver: FileDriver = this.dependencies.createFileDriver?.() ?? new HarmonyFileDriver();
    let rdbDriver: CloseableRdbDriver | undefined = undefined;
    let graph: PlatformGraph | undefined = undefined;
    let initializationStage: string = 'construct-drivers';

    try {
      initializationStage = 'geodata.install';
      const geodataDependencies: HarmonyGeodataInstallerDependencies = {
        resourceReader: this.dependencies.createGeodataResourceReader?.(this.context) ??
          new ContextPackagedRawfileReader(this.context),
        fileDriver,
        filesDir: paths.filesDir,
        expectedByteLength: GEOIP_METADB_SIZE_BYTES,
        expectedSha256Digest: GEOIP_METADB_SHA256,
        createTempId: (): string => idGenerator.nextId(),
        diagnostics: new HilogGeodataDiagnosticSink()
      };
      const geodataInstaller: GeodataInstaller = this.dependencies.createGeodataInstaller?.(geodataDependencies) ??
        new HarmonyGeodataInstaller(geodataDependencies);
      await geodataInstaller.ensureInstalled();
      hilog.info(INITIALIZATION_LOG_DOMAIN, INITIALIZATION_LOG_TAG, '%{public}s', 'geodata.install.ok');

      rdbDriver = this.dependencies.createRdbDriver?.(this.context, paths) ??
        new HarmonyRdbDriver(this.context, paths.databaseName);
      const huksDriver: PrepareableHuksDriver = this.dependencies.createHuksDriver?.() ?? new HarmonyHuksDriver();
      const sdkApiVersion: number = resolveSdkApiVersion(this.context, this.dependencies.resolveSdkApiVersion);
      const repository: ProfileRepository = this.dependencies.createRepository?.(rdbDriver) ??
        new RdbProfileRepository(rdbDriver);
      const proxySelectionRepository: ProxySelectionRepository =
        this.dependencies.createProxySelectionRepository?.(rdbDriver) ?? new RdbProxySelectionRepository(rdbDriver);
      const proxyIdentityHasher: ProxyIdentityHasher =
        this.dependencies.createProxyIdentityHasher?.() ?? new HarmonyProxyIdentityHasher();
      const contentStore: ProfileContentStore = this.dependencies.createContentStore?.(fileDriver, paths) ??
        new SandboxProfileContentStore(fileDriver, paths.filesDir);
      const secretStore: PlatformSecretStore = this.dependencies.createSecretStore?.(
        huksDriver,
        fileDriver,
        paths,
        idGenerator
      ) ?? new HuksSubscriptionSecretStore(huksDriver, fileDriver, paths.filesDir, idGenerator);
      const picker: LocalProfileAcquirer = this.dependencies.createPicker?.({
        context: this.context as common.UIAbilityContext,
        fileDriver,
        paths,
        clock,
        idGenerator
      }) ?? this.createDefaultPicker(fileDriver, paths, clock, idGenerator);
      const networkKitTransport: HttpTransport = this.dependencies.createNetworkKitTransport?.() ??
        new NetworkKitHttpTransport();
      const requestAgentTransport: HttpTransport = this.dependencies.createRequestAgentTransport?.({
        context: this.context,
        fileDriver,
        paths,
        idGenerator
      }) ?? new RequestAgentRedirectTransport({
        context: this.context,
        fileDriver,
        filesDir: paths.filesDir,
        idGenerator
      });
      const downloader: RemoteProfileAcquirer = this.dependencies.createDownloader?.({
        context: this.context,
        sdkApiVersion: sdkApiVersion,
        fileDriver,
        paths,
        clock,
        idGenerator,
        networkKitTransport,
        requestAgentTransport
      }) ?? new SubscriptionDownloader({
        sdkApiVersion: sdkApiVersion,
        networkKitTransport,
        requestAgentTransport,
        fileDriver,
        filesDir: paths.filesDir,
        clock,
        idGenerator
      });
      const sourceGateway: ProfileSourceGateway = this.dependencies.createSourceGateway?.({
        localAcquirer: picker,
        remoteAcquirer: downloader
      }) ?? new HarmonyProfileSourceGateway({
        localAcquirer: picker,
        remoteAcquirer: downloader
      });

      initializationStage = 'huks.prepare';
      await huksDriver.prepare();
      hilog.info(INITIALIZATION_LOG_DOMAIN, INITIALIZATION_LOG_TAG, '%{public}s', 'huks.prepare.ok');
      initializationStage = 'repository.list';
      const profiles: Profile[] = await repository.list();
      hilog.info(INITIALIZATION_LOG_DOMAIN, INITIALIZATION_LOG_TAG, '%{public}s', 'repository.list.ok');
      initializationStage = 'content.reconcile';
      await contentStore.reconcile(collectReferencedRevisions(profiles));
      hilog.info(INITIALIZATION_LOG_DOMAIN, INITIALIZATION_LOG_TAG, '%{public}s', 'content.reconcile.ok');
      initializationStage = 'secret.reconcile';
      await secretStore.reconcile(collectReferencedSecretIds(profiles));
      hilog.info(INITIALIZATION_LOG_DOMAIN, INITIALIZATION_LOG_TAG, '%{public}s', 'secret.reconcile.ok');

      const readyRdbDriver: CloseableRdbDriver = rdbDriver;
      graph = new PlatformGraphRecord(
        repository,
        proxySelectionRepository,
        proxyIdentityHasher,
        contentStore,
        sourceGateway,
        secretStore,
        clock,
        idGenerator,
        async (): Promise<void> => {
          await readyRdbDriver.close();
        }
      );
      const readyGraph: PlatformGraph = graph;
      return readyGraph;
    } catch (error) {
      hilog.error(INITIALIZATION_LOG_DOMAIN, INITIALIZATION_LOG_TAG, '%{public}s', initializationStage);
      if (graph !== undefined) {
        await safeCloseGraph(graph);
      } else if (rdbDriver !== undefined) {
        await safeCloseRdbDriver(rdbDriver);
      }
      throw error as Error;
    }
  }

  private resolvePaths(context: common.Context): PlatformPaths {
    if (this.dependencies.resolvePaths !== undefined) {
      return this.dependencies.resolvePaths(context);
    }
    return {
      filesDir: context.filesDir,
      databaseName: DEFAULT_DATABASE_NAME
    };
  }

  private createDefaultPicker(
    fileDriver: FileDriver,
    paths: PlatformPaths,
    clock: Clock,
    idGenerator: IdGenerator
  ): LocalProfileAcquirer {
    if (!hasUiAbilityInfo(this.context)) {
      return new UnsupportedLocalProfileAcquirer();
    }
    return new HarmonyFilePicker({
      context: this.context as common.UIAbilityContext,
      fileDriver,
      filesDir: paths.filesDir,
      clock,
      idGenerator
    });
  }
}

function collectReferencedRevisions(profiles: Profile[]): ProfileRevision[] {
  const referenced: ProfileRevision[] = [];
  const seen = new Set<string>();
  for (let index: number = 0; index < profiles.length; index += 1) {
    collectRevision(profiles[index].currentRevision, seen, referenced);
    collectRevision(profiles[index].failedCandidate, seen, referenced);
  }
  return referenced;
}

function collectRevision(
  revision: ProfileRevision | null,
  seen: Set<string>,
  referenced: ProfileRevision[]
): void {
  if (revision === null || seen.has(revision.relativePath)) {
    return;
  }
  seen.add(revision.relativePath);
  referenced.push(revision);
}

function collectReferencedSecretIds(profiles: Profile[]): string[] {
  const referenced: string[] = [];
  const seen = new Set<string>();
  for (let index: number = 0; index < profiles.length; index += 1) {
    const secretId: string | undefined = profiles[index].sourceSecretRef;
    if (secretId === undefined || seen.has(secretId)) {
      continue;
    }
    seen.add(secretId);
    referenced.push(secretId);
  }
  return referenced;
}

function resolveSdkApiVersion(
  context: common.Context,
  override?: (context: common.Context) => number
): number {
  if (override !== undefined) {
    return override(context);
  }
  const runtimeSdkApiVersion: number = deviceInfo.sdkApiVersion;
  if (!Number.isInteger(runtimeSdkApiVersion) || runtimeSdkApiVersion <= 0) {
    throw new Error('Runtime sdk api version was unavailable.');
  }
  return runtimeSdkApiVersion;
}

function hasUiAbilityInfo(context: common.Context): boolean {
  const uiContext: common.UIAbilityContext = context as common.UIAbilityContext;
  return uiContext.abilityInfo !== undefined;
}

function toPlatformContinuousTaskContext(context: common.Context): PlatformContinuousTaskContext {
  const uiContext: common.UIAbilityContext = context as common.UIAbilityContext;
  if (uiContext.abilityInfo !== undefined) {
    return {
      abilityInfo: {
        bundleName: uiContext.abilityInfo.bundleName,
        moduleName: uiContext.currentHapModuleInfo.name,
        name: uiContext.abilityInfo.name
      }
    };
  }
  const extensionContext: common.VpnExtensionContext = context as common.VpnExtensionContext;
  return {
    abilityInfo: {
      bundleName: extensionContext.extensionAbilityInfo.bundleName,
      moduleName: extensionContext.currentHapModuleInfo.name,
      name: extensionContext.extensionAbilityInfo.name
    }
  };
}

function sanitizeInitializationError(): PlatformInitializationError {
  return new PlatformInitializationError();
}

async function safeCloseGraph(graph: PlatformGraph): Promise<void> {
  try {
    await graph.close();
  } catch (_) {
  }
}

async function safeCloseRdbDriver(driver: CloseableRdbDriver): Promise<void> {
  try {
    await driver.close();
  } catch (_) {
  }
}
