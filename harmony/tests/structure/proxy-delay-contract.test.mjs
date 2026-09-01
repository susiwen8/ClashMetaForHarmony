import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  CORE_EXPORTS,
  RAW_PROXY_DELAY_EXPORTS,
  RAW_PROXY_EXPORTS
} from '../../tools/lib/native-provenance.mjs';

const REPO_ROOT = fileURLToPath(new URL('../../..', import.meta.url));
const HARMONY_ROOT = path.join(REPO_ROOT, 'harmony');
const CORE_ROOT = path.join(HARMONY_ROOT, 'core');
const SHARED_ROOT = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets');
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets');
const DOC_PATH = path.join(REPO_ROOT, 'docs', 'harmony', 'proxy-delay-test.md');

const GO_MAIN_PATH = path.join(CORE_ROOT, 'go', 'cmd', 'cmfa_core', 'main.go');
const GO_DELAY_JOB_PATH = path.join(CORE_ROOT, 'go', 'internal', 'proxygroups', 'delay_job.go');
const GO_DELAY_MODELS_PATH = path.join(CORE_ROOT, 'go', 'internal', 'proxygroups', 'delay_models.go');
const GO_DELAY_MIHOMO_PATH = path.join(CORE_ROOT, 'go', 'internal', 'proxygroups', 'delay_mihomo.go');
const CORE_HEADER_PATH = path.join(CORE_ROOT, 'abi', 'include', 'cmfa_core.h');
const HOST_HEADER_PATH = path.join(CORE_ROOT, 'abi', 'include', 'cmfa_host.h');
const BACKEND_SOURCE_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src', 'cmfa_mihomo_backend.cpp');
const DTS_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'types', 'libentry', 'Index.d.ts');
const CORE_SERVICE_PATH = path.join(SHARED_ROOT, 'core', 'CoreService.ets');
const CORE_DELAY_MODELS_PATH = path.join(SHARED_ROOT, 'core', 'CoreProxyDelayModels.ets');
const CORE_ADAPTER_PATH = path.join(CORE_ROOT, 'src', 'main', 'ets', 'CoreNativeAdapter.ets');
const CORE_DELAY_CODEC_PATH = path.join(CORE_ROOT, 'src', 'main', 'ets', 'ProxyDelayNativeCodec.ets');
const SHARED_DELAY_MODELS_PATH = path.join(SHARED_ROOT, 'proxy', 'ProxyDelayModels.ets');
const PROXY_PORTS_PATH = path.join(SHARED_ROOT, 'proxy', 'ProxyPorts.ets');
const PROXY_SERVICE_PATH = path.join(SHARED_ROOT, 'proxy', 'ProxyService.ets');
const PROXY_HANDLER_PATH = path.join(SHARED_ROOT, 'proxy', 'VpnProxyRuntimeHandler.ets');
const PROFILE_APPLICATION_PATH = path.join(SHARED_ROOT, 'profile', 'ProfileApplication.ets');
const VIEW_MODEL_PATH = path.join(ENTRY_ROOT, 'presentation', 'ProxyViewModel.ets');
const PAGE_PATH = path.join(ENTRY_ROOT, 'pages', 'ProxiesPage.ets');
const STRINGS_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'string.json');
const PROOF_RUNNER_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'run-phase4-device-proof.mjs');
const PROOF_SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase4-device-proof.schema.json');
const SOURCE_PRIVACY_BUCKETS = Object.freeze({
  go: [GO_MAIN_PATH, GO_DELAY_JOB_PATH, GO_DELAY_MODELS_PATH, GO_DELAY_MIHOMO_PATH],
  cpp: [BACKEND_SOURCE_PATH],
  shared: [CORE_SERVICE_PATH, SHARED_DELAY_MODELS_PATH, PROXY_PORTS_PATH, PROXY_SERVICE_PATH, PROXY_HANDLER_PATH, PROFILE_APPLICATION_PATH],
  entry: [VIEW_MODEL_PATH, PAGE_PATH]
});
const SYNTHETIC_FORBIDDEN_PROOF_KEYS = Object.freeze([
  'sessionId',
  'deviceId',
  'layoutText',
  'url',
  'credential',
  'jobId',
  'groupName',
  'nodeName',
  'provider',
  'endpoint'
]);
const ACTUAL_FORBIDDEN_PROOF_KEYS = Object.freeze([
  'deviceId',
  'layoutText',
  'credential',
  'jobId',
  'groupName',
  'nodeName',
  'provider',
  'endpoint'
]);
const SENSITIVE_SINK_EXPR = String.raw`(?:groupName|memberName|nodeName|provider(?:Name)?|endpoint|credential|jobId|row\.name|group\.name|node\.name|record\.(?:groupName|selectedNodeName))`;
const ERROR_SENSITIVE_EXPR = String.raw`(?:groupName|memberName|nodeName|provider(?:Name)?|endpoint|url|credential|jobId)`;

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
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

function collectScannerMatches(source) {
  const rules = [
    new RegExp(String.raw`\.id\(\s*` + "`" + String.raw`[^` + "`" + String.raw`]*\$\{[^}]*${SENSITIVE_SINK_EXPR}[^}]*\}[^` + "`" + String.raw`]*` + "`" + String.raw`\s*\)`, 'gu'),
    new RegExp(String.raw`\.id\(\s*[^)\n]*(?:${SENSITIVE_SINK_EXPR})\s*\+\s*[^)\n]*\)`, 'gu'),
    new RegExp(String.raw`\.id\(\s*[^)\n]*\+\s*(?:${SENSITIVE_SINK_EXPR})[^)\n]*\)`, 'gu'),
    new RegExp(String.raw`\.id\(\s*(?:${SENSITIVE_SINK_EXPR})\s*\)`, 'gu'),
    new RegExp(String.raw`(?:console|hilog)\.[a-z]+\([^)\n]*` + "`" + String.raw`[^` + "`" + String.raw`]*\$\{[^}]*${ERROR_SENSITIVE_EXPR}[^}]*\}[^` + "`" + String.raw`]*` + "`" + String.raw``, 'gu'),
    new RegExp(String.raw`(?:console|hilog)\.[a-z]+\([^)\n]*(?:${ERROR_SENSITIVE_EXPR})\s*\+\s*[^)\n]*\)`, 'gu'),
    new RegExp(String.raw`(?:console|hilog)\.[a-z]+\([^)\n]*\+\s*(?:${ERROR_SENSITIVE_EXPR})[^)\n]*\)`, 'gu'),
    new RegExp(String.raw`hilog\.[a-z]+\([^)\n]*,\s*(?:${ERROR_SENSITIVE_EXPR})(?:\s*[),])`, 'gu'),
    new RegExp(String.raw`console\.[a-z]+\([^)\n]*,\s*(?:${ERROR_SENSITIVE_EXPR})(?:\s*[),])`, 'gu'),
    new RegExp(String.raw`new Error\(\s*` + "`" + String.raw`[^` + "`" + String.raw`]*\$\{[^}]*${ERROR_SENSITIVE_EXPR}[^}]*\}[^` + "`" + String.raw`]*` + "`" + String.raw`\s*\)`, 'gu'),
    new RegExp(String.raw`new Error\(\s*[^)\n]*(?:${ERROR_SENSITIVE_EXPR})\s*\+\s*[^)\n]*\)`, 'gu'),
    new RegExp(String.raw`new Error\(\s*[^)\n]*\+\s*(?:${ERROR_SENSITIVE_EXPR})[^)\n]*\)`, 'gu'),
    new RegExp(String.raw`fmt\.Errorf\([^)\n]*\b(?:${ERROR_SENSITIVE_EXPR})\b`, 'gu'),
    new RegExp(String.raw`JSON\.stringify\(\s*(?:delaySnapshot|proxySnapshot|proxyState|delayState|delayViewSnapshot)\s*\)`, 'gu')
  ];
  return rules.flatMap((pattern) => [...source.matchAll(pattern)].map((match) => match[0]));
}

function collectForbiddenProofSchemaKeys(document, forbiddenKeys, trail = []) {
  const violations = [];
  if (Array.isArray(document)) {
    for (let index = 0; index < document.length; index += 1) {
      const value = document[index];
      if (typeof value === 'string' && forbiddenKeys.includes(value) && trail.at(-1) === 'required') {
        violations.push(`${trail.join('.')}[${index}]=${value}`);
      } else {
        violations.push(...collectForbiddenProofSchemaKeys(value, forbiddenKeys, [...trail, String(index)]));
      }
    }
    return violations;
  }
  if (document === null || typeof document !== 'object') {
    return violations;
  }
  for (const [key, value] of Object.entries(document)) {
    if (trail.at(-1) === 'properties' && forbiddenKeys.includes(key)) {
      violations.push(`${trail.join('.')} -> ${key}`);
    }
    violations.push(...collectForbiddenProofSchemaKeys(value, forbiddenKeys, [...trail, key]));
  }
  return violations;
}

test('proxy delay contract pins exact cross-layer exports enums bounds and result semantics', async () => {
  const [
    goMain,
    delayJobSource,
    delayModelsSource,
    delayMihomoSource,
    coreHeader,
    hostHeader,
    backendSource,
    dtsSource,
    coreServiceSource,
    coreDelayModelsSource,
    coreAdapterSource,
    codecSource,
    sharedDelayModelsSource,
    portsSource,
    serviceSource,
    handlerSource,
    applicationSource,
    viewModelSource,
    pageSource,
    stringsSource
  ] = await Promise.all([
    readUtf8(GO_MAIN_PATH),
    readUtf8(GO_DELAY_JOB_PATH),
    readUtf8(GO_DELAY_MODELS_PATH),
    readUtf8(GO_DELAY_MIHOMO_PATH),
    readUtf8(CORE_HEADER_PATH),
    readUtf8(HOST_HEADER_PATH),
    readUtf8(BACKEND_SOURCE_PATH),
    readUtf8(DTS_PATH),
    readUtf8(CORE_SERVICE_PATH),
    readUtf8(CORE_DELAY_MODELS_PATH),
    readUtf8(CORE_ADAPTER_PATH),
    readUtf8(CORE_DELAY_CODEC_PATH),
    readUtf8(SHARED_DELAY_MODELS_PATH),
    readUtf8(PROXY_PORTS_PATH),
    readUtf8(PROXY_SERVICE_PATH),
    readUtf8(PROXY_HANDLER_PATH),
    readUtf8(PROFILE_APPLICATION_PATH),
    readUtf8(VIEW_MODEL_PATH),
    readUtf8(PAGE_PATH),
    readUtf8(STRINGS_PATH)
  ]);

  assert.deepEqual(RAW_PROXY_DELAY_EXPORTS, [
    'cmfa_mihomo_proxy_delay_start_v1',
    'cmfa_mihomo_proxy_delay_snapshot_v1',
    'cmfa_mihomo_proxy_delay_cancel_v1'
  ]);
  assert.equal(new Set(RAW_PROXY_DELAY_EXPORTS).size, RAW_PROXY_DELAY_EXPORTS.length);
  assert.equal(RAW_PROXY_DELAY_EXPORTS.every((entry) => !RAW_PROXY_EXPORTS.includes(entry)), true);
  assert.deepEqual([...CORE_EXPORTS].sort(), [...CORE_EXPORTS], 'CORE_EXPORTS must stay lexically sorted');

  for (const symbol of RAW_PROXY_DELAY_EXPORTS) {
    assert.match(goMain, new RegExp(`//export ${symbol}\\b`, 'u'));
    assert.equal(CORE_EXPORTS.includes(symbol), true, `${symbol} must stay in the core export contract`);
  }

  assert.match(coreHeader, /cmfa_proxy_delay_start\(const cmfa_proxy_query_context \*context,[\s\S]*const char \*group_name,[\s\S]*cmfa_json_buffer \*output,[\s\S]*cmfa_error \*error\)/u);
  assert.match(coreHeader, /cmfa_proxy_delay_snapshot\(const char \*job_id,[\s\S]*cmfa_json_buffer \*output,[\s\S]*cmfa_error \*error\)/u);
  assert.match(coreHeader, /cmfa_proxy_delay_cancel\(const char \*job_id,[\s\S]*cmfa_json_buffer \*output,[\s\S]*cmfa_error \*error\)/u);
  assert.match(hostHeader, /cmfa_status \(\*proxy_delay_start\)\(void \*context,[\s\S]*const cmfa_proxy_query_context \*query,[\s\S]*const char \*group_name/u);
  assert.match(hostHeader, /cmfa_status \(\*proxy_delay_snapshot\)\(void \*context,[\s\S]*const char \*job_id/u);
  assert.match(hostHeader, /cmfa_status \(\*proxy_delay_cancel\)\(void \*context,[\s\S]*const char \*job_id/u);
  assert.match(backendSource, /extern "C" cmfa_status cmfa_mihomo_proxy_delay_start_v1/u);
  assert.match(backendSource, /extern "C" cmfa_status cmfa_mihomo_proxy_delay_snapshot_v1/u);
  assert.match(backendSource, /extern "C" cmfa_status cmfa_mihomo_proxy_delay_cancel_v1/u);

  assert.match(dtsSource, /export declare function startProxyDelayTest\(context: ProxyQueryContext, groupName: string\): Promise<string>;/u);
  assert.match(dtsSource, /export declare function readProxyDelayTest\(jobId: string\): Promise<string>;/u);
  assert.match(dtsSource, /export declare function cancelProxyDelayTest\(jobId: string\): Promise<string>;/u);
  assert.match(coreServiceSource, /startProxyDelayTest\(context: CoreProxyQueryContext, groupName: string\): Promise<CoreProxyDelaySnapshot>;/u);
  assert.match(coreServiceSource, /readProxyDelayTest\(jobId: string\): Promise<CoreProxyDelaySnapshot>;/u);
  assert.match(coreServiceSource, /cancelProxyDelayTest\(jobId: string\): Promise<CoreProxyDelaySnapshot>;/u);
  assert.match(coreAdapterSource, /startProxyDelayTest\(context: CoreProxyQueryContext, groupName: string\): Promise<CoreProxyDelaySnapshot>/u);
  assert.match(coreAdapterSource, /readProxyDelayTest\(jobId: string\): Promise<CoreProxyDelaySnapshot>/u);
  assert.match(coreAdapterSource, /cancelProxyDelayTest\(jobId: string\): Promise<CoreProxyDelaySnapshot>/u);

  assert.match(coreDelayModelsSource, /export type CoreProxyDelayJobState = 'RUNNING' \| 'COMPLETED' \| 'CANCELLED' \| 'FAILED';/u);
  assert.match(coreDelayModelsSource, /export type CoreProxyDelayNodeState = 'WAITING' \| 'TESTING' \| 'AVAILABLE' \| 'TIMEOUT' \| 'FAILED' \| 'CANCELLED' \| 'UNSUPPORTED';/u);
  assert.match(coreDelayModelsSource, /export type CoreProxyDelayURLSource = 'PROVIDER' \| 'FALLBACK';/u);
  assert.match(sharedDelayModelsSource, /export interface ProxyDelaySnapshotResult \{[\s\S]*jobId: string;[\s\S]*completedCount: number;[\s\S]*unsupportedCount: number;[\s\S]*nodes: ProxyDelayNodeResult\[\];/u);
  assert.match(portsSource, /startDelayTest\(groupName: string,\s*snapshotGeneration: number,\s*groupPath\?: string\[\]\): Promise<ProxyDelayResult>;/u);
  assert.match(portsSource, /readDelayTest\(jobId: string\): Promise<ProxyDelayResult>;/u);
  assert.match(portsSource, /cancelDelayTest\(jobId: string\): Promise<ProxyDelayResult>;/u);
  assert.match(portsSource, /cancelAndDrainDelayTest\(\): Promise<ProxyRejectedResult \| undefined>;/u);
  assert.match(applicationSource, /async startDelayTest\(groupName: string,\s*snapshotGeneration: number,\s*groupPath\?: string\[\]\): Promise<ProxyDelayResult>/u);
  assert.match(applicationSource, /async readDelayTest\(jobId: string\): Promise<ProxyDelayResult>/u);
  assert.match(applicationSource, /async cancelDelayTest\(jobId: string\): Promise<ProxyDelayResult>/u);
  assert.match(handlerSource, /async startDelayTest\(command: VpnProxyStartDelayTestCommand\): Promise<ProxyDelayResult>/u);
  assert.match(handlerSource, /async readDelayTest\(command: VpnProxyReadDelayTestCommand\): Promise<ProxyDelayResult>/u);
  assert.match(handlerSource, /async cancelDelayTest\(command: VpnProxyCancelDelayTestCommand\): Promise<ProxyDelayResult>/u);
  assert.match(serviceSource, /async startDelayTest\(groupName: string,\s*snapshotGeneration: number,\s*groupPath\?: string\[\]\): Promise<ProxyDelayResult>/u);
  assert.match(serviceSource, /normalizedGroupPath = groupPath === undefined[\s\S]*:\s*cloneVpnProxyGroupPath\(groupPath,\s*normalizedGroupName\);/u);
  assert.match(serviceSource, /return await this\.startRunningDelayTest\(identity,\s*normalizedGroupName,\s*snapshotGeneration,\s*normalizedGroupPath\);/u);
  assert.match(serviceSource, /createVpnProxyStartDelayTestCommand\(identity,\s*generation,\s*groupName,\s*groupPath\)/u);
  assert.match(viewModelSource, /await this\.application\.startDelayTest\(groupName,\s*generation,\s*this\.cloneDisplayedGroupPath\(\)\)/u);

  assert.match(delayModelsSource, /DelayWorkerCount\s*=\s*16/u);
  assert.match(delayModelsSource, /DelayNodeTimeout\s*=\s*5 \* time\.Second/u);
  assert.match(delayModelsSource, /MaxDelayJobIDBytes\s*=\s*32/u);
  assert.match(delayModelsSource, /DefaultDelayTestURL = "https:\/\/www\.gstatic\.com\/generate_204"/u);
  assert.match(delayModelsSource, /delayJobIDPattern = regexp\.MustCompile\(`\^\[0-9a-f\]\{32\}\$`\)/u);
  assert.match(delayJobSource, /return hex\.EncodeToString\(raw\[:\]\), nil/u);
  assert.match(codecSource, /const MAX_RAW_BYTES: number = 1024 \* 1024;/u);
  assert.match(codecSource, /const MAX_NAME_BYTES: number = 256;/u);
  assert.match(codecSource, /const MAX_NODES: number = 1024;/u);
  assert.match(delayMihomoSource, /mihomoDelayProviderExpectedStatus = mustMihomoDelayExpectedStatus\("200-299"\)/u);
  assert.match(delayMihomoSource, /mihomoDelayFallbackExpectedStatus = mustMihomoDelayExpectedStatus\("204"\)/u);

  assert.match(delayJobSource, /func buildDelayJobNodes\(nodes \[\]DelayRuntimeNode\) \(\[\]DelayNodeResult, \[\]delayTask\) \{[\s\S]*for index, node := range nodes \{[\s\S]*Index:\s*index,[\s\S]*if node\.IsGroup \|\| node\.Probe == nil \{[\s\S]*DelayNodeStateUnsupported[\s\S]*continue[\s\S]*DelayNodeStateWaiting[\s\S]*tasks = append\(tasks, delayTask\{index: index, probe: node\.Probe\}\)/u);
  assert.match(delayJobSource, /func deriveDelayJobState\(nodes \[\]DelayNodeResult\) DelayJobState \{\s*return DelayJobStateCompleted\s*\}/u,
    'ordinary per-row outcomes must still resolve the job to COMPLETED'
  );
  assert.match(codecSource, /if \(node\.state === 'UNSUPPORTED'\) \{\s*counts\.unsupportedCount \+= 1;\s*\} else \{\s*counts\.testableCount \+= 1;\s*\}\s*if \(!isLiveNodeState\(node\.state\)\) \{\s*counts\.completedCount \+= 1;\s*\}/u,
    'completedCount must include UNSUPPORTED and exclude only WAITING/TESTING'
  );

  assert.match(serviceSource, /private activeDelayRecord\?: ActiveDelayRecord;/u);
  assert.match(viewModelSource, /const PROXY_DELAY_POLL_MS: number = 250;/u);
  assert.match(pageSource, /\.id\('proxies\.delay-test'\)/u);
  assert.match(pageSource, /\.id\('proxies\.delay-progress'\)/u);
  assert.match(pageSource, /\.id\('proxies\.delay-summary'\)/u);
  assert.match(stringsSource, /"name": "proxies_delay_fastest_summary"/u);
  assert.match(stringsSource, /"name": "proxies_delay_unsupported"/u);
});

test('proxy delay contract preserves delay lifecycle ordering across shared and UI boundaries', async () => {
  const [serviceSource, handlerSource, applicationSource, viewModelSource] = await Promise.all([
    readUtf8(PROXY_SERVICE_PATH),
    readUtf8(PROXY_HANDLER_PATH),
    readUtf8(PROFILE_APPLICATION_PATH),
    readUtf8(VIEW_MODEL_PATH)
  ]);

  assert.match(applicationSource, /async reconcileActiveSelections\(\): Promise<ProxyReconcileResult>[\s\S]*await this\.requireDelayDrainProxyRejected\(\)[\s\S]*safeProxyReconciliation/u);
  assert.match(applicationSource, /private async closeInternal\(\): Promise<void> \{[\s\S]*await this\.requireDelayDrainAppError\('PERSISTENCE'\)[\s\S]*this\.dispose\(\)[\s\S]*this\.runtimeCoordinator\.dispose\(\)/u);

  assert.match(handlerSource, /private async flushInvalidatedSession\(sessionId: string\): Promise<void> \{[\s\S]*this\.commandBus\.invalidate\(sessionId\)[\s\S]*await this\.cancelAndDrainDelayJob\(sessionId\)[\s\S]*await this\.commandBus\.deactivate\(sessionId\)[\s\S]*await this\.cancelAndDrainDelayJob\(sessionId\)/u);
  assert.match(handlerSource, /await this\.selectionRepository\.listByProfile\(state\.identity\.profileId\)[\s\S]*await this\.replaySelections\(state, records\)[\s\S]*this\.activeState = state[\s\S]*this\.commandBus\.bind\(state\.identity, this\)/u);
  assert.match(serviceSource, /private async drainDelayTestInsideQueue\(\): Promise<ProxyRejectedResult \| undefined> \{[\s\S]*await this\.cancelActiveDelayRecord\(record\)[\s\S]*if \(result\.kind === 'SNAPSHOT' && this\.isTerminalDelayState\(result\.state\)\) \{\s*return undefined;\s*\}/u);
  assert.match(serviceSource, /if \(snapshot\.state === 'RUNNING'\) \{[\s\S]*activeRequest\.sessionId[\s\S]*\}\s*if \(snapshot\.state === 'STOPPED' && activeRequest === null\) \{[\s\S]*null/u);
  assert.match(viewModelSource, /private scheduleNextDelayPoll\(epoch: number, jobId: string\): void \{\s*this\.cancelScheduledDelayTask\(\);\s*this\.scheduledDelayTask = this\.delayScheduler\.schedule\(PROXY_DELAY_POLL_MS/u);
  assert.match(viewModelSource, /async leave\(\): Promise<void> \{[\s\S]*await this\.application\.cancelAndDrainDelayTest\(\)[\s\S]*this\.clearDelayTracking\(\)/u);
  assert.match(viewModelSource, /dispose\(\): Promise<boolean> \{[\s\S]*await this\.application\.cancelAndDrainDelayTest\(\)[\s\S]*didDrain = false[\s\S]*await pendingStart[\s\S]*this\.clearDelayTracking\(\)[\s\S]*return didDrain/u);
});

test('proxy delay privacy scanner catches synthetic leaks while allowing the explicit safe exceptions', () => {
  const leaking = `
    .id(\`${'${row.name}'}.delay\`);
    .id('delay-' + row.name);
    console.info(\`delay ${'${jobId}'}\`);
    console.info('job=' + jobId);
    hilog.info(0, 'Delay', '%{public}s', groupName);
    throw new Error(\`bad ${'${groupName}'}\`);
    throw new Error('bad=' + groupName);
    JSON.stringify(delaySnapshot);
  `;
  const allowed = `
    Text(row.name);
    Text(createDelayFastestSummaryResource(fastestRow.name, fastestRow.delayMs));
    return record.groupName === expectedGroupName && record.selectedNodeName === expectedNodeName;
    new Error('jobId field must not be blank.');
  `;
  const proofFixture = {
    properties: {
      sessionId: { type: 'string' },
      deviceId: { type: 'string' },
      layoutText: { type: 'string' },
      url: { type: 'string' },
      credential: { type: 'string' },
      jobId: { type: 'string' },
      groupName: { type: 'string' },
      nodeName: { type: 'string' },
      provider: { type: 'string' },
      endpoint: { type: 'string' }
    },
    required: ['sessionId', 'groupName', 'jobId']
  };

  assert.notEqual(collectScannerMatches(leaking).length, 0, 'synthetic leaking fixture must trip the privacy scanner');
  assert.deepEqual(collectScannerMatches(allowed), [], 'safe text/equality cases must stay allowed');
  assert.notEqual(collectForbiddenProofSchemaKeys(proofFixture, SYNTHETIC_FORBIDDEN_PROOF_KEYS).length, 0,
    'synthetic proof-schema fixture must trip the forbidden-key scanner'
  );
});

test('proxy delay privacy scanner keeps actual UI proof and doc surfaces redacted', async () => {
  const bucketEntries = await Promise.all(
    Object.entries(SOURCE_PRIVACY_BUCKETS).map(async ([bucketName, filePaths]) => ({
      bucketName,
      source: (await Promise.all(filePaths.map(readUtf8))).join('\n')
    }))
  );
  const [proofRunnerSource, proofSchemaSource] = await Promise.all([
    readUtf8(PROOF_RUNNER_PATH),
    readUtf8(PROOF_SCHEMA_PATH)
  ]);
  const proofSchema = JSON.parse(proofSchemaSource);

  for (const { bucketName, source } of bucketEntries) {
    assert.deepEqual(
      collectScannerMatches(source),
      [],
      `${bucketName} source bucket must stay free of dangerous id/log/error/JSON privacy sinks`
    );
  }
  assert.deepEqual(
    collectForbiddenProofSchemaKeys(proofSchema, ACTUAL_FORBIDDEN_PROOF_KEYS),
    [],
    'tracked proof schema must not publish raw delay-sensitive property keys'
  );
  assertNoPattern('tracked proof runner must not persist raw delay-sensitive object keys', proofRunnerSource, /\b(?:deviceId|layoutText|credential|jobId|groupName|nodeName|provider|endpoint)\b\s*:/u);
  assertNoPattern('tracked proof runner must not serialize delay snapshots directly', proofRunnerSource, /JSON\.stringify\s*\([^)]*(?:delay|proxy).*snapshot/iu);
  assertNoPattern('tracked proof/doc surfaces must not publish subscription URLs or explicit secret payload fields', `${proofRunnerSource}\n${proofSchemaSource}`, /(?:subscription\s*(?:url|uri)|token=|password:|credential:|endpoint:)/iu);
});

test('proxy delay documentation stays versioned verification-oriented and redacted', async () => {
  const source = await readUtf8(DOC_PATH);

  for (const required of [
    '# Harmony Proxy Delay Test Contract',
    'API schema version: `1.0.0`',
    'Raw Go exports: `cmfa_mihomo_proxy_delay_start_v1`, `cmfa_mihomo_proxy_delay_snapshot_v1`, `cmfa_mihomo_proxy_delay_cancel_v1`',
    'Worker/count bounds: `16 workers`, `5s` per node, `250ms` poll cadence, `1024` nodes, `256` UTF-8 bytes, `1 MiB` JSON, `32` lowercase-hex job IDs',
    'Expected-status rule: provider-backed URLs accept `200-299`; fallback accepts only fixed `204` probe responses from the canonical fallback endpoint invariant',
    'Lifecycle rule: drain proxy delay work before config reload, VPN replay changes, or VPN stop cleanup',
    'Delay-test results only describe node probing; they do not prove that system VPN/TUN capture is active.',
    'UI semantics: one active delay run, no auto-select, original node order preserved, `completedCount` excludes only live `WAITING`/`TESTING` rows and includes `UNSUPPORTED`',
    'Focused verification command:',
    'Full structure suite command:',
    'Focused structure cases verified on 2026-08-23:',
    'Full structure suite verified on 2026-08-23:'
  ]) {
    assert.equal(source.includes(required), true, `missing doc contract: ${required}`);
  }

  assertNoPattern('delay doc must not leak private profile/session/job or device fields', source, /\b(?:profileId|sessionId|jobId|deviceId)\b/u);
  assertNoPattern('delay doc must not leak raw proxy labels or provider names', source, /\b(?:groupName|memberName|nodeName|providerName)\b/u);
  assertNoPattern('delay doc must not leak endpoint or signing material', source, /(?:\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b|\.hap\b|\.p12\b|\.cer\b|\.pem\b|signing|keystore)/iu);
  assertNoPattern('delay doc must not include subscription payload examples', source, /(?:subscription\s*(?:url|uri)|proxy-groups:|proxies:|mixed-port:|token=)/iu);
  assertNoPattern('delay doc must not leak explicit http(s) probe or test urls', source, /https?:\/\//iu);
});
