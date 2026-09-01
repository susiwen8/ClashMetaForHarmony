import { describe, expect, it } from '@ohos/hypium';
import type {
  DnsProbeDriver,
  HttpProbeDriver,
  DirectTrafficProbeDependencies,
  ProbeClock,
  ProbeFileDriver,
  TcpProbeConnection,
  TcpProbeDriver,
  UdpProbeDriver,
  UdpProbeSocket
} from '../main/ets/probe/DirectTrafficProbe';
import {
  buildDnsQueryPacket,
  buildHashedInvalidLabel,
  buildHttpsExpectedBody,
  buildTcpExpectedPayload,
  buildUdpExpectedPayload,
  boundEvidenceJson,
  DirectTrafficProbe,
  HarmonyDnsProbeDriver
} from '../main/ets/probe/DirectTrafficProbe';
import {
  NativeSocketProbeResult,
  createDefaultNativeSocketProbePort
} from '../main/ets/probe/NativeSocketProbe';
import type {
  NativeSocketProbeKnownFailureCode,
  NativeSocketProbeKind,
  NativeSocketProbePort
} from '../main/ets/probe/NativeSocketProbe';
import {
  ProbeCommand,
  ProbeDnsAddress,
  ProbeEvidence,
  ProbeExternalOriginConfig,
  ProbeFailure,
  ProbeFileWriteRecord,
  ProbeFlowIdSet,
  ProbeHttpRequestOptions,
  ProbeHttpResponse,
  ProbeLocalListenerConfig,
  ProbeOriginConfig,
  ProbeRecord,
  ProbeRemoteInfo,
  ProbeSocketAddress,
  ProbeSocketMessage,
  ProbeTcpConnectOptions,
  ProbeUdpSendOptions,
  formatTerminalOutcome,
  isCompleteProbeCommand
} from '../main/ets/probe/ProbeModels';

function createStringBuffer(value: string): ArrayBuffer {
  const bytes: Uint8Array = new Uint8Array(value.length);
  for (let index = 0; index < value.length; index += 1) {
    bytes[index] = value.charCodeAt(index) & 0xff;
  }
  return bytes.buffer;
}

function decodeStringBuffer(buffer: ArrayBuffer): string {
  const bytes: Uint8Array = new Uint8Array(buffer);
  let value: string = '';
  for (let index = 0; index < bytes.length; index += 1) {
    value += String.fromCharCode(bytes[index]);
  }
  return value;
}

function cloneBuffer(buffer: ArrayBuffer): ArrayBuffer {
  return buffer.slice(0);
}

class FakeClock implements ProbeClock {
  private readonly values: Array<string>;
  private index: number = 0;

  constructor(values: Array<string>) {
    this.values = values.slice();
  }

  now(): string {
    const currentIndex: number = this.index < this.values.length ? this.index : this.values.length - 1;
    this.index += 1;
    return this.values[currentIndex];
  }
}

class FakeFileDriver implements ProbeFileDriver {
  writes: Array<ProbeFileWriteRecord> = [];

  async writeAtomic(path: string, content: string): Promise<void> {
    this.writes.push(new ProbeFileWriteRecord(path, content));
  }
}

class InvalidNativeSocketProbeShape {
  outcome: string = 'weird';
  bytesSent: number = -1;
  bytesReceived: number = -1;
  durationMs: number = -1;
  failureCode?: string = 'INVALID';
}

class ValidNativeSocketProbePassShape {
  outcome: string = 'pass';
  bytesSent: number = 0;
  bytesReceived: number = 0;
  durationMs: number = 0;
}

class ExtraNativeSocketProbeShape extends InvalidNativeSocketProbeShape {
  extraField: string = 'extra';
}

class InheritedOutcomeBase {
  get outcome(): string {
    return 'pass';
  }
}

class InheritedOutcomeShape extends InheritedOutcomeBase {
  bytesSent: number;
  bytesReceived: number;
  durationMs: number;

  constructor(expectedPayloadBytes: number) {
    super();
    this.bytesSent = expectedPayloadBytes;
    this.bytesReceived = expectedPayloadBytes;
    this.durationMs = 1;
  }
}

class ThrowingSliceArrayBuffer {
  slice(_start: number, _end?: number): ArrayBuffer {
    throw new Error('payload slice failed EINVAL payload-marker.invalid');
  }
}

class NativeProbeCall {
  kind: NativeSocketProbeKind;
  hostIpv4: string;
  port: number;
  payload: ArrayBuffer;
  timeoutMs: number;

  constructor(kind: NativeSocketProbeKind, hostIpv4: string, port: number, payload: ArrayBuffer, timeoutMs: number) {
    this.kind = kind;
    this.hostIpv4 = hostIpv4;
    this.port = port;
    this.payload = cloneBuffer(payload);
    this.timeoutMs = timeoutMs;
  }
}

class FakeNativeSocketProbePort implements NativeSocketProbePort {
  readonly calls: Array<NativeProbeCall> = [];
  readonly responses: Array<NativeSocketProbeResult | InvalidNativeSocketProbeShape | Error> = [];

  async probe(
    kind: NativeSocketProbeKind,
    hostIpv4: string,
    port: number,
    payload: ArrayBuffer,
    timeoutMs: number
  ): Promise<NativeSocketProbeResult> {
    this.calls.push(new NativeProbeCall(kind, hostIpv4, port, payload, timeoutMs));
    const next: NativeSocketProbeResult | InvalidNativeSocketProbeShape | Error | undefined = this.responses.shift();
    if (next instanceof Error) {
      throw next;
    }
    if (next !== undefined) {
      return next as NativeSocketProbeResult;
    }
    const bytes: number = new Uint8Array(payload).byteLength;
    const result: NativeSocketProbeResult = new NativeSocketProbeResult();
    result.outcome = 'pass';
    result.bytesSent = bytes;
    result.bytesReceived = bytes;
    result.durationMs = 1;
    return result;
  }
}

class ProbeHttpCall {
  url: string;
  options: ProbeHttpRequestOptions;

  constructor(url: string, options: ProbeHttpRequestOptions) {
    this.url = url;
    this.options = options;
  }
}

class FakeHttpDriver implements HttpProbeDriver {
  readonly calls: Array<ProbeHttpCall> = [];
  responseStatusCode: number = 200;
  responseBody: ArrayBuffer = createStringBuffer('');
  hangRequest: boolean = false;
  abortCalls: number = 0;

  async request(url: string, options: ProbeHttpRequestOptions): Promise<ProbeHttpResponse> {
    this.calls.push(new ProbeHttpCall(url, options));
    if (this.hangRequest) {
      return await new Promise<ProbeHttpResponse>(() => {
      });
    }
    const response: ProbeHttpResponse = new ProbeHttpResponse();
    response.statusCode = this.responseStatusCode;
    response.body = this.responseBody;
    return response;
  }

  abortCurrentRequest(): void {
    this.abortCalls += 1;
  }
}

class FakeTcpConnection implements TcpProbeConnection {
  readonly sent: Array<ArrayBuffer> = [];
  readonly closeCalls: Array<number> = [];
  readonly receiveQueue: Array<ArrayBuffer>;
  hangReceive: boolean = false;
  hangSend: boolean = false;
  cancelReceiveCalls: number = 0;

  constructor(receiveQueue: Array<ArrayBuffer>) {
    this.receiveQueue = receiveQueue.slice();
  }

  async send(data: ArrayBuffer): Promise<void> {
    if (this.hangSend) {
      return await new Promise<void>(() => {
      });
    }
    this.sent.push(data);
  }

  async receive(): Promise<ArrayBuffer> {
    if (this.hangReceive) {
      return await new Promise<ArrayBuffer>(() => {
      });
    }
    return this.receiveQueue.shift() ?? createStringBuffer('');
  }

  async close(): Promise<void> {
    this.closeCalls.push(this.sent.length);
  }

  cancelReceiveWait(): void {
    this.cancelReceiveCalls += 1;
  }
}

class FakeTcpDriver implements TcpProbeDriver {
  readonly connects: Array<ProbeTcpConnectOptions> = [];
  readonly deliveredConnections: Array<FakeTcpConnection> = [];
  private readonly connections: Array<FakeTcpConnection>;
  hangConnect: boolean = false;
  cancelPendingConnectCalls: number = 0;
  pendingConnectCancelled: boolean = false;

  constructor(connections: Array<FakeTcpConnection>) {
    this.connections = connections.slice();
  }

  async connect(options: ProbeTcpConnectOptions): Promise<TcpProbeConnection> {
    this.connects.push(options);
    if (this.hangConnect) {
      return await new Promise<TcpProbeConnection>(() => {
      });
    }
    const connection: FakeTcpConnection = this.connections.shift() ?? new FakeTcpConnection([]);
    this.deliveredConnections.push(connection);
    return connection;
  }

  async cancelPendingConnect(): Promise<void> {
    this.cancelPendingConnectCalls += 1;
    this.pendingConnectCancelled = true;
  }
}

class FakeUdpSocket implements UdpProbeSocket {
  readonly family: 'IPv4' | 'IPv6';
  readonly binds: Array<ProbeSocketAddress> = [];
  readonly sends: Array<ProbeUdpSendOptions> = [];
  readonly closeCalls: Array<number> = [];
  private readonly receiveQueue: Array<ProbeSocketMessage>;
  hangReceive: boolean = false;
  hangBind: boolean = false;
  hangSend: boolean = false;
  cancelReceiveCalls: number = 0;

  constructor(family: 'IPv4' | 'IPv6', receiveQueue: Array<ProbeSocketMessage>) {
    this.family = family;
    this.receiveQueue = receiveQueue.slice();
  }

  async bind(address: ProbeSocketAddress): Promise<void> {
    if (this.hangBind) {
      return await new Promise<void>(() => {
      });
    }
    this.binds.push(address);
  }

  async send(options: ProbeUdpSendOptions): Promise<void> {
    if (this.hangSend) {
      return await new Promise<void>(() => {
      });
    }
    this.sends.push(options);
  }

  async receive(): Promise<ProbeSocketMessage> {
    if (this.hangReceive) {
      return await new Promise<ProbeSocketMessage>(() => {
      });
    }
    return this.receiveQueue.shift() ?? createSocketMessage(this.family === 'IPv6' ? 'fd00::10' : '192.168.1.10', this.family, 5353, '');
  }

  async close(): Promise<void> {
    this.closeCalls.push(this.sends.length);
  }

  cancelReceiveWait(): void {
    this.cancelReceiveCalls += 1;
  }
}

class FakeUdpDriver implements UdpProbeDriver {
  readonly requests: Array<string> = [];
  readonly createdSockets: Array<FakeUdpSocket> = [];
  private readonly sockets: Array<FakeUdpSocket>;

  constructor(sockets: Array<FakeUdpSocket>) {
    this.sockets = sockets.slice();
  }

  createSocket(family: 'IPv4' | 'IPv6'): UdpProbeSocket {
    this.requests.push(family);
    const created: FakeUdpSocket = this.sockets.shift() ?? new FakeUdpSocket(family, []);
    this.createdSockets.push(created);
    return created;
  }
}

class FakeDnsDriver implements DnsProbeDriver {
  readonly lookups: Array<string> = [];
  ipv6AvailableValue: boolean = false;
  private readonly lookupResult: Array<ProbeDnsAddress>;
  invalidLookupResult?: Array<ProbeDnsAddress>;
  throwOnLookup: boolean = false;

  constructor(lookupResult: Array<ProbeDnsAddress>) {
    this.lookupResult = lookupResult.slice();
  }

  async getAddressesByName(host: string): Promise<Array<ProbeDnsAddress>> {
    this.lookups.push(host);
    if (this.throwOnLookup && host.endsWith('.invalid')) {
      throw new Error('lookup failed');
    }
    if (host.endsWith('.invalid') && this.invalidLookupResult !== undefined) {
      return this.invalidLookupResult.slice();
    }
    return this.lookupResult.slice();
  }

  async isIpv6Available(): Promise<boolean> {
    return this.ipv6AvailableValue;
  }
}

class FakeCapabilitySocket implements UdpProbeSocket {
  bindCalls: number = 0;
  closeCalls: number = 0;
  throwOnBind: boolean = false;

  async bind(_address: ProbeSocketAddress): Promise<void> {
    this.bindCalls += 1;
    if (this.throwOnBind) {
      throw new Error('bind failed');
    }
  }

  async send(_options: ProbeUdpSendOptions): Promise<void> {
  }

  async receive(): Promise<ProbeSocketMessage> {
    return createSocketMessage('::1', 'IPv6', 0, '');
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
  }
}

class ProbeTestEnvironment {
  probe: DirectTrafficProbe;
  fileDriver: FakeFileDriver;
  httpDriver: FakeHttpDriver;
  tcpDriver: FakeTcpDriver;
  udpDriver: FakeUdpDriver;
  dnsDriver: FakeDnsDriver;
  nativeSocketPort: FakeNativeSocketProbePort;

  constructor(
    probe: DirectTrafficProbe,
    fileDriver: FakeFileDriver,
    httpDriver: FakeHttpDriver,
    tcpDriver: FakeTcpDriver,
    udpDriver: FakeUdpDriver,
    dnsDriver: FakeDnsDriver,
    nativeSocketPort: FakeNativeSocketProbePort
  ) {
    this.probe = probe;
    this.fileDriver = fileDriver;
    this.httpDriver = httpDriver;
    this.tcpDriver = tcpDriver;
    this.udpDriver = udpDriver;
    this.dnsDriver = dnsDriver;
    this.nativeSocketPort = nativeSocketPort;
  }
}

function buildCommand(): ProbeCommand {
  const command: ProbeCommand = new ProbeCommand();
  command.runId = 'run-opaque';
  command.sessionId = 'session-opaque';
  command.pinnedCertificateHash = 'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
  command.originCaPem = '-----BEGIN CERTIFICATE-----\nVEVTVA==\n-----END CERTIFICATE-----';

  const flowIds: ProbeFlowIdSet = new ProbeFlowIdSet();
  flowIds.https = 'flow-https';
  flowIds.tcp = 'flow-tcp';
  flowIds.udpIpv4 = 'flow-udp4';
  flowIds.udpIpv6 = 'flow-udp6';
  flowIds.dnsLookup = 'flow-dns-lookup';
  flowIds.dnsPacketIpv4 = 'flow-dns4';
  flowIds.dnsPacketIpv6 = 'flow-dns6';
  flowIds.httpConnect = 'flow-http-connect';
  flowIds.socks5 = 'flow-socks5';
  command.flowIds = flowIds;

  const origin: ProbeOriginConfig = new ProbeOriginConfig();
  origin.host = 'origin.lan';
  origin.httpsPort = 18443;
  origin.tcpPort = 18080;
  origin.udpPort = 15353;
  origin.dnsPort = 15354;
  command.lanOrigin = origin;

  const externalOrigin: ProbeExternalOriginConfig = new ProbeExternalOriginConfig();
  externalOrigin.host = '11.22.33.44';
  externalOrigin.tcpHost = '55.66.77.88';
  externalOrigin.tcpPort = 80;
  externalOrigin.udpPort = 20053;
  externalOrigin.dnsPort = 20054;
  command.externalOrigin = externalOrigin;

  const listeners: ProbeLocalListenerConfig = new ProbeLocalListenerConfig();
  listeners.httpConnectPort = 17890;
  listeners.socks5Port = 17891;
  command.localListeners = listeners;
  return command;
}

function createProbeEnvironment(): ProbeTestEnvironment {
  const command: ProbeCommand = buildCommand();
  const fileDriver: FakeFileDriver = new FakeFileDriver();
  const httpDriver: FakeHttpDriver = new FakeHttpDriver();
  httpDriver.responseBody = createStringBuffer(buildHttpsExpectedBody(command));
  const tcpDriver: FakeTcpDriver = new FakeTcpDriver([
    new FakeTcpConnection([createStringBuffer('HTTP/1.1 200 Connection Established\r\n\r\n')]),
    new FakeTcpConnection([
      new Uint8Array([0x05, 0x00]).buffer,
      new Uint8Array([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x45, 0xD2]).buffer
    ])
  ]);
  const udpDriver: FakeUdpDriver = new FakeUdpDriver([
    new FakeUdpSocket('IPv4', [createSocketMessage('192.168.1.10', 'IPv4', 15353, buildUdpExpectedPayload(command, command.flowIds.udpIpv4))]),
    new FakeUdpSocket('IPv6', [createSocketMessage('fd00::10', 'IPv6', 15353, buildUdpExpectedPayload(command, command.flowIds.udpIpv6))]),
    new FakeUdpSocket('IPv4', [createBinarySocketMessage('192.168.1.10', 'IPv4', 15354, buildDnsQueryPacket(buildHashedInvalidLabel(command.runId, command.flowIds.dnsPacketIpv4)))]),
    new FakeUdpSocket('IPv6', [createBinarySocketMessage('fd00::10', 'IPv6', 15354, buildDnsQueryPacket(buildHashedInvalidLabel(command.runId, command.flowIds.dnsPacketIpv6)))])
  ]);
  const dnsDriver: FakeDnsDriver = new FakeDnsDriver([
    new ProbeDnsAddress('192.168.1.10', 1, 0),
    new ProbeDnsAddress('fd00::10', 2, 0)
  ]);
  dnsDriver.ipv6AvailableValue = true;
  const nativeSocketPort: FakeNativeSocketProbePort = new FakeNativeSocketProbePort();

  const probe: DirectTrafficProbe = new DirectTrafficProbe({
    httpDriver,
    tcpDriver,
    udpDriver,
    dnsDriver,
    nativeSocketPort,
    clock: new FakeClock([
      '2026-08-17T00:00:00.000Z',
      '2026-08-17T00:00:01.000Z'
    ]),
    fileDriver,
    timeoutMs: 20
  });

  return new ProbeTestEnvironment(probe, fileDriver, httpDriver, tcpDriver, udpDriver, dnsDriver, nativeSocketPort);
}

function createProbeWithEnvironment(environment: ProbeTestEnvironment, timeoutMs: number = 20): DirectTrafficProbe {
  const dependencies: DirectTrafficProbeDependencies = {
    httpDriver: environment.httpDriver,
    tcpDriver: environment.tcpDriver,
    udpDriver: environment.udpDriver,
    dnsDriver: environment.dnsDriver,
    nativeSocketPort: environment.nativeSocketPort,
    clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
    fileDriver: environment.fileDriver,
    timeoutMs
  };
  return new DirectTrafficProbe(dependencies);
}

function createNativeResult(
  outcome: 'pass' | 'fail' | 'timeout',
  payload: ArrayBuffer,
  failureCode?: NativeSocketProbeKnownFailureCode
): NativeSocketProbeResult {
  const bytes: number = new Uint8Array(payload).byteLength;
  const result: NativeSocketProbeResult = new NativeSocketProbeResult();
  result.outcome = outcome;
  result.bytesSent = bytes;
  result.bytesReceived = outcome === 'pass' ? bytes : 0;
  result.durationMs = 1;
  if (failureCode !== undefined) {
    result.failureCode = failureCode;
  }
  return result;
}

function createSocketMessage(address: string, family: 'IPv4' | 'IPv6', port: number, payload: string): ProbeSocketMessage {
  const remoteInfo: ProbeRemoteInfo = new ProbeRemoteInfo();
  remoteInfo.address = address;
  remoteInfo.family = family;
  remoteInfo.port = port;
  remoteInfo.size = payload.length;

  const message: ProbeSocketMessage = new ProbeSocketMessage();
  message.message = createStringBuffer(payload);
  message.remoteInfo = remoteInfo;
  return message;
}

function createBinarySocketMessage(address: string, family: 'IPv4' | 'IPv6', port: number, payload: ArrayBuffer): ProbeSocketMessage {
  const remoteInfo: ProbeRemoteInfo = new ProbeRemoteInfo();
  remoteInfo.address = address;
  remoteInfo.family = family;
  remoteInfo.port = port;
  remoteInfo.size = new Uint8Array(payload).byteLength;

  const message: ProbeSocketMessage = new ProbeSocketMessage();
  message.message = payload;
  message.remoteInfo = remoteInfo;
  return message;
}

function decodeSocks5Ipv4Target(buffer: ArrayBuffer): string {
  const bytes: Uint8Array = new Uint8Array(buffer);
  return `${bytes[4]}.${bytes[5]}.${bytes[6]}.${bytes[7]}`;
}

function decodeSocks5TargetPort(buffer: ArrayBuffer): number {
  const bytes: Uint8Array = new Uint8Array(buffer);
  return (bytes[8] << 8) | bytes[9];
}

export default function directTrafficProbeTestsuite() {
  describe('DirectTrafficProbeTest', () => {
    it('rejectsEmptyDefaultCommandsForAutoStartAndAcceptsCompleteCommands', 0, () => {
      expect(isCompleteProbeCommand(new ProbeCommand())).assertFalse();
      expect(isCompleteProbeCommand(buildCommand())).assertTrue();
    });

    it('hidesNonTerminalProbePageOutcomesAndKeepsOnlyPassFailLabels', 0, () => {
      expect(formatTerminalOutcome('pending')).assertEqual('');
      expect(formatTerminalOutcome('running')).assertEqual('');
      expect(formatTerminalOutcome('not-run')).assertEqual('');
      expect(formatTerminalOutcome('pass')).assertEqual('PASS');
      expect(formatTerminalOutcome('fail')).assertEqual('FAIL');
    });

    it('detectsIpv6CapabilityFromDisposableUdpBindAndClosesTheSocketOnEveryPath', 0, async () => {
      const successSocket: FakeCapabilitySocket = new FakeCapabilitySocket();
      const successDriver: HarmonyDnsProbeDriver = new HarmonyDnsProbeDriver(() => successSocket);
      expect(await successDriver.isIpv6Available()).assertTrue();
      expect(successSocket.bindCalls).assertEqual(1);
      expect(successSocket.closeCalls).assertEqual(1);

      const failureSocket: FakeCapabilitySocket = new FakeCapabilitySocket();
      failureSocket.throwOnBind = true;
      const failureDriver: HarmonyDnsProbeDriver = new HarmonyDnsProbeDriver(() => failureSocket);
      expect(await failureDriver.isIpv6Available()).assertFalse();
      expect(failureSocket.bindCalls).assertEqual(1);
      expect(failureSocket.closeCalls).assertEqual(1);
    });

    it('failsTheProbeWhenDnsLookupThrowsInsteadOfMarkingPass', 0, async () => {
      const environment: ProbeTestEnvironment = createProbeEnvironment();
      environment.dnsDriver.throwOnLookup = true;

      const result = await environment.probe.run(buildCommand());

      expect(result.outcome).assertEqual('fail');
      expect(result.failures.some((failure) => failure.code === 'DNS_LOOKUP_FAILED')).assertTrue();
      expect(result.records[0].stepId).assertEqual('dns-lookup');
      expect(result.records[0].outcome).assertEqual('fail');
    });

    it('failsTheProbeWhenDnsLookupReturnsNoAddresses', 0, async () => {
      const environment: ProbeTestEnvironment = createProbeEnvironment();
      environment.dnsDriver.invalidLookupResult = [];

      const result = await environment.probe.run(buildCommand());

      expect(result.outcome).assertEqual('fail');
      expect(result.failures.some((failure) => failure.code === 'DNS_LOOKUP_EMPTY')).assertTrue();
      expect(result.records[0].outcome).assertEqual('fail');
    });

    it('runsDirectChecksWithoutProxyMetadataAndWritesBoundedRedactedEvidence', 0, async () => {
      const environment: ProbeTestEnvironment = createProbeEnvironment();
      const command: ProbeCommand = buildCommand();
      const result = await environment.probe.run(command);

      expect(result.outcome).assertEqual('pass');
      expect(environment.httpDriver.calls.length).assertEqual(1);
      expect(environment.httpDriver.calls[0].options.headers.runIdHeader).assertEqual('run-opaque');
      expect(environment.httpDriver.calls[0].options.headers.sessionIdHeader).assertEqual('session-opaque');
      expect(environment.httpDriver.calls[0].options.headers.flowIdHeader).assertEqual('flow-https');
      expect(environment.httpDriver.calls[0].options.certificatePinning.publicKeyHash)
        .assertEqual('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
      expect(environment.httpDriver.calls[0].options.caData).assertEqual(command.originCaPem);
      expect(environment.httpDriver.calls[0].url.includes('origin.lan:18443')).assertTrue();
      expect(environment.tcpDriver.connects.length).assertEqual(2);
      expect(environment.tcpDriver.deliveredConnections.length).assertEqual(2);
      expect(environment.udpDriver.requests.length).assertEqual(0);
      expect(environment.nativeSocketPort.calls.map((call: NativeProbeCall): NativeSocketProbeKind => call.kind).join(',')).assertEqual('tcpExchange,udpEcho,dnsUdpEcho');
      expect(environment.nativeSocketPort.calls.map((call: NativeProbeCall): number => call.port).join(',')).assertEqual('80,20053,20054');
      expect(environment.nativeSocketPort.calls[0].hostIpv4).assertEqual('55.66.77.88');
      expect(environment.nativeSocketPort.calls[1].hostIpv4).assertEqual('11.22.33.44');
      expect(environment.nativeSocketPort.calls[2].hostIpv4).assertEqual('11.22.33.44');
      expect(decodeStringBuffer(environment.nativeSocketPort.calls[0].payload)).assertEqual(buildTcpExpectedPayload(command));
      expect(decodeStringBuffer(environment.nativeSocketPort.calls[0].payload).startsWith('SSH-2.0-cmfa-flow-tcp ')).assertTrue();
      expect(decodeStringBuffer(environment.nativeSocketPort.calls[0].payload).endsWith('\r\n')).assertTrue();
      expect(decodeStringBuffer(environment.nativeSocketPort.calls[0].payload).includes('TCP|run-opaque|session-opaque|flow-tcp')).assertTrue();
      expect(decodeStringBuffer(environment.nativeSocketPort.calls[0].payload).includes('Host:')).assertFalse();
      expect(decodeStringBuffer(environment.nativeSocketPort.calls[0].payload).includes('cmfa-flow-tcp')).assertTrue();
      expect(decodeStringBuffer(environment.nativeSocketPort.calls[1].payload)).assertEqual(buildUdpExpectedPayload(command, command.flowIds.udpIpv4));
      expect(new Uint8Array(environment.nativeSocketPort.calls[2].payload).byteLength > 0).assertTrue();
      expect(decodeStringBuffer(environment.tcpDriver.deliveredConnections[0].sent[0]).includes('CONNECT origin.lan:18080 HTTP/1.1')).assertTrue();
      expect(decodeSocks5Ipv4Target(environment.tcpDriver.deliveredConnections[1].sent[1])).assertEqual('192.168.1.10');
      expect(decodeSocks5TargetPort(environment.tcpDriver.deliveredConnections[1].sent[1])).assertEqual(18080);
      expect(environment.nativeSocketPort.calls[0].timeoutMs).assertEqual(20);
      expect(environment.nativeSocketPort.calls[1].timeoutMs).assertEqual(20);
      expect(environment.nativeSocketPort.calls[2].timeoutMs).assertEqual(20);
      expect(environment.fileDriver.writes.length).assertEqual(1);

      const evidence: string = environment.fileDriver.writes[0].content;
      expect(evidence.includes('origin.lan')).assertFalse();
      expect(evidence.includes('11.22.33.44')).assertFalse();
      expect(evidence.includes('55.66.77.88')).assertFalse();
      expect(evidence.includes('https://')).assertFalse();
      expect(evidence.includes('user:pass')).assertFalse();
      expect(evidence.includes('.invalid')).assertFalse();
      expect(evidence.includes('hostIpv4')).assertFalse();
      expect(evidence.includes('tcpHost')).assertFalse();
      expect(evidence.includes('GET /')).assertFalse();
      expect(evidence.includes('Host: 55.66.77.88')).assertFalse();
      expect(evidence.includes('errno')).assertFalse();
      const homePathMarker: string = '/' + 'Us' + 'ers' + '/';
      expect(evidence.includes(homePathMarker)).assertFalse();
      expect(evidence.length < 12288).assertTrue();
    });

    it('labelsExternalIngressByCaptureModeWithoutChangingLocalListenerIngress', 0, async () => {
      const baselineEnvironment: ProbeTestEnvironment = createProbeEnvironment();
      const baselineResult = await baselineEnvironment.probe.run(buildCommand());
      const baselineTcp: ProbeRecord | undefined = baselineResult.records.find(
        (record: ProbeRecord): boolean => record.stepId === 'tcp'
      );
      const baselineDns: ProbeRecord | undefined = baselineResult.records.find(
        (record: ProbeRecord): boolean => record.stepId === 'dns-packet-ipv4'
      );
      expect(baselineTcp?.ingressExpectation).assertEqual('lan-origin-direct');
      expect(baselineDns?.ingressExpectation).assertEqual('lan-origin-direct');

      const vpnEnvironment: ProbeTestEnvironment = createProbeEnvironment();
      const vpnCommand: ProbeCommand = buildCommand();
      vpnCommand.captureMode = 'vpn';
      const vpnResult = await vpnEnvironment.probe.run(vpnCommand);
      const vpnHttps: ProbeRecord | undefined = vpnResult.records.find(
        (record: ProbeRecord): boolean => record.stepId === 'https'
      );
      const vpnTcp: ProbeRecord | undefined = vpnResult.records.find(
        (record: ProbeRecord): boolean => record.stepId === 'tcp'
      );
      const vpnUdp: ProbeRecord | undefined = vpnResult.records.find(
        (record: ProbeRecord): boolean => record.stepId === 'udp-ipv4'
      );
      const vpnDns: ProbeRecord | undefined = vpnResult.records.find(
        (record: ProbeRecord): boolean => record.stepId === 'dns-packet-ipv4'
      );
      const vpnHttp: ProbeRecord | undefined = vpnResult.records.find(
        (record: ProbeRecord): boolean => record.stepId === 'http-connect'
      );
      const vpnSocks: ProbeRecord | undefined = vpnResult.records.find(
        (record: ProbeRecord): boolean => record.stepId === 'socks5'
      );
      expect(vpnHttps?.ingressExpectation).assertEqual('lan-origin-direct');
      expect(vpnTcp?.ingressExpectation).assertEqual('tun');
      expect(vpnUdp?.ingressExpectation).assertEqual('tun');
      expect(vpnDns?.ingressExpectation).assertEqual('tun');
      expect(vpnHttp?.ingressExpectation).assertEqual('local-http-connect-listener');
      expect(vpnSocks?.ingressExpectation).assertEqual('local-socks5-listener');
    });

    it('hashesInvalidDnsLabelsKeepsEveryRecordCorrelatedAndAlwaysMarksIpv6NativeStepsNotRun', 0, async () => {
      const environment: ProbeTestEnvironment = createProbeEnvironment();
      environment.dnsDriver.ipv6AvailableValue = true;

      const result = await environment.probe.run(buildCommand());
      const lookupHost: string = environment.dnsDriver.lookups[0];
      const ipv6Udp: ProbeRecord | undefined = result.records.find((record: ProbeRecord): boolean => record.stepId === 'udp-ipv6');
      const ipv6Dns: ProbeRecord | undefined = result.records.find((record: ProbeRecord): boolean => record.stepId === 'dns-packet-ipv6');

      expect(lookupHost.endsWith('.invalid')).assertTrue();
      expect(lookupHost.indexOf('run-opaque')).assertEqual(-1);
      expect(lookupHost.indexOf('session-opaque')).assertEqual(-1);
      expect(result.records.length >= 7).assertTrue();
      expect(result.records[0].runId).assertEqual('run-opaque');
      expect(result.records[0].sessionId).assertEqual('session-opaque');
      expect(result.records[result.records.length - 1].flowId.length > 0).assertTrue();
      expect(environment.udpDriver.requests.length).assertEqual(0);
      expect(ipv6Udp?.outcome).assertEqual('not-run');
      expect(ipv6Udp?.note).assertEqual('native-ipv4-only');
      expect(ipv6Dns?.outcome).assertEqual('not-run');
      expect(ipv6Dns?.note).assertEqual('native-ipv4-only');
    });

    it('failsHttpsWhenStatusOrBodyDoNotExactlyMatchCorrelationContract', 0, async () => {
      const environment: ProbeTestEnvironment = createProbeEnvironment();
      environment.httpDriver.responseStatusCode = 500;

      const statusFailure = await environment.probe.run(buildCommand());
      expect(statusFailure.outcome).assertEqual('fail');
      expect(statusFailure.failures.some((failure) => failure.code === 'HTTPS_DIRECT_FAILED')).assertTrue();

      environment.httpDriver.responseStatusCode = 200;
      environment.httpDriver.responseBody = createStringBuffer('WRONG');
      const bodyFailure = await environment.probe.run(buildCommand());
      expect(bodyFailure.outcome).assertEqual('fail');
      expect(bodyFailure.failures.some((failure) => failure.code === 'HTTPS_DIRECT_FAILED')).assertTrue();
    });

    it('failsTcpUdpAndDnsPacketChecksOnProtocolMismatch', 0, async () => {
      const command: ProbeCommand = buildCommand();

      const tcpEnv: ProbeTestEnvironment = createProbeEnvironment();
      tcpEnv.nativeSocketPort.responses.push(createNativeResult('fail', createStringBuffer(buildTcpExpectedPayload(command)), 'PAYLOAD_MISMATCH'));
      tcpEnv.probe = createProbeWithEnvironment(tcpEnv);
      const tcpFailure = await tcpEnv.probe.run(command);
      expect(tcpFailure.failures.some((failure) => failure.code === 'TCP_DIRECT_PAYLOAD_MISMATCH')).assertTrue();

      const udpEnv: ProbeTestEnvironment = createProbeEnvironment();
      udpEnv.nativeSocketPort.responses.push(
        createNativeResult('pass', createStringBuffer(buildTcpExpectedPayload(command))),
        createNativeResult('fail', createStringBuffer(buildUdpExpectedPayload(command, command.flowIds.udpIpv4)), 'PAYLOAD_MISMATCH')
      );
      udpEnv.probe = createProbeWithEnvironment(udpEnv);
      const udpFailure = await udpEnv.probe.run(command);
      expect(udpFailure.failures.some((failure) => failure.code === 'UDP_IPV4_FAILED')).assertTrue();

      const dnsEnv: ProbeTestEnvironment = createProbeEnvironment();
      dnsEnv.nativeSocketPort.responses.push(
        createNativeResult('pass', createStringBuffer(buildTcpExpectedPayload(command))),
        createNativeResult('pass', createStringBuffer(buildUdpExpectedPayload(command, command.flowIds.udpIpv4))),
        createNativeResult('fail', buildDnsQueryPacket(buildHashedInvalidLabel(command.runId, command.flowIds.dnsPacketIpv4)), 'PAYLOAD_MISMATCH')
      );
      dnsEnv.probe = createProbeWithEnvironment(dnsEnv);
      const dnsFailure = await dnsEnv.probe.run(command);
      expect(dnsFailure.failures.some((failure) => failure.code === 'DNS_PACKET_IPV4_FAILED')).assertTrue();
    });

    it('failsHttpConnectAndSocksOnRejectOrFailureReplies', 0, async () => {
      const command: ProbeCommand = buildCommand();

      const connectEnv: ProbeTestEnvironment = createProbeEnvironment();
      connectEnv.tcpDriver = new FakeTcpDriver([
        new FakeTcpConnection([createStringBuffer('HTTP/1.1 407 Proxy Authentication Required\r\n\r\n')]),
        new FakeTcpConnection([
          new Uint8Array([0x05, 0x00]).buffer,
          new Uint8Array([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x45, 0xD2]).buffer
        ])
      ]);
      connectEnv.probe = new DirectTrafficProbe({
        httpDriver: connectEnv.httpDriver,
        tcpDriver: connectEnv.tcpDriver,
        udpDriver: connectEnv.udpDriver,
        dnsDriver: connectEnv.dnsDriver,
        nativeSocketPort: connectEnv.nativeSocketPort,
        clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
        fileDriver: connectEnv.fileDriver,
        timeoutMs: 20
      });
      const connectFailure = await connectEnv.probe.run(command);
      expect(connectFailure.failures.some((failure) => failure.code === 'HTTP_CONNECT_LISTENER_FAILED')).assertTrue();

      const socksEnv: ProbeTestEnvironment = createProbeEnvironment();
      socksEnv.tcpDriver = new FakeTcpDriver([
        new FakeTcpConnection([createStringBuffer('HTTP/1.1 200 Connection Established\r\n\r\n')]),
        new FakeTcpConnection([
          new Uint8Array([0x05, 0xff]).buffer,
          new Uint8Array([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x45, 0xD2]).buffer
        ])
      ]);
      socksEnv.probe = new DirectTrafficProbe({
        httpDriver: socksEnv.httpDriver,
        tcpDriver: socksEnv.tcpDriver,
        udpDriver: socksEnv.udpDriver,
        dnsDriver: socksEnv.dnsDriver,
        nativeSocketPort: socksEnv.nativeSocketPort,
        clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
        fileDriver: socksEnv.fileDriver,
        timeoutMs: 20
      });
      const socksFailure = await socksEnv.probe.run(command);
      expect(socksFailure.failures.some((failure) => failure.code === 'SOCKS5_LISTENER_FAILED')).assertTrue();
    });

    it('rejectsInvalidIpv4OctetsInCompleteCommandValidation', 0, () => {
      const command: ProbeCommand = buildCommand();
      command.lanOrigin.host = '999.999.999.999';
      expect(isCompleteProbeCommand(command)).assertFalse();
    });

    it('abortsOrClosesOwnedHandlesOnTimeout', 0, async () => {
      const command: ProbeCommand = buildCommand();

      const httpEnv: ProbeTestEnvironment = createProbeEnvironment();
      httpEnv.httpDriver.hangRequest = true;
      httpEnv.probe = new DirectTrafficProbe({
        httpDriver: httpEnv.httpDriver,
        tcpDriver: httpEnv.tcpDriver,
        udpDriver: httpEnv.udpDriver,
        dnsDriver: httpEnv.dnsDriver,
        nativeSocketPort: httpEnv.nativeSocketPort,
        clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
        fileDriver: httpEnv.fileDriver,
        timeoutMs: 5
      });
      const httpTimeout = await httpEnv.probe.run(command);
      expect(httpTimeout.failures.some((failure) => failure.code === 'HTTPS_DIRECT_FAILED')).assertTrue();
      expect(httpEnv.httpDriver.abortCalls > 0).assertTrue();

      const tcpConnection: FakeTcpConnection = new FakeTcpConnection([]);
      tcpConnection.hangReceive = true;
      const tcpEnv: ProbeTestEnvironment = createProbeEnvironment();
      tcpEnv.tcpDriver = new FakeTcpDriver([
        tcpConnection,
        new FakeTcpConnection([
          new Uint8Array([0x05, 0x00]).buffer,
          new Uint8Array([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x45, 0xD2]).buffer
        ])
      ]);
      tcpEnv.probe = createProbeWithEnvironment(tcpEnv, 5);
      const tcpTimeout = await tcpEnv.probe.run(command);
      expect(tcpTimeout.failures.some((failure) => failure.code === 'HTTP_CONNECT_LISTENER_FAILED')).assertTrue();
      expect(tcpConnection.closeCalls.length > 0).assertTrue();
    });

    it('cancelsPendingTcpConnectBeforeDriverConnectResolves', 0, async () => {
      const command: ProbeCommand = buildCommand();
      const connectEnv: ProbeTestEnvironment = createProbeEnvironment();
      connectEnv.tcpDriver.hangConnect = true;
      connectEnv.probe = createProbeWithEnvironment(connectEnv, 5);

      const result = await connectEnv.probe.run(command);

      expect(result.failures.some((failure) => failure.code === 'HTTP_CONNECT_LISTENER_FAILED')).assertTrue();
      expect(connectEnv.tcpDriver.cancelPendingConnectCalls).assertEqual(2);
      expect(connectEnv.tcpDriver.pendingConnectCancelled).assertTrue();
    });

    it('cancelsReceiveWaitersImmediatelyOnOuterTimeout', 0, async () => {
      const command: ProbeCommand = buildCommand();
      const tcpConnection: FakeTcpConnection = new FakeTcpConnection([]);
      tcpConnection.hangReceive = true;
      const tcpEnv: ProbeTestEnvironment = createProbeEnvironment();
      tcpEnv.tcpDriver = new FakeTcpDriver([
        tcpConnection,
        new FakeTcpConnection([
          new Uint8Array([0x05, 0x00]).buffer,
          new Uint8Array([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x45, 0xD2]).buffer
        ])
      ]);
      tcpEnv.probe = createProbeWithEnvironment(tcpEnv, 5);

      const tcpResult = await tcpEnv.probe.run(command);
      expect(tcpResult.failures.some((failure) => failure.code === 'HTTP_CONNECT_LISTENER_FAILED')).assertTrue();
      expect(tcpConnection.cancelReceiveCalls).assertEqual(1);
    });

    it('mapsNativeTcpUdpAndDnsResultsToStepSpecificOutcomesWithoutLeakingDriverDetails', 0, async () => {
      const command: ProbeCommand = buildCommand();

      const tcpEnv: ProbeTestEnvironment = createProbeEnvironment();
      tcpEnv.nativeSocketPort.responses.push(
        createNativeResult('pass', createStringBuffer(buildTcpExpectedPayload(command))),
        createNativeResult('pass', createStringBuffer(buildUdpExpectedPayload(command, command.flowIds.udpIpv4))),
        createNativeResult('pass', buildDnsQueryPacket(buildHashedInvalidLabel(command.runId, command.flowIds.dnsPacketIpv4)))
      );
      const tcpPass = await tcpEnv.probe.run(command);
      expect(tcpPass.records.find((record: ProbeRecord): boolean => record.stepId === 'tcp')?.outcome).assertEqual('pass');

      const udpEnv: ProbeTestEnvironment = createProbeEnvironment();
      udpEnv.nativeSocketPort.responses.push(
        createNativeResult('pass', createStringBuffer(buildTcpExpectedPayload(command))),
        createNativeResult('timeout', createStringBuffer(buildUdpExpectedPayload(command, command.flowIds.udpIpv4)), 'TIMEOUT')
      );
      udpEnv.probe = createProbeWithEnvironment(udpEnv);
      const udpTimeout = await udpEnv.probe.run(command);
      expect(udpTimeout.records.find((record: ProbeRecord): boolean => record.stepId === 'udp-ipv4')?.outcome).assertEqual('fail');
      expect(udpTimeout.failures.some((failure) => failure.code === 'UDP_IPV4_FAILED')).assertTrue();

      const dnsEnv: ProbeTestEnvironment = createProbeEnvironment();
      dnsEnv.nativeSocketPort.responses.push(
        createNativeResult('pass', createStringBuffer(buildTcpExpectedPayload(command))),
        createNativeResult('pass', createStringBuffer(buildUdpExpectedPayload(command, command.flowIds.udpIpv4))),
        createNativeResult('pass', buildDnsQueryPacket(buildHashedInvalidLabel(command.runId, command.flowIds.dnsPacketIpv4)))
      );
      const dnsPass = await dnsEnv.probe.run(command);
      expect(dnsPass.records.find((record: ProbeRecord): boolean => record.stepId === 'dns-packet-ipv4')?.outcome).assertEqual('pass');
    });

    it('keepsEvidenceJsonRedactedWhenNativeBridgeThrowsOrReturnsInvalidShapes', 0, async () => {
      const command: ProbeCommand = buildCommand();
      command.lanOrigin.host = 'opaque-origin.example';

      const thrownEnv: ProbeTestEnvironment = createProbeEnvironment();
      thrownEnv.nativeSocketPort.responses.push(
        new Error('No route to host EHOSTUNREACH payload-marker.invalid errno=101 hostIpv4=198.51.100.5')
      );
      thrownEnv.probe = createProbeWithEnvironment(thrownEnv);
      const thrownResult = await thrownEnv.probe.run(command);
      expect(thrownResult.failures.some((failure) => failure.code === 'TCP_DIRECT_FAILED')).assertTrue();
      const thrownEvidence: string = thrownEnv.fileDriver.writes[0].content;

      const invalidEnv: ProbeTestEnvironment = createProbeEnvironment();
      const invalidShape: InvalidNativeSocketProbeShape = new InvalidNativeSocketProbeShape();
      invalidShape.bytesSent = -9;
      invalidShape.bytesReceived = -3;
      invalidShape.durationMs = -7;
      invalidShape.failureCode = 'ECONNREFUSED';
      invalidEnv.nativeSocketPort.responses.push(invalidShape);
      invalidEnv.probe = createProbeWithEnvironment(invalidEnv);
      const invalidResult = await invalidEnv.probe.run(command);
      expect(invalidResult.failures.some((failure) => failure.code === 'TCP_DIRECT_FAILED')).assertTrue();

      const invalidEvidence: string = invalidEnv.fileDriver.writes[0].content;
      const evidenceBodies: Array<string> = [thrownEvidence, invalidEvidence];
      for (let index = 0; index < evidenceBodies.length; index += 1) {
        const evidence: string = evidenceBodies[index];
        expect(evidence.includes('opaque-origin.example')).assertFalse();
        expect(evidence.includes('payload-marker')).assertFalse();
        expect(evidence.includes('.invalid')).assertFalse();
        expect(evidence.includes('hostIpv4')).assertFalse();
        expect(evidence.includes('errno')).assertFalse();
        expect(evidence.includes('ECONNREFUSED')).assertFalse();
        expect(evidence.includes('EHOSTUNREACH')).assertFalse();
        expect(evidence.includes('No route')).assertFalse();
        expect(evidence.includes('Connection refused')).assertFalse();
        expect(evidence.includes('Network unreachable')).assertFalse();
        expect(evidence.includes('Invalid argument')).assertFalse();
        expect(evidence.includes('labelHash=')).assertTrue();
      }
    });

    it('normalizesDefaultNativeAdapterFailuresWithoutReturningRawBridgeErrors', 0, async () => {
      const expectedPayload: ArrayBuffer = createStringBuffer('abc');
      const tcpSendPassAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        const valid: ValidNativeSocketProbePassShape = new ValidNativeSocketProbePassShape();
        valid.bytesSent = 3;
        valid.bytesReceived = 0;
        valid.durationMs = 1;
        return valid;
      });
      const tcpSendPassResult: NativeSocketProbeResult = await tcpSendPassAdapter.probe('tcpSend', '192.168.1.10', 443, expectedPayload, 20);
      expect(tcpSendPassResult.outcome).assertEqual('pass');
      expect(tcpSendPassResult.bytesSent).assertEqual(3);
      expect(tcpSendPassResult.bytesReceived).assertEqual(0);
      expect(tcpSendPassResult.failureCode).assertEqual(undefined);

      const tcpExchangePassAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        const valid: ValidNativeSocketProbePassShape = new ValidNativeSocketProbePassShape();
        valid.bytesSent = 3;
        valid.bytesReceived = 8;
        valid.durationMs = 1;
        return valid;
      });
      const tcpExchangePassResult: NativeSocketProbeResult = await tcpExchangePassAdapter.probe('tcpExchange', '192.168.1.10', 443, expectedPayload, 20);
      expect(tcpExchangePassResult.outcome).assertEqual('pass');
      expect(tcpExchangePassResult.bytesReceived).assertEqual(8);

      const nullShapeAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        return null;
      });
      const nullShapeResult: NativeSocketProbeResult = await nullShapeAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(nullShapeResult.failureCode).assertEqual('INVALID_RESULT');

      const undefinedShapeAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        return undefined;
      });
      const undefinedShapeResult: NativeSocketProbeResult = await undefinedShapeAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(undefinedShapeResult.failureCode).assertEqual('INVALID_RESULT');

      const nonObjectShapeAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        return 'not-an-object';
      });
      const nonObjectShapeResult: NativeSocketProbeResult = await nonObjectShapeAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(nonObjectShapeResult.failureCode).assertEqual('INVALID_RESULT');

      const invalidBytesSentAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        const malformed: InvalidNativeSocketProbeShape = new InvalidNativeSocketProbeShape();
        malformed.outcome = 'pass';
        malformed.bytesSent = 0x100000000;
        malformed.bytesReceived = 3;
        malformed.durationMs = 1;
        malformed.failureCode = undefined;
        return malformed;
      });
      const invalidBytesSentResult: NativeSocketProbeResult = await invalidBytesSentAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(invalidBytesSentResult.outcome).assertEqual('fail');
      expect(invalidBytesSentResult.bytesSent).assertEqual(0);
      expect(invalidBytesSentResult.bytesReceived).assertEqual(0);
      expect(invalidBytesSentResult.durationMs).assertEqual(0);
      expect(invalidBytesSentResult.failureCode).assertEqual('INVALID_RESULT');

      const unknownFailureCodeAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        const malformed: InvalidNativeSocketProbeShape = new InvalidNativeSocketProbeShape();
        malformed.outcome = 'fail';
        malformed.bytesSent = 3;
        malformed.bytesReceived = 0;
        malformed.durationMs = 1;
        malformed.failureCode = 'EHOSTUNREACH';
        return malformed;
      });
      const unknownFailureCodeResult: NativeSocketProbeResult = await unknownFailureCodeAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(unknownFailureCodeResult.failureCode).assertEqual('INVALID_RESULT');

      const missingFailureCodeAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        const malformed: InvalidNativeSocketProbeShape = new InvalidNativeSocketProbeShape();
        malformed.outcome = 'fail';
        malformed.bytesSent = 3;
        malformed.bytesReceived = 0;
        malformed.durationMs = 1;
        malformed.failureCode = undefined;
        return malformed;
      });
      const missingFailureCodeResult: NativeSocketProbeResult = await missingFailureCodeAdapter.probe('udpEcho', '192.168.1.10', 53, expectedPayload, 20);
      expect(missingFailureCodeResult.failureCode).assertEqual('INVALID_RESULT');

      const timeoutMissingCodeAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        const malformed: InvalidNativeSocketProbeShape = new InvalidNativeSocketProbeShape();
        malformed.outcome = 'timeout';
        malformed.bytesSent = 3;
        malformed.bytesReceived = 0;
        malformed.durationMs = 1;
        malformed.failureCode = undefined;
        return malformed;
      });
      const timeoutMissingCodeResult: NativeSocketProbeResult = await timeoutMissingCodeAdapter.probe('udpEcho', '192.168.1.10', 53, expectedPayload, 20);
      expect(timeoutMissingCodeResult.failureCode).assertEqual('INVALID_RESULT');

      const passWithFailureCodeAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        const malformed: InvalidNativeSocketProbeShape = new InvalidNativeSocketProbeShape();
        malformed.outcome = 'pass';
        malformed.bytesSent = 3;
        malformed.bytesReceived = 3;
        malformed.durationMs = 1;
        malformed.failureCode = 'CONNECT_FAILED';
        return malformed;
      });
      const passWithFailureCodeResult: NativeSocketProbeResult = await passWithFailureCodeAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(passWithFailureCodeResult.failureCode).assertEqual('INVALID_RESULT');

      const passWithMismatchedCountsAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        const malformed: InvalidNativeSocketProbeShape = new InvalidNativeSocketProbeShape();
        malformed.outcome = 'pass';
        malformed.bytesSent = 2;
        malformed.bytesReceived = 3;
        malformed.durationMs = 1;
        malformed.failureCode = undefined;
        return malformed;
      });
      const passWithMismatchedCountsResult: NativeSocketProbeResult = await passWithMismatchedCountsAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(passWithMismatchedCountsResult.failureCode).assertEqual('INVALID_RESULT');

      const timeoutWithWrongCodeAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        const malformed: InvalidNativeSocketProbeShape = new InvalidNativeSocketProbeShape();
        malformed.outcome = 'timeout';
        malformed.bytesSent = 3;
        malformed.bytesReceived = 0;
        malformed.durationMs = 1;
        malformed.failureCode = 'RECV_FAILED';
        return malformed;
      });
      const timeoutWithWrongCodeResult: NativeSocketProbeResult = await timeoutWithWrongCodeAdapter.probe('udpEcho', '192.168.1.10', 53, expectedPayload, 20);
      expect(timeoutWithWrongCodeResult.failureCode).assertEqual('INVALID_RESULT');

      const invalidAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        const malformed: InvalidNativeSocketProbeShape = new InvalidNativeSocketProbeShape();
        malformed.failureCode = 'EHOSTUNREACH';
        return malformed;
      });
      const invalidResult: NativeSocketProbeResult = await invalidAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(invalidResult.outcome).assertEqual('fail');
      expect(invalidResult.bytesSent).assertEqual(0);
      expect(invalidResult.bytesReceived).assertEqual(0);
      expect(invalidResult.durationMs).assertEqual(0);
      expect(invalidResult.failureCode).assertEqual('INVALID_RESULT');

      const extraFieldAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        const malformed: ExtraNativeSocketProbeShape = new ExtraNativeSocketProbeShape();
        malformed.outcome = 'fail';
        malformed.bytesSent = 3;
        malformed.bytesReceived = 0;
        malformed.durationMs = 1;
        malformed.failureCode = 'CONNECT_FAILED';
        return malformed;
      });
      const extraFieldResult: NativeSocketProbeResult = await extraFieldAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(extraFieldResult.failureCode).assertEqual('INVALID_RESULT');

      const inheritedOutcomeAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        return new InheritedOutcomeShape(3);
      });
      const inheritedOutcomeResult: NativeSocketProbeResult = await inheritedOutcomeAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(inheritedOutcomeResult.failureCode).assertEqual('INVALID_RESULT');

      const changingRequestPayloadAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async (request) => {
        request.payload = createStringBuffer('mutated-length');
        return createNativeResult('pass', request.payload);
      });
      const changingRequestPayloadResult: NativeSocketProbeResult = await changingRequestPayloadAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(changingRequestPayloadResult.failureCode).assertEqual('INVALID_RESULT');

      const thrownAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async (): Promise<NativeSocketProbeResult> => {
        throw new Error('Connection refused ECONNREFUSED');
      });
      const thrownResult: NativeSocketProbeResult = await thrownAdapter.probe('udpEcho', '192.168.1.10', 53, expectedPayload, 20);
      expect(thrownResult.outcome).assertEqual('fail');
      expect(thrownResult.bytesSent).assertEqual(0);
      expect(thrownResult.bytesReceived).assertEqual(0);
      expect(thrownResult.durationMs).assertEqual(0);
      expect(thrownResult.failureCode).assertEqual('BRIDGE_FAILURE');

      const throwingSlicePayload: ArrayBuffer = new ThrowingSliceArrayBuffer() as ArrayBuffer;
      const throwingSliceAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        return createNativeResult('pass', expectedPayload);
      });
      const throwingSliceResult: NativeSocketProbeResult = await throwingSliceAdapter.probe('tcpEcho', '192.168.1.10', 80, throwingSlicePayload, 20);
      expect(throwingSliceResult.failureCode).assertEqual('BRIDGE_FAILURE');

      const validPassAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        return createNativeResult('pass', expectedPayload);
      });
      const validPassResult: NativeSocketProbeResult = await validPassAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(validPassResult.outcome).assertEqual('pass');
      expect(validPassResult.failureCode).assertEqual(undefined);

      const validFailAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        return createNativeResult('fail', expectedPayload, 'CONNECT_FAILED');
      });
      const validFailResult: NativeSocketProbeResult = await validFailAdapter.probe('tcpEcho', '192.168.1.10', 80, expectedPayload, 20);
      expect(validFailResult.outcome).assertEqual('fail');
      expect(validFailResult.failureCode).assertEqual('CONNECT_FAILED');

      const validTimeoutAdapter: NativeSocketProbePort = createDefaultNativeSocketProbePort(async () => {
        return createNativeResult('timeout', expectedPayload, 'TIMEOUT');
      });
      const validTimeoutResult: NativeSocketProbeResult = await validTimeoutAdapter.probe('udpEcho', '192.168.1.10', 53, expectedPayload, 20);
      expect(validTimeoutResult.outcome).assertEqual('timeout');
      expect(validTimeoutResult.failureCode).assertEqual('TIMEOUT');
    });

    it('emitsMinimalEvidenceWhenOversizedContentStillExceedsTrimmedBudget', 0, () => {
      const huge: string = 'x'.repeat(20000);
      const serialized: string = boundEvidenceJson(new ProbeEvidence(
        huge,
        huge,
        huge,
        huge,
        huge,
        huge,
        [new ProbeRecord(huge, huge, huge, huge, huge, huge, huge, 1, huge, huge, 1, 1, 200, huge)],
        [new ProbeFailure(huge, huge)]
      ));

      expect(serialized.length <= 12288).assertTrue();
      expect(serialized.includes('"records":[]')).assertTrue();
      expect(serialized.includes('"failures":[]')).assertTrue();
    });
  });
}
