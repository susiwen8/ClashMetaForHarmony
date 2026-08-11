import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry');
const APPLICATION_COMPOSITION_PATH = path.join(ENTRY_ROOT, 'src', 'main', 'ets', 'bootstrap', 'ApplicationComposition.ets');
const CORE_COMPOSITION_PATH = path.join(ENTRY_ROOT, 'src', 'main', 'ets', 'bootstrap', 'CoreComposition.ets');
const ENTRY_ABILITY_PATH = path.join(ENTRY_ROOT, 'src', 'main', 'ets', 'entryability', 'EntryAbility.ets');
const ENTRY_TEST_LIST_PATH = path.join(ENTRY_ROOT, 'src', 'test', 'List.test.ets');

function parseJson5Object(raw) {
  return Function(`"use strict"; return (${raw});`)();
}

function collectNamedExports(source) {
  return [...source.matchAll(/^export\s+(?:type|interface)\s+(\w+)/gmu)].map((match) => match[1]).sort();
}

test('Task 10 composition surface stays abstract and entry depends on @cmfa/platform', async () => {
  const [compositionSource, coreCompositionSource, entryPackageRaw] = await Promise.all([
    fs.readFile(APPLICATION_COMPOSITION_PATH, 'utf8'),
    fs.readFile(CORE_COMPOSITION_PATH, 'utf8'),
    fs.readFile(path.join(ENTRY_ROOT, 'oh-package.json5'), 'utf8')
  ]);
  const entryPackage = parseJson5Object(entryPackageRaw);

  assert.deepEqual(collectNamedExports(compositionSource), ['ApplicationComposition', 'ApplicationCompositionState']);
  assert.equal([...compositionSource.matchAll(/^export\s+(?:class|function|const|let|var)\b/gmu)].length, 0);
  assert.doesNotMatch(
    compositionSource,
    /PlatformFactory|HarmonyRdbDriver|HarmonyHuksDriver|HarmonyFilePicker|NetworkKitHttpTransport|RequestAgentRedirectTransport/u,
    'ApplicationComposition public surface must not expose concrete platform adapters'
  );
  assert.match(coreCompositionSource, /createApplicationComposition/u);
  assert.equal(entryPackage.dependencies?.['@cmfa/platform'], 'file:../platform');
});

test('Task 10 entry routing keeps production and self-test launches isolated', async () => {
  const [entryAbilitySource, entryTestListSource] = await Promise.all([
    fs.readFile(ENTRY_ABILITY_PATH, 'utf8'),
    fs.readFile(ENTRY_TEST_LIST_PATH, 'utf8')
  ]);

  assert.match(entryAbilitySource, /private\s+windowStage\??:\s*window\.WindowStage/u);
  assert.match(entryAbilitySource, /private\s+applicationComposition\??:\s*ApplicationComposition/u);
  assert.match(entryAbilitySource, /private\s+async\s+loadTargetPage\s*\(/u);
  assert.match(entryAbilitySource, /pages\/Index/u);
  assert.match(entryAbilitySource, /pages\/CoreDebugPage/u);
  assert.match(entryAbilitySource, /createApplicationComposition/u);
  assert.match(entryAbilitySource, /if\s*\(\s*launchContext\.selfTest\s*\)/u);
  assert.match(entryAbilitySource, /await\s+this\.closeApplicationComposition\(\)/u);
  assert.match(entryAbilitySource, /onDestroy\(\):\s*void\s*\{[\s\S]*closeApplicationComposition\(\)/u);
  assert.doesNotMatch(
    entryAbilitySource,
    /HarmonyRdbDriver|HarmonyHuksDriver|HarmonyFilePicker|NetworkKitHttpTransport|RequestAgentRedirectTransport/u,
    'EntryAbility must not directly initialize concrete product adapters'
  );
  assert.match(entryTestListSource, /ApplicationComposition\.test/u);
});

test('Task 10 entry routing serializes navigation around the latest Want and invalidates teardown', async () => {
  const entryAbilitySource = await fs.readFile(ENTRY_ABILITY_PATH, 'utf8');

  assert.match(entryAbilitySource, /private\s+navigationPromise:\s*Promise<void>\s*=\s*Promise\.resolve\(\)/u);
  assert.match(entryAbilitySource, /private\s+navigationGeneration:\s*number\s*=\s*0/u);
  assert.match(entryAbilitySource, /private\s+scheduleNavigation\(\):\s*void/u);
  assert.match(entryAbilitySource, /const\s+generation:\s*number\s*=\s*\+\+this\.navigationGeneration/u);
  assert.match(entryAbilitySource, /this\.navigationPromise\s*=\s*this\.navigationPromise[\s\S]*\.then\(\s*async\s*\(\)\s*=>\s*\{/u);
  assert.match(entryAbilitySource, /if\s*\(\s*generation\s*!==\s*this\.navigationGeneration\s*\)/u);
  assert.match(entryAbilitySource, /private\s+scheduleTeardown\(\):\s*void/u);
  assert.match(entryAbilitySource, /const\s+generation:\s*number\s*=\s*\+\+this\.navigationGeneration[\s\S]*this\.windowStage\s*=\s*undefined/u);
  assert.match(entryAbilitySource, /onNewWant\([\s\S]*this\.scheduleNavigation\(\)/u);
  assert.match(entryAbilitySource, /onWindowStageCreate\([\s\S]*this\.scheduleNavigation\(\)/u);
  assert.match(entryAbilitySource, /onDestroy\(\):\s*void\s*\{[\s\S]*this\.scheduleTeardown\(\)/u);
  assert.match(entryAbilitySource, /onWindowStageDestroy\(\):\s*void\s*\{[\s\S]*this\.scheduleTeardown\(\)/u);
});
