import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry');
const ETS_ROOT = path.join(ENTRY_ROOT, 'src', 'main', 'ets');
const RESOURCES_ROOT = path.join(ENTRY_ROOT, 'src', 'main', 'resources');
const OHOS_TEST_ROOT = path.join(ENTRY_ROOT, 'src', 'ohosTest');
const OHOS_TEST_ETS_ROOT = path.join(OHOS_TEST_ROOT, 'ets');
const OHOS_TEST_RESOURCES_ROOT = path.join(OHOS_TEST_ROOT, 'resources');
const COMPONENTS_ROOT = path.join(ETS_ROOT, 'components');
const PAGES_ROOT = path.join(ETS_ROOT, 'pages');
const PRESENTATION_MODELS_PATH = path.join(ETS_ROOT, 'presentation', 'PresentationModels.ets');

const APPLICATION_COMPOSITION_PATH = path.join(ETS_ROOT, 'bootstrap', 'ApplicationComposition.ets');
const CORE_COMPOSITION_PATH = path.join(ETS_ROOT, 'bootstrap', 'CoreComposition.ets');
const ENTRY_ABILITY_PATH = path.join(ETS_ROOT, 'entryability', 'EntryAbility.ets');
const INDEX_PATH = path.join(PAGES_ROOT, 'Index.ets');
const MAIN_PAGES_PATH = path.join(RESOURCES_ROOT, 'base', 'profile', 'main_pages.json');
const OHOS_TEST_MODULE_PATH = path.join(OHOS_TEST_ROOT, 'module.json5');
const OHOS_TEST_RUNNER_PATH = path.join(OHOS_TEST_ETS_ROOT, 'testrunner', 'OpenHarmonyTestRunner.ets');
const OHOS_TEST_LIST_PATH = path.join(OHOS_TEST_ETS_ROOT, 'test', 'List.test.ets');
const OHOS_TEST_TESTABILITY_PATH = path.join(OHOS_TEST_ETS_ROOT, 'testability', 'TestAbility.ets');
const OHOS_TEST_PLATFORM_ADAPTERS_PATH = path.join(OHOS_TEST_ETS_ROOT, 'test', 'Phase3PlatformAdapters.test.ets');
const OHOS_TEST_RUNTIME_FLOW_PATH = path.join(OHOS_TEST_ETS_ROOT, 'test', 'Phase3RuntimeFlow.test.ets');
const OHOS_TEST_UI_FLOW_PATH = path.join(OHOS_TEST_ETS_ROOT, 'test', 'Phase3UiFlow.test.ets');
const OHOS_TEST_CANONICAL_FIXTURE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase3-valid.yaml');
const OHOS_TEST_RAWFILE_FIXTURE_PATH = path.join(OHOS_TEST_RESOURCES_ROOT, 'rawfile', 'phase3-valid.yaml');
const OHOS_TEST_PAGES_PATH = path.join(OHOS_TEST_RESOURCES_ROOT, 'base', 'profile', 'test_pages.json');
const STRING_RESOURCE_PATH = path.join(RESOURCES_ROOT, 'base', 'element', 'string.json');
const BASE_COLOR_RESOURCE_PATH = path.join(RESOURCES_ROOT, 'base', 'element', 'color.json');
const DARK_COLOR_RESOURCE_PATH = path.join(RESOURCES_ROOT, 'dark', 'element', 'color.json');
const FLOAT_RESOURCE_PATH = path.join(RESOURCES_ROOT, 'base', 'element', 'float.json');

const REQUIRED_PAGE_FILES = [
  path.join(PAGES_ROOT, 'HomePage.ets'),
  path.join(PAGES_ROOT, 'ProfilesPage.ets'),
  path.join(PAGES_ROOT, 'ProfileDetailPage.ets'),
  path.join(PAGES_ROOT, 'ImportProfileSheet.ets'),
  path.join(PAGES_ROOT, 'ProxiesPage.ets')
];

const REQUIRED_COMPONENT_FILES = [
  path.join(COMPONENTS_ROOT, 'RuntimeStatusCard.ets'),
  path.join(COMPONENTS_ROOT, 'ProfileListItem.ets'),
  path.join(COMPONENTS_ROOT, 'SafeErrorCard.ets')
];

const REQUIRED_STRING_KEYS = [
  'app_loading',
  'home_title',
  'home_subtitle',
  'home_profile_title',
  'home_profile_empty',
  'home_profile_empty_detail',
  'home_profile_manage',
  'home_profile_manage_trailing',
  'detail_proxy_title',
  'detail_proxy_manage',
  'detail_proxy_collapse',
  'detail_proxy_requires_active',
  'home_runtime_primary_busy',
  'home_runtime_listener_placeholder',
  'home_vpn_title',
  'home_vpn_status_stopped',
  'home_vpn_status_awaiting_consent',
  'home_vpn_status_starting',
  'home_vpn_status_running',
  'home_vpn_status_recovering',
  'home_vpn_status_stopping',
  'home_vpn_status_error',
  'home_vpn_primary_start',
  'home_vpn_primary_stop',
  'home_vpn_ipv4_label',
  'home_vpn_ipv6_label',
  'home_vpn_dns_label',
  'home_vpn_mtu_label',
  'home_vpn_notification_label',
  'home_vpn_recovery_label',
  'home_vpn_enabled',
  'home_vpn_disabled',
  'home_vpn_notification_active',
  'home_vpn_notification_inactive',
  'home_vpn_recovery_active',
  'home_vpn_recovery_idle',
  'home_vpn_boundary_note',
  'profiles_title',
  'profiles_add',
  'profiles_empty_title',
  'profiles_empty_body',
  'profiles_badge_active',
  'profiles_badge_valid',
  'profiles_badge_invalid',
  'profiles_badge_update_failed',
  'proxies_title',
  'proxies_back',
  'proxies_loading',
  'proxies_empty',
  'proxies_retry',
  'proxies_selected',
  'proxies_saved_for_next_start',
  'proxies_applied_not_persisted',
  'proxies_nested_group',
  'proxies_error_profile_unavailable',
  'proxies_error_runtime_not_ready',
  'proxies_error_query_failed',
  'proxies_error_selection_stale',
  'proxies_error_selection_failed',
  'proxies_error_persistence_failed',
  'proxies_error_session_changed',
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
  'detail_edit',
  'detail_edit_name_label',
  'detail_edit_url_label',
  'detail_edit_url_hint',
  'detail_edit_cancel',
  'detail_edit_save',
  'detail_edit_issue_required',
  'detail_edit_issue_name_too_long',
  'detail_edit_issue_url_invalid',
  'detail_edit_issue_url_invalid_scheme',
  'detail_enable',
  'detail_refresh',
  'detail_replace',
  'detail_delete',
  'detail_delete_confirm_title',
  'detail_delete_confirm_message',
  'detail_delete_confirm_action',
  'detail_delete_cancel',
  'detail_copy_detail',
  'detail_operation_processing',
  'detail_operation_completed',
  'detail_source_repair_required',
  'error_import',
  'error_download',
  'error_validation',
  'error_persistence',
  'error_core_load',
  'error_runtime_start',
  'error_runtime_stop',
  'error_vpn_permission_denied',
  'error_vpn_already_active',
  'error_vpn_system_revoked',
  'error_vpn_background_task_failed',
  'error_vpn_stop_failed',
  'error_vpn_profile_unavailable',
  'error_vpn_start_failed',
  'error_vpn_recovering'
];

const REQUIRED_BASE_COLOR_KEYS = [
  'start_window_background',
  'color_surface_background',
  'color_surface_card',
  'color_surface_subtle',
  'color_surface_info_panel',
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
  'color_status_info',
  'color_action_disabled_text'
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
  'page_padding_regular',
  'space_2xl'
];

const REQUIRED_SEMANTIC_IDS = [
  'home.profile.manage',
  'detail.proxy.toggle',
  'home.vpn.action',
  'profiles.back',
  'profiles.add',
  'import.file',
  'import.url',
  'import.submit',
  'proxies.back',
  'proxies.retry',
  'detail.back',
  'detail.edit',
  'detail.edit.name',
  'detail.edit.url',
  'detail.edit.cancel',
  'detail.edit.save',
  'detail.enable',
  'detail.operation.pending',
  'detail.operation.completed',
  'detail.refresh',
  'detail.delete'
];

const REQUIRED_OHOS_TEST_SUITES = [
  'Phase3PlatformAdapters',
  'Phase3RuntimeFlow',
  'Phase3UiFlow'
];

const PHASE3_VALID_YAML = `mode: rule
mixed-port: 7890
rules:
  - MATCH,DIRECT
`;

const BANNED_COPY_TERMS = [
  'system proxy',
  'global HTTP proxy',
  'always-on',
  'lockdown',
  'enterprise',
  '系统代理',
  '全局 HTTP 代理',
  '常驻 VPN',
  '锁定模式',
  '企业专用'
];

const APPROVED_BOUNDARY_STRING_VALUES = new Map([
  ['home_vpn_boundary_note', 'TUN capture is limited to traffic handled by this app session.']
]);

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

function getStringValue(document, key) {
  const entry = (document.string ?? []).find((candidate) => candidate.name === key);
  return entry?.value;
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

  const stringResourceNames = collectResourceNames(stringResources, 'string');

  assertContainsAll(stringResourceNames, REQUIRED_STRING_KEYS, 'base string.json');
  assertContainsAll(collectResourceNames(baseColors, 'color'), REQUIRED_BASE_COLOR_KEYS, 'base color.json');
  assertContainsAll(collectResourceNames(darkColors, 'color'), REQUIRED_BASE_COLOR_KEYS, 'dark color.json');
  assertContainsAll(collectResourceNames(floats, 'float'), REQUIRED_FLOAT_KEYS, 'float.json');

  for (const [key, value] of APPROVED_BOUNDARY_STRING_VALUES) {
    assert.equal(getStringValue(stringResources, key), value, `string.json key ${key} must stay exact`);
  }
  assert.equal(
    getStringValue(stringResources, 'detail_edit_issue_name_too_long'),
    '名称长度不能超过 80 个字符',
    'detail_edit_issue_name_too_long must match the 80-character validator limit'
  );
  assert.equal(
    [...stringResourceNames].some((name) => name.startsWith('home_local_')),
    false,
    'base string.json must not publish deprecated home_local_* product resources'
  );
  for (const forbiddenKey of ['profiles_locked_message', 'error_vpn_requires_local_stop', 'error_local_blocked_by_vpn']) {
    assert.equal(stringResourceNames.has(forbiddenKey), false, `base string.json must not publish ${forbiddenKey}`);
  }
  for (const forbiddenKey of [
    'home_runtime_title',
    'home_runtime_status_stopped',
    'home_runtime_status_starting',
    'home_runtime_status_running',
    'home_runtime_status_stopping',
    'home_runtime_status_error',
    'home_runtime_primary_start',
    'home_runtime_primary_stop',
    'home_runtime_missing_profile'
  ]) {
    assert.equal(stringResourceNames.has(forbiddenKey), false, `base string.json must not publish removed runtime copy ${forbiddenKey}`);
  }
  assert.equal(getStringValue(stringResources, 'error_runtime_start'), '启动运行服务失败',
    'error_runtime_start must stay runtime-neutral'
  );
  assert.equal(getStringValue(stringResources, 'error_runtime_stop'), '停止运行服务失败',
    'error_runtime_stop must stay runtime-neutral'
  );
  const stringValues = (stringResources.string ?? []).map((entry) => `${entry.value ?? ''}`).join('\n');
  for (const term of BANNED_COPY_TERMS) {
    assert.doesNotMatch(stringValues, new RegExp(`\\b${term.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')}\\b`, 'u'),
      `string resources must not claim forbidden networking scope: ${term}`
    );
  }
});

test('Task 13 native UI files expose semantic ids, safe layouts, and resource-backed copy only', async () => {
  const productionFiles = [INDEX_PATH, ...REQUIRED_PAGE_FILES, ...REQUIRED_COMPONENT_FILES];
  const [sources, presentationModelsSource] = await Promise.all([
    Promise.all(productionFiles.map(async (filePath) => [filePath, await readUtf8(filePath)])),
    readUtf8(PRESENTATION_MODELS_PATH)
  ]);
  const combinedSource = sources.map(([, source]) => source).join('\n');
  const homePageSource = sources.find(([filePath]) => filePath.endsWith('HomePage.ets'))?.[1] ?? '';
  const indexSource = sources.find(([filePath]) => filePath.endsWith('Index.ets'))?.[1] ?? '';
  const profilesPageSource = sources.find(([filePath]) => filePath.endsWith('ProfilesPage.ets'))?.[1] ?? '';
  const detailPageSource = sources.find(([filePath]) => filePath.endsWith('ProfileDetailPage.ets'))?.[1] ?? '';
  const proxiesPageSource = sources.find(([filePath]) => filePath.endsWith('ProxiesPage.ets'))?.[1] ?? '';
  const runtimeStatusCardSource = sources.find(([filePath]) => filePath.endsWith('RuntimeStatusCard.ets'))?.[1] ?? '';

  for (const semanticId of REQUIRED_SEMANTIC_IDS) {
    assert.match(combinedSource, new RegExp(`\\.id\\(['"\`]${semanticId.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')}['"\`]\\)`, 'u'),
      `production UI must expose semantic id ${semanticId}`
    );
  }
  assert.match(combinedSource, /\.id\(['"`]profiles\.row\.\$\{[^}]+\}['"`]\)/u, 'profile rows must expose dynamic semantic ids');
  assert.match(proxiesPageSource, /\.id\(group\.semanticId\)/u, 'proxy group chips must expose index-only semantic ids');
  assert.match(proxiesPageSource, /\.id\(row\.semanticId\)/u, 'proxy node rows must expose index-only semantic ids');
  assert.match(proxiesPageSource, /\.id\(`\$\{row\.semanticId\}\.runtime-selected`\)/u, 'proxy selected markers must use the runtime-selected suffix');
  assert.match(proxiesPageSource, /\.id\(`\$\{row\.semanticId\}\.saved-intent`\)/u, 'proxy saved markers must use the saved-intent suffix');
  assert.match(proxiesPageSource, /\.id\(`\$\{row\.semanticId\}\.nested-group`\)/u, 'proxy nested-group markers must use the nested-group suffix');
  assert.match(proxiesPageSource, /Text\(row\.name\)[\s\S]*\.id\(`\$\{row\.semanticId\}\.label`\)/u, 'proxy node labels must expose a stable private-layout extraction id');
  assert.match(combinedSource, /\$r\('app\.string\./u, 'production UI must use string resources');
  assert.match(combinedSource, /\$r\('app\.float\./u, 'production UI must use float tokens');
  assert.match(combinedSource, /\$r\('app\.color\./u, 'production UI must use color tokens');
  assert.match(combinedSource, /Navigation/u, 'Index must use native Navigation');
  assert.match(combinedSource, /bindSheet|\.sheet\(/u, 'Profiles must open a native sheet');
  assert.match(combinedSource, /AlertDialog/u, 'detail and HTTP confirmation must use native alerts');
  assert.match(combinedSource, /expandSafeArea|safeAreaPadding/u, 'pages must handle system safe areas');
  assert.match(combinedSource, /onAreaChange|onSizeChange/u, 'pages must adapt padding to portrait width');
  assert.match(combinedSource, /touch_target_min/u, 'interactive targets must honor the minimum 48vp token');
  assert.match(homePageSource, /\.width\('100%'\)[\s\S]*\.height\('100%'\)/u, 'HomePage root must fill the parent stack');
  assert.match(homePageSource, /justifyContent\(FlexAlign\.Start\)|align\(Alignment\.TopStart\)/u, 'HomePage root must start from the top');
  assert.match(homePageSource, /backgroundColor\(\$r\('app\.color\.color_surface_background'\)\)/u, 'HomePage must use the semantic page background');
  assert.match(homePageSource, /scrollBar\(BarState\.Off\)/u, 'HomePage scroll view must hide the visible scroll bar');
  assert.match(homePageSource, /\$r\('app\.string\.home_subtitle'\)/u, 'HomePage must show the resource-backed subtitle');
  assert.match(homePageSource, /\$r\('app\.string\.home_profile_empty_detail'\)/u, 'HomePage must show the empty profile helper copy');
  assert.match(homePageSource, /\$r\('app\.string\.home_profile_manage_trailing'\)/u, 'HomePage must render the trailing manage affordance through resources');
  assert.match(homePageSource, /Text\(\$r\('app\.string\.home_profile_title'\)\)[\s\S]*\.fontSize\(\$r\('app\.float\.type_caption'\)\)[\s\S]*\.fontColor\(\$r\('app\.color\.color_text_secondary'\)\)[\s\S]*\.width\('100%'\)[\s\S]*\.textAlign\(TextAlign\.Start\)/u,
    'home_profile_title must stay a left-aligned secondary caption'
  );
  assert.match(homePageSource, /\.padding\(\$r\('app\.float\.page_padding_compact'\)\)/u, 'HomePage should use the compact 16vp page padding for the visual baseline');
  assert.doesNotMatch(homePageSource, /home_info_(title|body|indicator)/u,
    'HomePage must remove the deprecated bottom info panel copy'
  );
  assert.doesNotMatch(homePageSource, /\.id\('home\.proxy\.manage'\)/u, 'HomePage must not keep the merged proxy management action');
  assert.doesNotMatch(homePageSource, /\.id\('home\.local\.action'\)/u, 'HomePage must not expose a standalone local proxy action');
  assert.match(homePageSource, /\.id\('home\.vpn\.action'\)/u, 'HomePage must own the VPN global capture action');
  assert.match(detailPageSource, /\$r\('app\.string\.detail_proxy_title'\)/u, 'ProfileDetailPage must render the proxy management title through resources');
  assert.match(detailPageSource, /\$r\('app\.string\.detail_proxy_requires_active'\)/u, 'ProfileDetailPage must render the inactive-profile helper copy through resources');
  assert.match(detailPageSource, /Button\(\$r\('app\.string\.detail_edit'\)\)[\s\S]*\.id\('detail\.edit'\)/u,
    'ProfileDetailPage must expose the non-editing edit action'
  );
  assert.match(detailPageSource, /Text\(\$r\('app\.string\.detail_edit_name_label'\)\)/u,
    'ProfileDetailPage must render the edit-name label through resources'
  );
  assert.match(detailPageSource, /TextInput\(\{[\s\S]*text:\s*this\.viewModel\?\.currentEditNameDraft\(\)\s*\?\?\s*''[\s\S]*\}\)[\s\S]*\.id\('detail\.edit\.name'\)/u,
    'ProfileDetailPage must bind the edit-name TextInput to the view-model draft getter and semantic id'
  );
  assert.match(detailPageSource, /this\.viewModel\?\.updateEditNameDraft\(value\)/u,
    'ProfileDetailPage must send name draft edits through the view model'
  );
  assert.match(detailPageSource, /Button\(\$r\('app\.string\.detail_edit_cancel'\)\)[\s\S]*\.id\('detail\.edit\.cancel'\)[\s\S]*\.onClick\(\(\)\s*=>\s*\{\s*this\.viewModel\?\.cancelEdit\(\);\s*\}\)/u,
    'ProfileDetailPage must expose the edit cancel action through cancelEdit'
  );
  assert.match(detailPageSource, /Button\(\$r\('app\.string\.detail_edit_save'\)\)[\s\S]*\.id\('detail\.edit\.save'\)[\s\S]*\.onClick\(\(\)\s*=>\s*\{\s*void this\.viewModel\?\.requestSaveEdits\(\);\s*\}\)/u,
    'ProfileDetailPage must expose the edit save action through requestSaveEdits'
  );
  assert.match(detailPageSource, /if\s*\(\s*this\.state\.profile\?\.sourceKind === 'REMOTE_URL'\s*\)[\s\S]*\.id\('detail\.edit\.url'\)/u,
    'ProfileDetailPage must expose the edit URL field only for remote profiles'
  );
  assert.match(detailPageSource, /TextInput\(\{[\s\S]*text:\s*this\.viewModel\?\.currentEditUrlDraft\(\)\s*\?\?\s*''[\s\S]*placeholder:\s*\$r\('app\.string\.import_url_placeholder'\)[\s\S]*\}\)[\s\S]*\.id\('detail\.edit\.url'\)/u,
    'ProfileDetailPage must bind the edit URL TextInput to the blank-preserving draft getter and semantic id'
  );
  assert.match(detailPageSource, /this\.viewModel\?\.updateEditUrlDraft\(value\)/u,
    'ProfileDetailPage must send URL draft edits through the view model'
  );
  assert.match(detailPageSource, /\$r\('app\.string\.detail_edit_url_hint'\)/u,
    'ProfileDetailPage must show the edit URL preservation hint through resources'
  );
  assert.match(detailPageSource, /resolveDetailEditNameIssue\(this\.state\.editNameIssue\)/u,
    'ProfileDetailPage must render edit-name validation from state.editNameIssue'
  );
  assert.match(detailPageSource, /resolveDetailEditUrlIssue\(this\.state\.editUrlIssue\)/u,
    'ProfileDetailPage must render edit-URL validation from state.editUrlIssue'
  );
  assert.doesNotMatch(detailPageSource, /onRequestReplaceSubscriptionUrl|currentReplacementUrlDraft|updateReplacementUrlDraft/u,
    'ProfileDetailPage must remove the separate replacement URL form wiring'
  );
  assert.doesNotMatch(detailPageSource, /\.id\('detail\.replace'\)/u,
    'ProfileDetailPage must remove the dedicated detail.replace control from production UI'
  );
  assert.match(detailPageSource, /if\s*\(\s*this\.state\.editing\s*\)[\s\S]*Button\(\$r\('app\.string\.detail_edit_cancel'\)\)/u,
    'ProfileDetailPage must switch into an editing surface when state.editing is true'
  );
  assert.match(detailPageSource, /if\s*\(\s*!this\.state\.editing\s*\)[\s\S]*this\.buildProxyManager\(\)/u,
    'ProfileDetailPage must hide proxy management while editing'
  );
  assert.match(detailPageSource, /if\s*\(\s*!this\.state\.editing && this\.state\.canEnable\s*\)/u,
    'ProfileDetailPage must hide enable while editing'
  );
  assert.match(detailPageSource, /if\s*\(\s*!this\.state\.editing && this\.state\.canRefresh\s*\)/u,
    'ProfileDetailPage must hide refresh while editing'
  );
  assert.match(detailPageSource, /if\s*\(\s*!this\.state\.editing && this\.state\.canDelete\s*\)/u,
    'ProfileDetailPage must hide delete while editing'
  );
  assert.match(homePageSource, /resolveActionBackground\(this\.state\.vpnGlobalCapture\.action\)/u, 'HomePage must keep the VPN action background stateful');
  assert.match(homePageSource, /resolveActionForeground\(this\.state\.vpnGlobalCapture\.action\)/u, 'HomePage must keep the VPN action text color stateful');
  assert.doesNotMatch(homePageSource, /\blocalProxy\b/u, 'HomePage must not bind product copy or actions to a localProxy home state');
  assert.match(profilesPageSource, /onBack:\s*\(\)\s*=>\s*void\s*=\s*\(\)\s*=>\s*\{\s*\}/u,
    'ProfilesPage must expose an onBack callback'
  );
  assert.match(profilesPageSource, /Row\(\{\s*space:\s*\$r\('app\.float\.space_md'\)\s*\}\)/u,
    'ProfilesPage header must use the medium horizontal spacing token'
  );
  assert.match(profilesPageSource, /Button\(\$r\('app\.string\.common_back'\)\)[\s\S]*\.id\('profiles\.back'\)[\s\S]*\.constraintSize\(\{\s*minHeight:\s*\$r\('app\.float\.touch_target_min'\)\s*\}\)[\s\S]*\.backgroundColor\(\$r\('app\.color\.color_surface_card'\)\)[\s\S]*\.fontColor\(\$r\('app\.color\.color_text_primary'\)\)[\s\S]*\.onClick\(\(\)\s*=>\s*\{\s*this\.onBack\(\);\s*\}\)/u,
    'ProfilesPage back button must use common_back, semantic id profiles.back, touch target, semantic colors, and call onBack'
  );
  assert.match(profilesPageSource, /Text\(\$r\('app\.string\.profiles_title'\)\)[\s\S]*\.layoutWeight\(1\)[\s\S]*\.textAlign\(TextAlign\.Start\)[\s\S]*\.maxLines\(1\)[\s\S]*\.textOverflow\(\{\s*overflow:\s*TextOverflow\.Ellipsis\s*\}\)/u,
    'ProfilesPage title must keep the weighted single-line ellipsis layout'
  );
  assert.match(profilesPageSource, /Button\(\$r\('app\.string\.profiles_add'\)\)[\s\S]*\.id\('profiles\.add'\)[\s\S]*\.constraintSize\(\{\s*minHeight:\s*\$r\('app\.float\.touch_target_min'\)\s*\}\)/u,
    'ProfilesPage add button must keep its semantic id and minimum touch target'
  );
  assert.match(indexSource, /ProfilesPage\(\{[\s\S]*onBack:\s*\(\)\s*=>\s*\{\s*this\.route\s*=\s*'HOME';\s*\}[\s\S]*\}\)/u,
    'Index must wire ProfilesPage onBack to return to HOME'
  );
  assert.match(indexSource, /@State\s+private\s+detailCommandPending:\s*boolean\s*=\s*false/u,
    'Index must keep a primitive detailCommandPending @State flag'
  );
  assert.match(indexSource, /@State\s+private\s+detailCommandCompleted:\s*boolean\s*=\s*false/u,
    'Index must keep a primitive detailCommandCompleted @State flag'
  );
  assert.match(indexSource, /this\.profileDetailSubscriptionId\s*=\s*this\.profileDetailViewModel\.subscribe\(\(state:\s*ProfileDetailViewState\):\s*void\s*=>\s*\{[\s\S]*this\.detailState\s*=\s*state[\s\S]*this\.detailCommandPending\s*=\s*state\.status\s*===\s*'SUBMITTING'[\s\S]*this\.detailCommandCompleted\s*=\s*state\.status\s*===\s*'COMPLETED'/u,
    'Index must project commandPending and commandCompleted from each subscribed detail state status'
  );
  assert.match(indexSource, /this\.detailState\s*=\s*this\.profileDetailViewModel\.current\(\)[\s\S]*this\.detailCommandPending\s*=\s*this\.detailState\.status\s*===\s*'SUBMITTING'[\s\S]*this\.detailCommandCompleted\s*=\s*this\.detailState\.status\s*===\s*'COMPLETED'/u,
    'Index must project the initial current() detail state status into primitive flags'
  );
  assert.match(indexSource, /private\s+disposeDetailViewModel\(\):\s*void\s*\{[\s\S]*this\.detailCommandPending\s*=\s*false[\s\S]*this\.detailCommandCompleted\s*=\s*false/u,
    'disposeDetailViewModel must reset the projected detail command flags'
  );
  assert.match(indexSource, /ProfileDetailPage\(\{[\s\S]*commandPending:\s*\$detailCommandPending[\s\S]*commandCompleted:\s*\$detailCommandCompleted[\s\S]*\}\)/u,
    'Index must pass detail command flags into ProfileDetailPage as @Link bindings'
  );
  assert.match(proxiesPageSource, /\$r\('app\.string\.proxies_title'\)/u, 'ProxiesPage must render the proxy page title through resources');
  assert.match(proxiesPageSource, /\.scrollBar\(BarState\.Off\)/u, 'ProxiesPage must hide visible scroll bars');
  assert.match(proxiesPageSource, /touch_target_min/u, 'ProxiesPage actions must honor the minimum touch target token');
  assert.doesNotMatch(runtimeStatusCardSource, /\.id\('home\.local\.action'\)|\.id\('home\.vpn\.action'\)/u, 'RuntimeStatusCard must not own page actions');
  assert.match(runtimeStatusCardSource, /\$r\('app\.string\.home_vpn_ipv4_label'\)/u, 'RuntimeStatusCard must render VPN IPv4 facts');
  assert.match(runtimeStatusCardSource, /\$r\('app\.string\.home_vpn_ipv6_label'\)/u, 'RuntimeStatusCard must render VPN IPv6 facts');
  assert.match(runtimeStatusCardSource, /\$r\('app\.string\.home_vpn_dns_label'\)/u, 'RuntimeStatusCard must render VPN DNS facts');
  assert.match(runtimeStatusCardSource, /\$r\('app\.string\.home_vpn_mtu_label'\)/u, 'RuntimeStatusCard must render VPN MTU facts');
  assert.match(runtimeStatusCardSource, /\$r\('app\.string\.home_vpn_notification_label'\)/u, 'RuntimeStatusCard must render notification status');
  assert.match(runtimeStatusCardSource, /\$r\('app\.string\.home_vpn_recovery_label'\)/u, 'RuntimeStatusCard must render recovery status');
  assert.match(runtimeStatusCardSource, /\$r\('app\.string\.home_runtime_listener_placeholder'\)/u, 'RuntimeStatusCard must show a resource-backed placeholder when listener addresses are missing');
  assert.match(runtimeStatusCardSource, /\$r\('app\.string\.home_vpn_boundary_note'\)/u, 'RuntimeStatusCard must render the VPN boundary note');
  assert.match(runtimeStatusCardSource, /\$r\('app\.string\.home_vpn_status_stopped'\)|\$r\('app\.string\.home_vpn_status_running'\)|\$r\('app\.string\.home_vpn_status_recovering'\)/u,
    'RuntimeStatusCard must render resource-backed VPN status labels'
  );
  assert.doesNotMatch(runtimeStatusCardSource, /home_local_[A-Za-z0-9_]+/u, 'RuntimeStatusCard must not expose deprecated local-only home resources');
  assert.match(runtimeStatusCardSource, /Divider\(/u, 'RuntimeStatusCard must use dividers to separate status, listener rows, and boundary note');
  assert.match(runtimeStatusCardSource, /\.padding\(\$r\('app\.float\.space_md'\)\)/u, 'RuntimeStatusCard should use the denser card padding for the 360x780 baseline');
  assert.doesNotMatch(presentationModelsSource, /\blocalProxy\b/u, 'PresentationModels must not publish a localProxy home state');
  assert.match(presentationModelsSource, /export function resolveNameIssue\(rawName: string, required: boolean\): 'REQUIRED' \| 'TOO_LONG' \| undefined \{[\s\S]*trimmed\.length > 80[\s\S]*return 'TOO_LONG';/u,
    'Profile name validation semantics must keep the 80-character limit that the UI copy describes'
  );
  assert.match(detailPageSource, /@Link\s+commandPending:\s*boolean/u,
    'ProfileDetailPage must expose commandPending as an @Link primitive'
  );
  assert.match(detailPageSource, /@Link\s+commandCompleted:\s*boolean/u,
    'ProfileDetailPage must expose commandCompleted as an @Link primitive'
  );
  assert.match(detailPageSource, /this\.buildOperationFeedback\(\)/u,
    'ProfileDetailPage must render operation feedback through a zero-arg member builder'
  );
  assert.match(detailPageSource, /private\s+buildOperationFeedback\(\):\s*void/u,
    'ProfileDetailPage must define operation feedback as a private member builder'
  );
  assert.match(detailPageSource, /@Builder[\s\S]*private\s+buildOperationFeedback\(\):\s*void\s*\{[\s\S]*if\s*\(\s*this\.commandPending\s*\)[\s\S]*Text\(\$r\('app\.string\.detail_operation_processing'\)\)[\s\S]*\.id\('detail\.operation\.pending'\)[\s\S]*\.fontColor\(\$r\('app\.color\.color_status_warning'\)\)/u,
    'ProfileDetailPage pending feedback must use the processing resource, pending semantic id, and warning color'
  );
  assert.match(detailPageSource, /@Builder[\s\S]*private\s+buildOperationFeedback\(\):\s*void\s*\{[\s\S]*else\s+if\s*\(\s*this\.commandCompleted\s*\)[\s\S]*Text\(\$r\('app\.string\.detail_operation_completed'\)\)[\s\S]*\.id\('detail\.operation\.completed'\)[\s\S]*\.fontColor\(\$r\('app\.color\.color_status_success'\)\)/u,
    'ProfileDetailPage completed feedback must use the completed resource, completed semantic id, and success color'
  );
  assert.match(detailPageSource, /if\s*\(\s*this\.commandPending\s*\)[\s\S]*else\s+if\s*\(\s*this\.commandCompleted\s*\)/u,
    'ProfileDetailPage feedback must render pending/completed mutually exclusively'
  );
  for (const controlId of ['detail.edit.cancel', 'detail.edit.save', 'detail.enable', 'detail.refresh', 'detail.delete']) {
    assert.match(detailPageSource, new RegExp(`\\.id\\(['"\`]${controlId.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')}['"\`]\\)[\\s\\S]*\\.enabled\\(!this\\.commandPending\\)`, 'u'),
      `${controlId} must be disabled while a detail command is pending`
    );
  }
  assert.match(detailPageSource, /TextInput\(\{[\s\S]*currentEditNameDraft\(\)[\s\S]*\}\)[\s\S]*\.enabled\(!this\.commandPending\)/u,
    'edit-name TextInput must be disabled while a detail command is pending'
  );
  assert.match(detailPageSource, /TextInput\(\{[\s\S]*currentEditUrlDraft\(\)[\s\S]*\}\)[\s\S]*\.enabled\(!this\.commandPending\)/u,
    'edit-url TextInput must be disabled while a detail command is pending'
  );
  assert.match(detailPageSource, /Button\(\$r\('app\.string\.common_back'\)\)[\s\S]*\.constraintSize\(\{\s*minHeight:\s*\$r\('app\.float\.touch_target_min'\)\s*\}\)[\s\S]*\.backgroundColor\(\$r\('app\.color\.color_surface_subtle'\)\)[\s\S]*\.fontColor\(\$r\('app\.color\.color_text_primary'\)\)[\s\S]*\.onClick\(\(\)\s*=>\s*\{\s*this\.onBack\(\);\s*\}\)/u,
    'Back must stay available while detail commands are pending'
  );
  assert.match(detailPageSource, /SafeErrorCard\(\{[\s\S]*\}\)/u,
    'ProfileDetailPage must keep the SafeErrorCard source intact'
  );
  assert.match(indexSource, /AlertDialog\.show\(\{[\s\S]*detail_delete_confirm_title[\s\S]*detail_delete_confirm_action/u,
    'Index must keep the native delete confirmation alert flow intact'
  );
  assert.match(indexSource, /AlertDialog\.show\(\{[\s\S]*import_http_warning_title[\s\S]*import_http_warning_confirm/u,
    'Index must keep the native HTTP warning alert flow intact'
  );
  assert.match(indexSource, /synchronizeDetailHttpAlert\(state: ProfileDetailViewState\): void[\s\S]*confirmPlainHttpAction\(\)/u,
    'Index detail HTTP confirmation must route through confirmPlainHttpAction'
  );
  assert.doesNotMatch(indexSource, /replaceHttpAlertOpen|requestReplaceSubscriptionUrl\(/u,
    'Index must remove the production-only replacement URL HTTP alert wiring'
  );

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
  assert.match(indexSource, /private\s+detailViewModelProfileId\??:\s*string/u,
    'Index must track the profile id bound to the current detail view model'
  );
  assert.match(indexSource, /private\s+openDetailRoute\(profileId:\s*string\):\s*void\s*\{[\s\S]*this\.ensureDetailViewModel\(profileId\)[\s\S]*this\.detailProfileId\s*=\s*profileId[\s\S]*this\.route\s*=\s*'DETAIL'/u,
    'Index must create or reuse the correct detail view model before publishing the selected detail profile id'
  );
  assert.doesNotMatch(indexSource, /private\s+openDetailRoute\(profileId:\s*string\):\s*void\s*\{[\s\S]*this\.detailProfileId\s*=\s*profileId[\s\S]*this\.ensureDetailViewModel\(profileId\)/u,
    'Index must not mark the new profile id before deciding whether the existing detail view model matches'
  );
  assert.doesNotMatch(indexSource, /if\s*\(\s*this\.profileDetailViewModel\s*!==\s*undefined\s*&&\s*this\.detailProfileId\s*===\s*profileId\s*\)/u,
    'Index must not use the published route id to decide whether the existing detail view model can be reused'
  );
  assert.match(indexSource, /this\.\w+\s*=\s*this\.composition\.subscribe[\s\S]*this\.composition\.state\(\)/u,
    'Index must subscribe before reading composition state to avoid missing READY'
  );
  assert.match(indexSource, /aboutToDisappear\(\):\s*void\s*\{[\s\S]*unsubscribe\(/u);
  assert.match(indexSource, /aboutToDisappear\(\):\s*void\s*\{[\s\S]*dispose\(/u);
  assert.doesNotMatch(indexSource, /createApplicationComposition|PlatformFactory|getContext\(/u,
    'Index must not bootstrap concrete dependencies or fallback to creating the graph'
  );
  assert.doesNotMatch(indexSource, /\.close\(\)/u, 'Index must not own ApplicationComposition teardown');
  assert.doesNotMatch(indexSource, /safeRemoteHostFromUrl|rawUrl: string = this\.profileDetailViewModel\?\.currentReplacementUrlDraft/u,
    'Index must remove the replacement-draft HTTP host sanitizing path after consolidating profile editing'
  );
});

test('Task 13 detail and error surfaces stay redacted and copy only pre-sanitized technical detail', async () => {
  const [detailPageSource, safeErrorCardSource] = await Promise.all([
    readUtf8(path.join(PAGES_ROOT, 'ProfileDetailPage.ets')),
    readUtf8(path.join(COMPONENTS_ROOT, 'SafeErrorCard.ets'))
  ]);

  assert.match(detailPageSource, /technicalDetail/u, 'detail page must render only redacted technical detail');
  assert.match(safeErrorCardSource, /Pasteboard/u, 'SafeErrorCard must use the system pasteboard');
  assert.match(safeErrorCardSource, /technicalDetail/u, 'SafeErrorCard must only copy the passed pre-redacted detail');
  assert.match(safeErrorCardSource, /try\s*\{[\s\S]*Pasteboard\.getSystemPasteboard\(\)[\s\S]*Pasteboard\.createData\([\s\S]*setData\(/u,
    'SafeErrorCard must guard pasteboard access behind a synchronous try block'
  );
  assert.match(safeErrorCardSource, /setData\([\s\S]*\.catch\(/u,
    'SafeErrorCard must swallow rejected pasteboard writes so copy failures cannot crash the page'
  );
  assert.doesNotMatch(safeErrorCardSource, /sourceUrl|yaml|picker|storage/u,
    'SafeErrorCard must not reach into raw source, YAML, picker, or storage data'
  );
});

test('Task 14 isolated Simulator test bundle registers an entry_test runner with deterministic suite order', async () => {
  const [moduleSource, runnerSource, listSource, pagesSource, testabilitySource] = await Promise.all([
    readUtf8(OHOS_TEST_MODULE_PATH),
    readUtf8(OHOS_TEST_RUNNER_PATH),
    readUtf8(OHOS_TEST_LIST_PATH),
    readUtf8(OHOS_TEST_PAGES_PATH),
    readUtf8(OHOS_TEST_TESTABILITY_PATH)
  ]);

  assert.match(moduleSource, /"name"\s*:\s*"entry_test"/u, 'ohosTest module must register the SDK entry_test test module name');
  assert.match(moduleSource, /"type"\s*:\s*"feature"/u, 'ohosTest module must keep the SDK feature module type');
  assert.match(moduleSource, /"deviceTypes"\s*:\s*\[\s*"phone"\s*\]/u, 'ohosTest module must stay phone-only');
  assert.match(moduleSource, /"srcEntry"\s*:\s*"\.\/ets\/testability\/TestAbility\.ets"/u,
    'ohosTest module must point the test ability at ets/testability/TestAbility.ets'
  );
  assert.doesNotMatch(moduleSource, /"exported"\s*:\s*true/u, 'ohosTest test ability must not be exported');
  assert.match(moduleSource, /"testRunner"\s*:\s*\{[\s\S]*"name"\s*:\s*"OpenHarmonyTestRunner"/u,
    'ohosTest module must bind the Hypium runner by class name'
  );
  assert.match(moduleSource, /"testRunner"\s*:\s*\{[\s\S]*"srcPath"\s*:\s*"\.\/ets\/testrunner\/OpenHarmonyTestRunner\.ets"/u,
    'ohosTest module must bind the runner source entrypoint'
  );
  assert.match(moduleSource, /"pages"\s*:\s*"\$profile:test_pages"/u, 'ohosTest module must use test_pages only');
  assert.match(runnerSource, /implements\s+TestRunner/u, 'OpenHarmonyTestRunner must implement the SDK TestRunner contract');
  assert.match(runnerSource, /List\.test/u, 'OpenHarmonyTestRunner must load List.test.ets');
  assert.match(runnerSource, /await\s+waitForTask14Completion(?:OrTimeout)?\(/u,
    'OpenHarmonyTestRunner must await the Task 14 completion barrier after registering Hypium tests'
  );
  assert.match(runnerSource, /TIMEOUT|timeout/u,
    'OpenHarmonyTestRunner must enforce a bounded completion timeout'
  );
  assert.match(runnerSource, /finally[\s\S]*reject\(/u,
    'OpenHarmonyTestRunner timeout handling must reject from a finally path even if evidence flushing throws'
  );
  assert.match(runnerSource, /getEvidence\(/u,
    'OpenHarmonyTestRunner must inspect final evidence after the completion barrier resolves'
  );
  assert.match(runnerSource, /status\s*!==\s*['"`]PASS['"`][\s\S]*failures\.length\s*>\s*0/u,
    'OpenHarmonyTestRunner must reject unless final evidence reports PASS with zero failures'
  );
  assert.match(runnerSource, /getEvidence\([\s\S]*completionObserved/iu,
    'OpenHarmonyTestRunner must check evidence before appending completionObserved'
  );
  const runnerFailureAppends = [...runnerSource.matchAll(/appendEvidenceFailure\(\s*['"`]OpenHarmonyTestRunner['"`]/gu)];
  assert.equal(runnerFailureAppends.length, 1,
    'OpenHarmonyTestRunner must record runner failure evidence at exactly one common catch point'
  );
  assert.doesNotMatch(runnerSource, /async\s+function\s+failTask14CompletionTimeout[\s\S]*appendEvidenceFailure\(/u,
    'OpenHarmonyTestRunner timeout helper must not append evidence directly'
  );
  assert.match(runnerSource, /catch[\s\S]*setEvidenceStatus\(['"`]FAIL['"`]\)[\s\S]*appendEvidenceFailure\([\s\S]*flushEvidence\([\s\S]*throw/u,
    'OpenHarmonyTestRunner common catch must set FAIL, append one generic failure, best-effort flush, and rethrow'
  );
  assert.match(testabilitySource, /export\s+async\s+function\s+waitForTask14Completion\(/u,
    'TestAbility must expose a waitForTask14Completion Promise barrier'
  );
  assert.match(testabilitySource, /signalTask14Completion/u,
    'TestAbility must expose a single-shot completion signal'
  );
  assert.match(runnerSource, /abilityDelegatorRegistry\.getArguments\(\)\.parameters|abilityDelegatorArguments\.parameters/u,
    'OpenHarmonyTestRunner must read AbilityDelegator string parameters for proof identity handoff'
  );
  assert.match(runnerSource, /configureEvidenceFromRunnerParameters\(runnerParameters\)/u,
    'OpenHarmonyTestRunner must pass the raw delegator parameters into the evidence configurator'
  );
  for (const parameterKey of [
    ['cmfa.phase3.runId', 'TASK14_RUN_ID_PARAMETER_KEY'],
    ['cmfa.phase3.productionHapSha256', 'TASK14_PRODUCTION_HAP_SHA256_PARAMETER_KEY'],
    ['cmfa.phase3.entryTestHapSha256', 'TASK14_ENTRY_TEST_HAP_SHA256_PARAMETER_KEY'],
    ['cmfa.phase3.fixtureSha256', 'TASK14_FIXTURE_SHA256_PARAMETER_KEY']
  ]) {
    assert.match(
      testabilitySource,
      new RegExp(`${parameterKey[0].replaceAll('.', '\\.')}|${parameterKey[1]}`, 'u'),
      `Task14 evidence configuration must recognize ${parameterKey[0]}`
    );
  }
  assert.doesNotMatch(runnerSource, /-w\s*[,)]|['"`]-w['"`]/u,
    'OpenHarmonyTestRunner / Task14 contract must not rely on an opaque -w JSON payload'
  );
  assert.match(testabilitySource, /runId:\s*string/u, 'Task14Evidence must persist the runner runId');
  assert.match(testabilitySource, /productionHapSha256:\s*string/u, 'Task14Evidence must persist the production HAP digest');
  assert.match(testabilitySource, /entryTestHapSha256:\s*string/u, 'Task14Evidence must persist the entry_test HAP digest');
  assert.match(testabilitySource, /fixtureSha256:\s*string/u, 'Task14Evidence must persist the fixture digest');
  assert.match(testabilitySource, /export\s+type\s+Task14CleanupStatus\s*=\s*['"`]pass['"`]\s*\|\s*['"`]fail['"`]\s*\|\s*['"`]incomplete['"`]/u,
    'Task14Evidence must define the truthful cleanup-status union'
  );
  assert.match(testabilitySource, /cleanup:\s*Task14CleanupStatus/u, 'Task14Evidence must persist truthful cleanup status');
  assert.match(testabilitySource, /homeSnapshotAddress:\s*string/u, 'Task14Evidence must persist the Home snapshot address');
  assert.match(testabilitySource, /homeRuntimeAddress:\s*string/u, 'Task14Evidence must persist the runtime snapshot address');
  assert.match(testabilitySource, /export\s+function\s+configureEvidenceFromRunnerParameters\(/u,
    'TestAbility must expose a runner-parameter configuration seam'
  );
  assert.match(testabilitySource, /export\s+function\s+setEvidenceCleanupStatus\(/u,
    'TestAbility must expose truthful cleanup status updates'
  );
  assert.match(testabilitySource, /export\s+function\s+setEvidenceHomeAddresses\(/u,
    'TestAbility must expose Home/runtime address updates'
  );

  const suiteMentions = [...listSource.matchAll(/from\s+'\.\/([^']+)\.test'/gu)].map((match) => match[1]);
  assert.deepEqual(suiteMentions, REQUIRED_OHOS_TEST_SUITES,
    'List.test.ets must import Phase3PlatformAdapters, Phase3RuntimeFlow, and Phase3UiFlow in deterministic order'
  );

  const suiteInvocationOrder = REQUIRED_OHOS_TEST_SUITES.map((suiteName) => {
    const index = listSource.indexOf(`${suiteName}Testsuite()`);
    assert.notEqual(index, -1, `${suiteName}Testsuite() must be invoked from List.test.ets`);
    return index;
  });
  assert.deepEqual([...suiteInvocationOrder].sort((left, right) => left - right), suiteInvocationOrder,
    'List.test.ets must invoke the three Task 14 suites in deterministic order'
  );
  assert.match(listSource, /describe\(['"`]Task14Finalization/u,
    'List.test.ets must register a deterministic finalization suite after the three Task 14 suites'
  );
  assert.match(listSource, /setEvidenceStatus\(['"`]PASS['"`]\)/u,
    'List.test.ets finalization must set PASS when no evidence failures remain'
  );
  assert.match(listSource, /signalTask14Completion\(/u,
    'List.test.ets finalization must signal the completion barrier exactly once'
  );
  assert.match(listSource, /await\s+flushEvidence\(/u,
    'List.test.ets finalization must flush evidence before completion'
  );
  assert.match(listSource, /getEvidence\(\)\.failures/u,
    'List.test.ets finalization must inspect accumulated evidence failures'
  );
  assert.match(listSource, /catch[\s\S]*setEvidenceStatus\(['"`]FAIL['"`]\)[\s\S]*appendEvidenceFailure\(['"`]Task14Finalization['"`]/u,
    'List.test.ets must downgrade evidence to FAIL and append a finalization failure before signaling when flush persistence fails'
  );
  assert.match(listSource, /appendEvidenceFailure\(['"`]Task14Finalization['"`][\s\S]*signalTask14Completion\(/u,
    'List.test.ets must append the finalization failure before signaling completion'
  );
  const lastSignalIndex = listSource.lastIndexOf('signalTask14Completion(');
  const lastItIndex = listSource.lastIndexOf('it(');
  assert.ok(lastSignalIndex > lastItIndex,
    'List.test.ets must not register any test item after the completion signal'
  );
  assert.match(pagesSource, /"src"\s*:\s*\[\s*"testability\/pages\/Index"\s*\]/u,
    'test_pages.json must only register the isolated testability page'
  );
});

test('Task 14 isolated Simulator fixture stays canonical and production sources stay clean', async () => {
  const [canonicalFixture, rawfileFixture, mainPagesSource, productionModuleSource] = await Promise.all([
    fs.readFile(OHOS_TEST_CANONICAL_FIXTURE_PATH),
    fs.readFile(OHOS_TEST_RAWFILE_FIXTURE_PATH),
    readUtf8(MAIN_PAGES_PATH),
    readUtf8(path.join(ENTRY_ROOT, 'src', 'main', 'module.json5'))
  ]);

  assert.equal(canonicalFixture.toString('utf8'), PHASE3_VALID_YAML,
    'tests/fixtures/phase3-valid.yaml must match the canonical Task 14 YAML exactly'
  );
  assert.deepEqual(rawfileFixture, canonicalFixture,
    'ohosTest rawfile fixture must stay byte-identical to tests/fixtures/phase3-valid.yaml'
  );

  for (const productionSource of [mainPagesSource, productionModuleSource]) {
    assert.doesNotMatch(productionSource, /ohosTest|entry_test|test_pages|TestAbility|OpenHarmonyTestRunner|phase3-valid\.yaml/u,
      'production routes and manifest must not reference the isolated ohosTest bundle'
    );
  }
});

test('Task 14 suite sources keep completion, picker cancel, sanitized displays, and non-swallowing cleanup semantics', async () => {
  const [platformSource, runtimeSource, uiSource, testabilitySource] = await Promise.all([
    readUtf8(OHOS_TEST_PLATFORM_ADAPTERS_PATH),
    readUtf8(OHOS_TEST_RUNTIME_FLOW_PATH),
    readUtf8(OHOS_TEST_UI_FLOW_PATH),
    readUtf8(OHOS_TEST_TESTABILITY_PATH)
  ]);

  assert.match(uiSource, /ON\.id\(['"`]import\.file['"`]\)[\s\S]*click\(/u,
    'Phase3UiFlow must click the production import.file semantic id before system Picker cancellation'
  );
  assert.doesNotMatch(uiSource, /home\.proxy\.manage/u,
    'Phase3UiFlow must not depend on the removed home proxy-management action'
  );
  assert.match(uiSource, /pressBack\(/u,
    'Phase3UiFlow must cancel the system Picker via Driver.pressBack'
  );
  assert.match(uiSource, /waitForComponent\(\s*ON\.id\(['"`]import\.file['"`]\)/u,
    'Phase3UiFlow must return to the import sheet after Picker cancellation before the HTTP warning flow'
  );
  assert.match(uiSource, /waitForComponent\(\s*ON\.id\(['"`]profiles\.add['"`]\)/u,
    'Phase3UiFlow must return to the profiles list after the HTTP warning cancel path'
  );
  assert.match(uiSource, /findComponent\(\s*ON\.id\(['"`]profiles\.back['"`]\)\s*\)/u,
    'Phase3UiFlow must find the Profiles back button by semantic id'
  );
  assert.match(uiSource, /getId\(\)\)\.assertEqual\(['"`]profiles\.back['"`]\)/u,
    'Phase3UiFlow must assert the Profiles back button keeps semantic id profiles.back'
  );
  assert.match(uiSource, /profilesBack\.click\(\)/u,
    'Phase3UiFlow must click the Profiles back button to return home'
  );
  assert.match(uiSource, /waitForComponent\(\s*ON\.id\(['"`]home\.profile\.manage['"`]\)\s*,\s*5000\s*\)/u,
    'Phase3UiFlow must wait for the home manage-profiles CTA after clicking Profiles back'
  );

  assert.doesNotMatch(runtimeSource, /HomeViewModel|localProxy/u,
    'Phase3RuntimeFlow must not reach the removed HomeViewModel/localProxy product surface'
  );
  assert.doesNotMatch(runtimeSource, /application\.(?:startLocal|stopLocal)\(/u,
    'Phase3RuntimeFlow must not call removed application.startLocal/stopLocal APIs'
  );
  assert.match(runtimeSource, /new\s+LocalRuntimeCoordinator\(/u,
    'Phase3RuntimeFlow must construct a retained LocalRuntimeCoordinator for diagnostic runtime control'
  );
  assert.match(runtimeSource, /coordinator\.current\(\)\.state[\s\S]*['"`]RUNNING['"`]/u,
    'Phase3RuntimeFlow must assert a RUNNING coordinator snapshot after start'
  );
  assert.match(runtimeSource, /(?:coordinator\.current\(\)\.latest|latest)\.state[\s\S]*['"`]RUNNING['"`]/u,
    'Phase3RuntimeFlow must assert a RUNNING latest coordinator snapshot after start'
  );
  assert.match(runtimeSource, /coordinator\.current\(\)\.state[\s\S]*['"`]STOPPED['"`]/u,
    'Phase3RuntimeFlow must assert a STOPPED coordinator snapshot after stop'
  );
  assert.match(runtimeSource, /(?:coordinator\.current\(\)\.latest|stoppedLatest)\.state[\s\S]*['"`]STOPPED['"`]/u,
    'Phase3RuntimeFlow must assert a STOPPED latest coordinator snapshot after stop'
  );
  assert.match(runtimeSource, /createProductionProfileApplication\([\s\S]*coordinator/u,
    'Phase3RuntimeFlow must pass the retained coordinator into the ProfileApplication helper'
  );
  assert.match(runtimeSource, /finally[\s\S]*await\s+coordinator\.stop\(/u,
    'Phase3RuntimeFlow must unconditionally stop the retained coordinator in finally'
  );
  assert.doesNotMatch(runtimeSource, /if\s*\(\s*runtimeState\s*===\s*['"`]RUNNING['"`][\s\S]*await\s+coordinator\.stop/u,
    'Phase3RuntimeFlow finally must not skip coordinator.stop based on a snapshot-state guard'
  );
  assert.match(runtimeSource, /['"`]retain\/save['"`][\s\S]*['"`]enable\.validate['"`][\s\S]*['"`]enable\.load['"`][\s\S]*['"`]start\.revalidate['"`][\s\S]*['"`]start\.load['"`][\s\S]*['"`]startLocal\(7890\)['"`]/u,
    'Phase3RuntimeFlow trace must acknowledge both enable validate/load and start revalidate/load before startLocal(7890)'
  );
  assert.match(runtimeSource, /setEvidenceHomeAddresses\(/u,
    'Phase3RuntimeFlow must publish Home/runtime addresses into Task14 evidence'
  );
  assert.match(runtimeSource, /setEvidenceCleanupStatus\(['"`]pass['"`]\)/u,
    'Phase3RuntimeFlow must mark cleanup pass only after teardown succeeds'
  );
  assert.match(runtimeSource, /setEvidenceCleanupStatus\(['"`](?:fail|incomplete)['"`]\)/u,
    'Phase3RuntimeFlow must downgrade cleanup status when teardown is not clean'
  );
  assert.doesNotMatch(runtimeSource, /\.catch\(\(\)\s*=>\s*\{\s*\}\)/u,
    'Phase3RuntimeFlow cleanup must not swallow repository/content removal failures'
  );
  assert.match(runtimeSource, /if\s*\(\s*application\s*!==\s*undefined\s*\)\s*\{[\s\S]*try\s*\{[\s\S]*application\.dispose\(/u,
    'Phase3RuntimeFlow must dispose the application during teardown once the coordinator cleanup path finishes'
  );
  assert.match(runtimeSource, /if\s*\(\s*coordinator\s*!==\s*undefined\s*\)\s*\{[\s\S]*try\s*\{[\s\S]*await\s+coordinator\.stop\([\s\S]*\}[\s\S]*catch/u,
    'Phase3RuntimeFlow must keep coordinator.stop failure handling inside teardown without skipping later cleanup'
  );
  const coordinatorStopIndex = runtimeSource.indexOf('await coordinator.stop()');
  const applicationDisposeIndex = runtimeSource.indexOf('application.dispose()');
  const coordinatorDisposeIndex = runtimeSource.indexOf('coordinator.dispose()');
  assert.notEqual(coordinatorStopIndex, -1, 'Phase3RuntimeFlow teardown must call await coordinator.stop()');
  assert.notEqual(applicationDisposeIndex, -1, 'Phase3RuntimeFlow teardown must call application.dispose()');
  assert.notEqual(coordinatorDisposeIndex, -1, 'Phase3RuntimeFlow teardown must call coordinator.dispose()');
  assert.ok(
    coordinatorStopIndex < applicationDisposeIndex && applicationDisposeIndex < coordinatorDisposeIndex,
    'Phase3RuntimeFlow teardown must preserve await coordinator.stop() -> application.dispose() -> coordinator.dispose() order'
  );
  assert.match(runtimeSource, /if\s*\(\s*graph\s*!==\s*undefined\s*\)\s*\{[\s\S]*try\s*\{[\s\S]*deleteAndClearActive[\s\S]*removeProfile[\s\S]*\}[\s\S]*finally\s*\{[\s\S]*await\s+graph\.close\(/u,
    'Phase3RuntimeFlow must close the graph from a finally branch even if repository/content cleanup fails'
  );

  assert.doesNotMatch(platformSource, /sourceDisplay:\s*EXTERNAL_PICKER_URI/u,
    'Phase3PlatformAdapters local test profiles must not persist the external Picker URI as sourceDisplay'
  );
  assert.doesNotMatch(platformSource, /sourceDisplay:\s*REMOTE_URL/u,
    'Phase3PlatformAdapters remote test profiles must not persist the raw remote URL as sourceDisplay'
  );
  assert.match(platformSource, /decrypt\(remoteSecretId\)[\s\S]*assertEqual\(REMOTE_URL\)/u,
    'Phase3PlatformAdapters must still prove the raw remote URL survives only through HUKS decrypt'
  );
  assert.match(platformSource, /contains[A-Za-z]*Subsequence|contains[A-Za-z]*Fragment/u,
    'Phase3PlatformAdapters must scan raw bytes/text through an explicit subsequence helper instead of sanitized strings'
  );
  assert.doesNotMatch(platformSource, /sanitizeEvidenceText\([\s\S]*database|databaseText:\s*string\s*=\s*sanitizeEvidenceText|envelopeText:\s*string\s*=\s*sanitizeEvidenceText/u,
    'Phase3PlatformAdapters database/envelope leak scans must not sanitize the source before checking sentinels'
  );
  assert.doesNotMatch(platformSource, /\.catch\(\(\)\s*=>\s*\{\s*\}\)/u,
    'Phase3PlatformAdapters cleanup must not swallow profile/content/secret deletion failures'
  );
  assert.match(platformSource, /if\s*\(\s*finalGraph\s*!==\s*undefined\s*\)\s*\{[\s\S]*try\s*\{[\s\S]*deleteAndClearActive[\s\S]*secretStore\.remove[\s\S]*\}[\s\S]*finally\s*\{[\s\S]*await\s+finalGraph\.close\(/u,
    'Phase3PlatformAdapters must close finalGraph from a finally branch even if profile/secret cleanup fails'
  );
  assert.match(platformSource, /cleanupGraph[\s\S]*try\s*\{[\s\S]*repository\.list\([\s\S]*assertNoResidualTask14Artifacts[\s\S]*\}[\s\S]*finally\s*\{[\s\S]*await\s+cleanupGraph\.close\(/u,
    'Phase3PlatformAdapters must close cleanupGraph from a finally branch even if cleanup assertions fail'
  );
  assert.match(platformSource, /appendEvidenceFailure\([\s\S]*cleanup[\s\S]*await\s+flushEvidence\(/u,
    'Phase3PlatformAdapters must append cleanup failure detail before flushing FAIL evidence'
  );
  assert.match(platformSource, /captureCleanupError|recordCleanupError/u,
    'Phase3PlatformAdapters cleanup must accumulate the first cleanup error while continuing later teardown steps'
  );
  assert.match(runtimeSource, /captureCleanupError|recordCleanupError/u,
    'Phase3RuntimeFlow cleanup must accumulate the first cleanup error while continuing later teardown steps'
  );

  assert.match(testabilitySource, /fsync|fsyncSync/u,
    'TestAbility.flushEvidence must fsync written evidence before publishing it'
  );
  assert.match(testabilitySource, /rename|moveFile/u,
    'TestAbility.flushEvidence must publish evidence through an atomic temp-to-final rename'
  );
  assert.match(testabilitySource, /\.tmp/u,
    'TestAbility.flushEvidence must write through a unique temporary evidence file'
  );
  const flushEvidenceMatch = testabilitySource.match(/export\s+async\s+function\s+flushEvidence\([\s\S]*?\n\}/u);
  assert.ok(flushEvidenceMatch, 'TestAbility must define flushEvidence');
  assert.doesNotMatch(flushEvidenceMatch[0], /fileIo\.open\(\s*filePath[\s\S]*OpenMode\.TRUNC/u,
    'TestAbility.flushEvidence must not truncate the final evidence file in place'
  );
});
