# HarmonyOS Standalone Local Proxy Removal Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove standalone Local proxy from the normal HarmonyOS product, one-click VPN contract, and current documentation without breaking diagnostic ABI or the TUN-shared runtime.

**Architecture:** Narrow the product to VPN-only at the entry/presentation/application boundaries. Retain `LocalRuntimeCoordinator`, low-level Local APIs, ABI, and Go `LocalProxy` only where they support self-test, mutation safety, or TUN. Migrate one-click device proof to schema v2 without the retired Local-to-VPN scenario.

**Tech Stack:** ArkTS/ArkUI, Node.js `node:test` structure contracts, JSON Schema, Node device runner, Go/mihomo runtime, C++ N-API, Hvigor/HarmonyOS HAP packaging.

---

## Chunk 1: Removal Contract and Red Baseline

### Task 1: Add the product-removal contract

**Files:**

- Create: `harmony/tests/structure/local-proxy-product-removal-contract.test.mjs`
- Reference: `docs/superpowers/specs/2026-08-29-harmonyos-remove-local-proxy-design.md`

- [ ] Add a structure test that rejects `home.local.action`, `onLocalAction`, `requestLocalAction`, `HomeViewState.localProxy`, user-facing `startLocal/stopLocal`, Local resource keys, Local profile locks, `LOCAL_STOP`, `LOCAL_STOP_FAILED`, `STOPPING_LOCAL`, `localToVpnState`, and runner Local selectors/helpers.
- [ ] Scope negative assertions to product files so `CoreDebugPage`, `CoreService`, `CoreNativeAdapter`, N-API/ABI, Go `LocalProxy`, self-test contracts, and retained `LocalRuntimeCoordinator` references/wiring in `CoreComposition`, `ProfileApplication`, and `ManageProfileUseCases` remain allowed.
- [ ] Add positive assertions that Home still exposes `home.vpn.action`, one-click still supports stopped start and running hot-switch, and the proof declares schema `2.0.0`.
- [ ] Run `node --test harmony/tests/structure/local-proxy-product-removal-contract.test.mjs`.
- [ ] Confirm RED failures are caused by the current Local product surfaces and proof v1 fields, not syntax or missing fixtures.

## Chunk 2: VPN-Only UI and Presentation

### Task 2: Remove Home Local controls and state

**Files:**

- Modify: `harmony/entry/src/main/ets/pages/HomePage.ets`
- Modify: `harmony/entry/src/main/ets/components/RuntimeStatusCard.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/entry/src/main/ets/presentation/PresentationModels.ets`
- Modify: `harmony/entry/src/main/ets/presentation/HomeViewModel.ets`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Test: `harmony/entry/src/test/HomeViewModel.test.ets`
- Test: `harmony/entry/src/test/PresentationModels.test.ets`
- Test: `harmony/entry/src/test/List.test.ets`

- [ ] Update Home/Presentation tests first to require a VPN-only `HomeViewState` and no Local command API.
- [ ] Run the focused entry module test and confirm RED against the current Local fields/methods.
- [ ] Delete the Local card, button, callback, addresses, errors, pending state, action resolver, and Local/VPN mutual-exclusion mapping.
- [ ] Narrow `RuntimeStatusCard` and Home action-label logic to VPN-only.
- [ ] Update Home title/subtitle and remove Local-only resources while preserving generic busy/VPN resources.
- [ ] Run focused entry tests and confirm GREEN.

### Task 3: Remove Local-only profile locks and node presentation states

**Files:**

- Modify: `harmony/entry/src/main/ets/presentation/ProfilesViewModel.ets`
- Modify: `harmony/entry/src/main/ets/presentation/ProfileDetailViewModel.ets`
- Modify: `harmony/entry/src/main/ets/pages/ProfilesPage.ets`
- Modify: `harmony/entry/src/main/ets/components/ProfileListItem.ets`
- Test: `harmony/entry/src/test/ProfilesViewModel.test.ets`
- Test: `harmony/entry/src/test/ProfileDetailViewModel.test.ets`

- [ ] Update focused tests first to remove Local-only profile locks.
- [ ] Run focused entry tests and confirm RED.
- [ ] Remove `actionsLockedByRuntime`, `areProfileActionsLocked`, and the locked banner/opacity guard.
- [ ] Run focused entry tests and confirm GREEN.

## Chunk 3: Application and One-Click Contract

### Task 4: Remove public Local application commands

**Files:**

- Modify: `harmony/shared/src/main/ets/profile/ProfileApplication.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets` only if constructor wiring can be narrowed without removing the internal coordinator
- Test: `harmony/shared/src/test/ProfileManagement.test.ets`
- Test: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Test: `harmony/entry/src/test/fakes/PresentationFakes.ets`

- [ ] Update tests first to require absence of product `startLocal()/stopLocal()` and direct stopped-to-VPN selection.
- [ ] Add/retain a test that shared runtime `STARTING`/`STOPPING` fails closed with a generic busy/start failure.
- [ ] Run focused shared/entry tests and confirm RED.
- [ ] Delete public Local commands, Local mutation ownership, Local busy helpers, Local-specific manual VPN error, and the Local-running one-click stop/re-query branch.
- [ ] Keep `LocalRuntimeCoordinator` wiring and mutation leases; do not delete its file or self-test coverage.
- [ ] Keep shared-runtime transitional guards.
- [ ] Run focused shared/entry tests and confirm GREEN.

### Task 5: Close the one-click public enums

**Files:**

- Modify: `harmony/shared/src/main/ets/proxy/ProxyOneClickVpnModels.ets`
- Modify: `harmony/shared/src/main/ets/vpn/VpnModels.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcClient.ets`
- Modify: `harmony/entry/src/main/ets/presentation/ProxyPresentationModels.ets`
- Modify: `harmony/entry/src/main/ets/presentation/ProxyViewModel.ets` if type narrowing requires it
- Modify: `harmony/entry/src/main/ets/pages/ProxiesPage.ets`
- Modify: `harmony/entry/src/main/ets/components/SafeErrorCard.ets`
- Modify: `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets`
- Test: `harmony/shared/src/test/ProxyOneClickVpnModels.test.ets`
- Test: `harmony/entry/src/test/ProxyPresentationModels.test.ets`
- Test: `harmony/entry/src/test/ProxyViewModel.test.ets`

- [ ] Update model/presentation tests first so allowed failures/stages exclude `LOCAL_STOP`, `LOCAL_STOP_FAILED`, and `STOPPING_LOCAL`.
- [ ] Run focused tests and confirm RED.
- [ ] Remove Local-only enums, constructors, error-resource allowlists, RPC/controller mappings, page progress/error branches, and test cases.
- [ ] Keep `proxies_error_runtime_not_ready`; it is still required for stopped/running proxy routing.
- [ ] Preserve VPN permission, profile, start, stopped-before-running, confirmation timeout, session changed, selection, and persistence failures.
- [ ] Run focused tests and confirm GREEN.

## Chunk 4: Proof v2 and Current Documentation

### Task 6: Migrate one-click device proof to schema v2

**Files:**

- Modify: `harmony/tests/fixtures/proxy-one-click-vpn-device-proof.schema.json`
- Modify: `harmony/tests/fixtures/proxy-one-click-vpn-device-proof.example.json`
- Modify: `harmony/tests/bin/run-proxy-one-click-vpn-device-proof.mjs`
- Modify: `harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs`
- Modify: `docs/harmony/proxy-one-click-vpn-device-proof.md`

- [ ] Update contract tests first to require schema `2.0.0`, reject `localToVpnState`, and reject the Local selector/helper in the runner.
- [ ] Run the one-click structure contract and confirm RED.
- [ ] Remove the field from required/properties/pass/incomplete shapes, the example, writer, orchestration result, cleanup fallbacks, injected seams, selector, parser, and Local-start helper.
- [ ] Preserve stopped-to-VPN, hot-switch same-session, recreation/hydration, target validation, cleanup, privacy, and fail-closed tests.
- [ ] Run the one-click structure contract and confirm GREEN.

### Task 7: Update product docs and exact-doc contracts

**Files:**

- Modify: `docs/harmony/current-version-vpn-user-guide.md`
- Modify: `docs/harmony/proxy-one-click-vpn.md`
- Modify: `docs/harmony/proxy-delay-test.md`
- Modify: `harmony/tests/structure/phase3-ui-contract.test.mjs`
- Modify: `harmony/tests/structure/phase4-vpn-contract.test.mjs`
- Modify: `harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs`
- Modify: `harmony/tests/structure/proxy-delay-contract.test.mjs`

- [ ] Update structure tests first to require VPN-only Home and to reject current Local product copy/semantic IDs.
- [ ] Run the focused structure set and confirm RED.
- [ ] Delete Local instructions and renumber the current user guide; keep the import, speed test, one-click VPN, hot-switch, status, stop, and troubleshooting flow.
- [ ] Remove Local stages/errors/order from the one-click contract and remove `local runtime changes` from the delay lifecycle wording.
- [ ] Keep historical specs, plans, artifacts, and Phase 0-2 milestone documents unchanged.
- [ ] Run the focused structure set and confirm GREEN.

## Chunk 5: Integration and Verification

### Task 8: Run complete automated verification

**Files:**

- Verify only; fix failures in the owning files above.

- [ ] Run `node --test harmony/tests/structure/*.test.mjs`.
- [ ] From `harmony`, run shared, platform, core, and entry debug module tests with `./hvigorw --mode module -p module=<module>@default -p product=default -p buildMode=debug test`.
- [ ] Run the entry `ohosTest` assembly required by the existing verification docs.
- [ ] From `harmony/core/go`, run `go test -count=1 ./...`.
- [ ] Run `go test -tags with_gvisor -race -count=1 ./...`.
- [ ] Run `go vet ./...`.
- [ ] Run native host cases for contract, TUN contract, mihomo backend, N-API environment, proxy, and TUN.
- [ ] Run `go test -count=1 ./internal/runtime -run '^TestTunUpgradeStopsLocalRuntimeBeforeRestart$'` to prove the retained `LocalProxy.StartTun()` running-runtime restart owner.
- [ ] Run the shared ArkTS suite containing `LocalRuntimeCoordinatorTest/stableTransitionalSnapshotsRejectCommandsWithoutExtraCoreCalls` and the new `ProfileApplication` generic busy assertion to prove shared-runtime transitional fail-closed behavior.
- [ ] Run `git diff --check` and the signing-isolation contract.

### Task 9: Build and inspect a fresh HarmonyOS package

**Files:**

- Regenerate ignored output under `harmony/entry/build/` and `harmony/artifacts/`.
- Do not change checked-in signing configuration.

- [ ] Run `node harmony/tests/bin/build-phase1-native.mjs --out harmony/artifacts/phase1-native-provenance.json` and its validation mode.
- [ ] Run the project HAP build lane for `entry@default / default / debug`.
- [ ] Verify native libraries and package inspection report no stub production backend.
- [ ] Record version `1.0.0`, version code `1000000`, exact HAP path, signed/unsigned status, and whether release metadata changed.
- [ ] If a usable signed HAP and connected device are available, install it and verify Home has no Local proxy surface, node selection starts VPN, hot-switch preserves the system session, Stop clears the VPN icon, and proof v2 passes.
- [ ] If command-line signing is unavailable, report physical-device installation/proof as the only remaining external verification gap; do not alter checked-in unsigned profiles.

## Execution Notes

- The worktree already contains extensive user-owned changes. Do not revert, reset, or broadly reformat them.
- Do not delete `local_proxy.go`, `LocalRuntimeCoordinator.ets`, Local self-test/native ABI surfaces, or Phase 4 Local evidence by name.
- Do not expose subscriptions, nodes, device identity, signing material, proof endpoints, or raw payloads.
- No commits or pushes are part of this task. Each lane must leave a scoped, reviewable diff and report its verification evidence to the leader.
