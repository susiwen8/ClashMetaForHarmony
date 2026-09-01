import { fileIo } from '@kit.CoreFileKit';
import {
  decodeVpnRpcUtf8,
  encodeVpnRpcUtf8,
  OwnershipStoreCorruptError,
  type VpnPlatformOwnershipStorePort
} from '@cmfa/shared';
import type { FileDriver, FileStat, FileToken } from '../files/FileDriver';
import {
  FILE_OPEN_MODE_CREATE,
  FILE_OPEN_MODE_READ_ONLY,
  FILE_OPEN_MODE_TRUNC,
  FILE_OPEN_MODE_WRITE_ONLY
} from '../files/FileDriver';
import { HarmonyFileDriver } from '../files/HarmonyFileDriver';

const STORE_VERSION: number = 1;
const MAX_DOCUMENT_BYTES: number = 256;
const VPN_DIRECTORY: string = 'vpn';
const ACTIVE_VPN_FILE_NAME: string = 'active-platform-vpn-v1.json';
const ACTIVE_VPN_TEMP_FILE_NAME: string = 'active-platform-vpn-v1.json.tmp';
const ACTIVE_VPN_CLAIM_FILE_NAME: string = 'active-platform-vpn-v1.claim.json';

interface OwnershipStoreDocument {
  version: number;
  vpnId: string;
}

interface OwnershipStoreJsonShape {
  version?: Object;
  vpnId?: Object;
}

export interface HarmonyVpnOwnershipStoreDependencies {
  fileDriver: FileDriver;
  filesDir: string;
  fsync?: (fd: number) => void;
}

class OwnershipStoreDocumentRecord implements OwnershipStoreDocument {
  readonly version: number;
  readonly vpnId: string;

  constructor(version: number, vpnId: string) {
    this.version = version;
    this.vpnId = vpnId;
  }
}

export class HarmonyVpnOwnershipStore implements VpnPlatformOwnershipStorePort {
  private readonly fileDriver: FileDriver;
  private readonly filesDir: string;
  private readonly directoryPath: string;
  private readonly targetPath: string;
  private readonly temporaryPath: string;
  private readonly claimPath: string;
  private readonly fsync: (fd: number) => void;

  constructor(dependencies: HarmonyVpnOwnershipStoreDependencies) {
    this.fileDriver = dependencies.fileDriver;
    this.filesDir = normalizeAbsoluteSandboxPath(dependencies.filesDir, 'VPN ownership filesDir');
    this.directoryPath = activePlatformVpnOwnershipDirectory(this.filesDir);
    this.targetPath = activePlatformVpnOwnershipPath(this.filesDir);
    this.temporaryPath = activePlatformVpnOwnershipTemporaryPath(this.filesDir);
    this.claimPath = activePlatformVpnOwnershipClaimPath(this.filesDir);
    this.fsync = dependencies.fsync ?? ((fd: number): void => {
      fileIo.fsyncSync(fd);
    });
  }

  async read(): Promise<string | null> {
    await this.reconcileClaimPath();
    const document: OwnershipStoreDocument | null = await this.readDocumentIfPresent(this.targetPath);
    return document?.vpnId ?? null;
  }

  async write(vpnId: string): Promise<void> {
    const safeVpnId: string = normalizePersistentVpnId(vpnId, false);
    const contents: Uint8Array = serializeDocument(safeVpnId);
    await this.reconcileClaimPath();
    await this.fileDriver.mkdir(this.directoryPath, true);

    let token: FileToken | undefined = undefined;
    let pendingFailure: Error | undefined = undefined;
    try {
      token = await this.fileDriver.open(
        this.temporaryPath,
        FILE_OPEN_MODE_CREATE | FILE_OPEN_MODE_WRITE_ONLY | FILE_OPEN_MODE_TRUNC
      );
      await writeAll(this.fileDriver, token.fd, contents);
      this.fsync(token.fd);
    } catch (error) {
      pendingFailure = coerceStoreWriteFailure(error);
    }
    if (token !== undefined) {
      try {
        await this.fileDriver.close(token);
      } catch (_) {
        pendingFailure = pendingFailure ?? new Error('VPN ownership store close failed.');
      }
    }
    if (pendingFailure !== undefined) {
      await this.cleanupTemporary();
      throw pendingFailure;
    }
    try {
      await this.fileDriver.renameReplace(this.temporaryPath, this.targetPath);
    } catch (error) {
      await this.cleanupTemporary();
      throw coerceStoreWriteFailure(error);
    }
  }

  async clearExpected(vpnId: string): Promise<void> {
    const expectedVpnId: string = normalizePersistentVpnId(vpnId, false);
    await this.reconcileClaimPath();
    const claimed: boolean = await this.claimCurrentTarget();
    if (!claimed) {
      return;
    }
    const document: OwnershipStoreDocument | null = await this.readDocumentIfPresent(this.claimPath);
    if (document === null) {
      return;
    }
    if (document.vpnId === expectedVpnId) {
      await this.fileDriver.unlink(this.claimPath);
      return;
    }
    await this.restoreOrDiscardClaim();
  }

  private async readDocumentIfPresent(path: string): Promise<OwnershipStoreDocument | null> {
    let stat: FileStat | undefined = undefined;
    try {
      stat = await this.fileDriver.statIfPresent(path);
    } catch (_) {
      throw new Error('VPN ownership store read failed.');
    }
    if (stat === undefined) {
      return null;
    }
    if (!stat.isFile || stat.size <= 0 || stat.size > MAX_DOCUMENT_BYTES) {
      throw new OwnershipStoreCorruptError();
    }
    const text: string = await this.readText(path, stat.size);
    return parseDocument(text);
  }

  private async readText(path: string, size: number): Promise<string> {
    let token: FileToken | undefined = undefined;
    let pendingFailure: Error | undefined = undefined;
    let decoded: string | undefined = undefined;
    try {
      token = await this.fileDriver.open(path, FILE_OPEN_MODE_READ_ONLY);
      const bytes: Uint8Array = await readAll(this.fileDriver, token.fd, size);
      if (bytes.length !== size) {
        throw new OwnershipStoreCorruptError();
      }
      decoded = decodeVpnRpcUtf8(bytes, MAX_DOCUMENT_BYTES);
    } catch (error) {
      pendingFailure = error instanceof OwnershipStoreCorruptError
        ? error
        : new Error('VPN ownership store read failed.');
    }
    if (token !== undefined) {
      try {
        await this.fileDriver.close(token);
      } catch (_) {
        pendingFailure = pendingFailure ?? new Error('VPN ownership store read failed.');
      }
    }
    if (pendingFailure !== undefined) {
      throw pendingFailure;
    }
    return decoded ?? '';
  }

  private async reconcileClaimPath(): Promise<void> {
    const claimStat: FileStat | undefined = await this.safeStatIfPresent(this.claimPath);
    if (claimStat === undefined) {
      return;
    }
    await this.readDocumentIfPresent(this.claimPath);
    const targetStat: FileStat | undefined = await this.safeStatIfPresent(this.targetPath);
    if (targetStat === undefined) {
      try {
        await this.fileDriver.renameNoOverwrite(this.claimPath, this.targetPath);
        return;
      } catch (_) {
        const targetAfterRace: FileStat | undefined = await this.safeStatIfPresent(this.targetPath);
        if (targetAfterRace === undefined) {
          throw new Error('VPN ownership store claim recovery failed.');
        }
      }
    }
    await this.readDocumentIfPresent(this.targetPath);
    await this.fileDriver.unlink(this.claimPath);
  }

  private async claimCurrentTarget(): Promise<boolean> {
    for (let attempt: number = 0; attempt < 2; attempt += 1) {
      try {
        await this.fileDriver.renameNoOverwrite(this.targetPath, this.claimPath);
        return true;
      } catch (_) {
        const targetStat: FileStat | undefined = await this.safeStatIfPresent(this.targetPath);
        const claimStat: FileStat | undefined = await this.safeStatIfPresent(this.claimPath);
        if (targetStat === undefined && claimStat === undefined) {
          return false;
        }
        if (claimStat !== undefined) {
          await this.reconcileClaimPath();
          continue;
        }
        throw new Error('VPN ownership store clear failed.');
      }
    }
    throw new Error('VPN ownership store clear failed.');
  }

  private async restoreOrDiscardClaim(): Promise<void> {
    const targetStat: FileStat | undefined = await this.safeStatIfPresent(this.targetPath);
    if (targetStat === undefined) {
      try {
        await this.fileDriver.renameNoOverwrite(this.claimPath, this.targetPath);
        return;
      } catch (_) {
        const targetAfterRace: FileStat | undefined = await this.safeStatIfPresent(this.targetPath);
        if (targetAfterRace === undefined) {
          throw new Error('VPN ownership store clear failed.');
        }
      }
    }
    await this.readDocumentIfPresent(this.targetPath);
    await this.fileDriver.unlink(this.claimPath);
  }

  private async safeStatIfPresent(path: string): Promise<FileStat | undefined> {
    try {
      return await this.fileDriver.statIfPresent(path);
    } catch (_) {
      throw new Error('VPN ownership store read failed.');
    }
  }

  private async cleanupTemporary(): Promise<void> {
    try {
      const stat: FileStat | undefined = await this.fileDriver.statIfPresent(this.temporaryPath);
      if (stat !== undefined && stat.isFile) {
        await this.fileDriver.unlink(this.temporaryPath);
      }
    } catch (_) {
    }
  }
}

export function createHarmonyVpnOwnershipStore(filesDir: string): HarmonyVpnOwnershipStore {
  return new HarmonyVpnOwnershipStore({
    fileDriver: new HarmonyFileDriver(),
    filesDir
  });
}

export function activePlatformVpnOwnershipDirectory(filesDir: string): string {
  return joinAbsoluteSandboxPath(normalizeAbsoluteSandboxPath(filesDir, 'VPN ownership filesDir'), VPN_DIRECTORY);
}

export function activePlatformVpnOwnershipPath(filesDir: string): string {
  return joinAbsoluteSandboxPath(activePlatformVpnOwnershipDirectory(filesDir), ACTIVE_VPN_FILE_NAME);
}

function activePlatformVpnOwnershipTemporaryPath(filesDir: string): string {
  return joinAbsoluteSandboxPath(activePlatformVpnOwnershipDirectory(filesDir), ACTIVE_VPN_TEMP_FILE_NAME);
}

function activePlatformVpnOwnershipClaimPath(filesDir: string): string {
  return joinAbsoluteSandboxPath(activePlatformVpnOwnershipDirectory(filesDir), ACTIVE_VPN_CLAIM_FILE_NAME);
}

function serializeDocument(vpnId: string): Uint8Array {
  return encodeVpnRpcUtf8(JSON.stringify(new OwnershipStoreDocumentRecord(STORE_VERSION, vpnId)), MAX_DOCUMENT_BYTES);
}

function parseDocument(rawText: string): OwnershipStoreDocument {
  if (countFieldOccurrences(rawText, 'version') !== 1 || countFieldOccurrences(rawText, 'vpnId') !== 1) {
    throw new OwnershipStoreCorruptError();
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(rawText) as Object;
  } catch (_) {
    throw new OwnershipStoreCorruptError();
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new OwnershipStoreCorruptError();
  }
  const record: OwnershipStoreJsonShape = parsed as OwnershipStoreJsonShape;
  const keys: string[] = Object.keys(parsed as Record<string, Object>);
  if (keys.length !== 2 || !keys.includes('version') || !keys.includes('vpnId')) {
    throw new OwnershipStoreCorruptError();
  }
  if (record.version !== STORE_VERSION) {
    throw new OwnershipStoreCorruptError();
  }
  const vpnId: string = normalizePersistentVpnId(record.vpnId, true);
  return new OwnershipStoreDocumentRecord(STORE_VERSION, vpnId);
}

function countFieldOccurrences(rawText: string, fieldName: string): number {
  const pattern: RegExp = new RegExp(`"${fieldName}"\\s*:`, 'gu');
  return rawText.match(pattern)?.length ?? 0;
}

function normalizePersistentVpnId(value: Object | undefined, failClosed: boolean): string {
  if (typeof value !== 'string') {
    if (failClosed) {
      throw new OwnershipStoreCorruptError();
    }
    throw new Error('VPN ownership id is invalid.');
  }
  if (value.length === 0 || value.trim() !== value) {
    if (failClosed) {
      throw new OwnershipStoreCorruptError();
    }
    throw new Error('VPN ownership id is invalid.');
  }
  return value;
}

async function readAll(fileDriver: FileDriver, fd: number, expectedSize: number): Promise<Uint8Array> {
  const output: Uint8Array = new Uint8Array(expectedSize);
  let offset: number = 0;
  while (offset < expectedSize) {
    const remaining: number = expectedSize - offset;
    const buffer: ArrayBuffer = new ArrayBuffer(remaining);
    const count: number = await fileDriver.read(fd, buffer, { length: remaining });
    if (count <= 0 || count > remaining) {
      throw new OwnershipStoreCorruptError();
    }
    output.set(new Uint8Array(buffer).slice(0, count), offset);
    offset += count;
  }
  return output;
}

async function writeAll(fileDriver: FileDriver, fd: number, bytes: Uint8Array): Promise<void> {
  let offset: number = 0;
  while (offset < bytes.length) {
    const remaining: Uint8Array = bytes.slice(offset);
    const count: number = await fileDriver.write(fd, remaining.buffer, { length: remaining.length });
    if (count <= 0 || count > remaining.length) {
      throw new Error('VPN ownership store write failed.');
    }
    offset += count;
  }
}

function coerceStoreWriteFailure(_error: Object | undefined): Error {
  return new Error('VPN ownership store write failed.');
}

function normalizeAbsoluteSandboxPath(rawPath: string, label: string): string {
  if (rawPath.trim() !== rawPath || rawPath.length === 0 || !rawPath.startsWith('/')) {
    throw new Error(`${label} must be a canonical absolute sandbox path.`);
  }
  if (rawPath.indexOf('\\') >= 0 || rawPath.indexOf('%') >= 0 || rawPath.indexOf(':') >= 0) {
    throw new Error(`${label} must be a canonical absolute sandbox path.`);
  }
  const rawSegments: string[] = rawPath.split('/');
  const normalizedSegments: string[] = [];
  for (let index: number = 1; index < rawSegments.length; index += 1) {
    const segment: string = rawSegments[index];
    if (!isCanonicalPathSegment(segment)) {
      throw new Error(`${label} must be a canonical absolute sandbox path.`);
    }
    normalizedSegments.push(segment);
  }
  return `/${normalizedSegments.join('/')}`;
}

function joinAbsoluteSandboxPath(base: string, child: string): string {
  if (base === '/') {
    return normalizeAbsoluteSandboxPath(`/${child}`, 'Sandbox path');
  }
  return normalizeAbsoluteSandboxPath(`${base}/${child}`, 'Sandbox path');
}

function isCanonicalPathSegment(segment: string): boolean {
  return segment.length > 0 &&
    segment !== '.' &&
    segment !== '..' &&
    !segment.includes('\\') &&
    !segment.includes('%') &&
    !segment.includes(':');
}
