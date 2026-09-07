import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../../', import.meta.url);

test('HarmonyOS source, build entry points and attribution remain available', () => {
  for (const path of [
    'harmony/entry/src/main/module.json5', 'harmony/shared/Index.ets',
    'harmony/platform/Index.ets', 'harmony/core/go/go.mod',
    'harmony/hvigorw', 'harmony/build-profile.json5',
    'harmony/traffic-probe/build-profile.json5',
    'docs/harmony/current-version-vpn-user-guide.md',
    'LICENSE', 'NOTICE', 'harmony/THIRD_PARTY_NOTICES.md'
  ]) {
    assert.ok(existsSync(new URL(path, root)), `Missing HarmonyOS input: ${path}`);
  }
  const goModule = readFileSync(new URL('harmony/core/go/go.mod', root), 'utf8');
  assert.match(goModule, /require github.com\/metacubex\/mihomo v/);
  assert.doesNotMatch(goModule, /core\/src\/foss/);
});

test('Android build and distribution entry points are removed', () => {
  for (const path of [
    'app/build.gradle.kts', 'common/build.gradle.kts', 'core/build.gradle.kts',
    'design/build.gradle.kts', 'service/build.gradle.kts', 'hideapi/build.gradle.kts',
    'build.gradle.kts', 'settings.gradle.kts', 'gradle.properties',
    'gradlew', 'gradlew.bat', 'gradle/wrapper/gradle-wrapper.jar',
    '.gitmodules', 'release.keystore',
    '.github/workflows/build-debug.yaml', '.github/workflows/build-release.yaml',
    '.github/workflows/build-pre-release.yaml', '.github/workflows/update-dependencies.yaml'
  ]) {
    assert.equal(existsSync(new URL(path, root)), false, `Android input remains: ${path}`);
  }
});
