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

function extractMethodBody(source, signature) {
  const startIndex = source.indexOf(signature);
  assert.notEqual(startIndex, -1, `missing method signature: ${signature}`);
  const braceStart = source.indexOf('{', startIndex);
  assert.notEqual(braceStart, -1, `missing method body start: ${signature}`);
  let depth = 0;
  for (let index = braceStart; index < source.length; index += 1) {
    const char = source[index];
    if (char === '{') {
      depth += 1;
    } else if (char === '}') {
      depth -= 1;
      if (depth === 0) {
        return source.slice(braceStart, index + 1);
      }
    }
  }
  assert.fail(`unterminated method body: ${signature}`);
}

test('vpn ownership recovery contracts keep the durable owner private and exact', async () => {
  const [portsSource, driverSource, compositionSource, storeSource] = await Promise.all([
    readUtf8(SHARED_PORTS_PATH),
    readUtf8(DRIVER_PATH),
    readUtf8(COMPOSITION_PATH),
    readUtf8(STORE_PATH)
  ]);

  assert.match(portsSource, /export class OwnershipStoreCorruptError extends Error/u);
  assert.match(portsSource, /export type VpnPlatformOwnershipPhase = 'PREPARED' \| 'ACTIVE' \| 'RELEASED';/u);
  assert.match(portsSource, /export interface VpnPlatformOwnershipRecord \{\s*phase: VpnPlatformOwnershipPhase;\s*vpnId: string;\s*\}/u);
  assert.match(portsSource, /export interface VpnPlatformOwnershipStorePort \{\s*read\(\): Promise<VpnPlatformOwnershipRecord \| null>;\s*write\(ownership: VpnPlatformOwnershipRecord\): Promise<void>;\s*clearExpected\(ownership: VpnPlatformOwnershipRecord\): Promise<void>;\s*\}/u);

  assert.match(storeSource, /const MAX_DOCUMENT_BYTES: number = 256;/u);
  assert.match(storeSource, /const ACTIVE_VPN_FILE_NAME: string = 'active-platform-vpn-v1\.json';/u);
  assert.match(storeSource, /const ACTIVE_VPN_TEMP_FILE_SUFFIX: string = '\.tmp';/u);
  assert.match(storeSource, /const ACTIVE_VPN_CLAIM_FILE_NAME: string = 'active-platform-vpn-v1\.claim\.json';/u);
  assert.match(storeSource, /fileIo\.fsyncSync\(fd\);/u);
  assert.match(storeSource, /createOperationId\?: \(\) => string;/u);
  assert.match(storeSource, /normalizeOperationId\(this\.createOperationId\(\)\)/u);
  assert.match(storeSource, /phase: VpnPlatformOwnershipPhase;/u);
  assert.match(storeSource, /await this\.fileDriver\.renameReplace\(temporaryPath,\s*this\.targetPath\);/u);
  assert.match(storeSource, /await this\.fileDriver\.renameNoOverwrite\(this\.targetPath,\s*this\.claimPath\);/u);
  assert.match(storeSource, /await this\.fileDriver\.renameNoOverwrite\(this\.claimPath,\s*this\.targetPath\);/u);
  assert.match(storeSource, /throw new OwnershipStoreCorruptError\(\);/u);
  assert.doesNotMatch(storeSource, /hilog\./u);
  assert.doesNotMatch(storeSource, /sessionId|profileId|versionId/u);
  assertOrdered(storeSource, [
    ['write temp contents', 'await writeAll(this.fileDriver, token.fd, contents);'],
    ['fsync temp file', 'this.fsync(token.fd);'],
    ['close temp file', 'await this.fileDriver.close(token);'],
    ['rename into place', 'await this.fileDriver.renameReplace(temporaryPath, this.targetPath);']
  ]);
  const clearMethod = extractMethodBody(
    storeSource,
    'async clearExpected(ownership: VpnPlatformOwnershipRecord): Promise<void>'
  );
  assertOrdered(clearMethod, [
    ['reconcile stale claim first', 'await this.reconcileClaimPath();'],
    ['claim current target', 'const claimed: boolean = await this.claimCurrentTarget();'],
    ['read claimed document', 'const claimedOwnership: OwnershipStoreDocumentRecord | null = await this.readDocumentIfPresent(this.claimPath);'],
    ['delete matched claim only', 'await this.fileDriver.unlink(this.claimPath);']
  ]);
  const reconcileMethod = extractMethodBody(storeSource, 'private async reconcileClaimPath(): Promise<void>');
  assertOrdered(reconcileMethod, [
    ['read claim before recovery', 'await this.readDocumentIfPresent(this.claimPath);'],
    ['recover stale claim when target missing', 'await this.fileDriver.renameNoOverwrite(this.claimPath, this.targetPath);'],
    ['prefer existing target on race', 'await this.readDocumentIfPresent(this.targetPath);'],
    ['drop stale claim after target wins', 'await this.fileDriver.unlink(this.claimPath);']
  ]);
  const restoreMethod = extractMethodBody(storeSource, 'private async restoreOrDiscardClaim(): Promise<void>');
  assertOrdered(restoreMethod, [
    ['if target absent restore claim', 'await this.fileDriver.renameNoOverwrite(this.claimPath, this.targetPath);'],
    ['if target exists keep it', 'await this.readDocumentIfPresent(this.targetPath);'],
    ['cleanup old claim', 'await this.fileDriver.unlink(this.claimPath);']
  ]);

  assert.match(compositionSource, /createHarmonyVpnOwnershipStore\(this\.context\.filesDir,\s*createOperationId\)/u);
  assert.match(compositionSource, /createPlatformPort\(request\.sessionId,\s*\(\): string => platformGraph\.idGenerator\.nextId\(\)\)/u);
  assert.doesNotMatch(compositionSource, /reportStageLifecycle:[\s\S]{0,200}(vpnId|sessionId)/u);

  assertOrdered(driverSource, [
    ['read durable owner', 'const persistedOwnership: VpnPlatformOwnershipRecord | null = await this.store.read();'],
    ['destroy stale owner by real vpn id', 'await this.recoverPersistedOwner(owner, persistedOwnership);'],
    ['generate new vpn id', 'owner.vpnId = await this.generateVpnId(owner.connection);'],
    ['persist prepared before create', "await this.store.write(createOwnershipRecord('PREPARED', owner.vpnId));"],
    ['create with persisted vpn id', 'const fd: number = await connection.create(platformConfig);']
  ]);
  assert.match(driverSource, /await this\.store\.write\(createOwnershipRecord\('ACTIVE', owner\.vpnId\)\);/u);
  assert.match(driverSource, /if \(persistedOwnership\.phase === 'RELEASED'\)/u);
  assert.match(driverSource, /if \(!liveHandle\.platformDestroyed\)/u);
  assert.match(driverSource, /if \(liveHandle\.persistedPhase !== 'RELEASED'\)/u);
  assert.match(driverSource, /DESTROY_ALREADY_RELEASED_ERROR_CODE: number = 19900001;/u);
  assert.match(driverSource, /await this\.store\.write\(createOwnershipRecord\('RELEASED', vpnId\)\);/u);
  assert.match(driverSource, /return createTunHandle\(fd,\s*owner\.vpnId,\s*this\.sessionId\);/u);
  assert.match(driverSource, /await this\.destroyStoredPlatformOwner\(liveHandle\.connection,\s*liveHandle\.vpnId\);/u);
  assert.match(driverSource, /await this\.store\.clearExpected\(createOwnershipRecord\('RELEASED', vpnId\)\);/u);
});
