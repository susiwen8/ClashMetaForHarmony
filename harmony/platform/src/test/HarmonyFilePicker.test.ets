import { describe, expect, it } from '@ohos/hypium';
import type { LocalAcquireCommand, LocalProfileAcquisition, LocalProfileAcquisitionFailure, StagedSource } from '@cmfa/shared';
import { HarmonyFilePicker, type HarmonyFilePickerDependencies } from '../main/ets/source/HarmonyFilePicker';
import {
  FakeDocumentPickerPort,
  FakeFileDriver,
  SequenceClock,
  SequenceIdGenerator,
  assertNoLeak,
  buildBytes
} from './fakes/PlatformFakes';

const FILES_DIR = '/sandbox/app/files';
const EXACT_LIMIT_BYTES = 16 * 1024 * 1024;

interface AcquiredLocalResultView {
  kind: 'ACQUIRED';
  profileName: string;
  sourceDisplay: string;
  staged: StagedSource;
}

class EmptyLocalAcquireCommand implements LocalAcquireCommand {
}

class PickerDependencyShape implements HarmonyFilePickerDependencies {
  readonly picker: FakeDocumentPickerPort;
  readonly fileDriver: FakeFileDriver;
  readonly filesDir: string;
  readonly clock: SequenceClock;
  readonly idGenerator: SequenceIdGenerator;

  constructor(
    picker: FakeDocumentPickerPort,
    fileDriver: FakeFileDriver,
    filesDir: string,
    clock: SequenceClock,
    idGenerator: SequenceIdGenerator
  ) {
    this.picker = picker;
    this.fileDriver = fileDriver;
    this.filesDir = filesDir;
    this.clock = clock;
    this.idGenerator = idGenerator;
  }
}

function buildPicker(
  pickerPort: FakeDocumentPickerPort,
  fileDriver: FakeFileDriver,
  timestamps: string[] = ['2026-08-11T10:00:00.000Z'],
  stagingIds: string[] = ['stage-one']
): HarmonyFilePicker {
  const dependencies = new PickerDependencyShape(
    pickerPort,
    fileDriver,
    FILES_DIR,
    new SequenceClock(timestamps),
    new SequenceIdGenerator(stagingIds)
  );
  return new HarmonyFilePicker(dependencies);
}

function requireFailure(result: LocalProfileAcquisition): LocalProfileAcquisitionFailure {
  expect(result.kind).assertEqual('FAILED');
  return result as LocalProfileAcquisitionFailure;
}

function assertFailureIsSafe(
  result: LocalProfileAcquisition,
  expectedFragment: string,
  forbiddenFragments: string[]
): LocalProfileAcquisitionFailure {
  const failure = requireFailure(result);
  expect(failure.shouldPersistInvalidProfile).assertTrue();
  expect(failure.error.stage).assertEqual('IMPORT');
  expect(failure.error.technicalDetail.includes(expectedFragment)).assertTrue();
  assertNoLeak(failure.error.technicalDetail, forbiddenFragments);
  return failure;
}

function assertFailureIsRetryable(failure: LocalProfileAcquisitionFailure): void {
  expect(failure.error.retryable).assertTrue();
}

function assertFailureDoesNotPersistInvalidProfile(failure: LocalProfileAcquisitionFailure): void {
  expect(failure.shouldPersistInvalidProfile).assertFalse();
}

function assertBytesEqual(actual: Uint8Array, expected: Uint8Array): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}

export default function harmonyFilePickerTestsuite() {
  describe('HarmonyFilePickerTest', () => {
    it('returnsCancelledWhenPickerReturnsNoSelection', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      pickerPort.scriptedSelections.push([]);
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      const picker = buildPicker(pickerPort, fileDriver);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());

      expect(result.kind).assertEqual('CANCELLED');
      expect(pickerPort.requests.length).assertEqual(1);
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/stage-one.yaml`)).assertFalse();
    });

    it('returnsRetryableNonPersistedFailureWhenPickerThrowsBeforeSelection', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      pickerPort.failNext(new Error('picker failed near content://documents/tree/private'));
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      const picker = buildPicker(pickerPort, fileDriver, ['2026-08-11T09:30:00.000Z']);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());
      const failure = requireFailure(result);

      assertFailureDoesNotPersistInvalidProfile(failure);
      assertFailureIsRetryable(failure);
      expect(failure.error.stage).assertEqual('IMPORT');
      expect(failure.error.technicalDetail.includes('Selected file')).assertTrue();
      assertNoLeak(failure.error.technicalDetail, ['picker failed near', 'content://documents/tree/private']);
      expect(failure.profileName).assertUndefined();
      expect(failure.sourceDisplay).assertUndefined();
      expect(fileDriver.operationLog.length).assertEqual(0);
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/stage-one.yaml`)).assertFalse();
    });

    it('copiesOneYamlSelectionIntoUniqueSandboxStageAndReturnsSafeMetadata', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      const sourceUri = 'content://documents/tree/primary%3Aprofiles/document/42';
      pickerPort.scriptedSelections.push([sourceUri]);
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      fileDriver.seedFile(sourceUri, buildBytes(4096), 'ClashBox.YAML');
      const picker = buildPicker(pickerPort, fileDriver, ['2026-08-11T10:00:00.000Z'], ['stage-one']);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());
      const acquired = result as AcquiredLocalResultView;

      expect(result.kind).assertEqual('ACQUIRED');
      expect(acquired.profileName).assertEqual('ClashBox.YAML');
      expect(acquired.sourceDisplay).assertEqual('ClashBox.YAML');
      const staged = acquired.staged;
      expect(staged.stagingId).assertEqual('stage-one');
      expect(staged.validationPath).assertEqual(`${FILES_DIR}/tmp/stage-one.yaml`);
      expect(staged.byteLength).assertEqual(4096);
      expect(staged.validatedAt).assertEqual('2026-08-11T10:00:00.000Z');
      expect(/^[0-9a-f]{64}$/u.test(staged.sha256Digest)).assertTrue();
      expect(fileDriver.hashPaths.length).assertEqual(1);
      expect(fileDriver.hashPaths[0]).assertEqual(`${FILES_DIR}/tmp/stage-one.yaml`);
      expect(fileDriver.countCloses(sourceUri)).assertEqual(1);
      expect(fileDriver.countCloses(`${FILES_DIR}/tmp/stage-one.yaml`)).assertEqual(1);
      expect(pickerPort.requests[0].maxSelectNumber).assertEqual(1);
      expect(pickerPort.requests[0].fileSuffixFilters.join(',')).assertEqual('Clash YAML|.yaml,.yml');
    });

    it('normalizesMixedSeparatorNamesToTheirBasename', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      const sourceUri = 'content://documents/tree/primary%3Aprofiles/document/basename';
      pickerPort.scriptedSelections.push([sourceUri]);
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      fileDriver.seedFile(sourceUri, buildBytes(256), 'folder\\nested/profile.yaml');
      const picker = buildPicker(pickerPort, fileDriver, ['2026-08-11T10:05:00.000Z'], ['stage-basename']);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());
      const acquired = result as AcquiredLocalResultView;

      expect(result.kind).assertEqual('ACQUIRED');
      expect(acquired.profileName).assertEqual('profile.yaml');
      expect(acquired.sourceDisplay).assertEqual('profile.yaml');
    });

    it('rejectsMultipleSelectionsAndUnsafeSuffixesWithoutLeakingPickerUris', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      pickerPort.scriptedSelections.push([
        'content://documents/tree/primary%3Aprofiles/document/one',
        'content://documents/tree/primary%3Aprofiles/document/two'
      ]);
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      const picker = buildPicker(pickerPort, fileDriver);

      const multipleResult = await picker.acquire(new EmptyLocalAcquireCommand());
      const multipleFailure = assertFailureIsSafe(
        multipleResult,
        'exactly one',
        ['content://documents/tree/primary%3Aprofiles/document/one', 'content://documents/tree/primary%3Aprofiles/document/two']
      );
      expect(multipleFailure.profileName).assertEqual('本地配置');
      expect(multipleFailure.sourceDisplay).assertEqual('本地配置');

      const txtUri = 'content://documents/tree/primary%3Aprofiles/document/txt';
      pickerPort.scriptedSelections.push([txtUri]);
      fileDriver.seedFile(txtUri, buildBytes(64), 'not-profile.txt');

      const txtResult = await picker.acquire(new EmptyLocalAcquireCommand());
      const txtFailure = assertFailureIsSafe(txtResult, '.yaml', [txtUri, '/sandbox/app/files']);
      expect(txtFailure.profileName).assertEqual('not-profile.txt');
      expect(txtFailure.sourceDisplay).assertEqual('not-profile.txt');
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/stage-one.yaml`)).assertFalse();
    });

    it('fallsBackTo本地配置WhenTheSelectedFileNameIsMissing', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      const sourceUri = 'content://documents/tree/primary%3Aprofiles/document/no-name';
      pickerPort.scriptedSelections.push([sourceUri]);
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      fileDriver.seedFile(sourceUri, buildBytes(32), '');
      const picker = buildPicker(pickerPort, fileDriver, ['2026-08-11T11:00:00.000Z'], ['stage-fallback']);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());
      const acquired = result as AcquiredLocalResultView;

      expect(result.kind).assertEqual('ACQUIRED');
      expect(acquired.profileName).assertEqual('本地配置');
      expect(acquired.sourceDisplay).assertEqual('本地配置');
    });

    it('enforcesTheSixteenMiBLimitDuringStreamingCleanupAndSkipsHash', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      const sourceUri = 'content://documents/tree/primary%3Aprofiles/document/oversize';
      pickerPort.scriptedSelections.push([sourceUri]);
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      fileDriver.seedFile(sourceUri, buildBytes(EXACT_LIMIT_BYTES + 1), 'huge.yaml');
      const picker = buildPicker(pickerPort, fileDriver, ['2026-08-11T12:00:00.000Z'], ['stage-huge']);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());

      const failure = assertFailureIsSafe(result, '16 MiB', [sourceUri, FILES_DIR]);
      expect(failure.profileName).assertEqual('huge.yaml');
      expect(fileDriver.hashPaths.length).assertEqual(0);
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/stage-huge.yaml`)).assertFalse();
      expect(fileDriver.countCloses(sourceUri)).assertEqual(1);
      expect(fileDriver.countCloses(`${FILES_DIR}/tmp/stage-huge.yaml`)).assertEqual(1);
    });

    it('preservesThePrimaryCopyFailureWhenCleanupAlsoFails', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      const sourceUri = 'content://documents/tree/primary%3Aprofiles/document/broken';
      pickerPort.scriptedSelections.push([sourceUri]);
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      fileDriver.seedFile(sourceUri, buildBytes(256), 'folder\\copied/broken.yaml');
      fileDriver.injectFailure('read', sourceUri, new Error('read failed at content://documents/tree/primary'));
      fileDriver.injectFailure('unlink', `${FILES_DIR}/tmp/stage-broken.yaml`, new Error('cleanup failed at /private/tmp/stage-broken.yaml'));
      const picker = buildPicker(pickerPort, fileDriver, ['2026-08-11T13:00:00.000Z'], ['stage-broken']);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());

      const failure = assertFailureIsSafe(
        result,
        'copy',
        [sourceUri, '/private/tmp/stage-broken.yaml', `${FILES_DIR}/tmp/stage-broken.yaml`]
      );
      assertFailureIsRetryable(failure);
      expect(failure.profileName).assertEqual('broken.yaml');
      expect(failure.sourceDisplay).assertEqual('broken.yaml');
      expect(fileDriver.countCloses(sourceUri)).assertEqual(1);
      expect(fileDriver.countCloses(`${FILES_DIR}/tmp/stage-broken.yaml`)).assertEqual(1);
    });

    it('returnsFailureWhenCloseFailsAfterCopyAndCleansTheStage', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      const sourceUri = 'content://documents/tree/primary%3Aprofiles/document/close';
      pickerPort.scriptedSelections.push([sourceUri]);
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      fileDriver.seedFile(sourceUri, buildBytes(64), 'close.yaml');
      fileDriver.injectFailure('close', `${FILES_DIR}/tmp/stage-close.yaml`, new Error(`close failed for ${FILES_DIR}/tmp/stage-close.yaml`));
      const picker = buildPicker(pickerPort, fileDriver, ['2026-08-11T14:00:00.000Z'], ['stage-close']);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());

      const failure = assertFailureIsSafe(result, 'close', [sourceUri, `${FILES_DIR}/tmp/stage-close.yaml`]);
      assertFailureIsRetryable(failure);
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/stage-close.yaml`)).assertFalse();
      expect(fileDriver.countCloses(sourceUri)).assertEqual(1);
    });

    it('returnsRetryableFailureWhenHashingTheStagedCopyFails', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      const sourceUri = 'content://documents/tree/primary%3Aprofiles/document/hash';
      pickerPort.scriptedSelections.push([sourceUri]);
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      fileDriver.seedFile(sourceUri, buildBytes(128), 'hash.yaml');
      fileDriver.injectFailure('hash', `${FILES_DIR}/tmp/stage-hash.yaml`, new Error(`hash failed for ${FILES_DIR}/tmp/stage-hash.yaml`));
      const picker = buildPicker(pickerPort, fileDriver, ['2026-08-11T15:00:00.000Z'], ['stage-hash']);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());

      const failure = assertFailureIsSafe(result, 'hashed', [sourceUri, `${FILES_DIR}/tmp/stage-hash.yaml`]);
      assertFailureIsRetryable(failure);
      expect(failure.profileName).assertEqual('hash.yaml');
      expect(failure.sourceDisplay).assertEqual('hash.yaml');
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/stage-hash.yaml`)).assertFalse();
    });

    it('rejectsHostileStageIdsBeforeCreatingAnyStageArtifacts', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      const sourceUri = 'content://documents/tree/primary%3Aprofiles/document/hostile-stage';
      pickerPort.scriptedSelections.push([sourceUri]);
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      fileDriver.seedFile(sourceUri, buildBytes(96), 'hostile.yaml');
      const picker = buildPicker(pickerPort, fileDriver, ['2026-08-11T15:30:00.000Z'], ['../escape']);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());

      const failure = assertFailureIsSafe(
        result,
        'Selected file',
        [sourceUri, '../escape', `${FILES_DIR}/escape.yaml`, `${FILES_DIR}/tmp/../escape.yaml`]
      );
      assertFailureIsRetryable(failure);
      expect(failure.profileName).assertEqual('hostile.yaml');
      expect(failure.sourceDisplay).assertEqual('hostile.yaml');
      expect(fileDriver.countCloses(sourceUri)).assertEqual(1);
      expect(fileDriver.operationLog.some((value: string): boolean => value.startsWith(`mkdir:${FILES_DIR}/tmp`))).assertFalse();
      expect(fileDriver.operationLog.some((value: string): boolean => value.startsWith(`open:${FILES_DIR}/escape.yaml`))).assertFalse();
      expect(fileDriver.operationLog.some((value: string): boolean => value.startsWith(`open:${FILES_DIR}/tmp/../escape.yaml`))).assertFalse();
      expect(fileDriver.operationLog.some((value: string): boolean => value.startsWith(`write:${FILES_DIR}`))).assertFalse();
      expect(fileDriver.fileExists(`${FILES_DIR}/escape.yaml`)).assertFalse();
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/../escape.yaml`)).assertFalse();
    });

    it('retriesPositiveShortWritesUntilEveryReadChunkIsFullyPersisted', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      const sourceUri = 'content://documents/tree/primary%3Aprofiles/document/short-write';
      pickerPort.scriptedSelections.push([sourceUri]);
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      const sourceBytes = buildBytes(97);
      fileDriver.seedFile(sourceUri, sourceBytes, 'short-write.yaml');
      fileDriver.scriptWriteCounts(`${FILES_DIR}/tmp/stage-short-write.yaml`, [7]);
      const picker = buildPicker(pickerPort, fileDriver, ['2026-08-11T15:40:00.000Z'], ['stage-short-write']);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());
      const acquired = result as AcquiredLocalResultView;

      expect(result.kind).assertEqual('ACQUIRED');
      expect(acquired.staged.byteLength).assertEqual(sourceBytes.length);
      assertBytesEqual(fileDriver.readFileBytes(acquired.staged.validationPath), sourceBytes);
    });

    it('failsSafelyWhenWriteMakesNoProgressAndCleansUpTheStage', 0, async () => {
      const pickerPort = new FakeDocumentPickerPort();
      const sourceUri = 'content://documents/tree/primary%3Aprofiles/document/zero-write';
      pickerPort.scriptedSelections.push([sourceUri]);
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      fileDriver.seedFile(sourceUri, buildBytes(80), 'zero-write.yaml');
      fileDriver.scriptWriteCounts(`${FILES_DIR}/tmp/stage-zero-write.yaml`, [0]);
      const picker = buildPicker(pickerPort, fileDriver, ['2026-08-11T15:45:00.000Z'], ['stage-zero-write']);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());

      const failure = assertFailureIsSafe(result, 'Selected file', [sourceUri, `${FILES_DIR}/tmp/stage-zero-write.yaml`]);
      assertFailureIsRetryable(failure);
      expect(failure.profileName).assertEqual('zero-write.yaml');
      expect(failure.sourceDisplay).assertEqual('zero-write.yaml');
      expect(fileDriver.hashPaths.length).assertEqual(0);
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/stage-zero-write.yaml`)).assertFalse();
    });
  });
}
