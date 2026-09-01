# HarmonyOS Proxy Selection Service and VPN Replay Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Coordinate active-profile proxy queries and selections across stopped and running VPN states, persist only confirmed intents, and replay them before VPN publishes `RUNNING`.

**Architecture:** `shared` owns closed proxy application results, `ProxyService`, a session-bound `VpnProxyCommandBus`, and the extension-owned runtime handler. `platform` migrates the profile RDB to version 2 with the only durable raw group/node table and supplies SHA-256 correlation identities. `entry` installs one bus beside `VpnSessionRegistry`, wires app-side stopped commands and extension-side running commands to the same authority, and gates initial start and recovery replay before `RUNNING`.

**Tech Stack:** ArkTS/Hypium, HarmonyOS relationalStore, CryptoArchitectureKit SHA-256, existing `CoreService` proxy contract, `SerialCommandQueue`, `VpnRuntimeCoordinator`, Node.js structure contracts, Hvigor.

**Spec:** `docs/superpowers/specs/2026-08-21-harmonyos-proxy-group-node-selection-design.md` — Plan C only.

**Prerequisite:** Plan B host and unsigned packaged-native contracts pass. Its fresh signed-HAP gate remains pending solely on DevEco automatic-signing regeneration; Plan C may proceed without weakening that later gate.

**Dirty-worktree constraint:** All listed modules contain user/Plan A/B changes. Preserve them. Never reset, restore, clean, stage whole files, or commit without explicit user authorization. Use `apply_patch` for source edits.

**Privacy rule:** `proxy_selections` is the only new durable location allowed to contain raw group/node names. Application memory may carry names for UI, but logs, thrown details, diagnostics, test reports, evidence, and proof artifacts use only operation, code, counts, duration, and hashes. Endpoint and credential fields remain forbidden.

---

## Chunk 1: Closed Domain, Command Bus, and Headless Proxy Service

### Task 1: Define Plan C application models, identities, results, and ports

**Files:**
- Create: `harmony/shared/src/main/ets/proxy/ProxyModels.ets`
- Create: `harmony/shared/src/main/ets/proxy/ProxyPorts.ets`
- Create: `harmony/shared/src/test/ProxyModels.test.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing closed-model tests**

Cover exact own shapes, cloning, canonical timestamps, safe positive generations, profile/revision/session identity correlation, name bounds, complete `CoreProxyType` reuse, and error privacy. Define this closed error set:

```text
PROXY_PROFILE_UNAVAILABLE
PROXY_RUNTIME_NOT_READY
PROXY_SELECTION_STALE
PROXY_QUERY_FAILED
PROXY_SELECTION_FAILED
PROXY_PERSISTENCE_FAILED
VPN_SESSION_CHANGED
```

Tests must prove no result/error contains endpoint, port, UUID, password, token, transport, certificate, provider payload, URL, config path, or raw native JSON fields.

- [ ] **Step 2: Run shared tests and verify RED**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony"
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: compile failure because the Plan C proxy models/ports do not exist.

- [ ] **Step 3: Implement exact immutable application shapes**

Define:

```ts
interface ActiveProxyProfile {
  profileId: string;
  revisionId: string;      // currentRevision.validatedAt, matching VpnStartRequest.versionId
  revisionHash: string;    // currentRevision.sha256Digest
  configPath: string;
}
interface ProxyRuntimeIdentity {
  profileId: string;
  revisionId: string;
  revisionHash: string;
  sessionId: string | null;
}
interface ProxySelectionRecord {
  profileId: string;
  groupName: string;
  selectedNodeName: string;
  revisionId: string;
  updatedAt: string;
}
interface ProxyGroupSnapshot {
  identity: ProxyRuntimeIdentity;
  generation: number;
  group: CoreProxyGroupSnapshot;
}
```

Add separate closed list/group query results and the required selection result kinds:

```text
APPLIED_NOW
SAVED_FOR_NEXT_START
APPLIED_NOT_PERSISTED
REJECTED
```

`APPLIED_NOW` and `APPLIED_NOT_PERSISTED` carry a confirmed running-session snapshot. `SAVED_FOR_NEXT_START` carries only the confirmed intent record and never a runtime checkmark snapshot. `REJECTED` carries code/retryability/timestamp only. Add clone constructors; exported arrays are never mutable authorities.

The exact service-facing query shapes are:

```ts
type ProxyGroupListQueryResult =
  | { kind: 'SNAPSHOT'; identity: ProxyRuntimeIdentity; generation: number; groups: CoreProxyGroupRef[] }
  | ProxyRejectedResult;
type ProxyGroupQueryResult =
  | { kind: 'SNAPSHOT'; snapshot: ProxyGroupSnapshot }
  | ProxyRejectedResult;
type ProxyReconcileResult =
  | { kind: 'RECONCILED'; profileIdHash: string; revisionHash: string; keptCount: number; deletedCount: number }
  | ProxyRejectedResult;
```

One monotonic safe-positive counter belongs to each `ProxyService`. Every list/group Core request advances it. Every emitted `ProxyGroupSnapshot` carries its exact group-query generation. The service stores only the latest issued generation per `(profileId, revisionId, sessionId|null, groupName)`; stopped and running selects reject every older/different generation.

- [ ] **Step 4: Define ports without platform/entry dependencies**

`ProxyPorts.ets` owns exact interfaces for:

- `ActiveProfileProxyPort.resolve(): Promise<ActiveProxyProfile | undefined>`;
- `CoreProxyPort.loadConfiguration/queryProxyGroups/queryProxyGroup/selectProxy` with the exact Plan B signatures, so `CoreService` structurally implements it;
- `ProxySelectionRepository.listByProfile(profileId)` ordered by group name, `get`, `upsert`, `delete`, `deleteProfile`, and atomic `reconcileProfile`;
- `ProxyIdentityHasher.sha256(value: string): Promise<string>`, which must return exactly 64 lowercase hexadecimal characters;
- `VpnRuntimeSnapshotPort.snapshot(): VpnRuntimeSnapshot` plus `acquireStoppedProxyLease()` returning an exact stopped-state lease or `undefined`; the lease remains held across app-core and repository awaits and blocks `VpnSessionRegistry.beginPending` until released;
- session-bound query/select commands and `VpnProxyCommandHandler`;
- `VpnProxyRuntimeLifecyclePort.activate(request)`, `invalidate(sessionId)`, and `deactivate(sessionId)`.

Pin the public headless service API used by Plan D:

```ts
listGroups(): Promise<ProxyGroupListQueryResult>;
queryGroup(groupName: string): Promise<ProxyGroupQueryResult>;
select(groupName: string, memberName: string, snapshotGeneration: number): Promise<ProxySelectionResult>;
reconcileActiveSelections(): Promise<ProxyReconcileResult>;
```

No port exposes RDB rows, native JSON, config bytes, or entry classes.

- [ ] **Step 5: Run shared tests and verify GREEN**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony"
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
cd "$CMFA_REPO_ROOT"
git diff --check -- \
  harmony/shared/src/main/ets/proxy/ProxyModels.ets \
  harmony/shared/src/main/ets/proxy/ProxyPorts.ets \
  harmony/shared/src/test/ProxyModels.test.ets \
  harmony/shared/Index.ets \
  harmony/shared/src/test/List.test.ets
```

### Task 2: Add the session-bound serialized `VpnProxyCommandBus`

**Files:**
- Create: `harmony/shared/src/main/ets/proxy/VpnProxyCommandBus.ets`
- Create: `harmony/shared/src/test/VpnProxyCommandBus.test.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing lifecycle/race tests**

Cover one exact binding, duplicate bind rejection, exact profile/revision/session matching, serialized concurrent commands, unbound submission, synchronous invalidation, queued-command rejection after epoch change, in-flight drain during awaited deactivate, handler errors, rebind to a later session, and cloned inputs/results. Errors expose only `VPN_SESSION_CHANGED` or another Plan C allowlisted code.

- [ ] **Step 2: Run shared tests and verify RED**

Run the shared Hypium command from Task 1. Expected: missing bus/binding API.

- [ ] **Step 3: Implement epoch-bound serialization**

Use the existing `SerialCommandQueue`. `bind(identity, handler)` installs one handler and monotonically advances an epoch. Every submission captures the epoch and exact raw identity, then rechecks both immediately before and after handler execution. `invalidate(sessionId)` synchronously closes delivery and advances the epoch so queued work rejects. `deactivate(sessionId)` invalidates first and awaits a queue barrier so stop/recovery cannot overlap a running patch. No command or error is logged.

Define these exact command/handler/bus methods:

```ts
interface VpnProxyQueryGroupsCommand { identity: ProxyRuntimeIdentity; generation: number; selectableOnly: boolean; }
interface VpnProxyQueryGroupCommand { identity: ProxyRuntimeIdentity; generation: number; groupName: string; }
interface VpnProxySelectCommand { identity: ProxyRuntimeIdentity; generation: number; groupName: string; memberName: string; }
interface VpnProxyCommandHandler {
  queryGroups(command: VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult>;
  queryGroup(command: VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult>;
  select(command: VpnProxySelectCommand): Promise<ProxySelectionResult>;
}
```

The bus exposes `submitQueryGroups`, `submitQueryGroup`, and `submitSelect` with those exact command/result pairs. Bound identities require a non-null session ID; all generation values are safe positive integers.

- [ ] **Step 4: Run race tests repeatedly and verify GREEN**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony"
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: both runs pass with deterministic command ordering and no timeout-based sleeps.

### Task 3: Implement stopped/running `ProxyService` semantics and reconciliation

**Files:**
- Create: `harmony/shared/src/main/ets/proxy/ActiveProfileProxyResolver.ets`
- Create: `harmony/shared/src/main/ets/proxy/ProxyService.ets`
- Create: `harmony/shared/src/test/ProxyService.test.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing service tests**

Cover:

- no/invalid/inactive profile;
- stopped app-core config load before query after process restart;
- list and group query context using `sha256(profileId)`, revision digest, nil session hash, and increasing generation;
- matching running session queries only through the command bus, never app core;
- STARTING/mismatched/stale VPN identity rejection;
- stopped selection re-querying the same group/member, persisting without calling native `selectProxy`, and returning only `SAVED_FOR_NEXT_START`;
- stale snapshot generation, missing/nested member, query/load/persistence failures;
- running selection delegated wholly to the bound handler;
- revision reconciliation keeping valid pairs, deleting stale pairs, and updating kept records to the active revision;
- serial command behavior and result cloning.

- [ ] **Step 2: Run shared tests and verify RED**

Run the shared Hypium command. Expected: missing resolver/service behavior.

- [ ] **Step 3: Implement active profile resolution**

`ActiveProfileProxyResolver` reads `ProfileRepository.getActiveId/get`, requires `VALID` or `UPDATE_FAILED_USING_VALID`, requires a current revision, and returns its ID, `validatedAt`, lowercase SHA-256 digest, and `ProfileContentStore.resolveCorePath`. Errors are sanitized and contain no raw path/profile values.

- [ ] **Step 4: Implement serialized query routing**

`ProxyService` owns one `SerialCommandQueue` and one monotonic safe generation counter. Only a matching `RUNNING` VPN session sends list/group reads through the bus. `RECOVERING`, `STARTING`, `STOPPING`, `AWAITING_CONSENT`, `ERROR`, an unbound bus, or identity drift returns `PROXY_RUNTIME_NOT_READY` or `VPN_SESSION_CHANGED`; it never falls back to app core. When VPN is truly `STOPPED` it loads the exact active config into app core before querying. It never merges app-core and extension snapshots. Core errors map to the closed Plan C error set without copying native details.

Every stopped list/group/select/reconcile command first acquires `VpnStoppedProxyLease`, verifies its frozen snapshot is `STOPPED` with no active request, and holds it through every core/repository await in that command. Release occurs in `finally`. Task 7 makes `VpnSessionRegistry.beginPending` fail closed while any such lease is live, so VPN start and stopped persistence cannot interleave.

- [ ] **Step 5: Implement stopped selection and reconciliation**

Stopped selection requires the latest service-issued group snapshot generation, re-queries the group, rejects missing or `isGroup` members, then upserts the intent record. It never patches app-core selection and never returns a runtime checkmark. Reconciliation queries the new active runtime, deletes missing group/member records, and updates valid records to the new revision. A repository failure returns a typed failure rather than inventing durable success.

Running selection applies the same latest-generation lookup before creating `VpnProxySelectCommand`; the handler must receive the exact latest service-issued generation for that group. A later list query does not invalidate an already issued group snapshot, while a later query of the same group does.

- [ ] **Step 6: Run shared tests and verify GREEN**

Run shared Hypium twice and `git diff --check` for Task 3 files.

---

## Chunk 2: Versioned RDB Selection Repository and Platform Identities

### Task 4: Migrate RDB v1 to v2 and implement `RdbProxySelectionRepository`

**Files:**
- Modify: `harmony/platform/src/main/ets/rdb/RdbDriver.ets`
- Modify: `harmony/platform/src/main/ets/rdb/HarmonyRdbDriver.ets`
- Modify: `harmony/platform/src/main/ets/rdb/RdbProfileRepository.ets`
- Create: `harmony/platform/src/main/ets/rdb/ProxySelectionRowCodec.ets`
- Create: `harmony/platform/src/main/ets/rdb/RdbProxySelectionRepository.ets`
- Create: `harmony/platform/src/test/RdbProxySelectionRepository.test.ets`
- Create: `harmony/tests/structure/plan-c-rdb-contract.test.mjs`
- Modify: `harmony/platform/src/test/RdbProfileRepository.test.ets`
- Modify: `harmony/platform/src/test/fakes/PlatformFakes.ets`
- Modify: `harmony/platform/src/test/List.test.ets`

- [ ] **Step 1: Write failing repository/migration tests**

Lock this table and no other raw-name location:

```sql
CREATE TABLE IF NOT EXISTS proxy_selections (
  profile_id TEXT NOT NULL,
  group_name TEXT NOT NULL,
  selected_node_name TEXT NOT NULL,
  revision_id TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (profile_id, group_name)
)
```

Cover new DB version 2, v1→v2 migration without profile loss, v0 initialization, unsupported future versions, exact row decoding, sorted list, get/upsert/delete, blank/control/>256-byte fields, canonical timestamp, unknown profile, revision mismatch policy, transaction rollback, and profile deletion removing selections in the same transaction.

- [ ] **Step 2: Run platform and structure tests and verify RED**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony"
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
cd "$CMFA_REPO_ROOT"
node --test harmony/tests/structure/plan-c-rdb-contract.test.mjs
```

- [ ] **Step 3: Extend the driver transaction surface**

Add `DurableProxySelectionRow` and these exact repository operations:

```ts
listByProfile(profileId: string): Promise<ProxySelectionRecord[]>; // group_name ASC
get(profileId: string, groupName: string): Promise<ProxySelectionRecord | undefined>;
upsert(record: ProxySelectionRecord): Promise<void>;
delete(profileId: string, groupName: string): Promise<void>;
deleteProfile(profileId: string): Promise<void>;
reconcileProfile(
  profileId: string,
  newRevisionId: string,
  validPairs: Array<{ groupName: string; selectedNodeName: string }>
): Promise<void>;
```

Mirror the needed row get/upsert/delete/delete-profile/reconcile methods on `RdbTransaction`. Driver list queries use exact `ORDER BY group_name ASC`. `HarmonyRdbTransaction.deleteProfile` deletes `proxy_selections` for the profile before deleting `profiles`. No SQL/error detail contains bind values.

- [ ] **Step 4: Implement explicit migration**

`HarmonyRdbDriver.initialize(2)` performs an additive migration only: create existing tables plus `proxy_selections`, validate both schemas, then set `store.version=2`. It accepts store version `0`, migrates exact version `1`, accepts `2`, and rejects every other nonzero version. If any step after table creation but before the version write fails, `store.version` remains exactly `1`; a later `initialize(2)` reruns idempotently, preserves all profiles, validates the already-created table, and then reaches version `2`. Tests inject that partial-migration failure and retry.

- [ ] **Step 5: Implement the repository**

`RdbProxySelectionRepository.upsert` opens one transaction, rejects a missing profile, null current revision, corrupt current-revision JSON/row decode, or `currentRevision.validatedAt !== record.revisionId`, then writes the row. All of those cases become the same sanitized platform persistence failure without raw values. Only `reconcileProfile` may rewrite kept rows to a new revision ID after the caller supplies runtime-validated `validPairs`; it atomically deletes every other row for that profile and upserts the kept pairs.

- [ ] **Step 6: Run platform/structure tests and verify GREEN**

Run platform Hypium, `plan-c-rdb-contract.test.mjs`, and diff-check all Task 4 files.

### Task 5: Wire the selection repository and SHA-256 identity hasher into `PlatformGraph`

**Files:**
- Create: `harmony/platform/src/main/ets/proxy/HarmonyProxyIdentityHasher.ets`
- Create: `harmony/platform/src/test/HarmonyProxyIdentityHasher.test.ets`
- Modify: `harmony/platform/src/main/ets/PlatformFactory.ets`
- Modify: `harmony/platform/Index.ets`
- Modify: `harmony/platform/src/test/PlatformFactory.test.ets`
- Modify: `harmony/platform/src/test/fakes/PlatformFakes.ets`
- Modify: `harmony/platform/src/test/List.test.ets`

- [ ] **Step 1: Write failing graph/hasher tests**

Cover canonical lowercase SHA-256 for ASCII and Unicode inputs, empty/control rejection, injected digest failures, independent repository instances over one RDB driver, graph cleanup, retry after initialization failure, and no input echo in errors.

- [ ] **Step 2: Run platform tests and verify RED**

Run platform Hypium. Expected: graph lacks selection repository/hasher.

- [ ] **Step 3: Implement the hasher without a new dependency**

Use this exact `@kit.CryptoArchitectureKit` lifecycle over a deterministic local UTF-8 encoder:

```ts
const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
await md.update({ data: utf8Bytes });
const result: cryptoFramework.DataBlob = await md.digest();
```

Convert `result.data` to exactly 64 lowercase hex characters and reject every other digest length. The constructor accepts a narrow `(bytes: Uint8Array) => Promise<Uint8Array>` seam for host tests. No raw input is logged or included in errors.

- [ ] **Step 4: Extend `PlatformGraph`**

Expose `proxySelectionRepository` and `proxyIdentityHasher`. `PlatformFactory` constructs both from the same initialized RDB driver used by profiles. Existing graph close remains the single driver owner. Update dependency fakes mechanically.

- [ ] **Step 5: Run platform tests and verify GREEN**

Run platform Hypium twice and diff-check Task 5 files.

---

## Chunk 3: Extension-Owned Runtime Handler and Replay-before-RUNNING

### Task 6: Implement running selection, rollback, and startup replay handler

**Files:**
- Create: `harmony/shared/src/main/ets/proxy/VpnProxyRuntimeHandler.ets`
- Create: `harmony/shared/src/test/VpnProxyRuntimeHandler.test.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing handler tests**

Cover activate identity resolution, pre-bind replay, deterministic record order, exact session/profile/revision hashes, list/group queries, stale generation/member rejection, successful select/post-query confirmation/persist, persistence failure + confirmed rollback, rollback failure → `APPLIED_NOT_PERSISTED`, stale record deletion, replay record revision update, repository/query/patch failure, concurrent select serialization, invalidate/deactivate races, recovery reactivation, and no raw name/error logging.

- [ ] **Step 2: Run shared tests and verify RED**

Run shared Hypium. Expected: missing runtime handler.

- [ ] **Step 3: Implement exact runtime activation**

The handler receives `ProfileRepository`, `ProxySelectionRepository`, `ProxyIdentityHasher`, `CoreService`, `Clock`, and the shared bus. `activate(request)` re-reads the committed profile, checks `validatedAt===versionId`, hashes profile/session IDs, builds Core query contexts using the revision digest, replays stored records, then binds the bus only after replay succeeds. Missing group/member deletes that record and leaves the config default. Non-stale query/persistence failures reject activation so VPN cannot publish `RUNNING` without a completed replay decision.

`listByProfile` is authoritative and already ordered `group_name ASC`; the handler preserves that order exactly and never re-sorts from an unordered map.

- [ ] **Step 4: Implement running selection and rollback**

For a matching command, re-query the exact group/member, reject nested/missing/stale choices, patch and use the confirmed returned snapshot, then persist. If persistence fails, patch `previousName` back and post-query confirm. Confirmed rollback returns `REJECTED`; failed rollback returns `APPLIED_NOT_PERSISTED` with the actually confirmed applied snapshot. Never claim persistence when the row was not committed.

- [ ] **Step 5: Implement safe deactivate/recovery behavior**

`invalidate` closes bus delivery synchronously. `deactivate` awaits queued/in-flight commands and clears identity. Calling `activate` again for the same recovered session replays durable records before rebinding. A later session epoch cannot receive an earlier result.

- [ ] **Step 6: Run shared tests and verify GREEN**

Run shared Hypium twice and diff-check Task 6 files.

### Task 7: Gate initial start and recovery replay in VPN/entry composition

**Files:**
- Modify: `harmony/shared/src/main/ets/vpn/VpnModels.ets`
- Modify: `harmony/shared/src/main/ets/vpn/VpnPorts.ets`
- Modify: `harmony/shared/src/main/ets/vpn/VpnRuntimeCoordinator.ets`
- Modify: `harmony/shared/src/test/VpnModels.test.ets`
- Modify: `harmony/shared/src/test/VpnRuntimeCoordinator.test.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets`
- Modify: `harmony/entry/src/test/VpnExtensionComposition.test.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnSessionRegistry.ets`
- Modify: `harmony/entry/src/test/VpnSessionRegistry.test.ets`
- Modify: `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets`
- Modify: `harmony/entry/src/test/HarmonyVpnController.test.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/entry/src/test/fakes/PresentationFakes.ets`
- Modify: `harmony/shared/src/main/ets/profile/ProfileApplication.ets`
- Modify: `harmony/shared/src/test/ProfileManagement.test.ets`
- Modify: `harmony/entry/src/ohosTest/ets/test/Phase3RuntimeFlow.test.ets`

- [ ] **Step 1: Write failing replay-order/composition tests**

Prove:

- initial `READY` TUN → proxy activate/replay → notification/running publication order;
- replay failure prevents `RUNNING` and cleans platform/TUN/notification;
- `stop()` invalidates delivery before cleanup and awaits deactivate;
- recovery invalidates the bus, replays after recovered TUN readiness, and only then republishes `RUNNING`;
- extension binds exactly the shared bus installed beside its registry;
- app-side `ProxyService` receives the same bus plus platform repository/hasher;
- refresh/enable reconciliation is serialized and profile deletion is already atomic;
- close/unexpected-failure paths unbind and do not leak a handler.
- `VpnSessionRegistry.beginPending` rejects while a stopped proxy lease is held, succeeds after release, and lease release is idempotent; app stopped commands and VPN start therefore have one explicit synchronization authority.

- [ ] **Step 2: Run shared/entry tests and verify RED**

Run shared and entry Hypium. Expected: missing proxy lifecycle dependency and composition wiring.

- [ ] **Step 3: Add the replay failure code and coordinator lifecycle port**

Add `VPN_PROXY_REPLAY_FAILED` to the exact VPN failure allowlist. Extend coordinator dependencies with `proxyLifecycle`. After initial or recovered TUN readiness, await `activate(request)` before publishing `RUNNING`. On stop/recovery/failure, call synchronous `invalidate` before other asynchronous work and await `deactivate` before TUN destruction. Preserve the existing serialized coordinator queue and cleanup semantics.

- [ ] **Step 4: Wire the extension handler**

`VpnExtensionComposition` creates one `VpnProxyRuntimeHandler` from its `PlatformGraph`, the shared bus, and a fresh `CoreService`. It passes the handler as the coordinator proxy lifecycle. Dispose paths always invalidate/deactivate before closing the graph. Test-only factories receive explicit seams; no process-global fallback silently creates another bus.

- [ ] **Step 5: Wire the app `ProxyService` and reconciliation**

`CoreComposition` owns one shared `VpnProxyCommandBus` beside `VpnSessionRegistry`, constructs `ProxyService` with app graph/core/controller/repository/hasher, and passes it into `ProfileApplication`. `ProfileApplication` exposes the exact Task 1 `listGroups/queryGroup/select/reconcileActiveSelections` methods for Plan D.

After `enable` returns `ENABLED`, the already-loaded active revision is reconciled. After `refresh` returns `UPDATED`, first check that the updated profile is still active, then `ProxyService.reconcileActiveSelections()` loads that revision into app core and reconciles. Add `proxyReconciliation: ProxyReconcileResult | null` to `ProfileApplicationSnapshot`; both paths publish the typed outcome there while leaving the original enable/refresh result union unchanged. A reconciliation failure never rolls back the committed profile. Update every direct `ProfileApplicationDependencies`/constructor site, including `PresentationFakes.ets`.

- [ ] **Step 6: Run complete Plan C module verification**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony"
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

Expected: shared/platform pass completely. Entry has only the two exact pre-existing Plan A failures and no proxy/VPN replay failure. `ohosTest` compiles; execution remains a Plan D device gate.

---

## Chunk 4: Plan C Contracts and Handoff

### Task 8: Lock Plan C privacy, ordering, and package-neutral evidence

**Files:**
- Create: `harmony/tests/structure/plan-c-proxy-selection-contract.test.mjs`
- Create: `docs/harmony/proxy-selection-replay.md`
- Modify: `harmony/tests/structure/phase3-layer-boundary.test.mjs`
- Modify: `harmony/tests/structure/phase4-vpn-contract.test.mjs`

- [ ] **Step 1: Write failing structure/privacy contracts**

Require exact shared/platform/entry ownership, RDB v2 table columns, bus identity/epoch checks, handler rollback kinds, initial/recovery replay-before-`RUNNING` source order, profile-delete selection cleanup, full error allowlists, and the exact `ProfileApplication.listGroups/queryGroup/select/reconcileActiveSelections` Plan D surface. Scan logs/errors/docs/proofs for raw group/node values while allowing the dedicated RDB row fields and in-memory UI models. The new contract also scans `docs/harmony/proxy-selection-replay.md` for absolute/file URLs, HAP/signing paths, signing-material tokens/extensions, device identifiers, subscription data, and raw configuration content using the bounded scanner style from existing compatibility/phase0 contracts.

- [ ] **Step 2: Run focused structure tests and verify RED**

```bash
node --test \
  harmony/tests/structure/plan-c-rdb-contract.test.mjs \
  harmony/tests/structure/plan-c-proxy-selection-contract.test.mjs \
  harmony/tests/structure/phase3-layer-boundary.test.mjs \
  harmony/tests/structure/phase4-vpn-contract.test.mjs
```

- [ ] **Step 3: Write the safe Plan C report**

Document schemas, result kinds, error codes, migration version, host test counts, and replay ordering using counts/hashes only. State that no ArkUI or physical-device success is claimed. Do not include group/node names, endpoints, URLs, config paths, device IDs, or signing material.

- [ ] **Step 4: Run the complete Plan C host gate**

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
  harmony/tests/structure/plan-c-rdb-contract.test.mjs \
  harmony/tests/structure/plan-c-proxy-selection-contract.test.mjs \
  harmony/tests/structure/phase3-layer-boundary.test.mjs \
  harmony/tests/structure/phase4-vpn-contract.test.mjs \
  harmony/tests/structure/phase1-bridge-contract.test.mjs \
  harmony/tests/structure/phase1-arkts-module-boundary.test.mjs \
  harmony/tests/structure/plan-b-proxy-contract.test.mjs \
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

Entry may contain only:

```text
extensionFactoryUsesTheExactInjectedRegistryForUnexpectedFailureCleanup
nonSharedStopResolvesWithoutTouchingTheSharedRegistry
```

`build-phase1-native --validate` is the package-neutral provenance gate. Plan C explicitly excludes fresh `inspect-hap.mjs`, `phase4-package-contract.test.mjs`, `run-phase4-device-proof.mjs`, signed-HAP, and physical-device claims. `entry@ohosTest assembleHap` proves compile/package only, not test execution.

- [ ] **Step 5: Record the Plan D handoff**

Plan C passes when stopped selection is durable, running selection/rollback is confirmed, startup and recovery replay occur before `RUNNING`, and all host/privacy/package-neutral gates pass. The exact Plan D consumer authority is `ProfileApplication.listGroups/queryGroup/select/reconcileActiveSelections`, constructed in `CoreComposition.ets` and pinned by `ApplicationComposition.test.ets`, `PresentationFakes.ets`, and `Phase3RuntimeFlow.test.ets`. It does not claim a node page, a signed current HAP, or real network success. Plan D must still add ArkUI and produce physical-device evidence after automatic signing is regenerated.

---

## Plan C Completion Criteria

1. A stopped selection is validated against the active loaded core, persisted without changing a runtime checkmark, and returned only as `SAVED_FOR_NEXT_START`.
2. A running selection is handled only by the matching extension session, post-query confirmed, then persisted; persistence failure rolls back or returns truthful `APPLIED_NOT_PERSISTED`.
3. RDB version 2 stores raw group/node names only in `proxy_selections`, migrates v1 without profile loss, and deletes selections atomically with profiles.
4. Initial VPN start and every recovery replay durable selections after TUN readiness and before any `RUNNING` publication.
5. Missing/stale replay records are deleted and defaults remain; non-stale replay failures prevent false `RUNNING`.
6. App-core and extension-core snapshots are never merged, session/profile/revision/epoch drift fails closed, and queued commands cannot escape unbind.
7. Shared/platform/entry tests and Plan C structure/privacy contracts pass; Entry adds no failure beyond the two pinned Plan A cases.
8. No log, error, report, proof, or table other than `proxy_selections` contains raw group/node names; no endpoint or credential field is introduced.
