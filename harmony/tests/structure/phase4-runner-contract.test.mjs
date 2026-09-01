import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import net from 'node:net';
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

function joinFragments(parts) {
  return parts.join('');
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
    localProof: {
      http: {
        ingress: 'local-http',
        outcome: 'pass',
        correlated: true,
        sessionId: uuid(),
        flowId: localHttpFlowId
      },
      socks: {
        ingress: 'local-socks',
        outcome: 'pass',
        correlated: true,
        sessionId: uuid(),
        flowId: localSocksFlowId
      }
    },
    runtime: {
      sessionId,
      counters: { rxPackets: 10, txPackets: 10, rxBytes: 1000, txBytes: 1000 },
      records: [
        { sequence: 1, kind: 'traffic', sessionIdHash: runnerHash(sessionId), ingress: 'tun', traceAlias: 'trace-1', coreAlias: '', flowIdHash: markerHash, protocol: 'tcp', hashedTuple: 'hash-1', correlationHash: markerHash, destinationHash: digest('dest-1'), outboundTerminalHash: digest('term-1'), outboundChainHash: digest('chain-1'), outboundChainLength: 2, linkageStatus: 'linked', counterDelta: 1, counterSnapshot: { rxPackets: 10, txPackets: 10, rxBytes: 1000, txBytes: 1000 }, detail: 'tcp' },
        { sequence: 2, kind: 'traffic', sessionIdHash: runnerHash(sessionId), ingress: 'tun', traceAlias: 'trace-2', coreAlias: '', flowIdHash: markerHash, protocol: 'udp', hashedTuple: 'hash-2', correlationHash: markerHash, destinationHash: digest('dest-2'), outboundTerminalHash: digest('term-2'), outboundChainHash: digest('chain-2'), outboundChainLength: 2, linkageStatus: 'linked', counterDelta: 1, counterSnapshot: { rxPackets: 10, txPackets: 10, rxBytes: 1000, txBytes: 1000 }, detail: 'udp' },
        { sequence: 3, kind: 'traffic', sessionIdHash: runnerHash(sessionId), ingress: 'tun', traceAlias: 'trace-3', coreAlias: '', flowIdHash: dnsHash, protocol: 'dns', hashedTuple: 'hash-3', correlationHash: dnsHash, destinationHash: digest('dest-3'), outboundTerminalHash: digest('term-3'), outboundChainHash: digest('chain-3'), outboundChainLength: 1, linkageStatus: 'linked', counterDelta: 1, counterSnapshot: { rxPackets: 10, txPackets: 10, rxBytes: 1000, txBytes: 1000 }, detail: 'dns' }
      ]
    },
    packages: {
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('signature:p') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('signature:q') }
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

function createReachabilityProbeRaw({
  runId = uuid(),
  sessionId = uuid(),
  httpsOutcome = 'pass',
  tcpOutcome = 'pass',
  udpOutcome = 'pass',
  dnsOutcome = 'pass',
  includeDnsPacket = true,
  rawFailureDetail = 'provider raw 11.22.33.44:29001 ECONNREFUSED'
} = {}) {
  const records = [
    { flowId: uuid(), stepId: 'https', ingressExpectation: 'origin-https', outcome: httpsOutcome, transport: 'https', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: httpsOutcome === 'pass' ? 1 : 0, statusCode: httpsOutcome === 'pass' ? 200 : 500 },
    { flowId: uuid(), stepId: 'tcp', ingressExpectation: 'tun', outcome: tcpOutcome, transport: 'tcp', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: tcpOutcome === 'pass' ? 1 : 0 },
    { flowId: uuid(), stepId: 'udp-ipv4', ingressExpectation: 'tun', outcome: udpOutcome, transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: udpOutcome === 'pass' ? 1 : 0 },
    { flowId: uuid(), stepId: 'dns-lookup', ingressExpectation: 'dns-default-lookup', outcome: 'pass', transport: 'dns', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 0, bytesReceived: 1 }
  ];
  if (includeDnsPacket) {
    records.push(
      { flowId: uuid(), stepId: 'dns-packet-ipv4', ingressExpectation: 'tun', outcome: dnsOutcome, transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: dnsOutcome === 'pass' ? 1 : 0 }
    );
  }
  return {
    version: '1.0.0',
    result: httpsOutcome === 'pass' && tcpOutcome === 'pass' && udpOutcome === 'pass' && (!includeDnsPacket || dnsOutcome === 'pass') ? 'pass' : 'fail',
    runId,
    sessionId,
    records,
    failures: [{ code: 'RAW_PROVIDER_FAILURE', detail: rawFailureDetail }]
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

function createControlCenterLayout({
  wifiState = 'on',
  bounds = { left: 0, top: 0, right: 2000, bottom: 3000 },
  wifiAttributes = {}
} = {}) {
  const boundsString = `[${bounds.left},${bounds.top}][${bounds.right},${bounds.bottom}]`;
  return {
    root: {
      attributes: {
        id: 'control_center_root',
        type: 'Panel',
        bounds: boundsString
      },
      children: [
        {
          attributes: {
            id: 'transition_togglewifi_ui_extension',
            type: 'Toggle',
            text: 'Wi-Fi',
            checked: wifiState === 'on' ? 'true' : 'false',
            clickable: 'true',
            enabled: 'true',
            bounds: '[1540,120][1860,420]',
            ...wifiAttributes
          },
          children: []
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
      if (joined.includes(' uitest uiInput click ') || joined.includes('uiInput keyEvent Power')) {
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      if (joined.includes(' shell rm -f ') && joined.includes('cmfa-layout-')) {
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      throw new Error(`unexpected command ${joined}`);
    }
  };
}

function createRuntimeLifecycleRecord(sequence, detail) {
  return {
    sequence,
    kind: 'lifecycle',
    detail
  };
}

function createRuntimeStopRecord(sequence, detail = 'vpn-stop-ok') {
  return {
    sequence,
    kind: 'stop',
    detail
  };
}

function createRuntimeJournal({
  runId = uuid(),
  sequence = 0,
  updatedAt = '2026-08-17T00:00:00.000Z',
  state = 'running',
  recoveryAttempt = 0,
  stopped = false,
  records = []
} = {}) {
  return {
    schemaVersion: '1.0.0',
    phase: 4,
    runId,
    sessionAlias: 'session-12345678',
    sequence,
    updatedAt,
    lifecycle: {
      state,
      detail: '',
      notificationActive: true,
      recoveryAttempt,
      stopped
    },
    counters: {
      rxPackets: 10,
      txPackets: 10,
      rxBytes: 1000,
      txBytes: 1000
    },
    records,
    writeFailureCount: 0,
    sizeBytes: 256
  };
}

test('phase4 runner correlates direct reachability, package identity, origin, probe, and tun evidence before pass', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  const result = runner.correlatePhase4Evidence(evidence);

  assert.equal(result.result, 'pass');
  assert.equal(result.failures.length, 0);
  assert.equal('sessionId' in result.traffic.tcp, false);
  assert.equal('traceId' in result.traffic.tcp, false);
  assert.equal(result.traffic.tcp.correlated, true);
  assert.equal(result.traffic.tcp.captureTrace.ingress, 'tun');
  assert.equal(result.traffic.udp.captureTrace.ingress, 'tun');
  assert.equal(result.traffic.dns.captureTrace.ingress, 'tun');
  assert.equal(result.localEvidence.http.correlated, true);
  assert.equal(result.localEvidence.http.ingress, 'local-http');
  assert.equal(result.localEvidence.socks.ingress, 'local-socks');
});

test('phase4 runner allows public TCP and UDP pass correlation without controlled TCP or UDP origin observations', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  evidence.origin.observations = evidence.origin.observations.filter((entry) => entry.protocol === 'https');

  const result = runner.correlatePhase4Evidence(evidence);

  assert.equal(result.result, 'pass', JSON.stringify(result.failures));
  assert.equal(result.failures.length, 0);
  assert.equal(result.traffic.tcp.result, 'pass');
  assert.equal(result.traffic.udp.result, 'pass');
  assert.equal(result.traffic.dns.result, 'pass');
});

test('phase4 runner still requires the controlled HTTPS observation for direct reachability', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  evidence.origin.observations = evidence.origin.observations.filter((entry) => entry.protocol !== 'https');

  const result = runner.correlatePhase4Evidence(evidence);

  assert.equal(result.result, 'incomplete');
  assert.match(result.failures.map((entry) => entry.code).join(','), /ORIGIN_REACHABILITY_NOT_PROVEN/u);
});

test('phase4 runner binds runtime records to the vpn journal session while correlating an independent probe session', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  const runtimeSessionId = evidence.runtime.sessionId;
  evidence.runtime.sessionAlias = `session-${runnerHash(runtimeSessionId)}`;
  evidence.probe.sessionId = uuid();

  const result = runner.correlatePhase4Evidence(evidence);

  assert.equal(result.result, 'pass');
  assert.equal(result.failures.length, 0);
  assert.equal(result.traffic.tcp.correlated, true);
});

test('phase4 runner rejects traffic records outside the vpn journal session', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  evidence.runtime.sessionAlias = `session-${runnerHash(evidence.runtime.sessionId)}`;
  evidence.runtime.records[0].sessionIdHash = runnerHash(uuid());

  const result = runner.correlatePhase4Evidence(evidence);

  assert.equal(result.result, 'incomplete');
  assert.match(result.failures.map((entry) => entry.code).join(','), /EVIDENCE_NORMALIZATION_FAILED/u);
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

test('phase4 runner sources local evidence from the runner host proof instead of probe-side local records', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  evidence.probe.records = evidence.probe.records.map((entry) =>
    entry.stepId === 'http-connect' || entry.stepId === 'socks5'
      ? { ...entry, outcome: 'fail' }
      : entry
  );

  const result = runner.correlatePhase4Evidence(evidence);
  assert.equal(result.result, 'pass');
  assert.equal(result.localEvidence.http.ingress, 'local-http');
  assert.equal(result.localEvidence.socks.ingress, 'local-socks');
});

test('phase4 runner requires destination and outbound hashes for linked tcp tun evidence', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  evidence.runtime.records[0].destinationHash = '';

  const result = runner.correlatePhase4Evidence(evidence);
  assert.equal(result.result, 'incomplete');
  assert.match(result.failures.map((entry) => entry.code).join(','), /TUN_LINK_MISSING/u);
});

test('phase4 runner rejects malformed hashes duplicate links and non-advancing counters', async () => {
  const runner = await import(modulePath);

  const malformed = createLinkedEvidence();
  malformed.runtime.records[0].destinationHash = 'not-a-hash';
  const malformedResult = runner.correlatePhase4Evidence(malformed);
  assert.equal(malformedResult.result, 'incomplete');
  assert.match(malformedResult.failures.map((entry) => entry.code).join(','), /EVIDENCE_NORMALIZATION_FAILED/u);

  const duplicate = createLinkedEvidence();
  duplicate.runtime.records.push({
    ...duplicate.runtime.records[0],
    sequence: 4,
    traceAlias: 'trace-duplicate'
  });
  const duplicateResult = runner.correlatePhase4Evidence(duplicate);
  assert.equal(duplicateResult.result, 'incomplete');
  assert.match(duplicateResult.failures.map((entry) => entry.code).join(','), /TUN_LINK_AMBIGUOUS/u);

  const stationary = createLinkedEvidence();
  stationary.runtime.records[0].counterDelta = 0;
  const stationaryResult = runner.correlatePhase4Evidence(stationary);
  assert.equal(stationaryResult.result, 'incomplete');
  assert.match(stationaryResult.failures.map((entry) => entry.code).join(','), /COUNTER_DELTA_MISSING/u);
});

test('phase4 runner never lets a linked ordinary udp record satisfy DNS proof even when hashes and counters match', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  const dnsRecord = evidence.runtime.records.find((entry) => entry.protocol === 'dns');
  const dnsHash = dnsRecord.correlationHash;
  evidence.runtime.records = evidence.runtime.records
    .filter((entry) => entry.protocol !== 'dns')
    .concat([{
      ...dnsRecord,
      sequence: 4,
      protocol: 'udp',
      flowIdHash: dnsHash,
      correlationHash: dnsHash,
      traceAlias: 'trace-dns-as-udp'
    }]);

  const result = runner.correlatePhase4Evidence(evidence);

  assert.equal(result.result, 'incomplete');
  assert.match(result.failures.map((entry) => entry.code).join(','), /TUN_LINK_MISSING/u);
  assert.equal(result.traffic.dns?.result === 'pass', false);
});

test('phase4 runner never promotes dns-lookup into global DNS proof without an exact dns-packet-ipv4 probe record', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  const dnsLookupFlowId = uuid();
  evidence.probe.records = evidence.probe.records
    .filter((entry) => entry.stepId !== 'dns-packet-ipv4')
    .map((entry) => entry.stepId === 'dns-lookup'
      ? { ...entry, outcome: 'pass', flowId: dnsLookupFlowId, ingressExpectation: 'tun' }
      : entry);
  const suspiciousDnsHash = createDnsPacketHash(evidence.runId, dnsLookupFlowId);
  evidence.runtime.records = evidence.runtime.records.map((entry) =>
    entry.protocol === 'dns'
      ? { ...entry, flowIdHash: suspiciousDnsHash, correlationHash: suspiciousDnsHash }
      : entry
  );

  const result = runner.correlatePhase4Evidence(evidence);

  assert.equal(result.result, 'incomplete');
  assert.match(result.failures.map((entry) => entry.code).join(','), /GLOBAL_INGRESS_INVALID|TUN_LINK_MISSING/u);
  assert.equal(result.traffic.dns?.result === 'pass', false);
  assert.equal(result.traffic.ipv4?.result === 'pass', false);
});

test('phase4 runner normalizePhase4ProbeEvidence keeps dns-lookup out of global DNS and IPv4 proof slots', async () => {
  const runner = await import(modulePath);
  const runId = uuid();
  const raw = {
    version: '1.0.0',
    result: 'pass',
    runId,
    sessionId: uuid(),
    records: [
      { flowId: uuid(), stepId: 'https', ingressExpectation: 'origin-https', outcome: 'pass', transport: 'https', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1, statusCode: 200 },
      { flowId: uuid(), stepId: 'tcp', ingressExpectation: 'tun', outcome: 'pass', transport: 'tcp', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
      { flowId: uuid(), stepId: 'udp-ipv4', ingressExpectation: 'tun', outcome: 'pass', transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
      { flowId: uuid(), stepId: 'dns-lookup', ingressExpectation: 'tun', outcome: 'pass', transport: 'dns', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 }
    ],
    failures: []
  };

  const normalized = runner.normalizePhase4ProbeEvidence(raw, runId);

  assert.equal(normalized.global.dns, null);
  assert.equal(normalized.global.ipv4, null);
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
        production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('p-sign') },
        probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
      };
    },
    execImpl: async (_command, args) => {
      calls.push(args.join(' '));
      const joined = args.join(' ');
      if (['help', '-h', '--help'].includes(joined)) {
        return {
          exitCode: 0,
          stdout: 'file recv [option] remote local\n-b: send/receive file to debug application directory\ninstall\nshell\nlist targets\n',
          stderr: ''
        };
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
      if (joined.endsWith('shell ifconfig')) {
        return {
          exitCode: 0,
          stdout: [
            'wlan0 Link encap:Ethernet',
            '  inet addr:30.231.216.149 Bcast:30.231.223.255 Mask:255.255.248.0',
            'wlan1 Link encap:Ethernet',
            '  inet addr:192.168.43.1 Bcast:192.168.43.255 Mask:255.255.255.0'
          ].join('\n'),
          stderr: ''
        };
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
      return {
        result: 'fail',
        failure: { code: 'BASELINE_TCP_FAILED', detail: 'tcp=fail' }
      };
    },
    startOriginImpl: async ({ deviceIpv4Candidates }) => {
      assert.deepEqual(deviceIpv4Candidates, [
        { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
        { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
      ]);
      calls.push('startOrigin');
      return { close: async () => { calls.push('origin.close'); } };
    },
    stopVpnImpl: async () => { calls.push('stopVpn'); },
    restoreNetworkStateImpl: async () => { calls.push('restoreNetwork'); },
    restoreScreenStateImpl: async () => { calls.push('restoreScreen'); }
  });

  assert.equal(result.result, 'incomplete');
  assert.match(result.failures.map((entry) => entry.code).join(','), /BASELINE_TCP_FAILED/u);
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

test('phase4 runner baseline classification requires https plus tcp udp and dns-packet reachability with fixed failure classes', async () => {
  const runner = await import(modulePath);
  const runId = uuid();
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-baseline-reachability-'));
  const localPath = path.join(tempRoot, 'probe.json');
  const externalOrigin = Object.freeze({ hostIpv4: '11.22.33.44', tcpHostIpv4: '55.66.77.88', tcpPort: 80, udpPort: 20053, dnsPort: 20054 });
  const origin = {
    publicKeyPinSha256: 'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    https: { host: 'origin.lan', port: 443, caPem: 'certificate' },
    tcp: { host: 'origin.lan', port: 18080 },
    udp: { host: 'origin.lan', port: 15353 }
  };

  const runBaseline = async (raw) => await runner.defaultRunBaselineProbeImpl({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    execImpl: async (_command, args) => {
      const joined = args.join(' ');
      if (joined.includes('file recv -b')) {
        await fs.writeFile(args.at(-1), `${JSON.stringify(raw)}\n`, 'utf8');
        return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      }
      return { exitCode: 0, stdout: 'Success\n', stderr: '' };
    },
    origin,
    externalOrigin,
    cwd: HARMONY_ROOT,
    fsApi: fs,
    tempRoot,
    runId,
    waitForEvidenceImpl: async () => ({ ok: true, proof: raw })
  });

  const missingDns = await runBaseline(createReachabilityProbeRaw({ runId, includeDnsPacket: false }));
  assert.equal(missingDns.result, 'fail');
  assert.equal(missingDns.failure.code, 'EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN');

  const httpsFail = await runBaseline(createReachabilityProbeRaw({ runId, httpsOutcome: 'fail' }));
  assert.equal(httpsFail.result, 'fail');
  assert.equal(httpsFail.failure.code, 'ORIGIN_REACHABILITY_NOT_PROVEN');
  assert.equal(httpsFail.failure.detail.includes('RAW_PROVIDER_FAILURE'), false);

  const externalFail = await runBaseline(createReachabilityProbeRaw({ runId, dnsOutcome: 'fail' }));
  assert.equal(externalFail.result, 'fail');
  assert.equal(externalFail.failure.code, 'EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN');
  assert.equal(externalFail.failure.detail.includes('11.22.33.44'), false);
});

test('phase4 runner vpn probe returns fixed pending triage classification for external failure and origin failure for controlled https failure', async () => {
  const runner = await import(modulePath);
  const runId = uuid();
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-vpn-reachability-'));
  const externalOrigin = Object.freeze({ hostIpv4: '11.22.33.44', tcpHostIpv4: '55.66.77.88', tcpPort: 80, udpPort: 20053, dnsPort: 20054 });
  const origin = {
    publicKeyPinSha256: 'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    https: { host: 'origin.lan', port: 443, caPem: 'certificate' },
    tcp: { host: 'origin.lan', port: 18080 },
    udp: { host: 'origin.lan', port: 15353 }
  };
  const runVpn = async (raw) => await runner.defaultRunVpnProbeImpl({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    execImpl: async (_command, args) => {
      const joined = args.join(' ');
      if (joined.includes('file recv -b')) {
        await fs.writeFile(args.at(-1), `${JSON.stringify(raw)}\n`, 'utf8');
        return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      }
      return { exitCode: 0, stdout: 'Success\n', stderr: '' };
    },
    origin,
    externalOrigin,
    cwd: HARMONY_ROOT,
    fsApi: fs,
    tempRoot,
    runId,
    waitForEvidenceImpl: async () => ({ ok: true, proof: raw })
  });

  const externalFail = await runVpn(createReachabilityProbeRaw({ runId, tcpOutcome: 'fail' }));
  assert.equal(externalFail.result, 'fail');
  assert.equal(externalFail.requiresExternalOriginTriage, true);
  assert.equal(externalFail.failure.code, 'GLOBAL_INGRESS_INVALID');
  assert.equal(externalFail.failure.detail.includes('RAW_PROVIDER_FAILURE'), false);

  const httpsFail = await runVpn(createReachabilityProbeRaw({ runId, httpsOutcome: 'fail' }));
  assert.equal(httpsFail.result, 'fail');
  assert.equal(httpsFail.requiresExternalOriginTriage, false);
  assert.equal(httpsFail.failure.code, 'ORIGIN_REACHABILITY_NOT_PROVEN');
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
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('p-sign') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
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
      bundleName: 'com.cmfa.phase4.trafficprobe',
      remotePath: '/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json',
      localPath: '/tmp/probe.json'
    }),
    ['-t', 'SERIAL123', 'file', 'recv', '-b', 'com.cmfa.phase4.trafficprobe', '/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json', '/tmp/probe.json']
  );
});

test('phase4 runner treats HDC zero-exit missing-file output as pollable evidence absence', async () => {
  const runner = await import(modulePath);
  const localPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-missing-pull-${process.pid}.json`);
  const result = await runner.pullBundleEvidenceJson({
    fsApi: fs,
    execImpl: async () => ({
      exitCode: 0,
      stdout: '[Fail]Error opening file: no such file or directory',
      stderr: ''
    }),
    hdcCommand: '/sdk/hdc',
    target: 'SERIAL123',
    bundleName: 'com.cmfa.phase4.trafficprobe',
    remotePath: '/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json',
    localPath,
    cwd: HARMONY_ROOT
  });
  assert.equal(result.ok, false);
  assert.equal(result.failure.code, 'APP_EVIDENCE_MISSING');
});

test('phase4 runner evidence polling survives twenty transient missing-file responses', async () => {
  const runner = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-evidence-poll-'));
  const localPath = path.join(tempRoot, 'probe.json');
  const expectedRunId = uuid();
  let attempts = 0;
  const result = await runner.waitForBundleEvidence({
    fsApi: fs,
    execImpl: async (_command, args) => {
      attempts += 1;
      if (attempts <= 20) {
        return { exitCode: 0, stdout: '[Fail] no such file or directory', stderr: '' };
      }
      await fs.writeFile(args.at(-1), `${JSON.stringify({ runId: expectedRunId })}\n`, 'utf8');
      return { exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    },
    hdcCommand: '/sdk/hdc',
    target: 'SERIAL123',
    bundleName: 'com.cmfa.phase4.trafficprobe',
    remotePath: '/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json',
    localPath,
    cwd: HARMONY_ROOT,
    expectedRunId,
    delayImpl: async () => {}
  });
  assert.equal(result.ok, true);
  assert.equal(attempts, 21);
});

test('phase4 runner evidence polling outlives the probe sequential timeout budget', async () => {
  const runner = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-evidence-budget-'));
  const localPath = path.join(tempRoot, 'probe.json');
  const expectedRunId = uuid();
  let attempts = 0;
  const result = await runner.waitForBundleEvidence({
    fsApi: fs,
    execImpl: async (_command, args) => {
      attempts += 1;
      const runId = attempts <= 60 ? uuid() : expectedRunId;
      await fs.writeFile(args.at(-1), `${JSON.stringify({ runId })}\n`, 'utf8');
      return { exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    },
    hdcCommand: '/sdk/hdc',
    target: 'SERIAL123',
    bundleName: 'com.cmfa.phase4.trafficprobe',
    remotePath: '/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json',
    localPath,
    cwd: HARMONY_ROOT,
    expectedRunId,
    delayImpl: async () => {}
  });
  assert.equal(result.ok, true);
  assert.equal(attempts, 61);
});

test('phase4 runner evidence polling rejects an older probe session from the same run', async (t) => {
  const runner = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-session-poll-'));
  t.after(async () => await fs.rm(tempRoot, { recursive: true, force: true }));
  const localPath = path.join(tempRoot, 'probe.json');
  const expectedRunId = uuid();
  const expectedSessionId = uuid();
  const staleSessionId = uuid();
  let attempts = 0;

  const result = await runner.waitForBundleEvidence({
    fsApi: fs,
    execImpl: async (_command, args) => {
      attempts += 1;
      const sessionId = attempts === 1 ? staleSessionId : expectedSessionId;
      await fs.writeFile(args.at(-1), `${JSON.stringify({ runId: expectedRunId, sessionId })}\n`, 'utf8');
      return { exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    },
    hdcCommand: '/sdk/hdc',
    target: 'SERIAL123',
    bundleName: 'com.cmfa.phase4.trafficprobe',
    remotePath: '/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json',
    localPath,
    cwd: HARMONY_ROOT,
    expectedRunId,
    expectedSessionId,
    delayImpl: async () => {}
  });

  assert.equal(result.ok, true);
  assert.equal(result.proof.sessionId, expectedSessionId);
  assert.equal(attempts, 2);
});

test('phase4 runner runtime recovery readiness requires a fresh RECOVERING -> proxy-activate-ok -> RUNNING window after baseline', async () => {
  const runner = await import(modulePath);
  const runId = uuid();
  const baselineJournal = createRuntimeJournal({
    runId,
    sequence: 5,
    updatedAt: '2026-08-17T00:00:05.000Z',
    records: [
      createRuntimeLifecycleRecord(1, 'STATE_CHANGED:RUNNING'),
      createRuntimeLifecycleRecord(2, 'STATE_CHANGED:RECOVERING'),
      createRuntimeLifecycleRecord(3, 'proxy-activate-ok'),
      createRuntimeLifecycleRecord(4, 'STATE_CHANGED:RUNNING'),
      { sequence: 5, kind: 'traffic', ingress: 'tun', detail: 'tcp' }
    ]
  });
  const baseline = runner.captureRuntimeRecoveryBaseline(baselineJournal, runId);

  const ready = runner.assessRuntimeRecoveryReadiness(
    createRuntimeJournal({
      runId,
      sequence: 9,
      updatedAt: '2026-08-17T00:00:09.000Z',
      records: [
        ...baselineJournal.records,
        createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING'),
        createRuntimeLifecycleRecord(7, 'proxy-activate-ok'),
        createRuntimeLifecycleRecord(9, 'STATE_CHANGED:RUNNING')
      ]
    }),
    baseline
  );
  assert.equal(ready.ready, true);

  const staleRunningOnly = runner.assessRuntimeRecoveryReadiness(
    createRuntimeJournal({
      runId,
      sequence: 9,
      updatedAt: '2026-08-17T00:00:09.000Z',
      records: [
        ...baselineJournal.records,
        createRuntimeLifecycleRecord(9, 'STATE_CHANGED:RUNNING')
      ]
    }),
    baseline
  );
  assert.equal(staleRunningOnly.ready, false);

  const missingProxyReplay = runner.assessRuntimeRecoveryReadiness(
    createRuntimeJournal({
      runId,
      sequence: 9,
      updatedAt: '2026-08-17T00:00:09.000Z',
      records: [
        ...baselineJournal.records,
        createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING'),
        createRuntimeLifecycleRecord(9, 'STATE_CHANGED:RUNNING')
      ]
    }),
    baseline
  );
  assert.equal(missingProxyReplay.ready, false);

  const staleJournal = runner.assessRuntimeRecoveryReadiness(
    createRuntimeJournal({
      runId,
      sequence: 5,
      updatedAt: '2026-08-17T00:00:05.000Z',
      records: baselineJournal.records
    }),
    baseline
  );
  assert.equal(staleJournal.ready, false);
});

test('phase4 runner runtime recovery entered assessment requires a fresh RECOVERING event after baseline', async () => {
  const runner = await import(modulePath);
  const runId = uuid();
  const baselineJournal = createRuntimeJournal({
    runId,
    sequence: 5,
    updatedAt: '2026-08-17T00:00:05.000Z',
    records: [
      createRuntimeLifecycleRecord(1, 'STATE_CHANGED:RUNNING'),
      createRuntimeLifecycleRecord(2, 'STATE_CHANGED:RECOVERING'),
      createRuntimeLifecycleRecord(3, 'proxy-activate-ok'),
      createRuntimeLifecycleRecord(4, 'STATE_CHANGED:RUNNING'),
      { sequence: 5, kind: 'traffic', ingress: 'tun', detail: 'tcp' }
    ]
  });
  const baseline = runner.captureRuntimeRecoveryBaseline(baselineJournal, runId);

  const entered = runner.assessRuntimeRecoveryEntered(
    createRuntimeJournal({
      runId,
      sequence: 6,
      updatedAt: '2026-08-17T00:00:06.000Z',
      state: 'recovering',
      recoveryAttempt: 1,
      records: [
        ...baselineJournal.records,
        createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING')
      ]
    }),
    baseline
  );
  assert.equal(entered.entered, true);

  const stale = runner.assessRuntimeRecoveryEntered(
    createRuntimeJournal({
      runId,
      sequence: 5,
      updatedAt: '2026-08-17T00:00:05.000Z',
      records: baselineJournal.records
    }),
    baseline
  );
  assert.equal(stale.entered, false);

  const missingRecovering = runner.assessRuntimeRecoveryEntered(
    createRuntimeJournal({
      runId,
      sequence: 6,
      updatedAt: '2026-08-17T00:00:06.000Z',
      records: [
        ...baselineJournal.records,
        createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RUNNING')
      ]
    }),
    baseline
  );
  assert.equal(missingRecovering.entered, false);
});

test('phase4 runner runtime recovery entered polling waits for a fresh production RECOVERING event', async (t) => {
  const runner = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-runtime-entered-'));
  t.after(async () => await fs.rm(tempRoot, { recursive: true, force: true }));
  const localPath = path.join(tempRoot, 'runtime.json');
  const runId = uuid();
  const baselineJournal = createRuntimeJournal({
    runId,
    sequence: 5,
    updatedAt: '2026-08-17T00:00:05.000Z',
    records: [
      createRuntimeLifecycleRecord(1, 'STATE_CHANGED:RUNNING'),
      createRuntimeLifecycleRecord(2, 'STATE_CHANGED:RECOVERING'),
      createRuntimeLifecycleRecord(3, 'proxy-activate-ok'),
      createRuntimeLifecycleRecord(4, 'STATE_CHANGED:RUNNING'),
      { sequence: 5, kind: 'traffic', ingress: 'tun', detail: 'tcp' }
    ]
  });
  const baseline = runner.captureRuntimeRecoveryBaseline(baselineJournal, runId);
  const queuedJournals = [
    createRuntimeJournal({
      runId,
      sequence: 5,
      updatedAt: '2026-08-17T00:00:05.000Z',
      records: baselineJournal.records
    }),
    createRuntimeJournal({
      runId,
      sequence: 6,
      updatedAt: '2026-08-17T00:00:06.000Z',
      state: 'recovering',
      recoveryAttempt: 1,
      records: [
        ...baselineJournal.records,
        createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING')
      ]
    })
  ];
  const delays = [];
  let attempts = 0;

  const result = await runner.waitForRuntimeRecoveryEntered({
    fsApi: fs,
    execImpl: async (_command, args) => {
      const next = queuedJournals[Math.min(attempts, queuedJournals.length - 1)];
      attempts += 1;
      await fs.writeFile(args.at(-1), `${JSON.stringify(next)}\n`, 'utf8');
      return { exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    },
    hdcCommand: '/sdk/hdc',
    target: 'SERIAL123',
    remotePath: '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json',
    localPath,
    cwd: HARMONY_ROOT,
    expectedRunId: runId,
    baseline,
    delayImpl: async (milliseconds) => {
      delays.push(milliseconds);
    }
  });

  assert.equal(result.ok, true);
  assert.equal(result.proof.sequence, 6);
  assert.equal(attempts, 2);
  assert.deepEqual(delays, [250]);
});

test('phase4 runner runtime recovery polling waits until a fresh production journal is ready', async (t) => {
  const runner = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-runtime-recovery-'));
  t.after(async () => await fs.rm(tempRoot, { recursive: true, force: true }));
  const localPath = path.join(tempRoot, 'runtime.json');
  const runId = uuid();
  const baselineJournal = createRuntimeJournal({
    runId,
    sequence: 5,
    updatedAt: '2026-08-17T00:00:05.000Z',
    records: [
      createRuntimeLifecycleRecord(1, 'STATE_CHANGED:RUNNING'),
      createRuntimeLifecycleRecord(2, 'STATE_CHANGED:RECOVERING'),
      createRuntimeLifecycleRecord(3, 'proxy-activate-ok'),
      createRuntimeLifecycleRecord(4, 'STATE_CHANGED:RUNNING'),
      { sequence: 5, kind: 'traffic', ingress: 'tun', detail: 'tcp' }
    ]
  });
  const baseline = runner.captureRuntimeRecoveryBaseline(baselineJournal, runId);
  const queuedJournals = [
    createRuntimeJournal({
      runId,
      sequence: 6,
      updatedAt: '2026-08-17T00:00:06.000Z',
      state: 'recovering',
      recoveryAttempt: 1,
      records: [
        ...baselineJournal.records,
        createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING')
      ]
    }),
    createRuntimeJournal({
      runId,
      sequence: 9,
      updatedAt: '2026-08-17T00:00:09.000Z',
      records: [
        ...baselineJournal.records,
        createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING'),
        createRuntimeLifecycleRecord(7, 'proxy-activate-ok'),
        createRuntimeLifecycleRecord(9, 'STATE_CHANGED:RUNNING')
      ]
    })
  ];
  const delays = [];
  let attempts = 0;

  const result = await runner.waitForRuntimeRecoveryReadiness({
    fsApi: fs,
    execImpl: async (_command, args) => {
      const next = queuedJournals[Math.min(attempts, queuedJournals.length - 1)];
      attempts += 1;
      await fs.writeFile(args.at(-1), `${JSON.stringify(next)}\n`, 'utf8');
      return { exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    },
    hdcCommand: '/sdk/hdc',
    target: 'SERIAL123',
    remotePath: '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json',
    localPath,
    cwd: HARMONY_ROOT,
    expectedRunId: runId,
    baseline,
    delayImpl: async (milliseconds) => {
      delays.push(milliseconds);
    }
  });

  assert.equal(result.ok, true);
  assert.equal(result.proof.sequence, 9);
  assert.equal(attempts, 2);
  assert.deepEqual(delays, [250]);
});

test('phase4 runner runtime stopped polling waits for a fresh stopped journal and rejects running journals', async (t) => {
  const runner = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-runtime-stopped-'));
  t.after(async () => await fs.rm(tempRoot, { recursive: true, force: true }));
  const localPath = path.join(tempRoot, 'runtime.json');
  const runId = uuid();
  const baselineJournal = createRuntimeJournal({
    runId,
    sequence: 9,
    updatedAt: '2026-08-17T00:00:09.000Z',
    records: [
      createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING'),
      createRuntimeLifecycleRecord(7, 'proxy-activate-ok'),
      createRuntimeLifecycleRecord(9, 'STATE_CHANGED:RUNNING')
    ]
  });
  const baseline = runner.captureRuntimeStopBaseline(baselineJournal, runId);

  const running = runner.assessRuntimeStopped(
    createRuntimeJournal({
      runId,
      sequence: 10,
      updatedAt: '2026-08-17T00:00:10.000Z',
      records: [
        ...baselineJournal.records,
        createRuntimeLifecycleRecord(10, 'STATE_CHANGED:RUNNING')
      ]
    }),
    baseline
  );
  assert.equal(running.stopped, false);

  const queuedJournals = [
    createRuntimeJournal({
      runId,
      sequence: 10,
      updatedAt: '2026-08-17T00:00:10.000Z',
      records: [
        ...baselineJournal.records,
        createRuntimeLifecycleRecord(10, 'STATE_CHANGED:RUNNING')
      ]
    }),
    createRuntimeJournal({
      runId,
      sequence: 12,
      updatedAt: '2026-08-17T00:00:12.000Z',
      state: 'stopped',
      stopped: true,
      records: [
        ...baselineJournal.records,
        createRuntimeStopRecord(11),
        createRuntimeLifecycleRecord(12, 'STATE_CHANGED:STOPPED')
      ]
    })
  ];
  const delays = [];
  let attempts = 0;

  const result = await runner.waitForRuntimeStopped({
    fsApi: fs,
    execImpl: async (_command, args) => {
      const next = queuedJournals[Math.min(attempts, queuedJournals.length - 1)];
      attempts += 1;
      await fs.writeFile(args.at(-1), `${JSON.stringify(next)}\n`, 'utf8');
      return { exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    },
    hdcCommand: '/sdk/hdc',
    target: 'SERIAL123',
    remotePath: '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json',
    localPath,
    cwd: HARMONY_ROOT,
    expectedRunId: runId,
    baseline,
    delayImpl: async (milliseconds) => {
      delays.push(milliseconds);
    }
  });

  assert.equal(result.ok, true);
  assert.equal(result.proof.sequence, 12);
  assert.equal(attempts, 2);
  assert.deepEqual(delays, [250]);
});

test('phase4 runner runtime traffic polling rejects stale journals, waits for split arrivals, and passes only after tcp/udp/dns are all fresh-linked', async (t) => {
  const runner = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-runtime-traffic-'));
  t.after(async () => await fs.rm(tempRoot, { recursive: true, force: true }));
  const localPath = path.join(tempRoot, 'runtime.json');
  const evidence = createLinkedEvidence();
  const probe = runner.normalizePhase4ProbeEvidence(evidence.probe, evidence.runId);
  const baselineJournal = createRuntimeJournal({
    runId: evidence.runId,
    sequence: 9,
    updatedAt: '2026-08-17T00:00:09.000Z',
    records: [
      createRuntimeLifecycleRecord(6, 'tun-start-ok'),
      createRuntimeLifecycleRecord(7, 'STATE_CHANGED:RECOVERING'),
      createRuntimeLifecycleRecord(8, 'proxy-activate-ok'),
      createRuntimeLifecycleRecord(9, 'STATE_CHANGED:RUNNING')
    ]
  });
  const baseline = runner.captureRuntimeTrafficBaseline(baselineJournal, evidence.runId);
  const stale = runner.assessRuntimeTrafficEvidence(baselineJournal, baseline, probe);
  assert.equal(stale.ready, false);

  const tcpHash = probe.global.tcp.correlationHash;
  const udpHash = probe.global.udp.correlationHash;
  const dnsHash = probe.global.dns.correlationHash;
  const queuedJournals = [
    baselineJournal,
    createRuntimeJournal({
      runId: evidence.runId,
      sequence: 11,
      updatedAt: '2026-08-17T00:00:11.000Z',
      records: [
        ...baselineJournal.records,
        {
          sequence: 11,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: tcpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-tcp',
          coreAlias: '',
          protocol: 'tcp',
          hashedTuple: 'hash-tcp',
          correlationHash: tcpHash,
          destinationHash: digest('dest-tcp'),
          outboundTerminalHash: digest('term-tcp'),
          outboundChainHash: digest('chain-tcp'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'tcp'
        }
      ]
    }),
    createRuntimeJournal({
      runId: evidence.runId,
      sequence: 12,
      updatedAt: '2026-08-17T00:00:12.000Z',
      records: [
        ...baselineJournal.records,
        {
          sequence: 11,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: tcpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-tcp',
          coreAlias: '',
          protocol: 'tcp',
          hashedTuple: 'hash-tcp',
          correlationHash: tcpHash,
          destinationHash: digest('dest-tcp'),
          outboundTerminalHash: digest('term-tcp'),
          outboundChainHash: digest('chain-tcp'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'tcp'
        },
        {
          sequence: 12,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: udpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-udp',
          coreAlias: '',
          protocol: 'udp',
          hashedTuple: 'hash-udp',
          correlationHash: udpHash,
          destinationHash: digest('dest-udp'),
          outboundTerminalHash: digest('term-udp'),
          outboundChainHash: digest('chain-udp'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'udp'
        }
      ]
    }),
    createRuntimeJournal({
      runId: evidence.runId,
      sequence: 13,
      updatedAt: '2026-08-17T00:00:13.000Z',
      records: [
        ...baselineJournal.records,
        {
          sequence: 11,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: tcpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-tcp',
          coreAlias: '',
          protocol: 'tcp',
          hashedTuple: 'hash-tcp',
          correlationHash: tcpHash,
          destinationHash: digest('dest-tcp'),
          outboundTerminalHash: digest('term-tcp'),
          outboundChainHash: digest('chain-tcp'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'tcp'
        },
        {
          sequence: 12,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: udpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-udp',
          coreAlias: '',
          protocol: 'udp',
          hashedTuple: 'hash-udp',
          correlationHash: udpHash,
          destinationHash: digest('dest-udp'),
          outboundTerminalHash: digest('term-udp'),
          outboundChainHash: digest('chain-udp'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'udp'
        },
        {
          sequence: 13,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: dnsHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-dns',
          coreAlias: '',
          protocol: 'dns',
          hashedTuple: 'hash-dns',
          correlationHash: dnsHash,
          destinationHash: digest('dest-dns'),
          outboundTerminalHash: digest('term-dns'),
          outboundChainHash: digest('chain-dns'),
          outboundChainLength: 1,
          counterDelta: 1,
          detail: 'dns'
        }
      ]
    })
  ];
  const delays = [];
  let attempts = 0;

  const result = await runner.waitForRuntimeTrafficEvidence({
    fsApi: fs,
    execImpl: async (_command, args) => {
      const next = queuedJournals[Math.min(attempts, queuedJournals.length - 1)];
      attempts += 1;
      await fs.writeFile(args.at(-1), `${JSON.stringify(next)}\n`, 'utf8');
      return { exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    },
    hdcCommand: '/sdk/hdc',
    target: 'SERIAL123',
    remotePath: '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json',
    localPath,
    cwd: HARMONY_ROOT,
    expectedRunId: evidence.runId,
    baseline,
    probe,
    delayImpl: async (milliseconds) => {
      delays.push(milliseconds);
    }
  });

  assert.equal(result.ok, true);
  assert.equal(result.proof.sequence, 13);
  assert.equal(attempts, 4);
  assert.deepEqual(delays, [250, 250, 250]);
});

test('phase4 runner runtime traffic assessment fail-closes on fresh duplicate linked records for any expected correlation', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  const probe = runner.normalizePhase4ProbeEvidence(evidence.probe, evidence.runId);
  const baselineJournal = createRuntimeJournal({
    runId: evidence.runId,
    sequence: 9,
    updatedAt: '2026-08-17T00:00:09.000Z',
    records: [
      createRuntimeLifecycleRecord(6, 'tun-start-ok'),
      createRuntimeLifecycleRecord(7, 'STATE_CHANGED:RECOVERING'),
      createRuntimeLifecycleRecord(8, 'proxy-activate-ok'),
      createRuntimeLifecycleRecord(9, 'STATE_CHANGED:RUNNING')
    ]
  });
  const baseline = runner.captureRuntimeTrafficBaseline(baselineJournal, evidence.runId);
  const tcpHash = probe.global.tcp.correlationHash;
  const udpHash = probe.global.udp.correlationHash;
  const dnsHash = probe.global.dns.correlationHash;

  const duplicateTcp = runner.assessRuntimeTrafficEvidence(
    createRuntimeJournal({
      runId: evidence.runId,
      sequence: 14,
      updatedAt: '2026-08-17T00:00:14.000Z',
      records: [
        ...baselineJournal.records,
        {
          sequence: 10,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: tcpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-tcp-a',
          coreAlias: '',
          protocol: 'tcp',
          hashedTuple: 'hash-tcp-a',
          correlationHash: tcpHash,
          destinationHash: digest('dest-tcp-a'),
          outboundTerminalHash: digest('term-tcp-a'),
          outboundChainHash: digest('chain-tcp-a'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'tcp'
        },
        {
          sequence: 11,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: tcpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-tcp-b',
          coreAlias: '',
          protocol: 'tcp',
          hashedTuple: 'hash-tcp-b',
          correlationHash: tcpHash,
          destinationHash: digest('dest-tcp-b'),
          outboundTerminalHash: digest('term-tcp-b'),
          outboundChainHash: digest('chain-tcp-b'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'tcp'
        },
        {
          sequence: 12,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: udpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-udp',
          coreAlias: '',
          protocol: 'udp',
          hashedTuple: 'hash-udp',
          correlationHash: udpHash,
          destinationHash: digest('dest-udp'),
          outboundTerminalHash: digest('term-udp'),
          outboundChainHash: digest('chain-udp'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'udp'
        },
        {
          sequence: 13,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: dnsHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-dns',
          coreAlias: '',
          protocol: 'dns',
          hashedTuple: 'hash-dns',
          correlationHash: dnsHash,
          destinationHash: digest('dest-dns'),
          outboundTerminalHash: digest('term-dns'),
          outboundChainHash: digest('chain-dns'),
          outboundChainLength: 1,
          counterDelta: 1,
          detail: 'dns'
        }
      ]
    }),
    baseline,
    probe
  );
  assert.equal(duplicateTcp.ready, false);
  assert.equal(duplicateTcp.reason, 'tcp-ambiguous');

  const duplicateUdp = runner.assessRuntimeTrafficEvidence(
    createRuntimeJournal({
      runId: evidence.runId,
      sequence: 14,
      updatedAt: '2026-08-17T00:00:14.000Z',
      records: [
        ...baselineJournal.records,
        {
          sequence: 10,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: tcpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-tcp',
          coreAlias: '',
          protocol: 'tcp',
          hashedTuple: 'hash-tcp',
          correlationHash: tcpHash,
          destinationHash: digest('dest-tcp'),
          outboundTerminalHash: digest('term-tcp'),
          outboundChainHash: digest('chain-tcp'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'tcp'
        },
        {
          sequence: 11,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: udpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-udp-a',
          coreAlias: '',
          protocol: 'udp',
          hashedTuple: 'hash-udp-a',
          correlationHash: udpHash,
          destinationHash: digest('dest-udp-a'),
          outboundTerminalHash: digest('term-udp-a'),
          outboundChainHash: digest('chain-udp-a'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'udp'
        },
        {
          sequence: 12,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: udpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-udp-b',
          coreAlias: '',
          protocol: 'udp',
          hashedTuple: 'hash-udp-b',
          correlationHash: udpHash,
          destinationHash: digest('dest-udp-b'),
          outboundTerminalHash: digest('term-udp-b'),
          outboundChainHash: digest('chain-udp-b'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'udp'
        },
        {
          sequence: 13,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: dnsHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-dns',
          coreAlias: '',
          protocol: 'dns',
          hashedTuple: 'hash-dns',
          correlationHash: dnsHash,
          destinationHash: digest('dest-dns'),
          outboundTerminalHash: digest('term-dns'),
          outboundChainHash: digest('chain-dns'),
          outboundChainLength: 1,
          counterDelta: 1,
          detail: 'dns'
        }
      ]
    }),
    baseline,
    probe
  );
  assert.equal(duplicateUdp.ready, false);
  assert.equal(duplicateUdp.reason, 'udp-ambiguous');

  const duplicateDns = runner.assessRuntimeTrafficEvidence(
    createRuntimeJournal({
      runId: evidence.runId,
      sequence: 14,
      updatedAt: '2026-08-17T00:00:14.000Z',
      records: [
        ...baselineJournal.records,
        {
          sequence: 10,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: tcpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-tcp',
          coreAlias: '',
          protocol: 'tcp',
          hashedTuple: 'hash-tcp',
          correlationHash: tcpHash,
          destinationHash: digest('dest-tcp'),
          outboundTerminalHash: digest('term-tcp'),
          outboundChainHash: digest('chain-tcp'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'tcp'
        },
        {
          sequence: 11,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: udpHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-udp',
          coreAlias: '',
          protocol: 'udp',
          hashedTuple: 'hash-udp',
          correlationHash: udpHash,
          destinationHash: digest('dest-udp'),
          outboundTerminalHash: digest('term-udp'),
          outboundChainHash: digest('chain-udp'),
          outboundChainLength: 2,
          counterDelta: 1,
          detail: 'udp'
        },
        {
          sequence: 12,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: dnsHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-dns-a',
          coreAlias: '',
          protocol: 'dns',
          hashedTuple: 'hash-dns-a',
          correlationHash: dnsHash,
          destinationHash: digest('dest-dns-a'),
          outboundTerminalHash: digest('term-dns-a'),
          outboundChainHash: digest('chain-dns-a'),
          outboundChainLength: 1,
          counterDelta: 1,
          detail: 'dns'
        },
        {
          sequence: 13,
          kind: 'traffic',
          ingress: 'tun',
          linkageStatus: 'linked',
          flowIdHash: dnsHash,
          sessionIdHash: '12345678',
          traceAlias: 'trace-dns-b',
          coreAlias: '',
          protocol: 'dns',
          hashedTuple: 'hash-dns-b',
          correlationHash: dnsHash,
          destinationHash: digest('dest-dns-b'),
          outboundTerminalHash: digest('term-dns-b'),
          outboundChainHash: digest('chain-dns-b'),
          outboundChainLength: 1,
          counterDelta: 1,
          detail: 'dns'
        }
      ]
    }),
    baseline,
    probe
  );
  assert.equal(duplicateDns.ready, false);
  assert.equal(duplicateDns.reason, 'dns-ambiguous');
});

test('phase4 runner normalizes vendor HarmonyOS 6 build strings before schema validation', async () => {
  const runner = await import(modulePath);
  assert.equal(
    runner.normalizeHarmonyOsVersion('CLS-AL00 6.1.0.135(SP8C00E120R4P8)'),
    'HarmonyOS 6.1.0.135'
  );
  assert.equal(runner.normalizeHarmonyOsVersion('HarmonyOS 6.0.0'), 'HarmonyOS 6.0.0');
  assert.equal(runner.normalizeHarmonyOsVersion('OpenHarmony 5.0.2'), null);
});

test('phase4 runner parses all device LAN interfaces and selects the unique hotspot subnet', async () => {
  const runner = await import(modulePath);
  const deviceIpv4Candidates = runner.parseDeviceLanIpv4Candidates([
    'wlan0 Link encap:Ethernet',
    '  inet addr:30.231.216.149 Bcast:30.231.223.255 Mask:255.255.248.0',
    'wlan1 Link encap:Ethernet',
    '  inet addr:192.168.43.1 Bcast:192.168.43.255 Mask:255.255.255.0',
    'ancowlan0 Link encap:Ethernet',
    '  inet addr:172.17.1.1 Bcast:172.17.1.255 Mask:255.255.255.0'
  ].join('\n'));
  assert.deepEqual(deviceIpv4Candidates, [
    { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
    { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' },
    { name: 'ancowlan0', address: '172.17.1.1', netmask: '255.255.255.0' }
  ]);

  const selected = runner.selectControlledLanOriginAddress({
    en0: [{ address: '192.168.43.4', netmask: '255.255.255.0', family: 'IPv4', internal: false }],
    utun9: [{ address: '10.0.0.2', netmask: '255.255.255.255', family: 'IPv4', internal: false }]
  }, { deviceIpv4Candidates });
  assert.equal(selected.ipv4.name, 'en0');
  assert.equal(selected.ipv4.address, '192.168.43.4');
});

test('phase4 runner default origin adapter forwards device WLAN facts', async () => {
  const source = await fs.readFile(modulePath, 'utf8');
  assert.match(source, /startOriginImpl\s*=\s*async\s*\(options\)\s*=>\s*await defaultStartOrigin\(options\)/u);
});

test('phase4 runner routes every semantic tap through the reliable uitest click helper and fail-closes command errors', async () => {
  const source = await fs.readFile(modulePath, 'utf8');
  assert.match(source, /async function clickLayoutNode[\s\S]*'shell', 'uitest', 'uiInput', 'click'/u);
  assert.match(source, /if \(result\?\.error \|\| result\?\.exitCode !== 0 \|\| result\?\.timedOut\)[\s\S]*UI_AUTOMATION_UNSUPPORTED/u);
  assert.doesNotMatch(source, /async function clickLayoutNode[\s\S]{0,500}'shell', 'uinput', '-T', '-c'/u);
});

test('phase4 runner gracefully stops VPN through Home before force-stopping bundle processes', async () => {
  const runner = await import(modulePath);
  const actionLayout = (text) => ({
    root: {
      attributes: {},
      children: [{
        attributes: {
          id: 'home.vpn.action',
          type: 'Button',
          text,
          bounds: '[52,1700][1164,1856]',
          clickable: 'true',
          enabled: 'true'
        }
      }]
    }
  });
  const layouts = [actionLayout('Stop VPN global capture'), actionLayout('Stop VPN global capture'), actionLayout('Start VPN global capture')];
  const calls = [];
  const result = await runner.defaultStopVpn({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    execImpl: async (_command, args) => {
      calls.push(args.join(' '));
      return { exitCode: 0, stdout: '', stderr: '' };
    },
    readLayoutImpl: async () => layouts.shift(),
    clickLayoutNodeImpl: async () => { calls.push('click-stop'); },
    delayImpl: async () => { calls.push('poll-delay'); },
    maxAttempts: 3
  });
  assert.equal(result.stopped, true);
  assert.equal(calls.filter((entry) => entry === 'click-stop').length, 1);
  assert.ok(calls.some((entry) => entry.includes('aa start')));
  const homeIndex = calls.findIndex((entry) => entry.includes(' shell uitest uiInput keyEvent Home'));
  const startIndex = calls.findIndex((entry) => entry.includes(' shell aa start '));
  const clickIndex = calls.findIndex((entry) => entry === 'click-stop');
  assert.ok(homeIndex >= 0, 'stop helper must normalize Home first');
  assert.ok(startIndex > homeIndex, 'production launch must happen after Home normalize');
  assert.ok(clickIndex > startIndex, 'layout read/click must happen after production launch');

  const source = await fs.readFile(modulePath, 'utf8');
  const finallyBlock = source.match(/\} finally \{[\s\S]*?return persistedProof;/u)?.[0] ?? '';
  const gracefulStopIndex = finallyBlock.indexOf('await stopVpnImpl(');
  const forceStopIndex = finallyBlock.indexOf('forceStopBundleImpl(');
  assert.ok(gracefulStopIndex >= 0, 'finally must await graceful VPN stop');
  assert.ok(forceStopIndex > gracefulStopIndex, 'force-stop cleanup must run only after graceful VPN stop');
  assert.doesNotMatch(finallyBlock, /Promise\.allSettled\(\[[\s\S]*?stopVpnImpl/u);

  await assert.rejects(
    () => runner.defaultForceStopBundle({
      target: 'SERIAL123',
      hdcCommand: '/sdk/hdc',
      bundleName: 'com.cmfa.phase4.trafficprobe',
      execImpl: async () => ({ exitCode: 1, stdout: '', stderr: '' })
    }),
    /STOP_CLEANUP_NOT_PROVEN/u
  );

  await assert.rejects(
    () => runner.defaultStopVpn({
      target: 'SERIAL123',
      hdcCommand: '/sdk/hdc',
      execImpl: async (_command, args) => {
        if (args.join(' ').includes(' shell uitest uiInput keyEvent Home')) {
          return { exitCode: 1, stdout: '', stderr: '' };
        }
        return { exitCode: 0, stdout: '', stderr: '' };
      },
      readLayoutImpl: async () => actionLayout('Stop VPN global capture'),
      maxAttempts: 1
    }),
    /STOP_CLEANUP_NOT_PROVEN/u
  );
});

test('phase4 runner canonicalizes decorated HDC fport tasks, removes forwards with split argv, and leaves no owned tasks behind', async () => {
  const runner = await import(modulePath);
  const tasks = new Set(['SERIAL123    tcp:49999 tcp:49998    [Forward]']);
  const calls = [];
  const ports = [41001, 41002];
  const runtimeProof = createRuntimeJournal({
    runId: uuid(),
    records: [
      createRuntimeLifecycleRecord(1, 'tun-start-ok'),
      createRuntimeLifecycleRecord(2, 'proxy-activate-ok'),
      createRuntimeLifecycleRecord(3, 'STATE_CHANGED:RUNNING')
    ]
  });
  const result = await runner.defaultRunLocalListenerProof({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    execImpl: async (_command, args) => {
      calls.push([...args]);
      const command = args.slice(2);
      if (command[0] === 'fport' && command[1] === 'ls') {
        return { exitCode: 0, stdout: `${[...tasks].join('\n')}\n`, stderr: '' };
      }
      if (command[0] === 'fport' && command[1] === 'rm') {
        tasks.delete(`SERIAL123    ${command[2]} ${command[3]}    [Forward]`);
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      if (command[0] === 'fport') {
        tasks.add(`SERIAL123    ${command[1]} ${command[2]}    [Forward]`);
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      throw new Error(`unexpected command ${command.join(' ')}`);
    },
    origin: { tcp: { host: '192.168.43.4', port: 42000 } },
    runId: runtimeProof.runId,
    runtimeProof,
    allocateLocalPortImpl: async () => ports.shift(),
    runHttpConnectProbeImpl: async ({ localPort }) => ({ ok: localPort === 41001 }),
    runSocks5ProbeImpl: async ({ localPort }) => ({ ok: localPort === 41002 })
  });

  assert.equal(result.result, 'pass');
  assert.deepEqual(result.http, { ingress: 'local-http', outcome: 'pass', correlated: true });
  assert.deepEqual(result.socks, { ingress: 'local-socks', outcome: 'pass', correlated: true });
  assert.deepEqual([...tasks], ['SERIAL123    tcp:49999 tcp:49998    [Forward]']);
  const removedTasks = calls
    .filter((args) => args[2] === 'fport' && args[3] === 'rm')
    .map((args) => args.slice(4))
    .sort();
  assert.deepEqual(removedTasks, [
    ['tcp:41001', 'tcp:7890'],
    ['tcp:41002', 'tcp:7891']
  ]);
});

test('phase4 runner fport parser fail-closes on non-tcp, extra tokens, control chars, and ambiguous decorated tasks', async () => {
  const runner = await import(modulePath);
  assert.deepEqual(
    runner.parseFportTaskLines('SERIAL123    tcp:41001 tcp:7890    [Forward]\ntcp:41002 tcp:7891\n'),
    ['tcp:41001 tcp:7890', 'tcp:41002 tcp:7891']
  );
  assert.throws(
    () => runner.parseFportTaskLines('SERIAL123    udp:41001 tcp:7890    [Forward]\n'),
    /LOCAL_LISTENER_PROOF_FAILED/u
  );
  assert.throws(
    () => runner.parseFportTaskLines('SERIAL123    tcp:41001 tcp:7890    [Forward] extra\n'),
    /LOCAL_LISTENER_PROOF_FAILED/u
  );
  assert.throws(
    () => runner.parseFportTaskLines('tcp:41001 tcp:7890\u0007\n'),
    /LOCAL_LISTENER_PROOF_FAILED/u
  );
  assert.throws(
    () => runner.parseFportTaskLines('SERIAL123 tcp:41001 tcp:7890 [Forward]\nSERIAL456 tcp:41001 tcp:7890 [Forward]\n'),
    /LOCAL_LISTENER_PROOF_FAILED/u
  );
});

test('phase4 runner does not over-correlate local listener proofs without current runtime ownership evidence', async () => {
  const runner = await import(modulePath);
  const tasks = new Set(['tcp:49999 tcp:49998']);
  const ports = [41001, 41002];
  const runId = uuid();
  const runtimeProof = createRuntimeJournal({
    runId: uuid(),
    records: [
      createRuntimeLifecycleRecord(1, 'proxy-activate-ok'),
      createRuntimeLifecycleRecord(2, 'STATE_CHANGED:RUNNING')
    ]
  });
  const result = await runner.defaultRunLocalListenerProof({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    execImpl: async (_command, args) => {
      const command = args.slice(2);
      if (command[0] === 'fport' && command[1] === 'ls') {
        return { exitCode: 0, stdout: `${[...tasks].join('\n')}\n`, stderr: '' };
      }
      if (command[0] === 'fport' && command[1] === 'rm') {
        tasks.delete(`${command[2]} ${command[3]}`);
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      if (command[0] === 'fport') {
        tasks.add(`${command[1]} ${command[2]}`);
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      throw new Error(`unexpected command ${command.join(' ')}`);
    },
    origin: { tcp: { host: '192.168.43.4', port: 42000 } },
    runId,
    runtimeProof,
    allocateLocalPortImpl: async () => ports.shift(),
    runHttpConnectProbeImpl: async ({ localPort }) => ({ ok: localPort === 41001 }),
    runSocks5ProbeImpl: async ({ localPort }) => ({ ok: localPort === 41002 })
  });

  assert.equal(result.result, 'fail');
  assert.deepEqual(result.http, { ingress: 'local-http', outcome: 'pass', correlated: false });
  assert.deepEqual(result.socks, { ingress: 'local-socks', outcome: 'pass', correlated: false });
  assert.deepEqual([...tasks], ['tcp:49999 tcp:49998']);
});

test('phase4 runner removes a partially-created HDC forward when the second local forward fails', async () => {
  const runner = await import(modulePath);
  const tasks = new Set(['tcp:49999 tcp:49998']);
  let createCount = 0;
  let portIndex = 0;
  const result = await runner.defaultRunLocalListenerProof({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    execImpl: async (_command, args) => {
      const command = args.slice(2);
      if (command[0] === 'fport' && command[1] === 'ls') {
        return { exitCode: 0, stdout: `${[...tasks].join('\n')}\n`, stderr: '' };
      }
      if (command[0] === 'fport' && command[1] === 'rm') {
        tasks.delete(`${command[2]} ${command[3]}`);
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      if (command[0] === 'fport') {
        createCount += 1;
        if (createCount === 2) return { exitCode: 1, stdout: '', stderr: '' };
        tasks.add(`${command[1]} ${command[2]}`);
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      throw new Error('unexpected command');
    },
    origin: { tcp: { host: '192.168.43.4', port: 42000 } },
    runId: uuid(),
    allocateLocalPortImpl: async () => [41001, 41002][portIndex++],
    runHttpConnectProbeImpl: async () => ({ ok: true }),
    runSocks5ProbeImpl: async () => ({ ok: true })
  });
  assert.equal(result.result, 'fail');
  assert.deepEqual([...tasks], ['tcp:49999 tcp:49998']);
});

test('phase4 runner host clients complete bounded HTTP CONNECT and SOCKS5 tunnel handshakes with echo correlation', async () => {
  const runner = await import(modulePath);
  const listen = async (server) => {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', () => {
        server.off('error', reject);
        resolve();
      });
    });
    return server.address().port;
  };
  const close = async (server) => await new Promise((resolve) => server.close(() => resolve()));

  const httpServer = net.createServer((socket) => {
    let headerComplete = false;
    let buffered = Buffer.alloc(0);
    socket.on('data', (chunk) => {
      if (headerComplete) {
        socket.end(chunk);
        return;
      }
      buffered = Buffer.concat([buffered, chunk]);
      if (buffered.includes(Buffer.from('\r\n\r\n', 'ascii'))) {
        headerComplete = true;
        socket.write(Buffer.from('HTTP/1.1 200 Connection established\r\n\r\n', 'ascii'));
      }
    });
  });
  const httpPort = await listen(httpServer);
  try {
    const http = await runner.runHttpConnectThroughForward({
      localPort: httpPort,
      originHost: '192.168.43.4',
      originPort: 42000,
      runId: uuid(),
      timeoutMs: 1000
    });
    assert.equal(http.ok, true);
  } finally {
    await close(httpServer);
  }

  const socksServer = net.createServer((socket) => {
    let stage = 0;
    socket.on('data', (chunk) => {
      if (stage === 0) {
        stage = 1;
        socket.write(Buffer.from([0x05, 0x00]));
        return;
      }
      if (stage === 1) {
        stage = 2;
        socket.write(Buffer.from([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x12, 0x34]));
        return;
      }
      socket.end(chunk);
    });
  });
  const socksPort = await listen(socksServer);
  try {
    const socks = await runner.runSocks5ThroughForward({
      localPort: socksPort,
      originHost: '192.168.43.4',
      originPort: 42000,
      runId: uuid(),
      timeoutMs: 1000
    });
    assert.equal(socks.ok, true);
  } finally {
    await close(socksServer);
  }
});

test('phase4 runner removes every remote raw layout after pulling it and fails closed on cleanup errors', async () => {
  const runner = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase4-remote-layout-cleanup-'));
  const localPath = path.join(tempRoot, 'layout.json');
  const calls = [];
  try {
    const layout = await runner.dumpLayoutToHost({
      hdcCommand: '/mock/hdc',
      target: 'SERIAL123',
      localPath,
      cwd: HARMONY_ROOT,
      execImpl: async (_command, args) => {
        calls.push(args);
        if (args.includes('recv')) {
          await fs.writeFile(localPath, JSON.stringify({ root: { attributes: {} } }), 'utf8');
        }
        return { exitCode: 0, stdout: '', stderr: '', timedOut: false, error: null };
      }
    });
    assert.deepEqual(layout, { root: { attributes: {} } });
    assert.equal(calls.some((args) => args.includes('rm') && args.includes('-f')), true);

    await assert.rejects(
      runner.dumpLayoutToHost({
        hdcCommand: '/mock/hdc',
        target: 'SERIAL123',
        localPath,
        cwd: HARMONY_ROOT,
        execImpl: async (_command, args) => {
          if (args.includes('recv')) {
            await fs.writeFile(localPath, JSON.stringify({ root: { attributes: {} } }), 'utf8');
          }
          if (args.includes('rm')) {
            return { exitCode: 1, stdout: '', stderr: '', timedOut: false, error: null };
          }
          return { exitCode: 0, stdout: '', stderr: '', timedOut: false, error: null };
        }
      }),
      /REMOTE_LAYOUT_CLEANUP_FAILED|remote layout cleanup failed/u
    );
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase4 runner starts VPN through the canonical HomePage semantic action', async () => {
  const source = await fs.readFile(modulePath, 'utf8');
  assert.match(source, /selectUniqueActionableLayoutNode\(appLayout, \{ ids: \['home\.vpn\.action'\] \}\)/u);
  assert.doesNotMatch(source, /home\.vpn\.primary/u);
});

test('phase4 runner forwards the exact proof runId through the production ability launch', async () => {
  const runner = await import(modulePath);
  const runId = uuid();
  const args = runner.buildProductionLaunchArgs('SERIAL123', runId);

  assert.deepEqual(args.slice(-10), [
    'shell', 'aa', 'start',
    '-a', 'EntryAbility',
    '-b', 'com.github.kr328.clash.harmony',
    '--ps', 'cmfa.phase1.runId', runId
  ]);
  assert.equal(args.at(-1), runId);
});

test('phase4 runner appends only the UUID-gated runId to the production launch arguments', async () => {
  const runner = await import(modulePath);
  const runId = uuid();

  const legacyArgs = runner.buildProductionLaunchArgs('SERIAL123', runId);

  assert.deepEqual(legacyArgs, [
    '-t', 'SERIAL123',
    'shell', 'aa', 'start',
    '-a', 'EntryAbility',
    '-b', 'com.github.kr328.clash.harmony',
    '--ps', 'cmfa.phase1.runId', runId
  ]);
  const invalidRunArgs = runner.buildProductionLaunchArgs('SERIAL123', 'not-a-uuid');
  assert.deepEqual(invalidRunArgs, [
    '-t', 'SERIAL123',
    'shell', 'aa', 'start',
    '-a', 'EntryAbility',
    '-b', 'com.github.kr328.clash.harmony'
  ]);
  assert.equal(invalidRunArgs.includes('cmfa.phase1.runId'), false);
});

test('phase4 runner flattens one injected external origin into baseline and vpn probe launch args only', async () => {
  const runner = await import(modulePath);
  const runId = uuid();
  const originHandle = {
    publicKeyPinSha256: 'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    https: { host: 'origin.lan', port: 443, caPem: '-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----' },
    tcp: { host: 'origin.lan', port: 18080 },
    udp: { host: 'origin.lan', port: 15353 }
  };
  const externalOrigin = Object.freeze({
    hostIpv4: '11.22.33.44',
    tcpHostIpv4: '55.66.77.88',
    tcpPort: 80,
    udpPort: 20053,
    dnsPort: 20054
  });

  const baselineParameters = runner.buildProbeAbilityParameters(originHandle, externalOrigin, runId, 'baseline');
  const vpnParameters = runner.buildProbeAbilityParameters(originHandle, externalOrigin, runId, 'vpn');

  assert.equal(baselineParameters.externalOrigin, externalOrigin);
  assert.equal(vpnParameters.externalOrigin, externalOrigin);
  assert.equal(baselineParameters.captureMode, 'baseline');
  assert.equal(vpnParameters.captureMode, 'vpn');

  const baselineArgs = runner.buildProbeLaunchArgs('SERIAL123', baselineParameters);
  const vpnArgs = runner.buildProbeLaunchArgs('SERIAL123', vpnParameters);

  for (const args of [baselineArgs, vpnArgs]) {
    assert.match(args.join(' '), /externalOriginHost/u);
    assert.match(args.join(' '), /externalTcpHost/u);
    assert.match(args.join(' '), /externalOriginTcpPort/u);
    assert.match(args.join(' '), /externalOriginUdpPort/u);
    assert.match(args.join(' '), /externalOriginDnsPort/u);
    assert.equal(args.includes('11.22.33.44'), true);
    assert.equal(args.includes('55.66.77.88'), true);
    assert.equal(args.includes('80'), true);
    assert.equal(args.includes('20053'), true);
    assert.equal(args.includes('20054'), true);
  }

  const productionArgs = runner.buildProductionLaunchArgs('SERIAL123', runId);
  assert.equal(productionArgs.includes('externalOriginHost'), false);
  assert.equal(productionArgs.includes('externalTcpHost'), false);
  assert.equal(productionArgs.includes('externalOriginTcpPort'), false);
  assert.equal(productionArgs.includes('externalOriginUdpPort'), false);
  assert.equal(productionArgs.includes('externalOriginDnsPort'), false);
  assert.equal(productionArgs.includes('11.22.33.44'), false);
  assert.equal(productionArgs.includes('55.66.77.88'), false);
});

test('phase4 runner rejects disabled and non-clickable semantic actions before tapping', async () => {
  const runner = await import(modulePath);
  const actionLayout = (attributes) => ({
    root: {
      attributes: {},
      children: [{
        attributes: {
          id: 'home.vpn.action',
          bounds: '[52,1936][1164,2092]',
          ...attributes
        }
      }]
    }
  });

  assert.throws(
    () => runner.selectUniqueActionableLayoutNode(actionLayout({ clickable: 'false', enabled: 'true' }), {
      ids: ['home.vpn.action']
    }),
    /UI_AUTOMATION_UNSUPPORTED/u
  );
  assert.throws(
    () => runner.selectUniqueActionableLayoutNode(actionLayout({ clickable: 'true', enabled: 'false' }), {
      ids: ['home.vpn.action']
    }),
    /UI_AUTOMATION_UNSUPPORTED/u
  );

  const selected = runner.selectUniqueActionableLayoutNode(
    actionLayout({ clickable: 'true', enabled: 'true' }),
    { ids: ['home.vpn.action'] }
  );
  assert.equal(selected.centerX, 608);
  assert.equal(selected.centerY, 2014);
});

test('phase4 runner recognizes the HarmonyOS 6 VPN consent action by localized actionable text', async () => {
  const runner = await import(modulePath);
  const consentLayout = {
    root: {
      attributes: {},
      children: [{
        attributes: {
          type: 'WindowScene',
          bundleName: 'com.huawei.systemui'
        },
        children: [{
          attributes: { type: 'AlertDialog' },
          children: [{
            attributes: {
              id: '',
              resourceName: null,
              text: '允许',
              type: 'Text',
              bounds: '[720,1483][1045,1665]',
              clickable: 'true',
              enabled: 'true'
            }
          }]
        }]
      }]
    }
  };

  const selected = runner.selectUniqueVpnConsentAction(consentLayout);
  assert.equal(selected.centerX, 882);
  assert.equal(selected.centerY, 1574);
});

test('phase4 runner rejects a bare Allow text action outside a VPN consent scene', async () => {
  const runner = await import(modulePath);
  const unrelatedLayout = {
    root: {
      attributes: {},
      children: [{
        attributes: {
          text: 'Allow',
          type: 'Button',
          bounds: '[20,20][220,100]',
          clickable: 'true',
          enabled: 'true'
        }
      }]
    }
  };

  assert.equal(runner.selectUniqueVpnConsentAction(unrelatedLayout), null);
});

test('phase4 runner summarizes VPN consent layouts with structural counts only', async () => {
  const runner = await import(modulePath);
  const summary = runner.summarizeVpnConsentLayout({
    root: {
      attributes: {},
      children: [{
        attributes: {
          type: 'WindowScene',
          bundleName: 'com.github.kr328.clash.harmony',
          displayId: '0',
          hostWindowId: '100'
        },
        children: [{
          attributes: {
            id: 'home.vpn.action',
            text: 'profile-secret-name',
            type: 'Button',
            clickable: 'true',
            enabled: 'false'
          }
        }]
      }, {
        attributes: {
          type: 'WindowScene',
          bundleName: 'com.huawei.systemui',
          displayId: '0',
          hostWindowId: '101'
        },
        children: [{
          attributes: { type: 'AlertDialog' },
          children: [{
            attributes: {
              text: '允许',
              type: 'Text',
              clickable: 'true',
              enabled: 'true'
            }
          }, {
            attributes: {
              text: 'unrelated action',
              type: 'Button',
              clickable: 'true',
              enabled: 'true'
            }
          }]
        }]
      }]
    }
  });

  assert.deepEqual(summary, {
    nodeCount: 7,
    windowSceneCount: 2,
    appWindowSceneCount: 1,
    nonAppWindowSceneCount: 1,
    vpnWindowSceneCount: 0,
    permissionWindowSceneCount: 0,
    systemUiWindowSceneCount: 1,
    launcherWindowSceneCount: 0,
    settingsWindowSceneCount: 0,
    otherWindowSceneCount: 0,
    distinctDisplayCount: 1,
    distinctHostWindowCount: 2,
    actionableNodeCount: 2,
    consentHintNodeCount: 1,
    consentActionNodeCount: 1,
    dialogLikeNodeCount: 1
  });
  assert.equal(JSON.stringify(summary).includes('profile-secret-name'), false);
  assert.equal(JSON.stringify(summary).includes('com.huawei.systemui'), false);
});

test('phase4 runner polls for a delayed HarmonyOS VPN consent action before leaving the app', async () => {
  const runner = await import(modulePath);
  const consentLayout = {
    root: {
      attributes: {},
      children: [{
        attributes: {
          type: 'WindowScene',
          bundleName: 'com.huawei.systemui'
        },
        children: [{
          attributes: { type: 'AlertDialog' },
          children: [{
            attributes: {
              text: '允许',
              type: 'Text',
              bounds: '[720,1483][1045,1665]',
              clickable: 'true',
              enabled: 'true'
            }
          }]
        }]
      }]
    }
  };
  const layouts = [
    { root: { attributes: {}, children: [] } },
    consentLayout
  ];
  const delays = [];
  const observations = [];

  const evidence = await runner.waitForVpnConsentAction({
    readLayoutImpl: async () => layouts.shift(),
    maxAttempts: 2,
    pollIntervalMs: 250,
    delayImpl: async (milliseconds) => delays.push(milliseconds),
    onLayoutObserved: (summary) => observations.push(summary)
  });

  assert.equal(evidence.selection.centerX, 882);
  assert.equal(evidence.selection.centerY, 1574);
  assert.deepEqual(delays, [250]);
  assert.equal(observations.length, 2);
  assert.equal(observations[0].consentActionNodeCount, 0);
  assert.equal(observations[1].consentActionNodeCount, 1);

  const absent = await runner.waitForVpnConsentAction({
    readLayoutImpl: async () => ({ root: { attributes: {}, children: [] } }),
    maxAttempts: 2,
    pollIntervalMs: 250,
    delayImpl: async () => {}
  });
  assert.equal(absent, null);
});

test('phase4 runner scrolls the semantic container before tapping an offscreen VPN action', async () => {
  const runner = await import(modulePath);
  const layout = {
    root: {
      attributes: {},
      children: [{
      attributes: {
        type: 'Scroll',
        bounds: '[0,110][1216,2233]',
        scrollable: 'true'
      },
      children: [{
        attributes: {
          id: 'home.vpn.action',
          type: 'Button',
          bounds: '[52,2822][1164,2978]',
          clickable: 'true',
          enabled: 'true'
        }
      }]
    }]
    }
  };
  const scrollContainer = runner.selectUniqueScrollableLayoutNode(layout);
  const offscreenAction = runner.selectUniqueActionableLayoutNode(layout, { ids: ['home.vpn.action'] });
  assert.equal(runner.isLayoutSelectionWithinViewport(offscreenAction, scrollContainer), false);
  assert.equal(runner.isLayoutSelectionWithinViewport({
    ...offscreenAction,
    bounds: { left: 52, top: 1700, right: 1164, bottom: 1856 },
    centerX: 608,
    centerY: 1778
  }, scrollContainer), true);

  const source = await fs.readFile(modulePath, 'utf8');
  const uiAutomation = source.match(/async function defaultPerformUiAutomation[\s\S]*?\n\}\n\nexport async function defaultSnapshotNetworkState/u)?.[0] ?? '';
  assert.match(uiAutomation, /const launchResult = await execImpl\(hdcCommand, buildProductionLaunchArgs\(target, runId\), \{ cwd \}\);/u);
  assert.match(uiAutomation, /if \(launchResult\?\.error \|\| launchResult\?\.exitCode !== 0 \|\| launchResult\?\.timedOut\) \{[\s\S]*UI_AUTOMATION_UNSUPPORTED/u);
  assert.match(uiAutomation, /const launchEvidence = await waitForUniqueLayoutSelection\(\{[\s\S]*?selectImpl: \(layout\) => selectUniqueActionableLayoutNode\(layout, \{ ids: \['home\.vpn\.action'\] \}\)/u);
  assert.match(uiAutomation, /let appLayout = launchEvidence\.layout;/u);
  assert.match(uiAutomation, /let primary = launchEvidence\.selection;/u);
  assert.match(uiAutomation, /let scrollContainer = selectUniqueScrollableLayoutNode\(appLayout\);/u);
  assert.match(uiAutomation, /isLayoutSelectionWithinViewport\(primary, scrollContainer\)/u);
  assert.match(uiAutomation, /await scrollLayoutNodeForward\(/u);
  assert.match(
    uiAutomation,
    /scrollLayoutNodeForward\([\s\S]*?appLayout = await dumpLayoutToHost\([\s\S]*?selectUniqueActionableLayoutNode\(appLayout, \{ ids: \['home\.vpn\.action'\] \}\)/u
  );
  assert.doesNotMatch(
    uiAutomation,
    /let appLayout = await dumpLayoutToHost\([\s\S]*?selectUniqueScrollableLayoutNode\(appLayout\);[\s\S]*?selectUniqueActionableLayoutNode\(appLayout, \{ ids: \['home\.vpn\.action'\] \}\)/u
  );
  assert.match(source, /async function scrollLayoutNodeForward[\s\S]*?'shell', 'uinput', '-T', '-m'/u);
});

test('phase4 runner normalizes system UI to Home before launching and dumping the production app', async () => {
  const source = await fs.readFile(modulePath, 'utf8');
  const uiAutomation = source.match(/async function defaultPerformUiAutomation[\s\S]*?\n\}\n\nexport async function defaultSnapshotNetworkState/u)?.[0] ?? '';
  const firstHomeIndex = uiAutomation.indexOf("buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'keyEvent', 'Home'])");
  const productionLaunchIndex = uiAutomation.indexOf('buildProductionLaunchArgs(target, runId)');

  assert.notEqual(firstHomeIndex, -1, 'UI automation must issue Home');
  assert.notEqual(productionLaunchIndex, -1, 'UI automation must launch the production app');
  assert.ok(
    firstHomeIndex < productionLaunchIndex,
    'UI automation must close notification center/system overlays before its first app layout dump'
  );
});

test('phase4 runner waits for observed screen-off and screen-on transitions', async () => {
  const source = await fs.readFile(modulePath, 'utf8');
  const uiAutomation = source.match(/async function defaultPerformUiAutomation[\s\S]*?\n\}\n\nexport async function defaultSnapshotNetworkState/u)?.[0] ?? '';
  assert.match(uiAutomation, /waitForScreenState\(\{[\s\S]*expectedScreenOn: false/u);
  assert.match(uiAutomation, /waitForScreenState\(\{[\s\S]*expectedScreenOn: true/u);
  assert.match(
    uiAutomation,
    /waitForScreenState\(\{[\s\S]*?expectedScreenOn: true[\s\S]*?'keyEvent', 'Home'[\s\S]*?waitForUniqueLayoutSelection/u
  );
  assert.doesNotMatch(uiAutomation, /const afterScreen(?:Off|On) = await defaultReadScreenState/u);
});

test('phase4 runner selects the unique HarmonyOS VPN status icon by its exact system id', async () => {
  const runner = await import(modulePath);
  const layout = {
    root: {
      attributes: { id: 'root', type: 'Root', bounds: '[0,0][1216,2688]' },
      children: [
        {
          attributes: {
            id: 'StatusBarIconWrapper_status_bar_vpn',
            type: 'Image',
            bounds: '[980,18][1028,66]'
          }
        },
        {
          attributes: {
            id: 'StatusBarIconWrapper_status_bar_vpn_extra',
            type: 'Image',
            bounds: '[1030,18][1078,66]'
          }
        }
      ]
    }
  };

  const selected = runner.selectUniqueVpnStatusIndicator(layout);
  assert.equal(selected.node.attributes.id, 'StatusBarIconWrapper_status_bar_vpn');

  layout.root.children.push({
    attributes: {
      id: 'StatusBarIconWrapper_status_bar_vpn',
      type: 'Image',
      bounds: '[1080,18][1128,66]'
    }
  });
  assert.throws(
    () => runner.selectUniqueVpnStatusIndicator(layout),
    /UI_AUTOMATION_UNSUPPORTED/u
  );
});

test('phase4 runner opens notification center with a gesture derived from the largest valid layout bounds', async () => {
  const runner = await import(modulePath);
  const calls = [];
  const layout = {
    root: {
      attributes: { id: 'root', type: 'Root', bounds: '[0,0][1216,2688]' },
      children: [{
        attributes: { id: 'small', type: 'Column', bounds: '[40,100][1176,2200]' }
      }]
    }
  };

  await runner.openNotificationCenter(layout, {
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    execImpl: async (_command, args) => {
      calls.push(args);
      return { exitCode: 0, stdout: '', stderr: '' };
    }
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].slice(-9), [
    'shell', 'uinput', '-T', '-m', '304', '1', '304', '2016', '600'
  ]);
});

test('phase4 runner selects only the unique app-owned background-mode notification list item', async () => {
  const runner = await import(modulePath);
  const appNotification = {
    attributes: {
      id: 'notification_com.github.kr328.clash.harmony_bgmode_42',
      type: 'ListItem',
      bounds: '[28,360][1188,640]'
    }
  };
  const layout = {
    root: {
      attributes: { id: 'root', type: 'Root', bounds: '[0,0][1216,2688]' },
      children: [
        appNotification,
        {
          attributes: {
            id: 'notification_other.bundle_bgmode_7',
            type: 'ListItem',
            bounds: '[28,660][1188,940]'
          }
        },
        {
          attributes: {
            id: 'notification_com.github.kr328.clash.harmony_bgmode_43',
            type: 'Text',
            bounds: '[60,380][900,430]'
          }
        }
      ]
    }
  };

  const selected = runner.selectUniqueAppOngoingNotification(layout);
  assert.equal(selected.node, appNotification);

  layout.root.children.push({
    attributes: {
      id: 'notification_com.github.kr328.clash.harmony_bgmode_44',
      type: 'ListItem',
      bounds: '[28,960][1188,1240]'
    }
  });
  assert.throws(
    () => runner.selectUniqueAppOngoingNotification(layout),
    /UI_AUTOMATION_UNSUPPORTED/u
  );
});

test('phase4 runner summarizes only non-content system UI anchor counts for diagnostics', async () => {
  const runner = await import(modulePath);
  const layout = {
    root: {
      attributes: { id: 'root', type: 'Root' },
      children: [
        { attributes: { id: 'other', type: 'ListItem', text: 'private notification' } },
        { attributes: { id: 'com.github.kr328.clash.harmony_card', type: 'Row', text: 'private app text' } },
        { attributes: { id: 'other.bundle_bgmode_1', type: 'ListItem', text: 'private background text' } },
        { attributes: { id: 'com.github.kr328.clash.harmony_bgmode_2', type: 'ListItem', text: 'private target text' } }
      ]
    }
  };

  assert.deepEqual(runner.summarizeSystemUiAnchors(layout), {
    listItemCount: 3,
    appBundleIdCount: 2,
    appBundleListItemCount: 1,
    appOwnedListItemAncestorCount: 1,
    backgroundModeIdCount: 2,
    backgroundModeListItemCount: 2,
    appBackgroundModeIdCount: 1,
    appBackgroundModeListItemCount: 1
  });
});

test('phase4 runner polls fresh layouts only while a strict semantic selector has zero matches', async () => {
  const runner = await import(modulePath);
  const layouts = [
    { root: { attributes: { id: 'root' }, children: [] } },
    {
      root: {
        attributes: { id: 'root' },
        children: [{
          attributes: {
            id: 'StatusBarIconWrapper_status_bar_vpn',
            type: 'Image',
            bounds: '[980,18][1028,66]'
          }
        }]
      }
    }
  ];
  const delays = [];
  const evidence = await runner.waitForUniqueLayoutSelection({
    readLayoutImpl: async () => layouts.shift(),
    selectImpl: runner.selectUniqueVpnStatusIndicator,
    maxAttempts: 2,
    pollIntervalMs: 250,
    delayImpl: async (milliseconds) => delays.push(milliseconds)
  });

  assert.equal(evidence.selection.node.attributes.id, 'StatusBarIconWrapper_status_bar_vpn');
  assert.deepEqual(delays, [250]);

  await assert.rejects(
    runner.waitForUniqueLayoutSelection({
      readLayoutImpl: async () => ({
        root: {
          attributes: { id: 'root' },
          children: [
            { attributes: { id: 'StatusBarIconWrapper_status_bar_vpn', bounds: '[0,0][10,10]' } },
            { attributes: { id: 'StatusBarIconWrapper_status_bar_vpn', bounds: '[20,0][30,10]' } }
          ]
        }
      }),
      selectImpl: runner.selectUniqueVpnStatusIndicator,
      maxAttempts: 2,
      delayImpl: async () => {
        throw new Error('ambiguity must not be retried');
      }
    }),
    /UI_AUTOMATION_UNSUPPORTED/u
  );
});

test('phase4 runner launch polling tolerates initial Settings layouts until the unique Home vpn action appears', async () => {
  const runner = await import(modulePath);
  const layouts = [
    {
      root: {
        attributes: { id: 'root' },
        children: Array.from({ length: 5 }, (_, index) => ({
          attributes: {
            id: `settings.scroll.${index}`,
            type: 'Scroll',
            scrollable: 'true',
            bounds: `[0,${index * 100}][1200,${(index + 1) * 100 + 600}]`
          }
        }))
      }
    },
    {
      root: {
        attributes: { id: 'root' },
        children: [{
          attributes: {
            id: 'settings.scroll.only',
            type: 'Scroll',
            scrollable: 'true',
            bounds: '[0,0][1200,2200]'
          }
        }]
      }
    },
    {
      root: {
        attributes: { id: 'root' },
        children: [{
          attributes: {
            id: 'home.scroll',
            type: 'Scroll',
            scrollable: 'true',
            bounds: '[0,0][1200,2200]'
          },
          children: [{
            attributes: {
              id: 'home.vpn.action',
              type: 'Button',
              text: 'Start VPN global capture',
              bounds: '[52,1700][1164,1856]',
              clickable: 'true',
              enabled: 'true'
            }
          }]
        }]
      }
    }
  ];
  const delays = [];

  const evidence = await runner.waitForUniqueLayoutSelection({
    readLayoutImpl: async () => layouts.shift(),
    selectImpl: (layout) => runner.selectUniqueActionableLayoutNode(layout, { ids: ['home.vpn.action'] }),
    maxAttempts: 3,
    pollIntervalMs: 250,
    delayImpl: async (milliseconds) => delays.push(milliseconds)
  });

  assert.equal(evidence.selection.node.attributes.id, 'home.vpn.action');
  assert.deepEqual(delays, [250, 250]);

  await assert.rejects(
    runner.waitForUniqueLayoutSelection({
      readLayoutImpl: async () => ({
        root: {
          attributes: { id: 'root' },
          children: [{
            attributes: {
              id: 'home.scroll',
              type: 'Scroll',
              scrollable: 'true',
              bounds: '[0,0][1200,2200]'
            },
            children: [
              {
                attributes: {
                  id: 'home.vpn.action',
                  type: 'Button',
                  bounds: '[52,1700][1164,1856]',
                  clickable: 'true',
                  enabled: 'true'
                }
              },
              {
                attributes: {
                  id: 'home.vpn.action',
                  type: 'Button',
                  bounds: '[52,1500][1164,1656]',
                  clickable: 'true',
                  enabled: 'true'
                }
              }
            ]
          }]
        }
      }),
      selectImpl: (layout) => runner.selectUniqueActionableLayoutNode(layout, { ids: ['home.vpn.action'] }),
      maxAttempts: 2,
      delayImpl: async () => {
        throw new Error('ambiguity must not be retried');
      }
    }),
    /UI_AUTOMATION_UNSUPPORTED/u
  );
});

test('phase4 runner fresh-dumps the opened notification center and does not use app-local placeholder selectors', async () => {
  const source = await fs.readFile(modulePath, 'utf8');
  const uiAutomation = source.match(/async function defaultPerformUiAutomation[\s\S]*?\n\}\n\nexport async function defaultSnapshotNetworkState/u)?.[0] ?? '';

  assert.match(uiAutomation, /waitForUniqueLayoutSelection\(\{[\s\S]*?selectImpl: selectUniqueVpnStatusIndicator/u);
  assert.match(uiAutomation, /await openNotificationCenter\(indicatorLayout/u);
  assert.match(
    uiAutomation,
    /await openNotificationCenter\(indicatorLayout[\s\S]*?waitForUniqueLayoutSelection\(\{[\s\S]*?selectImpl: selectUniqueAppOngoingNotification/u
  );
  assert.doesNotMatch(uiAutomation, /home_vpn_notification_label|vpn_indicator|ongoing_notification/u);
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
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('p-sign') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
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
        { flowId: uuid(), stepId: 'http-connect', ingressExpectation: 'local-http-connect-listener', outcome: 'fail', transport: 'tcp', targetPort: 7890, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 10, bytesReceived: 0 },
        { flowId: uuid(), stepId: 'socks5', ingressExpectation: 'local-socks5-listener', outcome: 'fail', transport: 'tcp', targetPort: 7891, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 10, bytesReceived: 0 }
      ],
      failures: []
    },
    localProof: {
      http: {
        ingress: 'local-http',
        outcome: 'pass',
        correlated: true,
        sessionId,
        flowId: uuid()
      },
      socks: {
        ingress: 'local-socks',
        outcome: 'pass',
        correlated: true,
        sessionId,
        flowId: uuid()
      }
    },
    runtime: {
      sessionAlias: `session-${runner.hashOpaqueCorrelationId(sessionId)}`,
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
          destinationHash: digest('dest-a'),
          outboundTerminalHash: digest('term-a'),
          outboundChainHash: digest('chain-a'),
          outboundChainLength: 2,
          counterDelta: 1,
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
          destinationHash: digest('dest-b'),
          outboundTerminalHash: digest('term-b'),
          outboundChainHash: digest('chain-b'),
          outboundChainLength: 2,
          counterDelta: 1,
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
          destinationHash: digest('dest-c'),
          outboundTerminalHash: digest('term-c'),
          outboundChainHash: digest('chain-c'),
          outboundChainLength: 1,
          counterDelta: 1,
          detail: 'dns',
          counterSnapshot: { rxPackets: 4, txPackets: 4, rxBytes: 40, txBytes: 40 }
        }
      ]
    },
    packages: {
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('signature:p') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('signature:q') }
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

test('phase4 runner skips graceful VPN stop before any start attempt but still force-stops bundles and restores state', async () => {
  const runner = await import(modulePath);
  const outputPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-prestart-cleanup-${process.pid}.json`);
  const calls = [];
  const result = await runner.runPhase4DeviceProof({
    outputPath,
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => ({
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('p-sign') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
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
      if (joined.endsWith('shell ifconfig')) {
        return {
          exitCode: 0,
          stdout: 'wlan0 Link encap:Ethernet\n  inet addr:192.168.43.8 Bcast:192.168.43.255 Mask:255.255.255.0\n',
          stderr: ''
        };
      }
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      throw new Error(`unexpected command ${joined}`);
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    startOriginImpl: async () => ({
      close: async () => { calls.push('origin.close'); }
    }),
    runBaselineProbeImpl: async () => ({ result: 'pass' }),
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: false }),
    stopVpnImpl: async () => {
      calls.push('stopVpn');
      throw new Error('stop should not be called');
    },
    forceStopBundleImpl: async ({ bundleName }) => { calls.push(`forceStop:${bundleName}`); },
    restoreNetworkStateImpl: async () => { calls.push('restoreNetwork'); return { restored: true }; },
    restoreScreenStateImpl: async () => { calls.push('restoreScreen'); return { restored: true }; },
    writeValidatedProofImpl: async (candidate) => candidate
  });

  assert.equal(result.result, 'incomplete');
  assert.equal(calls.includes('stopVpn'), false);
  assert.deepEqual(
    calls.filter((entry) => entry.startsWith('forceStop:')).sort(),
    ['forceStop:com.cmfa.phase4.trafficprobe', 'forceStop:com.github.kr328.clash.harmony']
  );
  assert.equal(calls.includes('origin.close'), true);
  assert.equal(calls.includes('restoreNetwork'), true);
  assert.equal(calls.includes('restoreScreen'), true);
  assert.equal(result.failures.some((entry) => entry.code === 'STOP_CLEANUP_NOT_PROVEN'), false);
  assert.match(result.failures.map((entry) => entry.code).join(','), /NETWORK_RECOVERY_NOT_PROVEN/u);
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
    localProof: {
      http: {
        ingress: 'local-http',
        outcome: 'pass',
        correlated: true,
        sessionId: sessionUuid,
        flowId: uuid()
      },
      socks: {
        ingress: 'local-socks',
        outcome: 'pass',
        correlated: true,
        sessionId: sessionUuid,
        flowId: uuid()
      }
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
          destinationHash: digest('dest-a'),
          outboundTerminalHash: digest('term-a'),
          outboundChainHash: digest('chain-a'),
          outboundChainLength: 2,
          counterDelta: 1,
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
          destinationHash: digest('dest-b'),
          outboundTerminalHash: digest('term-b'),
          outboundChainHash: digest('chain-b'),
          outboundChainLength: 2,
          counterDelta: 1,
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
          destinationHash: digest('dest-c'),
          outboundTerminalHash: digest('term-c'),
          outboundChainHash: digest('chain-c'),
          outboundChainLength: 1,
          counterDelta: 1,
          detail: 'dns',
          counterSnapshot: { rxPackets: 7, txPackets: 7, rxBytes: 70, txBytes: 70 }
        }
      ]
    },
    packages: {
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('signature:p') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('signature:q') }
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
  const realToggle = {
    attributes: {
      id: 'Setting.Wlan.WlanConfig.WlanSwitch.result',
      type: 'Toggle',
      checked: 'true',
      selected: 'false',
      enabled: 'true',
      bounds: '[1008,403][1125,468]'
    },
    children: []
  };
  assert.deepEqual(
    runner.readExplicitBooleanState(realToggle),
    { supported: true, value: true, source: 'checked' }
  );
  const selected = runner.selectUniqueLayoutNode([realToggle], {
    ids: ['Setting.Wlan.WlanConfig.WlanSwitch.result']
  });
  assert.deepEqual({ centerX: selected.centerX, centerY: selected.centerY }, { centerX: 1066, centerY: 435 });
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
  assert.equal(restoreHarness.calls.filter((entry) => entry.includes(' uitest uiInput click ')).length, 2);

  const alreadyCorrectHarness = createLayoutExecHarness({
    layouts: [createNetworkLayout({ wifiState: 'on', mobileState: 'off' })]
  });
  const alreadyCorrect = await runner.defaultRestoreNetworkState(snapshot, {
    execImpl: alreadyCorrectHarness.execImpl,
    cwd: HARMONY_ROOT
  });
  assert.equal(alreadyCorrect.restored, true);
  assert.equal(alreadyCorrectHarness.calls.filter((entry) => entry.includes(' uitest uiInput click ')).length, 0);

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
  assert.equal(restoreBothOnHarness.calls.filter((entry) => entry.includes(' uitest uiInput click ')).length, 2);
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
  assert.equal(bothOnHarness.calls.filter((entry) => entry.includes(' uitest uiInput click ')).length, 4);

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
  assert.equal(oneOnHarness.calls.filter((entry) => entry.includes(' uitest uiInput click ')).length, 2);

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

test('phase4 runner default network recovery waits for loss callback before restore and still restores when the callback fails', async () => {
  const runner = await import(modulePath);
  const snapshot = {
    supported: true,
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    wifiSelector: { resourceNames: ['wifi_switch'] },
    mobileSelector: { resourceNames: ['mobile_data_switch'] },
    wifiEnabled: true,
    mobileEnabled: true
  };
  const callbackOrderCalls = [];
  const callbackOrderHarness = createLayoutExecHarness({
    layouts: [
      createNetworkLayout({ wifiState: 'on', mobileState: 'on' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'on' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'off' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'off' }),
      createNetworkLayout({ wifiState: 'on', mobileState: 'on' })
    ]
  });
  const recovered = await runner.defaultExerciseNetworkRecovery(snapshot, {
    execImpl: async (command, args, options) => {
      callbackOrderCalls.push(args.join(' '));
      return await callbackOrderHarness.execImpl(command, args, options);
    },
    cwd: HARMONY_ROOT,
    onLossObserved: async () => {
      callbackOrderCalls.push('loss-callback');
    }
  });

  assert.equal(recovered.recovered, true);
  const callbackIndex = callbackOrderCalls.indexOf('loss-callback');
  assert.ok(callbackIndex >= 0, 'loss callback must run');
  const clickIndexes = callbackOrderCalls
    .map((entry, index) => entry.includes(' uitest uiInput click ') ? index : -1)
    .filter((index) => index >= 0);
  assert.equal(clickIndexes.filter((index) => index < callbackIndex).length, 2);
  assert.equal(clickIndexes.filter((index) => index > callbackIndex).length, 2);

  const failureCalls = [];
  const failureHarness = createLayoutExecHarness({
    layouts: [
      createNetworkLayout({ wifiState: 'on', mobileState: 'on' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'on' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'off' }),
      createNetworkLayout({ wifiState: 'off', mobileState: 'off' }),
      createNetworkLayout({ wifiState: 'on', mobileState: 'on' })
    ]
  });
  await assert.rejects(
    () => runner.defaultExerciseNetworkRecovery(snapshot, {
      execImpl: async (command, args, options) => {
        failureCalls.push(args.join(' '));
        return await failureHarness.execImpl(command, args, options);
      },
      cwd: HARMONY_ROOT,
      onLossObserved: async () => {
        failureCalls.push('loss-callback');
        throw Object.assign(new Error('NETWORK_RECOVERY_RUNTIME_TIMEOUT: missing recovering window.'), {
          code: 'NETWORK_RECOVERY_RUNTIME_TIMEOUT'
        });
      }
    }),
    /NETWORK_RECOVERY_RUNTIME_TIMEOUT/u
  );
  const failureCallbackIndex = failureCalls.indexOf('loss-callback');
  assert.ok(failureCallbackIndex >= 0, 'failing loss callback must still run');
  const failureClickIndexes = failureCalls
    .map((entry, index) => entry.includes(' uitest uiInput click ') ? index : -1)
    .filter((index) => index >= 0);
  assert.equal(failureClickIndexes.filter((index) => index < failureCallbackIndex).length, 2);
  assert.equal(failureClickIndexes.filter((index) => index > failureCallbackIndex).length, 2);
});

test('phase4 runner uses explicit airplane mode for controlled loss and rejects a disabled hotspot fallback', async () => {
  const runner = await import(modulePath);
  const airplaneSelector = { ids: ['Setting.MobileNetwork.air_plane_group.air_plane_mode_setting.result'] };
  const makeAirplaneState = (enabled) => ({
    supported: true,
    airplaneModeEnabled: enabled,
    airplane: { selector: airplaneSelector, centerX: 1066, centerY: 435, value: enabled, source: 'checked' }
  });
  const hotspotSelector = { ids: ['Setting.hotspot_data_entry.hotspot_switch.hotspot_switch_setting.result'] };
  const makeHotspotState = (enabled) => ({
    supported: true,
    hotspotEnabled: enabled,
    hotspot: { selector: hotspotSelector, centerX: 1066, centerY: 435, value: enabled, source: 'checked' }
  });
  const snapshot = await runner.defaultSnapshotNetworkState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    observeNetworkStateImpl: async () => ({ supported: false }),
    observeAirplaneModeStateImpl: async () => makeAirplaneState(false),
    observeHotspotStateImpl: async () => makeHotspotState(false)
  });
  assert.deepEqual(
    { supported: snapshot.supported, mode: snapshot.mode, airplaneModeEnabled: snapshot.airplaneModeEnabled },
    { supported: true, mode: 'airplane', airplaneModeEnabled: false }
  );

  const states = [makeAirplaneState(false), makeAirplaneState(true), makeAirplaneState(true), makeAirplaneState(false)];
  const calls = [];
  const recovered = await runner.defaultExerciseNetworkRecovery(snapshot, {
    execImpl: async (_command, args) => {
      calls.push(args.join(' '));
      return { exitCode: 0, stdout: '', stderr: '' };
    },
    observeAirplaneModeStateImpl: async () => states.shift(),
    cwd: HARMONY_ROOT
  });
  assert.deepEqual(
    { supported: recovered.supported, recovered: recovered.recovered, lossObserved: recovered.lossObserved, toggled: recovered.toggled },
    { supported: true, recovered: true, lossObserved: true, toggled: ['airplane'] }
  );
  assert.equal(calls.filter((entry) => entry.includes(' uitest uiInput click ')).length, 2);

  const unsupported = await runner.defaultSnapshotNetworkState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    observeNetworkStateImpl: async () => ({ supported: false }),
    observeAirplaneModeStateImpl: async () => ({ supported: false }),
    observeHotspotStateImpl: async () => makeHotspotState(false)
  });
  assert.deepEqual(unsupported, { supported: false });
});

test('phase4 runner prefers airplane mode over an enabled hotspot for physical route loss', async () => {
  const runner = await import(modulePath);
  const snapshot = await runner.defaultSnapshotNetworkState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    observeNetworkStateImpl: async () => ({ supported: false }),
    observeAirplaneModeStateImpl: async () => ({
      supported: true,
      airplaneModeEnabled: false,
      airplane: {
        selector: { ids: ['Setting.MobileNetwork.air_plane_group.air_plane_mode_setting.result'] },
        centerX: 1066,
        centerY: 435,
        value: false,
        source: 'checked'
      }
    }),
    observeHotspotStateImpl: async () => ({
      supported: true,
      hotspotEnabled: true,
      hotspot: {
        selector: { ids: ['Setting.hotspot_data_entry.hotspot_switch.hotspot_switch_setting.result'] },
        centerX: 1066,
        centerY: 435,
        value: true,
        source: 'checked'
      }
    })
  });

  assert.deepEqual(
    {
      supported: snapshot.supported,
      mode: snapshot.mode,
      airplaneModeEnabled: snapshot.airplaneModeEnabled,
      hotspotEnabled: snapshot.hotspotEnabled
    },
    { supported: true, mode: 'airplane', airplaneModeEnabled: false, hotspotEnabled: true }
  );
});

test('phase4 runner restores an enabled hotspot after leaving airplane mode', async () => {
  const runner = await import(modulePath);
  const airplaneSelector = { ids: ['Setting.MobileNetwork.air_plane_group.air_plane_mode_setting.result'] };
  const hotspotSelector = { ids: ['Setting.hotspot_data_entry.hotspot_switch.hotspot_switch_setting.result'] };
  const airplaneStates = [true, false];
  const hotspotStates = [false, true];
  const calls = [];
  const result = await runner.defaultRestoreNetworkState({
    supported: true,
    mode: 'airplane',
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    airplaneSelector,
    airplaneModeEnabled: false,
    hotspotSelector,
    hotspotEnabled: true
  }, {
    execImpl: async (_command, args) => {
      calls.push(args.join(' '));
      return { exitCode: 0, stdout: '', stderr: '' };
    },
    observeAirplaneModeStateImpl: async () => {
      const enabled = airplaneStates.shift();
      return {
        supported: true,
        airplaneModeEnabled: enabled,
        airplane: { selector: airplaneSelector, centerX: 1066, centerY: 435, value: enabled, source: 'checked' }
      };
    },
    observeHotspotStateImpl: async () => {
      const enabled = hotspotStates.shift();
      return {
        supported: true,
        hotspotEnabled: enabled,
        hotspot: { selector: hotspotSelector, centerX: 1066, centerY: 435, value: enabled, source: 'checked' }
      };
    },
    cwd: HARMONY_ROOT
  });

  assert.deepEqual(result, { restored: true, clicks: ['airplane', 'hotspot'] });
  assert.equal(calls.filter((entry) => entry.includes(' uitest uiInput click ')).length, 2);
});

test('phase4 runner falls back to hotspot loss and restores the exact pre-state', async () => {
  const runner = await import(modulePath);
  const hotspotSelector = { ids: ['Setting.hotspot_data_entry.hotspot_switch.hotspot_switch_setting.result'] };
  const makeState = (enabled) => ({
    supported: true,
    hotspotEnabled: enabled,
    hotspot: { selector: hotspotSelector, centerX: 1066, centerY: 435, value: enabled, source: 'checked' }
  });
  const snapshot = await runner.defaultSnapshotNetworkState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    observeNetworkStateImpl: async () => ({ supported: false }),
    observeAirplaneModeStateImpl: async () => ({ supported: false }),
    observeHotspotStateImpl: async () => makeState(true)
  });
  assert.deepEqual(
    { supported: snapshot.supported, mode: snapshot.mode, hotspotEnabled: snapshot.hotspotEnabled },
    { supported: true, mode: 'hotspot', hotspotEnabled: true }
  );

  const states = [makeState(true), makeState(false), makeState(false), makeState(true)];
  const calls = [];
  const recovered = await runner.defaultExerciseNetworkRecovery(snapshot, {
    execImpl: async (_command, args) => {
      calls.push(args.join(' '));
      return { exitCode: 0, stdout: '', stderr: '' };
    },
    observeHotspotStateImpl: async () => states.shift(),
    cwd: HARMONY_ROOT
  });
  assert.deepEqual(
    { supported: recovered.supported, recovered: recovered.recovered, lossObserved: recovered.lossObserved, toggled: recovered.toggled },
    { supported: true, recovered: true, lossObserved: true, toggled: ['hotspot'] }
  );
  assert.equal(calls.filter((entry) => entry.includes(' uitest uiInput click ')).length, 2);
});

test('phase4 runner prefers wifi-hotspot recovery over airplane when Control Center Wi-Fi and wlan0+wlan1 are both available', async () => {
  const runner = await import(modulePath);
  const snapshot = await runner.defaultSnapshotNetworkState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    observeNetworkStateImpl: async () => ({ supported: false }),
    observeAirplaneModeStateImpl: async () => ({
      supported: true,
      airplaneModeEnabled: false,
      airplane: {
        selector: { ids: ['Setting.MobileNetwork.air_plane_group.air_plane_mode_setting.result'] },
        centerX: 1066,
        centerY: 435,
        value: false,
        source: 'checked'
      }
    }),
    observeHotspotStateImpl: async () => ({
      supported: true,
      hotspotEnabled: true,
      hotspot: {
        selector: { ids: ['Setting.hotspot_data_entry.hotspot_switch.hotspot_switch_setting.result'] },
        centerX: 1066,
        centerY: 435,
        value: true,
        source: 'checked'
      }
    }),
    observeControlCenterWifiStateImpl: async () => ({
      supported: true,
      wifiEnabled: false,
      wifi: {
        selector: { ids: ['transition_togglewifi_ui_extension'] },
        centerX: 1700,
        centerY: 270,
        value: false,
        source: 'checked'
      }
    }),
    readDeviceLanIpv4CandidatesImpl: async () => ([
      { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ])
  });

  assert.deepEqual(
    {
      supported: snapshot.supported,
      mode: snapshot.mode,
      wifiEnabled: snapshot.wifiEnabled,
      wifiUplinkInterfaceName: snapshot.wifiUplinkInterfaceName,
      hotspotLanInterfaceName: snapshot.hotspotLanInterfaceName,
      wifiUplinkFingerprintType: typeof snapshot.wifiUplinkFingerprint,
      hotspotLanFingerprintType: typeof snapshot.hotspotLanFingerprint,
      wifiUplinkAddress: 'wifiUplinkAddress' in snapshot,
      wifiUplinkNetmask: 'wifiUplinkNetmask' in snapshot,
      hotspotLanAddress: 'hotspotLanAddress' in snapshot,
      hotspotLanNetmask: 'hotspotLanNetmask' in snapshot,
      airplaneModeEnabled: 'airplaneModeEnabled' in snapshot
    },
    {
      supported: true,
      mode: 'wifi-hotspot',
      wifiEnabled: true,
      wifiUplinkInterfaceName: 'wlan0',
      hotspotLanInterfaceName: 'wlan1',
      wifiUplinkFingerprintType: 'string',
      hotspotLanFingerprintType: 'string',
      wifiUplinkAddress: false,
      wifiUplinkNetmask: false,
      hotspotLanAddress: false,
      hotspotLanNetmask: false,
      airplaneModeEnabled: false
    }
  );
});

test('phase4 runner opens Control Center from the top-right using relative screen bounds and toggles the unique Wi-Fi tile', async (t) => {
  const runner = await import(modulePath);
  const calls = [];
  const layout = createControlCenterLayout({
    bounds: { left: 100, top: 20, right: 2300, bottom: 3620 }
  });
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-control-center-'));
  t.after(async () => await fs.rm(tempRoot, { recursive: true, force: true }));

  await runner.openControlCenter(layout, {
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    execImpl: async (_command, args) => {
      calls.push(args.join(' '));
      return { exitCode: 0, stdout: '', stderr: '' };
    },
    cwd: HARMONY_ROOT
  });

  const gesture = calls.find((entry) => entry.includes(' shell uinput -T -m '));
  assert.ok(gesture, 'expected control center swipe');
  assert.match(gesture, /\s2028\s21\s2028\s1280\s600$/u);

  const observed = await runner.observeControlCenterWifiState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    execImpl: async (_command, args) => {
      const joined = args.join(' ');
      if (joined.includes('dumpLayout')) {
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      if (joined.includes(' file recv ') && joined.includes('cmfa-layout-')) {
        const localPath = args.at(-1);
        await fs.writeFile(localPath, `${JSON.stringify(layout)}\n`, 'utf8');
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      if (joined.includes(' shell rm -f ') && joined.includes('cmfa-layout-')) {
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      if (joined.includes(' shell uinput -T -m ')) {
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      throw new Error(`unexpected command ${joined}`);
    },
    fsApi: fs,
    tempRoot,
    cwd: HARMONY_ROOT
  });

  assert.equal(observed.supported, true);
  assert.equal(observed.wifiEnabled, true);
  assert.equal(observed.wifi.selector.ids[0], 'transition_togglewifi_ui_extension');
});

test('phase4 runner waits for wifi-hotspot loss before callback, then restores uplink after callback and keeps hotspot LAN present', async () => {
  const runner = await import(modulePath);
  const wifiSelector = { ids: ['transition_togglewifi_ui_extension'] };
  const makeVendorTileState = () => ({
    supported: true,
    wifiEnabled: false,
    wifi: { selector: wifiSelector, centerX: 1700, centerY: 270, value: false, source: 'checked' }
  });
  const snapshot = await runner.defaultSnapshotNetworkState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    observeNetworkStateImpl: async () => ({ supported: false }),
    observeAirplaneModeStateImpl: async () => ({ supported: false }),
    observeHotspotStateImpl: async () => ({
      supported: true,
      hotspotEnabled: true,
      hotspot: {
        selector: { ids: ['Setting.hotspot_data_entry.hotspot_switch.hotspot_switch_setting.result'] },
        centerX: 1066,
        centerY: 435,
        value: true,
        source: 'checked'
      }
    }),
    observeControlCenterWifiStateImpl: async () => makeVendorTileState(),
    readDeviceLanIpv4CandidatesImpl: async () => ([
      { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ])
  });
  const interfaceStates = [
    [
      { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ],
    [
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ],
    [
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ],
    [
      { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ]
  ];
  const wifiStates = [makeVendorTileState(), makeVendorTileState(), makeVendorTileState()];
  const calls = [];

  const recovered = await runner.defaultExerciseNetworkRecovery(snapshot, {
    execImpl: async (_command, args) => {
      calls.push(args.join(' '));
      return { exitCode: 0, stdout: '', stderr: '' };
    },
    observeControlCenterWifiStateImpl: async () => wifiStates.shift(),
    readDeviceLanIpv4CandidatesImpl: async () => interfaceStates.shift(),
    cwd: HARMONY_ROOT,
    onLossObserved: async () => {
      calls.push('loss-callback');
    }
  });

  assert.deepEqual(recovered, {
    supported: true,
    recovered: true,
    lossObserved: true,
    toggled: ['wifi']
  });
  const callbackIndex = calls.indexOf('loss-callback');
  assert.ok(callbackIndex >= 0, 'loss callback must run');
  const clickIndexes = calls
    .map((entry, index) => entry.includes(' uitest uiInput click ') ? index : -1)
    .filter((index) => index >= 0);
  assert.equal(clickIndexes.filter((index) => index < callbackIndex).length, 1);
  assert.equal(clickIndexes.filter((index) => index > callbackIndex).length, 1);
});

test('phase4 runner restores wifi-hotspot uplink even when the loss callback fails and rejects hotspot-lan disappearance', async () => {
  const runner = await import(modulePath);
  const wifiSelector = { ids: ['transition_togglewifi_ui_extension'] };
  const makeVendorTileState = () => ({
    supported: true,
    wifiEnabled: false,
    wifi: { selector: wifiSelector, centerX: 1700, centerY: 270, value: false, source: 'checked' }
  });
  const snapshot = await runner.defaultSnapshotNetworkState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    observeNetworkStateImpl: async () => ({ supported: false }),
    observeAirplaneModeStateImpl: async () => ({ supported: false }),
    observeHotspotStateImpl: async () => ({
      supported: true,
      hotspotEnabled: true,
      hotspot: {
        selector: { ids: ['Setting.hotspot_data_entry.hotspot_switch.hotspot_switch_setting.result'] },
        centerX: 1066,
        centerY: 435,
        value: true,
        source: 'checked'
      }
    }),
    observeControlCenterWifiStateImpl: async () => makeVendorTileState(),
    readDeviceLanIpv4CandidatesImpl: async () => ([
      { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ])
  });
  const failureCalls = [];
  const failureInterfaces = [
    [
      { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ],
    [
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ],
    [
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ],
    [
      { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ]
  ];
  const failureWifiStates = [makeVendorTileState(), makeVendorTileState(), makeVendorTileState()];
  await assert.rejects(
    () => runner.defaultExerciseNetworkRecovery(snapshot, {
      execImpl: async (_command, args) => {
        failureCalls.push(args.join(' '));
        return { exitCode: 0, stdout: '', stderr: '' };
      },
      observeControlCenterWifiStateImpl: async () => failureWifiStates.shift(),
      readDeviceLanIpv4CandidatesImpl: async () => failureInterfaces.shift(),
      cwd: HARMONY_ROOT,
      onLossObserved: async () => {
        failureCalls.push('loss-callback');
        throw Object.assign(new Error('NETWORK_RECOVERY_RUNTIME_TIMEOUT: missing recovering window.'), {
          code: 'NETWORK_RECOVERY_RUNTIME_TIMEOUT'
        });
      }
    }),
    /NETWORK_RECOVERY_RUNTIME_TIMEOUT/u
  );
  const failureCallbackIndex = failureCalls.indexOf('loss-callback');
  assert.ok(failureCallbackIndex >= 0, 'failing loss callback must still run');
  const failureClickIndexes = failureCalls
    .map((entry, index) => entry.includes(' uitest uiInput click ') ? index : -1)
    .filter((index) => index >= 0);
  assert.equal(failureClickIndexes.filter((index) => index < failureCallbackIndex).length, 1);
  assert.equal(failureClickIndexes.filter((index) => index > failureCallbackIndex).length, 1);

  await assert.rejects(
    () => runner.defaultExerciseNetworkRecovery(snapshot, {
      execImpl: async () => ({ exitCode: 0, stdout: '', stderr: '' }),
      observeControlCenterWifiStateImpl: async () => makeVendorTileState(),
      readDeviceLanIpv4CandidatesImpl: async () => [],
      cwd: HARMONY_ROOT
    }),
    /NETWORK_RECOVERY_NOT_PROVEN/u
  );
});

test('phase4 runner restores wifi-hotspot idempotently when uplink is already back', async () => {
  const runner = await import(modulePath);
  const wifiSelector = { ids: ['transition_togglewifi_ui_extension'] };
  const snapshot = await runner.defaultSnapshotNetworkState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    observeNetworkStateImpl: async () => ({ supported: false }),
    observeAirplaneModeStateImpl: async () => ({ supported: false }),
    observeHotspotStateImpl: async () => ({
      supported: true,
      hotspotEnabled: true,
      hotspot: {
        selector: { ids: ['Setting.hotspot_data_entry.hotspot_switch.hotspot_switch_setting.result'] },
        centerX: 1066,
        centerY: 435,
        value: true,
        source: 'checked'
      }
    }),
    observeControlCenterWifiStateImpl: async () => ({
      supported: true,
      wifiEnabled: false,
      wifi: { selector: wifiSelector, centerX: 1700, centerY: 270, value: false, source: 'checked' }
    }),
    readDeviceLanIpv4CandidatesImpl: async () => ([
      { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ])
  });
  const calls = [];
  const result = await runner.defaultRestoreNetworkState(snapshot, {
    execImpl: async (_command, args) => {
      calls.push(args.join(' '));
      return { exitCode: 0, stdout: '', stderr: '' };
    },
    observeControlCenterWifiStateImpl: async () => ({
      supported: true,
      wifiEnabled: true,
      wifi: { selector: wifiSelector, centerX: 1700, centerY: 270, value: true, source: 'checked' }
    }),
    readDeviceLanIpv4CandidatesImpl: async () => ([
      { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ]),
    cwd: HARMONY_ROOT
  });

  assert.deepEqual(result, { restored: true, clicks: [] });
  assert.equal(calls.filter((entry) => entry.includes(' uitest uiInput click ')).length, 0);
});

test('phase4 runner rejects wifi-hotspot already-restored false positives when the uplink address drifts under the same interface name', async () => {
  const runner = await import(modulePath);
  const wifiSelector = { ids: ['transition_togglewifi_ui_extension'] };
  const snapshot = await runner.defaultSnapshotNetworkState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    observeNetworkStateImpl: async () => ({ supported: false }),
    observeAirplaneModeStateImpl: async () => ({ supported: false }),
    observeHotspotStateImpl: async () => ({
      supported: true,
      hotspotEnabled: true,
      hotspot: {
        selector: { ids: ['Setting.hotspot_data_entry.hotspot_switch.hotspot_switch_setting.result'] },
        centerX: 1066,
        centerY: 435,
        value: true,
        source: 'checked'
      }
    }),
    observeControlCenterWifiStateImpl: async () => ({
      supported: true,
      wifiEnabled: true,
      wifi: { selector: wifiSelector, centerX: 1700, centerY: 270, value: true, source: 'checked' }
    }),
    readDeviceLanIpv4CandidatesImpl: async () => ([
      { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ])
  });

  await assert.rejects(
    () => runner.defaultRestoreNetworkState(snapshot, {
      execImpl: async () => ({ exitCode: 0, stdout: '', stderr: '' }),
      observeControlCenterWifiStateImpl: async () => ({
        supported: true,
        wifiEnabled: false,
        wifi: { selector: wifiSelector, centerX: 1700, centerY: 270, value: false, source: 'checked' }
      }),
      readDeviceLanIpv4CandidatesImpl: async () => ([
        { name: 'wlan0', address: '30.231.216.150', netmask: '255.255.248.0' },
        { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
      ]),
      cwd: HARMONY_ROOT
    }),
    /NETWORK_RECOVERY_NOT_PROVEN/u
  );
});

test('phase4 runner rejects wifi-hotspot hotspot-lan address drift during loss and restore verification', async () => {
  const runner = await import(modulePath);
  const wifiSelector = { ids: ['transition_togglewifi_ui_extension'] };
  const snapshot = await runner.defaultSnapshotNetworkState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    observeNetworkStateImpl: async () => ({ supported: false }),
    observeAirplaneModeStateImpl: async () => ({ supported: false }),
    observeHotspotStateImpl: async () => ({
      supported: true,
      hotspotEnabled: true,
      hotspot: {
        selector: { ids: ['Setting.hotspot_data_entry.hotspot_switch.hotspot_switch_setting.result'] },
        centerX: 1066,
        centerY: 435,
        value: true,
        source: 'checked'
      }
    }),
    observeControlCenterWifiStateImpl: async () => ({
      supported: true,
      wifiEnabled: false,
      wifi: { selector: wifiSelector, centerX: 1700, centerY: 270, value: false, source: 'checked' }
    }),
    readDeviceLanIpv4CandidatesImpl: async () => ([
      { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ])
  });
  const wifiStates = [
    { supported: true, wifiEnabled: false, wifi: { selector: wifiSelector, centerX: 1700, centerY: 270, value: false, source: 'checked' } },
    { supported: true, wifiEnabled: false, wifi: { selector: wifiSelector, centerX: 1700, centerY: 270, value: false, source: 'checked' } }
  ];
  const interfaceStates = [
    [
      { name: 'wlan0', address: '30.231.216.149', netmask: '255.255.248.0' },
      { name: 'wlan1', address: '192.168.43.1', netmask: '255.255.255.0' }
    ],
    [
      { name: 'wlan1', address: '192.168.43.2', netmask: '255.255.255.0' }
    ]
  ];

  await assert.rejects(
    () => runner.defaultExerciseNetworkRecovery(snapshot, {
      execImpl: async () => ({ exitCode: 0, stdout: '', stderr: '' }),
      observeControlCenterWifiStateImpl: async () => wifiStates.shift(),
      readDeviceLanIpv4CandidatesImpl: async () => interfaceStates.shift(),
      cwd: HARMONY_ROOT
    }),
    /NETWORK_RECOVERY_NOT_PROVEN/u
  );
});

test('phase4 runner navigates Settings Home to the hotspot toggle using semantic ids', async () => {
  const runner = await import(modulePath);
  const node = (id, type, bounds, extra = {}) => ({
    attributes: { id, type, bounds, checked: 'false', enabled: 'true', selected: 'false', ...extra },
    children: []
  });
  const layouts = [
    [node('Setting.MobileData', 'NavDestination', '[0,0][1216,2688]')],
    [node('mobile_network_entry', 'Row', '[65,1803][1151,1959]', { clickable: 'true' })],
    [
      node('Setting.MobileNetwork', 'NavDestination', '[0,0][1216,2688]'),
      node('Setting.MobileNetwork.air_plane_group.hotspot_data_settings', 'Row', '[65,831][1151,987]', { clickable: 'true' })
    ],
    [
      node('Setting.hotspot_data_entry', 'NavDestination', '[0,0][1216,2688]'),
      node('Setting.hotspot_data_entry.hotspot_switch.hotspot_switch_setting.result', 'Toggle', '[1008,403][1125,468]', { checked: 'true' })
    ]
  ];
  const calls = [];
  const observed = await runner.observeCurrentHotspotState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    execImpl: async (_command, args) => {
      calls.push(args.join(' '));
      return { exitCode: 0, stdout: '', stderr: '' };
    },
    dumpLayoutImpl: async () => layouts.shift()
  });
  assert.equal(observed.supported, true);
  assert.equal(observed.hotspotEnabled, true);
  assert.equal(observed.hotspot.centerX, 1066);
  assert.equal(observed.hotspot.centerY, 435);
  assert.equal(calls.some((entry) => entry.includes('uiInput keyEvent Back')), true);
  assert.equal(calls.filter((entry) => entry.includes(' uitest uiInput click ')).length, 2);
});

test('phase4 runner navigates Settings Home to the explicit airplane mode toggle', async () => {
  const runner = await import(modulePath);
  const node = (id, type, bounds, extra = {}) => ({
    attributes: { id, type, bounds, checked: 'false', enabled: 'true', selected: 'false', ...extra },
    children: []
  });
  const layouts = [
    [node('Setting.Wlan', 'NavDestination', '[0,0][1216,2688]')],
    [node('mobile_network_entry', 'Row', '[65,1803][1151,1959]', { clickable: 'true' })],
    [
      node('Setting.MobileNetwork', 'NavDestination', '[0,0][1216,2688]'),
      node('Setting.MobileNetwork.air_plane_group.air_plane_mode_setting.result', 'Toggle', '[1008,403][1125,468]', { checked: 'false', clickable: 'true' })
    ]
  ];
  const calls = [];
  const observed = await runner.observeCurrentAirplaneModeState({
    target: 'SERIAL123',
    hdcCommand: '/sdk/hdc',
    cwd: HARMONY_ROOT,
    execImpl: async (_command, args) => {
      calls.push(args.join(' '));
      return { exitCode: 0, stdout: '', stderr: '' };
    },
    dumpLayoutImpl: async () => layouts.shift()
  });
  assert.equal(observed.supported, true);
  assert.equal(observed.airplaneModeEnabled, false);
  assert.equal(observed.airplane.centerX, 1066);
  assert.equal(observed.airplane.centerY, 435);
  assert.equal(calls.some((entry) => entry.includes('uiInput keyEvent Back')), true);
  assert.equal(calls.filter((entry) => entry.includes(' uitest uiInput click ')).length, 1);
});

test('phase4 runner default screen snapshot and restore read observable screen state and fail closed on mismatch', async () => {
  const runner = await import(modulePath);
  assert.deepEqual(
    runner.parseObservedScreenState('Display Id=0 State=2 Discount=1.000000 Brightness=60\n'),
    { supported: true, state: 'on', screenOn: true }
  );
  assert.deepEqual(
    runner.parseObservedScreenState('Display Id=0 State=0 Discount=1.000000 Brightness=60\n'),
    { supported: true, state: 'off', screenOn: false }
  );
  assert.deepEqual(
    runner.parseObservedScreenState('POWER STATE DUMP:\nCurrent State: AWAKE  Reason: 10\n'),
    { supported: true, state: 'on', screenOn: true }
  );
  assert.deepEqual(
    runner.parseObservedScreenState('POWER STATE DUMP:\nCurrent State: SLEEP  Reason: TIMEOUT\n'),
    { supported: true, state: 'off', screenOn: false }
  );

  const screenStates = [
    { supported: true, state: 'on', screenOn: true },
    { supported: true, state: 'on', screenOn: true },
    { supported: true, state: 'off', screenOn: false }
  ];
  const delays = [];
  const transitioned = await runner.waitForScreenState({
    expectedScreenOn: false,
    maxAttempts: 3,
    pollIntervalMs: 250,
    readScreenStateImpl: async () => screenStates.shift(),
    delayImpl: async (milliseconds) => {
      delays.push(milliseconds);
    }
  });
  assert.deepEqual(transitioned, { supported: true, state: 'off', screenOn: false });
  assert.deepEqual(delays, [250, 250]);

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

test('phase4 runner runs a fresh VPN probe after UI and recovery before downgrading cleanup failure', async () => {
  const runner = await import(modulePath);
  const outputPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-cleanup-${process.pid}.json`);
  let linkedEvidence = null;
  let runtimeBaseline = null;
  let writerCount = 0;
  const phaseCalls = [];
  let observedLocalRuntimeProof = null;
  let expectedRuntimeReadyProof = null;
  const result = await runner.runPhase4DeviceProof({
    outputPath,
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => ({
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('p-sign') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
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
      if (joined.endsWith('shell ifconfig')) {
        return {
          exitCode: 0,
          stdout: 'wlan0 Link encap:Ethernet\n  inet addr:192.168.43.8 Bcast:192.168.43.255 Mask:255.255.255.0\n',
          stderr: ''
        };
      }
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      if (joined.includes('file recv -b')) {
        const localPath = args.at(-1);
        const bundleName = args[5];
        const payload = bundleName === 'com.github.kr328.clash.harmony'
          ? (path.basename(localPath) === 'runtime.json' ? linkedEvidence.runtime : runtimeBaseline)
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
      linkedEvidence.runtime.runId = runId;
      const dnsProbe = linkedEvidence.probe.records.find((entry) => entry.stepId === 'dns-packet-ipv4');
      const dnsCorrelationHash = createDnsPacketHash(runId, dnsProbe.flowId);
      linkedEvidence.runtime.records = linkedEvidence.runtime.records.map((entry) =>
        entry.protocol === 'dns'
          ? { ...entry, flowIdHash: dnsCorrelationHash, correlationHash: dnsCorrelationHash }
          : entry
      );
      runtimeBaseline = createRuntimeJournal({
        runId,
        sequence: 5,
        updatedAt: '2026-08-17T00:00:05.000Z',
        records: [
          createRuntimeLifecycleRecord(1, 'STATE_CHANGED:RUNNING'),
          createRuntimeLifecycleRecord(2, 'STATE_CHANGED:RECOVERING'),
          createRuntimeLifecycleRecord(3, 'proxy-activate-ok'),
          createRuntimeLifecycleRecord(4, 'STATE_CHANGED:RUNNING'),
          { sequence: 5, kind: 'traffic', ingress: 'tun', detail: 'tcp' }
        ]
      });
      return {
        observations: linkedEvidence.origin.observations,
        close: async () => {}
      };
    },
    runBaselineProbeImpl: async () => {
      phaseCalls.push('baseline');
      return { result: 'pass' };
    },
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: true, wifiEnabled: true, mobileEnabled: false }),
    performUiAutomationImpl: async () => {
      phaseCalls.push('ui');
      return {
        ok: true,
        launcherContinuity: true,
        screenOffContinuity: true,
        vpnIndicatorVisible: true,
        ongoingNotificationVisible: true
      };
    },
    exerciseNetworkRecoveryImpl: async () => {
      phaseCalls.push('recovery');
      return { supported: true, recovered: true };
    },
    waitForRuntimeRecoveryReadinessImpl: async () => {
      expectedRuntimeReadyProof = createRuntimeJournal({
        runId: linkedEvidence.runId,
        sequence: 10,
        updatedAt: '2026-08-17T00:00:10.000Z',
        records: [
          createRuntimeLifecycleRecord(6, 'tun-start-ok'),
          createRuntimeLifecycleRecord(7, 'STATE_CHANGED:RECOVERING'),
          createRuntimeLifecycleRecord(8, 'proxy-activate-ok'),
          createRuntimeLifecycleRecord(9, 'STATE_CHANGED:RUNNING')
        ]
      });
      return { ok: true, proof: expectedRuntimeReadyProof };
    },
    runLocalListenerProofImpl: async (options) => {
      phaseCalls.push('local-proof');
      observedLocalRuntimeProof = options.runtimeProof ?? null;
      return {
        result: 'pass',
        http: { ingress: 'local-http', outcome: 'pass', correlated: true },
        socks: { ingress: 'local-socks', outcome: 'pass', correlated: true }
      };
    },
    runVpnProbeImpl: async () => {
      phaseCalls.push('vpn-probe');
      return { result: 'pass', raw: linkedEvidence.probe };
    },
    waitForRuntimeTrafficEvidenceImpl: async ({ baseline, probe }) => {
      phaseCalls.push('traffic-journal');
      assert.equal(baseline.sequence, expectedRuntimeReadyProof.sequence);
      assert.equal(probe.global.tcp.correlationHash.length > 0, true);
      return { ok: true, proof: linkedEvidence.runtime };
    },
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
  assert.deepEqual(observedLocalRuntimeProof, expectedRuntimeReadyProof);
  assert.deepEqual(phaseCalls, ['baseline', 'ui', 'recovery', 'local-proof', 'vpn-probe', 'traffic-journal']);
  assert.equal(result.result, 'incomplete');
  assert.equal(result.lifecycle.stop.result, 'fail');
  assert.match(result.failures.map((entry) => entry.code).join(','), /STOP_CLEANUP_NOT_PROVEN/u);
});

test('phase4 runner can finish a full successful run without stop-cleanup downgrade and waits for stopped journal before force-stop', async () => {
  const runner = await import(modulePath);
  const outputPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-pass-${process.pid}.json`);
  const validExternalOrigin = Object.freeze({
    hostIpv4: '11.22.33.44',
    tcpHostIpv4: '55.66.77.88',
    tcpPort: 80,
    udpPort: 20053,
    dnsPort: 20054
  });
  let linkedEvidence = null;
  let runtimeBaseline = null;
  let expectedRuntimeReadyProof = null;
  let factoryCalls = 0;
  let normalizerCalls = 0;
  const seenExternalOrigins = [];
  const phaseCalls = [];
  const cleanupCalls = [];

  const result = await runner.runPhase4DeviceProof({
    outputPath,
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => ({
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('p-sign') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
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
      if (joined.endsWith('shell ifconfig')) {
        return {
          exitCode: 0,
          stdout: 'wlan0 Link encap:Ethernet\n  inet addr:192.168.43.8 Bcast:192.168.43.255 Mask:255.255.255.0\n',
          stderr: ''
        };
      }
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      if (joined.includes('file recv -b')) {
        const localPath = args.at(-1);
        const bundleName = args[5];
        const payload = bundleName === 'com.github.kr328.clash.harmony'
          ? (path.basename(localPath) === 'runtime.json' ? linkedEvidence.runtime : runtimeBaseline)
          : linkedEvidence.probe;
        await fs.writeFile(localPath, `${JSON.stringify(payload)}\n`, 'utf8');
        return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      }
      throw new Error(`unexpected command ${joined}`);
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    createExternalOriginImpl: async () => {
      factoryCalls += 1;
      return validExternalOrigin;
    },
    normalizeExternalOriginImpl: (input) => {
      normalizerCalls += 1;
      assert.equal(input, validExternalOrigin);
      return validExternalOrigin;
    },
    startOriginImpl: async ({ runId }) => {
      linkedEvidence = createLinkedEvidence();
      linkedEvidence.runId = runId;
      linkedEvidence.origin.runId = runId;
      linkedEvidence.origin.observations = linkedEvidence.origin.observations.map((entry) => ({ ...entry, runId }));
      linkedEvidence.probe.runId = runId;
      linkedEvidence.runtime.runId = runId;
      const dnsProbe = linkedEvidence.probe.records.find((entry) => entry.stepId === 'dns-packet-ipv4');
      const dnsCorrelationHash = createDnsPacketHash(runId, dnsProbe.flowId);
      linkedEvidence.runtime.records = linkedEvidence.runtime.records.map((entry) =>
        entry.protocol === 'dns'
          ? { ...entry, flowIdHash: dnsCorrelationHash, correlationHash: dnsCorrelationHash }
          : entry
      );
      runtimeBaseline = createRuntimeJournal({
        runId,
        sequence: 5,
        updatedAt: '2026-08-17T00:00:05.000Z',
        records: [
          createRuntimeLifecycleRecord(1, 'STATE_CHANGED:RUNNING'),
          createRuntimeLifecycleRecord(2, 'STATE_CHANGED:RECOVERING'),
          createRuntimeLifecycleRecord(3, 'proxy-activate-ok'),
          createRuntimeLifecycleRecord(4, 'STATE_CHANGED:RUNNING'),
          { sequence: 5, kind: 'traffic', ingress: 'tun', detail: 'tcp' }
        ]
      });
      return {
        observations: linkedEvidence.origin.observations,
        close: async () => { cleanupCalls.push('origin.close'); }
      };
    },
    runBaselineProbeImpl: async (options) => {
      phaseCalls.push('baseline');
      seenExternalOrigins.push(options.externalOrigin);
      return { result: 'pass' };
    },
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: true, wifiEnabled: true, mobileEnabled: false }),
    performUiAutomationImpl: async () => {
      phaseCalls.push('ui');
      return {
        ok: true,
        launcherContinuity: true,
        screenOffContinuity: true,
        vpnIndicatorVisible: true,
        ongoingNotificationVisible: true
      };
    },
    exerciseNetworkRecoveryImpl: async () => {
      phaseCalls.push('recovery');
      return { supported: true, recovered: true };
    },
    waitForRuntimeRecoveryReadinessImpl: async () => {
      expectedRuntimeReadyProof = createRuntimeJournal({
        runId: linkedEvidence.runId,
        sequence: 10,
        updatedAt: '2026-08-17T00:00:10.000Z',
        records: [
          createRuntimeLifecycleRecord(6, 'tun-start-ok'),
          createRuntimeLifecycleRecord(7, 'STATE_CHANGED:RECOVERING'),
          createRuntimeLifecycleRecord(8, 'proxy-activate-ok'),
          createRuntimeLifecycleRecord(9, 'STATE_CHANGED:RUNNING')
        ]
      });
      return { ok: true, proof: expectedRuntimeReadyProof };
    },
    runLocalListenerProofImpl: async () => {
      phaseCalls.push('local-proof');
      return {
        result: 'pass',
        http: { ingress: 'local-http', outcome: 'pass', correlated: true },
        socks: { ingress: 'local-socks', outcome: 'pass', correlated: true }
      };
    },
    runVpnProbeImpl: async (options) => {
      phaseCalls.push('vpn-probe');
      seenExternalOrigins.push(options.externalOrigin);
      return { result: 'pass', raw: linkedEvidence.probe };
    },
    waitForRuntimeTrafficEvidenceImpl: async ({ baseline, probe }) => {
      phaseCalls.push('traffic-journal');
      assert.equal(baseline.sequence, expectedRuntimeReadyProof.sequence);
      assert.equal(probe.global.dns.correlationHash.length > 0, true);
      return { ok: true, proof: linkedEvidence.runtime };
    },
    stopVpnImpl: async () => {
      cleanupCalls.push('stop-request');
    },
    waitForRuntimeStoppedImpl: async ({ baseline }) => {
      cleanupCalls.push('stop-journal');
      assert.equal(
        baseline.sequence,
        runner.captureRuntimeStopBaseline(linkedEvidence.runtime, linkedEvidence.runId).sequence
      );
      return {
        ok: true,
        proof: createRuntimeJournal({
          runId: linkedEvidence.runId,
          sequence: 15,
          updatedAt: '2026-08-17T00:00:15.000Z',
          state: 'stopped',
          stopped: true,
          records: [
            ...linkedEvidence.runtime.records,
            createRuntimeStopRecord(14),
            createRuntimeLifecycleRecord(15, 'STATE_CHANGED:STOPPED')
          ]
        })
      };
    },
    forceStopBundleImpl: async ({ bundleName }) => { cleanupCalls.push(`forceStop:${bundleName}`); },
    restoreNetworkStateImpl: async () => ({ restored: true }),
    restoreScreenStateImpl: async () => ({ restored: true }),
    writeValidatedProofImpl: async (candidate) => candidate
  });

  assert.deepEqual(phaseCalls, ['baseline', 'ui', 'recovery', 'local-proof', 'vpn-probe', 'traffic-journal']);
  assert.equal(result.result, 'pass');
  assert.equal(factoryCalls, 1);
  assert.equal(normalizerCalls, 1);
  assert.equal(seenExternalOrigins.length, 2);
  assert.equal(seenExternalOrigins[0], validExternalOrigin);
  assert.equal(seenExternalOrigins[1], validExternalOrigin);
  assert.equal(Object.isFrozen(seenExternalOrigins[0]), true);
  assert.equal(Object.isFrozen(seenExternalOrigins[1]), true);
  assert.equal(result.lifecycle.stop.result, 'pass');
  assert.equal(result.failures.some((entry) => entry.code === 'STOP_CLEANUP_NOT_PROVEN'), false);
  assert.deepEqual(cleanupCalls, [
    'stop-request',
    'stop-journal',
    'forceStop:com.github.kr328.clash.harmony',
    'forceStop:com.cmfa.phase4.trafficprobe',
    'origin.close'
  ]);
});

test('phase4 runner performs post-stop external triage before force-stop and preserves the pending VPN failure only when post-stop external reachability still passes', async () => {
  const runner = await import(modulePath);
  const outputPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-poststop-triage-${process.pid}.json`);
  const validExternalOrigin = Object.freeze({ hostIpv4: '11.22.33.44', tcpHostIpv4: '55.66.77.88', tcpPort: 80, udpPort: 20053, dnsPort: 20054 });
  let baselineCalls = 0;
  const phaseCalls = [];
  const seenExternalOrigins = [];
  const result = await runner.runPhase4DeviceProof({
    outputPath,
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => ({
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('signature:p') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('signature:q') }
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
      if (joined.endsWith('shell ifconfig')) return { exitCode: 0, stdout: 'wlan0 Link encap:Ethernet\n  inet addr:192.168.43.8 Bcast:192.168.43.255 Mask:255.255.255.0\n', stderr: '' };
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      throw new Error(`unexpected command ${joined}`);
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    createExternalOriginImpl: async () => validExternalOrigin,
    normalizeExternalOriginImpl: (input) => input,
    startOriginImpl: async () => ({
      observations: [{ protocol: 'https', runId: uuid(), sessionId: uuid(), flowId: uuid() }],
      close: async () => { phaseCalls.push('origin-close'); }
    }),
    runBaselineProbeImpl: async (options) => {
      baselineCalls += 1;
      seenExternalOrigins.push(options.externalOrigin);
      phaseCalls.push(baselineCalls === 1 ? 'baseline' : 'poststop-baseline');
      return baselineCalls === 1
        ? { result: 'pass' }
        : { result: 'pass' };
    },
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: true, wifiEnabled: true, mobileEnabled: false }),
    performUiAutomationImpl: async () => { phaseCalls.push('ui'); return { ok: true, launcherContinuity: true, screenOffContinuity: true, vpnIndicatorVisible: true, ongoingNotificationVisible: true }; },
    waitForRuntimeBaselineImpl: async () => ({ ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 5, updatedAt: '2026-08-17T00:00:05.000Z', records: [createRuntimeLifecycleRecord(5, 'tun-start-ok')] }) }),
    waitForRuntimeRecoveryEnteredImpl: async () => ({ ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 6, updatedAt: '2026-08-17T00:00:06.000Z', records: [createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING')] }) }),
    exerciseNetworkRecoveryImpl: async (_snapshot, options) => { phaseCalls.push('recovery'); await options.onLossObserved(); return { supported: true, recovered: true }; },
    waitForRuntimeRecoveryReadinessImpl: async () => ({ ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 10, updatedAt: '2026-08-17T00:00:10.000Z', records: [createRuntimeLifecycleRecord(6, 'tun-start-ok')] }) }),
    runLocalListenerProofImpl: async () => { phaseCalls.push('local-proof'); return { result: 'pass', http: { ingress: 'local-http', outcome: 'pass', correlated: true }, socks: { ingress: 'local-socks', outcome: 'pass', correlated: true } }; },
    runVpnProbeImpl: async (options) => {
      seenExternalOrigins.push(options.externalOrigin);
      phaseCalls.push('vpn-probe');
      return {
        result: 'fail',
        requiresExternalOriginTriage: true,
        failure: { code: 'GLOBAL_INGRESS_INVALID', detail: 'fixed-pending-vpn-failure' },
        raw: createReachabilityProbeRaw({ httpsOutcome: 'pass', tcpOutcome: 'fail' }),
        normalized: {}
      };
    },
    stopVpnImpl: async () => { phaseCalls.push('graceful-stop'); },
    waitForRuntimeStoppedImpl: async () => { phaseCalls.push('runtime-stop'); return { ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 11, updatedAt: '2026-08-17T00:00:11.000Z', state: 'stopped', stopped: true, records: [createRuntimeStopRecord(11)] }) }; },
    forceStopBundleImpl: async ({ bundleName }) => { phaseCalls.push(bundleName.includes('trafficprobe') ? 'force-stop-probe' : 'force-stop-production'); },
    restoreNetworkStateImpl: async () => { phaseCalls.push('network-restore'); return { restored: true }; },
    restoreScreenStateImpl: async () => { phaseCalls.push('screen-restore'); return { restored: true }; },
    writeValidatedProofImpl: async (candidate) => { phaseCalls.push('write'); return candidate; }
  });

  assert.deepEqual(phaseCalls, [
    'baseline',
    'ui',
    'recovery',
    'local-proof',
    'vpn-probe',
    'graceful-stop',
    'runtime-stop',
    'poststop-baseline',
    'force-stop-production',
    'force-stop-probe',
    'origin-close',
    'network-restore',
    'screen-restore',
    'write'
  ]);
  assert.equal(seenExternalOrigins.length, 3);
  assert.equal(seenExternalOrigins[0], validExternalOrigin);
  assert.equal(seenExternalOrigins[1], validExternalOrigin);
  assert.equal(seenExternalOrigins[2], validExternalOrigin);
  assert.equal(result.failures.some((entry) => entry.code === 'GLOBAL_INGRESS_INVALID'), true);
  assert.equal(result.failures.some((entry) => entry.code === 'EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN'), false);
});

test('phase4 runner downgrades pending VPN external failure to external reachability not proven when post-stop probe also fails or runtime stop is unconfirmed', async () => {
  const runner = await import(modulePath);
  const validExternalOrigin = Object.freeze({ hostIpv4: '11.22.33.44', tcpHostIpv4: '55.66.77.88', tcpPort: 80, udpPort: 20053, dnsPort: 20054 });

  const postStopFailCalls = [];
  const postStopFail = await runner.runPhase4DeviceProof({
    outputPath: path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-poststop-fail-${process.pid}.json`),
    toolchainInspectorImpl: async () => ({ report: { result: 'pass' }, resolved: { paths: { hdc: '/sdk/hdc' } } }),
    inspectPackagesImpl: async () => ({ result: 'pass', production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('signature:p') }, probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('signature:q') } }),
    execImpl: async (_command, args) => {
      const joined = args.join(' ');
      if (joined === 'help') return { exitCode: 0, stdout: 'file recv -b\ninstall\nshell\nlist targets\n', stderr: '' };
      if (joined === 'list targets') return { exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
      if (joined.includes('param get const.product.model')) return { exitCode: 0, stdout: 'Mate 70\n', stderr: '' };
      if (joined.includes('param get const.product.name')) return { exitCode: 0, stdout: 'harmony\n', stderr: '' };
      if (joined.includes('param get const.product.software.version')) return { exitCode: 0, stdout: 'HarmonyOS 6.0.1.123\n', stderr: '' };
      if (joined.includes('param get const.product.cpu.abilist')) return { exitCode: 0, stdout: 'arm64-v8a\n', stderr: '' };
      if (joined.includes('param get const.ohos.apiversion')) return { exitCode: 0, stdout: '20\n', stderr: '' };
      if (joined.endsWith('shell ifconfig')) return { exitCode: 0, stdout: 'wlan0 Link encap:Ethernet\n  inet addr:192.168.43.8 Bcast:192.168.43.255 Mask:255.255.255.0\n', stderr: '' };
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      throw new Error(`unexpected command ${joined}`);
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    createExternalOriginImpl: async () => validExternalOrigin,
    normalizeExternalOriginImpl: (input) => input,
    startOriginImpl: async () => ({ observations: [{ protocol: 'https', runId: uuid(), sessionId: uuid(), flowId: uuid() }], close: async () => { postStopFailCalls.push('origin-close'); } }),
    runBaselineProbeImpl: async () => {
      postStopFailCalls.push(postStopFailCalls.includes('runtime-stop') ? 'poststop-baseline' : 'baseline');
      return postStopFailCalls.includes('runtime-stop')
        ? { result: 'fail', failure: { code: 'EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN', detail: 'raw 11.22.33.44' } }
        : { result: 'pass' };
    },
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: true, wifiEnabled: true, mobileEnabled: false }),
    performUiAutomationImpl: async () => ({ ok: true, launcherContinuity: true, screenOffContinuity: true, vpnIndicatorVisible: true, ongoingNotificationVisible: true }),
    waitForRuntimeBaselineImpl: async () => ({ ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 5, updatedAt: '2026-08-17T00:00:05.000Z', records: [createRuntimeLifecycleRecord(5, 'tun-start-ok')] }) }),
    waitForRuntimeRecoveryEnteredImpl: async () => ({ ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 6, updatedAt: '2026-08-17T00:00:06.000Z', records: [createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING')] }) }),
    exerciseNetworkRecoveryImpl: async (_snapshot, options) => { await options.onLossObserved(); return { supported: true, recovered: true }; },
    waitForRuntimeRecoveryReadinessImpl: async () => ({ ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 10, updatedAt: '2026-08-17T00:00:10.000Z', records: [createRuntimeLifecycleRecord(6, 'tun-start-ok')] }) }),
    runLocalListenerProofImpl: async () => ({ result: 'pass', http: { ingress: 'local-http', outcome: 'pass', correlated: true }, socks: { ingress: 'local-socks', outcome: 'pass', correlated: true } }),
    runVpnProbeImpl: async () => ({ result: 'fail', requiresExternalOriginTriage: true, failure: { code: 'GLOBAL_INGRESS_INVALID', detail: 'fixed-pending-vpn-failure' }, raw: createReachabilityProbeRaw({ httpsOutcome: 'pass', udpOutcome: 'fail' }), normalized: {} }),
    stopVpnImpl: async () => { postStopFailCalls.push('graceful-stop'); },
    waitForRuntimeStoppedImpl: async () => { postStopFailCalls.push('runtime-stop'); return { ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 11, updatedAt: '2026-08-17T00:00:11.000Z', state: 'stopped', stopped: true, records: [createRuntimeStopRecord(11)] }) }; },
    forceStopBundleImpl: async ({ bundleName }) => { postStopFailCalls.push(bundleName.includes('trafficprobe') ? 'force-stop-probe' : 'force-stop-production'); },
    restoreNetworkStateImpl: async () => ({ restored: true }),
    restoreScreenStateImpl: async () => ({ restored: true }),
    writeValidatedProofImpl: async (candidate) => candidate
  });
  assert.equal(postStopFail.failures.some((entry) => entry.code === 'EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN'), true);
  assert.equal(postStopFail.failures.some((entry) => entry.code === 'GLOBAL_INGRESS_INVALID'), false);
  assert.equal(JSON.stringify(postStopFail).includes('11.22.33.44'), false);

  const noStopTriageCalls = [];
  const noStopTriage = await runner.runPhase4DeviceProof({
    outputPath: path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-no-stop-triage-${process.pid}.json`),
    toolchainInspectorImpl: async () => ({ report: { result: 'pass' }, resolved: { paths: { hdc: '/sdk/hdc' } } }),
    inspectPackagesImpl: async () => ({ result: 'pass', production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('signature:p') }, probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('signature:q') } }),
    execImpl: async (_command, args) => {
      const joined = args.join(' ');
      if (joined === 'help') return { exitCode: 0, stdout: 'file recv -b\ninstall\nshell\nlist targets\n', stderr: '' };
      if (joined === 'list targets') return { exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
      if (joined.includes('param get const.product.model')) return { exitCode: 0, stdout: 'Mate 70\n', stderr: '' };
      if (joined.includes('param get const.product.name')) return { exitCode: 0, stdout: 'harmony\n', stderr: '' };
      if (joined.includes('param get const.product.software.version')) return { exitCode: 0, stdout: 'HarmonyOS 6.0.1.123\n', stderr: '' };
      if (joined.includes('param get const.product.cpu.abilist')) return { exitCode: 0, stdout: 'arm64-v8a\n', stderr: '' };
      if (joined.includes('param get const.ohos.apiversion')) return { exitCode: 0, stdout: '20\n', stderr: '' };
      if (joined.endsWith('shell ifconfig')) return { exitCode: 0, stdout: 'wlan0 Link encap:Ethernet\n  inet addr:192.168.43.8 Bcast:192.168.43.255 Mask:255.255.255.0\n', stderr: '' };
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      throw new Error(`unexpected command ${joined}`);
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    createExternalOriginImpl: async () => validExternalOrigin,
    normalizeExternalOriginImpl: (input) => input,
    startOriginImpl: async () => ({ observations: [{ protocol: 'https', runId: uuid(), sessionId: uuid(), flowId: uuid() }], close: async () => {} }),
    runBaselineProbeImpl: async () => { noStopTriageCalls.push('baseline-or-poststop'); return { result: 'pass' }; },
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: true, wifiEnabled: true, mobileEnabled: false }),
    performUiAutomationImpl: async () => ({ ok: true, launcherContinuity: true, screenOffContinuity: true, vpnIndicatorVisible: true, ongoingNotificationVisible: true }),
    waitForRuntimeBaselineImpl: async () => ({ ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 5, updatedAt: '2026-08-17T00:00:05.000Z', records: [createRuntimeLifecycleRecord(5, 'tun-start-ok')] }) }),
    waitForRuntimeRecoveryEnteredImpl: async () => ({ ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 6, updatedAt: '2026-08-17T00:00:06.000Z', records: [createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING')] }) }),
    exerciseNetworkRecoveryImpl: async (_snapshot, options) => { await options.onLossObserved(); return { supported: true, recovered: true }; },
    waitForRuntimeRecoveryReadinessImpl: async () => ({ ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 10, updatedAt: '2026-08-17T00:00:10.000Z', records: [createRuntimeLifecycleRecord(6, 'tun-start-ok')] }) }),
    runLocalListenerProofImpl: async () => ({ result: 'pass', http: { ingress: 'local-http', outcome: 'pass', correlated: true }, socks: { ingress: 'local-socks', outcome: 'pass', correlated: true } }),
    runVpnProbeImpl: async () => ({ result: 'fail', requiresExternalOriginTriage: true, failure: { code: 'GLOBAL_INGRESS_INVALID', detail: 'fixed-pending-vpn-failure' }, raw: createReachabilityProbeRaw({ httpsOutcome: 'pass', tcpOutcome: 'fail' }), normalized: {} }),
    stopVpnImpl: async () => {},
    waitForRuntimeStoppedImpl: async () => ({ ok: false, failure: { code: 'STOP_CLEANUP_NOT_PROVEN', detail: 'raw-stop-detail' } }),
    forceStopBundleImpl: async () => {},
    restoreNetworkStateImpl: async () => ({ restored: true }),
    restoreScreenStateImpl: async () => ({ restored: true }),
    writeValidatedProofImpl: async (candidate) => candidate
  });
  assert.deepEqual(noStopTriageCalls, ['baseline-or-poststop']);
  assert.equal(noStopTriage.failures.some((entry) => entry.code === 'EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN'), true);
  assert.equal(noStopTriage.failures.some((entry) => entry.code === 'STOP_CLEANUP_NOT_PROVEN'), true);
});

test('phase4 runner timeout and cleanup failures use allowlisted fixed reasons and stage details without raw exceptions', async () => {
  const runner = await import(modulePath);
  const evidence = createLinkedEvidence();
  const probe = runner.normalizePhase4ProbeEvidence(evidence.probe, evidence.runId);
  const baseline = runner.captureRuntimeTrafficBaseline(createRuntimeJournal({
    runId: evidence.runId,
    sequence: 9,
    updatedAt: '2026-08-17T00:00:09.000Z',
    records: [
      createRuntimeLifecycleRecord(6, 'tun-start-ok'),
      createRuntimeLifecycleRecord(7, 'STATE_CHANGED:RECOVERING'),
      createRuntimeLifecycleRecord(8, 'proxy-activate-ok'),
      createRuntimeLifecycleRecord(9, 'STATE_CHANGED:RUNNING')
    ]
  }), evidence.runId);
  const localPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-traffic-timeout-${process.pid}.json`);
  const timeout = await runner.waitForRuntimeTrafficEvidence({
    fsApi: fs,
    execImpl: async (_command, args) => {
      await fs.writeFile(args.at(-1), `${JSON.stringify(createRuntimeJournal({
        runId: evidence.runId,
        sequence: 10,
        updatedAt: '2026-08-17T00:00:10.000Z',
        records: [
          createRuntimeLifecycleRecord(10, 'STATE_CHANGED:RUNNING')
        ]
      }))}\n`, 'utf8');
      return { exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    },
    hdcCommand: '/sdk/hdc',
    target: 'SERIAL123',
    remotePath: '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json',
    localPath,
    cwd: HARMONY_ROOT,
    expectedRunId: evidence.runId,
    baseline,
    probe,
    maxAttempts: 1,
    delayImpl: async () => {}
  });
  assert.equal(timeout.ok, false);
  assert.equal(timeout.reason, 'tcp-missing');
  assert.equal(timeout.failure.detail.includes('tcp-missing'), true);
  assert.equal(timeout.failure.detail.includes('raw'), false);

  const outputPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-cleanup-stage-${process.pid}.json`);
  const result = await runner.runPhase4DeviceProof({
    outputPath,
    toolchainInspectorImpl: async () => ({ report: { result: 'pass' }, resolved: { paths: { hdc: '/sdk/hdc' } } }),
    inspectPackagesImpl: async () => ({ result: 'pass', production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('signature:p') }, probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('signature:q') } }),
    execImpl: async (_command, args) => {
      const joined = args.join(' ');
      if (joined === 'help') return { exitCode: 0, stdout: 'file recv -b\ninstall\nshell\nlist targets\n', stderr: '' };
      if (joined === 'list targets') return { exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
      if (joined.includes('param get const.product.model')) return { exitCode: 0, stdout: 'Mate 70\n', stderr: '' };
      if (joined.includes('param get const.product.name')) return { exitCode: 0, stdout: 'harmony\n', stderr: '' };
      if (joined.includes('param get const.product.software.version')) return { exitCode: 0, stdout: 'HarmonyOS 6.0.1.123\n', stderr: '' };
      if (joined.includes('param get const.product.cpu.abilist')) return { exitCode: 0, stdout: 'arm64-v8a\n', stderr: '' };
      if (joined.includes('param get const.ohos.apiversion')) return { exitCode: 0, stdout: '20\n', stderr: '' };
      if (joined.endsWith('shell ifconfig')) return { exitCode: 0, stdout: 'wlan0 Link encap:Ethernet\n  inet addr:192.168.43.8 Bcast:192.168.43.255 Mask:255.255.255.0\n', stderr: '' };
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      throw new Error(`unexpected command ${joined}`);
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    startOriginImpl: async () => ({ observations: [{ protocol: 'https', runId: uuid(), sessionId: uuid(), flowId: uuid() }], close: async () => { throw new Error('raw close 11.22.33.44'); } }),
    runBaselineProbeImpl: async () => ({ result: 'pass' }),
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: true, wifiEnabled: true, mobileEnabled: false }),
    performUiAutomationImpl: async () => ({ ok: true, launcherContinuity: true, screenOffContinuity: true, vpnIndicatorVisible: true, ongoingNotificationVisible: true }),
    waitForRuntimeBaselineImpl: async () => ({ ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 5, updatedAt: '2026-08-17T00:00:05.000Z', records: [createRuntimeLifecycleRecord(5, 'tun-start-ok')] }) }),
    waitForRuntimeRecoveryEnteredImpl: async () => ({ ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 6, updatedAt: '2026-08-17T00:00:06.000Z', records: [createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING')] }) }),
    exerciseNetworkRecoveryImpl: async (_snapshot, options) => { await options.onLossObserved(); return { supported: true, recovered: true }; },
    waitForRuntimeRecoveryReadinessImpl: async () => ({ ok: true, proof: createRuntimeJournal({ runId: uuid(), sequence: 10, updatedAt: '2026-08-17T00:00:10.000Z', records: [createRuntimeLifecycleRecord(6, 'tun-start-ok')] }) }),
    runLocalListenerProofImpl: async () => ({ result: 'pass', http: { ingress: 'local-http', outcome: 'pass', correlated: true }, socks: { ingress: 'local-socks', outcome: 'pass', correlated: true } }),
    runVpnProbeImpl: async () => ({ result: 'fail', requiresExternalOriginTriage: true, failure: { code: 'GLOBAL_INGRESS_INVALID', detail: 'fixed-pending-vpn-failure' }, raw: createReachabilityProbeRaw({ httpsOutcome: 'pass', tcpOutcome: 'fail' }), normalized: {} }),
    stopVpnImpl: async () => { throw new Error('raw graceful stop'); },
    waitForRuntimeStoppedImpl: async () => { throw new Error('raw runtime stop'); },
    forceStopBundleImpl: async ({ bundleName }) => { throw new Error(`raw force stop ${bundleName}`); },
    restoreNetworkStateImpl: async () => { throw new Error('raw network restore'); },
    restoreScreenStateImpl: async () => { throw new Error('raw screen restore'); },
    fsApi: {
      ...fs,
      mkdtemp: async () => await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-cleanup-stage-')),
      rm: async (...args) => {
        if (args.length > 1 && typeof args[0] === 'string' && args[0].includes('phase4-cleanup-stage-')) {
          throw new Error('raw temp cleanup');
        }
        return await fs.rm(...args);
      }
    },
    writeValidatedProofImpl: async (candidate) => candidate
  });
  const details = result.failures.filter((entry) => entry.code === 'STOP_CLEANUP_NOT_PROVEN').map((entry) => entry.detail).join('|');
  for (const stage of ['graceful-stop', 'runtime-stop', 'force-stop-production', 'force-stop-probe', 'origin-close', 'network-restore', 'screen-restore', 'temp-cleanup']) {
    assert.equal(details.includes(stage), true);
  }
  assert.equal(details.includes('11.22.33.44'), false);
  assert.equal(details.includes('raw'), false);
});

test('phase4 runner waits for a fresh RECOVERING window during controlled loss before restore and only then waits for readiness', async () => {
  const runner = await import(modulePath);
  const outputPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-recovery-entered-${process.pid}.json`);
  const phaseCalls = [];
  let linkedEvidence = null;
  let runtimeBaseline = null;
  let enteredProof = null;
  let readyProof = null;
  const fsApi = {
    ...fs,
    mkdtemp: async () => await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-pull-entered-'))
  };

  const result = await runner.runPhase4DeviceProof({
    fsApi,
    outputPath,
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => ({
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('p-sign') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
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
      if (joined.endsWith('shell ifconfig')) {
        return {
          exitCode: 0,
          stdout: 'wlan0 Link encap:Ethernet\n  inet addr:192.168.43.8 Bcast:192.168.43.255 Mask:255.255.255.0\n',
          stderr: ''
        };
      }
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      if (joined.includes('file recv -b')) {
        const localPath = args.at(-1);
        const bundleName = args[5];
        const payload = bundleName === 'com.github.kr328.clash.harmony'
          ? runtimeBaseline
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
      linkedEvidence.runtime.runId = runId;
      runtimeBaseline = createRuntimeJournal({
        runId,
        sequence: 5,
        updatedAt: '2026-08-17T00:00:05.000Z',
        records: [
          createRuntimeLifecycleRecord(1, 'STATE_CHANGED:RUNNING'),
          createRuntimeLifecycleRecord(2, 'STATE_CHANGED:RECOVERING'),
          createRuntimeLifecycleRecord(3, 'proxy-activate-ok'),
          createRuntimeLifecycleRecord(4, 'STATE_CHANGED:RUNNING'),
          { sequence: 5, kind: 'traffic', ingress: 'tun', detail: 'tcp' }
        ]
      });
      return {
        observations: linkedEvidence.origin.observations,
        close: async () => {}
      };
    },
    runBaselineProbeImpl: async () => {
      phaseCalls.push('baseline');
      return { result: 'pass' };
    },
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: true, wifiEnabled: true, mobileEnabled: false }),
    performUiAutomationImpl: async () => {
      phaseCalls.push('ui');
      return {
        ok: true,
        launcherContinuity: true,
        screenOffContinuity: true,
        vpnIndicatorVisible: true,
        ongoingNotificationVisible: true
      };
    },
    exerciseNetworkRecoveryImpl: async (_snapshot, options = {}) => {
      phaseCalls.push('recovery-start');
      await options.onLossObserved();
      phaseCalls.push('recovery-restored');
      return { supported: true, recovered: true };
    },
    waitForRuntimeRecoveryEnteredImpl: async () => {
      phaseCalls.push('runtime-entered');
      enteredProof = createRuntimeJournal({
        runId: linkedEvidence.runId,
        sequence: 6,
        updatedAt: '2026-08-17T00:00:06.000Z',
        state: 'recovering',
        recoveryAttempt: 1,
        records: [
          createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING')
        ]
      });
      return { ok: true, proof: enteredProof };
    },
    waitForRuntimeRecoveryReadinessImpl: async () => {
      phaseCalls.push('runtime-ready');
      readyProof = createRuntimeJournal({
        runId: linkedEvidence.runId,
        sequence: 9,
        updatedAt: '2026-08-17T00:00:09.000Z',
        records: [
          createRuntimeLifecycleRecord(6, 'STATE_CHANGED:RECOVERING'),
          createRuntimeLifecycleRecord(7, 'proxy-activate-ok'),
          createRuntimeLifecycleRecord(9, 'STATE_CHANGED:RUNNING')
        ]
      });
      return { ok: true, proof: readyProof };
    },
    runLocalListenerProofImpl: async (options) => {
      phaseCalls.push('local-proof');
      assert.deepEqual(options.runtimeProof, readyProof);
      return {
        result: 'pass',
        http: { ingress: 'local-http', outcome: 'pass', correlated: true },
        socks: { ingress: 'local-socks', outcome: 'pass', correlated: true }
      };
    },
    runVpnProbeImpl: async () => {
      phaseCalls.push('vpn-probe');
      return { result: 'pass', raw: linkedEvidence.probe };
    },
    waitForRuntimeTrafficEvidenceImpl: async ({ baseline, probe }) => {
      phaseCalls.push('traffic-journal');
      assert.equal(baseline.sequence, readyProof.sequence);
      assert.equal(probe.global.udp.correlationHash.length > 0, true);
      return { ok: true, proof: linkedEvidence.runtime };
    },
    stopVpnImpl: async () => {},
    forceStopBundleImpl: async () => {},
    restoreNetworkStateImpl: async () => ({ restored: true }),
    restoreScreenStateImpl: async () => ({ restored: true }),
    writeValidatedProofImpl: async (candidate) => candidate
  });

  assert.equal(result.result, 'incomplete');
  assert.deepEqual(phaseCalls, ['baseline', 'ui', 'recovery-start', 'runtime-entered', 'recovery-restored', 'runtime-ready', 'local-proof', 'vpn-probe', 'traffic-journal']);
  assert.equal(Boolean(enteredProof), true);
  assert.equal(Boolean(readyProof), true);
  assert.equal(result.failures.some((entry) => entry.code === 'STOP_CLEANUP_NOT_PROVEN'), true);
});

test('phase4 runner does not launch the VPN probe until runtime recovery readiness succeeds', async () => {
  const runner = await import(modulePath);
  const outputPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-runtime-timeout-${process.pid}.json`);
  const phaseCalls = [];
  let restoreCalls = 0;
  let runtimeBaseline = null;

  const result = await runner.runPhase4DeviceProof({
    outputPath,
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => ({
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('p-sign') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
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
      if (joined.endsWith('shell ifconfig')) {
        return {
          exitCode: 0,
          stdout: 'wlan0 Link encap:Ethernet\n  inet addr:192.168.43.8 Bcast:192.168.43.255 Mask:255.255.255.0\n',
          stderr: ''
        };
      }
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      if (joined.includes('file recv -b')) {
        await fs.writeFile(args.at(-1), `${JSON.stringify(runtimeBaseline)}\n`, 'utf8');
        return { exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
      }
      throw new Error(`unexpected command ${joined}`);
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    startOriginImpl: async ({ runId }) => {
      runtimeBaseline = createRuntimeJournal({
        runId,
        sequence: 5,
        updatedAt: '2026-08-17T00:00:05.000Z',
        records: [
          createRuntimeLifecycleRecord(1, 'STATE_CHANGED:RUNNING'),
          createRuntimeLifecycleRecord(2, 'STATE_CHANGED:RECOVERING'),
          createRuntimeLifecycleRecord(3, 'proxy-activate-ok'),
          createRuntimeLifecycleRecord(4, 'STATE_CHANGED:RUNNING'),
          { sequence: 5, kind: 'traffic', ingress: 'tun', detail: 'tcp' }
        ]
      });
      return { observations: [], close: async () => {} };
    },
    runBaselineProbeImpl: async () => {
      phaseCalls.push('baseline');
      return { result: 'pass' };
    },
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: true, wifiEnabled: true, mobileEnabled: false }),
    performUiAutomationImpl: async () => {
      phaseCalls.push('ui');
      return {
        ok: true,
        launcherContinuity: true,
        screenOffContinuity: true,
        vpnIndicatorVisible: true,
        ongoingNotificationVisible: true
      };
    },
    exerciseNetworkRecoveryImpl: async () => {
      phaseCalls.push('recovery');
      return { supported: true, recovered: true };
    },
    waitForRuntimeRecoveryReadinessImpl: async () => {
      phaseCalls.push('runtime-ready');
      return {
        ok: false,
        failure: { code: 'NETWORK_RECOVERY_RUNTIME_TIMEOUT', detail: 'Runtime journal did not publish a fresh recovery-ready window after network restoration.' }
      };
    },
    runVpnProbeImpl: async () => {
      phaseCalls.push('vpn-probe');
      return { result: 'pass', raw: {} };
    },
    stopVpnImpl: async () => {},
    forceStopBundleImpl: async () => {},
    restoreNetworkStateImpl: async () => {
      restoreCalls += 1;
      return { restored: true };
    },
    restoreScreenStateImpl: async () => ({ restored: true }),
    writeValidatedProofImpl: async (candidate) => candidate
  });

  assert.equal(result.result, 'incomplete');
  assert.equal(restoreCalls, 1);
  assert.deepEqual(phaseCalls, ['baseline', 'ui', 'recovery', 'runtime-ready']);
  assert.match(result.failures.map((entry) => entry.code).join(','), /NETWORK_RECOVERY_RUNTIME_TIMEOUT/u);
});

test('phase4 runner does not persist the raw origin in the proof when UI automation fails', async () => {
  const runner = await import(modulePath);
  const outputPath = path.join(HARMONY_ROOT, 'artifacts', `phase4-runner-origin-forwarding-${process.pid}.json`);
  const canonicalOriginIpv4 = joinFragments(['198', '.', '51', '.', '100', '.', '24']);
  const originFixture = `${canonicalOriginIpv4}/32`;
  let forwardedOptions = null;

  const result = await runner.runPhase4DeviceProof({
    outputPath,
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => ({
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('p-sign') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('q-sign') }
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
      if (joined.endsWith('shell ifconfig')) {
        return {
          exitCode: 0,
          stdout: 'wlan0 Link encap:Ethernet\n  inet addr:192.168.43.8 Bcast:192.168.43.255 Mask:255.255.255.0\n',
          stderr: ''
        };
      }
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      throw new Error(`unexpected command ${joined}`);
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    startOriginImpl: async ({ runId }) => ({
      sessionId: uuid(),
      tcp: { host: canonicalOriginIpv4, port: 443 },
      https: { host: canonicalOriginIpv4, port: 443, caPem: 'certificate' },
      udp: { host: canonicalOriginIpv4, port: 53 },
      observations: [{ protocol: 'tcp', detail: originFixture, runId, sessionId: uuid(), flowId: uuid() }],
      close: async () => {}
    }),
    runBaselineProbeImpl: async () => ({ result: 'pass' }),
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: true, wifiEnabled: true, mobileEnabled: false }),
    performUiAutomationImpl: async (options) => {
      forwardedOptions = options;
      return {
        ok: false,
        code: 'UI_AUTOMATION_UNSUPPORTED',
        detail: 'UI automation was intentionally blocked for forwarding verification.'
      };
    },
    stopVpnImpl: async () => {},
    forceStopBundleImpl: async () => {},
    restoreNetworkStateImpl: async () => ({ restored: true }),
    restoreScreenStateImpl: async () => ({ restored: true }),
    writeValidatedProofImpl: async (candidate) => candidate
  });

  assert.equal(typeof forwardedOptions?.runId, 'string');
  assert.equal(result.outputPath, 'harmony/artifacts/phase4-device-proof.json');
  assert.equal(JSON.stringify(result).includes(canonicalOriginIpv4), false);
  assert.equal(JSON.stringify(result).includes(originFixture), false);
  assert.equal(result.failures.some((entry) =>
    entry.code === 'STOP_CLEANUP_NOT_PROVEN' && entry.detail.includes('runtime-stop')
  ), false);
});

test('phase4 runner normalizes the external origin once before install, passes it to baseline before early UI failure, and fail-closes invalid config before install', async () => {
  const runner = await import(modulePath);
  const validExternalOrigin = Object.freeze({
    hostIpv4: '11.22.33.44',
    tcpHostIpv4: '55.66.77.88',
    tcpPort: 80,
    udpPort: 20053,
    dnsPort: 20054
  });
  let factoryCalls = 0;
  let normalizerCalls = 0;
  const seenExternalOrigins = [];

  const validResult = await runner.runPhase4DeviceProof({
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => ({
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('signature:p') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('signature:q') }
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
      if (joined.endsWith('shell ifconfig')) {
        return {
          exitCode: 0,
          stdout: 'wlan0 Link encap:Ethernet\n  inet addr:192.168.43.8 Bcast:192.168.43.255 Mask:255.255.255.0\n',
          stderr: ''
        };
      }
      if (joined.includes('install -r')) return { exitCode: 0, stdout: 'Success\n', stderr: '' };
      throw new Error(`unexpected command ${joined}`);
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    createExternalOriginImpl: async () => {
      factoryCalls += 1;
      return validExternalOrigin;
    },
    normalizeExternalOriginImpl: (input) => {
      normalizerCalls += 1;
      assert.equal(input, validExternalOrigin);
      return validExternalOrigin;
    },
    startOriginImpl: async () => ({
      sessionId: uuid(),
      tcp: { host: '192.0.2.10', port: 443 },
      https: { host: '192.0.2.10', port: 443, caPem: 'certificate' },
      udp: { host: '192.0.2.10', port: 53 },
      observations: [],
      close: async () => {}
    }),
    runBaselineProbeImpl: async (options) => {
      seenExternalOrigins.push(options.externalOrigin);
      return { result: 'pass' };
    },
    snapshotScreenStateImpl: async () => ({ supported: true, screenOn: true }),
    snapshotNetworkStateImpl: async () => ({ supported: true, wifiEnabled: true, mobileEnabled: false }),
    performUiAutomationImpl: async () => ({ ok: false, code: 'UI_AUTOMATION_UNSUPPORTED', detail: 'blocked' }),
    runVpnProbeImpl: async (options) => {
      seenExternalOrigins.push(options.externalOrigin);
      return { result: 'pass', raw: null, normalized: null };
    },
    stopVpnImpl: async () => {},
    forceStopBundleImpl: async () => {},
    restoreNetworkStateImpl: async () => ({ restored: true }),
    restoreScreenStateImpl: async () => ({ restored: true }),
    writeValidatedProofImpl: async (candidate) => candidate
  });

  assert.equal(factoryCalls, 1);
  assert.equal(normalizerCalls, 1);
  assert.equal(seenExternalOrigins.length, 1);
  assert.equal(seenExternalOrigins[0], validExternalOrigin);
  assert.equal(Object.isFrozen(seenExternalOrigins[0]), true);
  assert.equal(JSON.stringify(validResult).includes('11.22.33.44'), false);
  assert.equal(JSON.stringify(validResult).includes('55.66.77.88'), false);

  let installAttempted = false;
  const invalidResult = await runner.runPhase4DeviceProof({
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    inspectPackagesImpl: async () => ({
      result: 'pass',
      production: { bundleName: 'com.github.kr328.clash.harmony', stubDetected: false, hapSha256: digest('production'), signatureSha256: digest('signature:p') },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('probe'), signatureSha256: digest('signature:q') }
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
      if (joined.endsWith('shell ifconfig')) {
        return {
          exitCode: 0,
          stdout: 'wlan0 Link encap:Ethernet\n  inet addr:192.168.43.8 Bcast:192.168.43.255 Mask:255.255.255.0\n',
          stderr: ''
        };
      }
      if (joined.includes('install -r')) {
        installAttempted = true;
      }
      return { exitCode: 0, stdout: 'Success\n', stderr: '' };
    },
    hashFileImpl: async (filePath) => ({ path: filePath, sha256: digest(filePath), sizeBytes: 1, absolutePath: filePath }),
    createExternalOriginImpl: async () => ({ hostIpv4: '11.22.33.44', tcpHostIpv4: '55.66.77.88', tcpPort: 45678, udpPort: 20053, dnsPort: 20054 }),
    normalizeExternalOriginImpl: () => {
      throw Object.assign(new Error('leak 11.22.33.44 55.66.77.88:45678'), { code: 'whatever' });
    },
    writeValidatedProofImpl: async (candidate) => candidate
  });

  assert.equal(installAttempted, false);
  assert.equal(invalidResult.result, 'incomplete');
  assert.equal(invalidResult.failures.some((entry) => entry.code === 'EXTERNAL_ORIGIN_CONFIG_INVALID'), true);
  assert.equal(JSON.stringify(invalidResult).includes('11.22.33.44'), false);
  assert.equal(JSON.stringify(invalidResult).includes('55.66.77.88'), false);
  assert.equal(JSON.stringify(invalidResult).includes('45678'), false);
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

test('phase4 proof writer preserves original failures while canonicalizing partial incomplete evidence', async (t) => {
  const runner = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-runner-incomplete-'));
  t.after(async () => await fs.rm(tempRoot, { recursive: true, force: true }));
  const outputPath = path.join(tempRoot, 'proof.json');
  const incompleteProof = runner.createBaseProofForTesting({ outputPath });
  incompleteProof.traffic.ipv6 = { result: 'not-run', reason: 'network-not-provisioned' };
  incompleteProof.localEvidence.http = {
    result: 'pass',
    ingress: 'local-http',
    correlated: true
  };
  incompleteProof.failures.push({ code: 'TUN_LINK_MISSING', detail: 'Linked evidence was missing.' });

  const persisted = await runner.writeValidatedProof(incompleteProof, outputPath);

  assert.equal(persisted.result, 'incomplete');
  assert.deepEqual(persisted.traffic, {});
  assert.deepEqual(persisted.localEvidence, {});
  assert.deepEqual(persisted.failures, [
    { code: 'TUN_LINK_MISSING', detail: 'Linked evidence was missing.' }
  ]);
});

test('phase4 proof writer rejects nested persisted sessionId or traceId from pass and incomplete candidates', async () => {
  const runner = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-runner-privacy-'));
  const passCandidate = runner.createBaseProofForTesting({ outputPath: path.join(tempRoot, 'pass.json') });
  passCandidate.result = 'pass';
  passCandidate.traffic.tcp = {
    result: 'pass',
    correlated: true,
    sessionId: 'session-leak',
    captureTrace: { ingress: 'tun', event: 'tcp-connect' },
    coreEvent: { event: 'mihomo.tcp' }
  };
  passCandidate.traffic.udp = {
    result: 'pass',
    correlated: true,
    captureTrace: { ingress: 'tun', event: 'udp-associate' },
    coreEvent: { event: 'mihomo.udp' }
  };
  passCandidate.traffic.dns = {
    result: 'pass',
    correlated: true,
    captureTrace: { ingress: 'tun', event: 'dns-query' },
    coreEvent: { event: 'mihomo.dns' }
  };
  passCandidate.traffic.ipv4 = {
    result: 'pass',
    correlated: true,
    captureTrace: { ingress: 'tun', event: 'ipv4-flow' },
    coreEvent: { event: 'mihomo.ipv4' }
  };
  passCandidate.localEvidence.http = { result: 'pass', ingress: 'local-http', correlated: true };
  passCandidate.localEvidence.socks = { result: 'pass', ingress: 'local-socks', correlated: true };
  passCandidate.lifecycle = { notification: { result: 'pass' }, background: { result: 'pass' }, recovery: { result: 'pass' }, stop: { result: 'pass' } };

  const persistedPass = await runner.writeValidatedProof(passCandidate, path.join(tempRoot, 'pass.json'));
  assert.equal(persistedPass.result, 'incomplete');
  assert.equal(JSON.stringify(persistedPass).includes('session-leak'), false);

  const incompleteCandidate = runner.createBaseProofForTesting({ outputPath: path.join(tempRoot, 'incomplete.json') });
  incompleteCandidate.traffic.tcp = { result: 'pass', correlated: true, traceId: 'trace-leak' };
  const persistedIncomplete = await runner.writeValidatedProof(incompleteCandidate, path.join(tempRoot, 'incomplete.json'));
  assert.equal(persistedIncomplete.result, 'incomplete');
  assert.equal(JSON.stringify(persistedIncomplete).includes('trace-leak'), false);
});
