import {
  createAppError,
  cloneOneClickVpnOperationSnapshot,
  createProfile,
  createProfileRevision,
  createProxyRuntimeNotReadyError,
  createOneClickVpnOperationSnapshot,
  createVpnRuntimeSnapshot,
  ImportProfileUseCase,
  LeasedRemoteProfileRefresher,
  LocalRuntimeCoordinator,
  ManageProfileUseCases,
  ProfileApplication,
  type ProfileApplicationDependencies,
  ProfileCommitService,
  RefreshProfileUseCase,
  SerialCommandQueue,
  type AppError,
  type AppErrorStage,
  type Clock,
  type CoreEvent,
  type CoreProxyDelaySnapshot,
  type CoreProxyGroupList,
  type CoreProxyGroupResult,
  type CoreProxyQueryContext,
  type CoreProxySelectionApplied,
  type CoreService,
  type IdGenerator,
  type LocalAcquireCommand,
  type LocalRuntimeCoordinatorSnapshot,
  type LocalRuntimeStartedResult,
  type LocalRuntimeStoppedResult,
  type LocalOptions,
  type LocalProfileAcquisition,
  type HomeProxySelectionSummary,
  type ManageDeleteResult,
  type ManageEnableResult,
  type ManageProfileFailedResult,
  type ManageReplaceResult,
  type ImportProfileResult,
  type LocalRuntimeStartResult,
  type LocalRuntimeStopResult,
  type Profile,
  type OneClickVpnConfirmationHandle,
  type OneClickVpnConfirmationPort,
  type OneClickVpnConfirmationResult,
  type OneClickVpnOperationListener,
  type OneClickVpnOperationSnapshot,
  type ProxyDelayResult,
  type ProxyReconcileResult,
  type ProxyApplicationPort,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyRejectedResult,
  type ProxySelectionResult,
  type RefreshAllSubscriptionsResult,
  type ProfileApplicationErrorSnapshot,
  type ProfileApplicationListener,
  type ProfileApplicationProfileSnapshot,
  type ProfileApplicationSnapshot,
  type ProfileApplicationRuntimeLatestSnapshot,
  type ProfileApplicationRuntimeSnapshot,
  type ProfileContentStore,
  type ProfileRefreshLeasePort,
  type ProfileRepository,
  type ProfileRevision,
  type ProfileSourceGateway,
  type RemoteImportCommand,
  type ProfileSourceKind,
  type RefreshProfileResult,
  type RefreshProfilesItemResult,
  type RefreshProfilesResult,
  type RemoteAcquireCommand,
  type RemoteProfileAcquisition,
  type RuntimeSnapshot,
  type StagedSource,
  type SubscriptionSecretStore,
  type UpdateProfileResult,
  type VpnControllerStartResult,
  type VpnControllerStopResult,
  type VpnRuntimeEvent,
  type VpnRuntimeSnapshot,
  redactUrl
} from '@cmfa/shared';
import { safeRemoteSourceDisplayFromUrl } from '../../main/ets/presentation/PresentationModels';
import {
  ProxyDelayScheduledTaskPort,
  ProxyDelaySchedulerPort
} from '../../main/ets/presentation/ProxyViewModel';

interface ApplicationSnapshotOptions {
  httpAddress?: string;
  socksAddress?: string;
  runtimeError?: ProfileApplicationErrorSnapshot | null;
  latestRuntimeError?: string;
  error?: ProfileApplicationErrorSnapshot | null;
}

interface ProfileSnapshotOptions {
  sourceKind?: ProfileSourceKind;
  lastError?: ProfileApplicationErrorSnapshot | null;
  autoUpdateIntervalMs?: number;
  lastSuccessfulUpdateAt?: string;
}

class DeferredCommand {
  readonly promise: Promise<void>;
  private resolveRef?: () => void;

  constructor() {
    this.promise = new Promise<void>((resolve) => {
      this.resolveRef = resolve;
    });
  }

  resolve(): void {
    this.resolveRef?.();
  }
}

class InertProfileRefreshLeasePort implements ProfileRefreshLeasePort {
  async tryAcquire(_profileId: string, _ownerToken: string, _nowMs: number, _expiresAtMs: number): Promise<boolean> {
    return true;
  }

  async renew(_profileId: string, _ownerToken: string, _nowMs: number, _expiresAtMs: number): Promise<boolean> {
    return true;
  }

  async release(_profileId: string, _ownerToken: string): Promise<boolean> {
    return true;
  }
}

export class DeferredResult<T> {
  readonly promise: Promise<T>;
  private resolveRef?: (value: T) => void;

  constructor() {
    this.promise = new Promise<T>((resolve) => {
      this.resolveRef = resolve;
    });
  }

  resolve(value: T): void {
    this.resolveRef?.(value);
  }
}

export class ManualScheduledTask extends ProxyDelayScheduledTaskPort {
  readonly delayMs: number;
  private readonly callback: () => void;
  private cancelledValue: boolean = false;
  private firedValue: boolean = false;

  constructor(delayMs: number, callback: () => void) {
    super();
    this.delayMs = delayMs;
    this.callback = callback;
  }

  get cancelled(): boolean {
    return this.cancelledValue;
  }

  get fired(): boolean {
    return this.firedValue;
  }

  cancel(): void {
    this.cancelledValue = true;
  }

  run(): void {
    if (this.cancelledValue || this.firedValue) {
      return;
    }
    this.firedValue = true;
    this.callback();
  }
}

export class ManualDelayScheduler extends ProxyDelaySchedulerPort {
  readonly tasks: ManualScheduledTask[] = [];

  constructor() {
    super();
  }

  schedule(delayMs: number, callback: () => void): ManualScheduledTask {
    const task = new ManualScheduledTask(delayMs, callback);
    this.tasks.push(task);
    return task;
  }

  pendingCount(): number {
    let count: number = 0;
    for (let index: number = 0; index < this.tasks.length; index += 1) {
      if (!this.tasks[index].cancelled && !this.tasks[index].fired) {
        count += 1;
      }
    }
    return count;
  }

  latest(): ManualScheduledTask | undefined {
    return this.tasks.length === 0 ? undefined : this.tasks[this.tasks.length - 1];
  }
}

export interface SafeRemoteImportRecord {
  sourceDisplay: string;
  allowPlainHttp: boolean;
  profileName: string;
}

export interface SafeRefreshRecord {
  profileId: string;
  allowPlainHttp: boolean;
}

export interface SafeReplaceRecord {
  profileId: string;
  sourceDisplay: string;
}

export interface SafeUpdateProfileRecord {
  profileId: string;
  name: string;
  sourceChanged: boolean;
  sourceDisplay?: string;
  allowPlainHttp: boolean;
}

class SafeRemoteImportRecordValue implements SafeRemoteImportRecord {
  sourceDisplay: string = '';
  allowPlainHttp: boolean = false;
  profileName: string = '';
}

class SafeRefreshRecordValue implements SafeRefreshRecord {
  profileId: string = '';
  allowPlainHttp: boolean = false;
}

class SafeReplaceRecordValue implements SafeReplaceRecord {
  profileId: string = '';
  sourceDisplay: string = '';
}

class SafeUpdateProfileRecordValue implements SafeUpdateProfileRecord {
  profileId: string = '';
  name: string = '';
  sourceChanged: boolean = false;
  sourceDisplay?: string;
  allowPlainHttp: boolean = false;
}

class FixedClock implements Clock {
  now(): string {
    return '2026-08-11T12:30:00.000Z';
  }
}

class FixedIdGenerator implements IdGenerator {
  nextId(): string {
    return 'generated-id';
  }
}

class InertRepository implements ProfileRepository {
  async list(): Promise<Profile[]> {
    return [];
  }

  async get(_id: string): Promise<Profile | undefined> {
    return undefined;
  }

  async save(_profile: Profile): Promise<void> {
  }

  async deleteAndClearActive(_id: string): Promise<void> {
  }

  async getActiveId(): Promise<string | undefined> {
    return undefined;
  }

  async setActiveId(_id: string | undefined): Promise<void> {
  }
}

class InertContentStore implements ProfileContentStore {
  async retain(_profileId: string, _staged: StagedSource, _kind: 'CURRENT' | 'FAILED_CANDIDATE'): Promise<ProfileRevision> {
    throw new Error('retain should stay unused in presentation tests');
  }

  async discard(_staged: StagedSource): Promise<void> {
  }

  async removeRevision(_revision: ProfileRevision): Promise<void> {
  }

  async removeProfile(_profileId: string): Promise<void> {
  }

  async reconcile(_referenced: ProfileRevision[]): Promise<void> {
  }

  resolveCorePath(revision: ProfileRevision): string {
    return revision.relativePath;
  }
}

class InertSourceGateway implements ProfileSourceGateway {
  async acquireLocal(_command: LocalAcquireCommand): Promise<LocalProfileAcquisition> {
    throw new Error('local acquire should stay unused in presentation tests');
  }

  async acquireRemote(_command: RemoteAcquireCommand): Promise<RemoteProfileAcquisition> {
    throw new Error('remote acquire should stay unused in presentation tests');
  }
}

class InertSecretStore implements SubscriptionSecretStore {
  async encrypt(_plaintext: string): Promise<string> {
    return 'secret-ref';
  }

  async decrypt(_secretRef: string): Promise<string> {
    return 'secret-value';
  }

  async remove(_secretRef: string): Promise<void> {
  }
}

class InertCoreService implements CoreService {
  hello(): string {
    return 'hello';
  }

  async coreVersion(): Promise<string> {
    return 'core';
  }

  async validateConfiguration(_path: string): Promise<void> {
  }

  async loadConfiguration(_path: string): Promise<void> {
  }

  async startLocal(_options: LocalOptions): Promise<RuntimeSnapshot> {
    return createRuntimeModel('STOPPED', '', '', '');
  }

  async stopRuntime(): Promise<RuntimeSnapshot> {
    return createRuntimeModel('STOPPED', '', '', '');
  }

  runtimeSnapshot(): RuntimeSnapshot {
    return createRuntimeModel('STOPPED', '', '', '');
  }

  async queryProxyGroups(_context: CoreProxyQueryContext, _selectableOnly: boolean): Promise<CoreProxyGroupList> {
    return await Promise.reject(createProxyRuntimeNotReadyError('queryProxyGroups'));
  }

  async queryProxyGroup(_context: CoreProxyQueryContext, _groupName: string): Promise<CoreProxyGroupResult> {
    return await Promise.reject(createProxyRuntimeNotReadyError('queryProxyGroup'));
  }

  async selectProxy(
    _context: CoreProxyQueryContext,
    _groupName: string,
    _memberName: string
  ): Promise<CoreProxySelectionApplied> {
    return await Promise.reject(createProxyRuntimeNotReadyError('selectProxy'));
  }

  async startProxyDelayTest(_context: CoreProxyQueryContext, _groupName: string): Promise<CoreProxyDelaySnapshot> {
    return await Promise.reject(createProxyRuntimeNotReadyError('startProxyDelayTest'));
  }

  async readProxyDelayTest(_jobId: string): Promise<CoreProxyDelaySnapshot> {
    return await Promise.reject(createProxyRuntimeNotReadyError('readProxyDelayTest'));
  }

  async cancelProxyDelayTest(_jobId: string): Promise<CoreProxyDelaySnapshot> {
    return await Promise.reject(createProxyRuntimeNotReadyError('cancelProxyDelayTest'));
  }

  subscribe(_callback: (event: CoreEvent) => void): number {
    return 1;
  }

  unsubscribe(_subscriptionId: number): void {
  }
}

class ProfileApplicationErrorSnapshotValue implements ProfileApplicationErrorSnapshot {
  code: string = '';
  stage: AppErrorStage = 'PERSISTENCE';
  userMessageResource: string = '';
  technicalDetail: string = '';
  timestamp: string = '';
  retryable: boolean = false;
}

class ProfileApplicationRuntimeLatestSnapshotValue implements ProfileApplicationRuntimeLatestSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR' = 'STOPPED';
  httpAddress: string = '';
  socksAddress: string = '';
  lastError: string = '';
  mixedPort: number = 0;
}

class ProfileApplicationRuntimeSnapshotValue implements ProfileApplicationRuntimeSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR' = 'STOPPED';
  latest: ProfileApplicationRuntimeLatestSnapshot = new ProfileApplicationRuntimeLatestSnapshotValue();
  lastError: ProfileApplicationErrorSnapshot | null = null;
}

class ProfileApplicationProfileSnapshotValue implements ProfileApplicationProfileSnapshot {
  id: string = '';
  name: string = '';
  sourceDisplay: string = '';
  sourceKind: ProfileSourceKind = 'LOCAL_FILE';
  availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID' = 'INVALID';
  updatedAt: string = '';
  autoUpdateIntervalMs: number = 0;
  lastSuccessfulUpdateAt?: string;
  hasCurrentRevision: boolean = false;
  sourceRepairRequired: boolean = false;
  lastError: ProfileApplicationErrorSnapshot | null = null;
}

class ProfileApplicationSnapshotValue implements ProfileApplicationSnapshot {
  status: 'LOADING' | 'READY' | 'ERROR' = 'LOADING';
  profiles: ProfileApplicationProfileSnapshot[] = [];
  activeProfileId?: string;
  runtime: ProfileApplicationRuntimeSnapshot = new ProfileApplicationRuntimeSnapshotValue();
  proxyReconciliation: ProxyReconcileResult | null = null;
  error: ProfileApplicationErrorSnapshot | null = null;
}

class LocalRuntimeCoordinatorSnapshotValue implements LocalRuntimeCoordinatorSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR' = 'STOPPED';
  latest: RuntimeSnapshot = createRuntimeModel('STOPPED', '', '', '');
  lastError: AppError | null = null;
}

class StartedResultValue implements LocalRuntimeStartedResult {
  kind: 'STARTED' = 'STARTED';
  snapshot: LocalRuntimeCoordinatorSnapshot = createCoordinatorSnapshot();
}

class StoppedResultValue implements LocalRuntimeStoppedResult {
  kind: 'STOPPED' = 'STOPPED';
  snapshot: LocalRuntimeCoordinatorSnapshot = createCoordinatorSnapshot();
}

export class PresentationTestApplication extends ProfileApplication {
  readonly commandLog: string[] = [];
  readonly importUrlCommands: SafeRemoteImportRecord[] = [];
  readonly refreshCommands: SafeRefreshRecord[] = [];
  readonly replaceCommands: SafeReplaceRecord[] = [];
  readonly updateProfileCommands: SafeUpdateProfileRecord[] = [];
  private readonly presentationListeners: Map<number, ProfileApplicationListener> = new Map();
  private nextPresentationListenerId: number = 0;
  private currentSnapshot: ProfileApplicationSnapshot;
  private startDeferred?: DeferredCommand;
  private stopDeferred?: DeferredCommand;
  private readonly importLocalResults: Promise<ImportProfileResult>[] = [];
  private readonly importUrlResults: Promise<ImportProfileResult>[] = [];
  private readonly refreshResults: Promise<RefreshProfileResult>[] = [];
  private readonly refreshAllSubscriptionsResults: Promise<RefreshAllSubscriptionsResult>[] = [];
  private readonly enableResults: Promise<ManageEnableResult>[] = [];
  private readonly deleteResults: Promise<ManageDeleteResult>[] = [];
  private readonly replaceResults: Promise<ManageReplaceResult>[] = [];
  private readonly updateProfileResults: Promise<UpdateProfileResult>[] = [];
  private readonly vpnStartResults: Promise<VpnControllerStartResult>[] = [];
  private readonly vpnStopResults: Promise<VpnControllerStopResult>[] = [];
  private readonly homeProxySelectionResults: Promise<HomeProxySelectionSummary | undefined>[] = [];
  private readonly oneClickListeners: Map<number, OneClickVpnOperationListener> = new Map();
  private nextOneClickListenerId: number = 0;
  private refreshAllSubscriptionsCalls: number = 0;
  private oneClickSnapshot: OneClickVpnOperationSnapshot = createOneClickVpnOperationSnapshot('IDLE', false, 'NONE');

  constructor(snapshot?: ProfileApplicationSnapshot) {
    super(createDependencies());
    this.currentSnapshot = cloneApplicationSnapshot(snapshot ?? createApplicationSnapshot('LOADING', [], undefined, 'STOPPED'));
  }

  async initialize(): Promise<void> {
  }

  current(): ProfileApplicationSnapshot {
    return cloneApplicationSnapshot(this.currentSnapshot);
  }

  subscribe(listener: ProfileApplicationListener): number {
    this.nextPresentationListenerId += 1;
    this.presentationListeners.set(this.nextPresentationListenerId, listener);
    return this.nextPresentationListenerId;
  }

  unsubscribe(id: number): void {
    this.presentationListeners.delete(id);
  }

  listenerCount(): number {
    return this.presentationListeners.size;
  }

  refreshAllSubscriptionsCallCount(): number {
    return this.refreshAllSubscriptionsCalls;
  }

  queueImportLocalResult(result: ImportProfileResult | Promise<ImportProfileResult>): void {
    this.importLocalResults.push(Promise.resolve(result));
  }

  queueImportUrlResult(result: ImportProfileResult | Promise<ImportProfileResult>): void {
    this.importUrlResults.push(Promise.resolve(result));
  }

  queueRefreshResult(result: RefreshProfileResult | Promise<RefreshProfileResult>): void {
    this.refreshResults.push(Promise.resolve(result));
  }

  queueRefreshAllSubscriptionsResult(result: RefreshAllSubscriptionsResult | Promise<RefreshAllSubscriptionsResult>): void {
    this.refreshAllSubscriptionsResults.push(Promise.resolve(result));
  }

  queueRefreshAllSubscriptionsRejection(): void {
    this.refreshAllSubscriptionsResults.push(Promise.reject(new Error('refresh-all rejected')));
  }

  queueEnableResult(result: ManageEnableResult | Promise<ManageEnableResult>): void {
    this.enableResults.push(Promise.resolve(result));
  }

  queueDeleteResult(result: ManageDeleteResult | Promise<ManageDeleteResult>): void {
    this.deleteResults.push(Promise.resolve(result));
  }

  queueReplaceResult(result: ManageReplaceResult | Promise<ManageReplaceResult>): void {
    this.replaceResults.push(Promise.resolve(result));
  }

  queueUpdateProfileResult(result: UpdateProfileResult | Promise<UpdateProfileResult>): void {
    this.updateProfileResults.push(Promise.resolve(result));
  }

  queueVpnStartResult(result: VpnControllerStartResult | Promise<VpnControllerStartResult>): void {
    this.vpnStartResults.push(Promise.resolve(result));
  }

  queueVpnStopResult(result: VpnControllerStopResult | Promise<VpnControllerStopResult>): void {
    this.vpnStopResults.push(Promise.resolve(result));
  }

  queueHomeProxySelectionResult(
    result: HomeProxySelectionSummary | Promise<HomeProxySelectionSummary | undefined> | undefined
  ): void {
    this.homeProxySelectionResults.push(Promise.resolve(result));
  }

  deferRefreshAllSubscriptions(): DeferredResult<RefreshAllSubscriptionsResult> {
    const deferred: DeferredResult<RefreshAllSubscriptionsResult> = new DeferredResult<RefreshAllSubscriptionsResult>();
    this.refreshAllSubscriptionsResults.push(deferred.promise);
    return deferred;
  }

  deferStart(): DeferredCommand {
    const deferred: DeferredCommand = new DeferredCommand();
    this.startDeferred = deferred;
    return deferred;
  }

  deferStop(): DeferredCommand {
    const deferred: DeferredCommand = new DeferredCommand();
    this.stopDeferred = deferred;
    return deferred;
  }

  async startLocal(): Promise<LocalRuntimeStartResult> {
    this.commandLog.push('startLocal');
    if (this.startDeferred !== undefined) {
      const deferred: DeferredCommand = this.startDeferred;
      this.startDeferred = undefined;
      await deferred.promise;
    }
    return new StartedResultValue();
  }

  async stopLocal(): Promise<LocalRuntimeStopResult> {
    this.commandLog.push('stopLocal');
    if (this.stopDeferred !== undefined) {
      const deferred: DeferredCommand = this.stopDeferred;
      this.stopDeferred = undefined;
      await deferred.promise;
    }
    return new StoppedResultValue();
  }

  async startVpnGlobalCapture(): Promise<VpnControllerStartResult> {
    this.commandLog.push('startVpnGlobalCapture');
    return await shiftOrDefault<VpnControllerStartResult>(this.vpnStartResults, {
      kind: 'STARTED',
      snapshot: createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: {
          profileId: this.currentSnapshot.activeProfileId ?? 'active',
          versionId: 'version-1',
          sessionId: 'session-1'
        },
        activeHandle: {
          sessionId: 'session-1',
          attached: true
        },
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      })
    });
  }

  async stopVpnGlobalCapture(): Promise<VpnControllerStopResult> {
    this.commandLog.push('stopVpnGlobalCapture');
    return await shiftOrDefault<VpnControllerStopResult>(this.vpnStopResults, {
      kind: 'STOPPED',
      snapshot: createVpnRuntimeSnapshot({
        state: 'STOPPED',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: false,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      })
    });
  }

  async queryHomeProxySelection(): Promise<HomeProxySelectionSummary | undefined> {
    this.commandLog.push('queryHomeProxySelection');
    return await shiftOrDefault<HomeProxySelectionSummary | undefined>(this.homeProxySelectionResults, undefined);
  }

  currentOneClickVpnOperation(): OneClickVpnOperationSnapshot {
    return cloneOneClickVpnOperationSnapshot(this.oneClickSnapshot);
  }

  subscribeOneClickVpnOperation(listener: OneClickVpnOperationListener): number {
    this.nextOneClickListenerId += 1;
    this.oneClickListeners.set(this.nextOneClickListenerId, listener);
    return this.nextOneClickListenerId;
  }

  unsubscribeOneClickVpnOperation(id: number): void {
    this.oneClickListeners.delete(id);
  }

  emitOneClickVpnOperation(snapshot: OneClickVpnOperationSnapshot): void {
    this.oneClickSnapshot = cloneOneClickVpnOperationSnapshot(snapshot);
    const listeners: OneClickVpnOperationListener[] = [];
    this.oneClickListeners.forEach((listener: OneClickVpnOperationListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneOneClickVpnOperationSnapshot(this.oneClickSnapshot));
    }
  }

  oneClickListenerCount(): number {
    return this.oneClickListeners.size;
  }

  async importLocal(command: LocalAcquireCommand): Promise<ImportProfileResult> {
    this.commandLog.push(`importLocal:${command.preferredName?.trim() ?? ''}`);
    return await shiftOrDefault<ImportProfileResult>(this.importLocalResults, createCancelledImportResult());
  }

  async importUrl(command: RemoteImportCommand): Promise<ImportProfileResult> {
    const safeSourceDisplay: string = safeRemoteSourceDisplayFromUrl(command.sourceUrl) ?? '';
    this.commandLog.push(`importUrl:${command.allowPlainHttp ? 'plain' : 'secure'}:${command.name}`);
    this.importUrlCommands.push(createSafeRemoteImportRecord(safeSourceDisplay, command.allowPlainHttp, command.name));
    return await shiftOrDefault<ImportProfileResult>(this.importUrlResults, createCancelledImportResult());
  }

  async refresh(profileId: string, allowPlainHttp?: boolean): Promise<RefreshProfileResult> {
    this.commandLog.push(`refresh:${profileId}:${allowPlainHttp === true ? 'plain' : 'secure'}`);
    this.refreshCommands.push(createSafeRefreshRecord(profileId, allowPlainHttp === true));
    return await shiftOrDefault<RefreshProfileResult>(this.refreshResults, createCancelledRefreshResult());
  }

  async refreshAllSubscriptions(): Promise<RefreshAllSubscriptionsResult> {
    this.commandLog.push('refreshAllSubscriptions');
    this.refreshAllSubscriptionsCalls += 1;
    return await shiftOrDefault<RefreshAllSubscriptionsResult>(
      this.refreshAllSubscriptionsResults,
      createRefreshAllSubscriptionsCompletedResult([])
    );
  }

  async enable(profileId: string): Promise<ManageEnableResult> {
    this.commandLog.push(`enable:${profileId}`);
    return await shiftOrDefault<ManageEnableResult>(this.enableResults, createEnabledResult(profileId));
  }

  async delete(profileId: string): Promise<ManageDeleteResult> {
    this.commandLog.push(`delete:${profileId}`);
    return await shiftOrDefault<ManageDeleteResult>(this.deleteResults, createDeletedResult(profileId));
  }

  async replaceSubscriptionUrl(profileId: string, sourceUrl: string): Promise<ManageReplaceResult> {
    this.commandLog.push(`replaceSubscriptionUrl:${profileId}`);
    this.replaceCommands.push(createSafeReplaceRecord(profileId, redactUrl(sourceUrl)));
    return await shiftOrDefault<ManageReplaceResult>(this.replaceResults, createReplacedResult(profileId));
  }

  async updateProfile(
    profileId: string,
    name: string,
    sourceUrl?: string,
    allowPlainHttp: boolean = false
  ): Promise<UpdateProfileResult> {
    this.commandLog.push(`updateProfile:${profileId}:${allowPlainHttp ? 'plain' : 'secure'}:${name}`);
    this.updateProfileCommands.push(
      createSafeUpdateProfileRecord(
        profileId,
        name,
        sourceUrl !== undefined && sourceUrl.trim().length > 0,
        sourceUrl === undefined ? undefined : safeRemoteSourceDisplayFromUrl(sourceUrl),
        allowPlainHttp
      )
    );
    return await shiftOrDefault<UpdateProfileResult>(this.updateProfileResults, createUpdatedProfileResult(profileId));
  }

  dispose(): void {
    this.presentationListeners.clear();
    this.oneClickListeners.clear();
  }

  emitSnapshot(snapshot: ProfileApplicationSnapshot): void {
    this.currentSnapshot = cloneApplicationSnapshot(snapshot);
    const listeners: ProfileApplicationListener[] = [];
    this.presentationListeners.forEach((listener: ProfileApplicationListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](this.current());
    }
  }
}


export function createApplicationSnapshot(
  status: 'LOADING' | 'READY' | 'ERROR',
  profiles: ProfileApplicationProfileSnapshot[],
  activeProfileId: string | undefined,
  runtimeState: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR',
  options?: ApplicationSnapshotOptions
): ProfileApplicationSnapshot {
  const snapshot: ProfileApplicationSnapshotValue = new ProfileApplicationSnapshotValue();
  snapshot.status = status;
  snapshot.profiles = cloneProfiles(profiles);
  snapshot.activeProfileId = activeProfileId;
  snapshot.runtime = createRuntimeSnapshot(
    runtimeState,
    options?.httpAddress ?? '',
    options?.socksAddress ?? '',
    options?.latestRuntimeError ?? '',
    options?.runtimeError ?? null
  );
  snapshot.proxyReconciliation = null;
  snapshot.error = options?.error ?? null;
  return snapshot;
}

export function createProfileSnapshot(
  id: string,
  name: string,
  sourceDisplay: string,
  availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID',
  updatedAt: string,
  hasCurrentRevision: boolean,
  options?: ProfileSnapshotOptions
): ProfileApplicationProfileSnapshot {
  const snapshot: ProfileApplicationProfileSnapshotValue = new ProfileApplicationProfileSnapshotValue();
  snapshot.id = id;
  snapshot.name = name;
  snapshot.sourceDisplay = sourceDisplay;
  snapshot.sourceKind = options?.sourceKind ?? inferSourceKind(sourceDisplay);
  snapshot.availability = availability;
  snapshot.updatedAt = updatedAt;
  snapshot.autoUpdateIntervalMs = options?.autoUpdateIntervalMs ?? 0;
  snapshot.lastSuccessfulUpdateAt = options?.lastSuccessfulUpdateAt;
  snapshot.hasCurrentRevision = hasCurrentRevision;
  snapshot.lastError = options?.lastError ?? null;
  snapshot.sourceRepairRequired = resolveSourceRepairRequired(snapshot.sourceKind, snapshot.lastError);
  return snapshot;
}

export function createRuntimeSnapshot(
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR',
  httpAddress: string,
  socksAddress: string,
  lastError: string,
  error: ProfileApplicationErrorSnapshot | null
): ProfileApplicationRuntimeSnapshot {
  const snapshot: ProfileApplicationRuntimeSnapshotValue = new ProfileApplicationRuntimeSnapshotValue();
  snapshot.state = state;
  snapshot.latest = createRuntimeLatestSnapshot(state, httpAddress, socksAddress, lastError);
  snapshot.lastError = error === null ? null : cloneError(error);
  return snapshot;
}

export function createSafeError(
  code: string,
  stage: 'IMPORT' | 'DOWNLOAD' | 'VALIDATION' | 'PERSISTENCE' | 'CORE_LOAD' | 'RUNTIME_START' | 'RUNTIME_STOP',
  technicalDetail: string
): ProfileApplicationErrorSnapshot {
  const snapshot: ProfileApplicationErrorSnapshotValue = new ProfileApplicationErrorSnapshotValue();
  snapshot.code = code;
  snapshot.stage = stage;
  snapshot.userMessageResource = `error.${stage.toLowerCase()}`;
  snapshot.technicalDetail = technicalDetail;
  snapshot.timestamp = '2026-08-11T12:30:00.000Z';
  snapshot.retryable = false;
  return snapshot;
}

class InertProxyApplicationPort implements ProxyApplicationPort {
  async listGroups(): Promise<ProxyGroupListQueryResult> {
    throw createProxyRuntimeNotReadyError('listGroups');
  }

  async queryGroup(_groupName: string, _groupPath?: string[]): Promise<ProxyGroupQueryResult> {
    throw createProxyRuntimeNotReadyError('queryGroup');
  }

  async select(
    _groupName: string,
    _memberName: string,
    _snapshotGeneration: number,
    _groupPath?: string[]
  ): Promise<ProxySelectionResult> {
    throw createProxyRuntimeNotReadyError('select');
  }

  async reconcileActiveSelections(): Promise<ProxyReconcileResult> {
    throw createProxyRuntimeNotReadyError('reconcileActiveSelections');
  }

  async startDelayTest(_groupName: string, _snapshotGeneration: number, _groupPath?: string[]): Promise<ProxyDelayResult> {
    throw createProxyRuntimeNotReadyError('startDelayTest');
  }

  async readDelayTest(_jobId: string): Promise<ProxyDelayResult> {
    throw createProxyRuntimeNotReadyError('readDelayTest');
  }

  async cancelDelayTest(_jobId: string): Promise<ProxyDelayResult> {
    throw createProxyRuntimeNotReadyError('cancelDelayTest');
  }

  async cancelAndDrainDelayTest(): Promise<ProxyRejectedResult | undefined> {
    return undefined;
  }
}

class CancelledOneClickVpnConfirmationResultValue implements OneClickVpnConfirmationResult {
  kind: 'CANCELLED' = 'CANCELLED';
}

class InertOneClickVpnConfirmationHandle implements OneClickVpnConfirmationHandle {
  async wait(): Promise<OneClickVpnConfirmationResult> {
    return new CancelledOneClickVpnConfirmationResultValue();
  }

  markStartAccepted(): void {
  }

  cancel(): void {
  }
}

class InertOneClickVpnConfirmation implements OneClickVpnConfirmationPort {
  arm(_expectedSessionId: string, _timeoutMs: number): OneClickVpnConfirmationHandle {
    return new InertOneClickVpnConfirmationHandle();
  }
}

function createDependencies(): ProfileApplicationDependencies {
  const repository: InertRepository = new InertRepository();
  const contentStore: InertContentStore = new InertContentStore();
  const sourceGateway: InertSourceGateway = new InertSourceGateway();
  const secretStore: InertSecretStore = new InertSecretStore();
  const coreService: InertCoreService = new InertCoreService();
  const clock: FixedClock = new FixedClock();
  const runtimeCoordinator = new LocalRuntimeCoordinator({
    repository,
    contentStore,
    coreService,
    clock
  });
  const commitService = new ProfileCommitService({
    repository,
    contentStore,
    clock
  });
  const queue = new SerialCommandQueue();
  const importUseCase = new ImportProfileUseCase({
    repository,
    contentStore,
    sourceGateway,
    secretStore,
    coreService,
    clock,
    idGenerator: new FixedIdGenerator(),
    queue,
    commitService
  });
  const refreshUseCase = new RefreshProfileUseCase({
    repository,
    contentStore,
    sourceGateway,
    secretStore,
    coreService,
    clock,
    queue,
    commitService,
    leasedRemoteRefresher: createLeasedRemoteProfileRefresher(
      new InertProfileRefreshLeasePort(),
      clock,
      new FixedIdGenerator()
    )
  });
  const manageProfileUseCases = new ManageProfileUseCases({
    repository,
    contentStore,
    secretStore,
    coreService,
    clock,
    runtimeCoordinator
  });
  return {
    importUseCase,
    refreshUseCase,
    manageProfileUseCases,
    runtimeCoordinator,
    commitService,
    repository,
    oneClickVpnConfirmation: new InertOneClickVpnConfirmation(),
    proxyService: new InertProxyApplicationPort()
  };
}

function createLeasedRemoteProfileRefresher(
  leasePort: ProfileRefreshLeasePort,
  clock: Clock,
  idGenerator: IdGenerator
): LeasedRemoteProfileRefresher {
  return new LeasedRemoteProfileRefresher({
    leasePort,
    clock,
    idGenerator
  });
}

function createRuntimeLatestSnapshot(
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR',
  httpAddress: string,
  socksAddress: string,
  lastError: string
): ProfileApplicationRuntimeLatestSnapshot {
  const snapshot: ProfileApplicationRuntimeLatestSnapshotValue = new ProfileApplicationRuntimeLatestSnapshotValue();
  snapshot.state = state;
  snapshot.httpAddress = httpAddress;
  snapshot.socksAddress = socksAddress;
  snapshot.lastError = lastError;
  snapshot.mixedPort = state === 'RUNNING' ? 7890 : 0;
  return snapshot;
}

function createRuntimeModel(
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR',
  httpAddress: string,
  socksAddress: string,
  lastError: string
): RuntimeSnapshot {
  return {
    state,
    activeConfigPath: '',
    httpAddress,
    socksAddress,
    lastError,
    mixedPort: state === 'RUNNING' ? 7890 : 0
  };
}

function cloneApplicationSnapshot(snapshot: ProfileApplicationSnapshot): ProfileApplicationSnapshot {
  const cloned: ProfileApplicationSnapshotValue = new ProfileApplicationSnapshotValue();
  cloned.status = snapshot.status;
  cloned.profiles = cloneProfiles(snapshot.profiles);
  cloned.activeProfileId = snapshot.activeProfileId;
  cloned.runtime = createRuntimeSnapshot(
    snapshot.runtime.state,
    snapshot.runtime.latest.httpAddress,
    snapshot.runtime.latest.socksAddress,
    snapshot.runtime.latest.lastError,
    snapshot.runtime.lastError
  );
  cloned.proxyReconciliation = snapshot.proxyReconciliation;
  cloned.error = snapshot.error === null ? null : cloneError(snapshot.error);
  return cloned;
}

function createCoordinatorSnapshot(): LocalRuntimeCoordinatorSnapshot {
  const snapshot: LocalRuntimeCoordinatorSnapshotValue = new LocalRuntimeCoordinatorSnapshotValue();
  snapshot.state = 'STOPPED';
  snapshot.latest = createRuntimeModel('STOPPED', '', '', '');
  snapshot.lastError = null;
  return snapshot;
}

function cloneProfiles(profiles: ProfileApplicationProfileSnapshot[]): ProfileApplicationProfileSnapshot[] {
  const cloned: ProfileApplicationProfileSnapshot[] = [];
  for (let index: number = 0; index < profiles.length; index += 1) {
    cloned.push(
      createProfileSnapshot(
        profiles[index].id,
        profiles[index].name,
        profiles[index].sourceDisplay,
        profiles[index].availability,
        profiles[index].updatedAt,
        profiles[index].hasCurrentRevision,
        {
          sourceKind: (profiles[index] as ProfileApplicationProfileSnapshotValue).sourceKind,
          lastError: (profiles[index] as ProfileApplicationProfileSnapshotValue).lastError,
          autoUpdateIntervalMs: (profiles[index] as ProfileApplicationProfileSnapshotValue).autoUpdateIntervalMs,
          lastSuccessfulUpdateAt: (profiles[index] as ProfileApplicationProfileSnapshotValue).lastSuccessfulUpdateAt
        }
      )
    );
  }
  return cloned;
}

function cloneError(error: ProfileApplicationErrorSnapshot): ProfileApplicationErrorSnapshot {
  return createSafeError(error.code, error.stage, error.technicalDetail);
}

function inferSourceKind(sourceDisplay: string): ProfileSourceKind {
  const trimmed: string = sourceDisplay.trim();
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return 'REMOTE_URL';
  }
  return 'LOCAL_FILE';
}

function resolveSourceRepairRequired(
  sourceKind: ProfileSourceKind,
  lastError: ProfileApplicationErrorSnapshot | null
): boolean {
  if (sourceKind !== 'REMOTE_URL' || lastError === null) {
    return false;
  }
  return lastError.code === 'SOURCE_SECRET_MISSING' ||
    lastError.code === 'SOURCE_DECRYPT_FAILED' ||
    lastError.code === 'SOURCE_SECRET_VERSION_UNSUPPORTED';
}

function createProfileRecord(
  profileId: string,
  sourceKind: ProfileSourceKind = 'REMOTE_URL',
  availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID' = 'VALID'
): Profile {
  return createProfile({
    id: profileId,
    name: `Profile ${profileId}`,
    sourceKind,
    sourceDisplay: sourceKind === 'REMOTE_URL'
      ? `https://${profileId}.example.com/subscription.yaml`
      : `${profileId}.yaml`,
    sourceSecretRef: sourceKind === 'REMOTE_URL' ? `secret-${profileId}` : undefined,
    currentRevision: availability === 'INVALID'
      ? null
      : createProfileRevision(`profiles/${profileId}.yaml`, repeatDigest(profileId), 256, '2026-08-11T12:30:00.000Z'),
    failedCandidate: null,
    availability,
    lastError: null,
    createdAt: '2026-08-11T12:30:00.000Z',
    updatedAt: '2026-08-11T12:30:00.000Z',
    lastSuccessfulUpdateAt: availability === 'INVALID' ? null : '2026-08-11T12:30:00.000Z',
    autoUpdateIntervalMs: 0
  });
}

function repeatDigest(seed: string): string {
  let digest: string = '';
  while (digest.length < 64) {
    digest += seed;
  }
  return digest.substring(0, 64).replace(/[^0-9a-f]/gi, 'a');
}

function createSafeRemoteImportRecord(
  sourceDisplay: string,
  allowPlainHttp: boolean,
  profileName: string
): SafeRemoteImportRecord {
  const record: SafeRemoteImportRecordValue = new SafeRemoteImportRecordValue();
  record.sourceDisplay = sourceDisplay;
  record.allowPlainHttp = allowPlainHttp;
  record.profileName = profileName;
  return record;
}

function createSafeRefreshRecord(profileId: string, allowPlainHttp: boolean): SafeRefreshRecord {
  const record: SafeRefreshRecordValue = new SafeRefreshRecordValue();
  record.profileId = profileId;
  record.allowPlainHttp = allowPlainHttp;
  return record;
}

function createSafeReplaceRecord(profileId: string, sourceDisplay: string): SafeReplaceRecord {
  const record: SafeReplaceRecordValue = new SafeReplaceRecordValue();
  record.profileId = profileId;
  record.sourceDisplay = sourceDisplay;
  return record;
}

function createSafeUpdateProfileRecord(
  profileId: string,
  name: string,
  sourceChanged: boolean,
  sourceDisplay: string | undefined,
  allowPlainHttp: boolean
): SafeUpdateProfileRecord {
  const record: SafeUpdateProfileRecordValue = new SafeUpdateProfileRecordValue();
  record.profileId = profileId;
  record.name = name;
  record.sourceChanged = sourceChanged;
  record.sourceDisplay = sourceDisplay;
  record.allowPlainHttp = allowPlainHttp;
  return record;
}

function shiftOrDefault<T>(results: Promise<T>[], fallback: T): Promise<T> {
  if (results.length === 0) {
    return Promise.resolve(fallback);
  }
  const next: Promise<T> | undefined = results.shift();
  return next === undefined ? Promise.resolve(fallback) : next;
}

export function createCancelledImportResult(): ImportProfileResult {
  return {
    kind: 'CANCELLED'
  };
}

export function createCreatedImportResult(profileId: string, sourceKind: ProfileSourceKind = 'REMOTE_URL'): ImportProfileResult {
  return {
    kind: 'CREATED',
    profile: createProfileRecord(profileId, sourceKind)
  };
}

export function createFailedImportResult(
  code: string,
  stage: AppErrorStage,
  technicalDetail: string
): ImportProfileResult {
  return {
    kind: 'FAILED',
    error: createAppError(stage, technicalDetail, {
      code,
      retryable: false,
      timestamp: '2026-08-11T12:30:00.000Z'
    })
  };
}

export function createCancelledRefreshResult(): RefreshProfileResult {
  return {
    kind: 'CANCELLED'
  };
}

export function createUpdatedRefreshResult(profileId: string, sourceKind: ProfileSourceKind = 'REMOTE_URL'): RefreshProfileResult {
  return {
    kind: 'UPDATED',
    profile: createProfileRecord(profileId, sourceKind)
  };
}

export function createFailedRefreshResult(
  code: string,
  stage: AppErrorStage,
  technicalDetail: string
): RefreshProfileResult {
  return {
    kind: 'FAILED',
    error: createAppError(stage, technicalDetail, {
      code,
      retryable: false,
      timestamp: '2026-08-11T12:30:00.000Z'
    })
  };
}

export function createRefreshAllSubscriptionsCompletedResult(
  items: RefreshProfilesItemResult[],
  deadlineReached: boolean = false,
  cancelled: boolean = false,
  remainingCount: number = 0
): RefreshAllSubscriptionsResult {
  const result: RefreshProfilesResult = {
    items: items.map((item: RefreshProfilesItemResult): RefreshProfilesItemResult => ({
      profileId: item.profileId,
      status: item.status
    })),
    deadlineReached,
    cancelled,
    remainingCount
  };
  return {
    kind: 'COMPLETED',
    result
  };
}

export function createFailedRefreshAllSubscriptionsResult(
  code: string,
  stage: AppErrorStage,
  technicalDetail: string
): RefreshAllSubscriptionsResult {
  return {
    kind: 'FAILED',
    error: createAppError(stage, technicalDetail, {
      code,
      retryable: false,
      timestamp: '2026-08-11T12:30:00.000Z'
    })
  };
}

export function createEnabledResult(profileId: string): ManageEnableResult {
  return {
    kind: 'ENABLED',
    profile: createProfileRecord(profileId, 'REMOTE_URL', 'VALID')
  };
}

export function createDeletedResult(profileId: string): ManageDeleteResult {
  return {
    kind: 'DELETED',
    profileId
  };
}

export function createReplacedResult(profileId: string): ManageReplaceResult {
  return {
    kind: 'REPLACED',
    profile: createProfileRecord(profileId, 'REMOTE_URL', 'VALID')
  };
}

export function createUpdatedProfileResult(
  profileId: string,
  sourceKind: ProfileSourceKind = 'REMOTE_URL'
): UpdateProfileResult {
  return {
    kind: 'UPDATED',
    profile: createProfileRecord(profileId, sourceKind, 'VALID')
  };
}

export function createUpdatedProfileRefreshFailedResult(
  profileId: string,
  code: string,
  stage: AppErrorStage,
  technicalDetail: string,
  sourceKind: ProfileSourceKind = 'REMOTE_URL'
): UpdateProfileResult {
  return {
    kind: 'UPDATED_REFRESH_FAILED',
    profile: createProfileRecord(profileId, sourceKind, 'VALID'),
    error: createAppError(stage, technicalDetail, {
      code,
      retryable: false,
      timestamp: '2026-08-11T12:30:00.000Z'
    })
  };
}

export function createFailedUpdateResult(
  code: string,
  stage: AppErrorStage,
  technicalDetail: string
): UpdateProfileResult {
  return {
    kind: 'FAILED',
    error: createAppError(stage, technicalDetail, {
      code,
      retryable: false,
      timestamp: '2026-08-11T12:30:00.000Z'
    })
  };
}

export function createFailedManageResult(
  code: string,
  stage: AppErrorStage,
  technicalDetail: string
): ManageProfileFailedResult {
  return {
    kind: 'FAILED',
    error: createAppError(stage, technicalDetail, {
      code,
      retryable: false,
      timestamp: '2026-08-11T12:30:00.000Z'
    })
  };
}
