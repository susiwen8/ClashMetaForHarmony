# HarmonyOS Phase 4 VPN/TUN and Global Traffic Capture Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver an ordinary third-party HarmonyOS 6.x HAP that captures external-app TCP, UDP, DNS, IPv4, and IPv6 traffic through `VpnExtensionAbility`, `sing-tun` gVisor, and the existing mihomo runtime while retaining the loopback HTTP/SOCKS listeners.

**Architecture:** `entry` owns VPN consent and `VpnConnection`; platform-neutral lifecycle policy lives in `shared`; `core` passes only an owned integer fd and immutable options through Node-API and an append-only C ABI to Go. The Go backend constructs mihomo's pinned `listener/sing_tun` listener on the duplicated fd, instruments TUN ingress before delegating to the same mihomo tunnel used by local listeners, and exposes redacted correlated events and counters. A separately signed probe HAP with a distinct bundle name provides the physical-device proof.

**Tech Stack:** HarmonyOS 6.1 / API 20+ Stage model; ArkTS/ArkUI; NetworkKit `VpnExtensionAbility`; background continuous task; Node-API; C++17; append-only C ABI; Go 1.26; mihomo `v1.19.29`; `sing-tun v0.4.21` with `with_gvisor`; Node.js contract/proof runners; Hypium; Hvigor/ohpm; AArch64 OHOS toolchain.

**Design spec:** `docs/superpowers/specs/2026-08-16-harmonyos-phase4-vpn-tun-design.md`

---

## Delivery boundaries

- Work only in `harmony/**`, `docs/harmony/**`, and this plan. Do not modify Android modules or Android release metadata.
- Preserve all pre-existing Phase 1/2/3 worktree changes. Never reset, restore, clean, or overwrite unrelated edits.
- Apply @superpowers:test-driven-development to each behavior: write one focused failing test, run and read the expected failure, implement the minimum behavior, then rerun focused and regression lanes.
- Use only public ordinary-application APIs. Never request `ohos.permission.MANAGE_VPN`, `ohos.permission.MANAGE_SETTINGS`, `ohos.permission.ENTERPRISE_MANAGE_NETWORK`, or enterprise/device-owner privileges.
- Preserve `targetSdkVersion: 6.1.0(23)`, `compatibleSdkVersion: 6.0.0(20)`, `runtimeOS: HarmonyOS`, the arm64 production ABI, current signing isolation, and the Phase 1/2 self-test separation.
- Add no third-party dependency. `sing-tun v0.4.21`, its gVisor dependency, and mihomo `v1.19.29` are already pinned.
- Production must never package the probe bundle, probe resources, test control surface, certificates, keystores, passwords, device serial, subscription secrets, or clear probe DNS labels.
- `Running` is event-confirmed live state, never persisted optimism. Process death and reboot resolve to `Stopped` and require manual restart.
- “Local proxy” means the explicit loopback HTTP/SOCKS listeners. “VPN global capture” means TUN capture. Do not claim an OS global HTTP proxy setting.
- A simulator, host test, counter increase, local listener request, or request from the excluded production bundle cannot satisfy the independent physical-phone proof gate.
- Every implementation task ends with a narrow Lore commit. Before each commit run the focused lane and `git diff --check`; do not include `.omx/`, lockfiles created only by local tooling, or signing material.

## File responsibility map

### Shared VPN domain

| File | Single responsibility |
| --- | --- |
| `harmony/shared/src/main/ets/vpn/VpnModels.ets` | Immutable VPN config, state, error, event, handle, and snapshot types plus validation/cloning helpers. |
| `harmony/shared/src/main/ets/vpn/VpnPorts.ets` | UI controller, platform session, TUN runtime, network recovery, notification, profile-resolution, clock, and scheduler ports. |
| `harmony/shared/src/main/ets/vpn/VpnRuntimeCoordinator.ets` | Serialize one extension-owned VPN session, enforce state transitions, rollback order, recovery, and idempotent stop. |
| `harmony/shared/src/test/VpnModels.test.ets` | Lock config validation, redaction, clone isolation, and session-correlation rules. |
| `harmony/shared/src/test/VpnRuntimeCoordinator.test.ets` | Lock lifecycle, rollback, late-event rejection, cancellation, and bounded recovery using fakes. |

### Core and native bridge

| File | Single responsibility |
| --- | --- |
| `harmony/core/src/main/ets/CoreTunRuntime.ets` | Implement `TunRuntimePort`, transfer the borrowed Harmony fd once, and map native snapshots/events into shared values. |
| `harmony/core/abi/include/cmfa_types.h` | Append fixed-size TUN options, state, counters, ingress trace, and snapshot types. |
| `harmony/core/abi/include/cmfa_host.h` | Append the bounded synchronous socket-protection callback contract. |
| `harmony/core/abi/include/cmfa_core.h` | Export TUN start/stop/snapshot/trace retrieval without exposing Harmony objects. |
| `harmony/core/abi/src/cmfa_contract.cpp` | Validate ABI sizes/fd/options, duplicate and close fd ownership exactly once, serialize backend calls, and deliver events. |
| `harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp` | Adapt the neutral TUN ABI to Go exports and relay protection callbacks. |
| `harmony/entry/src/main/cpp/src/js_tun.cpp` | Decode TUN JS options, own async work, encode snapshots/traces, and release N-API references on shutdown. |
| `harmony/entry/src/main/cpp/src/js_core_module.cpp` | Register only the new TUN functions on the existing addon export object. |
| `harmony/core/go/internal/runtime/tun.go` | Construct/close the fd-backed mihomo sing-tun listener with gVisor and no route mutation. |
| `harmony/core/go/internal/runtime/tun_trace.go` | Emit bounded redacted ingress records, linked mihomo observations, and monotonic counters. |
| `harmony/core/go/internal/runtime/protect.go` | Invoke the host protection hook before API 20/21 outbound connects and fail closed on rejection/timeout. |
| `harmony/core/go/cmd/cmfa_core/main.go` | Export the TUN C surface and keep one shared local-proxy/mihomo runtime. |

### HarmonyOS lifecycle and UI

| File | Single responsibility |
| --- | --- |
| `harmony/platform/src/main/ets/network/HarmonyNetworkMonitor.ets` | Translate NetworkKit default-network availability/loss into a fakeable recovery port. |
| `harmony/platform/src/main/ets/background/HarmonyVpnNotificationDriver.ets` | Own continuous-task notification start/stop/cancellation for one session. |
| `harmony/entry/src/main/ets/vpn/VpnSessionRegistry.ets` | Hold process-local session snapshot subscriptions and reject late session updates. |
| `harmony/entry/src/main/ets/vpn/HarmonyVpnConnectionDriver.ets` | Create/protect/destroy the one platform `VpnConnection` and translate the validated config. |
| `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets` | Start/stop the VPN extension with exactly three non-secret Want parameters. |
| `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets` | Construct extension-owned adapters/coordinator and resolve one exact committed profile version. |
| `harmony/entry/src/main/ets/vpn/CmfaVpnExtensionAbility.ets` | Resolve the exact committed profile version and own the coordinator for the extension lifetime. |

### Independent proof lane

| File | Single responsibility |
| --- | --- |
| `harmony/traffic-probe/**` | Standalone DevEco project with a distinct application identity that produces direct TCP/UDP/DNS probes. |
| `harmony/tests/bin/phase4-origin.mjs` | Controlled TCP/UDP/DNS origin with generated opaque flow correlation. |
| `harmony/tests/bin/run-phase4-device-proof.mjs` | Build/sign/install both HAPs, drive physical-device checks, correlate evidence, redact, and write the proof. |
| `harmony/tests/fixtures/phase4-device-proof.schema.json` | Closed Phase 4 proof contract. |
| `harmony/tests/structure/phase4-*.test.mjs` | Lock manifest, ABI/build, probe isolation, package, runner, and proof-schema constraints. |

## Chunk 1: Contracts and data plane

### Task 1: Lock the Phase 4 build tags and proof contract

**Files:**
- Create: `harmony/tests/structure/phase4-proof-schema.test.mjs`
- Create: `harmony/tests/fixtures/phase4-device-proof.schema.json`
- Create: `harmony/tests/fixtures/phase4-device-proof.example.json`
- Modify: `harmony/tests/structure/go-ohos-build-contract.test.mjs`
- Modify: `harmony/tests/bin/build-phase1-native.mjs`
- Modify: `harmony/tools/build-go-ohos-probe.mjs`

- [ ] **Step 1: Write the failing gVisor build-contract test**

  Extend `go-ohos-build-contract.test.mjs` to require the production build invocation to pass exactly `-tags ohos,with_gvisor`, preserve `GOOS=linux`, `GOARCH=arm64`, `CGO_ENABLED=1`, and use only the pinned OHOS Clang toolchain. Add a negative fixture proving an `ohos`-only build is rejected.

- [ ] **Step 2: Write the failing closed proof-schema test**

  Define an inline valid Phase 4 object in the test and assert schema version `4.0.0` requires: redacted device identity, production/probe distinct bundle names and SHA-256 values, HAP/native hashes, core version, exact route/DNS/MTU assertions, TCP/UDP/DNS/IPv4/optional-IPv6 results, local HTTP/SOCKS results, notification/background/recovery/stop results, TUN counters, and trace/core-event pairs sharing `sessionId` plus `traceId`. Each capture trace must have `ingress: "tun"`; local listener evidence must use `local-http` or `local-socks`. Set `additionalProperties: false` recursively and reject serial-like keys, full URLs, signing paths, and secret fields.

- [ ] **Step 3: Run the focused tests and confirm RED**

  Run:

  ```bash
  node --test harmony/tests/structure/go-ohos-build-contract.test.mjs \
    harmony/tests/structure/phase4-proof-schema.test.mjs
  ```

  Expected: one assertion reports the missing `with_gvisor` tag and the schema test reports the missing schema/example; no syntax/import error.

- [ ] **Step 4: Implement the build and proof contracts**

  Update the Go build invocation from `-tags ohos` to `-tags ohos,with_gvisor`, update the build runner's reported command, and provide the closed schema/example. The example uses synthetic hashes/aliases and no real signing or device value. Do not add manifest, native-source, or probe-project assertions here; Tasks 3, 5, 9, and 10 add those assertions together with the behavior that makes them green.

- [ ] **Step 5: Run focused and existing structure regressions**

  ```bash
  node --test harmony/tests/structure/phase4-proof-schema.test.mjs
  node --test harmony/tests/structure/go-ohos-build-contract.test.mjs
  node --test harmony/tests/structure/*.test.mjs
  git diff --check
  ```

  Expected: every command exits `0`; the complete structure suite has zero failures.

- [ ] **Step 6: Commit the executable Phase 4 contract**

  Stage only the files in this task and create a Lore commit whose `Tested:` trailers list the green schema/build and complete structure lanes.

### Task 2: Add the shared VPN domain and serialized extension coordinator

**Files:**
- Create: `harmony/shared/src/main/ets/vpn/VpnModels.ets`
- Create: `harmony/shared/src/main/ets/vpn/VpnPorts.ets`
- Create: `harmony/shared/src/main/ets/vpn/VpnRuntimeCoordinator.ets`
- Create: `harmony/shared/src/test/VpnModels.test.ets`
- Create: `harmony/shared/src/test/VpnRuntimeCoordinator.test.ets`
- Modify: `harmony/shared/src/test/List.test.ets`
- Modify: `harmony/shared/src/test/fakes/ProfileFakes.ets`
- Modify: `harmony/shared/Index.ets`

- [ ] **Step 1: Write failing model tests**

  Define the desired public values in tests: states `STOPPED`, `AWAITING_CONSENT`, `STARTING`, `RUNNING`, `RECOVERING`, `STOPPING`, `ERROR`; full-capture config with `10.111.222.1/30`, `fd00:111:222::1/126`, routes `0.0.0.0/0` and `::/0`, DNS `10.111.222.2` and `fd00:111:222::2`, MTU `1500`, IPv4/IPv6 true, non-blocking, and exactly the production bundle in `blockedApplications`. Test rejection of blank IDs, wrong prefixes/routes/DNS, MTU outside `1280..9000`, trusted applications, and missing self-exclusion.

- [ ] **Step 2: Run the model test and confirm RED**

  ```bash
  cd harmony
  ./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
  ```

  Expected: ArkTS compilation fails because `VpnModels.ets` exports do not exist.

- [ ] **Step 3: Implement minimal immutable models and ports**

  Add `VpnStartRequest { profileId, versionId, sessionId }`, opaque `TunHandle { fd, vpnId, sessionId }`, validated `VpnCaptureConfig`, `TunStartOptions`, counters, ingress trace, snapshot, event, and allowlisted `VpnFailureCode`. Clone arrays and snapshots on every public boundary. Ports must exactly match the spec table and add `CommittedProfileResolverPort.resolve(profileId, versionId)`, `ClockPort.nowMs()`, and a cancelable bounded-delay scheduler for deterministic recovery tests.

- [ ] **Step 4: Write failing coordinator lifecycle and rollback tests**

  Cover: happy start order; process protection before platform create/core start; `Running` only after TUN readiness and notification start; duplicate start rejection; exact version resolution; stop while starting; repeated stop; each partial-start failure rolling back `tun.stop -> core/local runtime stop -> platform.destroy -> notification.stop`; late event from an old session ignored; consent denial returning `STOPPED`; network loss entering `RECOVERING`; recovery delays `250, 500, 1000, 2000, 4000, 8000` ms then terminal error; and cancellation preventing late retries.

- [ ] **Step 5: Run the coordinator test and confirm RED**

  Use the same shared Hvigor test command. Expected: failures because the coordinator is absent; the model tests now pass.

- [ ] **Step 6: Implement the minimal coordinator**

  Serialize all commands with `SerialCommandQueue` from `harmony/shared/src/main/ets/profile/SerialCommandQueue.ets`. Store only live session ownership. Validate event `sessionId` before state mutation. Keep stop idempotent and aggregate safe cleanup errors without skipping later cleanup. Make network recovery close stale outbound connections through the runtime port and retry only after `NetworkRecoveryPort` reports a usable network.

- [ ] **Step 7: Run shared tests and structure boundaries**

  ```bash
  cd harmony
  ./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
  cd ..
  node --test harmony/tests/structure/phase3-layer-boundary.test.mjs
  git diff --check
  ```

  Expected: all shared tests and the existing platform-neutral layer boundary pass. The manifest/VPN boundary test is deliberately introduced in Task 9, alongside the entry implementation that makes it green.

- [ ] **Step 8: Commit the shared VPN lifecycle**

  Stage the new VPN files, shared test list/fakes, and shared export only. Use Lore trailers to record the manual-restart and bounded-recovery constraints.

### Task 3: Extend the C ABI with fd ownership and bounded socket protection

**Files:**
- Modify: `harmony/core/abi/include/cmfa_types.h`
- Modify: `harmony/core/abi/include/cmfa_host.h`
- Modify: `harmony/core/abi/include/cmfa_core.h`
- Modify: `harmony/core/abi/src/cmfa_contract.cpp`
- Modify: `harmony/entry/src/main/cpp/include/cmfa_mihomo_backend.h`
- Modify: `harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp`
- Modify: `harmony/tools/test-native-host.mjs`
- Create: `harmony/tests/native/cmfa_tun_contract_test.cpp`
- Create: `harmony/tests/structure/phase4-native-contract.test.mjs`

- [ ] **Step 1: Write failing host tests for append-only ABI compatibility**

  Test old `cmfa_host_callbacks.struct_size` callers still initialize; the new full size accepts `protect_socket(context, fd, timeout_ms)`; short/oversized/null TUN option structs fail safely; all returned structs set their own `struct_size`; and no callback occurs after shutdown.

- [ ] **Step 2: Write failing fd ownership tests**

  Use `pipe()`/`fcntl()` seams plus injected `dup`/`close` functions to prove negative, zero, closed, and non-descriptor values fail; valid input is duplicated before backend start; the borrowed input remains open; the duplicate closes exactly once after success, rollback, repeated stop, or shutdown; and `dup()` failure never calls the backend.

- [ ] **Step 3: Write failing protection tests**

  Verify success, explicit rejection, missing callback, timeout, reentrant stop, and shutdown while blocked. The callback wait runs on the native worker, is capped at 3000 ms, and maps failure to `CMFA_SOCKET_PROTECT_FAILED` without invoking unprotected dial fallback.

- [ ] **Step 4: Run native tests and confirm RED**

  ```bash
  node harmony/tools/test-native-host.mjs
  ```

  Expected: compile failure for missing TUN ABI symbols/types; existing native executables still pass when run separately.

- [ ] **Step 5: Implement the minimum ABI and ownership state machine**

  Append new enum/status values instead of renumbering existing values. Add fixed-capacity fields for session ID, addresses, counters, trace IDs, ingress, protocol, hashed tuple, and optional correlation hash. Validate bounded UTF-8/ASCII fields before copying. `cmfa_tun_start` duplicates the fd exactly once, transfers only the duplicate to the backend, and records one close responsibility. `cmfa_tun_stop` is idempotent. Keep all Harmony/ArkTS types outside public headers.

- [ ] **Step 6: Adapt the backend seam without implementing Go behavior yet**

  Add backend function pointers for TUN start/stop/snapshot/traces and a host-protection trampoline. The test backend supplies deterministic stubs; production weak/exported Go symbols are wired in `cmfa_mihomo_backend.cpp`.

- [ ] **Step 7: Run host and structural regression tests**

  ```bash
  node harmony/tools/test-native-host.mjs
  node --test harmony/tests/structure/phase1-bridge-contract.test.mjs \
    harmony/tests/structure/phase4-native-contract.test.mjs
  git diff --check
  ```

  Expected: all host executables pass and ABI/source contract passes except the still-missing Node-API/Go source assertions.

- [ ] **Step 8: Commit the TUN ABI and fd ownership boundary**

  Stage only ABI/backend/test-runner/native-test files. Record the borrowed-versus-owned descriptor rule and callback timeout in Lore `Directive:` trailers.

### Task 4: Start sing-tun gVisor on the owned fd and instrument TUN ingress

**Files:**
- Create: `harmony/core/go/internal/runtime/tun.go`
- Create: `harmony/core/go/internal/runtime/tun_test.go`
- Create: `harmony/core/go/internal/runtime/tun_trace.go`
- Create: `harmony/core/go/internal/runtime/tun_trace_test.go`
- Create: `harmony/core/go/internal/runtime/protect.go`
- Create: `harmony/core/go/internal/runtime/protect_test.go`
- Modify: `harmony/core/go/internal/runtime/local_proxy.go`
- Modify: `harmony/core/go/internal/runtime/events.go`
- Modify: `harmony/core/go/internal/runtime/snapshot.go`
- Modify: `harmony/core/go/cmd/cmfa_core/main.go`

- [ ] **Step 1: Write failing constructor and lifecycle tests**

  Inject a `TunListenerFactory` whose production implementation calls mihomo `listener/sing_tun.New`. Assert options use the owned fd, `Stack: gvisor`, MTU 1500, both virtual prefixes, DNS hijack for TCP/UDP 53, `AutoRoute: false`, `AutoDetectInterface: false`, `AutoRedirect: false`, and the same `tunnel.Tunnel` as local listeners. Test one active runtime, start/stop races, reverse rollback, and no goroutine/listener leak.

- [ ] **Step 2: Run focused Go tests and confirm RED**

  ```bash
  cd harmony/core/go
  go test -count=1 ./internal/runtime -run 'TestTun|TestProtect|TestIngress'
  ```

  Expected: compile failures for absent TUN runtime/factory/trace types.

- [ ] **Step 3: Implement the fd-backed listener and shared runtime ownership**

  Prepare the existing mihomo executor once, create local HTTP/SOCKS listeners, then create the sing-tun listener with `inbound.WithInName("CMFA-TUN")`. A VPN start replaces a local-only start via the existing full stop path so no pre-protection outbound socket survives. Stop closes TUN first, then local listeners, tracked connections, and executor. Enable `with_gvisor` only through the build script contract from Task 1.

- [ ] **Step 4: Write failing TCP/UDP/DNS trace and counter tests**

  Wrap the `constant.Tunnel` boundary used only by the TUN listener. Feed fake TCP, UDP, and DNS inputs and require a bounded trace with `ingress: tun`, session ID, protocol, SHA-256 tuple hash, monotonic packet/byte counters, and a linked core event sharing the trace ID. Parse an opaque `cmfa-<flowId>` marker only from the controlled probe host/payload and store its hash; store DNS query SHA-256, never the clear label. Prove `local-http` and `local-socks` events cannot enter the TUN trace buffer.

- [ ] **Step 5: Implement bounded redacted tracing**

  Use a fixed 256-record ring buffer, 64-character lowercase hex hashes, and monotonically increasing counters. Never retain payloads, full URLs, clear DNS labels, source/destination text, credentials, config paths, or device data. Trace instrumentation delegates exactly once to the real mihomo tunnel and cannot decide routing.

- [ ] **Step 6: Write failing protection-before-dial tests**

  Inject `SocketProtector`. For API 20/21 mode, assert the fd is protected before each TCP/UDP outbound connect; rejection/timeout closes the socket and emits `VPN_SOCKET_PROTECT_FAILED`; success dials once. For API 22+ process-protected mode, assert the per-socket hook is not called. A failed connection does not kill an otherwise healthy packet loop.

- [ ] **Step 7: Implement the minimal protection hook and Go exports**

  Keep the callback synchronous only on a Go/native worker goroutine and bounded by the C ABI timeout. Export start/stop/snapshot/trace functions from `cmd/cmfa_core/main.go`, copy into caller-owned C buffers, and preserve the existing local start/stop/version/probe exports.

- [ ] **Step 8: Run focused, race, and build-contract lanes**

  ```bash
  cd harmony/core/go
  go test -tags with_gvisor -count=1 ./internal/runtime
  go test -tags with_gvisor -race -count=1 ./...
  cd ../../..
  node --test harmony/tests/structure/go-ohos-build-contract.test.mjs \
    harmony/tests/structure/phase4-native-contract.test.mjs
  git diff --check
  ```

  Expected: all Go and build-contract tests pass; no race report.

- [ ] **Step 9: Commit the sing-tun/mihomo data plane**

  Stage only Go runtime/export and build-contract files. Record that gVisor and disabled route mutation are deliberate HarmonyOS constraints.

### Task 5: Expose TUN through Node-API and `CoreTunRuntime`

**Files:**
- Create: `harmony/entry/src/main/cpp/src/js_tun.cpp`
- Modify: `harmony/entry/src/main/cpp/include/cmfa_napi.h`
- Modify: `harmony/entry/src/main/cpp/src/js_async.cpp`
- Modify: `harmony/entry/src/main/cpp/src/js_codec.cpp`
- Modify: `harmony/entry/src/main/cpp/src/js_core_module.cpp`
- Modify: `harmony/entry/src/main/cpp/CMakeLists.txt`
- Modify: `harmony/core/src/main/ets/CoreNativeAdapter.ets`
- Create: `harmony/core/src/main/ets/CoreTunRuntime.ets`
- Create: `harmony/core/src/test/CoreTunRuntime.test.ets`
- Modify: `harmony/core/src/test/List.test.ets`
- Modify: `harmony/core/Index.ets`
- Modify: `harmony/tests/native/napi_environment_test.cpp`

- [ ] **Step 1: Write failing Node-API contract tests**

  Require Promise-returning `startTun(options)`, `stopTun()`, `tunSnapshot()`, and `readTunTraces(afterSequence)` exports. Test strict object decoding, integer fd/range validation, fixed route/DNS/MTU values, session correlation, event callback lifetime, worker-thread execution, and environment cleanup releasing all references.

- [ ] **Step 2: Run native tests and confirm RED**

  ```bash
  node harmony/tools/test-native-host.mjs
  ```

  Expected: N-API environment test fails because the TUN exports and cleanup path are absent.

- [ ] **Step 3: Implement `js_tun.cpp` and registration**

  Reuse the existing async-work/error/codec helpers. Copy ArkTS strings/options before queuing work, never capture `napi_value` on a worker, and create JS snapshots only in the completion callback. Stop/shutdown deletes subscriptions and refs even after a native error. Add `js_tun.cpp` to CMake and register the four exports without altering Phase 1/2 test-only gating.

- [ ] **Step 4: Write failing ArkTS adapter tests**

  With a hand-written native fake, verify `CoreTunRuntime.start()` transfers each session fd once, rejects mismatched native session IDs, clones snapshots/traces, maps stable native errors, forwards events, makes repeated stop safe, and drops late callbacks after disposal.

- [ ] **Step 5: Run the core test and confirm RED**

  ```bash
  cd harmony
  ./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
  ```

  Expected: compile failure because `CoreTunRuntime` and native TUN methods do not exist.

- [ ] **Step 6: Implement the ArkTS TUN adapter and public exports**

  Extend `CoreNativeAdapter` with typed internal native shapes, implement `TunRuntimePort` in `CoreTunRuntime`, and export only the shared-compatible class from `core/Index.ets`. Do not import ability, NetworkKit, notification, or profile persistence APIs.

- [ ] **Step 7: Run bridge, ArkTS, and host regressions**

  ```bash
  node harmony/tools/test-native-host.mjs
  cd harmony
  ./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
  cd ..
  node --test harmony/tests/structure/phase1-bridge-contract.test.mjs \
    harmony/tests/structure/phase1-arkts-module-boundary.test.mjs \
    harmony/tests/structure/phase4-native-contract.test.mjs
  git diff --check
  ```

  Expected: all named lanes pass and Task 1's native source-presence contract is fully green.

- [ ] **Step 8: Commit the Node-API and ArkTS TUN boundary**

  Stage only the bridge/core files and tests. Record that fd ownership transfers at native start and no `napi_value` crosses to worker code.

## Chunk 2: HarmonyOS lifecycle and user experience

**Precondition:** Chunk 1 Tasks 1–5 are landed and green. Task 6 consumes the shared VPN ports from Task 2, Task 7 consumes its config/handle types, and Task 8 constructs `CoreTunRuntime` from Task 5. Do not execute Chunk 2 in isolation or replace those contracts with entry-layer duplicates.

### Task 6: Add permission-free recovery hints and continuous-notification adapters

**Files:**
- Create: `harmony/platform/src/main/ets/network/NetworkConnectionDriver.ets`
- Create: `harmony/platform/src/main/ets/network/HarmonyNetworkMonitor.ets`
- Create: `harmony/platform/src/main/ets/background/ContinuousTaskDriver.ets`
- Create: `harmony/platform/src/main/ets/background/HarmonyVpnNotificationDriver.ets`
- Create: `harmony/platform/src/test/HarmonyNetworkMonitor.test.ets`
- Create: `harmony/platform/src/test/HarmonyVpnNotificationDriver.test.ets`
- Modify: `harmony/platform/src/test/List.test.ets`
- Modify: `harmony/platform/src/main/ets/PlatformFactory.ets`
- Modify: `harmony/platform/Index.ets`
- Create: `harmony/tests/structure/phase4-platform-boundary.test.mjs`

- [ ] **Step 1: Write failing network-monitor tests**

  Use a hand-written `NetworkConnectionDriver` fake to require `currentNetwork()` to distinguish usable/unavailable, one underlying callback registration regardless of subscriber count, cloned notifications for available/lost/capability changes, and idempotent disposal that unregisters exact callback identities. Late callbacks after disposal must be ignored. Also require the production factory fallback to be opaque/unavailable without throwing.

- [ ] **Step 2: Run platform tests and confirm RED**

  ```bash
  cd harmony
  ./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
  ```

  Expected: compilation fails because the network driver and monitor do not exist.

- [ ] **Step 3: Implement the permission-free recovery seam**

  Keep `HarmonyNetworkMonitor` driven by an injected platform-neutral driver for deterministic tests, but do not ship a driver that calls default-network APIs: those APIs require the unapproved `ohos.permission.GET_NETWORK_INFO`. The production factory returns an opaque/unavailable monitor. Treat this port as a best-effort hint only; shared recovery must schedule `recover(sessionId)` with the bounded `250/500/1000/2000/4000/8000 ms` sequence even when the hint remains unavailable, and the TUN recovery result is the reachability probe.

- [ ] **Step 4: Write failing continuous-task tests**

  Inject a `ContinuousTaskDriver` and assert `start(sessionId)` creates a WantAgent targeting `EntryAbility`, requests the `dataTransfer` mode, records the returned continuous-task/notification ID when available, decodes the platform cancellation `id`, subscribes to `continuousTaskCancel`, and emits cancellation only for the current session. Test start failure, duplicate start, session-mismatched stop, repeated stop, stop after partial start, and removal of exact callbacks.

- [ ] **Step 5: Implement the minimal notification adapter**

  Wrap `backgroundTaskManager.startBackgroundRunning()`/`stopBackgroundRunning()` and `wantAgent.getWantAgent()` behind the driver. Use the API 20-compatible string-mode Promise start and no-ID stop overloads at every supported runtime; do not lexically reference API 21-only symbols from the compat-20 module. The click Want contains no profile/config secret. Cancellation maps to the shared port; when a start result omits the optional continuous-task ID, the one-active-session adapter treats the platform cancellation `id` as cancellation of that current session. The coordinator, not this adapter, decides session state.

- [ ] **Step 6: Add and run the platform boundary test**

  Assert no Task 6 production file imports NetworkKit connection APIs, only `HarmonyVpnNotificationDriver` imports background-task/WantAgent APIs, and neither adapter imports fd, N-API, core, profile content, or VPN ability types. Then run:

  ```bash
  cd harmony
  ./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
  cd ..
  node --test harmony/tests/structure/phase3-layer-boundary.test.mjs \
    harmony/tests/structure/phase4-platform-boundary.test.mjs
  git diff --check
  ```

  Expected: platform Hypium and both structure tests pass.

- [ ] **Step 7: Commit the recovery/background adapters**

  Stage only the shared bounded-recovery adjustment, platform adapters, platform tests/exports, design/plan updates, and boundary test. Record the exact two-permission constraint, API 20/21 compatibility, bounded TUN probe, and callback identity cleanup in Lore trailers.

### Task 7: Implement the one-owner `VpnConnection` driver and exact full-capture config

**Files:**
- Create: `harmony/entry/src/main/ets/vpn/VpnConnectionApi.ets`
- Create: `harmony/entry/src/main/ets/vpn/HarmonyVpnConnectionDriver.ets`
- Create: `harmony/entry/src/test/HarmonyVpnConnectionDriver.test.ets`
- Modify: `harmony/entry/src/test/List.test.ets`
- Create: `harmony/tests/structure/phase4-vpn-config.test.mjs`

- [ ] **Step 1: Write failing config translation tests**

  With a fake `VpnConnectionApi`, require `create()` to call `generateVpnId()` on API 20+, then call `create()` with IPv4 `10.111.222.1/30`, IPv6 `fd00:111:222::1/126`, routes `0.0.0.0/0` and `::/0`, DNS `10.111.222.2` and `fd00:111:222::2`, MTU 1500, IPv4/IPv6 accepted, `isBlocking: false`, no trusted list, and `blockedApplications: ["com.github.kr328.clash.harmony"]`. Assert returned `TunHandle` preserves fd/vpnId/sessionId and rejects non-positive/non-integer fd.

- [ ] **Step 2: Write failing protection and ownership tests**

  API 22+ must call `protectProcessNet()` exactly once before `create()` and abort on failure. API 20/21 must not call that method and must make `protectSocket(fd)` await `VpnConnection.protect(fd)`. Test duplicate create, destroy with generated VPN ID, fallback `destroy()` when generation was unavailable, repeated destroy, failed create cleanup, and rejection when the requested destroy `sessionId` is not the driver's live owning session; the driver stores `vpnId` only as internal platform cleanup identity.

- [ ] **Step 3: Run the entry test and confirm RED**

  ```bash
  cd harmony
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
  ```

  Expected: compilation fails for absent connection driver/API seam.

- [ ] **Step 4: Implement the driver around the public SDK**

  `VpnConnectionApi` wraps `vpnExtension.createVpnConnection(context)` and the returned SDK object so tests never mock SDK namespaces. Resolve SDK API level through an injected provider. Keep the original platform connection until destroy; never close the returned fd directly because native duplicates and owns only its copy. Map BusinessError codes into the allowlisted shared VPN failures without persisting raw system text.

- [ ] **Step 5: Add and run config/source structure tests**

  Require the exact address/route/DNS/MTU/self-exclusion literals, both accepted IP families, non-blocking mode, API 22 process protection, API 20/21 socket fallback, and absence of allowlists or forbidden permissions. Run:

  ```bash
  cd harmony
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
  cd ..
  node --test harmony/tests/structure/api20-sdk-contract.test.mjs \
    harmony/tests/structure/phase4-vpn-config.test.mjs
  git diff --check
  ```

  Expected: all tests pass, including the API 20 import/guard contract.

- [ ] **Step 6: Commit the platform TUN owner**

  Stage only the connection driver/seam and their tests. Record original-versus-duplicate fd ownership in the Lore `Directive:` trailer.

### Task 8: Wire the live registry, controller, and `VpnExtensionAbility` lifecycle

**Files:**
- Create: `harmony/entry/src/main/ets/vpn/VpnSessionRegistry.ets`
- Create: `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets`
- Create: `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets`
- Create: `harmony/entry/src/main/ets/vpn/CmfaVpnExtensionAbility.ets`
- Create: `harmony/entry/src/test/VpnSessionRegistry.test.ets`
- Create: `harmony/entry/src/test/HarmonyVpnController.test.ets`
- Create: `harmony/entry/src/test/VpnExtensionComposition.test.ets`
- Modify: `harmony/entry/src/test/fakes/PresentationFakes.ets`
- Modify: `harmony/entry/src/test/List.test.ets`
- Modify: `harmony/platform/src/main/ets/PlatformFactory.ets`

- [ ] **Step 1: Write failing live-registry tests**

  Require immutable snapshots, one active/pending session, unique subscription IDs, duplicate-session rejection, and late updates ignored unless their `sessionId` equals the live owner. Define “stale” operationally as any session not equal to the registry's current pending/active ID after a newer start or completed stop. A new registry begins `STOPPED`; it never reloads persisted `RUNNING` state.

- [ ] **Step 2: Write failing controller tests**

  Inject the registry and VPN-extension API. `start(profileId, versionId, sessionId)` must validate nonblank IDs, publish `AWAITING_CONSENT`, and call `startVpnExtensionAbility()` once with bundle `com.github.kr328.clash.harmony`, ability `CmfaVpnExtensionAbility`, and exactly three parameters: `profileId`, `versionId`, `sessionId`. Consent denial maps to `VPN_PERMISSION_DENIED` and `STOPPED`; duplicate pending/active starts fail. `stop(sessionId?)` records a user-requested stop, calls the stop API once, and stays idempotent. An extension destruction without that marker is classified as `VPN_SYSTEM_REVOKED` (including another VPN replacing the session) before cleanup.

- [ ] **Step 3: Run entry tests and confirm RED**

  Use the entry Hvigor test command. Expected: compile failures for the registry and controller APIs introduced by Steps 1–2; composition is deliberately added to the next RED cycle.

- [ ] **Step 4: Implement registry and controller**

  Use `vpnExtension.startVpnExtensionAbility()` and `stopVpnExtensionAbility()` only inside `HarmonyVpnController`. Never include config body, URL, node, credential, fd, or VPN ID in Want. Clone all snapshots/events and translate BusinessError into stable shared failures.

- [ ] **Step 5: Write failing extension-composition tests**

  Parse a fake Want; reject missing/extra/non-string values and stale/duplicate session IDs. Resolve the exact committed `(profileId, versionId)` through `CommittedProfileResolverPort`; deleted, superseded, or uncommitted versions fail closed. Verify dependency/start order: platform adapters -> process/socket protection mode -> platform create -> core/local runtime -> TUN -> continuous task. For every injected failure, assert reverse cleanup and a redacted registry error. Test user-requested `onDestroy()` as a normal stop and unrequested `onDestroy()` as `VPN_SYSTEM_REVOKED`, both using the identical cleanup sequence.

- [ ] **Step 6: Implement the extension-owned composition and lifecycle**

  `CmfaVpnExtensionAbility.onCreate(want)` starts one async composition and catches failure into the registry; `onDestroy()` awaits the same idempotent coordinator stop path without starting new work. The extension owns `HarmonyVpnConnectionDriver`, `CoreTunRuntime`, network monitor, notification driver, and `VpnRuntimeCoordinator`. Page/ability recreation only re-subscribes to registry state and never stops the extension. Extend `PlatformFactory` to accept the common context operations needed by both `UIAbilityContext` and `VpnExtensionContext` without importing entry types.

- [ ] **Step 7: Run lifecycle and boundary regressions**

  ```bash
  cd harmony
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
  cd ..
  node --test harmony/tests/structure/phase3-layer-boundary.test.mjs \
    harmony/tests/structure/phase4-platform-boundary.test.mjs \
    harmony/tests/structure/phase4-vpn-config.test.mjs
  git diff --check
  ```

  Expected: entry tests pass; no shared/platform boundary regression.

- [ ] **Step 8: Commit extension lifecycle orchestration**

  Stage only registry/controller/composition/ability, required PlatformFactory seam, and tests. Record manual restart after process death and exact Want keys in Lore trailers.

### Task 9: Integrate production composition, precise UI language, manifest, and resources

**Files:**
- Modify: `harmony/shared/src/main/ets/profile/ProfileApplication.ets`
- Modify: `harmony/shared/src/test/ProfileManagement.test.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/ApplicationComposition.ets`
- Modify: `harmony/entry/src/main/ets/entryability/EntryAbility.ets`
- Modify: `harmony/entry/src/main/ets/presentation/PresentationModels.ets`
- Modify: `harmony/entry/src/main/ets/presentation/HomeViewModel.ets`
- Modify: `harmony/entry/src/main/ets/components/RuntimeStatusCard.ets`
- Modify: `harmony/entry/src/main/ets/pages/HomePage.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/entry/src/test/HomeViewModel.test.ets`
- Modify: `harmony/entry/src/main/module.json5`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Create: `harmony/tests/structure/phase4-vpn-contract.test.mjs`
- Modify: `harmony/tests/structure/phase3-ui-contract.test.mjs`
- Modify: `harmony/tests/structure/phase0-layout.test.mjs`

- [ ] **Step 1: Write failing application/ViewModel tests**

  Require separate actions and visible states for `Local proxy` and `VPN global capture`; local start/stop continues using `LocalRuntimeCoordinator`, while VPN start resolves the selected committed version, generates a fresh non-secret session ID, and calls `VpnControllerPort`. Starting VPN performs a controlled local runtime stop first; starting local while VPN is active is disabled. Reconstructing the ViewModel reads the live registry snapshot, not persisted VPN state. Permission denial, already-active VPN, system revocation/replacement, background-task failure, recovery, and stop errors render distinct allowlisted safe messages.

- [ ] **Step 2: Run shared/entry tests and confirm RED**

  ```bash
  cd harmony
  ./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
  ```

  Expected: tests fail because the application facade and home presentation expose only local runtime.

- [ ] **Step 3: Implement composition and UI behavior**

  Add explicit Local proxy and VPN global capture cards/buttons, actual TUN/local-listener state, IPv4/IPv6/DNS/MTU facts, notification/recovery status, and the two listener addresses. Keep the existing Phase 1/2 self-test route isolated. Do not display “system proxy”, “global HTTP proxy”, always-on/lockdown, or unsupported OS-reserved traffic claims.

- [ ] **Step 4: Write failing manifest/wording contract tests**

  Require only `ohos.permission.INTERNET` and `ohos.permission.KEEP_BACKGROUND_RUNNING`; exactly one non-exported extension ability with `name: "CmfaVpnExtensionAbility"`, `type: "vpn"`, `srcEntry: "./ets/vpn/CmfaVpnExtensionAbility.ets"`, and no extra source-manifest fields beyond the current HarmonyOS 6.x SDK schema. Also require `harmony/hvigorw` to exec the integrated wrapper directly without reading, backing up, or rewriting `module.json5`. Require exact Local proxy/VPN global capture resources and reject misleading system-proxy/enterprise wording from production resources.

- [ ] **Step 5: Run structure tests and confirm RED**

  ```bash
  node --test harmony/tests/structure/phase4-vpn-contract.test.mjs \
    harmony/tests/structure/phase3-ui-contract.test.mjs \
    harmony/tests/structure/phase0-layout.test.mjs
  ```

  Expected: failures for the absent permission/extension declaration and new UI resource keys.

- [ ] **Step 6: Implement the manifest and resources**

  Add the ordinary background permission and the legal four-field VPN extension declaration (`name`, `srcEntry`, `type`, `exported`), update only resource-backed user text, and keep the ability non-exported. Do not add MANAGE_VPN or any settings/enterprise permission, and do not introduce a build-time wrapper sanitizer or any manifest rewrite workaround.

- [ ] **Step 7: Run module, HAP, and structure regressions**

  ```bash
  cd harmony
  ./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
  ./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
  ./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
  cd ..
  node --test harmony/tests/structure/*.test.mjs
  git diff --check
  ```

  Expected: every test/build exits `0`; the unsigned/development build contains the same four-field VPN extension declaration as the source manifest, no forbidden permission, and no `backgroundModes`. The wrapper must not rewrite the manifest before packaging.

- [ ] **Step 8: Commit the production VPN experience**

  Stage only application/composition/presentation/manifest/resources and contract tests. Record precise proxy terminology and ordinary-app permission limits in Lore trailers.

## Chunk 3: Independent device proof and delivery

**Precondition:** Chunks 1 and 2 are landed and every host/module/HAP lane is green. The connected target must be one HarmonyOS 6.x API 20+ AArch64 physical phone, the production app must have one selected committed profile, and signing inputs remain external to Git. If any physical precondition is absent, the runner writes `incomplete` rather than manufacturing a pass.

### Task 10: Build a separately packaged direct-traffic probe HAP

**Files:**
- Create: `harmony/traffic-probe/AppScope/app.json5`
- Create: `harmony/traffic-probe/build-profile.json5`
- Create: `harmony/traffic-probe/hvigorfile.ts`
- Create: `harmony/traffic-probe/hvigorw`
- Create: `harmony/traffic-probe/oh-package.json5`
- Create: `harmony/traffic-probe/entry/build-profile.json5`
- Create: `harmony/traffic-probe/entry/hvigorfile.ts`
- Create: `harmony/traffic-probe/entry/oh-package.json5`
- Create: `harmony/traffic-probe/entry/src/main/module.json5`
- Create: `harmony/traffic-probe/entry/src/main/resources/base/element/string.json`
- Create: `harmony/traffic-probe/entry/src/main/resources/base/profile/main_pages.json`
- Create: `harmony/traffic-probe/entry/src/main/ets/entryability/ProbeAbility.ets`
- Create: `harmony/traffic-probe/entry/src/main/ets/pages/ProbePage.ets`
- Create: `harmony/traffic-probe/entry/src/main/ets/probe/ProbeModels.ets`
- Create: `harmony/traffic-probe/entry/src/main/ets/probe/DirectTrafficProbe.ets`
- Create: `harmony/traffic-probe/entry/src/test/DirectTrafficProbe.test.ets`
- Create: `harmony/traffic-probe/entry/src/test/List.test.ets`
- Create: `harmony/tests/structure/phase4-probe-isolation.test.mjs`

- [ ] **Step 1: Write failing probe-isolation tests**

  Require a standalone project root, application bundle `com.cmfa.phase4.trafficprobe`, only `ohos.permission.INTERNET`, API 20 compatibility, and no dependency/path from the production root `build-profile.json5`, production modules, resources, CMake, HAP build, or package manifests. Reject the production bundle name in the probe and probe bundle/resources/native payload in production source lists.

- [ ] **Step 2: Run the structure test and confirm RED**

  ```bash
  node --test harmony/tests/structure/phase4-probe-isolation.test.mjs
  ```

  Expected: failure because the standalone probe project is absent.

- [ ] **Step 3: Create the minimal standalone DevEco project**

  Use its own AppScope, build profile, entry module, lock boundary, output tree, and executable project-local `hvigorw`. The wrapper follows `harmony/hvigorw` but sets `PROJECT_DIR` to `harmony/traffic-probe` before invoking DevEco's integrated wrapper, so every command below resolves the standalone project rather than the production root. Do not copy signing config into committed files. `ProbeAbility` accepts only generated run/session/flow IDs, LAN origin host/ports, pinned test certificate hash, and the production local-listener ports. It writes one bounded JSON result to `/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json` and displays only pass/fail progress.

- [ ] **Step 4: Write failing direct-traffic unit tests**

  Inject HTTP/TCP, UDP, DNS, and clock/file drivers. Require unique opaque flow IDs; direct HTTPS/TCP to the LAN origin without HTTP/SOCKS/PAC/application/Wi-Fi proxy configuration; direct UDP echo; `connection.getAddressesByName()` on a generated hashed `.invalid` label plus a raw DNS-format correlation packet; IPv4 required; IPv6 attempted only when capability is reported; and separate explicit local HTTP CONNECT/SOCKS5 checks. Every record carries run/session/flow correlation and contains no clear DNS label, full URL, proxy credential, device identifier, or signing path.

- [ ] **Step 5: Run probe unit tests and confirm RED**

  ```bash
  cd harmony/traffic-probe
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
  ```

  Expected: compilation fails because `DirectTrafficProbe` and its driver contracts are absent.

- [ ] **Step 6: Implement direct probes and evidence writing**

  Use NetworkKit HTTP/socket/DNS APIs only. Keep global-capture requests independent from local-listener requests, label each ingress expectation explicitly, set bounded timeouts, close every request/socket in `finally`, and atomically replace the evidence file only after all checks finish. The probe does not import production/shared/core packages and has no service/extension/background ability.

- [ ] **Step 7: Run unit, structure, and standalone HAP builds**

  ```bash
  cd harmony/traffic-probe
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
  cd ../..
  node --test harmony/tests/structure/phase4-probe-isolation.test.mjs
  git diff --check
  ```

  Expected: tests and build exit `0`; the probe HAP is produced only under `harmony/traffic-probe/entry/build/**` and may remain unsigned until Task 12.

- [ ] **Step 8: Commit the isolated probe source**

  Stage the standalone project source/config and isolation test only. Exclude build output, signing config/material, and probe evidence. Record that the probe is test-only and never a release deliverable.

### Task 11: Correlate controlled origin, probe, TUN, and mihomo evidence

> **2026-08-29 verification update:** Keep the controlled LAN origin for HTTPS
> identity and local HTTP/SOCKS proof. Run global TCP exchange plus UDP/DNS
> exact-echo native sockets against the validated public endpoint set.
> Connected-LAN capture and the removed `/32`/historical probe-only trusted-app
> allowlist experiments are not release gates.

**Files:**
- Create: `harmony/tests/bin/phase4-origin.mjs`
- Create: `harmony/tests/structure/phase4-origin-contract.test.mjs`
- Create: `harmony/entry/src/main/ets/vpn/VpnEvidenceJournal.ets`
- Create: `harmony/entry/src/test/VpnEvidenceJournal.test.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets`
- Modify: `harmony/entry/src/test/List.test.ets`
- Create: `harmony/tests/bin/run-phase4-device-proof.mjs`
- Create: `harmony/tests/bin/inspect-phase4-packages.mjs`
- Create: `harmony/tests/structure/phase4-runner-contract.test.mjs`
- Create: `harmony/tests/structure/phase4-package-contract.test.mjs`
- Modify: `harmony/tests/structure/phase4-proof-schema.test.mjs`

- [ ] **Step 1: Write failing origin tests**

  Require one process to bind a random LAN IPv4 HTTPS/TCP port and UDP echo port, optionally bind IPv6, emit newline-delimited synthetic observations, validate generated run/flow IDs, echo opaque payloads, and expose certificate/response hashes. Reject non-LAN bind addresses, oversized datagrams/headers, malformed IDs, clear secrets, and any record without run correlation. DNS system-resolution is observed at TUN/mihomo; the origin does not pretend to own public DNS.

- [ ] **Step 2: Run origin tests and confirm RED**

  ```bash
  node --test harmony/tests/structure/phase4-origin-contract.test.mjs
  ```

  Expected: import/file-not-found failure for `phase4-origin.mjs`.

- [ ] **Step 3: Implement the controlled origin**

  Reuse the Phase 2 ephemeral certificate and redaction patterns without importing its phase-specific schema. Bind only the explicitly selected private/LAN interface, print startup metadata once, record hashed flow correlation, and terminate cleanly on SIGTERM. Never write a private key or clear device address to the proof artifact.

- [ ] **Step 4: Write failing production evidence-journal tests**

  Feed TUN snapshots/traces/core events into a bounded journal and require only the current session; monotonic sequence; exact `ingress`; trace/core linkage; counters; lifecycle/recovery/notification/stop facts; atomic write; 1 MiB cap; and redaction of URLs, DNS labels, tuples, VPN IDs, config/profile content, raw errors, paths, and device data. The journal is observation-only and exposes no start/stop/test command.

- [ ] **Step 5: Implement and wire the journal**

  Store `/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json`, rotate on a new session, and finalize on stop after the last native snapshot/trace read. `VpnExtensionComposition` subscribes/unsubscribes the journal with the same lifecycle as the coordinator. A write failure is diagnostic and cannot turn a stopped runtime back to running.

- [ ] **Step 6: Write failing two-HAP package-inspection tests**

  Inject archive listing/extraction, hash, signature, native inspection, and manifest readers. Require production `com.github.kr328.clash.harmony`, probe `com.cmfa.phase4.trafficprobe`, distinct hashes/signatures, exact permission sets, real production addon/core/TUN symbols, no native payload in probe, and bidirectional rejection of the other bundle's resources/entry points. Unsigned HAP names or missing signature blocks fail.

- [ ] **Step 7: Implement the package inspector**

  Reuse `inspect-hap.mjs`, `inspect-native-lib.mjs`, and the existing safe ZIP/path/hash helpers for production; add the small probe-only archive/manifest checks without executing archive contents. Expose one CLI:

  ```bash
  node harmony/tests/bin/inspect-phase4-packages.mjs \
    --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
    --production-manifest harmony/artifacts/phase1-native-provenance.json \
    --probe-hap harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap \
    --out harmony/artifacts/phase4-package-inspection.json
  ```

  Expected when both inputs are valid: exit `0`, `result: "pass"`, two distinct bundle/hash entries, production `stubDetected: false`, and `probeEmbeddedInProduction: false`.

- [ ] **Step 8: Write failing runner contract and correlation tests**

  Inject filesystem, process, HDC, clock, origin, UI automation, and hash seams. Require: exactly one physical HarmonyOS 6 AArch64 target; two different signed HAP identities/hashes; production install before probe install; semantic UI launch/tap of `home.vpn.primary`; handling of the system VPN trust dialog; direct probe launch; sandbox pulls from both bundles; matching origin/probe/TUN/core records; TCP/UDP/DNS each `ingress: tun`; local checks only `local-http`/`local-socks`; counter deltas; IPv4 and conditional IPv6; launcher/screen-off continuity; system VPN indicator plus ongoing notification; controlled network loss/recovery; stop cleanup and ordinary-network restoration. Any missing link, unsigned/shared identity, counter-only evidence, local ingress substitution, or production-bundle self-test yields `fail`/`incomplete`, never pass.

- [ ] **Step 9: Implement built-in HDC/UITest automation and sandbox evidence pulls**

  Use only the connected device's built-in surfaces confirmed by `hdc shell uitest help`: `uitest dumpLayout -i -p <device-json>`, pull that layout to a temporary host path, locate a node by ArkUI/resource/text attributes, compute its bounds center, then call `uitest uiInput click <x> <y>`. Use `uitest uiInput keyEvent Home` and `Power` for launcher/screen continuity and always restore the prior screen state. Locate the system VPN consent action and VPN indicator/continuous notification from merged system-window layout rather than fixed coordinates or language-only text. A missing/ambiguous node yields `UI_AUTOMATION_UNSUPPORTED`, never a guessed click.

  Pull the two inputs with the HDC debug-bundle file surface already used by Phase 2:

  ```text
  hdc -t <target> file recv -b com.github.kr328.clash.harmony /data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json <temp>/runtime.json
  hdc -t <target> file recv -b com.cmfa.phase4.trafficprobe /data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json <temp>/probe.json
  ```

  Verify help exposes `file recv -b` before install, enforce the 1 MiB cap while reading, validate each JSON independently, and delete only the host temporary directory afterward.

- [ ] **Step 10: Implement the runner as a fail-closed state machine**

  Derive HDC from the pinned toolchain, accept repo-scoped `--production-hap` and `--probe-hap`, and call the package inspector before installation. Start the LAN origin for controlled HTTPS/local checks and first launch the probe with VPN stopped to prove TCP exchange plus UDP/DNS exact-echo reachability against the validated public endpoint set. LAN HTTPS failure yields `ORIGIN_REACHABILITY_NOT_PROVEN`; external-origin failure yields `EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN` before VPN claims begin. Then launch production, click `home.vpn.primary`, accept system consent through Step 9's semantic automation, run new unique public probe flows, and poll both evidence files.

  For continuity, leave the UI and turn screen off/on. For recovery, use the same UITest layout/click surface to open the system network controls, snapshot Wi-Fi/mobile switch state, produce a bounded real network loss, restore the exact state in `finally`, and require `RECOVERING -> RUNNING`; if the controls cannot be uniquely identified or device policy forbids the action, write `incomplete` with `NETWORK_RECOVERY_NOT_PROVEN`. When a VPN-round external-origin echo fails, gracefully stop, confirm the stopped journal, and check the same endpoint once before bundle force-stop and origin close. Always restore screen/network state in `finally`.

- [ ] **Step 11: Complete schema validation and redaction tests**

  Validate both sandbox inputs before correlation, then validate the final object against `phase4-device-proof.schema.json`. Recursively scan key/value text to reject serials, IP/host details not already reduced to approved aliases/hashes, full URLs, clear DNS labels, signing suffixes/paths, credentials, profile/config content, and raw system errors. Write atomically to ignored `harmony/artifacts/phase4-device-proof.json` on success, failure, or interruption.

- [ ] **Step 12: Run journal/origin/package/runner/schema regressions**

  ```bash
  cd harmony
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
  cd ..
  node --test harmony/tests/structure/phase4-origin-contract.test.mjs \
    harmony/tests/structure/phase4-package-contract.test.mjs \
    harmony/tests/structure/phase4-runner-contract.test.mjs \
    harmony/tests/structure/phase4-proof-schema.test.mjs \
    harmony/tests/structure/phase4-probe-isolation.test.mjs
  git diff --check
  ```

  Expected: every test exits `0`; no device is required for the injected runner contract lane.

- [ ] **Step 13: Commit the falsifiable proof pipeline**

  Stage only origin, journal, runner, tests, and schema updates. Exclude generated proof/evidence and all signing/device data. Record that only external-probe plus TUN plus linked mihomo evidence can pass.

### Task 12: Build, sign, install, and produce the physical-phone proof

**Files:**
- Modify only when a failing contract requires it: files owned by Tasks 1–11
- Generate, ignored: `harmony/artifacts/phase1-native-provenance.json`
- Generate, ignored: `harmony/artifacts/phase4-device-proof.json`
- Generate, ignored: `harmony/entry/build/default/outputs/default/entry-default-signed.hap`
- Generate, ignored: `harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap`

- [ ] **Step 1: Run all host-side regression gates fresh**

  ```bash
  node --test harmony/tests/structure/*.test.mjs
  node harmony/tools/test-native-host.mjs
  cd harmony/core/go
  go test -tags with_gvisor -race -count=1 ./...
  cd ../../..
  cd harmony
  ./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
  ./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
  ./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
  cd traffic-probe
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
  ```

  Expected: every command exits `0`, Go reports no race, and no test is skipped because a device is absent.

- [ ] **Step 2: Build fresh real-core AArch64 artifacts and both HAPs**

  From repository root, run:

  ```bash
  node harmony/tests/bin/build-phase1-native.mjs \
    --out harmony/artifacts/phase1-native-provenance.json
  cd harmony/traffic-probe
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug clean
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
  ```

  Expected: the first command exits `0` with manifest `result: "pass"` and a signed production HAP identity; probe build exits `0` and produces `harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap`. Both projects consume the current external DevEco automatic-signing configuration for the registered device. If either output is unsigned/missing, stop with `SIGNING_REQUIRED`; never add signing configuration/material to tracked files.

- [ ] **Step 3: Inspect package identity and provenance before install**

  From repository root, run:

  ```bash
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

  Expected: both commands exit `0`. Production contains real mihomo `v1.19.29`, sing-tun/gVisor bytes, expected TUN ABI symbols, one addon/core pair, only approved permissions, and no probe identity/resources/test control. Probe has the distinct bundle, only INTERNET, no production native libraries, and a valid developer signature. Persist hashes but no signing path.

- [ ] **Step 4: Install both HAPs and run the fail-closed Phase 4 runner**

  ```bash
  node harmony/tests/bin/run-phase4-device-proof.mjs \
    --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
    --probe-hap harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap \
    --out harmony/artifacts/phase4-device-proof.json
  ```

  Expected: one physical target is selected, both installs succeed, the system VPN trust flow is accepted through UI automation, TCP/UDP/DNS have external-probe + `ingress: tun` + linked mihomo evidence, lifecycle/recovery/stop checks pass, and the runner exits `0` with top-level `result: "pass"` and `stubDetected: false`.

- [ ] **Step 5: Re-run package/proof validators against the exact delivered HAP**

  Hash the final production/probe HAPs, compare them to the proof, rerun all Phase 4 structure/schema/package checks, and use `hdc shell bm dump -n` plus a post-stop direct probe to confirm the production bundle is installed, the probe remains a separate bundle, the VPN indicator/notification are gone, local ports are closed, and ordinary networking is restored.

- [ ] **Step 6: Fix only evidence-backed failures with new RED tests**

  If any device/build gate fails, apply @superpowers:systematic-debugging, add the smallest host regression reproducing the cause, verify RED, implement the minimal fix, rerun the focused gate, then restart Task 12 from Step 1. Never weaken the proof schema, substitute local traffic, mark optional IPv6 when available as skipped, or manually edit the generated proof to pass.

- [ ] **Step 7: Commit any required device-discovered fixes**

  If Step 6 changed tracked code, create one or more narrow Lore commits with exact tested/not-tested trailers. Generated HAPs/proofs remain ignored and signing/device materials remain untracked.

### Task 13: Final review and delivery evidence

**Files:**
- Review: all commits since `c79c5984`
- Review: `docs/superpowers/specs/2026-08-16-harmonyos-phase4-vpn-tun-design.md`
- Review: `docs/superpowers/plans/2026-08-16-harmonyos-phase4-vpn-tun.md`

- [ ] **Step 1: Dispatch the required final code reviewer**

  Apply @superpowers:requesting-code-review with base `c79c5984` and current `HEAD`. Require line-by-line checks for every acceptance criterion, fd/callback lifetime, ordinary-app permissions, loop prevention, IPv6/DNS capture, probe independence, evidence correlation, redaction, production-package isolation, and test adequacy.

- [ ] **Step 2: Resolve every Critical/Important finding through TDD**

  Return each valid issue to the owning implementation task, add a focused failing test, implement the smallest fix, rerun that task's full gate, and re-dispatch review until approved. Record any rejected reviewer suggestion with concrete code/test evidence.

- [ ] **Step 3: Apply verification-before-completion to the exact final tree**

  Re-run Task 12 Steps 1, 3, 4, and 5 after the last tracked edit. Confirm zero pending required exec sessions, zero test/build failures, proof `result: pass`, all acceptance criteria checked, and `git diff --check` clean. Inspect `git status --short` and exclude `.omx/`, generated lockfiles, HAPs/proofs, signing material, device data, and unrelated Phase 1/2 worktree edits from any final commit.

- [ ] **Step 4: Report the final HarmonyOS deliverables**

  Report package variant, AppScope version name/code, absolute signed production HAP path and SHA-256, separate probe HAP path/hash clearly marked test-only, `phase4-device-proof.json` path/result, exact device class/API/architecture alias, tests/builds run, changed files grouped by responsibility, simplifications made, and remaining risks. State explicitly that Android was not modified and that no OS global HTTP proxy, always-on lockdown, system-reserved traffic, or enterprise privilege is claimed.
