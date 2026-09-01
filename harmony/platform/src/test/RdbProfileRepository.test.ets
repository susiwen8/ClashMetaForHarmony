import { describe, expect, it } from '@ohos/hypium';
import type { Profile } from '@cmfa/shared';
import { RdbProfileRepository } from '../main/ets/rdb/RdbProfileRepository';
import { encodeProfileRow } from '../main/ets/rdb/ProfileRowCodec';
import { encodeProxySelectionRow } from '../main/ets/rdb/ProxySelectionRowCodec';
import { createProxySelectionRecord } from '@cmfa/shared';
import {
  assertAppErrorExactDetail,
  assertCanonicalTimestampWithinRange,
  RecordingRdbDriver,
  assertAppErrorShape,
  assertNoLeak,
  buildAppError,
  buildProfile,
  cloneDurableRow
} from './fakes/PlatformFakes';

class PersistenceErrorRecord {
  readonly technicalDetail: string;
  readonly timestamp: string;

  constructor(technicalDetail: string, timestamp: string) {
    this.technicalDetail = technicalDetail;
    this.timestamp = timestamp;
  }
}

function stitch(parts: string[]): string {
  return parts.join('');
}

function buildUnsafeHomePath(leaf: string): string {
  return stitch(['/Us', 'ers/susiwen8/Documents/github/ClashMetaForAndroid/profiles/', leaf]);
}

function buildUnsafeHomePrefix(): string {
  return stitch(['/Us', 'ers/susiwen8/Documents']);
}

function buildUnsafeSecretPath(): string {
  return stitch(['/Us', 'ers/susiwen8/Documents/secret.yaml']);
}

function buildUnsafeUrl(pathSuffix: string): string {
  return stitch(['https://user:', 'sec', 'ret', '@remote.example.com/', pathSuffix]);
}

function buildUnsafeYamlAssignment(): string {
  return stitch(['yaml=proxy-providers:\\n  ', 'sec', 'ret', ': abc123 ']);
}

function buildUnsafeLastErrorJson(): string {
  return JSON.stringify({
    stage: 'DOWNLOAD',
    code: 'CMFA_REMOTE_TIMEOUT',
    userMessageResource: 'error.remote.timeout',
    technicalDetail: stitch([
      'yaml: ',
      'sec',
      'ret',
      ': abc123\\nurl: ',
      buildUnsafeUrl('profile.yaml?token=abc123')
    ]),
    timestamp: '2026-08-07T00:00:00.000Z',
    retryable: true
  });
}

function buildUnsafeRevisionJson(): string {
  return JSON.stringify({
    relativePath: stitch(['/Us', 'ers/susiwen8/Documents/secret.yaml']),
    sha256Digest: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    byteLength: 1,
    validatedAt: '2026-08-07T00:00:00.000Z'
  });
}

function buildUnsafePayload(prefix: string): string {
  return `${prefix} ${buildUnsafeUrl('profile.yaml?token=abc123')} ` +
    `row={"id":"remote-redact","source":"https://remote.example.com/path"} ` +
    `${buildUnsafeYamlAssignment()}` +
    `path=${buildUnsafeHomePath('profile.yaml')}`;
}

async function expectPersistenceFailure(operation: () => Promise<void>, expectedDetail: string, forbidden: string[]): Promise<void> {
  try {
    await operation();
    expect(false).assertTrue();
  } catch (error) {
    assertAppErrorShape(error as Object, expectedDetail);
    const detail: string = (error as PersistenceErrorRecord).technicalDetail;
    assertNoLeak(detail, forbidden);
  }
}

async function expectSafeFallbackFailure(
  operation: () => Promise<void>,
  expectedDetail: string,
  forbidden: string[]
): Promise<void> {
  try {
    await operation();
    expect(false).assertTrue();
  } catch (error) {
    assertAppErrorExactDetail(error as Object, expectedDetail);
    const detail: string = (error as PersistenceErrorRecord).technicalDetail;
    assertNoLeak(detail, forbidden);
  }
}

export default function rdbProfileRepositoryTestsuite() {
  describe('RdbProfileRepositoryTest', () => {
    it('memoizesConcurrentFirstUseInitializationAndRetriesAfterFailure', 0, async () => {
      const driver = new RecordingRdbDriver();
      const initializeReleased = driver.blockNextInitialize();
      const initializeStarted = driver.nextInitializeStarted();
      const repository = new RdbProfileRepository(driver);

      const listPromise: Promise<Profile[]> = repository.list();
      const getPromise: Promise<Profile | undefined> = repository.get('concurrent-profile');
      await initializeStarted.promise;
      await Promise.resolve();
      await Promise.resolve();

      expect(driver.initializeCallCount).assertEqual(1);

      initializeReleased.resolve(undefined);
      const listResult: Profile[] = await listPromise;
      const getResult: Profile | undefined = await getPromise;

      expect(listResult.length).assertEqual(0);
      expect(getResult).assertUndefined();
      expect(driver.log[0]).assertEqual('initialize:3');

      const retryDriver = new RecordingRdbDriver();
      retryDriver.injectFailure('initialize', new Error('first init failed'));
      const retryRepository = new RdbProfileRepository(retryDriver);

      await expectSafeFallbackFailure(
        async () => {
          await retryRepository.list();
        },
        'Profile persistence initialization failed.',
        ['first init failed']
      );
      expect(retryDriver.initializeCallCount).assertEqual(1);

      const retriedList: Profile[] = await retryRepository.list();
      expect(retryDriver.initializeCallCount).assertEqual(2);
      expect(retriedList.length).assertEqual(0);
      expect(retryDriver.log[0]).assertEqual('initialize:3');
    });

    it('recreatesMissingAppStateSingletonWhenSettingAndClearingActiveId', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedMissingAppState();
      driver.seedRow(encodeProfileRow(buildProfile('local-valid', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/local-valid/current.yaml')));
      const repository = new RdbProfileRepository(driver);

      await repository.setActiveId('local-valid');

      const rereadRepository = new RdbProfileRepository(driver);
      expect(await rereadRepository.getActiveId()).assertEqual('local-valid');
      expect(driver.isAppStatePresent()).assertTrue();

      await rereadRepository.setActiveId(undefined);
      const clearedRepository = new RdbProfileRepository(driver);
      expect(await clearedRepository.getActiveId()).assertUndefined();
      expect(driver.isAppStatePresent()).assertTrue();
    });

    it('usesNonFixedCurrentTimestampForPersistenceFailures', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.injectFailure('listProfileRows', new Error(buildUnsafePayload('driver list failed')));
      const repository = new RdbProfileRepository(driver);
      const earliest: string = new Date().toISOString();

      try {
        await repository.list();
        expect(false).assertTrue();
      } catch (error) {
        const latest: string = new Date().toISOString();
        assertAppErrorExactDetail(error as Object, 'Profile list failed.');
        const record = error as PersistenceErrorRecord;
        assertCanonicalTimestampWithinRange(record.timestamp, earliest, latest, '2026-08-11T00:00:00.000Z');
      }
    });

    it('revalidatesCachedActiveIdAfterSuccessfulSaveMutatesTheActiveProfile', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedActiveId('active-profile');
      driver.seedRow(encodeProfileRow(buildProfile('active-profile', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/active-profile/current.yaml')));
      const repository = new RdbProfileRepository(driver);

      expect(await repository.getActiveId()).assertEqual('active-profile');
      driver.log.length = 0;

      await repository.save(buildProfile('active-profile', 'INVALID', '2026-08-07T00:03:00.000Z'));

      expect(await repository.getActiveId()).assertUndefined();
      expect(driver.currentActiveId()).assertUndefined();
      expect(driver.log.join('>')).assertContain('upsertProfileRow:active-profile>readActiveId>getProfileRow:active-profile>begin>tx.setActiveId:<cleared>>commit');
    });

    it('revalidatesCachedActiveIdAfterSuccessfulSaveKeepsStillValidActiveProfile', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedActiveId('active-profile');
      driver.seedRow(encodeProfileRow(buildProfile('active-profile', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/active-profile/current.yaml')));
      const repository = new RdbProfileRepository(driver);

      expect(await repository.getActiveId()).assertEqual('active-profile');
      driver.log.length = 0;

      await repository.save(buildProfile('active-profile', 'VALID', '2026-08-07T00:03:00.000Z', 'profiles/active-profile/current-next.yaml'));

      expect(await repository.getActiveId()).assertEqual('active-profile');
      expect(driver.currentActiveId()).assertEqual('active-profile');
      expect(driver.log.join('>')).assertContain('upsertProfileRow:active-profile>readActiveId>getProfileRow:active-profile');
    });

    it('keepsCachedActiveIdWhenSaveFailsBeforeMutatingDriverState', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedActiveId('active-profile');
      driver.seedRow(encodeProfileRow(buildProfile('active-profile', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/active-profile/current.yaml')));
      const repository = new RdbProfileRepository(driver);

      expect(await repository.getActiveId()).assertEqual('active-profile');
      driver.log.length = 0;
      driver.injectFailure('upsertProfileRow:active-profile', new Error(buildUnsafePayload('driver save failed')));

      await expectSafeFallbackFailure(
        async () => {
          await repository.save(buildProfile('active-profile', 'VALID', '2026-08-07T00:04:00.000Z', 'profiles/active-profile/current-next.yaml'));
        },
        'Profile save failed.',
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', buildUnsafeHomePrefix()]
      );

      driver.injectFailure('readActiveId', new Error('should not reread cached active id'));
      expect(await repository.getActiveId()).assertEqual('active-profile');
      expect(driver.log.join('>')).assertContain('upsertProfileRow:active-profile');
    });

    it('createsListsGetsAndUpsertsProfilesWithDeterministicOrdering', 0, async () => {
      const driver = new RecordingRdbDriver();
      const repository = new RdbProfileRepository(driver);
      const later: Profile = buildProfile('local-b', 'INVALID', '2026-08-07T00:02:00.000Z');
      const earlier: Profile = buildProfile('local-a', 'VALID', '2026-08-07T00:01:00.000Z', 'profiles/local-a/current.yaml');
      const sameTimeHighId: Profile = buildProfile('local-z', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/local-z/current.yaml');

      await repository.save(earlier);
      await repository.save(later);
      await repository.save(sameTimeHighId);

      const listed: Profile[] = await repository.list();
      const loaded: Profile | undefined = await repository.get('local-a');

      expect(listed.length).assertEqual(3);
      expect(listed[0].id).assertEqual('local-b');
      expect(listed[1].id).assertEqual('local-z');
      expect(listed[2].id).assertEqual('local-a');
      expect(loaded?.currentRevision?.relativePath).assertEqual('profiles/local-a/current.yaml');
    });

    it('setActiveIdReReadsAndValidatesInsideOneTransactionAndAllowsClear', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedRow(encodeProfileRow(buildProfile('local-valid', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/local-valid/current.yaml')));
      const repository = new RdbProfileRepository(driver);

      await repository.setActiveId('local-valid');
      expect(await repository.getActiveId()).assertEqual('local-valid');

      await repository.setActiveId(undefined);
      expect(await repository.getActiveId()).assertUndefined();
      expect(driver.log.join('>')).assertContain('begin>tx.getProfileRow:local-valid>tx.setActiveId:local-valid>commit');
      expect(driver.log.join('>')).assertContain('begin>tx.setActiveId:<cleared>>commit');
    });

    it('rejectsMissingOrInvalidActiveTargetAndRollsBackState', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedRow(encodeProfileRow(buildProfile('invalid-target', 'INVALID', '2026-08-07T00:02:00.000Z')));
      driver.seedActiveId('previous-active');
      const repository = new RdbProfileRepository(driver);

      await expectPersistenceFailure(
        async () => {
          await repository.setActiveId('missing-profile');
        },
        'not found',
        ['missing-profile']
      );
      expect(driver.currentActiveId()).assertEqual('previous-active');

      await expectPersistenceFailure(
        async () => {
          await repository.setActiveId('invalid-target');
        },
        'eligible',
        ['profiles/invalid-target', 'invalid-target.yaml']
      );
      expect(driver.currentActiveId()).assertEqual('previous-active');
    });

    it('initializationClearsStaleOrInvalidActiveIdButFailsOnCorruptRows', 0, async () => {
      const staleDriver = new RecordingRdbDriver();
      staleDriver.seedActiveId('missing-active');
      const staleRepository = new RdbProfileRepository(staleDriver);

      expect(await staleRepository.getActiveId()).assertUndefined();
      expect(staleDriver.log.join('>')).assertContain('readActiveId>begin>tx.setActiveId:<cleared>>commit');

      const invalidDriver = new RecordingRdbDriver();
      invalidDriver.seedActiveId('invalid-active');
      invalidDriver.seedRow(encodeProfileRow(buildProfile('invalid-active', 'INVALID', '2026-08-07T00:02:00.000Z')));
      const invalidRepository = new RdbProfileRepository(invalidDriver);

      expect(await invalidRepository.getActiveId()).assertUndefined();

      const corruptDriver = new RecordingRdbDriver();
      const corruptRow = cloneDurableRow(encodeProfileRow(buildProfile('remote-corrupt', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/remote-corrupt/current.yaml')));
      corruptRow.currentRevisionJson = buildUnsafeRevisionJson();
      corruptDriver.seedActiveId('remote-corrupt');
      corruptDriver.seedRow(corruptRow);
      const corruptRepository = new RdbProfileRepository(corruptDriver);

      await expectSafeFallbackFailure(
        async () => {
          await corruptRepository.getActiveId();
        },
        'Profile persistence initialization failed.',
        [buildUnsafeSecretPath(), 'secret.yaml', 'sandbox-relative']
      );
    });

    it('deleteAndClearActiveRunsExactTransactionalOrder', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedActiveId('delete-me');
      driver.seedRow(encodeProfileRow(buildProfile('delete-me', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/delete-me/current.yaml')));
      driver.seedProfileRefreshLeaseRow({
        profileId: 'delete-me',
        ownerToken: 'owner-a',
        expiresAtMs: 500
      });
      driver.seedSelectionRow(encodeProxySelectionRow(
        createProxySelectionRecord('delete-me', 'Group Alpha', 'Node Alpha', '2026-08-07T00:00:00.000Z', '2026-08-07T00:03:00.000Z')
      ));
      const repository = new RdbProfileRepository(driver);

      await repository.deleteAndClearActive('delete-me');

      expect(driver.log.join('>')).assertContain(
        'begin>clearActiveIfMatching:delete-me>deleteProfileSelections:delete-me>deleteProfileRefreshLeases:delete-me>deleteProfile:delete-me>commit'
      );
      expect(await repository.get('delete-me')).assertUndefined();
      expect(await repository.getActiveId()).assertUndefined();
      expect((await driver.listProxySelectionRows('delete-me')).length).assertEqual(0);
      expect(driver.readProfileRefreshLeaseRow('delete-me')).assertUndefined();
    });

    it('rollsBackOnTransactionStatementOrCommitFailureAndRemainsReusable', 0, async () => {
      const clearDriver = new RecordingRdbDriver();
      clearDriver.seedActiveId('delete-clear');
      clearDriver.seedRow(encodeProfileRow(buildProfile('delete-clear', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/delete-clear/current.yaml')));
      clearDriver.seedProfileRefreshLeaseRow({
        profileId: 'delete-clear',
        ownerToken: 'owner-a',
        expiresAtMs: 500
      });
      clearDriver.seedSelectionRow(encodeProxySelectionRow(
        createProxySelectionRecord('delete-clear', 'Group Alpha', 'Node Alpha', '2026-08-07T00:00:00.000Z', '2026-08-07T00:03:00.000Z')
      ));
      clearDriver.injectFailure('clearActiveIfMatching:delete-clear', new Error(`clear failed ${buildUnsafeUrl('delete-clear')}`));
      const clearRepository = new RdbProfileRepository(clearDriver);

      await expectSafeFallbackFailure(
        async () => {
          await clearRepository.deleteAndClearActive('delete-clear');
        },
        'Profile delete failed.',
        ['https://user:secret@remote.example.com/delete-clear', 'delete-clear']
      );
      expect((await clearRepository.get('delete-clear'))?.id).assertEqual('delete-clear');
      expect(await clearRepository.getActiveId()).assertEqual('delete-clear');
      expect((await clearDriver.listProxySelectionRows('delete-clear')).length).assertEqual(1);
      expect(clearDriver.readProfileRefreshLeaseRow('delete-clear')?.ownerToken).assertEqual('owner-a');

      clearDriver.log.length = 0;
      await clearRepository.setActiveId(undefined);
      expect(await clearRepository.getActiveId()).assertUndefined();

      const commitDriver = new RecordingRdbDriver();
      commitDriver.seedActiveId('tx-commit');
      commitDriver.seedRow(encodeProfileRow(buildProfile('tx-commit', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/tx-commit/current.yaml')));
      commitDriver.seedProfileRefreshLeaseRow({
        profileId: 'tx-commit',
        ownerToken: 'owner-b',
        expiresAtMs: 700
      });
      commitDriver.seedSelectionRow(encodeProxySelectionRow(
        createProxySelectionRecord('tx-commit', 'Group Alpha', 'Node Alpha', '2026-08-07T00:00:00.000Z', '2026-08-07T00:03:00.000Z')
      ));
      commitDriver.injectFailure('commit', new Error(`commit body leaked ${buildUnsafeHomePath('tx-commit.yaml')}`));
      const commitRepository = new RdbProfileRepository(commitDriver);

      await expectSafeFallbackFailure(
        async () => {
          await commitRepository.deleteAndClearActive('tx-commit');
        },
        'Profile delete failed.',
        [buildUnsafeHomePath('tx-commit.yaml'), 'tx-commit.yaml']
      );
      expect((await commitRepository.get('tx-commit'))?.id).assertEqual('tx-commit');
      expect(await commitRepository.getActiveId()).assertEqual('tx-commit');
      expect((await commitDriver.listProxySelectionRows('tx-commit')).length).assertEqual(1);
      expect(commitDriver.readProfileRefreshLeaseRow('tx-commit')?.ownerToken).assertEqual('owner-b');

      const leaseDeleteDriver = new RecordingRdbDriver();
      leaseDeleteDriver.seedActiveId('lease-delete');
      leaseDeleteDriver.seedRow(encodeProfileRow(buildProfile('lease-delete', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/lease-delete/current.yaml')));
      leaseDeleteDriver.seedProfileRefreshLeaseRow({
        profileId: 'lease-delete',
        ownerToken: 'owner-c',
        expiresAtMs: 900
      });
      leaseDeleteDriver.seedSelectionRow(encodeProxySelectionRow(
        createProxySelectionRecord('lease-delete', 'Group Alpha', 'Node Alpha', '2026-08-07T00:00:00.000Z', '2026-08-07T00:03:00.000Z')
      ));
      leaseDeleteDriver.injectFailure('deleteProfileRefreshLeases:lease-delete', new Error(buildUnsafePayload('driver lease delete failed')));
      const leaseDeleteRepository = new RdbProfileRepository(leaseDeleteDriver);

      await expectSafeFallbackFailure(
        async () => {
          await leaseDeleteRepository.deleteAndClearActive('lease-delete');
        },
        'Profile delete failed.',
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', buildUnsafeHomePrefix()]
      );
      expect((await leaseDeleteRepository.get('lease-delete'))?.id).assertEqual('lease-delete');
      expect(await leaseDeleteRepository.getActiveId()).assertEqual('lease-delete');
      expect((await leaseDeleteDriver.listProxySelectionRows('lease-delete')).length).assertEqual(1);
      expect(leaseDeleteDriver.readProfileRefreshLeaseRow('lease-delete')?.ownerToken).assertEqual('owner-c');
    });

    it('wrapsDriverAndCorruptionFailuresAsStablePersistenceErrorsWithoutLeakingSqlOrSecrets', 0, async () => {
      const driver = new RecordingRdbDriver();
      const row = encodeProfileRow(buildProfile('remote-redact', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/remote-redact/current.yaml'));
      row.lastErrorJson = buildUnsafeLastErrorJson();
      driver.seedListRows([row]);
      const repository = new RdbProfileRepository(driver);

      await expectSafeFallbackFailure(
        async () => {
          await repository.list();
        },
        'Profile list failed.',
        ['abc123', 'https://user:secret@remote.example.com/profile.yaml?token=abc123', 'profile.yaml', 'token=abc123', 'yaml']
      );

      const driverFailure = new RecordingRdbDriver();
      driverFailure.injectFailure(
        'listProfileRows',
        new Error(stitch(['SELECT * FROM profiles WHERE id="remote-redact" and yaml ', 'sec', 'ret', ': abc123']))
      );
      const failureRepository = new RdbProfileRepository(driverFailure);

      await expectSafeFallbackFailure(
        async () => {
          await failureRepository.list();
        },
        'Profile list failed.',
        ['abc123', 'id="remote-redact"', 'yaml', 'SELECT']
      );
    });

    it('usesSafeFallbackForDriverListFailuresInsteadOfUntrustedMessages', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.injectFailure('listProfileRows', new Error(buildUnsafePayload('driver list failed')));
      const repository = new RdbProfileRepository(driver);

      await expectSafeFallbackFailure(
        async () => {
          await repository.list();
        },
        'Profile list failed.',
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', buildUnsafeHomePrefix()]
      );
    });

    it('usesSafeFallbackForDriverGetFailuresInsteadOfUntrustedMessages', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.injectFailure('getProfileRow:remote-get', new Error(buildUnsafePayload('driver get failed')));
      const repository = new RdbProfileRepository(driver);

      await expectSafeFallbackFailure(
        async () => {
          await repository.get('remote-get');
        },
        'Profile lookup failed.',
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', buildUnsafeHomePrefix()]
      );
    });

    it('usesSafeFallbackForDriverSaveFailuresInsteadOfUntrustedMessages', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.injectFailure('upsertProfileRow:remote-save', new Error(buildUnsafePayload('driver save failed')));
      const repository = new RdbProfileRepository(driver);

      await expectSafeFallbackFailure(
        async () => {
          await repository.save(buildProfile('remote-save', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/remote-save/current.yaml'));
        },
        'Profile save failed.',
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', buildUnsafeHomePrefix()]
      );
    });

    it('usesSafeFallbackForInitializationFailuresInsteadOfUntrustedMessages', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.injectFailure('initialize', new Error(buildUnsafePayload('driver init failed')));
      const repository = new RdbProfileRepository(driver);

      await expectSafeFallbackFailure(
        async () => {
          await repository.list();
        },
        'Profile persistence initialization failed.',
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', buildUnsafeHomePrefix()]
      );
    });

    it('usesSafeFallbackForTransactionFailuresInsteadOfUntrustedMessages', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedActiveId('remote-delete');
      driver.seedRow(encodeProfileRow(buildProfile('remote-delete', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/remote-delete/current.yaml')));
      driver.injectFailure('clearActiveIfMatching:remote-delete', new Error(buildUnsafePayload('driver delete failed')));
      const repository = new RdbProfileRepository(driver);

      await expectSafeFallbackFailure(
        async () => {
          await repository.deleteAndClearActive('remote-delete');
        },
        'Profile delete failed.',
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', buildUnsafeHomePrefix()]
      );
    });

    it('usesSafeFallbackForDecodeFailuresInsteadOfPropagatingCorruptPayloadDetails', 0, async () => {
      const driver = new RecordingRdbDriver();
      const row = cloneDurableRow(encodeProfileRow(buildProfile('remote-decode', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/remote-decode/current.yaml')));
      row.lastErrorJson = buildUnsafeLastErrorJson();
      driver.seedListRows([row]);
      const repository = new RdbProfileRepository(driver);

      await expectSafeFallbackFailure(
        async () => {
          await repository.list();
        },
        'Profile list failed.',
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', buildUnsafeHomePrefix()]
      );
    });
  });
}
