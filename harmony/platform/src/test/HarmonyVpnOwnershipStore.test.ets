import { describe, expect, it } from '@ohos/hypium';
import { OwnershipStoreCorruptError } from '@cmfa/shared';
import { HarmonyVpnOwnershipStore, activePlatformVpnOwnershipPath } from '../main/ets/vpn/HarmonyVpnOwnershipStore';
import { FakeFileDriver } from './fakes/PlatformFakes';

const FILES_DIR: string = '/sandbox/app/files';
const VPN_DIRECTORY: string = `${FILES_DIR}/vpn`;
const TARGET_PATH: string = `${VPN_DIRECTORY}/active-platform-vpn-v1.json`;
const TEMP_PATH: string = `${VPN_DIRECTORY}/active-platform-vpn-v1.json.tmp`;
const CLAIM_PATH: string = `${VPN_DIRECTORY}/active-platform-vpn-v1.claim.json`;

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

class WriteDuringClaimFileDriver extends FakeFileDriver {
  private readonly replacementVpnId: string;
  private claimTriggered: boolean = false;

  constructor(replacementVpnId: string) {
    super();
    this.replacementVpnId = replacementVpnId;
  }

  override async renameNoOverwrite(source: string, destination: string): Promise<void> {
    await super.renameNoOverwrite(source, destination);
    if (!this.claimTriggered && source === TARGET_PATH && destination === CLAIM_PATH) {
      this.claimTriggered = true;
      const writerStore: HarmonyVpnOwnershipStore = createStore(this);
      await writerStore.write(this.replacementVpnId);
    }
  }
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
      expect(files.fileExists(CLAIM_PATH)).assertFalse();
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

    it('recoversAValidClaimFileWhenTheTargetIsMissingAndFailsClosedOnCorruptClaim', 0, async () => {
      const validFiles = new FakeFileDriver();
      const validStore = createStore(validFiles);
      validFiles.seedTextFile(CLAIM_PATH, '{"version":1,"vpnId":"vpn-claimed-1"}');

      expect(await validStore.read()).assertEqual('vpn-claimed-1');
      expect(validFiles.fileExists(TARGET_PATH)).assertTrue();
      expect(validFiles.fileExists(CLAIM_PATH)).assertFalse();

      const corruptFiles = new FakeFileDriver();
      const corruptStore = createStore(corruptFiles);
      corruptFiles.seedTextFile(CLAIM_PATH, '{"version":1,"vpnId":"vpn-claimed-1","vpnId":"vpn-claimed-2"}');

      await expectCorrupt(async (): Promise<string | null> => corruptStore.read());
      expect(corruptFiles.fileExists(CLAIM_PATH)).assertTrue();
      expect(corruptFiles.fileExists(TARGET_PATH)).assertFalse();
    });

    it('neverDeletesANewOwnerWrittenConcurrentlyDuringClearExpected', 0, async () => {
      const matchingFiles = new WriteDuringClaimFileDriver('vpn-new-1');
      const matchingStore = createStore(matchingFiles);
      matchingFiles.seedTextFile(TARGET_PATH, '{"version":1,"vpnId":"vpn-old-1"}');

      await matchingStore.clearExpected('vpn-old-1');

      expect(matchingFiles.fileExists(TARGET_PATH)).assertTrue();
      expect(matchingFiles.readFileText(TARGET_PATH)).assertEqual('{"version":1,"vpnId":"vpn-new-1"}');
      expect(matchingFiles.fileExists(CLAIM_PATH)).assertFalse();

      const mismatchFiles = new WriteDuringClaimFileDriver('vpn-new-2');
      const mismatchStore = createStore(mismatchFiles);
      mismatchFiles.seedTextFile(TARGET_PATH, '{"version":1,"vpnId":"vpn-old-2"}');

      await mismatchStore.clearExpected('vpn-other');

      expect(mismatchFiles.fileExists(TARGET_PATH)).assertTrue();
      expect(mismatchFiles.readFileText(TARGET_PATH)).assertEqual('{"version":1,"vpnId":"vpn-new-2"}');
      expect(mismatchFiles.fileExists(CLAIM_PATH)).assertFalse();
    });
  });
}
