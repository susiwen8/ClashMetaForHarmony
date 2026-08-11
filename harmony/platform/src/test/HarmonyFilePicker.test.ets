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
      fileDriver.seedFile(sourceUri, buildBytes(256), 'broken.yaml');
      fileDriver.injectFailure('read', sourceUri, new Error('read failed at content://documents/tree/primary'));
      fileDriver.injectFailure('unlink', `${FILES_DIR}/tmp/stage-broken.yaml`, new Error('cleanup failed at /private/tmp/stage-broken.yaml'));
      const picker = buildPicker(pickerPort, fileDriver, ['2026-08-11T13:00:00.000Z'], ['stage-broken']);

      const result = await picker.acquire(new EmptyLocalAcquireCommand());

      assertFailureIsSafe(
        result,
        'copy',
        [sourceUri, '/private/tmp/stage-broken.yaml', `${FILES_DIR}/tmp/stage-broken.yaml`]
      );
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

      assertFailureIsSafe(result, 'close', [sourceUri, `${FILES_DIR}/tmp/stage-close.yaml`]);
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/stage-close.yaml`)).assertFalse();
      expect(fileDriver.countCloses(sourceUri)).assertEqual(1);
    });
  });
}
