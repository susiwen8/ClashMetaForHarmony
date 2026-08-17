import assert from 'node:assert/strict';
import { execFile as execFileCallback } from 'node:child_process';
import crypto from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import test from 'node:test';
import { promisify } from 'node:util';

const modulePath = new URL('../bin/inspect-phase4-packages.mjs', import.meta.url);
const execFile = promisify(execFileCallback);
const HARMONY_ROOT = path.resolve(new URL('../..', import.meta.url).pathname);

function digest(seed) {
  return crypto.createHash('sha256').update(seed).digest('hex');
}

function createHappyInspectorDependencies() {
  const isProbe = (hapPath) => hapPath.includes('traffic-probe');
  return {
    loadProductionManifestImpl: async () => ({
      artifacts: {
        hap: { identity: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap' }
      },
      signing: { result: 'pass' },
      nativeBuildResult: 'pass'
    }),
    listArchiveEntriesImpl: async (hapPath) => {
      if (!isProbe(hapPath)) {
        return ['module.json', 'pack.info', 'libs/arm64-v8a/libentry.so', 'libs/arm64-v8a/libcmfa_mihomo.so', 'META-INF/CERT.SF'];
      }
      return ['module.json', 'pack.info', 'pages/ProbePage.abc', 'META-INF/CERT.SF'];
    },
    hashFileImpl: async (hapPath) => ({
      sha256: digest(hapPath),
      sizeBytes: 1024
    }),
    readModuleJsonImpl: async (hapPath) => ({
      bundleName: !isProbe(hapPath)
        ? 'com.github.kr328.clash.harmony'
        : 'com.github.kr328.clash.harmony.trafficprobe',
      requestPermissions: !isProbe(hapPath)
        ? ['ohos.permission.INTERNET', 'ohos.permission.KEEP_BACKGROUND_RUNNING']
        : ['ohos.permission.INTERNET']
    }),
    readSignatureImpl: async (hapPath) => ({
      signatureSha256: digest(`${hapPath}:signature`)
    }),
    verifySignatureImpl: async (options) => ({
      signatureSha256: digest(`${options.hapPath}:verified-signature`)
    }),
    inspectNativeImpl: async ({ hapPath }) => !isProbe(hapPath)
      ? {
        addon: { exportedSymbols: ['JNI_OnLoad'] },
        core: { exportedSymbols: ['cmfa_mihomo_start_local_v1', 'cmfa_mihomo_runtime_state_v1', 'cmfa_mihomo_take_runtime_log_v1'] }
      }
      : null
  };
}

test('phase4 package inspector requires exact production/probe bundle separation and native payload boundaries', async () => {
  const inspector = await import(modulePath);
  const result = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...createHappyInspectorDependencies()
  });

  assert.equal(result.result, 'pass');
  assert.equal(result.production.bundleName, 'com.github.kr328.clash.harmony');
  assert.equal(result.probe.bundleName, 'com.github.kr328.clash.harmony.trafficprobe');
  assert.notEqual(result.production.hapSha256, result.probe.hapSha256);
  assert.notEqual(result.production.signatureSha256, result.probe.signatureSha256);
  assert.deepEqual(result.production.permissions, ['ohos.permission.INTERNET', 'ohos.permission.KEEP_BACKGROUND_RUNNING']);
  assert.deepEqual(result.probe.permissions, ['ohos.permission.INTERNET']);
  assert.equal(result.production.stubDetected, false);
  assert.equal(result.probe.hasNativePayload, false);
  assert.equal(result.probeEmbeddedInProduction, false);
  assert.equal(result.failures.length, 0);
});

test('phase4 package inspector fail-closes for unsigned HAP names, missing signatures, and cross-bundle contamination', async () => {
  const inspector = await import(modulePath);
  const noSignature = createHappyInspectorDependencies();
  noSignature.loadProductionManifestImpl = async () => ({
    artifacts: {
      hap: { identity: 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap' }
    },
    signing: { result: 'pass' },
    nativeBuildResult: 'pass'
  });
  noSignature.readSignatureImpl = async () => null;
  const unsigned = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...noSignature
  });
  assert.equal(unsigned.result, 'fail');
  assert.match(unsigned.failures.map((entry) => entry.code).join(','), /UNSIGNED|SIGNATURE/u);

  const contaminated = createHappyInspectorDependencies();
  contaminated.listArchiveEntriesImpl = async () => ['module.json', 'libs/arm64-v8a/libentry.so', 'META-INF/CERT.SF'];
  contaminated.inspectNativeImpl = async () => ({
    addon: { exportedSymbols: ['JNI_OnLoad'] },
    core: { exportedSymbols: ['cmfa_mihomo_start_local_v1'] }
  });
  const fail = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...contaminated
  });
  assert.equal(fail.result, 'fail');
  assert.match(fail.failures.map((entry) => entry.code).join(','), /PROBE_NATIVE_PAYLOAD_FORBIDDEN|PRODUCTION_CORE_MISSING/u);
});

test('phase4 package inspector CLI writes atomic pass/fail JSON reports', async () => {
  const inspector = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase4-package-'));
  const outputPath = path.join(tempRoot, 'phase4-package-inspection.json');
  const report = await inspector.writeInspectionReport({
    outputPath,
    report: {
      schemaVersion: '1.0.0',
      result: 'fail',
      production: { bundleName: 'com.github.kr328.clash.harmony', hapSha256: digest('p'), signatureSha256: digest('ps'), permissions: ['ohos.permission.INTERNET'], stubDetected: false },
      probe: { bundleName: 'com.github.kr328.clash.harmony.trafficprobe', hapSha256: digest('q'), signatureSha256: digest('qs'), permissions: ['ohos.permission.INTERNET'], hasNativePayload: false },
      probeEmbeddedInProduction: false,
      failures: [{ code: 'SIGNATURE_MISSING', detail: 'Missing signature block.' }]
    }
  });
  assert.equal(report.result, 'fail');
  assert.deepEqual(JSON.parse(await fs.readFile(outputPath, 'utf8')), report);
});

test('phase4 package inspector real default readers parse module/signature/hash with repo-scoped zip inputs', async () => {
  const inspector = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-package-real-'));
  const hapRoot = path.join(tempRoot, 'production-hap');
  const manifestPath = path.join(tempRoot, 'phase1-native-provenance.json');
  const hapPath = path.join(tempRoot, 'entry-default-signed.hap');
  const probeHapRoot = path.join(tempRoot, 'probe-hap');
  const probeHapPath = path.join(tempRoot, 'probe-default-signed.hap');
  await fs.mkdir(path.join(hapRoot, 'META-INF'), { recursive: true });
  await fs.mkdir(path.join(probeHapRoot, 'META-INF'), { recursive: true });
  await fs.writeFile(path.join(hapRoot, 'module.json'), JSON.stringify({
    bundleName: 'com.github.kr328.clash.harmony',
    requestPermissions: [{ name: 'ohos.permission.INTERNET' }, { name: 'ohos.permission.KEEP_BACKGROUND_RUNNING' }]
  }), 'utf8');
  await fs.writeFile(path.join(hapRoot, 'META-INF', 'CERT.SF'), 'signature-a', 'utf8');
  await fs.writeFile(path.join(probeHapRoot, 'module.json'), JSON.stringify({
    bundleName: 'com.github.kr328.clash.harmony.trafficprobe',
    requestPermissions: [{ name: 'ohos.permission.INTERNET' }]
  }), 'utf8');
  await fs.writeFile(path.join(probeHapRoot, 'META-INF', 'CERT.SF'), 'signature-b', 'utf8');
  await fs.writeFile(manifestPath, JSON.stringify({
    artifacts: {
      hap: {
        identity: path.relative(path.resolve(HARMONY_ROOT, '..'), hapPath).split(path.sep).join('/'),
        sha256: digest('manifest-hap')
      }
    },
    signing: { result: 'pass' },
    nativeBuildResult: 'pass',
    phase2SelfTest: { enabled: false, purpose: 'production', releaseStatus: 'releasable' }
  }), 'utf8');
  await execFile('/usr/bin/zip', ['-qr', hapPath, '.'], { cwd: hapRoot });
  await execFile('/usr/bin/zip', ['-qr', probeHapPath, '.'], { cwd: probeHapRoot });

  const result = await inspector.inspectPhase4Packages({
    productionHapPath: hapPath,
    productionManifestPath: manifestPath,
    probeHapPath,
    inspectNativeImpl: async () => ({
      addon: { exportedSymbols: ['JNI_OnLoad'] },
      core: { exportedSymbols: ['cmfa_mihomo_start_local_v1', 'cmfa_mihomo_runtime_state_v1'] }
    })
  });
  assert.equal(result.production.bundleName, 'com.github.kr328.clash.harmony');
  assert.equal(result.probe.bundleName, 'com.github.kr328.clash.harmony.trafficprobe');
  assert.match(result.production.hapSha256, /^[a-f0-9]{64}$/u);
  assert.match(result.production.signatureSha256, /^[a-f0-9]{64}$/u);
});

test('phase4 package inspector real defaults fail closed for repo escape, missing manifest, and missing signatures', async () => {
  const inspector = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-package-fail-'));
  const hapRoot = path.join(tempRoot, 'unsigned-hap');
  const hapPath = path.join(tempRoot, 'entry-default-signed.hap');
  await fs.mkdir(hapRoot, { recursive: true });
  await fs.writeFile(path.join(hapRoot, 'module.json'), JSON.stringify({
    bundleName: 'com.github.kr328.clash.harmony',
    requestPermissions: [{ name: 'ohos.permission.INTERNET' }, { name: 'ohos.permission.KEEP_BACKGROUND_RUNNING' }]
  }), 'utf8');
  await execFile('/usr/bin/zip', ['-qr', hapPath, '.'], { cwd: hapRoot });

  await assert.rejects(
    inspector.inspectPhase4Packages({
      productionHapPath: '/tmp/outside.hap',
      productionManifestPath: path.join(tempRoot, 'missing.json'),
      probeHapPath: hapPath
    }),
    /repository|PATH_OUTSIDE_REPO|MANIFEST/u
  );

  const manifestPath = path.join(tempRoot, 'phase1-native-provenance.json');
  await fs.writeFile(manifestPath, JSON.stringify({
    artifacts: {
      hap: { identity: path.relative(path.resolve(HARMONY_ROOT, '..'), hapPath).split(path.sep).join('/') }
    },
    signing: { result: 'pass' },
    nativeBuildResult: 'pass',
    phase2SelfTest: { enabled: false, purpose: 'production', releaseStatus: 'releasable' }
  }), 'utf8');
  const result = await inspector.inspectPhase4Packages({
    productionHapPath: hapPath,
    productionManifestPath: manifestPath,
    probeHapPath: hapPath,
    inspectNativeImpl: async () => ({
      addon: { exportedSymbols: ['JNI_OnLoad'] },
      core: { exportedSymbols: ['cmfa_mihomo_start_local_v1', 'cmfa_mihomo_runtime_state_v1'] }
    })
  });
  assert.equal(result.result, 'fail');
  assert.match(result.failures.map((entry) => entry.code).join(','), /SIGNATURE_MISSING|SHARED_BUNDLE_IDENTITY|PROBE_BUNDLE_INVALID/u);
});

test('phase4 package inspector real signature verifier builds trusted java argv and cleans temp outputs', async () => {
  const inspector = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-signature-verify-'));
  const hapPath = path.join(tempRoot, 'entry-default-signed.hap');
  await fs.writeFile(hapPath, 'hap-bytes', 'utf8');
  const tempArtifacts = [];
  const result = await inspector.defaultVerifySignature({
    hapPath,
    tempRoot,
    execFileImpl: async (command, args) => {
      assert.equal(command, '/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java');
      assert.equal(args.includes('-jar'), true);
      assert.equal(args.includes('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar'), true);
      assert.equal(args.includes('verify-app'), true);
      const outCertIndex = args.indexOf('-outCertChain');
      const outProfileIndex = args.indexOf('-outProfile');
      await fs.writeFile(args[outCertIndex + 1], 'cert-chain', 'utf8');
      await fs.writeFile(args[outProfileIndex + 1], 'profile', 'utf8');
      tempArtifacts.push(args[outCertIndex + 1], args[outProfileIndex + 1]);
      return { stdout: '', stderr: '' };
    }
  });
  assert.match(result.signatureSha256, /^[a-f0-9]{64}$/u);
  for (const artifactPath of tempArtifacts) {
    await assert.rejects(fs.access(artifactPath));
  }
});

test('phase4 package inspector verifier nonzero or empty outputs fail closed', async () => {
  const inspector = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-signature-verify-fail-'));
  const hapPath = path.join(tempRoot, 'entry-default-signed.hap');
  await fs.writeFile(hapPath, 'hap-bytes', 'utf8');

  const failed = await inspector.defaultVerifySignature({
    hapPath,
    tempRoot,
    execFileImpl: async () => {
      throw new Error('verify failed');
    }
  });
  assert.equal(failed, null);

  const empty = await inspector.defaultVerifySignature({
    hapPath,
    tempRoot,
    execFileImpl: async (_command, args) => {
      const outCertIndex = args.indexOf('-outCertChain');
      const outProfileIndex = args.indexOf('-outProfile');
      await fs.writeFile(args[outCertIndex + 1], '', 'utf8');
      await fs.writeFile(args[outProfileIndex + 1], '', 'utf8');
      return { stdout: '', stderr: '' };
    }
  });
  assert.equal(empty, null);
});
