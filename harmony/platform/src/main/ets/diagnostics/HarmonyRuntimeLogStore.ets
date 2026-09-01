import {
  cloneRuntimeLogEntry,
  createRuntimeLogEntry,
  decodeVpnRpcUtf8,
  encodeVpnRpcUtf8,
  formatRuntimeLogsAsText,
  type RuntimeLogEntry,
  type RuntimeLogStorePort
} from '@cmfa/shared';
import type { FileDriver, FileStat, FileToken } from '../files/FileDriver';
import {
  FILE_OPEN_MODE_APPEND,
  FILE_OPEN_MODE_CREATE,
  FILE_OPEN_MODE_READ_ONLY,
  FILE_OPEN_MODE_TRUNC,
  FILE_OPEN_MODE_WRITE_ONLY
} from '../files/FileDriver';
import { HarmonyFileDriver } from '../files/HarmonyFileDriver';

const DEFAULT_MAX_FILE_BYTES: number = 512 * 1024;
const DEFAULT_READ_LIMIT: number = 500;
const MAX_READ_LIMIT: number = 1000;
const READ_CHUNK_BYTES: number = 64 * 1024;

export interface HarmonyRuntimeLogStoreDependencies {
  fileDriver: FileDriver;
  filesDir: string;
  maxFileBytes?: number;
}

export function runtimeLogCurrentPath(filesDir: string): string {
  return `${normalizeFilesDir(filesDir)}/diagnostics/runtime-logs.jsonl`;
}

export function runtimeLogPreviousPath(filesDir: string): string {
  return `${normalizeFilesDir(filesDir)}/diagnostics/runtime-logs.previous.jsonl`;
}

export function runtimeLogClearRequestPath(filesDir: string): string {
  return `${normalizeFilesDir(filesDir)}/diagnostics/runtime-logs.clear-request`;
}

export class HarmonyRuntimeLogStore implements RuntimeLogStorePort {
  private readonly fileDriver: FileDriver;
  private readonly filesDir: string;
  private readonly directoryPath: string;
  private readonly currentPath: string;
  private readonly previousPath: string;
  private readonly clearRequestPath: string;
  private readonly maxFileBytes: number;
  private tail: Promise<void> = Promise.resolve();

  constructor(dependencies: HarmonyRuntimeLogStoreDependencies) {
    this.fileDriver = dependencies.fileDriver;
    this.filesDir = normalizeFilesDir(dependencies.filesDir);
    this.directoryPath = `${this.filesDir}/diagnostics`;
    this.currentPath = runtimeLogCurrentPath(this.filesDir);
    this.previousPath = runtimeLogPreviousPath(this.filesDir);
    this.clearRequestPath = runtimeLogClearRequestPath(this.filesDir);
    this.maxFileBytes = normalizeMaxFileBytes(dependencies.maxFileBytes);
  }

  append(entry: RuntimeLogEntry): Promise<void> {
    const safeEntry: RuntimeLogEntry = cloneRuntimeLogEntry(entry);
    const previousTail: Promise<void> = this.tail;
    const operation: Promise<void> = previousTail.catch((): void => {
    }).then(async (): Promise<void> => {
      await this.appendInternal(safeEntry);
    });
    this.tail = operation;
    return operation;
  }

  async read(limit: number = DEFAULT_READ_LIMIT): Promise<RuntimeLogEntry[]> {
    await this.drain();
    if (await this.fileDriver.statIfPresent(this.clearRequestPath) !== undefined) {
      return [];
    }
    const normalizedLimit: number = normalizeReadLimit(limit);
    const entries: RuntimeLogEntry[] = [];
    appendEntries(entries, await this.readFile(this.previousPath));
    appendEntries(entries, await this.readFile(this.currentPath));
    if (entries.length <= normalizedLimit) {
      return entries;
    }
    return entries.slice(entries.length - normalizedLimit);
  }

  async clear(): Promise<void> {
    await this.drain();
    await this.fileDriver.mkdir(this.directoryPath, true);
    const marker: FileToken = await this.fileDriver.open(
      this.clearRequestPath,
      FILE_OPEN_MODE_WRITE_ONLY | FILE_OPEN_MODE_CREATE | FILE_OPEN_MODE_TRUNC
    );
    try {
      await this.writeAll(marker.fd, encodeVpnRpcUtf8('clear\n'));
    } finally {
      await this.fileDriver.close(marker);
    }
  }

  async exportText(): Promise<string> {
    return formatRuntimeLogsAsText(await this.read(MAX_READ_LIMIT));
  }

  async drain(): Promise<void> {
    try {
      await this.tail;
    } catch (_) {
    }
  }

  private async appendInternal(entry: RuntimeLogEntry): Promise<void> {
    await this.fileDriver.mkdir(this.directoryPath, true);
    await this.consumeClearRequest();
    const currentStat: FileStat | undefined = await this.fileDriver.statIfPresent(this.currentPath);
    if (currentStat !== undefined && currentStat.isFile && currentStat.size >= this.maxFileBytes) {
      await this.fileDriver.renameReplace(this.currentPath, this.previousPath);
    }
    const line: string = encodeEntry(entry);
    const bytes: Uint8Array = encodeVpnRpcUtf8(`${line}\n`);
    const handle: FileToken = await this.fileDriver.open(
      this.currentPath,
      FILE_OPEN_MODE_WRITE_ONLY | FILE_OPEN_MODE_CREATE | FILE_OPEN_MODE_APPEND
    );
    let failure: Error | undefined = undefined;
    try {
      await this.writeAll(handle.fd, bytes);
    } catch (error) {
      failure = error instanceof Error ? error : new Error('Runtime log write failed.');
    }
    try {
      await this.fileDriver.close(handle);
    } catch (_) {
      failure = failure ?? new Error('Runtime log close failed.');
    }
    if (failure !== undefined) {
      throw failure;
    }
  }

  private async writeAll(fd: number, bytes: Uint8Array): Promise<void> {
    let offset: number = 0;
    while (offset < bytes.length) {
      const remaining: Uint8Array = bytes.slice(offset);
      const written: number = await this.fileDriver.write(fd, remaining.buffer);
      if (written <= 0 || written > remaining.length) {
        throw new Error('Runtime log write failed.');
      }
      offset += written;
    }
  }

  private async readFile(path: string): Promise<RuntimeLogEntry[]> {
    const stat: FileStat | undefined = await this.fileDriver.statIfPresent(path);
    if (stat === undefined || !stat.isFile || stat.size <= 0 || stat.size > this.maxFileBytes + 8192) {
      return [];
    }
    let handle: FileToken | undefined = undefined;
    try {
      handle = await this.fileDriver.open(path, FILE_OPEN_MODE_READ_ONLY);
      const bytes: Uint8Array = await this.readAll(handle.fd, stat.size);
      await this.fileDriver.close(handle);
      handle = undefined;
      return decodeEntries(decodeVpnRpcUtf8(bytes));
    } catch (_) {
      if (handle !== undefined) {
        try {
          await this.fileDriver.close(handle);
        } catch (_) {
        }
      }
      return [];
    }
  }

  private async readAll(fd: number, expectedSize: number): Promise<Uint8Array> {
    const output: Uint8Array = new Uint8Array(expectedSize);
    let offset: number = 0;
    while (offset < expectedSize) {
      const chunkLength: number = Math.min(READ_CHUNK_BYTES, expectedSize - offset);
      const buffer: ArrayBuffer = new ArrayBuffer(chunkLength);
      const count: number = await this.fileDriver.read(fd, buffer);
      if (count <= 0) {
        break;
      }
      output.set(new Uint8Array(buffer).slice(0, count), offset);
      offset += count;
    }
    return output.slice(0, offset);
  }

  private async removeIfPresent(path: string): Promise<void> {
    if (await this.fileDriver.statIfPresent(path) === undefined) {
      return;
    }
    await this.fileDriver.unlink(path);
  }

  private async consumeClearRequest(): Promise<void> {
    if (await this.fileDriver.statIfPresent(this.clearRequestPath) === undefined) {
      return;
    }
    await this.removeIfPresent(this.previousPath);
    await this.removeIfPresent(this.currentPath);
    await this.removeIfPresent(this.clearRequestPath);
  }
}

export function createHarmonyRuntimeLogStore(filesDir: string): HarmonyRuntimeLogStore {
  return new HarmonyRuntimeLogStore({
    fileDriver: new HarmonyFileDriver(),
    filesDir
  });
}

function normalizeFilesDir(filesDir: string): string {
  const normalized: string = filesDir.trim().replace(/\/+$/u, '');
  if (!normalized.startsWith('/') || normalized.length <= 1) {
    throw new Error('Runtime log filesDir must be an absolute sandbox path.');
  }
  return normalized;
}

function normalizeMaxFileBytes(value: number | undefined): number {
  const resolved: number = value ?? DEFAULT_MAX_FILE_BYTES;
  if (!Number.isSafeInteger(resolved) || resolved < 100 || resolved > 4 * 1024 * 1024) {
    throw new Error('Runtime log maxFileBytes is invalid.');
  }
  return resolved;
}

function normalizeReadLimit(limit: number): number {
  if (!Number.isSafeInteger(limit) || limit <= 0) {
    throw new Error('Runtime log read limit is invalid.');
  }
  return Math.min(limit, MAX_READ_LIMIT);
}

function encodeEntry(entry: RuntimeLogEntry): string {
  return `{"timestamp":${JSON.stringify(entry.timestamp)},"level":${JSON.stringify(entry.level)},"message":${JSON.stringify(entry.message)}}`;
}

function decodeEntries(text: string): RuntimeLogEntry[] {
  const entries: RuntimeLogEntry[] = [];
  const lines: string[] = text.replace(/\r\n/gu, '\n').replace(/\r/gu, '\n').split('\n');
  for (let index: number = 0; index < lines.length; index += 1) {
    const entry: RuntimeLogEntry | undefined = decodeEntry(lines[index]);
    if (entry !== undefined) {
      entries.push(entry);
    }
  }
  return entries;
}

function decodeEntry(line: string): RuntimeLogEntry | undefined {
  if (line.trim().length === 0) {
    return undefined;
  }
  try {
    const parsed: Object = JSON.parse(line) as Object;
    if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') {
      return undefined;
    }
    const record: Record<string, Object> = parsed as Record<string, Object>;
    if (typeof record.timestamp !== 'string' || typeof record.level !== 'string' || typeof record.message !== 'string') {
      return undefined;
    }
    return createRuntimeLogEntry(record.timestamp, record.level, record.message);
  } catch (_) {
    return undefined;
  }
}

function appendEntries(target: RuntimeLogEntry[], source: RuntimeLogEntry[]): void {
  for (let index: number = 0; index < source.length; index += 1) {
    target.push(source[index]);
  }
}
