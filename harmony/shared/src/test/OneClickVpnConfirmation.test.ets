import { describe, expect, it } from '@ohos/hypium';
import {
  type OneClickVpnConfirmationHandle,
  type OneClickVpnConfirmationResult,
  SubscriptionOneClickVpnConfirmation,
  createVpnRuntimeEvent,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  type BoundedDelaySchedulerPort,
  type CancelableDelayTask,
  type VpnControllerPort,
  type VpnControllerStartResult,
  type VpnControllerStopResult,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot,
  type VpnRuntimeState
} from '../../Index';

class ManualDelayTask implements CancelableDelayTask {
  readonly delayMs: number;
  cancelCount: number = 0;
  private readonly runner: () => Promise<void>;

  constructor(delayMs: number, runner: () => Promise<void>) {
    this.delayMs = delayMs;
    this.runner = runner;
  }

  cancel(): void {
    this.cancelCount += 1;
  }

  async run(): Promise<void> {
    await this.runner();
  }
}

class ManualScheduler implements BoundedDelaySchedulerPort {
  readonly tasks: ManualDelayTask[] = [];

  schedule(delayMs: number, runner: () => Promise<void>): CancelableDelayTask {
    const task = new ManualDelayTask(delayMs, runner);
    this.tasks.push(task);
    return task;
  }
}

class ThrowingScheduler implements BoundedDelaySchedulerPort {
  scheduleCalls: number = 0;

  schedule(_delayMs: number, _runner: () => Promise<void>): CancelableDelayTask {
    this.scheduleCalls += 1;
    throw new Error('scheduler failed');
  }
}

class SynchronousScheduler implements BoundedDelaySchedulerPort {
  readonly tasks: ManualDelayTask[] = [];

  schedule(delayMs: number, runner: () => Promise<void>): CancelableDelayTask {
    const task = new ManualDelayTask(delayMs, runner);
    this.tasks.push(task);
    void runner();
    return task;
  }
}

class FakeVpnController implements VpnControllerPort {
  readonly subscribeIds: number[] = [];
  readonly unsubscribeIds: number[] = [];
  private readonly listeners: Map<number, (event: VpnRuntimeEvent) => void> = new Map();
  private nextSubscriptionId: number = 1;
  private snapshotValue: VpnRuntimeSnapshot = buildSnapshot('STOPPED');

  async start(_profileId: string, _versionId: string, _sessionId: string): Promise<VpnControllerStartResult> {
    throw new Error('not used');
  }

  async stop(_sessionId?: string): Promise<VpnControllerStopResult> {
    throw new Error('not used');
  }

  snapshot(): VpnRuntimeSnapshot {
    return cloneSnapshot(this.snapshotValue);
  }

  subscribe(listener: (event: VpnRuntimeEvent) => void): number {
    const subscriptionId: number = this.nextSubscriptionId;
    this.nextSubscriptionId += 1;
    this.subscribeIds.push(subscriptionId);
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.unsubscribeIds.push(subscriptionId);
    this.listeners.delete(subscriptionId);
  }

  setSnapshot(snapshot: VpnRuntimeSnapshot): void {
    this.snapshotValue = cloneSnapshot(snapshot);
  }

  emit(snapshot: VpnRuntimeSnapshot, type: 'STATE_CHANGED' | 'FAILED' | 'STOPPED' = 'STATE_CHANGED'): void {
    this.snapshotValue = cloneSnapshot(snapshot);
    const event: VpnRuntimeEvent = createVpnRuntimeEvent(type, this.snapshotValue);
    const listeners: Array<(event: VpnRuntimeEvent) => void> = [];
    this.listeners.forEach((listener) => {
      listeners.push(listener);
    });
    for (let index = 0; index < listeners.length; index += 1) {
      listeners[index](createVpnRuntimeEvent(event.type, event.snapshot));
    }
  }
}

function cloneSnapshot(snapshot: VpnRuntimeSnapshot): VpnRuntimeSnapshot {
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

function buildSnapshot(
  state: VpnRuntimeState,
  sessionId?: string
): VpnRuntimeSnapshot {
  const activeRequest = sessionId === undefined || state === 'STOPPED'
    ? null
    : createVpnStartRequest('profile-1', 'version-1', sessionId);
  return createVpnRuntimeSnapshot({
    state,
    activeRequest,
    activeHandle: state === 'RUNNING' && sessionId !== undefined
      ? {
          sessionId,
          attached: true
        }
      : null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: state === 'RUNNING',
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure: state === 'ERROR'
      ? {
          code: 'VPN_CREATE_FAILED',
          detail: 'redacted'
        }
      : null
  });
}

async function settleMicrotasks(turns: number = 6): Promise<void> {
  for (let turn = 0; turn < turns; turn += 1) {
    await Promise.resolve();
  }
}

export default function oneClickVpnConfirmationTestsuite() {
  describe('OneClickVpnConfirmationTest', () => {
    it('capturesSynchronousRunningFromCurrentSnapshotWhenStartIsMarkedAccepted', 0, async () => {
      const controller = new FakeVpnController();
      controller.setSnapshot(buildSnapshot('RUNNING', 'session-1'));
      const scheduler = new ManualScheduler();
      const confirmation: SubscriptionOneClickVpnConfirmation = new SubscriptionOneClickVpnConfirmation(controller, scheduler);
      const handle: OneClickVpnConfirmationHandle = confirmation.arm('session-1', 5000);

      handle.markStartAccepted();
      const result: OneClickVpnConfirmationResult = await handle.wait();

      expect(result.kind).assertEqual('RUNNING');
      expect(controller.subscribeIds.length).assertEqual(1);
      expect(controller.unsubscribeIds.length).assertEqual(1);
      expect(scheduler.tasks.length).assertEqual(1);
      expect(scheduler.tasks[0].cancelCount).assertEqual(1);
    });

    it('subscribesBeforeStartCanEmitAndSettlesRunningExactlyOnce', 0, async () => {
      const controller = new FakeVpnController();
      const scheduler = new ManualScheduler();
      const confirmation: SubscriptionOneClickVpnConfirmation = new SubscriptionOneClickVpnConfirmation(controller, scheduler);
      const handle: OneClickVpnConfirmationHandle = confirmation.arm('session-1', 5000);

      expect(controller.subscribeIds.length).assertEqual(1);
      expect(controller.unsubscribeIds.length).assertEqual(0);
      expect(scheduler.tasks.length).assertEqual(1);

      controller.emit(buildSnapshot('RUNNING', 'session-1'));

      const result: OneClickVpnConfirmationResult = await handle.wait();
      expect(result.kind).assertEqual('RUNNING');
      expect(controller.unsubscribeIds.length).assertEqual(1);
      expect(scheduler.tasks[0].cancelCount).assertEqual(1);

      handle.markStartAccepted();
      controller.emit(buildSnapshot('STOPPED'), 'STOPPED');
      expect(controller.unsubscribeIds.length).assertEqual(1);
    });

    it('ignoresStoppedBeforeStartAcceptanceThenClosesStoppedAfterStartAccepted', 0, async () => {
      const controller = new FakeVpnController();
      const scheduler = new ManualScheduler();
      const confirmation: SubscriptionOneClickVpnConfirmation = new SubscriptionOneClickVpnConfirmation(controller, scheduler);
      const handle: OneClickVpnConfirmationHandle = confirmation.arm('session-1', 5000);
      let settled: boolean = false;
      const pending: Promise<OneClickVpnConfirmationResult> = handle.wait().then((result: OneClickVpnConfirmationResult) => {
        settled = true;
        return result;
      });

      controller.emit(buildSnapshot('STOPPED'), 'STOPPED');
      await settleMicrotasks();
      expect(settled).assertFalse();

      handle.markStartAccepted();

      const result: OneClickVpnConfirmationResult = await pending;
      expect(result.kind).assertEqual('STOPPED');
      expect(controller.unsubscribeIds.length).assertEqual(1);
      expect(scheduler.tasks[0].cancelCount).assertEqual(1);
    });

    it('closesErrorWithoutLeakingSessionIdsOrRawDetails', 0, async () => {
      const controller = new FakeVpnController();
      const scheduler = new ManualScheduler();
      const confirmation: SubscriptionOneClickVpnConfirmation = new SubscriptionOneClickVpnConfirmation(controller, scheduler);
      const handle: OneClickVpnConfirmationHandle = confirmation.arm('session-1', 5000);

      controller.emit(buildSnapshot('ERROR', 'session-1'), 'FAILED');

      const result: OneClickVpnConfirmationResult = await handle.wait();
      expect(result.kind).assertEqual('ERROR');
      expect(JSON.stringify(result)).assertEqual('{"kind":"ERROR"}');
      expect(controller.unsubscribeIds.length).assertEqual(1);
      expect(scheduler.tasks[0].cancelCount).assertEqual(1);
    });

    it('treatsAnotherLiveSessionAsSessionChanged', 0, async () => {
      const controller = new FakeVpnController();
      const scheduler = new ManualScheduler();
      const confirmation: SubscriptionOneClickVpnConfirmation = new SubscriptionOneClickVpnConfirmation(controller, scheduler);
      const handle: OneClickVpnConfirmationHandle = confirmation.arm('session-1', 5000);

      controller.emit(buildSnapshot('STARTING', 'session-2'));

      const result: OneClickVpnConfirmationResult = await handle.wait();
      expect(result.kind).assertEqual('SESSION_CHANGED');
      expect(controller.unsubscribeIds.length).assertEqual(1);
      expect(scheduler.tasks[0].cancelCount).assertEqual(1);
    });

    it('timesOutWithBalancedCleanupWhenNoTerminalEventArrives', 0, async () => {
      const controller = new FakeVpnController();
      const scheduler = new ManualScheduler();
      const confirmation: SubscriptionOneClickVpnConfirmation = new SubscriptionOneClickVpnConfirmation(controller, scheduler);
      const handle: OneClickVpnConfirmationHandle = confirmation.arm('session-1', 2500);

      expect(scheduler.tasks.length).assertEqual(1);
      await scheduler.tasks[0].run();

      const result: OneClickVpnConfirmationResult = await handle.wait();
      expect(result.kind).assertEqual('TIMEOUT');
      expect(controller.unsubscribeIds.length).assertEqual(1);
      expect(scheduler.tasks[0].cancelCount).assertEqual(1);

      controller.emit(buildSnapshot('RUNNING', 'session-1'));
      expect(controller.unsubscribeIds.length).assertEqual(1);
    });

    it('cancelsIdempotentlyAndWaitResolvesCancelled', 0, async () => {
      const controller = new FakeVpnController();
      const scheduler = new ManualScheduler();
      const confirmation: SubscriptionOneClickVpnConfirmation = new SubscriptionOneClickVpnConfirmation(controller, scheduler);
      const handle: OneClickVpnConfirmationHandle = confirmation.arm('session-1', 2500);

      handle.cancel();
      handle.cancel();

      const result: OneClickVpnConfirmationResult = await handle.wait();
      expect(result.kind).assertEqual('CANCELLED');
      expect(controller.unsubscribeIds.length).assertEqual(1);
      expect(scheduler.tasks[0].cancelCount).assertEqual(1);
    });

    it('rejectsInvalidTimeoutWithoutSubscribingOrScheduling', 0, () => {
      const controller = new FakeVpnController();
      const scheduler = new ManualScheduler();
      const confirmation: SubscriptionOneClickVpnConfirmation = new SubscriptionOneClickVpnConfirmation(controller, scheduler);

      let threw: boolean = false;
      try {
        confirmation.arm('session-1', 0);
      } catch (_error) {
        threw = true;
      }

      expect(threw).assertTrue();
      expect(controller.subscribeIds.length).assertEqual(0);
      expect(controller.unsubscribeIds.length).assertEqual(0);
      expect(scheduler.tasks.length).assertEqual(0);
    });

    it('cleansUpSubscriptionWhenSchedulerThrowsDuringArm', 0, () => {
      const controller = new FakeVpnController();
      const scheduler = new ThrowingScheduler();
      const confirmation: SubscriptionOneClickVpnConfirmation = new SubscriptionOneClickVpnConfirmation(controller, scheduler);

      let threw: boolean = false;
      try {
        confirmation.arm('session-1', 2500);
      } catch (_error) {
        threw = true;
      }

      expect(threw).assertTrue();
      expect(controller.subscribeIds.length).assertEqual(1);
      expect(controller.unsubscribeIds.length).assertEqual(1);
      expect(scheduler.scheduleCalls).assertEqual(1);
    });

    it('settlesTimeoutWhenSchedulerRunsSynchronouslyAndCancelsReturnedTaskExactlyOnce', 0, async () => {
      const controller = new FakeVpnController();
      const scheduler = new SynchronousScheduler();
      const confirmation: SubscriptionOneClickVpnConfirmation = new SubscriptionOneClickVpnConfirmation(controller, scheduler);
      const handle: OneClickVpnConfirmationHandle = confirmation.arm('session-1', 2500);

      const result: OneClickVpnConfirmationResult = await handle.wait();

      expect(result.kind).assertEqual('TIMEOUT');
      expect(controller.subscribeIds.length).assertEqual(1);
      expect(controller.unsubscribeIds.length).assertEqual(1);
      expect(scheduler.tasks.length).assertEqual(1);
      expect(scheduler.tasks[0].cancelCount).assertEqual(1);
    });
  });
}
