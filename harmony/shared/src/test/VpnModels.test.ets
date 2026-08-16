import { describe, expect, it } from '@ohos/hypium';
import {
  VPN_FAILURE_CODES,
  VPN_RUNTIME_STATES,
  createTunHandle,
  createTunRuntimeSnapshot,
  createTunStartOptions,
  createVpnCaptureConfig,
  createVpnCounters,
  createVpnFailure,
  createVpnIngressTrace,
  createVpnRuntimeEvent,
  createVpnRuntimeSnapshot,
  createVpnStartRequest
} from '../../Index';
import { expectThrowsMessage } from './fakes/ProfileFakes';
import type {
  TunRuntimeSnapshot,
  VpnCaptureConfig,
  VpnRuntimeEvent,
  VpnRuntimeSnapshot
} from '../../Index';

function buildExactCaptureConfig(): VpnCaptureConfig {
  return createVpnCaptureConfig({
    addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
    routes: ['0.0.0.0/0', '::/0'],
    dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
    mtu: 1500,
    ipv4: true,
    ipv6: true,
    isBlocking: false,
    blockedApplications: ['com.github.kr328.clash.harmony'],
    trustedApplications: []
  });
}

function buildRuntimeSnapshot(sessionId: string): TunRuntimeSnapshot {
  return createTunRuntimeSnapshot({
    sessionId,
    state: 'READY',
    counters: createVpnCounters(7, 70, 9, 90),
    ingressTraces: [
      createVpnIngressTrace({
        sessionId,
        stage: 'TUN_READY',
        detail: 'ready',
        atMs: 22
      })
    ]
  });
}

export default function vpnModelsTestsuite() {
  describe('VpnModelsTest', () => {
    it('exposesExactLifecycleStatesAndFailureCodes', 0, () => {
      expect(VPN_RUNTIME_STATES.join(',')).assertEqual(
        'STOPPED,AWAITING_CONSENT,STARTING,RUNNING,RECOVERING,STOPPING,ERROR'
      );
      expect(VPN_FAILURE_CODES.includes('CONSENT_DENIED')).assertTrue();
      expect(VPN_FAILURE_CODES.includes('RECOVERY_EXHAUSTED')).assertTrue();
    });

    it('createsTheExactFullCaptureConfig', 0, () => {
      const config: VpnCaptureConfig = buildExactCaptureConfig();

      expect(config.addresses.join(',')).assertEqual('10.111.222.1/30,fd00:111:222::1/126');
      expect(config.routes.join(',')).assertEqual('0.0.0.0/0,::/0');
      expect(config.dnsServers.join(',')).assertEqual('10.111.222.2,fd00:111:222::2');
      expect(config.mtu).assertEqual(1500);
      expect(config.ipv4).assertTrue();
      expect(config.ipv6).assertTrue();
      expect(config.isBlocking).assertFalse();
      expect(config.blockedApplications.join(',')).assertEqual('com.github.kr328.clash.harmony');
    });

    it('clonesArraysAndSnapshotsAcrossPublicBoundaries', 0, () => {
      const addresses: string[] = ['10.111.222.1/30', 'fd00:111:222::1/126'];
      const routes: string[] = ['0.0.0.0/0', '::/0'];
      const dnsServers: string[] = ['10.111.222.2', 'fd00:111:222::2'];
      const blockedApplications: string[] = ['com.github.kr328.clash.harmony'];
      const config: VpnCaptureConfig = createVpnCaptureConfig({
        addresses,
        routes,
        dnsServers,
        mtu: 1500,
        ipv4: true,
        ipv6: true,
        isBlocking: false,
        blockedApplications,
        trustedApplications: []
      });
      addresses[0] = '198.51.100.1/30';
      routes[0] = '203.0.113.0/24';
      dnsServers[0] = '203.0.113.53';
      blockedApplications[0] = 'mutated.package';

      const tunSnapshot: TunRuntimeSnapshot = buildRuntimeSnapshot('session-1');
      const snapshot: VpnRuntimeSnapshot = createVpnRuntimeSnapshot({
        state: 'RUNNING',
        activeRequest: createVpnStartRequest('profile-1', 'version-1', 'session-1'),
        activeHandle: createTunHandle(17, 'vpn-1', 'session-1'),
        captureConfig: config,
        tunSnapshot,
        notificationActive: true,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      });
      const event: VpnRuntimeEvent = createVpnRuntimeEvent('SNAPSHOT', snapshot);
      if (snapshot.captureConfig !== null) {
        snapshot.captureConfig.addresses[0] = '198.51.100.9/30';
      }
      if (snapshot.tunSnapshot !== null) {
        snapshot.tunSnapshot.ingressTraces[0].detail = 'mutated';
      }

      expect(config.addresses.join(',')).assertEqual('10.111.222.1/30,fd00:111:222::1/126');
      expect(config.routes.join(',')).assertEqual('0.0.0.0/0,::/0');
      expect(config.dnsServers.join(',')).assertEqual('10.111.222.2,fd00:111:222::2');
      expect(config.blockedApplications.join(',')).assertEqual('com.github.kr328.clash.harmony');
      expect(event.snapshot.captureConfig?.addresses[0]).assertEqual('10.111.222.1/30');
      expect(event.snapshot.tunSnapshot?.ingressTraces[0].detail).assertEqual('ready');
    });

    it('rejectsBlankIdsAndUnknownFailureCodes', 0, () => {
      expectThrowsMessage(() => {
        createVpnStartRequest(' ', 'version-1', 'session-1');
      }, 'must not be blank');
      expectThrowsMessage(() => {
        createTunHandle(7, 'vpn-1', ' ');
      }, 'must not be blank');
      expectThrowsMessage(() => {
        createVpnFailure('UNLISTED_CODE', 'bad');
      }, 'allowlisted');
    });

    it('rejectsWrongPrefixesRoutesAndDns', 0, () => {
      expectThrowsMessage(() => {
        createVpnCaptureConfig({
          addresses: ['10.111.222.1/24', 'fd00:111:222::1/126'],
          routes: ['0.0.0.0/0', '::/0'],
          dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
          mtu: 1500,
          ipv4: true,
          ipv6: true,
          isBlocking: false,
          blockedApplications: ['com.github.kr328.clash.harmony'],
          trustedApplications: []
        });
      }, 'addresses');
      expectThrowsMessage(() => {
        createVpnCaptureConfig({
          addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
          routes: ['10.0.0.0/8', '::/0'],
          dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
          mtu: 1500,
          ipv4: true,
          ipv6: true,
          isBlocking: false,
          blockedApplications: ['com.github.kr328.clash.harmony'],
          trustedApplications: []
        });
      }, 'routes');
      expectThrowsMessage(() => {
        createVpnCaptureConfig({
          addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
          routes: ['0.0.0.0/0', '::/0'],
          dnsServers: ['10.111.222.3', 'fd00:111:222::2'],
          mtu: 1500,
          ipv4: true,
          ipv6: true,
          isBlocking: false,
          blockedApplications: ['com.github.kr328.clash.harmony'],
          trustedApplications: []
        });
      }, 'dns');
    });

    it('rejectsOutOfRangeMtuTrustedApplicationsAndMissingSelfExclusion', 0, () => {
      expectThrowsMessage(() => {
        createVpnCaptureConfig({
          addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
          routes: ['0.0.0.0/0', '::/0'],
          dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
          mtu: 1000,
          ipv4: true,
          ipv6: true,
          isBlocking: false,
          blockedApplications: ['com.github.kr328.clash.harmony'],
          trustedApplications: []
        });
      }, 'MTU');
      expectThrowsMessage(() => {
        createVpnCaptureConfig({
          addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
          routes: ['0.0.0.0/0', '::/0'],
          dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
          mtu: 1500,
          ipv4: true,
          ipv6: true,
          isBlocking: false,
          blockedApplications: ['com.github.kr328.clash.harmony'],
          trustedApplications: ['com.example.allowed']
        });
      }, 'trusted');
      expectThrowsMessage(() => {
        createVpnCaptureConfig({
          addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
          routes: ['0.0.0.0/0', '::/0'],
          dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
          mtu: 1500,
          ipv4: true,
          ipv6: true,
          isBlocking: false,
          blockedApplications: ['com.example.other'],
          trustedApplications: []
        });
      }, 'self-exclusion');
      expectThrowsMessage(() => {
        createTunStartOptions(buildExactCaptureConfig(), ['9.9.9.9']);
      }, 'DNS');
    });
  });
}
