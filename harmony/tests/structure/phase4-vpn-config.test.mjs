import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const DRIVER_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'vpn', 'HarmonyVpnConnectionDriver.ets');
const API_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'vpn', 'VpnConnectionApi.ets');

async function readSource(targetPath) {
  return await fs.readFile(targetPath, 'utf8');
}

function assertContains(source, fragment, context) {
  assert.equal(source.includes(fragment), true, `${context} must contain ${fragment}`);
}

function assertNotContains(source, fragment, context) {
  assert.equal(source.includes(fragment), false, `${context} must not contain ${fragment}`);
}

test('phase4 vpn driver keeps the exact full-capture literals and owner cleanup contracts', async () => {
  const [driverSource, apiSource] = await Promise.all([
    readSource(DRIVER_PATH),
    readSource(API_PATH)
  ]);
  const combinedSource = `${driverSource}\n${apiSource}`;

  assertContains(driverSource, '10.111.222.1', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'fd00:111:222::1', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, '0.0.0.0', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, '::', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, '10.111.222.2', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'fd00:111:222::2', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, '1500', 'HarmonyVpnConnectionDriver');
  assertContains(combinedSource, 'isIPv4Accepted', 'Harmony VPN source');
  assertContains(combinedSource, 'isIPv6Accepted', 'Harmony VPN source');
  assertContains(combinedSource, 'isBlocking', 'Harmony VPN source');
  assertContains(combinedSource, 'blockedApplications', 'Harmony VPN source');
  assertContains(driverSource, 'implements VpnPlatformSessionPort', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'constructor(api: VpnConnectionApi, sessionId: string)', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'async protectProcess(): Promise<void>', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'async create(config: VpnCaptureConfig): Promise<TunHandle>', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'async protectSocket(fd: number): Promise<void>', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'destroy(vpnId: string)', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'protectProcessNet', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'generateVpnId', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'Number.isSafeInteger', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'destroyWithVpnId', 'VpnConnectionApi');
  assertContains(driverSource, 'if (this.api.sdkApiVersion() >= API22)', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'if (this.api.sdkApiVersion() < API22)', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'PROCESS_PROTECT_FAILED', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'PROTECT_SOCKET_FAILED', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'CONSENT_DENIED', 'HarmonyVpnConnectionDriver');
  assertContains(apiSource, 'deviceInfo.sdkApiVersion', 'VpnConnectionApi');
  assertNotContains(driverSource, 'create(sessionId: string', 'HarmonyVpnConnectionDriver');
  assertNotContains(driverSource, 'SessionIdResolver', 'HarmonyVpnConnectionDriver');
  assertNotContains(driverSource, 'resolveSessionId', 'HarmonyVpnConnectionDriver');
  assertNotContains(driverSource, 'trustedApplications:', 'HarmonyVpnConnectionDriver');
  assertNotContains(driverSource, 'MANAGE_VPN', 'HarmonyVpnConnectionDriver');
  assertNotContains(driverSource, 'ohos.permission.', 'HarmonyVpnConnectionDriver');
  assertNotContains(apiSource, 'MANAGE_VPN', 'VpnConnectionApi');
  assertNotContains(apiSource, 'enterprise', 'VpnConnectionApi');
  assertNotContains(apiSource, 'return 20;', 'VpnConnectionApi');
});
