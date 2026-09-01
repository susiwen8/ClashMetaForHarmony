# HarmonyOS Home Selected Node Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** VPN 运行时在首页显示主要代理组及其最终实际节点，并在节点切换后自动刷新。

**Architecture:** 保持现有 RPC wire contract 不变，先修正 `VpnRpcProxyHandler` 对 selected group 的本地映射，再由 `ProfileApplication` 聚合 `listGroups + queryGroup` 并递归解析 terminal node。`HomeViewModel` 负责 RUNNING-only 查询、one-click 成功刷新与 stale-result 防护；ArkUI 使用 `Index` primitive `@State` 经两级 `@Link` 投影到成员 builder。

**Tech Stack:** ArkTS, HarmonyOS ArkUI, Hypium, Node.js structure contract tests, Hvigor, HDC

**Constraints:** 不新增依赖；不修改 Android；不修改 VPN RPC payload/codec/server protocol；不记录节点名；工作树已有大量既有改动，禁止 reset/revert；按用户约束不 commit、不 push。

---

## File Structure

- `harmony/shared/src/main/ets/vpn/rpc/VpnRpcProxyHandler.ets` — 将 query payload 的 selected member 正确映射为 group 或 terminal。
- `harmony/shared/src/test/VpnRpcProxyHandler.test.ets` — selected group adapter 回归测试。
- `harmony/shared/src/main/ets/profile/ProfileApplication.ets` — 首页所需的只读主要组/final-node 聚合查询。
- `harmony/shared/src/test/ProfileManagement.test.ets` — 聚合查询的直接、嵌套、循环、深度、拒绝、异常与 identity 测试。
- `harmony/shared/src/main/ets/proxy/ProxyService.ets` — 同一 RUNNING identity 复用固定 RPC session generation。
- `harmony/shared/src/test/ProxyService.test.ets` — RUNNING generation 稳定性与 STOPPED 递增回归测试。
- `harmony/entry/src/main/ets/presentation/PresentationModels.ets` — 两个脱敏展示字符串及 clone/create 合同。
- `harmony/entry/src/main/ets/presentation/HomeViewModel.ets` — RUNNING-only 异步刷新、one-click 订阅和 epoch/session 防旧结果。
- `harmony/entry/src/test/fakes/PresentationFakes.ets` — 可控的聚合查询与 one-click operation 测试替身。
- `harmony/entry/src/test/HomeViewModel.test.ets` — 首页行为测试。
- `harmony/entry/src/main/ets/pages/Index.ets` — 两个独立 primitive `@State` 的根投影。
- `harmony/entry/src/main/ets/pages/HomePage.ets` — 两个 primitive `@Link` 的中继。
- `harmony/entry/src/main/ets/components/RuntimeStatusCard.ets` — 成员 builder 动态显示代理组和节点。
- `harmony/entry/src/main/resources/base/element/string.json` — 资源化标签。
- `harmony/tests/structure/phase4-vpn-contract.test.mjs` — RUNNING-only/隐私/资源合同。
- `harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs` — primitive state/link/member-builder ArkUI 合同。

## Chunk 1: Shared Runtime And Application

### Preflight: Preserve overlapping worktree changes

- [ ] **Step 1: Inspect every owned file before editing**

Run `git status --short` and scoped `git diff -- <file>` for every file listed in this plan. Several targets already contain uncommitted work from earlier Harmony tasks.

- [ ] **Step 2: Establish the edit rule**

Use `apply_patch` only on the smallest necessary hunks. Do not format whole files, reorder unrelated code, regenerate resources, reset, checkout, or revert. When a target hunk already contains earlier work, extend that hunk in place and preserve all existing behavior.

### Task 1: Allow selected group members in running RPC query snapshots

**Files:**
- Modify: `harmony/shared/src/test/VpnRpcProxyHandler.test.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcProxyHandler.ets`

- [ ] **Step 1: Write the failing selected-group test**

Add a test that builds a catalog with a top-level group whose selected child is a group, returns a `VpnRpcQueryGroupPayload` where that group node is selected, calls `queryGroup`, and asserts:

```ts
expect(result.kind).assertEqual('SNAPSHOT');
if (result.kind === 'SNAPSHOT') {
  expect(result.snapshot.group.selectedName).assertEqual('Nested');
  expect(result.snapshot.group.nodes[0].isGroup).assertTrue();
  expect(result.snapshot.group.nodes[0].selected).assertTrue();
}
```

Also assert the wire request contains opaque IDs only and does not expose local group/node names.

- [ ] **Step 2: Run RED and verify the expected failure**

Run from `harmony/`:

```sh
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: FAIL because `createGroupSnapshotFromQueryPayload()` resolves `selectedNodeId` only as `TERMINAL` and returns `PROXY_QUERY_FAILED`.

- [ ] **Step 3: Implement the minimal adapter fix**

In `createGroupSnapshotFromQueryPayload()`:

- Resolve `selectedNodeId` as an immediate child without forcing a kind.
- Continue validating membership, ID uniqueness, child kind, and type against `payload.nodes`.
- Mark a node selected when its ID equals the selected child ID regardless of `GROUP`/`TERMINAL`.
- Do not change `createStaticGroupSnapshot()` because selection commands remain terminal-only.

- [ ] **Step 4: Run GREEN**

Run the same shared test command. Expected: BUILD SUCCESSFUL and the new test passes without regressing existing malformed-payload tests.

- [ ] **Step 5: Record a no-commit checkpoint**

Inspect the scoped diff for only the two owned files. Do not commit or push.

### Task 2: Aggregate the primary group and terminal node in ProfileApplication

**Files:**
- Modify: `harmony/shared/src/test/ProfileManagement.test.ets`
- Modify: `harmony/shared/src/main/ets/profile/ProfileApplication.ets`

- [ ] **Step 1: Extend the existing fake only enough to express real query behavior**

In `ProfileManagement.test.ets`, extend `FakeProxyApplication` before adding assertions:

- record each call as both `groupName` and a cloned full `groupPath`;
- add a queued `listGroups()` result surface instead of relying only on the fixed identity;
- keep queued `queryGroup()` results able to carry complete, independently chosen `profileId`, `revisionId`, `revisionHash`, and `sessionId` values;
- preserve all existing defaults so unrelated tests remain unchanged.

These are test-only controls on the dependency boundary; do not add test-only production APIs.

- [ ] **Step 2: Write direct and nested RED tests**

Add tests for the wished-for API (name chosen consistently in test and implementation), returning:

```ts
interface HomeProxySelectionSummary {
  groupName: string;
  nodeName: string;
}
```

Cover:

- first top-level group selected terminal -> `{ groupName: 'Primary', nodeName: 'Node A' }`
- first top-level group selected nested group -> query paths `['Primary']`, then `['Primary', 'Nested']`, and return the nested terminal name while preserving `groupName: 'Primary'`

- [ ] **Step 3: Run RED**

Run the shared module test command. Expected: compile failure or assertion failure because the aggregate API does not exist.

- [ ] **Step 4: Implement the minimal aggregate API**

Add a public read-only method on `ProfileApplication` which:

- initializes if needed;
- gets `listGroups()[0]` without sorting;
- recursively calls `queryGroup(targetName, fullPath)`;
- requires exact selected member match with `selected === true`;
- follows `isGroup` members and returns the final terminal;
- keeps the first group name as the displayed group;
- compares profile/revision/session identity across list and every query;
- catches rejected results and thrown errors and returns `undefined`.

Use a maximum of 16 path segments. Reject a next group already present in the current ancestor path before querying it.

- [ ] **Step 5: Run GREEN for direct/nested cases**

Run the shared module test command. Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Add the next RED edge-case batch**

Add separate tests for:

- empty list and `REJECTED`
- query exception and query `REJECTED`
- empty or missing selected member
- selected member with `selected === false`
- ancestor cycle
- path requiring more than 16 segments
- identity change between list/query or between nested queries

Run the tests and verify at least one fails for the missing guard before extending implementation.

- [ ] **Step 7: Implement edge guards and return clones/value objects**

Return only the two strings. Do not add log/proof/persistence fields.

- [ ] **Step 8: Run GREEN and inspect scoped diff**

Run shared tests again. Inspect only the two owned files. Do not commit or push.

## Chunk 2: Presentation, ArkUI, And Delivery

### Task 3: Publish selected node state safely from HomeViewModel

**Files:**
- Modify: `harmony/entry/src/test/HomeViewModel.test.ets`
- Modify: `harmony/entry/src/test/fakes/PresentationFakes.ets`
- Modify: `harmony/entry/src/main/ets/presentation/PresentationModels.ets`
- Modify: `harmony/entry/src/main/ets/presentation/HomeViewModel.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets` (only the two `createHomeViewState` compatibility call sites in this task)

- [ ] **Step 1: Write RUNNING-only RED tests**

Extend the presentation fake with queued/deferred aggregate results and a real listener surface for one-click snapshots. Add tests proving:

- a HomeViewModel constructed while VPN is already `RUNNING` asynchronously publishes group/node strings;
- `STOPPED`, `AWAITING_CONSENT`, `STARTING`, `RECOVERING`, `STOPPING`, and `ERROR` clear both strings immediately;
- an unavailable/throwing query hides both strings and does not create a Home error card.

- [ ] **Step 2: Run RED**

Run from `harmony/`:

```sh
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: compile/assertion failure because Home state and refresh behavior do not exist.

- [ ] **Step 3: Add minimal presentation state and loader**

Add `selectedProxyGroupName: string` and `selectedProxyNodeName: string` to Home create/clone models, defaulting to empty strings.

Keep the new `createHomeViewState` parameters explicit. In the same GREEN step, update the two existing `Index.ets` initialization/reset calls to pass `'', ''`; do not add ArkUI primitive state or rendering there until Task 4. This keeps the Task 3 entry build green without mixing in the UI projection.

In `HomeViewModel`:

- subscribe to application, VPN registry, and one-click operation;
- only query when application is `READY` and VPN is `RUNNING` with an active session;
- clear immediately outside that condition;
- use a monotonic epoch plus captured session ID before publishing a result;
- swallow query failures into empty display fields without logging payloads;
- unsubscribe all three subscriptions on dispose.

- [ ] **Step 4: Run GREEN for RUNNING-only behavior**

Run entry tests. Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Write stale-result and one-click RED tests**

Cover:

- a slow result from session A cannot overwrite session B;
- a slow result cannot reappear after `STOPPED`;
- dispose invalidates a pending result;
- one-click `IDLE + SUCCEEDED` refreshes;
- `FAILED`, busy progress, or `NONE` does not refresh.

- [ ] **Step 6: Complete epoch/session and one-click behavior**

Implement only what the failing tests require. Follow the existing `ProxyViewModel` one-click catch-up pattern so constructor-time state cannot be missed.

- [ ] **Step 7: Run GREEN and privacy assertions**

Run entry tests and assert the new state fields never contain group path, subscription URL/token, session ID, profile/revision identity, or local listener addresses. Inspect scoped diff. Do not commit or push.

### Task 4: Project the primitive fields through ArkUI and render the card rows

**Files:**
- Modify: `harmony/tests/structure/phase4-vpn-contract.test.mjs`
- Modify: `harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/entry/src/main/ets/pages/HomePage.ets`
- Modify: `harmony/entry/src/main/ets/components/RuntimeStatusCard.ets`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`

- [ ] **Step 1: Write structural RED contracts**

Require:

- two independent `@State private ...: string = ''` fields in `Index`;
- explicit copies after every Home state replacement and initialization/reset;
- `$link` forwarding through `HomePage` into `RuntimeStatusCard`;
- `@Link` declarations in both components;
- a component member `@Builder` for selected proxy rows;
- no component-external builder accepting the dynamic group/node strings;
- resource keys `home_vpn_proxy_group_label` and `home_vpn_proxy_node_label`;
- no log/proof interpolation of either name.

- [ ] **Step 2: Run RED**

```sh
node --test tests/structure/phase4-vpn-contract.test.mjs tests/structure/plan-d-proxy-ui-contract.test.mjs
```

Expected: FAIL on missing primitive projection/resources/member builder.

- [ ] **Step 3: Implement the ArkUI projection and card rows**

- `Index` owns the two primitive states and copies them whenever `homeState` changes or resets.
- `HomePage` relays both using `@Link`.
- `RuntimeStatusCard` receives both using `@Link` and invokes a private member builder.
- The member builder renders exactly two resource-backed fact rows only when both strings are non-empty.
- Render raw group/node names only in `Text(...)`; do not place them in IDs, logs, accessibility IDs, proof, or resource keys.

- [ ] **Step 4: Run GREEN structural tests**

Run the same Node tests. Expected: all pass.

- [ ] **Step 5: Re-run entry module tests**

Expected: BUILD SUCCESSFUL with ArkTS type checking and all Hypium tests passing.

- [ ] **Step 6: Inspect the complete feature diff**

Confirm no VPN RPC protocol file, Android file, unrelated user file, logging/proof code, or dependency manifest changed. Do not commit or push.

### Task 5: Keep running RPC session generation stable

**Files:**
- Modify: `harmony/shared/src/test/ProxyService.test.ets`
- Modify: `harmony/shared/src/main/ets/proxy/ProxyService.ets`

- [ ] **Step 1: Write the failing running-session test**

Change/add a test that executes `listGroups -> queryGroup -> select confirmation -> select -> startDelayTest` under one RUNNING identity and asserts every command sent through the bus uses the same positive generation. Keep existing STOPPED tests asserting successive local-core queries receive increasing generations.

- [ ] **Step 2: Run RED**

Run the shared module tests. Expected: the RUNNING command generations are currently `1, 2, 3...`, proving why the RPC server returns `SESSION_CHANGED` after the first request.

- [ ] **Step 3: Implement one generation per RUNNING identity**

In `ProxyService`, cache the generation together with a cloned complete `ProxyRuntimeIdentity`. For the authenticated cross-process route, bind `VpnRpcClient.activeContext().sessionGeneration` through `VpnProxyCommandBus` and prefer that value over the UI process's local generation history. Add one focused resolver:

- for authenticated RPC `RUNNING`, return the exact bound session generation only when all four identity fields match;
- for an in-process `RUNNING` handler without an RPC generation authority, return the cached generation when all four identity fields match, otherwise call `nextGeneration()` once and cache it;
- for `STOPPED`, call `nextGeneration()` normally and do not reuse a running cache.

Use this resolver in running `listGroups`, `queryGroup`, and selection confirmation. Delay start/read/cancel already carry the snapshot/active-job generation and must remain on that same value.

- [ ] **Step 4: Run GREEN and regression checks**

Run shared tests, then the full RPC structure tests. Expected: no Hypium errors; same-session running values stay fixed; a changed identity gets a new value; stopped values still increase.

- [ ] **Step 5: Rebuild/install and reproduce the original device path**

Start VPN, open the proxy page, and verify it no longer reports `VPN_SESSION_CHANGED`; return Home and verify both selected-proxy labels appear without recording their values.

### Task 6: Full verification, signed build, and device delivery

**Files:**
- Verify only: `.codex-secure/harmony-build-profile.signed.json5`
- Verify only: `.codex-secure/harmony-build-profile.unsigned-baseline.json5`
- Verify/temporarily managed by existing script: `harmony/build-profile.json5`
- Output: `harmony/entry/build/default/outputs/default/entry-default-signed.hap`

- [ ] **Step 1: Run complete automated verification**

Run the module tests from `harmony/`, then run the full structure suite from the worktree root so its repository-relative `harmony/...` fixture paths resolve exactly once:

```sh
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
cd ..
node --test harmony/tests/structure/*.test.mjs
```

Expected: every command exits 0, no Hypium `ERROR`, Node reports zero failed tests.

- [ ] **Step 2: Build the fresh signed HAP and retain the script result**

From worktree root:

```sh
CMFA_GO_MOD_CACHE="$(go env GOMODCACHE)"
GOMODCACHE="$CMFA_GO_MOD_CACHE" node .omx/task16-build-signed-production.mjs
```

Expected: signed production HAP at `harmony/entry/build/default/outputs/default/entry-default-signed.hap`.

- [ ] **Step 3: Verify signing profile restoration**

Read the build script's final JSON result without printing signing file contents. Require:

- `profilePrepared: true`
- `buildExit: 0`
- `unsignedBaselineRestored: true`

Then run from `harmony/`:

```sh
node --test tests/structure/signing-isolation.test.mjs
```

Expected: exit 0. The build script proves `harmony/build-profile.json5` restoration; the structure test separately proves no secret or machine-path leakage. Do not print or diff the contents of either `.codex-secure` profile.

- [ ] **Step 4: Install if the connected device is available**

Use `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc` to list targets, then install the signed HAP on the already-authorized unlocked device. If no target is present, report that device-only step as the sole remaining external verification instead of changing code.

- [ ] **Step 5: Device acceptance without leaking names**

Confirm VPN start, home rows visible, one-click switch refresh, and stop hides rows. Record only pass/fail counts; never output actual group/node names.

- [ ] **Step 6: Final review**

Run a full spec-compliance review, then a code-quality/security/privacy review. Fix every Critical/Important issue and re-run affected verification before reporting completion.
