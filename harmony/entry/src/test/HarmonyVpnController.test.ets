import { describe, expect, it } from '@ohos/hypium';
import type { Want } from '@kit.AbilityKit';
import {
  type BoundedDelaySchedulerPort,
  type CancelableDelayTask,
  type ClockPort,
  createVpnFailure,
  createVpnRpcBodyEvent,
  createVpnRpcBodyRequest,
  createVpnRpcBodySuccessResponse,
  createVpnRpcEmptyPayload,
  createVpnRpcGuards,
  createVpnRpcRuntimeSnapshotPayload,
  createVpnStartRequest,
  createVpnRuntimeSnapshot,
  type VpnControllerStartResult,
  type VpnRpcBody,
  type VpnRpcClientContext,
  type VpnRpcClientPort,
  type VpnRpcEventListener,
  type VpnRpcGuards,
  type VpnRpcMethod,
  type VpnRpcTrafficCounters,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot,
  type VpnStartRequest
} from '@cmfa/shared';
import {
  HarmonyVpnController,
  type HarmonyVpnControllerDependencies,
  type VpnExtensionAbilityApi
} from '../main/ets/vpn/HarmonyVpnController';
import { VpnSessionRegistry } from '../main/ets/vpn/VpnSessionRegistry';

const PROFILE_HASH: string = '1111111111111111111111111111111111111111111111111111111111111111';
const REVISION_HASH: string = '2222222222222222222222222222222222222222222222222222222222222222';
const CATALOG_DIGEST: string = '3333333333333333333333333333333333333333333333333333333333333333';

class DeferredVoid {
  readonly promise: Promise<void>;
  private resolveRef?: () => void;
  private rejectRef?: (error: Error) => void;

  constructor() {
    this.promise = new Promise<void>((resolve, reject) => {
      this.resolveRef = resolve;
      this.rejectRef = reject;
    });
  }

  resolve(): void {
    this.resolveRef?.();
  }

  reject(error: Error): void {
    this.rejectRef?.(error);
  }
}

class FakeBusinessError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

class FakeVpnExtensionAbilityApi implements VpnExtensionAbilityApi {
  startWant?: Want;
  startCalls: number = 0;
  stopCalls: number = 0;
  disposeCalls: number = 0;
  readonly trafficUpdates: string[] = [];
  startError?: Error;
  startBusinessError?: FakeBusinessError;
  stopError?: Error;
  updateTrafficError?: Error;
  deferStop: boolean = false;
  private readonly deferredStops: DeferredVoid[] = [];

  setStartBusinessError(code: number, message: string): void {
    this.startBusinessError = new FakeBusinessError(code, message);
  }

  async startVpnExtensionAbility(want: Want): Promise<void> {
    this.startCalls += 1;
    this.startWant = want;
    if (this.startBusinessError !== undefined) {
      throw this.startBusinessError;
    }
    if (this.startError !== undefined) {
      throw this.startError;
    }
  }

  async stopVpnExtensionAbility(): Promise<void> {
    this.stopCalls += 1;
    if (this.deferStop) {
      const deferred = new DeferredVoid();
      this.deferredStops.push(deferred);
      return await deferred.promise;
    }
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
  }

  resolveDeferredStop(): void {
    this.deferredStops.shift()?.resolve();
  }

  async updateTraffic(
    sessionId: string,
    uploadBytesPerSecond: number,
    downloadBytesPerSecond: number
  ): Promise<void> {
    this.trafficUpdates.push(`${sessionId}:${uploadBytesPerSecond}:${downloadBytesPerSecond}`);
    if (this.updateTrafficError !== undefined) {
      throw this.updateTrafficError;
    }
  }

  dispose(): void {
    this.disposeCalls += 1;
  }
}

class ManualClock implements ClockPort {
  private nowValue: number;

  constructor(nowMs: number = 1000) {
    this.nowValue = nowMs;
  }

  setNow(nowMs: number): void {
    this.nowValue = nowMs;
  }

  nowMs(): number {
    return this.nowValue;
  }
}

class ManualDelayTask implements CancelableDelayTask {
  readonly delayMs: number;
  private readonly runner: () => Promise<void>;
  canceled: boolean = false;

  constructor(delayMs: number, runner: () => Promise<void>) {
    this.delayMs = delayMs;
    this.runner = runner;
  }

  cancel(): void {
    this.canceled = true;
  }

  async run(): Promise<void> {
    if (this.canceled) {
      return;
    }
    await this.runner();
  }
}

class ManualScheduler implements BoundedDelaySchedulerPort {
  readonly tasks: ManualDelayTask[] = [];
  readonly scheduledDelays: number[] = [];

  schedule(delayMs: number, runner: () => Promise<void>): CancelableDelayTask {
    this.scheduledDelays.push(delayMs);
    const task = new ManualDelayTask(delayMs, runner);
    this.tasks.push(task);
    return task;
  }

  pendingCount(): number {
    let count = 0;
    for (let index = 0; index < this.tasks.length; index += 1) {
      if (!this.tasks[index].canceled) {
        count += 1;
      }
    }
    return count;
  }

  async runNext(): Promise<void> {
    while (this.tasks.length > 0) {
      const task = this.tasks.shift();
      if (task === undefined || task.canceled) {
        continue;
      }
      await task.run();
      return;
    }
  }
}

class FakeVpnRpcClient implements VpnRpcClientPort {
  connectOnceCalls: number = 0;
  connectCalls: number = 0;
  closeCalls: number = 0;
  stateValue: 'DISCONNECTED' | 'CONNECTING' | 'AUTHENTICATING' | 'READY' | 'RECONNECTING' | 'CLOSED' = 'DISCONNECTED';
  snapshotValue: VpnRuntimeSnapshot = createRpcSnapshot('STOPPED');
  contextValue: VpnRpcClientContext | null = null;
  connectOnceError?: Error;
  connectError?: Error;
  connectOnceDeferred?: DeferredVoid;
  connectDeferred?: DeferredVoid;
  readonly requests: VpnRpcBody[] = [];
  readonly responses: Array<VpnRpcBody | Error> = [];
  readonly trafficCounterSteps: Array<VpnRpcTrafficCounters | Error> = [];
  private readonly listeners: Map<number, VpnRpcEventListener> = new Map();
  private nextListenerId: number = 1;

  async connectOnce(): Promise<void> {
    this.connectOnceCalls += 1;
    if (this.connectOnceError !== undefined) {
      const error = this.connectOnceError;
      this.connectOnceError = undefined;
      throw error;
    }
    if (this.connectOnceDeferred !== undefined) {
      await this.connectOnceDeferred.promise;
    }
    this.stateValue = 'READY';
  }

  async connect(): Promise<void> {
    this.connectCalls += 1;
    if (this.connectError !== undefined) {
      throw this.connectError;
    }
    if (this.connectDeferred !== undefined) {
      await this.connectDeferred.promise;
    }
    this.stateValue = 'READY';
  }

  async request(method: VpnRpcMethod, guards: VpnRpcGuards, generation: number, payload: Object): Promise<VpnRpcBody> {
    const ordinal: number = this.requests.length + 1;
    const request = createVpnRpcBodyRequest(
      ordinal,
      1,
      ordinal,
      `00000000-0000-4000-8000-${`${ordinal}`.padStart(12, '0')}`,
      method,
      generation,
      guards,
      payload as never
    );
    this.requests.push(request);
    const response: VpnRpcBody | Error | undefined = this.responses.shift();
    if (response === undefined) {
      throw new Error('missing scripted rpc response');
    }
    if (response instanceof Error) {
      throw response;
    }
    return response;
  }

  async refreshTrafficCounters(): Promise<VpnRpcTrafficCounters> {
    const scripted = this.trafficCounterSteps.shift();
    if (scripted instanceof Error) {
      throw scripted;
    }
    if (scripted !== undefined) {
      return {
        txBytes: scripted.txBytes,
        rxBytes: scripted.rxBytes
      };
    }
    const counters: VpnRpcTrafficCounters = {
      txBytes: this.snapshotValue.tunSnapshot?.counters.txBytes ?? 0,
      rxBytes: this.snapshotValue.tunSnapshot?.counters.rxBytes ?? 0
    };
    return counters;
  }

  state() {
    return this.stateValue;
  }

  snapshot(): VpnRuntimeSnapshot {
    return createVpnRuntimeSnapshot({
      state: this.snapshotValue.state,
      activeRequest: this.snapshotValue.activeRequest,
      activeHandle: this.snapshotValue.activeHandle,
      captureConfig: this.snapshotValue.captureConfig,
      tunSnapshot: this.snapshotValue.tunSnapshot,
      notificationActive: this.snapshotValue.notificationActive,
      recoveryAttempt: this.snapshotValue.recoveryAttempt,
      scheduledRetryDelayMs: this.snapshotValue.scheduledRetryDelayMs,
      lastFailure: this.snapshotValue.lastFailure
    });
  }

  activeContext(): VpnRpcClientContext | null {
    if (this.contextValue === null) {
      return null;
    }
    return {
      sessionGeneration: this.contextValue.sessionGeneration,
      guards: createVpnRpcGuards(
        this.contextValue.guards.profileHash,
        this.contextValue.guards.revisionHash,
        this.contextValue.guards.catalogDigest
      )
    };
  }

  subscribe(listener: VpnRpcEventListener): number {
    const id = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(id, listener);
    return id;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  emitRuntimeChanged(snapshot: VpnRuntimeSnapshot, context: VpnRpcClientContext | null): void {
    this.snapshotValue = cloneRuntimeSnapshot(snapshot);
    this.contextValue = cloneContext(context);
    const event = createVpnRpcBodyEvent(
      10,
      1,
      'RUNTIME_CHANGED',
      context?.sessionGeneration ?? 0,
      context === null ? createVpnRpcGuards(null, null, null) : context.guards,
      createRuntimePayload(snapshot, context)
    );
    this.listeners.forEach((listener) => {
      listener(event);
    });
  }

  emitServerStopping(context: VpnRpcClientContext | null): void {
    const event = createVpnRpcBodyEvent(
      11,
      1,
      'SERVER_STOPPING',
      context?.sessionGeneration ?? 0,
      context === null ? createVpnRpcGuards(null, null, null) : context.guards,
      createVpnRpcEmptyPayload()
    );
    this.listeners.forEach((listener) => {
      listener(event);
    });
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
    this.stateValue = 'CLOSED';
  }
}

class FakeRuntimeMirrorPort {
  readonly bindSessions: string[] = [];
  readonly deactivateSessions: string[] = [];
  readonly eventLog?: string[];
  bindError?: Error;
  bindDeferred?: DeferredVoid;
  readonly scriptedBindErrors: Error[] = [];

  constructor(eventLog?: string[]) {
    this.eventLog = eventLog;
  }

  async bindExistingSession(request: VpnStartRequest): Promise<void> {
    const scriptedError: Error | undefined = this.scriptedBindErrors.shift();
    if (scriptedError !== undefined) {
      throw scriptedError;
    }
    if (this.bindError !== undefined) {
      throw this.bindError;
    }
    if (this.bindDeferred !== undefined) {
      await this.bindDeferred.promise;
    }
    this.bindSessions.push(request.sessionId);
    this.eventLog?.push(`mirror.bind:${request.sessionId}`);
  }

  async deactivate(sessionId: string): Promise<void> {
    this.deactivateSessions.push(sessionId);
    this.eventLog?.push(`mirror.deactivate:${sessionId}`);
  }
}

interface ControllerHarness {
  registry: VpnSessionRegistry;
  api: FakeVpnExtensionAbilityApi;
  rpcClient: FakeVpnRpcClient;
  runtimeMirror: FakeRuntimeMirrorPort;
  scheduler: ManualScheduler;
  trafficScheduler: ManualScheduler;
  trafficClock: ManualClock;
  controller: HarmonyVpnController;
  registryLog: string[];
  eventLog: string[];
  reportStages: string[];
}

interface TrafficLoopProbe {
  startTrafficLoop(sessionId: string): void;
  stopTrafficLoop(sessionId?: string): void;
}

class TestControllerDependencies implements HarmonyVpnControllerDependencies {
  rpcClient?: FakeVpnRpcClient;
  runtimeMirror?: FakeRuntimeMirrorPort;
  scheduler?: ManualScheduler;
  trafficScheduler?: ManualScheduler;
  trafficClock?: ManualClock;
  trafficReportStage?: (stage: string) => void;
}

function createHarness(): ControllerHarness {
  const registry = new VpnSessionRegistry();
  const api = new FakeVpnExtensionAbilityApi();
  const rpcClient = new FakeVpnRpcClient();
  const eventLog: string[] = [];
  const runtimeMirror = new FakeRuntimeMirrorPort(eventLog);
  const scheduler = new ManualScheduler();
  const trafficScheduler = new ManualScheduler();
  const trafficClock = new ManualClock();
  const reportStages: string[] = [];
  const dependencies = new TestControllerDependencies();
  dependencies.rpcClient = rpcClient;
  dependencies.runtimeMirror = runtimeMirror;
  dependencies.scheduler = scheduler;
  dependencies.trafficScheduler = trafficScheduler;
  dependencies.trafficClock = trafficClock;
  dependencies.trafficReportStage = (stage: string): void => {
    reportStages.push(stage);
  };
  const controller = new HarmonyVpnController(registry, api, dependencies);
  const registryLog: string[] = [];
  registry.subscribe((event: VpnRuntimeEvent) => {
    registryLog.push(`${event.type}:${event.snapshot.state}:${event.snapshot.activeRequest?.sessionId ?? 'none'}`);
    eventLog.push(`registry:${event.type}:${event.snapshot.state}:${event.snapshot.activeRequest?.sessionId ?? 'none'}`);
  });
  return {
    registry,
    api,
    rpcClient,
    runtimeMirror,
    scheduler,
    trafficScheduler,
    trafficClock,
    controller,
    registryLog,
    eventLog,
    reportStages
  };
}

function createRuntimePayload(snapshot: VpnRuntimeSnapshot, context: VpnRpcClientContext | null) {
  return createVpnRpcRuntimeSnapshotPayload(
    snapshot.state,
    context?.guards.profileHash ?? null,
    context?.guards.revisionHash ?? null,
    context?.guards.catalogDigest ?? null,
    snapshot.notificationActive,
    snapshot.recoveryAttempt,
    snapshot.scheduledRetryDelayMs,
    snapshot.lastFailure?.code ?? null,
    snapshot.tunSnapshot?.counters.txBytes ?? 0,
    snapshot.tunSnapshot?.counters.rxBytes ?? 0
  );
}

function createRpcSnapshot(state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'RECOVERING' | 'STOPPING' | 'ERROR'): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state,
    activeRequest: null,
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: state === 'RUNNING',
    recoveryAttempt: state === 'RECOVERING' ? 1 : 0,
    scheduledRetryDelayMs: null,
    lastFailure: null
  });
}

function cloneRuntimeSnapshot(snapshot: VpnRuntimeSnapshot): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state: snapshot.state,
    activeRequest: snapshot.activeRequest,
    activeHandle: snapshot.activeHandle,
    captureConfig: snapshot.captureConfig,
    tunSnapshot: snapshot.tunSnapshot,
    notificationActive: snapshot.notificationActive,
    recoveryAttempt: snapshot.recoveryAttempt,
    scheduledRetryDelayMs: snapshot.scheduledRetryDelayMs,
    lastFailure: snapshot.lastFailure
  });
}

function createContext(generation: number): VpnRpcClientContext {
  return createContextWithDigest(generation, CATALOG_DIGEST);
}

function createContextWithDigest(generation: number, catalogDigest: string): VpnRpcClientContext {
  return {
    sessionGeneration: generation,
    guards: createVpnRpcGuards(PROFILE_HASH, REVISION_HASH, catalogDigest)
  };
}

function cloneContext(context: VpnRpcClientContext | null): VpnRpcClientContext | null {
  if (context === null) {
    return null;
  }
  return {
    sessionGeneration: context.sessionGeneration,
    guards: createVpnRpcGuards(context.guards.profileHash, context.guards.revisionHash, context.guards.catalogDigest)
  };
}

function createStopResponse(generation: number, state: 'STOPPED' | 'STOPPING'): VpnRpcBody {
  const context = createContext(generation);
  return createVpnRpcBodySuccessResponse(
    20,
    1,
    1,
    '00000000-0000-4000-8000-000000000001',
    'STOP_VPN',
    generation,
    context.guards,
    createRuntimePayload(createRpcSnapshot(state), context)
  );
}

async function settleMicrotasks(turns: number = 8): Promise<void> {
  for (let index = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

class TimeoutResult<T> {
  readonly promise: Promise<T>;

  constructor(value: T, delayMs: number) {
    this.promise = new Promise<T>((resolve) => {
      setTimeout(() => resolve(value), delayMs);
    });
  }
}

function expectRejectedCode(result: VpnControllerStartResult, code: string): void {
  expect(result.kind).assertEqual('REJECTED');
  if (result.kind !== 'REJECTED') {
    expect().assertFail();
    return;
  }
  expect(result.failure.code).assertEqual(code);
}

export default function harmonyVpnControllerTestsuite() {
  describe('HarmonyVpnControllerTest', () => {
    it('startsOnlyAfterAuthoritativeRunningSnapshotAndNeverReadsBridge', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.snapshotValue = createRpcSnapshot('RUNNING');
      harness.rpcClient.contextValue = createContext(4);

      const result = await harness.controller.start('profile-1', 'version-1', 'session-1');

      expect(result.kind).assertEqual('STARTED');
      expect(harness.registry.snapshot().state).assertEqual('RUNNING');
      expect(harness.registry.snapshot().activeRequest?.sessionId ?? '').assertEqual('session-1');
      expect(harness.api.startCalls).assertEqual(1);
      expect(harness.rpcClient.connectCalls).assertEqual(1);
      expect(harness.rpcClient.connectOnceCalls).assertEqual(0);
    });

    it('startImmediateRunningRejectsAndRollsBackWhenMirrorBindFails', 0, async () => {
      const harness = createHarness();
      harness.runtimeMirror.bindError = new Error('bind failed');
      harness.rpcClient.snapshotValue = createRpcSnapshot('RUNNING');
      harness.rpcClient.snapshotValue.activeRequest = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.rpcClient.contextValue = createContext(4);

      const result = await harness.controller.start('profile-1', 'version-1', 'session-1');

      expectRejectedCode(result, 'VPN_CREATE_FAILED');
      expect(harness.api.stopCalls).assertEqual(1);
      expect(harness.registry.snapshot().state).assertEqual('STOPPED');
      expect(harness.runtimeMirror.bindSessions.length).assertEqual(0);
      expect(harness.registryLog.join('>')).assertEqual('STATE_CHANGED:AWAITING_CONSENT:session-1>STOPPED:STOPPED:none');
    });

    it('keepsStartPendingAcrossTransitionalSnapshotUntilRuntimeChangedRunning', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.snapshotValue = createRpcSnapshot('STARTING');
      harness.rpcClient.contextValue = createContext(0);

      let settled = false;
      const startPromise = harness.controller.start('profile-1', 'version-1', 'session-1').then((result) => {
        settled = true;
        return result;
      });
      await settleMicrotasks();

      expect(settled).assertFalse();
      expect(harness.registry.snapshot().state).assertEqual('STARTING');

      harness.rpcClient.emitRuntimeChanged(createRpcSnapshot('RUNNING'), createContext(1));
      const result = await startPromise;

      expect(result.kind).assertEqual('STARTED');
      expect(harness.registry.snapshot().state).assertEqual('RUNNING');
    });

    it('pendingStartRuntimeChangedWaitsForMirrorBindBeforePublishingRunning', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.snapshotValue = createRpcSnapshot('STARTING');
      harness.rpcClient.contextValue = createContext(0);
      harness.runtimeMirror.bindDeferred = new DeferredVoid();

      const startPromise = harness.controller.start('profile-1', 'version-1', 'session-1');
      await settleMicrotasks(4);
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: createVpnStartRequest('profile-1', 'version-1', 'session-1'),
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.emitRuntimeChanged(harness.rpcClient.snapshotValue, createContext(1));
      await settleMicrotasks(8);

      expect(harness.registry.snapshot().state === 'RUNNING').assertFalse();

      harness.runtimeMirror.bindDeferred.resolve();
      const result = await startPromise;

      expect(result.kind).assertEqual('STARTED');
      expect(harness.registry.snapshot().state).assertEqual('RUNNING');
    });

    it('pendingStartRuntimeChangedBindFailureRollsBackInsteadOfPublishingRunning', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.snapshotValue = createRpcSnapshot('STARTING');
      harness.rpcClient.contextValue = createContext(0);
      harness.runtimeMirror.bindError = new Error('bind failed');

      const startPromise = harness.controller.start('profile-1', 'version-1', 'session-1');
      await settleMicrotasks(4);
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: createVpnStartRequest('profile-1', 'version-1', 'session-1'),
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.emitRuntimeChanged(harness.rpcClient.snapshotValue, createContext(1));

      const result = await startPromise;

      expectRejectedCode(result, 'VPN_CREATE_FAILED');
      expect(harness.api.stopCalls).assertEqual(1);
      expect(harness.registry.snapshot().state).assertEqual('STOPPED');
    });

    it('rejectsPendingStartOnFirstAuthenticatedRuntimeErrorAndRollsBackExactlyOnce', 0, async () => {
      const harness = createHarness();
      const connectGate = new DeferredVoid();
      harness.rpcClient.connectDeferred = connectGate;
      harness.rpcClient.snapshotValue = createRpcSnapshot('STARTING');
      harness.rpcClient.contextValue = createContext(0);

      let settledCount = 0;
      const startPromise = harness.controller.start('profile-1', 'version-1', 'session-1').then((result) => {
        settledCount += 1;
        return result;
      });
      await settleMicrotasks();

      const errorSnapshot = createRpcSnapshot('ERROR');
      errorSnapshot.lastFailure = createVpnFailure('VPN_PROXY_REPLAY_FAILED', 'safe runtime failure');
      harness.rpcClient.emitRuntimeChanged(errorSnapshot, createContext(1));
      const pendingOutcome = await Promise.race([
        startPromise.then(() => 'resolved'),
        new TimeoutResult<string>('timeout', 20).promise
      ]);

      expect(pendingOutcome).assertEqual('resolved');
      const result = await startPromise;
      expectRejectedCode(result, 'VPN_CREATE_FAILED');
      expect(settledCount).assertEqual(1);
      expect(harness.api.stopCalls).assertEqual(1);
      expect(harness.registry.snapshot().state).assertEqual('STOPPED');
      expect(harness.registry.currentSessionId()).assertUndefined();

      connectGate.reject(new Error('late connect failure'));
      await settleMicrotasks();
      harness.rpcClient.emitRuntimeChanged(createRpcSnapshot('RUNNING'), createContext(2));
      await settleMicrotasks();
      expect(harness.api.stopCalls).assertEqual(1);
      expect(harness.registry.snapshot().state).assertEqual('STOPPED');

      harness.rpcClient.connectDeferred = undefined;
      harness.rpcClient.connectError = undefined;
      harness.rpcClient.snapshotValue = createRpcSnapshot('RUNNING');
      harness.rpcClient.contextValue = createContext(3);
      const restart = await harness.controller.start('profile-1', 'version-1', 'session-2');
      expect(restart.kind).assertEqual('STARTED');
    });

    it('rejectsPendingStartOnFirstAuthenticatedStoppedEventAndRollsBackExactlyOnce', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.connectDeferred = new DeferredVoid();
      harness.rpcClient.snapshotValue = createRpcSnapshot('STARTING');
      harness.rpcClient.contextValue = createContext(0);

      const startPromise = harness.controller.start('profile-1', 'version-1', 'session-1');
      await settleMicrotasks();
      harness.rpcClient.emitRuntimeChanged(createRpcSnapshot('STOPPED'), createContext(1));

      const pendingOutcome = await Promise.race([
        startPromise.then(() => 'resolved'),
        new TimeoutResult<string>('timeout', 20).promise
      ]);
      expect(pendingOutcome).assertEqual('resolved');

      const result = await startPromise;
      expectRejectedCode(result, 'VPN_CREATE_FAILED');
      expect(harness.api.stopCalls).assertEqual(1);
      expect(harness.registry.snapshot().state).assertEqual('STOPPED');
      expect(harness.registry.currentSessionId()).assertUndefined();
    });

    it('settlesPendingStartExactlyOnceAcrossConcurrentTerminalEventAndLateConnectFailure', 0, async () => {
      const harness = createHarness();
      const connectGate = new DeferredVoid();
      harness.rpcClient.connectDeferred = connectGate;
      harness.rpcClient.snapshotValue = createRpcSnapshot('STARTING');
      harness.rpcClient.contextValue = createContext(0);

      let settledCount = 0;
      const startPromise = harness.controller.start('profile-1', 'version-1', 'session-1').then((result) => {
        settledCount += 1;
        return result;
      });
      await settleMicrotasks();

      const errorSnapshot = createRpcSnapshot('ERROR');
      errorSnapshot.lastFailure = createVpnFailure('VPN_STOP_FAILED', 'safe runtime failure');
      harness.rpcClient.emitRuntimeChanged(errorSnapshot, createContext(1));
      connectGate.reject(new Error('connect timed out later'));
      await settleMicrotasks(16);
      harness.rpcClient.emitRuntimeChanged(createRpcSnapshot('RUNNING'), createContext(4));

      const result = await startPromise;
      expectRejectedCode(result, 'VPN_CREATE_FAILED');
      expect(settledCount).assertEqual(1);
      expect(harness.api.stopCalls).assertEqual(1);
      expect(harness.registry.snapshot().state).assertEqual('STOPPED');
    });

    it('rollsBackOnceWhenRpcConnectFails', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.connectError = new Error('rpc unavailable');

      const result = await harness.controller.start('profile-1', 'version-1', 'session-1');

      expectRejectedCode(result, 'VPN_CREATE_FAILED');
      expect(harness.api.startCalls).assertEqual(1);
      expect(harness.api.stopCalls).assertEqual(1);
      expect(harness.registry.snapshot().state).assertEqual('STOPPED');
    });

    it('immediateAuthoritativeRunningStartsOneTrafficLoopAndSeedsZeroTraffic', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: createVpnStartRequest('profile-1', 'version-1', 'session-1'),
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(4);

      const result = await harness.controller.start('profile-1', 'version-1', 'session-1');

      expect(result.kind).assertEqual('STARTED');
      expect(harness.trafficScheduler.scheduledDelays).assertDeepEquals([0]);
      expect(harness.trafficScheduler.pendingCount()).assertEqual(1);

      await harness.trafficScheduler.runNext();

      expect(harness.api.trafficUpdates).assertDeepEquals(['session-1:0:0']);
      expect(harness.trafficScheduler.scheduledDelays).assertDeepEquals([0, 1000]);
    });

    it('trafficLoopReportsFixedDiagnosticTransitionsThroughControllerDependency', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: createVpnStartRequest('profile-1', 'version-1', 'session-1'),
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(9);
      harness.rpcClient.trafficCounterSteps.push({ txBytes: 1024, rxBytes: 2048 });
      harness.rpcClient.trafficCounterSteps.push({ txBytes: 3072, rxBytes: 5120 });

      await harness.controller.start('profile-1', 'version-1', 'session-1');
      await harness.trafficScheduler.runNext();
      harness.trafficClock.setNow(2000);
      await harness.trafficScheduler.runNext();

      expect(harness.reportStages).assertDeepEquals([
        'notification.traffic.source-ok',
        'notification.traffic.counters-nonzero',
        'notification.traffic.rate-zero',
        'notification.traffic.rate-nonzero'
      ]);
    });

    it('transitionalSnapshotsDoNotStartTrafficUntilAuthoritativeRunning', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.snapshotValue = createRpcSnapshot('STARTING');
      harness.rpcClient.contextValue = createContext(0);

      const startPromise = harness.controller.start('profile-1', 'version-1', 'session-1');
      await settleMicrotasks(4);

      expect(harness.trafficScheduler.pendingCount()).assertEqual(0);

      harness.rpcClient.emitRuntimeChanged(createRpcSnapshot('RECOVERING'), createContext(1));
      await settleMicrotasks(4);

      expect(harness.trafficScheduler.pendingCount()).assertEqual(0);

      harness.rpcClient.emitRuntimeChanged(createRpcSnapshot('RUNNING'), createContext(2));
      await startPromise;

      expect(harness.trafficScheduler.scheduledDelays).assertDeepEquals([0]);
      expect(harness.trafficScheduler.pendingCount()).assertEqual(1);
    });

    it('userStopCancelsTheTrafficLoop', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: createVpnStartRequest('profile-1', 'version-1', 'session-1'),
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(5);

      await harness.controller.start('profile-1', 'version-1', 'session-1');
      expect(harness.trafficScheduler.pendingCount()).assertEqual(1);

      await harness.controller.stop('session-1');

      expect(harness.trafficScheduler.pendingCount()).assertEqual(0);
    });

    it('trafficSourceFailureKeepsRegistryStableAndRetriesWithoutStoppingVpn', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: createVpnStartRequest('profile-1', 'version-1', 'session-1'),
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(6);
      harness.rpcClient.trafficCounterSteps.push(new Error('refresh failed'));

      await harness.controller.start('profile-1', 'version-1', 'session-1');
      await harness.trafficScheduler.runNext();

      expect(harness.api.stopCalls).assertEqual(0);
      expect(harness.api.trafficUpdates).assertDeepEquals(['session-1:0:0']);
      expect(harness.registry.snapshot().state).assertEqual('RUNNING');
      expect(harness.registry.snapshot().lastFailure).assertNull();
      expect(harness.trafficScheduler.scheduledDelays).assertDeepEquals([0, 1000]);
    });

    it('trafficSinkFailureDoesNotChangeRuntimeOrTriggerStop', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: createVpnStartRequest('profile-1', 'version-1', 'session-1'),
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(7);
      harness.api.updateTrafficError = new Error('notification failed');

      await harness.controller.start('profile-1', 'version-1', 'session-1');
      await harness.trafficScheduler.runNext();

      expect(harness.api.stopCalls).assertEqual(0);
      expect(harness.api.trafficUpdates).assertDeepEquals(['session-1:0:0']);
      expect(harness.registry.snapshot().state).assertEqual('RUNNING');
      expect(harness.registry.snapshot().lastFailure).assertNull();
      expect(harness.trafficScheduler.scheduledDelays).assertDeepEquals([0, 1000]);
    });

    it('extensionDestroyedCancelsTrafficLoop', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: createVpnStartRequest('profile-1', 'version-1', 'session-1'),
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(8);

      await harness.controller.start('profile-1', 'version-1', 'session-1');
      harness.controller.handleExtensionDestroyed();

      expect(harness.trafficScheduler.pendingCount()).assertEqual(0);
    });

    it('extensionDestroyedWithoutLifecycleAuthorityOnlyClearsPresentationLoop', 0, async () => {
      const harness = createHarness();
      const probe = harness.controller as Object as TrafficLoopProbe;

      probe.startTrafficLoop('session-1');
      harness.controller.handleExtensionDestroyed();

      expect(harness.trafficScheduler.pendingCount()).assertEqual(0);
      expect(harness.registry.snapshot().state).assertEqual('STOPPED');
      expect(harness.runtimeMirror.deactivateSessions.length).assertEqual(0);
      expect(harness.registryLog.length).assertEqual(0);
    });

    it('staleStopTrafficLoopDoesNotCancelTheNewSessionLoop', 0, async () => {
      const harness = createHarness();
      const probe = harness.controller as Object as TrafficLoopProbe;

      probe.startTrafficLoop('session-2');
      probe.stopTrafficLoop('session-1');
      await harness.trafficScheduler.runNext();

      expect(harness.api.trafficUpdates).assertDeepEquals(['session-2:0:0']);
      expect(harness.trafficScheduler.scheduledDelays).assertDeepEquals([0, 1000]);
    });

    it('disposeAlwaysDisposesTrafficCoordinatorEvenWithoutRegistrySession', 0, async () => {
      const harness = createHarness();
      const probe = harness.controller as Object as TrafficLoopProbe;

      probe.startTrafficLoop('session-1');
      await harness.controller.dispose();
      await harness.trafficScheduler.runNext();

      expect(harness.api.trafficUpdates.length).assertEqual(0);
      expect(harness.trafficScheduler.pendingCount()).assertEqual(0);
      expect(harness.runtimeMirror.deactivateSessions.length).assertEqual(0);
    });

    it('initializeDisconnectedUsesConnectOnceWithoutStartingFullRecoveryWhenOneShotSucceeds', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.snapshotValue = createRpcSnapshot('RECOVERING');
      harness.rpcClient.contextValue = createContext(0);

      await harness.controller.initializeRuntimeMirror();

      expect(harness.rpcClient.connectOnceCalls).assertEqual(1);
      expect(harness.rpcClient.connectCalls).assertEqual(0);
      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');
      expect(harness.registry.snapshot().activeRequest).assertNull();
      expect(harness.registry.currentSessionId() === undefined).assertFalse();
    });

    it('initializeReturnsQuicklyAfterOneShotFailureAndLeavesRegistryRecoveringUntilOwnedFullConnectSettles', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.connectOnceError = new Error('one-shot unavailable');
      harness.rpcClient.connectDeferred = new DeferredVoid();

      const initializePromise = harness.controller.initializeRuntimeMirror();
      const outcome = await Promise.race([
        initializePromise.then(() => 'resolved'),
        new TimeoutResult<string>('timeout', 20).promise
      ]);

      expect(outcome).assertEqual('resolved');
      expect(harness.rpcClient.connectOnceCalls).assertEqual(1);
      expect(harness.rpcClient.connectCalls).assertEqual(1);
      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');
      expect(harness.runtimeMirror.bindSessions.length).assertEqual(0);
      expect(harness.registryLog.join('>')).assertEqual('STATE_CHANGED:RECOVERING:none');
    });

    it('backgroundFullRecoveryUsesKnownRequestFromRegistryAndBindsMirrorBeforePublishingRunningSnapshot', 0, async () => {
      const harness = createHarness();
      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.registry.beginPending(request);
      harness.rpcClient.connectOnceError = new Error('one-shot unavailable');
      harness.rpcClient.connectDeferred = new DeferredVoid();
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(6);

      await harness.controller.initializeRuntimeMirror();
      expect(harness.eventLog.join('>')).assertEqual(
        'registry:STATE_CHANGED:AWAITING_CONSENT:session-1>registry:STATE_CHANGED:RECOVERING:session-1'
      );

      harness.rpcClient.connectDeferred.resolve();
      await settleMicrotasks(16);

      expect(harness.runtimeMirror.bindSessions.join('>')).assertEqual('session-1');
      expect(harness.registry.snapshot().state).assertEqual('RUNNING');
      expect(harness.registry.snapshot().activeRequest?.sessionId ?? '').assertEqual('session-1');
      expect(harness.eventLog.join('>')).assertEqual(
        'registry:STATE_CHANGED:AWAITING_CONSENT:session-1>registry:STATE_CHANGED:RECOVERING:session-1>mirror.bind:session-1>registry:STATE_CHANGED:RUNNING:session-1'
      );
    });

    it('backgroundFullRecoveryKeepsRecoveringUntilExhaustedThenPublishesStopped', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.connectOnceError = new Error('one-shot unavailable');
      harness.rpcClient.connectDeferred = new DeferredVoid();

      await harness.controller.initializeRuntimeMirror();
      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');

      harness.rpcClient.connectDeferred.reject(new Error('connect exhausted'));
      await settleMicrotasks(16);

      expect(harness.registry.snapshot().state).assertEqual('STOPPED');
      expect(harness.runtimeMirror.bindSessions.length).assertEqual(0);
      expect(harness.registryLog.join('>')).assertEqual('STATE_CHANGED:RECOVERING:none>STOPPED:STOPPED:none');
    });

    it('runtimeChangedDuringHydrationWaitsForMirrorBindBeforePublishingRunning', 0, async () => {
      const harness = createHarness();
      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.registry.beginPending(request);
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RECOVERING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: false,
        recoveryAttempt: 1,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(8);
      harness.runtimeMirror.bindDeferred = new DeferredVoid();

      const initializePromise = harness.controller.initializeRuntimeMirror();
      await settleMicrotasks(4);
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.emitRuntimeChanged(harness.rpcClient.snapshotValue, createContext(9));
      await settleMicrotasks(8);

      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');
      expect(harness.runtimeMirror.bindSessions.length).assertEqual(0);

      harness.runtimeMirror.bindDeferred.resolve();
      await initializePromise;

      expect(harness.runtimeMirror.bindSessions.join('>')).assertEqual('session-1>session-1');
      expect(harness.runtimeMirror.deactivateSessions.join('>')).assertEqual('session-1');
      expect(harness.registry.snapshot().state).assertEqual('RUNNING');
      expect(harness.eventLog.join('>')).assertEqual(
        'registry:STATE_CHANGED:AWAITING_CONSENT:session-1>registry:STATE_CHANGED:RECOVERING:session-1>mirror.bind:session-1>mirror.deactivate:session-1>mirror.bind:session-1>registry:STATE_CHANGED:RUNNING:session-1'
      );
    });

    it('runtimeChangedToStoppedDuringDeferredBindDeactivatesBoundSessionBeforePublishingStopped', 0, async () => {
      const harness = createHarness();
      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.registry.beginPending(request);
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(12);
      harness.runtimeMirror.bindDeferred = new DeferredVoid();

      const initializePromise = harness.controller.initializeRuntimeMirror();
      await settleMicrotasks(4);
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'STOPPED',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: false,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(12);
      harness.rpcClient.emitRuntimeChanged(harness.rpcClient.snapshotValue, harness.rpcClient.contextValue);
      harness.rpcClient.contextValue = null;
      await settleMicrotasks(8);

      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');

      harness.runtimeMirror.bindDeferred.resolve();
      await initializePromise;

      expect(harness.runtimeMirror.bindSessions.join('>')).assertEqual('session-1');
      expect(harness.runtimeMirror.deactivateSessions.join('>')).assertEqual('session-1');
      expect(harness.registry.snapshot().state).assertEqual('STOPPED');
      expect(harness.eventLog.join('>')).assertEqual(
        'registry:STATE_CHANGED:AWAITING_CONSENT:session-1>registry:STATE_CHANGED:RECOVERING:session-1>mirror.bind:session-1>mirror.deactivate:session-1>registry:STOPPED:STOPPED:none'
      );
    });

    it('contextChangeDuringDeferredBindRebindsLatestContextAndPublishesLatestRunningSnapshot', 0, async () => {
      const harness = createHarness();
      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.registry.beginPending(request);
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContextWithDigest(13, '3333333333333333333333333333333333333333333333333333333333333333');
      harness.runtimeMirror.bindDeferred = new DeferredVoid();

      const initializePromise = harness.controller.initializeRuntimeMirror();
      await settleMicrotasks(4);
      harness.rpcClient.contextValue = createContextWithDigest(14, '4444444444444444444444444444444444444444444444444444444444444444');
      harness.rpcClient.emitRuntimeChanged(harness.rpcClient.snapshotValue, harness.rpcClient.contextValue);
      await settleMicrotasks(8);

      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');

      harness.runtimeMirror.bindDeferred.resolve();
      await initializePromise;

      expect(harness.runtimeMirror.bindSessions.join('>')).assertEqual('session-1>session-1');
      expect(harness.runtimeMirror.deactivateSessions.join('>')).assertEqual('session-1');
      expect(harness.registry.snapshot().state).assertEqual('RUNNING');
      expect(harness.registry.snapshot().activeRequest?.sessionId ?? '').assertEqual('session-1');
      expect(harness.eventLog.join('>')).assertEqual(
        'registry:STATE_CHANGED:AWAITING_CONSENT:session-1>registry:STATE_CHANGED:RECOVERING:session-1>mirror.bind:session-1>mirror.deactivate:session-1>mirror.bind:session-1>registry:STATE_CHANGED:RUNNING:session-1'
      );
    });

    it('bindFailureKeepsHydrationRecoveringAndDoesNotPublishStopped', 0, async () => {
      const harness = createHarness();
      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.registry.beginPending(request);
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(10);
      harness.runtimeMirror.bindError = new Error('bind failed');

      await harness.controller.initializeRuntimeMirror();

      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');
      expect(harness.runtimeMirror.bindSessions.length).assertEqual(0);
      expect(harness.registryLog.join('>')).assertEqual('STATE_CHANGED:AWAITING_CONSENT:session-1>STATE_CHANGED:RECOVERING:session-1');
    });

    it('initializeKnownRequestRetriesMirrorBindThenPublishesRunningAndCancelsRemainingTasks', 0, async () => {
      const harness = createHarness();
      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.registry.beginPending(request);
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(17);
      harness.runtimeMirror.scriptedBindErrors.push(new Error('bind-1'));
      harness.runtimeMirror.scriptedBindErrors.push(new Error('bind-2'));

      await harness.controller.initializeRuntimeMirror();

      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');
      expect(harness.scheduler.scheduledDelays.join('>')).assertEqual('250');

      await harness.scheduler.runNext();
      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');
      expect(harness.scheduler.scheduledDelays.join('>')).assertEqual('250>500');

      await harness.scheduler.runNext();
      expect(harness.registry.snapshot().state).assertEqual('RUNNING');
      expect(harness.runtimeMirror.bindSessions.join('>')).assertEqual('session-1');
      expect(harness.scheduler.pendingCount()).assertEqual(0);
    });

    it('initializeKnownRequestMirrorBindExhaustionPublishesReplayFailureWithoutStopping', 0, async () => {
      const harness = createHarness();
      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.registry.beginPending(request);
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(18);
      for (let index = 0; index < 6; index += 1) {
        harness.runtimeMirror.scriptedBindErrors.push(new Error(`bind-${index}`));
      }

      await harness.controller.initializeRuntimeMirror();
      for (let index = 0; index < 5; index += 1) {
        await harness.scheduler.runNext();
      }

      expect(harness.scheduler.scheduledDelays.join('>')).assertEqual('250>500>1000>2000>4000');
      expect(harness.registry.snapshot().state).assertEqual('ERROR');
      expect(harness.registry.snapshot().activeRequest?.sessionId ?? '').assertEqual('session-1');
      expect(harness.registry.currentSessionId() ?? '').assertEqual('session-1');
      expect(harness.registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_PROXY_REPLAY_FAILED');
      expect(harness.registryLog.join('>').includes('STOPPED:STOPPED')).assertFalse();
    });

    it('repeatedInitializeCallsDoNotStartAdditionalOneShotOrFullRecoveryAttempts', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.connectOnceError = new Error('one-shot unavailable');
      harness.rpcClient.connectDeferred = new DeferredVoid();

      await harness.controller.initializeRuntimeMirror();
      await harness.controller.initializeRuntimeMirror();

      expect(harness.rpcClient.connectOnceCalls).assertEqual(1);
      expect(harness.rpcClient.connectCalls).assertEqual(1);
      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');
    });

    it('concurrentInitializeCallsDoNotStartAdditionalOneShotAttemptsWhileHydrationIsActive', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.connectOnceDeferred = new DeferredVoid();

      const firstInitialize = harness.controller.initializeRuntimeMirror();
      await settleMicrotasks(4);
      const secondInitialize = harness.controller.initializeRuntimeMirror();
      const secondOutcome = await Promise.race([
        secondInitialize.then(() => 'resolved'),
        new TimeoutResult<string>('timeout', 20).promise
      ]);

      expect(secondOutcome).assertEqual('resolved');
      expect(harness.rpcClient.connectOnceCalls).assertEqual(1);
      expect(harness.rpcClient.connectCalls).assertEqual(0);
      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');

      harness.rpcClient.connectOnceDeferred.resolve();
      await firstInitialize;
    });

    it('runtimeChangedJoinDoesNotCreateAnotherBindWhileCompletionIsInFlight', 0, async () => {
      const harness = createHarness();
      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.registry.beginPending(request);
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(15);
      harness.runtimeMirror.bindDeferred = new DeferredVoid();

      const initializePromise = harness.controller.initializeRuntimeMirror();
      await settleMicrotasks(4);
      harness.rpcClient.emitRuntimeChanged(harness.rpcClient.snapshotValue, harness.rpcClient.contextValue);
      await settleMicrotasks(8);

      expect(harness.runtimeMirror.bindSessions.length).assertEqual(0);

      harness.runtimeMirror.bindDeferred.resolve();
      await initializePromise;

      expect(harness.runtimeMirror.bindSessions.join('>')).assertEqual('session-1');
      expect(harness.runtimeMirror.deactivateSessions.length).assertEqual(0);
    });

    it('steadyRuntimeChangedBeginsRecoveryUntilMirrorBindCompletesThenPublishesRunning', 0, async () => {
      const harness = createHarness();
      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.registry.beginPending(request);
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContextWithDigest(19, '5555555555555555555555555555555555555555555555555555555555555555');
      await harness.controller.initializeRuntimeMirror();
      harness.runtimeMirror.bindDeferred = new DeferredVoid();
      harness.rpcClient.contextValue = createContextWithDigest(20, '6666666666666666666666666666666666666666666666666666666666666666');

      const emitPromise = settleMicrotasks(0).then((): void => {
        harness.rpcClient.emitRuntimeChanged(harness.rpcClient.snapshotValue, harness.rpcClient.contextValue);
      });
      await emitPromise;
      await settleMicrotasks(8);

      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');

      harness.runtimeMirror.bindDeferred.resolve();
      await settleMicrotasks(16);

      expect(harness.registry.snapshot().state).assertEqual('RUNNING');
    });

    it('runningSnapshotWithoutKnownRequestStaysAnonymousAndDoesNotClaimProxyBind', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(11);

      await harness.controller.initializeRuntimeMirror();

      expect(harness.runtimeMirror.bindSessions.length).assertEqual(0);
      expect(harness.registry.snapshot().state).assertEqual('RUNNING');
      expect(harness.registry.snapshot().activeRequest).assertNull();
      expect(harness.registry.currentSessionId() === undefined).assertFalse();
    });

    it('disposeBeforeBackgroundRecoverySuccessPreventsLateBindAndAuthoritativePublish', 0, async () => {
      const harness = createHarness();
      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.registry.beginPending(request);
      harness.rpcClient.connectOnceError = new Error('one-shot unavailable');
      harness.rpcClient.connectDeferred = new DeferredVoid();
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(7);

      await harness.controller.initializeRuntimeMirror();
      await harness.controller.dispose();
      harness.rpcClient.connectDeferred.resolve();
      await settleMicrotasks(16);

      expect(harness.runtimeMirror.bindSessions.length).assertEqual(0);
      expect(harness.registryLog.join('>')).assertEqual('STATE_CHANGED:AWAITING_CONSENT:session-1>STATE_CHANGED:RECOVERING:session-1');
      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');
    });

    it('disposeDuringDeferredBindDeactivatesLateBoundSessionWithoutPublishing', 0, async () => {
      const harness = createHarness();
      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.registry.beginPending(request);
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(16);
      harness.runtimeMirror.bindDeferred = new DeferredVoid();

      const initializePromise = harness.controller.initializeRuntimeMirror();
      await settleMicrotasks(4);
      await harness.controller.dispose();
      harness.runtimeMirror.bindDeferred.resolve();
      await initializePromise;
      await settleMicrotasks(8);

      expect(harness.runtimeMirror.bindSessions.join('>')).assertEqual('session-1');
      expect(harness.runtimeMirror.deactivateSessions.join('>')).assertEqual('session-1>session-1');
      expect(harness.registry.snapshot().state).assertEqual('RECOVERING');
      expect(harness.eventLog.join('>')).assertEqual(
        'registry:STATE_CHANGED:AWAITING_CONSENT:session-1>registry:STATE_CHANGED:RECOVERING:session-1>mirror.deactivate:session-1>mirror.bind:session-1>mirror.deactivate:session-1'
      );
    });

    it('disposeCancelsScheduledMirrorRetry', 0, async () => {
      const harness = createHarness();
      const request = createVpnStartRequest('profile-1', 'version-1', 'session-1');
      harness.registry.beginPending(request);
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      harness.rpcClient.contextValue = createContext(21);
      harness.runtimeMirror.bindError = new Error('bind failed');

      await harness.controller.initializeRuntimeMirror();
      await harness.controller.dispose();

      expect(harness.scheduler.pendingCount()).assertEqual(0);
    });

    it('stopsViaRpcBeforeFinalSystemStop', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createRpcSnapshot('RUNNING');
      harness.rpcClient.contextValue = createContext(9);
      await harness.controller.initializeRuntimeMirror();
      harness.rpcClient.responses.push(createStopResponse(9, 'STOPPED'));

      const result = await harness.controller.stop();

      expect(result.kind).assertEqual('STOPPED');
      expect(harness.rpcClient.requests.length).assertEqual(1);
      expect(harness.rpcClient.requests[0].method).assertEqual('STOP_VPN');
      expect(harness.rpcClient.requests[0].sessionGeneration).assertEqual(9);
      expect(harness.api.stopCalls).assertEqual(1);
      expect(harness.registry.snapshot().state).assertEqual('STOPPED');
    });

    it('usesGenerationOneForAnonymousRunningContextOnFirstStopCommand', 0, async () => {
      const harness = createHarness();
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createRpcSnapshot('RUNNING');
      harness.rpcClient.contextValue = createContext(0);
      await harness.controller.initializeRuntimeMirror();
      harness.rpcClient.responses.push(createStopResponse(1, 'STOPPED'));

      await harness.controller.stop();

      expect(harness.rpcClient.requests[0].sessionGeneration).assertEqual(1);
      expect(harness.api.stopCalls).assertEqual(1);
    });

    it('fallsBackToSystemStopWhenRpcStopFailsAndSharesPendingStop', 0, async () => {
      const harness = createHarness();
      harness.api.deferStop = true;
      harness.rpcClient.stateValue = 'READY';
      harness.rpcClient.snapshotValue = createRpcSnapshot('RUNNING');
      harness.rpcClient.contextValue = createContext(4);
      await harness.controller.initializeRuntimeMirror();
      harness.rpcClient.responses.push(new Error('rpc disconnected'));

      let firstSettled = false;
      let secondSettled = false;
      const firstStop = harness.controller.stop().then((result) => {
        firstSettled = true;
        return result;
      });
      const secondStop = harness.controller.stop().then((result) => {
        secondSettled = true;
        return result;
      });
      await settleMicrotasks();

      expect(firstSettled).assertFalse();
      expect(secondSettled).assertFalse();
      expect(harness.api.stopCalls).assertEqual(1);
      harness.api.resolveDeferredStop();

      const firstResult = await firstStop;
      const secondResult = await secondStop;
      expect(firstResult.kind).assertEqual('STOPPED');
      expect(secondResult.kind).assertEqual('STOPPED');
      expect(harness.registry.snapshot().state).assertEqual('STOPPED');
    });

    it('rejectsBlankIdsAndConsentDenial', 0, async () => {
      const blankHarness = createHarness();
      const blank = await blankHarness.controller.start('profile-1', ' ', 'session-1');
      expectRejectedCode(blank, 'VPN_CONFIG_INVALID');

      const deniedHarness = createHarness();
      deniedHarness.api.setStartBusinessError(2203001, 'consent denied');
      const denied = await deniedHarness.controller.start('profile-1', 'version-1', 'session-1');
      expectRejectedCode(denied, 'VPN_PERMISSION_DENIED');
      expect(deniedHarness.registry.snapshot().state).assertEqual('STOPPED');
    });

    it('unsubscribesRpcListenerOnDispose', 0, async () => {
      const harness = createHarness();

      await harness.controller.dispose();
      await harness.controller.dispose();

      expect(harness.api.disposeCalls).assertEqual(1);
    });
  });
}
