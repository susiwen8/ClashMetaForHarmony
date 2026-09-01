import { describe, expect, it } from '@ohos/hypium';
import type {
  ApplicationComposition,
  ApplicationCompositionState
} from '../main/ets/bootstrap/ApplicationComposition';
import { reloadApplicationCompositionOnForeground } from '../main/ets/entryability/EntryAbility';

class FakeApplicationComposition implements ApplicationComposition {
  private readonly currentState: ApplicationCompositionState;

  constructor(state: ApplicationCompositionState) {
    this.currentState = state;
  }

  async initialize(): Promise<void> {}
  state(): ApplicationCompositionState { return this.currentState; }
  subscribe(): number { return 1; }
  unsubscribe(): void {}
  async close(): Promise<void> {}
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
  });
}
