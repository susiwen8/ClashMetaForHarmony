# HarmonyOS VPN Runtime Bridge Implementation Plan

## Status

Closed without adoption on August 25, 2026. The Task9A same-process co-location experiment was reverted after physical-device evidence showed that the packaged configuration did not produce a shared PID on phone hardware.

## Verified Evidence

- Default runtime placement keeps the UI ability and VPN extension in separate PIDs.
- An explicit VPN-extension `process` override is rejected by the Hvigor schema.
- `EntryAbility.process = ":vpn"` plus `CmfaVpnExtensionAbility.extensionProcessMode = "type"` was source-valid and package-inspection-valid, but physical proof still reported `samePid=false`.
- Fixed-stage timestamps were current, so the result was not caused by stale package data.
- Because same-PID proof failed, one-click proof remained incomplete and the delay lane was not advanced as a success claim.

## Final Outcome

- The source manifest is back to the pre-Task9A process configuration.
- Co-location-specific structure/package assertions were removed.
- The package inspector stays strict about signed artifacts and no longer exposes the Task9A-only co-location aggregate.
- Generic privacy/security hardening from Task9A remains in place.

## Retained Hardening

- JSON5-like parsing for structure/package inspection remains available.
- Package-inspection failures still normalize to fixed safe public messages.
- CLI unknown-flag handling still parses once, writes only safe reports, and avoids leaking raw flag values, cwd, usernames, stack traces, or filesystem details.

## Next Decision Gate

The next required architecture is true private cross-process RPC.

- AppService RPC is not a phone-safe default because current support is enterprise/2in1-only.
- No replacement RPC mechanism is selected in this plan.
- User decision is pending before any new architecture lane should begin.

## Verification Expectations

Any future replacement must re-prove all of the following before it can supersede this plan:

- truthful UI runtime marker restoration on phone hardware;
- truthful hot-switch behavior while VPN is already running;
- private identity/failure handling with no public leakage;
- strict signed-package inspection without bypass flags;
- passing one-click and delay proofs on the same signed artifact.

- [ ] **Step 1: Write failing NAPI and ArkTS codec tests**

The exact native declarations are:

```ts
export type NativeVpnRuntimeBridgeState =
  | 'EMPTY' | 'STARTING' | 'RUNNING' | 'RECOVERING' | 'STOPPING' | 'STOPPED' | 'ERROR';

export type NativeVpnRuntimeBridgeFailureCode =
  | 'VPN_PERMISSION_DENIED'
  | 'VPN_ALREADY_ACTIVE'
  | 'VPN_PROFILE_UNAVAILABLE'
  | 'VPN_LOCAL_STOP_REQUIRED'
  | 'VPN_CONFIG_INVALID'
  | 'VPN_CREATE_FAILED'
  | 'VPN_TUN_FD_INVALID'
  | 'VPN_TUN_START_FAILED'
  | 'VPN_SOCKET_PROTECT_FAILED'
  | 'VPN_LOCAL_PORT_CONFLICT'
  | 'VPN_BACKGROUND_TASK_FAILED'
  | 'VPN_PROXY_REPLAY_FAILED'
  | 'VPN_SYSTEM_REVOKED'
  | 'VPN_STOP_FAILED';

export interface NativeVpnRuntimeBridgeIdentity {
  sessionId: string;
  profileId: string;
  versionId: string;
}

export interface NativeVpnRuntimeBridgeSnapshot {
  generation: number;
  state: NativeVpnRuntimeBridgeState;
  sessionId: string | null;
  profileId: string | null;
  versionId: string | null;
  failureCode: NativeVpnRuntimeBridgeFailureCode | null;
}

export declare function claimVpnRuntimeBridgeSession(identity: NativeVpnRuntimeBridgeIdentity): number;
export declare function publishVpnRuntimeBridgeSnapshotIfOwned(
  writerGeneration: number,
  snapshot: NativeVpnRuntimeBridgeSnapshot
): boolean;
export declare function readVpnRuntimeBridgeSnapshot(): NativeVpnRuntimeBridgeSnapshot;
export declare function clearVpnRuntimeBridgeSnapshotIfOwned(writerGeneration: number, sessionId: string): boolean;
```

Native fake-environment tests must reject:

- missing, inherited, symbol, numeric, non-enumerable, duplicate, or extra keys;
- non-plain objects;
- unknown state/failure enums;
- blank, embedded-NUL, invalid UTF-8, or over-256-byte identities;
- negative, fractional, zero-owner, or above-safe-integer generations;
- snapshot generation/identity mismatches;
- failure detail or any key outside the six snapshot keys.

Also prove two fake NAPI environments see the same process-static snapshot, destroying a reader environment does not clear it, and the writer can publish after that teardown.

ArkTS tests must use an injected fake module and prove the adapter returns cloned, normalized private values and maps malformed native data to one fixed bridge-validation error without embedding any input value.

- [ ] **Step 2: Add the NAPI host case and verify RED**

Add:

```js
['napi-vpn-runtime-bridge', {
  sources: [
    NAPI_ENVIRONMENT_SOURCE,
    VPN_RUNTIME_BRIDGE_STORE_SOURCE,
    JS_ERRORS_SOURCE,
    JS_CODEC_SOURCE,
    JS_VPN_RUNTIME_BRIDGE_SOURCE,
    JS_VPN_RUNTIME_BRIDGE_NAPI_TEST_SOURCE
  ],
  defines: ['CMFA_VPN_RUNTIME_BRIDGE_TESTING=1'],
  prefix: 'napi-vpn-runtime-bridge-test-',
  includeDirs: [NAPI_SHIM_INCLUDE_DIR, ENTRY_INCLUDE_DIR],
  outputName: 'js_vpn_runtime_bridge_napi_test'
}]
```

Run:

```bash
node harmony/tools/test-native-host.mjs --case napi-vpn-runtime-bridge
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: native compile and ArkTS compile/tests fail because the bridge codec/adapter does not exist.

- [ ] **Step 3: Implement the exact NAPI callbacks**

Declare and register only these addon callbacks:

```cpp
napi_value claim_vpn_runtime_bridge_session(napi_env env, napi_callback_info info);
napi_value publish_vpn_runtime_bridge_snapshot_if_owned(napi_env env, napi_callback_info info);
napi_value read_vpn_runtime_bridge_snapshot(napi_env env, napi_callback_info info);
napi_value clear_vpn_runtime_bridge_snapshot_if_owned(napi_env env, napi_callback_info info);
```

Use exact-own-key validation, safe-integer validation, plain-object validation, bounded UTF-8 decoding, and explicit state/failure allowlists. Return booleans for stale publish/clear rather than throwing. Throw only a generic argument/state `CoreError` with a fixed operation name; never include field values.

Add the source to `libentry.so` and four descriptors to `define_core_module`. Do not touch `harmony/core/abi/include/cmfa_core.h`, `cmfa_host.h`, `cmfa_types.h`, or the 19-function public core ABI list.

- [ ] **Step 4: Implement the entry-private model and adapter**

Expose narrow private ports:

```ts
export interface VpnRuntimeBridgeReaderPort {
  read(): VpnRuntimeBridgeSnapshot;
}

export interface VpnRuntimeBridgeWriterPort extends VpnRuntimeBridgeReaderPort {
  claim(identity: VpnRuntimeBridgeIdentity): number;
  publishIfOwned(writerGeneration: number, snapshot: VpnRuntimeBridgeSnapshot): boolean;
  clearIfOwned(writerGeneration: number, sessionId: string): boolean;
}
```

`VpnRuntimeBridgeModels.ets` must enforce the same exact invariants as C++ and provide:

```ts
export function createVpnRuntimeBridgeIdentity(request: VpnStartRequest): VpnRuntimeBridgeIdentity;
export function cloneVpnRuntimeBridgeSnapshot(snapshot: VpnRuntimeBridgeSnapshot): VpnRuntimeBridgeSnapshot;
export function bridgeFailureToVpnFailure(code: VpnFailureCode): VpnFailure;
```

`bridgeFailureToVpnFailure` uses fixed safe details only. The model and adapter stay under `entry`; do not export them from `@cmfa/shared` or `@cmfa/core`.

- [ ] **Step 5: Run native/entry GREEN**

```bash
node harmony/tools/test-native-host.mjs --case vpn-runtime-bridge-store
node harmony/tools/test-native-host.mjs --case napi-vpn-runtime-bridge
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: store, NAPI, and ArkTS adapter tests pass.

- [ ] **Step 6: Verify private ABI and source hygiene**

```bash
node harmony/tools/test-native-host.mjs --case contract
rg -n "claimVpnRuntimeBridge|publishVpnRuntimeBridge|readVpnRuntimeBridge|clearVpnRuntimeBridge" \
  harmony/core/abi harmony/core/src || true
git diff --check
```

Expected: public core ABI test passes; the `rg` command has no matches; diff check is clean. Do not commit.

---

## Chunk 2: Extension Writer, Bind-Only UI Mirror, and Hydration

### Task 3: Add a replay-free proxy mirror lifecycle

**Files:**
- Modify: `harmony/shared/src/main/ets/proxy/ProxyPorts.ets`
- Modify: `harmony/shared/src/main/ets/proxy/VpnProxyRuntimeHandler.ets`
- Modify: `harmony/shared/src/test/VpnProxyRuntimeHandler.test.ets`

- [ ] **Step 1: Write failing mirror lifecycle tests**

Add the narrow port:

```ts
export interface VpnProxyRuntimeMirrorPort {
  bindExistingSession(request: VpnStartRequest): Promise<void>;
  deactivate(sessionId: string): Promise<void>;
}
```

Tests must prove:

- `bindExistingSession()` validates profile existence, activation eligibility, exact `versionId`, and nonblank session;
- it computes the same profile/revision/session identity and hashes as `activate()`;
- it binds the supplied UI `VpnProxyCommandBus` and enables query/select/delay through that bus;
- it never calls `selectionRepository.listByProfile`, `upsert`, or `delete` and never calls core `selectProxy` during bind;
- it does not mutate timestamps;
- bind failure leaves no active state;
- rebinding first drains/deactivates the old UI binding;
- `deactivate()` invalidates, drains any delay job, deactivates the bus, and is idempotent;
- existing `activate()` still reads/replays selections before binding, preserving the extension-owned order.

- [ ] **Step 2: Run shared tests and verify RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: compile/test failure because the mirror port and bind-only method do not exist.

- [ ] **Step 3: Refactor the minimal shared primitives**

Keep one identity resolver and one binder:

```ts
private async resolveActivationState(request: VpnStartRequest): Promise<ActiveRuntimeState>;

private bindState(state: ActiveRuntimeState): void {
  this.activeState = state;
  try {
    this.commandBus.bind(state.identity, this);
  } catch (_) {
    this.activeState = undefined;
    throw new Error('Binding failed.');
  }
}
```

The two public flows are exact:

```ts
activate = deactivate old -> resolve -> list -> replay -> bindState
bindExistingSession = deactivate old -> resolve -> bindState
```

Both run through the existing `lifecycleQueue` and both map private causes to the existing fixed activation error. Do not add a second handler class or direct native proxy calls.

- [ ] **Step 4: Run shared GREEN**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: all shared tests pass, including unchanged replay and delay suites.

- [ ] **Step 5: Verification checkpoint**

Run `git diff --check` and do not commit.

### Task 4: Make the VPN extension the only native bridge writer

**Files:**
- Modify: `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets`
- Modify: `harmony/entry/src/test/VpnExtensionComposition.test.ets`

- [ ] **Step 1: Write failing extension-writer tests**

Inject a `VpnRuntimeBridgeWriterPort` and record calls. Cover:

- one accepted start claims exactly once using only request identity;
- claim occurs before asynchronous coordinator work and gives the composition its writer generation;
- the extension owns an extension-local `VpnSessionRegistry` and `VpnProxyCommandBus` when tests/production do not inject them;
- coordinator `STARTING`, `RUNNING`, `RECOVERING`, `STOPPING`, `STOPPED`, and `ERROR` events publish matching bridge states;
- `RUNNING` is published only inside the coordinator subscription after the coordinator has already completed proxy activation and notification startup; no TUN event callback writes the bridge;
- every publish includes the current generation and exact current request identity;
- only sanitized `failure.code` crosses the port; detail is never forwarded;
- a stale publish returning `false` is ignored and cannot mutate a newer session;
- failed setup before coordinator creation publishes safe `ERROR` if still owned;
- stop/destroy publishes terminal state, disposes resources, and calls owner-aware clear exactly once;
- an old instance's late terminal publish/clear returning `false` does not affect the newer writer;
- malformed/rejected starts never claim ownership.

- [ ] **Step 2: Run entry tests and verify RED**

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: failures because the bridge writer is not a dependency and extension production still expects an externally shared command bus.

- [ ] **Step 3: Implement minimal writer ownership**

Add dependencies:

```ts
runtimeBridge?: VpnRuntimeBridgeWriterPort;
```

The production constructor defaults to `new NativeVpnRuntimeBridge()`, a private registry, and a private command bus. Store a writer generation only for the current accepted request. Publish through one helper that reconstructs the bridge snapshot from `currentRequest` plus coordinator state and sanitized failure code.

Do not publish from `TunRuntimeEvent`; retain that subscription only for packet diagnostics/evidence. Clear the writer token only after owner-aware terminal cleanup. Never log bridge identity or generation.

- [ ] **Step 4: Run entry GREEN**

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: all extension lifecycle tests pass.

- [ ] **Step 5: Verification checkpoint**

```bash
rg -n "recordTunEvent|publishIfOwned|claim\(" harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets
git diff --check
```

Manually confirm no TUN callback contains a bridge write and no log contains private bridge values. Do not commit.

### Task 5: Gate UI `RUNNING` on a matching bridge snapshot and successful mirror bind

**Files:**
- Modify: `harmony/shared/src/main/ets/vpn/VpnPorts.ets`
- Modify: `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnSessionRegistry.ets`
- Modify: `harmony/entry/src/test/HarmonyVpnController.test.ets`
- Modify: `harmony/entry/src/test/VpnSessionRegistry.test.ets`

- [ ] **Step 1: Write failing controller and registry tests**

Add optional initialization to the shared controller contract:

```ts
initializeRuntimeMirror?(): Promise<void>;
```

Inject into `HarmonyVpnController`:

```ts
bridge: VpnRuntimeBridgeReaderPort;
mirror: VpnProxyRuntimeMirrorPort;
scheduler: BoundedDelaySchedulerPort;
```

Use a manual scheduler and deferred bridge/mirror fakes to prove:

- after system start acceptance the controller begins one session-scoped bounded poll;
- `EMPTY` and identity-mismatched snapshots are ignored without binding/publishing;
- a matching transitional snapshot updates only the matching registry session;
- matching `RUNNING` awaits `mirror.bindExistingSession(request)` before registry `RUNNING`;
- observing `RUNNING` while bind is pending does not publish `RUNNING`;
- bind rejection publishes only safe `VPN_PROXY_REPLAY_FAILED` and never `RUNNING`;
- matching `ERROR` first deactivates the mirror, then publishes its allowlisted safe failure;
- matching `STOPPED` first deactivates the mirror, then completes the registry stop;
- stop cancels the current poll before issuing platform stop and clears the UI mirror;
- async `dispose()` cancels polling and clears only the mirror; it neither stops the extension nor clears the native bridge;
- a newer start token, stop, dispose, or completed terminal state invalidates late scheduled/deferred results;
- every scheduled task is cancelled at most once, polling has a fixed attempt bound, and no callback continues after the bound;
- no bridge identity appears in thrown errors or logs.

Registry tests add only the minimal reconstruction helpers:

- valid bridge identity can hydrate `STARTING`, `RECOVERING`, `STOPPING`, or bind-gated `RUNNING` from an initially stopped registry;
- malformed bridge data can publish sanitized controller `ERROR` with `activeRequest=null`;
- an error-without-request does not block a later normal `beginPending`;
- hydration cannot overwrite an unrelated live request.

- [ ] **Step 2: Run entry/shared tests and verify RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: controller constructor/port/hydration compile or assertion failures.

- [ ] **Step 3: Implement bounded session polling**

Use fixed private constants and one cancelable token, for example:

```ts
const BRIDGE_POLL_INTERVAL_MS: number = 100;
const BRIDGE_POLL_MAX_ATTEMPTS: number = 120;

interface RuntimeMirrorPoll {
  token: number;
  request: VpnStartRequest;
  attemptsRemaining: number;
  task?: CancelableDelayTask;
}
```

Every start/stop/dispose increments the token. Each callback checks token plus exact request identity both before and after every `await`. Schedule at most one next task. Exhaustion leaves the registry non-running so the existing 15-second one-click confirmation maps the outcome to its safe timeout.

For matching `RUNNING`, use this exact order:

```ts
await mirror.bindExistingSession(request);
checkTokenAndIdentity();
registry publishes RUNNING;
cancel current poll;
```

For terminal states, deactivate before publishing. Reuse fixed `createVpnFailure` details; never pass native or caught error text.

- [ ] **Step 4: Implement initialization hydration**

`initializeRuntimeMirror()` reads once synchronously:

- `EMPTY`/`STOPPED`: keep stopped and return;
- valid `RUNNING`: bind mirror, recheck token, hydrate registry to `RUNNING`, then return;
- valid transitional state: hydrate that state, schedule bounded continuation, then return;
- valid `ERROR`: publish sanitized error and return;
- malformed/unsupported snapshot or bind failure: publish safe `VPN_PROXY_REPLAY_FAILED` error and return.

The method must never reject application initialization for runtime hydration failure. It may reject only programming misuse caught by tests; production data failures become registry `ERROR`.

- [ ] **Step 5: Run controller/registry GREEN**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: all cancellation, ordering, identity, timeout, and hydration tests pass.

- [ ] **Step 6: Verification checkpoint**

Run `git diff --check`. Search for and reject any raw bridge/caught-error logging. Do not commit.

### Task 6: Wire the UI mirror before application `READY` and remove production static handoff

**Files:**
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets`
- Modify: `harmony/entry/src/test/VpnExtensionComposition.test.ets`
- Modify: `harmony/tests/structure/phase4-vpn-contract.test.mjs`

- [ ] **Step 1: Write failing composition tests**

Cover exact initialization and ownership behavior:

- default composition builds one UI `VpnProxyRuntimeHandler` with the UI graph repositories/hasher/core adapter/clock and the same UI `VpnProxyCommandBus` used by `ProxyService`;
- default controller receives `NativeVpnRuntimeBridge`, that mirror, and `TimeoutDelayScheduler`;
- `initializeRuntimeMirror()` resolves before `ProfileApplication` construction/initialization and before `READY` publication;
- a recreated application with bridge `RUNNING` is already registry `RUNNING` and command-bus query-capable when its first `READY` state is observed;
- hydration failure still yields application `READY` plus registry `ERROR`;
- a custom test controller without the optional method remains compatible and is not awaited;
- `closeResources()` awaits async controller disposal and does not stop or clear the extension-owned native snapshot;
- production initialization no longer installs UI registry/command bus through `installedVpnExtensionOwner`, `resolveInstalledVpnExtensionRegistry`, or `resolveInstalledVpnExtensionCommandBus`;
- extension construction remains self-contained when its ArkTS module statics are isolated.

Add a focused regression guard to `phase4-vpn-contract.test.mjs` that reads `ProxyService.ets` and requires no `libentry.so` import, no `NativeVpnRuntimeBridge` import, and no second running query/select branch. This guard is expected to be GREEN before and after the wiring change; it prevents Chunk 2 implementation from introducing the spec-rejected direct-native fallback.

- [ ] **Step 2: Run entry tests and verify RED**

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: ordering/ownership tests fail against current production wiring.

- [ ] **Step 3: Wire the graph-backed mirror**

Change default controller creation to receive the already-created `PlatformGraph`, `CoreService`, registry, and UI command bus. Construct:

```ts
const mirror = new VpnProxyRuntimeHandler(
  graph.repository,
  graph.proxySelectionRepository,
  graph.proxyIdentityHasher,
  new CoreProxyServiceAdapter(coreService),
  graph.clock,
  commandBus
);
const controller = new HarmonyVpnController(
  registry,
  api,
  new NativeVpnRuntimeBridge(),
  mirror,
  new TimeoutDelayScheduler()
);
```

Immediately after creating the default/custom controller and before constructing `ProfileApplication`, run:

```ts
await vpnController.initializeRuntimeMirror?.();
```

Await concrete `HarmonyVpnController.dispose()` during close.

- [ ] **Step 4: Delete the production static owner bridge**

Remove `InstalledVpnExtensionOwner`, its token counter, install/clear/resolve helpers, and production factory wiring that passes UI registry/command bus to the extension. Keep only explicit test injection seams that do not claim cross-Ability sharing. The extension defaults from Task 4 provide its own local registry/command bus; the UI gets runtime truth only from the native bridge.

- [ ] **Step 5: Run entry and focused structure GREEN**

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
cd ..
node --test harmony/tests/structure/phase4-vpn-contract.test.mjs
```

Expected: entry tests and existing VPN structure contracts pass.

- [ ] **Step 6: Verification checkpoint**

```bash
rg -n "InstalledVpnExtensionOwner|installedVpnExtensionOwner|installVpnExtensionOwner|clearInstalledVpnExtensionOwner|resolveInstalledVpnExtension" \
  harmony/entry/src/main/ets || true
git diff --check
```

Expected: the static owner search has no production matches. Do not commit.

---

## Chunk 3: Privacy Contracts, Full Gates, Signed HAP, and Physical Proof

### Task 7: Lock cross-layer, privacy, and physical-proof contracts

**Files:**
- Create: `harmony/tests/structure/vpn-runtime-bridge-contract.test.mjs`
- Create: `docs/harmony/vpn-runtime-bridge.md`
- Modify: `harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs`
- Modify: `harmony/tests/bin/run-proxy-one-click-vpn-device-proof.mjs`
- Modify: `harmony/tests/fixtures/proxy-one-click-vpn-device-proof.schema.json`
- Modify: `harmony/tests/fixtures/proxy-one-click-vpn-device-proof.example.json`
- Modify: `docs/harmony/proxy-one-click-vpn-device-proof.md`

- [ ] **Step 1: Write failing structure/privacy contracts**

The dedicated bridge contract must prove:

- the native store is process-static, mutex-protected, value-copying, and absent from all env/addon cleanup hooks;
- the four bridge names exist only in entry addon/NAPI/types/private adapter code and not public core ABI/header/service exports;
- exact six-key snapshot and three-key identity codecs exist in native and ArkTS;
- extension is the only production caller of claim/publish/clear; UI code calls read only;
- extension bridge writes are downstream of coordinator events and absent from TUN event callbacks;
- `bindExistingSession()` contains no selection list/replay/mutation path;
- UI registry `RUNNING` publication is syntactically downstream of awaited mirror bind;
- composition awaits initialization before `READY`;
- production static extension-owner symbols are gone;
- `ProxyService.ets` has no `libentry.so` import and no direct-native/fallback branch;
- bridge identities/failure details are absent from hilog, public result models, semantic IDs, proof JSON, fixtures, and docs;
- signing profile remains the empty baseline.

- [ ] **Step 2: Extend the proof shape with a fixed recreation result**

Add only this aggregate field:

```json
"recreationState": "RESTORED_RUNNING_SELECTED"
```

Allowed values are exactly `RESTORED_RUNNING_SELECTED` and `NOT_PROVEN`. Do not add session IDs, profile IDs, version IDs, node labels, URLs, endpoints, durations tied to identities, raw errors, or layouts.

Update `proofPassesContract` to require recreation success. The runner must:

1. reach the already-proven running state;
2. recreate/foreground the application without stopping VPN;
3. reopen the same proxy UI through semantic actions;
4. prove exactly one runtime-selected row is visible;
5. hot-switch once after recreation and prove the selected marker moves;
6. encode only the fixed aggregate enum;
7. retain existing bundle force-stop, remote journal deletion, writer close, and local/remote temporary-root cleanup in `finally`.

- [ ] **Step 3: Run focused tests and verify RED**

```bash
node --test harmony/tests/structure/vpn-runtime-bridge-contract.test.mjs
node --test harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs
```

Expected: new bridge and recreation contracts fail until all production/runner/schema updates exist.

- [ ] **Step 4: Implement the minimal contracts, runner update, and docs**

Keep docs implementation-focused: platform VPN type process routing, mandatory packaged/physical same-PID verification, extension-only writer, bind-only UI mirror, AppService rejection note, fixed failure behavior, and exact verification commands. Do not copy private sample values into documentation.

- [ ] **Step 5: Run focused and full structure GREEN**

```bash
node --test harmony/tests/structure/vpn-runtime-bridge-contract.test.mjs
node --test harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs
node --test harmony/tests/structure/*.test.mjs
node --check harmony/tests/bin/run-proxy-one-click-vpn-device-proof.mjs
```

Expected: every structure test passes and the runner parses.

- [ ] **Step 6: Verification checkpoint**

```bash
git diff --check
```

Do not commit.

### Task 8: Run complete regression gates

**Files:**
- Modify only files already owned by Tasks 1-7 when a genuine regression requires a fix.

- [ ] **Step 1: Run Go and every native host gate**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go test ./... -count=1
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go test -race ./internal/proxygroups -run 'TestDelayJob' -count=1
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go vet ./...
cd "$CMFA_REPO_ROOT"
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case tun-contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/test-native-host.mjs --case napi-proxy
node harmony/tools/test-native-host.mjs --case napi-tun
node harmony/tools/test-native-host.mjs --case vpn-runtime-bridge-store
node harmony/tools/test-native-host.mjs --case napi-vpn-runtime-bridge
```

- [ ] **Step 2: Run every structure and ArkTS gate**

```bash
node --test harmony/tests/structure/*.test.mjs
cd harmony
./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

- [ ] **Step 3: Fix only real regressions and repeat the failed gate**

Do not perform warning-only cleanup, broad refactors, dependency changes, or Android edits.

- [ ] **Step 4: Verification checkpoint**

Re-run every affected gate and `git diff --check`. Do not commit.

### Task 9: Build, inspect, prove on the physical device, and restore signing isolation

**Files/Artifacts:**
- Generate: `harmony/artifacts/phase1-native-provenance.json`
- Generate: `harmony/entry/build/default/outputs/default/entry-default-signed.hap`
- Generate: `harmony/artifacts/proxy-one-click-vpn-device-proof.json`
- Generate: `harmony/artifacts/proxy-delay-device-proof.json`

- [ ] **Step 1: Open the existing bounded signing window**

Use the already captured ignored backup `.codex-secure/harmony-build-profile.signed.json5` without printing it.

1. Verify `.codex-secure` mode is `0700`, the backup mode is `0600`, and the tracked profile currently contains exact `"signingConfigs": []`.
2. Validate privately that the backup differs only by one complete `app.signingConfigs` block and every referenced signing file exists. Do not print paths, aliases, passwords, certificates, or identities.
3. Capture baseline bytes plus SHA-256 privately.
4. Inject only the validated signing block inside a `try/finally` window.
5. In `finally`, restore the exact baseline bytes/hash even if build, install, proof, or review fails.

- [ ] **Step 2: Clean and build a fresh signed production HAP**

Inside the signing window:

```bash
cd harmony
./hvigorw clean
cd ..
node harmony/tests/bin/build-phase1-native.mjs --out harmony/artifacts/phase1-native-provenance.json
node harmony/tests/bin/build-phase1-native.mjs --validate harmony/artifacts/phase1-native-provenance.json
node harmony/tests/bin/inspect-hap.mjs \
  --hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --manifest harmony/artifacts/phase1-native-provenance.json \
  --build-kind production
```

Require a new HAP mtime and SHA-256 after the bridge sources, all production native libraries present, production self-test hooks absent, and signature inspection successful.

- [ ] **Step 3: Run bridge-aware one-click physical proof**

```bash
node harmony/tests/bin/run-proxy-one-click-vpn-device-proof.mjs \
  --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --out harmony/artifacts/proxy-one-click-vpn-device-proof.json
```

Require:

- `result: pass`;
- `stoppedToVpnState: RUNNING_SELECTED`;
- `localToVpnState: LOCAL_STOPPED_VPN_RUNNING_SELECTED`;
- `runningSwitchState: HOT_SWITCHED_SAME_SESSION`;
- `recreationState: RESTORED_RUNNING_SELECTED`;
- `cleanupState: CLEAN`;
- no private identity, label, URL, endpoint, credential, raw error, journal content, or layout content in the proof.

- [ ] **Step 4: Run the existing delay proof against the same HAP**

```bash
node harmony/tests/bin/run-proxy-delay-device-proof.mjs \
  --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --out harmony/artifacts/proxy-delay-device-proof.json
```

Require schema-valid `result: pass`, successful cancellation/drain, VPN quiet-window behavior, and cleanup.

- [ ] **Step 5: Verify final artifact digest consistency without source hash churn**

Require `packageSha256` in both generated proof documents to equal the fresh HAP SHA-256. Keep `harmony/tests/fixtures/proxy-one-click-vpn-device-proof.example.json` as the canonical `incomplete` example with its zero hash; do not turn source fixtures or docs into release-specific artifacts.

Run:

```bash
node --test harmony/tests/structure/vpn-runtime-bridge-contract.test.mjs
node --test harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs
node --test harmony/tests/structure/proxy-delay-device-proof-contract.test.mjs
```

- [ ] **Step 6: Restore and prove signing isolation**

In the unconditional `finally`, restore the original baseline and require:

```bash
git diff --exit-code -- harmony/build-profile.json5
node --test harmony/tests/structure/signing-isolation.test.mjs
```

The final file must contain exact `"signingConfigs": []`. Keep the secure ignored backup at its existing permissions; do not alter the user's DevEco credential store.

- [ ] **Step 7: Run final full verification**

1. Re-run all Task 8 gates against the final source and generated proof artifacts.
2. Validate both physical proof JSON files against their strict schemas and require `pass`.
3. Prove remote cleanup:

   ```bash
   hdc shell -b com.github.kr328.clash.harmony \
     sh -c 'test ! -e /data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json'
   ```

4. Require no recent `/tmp/proxy-one-click-vpn-layout-*`, `/tmp/proxy-one-click-vpn-runtime-*`, `/tmp/proxy-delay-layout-*`, or `/tmp/proxy-delay-runtime-*` directories.
5. Scan source while excluding generated caches:

   ```bash
   rg -n \
     --glob '!harmony/artifacts/go-mod-cache/**' \
     --glob '!harmony/**/.test/**' \
     'DEBUG-|CMFADelay|CMFA_SAFE_.*STAGE|reportSafe.*Stage' \
     harmony/entry/src harmony/shared/src harmony/tests/bin
   ```

   Expected: no matches.
6. Run `git diff --check`, signing isolation, and the exact `build-profile.json5` diff check once more.
7. Confirm no commit and no push were created.

- [ ] **Step 8: Independent completion reviews**

After implementation is green:

1. dispatch a spec-compliance reviewer for the whole bridge against the approved design;
2. resolve every issue and re-review until approved;
3. dispatch a separate code-quality/privacy reviewer only after spec approval;
4. resolve every Important/Critical issue and re-review until approved;
5. report both approval verdicts with the final HAP SHA-256 and proof outcomes; do not persist private review context in repository artifacts.

Do not commit or push.
