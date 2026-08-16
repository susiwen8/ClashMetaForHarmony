import { describe, expect, it } from '@ohos/hypium';
import {
  ContinuousNotificationPortError,
  TunRuntimePortError,
  VpnRuntimeCoordinator,
  VpnPlatformPortError,
  createTunHandle,
  createTunRuntimeFailure,
  createTunRuntimeSnapshot,
  createVpnCaptureConfig,
  createVpnIngressTrace
} from '../../Index';
import { createDeferred } from './fakes/ProfileFakes';
import type {
  BoundedDelaySchedulerPort,
  CancelableDelayTask,
  ClockPort,
  CommittedProfileResolverPort,
  ContinuousNotificationPort,
  ContinuousNotificationStopErrorCode,
  NetworkRecoveryPort,
  NetworkStatus,
  TunHandle,
  TunRuntimeEvent,
  TunRuntimePort,
  TunRuntimeSnapshot,
  TunStartOptions,
  VpnCaptureConfig,
  VpnControllerStartResult,
  VpnControllerStopResult,
  VpnPlatformErrorCode,
  VpnPlatformSessionPort,
  VpnRuntimeCoordinatorDependencies
} from '../../Index';

class FakeClock implements ClockPort {
  private readonly values: number[];
  private index: number = 0;

  constructor(values: number[]) {
    this.values = values.slice();
  }

  nowMs(): number {
    const safeIndex: number = Math.min(this.index, this.values.length - 1);
    const value: number = this.values[safeIndex];
    this.index += 1;
    return value;
  }
}

class FakeResolver implements CommittedProfileResolverPort {
  readonly calls: string[] = [];
  config: VpnCaptureConfig = buildExactCaptureConfig();
  resolveError?: Error;
  resolveGate = createDeferred<void>();
  useDeferredResolve: boolean = false;

  async resolve(profileId: string, versionId: string): Promise<VpnCaptureConfig> {
    this.calls.push(`${profileId}:${versionId}`);
    if (this.useDeferredResolve) {
      await this.resolveGate.promise;
    }
    if (this.resolveError !== undefined) {
      throw this.resolveError;
    }
    return this.config;
  }
}

class FakePlatform implements VpnPlatformSessionPort {
  readonly log: string[] = [];
  protectProcessError?: Error;
  createError?: Error;
  destroyError?: Error;
  nextHandle: TunHandle = createTunHandle(31, 'vpn-1', 'session-1');
  createGate = createDeferred<void>();
  useDeferredCreate: boolean = false;

  async create(_config: VpnCaptureConfig): Promise<TunHandle> {
    this.log.push(`platform.create:${this.nextHandle.sessionId}`);
    if (this.useDeferredCreate) {
      await this.createGate.promise;
    }
    if (this.createError !== undefined) {
      throw this.createError;
    }
    return createTunHandle(this.nextHandle.fd, this.nextHandle.vpnId, this.nextHandle.sessionId);
  }

  async protectProcess(): Promise<void> {
    this.log.push('platform.protectProcess');
    if (this.protectProcessError !== undefined) {
      throw this.protectProcessError;
    }
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

class FakeTunRuntime implements TunRuntimePort {
  readonly log: string[] = [];
  readonly startCalls: string[] = [];
  readonly stopCalls: number[] = [];
  readonly closeStaleCalls: string[] = [];
  readonly recoverCalls: string[] = [];
  private readonly listeners: Map<number, (event: TunRuntimeEvent) => void> = new Map();
  private nextListenerId: number = 1;
  snapshotValue: TunRuntimeSnapshot = buildTunSnapshot('session-1', 'IDLE');
  recoverSnapshotValue: TunRuntimeSnapshot = buildTunSnapshot('session-1', 'READY');
  startError?: Error;
  startPortError?: TunRuntimePortError;
  stopError?: Error;
  closeStaleError?: TunRuntimePortError;
  recoverPortError?: TunRuntimePortError;
  recoverError?: Error;
  startDeferred = createDeferred<TunRuntimeSnapshot>();
  recoverDeferred = createDeferred<TunRuntimeSnapshot>();
  useDeferredStart: boolean = false;
  useDeferredRecover: boolean = false;

  async start(handle: TunHandle, _options: TunStartOptions): Promise<TunRuntimeSnapshot> {
    this.log.push(`tun.start:${handle.sessionId}`);
    this.startCalls.push(handle.sessionId);
    if (this.startPortError !== undefined) {
      throw this.startPortError;
    }
    if (this.startError !== undefined) {
      throw this.startError;
    }
    if (this.useDeferredStart) {
      return await this.startDeferred.promise;
    }
    return cloneTunSnapshot(this.snapshotValue);
  }

  async stop(): Promise<void> {
    this.log.push('tun.stop');
    this.stopCalls.push(this.stopCalls.length + 1);
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
  }

  snapshot(): TunRuntimeSnapshot {
    return cloneTunSnapshot(this.snapshotValue);
  }

  async closeStaleOutboundConnections(sessionId: string): Promise<void> {
    this.log.push(`tun.closeStale:${sessionId}`);
    this.closeStaleCalls.push(sessionId);
    if (this.closeStaleError !== undefined) {
      throw this.closeStaleError;
    }
  }

  async recover(sessionId: string): Promise<TunRuntimeSnapshot> {
    this.log.push(`tun.recover:${sessionId}`);
    this.recoverCalls.push(sessionId);
    if (this.recoverPortError !== undefined) {
      throw this.recoverPortError;
    }
    if (this.recoverError !== undefined) {
      throw this.recoverError;
    }
    if (this.useDeferredRecover) {
      return await this.recoverDeferred.promise;
    }
    return cloneTunSnapshot(this.recoverSnapshotValue);
  }

  subscribe(listener: (event: TunRuntimeEvent) => void): number {
    const subscriptionId: number = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }

  emit(snapshot: TunRuntimeSnapshot): void {
    const listeners: Array<(event: TunRuntimeEvent) => void> = [];
    this.listeners.forEach((listener) => {
      listeners.push(listener);
    });
    for (let index = 0; index < listeners.length; index += 1) {
      listeners[index]({
        sessionId: snapshot.sessionId,
        snapshot: cloneTunSnapshot(snapshot)
      });
    }
  }
}

class FakeNetworkRecovery implements NetworkRecoveryPort {
  private readonly listeners: Map<number, (status: NetworkStatus) => void> = new Map();
  private nextListenerId: number = 1;
  status: NetworkStatus = { usable: false, networkId: '' };
  currentNetworkCalls: number = 0;

  currentNetwork(): NetworkStatus {
    this.currentNetworkCalls += 1;
    return {
      usable: this.status.usable,
      networkId: this.status.networkId
    };
  }

  subscribeUsableNetwork(listener: (status: NetworkStatus) => void): number {
    const subscriptionId: number = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribeUsableNetwork(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }

  emitUsable(networkId: string): void {
    this.status = { usable: true, networkId };
    const listeners: Array<(status: NetworkStatus) => void> = [];
    this.listeners.forEach((listener) => {
      listeners.push(listener);
    });
    for (let index = 0; index < listeners.length; index += 1) {
      listeners[index](this.currentNetwork());
    }
  }
}

class FakeNotification implements ContinuousNotificationPort {
  readonly log: string[] = [];
  readonly stopCalls: string[] = [];
  startError?: Error;
  stopError?: Error;
  private readonly listeners: Map<number, (sessionId: string) => void> = new Map();
  private nextListenerId: number = 1;

  async start(sessionId: string): Promise<void> {
    this.log.push(`notification.start:${sessionId}`);
    if (this.startError !== undefined) {
      throw this.startError;
    }
  }

  async stop(sessionId: string): Promise<void> {
    this.log.push(`notification.stop:${sessionId}`);
    this.stopCalls.push(sessionId);
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
  }

  subscribeCancellation(listener: (sessionId: string) => void): number {
    const subscriptionId: number = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribeCancellation(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }

  emitCancellation(sessionId: string): void {
    const listeners: Array<(sessionId: string) => void> = [];
    this.listeners.forEach((listener) => {
      listeners.push(listener);
    });
    for (let index = 0; index < listeners.length; index += 1) {
      listeners[index](sessionId);
    }
  }
}

class FakeDelayTask implements CancelableDelayTask {
  readonly delayMs: number;
  private readonly runner: () => Promise<void>;
  cancelled: boolean = false;

  constructor(delayMs: number, runner: () => Promise<void>) {
    this.delayMs = delayMs;
    this.runner = runner;
  }

  cancel(): void {
    this.cancelled = true;
  }

  async run(): Promise<void> {
    if (this.cancelled) {
      return;
    }
    await this.runner();
  }
}

class FakeScheduler implements BoundedDelaySchedulerPort {
  readonly delays: number[] = [];
  readonly tasks: FakeDelayTask[] = [];

  schedule(delayMs: number, runner: () => Promise<void>): CancelableDelayTask {
    this.delays.push(delayMs);
    const task: FakeDelayTask = new FakeDelayTask(delayMs, runner);
    this.tasks.push(task);
    return task;
  }

  latest(): FakeDelayTask {
    return this.tasks[this.tasks.length - 1];
  }
}

class DependencyBag implements VpnRuntimeCoordinatorDependencies {
  readonly resolver: FakeResolver;
  readonly platform: FakePlatform;
  readonly tunRuntime: FakeTunRuntime;
  readonly networkRecovery: FakeNetworkRecovery;
  readonly notification: FakeNotification;
  readonly scheduler: FakeScheduler;
  readonly clock: FakeClock;

  constructor(
    resolver: FakeResolver,
    platform: FakePlatform,
    tunRuntime: FakeTunRuntime,
    networkRecovery: FakeNetworkRecovery,
    notification: FakeNotification,
    scheduler: FakeScheduler,
    clock: FakeClock
  ) {
    this.resolver = resolver;
    this.platform = platform;
    this.tunRuntime = tunRuntime;
    this.networkRecovery = networkRecovery;
    this.notification = notification;
    this.scheduler = scheduler;
    this.clock = clock;
  }
}

function buildExactCaptureConfig(): VpnCaptureConfig {
  return createVpnCaptureConfig({
    addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
    routes: ['0.0.0.0/0', '::/0'],
    dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
    mtu: 1500,
    ipv4: true,
    ipv6: true,
    isBlocking: false,
    blockedApplications: ['com.github.kr328.clash.harmony'],
    trustedApplications: []
  });
}

function buildTunSnapshot(sessionId: string, state: 'IDLE' | 'STARTING' | 'READY' | 'STOPPED' | 'ERROR', code?: string): TunRuntimeSnapshot {
  return createTunRuntimeSnapshot({
    sessionId,
    state,
    counters: {
      txPackets: 0,
      txBytes: 0,
      rxPackets: 0,
      rxBytes: 0
    },
    ingressTraces: [
      createVpnIngressTrace({
        sessionId,
        stage: state === 'ERROR' ? 'TUN_ERROR' : 'TUN_READY',
        detail: state.toLowerCase(),
        atMs: 10
      })
    ],
    failure: code === undefined ? null : createTunRuntimeFailure(code, `failure:${code} vpnId=vpn-1`)
  });
}

function cloneTunSnapshot(snapshot: TunRuntimeSnapshot): TunRuntimeSnapshot {
  return createTunRuntimeSnapshot({
    sessionId: snapshot.sessionId,
    state: snapshot.state,
    counters: snapshot.counters,
    ingressTraces: snapshot.ingressTraces,
    failure: snapshot.failure
  });
}

function createCoordinator(
  resolver: FakeResolver,
  platform: FakePlatform,
  tunRuntime: FakeTunRuntime,
  networkRecovery: FakeNetworkRecovery,
  notification: FakeNotification,
  scheduler: FakeScheduler,
  times: number[]
): VpnRuntimeCoordinator {
  return new VpnRuntimeCoordinator(
    new DependencyBag(
      resolver,
      platform,
      tunRuntime,
      networkRecovery,
      notification,
      scheduler,
      new FakeClock(times)
    )
  );
}

function buildPlatformError(code: VpnPlatformErrorCode, detail: string): Error {
  return new VpnPlatformPortError(code, detail);
}

function buildNotificationStopError(code: ContinuousNotificationStopErrorCode, detail: string): Error {
  return new ContinuousNotificationPortError(code, detail);
}

async function waitForCondition(predicate: () => boolean, maxTurns: number = 12): Promise<void> {
  for (let turn = 0; turn < maxTurns; turn += 1) {
    if (predicate()) {
      return;
    }
    await Promise.resolve();
  }
  throw new Error('Condition was not satisfied within bounded microtask turns.');
}

async function settleMicrotasks(turns: number = 6): Promise<void> {
  for (let turn = 0; turn < turns; turn += 1) {
    await Promise.resolve();
  }
}

function captureEventStates(coordinator: VpnRuntimeCoordinator): string[] {
  const states: string[] = [];
  coordinator.subscribe((event) => {
    states.push(event.snapshot.state);
  });
  return states;
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

function countArrayEntry(values: string[], expectedValue: string): number {
  let count: number = 0;
  for (let index = 0; index < values.length; index += 1) {
    if (values[index] === expectedValue) {
      count += 1;
    }
  }
  return count;
}

export default function vpnRuntimeCoordinatorTestsuite() {
  describe('VpnRuntimeCoordinatorTest', () => {
    it('startsInHappyPathOrderAndProtectsProcessBeforeCreateAndTunStart', 0, async () => {
      const resolver = new FakeResolver();
      const platform = new FakePlatform();
      platform.nextHandle = createTunHandle(31, 'vpn-1', 'session-1');
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      const notification = new FakeNotification();
      const scheduler = new FakeScheduler();
      const coordinator = createCoordinator(
        resolver,
        platform,
        tunRuntime,
        new FakeNetworkRecovery(),
        notification,
        scheduler,
        [1, 2, 3, 4]
      );

      const result: VpnControllerStartResult = await coordinator.start('profile-1', 'version-1', 'session-1');

      expect(result.kind).assertEqual('STARTED');
      expect(resolver.calls.join('>')).assertEqual('profile-1:version-1');
      expect(platform.log.join('>')).assertEqual('platform.protectProcess>platform.create:session-1');
      expect(tunRuntime.log.join('>')).assertEqual('tun.start:session-1');
      expect(notification.log.join('>')).assertEqual('notification.start:session-1');
      expect(coordinator.snapshot().state).assertEqual('RUNNING');
    });

    it('becomesRunningOnlyAfterTunReadinessAndNotificationStart', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'STARTING');
      const coordinator = createCoordinator(
        new FakeResolver(),
        new FakePlatform(),
        tunRuntime,
        new FakeNetworkRecovery(),
        new FakeNotification(),
        new FakeScheduler(),
        [11, 12, 13, 14]
      );

      const startPromise: Promise<VpnControllerStartResult> = coordinator.start('profile-1', 'version-1', 'session-1');

      expect(coordinator.snapshot().state).assertEqual('STARTING');
      await waitForCondition(() => tunRuntime.startCalls.length === 1);
      tunRuntime.emit(buildTunSnapshot('session-1', 'READY'));
      const result: VpnControllerStartResult = await startPromise;

      expect(result.kind).assertEqual('STARTED');
      expect(coordinator.snapshot().state).assertEqual('RUNNING');
    });

    it('rejectsDuplicateStartAndResolvesTheExactRequestedVersionOnlyOnce', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'STARTING');
      const resolver = new FakeResolver();
      const coordinator = createCoordinator(
        resolver,
        new FakePlatform(),
        tunRuntime,
        new FakeNetworkRecovery(),
        new FakeNotification(),
        new FakeScheduler(),
        [21, 22, 23, 24, 25]
      );

      const first: Promise<VpnControllerStartResult> = coordinator.start('profile-1', 'version-1', 'session-1');
      const second: VpnControllerStartResult = await coordinator.start('profile-1', 'version-2', 'session-2');
      await waitForCondition(() => tunRuntime.startCalls.length === 1);
      tunRuntime.emit(buildTunSnapshot('session-1', 'READY'));
      const firstResult: VpnControllerStartResult = await first;

      expect(second.kind).assertEqual('REJECTED');
      expect(firstResult.kind).assertEqual('STARTED');
      expect(resolver.calls.join('>')).assertEqual('profile-1:version-1');
    });

    it('acceptsStopWhileStartingAndKeepsRepeatedStopIdempotent', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'STARTING');
      const platform = new FakePlatform();
      platform.nextHandle = createTunHandle(31, 'vpn-1', 'session-1');
      const notification = new FakeNotification();
      const coordinator = createCoordinator(
        new FakeResolver(),
        platform,
        tunRuntime,
        new FakeNetworkRecovery(),
        notification,
        new FakeScheduler(),
        [31, 32, 33, 34, 35, 36]
      );

      const startPromise: Promise<VpnControllerStartResult> = coordinator.start('profile-1', 'version-1', 'session-1');
      await waitForCondition(() => tunRuntime.startCalls.length === 1);
      const firstStop: Promise<VpnControllerStopResult> = coordinator.stop();
      tunRuntime.emit(buildTunSnapshot('session-1', 'READY'));
      const started: VpnControllerStartResult = await startPromise;
      const stopped: VpnControllerStopResult = await firstStop;
      const secondStop: VpnControllerStopResult = await coordinator.stop();

      expect(started.kind).assertEqual('STOPPED');
      expect(stopped.kind).assertEqual('STOPPED');
      expect(secondStop.kind).assertEqual('STOPPED');
      expect(tunRuntime.stopCalls.length).assertEqual(1);
      expect(platform.log.includes('platform.destroy:vpn-1')).assertTrue();
      expect(notification.stopCalls.join('>')).assertEqual('session-1');
      expect(coordinator.snapshot().state).assertEqual('STOPPED');
    });

    it('settlesStopWhileAwaitingReadyWithoutRequiringALaterTunEvent', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'STARTING');
      const platform = new FakePlatform();
      const notification = new FakeNotification();
      const coordinator = createCoordinator(
        new FakeResolver(),
        platform,
        tunRuntime,
        new FakeNetworkRecovery(),
        notification,
        new FakeScheduler(),
        [37, 38, 39, 40]
      );
      let startSettled: boolean = false;
      let stopSettled: boolean = false;

      const startPromise: Promise<VpnControllerStartResult> = coordinator.start('profile-1', 'version-1', 'session-1').then((result) => {
        startSettled = true;
        return result;
      });
      await waitForCondition(() => tunRuntime.startCalls.length === 1);
      const stopPromise: Promise<VpnControllerStopResult> = coordinator.stop().then((result) => {
        stopSettled = true;
        return result;
      });
      await waitForCondition(() => startSettled && stopSettled);
      const startResult: VpnControllerStartResult = await startPromise;
      const stopResult: VpnControllerStopResult = await stopPromise;

      expect(startSettled).assertTrue();
      expect(stopSettled).assertTrue();
      expect(startResult.kind).assertEqual('STOPPED');
      expect(stopResult.kind).assertEqual('STOPPED');
      expect(tunRuntime.stopCalls.length).assertEqual(1);
      expect(countArrayEntry(platform.log, 'platform.destroy:vpn-1')).assertEqual(1);
      expect(notification.stopCalls.length).assertEqual(1);
    });

    it('reversesCleanupWithoutSkippingLaterStepsAcrossPartialStartFailures', 0, async () => {
      const processPlatform = new FakePlatform();
      processPlatform.protectProcessError = new Error('protect failed');
      const processResult = await createCoordinator(
        new FakeResolver(),
        processPlatform,
        new FakeTunRuntime(),
        new FakeNetworkRecovery(),
        new FakeNotification(),
        new FakeScheduler(),
        [41, 42, 43]
      ).start('profile-1', 'version-1', 'session-1');
      expect(processResult.kind).assertEqual('FAILED');

      const tunPlatform = new FakePlatform();
      tunPlatform.nextHandle = createTunHandle(31, 'vpn-1', 'session-1');
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.startError = new Error('tun failed');
      const tunNotification = new FakeNotification();
      const tunResult = await createCoordinator(
        new FakeResolver(),
        tunPlatform,
        tunRuntime,
        new FakeNetworkRecovery(),
        tunNotification,
        new FakeScheduler(),
        [44, 45, 46, 47]
      ).start('profile-1', 'version-1', 'session-1');
      expect(tunResult.kind).assertEqual('FAILED');
      expect(`${tunRuntime.log.join('>')}>${tunPlatform.log.join('>')}>${tunNotification.log.join('>')}`).assertContain('tun.stop');
      expect(tunPlatform.log.join('>')).assertContain('platform.destroy:vpn-1');

      const notificationPlatform = new FakePlatform();
      notificationPlatform.nextHandle = createTunHandle(31, 'vpn-1', 'session-1');
      const notificationTun = new FakeTunRuntime();
      notificationTun.snapshotValue = buildTunSnapshot('session-1', 'READY');
      const notification = new FakeNotification();
      notification.startError = new Error('notification failed');
      notification.stopError = buildNotificationStopError('NOTIFICATION_STOP_FAILED', 'stop still fails');
      const notificationResult = await createCoordinator(
        new FakeResolver(),
        notificationPlatform,
        notificationTun,
        new FakeNetworkRecovery(),
        notification,
        new FakeScheduler(),
        [48, 49, 50, 51]
      ).start('profile-1', 'version-1', 'session-1');
      expect(notificationResult.kind).assertEqual('FAILED');
      expect(notificationTun.log.join('>')).assertEqual('tun.start:session-1>tun.stop');
      expect(notificationPlatform.log.join('>')).assertContain('platform.destroy:vpn-1');
      expect(notification.log.join('>')).assertEqual('notification.start:session-1>notification.stop:session-1');
    });

    it('settlesStopWhenResolverFailureArrivesAfterStopWasRequested', 0, async () => {
      const resolver = new FakeResolver();
      resolver.useDeferredResolve = true;
      const tunRuntime = new FakeTunRuntime();
      const platform = new FakePlatform();
      const notification = new FakeNotification();
      const coordinator = createCoordinator(
        resolver,
        platform,
        tunRuntime,
        new FakeNetworkRecovery(),
        notification,
        new FakeScheduler(),
        [52, 53, 54, 55]
      );
      let startSettled: boolean = false;
      let stopSettled: boolean = false;

      const startPromise: Promise<VpnControllerStartResult> = coordinator.start('profile-1', 'version-1', 'session-1').then((result) => {
        startSettled = true;
        return result;
      });
      const stopPromise: Promise<VpnControllerStopResult> = coordinator.stop().then((result) => {
        stopSettled = true;
        return result;
      });
      resolver.resolveError = new Error('resolve failed');
      resolver.resolveGate.resolve(undefined);
      await waitForCondition(() => startSettled && stopSettled);
      const startResult: VpnControllerStartResult = await startPromise;
      const stopResult: VpnControllerStopResult = await stopPromise;

      expect(startResult.kind).assertEqual('FAILED');
      expect(stopResult.kind).assertEqual('STOPPED');
      expect(tunRuntime.stopCalls.length).assertEqual(0);
      expect(countArrayEntry(platform.log, 'platform.destroy:vpn-1')).assertEqual(0);
      expect(notification.stopCalls.length).assertEqual(0);
      expect(coordinator.snapshot().state).assertEqual('STOPPED');
    });

    it('settlesStopWhenCreateFailureArrivesAfterStopWasRequested', 0, async () => {
      const resolver = new FakeResolver();
      const platform = new FakePlatform();
      platform.useDeferredCreate = true;
      const tunRuntime = new FakeTunRuntime();
      const notification = new FakeNotification();
      const coordinator = createCoordinator(
        resolver,
        platform,
        tunRuntime,
        new FakeNetworkRecovery(),
        notification,
        new FakeScheduler(),
        [56, 57, 58, 59]
      );
      let startSettled: boolean = false;
      let stopSettled: boolean = false;

      const startPromise: Promise<VpnControllerStartResult> = coordinator.start('profile-1', 'version-1', 'session-1').then((result) => {
        startSettled = true;
        return result;
      });
      await waitForCondition(() => platform.log.includes('platform.create:session-1'));
      const stopPromise: Promise<VpnControllerStopResult> = coordinator.stop().then((result) => {
        stopSettled = true;
        return result;
      });
      platform.createError = new Error('create failed');
      platform.createGate.resolve(undefined);
      await waitForCondition(() => startSettled && stopSettled);
      const startResult: VpnControllerStartResult = await startPromise;
      const stopResult: VpnControllerStopResult = await stopPromise;

      expect(startResult.kind).assertEqual('FAILED');
      expect(stopResult.kind).assertEqual('STOPPED');
      expect(tunRuntime.stopCalls.length).assertEqual(0);
      expect(countArrayEntry(platform.log, 'platform.destroy:vpn-1')).assertEqual(0);
      expect(notification.stopCalls.length).assertEqual(0);
      expect(coordinator.snapshot().state).assertEqual('STOPPED');
    });

    it('settlesStopWhenConsentDenialArrivesAfterStopWasRequested', 0, async () => {
      const resolver = new FakeResolver();
      const platform = new FakePlatform();
      platform.useDeferredCreate = true;
      const tunRuntime = new FakeTunRuntime();
      const notification = new FakeNotification();
      const coordinator = createCoordinator(
        resolver,
        platform,
        tunRuntime,
        new FakeNetworkRecovery(),
        notification,
        new FakeScheduler(),
        [60, 61, 62, 63]
      );
      let startSettled: boolean = false;
      let stopSettled: boolean = false;

      const startPromise: Promise<VpnControllerStartResult> = coordinator.start('profile-1', 'version-1', 'session-1').then((result) => {
        startSettled = true;
        return result;
      });
      await waitForCondition(() => platform.log.includes('platform.create:session-1'));
      const stopPromise: Promise<VpnControllerStopResult> = coordinator.stop().then((result) => {
        stopSettled = true;
        return result;
      });
      platform.createError = buildPlatformError('CONSENT_DENIED', 'denied');
      platform.createGate.resolve(undefined);
      await waitForCondition(() => startSettled && stopSettled);
      const startResult: VpnControllerStartResult = await startPromise;
      const stopResult: VpnControllerStopResult = await stopPromise;

      expect(startResult.kind).assertEqual('STOPPED');
      expect(stopResult.kind).assertEqual('STOPPED');
      expect(tunRuntime.stopCalls.length).assertEqual(0);
      expect(countArrayEntry(platform.log, 'platform.destroy:vpn-1')).assertEqual(0);
      expect(notification.stopCalls.length).assertEqual(0);
      expect(coordinator.snapshot().state).assertEqual('STOPPED');
    });

    it('ignoresLateEventsFromOldSessions', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      const coordinator = createCoordinator(
        new FakeResolver(),
        new FakePlatform(),
        tunRuntime,
        new FakeNetworkRecovery(),
        new FakeNotification(),
        new FakeScheduler(),
        [61, 62, 63, 64]
      );

      await coordinator.start('profile-1', 'version-1', 'session-1');
      tunRuntime.emit(buildTunSnapshot('old-session', 'ERROR', 'NETWORK_LOST'));

      expect(coordinator.snapshot().state).assertEqual('RUNNING');
      expect(coordinator.snapshot().activeRequest?.sessionId).assertEqual('session-1');
    });

    it('ignoresStaleStopRequestsAndNotificationCancellationFromAnOldSession', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      const platform = new FakePlatform();
      const notification = new FakeNotification();
      const coordinator = createCoordinator(
        new FakeResolver(),
        platform,
        tunRuntime,
        new FakeNetworkRecovery(),
        notification,
        new FakeScheduler(),
        [65, 66, 67, 68, 69, 70]
      );

      await coordinator.start('profile-1', 'version-1', 'session-1');
      await coordinator.stop('session-1');
      platform.nextHandle = createTunHandle(32, 'vpn-2', 'session-2');
      tunRuntime.snapshotValue = buildTunSnapshot('session-2', 'READY');
      await coordinator.start('profile-1', 'version-2', 'session-2');
      const stopCountBefore: number = tunRuntime.stopCalls.length;
      const destroyCountBefore: number = countArrayEntry(platform.log, 'platform.destroy:vpn-2');
      const notificationStopCountBefore: number = notification.stopCalls.length;

      await coordinator.stop('session-1');
      notification.emitCancellation('session-1');
      await settleMicrotasks();

      expect(coordinator.snapshot().state).assertEqual('RUNNING');
      expect(coordinator.snapshot().activeRequest?.sessionId).assertEqual('session-2');
      expect(tunRuntime.stopCalls.length).assertEqual(stopCountBefore);
      expect(countArrayEntry(platform.log, 'platform.destroy:vpn-2')).assertEqual(destroyCountBefore);
      expect(notification.stopCalls.length).assertEqual(notificationStopCountBefore);

      const session2Stop: VpnControllerStopResult = await coordinator.stop('session-2');
      expect(session2Stop.kind).assertEqual('STOPPED');
      expect(tunRuntime.stopCalls.length).assertEqual(stopCountBefore + 1);
      expect(countArrayEntry(platform.log, 'platform.destroy:vpn-2')).assertEqual(destroyCountBefore + 1);
      expect(notification.stopCalls.length).assertEqual(notificationStopCountBefore + 1);
    });

    it('idleStaleStopDoesNotPublishStoppingOrClearTheNextPreAdmitOwner', 0, async () => {
      const resolver = new FakeResolver();
      resolver.useDeferredResolve = true;
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-2', 'READY');
      const coordinator = createCoordinator(
        resolver,
        new FakePlatform(),
        tunRuntime,
        new FakeNetworkRecovery(),
        new FakeNotification(),
        new FakeScheduler(),
        [71, 72, 73, 74]
      );
      const states: string[] = captureEventStates(coordinator);

      const staleStopResult: VpnControllerStopResult = await coordinator.stop('old-session');
      const startPromise: Promise<VpnControllerStartResult> = coordinator.start('profile-1', 'version-2', 'session-2');
      const duplicateStart: VpnControllerStartResult = await coordinator.start('profile-1', 'version-3', 'session-3');
      resolver.resolveGate.resolve(undefined);
      const startResult: VpnControllerStartResult = await startPromise;

      expect(staleStopResult.kind).assertEqual('STOPPED');
      expect(states.includes('STOPPING')).assertFalse();
      expect(duplicateStart.kind).assertEqual('REJECTED');
      expect(startResult.kind).assertEqual('STARTED');
      expect(coordinator.snapshot().activeRequest?.sessionId).assertEqual('session-2');
      expect(tunRuntime.stopCalls.length).assertEqual(0);
    });

    it('treatsConsentDenialAsStoppedInsteadOfError', 0, async () => {
      const platform = new FakePlatform();
      platform.createError = buildPlatformError('CONSENT_DENIED', 'denied');
      const coordinator = createCoordinator(
        new FakeResolver(),
        platform,
        new FakeTunRuntime(),
        new FakeNetworkRecovery(),
        new FakeNotification(),
        new FakeScheduler(),
        [71, 72, 73]
      );

      const result: VpnControllerStartResult = await coordinator.start('profile-1', 'version-1', 'session-1');

      expect(result.kind).assertEqual('STOPPED');
      expect(coordinator.snapshot().state).assertEqual('STOPPED');
    });

    it('keepsLiveOwnershipAndClosesStaleOutboundConnectionsWhenNetworkLossEntersRecovering', 0, async () => {
      const resolver = new FakeResolver();
      const platform = new FakePlatform();
      const tunRuntime = new FakeTunRuntime();
      const network = new FakeNetworkRecovery();
      const scheduler = new FakeScheduler();
      const notification = new FakeNotification();
      const coordinator = createCoordinator(
        resolver,
        platform,
        tunRuntime,
        network,
        notification,
        scheduler,
        [81, 82, 83, 84, 85]
      );

      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      await coordinator.start('profile-1', 'version-1', 'session-1');
      tunRuntime.emit(buildTunSnapshot('session-1', 'ERROR', 'NETWORK_LOST'));

      expect(coordinator.snapshot().state).assertEqual('RECOVERING');
      expect(coordinator.snapshot().activeRequest?.sessionId).assertEqual('session-1');
      expect(coordinator.snapshot().notificationActive).assertTrue();
      await waitForCondition(() => tunRuntime.closeStaleCalls.length === 1);
      expect(tunRuntime.closeStaleCalls.join('>')).assertEqual('session-1');
      expect(tunRuntime.stopCalls.length).assertEqual(0);
      expect(platform.log.includes('platform.destroy:vpn-1')).assertFalse();
      expect(notification.stopCalls.length).assertEqual(0);
      expect(scheduler.tasks.length).assertEqual(1);
    });

    it('failsClosedWhenCloseStaleOutboundConnectionsErrorsDuringRecovery', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      tunRuntime.closeStaleError = new TunRuntimePortError('VPN_TUN_START_FAILED', 'close stale failed');
      const platform = new FakePlatform();
      const notification = new FakeNotification();
      const scheduler = new FakeScheduler();
      const coordinator = createCoordinator(
        new FakeResolver(),
        platform,
        tunRuntime,
        new FakeNetworkRecovery(),
        notification,
        scheduler,
        [85, 86, 87, 88, 89]
      );

      await coordinator.start('profile-1', 'version-1', 'session-1');
      tunRuntime.emit(buildTunSnapshot('session-1', 'ERROR', 'NETWORK_LOST'));
      await waitForCondition(() => tunRuntime.closeStaleCalls.length === 1);
      await waitForCondition(() => coordinator.snapshot().state === 'ERROR');
      await waitForCondition(() => notification.stopCalls.length === 1);

      expect(tunRuntime.stopCalls.length).assertEqual(1);
      expect(countArrayEntry(platform.log, 'platform.destroy:vpn-1')).assertEqual(1);
      expect(notification.stopCalls.length).assertEqual(1);
      expect(scheduler.tasks.length).assertEqual(0);
    });

    it('recoversOnScheduledRetryWithoutRecreatingPlatformOrNotification', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      tunRuntime.recoverSnapshotValue = buildTunSnapshot('session-1', 'READY');
      const platform = new FakePlatform();
      const network = new FakeNetworkRecovery();
      const notification = new FakeNotification();
      const scheduler = new FakeScheduler();
      const coordinator = createCoordinator(
        new FakeResolver(),
        platform,
        tunRuntime,
        network,
        notification,
        scheduler,
        [86, 87, 88, 89, 90]
      );

      await coordinator.start('profile-1', 'version-1', 'session-1');
      tunRuntime.emit(buildTunSnapshot('session-1', 'ERROR', 'NETWORK_LOST'));
      await waitForCondition(() => scheduler.tasks.length === 1);
      await scheduler.latest().run();

      expect(scheduler.delays.join(',')).assertEqual('250');
      expect(tunRuntime.closeStaleCalls.join('>')).assertEqual('session-1');
      expect(tunRuntime.recoverCalls.join('>')).assertEqual('session-1');
      expect(platform.log.join('>')).assertEqual('platform.protectProcess>platform.create:session-1');
      expect(notification.log.join('>')).assertEqual('notification.start:session-1');
      expect(tunRuntime.stopCalls.length).assertEqual(0);
      expect(coordinator.snapshot().state).assertEqual('RUNNING');
    });

    it('failsClosedWhenRecoverReturnsAReadySnapshotForAStaleSession', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      tunRuntime.recoverSnapshotValue = buildTunSnapshot('old-session', 'READY');
      const platform = new FakePlatform();
      const notification = new FakeNotification();
      const network = new FakeNetworkRecovery();
      const scheduler = new FakeScheduler();
      const coordinator = createCoordinator(
        new FakeResolver(),
        platform,
        tunRuntime,
        network,
        notification,
        scheduler,
        [90, 91, 92, 93, 94]
      );

      await coordinator.start('profile-1', 'version-1', 'session-1');
      tunRuntime.emit(buildTunSnapshot('session-1', 'ERROR', 'NETWORK_LOST'));
      network.emitUsable('wifi-1');
      await scheduler.latest().run();
      await waitForCondition(() => coordinator.snapshot().activeRequest === null);

      expect(coordinator.snapshot().state).assertEqual('ERROR');
      expect(tunRuntime.stopCalls.length).assertEqual(1);
      expect(countArrayEntry(platform.log, 'platform.destroy:vpn-1')).assertEqual(1);
      expect(notification.stopCalls.length).assertEqual(1);
      expect(coordinator.snapshot().activeRequest).assertEqual(null);
    });

    it('exhaustsFiveRecoveryAttemptsThenCleansUpExactlyOnce', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      tunRuntime.recoverPortError = new TunRuntimePortError('NETWORK_LOST', 'recover lost');
      const platform = new FakePlatform();
      const network = new FakeNetworkRecovery();
      const notification = new FakeNotification();
      const scheduler = new FakeScheduler();
      const coordinator = createCoordinator(
        new FakeResolver(),
        platform,
        tunRuntime,
        network,
        notification,
        scheduler,
        [91, 92, 93, 94, 95, 96, 97, 98, 99, 100]
      );

      await coordinator.start('profile-1', 'version-1', 'session-1');
      tunRuntime.emit(buildTunSnapshot('session-1', 'ERROR', 'NETWORK_LOST'));

      for (let index = 0; index < 5; index += 1) {
        await waitForCondition(() => scheduler.tasks.length === index + 1);
        await scheduler.tasks[index].run();
      }

      expect(scheduler.delays.join(',')).assertEqual('250,500,1000,2000,4000');
      expect(tunRuntime.recoverCalls.length).assertEqual(5);
      expect(tunRuntime.stopCalls.length).assertEqual(1);
      expect(countArrayEntry(platform.log, 'platform.destroy:vpn-1')).assertEqual(1);
      expect(notification.stopCalls.length).assertEqual(1);
      expect(coordinator.snapshot().state).assertEqual('ERROR');
    });

    it('deduplicatesUsableEventsWhenRecoveryRetryIsAlreadyScheduled', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      tunRuntime.recoverPortError = new TunRuntimePortError('NETWORK_LOST', 'recover lost');
      const network = new FakeNetworkRecovery();
      network.status = { usable: true, networkId: 'wifi-1' };
      const scheduler = new FakeScheduler();
      const coordinator = createCoordinator(
        new FakeResolver(),
        new FakePlatform(),
        tunRuntime,
        network,
        new FakeNotification(),
        scheduler,
        [107, 108, 109, 110, 111]
      );

      await coordinator.start('profile-1', 'version-1', 'session-1');
      tunRuntime.emit(buildTunSnapshot('session-1', 'ERROR', 'NETWORK_LOST'));
      await waitForCondition(() => tunRuntime.closeStaleCalls.length === 1);
      await waitForCondition(() => scheduler.tasks.length === 1);
      network.emitUsable('wifi-1');
      network.emitUsable('wifi-1');
      await scheduler.latest().run();
      await waitForCondition(() => scheduler.tasks.length === 2);

      expect(scheduler.delays.join(',')).assertEqual('250,500');
    });

    it('doesNotScheduleAnotherRetryWhileRecoverIsStillInFlight', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      tunRuntime.useDeferredRecover = true;
      const network = new FakeNetworkRecovery();
      network.status = { usable: true, networkId: 'wifi-1' };
      const scheduler = new FakeScheduler();
      const coordinator = createCoordinator(
        new FakeResolver(),
        new FakePlatform(),
        tunRuntime,
        network,
        new FakeNotification(),
        scheduler,
        [111, 112, 113, 114, 115]
      );

      await coordinator.start('profile-1', 'version-1', 'session-1');
      tunRuntime.emit(buildTunSnapshot('session-1', 'ERROR', 'NETWORK_LOST'));
      await waitForCondition(() => scheduler.tasks.length === 1);
      const firstTask: FakeDelayTask = scheduler.latest();
      const recoverRunPromise: Promise<void> = firstTask.run();
      await waitForCondition(() => tunRuntime.recoverCalls.length === 1);
      network.emitUsable('wifi-1');
      network.emitUsable('wifi-1');
      await settleMicrotasks();
      expect(scheduler.tasks.length).assertEqual(1);
      tunRuntime.recoverDeferred.resolve(buildTunSnapshot('session-1', 'READY'));
      await recoverRunPromise;
      expect(coordinator.snapshot().state).assertEqual('RUNNING');
    });

    it('ignoresLateRecoverReadyAfterUserStopTakesOwnershipOfCleanup', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      tunRuntime.useDeferredRecover = true;
      const platform = new FakePlatform();
      const notification = new FakeNotification();
      const network = new FakeNetworkRecovery();
      network.status = { usable: true, networkId: 'wifi-1' };
      const scheduler = new FakeScheduler();
      const coordinator = createCoordinator(
        new FakeResolver(),
        platform,
        tunRuntime,
        network,
        notification,
        scheduler,
        [116, 117, 118, 119, 120]
      );
      const states: string[] = captureEventStates(coordinator);

      await coordinator.start('profile-1', 'version-1', 'session-1');
      tunRuntime.emit(buildTunSnapshot('session-1', 'ERROR', 'NETWORK_LOST'));
      await waitForCondition(() => scheduler.tasks.length === 1);
      const recoveryTask: FakeDelayTask = scheduler.latest();
      const recoveryRunPromise: Promise<void> = recoveryTask.run();
      await waitForCondition(() => tunRuntime.recoverCalls.length === 1);

      const stopPromise: Promise<VpnControllerStopResult> = coordinator.stop('session-1');
      expect(coordinator.snapshot().state).assertEqual('STOPPING');

      tunRuntime.recoverDeferred.resolve(buildTunSnapshot('session-1', 'READY'));

      await recoveryRunPromise;
      const stopResult: VpnControllerStopResult = await stopPromise;

      expect(stopResult.kind).assertEqual('STOPPED');
      expect(tunRuntime.stopCalls.length).assertEqual(1);
      expect(countArrayEntry(platform.log, 'platform.destroy:vpn-1')).assertEqual(1);
      expect(notification.stopCalls.length).assertEqual(1);
      expect(coordinator.snapshot().state).assertEqual('STOPPED');
      const stoppingIndex: number = states.indexOf('STOPPING');
      expect(stoppingIndex >= 0).assertTrue();
      for (let index = stoppingIndex + 1; index < states.length; index += 1) {
        expect(states[index] === 'RUNNING').assertFalse();
        expect(states[index] === 'RECOVERING').assertFalse();
        expect(states[index] === 'ERROR').assertFalse();
      }
    });

    it('schedulesTheNextBoundedRetryEvenWhenCurrentNetworkRemainsOpaqueOrUnavailable', 0, async () => {
      const tunRuntime = new FakeTunRuntime();
      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      tunRuntime.recoverPortError = new TunRuntimePortError('NETWORK_LOST', 'recover lost');
      const network = new FakeNetworkRecovery();
      network.status = { usable: true, networkId: 'wifi-1' };
      const scheduler = new FakeScheduler();
      const coordinator = createCoordinator(
        new FakeResolver(),
        new FakePlatform(),
        tunRuntime,
        network,
        new FakeNotification(),
        scheduler,
        [112, 113, 114, 115, 116]
      );

      await coordinator.start('profile-1', 'version-1', 'session-1');
      tunRuntime.emit(buildTunSnapshot('session-1', 'ERROR', 'NETWORK_LOST'));
      await waitForCondition(() => scheduler.tasks.length === 1);
      network.status = { usable: false, networkId: '' };
      await scheduler.latest().run();
      await waitForCondition(() => scheduler.tasks.length === 2);
      expect(scheduler.delays.join(',')).assertEqual('250,500');
    });

    it('publishesStoppingBeforeCleanupAndCancelsRecoveryWithoutDoubleCleanupOrLateRunning', 0, async () => {
      const platform = new FakePlatform();
      const tunRuntime = new FakeTunRuntime();
      const network = new FakeNetworkRecovery();
      const scheduler = new FakeScheduler();
      const notification = new FakeNotification();
      const coordinator = createCoordinator(
        new FakeResolver(),
        platform,
        tunRuntime,
        network,
        notification,
        scheduler,
        [101, 102, 103, 104, 105, 106]
      );
      const states: string[] = captureEventStates(coordinator);

      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      await coordinator.start('profile-1', 'version-1', 'session-1');
      tunRuntime.emit(buildTunSnapshot('session-1', 'ERROR', 'NETWORK_LOST'));
      network.emitUsable('wifi-1');
      const scheduled: FakeDelayTask = scheduler.latest();
      const stopResult: VpnControllerStopResult = await coordinator.stop();
      const recoverCallCount: number = tunRuntime.recoverCalls.length;
      await scheduled.run();
      tunRuntime.emit(buildTunSnapshot('session-1', 'READY'));

      expect(stopResult.kind).assertEqual('STOPPED');
      expect(scheduled.cancelled).assertTrue();
      assertSubsequence(states, ['RUNNING', 'RECOVERING', 'STOPPING', 'STOPPED']);
      expect(tunRuntime.recoverCalls.length).assertEqual(recoverCallCount);
      expect(tunRuntime.stopCalls.length).assertEqual(1);
      expect(countArrayEntry(platform.log, 'platform.destroy:vpn-1')).assertEqual(1);
      expect(notification.stopCalls.length).assertEqual(1);
      expect(coordinator.snapshot().state).assertEqual('STOPPED');
    });

    it('publishesErrorAndCompletesCleanupOnTerminalNonNetworkTunFailure', 0, async () => {
      const platform = new FakePlatform();
      const tunRuntime = new FakeTunRuntime();
      const notification = new FakeNotification();
      const coordinator = createCoordinator(
        new FakeResolver(),
        platform,
        tunRuntime,
        new FakeNetworkRecovery(),
        notification,
        new FakeScheduler(),
        [111, 112, 113, 114]
      );
      const states: string[] = captureEventStates(coordinator);

      tunRuntime.snapshotValue = buildTunSnapshot('session-1', 'READY');
      await coordinator.start('profile-1', 'version-1', 'session-1');
      tunRuntime.emit(buildTunSnapshot('session-1', 'ERROR', 'VPN_TUN_START_FAILED'));

      assertSubsequence(states, ['RUNNING', 'ERROR']);
      await waitForCondition(() => coordinator.snapshot().activeRequest === null);
      expect(tunRuntime.stopCalls.length).assertEqual(1);
      expect(countArrayEntry(platform.log, 'platform.destroy:vpn-1')).assertEqual(1);
      expect(notification.stopCalls.length).assertEqual(1);
      expect(coordinator.snapshot().activeRequest).assertEqual(null);
      expect(coordinator.snapshot().state).assertEqual('ERROR');
    });
  });
}
