import { describe, expect, it } from '@ohos/hypium';
import { workScheduler } from '@kit.BackgroundTasksKit';
import type { WorkSchedulerExtensionContext } from '@kit.BackgroundTasksKit';
import type { ProfileRefreshPlatformGraph } from '@cmfa/platform';
import type {
  Clock,
  IdGenerator,
  LocalAcquireCommand,
  LocalProfileAcquisition,
  Profile,
  ProfileContentStore,
  ProfileRefreshLeasePort,
  ProfileRepository,
  ProfileRevision,
  ProfileSourceGateway,
  RemoteAcquireCommand,
  RemoteProfileAcquisition,
  StagedSource,
  SubscriptionSecretStore,
  RefreshProfilesCommand,
  RefreshProfilesResult
} from '@cmfa/shared';
import SubscriptionRefreshWorkAbility, {
  installSubscriptionRefreshWorkAbilityDependenciesForTesting,
  resetSubscriptionRefreshWorkAbilityDependenciesForTesting,
  type SubscriptionRefreshWorkAbilityDependencies,
  type SubscriptionRefreshWorkComposition,
  type SubscriptionRefreshWorkCompletionPort
} from '../main/ets/background/SubscriptionRefreshWorkAbility';
import {
  SubscriptionRefreshComposition,
  type SubscriptionRefreshCompositionDependencies,
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

class RecordingSubscriptionRefreshWorkAbilityDependencies implements SubscriptionRefreshWorkAbilityDependencies {
  readonly completionPort: SubscriptionRefreshWorkCompletionPort;
  private readonly compositionFactory: () => SubscriptionRefreshWorkComposition;
  private readonly nowMsFactory: () => number;

  constructor(
    compositionFactory: () => SubscriptionRefreshWorkComposition,
    completionPort: SubscriptionRefreshWorkCompletionPort,
    nowMsFactory: () => number
  ) {
    this.compositionFactory = compositionFactory;
    this.completionPort = completionPort;
    this.nowMsFactory = nowMsFactory;
  }

  createComposition(_context: WorkSchedulerExtensionContext): SubscriptionRefreshWorkComposition {
    return this.compositionFactory();
  }

  nowMs(): number {
    return this.nowMsFactory();
  }
}

class RecordingSubscriptionRefreshCompositionDependencies implements SubscriptionRefreshCompositionDependencies {
  private readonly graphFactory: () => Promise<ProfileRefreshPlatformGraph>;
  private readonly batchFactory: (graph: ProfileRefreshPlatformGraph) => SubscriptionRefreshBatchPort;

  constructor(
    graphFactory: () => Promise<ProfileRefreshPlatformGraph>,
    batchFactory: (graph: ProfileRefreshPlatformGraph) => SubscriptionRefreshBatchPort
  ) {
    this.graphFactory = graphFactory;
    this.batchFactory = batchFactory;
  }

  async createPlatformGraph(_context: WorkSchedulerExtensionContext): Promise<ProfileRefreshPlatformGraph> {
    return await this.graphFactory();
  }

  createBatchUseCase(graph: ProfileRefreshPlatformGraph): SubscriptionRefreshBatchPort {
    return this.batchFactory(graph);
  }
}

class RecordingBatchPort implements SubscriptionRefreshBatchPort {
  readonly commands: RefreshProfilesCommand[] = [];
  throwOnExecute: boolean = false;
  throwError?: Error;

  async execute(command: RefreshProfilesCommand): Promise<RefreshProfilesResult> {
    this.commands.push(command);
    if (this.throwOnExecute) {
      throw this.throwError ?? new Error('unsafe batch error');
    }
    return {
      items: [],
      deadlineReached: false,
      cancelled: false,
      remainingCount: 0
    };
  }
}

class InertProfileRepository implements ProfileRepository {
  async list(): Promise<Profile[]> {
    return [];
  }

  async get(_id: string): Promise<Profile | undefined> {
    return undefined;
  }

  async save(_profile: Profile): Promise<void> {
  }

  async deleteAndClearActive(_id: string): Promise<void> {
  }

  async getActiveId(): Promise<string | undefined> {
    return undefined;
  }

  async setActiveId(_id: string | undefined): Promise<void> {
  }
}

class InertProfileContentStore implements ProfileContentStore {
  async retain(_profileId: string, _staged: StagedSource, _kind: 'CURRENT' | 'FAILED_CANDIDATE'): Promise<ProfileRevision> {
    throw new Error('unused profile content store');
  }

  async discard(_staged: StagedSource): Promise<void> {
  }

  async removeRevision(_revision: ProfileRevision): Promise<void> {
  }

  async removeProfile(_profileId: string): Promise<void> {
  }

  async reconcile(_referenced: ProfileRevision[]): Promise<void> {
  }

  resolveCorePath(_revision: ProfileRevision): string {
    return '';
  }
}

class InertProfileSourceGateway implements ProfileSourceGateway {
  async acquireLocal(_command: LocalAcquireCommand): Promise<LocalProfileAcquisition> {
    throw new Error('unused local acquisition');
  }

  async acquireRemote(_command: RemoteAcquireCommand): Promise<RemoteProfileAcquisition> {
    throw new Error('unused remote acquisition');
  }
}

class InertSubscriptionSecretStore implements SubscriptionSecretStore {
  async encrypt(_plaintext: string): Promise<string> {
    return 'secret-ref';
  }

  async decrypt(_secretRef: string): Promise<string> {
    return 'secret-value';
  }

  async remove(_secretRef: string): Promise<void> {
  }
}

class InertClock implements Clock {
  now(): string {
    return '2026-09-02T00:00:00.000Z';
  }
}

class InertIdGenerator implements IdGenerator {
  nextId(): string {
    return 'test-id';
  }
}

class InertProfileRefreshLeasePort implements ProfileRefreshLeasePort {
  async tryAcquire(_profileId: string, _ownerToken: string, _nowMs: number, _expiresAtMs: number): Promise<boolean> {
    return true;
  }

  async renew(_profileId: string, _ownerToken: string, _nowMs: number, _expiresAtMs: number): Promise<boolean> {
    return true;
  }

  async release(_profileId: string, _ownerToken: string): Promise<boolean> {
    return true;
  }
}

class RecordingProfileRefreshPlatformGraph implements ProfileRefreshPlatformGraph {
  readonly repository: ProfileRepository = new InertProfileRepository();
  readonly profileRefreshLeasePort: ProfileRefreshLeasePort = new InertProfileRefreshLeasePort();
  readonly contentStore: ProfileContentStore = new InertProfileContentStore();
  readonly sourceGateway: ProfileSourceGateway = new InertProfileSourceGateway();
  readonly secretStore: SubscriptionSecretStore = new InertSubscriptionSecretStore();
  readonly clock: Clock = new InertClock();
  readonly idGenerator: IdGenerator = new InertIdGenerator();
  private readonly closeAction: () => Promise<void>;

  constructor(closeAction: () => Promise<void>) {
    this.closeAction = closeAction;
  }

  async close(): Promise<void> {
    await this.closeAction();
  }
}

function createDependencies(
  compositionFactory: () => SubscriptionRefreshWorkComposition,
  completionPort: SubscriptionRefreshWorkCompletionPort,
  nowMs: () => number
): SubscriptionRefreshWorkAbilityDependencies {
  return new RecordingSubscriptionRefreshWorkAbilityDependencies(compositionFactory, completionPort, nowMs);
}

function createGraph(closeAction: () => Promise<void>): ProfileRefreshPlatformGraph {
  return new RecordingProfileRefreshPlatformGraph(closeAction);
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
      installSubscriptionRefreshWorkAbilityDependenciesForTesting(
        createDependencies((): SubscriptionRefreshWorkComposition => composition, completion, (): number => 10_000)
      );
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
      installSubscriptionRefreshWorkAbilityDependenciesForTesting(
        createDependencies((): SubscriptionRefreshWorkComposition => composition, completion, (): number => 20_000)
      );
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
      installSubscriptionRefreshWorkAbilityDependenciesForTesting(
        createDependencies((): SubscriptionRefreshWorkComposition => composition, completion, (): number => 30_000)
      );
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
      installSubscriptionRefreshWorkAbilityDependenciesForTesting(
        createDependencies((): SubscriptionRefreshWorkComposition => composition, completion, (): number => 40_000)
      );
      const ability = new SubscriptionRefreshWorkAbility();

      ability.onWorkStart(workInfo());
      await settleMicrotasks();
      expect(completion.completedIds).assertDeepEquals([7301]);
      resetSubscriptionRefreshWorkAbilityDependenciesForTesting();
    });

    it('runsTheDueBatchWithTheExactDeadlineAndAlwaysClosesTheGraph', 0, async () => {
      const batch = new RecordingBatchPort();
      let closeCalls = 0;
      const graph = createGraph(async (): Promise<void> => {
        closeCalls += 1;
      });
      const composition = new SubscriptionRefreshComposition(
        {} as WorkSchedulerExtensionContext,
        new RecordingSubscriptionRefreshCompositionDependencies(
          async (): Promise<ProfileRefreshPlatformGraph> => graph,
          (): SubscriptionRefreshBatchPort => batch
        )
      );
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
      const graph = createGraph(async (): Promise<void> => {
        closeCalls += 1;
      });
      const composition = new SubscriptionRefreshComposition(
        {} as WorkSchedulerExtensionContext,
        new RecordingSubscriptionRefreshCompositionDependencies(
          async (): Promise<ProfileRefreshPlatformGraph> => graph,
          (): SubscriptionRefreshBatchPort => batch
        )
      );

      try {
        await composition.run(123456, (): boolean => false);
      } catch (_) {
      }

      expect(closeCalls).assertEqual(1);
    });

    it('preservesTheBatchErrorWhenBatchAndGraphCloseBothFail', 0, async () => {
      const batchError = new Error('primary batch error');
      const batch = new RecordingBatchPort();
      batch.throwOnExecute = true;
      batch.throwError = batchError;
      const graph = createGraph(async (): Promise<void> => {
        throw new Error('secondary close error');
      });
      const composition = new SubscriptionRefreshComposition(
        {} as WorkSchedulerExtensionContext,
        new RecordingSubscriptionRefreshCompositionDependencies(
          async (): Promise<ProfileRefreshPlatformGraph> => graph,
          (): SubscriptionRefreshBatchPort => batch
        )
      );
      let caught: Error | undefined = undefined;

      try {
        await composition.run(123456, (): boolean => false);
      } catch (error) {
        caught = error as Error;
      }

      expect(caught === batchError).assertTrue();
    });

    it('createsAndClosesAFreshProfileGraphForEveryRepeatedRun', 0, async () => {
      const batch = new RecordingBatchPort();
      let graphCreations = 0;
      let graphCloses = 0;
      const composition = new SubscriptionRefreshComposition(
        {} as WorkSchedulerExtensionContext,
        new RecordingSubscriptionRefreshCompositionDependencies(
          async (): Promise<ProfileRefreshPlatformGraph> => {
            graphCreations += 1;
            return createGraph(async (): Promise<void> => {
              graphCloses += 1;
            });
          },
          (): SubscriptionRefreshBatchPort => batch
        )
      );

      await composition.run(123456, (): boolean => false);
      await composition.run(223456, (): boolean => false);

      expect(graphCreations).assertEqual(2);
      expect(graphCloses).assertEqual(2);
      expect(batch.commands.length).assertEqual(2);
    });
  });
}
