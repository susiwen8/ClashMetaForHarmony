import {
  createRuntimeLogEntry,
  type CoreEvent,
  type CoreService,
  type RuntimeLogStorePort
} from '@cmfa/shared';
import { hilog } from '@kit.PerformanceAnalysisKit';

const RUNTIME_LOG_DOMAIN: number = 0x0000;
const RUNTIME_LOG_TAG: string = 'CMFALog';

export interface CoreLogSubscriptionPort {
  subscribe(callback: (event: CoreEvent) => void): number;
  unsubscribe(subscriptionId: number): void;
}

export class CoreServiceLogSubscriptionAdapter implements CoreLogSubscriptionPort {
  private readonly coreService: CoreService;

  constructor(coreService: CoreService) {
    this.coreService = coreService;
  }

  subscribe(callback: (event: CoreEvent) => void): number {
    return this.coreService.subscribe(callback);
  }

  unsubscribe(subscriptionId: number): void {
    this.coreService.unsubscribe(subscriptionId);
  }
}

export class CoreRuntimeLogCollector {
  private readonly core: CoreLogSubscriptionPort;
  private readonly store: RuntimeLogStorePort;
  private readonly now: () => string;
  private subscriptionId: number = 0;
  private closed: boolean = false;
  private storageHealthyValue: boolean = true;
  private closePromise?: Promise<void>;

  constructor(core: CoreLogSubscriptionPort, store: RuntimeLogStorePort, now: () => string) {
    this.core = core;
    this.store = store;
    this.now = now;
  }

  start(): void {
    if (this.closed || this.subscriptionId !== 0) {
      return;
    }
    this.subscriptionId = this.core.subscribe((event: CoreEvent): void => {
      if (this.closed || event.type !== 'log') {
        return;
      }
      try {
        const appendPromise: Promise<void> = this.store.append(
          createRuntimeLogEntry(this.now(), event.level, event.message)
        );
        void appendPromise.then((): void => {
          this.storageHealthyValue = true;
        }).catch((): void => {
          this.storageHealthyValue = false;
          hilog.error(RUNTIME_LOG_DOMAIN, RUNTIME_LOG_TAG, '%{public}s', 'runtime-log.persist.failed');
        });
      } catch (_) {
      }
    });
  }

  storageHealthy(): boolean {
    return this.storageHealthyValue;
  }

  async close(): Promise<void> {
    if (this.closePromise !== undefined) {
      await this.closePromise;
      return;
    }
    if (this.closed) {
      await this.store.drain();
      return;
    }
    const promise: Promise<void> = this.closeInternal();
    this.closePromise = promise;
    await promise;
  }

  private async closeInternal(): Promise<void> {
    this.closed = true;
    const subscriptionId: number = this.subscriptionId;
    this.subscriptionId = 0;
    if (subscriptionId !== 0) {
      try {
        this.core.unsubscribe(subscriptionId);
      } catch (_) {
      }
    }
    await this.store.drain();
  }
}
