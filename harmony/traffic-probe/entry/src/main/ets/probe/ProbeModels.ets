export const PROBE_EVIDENCE_PATH: string = '/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json';
export const PROBE_EVIDENCE_FILE_NAME: string = 'phase4-probe-evidence.json';
export const PROBE_HTTP_HEADER_RUN_ID: string = 'XCMFAProbeRunId';
export const PROBE_HTTP_HEADER_SESSION_ID: string = 'XCMFAProbeSessionId';
export const PROBE_HTTP_HEADER_FLOW_ID: string = 'XCMFAProbeFlowId';
export const PROBE_FAILURE_DETAIL_DNS_LOOKUP_FAILED: string = 'Standalone DNS correlation lookup failed.';
export const PROBE_FAILURE_DETAIL_DNS_LOOKUP_EMPTY: string = 'Standalone DNS correlation lookup returned no addresses.';
export const PROBE_FAILURE_DETAIL_HTTPS_FAILED: string = 'Standalone HTTPS correlation check failed.';
export const PROBE_FAILURE_DETAIL_TCP_FAILED: string = 'Standalone TCP correlation check failed.';
export const PROBE_FAILURE_DETAIL_UDP_FAILED: string = 'Standalone UDP correlation check failed.';
export const PROBE_FAILURE_DETAIL_DNS_PACKET_FAILED: string = 'Standalone DNS packet correlation check failed.';
export const PROBE_FAILURE_DETAIL_HTTP_CONNECT_FAILED: string = 'Standalone HTTP CONNECT correlation check failed.';
export const PROBE_FAILURE_DETAIL_SOCKS5_FAILED: string = 'Standalone SOCKS5 correlation check failed.';

export class ProbePageStepState {
  id: string;
  label: string;
  outcome: string;

  constructor(id: string, label: string, outcome: string = 'pending') {
    this.id = id;
    this.label = label;
    this.outcome = outcome;
  }
}

@Observed
export class ProbePageState {
  overallOutcome: string = 'pending';
  summary: string = 'PENDING';
  steps: Array<ProbePageStepState> = [
    new ProbePageStepState('https', 'HTTPS direct'),
    new ProbePageStepState('tcp', 'TCP direct'),
    new ProbePageStepState('udp-ipv4', 'UDP IPv4'),
    new ProbePageStepState('udp-ipv6', 'UDP IPv6'),
    new ProbePageStepState('dns-lookup', 'DNS lookup'),
    new ProbePageStepState('dns-packet-ipv4', 'DNS-shaped UDP echo IPv4'),
    new ProbePageStepState('dns-packet-ipv6', 'DNS-shaped UDP echo IPv6'),
    new ProbePageStepState('http-connect', 'HTTP CONNECT'),
    new ProbePageStepState('socks5', 'SOCKS5')
  ];

  begin(): void {
    this.overallOutcome = 'running';
    this.summary = 'RUNNING';
    this.resetSteps();
  }

  update(stepId: string, outcome: string): void {
    const step: ProbePageStepState | undefined = this.findStep(stepId);
    if (step !== undefined) {
      step.outcome = outcome;
      this.steps = this.steps.slice();
    }
  }

  finish(outcome: string): void {
    this.overallOutcome = outcome;
    this.summary = outcome.toUpperCase();
    this.steps = this.steps.slice();
  }

  private findStep(stepId: string): ProbePageStepState | undefined {
    for (let index = 0; index < this.steps.length; index += 1) {
      const step: ProbePageStepState = this.steps[index];
      if (step.id === stepId) {
        return step;
      }
    }
    return undefined;
  }

  private resetSteps(): void {
    for (let index = 0; index < this.steps.length; index += 1) {
      this.steps[index].outcome = 'pending';
    }
    this.steps = this.steps.slice();
  }
}

export class ProbeFailure {
  code: string;
  detail: string;

  constructor(code: string, detail: string) {
    this.code = code;
    this.detail = detail;
  }
}

export class ProbeRecord {
  runId: string;
  sessionId: string;
  flowId: string;
  stepId: string;
  ingressExpectation: string;
  outcome: string;
  transport: string;
  targetPort: number;
  startedAt: string;
  completedAt: string;
  bytesSent: number;
  bytesReceived: number;
  statusCode?: number;
  note?: string;

  constructor(
    runId: string,
    sessionId: string,
    flowId: string,
    stepId: string,
    ingressExpectation: string,
    outcome: string,
    transport: string,
    targetPort: number,
    startedAt: string,
    completedAt: string,
    bytesSent: number,
    bytesReceived: number,
    statusCode?: number,
    note?: string
  ) {
    this.runId = runId;
    this.sessionId = sessionId;
    this.flowId = flowId;
    this.stepId = stepId;
    this.ingressExpectation = ingressExpectation;
    this.outcome = outcome;
    this.transport = transport;
    this.targetPort = targetPort;
    this.startedAt = startedAt;
    this.completedAt = completedAt;
    this.bytesSent = bytesSent;
    this.bytesReceived = bytesReceived;
    this.statusCode = statusCode;
    this.note = note;
  }
}

export class ProbeEvidence {
  version: string;
  result: string;
  runId: string;
  sessionId: string;
  startedAt: string;
  completedAt: string;
  records: Array<ProbeRecord>;
  failures: Array<ProbeFailure>;

  constructor(
    version: string,
    result: string,
    runId: string,
    sessionId: string,
    startedAt: string,
    completedAt: string,
    records: Array<ProbeRecord>,
    failures: Array<ProbeFailure>
  ) {
    this.version = version;
    this.result = result;
    this.runId = runId;
    this.sessionId = sessionId;
    this.startedAt = startedAt;
    this.completedAt = completedAt;
    this.records = records;
    this.failures = failures;
  }
}

export class ProbeRunResult {
  outcome: string;
  records: Array<ProbeRecord>;
  failures: Array<ProbeFailure>;
  evidencePath: string;

  constructor(
    outcome: string,
    records: Array<ProbeRecord>,
    failures: Array<ProbeFailure>,
    evidencePath: string
  ) {
    this.outcome = outcome;
    this.records = records;
    this.failures = failures;
    this.evidencePath = evidencePath;
  }
}

export class ProbeFlowIdSet {
  https: string = '';
  tcp: string = '';
  udpIpv4: string = '';
  udpIpv6: string = '';
  dnsLookup: string = '';
  dnsPacketIpv4: string = '';
  dnsPacketIpv6: string = '';
  httpConnect: string = '';
  socks5: string = '';
}

export class ProbeOriginConfig {
  host: string = '';
  httpsPort: number = 0;
  tcpPort: number = 0;
  udpPort: number = 0;
  dnsPort: number = 0;
}

export class ProbeLocalListenerConfig {
  httpConnectPort: number = 0;
  socks5Port: number = 0;
}

export class ProbeCommand {
  runId: string = '';
  sessionId: string = '';
  flowIds: ProbeFlowIdSet = new ProbeFlowIdSet();
  lanOrigin: ProbeOriginConfig = new ProbeOriginConfig();
  localListeners: ProbeLocalListenerConfig = new ProbeLocalListenerConfig();
  pinnedCertificateHash: string = '';
}

export class ProbeSocketAddress {
  address: string = '';
  family: number = 1;
  port: number = 0;

  constructor(address: string = '', family: number = 1, port: number = 0) {
    this.address = address;
    this.family = family;
    this.port = port;
  }
}

export class ProbeTcpConnectOptions {
  address: ProbeSocketAddress = new ProbeSocketAddress();
  timeout: number = 0;
}

export class ProbeUdpSendOptions {
  data: ArrayBuffer = new ArrayBuffer(0);
  address: ProbeSocketAddress = new ProbeSocketAddress();
}

export class ProbeRemoteInfo {
  address: string = '';
  family: string = 'IPv4';
  port: number = 0;
  size: number = 0;
}

export class ProbeSocketMessage {
  message: ArrayBuffer = new ArrayBuffer(0);
  remoteInfo: ProbeRemoteInfo = new ProbeRemoteInfo();
}

export class ProbeCertificatePinning {
  publicKeyHash: string = '';
  hashAlgorithm: 'SHA-256' = 'SHA-256';
}

export class ProbeHttpHeaders {
  runIdHeader: string = '';
  sessionIdHeader: string = '';
  flowIdHeader: string = '';
}

export class ProbeHttpRequestOptions {
  method: string = 'GET';
  connectTimeout: number = 0;
  readTimeout: number = 0;
  maxLimit: number = 0;
  maxRedirects: number = 0;
  usingCache: boolean = false;
  expectDataType: string = 'ARRAY_BUFFER';
  headers: ProbeHttpHeaders = new ProbeHttpHeaders();
  certificatePinning: ProbeCertificatePinning = new ProbeCertificatePinning();
}

export class ProbeHttpResponse {
  statusCode: number = 0;
  body: ArrayBuffer = new ArrayBuffer(0);
}

export class ProbeDnsAddress {
  address: string = '';
  family: number = 1;
  port: number = 0;

  constructor(address: string = '', family: number = 1, port: number = 0) {
    this.address = address;
    this.family = family;
    this.port = port;
  }
}

export class ProbeFileWriteRecord {
  path: string = '';
  content: string = '';

  constructor(path: string = '', content: string = '') {
    this.path = path;
    this.content = content;
  }
}

export function isValidOpaqueProbeId(value: string): boolean {
  const trimmed: string = value.trim();
  return trimmed.length > 0 &&
    trimmed.length <= 128 &&
    !/\s/u.test(trimmed) &&
    /^[0-9A-Za-z._:-]+$/u.test(trimmed);
}

export function isValidProbeHost(value: string): boolean {
  const trimmed: string = value.trim();
  if (!(trimmed.length > 0 &&
    trimmed.length <= 255 &&
    !/\s/u.test(trimmed) &&
    /^[0-9A-Za-z:.-]+$/u.test(trimmed))) {
    return false;
  }
  if (trimmed.includes('.') && !trimmed.includes(':')) {
    const segments: Array<string> = trimmed.split('.');
    if (segments.length === 4) {
      return isValidIpv4Literal(trimmed);
    }
  }
  return true;
}

export function isValidProbePort(value: number): boolean {
  return Number.isInteger(value) && value >= 1 && value <= 65535;
}

export function isValidPinnedCertificateHash(value: string): boolean {
  return /^sha256\/[0-9A-Za-z+/=]{20,}$/u.test(value.trim());
}

export function areCompleteUniqueFlowIds(flowIds: ProbeFlowIdSet): boolean {
  const values: Array<string> = [
    flowIds.https,
    flowIds.tcp,
    flowIds.udpIpv4,
    flowIds.udpIpv6,
    flowIds.dnsLookup,
    flowIds.dnsPacketIpv4,
    flowIds.dnsPacketIpv6,
    flowIds.httpConnect,
    flowIds.socks5
  ];
  const seen: Set<string> = new Set();
  for (let index = 0; index < values.length; index += 1) {
    const next: string = values[index];
    if (!isValidOpaqueProbeId(next) || seen.has(next)) {
      return false;
    }
    seen.add(next);
  }
  return true;
}

export function isCompleteProbeCommand(command: ProbeCommand): boolean {
  return isValidOpaqueProbeId(command.runId) &&
    isValidOpaqueProbeId(command.sessionId) &&
    areCompleteUniqueFlowIds(command.flowIds) &&
    isValidProbeHost(command.lanOrigin.host) &&
    isValidProbePort(command.lanOrigin.httpsPort) &&
    isValidProbePort(command.lanOrigin.tcpPort) &&
    isValidProbePort(command.lanOrigin.udpPort) &&
    isValidProbePort(command.lanOrigin.dnsPort) &&
    isValidProbePort(command.localListeners.httpConnectPort) &&
    isValidProbePort(command.localListeners.socks5Port) &&
    isValidPinnedCertificateHash(command.pinnedCertificateHash);
}

export function formatTerminalOutcome(outcome: string): string {
  if (outcome === 'pass') {
    return 'PASS';
  }
  if (outcome === 'fail') {
    return 'FAIL';
  }
  return '';
}

export function isValidIpv4Literal(value: string): boolean {
  const segments: Array<string> = value.split('.');
  if (segments.length !== 4) {
    return false;
  }
  for (let index = 0; index < segments.length; index += 1) {
    const next: string = segments[index];
    if (!/^\d{1,3}$/u.test(next)) {
      return false;
    }
    const parsed: number = Number(next);
    if (!Number.isInteger(parsed) || parsed < 0 || parsed > 255) {
      return false;
    }
  }
  return true;
}

export function clampEvidenceString(value: string, maxLength: number): string {
  const trimmed: string = value.trim();
  if (trimmed.length <= maxLength) {
    return trimmed;
  }
  return trimmed.slice(0, maxLength);
}

export function buildCorrelationToken(protocol: string, runId: string, sessionId: string, flowId: string): string {
  return `${protocol}|${runId}|${sessionId}|${flowId}`;
}
