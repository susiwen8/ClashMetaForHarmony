import { describe, expect, it } from '@ohos/hypium';
import {
  VPN_FAILURE_CODES,
  VPN_RUNTIME_STATES,
  createTunHandle,
  createTunRuntimeFailure,
  createTunRuntimeSnapshot,
  createTunStartOptions,
  createVpnCaptureConfig,
  createVpnCounters,
  createVpnFailure,
  createVpnIngressTrace,
  createVpnRuntimeEvent,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  redactSensitiveText
} from '../../Index';
import { expectThrowsMessage } from './fakes/ProfileFakes';
import type {
  TunRuntimeFailure,
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
      expect(VPN_FAILURE_CODES.join(',')).assertEqual(
        'VPN_PERMISSION_DENIED,VPN_ALREADY_ACTIVE,VPN_PROFILE_UNAVAILABLE,VPN_CONFIG_INVALID,VPN_CREATE_FAILED,VPN_TUN_FD_INVALID,VPN_TUN_START_FAILED,VPN_SOCKET_PROTECT_FAILED,VPN_LOCAL_PORT_CONFLICT,VPN_BACKGROUND_TASK_FAILED,VPN_SYSTEM_REVOKED,VPN_STOP_FAILED'
      );
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

    it('clonesArraysAndSnapshotsAcrossPublicBoundariesWithoutExposingRawPlatformHandles', 0, () => {
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
      expect(`${JSON.stringify(snapshot)}${JSON.stringify(event)}`.includes('"fd"')).assertFalse();
      expect(`${JSON.stringify(snapshot)}${JSON.stringify(event)}`.includes('"vpnId"')).assertFalse();
      expect(event.snapshot.activeHandle?.sessionId).assertEqual('session-1');
    });

    it('rejectsBlankIdsAndPublicFailureCodesOutsideTheStableContract', 0, () => {
      expectThrowsMessage(() => {
        createVpnStartRequest(' ', 'version-1', 'session-1');
      }, 'must not be blank');
      expectThrowsMessage(() => {
        createTunHandle(7, 'vpn-1', ' ');
      }, 'must not be blank');
      expectThrowsMessage(() => {
        createVpnFailure('UNLISTED_CODE', 'bad');
      }, 'allowlisted');
      expectThrowsMessage(() => {
        createVpnFailure('NETWORK_LOST', 'bad');
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

    it('createsInternalTunRuntimeFailuresForRecoveryWithoutPollutingPublicVpnFailureCodes', 0, () => {
      const failure: TunRuntimeFailure = createTunRuntimeFailure('NETWORK_LOST', 'vpnId=vpn-9 deviceId=XYZ /Users/susiwen8/Documents/token.txt token=abc');

      expect(failure.code).assertEqual('NETWORK_LOST');
      expect(failure.detail.includes('vpn-9')).assertFalse();
      expect(failure.detail.includes('XYZ')).assertFalse();
      expect(failure.detail.includes('/Users/susiwen8/Documents')).assertFalse();
      expect(failure.detail.includes('abc')).assertFalse();
    });

    it('redactsSensitiveFailureAndIngressTraceDetailsUsingSharedSecretRedactorPlusVpnIdScrubbing', 0, () => {
      const rawDetail: string = 'vpnId=vpn-77 deviceId=dev-88 serial=ABC123 path=/Users/susiwen8/Documents/token.txt token=abc https://user:pw@example.com/profile';
      const failure = createVpnFailure('VPN_STOP_FAILED', rawDetail);
      const trace = createVpnIngressTrace({
        sessionId: 'session-9',
        stage: 'TUN_ERROR',
        detail: rawDetail,
        atMs: 99
      });
      const baselineRedacted: string = redactSensitiveText(rawDetail);

      expect(failure.detail === rawDetail).assertFalse();
      expect(trace.detail === rawDetail).assertFalse();
      expect(failure.detail.includes('/Users/susiwen8/Documents')).assertFalse();
      expect(failure.detail.includes('https://user:pw@example.com/profile')).assertFalse();
      expect(failure.detail.includes('token=abc')).assertFalse();
      expect(failure.detail.includes('vpn-77')).assertFalse();
      expect(failure.detail.includes('dev-88')).assertFalse();
      expect(trace.detail).assertEqual(failure.detail);
      expect(baselineRedacted === rawDetail).assertFalse();
    });

    it('redactsQuotedVpnAndDeviceAssignmentsWithoutRemovingTheKeys', 0, () => {
      const rawDetail: string = 'vpnId="vpn-77" deviceId: \'dev-88\' serial="ABC123"';
      const failure = createVpnFailure('VPN_STOP_FAILED', rawDetail);
      const trace = createVpnIngressTrace({
        sessionId: 'session-10',
        stage: 'TUN_ERROR',
        detail: rawDetail,
        atMs: 100
      });

      expect(failure.detail.includes('vpnId')).assertTrue();
      expect(failure.detail.includes('deviceId')).assertTrue();
      expect(failure.detail.includes('serial')).assertTrue();
      expect(failure.detail.includes('vpn-77')).assertFalse();
      expect(failure.detail.includes('dev-88')).assertFalse();
      expect(failure.detail.includes('ABC123')).assertFalse();
      expect(trace.detail).assertEqual(failure.detail);
    });
  });
}
