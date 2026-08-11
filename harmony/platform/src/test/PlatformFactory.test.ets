import common from '@ohos.app.ability.common';
import { describe, expect, it } from '@ohos/hypium';
import {
  createProfile,
  createProfileRevision,
  type AppError,
  type IdGenerator,
  type LocalProfileAcquisition,
  type LocalProfileAcquisitionSuccess,
  type Profile,
  type ProfileContentStore,
  type ProfileRepository,
  type ProfileRevision,
  type RemoteAcquireCommand,
  type RemoteProfileAcquisition,
  type RemoteProfileAcquisitionSuccess,
  type RevisionKind,
  type StagedSource
} from '@cmfa/shared';
import { PlatformFactory, type PlatformFactoryDependencies, type PlatformGraph, type PlatformPaths, type CloseableRdbDriver, type PrepareableHuksDriver, type PlatformSecretStore, type PlatformPickerDependencies, type PlatformRequestAgentTransportDependencies } from '../main/ets/PlatformFactory';
import type { DurableProfileRow } from '../main/ets/rdb/RdbDriver';
import { encodeProfileRow } from '../main/ets/rdb/ProfileRowCodec';
import { RdbProfileRepository } from '../main/ets/rdb/RdbProfileRepository';
import { SandboxProfileContentStore } from '../main/ets/files/SandboxProfileContentStore';
import type { FileDriver } from '../main/ets/files/FileDriver';
import { HuksSubscriptionSecretStore } from '../main/ets/secrets/HuksSubscriptionSecretStore';
import type { HuksDriver, HuksEncryptedPayload } from '../main/ets/secrets/HuksDriver';
import type { HttpTransport, HttpTransportRequest, HttpTransportResponse } from '../main/ets/source/HttpTransport';
import { HarmonyProfileSourceGateway } from '../main/ets/source/HarmonyProfileSourceGateway';
import type {
  HarmonyProfileSourceGatewayDependencies,
  LocalProfileAcquirer,
  RemoteProfileAcquirer
} from '../main/ets/source/HarmonyProfileSourceGateway';
import {
  DeterministicHuksDriver,
  FakeFileDriver,
  RecordingRdbDriver,
  SequenceClock,
  SequenceIdGenerator,
  assertNoLeak,
  buildBytes
} from './fakes/PlatformFakes';

const FILES_DIR: string = '/sandbox/app/files';
const DATABASE_NAME: string = 'cmfa_profiles.db';

class FakeLocalAcquirer implements LocalProfileAcquirer {
  callCount: number = 0;
  nextResult: LocalProfileAcquisition;

  constructor(nextResult: LocalProfileAcquisition) {
    this.nextResult = nextResult;
  }

  async acquire(): Promise<LocalProfileAcquisition> {
    this.callCount += 1;
    return this.nextResult;
  }
}

class FakeRemoteAcquirer implements RemoteProfileAcquirer {
  callCount: number = 0;
  readonly commands: RemoteAcquireCommand[] = [];
  nextResult: RemoteProfileAcquisition;

  constructor(nextResult: RemoteProfileAcquisition) {
    this.nextResult = nextResult;
  }

  async acquire(command: RemoteAcquireCommand): Promise<RemoteProfileAcquisition> {
    this.callCount += 1;
    this.commands.push(command);
    return this.nextResult;
  }
}

class CloseableRecordingRdbDriver extends RecordingRdbDriver implements CloseableRdbDriver {
  readonly events: string[];
  closeCallCount: number = 0;

  constructor(events: string[]) {
    super();
    this.events = events;
  }

  async initialize(version: number): Promise<void> {
    this.events.push(`rdb.initialize:${version}`);
    await super.initialize(version);
  }

  async listProfileRows(): Promise<DurableProfileRow[]> {
    this.events.push('repository.list');
    return await super.listProfileRows();
  }

  async close(): Promise<void> {
    this.closeCallCount += 1;
    this.events.push('rdb.close');
  }
}

class RecordingPrepareHuksDriver implements PrepareableHuksDriver {
  readonly events: string[];
  readonly delegate: DeterministicHuksDriver;
  prepareCallCount: number = 0;

  constructor(events: string[]) {
    this.events = events;
    this.delegate = new DeterministicHuksDriver();
  }

  async prepare(): Promise<void> {
    this.prepareCallCount += 1;
    this.events.push('huks.prepare');
    await this.delegate.prepare();
  }

  async encrypt(plaintext: Uint8Array): Promise<HuksEncryptedPayload> {
    return await this.delegate.encrypt(plaintext);
  }

  async decrypt(payload: HuksEncryptedPayload): Promise<Uint8Array> {
    return await this.delegate.decrypt(payload);
  }
}

class ThrowingPrepareHuksDriverFactory {
  readonly error: Error;

  constructor(error: Error) {
    this.error = error;
  }

  create(): PrepareableHuksDriver {
    throw this.error;
  }
}

class RecordingContentStore implements ProfileContentStore {
  readonly delegate: SandboxProfileContentStore;
  readonly events: string[];

  constructor(delegate: SandboxProfileContentStore, events: string[]) {
    this.delegate = delegate;
    this.events = events;
  }

  async retain(profileId: string, staged: StagedSource, kind: RevisionKind): Promise<ProfileRevision> {
    return await this.delegate.retain(profileId, staged, kind);
  }

  async discard(staged: StagedSource): Promise<void> {
    await this.delegate.discard(staged);
  }

  async removeRevision(revision: ProfileRevision): Promise<void> {
    await this.delegate.removeRevision(revision);
  }

  async removeProfile(profileId: string): Promise<void> {
    await this.delegate.removeProfile(profileId);
  }

  async reconcile(referenced: ProfileRevision[]): Promise<void> {
    this.events.push(`content.reconcile:${referenced.length}`);
    await this.delegate.reconcile(referenced);
  }

  resolveCorePath(revision: ProfileRevision): string {
    return this.delegate.resolveCorePath(revision);
  }
}

class RecordingSecretStore implements PlatformSecretStore {
  readonly delegate: HuksSubscriptionSecretStore;
  readonly events: string[];

  constructor(delegate: HuksSubscriptionSecretStore, events: string[]) {
    this.delegate = delegate;
    this.events = events;
  }

  async encrypt(plaintext: string): Promise<string> {
    return await this.delegate.encrypt(plaintext);
  }

  async decrypt(secretRef: string): Promise<string> {
    return await this.delegate.decrypt(secretRef);
  }

  async remove(secretRef: string): Promise<void> {
    await this.delegate.remove(secretRef);
  }

  async reconcile(referencedSecretIds: string[]): Promise<void> {
    this.events.push(`secret.reconcile:${referencedSecretIds.length}`);
    await this.delegate.reconcile(referencedSecretIds);
  }
}

class ThrowingContentStore implements ProfileContentStore {
  readonly detail: string;
  readonly events: string[];

  constructor(detail: string, events: string[]) {
    this.detail = detail;
    this.events = events;
  }

  async retain(_profileId: string, _staged: StagedSource, _kind: RevisionKind): Promise<ProfileRevision> {
    throw new Error('unused');
  }

  async discard(_staged: StagedSource): Promise<void> {
  }

  async removeRevision(_revision: ProfileRevision): Promise<void> {
  }

  async removeProfile(_profileId: string): Promise<void> {
  }

  async reconcile(_referenced: ProfileRevision[]): Promise<void> {
    this.events.push('content.reconcile:throw');
    throw new Error(this.detail);
  }

  resolveCorePath(revision: ProfileRevision): string {
    return revision.relativePath;
  }
}

class TrackingHttpTransport implements HttpTransport {
  readonly name: string;
  fetchCallCount: number = 0;
  readonly requests: HttpTransportRequest[] = [];
  readonly responseBody: Uint8Array;

  constructor(name: string, responseBody?: Uint8Array) {
    this.name = name;
    this.responseBody = responseBody ?? buildBytes(32);
  }

  async fetch(request: HttpTransportRequest): Promise<HttpTransportResponse> {
    this.fetchCallCount += 1;
    this.requests.push(request);
    return {
      statusCode: 200,
      headers: new Map<string, Array<string>>(),
      body: this.responseBody.buffer.slice(0)
    };
  }
}

interface TransportGraphConfig {
  sdkApiVersion: number;
  context: common.UIAbilityContext;
  networkKitTransport: HttpTransport;
  requestAgentTransport: HttpTransport;
}

function createContext(filesDir: string = FILES_DIR): common.UIAbilityContext {
  return {
    filesDir
  } as common.UIAbilityContext;
}

function createStagedSource(id: string): StagedSource {
  return {
    stagingId: id,
    validationPath: `${FILES_DIR}/tmp/${id}.yaml`,
    sha256Digest: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    byteLength: 128,
    validatedAt: '2026-08-07T00:00:00.000Z'
  };
}

function createRevision(relativePath: string): ProfileRevision {
  return createProfileRevision(
    relativePath,
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    64,
    '2026-08-07T00:00:00.000Z'
  );
}

function createProfileRecord(
  id: string,
  currentRevision: ProfileRevision | null,
  failedCandidate: ProfileRevision | null,
  sourceSecretRef?: string
): Profile {
  return createProfile({
    id,
    name: `Profile ${id}`,
    sourceKind: sourceSecretRef === undefined ? 'LOCAL_FILE' : 'REMOTE_URL',
    sourceDisplay: sourceSecretRef === undefined ? `${id}.yaml` : 'https://profiles.example.com',
    sourceSecretRef,
    currentRevision,
    failedCandidate,
    availability: currentRevision === null ? 'INVALID' : failedCandidate === null ? 'VALID' : 'UPDATE_FAILED_USING_VALID',
    lastError: null,
    createdAt: '2026-08-07T00:00:00.000Z',
    updatedAt: '2026-08-07T00:05:00.000Z',
    lastSuccessfulUpdateAt: currentRevision === null ? null : '2026-08-07T00:06:00.000Z'
  });
}

function asLocalAcquired(result: LocalProfileAcquisition): LocalProfileAcquisitionSuccess {
  return result as LocalProfileAcquisitionSuccess;
}

function asRemoteAcquired(result: RemoteProfileAcquisition): RemoteProfileAcquisitionSuccess {
  return result as RemoteProfileAcquisitionSuccess;
}

function asAppError(error: Object): AppError {
  return error as AppError;
}

function assertOrderedEvents(events: string[], expected: string[]): void {
  let cursor: number = -1;
  for (let index: number = 0; index < expected.length; index += 1) {
    const nextCursor: number = events.indexOf(expected[index], cursor + 1);
    expect(nextCursor >= 0).assertTrue();
    cursor = nextCursor;
  }
}

function createDefaultDependencies(
  context: common.UIAbilityContext,
  fileDriver: FileDriver,
  rdbDriver: CloseableRdbDriver,
  huksDriver: PrepareableHuksDriver,
  clock?: SequenceClock,
  idGenerator?: SequenceIdGenerator
): PlatformFactoryDependencies {
  const fixedClock: SequenceClock = clock ?? new SequenceClock(['2026-08-07T00:00:00.000Z']);
  const fixedIds: SequenceIdGenerator = idGenerator ?? new SequenceIdGenerator(['stage-one', 'stage-two', 'stage-three']);
  return {
    resolvePaths: (_context: common.UIAbilityContext): PlatformPaths => ({
      filesDir: context.filesDir,
      databaseName: DATABASE_NAME
    }),
    createClock: (): SequenceClock => fixedClock,
    createIdGenerator: (): SequenceIdGenerator => fixedIds,
    createFileDriver: (): FileDriver => fileDriver,
    createRdbDriver: (): CloseableRdbDriver => rdbDriver,
    createHuksDriver: (): PrepareableHuksDriver => huksDriver,
    resolveSdkApiVersion: (): number => 23
  };
}

async function createTransportGraph(config: TransportGraphConfig): Promise<PlatformGraph> {
  const fileDriver: FakeFileDriver = new FakeFileDriver();
  const rdbDriver: CloseableRecordingRdbDriver = new CloseableRecordingRdbDriver([]);
  const huksDriver: RecordingPrepareHuksDriver = new RecordingPrepareHuksDriver([]);
  const dependencies: PlatformFactoryDependencies = createDefaultDependencies(
    config.context,
    fileDriver,
    rdbDriver,
    huksDriver,
    new SequenceClock(['2026-08-07T00:00:00.000Z']),
    new SequenceIdGenerator([`download-${config.sdkApiVersion}`])
  );
  let pickerContextMatched: boolean = false;
  let requestContextMatched: boolean = false;
  let resolvedSdkApiVersionCallCount: number = 0;

  dependencies.resolveSdkApiVersion = (): number => config.sdkApiVersion;
  dependencies.resolveSdkApiVersion = (): number => {
    resolvedSdkApiVersionCallCount += 1;
    return config.sdkApiVersion;
  };
  dependencies.createPicker = (pickerDependencies: PlatformPickerDependencies): LocalProfileAcquirer => {
    pickerContextMatched = pickerDependencies.context === config.context;
    return new FakeLocalAcquirer({
      kind: 'ACQUIRED',
      profileName: '本地配置',
      sourceDisplay: 'picked.yaml',
      staged: createStagedSource(`picked-${config.sdkApiVersion}`)
    });
  };
  dependencies.createNetworkKitTransport = (): HttpTransport => config.networkKitTransport;
  dependencies.createRequestAgentTransport = (
    requestDependencies: PlatformRequestAgentTransportDependencies
  ): HttpTransport => {
    requestContextMatched = requestDependencies.context === config.context;
    return config.requestAgentTransport;
  };

  const graph: PlatformGraph = await new PlatformFactory(config.context, dependencies).create();
  expect(pickerContextMatched).assertTrue();
  expect(requestContextMatched).assertTrue();
  expect(resolvedSdkApiVersionCallCount).assertEqual(1);
  return graph;
}

export default function platformFactoryTestsuite() {
  describe('HarmonyProfileSourceGatewayTest', () => {
    it('delegatesLocalAndRemoteAcquisitionWithoutMutatingSharedValues', 0, async () => {
      const localResult: LocalProfileAcquisition = {
        kind: 'ACQUIRED',
        profileName: '本地配置',
        sourceDisplay: 'local.yaml',
        staged: createStagedSource('picked-stage')
      };
      const remoteResult: RemoteProfileAcquisition = {
        kind: 'ACQUIRED',
        profileName: 'Remote',
        sourceDisplay: 'https://profiles.example.com',
        staged: createStagedSource('download-stage')
      };
      const localAcquirer: FakeLocalAcquirer = new FakeLocalAcquirer(localResult);
      const remoteAcquirer: FakeRemoteAcquirer = new FakeRemoteAcquirer(remoteResult);
      const gatewayDependencies: HarmonyProfileSourceGatewayDependencies = {
        localAcquirer,
        remoteAcquirer
      };
      const gateway: HarmonyProfileSourceGateway = new HarmonyProfileSourceGateway(gatewayDependencies);

      const localAcquired: LocalProfileAcquisitionSuccess = asLocalAcquired(
        await gateway.acquireLocal({ preferredName: 'unused' })
      );
      const remoteAcquired: RemoteProfileAcquisitionSuccess = asRemoteAcquired(
        await gateway.acquireRemote({
          sourceUrl: 'https://profiles.example.com/edge.yaml',
          allowPlainHttp: false,
          profileName: 'Remote',
          sourceDisplay: 'https://profiles.example.com'
        })
      );

      expect(localAcquirer.callCount).assertEqual(1);
      expect(remoteAcquirer.callCount).assertEqual(1);
      expect(localAcquired.staged.validationPath).assertEqual(`${FILES_DIR}/tmp/picked-stage.yaml`);
      expect(remoteAcquired.staged.validationPath).assertEqual(`${FILES_DIR}/tmp/download-stage.yaml`);
      expect(remoteAcquirer.commands[0].sourceUrl).assertEqual('https://profiles.example.com/edge.yaml');
    });
  });

  describe('PlatformFactoryTest', () => {
    it('memoizesConcurrentInitializationAndReconcilesReferencedContentAndSecretsBeforeReadiness', 0, async () => {
      const events: string[] = [];
      const context: common.UIAbilityContext = createContext();
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const rdbDriver: CloseableRecordingRdbDriver = new CloseableRecordingRdbDriver(events);
      const huksDriver: RecordingPrepareHuksDriver = new RecordingPrepareHuksDriver(events);
      const currentA: ProfileRevision = createRevision('profiles/profile-a/valid/current-a.yaml');
      const currentB: ProfileRevision = createRevision('profiles/profile-b/valid/current-b.yaml');
      const failedB: ProfileRevision = createRevision('profiles/profile-b/failed/failed-b.yaml');
      const orphanRelativePath: string = 'profiles/orphan/valid/orphan.yaml';
      const profileA: Profile = createProfileRecord('profile-a', currentA, null, 'secret-alpha');
      const profileB: Profile = createProfileRecord('profile-b', currentB, failedB, 'secret-beta');
      const dependencies: PlatformFactoryDependencies = createDefaultDependencies(context, fileDriver, rdbDriver, huksDriver);
      let firstPromise: Promise<PlatformGraph>;
      let secondPromise: Promise<PlatformGraph>;
      let firstGraph: PlatformGraph;
      let secondGraph: PlatformGraph;

      rdbDriver.seedListRows([encodeProfileRow(profileA), encodeProfileRow(profileB)]);
      fileDriver.seedTextFile(`${FILES_DIR}/${currentA.relativePath}`, 'current-a');
      fileDriver.seedTextFile(`${FILES_DIR}/${currentB.relativePath}`, 'current-b');
      fileDriver.seedTextFile(`${FILES_DIR}/${failedB.relativePath}`, 'failed-b');
      fileDriver.seedTextFile(`${FILES_DIR}/${orphanRelativePath}`, 'orphan');
      fileDriver.seedTextFile(`${FILES_DIR}/profile-secrets/secret-alpha.json`, '{"value":"alpha"}');
      fileDriver.seedTextFile(`${FILES_DIR}/profile-secrets/secret-beta.json`, '{"value":"beta"}');
      fileDriver.seedTextFile(`${FILES_DIR}/profile-secrets/secret-orphan.json`, '{"value":"orphan"}');

      dependencies.resolvePaths = (_context: common.UIAbilityContext): PlatformPaths => {
        events.push('paths.resolve');
        return {
          filesDir: context.filesDir,
          databaseName: DATABASE_NAME
        };
      };
      dependencies.createContentStore = (_fileDriver: FileDriver, paths: PlatformPaths): ProfileContentStore => {
        expect(paths.filesDir).assertEqual(FILES_DIR);
        return new RecordingContentStore(new SandboxProfileContentStore(_fileDriver, paths.filesDir), events);
      };
      dependencies.createSecretStore = (
        _huksDriver: PrepareableHuksDriver,
        _fileDriver: FileDriver,
        paths: PlatformPaths,
        _idGenerator: IdGenerator
      ): PlatformSecretStore => {
        expect(paths.filesDir).assertEqual(FILES_DIR);
        return new RecordingSecretStore(
          new HuksSubscriptionSecretStore(_huksDriver, _fileDriver, paths.filesDir, _idGenerator),
          events
        );
      };

      const initializeReleased = rdbDriver.blockNextInitialize();
      const initializeStarted = rdbDriver.nextInitializeStarted();
      const factory: PlatformFactory = new PlatformFactory(context, dependencies);
      firstPromise = factory.create();
      secondPromise = factory.create();

      await initializeStarted.promise;
      await Promise.resolve();
      expect(rdbDriver.initializeCallCount).assertEqual(1);

      initializeReleased.resolve(undefined);
      firstGraph = await firstPromise;
      secondGraph = await secondPromise;

      expect(firstGraph === secondGraph).assertTrue();
      expect(rdbDriver.initializeCallCount).assertEqual(1);
      expect(rdbDriver.closeCallCount).assertEqual(0);
      expect(huksDriver.prepareCallCount).assertEqual(1);
      expect(fileDriver.fileExists(`${FILES_DIR}/${orphanRelativePath}`)).assertFalse();
      expect(fileDriver.fileExists(`${FILES_DIR}/${currentA.relativePath}`)).assertTrue();
      expect(fileDriver.fileExists(`${FILES_DIR}/${currentB.relativePath}`)).assertTrue();
      expect(fileDriver.fileExists(`${FILES_DIR}/${failedB.relativePath}`)).assertTrue();
      expect(fileDriver.fileExists(`${FILES_DIR}/profile-secrets/secret-orphan.json`)).assertFalse();
      expect(fileDriver.fileExists(`${FILES_DIR}/profile-secrets/secret-alpha.json`)).assertTrue();
      expect(fileDriver.fileExists(`${FILES_DIR}/profile-secrets/secret-beta.json`)).assertTrue();
      expect(firstGraph.repository instanceof RdbProfileRepository).assertTrue();
      expect(Object.keys(firstGraph).sort().join(',')).assertEqual(
        'clock,contentStore,idGenerator,repository,secretStore,sourceGateway'
      );
      expect(typeof firstGraph.close === 'function').assertTrue();
      assertOrderedEvents(events, [
        'paths.resolve',
        'rdb.initialize:1',
        'repository.list',
        'content.reconcile:3',
        'secret.reconcile:2',
        'huks.prepare'
      ]);

      await firstGraph.close();
      await firstGraph.close();
      expect(rdbDriver.closeCallCount).assertEqual(1);
    });

    it('sanitizesInitializationFailuresClosesPartialResourcesAndRetriesFresh', 0, async () => {
      const events: string[] = [];
      const context: common.UIAbilityContext = createContext();
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const unsafeDetail: string = 'cleanup failed for sentinel-secret-token and sentinel-secret-yaml';
      const firstDriver: CloseableRecordingRdbDriver = new CloseableRecordingRdbDriver(events);
      const secondDriver: CloseableRecordingRdbDriver = new CloseableRecordingRdbDriver(events);
      const huksDriver: RecordingPrepareHuksDriver = new RecordingPrepareHuksDriver(events);
      const drivers: CloseableRecordingRdbDriver[] = [firstDriver, secondDriver];
      const dependencies: PlatformFactoryDependencies = createDefaultDependencies(context, fileDriver, firstDriver, huksDriver);
      let driverIndex: number = 0;

      dependencies.createRdbDriver = (): CloseableRdbDriver => {
        const resolvedIndex: number = Math.min(driverIndex, drivers.length - 1);
        const nextDriver: CloseableRecordingRdbDriver = drivers[resolvedIndex];
        driverIndex += 1;
        return nextDriver;
      };
      dependencies.createRepository = (driver: CloseableRdbDriver): ProfileRepository => {
        const repository: RdbProfileRepository = new RdbProfileRepository(driver);
        const seededDriver: CloseableRecordingRdbDriver = driver as CloseableRecordingRdbDriver;
        const seededProfile: Profile = createProfileRecord(
          'profile-a',
          createRevision('profiles/profile-a/valid/a.yaml'),
          null,
          'secret-alpha'
        );
        seededDriver.seedListRows([encodeProfileRow(seededProfile)]);
        return repository;
      };
      dependencies.createContentStore = (): ProfileContentStore => new ThrowingContentStore(unsafeDetail, events);
      dependencies.createSecretStore = (
        _huksDriver: PrepareableHuksDriver,
        _fileDriver: FileDriver,
        paths: PlatformPaths,
        _idGenerator: IdGenerator
      ): PlatformSecretStore => new RecordingSecretStore(
        new HuksSubscriptionSecretStore(_huksDriver, _fileDriver, paths.filesDir, _idGenerator),
        events
      );

      const factory: PlatformFactory = new PlatformFactory(context, dependencies);

      try {
        await factory.create();
        expect(false).assertTrue();
      } catch (error) {
        const appError: AppError = asAppError(error as Object);
        expect(appError.stage).assertEqual('PERSISTENCE');
        expect(appError.code).assertEqual('CMFA_PERSISTENCE_FAILED');
        expect(appError.retryable).assertTrue();
        expect(appError.technicalDetail).assertEqual('Platform initialization failed.');
        assertNoLeak(appError.technicalDetail, ['sentinel-secret-token', 'sentinel-secret-yaml']);
      }

      expect(firstDriver.closeCallCount).assertEqual(1);
      expect(secondDriver.closeCallCount).assertEqual(0);

      dependencies.createContentStore = (_fileDriver: FileDriver, paths: PlatformPaths): ProfileContentStore =>
        new SandboxProfileContentStore(_fileDriver, paths.filesDir);
      const graph: PlatformGraph = await factory.create();
      expect(driverIndex).assertEqual(2);
      expect(graph.repository instanceof RdbProfileRepository).assertTrue();

      await graph.close();
      expect(secondDriver.closeCallCount).assertEqual(1);
    });

    it('closesTheAcquiredRdbDriverWhenCreateHuksDriverThrowsSynchronouslyAndRetriesWithFreshDrivers', 0, async () => {
      const context: common.UIAbilityContext = createContext();
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const firstDriver: CloseableRecordingRdbDriver = new CloseableRecordingRdbDriver([]);
      const secondDriver: CloseableRecordingRdbDriver = new CloseableRecordingRdbDriver([]);
      const drivers: CloseableRecordingRdbDriver[] = [firstDriver, secondDriver];
      const dependencies: PlatformFactoryDependencies = createDefaultDependencies(
        context,
        fileDriver,
        firstDriver,
        new RecordingPrepareHuksDriver([])
      );
      let driverIndex: number = 0;
      let throwHuksFactory: boolean = true;
      const huksThrow = new ThrowingPrepareHuksDriverFactory(new Error('huks create failed'));

      dependencies.createRdbDriver = (): CloseableRdbDriver => {
        const nextDriver: CloseableRecordingRdbDriver = drivers[Math.min(driverIndex, drivers.length - 1)];
        driverIndex += 1;
        return nextDriver;
      };
      dependencies.createHuksDriver = (): PrepareableHuksDriver => {
        if (throwHuksFactory) {
          return huksThrow.create();
        }
        return new RecordingPrepareHuksDriver([]);
      };

      const factory: PlatformFactory = new PlatformFactory(context, dependencies);

      try {
        await factory.create();
        expect(false).assertTrue();
      } catch (error) {
        const appError: AppError = asAppError(error as Object);
        expect(appError.stage).assertEqual('PERSISTENCE');
        expect(appError.technicalDetail).assertEqual('Platform initialization failed.');
      }

      expect(firstDriver.closeCallCount).assertEqual(1);
      expect(secondDriver.closeCallCount).assertEqual(0);
      expect(driverIndex).assertEqual(1);

      throwHuksFactory = false;
      const graph: PlatformGraph = await factory.create();
      expect(driverIndex).assertEqual(2);
      expect(graph.repository instanceof RdbProfileRepository).assertTrue();

      await graph.close();
      expect(secondDriver.closeCallCount).assertEqual(1);
    });

    it('selectsRemoteTransportBySdkVersionAndPassesTheRealContextIntoPlatformFactories', 0, async () => {
      const responseBytes: Uint8Array = buildBytes(48);
      const context: common.UIAbilityContext = createContext();
      const networkKitTransport: TrackingHttpTransport = new TrackingHttpTransport('networkKit', responseBytes);
      const requestAgentTransport: TrackingHttpTransport = new TrackingHttpTransport('requestAgent', responseBytes);

      const api23Graph: PlatformGraph = await createTransportGraph({
        sdkApiVersion: 23,
        context,
        networkKitTransport,
        requestAgentTransport
      });
      const api23Local: LocalProfileAcquisitionSuccess = asLocalAcquired(
        await api23Graph.sourceGateway.acquireLocal({ preferredName: '本地配置' })
      );
      const api23Remote: RemoteProfileAcquisitionSuccess = asRemoteAcquired(
        await api23Graph.sourceGateway.acquireRemote({
          sourceUrl: 'https://profiles.example.com/api23.yaml',
          allowPlainHttp: false,
          profileName: 'API23',
          sourceDisplay: 'https://profiles.example.com'
        })
      );

      expect(api23Local.staged.stagingId).assertEqual('picked-23');
      expect(api23Remote.staged.stagingId).assertEqual('download-23');
      expect(networkKitTransport.fetchCallCount).assertEqual(1);
      expect(requestAgentTransport.fetchCallCount).assertEqual(0);
      await api23Graph.close();

      const api20Graph: PlatformGraph = await createTransportGraph({
        sdkApiVersion: 20,
        context,
        networkKitTransport,
        requestAgentTransport
      });
      const api20Remote: RemoteProfileAcquisitionSuccess = asRemoteAcquired(
        await api20Graph.sourceGateway.acquireRemote({
          sourceUrl: 'https://profiles.example.com/api20.yaml',
          allowPlainHttp: false,
          profileName: 'API20',
          sourceDisplay: 'https://profiles.example.com'
        })
      );

      expect(api20Remote.staged.stagingId).assertEqual('download-20');
      expect(networkKitTransport.fetchCallCount).assertEqual(1);
      expect(requestAgentTransport.fetchCallCount).assertEqual(1);
      await api20Graph.close();
    });
  });
}
