import { describe, expect, it } from '@ohos/hypium';
import { createCoreService } from '@cmfa/core';
import { PlatformFactory, type PlatformGraph } from '@cmfa/platform';
import {
  createProfile,
  ImportProfileUseCase,
  LocalRuntimeCoordinator,
  ManageProfileUseCases,
  ProfileApplication,
  ProfileCommitService,
  RefreshProfileUseCase,
  SerialCommandQueue,
  type CoreEvent,
  type CoreService,
  type LocalOptions,
  type Profile,
  type ProfileRevision,
  type RuntimeSnapshot
} from '@cmfa/shared';
import { HomeViewModel } from '../../../main/ets/presentation/HomeViewModel';
import {
  appendEvidenceCheck,
  appendEvidenceFailure,
  appendEvidenceTrace,
  flushEvidence,
  getTestAbilityContext,
  stageRawfileToSandbox,
  setEvidenceStatus
} from '../testability/TestAbility';

const SUITE_NAME: string = 'Phase3RuntimeFlow';
const EXPECTED_HTTP_ADDRESS: string = '127.0.0.1:7890';
const EXPECTED_SOCKS_ADDRESS: string = '127.0.0.1:7891';

export default function Phase3RuntimeFlowTestsuite(): void {
  describe(SUITE_NAME, () => {
    it('runs the real core through ProfileApplication and HomeViewModel', 0, async () => {
      appendEvidenceTrace(`${SUITE_NAME}.start`);
      let graph: PlatformGraph | undefined = undefined;
      let application: ProfileApplication | undefined = undefined;
      let homeViewModel: HomeViewModel | undefined = undefined;
      const trace: string[] = [];
      const profileIds: string[] = [];
      try {
        graph = await new PlatformFactory(getTestAbilityContext()).create();
        const staging = await stageRawfileToSandbox('phase3-valid.yaml');
        const realCore: CoreService = createCoreService();

        await realCore.validateConfiguration(staging.validationPath);
        trace.push('validate');

        const profileId: string = graph.idGenerator.nextId();
        profileIds.push(profileId);
        const retainedRevision: ProfileRevision = await graph.contentStore.retain(profileId, staging, 'CURRENT');
        const timestamp: string = new Date().toISOString();
        const profile: Profile = createProfile({
          id: profileId,
          name: 'Task 14 Runtime',
          sourceKind: 'LOCAL_FILE',
          sourceDisplay: 'phase3-valid.yaml',
          currentRevision: retainedRevision,
          failedCandidate: null,
          availability: 'VALID',
          lastError: null,
          createdAt: timestamp,
          updatedAt: timestamp,
          lastSuccessfulUpdateAt: timestamp
        });
        await graph.repository.save(profile);
        trace.push('retain/save');

        const tracedCore: TracedCoreService = new TracedCoreService(realCore, trace);
        application = createProductionProfileApplication(graph, tracedCore);
        await application.initialize();

        const enableResult = await application.enable(profileId);
        ensure(enableResult.kind === 'ENABLED', `Enable must succeed before runtime start: ${JSON.stringify(enableResult)}`);

        const startResult = await application.startLocal();
        ensure(startResult.kind === 'STARTED', `startLocal must succeed: ${JSON.stringify(startResult)}`);
        expect(application.current().runtime.state).assertEqual('RUNNING');
        const latest = application.current().runtime.latest;
        expect(latest.state).assertEqual('RUNNING');
        expect(latest.httpAddress).assertEqual(EXPECTED_HTTP_ADDRESS);
        expect(latest.socksAddress).assertEqual(EXPECTED_SOCKS_ADDRESS);
        trace.push(`RUNNING ${latest.httpAddress} ${latest.socksAddress}`);

        homeViewModel = new HomeViewModel(application);
        expect(homeViewModel.current().httpAddress).assertEqual(latest.httpAddress);
        expect(homeViewModel.current().socksAddress).assertEqual(latest.socksAddress);

        const stopResult = await application.stopLocal();
        ensure(stopResult.kind === 'STOPPED', `stopLocal must succeed: ${JSON.stringify(stopResult)}`);
        expect(application.current().runtime.state).assertEqual('STOPPED');
        expect(application.current().runtime.latest.state).assertEqual('STOPPED');
        trace.push('STOPPED');

        expect(JSON.stringify(trace)).assertEqual(JSON.stringify([
          'validate',
          'retain/save',
          'enable.validate',
          'enable.load',
          'start.revalidate',
          'start.load',
          'startLocal(7890)',
          `RUNNING ${EXPECTED_HTTP_ADDRESS} ${EXPECTED_SOCKS_ADDRESS}`,
          'stop',
          'STOPPED'
        ]));
        appendEvidenceCheck(`${SUITE_NAME}: runtime trace pass`);
      } catch (error) {
        setEvidenceStatus('FAIL');
        appendEvidenceFailure(SUITE_NAME, `${error}`);
        throw toError(error);
      } finally {
        let cleanupError: Error | undefined = undefined;
        try {
          homeViewModel?.dispose();
        } catch (error) {
          cleanupError = toError(error);
        }
        if (application !== undefined) {
          try {
            const cleanupStop = await application.stopLocal();
            ensure(cleanupStop.kind === 'STOPPED', `Cleanup stop must not fail: ${JSON.stringify(cleanupStop)}`);
          } catch (error) {
            cleanupError = cleanupError ?? toError(error);
          } finally {
            try {
              application.dispose();
            } catch (error) {
              cleanupError = cleanupError ?? toError(error);
            }
          }
        }
        if (graph !== undefined) {
          try {
            for (let index: number = 0; index < profileIds.length; index += 1) {
              await graph.repository.deleteAndClearActive(profileIds[index]);
              await graph.contentStore.removeProfile(profileIds[index]);
            }
          } catch (error) {
            cleanupError = cleanupError ?? toError(error);
          } finally {
            try {
              await graph.close();
            } catch (error) {
              cleanupError = cleanupError ?? toError(error);
            }
          }
        }
        if (cleanupError !== undefined) {
          setEvidenceStatus('FAIL');
          appendEvidenceFailure(SUITE_NAME, `cleanup: ${cleanupError}`);
          await flushEvidence();
          throw cleanupError;
        }
        await flushEvidence();
      }
    });
  });
}

class TracedCoreService implements CoreService {
  private readonly delegate: CoreService;
  private readonly trace: string[];
  private validateCallCount: number = 0;
  private loadCallCount: number = 0;

  constructor(delegate: CoreService, trace: string[]) {
    this.delegate = delegate;
    this.trace = trace;
  }

  hello(): string {
    return this.delegate.hello();
  }

  async coreVersion(): Promise<string> {
    return await this.delegate.coreVersion();
  }

  async validateConfiguration(path: string): Promise<void> {
    void path;
    this.validateCallCount += 1;
    this.trace.push(this.validateCallCount === 1 ? 'enable.validate' : 'start.revalidate');
    await this.delegate.validateConfiguration(path);
  }

  async loadConfiguration(path: string): Promise<void> {
    void path;
    this.loadCallCount += 1;
    this.trace.push(this.loadCallCount === 1 ? 'enable.load' : 'start.load');
    await this.delegate.loadConfiguration(path);
  }

  async startLocal(options: LocalOptions): Promise<RuntimeSnapshot> {
    this.trace.push(`startLocal(${options.mixedPort})`);
    return await this.delegate.startLocal(options);
  }

  async stopRuntime(): Promise<RuntimeSnapshot> {
    this.trace.push('stop');
    return await this.delegate.stopRuntime();
  }

  runtimeSnapshot(): RuntimeSnapshot {
    return this.delegate.runtimeSnapshot();
  }

  subscribe(callback: (event: CoreEvent) => void): number {
    return this.delegate.subscribe(callback);
  }

  unsubscribe(subscriptionId: number): void {
    this.delegate.unsubscribe(subscriptionId);
  }
}

function createProductionProfileApplication(graph: PlatformGraph, coreService: CoreService): ProfileApplication {
  const commitService = new ProfileCommitService({
    repository: graph.repository,
    contentStore: graph.contentStore,
    clock: graph.clock
  });
  const queue = new SerialCommandQueue();
  const runtimeCoordinator = new LocalRuntimeCoordinator({
    repository: graph.repository,
    contentStore: graph.contentStore,
    coreService,
    clock: graph.clock
  });
  return new ProfileApplication({
    importUseCase: new ImportProfileUseCase({
      repository: graph.repository,
      contentStore: graph.contentStore,
      sourceGateway: graph.sourceGateway,
      secretStore: graph.secretStore,
      coreService,
      clock: graph.clock,
      idGenerator: graph.idGenerator,
      queue,
      commitService
    }),
    refreshUseCase: new RefreshProfileUseCase({
      repository: graph.repository,
      contentStore: graph.contentStore,
      sourceGateway: graph.sourceGateway,
      secretStore: graph.secretStore,
      coreService,
      clock: graph.clock,
      queue,
      commitService
    }),
    manageProfileUseCases: new ManageProfileUseCases({
      repository: graph.repository,
      contentStore: graph.contentStore,
      secretStore: graph.secretStore,
      coreService,
      clock: graph.clock,
      runtimeCoordinator
    }),
    runtimeCoordinator,
    commitService,
    repository: graph.repository
  });
}

function ensure(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(message);
  }
}

function toError(error: Object | undefined): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(`${error}`);
}
