import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = fileURLToPath(new URL('../../..', import.meta.url));
const HARMONY_ROOT = path.join(REPO_ROOT, 'harmony');
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets');
const RESOURCES_ROOT = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'resources', 'base', 'element');

const INDEX_PATH = path.join(ENTRY_ROOT, 'pages', 'Index.ets');
const HOME_PAGE_PATH = path.join(ENTRY_ROOT, 'pages', 'HomePage.ets');
const CARD_PATH = path.join(ENTRY_ROOT, 'components', 'RuntimeStatusCard.ets');
const PROXIES_PAGE_PATH = path.join(ENTRY_ROOT, 'pages', 'ProxiesPage.ets');
const PROXY_VIEW_MODEL_PATH = path.join(ENTRY_ROOT, 'presentation', 'ProxyViewModel.ets');
const PROXY_MODELS_PATH = path.join(ENTRY_ROOT, 'presentation', 'ProxyPresentationModels.ets');
const PROFILE_APPLICATION_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'profile', 'ProfileApplication.ets');
const STRING_RESOURCE_PATH = path.join(RESOURCES_ROOT, 'string.json');
const COLOR_RESOURCE_PATH = path.join(RESOURCES_ROOT, 'color.json');

const PROXY_STRING_KEYS = [
  'detail_proxy_title',
  'detail_proxy_manage',
  'detail_proxy_collapse',
  'detail_proxy_requires_active',
  'proxies_title',
  'proxies_back',
  'proxies_loading',
  'proxies_empty',
  'proxies_retry',
  'proxies_selected',
  'proxies_saved_for_next_start',
  'proxies_applied_not_persisted',
  'proxies_activation_starting_vpn',
  'proxies_activation_switching_vpn',
  'proxies_activation_transitioning',
  'proxies_nested_group',
  'proxies_one_click_busy',
  'proxies_error_profile_unavailable',
  'proxies_error_runtime_not_ready',
  'proxies_error_query_failed',
  'proxies_error_selection_stale',
  'proxies_error_selection_failed',
  'proxies_error_persistence_failed',
  'proxies_error_session_changed',
  'proxies_one_click_confirmation_timeout',
  'error_vpn_profile_unavailable',
  'error_vpn_permission_denied',
  'error_vpn_start_failed',
  'proxies_delay_action_start',
  'proxies_delay_action_cancel',
  'proxies_delay_progress',
  'proxies_delay_summary_available',
  'proxies_delay_summary_timeout',
  'proxies_delay_summary_failed',
  'proxies_delay_summary_cancelled',
  'proxies_delay_summary_unsupported',
  'proxies_delay_fastest_marker',
  'proxies_delay_fastest_summary',
  'proxies_delay_waiting',
  'proxies_delay_testing',
  'proxies_delay_timeout',
  'proxies_delay_failed',
  'proxies_delay_cancelled',
  'proxies_delay_unsupported',
  'proxies_delay_ms'
];

const PROXY_ERROR_MAPPINGS = [
  ['PROXY_PROFILE_UNAVAILABLE', 'proxies_error_profile_unavailable'],
  ['PROXY_RUNTIME_NOT_READY', 'proxies_error_runtime_not_ready'],
  ['PROXY_SELECTION_STALE', 'proxies_error_selection_stale'],
  ['PROXY_SELECTION_FAILED', 'proxies_error_selection_failed'],
  ['PROXY_PERSISTENCE_FAILED', 'proxies_error_persistence_failed'],
  ['VPN_SESSION_CHANGED', 'proxies_error_session_changed'],
  ['PROXY_QUERY_FAILED', 'proxies_error_query_failed']
];

const PROXY_DYNAMIC_STRING_VALUES = new Map([
  ['proxies_delay_progress', '已完成 %d / %d'],
  ['proxies_delay_summary_available', '可用 %d / %d'],
  ['proxies_delay_summary_timeout', '超时 %d'],
  ['proxies_delay_summary_failed', '不可用 %d'],
  ['proxies_delay_summary_cancelled', '已取消 %d'],
  ['proxies_delay_summary_unsupported', '不支持 %d'],
  ['proxies_delay_fastest_summary', '最快 %s %d ms'],
  ['proxies_delay_ms', '%d ms']
]);

const PROXY_STATIC_STRING_VALUES = new Map([
  ['proxies_activation_starting_vpn', '正在启动 VPN'],
  ['proxies_activation_switching_vpn', '正在切换到 VPN'],
  ['proxies_activation_transitioning', '切换中'],
  ['proxies_one_click_busy', '已有节点切换正在进行，请稍后再试。'],
  ['proxies_one_click_confirmation_timeout', 'VPN 已启动，但确认当前生效节点超时，请重试。']
]);

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

async function readJson(filePath) {
  return JSON.parse(await readUtf8(filePath));
}

function assertOrdered(source, labelsAndNeedles) {
  let previousIndex = -1;
  for (const [label, needle] of labelsAndNeedles) {
    const currentIndex = source.indexOf(needle);
    assert.notEqual(currentIndex, -1, `missing ${label}`);
    assert.ok(currentIndex > previousIndex, `${label} must preserve the required source order`);
    previousIndex = currentIndex;
  }
}

function assertNoPattern(label, source, pattern) {
  pattern.lastIndex = 0;
  assert.equal(pattern.test(source), false, label);
}

function normalizeHexColor(value) {
  const normalized = String(value).trim().toUpperCase();
  assert.match(normalized, /^#(?:[0-9A-F]{6}|[0-9A-F]{8})$/u, `invalid color token ${value}`);
  return normalized.length === 9 ? normalized.slice(0, 7) : normalized;
}

function channelFromHexPair(pair) {
  return Number.parseInt(pair, 16) / 255;
}

function srgbToLinear(channel) {
  if (channel <= 0.04045) {
    return channel / 12.92;
  }
  return ((channel + 0.055) / 1.055) ** 2.4;
}

function relativeLuminanceFromHex(value) {
  const normalized = normalizeHexColor(value);
  const red = srgbToLinear(channelFromHexPair(normalized.slice(1, 3)));
  const green = srgbToLinear(channelFromHexPair(normalized.slice(3, 5)));
  const blue = srgbToLinear(channelFromHexPair(normalized.slice(5, 7)));
  return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue);
}

function contrastRatio(foregroundHex, backgroundHex) {
  const foreground = relativeLuminanceFromHex(foregroundHex);
  const background = relativeLuminanceFromHex(backgroundHex);
  const lighter = Math.max(foreground, background);
  const darker = Math.min(foreground, background);
  return (lighter + 0.05) / (darker + 0.05);
}

test('plan d proxy ownership is scoped to active profile detail', async () => {
  const [indexSource, homePageSource, profileApplicationSource] = await Promise.all([
    readUtf8(INDEX_PATH),
    readUtf8(HOME_PAGE_PATH),
    readUtf8(PROFILE_APPLICATION_PATH)
  ]);

  assert.match(indexSource, /type\s+AppRoute\s*=\s*'HOME'\s*\|\s*'PROFILES'\s*\|\s*'DETAIL'/u);
  assert.doesNotMatch(indexSource, /'PROXIES'|openProxiesRoute|leaveProxiesRoute/u);
  assert.match(indexSource, /import\s+\{\s*ProxyViewModel\s*\}\s+from\s+'\.\.\/presentation\/ProxyViewModel'/u);
  assert.match(indexSource, /new\s+ProxyViewModel\(application\)/u);
  assert.match(profileApplicationSource, /export\s+class\s+ProfileApplication\s+implements\s+ProxyOneClickVpnApplicationPort\s*\{/u);
  assert.match(indexSource, /this\.proxySubscriptionId\s*=\s*this\.proxyViewModel\.subscribe\([\s\S]*this\.proxyState\s*=\s*this\.proxyViewModel\.current\(\)/u);
  assert.match(indexSource, /@State\s+private\s+proxyRenderVersion:\s*number\s*=\s*0;/u);
  assert.match(indexSource, /@State\s+private\s+detailCanManageProxies:\s*boolean\s*=\s*false;/u);
  assert.match(indexSource, /@State\s+private\s+detailProxyExpanded:\s*boolean\s*=\s*false;/u);
  assert.match(indexSource, /this\.proxyViewModel\?\.load\(this\.detailProfileId\)/u);
  assert.match(indexSource, /private\s+async\s+leaveDetailProxyManager\(/u);
  assert.match(indexSource, /this\.proxySubscriptionId\s*=\s*this\.proxyViewModel\.subscribe\(\(state:\s*ProxyViewState\):\s*void\s*=>\s*\{[\s\S]*this\.proxyState\s*=\s*state;[\s\S]*this\.proxyRenderVersion\s*=\s*this\.proxyRenderVersion\s*\+\s*1;/u);
  assert.match(indexSource, /@State\s+private\s+homeSelectedProxyGroupName:\s*string\s*=\s*'';/u);
  assert.match(indexSource, /@State\s+private\s+homeSelectedProxyNodeName:\s*string\s*=\s*'';/u);
  assert.match(homePageSource, /@Link\s+selectedProxyGroupName:\s*string;/u);
  assert.match(homePageSource, /@Link\s+selectedProxyNodeName:\s*string;/u);
  assert.match(homePageSource, /RuntimeStatusCard\(\{[\s\S]*selectedProxyGroupName:\s*\$selectedProxyGroupName,[\s\S]*selectedProxyNodeName:\s*\$selectedProxyNodeName/u);
  assert.doesNotMatch(homePageSource, /home\.proxy\.manage|home_proxy_manage|onManageProxies|buildManageProxiesCard/u);
  assert.match(indexSource, /if\s*\(\s*this\.proxyViewModel\s*!==\s*undefined\s*\)\s*\{[\s\S]*this\.proxyViewModel\.dispose\(\)\.then\([\s\S]*this\.handleProxyDisposeResult\(didDrain, disposeGeneration\);[\s\S]*this\.proxyViewModel\s*=\s*undefined/u);
  assert.doesNotMatch(indexSource, /\bhilog\.[a-z]+\s*\(/u);
  assert.doesNotMatch(homePageSource, /\bhilog\.[a-z]+\s*\(/u);
});

test('plan d proxy resources and error copy stay exact and complete', async () => {
  const [stringResources, proxiesPageSource] = await Promise.all([
    readJson(STRING_RESOURCE_PATH),
    readUtf8(PROXIES_PAGE_PATH)
  ]);

  const resourceNames = new Set((stringResources.string ?? []).map((entry) => entry.name));
  const resourceValues = new Map((stringResources.string ?? []).map((entry) => [entry.name, entry.value]));
  for (const key of PROXY_STRING_KEYS) {
    assert.ok(resourceNames.has(key), `string resources must include ${key}`);
  }
  assert.equal(resourceNames.has('proxies_one_click_local_stop_failed'), false,
    'string resources must not publish the removed local-stop activation error');
  for (const [key, value] of PROXY_DYNAMIC_STRING_VALUES.entries()) {
    assert.equal(resourceValues.get(key), value, `${key} must keep the exact ArkUI parameter template`);
    assert.doesNotMatch(String(resourceValues.get(key)), /%\{public\}/u, `${key} must not use hilog-style %{public} placeholders`);
  }
  for (const [key, value] of PROXY_STATIC_STRING_VALUES.entries()) {
    assert.equal(resourceValues.get(key), value, `${key} must keep the approved one-click copy`);
  }

  for (const [errorCode, resourceKey] of PROXY_ERROR_MAPPINGS) {
    assert.match(
      proxiesPageSource,
      new RegExp(`case\\s+'${errorCode}':[\\s\\S]*?return\\s+\\$r\\('app\\.string\\.${resourceKey}'\\);`, 'u'),
      `${errorCode} must map to ${resourceKey}`
    );
  }
  assert.match(proxiesPageSource, /case\s+'PROXY_QUERY_FAILED':[\s\S]*default:[\s\S]*return\s+\$r\('app\.string\.proxies_error_query_failed'\);/u,
    'query-failed must remain the exact default proxy error mapping'
  );
  assertNoPattern(
    'proxy page business copy must stay resource-backed instead of hard-coded inline',
    proxiesPageSource,
    /(?:正在启动 VPN|正在切换到 VPN|切换中|已有节点切换正在进行|确认当前生效节点超时)/u
  );
  assertNoPattern(
    'proxy page must not reference the removed local-stop activation resource',
    proxiesPageSource,
    /proxies_one_click_local_stop_failed/u
  );
});

test('plan d proxy status text colors meet wcag contrast on white cards', async () => {
  const colorResources = await readJson(COLOR_RESOURCE_PATH);
  const colors = new Map((colorResources.color ?? []).map((entry) => [entry.name, entry.value]));

  const surfaceCard = colors.get('color_surface_card');
  assert.notEqual(surfaceCard, undefined, 'color resources must include color_surface_card');

  for (const token of ['color_status_success', 'color_status_warning', 'color_status_danger']) {
    const foreground = colors.get(token);
    assert.notEqual(foreground, undefined, `color resources must include ${token}`);
    const ratio = contrastRatio(foreground, surfaceCard);
    assert.ok(ratio >= 4.5, `${token} must reach 4.5:1 contrast on color_surface_card, got ${ratio.toFixed(2)}:1`);
  }
});

test('plan d proxy page keeps index-only ids and exact state handling', async () => {
  const proxiesPageSource = await readUtf8(PROXIES_PAGE_PATH);

  assert.match(proxiesPageSource, /@Prop\s+renderVersion:\s*number;/u,
    'ProxiesPage must accept the primitive render version that forces ArkUI refresh on proxy-state publishes'
  );
  assert.match(
    proxiesPageSource,
    /@Builder\s+private\s+buildDelaySection\(\):\s*void\s*\{[\s\S]*this\.state\.delayState[\s\S]*this\.onDelayAction/u,
    'delay section must be a component member builder that directly consumes this.state and this.onDelayAction'
  );
  assert.match(proxiesPageSource, /\.id\('proxies\.back'\)/u);
  assert.match(proxiesPageSource, /\.id\('proxies\.retry'\)/u);
  assert.match(proxiesPageSource, /onDelayAction:\s*\(\)\s*=>\s*void/u);
  assert.match(proxiesPageSource, /\.id\('proxies\.delay-test'\)/u);
  assert.match(proxiesPageSource, /\.id\('proxies\.delay-progress'\)/u);
  assert.match(proxiesPageSource, /\.id\('proxies\.delay-summary'\)/u);
  assert.match(proxiesPageSource, /\.id\(`\$\{row\.semanticId\}\.delay`\)/u);
  assert.match(proxiesPageSource, /\.id\(`\$\{row\.semanticId\}\.fastest`\)/u);
  assert.match(proxiesPageSource, /\.id\(group\.semanticId\)/u, 'group chips must use precomputed index-only ids');
  assert.match(proxiesPageSource, /\.id\(row\.semanticId\)/u, 'node rows must use precomputed index-only ids');
  assert.match(proxiesPageSource, /\.id\(`\$\{row\.semanticId\}\.runtime-selected`\)/u);
  assert.match(proxiesPageSource, /\.id\(`\$\{row\.semanticId\}\.saved-intent`\)/u);
  assert.match(proxiesPageSource, /\.id\(`\$\{row\.semanticId\}\.nested-group`\)/u);
  assert.match(proxiesPageSource, /Text\(row\.name\)[\s\S]*\.id\(`\$\{row\.semanticId\}\.label`\)/u);
  assertNoPattern('group names must not leak into semantic ids', proxiesPageSource, /\.id\([^)]*(?:group\.name|row\.name|node\.name)/u);
  assert.match(proxiesPageSource, /if\s*\(\s*this\.state\.status\s*===\s*'LOADING'\s*\|\|\s*this\.state\.status\s*===\s*'IDLE'\s*\)\s*\{[\s\S]*buildMessageCard\(\$r\('app\.string\.proxies_loading'\)\)/u);
  assert.match(proxiesPageSource, /else\s+if\s*\(\s*this\.state\.status\s*===\s*'EMPTY'\s*\)\s*\{[\s\S]*buildMessageCard\(\$r\('app\.string\.proxies_empty'\)\)/u);
  assert.match(proxiesPageSource, /else\s+if\s*\(\s*this\.state\.status\s*===\s*'ERROR'\s*\)\s*\{[\s\S]*buildErrorCard\(this\.state,\s*this\.onRetry\)/u);
  assert.match(
    proxiesPageSource,
    /else\s*\{[\s\S]*if\s*\(\s*this\.state\.errorCode\s*!==\s*undefined\s*\)\s*\{[\s\S]*buildErrorCard\(this\.state,\s*this\.onRetry\)[\s\S]*\}[\s\S]*ForEach\(this\.state\.nodes/u,
    'READY states with typed selection errors must render the inline error card and still keep the node list visible'
  );
  assertOrdered(proxiesPageSource, [
    ['group tabs', ".scrollable(ScrollDirection.Horizontal)"],
    ['delay section', 'this.buildDelaySection();'],
    ['node list', 'ForEach(this.state.nodes, (row: ProxyNodeRowState) => {']
  ]);
  assert.match(
    proxiesPageSource,
    /if\s*\(\s*this\.state\.status\s*===\s*'READY'\s*\)\s*\{[\s\S]*this\.buildDelaySection\(\);[\s\S]*\}/u,
    'the delay section must render only for ready node content'
  );
  assert.match(
    proxiesPageSource,
    /ForEach\(this\.state\.nodes,\s*\(row:\s*ProxyNodeRowState\)\s*=>\s*\{[\s\S]*buildNodeButton\(row,\s*this\.state,\s*this\.onSelectNode\)[\s\S]*\},\s*\(row:\s*ProxyNodeRowState\)\s*=>\s*`\$\{this\.renderVersion\}:\$\{row\.semanticId\}`\)/u,
    'row subtree diff keys must include the primitive renderVersion while keeping visible semantic ids unchanged'
  );
  assert.match(proxiesPageSource, /if\s*\(\s*this\.state\.warning\s*===\s*'APPLIED_NOT_PERSISTED'\s*\)\s*\{[\s\S]*Text\(\$r\('app\.string\.proxies_applied_not_persisted'\)\)/u);
  assert.match(proxiesPageSource, /\.enabled\(!shouldDisableProxyInteractions\(this\.state\)\)/u, 'selectionPending and live delay must disable group chips');
  assert.match(proxiesPageSource, /\.enabled\(!shouldDisableProxyInteractionsFromRow\(state\.selectionPending,\s*state\.delayState\)\)/u,
    'selectionPending and live delay must disable node rows'
  );
  assert.match(proxiesPageSource, /\.enabled\(state\.errorRetryable\s*&&\s*!shouldDisableProxyInteractions\(state\)\)/u,
    'query retry must disable while activation is live'
  );
  assert.match(proxiesPageSource, /buildActivationErrorCard\(this\.state,\s*this\.onRetry\)/u,
    'ready states with one-click failures must render the activation error card'
  );
  assert.match(proxiesPageSource, /\.id\('proxies\.activation-retry'\)/u);
  assert.match(proxiesPageSource, /\.id\(`\$\{row\.semanticId\}\.activation`\)/u,
    'activating rows must reuse stable node ids with a fixed activation suffix'
  );
  assert.match(proxiesPageSource, /if\s*\(\s*shouldShowActivationStatus\(row,\s*state\)\s*\)\s*\{[\s\S]*Text\(resolveActivationStatusResource\(state\)\)/u);
  assert.match(
    proxiesPageSource,
    /function\s+shouldDisableProxyInteractions\(state:\s*ProxyViewState\):\s*boolean\s*\{\s*return\s+state\.selectionPending\s*\|\|\s*isDelayActionLive\(state\.delayState\);\s*\}/u,
    'group chips and retry controls must lock whenever activation or delay is live'
  );
  assert.match(
    proxiesPageSource,
    /\.enabled\(!shouldDisableProxyInteractions\(this\.state\)\)/u,
    'group chips must disable from the shared interaction gate'
  );
  assert.match(
    proxiesPageSource,
    /function\s+shouldDisableProxyInteractionsFromRow\(selectionPending:\s*boolean,\s*delayState:\s*ProxyDelayViewState\):\s*boolean\s*\{\s*return\s+selectionPending\s*\|\|\s*isDelayActionLive\(delayState\);\s*\}/u,
    'node rows must disable from the same activation and delay gate'
  );
  assert.match(proxiesPageSource, /Text\(group\.name\)/u, 'group names may only enter text rendering');
  assert.match(proxiesPageSource, /Text\(row\.name\)/u, 'node names may only enter text rendering');
  assert.match(proxiesPageSource, /if\s*\(\s*row\.isGroup\s*\)\s*\{[\s\S]*Text\(\$r\('app\.string\.proxies_nested_group'\)\)/u,
    'nested groups must expose the resource-backed affordance'
  );
  assert.match(proxiesPageSource, /\.onClick\(\(\)\s*=>\s*\{[\s\S]*onSelectNode\(row\.index\);[\s\S]*\}\)/u,
    'nested rows must continue through the shared select-node callback'
  );
  assert.match(
    proxiesPageSource,
    /Button\([^)]*resolveDelayActionLabel\(this\.state\.delayState\)[^)]*\)[\s\S]*\.id\('proxies\.delay-test'\)[\s\S]*\.constraintSize\(\{\s*minHeight:\s*\$r\('app\.float\.touch_target_min'\)\s*\}\)[\s\S]*\.focusable\(true\)[\s\S]*\.accessibilityText\(resolveDelayActionLabel\(this\.state\.delayState\)\)[\s\S]*\.enabled\(isDelayActionEnabled\(this\.state\)\)/u,
    'the delay action must keep the exact id, accessibility copy, touch target, and enablement contract'
  );
  assert.match(
    proxiesPageSource,
    /function\s+isDelayActionEnabled\(state:\s*ProxyViewState\):\s*boolean\s*\{[\s\S]*if\s*\(\s*state\.selectionPending\s*\)\s*\{\s*return\s+false;\s*\}[\s\S]*if\s*\(\s*isDelayActionLive\(state\.delayState\)\s*\)\s*\{\s*return\s+true;\s*\}[\s\S]*return\s+state\.status\s*===\s*'READY'\s*&&\s*state\.nodes\.length\s*>\s*0;\s*\}/u,
    'delay action must prioritize one-click activation disablement, but re-enable after FAILED or IDLE clears selectionPending and no live delay remains'
  );
  assert.match(
    proxiesPageSource,
    /Button\(\$r\('app\.string\.proxies_retry'\)\)[\s\S]*\.id\('proxies\.retry'\)[\s\S]*\.enabled\(state\.errorRetryable\s*&&\s*!shouldDisableProxyInteractions\(state\)\)/u,
    'load retry must disable while activation or delay is live'
  );
  assert.match(
    proxiesPageSource,
    /Button\(\$r\('app\.string\.proxies_retry'\)\)[\s\S]*\.id\('proxies\.activation-retry'\)[\s\S]*\.enabled\(state\.activationErrorRetryable\s*&&\s*!shouldDisableProxyInteractions\(state\)\)/u,
    'activation retry must disable while activation or delay is live'
  );
  assert.match(
    proxiesPageSource,
    /if\s*\(\s*this\.state\.activationStage\s*===\s*'FAILED'\s*&&\s*this\.state\.activationErrorResourceId\s*!==\s*undefined\s*\)\s*\{[\s\S]*buildActivationErrorCard\(this\.state,\s*this\.onRetry\)/u,
    'typed activation errors must render on the proxy page through the dedicated card'
  );
  assert.match(
    proxiesPageSource,
    /function\s+resolveActivationErrorMessage\(resourceId:\s*OneClickVpnErrorResourceId\s*\|\s*undefined\):\s*Resource\s*\{[\s\S]*case\s+'proxies_one_click_busy':[\s\S]*case\s+'proxies_error_selection_stale':[\s\S]*case\s+'proxies_error_selection_failed':[\s\S]*case\s+'proxies_error_persistence_failed':[\s\S]*case\s+'error_vpn_profile_unavailable':[\s\S]*case\s+'error_vpn_permission_denied':[\s\S]*case\s+'error_vpn_start_failed':[\s\S]*case\s+'proxies_one_click_confirmation_timeout':[\s\S]*case\s+'proxies_error_session_changed':/u,
    'every closed activation error resource must stay mapped to a resource-backed message'
  );
  assert.match(
    proxiesPageSource,
    /Progress\(\{\s*value:\s*resolveDelayProgressValue\(this\.state\),\s*total:\s*resolveDelayProgressTotal\(this\.state\),\s*type:\s*ProgressType\.Linear\s*\}\)[\s\S]*\.id\('proxies\.delay-progress'\)/u,
    'the live delay progress must use a linear progress bar with safe totals'
  );
  assert.match(
    proxiesPageSource,
    /Text\(\$r\('app\.string\.proxies_delay_progress',\s*this\.state\.completedDelayCount,\s*this\.state\.totalDelayCount\)\)/u,
    'the live delay copy must bind parameters directly through $r rather than a reconstructed Resource object'
  );
  assert.match(
    proxiesPageSource,
    /Text\(\$r\('app\.string\.proxies_delay_summary_available',\s*this\.state\.availableDelayCount,\s*this\.state\.totalDelayCount\)\)/u,
    'the terminal summary must always include the available/total segment through direct $r parameter binding'
  );
  assert.match(proxiesPageSource, /if\s*\(\s*this\.state\.timeoutDelayCount\s*>\s*0\s*\)\s*\{[\s\S]*\$r\('app\.string\.proxies_delay_summary_timeout',\s*this\.state\.timeoutDelayCount\)/u);
  assert.match(proxiesPageSource, /if\s*\(\s*this\.state\.failedDelayCount\s*>\s*0\s*\)\s*\{[\s\S]*\$r\('app\.string\.proxies_delay_summary_failed',\s*this\.state\.failedDelayCount\)/u);
  assert.match(proxiesPageSource, /if\s*\(\s*this\.state\.cancelledDelayCount\s*>\s*0\s*\)\s*\{[\s\S]*\$r\('app\.string\.proxies_delay_summary_cancelled',\s*this\.state\.cancelledDelayCount\)/u);
  assert.match(proxiesPageSource, /if\s*\(\s*this\.state\.unsupportedDelayCount\s*>\s*0\s*\)\s*\{[\s\S]*\$r\('app\.string\.proxies_delay_summary_unsupported',\s*this\.state\.unsupportedDelayCount\)/u);
  assert.match(
    proxiesPageSource,
    /if\s*\(\s*(?:fastestRow\s*!==\s*undefined\s*&&\s*fastestRow\.delayMs\s*!==\s*undefined|resolveFastestRow\(this\.state\)\s*!==\s*undefined\s*&&\s*resolveFastestRow\(this\.state\)!\.delayMs\s*!==\s*undefined)\s*\)\s*\{[\s\S]*Text\(\$r\('app\.string\.proxies_delay_fastest_summary',\s*(?:fastestRow\.name,\s*fastestRow\.delayMs|resolveFastestRow\(this\.state\)!\.name,\s*resolveFastestRow\(this\.state\)!\.delayMs!)\)\)/u,
    'the terminal summary fastest line must use direct $r parameter binding with only the visible row label and delay'
  );
  assert.match(
    proxiesPageSource,
    /case\s+'WAITING':[\s\S]*return\s+\$r\('app\.string\.proxies_delay_waiting'\);[\s\S]*case\s+'TESTING':[\s\S]*return\s+\$r\('app\.string\.proxies_delay_testing'\);[\s\S]*case\s+'AVAILABLE':[\s\S]*return\s+\$r\('app\.string\.proxies_delay_ms',\s*row\.delayMs/u,
    'row delay copy must cover waiting, testing, and available states through direct $r resources'
  );
  assertNoPattern(
    'dynamic delay resources must not rebuild ArkUI Resource objects by hand',
    proxiesPageSource,
    /function\s+createResourceWithParams\s*\(/u
  );
  assert.match(
    proxiesPageSource,
    /case\s+'TIMEOUT':[\s\S]*return\s+\$r\('app\.string\.proxies_delay_timeout'\);[\s\S]*case\s+'FAILED':[\s\S]*return\s+\$r\('app\.string\.proxies_delay_failed'\);[\s\S]*case\s+'CANCELLED':[\s\S]*return\s+\$r\('app\.string\.proxies_delay_cancelled'\);[\s\S]*case\s+'UNSUPPORTED':[\s\S]*return\s+\$r\('app\.string\.proxies_delay_unsupported'\);/u,
    'row delay copy must cover all terminal outcomes through resources'
  );
  assert.match(
    proxiesPageSource,
    /if\s*\(\s*row\.delayStatus\s*===\s*'AVAILABLE'\s*&&\s*row\.delayMs\s*!==\s*undefined\s*\)\s*\{[\s\S]*if\s*\(\s*row\.delayMs\s*<=\s*300\s*\)\s*\{[\s\S]*color_status_success[\s\S]*\}[\s\S]*if\s*\(\s*row\.delayMs\s*<=\s*800\s*\)\s*\{[\s\S]*color_status_warning[\s\S]*\}[\s\S]*return\s+\$r\('app\.color\.color_status_danger'\);/u,
    'available delay rows must branch through success/warning/danger thresholds'
  );
  assert.match(proxiesPageSource, /Text\(\$r\('app\.string\.proxies_delay_fastest_marker'\)\)[\s\S]*\.id\(`\$\{row\.semanticId\}\.fastest`\)/u,
    'the fastest row marker must stay resource-backed with the stable id'
  );
  assert.match(
    proxiesPageSource,
    /if\s*\(\s*shouldShowDelayOutcome\(row,\s*state\.delayState\)\s*\)\s*\{[\s\S]*Text\(resolveDelayOutcomeResource\(row\)\)[\s\S]*\.id\(`\$\{row\.semanticId\}\.delay`\)/u,
    'row delay outcomes must use the view delay state when deciding whether the stable id is present'
  );
  assert.match(
    proxiesPageSource,
    /function\s+shouldShowDelayOutcome\(row:\s*ProxyNodeRowState,\s*delayState:\s*ProxyDelayViewState\):\s*boolean\s*\{\s*return\s+row\.delayStatus\s*!==\s*'NONE'\s*\|\|\s*delayState\s*===\s*'STARTING';\s*\}/u,
    'STARTING must surface waiting outcomes for cleared NONE rows, while idle and terminal NONE rows stay hidden'
  );
  assert.match(proxiesPageSource, /\.scrollBar\(BarState\.Off\)/u, 'proxy lists must hide visible scroll bars');
});

test('plan d proxy presentation models preserve exact public state shapes and clone boundaries', async () => {
  const source = await readUtf8(PROXY_MODELS_PATH);

  assert.match(source, /export\s+type\s+ProxyViewStatus\s*=\s*'IDLE'\s*\|\s*'LOADING'\s*\|\s*'READY'\s*\|\s*'EMPTY'\s*\|\s*'ERROR'/u);
  assert.match(source, /export\s+type\s+ProxyPersistenceWarning\s*=\s*'NONE'\s*\|\s*'SAVED_FOR_NEXT_START'\s*\|\s*'APPLIED_NOT_PERSISTED'/u);
  assert.match(source, /semanticId:\s*string;/u);
  assert.match(source, /selectionPending:\s*boolean;/u);
  assert.match(source, /errorRetryable:\s*boolean;/u);
  assert.match(source, /state\.semanticId\s*=\s*`proxies\.group\.\$\{state\.index\}`/u);
  assert.match(source, /state\.semanticId\s*=\s*`proxies\.node\.\$\{state\.index\}`/u);
  assert.match(source, /function\s+cloneProxyGroupTabState\(state:\s*ProxyGroupTabState\):\s*ProxyGroupTabState\s*\{[\s\S]*return\s+createProxyGroupTabState\(state\.index,\s*state\.name,\s*state\.type,\s*state\.active\);/u);
  assert.match(source, /function\s+cloneProxyNodeRowState\(state:\s*ProxyNodeRowState\):\s*ProxyNodeRowState\s*\{[\s\S]*return\s+createProxyNodeRowState\([\s\S]*state\.index,[\s\S]*state\.name,[\s\S]*state\.type,[\s\S]*state\.isGroup,[\s\S]*state\.runtimeSelected,[\s\S]*state\.savedForNextStart[\s\S]*\);/u);
  assert.match(source, /const\s+clonedGroups:\s*ProxyGroupTabState\[\]\s*=\s*cloneProxyGroupTabStates\(groups\);[\s\S]*const\s+clonedNodes:\s*ProxyNodeRowState\[\]\s*=\s*cloneProxyNodeRowStates\(nodes\);[\s\S]*state\.groups\s*=\s*clonedGroups;[\s\S]*state\.nodes\s*=\s*clonedNodes;/u,
    'public arrays must cross the presentation boundary through clone constructors'
  );
  assertNoPattern('proxy presentation models must not import platform kits', source, /from\s+['"]@kit\./u);
  assertNoPattern('proxy presentation models must not expose endpoint or private identity fields', source, /\b(?:profileId|revisionId|sessionId|url|host|port|token|secret|password|credential|endpoint|address)\b/u);
});

test('plan d proxy view model keeps request lifecycle, retry states, and nested-group handling exact', async () => {
  const source = await readUtf8(PROXY_VIEW_MODEL_PATH);

  assert.match(source, /this\.state\s*=\s*createProxyViewState\('IDLE',\s*\[\],\s*\[\],\s*\{[\s\S]*selectionPending:\s*false,[\s\S]*warning:\s*'NONE'/u);
  assert.match(source, /if\s*\(this\.disposed\s*\|\|\s*\(this\.isActivationBusy\(\)[\s\S]*\)\)\s*\{\s*return;\s*\}/u);
  assertOrdered(source, [
    ['initial empty loading state', "this.publish(createProxyViewState('LOADING', [], [], {"],
    ['list groups', 'await this.deadline.run(() => this.application.listGroups())'],
    ['empty state', "this.publish(createProxyViewState('EMPTY', [], [], {"],
    ['first group query', 'await this.queryGroupByName(epoch, firstGroupName, firstGroupName, groups, [firstGroupName]);']
  ]);
  assert.match(source, /if\s*\(\s*row\.isGroup\s*\)\s*\{[\s\S]*await this\.queryGroupByName\(\s*epoch,\s*row\.name,\s*activeTopLevelGroupName,\s*this\.state\.groups,\s*this\.extendDisplayedGroupPath\(row\.name\)\s*\);[\s\S]*return;\s*\}/u,
    'nested group taps must re-query the child group through the shared node callback'
  );
  assert.match(source, /this\.application\.currentOneClickVpnOperation\(\)/u,
    'the view model must seed its progress view from the application-scoped one-click snapshot'
  );
  assert.match(source, /this\.application\.subscribeOneClickVpnOperation\(\(snapshot:\s*OneClickVpnOperationSnapshot\):\s*void\s*=>\s*\{[\s\S]*this\.handleOneClickOperation\(snapshot\);[\s\S]*\}\)/u,
    'the view model must subscribe to application-scoped one-click progress'
  );
  assert.match(source, /selectionResult\s*=\s*await this\.application\.selectNodeAndEnsureVpn\(\s*groupName,\s*row\.name,\s*generation,\s*this\.cloneDisplayedGroupPath\(\)\s*\)/u,
    'terminal node activation must use the one-click application use case'
  );
  assert.match(source, /if\s*\(\s*this\.displayedSessionId\s*!==\s*null\s*&&\s*row\.runtimeSelected\s*\)\s*\{\s*return;\s*\}/u,
    'the current running node must be an idempotent no-op'
  );
  assert.match(source, /this\.publish\(createProxyViewState\('ERROR',\s*groups,\s*nodes,\s*\{[\s\S]*warning:\s*this\.currentWarning\(\),[\s\S]*errorCode:\s*code,[\s\S]*errorRetryable:\s*retryable/u,
    'query rejections must publish the typed ERROR state without hiding unresolved persistence drift'
  );
  assert.match(source, /catch\s*\(_error\)\s*\{[\s\S]*if\s*\(!this\.isCurrentSelectionEpoch\(selectionEpoch\)\)\s*\{[\s\S]*return;[\s\S]*\}[\s\S]*this\.publishActivationFailure\('proxies_error_selection_failed',\s*true,\s*false\);\s*return;\s*\}/u,
    'one-click transport and deadline failures must map to the activation error channel'
  );
  assert.match(source, /private\s+publishActivationFailure\([\s\S]*createProxyActivationStateOptions\('FAILED',\s*this\.activatingRowIndex,\s*resourceId,\s*retryable\)/u,
    'one-click failures must stay on READY and surface the dedicated activation error channel'
  );
  assert.match(source, /private\s+publishActivationProgress\(stage:\s*ProxyActivationStage\):\s*void\s*\{[\s\S]*createProxyActivationStateOptions\(stage,\s*this\.activatingRowIndex\)/u,
    'application progress must drive the closed activation stage copy'
  );
  assert.match(source, /private\s+async\s+refreshDisplayedGroupAfterActivation\(\):\s*Promise<void>\s*\{[\s\S]*const\s+refreshContext:\s*RefreshContext\s*\|\s*undefined\s*=\s*this\.captureRefreshContext\(\);[\s\S]*await this\.deadline\.run\(\(\)\s*=>\s*this\.application\.queryGroup\(\s*refreshContext\.displayedGroupName,\s*refreshContext\.displayedGroupPath\s*\)\)[\s\S]*this\.applyDisplayedGroupSnapshot\(\s*result\.snapshot,\s*refreshContext\.activeTopLevelGroupName,\s*refreshContext\.displayedGroupPath\s*\);/u,
    'successful one-click flows must refresh the same displayed group from the query helper'
  );
  assert.match(source, /async\s+retry\(\):\s*Promise<void>\s*\{[\s\S]*if\s*\(\s*this\.isActivationBusy\(\)\s*\)\s*\{[\s\S]*return;[\s\S]*\}[\s\S]*await this\.load\(this\.expectedProfileId\);/u);
  assert.match(source, /dispose\(\):\s*Promise<boolean>\s*\{[\s\S]*this\.application\.unsubscribeOneClickVpnOperation\(this\.oneClickOperationListenerId\);[\s\S]*this\.disposed\s*=\s*true;[\s\S]*this\.listeners\.clear\(\);/u,
    'dispose must unsubscribe one-click progress exactly once before suppressing later callbacks'
  );
  assert.match(source, /subscribe\(listener:\s*ProxyViewListener\):\s*number\s*\{[\s\S]*this\.listeners\.set\(this\.nextListenerId,\s*listener\);[\s\S]*return this\.nextListenerId;/u);
  assert.match(source, /current\(\):\s*ProxyViewState\s*\{\s*return cloneProxyViewState\(this\.state\);\s*\}/u);
});

test('plan d proxy view model keeps the 250 ms delay polling cadence and drains before leaving or disposal', async () => {
  const source = await readUtf8(PROXY_VIEW_MODEL_PATH);

  assert.match(source, /const PROXY_DELAY_POLL_MS: number = 250;/u);
  assert.match(
    source,
    /private scheduleNextDelayPoll\(epoch: number, jobId: string\): void \{\s*this\.cancelScheduledDelayTask\(\);\s*this\.scheduledDelayTask = this\.delayScheduler\.schedule\(PROXY_DELAY_POLL_MS,\s*\(\) => \{\s*void this\.pollDelayTest\(epoch, jobId\);/u,
    'delay polling must stay non-overlapping and fixed at 250 ms'
  );
  assert.match(source, /async load\(expectedProfileId\?: string\): Promise<void> \{[\s\S]*if \(this\.hasDelayLifecycleWork\(\)\) \{[\s\S]*await this\.prepareForNavigationOrLoad\(\)/u);
  assert.match(source, /async openGroup\(groupIndex: number\): Promise<void> \{[\s\S]*if \(this\.hasDelayLifecycleWork\(\)\) \{[\s\S]*await this\.prepareForNavigationOrLoad\(\)/u);
  assert.match(source, /private async prepareForNavigationOrLoad\(\): Promise<boolean> \{[\s\S]*await this\.application\.cancelAndDrainDelayTest\(\)/u);
  assert.match(source, /async leave\(\): Promise<void> \{[\s\S]*await this\.application\.cancelAndDrainDelayTest\(\)[\s\S]*this\.clearDelayTracking\(\)/u);
  assert.match(source, /dispose\(\): Promise<boolean> \{[\s\S]*await this\.application\.cancelAndDrainDelayTest\(\)[\s\S]*didDrain = false[\s\S]*await pendingStart[\s\S]*this\.clearDelayTracking\(\)[\s\S]*return didDrain/u);
  assertNoPattern('proxy view-model must not interpolate raw delay job ids into public logs or errors', source, /(?:console|hilog)\.[a-z]+\s*\([^)]*jobId|new Error\s*\(\s*`[^`]*\$\{jobId/u);
});

test('plan d proxy privacy scanner forbids raw-label leakage outside text rendering', async () => {
  const [indexSource, homePageSource, cardSource, proxiesPageSource, proxyViewModelSource, proxyModelsSource] = await Promise.all([
    readUtf8(INDEX_PATH),
    readUtf8(HOME_PAGE_PATH),
    readUtf8(CARD_PATH),
    readUtf8(PROXIES_PAGE_PATH),
    readUtf8(PROXY_VIEW_MODEL_PATH),
    readUtf8(PROXY_MODELS_PATH)
  ]);
  const joined = [indexSource, homePageSource, cardSource, proxiesPageSource, proxyViewModelSource, proxyModelsSource].join('\n');
  const selectedProxyLeakPattern =
    /(?:\.id\s*\(|new Error\s*\(|console\.(?:debug|info|warn|error|log)\s*\(|hilog\.[a-z]+\s*\(|JSON\.stringify\s*\(|(?:proof|report|journal|evidence)[^;\n`]*`)[^;\n`]*\$\{(?:selectedProxyGroupName|selectedProxyNodeName|homeSelectedProxyGroupName|homeSelectedProxyNodeName)/u;
  const syntheticBadSource = [
    "Text(this.selectedProxyGroupName)",
    "Button('x').id(`home.${selectedProxyGroupName}`)",
    "throw new Error(`selected ${homeSelectedProxyNodeName}`)",
    "console.info(`selected ${selectedProxyNodeName}`)",
    "const proofLine = `selected ${homeSelectedProxyGroupName}`",
    "JSON.stringify({ value: homeSelectedProxyNodeName })"
  ].join('\n');

  assertNoPattern('proxy UI must not emit console logs', joined, /console\.(?:debug|info|warn|error|log)\s*\(/u);
  assertNoPattern('proxy UI must not import hilog', joined, /\bhilog\.[a-z]+\s*\(/u);
  assertNoPattern(
    'proxy UI must not interpolate private names into ids, logs, or errors',
    joined,
    /(?:\.id\s*\(|new Error\s*\(|console\.(?:debug|info|warn|error|log)\s*\(|hilog\.[a-z]+\s*\()[^;\n]*\$\{(?:groupName|memberName|group\.name|node\.name|row\.name)/u
  );
  assertNoPattern(
    'proxy UI must not serialize proxy state or selection objects',
    joined,
    /JSON\.stringify\s*\([^)]*(?:ProxyViewState|ProxyGroup|ProxySelection)/u
  );
  assertNoPattern(
    'proxy UI pages must not carry endpoint, credential, or private identity fields',
    `${proxiesPageSource}\n${proxyModelsSource}`,
    /\b(?:profileId|revisionId|sessionId|url|host|port|token|secret|password|credential|endpoint|address)\b/u
  );
  assert.match(proxiesPageSource, /Text\(group\.name\)/u);
  assert.match(proxiesPageSource, /Text\(row\.name\)/u);
  assertNoPattern(
    'raw proxy names must stay out of proof-like object literals',
    joined,
    /\{\s*(?:groupName|memberName|selectedNodeName|proxyGroupName|proxyNodeName)\s*:/u
  );
  assert.match(syntheticBadSource, selectedProxyLeakPattern,
    'privacy scanner must fail on ids/logs/errors/json/proof-like interpolation of selected proxy strings');
  assertNoPattern('home selected proxy strings must not leak through ids, logs, errors, json, or proof-like interpolation',
    joined, selectedProxyLeakPattern);
  assert.match(homePageSource, /RuntimeStatusCard\(\{[\s\S]*selectedProxyGroupName:\s*\$selectedProxyGroupName,[\s\S]*selectedProxyNodeName:\s*\$selectedProxyNodeName[\s\S]*\}\)/u);
  assert.match(cardSource, /Text\(this\.selectedProxyGroupName\)/u);
  assert.match(cardSource, /Text\(this\.selectedProxyNodeName\)/u);
});
