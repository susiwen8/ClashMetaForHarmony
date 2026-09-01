# HarmonyOS Standalone Local Proxy Removal Design

## Context

The current HarmonyOS product exposes two runtime modes on Home: standalone Local proxy and system VPN global capture. The product goal is now VPN-only. Standalone Local proxy adds an expert-only button, state card, profile-mutation locks, one-click transition branches, error states, and device-proof fields that are not useful to the target user.

The underlying implementation cannot be deleted by filename. `harmony/core/go/internal/runtime/local_proxy.go` currently owns both standalone listener startup and the TUN runtime used by the verified system VPN. Native runtime events, `stopRuntime`, and several ABI surfaces are also shared by TUN and self-test infrastructure.

## Decision

Remove standalone Local proxy as a product capability while retaining the diagnostic and TUN-shared lower layers.

After this change:

- Home exposes only configuration, proxy-node management, and VPN global capture.
- `HomeViewState` and `HomeViewModel` no longer expose Local proxy state or actions.
- `ProfileApplication` no longer exposes `startLocal()` or `stopLocal()` to product code.
- Selecting a terminal node has only two paths: start VPN from stopped state, or hot-switch an already running VPN.
- One-click public enums, errors, progress, documentation, runner, schema, and examples no longer contain Local-stop concepts.
- Profile pages no longer show Local-runtime locks or instructions to stop Local proxy.
- The current user guide no longer teaches Local proxy.

## Considered Approaches

### 1. Hide the Home controls only

Smallest change, but it leaves dead product methods, Local-specific state, error contracts, one-click branches, and proof requirements. Rejected because the feature would remain embedded in the product contract.

### 2. Remove the product capability and keep diagnostic/TUN internals

Recommended. It removes every normal user entry point and public product contract while preserving the proven VPN data plane and self-test ABI. This is the smallest boundary that fully satisfies the product request without invalidating Phase 1/2 diagnostics or Phase 4 TUN behavior.

### 3. Remove all Local-named native and Go code

Rejected for this change. `LocalProxy.StartTun()`, `LocalProxy.Stop()`, runtime subscriptions, configuration loading, HTTP/SOCKS listener factories, and ABI snapshots are currently shared by TUN. Removing them requires a separate `TunRuntime` extraction and new full physical-device proof.

## Product and Presentation Changes

### Home

- Delete the Local runtime card, HTTP/SOCKS facts, Local action button, Local error card, and `onLocalAction` callback.
- Narrow `RuntimeStatusCard` to VPN-only.
- Narrow Home action label resolution to VPN-only.
- Keep `Start VPN global capture` as the fallback action and node selection as the recommended one-click entry.

### State and ViewModels

- Delete `LocalProxyState` and `HomeViewState.localProxy`.
- Delete Local pending state, `requestPrimaryAction()`, `requestLocalAction()`, Local action resolution, and Local/VPN mutual-exclusion error mapping from `HomeViewModel`.
- Remove Local-runtime locks from profile list/detail presentation. No replacement VPN lock is introduced because VPN did not previously participate in these Local-only UI locks.

### Resources

- Delete `home_local_*`, Local-only error strings, the Local-stop profile banner, and Local-stop one-click error strings.
- Update Home copy to describe a VPN-only product.
- Keep generic runtime busy and VPN facts/resources.

## Application and One-Click Changes

- Remove public `ProfileApplication.startLocal()` and `stopLocal()` methods.
- Remove `LOCAL` from product runtime mutation ownership.
- Remove the Local-stop precondition from manual VPN startup.
- Remove the Local-running branch, stop/re-query sequence, Local busy helpers, and Local progress publication from one-click selection.
- Keep `LocalRuntimeCoordinator` temporarily as an internal compatibility and profile-mutation guard. Product code will not call its `start()` or `stop()` paths. A future focused refactor may split its mutation lease into a dedicated coordinator.
- Remove `LOCAL_STOP`, `LOCAL_STOP_FAILED`, `STOPPING_LOCAL`, and `proxies_one_click_local_stop_failed` from the public one-click contract.

The resulting node-selection flow is:

1. Reject while VPN is transitional, the retained shared runtime is `STARTING`/`STOPPING`, or another product mutation owns the operation.
2. Hot-switch when VPN is running.
3. Otherwise save the terminal-node selection and start VPN.
4. Publish success only after VPN running and selected-node confirmation.

Only the product `RUNNING -> stopLocalThenSelectAndStartVpn()` branch is removed. The fail-closed guard for shared-runtime transitional states remains because self-test diagnostics still use the retained runtime. Manual VPN startup must likewise map an unexpected diagnostic runtime transition to a generic busy/start failure rather than exposing instructions to stop a deleted product feature.

## Diagnostic and Data-Plane Boundary

The following remain intentionally:

- `CoreDebugPage` and its self-test-only route.
- `CoreService`/`CoreNativeAdapter` diagnostic `startLocal`, stop, snapshot, and subscription surfaces.
- Local-related N-API, C ABI, Go exports, and native host tests required by Phase 1/2 compatibility.
- `runtime.LocalProxy`, including its TUN startup, stop, configuration, socket-protection, trace, and loopback-listener internals.

These retained surfaces are not reachable from the normal `Index` product flow. Their presence does not restore the deleted product feature.

`runtime.LocalProxy.StartTun()` already owns the retained internal handoff: when the shared runtime is running without a TUN listener, `resolveTunBaseOptions()` restarts it with TUN options. Product code therefore does not need a visible “stop Local first” workflow. Native/Go verification must keep coverage for this internal running-runtime-to-TUN restart without reintroducing a Local UI action, public application method, or Local-specific one-click state.

## Device-Proof Contract Migration

The one-click VPN proof currently requires a Local-to-VPN scenario. That scenario must be removed rather than reported as permanently unproven.

- Bump the one-click proof schema from `1.1.0` to `2.0.0`.
- Remove `localToVpnState` from the schema, example, result writer, orchestration result, and aggregate pass/incomplete predicates.
- Remove the Local action selector and Local startup helper from the device runner.
- Preserve stopped-to-VPN, running hot-switch with stable system session, UI recreation/hydration, stop cleanup, target checks, privacy, and fail-closed behavior.
- Keep Phase 4 TCP/UDP/DNS and Local-evidence proof unchanged because those fields validate the shared VPN data plane, not the deleted Home feature.

## Documentation

Update current product documents:

- `docs/harmony/current-version-vpn-user-guide.md`
- `docs/harmony/proxy-one-click-vpn.md`
- `docs/harmony/proxy-one-click-vpn-device-proof.md`
- `docs/harmony/proxy-delay-test.md`

Historical plans, specifications, artifacts, and Phase 0-2 verification records remain unchanged because they document earlier milestones accurately.

## Test Strategy

Use a removal contract as the first failing test. It must reject Local product UI, state, methods, resources, one-click enums, proof fields, and runner selectors while allowing explicitly listed diagnostic/TUN internals.

Then update focused tests in three lanes:

1. UI/presentation/resources and profile-page behavior.
2. Shared application and one-click models.
3. Device runner/schema/docs and structure contracts.

Verification must include focused and full structure suites, ArkTS module tests, Go normal/race/vet, native host suites, fresh HAP packaging, privacy/signing checks, and physical-device UX/proof when a signed install is available.

The retained Go/native suites must specifically continue proving the `LocalProxy.StartTun()` running-runtime restart path and the shared-runtime transitional fail-closed guard.

## Acceptance Criteria

- No Local proxy card, button, address, status, error, or profile lock appears in the normal app.
- No normal product code can call `ProfileApplication.startLocal()` or `stopLocal()`.
- Node selection starts VPN directly from stopped state and hot-switches when running.
- Public one-click types and proof v2 contain no Local-stop state.
- The user guide describes a VPN-only flow.
- Existing TUN/VPN behavior, node import/query/speed test, RPC, recovery, notification, and stop behavior remain verified.
- A fresh HarmonyOS debug HAP is produced; signed-device verification is reported separately if signing is unavailable to the command-line build.

## Risks

- Large existing test fixtures construct `ProfileApplication` with Local coordinator state. They must be updated without deleting shared TUN fakes by name.
- The one-click proof migration is intentionally breaking and must reject the old field rather than silently accept it.
- Disk space is constrained; only exact Git-ignored build and Go caches may be cleaned. Existing proof artifacts must remain intact.
