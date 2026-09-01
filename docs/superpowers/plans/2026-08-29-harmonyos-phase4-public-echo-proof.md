# HarmonyOS Phase 4 Public Protocol Capture Proof Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the invalid connected-LAN global-capture gate with public TCP/UDP/DNS-format echo traffic while retaining the LAN origin for HTTPS and local-proxy checks.

**Architecture:** A test-only host helper supplies one strictly validated public TCP exchange endpoint plus documented public UDP/DNS exact-echo origins to the standalone probe HAP. `ProbeCommand` separates LAN and external destinations, the runner performs pre-VPN and conditional post-stop health checks, and proof correlation continues to require unique fresh TUN/mihomo evidence without changing the production VPN configuration.

**Tech Stack:** HarmonyOS 6.x API 20; ArkTS/Hypium; C++17 POSIX probe addon; Node.js test runner; HDC; physical-device proof.

**Design spec:** `docs/superpowers/specs/2026-08-29-harmonyos-phase4-public-echo-proof-design.md`

**Delivery constraints:** Do not commit or push. Do not alter Android. Restore both project-level signing profiles to unsigned before handoff. Never persist or print endpoint coordinates, device identifiers, signing material, subscriptions, or node data.

---

## File responsibility map

| File | Responsibility |
| --- | --- |
| `harmony/tests/bin/phase4-external-origin.mjs` | Own and strictly validate the test-only provider endpoint. |
| `harmony/traffic-probe/entry/src/main/ets/probe/ProbeModels.ets` | Model and validate separate LAN/external probe origins. |
| `harmony/traffic-probe/entry/src/main/ets/entryability/ProbeAbility.ets` | Decode flat and nested external-origin parameters. |
| `harmony/traffic-probe/entry/src/main/ets/probe/DirectTrafficProbe.ets` | Route global native sockets to external origin and local checks to LAN origin. |
| `harmony/tests/bin/run-phase4-device-proof.mjs` | Orchestrate baseline, VPN proof, post-stop provider triage, correlation, cleanup, and redacted proof. |
| `harmony/tests/structure/phase4-external-origin-contract.test.mjs` | Lock endpoint validation and no-output privacy. |
| `harmony/tests/structure/phase4-runner-contract.test.mjs` | Lock runner parameter flow, correlation, triage, and cleanup reason behavior. |

## Chunk 1: Isolated external-origin boundary

### Task 1: Add the strict host-side external-origin value

**Files:**
- Create: `harmony/tests/bin/phase4-external-origin.mjs`
- Create: `harmony/tests/structure/phase4-external-origin-contract.test.mjs`
- Modify: `harmony/tests/structure/List.test.mjs` only if explicit suite registration is required

- [ ] Add RED tests for the exact shape `{ hostIpv4, tcpPort, udpPort, dnsPort }`, canonical numeric IPv4, integer ports, missing/extra fields, mutation isolation, and a provider identity that reveals no coordinates.
- [ ] Add RED helper-level scans proving normalized errors and provider identity/serialization helpers never contain the host or ports.
- [ ] Run `node --test harmony/tests/structure/phase4-external-origin-contract.test.mjs`; require failures because the helper is absent.
- [ ] Implement a frozen `Phase4ExternalEchoOrigin` normalizer and a default provider factory from the reviewed public service. Keep coordinates in this one test-only module and return only a fixed provider alias to diagnostics.
- [ ] Re-run the focused test and `git diff --check`; require all cases pass.

### Task 2: Separate LAN and external origins in the probe command

**Files:**
- Modify: `harmony/traffic-probe/entry/src/main/ets/probe/ProbeModels.ets`
- Modify: `harmony/traffic-probe/entry/src/main/ets/entryability/ProbeAbility.ets`
- Modify: `harmony/traffic-probe/entry/src/test/ProbeAbility.test.ets`
- Modify: `harmony/traffic-probe/entry/src/test/List.test.ets` only if suite wiring requires it

- [ ] Add RED tests for a required `externalOrigin` with host/TCP/UDP/DNS fields in both flat Want and nested test input.
- [ ] Add RED tests for missing, invalid, mixed, or partially populated external values; parsing must fail closed without copying LAN values.
- [ ] Run the probe Hypium suite and record the expected missing-field/parser failures.
- [ ] Add `ProbeExternalOriginConfig`, `ProbeCommand.externalOrigin`, strict command validation, flat parameter constants, and decoder/fill helpers.
- [ ] Re-run the probe Hypium suite twice; require deterministic GREEN and no raw origin values in serialized errors.

### Task 3: Route only global native sockets to the external origin

**Files:**
- Modify: `harmony/traffic-probe/entry/src/main/ets/probe/DirectTrafficProbe.ets`
- Modify: `harmony/traffic-probe/entry/src/test/DirectTrafficProbe.test.ets`

- [ ] Add RED fake-port tests proving TCP, IPv4 UDP, and DNS-format IPv4 UDP use `externalOrigin.host` and their corresponding external ports.
- [ ] Add RED tests proving HTTPS, HTTP CONNECT, and SOCKS still use `lanOrigin`, and IPv6 remains `not-run` without creating an ArkTS UDP socket.
- [ ] Add RED privacy tests that serialize every success/failure branch and reject both LAN and external coordinates, provider response text, raw payload, and OS errors.
- [ ] Run the focused probe tests and verify the new routing assertions fail against the single-origin implementation.
- [ ] Resolve LAN and external address sets independently and change only the three global native operations to the external address set. Do not change the native addon API or echo semantics.
- [ ] Re-run the full probe Hypium suite and `git diff --check`; require GREEN.

## Chunk 2: Runner, evidence, and failure isolation

### Task 4: Pass the external origin only to the probe HAP

**Files:**
- Modify: `harmony/tests/bin/run-phase4-device-proof.mjs`
- Modify: `harmony/tests/structure/phase4-runner-contract.test.mjs`
- Modify: `harmony/tests/structure/phase4-probe-isolation.test.mjs`

- [ ] Add RED tests that baseline and VPN probe parameter builders receive the injected external origin and emit only the flat probe Want fields.
- [ ] Add RED tests proving the production launch arguments and UI-to-extension forwarding never contain any external-origin key or value.
- [ ] Add RED privacy tests for proof JSON, failures, command summaries, stdout, and stderr using sentinel coordinates.
- [ ] Run the focused runner/isolation tests and confirm expected missing-parameter failures.
- [ ] Inject the strict helper into `runPhase4DeviceProof`, extend probe parameter/launch builders, and pass the same immutable origin to baseline and VPN rounds.
- [ ] Re-run focused runner/schema/isolation tests; require GREEN.

### Task 5: Update reachability and DNS-specific correlation

**Files:**
- Modify: `harmony/tests/bin/run-phase4-device-proof.mjs`
- Modify: `harmony/tests/structure/phase4-runner-contract.test.mjs`
- Modify: `harmony/tests/structure/phase4-proof-schema.test.mjs`

- [ ] Add RED synthetic evidence tests where public TCP/UDP exact echoes and the controlled HTTPS observation pass without controlled TCP/UDP origin observations.
- [ ] Add RED negative tests where DNS evidence matches only a `protocol: udp` record; require `TUN_LINK_MISSING` and no DNS traffic pass.
- [ ] Keep RED negative tests for missing/ambiguous hashes, non-positive counters, and incomplete TCP destination/outbound-chain proof.
- [ ] Add a RED proof assertion that every pass/incomplete artifact retains exact production addresses, two default routes, DNS endpoints, blocking mode, and self-only blocked apps; keep empty trusted apps locked in `phase4-vpn-contract.test.mjs` rather than changing the persisted proof schema.
- [ ] Run runner/schema tests and verify failures reflect the old controlled-TCP/UDP observation dependency.
- [ ] Require controlled origin observation only for HTTPS/local ownership; retain exact probe echo outcomes and unique protocol/hash/runtime correlation for public flows.
- [ ] Re-run runner/schema tests and privacy scans; require GREEN.

### Task 6: Isolate provider failure and retain precise cleanup reasons

**Files:**
- Modify: `harmony/tests/bin/run-phase4-device-proof.mjs`
- Modify: `harmony/tests/structure/phase4-runner-contract.test.mjs`

- [ ] Add RED orchestration tests for: baseline external failure; VPN-round failure plus post-stop failure; VPN-round failure plus post-stop success; and cleanup failure that prevents provider triage.
- [ ] Require the first two cases to produce `EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN`; only post-stop success may preserve a VPN capture failure.
- [ ] Add RED tests that traffic-wait and finally cleanup expose only fixed reason/stage enums for journal, force-stop, origin close, network restore, screen restore, and temp cleanup boundaries.
- [ ] Run focused runner tests and record the expected generic-classification failures.
- [ ] Store a pending VPN probe failure; perform graceful VPN stop and runtime-stop confirmation; run the same endpoint once while the probe HAP and origin are still alive; classify it; only then continue bundle force-stop, origin close, state restore, temp cleanup, and proof write.
- [ ] Replace swallowed cleanup ambiguity with fixed redacted diagnostic stages while retaining the existing top-level lifecycle/failure schema.
- [ ] Re-run focused runner/schema/privacy tests; require GREEN.

## Chunk 3: Build and physical proof

### Task 7: Backfill the superseded proof documentation

**Files:**
- Modify: `docs/superpowers/specs/2026-08-16-harmonyos-phase4-vpn-tun-design.md`
- Modify: `docs/superpowers/specs/2026-08-28-harmonyos-native-traffic-probe-design.md`
- Modify: `docs/superpowers/plans/2026-08-16-harmonyos-phase4-vpn-tun.md`
- Modify: `docs/superpowers/plans/2026-08-28-harmonyos-native-traffic-probe.md`

- [ ] Document that connected-LAN flows are diagnostic-only and public TCP exchange plus public exact echo are the global-capture release gate.
- [ ] Record that the private `/32` and historical probe-only trusted-app allowlist experiments were falsified and removed, without preserving endpoint coordinates or device details.
- [ ] Run focused documentation/source contracts and `git diff --check`.

### Task 8: Run repository regressions

**Files:**
- No production edits expected

- [ ] Run Go unit tests, race tests, and vet.
- [ ] Run native core/N-API host tests and ASan/UBSan.
- [ ] Run all entry, shared, platform, core, and traffic-probe ArkTS tests.
- [ ] Run all structure tests and `git diff --check`; fix any regression before packaging.

### Task 9: Build unsigned HAPs and inspect package boundaries

**Files:**
- Generate, ignored: unsigned production and traffic-probe HAPs

- [ ] Build fresh unsigned production and probe HAPs.
- [ ] Run exact dual-HAP package inspection; production must be non-stub and reject probe content, while probe contains only the allowlisted addon.
- [ ] Verify both project-level build profiles remain unsigned after the builds.

### Task 10: Build signed device artifacts and run privacy scans

**Files:**
- Generate, ignored: signed production and traffic-probe HAPs

- [ ] Build signed device artifacts through the guarded helpers without modifying the secure signing backup.
- [ ] Restore `harmony/build-profile.json5` and `harmony/traffic-probe/build-profile.json5` exactly to unsigned baselines on success, nonzero exit, and exception paths.
- [ ] Scan artifacts and runner outputs for endpoint coordinates, device identity, signing paths/material, subscriptions, node data, raw payloads, and system errors.

### Task 11: Prove the public capture path on the physical phone

**Files:**
- Generate, ignored: `harmony/artifacts/phase4-device-proof.json`

- [ ] Confirm one physical target is connected and unlocked; install the exact inspected production/probe HAPs.
- [ ] Run the public baseline and require controlled HTTPS plus exact public TCP/UDP/DNS-format echo pass before VPN start.
- [ ] Run the full VPN lifecycle/recovery/local-listener proof.
- [ ] Require exactly one fresh linked TUN record with positive counters for TCP, UDP, and DNS, plus complete TCP outbound proof.
- [ ] Require notification/background/recovery/stop lifecycle pass, local HTTP/SOCKS pass, matching HAP hashes, exact production config assertions, and `stubDetected:false`.
- [ ] If a VPN-round echo fails, require the same endpoint post-stop triage before assigning a VPN failure.
- [ ] Re-run final regression/package/privacy validators and retain only redacted proof artifacts.

## Completion gate

Work is complete only when the full proof result is `pass`, all regressions and package inspections pass, no required command remains running, both signing profiles are unsigned, the dead private-origin experiment tokens are absent, and final review reports no blocker.

## Carrier-compatibility amendment

The first phone baseline proved UDP and DNS-format exact echo but rejected both
reviewed non-standard TCP exchange endpoints. The remaining work is therefore:

### Task 12: Add bounded native TCP exchange operations

- [ ] Add RED native core/N-API tests for `tcpHttp` status-line validation and
  `tcpExchange` request/response sequencing, including timeout/short I/O/single
  close, copied input, opaque marker handling, and fixed errors.
- [ ] Implement both operations without TLS, hostname resolution,
  response-body persistence, or changes to existing `tcpEcho`.
- [ ] Run native core/N-API and ASan/UBSan regressions.

### Task 13: Split TCP from UDP/DNS endpoint coordinates

- [ ] Add RED host/ArkTS/runner tests for separate public `tcpHostIpv4` and
  UDP/DNS `hostIpv4`, strict validation, flat Want forwarding, privacy, and
  protocol-specific socket routing.
- [ ] Build the TCP request with the opaque `cmfa-<flowId>` marker and call
  `tcpExchange` on the validated public TCP exchange endpoint; keep UDP/DNS
  exact echo unchanged.
- [ ] Re-run ArkTS, runner, structure, and package-isolation regressions.

### Task 14: Rebuild and repeat physical proof

- [ ] Rebuild signed probe/production HAPs through guarded helpers and restore
  unsigned profiles.
- [ ] Require pre-VPN TCP exchange plus UDP/DNS baseline, then full fresh TUN
  correlations, lifecycle/local checks, cleanup, package hashes, and non-stub
  production proof.
