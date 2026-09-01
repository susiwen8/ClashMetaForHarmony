import type {
  BoundedDelaySchedulerPort,
  CancelableDelayTask,
  ClockPort,
  VpnRpcTrafficCounters
} from '@cmfa/shared';

export interface VpnTrafficCounterSourcePort {
  refreshTrafficCounters(): Promise<VpnRpcTrafficCounters>;
}

export interface VpnTrafficNotificationSinkPort {
  updateTraffic(
    sessionId: string,
    uploadBytesPerSecond: number,
    downloadBytesPerSecond: number
  ): Promise<void>;
}

export interface VpnTrafficRateSample {
  sessionId: string;
  uploadBytesPerSecond: number;
  downloadBytesPerSecond: number;
}

type VpnTrafficDiagnosticStage =
  | 'notification.traffic.source-ok'
  | 'notification.traffic.source-failed'
  | 'notification.traffic.counters-zero'
  | 'notification.traffic.counters-nonzero'
  | 'notification.traffic.rate-zero'
  | 'notification.traffic.rate-nonzero';

interface VpnTrafficRateBaseline {
  sessionId: string;
  txBytes: number;
  rxBytes: number;
  nowMs: number;
}

class VpnTrafficRateSampleValue implements VpnTrafficRateSample {
  sessionId: string = '';
  uploadBytesPerSecond: number = 0;
  downloadBytesPerSecond: number = 0;
}

function createRateSample(
  sessionId: string,
  uploadBytesPerSecond: number,
  downloadBytesPerSecond: number
): VpnTrafficRateSample {
  const sample = new VpnTrafficRateSampleValue();
  sample.sessionId = sessionId;
  sample.uploadBytesPerSecond = uploadBytesPerSecond;
  sample.downloadBytesPerSecond = downloadBytesPerSecond;
  return sample;
}

function isValidSessionId(sessionId: string): boolean {
  return sessionId.length > 0;
}

function isValidCounter(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function isValidTimestamp(nowMs: number): boolean {
  return Number.isSafeInteger(nowMs) && nowMs >= 0;
}

function clampToSafeRate(value: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    return 0;
  }
  if (value >= Number.MAX_SAFE_INTEGER) {
    return Number.MAX_SAFE_INTEGER;
  }
  return Math.floor(value);
}

function computeBytesPerSecond(deltaBytes: number, elapsedMs: number): number {
  if (deltaBytes <= 0 || elapsedMs <= 0) {
    return 0;
  }
  const wholeBytesPerMs: number = Math.floor(deltaBytes / elapsedMs);
  const maxWholeBytesPerMs: number = Math.floor(Number.MAX_SAFE_INTEGER / 1000);
  if (wholeBytesPerMs > maxWholeBytesPerMs) {
    return Number.MAX_SAFE_INTEGER;
  }
  const remainderBytes: number = deltaBytes % elapsedMs;
  const scaled: number = wholeBytesPerMs * 1000 + Math.floor((remainderBytes * 1000) / elapsedMs);
  return clampToSafeRate(scaled);
}

function isNonZeroCounters(counters: VpnRpcTrafficCounters): boolean {
  return counters.txBytes > 0 || counters.rxBytes > 0;
}

function isNonZeroRate(sample: VpnTrafficRateSample): boolean {
  return sample.uploadBytesPerSecond > 0 || sample.downloadBytesPerSecond > 0;
}

export class VpnTrafficRateTracker {
  private baseline?: VpnTrafficRateBaseline;

  sample(sessionId: string, txBytes: number, rxBytes: number, nowMs: number): VpnTrafficRateSample {
    if (!isValidSessionId(sessionId) || !isValidCounter(txBytes) || !isValidCounter(rxBytes) || !isValidTimestamp(nowMs)) {
      this.reset();
      return createRateSample(sessionId, 0, 0);
    }

    const nextBaseline: VpnTrafficRateBaseline = {
      sessionId,
      txBytes,
      rxBytes,
      nowMs
    };
    const previousBaseline = this.baseline;
    this.baseline = nextBaseline;

    if (previousBaseline === undefined || previousBaseline.sessionId !== sessionId) {
      return createRateSample(sessionId, 0, 0);
    }
    if (txBytes < previousBaseline.txBytes || rxBytes < previousBaseline.rxBytes || nowMs <= previousBaseline.nowMs) {
      return createRateSample(sessionId, 0, 0);
    }

    return createRateSample(
      sessionId,
      computeBytesPerSecond(txBytes - previousBaseline.txBytes, nowMs - previousBaseline.nowMs),
      computeBytesPerSecond(rxBytes - previousBaseline.rxBytes, nowMs - previousBaseline.nowMs)
    );
  }

  reset(): void {
    this.baseline = undefined;
  }
}

export class VpnTrafficNotificationCoordinator {
  private readonly source: VpnTrafficCounterSourcePort;
  private readonly sink: VpnTrafficNotificationSinkPort;
  private readonly clock: ClockPort;
  private readonly scheduler: BoundedDelaySchedulerPort;
  private readonly reportStage?: (stage: string) => void;
  private readonly tracker: VpnTrafficRateTracker = new VpnTrafficRateTracker();
  private generation: number = 0;
  private activeSessionId?: string;
  private scheduledTask?: CancelableDelayTask;
  private disposed: boolean = false;
  private sourceHealthy?: boolean;
  private countersNonZero?: boolean;
  private rateNonZero?: boolean;

  constructor(
    source: VpnTrafficCounterSourcePort,
    sink: VpnTrafficNotificationSinkPort,
    clock: ClockPort,
    scheduler: BoundedDelaySchedulerPort,
    reportStage?: (stage: string) => void
  ) {
    this.source = source;
    this.sink = sink;
    this.clock = clock;
    this.scheduler = scheduler;
    this.reportStage = reportStage;
  }

  start(sessionId: string): void {
    if (this.disposed || !isValidSessionId(sessionId)) {
      return;
    }
    if (this.activeSessionId === sessionId) {
      return;
    }
    const previousGeneration = this.generation;
    this.cancelScheduledTask();
    this.tracker.reset();
    this.resetTransitionStates();
    this.generation += 1;
    this.activeSessionId = sessionId;
    if (!this.scheduleNextTick(sessionId, this.generation, 0)) {
      this.tracker.reset();
      this.resetTransitionStates();
      this.activeSessionId = undefined;
      this.generation = previousGeneration;
    }
  }

  stop(sessionId: string): void {
    if (this.activeSessionId !== sessionId) {
      return;
    }
    this.cancelScheduledTask();
    this.tracker.reset();
    this.resetTransitionStates();
    this.activeSessionId = undefined;
    this.generation += 1;
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.cancelScheduledTask();
    this.tracker.reset();
    this.resetTransitionStates();
    this.activeSessionId = undefined;
    this.generation += 1;
  }

  private scheduleNextTick(sessionId: string, generation: number, delayMs: number): boolean {
    if (!this.isGenerationActive(sessionId, generation)) {
      return false;
    }
    try {
      this.scheduledTask = this.scheduler.schedule(delayMs, async (): Promise<void> => {
        await this.runTick(sessionId, generation);
      });
      return true;
    } catch (_error) {
      this.scheduledTask = undefined;
      return false;
    }
  }

  private async runTick(sessionId: string, generation: number): Promise<void> {
    try {
      const counters = await this.source.refreshTrafficCounters();
      if (!this.isGenerationActive(sessionId, generation)) {
        return;
      }
      this.reportSourceState(true);
      this.reportCountersState(isNonZeroCounters(counters));
      const sample = this.tracker.sample(sessionId, counters.txBytes, counters.rxBytes, this.clock.nowMs());
      if (!this.isGenerationActive(sessionId, generation)) {
        return;
      }
      this.reportRateState(isNonZeroRate(sample));
      try {
        await this.sink.updateTraffic(
          sessionId,
          sample.uploadBytesPerSecond,
          sample.downloadBytesPerSecond
        );
      } catch (_error) {
      }
      if (!this.isGenerationActive(sessionId, generation)) {
        return;
      }
      if (!this.scheduleNextTick(sessionId, generation, 1000)) {
        this.terminateGeneration(sessionId, generation);
      }
    } catch (_error) {
      this.tracker.reset();
      this.reportSourceState(false);
      this.countersNonZero = undefined;
      this.rateNonZero = undefined;
      if (!this.isGenerationActive(sessionId, generation)) {
        return;
      }
      try {
        await this.sink.updateTraffic(sessionId, 0, 0);
      } catch (_updateError) {
      }
      if (!this.isGenerationActive(sessionId, generation)) {
        return;
      }
      if (!this.scheduleNextTick(sessionId, generation, 1000)) {
        this.terminateGeneration(sessionId, generation);
      }
    }
  }

  private cancelScheduledTask(): void {
    const task = this.scheduledTask;
    this.scheduledTask = undefined;
    task?.cancel();
  }

  private isGenerationActive(sessionId: string, generation: number): boolean {
    return !this.disposed &&
      this.activeSessionId === sessionId &&
      this.generation === generation;
  }

  private terminateGeneration(sessionId: string, generation: number): void {
    if (!this.isGenerationActive(sessionId, generation)) {
      return;
    }
    this.cancelScheduledTask();
    this.tracker.reset();
    this.resetTransitionStates();
    this.activeSessionId = undefined;
    this.generation += 1;
  }

  private resetTransitionStates(): void {
    this.sourceHealthy = undefined;
    this.countersNonZero = undefined;
    this.rateNonZero = undefined;
  }

  private reportSourceState(sourceHealthy: boolean): void {
    if (this.sourceHealthy === sourceHealthy) {
      return;
    }
    this.sourceHealthy = sourceHealthy;
    this.emitDiagnosticStage(sourceHealthy ? 'notification.traffic.source-ok' : 'notification.traffic.source-failed');
  }

  private reportCountersState(countersNonZero: boolean): void {
    if (this.countersNonZero === countersNonZero) {
      return;
    }
    this.countersNonZero = countersNonZero;
    this.emitDiagnosticStage(countersNonZero ? 'notification.traffic.counters-nonzero' : 'notification.traffic.counters-zero');
  }

  private reportRateState(rateNonZero: boolean): void {
    if (this.rateNonZero === rateNonZero) {
      return;
    }
    this.rateNonZero = rateNonZero;
    this.emitDiagnosticStage(rateNonZero ? 'notification.traffic.rate-nonzero' : 'notification.traffic.rate-zero');
  }

  private emitDiagnosticStage(stage: VpnTrafficDiagnosticStage): void {
    this.reportStage?.(stage);
  }
}
