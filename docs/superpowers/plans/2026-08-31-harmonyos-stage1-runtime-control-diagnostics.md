# HarmonyOS Stage 1 Runtime Control and Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver real HarmonyOS network-change recovery, session-scoped Rule/Global/Direct control, and a privacy-safe log center in the production Harmony app.

**Architecture:** Reuse the existing VPN recovery coordinator and authenticated LocalSocket RPC. Add one production NetworkKit adapter, a closed mode API through Go/C/NAPI/RPC, and an Extension-owned bounded JSONL log store read by the UI.

**Tech Stack:** HarmonyOS ArkTS, NetworkKit, CoreFileKit, Mihomo Go core, stable C ABI, Node-API, authenticated LocalSocket RPC, Hypium, Node structure tests.

---

## Chunk 1: Real network events

### Task 1: Bind HarmonyNetworkMonitor to NetworkKit

**Files:**
- Create: `harmony/platform/src/main/ets/network/HarmonyNetworkConnectionDriver.ets`
- Create: `harmony/platform/src/test/HarmonyNetworkConnectionDriver.test.ets`
- Modify: `harmony/platform/src/main/ets/network/HarmonyNetworkMonitor.ets`
- Modify: `harmony/platform/src/main/ets/PlatformFactory.ets`
- Modify: `harmony/platform/src/test/List.test.ets`
- Modify: `harmony/entry/src/main/module.json5`
- Create: `harmony/entry/src/test/NetworkRecoveryIntegration.test.ets`
- Modify: `harmony/entry/src/test/List.test.ets`
- Create: `harmony/tests/structure/stage1-runtime-control-contract.test.mjs`

- [ ] Write failing adapter tests for default net/capability mapping, event forwarding, exact callback registration, non-current net loss, and idempotent unregister.
- [ ] Write failing structure assertions that production factory injects the real driver and the manifest declares `GET_NETWORK_INFO`.
- [ ] Run focused Platform and structure tests and confirm RED.
- [ ] Implement the minimal NetworkKit adapter and monitor stale-event guard.
- [ ] Add an Entry integration test that feeds default-network loss/replacement through `HarmonyNetworkMonitor` into a real `VpnRuntimeCoordinator` and asserts `RUNNING -> RECOVERING -> RUNNING`.
- [ ] Re-run focused tests and confirm GREEN.

## Chunk 2: Current-session tunnel mode

### Task 2: Add the closed native mode contract

**Files:**
- Create: `harmony/core/go/internal/runtimecontrol/mode.go`
- Create: `harmony/core/go/internal/runtimecontrol/mode_test.go`
- Modify: `harmony/core/go/cmd/cmfa_core/main.go`
- Modify: `harmony/core/go/cmd/cmfa_core/main_test.go`
- Modify: `harmony/core/abi/include/cmfa_types.h`
- Modify: `harmony/core/abi/include/cmfa_core.h`
- Modify: `harmony/core/abi/src/cmfa_contract.cpp`
- Modify: `harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp`
- Create: `harmony/entry/src/main/cpp/src/js_runtime_control.cpp`
- Modify: `harmony/entry/src/main/cpp/include/cmfa_napi.h`
- Modify: `harmony/entry/src/main/cpp/src/js_core_module.cpp`
- Modify: `harmony/entry/src/main/cpp/CMakeLists.txt`
- Modify: `harmony/entry/src/main/cpp/types/libentry/Index.d.ts`
- Modify: `harmony/shared/src/main/ets/core/CoreModels.ets`
- Modify: `harmony/shared/src/main/ets/core/CoreService.ets`
- Modify: `harmony/core/src/main/ets/CoreNativeAdapter.ets`
- Modify native and structure contract tests under `harmony/tests/native` and `harmony/tests/structure`.

- [ ] Write failing Go tests for query, all three transitions, invalid input, and closing existing tracked connections in the runtime-control setter itself.
- [ ] Write failing ABI/NAPI tests for closed enums and error propagation.
- [ ] Run focused Go/native/structure tests and confirm RED.
- [ ] Implement the smallest Go → C ABI → NAPI → CoreService path; the Go setter is the single owner of post-switch tracker closure.
- [ ] Re-run focused tests and confirm GREEN.

### Task 3: Carry mode over authenticated RPC

**Files:**
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcModels.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcPayloads.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcBodyCodec.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcPorts.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcServer.ets`
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcRuntimeToolsClient.ets`
- Modify: `harmony/shared/Index.ets`
- Modify corresponding shared RPC tests and `harmony/shared/src/test/List.test.ets`.
- Modify: `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets`
- Modify: `harmony/entry/src/test/VpnExtensionComposition.test.ets`

- [ ] Write failing payload/codec/server/client tests for GET_MODE, SET_MODE, guards, invalid values, stale generation and non-running state.
- [ ] Run Shared and Entry tests and confirm RED.
- [ ] Implement the minimal RPC mode path using the existing authenticated session and guards.
- [ ] Re-run Shared and Entry tests and confirm GREEN.

### Task 4: Show and switch mode on Home

**Files:**
- Create: `harmony/entry/src/main/ets/runtime/RuntimeToolsService.ets`
- Create: `harmony/entry/src/main/ets/components/RuntimeModeCard.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/ApplicationComposition.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Modify: `harmony/entry/src/main/ets/presentation/HomeViewModel.ets`
- Modify: `harmony/entry/src/main/ets/presentation/PresentationModels.ets`
- Modify: `harmony/entry/src/main/ets/pages/HomePage.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify resources and Home/ApplicationComposition tests.

- [ ] Write failing ViewModel tests for initial query, running-only controls, pending guard, successful switch, failed switch and stale response suppression.
- [ ] Run Entry tests and confirm RED.
- [ ] Implement the mode card and wiring with no YAML persistence.
- [ ] Re-run Entry tests and confirm GREEN.

## Chunk 3: Privacy-safe log center

### Task 5: Build the bounded Extension-owned log store

**Files:**
- Create: `harmony/shared/src/main/ets/diagnostics/RuntimeLogModels.ets`
- Modify: `harmony/shared/Index.ets`
- Create: `harmony/platform/src/main/ets/diagnostics/HarmonyRuntimeLogStore.ets`
- Create: `harmony/platform/src/test/HarmonyRuntimeLogStore.test.ets`
- Modify: `harmony/platform/Index.ets`
- Modify: `harmony/platform/src/test/List.test.ets`
- Create: `harmony/entry/src/main/ets/vpn/CoreRuntimeLogCollector.ets`
- Create: `harmony/entry/src/test/CoreRuntimeLogCollector.test.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets`
- Modify: `harmony/entry/src/test/VpnExtensionComposition.test.ets`

- [ ] Write failing tests for sanitization, JSONL decode, size/entry bounds, rotation, corrupt-line tolerance, serial writes, subscription cleanup and final drain.
- [ ] Run Shared, Platform and Entry tests and confirm RED.
- [ ] Implement the store and Extension collector; keep Extension as the only writer.
- [ ] Re-run focused tests and confirm GREEN.

### Task 6: Add the Logs page, filtering and export

**Files:**
- Create: `harmony/platform/src/main/ets/diagnostics/HarmonyRuntimeLogExporter.ets`
- Create: `harmony/platform/src/test/HarmonyRuntimeLogExporter.test.ets`
- Create: `harmony/entry/src/main/ets/presentation/LogsViewModel.ets`
- Create: `harmony/entry/src/test/LogsViewModel.test.ets`
- Create: `harmony/entry/src/main/ets/pages/LogsPage.ets`
- Modify: `harmony/entry/src/main/ets/runtime/RuntimeToolsService.ets`
- Modify: `harmony/entry/src/main/ets/pages/HomePage.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify resources and structure tests.

- [ ] Write failing tests for polling, level/search filtering, copy text, clear, export cancellation/failure and late-result suppression.
- [ ] Run Platform, Entry and structure tests and confirm RED.
- [ ] Implement the page and system save picker export.
- [ ] Re-run focused tests and confirm GREEN.

## Chunk 4: Integration verification and package

### Task 7: Run the complete gate

- [ ] Run `go test -count=1 ./...` from `harmony/core/go`.
- [ ] Run all Harmony structure tests.
- [ ] Run Core, Shared, Platform and Entry module tests through `harmony/hvigorw`.
- [ ] Run `git diff --check` and inspect only this phase's diff without reverting pre-existing changes.
- [ ] Build a fresh signed production HAP through `node harmony/tests/bin/build-hap.mjs`.
- [ ] Record HAP variant, version, path and SHA-256; report any remaining real-device-only network/export checks honestly.
