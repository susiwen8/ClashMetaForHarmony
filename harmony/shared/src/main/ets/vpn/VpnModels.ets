export type VpnRuntimeState =
  | 'STOPPED'
  | 'AWAITING_CONSENT'
  | 'STARTING'
  | 'RUNNING'
  | 'RECOVERING'
  | 'STOPPING'
  | 'ERROR';

export const VPN_RUNTIME_STATES: VpnRuntimeState[] = [
  'STOPPED',
  'AWAITING_CONSENT',
  'STARTING',
  'RUNNING',
  'RECOVERING',
  'STOPPING',
  'ERROR'
];

export type VpnFailureCode =
  | 'ALREADY_ACTIVE'
  | 'CONSENT_DENIED'
  | 'INVALID_REQUEST'
  | 'NETWORK_LOST'
  | 'NOTIFICATION_START_FAILED'
  | 'NOTIFICATION_STOP_FAILED'
  | 'PLATFORM_CREATE_FAILED'
  | 'PROCESS_PROTECT_FAILED'
  | 'RECOVERY_EXHAUSTED'
  | 'RESOLVE_FAILED'
  | 'SESSION_MISMATCH'
  | 'STOP_FAILED'
  | 'TUN_START_FAILED'
  | 'TUN_STOP_FAILED';

export const VPN_FAILURE_CODES: VpnFailureCode[] = [
  'ALREADY_ACTIVE',
  'CONSENT_DENIED',
  'INVALID_REQUEST',
  'NETWORK_LOST',
  'NOTIFICATION_START_FAILED',
  'NOTIFICATION_STOP_FAILED',
  'PLATFORM_CREATE_FAILED',
  'PROCESS_PROTECT_FAILED',
  'RECOVERY_EXHAUSTED',
  'RESOLVE_FAILED',
  'SESSION_MISMATCH',
  'STOP_FAILED',
  'TUN_START_FAILED',
  'TUN_STOP_FAILED'
];

export interface VpnStartRequest {
  profileId: string;
  versionId: string;
  sessionId: string;
}

export interface TunHandle {
  fd: number;
  vpnId: string;
  sessionId: string;
}

export interface CreateVpnCaptureConfigInput {
  addresses: string[];
  routes: string[];
  dnsServers: string[];
  mtu: number;
  ipv4: boolean;
  ipv6: boolean;
  isBlocking: boolean;
  blockedApplications: string[];
  trustedApplications: string[];
}

export interface VpnCaptureConfig {
  addresses: string[];
  routes: string[];
  dnsServers: string[];
  mtu: number;
  ipv4: boolean;
  ipv6: boolean;
  isBlocking: boolean;
  blockedApplications: string[];
  trustedApplications: string[];
}

export interface TunStartOptions {
  captureConfig: VpnCaptureConfig;
  dnsServers: string[];
}

export interface VpnCounters {
  txPackets: number;
  txBytes: number;
  rxPackets: number;
  rxBytes: number;
}

export interface CreateVpnIngressTraceInput {
  sessionId: string;
  stage: string;
  detail: string;
  atMs: number;
}

export interface VpnIngressTrace {
  sessionId: string;
  stage: string;
  detail: string;
  atMs: number;
}

export interface VpnFailure {
  code: VpnFailureCode;
  detail: string;
}

export type TunRuntimeState = 'IDLE' | 'STARTING' | 'READY' | 'STOPPED' | 'ERROR';

export interface CreateTunRuntimeSnapshotInput {
  sessionId: string;
  state: TunRuntimeState;
  counters: VpnCounters;
  ingressTraces: VpnIngressTrace[];
  failure?: VpnFailure | null;
}

export interface TunRuntimeSnapshot {
  sessionId: string;
  state: TunRuntimeState;
  counters: VpnCounters;
  ingressTraces: VpnIngressTrace[];
  failure: VpnFailure | null;
}

export interface CreateVpnRuntimeSnapshotInput {
  state: VpnRuntimeState;
  activeRequest: VpnStartRequest | null;
  activeHandle: TunHandle | null;
  captureConfig: VpnCaptureConfig | null;
  tunSnapshot: TunRuntimeSnapshot | null;
  notificationActive: boolean;
  recoveryAttempt: number;
  scheduledRetryDelayMs: number | null;
  lastFailure: VpnFailure | null;
}

export interface VpnRuntimeSnapshot {
  state: VpnRuntimeState;
  activeRequest: VpnStartRequest | null;
  activeHandle: TunHandle | null;
  captureConfig: VpnCaptureConfig | null;
  tunSnapshot: TunRuntimeSnapshot | null;
  notificationActive: boolean;
  recoveryAttempt: number;
  scheduledRetryDelayMs: number | null;
  lastFailure: VpnFailure | null;
}

export type VpnRuntimeEventType = 'SNAPSHOT' | 'STATE_CHANGED' | 'FAILED' | 'RECOVERY_SCHEDULED' | 'STOPPED';

export interface VpnRuntimeEvent {
  type: VpnRuntimeEventType;
  snapshot: VpnRuntimeSnapshot;
}

export interface NetworkStatus {
  usable: boolean;
  networkId: string;
}

export interface VpnControllerStartedResult {
  kind: 'STARTED';
  snapshot: VpnRuntimeSnapshot;
}

export interface VpnControllerStoppedResult {
  kind: 'STOPPED';
  snapshot: VpnRuntimeSnapshot;
}

export interface VpnControllerFailedResult {
  kind: 'FAILED';
  snapshot: VpnRuntimeSnapshot;
  failure: VpnFailure;
}

export interface VpnControllerRejectedResult {
  kind: 'REJECTED';
  snapshot: VpnRuntimeSnapshot;
  failure: VpnFailure;
}

export type VpnControllerStartResult =
  | VpnControllerStartedResult
  | VpnControllerStoppedResult
  | VpnControllerFailedResult
  | VpnControllerRejectedResult;

export type VpnControllerStopResult =
  | VpnControllerStoppedResult
  | VpnControllerFailedResult;

const SELF_PACKAGE_NAME: string = 'com.github.kr328.clash.harmony';
const EXACT_ADDRESSES: string[] = ['10.111.222.1/30', 'fd00:111:222::1/126'];
const EXACT_ROUTES: string[] = ['0.0.0.0/0', '::/0'];
const EXACT_DNS: string[] = ['10.111.222.2', 'fd00:111:222::2'];

function normalizeId(rawValue: string, label: string): string {
  const normalized: string = rawValue.trim();
  if (normalized.length === 0) {
    throw new Error(`${label} must not be blank.`);
  }
  return normalized;
}

function cloneStringArray(values: string[]): string[] {
  return values.slice();
}

function expectExactList(label: string, actual: string[], expected: string[]): void {
  if (actual.length !== expected.length) {
    throw new Error(`Vpn ${label} must match the exact full-capture policy.`);
  }
  for (let index = 0; index < actual.length; index += 1) {
    if (actual[index] !== expected[index]) {
      throw new Error(`Vpn ${label} must match the exact full-capture policy.`);
    }
  }
}

function cloneFailure(failure: VpnFailure | null): VpnFailure | null {
  if (failure === null) {
    return null;
  }
  return createVpnFailure(failure.code, failure.detail);
}

function cloneCounters(counters: VpnCounters): VpnCounters {
  return createVpnCounters(counters.txPackets, counters.txBytes, counters.rxPackets, counters.rxBytes);
}

function cloneIngressTraces(traces: VpnIngressTrace[]): VpnIngressTrace[] {
  const clones: VpnIngressTrace[] = [];
  for (let index = 0; index < traces.length; index += 1) {
    clones.push(createVpnIngressTrace({
      sessionId: traces[index].sessionId,
      stage: traces[index].stage,
      detail: traces[index].detail,
      atMs: traces[index].atMs
    }));
  }
  return clones;
}

function cloneVpnStartRequest(request: VpnStartRequest | null): VpnStartRequest | null {
  if (request === null) {
    return null;
  }
  return createVpnStartRequest(request.profileId, request.versionId, request.sessionId);
}

function cloneTunHandle(handle: TunHandle | null): TunHandle | null {
  if (handle === null) {
    return null;
  }
  return createTunHandle(handle.fd, handle.vpnId, handle.sessionId);
}

function cloneCaptureConfig(config: VpnCaptureConfig | null): VpnCaptureConfig | null {
  if (config === null) {
    return null;
  }
  return createVpnCaptureConfig({
    addresses: config.addresses,
    routes: config.routes,
    dnsServers: config.dnsServers,
    mtu: config.mtu,
    ipv4: config.ipv4,
    ipv6: config.ipv6,
    isBlocking: config.isBlocking,
    blockedApplications: config.blockedApplications,
    trustedApplications: config.trustedApplications
  });
}

function cloneTunSnapshot(snapshot: TunRuntimeSnapshot | null): TunRuntimeSnapshot | null {
  if (snapshot === null) {
    return null;
  }
  return createTunRuntimeSnapshot({
    sessionId: snapshot.sessionId,
    state: snapshot.state,
    counters: snapshot.counters,
    ingressTraces: snapshot.ingressTraces,
    failure: snapshot.failure
  });
}

export function createVpnStartRequest(profileId: string, versionId: string, sessionId: string): VpnStartRequest {
  return {
    profileId: normalizeId(profileId, 'Profile id'),
    versionId: normalizeId(versionId, 'Version id'),
    sessionId: normalizeId(sessionId, 'Session id')
  };
}

export function createTunHandle(fd: number, vpnId: string, sessionId: string): TunHandle {
  if (!Number.isInteger(fd) || fd < 0) {
    throw new Error('Tun fd must be a non-negative integer.');
  }
  return {
    fd,
    vpnId: normalizeId(vpnId, 'Vpn id'),
    sessionId: normalizeId(sessionId, 'Session id')
  };
}

export function createVpnCaptureConfig(input: CreateVpnCaptureConfigInput): VpnCaptureConfig {
  const addresses: string[] = cloneStringArray(input.addresses);
  const routes: string[] = cloneStringArray(input.routes);
  const dnsServers: string[] = cloneStringArray(input.dnsServers);
  const blockedApplications: string[] = cloneStringArray(input.blockedApplications);
  const trustedApplications: string[] = cloneStringArray(input.trustedApplications);
  expectExactList('addresses', addresses, EXACT_ADDRESSES);
  expectExactList('routes', routes, EXACT_ROUTES);
  expectExactList('dns servers', dnsServers, EXACT_DNS);
  if (!Number.isInteger(input.mtu) || input.mtu < 1280 || input.mtu > 9000) {
    throw new Error('Vpn MTU must stay within 1280..9000.');
  }
  if (!input.ipv4 || !input.ipv6) {
    throw new Error('Vpn full-capture mode requires both IPv4 and IPv6.');
  }
  if (input.isBlocking) {
    throw new Error('Vpn full-capture mode must stay non-blocking.');
  }
  if (trustedApplications.length > 0) {
    throw new Error('Vpn trusted applications are not allowed.');
  }
  if (blockedApplications.length !== 1 || blockedApplications[0] !== SELF_PACKAGE_NAME) {
    throw new Error('Vpn self-exclusion must block only com.github.kr328.clash.harmony.');
  }
  return {
    addresses,
    routes,
    dnsServers,
    mtu: input.mtu,
    ipv4: input.ipv4,
    ipv6: input.ipv6,
    isBlocking: input.isBlocking,
    blockedApplications,
    trustedApplications
  };
}

export function createTunStartOptions(captureConfig: VpnCaptureConfig, dnsServers: string[]): TunStartOptions {
  const normalizedDnsServers: string[] = cloneStringArray(dnsServers);
  expectExactList('DNS servers', normalizedDnsServers, captureConfig.dnsServers);
  return {
    captureConfig: cloneCaptureConfig(captureConfig)!,
    dnsServers: normalizedDnsServers
  };
}

function normalizeCounter(value: number, label: string): number {
  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`${label} must be a non-negative integer.`);
  }
  return value;
}

export function createVpnCounters(txPackets: number, txBytes: number, rxPackets: number, rxBytes: number): VpnCounters {
  return {
    txPackets: normalizeCounter(txPackets, 'Vpn txPackets'),
    txBytes: normalizeCounter(txBytes, 'Vpn txBytes'),
    rxPackets: normalizeCounter(rxPackets, 'Vpn rxPackets'),
    rxBytes: normalizeCounter(rxBytes, 'Vpn rxBytes')
  };
}

export function createVpnIngressTrace(input: CreateVpnIngressTraceInput): VpnIngressTrace {
  const sessionId: string = normalizeId(input.sessionId, 'Session id');
  const stage: string = input.stage.trim();
  const detail: string = input.detail.trim();
  if (stage.length === 0) {
    throw new Error('Vpn ingress stage must not be blank.');
  }
  if (detail.length === 0) {
    throw new Error('Vpn ingress detail must not be blank.');
  }
  if (!Number.isInteger(input.atMs) || input.atMs < 0) {
    throw new Error('Vpn ingress timestamp must be a non-negative integer.');
  }
  return {
    sessionId,
    stage,
    detail,
    atMs: input.atMs
  };
}

export function createVpnFailure(code: string, detail: string): VpnFailure {
  if (!VPN_FAILURE_CODES.includes(code as VpnFailureCode)) {
    throw new Error('Vpn failure codes must stay allowlisted.');
  }
  const normalizedDetail: string = detail.trim();
  if (normalizedDetail.length === 0) {
    throw new Error('Vpn failure detail must not be blank.');
  }
  return {
    code: code as VpnFailureCode,
    detail: normalizedDetail
  };
}

export function createTunRuntimeSnapshot(input: CreateTunRuntimeSnapshotInput): TunRuntimeSnapshot {
  return {
    sessionId: normalizeId(input.sessionId, 'Session id'),
    state: input.state,
    counters: cloneCounters(input.counters),
    ingressTraces: cloneIngressTraces(input.ingressTraces),
    failure: cloneFailure(input.failure ?? null)
  };
}

export function createVpnRuntimeSnapshot(input: CreateVpnRuntimeSnapshotInput): VpnRuntimeSnapshot {
  return {
    state: input.state,
    activeRequest: cloneVpnStartRequest(input.activeRequest),
    activeHandle: cloneTunHandle(input.activeHandle),
    captureConfig: cloneCaptureConfig(input.captureConfig),
    tunSnapshot: cloneTunSnapshot(input.tunSnapshot),
    notificationActive: input.notificationActive,
    recoveryAttempt: input.recoveryAttempt,
    scheduledRetryDelayMs: input.scheduledRetryDelayMs,
    lastFailure: cloneFailure(input.lastFailure)
  };
}

export function createVpnRuntimeEvent(type: VpnRuntimeEventType, snapshot: VpnRuntimeSnapshot): VpnRuntimeEvent {
  return {
    type,
    snapshot: createVpnRuntimeSnapshot({
      state: snapshot.state,
      activeRequest: snapshot.activeRequest,
      activeHandle: snapshot.activeHandle,
      captureConfig: snapshot.captureConfig,
      tunSnapshot: snapshot.tunSnapshot,
      notificationActive: snapshot.notificationActive,
      recoveryAttempt: snapshot.recoveryAttempt,
      scheduledRetryDelayMs: snapshot.scheduledRetryDelayMs,
      lastFailure: snapshot.lastFailure
    })
  };
}
