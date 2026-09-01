export type SelectNodeAndEnsureVpnSuccessKind =
  | 'ALREADY_ACTIVE'
  | 'APPLIED_TO_RUNNING_VPN'
  | 'APPLIED_TO_RUNNING_VPN_NOT_PERSISTED'
  | 'VPN_STARTED'
  | 'SAVED_VPN_START_FAILED';

export type OneClickVpnFailureStage =
  | 'ADMISSION'
  | 'SELECTION'
  | 'VPN_START'
  | 'VPN_CONFIRMATION';

export type OneClickVpnFailureCode =
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

export type OneClickVpnErrorResourceId =
  | 'proxies_one_click_busy'
  | 'proxies_error_selection_stale'
  | 'proxies_error_selection_failed'
  | 'proxies_error_persistence_failed'
  | 'error_vpn_profile_unavailable'
  | 'error_vpn_permission_denied'
  | 'error_vpn_start_failed'
  | 'proxies_one_click_confirmation_timeout'
  | 'proxies_error_session_changed';

export type OneClickVpnProgressStage =
  | 'IDLE'
  | 'SAVING_SELECTION'
  | 'STARTING_VPN'
  | 'SWITCHING_VPN'
  | 'CONFIRMING_SELECTION';

export type OneClickVpnOperationOutcome = 'NONE' | 'SUCCEEDED' | 'FAILED';

export interface SelectNodeAndEnsureVpnSucceededResult {
  kind: SelectNodeAndEnsureVpnSuccessKind;
}

export interface SelectNodeAndEnsureVpnFailedResult {
  kind: 'FAILED';
  stage: OneClickVpnFailureStage;
  code: OneClickVpnFailureCode;
  retryable: boolean;
  resourceId: OneClickVpnErrorResourceId;
  savedForNextStart: boolean;
}

export type SelectNodeAndEnsureVpnResult =
  | SelectNodeAndEnsureVpnSucceededResult
  | SelectNodeAndEnsureVpnFailedResult;

export interface OneClickVpnOperationSnapshot {
  stage: OneClickVpnProgressStage;
  busy: boolean;
  outcome: OneClickVpnOperationOutcome;
}

const selectNodeAndEnsureVpnSuccessKinds: SelectNodeAndEnsureVpnSuccessKind[] = [
  'ALREADY_ACTIVE',
  'APPLIED_TO_RUNNING_VPN',
  'APPLIED_TO_RUNNING_VPN_NOT_PERSISTED',
  'VPN_STARTED',
  'SAVED_VPN_START_FAILED'
];

const oneClickVpnFailureStages: OneClickVpnFailureStage[] = [
  'ADMISSION',
  'SELECTION',
  'VPN_START',
  'VPN_CONFIRMATION'
];

const oneClickVpnFailureCodes: OneClickVpnFailureCode[] = [
  'OPERATION_BUSY',
  'PROXY_SELECTION_STALE',
  'PROXY_SELECTION_FAILED',
  'PROXY_PERSISTENCE_FAILED',
  'VPN_PROFILE_UNAVAILABLE',
  'VPN_PERMISSION_DENIED',
  'VPN_START_FAILED',
  'VPN_STOPPED_BEFORE_RUNNING',
  'VPN_CONFIRMATION_TIMEOUT',
  'VPN_SESSION_CHANGED'
];

const oneClickVpnErrorResourceIds: OneClickVpnErrorResourceId[] = [
  'proxies_one_click_busy',
  'proxies_error_selection_stale',
  'proxies_error_selection_failed',
  'proxies_error_persistence_failed',
  'error_vpn_profile_unavailable',
  'error_vpn_permission_denied',
  'error_vpn_start_failed',
  'proxies_one_click_confirmation_timeout',
  'proxies_error_session_changed'
];

const oneClickVpnProgressStages: OneClickVpnProgressStage[] = [
  'IDLE',
  'SAVING_SELECTION',
  'STARTING_VPN',
  'SWITCHING_VPN',
  'CONFIRMING_SELECTION'
];

const oneClickVpnOperationOutcomes: OneClickVpnOperationOutcome[] = [
  'NONE',
  'SUCCEEDED',
  'FAILED'
];

class SelectNodeAndEnsureVpnSucceededResultValue implements SelectNodeAndEnsureVpnSucceededResult {
  kind: SelectNodeAndEnsureVpnSuccessKind = 'ALREADY_ACTIVE';
}

class SelectNodeAndEnsureVpnFailedResultValue implements SelectNodeAndEnsureVpnFailedResult {
  kind: 'FAILED' = 'FAILED';
  stage: OneClickVpnFailureStage = 'ADMISSION';
  code: OneClickVpnFailureCode = 'OPERATION_BUSY';
  retryable: boolean = false;
  resourceId: OneClickVpnErrorResourceId = 'proxies_one_click_busy';
  savedForNextStart: boolean = false;
}

class OneClickVpnOperationSnapshotValue implements OneClickVpnOperationSnapshot {
  stage: OneClickVpnProgressStage = 'IDLE';
  busy: boolean = false;
  outcome: OneClickVpnOperationOutcome = 'NONE';
}

interface OneClickVpnFailureContract {
  stage: OneClickVpnFailureStage;
  code: OneClickVpnFailureCode;
  resourceId: OneClickVpnErrorResourceId;
  retryableOptions: boolean[];
  savedForNextStartOptions: boolean[];
}

const oneClickVpnFailureContracts: OneClickVpnFailureContract[] = [
  {
    stage: 'ADMISSION',
    code: 'OPERATION_BUSY',
    resourceId: 'proxies_one_click_busy',
    retryableOptions: [true],
    savedForNextStartOptions: [false, true]
  },
  {
    stage: 'SELECTION',
    code: 'PROXY_SELECTION_STALE',
    resourceId: 'proxies_error_selection_stale',
    retryableOptions: [true],
    savedForNextStartOptions: [false]
  },
  {
    stage: 'SELECTION',
    code: 'PROXY_SELECTION_FAILED',
    resourceId: 'proxies_error_selection_failed',
    retryableOptions: [true],
    savedForNextStartOptions: [false]
  },
  {
    stage: 'SELECTION',
    code: 'PROXY_PERSISTENCE_FAILED',
    resourceId: 'proxies_error_persistence_failed',
    retryableOptions: [false, true],
    savedForNextStartOptions: [false]
  },
  {
    stage: 'VPN_START',
    code: 'VPN_PROFILE_UNAVAILABLE',
    resourceId: 'error_vpn_profile_unavailable',
    retryableOptions: [false],
    savedForNextStartOptions: [true]
  },
  {
    stage: 'VPN_START',
    code: 'VPN_PERMISSION_DENIED',
    resourceId: 'error_vpn_permission_denied',
    retryableOptions: [true],
    savedForNextStartOptions: [true]
  },
  {
    stage: 'VPN_START',
    code: 'VPN_START_FAILED',
    resourceId: 'error_vpn_start_failed',
    retryableOptions: [true],
    savedForNextStartOptions: [true]
  },
  {
    stage: 'VPN_START',
    code: 'VPN_STOPPED_BEFORE_RUNNING',
    resourceId: 'error_vpn_start_failed',
    retryableOptions: [true],
    savedForNextStartOptions: [true]
  },
  {
    stage: 'VPN_CONFIRMATION',
    code: 'VPN_CONFIRMATION_TIMEOUT',
    resourceId: 'proxies_one_click_confirmation_timeout',
    retryableOptions: [true],
    savedForNextStartOptions: [true]
  },
  {
    stage: 'VPN_CONFIRMATION',
    code: 'VPN_SESSION_CHANGED',
    resourceId: 'proxies_error_session_changed',
    retryableOptions: [true],
    savedForNextStartOptions: [true]
  }
];

function normalizeSelectNodeAndEnsureVpnSuccessKind(
  kind: SelectNodeAndEnsureVpnSuccessKind
): SelectNodeAndEnsureVpnSuccessKind {
  for (let index: number = 0; index < selectNodeAndEnsureVpnSuccessKinds.length; index += 1) {
    if (selectNodeAndEnsureVpnSuccessKinds[index] === kind) {
      return kind;
    }
  }
  throw new Error('One-click VPN success kind must stay inside the allowlisted public contract.');
}

function normalizeOneClickVpnFailureStage(stage: OneClickVpnFailureStage): OneClickVpnFailureStage {
  for (let index: number = 0; index < oneClickVpnFailureStages.length; index += 1) {
    if (oneClickVpnFailureStages[index] === stage) {
      return stage;
    }
  }
  throw new Error('One-click VPN failure stage must stay inside the allowlisted public contract.');
}

function normalizeOneClickVpnFailureCode(code: OneClickVpnFailureCode): OneClickVpnFailureCode {
  for (let index: number = 0; index < oneClickVpnFailureCodes.length; index += 1) {
    if (oneClickVpnFailureCodes[index] === code) {
      return code;
    }
  }
  throw new Error('One-click VPN failure code must stay inside the allowlisted public contract.');
}

function normalizeOneClickVpnErrorResourceId(resourceId: OneClickVpnErrorResourceId): OneClickVpnErrorResourceId {
  for (let index: number = 0; index < oneClickVpnErrorResourceIds.length; index += 1) {
    if (oneClickVpnErrorResourceIds[index] === resourceId) {
      return resourceId;
    }
  }
  throw new Error('One-click VPN resourceId must stay inside the allowlisted public contract.');
}

function normalizeOneClickVpnProgressStage(stage: OneClickVpnProgressStage): OneClickVpnProgressStage {
  for (let index: number = 0; index < oneClickVpnProgressStages.length; index += 1) {
    if (oneClickVpnProgressStages[index] === stage) {
      return stage;
    }
  }
  throw new Error('One-click VPN progress stage must stay inside the allowlisted public contract.');
}

function normalizeOneClickVpnOperationOutcome(outcome: OneClickVpnOperationOutcome): OneClickVpnOperationOutcome {
  for (let index: number = 0; index < oneClickVpnOperationOutcomes.length; index += 1) {
    if (oneClickVpnOperationOutcomes[index] === outcome) {
      return outcome;
    }
  }
  throw new Error('One-click VPN operation outcome must stay inside the allowlisted public contract.');
}

function containsBoolean(values: boolean[], candidate: boolean): boolean {
  for (let index: number = 0; index < values.length; index += 1) {
    if (values[index] === candidate) {
      return true;
    }
  }
  return false;
}

function sortedKeys(record: Object): string[] {
  const keys: string[] = Object.keys(record);
  keys.sort();
  return keys;
}

function validateExactKeys(record: Object, expectedKeys: string[], label: string): void {
  const actualKeys: string[] = sortedKeys(record);
  const sortedExpectedKeys: string[] = expectedKeys.slice().sort();
  if (actualKeys.length !== sortedExpectedKeys.length) {
    throw new Error(`${label} must contain exact keys: ${sortedExpectedKeys.join(',')}.`);
  }
  for (let index: number = 0; index < sortedExpectedKeys.length; index += 1) {
    if (actualKeys[index] !== sortedExpectedKeys[index]) {
      throw new Error(`${label} must contain exact keys: ${sortedExpectedKeys.join(',')}.`);
    }
  }
}

function validateOneClickVpnFailureMapping(
  stage: OneClickVpnFailureStage,
  code: OneClickVpnFailureCode,
  retryable: boolean,
  resourceId: OneClickVpnErrorResourceId,
  savedForNextStart: boolean
): void {
  for (let index: number = 0; index < oneClickVpnFailureContracts.length; index += 1) {
    const contract: OneClickVpnFailureContract = oneClickVpnFailureContracts[index];
    if (contract.code !== code) {
      continue;
    }
    if (contract.stage !== stage ||
      contract.resourceId !== resourceId ||
      !containsBoolean(contract.retryableOptions, retryable) ||
      !containsBoolean(contract.savedForNextStartOptions, savedForNextStart)) {
      throw new Error(`One-click VPN failure mapping for ${code} must match the exact closed mapping.`);
    }
    return;
  }
  throw new Error(`One-click VPN failure mapping for ${code} must match the exact closed mapping.`);
}

function validateOneClickVpnOperationSnapshotInvariant(
  stage: OneClickVpnProgressStage,
  busy: boolean,
  outcome: OneClickVpnOperationOutcome
): void {
  if (stage === 'IDLE') {
    if (busy) {
      throw new Error('IDLE one-click VPN snapshots must not report busy=true.');
    }
    return;
  }
  if (!busy) {
    throw new Error('Live one-click VPN stages must report busy=true.');
  }
  if (outcome !== 'NONE') {
    throw new Error('Live one-click VPN stages must keep outcome=NONE.');
  }
}

export function listSelectNodeAndEnsureVpnSuccessKinds(): SelectNodeAndEnsureVpnSuccessKind[] {
  return selectNodeAndEnsureVpnSuccessKinds.slice();
}

export function listOneClickVpnFailureStages(): OneClickVpnFailureStage[] {
  return oneClickVpnFailureStages.slice();
}

export function listOneClickVpnFailureCodes(): OneClickVpnFailureCode[] {
  return oneClickVpnFailureCodes.slice();
}

export function listOneClickVpnErrorResourceIds(): OneClickVpnErrorResourceId[] {
  return oneClickVpnErrorResourceIds.slice();
}

export function listOneClickVpnProgressStages(): OneClickVpnProgressStage[] {
  return oneClickVpnProgressStages.slice();
}

export function listOneClickVpnOperationOutcomes(): OneClickVpnOperationOutcome[] {
  return oneClickVpnOperationOutcomes.slice();
}

export function createSelectNodeAndEnsureVpnSuccessResult(
  kind: SelectNodeAndEnsureVpnSuccessKind
): SelectNodeAndEnsureVpnResult {
  const result: SelectNodeAndEnsureVpnSucceededResultValue = new SelectNodeAndEnsureVpnSucceededResultValue();
  result.kind = normalizeSelectNodeAndEnsureVpnSuccessKind(kind);
  return result;
}

export function createOneClickVpnFailureResult(
  stage: OneClickVpnFailureStage,
  code: OneClickVpnFailureCode,
  retryable: boolean,
  resourceId: OneClickVpnErrorResourceId,
  savedForNextStart: boolean
): SelectNodeAndEnsureVpnResult {
  const normalizedStage: OneClickVpnFailureStage = normalizeOneClickVpnFailureStage(stage);
  const normalizedCode: OneClickVpnFailureCode = normalizeOneClickVpnFailureCode(code);
  const normalizedResourceId: OneClickVpnErrorResourceId = normalizeOneClickVpnErrorResourceId(resourceId);
  validateOneClickVpnFailureMapping(
    normalizedStage,
    normalizedCode,
    retryable,
    normalizedResourceId,
    savedForNextStart
  );
  const result: SelectNodeAndEnsureVpnFailedResultValue = new SelectNodeAndEnsureVpnFailedResultValue();
  result.stage = normalizedStage;
  result.code = normalizedCode;
  result.retryable = retryable;
  result.resourceId = normalizedResourceId;
  result.savedForNextStart = savedForNextStart;
  return result;
}

export function cloneSelectNodeAndEnsureVpnResult(
  result: SelectNodeAndEnsureVpnResult
): SelectNodeAndEnsureVpnResult {
  if (result.kind === 'FAILED') {
    validateExactKeys(
      result as Object,
      ['kind', 'stage', 'code', 'retryable', 'resourceId', 'savedForNextStart'],
      'One-click VPN failed result'
    );
    return createOneClickVpnFailureResult(
      result.stage,
      result.code,
      result.retryable,
      result.resourceId,
      result.savedForNextStart
    );
  }
  validateExactKeys(result as Object, ['kind'], 'One-click VPN success result');
  return createSelectNodeAndEnsureVpnSuccessResult(result.kind);
}

export function createOneClickVpnOperationSnapshot(
  stage: OneClickVpnProgressStage,
  busy: boolean,
  outcome: OneClickVpnOperationOutcome
): OneClickVpnOperationSnapshot {
  const normalizedStage: OneClickVpnProgressStage = normalizeOneClickVpnProgressStage(stage);
  const normalizedOutcome: OneClickVpnOperationOutcome = normalizeOneClickVpnOperationOutcome(outcome);
  validateOneClickVpnOperationSnapshotInvariant(normalizedStage, busy, normalizedOutcome);
  const snapshot: OneClickVpnOperationSnapshotValue = new OneClickVpnOperationSnapshotValue();
  snapshot.stage = normalizedStage;
  snapshot.busy = busy;
  snapshot.outcome = normalizedOutcome;
  return snapshot;
}

export function cloneOneClickVpnOperationSnapshot(
  snapshot: OneClickVpnOperationSnapshot
): OneClickVpnOperationSnapshot {
  validateExactKeys(snapshot as Object, ['stage', 'busy', 'outcome'], 'One-click VPN operation snapshot');
  return createOneClickVpnOperationSnapshot(snapshot.stage, snapshot.busy, snapshot.outcome);
}
