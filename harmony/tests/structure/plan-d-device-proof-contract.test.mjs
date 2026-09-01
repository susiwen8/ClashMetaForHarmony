import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const RUNNER_MODULE_PATH = new URL('../bin/run-plan-d-device-proof.mjs', import.meta.url);
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'plan-d-device-proof.schema.json');
const EXAMPLE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'plan-d-device-proof.example.json');
const HTTPS_LITERAL = ['https', '://'].join('');
const USERS_HOME_LITERAL = ['/', 'Us', 'ers/'].join('');

function digest(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function createLayoutRow(semanticId, {
  label = '',
  runtimeSelected = false,
  savedIntent = false,
  nestedGroup = false
} = {}) {
  const children = [];
  if (label.length > 0) {
    children.push({
      attributes: {
        id: `${semanticId}.label`,
        text: label
      },
      bounds: { left: 20, top: 20, right: 220, bottom: 60 }
    });
  }
  if (runtimeSelected) {
    children.push({
      attributes: { id: `${semanticId}.runtime-selected` },
      bounds: { left: 220, top: 20, right: 260, bottom: 60 }
    });
  }
  if (savedIntent) {
    children.push({
      attributes: { id: `${semanticId}.saved-intent` },
      bounds: { left: 260, top: 20, right: 300, bottom: 60 }
    });
  }
  if (nestedGroup) {
    children.push({
      attributes: { id: `${semanticId}.nested-group` },
      bounds: { left: 300, top: 20, right: 340, bottom: 60 }
    });
  }
  return {
    attributes: {
      id: semanticId,
      clickable: 'true',
      enabled: 'true',
      type: 'ListItem'
    },
    bounds: { left: 0, top: 0, right: 360, bottom: 72 },
    children
  };
}

function createProxyLayout() {
  return {
    root: {
      attributes: { id: 'root' },
      bounds: { left: 0, top: 0, right: 360, bottom: 720 },
      children: [
        {
          attributes: { id: 'detail.proxy.toggle', clickable: 'true', enabled: 'true' },
          bounds: { left: 16, top: 16, right: 344, bottom: 80 }
        },
        {
          attributes: { id: 'proxies.group.0', clickable: 'true', enabled: 'true' },
          bounds: { left: 16, top: 96, right: 344, bottom: 144 }
        },
        createLayoutRow('proxies.node.0', {
          label: 'Alpha',
          runtimeSelected: true
        }),
        createLayoutRow('proxies.node.1', {
          label: 'Beta'
        }),
        createLayoutRow('proxies.node.2', {
          label: 'Nested',
          nestedGroup: true
        })
      ]
    }
  };
}

function createHomeVpnLayout() {
  return {
    root: {
      attributes: { id: 'root' },
      bounds: { left: 0, top: 0, right: 360, bottom: 720 },
      children: [
        {
          attributes: { id: 'home.vpn.action', clickable: 'true', enabled: 'true' },
          bounds: { left: 16, top: 16, right: 344, bottom: 80 }
        }
      ]
    }
  };
}

function createPhase4Proof({
  productionSha256 = digest('production-hap'),
  probeSha256 = digest('probe-hap')
} = {}) {
  return {
    schemaVersion: '4.0.0',
    phase: 4,
    result: 'pass',
    runId: 'c76b37db-5c7d-4fdf-9c88-f1feef7a8a7b',
    outputPath: 'harmony/artifacts/phase4-device-proof.json',
    timestamps: {
      startedAt: '2026-08-23T01:00:00.000Z',
      completedAt: '2026-08-23T01:00:09.000Z'
    },
    device: {
      targetKind: 'physical',
      identityMasked: 'target-91ac4f20',
      osVersion: 'HarmonyOS 6.0.1.123',
      apiVersion: 24,
      abi: 'arm64-v8a',
      deviceClass: 'phone'
    },
    bundles: {
      production: { bundleName: 'com.github.kr328.clash.harmony' },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe' },
      hapSha256: [productionSha256, probeSha256]
    },
    core: {
      version: 'v1.19.29',
      nativeSha256: [digest('addon'), digest('mihomo')]
    },
    assertions: {
      addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
      routes: ['0.0.0.0/0', '::/0'],
      dns: ['10.111.222.2', 'fd00:111:222::2'],
      mtu: 1500,
      ipv4Accepted: true,
      ipv6Accepted: true,
      blocking: false,
      blockedApplications: ['com.github.kr328.clash.harmony']
    },
    traffic: {},
    localEvidence: {},
    lifecycle: {
      notification: { result: 'pass' },
      background: { result: 'pass' },
      recovery: { result: 'pass' },
      stop: { result: 'pass' }
    },
    tun: {
      counters: {
        rxPackets: 41,
        txPackets: 38,
        rxBytes: 4096,
        txBytes: 6144
      }
    },
    failures: []
  };
}

function createRuntimeTrafficRecord({
  destinationHash,
  outboundTerminalHash,
  counterDelta = 1,
  ingress = 'tun',
  protocol = 'tcp',
  sequence = 10
} = {}) {
  return {
    sequence,
    kind: 'traffic',
    protocol,
    ingress,
    destinationHash,
    outboundTerminalHash,
    counterDelta
  };
}

function createPlanDUiDriver() {
  return {
    launchProductionImpl: async () => {},
    openProxyManageImpl: async () => {},
    dumpLayoutImpl: async ({ stage }) => {
      if (stage === 'after-selection') {
        const layout = createProxyLayout();
        layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha' });
        layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta', savedIntent: true });
        return layout;
      }
      if (stage === 'post-vpn') {
        const layout = createProxyLayout();
        layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha' });
        layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta', runtimeSelected: true });
        return layout;
      }
      if (stage === 'relaunch-pre-save') {
        const layout = createProxyLayout();
        layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha' });
        layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta', runtimeSelected: true });
        return layout;
      }
      if (stage === 'relaunch-post-save') {
        const layout = createProxyLayout();
        layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha', savedIntent: true });
        layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta' });
        return layout;
      }
      if (stage === 'relaunch-verify') {
        const layout = createProxyLayout();
        layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha', runtimeSelected: true });
        layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta' });
        return layout;
      }
      if (stage === 'cleanup-stop') {
        return createHomeVpnLayout();
      }
      return createProxyLayout();
    },
    clickNodeImpl: async () => {},
    navigateBackHomeImpl: async () => {},
    forceStopProductionImpl: async () => {},
    startVpnImpl: async () => {},
    performPhase4AutomationImpl: async () => ({
      ok: true,
      ongoingNotificationVisible: true,
      launcherContinuity: true,
      screenOffContinuity: true,
      vpnIndicatorVisible: true
    })
  };
}

async function runPlanDDefaultCleanupScenario({
  fsApi = fs,
  execImpl = async () => ({ exitCode: 0, stdout: '', stderr: '', timedOut: false, error: null }),
  pullEvidenceImpl
} = {}) {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'plan-d-cleanup-scenario-'));
  const outputPath = path.join(tempRoot, 'plan-d-device-proof.json');
  const phase4OutputPath = path.join(tempRoot, 'phase4-device-proof.json');
  const productionHapPath = path.join(tempRoot, 'entry-default-signed.hap');
  const probeHapPath = path.join(tempRoot, 'probe-entry-default-signed.hap');

  await fs.writeFile(productionHapPath, 'production-hap', 'utf8');
  await fs.writeFile(probeHapPath, 'probe-hap', 'utf8');

  const proof = await runner.runPlanDDeviceProof({
    productionHapPath,
    probeHapPath,
    phase4OutputPath,
    outputPath,
    tempRoot,
    fsApi,
    runIdImpl: () => 'c76b37db-5c7d-4fdf-9c88-f1feef7a8a7b',
    hashFileImpl: async (filePath) => {
      const buffer = await fsApi.readFile(filePath);
      return { sha256: digest(buffer), sizeBytes: buffer.byteLength };
    },
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/mock/hdc' } }
    }),
    detectTargetImpl: async () => 'SERIAL123',
    execImpl,
    runPhase4Impl: async (options) => {
      const origin = await options.startOriginImpl({
        runId: options.runId,
        deviceIpv4Candidates: [{ address: '192.168.0.8', netmask: '255.255.255.0' }]
      });
      await options.performUiAutomationImpl({
        target: 'SERIAL123',
        hdcCommand: '/mock/hdc',
        runId: options.runId
      });
      await origin.close();
      return createPhase4Proof({
        productionSha256: digest('production-hap'),
        probeSha256: digest('probe-hap')
      });
    },
    startOriginImpl: async () => ({
      sessionId: 'session-1',
      https: { host: '192.168.0.9', port: 443 },
      close: async () => {}
    }),
    uiDriver: createPlanDUiDriver(),
    pullEvidenceImpl,
    collectOriginObservationsImpl: async () => [
      { protocol: 'https', responseBodySha256: digest('https-response') }
    ]
  });

  return { proof, tempRoot, outputPath };
}

test('plan d schema stays strict and the canonical example remains incomplete and secret-free', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const [schema, example] = await Promise.all([
    JSON.parse(await fs.readFile(SCHEMA_PATH, 'utf8')),
    JSON.parse(await fs.readFile(EXAMPLE_PATH, 'utf8'))
  ]);

  assert.equal(schema.additionalProperties, false);
  assert.equal('initialSelectedTerminalHash' in schema.properties.selection.properties, false);
  assert.equal('initialSelectedTerminalHash' in example.selection, false);
  assert.equal(schema.properties.failures.items.additionalProperties, false);
  assert.equal(schema.properties.failures.items.required.includes('detail'), false);
  assert.equal(example.result, 'incomplete');
  assert.equal(example.failures.every((entry) => 'code' in entry && 'stage' in entry), true);
  assert.equal(JSON.stringify(example).includes(HTTPS_LITERAL), false);
  assert.equal(JSON.stringify(example).includes(USERS_HOME_LITERAL), false);
  assert.equal(runner.validatePlanDProofDocument(example).valid, true);
});

test('plan d CLI parsing is strict and defaults to canonical repo-scoped manifest and outputs', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const parsed = runner.parseCliArguments([
    '--production-hap', 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    '--probe-hap', 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap'
  ]);

  assert.equal(parsed.productionManifestPath, path.join(HARMONY_ROOT, 'artifacts', 'phase1-native-provenance.json'));
  assert.equal(parsed.phase4OutputPath, path.join(HARMONY_ROOT, 'artifacts', 'phase4-device-proof.json'));
  assert.equal(parsed.outputPath, path.join(HARMONY_ROOT, 'artifacts', 'plan-d-device-proof.json'));
  assert.throws(() => runner.parseCliArguments(['--wat', 'x']), /Unknown argument/u);
  assert.throws(() => runner.parseCliArguments(['--out']), /Missing value/u);
});

test('plan d and phase4 proof paths reject repository symlink escapes', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const phase4Runner = await import(new URL('../bin/run-phase4-device-proof.mjs', import.meta.url));
  const safety = await import(new URL('../bin/repo-path-safety.mjs', import.meta.url));
  const repoTemp = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'plan-d-symlink-'));
  const externalTemp = await fs.mkdtemp(path.join(os.tmpdir(), 'plan-d-external-'));
  const linkedDir = path.join(repoTemp, 'linked');
  const linkedInput = path.join(repoTemp, 'input.hap');
  const externalInput = path.join(externalTemp, 'outside.hap');
  await fs.writeFile(externalInput, 'outside', 'utf8');
  await fs.symlink(externalTemp, linkedDir);
  await fs.symlink(externalInput, linkedInput);
  try {
    await assert.rejects(
      runner.writeArgumentErrorProof({
        outputPath: path.join(linkedDir, 'plan-d.json'),
        repoRoot: HARMONY_ROOT
      }),
      /repository|symlink|PATH_OUTSIDE_REPO/iu
    );
    await assert.rejects(
      phase4Runner.writeValidatedProof(
        phase4Runner.createBaseProofForTesting(),
        path.join(linkedDir, 'phase4.json'),
        fs,
        HARMONY_ROOT
      ),
      /repository|symlink|PATH_OUTSIDE_REPO/iu
    );
    await assert.rejects(
      safety.ensureRepoScopedExistingFile(fs, HARMONY_ROOT, linkedInput, '--production-hap'),
      /repository|symlink|PATH_OUTSIDE_REPO/iu
    );
  } finally {
    await fs.rm(repoTemp, { recursive: true, force: true });
    await fs.rm(externalTemp, { recursive: true, force: true });
  }
});

test('plan d hash helpers use the exact required formulas', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const runId = '6ea45344-5790-4bbb-a806-48ee31319bb7';
  const semanticId = 'proxies.node.7';
  const label = 'Visible Alpha';

  assert.equal(
    runner.hashRowCorrelation(runId, semanticId),
    digest(`${runId}\0${semanticId}`)
  );
  assert.equal(
    runner.hashSelectedTerminalLabel(label),
    digest(label)
  );
  assert.equal(
    runner.hashDestinationTuple('tcp', '192.168.0.9', 443),
    digest('tcp|192.168.0.9|443')
  );
});

test('plan d selection helper excludes nested groups, requires exactly one runtime marker, and returns only opaque values', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const runId = '6ea45344-5790-4bbb-a806-48ee31319bb7';
  const analyzed = runner.analyzeProxySelectionLayout({
    layout: createProxyLayout(),
    runId
  });

  assert.equal(analyzed.groupCount, 1);
  assert.equal(analyzed.nodeCount, 3);
  assert.equal(analyzed.selection.resultKind, 'changed-terminal');
  assert.equal(analyzed.selection.rowCorrelationHash, digest(`${runId}\0proxies.node.1`));
  assert.equal(analyzed.selection.selectedTerminalHash, digest('Beta'));
  assert.equal('selectedSemanticId' in analyzed.selection, false);
  assert.equal('selectedLabel' in analyzed.selection, false);

  const ambiguousLayout = createProxyLayout();
  ambiguousLayout.root.children.push(createLayoutRow('proxies.node.9', { runtimeSelected: true, label: 'Gamma' }));
  assert.throws(
    () => runner.analyzeProxySelectionLayout({ layout: ambiguousLayout, runId }),
    /PLAN_D_RUNTIME_SELECTION_AMBIGUOUS/u
  );
});

test('plan d proxy layout polling waits for the asynchronous runtime-selected state', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const runId = '6ea45344-5790-4bbb-a806-48ee31319bb7';
  const loadingLayout = createProxyLayout();
  loadingLayout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha' });
  let reads = 0;
  let delays = 0;

  const result = await runner.waitForProxyLayoutAnalysis({
    readLayoutImpl: async () => {
      reads += 1;
      return reads === 1 ? loadingLayout : createProxyLayout();
    },
    analyzeLayoutImpl: (layout) => runner.analyzeProxySelectionLayout({ layout, runId }),
    delayImpl: async () => {
      delays += 1;
    },
    attempts: 3
  });

  assert.equal(reads, 2);
  assert.equal(delays, 1);
  assert.equal(result.analysis.nodeCount, 3);
  assert.equal(result.analysis.selection.resultKind, 'changed-terminal');
});

test('plan d proxy layout polling treats a delayed saved-intent marker as transient', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  let analyses = 0;

  const result = await runner.waitForProxyLayoutAnalysis({
    readLayoutImpl: async () => createProxyLayout(),
    analyzeLayoutImpl: (layout) => {
      analyses += 1;
      if (analyses === 1) {
        throw Object.assign(new Error('PLAN_D_SAVED_INTENT_MISSING'), { code: 'PLAN_D_SAVED_INTENT_MISSING' });
      }
      return layout;
    },
    delayImpl: async () => {},
    attempts: 2
  });

  assert.equal(analyses, 2);
  assert.ok(result.analysis.root !== undefined);
});

test('plan d proxy selection scrolls before clicking an offscreen terminal row', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const runId = '6ea45344-5790-4bbb-a806-48ee31319bb7';
  const offscreen = createProxyLayout();
  offscreen.root.attributes.scrollable = 'true';
  offscreen.root.bounds = { left: 0, top: 0, right: 360, bottom: 720 };
  offscreen.root.children[3].bounds = { left: 0, top: 760, right: 360, bottom: 832 };
  offscreen.root.children.push({
    attributes: { id: 'group-tabs-scroll', scrollable: 'true' },
    bounds: { left: 0, top: 90, right: 360, bottom: 150 },
    children: []
  });
  const visible = createProxyLayout();
  visible.root.attributes.scrollable = 'true';
  visible.root.bounds = { left: 0, top: 0, right: 360, bottom: 720 };
  visible.root.children[3].bounds = { left: 0, top: 220, right: 360, bottom: 292 };
  visible.root.children.push({
    attributes: { id: 'group-tabs-scroll', scrollable: 'true' },
    bounds: { left: 0, top: 90, right: 360, bottom: 150 },
    children: []
  });
  let reads = 0;
  let scrolls = 0;

  const result = await runner.waitForVisibleProxySelection({
    readLayoutImpl: async () => {
      reads += 1;
      return reads === 1 ? offscreen : visible;
    },
    scrollForwardImpl: async () => {
      scrolls += 1;
    },
    runId,
    delayImpl: async () => {},
    attempts: 2
  });

  assert.equal(reads, 2);
  assert.equal(scrolls, 1);
  assert.equal(result.analysis.selection.resultKind, 'changed-terminal');
});

test('plan d proxy selection parses HarmonyOS string bounds from layout attributes', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const layout = createProxyLayout();
  delete layout.root.children[3].bounds;
  layout.root.children[3].attributes.bounds = '[12,220][348,292]';

  const result = runner.analyzeProxySelectionLayout({
    layout,
    runId: '6ea45344-5790-4bbb-a806-48ee31319bb7'
  });

  assert.deepEqual(result.transient.candidateSelection.bounds, {
    left: 12,
    top: 220,
    right: 348,
    bottom: 292
  });
  assert.equal(result.transient.candidateSelection.centerX, 180);
  assert.equal(result.transient.candidateSelection.centerY, 256);
});

test('plan d post-vpn verifier requires an exact HTTPS trace match and one unique tcp destination match', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const selectedTerminalHash = digest('Beta');
  const expectedDestinationHash = digest('tcp|192.168.0.9|443');
  const responseSha256 = digest('https-response');
  const verification = runner.verifyPhase4PostVpnEvidence({
    probeEvidence: {
      records: [
        {
          stepId: 'https',
          outcome: 'pass',
          transport: 'https',
          statusCode: 200,
          responseBodySha256: responseSha256
        }
      ]
    },
    originObservations: [
      {
        protocol: 'https',
        responseBodySha256: responseSha256
      }
    ],
    runtimeJournal: {
      records: [
        createRuntimeTrafficRecord({
          destinationHash: expectedDestinationHash,
          outboundTerminalHash: selectedTerminalHash
        })
      ]
    },
    expectedDestinationHash,
    selectedTerminalHash
  });

  assert.deepEqual(verification, {
    statusClass: '2xx',
    responseSha256,
    httpsTraceMatched: true,
    selectedProxyMatched: true,
    tunIngress: true,
    counterDelta: 1
  });

  assert.throws(() => runner.verifyPhase4PostVpnEvidence({
    probeEvidence: {
      records: [{ stepId: 'https', outcome: 'pass', transport: 'https', statusCode: 200, responseBodySha256: responseSha256 }]
    },
    originObservations: [{ protocol: 'https', responseBodySha256: responseSha256 }],
    runtimeJournal: {
      records: [
        createRuntimeTrafficRecord({
          destinationHash: expectedDestinationHash,
          outboundTerminalHash: digest('other-terminal')
        })
      ]
    },
    expectedDestinationHash,
    selectedTerminalHash
  }), /PLAN_D_SELECTED_PROXY_MISMATCH/u);
});

test('plan d replay journal verifier enforces proxy-activate-ok before RUNNING and exact saved-row correlation replay', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const savedRowCorrelationHash = digest('saved-row');

  assert.equal(runner.verifyReplayJournalOrdering([
    { sequence: 7, kind: 'lifecycle', detail: 'proxy-activate-ok' },
    { sequence: 8, kind: 'lifecycle', detail: 'STATE_CHANGED:RUNNING' }
  ]), true);

  assert.throws(
    () => runner.verifyReplayJournalOrdering([
      { sequence: 7, kind: 'lifecycle', detail: 'STATE_CHANGED:RUNNING' },
      { sequence: 8, kind: 'lifecycle', detail: 'proxy-activate-ok' }
    ]),
    /PLAN_D_REPLAY_ORDER_INVALID/u
  );
  assert.equal(runner.verifyReplaySessionBoundary('session-old', 'session-new'), true);
  assert.throws(
    () => runner.verifyReplaySessionBoundary('session-old', 'session-old'),
    /PLAN_D_REPLAY_SESSION_STALE/u
  );

  assert.equal(
    runner.verifyRelaunchSelectionMatch({
      rowCorrelationHash: savedRowCorrelationHash,
      expectedRowCorrelationHash: savedRowCorrelationHash,
      hasSavedIntentMarker: false
    }),
    true
  );
  assert.throws(
    () => runner.verifyRelaunchSelectionMatch({
      rowCorrelationHash: digest('different-row'),
      expectedRowCorrelationHash: savedRowCorrelationHash,
      hasSavedIntentMarker: false
    }),
    /PLAN_D_RELAUNCH_SELECTION_MISMATCH/u
  );
});

test('plan d runner wraps phase4 hooks in order, removes raw-layout temp files, and cleans up in finally', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'plan-d-runner-'));
  const calls = [];
  const outputPath = path.join(tempRoot, 'plan-d-device-proof.json');
  const phase4OutputPath = path.join(tempRoot, 'phase4-device-proof.json');

  const productionHapPath = path.join(tempRoot, 'entry-default-signed.hap');
  const probeHapPath = path.join(tempRoot, 'probe-entry-default-signed.hap');
  await fs.writeFile(productionHapPath, 'production-hap', 'utf8');
  await fs.writeFile(probeHapPath, 'probe-hap', 'utf8');

  const result = await runner.runPlanDDeviceProof({
    productionHapPath,
    probeHapPath,
    phase4OutputPath,
    outputPath,
    tempRoot,
    nowImpl: () => new Date('2026-08-23T01:00:00.000Z'),
    runIdImpl: () => 'c76b37db-5c7d-4fdf-9c88-f1feef7a8a7b',
    hashFileImpl: async (filePath) => {
      const buffer = await fs.readFile(filePath);
      return { sha256: digest(buffer), sizeBytes: buffer.byteLength };
    },
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/mock/hdc' } }
    }),
    detectTargetImpl: async () => 'SERIAL123',
    runPhase4Impl: async (options) => {
      calls.push('phase4:start');
      const origin = await options.startOriginImpl({
        runId: options.runId,
        deviceIpv4Candidates: [{ address: '192.168.0.8', netmask: '255.255.255.0' }]
      });
      calls.push('phase4:origin');
      const uiResult = await options.performUiAutomationImpl({
        target: 'SERIAL123',
        hdcCommand: '/mock/hdc',
        runId: options.runId
      });
      calls.push(`phase4:ui:${uiResult.ok}`);
      await origin.close();
      const proof = createPhase4Proof({
        productionSha256: digest('production-hap'),
        probeSha256: digest('probe-hap')
      });
      await fs.writeFile(phase4OutputPath, `${JSON.stringify(proof, null, 2)}\n`, 'utf8');
      return proof;
    },
    startOriginImpl: async ({ runId }) => {
      calls.push(`origin:start:${runId}`);
      return {
        sessionId: 'session-1',
        https: {
          host: '192.168.0.9',
          port: 443
        },
        close: async () => {
          calls.push('origin:close');
        }
      };
    },
    uiDriver: {
      launchProductionImpl: async () => {
        calls.push('ui:launch');
      },
      openProxyManageImpl: async () => {
        calls.push('ui:open-proxies');
      },
      dumpLayoutImpl: async ({ stage, layoutDir }) => {
        calls.push(`ui:dump:${stage}`);
        if (layoutDir) {
          await fs.writeFile(path.join(layoutDir, `${stage}.json`), JSON.stringify(createProxyLayout()), 'utf8');
        }
        if (stage === 'after-selection') {
          const layout = createProxyLayout();
          layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha' });
          layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta', savedIntent: true });
          return layout;
        }
        if (stage === 'post-vpn') {
          const layout = createProxyLayout();
          layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha' });
          layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta', runtimeSelected: true });
          return layout;
        }
        if (stage === 'relaunch-pre-save') {
          const layout = createProxyLayout();
          layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha' });
          layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta', runtimeSelected: true });
          return layout;
        }
        if (stage === 'relaunch-post-save') {
          const layout = createProxyLayout();
          layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha', savedIntent: true });
          layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta' });
          return layout;
        }
        if (stage === 'relaunch-verify') {
          const layout = createProxyLayout();
          layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha', runtimeSelected: true });
          layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta' });
          return layout;
        }
        return createProxyLayout();
      },
      clickNodeImpl: async (selection) => {
        calls.push(`ui:click:${selection.node.attributes.id}`);
      },
      navigateBackHomeImpl: async () => {
        calls.push('ui:back-home');
      },
      forceStopProductionImpl: async () => {
        calls.push('ui:force-stop-production');
      },
      startVpnImpl: async () => {
        calls.push('ui:start-vpn');
      },
      performPhase4AutomationImpl: async () => {
        calls.push('ui:default-phase4');
        return {
          ok: true,
          ongoingNotificationVisible: true,
          launcherContinuity: true,
          screenOffContinuity: true,
          vpnIndicatorVisible: true
        };
      }
    },
    pullEvidenceImpl: async ({ kind }) => {
      calls.push(`evidence:${kind}`);
      if (kind === 'probe') {
        return {
          records: [
            {
              stepId: 'https',
              outcome: 'pass',
              transport: 'https',
              statusCode: 200,
              responseBodySha256: digest('https-response')
            }
          ]
        };
      }
      return {
        sessionAlias: kind === 'runtime-journal-relaunch' ? 'session-new' : 'session-old',
        records: [
          createRuntimeTrafficRecord({
            destinationHash: digest('tcp|192.168.0.9|443'),
            outboundTerminalHash: digest('Beta'),
            sequence: kind === 'runtime-journal-post-phase4' ? 10 : 20
          }),
          ...(kind === 'runtime-journal-relaunch'
            ? [
              { sequence: 18, kind: 'lifecycle', detail: 'proxy-activate-ok' },
              { sequence: 19, kind: 'lifecycle', detail: 'STATE_CHANGED:RUNNING' }
            ]
            : [])
        ]
      };
    },
    collectOriginObservationsImpl: async () => [
      {
        protocol: 'https',
        responseBodySha256: digest('https-response')
      }
    ],
    cleanupImpl: async () => {
      calls.push('cleanup:extra');
      return { stopVpn: true, forceStop: true };
    }
  });

  assert.equal(result.result, 'pass');
  assert.deepEqual(calls, [
    'phase4:start',
    'origin:start:c76b37db-5c7d-4fdf-9c88-f1feef7a8a7b',
    'phase4:origin',
    'ui:launch',
    'ui:open-proxies',
    'ui:dump:initial-selection',
    'ui:click:proxies.node.1',
    'ui:dump:after-selection',
    'ui:back-home',
    'ui:default-phase4',
    'ui:launch',
    'ui:open-proxies',
    'ui:dump:post-vpn',
    'phase4:ui:true',
    'origin:close',
    'evidence:probe',
    'evidence:runtime-journal-post-phase4',
    'ui:launch',
    'ui:open-proxies',
    'ui:dump:relaunch-pre-save',
    'ui:click:proxies.node.0',
    'ui:dump:relaunch-post-save',
    'ui:back-home',
    'ui:force-stop-production',
    'ui:start-vpn',
    'evidence:runtime-journal-relaunch',
    'ui:launch',
    'ui:open-proxies',
    'ui:dump:relaunch-verify',
    'cleanup:extra'
  ]);
  assert.equal(result.cleanup.layoutTempRemoved, true);
  await fs.access(outputPath);
  const remainingEntries = await fs.readdir(tempRoot);
  assert.equal(remainingEntries.some((entry) => entry.startsWith('plan-d-ui-raw-layouts-')), false);
});

test('plan d runner fail-closes when default cleanup cannot prove explicit vpn stop convergence', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'plan-d-cleanup-fail-closed-'));
  const outputPath = path.join(tempRoot, 'plan-d-device-proof.json');
  const phase4OutputPath = path.join(tempRoot, 'phase4-device-proof.json');
  const productionHapPath = path.join(tempRoot, 'entry-default-signed.hap');
  const probeHapPath = path.join(tempRoot, 'probe-entry-default-signed.hap');
  const execCalls = [];

  await fs.writeFile(productionHapPath, 'production-hap', 'utf8');
  await fs.writeFile(probeHapPath, 'probe-hap', 'utf8');

  const proof = await runner.runPlanDDeviceProof({
    productionHapPath,
    probeHapPath,
    phase4OutputPath,
    outputPath,
    tempRoot,
    runIdImpl: () => 'c76b37db-5c7d-4fdf-9c88-f1feef7a8a7b',
    hashFileImpl: async (filePath) => {
      const buffer = await fs.readFile(filePath);
      return { sha256: digest(buffer), sizeBytes: buffer.byteLength };
    },
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/mock/hdc' } }
    }),
    detectTargetImpl: async () => 'SERIAL123',
    execImpl: async (_command, args) => {
      execCalls.push(args.join(' '));
      return { exitCode: 0, stdout: '', stderr: '', timedOut: false, error: null };
    },
    runPhase4Impl: async () => createPhase4Proof({
      productionSha256: digest('production-hap'),
      probeSha256: digest('probe-hap')
    }),
    startOriginImpl: async () => ({
      sessionId: 'session-1',
      https: { host: '192.168.0.9', port: 443 },
      close: async () => {}
    }),
    uiDriver: {
      launchProductionImpl: async () => {},
      openProxyManageImpl: async () => {},
      dumpLayoutImpl: async ({ stage }) => {
        if (stage === 'after-selection') {
          const layout = createProxyLayout();
          layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha' });
          layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta', savedIntent: true });
          return layout;
        }
        if (stage === 'post-vpn') {
          const layout = createProxyLayout();
          layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha' });
          layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta', runtimeSelected: true });
          return layout;
        }
        if (stage === 'relaunch-pre-save') {
          const layout = createProxyLayout();
          layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha' });
          layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta', runtimeSelected: true });
          return layout;
        }
        if (stage === 'relaunch-post-save') {
          const layout = createProxyLayout();
          layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha', savedIntent: true });
          layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta' });
          return layout;
        }
        if (stage === 'relaunch-verify') {
          const layout = createProxyLayout();
          layout.root.children[2] = createLayoutRow('proxies.node.0', { label: 'Alpha', runtimeSelected: true });
          layout.root.children[3] = createLayoutRow('proxies.node.1', { label: 'Beta' });
          return layout;
        }
        return createProxyLayout();
      },
      clickNodeImpl: async () => {},
      navigateBackHomeImpl: async () => {},
      forceStopProductionImpl: async () => {},
      startVpnImpl: async () => {},
      performPhase4AutomationImpl: async () => ({
        ok: true,
        ongoingNotificationVisible: true,
        launcherContinuity: true,
        screenOffContinuity: true,
        vpnIndicatorVisible: true
      })
    },
    pullEvidenceImpl: async ({ kind }) => kind === 'probe'
      ? {
        records: [
          {
            stepId: 'https',
            outcome: 'pass',
            transport: 'https',
            statusCode: 200,
            responseBodySha256: digest('https-response')
          }
        ]
      }
      : {
        sessionAlias: kind === 'runtime-journal-relaunch' ? 'session-new' : 'session-old',
        records: [
          createRuntimeTrafficRecord({
            destinationHash: digest('tcp|192.168.0.9|443'),
            outboundTerminalHash: digest('Beta'),
            sequence: kind === 'runtime-journal-post-phase4' ? 10 : 20
          }),
          ...(kind === 'runtime-journal-relaunch'
            ? [
              { sequence: 18, kind: 'lifecycle', detail: 'proxy-activate-ok' },
              { sequence: 19, kind: 'lifecycle', detail: 'STATE_CHANGED:RUNNING' }
            ]
            : [])
        ]
      },
    collectOriginObservationsImpl: async () => [
      { protocol: 'https', responseBodySha256: digest('https-response') }
    ]
  });

  assert.equal(proof.result, 'incomplete');
  assert.equal(proof.cleanup.relaunchCleanupSucceeded, false);
  assert.equal(execCalls.some((entry) => entry.includes('force-stop com.github.kr328.clash.harmony')), true);
  assert.equal(execCalls.some((entry) => entry.includes('force-stop com.cmfa.phase4.trafficprobe')), true);
});

test('plan d default cleanup rejects proxy-deactivate-ok plus STOPPED when STOPPING was never observed', async () => {
  const { proof } = await runPlanDDefaultCleanupScenario({
    pullEvidenceImpl: async ({ kind }) => {
      if (kind === 'probe') {
        return {
          records: [
            {
              stepId: 'https',
              outcome: 'pass',
              transport: 'https',
              statusCode: 200,
              responseBodySha256: digest('https-response')
            }
          ]
        };
      }
      if (kind === 'runtime-journal-post-phase4') {
        return {
          sessionAlias: 'session-old',
          records: [
            createRuntimeTrafficRecord({
              destinationHash: digest('tcp|192.168.0.9|443'),
              outboundTerminalHash: digest('Beta'),
              sequence: 10
            })
          ]
        };
      }
      if (kind === 'runtime-journal-relaunch') {
        return {
          sessionAlias: 'session-new',
          records: [
            createRuntimeTrafficRecord({
              destinationHash: digest('tcp|192.168.0.9|443'),
              outboundTerminalHash: digest('Beta'),
              sequence: 20
            }),
            { sequence: 21, kind: 'lifecycle', detail: 'proxy-activate-ok' },
            { sequence: 22, kind: 'lifecycle', detail: 'STATE_CHANGED:RUNNING' }
          ]
        };
      }
      return {
        runId: 'c76b37db-5c7d-4fdf-9c88-f1feef7a8a7b',
        sessionAlias: 'session-new',
        records: [
          { sequence: 31, kind: 'lifecycle', detail: 'proxy-deactivate-ok' },
          { sequence: 32, kind: 'lifecycle', detail: 'STATE_CHANGED:STOPPED' }
        ]
      };
    }
  });

  assert.equal(proof.cleanup.relaunchCleanupSucceeded, false);
});

test('plan d default cleanup fail-closes when cleanup evidence reuses the relaunch-stale session alias', async () => {
  const { proof } = await runPlanDDefaultCleanupScenario({
    pullEvidenceImpl: async ({ kind, expectedSessionAlias = '' }) => {
      if (kind === 'probe') {
        return {
          records: [
            {
              stepId: 'https',
              outcome: 'pass',
              transport: 'https',
              statusCode: 200,
              responseBodySha256: digest('https-response')
            }
          ]
        };
      }
      if (kind === 'runtime-journal-post-phase4') {
        return {
          sessionAlias: 'session-old',
          records: [
            createRuntimeTrafficRecord({
              destinationHash: digest('tcp|192.168.0.9|443'),
              outboundTerminalHash: digest('Beta'),
              sequence: 10
            })
          ]
        };
      }
      if (kind === 'runtime-journal-relaunch') {
        return {
          sessionAlias: 'session-new',
          records: [
            createRuntimeTrafficRecord({
              destinationHash: digest('tcp|192.168.0.9|443'),
              outboundTerminalHash: digest('Beta'),
              sequence: 20
            }),
            { sequence: 21, kind: 'lifecycle', detail: 'proxy-activate-ok' },
            { sequence: 22, kind: 'lifecycle', detail: 'STATE_CHANGED:RUNNING' }
          ]
        };
      }
      if (expectedSessionAlias.length > 0 && expectedSessionAlias !== 'session-stale') {
        throw Object.assign(new Error('PLAN_D_SESSION_ALIAS_MISMATCH'), { code: 'PLAN_D_SESSION_ALIAS_MISMATCH' });
      }
      return {
        runId: 'c76b37db-5c7d-4fdf-9c88-f1feef7a8a7b',
        sessionAlias: 'session-stale',
        records: [
          { sequence: 30, kind: 'lifecycle', detail: 'STATE_CHANGED:STOPPING' },
          { sequence: 31, kind: 'lifecycle', detail: 'STATE_CHANGED:STOPPED' }
        ]
      };
    }
  });

  assert.equal(proof.cleanup.relaunchCleanupSucceeded, false);
});

test('plan d default cleanup marks cleanup false when removing its temp root fails', async () => {
  const customFsApi = {
    ...fs,
    rm: async (targetPath, options) => {
      if (path.basename(targetPath).startsWith('plan-d-cleanup-')) {
        throw Object.assign(new Error('PLAN_D_CLEANUP_ROOT_RM_FAILED'), { code: 'PLAN_D_CLEANUP_ROOT_RM_FAILED' });
      }
      return await fs.rm(targetPath, options);
    }
  };

  const { proof } = await runPlanDDefaultCleanupScenario({
    fsApi: customFsApi,
    pullEvidenceImpl: async ({ kind }) => {
      if (kind === 'probe') {
        return {
          records: [
            {
              stepId: 'https',
              outcome: 'pass',
              transport: 'https',
              statusCode: 200,
              responseBodySha256: digest('https-response')
            }
          ]
        };
      }
      if (kind === 'runtime-journal-post-phase4') {
        return {
          sessionAlias: 'session-old',
          records: [
            createRuntimeTrafficRecord({
              destinationHash: digest('tcp|192.168.0.9|443'),
              outboundTerminalHash: digest('Beta'),
              sequence: 10
            })
          ]
        };
      }
      if (kind === 'runtime-journal-relaunch') {
        return {
          sessionAlias: 'session-new',
          records: [
            createRuntimeTrafficRecord({
              destinationHash: digest('tcp|192.168.0.9|443'),
              outboundTerminalHash: digest('Beta'),
              sequence: 20
            }),
            { sequence: 21, kind: 'lifecycle', detail: 'proxy-activate-ok' },
            { sequence: 22, kind: 'lifecycle', detail: 'STATE_CHANGED:RUNNING' }
          ]
        };
      }
      return {
        runId: 'c76b37db-5c7d-4fdf-9c88-f1feef7a8a7b',
        sessionAlias: 'session-new',
        records: [
          { sequence: 30, kind: 'lifecycle', detail: 'STATE_CHANGED:STOPPING' },
          { sequence: 31, kind: 'lifecycle', detail: 'STATE_CHANGED:STOPPED' }
        ]
      };
    }
  });

  assert.equal(proof.cleanup.relaunchCleanupSucceeded, false);
});

test('plan d runner closes the origin exactly once from finally when phase4 aborts after origin start', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'plan-d-origin-finally-'));
  const outputPath = path.join(tempRoot, 'plan-d-device-proof.json');
  const phase4OutputPath = path.join(tempRoot, 'phase4-device-proof.json');
  const productionHapPath = path.join(tempRoot, 'entry-default-signed.hap');
  const probeHapPath = path.join(tempRoot, 'probe-entry-default-signed.hap');
  let closeCount = 0;

  await fs.writeFile(productionHapPath, 'production-hap', 'utf8');
  await fs.writeFile(probeHapPath, 'probe-hap', 'utf8');

  const proof = await runner.runPlanDDeviceProof({
    productionHapPath,
    probeHapPath,
    phase4OutputPath,
    outputPath,
    tempRoot,
    runIdImpl: () => 'c76b37db-5c7d-4fdf-9c88-f1feef7a8a7b',
    hashFileImpl: async (filePath) => {
      const buffer = await fs.readFile(filePath);
      return { sha256: digest(buffer), sizeBytes: buffer.byteLength };
    },
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/mock/hdc' } }
    }),
    detectTargetImpl: async () => 'SERIAL123',
    cleanupImpl: async () => ({ stopVpn: false, forceStop: false }),
    runPhase4Impl: async (options) => {
      await options.startOriginImpl({
        runId: options.runId,
        deviceIpv4Candidates: [{ address: '192.168.0.8', netmask: '255.255.255.0' }]
      });
      throw Object.assign(new Error('PHASE4_ABORTED_AFTER_ORIGIN_START'), { code: 'PHASE4_ABORTED_AFTER_ORIGIN_START' });
    },
    startOriginImpl: async () => ({
      sessionId: 'session-1',
      https: { host: '192.168.0.9', port: 443 },
      close: async () => {
        closeCount += 1;
      }
    })
  });

  assert.equal(proof.result, 'incomplete');
  assert.equal(closeCount, 1);
});

test('plan d failure outputs remain canonical incomplete and never persist raw labels ids urls or temp paths', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'plan-d-failure-'));
  const outputPath = path.join(tempRoot, 'plan-d-device-proof.json');
  const phase4OutputPath = path.join(tempRoot, 'phase4-device-proof.json');
  const productionHapPath = path.join(tempRoot, 'entry-default-signed.hap');
  const probeHapPath = path.join(tempRoot, 'probe-entry-default-signed.hap');

  await fs.writeFile(productionHapPath, 'production-hap', 'utf8');
  await fs.writeFile(probeHapPath, 'probe-hap', 'utf8');

  const proof = await runner.runPlanDDeviceProof({
    productionHapPath,
    probeHapPath,
    phase4OutputPath,
    outputPath,
    tempRoot,
    runIdImpl: () => 'c76b37db-5c7d-4fdf-9c88-f1feef7a8a7b',
    hashFileImpl: async (filePath) => {
      const buffer = await fs.readFile(filePath);
      return { sha256: digest(buffer), sizeBytes: buffer.byteLength };
    },
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/mock/hdc' } }
    }),
    detectTargetImpl: async () => 'SERIAL123',
    runPhase4Impl: async () => createPhase4Proof(),
    startOriginImpl: async () => ({
      sessionId: 'session-1',
      https: { host: '192.168.0.9', port: 443 },
      close: async () => {}
    }),
    uiDriver: {
      launchProductionImpl: async () => {},
      openProxyManageImpl: async () => {},
      dumpLayoutImpl: async () => createProxyLayout(),
      clickNodeImpl: async () => {},
      navigateBackHomeImpl: async () => {},
      startVpnImpl: async () => {},
      performPhase4AutomationImpl: async () => ({
        ok: true,
        ongoingNotificationVisible: true,
        launcherContinuity: true,
        screenOffContinuity: true,
        vpnIndicatorVisible: true
      })
    },
    pullEvidenceImpl: async ({ kind }) => kind === 'probe'
      ? {
        records: [
          {
            stepId: 'https',
            outcome: 'pass',
            transport: 'https',
            statusCode: 200,
            responseBodySha256: digest('https-response')
          }
        ]
      }
      : {
        records: [
          createRuntimeTrafficRecord({
            destinationHash: digest('tcp|192.168.0.9|443'),
            outboundTerminalHash: digest('other-terminal')
          })
        ]
      },
    collectOriginObservationsImpl: async () => [
      { protocol: 'https', responseBodySha256: digest('https-response') }
    ]
  });

  const persisted = JSON.parse(await fs.readFile(outputPath, 'utf8'));
  const serialized = JSON.stringify(persisted);
  assert.equal(proof.result, 'incomplete');
  assert.equal(persisted.result, 'incomplete');
  assert.equal(persisted.failures.every((entry) => Object.keys(entry).sort().join(',') === 'code,stage'), true);
  assert.equal(serialized.includes('Alpha'), false);
  assert.equal(serialized.includes('Beta'), false);
  assert.equal(serialized.includes('proxies.node.0'), false);
  assert.equal(serialized.includes('proxies.node.1'), false);
  assert.equal(serialized.includes(HTTPS_LITERAL), false);
  assert.equal(serialized.includes(tempRoot), false);
});
