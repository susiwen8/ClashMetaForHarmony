import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry', 'src', 'main');
const ENTRY_ETS_ROOT = path.join(ENTRY_ROOT, 'ets');
const SHARED_ETS_ROOT = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets');

const PRODUCT_FILE_PATHS = Object.freeze({
  homePage: path.join(ENTRY_ETS_ROOT, 'pages', 'HomePage.ets'),
  indexPage: path.join(ENTRY_ETS_ROOT, 'pages', 'Index.ets'),
  homeViewModel: path.join(ENTRY_ETS_ROOT, 'presentation', 'HomeViewModel.ets'),
  presentationModels: path.join(ENTRY_ETS_ROOT, 'presentation', 'PresentationModels.ets'),
  profilesViewModel: path.join(ENTRY_ETS_ROOT, 'presentation', 'ProfilesViewModel.ets'),
  profileDetailViewModel: path.join(ENTRY_ETS_ROOT, 'presentation', 'ProfileDetailViewModel.ets'),
  profileListItem: path.join(ENTRY_ETS_ROOT, 'components', 'ProfileListItem.ets'),
  runtimeStatusCard: path.join(ENTRY_ETS_ROOT, 'components', 'RuntimeStatusCard.ets'),
  safeErrorCard: path.join(ENTRY_ETS_ROOT, 'components', 'SafeErrorCard.ets'),
  profilesPage: path.join(ENTRY_ETS_ROOT, 'pages', 'ProfilesPage.ets'),
  proxyOneClickVpnModels: path.join(SHARED_ETS_ROOT, 'proxy', 'ProxyOneClickVpnModels.ets'),
  proxyPresentationModels: path.join(ENTRY_ETS_ROOT, 'presentation', 'ProxyPresentationModels.ets'),
  proxiesPage: path.join(ENTRY_ETS_ROOT, 'pages', 'ProxiesPage.ets'),
  stringJson: path.join(ENTRY_ROOT, 'resources', 'base', 'element', 'string.json'),
  profileApplication: path.join(SHARED_ETS_ROOT, 'profile', 'ProfileApplication.ets'),
  proofSchema: path.join(HARMONY_ROOT, 'tests', 'fixtures', 'proxy-one-click-vpn-device-proof.schema.json'),
  proofExample: path.join(HARMONY_ROOT, 'tests', 'fixtures', 'proxy-one-click-vpn-device-proof.example.json'),
  proofRunner: path.join(HARMONY_ROOT, 'tests', 'bin', 'run-proxy-one-click-vpn-device-proof.mjs')
});

const FORBIDDEN_LITERAL_SOURCE_TOKENS = Object.freeze([
  'home.local.action',
  'onLocalAction',
  'requestLocalAction',
  'state.localProxy',
  'profiles_locked_message',
  'proxies_one_click_local_stop_failed'
]);

const FORBIDDEN_IDENTIFIER_PATTERNS = Object.freeze([
  ['LocalProxyState', /\bLocalProxyState\b/u],
  ['LOCAL_STOP', /\bLOCAL_STOP\b/u],
  ['actionsLockedByRuntime', /\bactionsLockedByRuntime\b/u],
  ['areProfileActionsLocked', /\bareProfileActionsLocked\b/u],
  ['STOPPING_LOCAL', /\bSTOPPING_LOCAL\b/u],
  ['LOCAL_STOP_FAILED', /\bLOCAL_STOP_FAILED\b/u],
  ['home_local_*', /\bhome_local_[A-Za-z0-9_]+\b/u],
  ['error_vpn_requires_local_stop', /\berror_vpn_requires_local_stop\b/u],
  ['error_local_blocked_by_vpn', /\berror_local_blocked_by_vpn\b/u]
]);

const FORBIDDEN_STRING_VALUE_PATTERNS = Object.freeze([
  /(?:^|\W)Local proxy(?:\W|$)/u,
  /(?:^|\W)Start Local proxy(?:\W|$)/u,
  /(?:^|\W)Stop Local proxy(?:\W|$)/u,
  /(?:^|\W)Starting local listeners(?:\W|$)/u,
  /(?:^|\W)Stopping local listeners(?:\W|$)/u,
  /(?:^|\W)Local listeners active(?:\W|$)/u,
  /(?:^|\W)Local listener stopped(?:\W|$)/u,
  /(?:^|\W)Local listener error(?:\W|$)/u,
  /(?:^|\W)HTTP listener(?:\W|$)/u,
  /(?:^|\W)SOCKS listener(?:\W|$)/u,
  /Only the explicit local HTTP and SOCKS listeners started here are supported\./u,
  /Stop the local proxy before starting VPN global capture\./u,
  /Stop VPN global capture before starting the local proxy\./u,
  /请先停止本地代理，再切换或删除配置。/u,
  /本地代理/u
]);

const FORBIDDEN_EXACT_STRING_KEYS = Object.freeze([
  'home_runtime_title',
  'home_runtime_status_stopped',
  'home_runtime_status_starting',
  'home_runtime_status_running',
  'home_runtime_status_stopping',
  'home_runtime_status_error',
  'home_runtime_primary_start',
  'home_runtime_primary_stop',
  'home_runtime_missing_profile'
]);

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

async function readJson(filePath) {
  return JSON.parse(await readUtf8(filePath));
}

function collectTokenViolations(namedSources, forbiddenTokens) {
  const violations = [];
  for (const [label, source] of Object.entries(namedSources)) {
    for (const token of forbiddenTokens) {
      if (source.includes(token)) {
        violations.push(`${label} contains ${token}`);
      }
    }
  }
  return violations;
}

function stripComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//gu, ' ')
    .replace(/\/\/.*$/gmu, ' ');
}

function collectPatternViolations(namedSources, patterns) {
  const violations = [];
  for (const [label, source] of Object.entries(namedSources)) {
    for (const [tokenLabel, pattern] of patterns) {
      pattern.lastIndex = 0;
      if (pattern.test(source)) {
        violations.push(`${label} contains ${tokenLabel}`);
      }
    }
  }
  return violations;
}

function extractHomeViewStateBlock(source) {
  const match = source.match(/export\s+interface\s+HomeViewState\s*\{[\s\S]*?\n\}/u);
  assert.notEqual(match, null, 'PresentationModels must declare HomeViewState');
  return match[0];
}

test('local proxy product surface is removed while vpn surface and shared runtime sequencing remain intact', async () => {
  const allPaths = Object.values(PRODUCT_FILE_PATHS);
  const fileStats = await Promise.all(allPaths.map(async (filePath) => {
    await fs.access(filePath);
    return filePath;
  }));
  assert.equal(fileStats.length, allPaths.length, 'all required product and proof files must exist');

  const [
    homePageSource,
    indexPageSource,
    homeViewModelSource,
    presentationModelsSource,
    profilesViewModelSource,
    profileDetailViewModelSource,
    profileListItemSource,
    runtimeStatusCardSource,
    safeErrorCardSource,
    profilesPageSource,
    proxyOneClickVpnModelsSource,
    proxyPresentationModelsSource,
    proxiesPageSource,
    stringResources,
    profileApplicationSource,
    proofSchema,
    proofExample,
    proofRunnerSource
  ] = await Promise.all([
    readUtf8(PRODUCT_FILE_PATHS.homePage),
    readUtf8(PRODUCT_FILE_PATHS.indexPage),
    readUtf8(PRODUCT_FILE_PATHS.homeViewModel),
    readUtf8(PRODUCT_FILE_PATHS.presentationModels),
    readUtf8(PRODUCT_FILE_PATHS.profilesViewModel),
    readUtf8(PRODUCT_FILE_PATHS.profileDetailViewModel),
    readUtf8(PRODUCT_FILE_PATHS.profileListItem),
    readUtf8(PRODUCT_FILE_PATHS.runtimeStatusCard),
    readUtf8(PRODUCT_FILE_PATHS.safeErrorCard),
    readUtf8(PRODUCT_FILE_PATHS.profilesPage),
    readUtf8(PRODUCT_FILE_PATHS.proxyOneClickVpnModels),
    readUtf8(PRODUCT_FILE_PATHS.proxyPresentationModels),
    readUtf8(PRODUCT_FILE_PATHS.proxiesPage),
    readJson(PRODUCT_FILE_PATHS.stringJson),
    readUtf8(PRODUCT_FILE_PATHS.profileApplication),
    readJson(PRODUCT_FILE_PATHS.proofSchema),
    readJson(PRODUCT_FILE_PATHS.proofExample),
    readUtf8(PRODUCT_FILE_PATHS.proofRunner)
  ]);

  assert.match(homePageSource, /home\.vpn\.action/u, 'HomePage must keep the VPN home action');
  assert.match(
    profileApplicationSource,
    /applySelectionToRunningVpn/u,
    'ProfileApplication must keep applySelectionToRunningVpn'
  );
  assert.match(
    profileApplicationSource,
    /selectAndStartVpn/u,
    'ProfileApplication must keep selectAndStartVpn'
  );
  assert.match(
    profileApplicationSource,
    /snapshot\.runtime\.state === 'STARTING'[\s\S]*snapshot\.runtime\.state === 'STOPPING'/u,
    'ProfileApplication must keep shared runtime STARTING/STOPPING gating'
  );

  const homeViewStateBlock = extractHomeViewStateBlock(presentationModelsSource);
  const literalSourceViolations = collectTokenViolations(
    {
      HomePage: homePageSource,
      Index: indexPageSource,
      HomeViewModel: homeViewModelSource,
      PresentationModels: presentationModelsSource,
      ProfilesViewModel: profilesViewModelSource,
      ProfileDetailViewModel: profileDetailViewModelSource,
      ProfileListItem: profileListItemSource,
      RuntimeStatusCard: runtimeStatusCardSource,
      SafeErrorCard: safeErrorCardSource,
      ProfilesPage: profilesPageSource,
      ProxyOneClickVpnModels: proxyOneClickVpnModelsSource,
      ProxyPresentationModels: proxyPresentationModelsSource,
      ProxiesPage: proxiesPageSource
    },
    FORBIDDEN_LITERAL_SOURCE_TOKENS
  );
  const boundaryAwareSourceViolations = collectPatternViolations(
    {
      HomePage: stripComments(homePageSource),
      Index: stripComments(indexPageSource),
      HomeViewModel: stripComments(homeViewModelSource),
      PresentationModels: stripComments(presentationModelsSource),
      ProfilesViewModel: stripComments(profilesViewModelSource),
      ProfileDetailViewModel: stripComments(profileDetailViewModelSource),
      ProfileListItem: stripComments(profileListItemSource),
      RuntimeStatusCard: stripComments(runtimeStatusCardSource),
      SafeErrorCard: stripComments(safeErrorCardSource),
      ProfilesPage: stripComments(profilesPageSource),
      ProxyOneClickVpnModels: stripComments(proxyOneClickVpnModelsSource),
      ProxyPresentationModels: stripComments(proxyPresentationModelsSource),
      ProxiesPage: stripComments(proxiesPageSource)
    },
    FORBIDDEN_IDENTIFIER_PATTERNS
  );
  const homeViewStateViolations = /\blocalProxy\b/u.test(homeViewStateBlock)
    ? ['HomeViewState declares localProxy']
    : [];

  const stringEntries = Array.isArray(stringResources?.string) ? stringResources.string : [];
  const forbiddenStringNameViolations = stringEntries
    .map((entry) => entry?.name)
    .filter((name) => typeof name === 'string' && name.startsWith('home_local_'))
    .map((name) => `string.json contains resource ${name}`);
  const forbiddenExactStringKeys = ['error_vpn_requires_local_stop', 'error_local_blocked_by_vpn', ...FORBIDDEN_EXACT_STRING_KEYS]
    .filter((key) => stringEntries.some((entry) => entry?.name === key))
    .map((key) => `string.json contains resource ${key}`);
  const forbiddenStringValueViolations = stringEntries.flatMap((entry) => {
    const value = typeof entry?.value === 'string' ? entry.value : '';
    return FORBIDDEN_STRING_VALUE_PATTERNS
      .filter((pattern) => pattern.test(value))
      .map(() => `string.json contains visible Local product copy in ${entry?.name ?? '<unknown>'}: ${JSON.stringify(value)}`);
  });
  const runtimeErrorValueViolations = [
    ['error_runtime_start', '启动运行服务失败'],
    ['error_runtime_stop', '停止运行服务失败']
  ].flatMap(([key, expectedValue]) => {
    const entry = stringEntries.find((candidate) => candidate?.name === key);
    if (entry?.value === expectedValue) {
      return [];
    }
    return [`string.json must keep ${key} runtime-neutral as ${JSON.stringify(expectedValue)} but saw ${JSON.stringify(entry?.value)}`];
  });

  const profileApplicationViolations = [
    ['public async startLocal(', /async\s+startLocal\(/u],
    ['public async stopLocal(', /async\s+stopLocal\(/u],
    ['stopLocalThenSelectAndStartVpn', /stopLocalThenSelectAndStartVpn/u],
    ["createOneClickVpnOperationSnapshot('STOPPING_LOCAL'", /createOneClickVpnOperationSnapshot\('STOPPING_LOCAL'/u]
  ].filter(([, pattern]) => pattern.test(profileApplicationSource))
    .map(([label]) => `ProfileApplication contains ${label}`);

  const proofSchemaViolations = [];
  const proofSchemaVersionConst = proofSchema?.properties?.schemaVersion?.const;
  if (proofSchemaVersionConst !== '2.0.0') {
    proofSchemaViolations.push(
      `proof schema properties.schemaVersion.const is ${JSON.stringify(proofSchemaVersionConst)} instead of "2.0.0"`
    );
  }
  if (JSON.stringify(proofSchema).includes('localToVpnState')) {
    proofSchemaViolations.push('proof schema still defines or requires localToVpnState');
  }

  const proofExampleViolations = JSON.stringify(proofExample).includes('localToVpnState')
    ? ['proof example still contains localToVpnState']
    : [];

  const proofRunnerViolations = ['localToVpnState', 'APP_HOME_LOCAL_SELECTOR', 'startLocalProxy']
    .filter((token) => proofRunnerSource.includes(token))
    .map((token) => `proof runner contains ${token}`);

  const allViolations = [
    ...homeViewStateViolations,
    ...literalSourceViolations,
    ...boundaryAwareSourceViolations,
    ...forbiddenStringNameViolations,
    ...forbiddenExactStringKeys,
    ...forbiddenStringValueViolations,
    ...runtimeErrorValueViolations,
    ...profileApplicationViolations,
    ...proofSchemaViolations,
    ...proofExampleViolations,
    ...proofRunnerViolations
  ];

  assert.deepEqual(
    allViolations,
    [],
    `local proxy product removal contract violations:\n${allViolations.join('\n')}`
  );
});
