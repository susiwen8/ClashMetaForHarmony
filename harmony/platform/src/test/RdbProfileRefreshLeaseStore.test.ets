import common from '@ohos.app.ability.common';
import { describe, expect, it } from '@ohos/hypium';
import type { ProfileRefreshLeasePort } from '@cmfa/shared';
import { PlatformFactory, type PlatformFactoryDependencies, type PlatformGraph, type CloseableRdbDriver, type PrepareableHuksDriver } from '../main/ets/PlatformFactory';
import { RdbProfileRefreshLeaseStore } from '../main/ets/rdb/RdbProfileRefreshLeaseStore';
import type { DurableProfileRefreshLeaseRow } from '../main/ets/rdb/RdbDriver';
import {
  DeterministicHuksDriver,
  FakeFileDriver,
  RecordingRdbDriver,
  assertNoLeak
} from './fakes/PlatformFakes';

class CloseableRecordingRdbDriver extends RecordingRdbDriver implements CloseableRdbDriver {
  closeCallCount: number = 0;

  async close(): Promise<void> {
    this.closeCallCount += 1;
  }
}

class RecordingPrepareHuksDriver extends DeterministicHuksDriver implements PrepareableHuksDriver {
  prepareCallCount: number = 0;

  async prepare(): Promise<void> {
    this.prepareCallCount += 1;
    await super.prepare();
  }
}

class FakeProfileRefreshLeasePort implements ProfileRefreshLeasePort {
  readonly label: string;

  constructor(label: string) {
    this.label = label;
  }

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

function createContext(): common.UIAbilityContext {
  return {
    filesDir: '/sandbox/app/files'
  } as common.UIAbilityContext;
}

function createDependencies(
  driver: CloseableRecordingRdbDriver,
  huksDriver: PrepareableHuksDriver
): PlatformFactoryDependencies {
  return {
    createFileDriver: (): FakeFileDriver => new FakeFileDriver(),
    createRdbDriver: (): CloseableRdbDriver => driver,
    createHuksDriver: (): PrepareableHuksDriver => huksDriver,
    createGeodataInstaller: () => ({
      ensureInstalled: async (): Promise<void> => {
      }
    }),
    resolveSdkApiVersion: (): number => 23,
    createPicker: () => ({
      acquire: async () => {
        throw new Error('unused');
      }
    }),
    createNetworkKitTransport: () => ({
      fetch: async () => ({
        statusCode: 200,
        headers: new Map<string, Array<string>>(),
        body: new ArrayBuffer(0)
      })
    }),
    createRequestAgentTransport: () => ({
      fetch: async () => ({
        statusCode: 200,
        headers: new Map<string, Array<string>>(),
        body: new ArrayBuffer(0)
      })
    }),
    createDownloader: () => ({
      acquire: async () => {
        throw new Error('unused');
      }
    }),
    createSourceGateway: () => ({
      acquireLocal: async () => {
        throw new Error('unused');
      },
      acquireRemote: async () => {
        throw new Error('unused');
      }
    })
  };
}

function buildLeaseRow(
  profileId: string,
  ownerToken: string,
  expiresAtMs: number
): DurableProfileRefreshLeaseRow {
  return {
    profileId,
    ownerToken,
    expiresAtMs
  };
}

async function expectSafeValidationFailure(
  operation: () => Promise<boolean>,
  forbiddenFragments: string[]
): Promise<void> {
  try {
    await operation();
    expect(false).assertTrue();
  } catch (error) {
    const message: string = error instanceof Error ? error.message : `${error}`;
    expect(message.length > 0).assertTrue();
    assertNoLeak(message, forbiddenFragments);
  }
}

export default function rdbProfileRefreshLeaseStoreTestsuite() {
  describe('RdbProfileRefreshLeaseStoreTest', () => {
    it('acquiresBlocksAndTransfersLeasesAccordingToOwnerAndExpiry', 0, async () => {
      const driver = new RecordingRdbDriver();
      const store = new RdbProfileRefreshLeaseStore(driver);

      expect(await store.tryAcquire('profile-a', 'owner-a', 100, 200)).assertTrue();
      expect(await store.tryAcquire('profile-a', 'owner-b', 120, 220)).assertFalse();
      expect(await store.tryAcquire('profile-a', 'owner-a', 130, 260)).assertTrue();
      expect(await store.tryAcquire('profile-a', 'owner-b', 260, 360)).assertTrue();
      expect(driver.log.join('>')).assertContain('begin>tx.getProfileRefreshLeaseRow:profile-a>tx.upsertProfileRefreshLeaseRow:profile-a>commit');
    });

    it('treatsExpiresAtEqualToNowAsExpired', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedProfileRefreshLeaseRow(buildLeaseRow('profile-boundary', 'owner-a', 300));
      const store = new RdbProfileRefreshLeaseStore(driver);

      expect(await store.tryAcquire('profile-boundary', 'owner-b', 300, 450)).assertTrue();
    });

    it('renewsOnlyForTheCurrentOwnerAndReleasesByCompareAndDelete', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedProfileRefreshLeaseRow(buildLeaseRow('profile-a', 'owner-a', 200));
      const store = new RdbProfileRefreshLeaseStore(driver);

      expect(await store.renew('profile-a', 'owner-a', 150, 300)).assertTrue();
      expect(await store.renew('profile-a', 'owner-b', 150, 310)).assertFalse();
      expect(await store.renew('missing-profile', 'owner-a', 150, 310)).assertFalse();
      expect(await store.release('profile-a', 'owner-b')).assertFalse();
      expect(driver.readProfileRefreshLeaseRow('profile-a')?.ownerToken).assertEqual('owner-a');
      expect(await store.release('profile-a', 'owner-a')).assertTrue();
      expect(driver.readProfileRefreshLeaseRow('profile-a')).assertUndefined();
      expect(await store.release('profile-a', 'owner-a')).assertFalse();
    });

    it('keepsTheReplacementLeaseWhenTheOldOwnerReleasesAfterOwnershipChanged', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedProfileRefreshLeaseRow(buildLeaseRow('profile-a', 'owner-a', 200));
      driver.replaceProfileRefreshLeaseRowBeforeNextDelete(buildLeaseRow('profile-a', 'owner-b', 400));
      const store = new RdbProfileRefreshLeaseStore(driver);

      expect(await store.release('profile-a', 'owner-a')).assertFalse();
      expect(driver.readProfileRefreshLeaseRow('profile-a')?.ownerToken).assertEqual('owner-b');
      expect(driver.readProfileRefreshLeaseRow('profile-a')?.expiresAtMs).assertEqual(400);
    });

    it('rollsBackAcquireAndReleaseMutationsWhenTheTransactionWriteFails', 0, async () => {
      const acquireDriver = new RecordingRdbDriver();
      acquireDriver.seedProfileRefreshLeaseRow(buildLeaseRow('profile-a', 'owner-a', 200));
      acquireDriver.injectFailure('tx.upsertProfileRefreshLeaseRow:profile-a', new Error('synthetic-upsert-failure'));
      const acquireStore = new RdbProfileRefreshLeaseStore(acquireDriver);

      try {
        await acquireStore.tryAcquire('profile-a', 'owner-b', 250, 400);
        expect(false).assertTrue();
      } catch (_) {
      }

      const acquireRow = acquireDriver.readProfileRefreshLeaseRow('profile-a');
      expect(acquireRow?.ownerToken).assertEqual('owner-a');
      expect(acquireRow?.expiresAtMs).assertEqual(200);

      const releaseDriver = new RecordingRdbDriver();
      releaseDriver.seedProfileRefreshLeaseRow(buildLeaseRow('profile-b', 'owner-b', 500));
      releaseDriver.injectFailure('tx.deleteProfileRefreshLeaseRowIfOwned:profile-b', new Error('synthetic-delete-failure'));
      const releaseStore = new RdbProfileRefreshLeaseStore(releaseDriver);

      try {
        await releaseStore.release('profile-b', 'owner-b');
        expect(false).assertTrue();
      } catch (_) {
      }

      const releaseRow = releaseDriver.readProfileRefreshLeaseRow('profile-b');
      expect(releaseRow?.ownerToken).assertEqual('owner-b');
      expect(releaseRow?.expiresAtMs).assertEqual(500);
    });

    it('rejectsInvalidInputsWithoutLeakingProfileIdsOrTokens', 0, async () => {
      const store = new RdbProfileRefreshLeaseStore(new RecordingRdbDriver());
      const overlong = 'x'.repeat(257);

      await expectSafeValidationFailure(
        async (): Promise<boolean> => await store.tryAcquire('', 'owner-a', 1, 2),
        ['owner-a']
      );
      await expectSafeValidationFailure(
        async (): Promise<boolean> => await store.tryAcquire('profile-a', '', 1, 2),
        ['profile-a']
      );
      await expectSafeValidationFailure(
        async (): Promise<boolean> => await store.tryAcquire(overlong, 'owner-a', 1, 2),
        [overlong, 'owner-a']
      );
      await expectSafeValidationFailure(
        async (): Promise<boolean> => await store.tryAcquire('profile-a', overlong, 1, 2),
        ['profile-a', overlong]
      );
      await expectSafeValidationFailure(
        async (): Promise<boolean> => await store.tryAcquire('profile-a', 'owner-a', -1, 2),
        ['profile-a', 'owner-a']
      );
      await expectSafeValidationFailure(
        async (): Promise<boolean> => await store.tryAcquire('profile-a', 'owner-a', 1.5, 2),
        ['profile-a', 'owner-a']
      );
      await expectSafeValidationFailure(
        async (): Promise<boolean> => await store.tryAcquire('profile-a', 'owner-a', Number.MAX_SAFE_INTEGER + 1, Number.MAX_SAFE_INTEGER + 2),
        ['profile-a', 'owner-a']
      );
      await expectSafeValidationFailure(
        async (): Promise<boolean> => await store.tryAcquire('profile-a', 'owner-a', 10, 10),
        ['profile-a', 'owner-a']
      );
    });

    it('surfacesInvalidDeleteAffectedRowsWithSafeErrorsAndNoTokenLeak', 0, async () => {
      const invalidDriver = new RecordingRdbDriver();
      invalidDriver.seedProfileRefreshLeaseRow(buildLeaseRow('profile-a', 'owner-a', 200));
      invalidDriver.overrideNextDeleteAffectedRows(Number.NaN);
      const invalidStore = new RdbProfileRefreshLeaseStore(invalidDriver);

      await expectSafeValidationFailure(
        async (): Promise<boolean> => await invalidStore.release('profile-a', 'owner-a'),
        ['profile-a', 'owner-a']
      );
      expect(invalidDriver.readProfileRefreshLeaseRow('profile-a')?.ownerToken).assertEqual('owner-a');

      const corruptDriver = new RecordingRdbDriver();
      corruptDriver.seedProfileRefreshLeaseRow(buildLeaseRow('profile-b', 'owner-b', 300));
      corruptDriver.overrideNextDeleteAffectedRows(2);
      const corruptStore = new RdbProfileRefreshLeaseStore(corruptDriver);

      await expectSafeValidationFailure(
        async (): Promise<boolean> => await corruptStore.release('profile-b', 'owner-b'),
        ['profile-b', 'owner-b']
      );
      expect(corruptDriver.readProfileRefreshLeaseRow('profile-b')?.ownerToken).assertEqual('owner-b');
    });

    it('exposesInjectedAndDefaultLeasePortsWithoutAddingExtraDriverCloseCalls', 0, async () => {
      const context = createContext();
      const injectedDriver = new CloseableRecordingRdbDriver();
      const injectedLeasePort = new FakeProfileRefreshLeasePort('injected');
      const injectedDependencies = createDependencies(injectedDriver, new RecordingPrepareHuksDriver());
      let observedLeaseDriver: CloseableRdbDriver | undefined = undefined;

      injectedDependencies.createProfileRefreshLeasePort = (driver: CloseableRdbDriver): ProfileRefreshLeasePort => {
        observedLeaseDriver = driver;
        return injectedLeasePort;
      };

      const injectedGraph: PlatformGraph = await new PlatformFactory(context, injectedDependencies).create();
      expect(observedLeaseDriver === injectedDriver).assertTrue();
      expect(injectedGraph.profileRefreshLeasePort === injectedLeasePort).assertTrue();

      await injectedGraph.close();
      expect(injectedDriver.closeCallCount).assertEqual(1);

      const defaultDriver = new CloseableRecordingRdbDriver();
      const defaultGraph: PlatformGraph = await new PlatformFactory(
        context,
        createDependencies(defaultDriver, new RecordingPrepareHuksDriver())
      ).create();

      expect(defaultGraph.profileRefreshLeasePort instanceof RdbProfileRefreshLeaseStore).assertTrue();
      await defaultGraph.close();
      expect(defaultDriver.closeCallCount).assertEqual(1);
    });
  });
}
