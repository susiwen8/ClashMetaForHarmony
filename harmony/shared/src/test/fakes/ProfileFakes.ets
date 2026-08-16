import {
  createSubscriptionSecretError,
  createAppError,
  createProfile,
  createProfileRevision,
  redactUrl,
  type LocalProfileAcquisitionCancelled as PortLocalProfileAcquisitionCancelled,
  type LocalProfileAcquisitionFailure as PortLocalProfileAcquisitionFailure,
  type LocalProfileAcquisitionSuccess as PortLocalProfileAcquisitionSuccess,
  type RemoteProfileAcquisitionFailure as PortRemoteProfileAcquisitionFailure,
  type RemoteProfileAcquisitionSuccess as PortRemoteProfileAcquisitionSuccess,
  type AppError,
  type Clock as PortClock,
  type CoreError,
  type IdGenerator as PortIdGenerator,
  type LocalAcquireCommand as PortLocalAcquireCommand,
  type LocalProfileAcquisition as PortLocalProfileAcquisition,
  type ProfileContentStore as PortProfileContentStore,
  type Profile,
  type ProfileRepository as PortProfileRepository,
  type ProfileRevision
  ,
  type ProfileSourceGateway as PortProfileSourceGateway,
  type RemoteAcquireCommand as PortRemoteAcquireCommand,
  type RemoteProfileAcquisition as PortRemoteProfileAcquisition,
  type RevisionKind as PortRevisionKind,
  type StagedSource as PortStagedSource,
  type SubscriptionSecretErrorCode as PortSubscriptionSecretErrorCode,
  type SubscriptionSecretStore as PortSubscriptionSecretStore
} from '../../../Index';

export type RevisionKind = PortRevisionKind;
export type SecretErrorCode = PortSubscriptionSecretErrorCode;

export interface Deferred<T> {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(error: Error): void;
}

export interface FixtureStagedSource extends PortStagedSource {}

export interface FixtureClock extends PortClock {}

export interface FixtureIdGenerator extends PortIdGenerator {}

export interface FixtureProfileRepository extends PortProfileRepository {}

export interface FixtureProfileContentStore extends PortProfileContentStore {}

export interface FixtureLocalAcquireCommand extends PortLocalAcquireCommand {}

export interface FixtureRemoteAcquireCommand extends PortRemoteAcquireCommand {}

export interface FixtureProfileSourceGateway extends PortProfileSourceGateway {}

export interface FixtureSubscriptionSecretStore extends PortSubscriptionSecretStore {}

interface FixtureCoreErrorContext {
  operation: string;
  status: number;
}

export class FakeOperationTimeline {
  readonly entries: string[] = [];

  record(label: string): void {
    this.entries.push(label);
  }

  joined(): string {
    return this.entries.join('>');
  }
}

export class SafeRemoteAcquireRecord {
  readonly sourceDisplay: string;
  readonly allowPlainHttp: boolean;

  constructor(sourceDisplay: string, allowPlainHttp: boolean) {
    this.sourceDisplay = sourceDisplay;
    this.allowPlainHttp = allowPlainHttp;
  }
}

class FixtureStagedSourceValue implements FixtureStagedSource {
  stagingId: string;
  validationPath: string;
  sha256Digest: string;
  byteLength: number;
  validatedAt: string;

  constructor(
    stagingId: string,
    validationPath: string,
    sha256Digest: string,
    byteLength: number,
    validatedAt: string
  ) {
    this.stagingId = stagingId;
    this.validationPath = validationPath;
    this.sha256Digest = sha256Digest;
    this.byteLength = byteLength;
    this.validatedAt = validatedAt;
  }
}

export type FixtureLocalProfileAcquisition = PortLocalProfileAcquisition;

export type FixtureRemoteProfileAcquisition = PortRemoteProfileAcquisition;

export class CancelledLocalSource implements PortLocalProfileAcquisitionCancelled {
  readonly kind: 'CANCELLED' = 'CANCELLED';
}

export class AcquiredLocalSource implements PortLocalProfileAcquisitionSuccess {
  readonly kind: 'ACQUIRED' = 'ACQUIRED';
  readonly profileName: string;
  readonly sourceDisplay: string;
  readonly staged: FixtureStagedSource;

  constructor(profileName: string, sourceDisplay: string, staged: FixtureStagedSource) {
    this.profileName = profileName;
    this.sourceDisplay = sourceDisplay;
    this.staged = staged;
  }
}

export class FailedLocalSource implements PortLocalProfileAcquisitionFailure {
  readonly kind: 'FAILED' = 'FAILED';
  readonly error: AppError;
  readonly shouldPersistInvalidProfile: boolean;
  readonly profileName?: string;
  readonly sourceDisplay?: string;

  constructor(error: AppError, shouldPersistInvalidProfile: boolean, profileName?: string, sourceDisplay?: string) {
    this.error = error;
    this.shouldPersistInvalidProfile = shouldPersistInvalidProfile;
    this.profileName = profileName;
    this.sourceDisplay = sourceDisplay;
  }
}

export class AcquiredRemoteSource implements PortRemoteProfileAcquisitionSuccess {
  readonly kind: 'ACQUIRED' = 'ACQUIRED';
  readonly profileName: string;
  readonly sourceDisplay: string;
  readonly staged: FixtureStagedSource;

  constructor(profileName: string, sourceDisplay: string, staged: FixtureStagedSource) {
    this.profileName = profileName;
    this.sourceDisplay = sourceDisplay;
    this.staged = staged;
  }
}

export class FailedRemoteSource implements PortRemoteProfileAcquisitionFailure {
  readonly kind: 'FAILED' = 'FAILED';
  readonly error: AppError;
  readonly profileName: string;
  readonly sourceDisplay: string;
  readonly shouldPersistInvalidProfile: boolean;

  constructor(error: AppError, profileName: string, sourceDisplay: string, shouldPersistInvalidProfile: boolean) {
    this.error = error;
    this.profileName = profileName;
    this.sourceDisplay = sourceDisplay;
    this.shouldPersistInvalidProfile = shouldPersistInvalidProfile;
  }
}

export class FakeClock implements FixtureClock {
  private readonly timestamps: string[];
  private nextIndex: number = 0;

  constructor(timestamps: string[]) {
    this.timestamps = timestamps.slice();
  }

  now(): string {
    const candidate: string = this.timestamps[Math.min(this.nextIndex, this.timestamps.length - 1)];
    this.nextIndex += 1;
    return candidate;
  }
}

export class FakeIdGenerator implements FixtureIdGenerator {
  readonly generatedIds: string[] = [];
  private readonly ids: string[];
  private nextIndex: number = 0;

  constructor(ids: string[]) {
    this.ids = ids.slice();
  }

  nextId(): string {
    const value: string = this.ids[Math.min(this.nextIndex, this.ids.length - 1)];
    this.nextIndex += 1;
    this.generatedIds.push(value);
    return value;
  }
}

export class ScriptedVoidFailure {
  readonly shouldReject: boolean;
  readonly error?: Error;

  constructor(shouldReject: boolean, error?: Error) {
    this.shouldReject = shouldReject;
    this.error = error;
  }
}

export class ScriptedStringFailure {
  readonly shouldReject: boolean;
  readonly value?: string;
  readonly error?: Error;

  constructor(shouldReject: boolean, value?: string, error?: Error) {
    this.shouldReject = shouldReject;
    this.value = value;
    this.error = error;
  }
}

export class FakeCoreService {
  readonly validateCalls: string[] = [];
  readonly scriptedResults: ScriptedVoidFailure[] = [];
  private readonly timeline?: FakeOperationTimeline;

  constructor(timeline?: FakeOperationTimeline) {
    this.timeline = timeline;
  }

  async validateConfiguration(path: string): Promise<void> {
    this.validateCalls.push(path);
    this.timeline?.record('validate');
    const scripted: ScriptedVoidFailure | undefined = this.scriptedResults.shift();
    if (scripted !== undefined && scripted.shouldReject && scripted.error !== undefined) {
      throw scripted.error;
    }
    return Promise.resolve();
  }
}

export class FakeProfileRepository implements FixtureProfileRepository {
  readonly operationLog: string[] = [];
  readonly savedProfiles: Profile[] = [];
  readonly deletedProfileIds: string[] = [];
  readonly setActiveIdCalls: (string | undefined)[] = [];
  readonly saveDeferreds: Deferred<void>[] = [];
  readonly saveStartedDeferreds: Deferred<void>[] = [];
  readonly scriptedSaveResults: ScriptedVoidFailure[] = [];
  private readonly profiles: Profile[] = [];
  private activeIdValue: string | undefined = undefined;
  private saveConcurrency: number = 0;
  maxSaveConcurrency: number = 0;
  private readonly timeline?: FakeOperationTimeline;

  constructor(seedProfiles?: Profile[], activeId?: string, timeline?: FakeOperationTimeline) {
    this.activeIdValue = activeId;
    this.timeline = timeline;
    if (seedProfiles !== undefined) {
      for (let index = 0; index < seedProfiles.length; index += 1) {
        this.upsert(seedProfiles[index]);
      }
    }
  }

  async list(): Promise<Profile[]> {
    this.operationLog.push('listProfiles');
    this.timeline?.record('listProfiles');
    const result: Profile[] = [];
    for (let index = 0; index < this.profiles.length; index += 1) {
      result.push(cloneProfile(this.profiles[index]));
    }
    return result;
  }

  async get(id: string): Promise<Profile | undefined> {
    this.operationLog.push('getProfile');
    this.timeline?.record('getProfile');
    const existing: Profile | undefined = this.find(id);
    return existing === undefined ? undefined : cloneProfile(existing);
  }

  async save(profile: Profile): Promise<void> {
    this.operationLog.push('saveProfile');
    this.timeline?.record('saveProfile');
    this.savedProfiles.push(cloneProfile(profile));
    this.saveConcurrency += 1;
    this.maxSaveConcurrency = Math.max(this.maxSaveConcurrency, this.saveConcurrency);
    const started: Deferred<void> | undefined = this.saveStartedDeferreds.shift();
    if (started !== undefined) {
      started.resolve(undefined);
    }
    try {
      const deferred: Deferred<void> | undefined = this.saveDeferreds.shift();
      if (deferred !== undefined) {
        await deferred.promise;
      }
      const scripted: ScriptedVoidFailure | undefined = this.scriptedSaveResults.shift();
      if (scripted !== undefined && scripted.shouldReject && scripted.error !== undefined) {
        this.timeline?.record('saveProfileFailed');
        throw scripted.error;
      }
      this.upsert(profile);
    } finally {
      this.saveConcurrency -= 1;
    }
  }

  async deleteAndClearActive(id: string): Promise<void> {
    this.operationLog.push('deleteAndClearActive');
    this.timeline?.record('deleteAndClearActive');
    this.deletedProfileIds.push(id);
    for (let index = this.profiles.length - 1; index >= 0; index -= 1) {
      if (this.profiles[index].id === id) {
        this.profiles.splice(index, 1);
      }
    }
    if (this.activeIdValue === id) {
      this.activeIdValue = undefined;
    }
  }

  async getActiveId(): Promise<string | undefined> {
    this.operationLog.push('getActiveId');
    this.timeline?.record('getActiveId');
    return this.activeIdValue;
  }

  async setActiveId(id: string | undefined): Promise<void> {
    this.operationLog.push('setActiveId');
    this.timeline?.record('setActiveId');
    this.setActiveIdCalls.push(id);
    this.activeIdValue = id;
  }

  currentProfile(id: string): Profile | undefined {
    const existing: Profile | undefined = this.find(id);
    return existing === undefined ? undefined : cloneProfile(existing);
  }

  private find(id: string): Profile | undefined {
    for (let index = 0; index < this.profiles.length; index += 1) {
      if (this.profiles[index].id === id) {
        return this.profiles[index];
      }
    }
    return undefined;
  }

  private upsert(profile: Profile): void {
    for (let index = 0; index < this.profiles.length; index += 1) {
      if (this.profiles[index].id === profile.id) {
        this.profiles[index] = cloneProfile(profile);
        return;
      }
    }
    this.profiles.push(cloneProfile(profile));
  }
}

export class FakeProfileContentStore implements FixtureProfileContentStore {
  readonly operationLog: string[] = [];
  readonly retainedKinds: RevisionKind[] = [];
  readonly retainedStages: FixtureStagedSource[] = [];
  readonly removedRevisions: ProfileRevision[] = [];
  readonly discardedStages: FixtureStagedSource[] = [];
  readonly removedProfileIds: string[] = [];
  readonly reconcileCalls: ProfileRevision[][] = [];
  readonly scriptedRetainResults: ProfileRevision[] = [];
  readonly scriptedRetainFailures: ScriptedVoidFailure[] = [];
  readonly scriptedDiscardFailures: ScriptedVoidFailure[] = [];
  private readonly timeline?: FakeOperationTimeline;

  constructor(timeline?: FakeOperationTimeline) {
    this.timeline = timeline;
  }

  async retain(profileId: string, staged: FixtureStagedSource, kind: RevisionKind): Promise<ProfileRevision> {
    this.operationLog.push('retainRevision');
    this.timeline?.record('retainRevision');
    this.retainedKinds.push(kind);
    this.retainedStages.push(staged);
    const failure: ScriptedVoidFailure | undefined = this.scriptedRetainFailures.shift();
    if (failure !== undefined && failure.shouldReject && failure.error !== undefined) {
      throw failure.error;
    }
    const scripted: ProfileRevision | undefined = this.scriptedRetainResults.shift();
    if (scripted !== undefined) {
      return cloneRevision(scripted);
    }
    return createProfileRevision(
      `profiles/${profileId}/${kind === 'CURRENT' ? 'current' : 'failed'}/${staged.stagingId}.yaml`,
      staged.sha256Digest,
      staged.byteLength,
      staged.validatedAt
    );
  }

  async discard(staged: FixtureStagedSource): Promise<void> {
    this.operationLog.push('discardStage');
    this.timeline?.record('discardStage');
    this.discardedStages.push(staged);
    const failure: ScriptedVoidFailure | undefined = this.scriptedDiscardFailures.shift();
    if (failure !== undefined && failure.shouldReject && failure.error !== undefined) {
      throw failure.error;
    }
  }

  async removeRevision(revision: ProfileRevision): Promise<void> {
    this.operationLog.push('removeRevision');
    this.timeline?.record('removeRevision');
    this.removedRevisions.push(cloneRevision(revision));
  }

  async removeProfile(profileId: string): Promise<void> {
    this.operationLog.push('removeProfile');
    this.timeline?.record('removeProfile');
    this.removedProfileIds.push(profileId);
  }

  async reconcile(referenced: ProfileRevision[]): Promise<void> {
    this.operationLog.push('reconcileRevisions');
    this.timeline?.record('reconcileRevisions');
    const cloned: ProfileRevision[] = [];
    for (let index = 0; index < referenced.length; index += 1) {
      cloned.push(cloneRevision(referenced[index]));
    }
    this.reconcileCalls.push(cloned);
  }

  resolveCorePath(revision: ProfileRevision): string {
    this.operationLog.push('resolveCorePath');
    this.timeline?.record('resolveCorePath');
    return `/sandbox/${revision.relativePath}`;
  }
}

export class FakeProfileSourceGateway implements FixtureProfileSourceGateway {
  readonly operationLog: string[] = [];
  readonly localCommands: FixtureLocalAcquireCommand[] = [];
  readonly remoteCommands: SafeRemoteAcquireRecord[] = [];
  readonly localResults: FixtureLocalProfileAcquisition[] = [];
  readonly remoteResults: FixtureRemoteProfileAcquisition[] = [];
  readonly scriptedLocalAcquireFailures: ScriptedVoidFailure[] = [];
  readonly scriptedRemoteAcquireFailures: ScriptedVoidFailure[] = [];
  private readonly timeline?: FakeOperationTimeline;

  constructor(timeline?: FakeOperationTimeline) {
    this.timeline = timeline;
  }

  async acquireLocal(command: FixtureLocalAcquireCommand): Promise<FixtureLocalProfileAcquisition> {
    this.operationLog.push('acquire');
    this.timeline?.record('acquire');
    this.localCommands.push(command);
    const failure: ScriptedVoidFailure | undefined = this.scriptedLocalAcquireFailures.shift();
    if (failure !== undefined && failure.shouldReject && failure.error !== undefined) {
      throw failure.error;
    }
    const next: FixtureLocalProfileAcquisition | undefined = this.localResults.shift();
    if (next === undefined) {
      throw new Error('No scripted local acquisition result.');
    }
    return next;
  }

  async acquireRemote(command: FixtureRemoteAcquireCommand): Promise<FixtureRemoteProfileAcquisition> {
    this.operationLog.push('acquire');
    this.timeline?.record('acquire');
    this.remoteCommands.push(new SafeRemoteAcquireRecord(redactUrl(command.sourceDisplay), command.allowPlainHttp));
    const failure: ScriptedVoidFailure | undefined = this.scriptedRemoteAcquireFailures.shift();
    if (failure !== undefined && failure.shouldReject && failure.error !== undefined) {
      throw failure.error;
    }
    const next: FixtureRemoteProfileAcquisition | undefined = this.remoteResults.shift();
    if (next === undefined) {
      throw new Error('No scripted remote acquisition result.');
    }
    return next;
  }
}

export class FakeSubscriptionSecretStore implements FixtureSubscriptionSecretStore {
  encryptCallCount: number = 0;
  readonly decryptCalls: string[] = [];
  readonly removedRefs: string[] = [];
  readonly storedRefs: string[] = [];
  readonly scriptedEncryptResults: ScriptedStringFailure[] = [];
  readonly scriptedDecryptResults: ScriptedStringFailure[] = [];
  private readonly timeline?: FakeOperationTimeline;

  constructor(timeline?: FakeOperationTimeline) {
    this.timeline = timeline;
  }

  async encrypt(plaintext: string): Promise<string> {
    void plaintext;
    this.encryptCallCount += 1;
    this.timeline?.record('encryptSource');
    const scripted: ScriptedStringFailure | undefined = this.scriptedEncryptResults.shift();
    if (scripted !== undefined && scripted.shouldReject && scripted.error !== undefined) {
      throw scripted.error;
    }
    const ref: string = scripted?.value ?? `secret-${this.encryptCallCount}`;
    this.storedRefs.push(ref);
    return ref;
  }

  async decrypt(secretRef: string): Promise<string> {
    this.decryptCalls.push(secretRef);
    this.timeline?.record('decryptSource');
    const scripted: ScriptedStringFailure | undefined = this.scriptedDecryptResults.shift();
    if (scripted !== undefined && scripted.shouldReject && scripted.error !== undefined) {
      throw scripted.error;
    }
    return materializeDecryptScenario(scripted?.value);
  }

  async remove(secretRef: string): Promise<void> {
    this.timeline?.record('removeSecret');
    this.removedRefs.push(secretRef);
  }
}

class FixtureCoreError extends Error implements CoreError {
  name: 'CoreError' = 'CoreError';
  code: string;
  category: 'CoreError' | 'StateError' = 'CoreError';
  detail: string;
  retryable: boolean;
  action: string = 'Check the staged configuration.';
  context?: FixtureCoreErrorContext;

  constructor(code: string, detail: string, retryable: boolean) {
    super('Core failure.');
    this.code = code;
    this.detail = detail;
    this.retryable = retryable;
    this.context = new FixtureCoreErrorContextValue('validate', -1);
  }
}

class FixtureCoreErrorContextValue implements FixtureCoreErrorContext {
  operation: string;
  status: number;

  constructor(operation: string, status: number) {
    this.operation = operation;
    this.status = status;
  }
}

class FixtureSecretError extends Error {
  readonly code: SecretErrorCode;
  readonly detail: string;

  constructor(code: SecretErrorCode, detail: string) {
    super(detail);
    this.code = code;
    this.detail = detail;
  }
}

export class ProfileFixtureOptions {
  id?: string;
  name?: string;
  sourceKind?: 'LOCAL_FILE' | 'REMOTE_URL';
  sourceDisplay?: string;
  sourceSecretRef?: string;
  currentRevision?: ProfileRevision | null;
  failedCandidate?: ProfileRevision | null;
  availability?: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID';
  lastError?: AppError | null;
  createdAt?: string;
  updatedAt?: string;
  lastSuccessfulUpdateAt?: string | null;
}

class DeferredBox<T> implements Deferred<T> {
  promise: Promise<T>;
  private readonly resolveRef: (value: T) => void;
  private readonly rejectRef: (error: Error) => void;

  constructor(promise: Promise<T>, resolveRef: (value: T) => void, rejectRef: (error: Error) => void) {
    this.promise = promise;
    this.resolveRef = resolveRef;
    this.rejectRef = rejectRef;
  }

  resolve(value: T): void {
    this.resolveRef(value);
  }

  reject(error: Error): void {
    this.rejectRef(error);
  }
}

export function createDeferred<T>(): Deferred<T> {
  let resolveRef: ((value: T) => void) | undefined = undefined;
  let rejectRef: ((error: Error) => void) | undefined = undefined;
  const promise: Promise<T> = new Promise<T>((resolve, reject) => {
    resolveRef = resolve;
    rejectRef = reject;
  });
  return new DeferredBox<T>(
    promise,
    (value: T) => {
      resolveRef?.(value);
    },
    (error: Error) => {
      rejectRef?.(error);
    }
  );
}

export function expectThrowsMessage(block: () => void, expectedFragment: string): void {
  let didThrow: boolean = false;
  try {
    block();
  } catch (error) {
    didThrow = true;
    const message: string = error instanceof Error ? error.message : `${error}`;
    if (!message.includes(expectedFragment)) {
      throw new Error(`Expected "${message}" to include "${expectedFragment}".`);
    }
  }
  if (!didThrow) {
    throw new Error(`Expected block to throw "${expectedFragment}".`);
  }
}

export function buildCoreError(code: string, detail: string, retryable: boolean): Error {
  return new FixtureCoreError(code, detail, retryable);
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

export function buildStagedSource(stagingId: string, validationPath: string): FixtureStagedSource {
  return new FixtureStagedSourceValue(
    stagingId,
    validationPath,
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    128,
    '2026-08-07T00:00:00.000Z'
  );
}

export function buildRevision(relativePath: string, validatedAt: string): ProfileRevision {
  return createProfileRevision(
    relativePath,
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    128,
    validatedAt
  );
}

export function buildProfile(options?: ProfileFixtureOptions): Profile {
  return createProfile({
    id: options?.id ?? 'profile-1',
    name: options?.name ?? 'Profile 1',
    sourceKind: options?.sourceKind ?? 'LOCAL_FILE',
    sourceDisplay: options?.sourceDisplay ?? 'profile.yaml',
    sourceSecretRef: options?.sourceSecretRef,
    currentRevision: options?.currentRevision ?? null,
    failedCandidate: options?.failedCandidate ?? null,
    availability: options?.availability ?? 'INVALID',
    lastError: options?.lastError ?? null,
    createdAt: options?.createdAt ?? '2026-08-07T00:00:00.000Z',
    updatedAt: options?.updatedAt ?? '2026-08-07T00:00:00.000Z',
    lastSuccessfulUpdateAt: options?.lastSuccessfulUpdateAt ?? null
  });
}

export function buildSecretError(code: SecretErrorCode, detail: string): Error {
  return createSubscriptionSecretError(code, detail);
}

export function buildJsonStateSnapshot(parts: Object[]): string {
  return JSON.stringify(parts);
}

function cloneRevision(revision: ProfileRevision): ProfileRevision {
  return createProfileRevision(
    revision.relativePath,
    revision.sha256Digest,
    revision.byteLength,
    revision.validatedAt
  );
}

function cloneProfile(profile: Profile): Profile {
  return createProfile({
    id: profile.id,
    name: profile.name,
    sourceKind: profile.sourceKind,
    sourceDisplay: profile.sourceDisplay,
    sourceSecretRef: profile.sourceSecretRef,
    currentRevision: profile.currentRevision === null ? null : cloneRevision(profile.currentRevision),
    failedCandidate: profile.failedCandidate === null ? null : cloneRevision(profile.failedCandidate),
    availability: profile.availability,
    lastError: profile.lastError === null
      ? null
      : createAppError(profile.lastError.stage, profile.lastError.technicalDetail, {
        code: profile.lastError.code,
        retryable: profile.lastError.retryable,
        timestamp: profile.lastError.timestamp,
        userMessageResource: profile.lastError.userMessageResource
      }),
    createdAt: profile.createdAt,
    updatedAt: profile.updatedAt,
    lastSuccessfulUpdateAt: profile.lastSuccessfulUpdateAt
  });
}

function materializeDecryptScenario(scenario?: string): string {
  switch (scenario) {
    case 'HTTP_SUBSCRIPTION_CREDENTIALS':
      return buildFragmentedUrl('http', 'user', 'secret', 'plain.example.com', 'subscription', 'token=abc123');
    case 'HTTPS_SUBSCRIPTION_CREDENTIALS':
      return buildFragmentedUrl('https', 'user', 'secret', 'remote.example.com', 'path', 'token=abc123');
    case 'HTTPS_REMOTE_DEFAULT':
    default:
      return buildFragmentedUrl('https', 'user', 'secret', 'example.com', 'subscription', 'token=default');
  }
}

function buildFragmentedUrl(
  scheme: string,
  user: string,
  credentialValue: string,
  authority: string,
  pathSegment: string,
  query: string
): string {
  const userInfo: string = `${user}:${credentialValue}`;
  return `${scheme}://${userInfo}@${authority}/${pathSegment}?${query}`;
}
