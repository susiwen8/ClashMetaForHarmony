import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

const harmonyRoot = path.resolve(new URL('../..', import.meta.url).pathname);
const cppIncludeDir = path.join(harmonyRoot, 'entry', 'src', 'main', 'cpp', 'include');
const cppSourceDir = path.join(harmonyRoot, 'entry', 'src', 'main', 'cpp', 'src');
const runnerPath = path.join(harmonyRoot, 'tools', 'test-native-host.mjs');
const backendSourceName = 'cmfa_mihomo_backend.cpp';
const rawVersionSymbol = 'cmfa_mihomo_core_version_cstr_v1';
const mainGuardSnippet =
  'process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)';
const expectedUsage = [
  'Usage:',
  '  node harmony/tools/test-native-host.mjs',
  '  node harmony/tools/test-native-host.mjs --case contract',
  '  node harmony/tools/test-native-host.mjs --case mihomo-backend',
  '  node harmony/tools/test-native-host.mjs --case napi-environment',
].join('\n');

async function readTreeFiles(rootDir) {
  const entries = await fs.readdir(rootDir, { withFileTypes: true });
  const files = await Promise.all(entries.map(async (entry) => {
    const absolutePath = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      return await readTreeFiles(absolutePath);
    }
    if (entry.isFile()) {
      return [absolutePath];
    }
    return [];
  }));
  return files.flat();
}

function expectArgumentInvalid(fn, args, message) {
  assert.throws(
    () => fn(args),
    (error) => error?.code === 'ARGUMENT_INVALID',
    message
  );
}

test('Task 7 keeps the raw Go declaration inside the hidden adapter only', async () => {
  const [headerFiles, sourceFiles] = await Promise.all([
    readTreeFiles(cppIncludeDir),
    readTreeFiles(cppSourceDir)
  ]);
  const allFiles = [...headerFiles, ...sourceFiles];
  const fileBodies = await Promise.all(allFiles.map(async (filePath) => ({
    filePath,
    body: await fs.readFile(filePath, 'utf8')
  })));

  const rawVersionHits = fileBodies
    .filter(({ body }) => body.includes(rawVersionSymbol))
    .map(({ filePath }) => path.basename(filePath));
  assert.deepEqual(
    rawVersionHits,
    [backendSourceName],
    `Expected raw Go symbol to appear only in ${backendSourceName}, found ${rawVersionHits.join(', ')}`
  );

  const internalMacroHits = fileBodies
    .filter(({ body }) => body.includes('CMFA_INTERNAL_BACKEND_API'))
    .map(({ filePath }) => path.basename(filePath));
  assert.deepEqual(
    internalMacroHits,
    [backendSourceName],
    `Expected CMFA_INTERNAL_BACKEND_API only in ${backendSourceName}, found ${internalMacroHits.join(', ')}`
  );

  for (const { filePath, body } of fileBodies) {
    assert.doesNotMatch(body, /\bdlopen\b/u, `${path.basename(filePath)} must not use dlopen`);
    assert.doesNotMatch(body, /\bdlsym\b/u, `${path.basename(filePath)} must not use dlsym`);
    assert.doesNotMatch(body, /\blibdl(?:\.so)?\b/u, `${path.basename(filePath)} must not mention libdl`);
  }
});

test('Task 7 host runner accepts only explicit native cases', async () => {
  const [runnerModule, runnerSource] = await Promise.all([
    import(new URL('../../tools/test-native-host.mjs', import.meta.url)),
    fs.readFile(runnerPath, 'utf8')
  ]);

  assert.equal(typeof runnerModule.parseCliArguments, 'function');
  assert.equal(typeof runnerModule.runCli, 'function');
  assert.deepEqual(runnerModule.parseCliArguments([]), { caseName: 'contract' });
  assert.deepEqual(runnerModule.parseCliArguments(['--case', 'contract']), { caseName: 'contract' });
  assert.deepEqual(runnerModule.parseCliArguments(['--case', 'mihomo-backend']), { caseName: 'mihomo-backend' });
  assert.deepEqual(runnerModule.parseCliArguments(['--case', 'napi-environment']), { caseName: 'napi-environment' });

  expectArgumentInvalid(runnerModule.parseCliArguments, ['--case'], 'missing case value should fail');
  expectArgumentInvalid(runnerModule.parseCliArguments, ['--case', 'unknown'], 'unknown case should fail');
  expectArgumentInvalid(runnerModule.parseCliArguments, ['--case', 'contract', 'extra'], 'extra args should fail');
  expectArgumentInvalid(runnerModule.parseCliArguments, ['contract'], 'positional case should fail');
  assert.throws(
    () => runnerModule.parseCliArguments(['--case']),
    (error) => error?.code === 'ARGUMENT_INVALID' && error.message === expectedUsage,
    'usage contract must be an exact five-line string'
  );

  assert.match(runnerSource, new RegExp(mainGuardSnippet.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u'));
});

test('Task 7 environment ownership is host-testable and SDK-opaque', async () => {
  const headerPath = path.join(cppIncludeDir, 'napi_environment.h');
  const header = await fs.readFile(headerPath, 'utf8');

  assert.match(header, /\bclass\s+NapiEnvironmentOwner\s+final\b/u);
  assert.match(header, /\bCleanupResult\s+cleanup\s*\(\s*\)\s*;/u);
  assert.doesNotMatch(header, /\bnapi\/native_api\.h\b/u);
  assert.doesNotMatch(header, /\bnode_api\.h\b/u);
  assert.doesNotMatch(header, /\bace_napi\.h\b/u);
});
