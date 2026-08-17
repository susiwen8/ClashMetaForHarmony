import { describe, expect, it } from '@ohos/hypium';
import type {
  DnsProbeDriver,
  HttpProbeDriver,
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
  ProbeCommand,
  ProbeDnsAddress,
  ProbeEvidence,
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
    return this.connections.shift() ?? new FakeTcpConnection([]);
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
  private readonly sockets: Array<FakeUdpSocket>;

  constructor(sockets: Array<FakeUdpSocket>) {
    this.sockets = sockets.slice();
  }

  createSocket(family: 'IPv4' | 'IPv6'): UdpProbeSocket {
    this.requests.push(family);
    return this.sockets.shift() ?? new FakeUdpSocket(family, []);
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

  constructor(
    probe: DirectTrafficProbe,
    fileDriver: FakeFileDriver,
    httpDriver: FakeHttpDriver,
    tcpDriver: FakeTcpDriver,
    udpDriver: FakeUdpDriver,
    dnsDriver: FakeDnsDriver
  ) {
    this.probe = probe;
    this.fileDriver = fileDriver;
    this.httpDriver = httpDriver;
    this.tcpDriver = tcpDriver;
    this.udpDriver = udpDriver;
    this.dnsDriver = dnsDriver;
  }
}

function buildCommand(): ProbeCommand {
  const command: ProbeCommand = new ProbeCommand();
  command.runId = 'run-opaque';
  command.sessionId = 'session-opaque';
  command.pinnedCertificateHash = 'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

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
    new FakeTcpConnection([createStringBuffer(buildTcpExpectedPayload(command))]),
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

  const probe: DirectTrafficProbe = new DirectTrafficProbe({
    httpDriver,
    tcpDriver,
    udpDriver,
    dnsDriver,
    clock: new FakeClock([
      '2026-08-17T00:00:00.000Z',
      '2026-08-17T00:00:01.000Z'
    ]),
    fileDriver,
    timeoutMs: 20
  });

  return new ProbeTestEnvironment(probe, fileDriver, httpDriver, tcpDriver, udpDriver, dnsDriver);
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
      const result = await environment.probe.run(buildCommand());

      expect(result.outcome).assertEqual('pass');
      expect(environment.httpDriver.calls.length).assertEqual(1);
      expect(environment.httpDriver.calls[0].options.headers.runIdHeader).assertEqual('run-opaque');
      expect(environment.httpDriver.calls[0].options.headers.sessionIdHeader).assertEqual('session-opaque');
      expect(environment.httpDriver.calls[0].options.headers.flowIdHeader).assertEqual('flow-https');
      expect(environment.tcpDriver.connects.length).assertEqual(3);
      expect(environment.udpDriver.requests.join(',')).assertEqual('IPv4,IPv6,IPv4,IPv6');
      expect(environment.fileDriver.writes.length).assertEqual(1);

      const evidence: string = environment.fileDriver.writes[0].content;
      expect(evidence.includes('origin.lan')).assertFalse();
      expect(evidence.includes('https://')).assertFalse();
      expect(evidence.includes('user:pass')).assertFalse();
      expect(evidence.includes('.invalid')).assertFalse();
      const homePathMarker: string = '/' + 'Us' + 'ers' + '/';
      expect(evidence.includes(homePathMarker)).assertFalse();
      expect(evidence.length < 12288).assertTrue();
    });

    it('hashesInvalidDnsLabelsKeepsEveryRecordCorrelatedAndSkipsIpv6WithoutCapability', 0, async () => {
      const environment: ProbeTestEnvironment = createProbeEnvironment();
      environment.dnsDriver.ipv6AvailableValue = false;

      const result = await environment.probe.run(buildCommand());
      const lookupHost: string = environment.dnsDriver.lookups[0];

      expect(lookupHost.endsWith('.invalid')).assertTrue();
      expect(lookupHost.indexOf('run-opaque')).assertEqual(-1);
      expect(lookupHost.indexOf('session-opaque')).assertEqual(-1);
      expect(result.records.length >= 7).assertTrue();
      expect(result.records[0].runId).assertEqual('run-opaque');
      expect(result.records[0].sessionId).assertEqual('session-opaque');
      expect(result.records[result.records.length - 1].flowId.length > 0).assertTrue();
      expect(result.records.some((record: ProbeRecord): boolean => record.flowId === 'flow-udp6')).assertFalse();
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
      tcpEnv.tcpDriver = new FakeTcpDriver([
        new FakeTcpConnection([createStringBuffer('WRONG')]),
        new FakeTcpConnection([createStringBuffer('HTTP/1.1 200 Connection Established\r\n\r\n')]),
        new FakeTcpConnection([
          new Uint8Array([0x05, 0x00]).buffer,
          new Uint8Array([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x45, 0xD2]).buffer
        ])
      ]);
      tcpEnv.probe = new DirectTrafficProbe({
        httpDriver: tcpEnv.httpDriver,
        tcpDriver: tcpEnv.tcpDriver,
        udpDriver: tcpEnv.udpDriver,
        dnsDriver: tcpEnv.dnsDriver,
        clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
        fileDriver: tcpEnv.fileDriver,
        timeoutMs: 20
      });
      const tcpFailure = await tcpEnv.probe.run(command);
      expect(tcpFailure.failures.some((failure) => failure.code === 'TCP_DIRECT_FAILED')).assertTrue();

      const udpEnv: ProbeTestEnvironment = createProbeEnvironment();
      udpEnv.udpDriver = new FakeUdpDriver([
        new FakeUdpSocket('IPv4', [createSocketMessage('192.168.1.99', 'IPv4', 15353, buildUdpExpectedPayload(command, command.flowIds.udpIpv4))]),
        new FakeUdpSocket('IPv6', [createSocketMessage('fd00::10', 'IPv6', 15353, buildUdpExpectedPayload(command, command.flowIds.udpIpv6))]),
        new FakeUdpSocket('IPv4', [createBinarySocketMessage('192.168.1.10', 'IPv4', 15354, buildDnsQueryPacket(buildHashedInvalidLabel(command.runId, command.flowIds.dnsPacketIpv4)))]),
        new FakeUdpSocket('IPv6', [createBinarySocketMessage('fd00::10', 'IPv6', 15354, buildDnsQueryPacket(buildHashedInvalidLabel(command.runId, command.flowIds.dnsPacketIpv6)))])
      ]);
      udpEnv.probe = new DirectTrafficProbe({
        httpDriver: udpEnv.httpDriver,
        tcpDriver: udpEnv.tcpDriver,
        udpDriver: udpEnv.udpDriver,
        dnsDriver: udpEnv.dnsDriver,
        clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
        fileDriver: udpEnv.fileDriver,
        timeoutMs: 20
      });
      const udpFailure = await udpEnv.probe.run(command);
      expect(udpFailure.failures.some((failure) => failure.code === 'UDP_IPV4_FAILED')).assertTrue();

      const dnsEnv: ProbeTestEnvironment = createProbeEnvironment();
      dnsEnv.udpDriver = new FakeUdpDriver([
        new FakeUdpSocket('IPv4', [createSocketMessage('192.168.1.10', 'IPv4', 15353, buildUdpExpectedPayload(command, command.flowIds.udpIpv4))]),
        new FakeUdpSocket('IPv6', [createSocketMessage('fd00::10', 'IPv6', 15353, buildUdpExpectedPayload(command, command.flowIds.udpIpv6))]),
        new FakeUdpSocket('IPv4', [createBinarySocketMessage('192.168.1.77', 'IPv4', 15354, createStringBuffer('JUNK'))]),
        new FakeUdpSocket('IPv6', [createBinarySocketMessage('fd00::10', 'IPv6', 15354, buildDnsQueryPacket(buildHashedInvalidLabel(command.runId, command.flowIds.dnsPacketIpv6)))])
      ]);
      dnsEnv.probe = new DirectTrafficProbe({
        httpDriver: dnsEnv.httpDriver,
        tcpDriver: dnsEnv.tcpDriver,
        udpDriver: dnsEnv.udpDriver,
        dnsDriver: dnsEnv.dnsDriver,
        clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
        fileDriver: dnsEnv.fileDriver,
        timeoutMs: 20
      });
      const dnsFailure = await dnsEnv.probe.run(command);
      expect(dnsFailure.failures.some((failure) => failure.code === 'DNS_PACKET_IPV4_FAILED')).assertTrue();
    });

    it('failsHttpConnectAndSocksOnRejectOrFailureReplies', 0, async () => {
      const command: ProbeCommand = buildCommand();

      const connectEnv: ProbeTestEnvironment = createProbeEnvironment();
      connectEnv.tcpDriver = new FakeTcpDriver([
        new FakeTcpConnection([createStringBuffer(buildTcpExpectedPayload(command))]),
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
        clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
        fileDriver: connectEnv.fileDriver,
        timeoutMs: 20
      });
      const connectFailure = await connectEnv.probe.run(command);
      expect(connectFailure.failures.some((failure) => failure.code === 'HTTP_CONNECT_LISTENER_FAILED')).assertTrue();

      const socksEnv: ProbeTestEnvironment = createProbeEnvironment();
      socksEnv.tcpDriver = new FakeTcpDriver([
        new FakeTcpConnection([createStringBuffer(buildTcpExpectedPayload(command))]),
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
        new FakeTcpConnection([createStringBuffer('HTTP/1.1 200 Connection Established\r\n\r\n')]),
        new FakeTcpConnection([
          new Uint8Array([0x05, 0x00]).buffer,
          new Uint8Array([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x45, 0xD2]).buffer
        ])
      ]);
      tcpEnv.probe = new DirectTrafficProbe({
        httpDriver: tcpEnv.httpDriver,
        tcpDriver: tcpEnv.tcpDriver,
        udpDriver: tcpEnv.udpDriver,
        dnsDriver: tcpEnv.dnsDriver,
        clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
        fileDriver: tcpEnv.fileDriver,
        timeoutMs: 5
      });
      const tcpTimeout = await tcpEnv.probe.run(command);
      expect(tcpTimeout.failures.some((failure) => failure.code === 'TCP_DIRECT_FAILED')).assertTrue();
      expect(tcpConnection.closeCalls.length > 0).assertTrue();

      const udpSocket: FakeUdpSocket = new FakeUdpSocket('IPv4', []);
      udpSocket.hangReceive = true;
      const udpEnv: ProbeTestEnvironment = createProbeEnvironment();
      udpEnv.udpDriver = new FakeUdpDriver([
        udpSocket,
        new FakeUdpSocket('IPv6', [createSocketMessage('fd00::10', 'IPv6', 15353, buildUdpExpectedPayload(command, command.flowIds.udpIpv6))]),
        new FakeUdpSocket('IPv4', [createBinarySocketMessage('192.168.1.10', 'IPv4', 15354, buildDnsQueryPacket(buildHashedInvalidLabel(command.runId, command.flowIds.dnsPacketIpv4)))]),
        new FakeUdpSocket('IPv6', [createBinarySocketMessage('fd00::10', 'IPv6', 15354, buildDnsQueryPacket(buildHashedInvalidLabel(command.runId, command.flowIds.dnsPacketIpv6)))])
      ]);
      udpEnv.probe = new DirectTrafficProbe({
        httpDriver: udpEnv.httpDriver,
        tcpDriver: udpEnv.tcpDriver,
        udpDriver: udpEnv.udpDriver,
        dnsDriver: udpEnv.dnsDriver,
        clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
        fileDriver: udpEnv.fileDriver,
        timeoutMs: 5
      });
      const udpTimeout = await udpEnv.probe.run(command);
      expect(udpTimeout.failures.some((failure) => failure.code === 'UDP_IPV4_FAILED')).assertTrue();
      expect(udpSocket.closeCalls.length > 0).assertTrue();
    });

    it('cancelsPendingTcpConnectBeforeDriverConnectResolves', 0, async () => {
      const command: ProbeCommand = buildCommand();
      const connectEnv: ProbeTestEnvironment = createProbeEnvironment();
      connectEnv.tcpDriver.hangConnect = true;
      connectEnv.probe = new DirectTrafficProbe({
        httpDriver: connectEnv.httpDriver,
        tcpDriver: connectEnv.tcpDriver,
        udpDriver: connectEnv.udpDriver,
        dnsDriver: connectEnv.dnsDriver,
        clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
        fileDriver: connectEnv.fileDriver,
        timeoutMs: 5
      });

      const result = await connectEnv.probe.run(command);

      expect(result.failures.some((failure) => failure.code === 'TCP_DIRECT_FAILED')).assertTrue();
      expect(connectEnv.tcpDriver.cancelPendingConnectCalls).assertEqual(3);
      expect(connectEnv.tcpDriver.pendingConnectCancelled).assertTrue();
    });

    it('cancelsReceiveWaitersImmediatelyOnOuterTimeout', 0, async () => {
      const command: ProbeCommand = buildCommand();
      const tcpConnection: FakeTcpConnection = new FakeTcpConnection([]);
      tcpConnection.hangReceive = true;
      const tcpEnv: ProbeTestEnvironment = createProbeEnvironment();
      tcpEnv.tcpDriver = new FakeTcpDriver([
        tcpConnection,
        new FakeTcpConnection([createStringBuffer('HTTP/1.1 200 Connection Established\r\n\r\n')]),
        new FakeTcpConnection([
          new Uint8Array([0x05, 0x00]).buffer,
          new Uint8Array([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x45, 0xD2]).buffer
        ])
      ]);
      tcpEnv.probe = new DirectTrafficProbe({
        httpDriver: tcpEnv.httpDriver,
        tcpDriver: tcpEnv.tcpDriver,
        udpDriver: tcpEnv.udpDriver,
        dnsDriver: tcpEnv.dnsDriver,
        clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
        fileDriver: tcpEnv.fileDriver,
        timeoutMs: 5
      });

      const tcpResult = await tcpEnv.probe.run(command);
      expect(tcpResult.failures.some((failure) => failure.code === 'TCP_DIRECT_FAILED')).assertTrue();
      expect(tcpConnection.cancelReceiveCalls).assertEqual(1);

      const udpSocket: FakeUdpSocket = new FakeUdpSocket('IPv4', []);
      udpSocket.hangReceive = true;
      const udpEnv: ProbeTestEnvironment = createProbeEnvironment();
      udpEnv.udpDriver = new FakeUdpDriver([
        udpSocket,
        new FakeUdpSocket('IPv6', [createSocketMessage('fd00::10', 'IPv6', 15353, buildUdpExpectedPayload(command, command.flowIds.udpIpv6))]),
        new FakeUdpSocket('IPv4', [createBinarySocketMessage('192.168.1.10', 'IPv4', 15354, buildDnsQueryPacket(buildHashedInvalidLabel(command.runId, command.flowIds.dnsPacketIpv4)))]),
        new FakeUdpSocket('IPv6', [createBinarySocketMessage('fd00::10', 'IPv6', 15354, buildDnsQueryPacket(buildHashedInvalidLabel(command.runId, command.flowIds.dnsPacketIpv6)))])
      ]);
      udpEnv.probe = new DirectTrafficProbe({
        httpDriver: udpEnv.httpDriver,
        tcpDriver: udpEnv.tcpDriver,
        udpDriver: udpEnv.udpDriver,
        dnsDriver: udpEnv.dnsDriver,
        clock: new FakeClock(['2026-08-17T00:00:00.000Z', '2026-08-17T00:00:01.000Z']),
        fileDriver: udpEnv.fileDriver,
        timeoutMs: 5
      });

      const udpResult = await udpEnv.probe.run(command);
      expect(udpResult.failures.some((failure) => failure.code === 'UDP_IPV4_FAILED')).assertTrue();
      expect(udpSocket.cancelReceiveCalls).assertEqual(1);
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
