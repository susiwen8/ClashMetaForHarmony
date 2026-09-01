import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const RUNNER_MODULE_PATH = new URL('../bin/run-proxy-delay-device-proof.mjs', import.meta.url);
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'proxy-delay-device-proof.schema.json');
const EXAMPLE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'proxy-delay-device-proof.example.json');
const DOC_PATH = path.join(REPO_ROOT, 'docs', 'harmony', 'proxy-delay-device-proof.md');
const HAP_PATH = path.join(HARMONY_ROOT, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const ARTIFACT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'proxy-delay-device-proof.json');
const FIXTURE_SHA256 = 'e5365cbdc7188d7c4ddf7e7937c94a952dbfe6740c0549ee10feb5470059420d';
const ZERO_SHA256 = '0'.repeat(64);

function digest(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function createNode(id, text = '', children = []) {
  const attributes = { id };
  if (text.length > 0) {
    attributes.text = text;
  }
  return {
    attributes,
    bounds: { left: 0, top: 0, right: 320, bottom: 60 },
    children
  };
}

function createActionableNode(id, text = '', children = []) {
  const node = createNode(id, text, children);
  node.attributes.clickable = 'true';
  node.attributes.enabled = 'true';
  return node;
}

function createDelayRow(index, {
  stateText = '等待',
  fastest = false,
  extraChildren = []
} = {}) {
  const baseId = `proxies.node.${index}`;
  const children = [
    createNode(`${baseId}.delay`, stateText)
  ];
  if (fastest) {
    children.push(createNode(`${baseId}.fastest`, '最快'));
  }
  return createNode(baseId, '', children.concat(extraChildren));
}

function createProxyDelayLayout(rows, extras = {}) {
  const children = [
    createNode('detail.proxy.toggle'),
    createNode('proxies.delay-test', extras.delayButtonText ?? '开始测速')
  ];
  if (extras.progressText !== undefined) {
    children.push(createNode('proxies.delay-progress', extras.progressText));
  }
  if (extras.summaryText !== undefined) {
    children.push(createNode('proxies.delay-summary', extras.summaryText));
  }
  return {
    root: createNode('root', '', children.concat(rows))
  };
}

function createCleanupLayout(children = []) {
  return {
    root: createNode('root', '', children)
  };
}

function createPassProof() {
  return {
    schemaVersion: '1.0.0',
    result: 'pass',
    packageSha256: FIXTURE_SHA256,
    measurement: {
      totalCount: 4,
      testableCount: 3,
      availableCount: 1,
      timeoutCount: 1,
      failedCount: 1,
      minDelayMs: 81,
      medianDelayMs: 81,
      maxDelayMs: 81
    },
    cancellationState: 'CANCELLED'
  };
}

function createIncompleteProof() {
  return {
    schemaVersion: '1.0.0',
    result: 'incomplete',
    packageSha256: ZERO_SHA256,
    measurement: {
      totalCount: 0,
      testableCount: 0,
      availableCount: 0,
      timeoutCount: 0,
      failedCount: 0,
      minDelayMs: 0,
      medianDelayMs: 0,
      maxDelayMs: 0
    },
    cancellationState: 'NOT_PROVEN'
  };
}

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

test('proxy delay device proof schema/example and validator accept exact pass and incomplete shapes while rejecting unknown or sensitive keys', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const schema = JSON.parse(await readUtf8(SCHEMA_PATH));
  const example = JSON.parse(await readUtf8(EXAMPLE_PATH));

  assert.equal(typeof runner.validateProxyDelayProofDocument, 'function');
  assert.equal(typeof runner.writeValidatedProxyDelayProof, 'function');

  const passValidation = await runner.validateProxyDelayProofDocument(createPassProof(), schema);
  assert.equal(passValidation.valid, true);

  const incompleteValidation = await runner.validateProxyDelayProofDocument(createIncompleteProof(), schema);
  assert.equal(incompleteValidation.valid, true);

  const exampleValidation = await runner.validateProxyDelayProofDocument(example, schema);
  assert.equal(exampleValidation.valid, true);

  const unknownKeyValidation = await runner.validateProxyDelayProofDocument({
    ...createPassProof(),
    runId: 'secret-run-id'
  }, schema);
  assert.equal(unknownKeyValidation.valid, false);

  const sensitiveKeyValidation = await runner.validateProxyDelayProofDocument({
    ...createPassProof(),
    measurement: {
      ...createPassProof().measurement,
      provider: 'private'
    }
  }, schema);
  assert.equal(sensitiveKeyValidation.valid, false);
});

test('proxy delay device proof layout analyzer parses terminal rows, fastest marker, exact ordering, and aggregate measurement from synthetic layouts', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const layout = createProxyDelayLayout([
    createDelayRow(0, { stateText: '81 ms', fastest: true }),
    createDelayRow(1, { stateText: '超时' }),
    createDelayRow(2, { stateText: '不可用' }),
    createDelayRow(3, { stateText: '不支持' })
  ], {
    summaryText: 'summary-ready'
  });

  const analysis = runner.analyzeProxyDelayLayout(layout);

  assert.equal(analysis.rows.length, 4);
  assert.equal(analysis.rows[0].state, 'AVAILABLE');
  assert.equal(analysis.rows[0].delayMs, 81);
  assert.equal(analysis.rows[0].fastest, true);
  assert.equal(analysis.rows[1].state, 'TIMEOUT');
  assert.equal(analysis.rows[2].state, 'FAILED');
  assert.equal(analysis.rows[3].state, 'UNSUPPORTED');
  assert.equal(analysis.totalCount, 4);
  assert.equal(analysis.testableCount, 3);
  assert.equal(analysis.availableCount, 1);
  assert.equal(analysis.timeoutCount, 1);
  assert.equal(analysis.failedCount, 1);
  assert.equal(analysis.phase, 'terminal');
  assert.equal(analysis.hasSummary, true);

  const measurement = runner.calculateDelayMeasurement(analysis.rows);
  assert.deepEqual(measurement, createPassProof().measurement);
});

test('proxy delay device proof layout analyzer recognizes progress/live states and rejects malformed or ambiguous row layouts', async () => {
  const runner = await import(RUNNER_MODULE_PATH);

  const liveLayout = createProxyDelayLayout([
    createDelayRow(0, { stateText: '测速中' }),
    createDelayRow(1, { stateText: '等待' }),
    createDelayRow(2, { stateText: '已取消' })
  ], {
    progressText: '1 / 3'
  });
  const liveAnalysis = runner.analyzeProxyDelayLayout(liveLayout);
  assert.equal(liveAnalysis.phase, 'live');
  assert.equal(liveAnalysis.hasProgress, true);
  assert.equal(liveAnalysis.rows[0].state, 'TESTING');
  assert.equal(liveAnalysis.rows[1].state, 'WAITING');
  assert.equal(liveAnalysis.rows[2].state, 'CANCELLED');

  assert.throws(
    () => runner.analyzeProxyDelayLayout(createProxyDelayLayout([
      createDelayRow(0, { stateText: '81 ms', fastest: true }),
      createDelayRow(2, { stateText: '95 ms' })
    ])),
    /PROXY_DELAY_LAYOUT_ORDER_INVALID/u
  );

  assert.throws(
    () => runner.analyzeProxyDelayLayout(createProxyDelayLayout([
      createDelayRow(0, { stateText: '81 ms', fastest: true }),
      createDelayRow(1, { stateText: '95 ms', fastest: true })
    ], { summaryText: 'summary-ready' })),
    /PROXY_DELAY_FASTEST_AMBIGUOUS/u
  );

  assert.throws(
    () => runner.analyzeProxyDelayLayout(createProxyDelayLayout([
      createDelayRow(0, {
        extraChildren: [createNode('proxies.node.0.delay', '超时')]
      })
    ])),
    /PROXY_DELAY_ROW_STATE_AMBIGUOUS/u
  );
});

test('proxy delay device proof cancellation comparator preserves completed outcomes while allowing cancelled pending rows', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const completed = [
    { index: 0, state: 'AVAILABLE', delayMs: 88, fastest: true },
    { index: 1, state: 'TIMEOUT', delayMs: null, fastest: false },
    { index: 2, state: 'FAILED', delayMs: null, fastest: false },
    { index: 3, state: 'UNSUPPORTED', delayMs: null, fastest: false }
  ];
  const completedRetained = [
    { index: 0, state: 'AVAILABLE', delayMs: 88, fastest: true },
    { index: 1, state: 'TIMEOUT', delayMs: null, fastest: false },
    { index: 2, state: 'FAILED', delayMs: null, fastest: false },
    { index: 3, state: 'UNSUPPORTED', delayMs: null, fastest: false }
  ];
  const pending = [
    { index: 0, state: 'AVAILABLE', delayMs: 88, fastest: true },
    { index: 1, state: 'TIMEOUT', delayMs: null, fastest: false },
    { index: 2, state: 'WAITING', delayMs: null, fastest: false },
    { index: 3, state: 'UNSUPPORTED', delayMs: null, fastest: false }
  ];
  const cancelledPending = [
    { index: 0, state: 'AVAILABLE', delayMs: 88, fastest: true },
    { index: 1, state: 'TIMEOUT', delayMs: null, fastest: false },
    { index: 2, state: 'CANCELLED', delayMs: null, fastest: false },
    { index: 3, state: 'UNSUPPORTED', delayMs: null, fastest: false }
  ];

  assert.equal(runner.compareCancellationRetention(completed, completedRetained), true);
  assert.equal(runner.compareCancellationRetention(pending, cancelledPending), true);

  assert.throws(
    () => runner.compareCancellationRetention(completed, [
      { index: 0, state: 'FAILED', delayMs: null, fastest: false },
      { index: 1, state: 'TIMEOUT', delayMs: null, fastest: false },
      { index: 2, state: 'FAILED', delayMs: null, fastest: false },
      { index: 3, state: 'UNSUPPORTED', delayMs: null, fastest: false }
    ]),
    /PROXY_DELAY_CANCELLATION_RETENTION_INVALID/u
  );
  assert.throws(
    () => runner.compareCancellationRetention(completed, [
      { index: 0, state: 'AVAILABLE', delayMs: 91, fastest: false },
      { index: 1, state: 'TIMEOUT', delayMs: null, fastest: false },
      { index: 2, state: 'AVAILABLE', delayMs: 40, fastest: false },
      { index: 3, state: 'UNSUPPORTED', delayMs: null, fastest: false }
    ]),
    /PROXY_DELAY_CANCELLATION_RETENTION_INVALID/u
  );
});

test('proxy delay device proof runner supports injected complete, cancelled, and vpn-quiet orchestration', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'proxy-delay-proof-runner-'));
  const outputPath = path.join(tempRoot, 'proxy-delay-device-proof.json');
  const productionHapPath = path.join(tempRoot, 'entry-default-signed.hap');
  await fs.writeFile(productionHapPath, 'signed-hap', 'utf8');

  const persisted = [];
  const orchestrationCalls = [];
  const completedRows = [
    { index: 0, state: 'AVAILABLE', delayMs: 81, fastest: true },
    { index: 1, state: 'TIMEOUT', delayMs: null, fastest: false },
    { index: 2, state: 'FAILED', delayMs: null, fastest: false },
    { index: 3, state: 'UNSUPPORTED', delayMs: null, fastest: false }
  ];
  const cancelledRows = [
    { index: 0, state: 'AVAILABLE', delayMs: 95, fastest: true },
    { index: 1, state: 'TIMEOUT', delayMs: null, fastest: false },
    { index: 2, state: 'CANCELLED', delayMs: null, fastest: false },
    { index: 3, state: 'UNSUPPORTED', delayMs: null, fastest: false }
  ];
  const cleanupArgs = runner.buildProxyDelayRuntimeJournalDeleteArgs('device-1');

  assert.equal(typeof runner.buildProxyDelayRuntimeJournalDeleteArgs, 'function');
  assert.equal(typeof runner.deleteProxyDelayRuntimeJournal, 'function');
  assert.deepEqual(cleanupArgs, [
    '-t',
    'device-1',
    'shell',
    '-b',
    'com.github.kr328.clash.harmony',
    'rm',
    '-f',
    '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json'
  ]);
  await runner.deleteProxyDelayRuntimeJournal({
    target: 'device-1',
    hdcCommand: 'hdc-bin',
    cwd: REPO_ROOT,
    execImpl: async (command, args) => {
      assert.equal(command, 'hdc-bin');
      assert.deepEqual(args, cleanupArgs);
      return { exitCode: 0, stdout: '', stderr: '', timedOut: false };
    }
  });
  await assert.rejects(
    async () => await runner.deleteProxyDelayRuntimeJournal({
      target: 'device-1',
      hdcCommand: 'hdc-bin',
      cwd: REPO_ROOT,
      execImpl: async () => ({ exitCode: 0, stdout: '', stderr: '', timedOut: true })
    }),
    /PROXY_DELAY_CLEANUP_FAILED/u
  );
  await assert.rejects(
    async () => await runner.deleteProxyDelayRuntimeJournal({
      target: 'device-1',
      hdcCommand: 'hdc-bin',
      cwd: REPO_ROOT,
      execImpl: async () => ({ exitCode: 1, stdout: '', stderr: '', timedOut: false })
    }),
    /PROXY_DELAY_CLEANUP_FAILED/u
  );
  await assert.rejects(
    async () => await runner.deleteProxyDelayRuntimeJournal({
      target: 'device-1',
      hdcCommand: 'hdc-bin',
      cwd: REPO_ROOT,
      execImpl: async () => ({ exitCode: 0, stdout: '', stderr: '', timedOut: false, error: new Error('boom') })
    }),
    /PROXY_DELAY_CLEANUP_FAILED/u
  );

  const proof = await runner.runProxyDelayDeviceProof({
    productionHapPath,
    outputPath,
    repoRoot: REPO_ROOT,
    hashFileImpl: async () => ({ sha256: FIXTURE_SHA256, sizeBytes: 9 }),
    writeValidatedProofImpl: async (candidate) => {
      persisted.push(candidate);
      return candidate;
    },
    orchestrationImpl: async () => {
      orchestrationCalls.push('run');
      return {
        completedRows,
        cancelledRows,
        cancellationState: 'CANCELLED',
        vpnQuiet: true
      };
    }
  });

  assert.equal(orchestrationCalls.length, 1);
  assert.equal(persisted.length, 1);
  assert.equal(proof.result, 'pass');
  assert.equal(proof.packageSha256, FIXTURE_SHA256);
  assert.deepEqual(proof.measurement, createPassProof().measurement);
  assert.equal(proof.cancellationState, 'CANCELLED');

  const persistedCleanupFailure = [];
  const execCalls = [];
  const stderrChunks = [];
  const originalStderrWrite = process.stderr.write;
  process.stderr.write = (chunk, ...rest) => {
    stderrChunks.push(String(chunk));
    return typeof originalStderrWrite === 'function'
      ? originalStderrWrite.call(process.stderr, chunk, ...rest)
      : true;
  };
  try {
    const cleanupFailureProof = await runner.runProxyDelayDeviceProof({
      productionHapPath,
      outputPath,
      repoRoot: REPO_ROOT,
      requiresDeviceSetup: true,
      hashFileImpl: async () => ({ sha256: FIXTURE_SHA256, sizeBytes: 9 }),
      toolchainInspectorImpl: async () => ({
        report: { result: 'pass' },
        resolved: { paths: { hdc: 'hdc-bin' } }
      }),
      execImpl: async (command, args) => {
        execCalls.push({ command, args });
        if (args[0] === 'list' && args[1] === 'targets') {
          return { exitCode: 0, stdout: 'device-1\n', stderr: '', timedOut: false };
        }
        if (args[0] === '-t' && args[2] === 'install') {
          return { exitCode: 0, stdout: '', stderr: '', timedOut: false };
        }
        if (args[0] === '-t' && args[2] === 'shell' && args[3] === 'aa' && args[4] === 'force-stop') {
          return { exitCode: 0, stdout: '', stderr: '', timedOut: false };
        }
        if (args[0] === '-t' && args[2] === 'shell' && args[3] === '-b' && args[4] === 'com.github.kr328.clash.harmony') {
          return { exitCode: 1, stdout: '', stderr: '', timedOut: false };
        }
        throw new Error(`unexpected exec args: ${args.join(' ')}`);
      },
      orchestrationImpl: async () => ({
        completedRows,
        cancelledRows,
        cancellationState: 'CANCELLED',
        vpnQuiet: true
      }),
      writeValidatedProofImpl: async (candidate) => {
        persistedCleanupFailure.push(structuredClone(candidate));
        return candidate;
      }
    });

    assert.equal(cleanupFailureProof.result, 'incomplete');
    assert.deepEqual(cleanupFailureProof.measurement, createIncompleteProof().measurement);
    assert.equal(cleanupFailureProof.cancellationState, 'NOT_PROVEN');
    assert.equal(persistedCleanupFailure.length, 1);
    assert.equal(persistedCleanupFailure[0].result, 'incomplete');
    assert.deepEqual(persistedCleanupFailure[0].measurement, createIncompleteProof().measurement);
    assert.equal(persistedCleanupFailure[0].cancellationState, 'NOT_PROVEN');
    assert.deepEqual(stderrChunks, ['PROXY_DELAY_CLEANUP_FAILED\n']);
    assert.deepEqual(
      execCalls.find((entry) => entry.args[2] === 'shell' && entry.args[3] === '-b')?.args,
      cleanupArgs
    );

    const persistedStopFailure = [];
    const stopFailureStderrChunks = [];
    process.stderr.write = (chunk, ...rest) => {
      stopFailureStderrChunks.push(String(chunk));
      return typeof originalStderrWrite === 'function'
        ? originalStderrWrite.call(process.stderr, chunk, ...rest)
        : true;
    };
    const stopFailureProof = await runner.runProxyDelayDeviceProof({
      productionHapPath,
      outputPath,
      repoRoot: REPO_ROOT,
      requiresDeviceSetup: true,
      hashFileImpl: async () => ({ sha256: FIXTURE_SHA256, sizeBytes: 9 }),
      toolchainInspectorImpl: async () => ({
        report: { result: 'pass' },
        resolved: { paths: { hdc: 'hdc-bin' } }
      }),
      execImpl: async (command, args) => {
        assert.equal(command, 'hdc-bin');
        if (args[0] === 'list' && args[1] === 'targets') {
          return { exitCode: 0, stdout: 'device-1\n', stderr: '', timedOut: false };
        }
        if (args[0] === '-t' && args[2] === 'install') {
          return { exitCode: 0, stdout: '', stderr: '', timedOut: false };
        }
        return { exitCode: 0, stdout: '', stderr: '', timedOut: false };
      },
      orchestrationImpl: async () => ({
        completedRows,
        cancelledRows,
        cancellationState: 'CANCELLED',
        vpnQuiet: true
      }),
      ensureVpnStoppedImpl: async () => {
        throw Object.assign(new Error('stop failed'), { code: 'PROXY_DELAY_CLEANUP_FAILED' });
      },
      forceStopProductionAppImpl: async () => {},
      forceStopProbeAppImpl: async () => {},
      deleteProxyDelayRuntimeJournalImpl: async () => {},
      writeValidatedProofImpl: async (candidate) => {
        persistedStopFailure.push(structuredClone(candidate));
        return candidate;
      }
    });

    assert.equal(stopFailureProof.result, 'incomplete');
    assert.deepEqual(stopFailureProof.measurement, createIncompleteProof().measurement);
    assert.equal(stopFailureProof.cancellationState, 'NOT_PROVEN');
    assert.equal(persistedStopFailure.length, 1);
    assert.equal(persistedStopFailure[0].result, 'incomplete');
    assert.deepEqual(persistedStopFailure[0].measurement, createIncompleteProof().measurement);
    assert.equal(persistedStopFailure[0].cancellationState, 'NOT_PROVEN');
    assert.deepEqual(stopFailureStderrChunks, ['PROXY_DELAY_CLEANUP_FAILED\n']);
  } finally {
    process.stderr.write = originalStderrWrite;
  }
});

test('proxy delay device proof CLI parsing keeps repository-safe defaults and proof writing falls back to canonical incomplete on invalid output', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const parsed = runner.parseCliArguments([
    '--production-hap', HAP_PATH,
    '--out', ARTIFACT_PATH
  ]);
  assert.equal(parsed.productionHapPath, HAP_PATH);
  assert.equal(parsed.outputPath, ARTIFACT_PATH);

  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'proxy-delay-proof-writer-'));
  const outputPath = path.join(tempRoot, 'proxy-delay-device-proof.json');
  const invalidProof = {
    schemaVersion: '1.0.0',
    result: 'pass',
    packageSha256: 'oops',
    measurement: {
      totalCount: 1,
      testableCount: 1,
      availableCount: 1,
      timeoutCount: 0,
      failedCount: 0,
      minDelayMs: 12,
      medianDelayMs: 12,
      maxDelayMs: 12
    },
    cancellationState: 'CANCELLED'
  };

  const persisted = await runner.writeValidatedProxyDelayProof(invalidProof, outputPath);
  assert.equal(persisted.result, 'incomplete');
  assert.equal(persisted.packageSha256, ZERO_SHA256);
  assert.deepEqual(persisted.measurement, createIncompleteProof().measurement);
  assert.equal(persisted.cancellationState, 'NOT_PROVEN');
});

test('proxy delay device proof source contract pins exact selectors, polling bounds, signed hap install, cleanup, and privacy-safe persistence', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const source = await readUtf8(fileURLToPath(RUNNER_MODULE_PATH));
  const homeLayout = createCleanupLayout([
    createActionableNode('home.vpn.action', 'Start')
  ]);
  const detailBackLayout = createCleanupLayout([
    createActionableNode('detail.back', 'Back')
  ]);
  const profilesBackLayout = createCleanupLayout([
    createActionableNode('profiles.back', 'Back')
  ]);
  const normalized = runner.normalizeProxyDelayRuntimeJournal({
    counters: {
      rxPackets: 7,
      txPackets: 9,
      rxBytes: 70,
      txBytes: 90
    },
    records: [
      {
        sequence: 1,
        kind: 'lifecycle',
        ingress: 'tun',
        detail: 'STATE_CHANGED:RUNNING',
        extraScalar: 'ignored-record-value',
        extraObject: { nestedFlag: true }
      }
    ],
    lifecycle: {
      state: 'RUNNING',
      recoveryAttempt: 4,
      extra: 'ignored'
    },
    extraScalar: 'ignored-value',
    extraObject: { nestedFlag: true }
  });
  const normalizedInvalidLifecycle = runner.normalizeProxyDelayRuntimeJournal({
    lifecycle: {
      state: 123,
      recoveryAttempt: -1
    }
  });
  const navigationAction = runner.selectVpnCleanupNavigationAction(homeLayout);
  const backNavigationAction = runner.selectVpnCleanupNavigationAction(detailBackLayout);
  const clickedNodes = [];
  const navigatedLayout = await runner.navigateToVpnCleanupHome({
    readLayoutImpl: async () => {
      if (clickedNodes.length === 0) {
        return detailBackLayout;
      }
      if (clickedNodes.length === 1) {
        return profilesBackLayout;
      }
      return homeLayout;
    },
    clickLayoutNodeImpl: async (selection) => {
      clickedNodes.push(selection.node.attributes.id);
    },
    attempts: 2
  });
  const directNavigatedLayout = await runner.navigateToVpnCleanupHome({
    readLayoutImpl: async () => homeLayout,
    clickLayoutNodeImpl: async () => {
      throw new Error('home navigation should not click');
    },
    attempts: 2
  });

  assert.equal(typeof runner.normalizeProxyDelayRuntimeJournal, 'function');
  assert.equal(typeof runner.selectVpnCleanupNavigationAction, 'function');
  assert.equal(typeof runner.navigateToVpnCleanupHome, 'function');
  assert.deepEqual(normalized.counters, {
    rxPackets: 7,
    txPackets: 9,
    rxBytes: 70,
    txBytes: 90
  });
  assert.deepEqual(normalized.records, [
    {
      sequence: 1,
      kind: 'lifecycle',
      ingress: 'tun',
      detail: 'STATE_CHANGED:RUNNING'
    }
  ]);
  assert.deepEqual(normalized.lifecycle, {
    state: 'running',
    recoveryAttempt: 4
  });
  assert.equal('extraScalar' in normalized, false);
  assert.equal('extraObject' in normalized, false);
  assert.deepEqual(normalizedInvalidLifecycle.lifecycle, {
    state: '',
    recoveryAttempt: 0
  });
  assert.equal(navigationAction.kind, 'home');
  assert.equal(backNavigationAction.kind, 'detail-back');
  assert.equal(directNavigatedLayout, homeLayout);
  assert.equal(navigatedLayout, homeLayout);
  assert.deepEqual(clickedNodes, ['detail.back', 'profiles.back']);
  assert.throws(
    () => runner.selectVpnCleanupNavigationAction(createCleanupLayout([
      createActionableNode('home.vpn.action', 'Start'),
      createActionableNode('home.vpn.action', 'Stop')
    ])),
    /PROXY_DELAY_CLEANUP_FAILED/u
  );
  assert.throws(
    () => runner.selectVpnCleanupNavigationAction(createCleanupLayout([
      createActionableNode('other.node', 'Other')
    ])),
    /PROXY_DELAY_CLEANUP_FAILED/u
  );

  assert.match(source, /home\.profile\.manage/u);
  assert.match(source, /home\.vpn\.action/u);
  assert.match(source, /detail\.proxy\.toggle/u);
  assert.match(source, /detail\.back/u);
  assert.match(source, /profiles\.back/u);
  assert.doesNotMatch(source, /home\.proxy\.manage/u);
  assert.match(source, /proxies\.delay-test/u);
  assert.match(source, /proxies\.delay-progress/u);
  assert.match(source, /proxies\.delay-summary/u);
  assert.match(source, /proxies\.node\.\$\{index\}/u);
  assert.match(source, /等待/u);
  assert.match(source, /测速中/u);
  assert.match(source, /超时/u);
  assert.match(source, /不可用/u);
  assert.match(source, /已取消/u);
  assert.match(source, /不支持/u);
  assert.match(source, /const UI_POLL_INTERVAL_MS = 250;/u);
  assert.match(source, /const COMPLETE_POLL_ATTEMPTS = 80;/u);
  assert.match(source, /const CANCEL_RETRY_LIMIT = 3;/u);
  assert.match(source, /const VPN_QUIET_RETRY_LIMIT = 3;/u);
  assert.match(source, /install', '-r'/u);
  assert.match(source, /entry-default-signed\.hap/u);
  assert.match(source, /dumpLayoutToHost/u);
  assert.match(source, /waitForVpnConsentAction/u);
  assert.match(source, /navigateToVpnCleanupHome/u);
  assert.match(source, /finally/u);
  assert.match(source, /rm\(localLayoutPath, \{ force: true \}\)/u);
  assert.match(source, /rm\(runtimeJournalPath, \{ force: true \}\)/u);
  assert.match(source, /force-stop', APP_BUNDLE/u);
  assert.match(source, /force-stop', PROBE_BUNDLE/u);
  assert.match(source, /shell', '-b', APP_BUNDLE, 'rm', '-f', RUNTIME_REMOTE_PATH/u);
  assert.match(source, /proof\.result = 'incomplete';/u);
  assert.match(source, /proof\.cancellationState = 'NOT_PROVEN';/u);
  assert.match(source, /proof\.measurement = createMeasurement\(\);/u);
  assert.doesNotMatch(source, /ensureVpnStopped\([^)]*\)\.catch\(\(\) => \{\}\)/u);
  assert.match(source, /platform-protect-ok/u);
  assert.doesNotMatch(
    source,
    /compareCancellationRetention\(completedRows,\s*analysis\.rows\)/u,
    'runCancellationCapture must only compare liveRows against the cancelled terminal rows from the same run'
  );
  assert.doesNotMatch(
    source,
    /compareCancellationRetention\(orchestration\.completedRows,\s*orchestration\.cancelledRows\)/u,
    'runProxyDelayDeviceProof must not compare completedRows and cancelledRows across independent runs'
  );
  assert.doesNotMatch(source, /CMFA_SAFE_PROXY_DELAY_STAGE/u);
  assert.doesNotMatch(source, /reportSafeProxyDelayStage/u);
  assert.doesNotMatch(source, /JSON\.stringify\((?:layout|rows|runtimeJournal|probe|origin)/u);
  assert.doesNotMatch(source, /console\.(?:log|error|warn)\([^)]*(?:session|device|provider|endpoint|node|group|url|label)/u);
  assert.doesNotMatch(source, /failures\s*:/u, 'persisted proof must not serialize private failure arrays');
});

test('proxy delay device proof documentation pins the exact command, fields, package path, and zero-private-data guarantee', async () => {
  const doc = await readUtf8(DOC_PATH);

  assert.match(doc, /schemaVersion/u);
  assert.match(doc, /result/u);
  assert.match(doc, /packageSha256/u);
  assert.match(doc, /measurement/u);
  assert.match(doc, /cancellationState/u);
  assert.match(doc, /node harmony\/tests\/bin\/run-proxy-delay-device-proof\.mjs --production-hap harmony\/entry\/build\/default\/outputs\/default\/entry-default-signed\.hap --out harmony\/artifacts\/proxy-delay-device-proof\.json/u);
  assert.match(doc, /entry-default-signed\.hap/u);
  assert.match(doc, new RegExp(FIXTURE_SHA256, 'u'));
  assert.match(doc, /zero private data/i);
  assert.doesNotMatch(doc, /serial|udid|device id|sessionAlias|provider|endpoint|signing/i);
});
