import type {
  BoundedDelaySchedulerPort,
  ClockPort,
  VpnRpcTrafficCounters
} from '@cmfa/shared';
import type {
  VpnTrafficMonitorListener,
  VpnTrafficMonitorReadPort,
  VpnTrafficMonitorSnapshot
} from './VpnTrafficMonitor';

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

type VpnTrafficDiagnosticStage =
  | 'notification.traffic.source-ok'
  | 'notification.traffic.source-failed'
  | 'notification.traffic.counters-zero'
  | 'notification.traffic.counters-nonzero'
  | 'notification.traffic.rate-zero'
  | 'notification.traffic.rate-nonzero';

class VpnTrafficMonitorSnapshotValue implements VpnTrafficMonitorSnapshot {
  available: boolean = false;
  txBytes: number = 0;
  rxBytes: number = 0;
  uploadBytesPerSecond: number = 0;
  downloadBytesPerSecond: number = 0;
}

class NullTrafficMonitor implements VpnTrafficMonitorReadPort {
  snapshot(): VpnTrafficMonitorSnapshot {
    return createSnapshot(false, 0, 0, 0, 0);
  }

  subscribe(_listener: VpnTrafficMonitorListener): number {
    return 0;
  }

  unsubscribe(_id: number): void {
  }
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

function isNonZeroCounters(snapshot: VpnTrafficMonitorSnapshot): boolean {
  return snapshot.txBytes > 0 || snapshot.rxBytes > 0;
}

function isNonZeroRate(snapshot: VpnTrafficMonitorSnapshot): boolean {
  return snapshot.uploadBytesPerSecond > 0 || snapshot.downloadBytesPerSecond > 0;
}

function asTrafficMonitorReadPort(
  candidate: VpnTrafficMonitorReadPort | VpnTrafficCounterSourcePort
): VpnTrafficMonitorReadPort | undefined {
  const monitor = candidate as VpnTrafficMonitorReadPort;
  if (typeof monitor.snapshot === 'function' &&
    typeof monitor.subscribe === 'function' &&
    typeof monitor.unsubscribe === 'function') {
    return monitor;
  }
  return undefined;
}

export class VpnTrafficNotificationCoordinator {
  private readonly monitor: VpnTrafficMonitorReadPort;
  private readonly sink: VpnTrafficNotificationSinkPort;
  private readonly reportStage?: (stage: string) => void;
  private activeSessionId?: string;
  private subscriptionId?: number;
  private disposed: boolean = false;
  private sourceHealthy?: boolean;
  private countersNonZero?: boolean;
  private rateNonZero?: boolean;

  constructor(
    monitor: VpnTrafficMonitorReadPort,
    sink: VpnTrafficNotificationSinkPort,
    reportStage?: (stage: string) => void
  );
  constructor(
    source: VpnTrafficCounterSourcePort,
    sink: VpnTrafficNotificationSinkPort,
    clock: ClockPort,
    scheduler: BoundedDelaySchedulerPort,
    reportStage?: (stage: string) => void
  );
  constructor(
    monitorOrSource: VpnTrafficMonitorReadPort | VpnTrafficCounterSourcePort,
    sink: VpnTrafficNotificationSinkPort,
    reportStageOrClock?: ((stage: string) => void) | ClockPort,
    _scheduler?: BoundedDelaySchedulerPort,
    maybeReportStage?: (stage: string) => void
  ) {
    this.monitor = asTrafficMonitorReadPort(monitorOrSource) ?? new NullTrafficMonitor();
    this.sink = sink;
    this.reportStage = typeof reportStageOrClock === 'function'
      ? reportStageOrClock
      : maybeReportStage;
  }

  start(sessionId: string): void {
    if (this.disposed || !isValidSessionId(sessionId)) {
      return;
    }
    if (this.activeSessionId === sessionId && this.subscriptionId !== undefined) {
      return;
    }

    this.detachListener();
    this.resetTransitionStates();
    this.activeSessionId = sessionId;

    let listenerId: number = 0;
    const listener = async (snapshot: VpnTrafficMonitorSnapshot): Promise<void> => {
      await this.forwardSnapshot(sessionId, listenerId, snapshot);
    };
    listenerId = this.monitor.subscribe(listener);
    this.subscriptionId = listenerId;

    void this.forwardSnapshot(sessionId, listenerId, this.monitor.snapshot());
  }

  stop(sessionId: string): void {
    if (this.activeSessionId !== sessionId) {
      return;
    }
    this.detachListener();
    this.resetTransitionStates();
    this.activeSessionId = undefined;
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.detachListener();
    this.resetTransitionStates();
    this.activeSessionId = undefined;
  }

  private async forwardSnapshot(
    sessionId: string,
    subscriptionId: number,
    snapshot: VpnTrafficMonitorSnapshot
  ): Promise<void> {
    if (!this.isSubscriptionActive(sessionId, subscriptionId)) {
      return;
    }

    const snapshotValue = cloneSnapshot(snapshot);
    this.reportSourceState(snapshotValue.available);
    this.reportCountersState(isNonZeroCounters(snapshotValue));
    this.reportRateState(isNonZeroRate(snapshotValue));

    try {
      await this.sink.updateTraffic(
        sessionId,
        snapshotValue.uploadBytesPerSecond,
        snapshotValue.downloadBytesPerSecond
      );
    } catch (_) {
    }
  }

  private detachListener(): void {
    const subscriptionId = this.subscriptionId;
    this.subscriptionId = undefined;
    if (subscriptionId === undefined) {
      return;
    }
    this.monitor.unsubscribe(subscriptionId);
  }

  private isSubscriptionActive(sessionId: string, subscriptionId: number): boolean {
    return !this.disposed &&
      this.activeSessionId === sessionId &&
      this.subscriptionId === subscriptionId;
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
