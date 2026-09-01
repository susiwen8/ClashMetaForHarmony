import { describe, expect, it } from '@ohos/hypium';
import type {
  CoreProxyGroupRef,
  CoreProxyGroupSnapshot,
  CoreProxyNodeSummary,
  CoreProxyType,
  OneClickVpnOperationSnapshot,
  ProxyDelayNodeResult,
  ProxyDelayResult,
  ProxyDelaySnapshotResult,
  ProxyGroupListQueryResult,
  ProxyGroupQueryResult,
  ProxyOneClickVpnApplicationPort,
  ProxyReconcileResult,
  ProxyRejectedResult,
  ProxyRejectedErrorCode,
  ProxySelectionResult,
  SelectNodeAndEnsureVpnResult
} from '@cmfa/shared';
import {
  cloneOneClickVpnOperationSnapshot,
  createOneClickVpnFailureResult,
  createOneClickVpnOperationSnapshot,
  createProxyDelayNodeResult,
  createProxyDelaySnapshotResult,
  createProxyGroupListQuerySnapshot,
  createProxyGroupQuerySnapshot,
  createProxyGroupSnapshot,
  createProxyRejectedError,
  createProxyRejectedResult,
  createProxyRuntimeIdentity,
  createProxySelectionAppliedNowResult,
  createProxySelectionAppliedNotPersistedResult,
  createProxySelectionRecord,
  createProxySelectionSavedForNextStartResult,
  createSelectNodeAndEnsureVpnSuccessResult
} from '@cmfa/shared';
import {
  ProxyViewModel,
  type ProxyViewDeadlinePort
} from '../main/ets/presentation/ProxyViewModel';
import type { ProxyViewState } from '../main/ets/presentation/ProxyPresentationModels';
import { DeferredResult, ManualDelayScheduler } from './fakes/PresentationFakes';

interface QueryCall {
  groupName: string;
  groupPath?: string[];
}

interface SelectCall {
  groupName: string;
  memberName: string;
  snapshotGeneration: number;
  groupPath?: string[];
}

interface OneClickCall {
  groupName: string;
  memberName: string;
  snapshotGeneration: number;
  groupPath?: string[];
}

interface DelayStartCall {
  groupName: string;
  snapshotGeneration: number;
  groupPath?: string[];
}

interface DelayJobCall {
  jobId: string;
}

interface OneClickFailureCase {
  stage: 'ADMISSION' | 'SELECTION' | 'VPN_START' | 'VPN_CONFIRMATION';
  code:
    | 'OPERATION_BUSY'
    | 'PROXY_SELECTION_STALE'
    | 'PROXY_SELECTION_FAILED'
    | 'PROXY_PERSISTENCE_FAILED'
    | 'VPN_PROFILE_UNAVAILABLE'
    | 'VPN_PERMISSION_DENIED'
    | 'VPN_START_FAILED'
    | 'VPN_STOPPED_BEFORE_RUNNING'
    | 'VPN_CONFIRMATION_TIMEOUT'
    | 'VPN_SESSION_CHANGED';
  retryable: boolean;
  resourceId:
    | 'proxies_one_click_busy'
    | 'proxies_error_selection_stale'
    | 'proxies_error_selection_failed'
    | 'proxies_error_persistence_failed'
    | 'error_vpn_profile_unavailable'
    | 'error_vpn_permission_denied'
    | 'error_vpn_start_failed'
    | 'proxies_one_click_confirmation_timeout'
    | 'proxies_error_session_changed';
  savedForNextStart: boolean;
}

class ImmediateDeadlinePort implements ProxyViewDeadlinePort {
  async run<T>(operation: () => Promise<T>): Promise<T> {
    return await operation();
  }
}

class OneClickFailureCaseValue implements OneClickFailureCase {
  stage: 'ADMISSION' | 'SELECTION' | 'VPN_START' | 'VPN_CONFIRMATION' = 'ADMISSION';
  code:
    | 'OPERATION_BUSY'
    | 'PROXY_SELECTION_STALE'
    | 'PROXY_SELECTION_FAILED'
    | 'PROXY_PERSISTENCE_FAILED'
    | 'VPN_PROFILE_UNAVAILABLE'
    | 'VPN_PERMISSION_DENIED'
    | 'VPN_START_FAILED'
    | 'VPN_STOPPED_BEFORE_RUNNING'
    | 'VPN_CONFIRMATION_TIMEOUT'
    | 'VPN_SESSION_CHANGED' = 'OPERATION_BUSY';
  retryable: boolean = false;
  resourceId:
    | 'proxies_one_click_busy'
    | 'proxies_error_selection_stale'
    | 'proxies_error_selection_failed'
    | 'proxies_error_persistence_failed'
    | 'error_vpn_profile_unavailable'
    | 'error_vpn_permission_denied'
    | 'error_vpn_start_failed'
    | 'proxies_one_click_confirmation_timeout'
    | 'proxies_error_session_changed' = 'proxies_one_click_busy';
  savedForNextStart: boolean = false;
}

class TimeoutDeadlinePort implements ProxyViewDeadlinePort {
  async run<T>(_operation: () => Promise<T>): Promise<T> {
    return await Promise.reject(new Error('deadline exceeded'));
  }
}

class LimitedDeadlinePort implements ProxyViewDeadlinePort {
  private remainingPasses: number;

  constructor(remainingPasses: number) {
    this.remainingPasses = remainingPasses;
  }

  async run<T>(operation: () => Promise<T>): Promise<T> {
    if (this.remainingPasses <= 0) {
      return await Promise.reject(new Error('deadline exceeded'));
    }
    this.remainingPasses -= 1;
    return await operation();
  }
}

class DeferredFailureResult<T> {
  readonly promise: Promise<T>;
  private rejectRef?: (reason: Object) => void;

  constructor() {
    this.promise = new Promise<T>((_resolve, reject: (reason?: Object) => void) => {
      this.rejectRef = (reason: Object): void => {
        reject(reason);
      };
    });
  }

  reject(reason: Object): void {
    this.rejectRef?.(reason);
  }
}

class RecordingProxyApplicationPort implements ProxyOneClickVpnApplicationPort {
  readonly queryCalls: QueryCall[] = [];
  readonly selectCalls: SelectCall[] = [];
  readonly oneClickCalls: OneClickCall[] = [];
  readonly startDelayCalls: DelayStartCall[] = [];
  readonly readDelayCalls: DelayJobCall[] = [];
  readonly cancelDelayCalls: DelayJobCall[] = [];
  cancelAndDrainCalls: number = 0;
  listGroupsCalls: number = 0;
  oneClickUnsubscribeCalls: number = 0;
  replayCurrentSnapshotOnSubscribe: boolean = false;
  subscribeSynchronousSnapshot?: OneClickVpnOperationSnapshot;
  private readonly listResults: Promise<ProxyGroupListQueryResult>[] = [];
  private readonly queryResults: Map<string, Promise<ProxyGroupQueryResult>[]> = new Map();
  private readonly selectResults: Promise<ProxySelectionResult>[] = [];
  private readonly oneClickResults: Promise<SelectNodeAndEnsureVpnResult>[] = [];
  private readonly startDelayResults: Promise<ProxyDelayResult>[] = [];
  private readonly readDelayResults: Promise<ProxyDelayResult>[] = [];
  private readonly cancelDelayResults: Promise<ProxyDelayResult>[] = [];
  private readonly cancelAndDrainResults: Promise<ProxyRejectedResult | undefined>[] = [];
  private readonly oneClickListeners: Map<number, (snapshot: OneClickVpnOperationSnapshot) => void> = new Map();
  private readonly currentOneClickSnapshots: OneClickVpnOperationSnapshot[] = [];
  private nextOneClickListenerId: number = 0;
  private oneClickSnapshot: OneClickVpnOperationSnapshot = createOneClickVpnOperationSnapshot('IDLE', false, 'NONE');

  queueListGroupsResult(result: ProxyGroupListQueryResult | Promise<ProxyGroupListQueryResult>): void {
    this.listResults.push(Promise.resolve(result));
  }

  queueQueryGroupResult(
    groupName: string,
    result: ProxyGroupQueryResult | Promise<ProxyGroupQueryResult>,
    groupPath?: string[]
  ): void {
    const queueKey: string = queryKey(groupName, groupPath);
    const queue: Promise<ProxyGroupQueryResult>[] = this.queryResults.get(queueKey) ?? [];
    queue.push(Promise.resolve(result));
    this.queryResults.set(queueKey, queue);
  }

  queueSelectResult(result: ProxySelectionResult | Promise<ProxySelectionResult>): void {
    this.selectResults.push(Promise.resolve(result));
  }

  queueSelectNodeAndEnsureVpnResult(result: SelectNodeAndEnsureVpnResult | Promise<SelectNodeAndEnsureVpnResult>): void {
    this.oneClickResults.push(Promise.resolve(result));
  }

  queueStartDelayResult(result: ProxyDelayResult | Promise<ProxyDelayResult>): void {
    this.startDelayResults.push(Promise.resolve(result));
  }

  queueReadDelayResult(result: ProxyDelayResult | Promise<ProxyDelayResult>): void {
    this.readDelayResults.push(Promise.resolve(result));
  }

  queueCancelDelayResult(result: ProxyDelayResult | Promise<ProxyDelayResult>): void {
    this.cancelDelayResults.push(Promise.resolve(result));
  }

  queueCancelAndDrainResult(result: ProxyRejectedResult | Promise<ProxyRejectedResult | undefined> | undefined): void {
    this.cancelAndDrainResults.push(Promise.resolve(result));
  }

  queueCurrentOneClickSnapshot(snapshot: OneClickVpnOperationSnapshot): void {
    this.currentOneClickSnapshots.push(cloneOneClickVpnOperationSnapshot(snapshot));
  }

  currentOneClickVpnOperation(): OneClickVpnOperationSnapshot {
    const queued: OneClickVpnOperationSnapshot | undefined = this.currentOneClickSnapshots.shift();
    if (queued !== undefined) {
      this.oneClickSnapshot = cloneOneClickVpnOperationSnapshot(queued);
    }
    return cloneOneClickVpnOperationSnapshot(this.oneClickSnapshot);
  }

  subscribeOneClickVpnOperation(listener: (snapshot: OneClickVpnOperationSnapshot) => void): number {
    this.nextOneClickListenerId += 1;
    this.oneClickListeners.set(this.nextOneClickListenerId, listener);
    if (this.replayCurrentSnapshotOnSubscribe) {
      listener(cloneOneClickVpnOperationSnapshot(this.oneClickSnapshot));
    }
    if (this.subscribeSynchronousSnapshot !== undefined) {
      this.publishOneClickOperation(this.subscribeSynchronousSnapshot);
    }
    return this.nextOneClickListenerId;
  }

  unsubscribeOneClickVpnOperation(id: number): void {
    this.oneClickUnsubscribeCalls += 1;
    this.oneClickListeners.delete(id);
  }

  publishOneClickOperation(snapshot: OneClickVpnOperationSnapshot): void {
    this.oneClickSnapshot = cloneOneClickVpnOperationSnapshot(snapshot);
    const listeners: Array<(snapshot: OneClickVpnOperationSnapshot) => void> = [];
    this.oneClickListeners.forEach((listener) => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneOneClickVpnOperationSnapshot(this.oneClickSnapshot));
    }
  }

  async listGroups(): Promise<ProxyGroupListQueryResult> {
    this.listGroupsCalls += 1;
    return await shiftOrThrow(this.listResults, 'listGroups');
  }

  async queryGroup(groupName: string, groupPath?: string[]): Promise<ProxyGroupQueryResult> {
    this.queryCalls.push({
      groupName,
      groupPath: cloneGroupPath(groupPath)
    });
    const exactQueue: Promise<ProxyGroupQueryResult>[] | undefined = this.queryResults.get(queryKey(groupName, groupPath));
    const queue: Promise<ProxyGroupQueryResult>[] | undefined = exactQueue ?? this.queryResults.get(queryKey(groupName));
    if (queue === undefined) {
      throw new Error('Missing query result');
    }
    return await shiftOrThrow(queue, 'queryGroup');
  }

  async select(
    groupName: string,
    memberName: string,
    snapshotGeneration: number,
    groupPath?: string[]
  ): Promise<ProxySelectionResult> {
    this.selectCalls.push({
      groupName,
      memberName,
      snapshotGeneration,
      groupPath: cloneGroupPath(groupPath)
    });
    return await shiftOrThrow(this.selectResults, 'select');
  }

  async selectNodeAndEnsureVpn(
    groupName: string,
    memberName: string,
    snapshotGeneration: number,
    groupPath?: string[]
  ): Promise<SelectNodeAndEnsureVpnResult> {
    this.oneClickCalls.push({
      groupName,
      memberName,
      snapshotGeneration,
      groupPath: cloneGroupPath(groupPath)
    });
    return await shiftOrThrow(this.oneClickResults, 'selectNodeAndEnsureVpn');
  }

  async reconcileActiveSelections(): Promise<ProxyReconcileResult> {
    return await Promise.reject(new Error('reconcileActiveSelections should stay unused in ProxyViewModel tests'));
  }

  async startDelayTest(groupName: string, snapshotGeneration: number, groupPath?: string[]): Promise<ProxyDelayResult> {
    this.startDelayCalls.push({
      groupName,
      snapshotGeneration,
      groupPath: cloneGroupPath(groupPath)
    });
    return await shiftOrThrow(this.startDelayResults, 'startDelayTest');
  }

  async readDelayTest(jobId: string): Promise<ProxyDelayResult> {
    this.readDelayCalls.push({ jobId });
    return await shiftOrThrow(this.readDelayResults, 'readDelayTest');
  }

  async cancelDelayTest(jobId: string): Promise<ProxyDelayResult> {
    this.cancelDelayCalls.push({ jobId });
    return await shiftOrThrow(this.cancelDelayResults, 'cancelDelayTest');
  }

  async cancelAndDrainDelayTest(): Promise<ProxyRejectedResult | undefined> {
    this.cancelAndDrainCalls += 1;
    return await shiftOrThrow(this.cancelAndDrainResults, 'cancelAndDrainDelayTest');
  }
}

function shiftOrThrow<T>(queue: Promise<T>[], label: string): Promise<T> {
  const next: Promise<T> | undefined = queue.shift();
  if (next === undefined) {
    throw new Error(`Missing queued result for ${label}`);
  }
  return next;
}

function cloneGroupPath(groupPath?: string[]): string[] | undefined {
  if (groupPath === undefined) {
    return undefined;
  }
  return groupPath.slice();
}

function queryKey(groupName: string, groupPath?: string[]): string {
  if (groupPath === undefined || groupPath.length === 0) {
    return groupName;
  }
  return `${groupName}\u0000${groupPath.join('\u0000')}`;
}

function proxyHash(seed: string): string {
  let value: string = '';
  while (value.length < 64) {
    value += seed;
  }
  return value.substring(0, 64).replace(/[^0-9a-f]/gi, 'a');
}

class CoreProxyGroupRefValue implements CoreProxyGroupRef {
  name: string = '';
  type: CoreProxyType = 'Selector';
}

class CoreProxyNodeSummaryValue implements CoreProxyNodeSummary {
  name: string = '';
  type: CoreProxyType = 'Direct';
  isGroup: boolean = false;
  selected: boolean = false;
}

class CoreProxyGroupSnapshotValue implements CoreProxyGroupSnapshot {
  name: string = '';
  type: CoreProxyType = 'Selector';
  selectedName: string = '';
  nodes: CoreProxyNodeSummary[] = [];
}

function createIdentity(sessionId: string | null = 'session-a', profileId: string = 'profile-a') {
  return createProxyRuntimeIdentity(
    profileId,
    '2026-08-11T12:30:00.000Z',
    proxyHash('ab'),
    sessionId
  );
}

function createGroupRef(name: string, type: CoreProxyType = 'Selector'): CoreProxyGroupRef {
  const value: CoreProxyGroupRefValue = new CoreProxyGroupRefValue();
  value.name = name;
  value.type = type;
  return value;
}

function createNode(
  name: string,
  selected: boolean,
  isGroup: boolean = false,
  type: CoreProxyType = isGroup ? 'Selector' : 'Direct'
): CoreProxyNodeSummary {
  const value: CoreProxyNodeSummaryValue = new CoreProxyNodeSummaryValue();
  value.name = name;
  value.type = type;
  value.isGroup = isGroup;
  value.selected = selected;
  return value;
}

function createGroupSnapshotModel(
  name: string,
  selectedName: string,
  nodes: CoreProxyNodeSummary[],
  type: CoreProxyType = 'Selector'
): CoreProxyGroupSnapshot {
  const value: CoreProxyGroupSnapshotValue = new CoreProxyGroupSnapshotValue();
  value.name = name;
  value.type = type;
  value.selectedName = selectedName;
  value.nodes = nodes;
  return value;
}

function createListResult(
  groupNames: string[],
  generation: number = 5,
  sessionId: string | null = 'session-a',
  profileId: string = 'profile-a'
): ProxyGroupListQueryResult {
  const groups: CoreProxyGroupRef[] = [];
  for (let index: number = 0; index < groupNames.length; index += 1) {
    groups.push(createGroupRef(groupNames[index]));
  }
  return createProxyGroupListQuerySnapshot(createIdentity(sessionId, profileId), generation, groups);
}

function createQueryResult(
  groupName: string,
  selectedName: string,
  nodeNames: string[],
  generation: number = 5,
  nestedIndexes: number[] = [],
  sessionId: string | null = 'session-a'
): ProxyGroupQueryResult {
  const nodes: CoreProxyNodeSummary[] = [];
  for (let index: number = 0; index < nodeNames.length; index += 1) {
    nodes.push(createNode(
      nodeNames[index],
      nodeNames[index] === selectedName,
      nestedIndexes.includes(index)
    ));
  }
  return createProxyGroupQuerySnapshot(
    createProxyGroupSnapshot(
      createIdentity(sessionId),
      generation,
      createGroupSnapshotModel(groupName, selectedName, nodes)
    )
  );
}

function createRejectedListResult(
  code: ProxyRejectedErrorCode,
  retryable: boolean
): ProxyGroupListQueryResult {
  return createProxyRejectedResult(createProxyRejectedError(code, retryable, '2026-08-11T12:30:00.000Z'));
}

function createRejectedGroupResult(
  code: ProxyRejectedErrorCode,
  retryable: boolean
): ProxyGroupQueryResult {
  return createProxyRejectedResult(createProxyRejectedError(code, retryable, '2026-08-11T12:30:00.000Z'));
}

function createRejectedSelectionResult(
  code: ProxyRejectedErrorCode,
  retryable: boolean
): ProxySelectionResult {
  return createProxyRejectedResult(createProxyRejectedError(code, retryable, '2026-08-11T12:30:00.000Z'));
}

function createAppliedNowSelection(groupName: string, selectedName: string, generation: number): ProxySelectionResult {
  const snapshot = createProxyGroupSnapshot(
    createIdentity(),
    generation,
    createGroupSnapshotModel(groupName, selectedName, [
      createNode('Node A', selectedName === 'Node A'),
      createNode('Node B', selectedName === 'Node B')
    ])
  );
  const record = createProxySelectionRecord(
    'profile-a',
    groupName,
    selectedName,
    '2026-08-11T12:30:00.000Z',
    '2026-08-11T12:31:00.000Z'
  );
  return createProxySelectionAppliedNowResult(snapshot, record, '2026-08-11T12:31:00.000Z');
}

function createSavedSelection(groupName: string, selectedName: string): ProxySelectionResult {
  return createProxySelectionSavedForNextStartResult(
    createProxySelectionRecord(
      'profile-a',
      groupName,
      selectedName,
      '2026-08-11T12:30:00.000Z',
      '2026-08-11T12:31:00.000Z'
    ),
    '2026-08-11T12:31:00.000Z'
  );
}

function createAppliedNotPersistedSelection(groupName: string, selectedName: string, generation: number): ProxySelectionResult {
  const snapshot = createProxyGroupSnapshot(
    createIdentity(),
    generation,
    createGroupSnapshotModel(groupName, selectedName, [
      createNode('Node A', selectedName === 'Node A'),
      createNode('Node B', selectedName === 'Node B')
    ])
  );
  const record = createProxySelectionRecord(
    'profile-a',
    groupName,
    selectedName,
    '2026-08-11T12:30:00.000Z',
    '2026-08-11T12:31:00.000Z'
  );
  return createProxySelectionAppliedNotPersistedResult(
    snapshot,
    record,
    createProxyRejectedError('PROXY_PERSISTENCE_FAILED', true, '2026-08-11T12:31:00.000Z'),
    '2026-08-11T12:31:00.000Z'
  );
}

function createOneClickFailureCase(
  stage: 'ADMISSION' | 'SELECTION' | 'VPN_START' | 'VPN_CONFIRMATION',
  code:
    | 'OPERATION_BUSY'
    | 'PROXY_SELECTION_STALE'
    | 'PROXY_SELECTION_FAILED'
    | 'PROXY_PERSISTENCE_FAILED'
    | 'VPN_PROFILE_UNAVAILABLE'
    | 'VPN_PERMISSION_DENIED'
    | 'VPN_START_FAILED'
    | 'VPN_STOPPED_BEFORE_RUNNING'
    | 'VPN_CONFIRMATION_TIMEOUT'
    | 'VPN_SESSION_CHANGED',
  retryable: boolean,
  resourceId:
    | 'proxies_one_click_busy'
    | 'proxies_error_selection_stale'
    | 'proxies_error_selection_failed'
    | 'proxies_error_persistence_failed'
    | 'error_vpn_profile_unavailable'
    | 'error_vpn_permission_denied'
    | 'error_vpn_start_failed'
    | 'proxies_one_click_confirmation_timeout'
    | 'proxies_error_session_changed',
  savedForNextStart: boolean
): OneClickFailureCase {
  const value = new OneClickFailureCaseValue();
  value.stage = stage;
  value.code = code;
  value.retryable = retryable;
  value.resourceId = resourceId;
  value.savedForNextStart = savedForNextStart;
  return value;
}

function createDelayNodeResultValue(
  index: number,
  name: string,
  state: 'WAITING' | 'TESTING' | 'AVAILABLE' | 'TIMEOUT' | 'FAILED' | 'CANCELLED' | 'UNSUPPORTED',
  type: CoreProxyType = 'Direct',
  delayMs: number | null = null,
  fastest: boolean = false
): ProxyDelayNodeResult {
  return createProxyDelayNodeResult(index, name, type, state, delayMs, fastest);
}

function createDelaySnapshotResultValue(
  groupName: string,
  generation: number,
  jobId: string,
  state: 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED',
  nodes: ProxyDelayNodeResult[],
  sessionId: string | null = 'session-a'
): ProxyDelaySnapshotResult {
  let testableCount: number = 0;
  let completedCount: number = 0;
  let availableCount: number = 0;
  let timeoutCount: number = 0;
  let failedCount: number = 0;
  let cancelledCount: number = 0;
  let unsupportedCount: number = 0;
  let fastestNodeIndex: number | null = null;
  for (let index: number = 0; index < nodes.length; index += 1) {
    const node: ProxyDelayNodeResult = nodes[index];
    if (node.state !== 'UNSUPPORTED') {
      testableCount += 1;
    }
    if (node.state === 'AVAILABLE' ||
      node.state === 'TIMEOUT' ||
      node.state === 'FAILED' ||
      node.state === 'CANCELLED' ||
      node.state === 'UNSUPPORTED') {
      completedCount += 1;
    }
    if (node.state === 'AVAILABLE') {
      availableCount += 1;
    } else if (node.state === 'TIMEOUT') {
      timeoutCount += 1;
    } else if (node.state === 'FAILED') {
      failedCount += 1;
    } else if (node.state === 'CANCELLED') {
      cancelledCount += 1;
    } else if (node.state === 'UNSUPPORTED') {
      unsupportedCount += 1;
    }
    if (node.fastest) {
      fastestNodeIndex = index;
    }
  }
  return createProxyDelaySnapshotResult(
    createIdentity(sessionId),
    generation,
    groupName,
    jobId,
    state,
    nodes.length,
    testableCount,
    completedCount,
    availableCount,
    timeoutCount,
    failedCount,
    cancelledCount,
    unsupportedCount,
    fastestNodeIndex,
    nodes
  );
}

function createRejectedDelayResult(
  code: ProxyRejectedErrorCode,
  retryable: boolean
): ProxyDelayResult {
  return createProxyRejectedResult(createProxyRejectedError(code, retryable, '2026-08-11T12:30:00.000Z'));
}

function lastPublished(states: ProxyViewState[]): ProxyViewState {
  return states[states.length - 1];
}

async function flushPromises(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

export default function proxyViewModelTestsuite(): void {
  describe('ProxyViewModelTest', () => {
    it('loadsOrderedGroupsThenQueriesTheFirstGroup', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      service.queueListGroupsResult(createListResult(['Group A', 'Group B'], 8));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 8));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();

      const state = viewModel.current();
      expect(service.listGroupsCalls).assertEqual(1);
      expect(service.queryCalls.length).assertEqual(1);
      expect(service.queryCalls[0].groupName).assertEqual('Group A');
      expect(state.status).assertEqual('READY');
      expect(state.groups.length).assertEqual(2);
      expect(state.groups[0].active).assertTrue();
      expect(state.groupGeneration).assertEqual(8);
      expect(state.nodes.length).assertEqual(2);
      expect(state.nodes[0].runtimeSelected).assertTrue();
      expect(state.nodes[1].runtimeSelected).assertFalse();
      expect(state.warning).assertEqual('NONE');
    });

    it('publishesEmptyWhenTheGroupListIsEmpty', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      service.queueListGroupsResult(createListResult([], 3));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();

      const state = viewModel.current();
      expect(state.status).assertEqual('EMPTY');
      expect(state.groups.length).assertEqual(0);
      expect(state.nodes.length).assertEqual(0);
      expect(service.queryCalls.length).assertEqual(0);
    });

    it('clearsOldRowsBeforeAsyncReloadAndRejectsAProfileIdentityMismatch', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      service.queueListGroupsResult(createListResult(['Group A'], 3));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A'], 3));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());
      await viewModel.load('profile-a');
      expect(viewModel.current().nodes.length).assertEqual(1);

      const deferred = new DeferredResult<ProxyGroupListQueryResult>();
      service.queueListGroupsResult(deferred.promise);
      const reload = viewModel.load('profile-b');

      expect(viewModel.current().status).assertEqual('LOADING');
      expect(viewModel.current().groups.length).assertEqual(0);
      expect(viewModel.current().nodes.length).assertEqual(0);

      deferred.resolve(createListResult(['Wrong Profile Group'], 4, 'session-b', 'profile-a'));
      await reload;

      expect(viewModel.current().status).assertEqual('ERROR');
      expect(viewModel.current().errorCode).assertEqual('PROXY_PROFILE_UNAVAILABLE');
      expect(viewModel.current().errorRetryable).assertFalse();
      expect(service.queryCalls.length).assertEqual(1);
    });

    it('mapsEveryClosedProxyErrorAndRetryReloads', 0, async () => {
      const codes: ProxyRejectedErrorCode[] = [
        'PROXY_PROFILE_UNAVAILABLE',
        'PROXY_RUNTIME_NOT_READY',
        'PROXY_SELECTION_STALE',
        'PROXY_QUERY_FAILED',
        'PROXY_SELECTION_FAILED',
        'PROXY_PERSISTENCE_FAILED',
        'VPN_SESSION_CHANGED'
      ];

      for (let index: number = 0; index < codes.length; index += 1) {
        const service = new RecordingProxyApplicationPort();
        service.queueListGroupsResult(createRejectedListResult(codes[index], index % 2 === 0));
        const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());
        await viewModel.load();
        const state = viewModel.current();
        expect(state.status).assertEqual('ERROR');
        expect(state.errorCode).assertEqual(codes[index]);
        expect(state.errorRetryable).assertEqual(index % 2 === 0);
      }

      const retryService = new RecordingProxyApplicationPort();
      retryService.queueListGroupsResult(createRejectedListResult('PROXY_RUNTIME_NOT_READY', true));
      retryService.queueListGroupsResult(createListResult(['Group A'], 6));
      retryService.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A'], 6));
      const retryViewModel = new ProxyViewModel(retryService, new ImmediateDeadlinePort());

      await retryViewModel.load();
      await retryViewModel.retry();

      expect(retryViewModel.current().status).assertEqual('READY');
      expect(retryService.listGroupsCalls).assertEqual(2);
    });

    it('mapsDeadlineExpiryToRetryableQueryFailureWithoutEchoingLabels', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      service.queueListGroupsResult(createListResult(['Group A'], 6));
      const viewModel = new ProxyViewModel(service, new TimeoutDeadlinePort());

      await viewModel.load();

      const state = viewModel.current();
      expect(state.status).assertEqual('ERROR');
      expect(state.errorCode).assertEqual('PROXY_QUERY_FAILED');
      expect(state.errorRetryable).assertTrue();
      expect(state.groups.length).assertEqual(0);
      expect(state.nodes.length).assertEqual(0);
    });

    it('switchesGroupsAndNavigatesNestedRowsByName', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      service.queueListGroupsResult(createListResult(['Group A', 'Group B'], 9));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Nested Group'], 9, [1]));
      service.queueQueryGroupResult('Group B', createQueryResult('Group B', 'Node C', ['Node C'], 9));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Nested Group'], 9, [1]));
      service.queueQueryGroupResult('Nested Group', createQueryResult('Nested Group', 'Nested Node', ['Nested Node'], 11));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      await viewModel.openGroup(1);
      await viewModel.openGroup(0);
      await viewModel.activateNode(1);

      const state = viewModel.current();
      expect(service.queryCalls.length).assertEqual(4);
      expect(service.queryCalls[1].groupName).assertEqual('Group B');
      expect(service.queryCalls[3].groupName).assertEqual('Nested Group');
      expect(state.status).assertEqual('READY');
      expect(state.nodes.length).assertEqual(1);
      expect(state.nodes[0].name).assertEqual('Nested Node');
      expect(state.groups[0].active).assertTrue();
      expect(state.groups[1].active).assertFalse();
      expect(state.groupGeneration).assertEqual(11);
    });

    it('propagatesExactNestedGroupPathsAcrossDuplicateBranchesForRefreshOneClickAndDelay', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      service.queueListGroupsResult(createListResult(['Gateway', 'Mirror'], 200, 'vpn-session'));
      service.queueQueryGroupResult(
        'Gateway',
        createQueryResult('Gateway', 'Shared', ['Shared', 'Gateway Direct'], 200, [0], 'vpn-session'),
        ['Gateway']
      );
      service.queueQueryGroupResult(
        'Shared',
        createQueryResult('Shared', 'Tokyo', ['Tokyo', 'Seoul'], 201, [], 'vpn-session'),
        ['Gateway', 'Shared']
      );
      service.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      service.queueQueryGroupResult(
        'Shared',
        createQueryResult('Shared', 'Seoul', ['Tokyo', 'Seoul'], 202, [], 'vpn-session'),
        ['Gateway', 'Shared']
      );
      service.queueQueryGroupResult(
        'Mirror',
        createQueryResult('Mirror', 'Shared', ['Shared'], 203, [0], 'vpn-session'),
        ['Mirror']
      );
      service.queueQueryGroupResult(
        'Shared',
        createQueryResult('Shared', 'Osaka', ['Osaka', 'Kyoto'], 204, [], 'vpn-session'),
        ['Mirror', 'Shared']
      );
      service.queueStartDelayResult(createDelaySnapshotResultValue('Shared', 204, 'mirror-shared-delay', 'RUNNING', [
        createDelayNodeResultValue(0, 'Osaka', 'TESTING'),
        createDelayNodeResultValue(1, 'Kyoto', 'WAITING')
      ], 'vpn-session'));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);

      await viewModel.load();
      await viewModel.activateNode(0);
      await viewModel.activateNode(1);
      await viewModel.openGroup(1);
      await viewModel.activateNode(0);
      await viewModel.toggleDelayTest();

      expect(service.queryCalls.length).assertEqual(5);
      expect((service.queryCalls[0].groupPath ?? []).join('/')).assertEqual('Gateway');
      expect((service.queryCalls[1].groupPath ?? []).join('/')).assertEqual('Gateway/Shared');
      expect((service.queryCalls[2].groupPath ?? []).join('/')).assertEqual('Gateway/Shared');
      expect((service.queryCalls[3].groupPath ?? []).join('/')).assertEqual('Mirror');
      expect((service.queryCalls[4].groupPath ?? []).join('/')).assertEqual('Mirror/Shared');
      expect(service.oneClickCalls.length).assertEqual(1);
      expect((service.oneClickCalls[0].groupPath ?? []).join('/')).assertEqual('Gateway/Shared');
      expect(service.oneClickCalls[0].groupName).assertEqual('Shared');
      expect(service.oneClickCalls[0].memberName).assertEqual('Seoul');
      expect(service.startDelayCalls.length).assertEqual(1);
      expect((service.startDelayCalls[0].groupPath ?? []).join('/')).assertEqual('Mirror/Shared');
      expect(service.startDelayCalls[0].groupName).assertEqual('Shared');
      expect(service.startDelayCalls[0].snapshotGeneration).assertEqual(204);
      expect(viewModel.current().delayState).assertEqual('RUNNING');
    });

    it('suppressesOlderInflightGroupResultsWhenANewerChoiceWins', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const olderGroup = new DeferredResult<ProxyGroupQueryResult>();
      service.queueListGroupsResult(createListResult(['Group A', 'Group B'], 12));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A'], 12));
      service.queueQueryGroupResult('Group A', olderGroup.promise);
      service.queueQueryGroupResult('Group B', createQueryResult('Group B', 'Node B', ['Node B'], 14));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      const stalePromise = viewModel.openGroup(0);
      await viewModel.openGroup(1);
      olderGroup.resolve(createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 13));
      await stalePromise;

      const state = viewModel.current();
      expect(state.groups[1].active).assertTrue();
      expect(state.nodes[0].name).assertEqual('Node B');
      expect(state.groupGeneration).assertEqual(14);
    });

    it('invokesOneClickForTerminalRowsNavigatesNestedRowsAndSkipsTheCurrentRunningNode', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredResult = new DeferredResult<SelectNodeAndEnsureVpnResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 21));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B', 'Nested Group'], 21, [2]));
      service.queueQueryGroupResult('Nested Group', createQueryResult('Nested Group', 'Nested Node', ['Nested Node'], 22));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B', 'Nested Group'], 23, [2]));
      service.queueSelectResult(createRejectedSelectionResult('PROXY_SELECTION_FAILED', true));
      service.queueSelectNodeAndEnsureVpnResult(deferredResult.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      await viewModel.activateNode(2);
      expect(service.oneClickCalls.length).assertEqual(0);
      expect(service.queryCalls[1].groupName).assertEqual('Nested Group');

      await viewModel.openGroup(0);
      await viewModel.activateNode(0);
      expect(service.oneClickCalls.length).assertEqual(0);

      const firstTap = viewModel.activateNode(1);
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('SAVING_SELECTION', true, 'NONE'));
      const secondTap = viewModel.activateNode(1);
      expect(service.oneClickCalls.length).assertEqual(1);
      expect(service.oneClickCalls[0].groupName).assertEqual('Group A');
      expect(service.oneClickCalls[0].memberName).assertEqual('Node B');
      expect(service.oneClickCalls[0].snapshotGeneration).assertEqual(23);
      expect(viewModel.current().selectionPending).assertTrue();
      expect(viewModel.current().activationStage).assertEqual('SAVING_SELECTION');

      deferredResult.resolve(createOneClickVpnFailureResult(
        'SELECTION',
        'PROXY_SELECTION_FAILED',
        true,
        'proxies_error_selection_failed',
        false
      ));
      await firstTap;
      await secondTap;
    });

    it('blocksInstantSecondTapBeforeTheFirstProgressEventWithoutNeedingApplicationBusyPublication', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredResult = new DeferredResult<SelectNodeAndEnsureVpnResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 211));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 211));
      service.queueSelectNodeAndEnsureVpnResult(deferredResult.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      const firstTap = viewModel.activateNode(1);
      const secondTap = viewModel.activateNode(1);

      expect(service.oneClickCalls.length).assertEqual(1);

      deferredResult.resolve(createOneClickVpnFailureResult(
        'SELECTION',
        'PROXY_SELECTION_FAILED',
        true,
        'proxies_error_selection_failed',
        false
      ));
      await firstTap;
      await secondTap;
    });

    it('constructsSafelyAcrossSynchronousProgressReplayAndCurrentCatchUpWindow', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      service.queueCurrentOneClickSnapshot(createOneClickVpnOperationSnapshot('IDLE', false, 'NONE'));
      service.subscribeSynchronousSnapshot = createOneClickVpnOperationSnapshot('SAVING_SELECTION', true, 'NONE');
      service.queueCurrentOneClickSnapshot(createOneClickVpnOperationSnapshot('CONFIRMING_SELECTION', true, 'NONE'));
      service.queueListGroupsResult(createListResult(['Group A'], 212, null));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 212, [], null));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node B', ['Node A', 'Node B'], 213, [], 'sync-session'));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      expect(viewModel.current().status).assertEqual('READY');
      expect(viewModel.current().selectionPending).assertFalse();
      expect(viewModel.current().activationStage).assertEqual('IDLE');

      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      await flushPromises();

      expect(service.queryCalls.length).assertEqual(2);
      expect(viewModel.current().nodes[1].runtimeSelected).assertTrue();
    });

    it('allowsInitialLoadButBlocksMutationsWhenConstructedDuringAnExternalBusyOperation', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      service.queueCurrentOneClickSnapshot(createOneClickVpnOperationSnapshot('STARTING_VPN', true, 'NONE'));
      service.queueCurrentOneClickSnapshot(createOneClickVpnOperationSnapshot('STARTING_VPN', true, 'NONE'));
      service.queueListGroupsResult(createListResult(['Group A'], 214, null));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 214, [], null));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node B', ['Node A', 'Node B'], 215, [], 'busy-session'));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      await viewModel.openGroup(0);
      await viewModel.retry();
      await viewModel.toggleDelayTest();
      await viewModel.activateNode(1);

      expect(service.listGroupsCalls).assertEqual(1);
      expect(service.queryCalls.length).assertEqual(1);
      expect(service.startDelayCalls.length).assertEqual(0);
      expect(service.oneClickCalls.length).assertEqual(0);
      expect(viewModel.current().selectionPending).assertFalse();
      expect(viewModel.current().activationStage).assertEqual('IDLE');

      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      await flushPromises();

      expect(service.queryCalls.length).assertEqual(2);
      expect(viewModel.current().nodes[1].runtimeSelected).assertTrue();
    });

    it('treatsTheCurrentRunningNodeAsANoOpEvenWhenItAlsoCarriesASavedMarker', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      service.queueListGroupsResult(createListResult(['Group A'], 216, 'running-session'));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 216, [], 'running-session'));
      service.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('ALREADY_ACTIVE'));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      const internalState = Reflect.get(viewModel, 'state') as ProxyViewState;
      internalState.nodes[0].savedForNextStart = true;

      await viewModel.activateNode(0);

      expect(service.oneClickCalls.length).assertEqual(0);
    });

    it('doesNotWrapApplicationOwnedOneClickCallsInThePresentationDeadlineAndIgnoresLateCompletionAfterDispose', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredResult = new DeferredResult<SelectNodeAndEnsureVpnResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 217, null));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 217, [], null));
      service.queueSelectNodeAndEnsureVpnResult(deferredResult.promise);
      const deadline = new LimitedDeadlinePort(2);
      const viewModel = new ProxyViewModel(service, deadline);
      const states: ProxyViewState[] = [];
      viewModel.subscribe((state: ProxyViewState): void => {
        states.push(state);
      });

      await viewModel.load();
      const operationPromise = viewModel.activateNode(1);
      const publishedBeforeDispose = states.length;
      const disposeFirst = viewModel.dispose();
      const disposeSecond = viewModel.dispose();

      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('SAVING_SELECTION', true, 'NONE'));
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      deferredResult.resolve(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      await operationPromise;
      await disposeFirst;
      await disposeSecond;

      expect(service.oneClickUnsubscribeCalls).assertEqual(1);
      expect(states.length).assertEqual(publishedBeforeDispose);
      expect(service.oneClickCalls.length).assertEqual(1);
    });

    it('retriesAfterSavedStartFailureAndEventuallyPublishesSuccessOnTheSecondTap', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      service.queueListGroupsResult(createListResult(['Group A'], 218, null));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 218, [], null));
      service.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('SAVED_VPN_START_FAILED'));
      service.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node B', ['Node A', 'Node B'], 219, [], 'retry-session'));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'FAILED'));
      await viewModel.activateNode(1);
      expect(viewModel.current().warning).assertEqual('SAVED_FOR_NEXT_START');
      expect(service.oneClickCalls.length).assertEqual(1);

      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      await viewModel.activateNode(1);

      expect(service.oneClickCalls.length).assertEqual(2);
      expect(viewModel.current().warning).assertEqual('NONE');
      expect(viewModel.current().nodes[1].runtimeSelected).assertTrue();
    });

    it('mapsAlreadyActiveAndAppliedToRunningVpnWithoutLeakingUnsafeDetails', 0, async () => {
      const alreadyService = new RecordingProxyApplicationPort();
      alreadyService.queueListGroupsResult(createListResult(['Group A'], 220, 'already-session'));
      alreadyService.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 220, [], 'already-session'));
      alreadyService.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('ALREADY_ACTIVE'));
      const alreadyViewModel = new ProxyViewModel(alreadyService, new ImmediateDeadlinePort());

      await alreadyViewModel.load();
      await alreadyViewModel.activateNode(0);
      expect(alreadyService.oneClickCalls.length).assertEqual(0);

      const runningService = new RecordingProxyApplicationPort();
      runningService.queueListGroupsResult(createListResult(['Group A'], 221, 'running-switch'));
      runningService.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 221, [], 'running-switch'));
      runningService.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('APPLIED_TO_RUNNING_VPN'));
      runningService.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node B', ['Node A', 'Node B'], 222, [], 'running-switch'));
      const runningViewModel = new ProxyViewModel(runningService, new ImmediateDeadlinePort());

      await runningViewModel.load();
      runningService.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      await runningViewModel.activateNode(1);

      expect(runningService.oneClickCalls.length).assertEqual(1);
      expect(runningViewModel.current().nodes[1].runtimeSelected).assertTrue();
    });

    it('keepsRowsWhenTheSameGroupRefreshFailsAfterSuccessAndMapsRejectedOrThrownRefreshSafely', 0, async () => {
      const rejectedService = new RecordingProxyApplicationPort();
      rejectedService.queueListGroupsResult(createListResult(['Group A'], 223, null));
      rejectedService.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 223, [], null));
      rejectedService.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      rejectedService.queueQueryGroupResult('Group A', createRejectedGroupResult('VPN_SESSION_CHANGED', true));
      const rejectedViewModel = new ProxyViewModel(rejectedService, new ImmediateDeadlinePort());

      await rejectedViewModel.load();
      await rejectedViewModel.activateNode(1);

      expect(rejectedViewModel.current().nodes[0].runtimeSelected).assertTrue();
      expect(rejectedViewModel.current().nodes[1].runtimeSelected).assertFalse();
      expect(rejectedViewModel.current().activationStage).assertEqual('FAILED');
      expect(rejectedViewModel.current().activationErrorResourceId).assertEqual('proxies_error_session_changed');

      const thrownService = new RecordingProxyApplicationPort();
      thrownService.queueListGroupsResult(createListResult(['Group A'], 224, null));
      thrownService.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 224, [], null));
      thrownService.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      thrownService.queueQueryGroupResult('Group A', Promise.reject(new Error('refresh exploded')));
      const thrownViewModel = new ProxyViewModel(thrownService, new ImmediateDeadlinePort());

      await thrownViewModel.load();
      await thrownViewModel.activateNode(1);

      expect(thrownViewModel.current().nodes[0].runtimeSelected).assertTrue();
      expect(thrownViewModel.current().nodes[1].runtimeSelected).assertFalse();
      expect(thrownViewModel.current().activationStage).assertEqual('FAILED');
      expect(thrownViewModel.current().activationErrorResourceId).assertEqual('proxies_error_selection_failed');
      expect(thrownViewModel.current().activationErrorRetryable).assertTrue();
    });

    it('blocksReloadGroupChangesAndDelayActionsWhileOneClickActivationIsLive', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      service.queueListGroupsResult(createListResult(['Group A', 'Group B'], 22));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 22));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 22, 'delay-job-live', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'WAITING'),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('STARTING_VPN', true, 'NONE'));

      await viewModel.load();
      await viewModel.retry();
      await viewModel.openGroup(1);
      await viewModel.toggleDelayTest();
      await viewModel.activateNode(1);

      expect(service.listGroupsCalls).assertEqual(1);
      expect(service.queryCalls.length).assertEqual(1);
      expect(service.startDelayCalls.length).assertEqual(0);
      expect(service.oneClickCalls.length).assertEqual(0);
    });

    it('mapsApplicationProgressStagesAndRefreshesTheSameDisplayedGroupOnSuccess', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      service.queueListGroupsResult(createListResult(['Group A'], 30, null));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 30, [], null));
      service.queueSelectResult(createRejectedSelectionResult('PROXY_SELECTION_FAILED', true));
      service.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node B', ['Node A', 'Node B'], 31, [], 'vpn-session-1'));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      const activationPromise = viewModel.activateNode(1);
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('SAVING_SELECTION', true, 'NONE'));
      expect(viewModel.current().activationStage).assertEqual('SAVING_SELECTION');
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('STARTING_VPN', true, 'NONE'));
      expect(viewModel.current().activationStage).assertEqual('STARTING_VPN');
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('CONFIRMING_SELECTION', true, 'NONE'));
      expect(viewModel.current().activationStage).assertEqual('CONFIRMING_SELECTION');
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      await activationPromise;

      const state = viewModel.current();
      expect(service.queryCalls.length).assertEqual(2);
      expect(service.queryCalls[1].groupName).assertEqual('Group A');
      expect(state.groupGeneration).assertEqual(31);
      expect(state.warning).assertEqual('NONE');
      expect(state.selectionPending).assertFalse();
      expect(state.activationStage).assertEqual('IDLE');
      expect(state.nodes[0].runtimeSelected).assertFalse();
      expect(state.nodes[1].runtimeSelected).assertTrue();
    });

    it('keepsAppliedNotPersistedWarningsAndSavedStartFailuresInTheActivationChannel', 0, async () => {
      const appliedService = new RecordingProxyApplicationPort();
      appliedService.queueListGroupsResult(createListResult(['Group A'], 40));
      appliedService.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 40));
      appliedService.queueSelectResult(createRejectedSelectionResult('PROXY_SELECTION_FAILED', true));
      appliedService.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('APPLIED_TO_RUNNING_VPN_NOT_PERSISTED'));
      appliedService.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node B', ['Node A', 'Node B'], 41));
      const appliedViewModel = new ProxyViewModel(appliedService, new ImmediateDeadlinePort());

      await appliedViewModel.load();
      appliedService.publishOneClickOperation(createOneClickVpnOperationSnapshot('SWITCHING_VPN', true, 'NONE'));
      appliedService.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      await appliedViewModel.activateNode(1);

      expect(appliedViewModel.current().warning).assertEqual('APPLIED_NOT_PERSISTED');
      expect(appliedViewModel.current().nodes[1].runtimeSelected).assertTrue();

      const savedStartService = new RecordingProxyApplicationPort();
      savedStartService.queueListGroupsResult(createListResult(['Group A'], 42, null));
      savedStartService.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 42, [], null));
      savedStartService.queueSelectResult(createRejectedSelectionResult('PROXY_SELECTION_FAILED', true));
      savedStartService.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('SAVED_VPN_START_FAILED'));
      const savedStartViewModel = new ProxyViewModel(savedStartService, new ImmediateDeadlinePort());

      await savedStartViewModel.load();
      savedStartService.publishOneClickOperation(createOneClickVpnOperationSnapshot('STARTING_VPN', true, 'NONE'));
      savedStartService.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'FAILED'));
      await savedStartViewModel.activateNode(1);

      expect(savedStartViewModel.current().warning).assertEqual('SAVED_FOR_NEXT_START');
      expect(savedStartViewModel.current().nodes[1].savedForNextStart).assertTrue();
      expect(savedStartViewModel.current().activationStage).assertEqual('FAILED');
      expect(savedStartViewModel.current().activationErrorResourceId).assertEqual('error_vpn_start_failed');
      expect(savedStartViewModel.current().activationErrorRetryable).assertTrue();
      expect(savedStartViewModel.current().errorCode).assertEqual(undefined);
    });

    it('mapsEveryOneClickFailureToTheActivationErrorChannelWithoutLeakingIntoQueryErrors', 0, async () => {
      const cases: OneClickFailureCase[] = [
        createOneClickFailureCase('ADMISSION', 'OPERATION_BUSY', true, 'proxies_one_click_busy', false),
        createOneClickFailureCase('SELECTION', 'PROXY_SELECTION_STALE', true, 'proxies_error_selection_stale', false),
        createOneClickFailureCase('SELECTION', 'PROXY_SELECTION_FAILED', true, 'proxies_error_selection_failed', false),
        createOneClickFailureCase('SELECTION', 'PROXY_PERSISTENCE_FAILED', true, 'proxies_error_persistence_failed', false),
        createOneClickFailureCase('VPN_START', 'VPN_PROFILE_UNAVAILABLE', false, 'error_vpn_profile_unavailable', true),
        createOneClickFailureCase('VPN_START', 'VPN_PERMISSION_DENIED', true, 'error_vpn_permission_denied', true),
        createOneClickFailureCase('VPN_START', 'VPN_START_FAILED', true, 'error_vpn_start_failed', true),
        createOneClickFailureCase('VPN_START', 'VPN_STOPPED_BEFORE_RUNNING', true, 'error_vpn_start_failed', true),
        createOneClickFailureCase('VPN_CONFIRMATION', 'VPN_CONFIRMATION_TIMEOUT', true, 'proxies_one_click_confirmation_timeout', true),
        createOneClickFailureCase('VPN_CONFIRMATION', 'VPN_SESSION_CHANGED', true, 'proxies_error_session_changed', true)
      ];

      for (let index: number = 0; index < cases.length; index += 1) {
        const service = new RecordingProxyApplicationPort();
        service.queueListGroupsResult(createListResult(['Group A'], 55 + index, cases[index].savedForNextStart ? null : 'session-a'));
        service.queueQueryGroupResult(
          'Group A',
          createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 55 + index, [], cases[index].savedForNextStart ? null : 'session-a')
        );
        service.queueSelectResult(createRejectedSelectionResult('PROXY_SELECTION_FAILED', true));
        service.queueSelectNodeAndEnsureVpnResult(createOneClickVpnFailureResult(
          cases[index].stage,
          cases[index].code,
          cases[index].retryable,
          cases[index].resourceId,
          cases[index].savedForNextStart
        ));
        const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

        await viewModel.load();
        service.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'FAILED'));
        await viewModel.activateNode(1);

        expect(viewModel.current().activationStage).assertEqual('FAILED');
        expect(viewModel.current().activationErrorResourceId).assertEqual(cases[index].resourceId);
        expect(viewModel.current().activationErrorRetryable).assertEqual(cases[index].retryable);
        expect(viewModel.current().errorCode).assertEqual(undefined);
      }
    });

    it('startsDelayTestsWithExactDisplayedGenerationClearsPreviousValuesAndPollsWithoutOverlap', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      const secondStart = new DeferredResult<ProxyDelayResult>();
      const firstRead = new DeferredResult<ProxyDelayResult>();
      const secondRead = new DeferredResult<ProxyDelayResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 90));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 90));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 90, 'delay-job-0', 'COMPLETED', [
        createDelayNodeResultValue(0, 'Node A', 'AVAILABLE', 'Direct', 61, true),
        createDelayNodeResultValue(1, 'Node B', 'TIMEOUT')
      ]));
      service.queueStartDelayResult(secondStart.promise);
      service.queueReadDelayResult(firstRead.promise);
      service.queueReadDelayResult(secondRead.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);

      await viewModel.load();
      await viewModel.toggleDelayTest();
      const restartPromise = viewModel.toggleDelayTest();

      expect(viewModel.current().delayState).assertEqual('STARTING');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('NONE');
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('NONE');
      expect(service.startDelayCalls.length).assertEqual(2);
      expect(service.startDelayCalls[1].groupName).assertEqual('Group A');
      expect(service.startDelayCalls[1].snapshotGeneration).assertEqual(90);

      secondStart.resolve(createDelaySnapshotResultValue('Group A', 90, 'delay-job-1', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'TESTING'),
        createDelayNodeResultValue(1, 'Node B', 'WAITING')
      ]));
      await restartPromise;

      expect(viewModel.current().delayState).assertEqual('RUNNING');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('TESTING');
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('WAITING');
      expect(scheduler.pendingCount()).assertEqual(1);
      expect(scheduler.latest()!.delayMs).assertEqual(250);
      expect(service.readDelayCalls.length).assertEqual(0);

      scheduler.latest()!.run();
      expect(service.readDelayCalls.length).assertEqual(1);
      expect(scheduler.pendingCount()).assertEqual(0);

      firstRead.resolve(createDelaySnapshotResultValue('Group A', 90, 'delay-job-1', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'AVAILABLE', 'Direct', 45, true),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      await flushPromises();

      expect(viewModel.current().delayState).assertEqual('RUNNING');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('AVAILABLE');
      expect(viewModel.current().nodes[0].delayMs).assertEqual(45);
      expect(viewModel.current().nodes[0].delayFastest).assertTrue();
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('TESTING');
      expect(viewModel.current().availableDelayCount).assertEqual(1);
      expect(viewModel.current().fastestDelayNodeIndex).assertEqual(0);
      expect(scheduler.pendingCount()).assertEqual(1);
      expect(service.readDelayCalls.length).assertEqual(1);

      scheduler.latest()!.run();
      expect(service.readDelayCalls.length).assertEqual(2);

      secondRead.resolve(createDelaySnapshotResultValue('Group A', 90, 'delay-job-1', 'COMPLETED', [
        createDelayNodeResultValue(0, 'Node A', 'AVAILABLE', 'Direct', 45, true),
        createDelayNodeResultValue(1, 'Node B', 'TIMEOUT')
      ]));
      await flushPromises();

      expect(viewModel.current().delayState).assertEqual('COMPLETED');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('AVAILABLE');
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('TIMEOUT');
      expect(viewModel.current().completedDelayCount).assertEqual(2);
      expect(viewModel.current().timeoutDelayCount).assertEqual(1);
      expect(scheduler.pendingCount()).assertEqual(0);
      expect(scheduler.tasks.length).assertEqual(2);
    });

    it('cancelsImmediatelyWhenTheSecondToggleArrivesBeforeStartResolves', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      const start = new DeferredResult<ProxyDelayResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 91));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 91));
      service.queueStartDelayResult(start.promise);
      service.queueCancelDelayResult(createDelaySnapshotResultValue('Group A', 91, 'delay-job-2', 'CANCELLED', [
        createDelayNodeResultValue(0, 'Node A', 'AVAILABLE', 'Direct', 88, true),
        createDelayNodeResultValue(1, 'Node B', 'WAITING')
      ]));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);

      await viewModel.load();
      const startPromise = viewModel.toggleDelayTest();
      const cancelPromise = viewModel.toggleDelayTest();

      expect(viewModel.current().delayState).assertEqual('STARTING');
      start.resolve(createDelaySnapshotResultValue('Group A', 91, 'delay-job-2', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'WAITING'),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));

      await startPromise;
      await cancelPromise;

      expect(service.cancelDelayCalls.length).assertEqual(1);
      expect(service.cancelDelayCalls[0].jobId).assertEqual('delay-job-2');
      expect(viewModel.current().delayState).assertEqual('CANCELLED');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('AVAILABLE');
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('CANCELLED');
      expect(viewModel.current().cancelledDelayCount).assertEqual(1);
      expect(scheduler.pendingCount()).assertEqual(0);
    });

    it('cancelsRunningDelayTestsDirectlyAndPreservesCompletedRows', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      service.queueListGroupsResult(createListResult(['Group A'], 92));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 92));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 92, 'delay-job-3', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'WAITING'),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      service.queueCancelDelayResult(createDelaySnapshotResultValue('Group A', 92, 'delay-job-3', 'CANCELLED', [
        createDelayNodeResultValue(0, 'Node A', 'FAILED'),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);

      await viewModel.load();
      await viewModel.toggleDelayTest();
      await viewModel.toggleDelayTest();

      expect(service.cancelDelayCalls.length).assertEqual(1);
      expect(service.cancelDelayCalls[0].jobId).assertEqual('delay-job-3');
      expect(service.readDelayCalls.length).assertEqual(0);
      expect(service.selectCalls.length).assertEqual(0);
      expect(viewModel.current().delayState).assertEqual('CANCELLED');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('FAILED');
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('CANCELLED');
      expect(viewModel.current().failedDelayCount).assertEqual(1);
      expect(viewModel.current().cancelledDelayCount).assertEqual(1);
    });

    it('ignoresInflightPollResultsAfterCancelBeginsAndOnlyAcceptsTheCancelTerminalSnapshot', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      const deferredRead = new DeferredResult<ProxyDelayResult>();
      const deferredCancel = new DeferredResult<ProxyDelayResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 92));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 92));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 92, 'delay-job-race', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'WAITING'),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      service.queueReadDelayResult(deferredRead.promise);
      service.queueCancelDelayResult(deferredCancel.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);

      await viewModel.load();
      await viewModel.toggleDelayTest();
      scheduler.latest()!.run();
      expect(service.readDelayCalls.length).assertEqual(1);

      const cancelPromise = viewModel.toggleDelayTest();
      expect(service.cancelDelayCalls.length).assertEqual(1);
      deferredRead.resolve(createDelaySnapshotResultValue('Group A', 92, 'delay-job-race', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'AVAILABLE', 'Direct', 31, true),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      await flushPromises();

      expect(viewModel.current().delayState).assertEqual('RUNNING');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('WAITING');
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('TESTING');
      expect(scheduler.pendingCount()).assertEqual(0);

      deferredCancel.resolve(createDelaySnapshotResultValue('Group A', 92, 'delay-job-race', 'CANCELLED', [
        createDelayNodeResultValue(0, 'Node A', 'AVAILABLE', 'Direct', 31, true),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      await cancelPromise;

      expect(viewModel.current().delayState).assertEqual('CANCELLED');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('AVAILABLE');
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('CANCELLED');
      expect(viewModel.current().availableDelayCount).assertEqual(1);
      expect(viewModel.current().cancelledDelayCount).assertEqual(1);
      expect(scheduler.pendingCount()).assertEqual(0);
    });

    it('publishesTypedInlineErrorsForFailedOrMalformedDelaySnapshots', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      const deferredMalformedRead = new DeferredResult<ProxyDelayResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 93));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 93));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 93, 'delay-job-4', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'WAITING'),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      service.queueReadDelayResult(createDelaySnapshotResultValue('Group A', 93, 'delay-job-4', 'FAILED', [
        createDelayNodeResultValue(0, 'Node A', 'FAILED'),
        createDelayNodeResultValue(1, 'Node B', 'FAILED')
      ]));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 93, 'delay-job-5', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'WAITING'),
        createDelayNodeResultValue(1, 'Node B', 'WAITING')
      ]));
      service.queueReadDelayResult(deferredMalformedRead.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);

      await viewModel.load();
      await viewModel.toggleDelayTest();
      scheduler.latest()!.run();
      await flushPromises();

      expect(viewModel.current().status).assertEqual('READY');
      expect(viewModel.current().delayState).assertEqual('FAILED');
      expect(viewModel.current().errorCode).assertEqual('PROXY_DELAY_TEST_FAILED');
      expect(viewModel.current().errorRetryable).assertTrue();
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('FAILED');
      expect(scheduler.pendingCount()).assertEqual(0);

      await viewModel.toggleDelayTest();
      scheduler.latest()!.run();
      deferredMalformedRead.resolve(createDelaySnapshotResultValue('Group A', 93, 'delay-job-5', 'RUNNING', [
        createDelayNodeResultValue(0, 'Wrong Node', 'WAITING'),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      await flushPromises();

      expect(viewModel.current().status).assertEqual('READY');
      expect(viewModel.current().delayState).assertEqual('FAILED');
      expect(viewModel.current().errorCode).assertEqual('PROXY_DELAY_TEST_FAILED');
      expect(viewModel.current().errorRetryable).assertTrue();
      expect(viewModel.current().nodes[0].name).assertEqual('Node A');
      expect(scheduler.pendingCount()).assertEqual(0);
    });

    it('mapsRunningReadFailuresToATerminalFailedDelayStateAndAllowsRestart', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      service.queueListGroupsResult(createListResult(['Group A'], 93));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 93));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 93, 'delay-job-read-fail', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'AVAILABLE', 'Direct', 41, true),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      service.queueReadDelayResult(Promise.reject(new Error('read failed')));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 93, 'delay-job-read-restart', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'WAITING'),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);

      await viewModel.load();
      await viewModel.toggleDelayTest();
      scheduler.latest()!.run();
      await flushPromises();

      expect(viewModel.current().delayState).assertEqual('FAILED');
      expect(viewModel.current().errorCode).assertEqual('PROXY_DELAY_TEST_FAILED');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('AVAILABLE');
      expect(viewModel.current().nodes[0].delayMs).assertEqual(41);
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('FAILED');
      expect(viewModel.current().availableDelayCount).assertEqual(1);
      expect(viewModel.current().failedDelayCount).assertEqual(1);
      expect(viewModel.current().completedDelayCount).assertEqual(2);
      expect(scheduler.pendingCount()).assertEqual(0);

      await viewModel.toggleDelayTest();

      expect(service.startDelayCalls.length).assertEqual(2);
      expect(viewModel.current().delayState).assertEqual('RUNNING');
    });

    it('mapsMalformedCancelSnapshotsToATerminalFailedDelayStateAndAllowsRestart', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      service.queueListGroupsResult(createListResult(['Group A'], 94));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 94));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 94, 'delay-job-cancel-fail', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'AVAILABLE', 'Direct', 37, true),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      service.queueCancelDelayResult(createDelaySnapshotResultValue('Group A', 94, 'delay-job-cancel-fail', 'CANCELLED', [
        createDelayNodeResultValue(0, 'Wrong Node', 'AVAILABLE', 'Direct', 37, true),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 94, 'delay-job-cancel-restart', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'WAITING'),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);

      await viewModel.load();
      await viewModel.toggleDelayTest();
      await viewModel.toggleDelayTest();

      expect(viewModel.current().delayState).assertEqual('FAILED');
      expect(viewModel.current().errorCode).assertEqual('PROXY_DELAY_TEST_FAILED');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('AVAILABLE');
      expect(viewModel.current().nodes[0].delayMs).assertEqual(37);
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('FAILED');
      expect(viewModel.current().availableDelayCount).assertEqual(1);
      expect(viewModel.current().failedDelayCount).assertEqual(1);
      expect(scheduler.pendingCount()).assertEqual(0);

      await viewModel.toggleDelayTest();

      expect(service.startDelayCalls.length).assertEqual(2);
      expect(viewModel.current().delayState).assertEqual('RUNNING');
    });

    it('cancelsAndClearsDelayResultsBeforeNavigationLeaveAndDispose', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      const drainOnDispose = new DeferredResult<ProxyRejectedResult | undefined>();
      service.queueListGroupsResult(createListResult(['Group A', 'Group B'], 94));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Nested Group'], 94, [1]));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 94, 'delay-job-6', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'TESTING'),
        createDelayNodeResultValue(1, 'Nested Group', 'WAITING', 'Selector')
      ]));
      service.queueCancelAndDrainResult(undefined);
      service.queueQueryGroupResult('Group B', createQueryResult('Group B', 'Node C', ['Node C'], 95));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Nested Group'], 94, [1]));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 94, 'delay-job-6b', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'TESTING'),
        createDelayNodeResultValue(1, 'Nested Group', 'WAITING', 'Selector')
      ]));
      service.queueCancelAndDrainResult(undefined);
      service.queueQueryGroupResult('Nested Group', createQueryResult('Nested Group', 'Nested Node', ['Nested Node'], 96));
      service.queueCancelAndDrainResult(undefined);
      service.queueStartDelayResult(createDelaySnapshotResultValue('Nested Group', 96, 'delay-job-7', 'RUNNING', [
        createDelayNodeResultValue(0, 'Nested Node', 'TESTING')
      ]));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Nested Group', 96, 'delay-job-7b', 'RUNNING', [
        createDelayNodeResultValue(0, 'Nested Node', 'TESTING')
      ]));
      service.queueCancelAndDrainResult(drainOnDispose.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);
      const states: ProxyViewState[] = [];
      viewModel.subscribe((state: ProxyViewState): void => {
        states.push(state);
      });

      await viewModel.load();
      await viewModel.toggleDelayTest();
      await viewModel.openGroup(1);

      expect(service.cancelAndDrainCalls).assertEqual(1);
      expect(viewModel.current().groups[1].active).assertTrue();
      expect(viewModel.current().delayState).assertEqual('IDLE');

      await viewModel.openGroup(0);
      await viewModel.toggleDelayTest();
      await viewModel.activateNode(1);

      expect(service.cancelAndDrainCalls).assertEqual(2);
      expect(viewModel.current().nodes[0].name).assertEqual('Nested Node');
      expect(viewModel.current().delayState).assertEqual('IDLE');

      await viewModel.toggleDelayTest();
      const leavePromise = viewModel.leave();
      await leavePromise;

      expect(service.cancelAndDrainCalls).assertEqual(3);
      expect(viewModel.current().delayState).assertEqual('IDLE');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('NONE');

      await viewModel.toggleDelayTest();
      const disposePromise = viewModel.dispose();
      expect(service.cancelAndDrainCalls).assertEqual(4);
      drainOnDispose.resolve(undefined);
      await disposePromise;

      expect(states.length >= 1).assertTrue();
      expect(scheduler.pendingCount()).assertEqual(0);
    });

    it('leaveInvalidatesInflightGroupQueriesSoTheyCannotRepopulateThePage', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredGroup = new DeferredResult<ProxyGroupQueryResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 110));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A'], 110));
      service.queueQueryGroupResult('Group A', deferredGroup.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());
      const states: ProxyViewState[] = [];
      viewModel.subscribe((state: ProxyViewState): void => {
        states.push(state);
      });

      await viewModel.load();
      const openPromise = viewModel.openGroup(0);
      const publishedBeforeLeave: number = states.length;

      await viewModel.leave();
      deferredGroup.resolve(createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 111));
      await openPromise;

      expect(states.length).assertEqual(publishedBeforeLeave);
      expect(viewModel.current().status).assertEqual('LOADING');
      expect(viewModel.current().nodes.length).assertEqual(0);
    });

    it('leaveInvalidatesInflightSelectionResultsSoTheyCannotPublishAfterBackNavigation', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredSelection = new DeferredResult<SelectNodeAndEnsureVpnResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 111));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 111));
      service.queueSelectResult(createRejectedSelectionResult('PROXY_SELECTION_FAILED', true));
      service.queueSelectNodeAndEnsureVpnResult(deferredSelection.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());
      const states: ProxyViewState[] = [];
      viewModel.subscribe((state: ProxyViewState): void => {
        states.push(state);
      });

      await viewModel.load();
      const selectionPromise = viewModel.activateNode(1);
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('SAVING_SELECTION', true, 'NONE'));
      const publishedBeforeLeave: number = states.length;

      await viewModel.leave();
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      deferredSelection.resolve(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      await selectionPromise;

      expect(states.length).assertEqual(publishedBeforeLeave + 1);
      expect(viewModel.current().selectionPending).assertFalse();
      expect(viewModel.current().groupGeneration).assertEqual(111);
      expect(viewModel.current().nodes[0].runtimeSelected).assertTrue();
      expect(viewModel.current().nodes[1].runtimeSelected).assertFalse();
      expect(viewModel.current().delayState).assertEqual('IDLE');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('NONE');
    });

    it('leaveStopsLiveOneClickProgressPublicationsWithoutCancellingTheApplicationOperation', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredSelection = new DeferredResult<SelectNodeAndEnsureVpnResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 112));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 112, [], null));
      service.queueSelectNodeAndEnsureVpnResult(deferredSelection.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());
      const states: ProxyViewState[] = [];
      viewModel.subscribe((state: ProxyViewState): void => {
        states.push(state);
      });

      await viewModel.load();
      const operationPromise = viewModel.activateNode(1);
      const publicationsBeforeLeave = states.length;

      await viewModel.leave();
      const stateAfterLeave: ProxyViewState = viewModel.current();
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('SAVING_SELECTION', true, 'NONE'));
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('STARTING_VPN', true, 'NONE'));
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('CONFIRMING_SELECTION', true, 'NONE'));

      expect(states.length).assertEqual(publicationsBeforeLeave);
      expect(viewModel.current().activationStage).assertEqual('IDLE');
      expect(viewModel.current().selectionPending).assertFalse();
      expect(viewModel.current().groupGeneration).assertEqual(stateAfterLeave.groupGeneration);

      deferredSelection.resolve(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      await operationPromise;
      expect(service.oneClickCalls.length).assertEqual(1);
      expect(service.cancelAndDrainCalls).assertEqual(0);
    });

    it('leaveInvalidatesInflightOneClickSuccessRefreshSoTheOldSnapshotCannotRepopulateThePage', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredRefresh = new DeferredResult<ProxyGroupQueryResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 121));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 121));
      service.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      service.queueQueryGroupResult('Group A', deferredRefresh.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());
      const states: ProxyViewState[] = [];
      viewModel.subscribe((state: ProxyViewState): void => {
        states.push(state);
      });

      await viewModel.load();
      const activationPromise = viewModel.activateNode(1);
      await flushPromises();

      await viewModel.leave();
      const publicationsAfterLeave: number = states.length;
      deferredRefresh.resolve(createQueryResult('Group A', 'Node B', ['Node A', 'Node B'], 122, [], 'stale-refresh-session'));
      await activationPromise;

      expect(states.length).assertEqual(publicationsAfterLeave);
      expect(viewModel.current().selectionPending).assertFalse();
      expect(viewModel.current().activationStage).assertEqual('IDLE');
      expect(viewModel.current().groupGeneration).assertEqual(121);
      expect(viewModel.current().nodes[0].runtimeSelected).assertTrue();
      expect(viewModel.current().nodes[1].runtimeSelected).assertFalse();
    });

    it('openGroupKeepsTheNewContextWhenAnOldOneClickSuccessRefreshResolvesLater', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredRefresh = new DeferredResult<ProxyGroupQueryResult>();
      service.queueListGroupsResult(createListResult(['Group A', 'Group B'], 122));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 122));
      service.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      service.queueQueryGroupResult('Group A', deferredRefresh.promise);
      service.queueQueryGroupResult('Group B', createQueryResult('Group B', 'Node C', ['Node C'], 123));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      const activationPromise = viewModel.activateNode(1);
      await flushPromises();

      await viewModel.openGroup(1);
      deferredRefresh.resolve(createQueryResult('Group A', 'Node B', ['Node A', 'Node B'], 124, [], 'stale-refresh-session'));
      await activationPromise;

      expect(viewModel.current().groups[1].active).assertTrue();
      expect(viewModel.current().nodes.length).assertEqual(1);
      expect(viewModel.current().nodes[0].name).assertEqual('Node C');
      expect(viewModel.current().groupGeneration).assertEqual(123);
    });

    it('staleOneClickSuccessRefreshRejectionCannotPublishActivationFailureIntoANewContext', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredRefresh = new DeferredResult<ProxyGroupQueryResult>();
      service.queueListGroupsResult(createListResult(['Group A', 'Group B'], 123));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 123));
      service.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      service.queueQueryGroupResult('Group A', deferredRefresh.promise);
      service.queueQueryGroupResult('Group B', createQueryResult('Group B', 'Node C', ['Node C'], 124));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      const activationPromise = viewModel.activateNode(1);
      await flushPromises();

      await viewModel.openGroup(1);
      deferredRefresh.resolve(createRejectedGroupResult('VPN_SESSION_CHANGED', true));
      await activationPromise;

      expect(viewModel.current().groups[1].active).assertTrue();
      expect(viewModel.current().activationStage).assertEqual('IDLE');
      expect(viewModel.current().activationErrorResourceId).assertUndefined();
      expect(viewModel.current().nodes[0].name).assertEqual('Node C');
    });

    it('staleOneClickSuccessRefreshThrowCannotPublishActivationFailureAfterLeave', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredRefresh = new DeferredFailureResult<ProxyGroupQueryResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 124));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 124));
      service.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      service.queueQueryGroupResult('Group A', deferredRefresh.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());
      const states: ProxyViewState[] = [];
      viewModel.subscribe((state: ProxyViewState): void => {
        states.push(state);
      });

      await viewModel.load();
      const activationPromise = viewModel.activateNode(1);
      await flushPromises();

      await viewModel.leave();
      const publicationsAfterLeave: number = states.length;
      deferredRefresh.reject(new Error('refresh exploded'));
      await activationPromise;

      expect(states.length).assertEqual(publicationsAfterLeave);
      expect(viewModel.current().activationStage).assertEqual('IDLE');
      expect(viewModel.current().activationErrorResourceId).assertUndefined();
      expect(viewModel.current().groupGeneration).assertEqual(124);
    });

    it('staleExternalSuccessRefreshCannotPolluteLeaveOrNewGroupContexts', 0, async () => {
      const successService = new RecordingProxyApplicationPort();
      const deferredSuccessRefresh = new DeferredResult<ProxyGroupQueryResult>();
      successService.queueListGroupsResult(createListResult(['Group A'], 125, null));
      successService.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 125, [], null));
      successService.queueQueryGroupResult('Group A', deferredSuccessRefresh.promise);
      const successViewModel = new ProxyViewModel(successService, new ImmediateDeadlinePort());
      const successStates: ProxyViewState[] = [];
      successViewModel.subscribe((state: ProxyViewState): void => {
        successStates.push(state);
      });

      await successViewModel.load();
      successService.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      await flushPromises();
      await successViewModel.leave();
      const successPublicationsAfterLeave: number = successStates.length;
      deferredSuccessRefresh.resolve(createQueryResult('Group A', 'Node B', ['Node A', 'Node B'], 126, [], 'stale-external-success'));
      await flushPromises();

      expect(successStates.length).assertEqual(successPublicationsAfterLeave);
      expect(successViewModel.current().activationStage).assertEqual('IDLE');
      expect(successViewModel.current().groupGeneration).assertEqual(125);

      const rejectedService = new RecordingProxyApplicationPort();
      const deferredRejectedRefresh = new DeferredResult<ProxyGroupQueryResult>();
      rejectedService.queueListGroupsResult(createListResult(['Group A', 'Group B'], 127, null));
      rejectedService.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A'], 127, [], null));
      rejectedService.queueQueryGroupResult('Group A', deferredRejectedRefresh.promise);
      rejectedService.queueQueryGroupResult('Group B', createQueryResult('Group B', 'Node C', ['Node C'], 128, [], null));
      const rejectedViewModel = new ProxyViewModel(rejectedService, new ImmediateDeadlinePort());

      await rejectedViewModel.load();
      rejectedService.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      await flushPromises();
      await rejectedViewModel.openGroup(1);
      deferredRejectedRefresh.resolve(createRejectedGroupResult('VPN_SESSION_CHANGED', true));
      await flushPromises();

      expect(rejectedViewModel.current().groups[1].active).assertTrue();
      expect(rejectedViewModel.current().activationStage).assertEqual('IDLE');
      expect(rejectedViewModel.current().nodes[0].name).assertEqual('Node C');

      const thrownService = new RecordingProxyApplicationPort();
      const deferredThrownRefresh = new DeferredFailureResult<ProxyGroupQueryResult>();
      thrownService.queueListGroupsResult(createListResult(['Group A', 'Group B'], 129, null));
      thrownService.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A'], 129, [], null));
      thrownService.queueQueryGroupResult('Group A', deferredThrownRefresh.promise);
      thrownService.queueQueryGroupResult('Group B', createQueryResult('Group B', 'Node C', ['Node C'], 130, [], null));
      const thrownViewModel = new ProxyViewModel(thrownService, new ImmediateDeadlinePort());

      await thrownViewModel.load();
      thrownService.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      await flushPromises();
      await thrownViewModel.openGroup(1);
      deferredThrownRefresh.reject(new Error('external refresh exploded'));
      await flushPromises();

      expect(thrownViewModel.current().groups[1].active).assertTrue();
      expect(thrownViewModel.current().activationStage).assertEqual('IDLE');
      expect(thrownViewModel.current().nodes[0].name).assertEqual('Node C');
    });

    it('loadReattachesAfterLeaveWhileTheApplicationOperationIsStillBusyAndRefreshesOnTerminalSuccess', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredSelection = new DeferredResult<SelectNodeAndEnsureVpnResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 113, null));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 113, [], null));
      service.queueSelectNodeAndEnsureVpnResult(deferredSelection.promise);
      service.queueListGroupsResult(createListResult(['Group A'], 114, null));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 114, [], null));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node B', ['Node A', 'Node B'], 115, [], 'reattach-session'));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      const operationPromise = viewModel.activateNode(1);
      await viewModel.leave();
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('STARTING_VPN', true, 'NONE'));

      await viewModel.load();

      expect(service.listGroupsCalls).assertEqual(2);
      expect(viewModel.current().status).assertEqual('READY');
      expect(viewModel.current().activationStage).assertEqual('IDLE');
      expect(viewModel.current().selectionPending).assertFalse();
      expect(viewModel.current().nodes[0].runtimeSelected).assertTrue();
      expect(viewModel.current().nodes[1].runtimeSelected).assertFalse();

      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      await flushPromises();

      expect(service.queryCalls.length).assertEqual(3);
      expect(viewModel.current().nodes[1].runtimeSelected).assertTrue();

      deferredSelection.resolve(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      await operationPromise;
    });

    it('loadSucceedsAfterLeaveBeforeThePreviousSelectionPromiseResolves', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredSelection = new DeferredResult<ProxySelectionResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 113));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 113));
      service.queueSelectResult(deferredSelection.promise);
      service.queueListGroupsResult(createListResult(['Group A'], 114));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 114));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());

      await viewModel.load();
      const selectionPromise = viewModel.activateNode(1);

      await viewModel.leave();
      await viewModel.load();

      expect(service.listGroupsCalls).assertEqual(2);
      expect(viewModel.current().selectionPending).assertFalse();
      expect(viewModel.current().groupGeneration).assertEqual(114);
      expect(viewModel.current().nodes[0].runtimeSelected).assertTrue();

      deferredSelection.resolve(createAppliedNowSelection('Group A', 'Node B', 115));
      await selectionPromise;

      expect(viewModel.current().groupGeneration).assertEqual(114);
      expect(viewModel.current().nodes[0].runtimeSelected).assertTrue();
      expect(viewModel.current().nodes[1].runtimeSelected).assertFalse();
    });

    it('failsClosedWhenDelayDrainFailsAndPreservesTheCurrentPage', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      service.queueListGroupsResult(createListResult(['Group A', 'Group B'], 97));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A'], 97));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 97, 'delay-job-8', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'TESTING')
      ]));
      service.queueCancelAndDrainResult(createProxyRejectedResult(
        createProxyRejectedError('PROXY_DELAY_DRAIN_FAILED', true, '2026-08-11T12:30:00.000Z')
      ));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);

      await viewModel.load();
      await viewModel.toggleDelayTest();
      await viewModel.openGroup(1);

      expect(service.queryCalls.length).assertEqual(1);
      expect(viewModel.current().groups[0].active).assertTrue();
      expect(viewModel.current().nodes[0].name).assertEqual('Node A');
      expect(viewModel.current().errorCode).assertEqual('PROXY_DELAY_DRAIN_FAILED');
      expect(viewModel.current().errorRetryable).assertTrue();
      expect(viewModel.current().delayState).assertEqual('RUNNING');
    });

    it('leaveRejectsWhenDelayDrainFailsAndSucceedsOnRetry', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      service.queueListGroupsResult(createListResult(['Group A'], 118));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 118));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 118, 'delay-job-leave-fail', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'AVAILABLE', 'Direct', 52, true),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      service.queueCancelAndDrainResult(createProxyRejectedResult(
        createProxyRejectedError('PROXY_DELAY_DRAIN_FAILED', true, '2026-08-11T12:30:00.000Z')
      ));
      service.queueCancelAndDrainResult(undefined);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);

      await viewModel.load();
      await viewModel.toggleDelayTest();

      let rejectedMessage: string = '';
      try {
        await viewModel.leave();
      } catch (error) {
        rejectedMessage = (error as Error).message;
      }

      expect(rejectedMessage).assertEqual('Proxy delay lifecycle drain failed.');
      expect(service.cancelAndDrainCalls).assertEqual(1);
      expect(viewModel.current().errorCode).assertEqual('PROXY_DELAY_DRAIN_FAILED');
      expect(viewModel.current().errorRetryable).assertTrue();
      expect(viewModel.current().delayState).assertEqual('RUNNING');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('AVAILABLE');
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('TESTING');

      Reflect.set(viewModel, 'activatingRowIndex', 1);
      Reflect.set(viewModel, 'activatingGroupName', 'Group A');
      Reflect.set(viewModel, 'activatingNodeName', 'Node B');
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('SAVING_SELECTION', true, 'NONE'));
      expect(viewModel.current().activationStage).assertEqual('SAVING_SELECTION');

      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('STARTING_VPN', true, 'NONE'));
      expect(viewModel.current().activationStage).assertEqual('STARTING_VPN');

      await viewModel.leave();

      expect(service.cancelAndDrainCalls).assertEqual(2);
      expect(viewModel.current().delayState).assertEqual('IDLE');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('NONE');
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('NONE');
    });

    it('ignoresLiveSelectionsAndPreservesTerminalDelayRowsAcrossSuccessfulSelection', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      service.queueListGroupsResult(createListResult(['Group A'], 98));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 98));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 98, 'delay-job-9', 'COMPLETED', [
        createDelayNodeResultValue(0, 'Node A', 'AVAILABLE', 'Direct', 72, true),
        createDelayNodeResultValue(1, 'Node B', 'FAILED')
      ]));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 98, 'delay-job-10', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'WAITING'),
        createDelayNodeResultValue(1, 'Node B', 'TESTING')
      ]));
      service.queueCancelDelayResult(createDelaySnapshotResultValue('Group A', 98, 'delay-job-10', 'CANCELLED', [
        createDelayNodeResultValue(0, 'Node A', 'AVAILABLE', 'Direct', 72, true),
        createDelayNodeResultValue(1, 'Node B', 'FAILED')
      ]));
      service.queueSelectResult(createAppliedNowSelection('Group A', 'Node B', 99));
      service.queueSelectNodeAndEnsureVpnResult(createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED'));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node B', ['Node A', 'Node B'], 99, [], 'vpn-session-live'));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);

      await viewModel.load();
      await viewModel.toggleDelayTest();
      await viewModel.toggleDelayTest();
      await viewModel.activateNode(1);

      expect(service.oneClickCalls.length).assertEqual(0);
      expect(viewModel.current().delayState).assertEqual('RUNNING');

      await viewModel.toggleDelayTest();
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('CONFIRMING_SELECTION', true, 'NONE'));
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED'));
      await viewModel.activateNode(1);

      expect(service.oneClickCalls.length).assertEqual(1);
      expect(viewModel.current().groupGeneration).assertEqual(99);
      expect(viewModel.current().delayState).assertEqual('CANCELLED');
      expect(viewModel.current().nodes[0].delayStatus).assertEqual('AVAILABLE');
      expect(viewModel.current().nodes[1].delayStatus).assertEqual('FAILED');
      expect(viewModel.current().nodes[1].runtimeSelected).assertTrue();
    });

    it('suppressesPublicationsAfterDisposeAndClearsListeners', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredGroup = new DeferredResult<ProxyGroupQueryResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 70));
      service.queueQueryGroupResult('Group A', deferredGroup.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());
      const states: ProxyViewState[] = [];
      const listenerId = viewModel.subscribe((state: ProxyViewState): void => {
        states.push(state);
      });

      const loadPromise = viewModel.load();
      viewModel.unsubscribe(listenerId);
      viewModel.dispose();
      deferredGroup.resolve(createQueryResult('Group A', 'Node A', ['Node A'], 70));
      await loadPromise;

      expect(states.length).assertEqual(1);
      expect(viewModel.current().status).assertEqual('LOADING');
    });

    it('reportsDisposeDelayDrainFailureInsteadOfSwallowingIt', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const scheduler = new ManualDelayScheduler();
      service.queueListGroupsResult(createListResult(['Group A'], 132));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A'], 132));
      service.queueStartDelayResult(createDelaySnapshotResultValue('Group A', 132, 'delay-job-dispose-fail', 'RUNNING', [
        createDelayNodeResultValue(0, 'Node A', 'TESTING')
      ]));
      service.queueCancelAndDrainResult(Promise.reject(new Error('safe drain failure')));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort(), scheduler);

      await viewModel.load();
      await viewModel.toggleDelayTest();
      const didDrain: boolean = await viewModel.dispose();

      expect(didDrain).assertFalse();
      expect(service.cancelAndDrainCalls).assertEqual(1);
      expect(scheduler.pendingCount()).assertEqual(0);
    });

    it('publishesClonedSnapshotsToListeners', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const states: ProxyViewState[] = [];
      service.queueListGroupsResult(createListResult(['Group A'], 80));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 80));
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());
      viewModel.subscribe((state: ProxyViewState): void => {
        states.push(state);
      });

      await viewModel.load();

      const published = lastPublished(states);
      published.groups[0].name = 'Mutated Group';
      published.nodes[0].name = 'Mutated Node';

      expect(viewModel.current().groups[0].name).assertEqual('Group A');
      expect(viewModel.current().nodes[0].name).assertEqual('Node A');
    });

    it('isolatesThrowingViewListenersSoLoadProgressAndFailureStillReachLaterSubscribers', 0, async () => {
      const service = new RecordingProxyApplicationPort();
      const deferredSelection = new DeferredResult<SelectNodeAndEnsureVpnResult>();
      service.queueListGroupsResult(createListResult(['Group A'], 131));
      service.queueQueryGroupResult('Group A', createQueryResult('Group A', 'Node A', ['Node A', 'Node B'], 131));
      service.queueSelectNodeAndEnsureVpnResult(deferredSelection.promise);
      const viewModel = new ProxyViewModel(service, new ImmediateDeadlinePort());
      const observedStages: string[] = [];

      viewModel.subscribe((_state: ProxyViewState): void => {
        throw new Error('listener exploded');
      });
      viewModel.subscribe((state: ProxyViewState): void => {
        observedStages.push(`${state.status}:${state.activationStage}`);
      });

      await viewModel.load();
      const activationPromise = viewModel.activateNode(1);
      service.publishOneClickOperation(createOneClickVpnOperationSnapshot('SAVING_SELECTION', true, 'NONE'));
      deferredSelection.resolve(createOneClickVpnFailureResult(
        'VPN_START',
        'VPN_START_FAILED',
        true,
        'error_vpn_start_failed',
        true
      ));
      await activationPromise;

      expect(observedStages[0]).assertEqual('LOADING:IDLE');
      expect(observedStages).assertContain('READY:IDLE');
      expect(observedStages).assertContain('READY:SAVING_SELECTION');
      expect(viewModel.current().activationStage).assertEqual('FAILED');
      expect(viewModel.current().activationErrorResourceId).assertEqual('error_vpn_start_failed');
    });
  });
}
