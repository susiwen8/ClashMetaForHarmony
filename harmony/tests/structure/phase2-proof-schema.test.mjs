import assert from 'node:assert/strict';
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
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase2-device-proof.schema.json');
const EXAMPLE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase2-device-proof.example.json');
const DEBUG_PAGE_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'pages', 'CoreDebugPage.ets');
const ENTRY_ABILITY_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'entryability', 'EntryAbility.ets');
const EXPECTED_RUN_ID = '980cbe02-b817-4db1-99bc-e8e4e6523daf';

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

test('Phase 2 runner always writes a repo-contained incomplete proof when no signed physical-device input exists', async () => {
  assert.ok(runner, 'Phase 2 runner module must exist');
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase2-runner-'));
  const repoRoot = path.join(tempRoot, 'repo');
  const harmonyRoot = path.join(repoRoot, 'harmony');
  const outputPath = path.join(harmonyRoot, 'artifacts', 'phase2-device-proof.json');

  await fs.mkdir(path.join(harmonyRoot, 'artifacts'), { recursive: true });
  await fs.writeFile(path.join(harmonyRoot, 'toolchain.lock.json'), JSON.stringify({
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hvigorVersion: '6.23.7',
      hdcVersion: '6.1.0.105'
    }
  }), 'utf8');

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
  assert.ok(proof.failures.some((entry) => entry.code === 'INPUT_HAP_MISSING'));
  assert.ok(proof.failures.some((entry) => entry.code === 'PHYSICAL_DEVICE_REQUIRED'));
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
});

test('inspect-native-lib and CoreDebugPage enforce real-core-only Phase 2 evidence lanes', async () => {
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

  for (const signal of [
    'phase2-device-proof.json',
    'appProcessId',
    'coreConnectionId',
    'clientSourcePort',
    'originRequestId',
    'appProbeId',
    'coreEventId',
    'stopResult',
    'CMFA_ENABLE_PHASE2_SELFTEST'
  ]) {
    assert.match(`${debugPageSource}\n${entryAbilitySource}`, new RegExp(signal.replaceAll('.', '\\.'), 'u'));
  }
  assert.match(debugPageSource, /selfTestBuildEnabled/u);
  assert.match(debugPageSource, /result: 'incomplete'/u);
});
