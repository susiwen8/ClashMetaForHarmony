import type { OneClickVpnErrorResourceId, ProxyRejectedErrorCode } from '@cmfa/shared';

export type ProxyViewStatus = 'IDLE' | 'LOADING' | 'READY' | 'EMPTY' | 'ERROR';
export type ProxyPersistenceWarning = 'NONE' | 'SAVED_FOR_NEXT_START' | 'APPLIED_NOT_PERSISTED';
export type ProxyDelayViewState = 'IDLE' | 'STARTING' | 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED';
export type ProxyNodeDelayStatus = 'NONE' | 'WAITING' | 'TESTING' | 'AVAILABLE' | 'TIMEOUT' | 'FAILED' | 'CANCELLED' | 'UNSUPPORTED';
export type ProxyActivationStage =
  | 'IDLE'
  | 'SAVING_SELECTION'
  | 'STARTING_VPN'
  | 'SWITCHING_VPN'
  | 'CONFIRMING_SELECTION'
  | 'FAILED';

export interface ProxyActivationStateOptions {
  stage: ProxyActivationStage;
  activatingRowIndex?: number;
  activationErrorResourceId?: OneClickVpnErrorResourceId;
  activationErrorRetryable?: boolean;
}

export interface ProxyGroupTabState {
  semanticId: string;
  index: number;
  name: string;
  type: string;
  active: boolean;
}

export interface ProxyNodeRowState {
  semanticId: string;
  index: number;
  name: string;
  type: string;
  isGroup: boolean;
  runtimeSelected: boolean;
  savedForNextStart: boolean;
  delayStatus: ProxyNodeDelayStatus;
  delayMs?: number;
  delayFastest: boolean;
}

export interface ProxyViewState {
  status: ProxyViewStatus;
  groups: ProxyGroupTabState[];
  nodes: ProxyNodeRowState[];
  groupGeneration?: number;
  selectionPending: boolean;
  activationStage: ProxyActivationStage;
  activatingRowIndex?: number;
  activationErrorResourceId?: OneClickVpnErrorResourceId;
  activationErrorRetryable: boolean;
  warning: ProxyPersistenceWarning;
  delayState: ProxyDelayViewState;
  totalDelayCount: number;
  testableDelayCount: number;
  completedDelayCount: number;
  availableDelayCount: number;
  timeoutDelayCount: number;
  failedDelayCount: number;
  cancelledDelayCount: number;
  unsupportedDelayCount: number;
  fastestDelayNodeIndex?: number;
  errorCode?: ProxyRejectedErrorCode;
  errorRetryable: boolean;
}

export interface ProxyNodeRowDelayOptions {
  delayStatus?: ProxyNodeDelayStatus;
  delayMs?: number;
  delayFastest?: boolean;
}

export interface ProxyViewStateOptions {
  groupGeneration?: number;
  selectionPending?: boolean;
  activation?: ProxyActivationStateOptions;
  warning?: ProxyPersistenceWarning;
  delayState?: ProxyDelayViewState;
  totalDelayCount?: number;
  testableDelayCount?: number;
  completedDelayCount?: number;
  availableDelayCount?: number;
  timeoutDelayCount?: number;
  failedDelayCount?: number;
  cancelledDelayCount?: number;
  unsupportedDelayCount?: number;
  fastestDelayNodeIndex?: number;
  errorCode?: ProxyRejectedErrorCode;
  errorRetryable?: boolean;
}

class ProxyGroupTabStateValue implements ProxyGroupTabState {
  semanticId: string = '';
  index: number = 0;
  name: string = '';
  type: string = '';
  active: boolean = false;
}

class ProxyNodeRowStateValue implements ProxyNodeRowState {
  semanticId: string = '';
  index: number = 0;
  name: string = '';
  type: string = '';
  isGroup: boolean = false;
  runtimeSelected: boolean = false;
  savedForNextStart: boolean = false;
  delayStatus: ProxyNodeDelayStatus = 'NONE';
  delayMs?: number;
  delayFastest: boolean = false;
}

class ProxyViewStateValue implements ProxyViewState {
  status: ProxyViewStatus = 'IDLE';
  groups: ProxyGroupTabState[] = [];
  nodes: ProxyNodeRowState[] = [];
  groupGeneration?: number;
  selectionPending: boolean = false;
  activationStage: ProxyActivationStage = 'IDLE';
  activatingRowIndex?: number;
  activationErrorResourceId?: OneClickVpnErrorResourceId;
  activationErrorRetryable: boolean = false;
  warning: ProxyPersistenceWarning = 'NONE';
  delayState: ProxyDelayViewState = 'IDLE';
  totalDelayCount: number = 0;
  testableDelayCount: number = 0;
  completedDelayCount: number = 0;
  availableDelayCount: number = 0;
  timeoutDelayCount: number = 0;
  failedDelayCount: number = 0;
  cancelledDelayCount: number = 0;
  unsupportedDelayCount: number = 0;
  fastestDelayNodeIndex?: number;
  errorCode?: ProxyRejectedErrorCode;
  errorRetryable: boolean = false;
}

class ProxyNodeRowDelayOptionsValue implements ProxyNodeRowDelayOptions {
  delayStatus?: ProxyNodeDelayStatus;
  delayMs?: number;
  delayFastest?: boolean;
}

class ProxyActivationStateOptionsValue implements ProxyActivationStateOptions {
  stage: ProxyActivationStage = 'IDLE';
  activatingRowIndex?: number;
  activationErrorResourceId?: OneClickVpnErrorResourceId;
  activationErrorRetryable?: boolean;
}

class ProxyViewStateOptionsValue implements ProxyViewStateOptions {
  groupGeneration?: number;
  selectionPending?: boolean;
  activation?: ProxyActivationStateOptions;
  warning?: ProxyPersistenceWarning;
  delayState?: ProxyDelayViewState;
  totalDelayCount?: number;
  testableDelayCount?: number;
  completedDelayCount?: number;
  availableDelayCount?: number;
  timeoutDelayCount?: number;
  failedDelayCount?: number;
  cancelledDelayCount?: number;
  unsupportedDelayCount?: number;
  fastestDelayNodeIndex?: number;
  errorCode?: ProxyRejectedErrorCode;
  errorRetryable?: boolean;
}

class DelayCountsValue {
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

function requireSafeNonNegativeInteger(value: number, label: string): number {
  if (!Number.isInteger(value) || value < 0 || value > Number.MAX_SAFE_INTEGER) {
    throw new Error(`${label} must be a safe non-negative integer.`);
  }
  return value;
}

function failPresentationOrder(): never {
  throw new Error('Proxy presentation ordering is invalid.');
}

function failDelayState(): never {
  throw new Error('Proxy delay presentation state is invalid.');
}

function failActivationState(): never {
  throw new Error('Proxy activation presentation state is invalid.');
}

function isLiveDelayStatus(status: ProxyNodeDelayStatus): boolean {
  return status === 'WAITING' || status === 'TESTING';
}

function isTerminalDelayStatus(status: ProxyNodeDelayStatus): boolean {
  return status === 'AVAILABLE' ||
    status === 'TIMEOUT' ||
    status === 'FAILED' ||
    status === 'CANCELLED' ||
    status === 'UNSUPPORTED';
}

function isLiveActivationStage(stage: ProxyActivationStage): boolean {
  return stage === 'SAVING_SELECTION' ||
    stage === 'STARTING_VPN' ||
    stage === 'SWITCHING_VPN' ||
    stage === 'CONFIRMING_SELECTION';
}

function normalizeActivationStage(stage: ProxyActivationStage): ProxyActivationStage {
  if (stage === 'IDLE' ||
    stage === 'SAVING_SELECTION' ||
    stage === 'STARTING_VPN' ||
    stage === 'SWITCHING_VPN' ||
    stage === 'CONFIRMING_SELECTION' ||
    stage === 'FAILED') {
    return stage;
  }
  failActivationState();
}

function normalizeActivationErrorResourceId(
  resourceId: OneClickVpnErrorResourceId
): OneClickVpnErrorResourceId {
  if (resourceId === 'proxies_one_click_busy' ||
    resourceId === 'proxies_error_selection_stale' ||
    resourceId === 'proxies_error_selection_failed' ||
    resourceId === 'proxies_error_persistence_failed' ||
    resourceId === 'error_vpn_profile_unavailable' ||
    resourceId === 'error_vpn_permission_denied' ||
    resourceId === 'error_vpn_start_failed' ||
    resourceId === 'proxies_one_click_confirmation_timeout' ||
    resourceId === 'proxies_error_session_changed') {
    return resourceId;
  }
  failActivationState();
}

function cloneNodeDelayOptions(options: ProxyNodeRowDelayOptions | undefined): ProxyNodeRowDelayOptionsValue {
  const clone: ProxyNodeRowDelayOptionsValue = new ProxyNodeRowDelayOptionsValue();
  if (options === undefined) {
    return clone;
  }
  clone.delayStatus = options.delayStatus;
  clone.delayMs = options.delayMs;
  clone.delayFastest = options.delayFastest;
  return clone;
}

function cloneActivationOptions(options: ProxyActivationStateOptions | undefined): ProxyActivationStateOptionsValue {
  const clone: ProxyActivationStateOptionsValue = new ProxyActivationStateOptionsValue();
  if (options === undefined) {
    return clone;
  }
  clone.stage = options.stage;
  clone.activatingRowIndex = options.activatingRowIndex;
  clone.activationErrorResourceId = options.activationErrorResourceId;
  clone.activationErrorRetryable = options.activationErrorRetryable;
  return clone;
}

function cloneOptions(options: ProxyViewStateOptions | undefined): ProxyViewStateOptionsValue {
  const clone: ProxyViewStateOptionsValue = new ProxyViewStateOptionsValue();
  if (options === undefined) {
    return clone;
  }
  clone.groupGeneration = options.groupGeneration;
  clone.selectionPending = options.selectionPending;
  if (options.activation !== undefined) {
    clone.activation = cloneActivationOptions(options.activation);
  }
  clone.warning = options.warning;
  clone.delayState = options.delayState;
  clone.totalDelayCount = options.totalDelayCount;
  clone.testableDelayCount = options.testableDelayCount;
  clone.completedDelayCount = options.completedDelayCount;
  clone.availableDelayCount = options.availableDelayCount;
  clone.timeoutDelayCount = options.timeoutDelayCount;
  clone.failedDelayCount = options.failedDelayCount;
  clone.cancelledDelayCount = options.cancelledDelayCount;
  clone.unsupportedDelayCount = options.unsupportedDelayCount;
  clone.fastestDelayNodeIndex = options.fastestDelayNodeIndex;
  clone.errorCode = options.errorCode;
  clone.errorRetryable = options.errorRetryable;
  return clone;
}

function validateRuntimeSelection(status: ProxyViewStatus, nodes: ProxyNodeRowState[]): void {
  let runtimeSelectedCount: number = 0;
  for (let index: number = 0; index < nodes.length; index += 1) {
    if (nodes[index].runtimeSelected) {
      runtimeSelectedCount += 1;
    }
  }
  if (runtimeSelectedCount > 1) {
    throw new Error('Proxy view state allows at most one runtime-selected node row.');
  }
  if (status === 'READY' && runtimeSelectedCount !== 1) {
    throw new Error('Ready proxy view state requires exactly one runtime-selected node row.');
  }
}

function validateGroupPositions(groups: ProxyGroupTabState[]): void {
  for (let index: number = 0; index < groups.length; index += 1) {
    if (groups[index].index !== index) {
      failPresentationOrder();
    }
  }
}

function validateNodePositions(nodes: ProxyNodeRowState[]): void {
  for (let index: number = 0; index < nodes.length; index += 1) {
    if (nodes[index].index !== index) {
      failPresentationOrder();
    }
  }
}

function normalizeDelayCounts(options: ProxyViewStateOptionsValue): DelayCountsValue {
  const counts: DelayCountsValue = new DelayCountsValue();
  counts.totalDelayCount = options.totalDelayCount === undefined
    ? 0
    : requireSafeNonNegativeInteger(options.totalDelayCount, 'Proxy total delay count');
  counts.testableDelayCount = options.testableDelayCount === undefined
    ? 0
    : requireSafeNonNegativeInteger(options.testableDelayCount, 'Proxy testable delay count');
  counts.completedDelayCount = options.completedDelayCount === undefined
    ? 0
    : requireSafeNonNegativeInteger(options.completedDelayCount, 'Proxy completed delay count');
  counts.availableDelayCount = options.availableDelayCount === undefined
    ? 0
    : requireSafeNonNegativeInteger(options.availableDelayCount, 'Proxy available delay count');
  counts.timeoutDelayCount = options.timeoutDelayCount === undefined
    ? 0
    : requireSafeNonNegativeInteger(options.timeoutDelayCount, 'Proxy timeout delay count');
  counts.failedDelayCount = options.failedDelayCount === undefined
    ? 0
    : requireSafeNonNegativeInteger(options.failedDelayCount, 'Proxy failed delay count');
  counts.cancelledDelayCount = options.cancelledDelayCount === undefined
    ? 0
    : requireSafeNonNegativeInteger(options.cancelledDelayCount, 'Proxy cancelled delay count');
  counts.unsupportedDelayCount = options.unsupportedDelayCount === undefined
    ? 0
    : requireSafeNonNegativeInteger(options.unsupportedDelayCount, 'Proxy unsupported delay count');
  if (options.fastestDelayNodeIndex !== undefined) {
    counts.fastestDelayNodeIndex = requireSafeNonNegativeInteger(
      options.fastestDelayNodeIndex,
      'Proxy fastest delay node index'
    );
  }
  return counts;
}

function validateActivationRowIndex(nodes: ProxyNodeRowState[], activatingRowIndex: number): number {
  const normalizedIndex: number = requireSafeNonNegativeInteger(
    activatingRowIndex,
    'Proxy activation row index'
  );
  if (normalizedIndex >= nodes.length || nodes[normalizedIndex].isGroup) {
    failActivationState();
  }
  return normalizedIndex;
}

function applyActivationState(
  state: ProxyViewStateValue,
  nodes: ProxyNodeRowState[],
  options: ProxyActivationStateOptionsValue,
  explicitActivation: boolean,
  selectionPendingOption?: boolean
): void {
  if (!explicitActivation) {
    state.activationStage = 'IDLE';
    state.activatingRowIndex = undefined;
    state.activationErrorResourceId = undefined;
    state.activationErrorRetryable = false;
    state.selectionPending = selectionPendingOption === true;
    return;
  }
  state.activationStage = normalizeActivationStage(options.stage);
  if (state.activationStage === 'IDLE') {
    if (selectionPendingOption === true) {
      failActivationState();
    }
    if (options.activatingRowIndex !== undefined ||
      options.activationErrorResourceId !== undefined ||
      options.activationErrorRetryable === true) {
      failActivationState();
    }
    state.selectionPending = false;
    return;
  }

  if (isLiveActivationStage(state.activationStage)) {
    if (selectionPendingOption === false) {
      failActivationState();
    }
    if (options.activationErrorResourceId !== undefined ||
      options.activationErrorRetryable === true ||
      options.activatingRowIndex === undefined) {
      failActivationState();
    }
    state.selectionPending = true;
    state.activatingRowIndex = validateActivationRowIndex(nodes, options.activatingRowIndex);
    if (nodes[state.activatingRowIndex].runtimeSelected) {
      failActivationState();
    }
    return;
  }

  if (selectionPendingOption === true) {
    failActivationState();
  }
  if (options.activationErrorResourceId === undefined) {
    failActivationState();
  }
  state.selectionPending = false;
  if (options.activatingRowIndex !== undefined) {
    state.activatingRowIndex = validateActivationRowIndex(nodes, options.activatingRowIndex);
  }
  state.activationErrorResourceId = normalizeActivationErrorResourceId(options.activationErrorResourceId);
  state.activationErrorRetryable = options.activationErrorRetryable === true;
}

function validateDelayRowShape(state: ProxyNodeRowStateValue): void {
  if (state.delayStatus === 'NONE') {
    if (state.delayMs !== undefined || state.delayFastest) {
      failDelayState();
    }
    return;
  }
  if (state.delayStatus === 'AVAILABLE') {
    if (state.delayMs === undefined ||
      !Number.isInteger(state.delayMs) ||
      state.delayMs < 1 ||
      state.delayMs > 65535) {
      failDelayState();
    }
    return;
  }
  if (state.delayMs !== undefined || state.delayFastest) {
    failDelayState();
  }
}

function recomputeDelayCounts(nodes: ProxyNodeRowState[]): DelayCountsValue {
  const counts: DelayCountsValue = new DelayCountsValue();
  counts.totalDelayCount = nodes.length;
  let fastestDelay: number = 0;
  let fastestCount: number = 0;
  let markedFastestIndex: number | undefined = undefined;
  for (let index: number = 0; index < nodes.length; index += 1) {
    const node: ProxyNodeRowState = nodes[index];
    if (node.delayStatus === 'UNSUPPORTED') {
      counts.unsupportedDelayCount += 1;
    } else {
      counts.testableDelayCount += 1;
    }
    if (node.delayStatus !== 'NONE' && !isLiveDelayStatus(node.delayStatus)) {
      counts.completedDelayCount += 1;
    }
    if (node.delayStatus === 'AVAILABLE') {
      counts.availableDelayCount += 1;
      const delayMs: number = node.delayMs as number;
      if (counts.fastestDelayNodeIndex === undefined || delayMs < fastestDelay) {
        counts.fastestDelayNodeIndex = index;
        fastestDelay = delayMs;
      }
    } else if (node.delayStatus === 'TIMEOUT') {
      counts.timeoutDelayCount += 1;
    } else if (node.delayStatus === 'FAILED') {
      counts.failedDelayCount += 1;
    } else if (node.delayStatus === 'CANCELLED') {
      counts.cancelledDelayCount += 1;
    }
    if (node.delayFastest) {
      if (node.delayStatus !== 'AVAILABLE') {
        failDelayState();
      }
      fastestCount += 1;
      markedFastestIndex = index;
    }
  }
  if ((counts.fastestDelayNodeIndex === undefined && fastestCount !== 0) ||
    (counts.fastestDelayNodeIndex !== undefined &&
      (fastestCount !== 1 || markedFastestIndex !== counts.fastestDelayNodeIndex))) {
    failDelayState();
  }
  return counts;
}

function validateDelaySnapshot(delayState: ProxyDelayViewState, nodes: ProxyNodeRowState[], counts: DelayCountsValue): void {
  const actual: DelayCountsValue = recomputeDelayCounts(nodes);
  if (counts.fastestDelayNodeIndex !== undefined && counts.fastestDelayNodeIndex >= nodes.length) {
    failDelayState();
  }
  if (delayState === 'IDLE') {
    for (let index: number = 0; index < nodes.length; index += 1) {
      if (nodes[index].delayStatus !== 'NONE') {
        failDelayState();
      }
    }
    if (counts.totalDelayCount !== 0 ||
      counts.testableDelayCount !== 0 ||
      counts.completedDelayCount !== 0 ||
      counts.availableDelayCount !== 0 ||
      counts.timeoutDelayCount !== 0 ||
      counts.failedDelayCount !== 0 ||
      counts.cancelledDelayCount !== 0 ||
      counts.unsupportedDelayCount !== 0 ||
      counts.fastestDelayNodeIndex !== undefined) {
      failDelayState();
    }
    return;
  }
  if (delayState === 'STARTING') {
    for (let index: number = 0; index < nodes.length; index += 1) {
      if (nodes[index].delayStatus !== 'NONE') {
        failDelayState();
      }
    }
    if (counts.totalDelayCount !== 0 ||
      counts.testableDelayCount !== 0 ||
      counts.completedDelayCount !== 0 ||
      counts.availableDelayCount !== 0 ||
      counts.timeoutDelayCount !== 0 ||
      counts.failedDelayCount !== 0 ||
      counts.cancelledDelayCount !== 0 ||
      counts.unsupportedDelayCount !== 0 ||
      counts.fastestDelayNodeIndex !== undefined) {
      failDelayState();
    }
    return;
  }
  for (let index: number = 0; index < nodes.length; index += 1) {
    const node: ProxyNodeRowState = nodes[index];
    if (delayState === 'RUNNING') {
      if (node.delayStatus === 'NONE') {
        failDelayState();
      }
    } else if (!isTerminalDelayStatus(node.delayStatus)) {
      failDelayState();
    }
  }
  if (counts.totalDelayCount !== actual.totalDelayCount ||
    counts.testableDelayCount !== actual.testableDelayCount ||
    counts.completedDelayCount !== actual.completedDelayCount ||
    counts.availableDelayCount !== actual.availableDelayCount ||
    counts.timeoutDelayCount !== actual.timeoutDelayCount ||
    counts.failedDelayCount !== actual.failedDelayCount ||
    counts.cancelledDelayCount !== actual.cancelledDelayCount ||
    counts.unsupportedDelayCount !== actual.unsupportedDelayCount ||
    counts.fastestDelayNodeIndex !== actual.fastestDelayNodeIndex) {
    failDelayState();
  }
}

export function createProxyGroupTabState(
  index: number,
  name: string,
  type: string,
  active: boolean
): ProxyGroupTabState {
  const state: ProxyGroupTabStateValue = new ProxyGroupTabStateValue();
  state.index = requireSafeNonNegativeInteger(index, 'Proxy group tab index');
  state.semanticId = `proxies.group.${state.index}`;
  state.name = name;
  state.type = type;
  state.active = active;
  return state;
}

export function cloneProxyGroupTabState(state: ProxyGroupTabState): ProxyGroupTabState {
  return createProxyGroupTabState(state.index, state.name, state.type, state.active);
}

export function cloneProxyGroupTabStates(states: ProxyGroupTabState[]): ProxyGroupTabState[] {
  const clones: ProxyGroupTabState[] = [];
  for (let index: number = 0; index < states.length; index += 1) {
    clones.push(cloneProxyGroupTabState(states[index]));
  }
  return clones;
}

export function createProxyNodeRowState(
  index: number,
  name: string,
  type: string,
  isGroup: boolean,
  runtimeSelected: boolean,
  savedForNextStart: boolean,
  delayOptions?: ProxyNodeRowDelayOptions
): ProxyNodeRowState {
  const normalizedDelayOptions: ProxyNodeRowDelayOptionsValue = cloneNodeDelayOptions(delayOptions);
  const state: ProxyNodeRowStateValue = new ProxyNodeRowStateValue();
  state.index = requireSafeNonNegativeInteger(index, 'Proxy node row index');
  state.semanticId = `proxies.node.${state.index}`;
  state.name = name;
  state.type = type;
  state.isGroup = isGroup;
  state.runtimeSelected = runtimeSelected;
  state.savedForNextStart = savedForNextStart;
  state.delayStatus = normalizedDelayOptions.delayStatus ?? 'NONE';
  state.delayMs = normalizedDelayOptions.delayMs;
  state.delayFastest = normalizedDelayOptions.delayFastest === true;
  validateDelayRowShape(state);
  return state;
}

export function cloneProxyNodeRowState(state: ProxyNodeRowState): ProxyNodeRowState {
  return createProxyNodeRowState(
    state.index,
    state.name,
    state.type,
    state.isGroup,
    state.runtimeSelected,
    state.savedForNextStart,
    {
      delayStatus: state.delayStatus,
      delayMs: state.delayMs,
      delayFastest: state.delayFastest
    }
  );
}

export function cloneProxyNodeRowStates(states: ProxyNodeRowState[]): ProxyNodeRowState[] {
  const clones: ProxyNodeRowState[] = [];
  for (let index: number = 0; index < states.length; index += 1) {
    clones.push(cloneProxyNodeRowState(states[index]));
  }
  return clones;
}

export function createProxyViewState(
  status: ProxyViewStatus,
  groups: ProxyGroupTabState[],
  nodes: ProxyNodeRowState[],
  options?: ProxyViewStateOptions
): ProxyViewState {
  const normalizedOptions: ProxyViewStateOptionsValue = cloneOptions(options);
  const explicitActivation: boolean = normalizedOptions.activation !== undefined;
  const normalizedActivationOptions: ProxyActivationStateOptionsValue = cloneActivationOptions(normalizedOptions.activation);
  const normalizedDelayCounts: DelayCountsValue = normalizeDelayCounts(normalizedOptions);
  const state: ProxyViewStateValue = new ProxyViewStateValue();
  const clonedGroups: ProxyGroupTabState[] = cloneProxyGroupTabStates(groups);
  const clonedNodes: ProxyNodeRowState[] = cloneProxyNodeRowStates(nodes);
  validateGroupPositions(clonedGroups);
  validateNodePositions(clonedNodes);
  validateRuntimeSelection(status, clonedNodes);
  state.status = status;
  state.groups = clonedGroups;
  state.nodes = clonedNodes;
  if (normalizedOptions.groupGeneration !== undefined) {
    state.groupGeneration = requireSafeNonNegativeInteger(
      normalizedOptions.groupGeneration,
      'Proxy group generation'
    );
  }
  applyActivationState(state, clonedNodes, normalizedActivationOptions, explicitActivation, normalizedOptions.selectionPending);
  state.warning = normalizedOptions.warning ?? 'NONE';
  state.delayState = normalizedOptions.delayState ?? 'IDLE';
  validateDelaySnapshot(state.delayState, clonedNodes, normalizedDelayCounts);
  state.totalDelayCount = normalizedDelayCounts.totalDelayCount;
  state.testableDelayCount = normalizedDelayCounts.testableDelayCount;
  state.completedDelayCount = normalizedDelayCounts.completedDelayCount;
  state.availableDelayCount = normalizedDelayCounts.availableDelayCount;
  state.timeoutDelayCount = normalizedDelayCounts.timeoutDelayCount;
  state.failedDelayCount = normalizedDelayCounts.failedDelayCount;
  state.cancelledDelayCount = normalizedDelayCounts.cancelledDelayCount;
  state.unsupportedDelayCount = normalizedDelayCounts.unsupportedDelayCount;
  state.fastestDelayNodeIndex = normalizedDelayCounts.fastestDelayNodeIndex;
  state.errorCode = normalizedOptions.errorCode;
  state.errorRetryable = normalizedOptions.errorRetryable === true;
  return state;
}

export function cloneProxyViewState(state: ProxyViewState): ProxyViewState {
  const options: ProxyViewStateOptionsValue = new ProxyViewStateOptionsValue();
  options.groupGeneration = state.groupGeneration;
  options.selectionPending = state.selectionPending;
  if (state.activationStage !== 'IDLE' ||
    state.activatingRowIndex !== undefined ||
    state.activationErrorResourceId !== undefined ||
    state.activationErrorRetryable) {
    options.activation = createProxyActivationStateOptions(
      state.activationStage,
      state.activatingRowIndex,
      state.activationErrorResourceId,
      state.activationErrorRetryable
    );
  }
  options.warning = state.warning;
  options.delayState = state.delayState;
  options.totalDelayCount = state.totalDelayCount;
  options.testableDelayCount = state.testableDelayCount;
  options.completedDelayCount = state.completedDelayCount;
  options.availableDelayCount = state.availableDelayCount;
  options.timeoutDelayCount = state.timeoutDelayCount;
  options.failedDelayCount = state.failedDelayCount;
  options.cancelledDelayCount = state.cancelledDelayCount;
  options.unsupportedDelayCount = state.unsupportedDelayCount;
  options.fastestDelayNodeIndex = state.fastestDelayNodeIndex;
  options.errorCode = state.errorCode;
  options.errorRetryable = state.errorRetryable;
  return createProxyViewState(state.status, state.groups, state.nodes, options);
}

export function createProxyActivationStateOptions(
  stage: ProxyActivationStage,
  activatingRowIndex?: number,
  activationErrorResourceId?: OneClickVpnErrorResourceId,
  activationErrorRetryable?: boolean
): ProxyActivationStateOptions {
  const options: ProxyActivationStateOptionsValue = new ProxyActivationStateOptionsValue();
  options.stage = normalizeActivationStage(stage);
  options.activatingRowIndex = activatingRowIndex;
  options.activationErrorResourceId = activationErrorResourceId;
  options.activationErrorRetryable = activationErrorRetryable;
  return options;
}
