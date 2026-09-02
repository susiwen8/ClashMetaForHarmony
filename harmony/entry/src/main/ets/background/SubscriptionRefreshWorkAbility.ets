import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import type { WorkSchedulerExtensionContext } from '@kit.BackgroundTasksKit';
import {
  createSubscriptionRefreshComposition,
  type SubscriptionRefreshWorkComposition
} from './SubscriptionRefreshComposition';
export type { SubscriptionRefreshWorkComposition } from './SubscriptionRefreshComposition';

const START_NEW_WORK_BUDGET_MS: number = 100 * 1000;

export interface SubscriptionRefreshWorkCompletionPort {
  complete(work: workScheduler.WorkInfo): void;
}

export interface SubscriptionRefreshWorkAbilityDependencies {
  createComposition(context: WorkSchedulerExtensionContext): SubscriptionRefreshWorkComposition;
  completionPort: SubscriptionRefreshWorkCompletionPort;
  nowMs(): number;
}

class HarmonySubscriptionRefreshWorkCompletionPort implements SubscriptionRefreshWorkCompletionPort {
  complete(work: workScheduler.WorkInfo): void {
    workScheduler.stopWork(work, false);
  }
}

class DefaultSubscriptionRefreshWorkAbilityDependencies implements SubscriptionRefreshWorkAbilityDependencies {
  createComposition(context: WorkSchedulerExtensionContext): SubscriptionRefreshWorkComposition {
    return createSubscriptionRefreshComposition(context);
  }

  readonly completionPort: SubscriptionRefreshWorkCompletionPort =
    new HarmonySubscriptionRefreshWorkCompletionPort();

  nowMs(): number {
    return Date.now();
  }
}

let installedDependencies: SubscriptionRefreshWorkAbilityDependencies | undefined = undefined;

export function installSubscriptionRefreshWorkAbilityDependenciesForTesting(
  dependencies: SubscriptionRefreshWorkAbilityDependencies
): void {
  installedDependencies = dependencies;
}

export function resetSubscriptionRefreshWorkAbilityDependenciesForTesting(): void {
  installedDependencies = undefined;
}

export default class SubscriptionRefreshWorkAbility extends WorkSchedulerExtensionAbility {
  private running: boolean = false;
  private cancelled: boolean = false;
  private activeWorkId?: number;

  onWorkStart(work: workScheduler.WorkInfo): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.cancelled = false;
    this.activeWorkId = work.workId;
    const dependencies: SubscriptionRefreshWorkAbilityDependencies = this.resolveDependencies();
    let composition: SubscriptionRefreshWorkComposition;
    let deadlineMs: number;
    try {
      composition = dependencies.createComposition(this.context);
      deadlineMs = resolveDeadlineMs(dependencies.nowMs());
    } catch (_) {
      this.finishWork(work, dependencies.completionPort);
      return;
    }

    void composition.run(deadlineMs, (): boolean => this.cancelled).catch((): void => {
    }).finally((): void => {
      this.finishWork(work, dependencies.completionPort);
    });
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    if (!this.running || this.activeWorkId !== work.workId) {
      return;
    }
    this.cancelled = true;
  }

  private finishWork(work: workScheduler.WorkInfo, completionPort: SubscriptionRefreshWorkCompletionPort): void {
    try {
      completionPort.complete(work);
    } catch (_) {
    }
    this.running = false;
    this.activeWorkId = undefined;
  }

  private resolveDependencies(): SubscriptionRefreshWorkAbilityDependencies {
    if (installedDependencies !== undefined) {
      return installedDependencies;
    }
    return new DefaultSubscriptionRefreshWorkAbilityDependencies();
  }
}

function resolveDeadlineMs(nowMs: number): number {
  if (!Number.isSafeInteger(nowMs) || nowMs < 0 || nowMs > Number.MAX_SAFE_INTEGER - START_NEW_WORK_BUDGET_MS) {
    throw new Error('Subscription refresh work clock was invalid.');
  }
  return nowMs + START_NEW_WORK_BUDGET_MS;
}
