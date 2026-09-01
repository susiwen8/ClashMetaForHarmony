# HarmonyOS Geodata Management Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage the canonical `geoip.metadb` with repairable startup, verified online staging, journaled apply/rollback, and bundled/previous restore.

**Architecture:** Separate immutable packaged baseline from runtime metadata. A minimal repair composition exists before the full PlatformGraph; management transactions use candidate/previous/metadata/journal files and only apply while all runtimes are fully stopped.

**Tech Stack:** ArkTS, CoreFileKit, NetworkKit HTTP, SHA-256 sidecars, RDB-independent metadata, ArkUI.

---

## Chunk 1: Models, health and startup

### Task 1: Add shared geodata contracts

**Files:**
- Create `GeodataModels.ets`, `GeodataPorts.ets`, `GeodataService.ets` and tests; update shared barrel.

- [ ] Test closed health/operation states, metadata descriptors, runtime gate and privacy.

### Task 2: Make startup preserve trusted runtime versions and expose repair state

**Files:**
- Modify `HarmonyGeodataInstaller.ets`, `PlatformFactory.ets`, composition state/CoreComposition/Index and tests.
- Modify: `harmony/entry/src/main/ets/bootstrap/ApplicationComposition.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/platform/src/test/PlatformFactory.test.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`

- [ ] Write RED tests for trusted-newer preservation, missing/corrupt baseline, metadata mismatch and `GEODATA_REPAIR_REQUIRED` routing.
- [ ] Implement minimal repair composition and full-graph retry.

## Chunk 2: Manager transaction

### Task 3: Implement health/metadata/journal recovery

**Files:**
- Create `HarmonyGeodataManager.ets` and platform tests.
- Modify: `harmony/platform/src/main/ets/files/FileDriver.ets`
- Modify: `harmony/platform/src/main/ets/files/HarmonyFileDriver.ets`
- Modify: `harmony/platform/src/test/fakes/PlatformFakes.ets`
- Modify: `harmony/platform/src/test/HarmonyFileDriver.test.ets`
- Modify: `harmony/platform/src/test/List.test.ets`

- [ ] Test every startup recovery matrix row: candidate-only, PREPARED old live, new live/old metadata, unknown live, interrupted rollback and metadata mismatch.
- [ ] Extend `FileDriver` with fsync, implement it in HarmonyFileDriver/fakes, and implement bounded exact JSON metadata/journal on that shared file abstraction.

### Task 4: Add verified online download and stopped-only apply

**Files:**
- Add streaming geodata downloader/sidecar parser, manager operations and tests.
- Modify: `harmony/platform/src/main/ets/PlatformFactory.ets` so `PlatformGraph` exposes `GeodataManagerPort`.
- Create: `harmony/entry/src/main/ets/runtime/GeodataRuntimeGateAdapter.ets` combining `VpnSessionRegistry` and `ProfileApplication` local-runtime state.
- Modify: `ApplicationComposition.ets` and `CoreComposition.ets` so READY exposes a shared `GeodataService`; repair state exposes only the repair service.

- [ ] Test strict `.sha256sum`, redirects, max bytes, short IO, checksum/size failure, exclusive transaction, runtime gate including AWAITING_CONSENT/local runtime, rollback and restart-required flag.
- [ ] Implement download while running but apply/restore only while fully stopped.

## Chunk 3: UI and proof

### Task 5: Add Geodata page

**Files:**
- Create `GeodataViewModel.ets`, `GeodataPage.ets`; modify Home/Index/composition/resources and tests.
- Modify: `harmony/entry/src/main/ets/pages/HomePage.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Modify: `harmony/entry/src/test/HomeViewModel.test.ets`, `ApplicationComposition.test.ets`, `List.test.ets`
- Create: `harmony/tests/structure/geodata-management-contract.test.mjs`

- [ ] Test loading/health/download/apply/previous/bundled/restart/repair and stale result suppression.
- [ ] Add safe semantic IDs and no absolute paths/full digest in public state.

### Task 6: Verify package and device behavior

- [ ] Run Shared/Platform/Entry hvigor commands, `node --test harmony/tests/structure/geodata-asset-contract.test.mjs harmony/tests/structure/geodata-management-contract.test.mjs`, the full structure suite and `git diff --check`; require zero failures.
- [ ] Build provenance and signed HAP with the exact commands from the VPN ownership plan. Without a local signing profile, unsigned/incomplete `SIGNING_REQUIRED` is allowed only for CI; this machine must produce signed `result=pass`.
- [ ] Create `run-geodata-device-proof.mjs` with schema/example/contract. Run it to prove stopped update/apply, running download/apply rejection, process restart adoption, corrupt candidate rollback and offline bundled restore; output `harmony/artifacts/geodata-device-proof.json` with only hashes/status booleans.
