import { createAppError, createProfile, createProfileRevision, type AppError, type Profile, type ProfileAvailability } from '@cmfa/shared';
import type { DurableProfileRow, RdbDriver, RdbTransaction } from '../../main/ets/rdb/RdbDriver';

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
