import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const fixturePath = new URL('../fixtures/toolchain-complete.json', import.meta.url);
const modulePath = new URL('../../tools/lib/toolchain.mjs', import.meta.url);

function createMemoryFs(fileMap) {
  const normalized = new Map(Object.entries(fileMap).map(([filePath, value]) => [path.posix.normalize(filePath), value]));

  return {
    async readFile(filePath, encoding = 'utf8') {
      const key = path.posix.normalize(filePath);
      if (!normalized.has(key)) {
        const error = new Error(`ENOENT: no such file or directory, open '${filePath}'`);
        error.code = 'ENOENT';
        throw error;
      }

      const value = normalized.get(key);
      if (Buffer.isBuffer(value)) {
        return encoding ? value.toString(encoding) : value;
      }

      return encoding ? String(value) : Buffer.from(String(value));
    },
    async access(filePath) {
      const key = path.posix.normalize(filePath);
      if (!normalized.has(key)) {
        const error = new Error(`ENOENT: no such file or directory, access '${filePath}'`);
        error.code = 'ENOENT';
        throw error;
      }
    },
    async realpath(filePath) {
      return path.posix.normalize(filePath);
    }
  };
}

function createProbeFromFixture(fixture) {
  return {
    cwd: fixture.probe.cwd,
    env: { ...fixture.probe.env },
    requirements: structuredClone(fixture.requirements),
    versions: { ...fixture.probe.versions },
    fs: createMemoryFs(fixture.probe.files),
    execFile(command, args) {
      const key = `${command} ${args.join(' ')}`.trim();
      const result = fixture.probe.commandResults?.[key];
      if (!result) {
        return Promise.resolve({ stdout: '', stderr: '' });
      }

      return Promise.resolve({
        stdout: result.stdout ?? '',
        stderr: result.stderr ?? ''
      });
    }
  };
}

test('discoverToolchain returns a sanitized pass report for the canonical complete fixture', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.schemaVersion, '1.0.0');
  assert.equal(report.result, 'pass');
  assert.deepEqual(report.failures, []);
  assert.deepEqual(report.target, {
    platform: 'HarmonyOS',
    apiVersion: 20,
    sdkVersion: 'HarmonyOS 6.0.0',
    ndkFound: true
  });
  assert.deepEqual(report.tools, {
    node: { found: true, version: 'v22.17.0' },
    java: { found: true, version: '17.0.14' },
    hvigor: { found: true, version: '5.0.1' },
    ohpm: { found: true, version: '5.0.3' },
    hdc: { found: true, version: 'Ver: 3.1.0a' },
    ohosClang: { found: true, version: '20' },
    llvmReadelf: { found: true, version: '20' }
  });

  const persisted = JSON.stringify(report);
  assert.doesNotMatch(persisted, /fixture-user/);
  assert.doesNotMatch(persisted, /\/Users\/fixture-user/);
  assert.doesNotMatch(persisted, /Secrets\/Huawei\/Sdk/);
});

test('discoverToolchain reports a stable TOOL_MISSING failure when a required host tool is absent', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  delete fixture.probe.files['/fixture/bin/hdc'];

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.equal(report.failures.length, 1);
  assert.deepEqual(report.failures[0], {
    code: 'TOOL_MISSING',
    detail: 'hdc'
  });
  assert.equal(report.tools.hdc.found, false);
  assert.equal(report.tools.hdc.version, null);
});

test('discoverToolchain reports API20_MISSING when the fixture resolves the wrong API version', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  fixture.requirements.target.apiVersion = 21;

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.match(JSON.stringify(report.failures), /API20_MISSING/);
});

test('discoverToolchain reports NDK_MISSING when the fixture loses the native sysroot', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  delete fixture.probe.files['/Users/fixture-user/Library/Secrets/Huawei/Sdk/openharmony/20/native/sysroot/usr/lib/aarch64-linux-ohos/libc++.so'];

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.match(JSON.stringify(report.failures), /NDK_MISSING/);
  assert.equal(report.target.ndkFound, false);
});

test('discoverToolchain reports TOOL_VERSION_MISSING when a required tool has no usable version', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  fixture.probe.versions.java = '   ';

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.match(JSON.stringify(report.failures), /TOOL_VERSION_MISSING/);
  assert.deepEqual(report.failures.find((entry) => entry.code === 'TOOL_VERSION_MISSING'), {
    code: 'TOOL_VERSION_MISSING',
    detail: 'java'
  });
  assert.equal(report.tools.java.found, true);
  assert.equal(report.tools.java.version, null);
});

test('discoverToolchain parses hvigor, ohpm, and hdc versions from command output without explicit probe versions', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  delete fixture.probe.versions.hvigor;
  delete fixture.probe.versions.ohpm;
  delete fixture.probe.versions.hdc;

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'pass');
  assert.deepEqual(report.tools.hvigor, { found: true, version: '5.0.1' });
  assert.deepEqual(report.tools.ohpm, { found: true, version: '5.0.3' });
  assert.deepEqual(report.tools.hdc, { found: true, version: 'Ver: 3.1.0a' });
});

test('discoverToolchain parses Windows-escaped sdk.dir values from local.properties', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  delete fixture.probe.env.DEVECO_SDK_HOME;
  delete fixture.probe.env.HARMONY_SDK_HOME;
  fixture.probe.files['/workspace/repo/harmony/local.properties'] = 'sdk.dir=C\\:\\\\Users\\\\name\\\\Sdk\n';
  fixture.probe.files['C:\\Users\\name\\Sdk/openharmony/20/toolchains/ets/oh-uni-package.json'] = '{"apiVersion":"20","sdkVersion":"HarmonyOS 6.0.0"}\n';
  fixture.probe.files['C:\\Users\\name\\Sdk/openharmony/20/toolchains/arkts/tsconfig/ohos-global.d.ets'] = '';
  fixture.probe.files['C:\\Users\\name\\Sdk/openharmony/20/native/build/cmake/ohos.toolchain.cmake'] = '';
  fixture.probe.files['C:\\Users\\name\\Sdk/openharmony/20/native/sysroot/usr/lib/aarch64-linux-ohos/libc++.so'] = '';
  fixture.probe.files['C:\\Users\\name\\Sdk/openharmony/20/native/llvm/bin/aarch64-linux-ohos-clang'] = '';
  fixture.probe.files['C:\\Users\\name\\Sdk/openharmony/20/native/llvm/bin/llvm-readelf'] = '';
  delete fixture.probe.files['/Users/fixture-user/Library/Secrets/Huawei/Sdk/openharmony/20/toolchains/ets/oh-uni-package.json'];
  delete fixture.probe.files['/Users/fixture-user/Library/Secrets/Huawei/Sdk/openharmony/20/toolchains/arkts/tsconfig/ohos-global.d.ets'];
  delete fixture.probe.files['/Users/fixture-user/Library/Secrets/Huawei/Sdk/openharmony/20/native/build/cmake/ohos.toolchain.cmake'];
  delete fixture.probe.files['/Users/fixture-user/Library/Secrets/Huawei/Sdk/openharmony/20/native/sysroot/usr/lib/aarch64-linux-ohos/libc++.so'];
  delete fixture.probe.files['/Users/fixture-user/Library/Secrets/Huawei/Sdk/openharmony/20/native/llvm/bin/aarch64-linux-ohos-clang'];
  delete fixture.probe.files['/Users/fixture-user/Library/Secrets/Huawei/Sdk/openharmony/20/native/llvm/bin/llvm-readelf'];

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'pass');
  assert.equal(report.target.sdkVersion, 'HarmonyOS 6.0.0');
  assert.equal(report.target.ndkFound, true);
});

test('resolveRepoRootFromImportMetaUrl converts file URLs with spaces and Windows drives', async () => {
  const { resolveRepoRootFromImportMetaUrl } = await import(modulePath);

  assert.equal(
    resolveRepoRootFromImportMetaUrl('file:///Users/test/My%20Repo/harmony/tools/preflight.mjs'),
    '/Users/test/My Repo'
  );
  assert.equal(
    resolveRepoRootFromImportMetaUrl('file:///C:/Users/name/My%20Repo/harmony/tools/preflight.mjs', {
      fileURLToPathImpl: () => 'C:\\Users\\name\\My Repo',
      pathModule: path.win32
    }),
    'C:\\Users\\name\\My Repo'
  );
});

test('discoverToolchain stays hermetic when caller provides complete requirements', async () => {
  const [source, fixture] = await Promise.all([
    fs.readFile(modulePath, 'utf8'),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);
  const tempModulePath = path.join(os.tmpdir(), `toolchain-hermetic-${Date.now()}.mjs`);

  await fs.writeFile(
    tempModulePath,
    source.replace(
      /const DEFAULT_REQUIREMENTS_PATH = .*;/u,
      "const DEFAULT_REQUIREMENTS_PATH = '/definitely/missing/toolchain.requirements.json';"
    ),
    'utf8'
  );

  try {
    const { discoverToolchain } = await import(`${pathToFileURL(tempModulePath).href}?t=${Date.now()}`);
    const report = await discoverToolchain(createProbeFromFixture(fixture));

    assert.equal(report.result, 'pass');
  } finally {
    await fs.rm(tempModulePath, { force: true });
  }
});
