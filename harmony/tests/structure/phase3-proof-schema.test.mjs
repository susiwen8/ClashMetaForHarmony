import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const RUNNER_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'run-phase3-simulator-proof.mjs');
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase3-simulator-proof.schema.json');
const EXAMPLE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase3-simulator-proof.example.json');
const FIXTURE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase3-valid.yaml');
const PHASE3_RUNNER_SOURCE_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'run-phase3-simulator-proof.mjs');
const PHASE2_RUNNER_SOURCE_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'run-phase2-device-proof.mjs');

let runner = null;
try {
  runner = await import(pathToFileURL(RUNNER_PATH).href);
} catch {
  // RED until the runner exists.
}

function digest(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function joinFragments(parts) {
  return parts.join('');
}

function createIsoSequence(...timestamps) {
  let index = 0;
  return () => new Date(timestamps[Math.min(index++, timestamps.length - 1)]);
}

async function writeFileWithParents(filePath, contents) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, contents, 'utf8');
}

async function createPhase3TempRepo(label) {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), `${label}-`));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const productionHapPath = path.join(harmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
  const entryTestHapPath = path.join(harmonyRoot, 'entry', 'build', 'default', 'outputs', 'ohosTest', 'entry-ohosTest-signed.hap');
  const fixturePath = path.join(harmonyRoot, 'tests', 'fixtures', 'phase3-valid.yaml');
  const outputPath = path.join(harmonyRoot, 'artifacts', 'phase3-simulator-proof.json');
  const manifestPath = path.join(harmonyRoot, 'artifacts', 'phase3-build-manifest.json');
  const rawCorePath = path.join(harmonyRoot, 'artifacts', 'libcmfa_mihomo.so');
  const prePackageCorePath = path.join(harmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libcmfa_mihomo.so');
  const prePackageAddonPath = path.join(harmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
  const fixtureBody = 'mode: rule\nrules:\n  - MATCH,DIRECT\n';

  await writeFileWithParents(path.join(harmonyRoot, 'toolchain.lock.json'), JSON.stringify({ installed: { hdcVersion: '6.1.1.125' } }));
  await writeFileWithParents(fixturePath, fixtureBody);
  await writeFileWithParents(productionHapPath, 'prod-hap');
  await writeFileWithParents(entryTestHapPath, 'test-hap');
  await writeFileWithParents(rawCorePath, 'raw-core');
  await writeFileWithParents(prePackageCorePath, 'raw-core');
  await writeFileWithParents(prePackageAddonPath, 'addon');

  return {
    tempRoot,
    repoRoot,
    harmonyRoot,
    productionHapPath,
    entryTestHapPath,
    fixturePath,
    outputPath,
    manifestPath,
    rawCorePath,
    prePackageCorePath,
    prePackageAddonPath,
    fixtureBody
  };
}

async function hashFile(filePath) {
  const buffer = await fs.readFile(filePath);
  return {
    sha256: digest(buffer),
    sizeBytes: buffer.byteLength
  };
}

async function createProductionManifest(paths) {
  return {
    result: 'pass',
    nativeBuildResult: 'pass',
    signing: { result: 'pass' },
    phase2SelfTest: {
      enabled: false,
      activation: 'default',
      purpose: 'production',
      releaseStatus: 'releasable'
    },
    artifacts: {
      hap: {
        identity: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
        ...(await hashFile(paths.productionHapPath))
      },
      rawCore: {
        identity: 'harmony/artifacts/libcmfa_mihomo.so',
        ...(await hashFile(paths.rawCorePath))
      },
      prePackageCore: {
        identity: 'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so',
        ...(await hashFile(paths.prePackageCorePath))
      },
      prePackageAddon: {
        identity: 'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so',
        ...(await hashFile(paths.prePackageAddonPath))
      },
      hapCore: {
        identity: 'libs/arm64-v8a/libcmfa_mihomo.so',
        ...(await hashFile(paths.rawCorePath))
      },
      hapAddon: {
        identity: 'libs/arm64-v8a/libentry.so',
        ...(await hashFile(paths.prePackageAddonPath))
      }
    },
    provenance: {
      upstream: {
        version: 'v1.19.29',
        commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
        buildInfo: '{"version":"v1.19.29","upstreamCommit":"e26714a181ac0e2fa803453c0a8e9a9ce94e31cb","abiVersion":"cmfa-harmony-v1","buildId":"0123456789abcdef"}',
        buildId: '0123456789abcdef'
      }
    }
  };
}

function createInspectionPass(manifest) {
  return {
    result: 'pass',
    stubDetected: false,
    hap: manifest.artifacts.hap,
    packaged: {
      rawCore: manifest.artifacts.rawCore,
      prePackageCore: manifest.artifacts.prePackageCore,
      prePackageAddon: manifest.artifacts.prePackageAddon,
      core: {
        identity: 'libs/arm64-v8a/libcmfa_mihomo.so',
        ...manifest.artifacts.hapCore,
        elf: {
          result: 'pass',
          architecture: 'AArch64',
          buildInfo: {
            version: manifest.provenance.upstream.version,
            upstreamCommit: manifest.provenance.upstream.commit,
            abiVersion: 'cmfa-harmony-v1',
            buildId: manifest.provenance.upstream.buildId
          },
          failures: []
        }
      },
      addon: {
        identity: 'libs/arm64-v8a/libentry.so',
        ...manifest.artifacts.hapAddon,
        elf: {
          result: 'pass',
          architecture: 'AArch64',
          buildInfo: null,
          failures: []
        }
      }
    },
    provenance: {
      expected: manifest.provenance.upstream,
      observed: {
        version: manifest.provenance.upstream.version,
        upstreamCommit: manifest.provenance.upstream.commit,
        abiVersion: 'cmfa-harmony-v1',
        buildId: manifest.provenance.upstream.buildId
      },
      verified: 'pass'
    },
    failures: []
  };
}

function createSimulatorEvidence({
  runId,
  productionHapSha256,
  entryTestHapSha256,
  fixtureSha256,
  status = 'PASS',
  failures = [],
  homeAddress = 'home.runtime.primary',
  cleanup = 'pass'
} = {}) {
  return {
    schemaVersion: '1.0.0',
    phase: 3,
    task: 14,
    status,
    updatedAt: '2026-08-11T02:00:04.000Z',
    runId,
    productionHapSha256,
    entryTestHapSha256,
    fixtureSha256,
    suites: ['Phase3PlatformAdapters', 'Phase3RuntimeFlow', 'Phase3UiFlow'],
    checks: [
      'Phase3PlatformAdapters: pass',
      'Phase3RuntimeFlow: validate > retain/save > enable.validate > enable.load > start.revalidate > start.load > startLocal(7890) > RUNNING 127.0.0.1:7890 127.0.0.1:7891 > stop > STOPPED',
      'Phase3UiFlow: pass'
    ],
    trace: ['runner.started', 'runner.completionObserved'],
    failures,
    cleanup,
    homeSnapshotAddress: homeAddress,
    homeRuntimeAddress: homeAddress
  };
}

function createExecResult({ stdout = '', stderr = '', exitCode = 0, error = null, timedOut = false } = {}) {
  return { stdout, stderr, exitCode, error, timedOut };
}

function createExecPlan({
  targets = 'simulator-5554\n',
  model = 'HarmonyOS Simulator',
  product = 'openharmony-simulator',
  buildVersion = 'HarmonyOS 6.0.0',
  apiVersion = '20',
  abi = 'arm64-v8a',
  installResults = [],
  uninstallResult = createExecResult(),
  forceStopResult = createExecResult()
} = {}) {
  const installQueue = [...installResults];
  return async function execImpl(command, args) {
    const joined = [command, ...args].join(' ');
    if (joined.includes('list targets')) {
      return createExecResult({ stdout: targets });
    }
    if (joined.includes('const.product.model')) {
      return createExecResult({ stdout: `${model}\n` });
    }
    if (joined.includes('const.product.name') || joined.includes('const.product.device')) {
      return createExecResult({ stdout: `${product}\n` });
    }
    if (joined.includes('const.product.software.version')) {
      return createExecResult({ stdout: `${buildVersion}\n` });
    }
    if (joined.includes('const.ohos.apiversion') || joined.includes('const.product.apiversion')) {
      return createExecResult({ stdout: `${apiVersion}\n` });
    }
    if (joined.includes('const.product.cpu.abilist')) {
      return createExecResult({ stdout: `${abi}\n` });
    }
    if (joined.includes(' install ')) {
      return installQueue.shift() ?? createExecResult();
    }
    if (joined.includes(' force-stop ')) {
      return forceStopResult;
    }
    if (joined.includes(' uninstall ')) {
      return uninstallResult;
    }
    if (joined.includes(' shell aa test ')) {
      return createExecResult();
    }
    if (joined.includes(' shell aa start ')) {
      return createExecResult();
    }
    if (args[0] === 'help') {
      return createExecResult({
        stdout: 'list targets [-v]\ninstall [-r|-s|-cwd|option] src\nshell [COMMAND...]\nuninstall bundleName\n'
      });
    }
    return createExecResult();
  };
}

test('Phase 3 simulator proof schema/example and runner contract stay provisional and honest', async () => {
  const [schema, example] = await Promise.all([
    fs.readFile(SCHEMA_PATH, 'utf8').then(JSON.parse),
    fs.readFile(EXAMPLE_PATH, 'utf8').then(JSON.parse)
  ]);

  assert.ok(runner, 'Phase 3 runner module must exist');
  assert.equal(typeof runner.validatePhase3Proof, 'function');
  assert.equal(typeof runner.runPhase3SimulatorProof, 'function');
  assert.equal(typeof runner.runCli, 'function');

  assert.equal(schema.$schema, 'https://json-schema.org/draft/2020-12/schema');
  assert.equal(schema.additionalProperties, false);
  assert.equal(schema.properties.phase.const, 3);
  assert.deepEqual(schema.properties.result.enum, ['provisional-pass', 'incomplete']);
  assert.ok(!schema.properties.result.enum.includes('pass'));
  assert.ok(schema.required.includes('physicalDeviceGates'));

  assert.equal(example.phase, 3);
  assert.equal(example.result, 'incomplete');
  assert.deepEqual(example.physicalDeviceGates, {
    phase2Traffic: 'incomplete',
    phase3ProfileRuntime: 'incomplete'
  });
  assert.equal(runner.validatePhase3Proof(example).valid, true);
  const impossible = structuredClone(example);
  impossible.result = 'pass';
  assert.equal(runner.validatePhase3Proof(impossible).valid, false);
});

test('Phase 3 CLI defaults stay repo-scoped and parse optional production/test inputs', async () => {
  assert.ok(runner, 'Phase 3 runner module must exist');
  assert.deepEqual(runner.parseCliArguments([], REPO_ROOT), {
    outputPath: path.join(REPO_ROOT, 'harmony', 'artifacts', 'phase3-simulator-proof.json'),
    productionManifestPath: path.join(REPO_ROOT, 'harmony', 'artifacts', 'phase3-build-manifest.json'),
    entryTestHapPath: path.join(REPO_ROOT, 'harmony', 'entry', 'build', 'default', 'outputs', 'ohosTest', 'entry-ohosTest-unsigned.hap'),
    fixturePath: FIXTURE_PATH
  });
});

test('Phase 3 CLI parse errors write the proof to a previously parsed custom --out path', async () => {
  assert.ok(runner, 'Phase 3 runner module must exist');
  const repo = await createPhase3TempRepo('phase3-cli-custom-out');
  const customOutputPath = path.join(repo.harmonyRoot, 'artifacts', 'custom-phase3-proof.json');

  const exitCode = await runner.runCli({
    argv: ['--out', 'harmony/artifacts/custom-phase3-proof.json', '--bogus'],
    repoRoot: repo.repoRoot,
    fsApi: await import('node:fs/promises').then((module) => module.default)
  });

  assert.equal(exitCode, 1);
  const persisted = JSON.parse(await fs.readFile(customOutputPath, 'utf8'));
  assert.equal(persisted.outputPath, 'harmony/artifacts/custom-phase3-proof.json');
  await assert.rejects(fs.access(repo.outputPath));
});

test('Phase 3 runner marks missing, ambiguous, and physical-only targets as incomplete simulator gates', async () => {
  assert.ok(runner, 'Phase 3 runner module must exist');
  const cases = [
    ['missing target', createExecPlan({ targets: '\n' }), 'DEVICE_TARGET_MISSING', 'host'],
    ['ambiguous target', createExecPlan({ targets: 'sim-a\nsim-b\n' }), 'DEVICE_TARGET_AMBIGUOUS', 'host'],
    ['physical target', createExecPlan({ model: 'Harmony Phone', product: 'PuraX' }), 'SIMULATOR_TARGET_REQUIRED', 'physical']
  ];

  for (const [label, execImpl, expectedCode, expectedKind] of cases) {
    const repo = await createPhase3TempRepo(`phase3-target-${label.replaceAll(' ', '-')}`);
    const manifest = await createProductionManifest(repo);
    const proof = await runner.runPhase3SimulatorProof({
      repoRoot: repo.repoRoot,
      productionManifestPath: repo.manifestPath,
      entryTestHapPath: repo.entryTestHapPath,
      fixturePath: repo.fixturePath,
      outputPath: repo.outputPath,
      buildPhase1NativeImpl: async () => manifest,
      inspectHapImpl: async () => createInspectionPass(manifest),
      execImpl,
      now: createIsoSequence('2026-08-11T02:00:00.000Z', '2026-08-11T02:00:01.000Z')
    });

    assert.equal(proof.result, 'incomplete', label);
    assert.equal(proof.target.targetKind, expectedKind, label);
    assert.ok(proof.failures.some((entry) => entry.code === expectedCode), label);
    assert.deepEqual(proof.physicalDeviceGates, {
      phase2Traffic: 'incomplete',
      phase3ProfileRuntime: 'incomplete'
    }, label);
  }
});

test('Phase 3 runner refuses unsigned artifacts and failed install or timed-out test execution', async () => {
  assert.ok(runner, 'Phase 3 runner module must exist');

  const unsignedRepo = await createPhase3TempRepo('phase3-unsigned');
  const unsignedProductionPath = unsignedRepo.productionHapPath.replace('-signed.hap', '-unsigned.hap');
  await fs.rename(unsignedRepo.productionHapPath, unsignedProductionPath);
  const unsignedProof = await runner.runPhase3SimulatorProof({
    repoRoot: unsignedRepo.repoRoot,
    productionManifestPath: unsignedRepo.manifestPath,
    entryTestHapPath: unsignedRepo.entryTestHapPath,
    fixturePath: unsignedRepo.fixturePath,
    outputPath: unsignedRepo.outputPath,
    buildPhase1NativeImpl: async () => {
      const manifest = await createProductionManifest({
        ...unsignedRepo,
        productionHapPath: unsignedProductionPath
      });
      return {
        ...manifest,
        artifacts: {
          ...manifest.artifacts,
          hap: {
            identity: 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap',
            ...(await hashFile(unsignedProductionPath))
          }
        }
      };
    },
    inspectHapImpl: async () => createInspectionPass(await createProductionManifest({
      ...unsignedRepo,
      productionHapPath: unsignedProductionPath
    })),
    execImpl: createExecPlan(),
    now: createIsoSequence('2026-08-11T02:00:00.000Z', '2026-08-11T02:00:01.000Z')
  });
  assert.equal(unsignedProof.result, 'incomplete');
  assert.ok(unsignedProof.failures.some((entry) => entry.code === 'INPUT_HAP_UNSIGNED'));

  const installRepo = await createPhase3TempRepo('phase3-install-fail');
  const installManifest = await createProductionManifest(installRepo);
  const installProof = await runner.runPhase3SimulatorProof({
    repoRoot: installRepo.repoRoot,
    productionManifestPath: installRepo.manifestPath,
    entryTestHapPath: installRepo.entryTestHapPath,
    fixturePath: installRepo.fixturePath,
    outputPath: installRepo.outputPath,
    buildPhase1NativeImpl: async () => installManifest,
    inspectHapImpl: async () => createInspectionPass(installManifest),
    execImpl: createExecPlan({
      installResults: [
        createExecResult({
          stderr: joinFragments(['failed ', '/Us', 'ers/alice/', 'dev', '.', 'p12']),
          exitCode: 1
        })
      ]
    }),
    now: createIsoSequence('2026-08-11T02:00:00.000Z', '2026-08-11T02:00:03.000Z')
  });
  assert.equal(installProof.result, 'incomplete');
  assert.ok(installProof.failures.some((entry) => entry.code === 'HDC_INSTALL_FAILED'));

  const timeoutRepo = await createPhase3TempRepo('phase3-test-timeout');
  const timeoutManifest = await createProductionManifest(timeoutRepo);
  const timeoutProof = await runner.runPhase3SimulatorProof({
    repoRoot: timeoutRepo.repoRoot,
    productionManifestPath: timeoutRepo.manifestPath,
    entryTestHapPath: timeoutRepo.entryTestHapPath,
    fixturePath: timeoutRepo.fixturePath,
    outputPath: timeoutRepo.outputPath,
    buildPhase1NativeImpl: async () => timeoutManifest,
    inspectHapImpl: async () => createInspectionPass(timeoutManifest),
    execImpl: createExecPlan(),
    runTestImpl: async () => createExecResult({ timedOut: true, stderr: 'timeout while running aa test' }),
    now: createIsoSequence('2026-08-11T02:00:00.000Z', '2026-08-11T02:00:02.000Z', '2026-08-11T02:00:03.000Z')
  });
  assert.equal(timeoutProof.result, 'incomplete');
  assert.ok(timeoutProof.failures.some((entry) => entry.code === 'SIMULATOR_TEST_TIMEOUT'));
});

test('Phase 3 runner records real unsigned artifacts before stopping at the signing gate', async () => {
  assert.ok(runner, 'Phase 3 runner module must exist');
  const repo = await createPhase3TempRepo('phase3-unsigned-safe-real-shape');
  const unsignedProductionPath = repo.productionHapPath.replace('-signed.hap', '-unsigned.hap');
  const unsignedEntryTestPath = repo.entryTestHapPath.replace('-signed.hap', '-unsigned.hap');
  await fs.rename(repo.productionHapPath, unsignedProductionPath);
  await fs.rename(repo.entryTestHapPath, unsignedEntryTestPath);

  const manifest = await createProductionManifest({
    ...repo,
    productionHapPath: unsignedProductionPath
  });
  manifest.result = 'incomplete';
  manifest.signing = { result: 'incomplete' };
  manifest.artifacts.hap = {
    identity: 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap',
    ...(await hashFile(unsignedProductionPath))
  };

  const calls = {
    inspect: 0,
    exec: 0,
    runTest: 0
  };

  const proof = await runner.runPhase3SimulatorProof({
    repoRoot: repo.repoRoot,
    productionManifestPath: repo.manifestPath,
    entryTestHapPath: unsignedEntryTestPath,
    fixturePath: repo.fixturePath,
    outputPath: repo.outputPath,
    buildPhase1NativeImpl: async () => manifest,
    inspectHapImpl: async () => {
      calls.inspect += 1;
      throw new Error('inspect should not run for unsigned-safe early exit');
    },
    execImpl: async () => {
      calls.exec += 1;
      throw new Error('hdc should not run for unsigned-safe early exit');
    },
    runTestImpl: async () => {
      calls.runTest += 1;
      throw new Error('aa test should not run for unsigned-safe early exit');
    },
    randomUUID: () => '980cbe02-b817-4db1-99bc-e8e4e6523daf',
    now: createIsoSequence('2026-08-12T03:00:00.000Z', '2026-08-12T03:00:01.000Z')
  });

  assert.equal(proof.result, 'incomplete');
  assert.deepEqual(calls, { inspect: 0, exec: 0, runTest: 0 });
  assert.deepEqual(proof.physicalDeviceGates, {
    phase2Traffic: 'incomplete',
    phase3ProfileRuntime: 'incomplete'
  });
  assert.equal(proof.cleanup.forceStopResult, 'not-run');
  assert.equal(proof.cleanup.uninstallResult, 'not-run');
  assert.equal(proof.cleanup.rebuildDefaultProductionLane, 'not-run');
  assert.equal(proof.cleanup.localPullDirectoryResult, 'pass');
  assert.equal(proof.haps.production.path, 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap');
  assert.deepEqual(
    { sha256: proof.haps.production.sha256, sizeBytes: proof.haps.production.sizeBytes },
    await hashFile(unsignedProductionPath)
  );
  assert.equal(proof.haps.entryTest.path, 'harmony/entry/build/default/outputs/ohosTest/entry-ohosTest-unsigned.hap');
  assert.deepEqual(
    { sha256: proof.haps.entryTest.sha256, sizeBytes: proof.haps.entryTest.sizeBytes },
    await hashFile(unsignedEntryTestPath)
  );
  assert.equal(runner.validatePhase3Proof(proof).valid, true);
  assert.deepEqual(
    proof.failures.map((entry) => entry.code),
    ['INPUT_HAP_UNSIGNED', 'SIGNING_REQUIRED']
  );
  assert.ok(!proof.failures.some((entry) => entry.code === 'PHASE3_SIMULATOR_PROOF_INVALID'));
});

test('Phase 3 pull helper rejects oversized or stale evidence before the runner can claim success', async () => {
  assert.ok(runner, 'Phase 3 runner module must exist');
  const repo = await createPhase3TempRepo('phase3-pull-helper');
  const localPath = path.join(repo.harmonyRoot, 'artifacts', 'phase3-pull', 'phase3-simulator-app-evidence.json');
  const runId = '980cbe02-b817-4db1-99bc-e8e4e6523daf';
  const fixtureHash = digest(repo.fixtureBody);

  await fs.mkdir(path.dirname(localPath), { recursive: true });
  const oversizePayload = `${'a'.repeat((1024 * 1024) + 1)}`;
  await fs.writeFile(localPath, oversizePayload, 'utf8');
  const oversize = await runner.pullPhase3AppEvidence({
    fsApi: await import('node:fs/promises').then((module) => module.default),
    execImpl: async () => createExecResult(),
    hdcCommand: 'hdc',
    target: 'simulator-5554',
    localPath,
    cwd: repo.repoRoot,
    expectedRunId: runId,
    expectedProductionHapSha256: digest('prod-hap'),
    expectedEntryTestHapSha256: digest('test-hap'),
    expectedFixtureSha256: fixtureHash,
    startedAt: new Date('2026-08-11T02:00:00.000Z'),
    remotePath: '/data/storage/el2/base/files/phase3-simulator-app-evidence.json'
  });
  assert.equal(oversize.ok, false);
  assert.equal(oversize.invalid.code, 'APP_EVIDENCE_SIZE_INVALID');

  await fs.writeFile(localPath, JSON.stringify(createSimulatorEvidence({
    runId,
    productionHapSha256: digest('prod-hap'),
    entryTestHapSha256: digest('test-hap'),
    fixtureSha256: fixtureHash
  })), 'utf8');
  const staleTime = new Date('2026-08-10T02:00:00.000Z');
  await fs.utimes(localPath, staleTime, staleTime);
  const stale = await runner.pullPhase3AppEvidence({
    fsApi: await import('node:fs/promises').then((module) => module.default),
    execImpl: async () => createExecResult(),
    hdcCommand: 'hdc',
    target: 'simulator-5554',
    localPath,
    cwd: repo.repoRoot,
    expectedRunId: runId,
    expectedProductionHapSha256: digest('prod-hap'),
    expectedEntryTestHapSha256: digest('test-hap'),
    expectedFixtureSha256: fixtureHash,
    startedAt: new Date('2026-08-11T02:00:00.000Z'),
    remotePath: '/data/storage/el2/base/files/phase3-simulator-app-evidence.json'
  });
  assert.equal(stale.ok, false);
  assert.equal(stale.invalid.code, 'APP_EVIDENCE_STALE');
});

test('Phase 3 runner rejects run/hap identity drift, persists redacted cleanup failures, and can still provisional-pass honestly', async () => {
  assert.ok(runner, 'Phase 3 runner module must exist');
  const repo = await createPhase3TempRepo('phase3-identity-cleanup');
  const manifest = await createProductionManifest(repo);
  const inspection = createInspectionPass(manifest);
  const fixtureDigest = await hashFile(repo.fixturePath);
  const productionDigest = await hashFile(repo.productionHapPath);
  const entryTestDigest = await hashFile(repo.entryTestHapPath);

  const mismatchProof = await runner.runPhase3SimulatorProof({
    repoRoot: repo.repoRoot,
    productionManifestPath: repo.manifestPath,
    entryTestHapPath: repo.entryTestHapPath,
    fixturePath: repo.fixturePath,
    outputPath: repo.outputPath,
    buildPhase1NativeImpl: async () => manifest,
    inspectHapImpl: async () => inspection,
    execImpl: createExecPlan(),
    pullPhase3AppEvidenceImpl: async () => ({
      ok: true,
      localPath: path.join(repo.harmonyRoot, 'artifacts', 'phase3-pull', 'phase3-simulator-app-evidence.json'),
      sha256: digest('evidence'),
      sizeBytes: 128,
      proof: createSimulatorEvidence({
        runId: '5582eb4a-df59-48cb-a3d8-d6e79c7eaebd',
        productionHapSha256: productionDigest.sha256,
        entryTestHapSha256: entryTestDigest.sha256,
        fixtureSha256: fixtureDigest.sha256
      })
    }),
    now: createIsoSequence('2026-08-11T02:00:00.000Z', '2026-08-11T02:00:01.000Z', '2026-08-11T02:00:04.000Z')
  });
  assert.equal(mismatchProof.result, 'incomplete');
  assert.ok(mismatchProof.failures.some((entry) => entry.code === 'APP_EVIDENCE_RUN_ID_MISMATCH'));

  const cleanupProof = await runner.runPhase3SimulatorProof({
    repoRoot: repo.repoRoot,
    productionManifestPath: repo.manifestPath,
    entryTestHapPath: repo.entryTestHapPath,
    fixturePath: repo.fixturePath,
    outputPath: repo.outputPath,
    buildPhase1NativeImpl: async () => manifest,
    inspectHapImpl: async () => inspection,
    execImpl: createExecPlan({
      forceStopResult: createExecResult({
        exitCode: 1,
        stderr: joinFragments(['file', '://', '/Us', 'ers/alice/', 'signing', '.', 'pem', ' cleanup failed'])
      })
    }),
    pullPhase3AppEvidenceImpl: async () => ({
      ok: true,
      localPath: path.join(repo.harmonyRoot, 'artifacts', 'phase3-pull', 'phase3-simulator-app-evidence.json'),
      sha256: digest('evidence'),
      sizeBytes: 128,
      proof: createSimulatorEvidence({
        runId: '980cbe02-b817-4db1-99bc-e8e4e6523daf',
        productionHapSha256: productionDigest.sha256,
        entryTestHapSha256: entryTestDigest.sha256,
        fixtureSha256: fixtureDigest.sha256
      })
    }),
    randomUUID: () => '980cbe02-b817-4db1-99bc-e8e4e6523daf',
    now: createIsoSequence('2026-08-11T02:00:00.000Z', '2026-08-11T02:00:01.000Z', '2026-08-11T02:00:04.000Z', '2026-08-11T02:00:05.000Z')
  });
  assert.equal(cleanupProof.result, 'incomplete');
  assert.ok(cleanupProof.failures.some((entry) => entry.code === 'CLEANUP_FORCE_STOP_FAILED'));
  assert.doesNotMatch(JSON.stringify(cleanupProof), /\/Users\/alice|signing\.pem/u);
  assert.match(JSON.stringify(cleanupProof), /<path>|file:\/\/<redacted>/u);

  const successProof = await runner.runPhase3SimulatorProof({
    repoRoot: repo.repoRoot,
    productionManifestPath: repo.manifestPath,
    entryTestHapPath: repo.entryTestHapPath,
    fixturePath: repo.fixturePath,
    outputPath: repo.outputPath,
    buildPhase1NativeImpl: async ({ phase2SelfTestEnabled = false } = {}) => {
      if (phase2SelfTestEnabled) {
        throw new Error('phase3 simulator proof must never rebuild self-test production manifests');
      }
      return manifest;
    },
    inspectHapImpl: async () => inspection,
    execImpl: createExecPlan(),
    pullPhase3AppEvidenceImpl: async () => ({
      ok: true,
      localPath: path.join(repo.harmonyRoot, 'artifacts', 'phase3-pull', 'phase3-simulator-app-evidence.json'),
      sha256: digest('evidence'),
      sizeBytes: 128,
      proof: createSimulatorEvidence({
        runId: '980cbe02-b817-4db1-99bc-e8e4e6523daf',
        productionHapSha256: productionDigest.sha256,
        entryTestHapSha256: entryTestDigest.sha256,
        fixtureSha256: fixtureDigest.sha256
      })
    }),
    randomUUID: () => '980cbe02-b817-4db1-99bc-e8e4e6523daf',
    now: createIsoSequence('2026-08-11T02:00:00.000Z', '2026-08-11T02:00:01.000Z', '2026-08-11T02:00:04.000Z', '2026-08-11T02:00:05.000Z')
  });
  assert.equal(successProof.result, 'provisional-pass');
  assert.equal(successProof.haps.production.architecture, 'AArch64');
  assert.equal(successProof.haps.production.stubDetected, false);
  assert.deepEqual(successProof.physicalDeviceGates, {
    phase2Traffic: 'incomplete',
    phase3ProfileRuntime: 'incomplete'
  });
  assert.deepEqual(successProof.failures, []);
});

test('Phase 3 provisional-pass rejects misleading suite/check strings, duplicate coverage, and evidence failures', async () => {
  assert.ok(runner, 'Phase 3 runner module must exist');
  const repo = await createPhase3TempRepo('phase3-false-positive');
  const manifest = await createProductionManifest(repo);
  const inspection = createInspectionPass(manifest);
  const fixtureDigest = await hashFile(repo.fixturePath);
  const productionDigest = await hashFile(repo.productionHapPath);
  const entryTestDigest = await hashFile(repo.entryTestHapPath);

  const baseProof = await runner.runPhase3SimulatorProof({
    repoRoot: repo.repoRoot,
    productionManifestPath: repo.manifestPath,
    entryTestHapPath: repo.entryTestHapPath,
    fixturePath: repo.fixturePath,
    outputPath: repo.outputPath,
    buildPhase1NativeImpl: async () => manifest,
    inspectHapImpl: async () => inspection,
    execImpl: createExecPlan(),
    pullPhase3AppEvidenceImpl: async () => ({
      ok: true,
      localPath: path.join(repo.harmonyRoot, 'artifacts', 'phase3-pull', 'phase3-simulator-app-evidence.json'),
      sha256: digest('evidence'),
      sizeBytes: 128,
      proof: createSimulatorEvidence({
        runId: '980cbe02-b817-4db1-99bc-e8e4e6523daf',
        productionHapSha256: productionDigest.sha256,
        entryTestHapSha256: entryTestDigest.sha256,
        fixtureSha256: fixtureDigest.sha256
      })
    }),
    randomUUID: () => '980cbe02-b817-4db1-99bc-e8e4e6523daf',
    now: createIsoSequence('2026-08-11T02:00:00.000Z', '2026-08-11T02:00:01.000Z', '2026-08-11T02:00:04.000Z', '2026-08-11T02:00:05.000Z')
  });
  assert.equal(baseProof.result, 'provisional-pass');

  const wrongCheck = structuredClone(baseProof);
  wrongCheck.appEvidence.checks = [
    'Phase3PlatformAdapters: pass',
    'Phase3RuntimeFlow: fail',
    'Phase3UiFlow: pass'
  ];
  assert.equal(runner.validatePhase3Proof(wrongCheck).valid, false);

  const duplicateSuite = structuredClone(baseProof);
  duplicateSuite.appEvidence.suites = [
    'Phase3PlatformAdapters',
    'Phase3RuntimeFlow',
    'Phase3RuntimeFlow'
  ];
  assert.equal(runner.validatePhase3Proof(duplicateSuite).valid, false);

  const evidenceFailure = structuredClone(baseProof);
  evidenceFailure.appEvidence.failureCount = 1;
  assert.equal(runner.validatePhase3Proof(evidenceFailure).valid, false);
});

test('Phase 3 failure paths persist cleanup and rebuild results to disk before returning', async () => {
  assert.ok(runner, 'Phase 3 runner module must exist');
  const repo = await createPhase3TempRepo('phase3-persisted-cleanup');
  const manifest = await createProductionManifest(repo);
  let buildCount = 0;

  await runner.runPhase3SimulatorProof({
    repoRoot: repo.repoRoot,
    productionManifestPath: repo.manifestPath,
    entryTestHapPath: repo.entryTestHapPath,
    fixturePath: repo.fixturePath,
    outputPath: repo.outputPath,
    buildPhase1NativeImpl: async () => {
      buildCount += 1;
      return manifest;
    },
    inspectHapImpl: async () => createInspectionPass(manifest),
    execImpl: createExecPlan({
      installResults: [
        createExecResult(),
        createExecResult({ exitCode: 1, stderr: 'entry_test install failed' })
      ],
      forceStopResult: createExecResult({ exitCode: 1, stderr: 'force stop failed' }),
      uninstallResult: createExecResult()
    }),
    randomUUID: () => '980cbe02-b817-4db1-99bc-e8e4e6523daf',
    now: createIsoSequence('2026-08-11T02:00:00.000Z', '2026-08-11T02:00:01.000Z', '2026-08-11T02:00:02.000Z')
  });

  const persisted = JSON.parse(await fs.readFile(repo.outputPath, 'utf8'));
  assert.equal(buildCount, 1, 'entry_test install failure happens before test execution and must not trigger a restore build');
  assert.equal(persisted.cleanup.forceStopResult, 'fail');
  assert.equal(persisted.cleanup.uninstallResult, 'pass');
  assert.equal(persisted.cleanup.rebuildDefaultProductionLane, 'not-run');
  assert.equal(persisted.cleanup.localPullDirectoryResult, 'pass');
  assert.ok(persisted.failures.some((entry) => entry.code === 'CLEANUP_FORCE_STOP_FAILED'));
  await assert.rejects(fs.access(path.join(repo.harmonyRoot, 'artifacts', 'phase3-pull', '980cbe02-b817-4db1-99bc-e8e4e6523daf')));
});

test('Phase 3 rebuilds the default production lane only after test execution has actually started', async () => {
  assert.ok(runner, 'Phase 3 runner module must exist');
  const earlyRepo = await createPhase3TempRepo('phase3-rebuild-early');
  const earlyManifest = await createProductionManifest(earlyRepo);
  let earlyBuildCount = 0;

  await runner.runPhase3SimulatorProof({
    repoRoot: earlyRepo.repoRoot,
    productionManifestPath: earlyRepo.manifestPath,
    entryTestHapPath: earlyRepo.entryTestHapPath,
    fixturePath: earlyRepo.fixturePath,
    outputPath: earlyRepo.outputPath,
    buildPhase1NativeImpl: async () => {
      earlyBuildCount += 1;
      return earlyManifest;
    },
    inspectHapImpl: async () => createInspectionPass(earlyManifest),
    execImpl: createExecPlan({ installResults: [createExecResult({ exitCode: 1, stderr: 'prod install failed' })] }),
    randomUUID: () => '980cbe02-b817-4db1-99bc-e8e4e6523daf',
    now: createIsoSequence('2026-08-12T02:00:00.000Z', '2026-08-12T02:00:01.000Z', '2026-08-12T02:00:02.000Z')
  });

  assert.equal(earlyBuildCount, 1, 'install failure before test run must not trigger a restore build');

  const timeoutRepo = await createPhase3TempRepo('phase3-rebuild-timeout');
  const timeoutManifest = await createProductionManifest(timeoutRepo);
  let timeoutBuildCount = 0;

  await runner.runPhase3SimulatorProof({
    repoRoot: timeoutRepo.repoRoot,
    productionManifestPath: timeoutRepo.manifestPath,
    entryTestHapPath: timeoutRepo.entryTestHapPath,
    fixturePath: timeoutRepo.fixturePath,
    outputPath: timeoutRepo.outputPath,
    buildPhase1NativeImpl: async () => {
      timeoutBuildCount += 1;
      return timeoutManifest;
    },
    inspectHapImpl: async () => createInspectionPass(timeoutManifest),
    execImpl: createExecPlan(),
    runTestImpl: async () => createExecResult({ timedOut: true, stderr: 'timeout while running aa test' }),
    randomUUID: () => '980cbe02-b817-4db1-99bc-e8e4e6523daf',
    now: createIsoSequence('2026-08-12T02:00:00.000Z', '2026-08-12T02:00:01.000Z', '2026-08-12T02:00:02.000Z', '2026-08-12T02:00:03.000Z')
  });

  assert.equal(timeoutBuildCount, 2, 'once test execution starts, timeout paths must restore the default production lane');
});

test('Phase 3 runner source reuses shared helper exports for path guards, target classification, and resolved hdc', async () => {
  const [phase3RunnerSource, phase2RunnerSource] = await Promise.all([
    fs.readFile(PHASE3_RUNNER_SOURCE_PATH, 'utf8'),
    fs.readFile(PHASE2_RUNNER_SOURCE_PATH, 'utf8')
  ]);

  assert.match(phase2RunnerSource, /export\s+function\s+classifyHarmonyTarget\(/u,
    'Phase 2 runner must export a reusable Harmony target classifier'
  );
  assert.match(phase2RunnerSource, /export\s+async\s+function\s+resolveExistingRepoScopedPath\(/u,
    'Phase 2 runner must export the repo-scoped existing-path guard'
  );
  assert.match(phase2RunnerSource, /export\s+async\s+function\s+resolveRepoScopedOutputPath\(/u,
    'Phase 2 runner must export the repo-scoped output-path guard'
  );
  assert.match(phase2RunnerSource, /export\s+async\s+function\s+hashRepoFile\(/u,
    'Phase 2 runner must export the repo-scoped file hasher'
  );
  assert.match(phase2RunnerSource, /export\s+async\s+function\s+resolveHdcCommand\(/u,
    'Phase 2 runner must export the resolved hdc command helper'
  );
  assert.doesNotMatch(phase3RunnerSource, /function\s+inferTargetKind\(/u,
    'Phase 3 runner must not keep a local target classifier copy'
  );
  assert.doesNotMatch(phase3RunnerSource, /async\s+function\s+resolveExistingRepoScopedPath\(/u,
    'Phase 3 runner must not keep a local existing-path guard copy'
  );
  assert.doesNotMatch(phase3RunnerSource, /async\s+function\s+resolveRepoScopedOutputPath\(/u,
    'Phase 3 runner must not keep a local output-path guard copy'
  );
  assert.doesNotMatch(phase3RunnerSource, /let\s+hdcCommand\s*=\s*['"`]hdc['"`]/u,
    'Phase 3 runner must not hardcode hdc from PATH'
  );
});

test('Phase 3 runner uses the resolved hdc path and aa test string parameters, never an opaque -w payload', async () => {
  assert.ok(runner, 'Phase 3 runner module must exist');
  const repo = await createPhase3TempRepo('phase3-resolved-hdc');
  const manifest = await createProductionManifest(repo);
  const commands = [];

  const proof = await runner.runPhase3SimulatorProof({
    repoRoot: repo.repoRoot,
    productionManifestPath: repo.manifestPath,
    entryTestHapPath: repo.entryTestHapPath,
    fixturePath: repo.fixturePath,
    outputPath: repo.outputPath,
    buildPhase1NativeImpl: async () => manifest,
    inspectHapImpl: async () => createInspectionPass(manifest),
    toolchainInspectorImpl: async () => ({
      report: { result: 'pass' },
      resolved: { paths: { hdc: '/sdk/ohos/bin/hdc' } }
    }),
    execImpl: async (command, args) => {
      commands.push([command, ...args]);
      if (args[0] === 'list' && args[1] === 'targets') {
        return createExecResult({ stdout: 'simulator-5554\n' });
      }
      if (args.includes('const.product.model')) return createExecResult({ stdout: 'HarmonyOS Simulator\n' });
      if (args.includes('const.product.name')) return createExecResult({ stdout: 'openharmony-simulator\n' });
      if (args.includes('const.product.software.version')) return createExecResult({ stdout: 'HarmonyOS 6.0.0\n' });
      if (args.includes('const.ohos.apiversion')) return createExecResult({ stdout: '20\n' });
      if (args.includes('const.product.cpu.abilist')) return createExecResult({ stdout: 'arm64-v8a\n' });
      if (args.includes('install')) return createExecResult();
      if (args.includes('aa') && args.includes('test')) return createExecResult({ timedOut: true, stderr: 'timeout' });
      if (args.includes('force-stop') || args.includes('uninstall')) return createExecResult();
      return createExecResult();
    },
    randomUUID: () => '980cbe02-b817-4db1-99bc-e8e4e6523daf',
    now: createIsoSequence('2026-08-11T02:00:00.000Z', '2026-08-11T02:00:01.000Z', '2026-08-11T02:00:02.000Z', '2026-08-11T02:00:03.000Z')
  });

  assert.equal(proof.result, 'incomplete');
  assert.equal(commands[0][0], '/sdk/ohos/bin/hdc');
  const aaTestCommand = commands.find((entry) => entry.includes('aa') && entry.includes('test'));
  assert.ok(aaTestCommand, 'runner must invoke aa test');
  assert.ok(aaTestCommand.includes('-s'));
  assert.ok(aaTestCommand.includes('cmfa.phase3.runId'));
  assert.ok(!aaTestCommand.includes('-w'));
});
