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

function assertOrdered(source, labelsAndNeedles) {
  let previousIndex = -1;
  for (const [label, needle] of labelsAndNeedles) {
    const currentIndex = source.indexOf(needle);
    assert.notEqual(currentIndex, -1, `missing ${label}`);
    assert.ok(currentIndex > previousIndex, `${label} must preserve the required source order`);
    previousIndex = currentIndex;
  }
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
  assert.match(
    driverSource,
    /constructor\(\s*api:\s*VpnConnectionApi,\s*sessionId:\s*string,\s*store:\s*VpnPlatformOwnershipStorePort,\s*reportStageLifecycle\?:\s*\(stage:\s*string\)\s*=>\s*void\s*\)/u,
    'HarmonyVpnConnectionDriver must keep the exact constructor signature independent of formatting'
  );
  assertContains(driverSource, 'async protectProcess(): Promise<void>', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'async create(config: VpnCaptureConfig): Promise<TunHandle>', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'async protectSocket(fd: number): Promise<void>', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'destroy(vpnId: string)', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'protectProcessNet', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'generateVpnId', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'Number.isSafeInteger', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'destroyWithVpnId', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'if (this.api.sdkApiVersion() >= API22)', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'if (this.api.sdkApiVersion() < API22)', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'PROCESS_PROTECT_FAILED', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'PROTECT_SOCKET_FAILED', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'CONSENT_DENIED', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'private readonly store: VpnPlatformOwnershipStorePort;', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'platformDestroyed: boolean;', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, "persistedPhase: VpnPlatformOwnershipPhase;", 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'const platformConfig: PlatformVpnConfig = createPlatformVpnConfig(owner.vpnId);', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'return createTunHandle(fd, owner.vpnId, this.sessionId);', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, "await this.store.clearExpected(createOwnershipRecord('RELEASED', vpnId));", 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, "await this.store.write(createOwnershipRecord('PREPARED', owner.vpnId));", 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, "await this.store.write(createOwnershipRecord('ACTIVE', owner.vpnId));", 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'const persistedOwnership: VpnPlatformOwnershipRecord | null = await this.store.read();', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'DESTROY_ALREADY_RELEASED_ERROR_CODE', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'if (!owner.storeWasEmpty)', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, "if (persistedOwnership.phase === 'RELEASED')", 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, "if (!liveHandle.platformDestroyed)", 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, "if (liveHandle.persistedPhase !== 'RELEASED')", 'HarmonyVpnConnectionDriver');
  for (const stage of [
    'platform.config.begin',
    'platform.config.ok',
    'platform.config.failed',
    'platform.connection.begin',
    'platform.connection.ok',
    'platform.connection.consent',
    'platform.connection.active',
    'platform.connection.legacy-reclaim.begin',
    'platform.connection.legacy-reclaim.ok',
    'platform.connection.legacy-reclaim.failed',
    'platform.connection.retry.begin',
    'platform.connection.retry.ok',
    'platform.connection.retry.consent',
    'platform.connection.retry.active',
    'platform.connection.retry.parameter',
    'platform.connection.retry.invalid',
    'platform.connection.retry.service',
    'platform.connection.retry.internal',
    'platform.connection.retry.failed',
    'platform.connection.parameter',
    'platform.connection.invalid',
    'platform.connection.service',
    'platform.connection.internal',
    'platform.connection.failed',
    'platform.fd.ok',
    'platform.fd.failed'
  ]) {
    assertContains(driverSource, `'${stage}'`, 'HarmonyVpnConnectionDriver');
  }
  assertNotContains(driverSource, 'JSON.stringify(error)', 'HarmonyVpnConnectionDriver');
  assertContains(apiSource, 'deviceInfo.sdkApiVersion', 'VpnConnectionApi');
  assertNotContains(driverSource, 'create(sessionId: string', 'HarmonyVpnConnectionDriver');
  assertNotContains(driverSource, 'SessionIdResolver', 'HarmonyVpnConnectionDriver');
  assertNotContains(driverSource, 'resolveSessionId', 'HarmonyVpnConnectionDriver');
  assertNotContains(
    driverSource,
    'PlatformVpnConfigRecord',
    'HarmonyVpnConnectionDriver must omit absent optional VpnConfig properties'
  );
  assertNotContains(
    apiSource,
    'class PlatformVpnConfigRecord',
    'VpnConnectionApi must not expose a record that materializes absent optional VpnConfig properties'
  );
  assertContains(
    driverSource,
    'const platformConfig: PlatformVpnConfig = {',
    'HarmonyVpnConnectionDriver'
  );
  assertContains(driverSource, 'trustedApplications: []', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'blockedApplications: [SELF_PACKAGE_NAME]', 'HarmonyVpnConnectionDriver');
  assertContains(driverSource, 'vpnId,', 'HarmonyVpnConnectionDriver');
  assertOrdered(driverSource, [
    ['read persisted owner', 'const persistedOwnership: VpnPlatformOwnershipRecord | null = await this.store.read();'],
    ['recover previous owner', 'await this.recoverPersistedOwner(owner, persistedOwnership);'],
    ['generate vpn id', 'owner.vpnId = await this.generateVpnId(owner.connection);'],
    ['persist prepared vpn id', "await this.store.write(createOwnershipRecord('PREPARED', owner.vpnId));"]
  ]);
  assertOrdered(driverSource, [
    ['destroy live owner by id', 'await this.destroyStoredPlatformOwner(liveHandle.connection, liveHandle.vpnId);'],
    ['persist released owner', "await this.store.write(createOwnershipRecord('RELEASED', vpnId));"],
    ['clear durable owner', "await this.store.clearExpected(createOwnershipRecord('RELEASED', vpnId));"],
    ['release live handle', 'this.liveHandle = undefined;']
  ]);
  assertNotContains(driverSource, 'MANAGE_VPN', 'HarmonyVpnConnectionDriver');
  assertNotContains(driverSource, 'ohos.permission.', 'HarmonyVpnConnectionDriver');
  assertNotContains(apiSource, 'MANAGE_VPN', 'VpnConnectionApi');
  assertNotContains(apiSource, 'enterprise', 'VpnConnectionApi');
  assertNotContains(apiSource, 'return 20;', 'VpnConnectionApi');
});
