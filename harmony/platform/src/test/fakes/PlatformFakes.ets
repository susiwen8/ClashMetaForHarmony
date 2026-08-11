import { createAppError, createProfile, createProfileRevision, type AppError, type Profile, type ProfileAvailability } from '@cmfa/shared';
import type { DurableProfileRow, RdbDriver, RdbTransaction } from '../../main/ets/rdb/RdbDriver';
import type { Clock, IdGenerator } from '@cmfa/shared';
import type { FileDriver } from '../../main/ets/files/FileDriver';
import {
  HUKS_SECRET_KEY_ALIAS_VERSION,
  HUKS_SECRET_NONCE_LENGTH,
  HUKS_SECRET_TAG_LENGTH,
  type HuksDriver,
  type HuksEncryptedPayload
} from '../../main/ets/secrets/HuksDriver';

class ScriptedFailure {
  readonly error: Error;

  constructor(error: Error) {
    this.error = error;
  }
}

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private readonly resolveFn: (value: T) => void;
  private readonly rejectFn: (error: Error) => void;

  constructor() {
    let resolveRef: ((value: T) => void) | undefined = undefined;
    let rejectRef: ((error: Error) => void) | undefined = undefined;
    this.promise = new Promise<T>((resolve, reject) => {
      resolveRef = resolve;
      rejectRef = reject;
    });
    this.resolveFn = (value: T) => {
      if (resolveRef !== undefined) {
        resolveRef(value);
      }
    };
    this.rejectFn = (error: Error) => {
      if (rejectRef !== undefined) {
        rejectRef(error);
      }
    };
  }

  resolve(value: T): void {
    this.resolveFn(value);
  }

  reject(error: Error): void {
    this.rejectFn(error);
  }
}

class FixtureAssertionError extends Error {
  constructor(message: string) {
    super(message);
  }
}

class PersistenceFailureShape {
  readonly stage: string;
  readonly code: string;
  readonly technicalDetail: string;

  constructor(stage: string, code: string, technicalDetail: string) {
    this.stage = stage;
    this.code = code;
    this.technicalDetail = technicalDetail;
  }
}

function cloneAppError(error: AppError | null): AppError | null {
  if (error === null) {
    return null;
  }
  return createAppError(error.stage, error.technicalDetail, {
    code: error.code,
    retryable: error.retryable,
    timestamp: error.timestamp,
    userMessageResource: error.userMessageResource
  });
}

function cloneRevisionJson(jsonText: string | null): string | null {
  if (jsonText === null) {
    return null;
  }
  return `${jsonText}`;
}

export function buildAppError(
  stage: 'IMPORT' | 'DOWNLOAD' | 'VALIDATION' | 'PERSISTENCE',
  detail: string,
  retryable: boolean,
  code?: string
): AppError {
  return createAppError(stage, detail, {
    retryable,
    code,
    timestamp: '2026-08-07T00:00:00.000Z'
  });
}

export function buildProfile(id: string, availability: ProfileAvailability, updatedAt: string, currentRevisionPath?: string): Profile {
  const currentRevision = currentRevisionPath === undefined
    ? null
    : createProfileRevision(
      currentRevisionPath,
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      128,
      '2026-08-07T00:00:00.000Z'
    );
  return createProfile({
    id,
    name: `Profile ${id}`,
    sourceKind: id.startsWith('remote-') ? 'REMOTE_URL' : 'LOCAL_FILE',
    sourceDisplay: id.startsWith('remote-') ? 'https://profiles.example.com' : `${id}.yaml`,
    sourceSecretRef: id.startsWith('remote-') ? `secret:${id}` : undefined,
    currentRevision,
    failedCandidate: null,
    availability,
    lastError: null,
    createdAt: '2026-08-07T00:00:00.000Z',
    updatedAt,
    lastSuccessfulUpdateAt: currentRevision === null ? null : '2026-08-07T00:10:00.000Z'
  });
}

export class RecordingRdbDriver implements RdbDriver {
  readonly log: string[] = [];
  readonly committedRows: Map<string, DurableProfileRow> = new Map<string, DurableProfileRow>();
  initializeCallCount: number = 0;
  private activeIdValue: string | undefined = undefined;
  private appStatePresent: boolean = true;
  private readonly scriptedFailures: Map<string, ScriptedFailure[]> = new Map<string, ScriptedFailure[]>();
  private readonly listedRows: DurableProfileRow[] = [];
  private readonly blockedInitializeStarted: DeferredValue<void>[] = [];
  private readonly blockedInitializeReleased: DeferredValue<void>[] = [];
  private lastBlockedInitializeStarted?: DeferredValue<void>;

  seedRow(row: DurableProfileRow): void {
    this.committedRows.set(row.id, cloneDurableRow(row));
  }

  seedListRows(rows: DurableProfileRow[]): void {
    this.listedRows.length = 0;
    for (let index = 0; index < rows.length; index += 1) {
      this.listedRows.push(cloneDurableRow(rows[index]));
    }
  }

  seedActiveId(activeId: string | undefined): void {
    this.activeIdValue = activeId;
  }

  seedMissingAppState(): void {
    this.appStatePresent = false;
    this.activeIdValue = undefined;
  }

  isAppStatePresent(): boolean {
    return this.appStatePresent;
  }

  blockNextInitialize(): DeferredValue<void> {
    const started = new DeferredValue<void>();
    const released = new DeferredValue<void>();
    this.blockedInitializeStarted.push(started);
    this.blockedInitializeReleased.push(released);
    this.lastBlockedInitializeStarted = started;
    return released;
  }

  nextInitializeStarted(): DeferredValue<void> {
    if (this.lastBlockedInitializeStarted !== undefined) {
      return this.lastBlockedInitializeStarted;
    }
    const started = new DeferredValue<void>();
    this.blockedInitializeStarted.push(started);
    return started;
  }

  injectFailure(operation: string, error: Error): void {
    let queue: ScriptedFailure[] | undefined = this.scriptedFailures.get(operation);
    if (queue === undefined) {
      queue = [];
      this.scriptedFailures.set(operation, queue);
    }
    queue.push(new ScriptedFailure(error));
  }

  async initialize(version: number): Promise<void> {
    this.log.push(`initialize:${version}`);
    this.initializeCallCount += 1;
    const started: DeferredValue<void> | undefined = this.blockedInitializeStarted.shift();
    started?.resolve(undefined);
    const released: DeferredValue<void> | undefined = this.blockedInitializeReleased.shift();
    if (released !== undefined) {
      await released.promise;
    }
    this.failIfScripted('initialize');
  }

  async listProfileRows(): Promise<DurableProfileRow[]> {
    this.log.push('listProfileRows');
    this.failIfScripted('listProfileRows');
    if (this.listedRows.length > 0) {
      const copy: DurableProfileRow[] = [];
      for (let index = 0; index < this.listedRows.length; index += 1) {
        copy.push(cloneDurableRow(this.listedRows[index]));
      }
      return copy;
    }

    const copy: DurableProfileRow[] = [];
    for (const row of this.committedRows.values()) {
      copy.push(cloneDurableRow(row));
    }
    return copy;
  }

  async getProfileRow(id: string): Promise<DurableProfileRow | undefined> {
    this.failIfScripted(`getProfileRow:${id}`);
    const row: DurableProfileRow | undefined = this.committedRows.get(id);
    if (row !== undefined) {
      this.log.push(`getProfileRow:${id}`);
    }
    return row === undefined ? undefined : cloneDurableRow(row);
  }

  async upsertProfileRow(row: DurableProfileRow): Promise<void> {
    this.log.push(`upsertProfileRow:${row.id}`);
    this.failIfScripted(`upsertProfileRow:${row.id}`);
    this.committedRows.set(row.id, cloneDurableRow(row));
  }

  async readActiveId(): Promise<string | undefined> {
    this.log.push('readActiveId');
    this.failIfScripted('readActiveId');
    if (!this.appStatePresent) {
      return undefined;
    }
    return this.activeIdValue;
  }

  async transaction<T>(block: (transaction: RdbTransaction) => Promise<T>): Promise<T> {
    this.log.push('begin');
    this.failIfScripted('begin');
    const rowsSnapshot: Map<string, DurableProfileRow> = cloneRowMap(this.committedRows);
    const activeSnapshot: string | undefined = this.activeIdValue;
    const transaction = new RecordingTransaction(this);
    try {
      const result: T = await block(transaction);
      this.failIfScripted('commit');
      this.log.push('commit');
      return result;
    } catch (error) {
      this.committedRows.clear();
      for (const entry of rowsSnapshot.entries()) {
        this.committedRows.set(entry[0], cloneDurableRow(entry[1]));
      }
      this.activeIdValue = activeSnapshot;
      this.log.push('rollback');
      if (error instanceof Error) {
        throw error;
      }
      throw new Error(`${error}`);
    }
  }

  currentActiveId(): string | undefined {
    return this.activeIdValue;
  }

  private failIfScripted(operation: string): void {
    const queue: ScriptedFailure[] | undefined = this.scriptedFailures.get(operation);
    if (queue === undefined || queue.length === 0) {
      return;
    }
    const next: ScriptedFailure | undefined = queue.shift();
    if (next !== undefined) {
      const failure: Error = next.error;
      throw failure;
    }
  }

  txGetProfileRow(id: string): DurableProfileRow | undefined {
    this.failIfScripted(`tx.getProfileRow:${id}`);
    const row: DurableProfileRow | undefined = this.committedRows.get(id);
    if (row !== undefined) {
      this.log.push(`tx.getProfileRow:${id}`);
    }
    return row === undefined ? undefined : cloneDurableRow(row);
  }

  txSetActiveId(activeId: string | undefined): void {
    this.log.push(`tx.setActiveId:${activeId ?? '<cleared>'}`);
    this.failIfScripted(`tx.setActiveId:${activeId ?? '<cleared>'}`);
    this.appStatePresent = true;
    this.activeIdValue = activeId;
  }

  txClearActiveIfMatching(id: string): void {
    this.log.push(`clearActiveIfMatching:${id}`);
    this.failIfScripted(`clearActiveIfMatching:${id}`);
    if (!this.appStatePresent) {
      return;
    }
    if (this.activeIdValue === id) {
      this.activeIdValue = undefined;
    }
  }

  txUpsertActiveId(activeId: string | undefined): void {
    this.log.push(`tx.upsertActiveId:${activeId ?? '<cleared>'}`);
    this.failIfScripted(`tx.upsertActiveId:${activeId ?? '<cleared>'}`);
    this.appStatePresent = true;
    this.activeIdValue = activeId;
  }

  txDeleteProfile(id: string): void {
    this.log.push(`deleteProfile:${id}`);
    this.failIfScripted(`deleteProfile:${id}`);
    this.committedRows.delete(id);
  }
}

class RecordingTransaction implements RdbTransaction {
  private readonly driver: RecordingRdbDriver;

  constructor(driver: RecordingRdbDriver) {
    this.driver = driver;
  }

  async getProfileRow(id: string): Promise<DurableProfileRow | undefined> {
    return this.driver.txGetProfileRow(id);
  }

  async setActiveId(activeId: string | undefined): Promise<void> {
    this.driver.txSetActiveId(activeId);
  }

  async clearActiveIfMatching(id: string): Promise<void> {
    this.driver.txClearActiveIfMatching(id);
  }

  async deleteProfile(id: string): Promise<void> {
    this.driver.txDeleteProfile(id);
  }
}

export function cloneDurableRow(row: DurableProfileRow): DurableProfileRow {
  return {
    schemaVersion: row.schemaVersion,
    id: row.id,
    name: row.name,
    sourceKind: row.sourceKind,
    sourceDisplay: row.sourceDisplay,
    sourceSecretRef: row.sourceSecretRef,
    currentRevisionJson: cloneRevisionJson(row.currentRevisionJson),
    failedCandidateJson: cloneRevisionJson(row.failedCandidateJson),
    availability: row.availability,
    lastErrorJson: cloneRevisionJson(row.lastErrorJson),
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    lastSuccessfulUpdateAt: row.lastSuccessfulUpdateAt
  };
}

function cloneRowMap(rows: Map<string, DurableProfileRow>): Map<string, DurableProfileRow> {
  const copy: Map<string, DurableProfileRow> = new Map<string, DurableProfileRow>();
  for (const entry of rows.entries()) {
    copy.set(entry[0], cloneDurableRow(entry[1]));
  }
  return copy;
}

export function assertAppErrorShape(error: Object, expectedDetailFragment: string): void {
  const record = error as PersistenceFailureShape;
  if (record.stage !== 'PERSISTENCE') {
    throw new FixtureAssertionError(`Expected PERSISTENCE stage but received ${JSON.stringify(record)}`);
  }
  if (record.code !== 'CMFA_PERSISTENCE_FAILED') {
    throw new FixtureAssertionError(`Expected CMFA_PERSISTENCE_FAILED but received ${JSON.stringify(record)}`);
  }
  const detail: string = record.technicalDetail;
  if (!detail.includes(expectedDetailFragment)) {
    throw new FixtureAssertionError(`Expected detail to contain ${expectedDetailFragment} but received ${detail}`);
  }
}

export function assertAppErrorExactDetail(error: Object, expectedDetail: string): void {
  const record = error as PersistenceFailureShape;
  if (record.stage !== 'PERSISTENCE') {
    throw new FixtureAssertionError(`Expected PERSISTENCE stage but received ${JSON.stringify(record)}`);
  }
  if (record.code !== 'CMFA_PERSISTENCE_FAILED') {
    throw new FixtureAssertionError(`Expected CMFA_PERSISTENCE_FAILED but received ${JSON.stringify(record)}`);
  }
  if (record.technicalDetail !== expectedDetail) {
    throw new FixtureAssertionError(`Expected detail ${expectedDetail} but received ${record.technicalDetail}`);
  }
}

export function assertCanonicalTimestampWithinRange(timestamp: string, earliest: string, latest: string, forbiddenFixed: string): void {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(timestamp)) {
    throw new FixtureAssertionError(`Expected canonical timestamp but received ${timestamp}`);
  }
  if (timestamp === forbiddenFixed) {
    throw new FixtureAssertionError(`Expected non-fixed timestamp but received ${timestamp}`);
  }
  if (timestamp < earliest || timestamp > latest) {
    throw new FixtureAssertionError(`Expected timestamp within [${earliest}, ${latest}] but received ${timestamp}`);
  }
}

export function assertNoLeak(text: string, forbiddenFragments: string[]): void {
  for (let index = 0; index < forbiddenFragments.length; index += 1) {
    if (text.includes(forbiddenFragments[index])) {
      throw new FixtureAssertionError(`Unexpected secret fragment leak: ${forbiddenFragments[index]} in ${text}`);
    }
  }
}

class FakeFileEntry {
  readonly kind: 'FILE' | 'DIRECTORY';
  bytes: Uint8Array;
  byteLength: number;
  nameOverride?: string;

  constructor(kind: 'FILE' | 'DIRECTORY', bytes?: Uint8Array, nameOverride?: string) {
    this.kind = kind;
    this.bytes = bytes === undefined ? new Uint8Array(0) : cloneBytes(bytes);
    this.byteLength = bytes === undefined ? 0 : bytes.length;
    this.nameOverride = nameOverride;
  }
}

class FakeOpenHandle {
  readonly fd: number;
  readonly path: string;
  readonly name: string;
  readonly readable: boolean;
  readonly writable: boolean;
  cursor: number;

  constructor(fd: number, path: string, name: string, readable: boolean, writable: boolean, cursor: number) {
    this.fd = fd;
    this.path = path;
    this.name = name;
    this.readable = readable;
    this.writable = writable;
    this.cursor = cursor;
  }
}

class ScriptedPathFailure {
  readonly error: Error;

  constructor(error: Error) {
    this.error = error;
  }
}

class FakePickerSelectionFailure {
  readonly error: Error;

  constructor(error: Error) {
    this.error = error;
  }
}

interface PickerSelectOptionsShape {
  maxSelectNumber: number;
  fileSuffixFilters: string[];
}

class FakeStatRecord {
  readonly size: number;
  readonly isFile: boolean;
  readonly isDirectory: boolean;

  constructor(size: number, isFile: boolean, isDirectory: boolean) {
    this.size = size;
    this.isFile = isFile;
    this.isDirectory = isDirectory;
  }
}

class FakeOpenedFileRecord {
  readonly fd: number;
  readonly path: string;
  readonly name: string;

  constructor(fd: number, path: string, name: string) {
    this.fd = fd;
    this.path = path;
    this.name = name;
  }
}

interface FileTokenShape {
  fd: number;
  path: string;
  name?: string;
}

interface BufferIoOptionsShape {
  offset?: number;
  length?: number;
}

export class SequenceClock implements Clock {
  private readonly timestamps: string[];
  private index: number = 0;

  constructor(timestamps: string[]) {
    this.timestamps = timestamps.slice();
  }

  now(): string {
    const resolvedIndex: number = Math.min(this.index, this.timestamps.length - 1);
    this.index += 1;
    return this.timestamps[resolvedIndex];
  }
}

export class SequenceIdGenerator implements IdGenerator {
  readonly generated: string[] = [];
  private readonly values: string[];
  private index: number = 0;

  constructor(values: string[]) {
    this.values = values.slice();
  }

  nextId(): string {
    const resolvedIndex: number = Math.min(this.index, this.values.length - 1);
    const value: string = this.values[resolvedIndex];
    this.index += 1;
    this.generated.push(value);
    return value;
  }
}

export class PickerRequestRecord {
  readonly maxSelectNumber: number;
  readonly fileSuffixFilters: string[];

  constructor(maxSelectNumber: number, fileSuffixFilters: string[]) {
    this.maxSelectNumber = maxSelectNumber;
    this.fileSuffixFilters = fileSuffixFilters.slice();
  }
}

export class FakeDocumentPickerPort {
  readonly requests: PickerRequestRecord[] = [];
  readonly scriptedSelections: (string[] | FakePickerSelectionFailure)[] = [];

  async select(options: PickerSelectOptionsShape): Promise<string[]> {
    this.requests.push(new PickerRequestRecord(options.maxSelectNumber, options.fileSuffixFilters));
    const next: string[] | FakePickerSelectionFailure | undefined = this.scriptedSelections.shift();
    if (next instanceof FakePickerSelectionFailure) {
      throw next.error;
    }
    return next === undefined ? [] : next.slice();
  }

  failNext(error: Error): void {
    this.scriptedSelections.push(new FakePickerSelectionFailure(error));
  }
}

export class FakeFileDriver implements FileDriver {
  readonly operationLog: string[] = [];
  readonly hashPaths: string[] = [];
  readonly renamePairs: string[] = [];
  readonly closeCounts: Map<string, number> = new Map<string, number>();
  private readonly entries: Map<string, FakeFileEntry> = new Map<string, FakeFileEntry>();
  private readonly handles: Map<number, FakeOpenHandle> = new Map<number, FakeOpenHandle>();
  private readonly scriptedFailures: Map<string, ScriptedPathFailure[]> = new Map<string, ScriptedPathFailure[]>();
  private readonly scriptedReadCounts: Map<string, number[]> = new Map<string, number[]>();
  private readonly scriptedWriteCounts: Map<string, number[]> = new Map<string, number[]>();
  private nextFd: number = 10;

  seedDirectory(path: string): void {
    this.entries.set(normalizeFakePath(path), new FakeFileEntry('DIRECTORY'));
  }

  seedFile(path: string, bytes: Uint8Array, nameOverride?: string): void {
    const normalizedPath: string = normalizeFakePath(path);
    const parent: string | null = fakeParentPath(normalizedPath);
    if (parent !== null) {
      this.ensureDirectoryChain(parent);
    }
    this.entries.set(normalizedPath, new FakeFileEntry('FILE', bytes, nameOverride));
  }

  seedTextFile(path: string, text: string, nameOverride?: string): void {
    this.seedFile(path, asciiBytes(text), nameOverride);
  }

  fileExists(path: string): boolean {
    return this.entries.has(normalizeFakePath(path));
  }

  readFileBytes(path: string): Uint8Array {
    const entry: FakeFileEntry | undefined = this.entries.get(normalizeFakePath(path));
    if (entry === undefined || entry.kind !== 'FILE') {
      throw new FixtureAssertionError(`Expected file at ${path}`);
    }
    return sliceBytes(entry.bytes, entry.byteLength);
  }

  readFileText(path: string): string {
    return asciiText(this.readFileBytes(path));
  }

  writeTextFile(path: string, text: string): void {
    this.seedTextFile(path, text);
  }

  countCloses(path: string): number {
    return this.closeCounts.get(normalizeFakePath(path)) ?? 0;
  }

  injectFailure(operation: string, target: string, error: Error): void {
    const key: string = `${operation}:${target}`;
    let queue: ScriptedPathFailure[] | undefined = this.scriptedFailures.get(key);
    if (queue === undefined) {
      queue = [];
      this.scriptedFailures.set(key, queue);
    }
    queue.push(new ScriptedPathFailure(error));
  }

  scriptWriteCounts(target: string, counts: number[]): void {
    this.scriptedWriteCounts.set(normalizeFakePath(target), counts.slice());
  }

  scriptReadCounts(target: string, counts: number[]): void {
    this.scriptedReadCounts.set(normalizeFakePath(target), counts.slice());
  }

  async mkdir(path: string, recursive: boolean): Promise<void> {
    const normalizedPath: string = normalizeFakePath(path);
    this.operationLog.push(`mkdir:${normalizedPath}:${recursive ? 'recursive' : 'single'}`);
    this.failIfScripted('mkdir', normalizedPath);
    if (!recursive) {
      const parent: string | null = fakeParentPath(normalizedPath);
      if (parent !== null && !this.entries.has(parent)) {
        throw new Error('Parent directory does not exist.');
      }
      this.entries.set(normalizedPath, new FakeFileEntry('DIRECTORY'));
      return;
    }
    this.ensureDirectoryChain(normalizedPath);
  }

  async list(path: string): Promise<string[]> {
    const normalizedPath: string = normalizeFakePath(path);
    this.operationLog.push(`list:${normalizedPath}`);
    this.failIfScripted('list', normalizedPath);
    const names: string[] = [];
    const prefix: string = normalizedPath === '/' ? '/' : `${normalizedPath}/`;
    for (const entryPath of this.entries.keys()) {
      if (!entryPath.startsWith(prefix) || entryPath === normalizedPath) {
        continue;
      }
      const remainder: string = entryPath.substring(prefix.length);
      if (remainder.length === 0 || remainder.includes('/')) {
        continue;
      }
      names.push(remainder);
    }
    names.sort();
    return names;
  }

  async stat(path: string): Promise<FakeStatRecord> {
    const normalizedPath: string = normalizeFakePath(path);
    this.operationLog.push(`stat:${normalizedPath}`);
    this.failIfScripted('stat', normalizedPath);
    const entry: FakeFileEntry | undefined = this.entries.get(normalizedPath);
    if (entry === undefined) {
      throw new Error('No such file or directory.');
    }
    return new FakeStatRecord(
      entry.kind === 'FILE' ? entry.byteLength : 0,
      entry.kind === 'FILE',
      entry.kind === 'DIRECTORY'
    );
  }

  async statIfPresent(path: string): Promise<FakeStatRecord | undefined> {
    const normalizedPath: string = normalizeFakePath(path);
    this.operationLog.push(`statIfPresent:${normalizedPath}`);
    this.failIfScripted('stat', normalizedPath);
    const entry: FakeFileEntry | undefined = this.entries.get(normalizedPath);
    if (entry === undefined) {
      return undefined;
    }
    return new FakeStatRecord(
      entry.kind === 'FILE' ? entry.byteLength : 0,
      entry.kind === 'FILE',
      entry.kind === 'DIRECTORY'
    );
  }

  async open(path: string, mode: number): Promise<FakeOpenedFileRecord> {
    const normalizedPath: string = normalizeFakePath(path);
    this.operationLog.push(`open:${normalizedPath}:${mode}`);
    this.failIfScripted('open', normalizedPath);
    const createFlag: boolean = (mode & 0o100) === 0o100;
    const truncFlag: boolean = (mode & 0o1000) === 0o1000;
    const appendFlag: boolean = (mode & 0o2000) === 0o2000;
    const readWriteFlag: boolean = (mode & 0o2) === 0o2;
    const writeOnlyFlag: boolean = (mode & 0o1) === 0o1;
    const writable: boolean = readWriteFlag || writeOnlyFlag;
    const readable: boolean = readWriteFlag || !writeOnlyFlag;
    let entry: FakeFileEntry | undefined = this.entries.get(normalizedPath);
    if (entry === undefined) {
      if (!createFlag) {
        throw new Error('No such file or directory.');
      }
      const parent: string | null = fakeParentPath(normalizedPath);
      if (parent !== null) {
        this.ensureDirectoryChain(parent);
      }
      entry = new FakeFileEntry('FILE');
      this.entries.set(normalizedPath, entry);
    }
    if (entry.kind !== 'FILE') {
      throw new Error('Expected a file path.');
    }
    if (truncFlag && writable) {
      entry.bytes = new Uint8Array(0);
      entry.byteLength = 0;
    }
    const cursor: number = appendFlag ? entry.byteLength : 0;
    const fd: number = this.nextFd;
    this.nextFd += 1;
    const handle = new FakeOpenHandle(
      fd,
      normalizedPath,
      resolveEntryName(normalizedPath, entry),
      readable,
      writable,
      cursor
    );
    this.handles.set(fd, handle);
    return new FakeOpenedFileRecord(handle.fd, handle.path, handle.name);
  }

  async close(file: number | FileTokenShape): Promise<void> {
    const handle = this.resolveHandle(file);
    this.operationLog.push(`close:${handle.path}`);
    this.failIfScripted('close', handle.path);
    this.handles.delete(handle.fd);
    this.closeCounts.set(handle.path, (this.closeCounts.get(handle.path) ?? 0) + 1);
  }

  async read(fd: number, buffer: ArrayBuffer, options?: BufferIoOptionsShape): Promise<number> {
    const handle: FakeOpenHandle = this.requireOpenHandle(fd);
    this.operationLog.push(`read:${handle.path}`);
    this.failIfScripted('read', handle.path);
    if (!handle.readable) {
      throw new Error('File is not readable.');
    }
    const entry: FakeFileEntry = this.requireFileEntry(handle.path);
    const offset: number = options?.offset ?? 0;
    const start: number = handle.cursor + offset;
    const requested: number = options?.length ?? buffer.byteLength;
    const available: number = Math.max(0, entry.byteLength - start);
    const scriptedCount: number | undefined = this.nextScriptedReadCount(handle.path);
    const count: number = scriptedCount === undefined ? Math.min(requested, available) : scriptedCount;
    const safeCopyCount: number = Math.min(count, requested, available);
    const target = new Uint8Array(buffer);
    for (let index = 0; index < safeCopyCount; index += 1) {
      target[index] = entry.bytes[start + index];
    }
    handle.cursor = start + count;
    return count;
  }

  async write(fd: number, buffer: ArrayBuffer | string, options?: BufferIoOptionsShape): Promise<number> {
    const handle: FakeOpenHandle = this.requireOpenHandle(fd);
    this.operationLog.push(`write:${handle.path}`);
    this.failIfScripted('write', handle.path);
    if (!handle.writable) {
      throw new Error('File is not writable.');
    }
    const entry: FakeFileEntry = this.requireFileEntry(handle.path);
    const source: Uint8Array = typeof buffer === 'string'
      ? asciiBytes(buffer)
      : new Uint8Array(buffer);
    const requested: number = options?.length ?? source.length;
    const scriptedCount: number | undefined = this.nextScriptedWriteCount(handle.path);
    const count: number = scriptedCount === undefined
      ? Math.min(requested, source.length)
      : scriptedCount;
    const offset: number = options?.offset ?? 0;
    const start: number = handle.cursor + offset;
    const requiredLength: number = start + count;
    if (entry.bytes.length < requiredLength) {
      const nextCapacity: number = growCapacity(entry.bytes.length, requiredLength);
      const next = new Uint8Array(nextCapacity);
      for (let index = 0; index < entry.byteLength; index += 1) {
        next[index] = entry.bytes[index];
      }
      entry.bytes = next;
    }
    for (let index = 0; index < count; index += 1) {
      entry.bytes[start + index] = source[index];
    }
    entry.byteLength = Math.max(entry.byteLength, requiredLength);
    handle.cursor = start + count;
    return count;
  }

  async unlink(path: string): Promise<void> {
    const normalizedPath: string = normalizeFakePath(path);
    this.operationLog.push(`unlink:${normalizedPath}`);
    this.failIfScripted('unlink', normalizedPath);
    const entry: FakeFileEntry | undefined = this.entries.get(normalizedPath);
    if (entry === undefined) {
      throw new Error('No such file or directory.');
    }
    if (entry.kind !== 'FILE') {
      throw new Error('Cannot unlink a directory.');
    }
    this.entries.delete(normalizedPath);
  }

  async rmdir(path: string): Promise<void> {
    const normalizedPath: string = normalizeFakePath(path);
    this.operationLog.push(`rmdir:${normalizedPath}`);
    this.failIfScripted('rmdir', normalizedPath);
    const entry: FakeFileEntry | undefined = this.entries.get(normalizedPath);
    if (entry === undefined) {
      throw new Error('No such file or directory.');
    }
    if (entry.kind !== 'DIRECTORY') {
      throw new Error('Cannot remove a file with rmdir.');
    }
    const prefix: string = normalizedPath === '/' ? '/' : `${normalizedPath}/`;
    for (const candidate of this.entries.keys()) {
      if (candidate !== normalizedPath && candidate.startsWith(prefix)) {
        throw new Error('Directory is not empty.');
      }
    }
    this.entries.delete(normalizedPath);
  }

  async renameNoOverwrite(source: string, destination: string): Promise<void> {
    const normalizedSource: string = normalizeFakePath(source);
    const normalizedDestination: string = normalizeFakePath(destination);
    this.operationLog.push(`rename:${normalizedSource}->${normalizedDestination}`);
    this.renamePairs.push(`${normalizedSource}->${normalizedDestination}`);
    this.failIfScripted('rename', `${normalizedSource}->${normalizedDestination}`);
    if (this.entries.has(normalizedDestination)) {
      throw new Error('Destination already exists.');
    }
    const entry: FakeFileEntry | undefined = this.entries.get(normalizedSource);
    if (entry === undefined) {
      throw new Error('No such file or directory.');
    }
    const parent: string | null = fakeParentPath(normalizedDestination);
    if (parent !== null) {
      this.ensureDirectoryChain(parent);
    }
    this.entries.delete(normalizedSource);
    this.entries.set(normalizedDestination, entry);
  }

  async hash(path: string, algorithm: string): Promise<string> {
    const normalizedPath: string = normalizeFakePath(path);
    this.operationLog.push(`hash:${normalizedPath}:${algorithm}`);
    this.hashPaths.push(normalizedPath);
    this.failIfScripted('hash', normalizedPath);
    const entry: FakeFileEntry = this.requireFileEntry(normalizedPath);
    if (algorithm !== 'sha256') {
      throw new Error(`Unsupported hash algorithm: ${algorithm}`);
    }
    return sha256Hex(sliceBytes(entry.bytes, entry.byteLength));
  }

  private ensureDirectoryChain(path: string): void {
    const normalizedPath: string = normalizeFakePath(path);
    if (normalizedPath === '/') {
      this.entries.set('/', new FakeFileEntry('DIRECTORY'));
      return;
    }
    const segments: string[] = normalizedPath.substring(1).split('/');
    let current = '';
    this.entries.set('/', new FakeFileEntry('DIRECTORY'));
    for (let index = 0; index < segments.length; index += 1) {
      current = `${current}/${segments[index]}`;
      this.entries.set(current, new FakeFileEntry('DIRECTORY'));
    }
  }

  private failIfScripted(operation: string, target: string): void {
    const key: string = `${operation}:${target}`;
    const queue: ScriptedPathFailure[] | undefined = this.scriptedFailures.get(key);
    if (queue === undefined || queue.length === 0) {
      return;
    }
    const failure: ScriptedPathFailure | undefined = queue.shift();
    if (failure !== undefined) {
      throw failure.error;
    }
  }

  private nextScriptedWriteCount(path: string): number | undefined {
    const queue: number[] | undefined = this.scriptedWriteCounts.get(path);
    if (queue === undefined || queue.length === 0) {
      return undefined;
    }
    const next: number | undefined = queue.shift();
    if (queue.length === 0) {
      this.scriptedWriteCounts.delete(path);
    }
    return next;
  }

  private nextScriptedReadCount(path: string): number | undefined {
    const queue: number[] | undefined = this.scriptedReadCounts.get(path);
    if (queue === undefined || queue.length === 0) {
      return undefined;
    }
    const next: number | undefined = queue.shift();
    if (queue.length === 0) {
      this.scriptedReadCounts.delete(path);
    }
    return next;
  }

  private requireOpenHandle(fd: number): FakeOpenHandle {
    const handle: FakeOpenHandle | undefined = this.handles.get(fd);
    if (handle === undefined) {
      throw new Error(`No open handle for fd ${fd}`);
    }
    return handle;
  }

  private resolveHandle(file: number | FileTokenShape): FakeOpenHandle {
    const fd: number = typeof file === 'number' ? file : file.fd;
    return this.requireOpenHandle(fd);
  }

  private requireFileEntry(path: string): FakeFileEntry {
    const entry: FakeFileEntry | undefined = this.entries.get(path);
    if (entry === undefined || entry.kind !== 'FILE') {
      throw new Error(`Expected file at ${path}`);
    }
    return entry;
  }
}

export function buildBytes(length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  for (let index = 0; index < length; index += 1) {
    bytes[index] = index % 251;
  }
  return bytes;
}

export function utf8Bytes(value: string): Uint8Array {
  return encodeUtf8(value);
}

class DeterministicHuksDriverCall {
  readonly nonceHex: string;
  readonly byteLength: number;

  constructor(nonceHex: string, byteLength: number) {
    this.nonceHex = nonceHex;
    this.byteLength = byteLength;
  }
}

export class DeterministicHuksDriver implements HuksDriver {
  readonly operationLog: string[] = [];
  readonly encryptCalls: DeterministicHuksDriverCall[] = [];
  readonly decryptCalls: string[] = [];
  ensureKeyCallCount: number = 0;
  generateKeyCallCount: number = 0;
  deleteKeyCallCount: number = 0;
  private keyExists: boolean = false;
  private readonly queuedNonces: Uint8Array[] = [];

  seedNonce(value: Uint8Array): void {
    this.queuedNonces.push(cloneBytes(value));
  }

  async encrypt(plaintext: Uint8Array): Promise<HuksEncryptedPayload> {
    this.ensureKey();
    const nonce: Uint8Array = this.nextNonce();
    const ciphertext: Uint8Array = new Uint8Array(plaintext.length);
    for (let index = 0; index < plaintext.length; index += 1) {
      ciphertext[index] = plaintext[index] ^ nonce[index % nonce.length] ^ 0x5a;
    }
    const tag: Uint8Array = buildAuthenticationTag(nonce, ciphertext);
    this.operationLog.push(`encrypt:${nonce.length}:${ciphertext.length}`);
    this.encryptCalls.push(new DeterministicHuksDriverCall(hexBytes(nonce), plaintext.length));
    return {
      keyAliasVersion: HUKS_SECRET_KEY_ALIAS_VERSION,
      nonce,
      ciphertext,
      tag
    };
  }

  async decrypt(payload: HuksEncryptedPayload): Promise<Uint8Array> {
    this.ensureKey();
    validateDeterministicPayload(payload);
    this.operationLog.push(`decrypt:${payload.nonce.length}:${payload.ciphertext.length}`);
    this.decryptCalls.push(hexBytes(payload.tag));
    const expectedTag: Uint8Array = buildAuthenticationTag(payload.nonce, payload.ciphertext);
    if (!equalBytes(expectedTag, payload.tag)) {
      throw new Error('Authenticated decryption rejected tampering.');
    }
    const plaintext: Uint8Array = new Uint8Array(payload.ciphertext.length);
    for (let index = 0; index < payload.ciphertext.length; index += 1) {
      plaintext[index] = payload.ciphertext[index] ^ payload.nonce[index % payload.nonce.length] ^ 0x5a;
    }
    return plaintext;
  }

  private ensureKey(): void {
    this.ensureKeyCallCount += 1;
    this.operationLog.push('ensureKey');
    if (!this.keyExists) {
      this.generateKeyCallCount += 1;
      this.keyExists = true;
      this.operationLog.push('generateKey');
    }
  }

  private nextNonce(): Uint8Array {
    const scripted: Uint8Array | undefined = this.queuedNonces.shift();
    if (scripted !== undefined) {
      if (scripted.length !== HUKS_SECRET_NONCE_LENGTH) {
        throw new Error('Deterministic nonce must be 12 bytes.');
      }
      return cloneBytes(scripted);
    }
    const next = new Uint8Array(HUKS_SECRET_NONCE_LENGTH);
    for (let index = 0; index < HUKS_SECRET_NONCE_LENGTH; index += 1) {
      next[index] = (this.encryptCalls.length + index + 1) & 0xff;
    }
    return next;
  }
}

export function replaceEnvelopeCiphertextByte(envelopeText: string): string {
  return mutateBase64Field(envelopeText, 'ciphertext');
}

export function replaceEnvelopeTagByte(envelopeText: string): string {
  return mutateBase64Field(envelopeText, 'tag');
}

export function replaceEnvelopeNumberField(envelopeText: string, fieldName: string, nextValue: number): string {
  const parsed: Record<string, string | number> = JSON.parse(envelopeText) as Record<string, string | number>;
  parsed[fieldName] = nextValue;
  return JSON.stringify(parsed);
}

function asciiBytes(text: string): Uint8Array {
  const bytes = new Uint8Array(text.length);
  for (let index = 0; index < text.length; index += 1) {
    bytes[index] = text.charCodeAt(index) & 0xff;
  }
  return bytes;
}

function asciiText(bytes: Uint8Array): string {
  let text = '';
  for (let index = 0; index < bytes.length; index += 1) {
    text += String.fromCharCode(bytes[index]);
  }
  return text;
}

function encodeUtf8(value: string): Uint8Array {
  const bytes: number[] = [];
  let index: number = 0;
  while (index < value.length) {
    const codeUnit: number = value.charCodeAt(index);
    if (codeUnit < 0x80) {
      bytes.push(codeUnit);
      index += 1;
      continue;
    }
    if (codeUnit < 0x800) {
      bytes.push(0xc0 | (codeUnit >> 6));
      bytes.push(0x80 | (codeUnit & 0x3f));
      index += 1;
      continue;
    }
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff && index + 1 < value.length) {
      const nextCodeUnit: number = value.charCodeAt(index + 1);
      if (nextCodeUnit >= 0xdc00 && nextCodeUnit <= 0xdfff) {
        const codePoint: number = 0x10000 + ((codeUnit - 0xd800) << 10) + (nextCodeUnit - 0xdc00);
        bytes.push(0xf0 | (codePoint >> 18));
        bytes.push(0x80 | ((codePoint >> 12) & 0x3f));
        bytes.push(0x80 | ((codePoint >> 6) & 0x3f));
        bytes.push(0x80 | (codePoint & 0x3f));
        index += 2;
        continue;
      }
    }
    bytes.push(0xe0 | (codeUnit >> 12));
    bytes.push(0x80 | ((codeUnit >> 6) & 0x3f));
    bytes.push(0x80 | (codeUnit & 0x3f));
    index += 1;
  }
  const encoded = new Uint8Array(bytes.length);
  for (let position = 0; position < bytes.length; position += 1) {
    encoded[position] = bytes[position];
  }
  return encoded;
}

function buildAuthenticationTag(nonce: Uint8Array, ciphertext: Uint8Array): Uint8Array {
  let accumulatorA: number = 0x13579bdf;
  let accumulatorB: number = 0x2468ace0;
  for (let index = 0; index < nonce.length; index += 1) {
    accumulatorA = ((accumulatorA << 5) - accumulatorA + nonce[index] + index) >>> 0;
    accumulatorB = ((accumulatorB << 7) ^ (nonce[index] + index)) >>> 0;
  }
  for (let index = 0; index < ciphertext.length; index += 1) {
    accumulatorA = ((accumulatorA << 5) - accumulatorA + ciphertext[index] + index) >>> 0;
    accumulatorB = ((accumulatorB << 7) ^ (ciphertext[index] + index)) >>> 0;
  }
  const tag = new Uint8Array(HUKS_SECRET_TAG_LENGTH);
  for (let index = 0; index < HUKS_SECRET_TAG_LENGTH; index += 1) {
    accumulatorA = ((accumulatorA << 3) ^ (accumulatorB >>> 1) ^ index) >>> 0;
    accumulatorB = ((accumulatorB << 5) ^ (accumulatorA >>> 2) ^ (ciphertext.length + index)) >>> 0;
    tag[index] = (accumulatorA ^ accumulatorB) & 0xff;
  }
  return tag;
}

function validateDeterministicPayload(payload: HuksEncryptedPayload): void {
  if (payload.keyAliasVersion !== HUKS_SECRET_KEY_ALIAS_VERSION ||
    payload.nonce.length !== HUKS_SECRET_NONCE_LENGTH ||
    payload.tag.length !== HUKS_SECRET_TAG_LENGTH) {
    throw new Error('Deterministic payload shape is invalid.');
  }
}

function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) {
      return false;
    }
  }
  return true;
}

function hexBytes(bytes: Uint8Array): string {
  let hex = '';
  for (let index = 0; index < bytes.length; index += 1) {
    hex += bytes[index].toString(16).padStart(2, '0');
  }
  return hex;
}

function mutateBase64Field(envelopeText: string, fieldName: string): string {
  const parsed: Record<string, string | number> = JSON.parse(envelopeText) as Record<string, string | number>;
  const encoded: string = `${parsed[fieldName] ?? ''}`;
  const decoded: Uint8Array = decodeBase64Loose(encoded);
  decoded[0] = decoded[0] ^ 0x01;
  parsed[fieldName] = encodeBase64Loose(decoded);
  return JSON.stringify(parsed);
}

function encodeBase64Loose(bytes: Uint8Array): string {
  const alphabet: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let encoded = '';
  let index = 0;
  while (index < bytes.length) {
    const first: number = bytes[index];
    const second: number = index + 1 < bytes.length ? bytes[index + 1] : -1;
    const third: number = index + 2 < bytes.length ? bytes[index + 2] : -1;
    encoded += alphabet[(first >> 2) & 0x3f];
    encoded += alphabet[((first & 0x03) << 4) | (second >= 0 ? ((second >> 4) & 0x0f) : 0)];
    encoded += second >= 0 ? alphabet[((second & 0x0f) << 2) | (third >= 0 ? ((third >> 6) & 0x03) : 0)] : '=';
    encoded += third >= 0 ? alphabet[third & 0x3f] : '=';
    index += 3;
  }
  return encoded;
}

function decodeBase64Loose(encoded: string): Uint8Array {
  const alphabet: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let paddingCount = 0;
  if (encoded.endsWith('==')) {
    paddingCount = 2;
  } else if (encoded.endsWith('=')) {
    paddingCount = 1;
  }
  const decoded = new Uint8Array((encoded.length / 4) * 3 - paddingCount);
  let writeIndex = 0;
  for (let index = 0; index < encoded.length; index += 4) {
    const a: number = alphabet.indexOf(encoded[index]);
    const b: number = alphabet.indexOf(encoded[index + 1]);
    const c: number = encoded[index + 2] === '=' ? -1 : alphabet.indexOf(encoded[index + 2]);
    const d: number = encoded[index + 3] === '=' ? -1 : alphabet.indexOf(encoded[index + 3]);
    decoded[writeIndex] = ((a << 2) | (b >> 4)) & 0xff;
    writeIndex += 1;
    if (c >= 0 && writeIndex < decoded.length + 1) {
      if (writeIndex < decoded.length) {
        decoded[writeIndex] = (((b & 0x0f) << 4) | (c >> 2)) & 0xff;
      }
      writeIndex += 1;
    }
    if (d >= 0 && writeIndex < decoded.length + 1) {
      if (writeIndex < decoded.length) {
        decoded[writeIndex] = (((c & 0x03) << 6) | d) & 0xff;
      }
      writeIndex += 1;
    }
  }
  return decoded;
}

function cloneBytes(bytes: Uint8Array): Uint8Array {
  const copy = new Uint8Array(bytes.length);
  for (let index = 0; index < bytes.length; index += 1) {
    copy[index] = bytes[index];
  }
  return copy;
}

function sliceBytes(bytes: Uint8Array, length: number): Uint8Array {
  const copy = new Uint8Array(length);
  for (let index = 0; index < length; index += 1) {
    copy[index] = bytes[index];
  }
  return copy;
}

function growCapacity(currentCapacity: number, requiredLength: number): number {
  let nextCapacity: number = currentCapacity > 0 ? currentCapacity : 1;
  while (nextCapacity < requiredLength) {
    nextCapacity *= 2;
  }
  return nextCapacity;
}

function normalizeFakePath(path: string): string {
  const trimmed: string = path.trim();
  if (trimmed.includes('://')) {
    return trimmed;
  }
  if (trimmed.length === 0) {
    return '/';
  }
  const rawSegments: string[] = trimmed.split('/');
  const segments: string[] = [];
  for (let index = 0; index < rawSegments.length; index += 1) {
    const segment: string = rawSegments[index];
    if (segment.length === 0 || segment === '.') {
      continue;
    }
    if (segment === '..') {
      if (segments.length > 0) {
        segments.pop();
      }
      continue;
    }
    segments.push(segment);
  }
  return `/${segments.join('/')}`;
}

function fakeParentPath(path: string): string | null {
  if (path.includes('://') || path === '/') {
    return null;
  }
  const separatorIndex: number = path.lastIndexOf('/');
  if (separatorIndex <= 0) {
    return '/';
  }
  return path.substring(0, separatorIndex);
}

function resolveEntryName(path: string, entry: FakeFileEntry): string {
  if (entry.nameOverride !== undefined) {
    return entry.nameOverride;
  }
  if (path.includes('://')) {
    const fragmentIndex: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf(':'));
    return fragmentIndex >= 0 ? path.substring(fragmentIndex + 1) : path;
  }
  const separatorIndex: number = path.lastIndexOf('/');
  return separatorIndex >= 0 ? path.substring(separatorIndex + 1) : path;
}

function sha256Hex(bytes: Uint8Array): string {
  const state: Uint32Array = new Uint32Array([
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19
  ]);
  const padded: Uint8Array = padSha256(bytes);
  const schedule: Uint32Array = new Uint32Array(64);

  for (let chunkOffset = 0; chunkOffset < padded.length; chunkOffset += 64) {
    for (let index = 0; index < 16; index += 1) {
      const baseOffset: number = chunkOffset + index * 4;
      schedule[index] =
        (padded[baseOffset] << 24) |
        (padded[baseOffset + 1] << 16) |
        (padded[baseOffset + 2] << 8) |
        padded[baseOffset + 3];
    }
    for (let index = 16; index < 64; index += 1) {
      const sigma0: number = rotateRight(schedule[index - 15], 7) ^ rotateRight(schedule[index - 15], 18) ^ (schedule[index - 15] >>> 3);
      const sigma1: number = rotateRight(schedule[index - 2], 17) ^ rotateRight(schedule[index - 2], 19) ^ (schedule[index - 2] >>> 10);
      schedule[index] = (schedule[index - 16] + sigma0 + schedule[index - 7] + sigma1) >>> 0;
    }

    let a: number = state[0];
    let b: number = state[1];
    let c: number = state[2];
    let d: number = state[3];
    let e: number = state[4];
    let f: number = state[5];
    let g: number = state[6];
    let h: number = state[7];

    for (let index = 0; index < 64; index += 1) {
      const sum1: number = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
      const choice: number = (e & f) ^ (~e & g);
      const temp1: number = (h + sum1 + choice + SHA256_ROUND_CONSTANTS[index] + schedule[index]) >>> 0;
      const sum0: number = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
      const majority: number = (a & b) ^ (a & c) ^ (b & c);
      const temp2: number = (sum0 + majority) >>> 0;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }

    state[0] = (state[0] + a) >>> 0;
    state[1] = (state[1] + b) >>> 0;
    state[2] = (state[2] + c) >>> 0;
    state[3] = (state[3] + d) >>> 0;
    state[4] = (state[4] + e) >>> 0;
    state[5] = (state[5] + f) >>> 0;
    state[6] = (state[6] + g) >>> 0;
    state[7] = (state[7] + h) >>> 0;
  }

  let digest = '';
  for (let index = 0; index < state.length; index += 1) {
    digest += state[index].toString(16).padStart(8, '0');
  }
  return digest.toLowerCase();
}

const SHA256_ROUND_CONSTANTS: Uint32Array = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]);

function padSha256(bytes: Uint8Array): Uint8Array {
  const bitLengthLow: number = (bytes.length * 8) >>> 0;
  const bitLengthHigh: number = Math.floor((bytes.length * 8) / 0x100000000);
  let paddedLength: number = bytes.length + 1 + 8;
  while (paddedLength % 64 !== 0) {
    paddedLength += 1;
  }
  const padded = new Uint8Array(paddedLength);
  for (let index = 0; index < bytes.length; index += 1) {
    padded[index] = bytes[index];
  }
  padded[bytes.length] = 0x80;
  padded[padded.length - 8] = (bitLengthHigh >>> 24) & 0xff;
  padded[padded.length - 7] = (bitLengthHigh >>> 16) & 0xff;
  padded[padded.length - 6] = (bitLengthHigh >>> 8) & 0xff;
  padded[padded.length - 5] = bitLengthHigh & 0xff;
  padded[padded.length - 4] = (bitLengthLow >>> 24) & 0xff;
  padded[padded.length - 3] = (bitLengthLow >>> 16) & 0xff;
  padded[padded.length - 2] = (bitLengthLow >>> 8) & 0xff;
  padded[padded.length - 1] = bitLengthLow & 0xff;
  return padded;
}

function rotateRight(value: number, bits: number): number {
  return ((value >>> bits) | (value << (32 - bits))) >>> 0;
}
