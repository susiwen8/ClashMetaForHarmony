import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const modulePath = new URL('../../tools/lib/toolchain.mjs', import.meta.url);
const preflightModulePath = new URL('../../tools/preflight.mjs', import.meta.url);
const lockPath = new URL('../../toolchain.lock.json', import.meta.url);
const allowlistPath = new URL('../../toolchain.native-allowlist.json', import.meta.url);
const harmonyRoot = path.resolve(new URL('../..', import.meta.url).pathname);
const REAL_INTEGRATED_SDK_ROOT = '/Applications/DevEco-Studio.app/Contents/sdk/default';

const EXPECTED_TARGET = {
  name: 'HarmonyOS 6/API 20/arm64',
  targetSdkVersion: '6.1.0(23)',
  targetApiVersion: 23,
  compatibleSdkVersion: '6.0.0(20)',
  compatibleApiVersion: 20,
  runtimeOS: 'HarmonyOS',
  architecture: 'arm64'
};

const EXPECTED_INSTALLED = {
  devecoVersion: '6.1.0.860',
  sdkVersion: '6.1.0.105',
  sdkApiVersion: 23,
  ndkVersion: '6.1.0.105',
  ndkApiVersion: 23,
  hvigorVersion: '6.23.7',
  ohpmVersion: '6.1.1.830',
  hdcVersion: '6.1.0.105'
};

const EXPECTED_ALLOWLIST = {
  schemaVersion: '1.0.0',
  architecture: 'arm64',
  source: {
    sdkVersion: '6.1.0.105',
    sdkApiVersion: 23
  },
  goProbe: ['libc.so'],
  mihomoCore: ['libc.so'],
  nodeAddon: ['libace_napi.z.so', 'libc.so', 'libcmfa_mihomo.so', 'libhilog_ndk.z.so']
};

test('the integrated HarmonyOS SDK contract matches the checked-in lock and allowlist', async () => {
  const [{ buildNativeAllowlist, buildToolchainLock, inspectToolchain }, lock, allowlist] = await Promise.all([
    import(modulePath),
    fs.readFile(lockPath, 'utf8').then((raw) => JSON.parse(raw)),
    fs.readFile(allowlistPath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  const inspection = await inspectToolchain({ cwd: harmonyRoot });

  assert.equal(inspection.report.result, 'pass');
  assert.equal(inspection.resolved.sdkRoot, REAL_INTEGRATED_SDK_ROOT);
  assert.deepEqual(inspection.report.target, EXPECTED_TARGET);
  assert.deepEqual(inspection.report.installed, EXPECTED_INSTALLED);
  assert.equal(inspection.report.tools.node.version, '22.17.0');
  assert.deepEqual(inspection.report.tools.ohosClang, { found: true, version: null });
  assert.deepEqual(inspection.report.tools.llvmReadelf, { found: true, version: null });
  assert.deepEqual(lock, {
    schemaVersion: '1.0.0',
    target: EXPECTED_TARGET,
    installed: EXPECTED_INSTALLED
  });
  assert.deepEqual(buildToolchainLock(inspection.report), lock);
  assert.deepEqual(allowlist, EXPECTED_ALLOWLIST);
  assert.deepEqual(buildNativeAllowlist(inspection), allowlist);
});

test('buildToolchainLock rejects empty and placeholder fields', async () => {
  const [{ buildToolchainLock }] = await Promise.all([
    import(modulePath)
  ]);

  assert.throws(
    () => buildToolchainLock({
      schemaVersion: '1.0.0',
      target: {
        ...EXPECTED_TARGET,
        runtimeOS: 'unknown'
      },
      installed: EXPECTED_INSTALLED
    }),
    (error) => error?.code === 'TOOLCHAIN_LOCK_INVALID' && /target.runtimeOS/u.test(error.message)
  );

  assert.throws(
    () => buildToolchainLock({
      schemaVersion: '1.0.0',
      target: EXPECTED_TARGET,
      installed: {
        ...EXPECTED_INSTALLED,
        hdcVersion: ' '
      }
    }),
    (error) => error?.code === 'TOOLCHAIN_LOCK_INVALID' && /installed.hdcVersion/u.test(error.message)
  );
});

test('the integrated SDK exposes declarations and executable native tools', async () => {
  const [{ inspectToolchain }] = await Promise.all([
    import(modulePath)
  ]);

  const inspection = await inspectToolchain({ cwd: harmonyRoot });
  const requiredExecutablePaths = [
    inspection.resolved.paths.clang,
    inspection.resolved.paths.llvmReadelf,
    inspection.resolved.paths.hdc
  ];

  assert.ok(inspection.resolved.arktsDeclarations.length > 0);
  assert.ok(inspection.resolved.arktsDeclarations.some((entry) => entry.endsWith('.d.ts') || entry.endsWith('.d.ets')));
  assert.equal(inspection.resolved.paths.sysroot.endsWith('/openharmony/native/sysroot'), true);
  assert.equal(inspection.resolved.paths.cmake.endsWith('/openharmony/native/build/cmake/ohos.toolchain.cmake'), true);

  for (const executablePath of requiredExecutablePaths) {
    const stats = await fs.stat(executablePath);
    assert.ok((stats.mode & 0o111) !== 0, `${executablePath} is not executable`);
  }
});

test('the integrated SDK declarations expose the API 20 to API 23 network and request surfaces used by Task 8', async () => {
  const [networkKit, requestApi, httpApi] = await Promise.all([
    fs.readFile(path.join(REAL_INTEGRATED_SDK_ROOT, 'openharmony', 'ets', 'kits', '@kit.NetworkKit.d.ts'), 'utf8'),
    fs.readFile(path.join(REAL_INTEGRATED_SDK_ROOT, 'openharmony', 'ets', 'api', '@ohos.request.d.ts'), 'utf8'),
    fs.readFile(path.join(REAL_INTEGRATED_SDK_ROOT, 'openharmony', 'ets', 'api', '@ohos.net.http.d.ts'), 'utf8')
  ]);

  assert.match(networkKit, /import http from '@ohos\.net\.http';/u);
  assert.match(networkKit, /export \{[^}]*http[^}]*\};/u);
  assert.match(httpApi, /maxRedirects\?: number;/u);
  assert.match(httpApi, /connectTimeout\?: number;/u);
  assert.match(httpApi, /readTimeout\?: number;/u);
  assert.match(httpApi, /maxLimit\?: number;/u);
  assert.match(httpApi, /usingCache\?: boolean;/u);
  assert.match(requestApi, /namespace agent \{/u);
  assert.match(requestApi, /interface Config \{/u);
  assert.match(requestApi, /redirect\?: boolean;/u);
  assert.match(requestApi, /on\(event: 'progress', callback: \(progress: Progress\) => void\): void;/u);
  assert.match(requestApi, /on\(event: 'response', callback: Callback<HttpResponse>\): void;/u);
  assert.match(requestApi, /on\(event: 'faultOccur', callback: Callback<Faults>\): void;/u);
  assert.match(requestApi, /function create\(context: BaseContext, config: Config\): Promise<Task>;/u);
  assert.match(requestApi, /delete\(\): Promise<boolean>;/u);
  assert.match(requestApi, /readonly statusCode: number;/u);
  assert.match(requestApi, /readonly headers: Map<string, Array<string>>;/u);
  assert.match(requestApi, /readonly processed: number;/u);
  assert.match(requestApi, /readonly sizes: Array<number>;/u);
});

test('preflight fallback report normalizes the node version', async () => {
  const source = await fs.readFile(preflightModulePath, 'utf8');
  const tempModulePath = path.join(os.tmpdir(), `preflight-fallback-${Date.now()}.mjs`);

  await fs.writeFile(
    tempModulePath,
    source
      .replace(
        /import \{[^}]+\} from '\.\/lib\/toolchain\.mjs';/u,
        `import { discoverToolchain, normalizeNodeVersion, resolveRepoRootFromImportMetaUrl } from '${new URL('../../tools/lib/toolchain.mjs', import.meta.url).href}';`
      )
      .replace(
        /main\(\)\.catch\(async \(error\) => \{\n  await writeReport\(createFallbackReport\(error\)\);\n  process\.exitCode = 2;\n\}\);\n/u,
        'export { createFallbackReport };\n'
      ),
    'utf8'
  );

  try {
    const { createFallbackReport } = await import(`${pathToFileURL(tempModulePath).href}?t=${Date.now()}`);
    const report = createFallbackReport({ code: 'BOOM' });

    assert.equal(report.tools.node.version, '22.17.0');
  } finally {
    await fs.rm(tempModulePath, { force: true });
  }
});
