import { describe, expect, it } from '@ohos/hypium';
import type { Want } from '@kit.AbilityKit';
import { isCompleteProbeCommand, type ProbeCommand } from '../main/ets/probe/ProbeModels';
import { readProbeCommandForTesting } from '../main/ets/entryability/ProbeAbility';

class FakeWantRecord {
  bundleName?: string = 'com.github.kr328.clash.harmony.trafficprobe';
  abilityName?: string = 'ProbeAbility';
  parameters?: Object;
}

class FlatParametersRecord {
  runId: string = 'run-opaque';
  sessionId: string = 'session-opaque';
  pinnedPublicKeyHash: string = 'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
  flowHttps: string = 'flow-https';
  flowTcp: string = 'flow-tcp';
  flowUdpIpv4: string = 'flow-udp4';
  flowUdpIpv6: string = 'flow-udp6';
  flowDnsLookup: string = 'flow-dns-lookup';
  flowDnsPacketIpv4: string = 'flow-dns4';
  flowDnsPacketIpv6: string = 'flow-dns6';
  flowHttpConnect: string = 'flow-http-connect';
  flowSocks5: string = 'flow-socks5';
  originHost: string = '192.168.1.10';
  originHttpsPort: number = 18443;
  originTcpPort: number = 18080;
  originUdpPort: number = 15353;
  originDnsPort: number = 15354;
  localHttpConnectPort: number = 7890;
  localSocks5Port: number = 7891;
}

class FlowIdsRecord {
  https: string = 'flow-https';
  tcp: string = 'flow-tcp';
  udpIpv4: string = 'flow-udp4';
  udpIpv6: string = 'flow-udp6';
  dnsLookup: string = 'flow-dns-lookup';
  dnsPacketIpv4: string = 'flow-dns4';
  dnsPacketIpv6: string = 'flow-dns6';
  httpConnect: string = 'flow-http-connect';
  socks5: string = 'flow-socks5';
}

class OriginRecord {
  host: string = '192.168.1.10';
  httpsPort: number = 18443;
  tcpPort: number = 18080;
  udpPort: number = 15353;
  dnsPort: number = 15354;
}

class LocalListenersRecord {
  httpConnectPort: number = 7890;
  socks5Port: number = 7891;
}

class NestedParametersRecord {
  runId: string = 'run-opaque';
  sessionId: string = 'session-opaque';
  pinnedCertificateHash: string = 'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
  flowIds: FlowIdsRecord = new FlowIdsRecord();
  lanOrigin: OriginRecord = new OriginRecord();
  localListeners: LocalListenersRecord = new LocalListenersRecord();
}

function createFlatWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  want.parameters = new FlatParametersRecord() as Object;
  return want as Want;
}

function createNestedFallbackWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  want.parameters = new NestedParametersRecord() as Object;
  return want as Want;
}

export default function probeAbilityTestsuite() {
  describe('ProbeAbilityTest', () => {
    it('parsesFlatWantExtrasIntoACompleteProbeCommand', 0, () => {
      const command: ProbeCommand = readProbeCommandForTesting(createFlatWant());

      expect(command.flowIds.https).assertEqual('flow-https');
      expect(command.flowIds.tcp).assertEqual('flow-tcp');
      expect(command.lanOrigin.host).assertEqual('192.168.1.10');
      expect(command.localListeners.httpConnectPort).assertEqual(7890);
      expect(command.pinnedCertificateHash).assertEqual('sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
      expect(isCompleteProbeCommand(command)).assertTrue();
    });

    it('keepsNestedWantFallbackForInProcessCompatibility', 0, () => {
      const command: ProbeCommand = readProbeCommandForTesting(createNestedFallbackWant());

      expect(command.flowIds.socks5).assertEqual('flow-socks5');
      expect(command.lanOrigin.dnsPort).assertEqual(15354);
      expect(command.localListeners.socks5Port).assertEqual(7891);
      expect(command.pinnedCertificateHash).assertEqual('sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
      expect(isCompleteProbeCommand(command)).assertTrue();
    });
  });
}
