import { describe, expect, it } from '@ohos/hypium';
import type { VpnPlatformOwnershipRecord } from '@cmfa/shared';
import { OwnershipStoreCorruptError } from '@cmfa/shared';
import { HarmonyVpnOwnershipStore, activePlatformVpnOwnershipPath } from '../main/ets/vpn/HarmonyVpnOwnershipStore';
import { BufferIoOptionsRecord } from '../main/ets/files/FileDriver';
import { FakeFileDriver } from './fakes/PlatformFakes';

const FILES_DIR: string = '/sandbox/app/files';
const VPN_DIRECTORY: string = `${FILES_DIR}/vpn`;
const TARGET_PATH: string = `${VPN_DIRECTORY}/active-platform-vpn-v1.json`;
const CLAIM_PATH: string = `${VPN_DIRECTORY}/active-platform-vpn-v1.claim.json`;
const TEMP_A_PATH: string = `${VPN_DIRECTORY}/active-platform-vpn-v1.op-a.tmp`;
const TEMP_B_PATH: string = `${VPN_DIRECTORY}/active-platform-vpn-v1.op-b.tmp`;

class OwnershipRecord implements VpnPlatformOwnershipRecord {
  readonly phase: 'PREPARED' | 'ACTIVE' | 'RELEASED';
  readonly vpnId: string;

  constructor(phase: 'PREPARED' | 'ACTIVE' | 'RELEASED', vpnId: string) {
    this.phase = phase;
    this.vpnId = vpnId;
  }
}

async function expectRejects<T>(action: () => Promise<T>): Promise<Error> {
  try {
    await action();
    expect().assertFail();
  } catch (error) {
    return error as Error;
  }
  return new Error('Expected rejection.');
}

async function expectCorrupt(action: () => Promise<VpnPlatformOwnershipRecord | null> | Promise<void>): Promise<void> {
  const error: Error = await expectRejects(async (): Promise<void> => {
    await action();
  });
  expect(error instanceof OwnershipStoreCorruptError).assertTrue();
}

function createOwnership(phase: 'PREPARED' | 'ACTIVE' | 'RELEASED', vpnId: string): OwnershipRecord {
  return new OwnershipRecord(phase, vpnId);
}

function createStore(
  fileDriver: FakeFileDriver,
  operationId: string,
  fsync?: (fd: number) => void
): HarmonyVpnOwnershipStore {
  return new HarmonyVpnOwnershipStore({
    fileDriver,
    filesDir: FILES_DIR,
    fsync,
    createOperationId: (): string => operationId
  });
}

function buildOversizeDocument(): string {
  return `{"version":1,"phase":"ACTIVE","vpnId":"${'v'.repeat(220)}"}`;
}

class WriteDuringClaimFileDriver extends FakeFileDriver {
  private readonly replacementOwnership: OwnershipRecord;
  private readonly fsync?: (fd: number) => void;
  private claimTriggered: boolean = false;

  constructor(replacementOwnership: OwnershipRecord, fsync?: (fd: number) => void) {
    super();
    this.replacementOwnership = replacementOwnership;
    this.fsync = fsync;
  }

  override async renameNoOverwrite(source: string, destination: string): Promise<void> {
    await super.renameNoOverwrite(source, destination);
    if (!this.claimTriggered && source === TARGET_PATH && destination === CLAIM_PATH) {
      this.claimTriggered = true;
      const writerStore: HarmonyVpnOwnershipStore = createStore(this, 'op-b', this.fsync);
      await writerStore.write(this.replacementOwnership);
    }
  }
}

class WriteDuringTempWriteFileDriver extends FakeFileDriver {
  private nestedStore?: HarmonyVpnOwnershipStore;
  private nestedOwnership?: OwnershipRecord;
  private triggered: boolean = false;

  constructor() {
    super();
  }

  setNestedWrite(store: HarmonyVpnOwnershipStore, ownership: OwnershipRecord): void {
    this.nestedStore = store;
    this.nestedOwnership = ownership;
  }

  override async write(fd: number, buffer: ArrayBuffer | string, options?: BufferIoOptionsRecord): Promise<number> {
    if (!this.triggered) {
      const text: string = typeof buffer === 'string' ? buffer : String.fromCharCode(...new Uint8Array(buffer));
      if (text.includes('"phase":"PREPARED"') && text.includes('"vpnId":"vpn-write-a"')) {
        this.triggered = true;
        await this.nestedStore?.write(this.nestedOwnership ?? createOwnership('ACTIVE', 'vpn-write-b'));
      }
    }
    return await super.write(fd, buffer, options);
  }
}

export default function harmonyVpnOwnershipStoreTestsuite() {
  describe('HarmonyVpnOwnershipStoreTest', () => {
    it('readsMissingAsNullAndTreatsRepeatedMissingClearsAsIdempotent', 0, async () => {
      const files = new FakeFileDriver();
      const store = createStore(files, 'op-a');

      expect(activePlatformVpnOwnershipPath(FILES_DIR)).assertEqual(TARGET_PATH);
      expect(await store.read()).assertNull();
      expect(await store.read()).assertNull();

      await store.clearExpected(createOwnership('ACTIVE', 'vpn-live-1'));
      await store.clearExpected(createOwnership('ACTIVE', 'vpn-live-1'));

      expect(files.fileExists(TARGET_PATH)).assertFalse();
      expect(files.operationLog.filter((entry: string): boolean => entry === `statIfPresent:${TARGET_PATH}`).length >= 4).assertTrue();
      expect(files.operationLog.some((entry: string): boolean => entry.startsWith(`unlink:${TARGET_PATH}`))).assertFalse();
    });

    it('writesReadsAndClearsExactOwnershipRecordsAcrossPreparedActiveAndReleased', 0, async () => {
      const files = new FakeFileDriver();
      const preparedStore = createStore(files, 'op-a');
      const activeStore = createStore(files, 'op-b');
      const releasedStore = createStore(files, 'op-c');

      await preparedStore.write(createOwnership('PREPARED', 'vpn-live-1'));
      expect(files.readFileText(TARGET_PATH)).assertEqual('{"version":1,"phase":"PREPARED","vpnId":"vpn-live-1"}');
      const prepared = await preparedStore.read();
      expect(prepared?.phase ?? '').assertEqual('PREPARED');
      expect(prepared?.vpnId ?? '').assertEqual('vpn-live-1');

      await activeStore.write(createOwnership('ACTIVE', 'vpn-live-1'));
      expect(files.readFileText(TARGET_PATH)).assertEqual('{"version":1,"phase":"ACTIVE","vpnId":"vpn-live-1"}');

      await releasedStore.write(createOwnership('RELEASED', 'vpn-live-1'));
      expect(files.readFileText(TARGET_PATH)).assertEqual('{"version":1,"phase":"RELEASED","vpnId":"vpn-live-1"}');

      await releasedStore.clearExpected(createOwnership('ACTIVE', 'vpn-live-1'));
      expect(files.fileExists(TARGET_PATH)).assertTrue();

      await releasedStore.clearExpected(createOwnership('RELEASED', 'vpn-live-1'));
      expect(files.fileExists(TARGET_PATH)).assertFalse();
      expect(files.fileExists(CLAIM_PATH)).assertFalse();
    });

    it('rejectsOversizeMalformedWrongVersionDuplicateKeyInvalidPhaseAndInvalidIdDocumentsAsCorrupt', 0, async () => {
      const files = new FakeFileDriver();
      const store = createStore(files, 'op-a');

      files.seedTextFile(TARGET_PATH, buildOversizeDocument());
      await expectCorrupt(async (): Promise<VpnPlatformOwnershipRecord | null> => store.read());

      files.writeTextFile(TARGET_PATH, '{"version":1,');
      await expectCorrupt(async (): Promise<VpnPlatformOwnershipRecord | null> => store.read());

      files.writeTextFile(TARGET_PATH, '{"version":2,"phase":"ACTIVE","vpnId":"vpn-live-1"}');
      await expectCorrupt(async (): Promise<VpnPlatformOwnershipRecord | null> => store.read());

      files.writeTextFile(TARGET_PATH, '{"version":1,"phase":"ACTIVE","vpnId":"vpn-live-1","vpnId":"vpn-live-2"}');
      await expectCorrupt(async (): Promise<VpnPlatformOwnershipRecord | null> => store.read());

      files.writeTextFile(TARGET_PATH, '{"version":1,"phase":"UNKNOWN","vpnId":"vpn-live-1"}');
      await expectCorrupt(async (): Promise<VpnPlatformOwnershipRecord | null> => store.read());

      files.writeTextFile(TARGET_PATH, '{"version":1,"phase":"ACTIVE","vpnId":"  "}');
      await expectCorrupt(async (): Promise<VpnPlatformOwnershipRecord | null> => store.read());
    });

    it('rejectsWritesThatExceedThe256ByteBoundOrUseInvalidOperationIds', 0, async () => {
      const files = new FakeFileDriver();
      const store = createStore(files, 'op-a');
      const oversizeVpnId: string = 'v'.repeat(220);

      const error: Error = await expectRejects(async (): Promise<void> => {
        await store.write(createOwnership('ACTIVE', oversizeVpnId));
      });
      expect(error instanceof OwnershipStoreCorruptError).assertFalse();
      expect(files.fileExists(TARGET_PATH)).assertFalse();

      const invalidOpStore = new HarmonyVpnOwnershipStore({
        fileDriver: files,
        filesDir: FILES_DIR,
        createOperationId: (): string => 'bad/op'
      });
      const invalidOpError: Error = await expectRejects(async (): Promise<void> => {
        await invalidOpStore.write(createOwnership('ACTIVE', 'vpn-live-1'));
      });
      expect(invalidOpError.message.includes('operation id')).assertTrue();
    });

    it('failsWriteClosedOnShortWriteFsyncAndRenameFailuresAndCleansUpEachTempFile', 0, async () => {
      const shortWriteFiles = new FakeFileDriver();
      shortWriteFiles.scriptWriteCounts(TEMP_A_PATH, [3]);
      const shortWriteStore = createStore(shortWriteFiles, 'op-a', (): void => {});

      await shortWriteStore.write(createOwnership('ACTIVE', 'vpn-live-1'));
      expect(shortWriteFiles.fileExists(TARGET_PATH)).assertTrue();
      expect(shortWriteFiles.readFileText(TARGET_PATH)).assertEqual('{"version":1,"phase":"ACTIVE","vpnId":"vpn-live-1"}');
      expect(shortWriteFiles.fileExists(TEMP_A_PATH)).assertFalse();

      const fsyncFiles = new FakeFileDriver();
      const fsyncStore = createStore(fsyncFiles, 'op-a', (_fd: number): void => {
        throw new Error('fsync failed');
      });
      await expectRejects(async (): Promise<void> => {
        await fsyncStore.write(createOwnership('ACTIVE', 'vpn-live-2'));
      });
      expect(fsyncFiles.fileExists(TARGET_PATH)).assertFalse();
      expect(fsyncFiles.fileExists(TEMP_A_PATH)).assertFalse();

      const renameFiles = new FakeFileDriver();
      renameFiles.injectFailure('renameReplace', `${TEMP_A_PATH}->${TARGET_PATH}`, new Error('rename failed'));
      const renameStore = createStore(renameFiles, 'op-a');
      await expectRejects(async (): Promise<void> => {
        await renameStore.write(createOwnership('ACTIVE', 'vpn-live-3'));
      });
      expect(renameFiles.fileExists(TARGET_PATH)).assertFalse();
      expect(renameFiles.fileExists(TEMP_A_PATH)).assertFalse();
    });

    it('treatsCorruptStoredStateAsFatalDuringExactClear', 0, async () => {
      const files = new FakeFileDriver();
      const store = createStore(files, 'op-a');
      files.seedTextFile(TARGET_PATH, '{"version":1,"phase":"ACTIVE","vpnId":"vpn-live-1","vpnId":"vpn-live-2"}');

      await expectCorrupt(async (): Promise<void> => store.clearExpected(createOwnership('ACTIVE', 'vpn-live-1')));
      expect(files.fileExists(TARGET_PATH)).assertFalse();
      expect(files.fileExists(CLAIM_PATH)).assertTrue();
    });

    it('recoversAValidClaimFileWhenTheTargetIsMissingAndFailsClosedOnCorruptClaim', 0, async () => {
      const validFiles = new FakeFileDriver();
      const validStore = createStore(validFiles, 'op-a');
      validFiles.seedTextFile(CLAIM_PATH, '{"version":1,"phase":"RELEASED","vpnId":"vpn-claimed-1"}');

      const recovered = await validStore.read();
      expect(recovered?.phase ?? '').assertEqual('RELEASED');
      expect(recovered?.vpnId ?? '').assertEqual('vpn-claimed-1');
      expect(validFiles.fileExists(TARGET_PATH)).assertTrue();
      expect(validFiles.fileExists(CLAIM_PATH)).assertFalse();

      const corruptFiles = new FakeFileDriver();
      const corruptStore = createStore(corruptFiles, 'op-a');
      corruptFiles.seedTextFile(CLAIM_PATH, '{"version":1,"phase":"RELEASED","vpnId":"vpn-claimed-1","vpnId":"vpn-claimed-2"}');

      await expectCorrupt(async (): Promise<VpnPlatformOwnershipRecord | null> => corruptStore.read());
      expect(corruptFiles.fileExists(CLAIM_PATH)).assertTrue();
      expect(corruptFiles.fileExists(TARGET_PATH)).assertFalse();
    });

    it('neverDeletesANewOwnerWrittenConcurrentlyDuringClearExpected', 0, async () => {
      const matchingFiles = new WriteDuringClaimFileDriver(createOwnership('ACTIVE', 'vpn-new-1'), (): void => {});
      const matchingStore = createStore(matchingFiles, 'op-a', (): void => {});
      matchingFiles.seedTextFile(TARGET_PATH, '{"version":1,"phase":"ACTIVE","vpnId":"vpn-old-1"}');

      await matchingStore.clearExpected(createOwnership('ACTIVE', 'vpn-old-1'));

      expect(matchingFiles.fileExists(TARGET_PATH)).assertTrue();
      expect(matchingFiles.readFileText(TARGET_PATH)).assertEqual('{"version":1,"phase":"ACTIVE","vpnId":"vpn-new-1"}');
      expect(matchingFiles.fileExists(CLAIM_PATH)).assertFalse();

      const mismatchFiles = new WriteDuringClaimFileDriver(createOwnership('ACTIVE', 'vpn-new-2'), (): void => {});
      const mismatchStore = createStore(mismatchFiles, 'op-a', (): void => {});
      mismatchFiles.seedTextFile(TARGET_PATH, '{"version":1,"phase":"ACTIVE","vpnId":"vpn-old-2"}');

      await mismatchStore.clearExpected(createOwnership('ACTIVE', 'vpn-other'));

      expect(mismatchFiles.fileExists(TARGET_PATH)).assertTrue();
      expect(mismatchFiles.readFileText(TARGET_PATH)).assertEqual('{"version":1,"phase":"ACTIVE","vpnId":"vpn-new-2"}');
      expect(mismatchFiles.fileExists(CLAIM_PATH)).assertFalse();
    });

    it('usesUniqueOperationTempsSoConcurrentWritesDoNotClobberEachOther', 0, async () => {
      const nestedDriver = new WriteDuringTempWriteFileDriver();
      const storeB = createStore(nestedDriver, 'op-b', (): void => {});
      nestedDriver.setNestedWrite(storeB, createOwnership('ACTIVE', 'vpn-write-b'));
      const storeA = createStore(nestedDriver, 'op-a', (): void => {});

      await storeA.write(createOwnership('PREPARED', 'vpn-write-a'));

      expect(nestedDriver.operationLog.some((entry: string): boolean => entry.includes(TEMP_A_PATH))).assertTrue();
      expect(nestedDriver.operationLog.some((entry: string): boolean => entry.includes(TEMP_B_PATH))).assertTrue();
      expect(nestedDriver.fileExists(TEMP_A_PATH)).assertFalse();
      expect(nestedDriver.fileExists(TEMP_B_PATH)).assertFalse();
      const finalText: string = nestedDriver.readFileText(TARGET_PATH);
      const finalIsA: boolean = finalText === '{"version":1,"phase":"PREPARED","vpnId":"vpn-write-a"}';
      const finalIsB: boolean = finalText === '{"version":1,"phase":"ACTIVE","vpnId":"vpn-write-b"}';
      expect(finalIsA || finalIsB).assertTrue();
    });
  });
}
