# HarmonyOS Subscription Refresh Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add refresh-all and power-aware scheduled refresh with per-profile intervals and cross-process serialization.

**Architecture:** Migrate profiles to DB v3/row v2, add a durable leased refresher shared by all remote refresh paths, and register one profile-only WorkScheduler Extension. Foreground UI reloads repository state without restarting running VPN/local cores.

**Tech Stack:** ArkTS, RDB, WorkScheduler, NetworkKit/RequestAgent downloader, Hypium.

---

## Chunk 1: Persistence and lease

### Task 1: Add update interval and v2→v3 migration

**Files:**
- Modify: `harmony/shared/src/main/ets/profile/ProfileModels.ets`
- Modify: `harmony/shared/src/main/ets/profile/ProfilePorts.ets`
- Modify: `harmony/platform/src/main/ets/rdb/RdbDriver.ets`
- Modify: `harmony/platform/src/main/ets/rdb/ProfileRowCodec.ets`
- Modify: `harmony/platform/src/main/ets/rdb/HarmonyRdbDriver.ets`
- Modify: `harmony/platform/src/main/ets/rdb/RdbProfileRepository.ets`
- Modify: `harmony/platform/src/test/ProfileRowCodec.test.ets`
- Modify: `harmony/platform/src/test/RdbProfileRepository.test.ets`
- Modify: `harmony/platform/src/test/RdbProxySelectionRepository.test.ets`
- Modify: `harmony/platform/src/test/List.test.ets`

- [ ] Write failing DB 0/1/2→3 and row 1→2 tests, including default interval 0 and schema validation.
- [ ] Implement additive `auto_update_interval_ms` and `profile_refresh_leases` migration.
- [ ] Run `cd harmony && ./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test`; require `BUILD SUCCESSFUL` and no `Error in`. DB target constant becomes 3, init accepts 0/1/2/3, decoder accepts row 1/2 and encoder writes row 2.

### Task 2: Implement durable leased remote refresh

**Files:**
- Create: `harmony/shared/src/main/ets/profile/LeasedRemoteProfileRefresher.ets`
- Create: `harmony/shared/src/main/ets/profile/RefreshProfilesUseCase.ets`
- Modify: `harmony/shared/src/main/ets/profile/ProfilePorts.ets`
- Modify: `harmony/shared/src/main/ets/profile/RefreshProfileUseCase.ets`
- Modify: `harmony/shared/src/main/ets/profile/ManageProfileUseCases.ets`
- Modify: `harmony/shared/src/main/ets/profile/ProfileApplication.ets`
- Modify: `harmony/shared/Index.ets`
- Create: `harmony/shared/src/test/RefreshProfilesUseCase.test.ets`
- Modify: `harmony/shared/src/test/ProfileManagement.test.ets`
- Modify: `harmony/shared/src/test/List.test.ets`
- Modify lease methods/transactions in `RdbDriver.ets`, `HarmonyRdbDriver.ets` and Platform tests.

- [ ] Write failing tests for 120s CAS acquire, renewal, compare-delete release, expiry recovery, per-profile BUSY, HTTPS/HTTP, due sorting, deadline and result classification.
- [ ] Route manual single, URL-edit auto-refresh, refresh-all and worker through the primitive.
- [ ] Put `ProfileRefreshLeasePort` in shared ports; implement acquire/renew/release via `RdbDriver.transaction`; wrap the existing remote execution inside `LeasedRemoteProfileRefresher`; route `ProfileApplication.refresh`, source-edit auto-refresh, batch and worker through it.
- [ ] Run `cd harmony && ./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test` and the exact Platform command above; require no Hypium `Error in` output.

## Chunk 2: WorkScheduler

### Task 3: Build a profile-only background graph

**Files:**
- Create: `harmony/platform/src/main/ets/ProfileRefreshPlatformFactory.ets`
- Create: `harmony/platform/src/main/ets/background/WorkSchedulerDriver.ets`
- Create: `harmony/platform/ProfileRefresh.ets`
- Modify: `harmony/platform/Index.ets`
- Create: `harmony/platform/src/test/WorkSchedulerDriver.test.ets`
- Modify: `harmony/platform/src/test/List.test.ets`
- Create: `harmony/tests/structure/subscription-refresh-contract.test.mjs`

- [ ] Write failing tests for one persisted 2h network work and idempotent reconcile.
- [ ] Export `createProfileRefreshPlatformGraph`, `WorkSchedulerDriver`, and their ports from `harmony/platform/ProfileRefresh.ets`/`harmony/platform/Index.ets`. Implement only profile repository/content/secret/downloader/core-validation dependencies.
- [ ] In `subscription-refresh-contract.test.mjs`, assert the profile-only barrel/factory never imports `ContinuousTaskDriver`, `HarmonyVpnNotificationDriver`, `backgroundTaskManager`, VPN RPC, or Entry UI modules; register `WorkSchedulerDriver.test.ets` in the Platform List and require the exact Platform command GREEN.

### Task 4: Register and implement SubscriptionRefreshWorkAbility

**Files:**
- Create: `harmony/entry/src/main/ets/background/SubscriptionRefreshWorkAbility.ets`
- Create: `harmony/entry/src/main/ets/background/SubscriptionRefreshComposition.ets`
- Create: `harmony/entry/src/test/SubscriptionRefreshWorkAbility.test.ets`
- Modify: `harmony/entry/src/test/List.test.ets`
- Modify: `harmony/entry/src/main/module.json5`
- Modify: `harmony/tests/structure/phase4-vpn-contract.test.mjs`
- Modify: `harmony/tests/structure/subscription-refresh-contract.test.mjs`

- [ ] Test onWorkStart deadline/drain and onWorkStop cancellation.
- [ ] Register one non-exported workScheduler Extension; update `phase4-vpn-contract.test.mjs` from “exactly one extension” to “exactly one VPN plus one workScheduler” without weakening VPN assertions.
- [ ] Run `cd harmony && ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test` and `node --test harmony/tests/structure/subscription-refresh-contract.test.mjs harmony/tests/structure/phase4-vpn-contract.test.mjs`; require GREEN.

## Chunk 3: UI

### Task 5: Add interval editing, refresh-all and foreground reload

**Files:**
- Modify: `harmony/shared/src/main/ets/profile/ProfileApplication.ets`
- Modify: `harmony/entry/src/main/ets/presentation/PresentationModels.ets`
- Modify: `harmony/entry/src/main/ets/presentation/ProfilesViewModel.ets`
- Modify: `harmony/entry/src/main/ets/pages/ProfilesPage.ets`
- Modify: `harmony/entry/src/main/ets/presentation/ProfileDetailViewModel.ets`
- Modify: `harmony/entry/src/main/ets/pages/ProfileDetailPage.ets`
- Modify: `harmony/entry/src/main/ets/entryability/EntryAbility.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Modify: `harmony/entry/src/test/ProfilesViewModel.test.ets`
- Modify: `harmony/entry/src/test/ProfileDetailViewModel.test.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/entry/src/test/List.test.ets`
- Modify: `harmony/tests/structure/phase3-ui-contract.test.mjs`

- [ ] Write failing UI tests for interval presets, last-success time, batch pending/progress/summary, double-submit and BUSY.
- [ ] Implement `reloadFromRepository()` on foreground and UI flows.
- [ ] Run the exact Shared, Platform and Entry hvigor commands above plus `node --test harmony/tests/structure/subscription-refresh-contract.test.mjs harmony/tests/structure/phase3-ui-contract.test.mjs harmony/tests/structure/phase4-vpn-contract.test.mjs`; then run full structure tests and `git diff --check`.
- [ ] Create `harmony/tests/bin/run-subscription-refresh-device-proof.mjs`, `harmony/tests/fixtures/subscription-refresh-device-proof.schema.json`, `harmony/tests/fixtures/subscription-refresh-device-proof.example.json`, and `harmony/tests/structure/subscription-refresh-device-proof-contract.test.mjs`. Write/run the contract RED first, implement to GREEN, build signed HAP, force-trigger work via system scheduler diagnostics, and require due HTTPS update, HTTP skip, foreground reload, and no VPN restart.
