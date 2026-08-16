import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import common from '@ohos.app.ability.common';
import {
  createAppError,
  type AppError,
  type Clock,
  type IdGenerator,
  type Profile,
  type ProfileContentStore,
  type ProfileRepository,
  type ProfileRevision,
  type ProfileSourceGateway,
  type SubscriptionSecretStore,
  type ContinuousNotificationPort,
  type NetworkRecoveryPort
} from '@cmfa/shared';
import { HarmonyVpnNotificationDriver } from './background/HarmonyVpnNotificationDriver';
import type { PlatformContinuousTaskContext } from './background/ContinuousTaskDriver';
import type { FileDriver } from './files/FileDriver';
import { HarmonyFileDriver } from './files/HarmonyFileDriver';
import { SandboxProfileContentStore } from './files/SandboxProfileContentStore';
import { HarmonyNetworkMonitor } from './network/HarmonyNetworkMonitor';
import { HarmonyRdbDriver } from './rdb/HarmonyRdbDriver';
import { RdbProfileRepository } from './rdb/RdbProfileRepository';
import type { RdbDriver } from './rdb/RdbDriver';
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
  context: common.UIAbilityContext;
  fileDriver: FileDriver;
  paths: PlatformPaths;
  idGenerator: IdGenerator;
}

export interface PlatformDownloaderDependencies {
  context: common.UIAbilityContext;
  sdkApiVersion: number;
  fileDriver: FileDriver;
  paths: PlatformPaths;
  clock: Clock;
  idGenerator: IdGenerator;
  networkKitTransport: HttpTransport;
  requestAgentTransport: HttpTransport;
}

export interface PlatformFactoryDependencies {
  resolvePaths?: (context: common.UIAbilityContext) => PlatformPaths;
  resolveSdkApiVersion?: (context: common.UIAbilityContext) => number;
  createClock?: () => Clock;
  createIdGenerator?: () => IdGenerator;
  createFileDriver?: () => FileDriver;
  createRdbDriver?: (context: common.UIAbilityContext, paths: PlatformPaths) => CloseableRdbDriver;
  createHuksDriver?: () => PrepareableHuksDriver;
  createRepository?: (driver: CloseableRdbDriver) => ProfileRepository;
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
  repository: ProfileRepository;
  contentStore: ProfileContentStore;
  sourceGateway: ProfileSourceGateway;
  secretStore: SubscriptionSecretStore;
  clock: Clock;
  idGenerator: IdGenerator;
  close(): Promise<void>;
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
  readonly contentStore: ProfileContentStore;
  readonly sourceGateway: ProfileSourceGateway;
  readonly secretStore: SubscriptionSecretStore;
  readonly clock: Clock;
  readonly idGenerator: IdGenerator;

  constructor(
    repository: ProfileRepository,
    contentStore: ProfileContentStore,
    sourceGateway: ProfileSourceGateway,
    secretStore: SubscriptionSecretStore,
    clock: Clock,
    idGenerator: IdGenerator,
    closeRdb: () => Promise<void>
  ) {
    this.repository = repository;
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
  private readonly context: common.UIAbilityContext;
  private readonly dependencies: PlatformFactoryDependencies;
  private inFlight?: Promise<PlatformGraph>;
  private readyGraph?: PlatformGraph;

  constructor(context: common.UIAbilityContext, dependencies?: PlatformFactoryDependencies) {
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
    const monitor = new HarmonyNetworkMonitor();
    await monitor.initialize();
    return monitor;
  }

  createContinuousNotificationPort(): ContinuousNotificationPort {
    const sdkApiVersion: number = resolveSdkApiVersion(this.context, this.dependencies.resolveSdkApiVersion);
    if (this.dependencies.createContinuousNotificationPort !== undefined) {
      return this.dependencies.createContinuousNotificationPort(
        this.context as PlatformContinuousTaskContext,
        sdkApiVersion
      );
    }
    return new HarmonyVpnNotificationDriver(
      this.context as PlatformContinuousTaskContext
    );
  }

  private async buildGraph(): Promise<PlatformGraph> {
    const paths: PlatformPaths = this.resolvePaths(this.context);
    const clock: Clock = this.dependencies.createClock?.() ?? new SystemClock();
    const idGenerator: IdGenerator = this.dependencies.createIdGenerator?.() ?? new SystemIdGenerator();
    const fileDriver: FileDriver = this.dependencies.createFileDriver?.() ?? new HarmonyFileDriver();
    let rdbDriver: CloseableRdbDriver | undefined = undefined;
    let graph: PlatformGraph | undefined = undefined;

    try {
      rdbDriver = this.dependencies.createRdbDriver?.(this.context, paths) ??
        new HarmonyRdbDriver(this.context, paths.databaseName);
      const huksDriver: PrepareableHuksDriver = this.dependencies.createHuksDriver?.() ?? new HarmonyHuksDriver();
      const sdkApiVersion: number = resolveSdkApiVersion(this.context, this.dependencies.resolveSdkApiVersion);
      const repository: ProfileRepository = this.dependencies.createRepository?.(rdbDriver) ??
        new RdbProfileRepository(rdbDriver);
      const contentStore: ProfileContentStore = this.dependencies.createContentStore?.(fileDriver, paths) ??
        new SandboxProfileContentStore(fileDriver, paths.filesDir);
      const secretStore: PlatformSecretStore = this.dependencies.createSecretStore?.(
        huksDriver,
        fileDriver,
        paths,
        idGenerator
      ) ?? new HuksSubscriptionSecretStore(huksDriver, fileDriver, paths.filesDir, idGenerator);
      const picker: LocalProfileAcquirer = this.dependencies.createPicker?.({
        context: this.context,
        fileDriver,
        paths,
        clock,
        idGenerator
      }) ?? new HarmonyFilePicker({
        context: this.context,
        fileDriver,
        filesDir: paths.filesDir,
        clock,
        idGenerator
      });
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

      const profiles: Profile[] = await repository.list();
      await contentStore.reconcile(collectReferencedRevisions(profiles));
      await secretStore.reconcile(collectReferencedSecretIds(profiles));
      await huksDriver.prepare();

      const readyRdbDriver: CloseableRdbDriver = rdbDriver;
      graph = new PlatformGraphRecord(
        repository,
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
      if (graph !== undefined) {
        await safeCloseGraph(graph);
      } else if (rdbDriver !== undefined) {
        await safeCloseRdbDriver(rdbDriver);
      }
      throw error as Error;
    }
  }

  private resolvePaths(context: common.UIAbilityContext): PlatformPaths {
    if (this.dependencies.resolvePaths !== undefined) {
      return this.dependencies.resolvePaths(context);
    }
    return {
      filesDir: context.filesDir,
      databaseName: DEFAULT_DATABASE_NAME
    };
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
  context: common.UIAbilityContext,
  override?: (context: common.UIAbilityContext) => number
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
