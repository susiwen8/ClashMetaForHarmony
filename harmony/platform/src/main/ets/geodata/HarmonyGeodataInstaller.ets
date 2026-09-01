import { hilog } from '@kit.PerformanceAnalysisKit';
import type { FileDriver, FileToken } from '../files/FileDriver';
import {
  FILE_OPEN_MODE_CREATE,
  FILE_OPEN_MODE_READ_ONLY,
  FILE_OPEN_MODE_TRUNC,
  FILE_OPEN_MODE_WRITE_ONLY
} from '../files/FileDriver';

const GEODATA_FILE_NAME: string = 'geoip.metadb';
const TEMP_FILE_PREFIX: string = '.tmp-geoip.metadb-';
const CANDIDATE_FILE_NAME: string = 'candidate.metadb';
const BACKUP_FILE_NAME: string = 'backup.metadb';
const COPY_BUFFER_SIZE: number = 64 * 1024;
const MAX_TEMP_DIR_ATTEMPTS: number = 8;
const HASH_ALGORITHM: string = 'sha256';
const SAFE_TEMP_ID_PATTERN: RegExp = /^[A-Za-z0-9._-]+$/u;
const GEODATA_LOG_DOMAIN: number = 0x0000;
const GEODATA_LOG_TAG: string = 'CMFAGeodata';
const UNKNOWN_DIAGNOSTIC_CODE: number = -1;

export interface PackagedRawfileReader {
  readRawfile(name: string): Promise<Uint8Array>;
}

export interface GeodataInstallDiagnosticEvent {
  stage: string;
  code: number;
}

export interface GeodataDiagnosticSink {
  report(stage: string, code: number): void;
}

export interface GeodataInstaller {
  ensureInstalled(): Promise<void>;
}

export interface HarmonyGeodataInstallerDependencies {
  resourceReader: PackagedRawfileReader;
  fileDriver: FileDriver;
  filesDir: string;
  expectedByteLength: number;
  expectedSha256Digest: string;
  createTempId: () => string;
  diagnostics?: GeodataDiagnosticSink;
}

export class HilogGeodataDiagnosticSink implements GeodataDiagnosticSink {
  report(stage: string, code: number): void {
    hilog.error(
      GEODATA_LOG_DOMAIN,
      GEODATA_LOG_TAG,
      '%{public}s:%{public}d',
      stage,
      code
    );
  }
}

class NoopGeodataDiagnosticSink implements GeodataDiagnosticSink {
  report(_stage: string, _code: number): void {
  }
}

class HarmonyGeodataInstallError extends Error {
  constructor() {
    super('Packaged geodata installation failed.');
  }
}

interface DiagnosticCodeCarrier {
  code?: number;
}

class ClaimedTempPaths {
  readonly rootPath: string;
  readonly candidatePath: string;
  readonly backupPath: string;

  constructor(rootPath: string) {
    this.rootPath = rootPath;
    this.candidatePath = `${rootPath}/${CANDIDATE_FILE_NAME}`;
    this.backupPath = `${rootPath}/${BACKUP_FILE_NAME}`;
  }
}

class ExistingTargetSnapshot {
  readonly size: number;
  readonly digest: string;

  constructor(size: number, digest: string) {
    this.size = size;
    this.digest = digest;
  }
}

export class HarmonyGeodataInstaller implements GeodataInstaller {
  private readonly resourceReader: PackagedRawfileReader;
  private readonly fileDriver: FileDriver;
  private readonly filesDir: string;
  private readonly expectedByteLength: number;
  private readonly expectedSha256Digest: string;
  private readonly createTempId: () => string;
  private readonly diagnostics: GeodataDiagnosticSink;

  constructor(dependencies: HarmonyGeodataInstallerDependencies) {
    this.resourceReader = dependencies.resourceReader;
    this.fileDriver = dependencies.fileDriver;
    this.filesDir = normalizeAbsoluteSandboxRoot(dependencies.filesDir);
    this.expectedByteLength = dependencies.expectedByteLength;
    this.expectedSha256Digest = dependencies.expectedSha256Digest.toLowerCase();
    this.createTempId = dependencies.createTempId;
    this.diagnostics = dependencies.diagnostics ?? new NoopGeodataDiagnosticSink();
  }

  async ensureInstalled(): Promise<void> {
    const targetPath: string = `${this.filesDir}/${GEODATA_FILE_NAME}`;
    let claimedTempPaths: ClaimedTempPaths | undefined = undefined;
    let retainClaimedTempDir: boolean = false;

    try {
      await this.runStage('files.mkdir', async (): Promise<void> => {
        await this.fileDriver.mkdir(this.filesDir, true);
      });
      if (await this.matchesInstalledTarget(targetPath)) {
        return;
      }
      const packagedBytes: Uint8Array = await this.runStage('resource.read', async (): Promise<Uint8Array> => {
        return await this.resourceReader.readRawfile(GEODATA_FILE_NAME);
      });
      await this.verifyPackagedBytes(packagedBytes);
      claimedTempPaths = await this.claimTempDir();
      await this.writeCandidateFile(claimedTempPaths.candidatePath, packagedBytes);
      await this.runStage('candidate.hash', async (): Promise<void> => {
        const digest: string = await this.fileDriver.hash(claimedTempPaths!.candidatePath, HASH_ALGORITHM);
        if (digest.toLowerCase() !== this.expectedSha256Digest) {
          throw new Error('Packaged geodata digest mismatch.');
        }
      });
      const existingTarget: ExistingTargetSnapshot | undefined = await this.captureExistingTargetSnapshot(targetPath);
      if (existingTarget !== undefined) {
        await this.copyTargetIntoBackup(targetPath, claimedTempPaths.backupPath, existingTarget.size);
        await this.runStage('backup.hash', async (): Promise<void> => {
          const backupStat = await this.fileDriver.stat(claimedTempPaths!.backupPath);
          if (!backupStat.isFile || backupStat.size !== existingTarget.size) {
            throw new Error('Backup geodata verification failed.');
          }
          const backupDigest: string = await this.fileDriver.hash(claimedTempPaths!.backupPath, HASH_ALGORITHM);
          if (backupDigest.toLowerCase() !== existingTarget.digest) {
            throw new Error('Backup geodata digest mismatch.');
          }
        });
      }
      await this.runStage('replace.apply', async (): Promise<void> => {
        await this.fileDriver.renameReplace(claimedTempPaths!.candidatePath, targetPath);
      });
      try {
        await this.runStage('target.verify', async (): Promise<void> => {
          await this.requireExpectedTarget(targetPath);
        });
      } catch (verifyError) {
        if (existingTarget === undefined) {
          await this.safeRemoveUnexpectedTarget(targetPath);
          throw verifyError as Error;
        }
        try {
          await this.runStage('restore.replace', async (): Promise<void> => {
            await this.fileDriver.renameReplace(claimedTempPaths!.backupPath, targetPath);
          });
          await this.runStage('restore.verify', async (): Promise<void> => {
            const restored = await this.fileDriver.stat(targetPath);
            if (!restored.isFile || restored.size !== existingTarget.size) {
              throw new Error('Restored geodata verification failed.');
            }
            const restoredDigest: string = await this.fileDriver.hash(targetPath, HASH_ALGORITHM);
            if (restoredDigest.toLowerCase() !== existingTarget.digest) {
              throw new Error('Restored geodata digest mismatch.');
            }
          });
        } catch (restoreError) {
          retainClaimedTempDir = true;
          throw restoreError as Error;
        }
        throw verifyError as Error;
      }
      await this.safeCleanupClaimedTempDir(claimedTempPaths);
      claimedTempPaths = undefined;
    } catch (error) {
      if (!retainClaimedTempDir) {
        await this.safeCleanupClaimedTempDir(claimedTempPaths);
      }
      throw toInstallError(error);
    }
  }

  private async matchesInstalledTarget(targetPath: string): Promise<boolean> {
    const existing = await this.fileDriver.statIfPresent(targetPath);
    if (existing === undefined || !existing.isFile || existing.size !== this.expectedByteLength) {
      return false;
    }
    try {
      const digest: string = await this.fileDriver.hash(targetPath, HASH_ALGORITHM);
      return digest.toLowerCase() === this.expectedSha256Digest;
    } catch (_) {
      return false;
    }
  }

  private async verifyPackagedBytes(bytes: Uint8Array): Promise<void> {
    await this.runStage('resource.verify', async (): Promise<void> => {
      if (bytes.length !== this.expectedByteLength) {
        throw new Error('Packaged geodata size mismatch.');
      }
    });
  }

  private async claimTempDir(): Promise<ClaimedTempPaths> {
    for (let attempt: number = 0; attempt < MAX_TEMP_DIR_ATTEMPTS; attempt += 1) {
      const tempId: string = this.createTempId();
      if (!SAFE_TEMP_ID_PATTERN.test(tempId)) {
        this.diagnostics.report('temp.id', UNKNOWN_DIAGNOSTIC_CODE);
        throw new HarmonyGeodataInstallError();
      }
      const claimed = new ClaimedTempPaths(`${this.filesDir}/${TEMP_FILE_PREFIX}${tempId}`);
      try {
        await this.fileDriver.mkdir(claimed.rootPath, false);
        return claimed;
      } catch (error) {
        const existing = await this.inspectClaimCollision(claimed.rootPath, error as Object | undefined);
        if (existing) {
          continue;
        }
        throw error as Error;
      }
    }
    this.diagnostics.report('claim.retry', UNKNOWN_DIAGNOSTIC_CODE);
    throw new HarmonyGeodataInstallError();
  }

  private async requireExpectedTarget(targetPath: string): Promise<void> {
    const existing = await this.fileDriver.statIfPresent(targetPath);
    if (existing === undefined || !existing.isFile || existing.size !== this.expectedByteLength) {
      throw new Error('Installed geodata verification failed.');
    }
    const digest: string = await this.fileDriver.hash(targetPath, HASH_ALGORITHM);
    if (digest.toLowerCase() !== this.expectedSha256Digest) {
      throw new Error('Installed geodata digest mismatch.');
    }
  }

  private async runStage<T>(stage: string, block: () => Promise<T>): Promise<T> {
    try {
      return await block();
    } catch (error) {
      this.diagnostics.report(stage, toDiagnosticCode(error as Object | undefined));
      throw error as Error;
    }
  }

  private async inspectClaimCollision(path: string, mkdirError: Object | undefined): Promise<boolean> {
    try {
      const existing = await this.fileDriver.statIfPresent(path);
      return existing?.isDirectory === true;
    } catch (statError) {
      this.diagnostics.report('claim.stat', toDiagnosticCode(statError as Object | undefined));
      throw mkdirError as Error;
    }
  }

  private async captureExistingTargetSnapshot(targetPath: string): Promise<ExistingTargetSnapshot | undefined> {
    const existing = await this.fileDriver.statIfPresent(targetPath);
    if (existing === undefined) {
      return undefined;
    }
    if (!existing.isFile) {
      throw new Error('Installed geodata target was invalid.');
    }
    const digest: string = await this.fileDriver.hash(targetPath, HASH_ALGORITHM);
    return new ExistingTargetSnapshot(existing.size, digest.toLowerCase());
  }

  private async writeCandidateFile(candidatePath: string, bytes: Uint8Array): Promise<void> {
    let handle: FileToken | undefined = undefined;
    try {
      handle = await this.runStage('candidate.open', async (): Promise<FileToken> => {
        return await this.fileDriver.open(candidatePath, FILE_OPEN_MODE_WRITE_ONLY | FILE_OPEN_MODE_CREATE);
      });
      await this.runStage('candidate.write', async (): Promise<void> => {
        await writeFully(this.fileDriver, handle!.fd, bytes);
      });
      await this.runStage('candidate.close', async (): Promise<void> => {
        await this.fileDriver.close(handle!);
      });
      handle = undefined;
    } finally {
      await this.safeClose(handle);
    }
  }

  private async copyTargetIntoBackup(targetPath: string, backupPath: string, expectedSize: number): Promise<void> {
    let sourceHandle: FileToken | undefined = undefined;
    let backupHandle: FileToken | undefined = undefined;
    try {
      sourceHandle = await this.runStage('backup.source.open', async (): Promise<FileToken> => {
        return await this.fileDriver.open(targetPath, FILE_OPEN_MODE_READ_ONLY);
      });
      backupHandle = await this.runStage('backup.open', async (): Promise<FileToken> => {
        return await this.fileDriver.open(backupPath, FILE_OPEN_MODE_WRITE_ONLY | FILE_OPEN_MODE_CREATE);
      });
      await this.runStage('backup.write', async (): Promise<void> => {
        await copyFileContents(this.fileDriver, sourceHandle!.fd, backupHandle!.fd, expectedSize);
      });
      await this.runStage('backup.source.close', async (): Promise<void> => {
        await this.fileDriver.close(sourceHandle!);
      });
      sourceHandle = undefined;
      await this.runStage('backup.close', async (): Promise<void> => {
        await this.fileDriver.close(backupHandle!);
      });
      backupHandle = undefined;
    } finally {
      await this.safeClose(sourceHandle);
      await this.safeClose(backupHandle);
    }
  }

  private async safeClose(handle?: FileToken): Promise<void> {
    if (handle === undefined) {
      return;
    }
    try {
      await this.fileDriver.close(handle);
    } catch (_) {
    }
  }

  private async safeCleanupClaimedTempDir(claimedTempPaths?: ClaimedTempPaths): Promise<void> {
    if (claimedTempPaths === undefined) {
      return;
    }
    try {
      await this.safeRemoveFile(claimedTempPaths.candidatePath);
      await this.safeRemoveFile(claimedTempPaths.backupPath);
      const existingDir = await this.fileDriver.statIfPresent(claimedTempPaths.rootPath);
      if (existingDir?.isDirectory === true) {
        const names: string[] = await this.fileDriver.list(claimedTempPaths.rootPath);
        for (let index: number = 0; index < names.length; index += 1) {
          await this.safeRemoveFile(`${claimedTempPaths.rootPath}/${names[index]}`);
        }
        await this.fileDriver.rmdir(claimedTempPaths.rootPath);
      }
    } catch (_) {
    }
  }

  private async safeRemoveUnexpectedTarget(targetPath: string): Promise<void> {
    try {
      const existing = await this.fileDriver.statIfPresent(targetPath);
      if (existing?.isFile === true) {
        await this.fileDriver.unlink(targetPath);
      }
    } catch (_) {
    }
  }

  private async safeRemoveFile(path: string): Promise<void> {
    try {
      const existing = await this.fileDriver.statIfPresent(path);
      if (existing?.isFile === true) {
        await this.fileDriver.unlink(path);
      }
    } catch (_) {
    }
  }
}

function normalizeAbsoluteSandboxRoot(rawPath: string): string {
  const normalized: string = rawPath.trim().replace(/\\/g, '/').replace(/\/+$/u, '');
  if (!normalized.startsWith('/')) {
    throw new Error('Sandbox root must be absolute.');
  }
  if (normalized.length === 0) {
    throw new Error('Sandbox root must be absolute.');
  }
  return normalized;
}

async function writeFully(fileDriver: FileDriver, fd: number, bytes: Uint8Array): Promise<void> {
  let totalWritten: number = 0;
  while (totalWritten < bytes.length) {
    const chunk: Uint8Array = totalWritten === 0
      ? bytes
      : bytes.slice(totalWritten);
    const wroteNow: number = await fileDriver.write(fd, chunk.buffer, {
      offset: 0,
      length: chunk.length
    });
    if (wroteNow <= 0 || wroteNow > chunk.length) {
      throw new Error('Packaged geodata temp write failed.');
    }
    totalWritten += wroteNow;
  }
}

async function copyFileContents(
  fileDriver: FileDriver,
  sourceFd: number,
  targetFd: number,
  expectedSize: number
): Promise<void> {
  let totalCopied: number = 0;
  while (totalCopied < expectedSize) {
    const remaining: number = expectedSize - totalCopied;
    const chunkSize: number = remaining < COPY_BUFFER_SIZE ? remaining : COPY_BUFFER_SIZE;
    const buffer = new ArrayBuffer(chunkSize);
    const readNow: number = await fileDriver.read(sourceFd, buffer, {
      offset: 0,
      length: chunkSize
    });
    if (readNow <= 0 || readNow > chunkSize) {
      throw new Error('Backup geodata read failed.');
    }
    let totalWritten: number = 0;
    while (totalWritten < readNow) {
      const slice: ArrayBuffer = totalWritten === 0 && readNow === buffer.byteLength
        ? buffer
        : buffer.slice(totalWritten, readNow);
      const wroteNow: number = await fileDriver.write(targetFd, slice, {
        offset: 0,
        length: readNow - totalWritten
      });
      if (wroteNow <= 0 || wroteNow > readNow - totalWritten) {
        throw new Error('Backup geodata write failed.');
      }
      totalWritten += wroteNow;
    }
    totalCopied += readNow;
  }
  const trailing = new ArrayBuffer(1);
  const trailingRead: number = await fileDriver.read(sourceFd, trailing, {
    offset: 0,
    length: 1
  });
  if (trailingRead !== 0) {
    throw new Error('Backup geodata size changed during copy.');
  }
}

function toDiagnosticCode(error: Object | undefined): number {
  const record = error as DiagnosticCodeCarrier;
  return typeof record?.code === 'number' ? record.code : UNKNOWN_DIAGNOSTIC_CODE;
}

function toInstallError(error: Object | undefined): HarmonyGeodataInstallError {
  if (error instanceof HarmonyGeodataInstallError) {
    return error;
  }
  return new HarmonyGeodataInstallError();
}
