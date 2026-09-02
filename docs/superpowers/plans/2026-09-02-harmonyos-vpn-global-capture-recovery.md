# HarmonyOS VPN Global Capture Recovery Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore real full-device application traffic capture on HarmonyOS 6 while retaining durable VPN ownership and safe migration from the broken ID-scoped build.

**Architecture:** Keep the shared capture policy unchanged, but omit `vpnId` from the platform `VpnConfig` so HarmonyOS uses the last physically proven legacy VPN Extension path. Upgrade durable ownership records to schema v2 with an explicit `PLATFORM_ID | LEGACY_GLOBAL` binding; migrate v1 records as `PLATFORM_ID`, and use binding-specific cleanup and bounded reclaim.

**Tech Stack:** ArkTS, HarmonyOS NetworkKit VPN Extension, Hypium, Node structure tests, Hvigor, HDC physical-device proofs.

---

## Chunk 1: Lock the regression and ownership migration

### Task 1: Add failing global-capture driver tests

**Files:**
- Modify: `harmony/entry/src/test/HarmonyVpnConnectionDriver.test.ets`
- Modify: `harmony/tests/structure/phase4-vpn-config.test.mjs`
- Modify: `harmony/tests/structure/vpn-ownership-recovery-contract.test.mjs`

- [ ] Add `VpnPlatformOwnershipBinding` to test ownership records and helpers.
- [ ] Change the exact platform-config assertion to require `config.vpnId === undefined`, `trustedApplications` empty, and `blockedApplications` containing only the VPN bundle.
- [ ] Add tests proving a new session persists `LEGACY_GLOBAL`, a live stop uses parameterless `destroy()`, and an ID-scoped v1 migration still calls `destroyWithVpnId`.
- [ ] Add a test proving a persisted `LEGACY_GLOBAL` owner authorizes one `2203002 -> destroy() -> retry` sequence, but never a second reclaim.
- [ ] Run `cd harmony && ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test` and confirm the new expectations fail against the current ID-scoped implementation.
- [ ] Run the two Node structure tests and confirm their new binding/config assertions fail for the expected reason.

### Task 2: Add failing ownership-store v2 tests

**Files:**
- Modify: `harmony/platform/src/test/HarmonyVpnOwnershipStore.test.ets`

- [ ] Extend test ownership records with explicit binding.
- [ ] Add a fixture for a version-1 `{version, phase, vpnId}` document and assert it reads as `PLATFORM_ID`.
- [ ] Assert all new writes use version 2 and persist exactly one `binding` field.
- [ ] Assert v2 `LEGACY_GLOBAL` and `PLATFORM_ID` records round-trip and remain exact-match inputs to `clearExpected`.
- [ ] Run `cd harmony && ./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test` and confirm the new v2 assertions fail against the v1 store.

## Chunk 2: Implement binding-aware ownership

### Task 3: Extend the shared ownership contract

**Files:**
- Modify: `harmony/shared/src/main/ets/vpn/VpnPorts.ets`

- [ ] Add `export type VpnPlatformOwnershipBinding = 'PLATFORM_ID' | 'LEGACY_GLOBAL';`.
- [ ] Add `binding: VpnPlatformOwnershipBinding` to `VpnPlatformOwnershipRecord`.
- [ ] Run the shared and structure tests; expected intermediate result is compilation failures only at callers that have not yet supplied binding.

### Task 4: Upgrade the durable store to schema v2

**Files:**
- Modify: `harmony/platform/src/main/ets/vpn/HarmonyVpnOwnershipStore.ets`
- Test: `harmony/platform/src/test/HarmonyVpnOwnershipStore.test.ets`

- [ ] Set the write schema version to 2 and serialize exactly `version`, `phase`, `vpnId`, and `binding`.
- [ ] Parse version-1 documents with exactly the old three fields and normalize them to `binding: 'PLATFORM_ID'`.
- [ ] Parse version-2 documents only when all four fields occur once and binding is in the closed allowlist.
- [ ] Include binding in exact-match, claim reconciliation, and cloned record logic.
- [ ] Run the platform unit tests and require no ArkTS errors or `ERROR: Error in` Hypium failures.

## Chunk 3: Restore the legacy global-capture platform path

### Task 5: Make the connection driver binding-aware

**Files:**
- Modify: `harmony/entry/src/main/ets/vpn/HarmonyVpnConnectionDriver.ets`
- Test: `harmony/entry/src/test/HarmonyVpnConnectionDriver.test.ets`

- [ ] Remove `vpnId` from `createPlatformVpnConfig`; retain blocked-self and empty trusted lists.
- [ ] Generate an internal marker and persist all new `PREPARED`, `ACTIVE`, and `RELEASED` records with `binding: 'LEGACY_GLOBAL'`.
- [ ] Recover `PLATFORM_ID` by exact `destroyWithVpnId`; recover `LEGACY_GLOBAL` by deferring cleanup until a legacy create returns `2203002`.
- [ ] Destroy live and create-failure `LEGACY_GLOBAL` sessions with parameterless `destroy()` before writing `RELEASED` and exact-clearing the marker.
- [ ] Keep reclaim bounded to one attempt and create the retry connection only after the original connection has been destroyed.
- [ ] Run the entry unit tests and require no ArkTS errors or `ERROR: Error in` failures.
- [ ] Run the focused Node VPN config/ownership tests and require all pass.

## Chunk 4: Build and physical-device release gate

### Task 6: Verify the debug build on the physical phone

**Files:**
- Generated, ignored: `harmony/artifacts/phase1-native-provenance.json`
- Generated, ignored: `harmony/artifacts/phase1-device-proof.json`
- Generated, ignored: `harmony/artifacts/home-traffic-device-proof-current.json`
- Generated, ignored: `harmony/artifacts/proxy-delay-device-proof-current.json`
- Generated, ignored: `harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap`

- [ ] Build a fresh signed debug HAP with the repository's guarded signing script and confirm unsigned baseline restoration.
- [ ] Build a fresh signed Traffic Probe HAP with `.omx/task16-build-signed-probe.mjs` and confirm its unsigned baseline restoration and `signedHapFresh: true` result.
- [ ] Inspect the paired production/probe packages with `inspect-phase4-packages.mjs` before running traffic evidence.
- [ ] Run Phase 1 physical-device proof and require install, launch, pull, and cleanup pass.
- [ ] Run `run-proxy-delay-device-proof.mjs` against the current production HAP, persist `proxy-delay-device-proof-current.json`, and select the lowest-latency non-timeout terminal node without exposing its label.
- [ ] Start VPN using that proven node and confirm both its `runtime-selected` semantic marker and the system VPN indicator.
- [ ] Record `multitun-vpn1` counters before and after a controlled Traffic Probe run; require packet/byte growth.
- [ ] Pull the privacy-safe runtime journal and require TUN ingress records and nonzero counters.
- [ ] Open an HTTPS external page in the device browser and require no network-error layout.
- [ ] Stop VPN cleanly and require the system VPN indicator to disappear.

### Task 7: Build and install the formal release HAP

**Files:**
- Generated, ignored: `harmony/entry/build/default/outputs/release/*.hap`
- Generated, ignored: `harmony/artifacts/release-build-provenance.json`
- Local secure orchestration: `.omx/task-release-build-signed.mjs`

- [ ] Create the ignored secure wrapper by adapting `.omx/task16-build-signed-production.mjs`; it must select exactly one non-probe signing profile, hash and save the unsigned baseline, and restore that baseline in `finally` without printing signing paths.
- [ ] In the wrapper, run `harmony/hvigorw --mode module -p module=entry@default -p product=default -p buildMode=release compileNative`, then the release CMake/Ninja target if Hvigor exposes it, followed by the same command ending in `assembleHap`.
- [ ] Discover exactly one fresh signed HAP below `harmony/entry/build/default/outputs`, reject paths under the debug `outputs/default` directory, and write a redacted `release-build-provenance.json` containing build mode, repo-relative HAP path, SHA-256, size, signing verification result, and unsigned-baseline restoration result.
- [ ] Verify the release signature with `hap-sign-tool.jar verify-app` into a temporary directory, then delete the extracted certificate/profile; inspect the archive/module metadata for bundle `com.github.kr328.clash.harmony`, version `1.0.0` / code `1000000`, and absence of `ohosTest`, Traffic Probe, and self-test entries.
- [ ] Install the release HAP with `hdc install -r`, launch `EntryAbility`, and confirm the home semantic IDs appear.
- [ ] Confirm the device package metadata reports the expected bundle/version and the installed package is accepted by the device; record the host SHA-256 as the immutable release artifact identity.
- [ ] Run `git diff --check`, request code review, commit the implementation with a Lore message, and leave the branch unpushed.
