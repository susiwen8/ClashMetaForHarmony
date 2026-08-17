import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const PROBE_ROOT = path.join(HARMONY_ROOT, 'traffic-probe');
const PROBE_BUNDLE_NAME = 'com.github.kr328.clash.harmony.trafficprobe';
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

  const rootBuildProfile = probeSource.get('build-profile.json5');
  assertIncludes(rootBuildProfile, '"compatibleSdkVersion": "6.0.0(20)"', 'probe build profile');
  assertIncludes(rootBuildProfile, '"targetSdkVersion": "6.1.0(23)"', 'probe build profile');
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
  assertExcludes(probeSource.get('entry/oh-package.json5'), '@cmfa/', 'probe entry package');
  assertExcludes(probeSource.get('entry/build-profile.json5'), 'externalNativeOptions', 'probe entry build profile');
  assertExcludes(probeSource.get('entry/build-profile.json5'), 'CMakeLists.txt', 'probe entry build profile');

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
  }

  const productionAppScope = await readUtf8(path.join(HARMONY_ROOT, 'AppScope/app.json5'));
  assertIncludes(productionAppScope, PRODUCTION_BUNDLE_NAME, 'production app scope');
  assertExcludes(productionAppScope, 'trafficprobe', 'production app scope');
});
