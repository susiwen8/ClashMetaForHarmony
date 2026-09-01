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
const PRESENTATION_MODELS_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'presentation', 'PresentationModels.ets');
const HOME_TRAFFIC_CARD_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'components', 'HomeTrafficCard.ets');
const STRING_JSON_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'string.json');

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

test('home traffic contract keeps monitor ownership inside composition and wires a read-only traffic state into home surfaces', async () => {
  const [
    applicationCompositionSource,
    coreCompositionSource,
    indexSource,
    homePageSource,
    homeViewModelSource,
    presentationModelsSource,
    homeTrafficCardSource,
    stringSource
  ] = await Promise.all([
    readUtf8(APPLICATION_COMPOSITION_PATH),
    readUtf8(CORE_COMPOSITION_PATH),
    readUtf8(INDEX_PATH),
    readUtf8(HOME_PAGE_PATH),
    readUtf8(HOME_VIEW_MODEL_PATH),
    readUtf8(PRESENTATION_MODELS_PATH),
    readUtf8(HOME_TRAFFIC_CARD_PATH),
    readUtf8(STRING_JSON_PATH)
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
  assert.match(presentationModelsSource, /export interface HomeTrafficState \{[\s\S]*visible: boolean;[\s\S]*available: boolean;[\s\S]*txBytes: number;[\s\S]*rxBytes: number;[\s\S]*uploadBytesPerSecond: number;[\s\S]*downloadBytesPerSecond: number;[\s\S]*recovering: boolean;[\s\S]*\}/u,
    'presentation models must expose a minimal home traffic state contract'
  );
  assert.match(presentationModelsSource, /export interface HomeViewState \{[\s\S]*traffic: HomeTrafficState;[\s\S]*\}/u,
    'Home view state must expose the nested traffic state'
  );
  assert.match(presentationModelsSource, /export function formatTrafficBytes\(bytes: number\): string/u,
    'presentation models must export a deterministic traffic byte formatter'
  );
  assert.match(homePageSource, /import \{ HomeTrafficCard \} from '\.\.\/components\/HomeTrafficCard';/u,
    'HomePage must render the dedicated traffic card'
  );
  assert.match(homePageSource, /RuntimeStatusCard\([\s\S]*\)\s*\n\s*if \(this\.state\.traffic\.visible\) \{[\s\S]*HomeTrafficCard\(\{[\s\S]*state: this\.state\.traffic[\s\S]*\}\)[\s\S]*\}\s*\n\s*RuntimeModeCard\(/u,
    'HomePage must render the traffic card between status and mode only when traffic is visible'
  );
  assert.match(homeTrafficCardSource, /\.id\('home\.traffic\.card'\)/u,
    'traffic card root semantic id is required'
  );
  assert.match(homeTrafficCardSource, /\.id\('home\.traffic\.upload\.speed'\)/u,
    'traffic upload speed semantic id is required'
  );
  assert.match(homeTrafficCardSource, /\.id\('home\.traffic\.upload\.total'\)/u,
    'traffic upload total semantic id is required'
  );
  assert.match(homeTrafficCardSource, /\.id\('home\.traffic\.download\.speed'\)/u,
    'traffic download speed semantic id is required'
  );
  assert.match(homeTrafficCardSource, /\.id\('home\.traffic\.download\.total'\)/u,
    'traffic download total semantic id is required'
  );
  assert.match(homeTrafficCardSource, /\.id\('home\.traffic\.status'\)/u,
    'traffic status semantic id is required'
  );
  assert.match(homeTrafficCardSource, /\/s/u,
    'traffic speed labels must append /s in the card instead of locale formatting'
  );
  for (const requiredString of [
    'home_traffic_title',
    'home_traffic_upload',
    'home_traffic_download',
    'home_traffic_total',
    'home_traffic_status_recovering',
    'home_traffic_status_unavailable',
    'home_traffic_status_available'
  ]) {
    assert.match(stringSource, new RegExp(`"name": "${requiredString}"`, 'u'),
      `string resource ${requiredString} is required`
    );
  }
  assert.match(indexSource, /createHomeViewState\([\s\S]*createHomeTrafficState\(/u,
    'Index initial and reset state must populate traffic defaults through the state factory'
  );
});

test('home traffic contract forbids polling, rpc snapshots, notification imports, traffic session leakage, and monitor lifecycle ownership in home surfaces', async () => {
  const [homePageSource, indexSource, homeViewModelSource, presentationModelsSource] = await Promise.all([
    readUtf8(HOME_PAGE_PATH),
    readUtf8(INDEX_PATH),
    readUtf8(HOME_VIEW_MODEL_PATH),
    readUtf8(PRESENTATION_MODELS_PATH)
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
  assert.equal(countMatches(homeViewModelSource, /trafficMonitor\.subscribe\(/gu), 1,
    'HomeViewModel must subscribe to the shared traffic read port exactly once'
  );
  assert.equal(countMatches(homeViewModelSource, /trafficMonitor\.unsubscribe\(/gu), 1,
    'HomeViewModel must unsubscribe from the shared traffic read port exactly once'
  );
  assertNoPattern(homeViewModelSource, /traffic\.sessionId/u, 'HomeViewModel traffic state must not contain session identifiers');
  assertNoPattern(presentationModelsSource, /interface HomeTrafficState \{[\s\S]*sessionId/u,
    'presentation traffic state must not expose session identifiers'
  );
});
