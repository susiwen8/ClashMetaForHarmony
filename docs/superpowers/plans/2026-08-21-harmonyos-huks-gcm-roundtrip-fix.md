# HarmonyOS HUKS AES-GCM Round-Trip Fix Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make existing and newly stored subscription URLs decrypt reliably on HarmonyOS 6.x without clearing app data or replacing the source.

**Architecture:** Keep the version-1 envelope, HUKS alias, secret store, and profile use cases intact. Replace only the `HarmonyHuksDriver` streaming sequence with the HarmonyOS one-shot `finishSession` sequence, then expose the existing detail-page refresh action as a recovery path for stored decrypt failures.

**Tech Stack:** ArkTS, HarmonyOS UniversalKeystoreKit (HUKS), Hypium module tests, Hvigor, HDC/UITest, Node.js verification scripts.

**Spec:** `docs/superpowers/specs/2026-08-21-harmonyos-huks-gcm-roundtrip-fix-design.md`

**Dirty-worktree constraint:** The target ArkTS files already contain unrelated uncommitted work. Preserve it. Do not reset, restore, clean, or commit entire overlapping files. Use scoped diffs after every task; implementation commits are intentionally deferred unless the user later authorizes a safe partial-staging strategy.

---

## Chunk 1: Preserve Evidence and Repair the HUKS Contract

### Task 1: Capture the pre-fix envelope integrity baseline

**Files:**
- Read only: device RDB `cmfa_profiles.db`
- Read only: device `profile-secrets/*.json`
- Temporary local evidence: `/tmp/cmfa-huks-fix-*/` with mode `0700`

- [ ] **Step 1: Confirm exactly one physical target and the installed bundle**

Run `hdc list targets` and `hdc shell bm dump -n com.github.kr328.clash.harmony` with the HDC binary under the installed DevEco Studio SDK.

Expected: exactly one target and an installed debug application with bundle name `com.github.kr328.clash.harmony`. Do not print the device identifier in the final report.

- [ ] **Step 2: Pull a read-only database/envelope snapshot into a protected temporary directory**

Create the directory with `mktemp -d /tmp/cmfa-huks-fix.XXXXXX`, set mode `0700`, and use `hdc file recv` for these exact remote directories:

```text
/data/app/el2/100/database/com.github.kr328.clash.harmony/entry/rdb
/data/app/el2/100/base/com.github.kr328.clash.harmony/haps/entry/files/profile-secrets
```

Expected: the snapshot contains the database plus WAL files and managed envelope files. Never display profile IDs, secret refs, envelope file names, URLs, ciphertext, nonce, or tags.

- [ ] **Step 3: Select the newest persisted decrypt failure without exposing values**

Pipe this exact query directly from `sqlite3` into a local Node process; do not echo its rows:

```sql
SELECT id, source_secret_ref, last_error_json, updated_at
FROM profiles
WHERE json_extract(last_error_json, '$.code') = 'SOURCE_DECRYPT_FAILED'
ORDER BY updated_at DESC, id ASC
LIMIT 1;
```

The Node process must:

1. requires the error code to be `SOURCE_DECRYPT_FAILED`;
2. decodes the `utf16hex:` reference in memory;
3. requires the corresponding envelope file to exist;
4. validates envelope version 1, alias version 1, nonce length 12, tag length 16, and non-empty ciphertext;
5. writes the raw profile ID and ref only inside the mode-`0700` temporary directory so later UITest/device checks select the same profile without printing either value;
6. writes SHA-256 digests of the encoded ref and envelope bytes to `before-integrity.json`.

Expected terminal output, with no sensitive values:

```json
{"eligibleProfileCount":1,"referencePresent":true,"envelopeShapeValid":true}
```

- [ ] **Step 4: Record the baseline as temporary evidence, not repository data**

Run `git status --short` and verify the snapshot created no repository file. Keep the temporary directory only until post-install comparison is complete.

### Task 2: Add the failing one-shot HUKS regression test

**Files:**
- Modify: `harmony/platform/src/test/HuksSubscriptionSecretStore.test.ets:35-220`
- Test: `harmony/platform/src/test/HuksSubscriptionSecretStore.test.ets:318-430`

- [ ] **Step 1: Extend the HUKS test double to record finish calls**

Add a `RecordedFinishCall` value that records only safe structural data:

```typescript
class RecordedFinishCall {
  readonly handle: number;
  readonly inDataLength: number;
  readonly tokenLength: number;
  readonly nonceLength: number;
  readonly tagLength: number;

  constructor(handle: number, inDataLength: number, tokenLength: number, nonceLength: number, tagLength: number) {
    this.handle = handle;
    this.inDataLength = inDataLength;
    this.tokenLength = tokenLength;
    this.nonceLength = nonceLength;
    this.tagLength = tagLength;
  }
}
```

Update `ScriptedSessionOperations.finishSession` to record those lengths. Its first successful finish returns `inData + 16-byte tag`; its second successful finish returns `inData`. Keep `updateSession` available in the interface, but record every call so the regression test can reject its use.

- [ ] **Step 2: Replace the permissive round-trip assertion with the desired contract**

The test must execute the real `HarmonyHuksDriver` and assert:

```typescript
const plaintext = utf8Bytes('hello');
const encrypted = await driver.encrypt(plaintext);
const decrypted = await driver.decrypt(encrypted);

expect(operations.updateCalls.length).assertEqual(0);
expect(operations.finishCalls.length).assertEqual(2);
expect(operations.finishCalls[0].inDataLength).assertEqual(plaintext.length);
expect(operations.finishCalls[0].nonceLength).assertEqual(12);
expect(operations.finishCalls[0].tagLength).assertEqual(0);
expect(operations.finishCalls[0].tokenLength).assertEqual(0);
expect(operations.finishCalls[1].inDataLength).assertEqual(encrypted.ciphertext.length);
expect(operations.finishCalls[1].nonceLength).assertEqual(12);
expect(operations.finishCalls[1].tagLength).assertEqual(16);
expect(operations.finishCalls[1].tokenLength).assertEqual(0);
expect(decrypted.length).assertEqual(plaintext.length);
for (let index: number = 0; index < plaintext.length; index += 1) {
  expect(decrypted[index]).assertEqual(plaintext[index]);
}
```

Rename the test to `passesBusinessBytesAndCompleteGcmPropertiesToFinishSession`.

- [ ] **Step 3: Move the injected operation-failure test to the finish boundary**

Make `ScriptedSessionOperations` accept a `finishError`, throw it from `finishSession`, and update the diagnostic expectation to:

```typescript
expect(diagnostics.events[0].stage).assertEqual('encrypt.finish');
expect(diagnostics.events[0].code).assertEqual(12000006);
```

The error and diagnostics must still contain neither plaintext nor a URL.

- [ ] **Step 4: Run the platform test and verify RED**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
```

Expected: the new round-trip test fails because the current driver makes two `updateSession` calls and sends empty finish options. Compilation must succeed; an unrelated compile error is not an acceptable RED signal.

- [ ] **Step 5: Inspect the scoped test diff**

Run `git diff --check` and `git diff` for `harmony/platform/src/test/HuksSubscriptionSecretStore.test.ets`.

Expected: only the one-shot contract fake/assertions and finish-stage diagnostic expectation changed. Do not stage the whole file because it predates this fix as modified worktree state.

### Task 3: Implement one-shot HUKS encryption and decryption

**Files:**
- Modify: `harmony/platform/src/main/ets/secrets/HarmonyHuksDriver.ets:42-118`
- Modify: `harmony/platform/src/main/ets/secrets/HarmonyHuksDriver.ets:260-420`
- Test: `harmony/platform/src/test/HuksSubscriptionSecretStore.test.ets`

- [ ] **Step 1: Add complete finish options**

Replace the update-only helper with:

```typescript
function createFinishOptions(
  nonce: Uint8Array,
  purpose: number,
  inData: Uint8Array,
  tag?: Uint8Array
): HuksOptionsContract {
  const initOptions: HuksOptionsContract = createInitOptions(nonce, purpose, tag);
  return {
    properties: initOptions.properties,
    inData: cloneBytes(inData)
  };
}
```

- [ ] **Step 2: Make encryption finish-only**

After `initSession`, call exactly:

```typescript
const finishResult = await this.operations.finishSession(
  sessionHandle,
  createFinishOptions(nonce, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, plaintext)
);
```

Do not call `updateSession`. Keep the stage as `encrypt.finish` until HUKS returns, set `sessionCompleted`, then switch to `encrypt.result` while splitting the output.

- [ ] **Step 3: Make decryption finish-only**

After validating the envelope and initializing the decrypt session, call:

```typescript
const finishResult = await this.operations.finishSession(
  sessionHandle,
  createFinishOptions(
    payload.nonce,
    huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
    payload.ciphertext,
    payload.tag
  )
);
sessionCompleted = true;
return copyOptionalBytes(finishResult.outData);
```

Do not concatenate update/finish output and do not pass business data through the optional token argument.

- [ ] **Step 4: Simplify encryption output separation**

Change `separateEncryptResult` to accept one `HuksReturnResultContract`. Treat `outData` as `ciphertext + tag` unless a valid `HUKS_TAG_AE_TAG` result property is present. Retain the checks for a malformed property tag and incomplete output. Remove `concatenateBytes` only after `rg` proves it has no remaining caller.

- [ ] **Step 5: Run the platform test and verify GREEN**

Run the platform module test command from Task 2 again.

Expected: exit code 0; the one-shot contract, key lifecycle, redaction, envelope shape, missing/tampered secret, and diagnostics tests all pass.

- [ ] **Step 6: Check the production diff and forbidden leakage**

Run `git diff --check` for the driver and its test, then search those files for new plaintext, URL, ciphertext, nonce, tag, or alias logging.

Expected: no secret-bearing logging and no unrelated production change.

---

## Chunk 2: Restore Recovery UI and Prove the Physical-Device Fix

### Task 4: Add and implement decrypt-failure retry policy

**Files:**
- Modify: `harmony/entry/src/test/ProfileDetailViewModel.test.ets:220-270`
- Modify: `harmony/entry/src/main/ets/presentation/ProfileDetailViewModel.ets:290-315`
- Modify: `harmony/entry/src/main/ets/pages/ProfileDetailPage.ets:70-105`
- Modify: `harmony/entry/src/main/resources/base/element/string.json:445-455`

- [ ] **Step 1: Write the failing presentation test**

Create a remote profile with a `SOURCE_DECRYPT_FAILED` error, queue a successful refresh result, and assert:

```typescript
expect(viewModel.current().sourceRepairRequired).assertTrue();
expect(viewModel.current().canRefresh).assertTrue();
expect(viewModel.current().canReplaceSubscriptionUrl).assertTrue();

await viewModel.requestRefresh();

expect(application.refreshCommands.length).assertEqual(1);
expect(application.refreshCommands[0].profileId).assertEqual('decrypt-retry');
```

Extend the existing `SOURCE_SECRET_MISSING` replacement test with `expect(viewModel.current().canRefresh).assertFalse()` so missing and unsupported sources remain replacement-only.

- [ ] **Step 2: Run the entry test and verify RED**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: the decrypt-retry test fails because `canRefresh` is currently false.

Hvigor currently exits 0 even when local ArkTS cases fail, so the exit code is
not the RED oracle. Parse
`entry/.test/default/intermediates/test/coverage_data/test_result.txt`, locate
the exact new test name, require it to exist, and require its immediately
following `result=` line to be `Failure` or `Error`. A missing case/report or a
compile error is not an acceptable RED signal.

```bash
node -e 'const fs=require("fs");const s=fs.readFileSync("entry/.test/default/intermediates/test/coverage_data/test_result.txt","utf8");const m=s.match(/test=retriesDecryptFailureWithoutReplacingSource\n(?:[^\n]*\n)*?result=(Success|Failure|Error)/u);if(!m||!new Set(["Failure","Error"]).has(m[1]))process.exit(1)'
```

- [ ] **Step 3: Implement the narrow ViewModel policy**

In `buildState`, derive:

```typescript
const decryptRetryAvailable: boolean = profile?.lastError?.code === 'SOURCE_DECRYPT_FAILED';
const canRefresh: boolean = !actionsLocked && profile !== undefined &&
  (!sourceRepairRequired || decryptRetryAvailable);
```

Keep `canReplaceSubscriptionUrl` unchanged so replacement is still available. Do not change `ProfileApplication.isSourceRepairRequired`; persistence and error classification remain stable.

- [ ] **Step 4: Make the warning copy match the available action**

Add `detail_source_retry_or_replace` with this value:

```text
当前保存的订阅来源暂时无法读取，可重试刷新或替换来源。
```

In `ProfileDetailPage`, render that resource only when `sourceRepairRequired && canRefresh`; retain `detail_source_repair_required` for replacement-only states.

Assign the existing replacement button the semantic ID `detail.replace` so
physical-device verification can select it without matching localized text.

- [ ] **Step 5: Run the entry test and verify GREEN**

Run the entry module test command again.

Expected: parse `test_result.txt`, require the new decrypt-retry case's result
to be exactly `Success`, and require the existing missing-secret replacement,
plain-HTTP consent, and unsafe-detail redaction cases to remain `Success`.

```bash
node -e 'const fs=require("fs");const s=fs.readFileSync("entry/.test/default/intermediates/test/coverage_data/test_result.txt","utf8");const m=s.match(/test=retriesDecryptFailureWithoutReplacingSource\n(?:[^\n]*\n)*?result=(Success|Failure|Error)/u);if(!m||m[1]!=="Success")process.exit(1)'
```

- [ ] **Step 6: Inspect only the recovery-policy diff**

Run `git diff --check` and `git diff` for the four files above. Expected: one boolean policy, one resource, one conditional message, and focused tests only.

### Task 5: Run repository verification and build the signed HAP

**Files:**
- Verify: `harmony/platform/src/main/ets/secrets/HarmonyHuksDriver.ets`
- Verify: `harmony/platform/src/test/HuksSubscriptionSecretStore.test.ets`
- Verify: `harmony/entry/src/main/ets/presentation/ProfileDetailViewModel.ets`
- Verify: `harmony/entry/src/main/ets/pages/ProfileDetailPage.ets`
- Verify: `harmony/entry/src/main/resources/base/element/string.json`
- Generated: `harmony/artifacts/huks-fix-build-evidence.json`
- Generated: `harmony/entry/build/default/outputs/default/entry-default-signed.hap`

- [ ] **Step 1: Run both affected module suites from fresh command invocations**

```bash
cd harmony
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: the platform command exits 0 with zero failed tests. For entry, parse
`entry/.test/default/intermediates/test/coverage_data/test_result.txt`; require
the new decrypt-retry case to be `Success`, and require the complete set of
non-success cases to equal this pre-existing allowlist with no additions:

```text
extensionFactoryUsesTheExactInjectedRegistryForUnexpectedFailureCleanup
nonSharedStopResolvesWithoutTouchingTheSharedRegistry
```

Do not claim the full entry suite is green while those unrelated errors remain.

Use a Node parser that walks `test=` / `result=` pairs, collects every result
other than `Success`, sorts the test names, and deep-compares them with the two
sorted allowlisted names above. The parser exits non-zero for a missing report,
duplicate test record, missing decrypt-retry case, or any added non-success
case.

- [ ] **Step 2: Run focused structural checks**

```bash
node --test \
  harmony/tests/structure/phase3-layer-boundary.test.mjs \
  harmony/tests/structure/phase3-ui-contract.test.mjs \
  harmony/tests/structure/signing-isolation.test.mjs
```

Expected: all listed Node tests pass.

- [ ] **Step 3: Build through the repository-provided build lane**

From the repository root, run:

```bash
node harmony/tests/bin/build-hap.mjs --out harmony/artifacts/huks-fix-build-evidence.json
```

Expected: exit code 0, evidence result `pass`, and a fresh `harmony/entry/build/default/outputs/default/entry-default-signed.hap`.

- [ ] **Step 4: Verify package identity without exposing signing material**

Run the repository HAP inspector for native provenance:

```bash
node harmony/tests/bin/inspect-hap.mjs \
  --hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --build-kind production
```

Then read `module.json` directly from the HAP with `/usr/bin/unzip -p` and pipe
it into Node. The Node process must assert:

```javascript
value.module.name === 'entry'
value.app.bundleName === 'com.github.kr328.clash.harmony'
value.app.targetAPIVersion === 60100023
value.app.minAPIVersion === 60000020
```

Together with the build evidence, assert only:

- file exists and has non-zero size;
- name is not `*-unsigned.hap`;
- module is `entry`;
- bundle is `com.github.kr328.clash.harmony`;
- target/compatible API match the project configuration;
- SHA-256 is recorded for before/after install identity checks.

Do not print certificate paths, profile paths, device IDs, or the subscription credential.

### Task 6: Install in place and verify the preserved envelope twice

**Files:**
- Read only: `/tmp/cmfa-huks-fix-*/before-integrity.json`
- Read only after install: device RDB and target envelope
- No app-data deletion or uninstall

- [ ] **Step 1: Install the exact signed HAP in place**

Run `hdc install -r harmony/entry/build/default/outputs/default/entry-default-signed.hap` with the DevEco HDC binary.

Expected: successful replacement install. Do not use `hdc uninstall`, clear data, delete the HUKS alias, or remove profile files.

- [ ] **Step 2: Launch and verify the existing profile exposes refresh**

Launch `EntryAbility`, open the preserved profile, and dump the layout with UITest. Assert structurally that both `detail.refresh` and the existing replace control are visible, while no plaintext URL is present in the dump.

Use this exact command family with the DevEco HDC binary:

```text
hdc shell aa force-stop com.github.kr328.clash.harmony
hdc shell aa start -a EntryAbility -b com.github.kr328.clash.harmony
hdc shell uitest dumpLayout -p /data/local/tmp/cmfa-huks-layout.json
hdc file recv /data/local/tmp/cmfa-huks-layout.json <protected-temp-layout-path>
hdc shell uitest uiInput click <center-x> <center-y>
```

The local Node selector reads the protected raw profile ID from Task 1, selects
exactly one clickable `profiles.row.<profile-id>` node, validates its bounds,
and emits only center coordinates to the click command. On the detail layout,
select exactly one visible/clickable node for each semantic ID
`detail.refresh` and `detail.replace`; do not match localized text.

- [ ] **Step 3: Refresh the preserved pre-fix profile**

Click `detail.refresh`. Wait for the submitting state to finish by polling the layout instead of sleeping. Assert that the resulting profile detail no longer contains `SOURCE_DECRYPT_FAILED`. A later download, parse, or validation error is useful evidence that HUKS decryption succeeded; a successful valid profile is also acceptable.

Before the click, capture the visible ISO `updatedAt` value only in the
protected temporary directory. Poll a fresh `dumpLayout` at bounded intervals
until that value changes (maximum 30 attempts), then require
`SOURCE_DECRYPT_FAILED` to be absent. Never print the timestamp or layout.

- [ ] **Step 4: Relaunch and perform the second refresh**

Force-stop only the ability/process, relaunch without clearing data, reopen the same profile, and click `detail.refresh` again. Poll to completion and again assert that `SOURCE_DECRYPT_FAILED` is absent.

Reuse the exact force-stop/start, `profiles.row.<profile-id>`, `detail.refresh`,
changed-`updatedAt`, and bounded-poll sequence above. Do not use Home key state,
screen coordinates from the prior process, or a newly imported profile.

- [ ] **Step 5: Compare post-test integrity without displaying values**

Pull a second RDB/envelope snapshot and run the same local checker against the stored raw ref in the protected temporary directory. Output only:

```json
{"referenceUnchanged":true,"envelopeDigestUnchanged":true,"profilePresent":true}
```

Expected: all three booleans are true. This proves the fixed build decrypted the pre-fix envelope without replacing or migrating it.

- [ ] **Step 6: Verify relaunch persistence and clean temporary diagnostics**

Confirm the profile remains listed after relaunch. Move the exact `/tmp/cmfa-huks-fix-*` diagnostic directory and any UITest dumps to Trash, then assert their original paths no longer exist. Do not remove application data.

- [ ] **Step 7: Review the final scoped diff and status**

Run `git diff --check` for these six scoped files and then `git status --short`:

```text
harmony/platform/src/main/ets/secrets/HarmonyHuksDriver.ets
harmony/platform/src/test/HuksSubscriptionSecretStore.test.ets
harmony/entry/src/main/ets/presentation/ProfileDetailViewModel.ets
harmony/entry/src/main/ets/pages/ProfileDetailPage.ets
harmony/entry/src/main/resources/base/element/string.json
harmony/entry/src/test/ProfileDetailViewModel.test.ets
```

Expected: no whitespace errors; unrelated pre-existing changes remain intact; only the six scoped files contain this implementation's code/test/resource hunks. Do not commit overlapping implementation files without explicit user authorization for a safe partial-staging operation.
