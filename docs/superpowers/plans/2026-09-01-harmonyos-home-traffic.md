# HarmonyOS Home Traffic Statistics Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce correct bidirectional TUN byte counters and show shared current-session speed/totals on Home and the VPN notification.

**Architecture:** Correct TX/RX at the Go tunnel boundary, then extract the existing notification poller into one composition-owned monitor. Controller owns monitor lifecycle; notification and Home consume the same samples.

**Tech Stack:** Go, Mihomo tunnel interfaces, ArkTS RPC, Hypium, ArkUI.

---

## Chunk 1: Correct counters

### Task 1: Count successful TCP and UDP bytes in both directions

**Files:**
- Modify: `harmony/core/go/internal/runtime/tun_trace.go`
- Modify: `harmony/core/go/internal/runtime/tun_trace_test.go`
- Modify: `harmony/core/go/internal/runtime/snapshot.go` if naming/docs require it

- [ ] Write failing Go tests for TCP Read→TX, TCP Write→RX, UDP Data→TX, UDP WriteBack→RX, short writes, errors/zero bytes, concurrency, and session reset.
- [ ] Run `go test -race -count=1 ./internal/runtime` and confirm RED.
- [ ] Add overflow-safe recorder increments and wrapper methods without storing payloads.
- [ ] Re-run race tests and confirm GREEN.

## Chunk 2: One monitor

### Task 2: Extract the generic traffic monitor

**Files:**
- Create: `harmony/entry/src/main/ets/vpn/VpnTrafficMonitor.ets`
- Create: `harmony/entry/src/test/VpnTrafficMonitor.test.ets`
- Modify: `harmony/entry/src/test/List.test.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnTrafficNotificationCoordinator.ets`
- Modify: `harmony/entry/src/test/VpnTrafficNotificationCoordinator.test.ets`

- [ ] Write failing monitor tests for one poller, first sample, elapsed-time rates, source failure, counter/time rollback, session switch, stale response, stop and dispose.
- [ ] Move source/clock/scheduler/generation ownership into the monitor and adapt notification as a subscriber.
- [ ] Register the new suite in `List.test.ets`; run `cd harmony && ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test`; require no `Error in`.

### Task 3: Wire monitor through composition and controller

**Files:**
- Modify: `harmony/entry/src/main/ets/bootstrap/ApplicationComposition.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Modify: `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/entry/src/test/HarmonyVpnController.test.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/entry/src/main/ets/presentation/HomeViewModel.ets`
- Modify: `harmony/entry/src/test/HomeViewModel.test.ets`

- [ ] Write failing tests for controller start/stop lifecycle and ready-state read-only port exposure.
- [ ] Before implementation create `harmony/tests/structure/home-traffic-contract.test.mjs`; assert RED because Home/Index lack the port, and assert Home/HomeVM never import NotificationKit or call `refreshTrafficCounters`/`GET_SNAPSHOT`.
- [ ] Create one monitor in CoreComposition, inject lifecycle into controller, expose `VpnTrafficMonitorReadPort` through `ApplicationCompositionReadyState`, and pass it `Index → HomeViewModel`.
- [ ] Run the Entry command and `node --test harmony/tests/structure/home-traffic-contract.test.mjs`; require GREEN.

## Chunk 3: Home presentation

### Task 4: Add Home traffic state and card

**Files:**
- Modify: `harmony/entry/src/main/ets/presentation/PresentationModels.ets`
- Modify: `harmony/entry/src/main/ets/presentation/HomeViewModel.ets`
- Create: `harmony/entry/src/main/ets/components/HomeTrafficCard.ets`
- Modify: `harmony/entry/src/main/ets/pages/HomePage.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Modify: `harmony/entry/src/test/HomeViewModel.test.ets`
- Modify: `harmony/entry/src/test/List.test.ets`
- Create: `harmony/tests/structure/home-traffic-contract.test.mjs`
- Create: `harmony/tests/bin/run-home-traffic-device-proof.mjs`
- Create: `harmony/tests/fixtures/home-traffic-device-proof.schema.json`
- Create: `harmony/tests/fixtures/home-traffic-device-proof.example.json`
- Create: `harmony/tests/structure/home-traffic-device-proof-contract.test.mjs`

- [ ] Write failing state/ViewModel tests for RUNNING, transient unavailable, RECOVERING, STOPPED, stale sessions and privacy.
- [ ] Implement deterministic byte formatting and card semantics.
- [ ] Run Entry/structure tests.
- [ ] Write `home-traffic-device-proof-contract.test.mjs` first and confirm RED; implement the exact runner/schema/example files above, then rerun and require GREEN. Reuse `harmony/traffic-probe` controlled upload/download and persist only rate/total monotonic booleans and notification/Home selector counts.
- [ ] Run Go race tests, Entry hvigor tests, `node --test harmony/tests/structure/home-traffic-contract.test.mjs`, then full structure tests.
- [ ] Build signed HAP with the same provenance/secure commands from the VPN ownership plan.
- [ ] Run `node harmony/tests/bin/run-home-traffic-device-proof.mjs --out harmony/artifacts/home-traffic-device-proof.json`; require both TX/upload and RX/download monotonic and Home/notification agreement.
