import { describe, expect, it } from '@ohos/hypium';
import type { Want } from '@kit.AbilityKit';
import { isCompleteProbeCommand, type ProbeCommand } from '../main/ets/probe/ProbeModels';
import { readProbeCommandForTesting } from '../main/ets/entryability/ProbeAbility';

class FakeWantRecord {
  bundleName?: string = 'com.cmfa.phase4.trafficprobe';
  abilityName?: string = 'ProbeAbility';
  parameters?: Object;
}

class FlatParametersRecord {
  runId: string = 'run-opaque';
  sessionId: string = 'session-opaque';
  captureMode: string = 'vpn';
  pinnedPublicKeyHash: string = 'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
  originCaPem: string = '-----BEGIN CERTIFICATE-----\nVEVTVA==\n-----END CERTIFICATE-----';
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
  externalOriginHost: string = '11.22.33.44';
  externalTcpHost: string = '55.66.77.88';
  externalOriginTcpPort: number = 80;
  externalOriginUdpPort: number = 20053;
  externalOriginDnsPort: number = 20054;
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

class ExternalOriginRecord {
  host: string = '11.22.33.44';
  tcpHost: string = '55.66.77.88';
  tcpPort: number = 80;
  udpPort: number = 20053;
  dnsPort: number = 20054;
}

class NestedParametersRecord {
  runId: string = 'run-opaque';
  sessionId: string = 'session-opaque';
  pinnedCertificateHash: string = 'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
  originCaPem: string = '-----BEGIN CERTIFICATE-----\nVEVTVA==\n-----END CERTIFICATE-----';
  flowIds: FlowIdsRecord = new FlowIdsRecord();
  lanOrigin: OriginRecord = new OriginRecord();
  externalOrigin: ExternalOriginRecord = new ExternalOriginRecord();
  localListeners: LocalListenersRecord = new LocalListenersRecord();
}

class NestedParametersWithoutExternalOriginRecord {
  runId: string = 'run-opaque';
  sessionId: string = 'session-opaque';
  pinnedCertificateHash: string = 'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
  originCaPem: string = '-----BEGIN CERTIFICATE-----\nVEVTVA==\n-----END CERTIFICATE-----';
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
  want.parameters = new NestedParametersWithoutExternalOriginRecord() as Object;
  return want as Want;
}

function createPartialExternalFlatWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new FlatParametersRecord();
  parameters.externalOriginDnsPort = 0;
  want.parameters = parameters as Object;
  return want as Want;
}

function createInvalidExternalFlatWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new FlatParametersRecord();
  parameters.externalOriginHost = 'origin.invalid';
  want.parameters = parameters as Object;
  return want as Want;
}

function createInvalidExternalTcpFlatWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new FlatParametersRecord();
  parameters.externalTcpHost = 'origin.invalid';
  want.parameters = parameters as Object;
  return want as Want;
}

function createLeadingZeroExternalFlatWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new FlatParametersRecord();
  parameters.externalOriginHost = '011.22.33.44';
  want.parameters = parameters as Object;
  return want as Want;
}

function createLeadingZeroExternalTcpFlatWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new FlatParametersRecord();
  parameters.externalTcpHost = '055.66.77.88';
  want.parameters = parameters as Object;
  return want as Want;
}

function createWhitespaceExternalFlatWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new FlatParametersRecord();
  parameters.externalOriginHost = ' 11.22.33.44 ';
  want.parameters = parameters as Object;
  return want as Want;
}

function createWhitespaceExternalTcpFlatWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new FlatParametersRecord();
  parameters.externalTcpHost = ' 55.66.77.88 ';
  want.parameters = parameters as Object;
  return want as Want;
}

function createMixedNonCanonicalExternalFlatWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new FlatParametersRecord();
  parameters.externalOriginHost = '11.022.33.44';
  want.parameters = parameters as Object;
  return want as Want;
}

function createMixedNonCanonicalExternalTcpFlatWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new FlatParametersRecord();
  parameters.externalTcpHost = '55.066.77.88';
  want.parameters = parameters as Object;
  return want as Want;
}

function createMixedInvalidExternalWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new NestedParametersRecord() as Object as Record<string, Object>;
  parameters.externalOriginHost = 'origin.invalid';
  parameters.externalTcpHost = '55.66.77.88';
  parameters.externalOriginTcpPort = 80;
  parameters.externalOriginUdpPort = 20053;
  parameters.externalOriginDnsPort = 20054;
  parameters.externalOrigin = new ExternalOriginRecord() as Object;
  want.parameters = parameters as Object;
  return want as Want;
}

function createNestedExternalWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new NestedParametersRecord();
  parameters.flowIds = new FlowIdsRecord();
  parameters.lanOrigin = new OriginRecord();
  parameters.externalOrigin = new ExternalOriginRecord();
  parameters.localListeners = new LocalListenersRecord();
  want.parameters = parameters as Object;
  return want as Want;
}

function createMixedExternalWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new NestedParametersRecord() as Object as Record<string, Object>;
  parameters.externalOriginHost = '11.22.33.44';
  parameters.externalTcpHost = '55.66.77.88';
  parameters.externalOriginTcpPort = 80;
  parameters.externalOriginUdpPort = 20053;
  parameters.externalOriginDnsPort = 0;
  const nestedExternal = new ExternalOriginRecord();
  nestedExternal.dnsPort = 20054;
  parameters.externalOrigin = nestedExternal as Object;
  want.parameters = parameters as Object;
  return want as Want;
}

function createMixedExternalWithLanLeakWant(): Want {
  const want: FakeWantRecord = new FakeWantRecord();
  const parameters = new NestedParametersWithoutExternalOriginRecord() as Object as Record<string, Object>;
  parameters.externalOriginHost = '';
  parameters.externalTcpHost = '';
  parameters.externalOriginTcpPort = 0;
  parameters.externalOriginUdpPort = 0;
  parameters.externalOriginDnsPort = 0;
  parameters.lanOrigin = new OriginRecord() as Object;
  want.parameters = parameters as Object;
  return want as Want;
}

export default function probeAbilityTestsuite() {
  describe('ProbeAbilityTest', () => {
    it('parsesFlatWantExtrasIntoACompleteProbeCommand', 0, () => {
      const command: ProbeCommand = readProbeCommandForTesting(createFlatWant());

      expect(command.flowIds.https).assertEqual('flow-https');
      expect(command.flowIds.tcp).assertEqual('flow-tcp');
      expect(command.lanOrigin.host).assertEqual('192.168.1.10');
      expect(command.externalOrigin.host).assertEqual('11.22.33.44');
      expect(command.externalOrigin.tcpHost).assertEqual('55.66.77.88');
      expect(command.externalOrigin.tcpPort).assertEqual(80);
      expect(command.externalOrigin.udpPort).assertEqual(20053);
      expect(command.externalOrigin.dnsPort).assertEqual(20054);
      expect(command.localListeners.httpConnectPort).assertEqual(7890);
      expect(command.captureMode).assertEqual('vpn');
      expect(command.pinnedCertificateHash).assertEqual('sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
      expect(command.originCaPem.startsWith('-----BEGIN CERTIFICATE-----')).assertTrue();
      expect(isCompleteProbeCommand(command)).assertTrue();
    });

    it('keepsNestedWantFallbackForInProcessCompatibility', 0, () => {
      const command: ProbeCommand = readProbeCommandForTesting(createNestedExternalWant());

      expect(command.flowIds.socks5).assertEqual('flow-socks5');
      expect(command.lanOrigin.dnsPort).assertEqual(15354);
      expect(command.externalOrigin.host).assertEqual('11.22.33.44');
      expect(command.externalOrigin.tcpHost).assertEqual('55.66.77.88');
      expect(command.externalOrigin.tcpPort).assertEqual(80);
      expect(command.externalOrigin.udpPort).assertEqual(20053);
      expect(command.externalOrigin.dnsPort).assertEqual(20054);
      expect(command.localListeners.socks5Port).assertEqual(7891);
      expect(command.captureMode).assertEqual('baseline');
      expect(command.pinnedCertificateHash).assertEqual('sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
      expect(command.originCaPem.endsWith('-----END CERTIFICATE-----')).assertTrue();
      expect(isCompleteProbeCommand(command)).assertTrue();
    });

    it('fillsMixedExternalOriginOnlyFromExternalOriginFieldsAndNeverFromLanOrigin', 0, () => {
      const mixed: ProbeCommand = readProbeCommandForTesting(createMixedExternalWant());
      expect(mixed.externalOrigin.host).assertEqual('11.22.33.44');
      expect(mixed.externalOrigin.tcpHost).assertEqual('55.66.77.88');
      expect(mixed.externalOrigin.tcpPort).assertEqual(80);
      expect(mixed.externalOrigin.udpPort).assertEqual(20053);
      expect(mixed.externalOrigin.dnsPort).assertEqual(20054);
      expect(isCompleteProbeCommand(mixed)).assertTrue();

      const leaked: ProbeCommand = readProbeCommandForTesting(createMixedExternalWithLanLeakWant());
      expect(leaked.externalOrigin.host).assertEqual('');
      expect(leaked.externalOrigin.tcpHost).assertEqual('');
      expect(leaked.externalOrigin.tcpPort).assertEqual(0);
      expect(leaked.externalOrigin.udpPort).assertEqual(0);
      expect(leaked.externalOrigin.dnsPort).assertEqual(0);
      expect(isCompleteProbeCommand(leaked)).assertFalse();
    });

    it('failsClosedWhenExternalOriginIsMissingPartialOrInvalid', 0, () => {
      const missing: ProbeCommand = readProbeCommandForTesting(createNestedFallbackWant());
      expect(missing.externalOrigin.host).assertEqual('');
      expect(missing.externalOrigin.tcpHost).assertEqual('');
      expect(missing.externalOrigin.tcpPort).assertEqual(0);
      expect(missing.externalOrigin.udpPort).assertEqual(0);
      expect(missing.externalOrigin.dnsPort).assertEqual(0);
      expect(isCompleteProbeCommand(missing)).assertFalse();

      const partial: ProbeCommand = readProbeCommandForTesting(createPartialExternalFlatWant());
      expect(partial.externalOrigin.dnsPort).assertEqual(0);
      expect(isCompleteProbeCommand(partial)).assertFalse();

      const invalid: ProbeCommand = readProbeCommandForTesting(createInvalidExternalFlatWant());
      expect(invalid.externalOrigin.host).assertEqual('origin.invalid');
      expect(isCompleteProbeCommand(invalid)).assertFalse();

      const invalidTcpHost: ProbeCommand = readProbeCommandForTesting(createInvalidExternalTcpFlatWant());
      expect(invalidTcpHost.externalOrigin.tcpHost).assertEqual('origin.invalid');
      expect(isCompleteProbeCommand(invalidTcpHost)).assertFalse();

      const mixedInvalid: ProbeCommand = readProbeCommandForTesting(createMixedInvalidExternalWant());
      expect(mixedInvalid.externalOrigin.host).assertEqual('origin.invalid');
      expect(mixedInvalid.externalOrigin.tcpHost).assertEqual('55.66.77.88');
      expect(mixedInvalid.externalOrigin.tcpPort).assertEqual(80);
      expect(mixedInvalid.externalOrigin.udpPort).assertEqual(20053);
      expect(mixedInvalid.externalOrigin.dnsPort).assertEqual(20054);
      expect(isCompleteProbeCommand(mixedInvalid)).assertFalse();
    });

    it('returnsExternalOriginObjectsIndependentFromInputMutation', 0, () => {
      const want: Want = createFlatWant();
      const parameters = want.parameters as Object as FlatParametersRecord;
      const command: ProbeCommand = readProbeCommandForTesting(want);

      parameters.externalOriginHost = '55.66.77.88';
      parameters.externalTcpHost = '66.77.88.99';
      parameters.externalOriginTcpPort = 1;
      parameters.externalOriginUdpPort = 2;
      parameters.externalOriginDnsPort = 3;

      expect(command.externalOrigin.host).assertEqual('11.22.33.44');
      expect(command.externalOrigin.tcpHost).assertEqual('55.66.77.88');
      expect(command.externalOrigin.tcpPort).assertEqual(80);
      expect(command.externalOrigin.udpPort).assertEqual(20053);
      expect(command.externalOrigin.dnsPort).assertEqual(20054);
    });

    it('failsClosedWhenExternalOriginIpv4FieldsAreNotCanonicalExactDottedDecimal', 0, () => {
      const leadingZero: ProbeCommand = readProbeCommandForTesting(createLeadingZeroExternalFlatWant());
      expect(leadingZero.externalOrigin.host).assertEqual('011.22.33.44');
      expect(isCompleteProbeCommand(leadingZero)).assertFalse();

      const leadingZeroTcpHost: ProbeCommand = readProbeCommandForTesting(createLeadingZeroExternalTcpFlatWant());
      expect(leadingZeroTcpHost.externalOrigin.tcpHost).assertEqual('055.66.77.88');
      expect(isCompleteProbeCommand(leadingZeroTcpHost)).assertFalse();

      const whitespace: ProbeCommand = readProbeCommandForTesting(createWhitespaceExternalFlatWant());
      expect(whitespace.externalOrigin.host).assertEqual(' 11.22.33.44 ');
      expect(isCompleteProbeCommand(whitespace)).assertFalse();

      const whitespaceTcpHost: ProbeCommand = readProbeCommandForTesting(createWhitespaceExternalTcpFlatWant());
      expect(whitespaceTcpHost.externalOrigin.tcpHost).assertEqual(' 55.66.77.88 ');
      expect(isCompleteProbeCommand(whitespaceTcpHost)).assertFalse();

      const mixedNonCanonical: ProbeCommand = readProbeCommandForTesting(createMixedNonCanonicalExternalFlatWant());
      expect(mixedNonCanonical.externalOrigin.host).assertEqual('11.022.33.44');
      expect(isCompleteProbeCommand(mixedNonCanonical)).assertFalse();

      const mixedNonCanonicalTcpHost: ProbeCommand = readProbeCommandForTesting(createMixedNonCanonicalExternalTcpFlatWant());
      expect(mixedNonCanonicalTcpHost.externalOrigin.tcpHost).assertEqual('55.066.77.88');
      expect(isCompleteProbeCommand(mixedNonCanonicalTcpHost)).assertFalse();
    });

    it('failsClosedWhenExternalOriginIpv4FieldsAreNotPublicGlobalUnicast', 0, () => {
      const rejected: Array<string> = [
        '10.0.0.1',
        '172.16.0.1',
        '192.168.1.1',
        '100.64.0.1',
        '169.254.1.1',
        '192.0.2.1',
        '198.18.0.1',
        '198.51.100.1',
        '203.0.113.1',
        '224.0.0.1'
      ];
      for (let index = 0; index < rejected.length; index += 1) {
        const parameters: FlatParametersRecord = new FlatParametersRecord();
        parameters.externalOriginHost = rejected[index];
        const want: FakeWantRecord = new FakeWantRecord();
        want.parameters = parameters as Object;
        const command: ProbeCommand = readProbeCommandForTesting(want as Want);
        expect(isCompleteProbeCommand(command)).assertFalse();

        const tcpParameters: FlatParametersRecord = new FlatParametersRecord();
        tcpParameters.externalTcpHost = rejected[index];
        const tcpWant: FakeWantRecord = new FakeWantRecord();
        tcpWant.parameters = tcpParameters as Object;
        const tcpCommand: ProbeCommand = readProbeCommandForTesting(tcpWant as Want);
        expect(isCompleteProbeCommand(tcpCommand)).assertFalse();
      }
    });
  });
}
