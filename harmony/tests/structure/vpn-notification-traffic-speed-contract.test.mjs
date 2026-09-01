import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const NOTIFICATION_DRIVER_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'background', 'HarmonyVpnNotificationDriver.ets');
const CONTINUOUS_TASK_DRIVER_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'background', 'ContinuousTaskDriver.ets');
const VPN_CONTROLLER_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'vpn', 'HarmonyVpnController.ets');
const TRAFFIC_COORDINATOR_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'vpn', 'VpnTrafficNotificationCoordinator.ets');
const CORE_COMPOSITION_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'bootstrap', 'CoreComposition.ets');

async function readUtf8(targetPath) {
  return await fs.readFile(targetPath, 'utf8');
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

test('vpn notification traffic speed contract keeps live-view ownership metadata and exact update request fields', async () => {
  const [notificationSource, driverSource] = await Promise.all([
    readUtf8(NOTIFICATION_DRIVER_PATH),
    readUtf8(CONTINUOUS_TASK_DRIVER_PATH)
  ]);

  assert.match(driverSource, /slotType\?: number;/u, 'ContinuousTaskNotificationInfo must expose optional slotType ownership');
  assert.match(driverSource, /contentType\?: number;/u, 'ContinuousTaskNotificationInfo must expose optional contentType ownership');
  assert.match(driverSource, /updateNotification\(notificationId: number, title: string, text: string\): Promise<void>;/u,
    'ContinuousTaskDriver must expose the updateNotification bridge'
  );

  assert.match(notificationSource, /id:\s*notificationId/u, 'notification update must reuse the original system notification id');
  assert.match(notificationSource, /updateOnly:\s*true/u, 'notification update must not create a second notification');
  assert.match(notificationSource, /notificationSlotType:\s*notificationManager\.SlotType\.LIVE_VIEW/u, 'notification update must target LIVE_VIEW');
  assert.match(notificationSource, /notificationContentType:\s*notificationManager\.ContentType\.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW/u,
    'notification update must target SYSTEM_LIVE_VIEW'
  );
  assert.match(notificationSource, /typeCode:\s*8/u, 'notification update must use the upload-download typeCode');
  assert.match(notificationSource, /title:\s*'Clash Meta VPN'/u, 'notification update must keep the fixed title');
  assert.match(notificationSource, /text:\s*speedText/u, 'system live view text must use the safe speed copy');
  assert.match(notificationSource, /capsule:\s*\{[\s\S]*title:\s*speedText/u, 'capsule title must mirror the safe speed copy');
  assert.match(notificationSource, /template:\s*\{[\s\S]*name:\s*'downloadTemplate'/u, 'notification update must use downloadTemplate');
  assert.match(notificationSource, /data:\s*\{[\s\S]*title:\s*'Clash Meta VPN'[\s\S]*fileName:\s*speedText[\s\S]*progressValue:\s*0/u,
    'downloadTemplate data must keep the exact title/fileName/progressValue mapping'
  );
});

test('vpn notification traffic speed contract keeps fixed safe formatting and session-id gating semantics', async () => {
  const notificationSource = await readUtf8(NOTIFICATION_DRIVER_PATH);
  const updateTrafficBody = extractMethodBody(notificationSource, 'async updateTraffic(');

  assert.match(notificationSource, /return `↑ \$\{formatSpeed\(uploadBytesPerSecond\)\}  ↓ \$\{formatSpeed\(downloadBytesPerSecond\)\}`;/u,
    'speed text must keep the exact fixed up/down format'
  );
  assert.match(notificationSource, /if \(!Number\.isSafeInteger\(value\) \|\| value < 0\) \{\s*return 0;\s*\}/u,
    'invalid speed inputs must normalize to zero'
  );
  assert.match(notificationSource, /if \(normalized < 1024\) \{\s*return `\$\{normalized\} B\/s`;\s*\}/u,
    'sub-KiB values must stay in integer B/s'
  );
  assert.match(notificationSource, /return `\$\{\(normalized \/ unit\.size\)\.toFixed\(1\)\} \$\{unit\.suffix\}\/s`;/u,
    'KiB/MiB/GiB values must stay base-1024 with one decimal place'
  );
  assert.match(updateTrafficBody, /if \(\s*this\.activeSessionId !== sessionId\s*\|\|\s*this\.activeNotificationId === undefined\s*\)\s*\{\s*return;\s*\}/u,
    'traffic updates must gate only on the owned session and notification id'
  );
  assert.match(notificationSource, /private activeNotificationIsLiveView\(\): boolean \{[\s\S]*this\.activeSlotType === CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE[\s\S]*this\.activeContentType === CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE/u,
    'start-returned slotType/contentType metadata must still be decoded for diagnostics'
  );
  assert.doesNotMatch(updateTrafficBody, /activeNotificationIsLiveView\(\)/u,
    'start-returned live-view metadata must not be a publish precondition'
  );
  for (const stage of [
    'notification.traffic.id-ready',
    'notification.traffic.id-missing',
    'notification.traffic.metadata-live-view',
    'notification.traffic.metadata-non-live-view',
    'notification.traffic.publish.begin',
    'notification.traffic.publish.ok',
    'notification.traffic.publish.failed'
  ]) {
    assert.match(notificationSource, new RegExp(`['"]${stage.replaceAll('.', '\\\.')}['"]`, 'u'));
  }
});

test('vpn notification traffic speed contract wires fixed diagnostic stage reporting through controller and composition only', async () => {
  const [controllerSource, coordinatorSource, coreCompositionSource] = await Promise.all([
    readUtf8(VPN_CONTROLLER_PATH),
    readUtf8(TRAFFIC_COORDINATOR_PATH),
    readUtf8(CORE_COMPOSITION_PATH)
  ]);

  assert.match(controllerSource, /trafficMonitor\?: VpnTrafficMonitorReadPort & VpnTrafficMonitorLifecyclePort;/u,
    'controller dependencies must accept one real shared traffic monitor'
  );
  assert.match(controllerSource, /trafficReportStage\?: \(stage: string\) => void;/u,
    'controller dependencies must expose the optional fixed diagnostic callback'
  );
  assert.match(
    controllerSource,
    /new VpnTrafficNotificationCoordinator\([\s\S]*dependencies\.trafficMonitor,[\s\S]*new VpnTrafficNotificationSinkRecord\(this\.vpnExtension\),[\s\S]*dependencies\.trafficReportStage[\s\S]*\)/u,
    'controller must subscribe the traffic coordinator to the injected shared monitor'
  );
  assert.doesNotMatch(
    controllerSource,
    /new VpnTrafficNotificationCoordinator\([\s\S]*trafficClock|new VpnTrafficNotificationCoordinator\([\s\S]*trafficScheduler/u,
    'controller must not construct the coordinator with source-owned polling dependencies'
  );
  assert.doesNotMatch(controllerSource, /new VpnTrafficMonitor\(/u,
    'controller must not own construction of the shared traffic monitor'
  );
  assert.match(
    controllerSource,
    /private startTrafficLoop\(sessionId: string\): void \{[\s\S]*this\.trafficMonitor\?\.start\(sessionId\);[\s\S]*this\.trafficNotificationCoordinator\?\.start\(sessionId\);/u,
    'controller must start the shared monitor before subscribing notification presentation to the shared monitor'
  );
  assert.match(controllerSource, /this\.trafficMonitor\?\.markRecovering\(sessionId\);/u,
    'controller must mark the shared monitor recovering without tearing down subscribers'
  );
  assert.match(controllerSource, /this\.trafficMonitor\?\.stop\(activeSessionId\);/u,
    'controller must stop the shared monitor for the active session'
  );
  assert.match(controllerSource, /this\.trafficMonitor\?\.dispose\(\);/u,
    'controller dispose must tear down the shared monitor'
  );
  assert.match(coreCompositionSource, /const trafficMonitor = new VpnTrafficMonitor\(/u,
    'production CoreComposition must create one composition-owned traffic monitor'
  );
  assert.match(coreCompositionSource, /controllerDependencies\.trafficMonitor = trafficMonitor;/u,
    'production CoreComposition must inject the shared traffic monitor into the controller'
  );
  assert.match(coreCompositionSource, /controllerDependencies\.trafficReportStage = reportVpnUiStage;/u,
    'production CoreComposition must wire the existing fixed UI stage reporter into the subscriber coordinator'
  );
  for (const stage of [
    'notification.traffic.source-ok',
    'notification.traffic.source-failed',
    'notification.traffic.counters-zero',
    'notification.traffic.counters-nonzero',
    'notification.traffic.rate-zero',
    'notification.traffic.rate-nonzero'
  ]) {
    assert.match(coordinatorSource, new RegExp(`['"]${stage.replaceAll('.', '\\\.')}['"]`, 'u'));
  }
  assert.doesNotMatch(coordinatorSource, /NullTrafficMonitor/u,
    'subscriber coordinator must not silently downgrade to a null monitor'
  );
  assert.doesNotMatch(coordinatorSource, /refreshTrafficCounters\(/u,
    'subscriber coordinator must not poll counters directly'
  );
  assert.doesNotMatch(coordinatorSource, /reportStage\(\s*`/u,
    'traffic diagnostics must use fixed stage literals rather than interpolated payloads'
  );
  assert.doesNotMatch(coordinatorSource, /reportStage\([^)]*(?:sessionId|txBytes|rxBytes|uploadBytesPerSecond|downloadBytesPerSecond|nowMs)/u,
    'traffic diagnostics must not log counters, rates, session ids, or timestamps'
  );
});
