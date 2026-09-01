import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseJson5Like } from '../bin/inspect-phase4-packages.mjs';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry');
const ETS_ROOT = path.join(ENTRY_ROOT, 'src', 'main', 'ets');
const MODULE_JSON_PATH = path.join(ENTRY_ROOT, 'src', 'main', 'module.json5');
const STRINGS_PATH = path.join(ENTRY_ROOT, 'src', 'main', 'resources', 'base', 'element', 'string.json');
const HOME_PAGE_PATH = path.join(ETS_ROOT, 'pages', 'HomePage.ets');
const HOME_VIEW_MODEL_PATH = path.join(ETS_ROOT, 'presentation', 'HomeViewModel.ets');
const CARD_PATH = path.join(ETS_ROOT, 'components', 'RuntimeStatusCard.ets');
const SAFE_ERROR_CARD_PATH = path.join(ETS_ROOT, 'components', 'SafeErrorCard.ets');
const ENTRY_ABILITY_PATH = path.join(ETS_ROOT, 'entryability', 'EntryAbility.ets');
const VPN_EXTENSION_COMPOSITION_PATH = path.join(ETS_ROOT, 'vpn', 'VpnExtensionComposition.ets');
const VPN_EVIDENCE_JOURNAL_PATH = path.join(ETS_ROOT, 'vpn', 'VpnEvidenceJournal.ets');
const VPN_EXTENSION_ABILITY_PATH = path.join(ETS_ROOT, 'vpn', 'CmfaVpnExtensionAbility.ets');
const VPN_CONTROLLER_PATH = path.join(ETS_ROOT, 'vpn', 'HarmonyVpnController.ets');
const UI_OWNED_VPN_API_PATH = path.join(ETS_ROOT, 'vpn', 'UiOwnedVpnExtensionAbilityApi.ets');
const CORE_COMPOSITION_PATH = path.join(ETS_ROOT, 'bootstrap', 'CoreComposition.ets');
const VPN_DRIVER_PATH = path.join(ETS_ROOT, 'vpn', 'HarmonyVpnConnectionDriver.ets');
const VPN_NOTIFICATION_DRIVER_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'background', 'HarmonyVpnNotificationDriver.ets');
const PLATFORM_FACTORY_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'PlatformFactory.ets');
const HVIGOR_WRAPPER_PATH = path.join(HARMONY_ROOT, 'hvigorw');
const PROFILE_APPLICATION_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'profile', 'ProfileApplication.ets');
const SHARED_VPN_PORTS_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'vpn', 'VpnPorts.ets');
const SHARED_VPN_COORDINATOR_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'vpn', 'VpnRuntimeCoordinator.ets');
const CORE_TUN_RUNTIME_PATH = path.join(HARMONY_ROOT, 'core', 'src', 'main', 'ets', 'CoreTunRuntime.ets');

const EXACT_STRING_VALUES = new Map([
  ['home_vpn_title', 'VPN global capture'],
  ['home_vpn_primary_start', 'Start VPN global capture'],
  ['home_vpn_primary_stop', 'Stop VPN global capture'],
  ['home_vpn_boundary_note', 'TUN capture is limited to traffic handled by this app session.'],
  ['home_vpn_notification_label', 'Continuous notification'],
  ['error_vpn_permission_denied', 'VPN permission was denied.'],
  ['error_vpn_profile_unavailable', 'The selected profile has no committed version for VPN global capture.'],
  ['error_vpn_start_failed', 'VPN global capture could not start with the selected profile.']
]);

const FORBIDDEN_PERMISSION_PATTERNS = [
  'MANAGE_VPN',
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
  return parseJson5Like(await fs.readFile(filePath, 'utf8'), filePath);
}

function getStringValue(document, key) {
  const entry = (document.string ?? []).find((candidate) => candidate.name === key);
  return entry?.value;
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

function extractMethodBody(source, signature) {
  const startIndex = source.indexOf(signature);
  assert.notEqual(startIndex, -1, `missing method signature: ${signature}`);
  const braceStart = source.indexOf('{', startIndex);
  assert.notEqual(braceStart, -1, `missing method body start: ${signature}`);
  let depth = 0;
  for (let index = braceStart; index < source.length; index += 1) {
    const char = source[index];
    if (char === '{') {
      depth += 1;
    } else if (char === '}') {
      depth -= 1;
      if (depth === 0) {
        return source.slice(braceStart, index + 1);
      }
    }
  }
  assert.fail(`unterminated method body: ${signature}`);
}

test('phase4 vpn contract keeps the production manifest to the minimal VPN surface', async () => {
  const moduleDocument = await readJson(MODULE_JSON_PATH);
  const permissions = moduleDocument.module.requestPermissions ?? [];
  const permissionNames = permissions.map((permission) => permission.name);

  assert.deepEqual(permissionNames, [
    'ohos.permission.INTERNET',
    'ohos.permission.GET_NETWORK_INFO',
    'ohos.permission.KEEP_BACKGROUND_RUNNING'
  ], 'module.json5 must declare exactly INTERNET, GET_NETWORK_INFO, and KEEP_BACKGROUND_RUNNING');

  const extensions = moduleDocument.module.extensionAbilities ?? [];
  assert.equal(extensions.length, 1, 'module.json5 must declare exactly one extension ability');
  assert.deepEqual(extensions[0], {
    name: 'CmfaVpnExtensionAbility',
    srcEntry: './ets/vpn/CmfaVpnExtensionAbility.ets',
    type: 'vpn',
    exported: false
  }, 'VPN extension ability contract drifted');

  const entryAbility = (moduleDocument.module.abilities ?? []).find((ability) => ability.name === 'EntryAbility');
  assert.deepEqual(entryAbility?.backgroundModes, ['dataTransfer'],
    'the UIAbility that owns the continuous notification must declare dataTransfer');
  assert.equal('process' in (entryAbility ?? {}), false,
    'EntryAbility must not declare an explicit process override');
  assert.notEqual(entryAbility?.isolationProcess, true,
    'EntryAbility must not opt into isolationProcess');
  assert.notEqual(extensions[0]?.isolationProcess, true,
    'CmfaVpnExtensionAbility must not opt into isolationProcess');
  assert.equal('process' in extensions[0], false,
    'CmfaVpnExtensionAbility must not declare an explicit process field');
  assert.equal('extensionProcessMode' in extensions[0], false,
    'CmfaVpnExtensionAbility must not declare extensionProcessMode for same-process routing');

  const serialized = JSON.stringify(moduleDocument);
  for (const forbidden of FORBIDDEN_PERMISSION_PATTERNS) {
    assert.doesNotMatch(serialized, new RegExp(forbidden, 'iu'), `module.json5 must not mention forbidden capability ${forbidden}`);
  }
});

test('phase4 vpn source validator accepts project json5 features and fail-closes on malformed source', async () => {
  const fixtureDocument = parseJson5Like(`
    {
      "module": {
        "requestPermissions": [
          { "name": "ohos.permission.INTERNET" },
          { "name": "ohos.permission.KEEP_BACKGROUND_RUNNING" },
        ],
        "abilities": [
          {
            "name": "EntryAbility",
            "backgroundModes": [
              "dataTransfer",
            ],
          },
        ],
        "extensionAbilities": [
          {
            "name": "CmfaVpnExtensionAbility",
            "type": "vpn",
            "exported": false,
          },
        ],
      },
    }
  `, 'phase4 vpn json5 fixture');

  const entryAbility = fixtureDocument.module.abilities[0];
  const extensionAbility = fixtureDocument.module.extensionAbilities[0];
  assert.equal('process' in entryAbility, false);
  assert.deepEqual(entryAbility.backgroundModes, ['dataTransfer']);
  assert.equal('extensionProcessMode' in extensionAbility, false);
  assert.equal('process' in extensionAbility, false);

  assert.throws(
    () => parseJson5Like('{ "module": { "requestPermissions": [ }', 'phase4 malformed json5 fixture'),
    /Failed to parse phase4 malformed json5 fixture/u
  );
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

test('phase4 vpn start parser accepts HarmonyOS transport metadata while requiring all session fields', async () => {
  const compositionSource = await readUtf8(VPN_EXTENSION_COMPOSITION_PATH);

  assert.match(compositionSource, /keys\.includes\('profileId'\)[\s\S]*keys\.includes\('versionId'\)[\s\S]*keys\.includes\('sessionId'\)/u,
    'VPN start parsing must require profileId, versionId, and sessionId'
  );
  assert.doesNotMatch(compositionSource, /keys\.length\s*!==\s*3/u,
    'HarmonyOS may add transport metadata to Want.parameters; required session fields must not require an exact key count'
  );
});

test('phase4 private-origin rollback removes the falsified route experiment while preserving replay and privacy hardening', async () => {
  const [runnerSource, coreCompositionSource, vpnCompositionSource, driverSource, journalSource] = await Promise.all([
    readUtf8(path.join(HARMONY_ROOT, 'tests', 'bin', 'run-phase4-device-proof.mjs')),
    readUtf8(CORE_COMPOSITION_PATH),
    readUtf8(VPN_EXTENSION_COMPOSITION_PATH),
    readUtf8(VPN_DRIVER_PATH),
    readUtf8(VPN_EVIDENCE_JOURNAL_PATH)
  ]);

  const productAndRunnerChain = [runnerSource, coreCompositionSource, vpnCompositionSource, driverSource].join('\n');
  for (const pattern of [
    /phase4OriginIpv4/u,
    /cmfa\.phase4\.originIpv4/u,
    /parsePhase4OriginIpv4/u,
    /createPhase4OriginRoute/u,
    /platform\.route\.phase4-applied/u,
    /platform\.apps\.phase4-probe-only/u
  ]) {
    assert.doesNotMatch(productAndRunnerChain, pattern);
  }

  assert.match(vpnCompositionSource, /export function cloneValidatedVpnReplayWant\(want: Want\): Want \| undefined/u,
    'generic replay/drain infrastructure must survive the rollback'
  );
  assert.match(journalSource, /recordDiagnosticStage\(stage: string\): void/u,
    'diagnostic stage privacy hardening must remain after removing the route experiment'
  );
  assert.match(driverSource, /trustedApplications:\s*\[\]/u,
    'default platform policy must keep an empty trustedApplications allowlist'
  );
  assert.match(driverSource, /blockedApplications:\s*\[SELF_PACKAGE_NAME\]/u,
    'default platform policy must keep only the self blocklist'
  );
});

test('phase4 runtime evidence carries only a validated runner UUID from UIAbility to the VPN journal', async () => {
  const [coreCompositionSource, vpnCompositionSource, journalSource] = await Promise.all([
    readUtf8(CORE_COMPOSITION_PATH),
    readUtf8(VPN_EXTENSION_COMPOSITION_PATH),
    readUtf8(VPN_EVIDENCE_JOURNAL_PATH)
  ]);

  assert.match(
    coreCompositionSource,
    /buildForwardedVpnExtensionWant\(want,\s*getPhase1LaunchContext\(\)\)/u,
    'System VPN API must forward through the shared Want helper with the current launch context'
  );
  assert.match(
    coreCompositionSource,
    /if\s*\(launchContext\.runId\.length\s*>\s*0\)\s*\{[\s\S]*forwardedParameters\[RUN_ID_KEY\]\s*=\s*launchContext\.runId/u,
    'helper must continue forwarding the evidence run id only when present'
  );
  assert.match(vpnCompositionSource, /function parseEvidenceRunId\(want: Want\): string/u);
  assert.match(vpnCompositionSource, /UUID_PATTERN\.test\(rawRunId\)/u);
  assert.match(vpnCompositionSource, /rotateSession\(request\.sessionId, evidenceRunId\)/u);
  assert.match(journalSource, /runId: string;/u);
  assert.match(journalSource, /rotateSession\(sessionId: string, runId: string\): void/u);
  assert.match(journalSource, /this\.document\.runId = runId;/u);
});

test('phase4 VPN start Want keeps explicit local-device routing through the UIAbility boundary', async () => {
  const [coreCompositionSource, controllerSource] = await Promise.all([
    readUtf8(CORE_COMPOSITION_PATH),
    readUtf8(path.join(ETS_ROOT, 'vpn', 'HarmonyVpnController.ets'))
  ]);

  assert.match(controllerSource, /deviceId:\s*''[\s\S]*bundleName:\s*BUNDLE_NAME[\s\S]*abilityName:\s*ABILITY_NAME/u);
  assert.match(
    coreCompositionSource,
    /deviceId:\s*sourceWant\.deviceId\s*\?\?\s*''[\s\S]*bundleName:\s*sourceWant\.bundleName[\s\S]*abilityName:\s*sourceWant\.abilityName/u,
    'helper must preserve bundle/ability and restore the legacy empty-string device fallback'
  );
  assert.match(coreCompositionSource, /forwardedParameters\[key\]\s*=\s*sourceParameters\[key\]/u);
});

test('phase4 vpn composition persists stage-only coordinator diagnostics alongside CMFAVpn hilog', async () => {
  const [compositionSource, driverSource] = await Promise.all([
    readUtf8(VPN_EXTENSION_COMPOSITION_PATH),
    readUtf8(VPN_DRIVER_PATH)
  ]);

  assert.match(compositionSource, /import \{ hilog \} from '@kit\.PerformanceAnalysisKit';/u);
  assert.match(compositionSource, /const VPN_STAGE_LOG_TAG: string = 'CMFAVpn';/u);
  assert.match(compositionSource, /function reportVpnStartStage\(stage: string\): void \{\s*hilog\.info\(VPN_STAGE_LOG_DOMAIN,\s*VPN_STAGE_LOG_TAG,\s*'%\{public\}s',\s*stage\);\s*\}/u);
  assert.match(
    compositionSource,
    /reportStageLifecycle:\s*\(stage: string\) => \{\s*this\.recordVpnStartStage\(stage\);\s*\}/u,
    'fixed coordinator stages must survive when Extension-process hilog is unavailable'
  );
  assert.match(
    compositionSource,
    /private recordVpnStartStage\(stage: string\): void \{\s*reportVpnStartStage\(stage\);\s*this\.evidenceJournal\?\.recordLifecycleFact\('starting', stage\.split\('\.'\)\.join\('-'\)\);\s*\}/u
  );
  assert.match(
    compositionSource,
    /new HarmonyVpnConnectionDriver\([\s\S]*createHarmonyVpnOwnershipStore\(this\.context\.filesDir\),[\s\S]*\(stage: string\) => \{\s*this\.recordVpnStartStage\(stage\);\s*\}/u,
    'platform connection sub-stages must flow into the same private evidence journal'
  );
  assert.doesNotMatch(compositionSource, /reportStageLifecycle:[\s\S]{0,200}(request|want|error|message|profile|session|config)/u);
});

test('phase4 packet diagnostics reach private evidence as a fixed allow-list without payload fields', async () => {
  const [portsSource, coreRuntimeSource, compositionSource, journalSource] = await Promise.all([
    readUtf8(SHARED_VPN_PORTS_PATH),
    readUtf8(CORE_TUN_RUNTIME_PATH),
    readUtf8(VPN_EXTENSION_COMPOSITION_PATH),
    readUtf8(VPN_EVIDENCE_JOURNAL_PATH)
  ]);

  assert.match(portsSource, /diagnosticStage\?: string;/u);
  for (const stage of [
    'tun.packet.read-loop-enter',
    'tun.packet.read-would-block',
    'tun.packet.read-failed',
    'tun.packet.raw-read',
    'tun.packet.gvisor-inject'
  ]) {
    assert.match(coreRuntimeSource, new RegExp(`['"]${stage.replaceAll('.', '\\\.')}['"]`, 'u'));
  }
  assert.match(coreRuntimeSource, /event\.ingress\s*!==\s*'diagnostic'/u);
  assert.match(coreRuntimeSource, /event\.message\s*!==\s*event\.protocol/u);
  assert.match(
    coreRuntimeSource,
    /if \(diagnosticStage !== undefined\) \{\s*this\.emitSnapshotEvent\(diagnosticStage, sessionId\);\s*return;\s*\}/u,
    'fixed diagnostics must not depend on a re-entrant tunSnapshot call during startTun'
  );
  assert.match(coreRuntimeSource, /diagnosticStage:\s*diagnosticStage/u);
  assert.match(compositionSource, /event\.diagnosticStage\s*!==\s*undefined[\s\S]*this\.recordVpnPacketDiagnosticStage\(event\.diagnosticStage\)/u);
  assert.match(compositionSource, /recordVpnPacketDiagnosticStage\(stage: string\)[\s\S]*recordDiagnosticStage\(stage\.split\('\.'\)\.join\('-'\)\)/u);
  assert.match(journalSource, /recordDiagnosticStage\(stage: string\): void \{[\s\S]*detail: sanitizeDetail\(stage\)/u);
  assert.doesNotMatch(journalSource, /recordDiagnosticStage\(stage: string\): void \{[\s\S]{0,700}(?:sessionId|traceId|message|code):\s*stage/u);
  assert.doesNotMatch(coreRuntimeSource, /diagnosticStage:\s*event\.(?:message|code|traceId|sessionId)/u);
});

test('phase4 UIAbility reports only fixed system VPN start boundary stages', async () => {
  const coreCompositionSource = await readUtf8(CORE_COMPOSITION_PATH);

  assert.match(coreCompositionSource, /const VPN_UI_LOG_TAG: string = 'CMFAVpn';/u);
  assert.match(coreCompositionSource, /function reportVpnUiStage\(stage: string\): void \{\s*hilog\.warn\(VPN_UI_LOG_DOMAIN,\s*VPN_UI_LOG_TAG,\s*'%\{public\}s',\s*stage\);\s*\}/u);
  for (const stage of [
    'ui.extension.start.invoke',
    'ui.extension.start.returned',
    'ui.extension.start.resolved',
    'ui.extension.start.rejected'
  ]) {
    assert.match(coreCompositionSource, new RegExp(`['"]${stage.replaceAll('.', '\\\.')}['"]`, 'u'));
  }
  assert.doesNotMatch(coreCompositionSource, /reportVpnUiStage\((?:error|want|request|profile|session|message|parameters)/u);
});

test('phase4 UIAbility reconstructs a fixed stop Want and reports each system stop boundary', async () => {
  const coreCompositionSource = await readUtf8(CORE_COMPOSITION_PATH);

  assert.doesNotMatch(coreCompositionSource, /private lastWant\?: Want/u,
    'stopping a stale system VPN must not depend on process-local start state');
  assert.match(
    coreCompositionSource,
    /const stopWant: Want = \{\s*deviceId: '',\s*bundleName: BUNDLE_NAME,\s*abilityName: ABILITY_NAME\s*\};/u,
    'the stop Want must be reconstructible from the declared VPN extension identity'
  );
  for (const stage of [
    'ui.extension.stop.invoke',
    'ui.extension.stop.returned',
    'ui.extension.stop.resolved',
    'ui.extension.stop.rejected'
  ]) {
    assert.match(coreCompositionSource, new RegExp(`['"]${stage.replaceAll('.', '\\\.')}['"]`, 'u'));
  }
  assert.doesNotMatch(coreCompositionSource, /reportVpnUiStage\((?:error|want|request|profile|session|message|parameters)/u);
});


test('phase4 controller completes a user stop from its pending completion even without any UI-extension static owner handoff', async () => {
  const controllerSource = await readUtf8(VPN_CONTROLLER_PATH);
  const handleDestroyedBody = extractMethodBody(controllerSource, 'handleExtensionDestroyed(): void');

  assert.match(handleDestroyedBody, /const currentSessionId: string \| undefined =\s*this\.pendingStopCompletion\?\.sessionId \?\? this\.registry\.currentSessionId\(\);/u,
    'the controller must derive stop completion from pendingStopCompletion or the registry instead of any bridge poller'
  );
  assert.match(handleDestroyedBody, /const pendingStop: PendingStopCompletion \| undefined = this\.pendingStopCompletion;/u);
  assert.match(handleDestroyedBody, /if \(pendingStop !== undefined && pendingStop\.sessionId === currentSessionId\) \{[\s\S]*this\.registry\.completeStop\(currentSessionId,\s*currentFailure\)[\s\S]*this\.pendingStopCompletion = undefined;[\s\S]*this\.stopRequestInFlight = undefined;[\s\S]*this\.knownRequest = undefined;[\s\S]*void this\.deactivateRuntimeMirror\(currentSessionId\);[\s\S]*pendingStop\.resolve\(createStoppedResult\(this\.registry\.snapshot\(\)\)\);[\s\S]*return;[\s\S]*\}/u,
    'the controller must settle the pending stop from controller/registry state and deactivate the runtime mirror'
  );
  assert.doesNotMatch(controllerSource, /invalidateBridgePolling|NativeVpnRuntimeBridge|InstalledVpnExtensionOwner|installedVpnExtensionOwner/u,
    'controller stop completion must not depend on obsolete bridge polling or static owner handoff symbols'
  );
});

test('phase4 HomeViewModel reports fixed VPN command routing stages without payloads', async () => {
  const homeViewModelSource = await readUtf8(HOME_VIEW_MODEL_PATH);

  assert.match(homeViewModelSource, /const VPN_COMMAND_LOG_TAG: string = 'CMFAVpn';/u);
  assert.match(homeViewModelSource, /function reportVpnCommandStage\(stage: string\): void \{\s*hilog\.warn\(VPN_COMMAND_LOG_DOMAIN,\s*VPN_COMMAND_LOG_TAG,\s*'%\{public\}s',\s*stage\);\s*\}/u);
  for (const stage of [
    'ui.command.enter',
    'ui.command.pending',
    'ui.command.action-unavailable',
    'ui.command.start.invoke',
    'ui.command.start.returned',
    'ui.command.start.started',
    'ui.command.start.profile-unavailable',
    'ui.command.start.controller-failed',
    'ui.command.start.other-failed'
  ]) {
    assert.match(homeViewModelSource, new RegExp(`['"]${stage.replaceAll('.', '\\\.')}['"]`, 'u'));
  }
  assert.doesNotMatch(homeViewModelSource, /ui\.command\.start\.local-stop-required/u,
    'VPN-only HomeViewModel must not publish a removed Local-stop routing stage'
  );
  assert.doesNotMatch(homeViewModelSource, /reportVpnCommandStage\((?:error|result|failure|snapshot|profile|session|message)/u);
});

test('phase4 vpn ability emits stage-only lifecycle diagnostics without serializing the system Want', async () => {
  const abilitySource = await readUtf8(VPN_EXTENSION_ABILITY_PATH);

  assert.match(abilitySource, /import \{ hilog \} from '@kit\.PerformanceAnalysisKit';/u);
  for (const stage of [
    'ability.onCreate',
    'ability.onRequest',
    'ability.want.invalid',
    'ability.want.valid',
    'ability.composition.start',
    'ability.composition.ok',
    'ability.composition.failed',
    'ability.onDestroy'
  ]) {
    assert.match(abilitySource, new RegExp(`['"]${stage.replaceAll('.', '\\\.')}['"]`, 'u'));
  }
  assert.doesNotMatch(abilitySource, /JSON\.stringify\s*\(\s*want\s*\)/u);
  assert.doesNotMatch(abilitySource, /hilog\.[a-z]+\([^\n]*want(?:\.|\b)/u);
});

test('phase4 notification diagnostics isolate each continuous-task boundary without logging error payloads', async () => {
  const notificationSource = await readUtf8(VPN_NOTIFICATION_DRIVER_PATH);

  assert.match(notificationSource, /const VPN_NOTIFICATION_LOG_TAG: string = 'CMFAVpn';/u);
  for (const stage of [
    'notification.want-agent.begin',
    'notification.want-agent.ok',
    'notification.want-agent.failed',
    'notification.cancel-subscribe.begin',
    'notification.cancel-subscribe.ok',
    'notification.cancel-subscribe.failed',
    'notification.background.begin',
    'notification.background.ok',
    'notification.background.failed',
    'notification.traffic.id-ready',
    'notification.traffic.id-missing',
    'notification.traffic.metadata-live-view',
    'notification.traffic.metadata-non-live-view',
    'notification.traffic.publish.begin',
    'notification.traffic.publish.ok',
    'notification.traffic.publish.failed'
  ]) {
    assert.match(notificationSource, new RegExp(`['"]${stage.replaceAll('.', '\\\.')}['"]`, 'u'));
  }
  assert.doesNotMatch(notificationSource, /reportNotificationStage\((?:error|want|context|session|request|info|notification)/u);
  assert.doesNotMatch(notificationSource, /JSON\.stringify|\.message\b|\.stack\b/u);
});

test('phase4 continuous-task system calls receive the original Ability context instead of an identity-only object', async () => {
  const [notificationSource, platformFactorySource] = await Promise.all([
    readUtf8(VPN_NOTIFICATION_DRIVER_PATH),
    readUtf8(PLATFORM_FACTORY_PATH)
  ]);

  assert.match(notificationSource, /constructor\(context: common\.Context\) \{\s*this\.context = context;\s*\}/u,
    'the system driver must retain an actual HarmonyOS Context');
  assert.match(platformFactorySource, /new HarmonyVpnNotificationDriver\(\s*toPlatformContinuousTaskContext\(this\.context\),\s*undefined,\s*this\.context\s*\)/u,
    'PlatformFactory must pass the original Ability context to the system driver');
  assert.doesNotMatch(notificationSource, /new AbilityKitContinuousTaskDriver\(context as common\.UIAbilityContext\)/u,
    'an identity-only adapter must never be cast into UIAbilityContext');
});

test('phase4 keeps continuous-task ownership in UIAbility and delegates only the logical lease to VpnExtensionAbility', async () => {
  const [apiSource, compositionSource, platformFactorySource] = await Promise.all([
    readUtf8(UI_OWNED_VPN_API_PATH),
    readUtf8(CORE_COMPOSITION_PATH),
    readUtf8(PLATFORM_FACTORY_PATH)
  ]);

  assert.match(apiSource, /class UiOwnedVpnExtensionAbilityApi implements VpnExtensionAbilityApi/u);
  assert.match(apiSource, /await this\.delegate\.stopVpnExtensionAbility\(\)[\s\S]*await this\.delegate\.startVpnExtensionAbility\(want\)[\s\S]*await this\.notification\.start\(sessionId\)/u,
    'an explicit new start must clear a stale system extension before requesting a fresh VPN session');
  assert.match(apiSource, /await this\.delegate\.stopVpnExtensionAbility\(\)[\s\S]*await this\.notification\.stop\(sessionId\)/u,
    'VPN extension must stop before releasing the UI continuous notification');
  assert.match(compositionSource, /new UiOwnedVpnExtensionAbilityApi\([\s\S]*createContinuousNotificationPort\(\)/u,
    'CoreComposition must bind the UIAbility-owned notification to the platform VPN API');
  assert.match(platformFactorySource, /if \(!hasUiAbilityInfo\(this\.context\)\) \{\s*return new UiAbilityOwnedContinuousNotificationPort\(\);\s*\}/u,
    'VpnExtensionAbility must use only the logical notification lease');
});

test('phase4 live-view traffic updates stay presentation-only and gate only on owned session plus notification id', async () => {
  const notificationSource = await readUtf8(VPN_NOTIFICATION_DRIVER_PATH);
  const updateTrafficBody = extractMethodBody(notificationSource, 'async updateTraffic(');

  assert.match(notificationSource, /async updateTraffic\(\s*sessionId:\s*string,\s*uploadBytesPerSecond:\s*number,\s*downloadBytesPerSecond:\s*number\s*\):\s*Promise<void>/u,
    'notification driver must expose a best-effort traffic update entrypoint');
  assert.match(updateTrafficBody, /if \(\s*this\.activeSessionId !== sessionId\s*\|\|\s*this\.activeNotificationId === undefined\s*\)\s*\{\s*return;\s*\}/u,
    'traffic updates must no-op only for wrong session or missing notification id before publish'
  );
  assert.match(updateTrafficBody, /await this\.driver\.updateNotification\(\s*this\.activeNotificationId,\s*(?:'Clash Meta VPN'|NOTIFICATION_TITLE),\s*speedText\s*\)/u,
    'traffic updates must reuse the original system-owned notification id with fixed safe copy'
  );
  assert.doesNotMatch(updateTrafficBody, /activeNotificationIsLiveView\(\)/u,
    'traffic updates must not gate publish on start-returned live-view metadata'
  );
  assert.doesNotMatch(notificationSource, /profileId|versionId|subscription\s*(?:url|uri)|token=|https?:\/\//iu,
    'traffic notification copy must not leak profile, subscription, token, or URL data'
  );
});

test('phase4 live-view notification failures do not mutate vpn ownership or lifecycle state', async () => {
  const notificationSource = await readUtf8(VPN_NOTIFICATION_DRIVER_PATH);
  const updateTrafficBody = extractMethodBody(notificationSource, 'async updateTraffic(');
  const stopBody = extractMethodBody(notificationSource, 'async stop(sessionId: string)');

  assert.doesNotMatch(updateTrafficBody, /activeSessionId\s*=\s*undefined|activeContinuousTaskId\s*=\s*undefined|activeNotificationId\s*=\s*undefined/u,
    'publish failures must not clear notification ownership from updateTraffic'
  );
  assert.doesNotMatch(updateTrafficBody, /detachCancellationListener|handleCancellation|stopBackgroundTask/u,
    'publish failures must not detach cancellation listeners or stop the background task'
  );
  assert.match(stopBody, /this\.activeNotificationId = undefined;/u,
    'successful stop must clear the owned notification id'
  );
});

test('phase4 proxy replay gates initial and recovered RUNNING publication and drains before TUN stop', async () => {
  const coordinatorSource = await readUtf8(SHARED_VPN_COORDINATOR_PATH);
  const initialStart = coordinatorSource.slice(
    coordinatorSource.indexOf('private async startInternal'),
    coordinatorSource.indexOf('private async stopInternal')
  );
  const recoveryStart = coordinatorSource.slice(
    coordinatorSource.indexOf('private async runRecoveryAttempt'),
    coordinatorSource.indexOf('private handleRecoveryFailure')
  );

  assert.ok(initialStart.indexOf('await this.activateProxyLifecycle') < initialStart.indexOf("buildActiveSnapshot('RUNNING'"));
  assert.ok(recoveryStart.indexOf('await this.activateProxyLifecycle') < recoveryStart.indexOf("buildActiveSnapshot('RUNNING'"));
  assert.match(
    coordinatorSource,
    /cleanupActiveSession[\s\S]*await this\.dependencies\.proxyLifecycle\.deactivate\(active\.request\.sessionId\)[\s\S]*await this\.dependencies\.tunRuntime\.stop/u
  );
});

test('phase4 cleanup ownership drains delay lifecycle before proxy deactivate and proxy deactivate before tun stop', async () => {
  const [coordinatorSource, compositionSource] = await Promise.all([
    readUtf8(SHARED_VPN_COORDINATOR_PATH),
    readUtf8(VPN_EXTENSION_COMPOSITION_PATH)
  ]);

  assert.match(coordinatorSource, /await this\.requireProxyDelayDrain\(this\.activeSession\.request\.sessionId,\s*'VPN_STOP_FAILED'\)[\s\S]*await this\.cleanupActiveSession\(this\.activeSession\)/u);
  assertOrdered(coordinatorSource, [
    ['proxy deactivate', 'await this.dependencies.proxyLifecycle.deactivate(active.request.sessionId)'],
    ['tun stop', 'await this.dependencies.tunRuntime.stop()'],
    ['vpn id capture', 'const vpnId: string = active.handle.vpnId;'],
    ['platform destroy', 'await this.dependencies.platform.destroy(vpnId)'],
    ['notification stop', 'await this.dependencies.notification.stop(active.request.sessionId)']
  ]);
  assert.match(
    coordinatorSource,
    /if \(active\.handle !== undefined\) \{\s*const vpnId: string = active\.handle\.vpnId;[\s\S]*await this\.dependencies\.platform\.destroy\(vpnId\);[\s\S]*\}/u
  );
  assertOrdered(compositionSource, [
    ['invalidate', 'lifecycle.invalidate(sessionId)'],
    ['delay drain', 'await lifecycle.cancelAndDrainDelayTest(sessionId)'],
    ['deactivate', 'await lifecycle.deactivate(sessionId)'],
    ['tun dispose', 'tunRuntime?.dispose()'],
    ['graph close', 'await graph.close()']
  ]);
  assert.match(compositionSource, /private async retryFailedStartCleanup\(sessionId: string\): Promise<void> \{[\s\S]*await this\.disposeOwnedResources\(sessionId\)[\s\S]*this\.registry\.completeStop\(sessionId,\s*this\.retryableStartFailure\)[\s\S]*this\.clearRetryableStartCleanupState\(\)[\s\S]*this\.currentRequest = undefined[\s\S]*this\.coordinator = undefined/u);
  assert.match(compositionSource, /private async finalizeFailedStart\(sessionId: string, failure: VpnFailure \| null\): Promise<void> \{[\s\S]*await this\.disposeOwnedResources\(sessionId\)[\s\S]*this\.registry\.completeStop\(sessionId,\s*failure\)[\s\S]*this\.clearRetryableStartCleanupState\(\)[\s\S]*this\.currentRequest = undefined[\s\S]*this\.coordinator = undefined/u);
});

test('phase4 vpn contract keeps exact VPN-only home resources and safe copy', async () => {
  const [stringDocument, homePageSource, homeViewModelSource, cardSource, safeErrorCardSource] = await Promise.all([
    readJson(STRINGS_PATH),
    readUtf8(HOME_PAGE_PATH),
    readUtf8(HOME_VIEW_MODEL_PATH),
    readUtf8(CARD_PATH),
    readUtf8(SAFE_ERROR_CARD_PATH)
  ]);

  for (const [key, value] of EXACT_STRING_VALUES) {
    assert.equal(getStringValue(stringDocument, key), value, `string.json key ${key} must stay exact`);
  }
  const resourceNames = new Set((stringDocument.string ?? []).map((entry) => entry.name));
  assert.equal(
    [...resourceNames].some((name) => name.startsWith('home_local_')),
    false,
    'string.json must not publish deprecated home_local_* VPN/home resources'
  );
  assert.equal(resourceNames.has('error_vpn_requires_local_stop'), false,
    'string.json must not publish the local-stop-before-VPN product error');
  assert.equal(resourceNames.has('error_local_blocked_by_vpn'), false,
    'string.json must not publish the VPN-stop-before-local product error');

  const resourceValues = (stringDocument.string ?? []).map((entry) => `${entry.value ?? ''}`).join('\n');
  const combinedSource = `${homePageSource}\n${cardSource}\n${safeErrorCardSource}\n${resourceValues}`;
  assert.doesNotMatch(homePageSource, /\.id\('home\.local\.action'\)/u, 'HomePage must not expose a local proxy action');
  assert.match(homePageSource, /\.id\('home\.vpn\.action'\)/u, 'HomePage must own the VPN global capture action');
  assert.doesNotMatch(homeViewModelSource, /\brequestLocalAction\b|\blocalProxy\b/u,
    'HomeViewModel must stay VPN-only on the home command surface');
  assert.match(cardSource, /\$r\('app\.string\.home_vpn_notification_label'\)/u, 'RuntimeStatusCard must surface notification facts');
  assert.match(cardSource, /\$r\('app\.string\.home_vpn_recovery_label'\)/u, 'RuntimeStatusCard must surface recovery facts');
  assert.equal(getStringValue(stringDocument, 'home_vpn_proxy_group_label'), 'Proxy group',
    'string.json must publish the selected proxy group label');
  assert.equal(getStringValue(stringDocument, 'home_vpn_proxy_node_label'), 'Current node',
    'string.json must publish the selected proxy node label');
  assert.match(cardSource, /@Link\s+selectedProxyGroupName:\s*string;/u,
    'RuntimeStatusCard must accept the selected proxy group string as an ArkUI link');
  assert.match(cardSource, /@Link\s+selectedProxyNodeName:\s*string;/u,
    'RuntimeStatusCard must accept the selected proxy node string as an ArkUI link');
  assert.match(cardSource, /this\.buildSelectedProxyRows\(\)/u,
    'RuntimeStatusCard must render selected proxy rows through a member builder');
  assert.match(cardSource, /@Builder\s+private\s+buildSelectedProxyRows\(\):\s*void/u,
    'RuntimeStatusCard must define the selected proxy rows as a zero-argument member builder');
  assert.doesNotMatch(cardSource, /function\s+buildSelectedProxyRows\s*\(/u,
    'RuntimeStatusCard must not move selected proxy rows to a global builder');
  assert.match(cardSource, /if\s*\(\s*this\.selectedProxyGroupName\.length\s*>\s*0\s*&&\s*this\.selectedProxyNodeName\.length\s*>\s*0\s*\)\s*\{[\s\S]*Text\(\$r\('app\.string\.home_vpn_proxy_group_label'\)\)[\s\S]*Text\(this\.selectedProxyGroupName\)[\s\S]*Text\(\$r\('app\.string\.home_vpn_proxy_node_label'\)\)[\s\S]*Text\(this\.selectedProxyNodeName\)[\s\S]*\}/u,
    'RuntimeStatusCard member builder must render exactly the selected proxy group and node rows from linked strings');
  const selectedProxyRowsBody = extractMethodBody(cardSource, 'private buildSelectedProxyRows(): void');
  assert.doesNotMatch(selectedProxyRowsBody, /vpnState\.status/u,
    'selected proxy rows builder must not depend on composite vpnState status; non-running cleanup owns visibility');
  assert.doesNotMatch(selectedProxyRowsBody, /\bBlank\(\)/u,
    'selected proxy rows must not use Blank to squeeze long values on narrow layouts');
  assert.match(selectedProxyRowsBody, /Text\(this\.selectedProxyGroupName\)[\s\S]*\.layoutWeight\(1\)[\s\S]*\.textAlign\(TextAlign\.End\)[\s\S]*\.maxLines\(1\)[\s\S]*\.textOverflow\(\{\s*overflow:\s*TextOverflow\.Ellipsis\s*\}\)/u,
    'selected proxy group value text must use weighted end-aligned single-line ellipsis layout');
  assert.match(selectedProxyRowsBody, /Text\(this\.selectedProxyNodeName\)[\s\S]*\.layoutWeight\(1\)[\s\S]*\.textAlign\(TextAlign\.End\)[\s\S]*\.maxLines\(1\)[\s\S]*\.textOverflow\(\{\s*overflow:\s*TextOverflow\.Ellipsis\s*\}\)/u,
    'selected proxy node value text must use weighted end-aligned single-line ellipsis layout');
  assert.doesNotMatch(cardSource, /buildFactRow\([^)]*selectedProxy(?:GroupName|NodeName)/u,
    'selected proxy strings must not be rendered through the global fact-row builder');
  assert.doesNotMatch(cardSource, /\.id\([^)]*selectedProxy(?:GroupName|NodeName)/u,
    'selected proxy strings must not leak into semantic ids');
  assert.doesNotMatch(cardSource, /JSON\.stringify\s*\([^)]*selectedProxy(?:GroupName|NodeName)|hilog\.[a-z]+\([^)]*selectedProxy(?:GroupName|NodeName)/u,
    'selected proxy strings must not leak into proof or logging surfaces');
  assert.doesNotMatch(cardSource, /home_local_[A-Za-z0-9_]+/u, 'RuntimeStatusCard must not surface deprecated local home resources');

  for (const forbidden of FORBIDDEN_COPY_PATTERNS) {
    assert.doesNotMatch(combinedSource, new RegExp(forbidden.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'iu'),
      `production UI code must not claim forbidden networking scope: ${forbidden}`
    );
  }
});

test('phase4 home vpn controls stay fail-closed during shared runtime transitions', async () => {
  const [homePageSource, homeViewModelSource, profileApplicationSource] = await Promise.all([
    readUtf8(HOME_PAGE_PATH),
    readUtf8(HOME_VIEW_MODEL_PATH),
    readUtf8(PROFILE_APPLICATION_PATH)
  ]);
  const startBody = extractMethodBody(profileApplicationSource, 'async startVpnGlobalCapture(): Promise<VpnControllerStartResult>');
  const stopBody = extractMethodBody(profileApplicationSource, 'async stopVpnGlobalCapture(): Promise<VpnControllerStopResult>');

  assert.match(homePageSource, /\.id\('home\.vpn\.action'\)/u, 'HomePage must keep the VPN start/stop action');
  assert.doesNotMatch(homePageSource, /\.id\('home\.local\.action'\)/u, 'HomePage must not reintroduce a local action');
  assert.match(homeViewModelSource, /this\.application\.startVpnGlobalCapture\(\)/u,
    'HomeViewModel must start VPN through the shared application command surface');
  assert.match(homeViewModelSource, /this\.application\.stopVpnGlobalCapture\(\)/u,
    'HomeViewModel must stop VPN through the shared application command surface');
  assert.doesNotMatch(homeViewModelSource, /\brequestLocalAction\b|\blocalProxy\b/u,
    'HomeViewModel must not keep local-home command state');
  assert.match(startBody, /if \(this\.snapshot\.runtime\.state === 'STARTING' \|\| this\.snapshot\.runtime\.state === 'STOPPING'\) \{[\s\S]*createVpnFailure\('VPN_CREATE_FAILED', 'VPN global capture could not be started\.'\)/u,
    'startVpnGlobalCapture must fail closed while shared runtime transitions are in flight');
  assert.match(stopBody, /const drainFailure: VpnFailure \| undefined = await this\.requireDelayDrainVpnFailure\('VPN_STOP_FAILED'\);/u,
    'stopVpnGlobalCapture must honor the shared delay drain before stop');
});

test('phase4 one-click vpn success requires RUNNING confirmation and hot-switch never restarts the session', async () => {
  const source = await readUtf8(PROFILE_APPLICATION_PATH);
  const hotSwitchSource = source.slice(
    source.indexOf('private async applySelectionToRunningVpn('),
    source.indexOf('private async selectAndStartVpn(')
  );
  const startSource = source.slice(
    source.indexOf('private async startVpnAfterSelection('),
    source.indexOf('private async finishVpnConfirmation(')
  );
  const finishSource = source.slice(
    source.indexOf('private async finishVpnConfirmation('),
    source.indexOf('private tryAcquireRuntimeMutationOwner(')
  );

  assertOrdered(startSource, [
    ['confirmation arm', 'confirmationHandle = this.oneClickVpnConfirmation.arm(sessionId, ONE_CLICK_VPN_CONFIRMATION_TIMEOUT_MS)'],
    ['publish starting vpn', "createOneClickVpnOperationSnapshot('STARTING_VPN', true, 'NONE')"],
    ['controller start', 'await controller.start(target.profileId, target.versionId, sessionId)'],
    ['publish confirming selection', "createOneClickVpnOperationSnapshot('CONFIRMING_SELECTION', true, 'NONE')"],
    ['accept started transition', 'confirmationHandle.markStartAccepted()'],
    ['wait running proof', 'confirmationResult = await confirmationHandle.wait()']
  ]);
  assert.doesNotMatch(startSource, /return createSelectNodeAndEnsureVpnSuccessResult\('VPN_STARTED'\)/u,
    'STARTED must not be treated as a terminal success without runtime confirmation'
  );
  assert.match(startSource, /return await this\.finishVpnConfirmation\([\s\S]*groupPath[\s\S]*\)/u,
    'confirmation handoff must propagate the selected groupPath into the final RUNNING verification'
  );
  assert.match(finishSource, /if \(confirmationResult\.kind === 'RUNNING'\)[\s\S]*await this\.proxyService\.queryGroup\(groupName,\s*groupPath\)[\s\S]*queryResult\.snapshot\.group\.selectedName !== memberName \|\| selectedNode === undefined \|\| !selectedNode\.selected[\s\S]*return createSelectNodeAndEnsureVpnSuccessResult\('VPN_STARTED'\)/u,
    'VPN_STARTED must remain gated by RUNNING plus same-group runtime selection through the path-aware queryGroup contract'
  );
  assert.match(hotSwitchSource, /await this\.proxyService\.queryGroup\(groupName,\s*groupPath\)[\s\S]*await this\.proxyService\.select\(groupName,\s*memberName,\s*snapshotGeneration,\s*groupPath\)/u,
    'running-session confirmation must propagate groupPath through query and selection'
  );
  assert.doesNotMatch(hotSwitchSource, /controller\.(?:start|stop)\(|createFreshVpnSessionId|oneClickVpnConfirmation\.arm/u,
    'running-session hot switch must not restart or replace the active VPN session'
  );
});

test('phase4 proxy routing stays on the shared command bus without direct native proxy fallbacks', async () => {
  const proxyServiceSource = await readUtf8(path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'proxy', 'ProxyService.ets'));
  const runningQueryBody = extractMethodBody(proxyServiceSource, 'private async queryRunningGroup(');
  const selectBody = extractMethodBody(proxyServiceSource, 'async select(');

  for (const forbidden of [
    'libentry.so',
    'CoreNativeAdapter',
    'getInternalNativeModule'
  ]) {
    assert.doesNotMatch(proxyServiceSource, new RegExp(forbidden.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u'),
      `ProxyService must not import or call native proxy fallback surface ${forbidden}`
    );
  }
  assert.match(runningQueryBody, /this\.commandBus\.submitQueryGroup/u,
    'running proxy query routing must use the command bus'
  );
  assert.doesNotMatch(runningQueryBody, /loadConfiguration|queryProxyGroup|queryProxyGroups|selectProxy|libentry\.so|CoreNativeAdapter|getInternalNativeModule/u,
    'running proxy query routing must not contain direct core/native fallback access'
  );
  assert.match(selectBody, /this\.commandBus\.submitSelect/u,
    'running proxy selection routing must use the command bus'
  );
  assert.match(selectBody, /createVpnProxySelectCommand\([\s\S]*identity,[\s\S]*confirmedSnapshot\.generation,[\s\S]*normalizedGroupName,[\s\S]*normalizedMemberName,[\s\S]*groupPath[\s\S]*\)/u,
    'running proxy selection routing must forward the optional groupPath into the command bus command'
  );
  assert.doesNotMatch(selectBody, /coreProxy\.selectProxy|getInternalNativeModule|CoreNativeAdapter|libentry\.so/u,
    'running proxy selection routing must not contain direct native/core selection fallback access'
  );
});

test('phase4 core composition removes static owner handoff and awaits runtime mirror hydration before READY', async () => {
  const [coreCompositionSource, vpnCompositionSource] = await Promise.all([
    readUtf8(CORE_COMPOSITION_PATH),
    readUtf8(VPN_EXTENSION_COMPOSITION_PATH)
  ]);
  const combinedSource = `${coreCompositionSource}\n${vpnCompositionSource}`;

  assert.match(coreCompositionSource, /const vpnRpcClient: VpnRpcClientPort \| undefined = this\.shouldCreateVpnController\(\)\s*\?\s*this\.resolveVpnRpcClient\(\)\s*:\s*undefined;/u,
    'CoreComposition must resolve one shared VPN RPC client before controller creation'
  );
  assert.match(coreCompositionSource, /vpnController = this\.createVpnController\([\s\S]*commandBus,[\s\S]*vpnRpcClient,[\s\S]*this\.ownedVpnRpcPlatformBundle[\s\S]*\);/u,
    'CoreComposition must pass the shared command bus, RPC client, and bundle state into controller creation'
  );
  assert.match(coreCompositionSource, /new UiVpnRpcRuntimeMirror\([\s\S]*new CoreProxyServiceAdapter\(coreService\),[\s\S]*commandBus,[\s\S]*bundle,[\s\S]*client,[\s\S]*new VpnRpcProxyHandler\(runtimeClient,\s*catalog,\s*graph\.clock\)/u,
    'CoreComposition must build the UI runtime mirror from UiVpnRpcRuntimeMirror plus VpnRpcProxyHandler over the shared RPC client'
  );
  assertOrdered(coreCompositionSource, [
    ['graph creation', 'const graph: PlatformGraph = await this.createPlatformGraph(this.context);'],
    ['registry resolution', 'const vpnRegistry: VpnSessionRegistry = this.resolveVpnRegistry();'],
    ['command bus resolution', 'const commandBus: VpnProxyCommandBus = this.resolveVpnCommandBus();'],
    ['controller creation', 'vpnController = this.createVpnController('],
    ['runtime mirror initialization', 'await this.initializeRuntimeMirror(vpnController);'],
    ['profile application creation', 'const application: ProfileApplication = this.createProfileApplication('],
    ['application initialize', 'await application.initialize();'],
    ['ready publication', 'this.publish(readyState);']
  ]);
  assert.doesNotMatch(combinedSource, /InstalledVpnExtensionOwner|installedVpnExtensionOwner|installVpnExtensionOwner|clearInstalledVpnExtensionOwner|resolveInstalledVpnExtension/u,
    'production ETS source must not retain the static UI-to-extension owner handoff symbols'
  );
  assert.doesNotMatch(coreCompositionSource, /new VpnProxyRuntimeHandler|NativeVpnRuntimeBridge/u,
    'CoreComposition must not rebuild the removed legacy runtime bridge or proxy runtime handler directly'
  );
});
