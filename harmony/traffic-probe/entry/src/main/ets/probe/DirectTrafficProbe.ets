import { fileIo } from '@kit.CoreFileKit';
import { connection, http, socket } from '@kit.NetworkKit';
import type common from '@ohos.app.ability.common';
import {
  buildCorrelationToken,
  clampEvidenceString,
  PROBE_FAILURE_DETAIL_DNS_LOOKUP_EMPTY,
  PROBE_FAILURE_DETAIL_DNS_LOOKUP_FAILED,
  PROBE_FAILURE_DETAIL_DNS_PACKET_FAILED,
  PROBE_FAILURE_DETAIL_HTTP_CONNECT_FAILED,
  PROBE_FAILURE_DETAIL_HTTPS_FAILED,
  PROBE_FAILURE_DETAIL_SOCKS5_FAILED,
  PROBE_FAILURE_DETAIL_TCP_FAILED,
  PROBE_FAILURE_DETAIL_UDP_FAILED,
  PROBE_HTTP_HEADER_FLOW_ID,
  PROBE_HTTP_HEADER_RUN_ID,
  PROBE_HTTP_HEADER_SESSION_ID,
  PROBE_EVIDENCE_PATH,
  ProbeCertificatePinning,
  ProbeCommand,
  ProbeDnsAddress,
  ProbeEvidence,
  ProbeFailure,
  ProbeFileWriteRecord,
  ProbeFlowIdSet,
  ProbeHttpHeaders,
  ProbeHttpRequestOptions,
  ProbeHttpResponse,
  ProbeLocalListenerConfig,
  ProbeOriginConfig,
  ProbePageState,
  ProbeRecord,
  ProbeRemoteInfo,
  ProbeRunResult,
  ProbeSocketAddress,
  ProbeSocketMessage,
  ProbeTcpConnectOptions,
  ProbeUdpSendOptions,
  formatTerminalOutcome,
  isCompleteProbeCommand,
  isValidIpv4Literal
} from './ProbeModels';

const DEFAULT_TIMEOUT_MS: number = 5_000;
const MAX_EVIDENCE_LENGTH: number = 12_288;
const LOOPBACK_V4: string = '127.0.0.1';
const LOOPBACK_V6: string = '::1';

const HTTPS_STEP_ID: string = 'https';
const TCP_STEP_ID: string = 'tcp';
const UDP_IPV4_STEP_ID: string = 'udp-ipv4';
const UDP_IPV6_STEP_ID: string = 'udp-ipv6';
const DNS_LOOKUP_STEP_ID: string = 'dns-lookup';
const DNS_PACKET_IPV4_STEP_ID: string = 'dns-packet-ipv4';
const DNS_PACKET_IPV6_STEP_ID: string = 'dns-packet-ipv6';
const HTTP_CONNECT_STEP_ID: string = 'http-connect';
const SOCKS5_STEP_ID: string = 'socks5';
const DNS_LOOKUP_FAILED_CODE: string = 'DNS_LOOKUP_FAILED';
const DNS_LOOKUP_EMPTY_CODE: string = 'DNS_LOOKUP_EMPTY';

export interface ProbeProgressReporter {
  onStep(stepId: string, outcome: string): void;
}

export interface HttpProbeDriver {
  request(url: string, options: ProbeHttpRequestOptions): Promise<ProbeHttpResponse>;
  abortCurrentRequest?(): void;
}

export interface TcpProbeConnection {
  send(data: ArrayBuffer): Promise<void>;
  receive(): Promise<ArrayBuffer>;
  close(): Promise<void>;
  cancelReceiveWait?(): void;
}

export interface TcpProbeDriver {
  connect(options: ProbeTcpConnectOptions): Promise<TcpProbeConnection>;
  cancelPendingConnect?(): Promise<void>;
}

export interface UdpProbeSocket {
  bind(address: ProbeSocketAddress): Promise<void>;
  send(options: ProbeUdpSendOptions): Promise<void>;
  receive(): Promise<ProbeSocketMessage>;
  close(): Promise<void>;
  cancelReceiveWait?(): void;
}

export interface UdpProbeDriver {
  createSocket(family: 'IPv4' | 'IPv6'): UdpProbeSocket;
}

export interface DnsProbeDriver {
  getAddressesByName(host: string): Promise<Array<ProbeDnsAddress>>;
  isIpv6Available(): Promise<boolean>;
}

export interface ProbeClock {
  now(): string;
}

export interface ProbeFileDriver {
  writeAtomic(path: string, content: string): Promise<void>;
}

export interface DirectTrafficProbeDependencies {
  httpDriver: HttpProbeDriver;
  tcpDriver: TcpProbeDriver;
  udpDriver: UdpProbeDriver;
  dnsDriver: DnsProbeDriver;
  clock: ProbeClock;
  fileDriver: ProbeFileDriver;
  timeoutMs?: number;
}

type ProbeSocketFactory = () => UdpProbeSocket;

class OriginAddressSet {
  ipv4?: string;
  ipv6?: string;
}

class PendingSocketWaiter {
  readonly promise: Promise<ProbeSocketMessage>;
  private readonly cancelRef: () => void;

  constructor(promise: Promise<ProbeSocketMessage>, cancelRef: () => void) {
    this.promise = promise;
    this.cancelRef = cancelRef;
  }

  cancel(): void {
    this.cancelRef();
  }
}

class ProbePublishReporter implements ProbeProgressReporter {
  private readonly pageState: ProbePageState;

  constructor(pageState: ProbePageState) {
    this.pageState = pageState;
  }

  onStep(stepId: string, outcome: string): void {
    this.pageState.update(stepId, outcome);
  }
}

export class DirectTrafficProbe {
  private readonly dependencies: DirectTrafficProbeDependencies;

  constructor(dependencies: DirectTrafficProbeDependencies) {
    this.dependencies = dependencies;
  }

  async run(command: ProbeCommand, reporter?: ProbeProgressReporter): Promise<ProbeRunResult> {
    if (!isCompleteProbeCommand(command)) {
      throw new Error('Probe command is incomplete.');
    }
    ensureUniqueFlowIds(command.flowIds);

    const startedAt: string = this.dependencies.clock.now();
    const records: Array<ProbeRecord> = [];
    const failures: Array<ProbeFailure> = [];

    await this.runDnsLookup(command, records, failures, reporter);
    const addresses: OriginAddressSet = await this.resolveOriginAddresses(command.lanOrigin.host);
    await this.runHttpsProbe(command, records, failures, reporter);
    await this.runTcpProbe(command, addresses, records, failures, reporter);
    await this.runUdpProbe(command, addresses, false, records, failures, reporter);

    const ipv6Available: boolean = await this.dependencies.dnsDriver.isIpv6Available();
    if (ipv6Available) {
      await this.runUdpProbe(command, addresses, true, records, failures, reporter);
    }

    await this.runDnsPacketProbe(command, addresses, false, records, failures, reporter);
    if (ipv6Available) {
      await this.runDnsPacketProbe(command, addresses, true, records, failures, reporter);
    }

    await this.runHttpConnectProbe(command, records, failures, reporter);
    await this.runSocks5Probe(command, addresses, records, failures, reporter);

    const completedAt: string = this.dependencies.clock.now();
    const outcome: string = failures.length === 0 ? 'pass' : 'fail';
    const evidence: ProbeEvidence = new ProbeEvidence(
      '1.0.0',
      outcome,
      command.runId,
      command.sessionId,
      startedAt,
      completedAt,
      records,
      failures
    );
    await this.dependencies.fileDriver.writeAtomic(PROBE_EVIDENCE_PATH, boundEvidenceJson(evidence));
    return new ProbeRunResult(outcome, records, failures, PROBE_EVIDENCE_PATH);
  }

  private async runDnsLookup(
    command: ProbeCommand,
    records: Array<ProbeRecord>,
    failures: Array<ProbeFailure>,
    reporter?: ProbeProgressReporter
  ): Promise<void> {
    const label: string = buildHashedInvalidLabel(command.runId, command.sessionId);
    const startedAt: string = this.dependencies.clock.now();
    let bytesReceived: number = 0;
    let outcome: string = 'pass';
    let failureCode: string | undefined = undefined;
    let failureDetail: string | undefined = undefined;
    try {
      const addresses: Array<ProbeDnsAddress> = await withTimeout(
        this.dependencies.dnsDriver.getAddressesByName(label),
        'dns-lookup',
        this.timeoutMs()
      );
      bytesReceived = addresses.length;
      if (addresses.length === 0) {
        outcome = 'fail';
        failureCode = DNS_LOOKUP_EMPTY_CODE;
        failureDetail = PROBE_FAILURE_DETAIL_DNS_LOOKUP_EMPTY;
      }
    } catch (_) {
      outcome = 'fail';
      failureCode = DNS_LOOKUP_FAILED_CODE;
      failureDetail = PROBE_FAILURE_DETAIL_DNS_LOOKUP_FAILED;
    }
    if (failureCode !== undefined && failureDetail !== undefined) {
      failures.push(new ProbeFailure(failureCode, failureDetail));
    }
    records.push(new ProbeRecord(
      command.runId,
      command.sessionId,
      command.flowIds.dnsLookup,
      DNS_LOOKUP_STEP_ID,
      'dns-default-lookup',
      outcome,
      'dns',
      command.lanOrigin.dnsPort,
      startedAt,
      this.dependencies.clock.now(),
      0,
      bytesReceived,
      undefined,
      `labelHash=${shortHash(label)}`
    ));
    reporter?.onStep(DNS_LOOKUP_STEP_ID, outcome);
  }

  private async runHttpsProbe(
    command: ProbeCommand,
    records: Array<ProbeRecord>,
    failures: Array<ProbeFailure>,
    reporter?: ProbeProgressReporter
  ): Promise<void> {
    const startedAt: string = this.dependencies.clock.now();
    const url: string = buildHttpsUrl(command);
    const options: ProbeHttpRequestOptions = createHttpOptions(command);
    const expectedBody: ArrayBuffer = encodeUtf8(buildHttpsExpectedBody(command));
    try {
      const response: ProbeHttpResponse = await withTimeout(
        this.dependencies.httpDriver.request(url, options),
        'https-request',
        this.timeoutMs(),
        () => this.dependencies.httpDriver.abortCurrentRequest?.()
      );
      if (!isExactHttpsResponse(response, expectedBody)) {
        throw new Error('invalid-https-response');
      }
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        command.flowIds.https,
        HTTPS_STEP_ID,
        'lan-origin-direct',
        'pass',
        'https',
        command.lanOrigin.httpsPort,
        startedAt,
        this.dependencies.clock.now(),
        0,
        byteLength(expectedBody),
        response.statusCode,
        `pin=${shortHash(command.pinnedCertificateHash)}`
      ));
      reporter?.onStep(HTTPS_STEP_ID, 'pass');
    } catch (_) {
      failures.push(new ProbeFailure('HTTPS_DIRECT_FAILED', PROBE_FAILURE_DETAIL_HTTPS_FAILED));
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        command.flowIds.https,
        HTTPS_STEP_ID,
        'lan-origin-direct',
        'fail',
        'https',
        command.lanOrigin.httpsPort,
        startedAt,
        this.dependencies.clock.now(),
        0,
        0,
        undefined,
        `pin=${shortHash(command.pinnedCertificateHash)}`
      ));
      reporter?.onStep(HTTPS_STEP_ID, 'fail');
    }
  }

  private async runTcpProbe(
    command: ProbeCommand,
    addresses: OriginAddressSet,
    records: Array<ProbeRecord>,
    failures: Array<ProbeFailure>,
    reporter?: ProbeProgressReporter
  ): Promise<void> {
    const targetAddress: string = requireString(addresses.ipv4, 'Missing IPv4 origin address.');
    const connectOptions: ProbeTcpConnectOptions = createTcpConnectOptions(targetAddress, 1, command.lanOrigin.tcpPort);
    const payload: ArrayBuffer = encodeUtf8(buildTcpExpectedPayload(command));
    const startedAt: string = this.dependencies.clock.now();
    let connectionRef: TcpProbeConnection | undefined = undefined;
    try {
      connectionRef = await withTimeout(
        this.dependencies.tcpDriver.connect(connectOptions),
        'tcp-connect',
        this.timeoutMs(),
        async () => {
          await this.dependencies.tcpDriver.cancelPendingConnect?.();
        }
      );
      await withTimeout(connectionRef.send(payload), 'tcp-send', this.timeoutMs(), async () => {
        await connectionRef?.close();
      });
      const response: ArrayBuffer = await withTimeout(connectionRef.receive(), 'tcp-receive', this.timeoutMs(), async () => {
        connectionRef?.cancelReceiveWait?.();
        await connectionRef?.close();
      });
      if (!arrayBuffersEqual(response, payload)) {
        throw new Error('invalid-tcp-response');
      }
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        command.flowIds.tcp,
        TCP_STEP_ID,
        'lan-origin-direct',
        'pass',
        'tcp',
        command.lanOrigin.tcpPort,
        startedAt,
        this.dependencies.clock.now(),
        byteLength(payload),
        byteLength(response),
        undefined,
        undefined
      ));
      reporter?.onStep(TCP_STEP_ID, 'pass');
    } catch (_) {
      failures.push(new ProbeFailure('TCP_DIRECT_FAILED', PROBE_FAILURE_DETAIL_TCP_FAILED));
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        command.flowIds.tcp,
        TCP_STEP_ID,
        'lan-origin-direct',
        'fail',
        'tcp',
        command.lanOrigin.tcpPort,
        startedAt,
        this.dependencies.clock.now(),
        byteLength(payload),
        0,
        undefined,
        undefined
      ));
      reporter?.onStep(TCP_STEP_ID, 'fail');
    } finally {
      if (connectionRef !== undefined) {
        try {
          await connectionRef.close();
        } catch (_) {
        }
      }
    }
  }

  private async runUdpProbe(
    command: ProbeCommand,
    addresses: OriginAddressSet,
    ipv6: boolean,
    records: Array<ProbeRecord>,
    failures: Array<ProbeFailure>,
    reporter?: ProbeProgressReporter
  ): Promise<void> {
    const stepId: string = ipv6 ? UDP_IPV6_STEP_ID : UDP_IPV4_STEP_ID;
    const flowId: string = ipv6 ? command.flowIds.udpIpv6 : command.flowIds.udpIpv4;
    const targetAddress: string | undefined = ipv6 ? addresses.ipv6 : addresses.ipv4;
    if (targetAddress === undefined) {
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        flowId,
        stepId,
        'lan-origin-direct',
        'not-run',
        'udp',
        command.lanOrigin.udpPort,
        this.dependencies.clock.now(),
        this.dependencies.clock.now(),
        0,
        0,
        undefined,
        'capability-not-reported'
      ));
      reporter?.onStep(stepId, 'not-run');
      return;
    }

    const socketRef: UdpProbeSocket = this.dependencies.udpDriver.createSocket(ipv6 ? 'IPv6' : 'IPv4');
    const bindAddress: ProbeSocketAddress = new ProbeSocketAddress(ipv6 ? LOOPBACK_V6 : LOOPBACK_V4, ipv6 ? 2 : 1, 0);
    const sendOptions: ProbeUdpSendOptions = new ProbeUdpSendOptions();
    sendOptions.data = encodeUtf8(buildUdpExpectedPayload(command, flowId));
    sendOptions.address = new ProbeSocketAddress(targetAddress, ipv6 ? 2 : 1, command.lanOrigin.udpPort);
    const startedAt: string = this.dependencies.clock.now();
    try {
      await withTimeout(socketRef.bind(bindAddress), 'udp-bind', this.timeoutMs(), async () => {
        await socketRef.close();
      });
      await withTimeout(socketRef.send(sendOptions), 'udp-send', this.timeoutMs(), async () => {
        await socketRef.close();
      });
      const response: ProbeSocketMessage = await withTimeout(socketRef.receive(), 'udp-receive', this.timeoutMs(), async () => {
        socketRef.cancelReceiveWait?.();
        await socketRef.close();
      });
      if (!arrayBuffersEqual(response.message, sendOptions.data) ||
        response.remoteInfo.address !== targetAddress ||
        response.remoteInfo.port !== command.lanOrigin.udpPort) {
        throw new Error('invalid-udp-response');
      }
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        flowId,
        stepId,
        'lan-origin-direct',
        'pass',
        'udp',
        command.lanOrigin.udpPort,
        startedAt,
        this.dependencies.clock.now(),
        byteLength(sendOptions.data),
        byteLength(response.message),
        undefined,
        undefined
      ));
      reporter?.onStep(stepId, 'pass');
    } catch (_) {
      failures.push(new ProbeFailure(ipv6 ? 'UDP_IPV6_FAILED' : 'UDP_IPV4_FAILED', PROBE_FAILURE_DETAIL_UDP_FAILED));
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        flowId,
        stepId,
        'lan-origin-direct',
        'fail',
        'udp',
        command.lanOrigin.udpPort,
        startedAt,
        this.dependencies.clock.now(),
        byteLength(sendOptions.data),
        0,
        undefined,
        undefined
      ));
      reporter?.onStep(stepId, 'fail');
    } finally {
      try {
        await socketRef.close();
      } catch (_) {
      }
    }
  }

  private async runDnsPacketProbe(
    command: ProbeCommand,
    addresses: OriginAddressSet,
    ipv6: boolean,
    records: Array<ProbeRecord>,
    failures: Array<ProbeFailure>,
    reporter?: ProbeProgressReporter
  ): Promise<void> {
    const stepId: string = ipv6 ? DNS_PACKET_IPV6_STEP_ID : DNS_PACKET_IPV4_STEP_ID;
    const flowId: string = ipv6 ? command.flowIds.dnsPacketIpv6 : command.flowIds.dnsPacketIpv4;
    const targetAddress: string | undefined = ipv6 ? addresses.ipv6 : addresses.ipv4;
    if (targetAddress === undefined) {
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        flowId,
        stepId,
        'lan-origin-direct',
        'not-run',
        'dns-packet',
        command.lanOrigin.dnsPort,
        this.dependencies.clock.now(),
        this.dependencies.clock.now(),
        0,
        0,
        undefined,
        'capability-not-reported'
      ));
      reporter?.onStep(stepId, 'not-run');
      return;
    }

    const label: string = buildHashedInvalidLabel(command.runId, flowId);
    const packet: ArrayBuffer = buildDnsQueryPacket(label);
    const socketRef: UdpProbeSocket = this.dependencies.udpDriver.createSocket(ipv6 ? 'IPv6' : 'IPv4');
    const bindAddress: ProbeSocketAddress = new ProbeSocketAddress(ipv6 ? LOOPBACK_V6 : LOOPBACK_V4, ipv6 ? 2 : 1, 0);
    const sendOptions: ProbeUdpSendOptions = new ProbeUdpSendOptions();
    sendOptions.data = packet;
    sendOptions.address = new ProbeSocketAddress(targetAddress, ipv6 ? 2 : 1, command.lanOrigin.dnsPort);
    const startedAt: string = this.dependencies.clock.now();
    try {
      await withTimeout(socketRef.bind(bindAddress), 'dns-bind', this.timeoutMs(), async () => {
        await socketRef.close();
      });
      await withTimeout(socketRef.send(sendOptions), 'dns-send', this.timeoutMs(), async () => {
        await socketRef.close();
      });
      const response: ProbeSocketMessage = await withTimeout(socketRef.receive(), 'dns-receive', this.timeoutMs(), async () => {
        socketRef.cancelReceiveWait?.();
        await socketRef.close();
      });
      if (!arrayBuffersEqual(response.message, packet) ||
        response.remoteInfo.address !== targetAddress ||
        response.remoteInfo.port !== command.lanOrigin.dnsPort) {
        throw new Error('invalid-dns-response');
      }
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        flowId,
        stepId,
        'lan-origin-direct',
        'pass',
        'dns-shaped-udp-echo',
        command.lanOrigin.dnsPort,
        startedAt,
        this.dependencies.clock.now(),
        byteLength(packet),
        byteLength(response.message),
        undefined,
        `labelHash=${shortHash(label)}`
      ));
      reporter?.onStep(stepId, 'pass');
    } catch (_) {
      failures.push(new ProbeFailure(ipv6 ? 'DNS_PACKET_IPV6_FAILED' : 'DNS_PACKET_IPV4_FAILED', PROBE_FAILURE_DETAIL_DNS_PACKET_FAILED));
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        flowId,
        stepId,
        'lan-origin-direct',
        'fail',
        'dns-shaped-udp-echo',
        command.lanOrigin.dnsPort,
        startedAt,
        this.dependencies.clock.now(),
        byteLength(packet),
        0,
        undefined,
        `labelHash=${shortHash(label)}`
      ));
      reporter?.onStep(stepId, 'fail');
    } finally {
      try {
        await socketRef.close();
      } catch (_) {
      }
    }
  }

  private async runHttpConnectProbe(
    command: ProbeCommand,
    records: Array<ProbeRecord>,
    failures: Array<ProbeFailure>,
    reporter?: ProbeProgressReporter
  ): Promise<void> {
    const payload: ArrayBuffer = buildHttpConnectPayload(command);
    const connectOptions: ProbeTcpConnectOptions = createTcpConnectOptions(LOOPBACK_V4, 1, command.localListeners.httpConnectPort);
    const startedAt: string = this.dependencies.clock.now();
    let connectionRef: TcpProbeConnection | undefined = undefined;
    try {
      connectionRef = await withTimeout(
        this.dependencies.tcpDriver.connect(connectOptions),
        'http-connect-open',
        this.timeoutMs(),
        async () => {
          await this.dependencies.tcpDriver.cancelPendingConnect?.();
        }
      );
      await withTimeout(connectionRef.send(payload), 'http-connect-send', this.timeoutMs(), async () => {
        await connectionRef?.close();
      });
      const response: ArrayBuffer = await withTimeout(connectionRef.receive(), 'http-connect-receive', this.timeoutMs(), async () => {
        connectionRef?.cancelReceiveWait?.();
        await connectionRef?.close();
      });
      if (!isExactHttpConnectSuccess(response)) {
        throw new Error('invalid-http-connect-response');
      }
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        command.flowIds.httpConnect,
        HTTP_CONNECT_STEP_ID,
        'local-http-connect-listener',
        'pass',
        'tcp',
        command.localListeners.httpConnectPort,
        startedAt,
        this.dependencies.clock.now(),
        byteLength(payload),
        byteLength(response),
        undefined,
        undefined
      ));
      reporter?.onStep(HTTP_CONNECT_STEP_ID, 'pass');
    } catch (_) {
      failures.push(new ProbeFailure('HTTP_CONNECT_LISTENER_FAILED', PROBE_FAILURE_DETAIL_HTTP_CONNECT_FAILED));
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        command.flowIds.httpConnect,
        HTTP_CONNECT_STEP_ID,
        'local-http-connect-listener',
        'fail',
        'tcp',
        command.localListeners.httpConnectPort,
        startedAt,
        this.dependencies.clock.now(),
        byteLength(payload),
        0,
        undefined,
        undefined
      ));
      reporter?.onStep(HTTP_CONNECT_STEP_ID, 'fail');
    } finally {
      if (connectionRef !== undefined) {
        try {
          await connectionRef.close();
        } catch (_) {
        }
      }
    }
  }

  private async runSocks5Probe(
    command: ProbeCommand,
    addresses: OriginAddressSet,
    records: Array<ProbeRecord>,
    failures: Array<ProbeFailure>,
    reporter?: ProbeProgressReporter
  ): Promise<void> {
    const targetAddress: string = requireString(addresses.ipv4, 'Missing IPv4 origin address.');
    const connectOptions: ProbeTcpConnectOptions = createTcpConnectOptions(LOOPBACK_V4, 1, command.localListeners.socks5Port);
    const greeting: ArrayBuffer = buildSocks5Greeting();
    const request: ArrayBuffer = buildSocks5ConnectRequest(targetAddress, command.lanOrigin.tcpPort);
    const startedAt: string = this.dependencies.clock.now();
    let connectionRef: TcpProbeConnection | undefined = undefined;
    try {
      connectionRef = await withTimeout(
        this.dependencies.tcpDriver.connect(connectOptions),
        'socks-connect-open',
        this.timeoutMs(),
        async () => {
          await this.dependencies.tcpDriver.cancelPendingConnect?.();
        }
      );
      await withTimeout(connectionRef.send(greeting), 'socks-greeting-send', this.timeoutMs(), async () => {
        await connectionRef?.close();
      });
      const greetingResponse: ArrayBuffer = await withTimeout(connectionRef.receive(), 'socks-greeting-receive', this.timeoutMs(), async () => {
        connectionRef?.cancelReceiveWait?.();
        await connectionRef?.close();
      });
      if (!isExactSocks5GreetingSuccess(greetingResponse)) {
        throw new Error('invalid-socks-greeting');
      }
      await withTimeout(connectionRef.send(request), 'socks-connect-send', this.timeoutMs(), async () => {
        await connectionRef?.close();
      });
      const connectResponse: ArrayBuffer = await withTimeout(connectionRef.receive(), 'socks-connect-receive', this.timeoutMs(), async () => {
        connectionRef?.cancelReceiveWait?.();
        await connectionRef?.close();
      });
      if (!isExactSocks5ConnectSuccess(connectResponse)) {
        throw new Error('invalid-socks-connect');
      }
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        command.flowIds.socks5,
        SOCKS5_STEP_ID,
        'local-socks5-listener',
        'pass',
        'tcp',
        command.localListeners.socks5Port,
        startedAt,
        this.dependencies.clock.now(),
        byteLength(greeting) + byteLength(request),
        byteLength(greetingResponse) + byteLength(connectResponse),
        undefined,
        undefined
      ));
      reporter?.onStep(SOCKS5_STEP_ID, 'pass');
    } catch (_) {
      failures.push(new ProbeFailure('SOCKS5_LISTENER_FAILED', PROBE_FAILURE_DETAIL_SOCKS5_FAILED));
      records.push(new ProbeRecord(
        command.runId,
        command.sessionId,
        command.flowIds.socks5,
        SOCKS5_STEP_ID,
        'local-socks5-listener',
        'fail',
        'tcp',
        command.localListeners.socks5Port,
        startedAt,
        this.dependencies.clock.now(),
        byteLength(greeting) + byteLength(request),
        0,
        undefined,
        undefined
      ));
      reporter?.onStep(SOCKS5_STEP_ID, 'fail');
    } finally {
      if (connectionRef !== undefined) {
        try {
          await connectionRef.close();
        } catch (_) {
        }
      }
    }
  }

  private async resolveOriginAddresses(host: string): Promise<OriginAddressSet> {
    const addresses: OriginAddressSet = new OriginAddressSet();
    if (isIpv4Literal(host)) {
      addresses.ipv4 = host;
      return addresses;
    }
    if (isIpv6Literal(host)) {
      addresses.ipv6 = host;
      return addresses;
    }
    const resolved: Array<ProbeDnsAddress> = await withTimeout(
      this.dependencies.dnsDriver.getAddressesByName(host),
      'origin-resolve',
      this.timeoutMs()
    );
    for (let index = 0; index < resolved.length; index += 1) {
      const next: ProbeDnsAddress = resolved[index];
      if (next.family === 1 && addresses.ipv4 === undefined) {
        addresses.ipv4 = next.address;
      }
      if (next.family === 2 && addresses.ipv6 === undefined) {
        addresses.ipv6 = next.address;
      }
    }
    return addresses;
  }

  private timeoutMs(): number {
    return this.dependencies.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }
}

export class HarmonyProbeClock implements ProbeClock {
  now(): string {
    return new Date().toISOString();
  }
}

export class HarmonyProbeFileDriver implements ProbeFileDriver {
  async writeAtomic(path: string, content: string): Promise<void> {
    const tempPath: string = `${path}.${Date.now()}.tmp`;
    const file: fileIo.File = fileIo.openSync(
      tempPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, content);
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file.fd);
    }
    try {
      fileIo.renameSync(tempPath, path);
    } catch (_) {
      try {
        fileIo.unlinkSync(tempPath);
      } catch (_) {
      }
      throw new Error('Failed to atomically publish probe evidence.');
    }
  }
}

class HttpRequestOptionsRecord implements http.HttpRequestOptions {
  method?: http.RequestMethod = http.RequestMethod.GET;
  expectDataType?: http.HttpDataType = http.HttpDataType.ARRAY_BUFFER;
  usingCache?: boolean = false;
  connectTimeout?: number = DEFAULT_TIMEOUT_MS;
  readTimeout?: number = DEFAULT_TIMEOUT_MS;
  maxLimit?: number = 4_096;
  maxRedirects?: number = 0;
  header?: Object = new HttpHeaderRecord();
  certificatePinning?: http.CertificatePinning = new HttpCertificatePinningRecord('');
}

class HttpCertificatePinningRecord implements http.CertificatePinning {
  publicKeyHash: string;
  hashAlgorithm: 'SHA-256' = 'SHA-256';

  constructor(publicKeyHash: string) {
    this.publicKeyHash = publicKeyHash;
  }
}

class HttpHeaderRecord {
  XCMFAProbeRunId: string = '';
  XCMFAProbeSessionId: string = '';
  XCMFAProbeFlowId: string = '';
}

export class HarmonyHttpProbeDriver implements HttpProbeDriver {
  private currentRequest?: http.HttpRequest;

  async request(url: string, options: ProbeHttpRequestOptions): Promise<ProbeHttpResponse> {
    const client: http.HttpRequest = http.createHttp();
    this.currentRequest = client;
    const requestOptions: HttpRequestOptionsRecord = new HttpRequestOptionsRecord();
    requestOptions.connectTimeout = options.connectTimeout;
    requestOptions.readTimeout = options.readTimeout;
    requestOptions.maxLimit = options.maxLimit;
    requestOptions.maxRedirects = options.maxRedirects;
    const headerRecord: HttpHeaderRecord = new HttpHeaderRecord();
    headerRecord.XCMFAProbeRunId = options.headers.runIdHeader;
    headerRecord.XCMFAProbeSessionId = options.headers.sessionIdHeader;
    headerRecord.XCMFAProbeFlowId = options.headers.flowIdHeader;
    requestOptions.header = headerRecord;
    requestOptions.certificatePinning = new HttpCertificatePinningRecord(options.certificatePinning.publicKeyHash);
    try {
      const response: http.HttpResponse = await client.request(url, requestOptions);
      const normalized: ProbeHttpResponse = new ProbeHttpResponse();
      normalized.statusCode = response.responseCode as number;
      normalized.body = normalizeHttpResponseBody(response.result);
      return normalized;
    } finally {
      this.currentRequest = undefined;
      try {
        client.destroy();
      } catch (_) {
      }
    }
  }

  abortCurrentRequest(): void {
    try {
      this.currentRequest?.destroy();
    } catch (_) {
    }
  }
}

class HarmonyTcpProbeConnection implements TcpProbeConnection {
  private readonly socketRef: socket.TCPSocket;
  private pendingWaiter?: PendingSocketWaiter;

  constructor(socketRef: socket.TCPSocket) {
    this.socketRef = socketRef;
  }

  async send(data: ArrayBuffer): Promise<void> {
    await this.socketRef.send(createTcpSendOptions(data));
  }

  async receive(): Promise<ArrayBuffer> {
    const waiter: PendingSocketWaiter = waitForTcpMessage(this.socketRef);
    this.pendingWaiter = waiter;
    const event: ProbeSocketMessage = await waiter.promise;
    this.pendingWaiter = undefined;
    return event.message;
  }

  async close(): Promise<void> {
    this.pendingWaiter?.cancel();
    this.pendingWaiter = undefined;
    await this.socketRef.close();
  }

  cancelReceiveWait(): void {
    this.pendingWaiter?.cancel();
    this.pendingWaiter = undefined;
  }
}

export class HarmonyTcpProbeDriver implements TcpProbeDriver {
  private pendingSocket?: socket.TCPSocket;

  async connect(options: ProbeTcpConnectOptions): Promise<TcpProbeConnection> {
    const tcpSocket: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.pendingSocket = tcpSocket;
    try {
      await tcpSocket.connect(options);
      this.pendingSocket = undefined;
      return new HarmonyTcpProbeConnection(tcpSocket);
    } catch (_) {
      this.pendingSocket = undefined;
      try {
        await tcpSocket.close();
      } catch (_) {
      }
      throw new Error('TCP connect failed.');
    }
  }

  async cancelPendingConnect(): Promise<void> {
    const pendingSocket: socket.TCPSocket | undefined = this.pendingSocket;
    this.pendingSocket = undefined;
    if (pendingSocket === undefined) {
      return;
    }
    try {
      await pendingSocket.close();
    } catch (_) {
    }
  }
}

class HarmonyUdpProbeSocket implements UdpProbeSocket {
  private readonly socketRef: socket.UDPSocket;
  private pendingWaiter?: PendingSocketWaiter;

  constructor(socketRef: socket.UDPSocket) {
    this.socketRef = socketRef;
  }

  async bind(address: ProbeSocketAddress): Promise<void> {
    await this.socketRef.bind(address);
  }

  async send(options: ProbeUdpSendOptions): Promise<void> {
    await this.socketRef.send(options);
  }

  async receive(): Promise<ProbeSocketMessage> {
    const waiter: PendingSocketWaiter = waitForUdpMessage(this.socketRef);
    this.pendingWaiter = waiter;
    const event: ProbeSocketMessage = await waiter.promise;
    this.pendingWaiter = undefined;
    return event;
  }

  async close(): Promise<void> {
    this.pendingWaiter?.cancel();
    this.pendingWaiter = undefined;
    await this.socketRef.close();
  }

  cancelReceiveWait(): void {
    this.pendingWaiter?.cancel();
    this.pendingWaiter = undefined;
  }
}

export class HarmonyUdpProbeDriver implements UdpProbeDriver {
  createSocket(_family: 'IPv4' | 'IPv6'): UdpProbeSocket {
    return new HarmonyUdpProbeSocket(socket.constructUDPSocketInstance());
  }
}

export class HarmonyDnsProbeDriver implements DnsProbeDriver {
  private readonly socketFactory: ProbeSocketFactory;

  constructor(socketFactory?: ProbeSocketFactory) {
    this.socketFactory = socketFactory ?? (() => new HarmonyUdpProbeSocket(socket.constructUDPSocketInstance()));
  }

  async getAddressesByName(host: string): Promise<Array<ProbeDnsAddress>> {
    const resolved: Array<connection.NetAddress> = await connection.getAddressesByName(host);
    const normalized: Array<ProbeDnsAddress> = [];
    for (let index = 0; index < resolved.length; index += 1) {
      const next: connection.NetAddress = resolved[index];
      normalized.push(new ProbeDnsAddress(next.address, next.family ?? 1, next.port ?? 0));
    }
    return normalized;
  }

  async isIpv6Available(): Promise<boolean> {
    let socketRef: UdpProbeSocket | undefined = undefined;
    try {
      socketRef = this.socketFactory();
      await withTimeout(socketRef.bind(new ProbeSocketAddress(LOOPBACK_V6, 2, 0)), 'ipv6-capability-bind', DEFAULT_TIMEOUT_MS, async () => {
        await socketRef?.close();
      });
      return true;
    } catch (_) {
      return false;
    } finally {
      if (socketRef !== undefined) {
        try {
          await socketRef.close();
        } catch (_) {
        }
      }
    }
  }
}

export class ProbeRuntimeFactory {
  static createDefault(_context: common.UIAbilityContext): DirectTrafficProbe {
    return new DirectTrafficProbe({
      httpDriver: new HarmonyHttpProbeDriver(),
      tcpDriver: new HarmonyTcpProbeDriver(),
      udpDriver: new HarmonyUdpProbeDriver(),
      dnsDriver: new HarmonyDnsProbeDriver(),
      clock: new HarmonyProbeClock(),
      fileDriver: new HarmonyProbeFileDriver()
    });
  }

  static createReporter(pageState: ProbePageState): ProbeProgressReporter {
    return new ProbePublishReporter(pageState);
  }
}

function withTimeout<T>(
  promise: Promise<T>,
  label: string,
  timeoutMs: number,
  onTimeout?: () => void | Promise<void>
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let settled: boolean = false;
    const timer: number = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      void Promise.resolve(onTimeout?.()).finally(() => {
        reject(new Error(`${label} timed out.`));
      });
    }, timeoutMs);

    void promise.then((value) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(value);
    }).catch(() => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      reject(new Error(`${label} failed.`));
    });
  });
}

function createHttpOptions(command: ProbeCommand): ProbeHttpRequestOptions {
  const headers: ProbeHttpHeaders = new ProbeHttpHeaders();
  headers.runIdHeader = clampEvidenceString(command.runId, 128);
  headers.sessionIdHeader = clampEvidenceString(command.sessionId, 128);
  headers.flowIdHeader = clampEvidenceString(command.flowIds.https, 128);

  const pinning: ProbeCertificatePinning = new ProbeCertificatePinning();
  pinning.publicKeyHash = command.pinnedCertificateHash;

  const options: ProbeHttpRequestOptions = new ProbeHttpRequestOptions();
  options.connectTimeout = DEFAULT_TIMEOUT_MS;
  options.readTimeout = DEFAULT_TIMEOUT_MS;
  options.maxLimit = 4_096;
  options.maxRedirects = 0;
  options.usingCache = false;
  options.expectDataType = 'ARRAY_BUFFER';
  options.headers = headers;
  options.certificatePinning = pinning;
  return options;
}

function createTcpConnectOptions(address: string, family: number, port: number): ProbeTcpConnectOptions {
  if (family === 1 && !isValidIpv4Literal(address)) {
    throw new Error('Invalid IPv4 origin address.');
  }
  const options: ProbeTcpConnectOptions = new ProbeTcpConnectOptions();
  options.address = new ProbeSocketAddress(address, family, port);
  options.timeout = DEFAULT_TIMEOUT_MS;
  return options;
}

function createTcpSendOptions(data: ArrayBuffer): socket.TCPSendOptions {
  return { data };
}

function buildHttpsUrl(command: ProbeCommand): string {
  return `https://${command.lanOrigin.host}:${command.lanOrigin.httpsPort}/probe/${shortHash(command.runId)}?sid=${shortHash(command.sessionId)}`;
}

export function buildHttpsExpectedBody(command: ProbeCommand): string {
  return buildCorrelationToken('HTTPS', command.runId, command.sessionId, command.flowIds.https);
}

export function buildTcpExpectedPayload(command: ProbeCommand): string {
  return buildCorrelationToken('TCP', command.runId, command.sessionId, command.flowIds.tcp);
}

export function buildUdpExpectedPayload(command: ProbeCommand, flowId: string): string {
  return buildCorrelationToken('UDP', command.runId, command.sessionId, flowId);
}

function buildHttpConnectPayload(command: ProbeCommand): ArrayBuffer {
  const authority: string = `${command.lanOrigin.host}:${command.lanOrigin.tcpPort}`;
  return encodeUtf8(
    `CONNECT ${authority} HTTP/1.1\r\nHost: ${authority}\r\nX-Run-Id: ${command.runId}\r\nX-Session-Id: ${command.sessionId}\r\nX-Flow-Id: ${command.flowIds.httpConnect}\r\n\r\n`
  );
}

export function buildHashedInvalidLabel(left: string, right: string): string {
  return `${shortHash(left)}-${shortHash(right)}.invalid`;
}

export function buildDnsQueryPacket(label: string): ArrayBuffer {
  const header: Array<number> = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
  const bytes: Array<number> = [];
  const segments: Array<string> = label.split('.');
  for (let index = 0; index < segments.length; index += 1) {
    const next: string = segments[index];
    bytes.push(next.length);
    for (let charIndex = 0; charIndex < next.length; charIndex += 1) {
      bytes.push(next.charCodeAt(charIndex) & 0xff);
    }
  }
  bytes.push(0x00, 0x00, 0x01, 0x00, 0x01);
  return new Uint8Array(header.concat(bytes)).buffer;
}

function buildSocks5ConnectRequest(ipv4: string, port: number): ArrayBuffer {
  const octets: Array<string> = ipv4.split('.');
  const bytes: Array<number> = [0x05, 0x01, 0x00, 0x01];
  for (let index = 0; index < 4; index += 1) {
    const parsed: number = Number(octets[index]);
    if (!Number.isInteger(parsed) || parsed < 0 || parsed > 255) {
      throw new Error('Invalid IPv4 origin address.');
    }
    bytes.push(parsed);
  }
  bytes.push((port >> 8) & 0xff, port & 0xff);
  return new Uint8Array(bytes).buffer;
}

function buildSocks5Greeting(): ArrayBuffer {
  const bytes: Array<number> = [];
  bytes.push(0x05, 0x01, 0x00);
  return new Uint8Array(bytes).buffer;
}

function ensureUniqueFlowIds(flowIds: ProbeFlowIdSet): void {
  const seen: Set<string> = new Set();
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
  for (let index = 0; index < values.length; index += 1) {
    const next: string = values[index];
    if (next.length === 0 || seen.has(next)) {
      throw new Error('Flow IDs must be unique and opaque.');
    }
    seen.add(next);
  }
}

function normalizeHttpResponseBody(body: string | Object | ArrayBuffer): ArrayBuffer {
  if (body instanceof ArrayBuffer) {
    return body;
  }
  if (typeof body === 'string') {
    return encodeUtf8(body);
  }
  throw new Error('Unsupported HTTP response body.');
}

function encodeUtf8(value: string): ArrayBuffer {
  const bytes: Array<number> = [];
  for (let index = 0; index < value.length; index += 1) {
    const codePoint: number = value.charCodeAt(index);
    if (codePoint <= 0x7f) {
      bytes.push(codePoint);
      continue;
    }
    if (codePoint <= 0x7ff) {
      bytes.push(0xc0 | (codePoint >> 6));
      bytes.push(0x80 | (codePoint & 0x3f));
      continue;
    }
    bytes.push(0xe0 | (codePoint >> 12));
    bytes.push(0x80 | ((codePoint >> 6) & 0x3f));
    bytes.push(0x80 | (codePoint & 0x3f));
  }
  return new Uint8Array(bytes).buffer;
}

function byteLength(buffer: ArrayBuffer): number {
  return new Uint8Array(buffer).byteLength;
}

function shortHash(value: string): string {
  let hashValue: number = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hashValue ^= value.charCodeAt(index);
    hashValue = Math.imul(hashValue, 16777619);
  }
  return (hashValue >>> 0).toString(16).padStart(8, '0');
}

function sanitizeError(error: Object | undefined): string {
  if (error instanceof Error) {
    return sanitizeText(error.message);
  }
  return 'probe-error';
}

function sanitizeText(raw: string): string {
  let sanitized: string = raw;
  sanitized = sanitized.replace(/https?:\/\/\S+/gu, '__URL__');
  sanitized = sanitized.replace(/[A-Za-z0-9._-]+\.invalid/gu, '__INVALID__');
  sanitized = sanitized.replace(/\/Users\/[^\s]+/gu, '__PATH__');
  sanitized = sanitized.replace(/[A-Za-z]:\\Users\\[^\\\s]+/gu, '__PATH__');
  sanitized = sanitized.replace(/([Pp]assword|[Ss]ecret|[Tt]oken)=\S+/gu, '$1=__REDACTED__');
  return sanitized;
}

export function boundEvidenceJson(evidence: ProbeEvidence): string {
  const serialized: string = `${JSON.stringify(evidence)}\n`;
  if (serialized.length <= MAX_EVIDENCE_LENGTH) {
    return serialized;
  }
  const trimmed: ProbeEvidence = new ProbeEvidence(
    evidence.version,
    evidence.result,
    evidence.runId,
    evidence.sessionId,
    evidence.startedAt,
    evidence.completedAt,
    evidence.records.slice(0, 6),
    evidence.failures.slice(0, 4)
  );
  const trimmedSerialized: string = `${JSON.stringify(trimmed)}\n`;
  if (trimmedSerialized.length <= MAX_EVIDENCE_LENGTH) {
    return trimmedSerialized;
  }
  const minimal: ProbeEvidence = new ProbeEvidence(
    clampEvidenceString(evidence.version, 16),
    clampEvidenceString(evidence.result, 8),
    clampEvidenceString(evidence.runId, 64),
    clampEvidenceString(evidence.sessionId, 64),
    clampEvidenceString(evidence.startedAt, 32),
    clampEvidenceString(evidence.completedAt, 32),
    [],
    []
  );
  return `${JSON.stringify(minimal)}\n`;
}

function isIpv4Literal(value: string): boolean {
  return isValidIpv4Literal(value);
}

function isIpv6Literal(value: string): boolean {
  return value.includes(':');
}

function requireString(value: string | undefined, message: string): string {
  if (value === undefined || value.length === 0) {
    throw new Error(message);
  }
  return value;
}

function waitForTcpMessage(targetSocket: socket.TCPSocket): PendingSocketWaiter {
  let settled: boolean = false;
  let timer: number = -1;
  let onMessageRef: ((info: socket.SocketMessageInfo) => void) | undefined = undefined;
  let onErrorRef: ((error: Error) => void) | undefined = undefined;
  const cleanup = (): void => {
    clearTimeout(timer);
    if (onMessageRef !== undefined) {
      try {
        targetSocket.off('message', onMessageRef);
      } catch (_) {
      }
    }
    if (onErrorRef !== undefined) {
      try {
        targetSocket.off('error', onErrorRef);
      } catch (_) {
      }
    }
  };

  const promise: Promise<ProbeSocketMessage> = new Promise<ProbeSocketMessage>((resolve, reject) => {
    timer = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(new Error('socket timeout'));
    }, DEFAULT_TIMEOUT_MS);
    onMessageRef = (info: socket.SocketMessageInfo): void => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      resolve(normalizeSocketMessage(info));
    };
    onErrorRef = (_error: Error): void => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(new Error('socket timeout'));
    };

    targetSocket.on('message', onMessageRef);
    targetSocket.on('error', onErrorRef);
  });

  return new PendingSocketWaiter(promise, () => {
    if (settled) {
      return;
    }
    settled = true;
    cleanup();
  });
}

function waitForUdpMessage(targetSocket: socket.UDPSocket): PendingSocketWaiter {
  let settled: boolean = false;
  let timer: number = -1;
  let onMessageRef: ((info: socket.SocketMessageInfo) => void) | undefined = undefined;
  let onErrorRef: ((error: Error) => void) | undefined = undefined;
  const cleanup = (): void => {
    clearTimeout(timer);
    if (onMessageRef !== undefined) {
      try {
        targetSocket.off('message', onMessageRef);
      } catch (_) {
      }
    }
    if (onErrorRef !== undefined) {
      try {
        targetSocket.off('error', onErrorRef);
      } catch (_) {
      }
    }
  };

  const promise: Promise<ProbeSocketMessage> = new Promise<ProbeSocketMessage>((resolve, reject) => {
    timer = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(new Error('socket timeout'));
    }, DEFAULT_TIMEOUT_MS);
    onMessageRef = (info: socket.SocketMessageInfo): void => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      resolve(normalizeSocketMessage(info));
    };
    onErrorRef = (_error: Error): void => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(new Error('socket timeout'));
    };

    targetSocket.on('message', onMessageRef);
    targetSocket.on('error', onErrorRef);
  });

  return new PendingSocketWaiter(promise, () => {
    if (settled) {
      return;
    }
    settled = true;
    cleanup();
  });
}

function normalizeSocketMessage(info: socket.SocketMessageInfo): ProbeSocketMessage {
  const remoteInfo: ProbeRemoteInfo = new ProbeRemoteInfo();
  remoteInfo.address = info.remoteInfo.address;
  remoteInfo.family = info.remoteInfo.family;
  remoteInfo.port = info.remoteInfo.port;
  remoteInfo.size = info.remoteInfo.size;

  const message: ProbeSocketMessage = new ProbeSocketMessage();
  message.message = info.message;
  message.remoteInfo = remoteInfo;
  return message;
}

function isExactHttpsResponse(response: ProbeHttpResponse, expectedBody: ArrayBuffer): boolean {
  return response.statusCode === 200 && arrayBuffersEqual(response.body, expectedBody);
}

function isExactHttpConnectSuccess(response: ArrayBuffer): boolean {
  const text: string = decodeAscii(response);
  return /^HTTP\/1\.[01] 200 /u.test(text);
}

function isExactSocks5GreetingSuccess(response: ArrayBuffer): boolean {
  const view: Uint8Array = new Uint8Array(response);
  return view.length === 2 && view[0] === 0x05 && view[1] === 0x00;
}

function isExactSocks5ConnectSuccess(response: ArrayBuffer): boolean {
  const view: Uint8Array = new Uint8Array(response);
  if (view.length < 5 || view[0] !== 0x05 || view[1] !== 0x00 || view[2] !== 0x00) {
    return false;
  }
  const atyp: number = view[3];
  if (atyp === 0x01) {
    return view.length >= 10;
  }
  if (atyp === 0x04) {
    return view.length >= 22;
  }
  if (atyp === 0x03) {
    const hostLength: number = view[4];
    return view.length >= 7 + hostLength;
  }
  return false;
}

function arrayBuffersEqual(left: ArrayBuffer, right: ArrayBuffer): boolean {
  const leftView: Uint8Array = new Uint8Array(left);
  const rightView: Uint8Array = new Uint8Array(right);
  if (leftView.length !== rightView.length) {
    return false;
  }
  for (let index = 0; index < leftView.length; index += 1) {
    if (leftView[index] !== rightView[index]) {
      return false;
    }
  }
  return true;
}

function decodeAscii(buffer: ArrayBuffer): string {
  const view: Uint8Array = new Uint8Array(buffer);
  let result: string = '';
  for (let index = 0; index < view.length; index += 1) {
    result += String.fromCharCode(view[index]);
  }
  return result;
}
