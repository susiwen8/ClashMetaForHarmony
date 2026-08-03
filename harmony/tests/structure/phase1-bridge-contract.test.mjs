import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';

const harmonyRoot = path.resolve(new URL('../..', import.meta.url).pathname);
const cppIncludeDir = path.join(harmonyRoot, 'entry', 'src', 'main', 'cpp', 'include');
const cppSourceDir = path.join(harmonyRoot, 'entry', 'src', 'main', 'cpp', 'src');
const runnerPath = path.join(harmonyRoot, 'tools', 'test-native-host.mjs');
const buildProfilePath = path.join(harmonyRoot, 'entry', 'build-profile.json5');
const entryPackagePath = path.join(harmonyRoot, 'entry', 'oh-package.json5');
const typesRoot = path.join(cppSourceDir, '..', 'types', 'libentry');
const dtsPath = path.join(typesRoot, 'Index.d.ts');
const typesPackagePath = path.join(typesRoot, 'oh-package.json5');
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
const typedSourceNames = [
  'addon_init.cpp',
  'js_async.cpp',
  'js_codec.cpp',
  'js_core_module.cpp',
  'js_errors.cpp',
  'js_events.cpp'
];
const typedValueExports = [
  'hello',
  'coreVersion',
  'validateConfiguration',
  'loadConfiguration',
  'startLocal',
  'stopRuntime',
  'runtimeSnapshot',
  'subscribe',
  'unsubscribe'
];
const typedTypeExports = [
  'RuntimeState',
  'LogLevel',
  'LocalOptions',
  'RuntimeSnapshot',
  'CoreEvent',
  'CoreErrorContext',
  'CoreError'
];

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

function parseJson5Object(raw) {
  return Function(`"use strict"; return (${raw});`)();
}

function parseExportNames(body, pattern) {
  return [...body.matchAll(pattern)].map((match) => match[1]).sort();
}

function createSpawnStub(outputsByFlag) {
  return function spawnStub(command, args) {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.stdout.setEncoding = () => {};
    child.stderr.setEncoding = () => {};
    child.kill = () => {};

    queueMicrotask(() => {
      const flag = args[0];
      const payload = outputsByFlag[flag];
      if (!payload) {
        child.stderr.emit('data', `missing stub output for ${flag}`);
        child.emit('close', 1, null);
        return;
      }
      child.stdout.emit('data', payload.stdout ?? '');
      child.stderr.emit('data', payload.stderr ?? '');
      child.emit('close', payload.exitCode ?? 0, null);
    });

    return child;
  };
}

async function withTempAllowlist(testFn) {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase1-node-addon-'));
  const libPath = path.join(tempRoot, 'libentry.so');
  const allowlistPath = path.join(tempRoot, 'allowlist.json');
  await fs.writeFile(libPath, 'fake-elf', 'utf8');
  await fs.writeFile(allowlistPath, JSON.stringify({
    schemaVersion: '1.0.0',
    nodeAddon: ['libace_napi.z.so', 'libc.so', 'libcmfa_mihomo.so', 'libhilog_ndk.z.so']
  }), 'utf8');

  try {
    return await testFn({ libPath, allowlistPath });
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
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

test('Task 7 typed facade files, exports, and source contracts are present', async () => {
  const [inspectModule, dtsBody, maybeHeader, buildProfileRaw, entryPackageRaw, typesPackageRaw] = await Promise.all([
    import('../bin/inspect-native-lib.mjs', { with: { type: 'module' } }).catch(() => import('../bin/inspect-native-lib.mjs')),
    fs.readFile(dtsPath, 'utf8'),
    fs.readFile(path.join(cppIncludeDir, 'cmfa_napi.h'), 'utf8'),
    fs.readFile(buildProfilePath, 'utf8'),
    fs.readFile(entryPackagePath, 'utf8'),
    fs.readFile(typesPackagePath, 'utf8')
  ]);

  const valueExports = parseExportNames(dtsBody, /^export declare function (\w+)\s*\(/gmu);
  const typeExports = parseExportNames(dtsBody, /^export (?:type|interface) (\w+)\b/gmu);
  const classExports = parseExportNames(dtsBody, /^export declare class (\w+)\b/gmu);
  assert.deepEqual(valueExports, [...typedValueExports].sort(), 'typed facade must expose exactly the documented nine value exports');
  assert.deepEqual(typeExports, [...typedTypeExports].sort(), 'typed facade must expose exactly the documented type exports');
  assert.deepEqual(classExports, [], 'typed facade must not add extra runtime class exports');
  assert.match(dtsBody, /type RuntimeState = 'STOPPED' \| 'STARTING' \| 'RUNNING' \| 'STOPPING' \| 'ERROR';/u);
  assert.match(dtsBody, /type LogLevel = 'DEBUG' \| 'INFO' \| 'WARN' \| 'ERROR';/u);
  assert.match(dtsBody, /interface CoreError extends Error/u);

  assert.match(maybeHeader, /#include <napi\/native_api\.h>/u);
  assert.match(maybeHeader, /\bstruct AddonState\b/u);
  assert.doesNotMatch(maybeHeader, /\bcmfa_internal_register_backend\b/u);

  const sourceBodies = await Promise.all(typedSourceNames.map(async (fileName) => ({
    fileName,
    body: await fs.readFile(path.join(cppSourceDir, fileName), 'utf8')
  })));
  assert.equal(typeof inspectModule.inspectNativeLibrary, 'function');
  assert.match(sourceBodies.find(({ fileName }) => fileName === 'js_async.cpp').body, /\bstd::thread\b/u);
  assert.match(sourceBodies.find(({ fileName }) => fileName === 'js_async.cpp').body, /\bnapi_create_threadsafe_function\b/u);
  assert.match(sourceBodies.find(({ fileName }) => fileName === 'js_events.cpp').body, /\bnapi_create_reference\b/u);
  assert.match(sourceBodies.find(({ fileName }) => fileName === 'js_events.cpp').body, /\bnapi_call_threadsafe_function\b/u);
  assert.match(sourceBodies.find(({ fileName }) => fileName === 'addon_init.cpp').body, /\bnapi_add_env_cleanup_hook\b/u);
  assert.match(sourceBodies.find(({ fileName }) => fileName === 'addon_init.cpp').body, /\bNAPI_MODULE\s*\(\s*libentry\s*,\s*Init\s*\)/u);
  for (const { fileName, body } of sourceBodies) {
    assert.doesNotMatch(body, /\bdlopen\b/u, `${fileName} must not use dlopen`);
    assert.doesNotMatch(body, /\bdlsym\b/u, `${fileName} must not use dlsym`);
    assert.doesNotMatch(body, /\blibdl(?:\.so)?\b/u, `${fileName} must not mention libdl`);
  }

  const buildProfile = parseJson5Object(buildProfileRaw);
  const entryPackage = parseJson5Object(entryPackageRaw);
  const typesPackage = parseJson5Object(typesPackageRaw);
  assert.deepEqual(buildProfile.buildOption.resOptions.copyCodeResource, { enable: false });
  assert.deepEqual(buildProfile.buildOption.externalNativeOptions, {
    path: './src/main/cpp/CMakeLists.txt',
    arguments: '',
    cppFlags: '',
    abiFilters: ['arm64-v8a'],
    targets: ['entry']
  });
  assert.equal(buildProfile.buildOptionSet.find((item) => item.name === 'debug')?.nativeLib?.debugSymbol?.strip, false);
  assert.deepEqual(entryPackage.dependencies, {
    'libentry.so': 'file:./src/main/cpp/types/libentry'
  });
  assert.deepEqual(typesPackage, {
    name: 'libentry.so',
    version: '1.0.0',
    types: './Index.d.ts'
  });
});

test('Task 7 nodeAddon inspector enforces exact dependency and export contracts', async () => {
  const { inspectNativeLibrary } = await import('../bin/inspect-native-lib.mjs');
  const toolchainInspectorImpl = async () => ({
    report: { result: 'pass' },
    resolved: {
      paths: {
        llvmReadelf: '/sdk/llvm-readelf'
      }
    }
  });

  await withTempAllowlist(async ({ libPath, allowlistPath }) => {
    const validResult = await inspectNativeLibrary({
      libPath,
      allowlistPath,
      toolchainInspectorImpl,
      spawnImpl: createSpawnStub({
        '-h': { stdout: 'Machine: AArch64\n' },
        '-d': {
          stdout: [
            'Shared library: [libace_napi.z.so]',
            'Shared library: [libc.so]',
            'Shared library: [libcmfa_mihomo.so]',
            'Shared library: [libhilog_ndk.z.so]'
          ].join('\n')
        },
        '-sW': {
          stdout: [
            '1: 00000000     0 FUNC    GLOBAL DEFAULT   10 napi_register_module_v1'
          ].join('\n')
        }
      })
    });
    assert.equal(validResult.component, 'nodeAddon');
    assert.equal(validResult.result, 'pass');

    const failureCases = [
      {
        name: 'missing allowlisted dependency fails',
        outputsByFlag: {
          '-h': { stdout: 'Machine: AArch64\n' },
          '-d': {
            stdout: [
              'Shared library: [libace_napi.z.so]',
              'Shared library: [libc.so]',
              'Shared library: [libcmfa_mihomo.so]'
            ].join('\n')
          },
          '-sW': { stdout: '1: 00000000     0 FUNC    GLOBAL DEFAULT   10 napi_register_module_v1\n' }
        },
        expectedCode: 'DT_NEEDED_SET_MISMATCH'
      },
      {
        name: 'extra dependency fails',
        outputsByFlag: {
          '-h': { stdout: 'Machine: AArch64\n' },
          '-d': {
            stdout: [
              'Shared library: [libace_napi.z.so]',
              'Shared library: [libc.so]',
              'Shared library: [libcmfa_mihomo.so]',
              'Shared library: [libhilog_ndk.z.so]',
              'Shared library: [libextra.so]'
            ].join('\n')
          },
          '-sW': { stdout: '1: 00000000     0 FUNC    GLOBAL DEFAULT   10 napi_register_module_v1\n' }
        },
        expectedCode: 'DT_NEEDED_NOT_ALLOWLISTED'
      },
      {
        name: 'libdl fails',
        outputsByFlag: {
          '-h': { stdout: 'Machine: AArch64\n' },
          '-d': {
            stdout: [
              'Shared library: [libace_napi.z.so]',
              'Shared library: [libc.so]',
              'Shared library: [libcmfa_mihomo.so]',
              'Shared library: [libhilog_ndk.z.so]',
              'Shared library: [libdl.so]'
            ].join('\n')
          },
          '-sW': { stdout: '1: 00000000     0 FUNC    GLOBAL DEFAULT   10 napi_register_module_v1\n' }
        },
        expectedCode: 'LIBDL_FORBIDDEN'
      },
      {
        name: 'libc++ shared fails',
        outputsByFlag: {
          '-h': { stdout: 'Machine: AArch64\n' },
          '-d': {
            stdout: [
              'Shared library: [libace_napi.z.so]',
              'Shared library: [libc.so]',
              'Shared library: [libcmfa_mihomo.so]',
              'Shared library: [libhilog_ndk.z.so]',
              'Shared library: [libc++_shared.so]'
            ].join('\n')
          },
          '-sW': { stdout: '1: 00000000     0 FUNC    GLOBAL DEFAULT   10 napi_register_module_v1\n' }
        },
        expectedCode: 'LIBCXX_SHARED_FORBIDDEN'
      },
      {
        name: 'public cmfa export fails',
        outputsByFlag: {
          '-h': { stdout: 'Machine: AArch64\n' },
          '-d': {
            stdout: [
              'Shared library: [libace_napi.z.so]',
              'Shared library: [libc.so]',
              'Shared library: [libcmfa_mihomo.so]',
              'Shared library: [libhilog_ndk.z.so]'
            ].join('\n')
          },
          '-sW': {
            stdout: [
              '1: 00000000     0 FUNC    GLOBAL DEFAULT   10 napi_register_module_v1',
              '2: 00000000     0 FUNC    GLOBAL DEFAULT   10 cmfa_runtime_state'
            ].join('\n')
          }
        },
        expectedCode: 'PUBLIC_CMFA_EXPORT_FORBIDDEN'
      },
      {
        name: 'backend registration symbol fails',
        outputsByFlag: {
          '-h': { stdout: 'Machine: AArch64\n' },
          '-d': {
            stdout: [
              'Shared library: [libace_napi.z.so]',
              'Shared library: [libc.so]',
              'Shared library: [libcmfa_mihomo.so]',
              'Shared library: [libhilog_ndk.z.so]'
            ].join('\n')
          },
          '-sW': {
            stdout: [
              '1: 00000000     0 FUNC    GLOBAL DEFAULT   10 napi_register_module_v1',
              '2: 00000000     0 FUNC    GLOBAL DEFAULT   10 _ZN4cmfa24register_mihomo_backendEP10cmfa_error'
            ].join('\n')
          }
        },
        expectedCode: 'BACKEND_REGISTER_SYMBOL_FORBIDDEN'
      },
      {
        name: 'internal register backend symbol fails',
        outputsByFlag: {
          '-h': { stdout: 'Machine: AArch64\n' },
          '-d': {
            stdout: [
              'Shared library: [libace_napi.z.so]',
              'Shared library: [libc.so]',
              'Shared library: [libcmfa_mihomo.so]',
              'Shared library: [libhilog_ndk.z.so]'
            ].join('\n')
          },
          '-sW': {
            stdout: [
              '1: 00000000     0 FUNC    GLOBAL DEFAULT   10 napi_register_module_v1',
              '2: 00000000     0 FUNC    GLOBAL DEFAULT   10 cmfa_internal_register_backend'
            ].join('\n')
          }
        },
        expectedCode: 'INTERNAL_SYMBOL_FORBIDDEN'
      },
      {
        name: 'test sentinel export fails',
        outputsByFlag: {
          '-h': { stdout: 'Machine: AArch64\n' },
          '-d': {
            stdout: [
              'Shared library: [libace_napi.z.so]',
              'Shared library: [libc.so]',
              'Shared library: [libcmfa_mihomo.so]',
              'Shared library: [libhilog_ndk.z.so]'
            ].join('\n')
          },
          '-sW': {
            stdout: [
              '1: 00000000     0 FUNC    GLOBAL DEFAULT   10 napi_register_module_v1',
              '2: 00000000     0 FUNC    GLOBAL DEFAULT   10 test_fake_stub_export'
            ].join('\n')
          }
        },
        expectedCode: 'EXPORT_SENTINEL_FORBIDDEN'
      }
    ];

    for (const failureCase of failureCases) {
      const result = await inspectNativeLibrary({
        libPath,
        allowlistPath,
        toolchainInspectorImpl,
        spawnImpl: createSpawnStub(failureCase.outputsByFlag)
      });
      assert.equal(result.result, 'fail', failureCase.name);
      assert.ok(
        result.failures.some((entry) => entry.code === failureCase.expectedCode),
        `${failureCase.name}: expected ${failureCase.expectedCode}, saw ${JSON.stringify(result.failures)}`
      );
    }
  });
});
