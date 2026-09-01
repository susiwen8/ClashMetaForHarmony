import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const APPLICATION_COMPOSITION_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'bootstrap', 'ApplicationComposition.ets');
const CORE_COMPOSITION_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'bootstrap', 'CoreComposition.ets');
const INDEX_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'pages', 'Index.ets');
const HOME_PAGE_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'pages', 'HomePage.ets');
const HOME_VIEW_MODEL_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'presentation', 'HomeViewModel.ets');

async function readUtf8(targetPath) {
  return await fs.readFile(targetPath, 'utf8');
}

function countMatches(source, pattern) {
  const matches = source.match(pattern);
  return matches === null ? 0 : matches.length;
}

function assertNoPattern(source, pattern, message) {
  assert.doesNotMatch(source, pattern, message);
}

test('home traffic contract keeps monitor ownership inside composition and exposes only a read port downstream', async () => {
  const [applicationCompositionSource, coreCompositionSource, indexSource, homeViewModelSource] = await Promise.all([
    readUtf8(APPLICATION_COMPOSITION_PATH),
    readUtf8(CORE_COMPOSITION_PATH),
    readUtf8(INDEX_PATH),
    readUtf8(HOME_VIEW_MODEL_PATH)
  ]);

  assert.match(applicationCompositionSource, /trafficMonitor\?: VpnTrafficMonitorReadPort;/u,
    'READY state must expose only a read-only traffic monitor port'
  );
  assert.equal(countMatches(coreCompositionSource, /new VpnTrafficMonitor\(/gu), 1,
    'CoreComposition must own exactly one VpnTrafficMonitor instance'
  );
  assert.match(coreCompositionSource, /private ownedVpnTrafficMonitor\?: VpnTrafficMonitorReadPort;/u,
    'composition must retain the owned read-only traffic monitor'
  );
  assert.match(coreCompositionSource, /interface BoundHarmonyVpnControllerResult \{[\s\S]*controller: HarmonyVpnController;[\s\S]*trafficMonitor: VpnTrafficMonitorReadPort;[\s\S]*\}/u,
    'controller factory must return both the controller and the shared read port'
  );
  assert.match(coreCompositionSource, /const ownedController = createBoundHarmonyVpnController\(/u,
    'composition must create the owned controller through the shared result wrapper'
  );
  assert.match(coreCompositionSource, /this\.ownedVpnController = ownedController\.controller;/u,
    'composition must keep the single owned controller instance'
  );
  assert.match(coreCompositionSource, /this\.ownedVpnTrafficMonitor = ownedController\.trafficMonitor;/u,
    'composition must keep the matching shared read port from the same factory result'
  );
  assert.match(coreCompositionSource, /const readyState: ApplicationCompositionState = createReadyState\([\s\S]*this\.ownedVpnTrafficMonitor,[\s\S]*\);/u,
    'READY publication must forward the owned read port'
  );
  assert.match(coreCompositionSource, /return \{[\s\S]*controller,[\s\S]*trafficMonitor[\s\S]*\};/u,
    'factory result must return the same shared monitor instance that was injected into the controller'
  );
  assert.match(indexSource, /state\.trafficMonitor/u,
    'Index must receive the read port from READY state'
  );
  assert.match(indexSource, /private attachApplication\([\s\S]*trafficMonitor\?: VpnTrafficMonitorReadPort,[\s\S]*\): void/u,
    'Index attachment must accept the read-only monitor port'
  );
  assert.match(indexSource, /new HomeViewModel\(application, vpnRegistry, runtimeModeClient, trafficMonitor\)/u,
    'Index must pass the read-only monitor port into HomeViewModel'
  );
  assert.match(homeViewModelSource, /constructor\([\s\S]*trafficMonitor\?: VpnTrafficMonitorReadPort[\s\S]*\)/u,
    'HomeViewModel must accept an optional read-only traffic monitor port'
  );
  assert.match(homeViewModelSource, /this\.trafficMonitorSubscriptionId = trafficMonitor\?\.subscribe\(/u,
    'HomeViewModel must subscribe once to the read-only monitor port'
  );
  assert.match(homeViewModelSource, /trafficMonitor\?\.unsubscribe\(this\.trafficMonitorSubscriptionId\);/u,
    'HomeViewModel dispose must clean up the read-only monitor subscription'
  );
});

test('home traffic contract forbids polling, rpc snapshots, notification imports, and monitor lifecycle ownership in home surfaces', async () => {
  const [homePageSource, indexSource, homeViewModelSource] = await Promise.all([
    readUtf8(HOME_PAGE_PATH),
    readUtf8(INDEX_PATH),
    readUtf8(HOME_VIEW_MODEL_PATH)
  ]);

  for (const source of [homePageSource, indexSource, homeViewModelSource]) {
    assertNoPattern(source, /NotificationKit/u, 'home surfaces must not import NotificationKit');
    assertNoPattern(source, /refreshTrafficCounters\(/u, 'home surfaces must not poll traffic counters directly');
    assertNoPattern(source, /GET_SNAPSHOT/u, 'home surfaces must not issue bridge snapshot rpc calls');
  }

  assertNoPattern(homeViewModelSource, /\.start\(/u, 'HomeViewModel must not own monitor start lifecycle');
  assertNoPattern(homeViewModelSource, /\.stop\(/u, 'HomeViewModel must not own monitor stop lifecycle');
  assertNoPattern(homeViewModelSource, /\.markRecovering\(/u, 'HomeViewModel must not own monitor recovery lifecycle');
  assertNoPattern(homeViewModelSource, /\.dispose\(/u, 'HomeViewModel must not dispose the shared monitor');
});
