import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');

const CORE_COMPOSITION_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'bootstrap', 'CoreComposition.ets');
const VPN_CONTROLLER_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'vpn', 'HarmonyVpnController.ets');
const VPN_REGISTRY_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'vpn', 'VpnSessionRegistry.ets');
const VPN_COMPOSITION_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'vpn', 'VpnExtensionComposition.ets');
const PROXY_SERVICE_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'proxy', 'ProxyService.ets');
const PROXY_COMMAND_BUS_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'proxy', 'VpnProxyCommandBus.ets');
const LOCAL_SOCKET_CLIENT_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'vpn', 'HarmonyVpnLocalSocketClient.ets');
const LOCAL_SOCKET_SERVER_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'vpn', 'HarmonyVpnLocalSocketServer.ets');
const KEY_PROVIDER_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'vpn', 'HarmonyVpnRpcKeyProvider.ets');
const PLATFORM_FACTORY_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'vpn', 'HarmonyVpnRpcPlatformFactory.ets');
const RPC_MODELS_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'vpn', 'rpc', 'VpnRpcModels.ets');
const RPC_AUTHENTICATOR_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'vpn', 'rpc', 'VpnRpcAuthenticator.ets');
const RPC_CLIENT_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'vpn', 'rpc', 'VpnRpcClient.ets');
const RPC_SERVER_SESSION_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'vpn', 'rpc', 'VpnRpcServerSession.ets');
const RPC_PROXY_HANDLER_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'vpn', 'rpc', 'VpnRpcProxyHandler.ets');
const RPC_CATALOG_BUILDER_PATH = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets', 'vpn', 'rpc', 'VpnRpcCatalogBuilder.ets');
const HOME_VIEW_MODEL_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'presentation', 'HomeViewModel.ets');
const ENTRY_STRINGS_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'string.json');
const BRIDGE_DOC_PATH = path.join(REPO_ROOT, 'docs', 'harmony', 'vpn-runtime-bridge.md');
const GUIDE_DOC_PATH = path.join(REPO_ROOT, 'docs', 'harmony', 'current-version-vpn-user-guide.md');

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

test('vpn rpc keeps versioned business transport in platform-only socket and HUKS adapters', async () => {
  const [clientSource, serverSource, keyProviderSource, platformFactorySource, proxyHandlerSource] = await Promise.all([
    readUtf8(LOCAL_SOCKET_CLIENT_PATH),
    readUtf8(LOCAL_SOCKET_SERVER_PATH),
    readUtf8(KEY_PROVIDER_PATH),
    readUtf8(PLATFORM_FACTORY_PATH),
    readUtf8(RPC_PROXY_HANDLER_PATH)
  ]);

  assert.match(clientSource, /import \{ socket \} from '@kit\.NetworkKit';/u);
  assert.match(serverSource, /import \{ socket \} from '@kit\.NetworkKit';/u);
  assert.match(platformFactorySource, /new HarmonyVpnLocalSocketClient\(undefined, this\.socketRootDir\)/u);
  assert.match(platformFactorySource, /new HarmonyVpnLocalSocketServer\(undefined, this\.socketRootDir\)/u);
  assert.match(platformFactorySource, /new HarmonyVpnRpcKeyProvider\(\)/u);
  assert.match(platformFactorySource, /const useLoopback: boolean = this\.sdkApiVersion >= 26;/u);
  assert.match(platformFactorySource, /new HarmonyVpnLoopbackSocketClient\(\)/u);
  assert.match(platformFactorySource, /new HarmonyVpnLoopbackSocketServer\(\)/u);
  assert.match(platformFactorySource, /constructor\(\s*dependencies\?: HarmonyVpnRpcPlatformDependencies,\s*socketRootDir: string = '',\s*sdkApiVersion: number = deviceInfo\.sdkApiVersion\s*\)/u);
  assert.match(clientSource, /resolveLocalSocketAddress\(this\.socketRootDir, address\)/u);
  assert.match(serverSource, /resolveLocalSocketAddress\(this\.socketRootDir, address\)/u);

  assert.match(keyProviderSource, /import \{ huks \} from '@kit\.UniversalKeystoreKit';/u);
  assert.match(keyProviderSource, /const VPN_RPC_KEY_ALGORITHM: string = 'HMAC\|SHA256';/u);
  assert.match(keyProviderSource, /const VPN_RPC_MAC_ALGORITHM: string = 'SHA256';/u);
  assert.match(keyProviderSource, /cryptoFramework\.createSymKeyGenerator\(VPN_RPC_KEY_ALGORITHM\)/u);
  assert.match(keyProviderSource, /cryptoFramework\.createMac\(VPN_RPC_MAC_ALGORITHM\)/u);
  assert.match(keyProviderSource, /await this\.operations\.generateKeyItem\(VPN_RPC_ROOT_HUKS_ALIAS/u);
  assert.match(keyProviderSource, /await this\.operations\.isKeyItemExist\(VPN_RPC_ROOT_HUKS_ALIAS/u);
  assert.match(keyProviderSource, /await this\.operations\.initSession\(/u);
  assert.match(keyProviderSource, /await this\.operations\.finishSession\(/u);
  assert.match(keyProviderSource, /await abortSessionSafely\(this\.operations,\s*sessionHandle\)/u);
  assert.doesNotMatch(keyProviderSource, /\b(?:exportKeyItem|importKeyItem|attestKeyItem|wrapKey)\b/u,
    'VPN RPC root material must stay non-exportable and app-private'
  );

  assert.match(proxyHandlerSource, /createVpnProxyQueryGroupsCommand/u);
  assert.match(proxyHandlerSource, /createVpnRpcQueryGroupRequestPayload\(groupEntry\.id\)/u);
  assert.match(proxyHandlerSource, /createVpnRpcSelectNodeRequestPayload\(normalizedCommand\.generation,\s*groupEntry\.id,\s*selectedEntry\.id\)/u);
  assert.match(proxyHandlerSource, /createVpnRpcDelayGroupRequestPayload\(normalizedCommand\.generation,\s*groupEntry\.id\)/u);
  assert.doesNotMatch(proxyHandlerSource, /\b(?:CommonEvent|AppStorage|Rdb|fileIo|libentry\.so|getInternalNativeModule)\b/u,
    'running proxy RPC business transport must not fall back to events, storage, files, or native static bridges'
  );
});

test('vpn local socket rpc protocol stays closed authenticated replay-safe and single-client bounded', async () => {
  const [modelsSource, authenticatorSource, clientSource, serverSessionSource, serverSource] = await Promise.all([
    readUtf8(RPC_MODELS_PATH),
    readUtf8(RPC_AUTHENTICATOR_PATH),
    readUtf8(RPC_CLIENT_PATH),
    readUtf8(RPC_SERVER_SESSION_PATH),
    readUtf8(LOCAL_SOCKET_SERVER_PATH)
  ]);

  for (const method of [
    'PING',
    'GET_SNAPSHOT',
    'GET_CATALOG_DIGEST',
    'QUERY_GROUPS',
    'QUERY_GROUP',
    'SELECT_NODE',
    'START_DELAY_TEST',
    'READ_DELAY_TEST',
    'CANCEL_DELAY_TEST',
    'STOP_VPN',
    'RUNTIME_CHANGED',
    'DELAY_CHANGED',
    'SERVER_STOPPING'
  ]) {
    assert.match(modelsSource, new RegExp(`'${method}'`, 'u'));
  }
  for (const code of [
    'RPC_UNAVAILABLE',
    'RPC_DISCONNECTED',
    'AUTH_FAILED',
    'PROTOCOL_MISMATCH',
    'FRAME_INVALID',
    'SESSION_CHANGED',
    'CATALOG_MISMATCH',
    'COMMAND_BUSY',
    'COMMAND_TIMEOUT',
    'CORE_OPERATION_FAILED',
    'REQUEST_REPLAY_EXPIRED',
    'SERVER_STOPPING'
  ]) {
    assert.match(modelsSource, new RegExp(`'${code}'`, 'u'));
  }

  assert.match(authenticatorSource, /clientProof/u);
  assert.match(authenticatorSource, /serverProof/u);
  assert.match(authenticatorSource, /FRAME_MAC_LABEL/u);
  assert.match(authenticatorSource, /deriveVpnRpcSocketAddress/u);
  assert.match(authenticatorSource, /decoded\.clientEpoch !== this\.clientEpoch \|\| decoded\.sequence !== this\.expectedIncomingSequence/u);

  assert.match(clientSource, /private requestOrdinal: number = 1;/u);
  assert.match(clientSource, /private socket: VpnRpcSocketConnectionPort \| null = null;/u);
  assert.match(clientSource, /private connection: VpnRpcAuthenticatedConnection \| null = null;/u);
  assert.match(clientSource, /this\.requestOrdinal = 1;/u);

  assert.match(serverSessionSource, /const RESPONSE_CACHE_LIMIT: number = 256;/u);
  assert.match(serverSessionSource, /const PENDING_LIMIT: number = 64;/u);
  assert.match(serverSessionSource, /if \(cached !== undefined\)[\s\S]*await this\.sendRawFrameOrdered\(context, cached\.frameBytes\);/u);
  assert.match(serverSessionSource, /if \(requestOrdinal <= context\.highestAcceptedOrdinal\)[\s\S]*createReplayExpiredResponse\(request\)/u);
  assert.match(serverSessionSource, /while \(context\.cacheOrder\.length > RESPONSE_CACHE_LIMIT\)/u);

  assertOrdered(serverSource, [
    ['existing active connection check', 'if (this.activeConnection !== undefined) {'],
    ['close previous connection', 'await previous.close();'],
    ['install next active connection', 'this.activeConnection = adapter;']
  ]);
});

test('vpn running proxy commands use the authenticated rpc session generation authority', async () => {
  const [commandBusSource, proxyServiceSource, coreCompositionSource, controllerSource] = await Promise.all([
    readUtf8(PROXY_COMMAND_BUS_PATH),
    readUtf8(PROXY_SERVICE_PATH),
    readUtf8(CORE_COMPOSITION_PATH),
    readUtf8(VPN_CONTROLLER_PATH)
  ]);

  assert.match(
    commandBusSource,
    /bind\(identity: ProxyRuntimeIdentity, handler: VpnProxyCommandHandler, sessionGeneration\?: number\): number/u
  );
  assert.match(
    commandBusSource,
    /activeSessionGeneration\(identity: ProxyRuntimeIdentity\): number \| undefined \{[\s\S]*!sameIdentity\(active\.identity, identity\)[\s\S]*return active\.sessionGeneration;/u
  );
  assertOrdered(proxyServiceSource, [
    ['read bound rpc session generation', 'this.commandBus.activeSessionGeneration(routing.identity!)'],
    ['prefer bound rpc session generation', 'if (authoritativeGeneration !== undefined) {'],
    ['fall back only for non-rpc handlers', 'const cached: RunningGenerationBinding | undefined = this.runningGenerationBinding;']
  ]);
  assert.match(
    coreCompositionSource,
    /this\.commandBus\.bind\([\s\S]*createProxyRuntimeIdentity\([\s\S]*handler,\s*context\.sessionGeneration\s*\);/u
  );
  assert.match(
    controllerSource,
    /const nextKey: string =\s*`\$\{request\.profileId\}\\u0000\$\{request\.versionId\}\\u0000\$\{request\.sessionId\}\\u0000\$\{context\.guards\.catalogDigest \?\? ''\}\\u0000\$\{context\.sessionGeneration\}`;/u
  );
});

test('vpn local socket rpc keeps one shared UI client one extension server and zero legacy bridge surfaces', async () => {
  const [coreCompositionSource, vpnCompositionSource] = await Promise.all([
    readUtf8(CORE_COMPOSITION_PATH),
    readUtf8(VPN_COMPOSITION_PATH)
  ]);
  const combinedSource = `${coreCompositionSource}\n${vpnCompositionSource}`;

  assert.match(coreCompositionSource, /if \(this\.ownedVpnRpcClient !== undefined\) \{\s*return this\.ownedVpnRpcClient;/u);
  assert.match(coreCompositionSource, /this\.ownedVpnRpcPlatformBundle = bundle;/u);
  assert.match(coreCompositionSource, /new UiVpnRpcRuntimeMirror\(/u);
  assert.match(coreCompositionSource, /new VpnRpcProxyHandler\(runtimeClient,\s*catalog,\s*graph\.clock\)/u);
  assert.match(coreCompositionSource, /new HarmonyVpnRpcPlatformFactory\(undefined, this\.context\.filesDir\)\.create\(\)/u);
  assert.match(coreCompositionSource, /new HarmonyVpnRpcPlatformFactory\(undefined, context\.filesDir\)\.create\(\)/u);

  assert.match(vpnCompositionSource, /const rpcBundle: HarmonyVpnRpcPlatformBundle = this\.createVpnRpcPlatformBundle\(\);/u);
  assertOrdered(vpnCompositionSource, [
    ['rpc catalog begin stage', "reportVpnStartStage('rpc.catalog.begin')"],
    ['rpc catalog build', 'const rpcCatalog = await buildVpnRpcCatalog('],
    ['rpc catalog ok stage', "reportVpnStartStage('rpc.catalog.ok')"],
    ['rpc address begin stage', "reportVpnStartStage('rpc.address.begin')"],
    ['rpc address derivation', 'const rpcAddress: string = await deriveVpnRpcSocketAddress(rpcBundle.crypto)'],
    ['rpc address ok stage', "reportVpnStartStage('rpc.address.ok')"]
  ]);
  assert.match(vpnCompositionSource, /const rpcSession: VpnRpcServerSessionPort = this\.createVpnRpcServerSession\(/u);
  assert.match(vpnCompositionSource, /rpcAddress,/u);
  assert.match(vpnCompositionSource, /const rpcServer: VpnRpcServerPort = this\.createVpnRpcServer\(/u);
  assertOrdered(vpnCompositionSource, [
    ['install rpc server owner', 'this.rpcServer = rpcServer;'],
    ['rpc listen begin stage', "reportVpnStartStage('rpc.server.listen.begin')"],
    ['rpc listen', 'await rpcServer.listen();'],
    ['rpc listen ok stage', "reportVpnStartStage('rpc.server.listen.ok')"],
    ['journal ready stage', "reportVpnStartStage('rpc.journal.ready')"]
  ]);
  assert.match(vpnCompositionSource, /new HarmonyVpnRpcPlatformFactory\(undefined, this\.context\?\.filesDir \?\? ''\)\.create\(\)/u);

  assert.doesNotMatch(combinedSource, /\b(?:NativeVpnRuntimeBridge|VpnRuntimeBridgeModels|claimVpnRuntimeBridgeSession|publishVpnRuntimeBridgeSnapshotIfOwned|readVpnRuntimeBridgeSnapshot|clearVpnRuntimeBridgeSnapshotIfOwned)\b/u,
    'legacy same-process bridge surfaces must stay removed'
  );
  assert.doesNotMatch(vpnCompositionSource, /\b(?:CommonEvent|AppStorage|Rdb|fileIo)\b/u,
    'VPN extension runtime authority must not fall back to event, storage, or file bridges'
  );
});

test('vpn controller startup hydration uses one-shot connect first background connect second and keeps mirror init before READY', async () => {
  const [controllerSource, registrySource, proxyServiceSource, coreCompositionSource] = await Promise.all([
    readUtf8(VPN_CONTROLLER_PATH),
    readUtf8(VPN_REGISTRY_PATH),
    readUtf8(PROXY_SERVICE_PATH),
    readUtf8(CORE_COMPOSITION_PATH)
  ]);

  assertOrdered(controllerSource, [
    ['runtime mirror hydration gate', 'this.registry.beginRuntimeMirrorHydration();'],
    ['one-shot startup probe', 'await this.rpcClient.connectOnce();']
  ]);
  assert.match(controllerSource, /async initializeRuntimeMirror\(\): Promise<void> \{[\s\S]*await this\.rpcClient\.connectOnce\(\);/u);
  assert.match(controllerSource, /private async runStartConnectFlow\(token: number, request: VpnStartRequest\): Promise<void> \{[\s\S]*await this\.rpcClient\.connect\(\);/u);
  assert.match(controllerSource, /private launchRuntimeMirrorRecovery\(\): void \{[\s\S]*void recoveryPromise\.catch\(\(\): void => \{\}\);[\s\S]*\}/u);
  assert.match(controllerSource, /private async runRuntimeMirrorRecovery\(token: number\): Promise<void> \{[\s\S]*await this\.rpcClient\.connect\(\);/u);
  assert.match(controllerSource, /private readonly scheduler\?: BoundedDelaySchedulerPort;/u);
  assert.match(controllerSource, /private runtimeMirrorRetryTask\?: CancelableDelayTask;/u);
  assert.match(controllerSource, /const RUNTIME_MIRROR_RETRY_DELAYS_MS: number\[\] = \[250, 500, 1000, 2000, 4000\];/u);
  assert.match(controllerSource, /async initializeRuntimeMirror\(\): Promise<void> \{[\s\S]*if \(this\.runtimeMirrorHydrationToken !== 0\) \{\s*return;\s*\}[\s\S]*\}/u);
  assert.match(controllerSource, /private completeRuntimeMirrorHydrationPromise\?: Promise<void>;/u);
  assert.match(controllerSource, /private scheduleRuntimeMirrorRetry\(token: number, knownRequest\?: VpnStartRequest\): void \{/u);
  assert.match(controllerSource, /this\.runtimeMirrorRetryTask = scheduler\.schedule\(delayMs, async \(\): Promise<void> => \{/u);
  assert.match(
    controllerSource,
    /this\.registry\.hydrateFailure\([\s\S]*createVpnFailure\('VPN_PROXY_REPLAY_FAILED', 'Proxy runtime mirror hydration failed\.'\),[\s\S]*knownRequest[\s\S]*\);/u
  );
  assertOrdered(controllerSource, [
    ['recovery snapshot read', 'const snapshot: VpnRuntimeSnapshot = this.rpcClient.snapshot();'],
    ['mirror sync before hydrate', 'await this.syncRuntimeMirror(snapshot, context, knownRequest);'],
    ['authoritative hydrate after sync', 'this.hydrateRegistryFromReadyRpc(latestSnapshot, latestContext, latestKnownRequest);']
  ]);
  assert.match(
    controllerSource,
    /if \(this\.completeRuntimeMirrorHydrationPromise !== undefined &&[\s\S]*this\.completeRuntimeMirrorHydrationToken === token\) \{[\s\S]*return await this\.completeRuntimeMirrorHydrationPromise;/u
  );
  assertOrdered(controllerSource, [
    ['candidate snapshot read', 'const candidateSnapshot: VpnRuntimeSnapshot = this.rpcClient.snapshot();'],
    ['latest snapshot reread', 'const latestSnapshot: VpnRuntimeSnapshot = this.rpcClient.snapshot();'],
    ['change detection continue', 'continue;'],
    ['stable authoritative hydrate', 'this.hydrateRegistryFromReadyRpc(latestSnapshot, latestContext, latestKnownRequest);']
  ]);
  assert.match(
    controllerSource,
    /const mirrorSynchronized: boolean = await this\.syncRuntimeMirror\([\s\S]*candidateSnapshot,[\s\S]*candidateContext,[\s\S]*candidateKnownRequest[\s\S]*\);/u
  );
  assert.match(controllerSource, /private async runRuntimeMirrorRecovery\(token: number\): Promise<void> \{[\s\S]*try \{[\s\S]*await this\.rpcClient\.connect\(\);[\s\S]*\} catch \(_\) \{[\s\S]*await this\.completeRuntimeMirrorHydrationUnavailableSafely\(token\);[\s\S]*return;[\s\S]*\}[\s\S]*await this\.completeRuntimeMirrorHydrationFromRpc\(token\);[\s\S]*\}/u);
  assert.match(controllerSource, /private async handleRuntimeChanged\(\): Promise<void> \{[\s\S]*if \(this\.runtimeMirrorHydrationToken !== 0\) \{[\s\S]*await this\.completeRuntimeMirrorHydrationFromRpc\(this\.runtimeMirrorHydrationToken\);[\s\S]*return;[\s\S]*\}[\s\S]*this\.registry\.beginRuntimeMirrorHydration\(\);[\s\S]*await this\.completeRuntimeMirrorHydrationFromRpc\(token\);/u);
  assert.match(controllerSource, /if \(requiresLiveRpcContext\(snapshot, context\)\) \{[\s\S]*const mirrorSynchronized: boolean = await this\.syncRuntimeMirror\(snapshot, context, request\);[\s\S]*if \(!mirrorSynchronized\) \{[\s\S]*return createRejectedResult\(this\.registry\.snapshot\(\), createStartFailure\(\)\);[\s\S]*\}[\s\S]*this\.registry\.hydrateRpcSnapshot\(snapshot, context, request\);/u);
  assert.match(controllerSource, /if \(requiresLiveRpcContext\(snapshot, context\)\) \{[\s\S]*const mirrorSynchronized: boolean = await this\.syncRuntimeMirror\(snapshot, context, pendingStart\.request\);[\s\S]*if \(!mirrorSynchronized\) \{[\s\S]*void this\.failPendingStart\(pendingStart\.token, pendingStart\.request, createStartFailure\(\)\);[\s\S]*return;[\s\S]*\}[\s\S]*this\.registry\.hydrateRpcSnapshot\(snapshot, context, pendingStart\.request\);/u);
  assert.match(controllerSource, /private async syncRuntimeMirror\([\s\S]*\): Promise<boolean> \{/u);
  assert.match(
    controllerSource,
    /if \(request === undefined \|\| context === null \|\| snapshot\.state === 'STOPPED' \|\| snapshot\.state === 'ERROR'\) \{[\s\S]*await this\.deactivateRuntimeMirror\(activeSessionId\);[\s\S]*return true;/u
  );
  assert.match(
    controllerSource,
    /await runtimeMirror\.bindExistingSession\(request\);[\s\S]*if \(this\.disposed\) \{[\s\S]*await this\.deactivateRuntimeMirror\(request\.sessionId\);[\s\S]*return false;/u
  );
  assert.match(controllerSource, /private async syncRuntimeMirror\([\s\S]*\): Promise<boolean> \{/u);
  assert.match(controllerSource, /await runtimeMirror\.bindExistingSession\(request\);[\s\S]*this\.mirroredBindingKey = nextKey;[\s\S]*return true;[\s\S]*\} catch \(_\) \{[\s\S]*this\.mirroredBindingKey = undefined;[\s\S]*return false;[\s\S]*\}/u);
  assert.match(controllerSource, /private async completeRuntimeMirrorHydrationUnavailableSafely\(token: number\): Promise<void> \{[\s\S]*this\.registry\.completeRuntimeMirrorHydrationUnavailable\(\);[\s\S]*\}/u);

  assertOrdered(registrySource, [
    ['registry hydration pending', 'this.runtimeMirrorHydrationPending = true;'],
    ['registry recovering publish', "state: 'RECOVERING'"],
    ['registry publish recovering snapshot', 'this.publishSnapshot(nextSnapshot, inferEventType(this.snapshotValue, nextSnapshot));']
  ]);
  assertOrdered(registrySource, [
    ['registry hydration cleared', 'this.runtimeMirrorHydrationPending = false;'],
    ['registry unavailable clears live session', 'this.liveSessionId = undefined;'],
    ['registry unavailable publishes stopped', "this.publishSnapshot(buildStoppedSnapshot(this.snapshotValue.lastFailure), 'STOPPED');"]
  ]);

  assertOrdered(proxyServiceSource, [
    ['non-running non-stopped route rejects', "return {\n      kind: 'REJECTED',\n      rejected: this.rejectRuntimeNotReady()\n    };"],
    ['runtime not ready code', "createProxyRejectedError('PROXY_RUNTIME_NOT_READY', false, this.clock.now())"]
  ]);
  assertOrdered(proxyServiceSource, [
    ['listGroups resolves routing', 'const routing: RoutingResolution = await this.resolveRouting();'],
    ['running route stays on command bus', "if (routing.kind === 'RUNNING') {"],
    ['stopped listGroups uses local query', 'return await this.queryStoppedGroups(routing.active!, routing.identity!, generation);']
  ]);
  assertOrdered(proxyServiceSource, [
    ['queryGroup resolves routing', 'const routing: RoutingResolution = await this.resolveRouting();'],
    ['running queryGroup stays on command bus', "if (routing.kind === 'RUNNING') {"],
    ['stopped queryGroup uses local query', 'return await this.queryStoppedGroup(']
  ]);
  assertOrdered(proxyServiceSource, [
    ['stopped route acquire lease', 'const lease: VpnStoppedProxyLease | undefined = this.vpnSnapshotPort.acquireStoppedProxyLease();'],
    ['lease gate rejects when unavailable', 'if (lease === undefined) {'],
    ['stopped resolver returns leased route', "kind: 'STOPPED'"]
  ]);
  assert.match(proxyServiceSource, /if \(snapshot\.state === 'STOPPED'\) \{[\s\S]*const lease: VpnStoppedProxyLease \| undefined = this\.vpnSnapshotPort\.acquireStoppedProxyLease\(\);[\s\S]*if \(lease === undefined\) \{[\s\S]*rejected: this\.rejectRuntimeNotReady\(\)[\s\S]*\}[\s\S]*return \{[\s\S]*kind: 'STOPPED'[\s\S]*lease/u);
  assertOrdered(proxyServiceSource, [
    ['stopped route check in resolver', "if (snapshot.state === 'STOPPED') {"],
    ['stopped route acquire lease in resolver', 'const lease: VpnStoppedProxyLease | undefined = this.vpnSnapshotPort.acquireStoppedProxyLease();'],
    ['stopped lease snapshot check', 'const leasedSnapshot: VpnRuntimeSnapshot = lease.snapshot();']
  ]);

  assertOrdered(coreCompositionSource, [
    ['runtime mirror initialize', 'await this.initializeRuntimeMirror(vpnController);'],
    ['application initialize', 'await application.initialize();'],
    ['ready publication', 'this.publish(readyState);']
  ]);
});

test('vpn rpc catalog builder reports only fixed stage boundaries around fallible core and HUKS work', async () => {
  const source = await readUtf8(RPC_CATALOG_BUILDER_PATH);
  assert.match(source, /export type VpnRpcCatalogBuildStageReporter = \(stage: string\) => void;/u);
  assert.match(source, /reportStage: VpnRpcCatalogBuildStageReporter = \(_stage: string\): void => \{\}/u);
  assertOrdered(source, [
    ['config begin', "reportStage('rpc.catalog.config.begin')"],
    ['load configuration', 'await coreProxy.loadConfiguration(configPath)'],
    ['config ok', "reportStage('rpc.catalog.config.ok')"],
    ['groups begin', "reportStage('rpc.catalog.groups.begin')"],
    ['query groups', 'await coreProxy.queryProxyGroups(context, true)'],
    ['groups ok', "reportStage('rpc.catalog.groups.ok')"],
    ['traversal begin', "reportStage('rpc.catalog.traversal.begin')"],
    ['traversal ok', "reportStage('rpc.catalog.traversal.ok')"],
    ['opaque begin', "reportStage('rpc.catalog.opaque.begin')"],
    ['opaque build', 'await buildVpnOpaqueCatalog(crypto, profileHash, revisionHash, groups)'],
    ['opaque ok', "reportStage('rpc.catalog.opaque.ok')"]
  ]);
});

test('vpn local socket rpc docs describe authenticated cross-process behavior user operations and privacy limits', async () => {
  const [homeViewModelSource, entryStringsSource, bridgeDocSource, guideDocSource] = await Promise.all([
    readUtf8(HOME_VIEW_MODEL_PATH),
    readUtf8(ENTRY_STRINGS_PATH),
    readUtf8(BRIDGE_DOC_PATH),
    readUtf8(GUIDE_DOC_PATH)
  ]);
  const entryStrings = JSON.parse(entryStringsSource);
  const recoveringEntry = entryStrings.string.find((entry) => entry.name === 'error_vpn_recovering');
  const proxyManageDisabledEntry = entryStrings.string.find((entry) => entry.name === 'detail_proxy_requires_active');

  assert.match(
    homeViewModelSource,
    /const canManageProxies: boolean = snapshot\.status === 'READY' &&\s*isProfileStartEligible\(activeProfile\)\s*&&\s*\(vpnSnapshot\.state === 'STOPPED' \|\| vpnSnapshot\.state === 'RUNNING'\);/u
  );
  assertOrdered(homeViewModelSource, [
    ['running state keeps stop action', "if (vpnSnapshot.state === 'RUNNING') {\n    return 'STOP';"],
    ['active error keeps stop action', "if (vpnSnapshot.state === 'ERROR' && vpnSnapshot.activeRequest !== null) {\n    return 'STOP';"],
    ['profile fallback eligibility gate', 'if (!isProfileStartEligible(activeProfile)) {']
  ]);
  assert.equal(typeof recoveringEntry?.value, 'string', 'entry strings must define error_vpn_recovering');
  assert.equal(recoveringEntry.value.includes('network change'), false, 'recovering copy must not claim a network-change cause');
  assert.equal(recoveringEntry.value.includes('being restored'), true, 'recovering copy must describe generic state restoration');
  assert.equal(typeof proxyManageDisabledEntry?.value, 'string', 'entry strings must define detail_proxy_requires_active');
  assert.equal(proxyManageDisabledEntry.value.includes('启用此配置'), true,
    'profile-detail proxy disabled copy must mention the active-profile requirement'
  );
  assert.equal(
    proxyManageDisabledEntry.value.includes('VPN 状态稳定') || proxyManageDisabledEntry.value.includes('VPN状态稳定'),
    true,
    'proxy management disabled copy must mention the stable VPN-state requirement'
  );

  for (const required of [
    'LocalSocket RPC',
    'HUKS',
    'mutual authentication',
    'MAC',
    'single shared UI client',
    'single VPN-extension server',
    'opaque IDs',
    'two PIDs',
    'startup probe',
    'connectOnce',
    'bounded recovery',
    'connect()',
    '250/500/1000/2000/4000',
    'RECOVERING',
    'ERROR',
    'VPN_PROXY_REPLAY_FAILED',
    'fail-close',
    'stop available',
    'mirror before READY',
    'STOPPED'
  ]) {
    assert.equal(bridgeDocSource.includes(required), true, `vpn runtime bridge doc must mention ${required}`);
  }
  assert.match(bridgeDocSource, /mirror before READY[\s\S]*startup probe[\s\S]*connectOnce/u);
  assert.match(bridgeDocSource, /bounded recovery[\s\S]*connect\(\)[\s\S]*RECOVERING[\s\S]*fail-close/u);
  assert.match(bridgeDocSource, /250\/500\/1000\/2000\/4000[\s\S]*VPN_PROXY_REPLAY_FAILED[\s\S]*ERROR[\s\S]*stop available/u);
  assert.match(bridgeDocSource, /RECOVERING[\s\S]*STOPPED/u, 'bridge doc must describe exhausting recovery before STOPPED');
  for (const required of [
    'LocalSocket RPC',
    'separate PIDs',
    'Start VPN global capture',
    'Stop VPN global capture',
    '测速全部节点',
    '下次启动生效',
    '重新打开应用后',
    'TCP / UDP / DNS',
    'system VPN'
  ]) {
    assert.equal(guideDocSource.includes(required), true, `current vpn guide must mention ${required}`);
  }

  assert.doesNotMatch(`${bridgeDocSource}\n${guideDocSource}`, /NativeVpnRuntimeBridge|same-process native bridge|AppService RPC|process = ":vpn"|extensionProcessMode/iu,
    'public docs must stop teaching the removed same-process bridge path'
  );
  assert.doesNotMatch(`${bridgeDocSource}\n${guideDocSource}`, /https?:\/\/|token=|password|credential|secret|nonce|serverProof|clientProof|sessionId|profileId|versionId/u,
    'public docs must not leak test URLs, secrets, or private RPC identities'
  );
});
