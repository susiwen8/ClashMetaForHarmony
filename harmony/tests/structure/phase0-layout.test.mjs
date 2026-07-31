import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const harmonyRoot = resolvePathFromImportMetaUrl(import.meta.url);
const repoRoot = path.resolve(harmonyRoot, '..');
const fixturePath = new URL('../fixtures/required-phase0-paths.json', import.meta.url);

function parseJson5Like(raw, filePath) {
  const sanitized = raw
    .replace(/\/\*[\s\S]*?\*\//gu, '')
    .replace(/^\s*\/\/.*$/gmu, '')
    .replace(/,\s*([}\]])/gu, '$1');

  try {
    return JSON.parse(sanitized);
  } catch (error) {
    error.message = `Failed to parse ${filePath}: ${error.message}`;
    throw error;
  }
}

async function readJson5(relativePath) {
  const absolutePath = path.join(harmonyRoot, relativePath);
  const raw = await fs.readFile(absolutePath, 'utf8');
  return parseJson5Like(raw, relativePath);
}

function resolvePathFromImportMetaUrl(importMetaUrl, relativePath = '../..') {
  return path.resolve(fileURLToPath(new URL(relativePath, importMetaUrl)));
}

function containsHarmonyProjectLiteral(source) {
  return /":harmony(?::[^"]+)?"/u.test(source);
}

test('phase0 layout helpers reject harmony project literals across multi-arg includes and decode encoded spaces', () => {
  const includeSamples = [
    `include(":${['app'].join('')}", ":${['harm', 'ony'].join('')}")`,
    `include(":${['harm', 'ony'].join('')}", ":${['app'].join('')}")`,
    `include(${['"common"', '":harmony:entry"', '":service"'].join(', ')})`
  ];

  for (const sample of includeSamples) {
    assert.equal(containsHarmonyProjectLiteral(sample), true);
  }

  const spacedRoot = resolvePathFromImportMetaUrl('file:///tmp/Space%20Folder/harmony/tests/structure/phase0-layout.test.mjs');
  assert.equal(spacedRoot, '/tmp/Space Folder/harmony');
});

test('phase0 Stage skeleton matches the HarmonyOS 6/API 20 contract', async () => {
  const fixture = JSON.parse(await fs.readFile(fixturePath, 'utf8'));
  const missingPaths = [];

  for (const relativePath of fixture.requiredPaths) {
    try {
      await fs.access(path.join(harmonyRoot, relativePath));
    } catch {
      missingPaths.push(relativePath);
    }
  }

  assert.deepEqual(missingPaths, [], `Missing required phase0 paths:\n${missingPaths.join('\n')}`);

  const appJson = await readJson5('AppScope/app.json5');
  assert.equal(appJson.app.bundleName, fixture.project.bundleName);

  const buildProfile = await readJson5('build-profile.json5');
  assert.deepEqual(buildProfile.app.signingConfigs, []);
  const product = buildProfile.app.products.find((entry) => entry.name === fixture.project.productName);
  assert.ok(product, `Missing product ${fixture.project.productName}`);
  assert.equal(product.targetSdkVersion, fixture.project.targetSdkVersion);
  assert.equal(product.compatibleSdkVersion, fixture.project.compatibleSdkVersion);
  assert.equal(product.runtimeOS, fixture.project.runtimeOS);

  const entryBuildProfile = await readJson5('entry/build-profile.json5');
  assert.equal(entryBuildProfile.apiType, 'stageMode');
  assert.ok(entryBuildProfile.targets.some((target) => target.name === fixture.project.productName));

  const moduleJson = await readJson5('entry/src/main/module.json5');
  assert.equal(moduleJson.module.name, fixture.module.name);
  assert.equal(moduleJson.module.type, fixture.module.type);
  assert.equal(moduleJson.module.mainElement, fixture.module.mainElement);
  assert.equal(moduleJson.module.pages, fixture.module.pages);
  assert.ok(Array.isArray(moduleJson.module.deviceTypes));
  assert.ok(moduleJson.module.deviceTypes.includes('phone'));

  const ability = moduleJson.module.abilities.find((entry) => entry.name === fixture.ability.name);
  assert.ok(ability, `Missing ability ${fixture.ability.name}`);
  assert.equal(ability.srcEntry, fixture.ability.srcEntry);

  const mainPages = JSON.parse(await fs.readFile(path.join(harmonyRoot, 'entry/src/main/resources/base/profile/main_pages.json'), 'utf8'));
  assert.ok(Array.isArray(mainPages.src));
  assert.ok(mainPages.src.includes(fixture.page.route));

  const entryAbilitySource = await fs.readFile(
    path.join(harmonyRoot, 'entry/src/main/ets/entryability/EntryAbility.ets'),
    'utf8'
  );
  assert.match(entryAbilitySource, /class\s+EntryAbility\s+extends\s+UIAbility/u);
  assert.match(entryAbilitySource, /loadContent\('pages\/Index'/u);

  const indexSource = await fs.readFile(
    path.join(harmonyRoot, 'entry/src/main/ets/pages/Index.ets'),
    'utf8'
  );
  assert.match(indexSource, /@Entry/u);
  assert.match(indexSource, /struct\s+Index/u);
});

test('phase0 layout keeps Harmony isolated from the Android root project and wrapper copies', async () => {
  const rootSettings = await fs.readFile(path.join(repoRoot, 'settings.gradle.kts'), 'utf8');
  assert.equal(containsHarmonyProjectLiteral(rootSettings), false);

  await assert.rejects(fs.access(path.join(harmonyRoot, 'hvigorw.js')));
  await assert.rejects(fs.access(path.join(harmonyRoot, 'hvigorw.bat')));
});

test('phase0 wrapper is a POSIX adapter for the integrated DevEco hvigor wrapper', async () => {
  const wrapperPath = path.join(harmonyRoot, 'hvigorw');
  const stats = await fs.stat(wrapperPath);
  const wrapperSource = await fs.readFile(wrapperPath, 'utf8');

  assert.ok((stats.mode & 0o111) !== 0, 'harmony/hvigorw must stay executable');
  assert.doesNotMatch(wrapperSource, /\/Users\//u);
  assert.doesNotMatch(wrapperSource, /hvigorw\.js/u);
  assert.match(wrapperSource, /\/Applications\/DevEco-Studio\.app\/Contents/u);
  assert.match(wrapperSource, /DEVECO_SDK_HOME/u);
  assert.match(wrapperSource, /tools\/hvigor\/bin\/hvigorw/u);
  assert.match(wrapperSource, /\bexec\b/u);
});

test('phase0 template PNG assets stay non-executable', async () => {
  const pngAssets = [
    'AppScope/resources/base/media/background.png',
    'AppScope/resources/base/media/foreground.png',
    'entry/src/main/resources/base/media/background.png',
    'entry/src/main/resources/base/media/foreground.png',
    'entry/src/main/resources/base/media/startIcon.png'
  ];

  for (const relativePath of pngAssets) {
    const stats = await fs.stat(path.join(harmonyRoot, relativePath));
    assert.equal(stats.isFile(), true, `${relativePath} must remain a regular file`);
    assert.equal(stats.mode & 0o111, 0, `${relativePath} must not carry executable bits`);
  }
});
