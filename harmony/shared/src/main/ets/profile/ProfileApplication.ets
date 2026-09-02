import { createAppError, type AppError, type AppErrorStage } from './AppErrors';
import type { ImportProfileResult, ImportProfileUseCase, RemoteImportCommand } from './ImportProfileUseCase';
import type {
  LocalRuntimeCoordinator,
  LocalRuntimeCoordinatorListener,
  LocalRuntimeCoordinatorSnapshot
} from './LocalRuntimeCoordinator';
import {
  createManageProfileFailedResult,
  type ManageDeleteResult,
  type ManageEnableResult,
  type ManageProfileUseCases,
  type ManageReplaceResult,
  type ManageUpdateResult
} from './ManageProfileUseCases';
import type { ProfileCommitService } from './ProfileCommitService';
import type {
  IdGenerator,
  LocalAcquireCommand,
  ProfileRefreshSchedulePort,
  ProfileRepository
} from './ProfilePorts';
import { createProfile, type Profile, type ProfileAvailability, type ProfileSourceKind } from './ProfileModels';
import type {
  RefreshProfileFailedResult,
  RefreshProfileResult,
  RefreshProfileUseCase
} from './RefreshProfileUseCase';
import type { RefreshProfilesItemResult, RefreshProfilesResult, RefreshProfilesUseCase } from './RefreshProfilesUseCase';
import { redactSensitiveText } from './SecretRedactor';
import {
  createVpnFailure,
  createVpnRuntimeSnapshot,
  type VpnFailure,
  type VpnControllerStartResult,
  type VpnControllerStopResult,
  type VpnRuntimeSnapshot,
  type VpnRuntimeState
} from '../vpn/VpnModels';
import type { OneClickVpnConfirmationHandle, OneClickVpnConfirmationPort, VpnControllerPort } from '../vpn/VpnPorts';
import type { OneClickVpnConfirmationResult } from '../vpn/VpnPorts';
import type { CoreProxyGroupSnapshot, CoreProxyNodeSummary } from '../core/CoreProxyModels';
import {
  cloneProxyDelayResult,
  type ProxyDelayResult
} from '../proxy/ProxyDelayModels';
import {
  cloneProxyGroupListQueryResult,
  cloneProxyGroupQueryResult,
  cloneProxyReconcileResult,
  cloneProxySelectionResult,
  createProxyRejectedError,
  createProxyRejectedResult,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyRejectedResult,
  type ProxyReconcileResult,
  type ProxyRuntimeIdentity,
  type ProxySelectionResult
} from '../proxy/ProxyModels';
import {
  cloneOneClickVpnOperationSnapshot,
  createOneClickVpnFailureResult,
  createSelectNodeAndEnsureVpnSuccessResult,
  createOneClickVpnOperationSnapshot,
  type OneClickVpnOperationSnapshot,
  type SelectNodeAndEnsureVpnResult
} from '../proxy/ProxyOneClickVpnModels';
import type {
  OneClickVpnOperationListener,
  ProxyApplicationPort,
  ProxyOneClickVpnApplicationPort
} from '../proxy/ProxyPorts';

export interface ProfileApplicationDependencies {
  importUseCase: ImportProfileUseCase;
  refreshUseCase: RefreshProfileUseCase;
  refreshProfilesUseCase?: RefreshProfilesUseCase;
  profileRefreshSchedule?: ProfileRefreshSchedulePort;
  manageProfileUseCases: ManageProfileUseCases;
  runtimeCoordinator: LocalRuntimeCoordinator;
  commitService: ProfileCommitService;
  repository: ProfileRepository;
  oneClickVpnConfirmation: OneClickVpnConfirmationPort;
  proxyService: ProxyApplicationPort;
  vpnController?: VpnControllerPort;
  idGenerator?: IdGenerator;
}

export interface ProfileApplicationSnapshot {
  status: 'LOADING' | 'READY' | 'ERROR';
  profiles: ProfileApplicationProfileSnapshot[];
  activeProfileId?: string;
  runtime: ProfileApplicationRuntimeSnapshot;
  proxyReconciliation: ProxyReconcileResult | null;
  error: ProfileApplicationErrorSnapshot | null;
}

export interface ProfileApplicationProfileSnapshot {
  id: string;
  name: string;
  sourceDisplay: string;
  sourceKind: ProfileSourceKind;
  availability: ProfileAvailability;
  updatedAt: string;
  autoUpdateIntervalMs: number;
  lastSuccessfulUpdateAt?: string;
  hasCurrentRevision: boolean;
  currentRevisionVersionId?: string;
  sourceRepairRequired: boolean;
  lastError: ProfileApplicationErrorSnapshot | null;
}

export interface ProfileApplicationRuntimeSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
  latest: ProfileApplicationRuntimeLatestSnapshot;
  lastError: ProfileApplicationErrorSnapshot | null;
}

export interface ProfileApplicationRuntimeLatestSnapshot {
  state: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
  httpAddress: string;
  socksAddress: string;
  lastError: string;
  mixedPort: number;
}

export interface ProfileApplicationErrorSnapshot {
  code: string;
  stage: AppErrorStage;
  userMessageResource: string;
  technicalDetail: string;
  timestamp: string;
  retryable: boolean;
}

export interface HomeProxySelectionSummary {
  groupName: string;
  nodeName: string;
}

export interface UpdateProfileUpdatedResult {
  kind: 'UPDATED';
  profile: Profile;
}

export interface UpdateProfileRefreshFailedResult {
  kind: 'UPDATED_REFRESH_FAILED';
  profile: Profile;
  error: AppError;
}

export interface UpdateProfileFailedResult {
  kind: 'FAILED';
  error: AppError;
}

export type UpdateProfileResult =
  | UpdateProfileUpdatedResult
  | UpdateProfileRefreshFailedResult
  | UpdateProfileFailedResult;

export interface RefreshAllSubscriptionsCompletedResult {
  kind: 'COMPLETED';
  result: RefreshProfilesResult;
}

export interface RefreshAllSubscriptionsFailedResult {
  kind: 'FAILED';
  error: AppError;
}

export type RefreshAllSubscriptionsResult =
  | RefreshAllSubscriptionsCompletedResult
  | RefreshAllSubscriptionsFailedResult;

export const PROFILE_AUTO_UPDATE_INTERVAL_PRESET_MS: readonly number[] = [
  0,
  2 * 60 * 60 * 1000,
  6 * 60 * 60 * 1000,
  12 * 60 * 60 * 1000,
  24 * 60 * 60 * 1000,
  7 * 24 * 60 * 60 * 1000
];

export type ProfileApplicationListener = (snapshot: ProfileApplicationSnapshot) => void;
type AppRuntimeMutationOwner = 'NONE' | 'ONE_CLICK' | 'VPN' | 'PROFILE_EDIT';

class RefreshFailedResultValue implements RefreshProfileFailedResult {
  kind: 'FAILED' = 'FAILED';
  error: AppError;

  constructor(error: AppError) {
    this.error = error;
  }
}

class UpdateProfileUpdatedResultValue implements UpdateProfileUpdatedResult {
  kind: 'UPDATED' = 'UPDATED';
  profile: Profile;

  constructor(profile: Profile) {
    this.profile = profile;
  }
}

class UpdateProfileRefreshFailedResultValue implements UpdateProfileRefreshFailedResult {
  kind: 'UPDATED_REFRESH_FAILED' = 'UPDATED_REFRESH_FAILED';
  profile: Profile;
  error: AppError;

  constructor(profile: Profile, error: AppError) {
    this.profile = profile;
    this.error = error;
  }
}

class UpdateProfileFailedResultValue implements UpdateProfileFailedResult {
  kind: 'FAILED' = 'FAILED';
  error: AppError;

  constructor(error: AppError) {
    this.error = error;
  }
}

class RefreshAllSubscriptionsCompletedResultValue implements RefreshAllSubscriptionsCompletedResult {
  kind: 'COMPLETED' = 'COMPLETED';
  result: RefreshProfilesResult;

  constructor(result: RefreshProfilesResult) {
    this.result = cloneRefreshProfilesResult(result);
  }
}

class RefreshAllSubscriptionsFailedResultValue implements RefreshAllSubscriptionsFailedResult {
  kind: 'FAILED' = 'FAILED';
  error: AppError;

  constructor(error: AppError) {
    this.error = error;
  }
}

export class ProfileApplication implements ProxyOneClickVpnApplicationPort {
  private readonly importUseCase: ImportProfileUseCase;
  private readonly refreshUseCase: RefreshProfileUseCase;
  private readonly refreshProfilesUseCase?: RefreshProfilesUseCase;
  private readonly profileRefreshSchedule?: ProfileRefreshSchedulePort;
  private readonly manageProfileUseCases: ManageProfileUseCases;
  private readonly runtimeCoordinator: LocalRuntimeCoordinator;
  private readonly commitService: ProfileCommitService;
  private readonly repository: ProfileRepository;
  private readonly oneClickVpnConfirmation: OneClickVpnConfirmationPort;
  private readonly proxyService: ProxyApplicationPort;
  private readonly vpnController?: VpnControllerPort;
  private readonly idGenerator?: IdGenerator;
  private readonly runtimeListener: LocalRuntimeCoordinatorListener;
  private readonly listeners: Map<number, ProfileApplicationListener> = new Map();
  private readonly oneClickVpnOperationListeners: Map<number, OneClickVpnOperationListener> = new Map();
  private initializePromise?: Promise<void>;
  private nextListenerId: number = 0;
  private nextOneClickVpnOperationListenerId: number = 0;
  private runtimeSubscriptionId: number;
  private disposed: boolean = false;
  private closed: boolean = false;
  private closePromise?: Promise<void>;
  private runtimeMutationOwner: AppRuntimeMutationOwner = 'NONE';
  private oneClickVpnOperationSnapshot: OneClickVpnOperationSnapshot = createOneClickVpnOperationSnapshot('IDLE', false, 'NONE');
  private snapshot: ProfileApplicationSnapshot = createProfileApplicationSnapshot(
    'LOADING',
    [],
    undefined,
    createProfileApplicationRuntimeSnapshot(thisRuntimeStoppedSnapshot()),
    null,
    null
  );

  constructor(dependencies: ProfileApplicationDependencies) {
    this.importUseCase = dependencies.importUseCase;
    this.refreshUseCase = dependencies.refreshUseCase;
    this.refreshProfilesUseCase = dependencies.refreshProfilesUseCase;
    this.profileRefreshSchedule = dependencies.profileRefreshSchedule;
    this.manageProfileUseCases = dependencies.manageProfileUseCases;
    this.runtimeCoordinator = dependencies.runtimeCoordinator;
    this.commitService = dependencies.commitService;
    this.repository = dependencies.repository;
    this.oneClickVpnConfirmation = dependencies.oneClickVpnConfirmation;
    this.proxyService = dependencies.proxyService;
    this.vpnController = dependencies.vpnController;
    this.idGenerator = dependencies.idGenerator;
    this.runtimeListener = (runtimeSnapshot: LocalRuntimeCoordinatorSnapshot): void => {
      this.publish(
        createProfileApplicationSnapshot(
          this.snapshot.status,
          this.snapshot.profiles,
          this.snapshot.activeProfileId,
          createProfileApplicationRuntimeSnapshot(runtimeSnapshot),
          this.snapshot.proxyReconciliation,
          this.snapshot.error
        )
      );
    };
    this.runtimeSubscriptionId = this.runtimeCoordinator.subscribe(this.runtimeListener);
  }

  initialize(): Promise<void> {
    if (this.initializePromise !== undefined) {
      return this.initializePromise;
    }
    const initializePromise: Promise<void> = this.initializeInternal();
    this.initializePromise = initializePromise;
    return initializePromise;
  }

  current(): ProfileApplicationSnapshot {
    return cloneProfileApplicationSnapshot(this.snapshot);
  }

  subscribe(listener: ProfileApplicationListener): number {
    this.nextListenerId += 1;
    this.listeners.set(this.nextListenerId, listener);
    return this.nextListenerId;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  currentOneClickVpnOperation(): OneClickVpnOperationSnapshot {
    return cloneOneClickVpnOperationSnapshot(this.oneClickVpnOperationSnapshot);
  }

  subscribeOneClickVpnOperation(listener: OneClickVpnOperationListener): number {
    this.nextOneClickVpnOperationListenerId += 1;
    this.oneClickVpnOperationListeners.set(this.nextOneClickVpnOperationListenerId, listener);
    return this.nextOneClickVpnOperationListenerId;
  }

  unsubscribeOneClickVpnOperation(id: number): void {
    this.oneClickVpnOperationListeners.delete(id);
  }

  async importLocal(command: LocalAcquireCommand): Promise<ImportProfileResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const result: ImportProfileResult = await this.importUseCase.executeLocal(command);
    await this.refreshSnapshotFromRepository(undefined);
    return result;
  }

  async importUrl(command: RemoteImportCommand): Promise<ImportProfileResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const result: ImportProfileResult = await this.importUseCase.executeRemote(command);
    await this.refreshSnapshotFromRepository(undefined);
    return result;
  }

  async refresh(profileId: string, allowPlainHttp: boolean = false): Promise<RefreshProfileResult> {
    try {
      if (this.snapshot.status !== 'READY') {
        await this.initialize();
      }
      const drainError: AppError | undefined = await this.requireDelayDrainAppError('RUNTIME_START');
      if (drainError !== undefined) {
        return new RefreshFailedResultValue(drainError);
      }
      const admission = this.runtimeCoordinator.acquireMutationLease('REFRESH');
      if (admission.error !== undefined) {
        return new RefreshFailedResultValue(admission.error);
      }
      try {
        const result: RefreshProfileResult = await this.refreshUseCase.execute({
          profileId,
          allowPlainHttp
        });
        await this.refreshSnapshotFromRepository(undefined);
        if (result.kind === 'UPDATED') {
          await this.maybeReconcileForActiveProfile(result.profile.id);
        }
        return result;
      } finally {
        admission.lease?.release();
      }
    } catch (error) {
      const appError: AppError = createAppError('RUNTIME_START', resolveErrorMessage(error, 'Runtime must be stopped before refresh.'), {
        retryable: false
      });
      await this.refreshSnapshotFromRepository(appError);
      return new RefreshFailedResultValue(appError);
    }
  }

  async refreshAllSubscriptions(): Promise<RefreshAllSubscriptionsResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    if (!this.tryAcquireRuntimeMutationOwner('PROFILE_EDIT')) {
      return new RefreshAllSubscriptionsFailedResultValue(createSubscriptionRefreshAllBusyError(this.commitService.now()));
    }
    const batchUseCase: RefreshProfilesUseCase | undefined = this.refreshProfilesUseCase;
    try {
      if (batchUseCase === undefined) {
        return new RefreshAllSubscriptionsFailedResultValue(
          createSubscriptionRefreshAllUnavailableError(this.commitService.now())
        );
      }
      const drainError: AppError | undefined = await this.requireDelayDrainAppError('RUNTIME_START');
      if (drainError !== undefined) {
        return new RefreshAllSubscriptionsFailedResultValue(createSubscriptionRefreshAllBusyError(this.commitService.now()));
      }
      const admission = this.runtimeCoordinator.acquireMutationLease('REFRESH');
      if (admission.error !== undefined) {
        return new RefreshAllSubscriptionsFailedResultValue(createSubscriptionRefreshAllBusyError(this.commitService.now()));
      }
      try {
        const result: RefreshProfilesResult = await batchUseCase.execute({
          mode: 'ALL'
        });
        await this.refreshSnapshotFromRepository(undefined);
        return new RefreshAllSubscriptionsCompletedResultValue(result);
      } finally {
        admission.lease?.release();
      }
    } catch (_) {
      const appError: AppError = createSubscriptionRefreshAllFailedError(this.commitService.now());
      await this.refreshSnapshotFromRepository(appError);
      return new RefreshAllSubscriptionsFailedResultValue(appError);
    } finally {
      this.releaseRuntimeMutationOwner('PROFILE_EDIT');
    }
  }

  async updateAutoUpdateInterval(profileId: string, intervalMs: number): Promise<UpdateProfileResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    if (!isAllowedProfileAutoUpdateInterval(intervalMs)) {
      return new UpdateProfileFailedResultValue(createSubscriptionIntervalInvalidError(this.commitService.now()));
    }
    if (!this.tryAcquireRuntimeMutationOwner('PROFILE_EDIT')) {
      return new UpdateProfileFailedResultValue(createProfileEditBusyError(this.commitService.now()));
    }
    try {
      const currentProfile: Profile | undefined = await this.repository.get(profileId);
      if (currentProfile === undefined || currentProfile.sourceKind !== 'REMOTE_URL') {
        return new UpdateProfileFailedResultValue(createSubscriptionIntervalUnavailableError(this.commitService.now()));
      }
      const updatedProfile: Profile = createProfile({
        id: currentProfile.id,
        name: currentProfile.name,
        sourceKind: currentProfile.sourceKind,
        sourceDisplay: currentProfile.sourceDisplay,
        sourceSecretRef: currentProfile.sourceSecretRef,
        currentRevision: currentProfile.currentRevision,
        failedCandidate: currentProfile.failedCandidate,
        availability: currentProfile.availability,
        lastError: currentProfile.lastError,
        createdAt: currentProfile.createdAt,
        updatedAt: this.commitService.now(),
        lastSuccessfulUpdateAt: currentProfile.lastSuccessfulUpdateAt,
        autoUpdateIntervalMs: intervalMs
      });
      await this.repository.save(updatedProfile);
      await this.refreshSnapshotFromRepository(undefined);
      const scheduleError: AppError | undefined = await this.reconcileProfileRefreshScheduleAndPublishError();
      if (scheduleError !== undefined) {
        return new UpdateProfileRefreshFailedResultValue(updatedProfile, scheduleError);
      }
      return new UpdateProfileUpdatedResultValue(updatedProfile);
    } catch (_) {
      return new UpdateProfileFailedResultValue(createSubscriptionIntervalSaveFailedError(this.commitService.now()));
    } finally {
      this.releaseRuntimeMutationOwner('PROFILE_EDIT');
    }
  }

  async reloadFromRepository(): Promise<void> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
      return;
    }
    await this.refreshSnapshotFromRepository(undefined);
    await this.reconcileProfileRefreshScheduleAndPublishError();
  }

  async enable(profileId: string): Promise<ManageEnableResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const drainError: AppError | undefined = await this.requireDelayDrainAppError('PERSISTENCE');
    if (drainError !== undefined) {
      return createManageProfileFailedResult(drainError);
    }
    const result: ManageEnableResult = await this.manageProfileUseCases.enable(profileId);
    await this.refreshSnapshotFromRepository(undefined);
    if (result.kind === 'ENABLED') {
      await this.maybeReconcileForActiveProfile(result.profile.id);
    }
    return result;
  }

  async delete(profileId: string): Promise<ManageDeleteResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const drainError: AppError | undefined = await this.requireDelayDrainAppError('PERSISTENCE');
    if (drainError !== undefined) {
      return createManageProfileFailedResult(drainError);
    }
    const result: ManageDeleteResult = await this.manageProfileUseCases.delete(profileId);
    await this.refreshSnapshotFromRepository(undefined);
    if (result.kind === 'FAILED') {
      return result;
    }
    const scheduleError: AppError | undefined = await this.reconcileProfileRefreshScheduleAndPublishError();
    if (scheduleError !== undefined) {
      return createManageProfileFailedResult(scheduleError);
    }
    return result;
  }

  async replaceSubscriptionUrl(
    profileId: string,
    sourceUrl: string,
    allowPlainHttp: boolean = false
  ): Promise<ManageReplaceResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const result: UpdateProfileResult = await this.updateSourceChangingProfile(profileId, sourceUrl, allowPlainHttp);
    if (result.kind !== 'UPDATED') {
      return createManageProfileFailedResult(result.error);
    }
    return {
      kind: 'REPLACED',
      profile: result.profile
    };
  }

  async updateProfile(
    profileId: string,
    name: string,
    sourceUrl?: string,
    allowPlainHttp: boolean = false
  ): Promise<UpdateProfileResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const drainError: AppError | undefined = await this.requireDelayDrainAppError('PERSISTENCE');
    if (drainError !== undefined) {
      return new UpdateProfileFailedResultValue(drainError);
    }

    const normalizedSourceUrl: string | undefined = normalizeOptionalSourceUrl(sourceUrl);
    const sourceChanged: boolean = normalizedSourceUrl !== undefined;
    if (!sourceChanged) {
      const metadataResult: ManageUpdateResult = await this.manageProfileUseCases.updateMetadata(profileId, name, undefined);
      await this.refreshSnapshotFromRepository(undefined);
      if (metadataResult.kind === 'FAILED') {
        return new UpdateProfileFailedResultValue(metadataResult.error);
      }
      return new UpdateProfileUpdatedResultValue(metadataResult.profile);
    }
    const sourceUrlForChange: string = normalizedSourceUrl ?? '';
    return await this.updateSourceChangingProfile(profileId, sourceUrlForChange, allowPlainHttp, name);
  }

  async startVpnGlobalCapture(): Promise<VpnControllerStartResult> {
    const controller: VpnControllerPort | undefined = this.vpnController;
    if (!this.tryAcquireRuntimeMutationOwner('VPN')) {
      return this.createStartVpnBusyResult(controller);
    }
    try {
      if (controller === undefined) {
        return {
          kind: 'REJECTED',
          snapshot: createStoppedVpnSnapshot(),
          failure: createVpnFailure('VPN_CREATE_FAILED', 'VPN global capture is unavailable.')
        };
      }
      if (this.snapshot.status !== 'READY') {
        return {
          kind: 'REJECTED',
          snapshot: controller.snapshot(),
          failure: createVpnFailure('VPN_PROFILE_UNAVAILABLE', 'VPN global capture is unavailable until profile loading completes.')
        };
      }
      const target: ActiveVpnProfile | undefined = this.resolveActiveVpnProfileFromSnapshot();
      if (target === undefined) {
        return {
          kind: 'REJECTED',
          snapshot: controller.snapshot(),
          failure: createVpnFailure('VPN_PROFILE_UNAVAILABLE', 'No committed active profile is available for VPN global capture.')
        };
      }
      const drainFailure: VpnFailure | undefined = await this.requireDelayDrainVpnFailure('VPN_CREATE_FAILED');
      if (drainFailure !== undefined) {
        return {
          kind: 'REJECTED',
          snapshot: controller.snapshot(),
          failure: drainFailure
        };
      }
      if (this.snapshot.runtime.state === 'STARTING' || this.snapshot.runtime.state === 'STOPPING') {
        return {
          kind: 'REJECTED',
          snapshot: controller.snapshot(),
          failure: createVpnFailure('VPN_CREATE_FAILED', 'VPN global capture could not be started.')
        };
      }
      return controller.start(target.profileId, target.versionId, createFreshVpnSessionId(this.idGenerator, this.commitService.now()));
    } finally {
      this.releaseRuntimeMutationOwner('VPN');
    }
  }

  async stopVpnGlobalCapture(): Promise<VpnControllerStopResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const controller: VpnControllerPort | undefined = this.vpnController;
    if (!this.tryAcquireRuntimeMutationOwner('VPN')) {
      return this.createStopVpnBusyResult(controller);
    }
    try {
      if (controller === undefined) {
        return {
          kind: 'STOPPED',
          snapshot: createStoppedVpnSnapshot()
        };
      }
      const drainFailure: VpnFailure | undefined = await this.requireDelayDrainVpnFailure('VPN_STOP_FAILED');
      if (drainFailure !== undefined) {
        return {
          kind: 'FAILED',
          snapshot: controller.snapshot(),
          failure: drainFailure
        };
      }
      return await controller.stop();
    } finally {
      this.releaseRuntimeMutationOwner('VPN');
    }
  }

  async listGroups(): Promise<ProxyGroupListQueryResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    return cloneProxyGroupListQueryResult(await this.proxyService.listGroups());
  }

  async queryGroup(groupName: string, groupPath?: string[]): Promise<ProxyGroupQueryResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    return cloneProxyGroupQueryResult(await this.proxyService.queryGroup(groupName, groupPath));
  }

  async queryHomeProxySelection(): Promise<HomeProxySelectionSummary | undefined> {
    try {
      const groupsResult: ProxyGroupListQueryResult = await this.listGroups();
      if (groupsResult.kind !== 'SNAPSHOT' || groupsResult.groups.length === 0) {
        return undefined;
      }
      const primaryGroupName: string = groupsResult.groups[0].name;
      return await this.queryHomeProxySelectionFromGroup(primaryGroupName, groupsResult.identity, [primaryGroupName]);
    } catch (_) {
      return undefined;
    }
  }

  async select(
    groupName: string,
    memberName: string,
    snapshotGeneration: number,
    groupPath?: string[]
  ): Promise<ProxySelectionResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    return cloneProxySelectionResult(await this.proxyService.select(groupName, memberName, snapshotGeneration, groupPath));
  }

  async selectNodeAndEnsureVpn(
    groupName: string,
    memberName: string,
    snapshotGeneration: number,
    groupPath?: string[]
  ): Promise<SelectNodeAndEnsureVpnResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    if (!this.tryAcquireRuntimeMutationOwner('ONE_CLICK')) {
      return createBusyOneClickVpnFailure();
    }
    let result: SelectNodeAndEnsureVpnResult | undefined;
    try {
      result = await this.selectNodeAndEnsureVpnInsideLease(groupName, memberName, snapshotGeneration, groupPath);
      return result;
    } finally {
      this.finishOneClickVpnOperation(result);
    }
  }

  async reconcileActiveSelections(): Promise<ProxyReconcileResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const drainRejected: ProxyRejectedResult | undefined = await this.requireDelayDrainProxyRejected();
    if (drainRejected !== undefined) {
      this.publish(
        createProfileApplicationSnapshot(
          'READY',
          this.snapshot.profiles,
          this.snapshot.activeProfileId,
          this.snapshot.runtime,
          drainRejected,
          this.snapshot.error
        )
      );
      return cloneProxyReconcileResult(drainRejected);
    }
    const result: ProxyReconcileResult = await this.safeProxyReconciliation();
    this.publish(
      createProfileApplicationSnapshot(
        'READY',
        this.snapshot.profiles,
        this.snapshot.activeProfileId,
        this.snapshot.runtime,
        result,
        this.snapshot.error
      )
    );
    return cloneProxyReconcileResult(result);
  }

  async startDelayTest(groupName: string, snapshotGeneration: number, groupPath?: string[]): Promise<ProxyDelayResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    return cloneProxyDelayResult(await this.proxyService.startDelayTest(groupName, snapshotGeneration, groupPath));
  }

  async readDelayTest(jobId: string): Promise<ProxyDelayResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    return cloneProxyDelayResult(await this.proxyService.readDelayTest(jobId));
  }

  async cancelDelayTest(jobId: string): Promise<ProxyDelayResult> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    return cloneProxyDelayResult(await this.proxyService.cancelDelayTest(jobId));
  }

  async cancelAndDrainDelayTest(): Promise<ProxyRejectedResult | undefined> {
    if (this.snapshot.status !== 'READY') {
      await this.initialize();
    }
    const result: ProxyRejectedResult | undefined = await this.proxyService.cancelAndDrainDelayTest();
    return result === undefined ? undefined : createProxyRejectedResult(result.error);
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    if (this.closePromise !== undefined) {
      await this.closePromise;
      return;
    }
    const closePromise: Promise<void> = this.closeInternal().finally(() => {
      if (!this.closed) {
        this.closePromise = undefined;
      }
    });
    this.closePromise = closePromise;
    await closePromise;
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.runtimeCoordinator.unsubscribe(this.runtimeSubscriptionId);
    this.listeners.clear();
    this.oneClickVpnOperationListeners.clear();
  }

  private async initializeInternal(): Promise<void> {
    try {
      await this.commitService.reconcileStoredContent();
      await this.runtimeCoordinator.initialize();
      await this.refreshSnapshotFromRepository(undefined);
      await this.reconcileProfileRefreshScheduleAndPublishError();
    } catch (error) {
      const appError: AppError = createAppError('PERSISTENCE', resolveErrorMessage(error, 'Profile application initialization failed.'), {
        retryable: false
      });
      await this.refreshSnapshotFromRepository(appError);
      throw toError(error, 'Profile application initialization failed.');
    } finally {
      if (this.snapshot.status !== 'READY') {
        this.initializePromise = undefined;
      }
    }
  }

  private async refreshSnapshotFromRepository(error?: AppError): Promise<void> {
    let profiles: ProfileApplicationProfileSnapshot[] = this.snapshot.profiles;
    let activeProfileId: string | undefined = this.snapshot.activeProfileId;
    let status: 'LOADING' | 'READY' | 'ERROR' = error === undefined ? 'READY' : 'ERROR';
    let snapshotError: ProfileApplicationErrorSnapshot | null = error === undefined ? null : createProfileApplicationErrorSnapshot(error);
    try {
      const listedProfiles: Profile[] = await this.repository.list();
      const nextProfiles: ProfileApplicationProfileSnapshot[] = [];
      for (let index: number = 0; index < listedProfiles.length; index += 1) {
        nextProfiles.push(createProfileApplicationProfileSnapshot(listedProfiles[index]));
      }
      sortProfileApplicationSnapshots(nextProfiles);
      profiles = nextProfiles;
      activeProfileId = await this.repository.getActiveId();
      if (snapshotError === null) {
        status = 'READY';
      }
    } catch (refreshError) {
      status = 'ERROR';
      snapshotError = createProfileApplicationErrorSnapshot(
        error ?? createAppError('PERSISTENCE', resolveErrorMessage(refreshError, 'Profile snapshot refresh failed.'), {
          retryable: false
        })
      );
    }
    this.publish(
      createProfileApplicationSnapshot(
        status,
        profiles,
        activeProfileId,
        createProfileApplicationRuntimeSnapshot(this.runtimeCoordinator.current()),
        this.snapshot.proxyReconciliation,
        snapshotError
      )
    );
  }

  private async reconcileProfileRefreshScheduleAndPublishError(): Promise<AppError | undefined> {
    const schedule: ProfileRefreshSchedulePort | undefined = this.profileRefreshSchedule;
    if (schedule === undefined) {
      return undefined;
    }
    try {
      await schedule.reconcile(this.hasScheduledRemoteProfiles());
      return undefined;
    } catch (_) {
      const appError: AppError = createSubscriptionScheduleFailedError(this.commitService.now());
      this.publishReadySnapshotError(appError);
      return appError;
    }
  }

  private publishReadySnapshotError(error: AppError): void {
    this.publish(
      createProfileApplicationSnapshot(
        'READY',
        this.snapshot.profiles,
        this.snapshot.activeProfileId,
        this.snapshot.runtime,
        this.snapshot.proxyReconciliation,
        createProfileApplicationErrorSnapshot(error)
      )
    );
  }

  private hasScheduledRemoteProfiles(): boolean {
    for (let index = 0; index < this.snapshot.profiles.length; index += 1) {
      const profile: ProfileApplicationProfileSnapshot = this.snapshot.profiles[index];
      if (profile.sourceKind === 'REMOTE_URL' && profile.autoUpdateIntervalMs > 0) {
        return true;
      }
    }
    return false;
  }

  private async maybeReconcileForActiveProfile(profileId: string): Promise<void> {
    if (this.snapshot.activeProfileId !== profileId) {
      return;
    }
    const drainRejected: ProxyRejectedResult | undefined = await this.requireDelayDrainProxyRejected();
    if (drainRejected !== undefined) {
      this.publish(
        createProfileApplicationSnapshot(
          'READY',
          this.snapshot.profiles,
          this.snapshot.activeProfileId,
          this.snapshot.runtime,
          drainRejected,
          this.snapshot.error
        )
      );
      return;
    }
    const result: ProxyReconcileResult = await this.safeProxyReconciliation();
    this.publish(
      createProfileApplicationSnapshot(
        'READY',
        this.snapshot.profiles,
        this.snapshot.activeProfileId,
        this.snapshot.runtime,
        result,
        this.snapshot.error
      )
    );
  }

  private async safeProxyReconciliation(): Promise<ProxyReconcileResult> {
    try {
      return cloneProxyReconcileResult(await this.proxyService.reconcileActiveSelections());
    } catch {
      return createProxyRejectedResult(
        createProxyRejectedError('PROXY_QUERY_FAILED', true, this.commitService.now())
      );
    }
  }

  private async closeInternal(): Promise<void> {
    const drainError: AppError | undefined = await this.requireDelayDrainAppError('PERSISTENCE');
    if (drainError !== undefined) {
      throw new Error(drainError.technicalDetail);
    }
    this.dispose();
    this.runtimeCoordinator.dispose();
    this.closed = true;
  }

  private async requireDelayDrainAppError(stage: AppErrorStage): Promise<AppError | undefined> {
    const rejected: ProxyRejectedResult | undefined = await this.requireDelayDrainProxyRejected();
    if (rejected === undefined) {
      return undefined;
    }
    return createDelayDrainAppError(stage, this.commitService.now());
  }

  private async requireDelayDrainProxyRejected(): Promise<ProxyRejectedResult | undefined> {
    try {
      const rejected: ProxyRejectedResult | undefined = await this.proxyService.cancelAndDrainDelayTest();
      return rejected === undefined ? undefined : createProxyRejectedResult(rejected.error);
    } catch (_) {
      return createDelayDrainProxyRejected(this.commitService.now());
    }
  }

  private async requireDelayDrainVpnFailure(code: 'VPN_CREATE_FAILED' | 'VPN_STOP_FAILED'): Promise<VpnFailure | undefined> {
    const rejected: ProxyRejectedResult | undefined = await this.requireDelayDrainProxyRejected();
    if (rejected === undefined) {
      return undefined;
    }
    return createVpnFailure(code, 'Proxy delay drain must finish before changing VPN global capture.');
  }

  private resolveActiveVpnProfileFromSnapshot(): ActiveVpnProfile | undefined {
    const activeProfileId: string | undefined = this.snapshot.activeProfileId;
    if (activeProfileId === undefined) {
      return undefined;
    }
    for (let index: number = 0; index < this.snapshot.profiles.length; index += 1) {
      const profile: ProfileApplicationProfileSnapshot = this.snapshot.profiles[index];
      if (profile.id !== activeProfileId || profile.currentRevisionVersionId === undefined) {
        continue;
      }
      if (profile.availability !== 'VALID' && profile.availability !== 'UPDATE_FAILED_USING_VALID') {
        return undefined;
      }
      return new ActiveVpnProfile(profile.id, profile.currentRevisionVersionId);
    }
    return undefined;
  }

  private async resolveLatestProfile(profileId: string, fallback: Profile): Promise<Profile> {
    try {
      const latest: Profile | undefined = await this.repository.get(profileId);
      return latest ?? fallback;
    } catch (_) {
      return fallback;
    }
  }

  private async updateSourceChangingProfile(
    profileId: string,
    sourceUrl: string,
    allowPlainHttp: boolean,
    explicitName?: string
  ): Promise<UpdateProfileResult> {
    const drainError: AppError | undefined = await this.requireDelayDrainAppError('PERSISTENCE');
    if (drainError !== undefined) {
      return new UpdateProfileFailedResultValue(drainError);
    }
    if (!this.tryAcquireRuntimeMutationOwner('PROFILE_EDIT')) {
      return new UpdateProfileFailedResultValue(createProfileEditBusyError(this.commitService.now()));
    }
    try {
      if (isPlainHttpUrl(sourceUrl) && !allowPlainHttp) {
        return new UpdateProfileFailedResultValue(createPlainHttpUpdateError(this.commitService.now()));
      }
      const vpnSnapshot: VpnRuntimeSnapshot = this.vpnController?.snapshot() ?? createStoppedVpnSnapshot();
      if (vpnSnapshot.state !== 'STOPPED') {
        return new UpdateProfileFailedResultValue(createSourceEditWhileVpnRunningError(this.commitService.now()));
      }
      const effectiveNameResult: ResolvedProfileNameResult = await this.resolveProfileNameForSourceEdit(profileId, explicitName);
      if (effectiveNameResult.error !== undefined) {
        return new UpdateProfileFailedResultValue(effectiveNameResult.error);
      }
      const metadataResult: ManageUpdateResult =
        await this.manageProfileUseCases.updateMetadata(profileId, effectiveNameResult.name, sourceUrl);
      await this.refreshSnapshotFromRepository(undefined);
      if (metadataResult.kind === 'FAILED') {
        return new UpdateProfileFailedResultValue(metadataResult.error);
      }
      return await this.completeSourceChangingRefresh(profileId, allowPlainHttp, metadataResult.profile);
    } finally {
      this.releaseRuntimeMutationOwner('PROFILE_EDIT');
    }
  }

  private async completeSourceChangingRefresh(
    profileId: string,
    allowPlainHttp: boolean,
    metadataProfile: Profile
  ): Promise<UpdateProfileResult> {
    const refreshResult: RefreshProfileResult = await this.refresh(profileId, allowPlainHttp);
    const latestProfile: Profile = await this.resolveLatestProfile(profileId, metadataProfile);
    if (refreshResult.kind === 'UPDATED') {
      if (refreshResult.profile.availability === 'UPDATE_FAILED_USING_VALID' || refreshResult.profile.lastError !== null) {
        return new UpdateProfileRefreshFailedResultValue(
          latestProfile,
          cloneAppError(refreshResult.profile.lastError ?? createUpdateRefreshCancelledError(this.commitService.now()))
        );
      }
      return new UpdateProfileUpdatedResultValue(latestProfile);
    }
    if (refreshResult.kind === 'FAILED') {
      return new UpdateProfileRefreshFailedResultValue(latestProfile, cloneAppError(refreshResult.error));
    }
    return new UpdateProfileRefreshFailedResultValue(latestProfile, createUpdateRefreshCancelledError(this.commitService.now()));
  }

  private async resolveProfileNameForSourceEdit(
    profileId: string,
    explicitName?: string
  ): Promise<ResolvedProfileNameResult> {
    if (explicitName !== undefined) {
      return new ResolvedProfileNameResultValue(explicitName, undefined);
    }
    try {
      const profile: Profile | undefined = await this.repository.get(profileId);
      if (profile === undefined) {
        return new ResolvedProfileNameResultValue('', createAppError('PERSISTENCE', 'Profile was not found.', {
          retryable: false,
          timestamp: this.commitService.now()
        }));
      }
      return new ResolvedProfileNameResultValue(profile.name, undefined);
    } catch (error) {
      return new ResolvedProfileNameResultValue('', createAppError('PERSISTENCE', resolveErrorMessage(error, 'Profile persistence failed.'), {
        retryable: false,
        timestamp: this.commitService.now()
      }));
    }
  }

  private publish(snapshot: ProfileApplicationSnapshot): void {
    this.snapshot = cloneProfileApplicationSnapshot(snapshot);
    if (this.listeners.size === 0) {
      return;
    }
    const listeners: ProfileApplicationListener[] = [];
    this.listeners.forEach((listener: ProfileApplicationListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneProfileApplicationSnapshot(this.snapshot));
    }
  }

  private finishOneClickVpnOperation(result: SelectNodeAndEnsureVpnResult | undefined): void {
    const outcome: 'SUCCEEDED' | 'FAILED' = result !== undefined &&
      result.kind !== 'FAILED' &&
      result.kind !== 'SAVED_VPN_START_FAILED'
      ? 'SUCCEEDED'
      : 'FAILED';
    this.releaseRuntimeMutationOwner('ONE_CLICK');
    this.publishOneClickVpnOperation(createOneClickVpnOperationSnapshot('IDLE', false, outcome));
  }

  private publishOneClickVpnOperation(snapshot: OneClickVpnOperationSnapshot): void {
    this.oneClickVpnOperationSnapshot = cloneOneClickVpnOperationSnapshot(snapshot);
    if (this.oneClickVpnOperationListeners.size === 0) {
      return;
    }
    const listeners: OneClickVpnOperationListener[] = [];
    this.oneClickVpnOperationListeners.forEach((listener: OneClickVpnOperationListener): void => {
      listeners.push(listener);
    });
    for (let index = 0; index < listeners.length; index += 1) {
      try {
        listeners[index](cloneOneClickVpnOperationSnapshot(this.oneClickVpnOperationSnapshot));
      } catch (_) {
      }
    }
  }

  private async selectNodeAndEnsureVpnInsideLease(
    groupName: string,
    memberName: string,
    snapshotGeneration: number,
    groupPath?: string[]
  ): Promise<SelectNodeAndEnsureVpnResult> {
    const vpnSnapshot: VpnRuntimeSnapshot = this.vpnController?.snapshot() ?? createStoppedVpnSnapshot();
    if (this.snapshot.runtime.state === 'STARTING' ||
      this.snapshot.runtime.state === 'STOPPING' ||
      isVpnOneClickBusyState(vpnSnapshot.state)) {
      return createBusyOneClickVpnFailure();
    }
    if (vpnSnapshot.state === 'RUNNING') {
      return await this.applySelectionToRunningVpn(groupName, memberName, snapshotGeneration, vpnSnapshot, groupPath);
    }
    return await this.selectAndStartVpn(groupName, memberName, snapshotGeneration, groupPath);
  }

  private async applySelectionToRunningVpn(
    groupName: string,
    memberName: string,
    snapshotGeneration: number,
    vpnSnapshot: VpnRuntimeSnapshot,
    groupPath?: string[]
  ): Promise<SelectNodeAndEnsureVpnResult> {
    const queryResult: ProxyGroupQueryResult = await this.proxyService.queryGroup(groupName, groupPath);
    if (queryResult.kind === 'REJECTED') {
      return mapOneClickQueryRejectedResult(queryResult, false);
    }
    const activeSessionId: string | null = vpnSnapshot.activeRequest?.sessionId ?? null;
    if (activeSessionId === null || queryResult.snapshot.identity.sessionId !== activeSessionId) {
      return createOneClickVpnFailureResult('VPN_CONFIRMATION', 'VPN_SESSION_CHANGED', true, 'proxies_error_session_changed', true);
    }
    const selectedNode = findProxyGroupNode(queryResult.snapshot.group, memberName);
    if (queryResult.snapshot.group.selectedName === memberName && selectedNode !== undefined && selectedNode.selected) {
      return createSelectNodeAndEnsureVpnSuccessResult('ALREADY_ACTIVE');
    }
    this.publishOneClickVpnOperation(createOneClickVpnOperationSnapshot('SWITCHING_VPN', true, 'NONE'));
    const selectionResult: ProxySelectionResult =
      await this.proxyService.select(groupName, memberName, snapshotGeneration, groupPath);
    if (selectionResult.kind === 'APPLIED_NOW') {
      return createSelectNodeAndEnsureVpnSuccessResult('APPLIED_TO_RUNNING_VPN');
    }
    if (selectionResult.kind === 'APPLIED_NOT_PERSISTED') {
      return createSelectNodeAndEnsureVpnSuccessResult('APPLIED_TO_RUNNING_VPN_NOT_PERSISTED');
    }
    if (selectionResult.kind === 'REJECTED') {
      return mapProxySelectionRejected(selectionResult, false);
    }
    return createOneClickVpnFailureResult(
      'SELECTION',
      'PROXY_PERSISTENCE_FAILED',
      true,
      'proxies_error_persistence_failed',
      false
    );
  }

  private async selectAndStartVpn(
    groupName: string,
    memberName: string,
    snapshotGeneration: number,
    groupPath?: string[]
  ): Promise<SelectNodeAndEnsureVpnResult> {
    this.publishOneClickVpnOperation(createOneClickVpnOperationSnapshot('SAVING_SELECTION', true, 'NONE'));
    const selectionResult: ProxySelectionResult =
      await this.proxyService.select(groupName, memberName, snapshotGeneration, groupPath);
    if (selectionResult.kind === 'REJECTED') {
      return mapProxySelectionRejected(selectionResult, false);
    }
    if (selectionResult.kind === 'APPLIED_NOT_PERSISTED') {
      return createOneClickVpnFailureResult(
        'SELECTION',
        'PROXY_PERSISTENCE_FAILED',
        selectionResult.error.retryable,
        'proxies_error_persistence_failed',
        false
      );
    }
    return await this.startVpnAfterSelection(groupName, memberName, true, groupPath);
  }

  private async startVpnAfterSelection(
    groupName: string,
    memberName: string,
    savedForNextStart: boolean,
    groupPath?: string[]
  ): Promise<SelectNodeAndEnsureVpnResult> {
    const controller: VpnControllerPort | undefined = this.vpnController;
    if (controller === undefined) {
      return createOneClickVpnFailureResult('VPN_START', 'VPN_PROFILE_UNAVAILABLE', false, 'error_vpn_profile_unavailable', savedForNextStart);
    }
    const target: ActiveVpnProfile | undefined = this.resolveActiveVpnProfileFromSnapshot();
    if (target === undefined) {
      return createOneClickVpnFailureResult('VPN_START', 'VPN_PROFILE_UNAVAILABLE', false, 'error_vpn_profile_unavailable', savedForNextStart);
    }
    const sessionId: string = createFreshVpnSessionId(this.idGenerator, this.commitService.now());
    let confirmationHandle: OneClickVpnConfirmationHandle | undefined;
    try {
      confirmationHandle = this.oneClickVpnConfirmation.arm(sessionId, ONE_CLICK_VPN_CONFIRMATION_TIMEOUT_MS);
      this.publishOneClickVpnOperation(createOneClickVpnOperationSnapshot('STARTING_VPN', true, 'NONE'));
      let startResult: VpnControllerStartResult;
      try {
        startResult = await controller.start(target.profileId, target.versionId, sessionId);
      } catch (_) {
        return createSelectNodeAndEnsureVpnSuccessResult('SAVED_VPN_START_FAILED');
      }
      if (startResult.kind !== 'STARTED') {
        return createSelectNodeAndEnsureVpnSuccessResult('SAVED_VPN_START_FAILED');
      }
      this.publishOneClickVpnOperation(createOneClickVpnOperationSnapshot('CONFIRMING_SELECTION', true, 'NONE'));
      try {
        confirmationHandle.markStartAccepted();
      } catch (_) {
        return createSelectNodeAndEnsureVpnSuccessResult('SAVED_VPN_START_FAILED');
      }
      let confirmationResult: OneClickVpnConfirmationResult;
      try {
        confirmationResult = await confirmationHandle.wait();
      } catch (_) {
        return createSelectNodeAndEnsureVpnSuccessResult('SAVED_VPN_START_FAILED');
      }
      return await this.finishVpnConfirmation(
        groupName,
        memberName,
        controller,
        target,
        sessionId,
        confirmationResult,
        savedForNextStart,
        groupPath
      );
    } catch (_) {
      return createSelectNodeAndEnsureVpnSuccessResult('SAVED_VPN_START_FAILED');
    } finally {
      confirmationHandle?.cancel();
    }
  }

  private async finishVpnConfirmation(
    groupName: string,
    memberName: string,
    controller: VpnControllerPort,
    target: ActiveVpnProfile,
    sessionId: string,
    confirmationResult: OneClickVpnConfirmationResult,
    savedForNextStart: boolean,
    groupPath?: string[]
  ): Promise<SelectNodeAndEnsureVpnResult> {
    if (confirmationResult.kind === 'RUNNING') {
      const queryResult: ProxyGroupQueryResult = await this.proxyService.queryGroup(groupName, groupPath);
      if (queryResult.kind === 'REJECTED') {
        return mapOneClickQueryRejectedResult(queryResult, savedForNextStart);
      }
      if (queryResult.snapshot.identity.sessionId !== sessionId ||
        queryResult.snapshot.identity.profileId !== target.profileId ||
        queryResult.snapshot.identity.revisionId !== target.versionId) {
        return createOneClickVpnFailureResult('VPN_CONFIRMATION', 'VPN_SESSION_CHANGED', true, 'proxies_error_session_changed', savedForNextStart);
      }
      const selectedNode = findProxyGroupNode(queryResult.snapshot.group, memberName);
      if (queryResult.snapshot.group.selectedName !== memberName || selectedNode === undefined || !selectedNode.selected) {
        return createOneClickVpnFailureResult('VPN_CONFIRMATION', 'VPN_SESSION_CHANGED', true, 'proxies_error_session_changed', savedForNextStart);
      }
      return createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED');
    }
    if (confirmationResult.kind === 'STOPPED') {
      return createOneClickVpnFailureResult('VPN_START', 'VPN_STOPPED_BEFORE_RUNNING', true, 'error_vpn_start_failed', savedForNextStart);
    }
    if (confirmationResult.kind === 'TIMEOUT') {
      return createOneClickVpnFailureResult(
        'VPN_CONFIRMATION',
        'VPN_CONFIRMATION_TIMEOUT',
        true,
        'proxies_one_click_confirmation_timeout',
        savedForNextStart
      );
    }
    if (confirmationResult.kind === 'SESSION_CHANGED' || confirmationResult.kind === 'CANCELLED') {
      return createOneClickVpnFailureResult('VPN_CONFIRMATION', 'VPN_SESSION_CHANGED', true, 'proxies_error_session_changed', savedForNextStart);
    }
    if (controller.snapshot().lastFailure?.code === 'VPN_PERMISSION_DENIED') {
      return createOneClickVpnFailureResult('VPN_START', 'VPN_PERMISSION_DENIED', true, 'error_vpn_permission_denied', savedForNextStart);
    }
    return createOneClickVpnFailureResult('VPN_START', 'VPN_START_FAILED', true, 'error_vpn_start_failed', savedForNextStart);
  }

  private async queryHomeProxySelectionFromGroup(
    primaryGroupName: string,
    expectedIdentity: ProxyRuntimeIdentity,
    groupPath: string[]
  ): Promise<HomeProxySelectionSummary | undefined> {
    if (groupPath.length === 0 || groupPath.length > HOME_PROXY_SELECTION_MAX_GROUP_PATH_SEGMENTS) {
      return undefined;
    }
    const targetGroupName: string = groupPath[groupPath.length - 1];
    let queryResult: ProxyGroupQueryResult;
    try {
      queryResult = await this.queryGroup(targetGroupName, groupPath);
    } catch (_) {
      return undefined;
    }
    if (queryResult.kind !== 'SNAPSHOT' ||
      !sameProxyRuntimeIdentity(queryResult.snapshot.identity, expectedIdentity) ||
      queryResult.snapshot.group.name !== targetGroupName) {
      return undefined;
    }
    const selectedNode: CoreProxyNodeSummary | undefined = findStrictSelectedProxyGroupNode(queryResult.snapshot.group);
    if (selectedNode === undefined) {
      return undefined;
    }
    if (!selectedNode.isGroup) {
      return {
        groupName: primaryGroupName,
        nodeName: selectedNode.name
      };
    }
    if (groupPath.length >= HOME_PROXY_SELECTION_MAX_GROUP_PATH_SEGMENTS || groupPath.includes(selectedNode.name)) {
      return undefined;
    }
    const nextGroupPath: string[] = groupPath.slice();
    nextGroupPath.push(selectedNode.name);
    return await this.queryHomeProxySelectionFromGroup(primaryGroupName, expectedIdentity, nextGroupPath);
  }

  private tryAcquireRuntimeMutationOwner(owner: AppRuntimeMutationOwner): boolean {
    if (this.runtimeMutationOwner !== 'NONE') {
      return false;
    }
    this.runtimeMutationOwner = owner;
    return true;
  }

  private releaseRuntimeMutationOwner(owner: AppRuntimeMutationOwner): void {
    if (this.runtimeMutationOwner !== owner) {
      return;
    }
    this.runtimeMutationOwner = 'NONE';
  }

  private createStartVpnBusyResult(controller: VpnControllerPort | undefined): VpnControllerStartResult {
    return {
      kind: 'REJECTED',
      snapshot: controller?.snapshot() ?? createStoppedVpnSnapshot(),
      failure: createVpnFailure('VPN_CREATE_FAILED', 'Another app runtime mutation is already in progress.')
    };
  }

  private createStopVpnBusyResult(controller: VpnControllerPort | undefined): VpnControllerStopResult {
    return {
      kind: 'FAILED',
      snapshot: controller?.snapshot() ?? createStoppedVpnSnapshot(),
      failure: createVpnFailure('VPN_STOP_FAILED', 'Another app runtime mutation is already in progress.')
    };
  }
}

class ActiveVpnProfile {
  profileId: string;
  versionId: string;

  constructor(profileId: string, versionId: string) {
    this.profileId = profileId;
    this.versionId = versionId;
  }
}

class ResolvedProfileNameResultValue implements ResolvedProfileNameResult {
  name: string;
  error?: AppError;

  constructor(name: string, error: AppError | undefined) {
    this.name = name;
    this.error = error;
  }
}

interface ResolvedProfileNameResult {
  name: string;
  error?: AppError;
}

class ProfileApplicationProfileSnapshotValue implements ProfileApplicationProfileSnapshot {
  id: string = '';
  name: string = '';
  sourceDisplay: string = '';
  sourceKind: ProfileSourceKind = 'LOCAL_FILE';
  availability: ProfileAvailability = 'INVALID';
  updatedAt: string = '';
  autoUpdateIntervalMs: number = 0;
  lastSuccessfulUpdateAt?: string;
  hasCurrentRevision: boolean = false;
  currentRevisionVersionId?: string;
  sourceRepairRequired: boolean = false;
  lastError: ProfileApplicationErrorSnapshot | null = null;
}

class ProfileApplicationSnapshotValue implements ProfileApplicationSnapshot {
  status: 'LOADING' | 'READY' | 'ERROR' = 'LOADING';
  profiles: ProfileApplicationProfileSnapshot[] = [];
  activeProfileId?: string;
  runtime: ProfileApplicationRuntimeSnapshot = createProfileApplicationRuntimeSnapshot(thisRuntimeStoppedSnapshot());
  proxyReconciliation: ProxyReconcileResult | null = null;
  error: ProfileApplicationErrorSnapshot | null = null;
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

class ProfileApplicationErrorSnapshotValue implements ProfileApplicationErrorSnapshot {
  code: string;
  stage: AppErrorStage;
  userMessageResource: string;
  technicalDetail: string;
  timestamp: string;
  retryable: boolean;

  constructor(error: AppError) {
    this.code = error.code;
    this.stage = error.stage;
    this.userMessageResource = error.userMessageResource;
    this.technicalDetail = redactSensitiveText(error.technicalDetail);
    this.timestamp = error.timestamp;
    this.retryable = error.retryable;
  }
}

function createProfileApplicationRuntimeLatestSnapshot(runtime: LocalRuntimeCoordinatorSnapshot): ProfileApplicationRuntimeLatestSnapshot {
  const snapshot: ProfileApplicationRuntimeLatestSnapshotValue = new ProfileApplicationRuntimeLatestSnapshotValue();
  snapshot.state = runtime.latest.state;
  snapshot.httpAddress = redactSensitiveText(runtime.latest.httpAddress);
  snapshot.socksAddress = redactSensitiveText(runtime.latest.socksAddress);
  snapshot.lastError = redactSensitiveText(runtime.latest.lastError);
  snapshot.mixedPort = runtime.latest.mixedPort;
  return snapshot;
}

function createProfileApplicationRuntimeSnapshot(runtime: LocalRuntimeCoordinatorSnapshot): ProfileApplicationRuntimeSnapshot {
  const snapshot: ProfileApplicationRuntimeSnapshotValue = new ProfileApplicationRuntimeSnapshotValue();
  snapshot.state = runtime.state;
  snapshot.latest = createProfileApplicationRuntimeLatestSnapshot(runtime);
  snapshot.lastError = runtime.lastError === null ? null : createProfileApplicationErrorSnapshot(runtime.lastError);
  return snapshot;
}

function createProfileApplicationErrorSnapshot(error: AppError): ProfileApplicationErrorSnapshot {
  return new ProfileApplicationErrorSnapshotValue(error);
}

function createProfileApplicationProfileSnapshot(profile: Profile): ProfileApplicationProfileSnapshot {
  const snapshot: ProfileApplicationProfileSnapshotValue = new ProfileApplicationProfileSnapshotValue();
  snapshot.id = profile.id;
  snapshot.name = profile.name;
  snapshot.sourceDisplay = profile.sourceDisplay;
  snapshot.sourceKind = profile.sourceKind;
  snapshot.availability = profile.availability;
  snapshot.updatedAt = profile.updatedAt;
  snapshot.autoUpdateIntervalMs = profile.autoUpdateIntervalMs;
  snapshot.lastSuccessfulUpdateAt = profile.lastSuccessfulUpdateAt === null ? undefined : profile.lastSuccessfulUpdateAt;
  snapshot.hasCurrentRevision = profile.currentRevision !== null;
  snapshot.currentRevisionVersionId = profile.currentRevision === null ? undefined : profile.currentRevision.validatedAt;
  snapshot.sourceRepairRequired = isSourceRepairRequired(profile);
  snapshot.lastError = profile.lastError === null ? null : createProfileApplicationErrorSnapshot(profile.lastError);
  return snapshot;
}

function createProfileApplicationSnapshot(
  status: 'LOADING' | 'READY' | 'ERROR',
  profiles: ProfileApplicationProfileSnapshot[],
  activeProfileId: string | undefined,
  runtime: ProfileApplicationRuntimeSnapshot,
  proxyReconciliation: ProxyReconcileResult | null,
  error: ProfileApplicationErrorSnapshot | null
): ProfileApplicationSnapshot {
  const snapshot: ProfileApplicationSnapshotValue = new ProfileApplicationSnapshotValue();
  snapshot.status = status;
  snapshot.profiles = cloneProfileApplicationProfiles(profiles);
  snapshot.activeProfileId = activeProfileId;
  snapshot.runtime = cloneProfileApplicationRuntimeSnapshot(runtime);
  snapshot.proxyReconciliation = proxyReconciliation === null ? null : cloneProxyReconcileResult(proxyReconciliation);
  snapshot.error = error === null ? null : cloneProfileApplicationErrorSnapshot(error);
  return snapshot;
}

function cloneProfileApplicationSnapshot(snapshot: ProfileApplicationSnapshot): ProfileApplicationSnapshot {
  return createProfileApplicationSnapshot(
    snapshot.status,
    snapshot.profiles,
    snapshot.activeProfileId,
    snapshot.runtime,
    snapshot.proxyReconciliation,
    snapshot.error
  );
}

function cloneProfileApplicationProfiles(profiles: ProfileApplicationProfileSnapshot[]): ProfileApplicationProfileSnapshot[] {
  const cloned: ProfileApplicationProfileSnapshot[] = [];
  for (let index: number = 0; index < profiles.length; index += 1) {
    const source: ProfileApplicationProfileSnapshot = profiles[index];
    const snapshot: ProfileApplicationProfileSnapshotValue = new ProfileApplicationProfileSnapshotValue();
    snapshot.id = source.id;
    snapshot.name = source.name;
    snapshot.sourceDisplay = source.sourceDisplay;
    snapshot.sourceKind = source.sourceKind;
    snapshot.availability = source.availability;
    snapshot.updatedAt = source.updatedAt;
    snapshot.autoUpdateIntervalMs = source.autoUpdateIntervalMs;
    snapshot.lastSuccessfulUpdateAt = source.lastSuccessfulUpdateAt;
    snapshot.hasCurrentRevision = source.hasCurrentRevision;
    snapshot.currentRevisionVersionId = source.currentRevisionVersionId;
    snapshot.sourceRepairRequired = source.sourceRepairRequired;
    snapshot.lastError = source.lastError === null ? null : cloneProfileApplicationErrorSnapshot(source.lastError);
    cloned.push(snapshot);
  }
  return cloned;
}

function isSourceRepairRequired(profile: Profile): boolean {
  if (profile.sourceKind !== 'REMOTE_URL' || profile.lastError === null) {
    return false;
  }
  return profile.lastError.code === 'SOURCE_SECRET_MISSING' ||
    profile.lastError.code === 'SOURCE_DECRYPT_FAILED' ||
    profile.lastError.code === 'SOURCE_SECRET_VERSION_UNSUPPORTED';
}

function cloneProfileApplicationRuntimeSnapshot(runtime: ProfileApplicationRuntimeSnapshot): ProfileApplicationRuntimeSnapshot {
  const snapshot: ProfileApplicationRuntimeSnapshotValue = new ProfileApplicationRuntimeSnapshotValue();
  snapshot.state = runtime.state;
  snapshot.latest = cloneProfileApplicationRuntimeLatestSnapshot(runtime.latest);
  snapshot.lastError = runtime.lastError === null ? null : cloneProfileApplicationErrorSnapshot(runtime.lastError);
  return snapshot;
}

function cloneProfileApplicationRuntimeLatestSnapshot(runtime: ProfileApplicationRuntimeLatestSnapshot): ProfileApplicationRuntimeLatestSnapshot {
  const snapshot: ProfileApplicationRuntimeLatestSnapshotValue = new ProfileApplicationRuntimeLatestSnapshotValue();
  snapshot.state = runtime.state;
  snapshot.httpAddress = runtime.httpAddress;
  snapshot.socksAddress = runtime.socksAddress;
  snapshot.lastError = runtime.lastError;
  snapshot.mixedPort = runtime.mixedPort;
  return snapshot;
}

function cloneProfileApplicationErrorSnapshot(error: ProfileApplicationErrorSnapshot): ProfileApplicationErrorSnapshot {
  return new ProfileApplicationErrorSnapshotValue({
    code: error.code,
    stage: error.stage,
    userMessageResource: error.userMessageResource,
    technicalDetail: error.technicalDetail,
    timestamp: error.timestamp,
    retryable: error.retryable
  });
}

function sortProfileApplicationSnapshots(profiles: ProfileApplicationProfileSnapshot[]): void {
  profiles.sort((left: ProfileApplicationProfileSnapshot, right: ProfileApplicationProfileSnapshot): number => {
    if (left.updatedAt !== right.updatedAt) {
      return right.updatedAt.localeCompare(left.updatedAt);
    }
    if (left.name !== right.name) {
      return left.name.localeCompare(right.name);
    }
    return left.id.localeCompare(right.id);
  });
}

function thisRuntimeStoppedSnapshot(): LocalRuntimeCoordinatorSnapshot {
  return {
    state: 'STOPPED',
    latest: {
      state: 'STOPPED',
      activeConfigPath: '',
      httpAddress: '',
      socksAddress: '',
      lastError: '',
      mixedPort: 0
    },
    lastError: null
  };
}

function createStoppedVpnSnapshot(): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state: 'STOPPED',
    activeRequest: null,
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: false,
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure: null
  });
}

function createFreshVpnSessionId(idGenerator: IdGenerator | undefined, timestamp: string): string {
  const rawId: string = idGenerator?.nextId().trim() ?? timestamp;
  const normalized: string = rawId.replace(/[^0-9A-Za-z_-]/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '');
  return `vpn-session-${normalized.length > 0 ? normalized : 'current'}`;
}

function createDelayDrainProxyRejected(timestamp: string): ProxyRejectedResult {
  return createProxyRejectedResult(createProxyRejectedError('PROXY_DELAY_DRAIN_FAILED', true, timestamp));
}

function createDelayDrainAppError(stage: AppErrorStage, timestamp: string): AppError {
  return createAppError(stage, 'Proxy delay drain must finish before this operation can continue.', {
    code: 'CMFA_PROXY_DELAY_DRAIN_FAILED',
    retryable: true,
    timestamp,
    userMessageResource: 'error.proxy.delay_drain'
  });
}

function createPlainHttpUpdateError(timestamp: string): AppError {
  return createAppError('IMPORT', 'Remote profile URL updates require HTTPS or explicit plain HTTP approval.', {
    retryable: false,
    timestamp
  });
}

function createSourceEditWhileVpnRunningError(timestamp: string): AppError {
  return createAppError('RUNTIME_STOP', 'VPN global capture must be stopped before editing the profile source.', {
    retryable: false,
    timestamp
  });
}

function createProfileEditBusyError(timestamp: string): AppError {
  return createAppError('RUNTIME_STOP', 'Another app runtime mutation is already in progress.', {
    retryable: true,
    timestamp
  });
}

function createSubscriptionRefreshAllBusyError(timestamp: string): AppError {
  return createAppError('RUNTIME_START', 'Subscription refresh is unavailable while runtime work is in progress.', {
    code: 'SUBSCRIPTION_REFRESH_ALL_BUSY',
    retryable: true,
    timestamp,
    userMessageResource: 'error.runtime.start'
  });
}

function createSubscriptionRefreshAllUnavailableError(timestamp: string): AppError {
  return createAppError('RUNTIME_START', 'Subscription refresh is unavailable in this environment.', {
    code: 'SUBSCRIPTION_REFRESH_ALL_UNAVAILABLE',
    retryable: false,
    timestamp,
    userMessageResource: 'error.runtime.start'
  });
}

function createSubscriptionRefreshAllFailedError(timestamp: string): AppError {
  return createAppError('DOWNLOAD', 'Subscription refresh failed before completion.', {
    code: 'SUBSCRIPTION_REFRESH_ALL_FAILED',
    retryable: false,
    timestamp,
    userMessageResource: 'error.download'
  });
}

function createSubscriptionIntervalInvalidError(timestamp: string): AppError {
  return createAppError('PERSISTENCE', 'Subscription auto-update interval is invalid.', {
    code: 'SUBSCRIPTION_INTERVAL_INVALID',
    retryable: false,
    timestamp,
    userMessageResource: 'error.persistence'
  });
}

function createSubscriptionIntervalUnavailableError(timestamp: string): AppError {
  return createAppError('PERSISTENCE', 'Subscription auto-update interval is unavailable for this profile.', {
    code: 'SUBSCRIPTION_INTERVAL_UNAVAILABLE',
    retryable: false,
    timestamp,
    userMessageResource: 'error.persistence'
  });
}

function createSubscriptionIntervalSaveFailedError(timestamp: string): AppError {
  return createAppError('PERSISTENCE', 'Subscription auto-update interval could not be saved.', {
    code: 'SUBSCRIPTION_INTERVAL_SAVE_FAILED',
    retryable: false,
    timestamp,
    userMessageResource: 'error.persistence'
  });
}

function createSubscriptionScheduleFailedError(timestamp: string): AppError {
  return createAppError('PERSISTENCE', 'Subscription schedule reconciliation failed after saving profile metadata.', {
    code: 'SUBSCRIPTION_SCHEDULE_FAILED',
    retryable: false,
    timestamp,
    userMessageResource: 'error.persistence'
  });
}

function createUpdateRefreshCancelledError(timestamp: string): AppError {
  return createAppError('DOWNLOAD', 'Profile metadata was saved, but the source refresh did not complete.', {
    code: 'CMFA_PROFILE_REFRESH_INCOMPLETE',
    retryable: false,
    timestamp,
    userMessageResource: 'error.download'
  });
}

function normalizeOptionalSourceUrl(sourceUrl: string | undefined): string | undefined {
  if (sourceUrl === undefined) {
    return undefined;
  }
  const normalized: string = sourceUrl.trim();
  return normalized.length === 0 ? undefined : normalized;
}

function isAllowedProfileAutoUpdateInterval(intervalMs: number): boolean {
  for (let index = 0; index < PROFILE_AUTO_UPDATE_INTERVAL_PRESET_MS.length; index += 1) {
    if (PROFILE_AUTO_UPDATE_INTERVAL_PRESET_MS[index] === intervalMs) {
      return true;
    }
  }
  return false;
}

function isPlainHttpUrl(sourceUrl: string): boolean {
  return sourceUrl.trim().startsWith('http://');
}

function cloneAppError(error: AppError): AppError {
  return createAppError(error.stage, error.technicalDetail, {
    code: error.code,
    retryable: error.retryable,
    timestamp: error.timestamp,
    userMessageResource: error.userMessageResource
  });
}

function cloneRefreshProfilesResult(result: RefreshProfilesResult): RefreshProfilesResult {
  const clonedItems: RefreshProfilesItemResult[] = result.items.map(
    (item: RefreshProfilesItemResult): RefreshProfilesItemResult => ({
      profileId: item.profileId,
      status: item.status
    })
  );
  return {
    items: clonedItems,
    deadlineReached: result.deadlineReached,
    cancelled: result.cancelled,
    remainingCount: result.remainingCount
  };
}

const ONE_CLICK_VPN_CONFIRMATION_TIMEOUT_MS: number = 15_000;
const HOME_PROXY_SELECTION_MAX_GROUP_PATH_SEGMENTS: number = 16;

function createBusyOneClickVpnFailure(): SelectNodeAndEnsureVpnResult {
  return createOneClickVpnFailureResult(
    'ADMISSION',
    'OPERATION_BUSY',
    true,
    'proxies_one_click_busy',
    false
  );
}

function isVpnOneClickBusyState(state: VpnRuntimeState): boolean {
  return state === 'AWAITING_CONSENT' ||
    state === 'STARTING' ||
    state === 'RECOVERING' ||
    state === 'STOPPING';
}

function mapProxySelectionRejected(result: ProxyRejectedResult, savedForNextStart: boolean): SelectNodeAndEnsureVpnResult {
  if (result.error.code === 'PROXY_SELECTION_STALE') {
    return createOneClickVpnFailureResult('SELECTION', 'PROXY_SELECTION_STALE', true, 'proxies_error_selection_stale', false);
  }
  if (result.error.code === 'PROXY_PERSISTENCE_FAILED') {
    return createOneClickVpnFailureResult(
      'SELECTION',
      'PROXY_PERSISTENCE_FAILED',
      result.error.retryable,
      'proxies_error_persistence_failed',
      false
    );
  }
  return createOneClickVpnFailureResult(
    'SELECTION',
    'PROXY_SELECTION_FAILED',
    result.error.retryable,
    'proxies_error_selection_failed',
    savedForNextStart
  );
}

function mapOneClickQueryRejectedResult(
  result: ProxyRejectedResult,
  savedForNextStart: boolean
): SelectNodeAndEnsureVpnResult {
  if (result.error.code === 'VPN_SESSION_CHANGED') {
    return createOneClickVpnFailureResult(
      'VPN_CONFIRMATION',
      'VPN_SESSION_CHANGED',
      true,
      'proxies_error_session_changed',
      savedForNextStart
    );
  }
  return createOneClickVpnFailureResult(
    'SELECTION',
    'PROXY_SELECTION_FAILED',
    result.error.retryable,
    'proxies_error_selection_failed',
    false
  );
}

function findProxyGroupNode(group: CoreProxyGroupSnapshot, memberName: string): CoreProxyNodeSummary | undefined {
  for (let index = 0; index < group.nodes.length; index += 1) {
    if (group.nodes[index].name === memberName) {
      return group.nodes[index];
    }
  }
  return undefined;
}

function findStrictSelectedProxyGroupNode(group: CoreProxyGroupSnapshot): CoreProxyNodeSummary | undefined {
  if (group.selectedName.length === 0) {
    return undefined;
  }
  let selectedNode: CoreProxyNodeSummary | undefined;
  for (let index = 0; index < group.nodes.length; index += 1) {
    const node: CoreProxyNodeSummary = group.nodes[index];
    if (!node.selected) {
      continue;
    }
    if (selectedNode !== undefined) {
      return undefined;
    }
    selectedNode = node;
  }
  if (selectedNode === undefined || selectedNode.name !== group.selectedName) {
    return undefined;
  }
  return selectedNode;
}

function sameProxyRuntimeIdentity(left: ProxyRuntimeIdentity, right: ProxyRuntimeIdentity): boolean {
  return left.profileId === right.profileId &&
    left.revisionId === right.revisionId &&
    left.revisionHash === right.revisionHash &&
    left.sessionId === right.sessionId;
}

function resolveErrorMessage(error: Object | undefined, fallback: string): string {
  return error instanceof Error && error.message.trim().length > 0 ? error.message : fallback;
}

function toError(error: Object | undefined, fallback: string): Error {
  return error instanceof Error ? error : new Error(fallback);
}
