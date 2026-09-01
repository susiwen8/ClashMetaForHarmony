import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const fixturePath = new URL('../fixtures/toolchain-complete.json', import.meta.url);
const modulePath = new URL('../../tools/lib/toolchain.mjs', import.meta.url);
const FIXTURE_SDK_ROOT = '/fixture/DevEco-Studio.app/Contents/sdk/default';
const FIXTURE_CONTENTS_ROOT = '/fixture/DevEco-Studio.app/Contents';
const WINDOWS_SDK_ROOT = 'C:\\Users\\name\\Sdk';
const FIXTURE_NATIVE_CMAKE = `${FIXTURE_SDK_ROOT}/openharmony/native/build-tools/cmake/bin/cmake`;

function normalizeKey(filePath) {
  return path.posix.normalize(filePath);
}

function createMemoryFs(fileMap, executableFiles = [], directories = []) {
  const normalized = new Map(Object.entries(fileMap).map(([filePath, value]) => [normalizeKey(filePath), value]));
  const executableSet = new Set(executableFiles.map((filePath) => normalizeKey(filePath)));
  const directorySet = new Set(directories.map((dirPath) => normalizeKey(dirPath)));

  function hasChildren(dirPath) {
    const prefix = `${normalizeKey(dirPath).replace(/\/$/u, '')}/`;
    for (const key of [...normalized.keys(), ...directorySet]) {
      if (key.startsWith(prefix)) {
        return true;
      }
    }

    return false;
  }

  function ensurePath(filePath, operation) {
    const key = normalizeKey(filePath);
    if (normalized.has(key) || directorySet.has(key) || hasChildren(key)) {
      return key;
    }

    const error = new Error(`ENOENT: no such file or directory, ${operation} '${filePath}'`);
    error.code = 'ENOENT';
    throw error;
  }

  return {
    async readFile(filePath, encoding = 'utf8') {
      const key = ensurePath(filePath, 'open');
      if (!normalized.has(key)) {
        const error = new Error(`EISDIR: illegal operation on a directory, read '${filePath}'`);
        error.code = 'EISDIR';
        throw error;
      }

      const value = normalized.get(key);
      if (Buffer.isBuffer(value)) {
        return encoding ? value.toString(encoding) : value;
      }

      return encoding ? String(value) : Buffer.from(String(value));
    },
    async access(filePath) {
      ensurePath(filePath, 'access');
    },
    async realpath(filePath) {
      return normalizeKey(filePath);
    },
    async stat(filePath) {
      const key = ensurePath(filePath, 'stat');
      const isDirectory = directorySet.has(key) || (!normalized.has(key) && hasChildren(key));
      const mode = isDirectory ? 0o040755 : (executableSet.has(key) ? 0o100755 : 0o100644);
      return {
        mode,
        isFile() {
          return !isDirectory;
        },
        isDirectory() {
          return isDirectory;
        }
      };
    },
    async readdir(dirPath) {
      const key = normalizeKey(dirPath);
      if (!directorySet.has(key) && !hasChildren(key)) {
        const error = new Error(`ENOENT: no such file or directory, scandir '${dirPath}'`);
        error.code = 'ENOENT';
        throw error;
      }

      const prefix = `${key.replace(/\/$/u, '')}/`;
      const entries = new Set();

      for (const item of [...normalized.keys(), ...directorySet]) {
        if (!item.startsWith(prefix)) {
          continue;
        }

        const remainder = item.slice(prefix.length);
        if (!remainder) {
          continue;
        }

        entries.add(remainder.split('/')[0]);
      }

      return [...entries].sort();
    }
  };
}

function createProbeFromFixture(fixture) {
  const cloned = structuredClone(fixture);
  cloned.requirements.files.nativeCmakeBinary ??= 'openharmony/native/build-tools/cmake/bin/cmake';
  if (!cloned.probe.omitNativeCmakeBinary) {
    cloned.probe.files[FIXTURE_NATIVE_CMAKE] ??= '';
  }
  if (!cloned.probe.omitNativeCmakeExecutable && !cloned.probe.executableFiles.includes(FIXTURE_NATIVE_CMAKE)) {
    cloned.probe.executableFiles.push(FIXTURE_NATIVE_CMAKE);
  }

  return {
    cwd: cloned.probe.cwd,
    env: { ...cloned.probe.env },
    requirements: structuredClone(cloned.requirements),
    versions: { ...cloned.probe.versions },
    fs: createMemoryFs(cloned.probe.files, cloned.probe.executableFiles, cloned.probe.directories),
    execFile(command, args) {
      const key = `${command} ${args.join(' ')}`.trim();
      const result = cloned.probe.commandResults?.[key];
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

test('discoverToolchain returns a sanitized pass report for the integrated SDK fixture', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.schemaVersion, '1.0.0');
  assert.equal(report.result, 'pass');
  assert.deepEqual(report.failures, []);
  assert.deepEqual(report.target, {
    name: 'HarmonyOS 6/API 20/arm64',
    targetSdkVersion: '6.1.1(24)',
    targetApiVersion: 24,
    compatibleSdkVersion: '6.0.0(20)',
    compatibleApiVersion: 20,
    runtimeOS: 'HarmonyOS',
    architecture: 'arm64'
  });
  assert.deepEqual(report.installed, {
    devecoVersion: '6.1.1.300',
    sdkVersion: '6.1.1.125',
    sdkApiVersion: 24,
    ndkVersion: '6.1.1.125',
    ndkApiVersion: 24,
    hvigorVersion: '6.24.4',
    ohpmVersion: '6.1.2.285',
    hdcVersion: '6.1.1.125'
  });
  assert.equal(report.tools.node.found, true);
  assert.equal(report.tools.node.version, '22.17.0');
  assert.equal(report.tools.java.found, true);
  assert.equal(report.tools.java.version, '17.0.18');
  assert.deepEqual(report.tools.arktsDeclarations, {
    found: true,
    count: 2,
    sample: '@ohos.app.ability.UIAbility.d.ts'
  });
  assert.deepEqual(report.tools.ohosClang, { found: true, version: null });
  assert.deepEqual(report.tools.llvmReadelf, { found: true, version: null });

  const persisted = JSON.stringify(report);
  assert.doesNotMatch(persisted, /\/fixture\/DevEco-Studio\.app/u);
});

test('discoverToolchain reports TOOL_MISSING when the integrated hdc binary is absent', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/toolchains/hdc`];
  fixture.probe.executableFiles = fixture.probe.executableFiles.filter((entry) => entry !== `${FIXTURE_SDK_ROOT}/openharmony/toolchains/hdc`);

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.deepEqual(report.failures.find((entry) => entry.code === 'TOOL_MISSING'), {
    code: 'TOOL_MISSING',
    detail: 'hdc'
  });
  assert.equal(report.tools.hdc.found, false);
});

test('discoverToolchain reports SDK_METADATA_MISSING when integrated metadata is absent', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/sdk-pkg.json`];

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.deepEqual(report.failures.find((entry) => entry.code === 'SDK_METADATA_MISSING'), {
    code: 'SDK_METADATA_MISSING',
    detail: 'sdk-pkg.json'
  });
});

test('discoverToolchain reports SDK_METADATA_MISSING when sdk-pkg.json is malformed JSON', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  fixture.probe.files[`${FIXTURE_SDK_ROOT}/sdk-pkg.json`] = '{ definitely-not-json }\n';

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.deepEqual(report.failures.find((entry) => entry.code === 'SDK_METADATA_MISSING'), {
    code: 'SDK_METADATA_MISSING',
    detail: 'sdk-pkg.json'
  });
});

test('discoverToolchain reports SDK_METADATA_MISSING when integrated SDK apiVersion is not 24', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  fixture.probe.files[`${FIXTURE_SDK_ROOT}/sdk-pkg.json`] = '{"apiVersion":"23","version":"6.1.1.125","platformVersion":"6.1.1","stage":"Release"}\n';

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.deepEqual(report.failures.find((entry) => entry.code === 'SDK_METADATA_MISSING'), {
    code: 'SDK_METADATA_MISSING',
    detail: 'sdk-pkg.json'
  });
});

test('discoverToolchain accepts top-level sdk-pkg metadata when data nesting is absent', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  fixture.probe.files[`${FIXTURE_SDK_ROOT}/sdk-pkg.json`] = '{"apiVersion":"24","version":"6.1.1.125","platformVersion":"6.1.1","stage":"Release"}\n';

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'pass');
  assert.equal(report.installed.sdkVersion, '6.1.1.125');
  assert.equal(report.installed.sdkApiVersion, 24);
});

test('discoverToolchain reports ARKTS_DECLARATIONS_MISSING when declaration files disappear', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/ets/api/@ohos.app.ability.UIAbility.d.ts`];
  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/ets/api/@ohos.hilog.d.ts`];

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.match(JSON.stringify(report.failures), /ARKTS_DECLARATIONS_MISSING/u);
});

test('discoverToolchain reports NDK_MISSING when the sysroot directory disappears', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  fixture.probe.directories = fixture.probe.directories.filter((entry) => !entry.startsWith(`${FIXTURE_SDK_ROOT}/openharmony/native/sysroot`));
  for (const key of Object.keys(fixture.probe.files)) {
    if (key.startsWith(`${FIXTURE_SDK_ROOT}/openharmony/native/sysroot/`)) {
      delete fixture.probe.files[key];
    }
  }

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.match(JSON.stringify(report.failures), /NDK_MISSING/u);
});

test('discoverToolchain reports TOOL_VERSION_MISSING when java has no usable version', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  fixture.probe.versions.java = '   ';

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.deepEqual(report.failures.find((entry) => entry.code === 'TOOL_VERSION_MISSING'), {
    code: 'TOOL_VERSION_MISSING',
    detail: 'java'
  });
  assert.equal(report.tools.java.version, null);
});

test('discoverToolchain prefers integrated metadata for hvigor, ohpm, and hdc versions', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.deepEqual(report.tools.hvigor, { found: true, version: '6.24.4' });
  assert.deepEqual(report.tools.ohpm, { found: true, version: '6.1.2.285' });
  assert.deepEqual(report.tools.hdc, { found: true, version: '6.1.1.125' });
});

test('discoverToolchain prefers the integrated hvigor binary over a PATH hvigor lookalike', async () => {
  const [{ inspectToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  fixture.probe.files['/fixture/bin/hvigor'] = '';
  fixture.probe.executableFiles.push('/fixture/bin/hvigor');
  fixture.probe.commandResults['/fixture/bin/hvigor --version'] = {
    stdout: '9.9.9\n',
    stderr: ''
  };

  const inspection = await inspectToolchain(createProbeFromFixture(fixture));

  assert.equal(inspection.report.result, 'pass');
  assert.equal(inspection.resolved.paths.hvigor, `${FIXTURE_CONTENTS_ROOT}/tools/hvigor/bin/hvigorw`);
  assert.deepEqual(inspection.report.tools.hvigor, { found: true, version: '6.24.4' });
});

test('discoverToolchain does not borrow integrated hvigor metadata for a PATH-only hvigor binary', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  delete fixture.probe.files[`${FIXTURE_CONTENTS_ROOT}/tools/hvigor/bin/hvigorw`];
  fixture.probe.executableFiles = fixture.probe.executableFiles.filter((entry) => entry !== `${FIXTURE_CONTENTS_ROOT}/tools/hvigor/bin/hvigorw`);
  fixture.probe.files['/fixture/bin/hvigor'] = '';
  fixture.probe.executableFiles.push('/fixture/bin/hvigor');

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.deepEqual(report.tools.hvigor, { found: true, version: null });
  assert.deepEqual(report.failures.find((entry) => entry.code === 'TOOL_VERSION_MISSING' && entry.detail === 'hvigor'), {
    code: 'TOOL_VERSION_MISSING',
    detail: 'hvigor'
  });
});

test('discoverToolchain normalizes a leading v only for the node version', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  fixture.probe.versions.node = 'v20.5.1';

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.tools.node.version, '20.5.1');
  assert.equal(report.tools.java.version, '17.0.18');
  assert.equal(report.tools.hdc.version, '6.1.1.125');
});

test('discoverToolchain parses Windows-escaped sdk.dir values from local.properties without mixing default DevEco contents', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  delete fixture.probe.env.DEVECO_SDK_HOME;
  fixture.probe.files['/workspace/repo/harmony/local.properties'] = 'sdk.dir=C\\:\\\\Users\\\\name\\\\Sdk\n';
  fixture.probe.files[`${WINDOWS_SDK_ROOT}/sdk-pkg.json`] = fixture.probe.files[`${FIXTURE_SDK_ROOT}/sdk-pkg.json`];
  fixture.probe.files[`${WINDOWS_SDK_ROOT}/openharmony/ets/oh-uni-package.json`] = fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/ets/oh-uni-package.json`];
  fixture.probe.files[`${WINDOWS_SDK_ROOT}/openharmony/native/oh-uni-package.json`] = fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/native/oh-uni-package.json`];
  fixture.probe.files[`${WINDOWS_SDK_ROOT}/openharmony/toolchains/oh-uni-package.json`] = fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/toolchains/oh-uni-package.json`];
  fixture.probe.files[`${WINDOWS_SDK_ROOT}/openharmony/ets/api/@ohos.app.ability.UIAbility.d.ts`] = fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/ets/api/@ohos.app.ability.UIAbility.d.ts`];
  fixture.probe.files[`${WINDOWS_SDK_ROOT}/openharmony/native/build/cmake/ohos.toolchain.cmake`] = fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/native/build/cmake/ohos.toolchain.cmake`];
  fixture.probe.files[`${WINDOWS_SDK_ROOT}/openharmony/native/sysroot/usr/lib/aarch64-linux-ohos/libc.so`] = '';
  fixture.probe.files[`${WINDOWS_SDK_ROOT}/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang`] = '';
  fixture.probe.files[`${WINDOWS_SDK_ROOT}/openharmony/native/llvm/bin/llvm-readelf`] = '';
  fixture.probe.files[`${WINDOWS_SDK_ROOT}/openharmony/toolchains/hdc`] = '';
  fixture.probe.directories.push(
    `${WINDOWS_SDK_ROOT}/openharmony/native/sysroot`,
    `${WINDOWS_SDK_ROOT}/openharmony/native/sysroot/usr`,
    `${WINDOWS_SDK_ROOT}/openharmony/native/sysroot/usr/lib`,
    `${WINDOWS_SDK_ROOT}/openharmony/native/sysroot/usr/lib/aarch64-linux-ohos`,
    `${WINDOWS_SDK_ROOT}/openharmony/ets/api`
  );
  fixture.probe.executableFiles.push(
    `${WINDOWS_SDK_ROOT}/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang`,
    `${WINDOWS_SDK_ROOT}/openharmony/native/llvm/bin/llvm-readelf`,
    `${WINDOWS_SDK_ROOT}/openharmony/toolchains/hdc`
  );
  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/sdk-pkg.json`];
  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/ets/oh-uni-package.json`];
  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/native/oh-uni-package.json`];
  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/toolchains/oh-uni-package.json`];
  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/ets/api/@ohos.app.ability.UIAbility.d.ts`];
  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/ets/api/@ohos.hilog.d.ts`];
  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/native/build/cmake/ohos.toolchain.cmake`];
  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/native/sysroot/usr/lib/aarch64-linux-ohos/libc.so`];
  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang`];
  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/native/llvm/bin/llvm-readelf`];
  delete fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/toolchains/hdc`];

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.deepEqual(report.failures.find((entry) => entry.code === 'TOOL_VERSION_MISSING'), {
    code: 'TOOL_VERSION_MISSING',
    detail: 'deveco'
  });
  assert.equal(report.installed.devecoVersion, null);
  assert.equal(report.installed.hvigorVersion, null);
  assert.equal(report.installed.ohpmVersion, null);
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

test('inspectToolchain exposes the integrated native cmake executable only through runtime resolved paths', async () => {
  const [{ inspectToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  fixture.requirements.files.nativeCmakeBinary = 'openharmony/native/build-tools/cmake/bin/cmake';
  fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/native/build-tools/cmake/bin/cmake`] = '';
  fixture.probe.executableFiles.push(`${FIXTURE_SDK_ROOT}/openharmony/native/build-tools/cmake/bin/cmake`);

  const inspection = await inspectToolchain(createProbeFromFixture(fixture));

  assert.equal(inspection.report.result, 'pass');
  assert.deepEqual(inspection.report.tools.nativeCmake, { found: true, version: null });
  assert.equal(
    inspection.resolved.paths.cmakeExecutable,
    `${FIXTURE_SDK_ROOT}/openharmony/native/build-tools/cmake/bin/cmake`
  );
  assert.equal(
    inspection.resolved.paths.cmake,
    `${FIXTURE_SDK_ROOT}/openharmony/native/build/cmake/ohos.toolchain.cmake`
  );

  const persisted = JSON.stringify(inspection.report);
  assert.doesNotMatch(persisted, /build-tools\/cmake\/bin\/cmake/u);
});

test('discoverToolchain reports TOOL_MISSING when the integrated native cmake executable is absent', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  fixture.requirements.files.nativeCmakeBinary = 'openharmony/native/build-tools/cmake/bin/cmake';
  fixture.probe.omitNativeCmakeBinary = true;
  fixture.probe.omitNativeCmakeExecutable = true;

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.deepEqual(report.tools.nativeCmake, { found: false, version: null });
  assert.deepEqual(report.failures.find((entry) => entry.code === 'TOOL_MISSING' && entry.detail === 'nativeCmake'), {
    code: 'TOOL_MISSING',
    detail: 'nativeCmake'
  });
});

test('discoverToolchain reports TOOL_MISSING when the integrated native cmake executable is not executable', async () => {
  const [{ discoverToolchain }, fixture] = await Promise.all([
    import(modulePath),
    fs.readFile(fixturePath, 'utf8').then((raw) => JSON.parse(raw))
  ]);

  fixture.requirements.files.nativeCmakeBinary = 'openharmony/native/build-tools/cmake/bin/cmake';
  fixture.probe.files[`${FIXTURE_SDK_ROOT}/openharmony/native/build-tools/cmake/bin/cmake`] = '';
  fixture.probe.omitNativeCmakeExecutable = true;

  const report = await discoverToolchain(createProbeFromFixture(fixture));

  assert.equal(report.result, 'incomplete');
  assert.deepEqual(report.tools.nativeCmake, { found: false, version: null });
  assert.deepEqual(report.failures.find((entry) => entry.code === 'TOOL_MISSING' && entry.detail === 'nativeCmake'), {
    code: 'TOOL_MISSING',
    detail: 'nativeCmake'
  });
});
