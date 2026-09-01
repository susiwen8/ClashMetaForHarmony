import { describe, expect, it } from '@ohos/hypium';
import type {
  BoundedDelaySchedulerPort,
  CancelableDelayTask,
  ClockPort,
  VpnRpcTrafficCounters
} from '@cmfa/shared';
import {
  VpnTrafficMonitor,
  VpnTrafficRateTracker,
  type VpnTrafficCounterSourcePort,
  type VpnTrafficMonitorSnapshot
} from '../main/ets/vpn/VpnTrafficMonitor';

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private resolveRef?: (value: T) => void;
  private rejectRef?: (error: Error) => void;

  constructor() {
    this.promise = new Promise<T>((resolve, reject) => {
      this.resolveRef = resolve;
      this.rejectRef = reject;
    });
  }

  resolve(value: T): void {
    this.resolveRef?.(value);
  }

  reject(error: Error): void {
    this.rejectRef?.(error);
  }
}

class ManualClock implements ClockPort {
  private nowValue: number;

  constructor(nowMs: number = 0) {
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
    for (let index: number = 0; index < this.tasks.length; index += 1) {
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

class ThrowingScheduler extends ManualScheduler {
  private readonly throwOnCalls: number[];
  private callCount: number = 0;

  constructor(...throwOnCalls: number[]) {
    super();
    this.throwOnCalls = throwOnCalls.slice();
  }

  schedule(delayMs: number, runner: () => Promise<void>): CancelableDelayTask {
    this.callCount += 1;
    if (this.throwOnCalls.includes(this.callCount)) {
      throw new Error(`schedule failed:${this.callCount}`);
    }
    return super.schedule(delayMs, runner);
  }
}

type ScriptedSourceStep = VpnRpcTrafficCounters | Error | DeferredValue<VpnRpcTrafficCounters>;

class ScriptedTrafficSource implements VpnTrafficCounterSourcePort {
  readonly calls: number[] = [];
  private readonly steps: ScriptedSourceStep[] = [];

  queueValue(txBytes: number, rxBytes: number): void {
    this.steps.push({
      txBytes,
      rxBytes
    });
  }

  queueError(error: Error): void {
    this.steps.push(error);
  }

  queueDeferred(): DeferredValue<VpnRpcTrafficCounters> {
    const deferred = new DeferredValue<VpnRpcTrafficCounters>();
    this.steps.push(deferred);
    return deferred;
  }

  async refreshTrafficCounters(): Promise<VpnRpcTrafficCounters> {
    this.calls.push(this.calls.length + 1);
    const step = this.steps.shift();
    if (step === undefined) {
      return {
        txBytes: 0,
        rxBytes: 0
      };
    }
    if (step instanceof Error) {
      throw step;
    }
    if (step instanceof DeferredValue) {
      return await step.promise;
    }
    return {
      txBytes: step.txBytes,
      rxBytes: step.rxBytes
    };
  }
}

function expectSnapshot(
  snapshot: VpnTrafficMonitorSnapshot,
  available: boolean,
  txBytes: number,
  rxBytes: number,
  uploadBytesPerSecond: number,
  downloadBytesPerSecond: number
): void {
  expect(snapshot.available).assertEqual(available);
  expect(snapshot.txBytes).assertEqual(txBytes);
  expect(snapshot.rxBytes).assertEqual(rxBytes);
  expect(snapshot.uploadBytesPerSecond).assertEqual(uploadBytesPerSecond);
  expect(snapshot.downloadBytesPerSecond).assertEqual(downloadBytesPerSecond);
}

function createReportStageCollector(target: string[]): (stage: string) => void {
  return (stage: string): void => {
    target.push(stage);
  };
}

async function settleMicrotasks(turns: number = 8): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

export default function vpnTrafficMonitorTestsuite() {
  describe('VpnTrafficMonitorTest', () => {
    it('trackerUsesZeroRatesForFirstSampleAndExactSecondDeltas', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      expectSnapshot(tracker.sample(1024, 2048, 1000), true, 1024, 2048, 0, 0);
      expectSnapshot(tracker.sample(4096, 6144, 2000), true, 4096, 6144, 3072, 4096);
    });

    it('trackerFloorsRatesForPartialSecondElapsed', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      tracker.sample(0, 0, 500);
      expectSnapshot(tracker.sample(1536, 3072, 1012), true, 1536, 3072, 3000, 6000);
    });

    it('trackerResetsBaselineWhenCountersRollbackOrTimeStops', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      tracker.sample(1000, 2000, 1000);
      expectSnapshot(tracker.sample(900, 2100, 2000), true, 900, 2100, 0, 0);
      expectSnapshot(tracker.sample(1100, 2200, 3000), true, 1100, 2200, 200, 100);

      expectSnapshot(tracker.sample(1200, 2300, 3000), true, 1200, 2300, 0, 0);
      expectSnapshot(tracker.sample(1500, 2600, 3500), true, 1500, 2600, 600, 600);
    });

    it('trackerClearsBaselineForInvalidInputUntilNextValidBaseline', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      tracker.sample(100, 200, 1000);
      expectSnapshot(tracker.sample(-1, 250, 2000), false, 0, 0, 0, 0);
      expectSnapshot(tracker.sample(300, 500, 3000), true, 300, 500, 0, 0);
      expectSnapshot(tracker.sample(600, 1100, 4000), true, 600, 1100, 300, 600);
    });

    it('trackerResetDropsPreviousBaseline', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      tracker.sample(100, 200, 1000);
      tracker.reset();
      expectSnapshot(tracker.sample(400, 800, 2000), true, 400, 800, 0, 0);
    });

    it('trackerClampsRatesToSafeIntegers', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      tracker.sample(0, 0, 1000);
      expectSnapshot(
        tracker.sample(Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, 1001),
        true,
        Number.MAX_SAFE_INTEGER,
        Number.MAX_SAFE_INTEGER,
        Number.MAX_SAFE_INTEGER,
        Number.MAX_SAFE_INTEGER
      );
    });

    it('startCreatesSingleLoopAndIgnoresDuplicateStartForSameSession', 0, () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const monitor = new VpnTrafficMonitor(source, clock, scheduler);

      monitor.start('session-1');
      monitor.start('session-1');

      expect(scheduler.scheduledDelays).assertDeepEquals([0]);
      expect(scheduler.pendingCount()).assertEqual(1);
    });

    it('startScheduleFailureRollsBackSoSameSessionCanRetry', 0, () => {
      const clock = new ManualClock(1000);
      const scheduler = new ThrowingScheduler(1);
      const source = new ScriptedTrafficSource();
      const monitor = new VpnTrafficMonitor(source, clock, scheduler);

      monitor.start('session-1');
      monitor.start('session-1');

      expect(scheduler.scheduledDelays.length).assertEqual(0);
      expect(source.calls.length).assertEqual(0);
    });

    it('tickWaitsForPublishCompletionBeforeSchedulingTheNextRun', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const monitor = new VpnTrafficMonitor(source, clock, scheduler);
      const published: VpnTrafficMonitorSnapshot[] = [];
      const publishedDeferred = new DeferredValue<void>();
      monitor.subscribe(async (snapshot: VpnTrafficMonitorSnapshot): Promise<void> => {
        published.push(snapshot);
        if (published.length === 1) {
          await publishedDeferred.promise;
        }
      });
      source.queueValue(128, 256);

      monitor.start('session-1');
      const runningTick = scheduler.runNext();
      await settleMicrotasks();

      expect(source.calls.length).assertEqual(1);
      expect(published.length).assertEqual(1);
      expect(scheduler.scheduledDelays).assertDeepEquals([0]);

      publishedDeferred.resolve(undefined);
      await runningTick;

      expect(scheduler.scheduledDelays).assertDeepEquals([0, 1000]);
      expect(scheduler.pendingCount()).assertEqual(1);
    });

    it('listenerFailureDoesNotReportSourceFailureOrResetBaselineForOtherSubscribers', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const reportStages: string[] = [];
      const monitor = new VpnTrafficMonitor(
        source,
        clock,
        scheduler,
        createReportStageCollector(reportStages)
      );
      const healthySnapshots: VpnTrafficMonitorSnapshot[] = [];
      let rejectingListenerCalls: number = 0;

      monitor.subscribe(async (_snapshot: VpnTrafficMonitorSnapshot): Promise<void> => {
        rejectingListenerCalls += 1;
        if (rejectingListenerCalls === 1) {
          throw new Error('listener failed');
        }
      });
      monitor.subscribe((snapshot: VpnTrafficMonitorSnapshot): void => {
        healthySnapshots.push(snapshot);
      });
      source.queueValue(1024, 2048);
      source.queueValue(3072, 6144);

      monitor.start('session-1');
      await scheduler.runNext();
      clock.setNow(2000);
      await scheduler.runNext();

      expect(rejectingListenerCalls).assertEqual(2);
      expect(healthySnapshots.length).assertEqual(2);
      expectSnapshot(healthySnapshots[0], true, 1024, 2048, 0, 0);
      expectSnapshot(healthySnapshots[1], true, 3072, 6144, 2048, 4096);
      expect(reportStages).assertDeepEquals([
        'notification.traffic.source-ok',
        'notification.traffic.counters-nonzero',
        'notification.traffic.rate-zero',
        'notification.traffic.rate-nonzero'
      ]);
      expect(scheduler.scheduledDelays).assertDeepEquals([0, 1000, 1000]);
    });

    it('sourceFailurePublishesUnavailableZeroRatesAndRetriesFromAFreshBaseline', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const monitor = new VpnTrafficMonitor(source, clock, scheduler);
      const snapshots: VpnTrafficMonitorSnapshot[] = [];
      monitor.subscribe((snapshot: VpnTrafficMonitorSnapshot): void => {
        snapshots.push(snapshot);
      });

      source.queueValue(400, 800);
      source.queueError(new Error('rpc unavailable'));
      source.queueValue(1000, 1800);
      source.queueValue(1600, 2800);

      monitor.start('session-1');

      await scheduler.runNext();
      clock.setNow(2000);
      await scheduler.runNext();
      clock.setNow(3000);
      await scheduler.runNext();
      clock.setNow(4000);
      await scheduler.runNext();

      expectSnapshot(snapshots[0], true, 400, 800, 0, 0);
      expectSnapshot(snapshots[1], false, 400, 800, 0, 0);
      expectSnapshot(snapshots[2], true, 1000, 1800, 0, 0);
      expectSnapshot(snapshots[3], true, 1600, 2800, 600, 1000);
    });

    it('rescheduleFailureStopsGenerationWithoutFallbackAndAllowsRetry', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ThrowingScheduler(2);
      const source = new ScriptedTrafficSource();
      const monitor = new VpnTrafficMonitor(source, clock, scheduler);
      const snapshots: VpnTrafficMonitorSnapshot[] = [];
      monitor.subscribe((snapshot: VpnTrafficMonitorSnapshot): void => {
        snapshots.push(snapshot);
      });

      source.queueValue(128, 256);
      source.queueValue(1152, 2304);

      monitor.start('session-1');
      await scheduler.runNext();

      expect(source.calls.length).assertEqual(1);
      expectSnapshot(snapshots[0], true, 128, 256, 0, 0);
      expect(scheduler.scheduledDelays).assertDeepEquals([0]);
      expect(scheduler.pendingCount()).assertEqual(0);

      clock.setNow(2000);
      monitor.start('session-1');
      await scheduler.runNext();

      expect(source.calls.length).assertEqual(2);
      expectSnapshot(snapshots[1], true, 1152, 2304, 0, 0);
      expect(scheduler.scheduledDelays).assertDeepEquals([0, 0, 1000]);
    });

    it('markRecoveringKeepsTotalsPublishesUnavailableAndRestartsFromZeroRatesWhenRunningResumes', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const monitor = new VpnTrafficMonitor(source, clock, scheduler);
      const snapshots: VpnTrafficMonitorSnapshot[] = [];
      monitor.subscribe((snapshot: VpnTrafficMonitorSnapshot): void => {
        snapshots.push(snapshot);
      });

      source.queueValue(2048, 4096);
      source.queueValue(3072, 6144);

      monitor.start('session-1');
      await scheduler.runNext();
      monitor.markRecovering('session-1');
      clock.setNow(2000);
      monitor.start('session-1');
      await scheduler.runNext();

      expectSnapshot(snapshots[0], true, 2048, 4096, 0, 0);
      expectSnapshot(snapshots[1], false, 2048, 4096, 0, 0);
      expectSnapshot(snapshots[2], true, 3072, 6144, 0, 0);
    });

    it('stopDuringSourceAwaitPreventsLatePublishAndReschedule', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const monitor = new VpnTrafficMonitor(source, clock, scheduler);
      const sourceDeferred = source.queueDeferred();
      const snapshots: VpnTrafficMonitorSnapshot[] = [];
      monitor.subscribe((snapshot: VpnTrafficMonitorSnapshot): void => {
        snapshots.push(snapshot);
      });

      monitor.start('session-1');
      const runningTick = scheduler.runNext();
      await settleMicrotasks();

      monitor.stop('session-1');
      sourceDeferred.resolve({
        txBytes: 300,
        rxBytes: 900
      });
      await runningTick;

      expect(snapshots.length).assertEqual(1);
      expectSnapshot(snapshots[0], false, 0, 0, 0, 0);
      expect(scheduler.scheduledDelays).assertDeepEquals([0]);
      expect(scheduler.pendingCount()).assertEqual(0);
    });

    it('sessionSwitchCancelsOldGenerationAndStartsFreshLoop', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const monitor = new VpnTrafficMonitor(source, clock, scheduler);
      const firstSessionSource = source.queueDeferred();
      const snapshots: VpnTrafficMonitorSnapshot[] = [];
      monitor.subscribe((snapshot: VpnTrafficMonitorSnapshot): void => {
        snapshots.push(snapshot);
      });
      source.queueValue(500, 700);

      monitor.start('session-1');
      const firstTick = scheduler.runNext();
      await settleMicrotasks();

      monitor.start('session-2');
      firstSessionSource.resolve({
        txBytes: 200,
        rxBytes: 400
      });
      await firstTick;

      clock.setNow(2000);
      await scheduler.runNext();

      expect(snapshots.length).assertEqual(2);
      expectSnapshot(snapshots[0], false, 0, 0, 0, 0);
      expectSnapshot(snapshots[1], true, 500, 700, 0, 0);
      expect(scheduler.scheduledDelays).assertDeepEquals([0, 0, 1000]);
    });

    it('disposeDuringPublishAwaitCancelsFollowUpScheduling', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const monitor = new VpnTrafficMonitor(source, clock, scheduler);
      const publishedDeferred = new DeferredValue<void>();
      source.queueValue(1024, 2048);
      monitor.subscribe(async (_snapshot: VpnTrafficMonitorSnapshot): Promise<void> => {
        await publishedDeferred.promise;
      });

      monitor.start('session-1');
      const runningTick = scheduler.runNext();
      await settleMicrotasks();

      monitor.dispose();
      publishedDeferred.resolve(undefined);
      await runningTick;

      expect(scheduler.scheduledDelays).assertDeepEquals([0]);
      expect(scheduler.pendingCount()).assertEqual(0);
    });

    it('reportsTrafficDiagnosticStagesOnlyOnTransitionsAndReplaysAfterRecoveringReset', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const reportStages: string[] = [];
      const monitor = new VpnTrafficMonitor(
        source,
        clock,
        scheduler,
        createReportStageCollector(reportStages)
      );

      source.queueValue(0, 0);
      source.queueValue(1024, 2048);
      source.queueValue(2048, 4096);
      source.queueError(new Error('refresh failed'));
      source.queueValue(4096, 8192);

      monitor.start('session-1');
      await scheduler.runNext();
      clock.setNow(2000);
      await scheduler.runNext();
      clock.setNow(3000);
      await scheduler.runNext();
      monitor.markRecovering('session-1');
      clock.setNow(4000);
      monitor.start('session-1');
      await scheduler.runNext();
      clock.setNow(5000);
      await scheduler.runNext();

      expect(reportStages).assertDeepEquals([
        'notification.traffic.source-ok',
        'notification.traffic.counters-zero',
        'notification.traffic.rate-zero',
        'notification.traffic.counters-nonzero',
        'notification.traffic.rate-nonzero',
        'notification.traffic.source-failed',
        'notification.traffic.source-ok',
        'notification.traffic.counters-nonzero',
        'notification.traffic.rate-zero',
        'notification.traffic.rate-nonzero'
      ]);
    });
  });
}
