import { describe, expect, it } from '@ohos/hypium';
import { FileStatRecord } from '../main/ets/files/FileDriver';
import { HarmonyFileDriver } from '../main/ets/files/HarmonyFileDriver';

const SANITIZED_MKDIR_FAILURE: string = 'Error: Sandbox directory preparation failed.';
const FILE_EXISTS_ERROR_CODE: number = 13900015;
const PERMISSION_ERROR_CODE: number = 13900012;

class FileIoBusinessError extends Error {
  code: number;

  constructor(code: number) {
    super(`code:${code}`);
    this.code = code;
  }
}

function fileIoBusinessError(code: number): FileIoBusinessError {
  return new FileIoBusinessError(code);
}

async function expectMkdirFailure(action: () => Promise<void>): Promise<string> {
  try {
    await action();
  } catch (error) {
    return `${error}`;
  }
  expect(false).assertTrue();
  return '';
}

function createDriver(
  mkdir: (path: string, recursive: boolean) => Promise<void>,
  statIfPresent: (path: string) => Promise<FileStatRecord | undefined>
): HarmonyFileDriver {
  return new HarmonyFileDriver({
    nativeMkdir: mkdir,
    statIfPresent
  });
}

export default function harmonyFileDriverTestsuite() {
  describe('HarmonyFileDriverTest', () => {
    it('returnsImmediatelyWhenNativeMkdirSucceeds', 0, async () => {
      let mkdirCalls: number = 0;
      let statCalls: number = 0;
      const driver: HarmonyFileDriver = createDriver(
        async () => {
          mkdirCalls += 1;
        },
        async () => {
          statCalls += 1;
          return new FileStatRecord(0, false, true);
        }
      );

      await driver.mkdir('/sandbox/app/files', true);

      expect(mkdirCalls).assertEqual(1);
      expect(statCalls).assertEqual(0);
    });

    it('treatsRecursiveMkdirFailureAsSuccessWhenTheDirectoryAlreadyExists', 0, async () => {
      let mkdirCalls: number = 0;
      let statCalls: number = 0;
      const driver: HarmonyFileDriver = createDriver(
        async () => {
          mkdirCalls += 1;
          throw fileIoBusinessError(FILE_EXISTS_ERROR_CODE);
        },
        async () => {
          statCalls += 1;
          return new FileStatRecord(0, false, true);
        }
      );

      await driver.mkdir('/sandbox/app/files', true);

      expect(mkdirCalls).assertEqual(1);
      expect(statCalls).assertEqual(1);
    });

    it('rejectsRecursiveMkdirFailureWhenTheExistingPathIsAFile', 0, async () => {
      let mkdirCalls: number = 0;
      let statCalls: number = 0;
      const driver: HarmonyFileDriver = createDriver(
        async () => {
          mkdirCalls += 1;
          throw fileIoBusinessError(FILE_EXISTS_ERROR_CODE);
        },
        async () => {
          statCalls += 1;
          return new FileStatRecord(12, true, false);
        }
      );
      const detail: string = await expectMkdirFailure(async () => {
        await driver.mkdir('/sandbox/app/files', true);
      });

      expect(detail).assertEqual(SANITIZED_MKDIR_FAILURE);
      expect(mkdirCalls).assertEqual(1);
      expect(statCalls).assertEqual(1);
    });

    it('rejectsRecursiveMkdirFailureWhenThePathIsStillAbsent', 0, async () => {
      let mkdirCalls: number = 0;
      let statCalls: number = 0;
      const driver: HarmonyFileDriver = createDriver(
        async () => {
          mkdirCalls += 1;
          throw fileIoBusinessError(FILE_EXISTS_ERROR_CODE);
        },
        async () => {
          statCalls += 1;
          return undefined;
        }
      );
      const detail: string = await expectMkdirFailure(async () => {
        await driver.mkdir('/sandbox/app/files', true);
      });

      expect(detail).assertEqual(SANITIZED_MKDIR_FAILURE);
      expect(mkdirCalls).assertEqual(1);
      expect(statCalls).assertEqual(1);
    });

    it('rejectsRecursiveMkdirFailureWhenStatusLookupAlsoFails', 0, async () => {
      let mkdirCalls: number = 0;
      let statCalls: number = 0;
      const driver: HarmonyFileDriver = createDriver(
        async () => {
          mkdirCalls += 1;
          throw fileIoBusinessError(FILE_EXISTS_ERROR_CODE);
        },
        async () => {
          statCalls += 1;
          throw new Error('stat failed');
        }
      );
      const detail: string = await expectMkdirFailure(async () => {
        await driver.mkdir('/sandbox/app/files', true);
      });

      expect(detail).assertEqual(SANITIZED_MKDIR_FAILURE);
      expect(mkdirCalls).assertEqual(1);
      expect(statCalls).assertEqual(1);
    });

    it('rejectsNonEexistRecursiveMkdirFailuresWithoutStatusLookup', 0, async () => {
      let mkdirCalls: number = 0;
      let statCalls: number = 0;
      const driver: HarmonyFileDriver = createDriver(
        async () => {
          mkdirCalls += 1;
          throw fileIoBusinessError(PERMISSION_ERROR_CODE);
        },
        async () => {
          statCalls += 1;
          return new FileStatRecord(0, false, true);
        }
      );
      const detail: string = await expectMkdirFailure(async () => {
        await driver.mkdir('/sandbox/app/files', true);
      });

      expect(detail).assertEqual(SANITIZED_MKDIR_FAILURE);
      expect(mkdirCalls).assertEqual(1);
      expect(statCalls).assertEqual(0);
    });

    it('keepsNonRecursiveMkdirExclusiveEvenIfTheDirectoryAlreadyExists', 0, async () => {
      let mkdirCalls: number = 0;
      let statCalls: number = 0;
      const driver: HarmonyFileDriver = createDriver(
        async () => {
          mkdirCalls += 1;
          throw fileIoBusinessError(FILE_EXISTS_ERROR_CODE);
        },
        async () => {
          statCalls += 1;
          return new FileStatRecord(0, false, true);
        }
      );
      const detail: string = await expectMkdirFailure(async () => {
        await driver.mkdir('/sandbox/app/files/.tmp-geoip', false);
      });

      expect(detail).assertEqual(SANITIZED_MKDIR_FAILURE);
      expect(mkdirCalls).assertEqual(1);
      expect(statCalls).assertEqual(0);
    });
  });
}
