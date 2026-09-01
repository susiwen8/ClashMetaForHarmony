import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));

function read(relativePath) {
  return fs.readFileSync(path.join(HARMONY_ROOT, relativePath), 'utf8');
}

test('stage1 production network recovery binds NetworkKit and declares network state permission', () => {
  const driverPath = path.join(HARMONY_ROOT, 'platform/src/main/ets/network/HarmonyNetworkConnectionDriver.ets');
  assert.equal(fs.existsSync(driverPath), true, 'production NetworkKit connection driver must exist');

  const driver = fs.readFileSync(driverPath, 'utf8');
  assert.match(driver, /from ['"]@kit\.NetworkKit['"]/u);
  assert.match(driver, /connection\.getDefaultNet/u);
  assert.match(driver, /connection\.getNetCapabilities/u);
  assert.match(driver, /connection\.createNetConnection/u);
  assert.match(driver, /NET_CAPABILITY_INTERNET/u);
  assert.match(driver, /NET_CAPABILITY_VALIDATED/u);

  const factory = read('platform/src/main/ets/PlatformFactory.ets');
  assert.match(factory, /new HarmonyNetworkMonitor\(new HarmonyNetworkConnectionDriver\(\)\)/u);

  const manifest = read('entry/src/main/module.json5');
  assert.match(manifest, /["']ohos\.permission\.GET_NETWORK_INFO["']/u);
});

test('stage1 network monitor rejects a stale loss after a replacement default network', () => {
  const monitor = read('platform/src/main/ets/network/HarmonyNetworkMonitor.ets');
  assert.match(monitor, /isCurrentNetwork\(networkId: string\)/u);
  assert.match(monitor, /isCandidateNetwork\(networkId: string\)/u);
  assert.match(monitor, /const wasCurrent: boolean = this\.monitor\.isCurrentNetwork\(networkId\)/u);
});

test('stage1 runtime mode stays closed across Go ABI NAPI and ArkTS', () => {
  const goMain = read('core/go/cmd/cmfa_core/main.go');
  assert.match(goMain, /cmfa_mihomo_runtime_mode_v1/u);
  assert.match(goMain, /cmfa_mihomo_set_runtime_mode_v1/u);

  const types = read('core/abi/include/cmfa_types.h');
  assert.match(types, /typedef enum cmfa_runtime_mode/u);
  assert.match(types, /CMFA_MODE_RULE/u);
  assert.match(types, /CMFA_MODE_GLOBAL/u);
  assert.match(types, /CMFA_MODE_DIRECT/u);

  const coreHeader = read('core/abi/include/cmfa_core.h');
  assert.match(coreHeader, /cmfa_runtime_mode_query/u);
  assert.match(coreHeader, /cmfa_runtime_mode_set/u);

  const module = read('entry/src/main/cpp/src/js_core_module.cpp');
  assert.match(module, /queryRuntimeMode/u);
  assert.match(module, /setRuntimeMode/u);

  const declarations = read('entry/src/main/cpp/types/libentry/Index.d.ts');
  assert.match(declarations, /export type RuntimeMode = 'RULE' \| 'GLOBAL' \| 'DIRECT'/u);
  assert.match(declarations, /queryRuntimeMode/u);
  assert.match(declarations, /setRuntimeMode/u);

  const service = read('shared/src/main/ets/core/CoreService.ets');
  assert.match(service, /queryRuntimeMode/u);
  assert.match(service, /setRuntimeMode/u);
});

test('stage1 log center is extension-written bounded redacted and user-exportable', () => {
  const models = read('shared/src/main/ets/diagnostics/RuntimeLogModels.ets');
  assert.match(models, /redactSensitiveText/u);
  assert.match(models, /MAX_RUNTIME_LOG_MESSAGE_LENGTH/u);

  const store = read('platform/src/main/ets/diagnostics/HarmonyRuntimeLogStore.ets');
  assert.match(store, /runtime-logs\.jsonl/u);
  assert.match(store, /runtime-logs\.previous\.jsonl/u);
  assert.match(store, /maxFileBytes/u);

  const composition = read('entry/src/main/ets/vpn/VpnExtensionComposition.ets');
  assert.match(composition, /CoreRuntimeLogCollector/u);
  assert.match(composition, /createHarmonyRuntimeLogStore/u);

  const index = read('entry/src/main/ets/pages/Index.ets');
  assert.match(index, /'LOGS'/u);
  assert.match(index, /LogsViewModel/u);

  const page = read('entry/src/main/ets/pages/LogsPage.ets');
  assert.match(page, /logs\.search/u);
  assert.match(page, /onLevelChange/u);
  assert.match(page, /onExport/u);
  assert.match(page, /onClear/u);

  const exporter = read('platform/src/main/ets/diagnostics/HarmonyRuntimeLogExporter.ets');
  assert.match(exporter, /DocumentViewPicker/u);
  assert.match(exporter, /clash-meta-runtime-log\.txt/u);
});
