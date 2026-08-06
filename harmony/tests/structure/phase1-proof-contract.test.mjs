import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const RUNNER_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'run-phase1-device-proof.mjs');
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase1-device-proof.schema.json');
const EXAMPLE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase1-device-proof.example.json');
const EXPECTED_RUN_ID = 'a8e7119f-3e1b-4a20-98e2-a6d2b0917df4';
const DIGEST_A = 'a'.repeat(64);
const DIGEST_B = 'b'.repeat(64);
const DIGEST_C = 'c'.repeat(64);
const DIGEST_D = 'd'.repeat(64);
const CORE_EXPORTS = [
  'cmfa_mihomo_core_build_info_json_cstr_v1',
  'cmfa_mihomo_core_version_cstr_v1',
  'cmfa_mihomo_probe_https_v1',
  'cmfa_mihomo_runtime_state_v1',
  'cmfa_mihomo_start_local_v1',
  'cmfa_mihomo_stop_v1',
  'cmfa_mihomo_take_runtime_log_v1'
];
const REQUIRED_CHECKS = [
  'nativeHello',
  'coreVersion',
  'promiseResolution',
  'typedRejection',
  'eventDelivery',
  'unsubscribeSilence'
];

let runner = null;
try {
  runner = await import(pathToFileURL(RUNNER_PATH).href);
} catch {
  // The first RED run intentionally reaches this path before the runner exists.
}

function createPassProof() {
  return {
    schemaVersion: '1.0.0',
    phase: 1,
    result: 'pass',
    runId: EXPECTED_RUN_ID,
    outputPath: 'harmony/artifacts/phase1-device-proof.json',
    bundle: 'com.github.kr328.clash.harmony',
    ability: 'EntryAbility',
    timestamps: {
      runnerStartedAt: '2026-08-05T01:00:00.000Z',
      appStartedAt: '2026-08-05T01:00:01.000Z',
      proofAt: '2026-08-05T01:00:02.000Z',
      runnerFinishedAt: '2026-08-05T01:00:03.000Z'
    },
    toolchainLock: {
      path: 'harmony/toolchain.lock.json',
      sha256: DIGEST_A
    },
    hap: {
      path: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
      sha256: DIGEST_B,
      sizeBytes: 1024
    },
    native: {
      addon: {
        path: 'libs/arm64-v8a/libentry.so',
        sha256: DIGEST_C,
        sizeBytes: 512,
        elfMachine: 'AArch64',
        exportListSha256: DIGEST_D,
        requiredExports: []
      },
      core: {
        path: 'libs/arm64-v8a/libcmfa_mihomo.so',
        sha256: DIGEST_A,
        sizeBytes: 768,
        elfMachine: 'AArch64',
        exportListSha256: DIGEST_B,
        requiredExports: CORE_EXPORTS
      }
    },
    device: {
      identityMasked: 'target-83e1d9a4',
      buildVersion: 'HarmonyOS-6.0.0.123',
      apiVersion: '20',
      abi: 'arm64-v8a',
      model: 'HarmonyOS phone'
    },
    app: {
      bridgeVersion: '1.0.0',
      coreVersion: 'v1.19.29',
      eventCount: 1,
      lastError: {
        name: 'CoreError',
        code: 'CMFA_INVALID_ARGUMENT',
        category: 'CoreError',
        message: 'Invalid native argument.',
        detail: 'validateConfiguration rejected the test-only invalid path.',
        retryable: false,
        action: 'Check the supplied value.',
        context: {
          operation: 'validateConfiguration',
          status: 1
        }
      }
    },
    steps: {
      nativeManifest: { result: 'pass' },
      install: { result: 'pass' },
      launch: { result: 'pass' },
      pull: { result: 'pass' },
      cleanup: { result: 'pass' }
    },
    checks: REQUIRED_CHECKS.map((id) => ({
      id,
      result: 'pass',
      detail: id === 'nativeHello' ? 'cmfa-native-ready' : 'verified'
    })),
    failures: []
  };
}

function createAppProof() {
  const proof = createPassProof();
  return {
    schemaVersion: proof.schemaVersion,
    phase: proof.phase,
    result: 'pass',
    runId: proof.runId,
    timestamps: {
      startedAt: proof.timestamps.appStartedAt,
      proofAt: proof.timestamps.proofAt
    },
    ...proof.app,
    checks: proof.checks,
    failures: []
  };
}

test('Task 8 shared boundary, composition, debug page, and self-test wiring are present', async () => {
  const sourcePaths = {
    models: path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'core', 'CoreModels.ets'),
    errors: path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'core', 'CoreErrors.ets'),
    service: path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'core', 'CoreService.ets'),
    adapter: path.join(HARMONY_ROOT, 'core', 'src', 'main', 'ets', 'CoreNativeAdapter.ets'),
    composition: path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'bootstrap', 'CoreComposition.ets'),
    page: path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'pages', 'CoreDebugPage.ets'),
    ability: path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'entryability', 'EntryAbility.ets')
  };
  const entries = await Promise.all(Object.entries(sourcePaths).map(async ([name, filePath]) => [name, await fs.readFile(filePath, 'utf8')]));
  const sources = Object.fromEntries(entries);

  assert.match(sources.models, /export (interface|type) RuntimeSnapshot/u);
  assert.match(sources.models, /export (interface|type) CoreEvent/u);
  assert.match(sources.errors, /export interface CoreError/u);
  assert.match(sources.service, /export interface CoreService/u);
  for (const method of ['hello', 'coreVersion', 'validateConfiguration', 'subscribe', 'unsubscribe']) {
    assert.match(sources.service, new RegExp(`\\b${method}\\b`, 'u'));
  }
  assert.doesNotMatch(sources.service, /libentry\.so/u);

  const allArkTsFiles = (await fs.readdir(path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets'), { recursive: true }))
    .filter((entry) => entry.endsWith('.ets'))
    .map((entry) => path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', entry));
  const ownerCandidates = [sourcePaths.adapter, ...allArkTsFiles];
  const nodeApiOwners = [];
  for (const filePath of new Set(ownerCandidates)) {
    const body = await fs.readFile(filePath, 'utf8');
    if (/from ['"]libentry\.so['"]/u.test(body)) {
      nodeApiOwners.push(path.relative(REPO_ROOT, filePath));
    }
  }
  assert.deepEqual(nodeApiOwners, ['harmony/core/src/main/ets/CoreNativeAdapter.ets']);
  assert.match(sources.adapter, /implements CoreService/u);
  assert.doesNotMatch(sources.adapter, /\bdlopen\b|\bdlsym\b/u);
  assert.match(sources.composition, /CoreNativeAdapter/u);
  assert.match(sources.composition, /CoreService/u);

  for (const visibleState of ['bridgeVersion', 'coreVersion', 'lastError', 'eventCount', 'proofStatus']) {
    assert.match(sources.page, new RegExp(`\\b${visibleState}\\b`, 'u'));
  }
  for (const selfTestSignal of ['cmfa.phase1.selfTest', 'cmfa.phase1.runId', 'phase1-device-proof.json']) {
    assert.match(`${sources.ability}\n${sources.page}`, new RegExp(selfTestSignal.replaceAll('.', '\\.'), 'u'));
  }
  assert.match(sources.page, /fileIo/u);
  assert.match(sources.page, /OpenMode\.(?:WRITE_ONLY|READ_WRITE)/u);
  assert.match(sources.page, /OpenMode\.TRUNC/u);

  const mainPages = JSON.parse(await fs.readFile(path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'resources', 'base', 'profile', 'main_pages.json'), 'utf8'));
  assert.ok(mainPages.src.includes('pages/CoreDebugPage'));
  assert.match(sources.ability, /loadContent\(['"]pages\/CoreDebugPage['"]/u);
  assert.doesNotMatch(sources.page, /proxy|profiles|vpn|tun/iu, 'Phase 1 page must not contain placeholder product UI');
});

test('Phase 1 proof schema and canonical incomplete example are strict and versioned', async () => {
  const [schema, example] = await Promise.all([
    fs.readFile(SCHEMA_PATH, 'utf8').then(JSON.parse),
    fs.readFile(EXAMPLE_PATH, 'utf8').then(JSON.parse)
  ]);

  assert.equal(schema.$schema, 'https://json-schema.org/draft/2020-12/schema');
  assert.equal(schema.schemaVersion, '1.0.0');
  assert.equal(schema.additionalProperties, false);
  for (const key of ['runId', 'timestamps', 'toolchainLock', 'hap', 'native', 'device', 'app', 'steps', 'checks', 'failures']) {
    assert.ok(schema.required.includes(key), `schema must require ${key}`);
  }
  assert.equal(schema.properties.phase.const, 1);
  assert.deepEqual(schema.properties.result.enum, ['pass', 'fail', 'incomplete']);

  assert.ok(runner, 'Phase 1 runner module must exist');
  assert.equal(example.result, 'incomplete');
  assert.equal(runner.validatePhase1Proof(example).valid, true);
  assert.ok(example.failures.length > 0);
  assert.doesNotMatch(JSON.stringify(example), /\/Users\/|[A-Za-z]:\\/u);
});

test('Phase 1 merged pass proof requires fresh app evidence and exact native hashes', () => {
  assert.ok(runner, 'Phase 1 runner module must exist');
  const passProof = createPassProof();
  assert.deepEqual(runner.validatePhase1Proof(passProof, {
    expectedRunId: EXPECTED_RUN_ID,
    expectedHapSha256: DIGEST_B,
    runnerStartedAt: passProof.timestamps.runnerStartedAt,
    runnerFinishedAt: passProof.timestamps.runnerFinishedAt
  }), { valid: true, errors: [] });

  const mutations = [
    ['run id mismatch', (proof) => { proof.runId = cryptoLikeUuid('b'); }, /runId/u],
    ['stale app timestamp', (proof) => { proof.timestamps.proofAt = '2026-08-04T23:59:59.000Z'; }, /runner interval/u],
    ['HAP digest mismatch', (proof) => { proof.hap.sha256 = DIGEST_C; }, /HAP digest/u],
    ['core digest missing', (proof) => { proof.native.core.sha256 = null; }, /native\.core\.sha256/u],
    ['wrong architecture', (proof) => { proof.native.addon.elfMachine = 'x86_64'; }, /AArch64/u],
    ['old conflicting export admitted', (proof) => { proof.native.core.requiredExports = ['cmfa_core_version']; }, /cmfa_mihomo_core_build_info_json_cstr_v1|cmfa_mihomo_core_version_cstr_v1/u],
    ['required self-test check missing', (proof) => { proof.checks.pop(); }, /unsubscribeSilence/u],
    ['typed error absent', (proof) => { proof.app.lastError = null; }, /typed CoreError/u]
  ];

  for (const [name, mutate, expected] of mutations) {
    const proof = structuredClone(passProof);
    mutate(proof);
    const validation = runner.validatePhase1Proof(proof, {
      expectedRunId: EXPECTED_RUN_ID,
      expectedHapSha256: DIGEST_B,
      runnerStartedAt: passProof.timestamps.runnerStartedAt,
      runnerFinishedAt: passProof.timestamps.runnerFinishedAt
    });
    assert.equal(validation.valid, false, name);
    assert.match(validation.errors.join('\n'), expected, name);
  }
});

test('Phase 1 app proof validation rejects synthetic, stale, and incomplete self-tests', () => {
  assert.ok(runner, 'Phase 1 runner module must exist');
  const appProof = createAppProof();
  const interval = {
    expectedRunId: EXPECTED_RUN_ID,
    runnerStartedAt: '2026-08-05T01:00:00.000Z',
    runnerFinishedAt: '2026-08-05T01:00:03.000Z'
  };
  assert.deepEqual(runner.validateAppSelfTestProof(appProof, interval), { valid: true, errors: [] });

  const wrongRun = structuredClone(appProof);
  wrongRun.runId = cryptoLikeUuid('f');
  assert.match(runner.validateAppSelfTestProof(wrongRun, interval).errors.join('\n'), /runId/u);

  const early = structuredClone(appProof);
  early.timestamps.startedAt = '2026-08-05T00:59:59.000Z';
  assert.match(runner.validateAppSelfTestProof(early, interval).errors.join('\n'), /runner interval/u);

  const forged = structuredClone(appProof);
  forged.checks.find((entry) => entry.id === 'eventDelivery').result = 'not-run';
  assert.match(runner.validateAppSelfTestProof(forged, interval).errors.join('\n'), /eventDelivery/u);

  const resultMissing = structuredClone(appProof);
  delete resultMissing.result;
  assert.match(runner.validateAppSelfTestProof(resultMissing, interval).errors.join('\n'), /result/u);
});

test('Phase 1 runner records a simulator target as incomplete rather than a device failure', async () => {
  assert.ok(runner, 'Phase 1 runner module must exist');
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'cmfa-phase1-simulator-proof-'));
  try {
    const hapPath = path.join(tempRoot, 'entry-default-signed.hap');
    const manifestPath = path.join(tempRoot, 'phase1-native-provenance.json');
    const outputPath = path.join(tempRoot, 'phase1-device-proof.json');
    const hapContent = Buffer.from('signed-hap');
    const hapDigest = crypto.createHash('sha256').update(hapContent).digest('hex');
    const nativeDigest = 'a'.repeat(64);
    const manifest = {
      nativeBuildResult: 'pass',
      signing: { result: 'pass' },
      toolchainLock: {
        path: 'harmony/toolchain.lock.json',
        sha256: 'b'.repeat(64)
      },
      artifacts: {
        hap: {
          sha256: hapDigest,
          sizeBytes: hapContent.byteLength
        },
        hapAddon: {
          identity: 'libs/arm64-v8a/libentry.so',
          sha256: nativeDigest,
          sizeBytes: 512,
          elf: {
            result: 'pass',
            architecture: 'AArch64',
            exportedSymbols: [],
            requiredExports: []
          }
        },
        hapCore: {
          identity: 'libs/arm64-v8a/libcmfa_mihomo.so',
          sha256: nativeDigest,
          sizeBytes: 768,
          elf: {
            result: 'pass',
            architecture: 'AArch64',
            exportedSymbols: CORE_EXPORTS,
            requiredExports: CORE_EXPORTS
          }
        }
      }
    };
    await fs.writeFile(hapPath, hapContent);
    await fs.writeFile(manifestPath, `${JSON.stringify(manifest)}\n`, 'utf8');

    const execImpl = async (_command, args) => {
      if (args.includes('help') || args.includes('-h') || args.includes('--help')) {
        return successfulCommand('list targets file recv install shell');
      }
      if (args[0] === 'list' && args[1] === 'targets') {
        return successfulCommand('simulator-target\n');
      }
      const key = args.at(-1);
      const facts = {
        'const.product.software.version': 'HarmonyOS-6.0.0.123',
        'const.ohos.apiversion': '20',
        'const.product.cpu.abilist': 'arm64-v8a',
        'const.product.model': 'HarmonyOS Simulator'
      };
      return successfulCommand(facts[key] ?? '');
    };

    const proof = await runner.runPhase1DeviceProof({
      hapPath,
      manifestPath,
      outputPath,
      repoRoot: tempRoot,
      execImpl,
      verifyManifestImpl: async () => ({ valid: true, errors: [] }),
      toolchainInspectorImpl: async () => ({
        report: { result: 'pass' },
        resolved: { paths: { hdc: 'hdc' } }
      }),
      randomUUID: () => EXPECTED_RUN_ID,
      now: monotonicNow(),
      waitImpl: () => Promise.resolve()
    });

    assert.equal(proof.result, 'incomplete');
    assert.ok(proof.failures.some((entry) => entry.code === 'DEVICE_TARGET_UNSUPPORTED'));
    assert.equal(runner.validatePhase1Proof(proof).valid, true);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Phase 1 command builders target one device, pass a JSON Want payload, and use bundle-scoped recv', () => {
  assert.ok(runner, 'Phase 1 runner module must exist');
  const startedAt = '2026-08-05T01:00:00.000Z';
  const launchArgs = runner.buildPhase1LaunchArgs('device-raw-id', EXPECTED_RUN_ID, startedAt);
  assert.deepEqual(launchArgs.slice(0, 2), ['-t', 'device-raw-id']);
  assert.deepEqual(launchArgs.slice(2, 7), ['shell', 'aa', 'start', '-a', 'EntryAbility']);
  assert.ok(launchArgs.includes('-b'));
  assert.ok(launchArgs.includes('-p'));
  const payload = JSON.parse(launchArgs[launchArgs.indexOf('-p') + 1]);
  assert.deepEqual(payload, {
    'cmfa.phase1.selfTest': true,
    'cmfa.phase1.runId': EXPECTED_RUN_ID,
    'cmfa.phase1.runnerStartedAt': startedAt
  });

  const pullArgs = runner.buildPhase1PullArgs('device-raw-id', '/tmp/local-proof.json');
  assert.deepEqual(pullArgs, [
    '-t', 'device-raw-id',
    'file', 'recv', '-b', 'com.github.kr328.clash.harmony',
    '/data/storage/el2/base/files/phase1-device-proof.json',
    '/tmp/local-proof.json'
  ]);
});

test('Phase 1 runner preserves a valid failing app proof as the final device failure', async () => {
  assert.ok(runner, 'Phase 1 runner module must exist');
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'cmfa-phase1-failing-app-proof-'));
  try {
    const hapPath = path.join(tempRoot, 'entry-default-signed.hap');
    const manifestPath = path.join(tempRoot, 'phase1-native-provenance.json');
    const outputPath = path.join(tempRoot, 'phase1-device-proof.json');
    const hapContent = Buffer.from('signed-hap');
    const hapDigest = crypto.createHash('sha256').update(hapContent).digest('hex');
    const nativeDigest = 'a'.repeat(64);
    const manifest = {
      nativeBuildResult: 'pass',
      signing: { result: 'pass' },
      toolchainLock: {
        path: 'harmony/toolchain.lock.json',
        sha256: 'b'.repeat(64)
      },
      artifacts: {
        hap: { sha256: hapDigest, sizeBytes: hapContent.byteLength },
        hapAddon: {
          identity: 'libs/arm64-v8a/libentry.so',
          sha256: nativeDigest,
          sizeBytes: 512,
          elf: {
            result: 'pass',
            architecture: 'AArch64',
            exportedSymbols: [],
            requiredExports: []
          }
        },
        hapCore: {
          identity: 'libs/arm64-v8a/libcmfa_mihomo.so',
          sha256: nativeDigest,
          sizeBytes: 768,
          elf: {
            result: 'pass',
            architecture: 'AArch64',
            exportedSymbols: CORE_EXPORTS,
            requiredExports: CORE_EXPORTS
          }
        }
      }
    };
    const appProof = createAppProof();
    appProof.result = 'fail';
    appProof.timestamps.startedAt = '2026-08-05T01:00:00.000Z';
    appProof.timestamps.proofAt = '2026-08-05T01:00:01.000Z';
    appProof.checks.find((entry) => entry.id === 'eventDelivery').result = 'fail';
    appProof.checks.find((entry) => entry.id === 'eventDelivery').detail = 'No event arrived.';
    appProof.failures = [{
      code: 'PHASE1_SELF_TEST_FAILED',
      detail: 'One or more real native bridge checks failed.',
      stage: 'self-test'
    }];

    await fs.writeFile(hapPath, hapContent);
    await fs.writeFile(manifestPath, `${JSON.stringify(manifest)}\n`, 'utf8');

    const execImpl = async (_command, args) => {
      if (args.includes('help') || args.includes('-h') || args.includes('--help')) {
        return successfulCommand('list targets file recv install shell');
      }
      if (args[0] === 'list' && args[1] === 'targets') {
        return successfulCommand('physical-target\n');
      }
      if (args.includes('param') && args.includes('get')) {
        const key = args.at(-1);
        const facts = {
          'const.product.software.version': 'HarmonyOS-6.0.0.123',
          'const.ohos.apiversion': '20',
          'const.product.cpu.abilist': 'arm64-v8a',
          'const.product.model': 'Huawei phone'
        };
        return successfulCommand(facts[key] ?? '');
      }
      if (args.includes('install')) {
        return successfulCommand('Success');
      }
      if (args.includes('aa') && args.includes('start')) {
        return successfulCommand('Start ability successfully');
      }
      if (args.includes('file') && args.includes('recv')) {
        await fs.writeFile(args.at(-1), `${JSON.stringify(appProof)}\n`, 'utf8');
        return successfulCommand();
      }
      return successfulCommand();
    };

    const proof = await runner.runPhase1DeviceProof({
      hapPath,
      manifestPath,
      outputPath,
      repoRoot: tempRoot,
      execImpl,
      verifyManifestImpl: async () => ({ valid: true, errors: [] }),
      toolchainInspectorImpl: async () => ({
        report: { result: 'pass' },
        resolved: { paths: { hdc: 'hdc' } }
      }),
      randomUUID: () => EXPECTED_RUN_ID,
      now: monotonicNow(),
      waitImpl: () => Promise.resolve()
    });

    assert.equal(proof.result, 'fail');
    assert.ok(proof.failures.some((entry) => entry.code === 'PHASE1_SELF_TEST_FAILED'));
    assert.ok(!proof.failures.some((entry) => entry.code === 'APP_PROOF_INVALID'));
    assert.equal(proof.checks.find((entry) => entry.id === 'eventDelivery').result, 'fail');
    assert.equal(runner.validatePhase1Proof(proof).valid, true);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Phase 1 app proof pull retries stale proof until the expected runId proof is observed', async () => {
  assert.ok(runner, 'Phase 1 runner module must exist');
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'cmfa-phase1-app-proof-'));
  try {
    const localProofPath = path.join(tempRoot, 'phase1-device-proof.json');
    const staleProof = createAppProof();
    staleProof.runId = cryptoLikeUuid('f');
    const freshProof = createAppProof();
    freshProof.runId = EXPECTED_RUN_ID;
    const interval = {
      runnerStartedAt: '2026-08-05T01:00:00.000Z',
      runnerFinishedAt: '2026-08-05T01:00:10.000Z'
    };
    let pullCount = 0;

    const execImpl = async (_command, _args) => {
      pullCount += 1;
      const payload = pullCount === 1 ? staleProof : freshProof;
      await fs.writeFile(localProofPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
      return {
        command: _command,
        args: _args,
        exitCode: 0,
        stdout: '',
        stderr: '',
        timedOut: false,
        error: null
      };
    };

    const pulled = await runner.pullAppProof({
      fsApi: fs,
      execImpl,
      hdcCommand: 'hdc',
      target: 'target-raw-id',
      localPath: localProofPath,
      cwd: tempRoot,
      waitImpl: () => Promise.resolve(),
      expectedRunId: EXPECTED_RUN_ID,
      runnerStartedAt: interval.runnerStartedAt,
      runnerFinishedAt: interval.runnerFinishedAt
    });

    assert.equal(pulled.ok, true);
    assert.equal(pullCount, 2);
    assert.equal(pulled.appProof.runId, EXPECTED_RUN_ID);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Phase 1 runner CLI always writes an incomplete proof when inputs or targets are unavailable', async () => {
  assert.ok(runner, 'Phase 1 runner module must exist');
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'cmfa-phase1-proof-'));
  try {
    const missingExit = await runner.runCli({
      argv: [],
      repoRoot: tempRoot,
      randomUUID: () => EXPECTED_RUN_ID,
      now: monotonicNow()
    });
    assert.equal(missingExit, 2);
    const outputPath = path.join(tempRoot, 'harmony', 'artifacts', 'phase1-device-proof.json');
    const missingProof = JSON.parse(await fs.readFile(outputPath, 'utf8'));
    assert.equal(missingProof.result, 'incomplete');
    assert.ok(missingProof.failures.some((entry) => entry.code === 'INPUT_HAP_MISSING'));
    assert.equal(runner.validatePhase1Proof(missingProof).valid, true);

    const fakeHapPath = path.join(tempRoot, 'entry-default-unsigned.hap');
    await fs.writeFile(fakeHapPath, 'unsigned-hap', 'utf8');
    const unsignedExit = await runner.runCli({
      argv: ['--hap', fakeHapPath],
      repoRoot: tempRoot,
      randomUUID: () => cryptoLikeUuid('e'),
      now: monotonicNow()
    });
    assert.equal(unsignedExit, 2);
    const unsignedProof = JSON.parse(await fs.readFile(outputPath, 'utf8'));
    assert.equal(unsignedProof.result, 'incomplete');
    assert.ok(unsignedProof.failures.some((entry) => entry.code === 'SIGNING_REQUIRED'));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Phase 1 CLI parsing is strict and keeps output/manifest paths repository-scoped by default', () => {
  assert.ok(runner, 'Phase 1 runner module must exist');
  assert.deepEqual(runner.parseCliArguments([
    '--hap', 'signed.hap',
    '--manifest', 'harmony/artifacts/custom-native.json',
    '--out', 'harmony/artifacts/custom-device.json'
  ], REPO_ROOT), {
    hapPath: path.join(REPO_ROOT, 'signed.hap'),
    manifestPath: path.join(REPO_ROOT, 'harmony', 'artifacts', 'custom-native.json'),
    outputPath: path.join(REPO_ROOT, 'harmony', 'artifacts', 'custom-device.json')
  });
  assert.throws(() => runner.parseCliArguments(['--wat'], REPO_ROOT), /Unknown argument/u);
  assert.throws(() => runner.parseCliArguments(['--hap'], REPO_ROOT), /requires a value/u);
});

test('Phase 1 runner rejects a repo-local HAP symlink that resolves outside the repository', async () => {
  assert.ok(runner, 'Phase 1 runner module must exist');
  const repoRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'cmfa-phase1-symlink-read-repo-'));
  const outsideRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'cmfa-phase1-symlink-read-outside-'));
  try {
    const outsideHap = path.join(outsideRoot, 'external-signed.hap');
    const linkedHap = path.join(repoRoot, 'entry-default-signed.hap');
    await fs.writeFile(outsideHap, 'outside-hap', 'utf8');
    await fs.symlink(outsideHap, linkedHap);

    const proof = await runner.runPhase1DeviceProof({
      hapPath: linkedHap,
      manifestPath: path.join(repoRoot, 'unused-manifest.json'),
      outputPath: path.join(repoRoot, 'harmony', 'artifacts', 'phase1-device-proof.json'),
      repoRoot,
      randomUUID: () => EXPECTED_RUN_ID,
      now: monotonicNow()
    });

    assert.equal(proof.result, 'fail');
    assert.ok(proof.failures.some((entry) => entry.code === 'PATH_OUTSIDE_REPO'));
  } finally {
    await fs.rm(repoRoot, { recursive: true, force: true });
    await fs.rm(outsideRoot, { recursive: true, force: true });
  }
});

test('Phase 1 proof writer rejects a repo-local output directory symlink that resolves outside the repository', async () => {
  assert.ok(runner, 'Phase 1 runner module must exist');
  const repoRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'cmfa-phase1-symlink-write-repo-'));
  const outsideRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'cmfa-phase1-symlink-write-outside-'));
  try {
    const harmonyRoot = path.join(repoRoot, 'harmony');
    const linkedArtifacts = path.join(harmonyRoot, 'artifacts');
    const outputPath = path.join(linkedArtifacts, 'phase1-device-proof.json');
    await fs.mkdir(harmonyRoot, { recursive: true });
    await fs.symlink(outsideRoot, linkedArtifacts);

    await assert.rejects(
      runner.writeProof({ result: 'incomplete' }, outputPath, fs, repoRoot),
      /outside the repository|symlink/iu
    );
    await assert.rejects(fs.access(path.join(outsideRoot, 'phase1-device-proof.json')));
  } finally {
    await fs.rm(repoRoot, { recursive: true, force: true });
    await fs.rm(outsideRoot, { recursive: true, force: true });
  }
});

function cryptoLikeUuid(fill) {
  return `${fill.repeat(8)}-${fill.repeat(4)}-4${fill.repeat(3)}-8${fill.repeat(3)}-${fill.repeat(12)}`;
}

function monotonicNow() {
  let tick = 0;
  return () => new Date(Date.parse('2026-08-05T01:00:00.000Z') + tick++ * 1000);
}

function successfulCommand(stdout = '') {
  return {
    command: 'hdc',
    args: [],
    exitCode: 0,
    stdout,
    stderr: '',
    timedOut: false,
    error: null
  };
}
