import { describe, expect, it } from '@ohos/hypium';
import { createCoreService } from '@cmfa/core';
import { PlatformFactory, type PlatformGraph } from '@cmfa/platform';
import {
  ActiveProfileProxyResolver,
  createProfile,
  ImportProfileUseCase,
  LocalRuntimeCoordinator,
  ManageProfileUseCases,
  ProfileApplication,
  ProfileCommitService,
  ProxyService,
  createProxyRuntimeNotReadyError,
  RefreshProfileUseCase,
  SerialCommandQueue,
  VpnProxyCommandBus,
  type CoreEvent,
  type CoreProxyDelaySnapshot,
  type CoreProxyGroupList,
  type CoreProxyGroupResult,
  type CoreProxyPort,
  type CoreProxyQueryContext,
  type CoreProxySelectionApplied,
  type CoreService,
  type LocalOptions,
  type OneClickVpnConfirmationHandle,
  type OneClickVpnConfirmationPort,
  type OneClickVpnConfirmationResult,
  type Profile,
  type ProfileRevision,
  type RuntimeSnapshot
} from '@cmfa/shared';
import { VpnSessionRegistry } from '../../../main/ets/vpn/VpnSessionRegistry';
import {
  appendEvidenceCheck,
  appendEvidenceFailure,
  appendEvidenceTrace,
  flushEvidence,
  getTestAbilityContext,
  setEvidenceCleanupStatus,
  setEvidenceHomeAddresses,
  stageRawfileToSandbox,
  setEvidenceStatus,
  TASK14_RUNTIME_FLOW_PASS_CHECK
} from '../testability/TestAbility';

const SUITE_NAME: string = 'Phase3RuntimeFlow';
const EXPECTED_HTTP_ADDRESS: string = '127.0.0.1:7890';
const EXPECTED_SOCKS_ADDRESS: string = '127.0.0.1:7891';

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

export default function Phase3RuntimeFlowTestsuite(): void {
  describe(SUITE_NAME, () => {
    it('runs the real core through ProfileApplication and LocalRuntimeCoordinator', 0, async () => {
      appendEvidenceTrace(`${SUITE_NAME}.start`);
      let graph: PlatformGraph | undefined = undefined;
      let coordinator: LocalRuntimeCoordinator | undefined = undefined;
      let application: ProfileApplication | undefined = undefined;
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
        coordinator = new LocalRuntimeCoordinator({
          repository: graph.repository,
          contentStore: graph.contentStore,
          coreService: tracedCore,
          clock: graph.clock
        });
        application = createProductionProfileApplication(graph, tracedCore, coordinator);
        await application.initialize();

        const enableResult = await application.enable(profileId);
        ensure(enableResult.kind === 'ENABLED', `Enable must succeed before runtime start: ${JSON.stringify(enableResult)}`);

        const startResult = await coordinator.start();
        ensure(startResult.kind === 'STARTED', `coordinator.start must succeed: ${JSON.stringify(startResult)}`);
        expect(coordinator.current().state).assertEqual('RUNNING');
        const latest = coordinator.current().latest;
        expect(latest.state).assertEqual('RUNNING');
        expect(latest.httpAddress).assertEqual(EXPECTED_HTTP_ADDRESS);
        expect(latest.socksAddress).assertEqual(EXPECTED_SOCKS_ADDRESS);
        trace.push(`RUNNING ${latest.httpAddress} ${latest.socksAddress}`);

        const homeHttpAddress: string = requireAddress(latest.httpAddress, 'Runtime httpAddress');
        const homeSocksAddress: string = requireAddress(latest.socksAddress, 'Runtime socksAddress');
        const diagnosticAddresses: string = formatListenerAddresses(homeHttpAddress, homeSocksAddress);
        setEvidenceHomeAddresses(
          diagnosticAddresses,
          diagnosticAddresses
        );

        const stopResult = await coordinator.stop();
        ensure(stopResult.kind === 'STOPPED', `coordinator.stop must succeed: ${JSON.stringify(stopResult)}`);
        expect(coordinator.current().state).assertEqual('STOPPED');
        expect(coordinator.current().latest.state).assertEqual('STOPPED');
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
        appendEvidenceCheck(TASK14_RUNTIME_FLOW_PASS_CHECK);
      } catch (error) {
        setEvidenceStatus('FAIL');
        appendEvidenceFailure(SUITE_NAME, `${error}`);
        throw toError(error);
      } finally {
        let cleanupError: Error | undefined = undefined;
        if (coordinator !== undefined) {
          try {
            const cleanupStop = await coordinator.stop();
            ensure(cleanupStop.kind === 'STOPPED', `Cleanup stop must not fail: ${JSON.stringify(cleanupStop)}`);
          } catch (error) {
            cleanupError = captureCleanupError(cleanupError, error);
          }
        }
        if (application !== undefined) {
          try {
            application.dispose();
          } catch (error) {
            cleanupError = captureCleanupError(cleanupError, error);
          }
        }
        if (coordinator !== undefined) {
          try {
            coordinator.dispose();
          } catch (error) {
            cleanupError = captureCleanupError(cleanupError, error);
          }
        }
        if (graph !== undefined) {
          try {
            for (let index: number = 0; index < profileIds.length; index += 1) {
              try {
                await graph.repository.deleteAndClearActive(profileIds[index]);
              } catch (error) {
                cleanupError = captureCleanupError(cleanupError, error);
              }
              try {
                await graph.contentStore.removeProfile(profileIds[index]);
              } catch (error) {
                cleanupError = captureCleanupError(cleanupError, error);
              }
            }
          } finally {
            try {
              await graph.close();
            } catch (error) {
              cleanupError = captureCleanupError(cleanupError, error);
            }
          }
        }
        if (cleanupError !== undefined) {
          setEvidenceCleanupStatus('fail');
          setEvidenceStatus('FAIL');
          appendEvidenceFailure(SUITE_NAME, `cleanup: ${cleanupError}`);
          await flushEvidence();
          throw cleanupError;
        }
        setEvidenceCleanupStatus('pass');
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

  async queryProxyGroups(context: CoreProxyQueryContext, selectableOnly: boolean): Promise<CoreProxyGroupList> {
    void context;
    void selectableOnly;
    return await Promise.reject(createProxyRuntimeNotReadyError('queryProxyGroups'));
  }

  async queryProxyGroup(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyGroupResult> {
    void context;
    void groupName;
    return await Promise.reject(createProxyRuntimeNotReadyError('queryProxyGroup'));
  }

  async selectProxy(
    context: CoreProxyQueryContext,
    groupName: string,
    memberName: string
  ): Promise<CoreProxySelectionApplied> {
    void context;
    void groupName;
    void memberName;
    return await Promise.reject(createProxyRuntimeNotReadyError('selectProxy'));
  }

  async startProxyDelayTest(_context: CoreProxyQueryContext, _groupName: string): Promise<CoreProxyDelaySnapshot> {
    return await Promise.reject(createProxyRuntimeNotReadyError('startProxyDelayTest'));
  }

  async readProxyDelayTest(_jobId: string): Promise<CoreProxyDelaySnapshot> {
    return await Promise.reject(createProxyRuntimeNotReadyError('readProxyDelayTest'));
  }

  async cancelProxyDelayTest(_jobId: string): Promise<CoreProxyDelaySnapshot> {
    return await Promise.reject(createProxyRuntimeNotReadyError('cancelProxyDelayTest'));
  }

  subscribe(callback: (event: CoreEvent) => void): number {
    return this.delegate.subscribe(callback);
  }

  unsubscribe(subscriptionId: number): void {
    this.delegate.unsubscribe(subscriptionId);
  }
}

function createProductionProfileApplication(
  graph: PlatformGraph,
  coreService: CoreService,
  runtimeCoordinator: LocalRuntimeCoordinator
): ProfileApplication {
  const commitService = new ProfileCommitService({
    repository: graph.repository,
    contentStore: graph.contentStore,
    clock: graph.clock
  });
  const queue = new SerialCommandQueue();
  const oneClickVpnConfirmation: OneClickVpnConfirmationPort = new InertOneClickVpnConfirmation();
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
    repository: graph.repository,
    oneClickVpnConfirmation,
    proxyService: new ProxyService(
      new ActiveProfileProxyResolver(graph.repository, graph.contentStore),
      new CoreProxyServiceAdapter(coreService),
      graph.proxySelectionRepository,
      graph.proxyIdentityHasher,
      new VpnSessionRegistry(),
      new VpnProxyCommandBus(),
      graph.clock
    )
  });
}

class CancelledOneClickVpnConfirmationResultValue implements OneClickVpnConfirmationResult {
  kind: 'CANCELLED' = 'CANCELLED';
}

class InertOneClickVpnConfirmationHandle implements OneClickVpnConfirmationHandle {
  async wait(): Promise<OneClickVpnConfirmationResult> {
    return new CancelledOneClickVpnConfirmationResultValue();
  }

  markStartAccepted(): void {
  }

  cancel(): void {
  }
}

class InertOneClickVpnConfirmation implements OneClickVpnConfirmationPort {
  arm(_expectedSessionId: string, _timeoutMs: number): OneClickVpnConfirmationHandle {
    return new InertOneClickVpnConfirmationHandle();
  }
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

function captureCleanupError(current: Error | undefined, error: Object | undefined): Error {
  if (current !== undefined) {
    return current;
  }
  return toError(error);
}

function formatListenerAddresses(httpAddress: string, socksAddress: string): string {
  return `${httpAddress}|${socksAddress}`;
}

function requireAddress(value: string | undefined, label: string): string {
  if (value === undefined) {
    throw new Error(`${label} must be defined.`);
  }
  return value;
}
