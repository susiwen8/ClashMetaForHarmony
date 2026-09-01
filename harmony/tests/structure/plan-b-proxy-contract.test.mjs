import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import {
  CORE_EXPORTS,
  PLAN_B_PROXY_ERROR_CODES,
  PLAN_B_PROXY_LIMITS,
  PLAN_B_PROXY_NAPI_METHODS,
  PLAN_B_PROXY_RUNTIME_TYPES,
  PLAN_B_PROXY_SHARED_METHODS,
  RAW_PROXY_DELAY_EXPORTS,
  RAW_PROXY_EXPORTS
} from '../../tools/lib/native-provenance.mjs';

const harmonyRoot = path.resolve(new URL('../..', import.meta.url).pathname);
const repoRoot = path.resolve(harmonyRoot, '..');
const coreProxyModelsPath = path.join(harmonyRoot, 'shared', 'src', 'main', 'ets', 'core', 'CoreProxyModels.ets');
const coreServicePath = path.join(harmonyRoot, 'shared', 'src', 'main', 'ets', 'core', 'CoreService.ets');
const coreErrorsPath = path.join(harmonyRoot, 'shared', 'src', 'main', 'ets', 'core', 'CoreErrors.ets');
const nativeAdapterPath = path.join(harmonyRoot, 'core', 'src', 'main', 'ets', 'CoreNativeAdapter.ets');
const proxyCodecPath = path.join(harmonyRoot, 'core', 'src', 'main', 'ets', 'ProxyNativeCodec.ets');
const typeDeclarationsPath = path.join(harmonyRoot, 'entry', 'src', 'main', 'cpp', 'types', 'libentry', 'Index.d.ts');
const backendSourcePath = path.join(harmonyRoot, 'entry', 'src', 'main', 'cpp', 'src', 'cmfa_mihomo_backend.cpp');
const goExportPath = path.join(harmonyRoot, 'core', 'go', 'cmd', 'cmfa_core', 'main.go');
const phase1ExamplePath = path.join(harmonyRoot, 'tests', 'fixtures', 'phase1-device-proof.example.json');
const nativeProxyDocPath = path.join(repoRoot, 'docs', 'harmony', 'native-proxy-contract.md');

const FORBIDDEN_PROXY_MODEL_FIELDS = [
  'server',
  'port',
  'uuid',
  'password',
  'token',
  'certificate',
  'provider',
  'delay',
  'url'
];

function extractQuotedEntries(body, arrayName) {
  const match = body.match(new RegExp(`\\b${arrayName}\\b[\\s\\S]*?=\\s*\\[([\\s\\S]*?)\\]`, 'u'));
  assert.ok(match, `expected ${arrayName} to be declared`);
  return [...match[1].matchAll(/'([^']+)'/gu)].map((entry) => entry[1]);
}

function extractInterfaceBlock(body, interfaceName) {
  const match = body.match(new RegExp(`export interface ${interfaceName}(?:\\s+extends\\s+[A-Za-z0-9_, ]+)?\\s*\\{([\\s\\S]*?)\\n\\}`, 'u'));
  assert.ok(match, `expected interface ${interfaceName}`);
  return match[1];
}

function extractPropertyNames(interfaceBody) {
  return [...interfaceBody.matchAll(/^\s*([A-Za-z][A-Za-z0-9]*)\s*:/gmu)].map((match) => match[1]);
}

function extractMethodNames(interfaceBody) {
  return [...interfaceBody.matchAll(/^\s*([A-Za-z][A-Za-z0-9]*)\s*\(/gmu)].map((match) => match[1]);
}

function countLiteralOccurrences(body, literal) {
  return body.split(literal).length - 1;
}

test('plan b proxy authority exports pin exact raw exports, methods, limits, runtime types, and error codes', () => {
  assert.deepEqual(RAW_PROXY_EXPORTS, [
    'cmfa_mihomo_proxy_groups_v1',
    'cmfa_mihomo_proxy_group_v1',
    'cmfa_mihomo_proxy_select_v1'
  ]);
  assert.deepEqual(RAW_PROXY_DELAY_EXPORTS, [
    'cmfa_mihomo_proxy_delay_start_v1',
    'cmfa_mihomo_proxy_delay_snapshot_v1',
    'cmfa_mihomo_proxy_delay_cancel_v1'
  ]);
  assert.deepEqual(PLAN_B_PROXY_NAPI_METHODS, [
    'queryProxyGroups',
    'queryProxyGroup',
    'selectProxy'
  ]);
  assert.deepEqual(PLAN_B_PROXY_SHARED_METHODS, PLAN_B_PROXY_NAPI_METHODS);
  assert.deepEqual(PLAN_B_PROXY_ERROR_CODES, [
    'PROXY_RUNTIME_NOT_READY',
    'PROXY_GROUP_NOT_FOUND',
    'PROXY_GROUP_NOT_SELECTABLE',
    'PROXY_MEMBER_NOT_FOUND',
    'PROXY_SELECTION_FAILED',
    'PROXY_BRIDGE_INVALID'
  ]);
  assert.deepEqual(PLAN_B_PROXY_LIMITS, {
    maxGroupCount: 128,
    maxNodeCount: 1024,
    maxNameUtf8Bytes: 256,
    maxRawJsonBytes: 1024 * 1024
  });
  assert.ok(RAW_PROXY_EXPORTS.every((symbol) => CORE_EXPORTS.includes(symbol)));
  assert.ok(RAW_PROXY_DELAY_EXPORTS.every((symbol) => CORE_EXPORTS.includes(symbol)));
  assert.deepEqual(RAW_PROXY_EXPORTS, [
    'cmfa_mihomo_proxy_groups_v1',
    'cmfa_mihomo_proxy_group_v1',
    'cmfa_mihomo_proxy_select_v1'
  ], 'plan b proxy authority must stay unchanged');
  assert.equal(
    RAW_PROXY_EXPORTS.every((symbol) => !RAW_PROXY_DELAY_EXPORTS.includes(symbol)),
    true,
    'delay authority must stay disjoint from legacy proxy authority'
  );
  assert.equal(new Set(CORE_EXPORTS).size, CORE_EXPORTS.length, 'core export authority must not duplicate symbols');
  assert.equal(new Set(PLAN_B_PROXY_RUNTIME_TYPES).size, PLAN_B_PROXY_RUNTIME_TYPES.length, 'runtime type authority must stay deduplicated');
  assert.deepEqual([...CORE_EXPORTS].slice().sort(), CORE_EXPORTS, 'core export authority must stay sorted');
});

test('plan b proxy models and typed surfaces stay metadata-only and exact', async () => {
  const [modelsBody, serviceBody, dtsBody] = await Promise.all([
    fs.readFile(coreProxyModelsPath, 'utf8'),
    fs.readFile(coreServicePath, 'utf8'),
    fs.readFile(typeDeclarationsPath, 'utf8')
  ]);

  const interfaceNames = [
    'CoreProxyQueryContext',
    'CoreProxyGroupRef',
    'CoreProxyNodeSummary',
    'CoreProxyGroupSnapshot',
    'CoreProxyGroupList',
    'CoreProxyGroupResult',
    'CoreProxySelectionApplied'
  ];
  const propertyNames = interfaceNames
    .flatMap((name) => extractPropertyNames(extractInterfaceBlock(modelsBody, name)));
  for (const forbiddenField of FORBIDDEN_PROXY_MODEL_FIELDS) {
    assert.equal(propertyNames.includes(forbiddenField), false, `proxy models must not expose ${forbiddenField}`);
  }

  const serviceMethods = extractMethodNames(extractInterfaceBlock(serviceBody, 'CoreService'));
  const legacyProxyMethods = serviceMethods.filter((name) => /^queryProxy|^selectProxy$/u.test(name));
  const delayProxyMethods = serviceMethods.filter((name) => name.includes('ProxyDelay'));
  assert.deepEqual(legacyProxyMethods, PLAN_B_PROXY_SHARED_METHODS);
  assert.deepEqual(delayProxyMethods, [
    'startProxyDelayTest',
    'readProxyDelayTest',
    'cancelProxyDelayTest'
  ]);

  const dtsProxyMethods = [...dtsBody.matchAll(/^export declare function (queryProxyGroups|queryProxyGroup|selectProxy)\s*\(/gmu)]
    .map((match) => match[1]);
  assert.deepEqual(dtsProxyMethods, PLAN_B_PROXY_NAPI_METHODS);
});

test('plan b proxy source files pin exact runtime types and raw export authorities without sensitive echoing', async () => {
  const [codecBody, errorsBody, adapterBody, backendBody, goBody] = await Promise.all([
    fs.readFile(proxyCodecPath, 'utf8'),
    fs.readFile(coreErrorsPath, 'utf8'),
    fs.readFile(nativeAdapterPath, 'utf8'),
    fs.readFile(backendSourcePath, 'utf8'),
    fs.readFile(goExportPath, 'utf8')
  ]);

  assert.deepEqual(extractQuotedEntries(codecBody, 'PROXY_TYPE_ALLOWLIST'), PLAN_B_PROXY_RUNTIME_TYPES);

  for (const symbol of RAW_PROXY_EXPORTS) {
    assert.equal(countLiteralOccurrences(backendBody, symbol) >= 1, true, `${symbol} must exist in the hidden backend adapter`);
    assert.equal(countLiteralOccurrences(goBody, symbol) >= 1, true, `${symbol} must exist in the Go export surface`);
  }

  const proxyCodes = new Set([
    ...errorsBody.matchAll(/'((?:PROXY|CMFA_[A-Z_]+)[A-Z0-9_]*)'/gu)
  ].map((match) => match[1]).filter((code) => code.startsWith('PROXY_')));
  for (const code of proxyCodes) {
    assert.ok(PLAN_B_PROXY_ERROR_CODES.includes(code), `unexpected proxy code ${code}`);
  }

  const sensitiveEchoPatterns = [
    /\$\{groupName\}/u,
    /\$\{memberName\}/u,
    /\$\{profileHash\}/u,
    /\$\{revisionHash\}/u,
    /\$\{sessionHash\}/u,
    /\+\s*groupName\b/u,
    /\+\s*memberName\b/u,
    /\+\s*raw\b/u
  ];
  const echoTargets = `${errorsBody}\n${adapterBody}`;
  for (const pattern of sensitiveEchoPatterns) {
    assert.doesNotMatch(echoTargets, pattern);
  }
});

test('plan b proxy proof/example/doc artifacts stay privacy-safe and scoped to host plus packaged-native evidence', async () => {
  const [exampleRaw, docRaw] = await Promise.all([
    fs.readFile(phase1ExamplePath, 'utf8'),
    fs.readFile(nativeProxyDocPath, 'utf8')
  ]);

  for (const forbidden of [
    /"server"\s*:/u,
    /"port"\s*:/u,
    /"uuid"\s*:/u,
    /"password"\s*:/u,
    /"token"\s*:/u,
    /"certificate"\s*:/u,
    /"provider"\s*:/u,
    /"delay"\s*:/u,
    /"url"\s*:/u
  ]) {
    assert.doesNotMatch(exampleRaw, forbidden);
  }

  assert.match(docRaw, /Plan B/u);
  assert.match(docRaw, /host \+ packaged-native contract evidence only/u);
  assert.match(docRaw, /No current physical subscription query/u);
  assert.match(docRaw, /No current .* UI/u);
  assert.match(docRaw, /No current persistence/u);
  assert.match(docRaw, /No current VPN replay/u);
  assert.match(docRaw, /No current physical HTTPS claim/u);
  assert.match(docRaw, /Plan C\/D\/device gates remain/u);
  assert.match(docRaw, /\bcounts\b/iu);
  assert.match(docRaw, /\bhash(?:es)?\b/iu);

  for (const forbidden of [
    /https?:\/\//iu,
    /file:\/\//iu,
    /\/Users\//u,
    /[A-Za-z]:\\\\/u,
    /\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b/u,
    /\b[a-z0-9.-]+\.(?:com|net|org|io)(?::\d+)?\b/iu
  ]) {
    assert.doesNotMatch(docRaw, forbidden);
  }
});
