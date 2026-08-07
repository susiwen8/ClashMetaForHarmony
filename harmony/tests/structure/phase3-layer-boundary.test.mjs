import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const SHARED_ETS_ROOT = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets');
const FORBIDDEN_SHARED_IMPORT_PATTERNS = [
  /@kit\./u,
  /@ohos\./u,
  /\bArkUI\b/u,
  /\bRDB\b/u,
  /\bPicker\b/u,
  /\bHUKS\b/u,
  /\bNode-API\b/u
];

async function readJson(relativePath) {
  return JSON.parse(await fs.readFile(path.join(HARMONY_ROOT, relativePath), 'utf8'));
}

async function collectFiles(rootDir) {
  const entries = await fs.readdir(rootDir, { withFileTypes: true });
  const files = await Promise.all(entries.map(async (entry) => {
    const absolutePath = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      return await collectFiles(absolutePath);
    }
    if (entry.isFile()) {
      return [absolutePath];
    }
    return [];
  }));
  return files.flat().sort();
}

test('Task 1 registers the platform HAR and keeps shared ArkTS free of platform imports', async () => {
  const [projectBuildProfile, platformPkg, entryPkg, sharedFiles] = await Promise.all([
    readJson('build-profile.json5'),
    readJson('platform/oh-package.json5'),
    readJson('entry/oh-package.json5'),
    collectFiles(SHARED_ETS_ROOT)
  ]);

  const registeredModuleNames = projectBuildProfile.modules.map((entry) => entry.name).sort();
  assert.deepEqual(registeredModuleNames, ['core', 'entry', 'platform', 'shared']);

  assert.equal(platformPkg.dependencies?.['@cmfa/shared'], 'file:../shared');
  assert.equal(entryPkg.dependencies?.['@cmfa/platform'], 'file:../platform');
  assert.equal(entryPkg.dependencies?.['@cmfa/shared'], 'file:../shared');
  assert.equal(entryPkg.dependencies?.['@cmfa/core'], 'file:../core');

  const forbiddenSharedImports = [];
  for (const filePath of sharedFiles) {
    const body = await fs.readFile(filePath, 'utf8');
    for (const pattern of FORBIDDEN_SHARED_IMPORT_PATTERNS) {
      if (pattern.test(body)) {
        forbiddenSharedImports.push({
          file: path.relative(HARMONY_ROOT, filePath).split(path.sep).join('/'),
          pattern: pattern.source
        });
      }
    }
  }

  assert.equal(forbiddenSharedImports.length, 0);
});
