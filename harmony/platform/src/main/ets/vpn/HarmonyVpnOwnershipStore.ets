import { fileIo } from '@kit.CoreFileKit';
import {
  decodeVpnRpcUtf8,
  encodeVpnRpcUtf8,
  OwnershipStoreCorruptError,
  type VpnPlatformOwnershipPhase,
  type VpnPlatformOwnershipRecord,
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
const ACTIVE_VPN_TEMP_FILE_SUFFIX: string = '.tmp';
const ACTIVE_VPN_CLAIM_FILE_NAME: string = 'active-platform-vpn-v1.claim.json';

interface OwnershipStoreDocument {
  version: number;
  phase: VpnPlatformOwnershipPhase;
  vpnId: string;
}

interface OwnershipStoreJsonShape {
  version?: Object;
  phase?: Object;
  vpnId?: Object;
}

export interface HarmonyVpnOwnershipStoreDependencies {
  fileDriver: FileDriver;
  filesDir: string;
  fsync?: (fd: number) => void;
  createOperationId?: () => string;
}

class OwnershipStoreDocumentRecord implements OwnershipStoreDocument, VpnPlatformOwnershipRecord {
  readonly version: number;
  readonly phase: VpnPlatformOwnershipPhase;
  readonly vpnId: string;

  constructor(version: number, phase: VpnPlatformOwnershipPhase, vpnId: string) {
    this.version = version;
    this.phase = phase;
    this.vpnId = vpnId;
  }
}

export class HarmonyVpnOwnershipStore implements VpnPlatformOwnershipStorePort {
  private readonly fileDriver: FileDriver;
  private readonly filesDir: string;
  private readonly directoryPath: string;
  private readonly targetPath: string;
  private readonly claimPath: string;
  private readonly fsync: (fd: number) => void;
  private readonly createOperationId: () => string;

  constructor(dependencies: HarmonyVpnOwnershipStoreDependencies) {
    this.fileDriver = dependencies.fileDriver;
    this.filesDir = normalizeAbsoluteSandboxPath(dependencies.filesDir, 'VPN ownership filesDir');
    this.directoryPath = activePlatformVpnOwnershipDirectory(this.filesDir);
    this.targetPath = activePlatformVpnOwnershipPath(this.filesDir);
    this.claimPath = activePlatformVpnOwnershipClaimPath(this.filesDir);
    this.fsync = dependencies.fsync ?? ((fd: number): void => {
      fileIo.fsyncSync(fd);
    });
    this.createOperationId = dependencies.createOperationId ?? (() => {
      return `${Date.now()}-${Math.floor(Math.random() * 1000000000)}`;
    });
  }

  async read(): Promise<VpnPlatformOwnershipRecord | null> {
    await this.reconcileClaimPath();
    return await this.readDocumentIfPresent(this.targetPath);
  }

  async write(ownership: VpnPlatformOwnershipRecord): Promise<void> {
    const safeOwnership: OwnershipStoreDocumentRecord = normalizeOwnershipRecord(ownership, false);
    const contents: Uint8Array = serializeDocument(safeOwnership);
    const temporaryPath: string = activePlatformVpnOwnershipTemporaryPath(
      this.filesDir,
      normalizeOperationId(this.createOperationId())
    );
    await this.reconcileClaimPath();
    await this.fileDriver.mkdir(this.directoryPath, true);

    let token: FileToken | undefined = undefined;
    let pendingFailure: Error | undefined = undefined;
    try {
      token = await this.fileDriver.open(
        temporaryPath,
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
      await this.cleanupTemporary(temporaryPath);
      throw pendingFailure;
    }
    try {
      await this.fileDriver.renameReplace(temporaryPath, this.targetPath);
    } catch (error) {
      await this.cleanupTemporary(temporaryPath);
      throw coerceStoreWriteFailure(error);
    }
  }

  async clearExpected(ownership: VpnPlatformOwnershipRecord): Promise<void> {
    const expectedOwnership: OwnershipStoreDocumentRecord = normalizeOwnershipRecord(ownership, false);
    await this.reconcileClaimPath();
    const claimed: boolean = await this.claimCurrentTarget();
    if (!claimed) {
      return;
    }
    const claimedOwnership: OwnershipStoreDocumentRecord | null = await this.readDocumentIfPresent(this.claimPath);
    if (claimedOwnership === null) {
      return;
    }
    if (sameOwnership(claimedOwnership, expectedOwnership)) {
      await this.fileDriver.unlink(this.claimPath);
      return;
    }
    await this.restoreOrDiscardClaim();
  }

  private async readDocumentIfPresent(path: string): Promise<OwnershipStoreDocumentRecord | null> {
    const stat: FileStat | undefined = await this.safeStatIfPresent(path);
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

  private async cleanupTemporary(path: string): Promise<void> {
    try {
      const stat: FileStat | undefined = await this.fileDriver.statIfPresent(path);
      if (stat !== undefined && stat.isFile) {
        await this.fileDriver.unlink(path);
      }
    } catch (_) {
    }
  }
}

export function createHarmonyVpnOwnershipStore(
  filesDir: string,
  createOperationId?: () => string
): HarmonyVpnOwnershipStore {
  return new HarmonyVpnOwnershipStore({
    fileDriver: new HarmonyFileDriver(),
    filesDir,
    createOperationId
  });
}

export function activePlatformVpnOwnershipDirectory(filesDir: string): string {
  return joinAbsoluteSandboxPath(normalizeAbsoluteSandboxPath(filesDir, 'VPN ownership filesDir'), VPN_DIRECTORY);
}

export function activePlatformVpnOwnershipPath(filesDir: string): string {
  return joinAbsoluteSandboxPath(activePlatformVpnOwnershipDirectory(filesDir), ACTIVE_VPN_FILE_NAME);
}

function activePlatformVpnOwnershipTemporaryPath(filesDir: string, operationId: string): string {
  return joinAbsoluteSandboxPath(
    activePlatformVpnOwnershipDirectory(filesDir),
    `active-platform-vpn-v1.${operationId}${ACTIVE_VPN_TEMP_FILE_SUFFIX}`
  );
}

function activePlatformVpnOwnershipClaimPath(filesDir: string): string {
  return joinAbsoluteSandboxPath(activePlatformVpnOwnershipDirectory(filesDir), ACTIVE_VPN_CLAIM_FILE_NAME);
}

function serializeDocument(ownership: OwnershipStoreDocumentRecord): Uint8Array {
  return encodeVpnRpcUtf8(
    JSON.stringify(new OwnershipStoreDocumentRecord(STORE_VERSION, ownership.phase, ownership.vpnId)),
    MAX_DOCUMENT_BYTES
  );
}

function parseDocument(rawText: string): OwnershipStoreDocumentRecord {
  if (
    countFieldOccurrences(rawText, 'version') !== 1 ||
    countFieldOccurrences(rawText, 'phase') !== 1 ||
    countFieldOccurrences(rawText, 'vpnId') !== 1
  ) {
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
  if (keys.length !== 3 || !keys.includes('version') || !keys.includes('phase') || !keys.includes('vpnId')) {
    throw new OwnershipStoreCorruptError();
  }
  if (record.version !== STORE_VERSION) {
    throw new OwnershipStoreCorruptError();
  }
  const phase: VpnPlatformOwnershipPhase = normalizeOwnershipPhase(record.phase, true);
  const vpnId: string = normalizePersistentVpnId(record.vpnId, true);
  return new OwnershipStoreDocumentRecord(STORE_VERSION, phase, vpnId);
}

function normalizeOwnershipRecord(
  ownership: VpnPlatformOwnershipRecord,
  failClosed: boolean
): OwnershipStoreDocumentRecord {
  const phase: VpnPlatformOwnershipPhase = normalizeOwnershipPhase(ownership.phase, failClosed);
  const vpnId: string = normalizePersistentVpnId(ownership.vpnId, failClosed);
  return new OwnershipStoreDocumentRecord(STORE_VERSION, phase, vpnId);
}

function sameOwnership(left: OwnershipStoreDocumentRecord, right: OwnershipStoreDocumentRecord): boolean {
  return left.phase === right.phase && left.vpnId === right.vpnId;
}

function countFieldOccurrences(rawText: string, fieldName: string): number {
  const pattern: RegExp = new RegExp(`"${fieldName}"\\s*:`, 'gu');
  return rawText.match(pattern)?.length ?? 0;
}

function normalizeOwnershipPhase(value: Object | undefined, failClosed: boolean): VpnPlatformOwnershipPhase {
  if (value === 'PREPARED' || value === 'ACTIVE' || value === 'RELEASED') {
    return value as VpnPlatformOwnershipPhase;
  }
  if (failClosed) {
    throw new OwnershipStoreCorruptError();
  }
  throw new Error('VPN ownership phase is invalid.');
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

function normalizeOperationId(rawValue: string): string {
  if (!/^[A-Za-z0-9_-]+$/u.test(rawValue)) {
    throw new Error('VPN ownership operation id is invalid.');
  }
  return rawValue;
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
