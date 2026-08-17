import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import type common from '@ohos.app.ability.common';
import { DirectTrafficProbe, ProbeRuntimeFactory } from '../probe/DirectTrafficProbe';
import {
  ProbeCommand,
  ProbeFlowIdSet,
  ProbeLocalListenerConfig,
  ProbeOriginConfig,
  ProbePageState,
  PROBE_PARAM_FLOW_DNS_LOOKUP,
  PROBE_PARAM_FLOW_DNS_PACKET_IPV4,
  PROBE_PARAM_FLOW_DNS_PACKET_IPV6,
  PROBE_PARAM_FLOW_HTTPS,
  PROBE_PARAM_FLOW_HTTP_CONNECT,
  PROBE_PARAM_FLOW_SOCKS5,
  PROBE_PARAM_FLOW_TCP,
  PROBE_PARAM_FLOW_UDP_IPV4,
  PROBE_PARAM_FLOW_UDP_IPV6,
  PROBE_PARAM_LOCAL_HTTP_CONNECT_PORT,
  PROBE_PARAM_LOCAL_SOCKS5_PORT,
  PROBE_PARAM_ORIGIN_DNS_PORT,
  PROBE_PARAM_ORIGIN_HOST,
  PROBE_PARAM_ORIGIN_HTTPS_PORT,
  PROBE_PARAM_ORIGIN_TCP_PORT,
  PROBE_PARAM_ORIGIN_UDP_PORT,
  PROBE_PARAM_PINNED_PUBLIC_KEY_HASH,
  PROBE_PARAM_RUN_ID,
  PROBE_PARAM_SESSION_ID,
  isCompleteProbeCommand
} from '../probe/ProbeModels';

const ROUTE_NAME: string = 'pages/ProbePage';

export default class ProbeAbility extends UIAbility {
  private readonly pageState: ProbePageState = new ProbePageState();
  private readonly storage: LocalStorage = new LocalStorage();
  private command: ProbeCommand = new ProbeCommand();
  private probe?: DirectTrafficProbe;
  private running: boolean = false;

  onCreate(want: Want): void {
    this.command = readProbeCommand(want);
    this.storage.setOrCreate('probePageState', this.pageState);
  }

  onNewWant(want: Want): void {
    this.command = readProbeCommand(want);
    if (isCompleteProbeCommand(this.command)) {
      this.startProbe();
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent(ROUTE_NAME, this.storage, (err) => {
      if (!err.code && isCompleteProbeCommand(this.command)) {
        this.startProbe();
      }
    });
  }

  private startProbe(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.pageState.begin();
    this.probe = this.probe ?? ProbeRuntimeFactory.createDefault(this.context as common.UIAbilityContext);
    const reporter = ProbeRuntimeFactory.createReporter(this.pageState);
    void this.probe.run(this.command, reporter).then((result) => {
      this.pageState.finish(result.outcome);
    }).catch(() => {
      this.pageState.finish('fail');
    }).finally(() => {
      this.running = false;
    });
  }
}

function readProbeCommand(want: Want): ProbeCommand {
  return readProbeCommandForTesting(want);
}

export function readProbeCommandForTesting(want: Want): ProbeCommand {
  const command: ProbeCommand = new ProbeCommand();
  const parameters: Record<string, Object> = want.parameters as Record<string, Object>;
  if (parameters === undefined) {
    return command;
  }

  command.runId = readString(parameters, PROBE_PARAM_RUN_ID);
  command.sessionId = readString(parameters, PROBE_PARAM_SESSION_ID);
  command.pinnedCertificateHash = readString(parameters, PROBE_PARAM_PINNED_PUBLIC_KEY_HASH);
  command.flowIds = readFlatFlowIds(parameters);
  command.lanOrigin = readFlatOrigin(parameters);
  command.localListeners = readFlatListeners(parameters);

  if (!areFlatFieldsComplete(command)) {
    const nestedFlowIds: ProbeFlowIdSet = readFlowIds(readObject(parameters, 'flowIds'));
    const nestedOrigin: ProbeOriginConfig = readOrigin(readObject(parameters, 'lanOrigin'));
    const nestedListeners: ProbeLocalListenerConfig = readListeners(readObject(parameters, 'localListeners'));
    fillMissingFlowIds(command.flowIds, nestedFlowIds);
    fillMissingOrigin(command.lanOrigin, nestedOrigin);
    fillMissingListeners(command.localListeners, nestedListeners);
    if (command.pinnedCertificateHash.length === 0) {
      command.pinnedCertificateHash = readString(parameters, 'pinnedCertificateHash');
    }
  }
  return command;
}

function areFlatFieldsComplete(command: ProbeCommand): boolean {
  return command.flowIds.https.length > 0 &&
    command.flowIds.tcp.length > 0 &&
    command.flowIds.udpIpv4.length > 0 &&
    command.flowIds.udpIpv6.length > 0 &&
    command.flowIds.dnsLookup.length > 0 &&
    command.flowIds.dnsPacketIpv4.length > 0 &&
    command.flowIds.dnsPacketIpv6.length > 0 &&
    command.flowIds.httpConnect.length > 0 &&
    command.flowIds.socks5.length > 0 &&
    command.lanOrigin.host.length > 0 &&
    command.lanOrigin.httpsPort > 0 &&
    command.lanOrigin.tcpPort > 0 &&
    command.lanOrigin.udpPort > 0 &&
    command.lanOrigin.dnsPort > 0 &&
    command.localListeners.httpConnectPort > 0 &&
    command.localListeners.socks5Port > 0 &&
    command.pinnedCertificateHash.length > 0;
}

function fillMissingFlowIds(target: ProbeFlowIdSet, fallback: ProbeFlowIdSet): void {
  if (target.https.length === 0) target.https = fallback.https;
  if (target.tcp.length === 0) target.tcp = fallback.tcp;
  if (target.udpIpv4.length === 0) target.udpIpv4 = fallback.udpIpv4;
  if (target.udpIpv6.length === 0) target.udpIpv6 = fallback.udpIpv6;
  if (target.dnsLookup.length === 0) target.dnsLookup = fallback.dnsLookup;
  if (target.dnsPacketIpv4.length === 0) target.dnsPacketIpv4 = fallback.dnsPacketIpv4;
  if (target.dnsPacketIpv6.length === 0) target.dnsPacketIpv6 = fallback.dnsPacketIpv6;
  if (target.httpConnect.length === 0) target.httpConnect = fallback.httpConnect;
  if (target.socks5.length === 0) target.socks5 = fallback.socks5;
}

function fillMissingOrigin(target: ProbeOriginConfig, fallback: ProbeOriginConfig): void {
  if (target.host.length === 0) target.host = fallback.host;
  if (target.httpsPort === 0) target.httpsPort = fallback.httpsPort;
  if (target.tcpPort === 0) target.tcpPort = fallback.tcpPort;
  if (target.udpPort === 0) target.udpPort = fallback.udpPort;
  if (target.dnsPort === 0) target.dnsPort = fallback.dnsPort;
}

function fillMissingListeners(target: ProbeLocalListenerConfig, fallback: ProbeLocalListenerConfig): void {
  if (target.httpConnectPort === 0) target.httpConnectPort = fallback.httpConnectPort;
  if (target.socks5Port === 0) target.socks5Port = fallback.socks5Port;
}

function readFlatFlowIds(source: Record<string, Object>): ProbeFlowIdSet {
  const flowIds: ProbeFlowIdSet = new ProbeFlowIdSet();
  flowIds.https = readString(source, PROBE_PARAM_FLOW_HTTPS);
  flowIds.tcp = readString(source, PROBE_PARAM_FLOW_TCP);
  flowIds.udpIpv4 = readString(source, PROBE_PARAM_FLOW_UDP_IPV4);
  flowIds.udpIpv6 = readString(source, PROBE_PARAM_FLOW_UDP_IPV6);
  flowIds.dnsLookup = readString(source, PROBE_PARAM_FLOW_DNS_LOOKUP);
  flowIds.dnsPacketIpv4 = readString(source, PROBE_PARAM_FLOW_DNS_PACKET_IPV4);
  flowIds.dnsPacketIpv6 = readString(source, PROBE_PARAM_FLOW_DNS_PACKET_IPV6);
  flowIds.httpConnect = readString(source, PROBE_PARAM_FLOW_HTTP_CONNECT);
  flowIds.socks5 = readString(source, PROBE_PARAM_FLOW_SOCKS5);
  return flowIds;
}

function readFlatOrigin(source: Record<string, Object>): ProbeOriginConfig {
  const origin: ProbeOriginConfig = new ProbeOriginConfig();
  origin.host = readString(source, PROBE_PARAM_ORIGIN_HOST);
  origin.httpsPort = readNumber(source, PROBE_PARAM_ORIGIN_HTTPS_PORT);
  origin.tcpPort = readNumber(source, PROBE_PARAM_ORIGIN_TCP_PORT);
  origin.udpPort = readNumber(source, PROBE_PARAM_ORIGIN_UDP_PORT);
  origin.dnsPort = readNumber(source, PROBE_PARAM_ORIGIN_DNS_PORT);
  return origin;
}

function readFlatListeners(source: Record<string, Object>): ProbeLocalListenerConfig {
  const listeners: ProbeLocalListenerConfig = new ProbeLocalListenerConfig();
  listeners.httpConnectPort = readNumber(source, PROBE_PARAM_LOCAL_HTTP_CONNECT_PORT);
  listeners.socks5Port = readNumber(source, PROBE_PARAM_LOCAL_SOCKS5_PORT);
  return listeners;
}

function readFlowIds(source: Record<string, Object>): ProbeFlowIdSet {
  const flowIds: ProbeFlowIdSet = new ProbeFlowIdSet();
  flowIds.https = readString(source, 'https');
  flowIds.tcp = readString(source, 'tcp');
  flowIds.udpIpv4 = readString(source, 'udpIpv4');
  flowIds.udpIpv6 = readString(source, 'udpIpv6');
  flowIds.dnsLookup = readString(source, 'dnsLookup');
  flowIds.dnsPacketIpv4 = readString(source, 'dnsPacketIpv4');
  flowIds.dnsPacketIpv6 = readString(source, 'dnsPacketIpv6');
  flowIds.httpConnect = readString(source, 'httpConnect');
  flowIds.socks5 = readString(source, 'socks5');
  return flowIds;
}

function readOrigin(source: Record<string, Object>): ProbeOriginConfig {
  const origin: ProbeOriginConfig = new ProbeOriginConfig();
  origin.host = readString(source, 'host');
  origin.httpsPort = readNumber(source, 'httpsPort');
  origin.tcpPort = readNumber(source, 'tcpPort');
  origin.udpPort = readNumber(source, 'udpPort');
  origin.dnsPort = readNumber(source, 'dnsPort');
  return origin;
}

function readListeners(source: Record<string, Object>): ProbeLocalListenerConfig {
  const listeners: ProbeLocalListenerConfig = new ProbeLocalListenerConfig();
  listeners.httpConnectPort = readNumber(source, 'httpConnectPort');
  listeners.socks5Port = readNumber(source, 'socks5Port');
  return listeners;
}

function readObject(source: Record<string, Object>, key: string): Record<string, Object> {
  const value: Object = source[key];
  if (typeof value !== 'object' || value === null) {
    return {};
  }
  return value as Record<string, Object>;
}

function readString(source: Record<string, Object>, key: string): string {
  const value: Object = source[key];
  return typeof value === 'string' ? value : '';
}

function readNumber(source: Record<string, Object>, key: string): number {
  const value: Object = source[key];
  return typeof value === 'number' ? value : 0;
}
