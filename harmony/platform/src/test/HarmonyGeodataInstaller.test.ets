import { describe, expect, it } from '@ohos/hypium';
import {
  FILE_OPEN_MODE_CREATE,
  FILE_OPEN_MODE_TRUNC,
  FILE_OPEN_MODE_WRITE_ONLY,
  BufferIoOptionsRecord
} from '../main/ets/files/FileDriver';
import {
  HarmonyGeodataInstaller,
  type GeodataDiagnosticSink,
  type GeodataInstallDiagnosticEvent,
  type PackagedRawfileReader
} from '../main/ets/geodata/HarmonyGeodataInstaller';
import { FakeFileDriver, assertNoLeak, buildBytes } from './fakes/PlatformFakes';

const FILES_DIR: string = '/sandbox/app/files';
const TARGET_PATH: string = `${FILES_DIR}/geoip.metadb`;
const TEMP_DIR_PREFIX: string = `${FILES_DIR}/.tmp-geoip.metadb-`;
const CANDIDATE_FILE_NAME: string = 'candidate.metadb';
const BACKUP_FILE_NAME: string = 'backup.metadb';

class RecordingPackagedRawfileReader implements PackagedRawfileReader {
  readonly calls: string[] = [];
  private readonly bytes: Uint8Array;
  private readonly error?: Error;

  constructor(bytes: Uint8Array, error?: Error) {
    this.bytes = bytes;
    this.error = error;
  }

  async readRawfile(name: string): Promise<Uint8Array> {
    this.calls.push(name);
    if (this.error !== undefined) {
      throw this.error;
    }
    return this.bytes.slice();
  }
}

class RecordingGeodataDiagnosticSink implements GeodataDiagnosticSink {
  readonly events: GeodataInstallDiagnosticEvent[] = [];

  report(stage: string, code: number): void {
    this.events.push({ stage, code });
  }
}

async function digestFor(bytes: Uint8Array): Promise<string> {
  const driver: FakeFileDriver = new FakeFileDriver();
  const probePath: string = `${FILES_DIR}/digest.bin`;
  driver.seedFile(probePath, bytes);
  return await driver.hash(probePath, 'sha256');
}

function sameLengthWrongDigestBytes(source: Uint8Array): Uint8Array {
  const mutated: Uint8Array = source.slice();
  mutated[mutated.length - 1] = (mutated[mutated.length - 1] + 1) % 251;
  return mutated;
}

function claimedTempDir(tempId: string): string {
  return `${TEMP_DIR_PREFIX}${tempId}`;
}

function candidatePath(tempId: string): string {
  return `${claimedTempDir(tempId)}/${CANDIDATE_FILE_NAME}`;
}

function backupPath(tempId: string): string {
  return `${claimedTempDir(tempId)}/${BACKUP_FILE_NAME}`;
}

function createTempIdFactory(tempIds: string[]): () => string {
  const queue: string[] = tempIds.slice();
  return (): string => {
    if (queue.length === 0) {
      throw new Error('No temp ids left.');
    }
    const next: string | undefined = queue.shift();
    return next ?? 'missing-temp-id';
  };
}

async function createInstaller(
  fileDriver: FakeFileDriver,
  resourceReader: PackagedRawfileReader,
  bytes: Uint8Array,
  diagnostics?: RecordingGeodataDiagnosticSink,
  tempId: string = 'temp-geodata'
): Promise<HarmonyGeodataInstaller> {
  return new HarmonyGeodataInstaller({
    resourceReader,
    fileDriver,
    filesDir: FILES_DIR,
    expectedByteLength: bytes.length,
    expectedSha256Digest: await digestFor(bytes),
    createTempId: (): string => tempId,
    diagnostics
  });
}

async function createInstallerWithTempIds(
  fileDriver: FakeFileDriver,
  resourceReader: PackagedRawfileReader,
  bytes: Uint8Array,
  tempIds: string[],
  diagnostics?: RecordingGeodataDiagnosticSink
): Promise<HarmonyGeodataInstaller> {
  return new HarmonyGeodataInstaller({
    resourceReader,
    fileDriver,
    filesDir: FILES_DIR,
    expectedByteLength: bytes.length,
    expectedSha256Digest: await digestFor(bytes),
    createTempId: createTempIdFactory(tempIds),
    diagnostics
  });
}

async function expectInstallFailure(installer: HarmonyGeodataInstaller, forbiddenFragments: string[]): Promise<string> {
  try {
    await installer.ensureInstalled();
  } catch (error) {
    const detail: string = `${error}`;
    for (let index: number = 0; index < forbiddenFragments.length; index += 1) {
      expect(detail.includes(forbiddenFragments[index])).assertFalse();
    }
    return detail;
  }
  expect(false).assertTrue();
  return '';
}

export default function harmonyGeodataInstallerTestsuite() {
  describe('HarmonyGeodataInstallerTest', () => {
    it('skipsPackagedReadWhenExistingGeoipAlreadyMatchesDigestAndSize', 0, async () => {
      const bytes: Uint8Array = buildBytes(128);
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const resourceReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(bytes);

      fileDriver.seedFile(TARGET_PATH, bytes);
      const installer: HarmonyGeodataInstaller = await createInstaller(fileDriver, resourceReader, bytes);
      await installer.ensureInstalled();

      expect(resourceReader.calls.length).assertEqual(0);
      expect(fileDriver.readFileBytes(TARGET_PATH).length).assertEqual(bytes.length);
    });

    it('installsMissingGeoipIntoTheAppFilesRootAndVerifiesTheFinalBytes', 0, async () => {
      const bytes: Uint8Array = buildBytes(96);
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const resourceReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(bytes);

      const installer: HarmonyGeodataInstaller = await createInstaller(fileDriver, resourceReader, bytes);
      await installer.ensureInstalled();

      expect(resourceReader.calls.length).assertEqual(1);
      expect(resourceReader.calls[0]).assertEqual('geoip.metadb');
      expect(fileDriver.readFileBytes(TARGET_PATH).length).assertEqual(bytes.length);
      expect(fileDriver.fileExists(claimedTempDir('temp-geodata'))).assertFalse();
    });

    it('replacesMismatchedExistingGeoipOnlyAfterHashingTheVerifiedTempFile', 0, async () => {
      const oldBytes: Uint8Array = buildBytes(24);
      const newBytes: Uint8Array = buildBytes(144);
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const resourceReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(newBytes);

      fileDriver.seedFile(TARGET_PATH, oldBytes);
      const installer: HarmonyGeodataInstaller = await createInstaller(fileDriver, resourceReader, newBytes, undefined, 'replace-id');
      await installer.ensureInstalled();

      expect(fileDriver.hashPaths.includes(candidatePath('replace-id'))).assertTrue();
      expect(fileDriver.hashPaths.includes(backupPath('replace-id'))).assertTrue();
      expect(fileDriver.hashPaths.includes(TARGET_PATH)).assertTrue();
      expect(fileDriver.renamePairs[0]).assertEqual(`${candidatePath('replace-id')}->${TARGET_PATH}`);
      expect(fileDriver.readFileBytes(TARGET_PATH).length).assertEqual(newBytes.length);
      expect(fileDriver.fileExists(claimedTempDir('replace-id'))).assertFalse();
    });

    it('preservesTheExistingGeoipWhenPackagedBytesFailSizeValidation', 0, async () => {
      const currentBytes: Uint8Array = buildBytes(32);
      const packagedBytes: Uint8Array = buildBytes(48);
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const resourceReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(packagedBytes);
      const diagnostics: RecordingGeodataDiagnosticSink = new RecordingGeodataDiagnosticSink();

      fileDriver.seedFile(TARGET_PATH, currentBytes);
      const installer = new HarmonyGeodataInstaller({
        resourceReader,
        fileDriver,
        filesDir: FILES_DIR,
        expectedByteLength: packagedBytes.length + 1,
        expectedSha256Digest: await digestFor(packagedBytes),
        createTempId: (): string => 'bad-packaged',
        diagnostics
      });
      const failureDetail: string = await expectInstallFailure(installer, [TARGET_PATH, claimedTempDir('bad-packaged')]);

      expect(fileDriver.readFileBytes(TARGET_PATH).length).assertEqual(currentBytes.length);
      expect(fileDriver.fileExists(claimedTempDir('bad-packaged'))).assertFalse();
      expect(diagnostics.events.length > 0).assertTrue();
      assertNoLeak(failureDetail, [TARGET_PATH, claimedTempDir('bad-packaged')]);
    });

    it('preservesTheExistingGeoipWhenPackagedBytesMatchSizeButFailDigestValidation', 0, async () => {
      const expectedBytes: Uint8Array = buildBytes(56);
      const currentBytes: Uint8Array = buildBytes(40);
      const packagedBytes: Uint8Array = sameLengthWrongDigestBytes(expectedBytes);
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const resourceReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(packagedBytes);
      const diagnostics: RecordingGeodataDiagnosticSink = new RecordingGeodataDiagnosticSink();
      const expectedDigest: string = await digestFor(expectedBytes);
      const originalDigest: string = await digestFor(currentBytes);

      fileDriver.seedFile(TARGET_PATH, currentBytes);
      const installer = new HarmonyGeodataInstaller({
        resourceReader,
        fileDriver,
        filesDir: FILES_DIR,
        expectedByteLength: expectedBytes.length,
        expectedSha256Digest: expectedDigest,
        createTempId: (): string => 'bad-digest',
        diagnostics
      });
      const failureDetail: string = await expectInstallFailure(installer, [
        TARGET_PATH,
        claimedTempDir('bad-digest'),
        expectedDigest,
        `${expectedBytes.length}`
      ]);

      expect(await fileDriver.hash(TARGET_PATH, 'sha256')).assertEqual(originalDigest);
      expect(fileDriver.renamePairs.length).assertEqual(0);
      expect(fileDriver.fileExists(claimedTempDir('bad-digest'))).assertFalse();
      expect(diagnostics.events.length).assertEqual(1);
      expect(diagnostics.events[0].stage).assertEqual('candidate.hash');
      expect(diagnostics.events[0].code).assertEqual(-1);
      expect(failureDetail).assertEqual('Error: Packaged geodata installation failed.');
      assertNoLeak(JSON.stringify(diagnostics.events), [
        TARGET_PATH,
        claimedTempDir('bad-digest'),
        expectedDigest,
        `${expectedBytes.length}`
      ]);
    });

    it('retriesWithNextTempIdWhenStaleClaimDirectoryAlreadyExistsWithoutTruncatingIt', 0, async () => {
      const bytes: Uint8Array = buildBytes(64);
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const resourceReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(bytes);

      fileDriver.seedDirectory(claimedTempDir('stale-id'));
      fileDriver.seedTextFile(candidatePath('stale-id'), 'stale-candidate');
      const installer: HarmonyGeodataInstaller = await createInstallerWithTempIds(
        fileDriver,
        resourceReader,
        bytes,
        ['stale-id', 'fresh-id']
      );
      await installer.ensureInstalled();

      expect(fileDriver.readFileText(candidatePath('stale-id'))).assertEqual('stale-candidate');
      expect(fileDriver.readFileBytes(TARGET_PATH).length).assertEqual(bytes.length);
      expect(fileDriver.fileExists(claimedTempDir('fresh-id'))).assertFalse();
    });

    it('letsTwoInstallersRecoverFromTheSameClaimDirectoryCollisionIndependently', 0, async () => {
      const firstBytes: Uint8Array = buildBytes(65);
      const secondBytes: Uint8Array = buildBytes(66);
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const firstReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(firstBytes);
      const secondReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(secondBytes);

      fileDriver.seedDirectory(claimedTempDir('shared-collision'));
      fileDriver.seedTextFile(candidatePath('shared-collision'), 'claimed-by-other-installer');
      const firstInstaller: HarmonyGeodataInstaller = await createInstallerWithTempIds(
        fileDriver,
        firstReader,
        firstBytes,
        ['shared-collision', 'first-unique']
      );
      const secondInstaller: HarmonyGeodataInstaller = await createInstallerWithTempIds(
        fileDriver,
        secondReader,
        secondBytes,
        ['shared-collision', 'second-unique']
      );

      await firstInstaller.ensureInstalled();
      expect(fileDriver.readFileBytes(TARGET_PATH).length).assertEqual(firstBytes.length);
      await fileDriver.unlink(TARGET_PATH);
      await secondInstaller.ensureInstalled();

      expect(fileDriver.readFileBytes(TARGET_PATH).length).assertEqual(secondBytes.length);
      expect(fileDriver.readFileText(candidatePath('shared-collision'))).assertEqual('claimed-by-other-installer');
      expect(fileDriver.fileExists(claimedTempDir('first-unique'))).assertFalse();
      expect(fileDriver.fileExists(claimedTempDir('second-unique'))).assertFalse();
    });

    it('restoresThePreviousGeoipBytesWhenPostReplaceCorruptionBreaksFinalVerification', 0, async () => {
      const currentBytes: Uint8Array = buildBytes(48);
      const packagedBytes: Uint8Array = buildBytes(80);
      const corruptedBytes: Uint8Array = sameLengthWrongDigestBytes(packagedBytes);
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const resourceReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(packagedBytes);
      const diagnostics: RecordingGeodataDiagnosticSink = new RecordingGeodataDiagnosticSink();
      const originalDigest: string = await digestFor(currentBytes);

      fileDriver.seedFile(TARGET_PATH, currentBytes);
      fileDriver.scriptRenameReplaceCorruption(`${candidatePath('rollback-ok')}->${TARGET_PATH}`, corruptedBytes);
      const installer: HarmonyGeodataInstaller = await createInstallerWithTempIds(
        fileDriver,
        resourceReader,
        packagedBytes,
        ['rollback-ok'],
        diagnostics
      );
      const failureDetail: string = await expectInstallFailure(installer, [TARGET_PATH, claimedTempDir('rollback-ok')]);

      expect(await fileDriver.hash(TARGET_PATH, 'sha256')).assertEqual(originalDigest);
      expect(fileDriver.renamePairs[0]).assertEqual(`${candidatePath('rollback-ok')}->${TARGET_PATH}`);
      expect(fileDriver.renamePairs[1]).assertEqual(`${backupPath('rollback-ok')}->${TARGET_PATH}`);
      expect(fileDriver.fileExists(claimedTempDir('rollback-ok'))).assertFalse();
      expect(diagnostics.events[0].stage).assertEqual('target.verify');
      expect(failureDetail).assertEqual('Error: Packaged geodata installation failed.');
    });

    it('retainsTheVerifiedBackupDirectoryWhenRollbackRestoreFails', 0, async () => {
      const currentBytes: Uint8Array = buildBytes(49);
      const packagedBytes: Uint8Array = buildBytes(81);
      const corruptedBytes: Uint8Array = sameLengthWrongDigestBytes(packagedBytes);
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const resourceReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(packagedBytes);
      const diagnostics: RecordingGeodataDiagnosticSink = new RecordingGeodataDiagnosticSink();
      const originalDigest: string = await digestFor(currentBytes);

      fileDriver.seedFile(TARGET_PATH, currentBytes);
      fileDriver.scriptRenameReplaceCorruption(`${candidatePath('rollback-fail')}->${TARGET_PATH}`, corruptedBytes);
      fileDriver.injectFailure(
        'renameReplace',
        `${backupPath('rollback-fail')}->${TARGET_PATH}`,
        new Error('restore failed')
      );
      const installer: HarmonyGeodataInstaller = await createInstallerWithTempIds(
        fileDriver,
        resourceReader,
        packagedBytes,
        ['rollback-fail'],
        diagnostics
      );
      const failureDetail: string = await expectInstallFailure(installer, [
        TARGET_PATH,
        claimedTempDir('rollback-fail'),
        originalDigest
      ]);

      expect(await fileDriver.hash(backupPath('rollback-fail'), 'sha256')).assertEqual(originalDigest);
      expect(fileDriver.fileExists(claimedTempDir('rollback-fail'))).assertTrue();
      expect(diagnostics.events.length >= 2).assertTrue();
      assertNoLeak(JSON.stringify(diagnostics.events), [TARGET_PATH, claimedTempDir('rollback-fail'), originalDigest]);
      expect(failureDetail).assertEqual('Error: Packaged geodata installation failed.');
    });

    it('removesTheBadTargetAndCleansTheClaimedTempDirWhenNoExistingGeoipFailsFinalVerification', 0, async () => {
      const packagedBytes: Uint8Array = buildBytes(82);
      const corruptedBytes: Uint8Array = sameLengthWrongDigestBytes(packagedBytes);
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const resourceReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(packagedBytes);
      const diagnostics: RecordingGeodataDiagnosticSink = new RecordingGeodataDiagnosticSink();

      fileDriver.scriptRenameReplaceCorruption(`${candidatePath('no-target-rollback')}->${TARGET_PATH}`, corruptedBytes);
      const installer: HarmonyGeodataInstaller = await createInstallerWithTempIds(
        fileDriver,
        resourceReader,
        packagedBytes,
        ['no-target-rollback'],
        diagnostics
      );
      const failureDetail: string = await expectInstallFailure(installer, [
        TARGET_PATH,
        claimedTempDir('no-target-rollback'),
        `${packagedBytes.length}`
      ]);

      expect(fileDriver.fileExists(TARGET_PATH)).assertFalse();
      expect(fileDriver.fileExists(claimedTempDir('no-target-rollback'))).assertFalse();
      expect(fileDriver.fileExists(candidatePath('no-target-rollback'))).assertFalse();
      expect(fileDriver.fileExists(backupPath('no-target-rollback'))).assertFalse();
      expect(fileDriver.renamePairs.length).assertEqual(1);
      expect(fileDriver.renamePairs[0]).assertEqual(`${candidatePath('no-target-rollback')}->${TARGET_PATH}`);
      expect(diagnostics.events.length).assertEqual(1);
      expect(diagnostics.events[0].stage).assertEqual('target.verify');
      expect(diagnostics.events[0].code).assertEqual(-1);
      expect(failureDetail).assertEqual('Error: Packaged geodata installation failed.');
      assertNoLeak(JSON.stringify(diagnostics.events), [
        TARGET_PATH,
        claimedTempDir('no-target-rollback'),
        `${packagedBytes.length}`
      ]);
    });

    it('cleansTempFilesAndPreservesTheExistingGeoipAcrossInterruptedWritesAndReplaceFailures', 0, async () => {
      const currentBytes: Uint8Array = buildBytes(20);
      const packagedBytes: Uint8Array = buildBytes(80);
      const writeFailDriver: FakeFileDriver = new FakeFileDriver();
      const replaceFailDriver: FakeFileDriver = new FakeFileDriver();
      const resourceReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(packagedBytes);

      writeFailDriver.seedFile(TARGET_PATH, currentBytes);
      writeFailDriver.scriptWriteCounts(candidatePath('write-fail'), [packagedBytes.length - 4, 0]);
      const interruptedInstall: HarmonyGeodataInstaller = await createInstallerWithTempIds(
        writeFailDriver,
        resourceReader,
        packagedBytes,
        ['write-fail']
      );
      await expectInstallFailure(interruptedInstall, [TARGET_PATH, claimedTempDir('write-fail')]);
      expect(writeFailDriver.readFileBytes(TARGET_PATH).length).assertEqual(currentBytes.length);
      expect(writeFailDriver.fileExists(claimedTempDir('write-fail'))).assertFalse();

      replaceFailDriver.seedFile(TARGET_PATH, currentBytes);
      replaceFailDriver.injectFailure(
        'renameReplace',
        `${candidatePath('replace-fail')}->${TARGET_PATH}`,
        new Error('replace failed')
      );
      const replaceFailureInstall: HarmonyGeodataInstaller = await createInstallerWithTempIds(
        replaceFailDriver,
        resourceReader,
        packagedBytes,
        ['replace-fail']
      );
      await expectInstallFailure(replaceFailureInstall, [TARGET_PATH, claimedTempDir('replace-fail')]);
      expect(replaceFailDriver.readFileBytes(TARGET_PATH).length).assertEqual(currentBytes.length);
      expect(replaceFailDriver.fileExists(claimedTempDir('replace-fail'))).assertFalse();

      const retryInstall: HarmonyGeodataInstaller = await createInstallerWithTempIds(
        replaceFailDriver,
        resourceReader,
        packagedBytes,
        ['replace-retry']
      );
      await retryInstall.ensureInstalled();
      expect(replaceFailDriver.readFileBytes(TARGET_PATH).length).assertEqual(packagedBytes.length);
    });

    it('treatsFilesDirPreparationAsIdempotentAndReportsOnlyStageAndCodeDiagnostics', 0, async () => {
      const bytes: Uint8Array = buildBytes(72);
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const resourceReader: RecordingPackagedRawfileReader = new RecordingPackagedRawfileReader(
        bytes,
        new Error(`resource read failed near ${TARGET_PATH}`)
      );
      const diagnostics: RecordingGeodataDiagnosticSink = new RecordingGeodataDiagnosticSink();

      fileDriver.seedDirectory(FILES_DIR);
      const installer: HarmonyGeodataInstaller = await createInstaller(fileDriver, resourceReader, bytes, diagnostics, 'diag-id');
      const failureDetail: string = await expectInstallFailure(installer, [TARGET_PATH, `${bytes.length}`]);

      expect(fileDriver.operationLog[0]).assertEqual(`mkdir:${FILES_DIR}:recursive`);
      expect(diagnostics.events.length).assertEqual(1);
      expect(diagnostics.events[0].stage.length > 0).assertTrue();
      expect(diagnostics.events[0].code).assertEqual(-1);
      assertNoLeak(JSON.stringify(diagnostics.events), [TARGET_PATH, `${bytes.length}`]);
      assertNoLeak(failureDetail, [TARGET_PATH, `${bytes.length}`]);
    });
  });

  describe('FakeFileDriverRenameReplaceTest', () => {
    it('requiresAnExistingDestinationParentDirectory', 0, async () => {
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const sourcePath: string = `${FILES_DIR}/geoip.source`;
      const destinationPath: string = `/missing-root/geoip.metadb`;

      fileDriver.seedFile(sourcePath, buildBytes(8));
      try {
        await fileDriver.renameReplace(sourcePath, destinationPath);
        expect(false).assertTrue();
      } catch (error) {
        expect(`${error}`.includes('parent')).assertTrue();
      }
      expect(fileDriver.fileExists(sourcePath)).assertTrue();
      expect(fileDriver.fileExists(destinationPath)).assertFalse();
    });

    it('replacesOnlyFilesAndLeavesNoOverwriteBehaviorUnchanged', 0, async () => {
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const sourcePath: string = `${FILES_DIR}/geoip.source`;
      const destinationPath: string = `${FILES_DIR}/geoip.metadb`;

      fileDriver.seedFile(sourcePath, buildBytes(10));
      fileDriver.seedFile(destinationPath, buildBytes(6));
      await fileDriver.renameReplace(sourcePath, destinationPath);

      expect(fileDriver.fileExists(sourcePath)).assertFalse();
      expect(fileDriver.readFileBytes(destinationPath).length).assertEqual(10);

      fileDriver.seedFile(sourcePath, buildBytes(4));
      try {
        await fileDriver.renameNoOverwrite(sourcePath, destinationPath);
        expect(false).assertTrue();
      } catch (error) {
        expect(`${error}`.includes('exists')).assertTrue();
      }
      expect(fileDriver.fileExists(sourcePath)).assertTrue();

      fileDriver.seedDirectory(`${FILES_DIR}/blocked`);
      fileDriver.seedFile(`${FILES_DIR}/blocked-source`, buildBytes(5));
      try {
        await fileDriver.renameReplace(`${FILES_DIR}/blocked-source`, `${FILES_DIR}/blocked`);
        expect(false).assertTrue();
      } catch (error) {
        expect(`${error}`.includes('file')).assertTrue();
      }
      expect(fileDriver.fileExists(`${FILES_DIR}/blocked-source`)).assertTrue();
    });

    it('preservesThePreviousDestinationWhenReplaceFails', 0, async () => {
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const sourcePath: string = `${FILES_DIR}/replace-source`;
      const destinationPath: string = `${FILES_DIR}/replace-destination`;

      fileDriver.seedFile(sourcePath, buildBytes(9));
      fileDriver.seedFile(destinationPath, buildBytes(7));
      fileDriver.injectFailure('renameReplace', `${sourcePath}->${destinationPath}`, new Error('forced replace failure'));

      try {
        await fileDriver.renameReplace(sourcePath, destinationPath);
        expect(false).assertTrue();
      } catch (error) {
        expect(`${error}`.includes('forced replace failure')).assertTrue();
      }
      expect(fileDriver.readFileBytes(sourcePath).length).assertEqual(9);
      expect(fileDriver.readFileBytes(destinationPath).length).assertEqual(7);
    });

    it('matchesOpenWriteBehaviorUsedByTheInstallerWriteOnlyCreateMode', 0, async () => {
      const fileDriver: FakeFileDriver = new FakeFileDriver();
      const path: string = `${FILES_DIR}/write-shape.metadb`;
      const bytes: Uint8Array = buildBytes(12);
      const handle = await fileDriver.open(path, FILE_OPEN_MODE_WRITE_ONLY | FILE_OPEN_MODE_CREATE);
      const wrote: number = await fileDriver.write(
        handle.fd,
        bytes.buffer,
        new BufferIoOptionsRecord(0, bytes.length)
      );
      await fileDriver.close(handle);

      expect(wrote).assertEqual(bytes.length);
      expect(fileDriver.readFileBytes(path).length).assertEqual(bytes.length);
    });
  });
}
