import { describe, expect, it } from '@ohos/hypium';
import { workScheduler } from '@kit.BackgroundTasksKit';
import type { WorkSchedulerExtensionContext } from '@kit.BackgroundTasksKit';
import type { ProfileRefreshPlatformGraph } from '@cmfa/platform';
import type { RefreshProfilesCommand, RefreshProfilesResult } from '@cmfa/shared';
import SubscriptionRefreshWorkAbility, {
  installSubscriptionRefreshWorkAbilityDependenciesForTesting,
  resetSubscriptionRefreshWorkAbilityDependenciesForTesting,
  type SubscriptionRefreshWorkComposition,
  type SubscriptionRefreshWorkCompletionPort
} from '../main/ets/background/SubscriptionRefreshWorkAbility';
import {
  SubscriptionRefreshComposition,
  type SubscriptionRefreshBatchPort
} from '../main/ets/background/SubscriptionRefreshComposition';

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private resolveValue?: (value: T) => void;

  constructor() {
    this.promise = new Promise<T>((resolve) => {
      this.resolveValue = resolve;
    });
  }

  resolve(value: T): void {
    this.resolveValue?.(value);
  }
}

class RecordingComposition implements SubscriptionRefreshWorkComposition {
  readonly startedDeadlines: number[] = [];
  readonly cancellationReaders: Array<() => boolean> = [];
  readonly runs: DeferredValue<void>[] = [];
  throwImmediately: boolean = false;

  async run(deadlineMs: number, isCancelled: () => boolean): Promise<void> {
    this.startedDeadlines.push(deadlineMs);
    this.cancellationReaders.push(isCancelled);
    if (this.throwImmediately) {
      throw new Error('unsafe composition error');
    }
    const deferred = new DeferredValue<void>();
    this.runs.push(deferred);
    await deferred.promise;
  }
}

class RecordingCompletionPort implements SubscriptionRefreshWorkCompletionPort {
  readonly completedIds: number[] = [];
  throwOnComplete: boolean = false;

  complete(work: workScheduler.WorkInfo): void {
    this.completedIds.push(work.workId);
    if (this.throwOnComplete) {
      throw new Error('unsafe completion error');
    }
  }
}

class RecordingBatchPort implements SubscriptionRefreshBatchPort {
  readonly commands: RefreshProfilesCommand[] = [];
  throwOnExecute: boolean = false;

  async execute(command: RefreshProfilesCommand): Promise<RefreshProfilesResult> {
    this.commands.push(command);
    if (this.throwOnExecute) {
      throw new Error('unsafe batch error');
    }
    return {
      items: [],
      deadlineReached: false,
      cancelled: false,
      remainingCount: 0
    };
  }
}

function workInfo(): workScheduler.WorkInfo {
  return {
    workId: 7301,
    bundleName: 'com.github.kr328.clash.harmony',
    abilityName: 'SubscriptionRefreshWorkAbility'
  };
}

async function settleMicrotasks(turns: number = 12): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

export default function subscriptionRefreshWorkAbilityTestsuite() {
  describe('SubscriptionRefreshWorkAbilityTest', () => {
    it('startsWithAOneHundredSecondBudgetAndCompletesAfterTheCurrentRunDrains', 0, async () => {
      const composition = new RecordingComposition();
      const completion = new RecordingCompletionPort();
      installSubscriptionRefreshWorkAbilityDependenciesForTesting({
        createComposition: (): SubscriptionRefreshWorkComposition => composition,
        completionPort: completion,
        nowMs: (): number => 10_000
      });
      const ability = new SubscriptionRefreshWorkAbility();

      ability.onWorkStart(workInfo());
      await settleMicrotasks();
      expect(composition.startedDeadlines).assertDeepEquals([110_000]);
      expect(completion.completedIds.length).assertEqual(0);

      composition.runs[0].resolve(undefined);
      await settleMicrotasks();
      expect(completion.completedIds).assertDeepEquals([7301]);
      resetSubscriptionRefreshWorkAbilityDependenciesForTesting();
    });

    it('marksCancellationOnStopButWaitsForTheInFlightItemToDrain', 0, async () => {
      const composition = new RecordingComposition();
      const completion = new RecordingCompletionPort();
      installSubscriptionRefreshWorkAbilityDependenciesForTesting({
        createComposition: (): SubscriptionRefreshWorkComposition => composition,
        completionPort: completion,
        nowMs: (): number => 20_000
      });
      const ability = new SubscriptionRefreshWorkAbility();
      const work = workInfo();

      ability.onWorkStart(work);
      await settleMicrotasks();
      expect(composition.cancellationReaders[0]()).assertFalse();
      ability.onWorkStop(work);
      expect(composition.cancellationReaders[0]()).assertTrue();
      expect(completion.completedIds.length).assertEqual(0);

      composition.runs[0].resolve(undefined);
      await settleMicrotasks();
      expect(completion.completedIds).assertDeepEquals([7301]);
      resetSubscriptionRefreshWorkAbilityDependenciesForTesting();
    });

    it('ignoresDuplicateStartsWhileOneRunIsActive', 0, async () => {
      const composition = new RecordingComposition();
      const completion = new RecordingCompletionPort();
      installSubscriptionRefreshWorkAbilityDependenciesForTesting({
        createComposition: (): SubscriptionRefreshWorkComposition => composition,
        completionPort: completion,
        nowMs: (): number => 30_000
      });
      const ability = new SubscriptionRefreshWorkAbility();

      ability.onWorkStart(workInfo());
      ability.onWorkStart(workInfo());
      await settleMicrotasks();
      expect(composition.startedDeadlines.length).assertEqual(1);
      composition.runs[0].resolve(undefined);
      await settleMicrotasks();
      expect(completion.completedIds.length).assertEqual(1);
      resetSubscriptionRefreshWorkAbilityDependenciesForTesting();
    });

    it('stillCompletesWhenTheCompositionOrCompletionPortFails', 0, async () => {
      const composition = new RecordingComposition();
      composition.throwImmediately = true;
      const completion = new RecordingCompletionPort();
      completion.throwOnComplete = true;
      installSubscriptionRefreshWorkAbilityDependenciesForTesting({
        createComposition: (): SubscriptionRefreshWorkComposition => composition,
        completionPort: completion,
        nowMs: (): number => 40_000
      });
      const ability = new SubscriptionRefreshWorkAbility();

      ability.onWorkStart(workInfo());
      await settleMicrotasks();
      expect(completion.completedIds).assertDeepEquals([7301]);
      resetSubscriptionRefreshWorkAbilityDependenciesForTesting();
    });

    it('runsTheDueBatchWithTheExactDeadlineAndAlwaysClosesTheGraph', 0, async () => {
      const batch = new RecordingBatchPort();
      let closeCalls = 0;
      const graph = {
        close: async (): Promise<void> => {
          closeCalls += 1;
        }
      } as ProfileRefreshPlatformGraph;
      const composition = new SubscriptionRefreshComposition({} as WorkSchedulerExtensionContext, {
        createPlatformGraph: async (): Promise<ProfileRefreshPlatformGraph> => graph,
        createBatchUseCase: (): SubscriptionRefreshBatchPort => batch
      });
      const cancellation = (): boolean => true;

      await composition.run(123456, cancellation);

      expect(batch.commands.length).assertEqual(1);
      expect(batch.commands[0].mode).assertEqual('DUE');
      expect(batch.commands[0].deadlineMs).assertEqual(123456);
      expect(batch.commands[0].isCancelled === cancellation).assertTrue();
      expect(closeCalls).assertEqual(1);
    });

    it('closesTheProfileGraphWhenTheBatchFails', 0, async () => {
      const batch = new RecordingBatchPort();
      batch.throwOnExecute = true;
      let closeCalls = 0;
      const graph = {
        close: async (): Promise<void> => {
          closeCalls += 1;
        }
      } as ProfileRefreshPlatformGraph;
      const composition = new SubscriptionRefreshComposition({} as WorkSchedulerExtensionContext, {
        createPlatformGraph: async (): Promise<ProfileRefreshPlatformGraph> => graph,
        createBatchUseCase: (): SubscriptionRefreshBatchPort => batch
      });

      try {
        await composition.run(123456, (): boolean => false);
      } catch (_) {
      }

      expect(closeCalls).assertEqual(1);
    });

    it('createsAndClosesAFreshProfileGraphForEveryRepeatedRun', 0, async () => {
      const batch = new RecordingBatchPort();
      let graphCreations = 0;
      let graphCloses = 0;
      const composition = new SubscriptionRefreshComposition({} as WorkSchedulerExtensionContext, {
        createPlatformGraph: async (): Promise<ProfileRefreshPlatformGraph> => {
          graphCreations += 1;
          return {
            close: async (): Promise<void> => {
              graphCloses += 1;
            }
          } as ProfileRefreshPlatformGraph;
        },
        createBatchUseCase: (): SubscriptionRefreshBatchPort => batch
      });

      await composition.run(123456, (): boolean => false);
      await composition.run(223456, (): boolean => false);

      expect(graphCreations).assertEqual(2);
      expect(graphCloses).assertEqual(2);
      expect(batch.commands.length).assertEqual(2);
    });
  });
}
