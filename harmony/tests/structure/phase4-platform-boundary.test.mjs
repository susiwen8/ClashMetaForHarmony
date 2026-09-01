import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const NETWORK_MONITOR_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'network', 'HarmonyNetworkMonitor.ets');
const NETWORK_DRIVER_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'network', 'NetworkConnectionDriver.ets');
const NOTIFICATION_DRIVER_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'background', 'HarmonyVpnNotificationDriver.ets');
const CONTINUOUS_TASK_DRIVER_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'background', 'ContinuousTaskDriver.ets');
const PLATFORM_FACTORY_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'PlatformFactory.ets');
const PLATFORM_INDEX_PATH = path.join(HARMONY_ROOT, 'platform', 'Index.ets');

async function readSource(targetPath) {
  return await fs.readFile(targetPath, 'utf8');
}

function assertNotContains(source, fragment, context) {
  assert.equal(
    source.includes(fragment),
    false,
    `${context} must not contain ${fragment}`
  );
}

function assertContains(source, fragment, context) {
  assert.equal(
    source.includes(fragment),
    true,
    `${context} must contain ${fragment}`
  );
}

test('phase4 platform boundary keeps notification SDK imports isolated and network recovery permission-free', async () => {
  const [
    networkMonitorSource,
    networkDriverSource,
    notificationDriverSource,
    continuousTaskDriverSource,
    platformFactorySource,
    platformIndexSource
  ] = await Promise.all([
    readSource(NETWORK_MONITOR_PATH),
    readSource(NETWORK_DRIVER_PATH),
    readSource(NOTIFICATION_DRIVER_PATH),
    readSource(CONTINUOUS_TASK_DRIVER_PATH),
    readSource(PLATFORM_FACTORY_PATH),
    readSource(PLATFORM_INDEX_PATH)
  ]);

  assertNotContains(networkMonitorSource, '@kit.NetworkKit', 'HarmonyNetworkMonitor');
  assertNotContains(networkDriverSource, '@kit.NetworkKit', 'NetworkConnectionDriver');
  assertNotContains(networkMonitorSource, '@cmfa/core', 'HarmonyNetworkMonitor');
  assertNotContains(networkMonitorSource, 'VpnExtensionAbility', 'HarmonyNetworkMonitor');
  assertNotContains(networkMonitorSource, 'content://', 'HarmonyNetworkMonitor');

  assertContains(notificationDriverSource, "@kit.BackgroundTasksKit", 'HarmonyVpnNotificationDriver');
  assertContains(notificationDriverSource, "@kit.AbilityKit", 'HarmonyVpnNotificationDriver');
  assertContains(notificationDriverSource, "@kit.NotificationKit", 'HarmonyVpnNotificationDriver');
  assertNotContains(continuousTaskDriverSource, '@kit.', 'ContinuousTaskDriver');
  assertNotContains(notificationDriverSource, '@cmfa/core', 'HarmonyVpnNotificationDriver');
  assertNotContains(notificationDriverSource, 'VpnExtensionAbility', 'HarmonyVpnNotificationDriver');
  assertNotContains(notificationDriverSource, 'profileId', 'HarmonyVpnNotificationDriver');
  assertNotContains(notificationDriverSource, 'versionId', 'HarmonyVpnNotificationDriver');
  assertNotContains(notificationDriverSource, 'secret', 'HarmonyVpnNotificationDriver');

  assertNotContains(platformFactorySource, '@kit.NetworkKit', 'PlatformFactory');
  assertNotContains(platformFactorySource, '@kit.BackgroundTasksKit', 'PlatformFactory');
  assertNotContains(platformFactorySource, '@kit.AbilityKit', 'PlatformFactory');
  assertNotContains(platformFactorySource, '@kit.NotificationKit', 'PlatformFactory');
  assertNotContains(platformIndexSource, '@kit.NotificationKit', 'platform/Index.ets');
  assertNotContains(platformIndexSource, '@kit.', 'platform/Index.ets');
});

test('phase4 notification adapter stays compat-20 and propagates start failures without a duplicate request', async () => {
  const notificationDriverSource = await readSource(NOTIFICATION_DRIVER_PATH);
  const startMethodOffset = notificationDriverSource.indexOf('async startBackgroundTask(');
  const stopMethodOffset = notificationDriverSource.indexOf('async stopBackgroundTask(', startMethodOffset);

  assert.notEqual(startMethodOffset, -1, 'notification driver must define startBackgroundTask');
  assert.notEqual(stopMethodOffset, -1, 'notification driver must define stopBackgroundTask after startBackgroundTask');

  const startMethodSource = notificationDriverSource.slice(startMethodOffset, stopMethodOffset);
  assertNotContains(
    startMethodSource,
    'catch',
    'notification start path'
  );
  assertNotContains(notificationDriverSource, 'ContinuousTaskRequest', 'compat-20 notification adapter');
  assertNotContains(notificationDriverSource, 'MODE_DATA_TRANSFER', 'compat-20 notification adapter');
  assertNotContains(
    notificationDriverSource,
    'stopBackgroundRunning(this.context, continuousTaskId)',
    'compat-20 notification adapter'
  );
  assert.match(
    notificationDriverSource,
    /notificationManager\.publish\(/u,
    'compat-20 notification adapter must update the system-owned notification via NotificationKit'
  );
  assert.match(
    notificationDriverSource,
    /updateOnly:\s*true/u,
    'compat-20 notification adapter must fail closed instead of creating a second notification'
  );
  assert.match(
    notificationDriverSource,
    /notificationSlotType:\s*notificationManager\.SlotType\.LIVE_VIEW/u,
    'compat-20 notification adapter must target the original LIVE_VIEW slot'
  );
  assert.match(
    notificationDriverSource,
    /notificationContentType:\s*notificationManager\.ContentType\.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW/u,
    'compat-20 notification adapter must keep the SYSTEM_LIVE_VIEW content type'
  );
});
