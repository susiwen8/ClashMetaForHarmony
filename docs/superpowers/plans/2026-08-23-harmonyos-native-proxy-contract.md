# HarmonyOS Native Proxy Contract Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the active loaded mihomo runtime's selectable proxy groups, ordered members, current selection, and strict selector patch through a bounded Go/C ABI/Node-API/ArkTS contract.

**Architecture:** Add a dedicated Go `proxygroups` façade over mihomo v1.19.29 instead of parsing YAML in ArkTS. Carry its results through caller-owned bounded JSON buffers in the existing hand-written C ABI, then through asynchronous Node-API string exports and a strict ArkTS decoder. Plan B owns no UI and no durable selection table; Plan C will wrap these core results with active profile/revision/session orchestration and persistence.

**Tech Stack:** Go 1.24, mihomo v1.19.29, cgo, C11/C++17 ABI contracts, HarmonyOS Node-API, ArkTS/Hypium, Node.js structure tests, Hvigor/HAP inspection.

**Spec:** `docs/superpowers/specs/2026-08-21-harmonyos-proxy-group-node-selection-design.md` — Plan B only.

**Prerequisite evidence:** Plan A is complete. The current physical-device subscription is `VALID`, its committed revision is YAML rather than Base64, the pinned GeoIP database is installed, and enable succeeded after `loadConfiguration`.

**Dirty-worktree constraint:** The target Go, ABI, C++, ArkTS, build, and test files already contain unrelated uncommitted work. Preserve it. Do not reset, restore, clean, or stage whole overlapping files. Implementation commits remain deferred until the user authorizes scoped staging.

**Privacy rule:** Group and node names are application-private. They may cross the native bridge and appear in the in-app proxy page later, but must never appear in logs, thrown error details, build reports, device proof, or exported diagnostics. Endpoint and credential fields are forbidden from every Plan B model and response.

**Command convention:** Every command below starts at the repository root. Commands that need an absolute Go module cache first set `CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"` and derive `GOMODCACHE` from it; no command contains a machine-specific path or placeholder.

---

## Chunk 1: Go Runtime Façade and Strict JSON Results

### Task 1: Define bounded proxy-group domain models and validation

**Files:**
- Create: `harmony/core/go/internal/proxygroups/models.go`
- Create: `harmony/core/go/internal/proxygroups/models_test.go`

- [ ] **Step 1: Write failing model validation tests**

Define tests for these exact limits and rules:

```go
const (
    MaxGroupCount     = 128
    MaxMemberCount    = 1024
    MaxNameUTF8Bytes  = 256
    MaxResponseBytes  = 1024 * 1024
)
```

Cover valid UTF-8 names; empty, oversized, control-character, and invalid UTF-8 names; duplicate group/member names; group/member count overflow; unknown group/member types; mismatched `SelectedName`; and multiple members marked selected.

The closed v1.19.29 runtime-type allowlist is `Direct`, `Reject`, `RejectDrop`, `Compatible`, `Pass`, `PassRule`, `Rematch`, `Dns`, `Relay`, `Selector`, `Fallback`, `URLTest`, `LoadBalance`, `Shadowsocks`, `ShadowsocksR`, `Snell`, `Socks5`, `Http`, `Vmess`, `Vless`, `Trojan`, `Hysteria`, `Hysteria2`, `WireGuard`, `Tuic`, `Ssh`, `Mieru`, `AnyTLS`, `Sudoku`, `Masque`, `TrustTunnel`, `ShadowQuic`, `OpenVPN`, `Tailscale`, and `GostRelay`. This list is pinned to `github.com/metacubex/mihomo@v1.19.29/constant.AdapterType`; unknown/future values fail closed until reviewed. Do not add server, port, UUID, password, token, transport, certificate, provider payload, delay, or URL fields.

- [ ] **Step 2: Run the focused Go test and verify RED**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./internal/proxygroups -count=1
```

Expected: compile failure because the package and types do not exist.

- [ ] **Step 3: Implement immutable result models**

Implement:

```go
type QueryContext struct {
    ProfileHash  string
    RevisionHash string
    SessionHash  *string
    Generation   uint64
}

type GroupRef struct {
    Name string `json:"name"`
    Type string `json:"type"`
}

type NodeSummary struct {
    Name     string `json:"name"`
    Type     string `json:"type"`
    IsGroup  bool   `json:"isGroup"`
    Selected bool   `json:"selected"`
}

type GroupSnapshot struct {
    Name         string        `json:"name"`
    Type         string        `json:"type"`
    SelectedName string        `json:"selectedName"`
    Nodes        []NodeSummary `json:"nodes"`
}
```

`ProfileHash` and `RevisionHash` are exactly 64 lowercase hexadecimal characters. `SessionHash` is either nil or exactly 64 lowercase hexadecimal characters. `Generation` is non-zero. These values are caller correlation identities; the runtime façade echoes them but never logs them. The app-owned core uses a nil session hash. Plan C supplies a session hash only for extension-owned runtime commands and remains responsible for proving that all hashes match the active profile, revision, and session. Adding this context intentionally refines the shorthand signatures in spec section 7.2 so stale results can be correlated without exposing raw IDs.

- [ ] **Step 4: Implement closed JSON result envelopes**

Use explicit structs rather than `map[string]any`:

```text
schemaVersion = "1.0.0"
kind = GROUP_LIST | GROUP_SNAPSHOT | SELECTION_APPLIED
profileHash
revisionHash
sessionHash (explicit JSON null or a 64-byte lowercase hash)
generation
groups | group
previousName (selection only)
```

Marshal only after model validation and reject any payload larger than `MaxResponseBytes`. Plan B does not encode rejected results in JSON: failures travel through the existing typed `cmfa_error`/`CoreError` channel with allowlisted codes `PROXY_RUNTIME_NOT_READY`, `PROXY_GROUP_NOT_FOUND`, `PROXY_GROUP_NOT_SELECTABLE`, `PROXY_MEMBER_NOT_FOUND`, `PROXY_SELECTION_FAILED`, and `PROXY_BRIDGE_INVALID`, plus retryability metadata. Plan C wraps those errors in the spec's rejected-result unions. No error field contains a raw name.

- [ ] **Step 5: Run the focused tests and verify GREEN**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
gofmt -w internal/proxygroups/models.go internal/proxygroups/models_test.go
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./internal/proxygroups -count=1
git -C "$CMFA_REPO_ROOT" diff --check -- \
  harmony/core/go/internal/proxygroups/models.go \
  harmony/core/go/internal/proxygroups/models_test.go
```

Expected: all model/bounds/JSON tests pass and `git diff --check` is empty.

### Task 2: Adapt mihomo's active proxy registry and patch selectors strictly

**Files:**
- Create: `harmony/core/go/internal/proxygroups/runtime.go`
- Create: `harmony/core/go/internal/proxygroups/runtime_test.go`
- Create: `harmony/core/go/internal/proxygroups/mihomo.go`
- Create: `harmony/core/go/internal/proxygroups/mihomo_integration_test.go`

- [ ] **Step 1: Write failing façade and real-adapter tests**

Define an internal `RuntimeRegistry`/`RuntimeGroup` adapter surface so unit tests do not need mihomo globals. Write both unit tests and the real-mihomo integration test before production implementation. Cover:

- listing hidden-filtered groups in runtime order;
- `selectableOnly=true` returning only `Selector` groups;
- querying ordered members and current member;
- nested group member `isGroup=true`;
- missing group, non-group proxy, duplicate member, malformed current selection, and not-ready registry;
- selection rejecting non-`Selector` groups and missing members before mutation;
- `Set` failure preserving the previous selection;
- successful `Set`, post-query confirmation, and one call to close stale connections for the selected group;
- post-query mismatch returning failure instead of invented success.

The integration test uses a credential-free in-memory config containing two selectors, nested membership, `DIRECT`, and `REJECT`. It loads through production `mihomoexecutor.ParseWithBytes`/`ApplyConfig`, queries real groups, selects another terminal member, and confirms the post-patch snapshot. Isolate the test package/process and restore/shutdown global runtime state in `t.Cleanup`. Do not log names or config bytes.

- [ ] **Step 2: Run the focused Go tests and verify RED**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./internal/proxygroups -count=1
```

Expected: the unit and real-adapter tests fail because the façade and production adapter are missing.

- [ ] **Step 3: Implement the serialized façade**

`Service` owns one `sync.Mutex` covering list/query/select calls. It exposes:

```go
func (s *Service) ListGroups(ctx QueryContext, selectableOnly bool) ([]byte, error)
func (s *Service) QueryGroup(ctx QueryContext, groupName string) ([]byte, error)
func (s *Service) Select(ctx QueryContext, groupName, memberName string) ([]byte, error)
```

Validate all input before registry access. Selection must verify the member in the same queried snapshot, call `Set`, re-query, require `Now()==memberName`, then close only connections whose tracker chain contains the selected group. Stale-connection closure is best-effort after confirmed selection: attempt every matching tracker and ignore individual `Close()` errors because the selector cannot be safely rolled back and an already-applied selection must not be reported as rejected. Do not reproduce Android's legacy behavior that returned `true` after `Set` failed.

- [ ] **Step 4: Implement the production mihomo adapter**

Use:

- `tunnel.Proxies()` for the current loaded registry;
- `tunnel.Proxies()["GLOBAL"] -> ProxyGroup.Proxies()` for the deterministic active top-level order after mihomo flattens every configured provider; never range the registry map for UI order and never truncate to `Providers()[0]` because an explicit `GLOBAL` may legally combine `use` and `proxies` across multiple providers;
- `outboundgroup.ProxyGroup` for groups/members/current selection/hidden state;
- `outboundgroup.SelectAble` plus exact type `constant.Selector` for patches;
- `statistic.DefaultManager.Range` and tracker chain inspection for group-scoped stale connection closure.

Convert `constant.AdapterType` with one exhaustive local switch pinned to the closed allowlist from Task 1. Do not call `AdapterType.String()` as the contract authority: in v1.19.29 it returns `Unknown` for at least `URLTest` and has no `LoadBalance` branch. Tests pin every allowed constant to its exact bridge string and reject values outside the pinned set.

No provider browsing, delay probing, sorting, or subtitle parsing is added.

- [ ] **Step 5: Run Go tests and verify GREEN**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./internal/proxygroups -count=1
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./... -count=1
```

Expected: the focused proxy tests and complete offline Go suite pass.

### Task 3: Export the bounded Go JSON functions from `cmfa_core`

**Files:**
- Modify: `harmony/core/go/cmd/cmfa_core/main.go`
- Modify: `harmony/core/go/cmd/cmfa_core/main_test.go`
- Create: `harmony/core/go/cmd/cmfa_core/proxy_exports_test.go`

- [ ] **Step 1: Write failing export/helper tests**

Cover nil input/output pointers, invalid UTF-8, invalid query hashes/generation, empty/oversized names, buffer-too-small required length, exact NUL termination, response cap enforcement, not-ready runtime, backend typed errors, and success without logging raw names.

- [ ] **Step 2: Run the export tests and verify RED**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./cmd/cmfa_core -count=1
```

Expected: raw cgo export symbols and buffer writer are absent.

- [ ] **Step 3: Add three raw Go exports**

```text
cmfa_mihomo_proxy_groups_v1
cmfa_mihomo_proxy_group_v1
cmfa_mihomo_proxy_select_v1
```

Each accepts validated query-context values plus a caller-owned output buffer/capacity and required-length pointer. It returns existing `cmfa_status` values only. On success, length is the JSON byte count excluding the trailing NUL. On `CMFA_BUFFER_TOO_SMALL`, length is the required JSON byte count excluding NUL, no partial JSON is copied, and the caller needs `length+1` bytes. On every other failure, length is zero. The Go side never returns an allocated C string and never logs request/result names.

- [ ] **Step 4: Bind exports to one production `proxygroups.Service`**

Use a package-level service with an explicit test replacement seam following the existing local-proxy/TUN export tests. Clear any test replacement in `t.Cleanup`. A successful config load makes the real mihomo registry queryable; an empty registry maps to `CMFA_INVALID_STATE`.

- [ ] **Step 5: Run Go tests and verify GREEN**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./cmd/cmfa_core ./internal/proxygroups -count=1
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./... -count=1
```

---

## Chunk 2: C ABI Contract and Hidden Backend Adapter

### Task 4: Add the public C ABI query/select buffer contract

**Files:**
- Modify: `harmony/core/abi/include/cmfa_types.h`
- Modify: `harmony/core/abi/include/cmfa_host.h`
- Modify: `harmony/core/abi/include/cmfa_core.h`
- Modify: `harmony/core/abi/src/cmfa_contract.cpp`
- Modify: `harmony/tests/native/cmfa_contract_test.cpp`
- Modify: `harmony/tools/test-native-host.mjs`
- Modify: `harmony/tests/structure/phase1-bridge-contract.test.mjs`

- [ ] **Step 1: Write failing C contract tests**

Add a `cmfa_proxy_query_context` with `struct_size`, fixed 65-byte lowercase profile/revision/session hash buffers, and non-zero generation. An empty session hash means absent; a non-empty session hash must be exactly 64 lowercase hexadecimal bytes. Add a caller-owned `cmfa_json_buffer` (`data`, `capacity`, `length`). Add tests for exact struct size, invalid hashes/generation, invalid UTF-8/control/oversized names, null buffers, too-small buffers, backend overrun/non-NUL output, response cap, backend errors, shutdown/race borrowing, and successful length-preserving JSON copy.

Buffer semantics are exact:

- success: `length` is the JSON byte count excluding NUL, `data[0:length]` is complete JSON, and `data[length]=='\0'`;
- `CMFA_BUFFER_TOO_SMALL`: `length` is the required JSON byte count excluding NUL, `data` contains no partial JSON and is ignored except `data[0]=='\0'` when capacity is non-zero;
- every other failure: `length=0`, and `data[0]=='\0'` when capacity is non-zero.

- [ ] **Step 2: Run host contract tests and verify RED**

```bash
node harmony/tools/test-native-host.mjs --case contract
```

Expected: missing public types/functions/backend callbacks and the public-function-count structure contract fails.

- [ ] **Step 3: Add the public functions**

```c
cmfa_status cmfa_proxy_groups(const cmfa_proxy_query_context *context,
                              uint8_t selectable_only,
                              cmfa_json_buffer *output,
                              cmfa_error *error);
cmfa_status cmfa_proxy_group(const cmfa_proxy_query_context *context,
                             const char *group_name,
                             cmfa_json_buffer *output,
                             cmfa_error *error);
cmfa_status cmfa_proxy_select(const cmfa_proxy_query_context *context,
                              const char *group_name,
                              const char *member_name,
                              cmfa_json_buffer *output,
                              cmfa_error *error);
```

Use fixed-width `uint8_t` rather than public C `bool`, so the existing C11 header smoke test needs no `stdbool.h` dependency; accept only `0` or `1`. Extend the hidden `cmfa_backend_api` with matching function pointers. Validate all caller-owned memory before borrowing the backend. Enforce the buffer semantics above and `length <= CMFA_MAX_PROXY_JSON_BYTES`. Errors are bounded stable messages with no raw names.

- [ ] **Step 4: Update host runner and structure contracts**

Update the exact public function list/count, header smoke test, backend completeness checks, and no-dlopen/export guards. Do not put raw Go symbols in public headers.

- [ ] **Step 5: Run contract tests and verify GREEN**

```bash
node harmony/tools/test-native-host.mjs --case contract
node --test harmony/tests/structure/phase1-bridge-contract.test.mjs
```

### Task 5: Bind the hidden C++ backend to the raw Go exports

**Files:**
- Modify: `harmony/entry/src/main/cpp/include/cmfa_mihomo_backend.h`
- Modify: `harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp`
- Modify: `harmony/tests/native/cmfa_mihomo_backend_test.cpp`
- Modify: `harmony/tools/test-native-host.mjs`

- [ ] **Step 1: Write failing backend wrapper tests**

Define strong test stubs for the three raw Go functions in `cmfa_mihomo_backend_test.cpp` and cover argument forwarding, output length, invalid raw output, buffer-too-small, shutdown, and error preservation. Stub payloads use generic synthetic names and are never printed. The three proxy exports are required strong symbols in production, matching the existing config/runtime export strategy; they are not optional weak TUN-style extensions.

- [ ] **Step 2: Run the mihomo-backend host case and verify RED**

```bash
node harmony/tools/test-native-host.mjs --case mihomo-backend
```

Expected: missing strong proxy export stubs/wrappers or backend callbacks.

- [ ] **Step 3: Add hidden wrappers and backend registrations**

Only `cmfa_mihomo_backend.cpp` may declare the three raw Go exports. Production registration fills the new backend callbacks. Host tests satisfy the strong declarations with local stubs. A production HAP missing any raw proxy export fails link/export inspection rather than degrading to `CMFA_CORE_UNAVAILABLE`.

- [ ] **Step 4: Run native host cases and verify GREEN**

```bash
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
```

---

## Chunk 3: Node-API Promise Surface and Strict ArkTS Decoder

### Task 6: Add asynchronous Node-API proxy exports

**Files:**
- Create: `harmony/entry/src/main/cpp/src/js_proxy.cpp`
- Create: `harmony/tests/native/js_proxy_napi_test.cpp`
- Modify: `harmony/entry/src/main/cpp/include/cmfa_napi.h`
- Modify: `harmony/entry/src/main/cpp/src/js_async.cpp`
- Modify: `harmony/entry/src/main/cpp/src/js_codec.cpp`
- Modify: `harmony/entry/src/main/cpp/src/js_core_module.cpp`
- Modify: `harmony/entry/src/main/cpp/CMakeLists.txt`
- Modify: `harmony/entry/src/main/cpp/types/libentry/Index.d.ts`
- Modify: `harmony/tools/test-native-host.mjs`
- Modify: `harmony/tests/native/shim/napi/native_api.h`
- Modify: `harmony/tests/structure/phase1-bridge-contract.test.mjs`

- [ ] **Step 1: Write failing NAPI tests and typed-export contracts**

Add `--case napi-proxy` to the host runner. Cover exact own-key validation for context objects, hash/generation/name limits, promise resolve/reject, 1 MiB output allocation, buffer-too-small, malformed UTF-8 JSON, env cleanup, queue failure, and no off-thread `napi_value` access. Update the exact `Index.d.ts` value/type export lists first so the structure test is RED.

Add `js_proxy.cpp` to the bridge contract's explicit native-source scan. Apply the same no-`dlopen`/`dlsym`, catch-all JS-boundary, async ownership, and exact-registration guards used for the existing NAPI source files; a new source file must not sit outside the source-level structure contract.

The raw `libentry.so` type is exact:

```ts
export interface ProxyQueryContext {
  profileHash: string;
  revisionHash: string;
  sessionHash: string | null;
  generation: number;
}
```

The only new native value exports are `queryProxyGroups`, `queryProxyGroup`, and `selectProxy`; each returns `Promise<string>`. Add `PROXY_GROUPS`, `PROXY_GROUP`, and `PROXY_SELECT` to `AsyncOp`, update `async_operation_name()` in `js_codec.cpp`, and update exact export/type arrays in the bridge structure contract.

- [ ] **Step 2: Run bridge/NAPI tests and verify RED**

```bash
node harmony/tools/test-native-host.mjs --case napi-proxy
node --test harmony/tests/structure/phase1-bridge-contract.test.mjs
```

Expected: the host runner rejects the absent `napi-proxy` case or fails to compile its missing test target, and the bridge structure contract fails because the exact native types/value exports and async operations are absent.

- [ ] **Step 3: Implement the three native Promise exports**

```ts
queryProxyGroups(context: ProxyQueryContext, selectableOnly: boolean): Promise<string>
queryProxyGroup(context: ProxyQueryContext, groupName: string): Promise<string>
selectProxy(context: ProxyQueryContext, groupName: string, memberName: string): Promise<string>
```

Decode inputs on the env thread, allocate a fixed bounded byte vector inside the async job, execute only C ABI functions on the worker thread, and create the JS string on the completion thread. Reuse existing async ownership/finalizer/error helpers. Never parse JSON or log names in C++.

- [ ] **Step 4: Register exact exports and CMake sources**

Keep probe exports behind the existing self-test guard. Node addon ELF exports remain the same fixed host-bridge allowlist; NAPI properties do not become public ELF `cmfa_*` symbols. Require `phase1-bridge-contract.test.mjs` to include `js_proxy.cpp` in its exact `typedSourceNames` authority and fail if the file is missing from that scan.

- [ ] **Step 5: Run host/structure tests and verify GREEN**

```bash
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/test-native-host.mjs --case napi-tun
node harmony/tools/test-native-host.mjs --case napi-proxy
node --test harmony/tests/structure/phase1-bridge-contract.test.mjs
```

Expected: all five named native-host cases and the bridge structure contract pass.

### Task 7: Decode native proxy JSON into typed ArkTS models

**Files:**
- Create: `harmony/shared/src/main/ets/core/CoreProxyModels.ets`
- Create: `harmony/core/src/main/ets/ProxyNativeCodec.ets`
- Create: `harmony/core/src/test/ProxyNativeCodec.test.ets`
- Modify: `harmony/shared/src/main/ets/core/CoreService.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/core/src/main/ets/CoreNativeAdapter.ets`
- Modify: `harmony/core/src/test/List.test.ets`
- Modify: `harmony/shared/src/test/ProfileManagement.test.ets`
- Modify: `harmony/shared/src/test/LocalRuntimeCoordinator.test.ets`
- Modify: `harmony/shared/src/test/fakes/ProfileFakes.ets`
- Modify: `harmony/entry/src/test/fakes/PresentationFakes.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/entry/src/ohosTest/ets/test/Phase3RuntimeFlow.test.ets`
- Modify: `harmony/entry/src/main/cpp/types/libentry/Index.d.ts`
- Modify: `harmony/tests/structure/phase1-arkts-module-boundary.test.mjs`

- [ ] **Step 1: Write failing strict decoder tests**

Cover exact schema/version/kind/own keys; context echo; arrays and primitive types; UTF-8 byte limits; counts; duplicate groups/members; selected invariants; unknown types; JSON cap; prototype/inherited-key rejection; and malformed native JSON. Assertions and thrown errors use operation/code/count only, never raw names or JSON.

- [ ] **Step 2: Run the core Hypium suite and verify RED**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony"
./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
```

Expected: the core suite fails because `ProxyNativeCodec`, its closed shared model surface, and the three `CoreNativeAdapter` methods do not exist.

- [ ] **Step 3: Add shared immutable proxy models**

Export these exact public shapes from `@cmfa/shared`:

```ts
export type CoreProxyType =
  | 'Direct'
  | 'Reject'
  | 'RejectDrop'
  | 'Compatible'
  | 'Pass'
  | 'PassRule'
  | 'Rematch'
  | 'Dns'
  | 'Relay'
  | 'Selector'
  | 'Fallback'
  | 'URLTest'
  | 'LoadBalance'
  | 'Shadowsocks'
  | 'ShadowsocksR'
  | 'Snell'
  | 'Socks5'
  | 'Http'
  | 'Vmess'
  | 'Vless'
  | 'Trojan'
  | 'Hysteria'
  | 'Hysteria2'
  | 'WireGuard'
  | 'Tuic'
  | 'Ssh'
  | 'Mieru'
  | 'AnyTLS'
  | 'Sudoku'
  | 'Masque'
  | 'TrustTunnel'
  | 'ShadowQuic'
  | 'OpenVPN'
  | 'Tailscale'
  | 'GostRelay';
export interface CoreProxyQueryContext {
  profileHash: string;
  revisionHash: string;
  sessionHash: string | null;
  generation: number;
}
export interface CoreProxyGroupRef { name: string; type: CoreProxyType; }
export interface CoreProxyNodeSummary { name: string; type: CoreProxyType; isGroup: boolean; selected: boolean; }
export interface CoreProxyGroupSnapshot { name: string; type: CoreProxyType; selectedName: string; nodes: CoreProxyNodeSummary[]; }
export interface CoreProxyGroupList { schemaVersion: '1.0.0'; kind: 'GROUP_LIST'; profileHash: string; revisionHash: string; sessionHash: string | null; generation: number; groups: CoreProxyGroupRef[]; }
export interface CoreProxyGroupResult { schemaVersion: '1.0.0'; kind: 'GROUP_SNAPSHOT'; profileHash: string; revisionHash: string; sessionHash: string | null; generation: number; group: CoreProxyGroupSnapshot; }
export interface CoreProxySelectionApplied { schemaVersion: '1.0.0'; kind: 'SELECTION_APPLIED'; profileHash: string; revisionHash: string; sessionHash: string | null; generation: number; previousName: string; group: CoreProxyGroupSnapshot; }
```

Clone arrays and objects at service boundaries. Do not add endpoint/credential fields.

- [ ] **Step 4: Implement the exact decoder**

`ProxyNativeCodec.ets` parses the raw native string and rejects unknown/missing keys or bounds drift. It returns closed typed values only. A decoder error maps to `CoreError` code `PROXY_BRIDGE_INVALID` with no payload echo.

- [ ] **Step 5: Extend `CoreService` and `CoreNativeAdapter`**

Add:

```ts
queryProxyGroups(context: CoreProxyQueryContext, selectableOnly: boolean): Promise<CoreProxyGroupList>
queryProxyGroup(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyGroupResult>
selectProxy(context: CoreProxyQueryContext, groupName: string, memberName: string): Promise<CoreProxySelectionApplied>
```

The adapter wraps synchronous throws and Promise rejections through the existing error normalizer, then decodes. Raw native strings never leave `@cmfa/core`.

Update every current `CoreService` implementation/fake listed in this task with deterministic proxy methods that either return injected typed results or reject with a fixed `PROXY_RUNTIME_NOT_READY` error. Run `rg "implements CoreService" harmony -g '*.ets'` and require no unhandled implementation remains. This compile-ripple update is mechanical and must not make unrelated profile/runtime tests depend on proxy names.

- [ ] **Step 6: Run ArkTS tests and verify GREEN**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony"
./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
cd "$CMFA_REPO_ROOT"
node --test harmony/tests/structure/phase1-arkts-module-boundary.test.mjs
rg "implements CoreService" harmony -g '*.ets'
```

Expected: core and shared pass completely; Entry has no new failure beyond the two exact Plan A allowlist failures named in Task 8 Step 5; the module-boundary contract proves that only interfaces/models—not the concrete adapter—are exported; every implementation printed by `rg` was explicitly updated in this task.

---

## Chunk 4: Export, Package, and Host Runtime Contract Evidence

### Task 8: Lock raw exports and packaged-native evidence

**Files:**
- Modify: `harmony/tests/bin/inspect-native-lib.mjs`
- Modify: `harmony/tests/bin/build-phase1-native.mjs`
- Modify: `harmony/tools/lib/native-provenance.mjs`
- Modify: `harmony/tests/structure/phase0-proof-contract.test.mjs`
- Modify: `harmony/tests/structure/phase1-proof-contract.test.mjs`
- Modify: `harmony/tests/structure/phase1-native-build-contract.test.mjs`
- Modify: `harmony/tests/structure/phase1-bridge-contract.test.mjs`
- Modify: `harmony/tests/structure/go-ohos-build-contract.test.mjs`
- Modify: `harmony/tests/bin/inspect-phase4-packages.mjs`
- Modify: `harmony/tests/structure/phase4-package-contract.test.mjs`
- Create: `harmony/tests/structure/plan-b-proxy-contract.test.mjs`
- Create: `docs/harmony/native-proxy-contract.md`
- Generated: `harmony/artifacts/phase1-native-provenance.json`

- [ ] **Step 1: Write failing export/provenance contracts**

Require the exact three new raw Go exports in `mihomoCore.requiredExports`, keep the Node addon export allowlist unchanged, require the three NAPI property names and shared method names, forbid endpoint/credential fields, and require every proxy error/detail/log path to omit raw group/member values.

- [ ] **Step 2: Run focused structure tests and verify RED**

```bash
node --test \
  harmony/tests/structure/phase0-proof-contract.test.mjs \
  harmony/tests/structure/phase1-proof-contract.test.mjs \
  harmony/tests/structure/phase1-native-build-contract.test.mjs \
  harmony/tests/structure/phase1-bridge-contract.test.mjs \
  harmony/tests/structure/plan-b-proxy-contract.test.mjs
```

Expected: the focused run fails because the new exact raw-export/provenance rules, native property/method authorities, privacy guard, and Plan B contract test are absent.

- [ ] **Step 3: Update canonical native export authorities**

Update every exact export list and provenance validator from one shared ordered definition where the current tooling permits it. A missing or extra proxy export fails package inspection. Do not add public symbols to the Node addon.

- [ ] **Step 4: Add safe Plan B documentation**

Document schemas, limits, error codes, host test counts, and package identities. Use only counts and hashes in examples; do not include real or synthetic node names that resemble endpoints.

- [ ] **Step 5: Run complete Plan B host verification**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go test ./... -count=1

cd "$CMFA_REPO_ROOT"
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/test-native-host.mjs --case napi-tun
node harmony/tools/test-native-host.mjs --case napi-proxy

node --test \
  harmony/tests/structure/phase0-proof-contract.test.mjs \
  harmony/tests/structure/phase1-proof-contract.test.mjs \
  harmony/tests/structure/phase1-native-build-contract.test.mjs \
  harmony/tests/structure/phase1-bridge-contract.test.mjs \
  harmony/tests/structure/phase1-arkts-module-boundary.test.mjs \
  harmony/tests/structure/plan-b-proxy-contract.test.mjs \
  harmony/tests/structure/signing-isolation.test.mjs

cd "$CMFA_REPO_ROOT/harmony"
./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

Entry may contain only these two pre-existing errors, whose exact names are pinned by Plan A Task 6 (`docs/superpowers/plans/2026-08-21-harmonyos-subscription-validation-compatibility.md`, Step 1) and summarized by `docs/harmony/subscription-validation-compatibility.md` key `step1_entry_only_allowlist_failures`:

```text
extensionFactoryUsesTheExactInjectedRegistryForUnexpectedFailureCleanup
nonSharedStopResolvesWithoutTouchingTheSharedRegistry
```

Every new Plan B test must be `Success`; any other Entry error fails the gate.

`entry@ohosTest assembleHap` is a compile/package gate for the modified `Phase3RuntimeFlow.test.ets` fake only. It does not claim that `src/ohosTest` executed on a Simulator or device; Plan B adds no interactive device proof.

- [ ] **Step 6: Build and inspect a fresh signed HAP**

Use the exact secure workflow documented in Plan A Task 6, Step 2 (`docs/superpowers/plans/2026-08-21-harmonyos-subscription-validation-compatibility.md`): DevEco produces one complete local `app.signingConfigs` object; capture it in a mode-0700/mode-0600 protected temp; prove the current tracked profile equals the safe empty `HEAD` bytes; inject only `app.signingConfigs` through an in-memory `apply_patch` wrapper; run the build in `try/finally`; restore the exact safe bytes and hash; then move the captured config to Trash. If DevEco has no complete local config, pause for the user to regenerate automatic signing—never reconstruct credentials or use a name-only placeholder. Run:

```bash
node harmony/tests/bin/build-phase1-native.mjs --out harmony/artifacts/phase1-native-provenance.json
node harmony/tests/bin/build-phase1-native.mjs --validate harmony/artifacts/phase1-native-provenance.json
node harmony/tests/bin/inspect-hap.mjs \
  --hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --manifest harmony/artifacts/phase1-native-provenance.json \
  --build-kind production
```

Finally restore the exact safe `build-profile.json5`, move captured signing config to Trash, and require signing isolation to pass without a process shim.

- [ ] **Step 7: Record the Plan B gate**

Plan B passes when the synthetic real-mihomo Go integration, all native/ArkTS decoders, raw export inspection, signed HAP inspection, and strict privacy contracts pass. This is host plus packaged-native contract evidence. It does not claim that the current physical-device subscription was queried, nor does it claim a UI page, durable selection, VPN replay, or physical HTTPS success; those remain Plan C/D gates required for the user's final objective.

---

## Plan B Completion Criteria

1. The production mihomo adapter returns selectable group names, deterministic ordered members, nested-group flags, and current selection from a loaded synthetic real-mihomo runtime through the typed Harmony `CoreService`; current-subscription device evidence remains a Plan D gate.
2. A valid selector patch is confirmed by a post-patch runtime query and closes only stale connections associated with that group.
3. Missing/non-selector groups, missing members, malformed names/JSON, duplicate members, bounds overflow, not-ready runtime, stale context, and buffer errors fail closed with allowlisted errors.
4. Go, C ABI, hidden backend, Node-API, ArkTS decoder, bridge, export, package, and signing-isolation tests pass.
5. A fresh signed HAP contains the exact new raw Go exports while the Node addon keeps its existing public ELF allowlist.
6. No Plan B log, error, report, or proof artifact contains raw group/node names, endpoints, credentials, subscription data, config paths, device IDs, or signing material.
