import {
  cloneRuntimeLogEntries,
  type RuntimeLogEntry,
  type RuntimeLogExportPort,
  type RuntimeLogExportResult,
  type RuntimeLogFilterLevel,
  type RuntimeLogStorePort
} from '@cmfa/shared';

const POLL_INTERVAL_MS: number = 500;

export interface LogsPollingTaskPort {
  cancel(): void;
}

export interface LogsPollingSchedulerPort {
  schedule(delayMs: number, runner: () => Promise<void>): LogsPollingTaskPort;
}

export interface LogsViewState {
  entries: RuntimeLogEntry[];
  totalCount: number;
  level: RuntimeLogFilterLevel;
  searchText: string;
  refreshing: boolean;
  operationPending: boolean;
  operationResult: 'NONE' | RuntimeLogExportResult | 'CLEARED';
  failed: boolean;
}

export type LogsViewListener = (state: LogsViewState) => void;

class TimeoutPollingTask implements LogsPollingTaskPort {
  private readonly timerId: number;

  constructor(timerId: number) {
    this.timerId = timerId;
  }

  cancel(): void {
    clearTimeout(this.timerId);
  }
}

class TimeoutPollingScheduler implements LogsPollingSchedulerPort {
  schedule(delayMs: number, runner: () => Promise<void>): LogsPollingTaskPort {
    const timerId: number = setTimeout((): void => {
      void runner();
    }, delayMs);
    return new TimeoutPollingTask(timerId);
  }
}

class LogsViewStateValue implements LogsViewState {
  entries: RuntimeLogEntry[] = [];
  totalCount: number = 0;
  level: RuntimeLogFilterLevel = 'ALL';
  searchText: string = '';
  refreshing: boolean = false;
  operationPending: boolean = false;
  operationResult: 'NONE' | RuntimeLogExportResult | 'CLEARED' = 'NONE';
  failed: boolean = false;
}

export class LogsViewModel {
  private readonly store: RuntimeLogStorePort;
  private readonly exporter: RuntimeLogExportPort;
  private readonly scheduler: LogsPollingSchedulerPort;
  private readonly listeners: Map<number, LogsViewListener> = new Map();
  private rawEntries: RuntimeLogEntry[] = [];
  private stateValue: LogsViewState = createLogsViewState([], 0, 'ALL', '', false, false, 'NONE', false);
  private nextListenerId: number = 0;
  private pollingTask?: LogsPollingTaskPort;
  private epoch: number = 0;
  private started: boolean = false;
  private disposed: boolean = false;

  constructor(
    store: RuntimeLogStorePort,
    exporter: RuntimeLogExportPort,
    scheduler?: LogsPollingSchedulerPort
  ) {
    this.store = store;
    this.exporter = exporter;
    this.scheduler = scheduler ?? new TimeoutPollingScheduler();
  }

  start(): void {
    if (this.disposed || this.started) {
      return;
    }
    this.started = true;
    void this.refresh();
  }

  current(): LogsViewState {
    return cloneLogsViewState(this.stateValue);
  }

  subscribe(listener: LogsViewListener): number {
    this.nextListenerId += 1;
    this.listeners.set(this.nextListenerId, listener);
    return this.nextListenerId;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  setLevel(level: RuntimeLogFilterLevel): void {
    if (this.disposed) {
      return;
    }
    this.publishFiltered(level, this.stateValue.searchText);
  }

  setSearchText(searchText: string): void {
    if (this.disposed) {
      return;
    }
    this.publishFiltered(this.stateValue.level, searchText.substring(0, 128));
  }

  async refresh(): Promise<void> {
    if (this.disposed || this.stateValue.refreshing) {
      return;
    }
    const epoch: number = this.epoch + 1;
    this.epoch = epoch;
    this.publish(createLogsViewState(
      this.stateValue.entries,
      this.stateValue.totalCount,
      this.stateValue.level,
      this.stateValue.searchText,
      true,
      this.stateValue.operationPending,
      this.stateValue.operationResult,
      false
    ));
    try {
      const entries: RuntimeLogEntry[] = await this.store.read();
      if (!this.canPublish(epoch)) {
        return;
      }
      this.rawEntries = cloneRuntimeLogEntries(entries);
      this.publishFiltered(this.stateValue.level, this.stateValue.searchText, false);
    } catch (_) {
      if (!this.canPublish(epoch)) {
        return;
      }
      this.publish(createLogsViewState(
        this.stateValue.entries,
        this.stateValue.totalCount,
        this.stateValue.level,
        this.stateValue.searchText,
        false,
        this.stateValue.operationPending,
        this.stateValue.operationResult,
        true
      ));
    } finally {
      if (this.canPublish(epoch)) {
        this.scheduleNextPoll();
      }
    }
  }

  async clearLogs(): Promise<void> {
    if (this.disposed || this.stateValue.operationPending) {
      return;
    }
    this.epoch += 1;
    this.pollingTask?.cancel();
    this.pollingTask = undefined;
    this.publish(createLogsViewState(
      this.stateValue.entries,
      this.stateValue.totalCount,
      this.stateValue.level,
      this.stateValue.searchText,
      false,
      true,
      'NONE',
      false
    ));
    try {
      await this.store.clear();
      if (this.disposed) {
        return;
      }
      this.rawEntries = [];
      this.publishFiltered(this.stateValue.level, this.stateValue.searchText, false, false, 'CLEARED');
      this.scheduleNextPoll();
    } catch (_) {
      if (!this.disposed) {
        this.publishOperation(false, 'NONE', true);
      }
    }
  }

  async exportLogs(): Promise<void> {
    if (this.disposed || this.stateValue.operationPending) {
      return;
    }
    this.publishOperation(true, 'NONE', false);
    let result: RuntimeLogExportResult = 'FAILED';
    try {
      result = await this.exporter.export(await this.store.exportText());
    } catch (_) {
      result = 'FAILED';
    }
    if (!this.disposed) {
      this.publishOperation(false, result, result === 'FAILED');
    }
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.epoch += 1;
    this.pollingTask?.cancel();
    this.pollingTask = undefined;
    this.listeners.clear();
  }

  private publishFiltered(
    level: RuntimeLogFilterLevel,
    searchText: string,
    refreshing: boolean = this.stateValue.refreshing,
    operationPending: boolean = this.stateValue.operationPending,
    operationResult: 'NONE' | RuntimeLogExportResult | 'CLEARED' = this.stateValue.operationResult
  ): void {
    const normalizedSearch: string = searchText.trim().toLowerCase();
    const filtered: RuntimeLogEntry[] = [];
    for (let index: number = 0; index < this.rawEntries.length; index += 1) {
      const entry: RuntimeLogEntry = this.rawEntries[index];
      if (level !== 'ALL' && entry.level !== level) {
        continue;
      }
      if (normalizedSearch.length > 0 &&
        !entry.message.toLowerCase().includes(normalizedSearch) &&
        !entry.level.toLowerCase().includes(normalizedSearch)) {
        continue;
      }
      filtered.push(entry);
    }
    this.publish(createLogsViewState(
      filtered,
      this.rawEntries.length,
      level,
      searchText,
      refreshing,
      operationPending,
      operationResult,
      false
    ));
  }

  private publishOperation(
    pending: boolean,
    result: 'NONE' | RuntimeLogExportResult | 'CLEARED',
    failed: boolean
  ): void {
    this.publish(createLogsViewState(
      this.stateValue.entries,
      this.stateValue.totalCount,
      this.stateValue.level,
      this.stateValue.searchText,
      this.stateValue.refreshing,
      pending,
      result,
      failed
    ));
  }

  private scheduleNextPoll(): void {
    if (!this.started || this.disposed) {
      return;
    }
    this.pollingTask?.cancel();
    this.pollingTask = this.scheduler.schedule(POLL_INTERVAL_MS, async (): Promise<void> => {
      this.pollingTask = undefined;
      await this.refresh();
    });
  }

  private canPublish(epoch: number): boolean {
    return !this.disposed && this.epoch === epoch;
  }

  private publish(state: LogsViewState): void {
    this.stateValue = cloneLogsViewState(state);
    const listeners: LogsViewListener[] = [];
    this.listeners.forEach((listener: LogsViewListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneLogsViewState(this.stateValue));
    }
  }
}

export function createLogsViewState(
  entries: RuntimeLogEntry[],
  totalCount: number,
  level: RuntimeLogFilterLevel,
  searchText: string,
  refreshing: boolean,
  operationPending: boolean,
  operationResult: 'NONE' | RuntimeLogExportResult | 'CLEARED',
  failed: boolean
): LogsViewState {
  const state: LogsViewStateValue = new LogsViewStateValue();
  state.entries = cloneRuntimeLogEntries(entries);
  state.totalCount = totalCount;
  state.level = level;
  state.searchText = searchText;
  state.refreshing = refreshing;
  state.operationPending = operationPending;
  state.operationResult = operationResult;
  state.failed = failed;
  return state;
}

export function cloneLogsViewState(state: LogsViewState): LogsViewState {
  return createLogsViewState(
    state.entries,
    state.totalCount,
    state.level,
    state.searchText,
    state.refreshing,
    state.operationPending,
    state.operationResult,
    state.failed
  );
}
