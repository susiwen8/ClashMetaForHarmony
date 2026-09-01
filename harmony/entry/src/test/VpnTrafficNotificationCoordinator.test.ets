import { describe, expect, it } from '@ohos/hypium';
import {
  VpnTrafficNotificationCoordinator,
  type VpnTrafficNotificationSinkPort
} from '../main/ets/vpn/VpnTrafficNotificationCoordinator';
import type {
  VpnTrafficMonitorListener,
  VpnTrafficMonitorReadPort,
  VpnTrafficMonitorSnapshot
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

interface TrafficUpdateRecord {
  sessionId: string;
  uploadBytesPerSecond: number;
  downloadBytesPerSecond: number;
}

type ScriptedSinkStep = Error | DeferredValue<void> | undefined;

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

class ScriptedTrafficMonitor implements VpnTrafficMonitorReadPort {
  private readonly listeners: Map<number, VpnTrafficMonitorListener> = new Map();
  private nextListenerId: number = 0;
  private currentSnapshot: VpnTrafficMonitorSnapshot;
  snapshotCallCount: number = 0;
  subscribeCallCount: number = 0;
  readonly unsubscribeCalls: number[] = [];

  constructor(initialSnapshot: VpnTrafficMonitorSnapshot) {
    this.currentSnapshot = cloneSnapshot(initialSnapshot);
  }

  snapshot(): VpnTrafficMonitorSnapshot {
    this.snapshotCallCount += 1;
    return cloneSnapshot(this.currentSnapshot);
  }

  subscribe(listener: VpnTrafficMonitorListener): number {
    this.subscribeCallCount += 1;
    this.nextListenerId += 1;
    this.listeners.set(this.nextListenerId, listener);
    return this.nextListenerId;
  }

  unsubscribe(id: number): void {
    this.unsubscribeCalls.push(id);
    this.listeners.delete(id);
  }

  listenerCount(): number {
    return this.listeners.size;
  }

  async publish(snapshot: VpnTrafficMonitorSnapshot): Promise<void> {
    this.currentSnapshot = cloneSnapshot(snapshot);
    const listeners: VpnTrafficMonitorListener[] = [];
    this.listeners.forEach((listener: VpnTrafficMonitorListener): void => {
      listeners.push(listener);
    });
    for (let index = 0; index < listeners.length; index += 1) {
      await listeners[index](cloneSnapshot(this.currentSnapshot));
    }
  }
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
    it('startReadsCurrentSnapshotSubscribesOnceAndForwardsFutureSnapshots', 0, async () => {
      const monitor = new ScriptedTrafficMonitor(createSnapshot(false, 0, 0, 0, 0));
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(monitor, sink);

      coordinator.start('session-1');
      coordinator.start('session-1');
      await settleMicrotasks();
      await monitor.publish(createSnapshot(true, 1024, 2048, 0, 0));
      await monitor.publish(createSnapshot(true, 2048, 4096, 1024, 2048));

      expect(monitor.snapshotCallCount).assertEqual(1);
      expect(monitor.subscribeCallCount).assertEqual(1);
      expect(monitor.listenerCount()).assertEqual(1);
      expect(sink.updates).assertDeepEquals([
        { sessionId: 'session-1', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 },
        { sessionId: 'session-1', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 },
        { sessionId: 'session-1', uploadBytesPerSecond: 1024, downloadBytesPerSecond: 2048 }
      ]);
    });

    it('sinkFailureDoesNotStopFutureSnapshotHandling', 0, async () => {
      const monitor = new ScriptedTrafficMonitor(createSnapshot(true, 0, 0, 0, 0));
      const sink = new RecordingTrafficSink();
      sink.queueError(new Error('notification publish failed'));
      const coordinator = new VpnTrafficNotificationCoordinator(monitor, sink);

      coordinator.start('session-1');
      await settleMicrotasks();
      await monitor.publish(createSnapshot(true, 2048, 4096, 2048, 4096));

      expect(sink.updates).assertDeepEquals([
        { sessionId: 'session-1', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 },
        { sessionId: 'session-1', uploadBytesPerSecond: 2048, downloadBytesPerSecond: 4096 }
      ]);
      expect(monitor.listenerCount()).assertEqual(1);
    });

    it('startSwitchesSessionsByUnsubscribingOldListenerAndReplayingCurrentSnapshot', 0, async () => {
      const monitor = new ScriptedTrafficMonitor(createSnapshot(true, 4096, 8192, 256, 512));
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(monitor, sink);

      coordinator.start('session-1');
      await settleMicrotasks();
      coordinator.start('session-2');
      await settleMicrotasks();

      expect(monitor.unsubscribeCalls).assertDeepEquals([1]);
      expect(monitor.subscribeCallCount).assertEqual(2);
      expect(monitor.listenerCount()).assertEqual(1);
      expect(sink.updates).assertDeepEquals([
        { sessionId: 'session-1', uploadBytesPerSecond: 256, downloadBytesPerSecond: 512 },
        { sessionId: 'session-2', uploadBytesPerSecond: 256, downloadBytesPerSecond: 512 }
      ]);
    });

    it('stopUnsubscribesAndIgnoresFutureSnapshots', 0, async () => {
      const monitor = new ScriptedTrafficMonitor(createSnapshot(false, 0, 0, 0, 0));
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(monitor, sink);

      coordinator.start('session-1');
      await settleMicrotasks();
      coordinator.stop('session-1');
      await monitor.publish(createSnapshot(true, 2048, 4096, 2048, 4096));

      expect(monitor.unsubscribeCalls).assertDeepEquals([1]);
      expect(monitor.listenerCount()).assertEqual(0);
      expect(sink.updates).assertDeepEquals([
        { sessionId: 'session-1', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 }
      ]);
    });

    it('disposeUnsubscribesAndIgnoresFutureSnapshots', 0, async () => {
      const monitor = new ScriptedTrafficMonitor(createSnapshot(true, 1024, 2048, 0, 0));
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(monitor, sink);

      coordinator.start('session-1');
      await settleMicrotasks();
      coordinator.dispose();
      await monitor.publish(createSnapshot(true, 2048, 4096, 1024, 2048));

      expect(monitor.unsubscribeCalls).assertDeepEquals([1]);
      expect(monitor.listenerCount()).assertEqual(0);
      expect(sink.updates).assertDeepEquals([
        { sessionId: 'session-1', uploadBytesPerSecond: 0, downloadBytesPerSecond: 0 }
      ]);
    });

    it('reportsTrafficDiagnosticStagesOnlyOnTransitionsAndReplaysAfterUnavailableSnapshot', 0, async () => {
      const reportStages: string[] = [];
      const monitor = new ScriptedTrafficMonitor(createSnapshot(false, 0, 0, 0, 0));
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(
        monitor,
        sink,
        createReportStageCollector(reportStages)
      );

      coordinator.start('session-1');
      await settleMicrotasks();
      await monitor.publish(createSnapshot(false, 0, 0, 0, 0));
      await monitor.publish(createSnapshot(true, 0, 0, 0, 0));
      await monitor.publish(createSnapshot(true, 1024, 2048, 0, 0));
      await monitor.publish(createSnapshot(true, 2048, 4096, 1024, 2048));
      await monitor.publish(createSnapshot(false, 2048, 4096, 0, 0));
      await monitor.publish(createSnapshot(false, 2048, 4096, 0, 0));

      expect(reportStages).assertDeepEquals([
        'notification.traffic.source-failed',
        'notification.traffic.counters-zero',
        'notification.traffic.rate-zero',
        'notification.traffic.source-ok',
        'notification.traffic.counters-nonzero',
        'notification.traffic.rate-nonzero',
        'notification.traffic.source-failed',
        'notification.traffic.rate-zero'
      ]);
    });

    it('startResetsTrafficDiagnosticTransitionsForTheNextSession', 0, async () => {
      const reportStages: string[] = [];
      const monitor = new ScriptedTrafficMonitor(createSnapshot(false, 0, 0, 0, 0));
      const sink = new RecordingTrafficSink();
      const coordinator = new VpnTrafficNotificationCoordinator(
        monitor,
        sink,
        createReportStageCollector(reportStages)
      );

      coordinator.start('session-1');
      await settleMicrotasks();
      coordinator.start('session-2');
      await settleMicrotasks();

      expect(reportStages).assertDeepEquals([
        'notification.traffic.source-failed',
        'notification.traffic.counters-zero',
        'notification.traffic.rate-zero',
        'notification.traffic.source-failed',
        'notification.traffic.counters-zero',
        'notification.traffic.rate-zero'
      ]);
    });
  });
}
