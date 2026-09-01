# HarmonyOS Native Traffic Probe Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a test-only POSIX/N-API TCP, UDP, and DNS-format echo probe so the Phase 4 physical-phone proof exercises ordinary application socket routing instead of NetworkKit's explicit default-network path.

**Architecture:** `libprobeentry.so` lives only in the standalone traffic-probe HAP. A platform-neutral C++ socket core performs bounded echo operations; a one-shot N-API Promise bridge copies inputs and returns fixed aggregate results; an injectable ArkTS adapter feeds the existing evidence model. Production packaging continues to reject all probe native content.

**Tech Stack:** HarmonyOS 6.x API 20; C++17/POSIX sockets; Node-API; ArkTS/Hypium; CMake/Hvigor; Node.js structure/package tests.

**Design spec:** `docs/superpowers/specs/2026-08-28-harmonyos-native-traffic-probe-design.md`

---

## File responsibility map

| File | Responsibility |
| --- | --- |
| `traffic-probe/entry/src/main/cpp/probe_native_core.{h,cpp}` | Strict request/result model and bounded POSIX echo operations. |
| `traffic-probe/entry/src/main/cpp/probe_native_napi.cpp` | Decode/copy request, one async work item, encode fixed result. |
| `traffic-probe/entry/src/main/cpp/CMakeLists.txt` | Build only `libprobeentry.so` for arm64. |
| `traffic-probe/entry/src/main/cpp/types/libprobeentry/*` | ArkTS type package for the addon. |
| `traffic-probe/entry/src/main/ets/probe/NativeSocketProbe.ets` | Sole native import and injectable ArkTS port. |
| `traffic-probe/entry/src/main/ets/probe/DirectTrafficProbe.ets` | Route TCP exchange plus UDP/DNS exact-echo steps through the port and publish existing evidence. |
| `tests/native/traffic_probe_native_core_test.cpp` | Host socket-core regression executable. |
| `tools/test-traffic-probe-native-host.mjs` | Build/run the isolated host test. |
| `tests/bin/inspect-native-lib.mjs` | Inspect explicit `probeAddon` identity without basename inference. |
| `toolchain.native-allowlist.json` | Keep a separate DT_NEEDED allowlist for the test-only addon. |

## Chunk 1: Native boundary

### Task 1: Lock the test-only native package contract

**Files:**
- Modify: `harmony/tests/structure/phase4-probe-isolation.test.mjs`
- Modify: `harmony/tests/structure/phase4-package-contract.test.mjs`
- Modify: `harmony/tests/bin/inspect-phase4-packages.mjs`
- Modify: `harmony/tests/bin/inspect-native-lib.mjs`
- Modify: `harmony/toolchain.native-allowlist.json`
- Modify: `harmony/traffic-probe/entry/build-profile.json5`
- Modify: `harmony/traffic-probe/entry/oh-package.json5`
- Create: `harmony/traffic-probe/entry/src/main/cpp/CMakeLists.txt`
- Create: `harmony/traffic-probe/entry/src/main/cpp/types/libprobeentry/oh-package.json5`
- Create: `harmony/traffic-probe/entry/src/main/cpp/types/libprobeentry/Index.d.ts`

- [ ] Write failing structure tests requiring exactly `libs/arm64-v8a/libprobeentry.so` in the probe, while production still rejects that name and every probe marker.
- [ ] Run the two structure tests and confirm failures for the absent native build/type package.
- [ ] Add `externalNativeOptions`, arm64 target `probeentry`, and the local `libprobeentry.so` type dependency.
- [ ] Add a distinct `probeAddon` inspection component and independent DT_NEEDED/export contract; package inspection must pass `component: 'probeAddon'` explicitly and must never infer this addon as the existing Go `probe` component from its basename.
- [ ] Update package inspection to require only the exact addon path, reject `cmfa_*`, host-bridge symbols, `libcmfa_mihomo.so`, `dlopen`, and `dlsym`, and avoid reusing the production `nodeAddon` allowlist.
- [ ] Re-run focused contracts and `git diff --check`.

### Task 2: Implement the bounded POSIX socket core test-first

**Files:**
- Create: `harmony/traffic-probe/entry/src/main/cpp/probe_native_core.h`
- Create: `harmony/traffic-probe/entry/src/main/cpp/probe_native_core.cpp`
- Create: `harmony/tests/native/traffic_probe_native_core_test.cpp`
- Create: `harmony/tools/test-traffic-probe-native-host.mjs`

- [ ] Write host tests for invalid IPv4/port/timeout/payload, TCP exchange, UDP echo, DNS-format UDP echo, mismatch, timeout, EINTR/short I/O, and exactly one fd close.
- [ ] Run `node harmony/tools/test-traffic-probe-native-host.mjs` and confirm RED because the core is absent.
- [ ] Implement non-blocking sockets, `poll()` with one monotonic deadline, bounded send/receive, exact peer/payload verification, and fixed failure enums.
- [ ] Re-run the host test and confirm all cases pass under leak-safe cleanup.

### Task 3: Add the one-shot N-API Promise bridge

**Files:**
- Create: `harmony/traffic-probe/entry/src/main/cpp/probe_native_napi.cpp`
- Modify: `harmony/traffic-probe/entry/src/main/cpp/CMakeLists.txt`
- Modify: `harmony/traffic-probe/entry/src/main/cpp/types/libprobeentry/Index.d.ts`
- Create: `harmony/tests/native/traffic_probe_napi_contract_test.cpp` (also provides the minimal fake async-work implementation for this isolated executable)
- Modify: `harmony/tests/native/shim/napi/native_api.h`
- Modify: `harmony/tools/test-traffic-probe-native-host.mjs`

- [ ] Extend the shared N-API header with only the async-work declarations required by this test; implement the matching fake functions directly in `traffic_probe_napi_contract_test.cpp`, not in production code or another existing N-API test.
- [ ] Write failing source/host contract tests for exact export `probeSocket`, strict fields, copied `ArrayBuffer`, async worker execution/completion/deletion, Promise result, and env cleanup.
- [ ] Make `harmony/tools/test-traffic-probe-native-host.mjs` compile `traffic_probe_napi_contract_test.cpp` as the concrete fake-provider/test executable.
- [ ] Implement one `napi_async_work` per request; never retain `napi_value` on the worker and never log request content.
- [ ] Run native host tests and verify no extra export or async reference remains.

## Chunk 2: ArkTS integration and delivery

### Task 4: Route the three global probe steps through native

> **2026-08-29 verification update:** `DirectTrafficProbe` now separates
> `lanOrigin` from a required canonical public `externalOrigin`. Only native
> TCP/IPv4 UDP/DNS-format IPv4 use the external origin; HTTPS and local
> HTTP/SOCKS remain on LAN/local ingress.

**Files:**
- Create: `harmony/traffic-probe/entry/src/main/ets/probe/NativeSocketProbe.ets`
- Modify: `harmony/traffic-probe/entry/src/main/ets/probe/DirectTrafficProbe.ets`
- Modify: `harmony/traffic-probe/entry/src/test/DirectTrafficProbe.test.ets`
- Modify: `harmony/traffic-probe/entry/src/test/List.test.ets`

- [ ] Write failing Hypium tests with a fake native port for TCP pass/failure, UDP pass/failure, DNS-format pass/failure, byte counts, and fixed timeout mapping.
- [ ] Add a failing IPv6 contract: even when the platform reports IPv6 available, the IPv4-only native port emits `not-run` for `udp-ipv6` and `dns-packet-ipv6` and creates no ArkTS UDP socket.
- [ ] Add failing privacy assertions that serialize every evidence/failure branch and reject `hostIpv4`, raw payload, `.invalid` labels, address values, `errno`/POSIX symbolic errors, and operating-system error prose.
- [ ] Implement the sole `libprobeentry.so` import and strict native result normalization.
- [ ] Replace only global TCP/UDP/DNS-format transport calls and route them to `externalOrigin`; keep HTTPS, DNS lookup, local HTTP/SOCKS, and evidence writing on their existing LAN/local paths.
- [ ] Run traffic-probe unit tests and confirm GREEN.

### Task 5: Build, inspect, sign, and prove on the phone

**Files:**
- Modify: `harmony/tests/structure/phase4-runner-contract.test.mjs` only if a failing evidence contract requires it.
- Update: `docs/superpowers/specs/2026-08-16-harmonyos-phase4-vpn-tun-design.md`
- Update: `docs/superpowers/plans/2026-08-16-harmonyos-phase4-vpn-tun.md`
- Generate, ignored: signed probe HAP and Phase 4 proof.

- [ ] Run native host, probe unit, focused package/isolation, all structure, and `git diff --check`.
- [ ] Build the unsigned probe and inspect that it contains exactly `libprobeentry.so` and no production native library.
- [ ] Regenerate/capture automatic signing for `com.cmfa.phase4.trafficprobe`, build the signed HAP, and restore the unsigned project baseline.
- [ ] Run package inspection against the exact production/probe HAP hashes.
- [ ] Ensure the production VPN is stopped, require public TCP exchange plus UDP/DNS exact-echo baseline, then run the pre-recovery traffic diagnostic and require fresh TUN correlations.
- [ ] Run the full Phase 4 device proof; require top-level `result: pass`, lifecycle pass, local listener pass, fresh traffic correlations, stopped journal, and matching HAP hashes.
- [ ] Re-run final Go/native/ArkTS/structure/package validators and retain only redacted proof artifacts; scan the final Phase 4 JSON with the same privacy assertions.

## Delivery constraints

- No commit or push in this worktree.
- No production permission, bundle, blocked-application, or routing change.
- No raw address, payload, DNS label, URL, signing path, device ID, or system error in proof output.
- Restore exactly `harmony/build-profile.json5` and `harmony/traffic-probe/build-profile.json5` to their unsigned baselines before handoff. Module-level native build profiles remain part of the implementation and must not be reverted.
