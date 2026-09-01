import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const PROBE_ROOT = path.join(HARMONY_ROOT, 'traffic-probe');
const PROBE_BUNDLE_NAME = 'com.cmfa.phase4.trafficprobe';
const PRODUCTION_BUNDLE_NAME = 'com.github.kr328.clash.harmony';
const PROBE_EVIDENCE_FILE = 'phase4-probe-evidence.json';
const PROBE_FILES = [
  '.gitignore',
  'AppScope/app.json5',
  'build-profile.json5',
  'hvigorfile.ts',
  'hvigorw',
  'oh-package.json5',
  'oh-package-lock.json5',
  'entry/build-profile.json5',
  'entry/hvigorfile.ts',
  'entry/oh-package.json5',
  'entry/src/main/module.json5',
  'entry/src/main/resources/base/element/string.json',
  'entry/src/main/resources/base/profile/main_pages.json',
  'entry/src/main/ets/entryability/ProbeAbility.ets',
  'entry/src/main/ets/pages/ProbePage.ets',
  'entry/src/main/ets/probe/ProbeModels.ets',
  'entry/src/main/ets/probe/DirectTrafficProbe.ets',
  'entry/src/main/cpp/CMakeLists.txt',
  'entry/src/main/cpp/types/libprobeentry/oh-package.json5',
  'entry/src/main/cpp/types/libprobeentry/Index.d.ts',
  'entry/src/test/DirectTrafficProbe.test.ets',
  'entry/src/test/List.test.ets'
];
const PRODUCTION_FILES = [
  'AppScope/app.json5',
  'build-profile.json5',
  'hvigorfile.ts',
  'oh-package.json5',
  'entry/build-profile.json5',
  'entry/hvigorfile.ts',
  'entry/oh-package.json5',
  'entry/src/main/module.json5',
  'entry/src/main/resources/base/element/string.json',
  'entry/src/main/resources/base/profile/main_pages.json',
  'entry/src/main/cpp/CMakeLists.txt'
];

async function readUtf8(targetPath) {
  return await fs.readFile(targetPath, 'utf8');
}

async function assertPathExists(targetPath, label) {
  try {
    await fs.access(targetPath);
  } catch {
    assert.fail(`${label} must exist: ${targetPath}`);
  }
}

function assertIncludes(source, expected, label) {
  assert.equal(source.includes(expected), true, `${label} must contain ${expected}`);
}

function assertExcludes(source, banned, label) {
  assert.equal(source.includes(banned), false, `${label} must not contain ${banned}`);
}

function assertRegexExcludes(source, bannedPattern, label) {
  assert.equal(bannedPattern.test(source), false, `${label} must not match ${bannedPattern}`);
}

test('phase4 probe project is a standalone HarmonyOS 6 API 20 project with a dedicated bundle and wrapper boundary', async () => {
  await assertPathExists(PROBE_ROOT, 'traffic probe project root');

  const probeFiles = await Promise.all(
    PROBE_FILES.map(async (relativePath) => {
      const absolutePath = path.join(PROBE_ROOT, relativePath);
      await assertPathExists(absolutePath, `traffic probe file ${relativePath}`);
      return [relativePath, await readUtf8(absolutePath)];
    })
  );
  const probeSource = new Map(probeFiles);

  assertIncludes(probeSource.get('AppScope/app.json5'), PROBE_BUNDLE_NAME, 'probe app scope');
  assertRegexExcludes(
    probeSource.get('AppScope/app.json5'),
    /"bundleName"\s*:\s*"com\.github\.kr328\.clash\.harmony"/u,
    'probe app scope'
  );
  assert.equal(PROBE_BUNDLE_NAME.startsWith(PRODUCTION_BUNDLE_NAME), false, 'probe bundle must not equal or nest under production bundle');
  assert.equal(PROBE_BUNDLE_NAME.startsWith(`${PRODUCTION_BUNDLE_NAME}.`), false, 'probe bundle must not start with the production bundle prefix');

  const rootBuildProfile = probeSource.get('build-profile.json5');
  assertIncludes(rootBuildProfile, '"compatibleSdkVersion": "6.0.0(20)"', 'probe build profile');
  assertIncludes(rootBuildProfile, '"targetSdkVersion": "6.1.1(24)"', 'probe build profile');
  assertExcludes(rootBuildProfile, '../entry', 'probe build profile');
  assertExcludes(rootBuildProfile, '../shared', 'probe build profile');
  assertExcludes(rootBuildProfile, '../platform', 'probe build profile');
  assertExcludes(rootBuildProfile, '../core', 'probe build profile');
  assertIncludes(rootBuildProfile, '"srcPath": "./entry"', 'probe build profile');

  assertIncludes(probeSource.get('entry/src/main/module.json5'), '"name": "ohos.permission.INTERNET"', 'probe module');
  assertExcludes(probeSource.get('entry/src/main/module.json5'), 'KEEP_BACKGROUND_RUNNING', 'probe module');
  assertExcludes(probeSource.get('entry/src/main/module.json5'), 'extensionAbilities', 'probe module');
  assertExcludes(probeSource.get('entry/src/main/module.json5'), 'CmfaVpnExtensionAbility', 'probe module');

  const wrapperSource = probeSource.get('hvigorw');
  assertIncludes(wrapperSource, 'PROJECT_DIR', 'probe hvigor wrapper');
  assertIncludes(wrapperSource, 'traffic-probe', 'probe hvigor wrapper');
  assertExcludes(wrapperSource, 'PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"', 'probe hvigor wrapper');

  assertExcludes(probeSource.get('oh-package.json5'), '@cmfa/', 'probe root package');
  const entryPackage = probeSource.get('entry/oh-package.json5');
  assertExcludes(entryPackage, '@cmfa/', 'probe entry package');
  assertIncludes(entryPackage, '"libprobeentry.so": "file:./src/main/cpp/types/libprobeentry"', 'probe entry package');
  assertExcludes(entryPackage, 'libentry.so', 'probe entry package');

  const entryBuildProfile = probeSource.get('entry/build-profile.json5');
  assertIncludes(entryBuildProfile, '"externalNativeOptions"', 'probe entry build profile');
  assertIncludes(entryBuildProfile, '"path": "./src/main/cpp/CMakeLists.txt"', 'probe entry build profile');
  assertIncludes(entryBuildProfile, '"arm64-v8a"', 'probe entry build profile');
  assertIncludes(entryBuildProfile, '"probeentry"', 'probe entry build profile');
  assertExcludes(entryBuildProfile, '"entry"', 'probe entry build profile');

  const probeNativeCmake = probeSource.get('entry/src/main/cpp/CMakeLists.txt');
  assertIncludes(probeNativeCmake, 'project(probeentry C CXX)', 'probe native CMake');
  assertIncludes(probeNativeCmake, 'add_library(probeentry SHARED', 'probe native CMake');
  assertIncludes(probeNativeCmake, 'probe_native_core.cpp', 'probe native CMake');
  assertIncludes(probeNativeCmake, 'probe_native_napi.cpp', 'probe native CMake');
  assertIncludes(probeNativeCmake, 'libace_napi.z.so', 'probe native CMake');
  assertExcludes(probeNativeCmake, 'libcmfa_mihomo.so', 'probe native CMake');
  assertExcludes(probeNativeCmake, 'add_library(entry SHARED', 'probe native CMake');
  assertExcludes(probeNativeCmake, 'stub', 'probe native CMake');

  const probeTypePackage = probeSource.get('entry/src/main/cpp/types/libprobeentry/oh-package.json5');
  assertIncludes(probeTypePackage, '"name": "libprobeentry.so"', 'probe native type package');
  assertIncludes(probeTypePackage, '"types": "./Index.d.ts"', 'probe native type package');
  const probeTypeDeclarations = probeSource.get('entry/src/main/cpp/types/libprobeentry/Index.d.ts');
  assertIncludes(probeTypeDeclarations, 'export interface ProbeSocketRequest', 'probe native type declarations');
  assertIncludes(probeTypeDeclarations, 'export declare function probeSocket', 'probe native type declarations');
  assertExcludes(probeTypeDeclarations, 'cmfa_', 'probe native type declarations');

  const probeGitignore = probeSource.get('.gitignore');
  assertIncludes(probeGitignore, '/.hvigor/', 'probe .gitignore');
  assertIncludes(probeGitignore, '/entry/.test/', 'probe .gitignore');
  assertIncludes(probeGitignore, '/entry/build/', 'probe .gitignore');
  assertIncludes(probeGitignore, '/oh_modules/', 'probe .gitignore');
  assertExcludes(probeGitignore, 'oh-package-lock.json5', 'probe .gitignore');

  const lockfileSource = probeSource.get('oh-package-lock.json5');
  assertIncludes(lockfileSource, '"@ohos/hypium"', 'probe lockfile');
  assertIncludes(lockfileSource, '"version": "1.0.25"', 'probe lockfile');
  assertExcludes(lockfileSource, '../', 'probe lockfile');
  assertExcludes(lockfileSource, 'file:../', 'probe lockfile');
  assertExcludes(lockfileSource, '@cmfa/', 'probe lockfile');
});

test('phase4 probe stays isolated from production manifests, modules, resources, and native payload lists', async () => {
  const productionFiles = await Promise.all(
    PRODUCTION_FILES.map(async (relativePath) => [relativePath, await readUtf8(path.join(HARMONY_ROOT, relativePath))])
  );

  for (const [relativePath, source] of productionFiles) {
    const label = `production file ${relativePath}`;
    assertExcludes(source, 'traffic-probe', label);
    assertExcludes(source, PROBE_BUNDLE_NAME, label);
    assertExcludes(source, 'ProbeAbility', label);
    assertExcludes(source, 'ProbePage', label);
    assertExcludes(source, 'DirectTrafficProbe', label);
    assertExcludes(source, PROBE_EVIDENCE_FILE, label);
    assertExcludes(source, 'libprobeentry.so', label);
    assertExcludes(source, 'probeAddon', label);
    assertExcludes(source, 'types/libprobeentry', label);
    assertExcludes(source, 'externalOriginHost', label);
    assertExcludes(source, 'externalTcpHost', label);
    assertExcludes(source, 'externalOriginTcpPort', label);
    assertExcludes(source, 'externalOriginUdpPort', label);
    assertExcludes(source, 'externalOriginDnsPort', label);
  }

  const productionAppScope = await readUtf8(path.join(HARMONY_ROOT, 'AppScope/app.json5'));
  assertIncludes(productionAppScope, PRODUCTION_BUNDLE_NAME, 'production app scope');
  assertExcludes(productionAppScope, 'trafficprobe', 'production app scope');
});

test('phase4 probe uses native global socket probes and the Harmony HTTP certificate-pin value format', async () => {
  const source = await readUtf8(path.join(PROBE_ROOT, 'entry/src/main/ets/probe/DirectTrafficProbe.ets'));
  assertIncludes(source, ".probe('tcpExchange'", 'probe native TCP exchange source');
  assertIncludes(source, ".probe('udpEcho'", 'probe native UDP source');
  assertIncludes(source, ".probe('dnsUdpEcho'", 'probe native DNS UDP source');
  assertExcludes(source, "new ProbeSocketAddress(ipv6 ? ANY_V6 : ANY_V4, ipv6 ? 2 : 1, 0)", 'probe UDP source');
  assertIncludes(
    source,
    'pinning.publicKeyHash = normalizeCertificatePinForHttp(command.pinnedCertificateHash);',
    'probe HTTPS pin adapter'
  );
  assert.match(source, /normalizeCertificatePinForHttp[\s\S]*startsWith\('sha256\/'\)/u);
});

test('phase4 probe receives an ephemeral public CA as a flat Want field without persisting it as evidence', async () => {
  const [models, ability, probe, runner] = await Promise.all([
    readUtf8(path.join(PROBE_ROOT, 'entry/src/main/ets/probe/ProbeModels.ets')),
    readUtf8(path.join(PROBE_ROOT, 'entry/src/main/ets/entryability/ProbeAbility.ets')),
    readUtf8(path.join(PROBE_ROOT, 'entry/src/main/ets/probe/DirectTrafficProbe.ets')),
    readUtf8(path.join(HARMONY_ROOT, 'tests/bin/run-phase4-device-proof.mjs'))
  ]);
  assertIncludes(models, "PROBE_PARAM_ORIGIN_CA_PEM: string = 'originCaPem'", 'probe CA parameter model');
  assertIncludes(models, "originCaPem: string = '';", 'probe command CA field');
  assertIncludes(ability, 'command.originCaPem = readString(parameters, PROBE_PARAM_ORIGIN_CA_PEM);', 'probe flat Want parser');
  assertIncludes(probe, 'requestOptions.caData = options.caData;', 'Harmony HTTP CA adapter');
  assertIncludes(probe, 'options.caData = command.originCaPem;', 'probe HTTP options');
  assertIncludes(runner, "'--ps', 'originCaPem', parameters.originCaPem", 'runner flat CA Want argument');
  assertIncludes(runner, 'originCaPem: originHandle.https.caPem', 'runner ephemeral CA source');
  assertExcludes(models, 'caPrivateKey', 'probe public CA model');
});

test('phase4 runner launches distinct baseline and VPN capture sessions with explicit ingress modes', async () => {
  const [models, ability, probe, runner] = await Promise.all([
    readUtf8(path.join(PROBE_ROOT, 'entry/src/main/ets/probe/ProbeModels.ets')),
    readUtf8(path.join(PROBE_ROOT, 'entry/src/main/ets/entryability/ProbeAbility.ets')),
    readUtf8(path.join(PROBE_ROOT, 'entry/src/main/ets/probe/DirectTrafficProbe.ets')),
    readUtf8(path.join(HARMONY_ROOT, 'tests/bin/run-phase4-device-proof.mjs'))
  ]);

  assertIncludes(models, "PROBE_PARAM_CAPTURE_MODE: string = 'captureMode'", 'probe capture-mode parameter');
  assertIncludes(models, "PROBE_PARAM_EXTERNAL_ORIGIN_HOST: string = 'externalOriginHost'", 'probe external-origin host parameter');
  assertIncludes(models, "PROBE_PARAM_EXTERNAL_TCP_HOST: string = 'externalTcpHost'", 'probe external tcp host parameter');
  assertIncludes(models, "PROBE_PARAM_EXTERNAL_ORIGIN_TCP_PORT: string = 'externalOriginTcpPort'", 'probe external-origin tcp parameter');
  assertIncludes(models, "PROBE_PARAM_EXTERNAL_ORIGIN_UDP_PORT: string = 'externalOriginUdpPort'", 'probe external-origin udp parameter');
  assertIncludes(models, "PROBE_PARAM_EXTERNAL_ORIGIN_DNS_PORT: string = 'externalOriginDnsPort'", 'probe external-origin dns parameter');
  assertIncludes(models, "captureMode: 'baseline' | 'vpn' = 'baseline';", 'probe command default capture mode');
  assertIncludes(ability, 'command.captureMode = readProbeCaptureMode(parameters);', 'probe capture-mode Want parser');
  assertIncludes(probe, 'externalIngressExpectation(command)', 'external probe ingress selection');
  assertIncludes(probe, "command.captureMode === 'vpn' ? 'tun' : 'lan-origin-direct'", 'mode-specific external ingress');
  assertIncludes(runner, "'--ps', 'captureMode', parameters.captureMode", 'runner flat capture-mode Want argument');
  assertIncludes(runner, "'--ps', 'externalOriginHost', parameters.externalOrigin.hostIpv4", 'runner flat external-origin host argument');
  assertIncludes(runner, "'--ps', 'externalTcpHost', parameters.externalOrigin.tcpHostIpv4", 'runner flat external tcp host argument');
  assertIncludes(runner, "'--pi', 'externalOriginTcpPort', `${parameters.externalOrigin.tcpPort}`", 'runner flat external-origin tcp argument');
  assertIncludes(runner, "'--pi', 'externalOriginUdpPort', `${parameters.externalOrigin.udpPort}`", 'runner flat external-origin udp argument');
  assertIncludes(runner, "'--pi', 'externalOriginDnsPort', `${parameters.externalOrigin.dnsPort}`", 'runner flat external-origin dns argument');
  assertIncludes(runner, "buildProbeAbilityParameters(origin, externalOrigin, runId, 'baseline')", 'runner baseline capture launch');
  assertIncludes(runner, "buildProbeAbilityParameters(origin, externalOrigin, runId, 'vpn')", 'runner VPN capture launch');
  assertIncludes(runner, 'expectedSessionId: parameters.sessionId', 'runner fresh-session evidence wait');
  assertExcludes(runner, "buildProductionLaunchArgs(target, runId, ", 'runner production launch path');
});
