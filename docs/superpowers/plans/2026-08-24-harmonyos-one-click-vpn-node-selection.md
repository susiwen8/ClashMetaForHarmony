# HarmonyOS One-Click VPN Node Selection Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one tap on a terminal proxy node stop any running local proxy, select the node, start VPN global capture, and confirm that node as runtime-selected without leaving the proxy page.

**Architecture:** Add a typed one-click activation contract and an application-scoped orchestration use case to `ProfileApplication`. `ProxyViewModel` consumes the use case through an extended presentation port, renders bounded activation stages, and refreshes the same displayed group only after VPN `RUNNING` plus runtime-selection confirmation. Existing proxy selection, VPN replay, lifecycle drain, semantic IDs, and privacy boundaries remain authoritative.

**Tech Stack:** HarmonyOS 6.x, ArkTS, Hypium, existing `ProfileApplication`/`ProxyService`/`VpnControllerPort` architecture, Node structure/device-proof tests, HDC/UITest.

**Design:** `docs/superpowers/specs/2026-08-24-harmonyos-one-click-vpn-node-selection-design.md`

**Working constraint:** Do not commit or push. Commit steps from the generic workflow are intentionally replaced with verification checkpoints because the user explicitly requires an uncommitted worktree.

---

## File Map

### New focused units

- `harmony/shared/src/main/ets/proxy/ProxyOneClickVpnModels.ets` — closed result/failure contracts, validation, and clone constructors.
- `harmony/shared/src/test/ProxyOneClickVpnModels.test.ets` — result/error invariant tests.
- `harmony/shared/src/main/ets/profile/OneClickVpnConfirmation.ets` — subscription-based, bounded VPN `RUNNING` confirmation and typed terminal outcomes.
- `harmony/shared/src/test/OneClickVpnConfirmation.test.ets` — deterministic fake-observer confirmation tests.
- `harmony/tests/bin/run-proxy-one-click-vpn-device-proof.mjs` — privacy-safe physical-device orchestration.
- `harmony/tests/fixtures/proxy-one-click-vpn-device-proof.schema.json` — strict aggregate/fixed-enum proof schema.
- `harmony/tests/fixtures/proxy-one-click-vpn-device-proof.example.json` — canonical incomplete proof.
- `harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs` — cross-layer, privacy, runner, and schema contracts.
- `docs/harmony/proxy-one-click-vpn.md` — implemented public behavior and verification commands.
- `docs/harmony/proxy-one-click-vpn-device-proof.md` — exact physical-proof command and privacy guarantee.

### Existing units to modify

- `harmony/shared/src/main/ets/proxy/ProxyPorts.ets` — presentation-facing one-click application port.
- `harmony/shared/src/main/ets/vpn/VpnPorts.ets` — balanced VPN runtime observation (`subscribe`/`unsubscribe`).
- `harmony/shared/src/main/ets/vpn/VpnRuntimeCoordinator.ets` — balanced `VpnControllerPort` implementation.
- `harmony/shared/src/main/ets/profile/ProfileApplication.ets` — application-scoped admission/mutation lease and orchestration.
- `harmony/shared/Index.ets` and `harmony/shared/src/test/List.test.ets` — public exports and suite registration.
- `harmony/shared/src/test/ProfileManagement.test.ets` — orchestration order, busy, replay, and failure tests.
- `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets` — `unsubscribe` implementation.
- `harmony/entry/src/test/HarmonyVpnController.test.ets` and `harmony/entry/src/test/ApplicationComposition.test.ets` — observation lifecycle compatibility.
- `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets` — construct one controller instance and its confirmation adapter.
- `harmony/entry/src/main/ets/presentation/ProxyPresentationModels.ets` — one-click activation view state.
- `harmony/entry/src/main/ets/presentation/ProxyViewModel.ets` — terminal-node one-click action and same-group confirmation refresh.
- `harmony/entry/src/test/ProxyPresentationModels.test.ets`, `harmony/entry/src/test/ProxyViewModel.test.ets`, and `harmony/entry/src/test/fakes/PresentationFakes.ets` — presentation tests/fakes.
- `harmony/entry/src/main/ets/pages/ProxiesPage.ets`, `harmony/entry/src/main/ets/pages/Index.ets`, and `harmony/entry/src/main/resources/base/element/string.json` — UI copy, disabled states, and wiring.
- `harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs` — stable semantic IDs and UI source contracts.
- `harmony/entry/src/ohosTest/ets/test/Phase3UiFlow.test.ets` — physical-device UI flow and controlled failure surface.

---

## Chunk 1: Typed Contracts and Runtime Observation

### Task 1: Add the closed one-click activation result model

**Files:**
- Create: `harmony/shared/src/main/ets/proxy/ProxyOneClickVpnModels.ets`
- Create: `harmony/shared/src/test/ProxyOneClickVpnModels.test.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing model tests**

Cover the exact success kinds:

```ts
export type SelectNodeAndEnsureVpnSuccessKind =
  | 'ALREADY_ACTIVE'
  | 'APPLIED_TO_RUNNING_VPN'
  | 'APPLIED_TO_RUNNING_VPN_NOT_PERSISTED'
  | 'VPN_STARTED'
  | 'SAVED_VPN_START_FAILED';
```

Cover the exact failure stages/codes and require every failure to carry only:

```ts
interface OneClickVpnFailure {
  stage: 'ADMISSION' | 'LOCAL_STOP' | 'SELECTION' | 'VPN_START' | 'VPN_CONFIRMATION';
  code: OneClickVpnFailureCode;
  retryable: boolean;
  resourceId: OneClickVpnErrorResourceId;
  savedForNextStart: boolean;
}
```

Test deep clones, closed keys, safe resource IDs, saved-marker invariants, and rejection of raw label/endpoint/session fields. Add table-driven assertions for every design-spec `OneClickVpnFailureCode`; each row must assert its exact `resourceId`, `retryable`, and `savedForNextStart` rather than checking only broad allowlists.

Also model the application-scoped progress contract:

```ts
export type OneClickVpnProgressStage =
  | 'IDLE'
  | 'STOPPING_LOCAL'
  | 'SAVING_SELECTION'
  | 'STARTING_VPN'
  | 'SWITCHING_VPN'
  | 'CONFIRMING_SELECTION';
```

The operation snapshot shape is exact:

```ts
export type OneClickVpnOperationOutcome = 'NONE' | 'SUCCEEDED' | 'FAILED';

export interface OneClickVpnOperationSnapshot {
  stage: OneClickVpnProgressStage;
  busy: boolean;
  outcome: OneClickVpnOperationOutcome;
}
```

Tests require every live stage to have `busy=true/outcome=NONE`; `IDLE` has `busy=false` and outcome `NONE`, `SUCCEEDED`, or `FAILED`. A new operation clears the outcome, and terminal publication returns to `IDLE`. No extra fields are allowed.

- [ ] **Step 2: Run shared tests and verify RED**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: compile/test failure because one-click result constructors and exports do not exist.

- [ ] **Step 3: Implement the minimal model**

Add concrete ArkTS value classes and constructors such as:

```ts
export function createOneClickVpnFailureResult(
  stage: OneClickVpnFailureStage,
  code: OneClickVpnFailureCode,
  retryable: boolean,
  resourceId: OneClickVpnErrorResourceId,
  savedForNextStart: boolean
): SelectNodeAndEnsureVpnResult;

export function cloneSelectNodeAndEnsureVpnResult(
  result: SelectNodeAndEnsureVpnResult
): SelectNodeAndEnsureVpnResult;
```

Do not carry group/node names, session IDs, raw `AppError`, raw `VpnFailure`, or technical detail in the public result.

- [ ] **Step 4: Run shared tests and verify GREEN**

Expected: all shared tests pass and the result allowlists are exact.

- [ ] **Step 5: Verification checkpoint**

Run `git diff --check`. Do not commit.

### Task 2: Add balanced, bounded VPN runtime confirmation

**Files:**
- Create: `harmony/shared/src/main/ets/profile/OneClickVpnConfirmation.ets`
- Create: `harmony/shared/src/test/OneClickVpnConfirmation.test.ets`
- Modify: `harmony/shared/src/main/ets/vpn/VpnPorts.ets`
- Modify: `harmony/shared/src/main/ets/vpn/VpnRuntimeCoordinator.ets`
- Modify: `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets`
- Modify: `harmony/entry/src/test/HarmonyVpnController.test.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/shared/src/test/VpnRuntimeCoordinator.test.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing observation tests**

Require `VpnControllerPort` to expose balanced observation:

```ts
subscribe(listener: (event: VpnRuntimeEvent) => void): number;
unsubscribe(subscriptionId: number): void;
```

Test a confirmation adapter that:

- subscribes before controller start can emit;
- first checks the current snapshot to avoid missing synchronous `RUNNING`;
- resolves `RUNNING` only for the expected session;
- maps `STOPPED`, `ERROR`, session change, and timeout to closed confirmation outcomes;
- cancels its timer and unsubscribes exactly once on every terminal path.

- [ ] **Step 2: Run shared/entry tests and verify RED**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: missing `unsubscribe`/confirmation types or interface implementation failures.

- [ ] **Step 3: Implement balanced observation**

Add `unsubscribe()` to both real `VpnControllerPort` implementers: `VpnRuntimeCoordinator` removes the listener from its own listener map, and `HarmonyVpnController` delegates to the registry. Implement a focused `SubscriptionOneClickVpnConfirmation` by reusing the existing `BoundedDelaySchedulerPort` and `CancelableDelayTask`; do not introduce a second scheduler/deadline abstraction and do not use unbounded polling.

The confirmation result must not contain session IDs. Session equality is private in-memory validation only.

- [ ] **Step 4: Run shared/entry tests and verify GREEN**

Run the same two explicit Hypium commands from Step 2. Expected: shared/entry compile through, removed listeners receive no later events, balanced subscription counts hold, and every confirmation terminal branch passes.

- [ ] **Step 5: Verification checkpoint**

Run `git diff --check`. Do not commit.

---

## Chunk 2: Application-Scoped Orchestration

### Task 3: Add the presentation-facing one-click port

**Files:**
- Modify: `harmony/shared/src/main/ets/proxy/ProxyPorts.ets`
- Modify: `harmony/shared/src/main/ets/profile/ProfileApplication.ets`
- Modify: `harmony/shared/src/test/ProfileManagement.test.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`

- [ ] **Step 1: Write failing port/composition tests**

Define an extended port without forcing `ProxyService` to own VPN lifecycle:

```ts
export interface ProxyOneClickVpnApplicationPort extends ProxyApplicationPort {
  currentOneClickVpnOperation(): OneClickVpnOperationSnapshot;
  subscribeOneClickVpnOperation(listener: OneClickVpnOperationListener): number;
  unsubscribeOneClickVpnOperation(subscriptionId: number): void;
  selectNodeAndEnsureVpn(
    groupName: string,
    memberName: string,
    snapshotGeneration: number
  ): Promise<SelectNodeAndEnsureVpnResult>;
}
```

Require `ProfileApplication` to implement it. Add an explicit `ApplicationCompositionDependencies.createOneClickVpnConfirmation(controller: VpnControllerPort)` factory seam. In composition, create one `VpnControllerPort` instance, pass that exact object (`===`) to the confirmation factory, and pass both the controller and returned adapter to `ProfileApplication`. The composition test must capture both references and assert object identity, not merely a shared registry.

- [ ] **Step 2: Run shared/entry tests and verify RED**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: port/method/dependency/factory construction missing.

- [ ] **Step 3: Implement only the interface/dependency wiring**

Add a `oneClickVpnConfirmation` dependency to `ProfileApplicationDependencies`, the explicit composition factory seam above, and balanced progress listener storage to `ProfileApplication`. Update dependency bags and fakes, but leave the orchestration method returning a temporary typed unavailable result only long enough to compile this task's wiring tests.

- [ ] **Step 4: Run shared/entry tests and verify GREEN**

Run the same explicit shared/entry commands from Step 2. Expected: the factory identity assertion passes and composition uses one controller instance; no orchestration behavior is claimed yet.

- [ ] **Step 5: Verification checkpoint**

Run `git diff --check`. Do not commit.

### Task 4: Implement app-scoped single-flight and exact runtime ordering

**Files:**
- Modify: `harmony/shared/src/main/ets/profile/ProfileApplication.ets`
- Modify: `harmony/shared/src/test/ProfileManagement.test.ets`
- Modify: `harmony/shared/src/test/fakes/ProfileFakes.ets` if shared helpers are already centralized there

- [ ] **Step 1: Write failing stopped-runtime tests**

Cover exact order with a shared command log:

```text
proxy.select(group, node, originalGeneration)
vpn.start(profile, revision, freshSession)
vpn.confirm.running
proxy.queryGroup(group)
```

Require success only when the post-start group snapshot marks the target terminal row `runtimeSelected=true`.

- [ ] **Step 2: Write failing local-running tests**

Require exact order:

```text
delay.drain
local.stop
proxy.queryGroup(group)        # obtains fresh generation
proxy.select(group, node, freshGeneration)
vpn.start
vpn.confirm.running
proxy.queryGroup(group)        # confirms runtime selection
```

Test local-stop failure, missing member after re-query, and generation/session change. No selection write or VPN start may follow a failed stop/revalidation.

- [ ] **Step 3: Write failing running-VPN and busy tests**

Cover:

- running VPN: `proxy.select` only; no local stop and no VPN start/stop;
- `APPLIED_NOT_PERSISTED`: runtime success with warning result;
- current node: `ALREADY_ACTIVE` without mutation;
- application-scoped admission rejects duplicate one-click calls;
- Home local/VPN start/stop entry points observe the same mutation lease;
- local/VPN transition states return `OPERATION_BUSY`;
- dispose/page recreation does not cancel an admitted operation.
- confirmation `STOPPED` before `RUNNING` maps exactly to `FAILED / VPN_CONFIRMATION / VPN_STOPPED_BEFORE_RUNNING`;
- confirmation `ERROR` with consent denial maps to `VPN_PERMISSION_DENIED`, while other runtime/start failures map to `VPN_START_FAILED`;
- bounded confirmation expiry maps to `VPN_CONFIRMATION_TIMEOUT`;
- running identity/session change before post-start row confirmation maps to `VPN_SESSION_CHANGED`;
- every mapping asserts exact `kind`, `stage`, `code`, `resourceId`, `retryable`, and `savedForNextStart`.

- [ ] **Step 4: Run shared tests and verify RED**

Expected: orchestration behavior is absent.

- [ ] **Step 5: Implement the minimal orchestration**

Add an application-scoped lease/owner. Public runtime mutations acquire/check it; private inside-lease helpers perform the one-click chain without reacquiring.

Use existing `ProxyService`/runtime-controller APIs as authorities. Do not duplicate selection persistence or VPN replay logic. Subscribe/arm VPN confirmation before the start call can emit; after confirmation, query the same group and validate the selected member in-memory.

- [ ] **Step 6: Run shared tests and verify GREEN**

Expected: all ordering, busy, failure, saved-marker, and confirmation tests pass.

- [ ] **Step 7: Verification checkpoint**

Run shared tests twice to catch state leakage, then `git diff --check`. Do not commit.

---

## Chunk 3: Presentation and ArkUI

### Task 5: Extend presentation state for one-click activation

**Files:**
- Modify: `harmony/entry/src/main/ets/presentation/ProxyPresentationModels.ets`
- Modify: `harmony/entry/src/test/ProxyPresentationModels.test.ets`
- Modify: `harmony/entry/src/test/List.test.ets`

- [ ] **Step 1: Write failing presentation-model tests**

Add a closed stage such as:

```ts
export type ProxyOneClickVpnViewStage =
  | 'IDLE'
  | 'STOPPING_LOCAL'
  | 'SAVING_SELECTION'
  | 'STARTING_VPN'
  | 'SWITCHING_VPN'
  | 'CONFIRMING_SELECTION'
  | 'FAILED';
```

Track only a bounded activating row index and safe error/resource state. Preserve existing delay overlay, selection markers, group order, and semantic IDs through clones.

Lock this invariant matrix in tests:

| Activation stage | `selectionPending` | Activating row | Activation error | Runtime-selected rows |
| --- | --- | --- | --- | --- |
| `IDLE` | false | absent | absent | existing `READY` invariant: exactly one |
| live stages (`STOPPING_LOCAL` through `CONFIRMING_SELECTION`) | true | valid terminal row index | absent | exactly one; never claim the target until confirmed |
| `FAILED` | false | optional retained row index | required | exactly one; saved marker may differ from runtime marker |

Use dedicated `activationErrorResourceId` and `activationErrorRetryable` fields. Do not widen or overload the existing `ProxyRejectedErrorCode`/`errorCode` selection-query error channel. `FAILED` is a retryable/non-retryable terminal presentation state and must re-enable controls.

- [ ] **Step 2: Run entry tests and verify RED**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: view-state fields/constructors missing.

- [ ] **Step 3: Implement the minimal state and clone invariants**

No group/node labels enter activation error fields or semantic IDs.

- [ ] **Step 4: Run entry tests and verify GREEN**

Run the same explicit entry Hypium command. Expected: invariant/clone/error-channel tests pass.

- [ ] **Step 5: Verification checkpoint**

Run `git diff --check`. Do not commit.

### Task 6: Replace terminal selection with the one-click ViewModel flow

**Files:**
- Modify: `harmony/entry/src/main/ets/presentation/ProxyViewModel.ets`
- Modify: `harmony/entry/src/test/ProxyViewModel.test.ets`
- Modify: `harmony/entry/src/test/fakes/PresentationFakes.ets`

- [ ] **Step 1: Write failing ViewModel tests**

Cover:

- terminal row invokes `selectNodeAndEnsureVpn` with exact group/member/generation;
- nested row remains query/navigation only;
- current running row is a no-op;
- live delay and live activation reject node/group/reload actions;
- stages map to safe presentation copy and activating row index;
- application progress subscription drives every stage; ViewModel does not infer `SAVING_SELECTION` or `CONFIRMING_SELECTION` from elapsed time;
- `VPN_STARTED`/`APPLIED_TO_RUNNING_VPN` refresh the same displayed group until runtime marker confirmation;
- `SAVED_VPN_START_FAILED` keeps the saved marker and page error;
- all failure codes map to exact resource IDs/retryability without raw error detail;
- duplicate taps create one application call;
- leave/dispose stops page-level refresh but does not cancel the application operation;
- a new ViewModel load recovers the source-of-truth state.
- constructor subscribes to the application-scoped operation snapshot; dispose unsubscribes exactly once and ignores later callbacks.

- [ ] **Step 2: Run entry tests and verify RED**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: ViewModel still calls plain `select` and lacks activation/progress subscription behavior.

- [ ] **Step 3: Implement the minimal flow**

Change the constructor dependency to `ProxyOneClickVpnApplicationPort`. Subscribe to `currentOneClickVpnOperation`/operation events, publish their closed stages with the private activating row index, and balance unsubscribe on dispose. Keep delay polling and selection-epoch protection independent. Reuse existing displayed-group query helpers instead of routing to Home or calling `HomeViewModel`.

- [ ] **Step 4: Run entry tests and verify GREEN**

Run the same explicit entry Hypium command. Expected: one-click/progress/dispose tests and all existing proxy tests pass.

- [ ] **Step 5: Verification checkpoint**

Run entry tests twice and `git diff --check`. Do not commit.

### Task 7: Render one-click stages without changing semantic IDs

**Files:**
- Modify: `harmony/entry/src/main/ets/pages/ProxiesPage.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Modify: `harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs`

- [ ] **Step 1: Write failing ArkUI/structure contracts**

Require resource-backed text for `正在启动 VPN`, `正在切换到 VPN`, `切换中`, local-stop failure, busy, and confirmation timeout. Require the activating row to reuse `proxies.node.<index>`; do not create IDs containing stage/node data.

Pin that group chips, other rows, delay action, and retry controls are disabled while activation is live.

- [ ] **Step 2: Run focused structure and entry tests and verify RED**

Run the focused structure command and the exact `entry@default` Hypium command shown in Step 4. Expected: resources/wiring/render contracts are missing.

- [ ] **Step 3: Implement the minimal UI**

Keep `Index` as wiring only. It must continue to pass `onSelectNode` to `ProxyViewModel.activateNode`; it must not call `HomeViewModel.requestVpnAction` from the proxy route.

Render stage text inside the existing row status column and render the typed safe error on the proxy page. Reuse the established primitive `renderVersion`/member-builder pattern so ArkUI updates on every activation snapshot.

- [ ] **Step 4: Run focused structure, entry tests, and ohosTest assemble GREEN**

Run:

```bash
node --test harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

- [ ] **Step 5: Verification checkpoint**

Run `git diff --check`. Do not commit.

---

## Chunk 4: Cross-Layer Contracts and Device Proof

### Task 8: Add one-click cross-layer and privacy contracts

**Files:**
- Create: `harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs`
- Create: `docs/harmony/proxy-one-click-vpn.md`
- Modify: `harmony/tests/structure/phase3-layer-boundary.test.mjs`
- Modify: `harmony/tests/structure/phase4-vpn-contract.test.mjs`

- [ ] **Step 1: Write failing source-order and privacy tests**

Pin:

- application layer owns stop/select/start/confirm ordering;
- stop-local precedes stopped-path re-query;
- persistence precedes VPN start;
- `STARTED` is never treated as success without `RUNNING` plus runtime marker;
- running VPN never calls start/stop for hot-switch;
- application-scoped admission covers Home mutations;
- ViewModel/Index never sequence Home VPN actions;
- public/result/error/log/durable surfaces do not contain raw labels, endpoints, URLs, credentials, sessions, or raw platform detail.

Add positive and negative synthetic privacy fixtures.

- [ ] **Step 2: Run focused contracts and verify RED**

Run:

```bash
node --test harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs
node --test \
  harmony/tests/structure/phase3-layer-boundary.test.mjs \
  harmony/tests/structure/phase4-vpn-contract.test.mjs
```

Expected: new authority/order/privacy contracts fail because one-click surfaces are absent.

- [ ] **Step 3: Update exact authority inventories and documentation**

Document only closed enums, ordering, ownership, safe error resources, and commands. Do not include live labels or device data.

- [ ] **Step 4: Run focused and full structure suites GREEN**

Run the same focused commands from Step 2, then:

```bash
node --test harmony/tests/structure/*.test.mjs
```

Expected: every tracked structure test passes.

- [ ] **Step 5: Verification checkpoint**

Run signing-isolation and `git diff --check`. Do not commit.

### Task 9: Implement a privacy-safe physical-device proof

**Files:**
- Create: `harmony/tests/bin/run-proxy-one-click-vpn-device-proof.mjs`
- Create: `harmony/tests/fixtures/proxy-one-click-vpn-device-proof.schema.json`
- Create: `harmony/tests/fixtures/proxy-one-click-vpn-device-proof.example.json`
- Extend: `harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs`
- Create: `docs/harmony/proxy-one-click-vpn-device-proof.md`
- Modify: `harmony/entry/src/ohosTest/ets/test/Phase3UiFlow.test.ets`

- [ ] **Step 1: Write failing schema/runner contracts**

Permit only fixed/aggregate fields, for example:

```text
schemaVersion
result: pass | incomplete
packageSha256
stoppedToVpnState: RUNNING_SELECTED | NOT_PROVEN
localToVpnState: LOCAL_STOPPED_VPN_RUNNING_SELECTED | NOT_PROVEN
runningSwitchState: HOT_SWITCHED_SAME_SESSION | NOT_PROVEN
cleanupState: CLEAN | NOT_PROVEN
```

Reject labels, hashes of labels, endpoints, URLs, credentials, timestamps, sessions, device IDs, raw layouts, and journals.

- [ ] **Step 2: Run the focused contract and verify RED**

Run:

```bash
node --test harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs
```

Expected: runner/schema/example/doc surfaces are missing.

- [ ] **Step 3: Implement production-HAP success-path orchestration**

Reuse only Phase 4/Plan D HDC target, semantic click, scroll, bounded layout-dump, consent, VPN state, and cleanup helpers. Explicitly do **not** reuse `readNodeVisibleLabel`, `hashSelectedTerminalLabel`, `selectedTerminalHash`, or the label-reading branch of `analyzeProxySelectionLayout`. Choose terminal nodes only by `proxies.node.<index>` held in private memory; never read, hash, persist, or print their labels.

Prove:

- stopped runtimes → tap terminal node → VPN `RUNNING` → same semantic row gets runtime marker;
- local running → tap a different terminal node → local stops → VPN runs → selected marker confirmed;
- VPN running → tap another terminal node → marker changes while VPN session remains the same in private memory;
- cleanup returns Home, stops VPN, force-stops owned apps, deletes remote/private journals and local layouts.

- [ ] **Step 4: Complete controlled failure integration coverage**

Keep controlled failure in injectable shared/entry Hypium tests: `ProfileApplication` proves the saved result plus retryable VPN-start failure, and `ProxyViewModel` proves the saved marker/error plus successful next-tap retry. These tests may compile/run in the ohosTest target, but do not inject dependencies into production `EntryAbility` and do not add a production self-test hook.

- [ ] **Step 5: Run proof contracts and ohosTest assemble GREEN**

Run:

```bash
node --test harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

- [ ] **Step 6: Run the physical proof**

After a fresh signed HAP exists:

```bash
node harmony/tests/bin/run-proxy-one-click-vpn-device-proof.mjs \
  --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --out harmony/artifacts/proxy-one-click-vpn-device-proof.json
```

Expected: `result: pass`, all three production behavior states proven, cleanup `CLEAN`, and zero private fields. The controlled failure/retry path is proven by the injectable tests from Step 4.

- [ ] **Step 7: Verification checkpoint**

Require all of the following:

- every `dumpLayoutToHost` pull removes its `/data/local/tmp/cmfa-layout-*.json` remote file before returning;
- bundle-scoped cleanup removes `/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json` with `hdc shell -b com.github.kr328.clash.harmony rm -f ...`;
- the runner removes local `fs.mkdtemp` roots prefixed `proxy-one-click-vpn-layout-` and `proxy-one-click-vpn-runtime-` in `finally`;
- a post-run `hdc shell -b ... test ! -e ...` assertion succeeds and `find /tmp` reports zero recent matching temp roots;
- production and probe bundles are force-stopped after verified VPN stop.

Run the focused contract again after cleanup checks. Do not commit.

---

## Chunk 5: Final Gates and Packaging

### Task 10: Run complete regression gates

**Files:**
- Modify only files already owned by Tasks 1-9 when a genuine regression requires a fix.

- [ ] **Step 1: Run Go and native gates**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go test ./... -count=1
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go test -race ./internal/proxygroups -run 'TestDelayJob' -count=1
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go vet ./...
cd "$CMFA_REPO_ROOT"
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/test-native-host.mjs --case napi-proxy
node harmony/tools/test-native-host.mjs --case napi-tun
```

- [ ] **Step 2: Run all structure and ArkTS gates**

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

No warning-only cleanup or unrelated refactor.

- [ ] **Step 4: Verification checkpoint**

Run all affected gates again and `git diff --check`. Do not commit.

### Task 11: Build, inspect, prove, and restore signing isolation

**Files/Artifacts:**
- Generate: `harmony/artifacts/phase1-native-provenance.json`
- Generate: `harmony/entry/build/default/outputs/default/entry-default-signed.hap`
- Generate: `harmony/artifacts/proxy-one-click-vpn-device-proof.json`
- Modify: `docs/harmony/proxy-one-click-vpn-device-proof.md`
- Modify: `harmony/tests/fixtures/proxy-one-click-vpn-device-proof.example.json`
- Modify: `harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs`

- [ ] **Step 1: Open a bounded signing window**

Reuse the secure signing workflow established by the prior Harmony plans:

1. Require tracked `harmony/build-profile.json5` to match the safe empty-signing baseline byte-for-byte; capture its bytes and SHA-256 privately without printing them.
2. Require one complete ignored automatic-signing backup at `.codex-secure/harmony-build-profile.signed.json5`. The containing temporary/signing directory must be mode `0700` and files mode `0600`.
3. Validate privately that the signed backup differs from the baseline only by one complete `app.signingConfigs` block and that every referenced local signing file exists; never print paths, aliases, passwords, or identities.
4. If the complete ignored backup is absent, stop with fixed `SIGNING_REQUIRED`, ask the user to regenerate DevEco automatic signing for this production project, capture the resulting signed profile into the ignored secure backup, then immediately restore the empty baseline.
5. For packaging, inject only the validated `app.signingConfigs` block and execute build/inspect/proof inside a `try/finally` signing window.
6. In `finally`, restore the exact baseline bytes/hash and move the temporary signing working directory to Trash. Do not delete or alter the user's DevEco credential store.

Never print or persist signing material in command output, logs, artifacts, docs, or Git.

- [ ] **Step 2: Clean and build the final signed HAP**

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

- [ ] **Step 3: Run the one-click and existing delay physical proofs**

Run the new one-click proof and rerun `run-proxy-delay-device-proof.mjs` to ensure selection interaction changes did not regress delay testing, cancellation, VPN quiet-window, or cleanup.

- [ ] **Step 4: Synchronize final artifact hashes**

Update the exact final HAP SHA-256 in:

- `docs/harmony/proxy-one-click-vpn-device-proof.md`;
- `harmony/tests/fixtures/proxy-one-click-vpn-device-proof.example.json`;
- `harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs`.

Then run:

```bash
node --test harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs
```

- [ ] **Step 5: Restore signing isolation**

Restore `"signingConfigs": []` exactly. Require:

```bash
git diff --exit-code -- harmony/build-profile.json5
node --test harmony/tests/structure/signing-isolation.test.mjs
```

- [ ] **Step 6: Final verification and review**

Require this executable checklist:

1. Re-run all Task 10 gates and both focused proof contracts.
2. Require both physical proof JSON documents to validate as `pass` against their strict schemas.
3. Prove remote cleanup with bundle-scoped HDC:

   ```bash
   hdc shell -b com.github.kr328.clash.harmony \
     sh -c 'test ! -e /data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json'
   ```

   Require no recent `/tmp/proxy-one-click-vpn-layout-*`, `/tmp/proxy-one-click-vpn-runtime-*`, `/tmp/proxy-delay-layout-*`, or `/tmp/proxy-delay-runtime-*` directories.
4. Scan source while excluding generated caches:

   ```bash
   rg -n \
     --glob '!harmony/artifacts/go-mod-cache/**' \
     --glob '!harmony/**/.test/**' \
     'DEBUG-|CMFADelay|CMFA_SAFE_.*STAGE|reportSafe.*Stage' \
     harmony/entry/src harmony/shared/src harmony/tests/bin
   ```

   Expected: no matches.
5. Dispatch a named one-click spec-compliance reviewer after implementation and a separate one-click code-quality reviewer after spec approval. Resolve and re-review every Important/Critical issue, then dispatch one final whole-feature reviewer. Record their `APPROVED` verdicts in the task transcript/final report; do not persist private review context in repository artifacts.
6. Run `git diff --check`, the signing-isolation test, and `git diff --exit-code -- harmony/build-profile.json5`.
7. Confirm no commit or push was created and the worktree remains available.
