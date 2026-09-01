import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const SHARED_PORTS_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'vpn', 'VpnPorts.ets');
const DRIVER_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'vpn', 'HarmonyVpnConnectionDriver.ets');
const COMPOSITION_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'vpn', 'VpnExtensionComposition.ets');
const STORE_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'vpn', 'HarmonyVpnOwnershipStore.ets');

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
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

test('vpn ownership recovery contracts keep the durable owner private and exact', async () => {
  const [portsSource, driverSource, compositionSource, storeSource] = await Promise.all([
    readUtf8(SHARED_PORTS_PATH),
    readUtf8(DRIVER_PATH),
    readUtf8(COMPOSITION_PATH),
    readUtf8(STORE_PATH)
  ]);

  assert.match(portsSource, /export class OwnershipStoreCorruptError extends Error/u);
  assert.match(portsSource, /export interface VpnPlatformOwnershipStorePort \{\s*read\(\): Promise<string \| null>;\s*write\(vpnId: string\): Promise<void>;\s*clearExpected\(vpnId: string\): Promise<void>;\s*\}/u);

  assert.match(storeSource, /const MAX_DOCUMENT_BYTES: number = 256;/u);
  assert.match(storeSource, /const ACTIVE_VPN_FILE_NAME: string = 'active-platform-vpn-v1\.json';/u);
  assert.match(storeSource, /const ACTIVE_VPN_TEMP_FILE_NAME: string = 'active-platform-vpn-v1\.json\.tmp';/u);
  assert.match(storeSource, /fileIo\.fsyncSync\(fd\);/u);
  assert.match(storeSource, /await this\.fileDriver\.renameReplace\(this\.temporaryPath,\s*this\.targetPath\);/u);
  assert.match(storeSource, /throw new OwnershipStoreCorruptError\(\);/u);
  assert.doesNotMatch(storeSource, /hilog\./u);
  assert.doesNotMatch(storeSource, /sessionId|profileId|versionId/u);
  assertOrdered(storeSource, [
    ['write temp contents', 'await writeAll(this.fileDriver, token.fd, contents);'],
    ['fsync temp file', 'this.fsync(token.fd);'],
    ['close temp file', 'await this.fileDriver.close(token);'],
    ['rename into place', 'await this.fileDriver.renameReplace(this.temporaryPath, this.targetPath);']
  ]);
  assertOrdered(storeSource, [
    ['read exact current document', 'const document: OwnershipStoreDocument | null = await this.readDocumentIfPresent();'],
    ['compare exact vpn id', 'if (document === null || document.vpnId !== expectedVpnId) {'],
    ['unlink exact file', 'await this.fileDriver.unlink(this.targetPath);']
  ]);

  assert.match(compositionSource, /createHarmonyVpnOwnershipStore\(this\.context\.filesDir\)/u);
  assert.doesNotMatch(compositionSource, /reportStageLifecycle:[\s\S]{0,200}(vpnId|sessionId)/u);

  assertOrdered(driverSource, [
    ['read durable owner', 'const persistedVpnId: string | null = await this.store.read();'],
    ['destroy stale owner by real vpn id', 'await this.recoverPersistedOwner(owner, persistedVpnId);'],
    ['generate new vpn id', 'owner.vpnId = await this.generateVpnId(owner.connection);'],
    ['persist before create', 'await this.store.write(owner.vpnId);'],
    ['create with persisted vpn id', 'const fd: number = await connection.create(platformConfig);']
  ]);
  assert.match(driverSource, /return createTunHandle\(fd,\s*owner\.vpnId,\s*this\.sessionId\);/u);
  assert.match(driverSource, /await liveHandle\.connection\.destroyWithVpnId\(vpnId\);/u);
  assert.match(driverSource, /await this\.store\.clearExpected\(vpnId\);/u);
});
