# HarmonyOS VPN Ownership Recovery Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the SDK-generated VPN identity so a new Extension process can reclaim and replace stale system VPN ownership after crash or upgrade.

**Architecture:** Add a bounded shared ownership-store port, an atomic platform file implementation, and inject it into `HarmonyVpnConnectionDriver`. The driver becomes the sole owner of recover/generate/persist/create/destroy/clear ordering while keeping the full-capture configuration unchanged.

**Tech Stack:** ArkTS, CoreFileKit, NetworkKit VPN Extension API 20+, Hypium, Node structure tests, physical HDC proof.

---

## Chunk 1: Durable ownership

### Task 1: Define and implement the ownership store

**Files:**
- Modify: `harmony/shared/src/main/ets/vpn/VpnPorts.ets`
- Modify: `harmony/shared/Index.ets`
- Create: `harmony/platform/src/main/ets/vpn/HarmonyVpnOwnershipStore.ets`
- Create: `harmony/platform/src/test/HarmonyVpnOwnershipStore.test.ets`
- Modify: `harmony/platform/Index.ets`
- Modify: `harmony/platform/src/test/List.test.ets`

- [ ] Write failing tests for missing, PREPARED/ACTIVE/RELEASED round-trip, 256-byte bound, corrupt/wrong-version/duplicate-key/invalid-phase/invalid-ID fail-closed, unique-temp write/write races, short write, fsync/rename failure, atomic-claim `clearExpected`, stale claims, and idempotent repeated reads/clears.
- [ ] Run `cd harmony && ./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test`; confirm the new test is reported as `Error in HarmonyVpnOwnershipStoreTest` (Hvigor may still exit 0).
- [ ] Implement `VpnPlatformOwnershipStorePort` and atomic `<filesDir>/vpn/active-platform-vpn-v1.json` storage without logging the ID.
- [ ] Re-run the exact Platform command; require `BUILD SUCCESSFUL` and no `Error in` output.

### Task 2: Restore the real API 20 VPN identity lifecycle

**Files:**
- Modify: `harmony/entry/src/main/ets/vpn/HarmonyVpnConnectionDriver.ets`
- Modify: `harmony/entry/src/test/HarmonyVpnConnectionDriver.test.ets`
- Modify: `harmony/tests/structure/phase4-vpn-config.test.mjs`
- Modify: `harmony/tests/structure/api20-sdk-contract.test.mjs`

- [ ] Replace legacy expectations with failing tests for PREPARED/ACTIVE/RELEASED recovery, generate → PREPARED → create/FD → ACTIVE, real handle ID, ID-based normal destroy → RELEASED → clear, failed create cleanup, platform-destroy vs store-cleanup retry separation, 19900001 recovery, corrupt-store rejection, and empty-store one-shot legacy fallback.
- [ ] Run `cd harmony && ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test` plus `node --test harmony/tests/structure/phase4-vpn-config.test.mjs harmony/tests/structure/api20-sdk-contract.test.mjs`; confirm RED.
- [ ] Implement the minimal ordered driver state machine; only successful platform destroy may clear the durable ID.
- [ ] Re-run focused tests and confirm GREEN.

## Chunk 2: Wiring and proof

### Task 3: Inject one Extension-private store

**Files:**
- Modify: `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets`
- Modify: `harmony/entry/src/test/VpnExtensionComposition.test.ets`
- Create: `harmony/tests/structure/vpn-ownership-recovery-contract.test.mjs`

- [ ] Write failing wiring/privacy tests proving `filesDir` store injection and no raw ID in RPC/evidence/Hilog/UI.
- [ ] Run the Entry command and `node --test harmony/tests/structure/vpn-ownership-recovery-contract.test.mjs`; confirm RED.
- [ ] Implement composition factory wiring.
- [ ] Re-run both commands; require no Hypium `Error in` and all Node tests pass.

### Task 4: Build and run physical recovery proof

**Files:**
- Create: `harmony/tests/bin/run-vpn-ownership-recovery-device-proof.mjs`
- Create: `harmony/tests/fixtures/vpn-ownership-recovery-device-proof.schema.json`
- Create: `harmony/tests/fixtures/vpn-ownership-recovery-device-proof.example.json`
- Create: `harmony/tests/structure/vpn-ownership-recovery-device-proof-contract.test.mjs`

- [ ] Write the runner/schema/example contract test first and run `node --test harmony/tests/structure/vpn-ownership-recovery-device-proof-contract.test.mjs`; confirm RED before implementing the four proof files, then rerun and require GREEN.
- [ ] Run `cd harmony && ./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test`, the same command with `platform@default`, and the same command with `entry@default`; require `BUILD SUCCESSFUL` and no `Error in` output. Then run `node --test harmony/tests/structure/*.test.mjs` and `git diff --check`; require zero failures.
- [ ] Build native/package provenance with `GOMODCACHE=/Users/susiwen8/go/pkg/mod node harmony/tests/bin/build-phase1-native.mjs --out harmony/artifacts/phase1-native-provenance.json`; on this machine build the signed HAP with `GOMODCACHE=/Users/susiwen8/go/pkg/mod node .omx/task16-build-signed-production.mjs` and require manifest `result=pass`.
- [ ] Implement the runner to install `entry-default-signed.hap`, prove normal start/stop and TCP/UDP/DNS, start again, reinstall in place, relaunch and require persisted-owner reclaim without reboot.
- [ ] In the same runner force-stop the bundle while active, relaunch, start and stop again. Persist only stage booleans/counts/hashes—never the vpnId.
- [ ] Run `node harmony/tests/bin/run-vpn-ownership-recovery-device-proof.mjs --out harmony/artifacts/vpn-ownership-recovery-device-proof.json`; require schema-valid `result=pass`.
