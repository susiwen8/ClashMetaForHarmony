import { describe, expect, it } from '@ohos/hypium';
import type {
  ApplicationComposition,
  ApplicationCompositionState
} from '../main/ets/bootstrap/ApplicationComposition';
import { reloadApplicationCompositionOnForeground } from '../main/ets/entryability/EntryAbility';
import EntryAbility from '../main/ets/entryability/EntryAbility';

interface ReloadRepositoryPort {
  reloadFromRepository(): Promise<void>;
}

interface ReadyCompositionState {
  status: 'READY';
  application: ReloadRepositoryPort;
}

interface LoadingCompositionState {
  status: 'LOADING';
}

class ReloadRepositoryPortRecord implements ReloadRepositoryPort {
  private readonly reloadAction: () => Promise<void>;

  constructor(reloadAction: () => Promise<void>) {
    this.reloadAction = reloadAction;
  }

  async reloadFromRepository(): Promise<void> {
    await this.reloadAction();
  }
}

class FakeApplicationComposition implements ApplicationComposition {
  private readonly currentState: ReadyCompositionState | LoadingCompositionState;
  private readonly closeAction?: () => Promise<void>;

  constructor(state: ReadyCompositionState | LoadingCompositionState, closeAction?: () => Promise<void>) {
    this.currentState = state;
    this.closeAction = closeAction;
  }

  async initialize(): Promise<void> {}
  state(): ApplicationCompositionState { return this.currentState as ApplicationCompositionState; }
  subscribe(): number { return 1; }
  unsubscribe(): void {}
  async close(): Promise<void> { await this.closeAction?.(); }
}

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private resolveValue?: (value: T) => void;

  constructor() {
    this.promise = new Promise<T>((resolve) => {
      this.resolveValue = resolve;
    });
  }

  resolve(value: T): void { this.resolveValue?.(value); }
}

interface EntryAbilityTestSurface {
  applicationComposition?: ApplicationComposition;
  navigationPromise: Promise<void>;
}

async function settleMicrotasks(turns: number = 8): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

function createReadyState(reloadFromRepository: () => Promise<void>): ReadyCompositionState {
  return {
    status: 'READY',
    application: new ReloadRepositoryPortRecord(reloadFromRepository)
  };
}

function createLoadingState(): LoadingCompositionState {
  return {
    status: 'LOADING'
  };
}

export default function entryAbilityTestsuite() {
  describe('EntryAbilityTest', () => {
    it('reloadsRepositoryStateOnlyWhenTheCompositionIsReady', 0, async () => {
      let reloadCalls = 0;
      const readyState = createReadyState(async (): Promise<void> => {
        reloadCalls += 1;
      });

      const reloaded = await reloadApplicationCompositionOnForeground(
        new FakeApplicationComposition(readyState)
      );
      const skippedLoading = await reloadApplicationCompositionOnForeground(
        new FakeApplicationComposition(createLoadingState())
      );
      const skippedMissing = await reloadApplicationCompositionOnForeground(undefined);

      expect(reloaded).assertTrue();
      expect(skippedLoading).assertFalse();
      expect(skippedMissing).assertFalse();
      expect(reloadCalls).assertEqual(1);
    });

    it('failsClosedWhenForegroundRepositoryReloadRejects', 0, async () => {
      const readyState = createReadyState(async (): Promise<void> => {
        throw new Error('unsafe reload detail');
      });

      const reloaded = await reloadApplicationCompositionOnForeground(
        new FakeApplicationComposition(readyState)
      );

      expect(reloaded).assertFalse();
    });

    it('serializesAnInFlightForegroundReloadBeforeCompositionTeardown', 0, async () => {
      const reloadBarrier = new DeferredValue<void>();
      const events: string[] = [];
      const readyState = createReadyState(async (): Promise<void> => {
        events.push('reload.start');
        await reloadBarrier.promise;
        events.push('reload.end');
      });
      const composition = new FakeApplicationComposition(readyState, async (): Promise<void> => {
        events.push('close');
      });
      const ability = new EntryAbility();
      Reflect.set(ability, 'applicationComposition', composition);

      ability.onForeground();
      await settleMicrotasks();
      expect(events).assertDeepEquals(['reload.start']);
      ability.onDestroy();
      await settleMicrotasks();
      expect(events).assertDeepEquals(['reload.start']);

      reloadBarrier.resolve(undefined);
      await Reflect.get(ability, 'navigationPromise') as Promise<void>;
      expect(events).assertDeepEquals(['reload.start', 'reload.end', 'close']);
    });

    it('coalescesDuplicateForegroundEventsWithinOneNavigationGeneration', 0, async () => {
      const reloadBarrier = new DeferredValue<void>();
      let reloadCalls = 0;
      const readyState = createReadyState(async (): Promise<void> => {
        reloadCalls += 1;
        await reloadBarrier.promise;
      });
      const ability = new EntryAbility();
      Reflect.set(ability, 'applicationComposition', new FakeApplicationComposition(readyState));

      ability.onForeground();
      ability.onForeground();
      ability.onForeground();
      await settleMicrotasks();
      expect(reloadCalls).assertEqual(1);

      reloadBarrier.resolve(undefined);
      await Reflect.get(ability, 'navigationPromise') as Promise<void>;
      expect(reloadCalls).assertEqual(1);
    });
  });
}
