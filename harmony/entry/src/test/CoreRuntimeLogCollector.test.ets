import { describe, expect, it } from '@ohos/hypium';
import {
  cloneRuntimeLogEntry,
  formatRuntimeLogsAsText,
  type CoreEvent,
  type RuntimeLogEntry,
  type RuntimeLogStorePort
} from '@cmfa/shared';
import { CoreRuntimeLogCollector, type CoreLogSubscriptionPort } from '../main/ets/vpn/CoreRuntimeLogCollector';

class FakeCoreLogSource implements CoreLogSubscriptionPort {
  private callback?: (event: CoreEvent) => void;
  subscribeCalls: number = 0;
  unsubscribeCalls: number = 0;

  subscribe(callback: (event: CoreEvent) => void): number {
    this.subscribeCalls += 1;
    this.callback = callback;
    return 9;
  }

  unsubscribe(subscriptionId: number): void {
    expect(subscriptionId).assertEqual(9);
    this.unsubscribeCalls += 1;
    this.callback = undefined;
  }

  emit(event: CoreEvent): void {
    this.callback?.(event);
  }
}
class FakeRuntimeLogStore implements RuntimeLogStorePort {
  readonly entries: RuntimeLogEntry[] = [];
  drainCalls: number = 0;

  async append(entry: RuntimeLogEntry): Promise<void> {
    this.entries.push(cloneRuntimeLogEntry(entry));
  }

  async read(_limit?: number): Promise<RuntimeLogEntry[]> {
    return this.entries.map((entry: RuntimeLogEntry): RuntimeLogEntry => cloneRuntimeLogEntry(entry));
  }

  async clear(): Promise<void> {
    this.entries.length = 0;
  }

  async exportText(): Promise<string> {
    return formatRuntimeLogsAsText(this.entries);
  }

  async drain(): Promise<void> {
    this.drainCalls += 1;
  }
}

export default function coreRuntimeLogCollectorTestsuite() {
  describe('CoreRuntimeLogCollectorTest', () => {
    it('collectsOnlyCoreLogEventsAndDrainsBeforeClosing', 0, async () => {
      const core = new FakeCoreLogSource();
      const store = new FakeRuntimeLogStore();
      const collector = new CoreRuntimeLogCollector(core, store, (): string => '2026-08-31T12:00:00.000Z');

      collector.start();
      collector.start();
      core.emit({ type: 'runtime', state: 'RUNNING', message: 'runtime event' });
      core.emit({ type: 'log', level: 'WARN', message: 'network recovering' });
      await store.drain();

      expect(core.subscribeCalls).assertEqual(1);
      expect(store.entries.length).assertEqual(1);
      expect(store.entries[0].level).assertEqual('WARN');
      expect(store.entries[0].message).assertEqual('network recovering');

      await collector.close();
      await collector.close();
      core.emit({ type: 'log', level: 'ERROR', message: 'late' });

      expect(core.unsubscribeCalls).assertEqual(1);
      expect(store.drainCalls >= 2).assertTrue();
      expect(store.entries.length).assertEqual(1);
    });
  });
}
