import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

const harmonyRoot = path.resolve(new URL('../..', import.meta.url).pathname);
const rdbDriverPath = path.join(harmonyRoot, 'platform', 'src', 'main', 'ets', 'rdb', 'RdbDriver.ets');
const harmonyDriverPath = path.join(harmonyRoot, 'platform', 'src', 'main', 'ets', 'rdb', 'HarmonyRdbDriver.ets');
const profileRepositoryPath = path.join(harmonyRoot, 'platform', 'src', 'main', 'ets', 'rdb', 'RdbProfileRepository.ets');
const proxyRepositoryPath = path.join(harmonyRoot, 'platform', 'src', 'main', 'ets', 'rdb', 'RdbProxySelectionRepository.ets');
const proxyIdentityHasherPath = path.join(harmonyRoot, 'platform', 'src', 'main', 'ets', 'proxy', 'HarmonyProxyIdentityHasher.ets');

function countLiteralOccurrences(body, literal) {
  return body.split(literal).length - 1;
}

function extractBlock(body, startPattern, endPattern) {
  const match = body.match(new RegExp(`${startPattern}([\\s\\S]*?)${endPattern}`, 'u'));
  assert.ok(match, `expected block between ${startPattern} and ${endPattern}`);
  return match[1];
}

test('plan c rdb contract pins driver row surfaces and schema version 3 repositories', async () => {
  const [driverSource, profileRepositorySource, proxyRepositorySource] = await Promise.all([
    fs.readFile(rdbDriverPath, 'utf8'),
    fs.readFile(profileRepositoryPath, 'utf8'),
    fs.readFile(proxyRepositoryPath, 'utf8')
  ]);

  assert.match(driverSource, /export interface DurableProxySelectionRow\s*\{[\s\S]*profileId:\s*string;[\s\S]*groupName:\s*string;[\s\S]*selectedNodeName:\s*string;[\s\S]*revisionId:\s*string;[\s\S]*updatedAt:\s*string;[\s\S]*\}/u);
  assert.match(driverSource, /listProxySelectionRows\(profileId:\s*string\):\s*Promise<DurableProxySelectionRow\[\]>;/u);
  assert.match(driverSource, /getProxySelectionRow\(profileId:\s*string,\s*groupName:\s*string\):\s*Promise<DurableProxySelectionRow \| undefined>;/u);
  assert.match(driverSource, /listProxySelectionRows\(profileId:\s*string\):\s*Promise<DurableProxySelectionRow\[\]>;/u);
  assert.match(driverSource, /upsertProxySelectionRow\(row:\s*DurableProxySelectionRow\):\s*Promise<void>;/u);
  assert.match(driverSource, /deleteProxySelection\(profileId:\s*string,\s*groupName:\s*string\):\s*Promise<void>;/u);
  assert.match(driverSource, /deleteProfileSelections\(profileId:\s*string\):\s*Promise<void>;/u);

  assert.match(profileRepositorySource, /const SCHEMA_VERSION = 3;/u);
  assert.match(proxyRepositorySource, /const SCHEMA_VERSION = 3;/u);
});

test('plan c rdb contract pins exact proxy selection table sql single raw-name location and ordered reads', async () => {
  const [driverSource, proxyRepositorySource] = await Promise.all([
    fs.readFile(harmonyDriverPath, 'utf8'),
    fs.readFile(proxyRepositoryPath, 'utf8')
  ]);

  assert.equal(countLiteralOccurrences(driverSource, "'proxy_selections'"), 1, 'proxy_selections literal should be centralized once');
  assert.match(
    driverSource,
    /const PROXY_SELECTIONS_TABLE_SQL =\s*'CREATE TABLE IF NOT EXISTS '\s*\+\s*PROXY_SELECTIONS_TABLE\s*\+\s*' \('\s*\+\s*'profile_id TEXT NOT NULL,'\s*\+\s*'group_name TEXT NOT NULL,'\s*\+\s*'selected_node_name TEXT NOT NULL,'\s*\+\s*'revision_id TEXT NOT NULL,'\s*\+\s*'updated_at TEXT NOT NULL,'\s*\+\s*'PRIMARY KEY \(profile_id, group_name\)'\s*\+\s*'\)'/u
  );
  assert.match(driverSource, /SELECT\s+\$\{PROXY_SELECTION_COLUMNS\}\s+FROM\s+\$\{PROXY_SELECTIONS_TABLE\}\s+WHERE profile_id = \?\s+ORDER BY group_name ASC/u);
  assert.match(driverSource, /DELETE FROM\s+\$\{PROXY_SELECTIONS_TABLE\}\s+WHERE profile_id = \? AND group_name = \?/u);
  assert.match(driverSource, /DELETE FROM\s+\$\{PROXY_SELECTIONS_TABLE\}\s+WHERE profile_id = \?/u);
  assert.match(driverSource, /async deleteProfile\(id:\s*string\):\s*Promise<void>\s*\{[\s\S]*deleteProfileSelections\(id\)[\s\S]*DELETE FROM profiles WHERE id = \?/u);
  assert.doesNotMatch(proxyRepositorySource, /proxy_selections/u);
});

test('plan c rdb contract keeps initialization helper on exact additive version path', async () => {
  const source = await fs.readFile(harmonyDriverPath, 'utf8');
  const initializationSource = extractBlock(
    source,
    'export async function runRdbInitialization\\(',
    'function toDriverError'
  );

  assert.match(source, /export interface HarmonyRdbInitializationOperations/u);
  assert.match(source, /export async function runRdbInitialization\(\s*version:\s*number,\s*operations:\s*HarmonyRdbInitializationOperations\s*\):\s*Promise<void>/u);
  assert.match(source, /const TARGET_SCHEMA_VERSION = 3;/u);
  assert.match(source, /function isSupportedSchemaVersion\(version:\s*number\):\s*boolean\s*\{[\s\S]*version === 0[\s\S]*version === 1[\s\S]*version === 2[\s\S]*version === 3[\s\S]*\}/u);
  assert.match(source, /if \(version !== TARGET_SCHEMA_VERSION\)\s*\{[\s\S]*Unsupported database version/u);
  assert.match(source, /if \(!isSupportedSchemaVersion\(currentVersion\)\)\s*\{[\s\S]*Unsupported database version/u);
  assert.match(source, /if \(currentVersion !== version\)\s*\{[\s\S]*operations\.writeVersion\(version\)/u);
  assert.match(initializationSource, /const currentVersion: number = operations\.currentVersion\(\);[\s\S]*await operations\.createProfilesTable\(\)[\s\S]*await operations\.createAppStateTable\(\)[\s\S]*await operations\.seedAppState\(\)[\s\S]*await operations\.createProxySelectionsTable\(\)/u);
  assert.match(initializationSource, /if \(currentVersion === 1 \|\| currentVersion === 2\)\s*\{[\s\S]*await operations\.ensureProfileAutoUpdateIntervalColumn\(\)[\s\S]*\}/u);
  assert.match(initializationSource, /await operations\.createProfileRefreshLeasesTable\(\)[\s\S]*await operations\.validateProfilesTable\(\)[\s\S]*await operations\.validateProxySelectionsTable\(\)[\s\S]*await operations\.validateProfileRefreshLeasesTable\(\)/u);
  assert.doesNotMatch(initializationSource, /if \(!isSupportedSchemaVersion\(version\)\)/u);
});

test('plan c rdb contract keeps v1 to v3 migration additive only for profiles', async () => {
  const source = await fs.readFile(harmonyDriverPath, 'utf8');
  const initializationSource = extractBlock(
    source,
    'export async function runRdbInitialization\\(',
    'function toDriverError'
  );
  const initializationOpsSource = extractBlock(
    source,
    'private createInitializationOperations\\(store: relationalStore\\.RdbStore\\): HarmonyRdbInitializationOperations \\{',
    'async assertTableSchema'
  );

  assert.match(source, /CREATE TABLE IF NOT EXISTS '\s*\+\s*PROXY_SELECTIONS_TABLE/u);
  assert.match(source, /const PROFILE_AUTO_UPDATE_INTERVAL_SQL =\s*'ALTER TABLE profiles ADD COLUMN auto_update_interval_ms INTEGER NOT NULL DEFAULT 0';/u);
  assert.match(source, /const PROFILE_REFRESH_LEASES_TABLE_SQL =[\s\S]*'profile_id TEXT PRIMARY KEY NOT NULL,'[\s\S]*'owner_token TEXT NOT NULL,'[\s\S]*'expires_at INTEGER NOT NULL'[\s\S]*'\)'/u);
  assert.match(source, /export const PROFILE_TABLE_SPECS:[\s\S]*'auto_update_interval_ms', 'INTEGER', 1, 0/u);
  assert.match(source, /export const PROFILE_REFRESH_LEASE_TABLE_SPECS:[\s\S]*'profile_id', 'TEXT', 1, 1[\s\S]*'owner_token', 'TEXT', 1, 0[\s\S]*'expires_at', 'INTEGER', 1, 0/u);
  assert.match(source, /async ensureProfileAutoUpdateIntervalColumn\(\): Promise<void> \{[\s\S]*tableHasColumn[\s\S]*PROFILE_AUTO_UPDATE_INTERVAL_COLUMN[\s\S]*if \(columnExists\)\s*\{[\s\S]*return;[\s\S]*\}[\s\S]*PROFILE_AUTO_UPDATE_INTERVAL_SQL/u);
  assert.match(source, /async validateProfileRefreshLeasesTable\(\): Promise<void> \{[\s\S]*PROFILE_REFRESH_LEASE_TABLE_SPECS/u);
  assert.doesNotMatch(initializationSource, /DROP\s+TABLE\s+IF\s+EXISTS\s+profiles/iu);
  assert.doesNotMatch(initializationSource, /DROP\s+TABLE\s+profiles/iu);
  assert.doesNotMatch(initializationSource, /DELETE\s+FROM\s+profiles/iu);
  assert.doesNotMatch(initializationSource, /REPLACE\s+INTO\s+profiles/iu);
  assert.doesNotMatch(initializationOpsSource, /DROP\s+TABLE\s+IF\s+EXISTS\s+profiles/iu);
  assert.doesNotMatch(initializationOpsSource, /DROP\s+TABLE\s+profiles/iu);
  assert.doesNotMatch(initializationOpsSource, /DELETE\s+FROM\s+profiles/iu);
  assert.doesNotMatch(initializationOpsSource, /REPLACE\s+INTO\s+profiles/iu);
});

test('plan c hasher contract pins exact sha256 lifecycle and input validation without barrel exposure assumptions', async () => {
  const source = await fs.readFile(proxyIdentityHasherPath, 'utf8');

  assert.match(source, /const md: cryptoFramework\.Md = cryptoFramework\.createMd\('SHA256'\);/u);
  assert.match(source, /await md\.update\(\{ data: utf8Bytes \}\);/u);
  assert.match(source, /const result: cryptoFramework\.DataBlob = await md\.digest\(\);/u);
  assert.match(source, /return cloneBytes\(result\.data\);/u);
  assert.match(source, /if \(value\.length === 0 \|\| value\.length > MAX_INPUT_CODE_UNITS\)/u);
  assert.match(source, /if \(isControlCodeUnit\(codeUnit\)\)/u);
  assert.match(source, /if \(isHighSurrogate\(codeUnit\)\)/u);
  assert.match(source, /if \(!isLowSurrogate\(trailingCodeUnit\)\)/u);
  assert.match(source, /if \(isLowSurrogate\(codeUnit\)\)/u);
  assert.match(source, /if \(digestBytes\.length !== SHA256_DIGEST_LENGTH_BYTES\)/u);
  assert.doesNotMatch(source, /\.trim\(/u);
});
