# HarmonyOS Task 7 Native Boundary Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first typed HarmonyOS Node-API boundary that reaches the real Go/mihomo version export, reports every unimplemented core capability honestly, tears down safely, and proves the exact native bytes packaged into the Phase 1 HAP.

**Architecture:** Rename the raw Go symbol into a versioned backend-private namespace, then direct-link it through one hidden C++ adapter into the existing eight-function Task 6 contract. A per-`napi_env` owner gates Promise/event delivery and drains native work before shutdown. A separate Phase 1 build orchestrator records fresh raw, pre-package, and HAP-extracted SHA-256 evidence without changing the Phase 0 proof lane.

**Tech Stack:** Go 1.26 `c-shared`; C11/C++17; HarmonyOS 6/API 20 Node-API and HiLog; CMake/Hvigor; ArkTS declaration files; Node.js built-in test runner, `crypto`, and `/usr/bin/unzip`.

---

## Delivery boundaries

- Work only in `harmony/**` plus this plan. Do not modify Android, JNI, NDK, Gradle application modules, or Android release metadata.
- Keep `harmony/core/abi/include/cmfa_core.h` at exactly eight app-facing functions. Do not rename its `cmfa_core_version(char *, size_t, cmfa_error *)` entry.
- Do not add a root `go.work`, a relative Go `replace`, a new package dependency, `dlopen`, `dlsym`, `libdl.so`, a second contract DSO, or fake/stub success paths.
- Generated `.so`, cgo headers, HAPs, proof/manifest JSON, caches, and signing material stay ignored and untracked.
- Task 7 may prove build and byte provenance. A Phase 1 device pass remains forbidden until Task 8 runs a fresh signed HAP on a HarmonyOS 6 arm64 target.
- Apply @superpowers:test-driven-development to every implementation task. Run the stated RED command before production edits, then the stated GREEN and regression commands.

## File responsibility map

| File | Single responsibility |
| --- | --- |
| `harmony/core/go/cmd/cmfa_core/main.go` | Own the one versioned raw Go export. |
| `harmony/tests/bin/inspect-native-lib.mjs` | Enforce component-specific AArch64 export and exact `DT_NEEDED` contracts. |
| `harmony/entry/src/main/cpp/include/cmfa_mihomo_backend.h` | Expose only hidden adapter register/unregister operations to addon initialization. |
| `harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp` | Be the only production unit that sees both the raw Go declaration and Task 6 hidden backend seam. |
| `harmony/entry/src/main/cpp/include/napi_environment.h` | Declare the testable per-environment close/drain/release owner with opaque resource operations. |
| `harmony/entry/src/main/cpp/src/napi_environment.cpp` | Implement teardown ordering and exactly-once resource release without importing HarmonyOS APIs into host tests. |
| `harmony/entry/src/main/cpp/include/cmfa_napi.h` | Share the addon state and focused codec/error/async/event entry declarations. |
| `harmony/entry/src/main/cpp/src/js_codec.cpp` | Convert and validate JS values, options, snapshots, and copied events. |
| `harmony/entry/src/main/cpp/src/js_errors.cpp` | Map every `cmfa_status`/`napi_status` into the stable non-secret `CoreError` shape. |
| `harmony/entry/src/main/cpp/src/js_async.cpp` | Run Promise operations on owned native workers and return results through guarded thread-safe functions. |
| `harmony/entry/src/main/cpp/src/js_events.cpp` | Own subscriptions, copied native events, initial truthful snapshot delivery, and unsubscribe. |
| `harmony/entry/src/main/cpp/src/js_core_module.cpp` | Bind the typed JS functions to codec, async, event, and contract operations. |
| `harmony/entry/src/main/cpp/src/addon_init.cpp` | Register backend, initialize Task 6, publish exports, and install environment cleanup in that order. |
| `harmony/entry/src/main/cpp/CMakeLists.txt` | Build one hidden `libentry.so` and direct-link the fresh imported `libcmfa_mihomo.so`. |
| `harmony/entry/src/main/cpp/types/libentry/*` | Declare the ArkTS/TypeScript surface consumed as `libentry.so`. |
| `harmony/tools/test-native-host.mjs` | Strictly select and compile the contract, backend, or environment host test case. |
| `harmony/toolchain.requirements.json` | Declare the installed native CMake executable separately from the CMake toolchain file. |
| `harmony/tools/lib/toolchain.mjs` | Resolve and executable-check the native CMake binary without persisting its absolute path. |
| `harmony/tests/structure/toolchain-discovery.test.mjs` | Lock native CMake binary discovery and missing/non-executable failures. |
| `harmony/tools/lib/native-provenance.mjs` | Hash files/HAP entries, enforce unique archive paths, and validate a Phase 1 native manifest. |
| `harmony/tests/bin/build-phase1-native.mjs` | Orchestrate one fresh Go → addon → HAP run and always persist sanitized evidence. |
| `harmony/tests/structure/phase1-bridge-contract.test.mjs` | Lock source layout, typed surface, direct-link rules, visibility, and build configuration. |
| `harmony/tests/structure/phase1-native-build-contract.test.mjs` | Lock freshness, hash equality, archive uniqueness, signing, and manifest result semantics. |

## Chunk 1: Remove the raw Go/app ABI symbol collision

### Task 1: Rename and harden the real Go export

**Files:**
- Modify: `harmony/core/go/cmd/cmfa_core/main.go:23-30`
- Modify: `harmony/tools/build-go-ohos-probe.mjs:29-36`
- Modify: `harmony/tools/build-mihomo-ohos.mjs:18-26`
- Modify: `harmony/tests/bin/inspect-native-lib.mjs:11-24,202-245`
- Modify: `harmony/tests/structure/go-ohos-build-contract.test.mjs`

- [ ] **Step 1: Add failing source and ELF contract assertions**

Add one focused source test before changing production expectations:

```js
const coreMainPath = new URL('../../core/go/cmd/cmfa_core/main.go', import.meta.url);
const RAW_VERSION_EXPORT = 'cmfa_mihomo_core_version_cstr_v1';

test('Task 7 gives the real Go version getter one backend-private export', async () => {
  const source = await fs.readFile(coreMainPath, 'utf8');
  assert.match(source, /\/\/export cmfa_mihomo_core_version_cstr_v1\nfunc cmfa_mihomo_core_version_cstr_v1\(\) \*C\.char/u);
  assert.doesNotMatch(source, /\/\/export cmfa_core_version(?:\s|$)/u);
});
```

Update the existing core helper fixtures to return `exportedSymbols: [RAW_VERSION_EXPORT]`. Add one test named exactly `Task 7 mihomo ELF rejects conflicting, sentinel, and libdl exports`; its synthetic `llvm-readelf -sW`/`-d` cases prove:

```js
assert.equal(result.result, 'pass');
assert.deepEqual(result.exportedSymbols.filter((name) => name.startsWith('cmfa_')), [RAW_VERSION_EXPORT]);

assert.ok(oldNameResult.failures.some((entry) =>
  entry.code === 'EXPORT_FORBIDDEN' && entry.detail === 'cmfa_core_version'));
assert.ok(extraCmfaResult.failures.some((entry) => entry.code === 'EXPORT_SET_MISMATCH'));
assert.ok(sentinelResult.failures.some((entry) => entry.code === 'EXPORT_SENTINEL_FORBIDDEN'));
assert.ok(libdlResult.failures.some((entry) => entry.code === 'LIBDL_FORBIDDEN'));
```

Sentinel matching applies only to exported symbol names and rejects case-insensitive `test`, `fake`, or `stub`; it must not scan proof fixture prose.

- [ ] **Step 2: Run the focused tests and record RED**

Run:

```bash
node --test --test-name-pattern='backend-private export|mihomo ELF' harmony/tests/structure/go-ohos-build-contract.test.mjs
```

Expected: two matching tests run and FAIL: the source test sees the old `//export cmfa_core_version`, while the ELF test sees missing hardened inspector failures. A `1..0` zero-match run is itself invalid RED evidence.

- [ ] **Step 3: Rename only the raw Go export and its build expectations**

Use this exact Go declaration; do not bulk-replace the app-facing Task 6 name:

```go
//export cmfa_mihomo_core_version_cstr_v1
func cmfa_mihomo_core_version_cstr_v1() *C.char {
	coreVersionOnce.Do(func() {
		coreVersionCStr = C.CString(goCoreVersion())
	})

	return coreVersionCStr
}
```

Set both `COMPONENT_CONFIG.mihomoCore.expectedExports` and `CORE_COMPONENT_CONFIG.expectedExports` to:

```js
['cmfa_mihomo_core_version_cstr_v1']
```

In `inspect-native-lib.mjs`:

```js
const REQUIRED_EXPORTS = {
  probe: ['cmfa_probe_add', 'cmfa_probe_version'],
  mihomoCore: ['cmfa_mihomo_core_version_cstr_v1'],
  nodeAddon: []
};
const FORBIDDEN_EXPORT_SENTINEL = /(?:test|fake|stub)/iu;
```

For `mihomoCore`, require the sorted `cmfa_*` subset to equal `requiredExports` exactly, add explicit `EXPORT_FORBIDDEN` for `cmfa_core_version`, add `EXPORT_SENTINEL_FORBIDDEN` when a public symbol matches the sentinel, and add `LIBDL_FORBIDDEN` whenever `neededLibraries` contains `libdl.so`. Preserve the probe rules and existing Android rejection.

- [ ] **Step 4: Run source/fixture tests to verify GREEN**

Run:

```bash
gofmt -w harmony/core/go/cmd/cmfa_core/main.go
node --test harmony/tests/structure/go-ohos-build-contract.test.mjs
```

Expected: all Task 5/Task 7 Go build-contract tests pass; fixtures no longer expect raw `cmfa_core_version`.

- [ ] **Step 5: Verify the Go package and a fresh OHOS ELF**

Run:

```bash
cd harmony/core/go && GOCACHE=/private/tmp/cmfa-go-cache-task5 GOMODCACHE=/private/tmp/cmfa-go-mod-cache-task5 go test ./...
cd ../../.. && GOCACHE=/private/tmp/cmfa-go-cache-task5 GOMODCACHE=/private/tmp/cmfa-go-mod-cache-task5 node harmony/tools/build-mihomo-ohos.mjs
node harmony/tests/bin/inspect-native-lib.mjs --component mihomoCore --lib harmony/artifacts/libcmfa_mihomo.so
```

Expected: Go tests pass; the build proof is `pass`; the inspector reports AArch64, only `cmfa_mihomo_core_version_cstr_v1` in its `cmfa_*` export subset, exact allowed dependencies, no sentinel, and no `libdl.so`.

- [ ] **Step 6: Confirm generated artifacts remain ignored**

Run:

```bash
git status --short --ignored harmony/artifacts
git ls-files harmony/artifacts
```

Expected: generated `.so`, `.h`, and proof files appear with `!!`; only `harmony/artifacts/.gitkeep` is tracked.

- [ ] **Step 7: Commit the collision removal**

```bash
git add harmony/core/go/cmd/cmfa_core/main.go harmony/tools/build-go-ohos-probe.mjs harmony/tools/build-mihomo-ohos.mjs harmony/tests/bin/inspect-native-lib.mjs harmony/tests/structure/go-ohos-build-contract.test.mjs
git commit -m "Keep the raw mihomo export out of the app ABI" -m $'The real Go library needs a linkable version getter, but its old name collided with the stable eight-function host contract. Give the raw function a versioned backend-private name and make ELF inspection reject regressions.\n\nConstraint: Preserve the app-facing cmfa_core_version signature and avoid libdl\nRejected: Resolve the collision through dlopen/dlsym | it expands the dependency and runtime failure surface\nConfidence: high\nScope-risk: narrow\nDirective: New raw Go exports must stay versioned and behind the hidden backend adapter\nTested: Go tests, Task 5 structure tests, fresh OHOS c-shared build, llvm-readelf inspection\nNot-tested: HarmonyOS device loading (Task 8 gate)'
```

## Chunk 2: Register a truthful hidden mihomo backend

### Task 2: Implement the direct-link backend adapter and strict host cases

**Files:**
- Create: `harmony/entry/src/main/cpp/include/cmfa_mihomo_backend.h`
- Create: `harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp`
- Create: `harmony/tests/native/cmfa_mihomo_backend_test.cpp`
- Create: `harmony/tests/structure/phase1-bridge-contract.test.mjs`
- Modify: `harmony/tools/test-native-host.mjs`

- [ ] **Step 1: Write the failing adapter and runner tests**

Create `cmfa_mihomo_backend_test.cpp` with a link-time stand-in for only the raw Go function:

```cpp
namespace {
char *g_raw_version = nullptr;
}

extern "C" char *cmfa_mihomo_core_version_cstr_v1(void) {
  return g_raw_version;
}
```

The test calls the adapter through the real Task 6 public contract, not by copying its implementation. Cover this table:

| Case | Expected status/result |
| --- | --- |
| first register → initialize → raw `"v1.19.29"` | `CMFA_OK`, exact caller-owned version |
| second register before initialize | `CMFA_INVALID_STATE` |
| register/unregister while initialized | `CMFA_INVALID_STATE` |
| null raw pointer | `CMFA_BACKEND_ERROR`, output starts with NUL |
| empty raw string | `CMFA_BACKEND_ERROR`, output starts with NUL |
| guard-page-backed 256 non-NUL bytes | child exits normally with `CMFA_BACKEND_ERROR`; byte 257 is inaccessible |
| valid 255-byte raw value, caller capacity 255 | `CMFA_BUFFER_TOO_SMALL`, output starts with NUL |
| validate/load/start | `CMFA_CORE_UNAVAILABLE`; start never returns RUNNING or binds a listener |
| runtime state | `CMFA_OK`, `STOPPED`, empty path, port `0` |
| stop with no runtime | idempotent `CMFA_OK` |
| shutdown then unregister twice | both cleanup paths are safe; no retained host bridge |

Use the existing `cmfa_error` caller buffer and assert its status/message are typed. Mirror the existing Task 6 `GuardPageRegion`/child-process pattern: allocate two pages, protect the second with `PROT_NONE`, point `g_raw_version` at exactly the final 256 bytes of the first page, fill them with non-NUL bytes, and invoke `cmfa_core_version` in the child. A correct adapter returns `CMFA_BACKEND_ERROR` and exits `0`; touching byte 257 terminates the child and fails the parent assertion. Keep the ASan case as a second, independent check.

Add the first bridge structure tests:

```js
test('Task 7 keeps the raw Go declaration inside the hidden adapter only', async () => {
  const cppRoot = new URL('../../entry/src/main/cpp/', import.meta.url);
  const sourceRoot = new URL('src/', cppRoot);
  const sourceNames = (await fs.readdir(sourceRoot))
    .filter((name) => name.endsWith('.cpp'))
    .sort();
  const sources = new Map(await Promise.all(sourceNames.map(async (name) => [
    name,
    await fs.readFile(new URL(name, sourceRoot), 'utf8')
  ])));

  assert.deepEqual(
    [...sources].filter(([, raw]) => raw.includes('cmfa_mihomo_core_version_cstr_v1')).map(([name]) => name),
    ['cmfa_mihomo_backend.cpp']
  );
  assert.deepEqual(
    [...sources].filter(([, raw]) => raw.includes('CMFA_INTERNAL_BACKEND_API')).map(([name]) => name),
    ['cmfa_mihomo_backend.cpp']
  );

  const headerRoot = new URL('include/', cppRoot);
  const headerNames = (await fs.readdir(headerRoot)).filter((name) => name.endsWith('.h')).sort();
  const headers = await Promise.all(headerNames.map((name) => fs.readFile(new URL(name, headerRoot), 'utf8')));
  const productionText = [...headers, ...sources.values()].join('\n');
  assert.doesNotMatch(productionText, /\b(?:dlopen|dlsym|libdl(?:\.so)?)\b/u);
});

test('Task 7 host runner accepts only explicit native cases', async () => {
  const { parseCliArguments } = await import(new URL('../../tools/test-native-host.mjs', import.meta.url));
  assert.deepEqual(parseCliArguments([]), { caseName: 'contract' });
  for (const caseName of ['contract', 'mihomo-backend', 'napi-environment']) {
    assert.deepEqual(parseCliArguments(['--case', caseName]), { caseName });
  }
  for (const argv of [['--case'], ['--case', 'unknown'], ['--case', 'contract', 'extra'], ['contract']]) {
    assert.throws(() => parseCliArguments(argv), (error) => error?.code === 'ARGUMENT_INVALID');
  }
});
```

Exporting `parseCliArguments` requires guarding the runner's `main()` with the repository's complete existing pattern:

```js
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const exitCode = await runCli();
  process.exitCode = exitCode;
}
```

Importing the runner in the structure test must never compile or run a native case.

- [ ] **Step 2: Run both test entry points and record RED**

Run:

```bash
node --test --test-name-pattern='raw Go declaration|native cases' harmony/tests/structure/phase1-bridge-contract.test.mjs
clang++ -std=c++17 -Wall -Wextra -Werror -pthread -DCMFA_INTERNAL_BACKEND_API=1 -I harmony/core/abi/include -I harmony/entry/src/main/cpp/include harmony/core/abi/src/cmfa_contract.cpp harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp harmony/tests/native/cmfa_mihomo_backend_test.cpp -o /tmp/cmfa_mihomo_backend_red
```

Expected: both named structure assertions run and FAIL because the adapter/strict dispatch are absent; the direct host compile exits non-zero because the production adapter source/header are absent. A missing test file or `1..0` is not acceptable RED. Do not use `node harmony/tools/test-native-host.mjs --case mihomo-backend` as pre-change RED: the current runner ignores arguments and would misleadingly run the contract suite successfully.

- [ ] **Step 3: Add the minimal hidden adapter surface**

`cmfa_mihomo_backend.h` must not expose `cmfa_backend_api` or the raw Go declaration:

```cpp
#ifndef CMFA_MIHOMO_BACKEND_H
#define CMFA_MIHOMO_BACKEND_H

#include "cmfa_types.h"

namespace cmfa {

#if defined(__GNUC__) || defined(__clang__)
#define CMFA_MIHOMO_HIDDEN __attribute__((visibility("hidden")))
#else
#define CMFA_MIHOMO_HIDDEN
#endif

CMFA_MIHOMO_HIDDEN cmfa_status register_mihomo_backend(cmfa_error *error);
CMFA_MIHOMO_HIDDEN cmfa_status unregister_mihomo_backend(cmfa_error *error);

} // namespace cmfa

#endif
```

Only `cmfa_mihomo_backend.cpp` begins with the internal seam definition and raw declaration:

```cpp
#if !defined(CMFA_INTERNAL_BACKEND_API)
#define CMFA_INTERNAL_BACKEND_API 1
#endif
#include "cmfa_mihomo_backend.h"
#include "cmfa_host.h"

extern "C" char *cmfa_mihomo_core_version_cstr_v1(void);

namespace {
constexpr size_t CMFA_MIHOMO_VERSION_MAX_BYTES = 256;
}
```

Implement a mutex-protected singleton adapter state containing:

```cpp
struct MihomoBackendState {
  bool registered = false;
  bool attached = false;
  cmfa_backend_host host{};
};
```

The fixed vtable behavior is:

```text
attach_host      -> copy the complete cmfa_backend_host into state; CMFA_OK
core_version     -> call the raw Go export, bounded memchr(..., 256), then copy
validate_config  -> CMFA_CORE_UNAVAILABLE
load_config      -> CMFA_CORE_UNAVAILABLE
start_local      -> zero STOPPED snapshot, then CMFA_CORE_UNAVAILABLE
runtime_state    -> caller-owned STOPPED/empty-path/port-0 snapshot; CMFA_OK
stop             -> CMFA_OK
shutdown         -> clear copied host state; CMFA_OK
```

For `core_version`, validate malformed backend output before caller capacity:

```cpp
const char *raw = cmfa_mihomo_core_version_cstr_v1();
if (raw == nullptr) {
  out[0] = '\0';
  return fail(error, CMFA_BACKEND_ERROR, "mihomo version is null");
}
const void *terminator = std::memchr(raw, '\0', CMFA_MIHOMO_VERSION_MAX_BYTES);
if (terminator == nullptr || terminator == raw) {
  out[0] = '\0';
  return fail(error, CMFA_BACKEND_ERROR, "mihomo version is malformed");
}
const size_t length = static_cast<const char *>(terminator) - raw;
if (capacity < length + 1) {
  out[0] = '\0';
  return fail(error, CMFA_BUFFER_TOO_SMALL, "version output buffer is too small");
}
std::memcpy(out, raw, length + 1);
```

`register_mihomo_backend` rejects its own duplicate with `CMFA_INVALID_STATE`, calls `cmfa_internal_register_backend(&vtable, error)`, and marks `registered` only on success. `unregister_mihomo_backend` is idempotent after a successful unregister; if Task 6 rejects it while initialized, preserve that status and keep `registered = true`.

- [ ] **Step 4: Refactor the host runner into strict case data**

Keep existing helper functions, header checks, and production test-hook check. Replace only the single hard-coded compile branch with:

```js
const CASES = new Map([
  ['contract', {
    sources: [CONTRACT_SOURCE, CONTRACT_TEST_SOURCE],
    defines: ['CMFA_INTERNAL_BACKEND_API=1', 'CMFA_CONTRACT_TESTING=1'],
    prefix: 'cmfa-contract-test-'
  }],
  ['mihomo-backend', {
    sources: [CONTRACT_SOURCE, MIHOMO_BACKEND_SOURCE, MIHOMO_BACKEND_TEST_SOURCE],
    defines: ['CMFA_INTERNAL_BACKEND_API=1'],
    prefix: 'cmfa-mihomo-backend-test-'
  }],
  ['napi-environment', {
    sources: [NAPI_ENVIRONMENT_SOURCE, NAPI_ENVIRONMENT_TEST_SOURCE],
    defines: [],
    prefix: 'cmfa-napi-environment-test-'
  }]
]);
```

Strict parsing accepts only `[]` or `['--case', name]`:

```js
export function parseCliArguments(argv = process.argv.slice(2)) {
  if (argv.length === 0) return { caseName: 'contract' };
  if (argv.length !== 2 || argv[0] !== '--case' || !CASES.has(argv[1])) {
    throw Object.assign(new Error([
      'Usage:',
      '  node harmony/tools/test-native-host.mjs',
      '  node harmony/tools/test-native-host.mjs --case contract',
      '  node harmony/tools/test-native-host.mjs --case mihomo-backend',
      '  node harmony/tools/test-native-host.mjs --case napi-environment'
    ].join('\n')), {
      code: 'ARGUMENT_INVALID'
    });
  }
  return { caseName: argv[1] };
}
```

Do not accept positional aliases. Missing, unknown, or extra case arguments print `ARGUMENT_INVALID`, set exit code `2`, and never fall through to the contract suite. `napi-environment` is recognized now but remains RED until Chunk 3 creates its sources.

- [ ] **Step 5: Run adapter and contract tests to verify GREEN**

Run:

```bash
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs
node harmony/tools/test-native-host.mjs --case contract
node --test harmony/tests/structure/phase1-bridge-contract.test.mjs
node harmony/tools/test-native-host.mjs --case
node harmony/tools/test-native-host.mjs --case unknown
node harmony/tools/test-native-host.mjs --case contract extra
node harmony/tools/test-native-host.mjs contract
```

Expected: the first four commands pass; both default and explicit contract runs report the existing 24 tests. Each of the final four negative CLI commands exits exactly `2`, prints `ARGUMENT_INVALID` plus the exact five-line usage text shown in Step 4, and does not compile a native test.

- [ ] **Step 6: Run memory and race checks**

Compile the same backend source/test list with:

```bash
clang++ -std=c++17 -Wall -Wextra -Werror -pthread -fsanitize=address,undefined -fno-omit-frame-pointer -DCMFA_INTERNAL_BACKEND_API=1 -I harmony/core/abi/include -I harmony/entry/src/main/cpp/include harmony/core/abi/src/cmfa_contract.cpp harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp harmony/tests/native/cmfa_mihomo_backend_test.cpp -o /tmp/cmfa_mihomo_backend_asan
ASAN_OPTIONS=detect_leaks=0 /tmp/cmfa_mihomo_backend_asan
clang++ -std=c++17 -Wall -Wextra -Werror -pthread -fsanitize=thread -DCMFA_INTERNAL_BACKEND_API=1 -I harmony/core/abi/include -I harmony/entry/src/main/cpp/include harmony/core/abi/src/cmfa_contract.cpp harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp harmony/tests/native/cmfa_mihomo_backend_test.cpp -o /tmp/cmfa_mihomo_backend_tsan
/tmp/cmfa_mihomo_backend_tsan
```

Expected: ASan/UBSan and TSan exit `0`; the 256-byte case produces no over-read; register/attach/shutdown state has no data race.

- [ ] **Step 7: Commit the hidden backend adapter**

```bash
git add harmony/entry/src/main/cpp/include/cmfa_mihomo_backend.h harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp harmony/tests/native/cmfa_mihomo_backend_test.cpp harmony/tests/structure/phase1-bridge-contract.test.mjs harmony/tools/test-native-host.mjs
git commit -m "Route the host contract through the real mihomo boundary" -m $'The stable HarmonyOS ABI needs one explicit path to the real Go library without exposing backend details or pretending unsupported operations work. Add a hidden direct-link adapter and make every Phase 1 hook truthful.\n\nConstraint: Raw version scans at most 256 bytes and unsupported runtime operations stay unavailable\nRejected: Register an incomplete vtable | Task 6 requires all lifecycle hooks and partial success would be ambiguous\nConfidence: high\nScope-risk: moderate\nDirective: Extend this adapter in Task 9; do not bypass it from Node-API code\nTested: backend host suite, 24-test contract regression, structure tests, ASan/UBSan, TSan\nNot-tested: real OHOS DSO link (Chunk 4) and device loading (Task 8)'
```

## Chunk 3: Own and drain one Node-API environment

### Task 3: Implement the host-testable environment teardown state machine

**Dependency:** Complete and commit Chunk 2 first. This task modifies the strict runner and bridge test file created there; it is not independently startable from the Task 6-only baseline.

**Files:**
- Create: `harmony/entry/src/main/cpp/include/napi_environment.h`
- Create: `harmony/entry/src/main/cpp/src/napi_environment.cpp`
- Create: `harmony/tests/native/napi_environment_test.cpp`
- Modify: `harmony/tests/structure/phase1-bridge-contract.test.mjs`
- Modify: `harmony/tools/test-native-host.mjs`

- [ ] **Step 1: Write failing lifecycle and concurrency tests**

Define fakes whose callbacks append exact operation names to a synchronized vector and increment atomic counters. The host test must cover:

| Case | Assertion |
| --- | --- |
| activate once | owner becomes deliverable; second activate fails |
| duplicate async/delivery/reference handle | rejected without taking caller ownership |
| normal completion/removal | each resource releases once and disappears from counts |
| cleanup start race with registration | delivery gate becomes false first; late registration fails |
| cleanup race with normal release | normal release returns `CLAIMED_BY_CLEANUP`; caller never frees the handle; owner releases once |
| blocking in-flight work | cleanup calls cancel, waits in join, and returns only after the worker is released |
| delivery teardown | `abort` occurs before `release`, exactly once |
| reference teardown | release occurs exactly once |
| lifecycle teardown | resource drain precedes `shutdown`, which precedes `unregister_backend` |
| second concurrent or sequential cleanup | waits for/returns the cached first result; no callback repeats |
| shutdown/unregister failure | both are attempted and their separate typed statuses remain in `CleanupResult` |
| post-cleanup delivery | `can_deliver()` remains false and no fake JS delivery counter changes |

The expected first-cleanup trace is exact:

```cpp
const std::vector<std::string> expected{
    "async.cancel",
    "async.join",
    "delivery.abort",
    "delivery.release",
    "reference.release",
    "async.release",
    "core.shutdown",
    "backend.unregister",
};
CHECK(trace == expected);
```

Use a condition variable inside the fake async resource so the test can prove cleanup is blocked in `join`, rather than relying on sleeps.

- [ ] **Step 2: Run the environment case and record RED**

Run:

```bash
clang++ -std=c++17 -Wall -Wextra -Werror -pthread -I harmony/core/abi/include -I harmony/entry/src/main/cpp/include harmony/entry/src/main/cpp/src/napi_environment.cpp harmony/tests/native/napi_environment_test.cpp -o /tmp/cmfa_napi_environment_red
node harmony/tools/test-native-host.mjs --case napi-environment
```

Expected: the direct compile fails because `napi_environment.h/.cpp` are not implemented; the strict runner recognizes the case but exits non-zero for the same missing sources. Do not accept the old behavior where the argument is ignored and the 24 contract tests run.

- [ ] **Step 3: Declare an opaque, SDK-independent ownership interface**

`napi_environment.h` includes only C++ standard headers plus `cmfa_types.h`; it must not include `napi/native_api.h`, `node_api.h`, or `ace_napi.h`.

```cpp
namespace cmfa::napi {

struct AsyncWorkRegistration {
  void *handle;
  void (*request_cancel)(void *handle);
  void (*join)(void *handle);
  void (*release)(void *handle);
};

struct DeliveryRegistration {
  void *handle;
  void (*abort)(void *handle);
  void (*release)(void *handle);
};

struct ReferenceRegistration {
  void *handle;
  void (*release)(void *handle);
};

struct LifecycleOperations {
  void *context;
  cmfa_status (*shutdown)(void *context, cmfa_error *error);
  cmfa_status (*unregister_backend)(void *context, cmfa_error *error);
};

struct CleanupResult {
  bool already_cleaned;
  cmfa_status shutdown_status;
  cmfa_status unregister_status;
};

enum class ReleaseResult {
  RELEASED,
  CLAIMED_BY_CLEANUP,
  NOT_REGISTERED
};

class NapiEnvironmentOwner final {
public:
  explicit NapiEnvironmentOwner(LifecycleOperations lifecycle);
  NapiEnvironmentOwner(const NapiEnvironmentOwner &) = delete;
  NapiEnvironmentOwner &operator=(const NapiEnvironmentOwner &) = delete;
  ~NapiEnvironmentOwner();

  bool activate();
  bool can_deliver() const;
  bool try_add_async(AsyncWorkRegistration registration);
  ReleaseResult finish_async(void *handle);
  bool try_add_delivery(DeliveryRegistration registration);
  ReleaseResult release_delivery(void *handle, bool abort);
  bool try_add_reference(ReferenceRegistration registration);
  ReleaseResult release_reference(void *handle);
  CleanupResult cleanup();

  size_t async_count() const;
  size_t delivery_count() const;
  size_t reference_count() const;
};

} // namespace cmfa::napi
```

Every registration requires a non-null unique handle and all required function pointers. Registration is allowed in `CREATED` and `ACTIVE`; it is rejected in `CLOSING` and `CLEANED`. `activate()` performs only `CREATED -> ACTIVE`; it enables delivery but does not change ownership of already registered setup resources.

A failed `try_add_*` does not call or retain the supplied operations; the caller still owns the resource. After `try_add_*` returns `true`, ownership transfers permanently to `NapiEnvironmentOwner`: the caller must never directly free that handle again. A later normal release returns:

```text
RELEASED           -> this call removed and released the owner-held resource
CLAIMED_BY_CLEANUP -> cleanup already moved it into its drain set and will release it
NOT_REGISTERED     -> it was never owner-held or was already released
```

None of these return values transfers ownership back to the caller.

- [ ] **Step 4: Implement close-first, drain-second cleanup**

Use one mutex, condition variable, lifecycle state enum (`CREATED`, `ACTIVE`, `CLOSING`, `CLEANED`), three maps keyed by handle, and a retained set of handles claimed by cleanup. `cleanup()` follows this algorithm:

```text
1. Under lock, ACTIVE/CREATED -> CLOSING, so can_deliver becomes false.
2. Add every moved handle to the claimed-by-cleanup set, move all registered resources to local vectors, and release the lock.
3. request_cancel every async resource.
4. join every async resource.
5. abort then release every delivery resource.
6. release every reference resource.
7. release every async resource.
8. call lifecycle.shutdown, then lifecycle.unregister_backend even if shutdown failed.
9. Under lock, cache both statuses, set CLEANED, notify concurrent cleanup callers.
```

If another thread sees `CLOSING`, it waits on the condition variable for `CLEANED` and returns the cached statuses with `already_cleaned = true`. A `CREATED` owner may clean up partial addon initialization safely. The destructor calls `cleanup()` and therefore shares the same idempotence path.

Normal `finish_async`, `release_delivery`, and `release_reference` remove one resource under lock, then invoke its release operations outside the lock and return `RELEASED`. A handle in the claimed set returns `CLAIMED_BY_CLEANUP` without touching it; every other missing handle returns `NOT_REGISTERED`. `release_delivery(handle, true)` performs abort before release. None of these functions calls an external operation while holding the owner mutex.

- [ ] **Step 5: Add structure assertions and verify GREEN**

Extend `phase1-bridge-contract.test.mjs`:

```js
test('Task 7 environment ownership is host-testable and SDK-opaque', async () => {
  const header = await fs.readFile(
    new URL('../../entry/src/main/cpp/include/napi_environment.h', import.meta.url),
    'utf8'
  );
  assert.match(header, /class NapiEnvironmentOwner final/u);
  assert.match(header, /CleanupResult cleanup\(\);/u);
  assert.doesNotMatch(header, /(?:napi\/native_api|node_api|ace_napi)\.h/u);
});
```

Run:

```bash
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case contract
node --test harmony/tests/structure/phase1-bridge-contract.test.mjs
```

Expected: the environment concurrency suite passes; backend and 24-test contract regressions pass; structure assertions pass.

- [ ] **Step 6: Run sanitizer and race verification**

Run:

```bash
clang++ -std=c++17 -Wall -Wextra -Werror -pthread -fsanitize=address,undefined -fno-omit-frame-pointer -I harmony/core/abi/include -I harmony/entry/src/main/cpp/include harmony/entry/src/main/cpp/src/napi_environment.cpp harmony/tests/native/napi_environment_test.cpp -o /tmp/cmfa_napi_environment_asan
ASAN_OPTIONS=detect_leaks=0 /tmp/cmfa_napi_environment_asan
clang++ -std=c++17 -Wall -Wextra -Werror -pthread -fsanitize=thread -I harmony/core/abi/include -I harmony/entry/src/main/cpp/include harmony/entry/src/main/cpp/src/napi_environment.cpp harmony/tests/native/napi_environment_test.cpp -o /tmp/cmfa_napi_environment_tsan
/tmp/cmfa_napi_environment_tsan
```

Expected: both binaries exit `0`; concurrent cleanup/registration and exactly-once release produce no race, deadlock, leak, or duplicate callback.

- [ ] **Step 7: Commit the environment owner**

```bash
git add harmony/entry/src/main/cpp/include/napi_environment.h harmony/entry/src/main/cpp/src/napi_environment.cpp harmony/tests/native/napi_environment_test.cpp harmony/tests/structure/phase1-bridge-contract.test.mjs harmony/tools/test-native-host.mjs
git commit -m "Prevent native work from outliving its ArkTS environment" -m $'Promises and event callbacks cannot retain a torn-down napi_env, so Task 7 needs one explicit owner that closes delivery before draining native resources. Make teardown ordered, idempotent, and host-testable without loading arm64 SDK libraries.

Constraint: No queued completion or callback may touch napi_env after cleanup begins
Rejected: Let individual bindings clean themselves independently | cross-resource ordering and exactly-once release would be unprovable
Confidence: high
Scope-risk: moderate
Directive: All Task 7 async work, thread-safe functions, and references must register with this owner
Tested: native lifecycle suite, contract/backend regressions, ASan/UBSan, TSan
Not-tested: actual napi_* operation mapping (Chunk 4) and device teardown (Task 8)'
```

## Chunk 4: Publish the typed Node-API facade

### Task 4: Bind the app ABI to nine typed ArkTS exports

**Dependency:** Complete and commit Chunks 1-3 first. This task links the renamed raw Go export through the hidden adapter and maps real `napi_*` resources into `NapiEnvironmentOwner`.

**Files:**
- Create: `harmony/entry/src/main/cpp/include/cmfa_napi.h`
- Create: `harmony/entry/src/main/cpp/src/js_codec.cpp`
- Create: `harmony/entry/src/main/cpp/src/js_errors.cpp`
- Create: `harmony/entry/src/main/cpp/src/js_async.cpp`
- Create: `harmony/entry/src/main/cpp/src/js_events.cpp`
- Create: `harmony/entry/src/main/cpp/src/js_core_module.cpp`
- Create: `harmony/entry/src/main/cpp/src/addon_init.cpp`
- Create: `harmony/entry/src/main/cpp/types/libentry/Index.d.ts`
- Create: `harmony/entry/src/main/cpp/types/libentry/oh-package.json5`
- Create: `harmony/entry/src/main/cpp/CMakeLists.txt`
- Modify: `harmony/tests/bin/inspect-native-lib.mjs`
- Modify: `harmony/tests/structure/phase1-bridge-contract.test.mjs`
- Modify: `harmony/entry/build-profile.json5`
- Modify: `harmony/entry/oh-package.json5`

- [ ] **Step 1: Add failing typed-surface, ownership, and build assertions**

Require this complete declaration surface in `Index.d.ts`; no extra export is part of Task 7:

```ts
export type RuntimeState = 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
export type LogLevel = 'DEBUG' | 'INFO' | 'WARN' | 'ERROR';

export interface LocalOptions {
  configPath: string;
  mixedPort: number;
}

export interface RuntimeSnapshot {
  state: RuntimeState;
  activeConfigPath: string;
  mixedPort: number;
}

export type CoreEvent =
  | { type: 'runtime'; state: RuntimeState; message: string }
  | { type: 'log'; level: LogLevel; message: string };

export interface CoreErrorContext {
  operation: string;
  status: number;
}

export interface CoreError extends Error {
  name: 'CoreError';
  code: string;
  category: 'CoreError' | 'StateError';
  detail: string;
  retryable: boolean;
  action: string;
  context?: CoreErrorContext;
}

export const hello: () => string;
export const coreVersion: () => Promise<string>;
export const validateConfiguration: (path: string) => Promise<void>;
export const loadConfiguration: (path: string) => Promise<void>;
export const startLocal: (options: LocalOptions) => Promise<RuntimeSnapshot>;
export const stopRuntime: () => Promise<RuntimeSnapshot>;
export const runtimeSnapshot: () => RuntimeSnapshot;
export const subscribe: (callback: (event: CoreEvent) => void) => number;
export const unsubscribe: (subscriptionId: number) => void;
```

Extend `phase1-bridge-contract.test.mjs` with focused tests that read every facade source and assert:

```js
assert.deepEqual(exportNames.sort(), [
  'coreVersion', 'hello', 'loadConfiguration', 'runtimeSnapshot',
  'startLocal', 'stopRuntime', 'subscribe', 'unsubscribe',
  'validateConfiguration'
]);
assert.match(asyncSource, /std::thread/u);
assert.match(asyncSource, /napi_create_threadsafe_function/u);
assert.match(eventSource, /napi_create_reference/u);
assert.match(eventSource, /napi_call_threadsafe_function/u);
assert.match(initSource, /napi_add_env_cleanup_hook/u);
assert.match(initSource, /NAPI_MODULE\(libentry, Init\)/u);
assert.doesNotMatch(allFacadeSources, /(?:dlopen|dlsym|libdl)/u);
```

Parse the module build profile and require only `arm64-v8a`, a CMake path, and `buildOptionSet.debug.nativeLib.debugSymbol.strip === false`. Require `entry/oh-package.json5` to contain exactly:

```json5
"libentry.so": "file:./src/main/cpp/types/libentry"
```

Add synthetic `nodeAddon` inspector cases. A valid fixture has exact `DT_NEEDED` entries from `toolchain.native-allowlist.json.nodeAddon` and no public `cmfa_*` symbol. Fixtures with `libc++_shared.so`, `libdl.so`, one missing/extra dependency, `cmfa_internal_register_backend`, source-level or Itanium-mangled `register_mihomo_backend`/`unregister_mihomo_backend`, or any `test`/`fake`/`stub` export must fail with a typed inspector code.

- [ ] **Step 2: Run the bridge tests and record RED**

Run:

```bash
node --test harmony/tests/structure/phase1-bridge-contract.test.mjs
```

Expected: the existing Chunk 2/3 assertions pass, while the typed facade, CMake, package, build-profile, and `nodeAddon` inspector tests FAIL because those files/rules do not exist. A zero-match run is invalid RED evidence.

- [ ] **Step 3: Implement copied input/output codecs and the stable `CoreError` mapping**

`cmfa_napi.h` owns only shared declarations: `AddonState`, copied `AsyncInput`/`AsyncResult`, copied `OwnedCoreEvent`, and focused codec/error/async/event entry points. It includes the official API 20-compatible header `napi/native_api.h`; it does not expose Task 6's internal backend seam.

`js_codec.cpp` must complete all conversion before a worker starts:

- strings are measured first, reject embedded NUL, and copy at most `CMFA_MAX_PATH_BYTES - 1` UTF-8 bytes into `std::string`;
- `LocalOptions` must be a non-null object with `configPath` and integer `mixedPort` in `1..65535`; unknown properties are ignored, but missing or wrong-typed required properties fail;
- `cmfa_runtime_snapshot` is copied into `{ state, activeConfigPath, mixedPort }`; state values outside the five declared literals are a backend error;
- callback messages are copied during the native callback and capped at 4096 bytes; no C pointer is retained;
- every `napi_status` is checked. A conversion failure throws/rejects a `CoreError`, never returns `undefined` as accidental success.

`js_errors.cpp` creates an actual JS `Error` with `name`, `code`, `category`, `message`, `detail`, `retryable`, `action`, and optional `{ operation, status }`. Use this stable table and fixed, non-secret text; do not put the user path, raw configuration, credentials, raw `cmfa_error.message`, or an absolute SDK/repository path into the JS error:

| Status | Code | Category | Retryable | Action |
| --- | --- | --- | --- | --- |
| `CMFA_INVALID_ARGUMENT`, `CMFA_INVALID_UTF8`, `CMFA_OUT_OF_RANGE`, `CMFA_BUFFER_TOO_SMALL` | enum name | `CoreError` | false | `CHECK_INPUT` |
| `CMFA_NOT_INITIALIZED`, `CMFA_ALREADY_INITIALIZED`, `CMFA_INVALID_STATE` | enum name | `StateError` | false | `RESTART_OPERATION` |
| `CMFA_BUSY` | `CMFA_BUSY` | `StateError` | true | `RETRY` |
| `CMFA_CORE_UNAVAILABLE` | `CMFA_CORE_UNAVAILABLE` | `CoreError` | false | `UPDATE_CORE` |
| `CMFA_BACKEND_ERROR` | `CMFA_BACKEND_ERROR` | `CoreError` | true | `RETRY` |
| any failed `napi_status` | `NAPI_FAILURE` | `CoreError` | false | `RESTART_APP` |

Use `napi_create_error` plus checked property writes. Synchronous entries call `napi_throw`; Promise completion calls `napi_reject_deferred`. If construction itself fails, use the minimal fixed `napi_throw_error` fallback.

- [ ] **Step 4: Implement owned `std::thread` + TSFN Promise jobs**

`js_async.cpp` provides one job engine for exactly five asynchronous entries: `coreVersion`, `validateConfiguration`, `loadConfiguration`, `startLocal`, and `stopRuntime`. Its creation sequence is fixed:

```text
1. Decode and copy every JS argument on the environment thread.
2. napi_create_promise and retain only napi_deferred in the job.
3. napi_create_threadsafe_function(func=null, max_queue_size=1,
   initial_thread_count=1, call_js_cb=complete_promise).
4. Register the TSFN wrapper with owner.try_add_delivery.
5. Allocate an async wrapper whose std::thread is still default-constructed and
   non-joinable, then register that wrapper with owner.try_add_async.
6. Only after both owner registrations succeed, construct/assign the joinable
   std::thread inside the registered wrapper so the worker cannot outrun owner
   visibility.
7. Return the Promise after the registered worker has been started.
```

Steps 1-7 run synchronously on the same `napi_env` thread as the cleanup hook,
so cleanup cannot interleave inside this creation sequence. If `std::thread`
construction throws, do not start a replacement or release registered handles
directly: call `finish_async(thread_handle)` first, then
`release_delivery(tsfn_handle, true)`, and honor `CLAIMED_BY_CLEANUP` from either
operation. If delivery registration fails, release the never-registered TSFN;
if async registration fails, destroy the still-non-joinable wrapper and roll
back the registered delivery through the owner. Every such path rejects or
throws the fixed sanitized `NAPI_FAILURE` error.

The worker touches no `napi_env`, `napi_value`, or `napi_ref`. It calls only the Task 6 app ABI with owned inputs and writes an owned result:

| JS entry | Worker operation |
| --- | --- |
| `coreVersion` | call `cmfa_core_version` with a 256-byte owned buffer; resolve the copied non-empty string |
| `validateConfiguration` | call `cmfa_validate_config`; Phase 1 must reject `CMFA_CORE_UNAVAILABLE` |
| `loadConfiguration` | call `cmfa_load_config`; Phase 1 must reject `CMFA_CORE_UNAVAILABLE` |
| `startLocal` | call `cmfa_start_local`; Phase 1 must reject `CMFA_CORE_UNAVAILABLE` and never return a fake snapshot |
| `stopRuntime` | call `cmfa_stop`, then `cmfa_runtime_state`; resolve the truthful stopped snapshot |

The worker may only cross into Node-API through `napi_call_threadsafe_function(..., napi_tsfn_nonblocking)`. The completion payload owns its result. `complete_promise` must handle the SDK-defined teardown call where `env == nullptr`: destroy the payload without reading the environment, deferred, or addon state.

Use distinct wrappers so lifetime is unambiguous:

- the async wrapper owns the joinable thread; `request_cancel` sets an atomic cancellation flag, `join` joins, and `release` joins-if-needed then deletes the wrapper;
- the delivery wrapper owns the TSFN release count; `abort` performs one `napi_tsfn_abort`, while `release` performs `napi_tsfn_release` only if abort did not already consume it, then deletes only wrapper-owned native state;
- the TSFN finalizer owns the Promise job object and does not access `napi_env` or `AddonState`;
- after successful owner registration no failure path frees that handle directly. Rollback uses `finish_async`/`release_delivery` and honors `CLAIMED_BY_CLEANUP`.

On normal completion, resolve/reject first, then call `finish_async(thread_handle)` and `release_delivery(tsfn_handle, false)`. A `napi_closing` queue result is owned by cleanup; an unexpected queue failure leaves the registered resources for the same cleanup path rather than self-joining or double-releasing from the worker.

- [ ] **Step 5: Implement subscriptions with a reference, TSFN, and truthful initial state**

`js_events.cpp` owns a mutex-protected `subscriptionId -> shared subscription` map. Each subscription contains an atomic active flag, a `napi_ref`, and its own bounded TSFN. Creation must:

```text
1. Require exactly one callable argument.
2. Call cmfa_runtime_state and copy the current state before publishing anything.
3. Create napi_ref and a TSFN (bounded queue, nonblocking delivery).
4. Register reference and delivery wrappers with NapiEnvironmentOwner.
5. Insert a positive uint32 subscription ID only after both registrations succeed.
6. Queue one copied initial runtime event from the real snapshot.
```

The Phase 1 initial event is therefore exactly truthful `STOPPED`, not a hard-coded optimistic state. Native log/runtime sinks copy `type`, state/level, and bounded message before taking a subscription snapshot; they never call JS directly. Queue full drops that event without blocking the core and without freeing owner-held resources. `napi_closing` is treated as teardown, not as an application error.

`unsubscribe(id)` is idempotent. It marks the subscription inactive and removes it under the map lock, then outside the lock calls `release_delivery(handle, true)` before `release_reference(handle)`. A concurrently copied subscription observes inactive or a closing TSFN; no queued callback may run after unsubscribe returns. Unknown IDs are a no-op, while non-uint32 arguments throw `CoreError`.

- [ ] **Step 6: Publish the module only after backend/core initialization and install one cleanup hook**

`js_core_module.cpp` defines exactly nine `napi_property_descriptor` entries. `hello()` synchronously returns the fixed string `cmfa-native-ready`; `runtimeSnapshot()` synchronously calls the real Task 6 ABI; all entries obtain the same `AddonState` through descriptor data and reject work after delivery closes.

`addon_init.cpp` uses this exact success order:

```text
1. Allocate AddonState and its CREATED NapiEnvironmentOwner.
2. cmfa::register_mihomo_backend.
3. cmfa_initialize with copied log/runtime host sinks.
4. napi_add_env_cleanup_hook.
5. napi_define_properties for exactly nine exports.
6. owner.activate; only now may Promise/event delivery begin.
```

Any failure unwinds in reverse: remove an installed cleanup hook, call the same owner cleanup path (which shuts down then unregisters), delete the state, and throw a sanitized `CoreError`. The cleanup hook first invokes `owner.cleanup()`, whose order is already locked by Chunk 3, and deletes `AddonState` only after drain/shutdown/unregister finish. TSFN finalizers must be self-contained so they cannot refer to the deleted state. Register exactly one module with:

```cpp
NAPI_MODULE(libentry, Init)
```

HiLog messages are fixed lifecycle facts only; never log JS inputs, configuration paths, raw backend errors, or signing/device data.

- [ ] **Step 7: Direct-link one hidden, static-libc++ `libentry.so` and wire Hvigor**

`CMakeLists.txt` uses repository-relative paths resolved from `CMAKE_CURRENT_SOURCE_DIR`:

```cmake
cmake_minimum_required(VERSION 3.5.0)
set(OHOS_STL c++_static CACHE STRING "" FORCE)
project(cmfa_entry LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN YES)

set(CMFA_HARMONY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../..")
set(CMFA_ABI_ROOT "${CMFA_HARMONY_ROOT}/core/abi")
set(CMFA_MIHOMO_LIBRARY "${CMFA_HARMONY_ROOT}/artifacts/libcmfa_mihomo.so")
if(NOT EXISTS "${CMFA_MIHOMO_LIBRARY}")
  message(FATAL_ERROR "Fresh libcmfa_mihomo.so is required before building libentry.so")
endif()

add_library(cmfa_mihomo SHARED IMPORTED)
set_target_properties(cmfa_mihomo PROPERTIES IMPORTED_LOCATION "${CMFA_MIHOMO_LIBRARY}")
add_library(entry SHARED
  "${CMFA_ABI_ROOT}/src/cmfa_contract.cpp"
  src/cmfa_mihomo_backend.cpp
  src/napi_environment.cpp
  src/js_codec.cpp
  src/js_errors.cpp
  src/js_async.cpp
  src/js_events.cpp
  src/js_core_module.cpp
  src/addon_init.cpp
)
```

Give only `cmfa_contract.cpp` and `cmfa_mihomo_backend.cpp` the source-specific `CMFA_INTERNAL_BACKEND_API=1` definition. Add private include paths for `include` and `${CMFA_ABI_ROOT}/include`; add `-Wall -Wextra -Werror -fvisibility=hidden`. Keep `OHOS_STL=c++_static` before `project()` as the single source-level STL selection so it exists when CMake loads the HarmonyOS toolchain; that toolchain maps the value to its own `-static-libstdc++` linker flag, so do not add a second manual STL link option. Link exactly `cmfa_mihomo`, `libace_napi.z.so`, and `libhilog_ndk.z.so`. Do not link `dl`, use `LINK_FLAGS` with an absolute SDK path, or make another contract DSO.

The module build profile must contain:

```json5
"buildOption": {
  "externalNativeOptions": {
    "path": "./src/main/cpp/CMakeLists.txt",
    "abiFilters": ["arm64-v8a"],
    "targets": ["entry"]
  },
  "resOptions": { "copyCodeResource": { "enable": false } }
},
"buildOptionSet": [
  {
    "name": "debug",
    "nativeLib": { "debugSymbol": { "strip": false } }
  },
  { "name": "release", "arkOptions": { "obfuscation": { "ruleOptions": { "enable": false, "files": ["./obfuscation-rules.txt"] } } } }
]
```

`types/libentry/oh-package.json5` names `libentry.so`, version `1.0.0`, and sets `types` to `./Index.d.ts`. `entry/oh-package.json5` adds only the local `libentry.so` dependency shown in Step 1.

Finish `inspect-native-lib.mjs` support for `nodeAddon`: infer it from `libentry.so`, select `allowlist.nodeAddon`, require the sorted `DT_NEEDED` list to equal that allowlist exactly, require no public `cmfa_*`, internal/backend/test-hook/sentinel export, and report `LIBDL_FORBIDDEN` or `LIBCXX_SHARED_FORBIDDEN` explicitly. This exact gate prevents the probed default `libc++_shared.so` dependency from being packaged.

- [ ] **Step 8: Configure the cross-build and verify source/host GREEN**

Run:

```bash
node harmony/tools/build-mihomo-ohos.mjs
node --test harmony/tests/structure/phase1-bridge-contract.test.mjs
cd harmony && ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug :entry:compileNative
cd ..
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case contract
```

Expected: the real core rebuild and bridge structure suite pass; Hvigor accepts
the arm64-only external CMake graph and generates its native build files without
packaging a HAP; all three host suites remain green. Task 5 owns the first actual
addon compilation/ELF inspection and is the only task allowed to package the
acceptance HAP after pre-package hashes exist. This is not a device-load pass.

- [ ] **Step 9: Commit the typed facade**

```bash
git add harmony/entry/src/main/cpp harmony/entry/build-profile.json5 harmony/entry/oh-package.json5 harmony/tests/bin/inspect-native-lib.mjs harmony/tests/structure/phase1-bridge-contract.test.mjs
git commit -m "Expose the real core through one typed HarmonyOS boundary" -m $'ArkTS needs a small, explicit native surface whose async work and subscriptions cannot outlive their environment. Publish nine typed exports, route them through the stable Task 6 ABI, and direct-link the freshly built real core without widening ELF visibility.\n\nConstraint: Unimplemented Phase 1 capabilities reject honestly and no napi_env use survives cleanup\nRejected: Use napi_async_work or dlopen | the approved boundary requires owned std::thread/TSFN work and a direct-linked real backend\nConfidence: medium\nScope-risk: broad\nDirective: New JS capabilities must extend the typed facade and NapiEnvironmentOwner instead of calling raw Go exports\nTested: bridge structure tests, OHOS arm64 Hvigor CMake configuration, contract/backend/environment host regressions\nNot-tested: addon link/ELF/HAP provenance (Task 5) or Promise/event execution on a HarmonyOS device (Task 8 gate)'
```

## Chunk 5: Prove the exact native bytes in one fresh HAP

### Task 5: Orchestrate and persist Phase 1 native provenance

**Dependency:** Complete and commit Chunks 1-4 first. This task is the only
acceptance lane that may package a HAP. It starts from a new random run, removes
only known generated outputs, hashes the core and addon before packaging, then
proves the exact HAP entries came from those bytes.

**Files:**
- Create: `harmony/tools/lib/native-provenance.mjs`
- Create: `harmony/tests/bin/build-phase1-native.mjs`
- Create: `harmony/tests/structure/phase1-native-build-contract.test.mjs`
- Modify: `harmony/toolchain.requirements.json`
- Modify: `harmony/tools/lib/toolchain.mjs`
- Modify: `harmony/tests/structure/toolchain-discovery.test.mjs`

- [ ] **Step 1: Add failing manifest, archive, ordering, and result tests**

`phase1-native-build-contract.test.mjs` imports the two missing modules and
uses temporary directories plus injected command/build/inspection operations.
Require these public helper exports:

```js
export const PHASE1_NATIVE_SCHEMA_VERSION = '1.0.0';
export const PHASE1_NATIVE_PHASE = 1;
export const HAP_NATIVE_ENTRIES = Object.freeze({
  addon: 'libs/arm64-v8a/libentry.so',
  core: 'libs/arm64-v8a/libcmfa_mihomo.so'
});

export async function hashFile(filePath, options = {});
export async function listHapEntries(hapPath, options = {});
export async function extractAndHashHapEntry(hapPath, entryPath, options = {});
export async function inspectHapNativeEntries(input, options = {});
export function derivePhase1Result(manifest);
export function validatePhase1NativeManifest(manifest, options = {});
export async function verifyPhase1NativeManifest(manifest, options = {});
```

Cover all of the following as separate named tests:

- `/usr/bin/unzip -Z1` entry listing counts exact path occurrences; missing or
  duplicate addon/core entries return `HAP_NATIVE_ENTRY_MISSING` or
  `HAP_NATIVE_ENTRY_AMBIGUOUS`.
- `/usr/bin/unzip -p` extraction is streamed to a run-scoped temporary file and
  SHA-256; an unzip error is `HAP_NATIVE_EXTRACTION_FAILED`. No archive path is
  interpolated into a shell string.
- a valid manifest has a UUID run ID, ordered timestamps, the toolchain-lock
  digest, raw/pre-package/HAP hashes, both ELF reports, archive occurrence
  counts, `nativeBuildResult`, overall `result`, and sanitized failures.
- raw core, pre-package core, and HAP core SHA-256/size must all match;
  pre-package addon and HAP addon SHA-256/size must match.
- a stale/missing path, swapped bytes, wrong toolchain digest, missing ELF pass,
  wrong architecture/dependency/export contract, or hash mismatch never
  validates.
- `fail` has priority over `incomplete`: any native/provenance/build failure
  makes both `nativeBuildResult` and overall `result` `fail`; signing/device
  blockers alone keep `nativeBuildResult: 'pass'` and overall
  `result: 'incomplete'`.
- no target records `DEVICE_TARGET_MISSING`; unsigned output records
  `SIGNING_REQUIRED`; when both occur both codes remain in the manifest.
- one injected full-success run records this exact order and no package action
  before both pre-package hashes:

```js
assert.deepEqual(events, [
  'clean', 'toolchain-lock', 'inspect-toolchain', 'verify-native-task',
  'build-core', 'hash-raw-core',
  'inspect-raw-core', 'prepare-addon', 'build-addon',
  'stage-pre-package-core', 'hash-pre-package-core',
  'hash-pre-package-addon', 'inspect-pre-package-core',
  'inspect-pre-package-addon', 'package-hap', 'hash-hap',
  'list-hap', 'extract-hap-core', 'extract-hap-addon',
  'inspect-hap-core', 'inspect-hap-addon', 'discover-device', 'persist'
]);
```

- core/addon failures stop before packaging; package/archive/hash failures stop
  before device discovery; the `finally` path still persists one sanitized
  manifest.
- the checked-in toolchain contract resolves and executable-checks a distinct
  `resolved.paths.cmakeExecutable`; it does not confuse that binary with the
  existing `resolved.paths.cmake` HarmonyOS toolchain file.
- the real Hvigor `taskTree` parser requires a top-level
  `:entry:compileNative` branch, requires that branch to contain
  `BuildNativeWithCmake`, and rejects it if the branch reaches `PackageHap`.
  The test does not assume the task is configure-only; it proves only that it
  prepares native work without packaging.
- CLI parsing rejects unknown flags, repeated flags, missing values, and paths
  outside the repository with stable `ARGUMENT_INVALID`/`PATH_OUTSIDE_REPO`
  failures. Default output is
  `harmony/artifacts/phase1-native-provenance.json`.

- [ ] **Step 2: Run the Phase 1 build contract and record RED**

Run:

```bash
node --test harmony/tests/structure/toolchain-discovery.test.mjs harmony/tests/structure/phase1-native-build-contract.test.mjs
```

Expected: the test file is discovered and fails because
`native-provenance.mjs` and `build-phase1-native.mjs` do not exist and the
toolchain resolver does not expose `cmakeExecutable`. A missing test file,
syntax error before test registration, or `1..0` is invalid RED.

- [ ] **Step 3: Implement archive hashing and strict manifest validation**

`native-provenance.mjs` uses only Node built-ins and the existing
`proof-redaction.mjs`. It must:

- hash files with streaming `crypto.createHash('sha256')`, returning both
  `sha256` and `sizeBytes`;
- execute only absolute `/usr/bin/unzip` with argument arrays, never a shell;
- list with `['-Z1', hapPath]`, reject a non-zero exit, and preserve duplicate
  lines so occurrence counts are meaningful;
- extract each exact entry with `['-p', hapPath, entryPath]` into a temporary
  file under `os.tmpdir()`, update SHA-256/size while streaming, close the file
  before inspection, and remove the run-scoped directory in `finally`;
- run `inspectNativeLibrary` on both extracted files with explicit `mihomoCore`
  and `nodeAddon` components; store normalized reports without temporary paths;
- require exact `HAP_NATIVE_ENTRIES`, exactly one occurrence each, and no second
  `libentry.so` or `libcmfa_mihomo.so` under another archive path;
- sanitize every persisted command, path, stdout/stderr, exception message, and
  failure detail. The repository path, home path, file URLs, URL credentials,
  Windows absolute paths, and signing-material filenames must not survive.

The versioned manifest shape is fixed:

```text
schemaVersion, phase, runId, result, nativeBuildResult
timestamps.startedAt, timestamps.completedAt
toolchainLock.path, toolchainLock.sha256
builds.core, builds.addonConfigure, builds.addon, builds.hap
artifacts.rawCore
artifacts.prePackageCore, artifacts.prePackageAddon
artifacts.hap, artifacts.hapCore, artifacts.hapAddon
archive.entryCount, archive.occurrences
signing.result
device.result, device.targetCount, device.identityMasked, device.proofResult
failures[] { code, detail, stage }
```

Use these exact nested state contracts; no other enum value or field is valid:

```text
BuildStep = {
  result: 'pass' | 'fail' | 'not-run',
  command: string[] | null,
  exitCode: integer | null,
  stdout: string,
  stderr: string
}

Artifact = null | {
  identity: string,
  sha256: 64-lowercase-hex,
  sizeBytes: non-negative integer,
  elf: inspectNativeLibrary pass report | null
}

signing = { result: 'pass' | 'incomplete' | 'not-run' }
device = {
  result: 'pass' | 'incomplete' | 'not-run',
  targetCount: non-negative integer | null,
  identityMasked: string | null,
  proofResult: 'not-run'
}
archive = {
  entryCount: non-negative integer | null,
  occurrences: { core: non-negative integer | null,
                 addon: non-negative integer | null }
}
```

All four `builds.*` fields always exist. Before a step runs it is the exact
`not-run/null/null/empty/empty` record; a pass has `exitCode: 0`; a fail has a
non-zero/null exit and at least one matching failure. Every artifact field
always exists and is `null` until produced. Raw/pre-package records require an
ELF pass report; HAP, HAP-core, and HAP-addon records require the HAP digest or
the extracted component ELF pass report as applicable. `toolchainLock.path` is
always the normalized lock identity; its SHA may be `null` only when a
toolchain-lock failure makes `nativeBuildResult: 'fail'` and every build stays
`not-run`.

`signing.result` is `not-run` until HAP selection, `incomplete` only with
`SIGNING_REQUIRED`, and otherwise `pass`. `device.result` is `not-run` after any
earlier native failure, `incomplete` only with a device-discovery blocker, and
`pass` only for exactly one masked target. `device.proofResult` always remains
`not-run`: Task 5 may discover a target but must not install, launch, or claim a
device pass. `validatePhase1NativeManifest` rejects unknown top-level/nested
fields, invalid UUID/timestamps/digests, inconsistent step/null/result
combinations, missing pass reports, non-arm64 components, and impossible
occurrence counts.
`verifyPhase1NativeManifest` additionally re-hashes every current file and HAP
entry and rejects stale, removed, or swapped bytes.

- [ ] **Step 4: Implement the fresh Go → addon → HAP orchestrator**

`build-phase1-native.mjs` exports `buildPhase1Native`, `parseCliArguments`,
`runCli`, and `writeManifest`. All external operations are injectable for the
contract tests, while production defaults call the existing real helpers.

First extend the existing toolchain contract test-first. Add this checked-in
requirement beside `ndkCmake`:

```json
"nativeCmakeBinary": "openharmony/native/build-tools/cmake/bin/cmake"
```

`buildResolvedPaths` keeps the current `cmake` field for
`ohos.toolchain.cmake` and adds a separate `cmakeExecutable` field.
`inspectToolchain` requires it to be executable, exposes
`tools.nativeCmake.found`, and returns the absolute executable only at
`inspection.resolved.paths.cmakeExecutable`; persisted reports still omit
absolute SDK paths. Extend `toolchain-discovery.test.mjs` with missing,
non-executable, and successful fixtures before changing production code.

The orchestrator also parses one fresh `hvigorw ... taskTree` result before the
native run. Isolate the `:entry:compileNative` root branch by indentation; require
`BuildNativeWithCmake` within that branch and forbid `PackageHap`. Name this
operation `prepare-addon`, not `configure-addon`: correctness relies only on it
not packaging a HAP, not on whether a future Hvigor version also compiles part
of the graph.

Start by creating `crypto.randomUUID()` and `startedAt`, then remove only these
validated generated targets:

```text
harmony/artifacts/libcmfa_mihomo.so
harmony/entry/.cxx/default/default/debug/arm64-v8a
harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a
harmony/entry/build/default/outputs/default
```

Refuse to clean if any resolved target escapes `harmony/` or equals the
repository/worktree root. The execution sequence is normative:

1. Hash `harmony/toolchain.lock.json`, run `inspectToolchain`, and verify the
   checked-in native CMake executable plus the `compileNative` task branch; any
   lock, toolchain, task-graph, or path failure is a native build `fail`.
2. Call `buildMihomoOhos`; require its aggregate proof to pass and require the
   single canonical `harmony/artifacts/libcmfa_mihomo.so` created after
   `startedAt`.
3. Immediately hash and inspect that raw core.
4. Run the verified non-packaging Hvigor native-preparation task:

   ```text
   ./hvigorw --mode module -p module=entry@default -p product=default
   -p buildMode=debug :entry:compileNative
   ```

5. Use only `inspection.resolved.paths.cmakeExecutable` from the checked-in
   toolchain contract and run it without a shell:

   ```text
   cmake --build entry/.cxx/default/default/debug/arm64-v8a --target entry
   ```

   Require the one fresh addon at
   `entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so`.
6. Copy the already-hashed raw core into that same pre-package directory as
   `libcmfa_mihomo.so`; hash both pre-package files and inspect them. Require
   raw core and pre-package core to match before proceeding.
7. Only now call the existing `buildHap` helper. It may re-run the native task,
   but any byte change is caught below. Preserve `SIGNING_REQUIRED` as an
   incomplete blocker and continue inspecting an available unsigned HAP; any
   other build failure is `fail`.
8. Hash the exact selected HAP, inspect its archive, extract/inspect both unique
   native entries, and require all pre-package/HAP SHA-256 and size equalities.
9. Run `hdc list targets` only for discovery, using the Phase 0 parser/masking
   helpers. Zero targets is `DEVICE_TARGET_MISSING`; multiple targets is
   `DEVICE_TARGET_AMBIGUOUS`; neither is a native build failure. Do not install.
10. Finalize with `fail` priority, set `completedAt`, sanitize the whole object,
    validate it, and atomically write a temporary JSON then rename it to
    `harmony/artifacts/phase1-native-provenance.json`.

The stable classification is:

| Condition | `nativeBuildResult` | Overall `result` |
| --- | --- | --- |
| Native build, ELF, archive, freshness, or hash error | `fail` | `fail` |
| Native proof passes; signing or device discovery is blocked | `pass` | `incomplete` |
| Native proof passes; signed HAP and one target are present | `pass` | `pass` |

If a fail and blocker coexist, retain every failure but return `fail`. CLI exit
codes are `0` for pass, `1` for honest incomplete, and `2` for fail/fatal. A
`--validate <manifest>` mode performs live `verifyPhase1NativeManifest` and
returns `0` when provenance is intact even if the recorded overall result is
honestly incomplete.

- [ ] **Step 5: Run focused GREEN and regression tests**

Run:

```bash
node --test harmony/tests/structure/toolchain-discovery.test.mjs
node --test harmony/tests/structure/phase1-native-build-contract.test.mjs
node --test harmony/tests/structure/phase0-proof-contract.test.mjs
node --test harmony/tests/structure/go-ohos-build-contract.test.mjs
node --test harmony/tests/structure/phase1-bridge-contract.test.mjs
```

Expected: every ordering, manifest, archive, freshness, redaction, result
priority, CLI, and existing Phase 0/Go/bridge regression passes with zero
warnings or skipped zero-match tests.

- [ ] **Step 6: Run the real provenance lane and inspect its honest gate**

Run:

```bash
node harmony/tests/bin/build-phase1-native.mjs
node harmony/tests/bin/build-phase1-native.mjs --validate harmony/artifacts/phase1-native-provenance.json
```

Expected on the current machine: the first command builds and proves both
native libraries, persists the manifest, and exits `1` only because no eligible
HarmonyOS 6 arm64 target is attached (`DEVICE_TARGET_MISSING`); if the generated
HAP is unsigned it also retains `SIGNING_REQUIRED`. `nativeBuildResult` remains
`pass`, overall `result` is `incomplete`, and the live validation command exits
`0`. Any native/provenance error instead exits `2` and must be fixed before
continuing.

- [ ] **Step 7: Commit the provenance lane**

```bash
git add harmony/toolchain.requirements.json harmony/tools/lib/toolchain.mjs harmony/tests/structure/toolchain-discovery.test.mjs harmony/tools/lib/native-provenance.mjs harmony/tests/bin/build-phase1-native.mjs harmony/tests/structure/phase1-native-build-contract.test.mjs
git commit -m "Make packaged native bytes independently provable" -m $'A successful HarmonyOS build is not enough to show which core and addon bytes entered the HAP. Add one fresh, ordered provenance run that hashes before packaging, re-extracts both unique archive entries, and preserves signing/device blockers without hiding native failures.\n\nConstraint: HAP packaging is forbidden until raw and pre-package hashes exist\nRejected: Hash only the final HAP | it cannot detect stale or swapped native inputs\nConfidence: high\nScope-risk: moderate\nDirective: Keep Phase 1 provenance separate from Phase 0 evidence and retain fail-over-incomplete priority\nTested: toolchain CMake-binary discovery, manifest/archive/order/redaction contracts, Phase 0/Go/bridge regressions, real native build and live manifest verification\nNot-tested: on-device Node-API load and real version display (Task 8)'
```

## Chunk 6: Run the final Task 7 acceptance matrix

### Task 6: Re-run every boundary, sanitizer, build, and provenance proof

**Files:** No tracked files. The Phase 1 manifest and native/HAP outputs remain
ignored evidence. If this task uncovers a bug, return to the owning task, add a
failing regression test, fix it there, repeat its two reviews, then restart this
matrix from Step 1.

- [ ] **Step 1: Run every structure test and Go regression**

```bash
node --test harmony/tests/structure/*.test.mjs
cd harmony/core/go && GOCACHE=/private/tmp/cmfa-go-cache-task7 GOMODCACHE=/private/tmp/cmfa-go-mod-cache-task7 go test ./...
cd ../../..
```

Expected: all discovered Node tests and all Go packages pass. No Android/Gradle
file is touched and no Android APK is built because this branch changes only
the separately scoped `harmony/**` implementation.

- [ ] **Step 2: Run all strict host cases**

```bash
node harmony/tools/test-native-host.mjs
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
```

Expected: default and `contract` run the same Task 6 suite; backend and owner
cases pass independently; no case silently falls back to another suite.

- [ ] **Step 3: Re-run the native owner and adapter sanitizers**

```bash
clang++ -std=c++17 -Wall -Wextra -Werror -pthread -fsanitize=address,undefined -fno-omit-frame-pointer -DCMFA_INTERNAL_BACKEND_API=1 -I harmony/core/abi/include -I harmony/entry/src/main/cpp/include harmony/core/abi/src/cmfa_contract.cpp harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp harmony/tests/native/cmfa_mihomo_backend_test.cpp -o /private/tmp/cmfa_mihomo_backend_task7_asan
ASAN_OPTIONS=detect_leaks=0 /private/tmp/cmfa_mihomo_backend_task7_asan
clang++ -std=c++17 -Wall -Wextra -Werror -pthread -fsanitize=thread -DCMFA_INTERNAL_BACKEND_API=1 -I harmony/core/abi/include -I harmony/entry/src/main/cpp/include harmony/core/abi/src/cmfa_contract.cpp harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp harmony/tests/native/cmfa_mihomo_backend_test.cpp -o /private/tmp/cmfa_mihomo_backend_task7_tsan
/private/tmp/cmfa_mihomo_backend_task7_tsan
clang++ -std=c++17 -Wall -Wextra -Werror -pthread -fsanitize=address,undefined -fno-omit-frame-pointer -I harmony/core/abi/include -I harmony/entry/src/main/cpp/include harmony/entry/src/main/cpp/src/napi_environment.cpp harmony/tests/native/napi_environment_test.cpp -o /private/tmp/cmfa_napi_environment_task7_asan
ASAN_OPTIONS=detect_leaks=0 /private/tmp/cmfa_napi_environment_task7_asan
clang++ -std=c++17 -Wall -Wextra -Werror -pthread -fsanitize=thread -I harmony/core/abi/include -I harmony/entry/src/main/cpp/include harmony/entry/src/main/cpp/src/napi_environment.cpp harmony/tests/native/napi_environment_test.cpp -o /private/tmp/cmfa_napi_environment_task7_tsan
/private/tmp/cmfa_napi_environment_task7_tsan
```

Expected: all binaries exit `0` with no memory, undefined-behavior, data-race,
deadlock, duplicate release, or delivery-after-cleanup report.

- [ ] **Step 4: Rebuild and live-verify the exact HAP provenance**

```bash
node harmony/tests/bin/build-phase1-native.mjs
node harmony/tests/bin/build-phase1-native.mjs --validate harmony/artifacts/phase1-native-provenance.json
```

Expected: the fresh manifest proves AArch64 and exact allowlisted dependencies,
the raw/private export rules, hidden addon symbols, unique archive entries, and
all five required hash/size equalities. Without a target and/or signing, the
corresponding `DEVICE_TARGET_MISSING` and `SIGNING_REQUIRED` blockers produce an
honest `incomplete`; if a signed HAP and exactly one target are available, the
provenance manifest may be `pass`. Either outcome is only Task 7 build/byte
provenance: do not claim the Task 8 Phase 1 device-load proof.

- [ ] **Step 5: Audit scope and tracked-output hygiene**

```bash
git diff --check
git status --short
git diff --name-only 5b83d2ce..HEAD
```

Expected: no whitespace errors; no `.so`, HAP, cgo header, manifest, signing
material, cache, absolute SDK path, Android/JNI/Gradle source, or Android release
metadata is tracked. `5b83d2ce` is the checked-in Task 7 design/base commit;
every later Task 7 commit is limited to `harmony/**` plus this plan, and the
final report cites the manifest path/result without committing it.
