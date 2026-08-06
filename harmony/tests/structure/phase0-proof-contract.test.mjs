import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const buildModulePath = new URL('../bin/build-hap.mjs', import.meta.url);
const runnerModulePath = new URL('../bin/run-phase0-device-proof.mjs', import.meta.url);
const schemaPath = new URL('../fixtures/phase0-device-proof.schema.json', import.meta.url);
const examplePath = new URL('../fixtures/phase0-device-proof.example.json', import.meta.url);

function createSpawnSequence(results) {
  let index = 0;

  return function spawnStub() {
    const current = results[index];
    index += 1;

    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();

    queueMicrotask(() => {
      if (current?.stdout) {
        child.stdout.emit('data', Buffer.from(current.stdout));
      }

      if (current?.stderr) {
        child.stderr.emit('data', Buffer.from(current.stderr));
      }

      if (current?.error) {
        child.emit('error', current.error);
      }

      child.emit('close', current?.exitCode ?? 0, current?.signal ?? null);
    });

    return child;
  };
}

function createAcceptedHdcHelpResult(command, args) {
  return {
    command,
    args,
    exitCode: 0,
    stdout: [
      '-t connectkey',
      'list targets [-v]',
      'install [-r|-s|-cwd|option] src',
      'shell [-b bundlename] [COMMAND...]'
    ].join('\n'),
    stderr: '',
    error: null
  };
}

function joinFragments(parts) {
  return parts.join('');
}

async function writeToolchainLock(harmonyRoot) {
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.lock.json'), JSON.stringify({
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hvigorVersion: '6.23.7',
      ohpmVersion: '6.1.1.830',
      hdcVersion: '6.1.0.105'
    }
  }), 'utf8');
}

function createPassingBuildEvidenceObject({ harmonyRoot, hapPath, sha256 }) {
  return {
    schemaVersion: '1.0.0',
    phase: 0,
    result: 'pass',
    outputPath: 'harmony/artifacts/phase0-build-evidence.json',
    timestamps: {
      startedAt: '2026-07-31T12:00:00.000Z',
      completedAt: '2026-07-31T12:00:05.000Z'
    },
    toolchain: {
      nodeVersion: '22.17.0',
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hvigorVersion: '6.23.7',
      ohpmVersion: '6.1.1.830',
      hdcVersion: '6.1.0.105'
    },
    wrapper: {
      path: 'harmony/hvigorw',
      executable: true
    },
    phase2SelfTest: createPhase2SelfTestEvidence(false),
    commands: [],
    hap: {
      path: path.relative(path.resolve(harmonyRoot, '..'), hapPath).split(path.sep).join('/'),
      sha256,
      sizeBytes: 10
    },
    failures: []
  };
}

function createPhase2SelfTestEvidence(enabled) {
  return {
    enabled,
    activation: enabled ? 'explicit' : 'default',
    purpose: enabled ? 'test-only' : 'production',
    releaseStatus: enabled ? 'not-releasable' : 'releasable'
  };
}

async function writePassingBuildEvidence({ harmonyRoot, hapPath, sha256, outputPath }) {
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, `${JSON.stringify(createPassingBuildEvidenceObject({ harmonyRoot, hapPath, sha256 }), null, 2)}\n`, 'utf8');
}

test('phase0 proof contract exports deterministic helpers and a validating incomplete example', async () => {
  const originalExitCode = process.exitCode;
  const [{ buildHap, findDebugHapCandidates, parseCliArguments: buildParseCliArguments, runCli: buildRunCli }, runnerModule, schemaRaw, exampleRaw] = await Promise.all([
    import(buildModulePath),
    import(runnerModulePath),
    fs.readFile(schemaPath, 'utf8'),
    fs.readFile(examplePath, 'utf8')
  ]);

  const {
    BUNDLE_NAME,
    DEFAULT_OUTPUT_PATH,
    ENTRY_ABILITY_NAME,
    PROOF_SCHEMA_VERSION,
    parseCliArguments,
    runCli,
    createMaskedDeviceIdentity,
    validatePhase0Proof
  } = runnerModule;

  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(typeof buildHap, 'function');
  assert.equal(typeof findDebugHapCandidates, 'function');
  assert.equal(typeof buildParseCliArguments, 'function');
  assert.equal(typeof buildRunCli, 'function');
  assert.equal(typeof parseCliArguments, 'function');
  assert.equal(typeof runCli, 'function');
  assert.match(DEFAULT_OUTPUT_PATH, /\/harmony\/artifacts\/phase0-device-proof\.json$/u);
  assert.doesNotMatch(DEFAULT_OUTPUT_PATH, /\/harmony\/harmony\//u);
  assert.equal(PROOF_SCHEMA_VERSION, '1.0.0');
  assert.equal(BUNDLE_NAME, 'com.github.kr328.clash.harmony');
  assert.equal(ENTRY_ABILITY_NAME, 'EntryAbility');
  assert.equal(process.exitCode, originalExitCode);
  assert.equal(createMaskedDeviceIdentity('ABC123XYZ'), createMaskedDeviceIdentity('ABC123XYZ'));
  assert.notEqual(createMaskedDeviceIdentity('ABC123XYZ'), createMaskedDeviceIdentity('ZYX321CBA'));

  const schema = JSON.parse(schemaRaw);
  const example = JSON.parse(exampleRaw);
  const exampleValidation = validatePhase0Proof(example, { schema });

  assert.equal(exampleValidation.valid, true, exampleValidation.errors.join('\n'));
  assert.equal(example.schemaVersion, PROOF_SCHEMA_VERSION);
  assert.equal(example.phase, 0);
  assert.equal(example.result, 'incomplete');
  assert.equal(example.bundle, BUNDLE_NAME);
  assert.equal(example.ability, ENTRY_ABILITY_NAME);
  assert.match(example.hap.sha256, /^[a-f0-9]{64}$/u);
  assert.equal(example.device.identityMasked.includes('example'), false);
  assert.equal(example.device.serial, undefined);
  assert.ok(example.failures.some((entry) => entry.code === 'DEVICE_TARGET_MISSING'));
  assert.ok(example.failures.some((entry) => entry.code === 'SIGNING_REQUIRED'));
});

test('phase0 build helper CLI requires explicit self-test flags and forwards strict evidence options', async () => {
  const { parseCliArguments, runCli } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-build-cli-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const customOut = path.join(repoRoot, 'harmony', 'artifacts', 'phase0-build-custom.json');
  const hapPath = path.join(harmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');

  await fs.mkdir(harmonyRoot, { recursive: true });

  assert.deepEqual(parseCliArguments([], repoRoot), {
    outputPath: path.join(repoRoot, 'harmony', 'artifacts', 'phase0-build-evidence.json'),
    phase2SelfTestEnabled: false
  });
  assert.deepEqual(parseCliArguments(['--phase2-self-test'], repoRoot), {
    outputPath: path.join(repoRoot, 'harmony', 'artifacts', 'phase0-build-evidence.json'),
    phase2SelfTestEnabled: true
  });
  assert.deepEqual(parseCliArguments(['--out', 'harmony/artifacts/custom.json', '--phase2-self-test'], repoRoot), {
    outputPath: path.join(repoRoot, 'harmony', 'artifacts', 'custom.json'),
    phase2SelfTestEnabled: true
  });

  for (const argv of [
    ['--out'],
    ['--out', 'one.json', '--out', 'two.json'],
    ['--phase2-self-test', '--phase2-self-test'],
    ['--unknown']
  ]) {
    assert.throws(
      () => parseCliArguments(argv, repoRoot),
      (error) => ['ARGUMENT_INVALID', 'PATH_OUTSIDE_REPO'].includes(error?.code),
      `expected ${argv.join(' ')} to fail`
    );
  }

  let observedOptions = null;
  let observedWrite = null;
  try {
    const exitCode = await runCli({
      argv: ['--out', 'harmony/artifacts/phase0-build-custom.json', '--phase2-self-test'],
      repoRoot,
      buildHapImpl: async (options) => {
        observedOptions = options;
        return {
          ...createPassingBuildEvidenceObject({
            harmonyRoot,
            hapPath,
            sha256: 'a'.repeat(64)
          }),
          outputPath: 'harmony/artifacts/phase0-build-custom.json',
          phase2SelfTest: createPhase2SelfTestEvidence(true)
        };
      },
      writeBuildEvidenceImpl: async (report, outputPath) => {
        observedWrite = { report, outputPath };
      },
      stdout: { write() {} }
    });

    assert.equal(exitCode, 0);
    assert.equal(observedOptions.outputPath, customOut);
    assert.equal(observedOptions.phase2SelfTestEnabled, true);
    assert.equal(observedWrite.outputPath, await fs.realpath(path.dirname(customOut)).then((realParent) => path.join(realParent, path.basename(customOut))));
    assert.deepEqual(observedWrite.report.phase2SelfTest, createPhase2SelfTestEvidence(true));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 build helper rejects repo-local symlink output parents that resolve outside the repository', async () => {
  const { runCli } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-build-out-symlink-parent-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const outsideRoot = path.join(tempRoot, 'outside');
  const linkedArtifacts = path.join(harmonyRoot, 'artifacts-link');
  const outsideOutput = path.join(outsideRoot, 'evidence.json');
  let buildInvoked = false;

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.mkdir(outsideRoot, { recursive: true });
  await fs.symlink(outsideRoot, linkedArtifacts);

  try {
    const exitCode = await runCli({
      argv: ['--out', 'harmony/artifacts-link/evidence.json'],
      repoRoot,
      buildHapImpl: async () => {
        buildInvoked = true;
        return createPassingBuildEvidenceObject({
          harmonyRoot,
          hapPath: path.join(harmonyRoot, 'entry-default-signed.hap'),
          sha256: 'b'.repeat(64)
        });
      },
      stdout: { write() {} },
      stderr: { write() {} }
    });

    assert.equal(exitCode, 2);
    assert.equal(buildInvoked, false);
    await assert.rejects(fs.access(outsideOutput));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 build helper rejects repo-local symlink output targets and does not write through them', async () => {
  const { runCli } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-build-out-symlink-target-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const artifactsRoot = path.join(harmonyRoot, 'artifacts');
  const outsideRoot = path.join(tempRoot, 'outside');
  const outsideOutput = path.join(outsideRoot, 'outside-evidence.json');
  const linkedOutput = path.join(artifactsRoot, 'linked-evidence.json');
  let buildInvoked = false;

  await fs.mkdir(artifactsRoot, { recursive: true });
  await fs.mkdir(outsideRoot, { recursive: true });
  await fs.writeFile(outsideOutput, 'outside-sentinel', 'utf8');
  await fs.symlink(outsideOutput, linkedOutput);

  try {
    const exitCode = await runCli({
      argv: ['--out', 'harmony/artifacts/linked-evidence.json'],
      repoRoot,
      buildHapImpl: async () => {
        buildInvoked = true;
        return createPassingBuildEvidenceObject({
          harmonyRoot,
          hapPath: path.join(harmonyRoot, 'entry-default-signed.hap'),
          sha256: 'c'.repeat(64)
        });
      },
      stdout: { write() {} },
      stderr: { write() {} }
    });

    assert.equal(exitCode, 2);
    assert.equal(buildInvoked, false);
    assert.equal(await fs.readFile(outsideOutput, 'utf8'), 'outside-sentinel');
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 build helper creates legal nested repo-scoped output parents and writes evidence there', async () => {
  const { runCli } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-build-out-nested-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const hapPath = path.join(harmonyRoot, 'entry-default-signed.hap');
  const outputPath = path.join(harmonyRoot, 'artifacts', 'nested', 'deeper', 'phase0-build.json');

  await fs.mkdir(harmonyRoot, { recursive: true });

  try {
    const exitCode = await runCli({
      argv: ['--out', 'harmony/artifacts/nested/deeper/phase0-build.json'],
      repoRoot,
      buildHapImpl: async () => createPassingBuildEvidenceObject({
        harmonyRoot,
        hapPath,
        sha256: 'd'.repeat(64)
      }),
      stdout: { write() {} },
      stderr: { write() {} }
    });

    assert.equal(exitCode, 0);
    const persisted = JSON.parse(await fs.readFile(outputPath, 'utf8'));
    assert.equal(persisted.outputPath, 'harmony/artifacts/phase0-build-evidence.json');
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 build helper fatal catch writes strict fail evidence to a legal repo-scoped custom --out path', async () => {
  const { runCli } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-build-fatal-out-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const outputPath = path.join(harmonyRoot, 'artifacts', 'fatal', 'phase0-build.json');

  await fs.mkdir(harmonyRoot, { recursive: true });

  try {
    const exitCode = await runCli({
      argv: ['--out', 'harmony/artifacts/fatal/phase0-build.json'],
      repoRoot,
      buildHapImpl: async () => {
        throw Object.assign(new Error('boom'), { code: 'BOOM' });
      },
      stdout: { write() {} },
      stderr: { write() {} }
    });

    const persisted = JSON.parse(await fs.readFile(outputPath, 'utf8'));
    assert.equal(exitCode, 2);
    assert.equal(persisted.outputPath, 'harmony/artifacts/fatal/phase0-build.json');
    assert.ok(persisted.failures.some((entry) => entry.code === 'BOOM'));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 proof schema declares only known top-level fields', async () => {
  const schema = JSON.parse(await fs.readFile(schemaPath, 'utf8'));
  const example = JSON.parse(await fs.readFile(examplePath, 'utf8'));

  assert.equal(schema.additionalProperties, false);
  assert.ok(schema.properties.outputPath);
  assert.ok(schema.properties.targetDiscovery);
  assert.ok(schema.properties.cleanup);
  assert.ok(schema.required.includes('outputPath'));
  assert.ok(schema.required.includes('cleanup'));
  assert.ok(schema.required.includes('targetDiscovery'));
  assert.equal(schema.$defs.step.additionalProperties, false);
  assert.equal(schema.$defs.failure.additionalProperties, false);
  assert.equal(example.outputPath, 'harmony/artifacts/phase0-device-proof.json');
  assert.deepEqual(example.targetDiscovery, {
    command: ['hdc', 'list', 'targets'],
    count: 0,
    identitiesMasked: []
  });
  assert.deepEqual(example.build.command, [
    'harmony/hvigorw',
    '--mode',
    'module',
    '-p',
    'module=entry@default',
    '-p',
    'product=default',
    '-p',
    'buildMode=debug',
    'assembleHap'
  ]);
});

test('phase0 proof validator accepts the always-write missing-hap incomplete shape', async () => {
  const [{ runPhase0DeviceProof, validatePhase0Proof }, schemaRaw] = await Promise.all([
    import(runnerModulePath),
    fs.readFile(schemaPath, 'utf8')
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-missing-hap-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.lock.json'), JSON.stringify({
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hvigorVersion: '6.23.7',
      ohpmVersion: '6.1.1.830',
      hdcVersion: '6.1.0.105'
    }
  }), 'utf8');

  try {
    const proof = await runPhase0DeviceProof({
      harmonyRoot,
      outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-device-proof.json')
    });

    const validation = validatePhase0Proof(proof, { schema: JSON.parse(schemaRaw) });
    assert.equal(proof.result, 'incomplete');
    assert.equal(proof.hap.path, null);
    assert.equal(proof.hap.sha256, null);
    assert.equal(validation.valid, true, validation.errors.join('\n'));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 proof contract accepts pass only when build, install, and launch all pass', async () => {
  const { validatePhase0Proof } = await import(runnerModulePath);

  const validPass = {
    schemaVersion: '1.0.0',
    phase: 0,
    result: 'pass',
    bundle: 'com.github.kr328.clash.harmony',
    ability: 'EntryAbility',
    timestamps: {
      startedAt: '2026-07-31T12:00:00.000Z',
      completedAt: '2026-07-31T12:00:10.000Z'
    },
    toolchain: {
      nodeVersion: '22.17.0',
      hvigorVersion: '6.23.7',
      ohpmVersion: '6.1.1.830',
      hdcVersion: '6.1.0.105',
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105'
    },
    hap: {
      path: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
      sha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    },
    device: {
      identityMasked: 'target-6a9f2e31',
      buildVersion: '6.1.0.123(C00E123R4P5)',
      apiVersion: '20',
      abi: 'arm64-v8a',
      model: 'HMA-AL00'
    },
    build: { result: 'pass' },
    install: { result: 'pass' },
    launch: { result: 'pass' },
    cleanup: {
      forceStop: { result: 'pass' }
    },
    failures: []
  };

  const invalidPass = structuredClone(validPass);
  invalidPass.launch.result = 'fail';
  const invalidCleanupPass = structuredClone(validPass);
  invalidCleanupPass.cleanup.forceStop.result = 'fail';

  assert.deepEqual(validatePhase0Proof(validPass), { valid: true, errors: [] });
  assert.equal(validatePhase0Proof(invalidPass).valid, false);
  assert.equal(validatePhase0Proof(invalidCleanupPass).valid, false);
});

test('phase0 proof contract rejects leaked serials and unordered timestamps', async () => {
  const { validatePhase0Proof } = await import(runnerModulePath);

  const invalidProof = {
    schemaVersion: '1.0.0',
    phase: 0,
    result: 'incomplete',
    bundle: 'com.github.kr328.clash.harmony',
    ability: 'EntryAbility',
    timestamps: {
      startedAt: '2026-07-31T12:00:10.000Z',
      completedAt: '2026-07-31T12:00:00.000Z'
    },
    toolchain: {
      nodeVersion: '22.17.0',
      hvigorVersion: '6.23.7',
      ohpmVersion: '6.1.1.830',
      hdcVersion: '6.1.0.105',
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105'
    },
    hap: {
      path: 'harmony/artifacts/example-signed.hap',
      sha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    },
    device: {
      identityMasked: 'SERIAL-123456',
      serial: 'SERIAL-123456',
      buildVersion: null,
      apiVersion: null,
      abi: null,
      model: null
    },
    build: { result: 'pass' },
    install: { result: 'not-run' },
    launch: { result: 'not-run' },
    failures: [{ code: 'DEVICE_TARGET_MISSING', stage: 'device', detail: 'No authorized device target detected.' }]
  };

  const validation = validatePhase0Proof(invalidProof);
  assert.equal(validation.valid, false);
  assert.ok(validation.errors.some((entry) => /timestamps/u.test(entry)));
  assert.ok(validation.errors.some((entry) => /serial/u.test(entry)));
});

test('phase0 build helper only accepts the direct module debug hap and excludes assembleApp staging copies', async () => {
  const { findDebugHapCandidates, selectDebugHapCandidate } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-hap-'));
  const firstCandidate = path.join(tempRoot, 'entry/build/default/outputs/default/entry-default-unsigned.hap');
  const secondCandidate = path.join(tempRoot, 'entry/build/default/outputs/default/app/entry-default.hap');
  const ignoredCandidate = path.join(tempRoot, 'entry/build/release/outputs/release/entry-release-signed.hap');

  await fs.mkdir(path.dirname(firstCandidate), { recursive: true });
  await fs.mkdir(path.dirname(secondCandidate), { recursive: true });
  await fs.mkdir(path.dirname(ignoredCandidate), { recursive: true });
  await fs.writeFile(firstCandidate, 'one', 'utf8');
  await fs.writeFile(secondCandidate, 'two', 'utf8');
  await fs.writeFile(ignoredCandidate, 'three', 'utf8');

  try {
    const candidates = await findDebugHapCandidates({ harmonyRoot: tempRoot });
    assert.deepEqual(candidates.map((entry) => path.relative(tempRoot, entry)), [
      'entry/build/default/outputs/default/entry-default-unsigned.hap'
    ]);
    assert.equal(selectDebugHapCandidate([firstCandidate]), firstCandidate);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 build helper prefers the signed module debug hap when signed and unsigned outputs coexist', async () => {
  const { findDebugHapCandidates, selectDebugHapCandidate } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-hap-signed-preferred-'));
  const unsignedCandidate = path.join(tempRoot, 'entry/build/default/outputs/default/entry-default-unsigned.hap');
  const signedCandidate = path.join(tempRoot, 'entry/build/default/outputs/default/entry-default-signed.hap');

  await fs.mkdir(path.dirname(unsignedCandidate), { recursive: true });
  await fs.writeFile(unsignedCandidate, 'unsigned', 'utf8');
  await fs.writeFile(signedCandidate, 'signed', 'utf8');

  try {
    const candidates = await findDebugHapCandidates({ harmonyRoot: tempRoot });
    assert.deepEqual(candidates.map((entry) => path.relative(tempRoot, entry)), [
      'entry/build/default/outputs/default/entry-default-signed.hap',
      'entry/build/default/outputs/default/entry-default-unsigned.hap'
    ]);
    assert.equal(selectDebugHapCandidate(candidates), signedCandidate);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 build helper keeps multiple signed module debug haps ambiguous', async () => {
  const { selectDebugHapCandidate } = await import(buildModulePath);

  assert.throws(
    () => selectDebugHapCandidate([
      '/tmp/entry-default-signed.hap',
      '/tmp/entry-default-signed-copy.hap'
    ]),
    (error) => error?.code === 'HAP_AMBIGUOUS'
  );
});

test('phase0 build helper reports WRAPPER_MISSING before any spawn attempt', async () => {
  const { DEFAULT_EVIDENCE_PATH, buildHap } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-wrapper-'));
  let spawnCount = 0;

  try {
    assert.match(DEFAULT_EVIDENCE_PATH, /\/harmony\/artifacts\/phase0-build-evidence\.json$/u);
    assert.doesNotMatch(DEFAULT_EVIDENCE_PATH, /\/harmony\/harmony\//u);

    const report = await buildHap({
      harmonyRoot: tempRoot,
      outputPath: path.join(tempRoot, 'artifacts', 'phase0-build-evidence.json'),
      spawnImpl() {
        spawnCount += 1;
        throw new Error('spawn should not be called when hvigorw is missing');
      }
    });

    assert.equal(report.result, 'fail');
    assert.ok(report.failures.some((entry) => entry.code === 'WRAPPER_MISSING'));
    assert.equal(spawnCount, 0);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 build helper marks unsigned exit0 outputs incomplete and redacts repo and home paths', async () => {
  const { buildHap } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-build-unsigned-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const wrapperPath = path.join(harmonyRoot, 'hvigorw');
  const unsignedHapPath = path.join(harmonyRoot, 'entry/build/default/outputs/default/entry-default-unsigned.hap');
  const repoLeak = path.join(tempRoot, 'repo-leak.txt');
  const homeLeak = path.join(os.homedir(), 'daemon-sec.json.lock');

  await fs.mkdir(path.dirname(wrapperPath), { recursive: true });
  await fs.writeFile(wrapperPath, '#!/bin/sh\n', 'utf8');
  await fs.chmod(wrapperPath, 0o755);
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.lock.json'), JSON.stringify({
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hvigorVersion: '6.23.7',
      ohpmVersion: '6.1.1.830',
      hdcVersion: '6.1.0.105'
    }
  }), 'utf8');

  try {
    let spawnIndex = 0;
    const report = await buildHap({
      harmonyRoot,
      outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json'),
      spawnImpl() {
        spawnIndex += 1;
        const current = spawnIndex === 1
          ? {
            exitCode: 0,
            stderr: `BUILD SUCCESSFUL\nWill skip sign 'hos_hap'. No signingConfigs profile for ${repoLeak} and ${homeLeak}\n`
          }
          : {
            exitCode: 0,
            stderr: `BUILD SUCCESSFUL\nWill skip sign 'hos_app'. No signingConfigs profile for ${repoLeak} and ${homeLeak}\n`
          };

        const child = new EventEmitter();
        child.stdout = new EventEmitter();
        child.stderr = new EventEmitter();

        queueMicrotask(async () => {
          if (spawnIndex === 1) {
            await fs.mkdir(path.dirname(unsignedHapPath), { recursive: true });
            await fs.writeFile(unsignedHapPath, 'unsigned-hap', 'utf8');
          }

          child.stderr.emit('data', Buffer.from(current.stderr));
          child.emit('close', current.exitCode, null);
        });

        return child;
      }
    });

    const persisted = JSON.stringify(report);
    assert.equal(report.result, 'incomplete');
    assert.equal(report.hap.path, 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap');
    assert.ok(report.failures.some((entry) => entry.code === 'SIGNING_REQUIRED'));
    assert.doesNotMatch(persisted, /\/Users\//u);
    assert.doesNotMatch(persisted, new RegExp(os.homedir().replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u'));
    assert.doesNotMatch(persisted, new RegExp(tempRoot.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u'));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 build helper rejects stale signed hap artifacts when this build produced no fresh module output', async () => {
  const { buildHap } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-build-stale-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const wrapperPath = path.join(harmonyRoot, 'hvigorw');
  const staleHapPath = path.join(harmonyRoot, 'entry/build/default/outputs/default/entry-default-signed.hap');
  const preservedNeighborPath = path.join(harmonyRoot, 'entry/build/default/intermediates/keep.txt');

  await fs.mkdir(path.dirname(wrapperPath), { recursive: true });
  await fs.mkdir(path.dirname(staleHapPath), { recursive: true });
  await fs.mkdir(path.dirname(preservedNeighborPath), { recursive: true });
  await fs.writeFile(wrapperPath, '#!/bin/sh\n', 'utf8');
  await fs.chmod(wrapperPath, 0o755);
  await fs.writeFile(staleHapPath, 'stale-signed-hap', 'utf8');
  await fs.writeFile(preservedNeighborPath, 'preserve-me', 'utf8');
  await writeToolchainLock(harmonyRoot);

  try {
    const report = await buildHap({
      harmonyRoot,
      outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json'),
      spawnImpl: createSpawnSequence([
        {
          exitCode: 0,
          stdout: 'BUILD SUCCESSFUL\n'
        },
        {
          exitCode: 0,
          stdout: 'BUILD SUCCESSFUL\n'
        }
      ])
    });

    assert.notEqual(report.result, 'pass');
    assert.equal(report.hap.path, null);
    assert.equal(report.hap.sha256, null);
    assert.ok(report.failures.some((entry) => entry.code === 'HAP_NOT_FOUND'));
    await assert.rejects(fs.access(staleHapPath));
    await fs.access(preservedNeighborPath);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 build helper stages the raw core into src/main/libs for packaging and removes the staging copy afterwards', async () => {
  const { buildHap } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-build-stage-core-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const wrapperPath = path.join(harmonyRoot, 'hvigorw');
  const rawCorePath = path.join(harmonyRoot, 'artifacts', 'libcmfa_mihomo.so');
  const stagedCorePath = path.join(harmonyRoot, 'entry', 'src', 'main', 'libs', 'arm64-v8a', 'libcmfa_mihomo.so');
  const hapPath = path.join(harmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
  let spawnCalls = 0;

  await fs.mkdir(path.dirname(wrapperPath), { recursive: true });
  await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
  await fs.writeFile(wrapperPath, '#!/bin/sh\n', 'utf8');
  await fs.chmod(wrapperPath, 0o755);
  await fs.writeFile(rawCorePath, 'raw-core-bytes', 'utf8');
  await writeToolchainLock(harmonyRoot);

  try {
    const report = await buildHap({
      harmonyRoot,
      outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json'),
      spawnImpl(command, args) {
        spawnCalls += 1;
        const child = new EventEmitter();
        child.stdout = new EventEmitter();
        child.stderr = new EventEmitter();

        queueMicrotask(async () => {
          const stagedBytes = await fs.readFile(stagedCorePath, 'utf8');
          assert.equal(stagedBytes, 'raw-core-bytes');
          if (spawnCalls === 1) {
            await fs.mkdir(path.dirname(hapPath), { recursive: true });
            await fs.writeFile(hapPath, 'signed-hap', 'utf8');
          }
          child.stdout.emit('data', Buffer.from('BUILD SUCCESSFUL\n'));
          child.emit('close', 0, null);
        });

        return child;
      }
    });

    assert.equal(report.result, 'pass');
    assert.equal(spawnCalls, 4);
    await assert.rejects(fs.access(stagedCorePath));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 build helper stamps strict self-test evidence and clears stale lane env by default', async () => {
  const { buildHap } = await import(buildModulePath);

  for (const variant of [
    { label: 'production', enabled: false, expected: createPhase2SelfTestEvidence(false) },
    { label: 'self-test', enabled: true, expected: createPhase2SelfTestEvidence(true) }
  ]) {
    const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), `phase0-build-lane-${variant.label}-`));
    const harmonyRoot = path.join(tempRoot, 'harmony');
    const wrapperPath = path.join(harmonyRoot, 'hvigorw');
    const hapPath = path.join(harmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
    const observedEnvs = [];

    await fs.mkdir(path.dirname(wrapperPath), { recursive: true });
    await fs.writeFile(wrapperPath, '#!/bin/sh\n', 'utf8');
    await fs.chmod(wrapperPath, 0o755);
    await writeToolchainLock(harmonyRoot);

    try {
      const report = await buildHap({
        harmonyRoot,
        outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json'),
        env: {
          ...process.env,
          CMFA_ENABLE_PHASE2_SELFTEST: '1',
          CMFA_TEST_BUILD_ABI: '1'
        },
        phase2SelfTestEnabled: variant.enabled,
        spawnImpl(command, args, options) {
          observedEnvs.push(options.env);
          const child = new EventEmitter();
          child.stdout = new EventEmitter();
          child.stderr = new EventEmitter();

          queueMicrotask(async () => {
            if (args.includes('assembleHap')) {
              await fs.mkdir(path.dirname(hapPath), { recursive: true });
              await fs.writeFile(hapPath, 'signed-hap', 'utf8');
            }
            child.stdout.emit('data', Buffer.from('BUILD SUCCESSFUL\n'));
            child.emit('close', 0, null);
          });

          return child;
        }
      });

      assert.equal(report.result, 'pass');
      assert.deepEqual(report.phase2SelfTest, variant.expected);
      assert.equal(observedEnvs.length, 2);
      for (const observedEnv of observedEnvs) {
        assert.equal(observedEnv.CMFA_ENABLE_PHASE2_SELFTEST, variant.enabled ? '1' : undefined, `${variant.label} lane must control CMFA_ENABLE_PHASE2_SELFTEST explicitly`);
        assert.equal(observedEnv.CMFA_TEST_BUILD_ABI, variant.enabled ? '1' : undefined, `${variant.label} lane must control CMFA_TEST_BUILD_ABI explicitly`);
      }
    } finally {
      await fs.rm(tempRoot, { recursive: true, force: true });
    }
  }
});

test('phase0 build helper times out hung hvigor, kills it, and returns fail evidence without waiting for close', async () => {
  const { buildHap } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-build-timeout-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const wrapperPath = path.join(harmonyRoot, 'hvigorw');
  let killCount = 0;

  await fs.mkdir(path.dirname(wrapperPath), { recursive: true });
  await fs.writeFile(wrapperPath, '#!/bin/sh\n', 'utf8');
  await fs.chmod(wrapperPath, 0o755);
  await writeToolchainLock(harmonyRoot);

  try {
    const report = await buildHap({
      harmonyRoot,
      outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json'),
      commandTimeoutMs: 10,
      spawnImpl() {
        let killed = false;
        const child = new EventEmitter();
        child.stdout = new EventEmitter();
        child.stderr = new EventEmitter();
        child.kill = () => {
          killed = true;
          killCount += 1;
          return true;
        };

        setTimeout(() => {
          child.stderr.emit('data', Buffer.from('still running\n'));
          if (!killed) {
            child.emit('close', 0, null);
          }
        }, 50);

        return child;
      }
    });

    assert.equal(report.result, 'fail');
    assert.equal(killCount, 1);
    assert.ok(report.failures.some((entry) => entry.code === 'BUILD_TIMEOUT'));
    assert.equal(report.hap.path, null);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 build helper redacts external absolute paths, file URLs, and signing material tokens without breaking normal URLs', async () => {
  const { buildHap } = await import(buildModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-build-sanitize-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const wrapperPath = path.join(harmonyRoot, 'hvigorw');
  const unsignedHapPath = path.join(harmonyRoot, 'entry/build/default/outputs/default/entry-default-unsigned.hap');
  const extCer = joinFragments(['c', 'er']);
  const extP12 = joinFragments(['p', '12']);
  const materialPath = joinFragments(['/private/tmp/local-', 'sign', 'ing/dev-', 'cert', '.', extCer]);
  const materialUrl = joinFragments(['file://', materialPath]);
  const materialToken = joinFragments(['release-', 'sign', 'ing.', extP12]);
  const httpsUrl = 'https://example.com/support';

  await fs.mkdir(path.dirname(wrapperPath), { recursive: true });
  await fs.mkdir(path.dirname(unsignedHapPath), { recursive: true });
  await fs.writeFile(wrapperPath, '#!/bin/sh\n', 'utf8');
  await fs.chmod(wrapperPath, 0o755);
  await fs.writeFile(unsignedHapPath, 'unsigned-hap', 'utf8');
  await writeToolchainLock(harmonyRoot);

  try {
    const report = await buildHap({
      harmonyRoot,
      outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json'),
      spawnImpl: createSpawnSequence([
        {
          exitCode: 0,
          stderr: `BUILD SUCCESSFUL\nWill skip sign 'hos_hap'. ${materialPath} ${materialUrl} ${materialToken} ${httpsUrl}\n`
        },
        {
          exitCode: 0,
          stderr: `BUILD SUCCESSFUL\nWill skip sign 'hos_app'. ${materialPath} ${materialUrl} ${materialToken} ${httpsUrl}\n`
        }
      ])
    });

    const persisted = JSON.stringify(report);
    assert.doesNotMatch(persisted, /\/private\/tmp\/local-signing/u);
    assert.doesNotMatch(persisted, /file:\/\/\/private\/tmp\/local-signing/u);
    assert.doesNotMatch(persisted, new RegExp(`\\.${extCer}\\b`, 'u'));
    assert.doesNotMatch(persisted, new RegExp(`\\.${extP12}\\b`, 'u'));
    assert.match(persisted, /https:\/\/example\.com\/support/u);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 device runner treats hdc connect-server output as incomplete and targets all follow-up commands', async () => {
  const { analyzeTargetDiscovery, buildTargetedHdcArgs } = await import(runnerModulePath);

  assert.deepEqual(
    analyzeTargetDiscovery({
      exitCode: 0,
      stdout: 'Connect server failed\n',
      stderr: ''
    }),
    {
      kind: 'connection-failed',
      targets: []
    }
  );

  assert.deepEqual(
    analyzeTargetDiscovery({
      exitCode: 0,
      stdout: '192.168.1.100:8710\n',
      stderr: ''
    }),
    {
      kind: 'selected',
      targets: ['192.168.1.100:8710']
    }
  );

  assert.deepEqual(
    analyzeTargetDiscovery({
      exitCode: 0,
      stdout: '[Empty]\n',
      stderr: ''
    }),
    {
      kind: 'missing',
      targets: []
    }
  );

  assert.deepEqual(
    buildTargetedHdcArgs('192.168.1.100:8710', ['shell', 'aa', 'start', '-a', 'EntryAbility', '-b', 'com.github.kr328.clash.harmony']),
    ['-t', '192.168.1.100:8710', 'shell', 'aa', 'start', '-a', 'EntryAbility', '-b', 'com.github.kr328.clash.harmony']
  );
});

test('phase0 device runner rejects fuzzy hdc help and accepts the real command syntax summary', async () => {
  const { runPhase0DeviceProof } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-help-contract-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const hapPath = path.join(harmonyRoot, 'entry-default-signed.hap');
  const buildEvidencePath = path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json');
  const actualSha = (await import('node:crypto')).createHash('sha256').update('signed-hap').digest('hex');

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.writeFile(hapPath, 'signed-hap', 'utf8');
  await writeToolchainLock(harmonyRoot);
  await writePassingBuildEvidence({
    harmonyRoot,
    hapPath,
    sha256: actualSha,
    outputPath: buildEvidencePath
  });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.requirements.json'), JSON.stringify({
    defaults: { sdkRoots: [] },
    files: { hdc: 'openharmony/toolchains/hdc' }
  }), 'utf8');

  try {
    let callCount = 0;
    let proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      async execImpl(command, args) {
        callCount += 1;
        if (args.length === 1 && ['help', '-h', '--help'].includes(args[0])) {
          return { command, args, exitCode: 0, stdout: 'list targets\ninstall\nshell\n', stderr: '', error: null };
        }

        throw new Error('fuzzy help must be rejected before any other hdc call');
      }
    });

    assert.equal(proof.result, 'incomplete');
    assert.ok(proof.failures.some((entry) => entry.code === 'HDC_HELP_UNSUPPORTED'));
    assert.equal(callCount, 3);

    const calls = [];
    proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      async execImpl(command, args) {
        calls.push(args);

        if (args.length === 1 && ['help', '-h', '--help'].includes(args[0])) {
          return {
            command,
            args,
            exitCode: 0,
            stdout: [
              '-t connectkey',
              'list targets [-v]',
              'install [-r|-s|-cwd|option] src',
              'shell [-b bundlename] [COMMAND...]'
            ].join('\n'),
            stderr: '',
            error: null
          };
        }

        if (args[0] === 'list') {
          return { command, args, exitCode: 0, stdout: '[Empty]\n', stderr: '', error: null };
        }

        throw new Error('real help summary should allow progression to target discovery');
      }
    });

    assert.equal(proof.result, 'incomplete');
    assert.ok(proof.failures.some((entry) => entry.code === 'DEVICE_TARGET_MISSING'));
    assert.ok(calls.some((args) => args[0] === 'list' && args[1] === 'targets'));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 device runner execCommand times out hung hdc, kills it, and resolves without waiting for callback', async () => {
  const { execCommand } = await import(runnerModulePath);
  let killCount = 0;

  const result = await execCommand('hdc', ['list', 'targets'], {
    cwd: process.cwd(),
    timeoutMs: 10,
    execFileImpl(command, args, options, callback) {
      const child = new EventEmitter();
      child.kill = () => {
        killCount += 1;
        return true;
      };

      setTimeout(() => {
        callback(null, 'late output\n', '');
      }, 50);

      return child;
    }
  });

  assert.equal(result.exitCode, null);
  assert.equal(result.signal, 'SIGTERM');
  assert.equal(result.timedOut, true);
  assert.equal(result.error?.code, 'HDC_TIMEOUT');
  assert.equal(killCount, 1);
});

test('phase0 device runner records install hdc timeouts as incomplete proof with HDC_TIMEOUT', async () => {
  const { runPhase0DeviceProof, validatePhase0Proof } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-hdc-timeout-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const hapPath = path.join(harmonyRoot, 'entry-default-signed.hap');
  const actualSha = (await import('node:crypto')).createHash('sha256').update('signed-hap').digest('hex');

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.writeFile(hapPath, 'signed-hap', 'utf8');
  await writeToolchainLock(harmonyRoot);
  await writePassingBuildEvidence({
    harmonyRoot,
    hapPath,
    sha256: actualSha,
    outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json')
  });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.requirements.json'), JSON.stringify({
    defaults: { sdkRoots: [] },
    files: { hdc: 'openharmony/toolchains/hdc' }
  }), 'utf8');

  try {
    const proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      async execImpl(command, args) {
        if (args.length === 1 && ['help', '-h', '--help'].includes(args[0])) {
          return createAcceptedHdcHelpResult(command, args);
        }
        if (args[0] === 'list') {
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '', error: null };
        }
        if (args.includes('const.product.software.version')) {
          return { command, args, exitCode: 0, stdout: '6.1.0.123\n', stderr: '', error: null };
        }
        if (args.includes('const.ohos.apiversion')) {
          return { command, args, exitCode: 0, stdout: '20\n', stderr: '', error: null };
        }
        if (args.includes('const.product.cpu.abilist')) {
          return { command, args, exitCode: 0, stdout: 'arm64-v8a\n', stderr: '', error: null };
        }
        if (args.includes('const.product.model')) {
          return { command, args, exitCode: 0, stdout: 'HMA-AL00\n', stderr: '', error: null };
        }
        if (args.includes('install')) {
          return {
            command,
            args,
            exitCode: null,
            stdout: '',
            stderr: '',
            signal: 'SIGTERM',
            timedOut: true,
            error: Object.assign(new Error('Command timed out after 1000 ms.'), { code: 'HDC_TIMEOUT' })
          };
        }
        if (args.includes('force-stop')) {
          return { command, args, exitCode: 0, stdout: '', stderr: '', error: null };
        }
        return { command, args, exitCode: 0, stdout: '', stderr: '', error: null };
      }
    });

    assert.equal(proof.result, 'incomplete');
    assert.equal(proof.install.result, 'incomplete');
    assert.ok(proof.failures.some((entry) => entry.code === 'HDC_TIMEOUT' && entry.stage === 'install'));
    assert.equal(validatePhase0Proof(proof).valid, true);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 device runner rejects unsigned haps before hdc and redacts external absolute input paths', async () => {
  const { runPhase0DeviceProof, validatePhase0Proof } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-runner-unsigned-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const externalRoot = path.join(tempRoot, 'external');
  const unsignedHapPath = path.join(externalRoot, 'entry-default-unsigned.hap');
  let execCount = 0;

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.mkdir(externalRoot, { recursive: true });
  await fs.writeFile(unsignedHapPath, 'unsigned-hap', 'utf8');
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.lock.json'), JSON.stringify({
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hvigorVersion: '6.23.7',
      ohpmVersion: '6.1.1.830',
      hdcVersion: '6.1.0.105'
    }
  }), 'utf8');

  try {
    const proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath: unsignedHapPath,
      outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-device-proof.json'),
      execImpl() {
        execCount += 1;
        throw new Error('hdc must not be called for unsigned input');
      }
    });

    const persisted = JSON.stringify(proof);
    assert.equal(proof.result, 'incomplete');
    assert.equal(proof.hap.path, 'external/entry-default-unsigned.hap');
    assert.ok(proof.failures.some((entry) => entry.code === 'INPUT_HAP_UNSIGNED'));
    assert.ok(proof.failures.some((entry) => entry.code === 'SIGNING_REQUIRED'));
    assert.equal(execCount, 0);
    assert.doesNotMatch(persisted, /\/Users\//u);
    assert.doesNotMatch(persisted, new RegExp(tempRoot.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u'));
    assert.equal(validatePhase0Proof(proof).valid, true);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 device runner redacts raw target identities in persisted commands and does not trust connect failures with exit0', async () => {
  const { runPhase0DeviceProof } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-runner-target-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const hapPath = path.join(harmonyRoot, 'entry-default-signed.hap');
  const rawTarget = '192.168.1.100:8710';
  const calls = [];

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.writeFile(hapPath, 'signed-hap', 'utf8');
  await writeToolchainLock(harmonyRoot);
  const actualSha = (await import('node:crypto')).createHash('sha256').update('signed-hap').digest('hex');
  await writePassingBuildEvidence({
    harmonyRoot,
    hapPath,
    sha256: actualSha,
    outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json')
  });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.requirements.json'), JSON.stringify({
    defaults: { sdkRoots: [] },
    files: { hdc: 'openharmony/toolchains/hdc' }
  }), 'utf8');

  try {
    const proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-device-proof.json'),
      async execImpl(command, args) {
        calls.push([command, ...args]);

        if (args.length === 1 && ['help', '-h', '--help'].includes(args[0])) {
          return createAcceptedHdcHelpResult(command, args);
        }

        if (args[0] === 'list') {
          return { command, args, exitCode: 0, stdout: `${rawTarget}\n`, stderr: '', error: null };
        }

        if (args.includes('const.product.software.version')) {
          return { command, args, exitCode: 0, stdout: '6.1.0.123(C00E123R4P5)\n', stderr: '', error: null };
        }

        if (args.includes('const.ohos.apiversion')) {
          return { command, args, exitCode: 0, stdout: '20\n', stderr: '', error: null };
        }

        if (args.includes('const.product.cpu.abilist')) {
          return { command, args, exitCode: 0, stdout: 'arm64-v8a\n', stderr: '', error: null };
        }

        if (args.includes('const.product.model')) {
          return { command, args, exitCode: 0, stdout: 'HMA-AL00\n', stderr: '', error: null };
        }

        if (args.includes('install')) {
          return { command, args, exitCode: 0, stdout: 'Connect server failed\n', stderr: '', error: null };
        }

        return { command, args, exitCode: 0, stdout: '', stderr: '', error: null };
      }
    });

    const persisted = JSON.stringify(proof);
    assert.equal(proof.result, 'incomplete');
    assert.equal(proof.install.result, 'incomplete');
    assert.ok(proof.failures.some((entry) => entry.code === 'DEVICE_CONNECTION_FAILED'));
    assert.ok(calls.some((call) => call[1] === '-t' && call[2] === rawTarget));
    assert.doesNotMatch(persisted, new RegExp(rawTarget.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u'));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 device runner requires matching pass build evidence before hdc and copies verified build step', async () => {
  const { DEFAULT_OUTPUT_PATH, runPhase0DeviceProof } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-build-evidence-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const hapPath = path.join(harmonyRoot, 'entry-default-signed.hap');
  const buildEvidencePath = path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json');
  let execCount = 0;

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.writeFile(hapPath, 'signed-hap', 'utf8');
  await writeToolchainLock(harmonyRoot);

  try {
    const digest = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    let proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      outputPath: DEFAULT_OUTPUT_PATH,
      execImpl() {
        execCount += 1;
        throw new Error('hdc must not run without verified build evidence');
      }
    });
    assert.equal(proof.result, 'incomplete');
    assert.ok(proof.failures.some((entry) => entry.code === 'BUILD_EVIDENCE_MISSING'));
    assert.equal(execCount, 0);

    await writePassingBuildEvidence({
      harmonyRoot,
      hapPath,
      sha256: digest,
      outputPath: buildEvidencePath
    });
    const raw = JSON.parse(await fs.readFile(buildEvidencePath, 'utf8'));
    raw.result = 'incomplete';
    await fs.writeFile(buildEvidencePath, `${JSON.stringify(raw, null, 2)}\n`, 'utf8');

    proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      execImpl() {
        execCount += 1;
        throw new Error('hdc must not run when build evidence did not pass');
      }
    });
    assert.equal(proof.result, 'incomplete');
    assert.ok(proof.failures.some((entry) => entry.code === 'BUILD_EVIDENCE_INVALID'));
    assert.equal(execCount, 0);

    raw.result = 'pass';
    raw.hap.sha256 = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
    await fs.writeFile(buildEvidencePath, `${JSON.stringify(raw, null, 2)}\n`, 'utf8');

    proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      execImpl() {
        execCount += 1;
        throw new Error('hdc must not run when build evidence hash mismatches');
      }
    });
    assert.equal(proof.result, 'incomplete');
    assert.ok(proof.failures.some((entry) => entry.code === 'BUILD_EVIDENCE_MISMATCH'));
    assert.equal(execCount, 0);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 device runner uses injected build evidence object and skips hdc when that fresh build did not pass', async () => {
  const { runPhase0DeviceProof } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-build-object-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const hapPath = path.join(harmonyRoot, 'entry-default-signed.hap');
  let execCount = 0;

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.writeFile(hapPath, 'signed-hap', 'utf8');
  await writeToolchainLock(harmonyRoot);
  await fs.mkdir(path.join(harmonyRoot, 'artifacts'), { recursive: true });
  await fs.writeFile(path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json'), `${JSON.stringify({
    schemaVersion: '1.0.0',
    phase: 0,
    result: 'pass',
    hap: { path: 'forged.hap', sha256: 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' }
  }, null, 2)}\n`, 'utf8');

  try {
    const proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      buildEvidence: {
        schemaVersion: '1.0.0',
        phase: 0,
        result: 'incomplete',
        commands: [],
        hap: {
          path: 'harmony/entry-default-signed.hap',
          sha256: 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
        }
      },
      execImpl() {
        execCount += 1;
        throw new Error('hdc must not run when injected build evidence is not pass');
      }
    });

    assert.equal(proof.result, 'incomplete');
    assert.ok(proof.failures.some((entry) => entry.code === 'BUILD_EVIDENCE_INVALID'));
    assert.equal(execCount, 0);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 device runner treats install exit0 failure text as fail and uses install -r syntax', async () => {
  const { runPhase0DeviceProof } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-install-fail-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const hapPath = path.join(harmonyRoot, 'entry-default-signed.hap');
  const calls = [];

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.writeFile(hapPath, 'signed-hap', 'utf8');
  await writeToolchainLock(harmonyRoot);
  const actualSha = (await import('node:crypto')).createHash('sha256').update('signed-hap').digest('hex');
  await writePassingBuildEvidence({
    harmonyRoot,
    hapPath,
    sha256: actualSha,
    outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json')
  });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.requirements.json'), JSON.stringify({
    defaults: { sdkRoots: [] },
    files: { hdc: 'openharmony/toolchains/hdc' }
  }), 'utf8');

  try {
    const proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      async execImpl(command, args) {
        calls.push([command, ...args]);
        if (args.length === 1 && ['help', '-h', '--help'].includes(args[0])) {
          return createAcceptedHdcHelpResult(command, args);
        }
        if (args[0] === 'list') {
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '', error: null };
        }
        if (args.includes('const.product.software.version')) {
          return { command, args, exitCode: 0, stdout: '6.1.0.123\n', stderr: '', error: null };
        }
        if (args.includes('const.ohos.apiversion')) {
          return { command, args, exitCode: 0, stdout: '20\n', stderr: '', error: null };
        }
        if (args.includes('const.product.cpu.abilist')) {
          return { command, args, exitCode: 0, stdout: 'arm64-v8a\n', stderr: '', error: null };
        }
        if (args.includes('const.product.model')) {
          return { command, args, exitCode: 0, stdout: 'HMA-AL00\n', stderr: '', error: null };
        }
        if (args.includes('install')) {
          return { command, args, exitCode: 0, stdout: 'Failure [INSTALL_FAILED_INVALID_APK]\n', stderr: '', error: null };
        }
        return { command, args, exitCode: 0, stdout: '', stderr: '', error: null };
      }
    });

    assert.equal(proof.result, 'fail');
    assert.equal(proof.install.result, 'fail');
    assert.ok(proof.failures.some((entry) => entry.code === 'INSTALL_FAILED'));
    assert.ok(calls.some((call) => call.includes('install') && !call.includes('app')));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 device runner treats launch exit0 failure text as fail instead of pass', async () => {
  const { runPhase0DeviceProof } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-launch-fail-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const hapPath = path.join(harmonyRoot, 'entry-default-signed.hap');

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.writeFile(hapPath, 'signed-hap', 'utf8');
  await writeToolchainLock(harmonyRoot);
  const actualSha = (await import('node:crypto')).createHash('sha256').update('signed-hap').digest('hex');
  await writePassingBuildEvidence({
    harmonyRoot,
    hapPath,
    sha256: actualSha,
    outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json')
  });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.requirements.json'), JSON.stringify({
    defaults: { sdkRoots: [] },
    files: { hdc: 'openharmony/toolchains/hdc' }
  }), 'utf8');

  try {
    const proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      async execImpl(command, args) {
        if (args.length === 1 && ['help', '-h', '--help'].includes(args[0])) {
          return createAcceptedHdcHelpResult(command, args);
        }
        if (args[0] === 'list') {
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '', error: null };
        }
        if (args.includes('const.product.software.version')) {
          return { command, args, exitCode: 0, stdout: '6.1.0.123\n', stderr: '', error: null };
        }
        if (args.includes('const.ohos.apiversion')) {
          return { command, args, exitCode: 0, stdout: '20\n', stderr: '', error: null };
        }
        if (args.includes('const.product.cpu.abilist')) {
          return { command, args, exitCode: 0, stdout: 'arm64-v8a\n', stderr: '', error: null };
        }
        if (args.includes('const.product.model')) {
          return { command, args, exitCode: 0, stdout: 'HMA-AL00\n', stderr: '', error: null };
        }
        if (args.includes('install')) {
          return { command, args, exitCode: 0, stdout: 'Success\n', stderr: '', error: null };
        }
        if (args.includes('start')) {
          return { command, args, exitCode: 0, stdout: 'Error: ability not found\n', stderr: '', error: null };
        }
        return { command, args, exitCode: 0, stdout: '', stderr: '', error: null };
      }
    });

    assert.equal(proof.result, 'fail');
    assert.equal(proof.launch.result, 'fail');
    assert.ok(proof.failures.some((entry) => entry.code === 'LAUNCH_FAILED'));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 device runner treats force-stop failure as non-pass and records cleanup failure', async () => {
  const { runPhase0DeviceProof, validatePhase0Proof } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-force-stop-fail-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const hapPath = path.join(harmonyRoot, 'entry-default-signed.hap');

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.writeFile(hapPath, 'signed-hap', 'utf8');
  await writeToolchainLock(harmonyRoot);
  const actualSha = (await import('node:crypto')).createHash('sha256').update('signed-hap').digest('hex');
  await writePassingBuildEvidence({
    harmonyRoot,
    hapPath,
    sha256: actualSha,
    outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json')
  });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.requirements.json'), JSON.stringify({
    defaults: { sdkRoots: [] },
    files: { hdc: 'openharmony/toolchains/hdc' }
  }), 'utf8');

  try {
    const proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      async execImpl(command, args) {
        if (args.length === 1 && ['help', '-h', '--help'].includes(args[0])) {
          return createAcceptedHdcHelpResult(command, args);
        }
        if (args[0] === 'list') {
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '', error: null };
        }
        if (args.includes('const.product.software.version')) {
          return { command, args, exitCode: 0, stdout: '6.1.0.123\n', stderr: '', error: null };
        }
        if (args.includes('const.ohos.apiversion')) {
          return { command, args, exitCode: 0, stdout: '20\n', stderr: '', error: null };
        }
        if (args.includes('const.product.cpu.abilist')) {
          return { command, args, exitCode: 0, stdout: 'arm64-v8a\n', stderr: '', error: null };
        }
        if (args.includes('const.product.model')) {
          return { command, args, exitCode: 0, stdout: 'HMA-AL00\n', stderr: '', error: null };
        }
        if (args.includes('install')) {
          return { command, args, exitCode: 0, stdout: 'Success\n', stderr: '', error: null };
        }
        if (args.includes('start')) {
          return { command, args, exitCode: 0, stdout: 'start ability successfully\n', stderr: '', error: null };
        }
        if (args.includes('force-stop')) {
          return { command, args, exitCode: 0, stdout: 'Error: force stop failed\n', stderr: '', error: null };
        }
        return { command, args, exitCode: 0, stdout: '', stderr: '', error: null };
      }
    });

    assert.notEqual(proof.result, 'pass');
    assert.equal(proof.cleanup.forceStop.result, 'fail');
    assert.ok(proof.failures.some((entry) => entry.code === 'FORCE_STOP_FAILED'));
    assert.equal(validatePhase0Proof(proof).valid, true);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 device runner treats force-stop timeout as non-pass and keeps the proof contract-valid', async () => {
  const { runPhase0DeviceProof, validatePhase0Proof } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-force-stop-timeout-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const hapPath = path.join(harmonyRoot, 'entry-default-signed.hap');

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.writeFile(hapPath, 'signed-hap', 'utf8');
  await writeToolchainLock(harmonyRoot);
  const actualSha = (await import('node:crypto')).createHash('sha256').update('signed-hap').digest('hex');
  await writePassingBuildEvidence({
    harmonyRoot,
    hapPath,
    sha256: actualSha,
    outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json')
  });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.requirements.json'), JSON.stringify({
    defaults: { sdkRoots: [] },
    files: { hdc: 'openharmony/toolchains/hdc' }
  }), 'utf8');

  try {
    const proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      async execImpl(command, args) {
        if (args.length === 1 && ['help', '-h', '--help'].includes(args[0])) {
          return createAcceptedHdcHelpResult(command, args);
        }
        if (args[0] === 'list') {
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '', error: null };
        }
        if (args.includes('const.product.software.version')) {
          return { command, args, exitCode: 0, stdout: '6.1.0.123\n', stderr: '', error: null };
        }
        if (args.includes('const.ohos.apiversion')) {
          return { command, args, exitCode: 0, stdout: '20\n', stderr: '', error: null };
        }
        if (args.includes('const.product.cpu.abilist')) {
          return { command, args, exitCode: 0, stdout: 'arm64-v8a\n', stderr: '', error: null };
        }
        if (args.includes('const.product.model')) {
          return { command, args, exitCode: 0, stdout: 'HMA-AL00\n', stderr: '', error: null };
        }
        if (args.includes('install')) {
          return { command, args, exitCode: 0, stdout: 'Success\n', stderr: '', error: null };
        }
        if (args.includes('start')) {
          return { command, args, exitCode: 0, stdout: 'start ability successfully\n', stderr: '', error: null };
        }
        if (args.includes('force-stop')) {
          return {
            command,
            args,
            exitCode: null,
            stdout: '',
            stderr: '',
            signal: 'SIGTERM',
            timedOut: true,
            error: Object.assign(new Error('Command timed out after 1000 ms.'), { code: 'HDC_TIMEOUT' })
          };
        }
        return { command, args, exitCode: 0, stdout: '', stderr: '', error: null };
      }
    });

    assert.equal(proof.result, 'incomplete');
    assert.equal(proof.cleanup.forceStop.result, 'incomplete');
    assert.ok(proof.failures.some((entry) => entry.code === 'HDC_TIMEOUT' && entry.stage === 'cleanup'));
    assert.equal(validatePhase0Proof(proof).valid, true);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 device proof redacts external absolute paths, file URLs, and signing material tokens without breaking normal URLs', async () => {
  const { runPhase0DeviceProof } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-proof-sanitize-'));
  const harmonyRoot = path.join(tempRoot, 'harmony');
  const hapPath = path.join(harmonyRoot, 'entry-default-signed.hap');
  const extCer = joinFragments(['c', 'er']);
  const extP12 = joinFragments(['p', '12']);
  const materialPath = joinFragments(['/private/tmp/local-', 'sign', 'ing/dev-', 'cert', '.', extCer]);
  const materialUrl = joinFragments(['file://', materialPath]);
  const materialToken = joinFragments(['release-', 'sign', 'ing.', extP12]);
  const httpsUrl = 'https://example.com/support';

  await fs.mkdir(harmonyRoot, { recursive: true });
  await fs.writeFile(hapPath, 'signed-hap', 'utf8');
  await writeToolchainLock(harmonyRoot);
  const actualSha = (await import('node:crypto')).createHash('sha256').update('signed-hap').digest('hex');
  await writePassingBuildEvidence({
    harmonyRoot,
    hapPath,
    sha256: actualSha,
    outputPath: path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json')
  });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.requirements.json'), JSON.stringify({
    defaults: { sdkRoots: [] },
    files: { hdc: 'openharmony/toolchains/hdc' }
  }), 'utf8');

  try {
    const proof = await runPhase0DeviceProof({
      harmonyRoot,
      hapPath,
      async execImpl(command, args) {
        if (args.length === 1 && ['help', '-h', '--help'].includes(args[0])) {
          return createAcceptedHdcHelpResult(command, args);
        }
        if (args[0] === 'list') {
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '', error: null };
        }
        if (args.includes('const.product.software.version')) {
          return { command, args, exitCode: 0, stdout: '6.1.0.123\n', stderr: '', error: null };
        }
        if (args.includes('const.ohos.apiversion')) {
          return { command, args, exitCode: 0, stdout: '20\n', stderr: '', error: null };
        }
        if (args.includes('const.product.cpu.abilist')) {
          return { command, args, exitCode: 0, stdout: 'arm64-v8a\n', stderr: '', error: null };
        }
        if (args.includes('const.product.model')) {
          return { command, args, exitCode: 0, stdout: 'HMA-AL00\n', stderr: '', error: null };
        }
        if (args.includes('install')) {
          return { command, args, exitCode: 0, stdout: 'Success\n', stderr: '', error: null };
        }
        if (args.includes('start')) {
          return { command, args, exitCode: 0, stdout: 'start ability successfully\n', stderr: '', error: null };
        }
        if (args.includes('force-stop')) {
          return {
            command,
            args,
            exitCode: 1,
            stdout: `${materialPath} ${materialUrl} ${materialToken} ${httpsUrl}\n`,
            stderr: `Error: force stop failed for ${materialPath}\n`,
            error: null
          };
        }
        return { command, args, exitCode: 0, stdout: '', stderr: '', error: null };
      }
    });

    const persisted = JSON.stringify(proof);
    assert.doesNotMatch(persisted, /\/private\/tmp\/local-signing/u);
    assert.doesNotMatch(persisted, /file:\/\/\/private\/tmp\/local-signing/u);
    assert.doesNotMatch(persisted, new RegExp(`\\.${extCer}\\b`, 'u'));
    assert.doesNotMatch(persisted, new RegExp(`\\.${extP12}\\b`, 'u'));
    assert.match(persisted, /https:\/\/example\.com\/support/u);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 runner CLI fatal catch respects custom --out', async () => {
  const { parseCliArguments, runCli } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-cli-out-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  await fs.mkdir(harmonyRoot, { recursive: true });
  const customOut = path.join(repoRoot, 'harmony', 'artifacts', 'custom-proof.json');
  const parsed = parseCliArguments(['--hap', 'harmony/app.hap', '--out', customOut], repoRoot);

  assert.equal(parsed.outputPath, customOut);
  assert.equal(parsed.hapPath, 'harmony/app.hap');

  try {
    const exitCode = await runCli({
      argv: ['--hap', 'harmony/app.hap', '--out', customOut],
      repoRoot,
      buildHapImpl: async () => createPassingBuildEvidenceObject({
        harmonyRoot,
        hapPath: path.join(harmonyRoot, 'entry-default-signed.hap'),
        sha256: 'e'.repeat(64)
      }),
      writeBuildEvidenceImpl: async () => {},
      runPhase0DeviceProofImpl: async () => {
        throw Object.assign(new Error('boom'), { code: 'BOOM' });
      }
    });

    const persisted = JSON.parse(await fs.readFile(customOut, 'utf8'));
    assert.equal(exitCode, 2);
    assert.equal(persisted.outputPath, 'harmony/artifacts/custom-proof.json');
    assert.ok(persisted.failures.some((entry) => entry.code === 'BOOM'));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase0 runner CLI ignores stale disk build evidence and forwards the fresh in-memory build object', async () => {
  const { runCli } = await import(runnerModulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase0-cli-build-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const hapPath = path.join(harmonyRoot, 'entry-default-signed.hap');
  const buildEvidencePath = path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json');
  const proofOut = path.join(harmonyRoot, 'artifacts', 'phase0-device-proof.json');
  const actualSha = (await import('node:crypto')).createHash('sha256').update('signed-hap').digest('hex');
  const freshBuild = createPassingBuildEvidenceObject({ harmonyRoot, hapPath, sha256: actualSha });
  let receivedBuildEvidence = null;

  await fs.mkdir(path.dirname(buildEvidencePath), { recursive: true });
  await fs.writeFile(hapPath, 'signed-hap', 'utf8');
  await fs.writeFile(buildEvidencePath, `${JSON.stringify({
    schemaVersion: '1.0.0',
    phase: 0,
    result: 'pass',
    timestamps: {
      startedAt: '2000-01-01T00:00:00.000Z',
      completedAt: '2000-01-01T00:00:01.000Z'
    },
    hap: {
      path: 'forged.hap',
      sha256: 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
    }
  }, null, 2)}\n`, 'utf8');

  try {
    const exitCode = await runCli({
      argv: ['--hap', hapPath, '--out', proofOut, '--build-evidence', buildEvidencePath],
      repoRoot,
      buildHapImpl: async () => freshBuild,
      runPhase0DeviceProofImpl: async (options) => {
        receivedBuildEvidence = options.buildEvidence;
        return {
          schemaVersion: '1.0.0',
          phase: 0,
          result: 'incomplete',
          outputPath: 'harmony/artifacts/phase0-device-proof.json',
          bundle: 'com.github.kr328.clash.harmony',
          ability: 'EntryAbility',
          timestamps: {
            startedAt: '2026-07-31T12:00:00.000Z',
            completedAt: '2026-07-31T12:00:01.000Z'
          },
          toolchain: freshBuild.toolchain,
          hap: freshBuild.hap,
          device: {
            identityMasked: null,
            buildVersion: null,
            apiVersion: null,
            abi: null,
            model: null
          },
          build: {
            result: 'incomplete',
            command: freshBuild.commands[0]?.command ?? null,
            exitCode: freshBuild.commands[0]?.exitCode ?? null,
            stdout: '',
            stderr: ''
          },
          install: { result: 'not-run', command: null, exitCode: null, stdout: '', stderr: '' },
          launch: { result: 'not-run', command: null, exitCode: null, stdout: '', stderr: '' },
          cleanup: { forceStop: { result: 'pass', command: null, exitCode: null, stdout: '', stderr: '' } },
          targetDiscovery: { command: ['hdc', 'list', 'targets'], count: 0, identitiesMasked: [] },
          failures: [{ code: 'DEVICE_TARGET_MISSING', detail: 'No device', stage: 'device' }]
        };
      }
    });

    const persistedBuild = JSON.parse(await fs.readFile(buildEvidencePath, 'utf8'));
    assert.equal(exitCode, 2);
    assert.deepEqual(receivedBuildEvidence, freshBuild);
    assert.equal(persistedBuild.hap.path, freshBuild.hap.path);
    assert.equal(persistedBuild.hap.sha256, freshBuild.hap.sha256);
    assert.notEqual(persistedBuild.hap.path, 'forged.hap');
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});
