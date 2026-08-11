import { describe, expect, it } from '@ohos/hypium';
import type { Profile } from '@cmfa/shared';
import { RdbProfileRepository } from '../main/ets/rdb/RdbProfileRepository';
import { encodeProfileRow } from '../main/ets/rdb/ProfileRowCodec';
import {
  assertAppErrorExactDetail,
  RecordingRdbDriver,
  assertAppErrorShape,
  assertNoLeak,
  buildAppError,
  buildProfile,
  cloneDurableRow
} from './fakes/PlatformFakes';

class PersistenceErrorRecord {
  readonly technicalDetail: string;

  constructor(technicalDetail: string) {
    this.technicalDetail = technicalDetail;
  }
}

function buildUnsafePayload(prefix: string): string {
  return `${prefix} https://user:secret@remote.example.com/profile.yaml?token=abc123 ` +
    `row={"id":"remote-redact","source":"https://remote.example.com/path"} ` +
    `yaml=proxy-providers:\\n  secret: abc123 ` +
    `path=/Users/susiwen8/Documents/github/ClashMetaForAndroid/profiles/profile.yaml`;
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
      corruptRow.currentRevisionJson = '{"relativePath":"/Users/susiwen8/Documents/secret.yaml","sha256Digest":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","byteLength":1,"validatedAt":"2026-08-07T00:00:00.000Z"}';
      corruptDriver.seedActiveId('remote-corrupt');
      corruptDriver.seedRow(corruptRow);
      const corruptRepository = new RdbProfileRepository(corruptDriver);

      await expectSafeFallbackFailure(
        async () => {
          await corruptRepository.getActiveId();
        },
        'Profile persistence initialization failed.',
        ['/Users/susiwen8/Documents/secret.yaml', 'secret.yaml', 'sandbox-relative']
      );
    });

    it('deleteAndClearActiveRunsExactTransactionalOrder', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedActiveId('delete-me');
      driver.seedRow(encodeProfileRow(buildProfile('delete-me', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/delete-me/current.yaml')));
      const repository = new RdbProfileRepository(driver);

      await repository.deleteAndClearActive('delete-me');

      expect(driver.log.join('>')).assertContain('begin>clearActiveIfMatching:delete-me>deleteProfile:delete-me>commit');
      expect(await repository.get('delete-me')).assertUndefined();
      expect(await repository.getActiveId()).assertUndefined();
    });

    it('rollsBackOnTransactionStatementOrCommitFailureAndRemainsReusable', 0, async () => {
      const clearDriver = new RecordingRdbDriver();
      clearDriver.seedActiveId('delete-clear');
      clearDriver.seedRow(encodeProfileRow(buildProfile('delete-clear', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/delete-clear/current.yaml')));
      clearDriver.injectFailure('clearActiveIfMatching:delete-clear', new Error('clear failed https://user:secret@remote.example.com/delete-clear'));
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

      clearDriver.log.length = 0;
      await clearRepository.setActiveId(undefined);
      expect(await clearRepository.getActiveId()).assertUndefined();

      const commitDriver = new RecordingRdbDriver();
      commitDriver.seedActiveId('tx-commit');
      commitDriver.seedRow(encodeProfileRow(buildProfile('tx-commit', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/tx-commit/current.yaml')));
      commitDriver.injectFailure('commit', new Error('commit body leaked /Users/susiwen8/Documents/github/ClashMetaForAndroid/profiles/tx-commit.yaml'));
      const commitRepository = new RdbProfileRepository(commitDriver);

      await expectSafeFallbackFailure(
        async () => {
          await commitRepository.deleteAndClearActive('tx-commit');
        },
        'Profile delete failed.',
        ['/Users/susiwen8/Documents/github/ClashMetaForAndroid/profiles/tx-commit.yaml', 'tx-commit.yaml']
      );
      expect((await commitRepository.get('tx-commit'))?.id).assertEqual('tx-commit');
      expect(await commitRepository.getActiveId()).assertEqual('tx-commit');
    });

    it('wrapsDriverAndCorruptionFailuresAsStablePersistenceErrorsWithoutLeakingSqlOrSecrets', 0, async () => {
      const driver = new RecordingRdbDriver();
      const row = encodeProfileRow(buildProfile('remote-redact', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/remote-redact/current.yaml'));
      row.lastErrorJson = '{"stage":"DOWNLOAD","code":"CMFA_REMOTE_TIMEOUT","userMessageResource":"error.remote.timeout","technicalDetail":"yaml: secret: abc123\\nurl: https://user:secret@remote.example.com/profile.yaml?token=abc123","timestamp":"2026-08-07T00:00:00.000Z","retryable":true}';
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
        new Error('SELECT * FROM profiles WHERE id=\"remote-redact\" and yaml secret: abc123')
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
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', '/Users/susiwen8/Documents']
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
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', '/Users/susiwen8/Documents']
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
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', '/Users/susiwen8/Documents']
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
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', '/Users/susiwen8/Documents']
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
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', '/Users/susiwen8/Documents']
      );
    });

    it('usesSafeFallbackForDecodeFailuresInsteadOfPropagatingCorruptPayloadDetails', 0, async () => {
      const driver = new RecordingRdbDriver();
      const row = cloneDurableRow(encodeProfileRow(buildProfile('remote-decode', 'VALID', '2026-08-07T00:02:00.000Z', 'profiles/remote-decode/current.yaml')));
      row.lastErrorJson = '{"stage":"DOWNLOAD","code":"CMFA_REMOTE_TIMEOUT","userMessageResource":"error.remote.timeout","technicalDetail":"yaml: secret: abc123\\nurl: https://user:secret@remote.example.com/profile.yaml?token=abc123","timestamp":"2026-08-07T00:00:00.000Z","retryable":true}';
      driver.seedListRows([row]);
      const repository = new RdbProfileRepository(driver);

      await expectSafeFallbackFailure(
        async () => {
          await repository.list();
        },
        'Profile list failed.',
        ['https://', 'profile.yaml', 'abc123', 'row={', 'proxy-providers', '/Users/susiwen8/Documents']
      );
    });
  });
}
