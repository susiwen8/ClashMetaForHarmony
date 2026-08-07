# HarmonyOS Phase 3 Profile and Local Runtime Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the first HarmonyOS-native user flow that imports a local file or subscription URL, preserves invalid and last-known-good revisions, enables one profile, and starts/stops the real mihomo local HTTP/SOCKS listener.

**Architecture:** Keep domain policy and use cases in the platform-independent `shared` HAR. Implement RDB, sandbox files, Picker, HTTP, and HUKS behind shared ports in a new `platform` HAR. Compose those adapters with the existing real `CoreService` in `entry`, where focused ViewModels feed resource-backed ArkUI pages while the Phase 1/2 self-test route remains isolated.

**Tech Stack:** HarmonyOS 6.1 target API 23 with API 20 compatibility; Stage model; ArkTS/ArkUI; RDB; CoreFileKit Picker/file APIs; NetworkKit plus API 20 redirect fallback; HUKS AES-GCM; Hypium 1.0.25; Hvigor/ohpm; existing Node.js structure tests; existing C++/Go/mihomo core and HAP provenance tools.

**Design spec:** `docs/superpowers/specs/2026-08-07-harmonyos-phase3-profile-runtime-design.md`

---

## Delivery boundaries

- Work only in `harmony/**`, `docs/harmony/**`, and this plan. Do not modify Android Gradle modules or Android release metadata.
- Apply @superpowers:test-driven-development to every behavior change: add the focused failing test, run it and read the expected failure, make the minimum production change, then rerun the focused and regression lanes.
- Add only the official dev-only `@ohos/hypium` package pinned to `1.0.25`; use hand-written fakes and do not add `@ohos/hamock` or another production dependency.
- Preserve `targetSdkVersion: 6.1.0(23)`, `compatibleSdkVersion: 6.0.0(20)`, `runtimeOS: HarmonyOS`, arm64 production ABI, signing isolation, and the exact real-core package/provenance rules.
- Keep `CoreDebugPage` and its Phase 1/2 device-proof launch path. Normal launch must use `pages/Index`; self-test launch alone may use `pages/CoreDebugPage`.
- Do not add VPN/TUN UI or runtime code, proxy/provider controls, traffic charts, logs, general settings, scheduled refresh, background guarantees, telemetry, or remote diagnostics.
- Never persist plaintext subscription URLs, external Picker URIs, configuration bodies, raw Native errors, stack traces, repository/home paths, or signing material.
- A Simulator result is provisional. Signing and physical-phone Phase 2/3 gates remain `incomplete` and no task may convert them to `pass`.
- Every task ends with its focused verification and a narrow Lore commit. The final task runs @superpowers:verification-before-completion before any completion claim.

## File responsibility map

### Shared domain

| File | Single responsibility |
| --- | --- |
| `harmony/shared/src/main/ets/profile/ProfileModels.ets` | Durable profile, revision, source, and availability types plus invariant helpers. |
| `harmony/shared/src/main/ets/profile/AppErrors.ets` | Stable application error stages/codes and user-safe error construction. |
| `harmony/shared/src/main/ets/profile/SecretRedactor.ets` | Remove URL credentials, paths, query/fragment values, and config-like secrets. |
| `harmony/shared/src/main/ets/profile/CoreErrorMapper.ets` | Convert existing typed `CoreError` operations into allowlisted `AppError` values. |
| `harmony/shared/src/main/ets/profile/ProfilePorts.ets` | Repository, content, source, secret, clock, and ID interfaces used by use cases. |
| `harmony/shared/src/main/ets/profile/SerialCommandQueue.ets` | Serialize mutating profile/runtime commands and collapse duplicate start/stop commands. |
| `harmony/shared/src/main/ets/profile/ProfileCommitService.ets` | Perform recoverable file-first/RDB-second revision commits and compensation. |
| `harmony/shared/src/main/ets/profile/ImportProfileUseCase.ets` | Coordinate initial local/URL acquisition, validation, encryption, and profile creation. |
| `harmony/shared/src/main/ets/profile/RefreshProfileUseCase.ets` | Refresh local/URL profiles without losing a last-known-good revision. |
| `harmony/shared/src/main/ets/profile/ManageProfileUseCases.ets` | List, enable, replace secret, and delete profiles while enforcing runtime rules. |
| `harmony/shared/src/main/ets/profile/LocalRuntimeCoordinator.ets` | Own one event-driven core runtime state and start/stop lifecycle. |
| `harmony/shared/src/main/ets/profile/ProfileApplication.ets` | Expose the small application facade consumed by entry ViewModels. |
| `harmony/shared/Index.ets` | Export the supported shared public surface. |

### Harmony platform adapters

| File | Single responsibility |
| --- | --- |
| `harmony/platform/src/main/ets/rdb/ProfileRowCodec.ets` | Encode/decode typed profile rows and reject corrupt persisted values. |
| `harmony/platform/src/main/ets/rdb/RdbDriver.ets` | Narrow transactional driver seam for repository tests. |
| `harmony/platform/src/main/ets/rdb/HarmonyRdbDriver.ets` | Wrap `@kit.ArkData` relationalStore calls and schema version 1. |
| `harmony/platform/src/main/ets/rdb/RdbProfileRepository.ets` | Implement profile metadata and single active-profile persistence. |
| `harmony/platform/src/main/ets/files/FileDriver.ets` | Narrow file operation seam for deterministic store tests. |
| `harmony/platform/src/main/ets/files/HarmonyFileDriver.ets` | Wrap CoreFileKit file I/O and SHA-256 hashing. |
| `harmony/platform/src/main/ets/files/SandboxProfileContentStore.ets` | Own temporary/current/failed revision layout, compensation, and reconciliation. |
| `harmony/platform/src/main/ets/source/HarmonyFilePicker.ets` | Select one YAML document and copy it immediately to a staging path. |
| `harmony/platform/src/main/ets/source/HttpTransport.ets` | Define one no-auto-redirect response/file transport contract for downloader policy tests. |
| `harmony/platform/src/main/ets/source/SubscriptionDownloader.ets` | Enforce URL/scheme/redirect/timeout/status/empty/size policy over a transport seam. |
| `harmony/platform/src/main/ets/source/NetworkKitHttpTransport.ets` | Perform API 23 bounded HTTP requests and destroy every HttpRequest. |
| `harmony/platform/src/main/ets/source/RequestAgentRedirectTransport.ets` | Provide the API 20–22 redirect-disabled manual fallback. |
| `harmony/platform/src/main/ets/source/HarmonyProfileSourceGateway.ets` | Combine Picker/downloader results into shared staged-source values. |
| `harmony/platform/src/main/ets/secrets/HuksDriver.ets` | Narrow HUKS operation seam for deterministic encryption tests. |
| `harmony/platform/src/main/ets/secrets/HarmonyHuksDriver.ets` | Generate/use one non-exportable AES-256 GCM master key. |
| `harmony/platform/src/main/ets/secrets/HuksSubscriptionSecretStore.ets` | Persist/reconcile versioned encrypted URL envelopes by opaque reference. |
| `harmony/platform/src/main/ets/PlatformFactory.ets` | Construct initialized adapters from a `UIAbilityContext`. |
| `harmony/platform/Index.ets` | Export only the factory and shared-compatible adapter types. |

### Entry presentation and integration

| File | Single responsibility |
| --- | --- |
| `harmony/entry/src/main/ets/bootstrap/ApplicationComposition.ets` | Initialize the production graph and publish loading/ready/error state. |
| `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets` | Retain the Phase 1/2 core and self-test composition only. |
| `harmony/entry/src/main/ets/presentation/PresentationModels.ets` | Immutable Home/Profile/import/detail view states with no secrets. |
| `harmony/entry/src/main/ets/presentation/HomeViewModel.ets` | Observe runtime/current profile and issue start/stop commands. |
| `harmony/entry/src/main/ets/presentation/ProfilesViewModel.ets` | Observe list state and route add/detail actions. |
| `harmony/entry/src/main/ets/presentation/ImportProfileViewModel.ets` | Own local/URL form, per-attempt HTTP confirmation, progress, and results. |
| `harmony/entry/src/main/ets/presentation/ProfileDetailViewModel.ets` | Enable, refresh/replace, copy-safe error, and delete one profile. |
| `harmony/entry/src/main/ets/components/RuntimeStatusCard.ets` | Render runtime state and actual listener addresses. |
| `harmony/entry/src/main/ets/components/ProfileListItem.ets` | Render one profile with independent active and availability badges. |
| `harmony/entry/src/main/ets/components/SafeErrorCard.ets` | Render/copy only pre-redacted structured error detail. |
| `harmony/entry/src/main/ets/pages/Index.ets` | Own the production Navigation shell and initialization state. |
| `harmony/entry/src/main/ets/pages/HomePage.ets` | Render current profile and local proxy start/stop flow. |
| `harmony/entry/src/main/ets/pages/ProfilesPage.ets` | Render profile list and add sheet entry. |
| `harmony/entry/src/main/ets/pages/ProfileDetailPage.ets` | Render profile facts, errors, and safe actions. |
| `harmony/entry/src/main/ets/pages/ImportProfileSheet.ets` | Render file/URL import controls and HTTP confirmation dialog. |
| `harmony/entry/src/test/*.test.ets` | Lock composition and ViewModel behavior with hand-written fakes. |
| `harmony/entry/src/ohosTest/ets/test/*.test.ets` | Exercise production navigation and concrete adapters on Simulator without changing production routing. |
| `harmony/entry/src/main/resources/base/element/{string,color,float}.json` | Own Simplified Chinese copy and light-theme design tokens. |
| `harmony/entry/src/main/resources/dark/element/color.json` | Override colors for system dark mode. |

### Verification

| File | Single responsibility |
| --- | --- |
| `harmony/tests/structure/phase3-layer-boundary.test.mjs` | Lock modules, dependency direction, permissions, exports, and no-secret source patterns. |
| `harmony/tests/structure/phase3-ui-contract.test.mjs` | Lock production/self-test routing, resource-backed UI, semantic IDs, and no VPN claims. |
| `harmony/tests/structure/phase3-proof-schema.test.mjs` | Lock Simulator runner, evidence schema, redaction, and non-physical result semantics. |
| `harmony/tests/bin/run-phase3-simulator-proof.mjs` | Build/run provisional Simulator checks and always preserve physical gate truth. |
| `harmony/tests/fixtures/phase3-simulator-proof.schema.json` | Define `provisional-pass`/`incomplete` Simulator evidence; never `pass`. |
| `harmony/tests/fixtures/phase3-simulator-proof.example.json` | Provide one schema-valid redacted provisional evidence fixture. |
| `harmony/tests/fixtures/phase3-valid.yaml` | Minimal deterministic valid local proxy configuration. |
| `docs/harmony/phase-0-3-verification.md` | Record exact Phase 0–3 commands, outcomes, HAP, and deferred gates. |

## Standard commands

Run from the repository root unless a step says otherwise:

```bash
node --test harmony/tests/structure/*.test.mjs

cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
cd ..
```

When a RED step names one Hypium file, temporarily keep only that suite in the
module's `src/test/List.test.ets`, run the module `test` command, then restore
the cumulative suite list before the GREEN regression run. Do not use skipped
tests as evidence.

## Chunk 1: Shared contracts and transactional domain behavior

### Task 1: Register the platform module and ArkTS test lane

**Files:**
- Modify: `harmony/oh-package.json5`
- Create (generated): `harmony/oh-package-lock.json5`
- Modify: `harmony/build-profile.json5`
- Modify: `harmony/entry/oh-package.json5`
- Modify (generated): `harmony/entry/oh-package-lock.json5`
- Modify: `harmony/tests/structure/phase1-arkts-module-boundary.test.mjs`
- Modify: `harmony/tests/structure/phase1-bridge-contract.test.mjs`
- Create: `harmony/tests/structure/phase3-layer-boundary.test.mjs`
- Create: `harmony/platform/oh-package.json5`
- Create: `harmony/platform/build-profile.json5`
- Create: `harmony/platform/hvigorfile.ts`
- Create: `harmony/platform/src/main/module.json5`
- Create: `harmony/platform/Index.ets`
- Create: `harmony/shared/src/test/List.test.ets`
- Create: `harmony/platform/src/test/List.test.ets`
- Create: `harmony/entry/src/test/List.test.ets`

- [ ] **Step 1: Write the failing module-boundary assertions**

Add a Node test that expects exactly `shared`, `core`, `platform`, and `entry`,
checks `@cmfa/platform -> @cmfa/shared`, checks `entry -> platform/shared/core`,
and scans `shared/src/main/ets` for forbidden `@kit.`, `@ohos.`, ArkUI, RDB,
Picker, HUKS, and Node-API imports. Update the older Phase 1 assertion from
three registered modules to four without weakening its existing checks. Update
the Phase 1 bridge dependency allowlist to include only the new local
`@cmfa/platform` dependency in addition to its existing three entries.

```js
assert.deepEqual(registeredModuleNames, ['core', 'entry', 'platform', 'shared']);
assert.equal(platformPkg.dependencies?.['@cmfa/shared'], 'file:../shared');
assert.equal(entryPkg.dependencies?.['@cmfa/platform'], 'file:../platform');
assert.equal(forbiddenSharedImports.length, 0);
```

- [ ] **Step 2: Run the RED structure test**

Run:

```bash
node --test harmony/tests/structure/phase3-layer-boundary.test.mjs \
  harmony/tests/structure/phase1-arkts-module-boundary.test.mjs \
  harmony/tests/structure/phase1-bridge-contract.test.mjs
```

Expected: FAIL because `platform` is not registered and the package/module
files do not exist.

- [ ] **Step 3: Add the minimal HAR skeleton and official test dependency**

Pin only:

```json
"devDependencies": {
  "@ohos/hypium": "1.0.25"
}
```

Create `@cmfa/platform` as a Stage HAR mirroring the existing `shared` module
shape (`harTasks`, target `default`, phone-compatible module profile), register
it between `shared` and `core`, and add the local file dependency to `entry`.
Create empty cumulative Hypium suite entrypoints so later tasks never invent a
second test layout.

- [ ] **Step 4: Resolve packages and run the GREEN module checks**

Run:

```bash
cd harmony
ohpm install
cd ..
node --test harmony/tests/structure/*.test.mjs
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
cd ..
```

Expected: structure tests PASS; all three Hypium commands report `BUILD
SUCCESSFUL` with zero failed cases.

`ohpm` is the DevEco toolchain prerequisite documented by `harmony/README.md`;
there is no repository-local ohpm wrapper. `ohpm install` creates the root lock
file and must not replace the local `file:` module dependencies with registry
packages.

- [ ] **Step 5: Commit the module/test foundation**

```bash
git add harmony/oh-package.json5 harmony/oh-package-lock.json5 \
  harmony/build-profile.json5 harmony/entry/oh-package.json5 \
  harmony/entry/oh-package-lock.json5 \
  harmony/platform harmony/shared/src/test harmony/entry/src/test \
  harmony/tests/structure/phase1-arkts-module-boundary.test.mjs \
  harmony/tests/structure/phase1-bridge-contract.test.mjs \
  harmony/tests/structure/phase3-layer-boundary.test.mjs
git commit -m "Prepare a testable Harmony platform boundary" \
  -m "Constraint: Keep shared free of HarmonyOS APIs and add only Hypium as a dev dependency

Confidence: high
Scope-risk: narrow
Tested: Phase 1 and Phase 3 module-boundary tests
Tested: empty shared/platform/entry Hypium lanes"
```

### Task 2: Define profile models, structured errors, and redaction

**Files:**
- Create: `harmony/shared/src/main/ets/profile/ProfileModels.ets`
- Create: `harmony/shared/src/main/ets/profile/AppErrors.ets`
- Create: `harmony/shared/src/main/ets/profile/SecretRedactor.ets`
- Create: `harmony/shared/src/main/ets/profile/CoreErrorMapper.ets`
- Modify: `harmony/shared/Index.ets`
- Create: `harmony/shared/src/test/ProfileDomain.test.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing model/error tests**

Cover all three availability values, nullable current/failed revisions,
1–80-character trimmed names, duplicate-name acceptance, active eligibility,
and the exact seven error stages. Add table-driven redaction tests for URL user
info, path/query/fragment tokens, home/repository paths, YAML credential keys,
and raw Core event messages.

```ts
it('redactsSubscriptionUrlToSchemeAndHost', 0, () => {
  const safe: string = redactUrl('https://user:pass@example.com/token?q=secret#x');
  expect(safe).assertEqual('https://example.com');
});

it('mapsStartCoreErrorWithoutRawDetail', 0, () => {
  const error: AppError = mapCoreError('startLocal', unsafeCoreError);
  expect(error.stage).assertEqual('RUNTIME_START');
  expect(error.technicalDetail.includes('token=')).assertFalse();
});
```

- [ ] **Step 2: Run the RED shared test**

Run the shared Hypium command from Standard commands.

Expected: FAIL with unresolved profile/error/redaction imports.

- [ ] **Step 3: Implement the minimal typed domain surface**

Define:

```ts
export type ProfileAvailability = 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID';
export type ProfileSourceKind = 'LOCAL_FILE' | 'REMOTE_URL';
export type AppErrorStage = 'IMPORT' | 'DOWNLOAD' | 'VALIDATION' |
  'PERSISTENCE' | 'CORE_LOAD' | 'RUNTIME_START' | 'RUNTIME_STOP';
```

Use ISO-8601 strings in durable models, keep revision paths sandbox-relative,
and make the mapper allowlist only `code`, `retryable`, `context.operation`,
and already-redacted detail. Never display `CoreEvent.message` directly.

- [ ] **Step 4: Run focused and regression tests**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
cd ..
node --test harmony/tests/structure/phase3-layer-boundary.test.mjs
```

Expected: all domain/error/redaction cases PASS and shared still has no platform
imports.

- [ ] **Step 5: Commit the domain vocabulary**

```bash
git add harmony/shared
git commit -m "Make profile state safe to persist and display" \
  -m "Constraint: Errors and profile metadata cannot contain subscription or configuration secrets

Confidence: high
Scope-risk: narrow
Tested: shared profile, error mapping, and redaction Hypium suites"
```

### Task 3: Implement recoverable import and refresh transactions

**Files:**
- Create: `harmony/shared/src/main/ets/profile/ProfilePorts.ets`
- Create: `harmony/shared/src/main/ets/profile/SerialCommandQueue.ets`
- Create: `harmony/shared/src/main/ets/profile/ProfileCommitService.ets`
- Create: `harmony/shared/src/main/ets/profile/ImportProfileUseCase.ets`
- Create: `harmony/shared/src/main/ets/profile/RefreshProfileUseCase.ets`
- Modify: `harmony/shared/Index.ets`
- Create: `harmony/shared/src/test/fakes/ProfileFakes.ets`
- Create: `harmony/shared/src/test/ProfileImportUseCases.test.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing transactional use-case tests**

Hand-written fakes must record call order and injected failures. Cover:

- valid local import: acquire → validate → retain → repository commit;
- invalid local/URL import retained as `INVALID`;
- Picker cancel creates no profile/error;
- post-Picker copy failure creates one retryable invalid local profile with no
  candidate revision and `本地配置` fallback metadata;
- URL encryption failure persists neither profile nor plaintext;
- valid refresh removes the prior revision only after repository commit;
- failed validation retains the prior valid revision and records a failed
  candidate;
- repository failure removes the new unreferenced revision and leaves the old
  row/file referenced;
- command queue never overlaps two mutations.

Assert observable ordering rather than private methods:

```ts
expect(fake.calls.join('>')).assertEqual(
  'acquire>validate>retainRevision>saveProfile>removeSuperseded'
);
```

- [ ] **Step 2: Run the RED shared test**

Run the shared Hypium command.

Expected: FAIL because ports and import/refresh services do not exist.

- [ ] **Step 3: Define narrow ports and the commit algorithm**

The shared ports expose typed operations only:

```ts
export interface ProfileRepository {
  list(): Promise<Profile[]>;
  get(id: string): Promise<Profile | undefined>;
  save(profile: Profile): Promise<void>;
  deleteAndClearActive(id: string): Promise<void>;
  getActiveId(): Promise<string | undefined>;
  setActiveId(id: string | undefined): Promise<void>;
}

export interface ProfileContentStore {
  retain(profileId: string, staged: StagedSource, kind: RevisionKind): Promise<ProfileRevision>;
  discard(staged: StagedSource): Promise<void>;
  removeRevision(revision: ProfileRevision): Promise<void>;
  removeProfile(profileId: string): Promise<void>;
  reconcile(referenced: ProfileRevision[]): Promise<void>;
  resolveCorePath(revision: ProfileRevision): string;
}
```

Also define `ProfileSourceGateway`, `SubscriptionSecretStore`, `Clock`, and
`IdGenerator`. Keep platform contexts and ArkUI types out of every signature.
`ProfileCommitService` owns compensation and never deletes a superseded file
before repository success. `deleteAndClearActive` is one repository
transaction; file/secret cleanup occurs only after it succeeds, and a later
startup `reconcile` removes content left by an interrupted cleanup. Startup
passes every current and failed revision returned by `list()` to `reconcile`.

- [ ] **Step 4: Implement initial import and manual refresh minimally**

Require `allowPlainHttp` in URL acquisition commands. Treat HTTP confirmation
cancellation as no command/no mutation. On decrypt failures, set the exact
`SOURCE_SECRET_*` non-retryable `PERSISTENCE` errors without creating a
candidate. A valid profile becomes `UPDATE_FAILED_USING_VALID`; an invalid one
stays `INVALID`.

- [ ] **Step 5: Run focused and cumulative tests**

Run the shared Hypium command, then:

```bash
node --test harmony/tests/structure/phase3-layer-boundary.test.mjs
git diff --check
```

Expected: all import/refresh order, failure, compensation, and redaction cases
PASS; no whitespace errors.

- [ ] **Step 6: Commit the transactional profile flow**

```bash
git add harmony/shared
git commit -m "Preserve valid profiles across failed imports" \
  -m "Constraint: Filesystem and RDB cannot share one transaction
Rejected: Overwrite the current revision before validation | a failed update would destroy the usable profile
Confidence: high
Scope-risk: moderate
Tested: shared import, refresh, compensation, and serialization suites"
```

### Task 4: Add enable/delete rules and the canonical runtime coordinator

**Files:**
- Create: `harmony/shared/src/main/ets/profile/ManageProfileUseCases.ets`
- Create: `harmony/shared/src/main/ets/profile/LocalRuntimeCoordinator.ets`
- Create: `harmony/shared/src/main/ets/profile/ProfileApplication.ets`
- Modify: `harmony/shared/Index.ets`
- Create: `harmony/shared/src/test/ProfileManagement.test.ets`
- Create: `harmony/shared/src/test/LocalRuntimeCoordinator.test.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing profile-management tests**

Cover enable validation/load before `activeProfileId` persistence, failed load
preserving the previous active ID, idempotent re-enable, rejection of invalid
profiles, running-state switch/delete/refresh rejection, deletion cleanup, and
corrupt-secret replacement.

- [ ] **Step 2: Write failing runtime-state tests**

Cover:

- cold start reconciles the core snapshot to `STOPPED` but preserves active ID;
- start always resolves/revalidates/loads the active revision before
  `startLocal({ mixedPort: 7890 })`;
- `RuntimeSnapshot` addresses are the only displayed listener source;
- duplicate start/stop taps share or reject the in-flight command rather than
  invoke core twice;
- runtime events and snapshots override stale command results;
- unexpected core error/stop moves to safe `ERROR`/`STOPPED` state;
- one subscription is installed and removed exactly once.

- [ ] **Step 3: Run the RED shared test**

Run the shared Hypium command.

Expected: FAIL with missing management and runtime coordinator symbols.

- [ ] **Step 4: Implement the minimal facade and coordinator**

`LocalRuntimeCoordinator` owns the state graph:

```text
STOPPED -> STARTING -> RUNNING -> STOPPING -> STOPPED
    \          |          |          /
     +---------+----------+---------+----> ERROR
```

`ProfileApplication` exposes observation plus `importLocal`, `importUrl`,
`refresh`, `replaceSubscriptionUrl`, `enable`, `delete`, `startLocal`, and
`stopLocal`; it does not expose repositories or raw core events to `entry`.

- [ ] **Step 5: Run Chunk 1 verification**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
cd ..
node --test harmony/tests/structure/phase1-arkts-module-boundary.test.mjs \
  harmony/tests/structure/phase1-bridge-contract.test.mjs \
  harmony/tests/structure/phase3-layer-boundary.test.mjs
git diff --check
```

Expected: all shared tests and all three listed structure suites PASS.

- [ ] **Step 6: Commit the single-runtime policy**

```bash
git add harmony/shared
git commit -m "Keep profile selection and local runtime truthful" \
  -m "Constraint: Only one stopped-profile selection and one mihomo runtime may exist
Rejected: Switch profiles while running | safe rollback and implicit traffic interruption are outside this milestone
Confidence: high
Scope-risk: moderate
Tested: shared management and runtime coordinator Hypium suites"
```

## Chunk 2: Harmony persistence, files, secrets, and source acquisition

### Task 5: Implement the versioned RDB profile repository

**Files:**
- Create: `harmony/platform/src/main/ets/rdb/ProfileRowCodec.ets`
- Create: `harmony/platform/src/main/ets/rdb/RdbDriver.ets`
- Create: `harmony/platform/src/main/ets/rdb/HarmonyRdbDriver.ets`
- Create: `harmony/platform/src/main/ets/rdb/RdbProfileRepository.ets`
- Modify: `harmony/platform/Index.ets`
- Create: `harmony/platform/src/test/fakes/PlatformFakes.ets`
- Create: `harmony/platform/src/test/ProfileRowCodec.test.ets`
- Create: `harmony/platform/src/test/RdbProfileRepository.test.ets`
- Modify: `harmony/platform/src/test/List.test.ets`

- [ ] **Step 1: Write failing row-codec tests**

Round-trip every profile field, `currentRevision`, `failedCandidate`, the
three availability values, error metadata, and nullable timestamps. Reject
unknown schema versions, invalid enums, absolute revision paths, invalid name
lengths, and missing required fields. Assert that encoded rows contain no
`http://`, `https://`, YAML body, or plaintext secret.

- [ ] **Step 2: Write failing repository transaction tests**

Use a recording `RdbDriver` fake. Cover create/list/get/save, deterministic
ordering by `updatedAt DESC, id ASC`, one active ID, rejecting invalid/missing
active profiles, rejecting an `app_state` row whose active ID cannot resolve to
a valid current profile, clearing a stale active ID during initialization, and
`deleteAndClearActive` performing row deletion plus active-ID clearing inside
one begin/commit boundary. Inject failure after each statement and assert
rollback with the original rows intact.

```ts
expect(driver.calls.join('>')).assertEqual(
  'begin>clearActiveIfMatching>deleteProfile>commit'
);
```

- [ ] **Step 3: Run the RED platform test**

Run the platform Hypium command from Standard commands.

Expected: FAIL with missing RDB codec/repository imports.

- [ ] **Step 4: Implement schema version 1 and the narrow driver**

Use `@kit.ArkData` `relationalStore`. Create:

```sql
CREATE TABLE IF NOT EXISTS profiles (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  source_display TEXT NOT NULL,
  source_secret_ref TEXT,
  current_revision_json TEXT,
  failed_candidate_json TEXT,
  availability TEXT NOT NULL,
  last_error_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_success_at TEXT
)
```

and one `app_state` row with primary key `1` and nullable
`active_profile_id`. Set RDB `securityLevel` to the installed SDK's supported
application-private level and database version to `1`. Always close
`ResultSet` in `finally`. Keep SQL and row conversion inside `platform`.

- [ ] **Step 5: Implement repository invariants and typed failures**

Decode every row before returning it. Convert RDB/schema/corruption errors to a
platform failure carrying a stable `PERSISTENCE` code and sanitized detail;
never include SQL values or a row JSON blob. `setActiveId` rereads and verifies
a valid current revision in the same transaction. `deleteAndClearActive`
clears and deletes atomically.

- [ ] **Step 6: Run focused and regression tests**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
cd ..
node --test harmony/tests/structure/phase3-layer-boundary.test.mjs
git diff --check
```

Expected: codec and repository tests PASS, including injected rollback cases.

- [ ] **Step 7: Commit RDB persistence**

```bash
git add harmony/platform
git commit -m "Persist one valid active Harmony profile consistently" \
  -m "Constraint: Profile deletion and active-ID clearing must share one RDB transaction
Confidence: high
Scope-risk: moderate
Tested: profile row codec and RDB repository Hypium suites"
```

### Task 6: Add sandbox revision storage and immediate Picker copying

**Files:**
- Create: `harmony/platform/src/main/ets/files/FileDriver.ets`
- Create: `harmony/platform/src/main/ets/files/HarmonyFileDriver.ets`
- Create: `harmony/platform/src/main/ets/files/SandboxProfileContentStore.ets`
- Create: `harmony/platform/src/main/ets/source/HarmonyFilePicker.ets`
- Modify: `harmony/platform/Index.ets`
- Modify: `harmony/platform/src/test/fakes/PlatformFakes.ets`
- Create: `harmony/platform/src/test/SandboxProfileContentStore.test.ets`
- Create: `harmony/platform/src/test/HarmonyFilePicker.test.ets`
- Modify: `harmony/platform/src/test/List.test.ets`

- [ ] **Step 1: Write failing content-store tests**

Use an in-memory file driver to cover:

- unique `tmp/`, `profiles/<id>/valid/`, and `profiles/<id>/failed/` paths;
- a 16 MiB file accepted and a 16 MiB + 1 byte file rejected;
- SHA-256/size recorded before immutable retain;
- retain uses rename inside the sandbox and never overwrites an existing
  revision;
- discard is idempotent;
- `removeProfile` cannot escape the profile root;
- startup `reconcile` keeps all referenced current/failed paths and deletes
  stale temp/unreferenced revision files;
- partial cleanup failure is reported safely and succeeds on the next
  reconciliation.

- [ ] **Step 2: Write failing Picker tests**

Inject picker/open/read/write operations. Cover cancellation (`[]`), one YAML
selection, multiple URIs rejected, filename extraction, missing filename
falling back to `本地配置`, close-on-success/failure, streaming size enforcement,
and a selected-file copy failure that retains safe source metadata but never
persists the external URI.

- [ ] **Step 3: Run the RED platform test**

Run the platform Hypium command.

Expected: FAIL because file-store and Picker adapters do not exist.

- [ ] **Step 4: Implement the CoreFileKit driver and sandbox store**

Use `fileIo`, `hash`, and application `filesDir`; do not use public storage or
broad storage permission. Normalize every relative path, reject `..`, URI
schemes, and absolute inputs at the store boundary, and close file descriptors
in `finally`. Use `hash.hash(path, 'sha256')` only after the streamed size check
passes.

- [ ] **Step 5: Implement the system document Picker adapter**

Use `picker.DocumentViewPicker(UIAbilityContext)` with:

```ts
const options = new picker.DocumentSelectOptions();
options.maxSelectNumber = 1;
options.fileSuffixFilters = ['Clash YAML|.yaml,.yml'];
```

Copy the returned URI immediately into a staging path and discard the URI.
Map user cancellation to `undefined`, not an error Profile. Map any later
read/copy failure to the selected-source failure shape required by Task 3.

- [ ] **Step 6: Run focused and regression tests**

Run platform Hypium, all structure tests, and `git diff --check`.

Expected: all file/Picker tests PASS; no new permission is present in
`entry/src/main/module.json5`.

- [ ] **Step 7: Commit sandbox import storage**

```bash
git add harmony/platform
git commit -m "Own imported configurations inside the app sandbox" \
  -m "Constraint: Picker grants are transient and the core accepts sandbox paths only
Rejected: Retain external document URIs | grants are not a durable core contract
Confidence: high
Scope-risk: moderate
Tested: sandbox revision and Picker adapter Hypium suites"
```

### Task 7: Protect subscription URLs with a HUKS-backed secret store

**Files:**
- Create: `harmony/platform/src/main/ets/secrets/HuksDriver.ets`
- Create: `harmony/platform/src/main/ets/secrets/HarmonyHuksDriver.ets`
- Create: `harmony/platform/src/main/ets/secrets/HuksSubscriptionSecretStore.ets`
- Modify: `harmony/platform/Index.ets`
- Modify: `harmony/platform/src/test/fakes/PlatformFakes.ets`
- Create: `harmony/platform/src/test/HuksSubscriptionSecretStore.test.ets`
- Modify: `harmony/platform/src/test/List.test.ets`

- [ ] **Step 1: Write failing secret-store tests**

Use a deterministic authenticated-encryption fake. Cover first-use key
creation, existing-key reuse, random 96-bit nonce per encryption, UTF-8
round-trip, versioned envelope fields, tampered ciphertext/tag rejection,
missing envelope, unsupported version, idempotent delete, and crash-safe
temporary-envelope replacement. Add reconciliation cases that preserve exactly
the opaque IDs referenced by repository profiles while deleting stale `.tmp`
and unreferenced envelope files after an interrupted profile delete; never
delete the shared HUKS master key. A corrupt referenced envelope remains in
place so decrypt produces the specified replacement-source error, while a
corrupt unreferenced envelope is safe to remove. Scan fake driver calls and
serialized envelope text to prove plaintext never reaches the
repository-facing reference.

- [ ] **Step 2: Run the RED platform test**

Run the platform Hypium command.

Expected: FAIL with missing HUKS driver/store symbols.

- [ ] **Step 3: Implement the non-exportable AES-GCM driver**

Use `@kit.UniversalKeystoreKit` `huks` with one fixed application key alias,
AES-256, GCM, no padding, and encrypt/decrypt purposes. Generate the key only
when `isKeyItemExist` is false. Use `initSession`, `updateSession`, and
`finishSession` with a fresh 12-byte nonce; abort/close failed sessions.
Neither the key nor URL plaintext may be returned in an error.

- [ ] **Step 4: Implement opaque encrypted envelope storage**

Store `{ version, nonce, ciphertext, tag, keyAliasVersion }` as an
application-private JSON envelope under `profile-secrets/<opaque-id>.json`.
Return only the opaque ID to RDB. Write a unique temporary envelope, rename it
after encryption succeeds, and delete it when the profile is deleted. Map
missing/corrupt/version errors to the exact `SOURCE_SECRET_*` codes. Expose an
implementation-only `reconcile(referencedSecretIds: string[])` method to the
platform factory; enumerate only the `profile-secrets` directory, preserve
referenced IDs, and remove temp/unreferenced envelopes idempotently.

- [ ] **Step 5: Run focused and security regressions**

Run platform Hypium, then:

```bash
rg -n "https?://.*(token|secret|password)|subscription.*url" \
  harmony/platform harmony/shared --glob '*.ets'
node --test harmony/tests/structure/phase3-layer-boundary.test.mjs
git diff --check
```

Expected: tests PASS; the search returns only deliberate redaction/test
fixtures, never a production credential literal or plaintext persistence.

- [ ] **Step 6: Commit protected subscription sources**

```bash
git add harmony/platform
git commit -m "Keep subscription credentials out of profile storage" \
  -m "Constraint: HUKS keys must remain non-exportable and RDB stores only opaque secret references
Confidence: high
Scope-risk: moderate
Tested: secret envelope, tamper, missing-key, and delete Hypium suites"
```

### Task 8: Implement bounded HTTP/HTTPS subscription acquisition

**Files:**
- Create: `harmony/platform/src/main/ets/source/HttpTransport.ets`
- Create: `harmony/platform/src/main/ets/source/SubscriptionDownloader.ets`
- Create: `harmony/platform/src/main/ets/source/NetworkKitHttpTransport.ets`
- Create: `harmony/platform/src/main/ets/source/RequestAgentRedirectTransport.ets`
- Modify: `harmony/platform/src/test/fakes/PlatformFakes.ets`
- Create: `harmony/platform/src/test/SubscriptionDownloader.test.ets`
- Modify: `harmony/platform/src/test/List.test.ets`
- Modify: `harmony/entry/src/main/module.json5`
- Modify: `harmony/tests/structure/api20-sdk-contract.test.mjs`
- Modify: `harmony/tests/structure/phase3-layer-boundary.test.mjs`

- [ ] **Step 1: Write failing download-policy tests**

The fake `HttpTransport` returns one response at a time with automatic
redirects disabled. Cover HTTPS success, HTTP rejected without
`allowPlainHttp`, confirmed HTTP success, cancellation issuing no transport
call, 204/empty body, non-2xx status, timeout, TLS error, exactly 16 MiB,
oversize, five allowed redirects, sixth redirect rejection, missing/relative
Location, redirect loop, and redirect to any non-HTTP(S) scheme.

```ts
expect(transport.requestedUrls).assertEqual([
  'https://a.example/start',
  'https://b.example/next'
]);
expect(result.sha256).assertEqual(expectedDigest);
```

- [ ] **Step 2: Add the failing API 20 fallback contract**

Extend the Node structure tests to require two explicit no-auto-redirect
transports:

- API 23+: NetworkKit with `maxRedirects: 0`, `maxLimit: 16 * 1024 * 1024`,
  `connectTimeout/readTimeout: 30000`, `usingCache: false`, and `delete()` in
  `finally`.
- API 20–22: `@kit.BasicServicesKit` request agent with `redirect: false`, a
  30-second cancellation timer, progress size cancellation, and task cleanup.

Require runtime selection by SDK API version. This is the compatible
implementation demanded by the existing API 20 rule, not a capability claim
based only on API 23 declarations.

Also make the structure test require exactly one new network permission entry:

```json
"requestPermissions": [
  { "name": "ohos.permission.INTERNET" }
]
```

Do not add storage, background, VPN, notification, or account permissions.

- [ ] **Step 3: Run the RED tests**

Run platform Hypium plus:

```bash
node --test harmony/tests/structure/api20-sdk-contract.test.mjs \
  harmony/tests/structure/phase3-layer-boundary.test.mjs
```

Expected: FAIL because downloader/transports and fallback selection are absent.

- [ ] **Step 4: Implement policy above the no-redirect transport**

Parse and normalize each URL, keep credentials only in the local call frame,
redact all failures, and manually follow 301/302/303/307/308 up to five hops.
Resolve relative `Location` against the current URL and recheck scheme before
the next request. Discard redirect bodies/staging files immediately. Require a
non-empty 2xx body and return one staged source with digest/size.

- [ ] **Step 5: Implement both installed-SDK transport adapters**

Use the exact API 23 declarations in the installed SDK for NetworkKit. On API
20–22, use foreground Request FileTransferAgent tasks with redirects disabled;
capture response headers/status, enforce the timer and progress byte cap, and
remove task/output on every non-success path. The transport contract never
returns an external URL, request header, or raw BusinessError as public detail.

- [ ] **Step 6: Run focused, compatibility, and leak tests**

Run platform Hypium, all structure tests, the credential `rg` check from Task
7, and `git diff --check`.

Expected: download matrix PASS; API 20 compatibility test proves the fallback;
the manifest exposes only the required INTERNET permission; no secret appears
in output or production source literals.

- [ ] **Step 7: Commit bounded subscription downloads**

```bash
git add harmony/platform harmony/entry/src/main/module.json5 harmony/tests/structure
git commit -m "Bound subscription downloads across Harmony 6 APIs" \
  -m "Constraint: API 20 lacks NetworkKit maxRedirects, so redirects must stay disabled below the shared policy
Rejected: Trust platform automatic redirects | every hop must be scheme-checked and limited to five
Confidence: medium
Scope-risk: moderate
Tested: downloader policy Hypium suite and API 20/23 structure contracts
Not-tested: live TLS/network behavior until Simulator instrumentation"
```

### Task 9: Compose initialized platform adapters behind one factory

**Files:**
- Create: `harmony/platform/src/main/ets/source/HarmonyProfileSourceGateway.ets`
- Create: `harmony/platform/src/main/ets/PlatformFactory.ets`
- Modify: `harmony/platform/Index.ets`
- Create: `harmony/platform/src/test/PlatformFactory.test.ets`
- Modify: `harmony/platform/src/test/List.test.ets`
- Modify: `harmony/tests/structure/phase3-layer-boundary.test.mjs`

- [ ] **Step 1: Write failing factory/gateway tests**

Inject driver factories and cover initialization order: paths → RDB/schema →
repository list → referenced-revision reconciliation → referenced-secret
reconciliation → secret key readiness → ready graph. Seed an unreferenced
encrypted envelope and assert that factory initialization deletes it while
preserving every `sourceSecretRef` returned by the repository. Cover one
initialization call under concurrent consumers,
retriable safe failure after cleanup, local staging, URL transport selection,
and no exposure of concrete drivers outside the platform graph.

- [ ] **Step 2: Run the RED platform test**

Run the platform Hypium command.

Expected: FAIL because gateway/factory exports do not exist.

- [ ] **Step 3: Implement the minimal platform graph**

Return only shared port implementations plus an async `close()` for RDB/network
resources. Construct clock/UUID providers internally using system time and
`@kit.ArkTS` util. Run content and secret orphan reconciliation before marking
the graph ready: derive referenced revisions and non-null secret IDs from the
single repository snapshot, pass them to their concrete platform reconcilers,
and fail closed on reconciliation error. The source gateway delegates
destination ownership to the content store and emits only shared
`StagedSource` values.

- [ ] **Step 4: Run Chunk 2 verification**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
cd ..
node --test harmony/tests/structure/*.test.mjs
git diff --check
```

Expected: shared/platform Hypium suites and every structure regression PASS.

- [ ] **Step 5: Commit the platform composition boundary**

```bash
git add harmony/platform harmony/tests/structure
git commit -m "Expose one initialized Harmony platform graph" \
  -m "Constraint: Entry consumes shared ports and cannot own RDB, file, network, or HUKS details
Confidence: high
Scope-risk: narrow
Tested: platform factory/gateway Hypium suite and full structure suite"
```

## Chunk 3: Production composition, ViewModels, and ArkUI

### Task 10: Compose the production graph and preserve the self-test route

**Files:**
- Modify: `harmony/entry/oh-package.json5`
- Modify (generated): `harmony/entry/oh-package-lock.json5`
- Create: `harmony/entry/src/main/ets/bootstrap/ApplicationComposition.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Modify: `harmony/entry/src/main/ets/entryability/EntryAbility.ets`
- Create: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Create: `harmony/entry/src/test/List.test.ets`
- Create: `harmony/tests/structure/phase3-ui-contract.test.mjs`
- Modify: `harmony/tests/structure/phase0-layout.test.mjs`
- Modify: `harmony/tests/structure/phase1-bridge-contract.test.mjs`
- Modify: `harmony/tests/structure/phase1-proof-contract.test.mjs`

- [ ] **Step 1: Write failing composition and routing tests**

Use injected platform/core factories to cover one concurrent initialization,
`LOADING → READY`, safe `LOADING → ERROR`, retry after fully closing a failed
graph, one application-scope runtime subscription, and idempotent teardown.
The structure tests must prove:

- an absent or false `cmfa.phase1.selfTest` loads `pages/Index`;
- only a true self-test flag loads `pages/CoreDebugPage`;
- the production path initializes `ApplicationComposition` once and the
  self-test path never initializes RDB, HUKS, Picker, or NetworkKit;
- `onDestroy` closes the production graph, while `CoreDebugPage` and all
  existing Phase 1/2 launch keys remain intact;
- `entry` depends on `@cmfa/platform`, and no concrete platform adapter leaks
  through the composition public surface.
- the Phase 0 layout and Phase 1 proof contracts no longer parse one literal
  default route; they assert `pages/Index` for production and
  `pages/CoreDebugPage` for a self-test Want.

- [ ] **Step 2: Run the RED tests**

Run the entry Hypium command plus:

```bash
node --test harmony/tests/structure/phase0-layout.test.mjs \
  harmony/tests/structure/phase1-bridge-contract.test.mjs \
  harmony/tests/structure/phase1-proof-contract.test.mjs \
  harmony/tests/structure/phase3-ui-contract.test.mjs
```

Expected: FAIL because the production composition and conditional route do
not exist and `EntryAbility` still always loads the debug page.

- [ ] **Step 3: Add the platform dependency and minimal composition state**

Pin `@cmfa/platform` to `file:../platform`. Expose only this lifecycle:

```ts
export type ApplicationCompositionState =
  | { status: 'LOADING' }
  | { status: 'READY'; application: ProfileApplication }
  | { status: 'ERROR'; error: AppError };

export interface ApplicationComposition {
  initialize(): Promise<void>;
  state(): ApplicationCompositionState;
  subscribe(listener: (state: ApplicationCompositionState) => void): number;
  unsubscribe(id: number): void;
  close(): Promise<void>;
}
```

Create the platform graph from the `UIAbilityContext`, inject the existing
real `CoreService`, initialize storage reconciliation and the runtime
coordinator before publishing `READY`, and retain only one initialization
Promise. On failure, close every adapter already created, publish a redacted
`PERSISTENCE` error, and allow a later explicit retry. Never log the graph,
profile data, a URL, or a raw exception.

- [ ] **Step 4: Route by the captured launch context**

Store the current `WindowStage`, apply Want parameters before choosing the
page, and use one `loadTargetPage()` method for both initial launch and
`onNewWant`. A production-to-self-test or self-test-to-production new Want
must close the previous production composition before loading the other page.
Keep all Phase 1/2 parameter parsing in `CoreComposition`; do not copy it into
the product composition.

- [ ] **Step 5: Run focused and regression tests**

Run entry Hypium and the four structure tests from Step 2.

Expected: composition lifecycle cases PASS, production launches `Index`, and
the complete Phase 1/2 debug route contract still passes.

- [ ] **Step 6: Commit the two isolated launch paths**

```bash
git add harmony/entry harmony/tests/structure
git commit -m "Keep production startup separate from device self-tests" \
  -m "Constraint: Phase 1/2 proof routing must remain callable without exposing debug UI on normal launch
Rejected: Initialize the product graph before every launch | self-tests must not mutate profile storage or HUKS state
Confidence: high
Scope-risk: moderate
Tested: entry composition Hypium suite and production/self-test route contracts"
```

### Task 11: Model home and profile-list presentation state

**Files:**
- Create: `harmony/entry/src/main/ets/presentation/PresentationModels.ets`
- Create: `harmony/entry/src/main/ets/presentation/HomeViewModel.ets`
- Create: `harmony/entry/src/main/ets/presentation/ProfilesViewModel.ets`
- Create: `harmony/entry/src/test/fakes/PresentationFakes.ets`
- Create: `harmony/entry/src/test/HomeViewModel.test.ets`
- Create: `harmony/entry/src/test/ProfilesViewModel.test.ets`
- Modify: `harmony/entry/src/test/List.test.ets`

- [ ] **Step 1: Write failing presentation-state tests**

Use one fake `ProfileApplication` with synchronous observation snapshots and
recorded commands. Cover empty/restoring, valid active, invalid,
update-failed, stopped, starting, running, stopping, and error states. Prove
that actual listener addresses come only from the runtime snapshot, duplicate
primary-action taps issue one command, list rows keep active and availability
badges independent, and every subscription is removed on `dispose()`.

Also assert that public state contains no repository/content/secret-store
object, external file URI, raw core event, full URL, YAML text, or unrestricted
exception detail.

- [ ] **Step 2: Run the RED entry tests**

Run the entry Hypium command.

Expected: FAIL because presentation models and ViewModels are absent.

- [ ] **Step 3: Implement immutable semantic view states**

Keep resource lookup in ArkUI, not in shared. The presentation contract carries
semantic values plus already-safe dynamic text:

```ts
export interface HomeViewState {
  initialization: 'LOADING' | 'READY' | 'ERROR';
  activeProfile?: ProfileSummaryState;
  runtime: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
  primaryAction: 'DISABLED' | 'START' | 'STOP' | 'BUSY';
  httpAddress?: string;
  socksAddress?: string;
  error?: SafeErrorState;
}

export interface ProfileRowState {
  id: string;
  name: string;
  sourceDisplay: string;
  availability: ProfileAvailability;
  active: boolean;
  updatedAt: string;
  actionsLockedByRuntime: boolean;
}
```

Use copy-on-write arrays/objects so each notification is a new immutable
snapshot. `HomeViewModel` owns the primary start/stop command; it disables the
action while either the facade or local command is pending. `ProfilesViewModel`
maps sorted application snapshots and emits navigation intents containing only
profile IDs or the add-sheet destination.

- [ ] **Step 4: Run focused and leak tests**

Run entry Hypium, `phase3-layer-boundary.test.mjs`, and:

```bash
rg -n "pickerUri|sourceSecretRef|configurationBody|CoreEvent" \
  harmony/entry/src/main/ets/presentation
```

Expected: ViewModel suites PASS; the final `rg` prints no matches.

- [ ] **Step 5: Commit the presentation boundary**

```bash
git add harmony/entry/src/main/ets/presentation harmony/entry/src/test
git commit -m "Make local proxy state renderable without leaking adapters" \
  -m "Constraint: Pages consume immutable user-safe state and cannot observe raw core or storage objects
Confidence: high
Scope-risk: narrow
Tested: home and profile-list ViewModel Hypium suites"
```

### Task 12: Model import and profile-detail interactions

**Files:**
- Create: `harmony/entry/src/main/ets/presentation/ImportProfileViewModel.ets`
- Create: `harmony/entry/src/main/ets/presentation/ProfileDetailViewModel.ets`
- Create: `harmony/entry/src/test/ImportProfileViewModel.test.ets`
- Create: `harmony/entry/src/test/ProfileDetailViewModel.test.ets`
- Modify: `harmony/entry/src/test/fakes/PresentationFakes.ets`
- Modify: `harmony/entry/src/test/List.test.ets`

- [ ] **Step 1: Write failing import tests**

Cover trimmed 1–80-character names, invalid URL/scheme, HTTPS submission,
Picker cancellation, post-Picker invalid-profile navigation, duplicate-submit
blocking, and success/failure navigation to the retained profile detail.

For every initial import and refresh attempt to `http://`, assert this exact
sequence: create a confirmation state containing only a redacted host → issue
no network command before confirmation → clear confirmation on cancel with no
error/mutation → after confirmation call the facade once with
`allowPlainHttp: true` → immediately discard consent. A second attempt must
ask again. The transient URL input is cleared after submit/cancel and is never
copied into diagnostics, profile rows, navigation intents, or error state.

- [ ] **Step 2: Write failing detail-action tests**

Cover unavailable enable action for invalid profiles; enable/update/delete
disabled while running; load-before-active behavior surfaced from the facade;
local refresh reopening Picker; URL refresh; corrupt-secret replacement;
delete confirmation with no pre-confirmation mutation; and copying only the
already-redacted technical detail. A successful delete navigates back exactly
once.

- [ ] **Step 3: Run the RED entry tests**

Run the entry Hypium command.

Expected: FAIL because import/detail ViewModels do not exist.

- [ ] **Step 4: Implement the two command-state machines**

Use explicit `IDLE | CONFIRMING_HTTP | SUBMITTING | COMPLETED | ERROR` import
states and one command token to ignore stale completions. The detail ViewModel
derives action availability from profile validity plus canonical runtime state;
it does not duplicate domain mutation rules. Store only a profile ID between
navigation events and refetch the profile after every command.

Map HTTP cancellation to `IDLE`, Picker cancellation to `IDLE`, and domain
failures to the retained profile/error returned by `ProfileApplication`.
Never persist or emit the plaintext URL form value.

- [ ] **Step 5: Run focused and cumulative entry tests**

Run entry Hypium and all Phase 3 structure tests.

Expected: every confirmation, duplicate-command, action-lock, navigation, and
redaction case PASS.

- [ ] **Step 6: Commit the guarded interaction flows**

```bash
git add harmony/entry/src/main/ets/presentation harmony/entry/src/test
git commit -m "Require explicit safe actions for profile mutations" \
  -m "Constraint: Plain HTTP consent is per request and runtime mutations cannot overlap
Rejected: Persist HTTP approval with the profile | later refreshes require a fresh warning
Confidence: high
Scope-risk: moderate
Tested: import and profile-detail ViewModel Hypium suites"
```

### Task 13: Build the resource-backed HarmonyOS-native interface

**Files:**
- Modify: `harmony/entry/src/main/resources/base/profile/main_pages.json`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Modify: `harmony/entry/src/main/resources/base/element/color.json`
- Modify: `harmony/entry/src/main/resources/base/element/float.json`
- Create: `harmony/entry/src/main/resources/dark/element/color.json`
- Create: `harmony/entry/src/main/ets/components/RuntimeStatusCard.ets`
- Create: `harmony/entry/src/main/ets/components/ProfileListItem.ets`
- Create: `harmony/entry/src/main/ets/components/SafeErrorCard.ets`
- Replace: `harmony/entry/src/main/ets/pages/Index.ets`
- Create: `harmony/entry/src/main/ets/pages/HomePage.ets`
- Create: `harmony/entry/src/main/ets/pages/ProfilesPage.ets`
- Create: `harmony/entry/src/main/ets/pages/ProfileDetailPage.ets`
- Create: `harmony/entry/src/main/ets/pages/ImportProfileSheet.ets`
- Modify: `harmony/tests/structure/phase3-ui-contract.test.mjs`

- [ ] **Step 1: Extend the RED UI contract**

Require all production pages/components, both page routes, semantic control
IDs, no Chinese or English user-facing string literals in `.ets`, all required
resource keys, system light/dark color tokens, safe-area handling, and no
`VPN`, `TUN`, `全局接管`, `全机代理`, traffic, log, provider, or settings claims.
Lock these stable IDs for Simulator automation:

```text
home.profile.manage
home.runtime.primary
profiles.add
profiles.row.<profileId>
import.file
import.url
import.submit
detail.enable
detail.refresh
detail.delete
```

- [ ] **Step 2: Run the RED UI contract**

Run:

```bash
node --test harmony/tests/structure/phase3-ui-contract.test.mjs
```

Expected: FAIL because the production UI/resources are absent and `Index`
still renders `Hello World`.

- [ ] **Step 3: Add resource and theme tokens**

Add Simplified Chinese resources for initialization, empty/active profile,
all five runtime states, local proxy actions, listener labels, add/import
forms, HTTP warning, active/valid/invalid/update-failed badges, enable/update/
replace/delete actions, delete confirmation, and the seven error stages.
Add semantic surface/text/border/accent/success/warning/error/disabled colors
with dark overrides, plus shared spacing/radius/type-size floats. Keep the
start window color resource valid in both themes.

- [ ] **Step 4: Implement focused components and page navigation**

`Index` owns `Navigation` plus composition loading/error/ready rendering and
creates/disposes page ViewModels. Home renders actual snapshot addresses and
one primary action. Profiles renders active and availability badges
independently and explains the running lock. Import uses a native sheet,
text inputs, Picker action, progress state, and a per-attempt HTTP alert.
Detail renders only redacted source/error values and requires an alert before
delete. `SafeErrorCard` copies only its pre-redacted value through the system
pasteboard.

Use system safe-area expansion, portrait-width adaptive padding, system font
scaling, minimum 48vp tap targets, and resource colors so system dark mode is
automatic. Do not add a custom theme toggle, landscape/tablet branches,
background service affordances, or local-port settings.

- [ ] **Step 5: Compile and run Chunk 3 verification**

Run:

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
cd ..
node --test harmony/tests/structure/*.test.mjs
git diff --check
```

Expected: entry Hypium, ArkTS/resource compilation, and every structure suite
PASS; the default HAP compiles with production `Index` and the debug page is
still packaged only as a conditional self-test route.

- [ ] **Step 6: Commit the production user flow**

```bash
git add harmony/entry harmony/tests/structure
git commit -m "Expose the first truthful Harmony local proxy flow" \
  -m "Constraint: The milestone controls only a local HTTP/SOCKS listener and must never imply VPN or system-wide capture
Confidence: high
Scope-risk: moderate
Tested: entry Hypium suite, ArkTS/HAP compile, and full structure suite"
```

## Chunk 4: Simulator integration evidence and final verification

### Task 14: Add an instrumented Simulator test bundle

**Files:**
- Create: `harmony/entry/src/ohosTest/module.json5`
- Create: `harmony/entry/src/ohosTest/ets/testability/TestAbility.ets`
- Create: `harmony/entry/src/ohosTest/ets/testrunner/OpenHarmonyTestRunner.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/List.test.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/Phase3PlatformAdapters.test.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/Phase3RuntimeFlow.test.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/Phase3UiFlow.test.ets`
- Create: `harmony/entry/src/ohosTest/resources/base/element/string.json`
- Create: `harmony/entry/src/ohosTest/resources/base/profile/test_pages.json`
- Create: `harmony/entry/src/ohosTest/resources/rawfile/phase3-valid.yaml`
- Create: `harmony/tests/fixtures/phase3-valid.yaml`
- Modify: `harmony/tests/structure/phase3-ui-contract.test.mjs`

- [ ] **Step 1: Write the failing test-bundle structure contract**

Require an `entry_test` test extension using Hypium's
`OpenHarmonyTestRunner`, the three named suites in deterministic order, and a
test-only rawfile byte-identical to the canonical fixture. Assert that no
`ohosTest` route, resource, fixture, runner, or build flag occurs in the
production `main_pages.json`, entry manifest, or default HAP source list.

The canonical configuration is deliberately minimal and uses the milestone
port:

```yaml
mode: rule
mixed-port: 7890
rules:
  - MATCH,DIRECT
```

- [ ] **Step 2: Run the RED structure test**

Run:

```bash
node --test harmony/tests/structure/phase3-ui-contract.test.mjs
```

Expected: FAIL because the Simulator test bundle and fixture do not exist.

- [ ] **Step 3: Scaffold the isolated Hypium test extension**

Use the installed HarmonyOS API 23 test-extension declarations, phone device
type, and existing dev-only `@ohos/hypium` package. `TestAbility` exists only
to supply a real `UIAbilityContext`; `OpenHarmonyTestRunner` loads
`List.test.ets`, waits for all async suites, writes one structured app-evidence
file, and exits non-zero when a required assertion fails. Do not add a
production launch parameter, exported test ability, signing profile, or new
permission.

- [ ] **Step 4: Exercise actual RDB, sandbox, and HUKS adapters**

In `Phase3PlatformAdapters.test.ets`, create the public platform graph in the
test bundle's isolated sandbox and cover:

- schema creation plus close/reopen persistence of profiles and active ID;
- a staged valid and failed revision surviving reconciliation only while
  referenced, with a synthetic orphan removed;
- HUKS URL encryption/decryption/delete using a non-exportable key;
- scanning RDB and envelope bytes to prove a sentinel URL, query token, YAML
  body, and external Picker URI are absent;
- corrupt/missing envelope errors remaining typed and redacted;
- idempotent graph cleanup and no surviving test profile after teardown.

Access adapters through the shared port-valued platform graph. Do not export
`HarmonyRdbDriver`, `HarmonyFileDriver`, or `HarmonyHuksDriver` to make the
test easier.

- [ ] **Step 5: Exercise the real core and production presentation state**

In `Phase3RuntimeFlow.test.ets`, copy the rawfile into a unique sandbox staging
path, calculate its digest, validate it with the real `CoreService`, retain and
save one profile through the real adapters, then use `ProfileApplication` to
enable, start, observe, and stop it. Assert call-visible behavior:

```text
validate → retain/save → revalidate → load → startLocal(7890)
→ RUNNING snapshot with HTTP/SOCKS addresses → stop → STOPPED
```

Instantiate `HomeViewModel` over the same facade and prove its displayed
addresses exactly equal the latest `RuntimeSnapshot`. Always stop the core and
close the graph in `finally`; a port conflict or cleanup failure is a failed
instrumented check, never a claimed listener.

- [ ] **Step 6: Exercise production navigation without a test-only route**

Use `@ohos.UiTest` Driver to launch `EntryAbility` without the self-test flag
and assert the stable semantic IDs from Task 13. Navigate Home → Profiles →
add sheet → URL form, verify the HTTP warning cancels without a request, and
return to the profile list. Seed any profile facts needed by the UI through
the same public application/port graph before launch; do not inject state into
ArkUI components or automate `CoreDebugPage`. File Picker cancellation is the
only system-Picker branch required in unattended Simulator automation; real
Picker selection remains a manual provisional observation because system
picker automation is not stable across Simulator images.

- [ ] **Step 7: Build the test HAP and run it when a Simulator is present**

Build with:

```bash
cd harmony
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
cd ..
```

When exactly one authorized Simulator is connected, install the production
and test HAPs and run:

```bash
hdc install -r \
  harmony/entry/build/default/outputs/default/entry-default-signed.hap
hdc install -r \
  harmony/entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap
hdc shell aa test -b com.github.kr328.clash.harmony \
  -m entry_test -s unittest OpenHarmonyTestRunner
```

Expected: each install exits `0` and reports a successful replacement before
the test command starts; on Simulator, all concrete-adapter, runtime, and UI
suites PASS and app evidence is written. If either signed path is absent,
signature verification rejects it, or a Simulator is unavailable, record the
lane as `incomplete`; do not invoke `aa test` after a failed install and do not
treat that environmental absence as test success.

- [ ] **Step 8: Commit the isolated integration bundle**

```bash
git add harmony/entry/src/ohosTest harmony/tests/fixtures/phase3-valid.yaml \
  harmony/tests/structure/phase3-ui-contract.test.mjs
git commit -m "Make Phase 3 observable on Simulator without widening production" \
  -m "Constraint: Simulator evidence is provisional and test fixtures must never enter the production HAP
Confidence: medium
Scope-risk: moderate
Tested: ohosTest HAP build and Phase 3 UI structure contract
Not-tested: physical-phone lifecycle and network behavior"
```

### Task 15: Create a truthful provisional Simulator proof runner

**Files:**
- Create: `harmony/tests/bin/run-phase3-simulator-proof.mjs`
- Modify: `harmony/tests/bin/inspect-hap.mjs`
- Create: `harmony/tests/fixtures/phase3-simulator-proof.schema.json`
- Create: `harmony/tests/fixtures/phase3-simulator-proof.example.json`
- Create: `harmony/tests/structure/phase3-proof-schema.test.mjs`
- Modify: `harmony/tests/structure/phase2-proof-schema.test.mjs`

- [ ] **Step 1: Write failing schema and runner tests**

Use mocked child processes/files to cover no target, ambiguous targets,
physical-only target, unsigned HAP, install failure, test timeout, stale or
oversized app evidence, run-ID mismatch, failed cleanup, redaction, and the
complete success path. Assert that the top-level result schema is exactly:

```json
{ "enum": ["provisional-pass", "incomplete"] }
```

The string `pass` must not be accepted as a top-level result. Both Phase 2
physical traffic and Phase 3 physical-device gates must be fixed to
`incomplete` in every Simulator proof, including the complete success path.

Add RED HAP-inspector cases for an explicit `production` build kind: it accepts
only a manifest whose `phase2SelfTest` tuple is
`enabled: false/purpose: production/releaseStatus: releasable`. Preserve the
current default/self-test behavior, including rejection unless that tuple is
`enabled: true/purpose: test-only/releaseStatus: not-releasable`. Both modes
must run the same strict native hashes, ABI, archive, provenance, and stub
checks.

- [ ] **Step 2: Run the RED runner contract**

Run:

```bash
node --test harmony/tests/structure/phase3-proof-schema.test.mjs
```

Expected: FAIL because runner, strict schema, and example are absent.

- [ ] **Step 3: Implement bounded target/build/install orchestration**

Reuse target discovery/masking, proof redaction, production native build, and
strict HAP inspection helpers already used by Phase 0–2. Do not copy their
device classification or secret/path sanitizers. The runner must:

1. generate a run ID and write evidence on every exit path;
2. build or accept one exact production HAP plus its `entry_test` HAP;
3. require exactly one target classified as `simulator` and never select a
   physical target for this runner;
4. require installable signed artifacts without writing signing paths;
5. install, launch the test runner with a bounded timeout, pull at most 1 MiB
   from `/data/storage/el2/base/files/phase3-simulator-app-evidence.json`, and
   require matching run/HAP/fixture identities;
6. force-stop the application and remove test artifacts even after failure;
7. rebuild the default production lane after the test run.

Use `spawn` argument arrays with `shell: false`; bound command output and
sanitize it before persistence.

Extend `inspectHap` with a required, allowlisted build-kind policy internally
and a CLI `--build-kind phase2-self-test|production`. Keep
`phase2-self-test` as the CLI/default library value so every existing Phase 2
caller retains the current gate. `production` changes only the expected
`phase2SelfTest` tuple; it must not skip or relax any artifact/provenance/stub
validation. Return a stable mismatch failure if a manifest is inspected under
the wrong kind.

- [ ] **Step 4: Derive provisional status from complete evidence only**

Allow `provisional-pass` only when strict HAP inspection reports the real
AArch64 core with `stubDetected: false`, all instrumented adapter/runtime/UI
checks succeeded, Home state addresses equal the runtime snapshot, start and
stop completed, identities match, cleanup succeeded, and failures are empty.
Every other outcome is `incomplete` with stable failure codes. A provisional
result must still contain:

```json
{
  "physicalDeviceGates": {
    "phase2Traffic": "incomplete",
    "phase3ProfileRuntime": "incomplete"
  }
}
```

- [ ] **Step 5: Run focused and full proof-contract tests**

Run:

```bash
node --test harmony/tests/structure/phase3-proof-schema.test.mjs \
  harmony/tests/structure/phase2-proof-schema.test.mjs \
  harmony/tests/structure/signing-isolation.test.mjs
git diff --check
```

Expected: runner/schema/example cases PASS, old physical proof semantics remain
unchanged, and no signing or machine-local identity leaks.

- [ ] **Step 6: Commit provisional evidence semantics**

```bash
git add harmony/tests/bin/run-phase3-simulator-proof.mjs \
  harmony/tests/bin/inspect-hap.mjs \
  harmony/tests/fixtures/phase3-simulator-proof.schema.json \
  harmony/tests/fixtures/phase3-simulator-proof.example.json \
  harmony/tests/structure/phase3-proof-schema.test.mjs \
  harmony/tests/structure/phase2-proof-schema.test.mjs
git commit -m "Prevent Simulator checks from becoming device claims" \
  -m "Constraint: No physical HarmonyOS phone is available, so both physical gates remain incomplete
Rejected: Reuse the Phase 2 pass result | Simulator execution cannot prove retail-device traffic or lifecycle
Confidence: high
Scope-risk: narrow
Tested: provisional proof schema, orchestration fakes, redaction, and signing-isolation contracts"
```

### Task 16: Run the complete Phase 0–3 verification and hand off the HAP

**Files:**
- Create: `docs/harmony/phase-0-3-verification.md`

- [ ] **Step 1: Run all ArkTS and structure regressions**

Run:

```bash
node --test harmony/tests/structure/*.test.mjs

cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
cd ..
```

Expected: every Node structure test and all shared/platform/entry Hypium suites
PASS with no skipped Phase 3 suite.

- [ ] **Step 2: Run core race, host-native, and API regressions**

Run:

```bash
cd harmony/core/go
go test -race -count=1 ./...
cd probe
go test -race -count=1 ./...
cd ../../../..

node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/audit-mihomo-api.mjs
```

Expected: both Go race suites, all three native lanes, and the pinned mihomo
API audit PASS.

- [ ] **Step 3: Run the Simulator proof when the lane is available**

Run:

```bash
node harmony/tests/bin/run-phase3-simulator-proof.mjs \
  --out harmony/artifacts/phase3-simulator-proof.json
```

Expected with one signed Simulator target: `provisional-pass`. Expected on the
current unsigned/device-deferred lane: `incomplete` with only explicit
Simulator/signing blockers. Either way, both physical gates remain
`incomplete`; any product, runtime, identity, redaction, or cleanup failure
must be fixed rather than documented as an environmental blocker.

- [ ] **Step 4: Rebuild and strictly inspect the production HAP**

After all test-only builds, clear test flags by using the default production
command:

```bash
node harmony/tests/bin/build-phase1-native.mjs \
  --out harmony/artifacts/phase3-production-provenance.json
node harmony/tests/bin/build-phase1-native.mjs \
  --validate harmony/artifacts/phase3-production-provenance.json
node harmony/tests/bin/inspect-hap.mjs \
  --hap harmony/entry/build/default/outputs/default/entry-default-unsigned.hap \
  --manifest harmony/artifacts/phase3-production-provenance.json \
  --build-kind production
```

On the current unsigned machine, the build command may exit `1` solely for
signing/device incompleteness; manifest validation and HAP inspection must exit
`0`. Require version `1.0.0` (`versionCode` `1000000`), arm64 production ABI,
real core/addon hash agreement, production self-test flag disabled,
`stubDetected: false`, no test fixture/runner in the archive, and the HAP path
shown above. A code/build/provenance failure is not an acceptable incomplete
result.

- [ ] **Step 5: Write the evidence-backed handoff record**

Create `phase-0-3-verification.md` with the exact commands, timestamps,
counts, production version/variant/HAP path and digest, Simulator result,
permissions, manifest-validation result, and package-inspection result. Carry
forward the Phase 0–2 evidence without changing its meaning. State explicitly:

- local-file Picker selection was manual/provisional if it was not stable in
  unattended UI automation;
- Simulator evidence is provisional;
- signing, install on retail hardware, Native load, real listener traffic,
  network changes, and process/background behavior on a HarmonyOS 6 phone are
  `incomplete`;
- VPN/TUN and system-wide traffic capture are not implemented.

- [ ] **Step 6: Apply verification-before-completion and commit the milestone**

Apply @superpowers:verification-before-completion. Confirm there are no active
build/test sessions, no failing required command, no unreviewed generated
lockfile, and no secret/signing/device artifact staged. Run:

```bash
git diff --check
rg -n "TO[D]O|TB[D]|placeholde[r]|FIXME|HACK|XXX" harmony docs/harmony
git status --short
```

Expected: no whitespace errors; the marker search prints no matches; status
shows only intentional Phase 3 source/tests/docs and excludes `harmony/artifacts`,
HAPs, signing material, device identities, and test secrets.

```bash
git add harmony docs/harmony/phase-0-3-verification.md
git commit -m "Deliver a device-deferred Harmony profile runtime" \
  -m "Constraint: Simulator checks are provisional and no physical HarmonyOS 6 phone is available
Rejected: Claim VPN or device completion | the milestone exposes only a local HTTP/SOCKS listener
Confidence: medium
Scope-risk: broad
Tested: full structure/Hypium/Go race/native/API/HAP provenance lanes and available Simulator checks
Not-tested: signed retail-phone traffic, lifecycle, and network-change behavior"
```
