import { describe, expect, it } from '@ohos/hypium';
import {
  HarmonyRuntimeLogExporter,
  type RuntimeLogSavePickerPort,
  type RuntimeLogSaveOptions
} from '../main/ets/diagnostics/HarmonyRuntimeLogExporter';
import { FakeFileDriver } from './fakes/PlatformFakes';

class FakeSavePicker implements RuntimeLogSavePickerPort {
  selections: string[] = [];
  requests: RuntimeLogSaveOptions[] = [];

  async save(options: RuntimeLogSaveOptions): Promise<string[]> {
    this.requests.push(options);
    return this.selections.slice();
  }
}

export default function harmonyRuntimeLogExporterTestsuite() {
  describe('HarmonyRuntimeLogExporterTest', () => {
    it('writesSelectedUtf8TextAndTreatsEmptySelectionAsCancellation', 0, async () => {
      const picker = new FakeSavePicker();
      const files = new FakeFileDriver();
      const exporter = new HarmonyRuntimeLogExporter({ picker, fileDriver: files });

      expect(await exporter.export('diagnostic log')).assertEqual('CANCELLED');

      picker.selections = ['/documents/runtime-log.txt'];
      expect(await exporter.export('diagnostic log')).assertEqual('EXPORTED');
      expect(files.readFileText('/documents/runtime-log.txt')).assertEqual('diagnostic log');
      expect(files.countCloses('/documents/runtime-log.txt')).assertEqual(1);
      expect(picker.requests[1].newFileNames[0]).assertEqual('clash-meta-runtime-log.txt');
    });

    it('returnsFailedWithoutLeakingThePlatformError', 0, async () => {
      const picker = new FakeSavePicker();
      const files = new FakeFileDriver();
      picker.selections = ['/documents/runtime-log.txt'];
      files.injectFailure('open', '/documents/runtime-log.txt', new Error('secret platform path'));
      const exporter = new HarmonyRuntimeLogExporter({ picker, fileDriver: files });

      expect(await exporter.export('log')).assertEqual('FAILED');
    });

    it('restoresAnExistingTargetWhenTheExportWriteFailsPartially', 0, async () => {
      const picker = new FakeSavePicker();
      const files = new FakeFileDriver();
      const target: string = '/documents/existing.txt';
      picker.selections = [target];
      files.seedTextFile(target, 'original-content');
      files.scriptWriteCounts(target, [1, 0]);
      const exporter = new HarmonyRuntimeLogExporter({ picker, fileDriver: files });

      expect(await exporter.export('replacement-log')).assertEqual('FAILED');
      expect(files.readFileText(target)).assertEqual('original-content');
    });
  });
}
