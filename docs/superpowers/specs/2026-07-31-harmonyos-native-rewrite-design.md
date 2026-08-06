# HarmonyOS 6 Native Rewrite Design

**Status:** User-approved design
**Date:** 2026-07-31
**Target:** HarmonyOS 6.x, API 20 compatible baseline, arm64 phone
**Delivery:** Developer-signed HAP for local device installation
**License:** GPL-3.0, consistent with this repository

## 1. Summary

Clash Meta for Android is a native Android application built around Android
Activities, Services, `VpnService`, Room, AIDL/JNI, and a Go-based mihomo core.
It has no HarmonyOS module, ArkTS source, HAP configuration, or Hvigor build.

The HarmonyOS application will therefore be a ground-up native rewrite rather
than a port of the Android application structure. It will use ArkTS and ArkUI
for the user experience, official HarmonyOS Kits for platform services, an
OHOS Node-API bridge for native calls, and upstream mihomo as the proxy
protocol engine.

"Ground-up rewrite" applies to the HarmonyOS client, platform integration,
state management, persistence, UI, lifecycle, and native bridge. It does not
mean reimplementing the proxy protocols already implemented by mihomo.

The work is staged. The first usable milestone provides the full non-VPN
workflow with a real local HTTP/SOCKS proxy. System-wide traffic capture is a
later milestone built on `VpnExtensionAbility` and a TUN file descriptor.

## 2. Confirmed Product Decisions

| Decision | Confirmed choice |
| --- | --- |
| Target platform | Huawei phones running HarmonyOS 6.x |
| Application model | Native Stage model HAP |
| UI stack | ArkTS and ArkUI |
| Distribution | Developer-signed local installation first |
| First runtime milestone | Real local HTTP/SOCKS proxy before VPN/TUN |
| Functional scope | Migrate all meaningful existing functions except VPN/TUN in the first full-feature milestone |
| UI direction | Native HarmonyOS redesign; preserve feature semantics rather than Android pixels |
| Data compatibility | Accept subscription URLs, Clash YAML, and exported configuration files; do not migrate Android Room or SharedPreferences data |
| Android maintenance | Out of scope |
| Existing third-party Harmony project | Reference material only; not a code baseline |
| Implementation route | Ground-up rewrite |

## 3. Goals

1. Produce a self-contained HarmonyOS 6 application that does not depend on
   Android modules at build time or runtime.
2. Import compatible subscription URLs and Clash YAML files.
3. Run a real mihomo core on arm64 HarmonyOS, without a fake or stub backend in
   distributable builds.
4. Provide profile, proxy, provider, latency test, file, override, settings,
   scheduled update, access-control preparation, log, and diagnostic features.
5. Use HarmonyOS-native navigation, storage, notifications, background tasks,
   file access, networking, and VPN APIs.
6. Preserve the last valid configuration when downloads, validation, storage,
   or native operations fail.
7. Make failures visible and diagnosable without exposing subscription
   credentials or other secrets.
8. Establish reproducible HAP build, signing, installation, and real-device
   verification lanes.
9. Add system VPN/TUN after the local proxy and full non-VPN workflows are
   proven.

## 4. Non-Goals

1. Maintaining or refactoring the Android application.
2. Reusing Android Activities, Views, Services, AIDL, Room, ContentProviders,
   broadcasts, or JNI contracts in the HarmonyOS application.
3. Pixel-for-pixel replication of the Android UI.
4. Reimplementing mihomo protocols in ArkTS or C++.
5. Migrating the Android application's internal database or private settings.
6. Publishing to AppGallery in the first delivery.
7. Adding telemetry, advertising, remote log upload, or account services.
8. Emulating Android-only entry points such as Quick Settings tiles, secret
   dialer codes, or Android broadcasts when HarmonyOS has no supported
   equivalent.
9. Treating an emulator or a stub native core as proof that VPN or mihomo works
   on a HarmonyOS 6 phone.

## 5. Existing-System Evidence

The current repository contains the following Android-only modules:

- `app`
- `common`
- `core`
- `design`
- `hideapi`
- `service`

The current execution path is:

1. Android UI selects a profile and starts an Android Service.
2. `TunService` uses `VpnService.Builder` to create a TUN interface.
3. Kotlin calls a JNI bridge.
4. The JNI bridge calls C exports generated from the Go core.
5. The Go core uses Android callbacks for socket protection, UID lookup,
   content access, and logging.

This surface is not a portable native API. The HarmonyOS application will use
the existing behavior and data formats as reference, but it will define a new
platform-neutral C ABI and an OHOS Node-API facade.

## 6. Platform Feasibility and Constraints

### 6.1 Documented capabilities

HarmonyOS/OpenHarmony documentation establishes the following relevant
capabilities:

- `VpnExtensionAbility` and `@ohos.net.vpnExtension` are available from API 11.
- `VpnConnection.create()` returns the virtual network interface file
  descriptor.
- `VpnConfig` supports addresses, routes, DNS, MTU, trusted applications, and
  blocked applications.
- `VpnConnection.protect(fd)` excludes a socket from VPN interception.
- The first VPN connection requires explicit user authorization.
- Only one active VPN connection is supported by the documented basic flow.
- The OHOS NDK supports C/C++, CMake, LLVM, musl, and Node-API integration with
  ArkTS.
- RDB and Preferences provide structured and key-value local persistence.
- Picker and FileShare APIs provide file selection and persistent file access.
- Long-running background work is user-visible and controlled by the system.

### 6.2 Required real-device proof

Documentation alone does not prove production behavior on a retail HarmonyOS
6 phone. The following are mandatory device gates:

- A real mihomo arm64 shared library loads successfully.
- TUN fd handoff works under real traffic.
- Socket protection prevents routing loops.
- Background operation survives app switching and screen-off within documented
  system policy.
- Network callbacks behave correctly across Wi-Fi/mobile transitions.
- Trusted/blocked application routing behaves as configured.
- File grants remain usable for the intended lifetime.

Because no HarmonyOS 6 physical device is currently available, implementation
after Phase 1 may proceed with host tests, cross-build inspection, HAP static
inspection, and Simulator runs. This is a development-only exception: all
affected phase proofs remain `incomplete`, Simulator results are provisional,
and publication, VPN/TUN, real network takeover, traffic claims, and final
completion still require the physical-device gates above. Once a device is
available, all deferred Phase 1 and Phase 2 proofs must be rerun against the
exact packaged build.

### 6.3 Toolchain prerequisite

The development machine now has DevEco Studio 6.1.0.860 installed with the
pre-integrated HarmonyOS 6.1 SDK root at
`/Applications/DevEco-Studio.app/Contents/sdk/default`. Task 2 verifies this
installation state as an integrated API 23 SDK/NDK/tooling contract, records
non-secret version facts, and confirms the native/ArkTS files that the build
must use.

### 6.4 Target-SDK verification rule

OpenHarmony `master` documentation is discovery evidence, not the final
compatibility contract. Implementation must:

- Pin the project target SDK to `6.1.0(23)` while preserving the compatibility
  baseline `6.0.0(20)` and `runtimeOS: HarmonyOS` in the generated
  `build-profile.json5`.
- Confirm every imported ArkTS symbol against the declarations shipped in the
  installed integrated SDK, with Task 3 proving the project-level compatible
  baseline rather than relying on a standalone API 20 disk layout.
- Confirm every native symbol and linked library against the installed
  integrated NDK sysroot, `ohos.toolchain.cmake`, and
  `aarch64-unknown-linux-ohos-clang` wrapper.
- Avoid APIs that cannot be represented by the API 20 compatible project
  baseline unless they are isolated behind a capability check and have an API
  20 implementation.
- Record the exact DevEco, SDK, NDK, Hvigor, Ohpm, HDC, and device build
  versions in the proof artifacts.

An API found only in a newer OpenHarmony document does not satisfy this rule.

## 7. Repository Boundary

The new project lives under `harmony/` in this repository:

```text
harmony/
├── AppScope/
├── entry/
├── shared/
├── platform/
├── core/
├── tests/
├── build-profile.json5
├── hvigorfile.ts
└── oh-package.json5
```

The Android Gradle modules remain intact and are not dependencies of the
HarmonyOS build. This keeps the rewrite self-contained while retaining the
Android application as a behavior reference during development.

After the rewrite is proven, the `harmony/` tree can be extracted to a separate
repository without changing its module contracts.

## 8. Architecture

### 8.1 Dependency direction

```text
entry UI
  -> shared use cases and contracts
    -> platform adapters
    -> core adapter
      -> Node-API facade
        -> platform-neutral C ABI
          -> mihomo Go core
```

Dependencies only point downward. Platform modules do not import UI state.
Native code does not know ArkUI component types.

### 8.2 `entry`

Responsibilities:

- `EntryAbility`
- ArkUI navigation and pages
- View models and presentation state
- User permission prompts
- `VpnExtensionAbility` declaration and lifecycle entry point
- Application-level runtime coordination

`entry` may depend on `shared`, `platform`, and `core`. It must not call RDB,
Preferences, file, or Node-API methods directly; those calls go through use
cases and adapters.

### 8.3 `shared`

Responsibilities:

- Domain models
- Repository and service interfaces
- Use cases
- Runtime state machine
- Validation rules that do not require HarmonyOS APIs
- Error taxonomy

`shared` has no HarmonyOS UI dependency and is independently unit-testable.

### 8.4 `platform`

Responsibilities:

- RDB profile metadata and selection persistence
- Preferences settings
- Application sandbox paths
- Picker/FileShare import and export
- Network change observation
- Notifications
- Long-running background task integration
- Scheduled profile updates
- HUKS-backed secret storage

Android concepts such as Room, SharedPreferences, ContentProvider, Broadcast,
AlarmManager, or ForegroundService do not appear in this module.

### 8.5 `core`

Responsibilities:

- Build and package the real arm64 mihomo library
- Define the stable C ABI
- Provide the C++ Node-API facade
- Convert ArkTS inputs to validated native values
- Convert native results to typed ArkTS objects
- Deliver logs and state events asynchronously
- Own the TUN fd only while a TUN runtime is active

The core has three explicit boundaries:

1. **Node-API facade:** ArkTS values, Promises, callbacks, and error mapping.
2. **Platform-neutral C ABI:** primitive values, byte buffers, file paths,
   file descriptors, result structures, and host callbacks.
3. **Go/mihomo backend:** configuration, proxy groups, providers, traffic,
   local listeners, and later TUN processing.

The release build fails when the real core is missing. A stub is allowed only
in narrowly named development tests and can never be packaged as the
deliverable HAP.

### 8.6 Core interface groups

The platform-neutral ABI exposes these capability groups:

- Lifecycle: initialize, query version, reset, shut down.
- Configuration: validate, load, query active configuration, read/write
  overrides.
- Runtime: start local proxy, stop runtime, query runtime state.
- Proxies: query groups, select node, health check one/all.
- Providers: query providers and update a provider.
- Traffic: current and total traffic counters.
- Logging/events: subscribe, unsubscribe, structured event sink.
- VPN phase: start TUN with an owned fd, stop TUN, protect socket callback.

Host callbacks are limited to platform operations the core cannot perform
portably:

- Structured log sink
- Runtime event sink
- Socket protection

The HarmonyOS application copies imported files into its sandbox before the
core sees them, so the core does not need Android-style content URI callbacks.
Per-application routing uses `VpnConfig` trusted/blocked bundle names rather
than Android `/proc` UID attribution.

## 9. Runtime Ownership and State

Only one mihomo runtime may exist at a time.

The canonical state machine is:

```text
Stopped -> Starting -> Running -> Stopping -> Stopped
                      |
                      v
                    Error
```

Rules:

- Every transition is serialized by `RuntimeCoordinator`.
- Concurrent start requests coalesce or fail with a typed state error.
- Stop is idempotent.
- `Error` retains a diagnostic cause and can transition to `Starting` only
  through an explicit retry.
- A configuration update does not replace the active configuration until
  validation and atomic commit succeed.
- UI state is derived from runtime events and persisted confirmed state, never
  from optimistic button state.

### 9.1 Local proxy ownership

Before VPN is implemented, the application process owns the runtime and
requests a user-visible long-running task when required. If HarmonyOS revokes
that eligibility, the application reports the stopped/error state rather than
claiming the proxy still runs.

### 9.2 VPN ownership

In VPN mode, `VpnExtensionAbility` owns the TUN fd and the active runtime.
The UI becomes a controller. The exact process placement and IPC mechanism are
selected by the real-device PoC, but both must conform to the same
`CoreRuntime` and `RuntimeCoordinator` contracts. Switching between local and
VPN modes stops the current runtime before starting the next one.

## 10. Application Services

### 10.1 `ProfileService`

- Import subscription URL
- Import local YAML
- Create, copy, edit metadata, delete, update, and activate profiles
- Validate downloaded or imported content through the real core
- Preserve the last valid profile on failure

### 10.2 `CoreRuntime`

- Initialize and shut down the core
- Load the active configuration
- Start and stop local HTTP/SOCKS listeners
- Start and stop TUN in the VPN phase
- Translate native events into domain runtime events

### 10.3 `ProxyService`

- Query proxy groups
- Select a group member
- Search and sort nodes
- Run individual or batch latency checks
- Persist confirmed selections

### 10.4 `ProviderService`

- Query proxy and rule providers
- Update providers
- Expose status, update time, and structured failures

### 10.5 `SettingsService`

- Application and appearance settings
- Local proxy and network settings
- DNS settings
- Overrides
- Meta feature settings
- Update intervals
- Logging options
- VPN/TUN and access-control settings when available

### 10.6 `LogService`

- Receive structured native logs
- Filter and search live logs
- Pause UI scrolling without stopping collection
- Rotate persisted logs by size and count
- Export an explicitly requested diagnostic archive

### 10.7 `SchedulerService`

- Schedule profile refreshes
- Coalesce duplicate work
- Retry transient failures with bounded backoff
- Run a compensating refresh after network recovery when appropriate

### 10.8 `AccessControlService`

- Store bundle allowlist/blocklist choices
- Validate mutually exclusive modes
- Apply the selected list to `VpnConfig`

This service is visible but disabled with an accurate explanation until the VPN
milestone is implemented.

## 11. Persistence

### 11.1 RDB

RDB stores structured metadata, not full YAML bodies:

- `profiles`
  - stable profile ID
  - display name
  - source type
  - encrypted source reference when applicable
  - active flag
  - update interval
  - last successful update
  - last status
  - parsed subscription information
  - current committed version ID
- `profile_versions`
  - profile ID
  - immutable version ID
  - content hash
  - sandbox-relative directory
  - creation time
  - validation status
- `selections`
  - profile ID
  - proxy group
  - selected proxy
- `update_history`
  - profile ID
  - start/end time
  - outcome
  - non-secret diagnostic code

Provider state and live traffic are runtime data and are not persisted unless a
confirmed user setting requires it.

### 11.2 Preferences

Preferences stores small settings such as:

- Theme and language
- Sort modes
- Local listener ports
- DNS preferences
- Log level and retention
- Last selected page
- User-confirmed restart behavior

### 11.3 Files

Application sandbox directories contain:

- Active and inactive YAML profiles
- Temporary profile processing files
- Provider assets
- Geo data
- Override files
- Rotating logs
- Explicitly generated diagnostics

Profile payloads are immutable and versioned:

```text
profiles/<profile-id>/versions/<content-hash>/
processing/<operation-id>/
```

RDB's `profiles.current_version_id` is the only authoritative pointer to a
profile payload. A new version never overwrites or renames the directory
referenced by the current pointer.

Imported content follows:

```text
Picker input
  -> bounded read into processing directory
  -> core validation
  -> atomic rename into a new immutable version directory
  -> one RDB transaction inserts the version row and flips current_version_id
  -> active runtime reload when this is the active profile
  -> old-version cleanup only after confirmed success
```

Failure behavior:

- Validation failure removes the processing directory; RDB is untouched.
- Filesystem rename failure leaves RDB untouched.
- RDB commit failure leaves `current_version_id` unchanged; the new unreferenced
  version is cleaned immediately or during startup recovery.
- If the updated profile is active and runtime reload fails after the RDB
  commit, a compensating RDB transaction restores the previous version pointer
  and the runtime reloads the previous version.
- The previous version directory remains present until the new version is
  committed and, for an active profile, successfully loaded.

This version-pointer protocol provides rollback without claiming a nonexistent
atomic transaction across RDB and the filesystem.

## 12. User Experience

The phone UI uses HarmonyOS `Navigation` with four primary destinations:

- Home
- Proxies
- Profiles
- More

### 12.1 Home

- Start/stop control
- Active profile
- Proxy mode
- Current and total traffic
- Connection count
- Runtime warnings and errors
- Shortcuts to logs and diagnostics

### 12.2 Proxies

- Proxy group navigation
- Node selection
- Search and sort
- Single and batch latency tests
- Clear loading, success, timeout, and failure states

### 12.3 Profiles

- Subscription URL import
- Local YAML import
- Update and activate
- Copy and delete
- Subscription usage and expiration
- Profile file access and safe editing

### 12.4 More

- Providers
- Logs
- Files
- Settings
- Help and diagnostics
- About and open-source notices

### 12.5 Interaction requirements

- No unbounded loading indicator.
- Destructive operations require confirmation.
- Configuration errors identify the file, line, and field when the core
  provides that information.
- Core-dependent controls are disabled with an explanation until the core is
  ready.
- VPN-only controls are explicitly marked unavailable before the VPN
  milestone; they do not simulate success.
- Dark mode, dynamic text, rotation, and baseline accessibility are supported.
- Sensitive values are masked by default.

## 13. Key Flows

### 13.1 Import and activate a profile

1. User selects a URL or local file.
2. `ProfileService` creates a processing directory.
3. Content is downloaded or copied with size and timeout bounds.
4. The real core validates the content.
5. Validation errors return structured location and message data.
6. Successful content is atomically renamed into a new immutable version
   directory; the previous version remains untouched.
7. One RDB transaction inserts the version record and changes the profile's
   current version pointer.
8. Activation or an active-profile update asks `CoreRuntime` to load the
   committed version path.
9. If runtime load fails, the pointer and runtime are restored to the previous
   version before the failure is shown.
10. UI updates only after confirmed runtime events.
11. Superseded versions are cleaned only after successful commit and load.

### 13.2 Start a local proxy

1. `RuntimeCoordinator` verifies the state is `Stopped` or retryable `Error`.
2. The active profile is validated and loaded.
3. The core binds configured HTTP/SOCKS listeners.
4. Bind failures include the affected address/port and leave the runtime
   stopped.
5. Successful start emits `Running` with actual bound listener information.
6. The UI shows the confirmed listener addresses.

### 13.3 Select a proxy

1. UI sends profile ID, group, and target node to `ProxyService`.
2. The service verifies the group and node exist in the current snapshot.
3. The core applies the selection.
4. The confirmed selection is persisted.
5. A rejected selection leaves both runtime and persisted state unchanged.

### 13.4 Update a provider

1. UI or scheduler requests a provider update.
2. `ProviderService` deduplicates concurrent requests.
3. The core performs the update.
4. State and update time refresh on success.
5. Failure exposes a typed retryable or non-retryable result.

### 13.5 Start VPN

1. UI requests VPN start.
2. HarmonyOS presents its trust dialog when required.
3. `VpnExtensionAbility` constructs `VpnConfig`.
4. `VpnConnection.create()` returns the TUN fd.
5. The fd is transferred to `CoreRuntime`.
6. The core starts TUN processing and uses the host socket-protection callback.
7. `Running` is emitted only after traffic processing is ready.
8. Stop shuts down the core before destroying the VPN connection and closing
   the fd.

## 14. Error Model

All failures use a shared structured error:

- Stable error code
- Error category
- User-facing message
- Technical detail
- Retryable flag
- Suggested user action
- Optional non-secret context

Categories:

- `ConfigError`
- `NetworkError`
- `CoreError`
- `PermissionError`
- `StorageError`
- `SystemLimitError`
- `StateError`

Recovery rules:

- Failed profile updates retain the last valid profile.
- Native crashes do not trigger an infinite restart loop.
- Incomplete processing directories are cleaned on startup.
- Log retention prevents unbounded storage growth.
- Revoked background or VPN permission updates runtime and UI state
  immediately.
- The application never records an optimistic start as persisted success.

## 15. Security and Privacy

- Subscription URLs, credentials, private keys, and tokens are excluded from
  ordinary logs.
- Sensitive references use HUKS-backed encryption.
- Configuration exports warn that the content may contain credentials.
- Diagnostic exports require an explicit user action.
- The application does not send telemetry or logs.
- Node-API validates string length, file size, fd validity, and legal state
  order before calling the C ABI.
- Native callbacks never retain invalid ArkTS handles or expose raw pointers.
- Imported files are bounded and copied into the application sandbox before
  use.

## 16. Delivery Phases

### Phase 0: Toolchain and empty application

Deliverables:

- HarmonyOS 6.1 integrated SDK/NDK tooling verified with an API 20 compatible project contract
- Developer signing configured outside source control
- Empty native Stage HAP builds
- HAP installs and launches on a HarmonyOS 6 phone

Gate:

- `hvigorw assembleHap` succeeds reproducibly and `hdc` installs the produced
  HAP.

### Phase 1: Native bridge

Deliverables:

- C++ Node-API addon
- ArkTS type declarations
- `hello()` and `coreVersion()` calls
- Promise and event callback proof
- arm64 packaging verification

Gate:

- The phone loads and calls the real arm64 native library.

### Phase 2: Real mihomo local proxy

Deliverables:

- Reproducible mihomo OHOS build
- Stable C ABI
- Configuration validation and load
- HTTP/SOCKS start and stop
- Real logs and runtime events
- A test-only minimal ArkTS debug page showing core version, fixture validation,
  runtime state, actual listener addresses, recent structured logs, and
  start/stop/probe controls
- Checked-in non-secret Phase 2 YAML fixtures
- Deterministic HTTP and SOCKS device probes through the real listeners

Gate:

- No fake/stub backend is packaged.
- Both the HTTP listener and the SOCKS5 listener complete an HTTPS request to
  the test origin through the real core.
- Phase 2 uses a deterministic `MATCH,DIRECT` fixture; proxy group selection
  and remote-node behavior are Phase 3 acceptance concerns.
- The device runner writes `phase2-device-proof.json` containing toolchain and
  device build versions, HAP hash, native-library hash, reported core version,
  fixture hash, bound listener addresses, HTTP and SOCKS probe results,
  response hash, timestamps, and an explicit `stubDetected: false` result.

### Phase 3: Full non-VPN application

Deliverables:

- Profile, proxy, provider, latency, file, override, settings, scheduled
  update, log, and diagnostic workflows
- Native HarmonyOS UI
- Persistence and failure recovery

Gate:

- All non-VPN acceptance scenarios pass on a HarmonyOS 6 phone.

### Phase 4: VPN/TUN

Deliverables:

- VPN trust flow
- TUN fd handoff
- Routes, DNS, MTU
- Socket protection
- App allowlist/blocklist
- Correct start/stop ownership

Gate:

- Real phone traffic passes through TUN without a routing loop, and stop
  restores normal networking.

### Phase 5: Hardening and local delivery

Deliverables:

- Screen-off and app-switch testing
- Wi-Fi/mobile transition recovery
- Process and permission failure handling
- Log and storage pressure testing
- Developer-signed HAP and installation instructions

Gate:

- The complete device matrix passes with no known critical error.

## 17. Test Strategy

### 17.1 ArkTS unit tests

- Runtime state transitions
- Use cases and repository contracts
- Error mapping
- Settings validation
- Selection persistence
- Scheduler deduplication and bounded retry

### 17.2 Persistence and file tests

- RDB create and upgrade
- Atomic profile replacement
- Failed validation rollback
- Interrupted update cleanup
- Storage-full behavior
- Log rotation
- Import size limits

### 17.3 Native tests

- C ABI argument and state validation
- Node-API type conversion
- Promise resolution/rejection
- Asynchronous event delivery
- Callback shutdown
- Invalid and double-closed fd handling
- Concurrent start/stop requests

### 17.4 Go tests

- OHOS platform adapters
- Configuration validation
- Lifecycle interface
- Local listener creation
- Provider and proxy query contracts
- TUN adapter in the VPN phase

### 17.5 Contract tests

A checked-in, non-secret YAML corpus covers:

- Valid minimal configuration
- Proxy groups
- Proxy and rule providers
- Subscription metadata
- Overrides
- Invalid YAML
- Invalid fields
- Unsupported platform-specific options

Expected outputs are compared at the domain contract boundary rather than
against Android UI implementation details.

### 17.6 Build tests

- Debug HAP build
- Release-shaped HAP build without signing secrets in source control
- arm64 library ABI inspection
- HAP content inspection
- Explicit failure when the real core is missing
- Dependency and license notice verification

### 17.7 Device tests

- Install, launch, stop, uninstall, and reinstall
- URL and file import
- Proxy group and selection
- Latency test
- Local HTTP/SOCKS traffic
- Real-time log stream
- Background and screen-off behavior
- Network switching
- VPN authorization, TUN traffic, stop, and permission revocation
- App allowlist/blocklist

Emulator testing is limited to UI, basic ArkTS logic, and accessibility. It is
not accepted as evidence for native core, traffic, background, or VPN claims.

### 17.8 Phase 2 deterministic proxy proof

The limited Phase 2 surface uses:

- A checked-in, non-secret `MATCH,DIRECT` mihomo fixture.
- A test-only ArkTS debug page; production navigation and profile UI are not
  prerequisites.
- A test origin started by the repository's device-test harness on a
  development host reachable from the phone.
- A test-build native probe that connects first to the core's HTTP listener and
  then to its SOCKS5 listener, requests the same HTTPS test resource, and
  returns structured results to ArkTS.
- Origin and probe request IDs that prove both requests reached the intended
  endpoint.
- HAP and library inspection that rejects known stub symbols and verifies the
  packaged arm64 library hash.

The test runner persists the proof as `phase2-device-proof.json`. A screenshot,
UI toast, emulator result, or unstructured console log is not sufficient
evidence.

## 18. Acceptance Criteria

The first usable non-VPN milestone is complete when:

1. A developer-signed HAP installs and launches on a HarmonyOS 6 phone.
2. A compatible subscription URL or Clash YAML imports successfully.
3. The application shows proxy groups and nodes.
4. Node selection and latency testing work.
5. A real mihomo core starts HTTP/SOCKS listeners.
6. A real HTTPS request succeeds through the selected proxy.
7. Live logs can be filtered and exported.
8. A failed update or invalid configuration does not destroy the previous valid
   profile.
9. Native failure produces a typed error instead of crashing the UI.
10. The HAP contains no fake/stub core.

The VPN milestone is complete when:

1. The system trust flow works.
2. TUN fd handoff succeeds.
3. Real device traffic crosses the selected proxy.
4. Socket protection prevents recursion.
5. DNS and route settings take effect.
6. App allowlist/blocklist behavior matches the selected mode.
7. Stopping VPN restores normal networking.
8. UI, notification, and runtime state remain consistent through background,
   screen-off, network switching, and permission revocation tests.

## 19. Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Go does not build cleanly for OHOS | Blocks all real core work | Make real arm64 core loading the Phase 1/2 gate; do not build the UI around a stub |
| Android host assumptions remain in existing Go wrapper | Build or runtime failure | Define a new C ABI and OHOS host callbacks; do not reuse JNI, logcat, content URI, procfs, or Android API-level paths |
| gVisor/sing-tun require OHOS patches | Delays local proxy or TUN | Enable capabilities incrementally; prove config/local listener before TUN |
| Background policy stops the process | Proxy appears active but is not | Use official user-visible background mechanisms, observe cancellation, and derive UI from confirmed runtime state |
| VPN behavior differs on retail devices | System proxy milestone fails | Treat real-device VPN proof as a hard phase gate |
| File grants expire | Updates or edits fail later | Copy imports into the sandbox; request persistent grants only for explicitly linked external folders |
| Secrets leak through logs or exports | Privacy incident | HUKS-backed storage, structured redaction, explicit export warnings |
| Full rewrite scope grows too large | Long unverified development | Deliver vertical phases with device gates; no phase proceeds on fake evidence |
| Existing repository has little automated test coverage | Regression risk | Create a new HarmonyOS contract and device test suite from the first phase |

## 20. Licensing and Attribution

- New HarmonyOS code follows this repository's GPL-3.0 license.
- Upstream mihomo license and corresponding source/build obligations are
  preserved.
- Third-party notices list every distributed dependency and binary.
- The unrelated `andycaihello/clash-harmony` project may inform feasibility
  research but is not copied or used as a source baseline.
- Signing files, passwords, private keys, and device-specific paths never enter
  source control.

## 21. Planning Boundary

This document defines the complete product architecture and acceptance
contracts. The first implementation plan produced from it covers Phases 0-2:

1. Toolchain and signed empty HAP
2. Node-API bridge
3. Real mihomo local proxy

### 21.1 In scope for the first implementation plan

- Install-state verification for the HarmonyOS 6.1 integrated SDK/NDK toolchain, with project compatibility proved separately.
- Configure local developer signing without committing secrets.
- Create the self-contained `harmony/` Stage project.
- Build, install, and launch an empty HAP.
- Build and load the arm64 Node-API addon.
- Implement only the minimum domain/runtime contracts required by the debug
  proof surface.
- Build the real mihomo core and platform-neutral lifecycle/config/local-proxy
  ABI.
- Validate and load checked-in non-secret YAML fixtures.
- Start and stop real HTTP and SOCKS5 listeners.
- Display core version, runtime state, listener information, and recent
  structured logs on the test-only debug page.
- Run the deterministic HTTP and SOCKS device probes and write the structured
  Phase 2 proof artifact.
- Verify the HAP contains the real core and no stub.

### 21.2 Explicitly deferred from the first implementation plan

- Production navigation and visual polish
- RDB profile library and user-driven import
- Proxy group browsing, node selection, and latency UI
- Provider management
- File editor and export UI
- Production settings and overrides UI
- Scheduled updates
- Production log history, filtering, rotation, and export
- Access-control UI
- `VpnExtensionAbility`, TUN, route/DNS configuration, and socket protection
- Background hardening and release delivery

Phases 3-5 remain governed by the interfaces, flows, risks, and acceptance
criteria in this design, but each is planned only after its prerequisite device
gate passes. This prevents detailed UI or VPN work from being built on an
unproven native core.

## 22. References

Local evidence:

- `settings.gradle.kts`
- `build.gradle.kts`
- `core/build.gradle.kts`
- `core/src/main/cpp/main.c`
- `core/src/main/golang/native/`
- `service/src/main/java/com/github/kr328/clash/service/TunService.kt`
- `app/src/main/AndroidManifest.xml`
- `service/src/main/AndroidManifest.xml`

Platform references:

- [OpenHarmony third-party VPN guide, reviewed snapshot](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/network/net-vpnExtension.md)
- [OpenHarmony VPN Extension API, reviewed snapshot](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/reference/apis-network-kit/js-apis-net-vpnExtension.md)
- [OpenHarmony NDK overview, reviewed snapshot](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/napi/ndk-development-overview.md)
- [OpenHarmony continuous tasks, reviewed snapshot](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/task-management/continuous-task.md)
- [Huawei FileShare guidance](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/native-fileshare-guidelines)
