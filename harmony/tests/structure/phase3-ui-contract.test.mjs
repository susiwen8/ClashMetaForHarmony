import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry');
const ETS_ROOT = path.join(ENTRY_ROOT, 'src', 'main', 'ets');
const RESOURCES_ROOT = path.join(ENTRY_ROOT, 'src', 'main', 'resources');
const COMPONENTS_ROOT = path.join(ETS_ROOT, 'components');
const PAGES_ROOT = path.join(ETS_ROOT, 'pages');

const APPLICATION_COMPOSITION_PATH = path.join(ETS_ROOT, 'bootstrap', 'ApplicationComposition.ets');
const CORE_COMPOSITION_PATH = path.join(ETS_ROOT, 'bootstrap', 'CoreComposition.ets');
const ENTRY_ABILITY_PATH = path.join(ETS_ROOT, 'entryability', 'EntryAbility.ets');
const INDEX_PATH = path.join(PAGES_ROOT, 'Index.ets');
const MAIN_PAGES_PATH = path.join(RESOURCES_ROOT, 'base', 'profile', 'main_pages.json');
const STRING_RESOURCE_PATH = path.join(RESOURCES_ROOT, 'base', 'element', 'string.json');
const BASE_COLOR_RESOURCE_PATH = path.join(RESOURCES_ROOT, 'base', 'element', 'color.json');
const DARK_COLOR_RESOURCE_PATH = path.join(RESOURCES_ROOT, 'dark', 'element', 'color.json');
const FLOAT_RESOURCE_PATH = path.join(RESOURCES_ROOT, 'base', 'element', 'float.json');

const REQUIRED_PAGE_FILES = [
  path.join(PAGES_ROOT, 'HomePage.ets'),
  path.join(PAGES_ROOT, 'ProfilesPage.ets'),
  path.join(PAGES_ROOT, 'ProfileDetailPage.ets'),
  path.join(PAGES_ROOT, 'ImportProfileSheet.ets')
];

const REQUIRED_COMPONENT_FILES = [
  path.join(COMPONENTS_ROOT, 'RuntimeStatusCard.ets'),
  path.join(COMPONENTS_ROOT, 'ProfileListItem.ets'),
  path.join(COMPONENTS_ROOT, 'SafeErrorCard.ets')
];

const REQUIRED_STRING_KEYS = [
  'app_loading',
  'home_title',
  'home_profile_title',
  'home_profile_empty',
  'home_profile_manage',
  'home_runtime_title',
  'home_runtime_status_stopped',
  'home_runtime_status_starting',
  'home_runtime_status_running',
  'home_runtime_status_stopping',
  'home_runtime_status_error',
  'home_runtime_primary_start',
  'home_runtime_primary_stop',
  'home_runtime_primary_busy',
  'home_runtime_missing_profile',
  'home_runtime_http_label',
  'home_runtime_socks_label',
  'home_runtime_local_proxy',
  'profiles_title',
  'profiles_add',
  'profiles_empty_title',
  'profiles_empty_body',
  'profiles_locked_message',
  'profiles_badge_active',
  'profiles_badge_valid',
  'profiles_badge_invalid',
  'profiles_badge_update_failed',
  'import_title',
  'import_name_label',
  'import_name_placeholder',
  'import_url_label',
  'import_url_placeholder',
  'import_file_action',
  'import_url_action',
  'import_submit',
  'import_cancel',
  'import_http_warning_title',
  'import_http_warning_message',
  'import_http_warning_confirm',
  'import_http_warning_cancel',
  'import_progress_import',
  'import_progress_download',
  'import_progress_validation',
  'import_progress_persistence',
  'detail_title',
  'detail_source_kind_file',
  'detail_source_kind_url',
  'detail_source_title',
  'detail_updated_at',
  'detail_enable',
  'detail_refresh',
  'detail_replace',
  'detail_delete',
  'detail_delete_confirm_title',
  'detail_delete_confirm_message',
  'detail_delete_confirm_action',
  'detail_delete_cancel',
  'detail_copy_detail',
  'detail_source_repair_required',
  'error_import',
  'error_download',
  'error_validation',
  'error_persistence',
  'error_core_load',
  'error_runtime_start',
  'error_runtime_stop'
];

const REQUIRED_BASE_COLOR_KEYS = [
  'start_window_background',
  'color_surface_background',
  'color_surface_card',
  'color_surface_subtle',
  'color_text_primary',
  'color_text_secondary',
  'color_text_inverse',
  'color_border_subtle',
  'color_action_primary',
  'color_action_primary_pressed',
  'color_action_primary_disabled',
  'color_status_success',
  'color_status_warning',
  'color_status_danger',
  'color_status_info'
];

const REQUIRED_FLOAT_KEYS = [
  'space_xs',
  'space_sm',
  'space_md',
  'space_lg',
  'space_xl',
  'radius_chip',
  'radius_card',
  'radius_sheet',
  'type_caption',
  'type_body',
  'type_title',
  'type_headline',
  'touch_target_min',
  'page_padding_compact',
  'page_padding_regular'
];

const REQUIRED_SEMANTIC_IDS = [
  'home.profile.manage',
  'home.runtime.primary',
  'profiles.add',
  'import.file',
  'import.url',
  'import.submit',
  'detail.enable',
  'detail.refresh',
  'detail.delete'
];

const BANNED_COPY_TERMS = [
  'VPN',
  'TUN',
  '全局接管',
  '全机代理',
  'traffic',
  '流量',
  'log',
  '日志',
  'provider',
  '提供者',
  'settings',
  '设置'
];

async function readJson(filePath) {
  return JSON.parse(await fs.readFile(filePath, 'utf8'));
}

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function collectResourceNames(document, key) {
  return new Set((document[key] ?? []).map((entry) => entry.name));
}

function assertContainsAll(names, requiredNames, label) {
  for (const requiredName of requiredNames) {
    assert.ok(names.has(requiredName), `${label} must include resource "${requiredName}"`);
  }
}

function assertNoVisibleLiterals(source, filePath) {
  assert.doesNotMatch(source, /[\u4e00-\u9fff]/u, `${filePath} must not embed Chinese UI literals`);
  assert.doesNotMatch(source, /['"`](?:Hello World|Welcome|Start|Stop|Delete|Enable|Import|Download|Running|Stopped)['"`]/u,
    `${filePath} must resolve visible strings from resources instead of inline literals`
  );
}

function assertNoBannedTerms(source, filePath) {
  for (const term of BANNED_COPY_TERMS) {
    assert.doesNotMatch(source, new RegExp(`\\b${term.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')}\\b`, 'u'),
      `${filePath} must not describe the product as ${term}`
    );
  }
}

test('Task 13 production routing exposes only Index and conditional CoreDebugPage, with required native files present', async () => {
  const [mainPages, indexExists, applicationCompositionSource] = await Promise.all([
    readJson(MAIN_PAGES_PATH),
    fileExists(INDEX_PATH),
    readUtf8(APPLICATION_COMPOSITION_PATH)
  ]);

  assert.equal(indexExists, true, 'pages/Index.ets must exist');
  assert.deepEqual(mainPages.src, ['pages/CoreDebugPage', 'pages/Index'].sort(), 'main_pages.json must keep only production Index and CoreDebugPage routes');
  assert.deepEqual([...mainPages.src].sort(), ['pages/CoreDebugPage', 'pages/Index'], 'main_pages.json must keep exactly two routes');

  for (const filePath of [...REQUIRED_PAGE_FILES, ...REQUIRED_COMPONENT_FILES]) {
    assert.equal(await fileExists(filePath), true, `${path.relative(HARMONY_ROOT, filePath)} must exist`);
  }

  assert.match(applicationCompositionSource, /export\s+interface\s+ApplicationComposition/u);
});

test('Task 13 resource files cover the native UI copy, semantic colors, and layout tokens', async () => {
  const [stringResources, baseColors, darkColors, floats] = await Promise.all([
    readJson(STRING_RESOURCE_PATH),
    readJson(BASE_COLOR_RESOURCE_PATH),
    readJson(DARK_COLOR_RESOURCE_PATH),
    readJson(FLOAT_RESOURCE_PATH)
  ]);

  assertContainsAll(collectResourceNames(stringResources, 'string'), REQUIRED_STRING_KEYS, 'base string.json');
  assertContainsAll(collectResourceNames(baseColors, 'color'), REQUIRED_BASE_COLOR_KEYS, 'base color.json');
  assertContainsAll(collectResourceNames(darkColors, 'color'), REQUIRED_BASE_COLOR_KEYS, 'dark color.json');
  assertContainsAll(collectResourceNames(floats, 'float'), REQUIRED_FLOAT_KEYS, 'float.json');
});

test('Task 13 native UI files expose semantic ids, safe layouts, and resource-backed copy only', async () => {
  const productionFiles = [INDEX_PATH, ...REQUIRED_PAGE_FILES, ...REQUIRED_COMPONENT_FILES];
  const sources = await Promise.all(productionFiles.map(async (filePath) => [filePath, await readUtf8(filePath)]));
  const combinedSource = sources.map(([, source]) => source).join('\n');

  for (const semanticId of REQUIRED_SEMANTIC_IDS) {
    assert.match(combinedSource, new RegExp(`\\.id\\(['"\`]${semanticId.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')}['"\`]\\)`, 'u'),
      `production UI must expose semantic id ${semanticId}`
    );
  }
  assert.match(combinedSource, /\.id\(['"`]profiles\.row\.\$\{[^}]+\}['"`]\)/u, 'profile rows must expose dynamic semantic ids');
  assert.match(combinedSource, /\$r\('app\.string\./u, 'production UI must use string resources');
  assert.match(combinedSource, /\$r\('app\.float\./u, 'production UI must use float tokens');
  assert.match(combinedSource, /\$r\('app\.color\./u, 'production UI must use color tokens');
  assert.match(combinedSource, /Navigation/u, 'Index must use native Navigation');
  assert.match(combinedSource, /bindSheet|\.sheet\(/u, 'Profiles must open a native sheet');
  assert.match(combinedSource, /AlertDialog/u, 'detail and HTTP confirmation must use native alerts');
  assert.match(combinedSource, /expandSafeArea|safeAreaPadding/u, 'pages must handle system safe areas');
  assert.match(combinedSource, /onAreaChange|onSizeChange/u, 'pages must adapt padding to portrait width');
  assert.match(combinedSource, /touch_target_min/u, 'interactive targets must honor the minimum 48vp token');

  for (const [filePath, source] of sources) {
    assertNoVisibleLiterals(source, path.relative(HARMONY_ROOT, filePath));
    assertNoBannedTerms(source, path.relative(HARMONY_ROOT, filePath));
  }
});

test('Task 13 lifecycle bridge injects one shared ApplicationComposition into Index and keeps page ownership narrow', async () => {
  const [entryAbilitySource, coreCompositionSource, indexSource] = await Promise.all([
    readUtf8(ENTRY_ABILITY_PATH),
    readUtf8(CORE_COMPOSITION_PATH),
    readUtf8(INDEX_PATH)
  ]);

  assert.match(coreCompositionSource, /const\s+APPLICATION_COMPOSITION_STORAGE_KEY/u);
  assert.match(coreCompositionSource, /export\s+function\s+createApplicationCompositionStorage\s*\(/u);
  assert.match(coreCompositionSource, /export\s+function\s+getApplicationCompositionFromStorage\s*\(/u);

  assert.match(entryAbilitySource, /createApplicationCompositionStorage/u);
  assert.match(entryAbilitySource, /if\s*\(\s*launchContext\.selfTest\s*\)\s*\{[\s\S]*await\s+this\.closeApplicationComposition\(\)[\s\S]*loadContent\(\s*SELF_TEST_ROUTE\s*,\s*\(/u);
  assert.match(entryAbilitySource, /loadContent\(\s*PRODUCTION_ROUTE\s*,\s*storage\s*,\s*\(/u);
  assert.match(entryAbilitySource, /this\.applicationComposition\s*=\s*applicationComposition/u);

  assert.match(indexSource, /this\.getUIContext\(\)\.getSharedLocalStorage\(\)/u);
  assert.match(indexSource, /getApplicationCompositionFromStorage/u);
  assert.match(indexSource, /new\s+HomeViewModel\(/u);
  assert.match(indexSource, /new\s+ProfilesViewModel\(/u);
  assert.match(indexSource, /new\s+ImportProfileViewModel\(/u);
  assert.match(indexSource, /new\s+ProfileDetailViewModel\(/u);
  assert.match(indexSource, /this\.\w+\s*=\s*this\.composition\.subscribe[\s\S]*this\.composition\.state\(\)/u,
    'Index must subscribe before reading composition state to avoid missing READY'
  );
  assert.match(indexSource, /aboutToDisappear\(\):\s*void\s*\{[\s\S]*unsubscribe\(/u);
  assert.match(indexSource, /aboutToDisappear\(\):\s*void\s*\{[\s\S]*dispose\(/u);
  assert.doesNotMatch(indexSource, /createApplicationComposition|PlatformFactory|getContext\(/u,
    'Index must not bootstrap concrete dependencies or fallback to creating the graph'
  );
  assert.doesNotMatch(indexSource, /\.close\(\)/u, 'Index must not own ApplicationComposition teardown');
});

test('Task 13 detail and error surfaces stay redacted and copy only pre-sanitized technical detail', async () => {
  const [detailPageSource, safeErrorCardSource] = await Promise.all([
    readUtf8(path.join(PAGES_ROOT, 'ProfileDetailPage.ets')),
    readUtf8(path.join(COMPONENTS_ROOT, 'SafeErrorCard.ets'))
  ]);

  assert.match(detailPageSource, /technicalDetail/u, 'detail page must render only redacted technical detail');
  assert.match(safeErrorCardSource, /Pasteboard/u, 'SafeErrorCard must use the system pasteboard');
  assert.match(safeErrorCardSource, /technicalDetail/u, 'SafeErrorCard must only copy the passed pre-redacted detail');
  assert.doesNotMatch(safeErrorCardSource, /sourceUrl|yaml|picker|storage/u,
    'SafeErrorCard must not reach into raw source, YAML, picker, or storage data'
  );
});
