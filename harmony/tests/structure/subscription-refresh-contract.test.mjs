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

test('subscription refresh platform graph stays isolated from vpn notification and entry dependencies', async () => {
  const [barrel, factory, driver] = await Promise.all([
    readUtf8(PROFILE_REFRESH_BARREL),
    readUtf8(FACTORY_PATH),
    readUtf8(DRIVER_PATH)
  ]);
  const combined = `${barrel}\n${factory}\n${driver}`;

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
