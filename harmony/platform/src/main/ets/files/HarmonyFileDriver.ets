import { fileIo, hash } from '@kit.CoreFileKit';
import type { BufferIoOptions, FileDriver, FileStat, FileToken } from './FileDriver';
import {
  BufferIoOptionsRecord,
  FileStatRecord,
  FileTokenRecord,
  FILE_MOVE_MODE_OVERWRITE,
  FILE_MOVE_MODE_NO_OVERWRITE
} from './FileDriver';

type MkdirOperation = (path: string, recursive: boolean) => Promise<void>;
type StatIfPresentOperation = (path: string) => Promise<FileStat | undefined>;

const SANDBOX_DIRECTORY_PREPARATION_FAILURE: string = 'Sandbox directory preparation failed.';
const FILE_EXISTS_ERROR_CODE: number = 13900015;

interface HarmonyDirectoryOperations {
  nativeMkdir?: MkdirOperation;
  statIfPresent?: StatIfPresentOperation;
}

async function mkdirWithRecursiveIdempotence(
  path: string,
  recursive: boolean,
  mkdir: MkdirOperation,
  statIfPresent: StatIfPresentOperation
): Promise<void> {
  try {
    await mkdir(path, recursive);
    return;
  } catch (error) {
    if (recursive && isFileExistsError(error)) {
      try {
        const existing: FileStat | undefined = await statIfPresent(path);
        if (existing !== undefined && existing.isDirectory) {
          return;
        }
      } catch (_) {
      }
    }
    throw new Error(SANDBOX_DIRECTORY_PREPARATION_FAILURE);
  }
}

export class HarmonyFileDriver implements FileDriver {
  private readonly nativeMkdir?: MkdirOperation;
  private readonly statIfPresentOverride?: StatIfPresentOperation;

  constructor(directoryOperations?: HarmonyDirectoryOperations) {
    this.nativeMkdir = directoryOperations?.nativeMkdir;
    this.statIfPresentOverride = directoryOperations?.statIfPresent;
  }

  async mkdir(path: string, recursive: boolean): Promise<void> {
    await mkdirWithRecursiveIdempotence(
      path,
      recursive,
      async (mkdirPath: string, mkdirRecursive: boolean): Promise<void> => {
        if (this.nativeMkdir !== undefined) {
          await this.nativeMkdir(mkdirPath, mkdirRecursive);
          return;
        }
        await fileIo.mkdir(mkdirPath, mkdirRecursive);
      },
      async (statPath: string): Promise<FileStat | undefined> => {
        if (this.statIfPresentOverride !== undefined) {
          return await this.statIfPresentOverride(statPath);
        }
        return await this.statIfPresent(statPath);
      }
    );
  }

  async list(path: string): Promise<string[]> {
    try {
      return await fileIo.listFile(path);
    } catch (_) {
      throw new Error('Sandbox directory listing failed.');
    }
  }

  async stat(path: string): Promise<FileStat> {
    try {
      const value = await fileIo.stat(path);
      return new FileStatRecord(value.size, value.isFile(), value.isDirectory());
    } catch (_) {
      throw new Error('Sandbox file status lookup failed.');
    }
  }

  async statIfPresent(path: string): Promise<FileStat | undefined> {
    try {
      const exists: boolean = await fileIo.access(path);
      if (!exists) {
        return undefined;
      }
      const value = await fileIo.stat(path);
      return new FileStatRecord(value.size, value.isFile(), value.isDirectory());
    } catch (error) {
      if (isNoSuchFileError(error)) {
        return undefined;
      }
      throw new Error('Sandbox file status lookup failed.');
    }
  }

  async open(path: string, mode: number): Promise<FileToken> {
    try {
      const file = await fileIo.open(path, mode);
      return new FileTokenRecord(file.fd, file.path, file.name);
    } catch (_) {
      throw new Error('Sandbox file open failed.');
    }
  }

  async close(file: number | FileToken): Promise<void> {
    const fd: number = typeof file === 'number' ? file : file.fd;
    try {
      await fileIo.close(fd);
    } catch (_) {
      throw new Error('Sandbox file close failed.');
    }
  }

  async read(fd: number, buffer: ArrayBuffer, options?: BufferIoOptions): Promise<number> {
    try {
      if (options === undefined) {
        return await fileIo.read(fd, buffer);
      }
      return await fileIo.read(fd, buffer, new BufferIoOptionsRecord(options.offset, options.length));
    } catch (_) {
      throw new Error('Sandbox file read failed.');
    }
  }

  async write(fd: number, buffer: ArrayBuffer | string, options?: BufferIoOptions): Promise<number> {
    try {
      if (options === undefined) {
        return await fileIo.write(fd, buffer);
      }
      return await fileIo.write(fd, buffer, new BufferIoOptionsRecord(options.offset, options.length));
    } catch (_) {
      throw new Error('Sandbox file write failed.');
    }
  }

  async unlink(path: string): Promise<void> {
    try {
      await fileIo.unlink(path);
    } catch (_) {
      throw new Error('Sandbox file removal failed.');
    }
  }

  async rmdir(path: string): Promise<void> {
    try {
      await fileIo.rmdir(path);
    } catch (_) {
      throw new Error('Sandbox directory removal failed.');
    }
  }

  async renameNoOverwrite(source: string, destination: string): Promise<void> {
    try {
      await fileIo.moveFile(source, destination, FILE_MOVE_MODE_NO_OVERWRITE);
    } catch (_) {
      throw new Error('Sandbox file move failed.');
    }
  }

  async renameReplace(source: string, destination: string): Promise<void> {
    try {
      await fileIo.moveFile(source, destination, FILE_MOVE_MODE_OVERWRITE);
    } catch (_) {
      throw new Error('Sandbox file replace failed.');
    }
  }

  async hash(path: string, algorithm: string): Promise<string> {
    try {
      return await hash.hash(path, algorithm);
    } catch (_) {
      throw new Error('Sandbox file hash failed.');
    }
  }
}

interface BusinessErrorShape {
  code?: number;
}

function isNoSuchFileError(error: Object | undefined): boolean {
  const record = error as BusinessErrorShape;
  return record?.code === 13900002;
}

function isFileExistsError(error: Object | undefined): boolean {
  const record = error as BusinessErrorShape;
  return record?.code === FILE_EXISTS_ERROR_CODE;
}
