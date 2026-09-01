import type {
  BoundedDelaySchedulerPort,
  CancelableDelayTask,
  ClockPort,
  VpnRpcTrafficCounters
} from '@cmfa/shared';

export interface VpnTrafficCounterSourcePort {
  refreshTrafficCounters(): Promise<VpnRpcTrafficCounters>;
}

export interface VpnTrafficMonitorSnapshot {
  available: boolean;
  txBytes: number;
  rxBytes: number;
  uploadBytesPerSecond: number;
  downloadBytesPerSecond: number;
}

export type VpnTrafficMonitorListener = (snapshot: VpnTrafficMonitorSnapshot) => void | Promise<void>;

export interface VpnTrafficMonitorReadPort {
  snapshot(): VpnTrafficMonitorSnapshot;
  subscribe(listener: VpnTrafficMonitorListener): number;
  unsubscribe(id: number): void;
}

export interface VpnTrafficMonitorLifecyclePort {
  start(sessionId: string): void;
  markRecovering(sessionId: string): void;
  stop(sessionId?: string): void;
  dispose(): void;
}

type VpnTrafficDiagnosticStage =
  | 'notification.traffic.source-ok'
  | 'notification.traffic.source-failed'
  | 'notification.traffic.counters-zero'
  | 'notification.traffic.counters-nonzero'
  | 'notification.traffic.rate-zero'
  | 'notification.traffic.rate-nonzero';

interface VpnTrafficRateBaseline {
  txBytes: number;
  rxBytes: number;
  nowMs: number;
}

class VpnTrafficMonitorSnapshotValue implements VpnTrafficMonitorSnapshot {
  available: boolean = false;
  txBytes: number = 0;
  rxBytes: number = 0;
  uploadBytesPerSecond: number = 0;
  downloadBytesPerSecond: number = 0;
}

function createSnapshot(
  available: boolean,
  txBytes: number,
  rxBytes: number,
  uploadBytesPerSecond: number,
  downloadBytesPerSecond: number
): VpnTrafficMonitorSnapshot {
  const snapshot = new VpnTrafficMonitorSnapshotValue();
  snapshot.available = available;
  snapshot.txBytes = txBytes;
  snapshot.rxBytes = rxBytes;
  snapshot.uploadBytesPerSecond = uploadBytesPerSecond;
  snapshot.downloadBytesPerSecond = downloadBytesPerSecond;
  return snapshot;
}

function cloneSnapshot(snapshot: VpnTrafficMonitorSnapshot): VpnTrafficMonitorSnapshot {
  return createSnapshot(
    snapshot.available,
    snapshot.txBytes,
    snapshot.rxBytes,
    snapshot.uploadBytesPerSecond,
    snapshot.downloadBytesPerSecond
  );
}

function isValidSessionId(sessionId: string): boolean {
  return sessionId.trim().length > 0;
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

function isNonZeroRate(snapshot: VpnTrafficMonitorSnapshot): boolean {
  return snapshot.uploadBytesPerSecond > 0 || snapshot.downloadBytesPerSecond > 0;
}

export class VpnTrafficRateTracker {
  private baseline?: VpnTrafficRateBaseline;

  sample(txBytes: number, rxBytes: number, nowMs: number): VpnTrafficMonitorSnapshot {
    if (!isValidCounter(txBytes) || !isValidCounter(rxBytes) || !isValidTimestamp(nowMs)) {
      this.reset();
      return createSnapshot(false, 0, 0, 0, 0);
    }

    const nextBaseline: VpnTrafficRateBaseline = {
      txBytes,
      rxBytes,
      nowMs
    };
    const previousBaseline = this.baseline;
    this.baseline = nextBaseline;

    if (previousBaseline === undefined) {
      return createSnapshot(true, txBytes, rxBytes, 0, 0);
    }
    if (txBytes < previousBaseline.txBytes || rxBytes < previousBaseline.rxBytes || nowMs <= previousBaseline.nowMs) {
      return createSnapshot(true, txBytes, rxBytes, 0, 0);
    }

    return createSnapshot(
      true,
      txBytes,
      rxBytes,
      computeBytesPerSecond(txBytes - previousBaseline.txBytes, nowMs - previousBaseline.nowMs),
      computeBytesPerSecond(rxBytes - previousBaseline.rxBytes, nowMs - previousBaseline.nowMs)
    );
  }

  reset(): void {
    this.baseline = undefined;
  }
}

export class VpnTrafficMonitor implements VpnTrafficMonitorReadPort, VpnTrafficMonitorLifecyclePort {
  private readonly source: VpnTrafficCounterSourcePort;
  private readonly clock: ClockPort;
  private readonly scheduler: BoundedDelaySchedulerPort;
  private readonly reportStage?: (stage: string) => void;
  private readonly tracker: VpnTrafficRateTracker = new VpnTrafficRateTracker();
  private readonly listeners: Map<number, VpnTrafficMonitorListener> = new Map();
  private nextListenerId: number = 0;
  private generation: number = 0;
  private activeSessionId?: string;
  private scheduledTask?: CancelableDelayTask;
  private disposed: boolean = false;
  private recovering: boolean = false;
  private currentSnapshot: VpnTrafficMonitorSnapshot = createSnapshot(false, 0, 0, 0, 0);
  private sourceHealthy?: boolean;
  private countersNonZero?: boolean;
  private rateNonZero?: boolean;

  constructor(
    source: VpnTrafficCounterSourcePort,
    clock: ClockPort,
    scheduler: BoundedDelaySchedulerPort,
    reportStage?: (stage: string) => void
  ) {
    this.source = source;
    this.clock = clock;
    this.scheduler = scheduler;
    this.reportStage = reportStage;
  }

  snapshot(): VpnTrafficMonitorSnapshot {
    return cloneSnapshot(this.currentSnapshot);
  }

  subscribe(listener: VpnTrafficMonitorListener): number {
    this.nextListenerId += 1;
    this.listeners.set(this.nextListenerId, listener);
    return this.nextListenerId;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  start(sessionId: string): void {
    if (this.disposed || !isValidSessionId(sessionId)) {
      return;
    }
    const previousSessionId: string | undefined = this.activeSessionId;
    if (previousSessionId === sessionId && !this.recovering && this.scheduledTask !== undefined) {
      return;
    }

    const previousGeneration = this.generation;
    const switchingSessions: boolean = previousSessionId !== undefined && previousSessionId !== sessionId;

    this.cancelScheduledTask();
    this.tracker.reset();
    this.resetTransitionStates();
    this.recovering = false;
    this.generation += 1;
    this.activeSessionId = sessionId;

    if (switchingSessions) {
      void this.publishSnapshot(createSnapshot(false, 0, 0, 0, 0), true);
    }

    if (!this.scheduleNextTick(sessionId, this.generation, 0)) {
      this.tracker.reset();
      this.resetTransitionStates();
      this.activeSessionId = undefined;
      this.generation = previousGeneration;
    }
  }

  markRecovering(sessionId: string): void {
    if (!this.isGenerationActive(sessionId, this.generation)) {
      return;
    }
    this.cancelScheduledTask();
    this.tracker.reset();
    this.recovering = true;
    this.reportSourceState(false);
    this.countersNonZero = undefined;
    this.rateNonZero = undefined;
    void this.publishSnapshot(
      createSnapshot(false, this.currentSnapshot.txBytes, this.currentSnapshot.rxBytes, 0, 0),
      true
    );
  }

  stop(sessionId?: string): void {
    const activeSessionId: string | undefined = this.activeSessionId;
    if (activeSessionId === undefined) {
      return;
    }
    if (sessionId !== undefined && sessionId !== activeSessionId) {
      return;
    }
    this.cancelScheduledTask();
    this.tracker.reset();
    this.resetTransitionStates();
    this.recovering = false;
    this.activeSessionId = undefined;
    this.generation += 1;
    void this.publishSnapshot(createSnapshot(false, 0, 0, 0, 0), true);
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.cancelScheduledTask();
    this.tracker.reset();
    this.resetTransitionStates();
    this.recovering = false;
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
    } catch (_) {
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
      const snapshot = this.tracker.sample(counters.txBytes, counters.rxBytes, this.clock.nowMs());
      if (!this.isGenerationActive(sessionId, generation)) {
        return;
      }
      this.reportRateState(isNonZeroRate(snapshot));
      await this.publishSnapshot(snapshot);
      if (!this.isGenerationActive(sessionId, generation)) {
        return;
      }
      if (!this.scheduleNextTick(sessionId, generation, 1000)) {
        this.terminateGeneration(sessionId, generation);
      }
    } catch (_) {
      this.tracker.reset();
      this.reportSourceState(false);
      this.countersNonZero = undefined;
      this.rateNonZero = undefined;
      if (!this.isGenerationActive(sessionId, generation)) {
        return;
      }
      await this.publishSnapshot(
        createSnapshot(false, this.currentSnapshot.txBytes, this.currentSnapshot.rxBytes, 0, 0)
      );
      if (!this.isGenerationActive(sessionId, generation)) {
        return;
      }
      if (!this.scheduleNextTick(sessionId, generation, 1000)) {
        this.terminateGeneration(sessionId, generation);
      }
    }
  }

  private async publishSnapshot(snapshot: VpnTrafficMonitorSnapshot, force: boolean = false): Promise<void> {
    if (!force && snapshotsEqual(this.currentSnapshot, snapshot)) {
      return;
    }
    this.currentSnapshot = cloneSnapshot(snapshot);
    if (this.listeners.size === 0) {
      return;
    }
    const listeners: VpnTrafficMonitorListener[] = [];
    this.listeners.forEach((listener: VpnTrafficMonitorListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      try {
        await listeners[index](cloneSnapshot(this.currentSnapshot));
      } catch (_) {
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
      !this.recovering &&
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

function snapshotsEqual(left: VpnTrafficMonitorSnapshot, right: VpnTrafficMonitorSnapshot): boolean {
  return left.available === right.available &&
    left.txBytes === right.txBytes &&
    left.rxBytes === right.rxBytes &&
    left.uploadBytesPerSecond === right.uploadBytesPerSecond &&
    left.downloadBytesPerSecond === right.downloadBytesPerSecond;
}
