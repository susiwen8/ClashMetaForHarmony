import type { Want } from '@kit.AbilityKit';
import common from '@ohos.app.ability.common';
import { describe, expect, it } from '@ohos/hypium';
import type { PlatformGraph } from '@cmfa/platform';
import {
  VpnRuntimeCoordinator,
  createProfile,
  createProfileRevision,
  createTunHandle,
  createTunRuntimeSnapshot,
  createVpnCaptureConfig,
  createVpnCounters,
  createVpnFailure,
  type BoundedDelaySchedulerPort,
  type CancelableDelayTask,
  type ClockPort,
  type ContinuousNotificationPort,
  type NetworkRecoveryPort,
  type NetworkStatus,
  type Profile,
  type ProfileContentStore,
  type ProfileRepository,
  type ProfileRevision,
  type ProfileSourceGateway,
  type StagedSource,
  type SubscriptionSecretStore,
  type TunHandle,
  type TunRuntimeEvent,
  type TunRuntimePort,
  type TunRuntimeSnapshot,
  type TunStartOptions,
  type VpnCaptureConfig,
  type VpnControllerPort,
  type VpnFailure,
  type VpnPlatformSessionPort
} from '@cmfa/shared';
import CmfaVpnExtensionAbility from '../main/ets/vpn/CmfaVpnExtensionAbility';
import {
  VpnExtensionCompositionRunner,
  VpnExtensionComposition,
  installVpnExtensionCompositionFactoryForTesting,
  resetVpnExtensionCompositionForTesting,
  type VpnExtensionCompositionDependencies
} from '../main/ets/vpn/VpnExtensionComposition';
import { VpnSessionRegistry } from '../main/ets/vpn/VpnSessionRegistry';

class ImmediateDelayTask implements CancelableDelayTask {
  cancel(): void {
  }
}

class ImmediateScheduler implements BoundedDelaySchedulerPort {
  schedule(_delayMs: number, runner: () => Promise<void>): CancelableDelayTask {
    void runner();
    return new ImmediateDelayTask();
  }
}

class FixedClock implements ClockPort {
  nowMs(): number {
    return 100;
  }
}

class SilentNetworkRecovery implements NetworkRecoveryPort {
  currentNetwork(): NetworkStatus {
    return {
      usable: false,
      networkId: ''
    };
  }

  subscribeUsableNetwork(_listener: (status: NetworkStatus) => void): number {
    return 1;
  }

  unsubscribeUsableNetwork(_subscriptionId: number): void {
  }
}

class MemoryRepository implements ProfileRepository {
  private readonly profile?: Profile;

  constructor(profile?: Profile) {
    this.profile = profile;
  }

  async list(): Promise<Profile[]> {
    return this.profile === undefined ? [] : [this.profile];
  }

  async get(id: string): Promise<Profile | undefined> {
    if (this.profile === undefined || this.profile.id !== id) {
      return undefined;
    }
    return this.profile;
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

class MemoryContentStore implements ProfileContentStore {
  resolveCorePath(revision: ProfileRevision): string {
    return `/sandbox/${revision.relativePath}`;
  }

  async retain(_profileId: string, _staged: StagedSource, _kind: 'CURRENT' | 'FAILED_CANDIDATE'): Promise<ProfileRevision> {
    throw new Error('retain unused');
  }

  async discard(_staged: StagedSource): Promise<void> {
  }

  async removeRevision(_revision: ProfileRevision): Promise<void> {
  }

  async removeProfile(_profileId: string): Promise<void> {
  }

  async reconcile(_referenced: ProfileRevision[]): Promise<void> {
  }
}

class InertSourceGateway implements ProfileSourceGateway {
  async acquireLocal(): Promise<never> {
    throw new Error('unused');
  }

  async acquireRemote(): Promise<never> {
    throw new Error('unused');
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
  readonly sourceGateway: ProfileSourceGateway = new InertSourceGateway();
  readonly secretStore: SubscriptionSecretStore = new InertSecretStore();
  readonly clock: GraphClock = new GraphClock();
  readonly idGenerator: GraphIdGenerator = new GraphIdGenerator();
  closeCalls: number = 0;

  constructor(profile?: Profile) {
    this.repository = new MemoryRepository(profile);
    this.contentStore = new MemoryContentStore();
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
  }
}

class RecordingNotification implements ContinuousNotificationPort {
  readonly log: string[];
  startError?: Error;
  stopError?: Error;

  constructor(log: string[]) {
    this.log = log;
  }

  async start(sessionId: string): Promise<void> {
    this.log.push(`notification.start:${sessionId}`);
    if (this.startError !== undefined) {
      throw this.startError;
    }
  }

  async stop(sessionId: string): Promise<void> {
    this.log.push(`notification.stop:${sessionId}`);
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
  }

  subscribeCancellation(_listener: (sessionId: string) => void): number {
    return 1;
  }

  unsubscribeCancellation(_subscriptionId: number): void {
  }
}

class GraphClock {
  now(): string {
    return '2026-08-16T12:00:00.000Z';
  }
}

class GraphIdGenerator {
  nextId(): string {
    return 'generated-id';
  }
}

class FakeCompositionRunner implements VpnExtensionCompositionRunner {
  startCalls: number = 0;
  stopCalls: number = 0;
  recordedFailures: VpnFailure[] = [];
  private resolveStartRef?: () => void;
  private readonly startGate: Promise<void>;

  constructor() {
    this.startGate = new Promise<void>((resolve) => {
      this.resolveStartRef = resolve;
    });
  }

  async start(_want: Want): Promise<void> {
    this.startCalls += 1;
    await this.startGate;
  }

  async stopForDestroy(): Promise<void> {
    this.stopCalls += 1;
  }

  async recordUnexpectedFailure(failure: VpnFailure): Promise<void> {
    this.recordedFailures.push(failure);
  }

  releaseStart(): void {
    this.resolveStartRef?.();
  }
}

class DeferredStopCompositionRunner implements VpnExtensionCompositionRunner {
  readonly contextTag: string;
  startCalls: number = 0;
  stopCalls: number = 0;
  recordedFailures: VpnFailure[] = [];
  private resolveStopRef?: () => void;
  private readonly stopGate: Promise<void>;

  constructor(contextTag: string) {
    this.contextTag = contextTag;
    this.stopGate = new Promise<void>((resolve) => {
      this.resolveStopRef = resolve;
    });
  }

  async start(_want: Want): Promise<void> {
    this.startCalls += 1;
  }

  async stopForDestroy(): Promise<void> {
    this.stopCalls += 1;
    await this.stopGate;
  }

  async recordUnexpectedFailure(failure: VpnFailure): Promise<void> {
    this.recordedFailures.push(failure);
  }

  releaseStop(): void {
    this.resolveStopRef?.();
  }
}

class FakeAbilityInfoRecord {
  bundleName: string;
  name: string;

  constructor(bundleName: string, name: string) {
    this.bundleName = bundleName;
    this.name = name;
  }
}

class FakeHapModuleInfoRecord {
  name: string;

  constructor(name: string) {
    this.name = name;
  }
}

class EmptyResourceManagerRecord {
}

class EmptyApplicationInfoRecord {
}

class EmptyConfigurationRecord {
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
  bundleName?: string;
  abilityName?: string;
  parameters?: Record<string, Object> | null;

  constructor(profileId: string, versionId: string, sessionId: string) {
    this.bundleName = 'com.github.kr328.clash.harmony';
    this.abilityName = 'CmfaVpnExtensionAbility';
    void profileId;
    void versionId;
    void sessionId;
    this.parameters = null;
  }
}

class RejectingCompositionRunner implements VpnExtensionCompositionRunner {
  readonly registry: VpnSessionRegistry;
  startCalls: number = 0;
  stopCalls: number = 0;
  recordedFailures: VpnFailure[] = [];
  startError: Error = new Error('raw ability start secret 77');

  constructor(registry: VpnSessionRegistry) {
    this.registry = registry;
  }

  async start(_want: Want): Promise<void> {
    this.startCalls += 1;
    throw this.startError;
  }

  async stopForDestroy(): Promise<void> {
    this.stopCalls += 1;
  }

  async recordUnexpectedFailure(failure: VpnFailure): Promise<void> {
    this.recordedFailures.push(failure);
    const sessionId: string | undefined = this.registry.currentSessionId();
    if (sessionId !== undefined) {
      this.registry.completeStop(sessionId, failure);
    }
  }
}

class RecordingPlatformPort implements VpnPlatformSessionPort {
  readonly log: string[];
  createError?: Error;
  protectProcessError?: Error;
  destroyError?: Error;
  nextHandle: TunHandle = createTunHandle(31, 'vpn-1', 'session-1');

  constructor(log: string[]) {
    this.log = log;
  }

  async protectProcess(): Promise<void> {
    this.log.push('platform.protectProcess');
    if (this.protectProcessError !== undefined) {
      throw this.protectProcessError;
    }
  }

  async create(_config: VpnCaptureConfig): Promise<TunHandle> {
    this.log.push(`platform.create:${this.nextHandle.sessionId}`);
    if (this.createError !== undefined) {
      throw this.createError;
    }
    return createTunHandle(this.nextHandle.fd, this.nextHandle.vpnId, this.nextHandle.sessionId);
  }

  async protectSocket(fd: number): Promise<void> {
    this.log.push(`platform.protectSocket:${fd}`);
  }

  async destroy(vpnId: string): Promise<void> {
    this.log.push(`platform.destroy:${vpnId}`);
    if (this.destroyError !== undefined) {
      throw this.destroyError;
    }
  }
}

class RecordingTunRuntime implements TunRuntimePort {
  readonly log: string[];
  startError?: Error;
  stopError?: Error;
  private readonly listeners: Map<number, (event: TunRuntimeEvent) => void> = new Map();
  private nextListenerId: number = 1;
  snapshotValue: TunRuntimeSnapshot = createTunRuntimeSnapshot({
    sessionId: 'session-1',
    state: 'READY',
    counters: createVpnCounters(0, 0, 0, 0),
    ingressTraces: [],
    failure: null
  });

  constructor(log: string[]) {
    this.log = log;
  }

  async start(handle: TunHandle, _options: TunStartOptions): Promise<TunRuntimeSnapshot> {
    this.log.push('core.runtime.create');
    this.log.push(`tun.start:${handle.sessionId}`);
    if (this.startError !== undefined) {
      throw this.startError;
    }
    return this.snapshot();
  }

  async stop(): Promise<void> {
    this.log.push('tun.stop');
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
  }

  async closeStaleOutboundConnections(sessionId: string): Promise<void> {
    this.log.push(`tun.closeStale:${sessionId}`);
  }

  async recover(sessionId: string): Promise<TunRuntimeSnapshot> {
    this.log.push(`tun.recover:${sessionId}`);
    return this.snapshot();
  }

  snapshot(): TunRuntimeSnapshot {
    return createTunRuntimeSnapshot({
      sessionId: this.snapshotValue.sessionId,
      state: this.snapshotValue.state,
      counters: this.snapshotValue.counters,
      ingressTraces: this.snapshotValue.ingressTraces,
      failure: this.snapshotValue.failure
    });
  }

  subscribe(listener: (event: TunRuntimeEvent) => void): number {
    const id: number = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(id, listener);
    return id;
  }

  unsubscribe(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }
}

class RecordingPlatformFactory {
  readonly graph: RecordingPlatformGraph;
  readonly notification: RecordingNotification;
  readonly networkRecovery: SilentNetworkRecovery = new SilentNetworkRecovery();
  readonly log: string[];

  constructor(log: string[], profile?: Profile) {
    this.log = log;
    this.graph = new RecordingPlatformGraph(profile);
    this.notification = new RecordingNotification(log);
  }

  async create(): Promise<PlatformGraph> {
    this.log.push('platform.adapters.graph');
    return this.graph;
  }

  async createNetworkRecoveryPort(): Promise<NetworkRecoveryPort> {
    this.log.push('platform.adapters.network');
    return this.networkRecovery;
  }

  createContinuousNotificationPort(): ContinuousNotificationPort {
    this.log.push('platform.adapters.notification');
    return this.notification;
  }
}

function buildProfile(profileId: string, versionId: string, availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID' = 'VALID'): Profile {
  return createProfile({
    id: profileId,
    name: `Profile ${profileId}`,
    sourceKind: 'REMOTE_URL',
    sourceDisplay: `https://${profileId}.example.com/subscription.yaml`,
    sourceSecretRef: `secret-${profileId}`,
    currentRevision: availability === 'INVALID'
      ? null
      : createProfileRevision(`profiles/${profileId}.yaml`, repeatDigest(profileId), 256, versionId),
    failedCandidate: null,
    availability,
    lastError: null,
    createdAt: '2026-08-16T12:00:00.000Z',
    updatedAt: '2026-08-16T12:00:00.000Z',
    lastSuccessfulUpdateAt: availability === 'INVALID' ? null : '2026-08-16T12:00:00.000Z'
  });
}

function repeatDigest(seed: string): string {
  let digest: string = '';
  while (digest.length < 64) {
    digest += seed;
  }
  return digest.substring(0, 64).replace(/[^0-9a-f]/gi, 'a');
}

function buildExactWant(profileId: string, versionId: string, sessionId: string): Want {
  return {
    bundleName: 'com.github.kr328.clash.harmony',
    abilityName: 'CmfaVpnExtensionAbility',
    parameters: {
      profileId,
      versionId,
      sessionId
    }
  };
}

function createDependencies(
  registry: VpnSessionRegistry,
  platformFactory: RecordingPlatformFactory,
  platformPort: RecordingPlatformPort,
  tunRuntime: RecordingTunRuntime
): VpnExtensionCompositionDependencies {
  return {
    registry,
    createPlatformFactory: (_context: common.VpnExtensionContext | undefined) => {
      return platformFactory;
    },
    createPlatformPort: (_sessionId: string) => {
      return platformPort;
    },
    createTunRuntime: (_configPath: string) => {
      return tunRuntime;
    },
    createCoordinator: (dependencies) => {
      return new VpnRuntimeCoordinator(dependencies);
    },
    createClock: () => {
      return new FixedClock();
    },
    createScheduler: () => {
      return new ImmediateScheduler();
    }
  };
}

async function waitForCondition(predicate: () => boolean, maxTurns: number = 20): Promise<void> {
  for (let turn = 0; turn < maxTurns; turn += 1) {
    if (predicate()) {
      return;
    }
    await Promise.resolve();
  }
  expect().assertFail();
}

async function settleMicrotasks(turns: number = 6): Promise<void> {
  for (let turn = 0; turn < turns; turn += 1) {
    await Promise.resolve();
  }
}

function assertSubsequence(actual: string[], expected: string[]): void {
  let actualIndex: number = 0;
  for (let expectedIndex = 0; expectedIndex < expected.length; expectedIndex += 1) {
    while (actualIndex < actual.length && actual[actualIndex] !== expected[expectedIndex]) {
      actualIndex += 1;
    }
    expect(actualIndex < actual.length).assertTrue();
    actualIndex += 1;
  }
}

export default function vpnExtensionCompositionTestsuite() {
  describe('VpnExtensionCompositionTest', () => {
    it('startsWithTheExactCommittedVersionAndFollowsCoordinatorOrder', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const platformPort = new RecordingPlatformPort(log);
      const tunRuntime = new RecordingTunRuntime(log);
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(registry, platformFactory, platformPort, tunRuntime)
      );

      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      assertSubsequence(log, [
        'platform.adapters.graph',
        'platform.adapters.network',
        'platform.adapters.notification',
        'platform.protectProcess',
        'platform.create:session-1',
        'core.runtime.create',
        'tun.start:session-1',
        'notification.start:session-1'
      ]);
      expect(registry.snapshot().state).assertEqual('RUNNING');
      expect(registry.snapshot().lastFailure).assertNull();
    });

    it('failsClosedForMalformedAndStaleWants', 0, async () => {
      const missingRegistry = new VpnSessionRegistry();
      const missingLog: string[] = [];
      const missingFactory = new RecordingPlatformFactory(missingLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const missingComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(missingRegistry, missingFactory, new RecordingPlatformPort(missingLog), new RecordingTunRuntime(missingLog))
      );

      await missingComposition.start({
        bundleName: 'com.github.kr328.clash.harmony',
        abilityName: 'CmfaVpnExtensionAbility',
        parameters: {
          profileId: 'profile-1',
          sessionId: 'session-1'
        }
      });
      expect(missingLog.length).assertEqual(0);
      expect(missingRegistry.snapshot().state).assertEqual('STOPPED');

      const extraRegistry = new VpnSessionRegistry();
      extraRegistry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const extraLog: string[] = [];
      const extraComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(extraRegistry, new RecordingPlatformFactory(extraLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z')), new RecordingPlatformPort(extraLog), new RecordingTunRuntime(extraLog))
      );

      await extraComposition.start({
        bundleName: 'com.github.kr328.clash.harmony',
        abilityName: 'CmfaVpnExtensionAbility',
        parameters: {
          profileId: 'profile-1',
          versionId: '2026-08-16T12:00:00.000Z',
          sessionId: 'session-1',
          extra: 'unexpected'
        }
      });
      expect(extraLog.length).assertEqual(0);
      expect(extraRegistry.snapshot().state).assertEqual('STOPPED');
      expect(extraRegistry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_CONFIG_INVALID');

      const nullRegistry = new VpnSessionRegistry();
      nullRegistry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const nullLog: string[] = [];
      const nullComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(nullRegistry, new RecordingPlatformFactory(nullLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z')), new RecordingPlatformPort(nullLog), new RecordingTunRuntime(nullLog))
      );

      await nullComposition.start(new NullParametersWantRecord('profile-1', '2026-08-16T12:00:00.000Z', 'session-1') as Want);
      expect(nullLog.length).assertEqual(0);
      expect(nullRegistry.snapshot().state).assertEqual('STOPPED');
      expect(nullRegistry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_CONFIG_INVALID');

      const staleRegistry = new VpnSessionRegistry();
      staleRegistry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-live'
      });
      const staleLog: string[] = [];
      const staleComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(staleRegistry, new RecordingPlatformFactory(staleLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z')), new RecordingPlatformPort(staleLog), new RecordingTunRuntime(staleLog))
      );

      await staleComposition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-stale'));
      expect(staleLog.length).assertEqual(0);
      expect(staleRegistry.snapshot().state).assertEqual('AWAITING_CONSENT');
    });

    it('reversesCleanupAndPublishesRedactedFailureWhenInjectedStartStepsFail', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      platformFactory.notification.startError = new Error('raw notification secret 55');
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(registry, platformFactory, new RecordingPlatformPort(log), new RecordingTunRuntime(log))
      );

      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      assertSubsequence(log, [
        'platform.protectProcess',
        'platform.create:session-1',
        'core.runtime.create',
        'tun.start:session-1',
        'notification.start:session-1',
        'tun.stop',
        'platform.destroy:vpn-1',
        'notification.stop:session-1'
      ]);
      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(registry.snapshot().lastFailure?.detail.includes('raw notification secret 55') ?? false).assertFalse();
    });

    it('usesTheSameCleanupSequenceForUserRequestedAndSystemDestroy', 0, async () => {
      const firstRegistry = new VpnSessionRegistry();
      firstRegistry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const firstLog: string[] = [];
      const firstComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(firstRegistry, new RecordingPlatformFactory(firstLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z')), new RecordingPlatformPort(firstLog), new RecordingTunRuntime(firstLog))
      );
      await firstComposition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));
      firstRegistry.markUserStopRequested('session-1');

      firstLog.length = 0;
      await firstComposition.stopForDestroy();
      const userSequence: string = firstLog.join('>');

      const secondRegistry = new VpnSessionRegistry();
      secondRegistry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const secondLog: string[] = [];
      const secondComposition = new VpnExtensionComposition(
        undefined,
        createDependencies(secondRegistry, new RecordingPlatformFactory(secondLog, buildProfile('profile-1', '2026-08-16T12:00:00.000Z')), new RecordingPlatformPort(secondLog), new RecordingTunRuntime(secondLog))
      );
      await secondComposition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      secondLog.length = 0;
      await secondComposition.stopForDestroy();
      const systemSequence: string = secondLog.join('>');

      expect(userSequence).assertEqual(systemSequence);
      expect(firstRegistry.snapshot().lastFailure).assertNull();
      expect(secondRegistry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_SYSTEM_REVOKED');
    });

    it('keepsRedactedStopCleanupFailureInsteadOfOverwritingItDuringDestroy', 0, async () => {
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const log: string[] = [];
      const platformFactory = new RecordingPlatformFactory(log, buildProfile('profile-1', '2026-08-16T12:00:00.000Z'));
      const platformPort = new RecordingPlatformPort(log);
      const tunRuntime = new RecordingTunRuntime(log);
      tunRuntime.stopError = new Error('raw tun stop secret 88');
      platformPort.destroyError = new Error('raw platform destroy secret 99');
      platformFactory.notification.stopError = new Error('raw notification stop secret 111');
      const composition = new VpnExtensionComposition(
        undefined,
        createDependencies(registry, platformFactory, platformPort, tunRuntime)
      );

      await composition.start(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));
      log.length = 0;

      await composition.stopForDestroy();

      assertSubsequence(log, [
        'tun.stop',
        'platform.destroy:vpn-1',
        'notification.stop:session-1'
      ]);
      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_STOP_FAILED');
      expect(registry.snapshot().lastFailure?.detail.includes('raw tun stop secret 88') ?? false).assertFalse();
      expect(registry.snapshot().lastFailure?.detail.includes('raw platform destroy secret 99') ?? false).assertFalse();
      expect(registry.snapshot().lastFailure?.detail.includes('raw notification stop secret 111') ?? false).assertFalse();
    });

    it('abilityStartsOnlyOneCompositionAndAwaitsStopUntilStartSettles', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const fakeRunner = new FakeCompositionRunner();
      installVpnExtensionCompositionFactoryForTesting((_context) => {
        return fakeRunner;
      });

      const ability = new CmfaVpnExtensionAbility();
      const want = buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1');

      ability.onCreate(want);
      ability.onCreate(want);
      expect(fakeRunner.startCalls).assertEqual(1);

      ability.onDestroy();
      expect(fakeRunner.stopCalls).assertEqual(0);

      fakeRunner.releaseStart();
      await waitForCondition(() => fakeRunner.stopCalls === 1);
      resetVpnExtensionCompositionForTesting();
    });

    it('abilityRecordsUnexpectedOnCreateRejectionsThroughTheRunnerSurface', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const registry = new VpnSessionRegistry();
      registry.beginPending({
        profileId: 'profile-1',
        versionId: '2026-08-16T12:00:00.000Z',
        sessionId: 'session-1'
      });
      const fakeRunner = new RejectingCompositionRunner(registry);
      installVpnExtensionCompositionFactoryForTesting((_context) => {
        return fakeRunner;
      });

      const ability = new CmfaVpnExtensionAbility();
      const want = buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1');

      ability.onCreate(want);

      await waitForCondition(() => fakeRunner.recordedFailures.length === 1);
      expect(fakeRunner.startCalls).assertEqual(1);
      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_CREATE_FAILED');
      expect(registry.snapshot().lastFailure?.detail.includes('raw ability start secret 77') ?? false).assertFalse();
      resetVpnExtensionCompositionForTesting();
    });

    it('doesNotCreateAFreshCompositionDuringCleanupAndOnlyCreatesOneAfterCleanupSettles', 0, async () => {
      resetVpnExtensionCompositionForTesting();
      const runnerByTag: Map<string, DeferredStopCompositionRunner> = new Map();
      const createdTags: string[] = [];
      installVpnExtensionCompositionFactoryForTesting((context) => {
        const tag: string = (context?.extensionAbilityInfo.name ?? 'missing') as string;
        createdTags.push(tag);
        const runner = new DeferredStopCompositionRunner(tag);
        runnerByTag.set(tag, runner);
        return runner;
      });

      const firstAbility = new CmfaVpnExtensionAbility();
      firstAbility.context = new FakeVpnExtensionContextRecord('first') as common.VpnExtensionContext;
      firstAbility.onCreate(buildExactWant('profile-1', '2026-08-16T12:00:00.000Z', 'session-1'));

      const firstRunner = runnerByTag.get('first');
      expect(firstRunner !== undefined).assertTrue();
      firstAbility.onDestroy();
      await waitForCondition(() => (firstRunner?.stopCalls ?? 0) === 1);

      const secondAbility = new CmfaVpnExtensionAbility();
      secondAbility.context = new FakeVpnExtensionContextRecord('second') as common.VpnExtensionContext;
      secondAbility.onCreate(buildExactWant('profile-2', '2026-08-16T12:00:00.000Z', 'session-2'));

      expect(createdTags.join('>')).assertEqual('first');
      expect(firstRunner?.startCalls ?? 0).assertEqual(1);

      firstRunner?.releaseStop();
      await settleMicrotasks();

      const thirdAbility = new CmfaVpnExtensionAbility();
      thirdAbility.context = new FakeVpnExtensionContextRecord('second') as common.VpnExtensionContext;
      thirdAbility.onCreate(buildExactWant('profile-2', '2026-08-16T12:00:00.000Z', 'session-2'));

      const secondRunner = runnerByTag.get('second');
      expect(secondRunner !== undefined).assertTrue();
      expect(createdTags.join('>')).assertEqual('first>second');
      expect(secondRunner?.startCalls ?? 0).assertEqual(1);

      thirdAbility.onDestroy();
      await waitForCondition(() => (secondRunner?.stopCalls ?? 0) === 1);
      secondRunner?.releaseStop();
      resetVpnExtensionCompositionForTesting();
    });
  });
}
