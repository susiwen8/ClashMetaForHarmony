import { describe, expect, it } from '@ohos/hypium';
import { createProfileRevision, type ProfileRevision, type StagedSource } from '@cmfa/shared';
import { SandboxProfileContentStore } from '../main/ets/files/SandboxProfileContentStore';
import { FakeFileDriver, assertNoLeak, buildBytes } from './fakes/PlatformFakes';

const FILES_DIR = '/sandbox/app/files';
const EXACT_LIMIT_BYTES = 16 * 1024 * 1024;
const DEFAULT_DIGEST = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const DEFAULT_TIMESTAMP = '2026-08-11T09:00:00.000Z';

class RawRevisionValue implements ProfileRevision {
  readonly relativePath: string;
  readonly sha256Digest: string;
  readonly byteLength: number;
  readonly validatedAt: string;

  constructor(relativePath: string, sha256Digest: string, byteLength: number, validatedAt: string) {
    this.relativePath = relativePath;
    this.sha256Digest = sha256Digest;
    this.byteLength = byteLength;
    this.validatedAt = validatedAt;
  }
}

class FailureShape {
  readonly technicalDetail?: string;
  readonly message?: string;
}

function buildStaged(
  stagingId: string,
  byteLength: number,
  validationPath: string = `${FILES_DIR}/tmp/${stagingId}.yaml`,
  sha256Digest: string = DEFAULT_DIGEST,
  validatedAt: string = DEFAULT_TIMESTAMP
): StagedSource {
  return {
    stagingId,
    validationPath,
    sha256Digest,
    byteLength,
    validatedAt
  };
}

function buildRevision(relativePath: string): ProfileRevision {
  return createProfileRevision(relativePath, DEFAULT_DIGEST, 128, DEFAULT_TIMESTAMP);
}

function buildUnsafeRevision(relativePath: string): ProfileRevision {
  return new RawRevisionValue(relativePath, DEFAULT_DIGEST, 128, DEFAULT_TIMESTAMP);
}

function extractFailureDetail(error: Object | undefined): string {
  if (error === undefined) {
    return 'undefined';
  }
  const record = error as FailureShape;
  if (typeof record.technicalDetail === 'string' && record.technicalDetail.length > 0) {
    return record.technicalDetail;
  }
  if (typeof record.message === 'string' && record.message.length > 0) {
    return record.message;
  }
  return `${error}`;
}

async function expectSafeFailure(
  operation: () => Promise<void>,
  expectedFragment: string,
  forbiddenFragments: string[]
): Promise<void> {
  try {
    await operation();
    expect(false).assertTrue();
  } catch (error) {
    const detail: string = extractFailureDetail(error as Object);
    expect(detail.includes(expectedFragment)).assertTrue();
    assertNoLeak(detail, forbiddenFragments);
  }
}

class MkdirRaceFakeFileDriver extends FakeFileDriver {
  private readonly racedPath: string;

  constructor(racedPath: string) {
    super();
    this.racedPath = racedPath;
  }

  override async mkdir(path: string, recursive: boolean): Promise<void> {
    if (path === this.racedPath) {
      this.operationLog.push(`mkdir:${path}:${recursive ? 'recursive' : 'single'}`);
      this.seedDirectory(path);
      throw new Error('Concurrent directory creation.');
    }
    await super.mkdir(path, recursive);
  }
}

export default function sandboxProfileContentStoreTestsuite() {
  describe('SandboxProfileContentStoreTest', () => {
    it('fakeRenameRequiresExistingDestinationParent', 0, async () => {
      const driver = new FakeFileDriver();
      driver.seedDirectory(FILES_DIR);
      driver.seedDirectory(`${FILES_DIR}/tmp`);
      driver.seedFile(`${FILES_DIR}/tmp/source.yaml`, buildBytes(12));

      await expectSafeFailure(
        async () => {
          await driver.renameNoOverwrite(
            `${FILES_DIR}/tmp/source.yaml`,
            `${FILES_DIR}/profiles/alpha/failed/source.yaml`
          );
        },
        'Destination parent',
        ['source.yaml', `${FILES_DIR}/profiles/alpha/failed`]
      );

      expect(driver.fileExists(`${FILES_DIR}/tmp/source.yaml`)).assertTrue();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/failed/source.yaml`)).assertFalse();
    });

    it('retainsCurrentAndFailedCandidateAtImmutableManagedPathsAndResolvesCorePath', 0, async () => {
      const driver = new FakeFileDriver();
      driver.seedDirectory(FILES_DIR);
      driver.seedDirectory(`${FILES_DIR}/tmp`);
      driver.seedFile(`${FILES_DIR}/tmp/stage-current.yaml`, buildBytes(128));
      driver.seedFile(`${FILES_DIR}/tmp/stage-failed.yaml`, buildBytes(256));
      const store = new SandboxProfileContentStore(driver, FILES_DIR);

      const current = await store.retain('alpha', buildStaged('stage-current', 128), 'CURRENT');
      const failed = await store.retain('alpha', buildStaged('stage-failed', 256), 'FAILED_CANDIDATE');

      expect(current.relativePath).assertEqual('profiles/alpha/valid/stage-current.yaml');
      expect(failed.relativePath).assertEqual('profiles/alpha/failed/stage-failed.yaml');
      expect(current.sha256Digest).assertEqual(DEFAULT_DIGEST);
      expect(failed.byteLength).assertEqual(256);
      expect(driver.fileExists(`${FILES_DIR}/tmp/stage-current.yaml`)).assertFalse();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/valid/stage-current.yaml`)).assertTrue();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/failed/stage-failed.yaml`)).assertTrue();
      expect(store.resolveCorePath(current)).assertEqual(`${FILES_DIR}/profiles/alpha/valid/stage-current.yaml`);
      expect(store.resolveCorePath(failed)).assertEqual(`${FILES_DIR}/profiles/alpha/failed/stage-failed.yaml`);
    });

    it('createsMissingRetentionDirectoryBeforeRename', 0, async () => {
      const driver = new FakeFileDriver();
      driver.seedDirectory(FILES_DIR);
      driver.seedDirectory(`${FILES_DIR}/tmp`);
      driver.seedFile(`${FILES_DIR}/tmp/stage-create-parent.yaml`, buildBytes(192));
      const store = new SandboxProfileContentStore(driver, FILES_DIR);

      const retained = await store.retain('alpha', buildStaged('stage-create-parent', 192), 'FAILED_CANDIDATE');

      expect(retained.relativePath).assertEqual('profiles/alpha/failed/stage-create-parent.yaml');
      expect(driver.operationLog.includes(`mkdir:${FILES_DIR}/profiles/alpha/failed:recursive`)).assertTrue();
      expect(driver.fileExists(`${FILES_DIR}/tmp/stage-create-parent.yaml`)).assertFalse();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/failed/stage-create-parent.yaml`)).assertTrue();
    });

    it('reusesExistingRetentionDirectoryWithoutRecreatingIt', 0, async () => {
      const driver = new FakeFileDriver();
      driver.seedDirectory(FILES_DIR);
      driver.seedDirectory(`${FILES_DIR}/tmp`);
      driver.seedDirectory(`${FILES_DIR}/profiles/alpha/failed`);
      driver.seedFile(`${FILES_DIR}/tmp/stage-reuse.yaml`, buildBytes(256));
      driver.injectFailure(
        'mkdir',
        `${FILES_DIR}/profiles/alpha/failed`,
        new Error('Existing directory must not be recreated.')
      );
      const store = new SandboxProfileContentStore(driver, FILES_DIR);

      const retained = await store.retain('alpha', buildStaged('stage-reuse', 256), 'FAILED_CANDIDATE');

      expect(retained.relativePath).assertEqual('profiles/alpha/failed/stage-reuse.yaml');
      expect(driver.fileExists(`${FILES_DIR}/tmp/stage-reuse.yaml`)).assertFalse();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/failed/stage-reuse.yaml`)).assertTrue();
      expect(driver.operationLog.includes(`mkdir:${FILES_DIR}/profiles/alpha/failed:recursive`)).assertFalse();
      expect(driver.renamePairs).assertDeepEquals([
        `${FILES_DIR}/tmp/stage-reuse.yaml->${FILES_DIR}/profiles/alpha/failed/stage-reuse.yaml`
      ]);
    });

    it('retainsWhenRetentionDirectoryAppearsDuringMkdirRace', 0, async () => {
      const driver = new MkdirRaceFakeFileDriver(`${FILES_DIR}/profiles/alpha/failed`);
      driver.seedDirectory(FILES_DIR);
      driver.seedDirectory(`${FILES_DIR}/tmp`);
      driver.seedFile(`${FILES_DIR}/tmp/stage-race.yaml`, buildBytes(224));
      const store = new SandboxProfileContentStore(driver, FILES_DIR);

      const retained = await store.retain('alpha', buildStaged('stage-race', 224), 'FAILED_CANDIDATE');

      expect(retained.relativePath).assertEqual('profiles/alpha/failed/stage-race.yaml');
      expect(driver.fileExists(`${FILES_DIR}/tmp/stage-race.yaml`)).assertFalse();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/failed/stage-race.yaml`)).assertTrue();
      expect(driver.renamePairs).assertDeepEquals([
        `${FILES_DIR}/tmp/stage-race.yaml->${FILES_DIR}/profiles/alpha/failed/stage-race.yaml`
      ]);
    });

    it('failsClosedWhenRetentionDirectoryPathIsAnExistingFile', 0, async () => {
      const driver = new FakeFileDriver();
      driver.seedDirectory(FILES_DIR);
      driver.seedDirectory(`${FILES_DIR}/tmp`);
      driver.seedFile(`${FILES_DIR}/tmp/stage-parent-file.yaml`, buildBytes(208));
      driver.seedFile(`${FILES_DIR}/profiles/alpha/failed`, buildBytes(4));
      const store = new SandboxProfileContentStore(driver, FILES_DIR);

      await expectSafeFailure(
        async () => {
          await store.retain('alpha', buildStaged('stage-parent-file', 208), 'FAILED_CANDIDATE');
        },
        'Sandbox directory preparation failed.',
        [`${FILES_DIR}/profiles/alpha/failed`, 'stage-parent-file', 'alpha']
      );

      expect(driver.fileExists(`${FILES_DIR}/tmp/stage-parent-file.yaml`)).assertTrue();
      expect(driver.renamePairs.some((value: string): boolean => value.includes('stage-parent-file'))).assertFalse();
    });

    it('acceptsExactlySixteenMiBAndRejectsOversizeStagesBeforeRename', 0, async () => {
      const driver = new FakeFileDriver();
      driver.seedDirectory(FILES_DIR);
      driver.seedDirectory(`${FILES_DIR}/tmp`);
      driver.seedFile(`${FILES_DIR}/tmp/exact.yaml`, buildBytes(EXACT_LIMIT_BYTES));
      driver.seedFile(`${FILES_DIR}/tmp/oversize.yaml`, buildBytes(EXACT_LIMIT_BYTES + 1));
      const store = new SandboxProfileContentStore(driver, FILES_DIR);

      const accepted = await store.retain('limit-ok', buildStaged('exact', EXACT_LIMIT_BYTES), 'CURRENT');
      expect(accepted.byteLength).assertEqual(EXACT_LIMIT_BYTES);

      await expectSafeFailure(
        async () => {
          await store.retain('limit-bad', buildStaged('oversize', EXACT_LIMIT_BYTES + 1), 'CURRENT');
        },
        '16 MiB',
        [`${FILES_DIR}/tmp/oversize.yaml`, 'limit-bad']
      );
      expect(driver.fileExists(`${FILES_DIR}/tmp/oversize.yaml`)).assertTrue();
      expect(driver.renamePairs.some((value: string): boolean => value.includes('oversize'))).assertFalse();
    });

    it('neverOverwritesExistingRevisionAndLeavesStageInPlaceWhenRenameFails', 0, async () => {
      const driver = new FakeFileDriver();
      driver.seedDirectory(FILES_DIR);
      driver.seedDirectory(`${FILES_DIR}/tmp`);
      driver.seedFile(`${FILES_DIR}/tmp/stage-conflict.yaml`, buildBytes(128));
      driver.seedFile(`${FILES_DIR}/profiles/alpha/valid/stage-conflict.yaml`, buildBytes(32));
      const store = new SandboxProfileContentStore(driver, FILES_DIR);

      await expectSafeFailure(
        async () => {
          await store.retain('alpha', buildStaged('stage-conflict', 128), 'CURRENT');
        },
        'already exists',
        [`${FILES_DIR}/profiles/alpha/valid/stage-conflict.yaml`]
      );

      expect(driver.fileExists(`${FILES_DIR}/tmp/stage-conflict.yaml`)).assertTrue();
      expect(driver.readFileBytes(`${FILES_DIR}/profiles/alpha/valid/stage-conflict.yaml`).length).assertEqual(32);
    });

    it('discardIsIdempotentAndRemoveProfileDeletesOnlyTheOwnedProfileRoot', 0, async () => {
      const driver = new FakeFileDriver();
      driver.seedDirectory(FILES_DIR);
      driver.seedDirectory(`${FILES_DIR}/tmp`);
      driver.seedFile(`${FILES_DIR}/tmp/discard-me.yaml`, buildBytes(64));
      driver.seedFile(`${FILES_DIR}/profiles/alpha/valid/current.yaml`, buildBytes(32));
      driver.seedFile(`${FILES_DIR}/profiles/alpha/failed/last.yaml`, buildBytes(16));
      driver.seedFile(`${FILES_DIR}/profiles/beta/valid/current.yaml`, buildBytes(48));
      const store = new SandboxProfileContentStore(driver, FILES_DIR);

      await store.discard(buildStaged('discard-me', 64));
      await store.discard(buildStaged('discard-me', 64));
      await store.removeProfile('alpha');

      expect(driver.fileExists(`${FILES_DIR}/tmp/discard-me.yaml`)).assertFalse();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/valid/current.yaml`)).assertFalse();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/failed/last.yaml`)).assertFalse();
      expect(driver.fileExists(`${FILES_DIR}/profiles/beta/valid/current.yaml`)).assertTrue();
    });

    it('rejectsUnsafeProfileIdsAndRelativeRevisionPaths', 0, async () => {
      const driver = new FakeFileDriver();
      driver.seedDirectory(FILES_DIR);
      driver.seedDirectory(`${FILES_DIR}/tmp`);
      driver.seedFile(`${FILES_DIR}/tmp/stage-safe.yaml`, buildBytes(128));
      const store = new SandboxProfileContentStore(driver, FILES_DIR);

      await expectSafeFailure(
        async () => {
          await store.retain('../escape', buildStaged('stage-safe', 128), 'CURRENT');
        },
        'relative path',
        ['../escape', FILES_DIR]
      );

      await expectSafeFailure(
        async () => {
          store.resolveCorePath(buildUnsafeRevision('../escape/current.yaml'));
          return Promise.resolve();
        },
        'relative path',
        ['../escape']
      );
    });

    it('reconcileRemovesOnlyManagedStaleFilesAndKeepsReferencedCurrentAndFailedRevisions', 0, async () => {
      const driver = new FakeFileDriver();
      driver.seedDirectory(FILES_DIR);
      driver.seedFile(`${FILES_DIR}/tmp/stale.yaml`, buildBytes(12));
      driver.seedFile(`${FILES_DIR}/tmp/keep.txt`, buildBytes(7));
      driver.seedFile(`${FILES_DIR}/profiles/alpha/valid/current.yaml`, buildBytes(20));
      driver.seedFile(`${FILES_DIR}/profiles/alpha/failed/invalid.yaml`, buildBytes(21));
      driver.seedFile(`${FILES_DIR}/profiles/alpha/valid/orphan.yaml`, buildBytes(22));
      driver.seedFile(`${FILES_DIR}/profiles/beta/valid/old.yaml`, buildBytes(23));
      driver.seedFile(`${FILES_DIR}/profiles/beta/notes.txt`, buildBytes(9));
      const store = new SandboxProfileContentStore(driver, FILES_DIR);

      await store.reconcile([
        buildRevision('profiles/alpha/valid/current.yaml'),
        buildRevision('profiles/alpha/failed/invalid.yaml')
      ]);

      expect(driver.fileExists(`${FILES_DIR}/tmp/stale.yaml`)).assertFalse();
      expect(driver.fileExists(`${FILES_DIR}/tmp/keep.txt`)).assertTrue();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/valid/current.yaml`)).assertTrue();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/failed/invalid.yaml`)).assertTrue();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/valid/orphan.yaml`)).assertFalse();
      expect(driver.fileExists(`${FILES_DIR}/profiles/beta/valid/old.yaml`)).assertFalse();
      expect(driver.fileExists(`${FILES_DIR}/profiles/beta/notes.txt`)).assertTrue();
    });

    it('failsClosedOnInvalidReconcileReferencesAndRetriesAfterPartialCleanupFailure', 0, async () => {
      const driver = new FakeFileDriver();
      driver.seedDirectory(FILES_DIR);
      driver.seedFile(`${FILES_DIR}/tmp/stale.yaml`, buildBytes(12));
      driver.seedFile(`${FILES_DIR}/profiles/alpha/valid/current.yaml`, buildBytes(20));
      driver.seedFile(`${FILES_DIR}/profiles/alpha/valid/orphan.yaml`, buildBytes(22));
      const store = new SandboxProfileContentStore(driver, FILES_DIR);

      await expectSafeFailure(
        async () => {
          await store.reconcile([buildRevision('profiles/%2e%2e/evil.yaml')]);
        },
        'relative path',
        ['%2e%2e', FILES_DIR]
      );
      expect(driver.fileExists(`${FILES_DIR}/tmp/stale.yaml`)).assertTrue();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/valid/orphan.yaml`)).assertTrue();

      driver.injectFailure('unlink', `${FILES_DIR}/profiles/alpha/valid/orphan.yaml`, new Error('unlink failed for /private/data/orphan'));
      await expectSafeFailure(
        async () => {
          await store.reconcile([buildRevision('profiles/alpha/valid/current.yaml')]);
        },
        'cleanup',
        ['/private/data/orphan', 'profiles/alpha/valid/orphan.yaml']
      );
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/valid/orphan.yaml`)).assertTrue();

      await store.reconcile([buildRevision('profiles/alpha/valid/current.yaml')]);
      expect(driver.fileExists(`${FILES_DIR}/tmp/stale.yaml`)).assertFalse();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/valid/orphan.yaml`)).assertFalse();
    });

    it('rejectsStatFaultsDuringReconcileInsteadOfTreatingThemAsMissingAndSucceedsOnRetry', 0, async () => {
      const driver = new FakeFileDriver();
      driver.seedDirectory(FILES_DIR);
      driver.seedDirectory(`${FILES_DIR}/tmp`);
      driver.seedFile(`${FILES_DIR}/tmp/stale.yaml`, buildBytes(12));
      driver.seedFile(`${FILES_DIR}/profiles/alpha/valid/current.yaml`, buildBytes(20));
      driver.seedFile(`${FILES_DIR}/profiles/alpha/valid/orphan.yaml`, buildBytes(22));
      const store = new SandboxProfileContentStore(driver, FILES_DIR);

      driver.injectFailure('stat', `${FILES_DIR}/tmp`, new Error(`stat denied for ${FILES_DIR}/tmp`));
      await expectSafeFailure(
        async () => {
          await store.reconcile([buildRevision('profiles/alpha/valid/current.yaml')]);
        },
        'cleanup',
        [`${FILES_DIR}/tmp`, 'profiles/alpha/valid/orphan.yaml']
      );

      expect(driver.fileExists(`${FILES_DIR}/tmp/stale.yaml`)).assertTrue();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/valid/orphan.yaml`)).assertTrue();

      await store.reconcile([buildRevision('profiles/alpha/valid/current.yaml')]);
      expect(driver.fileExists(`${FILES_DIR}/tmp/stale.yaml`)).assertFalse();
      expect(driver.fileExists(`${FILES_DIR}/profiles/alpha/valid/orphan.yaml`)).assertFalse();
    });
  });
}
