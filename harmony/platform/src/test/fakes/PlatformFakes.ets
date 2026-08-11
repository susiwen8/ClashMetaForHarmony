import { createAppError, createProfile, createProfileRevision, type AppError, type Profile, type ProfileAvailability } from '@cmfa/shared';
import type { DurableProfileRow, RdbDriver, RdbTransaction } from '../../main/ets/rdb/RdbDriver';
import type { Clock, IdGenerator } from '@cmfa/shared';
import type { FileDriver } from '../../main/ets/files/FileDriver';

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
    const count: number = Math.min(requested, available);
    const target = new Uint8Array(buffer);
    for (let index = 0; index < count; index += 1) {
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
    const count: number = Math.min(requested, source.length);
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
    return pseudoSha256(sliceBytes(entry.bytes, entry.byteLength));
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

function pseudoSha256(bytes: Uint8Array): string {
  let accumulatorA: number = 0x6a09e667;
  let accumulatorB: number = 0xbb67ae85;
  for (let index = 0; index < bytes.length; index += 1) {
    accumulatorA = ((accumulatorA ^ bytes[index]) * 0x45d9f3b) >>> 0;
    accumulatorB = ((accumulatorB + bytes[index] + index) * 0x27d4eb2d) >>> 0;
  }
  let digest = '';
  for (let index = 0; index < 8; index += 1) {
    accumulatorA = ((accumulatorA ^ (accumulatorB >>> ((index % 4) * 8))) * 0x45d9f3b) >>> 0;
    accumulatorB = ((accumulatorB ^ (accumulatorA >>> ((index % 4) * 8))) * 0x27d4eb2d) >>> 0;
    digest += accumulatorA.toString(16).padStart(8, '0');
  }
  return digest.substring(0, 64).toLowerCase();
}
