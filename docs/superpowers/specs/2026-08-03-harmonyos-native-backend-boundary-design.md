# HarmonyOS Native Backend Boundary Correction Design

**Status:** Approved direction for the Phase 1 Task 7 boundary correction

**Parent design:** `docs/superpowers/specs/2026-07-31-harmonyos-native-rewrite-design.md`

**Parent plan:** `docs/superpowers/plans/2026-07-31-harmonyos-phases-0-2.md`

## Problem

Task 5 currently builds a real Go `c-shared` library whose raw version getter is
exported as:

```c
const char *cmfa_core_version(void);
```

Task 6 independently defines the stable app-facing ABI entry point with the
same symbol name but an incompatible signature:

```c
cmfa_status cmfa_core_version(char *out, size_t capacity, cmfa_error *error);
```

Loading both definitions into the Task 7 process would permit ELF symbol
preemption or misbinding. It would also bypass the hidden backend registration
seam already implemented by Task 6. Task 7 cannot rely on link order, global
symbol lookup, or a fake backend to make the Phase 1 proof pass.

## Goals

- Keep the default public C ABI limited to the eight Task 6 app-facing
  functions.
- Make `coreVersion()` reach the real Go/mihomo library through the hidden
  Task 6 backend seam.
- Remove the incompatible duplicate ELF symbol before the Node-API addon links
  the two native layers.
- Keep not-yet-implemented configuration and runtime capabilities explicitly
  unavailable; never synthesize a fake success.
- Keep the correction independent of Android, JNI, `libdl`, and Android build
  modules.
- Preserve a direct evolution path for Task 9 to add the remaining real
  backend operations.

## Non-goals

- Implementing configuration parsing, listeners, traffic probes, VPN/TUN, or
  other Phase 2+ backend capabilities.
- Introducing a second contract DSO.
- Adding dynamic backend replacement after `cmfa_initialize`.
- Using `dlopen`/`dlsym` or changing the native dependency allowlist to admit
  `libdl.so`.
- Modifying or maintaining the Android application.

## Decision

### 1. Give the raw Go export a backend-private, versioned name

The Task 5 Go library will export:

```c
const char *cmfa_mihomo_core_version_cstr_v1(void);
```

The old raw `cmfa_core_version(void)` export will be removed. The build helper,
ELF inspector, proof contract, and structure tests will require the versioned
private symbol and reject the old conflicting symbol.

The raw function remains a real DSO export because the separately built
Node-API addon must link to it. Its name makes the implementation boundary and
signature generation explicit; it is not part of the app-facing ABI.

### 2. Add one hidden C++ backend adapter

Task 7 will add a focused `mihomo_backend_adapter` unit in the Node-API native
tree. It is the only production unit allowed to include both the private Go
backend declaration and Task 6's `CMFA_INTERNAL_BACKEND_API` seam.

The adapter will:

- provide a complete `cmfa_backend_api` vtable required by Task 6;
- copy the raw Go version into the caller-owned buffer with bounded,
  NUL-terminated semantics;
- return `CMFA_CORE_UNAVAILABLE` for configuration and start operations that
  Task 9 has not implemented;
- report a truthful stopped snapshot while no runtime capability exists;
- make `stop` and `shutdown` idempotently release only resources the adapter
  actually owns;
- register before `cmfa_initialize` and unregister only after
  `cmfa_shutdown`, matching Task 6 lifecycle rules.

This is a partial real backend, not a stub: the version comes from the real Go
library, unsupported capabilities return typed failures, and no proxy success
is fabricated.

The Phase 1 hook matrix is fixed:

| Hook | Phase 1 behavior |
| --- | --- |
| `attach_host` | Copy the backend-host bridge only; allocate no proxy runtime |
| `core_version` | Call the real versioned Go export and perform the bounded copy |
| `validate_config` | Return `CMFA_CORE_UNAVAILABLE` |
| `load_config` | Return `CMFA_CORE_UNAVAILABLE` |
| `start_local` | Return `CMFA_CORE_UNAVAILABLE` and never bind a listener |
| `runtime_state` | Return a caller-owned truthful `STOPPED` snapshot |
| `stop` | Return `CMFA_OK` idempotently because no runtime was created |
| `shutdown` | Release the copied host bridge and return `CMFA_OK` idempotently |

### 3. Direct-link the addon and real core

The Task 7 CMake target will link the versioned private export directly from
the freshly built `libcmfa_mihomo.so`. It will not use global lookup or
`dlopen`/`dlsym`.

The build must use repository-relative CMake paths and must not commit the
generated `.so`, cgo header, HAP, signing material, or absolute SDK paths. HAP
verification must prove that the arm64 addon and real core are packaged from
the fresh build artifacts.

The source of truth for “fresh” is a versioned ignored Phase 1 build manifest.
The build flow hashes `libcmfa_mihomo.so` immediately after the fresh core
build. It then builds `libentry.so`, hashes that exact pre-package addon, and
only then permits HAP packaging. After packaging it hashes the HAP. Package
inspection extracts both native libraries from that exact HAP and requires
their bytes to match the earlier pre-package hashes. The manifest also records
the canonical artifact identities, toolchain lock digest, build start/finish
timestamps, and a random run ID. A missing, stale, ambiguous, or hash-mismatched
manifest is `fail` or `incomplete`, never `pass`.

### 4. Make the host runner's case selection real

`harmony/tools/test-native-host.mjs` will gain strict case parsing:

```text
default / --case contract     -> Task 6 ABI contract tests
--case napi-environment       -> Task 7 environment-owner tests
unknown or missing case value -> non-zero typed CLI failure
```

The N-API environment host test will use opaque handles and injected native
operations, so macOS never attempts to load the arm64 HarmonyOS Node-API
libraries. Production code will map that seam to the SDK's actual
`napi_*` APIs.

## Runtime and teardown rules

- Addon initialization order is backend registration, Task 6 initialization,
  then JS export publication.
- Environment cleanup first prevents new JS delivery, then cancels or joins
  async work, aborts/releases thread-safe functions, calls `cmfa_shutdown`,
  and finally unregisters the backend.
- Cleanup is idempotent. No queued completion or event may touch a torn-down
  `napi_env`.
- Backend adapter callbacks and strings are copied or retained for the full
  native call lifetime; no stack pointer crosses an asynchronous boundary.
- A failure to load or call the real Go library is a typed error and a Phase 1
  proof failure, never a fallback to a fake version.

## Error handling

- Raw Go version pointer is null: `CMFA_BACKEND_ERROR`.
- The private adapter constant `CMFA_MIHOMO_VERSION_MAX_BYTES` is exactly 256,
  including the terminator. The adapter scans no more than those 256 bytes.
- Raw version is empty or is not NUL-terminated within 256 bytes:
  `CMFA_BACKEND_ERROR`; this is malformed backend output and is independent of
  caller capacity.
- After a valid raw length is known, caller capacity smaller than
  `raw_length + 1` produces `CMFA_BUFFER_TOO_SMALL`, with `out[0] = '\0'` when
  capacity is non-zero.
- Not-yet-implemented backend capability: `CMFA_CORE_UNAVAILABLE`.
- Duplicate or late backend registration: preserve Task 6's typed lifecycle
  error.
- Node-API conversion errors use the declared `CoreError` taxonomy and never
  persist raw secrets or unrestricted local paths.

## Verification

The correction is accepted only when all of the following are fresh and pass:

1. Structure tests first fail against the old raw export, absent adapter, and
   missing runner case, then pass after implementation.
2. Go unit tests and the OHOS `c-shared` build pass with the versioned private
   export.
3. ELF inspection proves AArch64, requires the new private export, rejects the
   old incompatible export, and permits only the checked-in component
   dependencies. For `libcmfa_mihomo.so`, the only permitted `cmfa_*` export
   in Phase 1 is `cmfa_mihomo_core_version_cstr_v1`; cgo/runtime exports may
   remain but test, fake, and stub sentinels are forbidden. For `libentry.so`,
   `cmfa_internal_*`, backend-registration, environment-test, and test-hook
   symbols must not be externally visible. Neither library may depend on
   `libdl.so`, and every `DT_NEEDED` entry must be an exact member of the
   checked-in component allowlist.
4. Host adapter tests prove bounded version copying and typed unavailable
   operations without a fake backend.
5. `--case napi-environment` proves cancellation, join/drain, double cleanup,
   exactly-once release, and no delivery after teardown.
6. The Task 6 contract suite and all existing structure tests remain green.
7. The Phase 1 build manifest records pre-package SHA-256 values for the fresh
   `libcmfa_mihomo.so` and `libentry.so`; HAP inspection extracts both entries
   and proves exact byte-for-byte hash equality. Missing signing remains an
   honest incomplete device/build gate, and stale or swapped native bytes can
   never pass.

## Stop rules

- Stop Task 7 integration if the real core cannot be linked without the old
  conflicting symbol.
- Do not add `libdl`, a fake version, a stub backend, or Android/JNI code to
  bypass a link or load failure.
- Do not claim the Phase 1 device gate until a HarmonyOS 6 arm64 phone loads
  the fresh HAP and reports the real version with matching hashes.
