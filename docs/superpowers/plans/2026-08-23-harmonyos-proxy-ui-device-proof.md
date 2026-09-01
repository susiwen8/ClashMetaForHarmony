# HarmonyOS Proxy UI and Device Proof Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the active mihomo runtime's proxy groups and ordered nodes in native ArkUI, apply generation-bound terminal selections truthfully, and prove one selected node carries a real HTTPS request through HarmonyOS VPN/TUN on a physical phone.

**Architecture:** `entry` adds a package-local presentation model, `ProxyViewModel`, and `ProxiesPage` over the already-approved `ProfileApplication.listGroups/queryGroup/select` authority. `Index` owns route and ViewModel lifetime, while `HomePage` only exposes a guarded navigation entry. The existing TUN trace gains a bounded SHA-256-only view of the actual live mihomo outbound chain so the controlled HTTPS flow can be matched to the terminal member selected in ArkUI without exposing its label. Device evidence reuses the existing signed packages, HDC, UI semantic IDs, VPN lifecycle evidence, and traffic probe; any layout containing private labels is parsed only in a temporary directory and reduced to counts, booleans, result kinds, and hashes before persistence.

**Tech Stack:** HarmonyOS 6.x, ArkTS strict mode, ArkUI, Hypium, Node test runner, HDC UI Test, existing Phase 4 VPN/TUN traffic probe.

**Standing constraints:** Do not add dependencies. Do not commit or push unless the user separately requests it. Do not log, serialize into proofs, or report raw profile IDs, proxy group names, node names, endpoints, subscription content, configuration paths, device identifiers, or signing material.

---

## Chunk 0: Actual Outbound Correlation

### Task 0A: Capture the live mihomo outbound chain in the existing TUN trace

**Files:**
- Modify: `harmony/core/go/internal/runtime/snapshot.go`
- Modify: `harmony/core/go/internal/runtime/tun_trace.go`
- Modify: `harmony/core/go/internal/runtime/tun_trace_test.go`
- Modify: `harmony/core/go/upstream.api-lock.json` only if the pinned tracker API lock requires an explicit ownership note

- [ ] **Step 1: Write failing Go timing and privacy tests**

Cover TCP first-read capture while a unique matching live tracker exists, TCP no-read fallback, UDP capture after delegate registration, zero tracker match, multiple tracker matches, empty chain, oversized chain, deterministic terminal/whole-chain hashes, cloned trace snapshots, and absence of raw chain values in traces/events/errors.

Use an injected narrow tracker-range seam in tests; do not race the real global manager in unit tests. Lock the mihomo semantics that `TrackerInfo.Chain[0]` is the terminal outbound member and that the chain snapshot is obtained only from the live tracker.

- [ ] **Step 2: Run Go tests and verify RED**

Run:

```bash
cd harmony/core/go
GOPROXY=off go test ./internal/runtime -count=1
```

Expected: missing outbound proof fields and live-tracker observer.

- [ ] **Step 3: Implement the bounded trace evidence**

Extend `TunTrace` with only:

```go
DestinationHash      string
OutboundTerminalHash string
OutboundChainHash    string
OutboundChainLength  uint32
```

Use lowercase SHA-256 over UTF-8. `DestinationHash` is `sha256(protocol + "|" + canonicalDestinationIP + "|" + decimalDestinationPort)`. `OutboundTerminalHash` is `sha256(chain[0])`; `OutboundChainHash` is `sha256(strings.Join(chain, "\x1f"))`; length is the exact bounded chain length. Accept at most 16 non-empty chain elements of at most 256 UTF-8 bytes each. An invalid destination leaves `DestinationHash` empty. Any invalid, empty, zero-match, or multi-match chain observation leaves all three outbound proof fields empty/zero.

For TCP, create the trace once from `tapConn.Read` when the first payload bytes arrive, because mihomo has already created and joined the outbound tracker before relay. Use `sync.Once`; if no read occurs, append one fallback trace after the delegate returns without outbound proof. For UDP, capture the payload marker first, invoke the delegate so the tracker is registered, then append the trace. Match a tracker only when the injected range returns exactly one live tracker with the same metadata identity and canonical tuple. Never copy `Chain`, rule, payload, address, or tracker ID into a public value.

- [ ] **Step 4: Run Go tests and verify GREEN**

Run `go test ./internal/runtime -count=1` twice, then full offline Go tests and diff-check Task 0A files.

### Task 0B: Carry hashed outbound proof through ABI, ArkTS, journal, and Phase 4 proof

**Files:**
- Modify: `harmony/core/abi/include/cmfa_types.h`
- Modify: `harmony/core/abi/src/cmfa_contract.cpp`
- Modify: `harmony/core/go/cmd/cmfa_core/main.go`
- Modify: `harmony/core/go/cmd/cmfa_core/tun_exports_test.go`
- Modify: `harmony/entry/src/main/cpp/include/cmfa_napi.h`
- Modify: `harmony/entry/src/main/cpp/src/js_async.cpp`
- Modify: `harmony/entry/src/main/cpp/src/js_codec.cpp`
- Modify: `harmony/tests/native/js_tun_napi_test.cpp`
- Modify: `harmony/entry/src/main/cpp/types/libentry/Index.d.ts`
- Modify: `harmony/core/src/main/ets/CoreNativeAdapter.ets`
- Modify: `harmony/core/src/main/ets/CoreTunRuntime.ets`
- Modify: `harmony/core/src/test/CoreTunRuntime.test.ets`
- Modify: `harmony/shared/src/main/ets/vpn/VpnModels.ets`
- Modify: `harmony/shared/src/test/VpnModels.test.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnEvidenceJournal.ets`
- Modify: `harmony/entry/src/test/VpnEvidenceJournal.test.ets`
- Modify: `harmony/tests/bin/run-phase4-device-proof.mjs`
- Modify: `harmony/tests/fixtures/phase4-device-proof.schema.json`
- Modify: `harmony/tests/structure/phase4-runner-contract.test.mjs`
- Modify: `harmony/tests/structure/phase4-proof-schema.test.mjs`

- [ ] **Step 1: Write failing ABI/codec/journal/proof tests**

Require exact 64-character lowercase hashes or the all-empty/all-zero fail-closed state; reject partial outbound fields, invalid hash text, nonzero length without hashes, zero length with hashes, unknown JS fields, and unbounded numeric values. Require linked TCP pass evidence to carry a non-empty destination hash, outbound terminal hash, whole-chain hash, and positive chain length. Confirm journal and proof never contain raw group/member/chain strings or a raw destination.

- [ ] **Step 2: Run native/core/shared/entry/structure tests and verify RED**

Run the focused C ABI host case, NAPI TUN case, core/shared/entry Hypium, Phase 4 runner contract, and Phase 4 proof schema. Expected: outbound fields are missing.

- [ ] **Step 3: Extend the fixed transport surface**

Append three fixed hash buffers and one `uint32_t` length to `cmfa_tun_trace`; zero and validate them in every success/failure path. Copy them into `OwnedTunTrace`, NAPI objects, `InternalTunNativeTrace`, `VpnIngressTrace`, and `VpnEvidenceObservationRecord`. Clone arrays/records at every ArkTS boundary. No new event channel or dependency is introduced.

The Phase 4 runner correlates the existing controlled TCP record by `correlationHash`, carries the three outbound proof fields into its strict proof, and requires them for a passing linked TCP/TUN flow. It does not attempt to interpret or reverse the hashes.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run every Step 2 command twice where deterministic, then the complete Task 4 host gate. No prior Phase 4 evidence assertion may be weakened.

---

## Chunk 1: Truthful Presentation State

### Task 1: Add immutable proxy presentation models

**Files:**
- Create: `harmony/entry/src/main/ets/presentation/ProxyPresentationModels.ets`
- Create: `harmony/entry/src/test/ProxyPresentationModels.test.ets`
- Modify: `harmony/entry/src/test/List.test.ets`

- [ ] **Step 1: Write failing model tests**

Cover deep cloning, ordered groups and nodes, stable index-based semantic IDs, exactly one runtime-confirmed checkmark, a separate saved-intent marker, warning state, empty/error state, and rejection of malformed generation or index values. Mutating input or returned arrays must not mutate the authority.

- [ ] **Step 2: Run entry Hypium and verify RED**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: compile failure because `ProxyPresentationModels.ets` and its exports do not exist.

- [ ] **Step 3: Implement the exact presentation shapes**

Define focused entry-only shapes:

```ts
export type ProxyViewStatus = 'IDLE' | 'LOADING' | 'READY' | 'EMPTY' | 'ERROR';
export type ProxyPersistenceWarning = 'NONE' | 'SAVED_FOR_NEXT_START' | 'APPLIED_NOT_PERSISTED';

export interface ProxyGroupTabState {
  semanticId: string;       // proxies.group.<ordered index>
  index: number;
  name: string;
  type: string;
  active: boolean;
}

export interface ProxyNodeRowState {
  semanticId: string;       // proxies.node.<ordered index>
  index: number;
  name: string;
  type: string;
  isGroup: boolean;
  runtimeSelected: boolean;
  savedForNextStart: boolean;
}

export interface ProxyViewState {
  status: ProxyViewStatus;
  groups: ProxyGroupTabState[];
  nodes: ProxyNodeRowState[];
  groupGeneration?: number;
  selectionPending: boolean;
  warning: ProxyPersistenceWarning;
  errorCode?: ProxyRejectedErrorCode;
  errorRetryable: boolean;
}
```

Construct semantic IDs only from bounded array indexes. Raw group/node labels remain user-visible in-memory fields but never enter semantic IDs, logs, errors, or evidence. Clone every returned state.

- [ ] **Step 4: Run entry Hypium and verify GREEN**

Run entry Hypium twice and `git diff --check` for the Task 1 files.

### Task 2: Implement `ProxyViewModel` with stale-result suppression

**Files:**
- Create: `harmony/entry/src/main/ets/presentation/ProxyViewModel.ets`
- Create: `harmony/entry/src/test/ProxyViewModel.test.ets`
- Modify: `harmony/entry/src/test/fakes/PresentationFakes.ets`
- Modify: `harmony/entry/src/test/List.test.ets`

- [ ] **Step 1: Write failing behavior tests**

Cover:

- initial list followed by the first ordered group query;
- empty list, every closed proxy rejection code, and retry;
- a bounded operation deadline clears loading and maps to a retryable query failure without echoing labels;
- group switching and nested-group navigation;
- an older in-flight group result never replacing a later choice;
- terminal selection forwarding the exact group/member/generation;
- duplicate taps ignored while a selection is pending;
- `APPLIED_NOW` replaces the current group with its confirmed snapshot;
- `SAVED_FOR_NEXT_START` preserves the prior runtime checkmark and marks only the saved row;
- `APPLIED_NOT_PERSISTED` uses the confirmed runtime snapshot and publishes the restart-persistence warning;
- `REJECTED` preserves the previous snapshot and exposes only code/retryability;
- `dispose()` suppresses later publications and clears listeners;
- no logs, serialized state, or errors echo private labels.

- [ ] **Step 2: Run entry Hypium and verify RED**

Expected: missing `ProxyViewModel` behavior.

- [ ] **Step 3: Implement serialized public methods**

Expose:

```ts
load(): Promise<void>;
openGroup(groupIndex: number): Promise<void>;
activateNode(nodeIndex: number): Promise<void>;
retry(): Promise<void>;
current(): ProxyViewState;
subscribe(listener: ProxyViewListener): number;
unsubscribe(id: number): void;
dispose(): void;
```

Use `ProxyApplicationPort`, not concrete platform/core classes. `load()` calls `listGroups()` then queries the first returned group. `openGroup()` resolves the raw label from the current immutable tab state. `activateNode()` resolves the row by index; group rows call the same group query path, terminal rows call `select()` with the current snapshot generation.

Use a monotonic request epoch so only the newest list/group query may publish. Keep one selection-pending guard. Never optimistically move the runtime checkmark. Preserve group/member order exactly as returned by Plan C.

Inject a narrow `ProxyViewDeadlinePort.run<T>(operation)` seam. The production implementation races each list/group operation against a fixed 15-second deadline and clears its timer in `finally`; tests inject an immediate deterministic deadline. Deadline expiry publishes only `PROXY_QUERY_FAILED` with retryability and never copies an exception message.

- [ ] **Step 4: Run entry tests and verify GREEN**

Run entry Hypium twice and diff-check Task 2 files.

---

## Chunk 2: Native ArkUI and Navigation

### Task 3: Add the guarded Home entry and `ProxiesPage`

**Files:**
- Create: `harmony/entry/src/main/ets/pages/ProxiesPage.ets`
- Modify: `harmony/entry/src/main/ets/pages/HomePage.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Modify: `harmony/entry/src/main/resources/base/element/color.json` only if an existing semantic color cannot express the saved warning
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`

- [ ] **Step 1: Write failing composition and source contract tests**

Pin:

- route union includes `PROXIES`;
- `Index` constructs one `ProxyViewModel` from the shared `ProfileApplication`, subscribes before reading state, calls `load()` whenever the route opens, and disposes it with other view models;
- Home entry ID is exactly `home.proxy.manage`;
- page IDs include `proxies.back`, `proxies.retry`, `proxies.group.<index>`, and `proxies.node.<index>`;
- selected/saved marker IDs are exactly `proxies.node.<index>.runtime-selected` and `proxies.node.<index>.saved-intent`;
- entry enablement requires application `READY` plus an active `VALID` or `UPDATE_FAILED_USING_VALID` profile;
- all visible static copy is resource-backed;
- no semantic ID, log, error, or warning includes a raw group/node label.

Pin this exact resource allowlist:

```text
home_proxy_manage
home_proxy_manage_disabled
proxies_title
proxies_back
proxies_loading
proxies_empty
proxies_retry
proxies_selected
proxies_saved_for_next_start
proxies_applied_not_persisted
proxies_nested_group
proxies_error_profile_unavailable
proxies_error_runtime_not_ready
proxies_error_query_failed
proxies_error_selection_stale
proxies_error_selection_failed
proxies_error_persistence_failed
proxies_error_session_changed
```

Map the seven closed errors exactly: `PROXY_PROFILE_UNAVAILABLE` to
`proxies_error_profile_unavailable`, `PROXY_RUNTIME_NOT_READY` to
`proxies_error_runtime_not_ready`, `PROXY_QUERY_FAILED` to
`proxies_error_query_failed`, `PROXY_SELECTION_STALE` to
`proxies_error_selection_stale`, `PROXY_SELECTION_FAILED` to
`proxies_error_selection_failed`, `PROXY_PERSISTENCE_FAILED` to
`proxies_error_persistence_failed`, and `VPN_SESSION_CHANGED` to
`proxies_error_session_changed`.

- [ ] **Step 2: Run entry and focused structure tests and verify RED**

Run entry Hypium plus `phase3-ui-contract.test.mjs`. Expected: missing page, route, resources, and semantic IDs.

- [ ] **Step 3: Implement route ownership in `Index`**

Add `PROXIES` to `AppRoute`, state/subscription fields for `ProxyViewModel`, and `openProxiesRoute()`. Create the ViewModel beside other presentation owners when the application becomes ready. Render `ProxiesPage` with back/retry/group/node callbacks. Back returns to `HOME` without destroying the marker state; reopening calls `load()` so a VPN start/recovery is reflected by a fresh runtime snapshot.

- [ ] **Step 4: Implement the Home entry**

Add a full-width resource-backed card or row after the active-profile card. The row always exists for stable automation. It is enabled only for a ready valid active profile, shows the disabled explanation otherwise, and invokes only `onManageProxies`.

- [ ] **Step 5: Implement `ProxiesPage`**

Use:

- a top app bar with `proxies.back`;
- a horizontal group selector preserving runtime order;
- a vertical ordered node list;
- resource-backed selected marker and saved-intent marker;
- a navigation affordance for nested group rows;
- a visible `APPLIED_NOT_PERSISTED` warning;
- loading, empty, typed error, and retry states;
- 48vp minimum interactive targets, safe-area padding, semantic colors, compact layout support, and hidden scroll bars.

Duplicate taps remain disabled while `selectionPending`. The runtime checkmark renders only `runtimeSelected`; `savedForNextStart` has distinct copy and color.

- [ ] **Step 6: Run entry and structure tests and verify GREEN**

Run entry Hypium twice, focused UI structure tests, `entry@ohosTest assembleHap`, and diff-check Task 3 files.

---

## Chunk 3: Privacy and Device Evidence

### Task 4: Lock Plan D UI privacy and automation contracts

**Files:**
- Create: `harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs`
- Modify: `harmony/tests/structure/phase3-ui-contract.test.mjs`
- Modify: `harmony/entry/src/ohosTest/ets/test/Phase3UiFlow.test.ets`
- Modify: `harmony/entry/src/ohosTest/ets/test/List.test.ets` only if a new suite is required

- [ ] **Step 1: Write failing Plan D structure tests**

Require exact page/ViewModel/model ownership, resource keys, route lifecycle, stable index-only semantic IDs, closed result handling, stale-request suppression, duplicate-tap guard, selected versus saved marker separation, nested navigation, and all loading/empty/error/warning states.

Scan production UI and presentation code for endpoint/credential fields, raw-label interpolation into IDs/logs/errors, `JSON.stringify` of proxy state, literal package/signing paths, and unbounded public arrays. The scanner may allow raw labels only in the private in-memory `name` fields rendered directly as Text.

Implement the scanner as fixed source contracts: forbid `${groupName}`, `${memberName}`, `${node.name}`, and `${group.name}` inside `.id`, `hilog`, `console`, `new Error`, or proof object literals; forbid `JSON.stringify` whose direct expression contains `ProxyViewState`, `ProxyGroup`, or `ProxySelection`; allow `Text(group.name)` and `Text(node.name)` only in `ProxiesPage.ets`; require every public array to be created through the presentation clone constructors.

- [ ] **Step 2: Run focused contracts and verify RED then GREEN**

Run:

```bash
node --test \
  harmony/tests/structure/plan-c-proxy-selection-contract.test.mjs \
  harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs \
  harmony/tests/structure/plan-d-device-proof-contract.test.mjs \
  harmony/tests/structure/phase3-ui-contract.test.mjs \
  harmony/tests/structure/phase4-vpn-contract.test.mjs
```

Update the existing UI flow only with stable page existence/back-navigation checks that do not require a real profile. Real node counts and selection are a production-package physical-device gate, not a synthetic ohosTest claim.

- [ ] **Step 3: Run complete Plan D host gate**

Run the exact complete gate below. No new test failure is allowed.

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go test ./... -count=1

cd "$CMFA_REPO_ROOT"
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/test-native-host.mjs --case napi-tun
node harmony/tools/test-native-host.mjs --case napi-proxy
node --test \
  harmony/tests/structure/plan-b-proxy-contract.test.mjs \
  harmony/tests/structure/plan-c-rdb-contract.test.mjs \
  harmony/tests/structure/plan-c-proxy-selection-contract.test.mjs \
  harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs \
  harmony/tests/structure/plan-d-device-proof-contract.test.mjs \
  harmony/tests/structure/phase3-layer-boundary.test.mjs \
  harmony/tests/structure/phase3-ui-contract.test.mjs \
  harmony/tests/structure/phase4-vpn-contract.test.mjs \
  harmony/tests/structure/phase4-package-contract.test.mjs \
  harmony/tests/structure/signing-isolation.test.mjs

cd "$CMFA_REPO_ROOT/harmony"
./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap

cd "$CMFA_REPO_ROOT"
node harmony/tests/bin/build-phase1-native.mjs --validate harmony/artifacts/phase1-native-provenance.json
```

`plan-d-device-proof-contract.test.mjs` must validate the runner source, the strict schema, the incomplete example, and a synthetic generated proof. After physical execution it validates `harmony/artifacts/plan-d-device-proof.json` against the same schema without weakening required pass-only correlations.

### Task 5: Build, install, and collect a privacy-safe physical-device proof

**Files:**
- Create: `docs/harmony/proxy-ui-device-proof.md`
- Create: `harmony/tests/bin/run-plan-d-device-proof.mjs`
- Create: `harmony/tests/fixtures/plan-d-device-proof.schema.json`
- Create: `harmony/tests/fixtures/plan-d-device-proof.example.json`
- Create: `harmony/tests/structure/plan-d-device-proof-contract.test.mjs`
- Use ignored local `.omx/inspect-phase4-device-evidence.mjs` only to diagnose a failed tracked proof; it is not a pass authority
- Reuse: `harmony/tests/bin/inspect-hap.mjs`
- Reuse: `harmony/tests/bin/inspect-phase4-packages.mjs`
- Reuse: `harmony/tests/bin/run-phase4-device-proof.mjs`

- [ ] **Step 1: Restore automatic signing in an isolated temporary copy**

Recover the separately provisioned production and traffic-probe automatic-signing configurations from safe local backups. Validate all referenced material exists without printing it. Patch `harmony/build-profile.json5` and `harmony/traffic-probe/build-profile.json5` only for their builds, and restore both original files' exact bytes in `finally`. Do not place signing material inside the repository. The two packages must retain distinct verified signatures.

- [ ] **Step 2: Build and inspect fresh production and probe packages**

Prepare the digest-pinned GeoIP asset, compile native libraries, assemble the current production package, and separately assemble the current traffic-probe package. Validate production provenance, then inspect both packages together:

```bash
node harmony/tests/bin/build-phase1-native.mjs \
  --out harmony/artifacts/phase1-native-provenance.json
cd harmony/traffic-probe
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug clean
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
cd ../..
node harmony/tests/bin/inspect-hap.mjs \
  --hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --manifest harmony/artifacts/phase1-native-provenance.json \
  --build-kind production
node harmony/tests/bin/inspect-phase4-packages.mjs \
  --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --production-manifest harmony/artifacts/phase1-native-provenance.json \
  --probe-hap harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap \
  --out harmony/artifacts/phase4-package-inspection.json
```

Both package inspections must pass. Record only each package's size and SHA-256 in private evidence; do not report signing paths or identifiers.

- [ ] **Step 3: Install both packages and open the production application**

Use the single authorized physical phone. Install both inspected packages with replacement, launch the production entry ability, and confirm the active profile remains valid. If installation or launch fails, collect only allowlisted stage/error codes.

- [ ] **Step 4: Verify the real node page without persisting raw layout**

`run-plan-d-device-proof.mjs` opens `home.proxy.manage`. It dumps the UI hierarchy to a `mkdtemp` directory, counts `proxies.group.<index>` and `proxies.node.<index>` components, hashes the canonical ordered semantic-ID list, then deletes the raw dump in `finally`. Pass requires more than one node and at least one selectable group. The proof stores only counts and hashes.

- [ ] **Step 5: Select a terminal node and start VPN**

`run-plan-d-device-proof.mjs` imports `runPhase4DeviceProof` and `defaultPerformUiAutomation`. It supplies a wrapper `performUiAutomationImpl`: before delegating to the default Phase 4 VPN-start automation, it launches production, opens the proxy page, chooses a non-selected terminal row by semantic index, computes `selectedRowCorrelationHash = SHA-256(runId + NUL + rowSemanticId)`, and computes `selectedTerminalHash = SHA-256(UTF8(rowVisibleLabel))` in memory. It never persists the raw semantic ID, index, visible label, or `selectedTerminalHash`. After the default automation returns with VPN running, the wrapper relaunches the production UI without stopping the VPN, reopens the proxy page, requires exactly one `proxies.node.<index>.runtime-selected` marker and no saved marker, hashes the marker's parent row, and requires equality with `selectedRowCorrelationHash` before returning control to Phase 4. A wrapped `startOriginImpl` also retains the run-unique HTTPS origin IP and port only in memory and computes the exact expected HTTPS `DestinationHash` using the Go canonical formula.

- [ ] **Step 6: Run the controlled HTTPS probe through TUN**

Invoke the tracked Plan D runner against the exact inspected production and probe packages. It delegates the VPN/TUN lifecycle and traffic portion to `runPhase4DeviceProof` with the wrapped UI hook above:

```bash
node harmony/tests/bin/run-plan-d-device-proof.mjs \
  --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --probe-hap harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap \
  --phase4-out harmony/artifacts/phase4-device-proof.json \
  --out harmony/artifacts/plan-d-device-proof.json
```

Pass requires the wrapped UI hook to return the matching runtime-selected row hash, then the Phase 4 HTTPS step and matching origin observation to succeed, a non-empty HTTPS response hash, and VPN evidence proving ingress was `tun`; packet counters must advance. The Plan D runner locates exactly one runtime trace whose `DestinationHash` equals the in-memory run-unique HTTPS destination hash and whose protocol is TCP, then requires `selectedTerminalHash === outboundTerminalHash`. Zero or multiple HTTPS destination matches fail closed. It persists only `httpsTraceMatched: true` and `selectedProxyMatched: true`. The hook runs before Phase 4 network recovery and `runVpnProbeImpl`, so the runtime-confirmed marker, live tracker chain, HTTPS destination, and traffic use the same still-bound running session. The combined proof therefore verifies that the selected terminal member is the actual mihomo outbound leaf of the successful HTTPS flow without persisting its label, deterministic label hash, or destination hash. Do not record the chosen label, raw semantic ID, index, selected-label hash, raw chain, destination hash, or remote endpoint.

- [ ] **Step 7: Verify persistence across relaunch**

After delegated Phase 4 cleanup stops VPN, the Plan D runner launches production again, selects another terminal row, confirms one saved marker and the old runtime checkmark semantics, and computes a new opaque row correlation hash. It force-stops/relaunches production, starts VPN through the same stable Home action, and verifies replay completes before `RUNNING`. It reopens the page while VPN remains running, hashes the unique runtime-selected marker's parent row, and requires it equals the new saved-row correlation hash. Record only result kinds, counts, ordering booleans, and hashes.

- [ ] **Step 8: Write the safe device report and restore local state**

`docs/harmony/proxy-ui-device-proof.md` may contain only:

- package SHA-256 and size;
- group/node counts;
- semantic-ID list hash;
- selected-row correlation hash and equality booleans after start and relaunch;
- selection result kinds;
- replay-before-running boolean;
- HTTPS status class and response hash;
- TUN ingress boolean and counter deltas;
- HTTPS trace matched boolean;
- selected outbound terminal matched boolean;
- relaunch replay boolean;
- zero-leak assertions.

The tracked Plan D proof schema rejects unknown fields and permits only the allowlisted counts, booleans, result kinds, timestamps, and lowercase SHA-256 values above. It forbids raw semantic IDs/indexes as well as labels and endpoints. Remove temporary raw layouts, pulled private journals, origin logs, and signing copies in `finally`. Restore both unsigned build profiles' exact bytes.

---

## Plan D Completion Criteria

1. `home.proxy.manage` is present and guarded by a ready valid active profile.
2. `ProxiesPage` renders multiple real groups/nodes in runtime order with stable index-only semantic IDs.
3. Exactly one runtime-confirmed selection uses a checkmark; a stopped saved intent uses a distinct marker.
4. Terminal selection is generation-bound, duplicate-safe, and truthfully maps all four Plan C result kinds.
5. Nested group rows navigate rather than patching a group as a terminal node.
6. No UI, log, error, report, or proof leaks endpoints, credentials, private IDs, raw group/node labels, configuration paths, device identifiers, subscription content, or signing material.
7. Full host tests, structure contracts, current signed production/probe builds, dual-package inspection, and provenance validation pass.
8. Physical-device evidence proves multiple nodes are visible, replay occurs before `RUNNING`, one selected node carries a successful HTTPS request through TUN, and persistence survives relaunch.
