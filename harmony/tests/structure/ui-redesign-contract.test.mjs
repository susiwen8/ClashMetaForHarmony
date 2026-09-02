import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry', 'src', 'main');
const ETS_ROOT = path.join(ENTRY_ROOT, 'ets');
const BASE_ELEMENT_ROOT = path.join(ENTRY_ROOT, 'resources', 'base', 'element');
const DARK_ELEMENT_ROOT = path.join(ENTRY_ROOT, 'resources', 'dark', 'element');

const FILES = {
  home: path.join(ETS_ROOT, 'pages', 'HomePage.ets'),
  profiles: path.join(ETS_ROOT, 'pages', 'ProfilesPage.ets'),
  detail: path.join(ETS_ROOT, 'pages', 'ProfileDetailPage.ets'),
  proxies: path.join(ETS_ROOT, 'pages', 'ProxiesPage.ets'),
  logs: path.join(ETS_ROOT, 'pages', 'LogsPage.ets'),
  importSheet: path.join(ETS_ROOT, 'pages', 'ImportProfileSheet.ets'),
  safeError: path.join(ETS_ROOT, 'components', 'SafeErrorCard.ets'),
  baseColors: path.join(BASE_ELEMENT_ROOT, 'color.json'),
  darkColors: path.join(DARK_ELEMENT_ROOT, 'color.json'),
  floats: path.join(BASE_ELEMENT_ROOT, 'float.json')
};

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

async function readJson(filePath) {
  return JSON.parse(await readUtf8(filePath));
}

function resourceNames(document, key) {
  return new Set((document[key] ?? []).map((entry) => entry.name));
}

function assertOrdered(source, needles) {
  let previous = -1;
  for (const needle of needles) {
    const current = source.indexOf(needle);
    assert.notEqual(current, -1, `missing ordered UI marker: ${needle}`);
    assert.ok(current > previous, `UI marker must follow prior task order: ${needle}`);
    previous = current;
  }
}

test('Signal Paper tokens exist in both color modes and centralize visual values', async () => {
  const [baseColors, darkColors, floats] = await Promise.all([
    readJson(FILES.baseColors),
    readJson(FILES.darkColors),
    readJson(FILES.floats)
  ]);
  const requiredColors = [
    'color_surface_hero',
    'color_surface_hero_subtle',
    'color_text_on_hero',
    'color_text_on_hero_secondary',
    'color_signal_active',
    'color_signal_idle'
  ];
  const requiredFloats = ['radius_hero', 'radius_action', 'type_display', 'type_metric'];
  const baseNames = resourceNames(baseColors, 'color');
  const darkNames = resourceNames(darkColors, 'color');
  const floatNames = resourceNames(floats, 'float');

  for (const name of requiredColors) {
    assert.equal(baseNames.has(name), true, `base palette must define ${name}`);
    assert.equal(darkNames.has(name), true, `dark palette must define ${name}`);
  }
  for (const name of requiredFloats) {
    assert.equal(floatNames.has(name), true, `float tokens must define ${name}`);
  }

  const productionSource = (await Promise.all([
    readUtf8(FILES.home),
    readUtf8(FILES.profiles),
    readUtf8(FILES.detail),
    readUtf8(FILES.proxies),
    readUtf8(FILES.logs),
    readUtf8(FILES.importSheet),
    readUtf8(FILES.safeError)
  ])).join('\n');
  assert.doesNotMatch(productionSource, /#[0-9a-f]{6,8}/iu, 'production UI must use resource colors');
});

test('Home puts the complete connection state and action before secondary content', async () => {
  const source = await readUtf8(FILES.home);
  assert.match(source, /@Builder\s+private\s+buildConnectionHero\(\):\s*void/u);
  assert.match(source, /private\s+resolveHeroStatusLabel\(\)/u);
  assert.match(source, /private\s+resolveHeroStatusColor\(\)/u);
  for (const state of ['STOPPED', 'AWAITING_CONSENT', 'STARTING', 'RUNNING', 'RECOVERING', 'STOPPING', 'ERROR']) {
    assert.match(source, new RegExp(`['\"]${state}['\"]`, 'u'), `hero must render ${state}`);
  }
  assert.match(source, /this\.state\.activeProfile\s*===\s*undefined/u, 'hero must render no-profile state');
  assertOrdered(source, [
    'this.buildConnectionHero()',
    "this.state.vpnGlobalCapture.error !== undefined",
    'buildProfileCard(',
    'RuntimeStatusCard({',
    'if (this.state.traffic.visible)',
    'HomeTrafficCard({',
    'RuntimeModeCard({',
    "Button($r('app.string.home_logs_open'))"
  ]);
  assert.match(source, /\.id\('home\.vpn\.action'\)/u);
  assert.match(source, /\.id\('home\.scroll'\)/u);
  assert.match(source, /resolveActionBackground\(this\.state\.vpnGlobalCapture\.action\)/u);
  assert.match(source, /resolveActionForeground\(this\.state\.vpnGlobalCapture\.action\)/u);
});

test('Main screens keep compact, deterministic task order and distinct scroll identities', async () => {
  const [profiles, detail, logs] = await Promise.all([
    readUtf8(FILES.profiles),
    readUtf8(FILES.detail),
    readUtf8(FILES.logs)
  ]);
  assert.match(profiles, /\.id\('profiles\.scroll'\)/u);
  assert.match(detail, /\.id\('detail\.scroll'\)/u);
  assert.match(logs, /\.id\('logs\.list'\)/u);
  assertOrdered(profiles, [
    ".id('profiles.back')",
    "$r('app.string.profiles_title')",
    ".id('profiles.add')",
    ".id('profiles.refresh-all')",
    'ProfileListItem({'
  ]);
  assertOrdered(detail, [
    ".id('detail.back')",
    "$r('app.string.detail_title')",
    "if (!this.state.editing && this.state.canEnable)",
    'this.buildProxyManager()',
    'this.buildEditSurface()',
    ".id('detail.refresh')",
    'this.buildAutoUpdateSurface()',
    ".id('detail.delete')"
  ]);
  assertOrdered(logs, [
    ".id('logs.back')",
    ".id('logs.search')",
    "this.buildFilter('ALL'",
    "$r('app.string.logs_refresh')",
    "$r('app.string.logs_export')",
    "$r('app.string.logs_clear')",
    ".id('logs.list')"
  ]);
});

test('Secondary surfaces stay dense without losing automation or safe callbacks', async () => {
  const [proxies, logs, importSheet, safeError] = await Promise.all([
    readUtf8(FILES.proxies),
    readUtf8(FILES.logs),
    readUtf8(FILES.importSheet),
    readUtf8(FILES.safeError)
  ]);
  for (const marker of [
    ".id('proxies.delay-test')",
    '.id(group.semanticId)',
    '.id(row.semanticId)'
  ]) {
    assert.match(proxies, new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u'));
  }
  assert.doesNotMatch(proxies, /function buildNodeButton[\s\S]*\.border\(\{[\s\S]*color:\s*\$r\('app\.color\.color_border_subtle'\)/u,
    'node rows must use grouped separators instead of one outlined card per node');
  assert.match(logs, /@Prop\s+state:\s*LogsViewState/u);
  assert.match(logs, /onBack:[\s\S]*this\.onBack\(\)/u);
  assert.match(logs, /copyLogEntry\(entry\)/u);
  assert.doesNotMatch(logs, /private\s+buildLogEntry[\s\S]*\.borderRadius\(\$r\('app\.float\.radius_card'\)\)/u,
    'logs must use continuous rows instead of one card per record');

  for (const id of ['import.file', 'import.qr', 'import.url', 'import.submit']) {
    assert.match(importSheet, new RegExp(`\\.id\\(['\"]${id.replace('.', '\\.')}['\"]\\)`, 'u'));
  }
  for (const call of ['requestImportLocal', 'requestScanQr', 'requestImportUrl']) {
    assert.match(importSheet, new RegExp(`this\\.viewModel\\?\\.${call}\\(`, 'u'));
  }
  assert.match(importSheet, /Scroll\(\)/u, 'medium import sheet must own one internal scroll');
  assert.match(safeError, /this\.copyTechnicalDetail\(this\.error\.technicalDetail\)/u);
  assert.doesNotMatch(`${proxies}\n${logs}\n${importSheet}`, /home\.local\.action|Start Local proxy|system proxy/iu);
});
