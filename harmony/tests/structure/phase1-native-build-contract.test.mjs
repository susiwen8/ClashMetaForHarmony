import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';

const buildModulePath = new URL('../bin/build-phase1-native.mjs', import.meta.url);
const provenanceModulePath = new URL('../../tools/lib/native-provenance.mjs', import.meta.url);
const inspectNativeLibModulePath = new URL('../bin/inspect-native-lib.mjs', import.meta.url);
const harmonyRoot = path.resolve(new URL('../..', import.meta.url).pathname);
const repoRoot = path.resolve(harmonyRoot, '..');
const defaultManifestPath = path.join(harmonyRoot, 'artifacts', 'phase1-native-provenance.json');
const defaultRawCorePath = path.join(harmonyRoot, 'artifacts', 'libcmfa_mihomo.so');
const CORE_EXPORTS = [
  'cmfa_mihomo_close_stale_tun_connections_v1',
  'cmfa_mihomo_core_build_info_json_cstr_v1',
  'cmfa_mihomo_core_version_cstr_v1',
  'cmfa_mihomo_probe_cancel_v1',
  'cmfa_mihomo_probe_https_v1',
  'cmfa_mihomo_runtime_state_v1',
  'cmfa_mihomo_start_local_v1',
  'cmfa_mihomo_start_tun_v1',
  'cmfa_mihomo_stop_tun_v1',
  'cmfa_mihomo_stop_v1',
  'cmfa_mihomo_take_runtime_log_v1',
  'cmfa_mihomo_tun_copy_traces_ring_v1',
  'cmfa_mihomo_tun_copy_traces_v1',
  'cmfa_mihomo_tun_runtime_state_v1'
];
const NODE_ADDON_ALLOWED_EXPORTS = [
  '_fini',
  '_init',
  'cmfa_host_emit_runtime_event_bridge_v1',
  'cmfa_host_protect_socket_bridge_v1'
];
const defaultPrePackageCorePath = path.join(
  harmonyRoot,
  'entry',
  'build',
  'default',
  'intermediates',
  'cmake',
  'default',
  'obj',
  'arm64-v8a',
  'libcmfa_mihomo.so'
);
const defaultPrePackageAddonPath = path.join(
  harmonyRoot,
  'entry',
  'build',
  'default',
  'intermediates',
  'cmake',
  'default',
  'obj',
  'arm64-v8a',
  'libentry.so'
);
const defaultHapPath = path.join(
  harmonyRoot,
  'entry',
  'build',
  'default',
  'outputs',
  'default',
  'entry-default-unsigned.hap'
);

const signingFixtureExtensions = Object.freeze([
  joinFragments(['p', '12']),
  joinFragments(['c', 'er']),
  joinFragments(['p', '7b']),
  joinFragments(['p', 'em']),
  joinFragments(['p', 'fx'])
]);
const signingFixtureFiles = Object.freeze({
  command: joinFragments(['secret.', 'p', '12']),
  proof: joinFragments(['proof.', 'p', '12']),
  token: joinFragments(['token.', 'p', 'fx']),
  bundle: joinFragments(['bundle.', 'c', 'er']),
  chain: joinFragments(['chain.', 'p', '7b']),
  local: joinFragments(['local.', 'p', 'em']),
  retryStore: joinFragments(['keystore.', 'p', 'fx']),
  mirror: joinFragments(['mirror.', 'c', 'er']),
  archive: joinFragments(['explode.', 'p', 'em']),
  raw: joinFragments(['raw.', 'p', '12']),
  testStore: joinFragments(['test-keystore.', 'p', '12'])
});
const aliceHomeFixture = joinFragments(['/Us', 'ers/alice']);
const signingFixtureExtensionPattern = new RegExp(
  String.raw`\.(?:${signingFixtureExtensions.map(escapeRegex).join('|')})\b`,
  'iu'
);

const TOOLCHAIN_LOCK_TEMPLATE = {
  schemaVersion: '1.0.0',
  target: {
    name: 'HarmonyOS 6/API 20/arm64',
    targetSdkVersion: '6.1.0(23)',
    targetApiVersion: 23,
    compatibleSdkVersion: '6.0.0(20)',
    compatibleApiVersion: 20,
    runtimeOS: 'HarmonyOS',
    architecture: 'arm64'
  },
  installed: {
    devecoVersion: '6.1.0.860',
    sdkVersion: '6.1.0.105',
    sdkApiVersion: 23,
    ndkVersion: '6.1.0.105',
    ndkApiVersion: 23,
    hvigorVersion: '6.23.7',
    ohpmVersion: '6.1.1.830',
    hdcVersion: '6.1.0.105'
  }
};

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function joinFragments(parts) {
  return parts.join('');
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

function isoAt(offsetMs) {
  return new Date(Date.UTC(2026, 7, 3, 12, 0, 0, offsetMs)).toISOString();
}

function createBuildStep(result = 'not-run', command = null, exitCode = null, stdout = '', stderr = '') {
  return { result, command, exitCode, stdout, stderr };
}

function createPhase2SelfTestEvidence(enabled = false) {
  return {
    enabled,
    activation: enabled ? 'explicit' : 'default',
    purpose: enabled ? 'test-only' : 'production',
    releaseStatus: enabled ? 'not-releasable' : 'releasable'
  };
}

function createElfReport(component, overrides = {}) {
  const defaults = component === 'nodeAddon'
    ? {
      result: 'pass',
      component: 'nodeAddon',
      architecture: 'AArch64',
      neededLibraries: ['libace_napi.z.so', 'libc.so', 'libcmfa_mihomo.so', 'libhilog_ndk.z.so'],
      allowedNeededLibraries: ['libace_napi.z.so', 'libc.so', 'libcmfa_mihomo.so', 'libhilog_ndk.z.so'],
      exportedSymbols: NODE_ADDON_ALLOWED_EXPORTS,
      requiredExports: [],
      failures: []
    }
    : {
      result: 'pass',
      component: 'mihomoCore',
      architecture: 'AArch64',
      neededLibraries: ['libc.so'],
      allowedNeededLibraries: ['libc.so'],
      exportedSymbols: CORE_EXPORTS,
      requiredExports: CORE_EXPORTS,
      failures: []
    };

  return {
    ...defaults,
    ...overrides
  };
}

function createArtifact(identity, contents, elf = null) {
  return {
    identity,
    sha256: sha256(contents),
    sizeBytes: Buffer.byteLength(contents),
    elf
  };
}

function createStrictManifest(overrides = {}) {
  return {
    schemaVersion: '1.0.0',
    phase: 1,
    runId: '00000000-0000-4000-8000-000000000001',
    result: 'pass',
    nativeBuildResult: 'pass',
    timestamps: {
      startedAt: isoAt(0),
      completedAt: isoAt(5000)
    },
    toolchainLock: {
      path: 'harmony/toolchain.lock.json',
      sha256: sha256(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
    },
    phase2SelfTest: createPhase2SelfTestEvidence(false),
    builds: {
      core: createBuildStep('pass', ['node', 'harmony/tools/build-mihomo-ohos.mjs'], 0),
      addonConfigure: createBuildStep('pass', ['harmony/hvigorw', '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', '-p', 'buildMode=debug', 'compileNative'], 0),
      addon: createBuildStep('pass', ['cmake', '--build', 'entry/.cxx/default/default/debug/arm64-v8a', '--target', 'entry'], 0),
      hap: createBuildStep('pass', ['harmony/hvigorw', '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', '-p', 'buildMode=debug', 'assembleHap'], 0)
    },
    artifacts: {
      rawCore: createArtifact('harmony/artifacts/libcmfa_mihomo.so', 'core-bytes', createElfReport('mihomoCore')),
      prePackageCore: createArtifact('harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so', 'core-bytes', createElfReport('mihomoCore')),
      prePackageAddon: createArtifact('harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so', 'addon-bytes', createElfReport('nodeAddon')),
      hap: createArtifact('harmony/entry/build/default/outputs/default/entry-default-unsigned.hap', 'hap-bytes', null),
      hapCore: createArtifact('libs/arm64-v8a/libcmfa_mihomo.so', 'core-bytes', createElfReport('mihomoCore')),
      hapAddon: createArtifact('libs/arm64-v8a/libentry.so', 'addon-bytes', createElfReport('nodeAddon'))
    },
    archive: {
      entryCount: 2,
      occurrences: {
        core: 1,
        addon: 1
      }
    },
    signing: {
      result: 'pass'
    },
    device: {
      result: 'pass',
      targetCount: 1,
      identityMasked: 'target-1234abcd',
      proofResult: 'not-run'
    },
    failures: [],
    ...overrides
  };
}

function createEarlyFailureManifest(overrides = {}) {
  return {
    schemaVersion: '1.0.0',
    phase: 1,
    runId: '11111111-2222-4333-8444-555555555555',
    result: 'fail',
    nativeBuildResult: 'fail',
    timestamps: {
      startedAt: isoAt(0),
      completedAt: isoAt(1000)
    },
    toolchainLock: {
      path: 'harmony/toolchain.lock.json',
      sha256: null
    },
    phase2SelfTest: createPhase2SelfTestEvidence(false),
    builds: {
      core: createBuildStep(),
      addonConfigure: createBuildStep(),
      addon: createBuildStep(),
      hap: createBuildStep()
    },
    artifacts: {
      rawCore: null,
      prePackageCore: null,
      prePackageAddon: null,
      hap: null,
      hapCore: null,
      hapAddon: null
    },
    archive: {
      entryCount: null,
      occurrences: {
        core: null,
        addon: null
      }
    },
    signing: {
      result: 'not-run'
    },
    device: {
      result: 'not-run',
      targetCount: null,
      identityMasked: null,
      proofResult: 'not-run'
    },
    failures: [
      {
        code: 'TOOLCHAIN_LOCK_FAILED',
        detail: 'toolchain.lock.json could not be hashed',
        stage: 'toolchain-lock'
      }
    ],
    ...overrides
  };
}

async function withTempDir(prefix, fn) {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), prefix));
  try {
    return await fn(tempRoot);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
}

function createSpawnForExtraction({ stdout = '', stderr = '', exitCode = 0, onArgs = () => {} }) {
  return function spawnStub(command, args) {
    onArgs(command, args);
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.stdout.pipe = (stream) => {
      queueMicrotask(() => {
        stream.write(stdout);
        stream.end();
      });
      return stream;
    };
    child.stderr.setEncoding = () => {};
    queueMicrotask(() => {
      if (stderr) {
        child.stderr.emit('data', stderr);
      }
      child.emit('close', exitCode, null);
    });
    return child;
  };
}

function createLiveFsStub(existingPaths) {
  const normalized = new Set([...existingPaths].map((entry) => path.resolve(entry)));
  return {
    async lstat(targetPath) {
      const resolved = path.resolve(targetPath);
      if (!normalized.has(resolved)) {
        const error = new Error(`ENOENT: no such file or directory, lstat '${targetPath}'`);
        error.code = 'ENOENT';
        throw error;
      }
      return {
        isSymbolicLink() {
          return false;
        }
      };
    },
    async stat(targetPath) {
      const resolved = path.resolve(targetPath);
      if (!normalized.has(resolved)) {
        const error = new Error(`ENOENT: no such file or directory, stat '${targetPath}'`);
        error.code = 'ENOENT';
        throw error;
      }
      return {
        dev: 1,
        ino: resolved.length,
        isFile() {
          return true;
        }
      };
    },
    async realpath(targetPath) {
      const resolved = path.resolve(targetPath);
      if (!normalized.has(resolved)) {
        const error = new Error(`ENOENT: no such file or directory, realpath '${targetPath}'`);
        error.code = 'ENOENT';
        throw error;
      }
      return resolved;
    }
  };
}

test('phase1 native modules export frozen constants and documented entry points', async () => {
  const [buildModule, provenanceModule] = await Promise.all([
    import(buildModulePath),
    import(provenanceModulePath)
  ]);

  assert.equal(buildModule.PHASE1_NATIVE_SCHEMA_VERSION, '1.0.0');
  assert.equal(buildModule.PHASE1_NATIVE_PHASE, 1);
  assert.equal(Object.isFrozen(buildModule.HAP_NATIVE_ENTRIES), true);
  assert.deepEqual(buildModule.HAP_NATIVE_ENTRIES, {
    addon: 'libs/arm64-v8a/libentry.so',
    core: 'libs/arm64-v8a/libcmfa_mihomo.so'
  });
  assert.equal(typeof buildModule.buildPhase1Native, 'function');
  assert.equal(typeof buildModule.parseCliArguments, 'function');
  assert.equal(typeof buildModule.runCli, 'function');
  assert.equal(typeof buildModule.writeManifest, 'function');
  for (const exportName of [
    'hashFile',
    'listHapEntries',
    'extractAndHashHapEntry',
    'inspectHapNativeEntries',
    'derivePhase1Result',
    'validatePhase1NativeManifest',
    'verifyPhase1NativeManifest'
  ]) {
    assert.equal(typeof provenanceModule[exportName], 'function', `${exportName} must be exported`);
  }
});

test('phase1 CLI requires explicit --validate <manifest> and rejects forbidden combinations', async () => {
  const { parseCliArguments, runCli } = await import(buildModulePath);

  assert.deepEqual(parseCliArguments([], repoRoot), {
    outputPath: defaultManifestPath,
    validatePath: null,
    phase2SelfTestEnabled: false
  });
  assert.deepEqual(parseCliArguments(['--phase2-self-test'], repoRoot), {
    outputPath: defaultManifestPath,
    validatePath: null,
    phase2SelfTestEnabled: true
  });
  assert.deepEqual(parseCliArguments(['--validate', 'harmony/artifacts/phase1-native-provenance.json'], repoRoot), {
    outputPath: defaultManifestPath,
    validatePath: path.join(repoRoot, 'harmony', 'artifacts', 'phase1-native-provenance.json'),
    phase2SelfTestEnabled: false
  });

  for (const argv of [
    ['--validate'],
    ['--validate', 'harmony/artifacts/a.json', '--validate', 'harmony/artifacts/b.json'],
    ['--validate', '../outside.json'],
    ['--validate', 'harmony/artifacts/a.json', '--out', 'harmony/artifacts/b.json'],
    ['--validate', 'harmony/artifacts/a.json', '--phase2-self-test'],
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

  let observedValidatePath = null;
  const exitCode = await runCli({
    argv: ['--validate', 'harmony/artifacts/custom-phase1.json'],
    verifyManifestImpl: async ({ manifestPath }) => {
      observedValidatePath = manifestPath;
      return {
        manifest: createEarlyFailureManifest(),
        valid: true,
        errors: []
      };
    },
    stdout: { write() {} }
  });
  assert.equal(exitCode, 0);
  assert.equal(observedValidatePath, path.join(repoRoot, 'harmony', 'artifacts', 'custom-phase1.json'));
});

test('listHapEntries uses /usr/bin/unzip -Z1 with argv arrays and preserves duplicate entries', async () => {
  const { listHapEntries } = await import(provenanceModulePath);
  let observed = null;

  const listed = await listHapEntries('/tmp/fake.hap', {
    execFileImpl(command, args, options, callback) {
      observed = { command, args, options };
      callback(null, 'libs/arm64-v8a/libentry.so\nlibs/arm64-v8a/libentry.so\nlibs/arm64-v8a/libcmfa_mihomo.so\n', '');
      return { kill() {} };
    }
  });

  assert.deepEqual(observed, {
    command: '/usr/bin/unzip',
    args: ['-Z1', '/tmp/fake.hap'],
    options: {
      cwd: repoRoot,
      env: process.env,
      shell: false,
      windowsHide: true,
      maxBuffer: 10 * 1024 * 1024
    }
  });
  assert.equal(listed.entryCount, 3);
  assert.deepEqual(listed.occurrences, {
    'libs/arm64-v8a/libentry.so': 2,
    'libs/arm64-v8a/libcmfa_mihomo.so': 1
  });
});

test('extractAndHashHapEntry keeps the public positional signature and removes its temp file after inspect', async () => {
  const [{ extractAndHashHapEntry }, { inspectNativeLibrary }] = await Promise.all([
    import(provenanceModulePath),
    import(inspectNativeLibModulePath)
  ]);

  await withTempDir('phase1-native-extract-', async (tempRoot) => {
    let observedArgs = null;
    let inspectedPath = null;
    const runScopedDir = path.join(tempRoot, 'phase1-native-run-123');

    const extracted = await extractAndHashHapEntry('/tmp/archive.hap', 'libs/arm64-v8a/libentry.so', {
      runId: 'run-123',
      tempRoot,
      component: 'nodeAddon',
      spawnImpl: createSpawnForExtraction({
        stdout: 'addon-binary',
        onArgs(command, args) {
          observedArgs = { command, args };
        }
      }),
      inspectNativeLibraryImpl: async (input) => {
        inspectedPath = input.libPath;
        return {
          ...(await inspectNativeLibrary({
            libPath: input.libPath,
            component: 'nodeAddon',
            toolchainInspectorImpl: async () => ({
              report: { result: 'pass' },
              resolved: { paths: { llvmReadelf: '/fixture/llvm-readelf' } }
            }),
            spawnImpl(command, args) {
              const child = new EventEmitter();
              child.stdout = new EventEmitter();
              child.stderr = new EventEmitter();
              child.stdout.setEncoding = () => {};
              child.stderr.setEncoding = () => {};
              queueMicrotask(() => {
                if (args[0] === '-h') {
                  child.stdout.emit('data', 'Machine: AArch64\n');
                } else if (args[0] === '-d') {
                  child.stdout.emit('data', 'Shared library: [libace_napi.z.so]\nShared library: [libc.so]\nShared library: [libcmfa_mihomo.so]\nShared library: [libhilog_ndk.z.so]\n');
                } else {
                  child.stdout.emit('data', [
                    '1: 0000 GLOBAL DEFAULT 1 _init',
                    '2: 0000 GLOBAL DEFAULT 1 _fini',
                    '3: 0000 GLOBAL DEFAULT 1 cmfa_host_emit_runtime_event_bridge_v1',
                    '4: 0000 GLOBAL DEFAULT 1 cmfa_host_protect_socket_bridge_v1'
                  ].join('\n'));
                }
                child.emit('close', 0, null);
              });
              return child;
            },
            fsApi: {
              ...fs,
              readFile: fs.readFile,
              stat: fs.stat,
              access: fs.access
            }
          }))
        };
      }
    });

    assert.deepEqual(observedArgs, {
      command: '/usr/bin/unzip',
      args: ['-p', '/tmp/archive.hap', 'libs/arm64-v8a/libentry.so']
    });
    assert.match(inspectedPath, new RegExp(`^${tempRoot.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')}.+run-123.+\\.so$`, 'u'));
    await assert.rejects(fs.access(inspectedPath));
    await assert.rejects(fs.access(runScopedDir));
    assert.equal(extracted.identity, 'libs/arm64-v8a/libentry.so');
    assert.equal(extracted.sha256, sha256('addon-binary'));
    assert.equal(extracted.sizeBytes, Buffer.byteLength('addon-binary'));
    assert.equal(extracted.elf.result, 'pass');
  });
});

test('extractAndHashHapEntry rejects reused run roots and removes run-scoped extraction directories after spawn, unzip, and hash failures', async () => {
  const { extractAndHashHapEntry } = await import(provenanceModulePath);

  await withTempDir('phase1-native-extract-failures-', async (tempRoot) => {
    const reusedRunId = 'run-reused';
    const reusedRunRoot = path.join(tempRoot, `phase1-native-${reusedRunId}`);
    await fs.mkdir(reusedRunRoot, { recursive: true });

    await assert.rejects(
      extractAndHashHapEntry('/tmp/archive.hap', 'libs/arm64-v8a/libentry.so', {
        runId: reusedRunId,
        tempRoot,
        spawnImpl: createSpawnForExtraction({ stdout: 'addon-binary' }),
        inspectNativeLibraryImpl: async () => createElfReport('nodeAddon')
      }),
      /run-reused|phase1-native/u
    );
    await fs.access(reusedRunRoot);

    const spawnErrorRunId = 'run-spawn-error';
    const spawnErrorRoot = path.join(tempRoot, `phase1-native-${spawnErrorRunId}`);
    await assert.rejects(
      extractAndHashHapEntry('/tmp/archive.hap', 'libs/arm64-v8a/libentry.so', {
        runId: spawnErrorRunId,
        tempRoot,
        spawnImpl() {
          const child = new EventEmitter();
          child.stdout = new EventEmitter();
          child.stderr = new EventEmitter();
          child.stdout.pipe = () => ({ end() {}, on() {}, once() {}, emit() {} });
          child.stderr.setEncoding = () => {};
          queueMicrotask(() => {
            child.emit('error', Object.assign(new Error('spawn exploded'), { code: 'SPAWN_FAILED' }));
          });
          return child;
        },
        inspectNativeLibraryImpl: async () => createElfReport('nodeAddon')
      }),
      /spawn exploded/u
    );
    await assert.rejects(fs.access(spawnErrorRoot));

    const unzipFailureRunId = 'run-unzip-failure';
    const unzipFailureRoot = path.join(tempRoot, `phase1-native-${unzipFailureRunId}`);
    await assert.rejects(
      extractAndHashHapEntry('/tmp/archive.hap', 'libs/arm64-v8a/libentry.so', {
        runId: unzipFailureRunId,
        tempRoot,
        spawnImpl: createSpawnForExtraction({
          stdout: 'addon-binary',
          stderr: 'inflate failed',
          exitCode: 9
        }),
        inspectNativeLibraryImpl: async () => createElfReport('nodeAddon')
      }),
      /inflate failed|HAP_NATIVE_EXTRACTION_FAILED/u
    );
    await assert.rejects(fs.access(unzipFailureRoot));

    const hashFailureRunId = 'run-hash-failure';
    const hashFailureRoot = path.join(tempRoot, `phase1-native-${hashFailureRunId}`);
    await assert.rejects(
      extractAndHashHapEntry('/tmp/archive.hap', 'libs/arm64-v8a/libentry.so', {
        runId: hashFailureRunId,
        tempRoot,
        spawnImpl: createSpawnForExtraction({ stdout: 'addon-binary' }),
        createReadStreamImpl() {
          const stream = new EventEmitter();
          queueMicrotask(() => {
            stream.emit('error', Object.assign(new Error('hash read failed'), { code: 'EIO' }));
          });
          return stream;
        },
        inspectNativeLibraryImpl: async () => createElfReport('nodeAddon')
      }),
      /hash read failed/u
    );
    await assert.rejects(fs.access(hashFailureRoot));
  });
});

test('extractAndHashHapEntry and inspectHapNativeEntries reject malicious run ids before any temp-root mutation', async () => {
  const { extractAndHashHapEntry, inspectHapNativeEntries } = await import(provenanceModulePath);

  for (const runId of [
    '../evil',
    'x/../../evil',
    'nested/run',
    '/absolute-evil',
    'C:\\temp\\evil',
    'windows\\..\\escape'
  ]) {
    await withTempDir('phase1-native-runid-reject-', async (tempRoot) => {
      const outsideRoot = path.join(tempRoot, '..', 'outside-sentinel');
      const outsideFile = path.join(outsideRoot, 'sentinel.txt');
      let spawnCalled = false;
      let listCalled = false;

      await fs.mkdir(outsideRoot, { recursive: true });
      await fs.writeFile(outsideFile, 'safe', 'utf8');

      await assert.rejects(
        extractAndHashHapEntry('/tmp/archive.hap', 'libs/arm64-v8a/libentry.so', {
          runId,
          tempRoot,
          spawnImpl() {
            spawnCalled = true;
            throw new Error('spawn must not run for invalid run ids');
          },
          inspectNativeLibraryImpl: async () => createElfReport('nodeAddon')
        }),
        (error) => error?.code === 'HAP_NATIVE_EXTRACTION_ROOT_INVALID'
      );
      assert.equal(spawnCalled, false, `${runId} should be rejected before spawn`);
      assert.deepEqual(await fs.readdir(tempRoot), [], `${runId} should not create temp-root entries`);
      assert.equal(await fs.readFile(outsideFile, 'utf8'), 'safe');

      await assert.rejects(
        inspectHapNativeEntries({
          hapPath: '/tmp/archive.hap',
          runId
        }, {
          tempRoot,
          listHapEntriesImpl: async () => {
            listCalled = true;
            throw new Error('list must not run for invalid run ids');
          }
        }),
        (error) => error?.code === 'HAP_NATIVE_EXTRACTION_ROOT_INVALID'
      );
      assert.equal(listCalled, false, `${runId} should be rejected before list`);
      assert.deepEqual(await fs.readdir(tempRoot), [], `${runId} should not create temp-root entries after inspect`);
      assert.equal(await fs.readFile(outsideFile, 'utf8'), 'safe');
    });
  }
});

test('inspectHapNativeEntries uses the public input-plus-options signature and reports exact-path collisions', async () => {
  const { inspectHapNativeEntries } = await import(provenanceModulePath);
  await withTempDir('phase1-native-collisions-', async (tempRoot) => {
    const duplicate = await inspectHapNativeEntries({
      hapPath: '/tmp/archive.hap',
      runId: 'run-duplicate'
    }, {
      tempRoot,
      listHapEntriesImpl: async () => ({
        entryCount: 4,
        entries: [
          'libs/arm64-v8a/libcmfa_mihomo.so',
          'libs/arm64-v8a/libcmfa_mihomo.so',
          'libs/arm64-v8a/libentry.so',
          'libs/arm64-v8a/libentry.so'
        ],
        occurrences: {
          'libs/arm64-v8a/libentry.so': 2,
          'libs/arm64-v8a/libcmfa_mihomo.so': 2
        }
      })
    });
    assert.ok(duplicate.failures.some((entry) => entry.code === 'HAP_NATIVE_ENTRY_AMBIGUOUS'));

    const wrongPath = await inspectHapNativeEntries({
      hapPath: '/tmp/archive.hap',
      runId: 'run-missing'
    }, {
      tempRoot,
      listHapEntriesImpl: async () => ({
        entryCount: 1,
        entries: ['assets/libentry.so'],
        occurrences: {
          'assets/libentry.so': 1
        }
      })
    });
    assert.ok(wrongPath.failures.some((entry) => entry.code === 'HAP_NATIVE_ENTRY_MISSING'));
    assert.ok(wrongPath.failures.some((entry) => entry.code === 'HAP_NATIVE_ENTRY_WRONG_PATH'));
  });
});

test('inspectHapNativeEntries removes the run root when listHapEntriesImpl throws before any extraction', async () => {
  const { inspectHapNativeEntries } = await import(provenanceModulePath);

  await withTempDir('phase1-native-list-throw-', async (tempRoot) => {
    const runId = 'run-list-throw';
    const runScopedDir = path.join(tempRoot, `phase1-native-${runId}`);

    await assert.rejects(
      inspectHapNativeEntries({
        hapPath: '/tmp/archive.hap',
        runId
      }, {
        tempRoot,
        listHapEntriesImpl: async () => {
          throw Object.assign(new Error('list exploded'), { code: 'LIST_FAILED' });
        }
      }),
      /list exploded/u
    );

    await assert.rejects(fs.access(runScopedDir));
  });
});

test('strict manifest validator accepts honest early-fail evidence and rejects obsolete fields plus nested contract drift', async () => {
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  const validPass = validatePhase1NativeManifest(createStrictManifest());
  assert.equal(validPass.valid, true, validPass.errors.join('\n'));

  const validEarlyFail = validatePhase1NativeManifest(createEarlyFailureManifest());
  assert.equal(validEarlyFail.valid, true, validEarlyFail.errors.join('\n'));

  const invalid = validatePhase1NativeManifest(createStrictManifest({
    outputPath: 'harmony/artifacts/phase1-native-provenance.json',
    artifacts: {
      ...createStrictManifest().artifacts,
      rawCore: {
        ...createStrictManifest().artifacts.rawCore,
        path: 'harmony/artifacts/libcmfa_mihomo.so',
        extraNested: true,
        elf: {
          ...createStrictManifest().artifacts.rawCore.elf,
          component: 'nodeAddon',
          extraElfField: true
        }
      }
    },
    signing: {
      result: 'pass',
      command: ['harmony/hvigorw', 'assembleHap']
    },
    builds: {
      ...createStrictManifest().builds,
      core: {
        result: 'pass',
        command: ['node', 'x'],
        exitCode: 1,
        stdout: '',
        stderr: '',
        extraBuildField: true
      },
      addonConfigure: {
        result: 'not-run',
        command: null,
        exitCode: null,
        stdout: 'unexpected',
        stderr: ''
      }
    },
    failures: [
      {
        code: 'PROVENANCE_HASH_MISMATCH',
        detail: 'wrong hash',
        stage: 'archive',
        extraFailureField: true
      }
    ]
  }));

  assert.equal(invalid.valid, false);
  assert.match(invalid.errors.join('\n'), /outputPath/u);
  assert.match(invalid.errors.join('\n'), /signing/u);
  assert.match(invalid.errors.join('\n'), /artifacts\.rawCore/u);
  assert.match(invalid.errors.join('\n'), /BuildStep/u);
  assert.match(invalid.errors.join('\n'), /failure/u);
  assert.match(invalid.errors.join('\n'), /component/u);
});

test('strict manifest validator requires the canonical harmony/toolchain.lock.json identity', async () => {
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  const invalid = validatePhase1NativeManifest(createStrictManifest({
    toolchainLock: {
      path: 'toolchain.lock.json',
      sha256: sha256(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
    }
  }));

  assert.equal(invalid.valid, false);
  assert.match(invalid.errors.join('\n'), /toolchainLock\.path|harmony\/toolchain\.lock\.json/u);
});

test('strict manifest validator requires the canonical 14-symbol core export contract and rejects missing or extra public exports', async () => {
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  const exactCanonicalManifest = createStrictManifest();
  const exactCanonical = validatePhase1NativeManifest(exactCanonicalManifest);
  assert.equal(exactCanonical.valid, true, exactCanonical.errors.join('\n'));

  const missingTunExport = validatePhase1NativeManifest(createStrictManifest({
    artifacts: {
      ...createStrictManifest().artifacts,
      rawCore: createArtifact(
        'harmony/artifacts/libcmfa_mihomo.so',
        'core-bytes',
        createElfReport('mihomoCore', {
          exportedSymbols: CORE_EXPORTS.filter((symbol) => symbol !== 'cmfa_mihomo_tun_runtime_state_v1'),
          requiredExports: CORE_EXPORTS.filter((symbol) => symbol !== 'cmfa_mihomo_tun_runtime_state_v1')
        })
      )
    }
  }));
  assert.equal(missingTunExport.valid, false);
  assert.match(missingTunExport.errors.join('\n'), /requiredExports must match the core export contract|exportedSymbols must include/u);

  const extraPublicExport = validatePhase1NativeManifest(createStrictManifest({
    artifacts: {
      ...createStrictManifest().artifacts,
      rawCore: createArtifact(
        'harmony/artifacts/libcmfa_mihomo.so',
        'core-bytes',
        createElfReport('mihomoCore', {
          exportedSymbols: [...CORE_EXPORTS, 'cmfa_extra_symbol'],
          requiredExports: CORE_EXPORTS
        })
      )
    }
  }));
  assert.equal(extraPublicExport.valid, false);
  assert.match(extraPublicExport.errors.join('\n'), /exportedSymbols must not expose extra cmfa_\* symbols/u);
});

test('strict manifest validator requires the canonical four-symbol addon export contract and rejects missing or extra exports', async () => {
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  const exactCanonical = validatePhase1NativeManifest(createStrictManifest());
  assert.equal(exactCanonical.valid, true, exactCanonical.errors.join('\n'));

  const missingBridgeExport = validatePhase1NativeManifest(createStrictManifest({
    artifacts: {
      ...createStrictManifest().artifacts,
      prePackageAddon: createArtifact(
        'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so',
        'addon-bytes',
        createElfReport('nodeAddon', {
          exportedSymbols: NODE_ADDON_ALLOWED_EXPORTS.filter((symbol) => symbol !== 'cmfa_host_emit_runtime_event_bridge_v1')
        })
      )
    }
  }));
  assert.equal(missingBridgeExport.valid, false);
  assert.match(missingBridgeExport.errors.join('\n'), /exportedSymbols must only contain/u);

  const extraAddonExport = validatePhase1NativeManifest(createStrictManifest({
    artifacts: {
      ...createStrictManifest().artifacts,
      prePackageAddon: createArtifact(
        'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so',
        'addon-bytes',
        createElfReport('nodeAddon', {
          exportedSymbols: [...NODE_ADDON_ALLOWED_EXPORTS, 'napi_register_module_v1']
        })
      )
    }
  }));
  assert.equal(extraAddonExport.valid, false);
  assert.match(extraAddonExport.errors.join('\n'), /exportedSymbols must only contain/u);
});

test('strict manifest validator rejects fail-priority violations, stale invariants, and fake ELF pass reports', async () => {
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  const invalid = validatePhase1NativeManifest(createStrictManifest({
    result: 'incomplete',
    nativeBuildResult: 'pass',
    builds: {
      ...createStrictManifest().builds,
      addon: createBuildStep('fail', ['cmake', '--build'], 0, '', '')
    },
    artifacts: {
      ...createStrictManifest().artifacts,
      prePackageCore: createArtifact('harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so', 'different-core', createElfReport('mihomoCore')),
      hapAddon: createArtifact('libs/arm64-v8a/libentry.so', 'addon-bytes', createElfReport('nodeAddon', {
        neededLibraries: ['libdl.so'],
        exportedSymbols: ['cmfa_forbidden_symbol']
      }))
    },
    failures: [
      {
        code: 'SIGNING_REQUIRED',
        detail: 'unsigned',
        stage: 'signing'
      }
    ]
  }));

  assert.equal(invalid.valid, false);
  assert.match(invalid.errors.join('\n'), /nativeBuildResult fail/u);
  assert.match(invalid.errors.join('\n'), /result fail/u);
  assert.match(invalid.errors.join('\n'), /prePackageCore/u);
  assert.match(invalid.errors.join('\n'), /libdl\.so|dependency|export/u);
});

test('verifyPhase1NativeManifest live-rehashes by identity, rejects repo escape, and catches stale addon bytes', async () => {
  const { verifyPhase1NativeManifest } = await import(provenanceModulePath);
  const manifest = createStrictManifest();
  const liveFs = createLiveFsStub([
    repoRoot,
    path.join(repoRoot, manifest.toolchainLock.path),
    path.join(repoRoot, manifest.artifacts.rawCore.identity),
    path.join(repoRoot, manifest.artifacts.prePackageCore.identity),
    path.join(repoRoot, manifest.artifacts.prePackageAddon.identity),
    path.join(repoRoot, manifest.artifacts.hap.identity)
  ]);

  const valid = await verifyPhase1NativeManifest(manifest, {
    repoRoot,
    fsApi: liveFs,
    hashFileImpl: async (targetPath) => {
      if (targetPath.endsWith('toolchain.lock.json')) {
        return {
          sha256: manifest.toolchainLock.sha256,
          sizeBytes: Buffer.byteLength(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
        };
      }
      if (targetPath.endsWith('libcmfa_mihomo.so')) {
        return {
          sha256: manifest.artifacts.rawCore.sha256,
          sizeBytes: manifest.artifacts.rawCore.sizeBytes
        };
      }
      if (targetPath.endsWith('libentry.so')) {
        return {
          sha256: manifest.artifacts.prePackageAddon.sha256,
          sizeBytes: manifest.artifacts.prePackageAddon.sizeBytes
        };
      }
      return {
        sha256: manifest.artifacts.hap.sha256,
        sizeBytes: manifest.artifacts.hap.sizeBytes
      };
    },
    inspectHapNativeEntriesImpl: async () => ({
      entryCount: 2,
      occurrences: {
        core: 1,
        addon: 1
      },
      artifacts: {
        core: manifest.artifacts.hapCore,
        addon: manifest.artifacts.hapAddon
      },
      failures: []
    }),
    inspectNativeLibraryImpl: async ({ component }) => createElfReport(component)
  });
  assert.equal(valid.valid, true, valid.errors.join('\n'));

  const stale = await verifyPhase1NativeManifest({
    ...manifest,
    artifacts: {
      ...manifest.artifacts,
      prePackageAddon: {
        ...manifest.artifacts.prePackageAddon,
        sha256: sha256('stale-addon')
      }
    }
  }, {
    repoRoot,
    fsApi: liveFs,
    hashFileImpl: async (targetPath) => {
      if (targetPath.endsWith('toolchain.lock.json')) {
        return {
          sha256: manifest.toolchainLock.sha256,
          sizeBytes: Buffer.byteLength(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
        };
      }
      if (targetPath.endsWith('libentry.so')) {
        return {
          sha256: sha256('fresh-addon'),
          sizeBytes: Buffer.byteLength('fresh-addon')
        };
      }
      return {
        sha256: manifest.artifacts.rawCore.sha256,
        sizeBytes: manifest.artifacts.rawCore.sizeBytes
      };
    },
    inspectHapNativeEntriesImpl: async () => ({
      entryCount: 2,
      occurrences: {
        core: 1,
        addon: 1
      },
      artifacts: {
        core: manifest.artifacts.hapCore,
        addon: manifest.artifacts.hapAddon
      },
      failures: []
    }),
    inspectNativeLibraryImpl: async ({ component }) => createElfReport(component)
  });
  assert.equal(stale.valid, false);
  assert.match(stale.errors.join('\n'), /prePackageAddon/u);

  const traversal = await verifyPhase1NativeManifest({
    ...manifest,
    artifacts: {
      ...manifest.artifacts,
      rawCore: {
        ...manifest.artifacts.rawCore,
        identity: '../../outside/libcmfa_mihomo.so'
      }
    }
  }, {
    repoRoot,
    fsApi: liveFs,
    hashFileImpl: async (targetPath) => {
      if (targetPath.endsWith('toolchain.lock.json')) {
        return {
          sha256: manifest.toolchainLock.sha256,
          sizeBytes: Buffer.byteLength(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
        };
      }
      return manifest.artifacts.rawCore;
    },
    inspectNativeLibraryImpl: async ({ component }) => createElfReport(component)
  });
  assert.equal(traversal.valid, false);
  assert.match(traversal.errors.join('\n'), /outside|escape/u);
});

test('verifyPhase1NativeManifest rejects repo-internal symlink identities that resolve outside the real repo root', async () => {
  const { verifyPhase1NativeManifest } = await import(provenanceModulePath);

  for (const variant of [
    { key: 'rawCore', identity: 'harmony/artifacts/libcmfa_mihomo.so', contents: 'core-bytes', elf: createElfReport('mihomoCore') },
    { key: 'prePackageCore', identity: 'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so', contents: 'core-bytes', elf: createElfReport('mihomoCore') },
    { key: 'prePackageAddon', identity: 'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so', contents: 'addon-bytes', elf: createElfReport('nodeAddon') },
    { key: 'hap', identity: 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap', contents: 'hap-bytes', elf: null }
  ]) {
    await withTempDir(`phase1-native-live-symlink-${variant.key}-`, async (tempRoot) => {
      const fakeRepoRoot = path.join(tempRoot, 'repo');
      const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
      const outsideRoot = path.join(tempRoot, 'outside');
      const insidePath = path.join(fakeRepoRoot, variant.identity);
      const outsidePath = path.join(outsideRoot, `${variant.key}${variant.key === 'hap' ? '.hap' : '.bin'}`);
      const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
      let artifactHashCalls = 0;
      let archiveInspectCalled = false;

      await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
      await fs.mkdir(path.dirname(insidePath), { recursive: true });
      await fs.mkdir(path.dirname(outsidePath), { recursive: true });
      await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
      await fs.writeFile(outsidePath, variant.contents, 'utf8');
      await fs.symlink(outsidePath, insidePath);

      const artifact = createArtifact(variant.identity, variant.contents, variant.elf);
      const manifest = createEarlyFailureManifest({
        toolchainLock: {
          path: 'harmony/toolchain.lock.json',
          sha256: sha256(`${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`)
        },
        failures: [
          {
            code: 'PACKAGE_HAP_FAILED',
            detail: 'synthetic fail state',
            stage: 'package-hap'
          }
        ],
        artifacts: {
          rawCore: null,
          prePackageCore: null,
          prePackageAddon: null,
          hap: null,
          hapCore: null,
          hapAddon: null,
          [variant.key]: artifact
        }
      });

      const result = await verifyPhase1NativeManifest(manifest, {
        repoRoot: fakeRepoRoot,
        hashFileImpl: async (targetPath) => {
          if (targetPath === toolchainLockPath) {
            return {
              sha256: manifest.toolchainLock.sha256,
              sizeBytes: Buffer.byteLength(`${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`)
            };
          }
          if (targetPath === insidePath) {
            artifactHashCalls += 1;
            return {
              sha256: artifact.sha256,
              sizeBytes: artifact.sizeBytes
            };
          }
          throw new Error(`unexpected hash target: ${targetPath}`);
        },
        inspectHapNativeEntriesImpl: async () => {
          archiveInspectCalled = true;
          throw new Error('archive inspect should not run for symlink escapes');
        }
      });

      assert.equal(result.valid, false, `${variant.key} should be invalid`);
      assert.match(result.errors.join('\n'), /outside|symlink|repository/u);
      assert.equal(artifactHashCalls, 0, `${variant.key} should be rejected before live hashing`);
      assert.equal(archiveInspectCalled, false, `${variant.key} should never reach archive inspect`);
    });
  }
});

test('verifyPhase1NativeManifest live-reinspects raw and pre-package ELF artifacts with the correct component contracts', async () => {
  const { verifyPhase1NativeManifest } = await import(provenanceModulePath);

  await withTempDir('phase1-native-live-elf-contracts-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const rawCorePath = path.join(fakeHarmonyRoot, 'artifacts', 'libcmfa_mihomo.so');
    const preCorePath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libcmfa_mihomo.so');
    const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
    const observedComponents = [];

    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
    await fs.mkdir(path.dirname(preCorePath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
    await fs.writeFile(preCorePath, 'core-bytes', 'utf8');
    await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');

    const manifest = createEarlyFailureManifest({
      toolchainLock: {
        path: 'harmony/toolchain.lock.json',
        sha256: sha256(`${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`)
      },
      failures: [
        {
          code: 'PACKAGE_HAP_FAILED',
          detail: 'synthetic fail state',
          stage: 'package-hap'
        }
      ],
      artifacts: {
        rawCore: createArtifact('harmony/artifacts/libcmfa_mihomo.so', 'core-bytes', createElfReport('mihomoCore')),
        prePackageCore: createArtifact('harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so', 'core-bytes', createElfReport('mihomoCore')),
        prePackageAddon: createArtifact('harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so', 'addon-bytes', createElfReport('nodeAddon')),
        hap: null,
        hapCore: null,
        hapAddon: null
      }
    });

    const result = await verifyPhase1NativeManifest(manifest, {
      repoRoot: fakeRepoRoot,
      hashFileImpl: async (targetPath) => {
        if (targetPath.endsWith('toolchain.lock.json')) {
          return {
            sha256: manifest.toolchainLock.sha256,
            sizeBytes: Buffer.byteLength(`${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`)
          };
        }
        if (targetPath.endsWith('/harmony/artifacts/libcmfa_mihomo.so') || targetPath.endsWith('/libcmfa_mihomo.so')) {
          return {
            sha256: manifest.artifacts.rawCore.sha256,
            sizeBytes: manifest.artifacts.rawCore.sizeBytes
          };
        }
        return {
          sha256: manifest.artifacts.prePackageAddon.sha256,
          sizeBytes: manifest.artifacts.prePackageAddon.sizeBytes
        };
      },
      inspectNativeLibraryImpl: async ({ libPath, component }) => {
        observedComponents.push({ libPath, component });
        if (libPath.endsWith('/harmony/artifacts/libcmfa_mihomo.so')) {
          return createElfReport(component, { architecture: 'x86_64' });
        }
        if (libPath.endsWith('/libcmfa_mihomo.so')) {
          return createElfReport(component, { neededLibraries: ['libc.so', 'libdl.so'] });
        }
        return createElfReport('mihomoCore');
      }
    });

    assert.equal(result.valid, false);
    assert.match(result.errors.join('\n'), /rawCore/u);
    assert.match(result.errors.join('\n'), /prePackageCore/u);
    assert.match(result.errors.join('\n'), /prePackageAddon/u);
    assert.deepEqual(
      observedComponents.map(({ component }) => component).sort(),
      ['mihomoCore', 'mihomoCore', 'nodeAddon'].sort()
    );
  });
});

test('verifyPhase1NativeManifest rejects persisted ELF reports that do not match the live raw-core inspection', async () => {
  const { verifyPhase1NativeManifest } = await import(provenanceModulePath);

  await withTempDir('phase1-native-live-elf-mismatch-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const rawCorePath = path.join(fakeHarmonyRoot, 'artifacts', 'libcmfa_mihomo.so');

    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');

    const manifest = createEarlyFailureManifest({
      toolchainLock: {
        path: 'harmony/toolchain.lock.json',
        sha256: sha256(`${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`)
      },
      failures: [
        {
          code: 'PACKAGE_HAP_FAILED',
          detail: 'synthetic fail state',
          stage: 'package-hap'
        }
      ],
      artifacts: {
        rawCore: createArtifact('harmony/artifacts/libcmfa_mihomo.so', 'core-bytes', createElfReport('mihomoCore', {
          exportedSymbols: [...createElfReport('mihomoCore').exportedSymbols, '_persisted_only_symbol']
        })),
        prePackageCore: null,
        prePackageAddon: null,
        hap: null,
        hapCore: null,
        hapAddon: null
      }
    });

    const result = await verifyPhase1NativeManifest(manifest, {
      repoRoot: fakeRepoRoot,
      hashFileImpl: async (targetPath) => ({
        sha256: targetPath.endsWith('toolchain.lock.json') ? manifest.toolchainLock.sha256 : manifest.artifacts.rawCore.sha256,
        sizeBytes: targetPath.endsWith('toolchain.lock.json')
          ? Buffer.byteLength(`${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`)
          : manifest.artifacts.rawCore.sizeBytes
      }),
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component)
    });

    assert.equal(result.valid, false);
    assert.match(result.errors.join('\n'), /rawCore/u);
    assert.match(result.errors.join('\n'), /live|persisted|mismatch/u);
  });
});

test('verifyPhase1NativeManifest reports stable live ELF inspection errors for raw artifacts', async () => {
  const { verifyPhase1NativeManifest } = await import(provenanceModulePath);

  await withTempDir('phase1-native-live-elf-throw-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const rawCorePath = path.join(fakeHarmonyRoot, 'artifacts', 'libcmfa_mihomo.so');

    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');

    const manifest = createEarlyFailureManifest({
      toolchainLock: {
        path: 'harmony/toolchain.lock.json',
        sha256: sha256(`${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`)
      },
      failures: [
        {
          code: 'PACKAGE_HAP_FAILED',
          detail: 'synthetic fail state',
          stage: 'package-hap'
        }
      ],
      artifacts: {
        rawCore: createArtifact('harmony/artifacts/libcmfa_mihomo.so', 'core-bytes', createElfReport('mihomoCore')),
        prePackageCore: null,
        prePackageAddon: null,
        hap: null,
        hapCore: null,
        hapAddon: null
      }
    });

    const result = await verifyPhase1NativeManifest(manifest, {
      repoRoot: fakeRepoRoot,
      hashFileImpl: async (targetPath) => ({
        sha256: targetPath.endsWith('toolchain.lock.json') ? manifest.toolchainLock.sha256 : manifest.artifacts.rawCore.sha256,
        sizeBytes: targetPath.endsWith('toolchain.lock.json')
          ? Buffer.byteLength(`${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`)
          : manifest.artifacts.rawCore.sizeBytes
      }),
      inspectNativeLibraryImpl: async () => {
        throw Object.assign(new Error('readelf exploded'), { code: 'READELF_FAILED' });
      }
    });

    assert.equal(result.valid, false);
    assert.match(result.errors.join('\n'), /rawCore/u);
    assert.match(result.errors.join('\n'), /READELF_FAILED|readelf exploded|live ELF/u);
  });
});

test('verifyPhase1NativeManifest skips archive live verification for strict-valid fail manifests with no hap artifact while still rehashing existing files', async () => {
  const { verifyPhase1NativeManifest } = await import(provenanceModulePath);

  for (const variant of [
    {
      label: 'package-fail',
      manifest: {
        ...createStrictManifest({
          result: 'fail',
          nativeBuildResult: 'fail',
          builds: {
            ...createStrictManifest().builds,
            hap: createBuildStep('fail', ['harmony/hvigorw', '--mode', 'module', 'assembleHap'], 17, '', 'hvigor fail')
          },
          artifacts: {
            ...createStrictManifest().artifacts,
            hap: null,
            hapCore: null,
            hapAddon: null
          },
          archive: {
            entryCount: null,
            occurrences: {
              core: null,
              addon: null
            }
          },
          signing: {
            result: 'pass'
          },
          device: {
            result: 'not-run',
            targetCount: null,
            identityMasked: null,
            proofResult: 'not-run'
          },
          failures: [
            { code: 'PACKAGE_HAP_FAILED', detail: 'package failed after selecting hap', stage: 'package-hap' }
          ]
        })
      }
    },
    {
      label: 'external-hap-path',
      manifest: {
        ...createStrictManifest({
          result: 'fail',
          nativeBuildResult: 'fail',
          artifacts: {
            ...createStrictManifest().artifacts,
            hap: null,
            hapCore: null,
            hapAddon: null
          },
          archive: {
            entryCount: null,
            occurrences: {
              core: null,
              addon: null
            }
          },
          signing: {
            result: 'pass'
          },
          device: {
            result: 'not-run',
            targetCount: null,
            identityMasked: null,
            proofResult: 'not-run'
          },
          failures: [
            { code: 'HAP_PATH_OUTSIDE_REPO', detail: 'Selected hap path escapes the repository: ../outside/entry.hap', stage: 'package-hap' }
          ]
        })
      }
    }
  ]) {
    const observedTargets = [];
    let inspectCalled = false;
    const liveFs = createLiveFsStub([
      repoRoot,
      path.join(repoRoot, variant.manifest.toolchainLock.path),
      path.join(repoRoot, variant.manifest.artifacts.rawCore.identity),
      path.join(repoRoot, variant.manifest.artifacts.prePackageCore.identity),
      path.join(repoRoot, variant.manifest.artifacts.prePackageAddon.identity)
    ]);

    const result = await verifyPhase1NativeManifest(variant.manifest, {
      repoRoot,
      fsApi: liveFs,
      hashFileImpl: async (targetPath) => {
        observedTargets.push(targetPath);
        if (targetPath.endsWith('toolchain.lock.json')) {
          return {
            sha256: variant.manifest.toolchainLock.sha256,
            sizeBytes: Buffer.byteLength(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
          };
        }
        if (targetPath.endsWith('harmony/artifacts/libcmfa_mihomo.so') || targetPath.endsWith('libcmfa_mihomo.so')) {
          return {
            sha256: variant.manifest.artifacts.rawCore.sha256,
            sizeBytes: variant.manifest.artifacts.rawCore.sizeBytes
          };
        }
        if (targetPath.endsWith('/libentry.so')) {
          return {
            sha256: variant.manifest.artifacts.prePackageAddon.sha256,
            sizeBytes: variant.manifest.artifacts.prePackageAddon.sizeBytes
          };
        }
        return {
          sha256: variant.manifest.artifacts.prePackageCore.sha256,
          sizeBytes: variant.manifest.artifacts.prePackageCore.sizeBytes
        };
      },
      inspectHapNativeEntriesImpl: async () => {
        inspectCalled = true;
        throw new Error('archive live verification should not run without artifacts.hap');
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component)
    });

    assert.equal(result.valid, true, `${variant.label}: ${result.errors.join('\n')}`);
    assert.equal(inspectCalled, false, `${variant.label} should not inspect HAP entries`);
    assert.equal(observedTargets.length, 4, `${variant.label} should rehash lock/raw/prepackage files`);
    assert.ok(observedTargets.some((targetPath) => targetPath.endsWith('toolchain.lock.json')), `${variant.label} should rehash toolchain lock`);
    assert.ok(observedTargets.some((targetPath) => targetPath.endsWith('harmony/artifacts/libcmfa_mihomo.so') || targetPath.endsWith('/libcmfa_mihomo.so')), `${variant.label} should rehash raw core`);
    assert.ok(observedTargets.some((targetPath) => targetPath.includes('intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so')), `${variant.label} should rehash pre-package core`);
    assert.ok(observedTargets.some((targetPath) => targetPath.includes('intermediates/cmake/default/obj/arm64-v8a/libentry.so')), `${variant.label} should rehash pre-package addon`);
  }
});

test('buildPhase1Native passes HAP helper event callbacks through the real boundaries and strips obsolete persisted fields', async () => {
  const { buildPhase1Native } = await import(buildModulePath);

  await withTempDir('phase1-native-events-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
    const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
    const preCorePath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libcmfa_mihomo.so');
    const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
    const hapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
    const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const events = [];
    let helperOptions = null;

    await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
    await fs.mkdir(path.dirname(hapPath), { recursive: true });
    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      nowSequence: [new Date(isoAt(0)), new Date(isoAt(5000))],
      randomUuidImpl: () => '22222222-3333-4444-8555-666666666666',
      onEvent(event) {
        events.push(event);
      },
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => {
        await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      runCommandImpl: async ({ command, args }) => {
        const joined = [command, ...args].join(' ');
        if (joined.includes('compileNative')) {
          return { command, args, exitCode: 0, stdout: `ok ${process.env.HOME}\n`, stderr: `${signingFixtureFiles.command}\n` };
        }
        if (joined.includes('--build')) {
          await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
          await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
          return { command, args, exitCode: 0, stdout: 'cmake build ok', stderr: '' };
        }
        if (joined.includes('list targets')) {
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
        }
        throw new Error(`unexpected command: ${joined}`);
      },
      buildHapImpl: async () => {
        await fs.mkdir(path.dirname(hapPath), { recursive: true });
        await fs.writeFile(hapPath, 'hap-bytes', 'utf8');
        return {
          result: 'incomplete',
          hap: {
            path: path.relative(fakeRepoRoot, hapPath).split(path.sep).join('/'),
            sha256: sha256('hap-bytes'),
            sizeBytes: Buffer.byteLength('hap-bytes')
          },
          failures: [
            { code: 'SIGNING_REQUIRED', detail: 'unsigned debug hap', stage: 'signing' }
          ],
          commands: [
            {
              stage: 'module',
              command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
              exitCode: 0,
              stdout: 'unsigned build',
              stderr: `skip sign ${signingFixtureFiles.command}`
            }
          ]
        };
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
      inspectHapNativeEntriesImpl: async (input, options = {}) => {
        helperOptions = options;
        options.onEvent?.('list-hap');
        options.onEvent?.('extract-hap-core');
        options.onEvent?.('extract-hap-addon');
        options.onEvent?.('inspect-hap-core');
        options.onEvent?.('inspect-hap-addon');
        return {
          entryCount: 2,
          occurrences: {
            core: 1,
            addon: 1
          },
          artifacts: {
            core: createArtifact('libs/arm64-v8a/libcmfa_mihomo.so', 'core-bytes', createElfReport('mihomoCore')),
            addon: createArtifact('libs/arm64-v8a/libentry.so', 'addon-bytes', createElfReport('nodeAddon'))
          },
          failures: []
        };
      }
    });

    assert.equal(typeof helperOptions?.onEvent, 'function');
    assert.deepEqual(events, [
      'clean',
      'toolchain-lock',
      'inspect-toolchain',
      'verify-native-task',
      'build-core',
      'hash-raw-core',
      'inspect-raw-core',
      'prepare-addon',
      'build-addon',
      'stage-pre-package-core',
      'hash-pre-package-core',
      'hash-pre-package-addon',
      'inspect-pre-package-core',
      'inspect-pre-package-addon',
      'package-hap',
      'hash-hap',
      'list-hap',
      'extract-hap-core',
      'extract-hap-addon',
      'inspect-hap-core',
      'inspect-hap-addon',
      'discover-device',
      'persist'
    ]);
    assert.equal(manifest.result, 'incomplete');
    assert.equal('outputPath' in manifest, false);
    assert.equal('path' in manifest.artifacts.rawCore, false);
    assert.equal('command' in manifest.signing, false);

    const persisted = JSON.parse(await fs.readFile(outputPath, 'utf8'));
    assert.equal('outputPath' in persisted, false);
    assert.equal('path' in persisted.artifacts.rawCore, false);
    assert.equal('command' in persisted.signing, false);
    const persistedJson = JSON.stringify(persisted);
    assert.equal(persistedJson.includes(signingFixtureFiles.command), false);
    assert.equal(persistedJson.includes(joinFragments(['Us', 'ers'])), false);
  });
});

test('buildPhase1Native redacts signing material filenames from persisted command streams, failures, and caught exceptions after path redaction', async () => {
  const { buildPhase1Native } = await import(buildModulePath);

  await withTempDir('phase1-native-signing-redaction-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
    const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
    const preCorePath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libcmfa_mihomo.so');
    const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
    const hapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
    const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const aliceHome = aliceHomeFixture;

    await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
    await fs.mkdir(path.dirname(hapPath), { recursive: true });
    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      env: {
        ...process.env,
        HOME: aliceHome
      },
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => {
        await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('compileNative')) {
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.includes('--build')) {
          await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
          await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.join(' ') === 'list targets') {
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
        }
        throw new Error(`unexpected command: ${args.join(' ')}`);
      },
      buildHapImpl: async () => {
        await fs.mkdir(path.dirname(hapPath), { recursive: true });
        await fs.writeFile(hapPath, 'hap-bytes', 'utf8');
        return {
          result: 'incomplete',
          hap: {
            path: path.relative(fakeRepoRoot, hapPath).split(path.sep).join('/'),
            sha256: sha256('hap-bytes'),
            sizeBytes: Buffer.byteLength('hap-bytes')
          },
          failures: [
            {
              code: 'SIGNING_REQUIRED',
              detail: `needs <home>/${signingFixtureFiles.proof} plus file://${aliceHome}/${signingFixtureFiles.token} before signing can continue`,
              stage: 'signing'
            }
          ],
          commands: [
            {
              stage: 'module',
              command: [
                'harmony/hvigorw',
                '--sign-store',
                path.join(aliceHome, signingFixtureFiles.command),
                '--sign-cert',
                `<home>/${signingFixtureFiles.bundle}`
              ],
              exitCode: 0,
              stdout: `using file://${aliceHome}/${signingFixtureFiles.chain} and <home>/${signingFixtureFiles.local}`,
              stderr: `retry ${path.join(aliceHome, signingFixtureFiles.retryStore)} then <home>/${signingFixtureFiles.mirror}`
            }
          ]
        };
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
      inspectHapNativeEntriesImpl: async () => {
        throw new Error(`archive exploded at <home>/${signingFixtureFiles.archive} after reading file://${aliceHome}/${signingFixtureFiles.raw}`);
      }
    });

    const persisted = JSON.parse(await fs.readFile(outputPath, 'utf8'));
    const persistedJson = JSON.stringify(persisted);

    assert.match(persistedJson, /<signing-material>/u);
    assert.equal(persistedJson.includes(aliceHome), false);
    assert.equal(persistedJson.includes(`file://${aliceHome}`), false);
    for (const fixtureFile of Object.values(signingFixtureFiles)) {
      assert.equal(persistedJson.includes(fixtureFile), false, `${fixtureFile} must be redacted`);
    }
    assert.doesNotMatch(persistedJson, signingFixtureExtensionPattern);
  });
});

test('buildPhase1Native taskTree parser keeps column-zero hvigor connectors inside the compileNative branch and stops before sibling roots', async () => {
  const { buildPhase1Native } = await import(buildModulePath);

  await withTempDir('phase1-native-tasktree-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const outputPath = path.join(fakeHarmonyRoot, 'artifacts', 'phase1-native-provenance.json');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');

    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const siblingOkay = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('taskTree')) {
          return {
            command,
            args,
            exitCode: 0,
            stdout: [
              ':entry:compileNative',
              '+--- :default@BuildNativeWithCmake',
              '    +--- :default@ConfigureCmake',
              '        \\--- :default@PreBuild',
              ':entry:PreviewBuild',
              '+--- :default@PackageHap'
            ].join('\n'),
            stderr: ''
          };
        }
        return {
          command,
          args,
          exitCode: 1,
          stdout: '',
          stderr: ''
        };
      },
      buildMihomoOhosImpl: async () => ({
        result: 'fail',
        components: {
          mihomoCore: { result: 'fail', artifactPath: null }
        },
        failures: [
          { code: 'CORE_BUILD_FAILED', detail: 'expected later failure', stage: 'build-core' }
        ]
      })
    });
    assert.ok(!siblingOkay.failures.some((entry) => entry.code === 'NATIVE_TASK_BUILD_NATIVE_MISSING'));
    assert.ok(!siblingOkay.failures.some((entry) => entry.code === 'NATIVE_TASK_PACKAGE_HAP_FORBIDDEN'));
    assert.ok(siblingOkay.failures.some((entry) => entry.code === 'CORE_BUILD_FAILED'));

    const ansiSiblingOkay = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('taskTree')) {
          return {
            command,
            args,
            exitCode: 0,
            stdout: [
              ':entry:compileNative',
              '+--- :default@BuildNativeWithCmake',
              '\u001b[32m:entry:PreviewBuild\u001b[0m',
              '+--- :default@PackageHap'
            ].join('\n'),
            stderr: ''
          };
        }
        return {
          command,
          args,
          exitCode: 1,
          stdout: '',
          stderr: ''
        };
      },
      buildMihomoOhosImpl: async () => ({
        result: 'fail',
        components: {
          mihomoCore: { result: 'fail', artifactPath: null }
        },
        failures: [
          { code: 'CORE_BUILD_FAILED', detail: 'expected later failure', stage: 'build-core' }
        ]
      })
    });
    assert.ok(!ansiSiblingOkay.failures.some((entry) => entry.code === 'NATIVE_TASK_BUILD_NATIVE_MISSING'));
    assert.ok(!ansiSiblingOkay.failures.some((entry) => entry.code === 'NATIVE_TASK_PACKAGE_HAP_FORBIDDEN'));
  });
});

test('buildPhase1Native taskTree parser still forbids PackageHap inside the compileNative branch and ignores indented pseudo roots', async () => {
  const { buildPhase1Native } = await import(buildModulePath);

  await withTempDir('phase1-native-tasktree-branch-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const outputPath = path.join(fakeHarmonyRoot, 'artifacts', 'phase1-native-provenance.json');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');

    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const packageHapForbidden = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      runCommandImpl: async ({ command, args }) => ({
        command,
        args,
        exitCode: 0,
        stdout: [
          ':entry:compileNative',
          '+--- :default@BuildNativeWithCmake',
          '    +--- :default@ConfigureCmake',
          '+--- :default@PackageHap'
        ].join('\n'),
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => ({
        result: 'fail',
        components: {
          mihomoCore: { result: 'fail', artifactPath: null }
        },
        failures: [
          { code: 'CORE_BUILD_FAILED', detail: 'expected later failure', stage: 'build-core' }
        ]
      })
    });
    assert.ok(!packageHapForbidden.failures.some((entry) => entry.code === 'NATIVE_TASK_BUILD_NATIVE_MISSING'));
    assert.ok(packageHapForbidden.failures.some((entry) => entry.code === 'NATIVE_TASK_PACKAGE_HAP_FORBIDDEN'));

    const ansiPackageHapForbidden = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      runCommandImpl: async ({ command, args }) => ({
        command,
        args,
        exitCode: 0,
        stdout: [
          '\u001b[35m:entry:compileNative\u001b[0m',
          '+--- :default@BuildNativeWithCmake',
          '\u001b[31m+--- :default@PackageHap\u001b[0m'
        ].join('\n'),
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => ({
        result: 'fail',
        components: {
          mihomoCore: { result: 'fail', artifactPath: null }
        },
        failures: [
          { code: 'CORE_BUILD_FAILED', detail: 'expected later failure', stage: 'build-core' }
        ]
      })
    });
    assert.ok(!ansiPackageHapForbidden.failures.some((entry) => entry.code === 'NATIVE_TASK_BUILD_NATIVE_MISSING'));
    assert.ok(ansiPackageHapForbidden.failures.some((entry) => entry.code === 'NATIVE_TASK_PACKAGE_HAP_FORBIDDEN'));

    const indentedPseudoRoot = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      runCommandImpl: async ({ command, args }) => ({
        command,
        args,
        exitCode: 0,
        stdout: '  :entry:compileNative\n    +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      })
    });
    assert.ok(indentedPseudoRoot.failures.some((entry) => entry.code === 'NATIVE_TASK_ROOT_MISSING'));

    const ansiIndentedPseudoRoot = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      runCommandImpl: async ({ command, args }) => ({
        command,
        args,
        exitCode: 0,
        stdout: '  \u001b[36m:entry:compileNative\u001b[0m\n    +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      })
    });
    assert.ok(ansiIndentedPseudoRoot.failures.some((entry) => entry.code === 'NATIVE_TASK_ROOT_MISSING'));
  });
});

test('buildPhase1Native requires a fresh addon mtime and stops before device discovery on archive failures', async () => {
  const { buildPhase1Native } = await import(buildModulePath);

  await withTempDir('phase1-native-stale-addon-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const rawCorePath = path.join(fakeHarmonyRoot, 'artifacts', 'libcmfa_mihomo.so');
    const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const outputPath = path.join(fakeHarmonyRoot, 'artifacts', 'phase1-native-provenance.json');
    const events = [];

    await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      nowSequence: [new Date(isoAt(1000)), new Date(isoAt(5000))],
      onEvent(event) {
        events.push(event);
      },
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => {
        await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('compileNative')) {
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.includes('--build')) {
          await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
          await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
          await fs.utimes(preAddonPath, new Date(isoAt(0)), new Date(isoAt(0)));
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.join(' ') === 'list targets') {
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
        }
        throw new Error(`unexpected command: ${args.join(' ')}`);
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
      buildHapImpl: async () => ({
        result: 'pass',
        hap: {
          path: 'harmony/entry/build/default/outputs/default/entry-default.hap',
          sha256: sha256('hap-bytes'),
          sizeBytes: Buffer.byteLength('hap-bytes')
        },
        failures: [],
        commands: []
      })
    });

    assert.equal(manifest.result, 'fail');
    assert.ok(manifest.failures.some((entry) => /ADDON.*STALE|STALE_ADDON/u.test(entry.code) || /fresh addon/i.test(entry.detail)));
    assert.ok(!events.includes('discover-device'));
  });
});

test('runCli maps validate/build exit codes deterministically with the explicit validate-path contract', async () => {
  const { runCli } = await import(buildModulePath);

  const validateExit = await runCli({
    argv: ['--validate', 'harmony/artifacts/phase1-native-provenance.json'],
    verifyManifestImpl: async () => ({
      manifest: createEarlyFailureManifest(),
      valid: true,
      errors: []
    }),
    stdout: { write() {} }
  });
  assert.equal(validateExit, 0);

  const incompleteExit = await runCli({
    argv: [],
    buildPhase1NativeImpl: async () => createStrictManifest({
      result: 'incomplete',
      nativeBuildResult: 'pass',
      signing: {
        result: 'incomplete'
      },
      device: {
        result: 'incomplete',
        targetCount: 0,
        identityMasked: null,
        proofResult: 'not-run'
      },
      failures: [
        { code: 'SIGNING_REQUIRED', detail: 'unsigned', stage: 'signing' }
      ]
    }),
    stdout: { write() {} }
  });
  assert.equal(incompleteExit, 1);

  const failExit = await runCli({
    argv: [],
    buildPhase1NativeImpl: async () => createEarlyFailureManifest(),
    stdout: { write() {} }
  });
  assert.equal(failExit, 2);
});

test('buildPhase1Native uses the exact hvigor argv for taskTree and compileNative without --no-daemon', async () => {
  const { buildPhase1Native } = await import(buildModulePath);

  await withTempDir('phase1-native-argv-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const rawCorePath = path.join(fakeHarmonyRoot, 'artifacts', 'libcmfa_mihomo.so');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const outputPath = path.join(fakeHarmonyRoot, 'artifacts', 'phase1-native-provenance.json');
    const seenTaskTreeArgs = [];
    const seenCompileNativeArgs = [];

    await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      buildMihomoOhosImpl: async () => {
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('taskTree')) {
          seenTaskTreeArgs.push([...args]);
          return {
            command,
            args,
            exitCode: 0,
            stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
            stderr: ''
          };
        }
        if (args.includes('compileNative')) {
          seenCompileNativeArgs.push([...args]);
          return {
            command,
            args,
            exitCode: 1,
            stdout: '',
            stderr: 'expected stop after argv capture'
          };
        }
        throw new Error(`unexpected command: ${args.join(' ')}`);
      }
    });

    assert.equal(manifest.result, 'fail');
    assert.deepEqual(seenTaskTreeArgs, [[
      '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', '-p', 'buildMode=debug', 'taskTree'
    ]]);
    assert.deepEqual(seenCompileNativeArgs, [[
      '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', '-p', 'buildMode=debug', 'compileNative'
    ]]);
  });
});

test('phase1 CLI rejects mixed --out and --validate in either order', async () => {
  const { parseCliArguments } = await import(buildModulePath);

  for (const argv of [
    ['--validate', 'harmony/artifacts/a.json', '--out', 'harmony/artifacts/b.json'],
    ['--out', 'harmony/artifacts/b.json', '--validate', 'harmony/artifacts/a.json']
  ]) {
    assert.throws(
      () => parseCliArguments(argv, repoRoot),
      (error) => error?.code === 'ARGUMENT_INVALID',
      `expected ${argv.join(' ')} to fail`
    );
  }
});

test('phase1 manifest validator requires strict phase2 self-test evidence and rejects impossible combinations', async () => {
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  const missing = createStrictManifest();
  delete missing.phase2SelfTest;
  const missingValidation = validatePhase1NativeManifest(missing);
  assert.equal(missingValidation.valid, false);
  assert.match(missingValidation.errors.join('\n'), /phase2SelfTest/u);

  const inconsistent = validatePhase1NativeManifest(createStrictManifest({
    phase2SelfTest: {
      enabled: true,
      activation: 'default',
      purpose: 'production',
      releaseStatus: 'releasable'
    }
  }));
  assert.equal(inconsistent.valid, false);
  assert.match(inconsistent.errors.join('\n'), /phase2SelfTest/u);
});

test('buildPhase1Native stamps strict self-test provenance, forwards explicit lane intent, and clears stale self-test env by default', async () => {
  const { buildPhase1Native, HAP_NATIVE_ENTRIES } = await import(buildModulePath);
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  for (const variant of [
    { label: 'production', enabled: false, expected: createPhase2SelfTestEvidence(false) },
    { label: 'self-test', enabled: true, expected: createPhase2SelfTestEvidence(true) }
  ]) {
    await withTempDir(`phase1-native-self-test-${variant.label}-`, async (tempRoot) => {
      const fakeRepoRoot = path.join(tempRoot, 'repo');
      const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
      const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
      const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
      const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
      const hapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
      const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
      const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
      const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
      const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
      const observedEnvs = [];
      let observedBuildHapOptions = null;

      await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
      await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
      await fs.mkdir(path.dirname(hdcPath), { recursive: true });
      await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
      await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
      await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
      await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

      const manifest = await buildPhase1Native({
        harmonyRoot: fakeHarmonyRoot,
        repoRoot: fakeRepoRoot,
        outputPath,
        env: {
          ...process.env,
          CMFA_ENABLE_PHASE2_SELFTEST: '1',
          CMFA_TEST_BUILD_ABI: '1'
        },
        phase2SelfTestEnabled: variant.enabled,
        inspectToolchainImpl: async () => ({
          report: {
            schemaVersion: '1.0.0',
            result: 'pass',
            target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
            installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
            tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
            failures: []
          },
          resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
        }),
        inspectTaskTreeImpl: async () => ({
          rootTask: ':entry:compileNative',
          hasBuildNativeWithCmake: true,
          hasPackageHap: false,
          exitCode: 0,
          stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
          stderr: ''
        }),
        buildMihomoOhosImpl: async (options) => {
          observedEnvs.push({ stage: 'build-core', env: options.env });
          await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
          await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
          return {
            result: 'pass',
            components: {
              mihomoCore: { result: 'pass', artifactPath: rawCorePath }
            },
            failures: []
          };
        },
        runCommandImpl: async ({ command, args, env }) => {
          if (args.includes('compileNative')) {
            observedEnvs.push({ stage: 'prepare-addon', env });
            return { command, args, exitCode: 0, stdout: '', stderr: '' };
          }
          if (args.includes('--build')) {
            observedEnvs.push({ stage: 'build-addon', env });
            await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
            await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
            return { command, args, exitCode: 0, stdout: '', stderr: '' };
          }
          if (args.join(' ') === 'list targets') {
            return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
          }
          throw new Error(`unexpected command: ${command} ${args.join(' ')}`);
        },
        buildHapImpl: async (options) => {
          observedBuildHapOptions = options;
          await fs.mkdir(path.dirname(hapPath), { recursive: true });
          await fs.writeFile(hapPath, 'hap-bytes', 'utf8');
          return {
            schemaVersion: '1.0.0',
            phase: 0,
            result: 'incomplete',
            harmonyRoot: 'harmony',
            outputPath: 'harmony/artifacts/phase0-build-evidence.json',
            timestamps: {
              startedAt: isoAt(0),
              completedAt: isoAt(1)
            },
            toolchain: {
              nodeVersion: process.version.replace(/^v/u, ''),
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
            phase2SelfTest: variant.expected,
            commands: [
              {
                stage: 'module',
                command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
                exitCode: 0,
                stdout: '',
                stderr: ''
              }
            ],
            hap: {
              path: path.relative(fakeRepoRoot, hapPath).split(path.sep).join('/'),
              sha256: sha256('hap-bytes'),
              sizeBytes: Buffer.byteLength('hap-bytes')
            },
            failures: [
              {
                code: 'SIGNING_REQUIRED',
                detail: 'unsigned',
                stage: 'signing'
              }
            ]
          };
        },
        inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
        inspectHapNativeEntriesImpl: async () => ({
          entryCount: 2,
          occurrences: { core: 1, addon: 1 },
          artifacts: {
            core: createArtifact(HAP_NATIVE_ENTRIES.core, 'core-bytes', createElfReport('mihomoCore')),
            addon: createArtifact(HAP_NATIVE_ENTRIES.addon, 'addon-bytes', createElfReport('nodeAddon'))
          },
          failures: []
        })
      });

      assert.deepEqual(manifest.phase2SelfTest, variant.expected);
      assert.equal(observedBuildHapOptions.phase2SelfTestEnabled, variant.enabled);
      assert.deepEqual(observedBuildHapOptions.env.CMFA_ENABLE_PHASE2_SELFTEST, variant.enabled ? '1' : undefined);
      assert.deepEqual(observedBuildHapOptions.env.CMFA_TEST_BUILD_ABI, variant.enabled ? '1' : undefined);
      for (const observed of observedEnvs) {
        assert.equal(observed.env.CMFA_ENABLE_PHASE2_SELFTEST, variant.enabled ? '1' : undefined, `${variant.label} lane must control CMFA_ENABLE_PHASE2_SELFTEST explicitly during ${observed.stage}`);
        assert.equal(observed.env.CMFA_TEST_BUILD_ABI, variant.enabled ? '1' : undefined, `${variant.label} lane must control CMFA_TEST_BUILD_ABI explicitly during ${observed.stage}`);
      }
      assert.equal(validatePhase1NativeManifest(manifest).valid, true);
    });
  }
});

test('buildPhase1Native rejects buildHap reports that omit strict phase2 self-test evidence', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  await withTempDir('phase1-native-buildhap-phase2-invalid-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
    const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
    const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
    const hapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
    let archiveCalled = false;
    let deviceDiscoveryCalled = false;

    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => {
        await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('compileNative')) {
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.includes('--build')) {
          await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
          await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.join(' ') === 'list targets') {
          deviceDiscoveryCalled = true;
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
        }
        throw new Error(`unexpected command: ${command} ${args.join(' ')}`);
      },
      buildHapImpl: async () => {
        await fs.mkdir(path.dirname(hapPath), { recursive: true });
        await fs.writeFile(hapPath, 'hap-bytes', 'utf8');
        return {
          schemaVersion: '1.0.0',
          phase: 0,
          result: 'incomplete',
          harmonyRoot: 'harmony',
          outputPath: 'harmony/artifacts/phase0-build-evidence.json',
          timestamps: {
            startedAt: isoAt(0),
            completedAt: isoAt(1)
          },
          toolchain: {
            nodeVersion: process.version.replace(/^v/u, ''),
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
          commands: [
            {
              stage: 'module',
              command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
              exitCode: 0,
              stdout: '',
              stderr: ''
            }
          ],
          hap: {
            path: path.relative(fakeRepoRoot, hapPath).split(path.sep).join('/'),
            sha256: sha256('hap-bytes'),
            sizeBytes: Buffer.byteLength('hap-bytes')
          },
          failures: [
            {
              code: 'SIGNING_REQUIRED',
              detail: 'unsigned',
              stage: 'signing'
            }
          ]
        };
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
      inspectHapNativeEntriesImpl: async () => {
        archiveCalled = true;
        throw new Error('archive should not run when buildHap report is malformed');
      }
    });

    assert.equal(archiveCalled, false);
    assert.equal(deviceDiscoveryCalled, false);
    assert.ok(manifest.failures.some((entry) => entry.code === 'PACKAGE_HAP_REPORT_INVALID' && entry.stage === 'package-hap'));
    assert.equal(validatePhase1NativeManifest(manifest).valid, true);
  });
});

test('inspectHapNativeEntries keeps extracted files present through inspect, emits real ordered events, and removes the run temp dir on inspect failure', async () => {
  const { inspectHapNativeEntries } = await import(provenanceModulePath);
  const { HAP_NATIVE_ENTRIES: entries } = await import(buildModulePath);

  await withTempDir('phase1-native-boundary-', async (tempRoot) => {
    const events = [];
    const existsAtInspect = [];
    const runId = 'run-boundary';
    const runScopedDir = path.join(tempRoot, `phase1-native-${runId}`);

    await assert.rejects(async () => {
      await inspectHapNativeEntries({
        hapPath: '/tmp/archive.hap',
        runId
      }, {
        tempRoot,
        listHapEntriesImpl: async () => ({
          entryCount: 2,
          entries: [entries.core, entries.addon],
          occurrences: {
            [entries.core]: 1,
            [entries.addon]: 1
          }
        }),
        spawnImpl: createSpawnForExtraction({
          stdout: 'binary-payload'
        }),
        inspectNativeLibraryImpl: async ({ libPath, component }) => {
          let exists = true;
          try {
            await fs.access(libPath);
          } catch {
            exists = false;
          }
          existsAtInspect.push({ component, exists });
          if (component === 'nodeAddon') {
            throw Object.assign(new Error('addon inspect exploded'), { code: 'ADDON_INSPECT_FAILED' });
          }
          return createElfReport(component);
        },
        onEvent(eventName) {
          events.push(eventName);
        }
      });
    }, /addon inspect exploded/u);

    assert.deepEqual(events, [
      'list-hap',
      'extract-hap-core',
      'extract-hap-addon',
      'inspect-hap-core',
      'inspect-hap-addon'
    ]);
    assert.deepEqual(existsAtInspect, [
      { component: 'mihomoCore', exists: true },
      { component: 'nodeAddon', exists: true }
    ]);
    await assert.rejects(fs.access(runScopedDir));
  });
});

test('buildPhase1Native turns raw-core ELF contract drift into a stable native failure without PHASE1_MANIFEST_INVALID or downstream execution', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  await withTempDir('phase1-native-raw-elf-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const rawCorePath = path.join(fakeHarmonyRoot, 'artifacts', 'libcmfa_mihomo.so');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const outputPath = path.join(fakeHarmonyRoot, 'artifacts', 'phase1-native-provenance.json');
    let compileNativeCalled = false;
    let packageCalled = false;

    await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => {
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component, {
        architecture: 'x86_64'
      }),
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('compileNative')) {
          compileNativeCalled = true;
        }
        throw new Error(`unexpected downstream command: ${command} ${args.join(' ')}`);
      },
      buildHapImpl: async () => {
        packageCalled = true;
        throw new Error('package should not run after raw ELF drift');
      }
    });

    assert.equal(compileNativeCalled, false);
    assert.equal(packageCalled, false);
    assert.equal(manifest.artifacts.rawCore, null);
    assert.ok(manifest.failures.some((entry) => entry.code === 'RAW_CORE_ELF_INVALID' && entry.stage === 'build-core'));
    assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'));
    assert.equal(validatePhase1NativeManifest(manifest).valid, true);
  });
});

test('buildPhase1Native turns HAP addon ELF contract drift into a stable archive failure without device discovery or PHASE1_MANIFEST_INVALID', async () => {
  const { buildPhase1Native, HAP_NATIVE_ENTRIES } = await import(buildModulePath);
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  await withTempDir('phase1-native-hap-elf-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
    const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
    const preCorePath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libcmfa_mihomo.so');
    const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
    const hapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
    let discoverDeviceCalled = false;

    await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
    await fs.mkdir(path.dirname(hapPath), { recursive: true });
    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => {
        await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('compileNative')) {
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.includes('--build')) {
          await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
          await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.join(' ') === 'list targets') {
          discoverDeviceCalled = true;
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
        }
        throw new Error(`unexpected command: ${args.join(' ')}`);
      },
      buildHapImpl: async () => {
        await fs.mkdir(path.dirname(hapPath), { recursive: true });
        await fs.writeFile(hapPath, 'hap-bytes', 'utf8');
        return {
          result: 'incomplete',
          hap: {
            path: path.relative(fakeRepoRoot, hapPath).split(path.sep).join('/'),
            sha256: sha256('hap-bytes'),
            sizeBytes: Buffer.byteLength('hap-bytes')
          },
          failures: [{ code: 'SIGNING_REQUIRED', detail: 'unsigned', stage: 'signing' }],
          commands: [
            {
              stage: 'module',
              command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
              exitCode: 0,
              stdout: '',
              stderr: ''
            }
          ]
        };
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
      inspectHapNativeEntriesImpl: async (input, options = {}) => {
        options.onEvent?.('list-hap');
        options.onEvent?.('extract-hap-core');
        options.onEvent?.('extract-hap-addon');
        options.onEvent?.('inspect-hap-core');
        options.onEvent?.('inspect-hap-addon');
        return {
          entryCount: 2,
          occurrences: { core: 1, addon: 1 },
          artifacts: {
            core: createArtifact(HAP_NATIVE_ENTRIES.core, 'core-bytes', createElfReport('mihomoCore')),
            addon: createArtifact(HAP_NATIVE_ENTRIES.addon, 'addon-bytes', createElfReport('nodeAddon', {
              exportedSymbols: ['_init', 'bad_symbol']
            }))
          },
          failures: []
        };
      }
    });

    assert.equal(discoverDeviceCalled, false);
    assert.equal(manifest.artifacts.hapAddon, null);
    assert.ok(manifest.failures.some((entry) => entry.code === 'HAP_ADDON_ELF_INVALID' && entry.stage === 'archive'));
    assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'));
    assert.equal(validatePhase1NativeManifest(manifest).valid, true);
  });
});

test('buildPhase1Native records a strict-valid package failure when buildHap fails after selecting a hap path', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  await withTempDir('phase1-native-package-fail-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
    const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
    const preCorePath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libcmfa_mihomo.so');
    const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
    const hapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
    let archiveCalled = false;
    let discoverDeviceCalled = false;

    await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
    await fs.mkdir(path.dirname(hapPath), { recursive: true });
    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => {
        await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('compileNative')) {
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.includes('--build')) {
          await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
          await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.join(' ') === 'list targets') {
          discoverDeviceCalled = true;
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
        }
        throw new Error(`unexpected command: ${args.join(' ')}`);
      },
      buildHapImpl: async () => {
        await fs.mkdir(path.dirname(hapPath), { recursive: true });
        await fs.writeFile(hapPath, 'hap-bytes', 'utf8');
        return {
          result: 'fail',
          hap: {
            path: path.relative(fakeRepoRoot, hapPath).split(path.sep).join('/'),
            sha256: sha256('hap-bytes'),
            sizeBytes: Buffer.byteLength('hap-bytes')
          },
          failures: [
            { code: 'MODULE_BUILD_FAILED', detail: 'hvigor failed after selecting hap', stage: 'package-hap' }
          ],
          commands: [
            {
              stage: 'module',
              command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
              exitCode: 17,
              stdout: '',
              stderr: 'hvigor fail'
            }
          ]
        };
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
      inspectHapNativeEntriesImpl: async () => {
        archiveCalled = true;
        throw new Error('archive should not run after package fail');
      }
    });

    assert.equal(archiveCalled, false);
    assert.equal(discoverDeviceCalled, false);
    assert.equal(manifest.builds.hap.result, 'fail');
    assert.equal(manifest.builds.hap.exitCode, 17);
    assert.equal(manifest.signing.result, 'pass');
    assert.equal(manifest.artifacts.hap, null);
    assert.ok(manifest.failures.some((entry) => entry.code === 'PACKAGE_HAP_FAILED' && entry.stage === 'package-hap'));
    assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'));
    assert.equal(validatePhase1NativeManifest(manifest).valid, true);
  });
});

test('buildPhase1Native rejects repo-external hap paths before archive hashing and persists a strict-valid fail manifest', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  await withTempDir('phase1-native-external-hap-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
    const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
    const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
    const outsideHapPath = path.join(tempRoot, 'outside', 'entry-default-unsigned.hap');
    let archiveCalled = false;
    let discoverDeviceCalled = false;

    await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.mkdir(path.dirname(outsideHapPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(outsideHapPath, 'hap-bytes', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => {
        await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('compileNative')) {
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.includes('--build')) {
          await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
          await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.join(' ') === 'list targets') {
          discoverDeviceCalled = true;
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
        }
        throw new Error(`unexpected command: ${args.join(' ')}`);
      },
      buildHapImpl: async () => ({
        result: 'pass',
        hap: {
          path: outsideHapPath,
          sha256: sha256('hap-bytes'),
          sizeBytes: Buffer.byteLength('hap-bytes')
        },
        failures: [],
        commands: [
          {
            stage: 'module',
            command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
            exitCode: 0,
            stdout: '',
            stderr: ''
          }
        ]
      }),
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
      inspectHapNativeEntriesImpl: async () => {
        archiveCalled = true;
        throw new Error('archive should not run for external hap path');
      }
    });

    assert.equal(archiveCalled, false);
    assert.equal(discoverDeviceCalled, false);
    assert.equal(manifest.artifacts.hap, null);
    assert.ok(manifest.failures.some((entry) => /PATH_OUTSIDE_REPO|HAP.*PATH/u.test(entry.code) && entry.stage === 'package-hap'));
    assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'));
    assert.equal(validatePhase1NativeManifest(manifest).valid, true);
  });
});

test('buildPhase1Native rejects repo-internal canonical hap symlinks that resolve outside the real repo before hash/archive', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest, verifyPhase1NativeManifest } = await import(provenanceModulePath);

  await withTempDir('phase1-native-symlink-hap-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
    const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
    const preCorePath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libcmfa_mihomo.so');
    const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
    const insideHapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
    const outsideHapPath = path.join(tempRoot, 'outside', 'entry-default-unsigned.hap');
    let archiveCalled = false;
    let discoverDeviceCalled = false;

    await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.mkdir(path.dirname(outsideHapPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(outsideHapPath, 'hap-bytes', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => {
        await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('compileNative')) {
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.includes('--build')) {
          await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
          await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.join(' ') === 'list targets') {
          discoverDeviceCalled = true;
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
        }
        throw new Error(`unexpected command: ${args.join(' ')}`);
      },
      buildHapImpl: async () => {
        await fs.mkdir(path.dirname(insideHapPath), { recursive: true });
        await fs.symlink(outsideHapPath, insideHapPath);
        return {
          result: 'pass',
          hap: {
            path: 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap',
            sha256: sha256('hap-bytes'),
            sizeBytes: Buffer.byteLength('hap-bytes')
          },
          failures: [],
          commands: [
            {
              stage: 'module',
              command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
              exitCode: 0,
              stdout: '',
              stderr: ''
            }
          ]
        };
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
      inspectHapNativeEntriesImpl: async () => {
        archiveCalled = true;
        throw new Error('archive should not run for symlink hap path');
      }
    });

    assert.equal(archiveCalled, false);
    assert.equal(discoverDeviceCalled, false);
    assert.equal(manifest.artifacts.hap, null);
    assert.equal(manifest.device.result, 'not-run');
    assert.ok(manifest.failures.some((entry) => /HAP_PATH_OUTSIDE_REPO|SYMLINK|REALPATH/u.test(entry.code) && entry.stage === 'package-hap'));
    assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'));
    assert.equal(validatePhase1NativeManifest(manifest).valid, true);

    const liveVerification = await verifyPhase1NativeManifest(manifest, {
      repoRoot: fakeRepoRoot,
      hashFileImpl: async (targetPath) => {
        if (targetPath.endsWith('toolchain.lock.json')) {
          return {
            sha256: manifest.toolchainLock.sha256,
            sizeBytes: Buffer.byteLength(`${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`)
          };
        }
        if (
          targetPath.endsWith('/harmony/artifacts/libcmfa_mihomo.so') ||
          targetPath.endsWith('/harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so')
        ) {
          return {
            sha256: manifest.artifacts.rawCore.sha256,
            sizeBytes: manifest.artifacts.rawCore.sizeBytes
          };
        }
        if (targetPath.endsWith('/harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so')) {
          return {
            sha256: manifest.artifacts.prePackageAddon.sha256,
            sizeBytes: manifest.artifacts.prePackageAddon.sizeBytes
          };
        }
        throw new Error(`unexpected live hash target: ${targetPath}`);
      },
      inspectHapNativeEntriesImpl: async () => {
        throw new Error('live verify archive should not run for rejected symlink hap');
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component)
    });
    assert.equal(liveVerification.valid, true, liveVerification.errors.join('\n'));
  });
});

test('buildPhase1Native snapshots the selected HAP before hash/archive so post-validation path swaps cannot prove outside bytes', async () => {
  const { buildPhase1Native } = await import(buildModulePath);

  await withTempDir('phase1-native-hap-swap-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
    const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
    const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
    const insideHapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
    const outsideHapPath = path.join(tempRoot, 'outside', 'entry-default-unsigned.hap');
    const insideBytes = 'inside-hap-bytes';
    const outsideBytes = 'outside-hap-bytes';
    let observedArchivePath = null;
    let observedArchiveBytes = null;

    await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.mkdir(path.dirname(outsideHapPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(outsideHapPath, outsideBytes, 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      onEvent(event) {
        if (event === 'hash-hap') {
          void (async () => {
            await fs.rm(insideHapPath, { force: true });
            await fs.symlink(outsideHapPath, insideHapPath);
          })();
        }
      },
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => {
        await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('compileNative')) {
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.includes('--build')) {
          await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
          await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.join(' ') === 'list targets') {
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
        }
        throw new Error(`unexpected command: ${args.join(' ')}`);
      },
      buildHapImpl: async () => {
        await fs.mkdir(path.dirname(insideHapPath), { recursive: true });
        await fs.writeFile(insideHapPath, insideBytes, 'utf8');
        return {
          result: 'pass',
          hap: {
            path: 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap',
            sha256: sha256(insideBytes),
            sizeBytes: Buffer.byteLength(insideBytes)
          },
          failures: [],
          commands: [
            {
              stage: 'module',
              command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
              exitCode: 0,
              stdout: '',
              stderr: ''
            }
          ]
        };
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
      inspectHapNativeEntriesImpl: async ({ hapPath }) => {
        observedArchivePath = hapPath;
        observedArchiveBytes = await fs.readFile(hapPath, 'utf8');
        return {
          entryCount: 2,
          occurrences: { core: 1, addon: 1 },
          artifacts: {
            core: createArtifact('libs/arm64-v8a/libcmfa_mihomo.so', 'core-bytes', createElfReport('mihomoCore')),
            addon: createArtifact('libs/arm64-v8a/libentry.so', 'addon-bytes', createElfReport('nodeAddon'))
          },
          failures: []
        };
      }
    });

    assert.notEqual(manifest.artifacts.hap?.sha256, sha256(outsideBytes));
    assert.notEqual(observedArchiveBytes, outsideBytes);
    assert.equal(manifest.artifacts.hap?.sha256, sha256(insideBytes));
    assert.equal(observedArchiveBytes, insideBytes);
    assert.equal(manifest.artifacts.hap?.identity, 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap');
    assert.notEqual(observedArchivePath, insideHapPath);
    assert.equal(await fs.readFile(outsideHapPath, 'utf8'), outsideBytes);
  });
});

test('buildPhase1Native cleans up HAP snapshot files after archive exceptions and never persists temp snapshot paths', async () => {
  const { buildPhase1Native } = await import(buildModulePath);

  await withTempDir('phase1-native-hap-snapshot-cleanup-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
    const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
    const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
    const insideHapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
    let observedArchivePath = null;

    await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => {
        await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      runCommandImpl: async ({ command, args }) => {
        if (args.includes('compileNative')) {
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.includes('--build')) {
          await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
          await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (args.join(' ') === 'list targets') {
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
        }
        throw new Error(`unexpected command: ${args.join(' ')}`);
      },
      buildHapImpl: async () => {
        await fs.mkdir(path.dirname(insideHapPath), { recursive: true });
        await fs.writeFile(insideHapPath, 'hap-bytes', 'utf8');
        return {
          result: 'pass',
          hap: {
            path: 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap',
            sha256: sha256('hap-bytes'),
            sizeBytes: Buffer.byteLength('hap-bytes')
          },
          failures: [],
          commands: [
            {
              stage: 'module',
              command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
              exitCode: 0,
              stdout: '',
              stderr: ''
            }
          ]
        };
      },
      inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
      inspectHapNativeEntriesImpl: async ({ hapPath }) => {
        observedArchivePath = hapPath;
        throw Object.assign(new Error('archive exploded after snapshot'), { code: 'ARCHIVE_BROKEN' });
      }
    });

    assert.ok(manifest.failures.some((entry) => entry.code === 'ARCHIVE_BROKEN' && entry.stage === 'archive'));
    assert.notEqual(observedArchivePath, insideHapPath);
    await assert.rejects(fs.access(observedArchivePath));
    const serialized = JSON.stringify(manifest);
    assert.doesNotMatch(serialized, /phase1-native-snapshot|selected\.hap|\/private\/var\/folders|\/var\/folders/u);
  });
});

test('buildPhase1Native rejects repo-internal non-canonical hap paths before hash/archive and keeps fail manifests strict-valid and live-verifiable', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest, verifyPhase1NativeManifest } = await import(provenanceModulePath);

  for (const variant of [
    {
      label: 'wrong-place',
      hapPath: 'harmony/artifacts/wrong-place.hap',
      buildHapResult: 'pass',
      buildHapFailures: []
    },
    {
      label: 'nested-under-default',
      hapPath: 'harmony/entry/build/default/outputs/default/nested/entry-default-unsigned.hap',
      buildHapResult: 'pass',
      buildHapFailures: []
    },
    {
      label: 'non-hap-extension',
      hapPath: 'harmony/entry/build/default/outputs/default/entry-default-unsigned.bin',
      buildHapResult: 'pass',
      buildHapFailures: []
    },
    {
      label: 'non-canonical-segments',
      hapPath: 'harmony/entry/build/default/outputs/default/../default/entry-default-unsigned.hap',
      buildHapResult: 'incomplete',
      buildHapFailures: [
        { code: 'SIGNING_REQUIRED', detail: `unsigned because ${signingFixtureFiles.command} missing`, stage: 'signing' }
      ]
    }
  ]) {
    await withTempDir(`phase1-native-invalid-hap-${variant.label}-`, async (tempRoot) => {
      const fakeRepoRoot = path.join(tempRoot, 'repo');
      const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
      const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
      const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
      const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
      const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
      const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
      const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
      const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
      let archiveCalled = false;
      let discoverDeviceCalled = false;
      let liveVerifyArchiveCalled = false;

      await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
      await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
      await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
      await fs.mkdir(path.dirname(hdcPath), { recursive: true });
      await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
      await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
      await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
      await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

      const manifest = await buildPhase1Native({
        harmonyRoot: fakeHarmonyRoot,
        repoRoot: fakeRepoRoot,
        outputPath,
        inspectToolchainImpl: async () => ({
          report: {
            schemaVersion: '1.0.0',
            result: 'pass',
            target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
            installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
            tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
            failures: []
          },
          resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
        }),
        inspectTaskTreeImpl: async () => ({
          rootTask: ':entry:compileNative',
          hasBuildNativeWithCmake: true,
          hasPackageHap: false,
          exitCode: 0,
          stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
          stderr: ''
        }),
        buildMihomoOhosImpl: async () => {
          await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
          await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
          return {
            result: 'pass',
            components: {
              mihomoCore: { result: 'pass', artifactPath: rawCorePath }
            },
            failures: []
          };
        },
        runCommandImpl: async ({ command, args }) => {
          if (args.includes('compileNative')) {
            return { command, args, exitCode: 0, stdout: '', stderr: '' };
          }
          if (args.includes('--build')) {
            await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
            await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
            return { command, args, exitCode: 0, stdout: '', stderr: '' };
          }
          if (args.join(' ') === 'list targets') {
            discoverDeviceCalled = true;
            return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
          }
          throw new Error(`unexpected command: ${args.join(' ')}`);
        },
        buildHapImpl: async () => ({
          result: variant.buildHapResult,
          hap: {
            path: variant.hapPath,
            sha256: sha256('hap-bytes'),
            sizeBytes: Buffer.byteLength('hap-bytes')
          },
          failures: variant.buildHapFailures,
          commands: [
            {
              stage: 'module',
              command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
              exitCode: 0,
              stdout: '',
              stderr: ''
            }
          ]
        }),
        inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
        inspectHapNativeEntriesImpl: async () => {
          archiveCalled = true;
          throw new Error('archive should not run for invalid repo-internal hap paths');
        }
      });

      assert.equal(archiveCalled, false, `${variant.label} should not archive-inspect`);
      assert.equal(discoverDeviceCalled, false, `${variant.label} should not discover device`);
      assert.equal(manifest.artifacts.hap, null, `${variant.label} should keep hap artifact null`);
      assert.deepEqual(manifest.archive, {
        entryCount: null,
        occurrences: {
          core: null,
          addon: null
        }
      });
      assert.equal(manifest.device.result, 'not-run');
      assert.ok(manifest.failures.some((entry) => entry.code === 'HAP_PATH_INVALID' && entry.stage === 'package-hap'), `${variant.label} should record HAP_PATH_INVALID`);
      assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'), `${variant.label} must not fall back to manifest invalid`);
      assert.equal(validatePhase1NativeManifest(manifest).valid, true, `${variant.label}: ${validatePhase1NativeManifest(manifest).errors.join('\n')}`);

      const liveVerification = await verifyPhase1NativeManifest(manifest, {
        repoRoot: fakeRepoRoot,
        hashFileImpl: async (targetPath) => {
          if (targetPath.endsWith('toolchain.lock.json')) {
            return {
              sha256: manifest.toolchainLock.sha256,
              sizeBytes: Buffer.byteLength(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
            };
          }
          if (targetPath.endsWith('harmony/artifacts/libcmfa_mihomo.so') || targetPath.endsWith('/libcmfa_mihomo.so')) {
            return {
              sha256: manifest.artifacts.rawCore.sha256,
              sizeBytes: manifest.artifacts.rawCore.sizeBytes
            };
          }
          if (targetPath.endsWith('/libentry.so')) {
            return {
              sha256: manifest.artifacts.prePackageAddon.sha256,
              sizeBytes: manifest.artifacts.prePackageAddon.sizeBytes
            };
          }
          return {
            sha256: manifest.artifacts.prePackageCore.sha256,
            sizeBytes: manifest.artifacts.prePackageCore.sizeBytes
          };
        },
        inspectHapNativeEntriesImpl: async () => {
          liveVerifyArchiveCalled = true;
          throw new Error('live verify archive should not run for invalid repo-internal hap paths');
        },
        inspectNativeLibraryImpl: async ({ component }) => createElfReport(component)
      });

      assert.equal(liveVerifyArchiveCalled, false, `${variant.label} live verify should not inspect HAP`);
      assert.equal(liveVerification.valid, true, `${variant.label}: ${liveVerification.errors.join('\n')}`);
    });
  }
});

test('buildPhase1Native restores a live-verifiable pre-package core after buildHap removes the cmake output copy in both lanes', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest, verifyPhase1NativeManifest } = await import(provenanceModulePath);
  const { HAP_NATIVE_ENTRIES: entries } = await import(buildModulePath);

  for (const variant of [
    { label: 'default', phase2SelfTestEnabled: false },
    { label: 'phase2-self-test', phase2SelfTestEnabled: true }
  ]) {
    await withTempDir(`phase1-native-restore-precore-${variant.label}-`, async (tempRoot) => {
      const fakeRepoRoot = path.join(tempRoot, 'repo');
      const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
      const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
      const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
      const prePackageCorePath = path.join(
        fakeHarmonyRoot,
        'entry',
        'build',
        'default',
        'intermediates',
        'cmake',
        'default',
        'obj',
        'arm64-v8a',
        'libcmfa_mihomo.so'
      );
      const preAddonPath = path.join(
        fakeHarmonyRoot,
        'entry',
        'build',
        'default',
        'intermediates',
        'cmake',
        'default',
        'obj',
        'arm64-v8a',
        'libentry.so'
      );
      const hapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
      const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
      const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
      const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
      const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');

      await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
      await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
      await fs.mkdir(path.dirname(hdcPath), { recursive: true });
      await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
      await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
      await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
      await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

      const manifest = await buildPhase1Native({
        harmonyRoot: fakeHarmonyRoot,
        repoRoot: fakeRepoRoot,
        outputPath,
        phase2SelfTestEnabled: variant.phase2SelfTestEnabled,
        inspectToolchainImpl: async () => ({
          report: {
            schemaVersion: '1.0.0',
            result: 'pass',
            target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
            installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
            tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
            failures: []
          },
          resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
        }),
        inspectTaskTreeImpl: async () => ({
          rootTask: ':entry:compileNative',
          hasBuildNativeWithCmake: true,
          hasPackageHap: false,
          exitCode: 0,
          stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
          stderr: ''
        }),
        buildMihomoOhosImpl: async () => {
          await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
          await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
          return {
            result: 'pass',
            components: {
              mihomoCore: { result: 'pass', artifactPath: rawCorePath }
            },
            failures: []
          };
        },
        runCommandImpl: async ({ command, args, env }) => {
          const joined = [command, ...args].join(' ');
          if (joined.includes('compileNative')) {
            assert.equal(env.CMFA_ENABLE_PHASE2_SELFTEST, variant.phase2SelfTestEnabled ? '1' : undefined, `${variant.label} compileNative lane must set CMFA_ENABLE_PHASE2_SELFTEST correctly`);
            return { command, args, exitCode: 0, stdout: '', stderr: '' };
          }
          if (joined.includes('--build')) {
            assert.equal(env.CMFA_ENABLE_PHASE2_SELFTEST, variant.phase2SelfTestEnabled ? '1' : undefined, `${variant.label} addon build lane must set CMFA_ENABLE_PHASE2_SELFTEST correctly`);
            await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
            await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
            return { command, args, exitCode: 0, stdout: '', stderr: '' };
          }
          if (joined.includes('list targets')) {
            return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
          }
          throw new Error(`unexpected command: ${joined}`);
        },
        buildHapImpl: async ({ env, phase2SelfTestEnabled }) => {
          assert.equal(env.CMFA_ENABLE_PHASE2_SELFTEST, variant.phase2SelfTestEnabled ? '1' : undefined, `${variant.label} buildHap lane must set CMFA_ENABLE_PHASE2_SELFTEST correctly`);
          assert.equal(phase2SelfTestEnabled, variant.phase2SelfTestEnabled, `${variant.label} buildHap lane must preserve phase2SelfTestEnabled intent`);
          await fs.rm(path.dirname(prePackageCorePath), { recursive: true, force: true });
          await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
          await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
          await fs.mkdir(path.dirname(hapPath), { recursive: true });
          await fs.writeFile(hapPath, 'hap-bytes', 'utf8');
          return {
            result: 'incomplete',
            phase2SelfTest: createPhase2SelfTestEvidence(variant.phase2SelfTestEnabled),
            hap: {
              path: path.relative(fakeRepoRoot, hapPath).split(path.sep).join('/'),
              sha256: sha256('hap-bytes'),
              sizeBytes: Buffer.byteLength('hap-bytes')
            },
            failures: [{ code: 'SIGNING_REQUIRED', detail: 'unsigned', stage: 'signing' }],
            commands: [
              {
                stage: 'module',
                command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
                exitCode: 0,
                stdout: '',
                stderr: ''
              }
            ]
          };
        },
        inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
        inspectHapNativeEntriesImpl: async () => ({
          entryCount: 2,
          occurrences: { core: 1, addon: 1 },
          artifacts: {
            core: createArtifact(entries.core, 'core-bytes', createElfReport('mihomoCore')),
            addon: createArtifact(entries.addon, 'addon-bytes', createElfReport('nodeAddon'))
          },
          failures: []
        })
      });

      const persisted = JSON.parse(await fs.readFile(outputPath, 'utf8'));
      const manifestValidation = validatePhase1NativeManifest(manifest);
      const persistedValidation = validatePhase1NativeManifest(persisted);

      assert.equal(manifest.nativeBuildResult, 'pass', `${variant.label} lane should keep nativeBuildResult=pass`);
      assert.equal(manifest.phase2SelfTest.enabled, variant.phase2SelfTestEnabled);
      assert.equal(persisted.phase2SelfTest.enabled, variant.phase2SelfTestEnabled);
      assert.equal(manifestValidation.valid, true, `${variant.label}: ${manifestValidation.errors.join('\n')}`);
      assert.equal(persistedValidation.valid, true, `${variant.label}: ${persistedValidation.errors.join('\n')}`);
      assert.equal(await fs.readFile(prePackageCorePath, 'utf8'), 'core-bytes');
      assert.equal(
        manifest.artifacts.prePackageCore.identity,
        'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so'
      );
      assert.equal(
        persisted.artifacts.prePackageCore.identity,
        'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so'
      );
      assert.deepEqual(
        {
          sha256: manifest.artifacts.prePackageCore.sha256,
          sizeBytes: manifest.artifacts.prePackageCore.sizeBytes,
          elf: manifest.artifacts.prePackageCore.elf
        },
        {
          sha256: manifest.artifacts.rawCore.sha256,
          sizeBytes: manifest.artifacts.rawCore.sizeBytes,
          elf: manifest.artifacts.rawCore.elf
        }
      );
      assert.deepEqual(
        {
          sha256: persisted.artifacts.prePackageCore.sha256,
          sizeBytes: persisted.artifacts.prePackageCore.sizeBytes,
          elf: persisted.artifacts.prePackageCore.elf
        },
        {
          sha256: persisted.artifacts.rawCore.sha256,
          sizeBytes: persisted.artifacts.rawCore.sizeBytes,
          elf: persisted.artifacts.rawCore.elf
        }
      );
      assert.deepEqual(
        {
          sha256: persisted.artifacts.prePackageCore.sha256,
          sizeBytes: persisted.artifacts.prePackageCore.sizeBytes,
          elf: persisted.artifacts.prePackageCore.elf
        },
        {
          sha256: persisted.artifacts.hapCore.sha256,
          sizeBytes: persisted.artifacts.hapCore.sizeBytes,
          elf: persisted.artifacts.hapCore.elf
        }
      );

      const liveVerification = await verifyPhase1NativeManifest(persisted, {
        repoRoot: fakeRepoRoot,
        inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
        inspectHapNativeEntriesImpl: async () => ({
          entryCount: 2,
          occurrences: { core: 1, addon: 1 },
          artifacts: {
            core: createArtifact(entries.core, 'core-bytes', createElfReport('mihomoCore')),
            addon: createArtifact(entries.addon, 'addon-bytes', createElfReport('nodeAddon'))
          },
          failures: []
        })
      });

      assert.equal(liveVerification.valid, true, `${variant.label}: ${liveVerification.errors.join('\n')}`);
    });
  }
});

test('buildPhase1Native rejects missing or invalid resolved hdc paths without PATH fallback and keeps the fail manifest strict-valid', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest, verifyPhase1NativeManifest } = await import(provenanceModulePath);

  for (const variant of [
    { label: 'null', hdcPath: null },
    { label: 'missing', hdcPath: undefined },
    { label: 'empty', hdcPath: '' },
    { label: 'nonstring', hdcPath: 17 }
  ]) {
    await withTempDir(`phase1-native-hdc-${variant.label}-`, async (tempRoot) => {
      const fakeRepoRoot = path.join(tempRoot, 'repo');
      const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
      const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
      const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
      const outputPath = path.join(fakeHarmonyRoot, 'artifacts', 'phase1-native-provenance.json');
      let buildCoreCalled = false;
      let compileNativeCalled = false;
      let deviceDiscoveryCalled = false;

      await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
      await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
      await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
      await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
      await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');

      const manifest = await buildPhase1Native({
        harmonyRoot: fakeHarmonyRoot,
        repoRoot: fakeRepoRoot,
        outputPath,
        inspectToolchainImpl: async () => ({
          report: {
            schemaVersion: '1.0.0',
            result: 'pass',
            target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
            installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
            tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
            failures: []
          },
          resolved: { paths: { cmakeExecutable, hdc: variant.hdcPath } }
        }),
        inspectTaskTreeImpl: async () => ({
          rootTask: ':entry:compileNative',
          hasBuildNativeWithCmake: true,
          hasPackageHap: false,
          exitCode: 0,
          stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
          stderr: ''
        }),
        buildMihomoOhosImpl: async () => {
          buildCoreCalled = true;
          throw new Error('core build should not run when resolved hdc path is invalid');
        },
        runCommandImpl: async ({ command, args }) => {
          if (args.includes('compileNative')) {
            compileNativeCalled = true;
          }
          if (args.join(' ') === 'list targets') {
            deviceDiscoveryCalled = true;
          }
          throw new Error(`unexpected command: ${command} ${args.join(' ')}`);
        }
      });

      assert.equal(buildCoreCalled, false, `${variant.label} should stop before build-core`);
      assert.equal(compileNativeCalled, false, `${variant.label} should stop before compileNative`);
      assert.equal(deviceDiscoveryCalled, false, `${variant.label} should never call hdc`);
      assert.equal(manifest.device.result, 'not-run');
      assert.ok(manifest.failures.some((entry) => entry.code === 'TOOLCHAIN_HDC_PATH_INVALID' && entry.stage === 'toolchain'), `${variant.label} should record TOOLCHAIN_HDC_PATH_INVALID`);
      assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'));
      const validation = validatePhase1NativeManifest(manifest);
      assert.equal(validation.valid, true, `${variant.label}: ${validation.errors.join('\n')}`);

      const liveVerification = await verifyPhase1NativeManifest(manifest, {
        repoRoot: fakeRepoRoot,
        hashFileImpl: async (targetPath) => ({
          sha256: manifest.toolchainLock.sha256,
          sizeBytes: Buffer.byteLength(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
        }),
        inspectHapNativeEntriesImpl: async () => {
          throw new Error('live verify archive should not run for early hdc-path failures');
        }
      });
      assert.equal(liveVerification.valid, true, `${variant.label}: ${liveVerification.errors.join('\n')}`);
    });
  }
});

test('buildPhase1Native rejects missing or invalid resolved cmake executable paths and keeps the fail manifest strict-valid', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest, verifyPhase1NativeManifest } = await import(provenanceModulePath);

  for (const variant of [
    { label: 'null', cmakeExecutable: null },
    { label: 'missing', cmakeExecutable: undefined },
    { label: 'empty', cmakeExecutable: '' },
    { label: 'nonstring', cmakeExecutable: 17 },
    { label: 'relative', cmakeExecutable: 'relative-cmake' }
  ]) {
    await withTempDir(`phase1-native-cmake-${variant.label}-`, async (tempRoot) => {
      const fakeRepoRoot = path.join(tempRoot, 'repo');
      const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
      const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
      const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
      const outputPath = path.join(fakeHarmonyRoot, 'artifacts', 'phase1-native-provenance.json');
      let buildCoreCalled = false;
      let compileNativeCalled = false;
      let cmakeBuildCalled = false;
      let deviceDiscoveryCalled = false;

      await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
      await fs.mkdir(path.dirname(hdcPath), { recursive: true });
      await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
      await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
      await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

      const manifest = await buildPhase1Native({
        harmonyRoot: fakeHarmonyRoot,
        repoRoot: fakeRepoRoot,
        outputPath,
        inspectToolchainImpl: async () => ({
          report: {
            schemaVersion: '1.0.0',
            result: 'pass',
            target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
            installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
            tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
            failures: []
          },
          resolved: { paths: { cmakeExecutable: variant.cmakeExecutable, hdc: hdcPath } }
        }),
        inspectTaskTreeImpl: async () => ({
          rootTask: ':entry:compileNative',
          hasBuildNativeWithCmake: true,
          hasPackageHap: false,
          exitCode: 0,
          stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
          stderr: ''
        }),
        buildMihomoOhosImpl: async () => {
          buildCoreCalled = true;
          throw new Error('core build should not run when resolved cmake path is invalid');
        },
        runCommandImpl: async ({ command, args }) => {
          if (args.includes('compileNative')) {
            compileNativeCalled = true;
          }
          if (command === 'relative-cmake' || args.includes('--build')) {
            cmakeBuildCalled = true;
          }
          if (args.join(' ') === 'list targets') {
            deviceDiscoveryCalled = true;
          }
          throw new Error(`unexpected command: ${command} ${args.join(' ')}`);
        }
      });

      assert.equal(buildCoreCalled, false, `${variant.label} should stop before build-core`);
      assert.equal(compileNativeCalled, false, `${variant.label} should stop before compileNative`);
      assert.equal(cmakeBuildCalled, false, `${variant.label} must never invoke cmake --build`);
      assert.equal(deviceDiscoveryCalled, false, `${variant.label} should never call hdc`);
      assert.equal(manifest.device.result, 'not-run');
      assert.ok(
        manifest.failures.some((entry) => ['TOOLCHAIN_CMAKE_PATH_INVALID', 'TOOLCHAIN_INSPECTION_FAILED'].includes(entry.code) && entry.stage === 'toolchain'),
        `${variant.label} should record a stable toolchain/cmake failure`
      );
      assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'));
      const validation = validatePhase1NativeManifest(manifest);
      assert.equal(validation.valid, true, `${variant.label}: ${validation.errors.join('\n')}`);

      const liveVerification = await verifyPhase1NativeManifest(manifest, {
        repoRoot: fakeRepoRoot,
        hashFileImpl: async () => ({
          sha256: manifest.toolchainLock.sha256,
          sizeBytes: Buffer.byteLength(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
        }),
        inspectHapNativeEntriesImpl: async () => {
          throw new Error('live verify archive should not run for early cmake-path failures');
        }
      });
      assert.equal(liveVerification.valid, true, `${variant.label}: ${liveVerification.errors.join('\n')}`);
    });
  }
});

test('buildPhase1Native rejects malformed inspectToolchain reports before taskTree and keeps the fail manifest strict-valid', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest, verifyPhase1NativeManifest } = await import(provenanceModulePath);

  for (const variant of [
    { label: 'report-null', inspection: ({ cmakeExecutable, hdcPath }) => ({ report: null, resolved: { paths: { cmakeExecutable, hdc: hdcPath } } }) },
    { label: 'report-missing', inspection: ({ cmakeExecutable, hdcPath }) => ({ resolved: { paths: { cmakeExecutable, hdc: hdcPath } } }) },
    { label: 'result-missing', inspection: ({ cmakeExecutable, hdcPath }) => ({ report: { failures: [] }, resolved: { paths: { cmakeExecutable, hdc: hdcPath } } }) },
    { label: 'result-unknown', inspection: ({ cmakeExecutable, hdcPath }) => ({ report: { result: 'mystery', failures: [] }, resolved: { paths: { cmakeExecutable, hdc: hdcPath } } }) },
    { label: 'failures-string', inspection: ({ cmakeExecutable, hdcPath }) => ({ report: { result: 'pass', failures: 'boom' }, resolved: { paths: { cmakeExecutable, hdc: hdcPath } } }) },
    { label: 'failure-nonobject', inspection: ({ cmakeExecutable, hdcPath }) => ({ report: { result: 'pass', failures: [17] }, resolved: { paths: { cmakeExecutable, hdc: hdcPath } } }) },
    { label: 'failure-missing-code', inspection: ({ cmakeExecutable, hdcPath }) => ({ report: { result: 'pass', failures: [{ detail: 'broken' }] }, resolved: { paths: { cmakeExecutable, hdc: hdcPath } } }) },
    { label: 'failure-empty-detail', inspection: ({ cmakeExecutable, hdcPath }) => ({ report: { result: 'pass', failures: [{ code: 'BROKEN', detail: '' }] }, resolved: { paths: { cmakeExecutable, hdc: hdcPath } } }) }
  ]) {
    await withTempDir(`phase1-native-toolchain-report-${variant.label}-`, async (tempRoot) => {
      const fakeRepoRoot = path.join(tempRoot, 'repo');
      const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
      const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
      const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
      const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
      const outputPath = path.join(fakeHarmonyRoot, 'artifacts', 'phase1-native-provenance.json');
      let taskTreeCalled = false;
      let buildCoreCalled = false;
      let compileNativeCalled = false;
      let deviceDiscoveryCalled = false;

      await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
      await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
      await fs.mkdir(path.dirname(hdcPath), { recursive: true });
      await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
      await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
      await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
      await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

      const manifest = await buildPhase1Native({
        harmonyRoot: fakeHarmonyRoot,
        repoRoot: fakeRepoRoot,
        outputPath,
        inspectToolchainImpl: async () => variant.inspection({ cmakeExecutable, hdcPath }),
        inspectTaskTreeImpl: async () => {
          taskTreeCalled = true;
          throw new Error('taskTree should not run when inspectToolchain report is malformed');
        },
        buildMihomoOhosImpl: async () => {
          buildCoreCalled = true;
          throw new Error('core build should not run when inspectToolchain report is malformed');
        },
        runCommandImpl: async ({ args }) => {
          if (args.includes('compileNative')) {
            compileNativeCalled = true;
          }
          if (args.join(' ') === 'list targets') {
            deviceDiscoveryCalled = true;
          }
          throw new Error(`unexpected command: ${args.join(' ')}`);
        }
      });

      assert.equal(taskTreeCalled, false, `${variant.label} should stop before taskTree`);
      assert.equal(buildCoreCalled, false, `${variant.label} should stop before build-core`);
      assert.equal(compileNativeCalled, false, `${variant.label} should stop before compileNative`);
      assert.equal(deviceDiscoveryCalled, false, `${variant.label} should never call hdc`);
      assert.ok(manifest.failures.some((entry) => entry.code === 'TOOLCHAIN_REPORT_INVALID' && entry.stage === 'toolchain'), `${variant.label} should record TOOLCHAIN_REPORT_INVALID`);
      assert.ok(manifest.failures.some((entry) => entry.code === 'TOOLCHAIN_INSPECTION_FAILED' && entry.stage === 'toolchain'), `${variant.label} should record TOOLCHAIN_INSPECTION_FAILED`);
      assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'), `${variant.label} must not fall back to PHASE1_MANIFEST_INVALID`);
      const validation = validatePhase1NativeManifest(manifest);
      assert.equal(validation.valid, true, `${variant.label}: ${validation.errors.join('\n')}`);

      const liveVerification = await verifyPhase1NativeManifest(manifest, {
        repoRoot: fakeRepoRoot,
        hashFileImpl: async () => ({
          sha256: manifest.toolchainLock.sha256,
          sizeBytes: Buffer.byteLength(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
        }),
        inspectHapNativeEntriesImpl: async () => {
          throw new Error('live verify archive should not run for malformed toolchain reports');
        }
      });
      assert.equal(liveVerification.valid, true, `${variant.label}: ${liveVerification.errors.join('\n')}`);
    });
  }
});

test('buildPhase1Native stops after legal non-pass inspectToolchain reports and normalizes copied failures to toolchain stage', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest, verifyPhase1NativeManifest } = await import(provenanceModulePath);

  for (const variant of [
    { label: 'fail', result: 'fail' },
    { label: 'incomplete', result: 'incomplete' }
  ]) {
    await withTempDir(`phase1-native-toolchain-nonpass-${variant.label}-`, async (tempRoot) => {
      const fakeRepoRoot = path.join(tempRoot, 'repo');
      const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
      const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
      const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
      const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
      const outputPath = path.join(fakeHarmonyRoot, 'artifacts', 'phase1-native-provenance.json');
      let taskTreeCalled = false;
      let buildCoreCalled = false;
      let compileNativeCalled = false;
      let deviceDiscoveryCalled = false;

      await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
      await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
      await fs.mkdir(path.dirname(hdcPath), { recursive: true });
      await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
      await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
      await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
      await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

      const manifest = await buildPhase1Native({
        harmonyRoot: fakeHarmonyRoot,
        repoRoot: fakeRepoRoot,
        outputPath,
        inspectToolchainImpl: async () => ({
          report: {
            schemaVersion: '1.0.0',
            result: variant.result,
            target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
            installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
            tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
            failures: [
              {
                code: 'SDK_METADATA_MISSING',
                detail: path.posix.join('signing', signingFixtureFiles.testStore),
                stage: 'foreign-stage'
              }
            ]
          },
          resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
        }),
        inspectTaskTreeImpl: async () => {
          taskTreeCalled = true;
          throw new Error('taskTree should not run when inspectToolchain report is non-pass');
        },
        buildMihomoOhosImpl: async () => {
          buildCoreCalled = true;
          throw new Error('core build should not run when inspectToolchain report is non-pass');
        },
        runCommandImpl: async ({ args }) => {
          if (args.includes('compileNative')) {
            compileNativeCalled = true;
          }
          if (args.join(' ') === 'list targets') {
            deviceDiscoveryCalled = true;
          }
          throw new Error(`unexpected command: ${args.join(' ')}`);
        }
      });

      assert.equal(taskTreeCalled, false, `${variant.label} should stop before taskTree`);
      assert.equal(buildCoreCalled, false, `${variant.label} should stop before build-core`);
      assert.equal(compileNativeCalled, false, `${variant.label} should stop before compileNative`);
      assert.equal(deviceDiscoveryCalled, false, `${variant.label} should never call hdc`);
      assert.ok(manifest.failures.some((entry) => entry.code === 'TOOLCHAIN_INSPECTION_FAILED' && entry.stage === 'toolchain'));
      assert.ok(manifest.failures.some((entry) => entry.code === 'SDK_METADATA_MISSING' && entry.stage === 'toolchain' && entry.detail.includes('<signing-material>')));
      assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'));
      const validation = validatePhase1NativeManifest(manifest);
      assert.equal(validation.valid, true, `${variant.label}: ${validation.errors.join('\n')}`);

      const liveVerification = await verifyPhase1NativeManifest(manifest, {
        repoRoot: fakeRepoRoot,
        hashFileImpl: async () => ({
          sha256: manifest.toolchainLock.sha256,
          sizeBytes: Buffer.byteLength(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
        }),
        inspectHapNativeEntriesImpl: async () => {
          throw new Error('live verify archive should not run for non-pass toolchain reports');
        }
      });
      assert.equal(liveVerification.valid, true, `${variant.label}: ${liveVerification.errors.join('\n')}`);
    });
  }
});

test('buildPhase1Native rejects malformed buildHap reports before hash/archive and keeps fail manifests strict-valid and live-verifiable', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest, verifyPhase1NativeManifest } = await import(provenanceModulePath);

  for (const variant of [
    {
      label: 'missing-result',
      report: ({ hapPath, repoRoot }) => ({
        hap: {
          path: path.relative(repoRoot, hapPath).split(path.sep).join('/'),
          sha256: sha256('hap-bytes'),
          sizeBytes: Buffer.byteLength('hap-bytes')
        },
        failures: [],
        commands: [
          {
            stage: 'module',
            command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
            exitCode: 0,
            stdout: '',
            stderr: ''
          }
        ]
      })
    },
    {
      label: 'unknown-result',
      report: ({ hapPath, repoRoot }) => ({
        result: 'mystery',
        hap: {
          path: path.relative(repoRoot, hapPath).split(path.sep).join('/'),
          sha256: sha256('hap-bytes'),
          sizeBytes: Buffer.byteLength('hap-bytes')
        },
        failures: [],
        commands: [
          {
            stage: 'module',
            command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
            exitCode: 0,
            stdout: '',
            stderr: ''
          }
        ]
      })
    },
    {
      label: 'commands-missing',
      report: ({ hapPath, repoRoot }) => ({
        result: 'pass',
        hap: {
          path: path.relative(repoRoot, hapPath).split(path.sep).join('/'),
          sha256: sha256('hap-bytes'),
          sizeBytes: Buffer.byteLength('hap-bytes')
        },
        failures: []
      })
    },
    {
      label: 'commands-empty',
      report: ({ hapPath, repoRoot }) => ({
        result: 'pass',
        hap: {
          path: path.relative(repoRoot, hapPath).split(path.sep).join('/'),
          sha256: sha256('hap-bytes'),
          sizeBytes: Buffer.byteLength('hap-bytes')
        },
        failures: [],
        commands: []
      })
    },
    {
      label: 'commands-nonarray',
      report: ({ hapPath, repoRoot }) => ({
        result: 'pass',
        hap: {
          path: path.relative(repoRoot, hapPath).split(path.sep).join('/'),
          sha256: sha256('hap-bytes'),
          sizeBytes: Buffer.byteLength('hap-bytes')
        },
        failures: [],
        commands: 'assembleHap'
      })
    },
    {
      label: 'command-not-string-array',
      report: ({ hapPath, repoRoot }) => ({
        result: 'pass',
        hap: {
          path: path.relative(repoRoot, hapPath).split(path.sep).join('/'),
          sha256: sha256('hap-bytes'),
          sizeBytes: Buffer.byteLength('hap-bytes')
        },
        failures: [],
        commands: [
          {
            stage: 'module',
            command: 'harmony/hvigorw --mode module assembleHap',
            exitCode: 0,
            stdout: '',
            stderr: ''
          }
        ]
      })
    },
    {
      label: 'exitcode-missing',
      report: ({ hapPath, repoRoot }) => ({
        result: 'pass',
        hap: {
          path: path.relative(repoRoot, hapPath).split(path.sep).join('/'),
          sha256: sha256('hap-bytes'),
          sizeBytes: Buffer.byteLength('hap-bytes')
        },
        failures: [],
        commands: [
          {
            stage: 'module',
            command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
            stdout: '',
            stderr: ''
          }
        ]
      })
    },
    {
      label: 'exitcode-null',
      report: ({ hapPath, repoRoot }) => ({
        result: 'pass',
        hap: {
          path: path.relative(repoRoot, hapPath).split(path.sep).join('/'),
          sha256: sha256('hap-bytes'),
          sizeBytes: Buffer.byteLength('hap-bytes')
        },
        failures: [],
        commands: [
          {
            stage: 'module',
            command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
            exitCode: null,
            stdout: '',
            stderr: ''
          }
        ]
      })
    },
    {
      label: 'exitcode-string',
      report: ({ hapPath, repoRoot }) => ({
        result: 'pass',
        hap: {
          path: path.relative(repoRoot, hapPath).split(path.sep).join('/'),
          sha256: sha256('hap-bytes'),
          sizeBytes: Buffer.byteLength('hap-bytes')
        },
        failures: [],
        commands: [
          {
            stage: 'module',
            command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
            exitCode: '0',
            stdout: '',
            stderr: ''
          }
        ]
      })
    }
  ]) {
    await withTempDir(`phase1-native-badhap-${variant.label}-`, async (tempRoot) => {
      const fakeRepoRoot = path.join(tempRoot, 'repo');
      const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
      const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
      const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
      const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
      const hapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
      const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
      const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
      const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
      const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
      let archiveCalled = false;
      let discoverDeviceCalled = false;
      let liveVerifyArchiveCalled = false;

      await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
      await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
      await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
      await fs.mkdir(path.dirname(hdcPath), { recursive: true });
      await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
      await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
      await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
      await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

      const manifest = await buildPhase1Native({
        harmonyRoot: fakeHarmonyRoot,
        repoRoot: fakeRepoRoot,
        outputPath,
        inspectToolchainImpl: async () => ({
          report: {
            schemaVersion: '1.0.0',
            result: 'pass',
            target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
            installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
            tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
            failures: []
          },
          resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
        }),
        inspectTaskTreeImpl: async () => ({
          rootTask: ':entry:compileNative',
          hasBuildNativeWithCmake: true,
          hasPackageHap: false,
          exitCode: 0,
          stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
          stderr: ''
        }),
        buildMihomoOhosImpl: async () => {
          await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
          await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
          return {
            result: 'pass',
            components: {
              mihomoCore: { result: 'pass', artifactPath: rawCorePath }
            },
            failures: []
          };
        },
        runCommandImpl: async ({ command, args }) => {
          if (args.includes('compileNative')) {
            return { command, args, exitCode: 0, stdout: '', stderr: '' };
          }
          if (args.includes('--build')) {
            await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
            await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
            return { command, args, exitCode: 0, stdout: '', stderr: '' };
          }
          if (args.join(' ') === 'list targets') {
            discoverDeviceCalled = true;
            return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
          }
          throw new Error(`unexpected command: ${args.join(' ')}`);
        },
        buildHapImpl: async () => {
          await fs.mkdir(path.dirname(hapPath), { recursive: true });
          await fs.writeFile(hapPath, 'hap-bytes', 'utf8');
          return variant.report({ hapPath, repoRoot: fakeRepoRoot });
        },
        inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
        inspectHapNativeEntriesImpl: async () => {
          archiveCalled = true;
          throw new Error('archive should not run for malformed buildHap report');
        }
      });

      assert.equal(archiveCalled, false, `${variant.label} should not archive-inspect`);
      assert.equal(discoverDeviceCalled, false, `${variant.label} should not discover device`);
      assert.equal(manifest.builds.hap.result, 'fail');
      assert.ok(manifest.builds.hap.command === null || Array.isArray(manifest.builds.hap.command), `${variant.label} should keep build step command strict-valid`);
      assert.ok(manifest.builds.hap.exitCode === null || Number.isInteger(manifest.builds.hap.exitCode), `${variant.label} should keep build step exitCode strict-valid`);
      assert.notEqual(manifest.signing.result, 'pass', `${variant.label} signing must not default to pass`);
      assert.equal(manifest.artifacts.hap, null);
      assert.deepEqual(manifest.archive, {
        entryCount: null,
        occurrences: {
          core: null,
          addon: null
        }
      });
      assert.equal(manifest.device.result, 'not-run');
      assert.ok(manifest.failures.some((entry) => entry.code === 'PACKAGE_HAP_REPORT_INVALID' && entry.stage === 'package-hap'), `${variant.label} should record PACKAGE_HAP_REPORT_INVALID`);
      assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'));
      const validation = validatePhase1NativeManifest(manifest);
      assert.equal(validation.valid, true, `${variant.label}: ${validation.errors.join('\n')}`);

      const liveVerification = await verifyPhase1NativeManifest(manifest, {
        repoRoot: fakeRepoRoot,
        hashFileImpl: async (targetPath) => {
          if (targetPath.endsWith('toolchain.lock.json')) {
            return {
              sha256: manifest.toolchainLock.sha256,
              sizeBytes: Buffer.byteLength(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
            };
          }
          if (targetPath.endsWith('harmony/artifacts/libcmfa_mihomo.so') || targetPath.endsWith('/libcmfa_mihomo.so')) {
            return {
              sha256: manifest.artifacts.rawCore.sha256,
              sizeBytes: manifest.artifacts.rawCore.sizeBytes
            };
          }
          if (targetPath.endsWith('/libentry.so')) {
            return {
              sha256: manifest.artifacts.prePackageAddon.sha256,
              sizeBytes: manifest.artifacts.prePackageAddon.sizeBytes
            };
          }
          return {
            sha256: manifest.artifacts.prePackageCore.sha256,
            sizeBytes: manifest.artifacts.prePackageCore.sizeBytes
          };
        },
        inspectHapNativeEntriesImpl: async () => {
          liveVerifyArchiveCalled = true;
          throw new Error('live verify archive should not run for malformed buildHap report');
        },
        inspectNativeLibraryImpl: async ({ component }) => createElfReport(component)
      });

      assert.equal(liveVerifyArchiveCalled, false, `${variant.label} live verify should not inspect HAP`);
      assert.equal(liveVerification.valid, true, `${variant.label}: ${liveVerification.errors.join('\n')}`);
    });
  }
});

test('buildPhase1Native rejects malformed archive reports before copying values into the manifest and keeps fail manifests strict-valid', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest, verifyPhase1NativeManifest } = await import(provenanceModulePath);

  for (const variant of [
    {
      label: 'entrycount-string',
      archive: {
        entryCount: '2',
        occurrences: { core: 1, addon: 1 },
        artifacts: {},
        failures: []
      }
    },
    {
      label: 'occurrences-wrong-type',
      archive: {
        entryCount: 2,
        occurrences: { core: '1', addon: 1 },
        artifacts: {},
        failures: []
      }
    },
    {
      label: 'artifact-malformed',
      archive: {
        entryCount: 2,
        occurrences: { core: 1, addon: 1 },
        artifacts: {
          core: {
            identity: 'libs/arm64-v8a/libcmfa_mihomo.so',
            sha256: 'bad',
            sizeBytes: '10',
            elf: { result: 'pass' }
          }
        },
        failures: []
      }
    },
    {
      label: 'occurrence-without-artifact',
      archive: {
        entryCount: 2,
        occurrences: { core: 1, addon: 1 },
        artifacts: {
          core: {
            identity: 'libs/arm64-v8a/libcmfa_mihomo.so',
            sha256: sha256('core-bytes'),
            sizeBytes: Buffer.byteLength('core-bytes'),
            elf: createElfReport('mihomoCore')
          }
        },
        failures: []
      }
    },
    {
      label: 'artifact-with-zero-occurrence',
      archive: {
        entryCount: 2,
        occurrences: { core: 0, addon: 1 },
        artifacts: {
          core: {
            identity: 'libs/arm64-v8a/libcmfa_mihomo.so',
            sha256: sha256('core-bytes'),
            sizeBytes: Buffer.byteLength('core-bytes'),
            elf: createElfReport('mihomoCore')
          },
          addon: {
            identity: 'libs/arm64-v8a/libentry.so',
            sha256: sha256('addon-bytes'),
            sizeBytes: Buffer.byteLength('addon-bytes'),
            elf: createElfReport('nodeAddon')
          }
        },
        failures: []
      }
    },
    {
      label: 'entrycount-below-occurrence-sum',
      archive: {
        entryCount: 1,
        occurrences: { core: 1, addon: 1 },
        artifacts: {
          core: {
            identity: 'libs/arm64-v8a/libcmfa_mihomo.so',
            sha256: sha256('core-bytes'),
            sizeBytes: Buffer.byteLength('core-bytes'),
            elf: createElfReport('mihomoCore')
          },
          addon: {
            identity: 'libs/arm64-v8a/libentry.so',
            sha256: sha256('addon-bytes'),
            sizeBytes: Buffer.byteLength('addon-bytes'),
            elf: createElfReport('nodeAddon')
          }
        },
        failures: []
      }
    }
  ]) {
    await withTempDir(`phase1-native-badarchive-${variant.label}-`, async (tempRoot) => {
      const fakeRepoRoot = path.join(tempRoot, 'repo');
      const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
      const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
      const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
      const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
      const hapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
      const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
      const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
      const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
      const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
      let discoverDeviceCalled = false;
      let liveVerifyArchiveCalled = false;

      await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
      await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
      await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
      await fs.mkdir(path.dirname(hdcPath), { recursive: true });
      await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
      await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
      await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
      await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

      const manifest = await buildPhase1Native({
        harmonyRoot: fakeHarmonyRoot,
        repoRoot: fakeRepoRoot,
        outputPath,
        inspectToolchainImpl: async () => ({
          report: {
            schemaVersion: '1.0.0',
            result: 'pass',
            target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
            installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
            tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
            failures: []
          },
          resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
        }),
        inspectTaskTreeImpl: async () => ({
          rootTask: ':entry:compileNative',
          hasBuildNativeWithCmake: true,
          hasPackageHap: false,
          exitCode: 0,
          stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
          stderr: ''
        }),
        buildMihomoOhosImpl: async () => {
          await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
          await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
          return {
            result: 'pass',
            components: {
              mihomoCore: { result: 'pass', artifactPath: rawCorePath }
            },
            failures: []
          };
        },
        runCommandImpl: async ({ command, args }) => {
          if (args.includes('compileNative')) {
            return { command, args, exitCode: 0, stdout: '', stderr: '' };
          }
          if (args.includes('--build')) {
            await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
            await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
            return { command, args, exitCode: 0, stdout: '', stderr: '' };
          }
          if (args.join(' ') === 'list targets') {
            discoverDeviceCalled = true;
            return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
          }
          throw new Error(`unexpected command: ${args.join(' ')}`);
        },
        buildHapImpl: async () => {
          await fs.mkdir(path.dirname(hapPath), { recursive: true });
          await fs.writeFile(hapPath, 'hap-bytes', 'utf8');
          return {
            result: 'incomplete',
            hap: {
              path: path.relative(fakeRepoRoot, hapPath).split(path.sep).join('/'),
              sha256: sha256('hap-bytes'),
              sizeBytes: Buffer.byteLength('hap-bytes')
            },
            failures: [{ code: 'SIGNING_REQUIRED', detail: 'unsigned', stage: 'signing' }],
            commands: [
              {
                stage: 'module',
                command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
                exitCode: 0,
                stdout: '',
                stderr: ''
              }
            ]
          };
        },
        inspectNativeLibraryImpl: async ({ component }) => createElfReport(component),
        inspectHapNativeEntriesImpl: async () => variant.archive
      });

      assert.equal(discoverDeviceCalled, false, `${variant.label} should not discover device`);
      assert.notEqual(manifest.artifacts.hap, null, `${variant.label} should keep HAP digest evidence`);
      assert.deepEqual(manifest.archive, {
        entryCount: null,
        occurrences: {
          core: null,
          addon: null
        }
      });
      assert.equal(manifest.artifacts.hapCore, null);
      assert.equal(manifest.artifacts.hapAddon, null);
      assert.ok(manifest.failures.some((entry) => entry.code === 'HAP_ARCHIVE_REPORT_INVALID' && entry.stage === 'archive'), `${variant.label} should record HAP_ARCHIVE_REPORT_INVALID`);
      assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'));
      const validation = validatePhase1NativeManifest(manifest);
      assert.equal(validation.valid, true, `${variant.label}: ${validation.errors.join('\n')}`);

      const liveVerification = await verifyPhase1NativeManifest(manifest, {
        repoRoot: fakeRepoRoot,
        hashFileImpl: async (targetPath) => {
          if (targetPath.endsWith('toolchain.lock.json')) {
            return {
              sha256: manifest.toolchainLock.sha256,
              sizeBytes: Buffer.byteLength(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
            };
          }
          if (targetPath.endsWith('entry-default-unsigned.hap')) {
            return {
              sha256: manifest.artifacts.hap.sha256,
              sizeBytes: manifest.artifacts.hap.sizeBytes
            };
          }
          if (targetPath.endsWith('harmony/artifacts/libcmfa_mihomo.so') || targetPath.endsWith('/libcmfa_mihomo.so')) {
            return {
              sha256: manifest.artifacts.rawCore.sha256,
              sizeBytes: manifest.artifacts.rawCore.sizeBytes
            };
          }
          if (targetPath.endsWith('/libentry.so')) {
            return {
              sha256: manifest.artifacts.prePackageAddon.sha256,
              sizeBytes: manifest.artifacts.prePackageAddon.sizeBytes
            };
          }
          return {
            sha256: manifest.artifacts.prePackageCore.sha256,
            sizeBytes: manifest.artifacts.prePackageCore.sizeBytes
          };
        },
        inspectHapNativeEntriesImpl: async () => {
          liveVerifyArchiveCalled = true;
          throw new Error('live verify archive should not run for malformed archive producer manifests');
        },
        inspectNativeLibraryImpl: async ({ component }) => createElfReport(component)
      });

      assert.equal(liveVerifyArchiveCalled, false, `${variant.label} live verify should not inspect malformed archive evidence`);
      assert.equal(liveVerification.valid, true, `${variant.label}: ${liveVerification.errors.join('\n')}`);
    });
  }
});

test('buildPhase1Native normalizes full ELF reports before validation and persistence', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);
  const { HAP_NATIVE_ENTRIES: entries } = await import(buildModulePath);

  await withTempDir('phase1-native-elf-normalization-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const artifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
    const rawCorePath = path.join(artifactsRoot, 'libcmfa_mihomo.so');
    const preAddonPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a', 'libentry.so');
    const hapPath = path.join(fakeHarmonyRoot, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
    const outputPath = path.join(artifactsRoot, 'phase1-native-provenance.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');

    await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
    await fs.mkdir(path.dirname(hapPath), { recursive: true });
    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => {
        await fs.mkdir(path.dirname(rawCorePath), { recursive: true });
        await fs.writeFile(rawCorePath, 'core-bytes', 'utf8');
        return {
          result: 'pass',
          components: {
            mihomoCore: { result: 'pass', artifactPath: rawCorePath }
          },
          failures: []
        };
      },
      runCommandImpl: async ({ command, args }) => {
        const joined = [command, ...args].join(' ');
        if (joined.includes('compileNative')) {
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (joined.includes('--build')) {
          await fs.mkdir(path.dirname(preAddonPath), { recursive: true });
          await fs.writeFile(preAddonPath, 'addon-bytes', 'utf8');
          return { command, args, exitCode: 0, stdout: '', stderr: '' };
        }
        if (joined.includes('list targets')) {
          return { command, args, exitCode: 0, stdout: 'SERIAL123\n', stderr: '' };
        }
        throw new Error(`unexpected command: ${joined}`);
      },
      buildHapImpl: async () => {
        await fs.mkdir(path.dirname(hapPath), { recursive: true });
        await fs.writeFile(hapPath, 'hap-bytes', 'utf8');
        return {
          result: 'incomplete',
          hap: {
            path: path.relative(fakeRepoRoot, hapPath).split(path.sep).join('/'),
            sha256: sha256('hap-bytes'),
            sizeBytes: Buffer.byteLength('hap-bytes')
          },
          failures: [{ code: 'SIGNING_REQUIRED', detail: 'unsigned', stage: 'signing' }],
          commands: [
            {
              stage: 'module',
              command: ['harmony/hvigorw', '--mode', 'module', 'assembleHap'],
              exitCode: 0,
              stdout: '',
              stderr: ''
            }
          ]
        };
      },
      inspectNativeLibraryImpl: async ({ component, libPath }) => ({
        schemaVersion: '1.0.0',
        inspectedAt: isoAt(0),
        libPath,
        readelfPath: '/sdk/llvm-readelf',
        ...createElfReport(component)
      }),
      inspectHapNativeEntriesImpl: async (input, options = {}) => {
        options.onEvent?.('list-hap');
        options.onEvent?.('extract-hap-core');
        options.onEvent?.('extract-hap-addon');
        options.onEvent?.('inspect-hap-core');
        options.onEvent?.('inspect-hap-addon');
        return {
          entryCount: 2,
          occurrences: { core: 1, addon: 1 },
          artifacts: {
            core: {
              identity: entries.core,
              sha256: sha256('core-bytes'),
              sizeBytes: Buffer.byteLength('core-bytes'),
              elf: {
                schemaVersion: '1.0.0',
                inspectedAt: isoAt(0),
                libPath: '/tmp/core.so',
                readelfPath: '/sdk/llvm-readelf',
                ...createElfReport('mihomoCore')
              }
            },
            addon: {
              identity: entries.addon,
              sha256: sha256('addon-bytes'),
              sizeBytes: Buffer.byteLength('addon-bytes'),
              elf: {
                schemaVersion: '1.0.0',
                inspectedAt: isoAt(0),
                libPath: '/tmp/addon.so',
                readelfPath: '/sdk/llvm-readelf',
                ...createElfReport('nodeAddon')
              }
            }
          },
          failures: []
        };
      }
    });

    const persisted = JSON.parse(await fs.readFile(outputPath, 'utf8'));
    for (const slot of ['rawCore', 'prePackageCore', 'prePackageAddon', 'hapCore', 'hapAddon']) {
      assert.notEqual(manifest.artifacts[slot], null, `${slot} should be present`);
      assert.deepEqual(Object.keys(manifest.artifacts[slot].elf).sort(), [
        'allowedNeededLibraries',
        'architecture',
        'component',
        'exportedSymbols',
        'failures',
        'neededLibraries',
        'requiredExports',
        'result'
      ]);
      assert.deepEqual(Object.keys(persisted.artifacts[slot].elf).sort(), [
        'allowedNeededLibraries',
        'architecture',
        'component',
        'exportedSymbols',
        'failures',
        'neededLibraries',
        'requiredExports',
        'result'
      ]);
    }
    assert.equal(validatePhase1NativeManifest(persisted).valid, true);
  });
});

test('normalizeElfReport preserves the actual component and falls back only when the inspector omitted it', async () => {
  const { normalizeElfReport } = await import(provenanceModulePath);

  const mismatchedActual = normalizeElfReport({
    ...createElfReport('mihomoCore'),
    component: 'nodeAddon'
  }, 'mihomoCore');
  assert.equal(mismatchedActual.component, 'nodeAddon');

  const missingActual = normalizeElfReport({
    ...createElfReport('mihomoCore'),
    component: undefined
  }, 'mihomoCore');
  assert.equal(missingActual.component, 'mihomoCore');
});

test('normalizeElfReport exposes core build provenance only for explicit live inspection', async () => {
  const { normalizeElfReport } = await import(provenanceModulePath);
  const buildInfo = {
    version: 'v1.19.29',
    upstreamCommit: '0123456789abcdef0123456789abcdef01234567',
    abiVersion: 'cmfa-harmony-v1',
    buildId: '0123456789abcdef'
  };
  const inspected = {
    ...createElfReport('mihomoCore'),
    rawVersion: buildInfo.version,
    buildInfo
  };

  const persistedManifestReport = normalizeElfReport(inspected, 'mihomoCore');
  assert.equal('rawVersion' in persistedManifestReport, false);
  assert.equal('buildInfo' in persistedManifestReport, false);

  const liveInspectionReport = normalizeElfReport(inspected, 'mihomoCore', {
    includeBuildInfo: true
  });
  assert.equal(liveInspectionReport.rawVersion, buildInfo.version);
  assert.deepEqual(liveInspectionReport.buildInfo, buildInfo);
});

test('strict validator rejects forged native pass manifests with missing artifacts, wrong identities, and blocker inconsistency', async () => {
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  const forgedPass = validatePhase1NativeManifest(createEarlyFailureManifest({
    result: 'pass',
    nativeBuildResult: 'pass',
    toolchainLock: {
      path: 'harmony/toolchain.lock.json',
      sha256: sha256(JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE))
    },
    builds: {
      core: createBuildStep('pass', ['node', 'x'], 0),
      addonConfigure: createBuildStep('pass', ['hvigorw'], 0),
      addon: createBuildStep('pass', ['cmake'], 0),
      hap: createBuildStep('pass', ['hvigorw'], 0)
    },
    archive: {
      entryCount: 0,
      occurrences: {
        core: 0,
        addon: 0
      }
    },
    signing: {
      result: 'pass'
    },
    device: {
      result: 'pass',
      targetCount: 1,
      identityMasked: 'target-zzzzzzzz',
      proofResult: 'not-run'
    },
    failures: []
  }));
  assert.equal(forgedPass.valid, false);
  assert.match(forgedPass.errors.join('\n'), /artifacts|archive|identityMasked/u);

  const wrongIdentity = validatePhase1NativeManifest(createStrictManifest({
    artifacts: {
      ...createStrictManifest().artifacts,
      rawCore: createArtifact('harmony/other/libcmfa_mihomo.so', 'core-bytes', createElfReport('mihomoCore')),
      prePackageCore: createArtifact('harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/other.so', 'core-bytes', createElfReport('mihomoCore')),
      prePackageAddon: createArtifact('harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry-copy.so', 'addon-bytes', createElfReport('nodeAddon')),
      hap: createArtifact('harmony/entry/build/default/outputs/release/entry.hap', 'hap-bytes', null)
    },
    signing: {
      result: 'incomplete'
    },
    device: {
      result: 'incomplete',
      targetCount: 2,
      identityMasked: 'target-deadbeef',
      proofResult: 'not-run'
    },
    failures: [
      { code: 'DEVICE_TARGET_MISSING', detail: 'wrong blocker', stage: 'device' }
    ]
  }));
  assert.equal(wrongIdentity.valid, false);
  assert.match(wrongIdentity.errors.join('\n'), /identity|SIGNING_REQUIRED|DEVICE_TARGET_AMBIGUOUS|identityMasked/u);
});

test('buildPhase1Native records TOOLCHAIN_LOCK_FAILED and still persists a strictly valid early-fail manifest', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  await withTempDir('phase1-native-lock-fail-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const outputPath = path.join(fakeHarmonyRoot, 'artifacts', 'phase1-native-provenance.json');

    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      })
    });

    assert.equal(manifest.nativeBuildResult, 'fail');
    assert.equal(manifest.result, 'fail');
    assert.equal(manifest.toolchainLock.sha256, null);
    assert.deepEqual(manifest.builds, {
      core: createBuildStep(),
      addonConfigure: createBuildStep(),
      addon: createBuildStep(),
      hap: createBuildStep()
    });
    assert.ok(manifest.failures.some((entry) => entry.code === 'TOOLCHAIN_LOCK_FAILED' && entry.stage === 'toolchain-lock'));
    assert.ok(!manifest.failures.some((entry) => entry.code === 'PHASE1_MANIFEST_INVALID'));

    const persisted = JSON.parse(await fs.readFile(outputPath, 'utf8'));
    assert.equal(validatePhase1NativeManifest(persisted).valid, true);
  });
});

test('buildPhase1Native adds a matching build-core failure when early core failure stages are foreign and persists a valid fail manifest', async () => {
  const { buildPhase1Native } = await import(buildModulePath);
  const { validatePhase1NativeManifest } = await import(provenanceModulePath);

  await withTempDir('phase1-native-core-fail-', async (tempRoot) => {
    const fakeRepoRoot = path.join(tempRoot, 'repo');
    const fakeHarmonyRoot = path.join(fakeRepoRoot, 'harmony');
    const toolchainLockPath = path.join(fakeHarmonyRoot, 'toolchain.lock.json');
    const cmakeExecutable = path.join(fakeHarmonyRoot, 'sdk', 'native', 'build-tools', 'cmake', 'bin', 'cmake');
    const hdcPath = path.join(fakeHarmonyRoot, 'sdk', 'toolchains', 'hdc');
    const outputPath = path.join(fakeHarmonyRoot, 'artifacts', 'phase1-native-provenance.json');

    await fs.mkdir(path.dirname(toolchainLockPath), { recursive: true });
    await fs.mkdir(path.dirname(cmakeExecutable), { recursive: true });
    await fs.mkdir(path.dirname(hdcPath), { recursive: true });
    await fs.writeFile(toolchainLockPath, `${JSON.stringify(TOOLCHAIN_LOCK_TEMPLATE, null, 2)}\n`, 'utf8');
    await fs.writeFile(path.join(fakeHarmonyRoot, 'hvigorw'), '#!/bin/sh\n', 'utf8');
    await fs.writeFile(cmakeExecutable, '#!/bin/sh\n', 'utf8');
    await fs.writeFile(hdcPath, '#!/bin/sh\n', 'utf8');

    const manifest = await buildPhase1Native({
      harmonyRoot: fakeHarmonyRoot,
      repoRoot: fakeRepoRoot,
      outputPath,
      inspectToolchainImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20, runtimeOS: 'HarmonyOS', name: 'HarmonyOS 6/API 20/arm64' },
          installed: TOOLCHAIN_LOCK_TEMPLATE.installed,
          tools: { nativeCmake: { found: true, version: null }, hdc: { found: true, version: '6.1.0.105' } },
          failures: []
        },
        resolved: { paths: { cmakeExecutable, hdc: hdcPath } }
      }),
      inspectTaskTreeImpl: async () => ({
        rootTask: ':entry:compileNative',
        hasBuildNativeWithCmake: true,
        hasPackageHap: false,
        exitCode: 0,
        stdout: ':entry:compileNative\n  +--- :default@BuildNativeWithCmake\n',
        stderr: ''
      }),
      buildMihomoOhosImpl: async () => ({
        result: 'fail',
        components: {
          mihomoCore: { result: 'fail', artifactPath: null }
        },
        failures: [
          { code: 'GO_BUILD_FAILED', detail: 'core exploded', stage: 'go-build-step' }
        ]
      })
    });

    assert.ok(manifest.failures.some((entry) => entry.stage === 'build-core'));
    const persisted = JSON.parse(await fs.readFile(outputPath, 'utf8'));
    assert.equal(validatePhase1NativeManifest(persisted).valid, true);
  });
});
