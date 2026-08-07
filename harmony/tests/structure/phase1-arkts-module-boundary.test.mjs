import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));

function assertRegisteredArktsModules(projectBuildProfile) {
  const registeredModuleOrder = projectBuildProfile.modules.map((entry) => entry.name);
  assert.deepEqual(registeredModuleOrder, ['shared', 'platform', 'core', 'entry']);
  const registeredModuleNames = projectBuildProfile.modules.map((entry) => entry.name).sort();
  assert.deepEqual(registeredModuleNames, ['core', 'entry', 'platform', 'shared']);
  for (const moduleName of ['core', 'platform', 'shared']) {
    const registration = projectBuildProfile.modules.find((entry) => entry.name === moduleName);
    assert.equal(registration.srcPath, `./${moduleName}`);
    assert.deepEqual(registration.targets, [{ name: 'default' }]);
  }
}

async function readJson(relativePath) {
  return JSON.parse(await fs.readFile(path.join(HARMONY_ROOT, relativePath), 'utf8'));
}

async function readText(relativePath) {
  return await fs.readFile(path.join(HARMONY_ROOT, relativePath), 'utf8');
}

test('Task 8 ArkTS modules use local oh-package source dependencies instead of cross-module relative imports', async () => {
  const [
    projectBuildProfile,
    sharedPkg,
    platformPkg,
    corePkg,
    entryPkg,
    sharedIndex,
    coreIndex,
    sharedBuildProfile,
    platformBuildProfile,
    coreBuildProfile,
    sharedModuleProfile,
    platformModuleProfile,
    coreModuleProfile,
    sharedHvigor,
    platformHvigor,
    coreHvigor,
    composition,
    adapter
  ] = await Promise.all([
    readJson('build-profile.json5'),
    readJson('shared/oh-package.json5'),
    readJson('platform/oh-package.json5'),
    readJson('core/oh-package.json5'),
    readJson('entry/oh-package.json5'),
    readText('shared/Index.ets'),
    readText('core/Index.ets'),
    readJson('shared/build-profile.json5'),
    readJson('platform/build-profile.json5'),
    readJson('core/build-profile.json5'),
    readJson('shared/src/main/module.json5'),
    readJson('platform/src/main/module.json5'),
    readJson('core/src/main/module.json5'),
    readText('shared/hvigorfile.ts'),
    readText('platform/hvigorfile.ts'),
    readText('core/hvigorfile.ts'),
    readText('entry/src/main/ets/bootstrap/CoreComposition.ets'),
    readText('core/src/main/ets/CoreNativeAdapter.ets')
  ]);

  assertRegisteredArktsModules(projectBuildProfile);

  assert.equal(sharedPkg.name, '@cmfa/shared');
  assert.equal(sharedPkg.main, 'Index.ets');
  assert.deepEqual(sharedPkg.dependencies ?? {}, {});

  assert.equal(platformPkg.name, '@cmfa/platform');
  assert.equal(platformPkg.main, 'Index.ets');
  assert.equal(platformPkg.dependencies?.['@cmfa/shared'], 'file:../shared');

  assert.equal(corePkg.name, '@cmfa/core');
  assert.equal(corePkg.main, 'Index.ets');
  assert.equal(corePkg.dependencies?.['@cmfa/shared'], 'file:../shared');

  assert.equal(entryPkg.dependencies?.['@cmfa/platform'], 'file:../platform');
  assert.equal(entryPkg.dependencies?.['@cmfa/shared'], 'file:../shared');
  assert.equal(entryPkg.dependencies?.['@cmfa/core'], 'file:../core');
  assert.equal(entryPkg.dependencies?.['libentry.so'], 'file:./src/main/cpp/types/libentry');

  assert.match(sharedIndex, /export .* from ['"]\.\/src\/main\/ets\/core\/CoreModels['"]/u);
  assert.match(sharedIndex, /export .* from ['"]\.\/src\/main\/ets\/core\/CoreService['"]/u);
  assert.match(sharedIndex, /export .* from ['"]\.\/src\/main\/ets\/core\/CoreErrors['"]/u);

  assert.match(coreIndex, /createCoreService/u);
  assert.match(coreIndex, /CORE_BRIDGE_VERSION/u);
  assert.doesNotMatch(coreIndex, /export\s+(?:class|interface|type)\s+CoreNativeAdapter/u, '@cmfa/core root must not export the concrete adapter');
  assert.doesNotMatch(coreIndex, /probeHttpsForSelfTest|probeHttps/u, '@cmfa/core root must not export self-test probe surface');

  for (const [buildProfile, moduleProfile, hvigor, moduleName] of [
    [sharedBuildProfile, sharedModuleProfile, sharedHvigor, 'shared'],
    [platformBuildProfile, platformModuleProfile, platformHvigor, 'platform'],
    [coreBuildProfile, coreModuleProfile, coreHvigor, 'core']
  ]) {
    assert.equal(buildProfile.apiType, 'stageMode');
    assert.equal(buildProfile.buildOption?.resOptions?.copyCodeResource?.enable, false);
    assert.deepEqual(buildProfile.targets, [{ name: 'default' }]);
    assert.equal(moduleProfile.module?.name, moduleName);
    assert.equal(moduleProfile.module?.type, 'har');
    assert.ok(Array.isArray(moduleProfile.module?.deviceTypes));
    assert.match(hvigor, /harTasks/u);
  }

  assert.match(composition, /from ['"]@cmfa\/core['"]/u);
  assert.match(composition, /createCoreService/u);
  assert.match(composition, /getSelfTestCoreService/u);
  assert.match(composition, /interface Phase2SelfTestCoreService/u);
  assert.match(composition, /probeHttpsForSelfTest/u);
  assert.match(composition, /from ['"]@cmfa\/shared['"]/u);
  assert.doesNotMatch(composition, /\.\.\/\.\.\/\.\.\/\.\.\/\.\.\/core/u);

  assert.match(adapter, /from ['"]@cmfa\/shared['"]/u);
  assert.doesNotMatch(adapter, /\.\.\/\.\.\/\.\.\/shared/u);
});

test('Task 1 module registration guard rejects reordered modules even when the set matches', () => {
  const reorderedBuildProfile = {
    modules: [
      { name: 'shared', srcPath: './shared', targets: [{ name: 'default' }] },
      {
        name: 'core',
        srcPath: './core',
        targets: [{ name: 'default' }]
      },
      {
        name: 'platform',
        srcPath: './platform',
        targets: [{ name: 'default' }]
      },
      {
        name: 'entry',
        srcPath: './entry',
        targets: [{ name: 'default', applyToProducts: ['default'] }]
      }
    ]
  };

  assert.throws(
    () => assertRegisteredArktsModules(reorderedBuildProfile),
    /shared|platform/u
  );
});

test('CoreNativeAdapter normalizes both synchronous native throws and Promise rejections', async () => {
  const adapter = await readText('core/src/main/ets/CoreNativeAdapter.ets');

  for (const [nativeCall, returnType] of [
    ['nativeCoreVersion', 'Promise<string>'],
    ['nativeValidateConfiguration', 'Promise<void>'],
    ['nativeLoadConfiguration', 'Promise<void>'],
    ['nativeStartLocal', 'Promise<RuntimeSnapshot>'],
    ['nativeStopRuntime', 'Promise<RuntimeSnapshot>']
  ]) {
    assert.match(adapter, new RegExp(`\\(\\): ${returnType} => ${nativeCall}\\(`, 'u'));
  }
  assert.match(adapter, /invoke: \(\) => Promise<T>/u);
  assert.match(adapter, /try\s*\{[\s\S]*invoke\(\)\.catch/u);
  assert.match(adapter, /catch \(error\)[\s\S]*Promise\.reject\(normalizeCoreError/u);
});

test('CoreDebugPage observes new Want contexts and runs each self-test runId at most once', async () => {
  const [composition, page, ability] = await Promise.all([
    readText('entry/src/main/ets/bootstrap/CoreComposition.ets'),
    readText('entry/src/main/ets/pages/CoreDebugPage.ets'),
    readText('entry/src/main/ets/entryability/EntryAbility.ets')
  ]);

  assert.match(composition, /subscribePhase1LaunchContext/u);
  assert.match(composition, /unsubscribePhase1LaunchContext/u);
  assert.match(composition, /phase1LaunchListener\?\.\(context\)/u);
  assert.match(composition, /probeOriginUrl/u);
  assert.match(composition, /probeCaPem/u);
  assert.match(composition, /probeExpectedBodySha256/u);
  assert.match(ability, /cmfa\.phase2\.originUrl/u);
  assert.match(ability, /cmfa\.phase2\.caPem/u);
  assert.match(ability, /cmfa\.phase2\.expectedBodySha256/u);
  assert.match(page, /subscribePhase1LaunchContext/u);
  assert.match(page, /unsubscribePhase1LaunchContext/u);
  assert.match(page, /selfTestInFlight/u);
  assert.match(page, /activeRunId/u);
  assert.match(page, /activeRunId === context\.runId/u);
  assert.match(page, /runAutomaticSelfTest\(context: Phase1LaunchContext\)/u);
  assert.match(page, /writeProof\(proof, context\.filesDir\)/u);
  assert.match(page, /runPhase2ProbeSelfTest\(context: Phase1LaunchContext\)/u);
  assert.match(page, /phase2-device-proof\.json/u);
  assert.match(page, /phase2-match-direct\.yaml/u);
  assert.match(page, /getSelfTestCoreService/u);
  assert.match(page, /probeHttpsForSelfTest/u);
  assert.match(page, /this\.coreService\.startLocal/u);
  assert.match(page, /this\.coreService\.stopRuntime/u);
});
