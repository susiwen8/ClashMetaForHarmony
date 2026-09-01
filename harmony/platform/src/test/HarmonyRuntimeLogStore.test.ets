import { describe, expect, it } from '@ohos/hypium';
import { createRuntimeLogEntry, type RuntimeLogEntry } from '@cmfa/shared';
import {
  HarmonyRuntimeLogStore,
  runtimeLogCurrentPath,
  runtimeLogPreviousPath
} from '../main/ets/diagnostics/HarmonyRuntimeLogStore';
import { FakeFileDriver } from './fakes/PlatformFakes';

const FILES_DIR: string = '/sandbox/files';

export default function harmonyRuntimeLogStoreTestsuite() {
  describe('HarmonyRuntimeLogStoreTest', () => {
    it('appendsReadsExportsAndClearsBoundedJsonlHistory', 0, async () => {
      const files = new FakeFileDriver();
      const store = new HarmonyRuntimeLogStore({ fileDriver: files, filesDir: FILES_DIR, maxFileBytes: 8192 });
      const first: RuntimeLogEntry = createRuntimeLogEntry('2026-08-31T12:00:00.000Z', 'INFO', 'vpn starting');
      const second: RuntimeLogEntry = createRuntimeLogEntry('2026-08-31T12:00:01.000Z', 'WARN', 'network recovering');

      await Promise.all([store.append(first), store.append(second)]);
      await store.drain();
      const entries: RuntimeLogEntry[] = await store.read();
      const exported: string = await store.exportText();

      expect(entries.length).assertEqual(2);
      expect(entries[0].message).assertEqual('vpn starting');
      expect(entries[1].message).assertEqual('network recovering');
      expect(exported.includes('[INFO] vpn starting')).assertTrue();
      expect(exported.includes('[WARN] network recovering')).assertTrue();

      await store.clear();
      expect((await store.read()).length).assertEqual(0);
    });

    it('rotatesAtTheBoundAndIgnoresCorruptOrPartialLines', 0, async () => {
      const files = new FakeFileDriver();
      const store = new HarmonyRuntimeLogStore({ fileDriver: files, filesDir: FILES_DIR, maxFileBytes: 100 });

      await store.append(createRuntimeLogEntry('2026-08-31T12:00:00.000Z', 'INFO', 'first-entry-long-enough-to-rotate'));
      await store.append(createRuntimeLogEntry('2026-08-31T12:00:01.000Z', 'ERROR', 'second-entry-long-enough-to-rotate'));
      await store.append(createRuntimeLogEntry('2026-08-31T12:00:02.000Z', 'WARN', 'third'));
      await store.drain();

      expect(files.fileExists(runtimeLogPreviousPath(FILES_DIR))).assertTrue();
      const currentPath: string = runtimeLogCurrentPath(FILES_DIR);
      files.writeTextFile(currentPath, `${files.readFileText(currentPath)}\n{"timestamp":`);
      const entries: RuntimeLogEntry[] = await store.read(20);
      expect(entries.length >= 1).assertTrue();
      expect(entries[entries.length - 1].message).assertEqual('third');
    });
  });
}
