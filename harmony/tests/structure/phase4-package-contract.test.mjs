import assert from 'node:assert/strict';
import { execFile as execFileCallback } from 'node:child_process';
import crypto from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import {
  CORE_EXPORTS,
  NODE_ADDON_ALLOWED_EXPORTS,
  RAW_PROXY_DELAY_EXPORTS,
  RAW_PROXY_EXPORTS
} from '../../tools/lib/native-provenance.mjs';

const modulePath = new URL('../bin/inspect-phase4-packages.mjs', import.meta.url);
const inspectNativeLibModulePath = new URL('../bin/inspect-native-lib.mjs', import.meta.url);
const execFile = promisify(execFileCallback);
const HARMONY_ROOT = path.resolve(new URL('../..', import.meta.url).pathname);
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const PROBE_ADDON_ENTRY = 'libs/arm64-v8a/libprobeentry.so';
const PROBE_ADDON_ALLOWED_NEEDED = ['libace_napi.z.so', 'libc.so'];
const PROBE_ADDON_ALLOWED_EXPORTS = ['_fini', '_init'];
const FAKE_TOOLCHAIN_READELF_PATH = path.join(HARMONY_ROOT, 'artifacts', 'fake-llvm-readelf');

function assertNoSensitiveLeak(value, sentinel, label) {
  assert.equal(value.includes(sentinel), false, `${label} must not leak sentinel path fragments`);
  assert.equal(value.includes(process.cwd()), false, `${label} must not leak cwd`);
  assert.equal(value.includes(os.userInfo().username), false, `${label} must not leak username`);
  assert.equal(/ENOENT|EACCES|no such file|stack/i.test(value), false, `${label} must not leak raw fs errors or stack text`);
}

function digest(seed) {
  return crypto.createHash('sha256').update(seed).digest('hex');
}

function createProbeAddonElfReport(overrides = {}) {
  return {
    schemaVersion: '1.0.0',
    result: 'pass',
    component: 'probeAddon',
    libPath: PROBE_ADDON_ENTRY,
    readelfPath: 'artifacts/fake-llvm-readelf',
    architecture: 'AArch64',
    neededLibraries: [...PROBE_ADDON_ALLOWED_NEEDED],
    allowedNeededLibraries: [...PROBE_ADDON_ALLOWED_NEEDED],
    exportedSymbols: [...PROBE_ADDON_ALLOWED_EXPORTS],
    requiredExports: [],
    rawVersion: null,
    buildInfo: null,
    failures: [],
    ...overrides
  };
}

function createReadelfSpawn({
  neededLibraries = PROBE_ADDON_ALLOWED_NEEDED,
  exportedSymbols = PROBE_ADDON_ALLOWED_EXPORTS,
  relocationLines = '',
  exitCode = 0
} = {}) {
  return (_command, args) => {
    const firstArg = args[0];
    const stdoutText = firstArg === '-h'
      ? 'ELF Header:\n  Machine:                           AArch64\n'
      : firstArg === '-d'
        ? neededLibraries
          .map((entry) => `0x0000000000000001 (NEEDED)             Shared library: [${entry}]`)
          .join('\n')
        : firstArg === '--dyn-syms'
          ? exportedSymbols
            .map((entry, index) => `    ${index + 1}: 0000000000000000     0 FUNC    GLOBAL DEFAULT   12 ${entry}`)
            .join('\n')
          : relocationLines;

    return {
      stdout: {
        setEncoding() {},
        on(event, handler) {
          if (event === 'data' && stdoutText.length > 0) {
            setImmediate(() => handler(stdoutText));
          }
        }
      },
      stderr: {
        setEncoding() {},
        on() {}
      },
      on(event, handler) {
        if (event === 'close') {
          setImmediate(() => handler(exitCode, null));
        }
      },
      kill() {}
    };
  };
}

function createPackagedModuleInfo({
  bundleName,
  requestPermissions,
  extensionType = 'vpn',
  duplicateEntry = false,
  duplicateExtension = false
}) {
  const abilities = [{ name: 'EntryAbility' }];
  const extension = {
    name: 'CmfaVpnExtensionAbility',
    type: extensionType
  };
  const extensionAbilities = [extension];
  if (duplicateEntry) {
    abilities.push({ name: 'EntryAbility' });
  }
  if (duplicateExtension) {
    extensionAbilities.push({ ...extension });
  }
  return {
    bundleName,
    requestPermissions,
    abilities,
    extensionAbilities
  };
}

function createHappyInspectorDependencies() {
  const isProbe = (hapPath) => hapPath.includes('traffic-probe');
  const safeArchiveEntries = new Map([
    ['ets/sourceMaps.map', Buffer.from('no obsolete bridge markers here', 'utf8')],
    ['ets/modules.abc', Buffer.from('compiled module without obsolete bridge markers', 'utf8')]
  ]);
  return {
    loadProductionManifestImpl: async () => ({
      artifacts: {
        hap: { identity: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap' }
      },
      signing: { result: 'pass' },
      nativeBuildResult: 'pass'
    }),
    listArchiveEntriesImpl: async (hapPath) => {
      if (!isProbe(hapPath)) {
        return [
          'module.json',
          'pack.info',
          'libs/arm64-v8a/libentry.so',
          'libs/arm64-v8a/libcmfa_mihomo.so',
          'ets/sourceMaps.map',
          'ets/modules.abc',
          'META-INF/CERT.SF'
        ];
      }
      return ['module.json', 'pack.info', PROBE_ADDON_ENTRY, 'pages/ProbePage.abc', 'META-INF/CERT.SF'];
    },
    hashFileImpl: async (hapPath) => ({
      sha256: digest(hapPath),
      sizeBytes: 1024
    }),
    readModuleJsonImpl: async (hapPath) => ({
      ...createPackagedModuleInfo({
        bundleName: !isProbe(hapPath)
          ? 'com.github.kr328.clash.harmony'
          : 'com.cmfa.phase4.trafficprobe',
        requestPermissions: !isProbe(hapPath)
          ? ['ohos.permission.INTERNET', 'ohos.permission.KEEP_BACKGROUND_RUNNING']
          : ['ohos.permission.INTERNET']
      })
    }),
    readSignatureImpl: async (hapPath) => ({
      signatureSha256: digest(`${hapPath}:signature`)
    }),
    readArchiveEntryImpl: async (_hapPath, entryPath) => safeArchiveEntries.get(entryPath) ?? Buffer.from('', 'utf8'),
    verifySignatureImpl: async (options) => ({
      signatureSha256: digest(`${options.hapPath}:verified-signature`)
    }),
    inspectNativeImpl: async ({ hapPath, role, component, nativeEntryPath }) => !isProbe(hapPath)
      ? {
        addon: { exportedSymbols: NODE_ADDON_ALLOWED_EXPORTS },
        core: { exportedSymbols: CORE_EXPORTS }
      }
      : {
        role,
        component,
        nativeEntryPath,
        probeAddon: createProbeAddonElfReport()
      }
  };
}

test('phase4 package inspector requires exact production/probe bundle separation and native payload boundaries', async () => {
  const inspector = await import(modulePath);
  const result = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...createHappyInspectorDependencies()
  });

  assert.equal(result.result, 'pass');
  assert.equal(result.production.bundleName, 'com.github.kr328.clash.harmony');
  assert.equal(result.probe.bundleName, 'com.cmfa.phase4.trafficprobe');
  assert.notEqual(result.production.hapSha256, result.probe.hapSha256);
  assert.notEqual(result.production.signatureSha256, result.probe.signatureSha256);
  assert.deepEqual(result.production.permissions, ['ohos.permission.INTERNET', 'ohos.permission.KEEP_BACKGROUND_RUNNING']);
  assert.deepEqual(result.probe.permissions, ['ohos.permission.INTERNET']);
  assert.equal(result.production.stubDetected, false);
  assert.equal(result.probe.hasNativePayload, true);
  assert.equal(result.probeEmbeddedInProduction, false);
  assert.equal(result.failures.length, 0);
});

test('phase4 package inspector fail-closes when production HAP embeds probe-only native, type, or project entries', async () => {
  const inspector = await import(modulePath);

  for (const contaminatedEntry of [
    'libs/arm64-v8a/libprobeentry.so',
    'types/libprobeentry/Index.d.ts',
    'traffic-probe/entry/src/main/ets/probe/DirectTrafficProbe.ets'
  ]) {
    const dependencies = createHappyInspectorDependencies();
    dependencies.listArchiveEntriesImpl = async (hapPath) => {
      if (!hapPath.includes('traffic-probe')) {
        return [
          'module.json',
          'pack.info',
          'libs/arm64-v8a/libentry.so',
          'libs/arm64-v8a/libcmfa_mihomo.so',
          contaminatedEntry,
          'ets/sourceMaps.map',
          'ets/modules.abc',
          'META-INF/CERT.SF'
        ];
      }
      return ['module.json', 'pack.info', PROBE_ADDON_ENTRY, 'pages/ProbePage.abc', 'META-INF/CERT.SF'];
    };

    const result = await inspector.inspectPhase4Packages({
      productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
      productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
      probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
      ...dependencies
    });

    assert.equal(result.result, 'fail', contaminatedEntry);
    assert.ok(
      result.failures.some((failure) => failure.code === 'PROBE_EMBEDDED_IN_PRODUCTION'),
      contaminatedEntry
    );
  }
});

test('phase4 package inspector requires explicit probeAddon component for the exact probe addon path', async () => {
  const inspector = await import(modulePath);
  let probeInvocation = null;
  const dependencies = createHappyInspectorDependencies();
  dependencies.inspectNativeImpl = async ({ hapPath, role, component, nativeEntryPath }) => {
    if (!hapPath.includes('traffic-probe')) {
      return {
        addon: { exportedSymbols: NODE_ADDON_ALLOWED_EXPORTS },
        core: { exportedSymbols: CORE_EXPORTS }
      };
    }

    probeInvocation = { role, component, nativeEntryPath };
    return {
      probeAddon: createProbeAddonElfReport()
    };
  };

  const result = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...dependencies
  });

  assert.deepEqual(probeInvocation, {
    role: 'probe',
    component: 'probeAddon',
    nativeEntryPath: PROBE_ADDON_ENTRY
  });
  assert.equal(result.result, 'pass');
  assert.equal(result.probe.hasNativePayload, true);
});

test('phase4 package inspector keeps probe native payload visibility when probeAddon inspection fails', async () => {
  const inspector = await import(modulePath);
  const dependencies = createHappyInspectorDependencies();
  dependencies.inspectNativeImpl = async ({ hapPath }) => !hapPath.includes('traffic-probe')
    ? {
      addon: { exportedSymbols: NODE_ADDON_ALLOWED_EXPORTS },
      core: { exportedSymbols: CORE_EXPORTS }
    }
    : {
      probeAddon: createProbeAddonElfReport({
        result: 'fail',
        exportedSymbols: [...PROBE_ADDON_ALLOWED_EXPORTS, 'cmfa_host_emit_runtime_event_bridge_v1'],
        failures: [
          {
            code: 'HOST_BRIDGE_EXPORT_FORBIDDEN',
            detail: 'Probe addon must not export host bridge symbols.'
          }
        ]
      })
    };

  const result = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...dependencies
  });

  assert.equal(result.result, 'fail');
  assert.equal(result.probe.hasNativePayload, true);
  assert.ok(result.failures.some((failure) => failure.code === 'HOST_BRIDGE_EXPORT_FORBIDDEN'));
});

test('phase4 package inspector keeps probe native payload visibility when probe native inspection throws', async () => {
  const inspector = await import(modulePath);
  const dependencies = createHappyInspectorDependencies();
  const sentinel = `phase4-probe-native-throw-${process.pid}-${os.userInfo().username}`;
  dependencies.inspectNativeImpl = async ({ hapPath, role }) => {
    if (!hapPath.includes('traffic-probe')) {
      return {
        addon: { exportedSymbols: NODE_ADDON_ALLOWED_EXPORTS },
        core: { exportedSymbols: CORE_EXPORTS }
      };
    }

    assert.equal(role, 'probe');
    throw Object.assign(
      new Error(`ENOENT: native probe inspector failed for /tmp/${sentinel}/libprobeentry.so`),
      { code: 'ENOENT' }
    );
  };

  const result = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...dependencies
  });

  assert.equal(result.result, 'fail');
  assert.equal(result.probe.hasNativePayload, true);
  assert.ok(result.failures.some((failure) => failure.code === 'PROBE_NATIVE_INSPECTION_FAILED'));
  assert.equal(result.failures.some((failure) => failure.code === 'PROBE_PACKAGE_UNREADABLE'), false);
  assertNoSensitiveLeak(JSON.stringify(result), sentinel, 'serialized probe native throw report');
});

test('inspect-native-lib requires an explicit probeAddon component and uses a separate probe addon allowlist', async () => {
  const [{ inspectNativeLibrary }] = await Promise.all([
    import(inspectNativeLibModulePath)
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase4-probe-addon-'));
  const allowlistPath = path.join(tempRoot, 'toolchain.native-allowlist.json');
  const probeLibPath = path.join(tempRoot, 'libprobeentry.so');

  await fs.writeFile(allowlistPath, JSON.stringify({
    schemaVersion: '1.0.0',
    architecture: 'arm64',
    source: {
      sdkVersion: '6.1.1.125',
      sdkApiVersion: 24
    },
    goProbe: ['libc.so'],
    mihomoCore: ['libc.so'],
    nodeAddon: ['libace_napi.z.so', 'libc.so', 'libcmfa_mihomo.so', 'libhilog_ndk.z.so'],
    probeAddon: PROBE_ADDON_ALLOWED_NEEDED
  }), 'utf8');
  await fs.writeFile(probeLibPath, 'probe-addon-binary', 'utf8');

  try {
    await assert.rejects(
      () => inspectNativeLibrary({
        libPath: probeLibPath,
        allowlistPath,
        toolchainInspectorImpl: async () => ({
          report: { result: 'pass' },
          resolved: { paths: { llvmReadelf: FAKE_TOOLCHAIN_READELF_PATH } }
        }),
        spawnImpl: createReadelfSpawn()
      }),
      (error) => error?.code === 'COMPONENT_REQUIRED'
    );

    const pass = await inspectNativeLibrary({
      libPath: probeLibPath,
      component: 'probeAddon',
      allowlistPath,
      toolchainInspectorImpl: async () => ({
        report: { result: 'pass' },
        resolved: { paths: { llvmReadelf: FAKE_TOOLCHAIN_READELF_PATH } }
      }),
      spawnImpl: createReadelfSpawn()
    });
    assert.equal(pass.result, 'pass');
    assert.deepEqual(pass.neededLibraries, PROBE_ADDON_ALLOWED_NEEDED);
    assert.deepEqual(pass.exportedSymbols, PROBE_ADDON_ALLOWED_EXPORTS);

    const fail = await inspectNativeLibrary({
      libPath: probeLibPath,
      component: 'probeAddon',
      allowlistPath,
      toolchainInspectorImpl: async () => ({
        report: { result: 'pass' },
        resolved: { paths: { llvmReadelf: FAKE_TOOLCHAIN_READELF_PATH } }
      }),
      fsApi: {
        ...fs,
        readFile: async (targetPath, encoding) => {
          if (targetPath === probeLibPath) {
            return Buffer.from('probe-addon-binary\0dlsym', 'latin1');
          }
          return await fs.readFile(targetPath, encoding);
        }
      },
      spawnImpl: createReadelfSpawn({
        neededLibraries: [...PROBE_ADDON_ALLOWED_NEEDED, 'libcmfa_mihomo.so'],
        exportedSymbols: [...PROBE_ADDON_ALLOWED_EXPORTS, 'cmfa_host_emit_runtime_event_bridge_v1']
      })
    });
    assert.equal(fail.result, 'fail');
    assert.ok(fail.failures.some((failure) => failure.code === 'DT_NEEDED_NOT_ALLOWLISTED'));
    assert.ok(fail.failures.some((failure) => failure.code === 'HOST_BRIDGE_EXPORT_FORBIDDEN'));
    assert.ok(fail.failures.some((failure) => failure.code === 'DLOPEN_SENTINEL_FORBIDDEN'));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('phase4 package inspector fail-closes when production archive entries still contain obsolete bridge markers', async () => {
  const inspector = await import(modulePath);
  const markerEntries = ['ets/sourceMaps.map', 'ets/modules.abc'];
  const markers = [
    'NativeVpnRuntimeBridge',
    'VpnRuntimeBridgeModels',
    'claimVpnRuntimeBridgeSession',
    'publishVpnRuntimeBridgeSnapshotIfOwned',
    'readVpnRuntimeBridgeSnapshot',
    'clearVpnRuntimeBridgeSnapshotIfOwned'
  ];

  for (const entryPath of markerEntries) {
    for (const marker of markers) {
      const dependencies = createHappyInspectorDependencies();
      dependencies.readArchiveEntryImpl = async (_hapPath, candidatePath) => {
        if (candidatePath === entryPath) {
          return Buffer.from(`prefix ${marker} suffix`, 'utf8');
        }
        return Buffer.from('safe-bytes', 'utf8');
      };

      const result = await inspector.inspectPhase4Packages({
        productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
        productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
        probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
        ...dependencies
      });

      assert.equal(result.result, 'fail', `${entryPath} ${marker}`);
      assert.ok(result.failures.some((failure) => failure.code === 'PRODUCTION_BRIDGE_MARKERS_FORBIDDEN'), `${entryPath} ${marker}`);
      assert.doesNotMatch(JSON.stringify(result.failures), new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u'));
    }
  }
});

test('phase4 package inspector fail-closes when production bridge scan entries are duplicated or unreadable', async () => {
  const inspector = await import(modulePath);

  for (const duplicatedEntry of ['ets/sourceMaps.map', 'ets/modules.abc']) {
    const dependencies = createHappyInspectorDependencies();
    dependencies.listArchiveEntriesImpl = async (hapPath) => {
      const base = await createHappyInspectorDependencies().listArchiveEntriesImpl(hapPath);
      if (hapPath.includes('traffic-probe')) {
        return base;
      }
      return [...base, duplicatedEntry];
    };

    const duplicated = await inspector.inspectPhase4Packages({
      productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
      productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
      probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
      ...dependencies
    });

    assert.equal(duplicated.result, 'fail');
    assert.ok(duplicated.failures.some((failure) => failure.code === 'PRODUCTION_BRIDGE_SCAN_INVALID'));
  }

  const unreadableDependencies = createHappyInspectorDependencies();
  unreadableDependencies.readArchiveEntryImpl = async () => {
    throw new Error('raw archive read failure should stay redacted');
  };

  const unreadable = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...unreadableDependencies
  });

  assert.equal(unreadable.result, 'fail');
  assert.ok(unreadable.failures.some((failure) => failure.code === 'PRODUCTION_BRIDGE_SCAN_INVALID'));
  assert.doesNotMatch(JSON.stringify(unreadable.failures), /raw archive read failure/u);
});

test('phase4 package inspector requires exactly one production modules archive while treating source maps as optional', async () => {
  const inspector = await import(modulePath);

  const missingModulesDependencies = createHappyInspectorDependencies();
  missingModulesDependencies.listArchiveEntriesImpl = async (hapPath) => {
    const base = await createHappyInspectorDependencies().listArchiveEntriesImpl(hapPath);
    if (hapPath.includes('traffic-probe')) {
      return base;
    }
    return base.filter((entry) => entry !== 'ets/modules.abc' && entry !== 'ets/sourceMaps.map');
  };

  const missingModules = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...missingModulesDependencies
  });

  assert.equal(missingModules.result, 'fail');
  assert.ok(missingModules.failures.some((failure) => failure.code === 'PRODUCTION_BRIDGE_SCAN_INVALID'));

  const optionalSourceMapsDependencies = createHappyInspectorDependencies();
  optionalSourceMapsDependencies.listArchiveEntriesImpl = async (hapPath) => {
    const base = await createHappyInspectorDependencies().listArchiveEntriesImpl(hapPath);
    if (hapPath.includes('traffic-probe')) {
      return base;
    }
    return base.filter((entry) => entry !== 'ets/sourceMaps.map');
  };

  const optionalSourceMaps = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...optionalSourceMapsDependencies
  });

  assert.equal(optionalSourceMaps.result, 'pass');
  assert.equal(optionalSourceMaps.failures.length, 0);
});

test('phase4 package inspector keeps generic production vpn ability boundaries without co-location requirements', async () => {
  const inspector = await import(modulePath);

  const cases = [
    {
      name: 'wrong extension type',
      moduleInfo: createPackagedModuleInfo({
        bundleName: 'com.github.kr328.clash.harmony',
        requestPermissions: ['ohos.permission.INTERNET', 'ohos.permission.KEEP_BACKGROUND_RUNNING'],
        extensionType: 'service'
      }),
      code: 'PRODUCTION_VPN_EXTENSION_TYPE_INVALID'
    },
    {
      name: 'duplicate entry ability',
      moduleInfo: createPackagedModuleInfo({
        bundleName: 'com.github.kr328.clash.harmony',
        requestPermissions: ['ohos.permission.INTERNET', 'ohos.permission.KEEP_BACKGROUND_RUNNING'],
        duplicateEntry: true
      }),
      code: 'PRODUCTION_ENTRY_ABILITY_COUNT_INVALID'
    },
    {
      name: 'duplicate vpn extension ability',
      moduleInfo: createPackagedModuleInfo({
        bundleName: 'com.github.kr328.clash.harmony',
        requestPermissions: ['ohos.permission.INTERNET', 'ohos.permission.KEEP_BACKGROUND_RUNNING'],
        duplicateExtension: true
      }),
      code: 'PRODUCTION_VPN_EXTENSION_COUNT_INVALID'
    }
  ];

  for (const testCase of cases) {
    const dependencies = createHappyInspectorDependencies();
    dependencies.readModuleJsonImpl = async (hapPath) => {
      if (hapPath.includes('traffic-probe')) {
        return createPackagedModuleInfo({
          bundleName: 'com.cmfa.phase4.trafficprobe',
          requestPermissions: ['ohos.permission.INTERNET']
        });
      }
      return testCase.moduleInfo;
    };

    const result = await inspector.inspectPhase4Packages({
      productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
      productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
      probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
      ...dependencies
    });

    assert.equal(result.result, 'fail', testCase.name);
    assert.match(result.failures.map((entry) => entry.code).join(','), new RegExp(testCase.code, 'u'), testCase.name);
  }
});

test('phase4 package inspector compares the exact public core ABI without rejecting compiler-internal ELF symbols', async () => {
  const inspector = await import(modulePath);
  const dependencies = createHappyInspectorDependencies();
  dependencies.inspectNativeImpl = async ({ hapPath, role, component, nativeEntryPath }) => !hapPath.includes('traffic-probe')
    ? {
      addon: { exportedSymbols: NODE_ADDON_ALLOWED_EXPORTS },
      core: { exportedSymbols: [...CORE_EXPORTS, '_init', '_cgo_internal_helper', 'crosscall2'] }
    }
    : {
      role,
      component,
      nativeEntryPath,
      probeAddon: createProbeAddonElfReport()
    };

  const result = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...dependencies
  });

  assert.equal(result.result, 'pass');
  assert.deepEqual(result.failures, []);
});

test('phase4 package inspector requires the canonical four-symbol nodeAddon bridge contract', async () => {
  const inspector = await import(modulePath);
  const dependencies = createHappyInspectorDependencies();
  dependencies.inspectNativeImpl = async ({ role }) => role === 'production'
    ? {
      addon: { exportedSymbols: ['JNI_OnLoad'] },
      core: { exportedSymbols: CORE_EXPORTS }
    }
    : null;

  const result = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...dependencies
  });

  assert.equal(result.result, 'fail');
  assert.match(result.failures.map((entry) => entry.code).join(','), /PRODUCTION_ADDON_EXPORTS_INVALID/u);
});

test('phase4 package inspector fail-closes when any raw proxy export is missing from the production core authority', async () => {
  const inspector = await import(modulePath);
  const dependencies = createHappyInspectorDependencies();
  dependencies.inspectNativeImpl = async ({ hapPath }) => !hapPath.includes('traffic-probe')
    ? {
      addon: { exportedSymbols: NODE_ADDON_ALLOWED_EXPORTS },
      core: { exportedSymbols: CORE_EXPORTS.filter((entry) => entry !== RAW_PROXY_EXPORTS[0]) }
    }
    : null;

  const result = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...dependencies
  });

  assert.equal(result.result, 'fail');
  assert.match(result.failures.map((entry) => entry.code).join(','), /PRODUCTION_CORE_EXPORTS_INVALID/u);
});

test('phase4 package inspector fail-closes when any raw delay export is missing from the production core authority', async () => {
  const inspector = await import(modulePath);

  for (const missingSymbol of RAW_PROXY_DELAY_EXPORTS) {
    const dependencies = createHappyInspectorDependencies();
    dependencies.inspectNativeImpl = async ({ hapPath }) => !hapPath.includes('traffic-probe')
      ? {
        addon: { exportedSymbols: NODE_ADDON_ALLOWED_EXPORTS },
        core: { exportedSymbols: CORE_EXPORTS.filter((entry) => entry !== missingSymbol) }
      }
      : null;

    const result = await inspector.inspectPhase4Packages({
      productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
      productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
      probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
      ...dependencies
    });

    assert.equal(result.result, 'fail', missingSymbol);
    assert.match(result.failures.map((entry) => entry.code).join(','), /PRODUCTION_CORE_EXPORTS_INVALID/u, missingSymbol);
  }
});

test('phase4 package inspector fail-closes when production core exports add extra public symbols', async () => {
  const inspector = await import(modulePath);
  const dependencies = createHappyInspectorDependencies();
  dependencies.inspectNativeImpl = async ({ hapPath }) => !hapPath.includes('traffic-probe')
    ? {
      addon: { exportedSymbols: NODE_ADDON_ALLOWED_EXPORTS },
      core: { exportedSymbols: [...CORE_EXPORTS, 'cmfa_mihomo_extra_export_v1'] }
    }
    : null;

  const result = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...dependencies
  });

  assert.equal(result.result, 'fail');
  assert.match(result.failures.map((entry) => entry.code).join(','), /PRODUCTION_CORE_EXPORTS_INVALID/u);
});

test('phase4 package inspector fail-closes when production core authority misses non-proxy load validate or tun exports', async () => {
  const inspector = await import(modulePath);

  for (const missingSymbol of [
    'cmfa_mihomo_load_config_v1',
    'cmfa_mihomo_validate_config_v1',
    'cmfa_mihomo_start_tun_v1'
  ]) {
    const dependencies = createHappyInspectorDependencies();
    dependencies.inspectNativeImpl = async ({ hapPath }) => !hapPath.includes('traffic-probe')
      ? {
        addon: { exportedSymbols: NODE_ADDON_ALLOWED_EXPORTS },
        core: { exportedSymbols: CORE_EXPORTS.filter((entry) => entry !== missingSymbol) }
      }
      : null;

    const result = await inspector.inspectPhase4Packages({
      productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
      productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
      probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
      ...dependencies
    });

    assert.equal(result.result, 'fail', missingSymbol);
    assert.match(result.failures.map((entry) => entry.code).join(','), /PRODUCTION_CORE_EXPORTS_INVALID/u, missingSymbol);
  }
});

test('phase4 package inspector treats raw delay exports as part of the exact public authority and rejects extra cmfa delay symbols', async () => {
  const inspector = await import(modulePath);
  const dependencies = createHappyInspectorDependencies();
  dependencies.inspectNativeImpl = async ({ hapPath }) => !hapPath.includes('traffic-probe')
    ? {
      addon: { exportedSymbols: NODE_ADDON_ALLOWED_EXPORTS },
      core: { exportedSymbols: [...CORE_EXPORTS, 'cmfa_mihomo_proxy_delay_debug_v1'] }
    }
    : null;

  const result = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...dependencies
  });

  assert.equal(result.result, 'fail');
  assert.match(result.failures.map((entry) => entry.code).join(','), /PRODUCTION_CORE_EXPORTS_INVALID/u);
});

test('phase4 package inspector fail-closes for unsigned HAP names, missing signatures, and cross-bundle contamination', async () => {
  const inspector = await import(modulePath);
  const noSignature = createHappyInspectorDependencies();
  noSignature.loadProductionManifestImpl = async () => ({
    artifacts: {
      hap: { identity: 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap' }
    },
    signing: { result: 'pass' },
    nativeBuildResult: 'pass'
  });
  noSignature.readSignatureImpl = async () => null;
  const unsigned = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-unsigned.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...noSignature
  });
  assert.equal(unsigned.result, 'fail');
  assert.match(unsigned.failures.map((entry) => entry.code).join(','), /UNSIGNED|SIGNATURE/u);

  const contaminated = createHappyInspectorDependencies();
  contaminated.listArchiveEntriesImpl = async () => ['module.json', 'libs/arm64-v8a/libentry.so', 'META-INF/CERT.SF'];
  contaminated.inspectNativeImpl = async () => ({
    addon: { exportedSymbols: ['JNI_OnLoad'] },
    core: { exportedSymbols: CORE_EXPORTS.filter((entry) => entry !== 'cmfa_mihomo_load_config_v1') }
  });
  const fail = await inspector.inspectPhase4Packages({
    productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
    productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
    probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
    ...contaminated
  });
  assert.equal(fail.result, 'fail');
  assert.deepEqual(
    fail.failures.map((entry) => entry.code),
    [
      'PRODUCTION_BRIDGE_SCAN_INVALID',
      'PRODUCTION_ADDON_EXPORTS_INVALID',
      'PRODUCTION_CORE_EXPORTS_INVALID',
      'PROBE_NATIVE_ENTRY_INVALID',
      'PROBE_NATIVE_INSPECTION_MISSING'
    ]
  );
});

test('phase4 package inspector CLI writes atomic pass/fail JSON reports', async () => {
  const inspector = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase4-package-'));
  const outputPath = path.join(tempRoot, 'phase4-package-inspection.json');
  const report = await inspector.writeInspectionReport({
    outputPath,
    report: {
      schemaVersion: '1.0.0',
      result: 'fail',
      production: { bundleName: 'com.github.kr328.clash.harmony', hapSha256: digest('p'), signatureSha256: digest('ps'), permissions: ['ohos.permission.INTERNET'], stubDetected: false },
      probe: { bundleName: 'com.cmfa.phase4.trafficprobe', hapSha256: digest('q'), signatureSha256: digest('qs'), permissions: ['ohos.permission.INTERNET'], hasNativePayload: false },
      probeEmbeddedInProduction: false,
      failures: [{ code: 'SIGNATURE_MISSING', detail: 'Missing signature block.' }]
    }
  });
  assert.equal(report.result, 'fail');
  assert.deepEqual(JSON.parse(await fs.readFile(outputPath, 'utf8')), report);
});

test('phase4 package inspector real default readers parse module/signature/hash with repo-scoped zip inputs', async () => {
  const inspector = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-package-real-'));
  const hapRoot = path.join(tempRoot, 'production-hap');
  const manifestPath = path.join(tempRoot, 'phase1-native-provenance.json');
  const hapPath = path.join(tempRoot, 'entry-default-signed.hap');
  const probeHapRoot = path.join(tempRoot, 'probe-hap');
  const probeHapPath = path.join(tempRoot, 'probe-default-signed.hap');
  await fs.mkdir(path.join(hapRoot, 'META-INF'), { recursive: true });
  await fs.mkdir(path.join(probeHapRoot, 'META-INF'), { recursive: true });
  await fs.writeFile(path.join(hapRoot, 'module.json'), JSON.stringify({
    bundleName: 'com.github.kr328.clash.harmony',
    requestPermissions: [{ name: 'ohos.permission.INTERNET' }, { name: 'ohos.permission.KEEP_BACKGROUND_RUNNING' }]
  }), 'utf8');
  await fs.writeFile(path.join(hapRoot, 'META-INF', 'CERT.SF'), 'signature-a', 'utf8');
  await fs.writeFile(path.join(probeHapRoot, 'module.json'), JSON.stringify({
    bundleName: 'com.cmfa.phase4.trafficprobe',
    requestPermissions: [{ name: 'ohos.permission.INTERNET' }]
  }), 'utf8');
  await fs.writeFile(path.join(probeHapRoot, 'META-INF', 'CERT.SF'), 'signature-b', 'utf8');
  await fs.writeFile(manifestPath, JSON.stringify({
    artifacts: {
      hap: {
        identity: path.relative(path.resolve(HARMONY_ROOT, '..'), hapPath).split(path.sep).join('/'),
        sha256: digest('manifest-hap')
      }
    },
    signing: { result: 'pass' },
    nativeBuildResult: 'pass',
    phase2SelfTest: { enabled: false, purpose: 'production', releaseStatus: 'releasable' }
  }), 'utf8');
  await execFile('/usr/bin/zip', ['-qr', hapPath, '.'], { cwd: hapRoot });
  await execFile('/usr/bin/zip', ['-qr', probeHapPath, '.'], { cwd: probeHapRoot });

  const result = await inspector.inspectPhase4Packages({
    productionHapPath: hapPath,
    productionManifestPath: manifestPath,
    probeHapPath,
    inspectNativeImpl: async () => ({
      addon: { exportedSymbols: ['JNI_OnLoad'] },
      core: { exportedSymbols: CORE_EXPORTS.filter((entry) => entry !== 'cmfa_mihomo_validate_config_v1') }
    })
  });
  assert.equal(result.production.bundleName, 'com.github.kr328.clash.harmony');
  assert.equal(result.probe.bundleName, 'com.cmfa.phase4.trafficprobe');
  assert.match(result.production.hapSha256, /^[a-f0-9]{64}$/u);
  assert.match(result.production.signatureSha256, /^[a-f0-9]{64}$/u);
});

test('phase4 package inspector reads the HarmonyOS v3 binary signing block', async () => {
  const inspector = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-hap-v3-signature-'));
  const hapRoot = path.join(tempRoot, 'hap');
  const hapPath = path.join(tempRoot, 'entry-default-signed.hap');
  await fs.mkdir(hapRoot, { recursive: true });
  await fs.writeFile(path.join(hapRoot, 'module.json'), '{}', 'utf8');
  await execFile('/usr/bin/zip', ['-qr', hapPath, '.'], { cwd: hapRoot });

  const unsigned = await fs.readFile(hapPath);
  let eocdOffset = -1;
  for (let offset = unsigned.length - 22; offset >= Math.max(0, unsigned.length - 65_557); offset -= 1) {
    if (unsigned.readUInt32LE(offset) === 0x06054b50) {
      eocdOffset = offset;
      break;
    }
  }
  assert.notEqual(eocdOffset, -1);
  const centralDirectoryOffset = unsigned.readUInt32LE(eocdOffset + 16);
  const payload = Buffer.from('phase4-v3-signature-payload', 'utf8');
  const footer = Buffer.alloc(32);
  footer.writeUInt32LE(3, 0);
  footer.writeBigUInt64LE(BigInt(payload.length + footer.length), 4);
  footer.write('<hap sign block>', 12, 'ascii');
  footer.writeUInt32LE(3, 28);
  const signingBlock = Buffer.concat([payload, footer]);
  const signed = Buffer.concat([
    unsigned.subarray(0, centralDirectoryOffset),
    signingBlock,
    unsigned.subarray(centralDirectoryOffset)
  ]);
  signed.writeUInt32LE(centralDirectoryOffset + signingBlock.length, eocdOffset + signingBlock.length + 16);
  await fs.writeFile(hapPath, signed);

  const signature = await inspector.defaultReadSignature(hapPath);
  assert.equal(signature.blockVersion, 3);
  assert.equal(signature.signatureSha256, crypto.createHash('sha256').update(signingBlock).digest('hex'));
});

test('phase4 package inspector real defaults fail closed for repo escape, missing manifest, and missing signatures', async () => {
  const inspector = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-package-fail-'));
  const hapRoot = path.join(tempRoot, 'unsigned-hap');
  const hapPath = path.join(tempRoot, 'entry-default-signed.hap');
  await fs.mkdir(hapRoot, { recursive: true });
  await fs.writeFile(path.join(hapRoot, 'module.json'), JSON.stringify({
    bundleName: 'com.github.kr328.clash.harmony',
    requestPermissions: [{ name: 'ohos.permission.INTERNET' }, { name: 'ohos.permission.KEEP_BACKGROUND_RUNNING' }]
  }), 'utf8');
  await execFile('/usr/bin/zip', ['-qr', hapPath, '.'], { cwd: hapRoot });

  await assert.rejects(
    inspector.inspectPhase4Packages({
      productionHapPath: '/tmp/outside.hap',
      productionManifestPath: path.join(tempRoot, 'missing.json'),
      probeHapPath: hapPath
    }),
    (error) => error?.code === 'PATH_OUTSIDE_REPO' && error?.message === 'Package inspection inputs must stay inside the repository.'
  );

  const manifestPath = path.join(tempRoot, 'phase1-native-provenance.json');
  await fs.writeFile(manifestPath, JSON.stringify({
    artifacts: {
      hap: { identity: path.relative(path.resolve(HARMONY_ROOT, '..'), hapPath).split(path.sep).join('/') }
    },
    signing: { result: 'pass' },
    nativeBuildResult: 'pass',
    phase2SelfTest: { enabled: false, purpose: 'production', releaseStatus: 'releasable' }
  }), 'utf8');
  const result = await inspector.inspectPhase4Packages({
    productionHapPath: hapPath,
    productionManifestPath: manifestPath,
    probeHapPath: hapPath,
    inspectNativeImpl: async () => ({
      addon: { exportedSymbols: ['JNI_OnLoad'] },
      core: { exportedSymbols: CORE_EXPORTS.filter((entry) => entry !== 'cmfa_mihomo_start_tun_v1') }
    })
  });
  assert.equal(result.result, 'fail');
  assert.deepEqual(
    result.failures.map((entry) => entry.code),
    [
      'SIGNATURE_MISSING',
      'SIGNATURE_VERIFY_FAILED',
      'PROBE_BUNDLE_INVALID',
      'HAP_HASH_COLLISION',
      'SIGNATURE_COLLISION',
      'PROBE_PERMISSIONS_INVALID',
      'PRODUCTION_ENTRY_ABILITY_COUNT_INVALID',
      'PRODUCTION_VPN_EXTENSION_COUNT_INVALID',
      'PRODUCTION_BRIDGE_SCAN_INVALID',
      'PRODUCTION_ADDON_EXPORTS_INVALID',
      'PRODUCTION_CORE_EXPORTS_INVALID',
      'PROBE_NATIVE_ENTRY_INVALID',
      'PROBE_NATIVE_INSPECTION_MISSING'
    ]
  );
});

test('phase4 package inspector normalizes unreadable manifest failures without leaking absolute paths', async () => {
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-package-sanitize-'));
  const sentinel = `phase4-sentinel-${process.pid}-${os.userInfo().username}`;
  const manifestPath = path.join(tempRoot, sentinel, 'missing.json');
  const outputPath = path.join(tempRoot, 'report.json');

  const { stderr } = await execFile(
    process.execPath,
    [
      fileURLToPath(modulePath),
      '--production-hap', 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
      '--production-manifest', path.relative(REPO_ROOT, manifestPath),
      '--probe-hap', 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
      '--out', path.relative(REPO_ROOT, outputPath)
    ],
    {
      cwd: REPO_ROOT,
      encoding: 'utf8'
    }
  ).catch((error) => ({
    stderr: `${error.stderr ?? ''}`,
    stdout: `${error.stdout ?? ''}`,
    code: error.code
  }));

  const report = JSON.parse(await fs.readFile(outputPath, 'utf8'));
  assert.equal(report.result, 'fail');
  assert.deepEqual(report.failures, [
    {
      code: 'PRODUCTION_MANIFEST_UNREADABLE',
      detail: 'Production manifest could not be read.'
    }
  ]);
  assertNoSensitiveLeak(JSON.stringify(report), sentinel, 'serialized report');
  assertNoSensitiveLeak(stderr, sentinel, 'stderr');
});

test('phase4 package inspector CLI unknown-flag failures stay fixed, stack-free, and route reports safely', async () => {
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-package-cli-args-'));
  const sentinel = `phase4-cli-args-${process.pid}-${os.userInfo().username}`;
  const safeOut = path.join(HARMONY_ROOT, 'artifacts', `${sentinel}-safe.json`);
  const safeOutAfter = path.join(HARMONY_ROOT, 'artifacts', `${sentinel}-safe-after.json`);
  const defaultOut = path.join(HARMONY_ROOT, 'artifacts', 'phase4-package-inspection.json');
  const unsafeOut = path.join(os.tmpdir(), `${sentinel}-outside.json`);
  const cliPath = fileURLToPath(modulePath);

  const safeFailure = await execFile(
    process.execPath,
    [
      cliPath,
      '--out', path.relative(REPO_ROOT, safeOut),
      '--bad-flag', path.join(REPO_ROOT, sentinel, 'argv')
    ],
    { cwd: REPO_ROOT, encoding: 'utf8' }
  ).catch((error) => ({
    code: error.code,
    stderr: `${error.stderr ?? ''}`,
    stdout: `${error.stdout ?? ''}`
  }));

  assert.notEqual(safeFailure.code, 0);
  const safeReport = JSON.parse(await fs.readFile(safeOut, 'utf8'));
  assert.deepEqual(safeReport.failures, [
    {
      code: 'PACKAGE_ARGUMENT_INVALID',
      detail: 'Package inspection arguments are invalid.'
    }
  ]);
  assertNoSensitiveLeak(JSON.stringify(safeReport), sentinel, 'safe unknown-flag report');
  assertNoSensitiveLeak(safeFailure.stderr, sentinel, 'safe unknown-flag stderr');
  assert.equal(/inspect-phase4-packages\.mjs:\d+/u.test(safeFailure.stderr), false, 'safe unknown-flag stderr must not leak source file lines');
  assert.equal(safeFailure.stderr.includes('--bad-flag'), false, 'safe unknown-flag stderr must not echo raw flag');

  const safeAfterFailure = await execFile(
    process.execPath,
    [
      cliPath,
      '--bad-flag',
      '--out', path.relative(REPO_ROOT, safeOutAfter)
    ],
    { cwd: REPO_ROOT, encoding: 'utf8' }
  ).catch((error) => ({
    code: error.code,
    stderr: `${error.stderr ?? ''}`,
    stdout: `${error.stdout ?? ''}`
  }));

  assert.notEqual(safeAfterFailure.code, 0);
  const safeAfterReport = JSON.parse(await fs.readFile(safeOutAfter, 'utf8'));
  assert.deepEqual(safeAfterReport.failures, [
    {
      code: 'PACKAGE_ARGUMENT_INVALID',
      detail: 'Package inspection arguments are invalid.'
    }
  ]);
  assertNoSensitiveLeak(JSON.stringify(safeAfterReport), sentinel, 'safe-after unknown-flag report');
  assertNoSensitiveLeak(safeAfterFailure.stderr, sentinel, 'safe-after unknown-flag stderr');
  assert.equal(/inspect-phase4-packages\.mjs:\d+/u.test(safeAfterFailure.stderr), false, 'safe-after unknown-flag stderr must not leak source file lines');
  assert.equal(safeAfterFailure.stderr.includes('--bad-flag'), false, 'safe-after unknown-flag stderr must not echo raw flag');

  const unsafeFailure = await execFile(
    process.execPath,
    [
      cliPath,
      '--out', unsafeOut,
      '--bad-flag'
    ],
    { cwd: REPO_ROOT, encoding: 'utf8' }
  ).catch((error) => ({
    code: error.code,
    stderr: `${error.stderr ?? ''}`,
    stdout: `${error.stdout ?? ''}`
  }));

  assert.notEqual(unsafeFailure.code, 0);
  await assert.rejects(fs.access(unsafeOut));
  const defaultReport = JSON.parse(await fs.readFile(defaultOut, 'utf8'));
  assert.deepEqual(defaultReport.failures, [
    {
      code: 'PACKAGE_ARGUMENT_INVALID',
      detail: 'Package inspection arguments are invalid.'
    }
  ]);
  assertNoSensitiveLeak(JSON.stringify(defaultReport), sentinel, 'default unknown-flag report');
  assertNoSensitiveLeak(unsafeFailure.stderr, sentinel, 'unsafe unknown-flag stderr');
  assert.equal(/inspect-phase4-packages\.mjs:\d+/u.test(unsafeFailure.stderr), false, 'unsafe unknown-flag stderr must not leak source file lines');
  assert.equal(unsafeFailure.stderr.includes('--bad-flag'), false, 'unsafe unknown-flag stderr must not echo raw flag');
});

test('phase4 package inspector normalizes package read failures without leaking raw errors', async () => {
  const inspector = await import(modulePath);
  const sentinel = `phase4-package-read-${process.pid}-${os.userInfo().username}`;

  await assert.rejects(
    inspector.inspectPhase4Packages({
      productionHapPath: 'harmony/entry/build/default/outputs/default/entry-default-signed.hap',
      productionManifestPath: 'harmony/artifacts/phase1-native-provenance.json',
      probeHapPath: 'harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap',
      ...createHappyInspectorDependencies(),
      readModuleJsonImpl: async () => {
        throw Object.assign(new Error(`ENOENT: ${path.join(REPO_ROOT, sentinel, 'module.json')}`), { code: 'ENOENT' });
      }
    }),
    (error) => {
      assert.equal(error?.code, 'PRODUCTION_PACKAGE_UNREADABLE');
      assert.equal(error?.message, 'Production package metadata could not be read.');
      assertNoSensitiveLeak(`${error?.message ?? ''}`, sentinel, 'thrown public message');
      return true;
    }
  );
});

test('phase4 package inspector real signature verifier builds trusted java argv and cleans temp outputs', async () => {
  const inspector = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-signature-verify-'));
  const hapPath = path.join(tempRoot, 'entry-default-signed.hap');
  await fs.writeFile(hapPath, 'hap-bytes', 'utf8');
  const tempArtifacts = [];
  const result = await inspector.defaultVerifySignature({
    hapPath,
    tempRoot,
    execFileImpl: async (command, args) => {
      assert.equal(command, '/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java');
      assert.equal(args.includes('-jar'), true);
      assert.equal(args.includes('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar'), true);
      assert.equal(args.includes('verify-app'), true);
      const outCertIndex = args.indexOf('-outCertChain');
      const outProfileIndex = args.indexOf('-outProfile');
      assert.match(args[outCertIndex + 1], /\.cer$/u);
      assert.match(args[outProfileIndex + 1], /\.p7b$/u);
      await fs.writeFile(args[outCertIndex + 1], 'cert-chain', 'utf8');
      await fs.writeFile(args[outProfileIndex + 1], 'profile', 'utf8');
      tempArtifacts.push(args[outCertIndex + 1], args[outProfileIndex + 1]);
      return { stdout: '', stderr: '' };
    }
  });
  assert.match(result.signatureSha256, /^[a-f0-9]{64}$/u);
  for (const artifactPath of tempArtifacts) {
    await assert.rejects(fs.access(artifactPath));
  }
});

test('phase4 package inspector verifier nonzero or empty outputs fail closed', async () => {
  const inspector = await import(modulePath);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-signature-verify-fail-'));
  const hapPath = path.join(tempRoot, 'entry-default-signed.hap');
  await fs.writeFile(hapPath, 'hap-bytes', 'utf8');

  const failed = await inspector.defaultVerifySignature({
    hapPath,
    tempRoot,
    execFileImpl: async () => {
      throw new Error('verify failed');
    }
  });
  assert.equal(failed, null);

  const empty = await inspector.defaultVerifySignature({
    hapPath,
    tempRoot,
    execFileImpl: async (_command, args) => {
      const outCertIndex = args.indexOf('-outCertChain');
      const outProfileIndex = args.indexOf('-outProfile');
      await fs.writeFile(args[outCertIndex + 1], '', 'utf8');
      await fs.writeFile(args[outProfileIndex + 1], '', 'utf8');
      return { stdout: '', stderr: '' };
    }
  });
  assert.equal(empty, null);
});

test('phase4 package inspector source contract requires production archive bridge scans through bounded unzip reads', async () => {
  const source = await fs.readFile(fileURLToPath(modulePath), 'utf8');

  assert.match(source, /const REQUIRED_PRODUCTION_BRIDGE_SCAN_ENTRY_PATHS = Object\.freeze\(\[\s*'ets\/modules\.abc'\s*\]\);/u);
  assert.match(source, /const OPTIONAL_PRODUCTION_BRIDGE_SCAN_ENTRY_PATHS = Object\.freeze\(\[\s*'ets\/sourceMaps\.map'\s*\]\);/u);
  assert.match(source, /const OBSOLETE_BRIDGE_MARKERS = Object\.freeze\(\[[\s\S]*'NativeVpnRuntimeBridge'[\s\S]*'clearVpnRuntimeBridgeSnapshotIfOwned'[\s\S]*\]\);/u);
  assert.match(source, /execFileImpl\('\/usr\/bin\/unzip',\s*\['-p',\s*hapPath,\s*entryPath\]/u);
  assert.match(source, /maxBuffer:\s*PRODUCTION_BRIDGE_SCAN_MAX_BUFFER_BYTES/u);
  assert.match(source, /scanProductionBridgeMarkersImpl/u);
});
