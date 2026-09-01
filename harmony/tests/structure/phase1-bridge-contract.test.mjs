import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const ENTRY_CPP_ROOT = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp');
const ENTRY_ETS_ROOT = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets');
const ENTRY_TEST_ROOT = path.join(HARMONY_ROOT, 'entry', 'src', 'test');
const SHARED_ROOT = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets');
const STRUCTURE_ROOT = path.join(HARMONY_ROOT, 'tests', 'structure');

const OBSOLETE_FILE_PATHS = Object.freeze([
  path.join(ENTRY_CPP_ROOT, 'include', 'vpn_runtime_bridge_store.h'),
  path.join(ENTRY_CPP_ROOT, 'src', 'vpn_runtime_bridge_store.cpp'),
  path.join(ENTRY_CPP_ROOT, 'src', 'js_vpn_runtime_bridge.cpp'),
  path.join(HARMONY_ROOT, 'tests', 'native', 'vpn_runtime_bridge_store_test.cpp'),
  path.join(HARMONY_ROOT, 'tests', 'native', 'js_vpn_runtime_bridge_napi_test.cpp'),
  path.join(ENTRY_ETS_ROOT, 'vpn', 'NativeVpnRuntimeBridge.ets'),
  path.join(ENTRY_ETS_ROOT, 'vpn', 'VpnRuntimeBridgeModels.ets'),
  path.join(ENTRY_TEST_ROOT, 'NativeVpnRuntimeBridge.test.ets'),
  path.join(STRUCTURE_ROOT, 'vpn-runtime-bridge-contract.test.mjs')
]);

const BRIDGE_EXPORTS = Object.freeze([
  'claimVpnRuntimeBridgeSession',
  'publishVpnRuntimeBridgeSnapshotIfOwned',
  'readVpnRuntimeBridgeSnapshot',
  'clearVpnRuntimeBridgeSnapshotIfOwned'
]);

const BRIDGE_TYPES = Object.freeze([
  'NativeVpnRuntimeBridgeState',
  'NativeVpnRuntimeBridgeFailureCode',
  'NativeVpnRuntimeBridgeIdentity',
  'NativeVpnRuntimeBridgeSnapshot'
]);

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

async function assertMissing(filePath) {
  await assert.rejects(
    fs.access(filePath),
    { code: 'ENOENT' },
    `${path.relative(REPO_ROOT, filePath)} must be deleted after RPC cutover`
  );
}

test('Task 14 deletes every obsolete process-static bridge source and dedicated test', async () => {
  await Promise.all(OBSOLETE_FILE_PATHS.map(assertMissing));
});

test('Task 14 removes obsolete bridge NAPI exports, descriptors, d.ts surface, and native-host cases', async () => {
  const [cmakeSource, napiHeader, coreModuleSource, dtsSource, nativeHostSource] = await Promise.all([
    readUtf8(path.join(ENTRY_CPP_ROOT, 'CMakeLists.txt')),
    readUtf8(path.join(ENTRY_CPP_ROOT, 'include', 'cmfa_napi.h')),
    readUtf8(path.join(ENTRY_CPP_ROOT, 'src', 'js_core_module.cpp')),
    readUtf8(path.join(ENTRY_CPP_ROOT, 'types', 'libentry', 'Index.d.ts')),
    readUtf8(path.join(HARMONY_ROOT, 'tools', 'test-native-host.mjs'))
  ]);

  assert.match(cmakeSource, /src\/js_proxy\.cpp/u);
  assert.match(cmakeSource, /src\/js_tun\.cpp/u);
  assert.doesNotMatch(cmakeSource, /js_vpn_runtime_bridge\.cpp/u);
  assert.doesNotMatch(cmakeSource, /vpn_runtime_bridge_store\.cpp/u);

  for (const exportName of BRIDGE_EXPORTS) {
    assert.doesNotMatch(napiHeader, new RegExp(`\\b${exportName}\\b`, 'u'));
    assert.doesNotMatch(coreModuleSource, new RegExp(`\\b${exportName}\\b`, 'u'));
    assert.doesNotMatch(dtsSource, new RegExp(`\\b${exportName}\\b`, 'u'));
    assert.doesNotMatch(nativeHostSource, new RegExp(`\\b${exportName}\\b`, 'u'));
  }

  for (const typeName of BRIDGE_TYPES) {
    assert.doesNotMatch(dtsSource, new RegExp(`\\b${typeName}\\b`, 'u'));
  }

  assert.doesNotMatch(nativeHostSource, /napi-vpn-runtime-bridge/u);
  assert.doesNotMatch(nativeHostSource, /vpn-runtime-bridge-store/u);
  assert.match(nativeHostSource, /napi-proxy/u);
  assert.match(nativeHostSource, /napi-tun/u);
});

test('Task 14 removes production and test imports that keep the obsolete bridge alive', async () => {
  const [coreCompositionSource, controllerSource, extensionSource, listTestSource] = await Promise.all([
    readUtf8(path.join(ENTRY_ETS_ROOT, 'bootstrap', 'CoreComposition.ets')),
    readUtf8(path.join(ENTRY_ETS_ROOT, 'vpn', 'HarmonyVpnController.ets')),
    readUtf8(path.join(ENTRY_ETS_ROOT, 'vpn', 'VpnExtensionComposition.ets')),
    readUtf8(path.join(ENTRY_TEST_ROOT, 'List.test.ets'))
  ]);

  assert.doesNotMatch(coreCompositionSource, /VpnRuntimeBridge/u);
  assert.doesNotMatch(controllerSource, /bridgeReader|VpnRuntimeBridge/u);
  assert.doesNotMatch(extensionSource, /NativeVpnRuntimeBridge|VpnRuntimeBridge|runtimeBridge/u);
  assert.doesNotMatch(extensionSource, /\bTraversalBudget\b|\bbuildCatalogSnapshotGroup\b|\bRPC_CATALOG_BUILD_GENERATION\b|\bRPC_CATALOG_MAX_DEPTH\b|\bRPC_CATALOG_MAX_ENTRIES\b/u);
  assert.doesNotMatch(listTestSource, /NativeVpnRuntimeBridge/u);

  assert.match(extensionSource, /VpnRpcServer/u);
  assert.match(extensionSource, /VpnProxyRuntimeHandler/u);
  assert.match(extensionSource, /buildVpnRpcCatalogFromCore/u);
});

test('Task 14 keeps public core ABI, proxy RPC service, and TUN runtime surfaces intact', async () => {
  const [coreHeader, hostHeader, typesHeader, backendSource, sharedVpnModels, sharedRpcBuilder, coreService] = await Promise.all([
    readUtf8(path.join(HARMONY_ROOT, 'core', 'abi', 'include', 'cmfa_core.h')),
    readUtf8(path.join(HARMONY_ROOT, 'core', 'abi', 'include', 'cmfa_host.h')),
    readUtf8(path.join(HARMONY_ROOT, 'core', 'abi', 'include', 'cmfa_types.h')),
    readUtf8(path.join(ENTRY_CPP_ROOT, 'src', 'cmfa_mihomo_backend.cpp')),
    readUtf8(path.join(SHARED_ROOT, 'vpn', 'VpnModels.ets')),
    readUtf8(path.join(SHARED_ROOT, 'vpn', 'rpc', 'VpnRpcCatalogBuilder.ets')),
    readUtf8(path.join(SHARED_ROOT, 'core', 'CoreService.ets'))
  ]);

  assert.match(coreHeader, /\bcmfa_proxy_groups\b/u);
  assert.match(coreHeader, /\bcmfa_proxy_group\b/u);
  assert.match(coreHeader, /\bcmfa_proxy_select\b/u);
  assert.match(coreHeader, /\bcmfa_tun_start\b/u);
  assert.match(hostHeader, /\bhost_protect_socket\b/u);
  assert.match(hostHeader, /\bhost_emit_event\b/u);
  assert.match(backendSource, /\bcmfa_host_protect_socket_bridge_v1\b/u);
  assert.match(backendSource, /\bcmfa_host_emit_runtime_event_bridge_v1\b/u);
  assert.match(typesHeader, /\bcmfa_proxy_query_context\b/u);

  assert.match(coreService, /\bqueryProxyGroups\b/u);
  assert.match(coreService, /\bstartProxyDelayTest\b/u);
  assert.match(sharedRpcBuilder, /\bbuildVpnRpcCatalogFromCore\b/u);
  assert.match(sharedVpnModels, /\bcreateVpnRuntimeSnapshot\b/u);
  assert.match(sharedVpnModels, /\bcreateVpnFailure\b/u);
});

test('Task 14 keeps build cache cleanup and production package marker scans wired into the proof toolchain', async () => {
  const [phase1BuildSource, buildHapSource, phase4PackageSource] = await Promise.all([
    readUtf8(path.join(HARMONY_ROOT, 'tests', 'bin', 'build-phase1-native.mjs')),
    readUtf8(path.join(HARMONY_ROOT, 'tests', 'bin', 'build-hap.mjs')),
    readUtf8(path.join(HARMONY_ROOT, 'tests', 'bin', 'inspect-phase4-packages.mjs'))
  ]);

  assert.match(phase1BuildSource, /\['entry', 'build', 'default', 'cache'\]/u);
  assert.match(phase1BuildSource, /await cleanupPhase1Outputs\(harmonyRoot,\s*fsApi\);/u);
  assert.match(buildHapSource, /\['entry', 'build', 'default', 'cache'\]/u);
  assert.match(buildHapSource, /await cleanupBuildOutputs\(harmonyRoot,\s*fsApi\);/u);
  assert.match(phase4PackageSource, /scanProductionBridgeMarkersImpl/u);
  assert.match(phase4PackageSource, /'ets\/sourceMaps\.map'/u);
  assert.match(phase4PackageSource, /'ets\/modules\.abc'/u);
  assert.match(phase4PackageSource, /'NativeVpnRuntimeBridge'/u);
  assert.match(phase4PackageSource, /'clearVpnRuntimeBridgeSnapshotIfOwned'/u);
});
