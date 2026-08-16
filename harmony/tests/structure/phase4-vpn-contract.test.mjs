import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry');
const ETS_ROOT = path.join(ENTRY_ROOT, 'src', 'main', 'ets');
const MODULE_JSON_PATH = path.join(ENTRY_ROOT, 'src', 'main', 'module.json5');
const STRINGS_PATH = path.join(ENTRY_ROOT, 'src', 'main', 'resources', 'base', 'element', 'string.json');
const HOME_PAGE_PATH = path.join(ETS_ROOT, 'pages', 'HomePage.ets');
const CARD_PATH = path.join(ETS_ROOT, 'components', 'RuntimeStatusCard.ets');
const SAFE_ERROR_CARD_PATH = path.join(ETS_ROOT, 'components', 'SafeErrorCard.ets');
const HVIGOR_WRAPPER_PATH = path.join(HARMONY_ROOT, 'hvigorw');

const EXACT_STRING_VALUES = new Map([
  ['home_local_title', 'Local proxy'],
  ['home_vpn_title', 'VPN global capture'],
  ['home_local_primary_start', 'Start Local proxy'],
  ['home_local_primary_stop', 'Stop Local proxy'],
  ['home_local_boundary_note', 'Only the explicit local HTTP and SOCKS listeners started here are supported.'],
  ['home_vpn_primary_start', 'Start VPN global capture'],
  ['home_vpn_primary_stop', 'Stop VPN global capture'],
  ['home_vpn_boundary_note', 'TUN capture is limited to traffic handled by this app session.'],
  ['home_vpn_notification_label', 'Continuous notification'],
  ['error_vpn_permission_denied', 'VPN permission was denied.'],
  ['error_vpn_requires_local_stop', 'Stop the local proxy before starting VPN global capture.'],
  ['error_local_blocked_by_vpn', 'Stop VPN global capture before starting the local proxy.']
]);

const FORBIDDEN_PERMISSION_PATTERNS = [
  'MANAGE_VPN',
  'GET_NETWORK_INFO',
  'enterprise',
  'settings'
];

const FORBIDDEN_COPY_PATTERNS = [
  'system proxy',
  'global HTTP proxy',
  'always-on',
  'lockdown',
  'enterprise',
  '系统代理',
  '全局 HTTP 代理',
  '企业'
];

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

async function readJson(filePath) {
  return JSON.parse(await fs.readFile(filePath, 'utf8'));
}

function getStringValue(document, key) {
  const entry = (document.string ?? []).find((candidate) => candidate.name === key);
  return entry?.value;
}

test('phase4 vpn contract keeps the production manifest to the minimal VPN surface', async () => {
  const moduleDocument = await readJson(MODULE_JSON_PATH);
  const permissions = moduleDocument.module.requestPermissions ?? [];
  const permissionNames = permissions.map((permission) => permission.name);

  assert.deepEqual(permissionNames, [
    'ohos.permission.INTERNET',
    'ohos.permission.KEEP_BACKGROUND_RUNNING'
  ], 'module.json5 must declare exactly INTERNET and KEEP_BACKGROUND_RUNNING');

  const extensions = moduleDocument.module.extensionAbilities ?? [];
  assert.equal(extensions.length, 1, 'module.json5 must declare exactly one extension ability');
  assert.deepEqual(extensions[0], {
    name: 'CmfaVpnExtensionAbility',
    srcEntry: './ets/vpn/CmfaVpnExtensionAbility.ets',
    type: 'vpn',
    exported: false
  }, 'VPN extension ability contract drifted');

  const serialized = JSON.stringify(moduleDocument);
  for (const forbidden of FORBIDDEN_PERMISSION_PATTERNS) {
    assert.doesNotMatch(serialized, new RegExp(forbidden, 'iu'), `module.json5 must not mention forbidden capability ${forbidden}`);
  }
});

test('phase4 vpn contract keeps hvigorw as a direct integrated-wrapper adapter without manifest rewriting', async () => {
  const wrapperSource = await readUtf8(HVIGOR_WRAPPER_PATH);

  assert.match(wrapperSource, /exec "\$\{INTEGRATED_HVIGOR_WRAPPER\}" "\$@"/u,
    'hvigorw must exec the integrated wrapper directly'
  );
  assert.doesNotMatch(wrapperSource, /backgroundModes/u,
    'hvigorw must not special-case backgroundModes'
  );
  assert.doesNotMatch(wrapperSource, /sanitize_entry_manifest|restore_entry_manifest|ENTRY_MODULE_JSON|MANIFEST_BACKUP_PATH/u,
    'hvigorw must not read, back up, or rewrite module.json5'
  );
  assert.doesNotMatch(wrapperSource, /perl/u,
    'hvigorw must not shell out to perl for manifest rewriting'
  );
});

test('phase4 vpn contract keeps exact Local proxy / VPN global capture resources and safe copy', async () => {
  const [stringDocument, homePageSource, cardSource, safeErrorCardSource] = await Promise.all([
    readJson(STRINGS_PATH),
    readUtf8(HOME_PAGE_PATH),
    readUtf8(CARD_PATH),
    readUtf8(SAFE_ERROR_CARD_PATH)
  ]);

  for (const [key, value] of EXACT_STRING_VALUES) {
    assert.equal(getStringValue(stringDocument, key), value, `string.json key ${key} must stay exact`);
  }

  const resourceValues = (stringDocument.string ?? []).map((entry) => `${entry.value ?? ''}`).join('\n');
  const combinedSource = `${homePageSource}\n${cardSource}\n${safeErrorCardSource}\n${resourceValues}`;
  assert.match(homePageSource, /\.id\('home\.local\.action'\)/u, 'HomePage must own the local proxy action');
  assert.match(homePageSource, /\.id\('home\.vpn\.action'\)/u, 'HomePage must own the VPN global capture action');
  assert.match(cardSource, /\$r\('app\.string\.home_vpn_notification_label'\)/u, 'RuntimeStatusCard must surface notification facts');
  assert.match(cardSource, /\$r\('app\.string\.home_vpn_recovery_label'\)/u, 'RuntimeStatusCard must surface recovery facts');
  assert.match(cardSource, /\$r\('app\.string\.home_local_http_label'\)/u, 'RuntimeStatusCard must surface HTTP listener facts');
  assert.match(cardSource, /\$r\('app\.string\.home_local_socks_label'\)/u, 'RuntimeStatusCard must surface SOCKS listener facts');

  for (const forbidden of FORBIDDEN_COPY_PATTERNS) {
    assert.doesNotMatch(combinedSource, new RegExp(forbidden.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'iu'),
      `production UI code must not claim forbidden networking scope: ${forbidden}`
    );
  }
});
