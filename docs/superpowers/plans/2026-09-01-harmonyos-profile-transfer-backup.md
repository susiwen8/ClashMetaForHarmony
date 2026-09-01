# HarmonyOS QR Import, Export, and Backup Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add QR URL import, exact YAML export, and passphrase-encrypted portable profile backup/restore.

**Architecture:** Reuse existing profile import/validation and file picker flows. Add platform adapters for ScanKit, exact export, and PBKDF2/AES-GCM; restore uses a journaled two-phase additive transaction and rewraps remote URLs into new HUKS envelopes.

**Tech Stack:** ScanKit, CoreFileKit, CryptoArchitectureKit, HUKS, RDB, ArkUI.

---

## Chunk 1: Shared contracts and QR

### Task 1: Add strict transfer models/ports

**Files:**
- Create shared transfer models, ports and tests; update shared barrel.

- [ ] Test exact keys, closed result enums, limits, safe filenames and no raw secret serialization.
- [ ] Implement minimal contracts.

### Task 2: Add system QR scanner and import flow

**Files:**
- Create `HarmonyQrScanner.ets` and tests.
- Modify import ViewModel/sheet, composition wiring, resources and structure tests.

- [ ] Write RED tests for QR-only ScanKit options, album, cancellation, invalid scheme, HTTP consent, duplicate tap and raw-value privacy.
- [ ] Implement system `startScanForResult`; do not add CAMERA permission.
- [ ] Run Platform/Entry tests.

## Chunk 2: Exact YAML export

### Task 3: Implement bounded rollback-safe YAML export

**Files:**
- Create platform YAML exporter + tests.
- Modify profile detail ViewModel/page and composition.

- [ ] Test current-revision requirement, sandbox path, size/hash, picker cancellation, short IO, rollback, safe name and zero secret decrypt.
- [ ] Implement exact streaming copy and sensitive-data confirmation UI.

## Chunk 3: Encrypted backup

### Task 4: Implement portable backup codec

**Files:**
- Create platform CryptoFramework PBKDF2/AES-GCM codec and tests.

- [ ] Add known-answer/tamper/wrong-passphrase/KDF-bound/64MiB streaming-bound tests.
- [ ] Implement versioned authenticated envelope; never persist plaintext/passphrase/key.

### Task 5: Implement two-phase backup snapshot and restore

**Files:**
- Create shared backup use case and platform merge/journal adapters.
- Modify RDB/profile/secret ports and add tests.

- [ ] Test 128-profile/16MiB-entry/64MiB aggregate limits, full round trip, HUKS rewrap, ID conflicts, active/selections mapping, zero-mutation validation failure, RDB failure cleanup and crash-stage reconcile.
- [ ] Define a closed journal schema containing only transaction ID, stage, regenerated profile IDs, provisional secret refs and non-secret counters/hashes. Explicitly forbid plaintext URLs, YAML bytes, filesystem paths, HUKS aliases/envelopes, crypto nonce/tag/ciphertext and profile names.
- [ ] Add RED tests for exact journal keys, absence of every raw secret fragment, malformed-journal fail-closed cleanup, journal removal after commit/rollback, and startup reconcile for every stage.
- [ ] Implement phase-1 stage/validate/provisional refs and one phase-2 RDB merge transaction.

### Task 6: Add Profiles backup/restore UI and physical proof

- [ ] Add passphrase dialogs, export/restore actions, pending/error states and structure tests.
- [ ] Run all module/structure tests.
- [ ] Build signed HAP and verify QR camera, YAML export, encrypted backup, reinstall and restore on device.

Exact module commands are the Shared/Platform/Entry hvigor commands used in the other plans. Add `harmony/entry/src/test/List.test.ets`, `harmony/platform/src/test/List.test.ets`, and `harmony/shared/src/test/List.test.ets` registration for every new suite. Add `harmony/tests/structure/profile-transfer-contract.test.mjs` and run it before the full structure suite. Device proof is implemented as `run-profile-transfer-device-proof.mjs` plus schema/example/contract and writes `harmony/artifacts/profile-transfer-device-proof.json`.
