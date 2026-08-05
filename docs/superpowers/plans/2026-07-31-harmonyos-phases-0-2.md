# HarmonyOS 6 Phases 0–2 Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and prove a self-contained HarmonyOS 6/API 20 Stage HAP that loads a real arm64 native bridge and then runs a real mihomo HTTP/SOCKS local proxy with reproducible device evidence.

**Architecture:** The Harmony tree is independent of the Android Gradle modules. ArkTS calls a C++ Node-API facade, the facade calls a hand-written platform-neutral `cmfa_*` C ABI, and an OHOS-targeted Go shared library implements that ABI with pinned upstream mihomo code. Every phase has an explicit artifact gate; no stub or emulator result can satisfy the real-core or traffic gates.

**Tech Stack:** HarmonyOS 6/API 20, Stage model, ArkTS/ArkUI, Hvigor, OHOS NDK/LLVM, C++17 Node-API, Go/cgo `c-shared`, upstream mihomo, Node.js built-in test runner, `hdc`.

**Design spec:** `docs/superpowers/specs/2026-07-31-harmonyos-native-rewrite-design.md`

---

## Current Baseline

- The repository has no `harmony/` tree.
- DevEco Studio 6.1.0.860 is installed with the integrated HarmonyOS 6.1 SDK/NDK/tooling root at `/Applications/DevEco-Studio.app/Contents/sdk/default`; Task 2 pins that installation contract.
- Node.js `v22.17.0`, Java 17, and Go `1.26.2 darwin/arm64` are available.
- `go tool dist list` does not provide an `ohos/arm64` target.
- `core/src/foss/golang/clash` is a declared but uninitialized mihomo submodule.
- The Android JNI bridge is evidence only. It must not become a dependency of the HarmonyOS build.

## Hard Gates and Stop Rules

1. The installed DevEco 6.1 integrated API 23 SDK/NDK files are the installation authority; Task 3 must still prove the API 20 compatible project settings in `build-profile.json5`.
2. DevEco generates the initial Stage project. Do not hand-copy an old API 12/13 template.
3. `GOOS=linux GOARCH=arm64 CGO_ENABLED=1` with the OHOS clang is a hypothesis until a library is built and loaded on a HarmonyOS 6 phone.
4. If the Go/cgo smoke library cannot load, stop Phase 1 core work and diagnose the toolchain/runtime mismatch. Do not replace it with a fake backend.
5. Phase 2 cannot pass unless the HAP inspection proves arm64, the real-core symbols exist, the stub sentinel is absent, and both HTTP and SOCKS HTTPS probes pass.
6. A missing device, signing identity, SDK, or proof input produces a versioned `incomplete` proof artifact rather than a false success.

## Explicit Non-Goals for This Plan

- Production navigation, profile library, RDB, Preferences, providers UI, node selection UI, scheduled updates, production log history, VPN/TUN, socket protection, and app allow/block lists.
- Modifying or maintaining Android modules.
- Reusing JNI, `android/log`, Android content URIs, Android `/proc` UID lookup, or `VpnService`.
- AppGallery publication or release signing.

## Planned File Map

```text
harmony/
├── AppScope/
├── entry/
│   └── src/main/
│       ├── cpp/                 # OHOS Node-API facade and CMake
│       └── ets/                 # EntryAbility and Phase 1–2 debug page
├── shared/
│   └── src/main/ets/core/       # Small typed runtime contracts
├── platform/
│   └── src/main/ets/fs/         # Sandbox-only fixture paths
├── core/
│   ├── abi/                     # Public hand-written C ABI
│   └── go/                      # OHOS wrapper and pinned mihomo module
├── tests/
│   ├── bin/                     # Build, HAP, ABI, and device runners
│   ├── fixtures/                # Non-secret YAML and proof schemas
│   ├── native/                  # Host C/C++ contract tests
│   └── structure/               # SDK-independent Node tests
├── tools/                       # Toolchain discovery and build helpers
└── artifacts/                   # Ignored generated proof/output files
```

## Chunk 1: Phase 0 — Toolchain, Stage HAP, Signing, and Device Launch

### Task 1: Lock the toolchain contract with an SDK-independent preflight

**Files:**
- Create: `harmony/tests/structure/toolchain-discovery.test.mjs`
- Create: `harmony/tests/fixtures/toolchain-complete.json`
- Create: `harmony/tools/lib/toolchain.mjs`
- Create: `harmony/tools/preflight.mjs`
- Create: `harmony/toolchain.requirements.json`
- Create: `harmony/artifacts/.gitkeep`
- Modify: `.gitignore`

- [ ] **Step 1: Write the failing toolchain discovery test**

  Test the pure discovery functions with injected command results and a fake SDK tree. Required normalized fields are:

  ```js
  {
    schemaVersion: '1.0.0',
    result: 'pass',
    target: {
      name: 'HarmonyOS 6/API 20/arm64',
      targetSdkVersion: '6.1.0(23)',
      compatibleSdkVersion: '6.0.0(20)',
      runtimeOS: 'HarmonyOS'
    },
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      sdkApiVersion: 23,
      ndkVersion: '6.1.0.105',
      hdcVersion: '6.1.0.105'
    },
    tools: {
      node: { found: true, version: '22.17.0' },
      java: { found: true, version: '17.0.18' },
      hvigor: { found: true, version: '6.23.7' },
      ohpm: { found: true, version: '6.1.1.830' },
      hdc: { found: true, version: '6.1.0.105' },
      ohosClang: { found: true, version: null },
      llvmReadelf: { found: true, version: null }
    }
  }
  ```

  Assert that a missing required tool changes `result` to `incomplete`, records a stable failure code, and never records environment-variable values or absolute secret paths.

  `toolchain-complete.json` is the canonical fake-success input consumed by
  this test. It contains the complete object shown above plus non-secret fake
  SDK-relative entries for the API declaration root, NDK sysroot, CMake
  toolchain, clang, and `llvm-readelf`. Missing-tool, wrong-API, and
  missing-NDK cases are derived in memory from that fixture so a second
  ambiguous fixture format is not introduced.

- [ ] **Step 2: Run the test to verify RED**

  Run: `node --test harmony/tests/structure/toolchain-discovery.test.mjs`

  Expected: FAIL because `harmony/tools/lib/toolchain.mjs` does not exist.

- [ ] **Step 3: Implement discovery and the CLI**

  `toolchain.mjs` must:

  - resolve tools from `PATH`, DevEco's documented terminal environment, and an optional ignored `harmony/local.properties`;
  - run version commands without a shell;
  - locate the integrated ArkTS declaration tree, NDK sysroot, CMake toolchain, `aarch64-unknown-linux-ohos-clang`, and `llvm-readelf`;
  - return structured failures such as `SDK_METADATA_MISSING`, `ARKTS_DECLARATIONS_MISSING`, `TOOL_MISSING`, `TOOL_VERSION_MISSING`, and `NDK_MISSING`;
  - redact device serials and local paths in persisted output.

  `preflight.mjs` writes `harmony/artifacts/toolchain-preflight.json` even when incomplete and exits `0` only when every required item is found.

- [ ] **Step 4: Add repository hygiene**

  Add ignores for:

  ```gitignore
  /harmony/.hvigor/
  /harmony/oh_modules/
  /harmony/build/
  /harmony/**/build/
  /harmony/artifacts/*
  !/harmony/artifacts/.gitkeep
  /harmony/local.properties
  /harmony/**/*.p12
  /harmony/**/*.cer
  /harmony/**/*.p7b
  /harmony/**/*.pem
  ```

  Do not ignore checked-in non-secret test fixtures.

- [ ] **Step 5: Verify GREEN against fixtures and honest RED against this Mac**

  Run: `node --test harmony/tests/structure/toolchain-discovery.test.mjs`

  Expected: PASS.

  Run: `node harmony/tools/preflight.mjs`

  Expected on a missing install: exit code `2`; proof has `result: "incomplete"` and identifies which integrated metadata, declarations, native files, or tools are absent.

- [ ] **Step 6: Commit the preflight increment**

  Commit only the files in this task with a Lore message whose intent line is `Make the HarmonyOS toolchain prerequisite reproducible`.

### Task 2: Verify the integrated DevEco 6.1 toolchain and pin non-secret version facts

**Files:**
- Create after installation: `harmony/toolchain.lock.json`
- Create after installation: `harmony/toolchain.native-allowlist.json`
- Create: `harmony/tests/structure/api20-sdk-contract.test.mjs`
- Modify: `harmony/tools/preflight.mjs`

- [ ] **Step 1: Obtain the official toolchain**

  Use the current package from Huawei's official DevEco resources page:
  `https://developer.huawei.com/consumer/cn/deveco-studio/resources/`.

  Validate the already-installed official DevEco 6.1 package, its pre-integrated HarmonyOS 6.1 SDK/NDK, and the bundled command-line/device tools. Immediately record the exact discovered versions in `toolchain.lock.json`; do not use a remembered version or lower-bound example as the lock. Accept no SDK copied from an unrelated repository.

- [ ] **Step 2: Write a failing integrated SDK contract test**

  Given the discovered SDK root, assert that:

  - the integrated SDK metadata and locked target/compatible/runtimeOS contract exist;
  - ArkTS API declarations can be enumerated from the integrated SDK;
  - the NDK sysroot and `ohos.toolchain.cmake` exist;
  - `aarch64-unknown-linux-ohos-clang`, `llvm-readelf`, and `hdc` are executable.

- [ ] **Step 3: Run the contract test to verify RED**

  Run: `node --test harmony/tests/structure/api20-sdk-contract.test.mjs`

  Expected before installation/configuration: FAIL with one stable missing-tool or missing-SDK code.

- [ ] **Step 4: Generate the lock file from actual tools**

  Persist `schemaVersion`, the fixed target string
  `HarmonyOS 6/API 20/arm64`, the project target/compatible/runtimeOS values,
  and the exact discovered values for `devecoVersion`, `sdkVersion`,
  `ndkVersion`, `hvigorVersion`, `ohpmVersion`, and `hdcVersion`. The generator rejects an empty version
  instead of writing a placeholder. Do not persist usernames, device serials,
  credentials, signing paths, or SDK absolute paths.

  Generate `toolchain.native-allowlist.json` from libraries that actually
  exist in the integrated API 23 NDK sysroot. It has separate exact `DT_NEEDED`
  allowlists for `goProbe`, `mihomoCore`, and `nodeAddon`. Candidate base
  entries are `libc.so`, `libdl.so`, and `libm.so`; the addon additionally
  permits the SDK-confirmed Node-API and HiLog library names plus the packaged
  real core. A candidate is included only when the installed sysroot contains
  it. Inspection fails for every undeclared `DT_NEEDED` entry even if another
  host SDK happens to provide that name.

- [ ] **Step 5: Verify installed tools**

  Run:

  ```bash
  node harmony/tools/preflight.mjs
  node --test harmony/tests/structure/api20-sdk-contract.test.mjs
  ```

  Expected: both exit `0`; preflight reports the verified integrated API 23 install and the fixed API 20 compatible project target contract.

- [ ] **Step 6: Commit the version contract**

  Commit the test, lock file, and preflight adjustment with intent line `Pin the verified HarmonyOS 6 build contract`.

### Task 3: Generate and sanitize the self-contained Stage project

**Files:**
- Create from DevEco Empty Ability template: `harmony/AppScope/app.json5`
- Create from template: `harmony/build-profile.json5`
- Create from template: `harmony/hvigorfile.ts`
- Create from template: `harmony/hvigorw`
- Create from template when provided: `harmony/hvigorw.bat`
- Create from template: `harmony/hvigor/hvigor-config.json5`
- Create from template: `harmony/oh-package.json5`
- Create from template: `harmony/entry/build-profile.json5`
- Create from template: `harmony/entry/hvigorfile.ts`
- Create from template: `harmony/entry/oh-package.json5`
- Create from template: `harmony/entry/src/main/module.json5`
- Create from template: `harmony/entry/src/main/ets/entryability/EntryAbility.ets`
- Create from template: `harmony/entry/src/main/ets/pages/Index.ets`
- Create from template: `harmony/entry/src/main/resources/base/profile/main_pages.json`
- Create from template: `harmony/entry/src/main/resources/base/element/string.json`
- Create: `harmony/tests/fixtures/required-phase0-paths.json`
- Create: `harmony/tests/structure/phase0-layout.test.mjs`
- Create: `harmony/tests/structure/signing-isolation.test.mjs`

- [ ] **Step 1: Write the failing layout and signing-isolation tests**

  `phase0-layout.test.mjs` reads `required-phase0-paths.json` and checks the Stage skeleton, the fixed `targetSdkVersion=6.1.0(23)` plus `compatibleSdkVersion=6.0.0(20)`/`runtimeOS=HarmonyOS` project contract, `entry` module, `EntryAbility`, and `pages/Index`.

  `signing-isolation.test.mjs` rejects tracked `.p12`, `.cer`, `.p7b`, `.pem`, passwords, absolute user paths, and signing material. It allows a product to name a local signing config but not to embed its secrets.

- [ ] **Step 2: Run tests to verify RED**

  Run:

  ```bash
  node --test harmony/tests/structure/phase0-layout.test.mjs
  node --test harmony/tests/structure/signing-isolation.test.mjs
  ```

  Expected: layout FAIL because the Stage project is absent;
  `signing-isolation.test.mjs` PASS against the otherwise empty Harmony tree.
  The signing test fails only when it finds tracked signing material,
  credential-like values, or machine-specific absolute paths.

- [ ] **Step 3: Generate the API 20 compatible project from DevEco**

  Create an Empty Ability, Stage model, ArkTS application at `harmony/` with:

  - bundle name `com.github.kr328.clash.harmony`;
  - module `entry`;
  - ability `EntryAbility`;
  - product `default`;
  - target SDK `6.1.0(23)` with compatible baseline `6.0.0(20)` and `runtimeOS: HarmonyOS`;
  - phone/default device type.

  Keep the generated Hvigor/plugin versions. Do not paste the old `2.4.2` sample versions or an API 12 target.

- [ ] **Step 4: Sanitize generated configuration**

  Remove generated machine-specific signing paths from tracked files. Keep actual debug signing in DevEco-managed local state or ignored `harmony/local.properties`. Confirm `harmony/` is not included from Android `settings.gradle.kts`.

- [ ] **Step 5: Verify structure and secret isolation**

  Run: `node --test harmony/tests/structure/phase0-layout.test.mjs harmony/tests/structure/signing-isolation.test.mjs`

  Expected: PASS.

  Run: `git diff --check`

  Expected: no output.

- [ ] **Step 6: Commit the Stage shell**

  Commit with intent line `Give the HarmonyOS rewrite an independent Stage application`.

### Task 4: Build, inspect, install, and launch the empty HAP

**Files:**
- Create: `harmony/tests/bin/build-hap.mjs`
- Create: `harmony/tests/bin/run-phase0-device-proof.mjs`
- Create: `harmony/tests/fixtures/phase0-device-proof.schema.json`
- Create: `harmony/tests/fixtures/phase0-device-proof.example.json`
- Create: `harmony/tests/structure/phase0-proof-contract.test.mjs`
- Create: `harmony/README.md`

- [ ] **Step 1: Write failing proof-contract tests**

  Require `schemaVersion`, `phase: 0`, `result`, toolchain versions, masked
  device identity, exact device build version, HAP SHA-256, bundle, ability,
  install result, launch result, timestamps, and structured failures.

  The only successful state is `result: "pass"` with successful build, install, and launch. Missing device/signing produces `incomplete`.

- [ ] **Step 2: Run the proof test to verify RED**

  Run: `node --test harmony/tests/structure/phase0-proof-contract.test.mjs`

  Expected: FAIL because the runner and example are absent.

- [ ] **Step 3: Implement deterministic build discovery**

  `build-hap.mjs` first discovers the generated executable wrapper and returns
  stable `WRAPPER_MISSING` when it is absent. It then runs the wrapper without
  a shell:

  ```bash
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
  ```

  It verifies exactly one intended debug HAP, computes SHA-256, and writes structured build evidence. Also run project-level `assembleApp` once to catch product configuration errors:

  ```bash
  ./hvigorw --mode project -p product=default -p buildMode=debug assembleApp
  ```

- [ ] **Step 4: Implement the always-write device runner**

  The runner executes:

  ```bash
  hdc list targets
  hdc app install -r <signed-hap>
  hdc shell aa start -a EntryAbility -b com.github.kr328.clash.harmony
  hdc shell aa force-stop com.github.kr328.clash.harmony
  ```

  Use the installed `hdc` help output to confirm exact API 20 command spelling
  before locking it. Mask the serial, record the unmasked OS build version
  reported by the device, and write a proof file on every exit path.

- [ ] **Step 5: Verify the Phase 0 gate**

  Run:

  ```bash
  node --test harmony/tests/structure/*.test.mjs
  node harmony/tests/bin/build-hap.mjs
  node harmony/tests/bin/run-phase0-device-proof.mjs --hap <actual-signed-hap>
  ```

  Expected: tests PASS; build exits `0`; a connected authorized HarmonyOS 6 phone yields `phase0-device-proof.json` with `result: "pass"`.

- [ ] **Step 6: Document exact local commands and commit**

  `harmony/README.md` records installed tool versions, non-secret setup, build output location, signing isolation, and device commands. Commit with intent line `Make the empty HarmonyOS application independently provable`.

## Chunk 2: Phase 1 — Real arm64 Go Load and Node-API Bridge

### Task 5: Build a falsifiable Go/cgo lane and a real mihomo version library

**Files:**
- Create: `harmony/core/go/probe/go.mod`
- Create: `harmony/core/go/probe/main.go`
- Create: `harmony/core/go/probe/probe_test.go`
- Create: `harmony/core/go/go.mod`
- Create: `harmony/core/go/go.sum`
- Create: `harmony/core/go/upstream.lock.json`
- Create: `harmony/core/go/cmd/cmfa_core/main.go`
- Create: `harmony/core/go/internal/version/version.go`
- Create: `harmony/tools/build-go-ohos-probe.mjs`
- Create: `harmony/tools/build-mihomo-ohos.mjs`
- Create: `harmony/tests/bin/inspect-native-lib.mjs`
- Create: `harmony/tests/structure/go-ohos-build-contract.test.mjs`

- [ ] **Step 1: Write the failing Go and build-contract tests**

  The Go probe exports exactly:

  ```c
  const char *cmfa_probe_version(void);
  int32_t cmfa_probe_add(int32_t left, int32_t right);
  ```

  The structure test requires the build helper to use discovered API 20 NDK tools, `GOOS=linux`, `GOARCH=arm64`, `CGO_ENABLED=1`, `-buildmode=c-shared`, and a custom `ohos` build tag. It must reject host clang and Android NDK paths.

- [ ] **Step 2: Run tests to verify RED**

  Run:

  ```bash
  go test ./harmony/core/go/probe/...
  node --test harmony/tests/structure/go-ohos-build-contract.test.mjs
  ```

  Expected: FAIL because the probe/build helper is absent.

- [ ] **Step 3: Implement the probe and cross-build helper**

  The helper builds into an ignored temporary directory with:

  ```bash
  GOOS=linux
  GOARCH=arm64
  CGO_ENABLED=1
  CC=<integrated-ndk>/aarch64-unknown-linux-ohos-clang
  CXX=<integrated-ndk>/aarch64-unknown-linux-ohos-clang++
  go build -tags ohos -buildmode=c-shared
  ```

  Do not set `GOOS=ohos`; stock Go rejects that pair.

- [ ] **Step 4: Inspect the ELF before packaging**

  `inspect-native-lib.mjs` invokes the integrated NDK `llvm-readelf -h -d -sW`. Assert AArch64, expected exports, legal `NEEDED` entries, and no Android libraries.

  “Legal” means an exact match against the component-specific entries in
  `harmony/toolchain.native-allowlist.json`; discovery from the current Mac or
  an Android NDK is forbidden.

- [ ] **Step 5: Pin upstream and build the smallest honest core**

  Initialize the existing mihomo gitlink for source audit, record its exact
  commit, and pin the Harmony Go module to that upstream commit without a
  relative `replace` to an Android directory. The initial real library imports
  only the upstream version package and exports `cmfa_core_version`; it does
  not claim configuration or listener support.

- [ ] **Step 6: Cross-build and inspect the real version library**

  Run:

  ```bash
  node harmony/tools/build-go-ohos-probe.mjs
  node harmony/tools/build-mihomo-ohos.mjs
  node harmony/tests/bin/inspect-native-lib.mjs --lib <actual-libcmfa_mihomo.so>
  ```

  Expected: both outputs are AArch64, the real library exports
  `cmfa_core_version`, and neither output depends on Android libraries.

- [ ] **Step 7: Enforce the compile/ELF stop rule**

  If either cross-build or ELF inspection fails, save a structured failed
  build proof at `harmony/artifacts/go-ohos-build-proof.json` and diagnose
  before Tasks 6–8. Do not introduce a stub fallback. Tasks 6–7 may build the
  adapter only after this compile gate. Task 8 is the sole versioned
  direct-link device invocation gate, and no Phase 2 task may begin until its
  fresh device proof passes. It must preserve Task 7's direct link from
  `libentry.so` to `libcmfa_mihomo.so`; `dlopen`/`dlsym` are forbidden.

- [ ] **Step 8: Commit the testable build lane**

  Commit after both ELF inspections pass, with intent line `Make the Go HarmonyOS build hypothesis directly testable`.

### Task 6: Define the minimal platform-neutral core ABI with host tests

**Files:**
- Create: `harmony/core/abi/include/cmfa_types.h`
- Create: `harmony/core/abi/include/cmfa_host.h`
- Create: `harmony/core/abi/include/cmfa_core.h`
- Create: `harmony/core/abi/src/cmfa_contract.cpp`
- Create: `harmony/tests/native/cmfa_contract_test.cpp`
- Create: `harmony/tools/test-native-host.mjs`

- [ ] **Step 1: Write failing host tests for ABI state and bounds**

  Cover null pointers, overlong strings, invalid UTF-8, calls before initialization, duplicate initialization, idempotent stop/shutdown, concurrent start rejection, event unsubscribe, and error-buffer truncation.

- [ ] **Step 2: Run the test to verify RED**

  Run: `node harmony/tools/test-native-host.mjs`

  Expected: FAIL because the ABI contract does not exist.

- [ ] **Step 3: Add the hand-written ABI**

  Use fixed-width types and caller-owned buffers. The public surface for Phases 1–2 is:

  ```c
  cmfa_status cmfa_initialize(const cmfa_host_callbacks *host, cmfa_error *error);
  cmfa_status cmfa_core_version(char *out, size_t capacity, cmfa_error *error);
  cmfa_status cmfa_validate_config(const char *path, cmfa_error *error);
  cmfa_status cmfa_load_config(const char *path, cmfa_error *error);
  cmfa_status cmfa_start_local(const cmfa_local_options *options,
                               cmfa_runtime_snapshot *snapshot,
                               cmfa_error *error);
  cmfa_status cmfa_stop(cmfa_error *error);
  cmfa_status cmfa_runtime_state(cmfa_runtime_snapshot *snapshot,
                                 cmfa_error *error);
  cmfa_status cmfa_shutdown(cmfa_error *error);
  ```

  `cmfa_host_callbacks` contains only structured log and runtime event sinks in this plan. Socket protection is deferred to Phase 4.

- [ ] **Step 4: Implement contract validation without a fake backend**

  `cmfa_contract.cpp` owns validation and state serialization, then dispatches to a registered real backend. When no backend is linked, core-dependent calls return typed `CMFA_CORE_UNAVAILABLE`; they never synthesize success or a fake version.

- [ ] **Step 5: Run host tests to verify GREEN**

  Run: `node harmony/tools/test-native-host.mjs`

  Expected: compiled tests exit `0` with all assertions passing.

- [ ] **Step 6: Commit the ABI contract**

  Commit with intent line `Keep HarmonyOS host concerns outside the mihomo core`.

### Task 7: Implement the C++ Node-API facade and ArkTS declarations

**Files:**
- Create: `harmony/entry/src/main/cpp/CMakeLists.txt`
- Create: `harmony/entry/src/main/cpp/include/cmfa_napi.h`
- Create: `harmony/entry/src/main/cpp/src/addon_init.cpp`
- Create: `harmony/entry/src/main/cpp/src/js_core_module.cpp`
- Create: `harmony/entry/src/main/cpp/src/js_async.cpp`
- Create: `harmony/entry/src/main/cpp/src/js_events.cpp`
- Create: `harmony/entry/src/main/cpp/src/js_errors.cpp`
- Create: `harmony/entry/src/main/cpp/src/js_codec.cpp`
- Create: `harmony/entry/src/main/cpp/src/napi_environment.cpp`
- Create: `harmony/entry/src/main/cpp/include/napi_environment.h`
- Create: `harmony/entry/src/main/cpp/types/libentry/Index.d.ts`
- Create: `harmony/entry/src/main/cpp/types/libentry/oh-package.json5`
- Create: `harmony/tests/native/napi_environment_test.cpp`
- Create: `harmony/tests/structure/phase1-bridge-contract.test.mjs`
- Modify: `harmony/entry/build-profile.json5`
- Modify: `harmony/entry/oh-package.json5`

- [ ] **Step 1: Write the failing bridge surface test**

  Require typed exports for:

  ```ts
  hello(): string;
  coreVersion(): Promise<string>;
  validateConfiguration(path: string): Promise<void>;
  loadConfiguration(path: string): Promise<void>;
  startLocal(options: LocalOptions): Promise<RuntimeSnapshot>;
  stopRuntime(): Promise<RuntimeSnapshot>;
  runtimeSnapshot(): RuntimeSnapshot;
  subscribe(callback: (event: CoreEvent) => void): number;
  unsubscribe(subscriptionId: number): void;
  ```

  Require a stable `CoreError` shape with code, category, message, detail, retryable, action, and non-secret context.

  Also write `napi_environment_test.cpp` first. It must fail until the
  environment owner can cancel in-flight work, abort/release callbacks, handle
  cleanup twice safely, and suppress delivery after teardown.

- [ ] **Step 2: Run the contract test to verify RED**

  Run:

  ```bash
  node --test harmony/tests/structure/phase1-bridge-contract.test.mjs
  node harmony/tools/test-native-host.mjs --case napi-environment
  ```

  Expected: both FAIL because the facade and environment owner are absent.

- [ ] **Step 3: Implement synchronous conversion and async work**

  - `addon_init.cpp` registers one module.
  - `js_codec.cpp` validates types, maximum lengths, paths, and port ranges.
  - `js_async.cpp` owns Promise work and never keeps stack/native pointers after completion.
  - `js_events.cpp` owns one thread-safe callback bridge and guarantees no callback after unsubscribe/shutdown.
  - `js_errors.cpp` maps every `cmfa_status` to the shared error taxonomy.
  - `napi_environment.cpp` registers an environment cleanup hook, marks the
    environment invalid before teardown, cancels or joins outstanding async
    work, aborts/releases every thread-safe function, releases references
    exactly once, and prevents any queued completion from touching a torn-down
    `napi_env`.

  Link only the exact addon entries in
  `harmony/toolchain.native-allowlist.json`, including the shipped Node-API
  and HiLog libraries confirmed from the integrated SDK.

- [ ] **Step 4: Verify build and static contract**

  Run:

  ```bash
  node harmony/tools/test-native-host.mjs --case napi-environment
  node --test harmony/tests/structure/phase1-bridge-contract.test.mjs
  node harmony/tests/bin/build-hap.mjs
  ```

  Expected: the native lifecycle test proves cleanup during in-flight work,
  callback unsubscribe, double cleanup, and no delivery after teardown; the
  structure test passes; the HAP contains the arm64 Node-API addon.

- [ ] **Step 5: Commit the facade**

  Commit with intent line `Expose the native core through a typed HarmonyOS boundary`.

### Task 8: Add the minimum shared contracts and Phase 1 debug proof

**Files:**
- Create: `harmony/shared/src/main/ets/core/CoreModels.ets`
- Create: `harmony/shared/src/main/ets/core/CoreErrors.ets`
- Create: `harmony/shared/src/main/ets/core/CoreService.ets`
- Create: `harmony/core/src/main/ets/CoreNativeAdapter.ets`
- Create: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Create: `harmony/entry/src/main/ets/pages/CoreDebugPage.ets`
- Modify: `harmony/entry/src/main/ets/entryability/EntryAbility.ets`
- Create: `harmony/tests/bin/run-phase1-device-proof.mjs`
- Create: `harmony/tests/fixtures/phase1-device-proof.schema.json`
- Create: `harmony/tests/fixtures/phase1-device-proof.example.json`
- Create: `harmony/tests/structure/phase1-proof-contract.test.mjs`
- Modify: `harmony/entry/src/main/resources/base/profile/main_pages.json`

- [ ] **Step 1: Write the failing Phase 1 proof test**

  `CoreService.ets` is an interface-only shared contract and never imports
  `libentry.so`. `CoreNativeAdapter.ets` is the sole concrete ArkTS owner of
  Node-API calls. `CoreComposition.ets` constructs the adapter and supplies
  the `CoreService` interface to the debug page.

  The proof schema requires:

  - `schemaVersion: "1.0.0"`, `phase: 1`, and
    `result: pass | fail | incomplete`;
  - a runner-generated `runId`, start/finish timestamps, and proof timestamp;
  - exact toolchain-lock digest and device build/API/ABI facts;
  - HAP hash, packaged addon/core native-library hashes and paths, ELF
    machines, and inspected export-list digests;
  - structured check results and failures.

  A pass additionally requires:

  - `hello()` returns the expected native value;
  - `coreVersion()` returns a non-empty version from the real Go library;
  - one Promise resolves;
  - one invalid call rejects with a typed error;
  - one event arrives;
  - no event arrives after unsubscribe;
  - native and HAP hashes are recorded.

  Validation rejects a stale or synthetic artifact unless the app echoes the
  exact Want `runId`, timestamps fall inside the runner interval, hashes match
  the just-installed HAP, the AArch64 addon still passes Task 7's exact
  Node-API ELF/dependency contract, and the packaged real core exports
  `cmfa_mihomo_core_version_cstr_v1`. The obsolete conflicting raw
  `cmfa_core_version` export is forbidden.

- [ ] **Step 2: Run the proof test to verify RED**

  Run: `node --test harmony/tests/structure/phase1-proof-contract.test.mjs`

  Expected: FAIL because the example/runner is absent.

- [ ] **Step 3: Implement the debug page and automatic self-test mode**

  The page shows bridge/core versions, last structured error, event count, and proof status. A test-only Want parameter runs the Phase 1 checks and writes a JSON result in the app sandbox. No production navigation or placeholder proxy UI is added.

- [ ] **Step 4: Implement the always-write device runner**

  Generate a cryptographically random run ID, install and start the HAP with
  that self-test Want parameter, pull the proof, merge
  toolchain/HAP/ELF/device facts, validate freshness and hashes, and save
  `harmony/artifacts/phase1-device-proof.json` on pass, fail, or incomplete.

- [ ] **Step 5: Verify the Phase 1 gate**

  Run:

  ```bash
  node --test harmony/tests/structure/*.test.mjs
  node harmony/tests/bin/run-phase1-device-proof.mjs --hap <actual-signed-hap>
  ```

  Expected: `result: "pass"` on a HarmonyOS 6 arm64 phone. A host-only or emulator run is insufficient.

- [ ] **Step 6: Commit Phase 1**

  Commit with intent line `Prove the real native bridge on a HarmonyOS 6 phone`.

## Chunk 3: Phase 2 — Real mihomo Configuration and HTTP/SOCKS Traffic

### Task 9: Pin upstream mihomo and implement version/configuration operations

**Files:**
- Modify: `harmony/core/go/go.mod`
- Modify: `harmony/core/go/go.sum`
- Modify: `harmony/core/go/upstream.lock.json`
- Create: `harmony/core/go/upstream.api-lock.json`
- Modify: `harmony/core/go/cmd/cmfa_core/main.go`
- Modify: `harmony/core/go/internal/version/version.go`
- Create: `harmony/core/go/internal/config/validate.go`
- Create: `harmony/core/go/internal/config/load.go`
- Create: `harmony/core/go/internal/events/sink.go`
- Create: `harmony/core/go/internal/runtime/lifecycle.go`
- Create: `harmony/core/go/internal/config/validate_test.go`
- Create: `harmony/core/go/internal/runtime/lifecycle_test.go`
- Create: `harmony/tests/fixtures/phase2-match-direct.yaml`
- Create: `harmony/tests/fixtures/phase2-invalid.yaml`
- Create: `harmony/tools/audit-mihomo-api.mjs`
- Modify: `harmony/tools/build-mihomo-ohos.mjs`

- [ ] **Step 1: Re-audit the pinned upstream source for the expanded import graph**

  Confirm the Task 5 pin still matches the audited source. Inspect every
  package added for configuration/runtime work for Linux build tags,
  `x/sys/unix`, netlink/nftables, Android logging, and filesystem assumptions.
  The Harmony build must still work after `harmony/` is extracted.

  `audit-mihomo-api.mjs` uses `go list -json` and `go doc` against the pinned
  module to resolve and hash the exact configuration parse/load, HTTP listener,
  SOCKS listener, connection-tracker, and shutdown symbols. It writes
  `upstream.api-lock.json` with module commit, import path, symbol, signature
  digest, constructor inputs, ownership, and required close order. HTTP starts
  from the already evidenced
  `github.com/metacubex/mihomo/listener/http.NewWithAuthenticate`; the script
  must discover and verify the pinned SOCKS counterpart rather than assuming
  its name. Missing or changed symbols fail this task before runtime code is
  written.

- [ ] **Step 2: Write failing Go tests**

  Test:

  - version comes from upstream mihomo;
  - valid `MATCH,DIRECT` YAML validates;
  - invalid YAML returns line/field detail when upstream provides it;
  - `content://` and paths outside the supplied sandbox root are rejected;
  - failed load leaves the previous loaded configuration unchanged;
  - lifecycle rejects illegal transitions.

- [ ] **Step 3: Run tests to verify RED**

  Run: `go test ./harmony/core/go/internal/...`

  Expected: FAIL because the wrapper is absent.

- [ ] **Step 4: Implement the minimum portable wrapper**

  Reuse only the exact pinned symbols recorded in
  `upstream.api-lock.json` for parsing/loading. Do not copy Android JNI/C
  bridge files. Use normal sandbox file paths, portable logging callbacks, and
  the explicit runtime state machine. Export build information containing the
  pinned commit, upstream-reported version, ABI version, and reproducible build
  ID for later package verification.

- [ ] **Step 5: Cross-build and inspect the real library**

  `build-mihomo-ohos.mjs` uses the proven Task 5 lane and emits `libcmfa_mihomo.so` plus its cgo-generated private header. The public header remains `cmfa_core.h`.

  Run:

  ```bash
  node harmony/tools/build-mihomo-ohos.mjs
  node harmony/tests/bin/inspect-native-lib.mjs --build-manifest harmony/artifacts/build-manifest.json
  ```

  Expected: AArch64 real-core exports; no Android dependency; no stub sentinel.

- [ ] **Step 6: Run Go tests and commit**

  Run: `go test ./harmony/core/go/...`

  Expected: PASS.

  Commit with intent line `Make mihomo configuration handling native to the HarmonyOS host contract`.

### Task 10: Start and stop real HTTP and SOCKS listeners with events

**Files:**
- Create: `harmony/core/go/internal/runtime/local_proxy.go`
- Create: `harmony/core/go/internal/runtime/local_proxy_test.go`
- Create: `harmony/core/go/internal/runtime/snapshot.go`
- Create: `harmony/core/go/internal/runtime/events.go`
- Modify: `harmony/core/go/cmd/cmfa_core/main.go`
- Modify: `harmony/core/abi/include/cmfa_types.h`
- Modify: `harmony/entry/src/main/cpp/src/js_core_module.cpp`
- Modify: `harmony/entry/src/main/cpp/src/js_events.cpp`

- [ ] **Step 1: Write failing local-runtime tests**

  Assert:

  - one runtime at a time;
  - HTTP and SOCKS both bind loopback;
  - actual listener addresses are returned;
  - partial bind failure closes all listeners;
  - stop is idempotent;
  - start/stop transitions emit ordered structured events;
  - failed restart retains a truthful `Error` state and diagnostic cause.

- [ ] **Step 2: Run tests to verify RED**

  Run: `go test ./harmony/core/go/internal/runtime/...`

  Expected: FAIL because local listeners are not implemented.

- [ ] **Step 3: Implement upstream-backed listeners**

  Use only the HTTP/SOCKS constructor and shutdown sequence locked by
  `upstream.api-lock.json`; a signature-digest mismatch is a build failure.
  Add the missing SOCKS path rather than wrapping the Android-only `startHttp`
  helper. Bind loopback only for Phase 2, return actual addresses, and emit
  bounded structured logs with secret redaction.

- [ ] **Step 4: Wire ABI and Node-API snapshots**

  Map `Stopped`, `Starting`, `Running`, `Stopping`, and `Error` without optimistic UI state. All cross-language strings use bounded copies and all event payloads are owned until delivery completes.

- [ ] **Step 5: Verify host behavior and cross-build**

  Run:

  ```bash
  go test -race ./harmony/core/go/internal/runtime/...
  node harmony/tools/build-mihomo-ohos.mjs
  node harmony/tests/bin/build-hap.mjs
  ```

  Expected: tests PASS and the HAP packages the inspected real library.

- [ ] **Step 6: Commit the runtime**

  Commit with intent line `Make local proxy state reflect real listener ownership`.

### Task 11: Add deterministic HTTPS probes through both listeners

**Files:**
- Create: `harmony/core/go/internal/probe/http.go`
- Create: `harmony/core/go/internal/probe/socks5.go`
- Create: `harmony/core/go/internal/probe/probe_test.go`
- Create: `harmony/tests/bin/phase2-origin.mjs`
- Create: `harmony/tests/fixtures/origin-body.txt`
- Modify: `harmony/core/go/cmd/cmfa_core/main.go`
- Modify: `harmony/core/abi/include/cmfa_core.h`
- Modify: `harmony/core/abi/include/cmfa_types.h`
- Modify: `harmony/entry/src/main/cpp/src/js_core_module.cpp`
- Modify: `harmony/entry/src/main/cpp/src/js_async.cpp`
- Modify: `harmony/entry/src/main/cpp/types/libentry/Index.d.ts`
- Modify: `harmony/shared/src/main/ets/core/CoreModels.ets`
- Modify: `harmony/shared/src/main/ets/core/CoreService.ets`
- Modify: `harmony/core/src/main/ets/CoreNativeAdapter.ets`
- Modify: `harmony/entry/src/main/ets/pages/CoreDebugPage.ets`

- [ ] **Step 1: Write failing proxy-probe tests**

  Start an HTTPS origin with a run-specific certificate and fixed body. Test HTTP CONNECT and a minimal RFC 1928 SOCKS5 client against the same origin. Require request ID echo, status 200, matching body SHA-256, TLS peer digest, byte count, timestamps, and structured errors.

- [ ] **Step 2: Run tests to verify RED**

  Run: `go test ./harmony/core/go/internal/probe/...`

  Expected: FAIL because the probe clients are absent.

- [ ] **Step 3: Implement probes without disabling TLS verification**

  Use Go standard `crypto/tls`, `crypto/x509`, `net`, and `net/http`. Pass the ephemeral test CA into the test-only probe API. Implement the small SOCKS5 no-auth handshake locally instead of adding a new dependency.

  Export a test-build-only `cmfa_probe_https` ABI accepting `probeRunId`,
  protocol, listener address, origin URL, CA PEM, and expected body hash. Its
  owned result includes the request/origin IDs, TLS peer digest, response hash,
  byte count, timestamps, client socket endpoints, and a real mihomo
  connection-tracker record. Keep the request open until the pinned upstream
  tracker reports a matching client source port, destination, and inbound type;
  record that core connection ID in the result.

- [ ] **Step 4: Carry the result through Node-API and ArkTS**

  `js_async.cpp` invokes the device-process ABI on background work and owns the
  result until conversion. `Index.d.ts`, `CoreModels.ets`, and
  `CoreService.ets` define the same structured result; `CoreNativeAdapter.ets`
  is the only native caller. `CoreDebugPage.ets` invokes both protocols in
  self-test mode and writes results into app evidence. No host-side proxy
  client is accepted by the proof runner.

- [ ] **Step 5: Implement the host origin**

  `phase2-origin.mjs` creates run-specific non-secret test certificates via the available system/OpenSSL tooling, starts on an explicitly reachable interface, echoes a request ID, serves `origin-body.txt`, and prints machine-readable connection information. Generated keys remain under ignored `harmony/artifacts/`.

- [ ] **Step 6: Verify both native probe paths on the host test harness**

  Run: `go test ./harmony/core/go/internal/probe/...`

  Expected: PASS for both HTTP and SOCKS clients with TLS verification enabled.

- [ ] **Step 7: Commit the proof transport**

  Commit with intent line `Require real HTTPS traffic before accepting the local proxy`.

### Task 12: Version the Phase 2 proof and reject fake packages

**Files:**
- Create: `harmony/tests/fixtures/phase2-device-proof.schema.json`
- Create: `harmony/tests/fixtures/phase2-device-proof.example.json`
- Create: `harmony/tests/structure/phase2-proof-schema.test.mjs`
- Create: `harmony/tests/bin/inspect-hap.mjs`
- Create: `harmony/tests/bin/run-phase2-device-proof.mjs`
- Modify: `harmony/tests/bin/inspect-native-lib.mjs`
- Modify: `harmony/entry/src/main/ets/pages/CoreDebugPage.ets`

- [ ] **Step 1: Write the failing proof and inspector tests**

  Schema `1.0.0` contains:

  - `result: pass | fail | incomplete`;
  - exact DevEco, SDK, NDK, Hvigor, Node, and hdc versions;
  - masked device model/product/build/API/ABI facts;
  - HAP, native library, fixture, and response SHA-256 values;
  - core version and actual HTTP/SOCKS listener addresses;
  - `stubDetected: false | true | null` and performed checks;
  - HTTP and SOCKS results with request IDs, origin IDs, TLS data, status, bytes, hashes, timestamps, and errors;
  - structured failures.

  A pass requires `stubDetected === false` and both probes `status === "pass"`. `null` can never pass.

  Each probe must also contain the app-process ID, runner `runId`, core
  connection ID, matching client source port, destination, and upstream
  inbound type. The origin request ID, app probe ID, and core event ID must
  correlate under the same run ID.

- [ ] **Step 2: Run the schema test to verify RED**

  Run: `node --test harmony/tests/structure/phase2-proof-schema.test.mjs`

  Expected: FAIL because schema/example/validator are absent.

- [ ] **Step 3: Implement HAP and ELF inspection**

  `inspect-hap.mjs` extracts to a unique temporary directory, enumerates native libraries, hashes the HAP and packaged core, and rejects missing or conflicting core libraries.

  `inspect-native-lib.mjs` requires AArch64, real `cmfa_*` exports, a non-empty
  upstream version, and no `ohos_mihomo_stub_build`, `fake`, or probe-backend
  sentinel. The build helper writes
  `harmony/artifacts/build-manifest.json` with the just-built core/HAP paths
  and hashes. A pass requires the packaged `libcmfa_mihomo.so` bytes to hash
  exactly the same as that just-built core, and exported build info must match
  the commit/version in `upstream.lock.json`. Stub detection is
  symbol/content/hash/provenance based, not filename-only.

- [ ] **Step 4: Implement the always-write Phase 2 runner**

  The runner:

  1. builds and inspects the HAP;
  2. starts the HTTPS origin;
  3. installs/launches the debug HAP;
  4. validates and loads the checked-in fixture;
  5. starts real listeners;
  6. sends a random run ID to the app and instructs the app-process
     Node-API/native probe to run HTTP then SOCKS through those listeners;
  7. stops the runtime;
  8. pulls app evidence;
  9. correlates origin request IDs with app probe IDs and real-core connection
     tracker IDs;
  10. verifies packaged/built core hash equality and upstream provenance;
  11. writes and validates `harmony/artifacts/phase2-device-proof.json` even
      on failure.

- [ ] **Step 5: Verify SDK-independent contracts**

  Run: `node --test harmony/tests/structure/*.test.mjs`

  Expected: PASS.

- [ ] **Step 6: Verify the real-device Phase 2 gate**

  Run:

  ```bash
  node harmony/tests/bin/run-phase2-device-proof.mjs \
    --build-manifest harmony/artifacts/build-manifest.json \
    --fixture harmony/tests/fixtures/phase2-match-direct.yaml \
    --out harmony/artifacts/phase2-device-proof.json
  ```

  Expected: `result: "pass"`, `stubDetected: false`, and both HTTPS probes pass on a HarmonyOS 6 phone.

- [ ] **Step 7: Run the complete Phase 0–2 verification**

  Run:

  ```bash
  node --test harmony/tests/structure/*.test.mjs
  go test -race ./harmony/core/go/...
  node harmony/tools/test-native-host.mjs
  node harmony/tests/bin/build-hap.mjs
  node harmony/tests/bin/inspect-hap.mjs --build-manifest harmony/artifacts/build-manifest.json
  node harmony/tests/bin/run-phase2-device-proof.mjs --build-manifest harmony/artifacts/build-manifest.json
  git diff --check
  ```

  Expected: every command exits `0`.

- [ ] **Step 8: Commit the Phase 2 evidence gate**

  Commit with intent line `Make real mihomo traffic the only Phase 2 success condition`.

### Task 13: Review Phase 0–2 and hand off only after evidence passes

**Files:**
- Modify: `harmony/README.md`
- Create: `harmony/THIRD_PARTY_NOTICES.md`
- Create: `docs/harmony/phase-0-2-verification.md`

- [ ] **Step 1: Document the reproducible build and source obligations**

  Record the upstream mihomo commit/license, exact commands, signing isolation, artifact paths, and proof schema. Do not commit generated HAPs, signing material, device serials, or local absolute paths.

- [ ] **Step 2: Request code review**

  Use `superpowers:requesting-code-review`. Require reviewers to check ABI lifetime safety, Promise/event cleanup, no Android imports, no stub fallback, secret redaction, and proof falsifiability.

- [ ] **Step 3: Apply valid review findings and rerun verification**

  Use `superpowers:receiving-code-review` before modifying code from review feedback.

- [ ] **Step 4: Verify completion claims**

  Use `superpowers:verification-before-completion`. Phase 2 is complete only when the latest command output and the latest device proof both pass.

- [ ] **Step 5: Stop at the approved boundary**

  Do not begin Phase 3 UI or Phase 4 VPN/TUN work in this plan. Write a new reviewed plan after the Phase 2 phone gate passes.
