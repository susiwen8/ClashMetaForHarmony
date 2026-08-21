# HarmonyOS HUKS AES-GCM Round-Trip Fix Design

**Status:** User-approved design, pending implementation planning  
**Date:** 2026-08-21  
**Target:** HarmonyOS 6.x / API 23 on physical phones  
**Scope:** Repair encrypted subscription URL round trips without clearing app data  

## 1. Problem

A newly imported remote profile can be persisted with a valid version-1 secret
envelope, but its next refresh fails with `SOURCE_DECRYPT_FAILED` before any
HTTP request is attempted. Device inspection established that each remote
profile has one distinct existing envelope, and that the latest envelope has a
12-byte nonce, non-empty ciphertext, and a 16-byte AES-GCM authentication tag.

The production `HarmonyHuksDriver` currently sends all business bytes through
`updateSession` and then calls `finishSession` with empty options. Its unit fake
accepts this sequence, so the tests do not model the HarmonyOS 6.x device
contract that failed.

## 2. Decision

Use the one-shot AES-GCM sequence demonstrated by the HarmonyOS HUKS samples:

1. Initialize the session with the complete algorithm parameters, nonce,
   purpose, and the stored AE tag for decryption.
2. Pass the business input and the complete operation properties to
   `finishSession`.
3. Do not call `updateSession` for subscription URL secrets.
4. For encryption, split the returned data into ciphertext and the final
   16-byte tag, while retaining support for a tag returned in result
   properties.
5. For decryption, return `finishSession.outData` as plaintext only after HUKS
   authenticates the stored tag.

Subscription URLs are small control-plane secrets, so a one-shot operation is
the narrowest reliable solution. This change does not generalize the driver
into a streaming encryption API.

## 3. Compatibility and Data Preservation

- Keep the HUKS alias `cmfa.subscription.secret.master.v1` unchanged.
- Keep envelope version 1 and key-alias version 1 unchanged.
- Keep the current 12-byte nonce and 16-byte tag encoding.
- Do not delete profiles, envelopes, RDB rows, configuration revisions, or the
  existing HUKS key.
- Existing envelopes are retried through the corrected decrypt sequence. If an
  individual envelope still fails authentication, the application retains its
  current safe `SOURCE_DECRYPT_FAILED` state and allows source replacement.
- Installation on the physical phone must be an in-place install that preserves
  application data.

No data migration is required because the stored envelope shape is already
valid and only the HUKS operation sequence changes.

## 4. Code Boundaries

`HarmonyHuksDriver` owns the change. It will construct complete finish options,
run one HUKS operation per encrypt/decrypt call, separate encryption output,
and retain the existing redacted stage/code diagnostics.

`HuksSubscriptionSecretStore`, profile use cases, RDB codecs, download logic,
and UI error mapping remain unchanged. They already provide the correct
envelope, persistence, and failure boundaries.

## 5. Error Handling

- Key lookup, generation, and session initialization retain their current
  fail-closed behavior.
- A failed encryption finish aborts the session and maps to the existing secret
  write failure at the store boundary.
- A failed decryption finish aborts the session and maps to
  `SOURCE_DECRYPT_FAILED` without exposing URL, ciphertext, nonce, tag, alias,
  or device identifiers.
- Diagnostics record only the operation stage and numeric HUKS business error.
- Malformed version, nonce, or tag inputs continue to fail before calling HUKS.

## 6. Test Design

TDD starts with a regression test that fails against the current driver. The
test double will model the desired one-shot contract and assert:

- no `updateSession` call occurs;
- encryption finish receives the original plaintext through `inData`;
- decryption finish receives ciphertext through `inData`;
- decryption finish properties include the 16-byte AE tag and 12-byte nonce;
- business bytes are never passed as the optional authentication token;
- the round trip restores the original UTF-8 bytes.

Existing key-lifecycle, output-shape, redaction, secret-envelope, and profile
management tests remain in the verification set. Diagnostic tests will expect
the failure stage to move from `encrypt.update` to `encrypt.finish` where
appropriate.

## 7. Device Verification

1. Build a fresh signed debug HAP from the current worktree.
2. Confirm one physical HarmonyOS 6.x target is connected.
3. Install in place without uninstalling or clearing data.
4. Launch the app and retry the existing newly created remote profile.
5. Verify the error is no longer `SOURCE_DECRYPT_FAILED` and that execution
   reaches download/parse handling or imports the profile successfully.
6. Confirm the profile and its stored source remain present after relaunch.

The subscription credential and downloaded node contents must not appear in
terminal output, logs, screenshots, test fixtures, or the final report.

## 8. Non-Goals

- Changing subscription parsing, HTTP behavior, VPN/TUN, proxy routing, or UI.
- Rotating or exporting the HUKS key.
- Re-encrypting all stored envelopes eagerly.
- Adding a second encryption library or dependency.
- Clearing application data to hide compatibility failures.
