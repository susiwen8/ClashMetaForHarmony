import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const PLATFORM_ROOT = path.join(HARMONY_ROOT, 'platform');
const PROFILE_REFRESH_BARREL = path.join(PLATFORM_ROOT, 'ProfileRefresh.ets');
const PLATFORM_INDEX = path.join(PLATFORM_ROOT, 'Index.ets');
const FACTORY_PATH = path.join(PLATFORM_ROOT, 'src', 'main', 'ets', 'ProfileRefreshPlatformFactory.ets');
const DRIVER_PATH = path.join(PLATFORM_ROOT, 'src', 'main', 'ets', 'background', 'WorkSchedulerDriver.ets');
const PLATFORM_TEST_LIST = path.join(PLATFORM_ROOT, 'src', 'test', 'List.test.ets');
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry');
const ENTRY_ETS_ROOT = path.join(ENTRY_ROOT, 'src', 'main', 'ets');
const MODULE_JSON_PATH = path.join(ENTRY_ROOT, 'src', 'main', 'module.json5');
const WORK_ABILITY_PATH = path.join(ENTRY_ETS_ROOT, 'background', 'SubscriptionRefreshWorkAbility.ets');
const WORK_COMPOSITION_PATH = path.join(ENTRY_ETS_ROOT, 'background', 'SubscriptionRefreshComposition.ets');
const ENTRY_TEST_LIST = path.join(ENTRY_ROOT, 'src', 'test', 'List.test.ets');
const ENTRY_ABILITY_PATH = path.join(ENTRY_ETS_ROOT, 'entryability', 'EntryAbility.ets');
const PROFILES_PAGE_PATH = path.join(ENTRY_ETS_ROOT, 'pages', 'ProfilesPage.ets');
const PROFILE_DETAIL_PAGE_PATH = path.join(ENTRY_ETS_ROOT, 'pages', 'ProfileDetailPage.ets');
const INDEX_PATH = path.join(ENTRY_ETS_ROOT, 'pages', 'Index.ets');
const STRINGS_PATH = path.join(ENTRY_ROOT, 'src', 'main', 'resources', 'base', 'element', 'string.json');
const PROFILE_ONLY_HELPER_PATHS = [
  path.join(PLATFORM_ROOT, 'src', 'main', 'ets', 'source', 'SubscriptionDownloader.ets'),
  path.join(PLATFORM_ROOT, 'src', 'main', 'ets', 'source', 'RequestAgentRedirectTransport.ets'),
  path.join(PLATFORM_ROOT, 'src', 'main', 'ets', 'source', 'NetworkKitHttpTransport.ets'),
  path.join(PLATFORM_ROOT, 'src', 'main', 'ets', 'source', 'HarmonyProfileSourceGateway.ets')
];

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

test('subscription refresh platform barrel exports the profile-only graph and scheduler driver', async () => {
  const [barrel, index] = await Promise.all([
    readUtf8(PROFILE_REFRESH_BARREL),
    readUtf8(PLATFORM_INDEX)
  ]);

  assert.match(barrel, /ProfileRefreshPlatformFactory/u);
  assert.match(barrel, /ProfileRefreshPlatformGraph/u);
  assert.match(barrel, /WorkSchedulerDriver/u);
  assert.match(barrel, /WorkSchedulerSystemPort/u);
  assert.match(barrel, /RdbProfileRefreshLeaseStore/u);
  assert.match(index, /export \* from '\.\/ProfileRefresh';/u);
});

test('subscription refresh foreground reload reads repository state without restarting runtimes', async () => {
  const [ability, entryList] = await Promise.all([
    readUtf8(ENTRY_ABILITY_PATH),
    readUtf8(ENTRY_TEST_LIST)
  ]);

  assert.match(ability, /onForeground\(\):\s*void\s*\{[\s\S]*reloadApplicationCompositionOnForeground/u);
  assert.match(ability, /await state\.application\.reloadFromRepository\(\)/u);
  const reloadStart = ability.indexOf('export async function reloadApplicationCompositionOnForeground');
  const reloadSource = ability.slice(reloadStart);
  assert.doesNotMatch(reloadSource, /startVpnGlobalCapture|stopVpnGlobalCapture|startLocal|stopRuntime|loadConfiguration/u);
  assert.match(entryList, /import entryAbilityTestsuite from '\.\/EntryAbility\.test';/u);
  assert.match(entryList, /entryAbilityTestsuite\(\);/u);
});

test('subscription refresh detail UI exposes remote-only interval presets and last-success metadata', async () => {
  const [page, stringsSource] = await Promise.all([
    readUtf8(PROFILE_DETAIL_PAGE_PATH),
    readUtf8(STRINGS_PATH)
  ]);
  const strings = JSON.parse(stringsSource);
  const names = new Set((strings.string ?? []).map((entry) => entry.name));

  assert.match(page, /PROFILE_AUTO_UPDATE_INTERVAL_PRESET_MS/u);
  assert.match(page, /profile\?\.sourceKind === 'REMOTE_URL'/u);
  assert.match(page, /\.id\('detail\.auto-update'\)/u);
  assert.match(page, /\.id\(`detail\.auto-update\.\$\{intervalMs\}`\)/u);
  assert.match(page, /requestAutoUpdateInterval\(intervalMs\)/u);
  assert.match(page, /\.id\('detail\.last-successful-update'\)/u);
  assert.match(page, /\.id\('detail\.auto-update\.current'\)/u);
  assert.match(page, /return \$r\('app\.string\.detail_auto_update_custom'\);/u);
  assert.doesNotMatch(page, /case 0:[\s\S]*default:[\s\S]*detail_auto_update_off/u);

  for (const name of [
    'detail_last_successful_update',
    'detail_last_successful_update_never',
    'detail_auto_update_title',
    'detail_auto_update_note',
    'detail_auto_update_current',
    'detail_auto_update_custom',
    'detail_auto_update_off',
    'detail_auto_update_2h',
    'detail_auto_update_6h',
    'detail_auto_update_12h',
    'detail_auto_update_24h',
    'detail_auto_update_7d'
  ]) {
    assert.equal(names.has(name), true, `missing string resource ${name}`);
  }
});

test('subscription refresh platform graph stays isolated from vpn notification and entry dependencies', async () => {
  const [barrel, factory, driver, ...helperSources] = await Promise.all([
    readUtf8(PROFILE_REFRESH_BARREL),
    readUtf8(FACTORY_PATH),
    readUtf8(DRIVER_PATH),
    ...PROFILE_ONLY_HELPER_PATHS.map((filePath) => readUtf8(filePath))
  ]);
  const combined = `${barrel}\n${factory}\n${driver}\n${helperSources.join('\n')}`;

  for (const forbidden of [
    'ContinuousTaskDriver',
    'HarmonyVpnNotificationDriver',
    'backgroundTaskManager',
    'NotificationKit',
    'VpnRpc',
    '/entry/',
    'EntryAbility',
    "from './PlatformFactory'"
  ]) {
    assert.equal(combined.includes(forbidden), false, `${forbidden} must stay outside the profile-only graph`);
  }

  assert.match(factory, /RdbProfileRepository/u);
  assert.match(factory, /RdbProfileRefreshLeaseStore/u);
  assert.match(factory, /SandboxProfileContentStore/u);
  assert.match(factory, /HuksSubscriptionSecretStore/u);
  assert.match(factory, /SubscriptionDownloader/u);
});

test('subscription refresh registers one non-exported workScheduler extension without weakening the VPN extension', async () => {
  const moduleSource = await readUtf8(MODULE_JSON_PATH);
  const normalized = moduleSource
    .replace(/\/\*[\s\S]*?\*\//gu, '')
    .replace(/^\s*\/\/.*$/gmu, '')
    .replace(/,\s*([}\]])/gu, '$1');
  const moduleDocument = JSON.parse(normalized);
  const extensions = moduleDocument.module.extensionAbilities ?? [];
  const vpnExtensions = extensions.filter((extension) => extension.type === 'vpn');
  const workExtensions = extensions.filter((extension) => extension.type === 'workScheduler');

  assert.equal(vpnExtensions.length, 1);
  assert.equal(vpnExtensions[0].name, 'CmfaVpnExtensionAbility');
  assert.equal(workExtensions.length, 1);
  assert.deepEqual(workExtensions[0], {
    name: 'SubscriptionRefreshWorkAbility',
    srcEntry: './ets/background/SubscriptionRefreshWorkAbility.ets',
    type: 'workScheduler',
    exported: false
  });
});

test('subscription refresh work ability applies the deadline cancellation and profile-only composition contract', async () => {
  const [ability, composition, entryList] = await Promise.all([
    readUtf8(WORK_ABILITY_PATH),
    readUtf8(WORK_COMPOSITION_PATH),
    readUtf8(ENTRY_TEST_LIST)
  ]);

  assert.match(ability, /extends WorkSchedulerExtensionAbility/u);
  assert.match(ability, /100\s*\*\s*1000/u);
  assert.match(ability, /onWorkStart\(work:\s*workScheduler\.WorkInfo\):\s*void/u);
  assert.match(ability, /onWorkStop\(work:\s*workScheduler\.WorkInfo\):\s*void/u);
  assert.match(ability, /workScheduler\.stopWork\(work, false\)/u);
  assert.match(composition, /new ProfileRefreshPlatformFactory\(context\)/u);
  assert.match(composition, /from '@cmfa\/platform\/ProfileRefresh';/u);
  assert.match(composition, /mode:\s*'DUE'/u);
  assert.match(composition, /deadlineMs/u);
  assert.match(composition, /isCancelled/u);
  assert.match(composition, /await graph\.close\(\)/u);
  assert.doesNotMatch(composition, /PlatformFactory|HarmonyVpnNotificationDriver|backgroundTaskManager|VpnRpc|CoreComposition/u);
  assert.match(entryList, /import subscriptionRefreshWorkAbilityTestsuite from '\.\/SubscriptionRefreshWorkAbility\.test';/u);
  assert.match(entryList, /subscriptionRefreshWorkAbilityTestsuite\(\);/u);
});

test('subscription refresh scheduler registers one persisted two-hour any-network work without clearing unrelated work', async () => {
  const driver = await readUtf8(DRIVER_PATH);

  assert.match(driver, /SUBSCRIPTION_REFRESH_WORK_ID:\s*number\s*=\s*7301/u);
  assert.match(driver, /SUBSCRIPTION_REFRESH_REPEAT_MS:\s*number\s*=\s*2\s*\*\s*60\s*\*\s*60\s*\*\s*1000/u);
  assert.match(driver, /isPersisted:\s*true/u);
  assert.match(driver, /NETWORK_TYPE_ANY/u);
  assert.match(driver, /isRepeat:\s*true/u);
  assert.match(driver, /abilityName:\s*SUBSCRIPTION_REFRESH_ABILITY_NAME/u);
  assert.doesNotMatch(driver, /stopAndClearWorks/u);
});

test('subscription refresh platform test suites remain registered', async () => {
  const list = await readUtf8(PLATFORM_TEST_LIST);

  assert.match(list, /import workSchedulerDriverTestsuite from '\.\/WorkSchedulerDriver\.test';/u);
  assert.match(list, /workSchedulerDriverTestsuite\(\);/u);
  assert.match(list, /import profileRefreshPlatformFactoryTestsuite from '\.\/ProfileRefreshPlatformFactory\.test';/u);
  assert.match(list, /profileRefreshPlatformFactoryTestsuite\(\);/u);
});

test('subscription refresh profiles UI wires refresh-all progress and privacy-safe result counts', async () => {
  const [page, index, stringsSource] = await Promise.all([
    readUtf8(PROFILES_PAGE_PATH),
    readUtf8(INDEX_PATH),
    readUtf8(STRINGS_PATH)
  ]);
  const strings = JSON.parse(stringsSource);
  const names = new Set((strings.string ?? []).map((entry) => entry.name));

  assert.match(page, /\.id\('profiles\.refresh-all'\)/u);
  assert.match(page, /\.id\('profiles\.refresh-progress'\)/u);
  assert.match(page, /\.id\('profiles\.refresh-summary'\)/u);
  assert.match(page, /refreshAllSummary/u);
  assert.match(page, /state\.remoteProfileCount/u);
  assert.doesNotMatch(page, /sourceKind\s*===\s*['"]REMOTE_URL['"]/u);
  assert.match(page, /summary\.success/u);
  assert.match(page, /summary\.failedUsingCurrent/u);
  assert.match(page, /summary\.skippedHttp/u);
  assert.match(page, /summary\.busy/u);
  const summarySource = page.slice(page.indexOf('function createRefreshSummaryItems'));
  assert.doesNotMatch(summarySource, /profileId|sourceDisplay|sourceSecretRef/u);
  assert.match(index, /onRefreshAll:\s*\(\)\s*=>\s*\{[\s\S]*requestRefreshAll\(\)/u);

  for (const name of [
    'profiles_refresh_all',
    'profiles_refresh_pending',
    'profiles_refresh_progress',
    'profiles_refresh_success',
    'profiles_refresh_failed_using_current',
    'profiles_refresh_failed',
    'profiles_refresh_skipped_http',
    'profiles_refresh_skipped_not_due',
    'profiles_refresh_busy',
    'profiles_refresh_interrupted',
    'profiles_refresh_remaining'
  ]) {
    assert.equal(names.has(name), true, `missing string resource ${name}`);
  }
});
