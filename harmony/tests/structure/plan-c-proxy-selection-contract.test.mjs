import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = fileURLToPath(new URL('../../..', import.meta.url));
const HARMONY_ROOT = path.join(REPO_ROOT, 'harmony');
const SHARED_ROOT = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets');
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets');

const PROXY_MODELS_PATH = path.join(SHARED_ROOT, 'proxy', 'ProxyModels.ets');
const PROXY_PORTS_PATH = path.join(SHARED_ROOT, 'proxy', 'ProxyPorts.ets');
const PROXY_SERVICE_PATH = path.join(SHARED_ROOT, 'proxy', 'ProxyService.ets');
const PROXY_BUS_PATH = path.join(SHARED_ROOT, 'proxy', 'VpnProxyCommandBus.ets');
const PROXY_HANDLER_PATH = path.join(SHARED_ROOT, 'proxy', 'VpnProxyRuntimeHandler.ets');
const PROFILE_APPLICATION_PATH = path.join(SHARED_ROOT, 'profile', 'ProfileApplication.ets');
const VPN_MODELS_PATH = path.join(SHARED_ROOT, 'vpn', 'VpnModels.ets');
const VPN_COORDINATOR_PATH = path.join(SHARED_ROOT, 'vpn', 'VpnRuntimeCoordinator.ets');
const RDB_DRIVER_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'rdb', 'HarmonyRdbDriver.ets');
const CORE_COMPOSITION_PATH = path.join(ENTRY_ROOT, 'bootstrap', 'CoreComposition.ets');
const EXTENSION_COMPOSITION_PATH = path.join(ENTRY_ROOT, 'vpn', 'VpnExtensionComposition.ets');
const VPN_EVIDENCE_JOURNAL_PATH = path.join(ENTRY_ROOT, 'vpn', 'VpnEvidenceJournal.ets');
const PHASE4_PROOF_RUNNER_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'run-phase4-device-proof.mjs');
const PHASE4_PROOF_SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase4-device-proof.schema.json');
const REPORT_PATH = path.join(REPO_ROOT, 'docs', 'harmony', 'proxy-selection-replay.md');

const ABSOLUTE_PATH_PATTERN =
  /(?:^|[\s'"`(])(?:\/(?:[^/\s'"`)]+\/)*[^/\s'"`)]*|[A-Za-z]:\\(?:[^\\\s'"`)]+\\)*[^\\\s'"`)]*|\\\\[^\\\s'"`)]+\\[^\\\s'"`)]+(?:\\[^\\\s'"`)]+)*)/u;

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

test('plan c exposes one package-neutral application surface and keeps concrete runtime ownership in composition', async () => {
  const [ports, application, coreComposition, extensionComposition] = await Promise.all([
    readUtf8(PROXY_PORTS_PATH),
    readUtf8(PROFILE_APPLICATION_PATH),
    readUtf8(CORE_COMPOSITION_PATH),
    readUtf8(EXTENSION_COMPOSITION_PATH)
  ]);

  assert.match(
    ports,
    /export interface ProxyApplicationPort\s*\{\s*listGroups\(\): Promise<ProxyGroupListQueryResult>;\s*queryGroup\(groupName: string,\s*groupPath\?: string\[\]\): Promise<ProxyGroupQueryResult>;\s*select\(\s*groupName: string,\s*memberName: string,\s*snapshotGeneration: number,\s*groupPath\?: string\[\]\s*\): Promise<ProxySelectionResult>;\s*reconcileActiveSelections\(\): Promise<ProxyReconcileResult>;/u
  );
  assert.match(ports, /startDelayTest\(groupName: string,\s*snapshotGeneration: number,\s*groupPath\?: string\[\]\): Promise<ProxyDelayResult>;/u);
  assert.match(ports, /readDelayTest\(jobId: string\): Promise<ProxyDelayResult>;/u);
  assert.match(ports, /cancelDelayTest\(jobId: string\): Promise<ProxyDelayResult>;/u);
  assert.match(ports, /cancelAndDrainDelayTest\(\): Promise<ProxyRejectedResult \| undefined>;/u);
  assert.match(ports, /selectNodeAndEnsureVpn\(\s*groupName: string,\s*memberName: string,\s*snapshotGeneration: number,\s*groupPath\?: string\[\]\s*\): Promise<SelectNodeAndEnsureVpnResult>;/u);
  assert.match(application, /async listGroups\(\): Promise<ProxyGroupListQueryResult>/u);
  assert.match(application, /async queryGroup\(groupName: string,\s*groupPath\?: string\[\]\): Promise<ProxyGroupQueryResult>/u);
  assert.match(application, /async select\(\s*groupName: string,\s*memberName: string,\s*snapshotGeneration: number,\s*groupPath\?: string\[\]\s*\): Promise<ProxySelectionResult>/u);
  assert.match(application, /async reconcileActiveSelections\(\): Promise<ProxyReconcileResult>/u);
  assert.match(application, /async startDelayTest\(groupName: string,\s*snapshotGeneration: number,\s*groupPath\?: string\[\]\): Promise<ProxyDelayResult>/u);
  assert.match(application, /async readDelayTest\(jobId: string\): Promise<ProxyDelayResult>/u);
  assert.match(application, /async cancelDelayTest\(jobId: string\): Promise<ProxyDelayResult>/u);
  assert.match(application, /async cancelAndDrainDelayTest\(\): Promise<ProxyRejectedResult \| undefined>/u);
  assert.match(application, /async selectNodeAndEnsureVpn\(\s*groupName: string,\s*memberName: string,\s*snapshotGeneration: number,\s*groupPath\?: string\[\]\s*\): Promise<SelectNodeAndEnsureVpnResult>/u);
  assert.match(coreComposition, /new VpnProxyCommandBus\(\)/u);
  assert.match(coreComposition, /new ProxyService\([\s\S]*graph\.proxySelectionRepository[\s\S]*graph\.proxyIdentityHasher/u);
  assert.match(extensionComposition, /new VpnProxyRuntimeHandler\([\s\S]*graph\.proxySelectionRepository[\s\S]*graph\.proxyIdentityHasher/u);
});

test('plan c delay lifecycle gates profile mutations and flushes invalidated shared sessions in source order', async () => {
  const [application, service, handler] = await Promise.all([
    readUtf8(PROFILE_APPLICATION_PATH),
    readUtf8(PROXY_SERVICE_PATH),
    readUtf8(PROXY_HANDLER_PATH)
  ]);

  assert.match(application, /async refresh\(profileId: string, allowPlainHttp: boolean = false\): Promise<RefreshProfileResult>[\s\S]*await this\.requireDelayDrainAppError\('RUNTIME_START'\)[\s\S]*acquireMutationLease\('REFRESH'\)/u);
  assert.match(application, /async enable\(profileId: string\): Promise<ManageEnableResult>[\s\S]*await this\.requireDelayDrainAppError\('PERSISTENCE'\)[\s\S]*manageProfileUseCases\.enable/u);
  assert.match(application, /async replaceSubscriptionUrl\([\s\S]*profileId: string,[\s\S]*sourceUrl: string,[\s\S]*allowPlainHttp: boolean = false[\s\S]*\): Promise<ManageReplaceResult>[\s\S]*await this\.updateSourceChangingProfile\(profileId, sourceUrl, allowPlainHttp\)/u);
  assert.match(application, /private async updateSourceChangingProfile\([\s\S]*await this\.requireDelayDrainAppError\('PERSISTENCE'\)/u);
  assert.match(application, /async delete\(profileId: string\): Promise<ManageDeleteResult>[\s\S]*await this\.requireDelayDrainAppError\('PERSISTENCE'\)/u);
  assert.doesNotMatch(application, /async startLocal\(\): Promise<LocalRuntimeStartResult>/u,
    'ProfileApplication must not expose a public startLocal surface after the VPN-only migration'
  );
  assert.doesNotMatch(application, /async stopLocal\(\): Promise<LocalRuntimeStopResult>/u,
    'ProfileApplication must not expose a public stopLocal surface after the VPN-only migration'
  );
  assert.match(application, /async startVpnGlobalCapture\(\): Promise<VpnControllerStartResult>[\s\S]*await this\.requireDelayDrainVpnFailure\('VPN_CREATE_FAILED'\)[\s\S]*controller\.start/u);
  assert.match(application, /async stopVpnGlobalCapture\(\): Promise<VpnControllerStopResult>[\s\S]*await this\.requireDelayDrainVpnFailure\('VPN_STOP_FAILED'\)[\s\S]*controller\.stop/u);
  assert.match(application, /async reconcileActiveSelections\(\): Promise<ProxyReconcileResult>[\s\S]*await this\.requireDelayDrainProxyRejected\(\)[\s\S]*safeProxyReconciliation/u);
  assert.match(application, /private async closeInternal\(\): Promise<void> \{[\s\S]*await this\.requireDelayDrainAppError\('PERSISTENCE'\)[\s\S]*this\.dispose\(\)[\s\S]*this\.runtimeCoordinator\.dispose\(\)/u);

  assert.equal((service.match(/private activeDelayRecord\?: ActiveDelayRecord;/gu) ?? []).length, 1, 'ProxyService must keep exactly one active shared delay record slot');
  assert.match(service, /private finalDelayResult\?: ProxyDelaySnapshotResult;/u);
  assert.match(service, /private finalDelayIdentityKey\?: string;/u);
  assert.match(service, /if \(snapshot\.state === 'RUNNING'\) \{[\s\S]*activeRequest\.sessionId[\s\S]*\}\s*if \(snapshot\.state === 'STOPPED' && activeRequest === null\) \{[\s\S]*null/u,
    'final delay reads must stay session-scoped while the runtime is running and downgrade to null-session only after STOPPED');

  assert.match(handler, /private async flushInvalidatedSession\(sessionId: string\): Promise<void> \{[\s\S]*this\.commandBus\.invalidate\(sessionId\)[\s\S]*await this\.cancelAndDrainDelayJob\(sessionId\)[\s\S]*await this\.commandBus\.deactivate\(sessionId\)[\s\S]*await this\.cancelAndDrainDelayJob\(sessionId\)/u);
  assert.match(handler, /await this\.selectionRepository\.listByProfile\(state\.identity\.profileId\)[\s\S]*await this\.replaySelections\(state, records\)[\s\S]*this\.activeState = state[\s\S]*this\.commandBus\.bind\(state\.identity, this\)/u);
});

test('plan c pins exact result and error allowlists', async () => {
  const [proxyModels, vpnModels] = await Promise.all([
    readUtf8(PROXY_MODELS_PATH),
    readUtf8(VPN_MODELS_PATH)
  ]);

  for (const kind of ['APPLIED_NOW', 'SAVED_FOR_NEXT_START', 'APPLIED_NOT_PERSISTED', 'REJECTED']) {
    assert.match(proxyModels, new RegExp(`['"]${kind}['"]`, 'u'));
  }
  for (const code of [
    'PROXY_PROFILE_UNAVAILABLE',
    'PROXY_RUNTIME_NOT_READY',
    'PROXY_SELECTION_STALE',
    'PROXY_QUERY_FAILED',
    'PROXY_SELECTION_FAILED',
    'PROXY_PERSISTENCE_FAILED',
    'VPN_SESSION_CHANGED'
  ]) {
    assert.match(proxyModels, new RegExp(`['"]${code}['"]`, 'u'));
  }
  assert.match(vpnModels, /\| 'VPN_PROXY_REPLAY_FAILED'/u);
  assert.match(vpnModels, /VPN_FAILURE_CODES[\s\S]*'VPN_PROXY_REPLAY_FAILED'/u);
});

test('plan c command bus binds exact identity and rejects stale epochs before and after handler work', async () => {
  const source = await readUtf8(PROXY_BUS_PATH);

  assert.match(source, /const boundIdentity: ProxyRuntimeIdentity = requireBoundIdentity\(identity\)/u);
  assert.match(source, /const epoch: number = this\.advanceBindingEpoch\(\)/u);
  assert.match(source, /active\.epoch !== captured\.epoch/u);
  assert.match(source, /active\.handler !== captured\.handler/u);
  assert.match(source, /sameIdentity\(active\.identity, captured\.identity\)/u);
  assert.match(source, /this\.activeBinding = undefined;\s*this\.advanceClosedEpoch\(\);/u);
  assert.match(source, /async deactivate\(sessionId: string\): Promise<void>\s*\{\s*this\.invalidate\(sessionId\);\s*await this\.queue\.execute/u);
  assert.ok((source.match(/!this\.matchesCapturedBinding\(captured, validatedCommand\.identity\)/gu) ?? []).length >= 6);
});

test('plan c runtime replay precedes binding and persistence failure stays truthful', async () => {
  const source = await readUtf8(PROXY_HANDLER_PATH);

  assertOrdered(source, [
    ['durable selection read', 'selectionRepository.listByProfile'],
    ['selection replay', 'replaySelections(state, records)'],
    ['active-state publication', 'this.activeState = state'],
    ['session bus bind', 'this.commandBus.bind(state.identity, this)']
  ]);
  assert.match(source, /await this\.selectionRepository\.upsert\(confirmedRecord\)[\s\S]*createProxySelectionAppliedNowResult/u);
  assert.match(source, /handlePersistenceFailure\([\s\S]*createProxySelectionAppliedNotPersistedResult/u);
  assert.match(source, /isConfirmedSelection\(rollbackApplied\.group, command\.groupName, previousName\)[\s\S]*createProxyRejectedResult\(persistenceError\)/u);
  assert.match(source, /isConfirmedSelection\(rollbackState\.group, command\.groupName, previousName\)[\s\S]*createProxyRejectedResult\(persistenceError\)/u);
});

test('plan c initial and recovery flows activate replay before publishing running', async () => {
  const source = await readUtf8(VPN_COORDINATOR_PATH);
  const initialStart = source.slice(source.indexOf('private async startInternal'), source.indexOf('private async stopInternal'));
  const recoveryStart = source.slice(source.indexOf('private async runRecoveryAttempt'), source.indexOf('private handleRecoveryFailure'));

  assertOrdered(initialStart, [
    ['TUN readiness', 'await this.awaitTunReady'],
    ['proxy replay activation', 'await this.activateProxyLifecycle'],
    ['notification start', 'await this.dependencies.notification.start'],
    ['RUNNING publication', "buildActiveSnapshot('RUNNING'" ]
  ]);
  assertOrdered(recoveryStart, [
    ['TUN recovery', 'await this.dependencies.tunRuntime.recover'],
    ['proxy recovery replay', 'await this.activateProxyLifecycle'],
    ['recovered RUNNING publication', "buildActiveSnapshot('RUNNING'" ]
  ]);
  assert.match(source, /this\.dependencies\.proxyLifecycle\.invalidate\(visibleSessionId\)/u);
  assert.match(source, /cleanupActiveSession[\s\S]*await this\.dependencies\.proxyLifecycle\.deactivate\(active\.request\.sessionId\)[\s\S]*tunRuntime\.stop/u);
});

test('plan c rdb v2 keeps raw names only in the dedicated selection table and deletes them with profiles', async () => {
  const source = await readUtf8(RDB_DRIVER_PATH);

  assert.match(
    source,
    /const PROXY_SELECTIONS_TABLE_SQL =\s*'CREATE TABLE IF NOT EXISTS ' \+ PROXY_SELECTIONS_TABLE \+ ' \(' \+\s*'profile_id TEXT NOT NULL,' \+\s*'group_name TEXT NOT NULL,' \+\s*'selected_node_name TEXT NOT NULL,' \+\s*'revision_id TEXT NOT NULL,' \+\s*'updated_at TEXT NOT NULL,' \+\s*'PRIMARY KEY \(profile_id, group_name\)' \+\s*'\)'/u
  );
  assert.match(source, /SELECT \$\{PROXY_SELECTION_COLUMNS\} FROM \$\{PROXY_SELECTIONS_TABLE\} WHERE profile_id = \? ORDER BY group_name ASC/u);
  assert.match(source, /async deleteProfile\(id: string\): Promise<void>[\s\S]*await this\.deleteProfileSelections\(id\)[\s\S]*DELETE FROM profiles WHERE id = \?/u);
});

test('plan c proxy sources never log or interpolate private group and node values into errors', async () => {
  const files = [PROXY_SERVICE_PATH, PROXY_BUS_PATH, PROXY_HANDLER_PATH, PROFILE_APPLICATION_PATH];
  const sources = await Promise.all(files.map(readUtf8));
  const joined = sources.join('\n');

  assertNoPattern('proxy code must not emit console logs', joined, /console\.(?:debug|info|warn|error|log)\s*\(/u);
  assertNoPattern('proxy code must not emit public hilog values', joined, /hilog\.[a-z]+\s*\(/u);
  assertNoPattern('proxy code must not serialize errors', joined, /JSON\.stringify\s*\(\s*(?:error|result|snapshot)/u);
  assertNoPattern(
    'proxy code must not interpolate private names into errors',
    joined,
    /new Error\s*\(\s*`[^`]*\$\{(?:groupName|memberName|selectedNodeName|record\.(?:groupName|selectedNodeName))/u
  );
});

test('plan c tracked proof and journal surfaces cannot persist private proxy labels', async () => {
  const [journal, proofRunner, proofSchema] = await Promise.all([
    readUtf8(VPN_EVIDENCE_JOURNAL_PATH),
    readUtf8(PHASE4_PROOF_RUNNER_PATH),
    readUtf8(PHASE4_PROOF_SCHEMA_PATH)
  ]);
  const proofSurfaces = `${journal}\n${proofRunner}\n${proofSchema}`;

  assertNoPattern(
    'proof surfaces must not add raw proxy label fields',
    proofSurfaces,
    /(?:groupName|memberName|selectedNodeName|proxyGroupName|proxyNodeName)\s*[:=]/u
  );
  assertNoPattern(
    'proof surfaces must not serialize proxy commands or snapshots',
    proofSurfaces,
    /JSON\.stringify\s*\([^)]*(?:ProxyGroup|ProxySelection|VpnProxy)/u
  );
  assert.match(journal, /detail: sanitizeDetail\(stage\)/u);
});

test('plan c report is package-neutral and contains only bounded counts hashes and contract facts', async () => {
  const report = await readUtf8(REPORT_PATH);

  for (const required of [
    '# HarmonyOS Proxy Selection Replay',
    'RDB schema version: `2`',
    'Replay ordering: `TUN_READY -> REPLAY -> BIND -> RUNNING`',
    'Focused structure cases: `46`',
    'Physical-device result: `NOT_CLAIMED`',
    'Signed package result: `NOT_CLAIMED`',
    'Raw proxy names recorded: `0`',
    'Endpoint fields recorded: `0`'
  ]) {
    assert.equal(report.includes(required), true, `missing report contract: ${required}`);
  }

  for (const [label, pattern] of [
    ['report URL', /(?:https?|content):\/\//iu],
    ['report file URL', /file:\/\//iu],
    ['report absolute path', ABSOLUTE_PATH_PATTERN],
    ['report signed package path', /(?:\.hap\b|entry-default-signed)/iu],
    ['report signing material', /(?:\.p12\b|\.p7b\b|\.cer\b|\.pem\b|\.jks\b|\.keystore\b|storePassword|keyAlias|signingConfigs)/iu],
    ['report device identifier', /(?:deviceId|udid|serial(?:Number)?|\b[0-9a-f]{8}-[0-9a-f-]{27,}\b)/iu],
    ['report subscription data', /(?:subscription\s*(?:url|uri)|token=|proxy-groups:|proxies:|mixed-port:)/iu],
    ['report endpoint', /\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b/u]
  ]) {
    assertNoPattern(label, report, pattern);
  }
});
