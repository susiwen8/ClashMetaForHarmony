# HarmonyOS Phase 3 Profile and Local Runtime Design

**Status:** User-approved design, pending implementation planning  
**Date:** 2026-08-07  
**Target:** HarmonyOS 6.x, target API 23, compatible API 20, ordinary phone portrait layout  
**Milestone:** Import one Clash configuration, enable it, and run the real local HTTP/SOCKS proxy  

## 1. Summary

Phase 3 replaces the production `Hello World`/core debug surface with the first
user-facing vertical slice of the native HarmonyOS application. A user can
import a local Clash YAML file or a subscription URL, see the resulting
profile even when it is invalid, enable one valid profile, start and stop the
real mihomo local proxy, and see current state or a structured error.

The work extends the Phase 0–2 native core rather than replacing it. It adds a
HarmonyOS `platform` module for persistence, sandbox files, networking, system
file selection, and secret protection; adds domain models and use cases to
`shared`; and adds native ArkUI pages and presentation state to `entry`.

The milestone intentionally does not implement VPN/TUN or claim system-wide
traffic interception. The local runtime binds a mihomo mixed listener that
accepts HTTP and SOCKS traffic. Phase 2 and Phase 3 physical-device proofs
remain `incomplete` until the exact packaged build can be run on a physical
HarmonyOS 6 phone.

This document deliberately narrows the broader Phase 3 full non-VPN scope in
the 2026-07-31 rewrite design to its first tracer-bullet milestone. Proxy and
provider management, latency tests, traffic views, logs, settings, and
scheduled refresh remain later milestones and must not be pulled into this
implementation plan.

## 2. Confirmed Decisions

| Topic | Decision |
| --- | --- |
| Implementation route | Layered vertical slice with a new `platform` module |
| UI direction | HarmonyOS-native appearance; preserve Android information hierarchy and feature meaning |
| First flow | Home, file/URL import, profile list, enable, local proxy start/stop, status and errors |
| URL refresh | Manual only in this milestone |
| Runtime meaning | Real local HTTP/SOCKS listener; no system traffic capture |
| Invalid input | Keep an unusable profile that can be retried, replaced, or deleted |
| Existing valid profile update failure | Keep the last valid configuration active and record the failed attempt |
| Profile switching while running | Disallowed; the user stops the runtime first |
| Layout | Ordinary phone portrait layout |
| Language | Simplified Chinese with all user-facing text in resources |
| Theme | Follow the system light/dark theme |
| VPN/TUN | Preserve an architectural boundary only; no UI or runtime implementation |
| Android maintenance | Out of scope |
| Physical-device status | Development may continue without a phone, but device gates remain `incomplete` |

## 3. Goals

1. Provide a complete, usable profile-to-local-proxy flow in production UI.
2. Keep profile metadata, source secrets, and configuration files inside
   explicit, testable storage boundaries.
3. Ensure a failed import or update never destroys the last valid profile
   revision.
4. Use the existing real `CoreService` contract for validation, loading,
   runtime control, snapshots, and events.
5. Make current state and failures understandable without exposing subscription
   credentials or configuration secrets.
6. Preserve Phase 1/2 self-test entry points and production-package guarantees.
7. Produce an unsigned production HAP that can be exercised in Simulator and
   later signed and rerun unchanged on a physical device.

## 4. Non-Goals

1. VPN/TUN, `VpnExtensionAbility`, system-wide proxying, per-application rules,
   or socket protection.
2. Proxy group selection, provider management, latency tests, traffic charts,
   logs, diagnostics export, overrides, or general settings pages.
3. Scheduled subscription refresh or background refresh.
4. AppGallery publication, account services, analytics, telemetry, or remote
   log upload.
5. Android data migration or Android code maintenance.
6. Tablet, foldable, landscape, or multi-window layout optimization in this
   milestone.
7. Auto-starting the local runtime after process launch or device restart.

## 5. Existing Baseline and Compatibility Boundary

The current `shared` module already defines `CoreService` with:

- `validateConfiguration`
- `loadConfiguration`
- `startLocal`
- `stopRuntime`
- `runtimeSnapshot`
- `subscribe` and `unsubscribe`

The `core` module already implements that contract through the real Node-API
and mihomo bridge. Phase 3 consumes this surface and adds only narrowly scoped
contract detail when the existing typed error information is insufficient for
the application error taxonomy. It does not expand proxy/provider/traffic or
VPN ABI groups.

`CoreDebugPage` and the Phase 1/2 launch parameters remain available to the
self-test build. `EntryAbility` selects the self-test page only when the
existing self-test launch flag is true; ordinary production launch selects the
new application home page. This preserves deferred physical-device proof
without exposing a debug page as the normal product surface.

The instruction in the Phase 0–2 handoff not to treat Simulator evidence as a
reason to advance proof status still applies. The user has explicitly allowed
Phase 3 development while those proofs are incomplete; this is not an
exception to any signing, physical-device, or publication gate.

## 6. Architecture

### 6.1 Dependency direction

```text
entry (ArkUI pages, view models, composition root)
  ├──> shared (models, ports, use cases, runtime coordinator)
  ├──> platform (HarmonyOS implementations of shared ports)
  └──> core (real implementation of shared CoreService)

platform ──> shared
core ──────> shared
shared ────> no entry/platform/core implementation
```

`shared` owns interfaces; `platform` and `core` implement them. The composition
root in `entry` creates concrete adapters and injects them into shared use
cases. A use case can therefore be tested with in-memory ports and a fake
`CoreService` without ArkUI, RDB, a file picker, or Native code.

### 6.2 `shared`

`shared` owns:

- Profile, revision, source, availability, runtime, and application error
  models.
- Repository, content store, source acquisition, and secret-store ports.
- Import, refresh, enable, delete, start, and stop use cases.
- The single-runtime coordinator and its serial command queue.
- Redaction rules and user-safe error mapping that do not require HarmonyOS
  APIs.

It does not import ArkUI components, RDB, Preferences, HUKS, picker, network,
or Node-API modules.

### 6.3 `platform`

`platform` is a new HarmonyOS library module. It owns:

- RDB profile metadata and active-profile persistence.
- App-sandbox configuration revisions and temporary files.
- System picker selection and copying selected bytes into the sandbox.
- HTTP/HTTPS subscription download.
- HUKS-backed encryption for subscription URLs.
- Startup reconciliation and unreferenced-file cleanup.

It does not own ViewModels, navigation, ArkUI visual state, or runtime policy.
Scheduled updates, notifications, long-running background tasks, and general
Preferences remain later additions to this module rather than being partially
implemented now.

### 6.4 `core`

`core` remains responsible for the real packaged mihomo library, Node-API
facade, typed ArkTS adapter, and asynchronous events. It accepts only sandbox
paths supplied through `CoreService`; it never receives picker URIs or
subscription URLs.

### 6.5 `entry`

`entry` owns:

- `EntryAbility`, application navigation, ArkUI pages, dialogs, and sheets.
- Home, profile list, import, and profile-detail ViewModels.
- The composition root and application-lifetime subscriptions.
- Mapping domain presentation models to resource-backed Chinese strings.

Pages invoke ViewModel commands and render immutable presentation state. They
do not issue RDB statements, copy files, call HUKS, download URLs, or invoke
Node-API directly.

## 7. Domain Model and Ports

### 7.1 Profile model

A profile has these durable fields:

- `id`: generated stable identifier.
- `name`: trimmed user-visible name, 1–80 characters.
- `sourceKind`: `LOCAL_FILE` or `REMOTE_URL`.
- `sourceDisplay`: original file name for local input or a redacted
  scheme/host representation for a URL.
- `sourceSecretRef`: absent for a local file; an encrypted source record for a
  URL. Plaintext URLs are never stored in RDB.
- `currentRevision`: the last configuration that passed core validation, or
  absent when none has passed.
- `failedCandidate`: the most recent acquired configuration that failed
  validation, or absent.
- `availability`: `VALID`, `INVALID`, or `UPDATE_FAILED_USING_VALID`.
- `lastError`: an optional structured application error.
- `createdAt`, `updatedAt`, and `lastSuccessfulUpdateAt` timestamps.

Profile names need not be globally unique; identity and selection use `id`.
The UI always shows source and status so duplicate display names remain
distinguishable.

The active profile is stored separately as a nullable `activeProfileId`, so
there cannot be multiple durable `enabled` flags. Repository transactions
reject an active ID that does not reference a valid profile.

### 7.2 Revision model

Each persisted revision records:

- its sandbox-relative path;
- SHA-256 digest and byte length;
- validation timestamp;
- whether it is the current valid revision or failed candidate.

Configuration contents and YAML fragments are not stored in RDB or error
records. A successful replacement changes the metadata reference before the
old file is removed. A failed validation never changes `currentRevision`.

### 7.3 Shared ports

The use-case boundary consists of:

- `ProfileRepository`: list/get/upsert/delete profiles and transactionally
  read or change `activeProfileId`.
- `ProfileContentStore`: stage imported bytes, retain a valid or failed
  revision, resolve a sandbox path for the core, remove profile content, and
  reconcile unreferenced files.
- `ProfileSourceGateway`: select and copy one local file, or download one URL,
  returning a staged source or a user-cancelled result.
- `SubscriptionSecretStore`: encrypt a URL, decrypt it only for manual refresh,
  and delete its encrypted record.
- Existing `CoreService`: validate/load configuration and control/observe the
  local runtime.

The source gateway owns platform-specific picker and network details. The
content store owns sandbox file layout. The repository owns metadata only.
None may update another unit's storage behind its interface.

## 8. Persistence and File Commit Protocol

RDB uses a versioned schema with a profile table and one application-state
row containing `activeProfileId`. Error and revision metadata may be encoded
as versioned JSON values inside the row, but their decoded form is always the
typed shared model.

Filesystem and RDB cannot share one native transaction, so writes use a
recoverable commit protocol:

1. Acquire bytes into a uniquely named temporary sandbox file.
2. Enforce the size limit and calculate its digest.
3. Ask `CoreService` to validate the temporary path.
4. Move the temporary file to a unique immutable revision path.
5. Commit the new revision reference and status in one RDB transaction.
6. Only after the RDB commit succeeds, delete the superseded revision.
7. If the RDB commit fails, delete the new unreferenced revision and retain
   the prior row and prior file.

On application startup, reconciliation removes stale temporary files and
revision files not referenced by RDB. It never removes a referenced current or
failed revision. This makes the change observable as atomic even if the
process exits between filesystem and database operations.

For an initial invalid configuration, the candidate revision is retained and
`currentRevision` remains absent. For an invalid update of a previously valid
profile, the new failed candidate and error are retained while
`currentRevision` and `activeProfileId` remain unchanged.

Deleting a non-running profile removes its RDB row and active selection in one
transaction, then deletes its files and encrypted source. Startup
reconciliation completes any cleanup left by a process exit. Deleting the
currently running profile is rejected before mutation.

## 9. Use Cases and Data Flow

### 9.1 Import local file

1. The user selects a file through the system picker.
2. Cancellation produces no profile and no error banner.
3. The gateway copies the selected bytes into a temporary sandbox file; the
   application does not retain dependence on the picker URI or grant.
4. The import use case validates and commits according to Section 8.
5. A valid result creates a `VALID` profile. A validation failure creates an
   `INVALID` profile with a failed candidate and structured error.
6. Once the picker returns a non-cancelled selection, any later read or copy
   failure deterministically creates an `INVALID` local-file profile with no
   candidate revision and a structured import error. Its recovery action is
   `重新选择文件`. If the picker does not provide a usable file name, the fixed
   resource string `本地配置` is used as both the initial name and source
   display. Only picker cancellation creates no profile.

The default name is derived from the selected file name and can be edited in
the import flow before commit.

### 9.2 Import subscription URL

1. The user supplies a name and an HTTP or HTTPS URL.
2. The URL is parsed and normalized for transport, encrypted for persistence,
   and represented publicly only by a redacted display value.
3. The gateway downloads to a temporary file and the import use case validates
   and commits it.
4. A download or validation failure still creates an `INVALID` profile with
   the encrypted source and structured error, allowing manual retry or delete.

If encryption fails, no profile or plaintext URL is persisted. The temporary
file is removed.

### 9.3 Manual update

- A URL profile decrypts its source only for the duration of a refresh request.
- A local-file profile opens the picker again; it does not attempt to reopen
  the original external URI.
- Success replaces the current revision and clears the failed candidate and
  last error.
- Failure retains the new failed candidate when bytes were acquired. A profile
  with a prior valid revision becomes `UPDATE_FAILED_USING_VALID`; an initial
  invalid profile stays `INVALID`.
- Refreshing a running profile is rejected until the runtime is stopped.

If a URL source cannot be found or decrypted, no download begins and no
candidate file is created. A profile with a valid current revision becomes
`UPDATE_FAILED_USING_VALID`; a profile without one remains `INVALID`. The
current revision and active selection are unchanged, and `lastError` records a
non-retryable `PERSISTENCE` error such as `SOURCE_SECRET_MISSING`,
`SOURCE_DECRYPT_FAILED`, or `SOURCE_SECRET_VERSION_UNSUPPORTED`. The detail
page offers `替换订阅地址` as the recovery action; retrying the same corrupted
secret is not presented as useful.

### 9.4 Enable profile

Enable is separate from start:

1. Reject the command unless the runtime is `STOPPED` or recoverably `ERROR`.
2. Resolve the selected profile's current valid sandbox path.
3. Revalidate it, then call `loadConfiguration`.
4. Persist `activeProfileId` only after the core load succeeds.
5. On failure, keep the former active ID and expose a structured error.

Enabling the already active valid profile is an idempotent no-op after its
stored invariants are checked.

### 9.5 Start and stop local proxy

Start requires a valid active profile. Because the core does not survive an
application process restart, start always resolves and loads the active
revision before calling `startLocal`. The first milestone uses mixed port
`7890`; the core `RuntimeSnapshot`, not the requested value, is the source of
truth for displayed HTTP/SOCKS addresses. Port configuration is deferred to a
later settings milestone. A port conflict is reported as a runtime-start
error.

Stop calls `stopRuntime` and waits for the resulting snapshot. Repeated start
or stop taps while a command is in progress do not enqueue duplicate commands.
Only one core runtime may exist.

The runtime coordinator subscribes once at application scope, merges command
results with core events, and publishes one canonical runtime presentation
state. It unsubscribes during application teardown.

## 10. Runtime State and Lifecycle

The canonical states are:

```text
STOPPED -> STARTING -> RUNNING -> STOPPING -> STOPPED
    \          |          |          /
     +---------+----------+---------+----> ERROR
```

`ERROR` always carries a structured last error and the latest core snapshot.
The coordinator reconciles an error event with `runtimeSnapshot`; it never
shows `RUNNING` based only on an earlier command result.

On cold application launch:

- profile metadata and `activeProfileId` are restored;
- storage reconciliation completes before profile actions are enabled;
- the canonical runtime state starts as `STOPPED` after checking the core
  snapshot;
- the application never auto-starts the proxy.

Moving the Ability between foreground and background does not imply a VPN or
guaranteed background service. Phase 3 makes no background-survival claim.
If the system terminates the process, the next launch shows `STOPPED`.

## 11. UI and Navigation

### 11.1 Application shell and home

The normal launch page is a HarmonyOS-native application shell using system
navigation, safe areas, typography, spacing, rounded surfaces, and automatic
light/dark colors. All strings are Simplified Chinese resources.

Home shows:

- the current profile or a prompt to add/enable one;
- the canonical runtime state and most recent user-safe error;
- one primary start/stop action with disabled progress states;
- the actual HTTP and SOCKS listener addresses returned by the core while
  running;
- navigation to the profile list.

The page consistently says `本地代理`. It does not use `VPN`, `全局接管`,
`全机代理`, or equivalent claims. Without a valid active profile, start is
disabled and the page links to profile management.

### 11.2 Profile list

Each list item shows name, redacted source, last update time, and exactly one
of the current/valid/invalid/update-failed badges that apply. The active badge
is visually distinct from validity.

The add action opens a native sheet with `从文件导入` and `通过 URL 导入`.
Selecting a profile opens its detail page. Running state disables switching
and explains that the local proxy must be stopped first.

### 11.3 Import interaction

The URL form contains name and subscription address. The local-file path uses
the system picker and a name derived from the selected file. Download,
validation, and save stages show one in-progress state and disable duplicate
submission. On completion, the application opens the profile detail page
whether the profile is valid or retained as invalid.

### 11.4 Profile detail

The detail page shows source type, redacted source, effective revision time,
last refresh result, availability, and structured error when present. Actions
are:

- enable a valid profile;
- manually update a URL profile;
- replace the subscription address when its saved secret cannot be decrypted;
- select a replacement for a local-file profile;
- delete a non-running profile.

An invalid profile never exposes an enable action. Delete requires a
confirmation dialog. A running profile cannot be deleted. Error details can
be copied only after applying the same redaction used for display and logs.

## 12. Error Taxonomy and Recovery

`AppError` contains a stable code, stage, user-facing resource key, redacted
technical detail, timestamp, and retryable flag. Stages are:

- `IMPORT`
- `DOWNLOAD`
- `VALIDATION`
- `PERSISTENCE`
- `CORE_LOAD`
- `RUNTIME_START`
- `RUNTIME_STOP`

Unknown platform and native errors map to a stable fallback code within the
correct stage. Raw exception text, stack traces, YAML fragments, full paths,
and full URLs never become user-facing messages or durable normal logs.

The shared core-error mapper uses the operation that raised an existing typed
`CoreError` to select `VALIDATION`, `CORE_LOAD`, `RUNTIME_START`, or
`RUNTIME_STOP`, preserves only allowlisted stable code/retryable fields, and
redacts its detail. Runtime event messages are untrusted diagnostic input and
are never displayed directly. If the current `CoreService` implementation
cannot expose the operation, stable code, and retryable flag already available
from its typed rejection, the only permitted contract expansion in this
milestone is a typed `CoreFailure` carrying those three fields plus sanitized
detail. It must not expand the native capability groups or ABI.

Recovery rules are:

- acquisition or validation failure cannot replace a valid revision;
- persistence failure compensates by removing the unreferenced new file;
- load failure cannot change `activeProfileId`;
- start failure returns to an error state with no claimed listener;
- a core error/stop event immediately updates the canonical state;
- a user retry runs a new command after the previous one has completed;
- local-file retry reopens the picker; URL retry reuses a decryptable encrypted
  source, while secret-store errors require replacing the subscription URL.

## 13. Security and Resource Limits

- Configuration files, valid or invalid, remain inside the application
  sandbox and are never copied to a public directory.
- A HUKS-managed non-exportable key encrypts URL plaintext. RDB stores only
  ciphertext, IV/nonce, authentication tag, version, and key alias metadata.
- Decrypted URL text exists only for the active download call and is not added
  to presentation state or logs.
- Redaction removes user info, path tokens, query strings, fragments, headers,
  filesystem roots, and likely credential values. The public URL form is at
  most scheme plus host.
- Only `http` and `https` schemes are accepted. HTTP is allowed for compatible
  local subscriptions but requires explicit confirmation before every network
  attempt, including initial import and each manual refresh. Confirmation is
  ephemeral and is not stored in RDB, Preferences, or the profile. Cancelling
  the warning performs no request, creates no error, and leaves the profile
  unchanged.
- Downloads have a 30-second request timeout, at most five redirects, and a
  maximum body size of 16 MiB. Redirects are revalidated for allowed schemes.
- Non-success HTTP status, empty response, oversized body, timeout, redirect
  violation, and TLS failure are distinct download error codes.
- Temporary files are removed after success, failure, or cancellation, with
  startup reconciliation as crash recovery.
- Import and runtime commands are serialized, and controls are disabled while
  their matching command is pending.
- No telemetry, analytics, remote logging, or account identity is added.

The module declares only the HarmonyOS permissions required for network access
and existing production behavior. Picker-mediated file selection must not be
replaced with broad storage permission.

## 14. Testing Strategy

### 14.1 Shared unit tests

Use in-memory ports and a fake `CoreService` to cover:

- valid and invalid initial imports;
- valid update and failed update preserving the prior revision;
- active-profile invariants and load-before-persist behavior;
- delete restrictions and cleanup requests;
- start/stop serialization, idempotence, core events, and cold-start state;
- every error-stage mapping and redaction of URL/path/config secrets.

### 14.2 Platform adapter tests

Use isolated temporary stores and deterministic network fixtures to cover:

- RDB creation, migration version, transactions, and active-ID constraints;
- commit compensation and startup orphan reconciliation;
- picker cancellation versus read/copy failure;
- HUKS encryption round-trip without plaintext persistence;
- missing, corrupt, and unsupported-version URL secrets with deterministic
  profile status and replacement recovery;
- HTTP success, status failures, TLS failure, timeout, redirects, scheme
  rejection, empty body, and 16 MiB limit;
- per-attempt HTTP warning confirmation/cancellation without persisted consent;
- cleanup after success, failure, cancellation, and simulated process gaps.

Tests must not depend on a real subscription service or persist test secrets in
the repository.

### 14.3 Core and native regression tests

Retain all Phase 0–2 structure, Go race, native contract, backend, Node-API,
API-audit, cross-build, HAP-inspection, and production-manifest tests. Add
contract coverage only for any typed-error detail changed for Phase 3.

The normal production package must still contain the real AArch64 core and
addon, must report `stubDetected: false`, and must not package the Phase 2
self-test backend as releasable output.

### 14.4 ArkUI and integration tests

With injected presentation fixtures, cover:

- empty, valid-active, invalid, update-failed, running, transitioning, and
  error screens;
- disabled duplicate actions and running-state profile restrictions;
- navigation among home, list, import, and detail;
- Simplified Chinese resource resolution and light/dark theme rendering;
- secret-safe display and copy output.

On HarmonyOS Simulator, exercise the production navigation and file/URL flows
as far as supported, then start and stop the real local listener and compare
displayed addresses with `RuntimeSnapshot`. Simulator results are provisional
and cannot satisfy physical-device gates.

## 15. Milestone Acceptance

Phase 3 implementation is ready for device-deferred handoff only when all of
the following are true:

1. A local Clash YAML file can be selected, copied, validated, represented as
   a profile, enabled, and used to start and stop the real local listener.
2. An HTTP/HTTPS URL can be downloaded, validated, imported, and manually
   refreshed.
3. An invalid configuration remains visible and cannot be enabled, but can be
   retried, replaced, or deleted.
4. A failed update never replaces the last valid configuration.
5. Runtime and profile commands remain consistent under duplicate taps, core
   errors, and application cold launch.
6. Display, copied error details, durable normal logs, and RDB contain no
   plaintext subscription URL or configuration body.
7. All new shared, platform, ArkUI, and integration tests pass, and all Phase
   0–2 regression lanes still pass.
8. The production HAP builds and passes strict package/provenance inspection
   with the real core and no stub.
9. The verification record explicitly reports signing and physical-device
   results as `incomplete` when those inputs remain unavailable.

A signed install, Native library load, real listener traffic, network changes,
and process/background behavior on a retail HarmonyOS 6 phone remain mandatory
deferred gates. Their absence prevents a final production-ready or
device-verified claim, but does not prevent planning and implementing this
device-independent Phase 3 slice.

## 16. Implementation Planning Boundary

The implementation plan should deliver one tracer-bullet path rather than
building all layers in isolation:

1. Add shared models/ports/use cases with failing tests.
2. Add the minimal `platform` module adapters and their tests.
3. Wire the composition root and preserve conditional self-test launch.
4. Add profile import/list/detail UI and resource-backed text.
5. Add home runtime control and canonical event-driven state.
6. Run the complete Phase 0–3 verification and rebuild the production HAP.

Scheduled refresh, proxy/provider controls, logs, settings, and VPN/TUN each
require later milestone designs and are not hidden tasks inside this plan.
