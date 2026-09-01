import type {
  CoreProxyGroupRef,
  CoreProxyGroupSnapshot,
  OneClickVpnErrorResourceId,
  OneClickVpnOperationSnapshot,
  ProxyDelayNodeResult,
  ProxyDelayResult,
  ProxyDelaySnapshotResult,
  ProxyGroupListQueryResult,
  ProxyGroupQueryResult,
  ProxyGroupSnapshot,
  ProxyOneClickVpnApplicationPort,
  ProxyRejectedErrorCode,
  ProxyRejectedResult,
  ProxySelectionResult,
  SelectNodeAndEnsureVpnResult
} from '@cmfa/shared';
import {
  cloneOneClickVpnOperationSnapshot,
  cloneProxyDelayResult,
  cloneProxyGroupListQueryResult,
  cloneProxyGroupQueryResult,
  createOneClickVpnOperationSnapshot
} from '@cmfa/shared';
import {
  cloneProxyViewState,
  createProxyActivationStateOptions,
  createProxyGroupTabState,
  createProxyNodeRowState,
  createProxyViewState,
  type ProxyActivationStateOptions,
  type ProxyActivationStage,
  type ProxyDelayViewState,
  type ProxyGroupTabState,
  type ProxyNodeDelayStatus,
  type ProxyNodeRowState,
  type ProxyPersistenceWarning,
  type ProxyViewState
} from './ProxyPresentationModels';

const PROXY_VIEW_DEADLINE_MS: number = 15000;
const PROXY_DELAY_POLL_MS: number = 250;

export type ProxyViewListener = (state: ProxyViewState) => void;

export interface ProxyViewDeadlinePort {
  run<T>(operation: () => Promise<T>): Promise<T>;
}

export abstract class ProxyDelayScheduledTaskPort {
  abstract cancel(): void;
}

export abstract class ProxyDelaySchedulerPort {
  abstract schedule(delayMs: number, callback: () => void): ProxyDelayScheduledTaskPort;
}

interface SavedProxyIntent {
  profileId: string;
  revisionId: string;
  groupName: string;
  nodeName: string;
}

class SavedProxyIntentValue implements SavedProxyIntent {
  profileId: string = '';
  revisionId: string = '';
  groupName: string = '';
  nodeName: string = '';
}

interface AppliedNotPersistedState {
  profileId: string;
  revisionId: string;
  sessionId: string;
}

class AppliedNotPersistedStateValue implements AppliedNotPersistedState {
  profileId: string = '';
  revisionId: string = '';
  sessionId: string = '';
}

interface RefreshContext {
  requestEpoch: number;
  pageActive: boolean;
  displayedGroupName: string;
  displayedGroupPath: string[];
  activeTopLevelGroupName: string;
}

class RefreshContextValue implements RefreshContext {
  requestEpoch: number = 0;
  pageActive: boolean = false;
  displayedGroupName: string = '';
  displayedGroupPath: string[] = [];
  activeTopLevelGroupName: string = '';
}

class DelaySummaryValue {
  totalDelayCount: number = 0;
  testableDelayCount: number = 0;
  completedDelayCount: number = 0;
  availableDelayCount: number = 0;
  timeoutDelayCount: number = 0;
  failedDelayCount: number = 0;
  cancelledDelayCount: number = 0;
  unsupportedDelayCount: number = 0;
  fastestDelayNodeIndex?: number;
}

class ProxyViewDeadlineExceededError extends Error {
  constructor() {
    super('Proxy view deadline exceeded.');
  }
}

class TimeoutProxyViewDeadlinePort implements ProxyViewDeadlinePort {
  async run<T>(operation: () => Promise<T>): Promise<T> {
    let timerId: number = -1;
    try {
      return await Promise.race<T>([
        operation(),
        new Promise<T>((_resolve: (value: T) => void, reject: (reason?: Object) => void) => {
          timerId = setTimeout(() => {
            reject(new ProxyViewDeadlineExceededError());
          }, PROXY_VIEW_DEADLINE_MS);
        })
      ]);
    } finally {
      if (timerId >= 0) {
        clearTimeout(timerId);
      }
    }
  }
}

class TimeoutProxyDelayScheduledTask extends ProxyDelayScheduledTaskPort {
  private readonly timerId: number;
  private cancelled: boolean = false;

  constructor(delayMs: number, callback: () => void) {
    super();
    this.timerId = setTimeout(() => {
      if (this.cancelled) {
        return;
      }
      callback();
    }, delayMs);
  }

  cancel(): void {
    if (this.cancelled) {
      return;
    }
    this.cancelled = true;
    clearTimeout(this.timerId);
  }
}

class TimeoutProxyDelaySchedulerPort extends ProxyDelaySchedulerPort {
  schedule(delayMs: number, callback: () => void): ProxyDelayScheduledTaskPort {
    return new TimeoutProxyDelayScheduledTask(delayMs, callback);
  }
}

export class ProxyViewModel {
  private readonly application: ProxyOneClickVpnApplicationPort;
  private readonly deadline: ProxyViewDeadlinePort;
  private readonly delayScheduler: ProxyDelaySchedulerPort;
  private readonly listeners: Map<number, ProxyViewListener> = new Map();
  private readonly oneClickOperationListenerId: number;
  private state: ProxyViewState;
  private nextListenerId: number = 0;
  private requestEpoch: number = 0;
  private selectionEpoch: number = 0;
  private delayEpoch: number = 0;
  private pageActive: boolean = true;
  private disposed: boolean = false;
  private disposePromise?: Promise<boolean>;
  private activeTopLevelGroupName?: string;
  private displayedGroupName?: string;
  private displayedGroupPath?: string[];
  private activeDelayJobId?: string;
  private activeDelayGroupName?: string;
  private activeDelayGeneration?: number;
  private scheduledDelayTask?: ProxyDelayScheduledTaskPort;
  private pendingDelayCancellation: boolean = false;
  private inFlightDelayStart?: Promise<void>;
  private readonly savedIntents: Map<string, SavedProxyIntent> = new Map();
  private appliedNotPersisted?: AppliedNotPersistedState;
  private oneClickOperation: OneClickVpnOperationSnapshot = createOneClickVpnOperationSnapshot('IDLE', false, 'NONE');
  private localOneClickPending: boolean = false;
  private displayedProfileId?: string;
  private displayedRevisionId?: string;
  private displayedSessionId: string | null = null;
  private activatingRowIndex?: number;
  private activatingGroupName?: string;
  private activatingNodeName?: string;
  private pendingExternalSuccessRefresh: boolean = false;
  private expectedProfileId?: string;

  constructor(
    application: ProxyOneClickVpnApplicationPort,
    deadline?: ProxyViewDeadlinePort,
    delayScheduler?: ProxyDelaySchedulerPort
  ) {
    this.application = application;
    this.deadline = deadline ?? new TimeoutProxyViewDeadlinePort();
    this.delayScheduler = delayScheduler ?? new TimeoutProxyDelaySchedulerPort();
    this.state = createProxyViewState('IDLE', [], [], {
      selectionPending: false,
      warning: 'NONE'
    });
    this.oneClickOperation = cloneOneClickVpnOperationSnapshot(this.application.currentOneClickVpnOperation());
    this.oneClickOperationListenerId = this.application.subscribeOneClickVpnOperation((snapshot: OneClickVpnOperationSnapshot): void => {
      this.handleOneClickOperation(snapshot);
    });
    const catchUpSnapshot: OneClickVpnOperationSnapshot = cloneOneClickVpnOperationSnapshot(this.application.currentOneClickVpnOperation());
    this.oneClickOperation = catchUpSnapshot;
    this.handleOneClickOperation(catchUpSnapshot);
  }

  current(): ProxyViewState {
    return cloneProxyViewState(this.state);
  }

  subscribe(listener: ProxyViewListener): number {
    this.nextListenerId += 1;
    this.listeners.set(this.nextListenerId, listener);
    return this.nextListenerId;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  async load(expectedProfileId?: string): Promise<void> {
    const reattaching: boolean = !this.pageActive;
    if (reattaching) {
      this.pageActive = true;
    }
    if (this.disposed || (this.isActivationBusy() && this.state.status !== 'IDLE' && !reattaching)) {
      return;
    }
    this.expectedProfileId = expectedProfileId;
    this.publish(createProxyViewState('LOADING', [], [], {
      warning: this.currentWarning()
    }));
    if (this.hasDelayLifecycleWork()) {
      if (!(await this.prepareForNavigationOrLoad())) {
        return;
      }
    }
    const epoch: number = this.beginRequest(undefined, [], false);
    let listResult: ProxyGroupListQueryResult;
    try {
      listResult = cloneProxyGroupListQueryResult(await this.deadline.run(() => this.application.listGroups()));
    } catch (_error) {
      this.publishQueryFailure(epoch, [], []);
      return;
    }
    if (!this.isCurrentEpoch(epoch)) {
      return;
    }
    if (listResult.kind === 'REJECTED') {
      this.publishQueryRejection(epoch, [], [], listResult.error.code, listResult.error.retryable);
      return;
    }
    if (expectedProfileId !== undefined && listResult.identity.profileId !== expectedProfileId) {
      this.publishQueryRejection(epoch, [], [], 'PROXY_PROFILE_UNAVAILABLE', false);
      return;
    }
    this.reconcileSavedIntentIdentity(
      listResult.identity.profileId,
      listResult.identity.revisionId,
      listResult.identity.sessionId
    );
    this.reconcileAppliedNotPersistedIdentity(
      listResult.identity.profileId,
      listResult.identity.revisionId,
      listResult.identity.sessionId
    );
    if (listResult.groups.length === 0) {
      this.activeTopLevelGroupName = undefined;
      this.displayedGroupName = undefined;
      this.publish(createProxyViewState('EMPTY', [], [], {
        warning: this.currentWarning()
      }));
      return;
    }
    const firstGroupName: string = listResult.groups[0].name;
    const groups: ProxyGroupTabState[] = createTabs(listResult.groups, firstGroupName);
    this.activeTopLevelGroupName = firstGroupName;
    this.publish(createProxyViewState('LOADING', groups, [], {
      warning: this.currentWarning()
    }));
    await this.queryGroupByName(epoch, firstGroupName, firstGroupName, groups, [firstGroupName]);
  }

  async openGroup(groupIndex: number): Promise<void> {
    if (this.disposed || this.isActivationBusy()) {
      return;
    }
    if (!Number.isInteger(groupIndex) || groupIndex < 0 || groupIndex >= this.state.groups.length) {
      return;
    }
    if (this.hasDelayLifecycleWork()) {
      if (!(await this.prepareForNavigationOrLoad())) {
        return;
      }
    }
    const groupName: string = this.state.groups[groupIndex].name;
    const groups: ProxyGroupTabState[] = setActiveTopLevelGroup(this.state.groups, groupName);
    const epoch: number = this.beginRequest(groupName, groups);
    await this.queryGroupByName(epoch, groupName, groupName, groups, [groupName]);
  }

  async activateNode(nodeIndex: number): Promise<void> {
    if (this.disposed || this.isActivationBusy()) {
      return;
    }
    if (!Number.isInteger(nodeIndex) || nodeIndex < 0 || nodeIndex >= this.state.nodes.length) {
      return;
    }
    const row: ProxyNodeRowState = this.state.nodes[nodeIndex];
    if (row.isGroup) {
      const activeTopLevelGroupName: string | undefined = this.activeTopLevelGroupName;
      if (activeTopLevelGroupName === undefined) {
        return;
      }
      if (this.hasDelayLifecycleWork()) {
        if (!(await this.prepareForNavigationOrLoad())) {
          return;
        }
      }
      const epoch: number = this.beginRequest(activeTopLevelGroupName, this.state.groups);
      await this.queryGroupByName(
        epoch,
        row.name,
        activeTopLevelGroupName,
        this.state.groups,
        this.extendDisplayedGroupPath(row.name)
      );
      return;
    }
    if (this.isLiveDelayState(this.state.delayState)) {
      return;
    }
    if (this.displayedSessionId !== null && row.runtimeSelected) {
      return;
    }
    const groupName: string | undefined = this.displayedGroupName;
    const generation: number | undefined = this.state.groupGeneration;
    if (groupName === undefined || generation === undefined) {
      return;
    }
    const selectionEpoch: number = this.beginSelectionEpoch();
    this.localOneClickPending = true;
    this.activatingRowIndex = nodeIndex;
    this.activatingGroupName = groupName;
    this.activatingNodeName = row.name;
    let selectionResult: SelectNodeAndEnsureVpnResult;
    try {
      selectionResult = await this.application.selectNodeAndEnsureVpn(
        groupName,
        row.name,
        generation,
        this.cloneDisplayedGroupPath()
      );
    } catch (_error) {
      if (!this.isCurrentSelectionEpoch(selectionEpoch)) {
        return;
      }
      this.publishActivationFailure('proxies_error_selection_failed', true, false);
      return;
    } finally {
      this.localOneClickPending = false;
    }
    if (this.disposed || !this.isCurrentSelectionEpoch(selectionEpoch)) {
      return;
    }
    await this.applyOneClickResult(selectionResult);
  }

  async toggleDelayTest(): Promise<void> {
    if (this.disposed || this.isActivationBusy() || this.state.status !== 'READY') {
      return;
    }
    if (this.state.delayState === 'STARTING') {
      this.pendingDelayCancellation = true;
      const pendingStart: Promise<void> | undefined = this.inFlightDelayStart;
      if (pendingStart !== undefined) {
        await pendingStart;
      }
      return;
    }
    if (this.state.delayState === 'RUNNING') {
      await this.cancelActiveDelayTest();
      return;
    }
    const groupName: string | undefined = this.displayedGroupName;
    const generation: number | undefined = this.state.groupGeneration;
    if (groupName === undefined || generation === undefined) {
      return;
    }
    const epoch: number = this.beginDelayEpoch(groupName, generation);
    const clearedNodes: ProxyNodeRowState[] = clearDelayRows(this.state.nodes);
    this.publish(createProxyViewState('READY', this.state.groups, clearedNodes, {
      groupGeneration: generation,
      warning: this.state.warning,
      delayState: 'STARTING'
    }));
    const startPromise: Promise<void> = this.startDelayLoop(epoch, groupName, generation);
    this.inFlightDelayStart = startPromise;
    try {
      await startPromise;
    } finally {
      if (this.inFlightDelayStart === startPromise) {
        this.inFlightDelayStart = undefined;
      }
    }
  }

  async leave(): Promise<void> {
    if (this.disposed) {
      return;
    }
    const previousPageActive: boolean = this.pageActive;
    this.pageActive = false;
    this.invalidateRequestAndSelectionEpochs();
    const cleared: boolean = await this.cancelDelayLifecycleAndClear();
    if (!cleared) {
      this.pageActive = previousPageActive;
      this.handleOneClickOperation(this.oneClickOperation);
      throw new Error('Proxy delay lifecycle drain failed.');
    }
    this.publishSelectionClearedState();
    this.clearActivationTarget(true);
  }

  async retry(): Promise<void> {
    if (this.isActivationBusy()) {
      return;
    }
    await this.load(this.expectedProfileId);
  }

  dispose(): Promise<boolean> {
    if (this.disposePromise !== undefined) {
      return this.disposePromise;
    }
    this.invalidateRequestAndSelectionEpochs();
    this.application.unsubscribeOneClickVpnOperation(this.oneClickOperationListenerId);
    this.disposed = true;
    this.listeners.clear();
    this.cancelScheduledDelayTask();
    this.bumpDelayEpoch();
    const hasDelayWork: boolean = this.inFlightDelayStart !== undefined ||
      this.activeDelayJobId !== undefined ||
      this.state.delayState === 'STARTING' ||
      this.state.delayState === 'RUNNING';
    if (!hasDelayWork) {
      this.clearDelayTracking();
      this.disposePromise = Promise.resolve(true);
      return this.disposePromise;
    }
    const pendingStart: Promise<void> | undefined = this.inFlightDelayStart;
    this.disposePromise = (async (): Promise<boolean> => {
      let didDrain: boolean = true;
      try {
        const rejected: ProxyRejectedResult | undefined = await this.application.cancelAndDrainDelayTest();
        if (rejected !== undefined) {
          didDrain = false;
        }
      } catch (_error) {
        didDrain = false;
      }
      if (pendingStart !== undefined) {
        try {
          await pendingStart;
        } catch (_error) {
          didDrain = false;
        }
      }
      this.clearDelayTracking();
      return didDrain;
    })();
    return this.disposePromise;
  }

  private async startDelayLoop(epoch: number, groupName: string, generation: number): Promise<void> {
    let result: ProxyDelayResult;
    try {
      result = cloneProxyDelayResult(
        await this.application.startDelayTest(groupName, generation, this.cloneDisplayedGroupPath())
      );
    } catch (_error) {
      if (this.isCurrentDelayEpoch(epoch)) {
        this.publishStartDelayFailure('PROXY_DELAY_TEST_FAILED', true);
      }
      return;
    }
    if (!this.isCurrentDelayEpoch(epoch)) {
      return;
    }
    if (result.kind === 'REJECTED') {
      this.publishStartDelayFailure(result.error.code, result.error.retryable);
      return;
    }
    let mappedRows: ProxyNodeRowState[];
    let delayState: ProxyDelayViewState;
    try {
      mappedRows = this.mapDelaySnapshotRows(result);
      delayState = this.mapDelayJobState(result.state);
    } catch (_error) {
      this.publishDelayFailure('PROXY_DELAY_TEST_FAILED', true);
      return;
    }
    if (!this.isCurrentDelayEpoch(epoch)) {
      return;
    }
    this.activeDelayJobId = result.jobId;
    if (this.pendingDelayCancellation && result.state === 'RUNNING') {
      this.pendingDelayCancellation = false;
      await this.cancelActiveDelayTest();
      return;
    }
    this.pendingDelayCancellation = false;
    this.publishDelaySnapshot(delayState, mappedRows, result.state === 'FAILED');
    if (result.state === 'RUNNING' && this.isCurrentDelayEpoch(epoch, result.jobId)) {
      this.scheduleNextDelayPoll(epoch, result.jobId);
      return;
    }
    this.clearDelayTracking();
  }

  private async cancelActiveDelayTest(): Promise<void> {
    const jobId: string | undefined = this.activeDelayJobId;
    if (jobId === undefined) {
      return;
    }
    const epoch: number = this.bumpDelayEpoch();
    this.cancelScheduledDelayTask();
    let result: ProxyDelayResult;
    try {
      result = cloneProxyDelayResult(await this.application.cancelDelayTest(jobId));
    } catch (_error) {
      if (this.isCurrentDelayEpoch(epoch, jobId)) {
        this.publishDelayFailure('PROXY_DELAY_TEST_FAILED', true);
      }
      return;
    }
    if (!this.isCurrentDelayEpoch(epoch, jobId)) {
      return;
    }
    if (result.kind === 'REJECTED' || result.state === 'RUNNING') {
      this.publishDelayFailure('PROXY_DELAY_TEST_FAILED', true);
      return;
    }
    let mappedRows: ProxyNodeRowState[];
    try {
      mappedRows = this.mapDelaySnapshotRows(result);
    } catch (_error) {
      this.publishDelayFailure('PROXY_DELAY_TEST_FAILED', true);
      return;
    }
    this.publishDelaySnapshot(this.mapDelayJobState(result.state), mappedRows, false);
    this.clearDelayTracking();
  }

  private scheduleNextDelayPoll(epoch: number, jobId: string): void {
    this.cancelScheduledDelayTask();
    this.scheduledDelayTask = this.delayScheduler.schedule(PROXY_DELAY_POLL_MS, () => {
      void this.pollDelayTest(epoch, jobId);
    });
  }

  private async pollDelayTest(epoch: number, jobId: string): Promise<void> {
    if (!this.isCurrentDelayEpoch(epoch, jobId)) {
      return;
    }
    let result: ProxyDelayResult;
    try {
      result = cloneProxyDelayResult(await this.application.readDelayTest(jobId));
    } catch (_error) {
      if (this.isCurrentDelayEpoch(epoch, jobId)) {
        this.publishDelayFailure('PROXY_DELAY_TEST_FAILED', true);
      }
      return;
    }
    if (!this.isCurrentDelayEpoch(epoch, jobId)) {
      return;
    }
    if (result.kind === 'REJECTED') {
      this.publishDelayFailure('PROXY_DELAY_TEST_FAILED', true);
      return;
    }
    let mappedRows: ProxyNodeRowState[];
    let delayState: ProxyDelayViewState;
    try {
      mappedRows = this.mapDelaySnapshotRows(result);
      delayState = this.mapDelayJobState(result.state);
    } catch (_error) {
      this.publishDelayFailure('PROXY_DELAY_TEST_FAILED', true);
      return;
    }
    if (!this.isCurrentDelayEpoch(epoch, jobId)) {
      return;
    }
    this.publishDelaySnapshot(delayState, mappedRows, result.state === 'FAILED');
    if (result.state === 'RUNNING' && this.isCurrentDelayEpoch(epoch, jobId)) {
      this.scheduleNextDelayPoll(epoch, jobId);
      return;
    }
    this.clearDelayTracking();
  }

  private async prepareForNavigationOrLoad(): Promise<boolean> {
    return await this.cancelDelayLifecycleAndClear();
  }

  private hasDelayLifecycleWork(): boolean {
    return this.state.delayState !== 'IDLE' ||
      this.inFlightDelayStart !== undefined ||
      this.activeDelayJobId !== undefined;
  }

  private async cancelDelayLifecycleAndClear(): Promise<boolean> {
    const hadDelayPresentation: boolean = this.state.delayState !== 'IDLE';
    const hadLiveDelay: boolean = this.inFlightDelayStart !== undefined ||
      this.activeDelayJobId !== undefined ||
      this.state.delayState === 'STARTING' ||
      this.state.delayState === 'RUNNING';
    if (!hadDelayPresentation && !hadLiveDelay) {
      return true;
    }
    const pendingStart: Promise<void> | undefined = this.inFlightDelayStart;
    this.cancelScheduledDelayTask();
    this.bumpDelayEpoch();
    this.pendingDelayCancellation = false;
    if (hadLiveDelay) {
      let rejected: ProxyRejectedResult | undefined;
      try {
        rejected = await this.application.cancelAndDrainDelayTest();
      } catch (_error) {
        if (pendingStart !== undefined) {
          await pendingStart;
        }
        this.publishDelayLifecycleFailure('PROXY_DELAY_DRAIN_FAILED', true);
        return false;
      }
      if (pendingStart !== undefined) {
        await pendingStart;
      }
      if (rejected !== undefined) {
        this.publishDelayLifecycleFailure(rejected.error.code, rejected.error.retryable);
        return false;
      }
    }
    this.clearDelayTracking();
    this.publish(createProxyViewState(this.state.status, this.state.groups, clearDelayRows(this.state.nodes), {
      groupGeneration: this.state.groupGeneration,
      selectionPending: false,
      warning: this.state.warning
    }));
    return true;
  }

  private beginRequest(
    activeTopLevelGroupName: string | undefined,
    groups: ProxyGroupTabState[],
    publishLoading: boolean = true
  ): number {
    this.requestEpoch = nextEpochValue(this.requestEpoch);
    this.activeTopLevelGroupName = activeTopLevelGroupName;
    if (publishLoading) {
      this.publish(createProxyViewState('LOADING', groups, [], {
        warning: this.currentWarning()
      }));
    }
    return this.requestEpoch;
  }

  private async queryGroupByName(
    epoch: number,
    groupName: string,
    activeTopLevelGroupName: string,
    groups: ProxyGroupTabState[],
    groupPath?: string[]
  ): Promise<void> {
    let result: ProxyGroupQueryResult;
    try {
      result = cloneProxyGroupQueryResult(
        await this.deadline.run(() => this.application.queryGroup(groupName, groupPath))
      );
    } catch (_error) {
      this.publishQueryFailure(epoch, groups, []);
      return;
    }
    if (!this.isCurrentEpoch(epoch)) {
      return;
    }
    if (result.kind === 'REJECTED') {
      this.publishQueryRejection(epoch, groups, [], result.error.code, result.error.retryable);
      return;
    }
    this.applyDisplayedGroupSnapshot(result.snapshot, activeTopLevelGroupName, groupPath);
  }

  private applyDisplayedGroupSnapshot(
    snapshot: ProxyGroupSnapshot,
    activeTopLevelGroupName: string,
    groupPath?: string[]
  ): void {
    this.activeTopLevelGroupName = activeTopLevelGroupName;
    this.displayedGroupName = snapshot.group.name;
    this.displayedGroupPath = cloneGroupPath(groupPath ?? [snapshot.group.name]);
    this.displayedProfileId = snapshot.identity.profileId;
    this.displayedRevisionId = snapshot.identity.revisionId;
    this.displayedSessionId = snapshot.identity.sessionId;
    this.reconcileSavedIntentIdentity(
      snapshot.identity.profileId,
      snapshot.identity.revisionId,
      snapshot.identity.sessionId
    );
    this.reconcileAppliedNotPersistedIdentity(
      snapshot.identity.profileId,
      snapshot.identity.revisionId,
      snapshot.identity.sessionId
    );
    const savedIntent: SavedProxyIntent | undefined = this.savedIntents.get(this.displayedGroupPathKey());
    const savedNodeName: string | undefined = savedIntent?.nodeName;
    const rows: ProxyNodeRowState[] = preserveDelayOverlay(
      createRows(snapshot.group, savedNodeName),
      this.state.nodes,
      this.state.delayState
    );
    const savedMarkerPresent: boolean = savedNodeName !== undefined && containsSavedMarker(rows);
    if (savedNodeName !== undefined && !savedMarkerPresent) {
      this.savedIntents.delete(this.displayedGroupPathKey());
    }
    this.publishReadyRows(
      rows,
      snapshot.generation,
      this.appliedNotPersisted !== undefined
        ? 'APPLIED_NOT_PERSISTED'
        : savedMarkerPresent ? 'SAVED_FOR_NEXT_START' : 'NONE'
    );
  }

  private async applyOneClickResult(result: SelectNodeAndEnsureVpnResult): Promise<void> {
    if (result.kind === 'FAILED') {
      this.publishActivationFailure(result.resourceId, result.retryable, result.savedForNextStart);
      return;
    }
    if (result.kind === 'SAVED_VPN_START_FAILED') {
      this.publishActivationFailure('error_vpn_start_failed', true, true);
      return;
    }
    if (result.kind === 'ALREADY_ACTIVE') {
      this.clearActivationPresentation();
      this.clearActivationTarget(true);
      return;
    }
    if (result.kind === 'APPLIED_TO_RUNNING_VPN_NOT_PERSISTED') {
      this.syncAppliedNotPersistedFromDisplayedIdentity();
      await this.refreshDisplayedGroupAfterActivation();
      return;
    }
    this.appliedNotPersisted = undefined;
    await this.refreshDisplayedGroupAfterActivation();
  }

  private publishSelectionClearedState(): void {
    if (!this.state.selectionPending && this.state.delayState === 'IDLE') {
      return;
    }
    this.publish(createProxyViewState(this.state.status, this.state.groups, clearDelayRows(this.state.nodes), {
      groupGeneration: this.state.groupGeneration,
      warning: this.state.warning,
      errorCode: this.state.errorCode,
      errorRetryable: this.state.errorRetryable
    }));
  }

  private publishQueryFailure(epoch: number, groups: ProxyGroupTabState[], nodes: ProxyNodeRowState[]): void {
    this.publishQueryRejection(epoch, groups, nodes, 'PROXY_QUERY_FAILED', true);
  }

  private publishQueryRejection(
    epoch: number,
    groups: ProxyGroupTabState[],
    nodes: ProxyNodeRowState[],
    code: ProxyRejectedErrorCode,
    retryable: boolean
  ): void {
    if (!this.isCurrentEpoch(epoch)) {
      return;
    }
    this.publish(createProxyViewState('ERROR', groups, nodes, {
      warning: this.currentWarning(),
      errorCode: code,
      errorRetryable: retryable
    }));
  }

  private publishReadyRows(
    rows: ProxyNodeRowState[],
    groupGeneration: number | undefined,
    warning: ProxyPersistenceWarning
  ): void {
    const delayState: ProxyDelayViewState = this.state.delayState;
    const delaySummary: DelaySummaryValue = summarizeDelayRows(delayState, rows);
    this.publish(createProxyViewState('READY', this.state.groups, rows, {
      groupGeneration,
      warning,
      delayState,
      totalDelayCount: delaySummary.totalDelayCount,
      testableDelayCount: delaySummary.testableDelayCount,
      completedDelayCount: delaySummary.completedDelayCount,
      availableDelayCount: delaySummary.availableDelayCount,
      timeoutDelayCount: delaySummary.timeoutDelayCount,
      failedDelayCount: delaySummary.failedDelayCount,
      cancelledDelayCount: delaySummary.cancelledDelayCount,
      unsupportedDelayCount: delaySummary.unsupportedDelayCount,
      fastestDelayNodeIndex: delaySummary.fastestDelayNodeIndex,
      activation: this.state.activationStage !== 'IDLE'
        ? createProxyActivationStateOptions(
          this.state.activationStage,
          this.state.activatingRowIndex,
          this.state.activationErrorResourceId,
          this.state.activationErrorRetryable
        )
        : undefined
    }));
  }

  private handleOneClickOperation(snapshot: OneClickVpnOperationSnapshot): void {
    this.oneClickOperation = cloneOneClickVpnOperationSnapshot(snapshot);
    if (this.disposed || !this.pageActive || this.state.status !== 'READY') {
      return;
    }
    if (this.activatingRowIndex === undefined) {
      if (snapshot.stage === 'IDLE' && snapshot.outcome === 'SUCCEEDED') {
        void this.refreshDisplayedGroupAfterExternalSuccess();
      }
      return;
    }
    if (snapshot.stage === 'IDLE') {
      if (snapshot.outcome === 'SUCCEEDED') {
        this.clearActivationPresentation();
      }
      return;
    }
    this.publishActivationProgress(snapshot.stage);
  }

  private publishActivationProgress(stage: ProxyActivationStage): void {
    if (this.activatingRowIndex === undefined) {
      return;
    }
    this.publishCurrentReadyState(
      this.state.nodes,
      this.state.warning,
      createProxyActivationStateOptions(stage, this.activatingRowIndex)
    );
  }

  private publishActivationFailure(
    resourceId: OneClickVpnErrorResourceId,
    retryable: boolean,
    savedForNextStart: boolean
  ): void {
    let rows: ProxyNodeRowState[] = this.state.nodes;
    let warning: ProxyPersistenceWarning = this.currentWarning();
    if (savedForNextStart) {
      this.appliedNotPersisted = undefined;
      this.rememberSavedIntentForCurrentActivation();
      if (this.activatingNodeName !== undefined) {
        rows = markSavedRow(this.state.nodes, this.activatingNodeName);
      }
      warning = 'SAVED_FOR_NEXT_START';
    }
    if (this.activatingRowIndex === undefined) {
      return;
    }
    this.publishCurrentReadyState(
      rows,
      warning,
      createProxyActivationStateOptions('FAILED', this.activatingRowIndex, resourceId, retryable)
    );
  }

  private clearActivationPresentation(): void {
    if (this.state.status !== 'READY' || this.state.activationStage === 'IDLE') {
      return;
    }
    this.publishCurrentReadyState(this.state.nodes, this.state.warning);
  }

  private publishCurrentReadyState(
    rows: ProxyNodeRowState[],
    warning: ProxyPersistenceWarning,
    activation?: ProxyActivationStateOptions
  ): void {
    const delaySummary: DelaySummaryValue = summarizeDelayRows(this.state.delayState, rows);
    this.publish(createProxyViewState('READY', this.state.groups, rows, {
      groupGeneration: this.state.groupGeneration,
      warning,
      delayState: this.state.delayState,
      totalDelayCount: delaySummary.totalDelayCount,
      testableDelayCount: delaySummary.testableDelayCount,
      completedDelayCount: delaySummary.completedDelayCount,
      availableDelayCount: delaySummary.availableDelayCount,
      timeoutDelayCount: delaySummary.timeoutDelayCount,
      failedDelayCount: delaySummary.failedDelayCount,
      cancelledDelayCount: delaySummary.cancelledDelayCount,
      unsupportedDelayCount: delaySummary.unsupportedDelayCount,
      fastestDelayNodeIndex: delaySummary.fastestDelayNodeIndex,
      activation
    }));
  }

  private async refreshDisplayedGroupAfterActivation(): Promise<void> {
    const refreshContext: RefreshContext | undefined = this.captureRefreshContext();
    if (refreshContext === undefined) {
      this.clearActivationTarget(true);
      return;
    }
    let result: ProxyGroupQueryResult;
    try {
      result = cloneProxyGroupQueryResult(
        await this.deadline.run(() => this.application.queryGroup(
          refreshContext.displayedGroupName,
          refreshContext.displayedGroupPath
        ))
      );
    } catch (_error) {
      if (!this.isCurrentRefreshContext(refreshContext)) {
        return;
      }
      this.publishActivationFailure('proxies_error_selection_failed', true, false);
      return;
    }
    if (!this.isCurrentRefreshContext(refreshContext)) {
      return;
    }
    if (result.kind === 'REJECTED') {
      this.publishActivationFailure(
        result.error.code === 'VPN_SESSION_CHANGED' ? 'proxies_error_session_changed' : 'proxies_error_selection_failed',
        true,
        false
      );
      return;
    }
    this.applyDisplayedGroupSnapshot(
      result.snapshot,
      refreshContext.activeTopLevelGroupName,
      refreshContext.displayedGroupPath
    );
    this.clearActivationTarget(true);
  }

  private async refreshDisplayedGroupAfterExternalSuccess(): Promise<void> {
    if (this.pendingExternalSuccessRefresh || this.disposed) {
      return;
    }
    const refreshContext: RefreshContext | undefined = this.captureRefreshContext();
    if (refreshContext === undefined) {
      return;
    }
    this.pendingExternalSuccessRefresh = true;
    try {
      const result: ProxyGroupQueryResult = cloneProxyGroupQueryResult(
        await this.deadline.run(() => this.application.queryGroup(
          refreshContext.displayedGroupName,
          refreshContext.displayedGroupPath
        ))
      );
      if (!this.isCurrentRefreshContext(refreshContext) || result.kind === 'REJECTED') {
        return;
      }
      this.applyDisplayedGroupSnapshot(
        result.snapshot,
        refreshContext.activeTopLevelGroupName,
        refreshContext.displayedGroupPath
      );
    } catch (_error) {
    } finally {
      this.pendingExternalSuccessRefresh = false;
    }
  }

  private clearActivationTarget(clearPresentation: boolean): void {
    if (clearPresentation) {
      this.activatingRowIndex = undefined;
      this.activatingGroupName = undefined;
      this.activatingNodeName = undefined;
      return;
    }
    this.activatingGroupName = undefined;
    this.activatingNodeName = undefined;
  }

  private rememberSavedIntentForCurrentActivation(): void {
    if (this.displayedProfileId === undefined ||
      this.displayedRevisionId === undefined ||
      this.activatingGroupName === undefined ||
      this.activatingNodeName === undefined) {
      return;
    }
    this.reconcileSavedIntentIdentity(this.displayedProfileId, this.displayedRevisionId, null);
    this.savedIntents.set(this.displayedGroupPathKey(), createSavedIntent(
      this.displayedProfileId,
      this.displayedRevisionId,
      this.activatingGroupName,
      this.activatingNodeName
    ));
  }

  private syncAppliedNotPersistedFromDisplayedIdentity(): void {
    if (this.displayedProfileId === undefined || this.displayedRevisionId === undefined) {
      this.appliedNotPersisted = undefined;
      return;
    }
    this.appliedNotPersisted = createAppliedNotPersistedState(
      this.displayedProfileId,
      this.displayedRevisionId,
      this.displayedSessionId
    );
  }

  private publishStartDelayFailure(code: ProxyRejectedErrorCode, retryable: boolean): void {
    this.clearDelayTracking();
    this.publish(createProxyViewState('READY', this.state.groups, clearDelayRows(this.state.nodes), {
      groupGeneration: this.state.groupGeneration,
      warning: this.state.warning,
      errorCode: code,
      errorRetryable: retryable
    }));
  }

  private publishDelayFailure(code: ProxyRejectedErrorCode, retryable: boolean): void {
    const previousDelayState: ProxyDelayViewState = this.state.delayState;
    const previousNodes: ProxyNodeRowState[] = this.state.nodes;
    const groups: ProxyGroupTabState[] = this.state.groups;
    const groupGeneration: number | undefined = this.state.groupGeneration;
    const warning: ProxyPersistenceWarning = this.state.warning;
    this.cancelScheduledDelayTask();
    this.clearDelayTracking();
    if (previousDelayState === 'STARTING') {
      this.publish(createProxyViewState('READY', groups, clearDelayRows(previousNodes), {
        groupGeneration,
        warning,
        errorCode: code,
        errorRetryable: retryable
      }));
      return;
    }
    const failedRows: ProxyNodeRowState[] = createTerminalFailedDelayRows(previousNodes);
    const delaySummary: DelaySummaryValue = summarizeDelayRows('FAILED', failedRows);
    this.publish(createProxyViewState('READY', groups, failedRows, {
      groupGeneration,
      warning,
      delayState: 'FAILED',
      totalDelayCount: delaySummary.totalDelayCount,
      testableDelayCount: delaySummary.testableDelayCount,
      completedDelayCount: delaySummary.completedDelayCount,
      availableDelayCount: delaySummary.availableDelayCount,
      timeoutDelayCount: delaySummary.timeoutDelayCount,
      failedDelayCount: delaySummary.failedDelayCount,
      cancelledDelayCount: delaySummary.cancelledDelayCount,
      unsupportedDelayCount: delaySummary.unsupportedDelayCount,
      fastestDelayNodeIndex: delaySummary.fastestDelayNodeIndex,
      errorCode: code,
      errorRetryable: retryable
    }));
  }

  private publishDelayLifecycleFailure(code: ProxyRejectedErrorCode, retryable: boolean): void {
    const delayState: ProxyDelayViewState = this.state.delayState;
    const delaySummary: DelaySummaryValue = summarizeDelayRows(delayState, this.state.nodes);
    this.publish(createProxyViewState(this.state.status, this.state.groups, this.state.nodes, {
      groupGeneration: this.state.groupGeneration,
      selectionPending: this.state.selectionPending,
      warning: this.state.warning,
      delayState,
      totalDelayCount: delaySummary.totalDelayCount,
      testableDelayCount: delaySummary.testableDelayCount,
      completedDelayCount: delaySummary.completedDelayCount,
      availableDelayCount: delaySummary.availableDelayCount,
      timeoutDelayCount: delaySummary.timeoutDelayCount,
      failedDelayCount: delaySummary.failedDelayCount,
      cancelledDelayCount: delaySummary.cancelledDelayCount,
      unsupportedDelayCount: delaySummary.unsupportedDelayCount,
      fastestDelayNodeIndex: delaySummary.fastestDelayNodeIndex,
      errorCode: code,
      errorRetryable: retryable
    }));
  }

  private publishDelaySnapshot(
    delayState: ProxyDelayViewState,
    rows: ProxyNodeRowState[],
    isJobFailure: boolean
  ): void {
    const delaySummary: DelaySummaryValue = summarizeDelayRows(delayState, rows);
    this.publish(createProxyViewState('READY', this.state.groups, rows, {
      groupGeneration: this.state.groupGeneration,
      warning: this.state.warning,
      delayState,
      totalDelayCount: delaySummary.totalDelayCount,
      testableDelayCount: delaySummary.testableDelayCount,
      completedDelayCount: delaySummary.completedDelayCount,
      availableDelayCount: delaySummary.availableDelayCount,
      timeoutDelayCount: delaySummary.timeoutDelayCount,
      failedDelayCount: delaySummary.failedDelayCount,
      cancelledDelayCount: delaySummary.cancelledDelayCount,
      unsupportedDelayCount: delaySummary.unsupportedDelayCount,
      fastestDelayNodeIndex: delaySummary.fastestDelayNodeIndex,
      errorCode: isJobFailure ? 'PROXY_DELAY_TEST_FAILED' : undefined,
      errorRetryable: isJobFailure
    }));
  }

  private mapDelaySnapshotRows(result: ProxyDelaySnapshotResult): ProxyNodeRowState[] {
    if (this.activeDelayGroupName === undefined || this.activeDelayGeneration === undefined) {
      throw new Error('Delay binding missing.');
    }
    if (result.groupName !== this.activeDelayGroupName || result.generation !== this.activeDelayGeneration) {
      throw new Error('Delay binding mismatch.');
    }
    const currentRows: ProxyNodeRowState[] = this.state.nodes;
    if (result.nodes.length !== currentRows.length) {
      throw new Error('Delay node length mismatch.');
    }
    const mapped: ProxyNodeRowState[] = [];
    for (let index: number = 0; index < currentRows.length; index += 1) {
      const current: ProxyNodeRowState = currentRows[index];
      const node: ProxyDelayNodeResult = result.nodes[index];
      if (node.index !== current.index || node.name !== current.name || node.type !== current.type) {
        throw new Error('Delay node identity mismatch.');
      }
      mapped.push(createProxyNodeRowState(
        current.index,
        current.name,
        current.type,
        current.isGroup,
        current.runtimeSelected,
        current.savedForNextStart,
        {
          delayStatus: normalizeDelayNodeStatus(result.state, node),
          delayMs: node.state === 'AVAILABLE' ? node.delayMs ?? undefined : undefined,
          delayFastest: node.fastest
        }
      ));
    }
    return mapped;
  }

  private mapDelayJobState(state: string): ProxyDelayViewState {
    if (state === 'RUNNING') {
      return 'RUNNING';
    }
    if (state === 'COMPLETED') {
      return 'COMPLETED';
    }
    if (state === 'CANCELLED') {
      return 'CANCELLED';
    }
    if (state === 'FAILED') {
      return 'FAILED';
    }
    throw new Error('Unsupported delay job state.');
  }

  private currentWarning(): ProxyPersistenceWarning {
    return this.appliedNotPersisted === undefined ? 'NONE' : 'APPLIED_NOT_PERSISTED';
  }

  private beginDelayEpoch(groupName: string, generation: number): number {
    const epoch: number = this.bumpDelayEpoch();
    this.cancelScheduledDelayTask();
    this.pendingDelayCancellation = false;
    this.activeDelayJobId = undefined;
    this.activeDelayGroupName = groupName;
    this.activeDelayGeneration = generation;
    return epoch;
  }

  private bumpDelayEpoch(): number {
    this.delayEpoch = nextEpochValue(this.delayEpoch);
    return this.delayEpoch;
  }

  private beginSelectionEpoch(): number {
    this.selectionEpoch = nextEpochValue(this.selectionEpoch);
    return this.selectionEpoch;
  }

  private invalidateRequestAndSelectionEpochs(): void {
    this.requestEpoch = nextEpochValue(this.requestEpoch);
    this.selectionEpoch = nextEpochValue(this.selectionEpoch);
  }

  private cancelScheduledDelayTask(): void {
    const scheduled: ProxyDelayScheduledTaskPort | undefined = this.scheduledDelayTask;
    this.scheduledDelayTask = undefined;
    scheduled?.cancel();
  }

  private clearDelayTracking(): void {
    this.cancelScheduledDelayTask();
    this.pendingDelayCancellation = false;
    this.activeDelayJobId = undefined;
    this.activeDelayGroupName = undefined;
    this.activeDelayGeneration = undefined;
  }

  private isCurrentEpoch(epoch: number): boolean {
    return !this.disposed && epoch === this.requestEpoch;
  }

  private isCurrentSelectionEpoch(epoch: number): boolean {
    return !this.disposed && epoch === this.selectionEpoch;
  }

  private isCurrentDelayEpoch(epoch: number, jobId?: string): boolean {
    if (this.disposed || epoch !== this.delayEpoch) {
      return false;
    }
    if (jobId !== undefined && this.activeDelayJobId !== jobId) {
      return false;
    }
    return true;
  }

  private captureRefreshContext(): RefreshContext | undefined {
    const displayedGroupName: string | undefined = this.displayedGroupName;
    const activeTopLevelGroupName: string | undefined = this.activeTopLevelGroupName;
    if (displayedGroupName === undefined || activeTopLevelGroupName === undefined) {
      return undefined;
    }
    const context: RefreshContextValue = new RefreshContextValue();
    context.requestEpoch = this.requestEpoch;
    context.pageActive = this.pageActive;
    context.displayedGroupName = displayedGroupName;
    context.displayedGroupPath = this.cloneDisplayedGroupPath() ?? [displayedGroupName];
    context.activeTopLevelGroupName = activeTopLevelGroupName;
    return context;
  }

  private isCurrentRefreshContext(context: RefreshContext): boolean {
    return !this.disposed &&
      this.requestEpoch === context.requestEpoch &&
      this.pageActive === context.pageActive &&
      this.displayedGroupName === context.displayedGroupName &&
      sameGroupPath(this.displayedGroupPath, context.displayedGroupPath) &&
      this.activeTopLevelGroupName === context.activeTopLevelGroupName;
  }

  private cloneDisplayedGroupPath(): string[] | undefined {
    return this.displayedGroupPath === undefined ? undefined : cloneGroupPath(this.displayedGroupPath);
  }

  private extendDisplayedGroupPath(groupName: string): string[] {
    const path: string[] = this.cloneDisplayedGroupPath() ?? [];
    path.push(groupName);
    return path;
  }

  private displayedGroupPathKey(): string {
    const path: string[] | undefined = this.displayedGroupPath;
    if (path === undefined || path.length === 0) {
      return '';
    }
    return path.join('\u0000');
  }

  private isLiveDelayState(state: ProxyDelayViewState): boolean {
    return state === 'STARTING' || state === 'RUNNING';
  }

  private isActivationBusy(): boolean {
    return this.localOneClickPending || this.oneClickOperation.busy;
  }

  private publish(state: ProxyViewState): void {
    if (this.disposed) {
      return;
    }
    this.state = cloneProxyViewState(state);
    if (this.listeners.size === 0) {
      return;
    }
    const listeners: ProxyViewListener[] = [];
    this.listeners.forEach((listener: ProxyViewListener): void => {
      listeners.push(listener);
    });
    const snapshot: ProxyViewState = cloneProxyViewState(this.state);
    for (let index: number = 0; index < listeners.length; index += 1) {
      try {
        listeners[index](cloneProxyViewState(snapshot));
      } catch (_) {
      }
    }
  }

  private reconcileSavedIntentIdentity(profileId: string, revisionId: string, sessionId: string | null): void {
    let identityDrift: boolean = sessionId !== null;
    this.savedIntents.forEach((savedIntent: SavedProxyIntent): void => {
      if (savedIntent.profileId !== profileId || savedIntent.revisionId !== revisionId) {
        identityDrift = true;
      }
    });
    if (identityDrift) {
      this.savedIntents.clear();
    }
  }

  private reconcileAppliedNotPersistedIdentity(
    profileId: string,
    revisionId: string,
    sessionId: string | null
  ): void {
    const applied: AppliedNotPersistedState | undefined = this.appliedNotPersisted;
    if (applied === undefined) {
      return;
    }
    if (sessionId === null ||
      applied.profileId !== profileId ||
      applied.revisionId !== revisionId ||
      applied.sessionId !== sessionId) {
      this.appliedNotPersisted = undefined;
    }
  }
}

function cloneGroupPath(groupPath: string[]): string[] {
  const copy: string[] = [];
  for (let index: number = 0; index < groupPath.length; index += 1) {
    copy.push(groupPath[index]);
  }
  return copy;
}

function sameGroupPath(left: string[] | undefined, right: string[] | undefined): boolean {
  if (left === undefined || right === undefined) {
    return left === right;
  }
  if (left.length !== right.length) {
    return false;
  }
  for (let index: number = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) {
      return false;
    }
  }
  return true;
}

function createTabs(groups: CoreProxyGroupRef[], activeGroupName: string): ProxyGroupTabState[] {
  const tabs: ProxyGroupTabState[] = [];
  for (let index: number = 0; index < groups.length; index += 1) {
    tabs.push(createProxyGroupTabState(index, groups[index].name, groups[index].type, groups[index].name === activeGroupName));
  }
  return tabs;
}

function setActiveTopLevelGroup(groups: ProxyGroupTabState[], activeGroupName: string): ProxyGroupTabState[] {
  const tabs: ProxyGroupTabState[] = [];
  for (let index: number = 0; index < groups.length; index += 1) {
    tabs.push(createProxyGroupTabState(
      groups[index].index,
      groups[index].name,
      groups[index].type,
      groups[index].name === activeGroupName
    ));
  }
  return tabs;
}

function createRows(group: CoreProxyGroupSnapshot, savedNodeName?: string): ProxyNodeRowState[] {
  const rows: ProxyNodeRowState[] = [];
  for (let index: number = 0; index < group.nodes.length; index += 1) {
    rows.push(createProxyNodeRowState(
      index,
      group.nodes[index].name,
      group.nodes[index].type,
      group.nodes[index].isGroup,
      group.nodes[index].selected,
      savedNodeName !== undefined && group.nodes[index].name === savedNodeName
    ));
  }
  return rows;
}

function clearDelayRows(nodes: ProxyNodeRowState[]): ProxyNodeRowState[] {
  const rows: ProxyNodeRowState[] = [];
  for (let index: number = 0; index < nodes.length; index += 1) {
    rows.push(createProxyNodeRowState(
      nodes[index].index,
      nodes[index].name,
      nodes[index].type,
      nodes[index].isGroup,
      nodes[index].runtimeSelected,
      nodes[index].savedForNextStart
    ));
  }
  return rows;
}

function createTerminalFailedDelayRows(nodes: ProxyNodeRowState[]): ProxyNodeRowState[] {
  const rows: ProxyNodeRowState[] = [];
  for (let index: number = 0; index < nodes.length; index += 1) {
    const node: ProxyNodeRowState = nodes[index];
    const delayStatus: ProxyNodeDelayStatus = isCompletedDelayStatus(node.delayStatus)
      ? node.delayStatus
      : 'FAILED';
    rows.push(createProxyNodeRowState(
      node.index,
      node.name,
      node.type,
      node.isGroup,
      node.runtimeSelected,
      node.savedForNextStart,
      {
        delayStatus,
        delayMs: delayStatus === 'AVAILABLE' ? node.delayMs : undefined,
        delayFastest: delayStatus === 'AVAILABLE' && node.delayFastest
      }
    ));
  }
  return rows;
}

function preserveDelayOverlay(
  nextRows: ProxyNodeRowState[],
  currentRows: ProxyNodeRowState[],
  delayState: ProxyDelayViewState
): ProxyNodeRowState[] {
  if (delayState === 'IDLE' || delayState === 'STARTING') {
    return nextRows;
  }
  if (nextRows.length !== currentRows.length) {
    return nextRows;
  }
  const rows: ProxyNodeRowState[] = [];
  for (let index: number = 0; index < nextRows.length; index += 1) {
    const next: ProxyNodeRowState = nextRows[index];
    const current: ProxyNodeRowState = currentRows[index];
    if (next.index !== current.index || next.name !== current.name || next.type !== current.type) {
      return nextRows;
    }
    rows.push(createProxyNodeRowState(
      next.index,
      next.name,
      next.type,
      next.isGroup,
      next.runtimeSelected,
      next.savedForNextStart,
      {
        delayStatus: current.delayStatus,
        delayMs: current.delayMs,
        delayFastest: current.delayFastest
      }
    ));
  }
  return rows;
}

function containsSavedMarker(nodes: ProxyNodeRowState[]): boolean {
  for (let index: number = 0; index < nodes.length; index += 1) {
    if (nodes[index].savedForNextStart) {
      return true;
    }
  }
  return false;
}

function createSavedIntent(
  profileId: string,
  revisionId: string,
  groupName: string,
  nodeName: string
): SavedProxyIntent {
  const intent: SavedProxyIntentValue = new SavedProxyIntentValue();
  intent.profileId = profileId;
  intent.revisionId = revisionId;
  intent.groupName = groupName;
  intent.nodeName = nodeName;
  return intent;
}

function createAppliedNotPersistedState(
  profileId: string,
  revisionId: string,
  sessionId: string | null
): AppliedNotPersistedState | undefined {
  if (sessionId === null) {
    return undefined;
  }
  const state: AppliedNotPersistedStateValue = new AppliedNotPersistedStateValue();
  state.profileId = profileId;
  state.revisionId = revisionId;
  state.sessionId = sessionId;
  return state;
}

function markSavedRow(nodes: ProxyNodeRowState[], savedNodeName: string): ProxyNodeRowState[] {
  const rows: ProxyNodeRowState[] = [];
  for (let index: number = 0; index < nodes.length; index += 1) {
    rows.push(createProxyNodeRowState(
      nodes[index].index,
      nodes[index].name,
      nodes[index].type,
      nodes[index].isGroup,
      nodes[index].runtimeSelected,
      nodes[index].name === savedNodeName,
      {
        delayStatus: nodes[index].delayStatus,
        delayMs: nodes[index].delayMs,
        delayFastest: nodes[index].delayFastest
      }
    ));
  }
  return rows;
}

function normalizeDelayNodeStatus(
  jobState: string,
  node: ProxyDelayNodeResult
): ProxyNodeDelayStatus {
  if (jobState === 'CANCELLED' &&
    (node.state === 'WAITING' || node.state === 'TESTING' || node.state === 'CANCELLED')) {
    return 'CANCELLED';
  }
  return node.state;
}

function isCompletedDelayStatus(status: ProxyNodeDelayStatus): boolean {
  return status === 'AVAILABLE' ||
    status === 'TIMEOUT' ||
    status === 'FAILED' ||
    status === 'CANCELLED' ||
    status === 'UNSUPPORTED';
}

function nextEpochValue(current: number): number {
  if (current >= Number.MAX_SAFE_INTEGER) {
    return 1;
  }
  return current + 1;
}

function summarizeDelayRows(delayState: ProxyDelayViewState, rows: ProxyNodeRowState[]): DelaySummaryValue {
  const summary: DelaySummaryValue = new DelaySummaryValue();
  if (delayState === 'IDLE' || delayState === 'STARTING') {
    return summary;
  }
  summary.totalDelayCount = rows.length;
  for (let index: number = 0; index < rows.length; index += 1) {
    const row: ProxyNodeRowState = rows[index];
    if (row.delayStatus !== 'UNSUPPORTED') {
      summary.testableDelayCount += 1;
    }
    if (row.delayStatus === 'AVAILABLE' ||
      row.delayStatus === 'TIMEOUT' ||
      row.delayStatus === 'FAILED' ||
      row.delayStatus === 'CANCELLED' ||
      row.delayStatus === 'UNSUPPORTED') {
      summary.completedDelayCount += 1;
    }
    if (row.delayStatus === 'AVAILABLE') {
      summary.availableDelayCount += 1;
    } else if (row.delayStatus === 'TIMEOUT') {
      summary.timeoutDelayCount += 1;
    } else if (row.delayStatus === 'FAILED') {
      summary.failedDelayCount += 1;
    } else if (row.delayStatus === 'CANCELLED') {
      summary.cancelledDelayCount += 1;
    } else if (row.delayStatus === 'UNSUPPORTED') {
      summary.unsupportedDelayCount += 1;
    }
    if (row.delayFastest) {
      summary.fastestDelayNodeIndex = index;
    }
  }
  return summary;
}
