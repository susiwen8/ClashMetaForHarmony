import { describe, expect, it } from '@ohos/hypium';
import type {
  BoundedDelaySchedulerPort,
  CancelableDelayTask,
  ClockPort,
  VpnRpcTrafficCounters
} from '@cmfa/shared';
import {
  VpnTrafficNotificationCoordinator,
  VpnTrafficRateTracker,
  type VpnTrafficCounterSourcePort,
  type VpnTrafficNotificationSinkPort,
  type VpnTrafficRateSample
} from '../main/ets/vpn/VpnTrafficNotificationCoordinator';

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
type ScriptedSinkStep = Error | DeferredValue<void> | undefined;

interface TrafficUpdateRecord {
  sessionId: string;
  uploadBytesPerSecond: number;
  downloadBytesPerSecond: number;
}

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

class RecordingTrafficSink implements VpnTrafficNotificationSinkPort {
  readonly updates: TrafficUpdateRecord[] = [];
  private readonly steps: ScriptedSinkStep[] = [];

  queueError(error: Error): void {
    this.steps.push(error);
  }

  queueDeferred(): DeferredValue<void> {
    const deferred = new DeferredValue<void>();
    this.steps.push(deferred);
    return deferred;
  }

  async updateTraffic(
    sessionId: string,
    uploadBytesPerSecond: number,
    downloadBytesPerSecond: number
  ): Promise<void> {
    this.updates.push({
      sessionId,
      uploadBytesPerSecond,
      downloadBytesPerSecond
    });
    const step = this.steps.shift();
    if (step === undefined) {
      return;
    }
    if (step instanceof Error) {
      throw step;
    }
    await step.promise;
  }
}

function expectRateSample(
  sample: VpnTrafficRateSample,
  sessionId: string,
  uploadBytesPerSecond: number,
  downloadBytesPerSecond: number
): void {
  expect(sample.sessionId).assertEqual(sessionId);
  expect(sample.uploadBytesPerSecond).assertEqual(uploadBytesPerSecond);
  expect(sample.downloadBytesPerSecond).assertEqual(downloadBytesPerSecond);
}

function createReportStageCollector(target: string[]): (stage: string) => void {
  return (stage: string): void => {
    target.push(stage);
  };
}

async function settleMicrotasks(turns: number = 8): Promise<void> {
  for (let index = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

export default function vpnTrafficNotificationCoordinatorTestsuite() {
  describe('VpnTrafficNotificationCoordinatorTest', () => {
    it('trackerUsesZeroRatesForFirstSampleAndExactSecondDeltas', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      expectRateSample(tracker.sample('session-1', 1024, 2048, 1000), 'session-1', 0, 0);
      expectRateSample(tracker.sample('session-1', 4096, 6144, 2000), 'session-1', 3072, 4096);
    });

    it('trackerFloorsRatesForPartialSecondElapsed', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      tracker.sample('session-1', 0, 0, 500);
      expectRateSample(tracker.sample('session-1', 1536, 3072, 1012), 'session-1', 3000, 6000);
    });

    it('trackerResetsBaselineWhenSessionChanges', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      tracker.sample('session-1', 100, 200, 1000);
      expectRateSample(tracker.sample('session-2', 700, 900, 1500), 'session-2', 0, 0);
      expectRateSample(tracker.sample('session-2', 900, 1500, 2500), 'session-2', 200, 600);
    });

    it('trackerResetsBaselineWhenCountersRollbackOrTimeStops', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      tracker.sample('session-1', 1000, 2000, 1000);
      expectRateSample(tracker.sample('session-1', 900, 2100, 2000), 'session-1', 0, 0);
      expectRateSample(tracker.sample('session-1', 1100, 2200, 3000), 'session-1', 200, 100);

      expectRateSample(tracker.sample('session-1', 1200, 2300, 3000), 'session-1', 0, 0);
      expectRateSample(tracker.sample('session-1', 1500, 2600, 3500), 'session-1', 600, 600);
    });

    it('trackerClearsBaselineForInvalidInputUntilNextValidBaseline', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      tracker.sample('session-1', 100, 200, 1000);
      expectRateSample(tracker.sample('session-1', -1, 250, 2000), 'session-1', 0, 0);
      expectRateSample(tracker.sample('session-1', 300, 500, 3000), 'session-1', 0, 0);
      expectRateSample(tracker.sample('session-1', 600, 1100, 4000), 'session-1', 300, 600);
    });

    it('trackerResetDropsPreviousBaseline', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      tracker.sample('session-1', 100, 200, 1000);
      tracker.reset();
      expectRateSample(tracker.sample('session-1', 400, 800, 2000), 'session-1', 0, 0);
    });

    it('trackerClampsRatesToSafeIntegers', 0, () => {
      const tracker = new VpnTrafficRateTracker();

      tracker.sample('session-1', 0, 0, 1000);
      expectRateSample(
        tracker.sample('session-1', Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, 1001),
        'session-1',
        Number.MAX_SAFE_INTEGER,
        Number.MAX_SAFE_INTEGER
      );
    });

    it('startCreatesSingleLoopAndIgnoresDuplicateStartForSameSession', 0, () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(source, sink, clock, scheduler);

      coordinator.start('session-1');
      coordinator.start('session-1');

      expect(scheduler.scheduledDelays).assertDeepEquals([0]);
      expect(scheduler.pendingCount()).assertEqual(1);
    });

    it('startScheduleFailureRollsBackSoSameSessionCanRetry', 0, () => {
      const clock = new ManualClock(1000);
      const scheduler = new ThrowingScheduler(1);
      const source = new ScriptedTrafficSource();
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(source, sink, clock, scheduler);

      coordinator.start('session-1');
      coordinator.start('session-1');

      expect(scheduler.scheduledDelays).assertDeepEquals([0]);
      expect(scheduler.pendingCount()).assertEqual(1);
      expect(source.calls.length).assertEqual(0);
      expect(sink.updates.length).assertEqual(0);
    });

    it('tickWaitsForSinkCompletionBeforeSchedulingTheNextRun', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(source, sink, clock, scheduler);
      const sinkDeferred = sink.queueDeferred();
      source.queueValue(128, 256);

      coordinator.start('session-1');
      const runningTick = scheduler.runNext();
      await settleMicrotasks();

      expect(source.calls.length).assertEqual(1);
      expect(sink.updates.length).assertEqual(1);
      expect(scheduler.scheduledDelays).assertDeepEquals([0]);

      sinkDeferred.resolve(undefined);
      await runningTick;

      expect(scheduler.scheduledDelays).assertDeepEquals([0, 1000]);
      expect(scheduler.pendingCount()).assertEqual(1);
    });

    it('sourceFailurePublishesZeroAndRetriesFromAFreshBaseline', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(source, sink, clock, scheduler);

      source.queueError(new Error('rpc unavailable'));
      source.queueValue(400, 800);
      source.queueValue(1000, 1800);

      coordinator.start('session-1');

      await scheduler.runNext();
      clock.setNow(2000);
      await scheduler.runNext();
      clock.setNow(3000);
      await scheduler.runNext();

      expect(sink.updates).assertDeepEquals([
        { sessionId: 'session-1', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 },
        { sessionId: 'session-1', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 },
        { sessionId: 'session-1', uploadBytesPerSecond: 600, downloadBytesPerSecond: 1000 }
      ]);
    });

    it('sinkFailureDoesNotStopFutureTicks', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(source, sink, clock, scheduler);

      source.queueValue(0, 0);
      source.queueValue(2048, 4096);
      sink.queueError(new Error('notification publish failed'));

      coordinator.start('session-1');

      await scheduler.runNext();
      clock.setNow(2000);
      await scheduler.runNext();

      expect(sink.updates).assertDeepEquals([
        { sessionId: 'session-1', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 },
        { sessionId: 'session-1', uploadBytesPerSecond: 2048, downloadBytesPerSecond: 4096 }
      ]);
      expect(scheduler.pendingCount()).assertEqual(1);
    });

    it('rescheduleFailureStopsGenerationWithoutSourceFailureFallbackAndAllowsRetry', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ThrowingScheduler(2);
      const source = new ScriptedTrafficSource();
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(source, sink, clock, scheduler);

      source.queueValue(128, 256);
      source.queueValue(1152, 2304);

      coordinator.start('session-1');
      await scheduler.runNext();

      expect(source.calls.length).assertEqual(1);
      expect(sink.updates).assertDeepEquals([
        { sessionId: 'session-1', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 }
      ]);
      expect(scheduler.scheduledDelays).assertDeepEquals([0]);
      expect(scheduler.pendingCount()).assertEqual(0);

      clock.setNow(2000);
      coordinator.start('session-1');
      await scheduler.runNext();

      expect(source.calls.length).assertEqual(2);
      expect(sink.updates).assertDeepEquals([
        { sessionId: 'session-1', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 },
        { sessionId: 'session-1', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 }
      ]);
      expect(scheduler.scheduledDelays).assertDeepEquals([0, 0, 1000]);
    });

    it('stopDuringSourceAwaitPreventsLateUpdateAndReschedule', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(source, sink, clock, scheduler);
      const sourceDeferred = source.queueDeferred();

      coordinator.start('session-1');
      const runningTick = scheduler.runNext();
      await settleMicrotasks();

      coordinator.stop('session-1');
      sourceDeferred.resolve({
        txBytes: 300,
        rxBytes: 900
      });
      await runningTick;

      expect(sink.updates.length).assertEqual(0);
      expect(scheduler.scheduledDelays).assertDeepEquals([0]);
      expect(scheduler.pendingCount()).assertEqual(0);
    });

    it('sessionSwitchCancelsOldGenerationAndStartsFreshLoop', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(source, sink, clock, scheduler);
      const firstSessionSource = source.queueDeferred();
      source.queueValue(500, 700);

      coordinator.start('session-1');
      const firstTick = scheduler.runNext();
      await settleMicrotasks();

      coordinator.start('session-2');
      firstSessionSource.resolve({
        txBytes: 200,
        rxBytes: 400
      });
      await firstTick;

      clock.setNow(2000);
      await scheduler.runNext();

      expect(sink.updates).assertDeepEquals([
        { sessionId: 'session-2', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 }
      ]);
      expect(scheduler.scheduledDelays).assertDeepEquals([0, 0, 1000]);
    });

    it('disposeDuringSinkAwaitCancelsFollowUpScheduling', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(source, sink, clock, scheduler);
      const sinkDeferred = sink.queueDeferred();
      source.queueValue(1024, 2048);

      coordinator.start('session-1');
      const runningTick = scheduler.runNext();
      await settleMicrotasks();

      coordinator.dispose();
      sinkDeferred.resolve(undefined);
      await runningTick;

      expect(sink.updates).assertDeepEquals([
        { sessionId: 'session-1', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 }
      ]);
      expect(scheduler.scheduledDelays).assertDeepEquals([0]);
      expect(scheduler.pendingCount()).assertEqual(0);
    });

    it('reportsTrafficDiagnosticStagesOnlyOnTransitionsAndReplaysAfterSourceFailureReset', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const sink = new RecordingTrafficSink();
      const reportStages: string[] = [];
      const coordinator = new VpnTrafficNotificationCoordinator(
        source,
        sink,
        clock,
        scheduler,
        createReportStageCollector(reportStages)
      );

      source.queueValue(0, 0);
      source.queueValue(1024, 2048);
      source.queueValue(2048, 4096);
      source.queueError(new Error('refresh failed'));
      source.queueValue(4096, 8192);

      coordinator.start('session-1');
      await scheduler.runNext();
      clock.setNow(2000);
      await scheduler.runNext();
      clock.setNow(3000);
      await scheduler.runNext();
      clock.setNow(4000);
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
        'notification.traffic.rate-zero'
      ]);
    });

    it('startResetsTrafficDiagnosticTransitionsForTheNextSession', 0, async () => {
      const clock = new ManualClock(1000);
      const scheduler = new ManualScheduler();
      const source = new ScriptedTrafficSource();
      const sink = new RecordingTrafficSink();
      const reportStages: string[] = [];
      const coordinator = new VpnTrafficNotificationCoordinator(
        source,
        sink,
        clock,
        scheduler,
        createReportStageCollector(reportStages)
      );

      source.queueValue(0, 0);
      source.queueValue(0, 0);

      coordinator.start('session-1');
      await scheduler.runNext();

      coordinator.start('session-2');
      clock.setNow(2000);
      await scheduler.runNext();

      expect(reportStages).assertDeepEquals([
        'notification.traffic.source-ok',
        'notification.traffic.counters-zero',
        'notification.traffic.rate-zero',
        'notification.traffic.source-ok',
        'notification.traffic.counters-zero',
        'notification.traffic.rate-zero'
      ]);
    });
  });
}
