import { describe, expect, it } from '@ohos/hypium';
import type {
  ApplicationComposition,
  ApplicationCompositionState
} from '../main/ets/bootstrap/ApplicationComposition';
import { reloadApplicationCompositionOnForeground } from '../main/ets/entryability/EntryAbility';
import EntryAbility from '../main/ets/entryability/EntryAbility';

class FakeApplicationComposition implements ApplicationComposition {
  private readonly currentState: ApplicationCompositionState;
  private readonly closeAction?: () => Promise<void>;

  constructor(state: ApplicationCompositionState, closeAction?: () => Promise<void>) {
    this.currentState = state;
    this.closeAction = closeAction;
  }

  async initialize(): Promise<void> {}
  state(): ApplicationCompositionState { return this.currentState; }
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

export default function entryAbilityTestsuite() {
  describe('EntryAbilityTest', () => {
    it('reloadsRepositoryStateOnlyWhenTheCompositionIsReady', 0, async () => {
      let reloadCalls = 0;
      const readyState = {
        status: 'READY',
        application: {
          reloadFromRepository: async (): Promise<void> => {
            reloadCalls += 1;
          }
        }
      } as ApplicationCompositionState;

      const reloaded = await reloadApplicationCompositionOnForeground(
        new FakeApplicationComposition(readyState)
      );
      const skippedLoading = await reloadApplicationCompositionOnForeground(
        new FakeApplicationComposition({ status: 'LOADING' })
      );
      const skippedMissing = await reloadApplicationCompositionOnForeground(undefined);

      expect(reloaded).assertTrue();
      expect(skippedLoading).assertFalse();
      expect(skippedMissing).assertFalse();
      expect(reloadCalls).assertEqual(1);
    });

    it('failsClosedWhenForegroundRepositoryReloadRejects', 0, async () => {
      const readyState = {
        status: 'READY',
        application: {
          reloadFromRepository: async (): Promise<void> => {
            throw new Error('unsafe reload detail');
          }
        }
      } as ApplicationCompositionState;

      const reloaded = await reloadApplicationCompositionOnForeground(
        new FakeApplicationComposition(readyState)
      );

      expect(reloaded).assertFalse();
    });

    it('serializesAnInFlightForegroundReloadBeforeCompositionTeardown', 0, async () => {
      const reloadBarrier = new DeferredValue<void>();
      const events: string[] = [];
      const readyState = {
        status: 'READY',
        application: {
          reloadFromRepository: async (): Promise<void> => {
            events.push('reload.start');
            await reloadBarrier.promise;
            events.push('reload.end');
          }
        }
      } as ApplicationCompositionState;
      const composition = new FakeApplicationComposition(readyState, async (): Promise<void> => {
        events.push('close');
      });
      const ability = new EntryAbility();
      const surface = ability as unknown as EntryAbilityTestSurface;
      surface.applicationComposition = composition;

      ability.onForeground();
      await settleMicrotasks();
      expect(events).assertDeepEquals(['reload.start']);
      ability.onDestroy();
      await settleMicrotasks();
      expect(events).assertDeepEquals(['reload.start']);

      reloadBarrier.resolve(undefined);
      await surface.navigationPromise;
      expect(events).assertDeepEquals(['reload.start', 'reload.end', 'close']);
    });

    it('coalescesDuplicateForegroundEventsWithinOneNavigationGeneration', 0, async () => {
      const reloadBarrier = new DeferredValue<void>();
      let reloadCalls = 0;
      const readyState = {
        status: 'READY',
        application: {
          reloadFromRepository: async (): Promise<void> => {
            reloadCalls += 1;
            await reloadBarrier.promise;
          }
        }
      } as ApplicationCompositionState;
      const ability = new EntryAbility();
      const surface = ability as unknown as EntryAbilityTestSurface;
      surface.applicationComposition = new FakeApplicationComposition(readyState);

      ability.onForeground();
      ability.onForeground();
      ability.onForeground();
      await settleMicrotasks();
      expect(reloadCalls).assertEqual(1);

      reloadBarrier.resolve(undefined);
      await surface.navigationPromise;
      expect(reloadCalls).assertEqual(1);
    });
  });
}
