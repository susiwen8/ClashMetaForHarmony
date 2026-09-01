import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry', 'src', 'main');
const PAGES_ROOT = path.join(ENTRY_ROOT, 'ets', 'pages');
const INDEX_PATH = path.join(PAGES_ROOT, 'Index.ets');
const HOME_PATH = path.join(PAGES_ROOT, 'HomePage.ets');
const DETAIL_PATH = path.join(PAGES_ROOT, 'ProfileDetailPage.ets');
const PROXIES_PATH = path.join(PAGES_ROOT, 'ProxiesPage.ets');
const PROXY_VIEW_MODEL_PATH = path.join(ENTRY_ROOT, 'ets', 'presentation', 'ProxyViewModel.ets');
const STRINGS_PATH = path.join(ENTRY_ROOT, 'resources', 'base', 'element', 'string.json');

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

test('profile detail owns the only proxy-management entry and top-level proxy route is removed', async () => {
  const [indexSource, homeSource, detailSource, stringsSource] = await Promise.all([
    readUtf8(INDEX_PATH),
    readUtf8(HOME_PATH),
    readUtf8(DETAIL_PATH),
    readUtf8(STRINGS_PATH)
  ]);
  const strings = JSON.parse(stringsSource);
  const stringNames = new Set((strings.string ?? []).map((entry) => entry.name));

  assert.match(indexSource, /type AppRoute = 'HOME' \| 'PROFILES' \| 'DETAIL' \| 'LOGS';/u);
  assert.doesNotMatch(indexSource, /route === 'PROXIES'|openProxiesRoute|leaveProxiesRoute/u);
  assert.doesNotMatch(homeSource, /home\.proxy\.manage|home_proxy_manage|onManageProxies|buildManageProxiesCard/u);
  assert.equal(stringNames.has('home_proxy_manage'), false);
  assert.equal(stringNames.has('home_proxy_manage_disabled'), false);

  for (const key of [
    'detail_proxy_title',
    'detail_proxy_manage',
    'detail_proxy_collapse',
    'detail_proxy_requires_active'
  ]) {
    assert.equal(stringNames.has(key), true, `missing ${key}`);
  }
  assert.match(detailSource, /\.id\('detail\.proxy\.toggle'\)/u);
  assert.match(detailSource, /\.id\('detail\.back'\)/u);
  assert.match(detailSource, /\$r\('app\.string\.detail_proxy_requires_active'\)/u);
});

test('Index scopes proxy loading to the exact active detail profile and drains every exit', async () => {
  const indexSource = await readUtf8(INDEX_PATH);

  assert.match(indexSource, /@State private detailCanManageProxies: boolean = false;/u);
  assert.match(indexSource, /@State private detailProxyExpanded: boolean = false;/u);
  assert.match(
    indexSource,
    /detailProfileId\.length > 0[\s\S]*activeProfileId !== undefined[\s\S]*detailProfileId === activeProfileId/u
  );
  assert.match(
    indexSource,
    /if \(!this\.detailCanManageProxies \|\| this\.detailProfileId\.length === 0\) \{[\s\S]*return;[\s\S]*\}/u
  );
  assert.match(indexSource, /this\.proxyViewModel\?\.load\(this\.detailProfileId\)/u);
  assert.match(indexSource, /private async leaveDetailProxyManager\(/u);
  assert.match(indexSource, /this\.profileDetailNavigationSubscriptionId[\s\S]*leaveDetailProxyManager\('PROFILES'\)/u);
  assert.match(indexSource, /onBack:[\s\S]*leaveDetailProxyManager\('PROFILES'\)/u);
  assert.match(indexSource, /detailProxyExpanded[\s\S]*activeProfileId !== this\.detailProfileId[\s\S]*leaveDetailProxyManager\(\)/u);
  assert.match(indexSource, /ProfileDetailPage\(\{[\s\S]*canManageProxies: \$detailCanManageProxies[\s\S]*proxyExpanded: \$detailProxyExpanded/u);
});

test('embedded proxy content keeps one vertical detail scroll and preserves horizontal group scrolling', async () => {
  const [detailSource, proxiesSource] = await Promise.all([
    readUtf8(DETAIL_PATH),
    readUtf8(PROXIES_PATH)
  ]);

  assert.match(detailSource, /@Link canManageProxies: boolean;/u);
  assert.match(detailSource, /@Link proxyExpanded: boolean;/u);
  assert.match(detailSource, /if \(this\.proxyExpanded\) \{[\s\S]*ProxiesPage\(\{[\s\S]*embedded: true/u);
  assert.match(detailSource, /this\.proxyExpanded\s*\? \$r\('app\.string\.detail_proxy_collapse'\)\s*: \$r\('app\.string\.detail_proxy_manage'\)/u);
  assert.match(detailSource, /if \(!this\.proxyExpanded && !this\.canManageProxies\)/u);

  assert.match(proxiesSource, /@Prop embedded: boolean(?: = false)?;/u);
  assert.match(proxiesSource, /if \(this\.embedded\) \{[\s\S]*this\.buildProxyContent\(\)/u);
  assert.match(proxiesSource, /Scroll\(\) \{[\s\S]*Row\(\{ space: \$r\('app\.float\.space_sm'\) \}\)[\s\S]*scrollable\(ScrollDirection\.Horizontal\)/u);
});

test('ProxyViewModel clears stale rows and rejects an authoritative profile mismatch', async () => {
  const source = await readUtf8(PROXY_VIEW_MODEL_PATH);

  assert.match(source, /async load\(expectedProfileId\?: string\): Promise<void>/u);
  assert.match(
    source,
    /this\.publish\(createProxyViewState\('LOADING', \[\], \[\],[\s\S]*if \(this\.hasDelayLifecycleWork\(\)\)/u
  );
  assert.match(
    source,
    /expectedProfileId !== undefined && listResult\.identity\.profileId !== expectedProfileId[\s\S]*'PROXY_PROFILE_UNAVAILABLE'/u
  );
});

test('teardown consumes an explicit proxy delay-drain result', async () => {
  const [indexSource, proxyViewModelSource] = await Promise.all([
    readUtf8(INDEX_PATH),
    readUtf8(PROXY_VIEW_MODEL_PATH)
  ]);

  assert.match(proxyViewModelSource, /private disposePromise\?: Promise<boolean>;/u);
  assert.match(proxyViewModelSource, /dispose\(\): Promise<boolean>/u);
  assert.match(proxyViewModelSource, /let didDrain: boolean = true;/u);
  assert.match(proxyViewModelSource, /catch \(_error\) \{\s*didDrain = false;\s*\}/u);
  assert.match(proxyViewModelSource, /return didDrain;/u);
  assert.match(indexSource, /private proxyDisposeDrainFailed: boolean = false;/u);
  assert.match(indexSource, /private proxyDisposeGeneration: number = 0;/u);
  assert.match(indexSource, /proxyViewModel\.dispose\(\)\.then\(\(didDrain: boolean\): void => \{\s*this\.handleProxyDisposeResult\(didDrain, disposeGeneration\);/u);
  assert.match(indexSource, /private handleProxyDisposeResult\(didDrain: boolean, disposeGeneration: number\): void/u);
  assert.match(indexSource, /if \(disposeGeneration !== this\.proxyDisposeGeneration\) \{\s*return;\s*\}/u);
  assert.match(indexSource, /this\.proxyDisposeDrainFailed = !didDrain;[\s\S]*if \(didDrain\) \{[\s\S]*return;[\s\S]*\}/u);
  assert.match(indexSource, /createAppError\(\s*'RUNTIME_STOP',\s*'Proxy delay lifecycle cleanup failed\.'/u);
  assert.match(indexSource, /this\.compositionStatus = 'ERROR';[\s\S]*this\.compositionError = cleanupError;/u);
  assert.match(indexSource, /const disposeGeneration: number = this\.proxyDisposeGeneration \+ 1;\s*this\.proxyDisposeGeneration = disposeGeneration;/u);
  assert.match(indexSource, /this\.application = application;[\s\S]*this\.proxyDisposeGeneration \+= 1;/u);
});
