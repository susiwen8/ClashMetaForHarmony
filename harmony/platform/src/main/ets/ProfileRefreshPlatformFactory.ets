import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import type common from '@ohos.app.ability.common';
import {
  createAppError,
  type Clock,
  type IdGenerator,
  type LocalAcquireCommand,
  type LocalProfileAcquisition,
  type Profile,
  type ProfileContentStore,
  type ProfileRefreshLeasePort,
  type ProfileRepository,
  type ProfileRevision,
  type ProfileSourceGateway,
  type SubscriptionSecretStore
} from '@cmfa/shared';
import { HarmonyFileDriver } from './files/HarmonyFileDriver';
import { SandboxProfileContentStore } from './files/SandboxProfileContentStore';
import { HarmonyRdbDriver } from './rdb/HarmonyRdbDriver';
import { RdbProfileRefreshLeaseStore } from './rdb/RdbProfileRefreshLeaseStore';
import { RdbProfileRepository } from './rdb/RdbProfileRepository';
import { HarmonyHuksDriver } from './secrets/HarmonyHuksDriver';
import { HuksSubscriptionSecretStore } from './secrets/HuksSubscriptionSecretStore';
import { HarmonyProfileSourceGateway, type LocalProfileAcquirer, type RemoteProfileAcquirer } from './source/HarmonyProfileSourceGateway';
import { NetworkKitHttpTransport } from './source/NetworkKitHttpTransport';
import { RequestAgentRedirectTransport } from './source/RequestAgentRedirectTransport';
import { SubscriptionDownloader } from './source/SubscriptionDownloader';

const DEFAULT_DATABASE_NAME: string = 'cmfa_profiles.db';
const INITIALIZATION_ERROR_MESSAGE: string = 'Profile refresh platform initialization failed.';

export interface ProfileRefreshSecretStore extends SubscriptionSecretStore {
  reconcile(referencedSecretIds: string[]): Promise<void>;
}

export interface ProfileRefreshPlatformComponents {
  repository: ProfileRepository;
  profileRefreshLeasePort: ProfileRefreshLeasePort;
  contentStore: ProfileContentStore;
  sourceGateway: ProfileSourceGateway;
  secretStore: ProfileRefreshSecretStore;
  clock: Clock;
  idGenerator: IdGenerator;
  prepareSecrets(): Promise<void>;
  closeRdb(): Promise<void>;
}

export interface ProfileRefreshPlatformGraph {
  readonly repository: ProfileRepository;
  readonly profileRefreshLeasePort: ProfileRefreshLeasePort;
  readonly contentStore: ProfileContentStore;
  readonly sourceGateway: ProfileSourceGateway;
  readonly secretStore: SubscriptionSecretStore;
  readonly clock: Clock;
  readonly idGenerator: IdGenerator;
  close(): Promise<void>;
}

export interface ProfileRefreshPlatformFactoryDependencies {
  createComponents?: () => ProfileRefreshPlatformComponents;
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

class UnsupportedLocalProfileAcquirer implements LocalProfileAcquirer {
  async acquire(command: LocalAcquireCommand): Promise<LocalProfileAcquisition> {
    return {
      kind: 'FAILED',
      error: createAppError('IMPORT', 'Local profile acquisition is unsupported in this profile refresh platform.', {
        code: 'CMFA_IMPORT_UNSUPPORTED_LOCAL_PROFILE',
        retryable: false
      }),
      shouldPersistInvalidProfile: false,
      profileName: command.preferredName,
      sourceDisplay: undefined
    };
  }
}

const GRAPH_CLOSE_ACTIONS: WeakMap<ProfileRefreshPlatformGraphRecord, () => Promise<void>> = new WeakMap();
const GRAPH_CLOSE_PROMISES: WeakMap<ProfileRefreshPlatformGraphRecord, Promise<void>> = new WeakMap();
const GRAPH_CLOSED_FLAGS: WeakMap<ProfileRefreshPlatformGraphRecord, boolean> = new WeakMap();

class ProfileRefreshPlatformGraphRecord implements ProfileRefreshPlatformGraph {
  readonly repository: ProfileRepository;
  readonly profileRefreshLeasePort: ProfileRefreshLeasePort;
  readonly contentStore: ProfileContentStore;
  readonly sourceGateway: ProfileSourceGateway;
  readonly secretStore: SubscriptionSecretStore;
  readonly clock: Clock;
  readonly idGenerator: IdGenerator;

  constructor(components: ProfileRefreshPlatformComponents) {
    this.repository = components.repository;
    this.profileRefreshLeasePort = components.profileRefreshLeasePort;
    this.contentStore = components.contentStore;
    this.sourceGateway = components.sourceGateway;
    this.secretStore = components.secretStore;
    this.clock = components.clock;
    this.idGenerator = components.idGenerator;
    GRAPH_CLOSE_ACTIONS.set(this, components.closeRdb);
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
    const closePromise: Promise<void> = closeAction().finally(() => {
      GRAPH_CLOSED_FLAGS.set(this, true);
    });
    GRAPH_CLOSE_PROMISES.set(this, closePromise);
    await closePromise;
  }
}

export class ProfileRefreshPlatformFactory {
  private readonly context: common.Context;
  private readonly dependencies: ProfileRefreshPlatformFactoryDependencies;
  private inFlight?: Promise<ProfileRefreshPlatformGraph>;
  private readyGraph?: ProfileRefreshPlatformGraph;

  constructor(context: common.Context, dependencies?: ProfileRefreshPlatformFactoryDependencies) {
    this.context = context;
    this.dependencies = dependencies ?? {};
  }

  async create(): Promise<ProfileRefreshPlatformGraph> {
    if (this.readyGraph !== undefined) {
      return this.readyGraph;
    }
    if (this.inFlight !== undefined) {
      return await this.inFlight;
    }
    const nextGraph: Promise<ProfileRefreshPlatformGraph> = this.buildGraph();
    this.inFlight = nextGraph;
    try {
      const graph: ProfileRefreshPlatformGraph = await nextGraph;
      this.readyGraph = graph;
      return graph;
    } catch (_) {
      throw sanitizeInitializationError();
    } finally {
      if (this.readyGraph === undefined && this.inFlight === nextGraph) {
        this.inFlight = undefined;
      }
    }
  }

  private async buildGraph(): Promise<ProfileRefreshPlatformGraph> {
    const components: ProfileRefreshPlatformComponents =
      this.dependencies.createComponents?.() ?? this.createDefaultComponents();
    let graph: ProfileRefreshPlatformGraph | undefined = undefined;

    try {
      await components.prepareSecrets();
      const profiles: Profile[] = await components.repository.list();
      await components.contentStore.reconcile(collectReferencedRevisions(profiles));
      await components.secretStore.reconcile(collectReferencedSecretIds(profiles));
      graph = new ProfileRefreshPlatformGraphRecord(components);
      return graph;
    } catch (error) {
      if (graph !== undefined) {
        await safeCloseGraph(graph);
      } else {
        await safeCloseRdb(components);
      }
      throw error as Error;
    }
  }

  private createDefaultComponents(): ProfileRefreshPlatformComponents {
    const filesDir: string = this.context.filesDir;
    const clock: Clock = new SystemClock();
    const idGenerator: IdGenerator = new SystemIdGenerator();
    const fileDriver = new HarmonyFileDriver();
    const rdbDriver = new HarmonyRdbDriver(this.context, DEFAULT_DATABASE_NAME);
    const repository: ProfileRepository = new RdbProfileRepository(rdbDriver);
    const profileRefreshLeasePort: ProfileRefreshLeasePort = new RdbProfileRefreshLeaseStore(rdbDriver);
    const contentStore: ProfileContentStore = new SandboxProfileContentStore(fileDriver, filesDir);
    const huksDriver = new HarmonyHuksDriver();
    const secretStore: ProfileRefreshSecretStore =
      new HuksSubscriptionSecretStore(huksDriver, fileDriver, filesDir, idGenerator);
    const networkKitTransport = new NetworkKitHttpTransport();
    const requestAgentTransport = new RequestAgentRedirectTransport({
      context: this.context,
      fileDriver,
      filesDir,
      idGenerator
    });
    const remoteAcquirer: RemoteProfileAcquirer = new SubscriptionDownloader({
      sdkApiVersion: resolveSdkApiVersionSafe(),
      networkKitTransport,
      requestAgentTransport,
      fileDriver,
      filesDir,
      clock,
      idGenerator
    });
    const sourceGateway: ProfileSourceGateway = new HarmonyProfileSourceGateway({
      localAcquirer: new UnsupportedLocalProfileAcquirer(),
      remoteAcquirer
    });

    return {
      repository,
      profileRefreshLeasePort,
      contentStore,
      sourceGateway,
      secretStore,
      clock,
      idGenerator,
      prepareSecrets: async (): Promise<void> => {
        await huksDriver.prepare();
      },
      closeRdb: async (): Promise<void> => {
        await rdbDriver.close();
      }
    };
  }
}

function collectReferencedRevisions(profiles: Profile[]): ProfileRevision[] {
  const referenced: ProfileRevision[] = [];
  const seen: Set<string> = new Set<string>();
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
  const seen: Set<string> = new Set<string>();
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

function resolveSdkApiVersionSafe(): number {
  const rawValue = deviceInfo.sdkApiVersion as number | string;
  let parsedValue: number;
  if (typeof rawValue === 'number') {
    parsedValue = rawValue;
  } else if (typeof rawValue === 'string') {
    parsedValue = Number.parseInt(rawValue, 10);
  } else {
    parsedValue = Number.NaN;
  }
  if (!Number.isSafeInteger(parsedValue) || parsedValue <= 0) {
    return 0;
  }
  return parsedValue;
}

function sanitizeInitializationError(): Error {
  return new Error(INITIALIZATION_ERROR_MESSAGE);
}

async function safeCloseGraph(graph: ProfileRefreshPlatformGraph): Promise<void> {
  try {
    await graph.close();
  } catch (_) {
  }
}

async function safeCloseRdb(components: ProfileRefreshPlatformComponents): Promise<void> {
  try {
    await components.closeRdb();
  } catch (_) {
  }
}
