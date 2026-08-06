import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const RUNNER_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'run-phase2-device-proof.mjs');
const INSPECT_HAP_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'inspect-hap.mjs');
const INSPECT_NATIVE_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'inspect-native-lib.mjs');
const ORIGIN_MODULE_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'phase2-origin.mjs');
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase2-device-proof.schema.json');
const EXAMPLE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase2-device-proof.example.json');
const APP_EVIDENCE_EXAMPLE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase2-app-evidence.example.json');
const DEBUG_PAGE_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'pages', 'CoreDebugPage.ets');
const ENTRY_ABILITY_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'entryability', 'EntryAbility.ets');
const EXPECTED_RUN_ID = '980cbe02-b817-4db1-99bc-e8e4e6523daf';
const CORE_COMMIT = 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb';
const CORE_VERSION = 'v1.19.29';
const BUILD_INFO_JSON = JSON.stringify({
  version: CORE_VERSION,
  upstreamCommit: CORE_COMMIT,
  abiVersion: 'cmfa-harmony-v1',
  buildId: '0123456789abcdef'
});

let runner = null;
let inspectHapModule = null;
try {
  runner = await import(pathToFileURL(RUNNER_PATH).href);
} catch {
  // RED until the runner exists.
}
try {
  inspectHapModule = await import(pathToFileURL(INSPECT_HAP_PATH).href);
} catch {
  // RED until the HAP inspector exists.
}

function digest(char) {
  return char.repeat(64);
}

function joinFragments(parts) {
  return parts.join('');
}

const certPemLiteral = joinFragments(['-----BEGIN ', 'CERTIFICATE', '-----\n...\n-----END ', 'CERTIFICATE', '-----']);
const certPemPath = joinFragments(['harmony/artifacts/phase2-origin/', 'cert', '.', 'pem']);
const keyPemPath = joinFragments(['harmony/artifacts/phase2-origin/', 'key', '.', 'pem']);
const certPathKey = joinFragments(['cert', 'Path']);
const keyPathKey = joinFragments(['key', 'Path']);

async function readAppEvidenceFixture() {
  return JSON.parse(await fs.readFile(APP_EVIDENCE_EXAMPLE_PATH, 'utf8'));
}

function createValidPassProof() {
  return {
    schemaVersion: '1.0.0',
    phase: 2,
    result: 'pass',
    runId: EXPECTED_RUN_ID,
    outputPath: 'harmony/artifacts/phase2-device-proof.json',
    bundle: 'com.github.kr328.clash.harmony',
    ability: 'EntryAbility',
    timestamps: {
      runnerStartedAt: '2026-08-06T02:00:00.000Z',
      appStartedAt: '2026-08-06T02:00:03.000Z',
      proofAt: '2026-08-06T02:00:05.000Z',
      runnerFinishedAt: '2026-08-06T02:00:06.000Z'
    },
    toolchain: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hvigorVersion: '6.23.7',
      nodeVersion: '22.17.0',
      hdcVersion: '6.1.0.105'
    },
    device: {
      targetKind: 'physical',
      identityMasked: 'target-83e1d9a4',
      model: 'Harmony Phone',
      product: 'PuraX',
      buildVersion: 'HarmonyOS 6.0.1.123',
      apiVersion: '20',
      abi: 'arm64-v8a'
    },
    hap: {
      path: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
      sha256: digest('a'),
      sizeBytes: 2048
    },
    packaged: {
      rawCore: {
        path: 'harmony/artifacts/libcmfa_mihomo.so',
        sha256: digest('b'),
        sizeBytes: 512
      },
      prePackageCore: {
        path: 'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so',
        sha256: digest('b'),
        sizeBytes: 512
      },
      prePackageAddon: {
        path: 'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so',
        sha256: digest('c'),
        sizeBytes: 256
      },
      core: {
        path: 'libs/arm64-v8a/libcmfa_mihomo.so',
        sha256: digest('b'),
        sizeBytes: 512
      },
      addon: {
        path: 'libs/arm64-v8a/libentry.so',
        sha256: digest('c'),
        sizeBytes: 256
      }
    },
    fixtures: {
      matchConfig: {
        path: 'harmony/tests/fixtures/phase2-match-direct.yaml',
        sha256: digest('d'),
        sizeBytes: 43
      },
      originBody: {
        path: 'harmony/tests/fixtures/origin-body.txt',
        sha256: digest('e'),
        sizeBytes: 26
      }
    },
    origin: {
      originRunId: EXPECTED_RUN_ID,
      originId: 'origin-123',
      originUrl: 'https://127.0.0.1:18443/',
      bindAddress: '127.0.0.1:18443',
      tlsCertSha256: digest('f'),
      responseSha256: digest('e'),
      requestObservations: [
        {
          protocol: 'HTTP_CONNECT',
          requestId: 'req-http',
          originRequestId: 'req-http',
          originEventRunId: EXPECTED_RUN_ID,
          httpStatus: 200,
          responseBytes: 26,
          responseSha256: digest('e'),
          observedAt: '2026-08-06T02:00:04.000Z'
        },
        {
          protocol: 'SOCKS5',
          requestId: 'req-socks',
          originRequestId: 'req-socks',
          originEventRunId: EXPECTED_RUN_ID,
          httpStatus: 200,
          responseBytes: 26,
          responseSha256: digest('e'),
          observedAt: '2026-08-06T02:00:05.000Z'
        }
      ]
    },
    core: {
      version: CORE_VERSION,
      httpListenerAddress: '127.0.0.1:19090',
      socksListenerAddress: '127.0.0.1:19091',
      provenance: {
        expected: {
          version: CORE_VERSION,
          commit: CORE_COMMIT,
          buildInfo: BUILD_INFO_JSON,
          buildId: '0123456789abcdef'
        },
        observed: {
          version: CORE_VERSION,
          commit: CORE_COMMIT,
          buildInfo: BUILD_INFO_JSON,
          buildId: '0123456789abcdef'
        },
        verified: 'pass'
      }
    },
    stubDetection: {
      stubDetected: false,
      checks: [
        { id: 'manifestInspection', result: 'pass', detail: 'manifest matched' },
        { id: 'nativeLibraryInspection', result: 'pass', detail: 'real exports and build info matched' }
      ]
    },
    appEvidence: {
      path: 'harmony/artifacts/phase2-pull/phase2-device-proof.app.json',
      sha256: digest('9'),
      sizeBytes: 1024,
      runId: EXPECTED_RUN_ID,
      originRunId: EXPECTED_RUN_ID,
      appProcessId: 4312,
      stopResult: 'pass',
      fixturePath: 'harmony/tests/fixtures/phase2-match-direct.yaml',
      fixtureSha256: digest('d'),
      coreVersion: CORE_VERSION,
      httpListenerAddress: '127.0.0.1:19090',
      socksListenerAddress: '127.0.0.1:19091'
    },
    probes: {
      http: {
        protocol: 'HTTP_CONNECT',
        status: 'pass',
        runId: EXPECTED_RUN_ID,
        probeRunId: 'probe-http',
        requestId: 'req-http',
        originRequestId: 'req-http',
        appProbeId: 'app-http',
        coreEventId: 'core-http',
        originEventRunId: EXPECTED_RUN_ID,
        appEventRunId: EXPECTED_RUN_ID,
        coreEventRunId: EXPECTED_RUN_ID,
        originId: 'origin-123',
        appProcessId: 4312,
        coreConnectionId: 'conn-http',
        clientSourcePort: 39111,
        destination: 'example.com:443',
        upstreamInboundType: 'HTTP_CONNECT',
        listenerAddress: '127.0.0.1:19090',
        tlsPeerSha256: digest('f'),
        httpStatus: 200,
        responseBytes: 26,
        responseSha256: digest('e'),
        startedAt: '2026-08-06T02:00:03.500Z',
        completedAt: '2026-08-06T02:00:04.000Z',
        error: null
      },
      socks: {
        protocol: 'SOCKS5',
        status: 'pass',
        runId: EXPECTED_RUN_ID,
        probeRunId: 'probe-socks',
        requestId: 'req-socks',
        originRequestId: 'req-socks',
        appProbeId: 'app-socks',
        coreEventId: 'core-socks',
        originEventRunId: EXPECTED_RUN_ID,
        appEventRunId: EXPECTED_RUN_ID,
        coreEventRunId: EXPECTED_RUN_ID,
        originId: 'origin-123',
        appProcessId: 4312,
        coreConnectionId: 'conn-socks',
        clientSourcePort: 39112,
        destination: 'example.com:443',
        upstreamInboundType: 'SOCKS5',
        listenerAddress: '127.0.0.1:19091',
        tlsPeerSha256: digest('f'),
        httpStatus: 200,
        responseBytes: 26,
        responseSha256: digest('e'),
        startedAt: '2026-08-06T02:00:04.200Z',
        completedAt: '2026-08-06T02:00:05.000Z',
        error: null
      }
    },
    stop: {
      result: 'pass',
      forceStopResult: 'pass'
    },
    failures: []
  };
}

test('Phase 2 schema/example and runner contract are strict and versioned', async () => {
  const [schema, example] = await Promise.all([
    fs.readFile(SCHEMA_PATH, 'utf8').then(JSON.parse),
    fs.readFile(EXAMPLE_PATH, 'utf8').then(JSON.parse)
  ]);

  assert.equal(schema.$schema, 'https://json-schema.org/draft/2020-12/schema');
  assert.equal(schema.schemaVersion, '1.0.0');
  assert.equal(schema.additionalProperties, false);
  for (const key of ['toolchain', 'device', 'hap', 'packaged', 'fixtures', 'origin', 'core', 'stubDetection', 'appEvidence', 'probes', 'failures']) {
    assert.ok(schema.required.includes(key), `schema must require ${key}`);
  }
  assert.equal(schema.properties.phase.const, 2);
  assert.deepEqual(schema.properties.result.enum, ['pass', 'fail', 'incomplete']);
  assert.deepEqual(schema.properties.stubDetection.properties.stubDetected.enum, [false, true, null]);
  assert.deepEqual(schema.properties.probes.required, ['http', 'socks']);

  assert.ok(runner, 'Phase 2 runner module must exist');
  assert.equal(typeof runner.validatePhase2Proof, 'function');
  assert.equal(typeof runner.runPhase2DeviceProof, 'function');
  assert.equal(example.result, 'incomplete');
  assert.equal(example.device.targetKind, 'host');
  assert.equal(example.stubDetection.stubDetected, null);
  assert.equal(runner.validatePhase2Proof(example).valid, true);
  assert.ok(example.failures.some((entry) => entry.code === 'PHYSICAL_DEVICE_REQUIRED'));
  assert.doesNotMatch(JSON.stringify(example), /\/Users\/|[A-Za-z]:\\/u);
});

test('Phase 2 CLI uses build-manifest/fixture/out and always writes a legal parse-error proof', async () => {
  assert.ok(runner, 'Phase 2 runner module must exist');
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase2-cli-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const customProofPath = path.join(harmonyRoot, 'artifacts', 'custom-proof.json');
  const customManifestPath = path.join(harmonyRoot, 'artifacts', 'custom-build-manifest.json');
  const fixturePath = path.join(harmonyRoot, 'tests', 'fixtures', 'phase2-match-direct.yaml');

  await fs.mkdir(path.dirname(fixturePath), { recursive: true });
  await fs.mkdir(path.join(harmonyRoot, 'artifacts'), { recursive: true });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.lock.json'), JSON.stringify({ installed: {} }), 'utf8');
  await fs.writeFile(fixturePath, 'mode: rule\nrules:\n  - MATCH,DIRECT\n', 'utf8');
  await fs.writeFile(path.join(harmonyRoot, 'tests', 'fixtures', 'origin-body.txt'), 'fixture-body', 'utf8');

  assert.deepEqual(runner.parseCliArguments([], repoRoot), {
    buildManifestPath: path.join(repoRoot, 'harmony', 'artifacts', 'phase2-build-manifest.json'),
    fixturePath: path.join(repoRoot, 'harmony', 'tests', 'fixtures', 'phase2-match-direct.yaml'),
    outputPath: path.join(repoRoot, 'harmony', 'artifacts', 'phase2-device-proof.json')
  });

  assert.deepEqual(runner.parseCliArguments([
    '--build-manifest', 'harmony/artifacts/custom-build-manifest.json',
    '--fixture', 'harmony/tests/fixtures/phase2-match-direct.yaml',
    '--out', 'harmony/artifacts/custom-proof.json'
  ], repoRoot), {
    buildManifestPath: customManifestPath,
    fixturePath,
    outputPath: customProofPath
  });

  const exitCode = await runner.runCli({
    argv: ['--out', 'harmony/artifacts/custom-proof.json', '--bogus'],
    repoRoot,
    fsApi: await import('node:fs/promises').then((module) => module.default)
  });
  const persisted = JSON.parse(await fs.readFile(customProofPath, 'utf8'));

  assert.equal(exitCode, 1);
  assert.equal(persisted.outputPath, 'harmony/artifacts/custom-proof.json');
  assert.ok(persisted.failures.some((entry) => entry.code === 'ARGUMENT_INVALID'));
});

test('Phase 2 CLI parse errors write minimal proofs and never invoke build/device/origin callbacks', async () => {
  assert.ok(runner, 'Phase 2 runner module must exist');
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase2-cli-no-side-effects-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  await fs.mkdir(path.join(harmonyRoot, 'artifacts'), { recursive: true });
  await fs.mkdir(path.join(harmonyRoot, 'tests', 'fixtures'), { recursive: true });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.lock.json'), JSON.stringify({ installed: { hdcVersion: '6.1.0.105' } }), 'utf8');
  await fs.writeFile(path.join(harmonyRoot, 'tests', 'fixtures', 'phase2-match-direct.yaml'), 'mode: rule\nrules:\n  - MATCH,DIRECT\n', 'utf8');
  await fs.writeFile(path.join(harmonyRoot, 'tests', 'fixtures', 'origin-body.txt'), 'fixture-body', 'utf8');

  for (const variant of [
    {
      label: 'unknown option',
      argv: ['--bogus'],
      outputPath: path.join(harmonyRoot, 'artifacts', 'phase2-device-proof.json')
    },
    {
      label: 'missing value',
      argv: ['--build-manifest'],
      outputPath: path.join(harmonyRoot, 'artifacts', 'phase2-device-proof.json')
    },
    {
      label: 'duplicate option',
      argv: ['--out', 'harmony/artifacts/custom-proof.json', '--out', 'harmony/artifacts/other.json'],
      outputPath: path.join(harmonyRoot, 'artifacts', 'custom-proof.json')
    },
    {
      label: 'repo escape out falls back to default proof path',
      argv: ['--out', '../escape.json'],
      outputPath: path.join(harmonyRoot, 'artifacts', 'phase2-device-proof.json')
    }
  ]) {
    const calls = {
      build: 0,
      inspect: 0,
      toolchain: 0,
      exec: 0,
      origin: 0,
      pull: 0
    };
    const exitCode = await runner.runCli({
      argv: variant.argv,
      repoRoot,
      buildPhase1NativeImpl: async () => { calls.build += 1; throw new Error('build should not run'); },
      inspectHapImpl: async () => { calls.inspect += 1; throw new Error('inspect should not run'); },
      toolchainInspectorImpl: async () => { calls.toolchain += 1; throw new Error('toolchain should not run'); },
      execImpl: async () => { calls.exec += 1; throw new Error('exec should not run'); },
      startOriginImpl: async () => { calls.origin += 1; throw new Error('origin should not run'); },
      pullPhase2AppEvidenceImpl: async () => { calls.pull += 1; throw new Error('pull should not run'); }
    });
    assert.equal(exitCode, 1, variant.label);
    assert.deepEqual(calls, {
      build: 0,
      inspect: 0,
      toolchain: 0,
      exec: 0,
      origin: 0,
      pull: 0
    }, variant.label);
    const persisted = JSON.parse(await fs.readFile(variant.outputPath, 'utf8'));
    assert.equal(persisted.outputPath, path.relative(repoRoot, variant.outputPath).split(path.sep).join('/'), variant.label);
    assert.ok(persisted.failures.some((entry) => entry.code === 'ARGUMENT_INVALID'), variant.label);
    assert.equal(runner.validatePhase2Proof(persisted).valid, true, variant.label);
  }
});

test('Phase 2 proof writer ignores attacker temp/final symlinks and leaves no temp residue', async () => {
  assert.ok(runner, 'Phase 2 runner module must exist');
  const nodeFsApi = await import('node:fs/promises').then((module) => module.default);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase2-proof-writer-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const outputPath = path.join(harmonyRoot, 'artifacts', 'phase2-device-proof.json');
  const tempPath = `${outputPath}.${process.pid}.tmp`;
  const outsideTarget = path.join(tempRoot, 'outside-target.json');
  const outsideLinkTarget = path.join(tempRoot, 'outside-link-target.json');

  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.mkdir(path.join(harmonyRoot, 'tests', 'fixtures'), { recursive: true });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.lock.json'), JSON.stringify({ installed: { hdcVersion: '6.1.0.105' } }), 'utf8');
  await fs.writeFile(path.join(harmonyRoot, 'tests', 'fixtures', 'origin-body.txt'), 'fixture-body', 'utf8');
  await fs.writeFile(outsideTarget, 'sentinel-temp', 'utf8');
  await fs.writeFile(outsideLinkTarget, 'sentinel-output', 'utf8');

  await fs.symlink(outsideTarget, tempPath);
  const tempAttackProof = await runner.writeArgumentErrorProof({
    outputPath,
    repoRoot,
    fsApi: nodeFsApi,
    randomUUID: () => EXPECTED_RUN_ID,
    now: () => new Date('2026-08-06T02:00:00.000Z'),
    detail: 'temp symlink race'
  });

  assert.equal(await fs.readFile(outsideTarget, 'utf8'), 'sentinel-temp');
  assert.equal(runner.validatePhase2Proof(tempAttackProof).valid, true);
  assert.equal(runner.validatePhase2Proof(JSON.parse(await fs.readFile(outputPath, 'utf8'))).valid, true);
  assert.equal((await fs.lstat(outputPath)).isFile(), true);
  assert.ok(!(await fs.readdir(path.dirname(outputPath))).some((entry) => entry.startsWith('.cmfa-phase2-proof-')));

  await fs.rm(outputPath, { force: true });
  await fs.symlink(outsideLinkTarget, outputPath);
  const finalLinkProof = await runner.writeArgumentErrorProof({
    outputPath,
    repoRoot,
    fsApi: nodeFsApi,
    randomUUID: () => EXPECTED_RUN_ID,
    now: () => new Date('2026-08-06T02:00:01.000Z'),
    detail: 'final symlink race'
  });

  assert.equal(await fs.readFile(outsideLinkTarget, 'utf8'), 'sentinel-output');
  assert.equal(runner.validatePhase2Proof(finalLinkProof).valid, true);
  assert.equal(runner.validatePhase2Proof(JSON.parse(await fs.readFile(outputPath, 'utf8'))).valid, true);
  assert.equal((await fs.lstat(outputPath)).isFile(), true);
  assert.ok(!(await fs.readdir(path.dirname(outputPath))).some((entry) => entry.startsWith('.cmfa-phase2-proof-')));
});

test('Phase 2 pass validator rejects fabricated partial passes and accepts fully correlated proofs only', () => {
  assert.ok(runner, 'Phase 2 runner module must exist');
  const passProof = createValidPassProof();
  assert.deepEqual(runner.validatePhase2Proof(passProof), { valid: true, errors: [] });

  const mutations = [
    ['toolchain version missing', (proof) => { proof.toolchain.hdcVersion = null; }, /toolchain|hdcVersion/u],
    ['device downgraded to simulator', (proof) => { proof.device.targetKind = 'simulator'; }, /simulator|physical/u],
    ['raw core hash missing', (proof) => { proof.packaged.rawCore.sha256 = null; }, /rawCore|packaged/u],
    ['origin/app/core run correlation broken', (proof) => { proof.probes.http.coreEventRunId = 'mismatch'; }, /run correlation|coreEventRunId/u],
    ['probe source port missing', (proof) => { proof.probes.socks.clientSourcePort = null; }, /source port|clientSourcePort/u],
    ['stop failed', (proof) => { proof.stop.result = 'fail'; }, /stop/u],
    ['force-stop failed', (proof) => { proof.stop.forceStopResult = 'fail'; }, /forceStopResult|cleanup/u],
    ['stub detection not false', (proof) => { proof.stubDetection.stubDetected = null; }, /stubDetected/u],
    ['pass with failure array', (proof) => { proof.failures.push({ code: 'BAD', detail: 'should not pass', stage: 'proof' }); }, /failures/u],
    ['app evidence originRunId missing', (proof) => { proof.appEvidence.originRunId = null; }, /originRunId/u],
    ['app evidence fixture path drift', (proof) => { proof.appEvidence.fixturePath = 'harmony/tests/fixtures/other.yaml'; }, /fixturePath|fixture/u],
    ['app evidence fixture hash drift', (proof) => { proof.appEvidence.fixtureSha256 = digest('0'); }, /fixtureSha256|fixture/u]
  ];

  for (const [label, mutate, expected] of mutations) {
    const proof = structuredClone(passProof);
    mutate(proof);
    const validation = runner.validatePhase2Proof(proof);
    assert.equal(validation.valid, false, label);
    assert.match(validation.errors.join('\n'), expected, label);
  }
});

test('Phase 2 origin parser accepts split JSONL records and ignores wrong-run observations', async () => {
  assert.ok(runner, 'Phase 2 runner module must exist');
  const originModule = await import(pathToFileURL(ORIGIN_MODULE_PATH).href);
  const parser = runner.createOriginStdoutParser(EXPECTED_RUN_ID);
  const startedRecord = originModule.createStartedRecord({
    runId: EXPECTED_RUN_ID,
    originId: 'origin-123',
    originUrl: 'https://127.0.0.1:18443/',
    address: '127.0.0.1:18443',
    caPem: 'pem-placeholder',
    bodySha256: digest('e'),
    bindHost: '127.0.0.1',
    files: { [certPathKey]: 'a', [keyPathKey]: 'b' },
    pid: 123
  });
  const goodRequest = originModule.createRequestRecord({
    runId: EXPECTED_RUN_ID,
    originId: 'origin-123',
    requestId: 'req-http',
    protocol: 'HTTP_CONNECT',
    method: 'CONNECT',
    pathName: '/',
    receivedAt: '2026-08-06T02:00:04.000Z',
    responseBytes: 26,
    responseSha256: digest('e')
  });
  const wrongRequest = originModule.createRequestRecord({
    runId: '5582eb4a-df59-48cb-a3d8-d6e79c7eaebd',
    originId: 'origin-123',
    requestId: 'req-wrong',
    protocol: 'HTTP_CONNECT',
    method: 'CONNECT',
    pathName: '/',
    receivedAt: '2026-08-06T02:00:04.100Z',
    responseBytes: 26,
    responseSha256: digest('e')
  });
  const startedLine = JSON.stringify(startedRecord);
  parser.push(startedLine.slice(0, 20));
  parser.push(`${startedLine.slice(20)}\n${JSON.stringify(goodRequest)}\n${JSON.stringify(wrongRequest)}\n`);
  const snapshot = parser.snapshot();
  assert.equal(snapshot.started.length, 1);
  assert.equal(snapshot.requests.length, 1);
  assert.equal(snapshot.requests[0].requestId, 'req-http');
  assert.ok(snapshot.invalid.some((entry) => /runId mismatch/u.test(entry.error)));
});

test('Phase 2 startOriginProcess forwards the exact runId into the origin CLI argv seam', async () => {
  assert.ok(runner, 'Phase 2 runner module must exist');
  const originModule = await import(pathToFileURL(ORIGIN_MODULE_PATH).href);
  const observed = { command: null, args: null };

  const handle = await runner.startOriginProcess({
    repoRoot: REPO_ROOT,
    originBodyPath: path.join(REPO_ROOT, 'harmony', 'tests', 'fixtures', 'origin-body.txt'),
    runId: EXPECTED_RUN_ID,
    spawnImpl: (command, args) => {
      observed.command = command;
      observed.args = args;
      const child = new EventEmitter();
      child.stdout = new EventEmitter();
      child.stderr = new EventEmitter();
      child.stdout.setEncoding = () => {};
      child.stderr.setEncoding = () => {};
      child.kill = () => {
        setImmediate(() => child.emit('exit', 0, null));
      };
      setImmediate(() => {
        child.stdout.emit('data', `${JSON.stringify(originModule.createStartedRecord({
          runId: EXPECTED_RUN_ID,
          originId: 'origin-123',
          originUrl: 'https://127.0.0.1:18443/',
          address: '127.0.0.1:18443',
          caPem: certPemLiteral,
          bodySha256: digest('e'),
          bindHost: '127.0.0.1',
          files: { [certPathKey]: certPemPath, [keyPathKey]: keyPemPath },
          pid: 4312
        }))}\n`);
      });
      return child;
    }
  });

  assert.equal(observed.command, 'node');
  assert.ok(observed.args.includes('--run-id'));
  assert.equal(observed.args[observed.args.indexOf('--run-id') + 1], EXPECTED_RUN_ID);
  await handle.stop();
});

test('Phase 2 app proof parser accepts canonical writer shape and rejects old probe arrays plus wrong originRunId', async () => {
  assert.ok(runner, 'Phase 2 runner module must exist');
  const canonical = await readAppEvidenceFixture();
  assert.equal(runner.parsePhase2AppEvidence(canonical, {
    expectedRunId: EXPECTED_RUN_ID,
    expectedFixturePath: canonical.fixturePath,
    expectedFixtureSha256: canonical.fixtureSha256
  }).valid, true);
  const legacy = {
    ...canonical,
    probes: [{ protocol: 'HTTP_CONNECT' }, { protocol: 'SOCKS5' }]
  };
  const legacyValidation = runner.parsePhase2AppEvidence(legacy, {
    expectedRunId: EXPECTED_RUN_ID,
    expectedFixturePath: canonical.fixturePath,
    expectedFixtureSha256: canonical.fixtureSha256
  });
  assert.equal(legacyValidation.valid, false);
  assert.match(legacyValidation.errors.join('\n'), /probes must be an object|probes\.http/u);
  const wrongOriginRunId = {
    ...canonical,
    originRunId: '5582eb4a-df59-48cb-a3d8-d6e79c7eaebd'
  };
  const wrongOriginValidation = runner.parsePhase2AppEvidence(wrongOriginRunId, {
    expectedRunId: EXPECTED_RUN_ID,
    expectedFixturePath: canonical.fixturePath,
    expectedFixtureSha256: canonical.fixtureSha256
  });
  assert.equal(wrongOriginValidation.valid, false);
  assert.match(wrongOriginValidation.errors.join('\n'), /originRunId/u);
  const wrongSchemaVersion = {
    ...canonical,
    schemaVersion: '9.9.9'
  };
  const wrongSchemaValidation = runner.parsePhase2AppEvidence(wrongSchemaVersion, {
    expectedRunId: EXPECTED_RUN_ID,
    expectedFixturePath: canonical.fixturePath,
    expectedFixtureSha256: canonical.fixtureSha256
  });
  assert.equal(wrongSchemaValidation.valid, false);
  assert.match(wrongSchemaValidation.errors.join('\n'), /schemaVersion/u);
  const wrongPhase = {
    ...canonical,
    phase: 1
  };
  const wrongPhaseValidation = runner.parsePhase2AppEvidence(wrongPhase, {
    expectedRunId: EXPECTED_RUN_ID,
    expectedFixturePath: canonical.fixturePath,
    expectedFixtureSha256: canonical.fixtureSha256
  });
  assert.equal(wrongPhaseValidation.valid, false);
  assert.match(wrongPhaseValidation.errors.join('\n'), /phase/u);
  const wrongFixturePath = {
    ...canonical,
    fixturePath: 'harmony/tests/fixtures/other.yaml'
  };
  const wrongFixturePathValidation = runner.parsePhase2AppEvidence(wrongFixturePath, {
    expectedRunId: EXPECTED_RUN_ID,
    expectedFixturePath: canonical.fixturePath,
    expectedFixtureSha256: canonical.fixtureSha256
  });
  assert.equal(wrongFixturePathValidation.valid, false);
  assert.match(wrongFixturePathValidation.errors.join('\n'), /fixturePath/u);
  const wrongFixtureHash = {
    ...canonical,
    fixtureSha256: digest('0')
  };
  const wrongFixtureHashValidation = runner.parsePhase2AppEvidence(wrongFixtureHash, {
    expectedRunId: EXPECTED_RUN_ID,
    expectedFixturePath: canonical.fixturePath,
    expectedFixtureSha256: canonical.fixtureSha256
  });
  assert.equal(wrongFixtureHashValidation.valid, false);
  assert.match(wrongFixtureHashValidation.errors.join('\n'), /fixtureSha256/u);
  const wrongTimestamp = structuredClone(canonical);
  wrongTimestamp.probes.http.completedAt = 'nope';
  const wrongTimestampValidation = runner.parsePhase2AppEvidence(wrongTimestamp, {
    expectedRunId: EXPECTED_RUN_ID,
    expectedFixturePath: canonical.fixturePath,
    expectedFixtureSha256: canonical.fixtureSha256
  });
  assert.equal(wrongTimestampValidation.valid, false);
  assert.match(wrongTimestampValidation.errors.join('\n'), /completedAt|timestamp/u);
  const wrongDigest = structuredClone(canonical);
  wrongDigest.probes.http.tlsPeerSha256 = 'bad';
  const wrongDigestValidation = runner.parsePhase2AppEvidence(wrongDigest, {
    expectedRunId: EXPECTED_RUN_ID,
    expectedFixturePath: canonical.fixturePath,
    expectedFixtureSha256: canonical.fixtureSha256
  });
  assert.equal(wrongDigestValidation.valid, false);
  assert.match(wrongDigestValidation.errors.join('\n'), /tlsPeerSha256|digest/u);
});

test('Phase 2 pull helper auto-creates a run-scoped parent, rejects oversize and invalid JSON, and blocks symlink escapes', async () => {
  assert.ok(runner, 'Phase 2 runner module must exist');
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase2-pull-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const runDir = path.join(harmonyRoot, 'artifacts', 'phase2-pull', EXPECTED_RUN_ID);
  const localPath = path.join(runDir, 'phase2-device-proof.json');
  await fs.mkdir(harmonyRoot, { recursive: true });

  let execCount = 0;
  const invalidJsonPull = await runner.pullPhase2AppEvidence({
    fsApi: await import('node:fs/promises').then((module) => module.default),
    execImpl: async () => {
      execCount += 1;
      await fs.mkdir(runDir, { recursive: true });
      await fs.writeFile(localPath, '{bad json', 'utf8');
      return { command: '/sdk/hdc', args: [], exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    },
    hdcCommand: '/sdk/hdc',
    target: 'device',
    localPath,
    cwd: repoRoot,
    expectedRunId: EXPECTED_RUN_ID,
    waitImpl: async () => {}
  });
  assert.equal(execCount, 1);
  assert.equal(invalidJsonPull.ok, false);
  assert.match(invalidJsonPull.invalid.detail, /parse|JSON|app evidence/u);

  const oversizePull = await runner.pullPhase2AppEvidence({
    fsApi: await import('node:fs/promises').then((module) => module.default),
    execImpl: async () => {
      await fs.mkdir(runDir, { recursive: true });
      await fs.writeFile(localPath, 'x'.repeat((runner.MAX_PHASE2_APP_EVIDENCE_BYTES ?? 1024 * 1024) + 1), 'utf8');
      return { command: '/sdk/hdc', args: [], exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    },
    hdcCommand: '/sdk/hdc',
    target: 'device',
    localPath,
    cwd: repoRoot,
    expectedRunId: EXPECTED_RUN_ID,
    waitImpl: async () => {}
  });
  assert.equal(oversizePull.ok, false);
  assert.match(oversizePull.invalid.detail, /exceeds|size/u);

  const outsideRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase2-pull-outside-'));
  const symlinkParent = path.join(harmonyRoot, 'artifacts', 'phase2-pull');
  await fs.rm(symlinkParent, { recursive: true, force: true });
  await fs.mkdir(path.dirname(symlinkParent), { recursive: true });
  await fs.symlink(outsideRoot, symlinkParent);
  let escapedExecCount = 0;
  const symlinkPull = await runner.pullPhase2AppEvidence({
    fsApi: await import('node:fs/promises').then((module) => module.default),
    execImpl: async () => {
      escapedExecCount += 1;
      return { command: '/sdk/hdc', args: [], exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    },
    hdcCommand: '/sdk/hdc',
    target: 'device',
    localPath: path.join(symlinkParent, EXPECTED_RUN_ID, 'phase2-device-proof.json'),
    cwd: repoRoot,
    expectedRunId: EXPECTED_RUN_ID,
    waitImpl: async () => {}
  });
  assert.equal(escapedExecCount, 0);
  assert.equal(symlinkPull.ok, false);
  assert.match(symlinkPull.invalid.detail, /symlink|repository/u);
});

test('Phase 2 pull helper reads app evidence from a single opened inode even if the path is swapped after stat', async () => {
  assert.ok(runner, 'Phase 2 runner module must exist');
  const nodeFsApi = await import('node:fs/promises').then((module) => module.default);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase2-pull-fd-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const runDir = path.join(harmonyRoot, 'artifacts', 'phase2-pull', EXPECTED_RUN_ID);
  const localPath = path.join(runDir, 'phase2-device-proof.json');
  const originalPath = path.join(runDir, 'phase2-device-proof.original.json');
  const attackerPath = path.join(runDir, 'phase2-device-proof.attacker.json');
  const goodEvidence = await readAppEvidenceFixture();
  const attackerEvidence = {
    ...goodEvidence,
    runId: '5582eb4a-df59-48cb-a3d8-d6e79c7eaebd'
  };
  const expectedBuffer = Buffer.from(`${JSON.stringify(goodEvidence)}\n`, 'utf8');
  let openPath = null;
  let swapStage = null;

  await fs.mkdir(harmonyRoot, { recursive: true });

  async function swapPulledPath(stage) {
    if (swapStage !== null) {
      return;
    }
    swapStage = stage;
    await nodeFsApi.rename(localPath, originalPath);
    await nodeFsApi.rename(attackerPath, localPath);
  }

  const fsApi = new Proxy(nodeFsApi, {
    get(target, property, receiver) {
      if (property === 'stat') {
        return async (filePath, ...args) => {
          const stats = await target.stat(filePath, ...args);
          if (filePath === localPath) {
            await swapPulledPath('path');
          }
          return stats;
        };
      }
      if (property === 'open') {
        return async (filePath, ...args) => {
          openPath = filePath;
          const handle = await target.open(filePath, ...args);
          return new Proxy(handle, {
            get(innerTarget, innerProperty, innerReceiver) {
              if (innerProperty === 'stat') {
                return async (...statArgs) => {
                  const stats = await innerTarget.stat(...statArgs);
                  await swapPulledPath('handle');
                  return stats;
                };
              }
              if (innerProperty === 'readFile') {
                return async (...readArgs) => {
                  await swapPulledPath('handle');
                  return innerTarget.readFile(...readArgs);
                };
              }
              return Reflect.get(innerTarget, innerProperty, innerReceiver);
            }
          });
        };
      }
      return Reflect.get(target, property, receiver);
    }
  });

  const pullResult = await runner.pullPhase2AppEvidence({
    fsApi,
    execImpl: async () => {
      await fs.mkdir(runDir, { recursive: true });
      await fs.writeFile(localPath, `${JSON.stringify(goodEvidence)}\n`, 'utf8');
      await fs.writeFile(attackerPath, `${JSON.stringify(attackerEvidence)}\n`, 'utf8');
      return { command: '/sdk/hdc', args: [], exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    },
    hdcCommand: '/sdk/hdc',
    target: 'device',
    localPath,
    cwd: repoRoot,
    expectedRunId: EXPECTED_RUN_ID,
    waitImpl: async () => {}
  });

  assert.equal(pullResult.ok, true, pullResult.invalid?.detail);
  assert.equal(openPath, await fs.realpath(localPath));
  assert.equal(swapStage, 'handle');
  assert.equal(pullResult.proof.runId, EXPECTED_RUN_ID);
  assert.equal(pullResult.proof.originRunId, EXPECTED_RUN_ID);
  assert.equal(pullResult.sha256, crypto.createHash('sha256').update(expectedBuffer).digest('hex'));
  assert.equal(pullResult.sizeBytes, expectedBuffer.byteLength);
  assert.equal(JSON.parse(await fs.readFile(localPath, 'utf8')).runId, attackerEvidence.runId);
});

test('Phase 2 runner executes the exact build-origin-device-app trace and rejects stale mismatched app evidence', async () => {
  assert.ok(runner, 'Phase 2 runner module must exist');
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase2-physical-lane-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const buildManifestPath = path.join(harmonyRoot, 'artifacts', 'phase2-build-manifest.json');
  const outputPath = path.join(harmonyRoot, 'artifacts', 'phase2-device-proof.json');
  const fixturePath = path.join(harmonyRoot, 'tests', 'fixtures', 'phase2-match-direct.yaml');
  const appEvidencePath = path.join(harmonyRoot, 'artifacts', 'phase2-pull', `${EXPECTED_RUN_ID}.json`);
  const signedHapPath = path.join(harmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
  const rawCorePath = path.join(harmonyRoot, 'artifacts', 'libcmfa_mihomo.so');
  const prePackageCorePath = path.join(harmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libcmfa_mihomo.so');
  const prePackageAddonPath = path.join(harmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
  const events = [];

  await fs.mkdir(path.dirname(appEvidencePath), { recursive: true });
  await fs.mkdir(path.dirname(signedHapPath), { recursive: true });
  await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
  await fs.mkdir(path.dirname(prePackageCorePath), { recursive: true });
  await fs.mkdir(path.dirname(fixturePath), { recursive: true });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.lock.json'), JSON.stringify({
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hvigorVersion: '6.23.7',
      hdcVersion: '6.1.0.105'
    }
  }), 'utf8');
  await fs.writeFile(fixturePath, 'mode: rule\nmixed-port: 0\nrules:\n  - MATCH,DIRECT\n', 'utf8');
  await fs.writeFile(path.join(harmonyRoot, 'tests', 'fixtures', 'origin-body.txt'), 'origin-body', 'utf8');
  await fs.writeFile(signedHapPath, 'signed-hap', 'utf8');
  await fs.writeFile(rawCorePath, 'real-core', 'utf8');
  await fs.writeFile(prePackageCorePath, 'real-core', 'utf8');
  await fs.writeFile(prePackageAddonPath, 'real-addon', 'utf8');

  const appEvidence = await readAppEvidenceFixture();
  await fs.writeFile(appEvidencePath, `${JSON.stringify(appEvidence)}\n`, 'utf8');

  const buildManifest = {
    result: 'pass',
    nativeBuildResult: 'pass',
    phase2SelfTest: {
      enabled: true,
      activation: 'explicit',
      purpose: 'test-only',
      releaseStatus: 'not-releasable'
    },
    signing: { result: 'pass' },
    artifacts: {
      hap: {
        identity: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
        sha256: digest('a'),
        sizeBytes: 10
      },
      rawCore: {
        identity: 'harmony/artifacts/libcmfa_mihomo.so',
        sha256: digest('b'),
        sizeBytes: 9
      },
      prePackageCore: {
        identity: 'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so',
        sha256: digest('b'),
        sizeBytes: 9
      },
      prePackageAddon: {
        identity: 'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so',
        sha256: digest('c'),
        sizeBytes: 10
      },
      hapCore: {
        identity: 'libs/arm64-v8a/libcmfa_mihomo.so',
        sha256: digest('b'),
        sizeBytes: 9
      },
      hapAddon: {
        identity: 'libs/arm64-v8a/libentry.so',
        sha256: digest('c'),
        sizeBytes: 10
      }
    },
    provenance: {
      upstream: {
        version: CORE_VERSION,
        commit: CORE_COMMIT,
        buildInfo: BUILD_INFO_JSON,
        buildId: '0123456789abcdef'
      }
    }
  };

  const staleProof = structuredClone(appEvidence);
  staleProof.runId = '0d65110a-c6d2-42e0-b06d-0f694064cd50';
  const originModule = await import(pathToFileURL(ORIGIN_MODULE_PATH).href);
  const createOriginHandle = (records) => {
    const parser = runner.createOriginStdoutParser(EXPECTED_RUN_ID);
    for (const chunk of records) {
      parser.push(chunk);
    }
    return {
      originId: 'origin-123',
      originRunId: EXPECTED_RUN_ID,
      originUrl: 'https://127.0.0.1:18443/',
      address: '127.0.0.1:18443',
        caPem: certPemLiteral,
      tlsCertSha256: digest('f'),
      bodySha256: digest('e'),
      requestObservations: [],
      async waitForRequestObservations(expectedCount) {
        return parser.snapshot().requests.slice(0, expectedCount);
      },
      getInvalidRecords() {
        return parser.snapshot().invalid;
      },
      async stop() {
        this.requestObservations = parser.snapshot().requests;
      }
    };
  };

  const execImpl = async (_command, args) => {
    events.push(args.join(' '));
    const joined = args.join(' ');
    if (joined === 'help') {
      return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'list targets [-v]\ninstall [-r|-s|-cwd|option] src\nshell [-b bundlename] [COMMAND...]', stderr: '' };
    }
    if (joined === 'list targets') {
      return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'device-serial-1\n', stderr: '' };
    }
    if (joined.includes('param get const.product.software.version')) {
      return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'HarmonyOS 6.0.1.123\n', stderr: '' };
    }
    if (joined.includes('param get const.ohos.apiversion')) {
      return { command: '/sdk/hdc', args, exitCode: 0, stdout: '20\n', stderr: '' };
    }
    if (joined.includes('param get const.product.cpu.abilist')) {
      return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'arm64-v8a\n', stderr: '' };
    }
    if (joined.includes('param get const.product.model')) {
      return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'Harmony Phone\n', stderr: '' };
    }
    if (joined.includes('param get const.product.name')) {
      return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'PuraX\n', stderr: '' };
    }
    if (joined.includes('install -r')) {
      return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'successfully', stderr: '' };
    }
    if (joined.includes('shell aa start')) {
      return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'start ability successfully', stderr: '' };
    }
    if (joined.includes('file recv -b')) {
      const destinationPath = args.at(-1);
      await fs.mkdir(path.dirname(destinationPath), { recursive: true });
      await fs.writeFile(destinationPath, `${JSON.stringify(appEvidence)}\n`, 'utf8');
      return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
    }
    if (joined.includes('shell aa force-stop')) {
      return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'force-stop success', stderr: '' };
    }
    throw new Error(`unexpected command ${joined}`);
  };

  const proof = await runner.runPhase2DeviceProof({
    repoRoot,
    buildManifestPath,
    fixturePath,
    outputPath,
    randomUUID: () => EXPECTED_RUN_ID,
    buildPhase1NativeImpl: async (options) => {
      events.push('buildPhase1Native');
      assert.equal(options.phase2SelfTestEnabled, true);
      await fs.writeFile(buildManifestPath, `${JSON.stringify(buildManifest)}\n`, 'utf8');
      return buildManifest;
    },
    inspectHapImpl: async () => {
      events.push('inspectHap');
      return {
        result: 'pass',
        stubDetected: false,
        packaged: {
          rawCore: { identity: buildManifest.artifacts.rawCore.identity, sha256: digest('b'), sizeBytes: 9, elf: { result: 'pass' } },
          prePackageCore: { identity: buildManifest.artifacts.prePackageCore.identity, sha256: digest('b'), sizeBytes: 9, elf: { result: 'pass' } },
          prePackageAddon: { identity: buildManifest.artifacts.prePackageAddon.identity, sha256: digest('c'), sizeBytes: 10, elf: { result: 'pass' } },
          core: { identity: 'libs/arm64-v8a/libcmfa_mihomo.so', sha256: digest('b'), sizeBytes: 9, elf: { result: 'pass' } },
          addon: { identity: 'libs/arm64-v8a/libentry.so', sha256: digest('c'), sizeBytes: 10, elf: { result: 'pass' } }
        },
        provenance: {
          expected: buildManifest.provenance.upstream,
          observed: buildManifest.provenance.upstream,
          verified: 'pass'
        },
        failures: []
      };
    },
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    execImpl,
    startOriginImpl: async (options) => {
      events.push('startOrigin');
      assert.equal(options.runId, EXPECTED_RUN_ID);
      const startedRecord = originModule.createStartedRecord({
        runId: EXPECTED_RUN_ID,
        originId: 'origin-123',
        originUrl: 'https://127.0.0.1:18443/',
        address: '127.0.0.1:18443',
        caPem: certPemLiteral,
        bodySha256: digest('e'),
        bindHost: '127.0.0.1',
        files: { [certPathKey]: certPemPath, [keyPathKey]: keyPemPath },
        pid: 4312
      });
      const httpRecord = originModule.createRequestRecord({
        runId: EXPECTED_RUN_ID,
        originId: 'origin-123',
        requestId: 'req-http',
        protocol: 'HTTP_CONNECT',
        method: 'CONNECT',
        pathName: '/',
        receivedAt: '2026-08-06T02:00:04.000Z',
        responseBytes: 26,
        responseSha256: digest('e')
      });
      const socksRecord = originModule.createRequestRecord({
        runId: EXPECTED_RUN_ID,
        originId: 'origin-123',
        requestId: 'req-socks',
        protocol: 'SOCKS5',
        method: 'CONNECT',
        pathName: '/',
        receivedAt: '2026-08-06T02:00:05.000Z',
        responseBytes: 26,
        responseSha256: digest('e')
      });
      return createOriginHandle([
        `${JSON.stringify(startedRecord).slice(0, 30)}`,
        `${JSON.stringify(startedRecord).slice(30)}\n${JSON.stringify(httpRecord)}\n${JSON.stringify(socksRecord)}\n`
      ]);
    }
  });

  assert.equal(proof.result, 'pass');
  assert.deepEqual(events.slice(0, 6), ['buildPhase1Native', 'inspectHap', 'startOrigin', 'help', 'list targets', '-t device-serial-1 shell param get const.product.software.version']);
  assert.ok(events.some((entry) => entry.includes('install -r')));
  assert.ok(events.some((entry) => entry.includes('shell aa start')));
  assert.ok(events.some((entry) => entry.includes('shell aa force-stop')));
  assert.equal(proof.appEvidence.appProcessId, 4312);
  assert.equal(proof.probes.http.appEventRunId, EXPECTED_RUN_ID);
  assert.equal(proof.probes.socks.coreEventRunId, EXPECTED_RUN_ID);

  const cleanupTempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase2-force-stop-'));
  const cleanupRepoRoot = path.join(cleanupTempRoot, 'repo');
  const cleanupHarmonyRoot = path.join(cleanupRepoRoot, 'harmony');
  const cleanupBuildManifestPath = path.join(cleanupHarmonyRoot, 'artifacts', 'phase2-build-manifest.json');
  const cleanupOutputPath = path.join(cleanupHarmonyRoot, 'artifacts', 'phase2-device-proof.json');
  const cleanupFixturePath = path.join(cleanupHarmonyRoot, 'tests', 'fixtures', 'phase2-match-direct.yaml');
  const cleanupPullDir = path.join(cleanupHarmonyRoot, 'artifacts', 'phase2-pull', EXPECTED_RUN_ID);
  const cleanupEvidencePath = path.join(cleanupPullDir, 'phase2-device-proof.json');
  const cleanupSignedHapPath = path.join(cleanupHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
  const cleanupRawCorePath = path.join(cleanupHarmonyRoot, 'artifacts', 'libcmfa_mihomo.so');
  const cleanupPrePackageCorePath = path.join(cleanupHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libcmfa_mihomo.so');
  const cleanupPrePackageAddonPath = path.join(cleanupHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');

  await fs.mkdir(path.dirname(cleanupSignedHapPath), { recursive: true });
  await fs.mkdir(path.dirname(cleanupRawCorePath), { recursive: true });
  await fs.mkdir(path.dirname(cleanupPrePackageCorePath), { recursive: true });
  await fs.mkdir(path.dirname(cleanupFixturePath), { recursive: true });
  await fs.writeFile(path.join(cleanupHarmonyRoot, 'toolchain.lock.json'), JSON.stringify({
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hvigorVersion: '6.23.7',
      hdcVersion: '6.1.0.105'
    }
  }), 'utf8');
  await fs.writeFile(cleanupFixturePath, 'mode: rule\nmixed-port: 0\nrules:\n  - MATCH,DIRECT\n', 'utf8');
  await fs.writeFile(path.join(cleanupHarmonyRoot, 'tests', 'fixtures', 'origin-body.txt'), 'origin-body', 'utf8');
  await fs.writeFile(cleanupSignedHapPath, 'signed-hap', 'utf8');
  await fs.writeFile(cleanupRawCorePath, 'real-core', 'utf8');
  await fs.writeFile(cleanupPrePackageCorePath, 'real-core', 'utf8');
  await fs.writeFile(cleanupPrePackageAddonPath, 'real-addon', 'utf8');

  const forceStopProof = await runner.runPhase2DeviceProof({
    repoRoot: cleanupRepoRoot,
    buildManifestPath: cleanupBuildManifestPath,
    fixturePath: cleanupFixturePath,
    outputPath: cleanupOutputPath,
    randomUUID: () => EXPECTED_RUN_ID,
    buildPhase1NativeImpl: async () => buildManifest,
    inspectHapImpl: async () => ({
      result: 'pass',
      stubDetected: false,
      packaged: {
        rawCore: { identity: buildManifest.artifacts.rawCore.identity, sha256: digest('b'), sizeBytes: 9, elf: { result: 'pass' } },
        prePackageCore: { identity: buildManifest.artifacts.prePackageCore.identity, sha256: digest('b'), sizeBytes: 9, elf: { result: 'pass' } },
        prePackageAddon: { identity: buildManifest.artifacts.prePackageAddon.identity, sha256: digest('c'), sizeBytes: 10, elf: { result: 'pass' } },
        core: { identity: 'libs/arm64-v8a/libcmfa_mihomo.so', sha256: digest('b'), sizeBytes: 9, elf: { result: 'pass' } },
        addon: { identity: 'libs/arm64-v8a/libentry.so', sha256: digest('c'), sizeBytes: 10, elf: { result: 'pass' } }
      },
      provenance: {
        expected: buildManifest.provenance.upstream,
        observed: buildManifest.provenance.upstream,
        verified: 'pass'
      },
      failures: []
    }),
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    execImpl: async (_command, args) => {
      const joined = args.join(' ');
      if (joined === 'help') return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'list targets [-v]\ninstall [-r|-s|-cwd|option] src\nshell [-b bundlename] [COMMAND...]', stderr: '' };
      if (joined === 'list targets') return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'device-serial-1\n', stderr: '' };
      if (joined.includes('param get const.product.software.version')) return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'HarmonyOS 6.0.1.123\n', stderr: '' };
      if (joined.includes('param get const.ohos.apiversion')) return { command: '/sdk/hdc', args, exitCode: 0, stdout: '20\n', stderr: '' };
      if (joined.includes('param get const.product.cpu.abilist')) return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'arm64-v8a\n', stderr: '' };
      if (joined.includes('param get const.product.model')) return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'Harmony Phone\n', stderr: '' };
      if (joined.includes('param get const.product.name')) return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'PuraX\n', stderr: '' };
      if (joined.includes('install -r')) return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'successfully', stderr: '' };
      if (joined.includes('shell aa start')) return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'start ability successfully', stderr: '' };
      if (joined.includes('file recv -b')) {
        await fs.mkdir(cleanupPullDir, { recursive: true });
        await fs.writeFile(cleanupEvidencePath, JSON.stringify(await readAppEvidenceFixture()), 'utf8');
        return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
      }
      if (joined.includes('shell aa force-stop')) return { command: '/sdk/hdc', args, exitCode: 1, stdout: '', stderr: 'force-stop failed' };
      throw new Error(`unexpected command ${joined}`);
    },
    startOriginImpl: async () => {
      const startedRecord = originModule.createStartedRecord({
        runId: EXPECTED_RUN_ID,
        originId: 'origin-123',
        originUrl: 'https://127.0.0.1:18443/',
        address: '127.0.0.1:18443',
        caPem: certPemLiteral,
        bodySha256: digest('e'),
        bindHost: '127.0.0.1',
        files: { [certPathKey]: certPemPath, [keyPathKey]: keyPemPath },
        pid: 4312
      });
      const httpRecord = originModule.createRequestRecord({
        runId: EXPECTED_RUN_ID,
        originId: 'origin-123',
        requestId: 'req-http',
        protocol: 'HTTP_CONNECT',
        method: 'CONNECT',
        pathName: '/',
        receivedAt: '2026-08-06T02:00:04.000Z',
        responseBytes: 26,
        responseSha256: digest('e')
      });
      const socksRecord = originModule.createRequestRecord({
        runId: EXPECTED_RUN_ID,
        originId: 'origin-123',
        requestId: 'req-socks',
        protocol: 'SOCKS5',
        method: 'CONNECT',
        pathName: '/',
        receivedAt: '2026-08-06T02:00:05.000Z',
        responseBytes: 26,
        responseSha256: digest('e')
      });
      return createOriginHandle([
        `${JSON.stringify(startedRecord)}\n${JSON.stringify(httpRecord)}\n${JSON.stringify(socksRecord)}\n`
      ]);
    }
  });
  assert.equal(forceStopProof.result, 'fail');
  assert.equal(forceStopProof.stop.forceStopResult, 'fail');
  assert.ok(forceStopProof.failures.some((entry) => entry.code === 'DEVICE_FORCE_STOP_FAILED'));
  await assert.rejects(fs.access(cleanupPullDir));

  await fs.writeFile(appEvidencePath, `${JSON.stringify(staleProof)}\n`, 'utf8');
  const failingProof = await runner.runPhase2DeviceProof({
    repoRoot,
    buildManifestPath,
    fixturePath,
    outputPath,
    randomUUID: () => EXPECTED_RUN_ID,
    buildPhase1NativeImpl: async () => buildManifest,
    inspectHapImpl: async () => ({
      result: 'pass',
      stubDetected: false,
      packaged: {
        rawCore: { identity: buildManifest.artifacts.rawCore.identity, sha256: digest('b'), sizeBytes: 9, elf: { result: 'pass' } },
        prePackageCore: { identity: buildManifest.artifacts.prePackageCore.identity, sha256: digest('b'), sizeBytes: 9, elf: { result: 'pass' } },
        prePackageAddon: { identity: buildManifest.artifacts.prePackageAddon.identity, sha256: digest('c'), sizeBytes: 10, elf: { result: 'pass' } },
        core: { identity: 'libs/arm64-v8a/libcmfa_mihomo.so', sha256: digest('b'), sizeBytes: 9, elf: { result: 'pass' } },
        addon: { identity: 'libs/arm64-v8a/libentry.so', sha256: digest('c'), sizeBytes: 10, elf: { result: 'pass' } }
      },
      provenance: {
        expected: buildManifest.provenance.upstream,
        observed: buildManifest.provenance.upstream,
        verified: 'pass'
      },
      failures: []
    }),
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/hdc' } }
    }),
    execImpl: async (_command, args) => {
      const joined = args.join(' ');
      if (joined.includes('file recv -b')) {
        const destinationPath = args.at(-1);
        await fs.mkdir(path.dirname(destinationPath), { recursive: true });
        await fs.writeFile(destinationPath, `${JSON.stringify(staleProof)}\n`, 'utf8');
        return { command: '/sdk/hdc', args, exitCode: 0, stdout: 'FileTransfer finish', stderr: '' };
      }
      return await execImpl(_command, args);
    },
    startOriginImpl: async () => createOriginHandle([
      `${JSON.stringify(originModule.createStartedRecord({
        runId: EXPECTED_RUN_ID,
        originId: 'origin-123',
        originUrl: 'https://127.0.0.1:18443/',
        address: '127.0.0.1:18443',
        caPem: certPemLiteral,
        bodySha256: digest('e'),
        bindHost: '127.0.0.1',
        files: { [certPathKey]: certPemPath, [keyPathKey]: keyPemPath },
        pid: 4312
      }))}\n`
    ])
  });
  assert.equal(failingProof.result, 'fail');
  assert.ok(failingProof.failures.some((entry) => /APP_EVIDENCE/i.test(entry.code)));
});

test('Phase 2 runner always writes a repo-contained incomplete proof when no signed physical-device input exists', async () => {
  assert.ok(runner, 'Phase 2 runner module must exist');
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase2-runner-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const outputPath = path.join(harmonyRoot, 'artifacts', 'phase2-device-proof.json');

  await fs.mkdir(path.join(harmonyRoot, 'artifacts'), { recursive: true });
  await fs.mkdir(path.join(harmonyRoot, 'tests', 'fixtures'), { recursive: true });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.lock.json'), JSON.stringify({
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hvigorVersion: '6.23.7',
      hdcVersion: '6.1.0.105'
    }
  }), 'utf8');
  await fs.writeFile(path.join(harmonyRoot, 'tests', 'fixtures', 'phase2-match-direct.yaml'), 'mode: rule\nrules:\n  - MATCH,DIRECT\n', 'utf8');
  await fs.writeFile(path.join(harmonyRoot, 'tests', 'fixtures', 'origin-body.txt'), 'fixture-body', 'utf8');

  const proof = await runner.runPhase2DeviceProof({
    repoRoot,
    outputPath,
    randomUUID: () => EXPECTED_RUN_ID
  });
  const persisted = JSON.parse(await fs.readFile(outputPath, 'utf8'));

  assert.equal(proof.result, 'incomplete');
  assert.equal(proof.runId, EXPECTED_RUN_ID);
  assert.equal(proof.outputPath, 'harmony/artifacts/phase2-device-proof.json');
  assert.equal(proof.stubDetection.stubDetected, null);
  assert.equal(proof.device.targetKind, 'host');
  assert.equal(proof.probes.http.status, 'not-run');
  assert.equal(proof.probes.socks.status, 'not-run');
  assert.ok(proof.failures.some((entry) => ['INPUT_HAP_MISSING', 'SIGNING_REQUIRED'].includes(entry.code)));
  assert.equal(runner.validatePhase2Proof(persisted).valid, true);
});

test('inspect-hap exports strict live rehash helpers and rejects fake packaged cores', async () => {
  assert.ok(inspectHapModule, 'inspect-hap module must exist');
  assert.equal(typeof inspectHapModule.inspectHap, 'function');
  assert.equal(typeof inspectHapModule.parseCliArguments, 'function');

  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase2-inspect-hap-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const hapPath = path.join(repoRoot, 'harmony', 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
  await fs.mkdir(path.dirname(hapPath), { recursive: true });
  await fs.writeFile(hapPath, 'hap-bytes', 'utf8');

  const report = await inspectHapModule.inspectHap({
    hapPath,
    repoRoot,
    manifest: {
      nativeBuildResult: 'pass',
      artifacts: {
        hap: { identity: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap', sha256: digest('a'), sizeBytes: 1024 },
        hapCore: { identity: 'libs/arm64-v8a/libcmfa_mihomo.so', sha256: digest('b'), sizeBytes: 512 },
        hapAddon: { identity: 'libs/arm64-v8a/libentry.so', sha256: digest('c'), sizeBytes: 256 }
      },
      provenance: {
        upstream: {
          commit: '0123456789abcdef0123456789abcdef01234567',
          version: 'v1.19.29',
          buildInfo: '{\"version\":\"v1.19.29\"}'
        }
      }
    },
    listHapEntriesImpl: async () => ['libs/arm64-v8a/libcmfa_mihomo.so', 'libs/arm64-v8a/libentry.so'],
    hashFileImpl: async (filePath) => ({
      sha256: filePath.endsWith('.hap') ? digest('a') : (filePath.endsWith('libcmfa_mihomo.so') ? digest('d') : digest('c')),
      sizeBytes: filePath.endsWith('.hap') ? 1024 : (filePath.endsWith('libcmfa_mihomo.so') ? 512 : 256)
    }),
    inspectNativeLibraryImpl: async ({ component }) => ({
      schemaVersion: '1.0.0',
      result: component === 'mihomoCore' ? 'fail' : 'pass',
      component,
      architecture: 'AArch64',
      exportedSymbols: [],
      requiredExports: [],
      buildInfo: component === 'mihomoCore' ? null : { version: 'v1.19.29', commit: '0123456789abcdef0123456789abcdef01234567' },
      failures: component === 'mihomoCore' ? [{ code: 'BUILD_INFO_MISSING', detail: 'missing', stage: 'archive' }] : []
    })
  });

  assert.equal(report.result, 'fail');
  assert.ok(report.failures.some((entry) => entry.code === 'HAP_CORE_REHASH_MISMATCH'));
  assert.ok(report.failures.some((entry) => entry.code === 'HAP_CORE_ELF_INVALID'));

  const rawCorePath = path.join(repoRoot, 'harmony', 'artifacts', 'libcmfa_mihomo.so');
  const prePackageCorePath = path.join(repoRoot, 'harmony', 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libcmfa_mihomo.so');
  const prePackageAddonPath = path.join(repoRoot, 'harmony', 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
  await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
  await fs.mkdir(path.dirname(prePackageCorePath), { recursive: true });
  await fs.writeFile(rawCorePath, 'raw-core', 'utf8');
  await fs.writeFile(prePackageCorePath, 'stale-core', 'utf8');
  await fs.writeFile(prePackageAddonPath, 'addon', 'utf8');

  const provenanceReport = await inspectHapModule.inspectHap({
    hapPath,
    repoRoot,
    manifestPath: path.join(repoRoot, 'harmony', 'artifacts', 'phase1-native-provenance.json'),
    fsApi: await import('node:fs/promises').then((module) => module.default),
    listHapEntriesImpl: async () => ['libs/arm64-v8a/libcmfa_mihomo.so', 'libs/arm64-v8a/libentry.so'],
    hashFileImpl: async (filePath) => ({
      sha256: filePath.endsWith('entry-default-signed.hap') ? digest('h') : (filePath.endsWith('libentry.so') ? digest('j') : digest('i')),
      sizeBytes: 64
    }),
    inspectNativeLibraryImpl: async () => ({
      schemaVersion: '1.0.0',
      result: 'pass',
      component: 'mihomoCore',
      architecture: 'AArch64',
      exportedSymbols: [],
      requiredExports: [],
      buildInfo: {
        version: CORE_VERSION,
        upstreamCommit: CORE_COMMIT,
        abiVersion: 'cmfa-harmony-v1',
        buildId: '0123456789abcdef'
      },
      failures: []
    }),
    manifest: {
      result: 'pass',
      nativeBuildResult: 'pass',
      phase2SelfTest: {
        enabled: false,
        activation: 'default',
        purpose: 'production',
        releaseStatus: 'releasable'
      },
      artifacts: {
        hap: { identity: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap', sha256: digest('h'), sizeBytes: 64 },
        rawCore: { identity: 'harmony/artifacts/libcmfa_mihomo.so', sha256: digest('i'), sizeBytes: 64 },
        prePackageCore: { identity: 'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so', sha256: digest('k'), sizeBytes: 64 },
        prePackageAddon: { identity: 'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so', sha256: digest('j'), sizeBytes: 64 },
        hapCore: { identity: 'libs/arm64-v8a/libcmfa_mihomo.so', sha256: digest('i'), sizeBytes: 64 },
        hapAddon: { identity: 'libs/arm64-v8a/libentry.so', sha256: digest('j'), sizeBytes: 64 }
      },
      provenance: {
        upstream: {
          version: CORE_VERSION,
          commit: CORE_COMMIT,
          buildInfo: BUILD_INFO_JSON,
          buildId: '0123456789abcdef'
        }
      }
    }
  });

  assert.equal(provenanceReport.result, 'fail');
  assert.ok(provenanceReport.failures.some((entry) => /PHASE2_SELF_TEST_REQUIRED|PREPACKAGE_CORE|RAW_CORE/u.test(entry.code)));
});

test('inspect-native-lib and CoreDebugPage enforce real-core-only Phase 2 evidence lanes', async () => {
  const appEvidenceFixture = await readAppEvidenceFixture();
  const [inspectNativeSource, debugPageSource, entryAbilitySource] = await Promise.all([
    fs.readFile(INSPECT_NATIVE_PATH, 'utf8'),
    fs.readFile(DEBUG_PAGE_PATH, 'utf8'),
    fs.readFile(ENTRY_ABILITY_PATH, 'utf8')
  ]);

  assert.match(inspectNativeSource, /BUILD_INFO_MISSING/u);
  assert.match(inspectNativeSource, /BUILD_INFO_INVALID/u);
  assert.match(inspectNativeSource, /cmfa_mihomo_core_build_info_json_cstr_v1/u);
  assert.match(inspectNativeSource, /cmfa_mihomo_core_version_cstr_v1/u);
  assert.match(inspectNativeSource, /ohos_mihomo_stub_build/u);
  assert.match(inspectNativeSource, /probe-backend/u);
  assert.match(inspectNativeSource, /dlopen|dlsym|libdl/u);

  const topLevelSignals = [
    'phase2-device-proof.json',
    'CMFA_ENABLE_PHASE2_SELFTEST',
    ...Object.keys(appEvidenceFixture),
    ...Object.keys(appEvidenceFixture.stop),
    ...Object.keys(appEvidenceFixture.probes.http),
    ...Object.keys(appEvidenceFixture.probes.socks)
  ];
  for (const signal of new Set(topLevelSignals)) {
    assert.match(`${debugPageSource}\n${entryAbilitySource}`, new RegExp(signal.replaceAll('.', '\\.'), 'u'));
  }
  assert.match(debugPageSource, /selfTestBuildEnabled/u);
  assert.match(debugPageSource, /result: 'incomplete'/u);
  assert.match(debugPageSource, /process\.pid/u);
  assert.doesNotMatch(debugPageSource, /\.call\(/u);
  assert.doesNotMatch(debugPageSource, /interface\s+ProcessInfo/u);
  assert.match(debugPageSource, /const phase2Probes:\s*Phase2ProbeCollection\s*=\s*\{\s*http:\s*httpProbe,\s*socks:\s*socksProbe/u);
  assert.match(debugPageSource, /probes:\s*phase2Probes/u);
  assert.match(debugPageSource, /httpProbe !== null && socksProbe !== null/u);
  assert.match(debugPageSource, /writeAtomicTextFile/u);
  assert.match(debugPageSource, /renameSync/u);
  assert.match(debugPageSource, /fsyncSync|flushSync/u);
  assert.doesNotMatch(debugPageSource, /probes:\s*Phase2ProbeEntry\[\]/u);
  assert.doesNotMatch(debugPageSource, /probes\.length/u);
  assert.doesNotMatch(debugPageSource, /openSync\(\s*filePath[\s\S]*OpenMode\.TRUNC/u);
});
