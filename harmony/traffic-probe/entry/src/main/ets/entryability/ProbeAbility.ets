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
  const command: ProbeCommand = new ProbeCommand();
  const parameters: Record<string, Object> = want.parameters as Record<string, Object>;
  if (parameters === undefined) {
    return command;
  }

  command.runId = readString(parameters, 'runId');
  command.sessionId = readString(parameters, 'sessionId');
  command.pinnedCertificateHash = readString(parameters, 'pinnedCertificateHash');
  command.flowIds = readFlowIds(readObject(parameters, 'flowIds'));
  command.lanOrigin = readOrigin(readObject(parameters, 'lanOrigin'));
  command.localListeners = readListeners(readObject(parameters, 'localListeners'));
  return command;
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
