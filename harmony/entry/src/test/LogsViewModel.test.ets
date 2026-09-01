import { describe, expect, it } from '@ohos/hypium';
import {
  cloneRuntimeLogEntry,
  createRuntimeLogEntry,
  formatRuntimeLogsAsText,
  type RuntimeLogEntry,
  type RuntimeLogExportPort,
  type RuntimeLogExportResult,
  type RuntimeLogStorePort
} from '@cmfa/shared';
import {
  LogsViewModel,
  type LogsPollingTaskPort,
  type LogsPollingSchedulerPort,
  type LogsViewState
} from '../main/ets/presentation/LogsViewModel';

class FakeLogStore implements RuntimeLogStorePort {
  entries: RuntimeLogEntry[] = [];
  clearCalls: number = 0;

  async append(entry: RuntimeLogEntry): Promise<void> {
    this.entries.push(cloneRuntimeLogEntry(entry));
  }

  async read(_limit?: number): Promise<RuntimeLogEntry[]> {
    return this.entries.map((entry: RuntimeLogEntry): RuntimeLogEntry => cloneRuntimeLogEntry(entry));
  }

  async clear(): Promise<void> {
    this.clearCalls += 1;
    this.entries = [];
  }

  async exportText(): Promise<string> {
    return formatRuntimeLogsAsText(this.entries);
  }

  async drain(): Promise<void> {
  }
}
class FakeExporter implements RuntimeLogExportPort {
  result: RuntimeLogExportResult = 'EXPORTED';
  exportedText: string = '';

  async export(text: string): Promise<RuntimeLogExportResult> {
    this.exportedText = text;
    return this.result;
  }
}

class FakePollingTask implements LogsPollingTaskPort {
  cancelled: boolean = false;

  cancel(): void {
    this.cancelled = true;
  }
}

class FakePollingScheduler implements LogsPollingSchedulerPort {
  delayMs: number = 0;
  runner?: () => Promise<void>;
  task: FakePollingTask = new FakePollingTask();

  schedule(delayMs: number, runner: () => Promise<void>): LogsPollingTaskPort {
    this.delayMs = delayMs;
    this.runner = runner;
    this.task = new FakePollingTask();
    return this.task;
  }
}

async function flushPromises(turns: number = 6): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

export default function logsViewModelTestsuite() {
  describe('LogsViewModelTest', () => {
    it('pollsFiltersSearchesClearsAndExportsThePrivateHistory', 0, async () => {
      const store = new FakeLogStore();
      store.entries = [
        createRuntimeLogEntry('2026-08-31T12:00:00.000Z', 'INFO', 'vpn started'),
        createRuntimeLogEntry('2026-08-31T12:00:01.000Z', 'ERROR', 'network failed')
      ];
      const exporter = new FakeExporter();
      const scheduler = new FakePollingScheduler();
      const viewModel = new LogsViewModel(store, exporter, scheduler);

      viewModel.start();
      await flushPromises();
      let state: LogsViewState = viewModel.current();
      expect(state.entries.length).assertEqual(2);
      expect(scheduler.delayMs).assertEqual(500);

      viewModel.setLevel('ERROR');
      viewModel.setSearchText('network');
      state = viewModel.current();
      expect(state.entries.length).assertEqual(1);
      expect(state.entries[0].level).assertEqual('ERROR');

      await viewModel.exportLogs();
      expect(exporter.exportedText.includes('vpn started')).assertTrue();
      expect(viewModel.current().operationResult).assertEqual('EXPORTED');

      await viewModel.clearLogs();
      expect(store.clearCalls).assertEqual(1);
      expect(viewModel.current().entries.length).assertEqual(0);

      viewModel.dispose();
      expect(scheduler.task.cancelled).assertTrue();
    });
  });
}
