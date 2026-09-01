# HarmonyOS Profile Proxy Management Merge Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将代理节点管理合并进对应配置详情页，并删除首页独立入口和独立代理路由。

**Architecture:** `Index` 继续拥有唯一 `ProxyViewModel`，把 active-profile eligibility 投影为详情页 primitive state。`ProfileDetailPage` 按需展开 `ProxiesPage` 的 embedded 内容；现有代理查询、测速、选择和一键 VPN 逻辑不复制、不改协议。

**Tech Stack:** ArkTS, ArkUI, Node.js structure tests, Hypium, Hvigor, HDC

**Constraints:** 不新增依赖；不修改 Android；不读取或输出配置名、节点名、订阅地址或 token；保留工作树全部既有改动；仅用 `apply_patch` 编辑；不 commit、不 push。

---

## Chunk 1: Navigation and UI Contract

### Task 1: Lock the merged navigation contract

**Files:**
- Modify: `harmony/tests/structure/phase3-ui-contract.test.mjs`
- Modify: `harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs`
- Modify: `harmony/tests/structure/vpn-local-socket-rpc-contract.test.mjs`
- Modify: `harmony/tests/structure/plan-d-device-proof-contract.test.mjs`
- Modify: `harmony/tests/structure/proxy-delay-device-proof-contract.test.mjs`
- Modify: `harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs`
- Modify: `harmony/entry/src/ohosTest/ets/test/Phase3UiFlow.test.ets`
- Modify: `harmony/entry/src/test/ProxyViewModel.test.ets`

- [ ] **Step 1: Write failing structure assertions**

Require removal of `home.proxy.manage`, `home_proxy_manage`, `home_proxy_manage_disabled`, `AppRoute.PROXIES`, `HomePage.onManageProxies`, and the standalone proxy route branch. Require `detail.proxy.toggle`, resource keys for the detail proxy section, embedded rendering, exact active/detail profile matching, no load while ineligible, profile-id validation inside `ProxyViewModel.load(expectedProfileId)`, immediate empty loading state, and proxy drain on every detail exit.

- [ ] **Step 2: Run RED**

```sh
node --test harmony/tests/structure/phase3-ui-contract.test.mjs harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs harmony/tests/structure/vpn-local-socket-rpc-contract.test.mjs
```

Expected: FAIL because the home entry/standalone route still exists and detail proxy contracts are absent.

### Task 2: Migrate proof navigation contracts before production changes

**Files:**
- Modify: `harmony/tests/bin/run-plan-d-device-proof.mjs`
- Modify: `harmony/tests/bin/run-proxy-delay-device-proof.mjs`
- Modify: `harmony/tests/bin/run-proxy-one-click-vpn-device-proof.mjs`
- Test: `harmony/tests/structure/plan-d-device-proof-contract.test.mjs`
- Test: `harmony/tests/structure/proxy-delay-device-proof-contract.test.mjs`
- Test: `harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs`

- [ ] **Step 1: Change the expected navigation sequence**

Contracts must require `home.profile.manage`, the unique active `profiles.row.*` element, and `detail.proxy.toggle`; they must forbid `home.proxy.manage`. Cleanup navigation must support detail back followed by profiles back before looking for the home VPN action.

- [ ] **Step 2: Run RED against proof contracts**

```sh
node --test harmony/tests/structure/plan-d-device-proof-contract.test.mjs harmony/tests/structure/proxy-delay-device-proof-contract.test.mjs harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs
```

Expected: FAIL because proof runners still hardcode the removed home proxy selector.

## Chunk 2: Detail Proxy Integration

### Task 3: Move the proxy surface into profile detail

**Files:**
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/entry/src/main/ets/pages/HomePage.ets`
- Modify: `harmony/entry/src/main/ets/pages/ProfileDetailPage.ets`
- Modify: `harmony/entry/src/main/ets/pages/ProxiesPage.ets`
- Modify: `harmony/entry/src/main/ets/presentation/ProxyViewModel.ets`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`

- [ ] **Step 1: Remove the home and route surfaces**

Remove the home proxy card, its props/callback, `PROXIES` from `AppRoute`, and the standalone proxy route/open helpers. Keep `HomeViewModel.canManageProxies` as the authoritative eligibility input for the detail projection.

- [ ] **Step 2: Project profile-scoped eligibility**

Add `detailCanManageProxies` and `detailProxyExpanded` primitive states. Recompute eligibility after home/detail updates and initial snapshots using exact `detailState.profile.id === homeState.activeProfile.id`. Ineligible toggle is a no-op and must not call `load()`. Do not collapse or replace the expanded header with disabled copy on transient VPN state changes while the same profile remains active; do close and leave if the active profile identity changes.

- [ ] **Step 3: Add safe expand/collapse lifecycle**

Expand only when eligible, clear old UI state, then call `ProxyViewModel.load(detailProfileId)`. `load` immediately publishes empty `LOADING` before any async delay drain and rejects authoritative profile identity mismatch before group query. Manual back, delete-success navigation intent, active-profile drift and switching detail share one guarded leave promise; composition teardown/error uses `dispose()` to drain. Reset expansion, eligibility and proxy snapshot during teardown without touching unrelated state.

- [ ] **Step 4: Add the detail section**

Render a resource-backed proxy card after configuration operations, with semantic id `detail.proxy.toggle`, disabled/instruction copy for inactive configurations, and embedded proxy content when expanded. Preserve all existing config mutation buttons and feedback.

- [ ] **Step 5: Add embedded rendering**

Refactor `ProxiesPage` to a shared content builder. Embedded mode removes its back/header and outer vertical Scroll/padding so detail owns the only vertical Scroll; keep the horizontal group Scroll. Keep proxy group, node, retry, delay test and activation semantics unchanged.

- [ ] **Step 6: Run GREEN**

Run all targeted UI, proof-runner and `ProxyViewModel` tests until they pass.

## Chunk 3: Verification and Device Delivery

### Task 4: Verify, package, install and exercise the merged flow

**Files:**
- Modify only if verification exposes a scoped regression.

- [ ] **Step 1: Run Entry tests and ohosTest compile**

```sh
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

- [ ] **Step 2: Run all structure contracts**

```sh
node --test harmony/tests/structure/*.test.mjs
```

- [ ] **Step 3: Build signed HAP**

Use the existing signing-isolated production build lane. Require `profilePrepared: true`, `buildExit: 0`, and `unsignedBaselineRestored: true`.

- [ ] **Step 4: Install and verify on the connected device**

Cover-install the signed HAP and launch it. Verify:

- 首页不存在独立“管理代理节点”；
- 管理配置 → 当前配置详情里存在代理节点卡片；
- 详情保持单一纵向 Scroll，展开后横向分组仍可操作，并能显示节点、执行全量测速、选择节点并触发一键 VPN；
- 节点触发 VPN 的瞬态期间，展开内容与“收起”按钮保持可见；
- 手动返回、测速中返回和删除成功返回都不会留下运行中的测速；
- 非当前配置显示先启用说明，不展示其他配置的节点。

- [ ] **Step 5: Final review**

Run spec compliance, code quality and privacy review. Fix every Critical/Important issue and rerun affected verification. Do not commit or push.
