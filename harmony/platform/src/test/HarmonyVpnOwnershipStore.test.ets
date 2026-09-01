import { describe, expect, it } from '@ohos/hypium';
import { OwnershipStoreCorruptError } from '@cmfa/shared';
import { HarmonyVpnOwnershipStore, activePlatformVpnOwnershipPath } from '../main/ets/vpn/HarmonyVpnOwnershipStore';
import { FakeFileDriver } from './fakes/PlatformFakes';

const FILES_DIR: string = '/sandbox/app/files';
const VPN_DIRECTORY: string = `${FILES_DIR}/vpn`;
const TARGET_PATH: string = `${VPN_DIRECTORY}/active-platform-vpn-v1.json`;
const TEMP_PATH: string = `${VPN_DIRECTORY}/active-platform-vpn-v1.json.tmp`;

async function expectRejects(action: () => Promise<void>): Promise<Error> {
  try {
    await action();
    expect().assertFail();
  } catch (error) {
    return error as Error;
  }
  return new Error('Expected rejection.');
}

async function expectCorrupt(action: () => Promise<string | null> | Promise<void>): Promise<void> {
  const error: Error = await expectRejects(async () => {
    await action();
  });
  expect(error instanceof OwnershipStoreCorruptError).assertTrue();
}

function createStore(
  fileDriver: FakeFileDriver,
  fsync?: (fd: number) => void
): HarmonyVpnOwnershipStore {
  return new HarmonyVpnOwnershipStore({
    fileDriver,
    filesDir: FILES_DIR,
    fsync
  });
}

function buildOversizeDocument(): string {
  return `{"version":1,"vpnId":"${'v'.repeat(240)}"}`;
}

export default function harmonyVpnOwnershipStoreTestsuite() {
  describe('HarmonyVpnOwnershipStoreTest', () => {
    it('readsMissingAsNullAndTreatsRepeatedMissingClearsAsIdempotent', 0, async () => {
      const files = new FakeFileDriver();
      const store = createStore(files);

      expect(activePlatformVpnOwnershipPath(FILES_DIR)).assertEqual(TARGET_PATH);
      expect(await store.read()).assertNull();
      expect(await store.read()).assertNull();

      await store.clearExpected('vpn-live-1');
      await store.clearExpected('vpn-live-1');

      expect(files.fileExists(TARGET_PATH)).assertFalse();
      expect(files.operationLog.filter((entry: string): boolean => entry === `statIfPresent:${TARGET_PATH}`).length >= 4).assertTrue();
      expect(files.operationLog.some((entry: string): boolean => entry.startsWith(`unlink:${TARGET_PATH}`))).assertFalse();
    });

    it('writesReadsAndClearsOnlyTheMatchingPersistedVpnId', 0, async () => {
      const files = new FakeFileDriver();
      const store = createStore(files);

      await store.write('vpn-live-1');

      expect(files.fileExists(TARGET_PATH)).assertTrue();
      expect(files.fileExists(TEMP_PATH)).assertFalse();
      expect(files.readFileText(TARGET_PATH)).assertEqual('{"version":1,"vpnId":"vpn-live-1"}');
      expect(await store.read()).assertEqual('vpn-live-1');

      await store.clearExpected('vpn-other');
      expect(files.fileExists(TARGET_PATH)).assertTrue();

      await store.clearExpected('vpn-live-1');
      expect(files.fileExists(TARGET_PATH)).assertFalse();
    });

    it('rejectsOversizeMalformedWrongVersionDuplicateKeyAndInvalidIdDocumentsAsCorrupt', 0, async () => {
      const files = new FakeFileDriver();
      const store = createStore(files);

      files.seedTextFile(TARGET_PATH, buildOversizeDocument());
      await expectCorrupt(async (): Promise<string | null> => store.read());

      files.writeTextFile(TARGET_PATH, '{"version":1,');
      await expectCorrupt(async (): Promise<string | null> => store.read());

      files.writeTextFile(TARGET_PATH, '{"version":2,"vpnId":"vpn-live-1"}');
      await expectCorrupt(async (): Promise<string | null> => store.read());

      files.writeTextFile(TARGET_PATH, '{"version":1,"vpnId":"vpn-live-1","vpnId":"vpn-live-2"}');
      await expectCorrupt(async (): Promise<string | null> => store.read());

      files.writeTextFile(TARGET_PATH, '{"version":1,"vpnId":"  "}');
      await expectCorrupt(async (): Promise<string | null> => store.read());
    });

    it('rejectsWritesThatExceedThe256ByteBound', 0, async () => {
      const files = new FakeFileDriver();
      const store = createStore(files);
      const oversizeVpnId: string = 'v'.repeat(240);

      const error: Error = await expectRejects(async () => {
        await store.write(oversizeVpnId);
      });

      expect(error instanceof OwnershipStoreCorruptError).assertFalse();
      expect(files.fileExists(TARGET_PATH)).assertFalse();
      expect(files.fileExists(TEMP_PATH)).assertFalse();
    });

    it('failsWriteClosedOnShortWriteFsyncAndRenameFailuresAndCleansUpTheTempFile', 0, async () => {
      const shortWriteFiles = new FakeFileDriver();
      shortWriteFiles.scriptWriteCounts(TEMP_PATH, [3]);
      const shortWriteStore = createStore(shortWriteFiles);

      await expectRejects(async () => {
        await shortWriteStore.write('vpn-live-1');
      });
      expect(shortWriteFiles.fileExists(TARGET_PATH)).assertFalse();
      expect(shortWriteFiles.fileExists(TEMP_PATH)).assertFalse();

      const fsyncFiles = new FakeFileDriver();
      const fsyncStore = createStore(fsyncFiles, (_fd: number): void => {
        throw new Error('fsync failed');
      });

      await expectRejects(async () => {
        await fsyncStore.write('vpn-live-2');
      });
      expect(fsyncFiles.fileExists(TARGET_PATH)).assertFalse();
      expect(fsyncFiles.fileExists(TEMP_PATH)).assertFalse();

      const renameFiles = new FakeFileDriver();
      renameFiles.injectFailure('renameReplace', `${TEMP_PATH}->${TARGET_PATH}`, new Error('rename failed'));
      const renameStore = createStore(renameFiles);

      await expectRejects(async () => {
        await renameStore.write('vpn-live-3');
      });
      expect(renameFiles.fileExists(TARGET_PATH)).assertFalse();
      expect(renameFiles.fileExists(TEMP_PATH)).assertFalse();
    });

    it('treatsCorruptStoredStateAsFatalDuringExactClear', 0, async () => {
      const files = new FakeFileDriver();
      const store = createStore(files);
      files.seedTextFile(TARGET_PATH, '{"version":1,"vpnId":"vpn-live-1","vpnId":"vpn-live-2"}');

      await expectCorrupt(async (): Promise<void> => store.clearExpected('vpn-live-1'));
      expect(files.fileExists(TARGET_PATH)).assertTrue();
    });
  });
}
