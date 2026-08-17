import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const modulePath = new URL('../bin/run-phase4-device-proof.mjs', import.meta.url);
const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));

function uuid() {
  return crypto.randomUUID();
}

function digest(seed) {
  return crypto.createHash('sha256').update(seed).digest('hex');
}

function shortHash(value) {
  let hashValue = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hashValue ^= value.charCodeAt(index);
    hashValue = Math.imul(hashValue, 16777619);
  }
  return (hashValue >>> 0).toString(16).padStart(8, '0');
}

function createDnsPacketHash(runId, flowId) {
  const label = `${shortHash(runId)}-${shortHash(flowId)}.invalid`;
  const header = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
  const bytes = [];
  for (const segment of label.split('.')) {
    bytes.push(segment.length);
    for (let index = 0; index < segment.length; index += 1) {
      bytes.push(segment.charCodeAt(index) & 0xff);
    }
  }
  bytes.push(0x00, 0x00, 0x01, 0x00, 0x01);
  return digest(Buffer.from(header.concat(bytes)));
}

function createLinkedEvidence() {
  const runId = uuid();
  const sessionId = uuid();
  const flowId = uuid();
  const localHttpFlowId = uuid();
  const localSocksFlowId = uuid();
  const markerHash = digest(`cmfa-${flowId}`);
  const dnsHash = createDnsPacketHash(runId, flowId);
  return {
    runId,
    origin: {
      runId,
      observations: [
        { protocol: 'https', runId, sessionId, flowId, responseBodySha256: digest('https') },
        { protocol: 'tcp', runId, sessionId, flowId, payloadSha256: digest('tcp'), correlationHash: markerHash },
        { protocol: 'udp', runId, sessionId, flowId, payloadSha256: digest('udp'), correlationHash: markerHash, dnsShaped: false }
      ]
    },
    probe: {
      version: '1.0.0',
      result: 'pass',
      runId,
      sessionId,
      records: [
        { flowId: uuid(), stepId: 'https', ingressExpectation: 'origin-https', outcome: 'pass', transport: 'https', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1, statusCode: 200 },
        { flowId, stepId: 'tcp', ingressExpectation: 'tun', outcome: 'pass', transport: 'tcp', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId, stepId: 'udp-ipv4', ingressExpectation: 'tun', outcome: 'pass', transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId, stepId: 'dns-packet-ipv4', ingressExpectation: 'tun', outcome: 'pass', transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId: localHttpFlowId, stepId: 'http-connect', ingressExpectation: 'local-http-connect-listener', outcome: 'pass', transport: 'tcp', targetPort: 7890, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId: localSocksFlowId, stepId: 'socks5', ingressExpectation: 'local-socks5-listener', outcome: 'pass', transport: 'tcp', targetPort: 7891, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 }
      ],
      failures: []
    },
    runtime: {
      sessionId,
      counters: { rxPackets: 10, txPackets: 10, rxBytes: 1000, txBytes: 1000 },
      records: [
        { sequence: 1, kind: 'traffic', sessionIdHash: runnerHash(sessionId), ingress: 'tun', traceAlias: 'trace-1', coreAlias: '', flowIdHash: markerHash, protocol: 'tcp', hashedTuple: 'hash-1', correlationHash: markerHash, linkageStatus: 'linked', counterSnapshot: { rxPackets: 10, txPackets: 10, rxBytes: 1000, txBytes: 1000 }, detail: 'tcp' },
        { sequence: 2, kind: 'traffic', sessionIdHash: runnerHash(sessionId), ingress: 'tun', traceAlias: 'trace-2', coreAlias: '', flowIdHash: markerHash, protocol: 'udp', hashedTuple: 'hash-2', correlationHash: markerHash, linkageStatus: 'linked', counterSnapshot: { rxPackets: 10, txPackets: 10, rxBytes: 1000, txBytes: 1000 }, detail: 'udp' },
        { sequence: 3, kind: 'traffic', sessionIdHash: runnerHash(sessionId), ingress: 'tun', traceAlias: 'trace-3', coreAlias: '', flowIdHash: dnsHash, protocol: 'dns', hashedTuple: 'hash-3', correlationHash: dnsHash, linkageStatus: 'linked', counterSnapshot: { rxPackets: 10, txPackets: 10, rxBytes: 1000, txBytes: 1000 }, detail: 'dns' }
      ]
    },
    packages: {
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', hapSha256: digest('production'), signatureSha256: digest('signature:p') },
      probe: { bundleName: 'com.github.kr328.clash.harmony.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('signature:q') }
    },
    lifecycle: {
      launcherContinuity: true,
      screenOffContinuity: true,
      vpnIndicatorVisible: true,
      ongoingNotificationVisible: true,
      networkLossRecovery: true,
      stopCleanup: true,
      networkingRestored: true
    }
  };
}

function runnerHash(value) {
  return shortHash(String(value));
}

function legacyRunnerHash(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex').slice(0, 16);
}

function createNetworkLayout({
  wifiState = 'on',
  mobileState = 'off',
  wifiAttributes = {},
  mobileAttributes = {}
} = {}) {
  return {
    root: {
      attributes: {},
      children: [
        {
          attributes: {
            resourceName: 'wifi_switch',
            text: 'Wi-Fi',
            checked: wifiState === 'on' ? 'true' : 'false',
            ...wifiAttributes
          },
          bounds: { left: 10, top: 10, right: 30, bottom: 30 }
        },
        {
          attributes: {
            resourceName: 'mobile_data_switch',
            text: 'Mobile data',
            checked: mobileState === 'on' ? 'true' : 'false',
            ...mobileAttributes
          },
          bounds: { left: 40, top: 10, right: 60, bottom: 30 }
        }
      ]
    }
  };
}

function createLayoutExecHarness({ layouts = [], screenOutputs = [] } = {}) {
  const queuedLayouts = [...layouts];
  const queuedScreenOutputs = [...screenOutputs];
  const calls = [];
  return {
    calls,
    execImpl: async (_command, args) => {
      calls.push(args.join(' '));
      const joined = args.join(' ');
      if (joined.includes('dumpLayout')) {
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      if (joined.includes(' file recv ') && joined.includes('cmfa-layout-')) {
        const localPath = args.at(-1);
        const nextLayout = queuedLayouts.shift();
        assert.ok(nextLayout, `expected queued layout for ${joined}`);
        await fs.writeFile(localPath, `${JSON.stringify(nextLayout)}\n`, 'utf8');
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      if (joined.includes('hidumper')) {
        const nextOutput = queuedScreenOutputs.shift();
        assert.notEqual(nextOutput, undefined, `expected queued screen output for ${joined}`);
        return { exitCode: 0, stdout: nextOutput, stderr: '' };
      }
      if (joined.includes('uiInput click') || joined.includes('uiInput keyEvent Power')) {
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      throw new Error(`unexpected command ${joined}`);
    }
  };
}

test('phase4 runner correlates direct reachability, package identity, origin, probe, and tun evidence before pass', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  const result = runner.correlatePhase4Evidence(evidence);

  assert.equal(result.result, 'pass');
  assert.equal(result.failures.length, 0);
  assert.equal(result.traffic.tcp.captureTrace.ingress, 'tun');
  assert.equal(result.traffic.udp.captureTrace.ingress, 'tun');
  assert.equal(result.traffic.dns.captureTrace.ingress, 'tun');
  assert.equal(result.localEvidence.http.ingress, 'local-http');
  assert.equal(result.localEvidence.socks.ingress, 'local-socks');
});

test('phase4 runner fail-closes on counter-only, local substitution, missing reachability, or shared bundle identity', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  evidence.probe.records[1].outcome = 'fail';
  evidence.runtime.records = [];
  evidence.packages.probe.hapSha256 = evidence.packages.production.hapSha256;
  evidence.probe.records[1].ingressExpectation = 'local-http';

  const result = runner.correlatePhase4Evidence(evidence);
  assert.equal(result.result, 'incomplete');
  assert.match(result.failures.map((entry) => entry.code).join(','), /ORIGIN_REACHABILITY_NOT_PROVEN|TUN_LINK_MISSING|SHARED_BUNDLE_IDENTITY|GLOBAL_INGRESS_INVALID/u);
});

test('phase4 runner parse errors still write an atomic incomplete proof at the canonical path', async () => {
  const runner = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-runner-'));
  const outputPath = path.join(tempRoot, 'phase4-device-proof.json');
  const proof = await runner.writeArgumentErrorProof({
    outputPath,
    detail: 'Missing --production-hap.'
  });

  assert.equal(proof.result, 'incomplete');
  assert.equal(proof.outputPath, 'harmony/artifacts/phase4-device-proof.json');
  assert.match(proof.failures.map((entry) => entry.code).join(','), /ARGUMENT_INVALID/u);
  assert.deepEqual(JSON.parse(await fs.readFile(outputPath, 'utf8')), proof);
});

test('phase4 runner discovers toolchain and target state before any install, and stops early when direct baseline is not proven', async () => {
  const runner = await import(modulePath);
  const calls = [];
  const outputPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-baseline-${process.pid}.json`);
  const result = await runner.runPhase4DeviceProof({
    outputPath,
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => {
      calls.push('inspectPackages');
      return {
        result: 'pass',
        production: { bundleName: 'com.github.kr328.clash.harmony', hapSha256: digest('production'), signatureSha256: digest('p-sign') },
        probe: { bundleName: 'com.github.kr328.clash.harmony.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
      };
    },
    execImpl: async (_command, args) => {
      calls.push(args.join(' '));
      const joined = args.join(' ');
      if (joined === 'help') {
        return { exitCode: 0, stdout: 'file recv -b\ninstall\nshell\nlist targets\n', stderr: '' };
      }
      if (joined === 'list targets') {
        return { exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
      }
      if (joined.includes('param get const.product.model')) {
        return { exitCode: 0, stdout: 'Mate 70\n', stderr: '' };
      }
      if (joined.includes('param get const.product.name')) {
        return { exitCode: 0, stdout: 'harmony\n', stderr: '' };
      }
      if (joined.includes('param get const.product.software.version')) {
        return { exitCode: 0, stdout: 'HarmonyOS 6.0.1.123\n', stderr: '' };
      }
      if (joined.includes('param get const.product.cpu.abilist')) {
        return { exitCode: 0, stdout: 'arm64-v8a\n', stderr: '' };
      }
      if (joined.includes('param get const.ohos.apiversion')) {
        return { exitCode: 0, stdout: '20\n', stderr: '' };
      }
      if (joined.includes('install -r')) {
        return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      }
      if (joined.includes('force-stop') || joined.includes('power-shell') || joined.includes('uitest')) {
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      throw new Error(`unexpected command ${joined}`);
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    runBaselineProbeImpl: async () => {
      calls.push('baselineProbe');
      return { result: 'fail' };
    },
    startOriginImpl: async () => {
      calls.push('startOrigin');
      return { close: async () => { calls.push('origin.close'); } };
    },
    stopVpnImpl: async () => { calls.push('stopVpn'); },
    restoreNetworkStateImpl: async () => { calls.push('restoreNetwork'); },
    restoreScreenStateImpl: async () => { calls.push('restoreScreen'); }
  });

  assert.equal(result.result, 'incomplete');
  assert.match(result.failures.map((entry) => entry.code).join(','), /ORIGIN_REACHABILITY_NOT_PROVEN/u);
  assert.deepEqual(calls.slice(0, 3), ['inspectPackages', 'help', 'list targets']);
  const productionInstallIndex = calls.findIndex((entry) => entry.includes('install -r') && entry.includes('com.github.kr328.clash.harmony') === false);
  const probeInstallIndex = calls.findLastIndex((entry) => entry.includes('install -r'));
  const baselineIndex = calls.indexOf('baselineProbe');
  assert.equal(productionInstallIndex >= 0, true);
  assert.equal(probeInstallIndex > productionInstallIndex, true);
  assert.equal(baselineIndex > probeInstallIndex, true);
  assert.equal(calls.includes('origin.close'), true);
  assert.equal(calls.includes('restoreNetwork'), true);
  assert.equal(calls.includes('restoreScreen'), true);
});

test('phase4 runner requires hdc help to confirm file recv -b and exposes exact bundle pull commands', async () => {
  const runner = await import(modulePath);
  const outputPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-help-${process.pid}.json`);
  const helpFail = await runner.runPhase4DeviceProof({
    outputPath,
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => ({
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', hapSha256: digest('production'), signatureSha256: digest('p-sign') },
      probe: { bundleName: 'com.github.kr328.clash.harmony.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
    }),
    execImpl: async (_command, args) => {
      if (['help', '-h', '--help'].includes(args.join(' '))) {
        return { exitCode: 0, stdout: 'install\nshell\nlist targets\n', stderr: '' };
      }
      throw new Error(`unexpected ${args.join(' ')}`);
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath })
  });
  assert.equal(helpFail.result, 'incomplete');
  assert.match(helpFail.failures.map((entry) => entry.code).join(','), /HDC_HELP_UNSUPPORTED/u);

  assert.deepEqual(
    runner.buildBundleEvidencePullArgs({
      target: 'SERIAL123',
      bundleName: 'com.github.kr328.clash.harmony.trafficprobe',
      remotePath: '/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json',
      localPath: '/tmp/probe.json'
    }),
    ['-t', 'SERIAL123', 'file', 'recv', '-b', 'com.github.kr328.clash.harmony.trafficprobe', '/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json', '/tmp/probe.json']
  );
});

test('phase4 runner semantic layout selection fails closed on ambiguity and unsupported network controls', async () => {
  const runner = await import(modulePath);
  const layout = {
    root: {
      attributes: {},
      children: [
        { attributes: { id: 'home.vpn.primary', text: 'Start VPN global capture' }, bounds: { left: 0, top: 0, right: 10, bottom: 10 } },
        { attributes: { id: 'home.vpn.primary', text: 'Start VPN global capture' }, bounds: { left: 12, top: 0, right: 20, bottom: 10 } }
      ]
    }
  };
  assert.throws(
    () => runner.selectUniqueLayoutNode(layout, { ids: ['home.vpn.primary'] }),
    /UI_AUTOMATION_UNSUPPORTED/u
  );

  const outputPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-network-${process.pid}.json`);
  const unsupported = await runner.runPhase4DeviceProof({
    outputPath,
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => ({
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', hapSha256: digest('production'), signatureSha256: digest('p-sign') },
      probe: { bundleName: 'com.github.kr328.clash.harmony.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
    }),
    execImpl: async (_command, args) => {
      const joined = args.join(' ');
      if (joined === 'help') return { exitCode: 0, stdout: 'file recv -b\ninstall\nshell\nlist targets\n', stderr: '' };
      if (joined === 'list targets') return { exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
      if (joined.includes('param get const.product.model')) return { exitCode: 0, stdout: 'Mate 70\n', stderr: '' };
      if (joined.includes('param get const.product.name')) return { exitCode: 0, stdout: 'harmony\n', stderr: '' };
      if (joined.includes('param get const.product.software.version')) return { exitCode: 0, stdout: 'HarmonyOS 6.0.1.123\n', stderr: '' };
      if (joined.includes('param get const.product.cpu.abilist')) return { exitCode: 0, stdout: 'arm64-v8a\n', stderr: '' };
      if (joined.includes('param get const.ohos.apiversion')) return { exitCode: 0, stdout: '20\n', stderr: '' };
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      return { exitCode: 0, stdout: '', stderr: '' };
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    startOriginImpl: async () => ({ close: async () => {} }),
    runBaselineProbeImpl: async () => ({ result: 'pass' }),
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: false }),
    restoreNetworkStateImpl: async () => {},
    restoreScreenStateImpl: async () => {},
    stopVpnImpl: async () => {}
  });
  assert.equal(unsupported.result, 'incomplete');
  assert.match(unsupported.failures.map((entry) => entry.code).join(','), /NETWORK_RECOVERY_NOT_PROVEN/u);
});

test('phase4 runner normalizes raw probe records, runtime journal records, and origin observations before correlation', async () => {
  const runner = await import(modulePath);
  const runId = uuid();
  const sessionId = uuid();
  const flowId = uuid();
  const markerHash = digest(`cmfa-${flowId}`);
  const dnsHash = createDnsPacketHash(runId, flowId);
  const normalized = runner.normalizePhase4CollectedEvidence({
    runId,
    origin: {
      started: { sessionId: uuid() },
      observations: [
        { protocol: 'https', runId, sessionId, flowId, responseBodySha256: digest('https') },
        { protocol: 'tcp', runId, sessionId, flowId, payloadSha256: digest('tcp'), correlationHash: markerHash },
        { protocol: 'udp', runId, sessionId, flowId, payloadSha256: digest('udp'), correlationHash: markerHash, dnsShaped: false }
      ]
    },
    probe: {
      version: '1.0.0',
      result: 'pass',
      runId,
      sessionId,
      records: [
        { flowId, stepId: 'https', ingressExpectation: 'origin-https', outcome: 'pass', transport: 'https', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 10, bytesReceived: 20, statusCode: 200 },
        { flowId, stepId: 'tcp', ingressExpectation: 'tun', outcome: 'pass', transport: 'tcp', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 10, bytesReceived: 20 },
        { flowId, stepId: 'udp-ipv4', ingressExpectation: 'tun', outcome: 'pass', transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 10, bytesReceived: 20 },
        { flowId, stepId: 'dns-packet-ipv4', ingressExpectation: 'tun', outcome: 'pass', transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 10, bytesReceived: 20 },
        { flowId: uuid(), stepId: 'http-connect', ingressExpectation: 'local-http-connect-listener', outcome: 'pass', transport: 'tcp', targetPort: 7890, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 10, bytesReceived: 20 },
        { flowId: uuid(), stepId: 'socks5', ingressExpectation: 'local-socks5-listener', outcome: 'pass', transport: 'tcp', targetPort: 7891, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 10, bytesReceived: 20 }
      ],
      failures: []
    },
    runtime: {
      sessionAlias: 'session-a',
      counters: { rxPackets: 4, txPackets: 4, rxBytes: 40, txBytes: 40 },
      records: [
        {
          sequence: 1,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: markerHash,
          sessionIdHash: runner.hashOpaqueCorrelationId(sessionId),
          traceAlias: 'trace-a',
          coreAlias: '',
          protocol: 'tcp',
          hashedTuple: 'hash-a',
          correlationHash: markerHash,
          detail: 'tcp',
          counterSnapshot: { rxPackets: 4, txPackets: 4, rxBytes: 40, txBytes: 40 }
        },
        {
          sequence: 2,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: markerHash,
          sessionIdHash: runner.hashOpaqueCorrelationId(sessionId),
          traceAlias: 'trace-b',
          coreAlias: '',
          protocol: 'udp',
          hashedTuple: 'hash-b',
          correlationHash: markerHash,
          detail: 'udp',
          counterSnapshot: { rxPackets: 4, txPackets: 4, rxBytes: 40, txBytes: 40 }
        },
        {
          sequence: 3,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: dnsHash,
          sessionIdHash: runner.hashOpaqueCorrelationId(sessionId),
          traceAlias: 'trace-c',
          coreAlias: '',
          protocol: 'dns',
          hashedTuple: 'hash-c',
          correlationHash: dnsHash,
          detail: 'dns',
          counterSnapshot: { rxPackets: 4, txPackets: 4, rxBytes: 40, txBytes: 40 }
        }
      ]
    },
    packages: {
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', hapSha256: digest('production'), signatureSha256: digest('signature:p') },
      probe: { bundleName: 'com.github.kr328.clash.harmony.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('signature:q') }
    },
    lifecycle: {
      launcherContinuity: true,
      screenOffContinuity: true,
      vpnIndicatorVisible: true,
      ongoingNotificationVisible: true,
      networkLossRecovery: true,
      stopCleanup: true,
      networkingRestored: true
    }
  });

  assert.equal(normalized.probe.directReachability.result, 'pass');
  assert.equal(normalized.probe.global.tcp.flowId, flowId);
  assert.equal(normalized.runtime.linkedRecords[0].flowIdHash, markerHash);
  assert.equal(normalized.origin.observations[0].flowId, flowId);
  const proof = runner.correlatePhase4Evidence(normalized);
  assert.equal(proof.result, 'pass');
});

test('phase4 runner hashOpaqueCorrelationId matches the ArkTS FNV-1a UTF-16 contract and rejects legacy SHA session hashes', async () => {
  const runner = await import(modulePath);
  const sessionId = 'phase4-session-机密-🚀';
  const sessionUuid = '123e4567-e89b-12d3-a456-426614174000';
  const runId = uuid();
  const flowId = uuid();
  const markerHash = digest(`cmfa-${flowId}`);
  const expectedHash = '4a0a38ca';
  const expectedUuidHash = 'd02023ff';
  assert.equal(runnerHash(sessionId), expectedHash);
  assert.equal(runner.hashOpaqueCorrelationId(sessionId), expectedHash);
  assert.equal(runnerHash(sessionUuid), expectedUuidHash);
  assert.equal(runner.hashOpaqueCorrelationId(sessionUuid), expectedUuidHash);

  const normalized = runner.normalizePhase4CollectedEvidence({
    runId,
    origin: {
      observations: [
        { protocol: 'https', runId, sessionId: sessionUuid, flowId, responseBodySha256: digest('https') },
        { protocol: 'tcp', runId, sessionId: sessionUuid, flowId, payloadSha256: digest('tcp'), correlationHash: markerHash },
        { protocol: 'udp', runId, sessionId: sessionUuid, flowId, payloadSha256: digest('udp'), correlationHash: markerHash, dnsShaped: false }
      ]
    },
    probe: {
      version: '1.0.0',
      result: 'pass',
      runId,
      sessionId: sessionUuid,
      records: [
        { flowId, stepId: 'https', ingressExpectation: 'origin-https', outcome: 'pass', transport: 'https', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1, statusCode: 200 },
        { flowId, stepId: 'tcp', ingressExpectation: 'tun', outcome: 'pass', transport: 'tcp', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId, stepId: 'udp-ipv4', ingressExpectation: 'tun', outcome: 'pass', transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId, stepId: 'dns-packet-ipv4', ingressExpectation: 'tun', outcome: 'pass', transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId: uuid(), stepId: 'http-connect', ingressExpectation: 'local-http-connect-listener', outcome: 'pass', transport: 'tcp', targetPort: 7890, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId: uuid(), stepId: 'socks5', ingressExpectation: 'local-socks5-listener', outcome: 'pass', transport: 'tcp', targetPort: 7891, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 }
      ],
      failures: []
    },
    runtime: {
      counters: { rxPackets: 7, txPackets: 7, rxBytes: 70, txBytes: 70 },
      records: [
        {
          sequence: 1,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: markerHash,
          sessionIdHash: expectedUuidHash,
          traceAlias: 'trace-a',
          coreAlias: '',
          protocol: 'tcp',
          hashedTuple: 'hash-a',
          correlationHash: markerHash,
          detail: 'tcp',
          counterSnapshot: { rxPackets: 7, txPackets: 7, rxBytes: 70, txBytes: 70 }
        },
        {
          sequence: 2,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: markerHash,
          sessionIdHash: expectedUuidHash,
          traceAlias: 'trace-b',
          coreAlias: '',
          protocol: 'udp',
          hashedTuple: 'hash-b',
          correlationHash: markerHash,
          detail: 'udp',
          counterSnapshot: { rxPackets: 7, txPackets: 7, rxBytes: 70, txBytes: 70 }
        },
        {
          sequence: 3,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: createDnsPacketHash(runId, flowId),
          sessionIdHash: expectedUuidHash,
          traceAlias: 'trace-c',
          coreAlias: '',
          protocol: 'dns',
          hashedTuple: 'hash-c',
          correlationHash: createDnsPacketHash(runId, flowId),
          detail: 'dns',
          counterSnapshot: { rxPackets: 7, txPackets: 7, rxBytes: 70, txBytes: 70 }
        }
      ]
    },
    packages: {
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', hapSha256: digest('production'), signatureSha256: digest('signature:p') },
      probe: { bundleName: 'com.github.kr328.clash.harmony.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('signature:q') }
    },
    lifecycle: {
      launcherContinuity: true,
      screenOffContinuity: true,
      vpnIndicatorVisible: true,
      ongoingNotificationVisible: true,
      networkLossRecovery: true,
      stopCleanup: true,
      networkingRestored: true
    }
  });

  assert.equal(normalized.runtime.linkedRecords[0].sessionIdHash, expectedUuidHash);
  assert.equal(runner.correlatePhase4Evidence(normalized).result, 'pass');

  normalized.runtime.records[0].sessionIdHash = legacyRunnerHash(sessionUuid);
  normalized.runtime.records[1].sessionIdHash = legacyRunnerHash(sessionUuid);
  normalized.runtime.records[2].sessionIdHash = legacyRunnerHash(sessionUuid);
  const legacyMismatch = runner.correlatePhase4Evidence(runner.normalizePhase4CollectedEvidence(normalized));
  assert.equal(legacyMismatch.result, 'incomplete');
  assert.match(legacyMismatch.failures.map((entry) => entry.code).join(','), /TUN_LINK_MISSING/u);
});

test('phase4 runner state readers reject unknown or conflicting layout attrs', async () => {
  const runner = await import(modulePath);
  assert.deepEqual(
    runner.readExplicitBooleanState({
      attributes: { resourceName: 'wifi_switch', checked: 'true' }
    }),
    { supported: true, value: true, source: 'checked' }
  );
  assert.deepEqual(
    runner.readExplicitBooleanState({
      attributes: { resourceName: 'wifi_switch', enabled: 'true' }
    }),
    { supported: true, value: true, source: 'enabled' }
  );
  assert.equal(
    runner.readExplicitBooleanState({
      attributes: { resourceName: 'wifi_switch', foo: 'bar' }
    }).supported,
    false
  );
  assert.equal(
    runner.readExplicitBooleanState({
      attributes: { resourceName: 'wifi_switch', checked: 'true', state: 'off' }
    }).supported,
    false
  );
});

test('phase4 runner default network snapshot and restore preserve exact wifi/mobile state and skip already-correct restore clicks', async () => {
  const runner = await import(modulePath);
  const snapshotHarness = createLayoutExecHarness({
    layouts: [createNetworkLayout({ wifiState: 'on', mobileState: 'off' })]
  });
  const snapshot = await runner.defaultSnapshotNetworkState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    execImpl: snapshotHarness.execImpl,
    cwd: HARMONY_ROOT
  });
  assert.deepEqual(
    {
      supported: snapshot.supported,
      wifiEnabled: snapshot.wifiEnabled,
      mobileEnabled: snapshot.mobileEnabled
    },
    { supported: true, wifiEnabled: true, mobileEnabled: false }
  );

  const restoreHarness = createLayoutExecHarness({
    layouts: [
      createNetworkLayout({ wifiState: 'off', mobileState: 'on' }),
      createNetworkLayout({ wifiState: 'on', mobileState: 'off' })
    ]
  });
  const restoreResult = await runner.defaultRestoreNetworkState(snapshot, {
    execImpl: restoreHarness.execImpl,
    cwd: HARMONY_ROOT
  });
  assert.equal(restoreResult.restored, true);
  assert.equal(restoreHarness.calls.filter((entry) => entry.includes('uiInput click')).length, 2);

  const alreadyCorrectHarness = createLayoutExecHarness({
    layouts: [createNetworkLayout({ wifiState: 'on', mobileState: 'off' })]
  });
  const alreadyCorrect = await runner.defaultRestoreNetworkState(snapshot, {
    execImpl: alreadyCorrectHarness.execImpl,
    cwd: HARMONY_ROOT
  });
  assert.equal(alreadyCorrect.restored, true);
  assert.equal(alreadyCorrectHarness.calls.filter((entry) => entry.includes('uiInput click')).length, 0);

  const bothOnSnapshot = {
    supported: true,
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    wifiSelector: { resourceNames: ['wifi_switch'] },
    mobileSelector: { resourceNames: ['mobile_data_switch'] },
    wifiEnabled: true,
    mobileEnabled: true
  };
  const restoreBothOnHarness = createLayoutExecHarness({
    layouts: [
      createNetworkLayout({ wifiState: 'off', mobileState: 'off' }),
      createNetworkLayout({ wifiState: 'on', mobileState: 'on' })
    ]
  });
  const restoreBothOn = await runner.defaultRestoreNetworkState(bothOnSnapshot, {
    execImpl: restoreBothOnHarness.execImpl,
    cwd: HARMONY_ROOT
  });
  assert.equal(restoreBothOn.restored, true);
  assert.equal(restoreBothOnHarness.calls.filter((entry) => entry.includes('uiInput click')).length, 2);
});

test('phase4 runner default network recovery turns every enabled path off before exact restore, and rejects incomplete loss', async () => {
  const runner = await import(modulePath);
  const bothOff = {
    supported: true,
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    wifiSelector: { resourceNames: ['wifi_switch'] },
    mobileSelector: { resourceNames: ['mobile_data_switch'] },
    wifiEnabled: false,
    mobileEnabled: false
  };
  const unsupported = await runner.defaultExerciseNetworkRecovery(bothOff, {
    execImpl: createLayoutExecHarness().execImpl,
    cwd: HARMONY_ROOT
  });
  assert.equal(unsupported.supported, false);

  const bothOnHarness = createLayoutExecHarness({
    layouts: [
      createNetworkLayout({ wifiState: 'on', mobileState: 'on' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'on' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'off' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'off' }),
      createNetworkLayout({ wifiState: 'on', mobileState: 'on' })
    ]
  });
  const recoveredBothOn = await runner.defaultExerciseNetworkRecovery({
    supported: true,
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    wifiSelector: { resourceNames: ['wifi_switch'] },
    mobileSelector: { resourceNames: ['mobile_data_switch'] },
    wifiEnabled: true,
    mobileEnabled: true
  }, {
    execImpl: bothOnHarness.execImpl,
    cwd: HARMONY_ROOT
  });
  assert.deepEqual(
    {
      supported: recoveredBothOn.supported,
      recovered: recoveredBothOn.recovered,
      lossObserved: recoveredBothOn.lossObserved
    },
    { supported: true, recovered: true, lossObserved: true }
  );
  assert.deepEqual(recoveredBothOn.toggled, ['wifi', 'mobile']);
  assert.equal(bothOnHarness.calls.filter((entry) => entry.includes('uiInput click')).length, 4);

  const oneOnHarness = createLayoutExecHarness({
    layouts: [
      createNetworkLayout({ wifiState: 'on', mobileState: 'off' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'off' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'off' }),
      createNetworkLayout({ wifiState: 'on', mobileState: 'off' })
    ]
  });
  const recoveredOneOn = await runner.defaultExerciseNetworkRecovery({
    supported: true,
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    wifiSelector: { resourceNames: ['wifi_switch'] },
    mobileSelector: { resourceNames: ['mobile_data_switch'] },
    wifiEnabled: true,
    mobileEnabled: false
  }, {
    execImpl: oneOnHarness.execImpl,
    cwd: HARMONY_ROOT
  });
  assert.deepEqual(recoveredOneOn.toggled, ['wifi']);
  assert.equal(oneOnHarness.calls.filter((entry) => entry.includes('uiInput click')).length, 2);

  const failingHarness = createLayoutExecHarness({
    layouts: [
      createNetworkLayout({ wifiState: 'on', mobileState: 'on' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'on' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'on' })
    ]
  });
  await assert.rejects(
    () => runner.defaultExerciseNetworkRecovery({
      supported: true,
      target: 'SERIAL123',
      hdcCommand: '/sdk/hdc',
      cwd: HARMONY_ROOT,
      wifiSelector: { resourceNames: ['wifi_switch'] },
      mobileSelector: { resourceNames: ['mobile_data_switch'] },
      wifiEnabled: true,
      mobileEnabled: true
    }, {
      execImpl: failingHarness.execImpl,
      cwd: HARMONY_ROOT
    }),
    /NETWORK_RECOVERY_NOT_PROVEN/u
  );
});

test('phase4 runner default screen snapshot and restore read observable screen state and fail closed on mismatch', async () => {
  const runner = await import(modulePath);
  const onHarness = createLayoutExecHarness({
    screenOutputs: ['Display state: ON\n']
  });
  const onSnapshot = await runner.defaultSnapshotScreenState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    execImpl: onHarness.execImpl,
    cwd: HARMONY_ROOT
  });
  assert.deepEqual(
    { supported: onSnapshot.supported, screenOn: onSnapshot.screenOn },
    { supported: true, screenOn: true }
  );

  const offHarness = createLayoutExecHarness({
    screenOutputs: ['Display state: OFF\n']
  });
  const offSnapshot = await runner.defaultSnapshotScreenState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    execImpl: offHarness.execImpl,
    cwd: HARMONY_ROOT
  });
  assert.deepEqual(
    { supported: offSnapshot.supported, screenOn: offSnapshot.screenOn },
    { supported: true, screenOn: false }
  );

  const unknownHarness = createLayoutExecHarness({
    screenOutputs: ['Display state: UNKNOWN\n', 'Display state: UNKNOWN\n']
  });
  assert.deepEqual(
    await runner.defaultSnapshotScreenState({
      target: 'SERIAL123',
      hdcCommand: '/sdk/hdc',
      execImpl: unknownHarness.execImpl,
      cwd: HARMONY_ROOT
    }),
    { supported: false }
  );

  const mismatchHarness = createLayoutExecHarness({
    screenOutputs: ['Display state: OFF\n', 'Display state: OFF\n']
  });
  await assert.rejects(
    () => runner.defaultRestoreScreenState({
      supported: true,
      target: 'SERIAL123',
      hdcCommand: '/sdk/hdc',
      cwd: HARMONY_ROOT,
      screenOn: true
    }, {
      execImpl: mismatchHarness.execImpl,
      cwd: HARMONY_ROOT
    }),
    /STOP_CLEANUP_NOT_PROVEN/u
  );
});

test('phase4 runner downgrades a candidate pass when cleanup restore fails and still writes exactly once', async () => {
  const runner = await import(modulePath);
  const outputPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-cleanup-${process.pid}.json`);
  let linkedEvidence = null;
  let writerCount = 0;
  const result = await runner.runPhase4DeviceProof({
    outputPath,
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => ({
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', hapSha256: digest('production'), signatureSha256: digest('p-sign') },
      probe: { bundleName: 'com.github.kr328.clash.harmony.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
    }),
    execImpl: async (_command, args) => {
      const joined = args.join(' ');
      if (joined === 'help') return { exitCode: 0, stdout: 'file recv -b\ninstall\nshell\nlist targets\n', stderr: '' };
      if (joined === 'list targets') return { exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
      if (joined.includes('param get const.product.model')) return { exitCode: 0, stdout: 'Mate 70\n', stderr: '' };
      if (joined.includes('param get const.product.name')) return { exitCode: 0, stdout: 'harmony\n', stderr: '' };
      if (joined.includes('param get const.product.software.version')) return { exitCode: 0, stdout: 'HarmonyOS 6.0.1.123\n', stderr: '' };
      if (joined.includes('param get const.product.cpu.abilist')) return { exitCode: 0, stdout: 'arm64-v8a\n', stderr: '' };
      if (joined.includes('param get const.ohos.apiversion')) return { exitCode: 0, stdout: '20\n', stderr: '' };
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      if (joined.includes('file recv -b')) {
        const localPath = args.at(-1);
        const bundleName = args[5];
        const payload = bundleName === 'com.github.kr328.clash.harmony'
          ? linkedEvidence.runtime
          : linkedEvidence.probe;
        await fs.writeFile(localPath, `${JSON.stringify(payload)}\n`, 'utf8');
        return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      }
      throw new Error(`unexpected command ${joined}`);
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    startOriginImpl: async ({ runId }) => {
      linkedEvidence = createLinkedEvidence();
      linkedEvidence.runId = runId;
      linkedEvidence.origin.runId = runId;
      linkedEvidence.origin.observations = linkedEvidence.origin.observations.map((entry) => ({ ...entry, runId }));
      linkedEvidence.probe.runId = runId;
      return {
        observations: linkedEvidence.origin.observations,
        close: async () => {}
      };
    },
    runBaselineProbeImpl: async () => ({ result: 'pass' }),
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: true, wifiEnabled: true, mobileEnabled: false }),
    performUiAutomationImpl: async () => ({
      ok: true,
      launcherContinuity: true,
      screenOffContinuity: true,
      vpnIndicatorVisible: true,
      ongoingNotificationVisible: true
    }),
    exerciseNetworkRecoveryImpl: async () => ({ supported: true, recovered: true }),
    stopVpnImpl: async () => {},
    forceStopBundleImpl: async () => {},
    restoreNetworkStateImpl: async () => ({ restored: true }),
    restoreScreenStateImpl: async () => { throw new Error('screen restore failed'); },
    writeValidatedProofImpl: async (candidate) => {
      writerCount += 1;
      return candidate;
    }
  });

  assert.equal(writerCount, 1);
  assert.equal(result.result, 'incomplete');
  assert.equal(result.lifecycle.stop.result, 'fail');
  assert.match(result.failures.map((entry) => entry.code).join(','), /STOP_CLEANUP_NOT_PROVEN/u);
});

test('phase4 runner LAN origin selection is unique/private and proof writing falls back to canonical incomplete on invalid proof', async () => {
  const runner = await import(modulePath);
  assert.deepEqual(
    runner.selectControlledLanOriginAddress({
      en0: [{ address: '192.168.1.12', family: 'IPv4', internal: false }],
      lo0: [{ address: '127.0.0.1', family: 'IPv4', internal: true }]
    }).ipv4.address,
    '192.168.1.12'
  );
  assert.throws(
    () => runner.selectControlledLanOriginAddress({
      en0: [{ address: '192.168.1.12', family: 'IPv4', internal: false }],
      en1: [{ address: '10.0.0.8', family: 'IPv4', internal: false }]
    }),
    /ORIGIN_BIND_BLOCKED/u
  );

  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-runner-invalid-'));
  const invalidProof = runner.createBaseProofForTesting({ outputPath: path.join(tempRoot, 'proof.json') });
  invalidProof.result = 'pass';
  invalidProof.traffic = {};
  const persisted = await runner.writeValidatedProof(invalidProof, path.join(tempRoot, 'proof.json'));
  assert.equal(persisted.result, 'incomplete');
  assert.match(persisted.failures.map((entry) => entry.code).join(','), /PHASE4_PROOF_INVALID/u);
});
