# HarmonyOS Proxy Delay Test Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Clash Meta-style action that tests every testable terminal node in the currently displayed HarmonyOS proxy group, progressively shows connection/HTTP delay, and identifies the fastest usable node without changing selection.

**Architecture:** A single generation-bound Go job owns discovery, URL choice, the 16-worker pool, 5-second node deadlines, cancellation, aggregation, and immutable JSON snapshots. The fixed C ABI, C++ backend, Node-API, and strict Core ArkTS codec carry start/read/cancel operations; the Shared service owns routing plus stopped-runtime lease lifetime, while `ProxyViewModel` polls every 250 ms and ArkUI renders only cloned session state.

**Tech Stack:** Go 1.24, mihomo v1.19.29, cgo, C11/C++17 ABI contracts, HarmonyOS Node-API, ArkTS/Hypium, ArkUI, Node.js structure/device-proof tests, Hvigor, HDC.

**Spec:** `docs/superpowers/specs/2026-08-23-harmonyos-proxy-delay-test-design.md`

**Execution workflow:** Use `@superpowers:test-driven-development` for every task, `@superpowers:subagent-driven-development` for execution, and `@superpowers:verification-before-completion` before reporting completion.

**Dirty-worktree constraint:** This worktree contains extensive unrelated uncommitted work. Preserve it. Do not reset, restore, clean, overwrite, or stage whole overlapping files. This plan intentionally contains no commit steps because the user has not authorized commits.

**Privacy rule:** Raw group/node labels may exist only in private in-process request/snapshot/UI memory. Never put labels, endpoints, provider URLs, credentials, subscription content, deterministic label hashes, or raw layout data in logs, durable storage, build reports, or device proofs.

**Command convention:** Every command starts at the repository root. Commands that need Go dependencies derive the repository root and use the pinned offline module cache.

**File-ownership map:**

- `harmony/core/go/internal/proxygroups/delay_models.go` owns bounded delay-job enums, snapshots, validation, cloning, and JSON encoding only.
- `harmony/core/go/internal/proxygroups/delay_job.go` owns one active job, scheduling, cancellation, deadlines, progress, and fastest calculation only.
- `harmony/core/go/internal/proxygroups/delay_mihomo.go` owns mihomo group/provider/node discovery and private URL/expected-status resolution only.
- `harmony/shared/src/main/ets/core/CoreProxyDelayModels.ets` and `harmony/core/src/main/ets/ProxyDelayNativeCodec.ets` own the strict Core ArkTS contract and decoding only.
- `harmony/shared/src/main/ets/proxy/ProxyDelayModels.ets` owns package-neutral application delay models/clones; `ProxyService.ets` owns routing, lease retention, and finalization.
- `ProxyPresentationModels.ets`, `ProxyViewModel.ets`, and `ProxiesPage.ets` own presentation state, polling/lifecycle, and rendering respectively.
- Tracked device-proof files store only bounded counts, booleans, package hashes, and aggregate delay statistics.

---

## Chunk 1: Core-native Delay Job

### Task 1: Define the closed, bounded Go delay snapshot contract

**Files:**
- Create: `harmony/core/go/internal/proxygroups/delay_models.go`
- Create: `harmony/core/go/internal/proxygroups/delay_models_test.go`

- [ ] **Step 1: Write failing model and JSON tests**

Pin these exact public values and bounds:

```go
const (
    DelaySchemaVersion  = "1.0.0"
    MaxDelayJobIDBytes  = 32
    DelayWorkerCount    = 16
    DelayNodeTimeout    = 5 * time.Second
    DefaultDelayTestURL = "https://www.gstatic.com/generate_204"
)

type DelayJobState string // RUNNING | COMPLETED | CANCELLED | FAILED
type DelayNodeState string // WAITING | TESTING | AVAILABLE | TIMEOUT | FAILED | CANCELLED | UNSUPPORTED
type DelayURLSource string // PROVIDER | FALLBACK
```

Test exact own JSON fields, `jobId` pattern `^[0-9a-f]{32}$`, `QueryContext` echo, group/node name bounds inherited from `models.go`, maximum 1024 nodes, closed proxy types, ordered contiguous indexes, positive `delayMs` only for `AVAILABLE`, null delay otherwise, one-or-zero fastest flags, lowest-index tie breaking, every counter equalling its node-state count, `completedCount` excluding `WAITING`/`TESTING`, terminal jobs containing no live nodes, and the existing 1 MiB JSON cap. Unknown fields, unknown states, endpoint/URL/credential fields, and malformed count combinations fail closed.

- [ ] **Step 2: Run the focused test and verify RED**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./internal/proxygroups -run 'TestDelay(Model|Snapshot|JSON)' -count=1
```

Expected: compile failure because the delay types and constructors do not exist.

- [ ] **Step 3: Implement immutable snapshot values and validation**

Use explicit structs, never `map[string]any`:

```go
type DelayNodeResult struct {
    Index   int            `json:"index"`
    Name    string         `json:"name"`
    Type    string         `json:"type"`
    State   DelayNodeState `json:"state"`
    DelayMs *uint16        `json:"delayMs"`
    Source  *DelayURLSource `json:"source"`
    Fastest bool           `json:"fastest"`
}

type DelayTestSnapshot struct {
    SchemaVersion    string            `json:"schemaVersion"`
    JobID            string            `json:"jobId"`
    State            DelayJobState     `json:"state"`
    ProfileHash      string            `json:"profileHash"`
    RevisionHash     string            `json:"revisionHash"`
    SessionHash      *string           `json:"sessionHash"`
    Generation       uint64            `json:"generation"`
    GroupName        string            `json:"groupName"`
    TotalCount       int               `json:"totalCount"`
    TestableCount    int               `json:"testableCount"`
    CompletedCount   int               `json:"completedCount"`
    AvailableCount   int               `json:"availableCount"`
    TimeoutCount     int               `json:"timeoutCount"`
    FailedCount      int               `json:"failedCount"`
    CancelledCount   int               `json:"cancelledCount"`
    UnsupportedCount int               `json:"unsupportedCount"`
    FastestNodeIndex *int              `json:"fastestNodeIndex"`
    Nodes            []DelayNodeResult `json:"nodes"`
}
```

Construct snapshots through validating constructors, deep-copy the session hash/delay/source/index pointers and node slice, and marshal only a validated clone. `source` is non-null `PROVIDER`/`FALLBACK` for every testable node, including queued or cancelled nodes whose URL was already resolved; it is JSON `null` only for `UNSUPPORTED` nodes because no request URL exists. Do not include raw failure text, URL, provider identity, address, port, credentials, or selector state.

- [ ] **Step 4: Run the model tests and verify GREEN**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
gofmt -w internal/proxygroups/delay_models.go internal/proxygroups/delay_models_test.go
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./internal/proxygroups -run 'TestDelay(Model|Snapshot|JSON)' -count=1
git -C "$CMFA_REPO_ROOT" diff --check -- \
  harmony/core/go/internal/proxygroups/delay_models.go \
  harmony/core/go/internal/proxygroups/delay_models_test.go
```

Expected: focused tests pass and `git diff --check` is empty.

### Task 2: Implement the 16-worker job manager with reliable cancellation

**Files:**
- Create: `harmony/core/go/internal/proxygroups/delay_job.go`
- Create: `harmony/core/go/internal/proxygroups/delay_job_test.go`

- [ ] **Step 1: Write deterministic failing scheduler tests**

Inject a registry, ID source, and per-node probe so tests use barriers/fake clocks rather than sleeping. Cover one active job per manager, start cancelling and draining an older job, exactly 16 concurrent probes at peak, ordered snapshots despite reverse completion, progressive `WAITING -> TESTING -> terminal` publication, independent 5-second child contexts, positive delay, zero-delay rejection, timeout versus root cancellation classification, queued and active cancellation, retained partial results, idempotent cancel, read side-effect freedom, no publication after the final cancelled snapshot, fastest recalculation and original-index tie break, all-failure completion, and invalid/missing job IDs. Add table tests proving that any profile, revision, session, generation, or group mismatch passed to `InvalidateActiveIfNot` cancels and drains the active job, while an exact match leaves it running.

- [ ] **Step 2: Run the job tests and verify RED**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./internal/proxygroups -run 'TestDelayJob' -count=1
```

Expected: compile failure because `DelayJobManager` is missing.

- [ ] **Step 3: Implement the minimal manager surface**

```go
type DelayProbe func(context.Context) (uint16, error)

type DelayRuntimeNode struct {
    Name    string
    Type    string
    IsGroup bool
    Source  *DelayURLSource
    Probe   DelayProbe
}

type DelayRuntimeRegistry interface {
    DelayNodes(groupName string) ([]DelayRuntimeNode, error)
}

func (m *DelayJobManager) Start(ctx QueryContext, groupName string) (DelayTestSnapshot, error)
func (m *DelayJobManager) Read(jobID string) (DelayTestSnapshot, error)
func (m *DelayJobManager) Cancel(jobID string) (DelayTestSnapshot, error)
func (m *DelayJobManager) CancelActiveAndDrain() error
func (m *DelayJobManager) InvalidateActiveIfNot(ctx QueryContext, groupName string) error
```

`Start` validates before mutation, cancels/drains the prior job, creates a crypto-random 128-bit lowercase-hex job ID through an injectable generator, discovers once, marks nested/built-in nodes `UNSUPPORTED`, and launches exactly 16 fixed workers. Each worker uses `context.WithTimeout(root, 5*time.Second)`. `Cancel` cancels root, waits for the worker `WaitGroup`, marks queued/interrupted work `CANCELLED`, publishes one final clone, and returns it. `InvalidateActiveIfNot` compares the complete bound `QueryContext` and group, then cancels/drains on any mismatch; Chunk 2 additionally calls unconditional `CancelActiveAndDrain` before configuration/local/TUN replacement paths. Never hold the manager mutex while calling a probe or waiting for workers.

- [ ] **Step 4: Run focused and race tests and verify GREEN**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
gofmt -w internal/proxygroups/delay_job.go internal/proxygroups/delay_job_test.go
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./internal/proxygroups -run 'TestDelayJob' -count=1
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test -race ./internal/proxygroups -run 'TestDelayJob' -count=1
```

Expected: functional and race tests pass with a measured concurrency peak of 16.

### Task 3: Resolve real mihomo nodes, providers, URLs, and expected status

**Files:**
- Create: `harmony/core/go/internal/proxygroups/delay_mihomo.go`
- Create: `harmony/core/go/internal/proxygroups/delay_mihomo_integration_test.go`
- Modify: `harmony/core/go/internal/proxygroups/mihomo.go`
- Modify: `harmony/core/go/internal/proxygroups/mihomo_integration_test.go`

- [ ] **Step 1: Write failing production-adapter and real-runtime tests**

Cover exact group member order; duplicate terminal-name failure; nested group and `Direct`, `Reject`, `RejectDrop`, `Pass`, `PassRule`, `Rematch`, and `Dns` as `UNSUPPORTED`; supported terminal types as testable; first containing provider in `group.Providers()` order; valid non-empty `HealthCheckURL()` preference; invalid/empty provider URL fallback; provider expected range 200-299; fallback expected range exactly 204; and no selector mutation before/after the job.

The subprocess integration test starts a credential-free local `httptest` origin plus test-only SOCKS5 forwarder, loads a real mihomo configuration with a selector, file/compatible provider, two SOCKS5 terminals, a nested selector, and built-ins, then proves at least one positive provider-URL delay and an unchanged `Now()` selection. A second run cancels while the controlled origin blocks and proves terminal cancellation. Discard child stdout/stderr so synthetic names and URLs cannot escape on failure.

- [ ] **Step 2: Run the real-adapter tests and verify RED**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./internal/proxygroups -run 'Test(MihomoDelay|DelayServiceWithRealMihomo)' -count=1
```

Expected: missing delay registry/probe resolution failures.

- [ ] **Step 3: Implement public-API-only mihomo discovery**

Use only `tunnel.Proxies()`, `outboundgroup.ProxyGroup.Proxies()`, `outboundgroup.ProxyGroup.Providers()`, `provider.ProxyProvider.Proxies()`, `provider.ProxyProvider.HealthCheckURL()`, and `constant.Proxy.URLTest`. Match a member to the first provider whose ordered `Proxies()` contains that exact member/name; do not range `tunnel.Providers()` for ordering. Validate provider URLs with `net/url` and accept only non-empty HTTP/HTTPS URLs with a host.

Build the private probes with:

```go
providerExpected, _ := utils.NewUnsignedRanges[uint16]("200-299")
fallbackExpected, _ := utils.NewUnsignedRanges[uint16]("204")
expected := fallbackExpected
if source == DelayURLSourceProvider {
    expected = providerExpected
}
delay, err := proxy.URLTest(ctx, privateURL, expected)
```

Never use reflection, `MarshalJSON`, provider serialization, private config parsing, or concrete-provider fields to recover expected-status. Keep URLs captured only inside the Core-private probe closure and never copy them into a snapshot or error.

- [ ] **Step 4: Run the complete Go gate and verify GREEN**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
gofmt -w internal/proxygroups/delay_mihomo.go internal/proxygroups/delay_mihomo_integration_test.go \
  internal/proxygroups/mihomo.go internal/proxygroups/mihomo_integration_test.go
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./internal/proxygroups -count=1
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./... -count=1
```

Expected: all delay tests and the existing Go suite pass; the selector remains unchanged.

---

## Chunk 2: Go Export, Fixed C ABI, Backend, and Node-API

### Task 4: Export bounded delay start/read/cancel JSON from Go

**Files:**
- Modify: `harmony/core/go/cmd/cmfa_core/main.go`
- Modify: `harmony/core/go/cmd/cmfa_core/main_test.go`
- Modify: `harmony/core/go/cmd/cmfa_core/proxy_exports_test.go`
- Create: `harmony/core/go/cmd/cmfa_core/proxy_delay_exports_test.go`

- [ ] **Step 1: Write failing raw-export and mutation-drain tests**

Add a replaceable `proxyDelayService` seam backed in production by one process-wide `proxygroups.DelayJobManager`. Cover nil hashes/group/job/output/length pointers, invalid UTF-8/control/oversized group names, exact lowercase 32-hex job IDs, invalid query identity/generation, 1 MiB response bound, exact NUL termination, buffer-too-small required length with no partial JSON, zeroed failure outputs, success/error mapping, panic containment, read/cancel idempotence, and no request/snapshot labels in error strings.

For `cmfa_mihomo_load_config_v1`, `cmfa_mihomo_start_local_v1`, `cmfa_mihomo_stop_v1`, `cmfa_mihomo_start_tun_v1`, `cmfa_mihomo_stop_tun_v1`, and shutdown, write ordering tests proving `CancelActiveAndDrain()` completes before the existing mutation callback is invoked. A drain failure returns `CMFA_BACKEND_ERROR`, leaves outputs zeroed, and prevents the mutation.

- [ ] **Step 2: Run focused Go exports and verify RED**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./cmd/cmfa_core -run 'Test(ProxyDelay|DelayDrain)' -count=1
```

Expected: compile failures for the delay service seam and raw symbols.

- [ ] **Step 3: Add the three raw Go symbols and reuse the strict buffer writer**

Export:

```text
cmfa_mihomo_proxy_delay_start_v1
cmfa_mihomo_proxy_delay_snapshot_v1
cmfa_mihomo_proxy_delay_cancel_v1
```

`start` accepts profile/revision/optional-session hashes, generation, and group name. `snapshot`/`cancel` accept only the opaque job ID. All accept caller-owned output/capacity/length and `cmfa_error`. Reuse the existing proxy raw-export validation and buffer semantics; marshal only a validated `DelayTestSnapshot`. Map missing/stale jobs to `CMFA_INVALID_STATE`, malformed input to `CMFA_INVALID_ARGUMENT`/`CMFA_INVALID_UTF8`/`CMFA_OUT_OF_RANGE`, overflow to `CMFA_OUT_OF_RANGE`, and internal failures to `CMFA_BACKEND_ERROR`. Error text is a closed code such as `PROXY_DELAY_JOB_NOT_FOUND` or `PROXY_DELAY_BRIDGE_INVALID`, never a request value.

- [ ] **Step 4: Add the fail-closed Core mutation gate**

Create one helper that calls `CancelActiveAndDrain()` and use it before every configuration/local/TUN mutation listed in Step 1. The helper must run outside unrelated runtime mutexes, must not log the job or node data, and must preserve existing output initialization on failure. Validation-only and snapshot-only functions remain side-effect free.

- [ ] **Step 5: Run focused and complete Go tests and verify GREEN**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
gofmt -w cmd/cmfa_core/main.go cmd/cmfa_core/main_test.go \
  cmd/cmfa_core/proxy_exports_test.go cmd/cmfa_core/proxy_delay_exports_test.go
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./cmd/cmfa_core -run 'Test(ProxyDelay|DelayDrain)' -count=1
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test ./... -count=1
```

Expected: raw-export, ordering, and full Go tests pass.

### Task 5: Extend the fixed C ABI and hidden mihomo backend

**Files:**
- Modify: `harmony/core/abi/include/cmfa_types.h`
- Modify: `harmony/core/abi/include/cmfa_host.h`
- Modify: `harmony/core/abi/include/cmfa_core.h`
- Modify: `harmony/core/abi/src/cmfa_contract.cpp`
- Modify: `harmony/entry/src/main/cpp/src/cmfa_mihomo_backend.cpp`
- Modify: `harmony/tests/native/cmfa_contract_test.cpp`
- Modify: `harmony/tests/native/cmfa_mihomo_backend_test.cpp`
- Modify: `harmony/tools/test-native-host.mjs`
- Modify: `harmony/tools/lib/native-provenance.mjs`
- Modify: `harmony/tests/structure/phase1-bridge-contract.test.mjs`
- Modify: `harmony/tests/structure/plan-b-proxy-contract.test.mjs`

- [ ] **Step 1: Write failing C contract and backend tests**

Pin `CMFA_MAX_PROXY_DELAY_JOB_ID_BYTES` to 33 including NUL. Test exact public declarations/function count, backend callback completeness, initialization/shutdown borrowing, valid query/group/job forwarding, invalid job IDs, null buffers, too-small buffers, backend overrun/non-NUL output, canary preservation, response cap, unknown status rejection, error preservation, and `data[0]=='\0'` plus `length==0` on every non-buffer-too-small failure.

The hidden backend test defines strong stubs for all three raw Go symbols. Synthetic labels/URLs stay in memory and are never printed.

- [ ] **Step 2: Run host tests and verify RED**

```bash
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
```

Expected: missing public functions, backend callbacks, and raw wrappers.

- [ ] **Step 3: Add the fixed public and hidden backend surfaces**

Add these public functions:

```c
cmfa_status cmfa_proxy_delay_start(const cmfa_proxy_query_context *context,
                                   const char *group_name,
                                   cmfa_json_buffer *output,
                                   cmfa_error *error);
cmfa_status cmfa_proxy_delay_snapshot(const char *job_id,
                                      cmfa_json_buffer *output,
                                      cmfa_error *error);
cmfa_status cmfa_proxy_delay_cancel(const char *job_id,
                                    cmfa_json_buffer *output,
                                    cmfa_error *error);
```

Extend `cmfa_backend_api` with matching callbacks and register them in `cmfa_mihomo_backend.cpp`. The backend wrappers call only the three required strong raw Go symbols. Reuse the existing `cmfa_proxy_query_context` and `cmfa_json_buffer`; do not add variable-layout structs or allocated strings. Preserve the existing exact success/buffer-too-small/failure semantics and reject any backend output larger than `CMFA_MAX_PROXY_JSON_BYTES`.

- [ ] **Step 4: Update header smoke tests and exact contract inventories**

Update the C11/C++17 header smoke source, exact exported-function list/count, backend size/completeness tests, strong-symbol expectations, and no-`dlopen`/visibility contracts. In `native-provenance.mjs`, preserve the existing exact `RAW_PROXY_EXPORTS` Plan B authority and add a disjoint exact `RAW_PROXY_DELAY_EXPORTS` containing only the three new raw delay symbols; include both sets in sorted `CORE_EXPORTS`. Update Plan B tests to prove its old authority remains exact/disjoint and bridge tests to consume the new delay authority. Production public headers must not expose `cmfa_mihomo_*` names.

- [ ] **Step 5: Run C/backend contracts and verify GREEN**

```bash
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node --test \
  harmony/tests/structure/phase1-bridge-contract.test.mjs \
  harmony/tests/structure/plan-b-proxy-contract.test.mjs
```

Expected: all fixed ABI, hidden backend, and structure contracts pass.

### Task 6: Add strict promise-based Node-API delay operations

**Files:**
- Modify: `harmony/entry/src/main/cpp/include/cmfa_napi.h`
- Modify: `harmony/entry/src/main/cpp/src/js_proxy.cpp`
- Modify: `harmony/entry/src/main/cpp/src/js_async.cpp`
- Modify: `harmony/entry/src/main/cpp/src/js_codec.cpp`
- Modify: `harmony/entry/src/main/cpp/src/js_core_module.cpp`
- Modify: `harmony/entry/src/main/cpp/src/addon_init.cpp`
- Modify: `harmony/entry/src/main/cpp/types/libentry/Index.d.ts`
- Modify: `harmony/tests/native/js_proxy_napi_test.cpp`
- Modify: `harmony/tests/native/shim/napi/native_api.h` only if a newly exercised standard Node-API symbol is absent

- [ ] **Step 1: Write failing Node-API tests**

Cover exact arity, missing addon state, plain-object and constrained ArkTS data-class query contexts, null/custom/poisoned prototypes, exact own keys, lowercase hashes, safe positive generation, group-name bounds, 32-hex job IDs, promise queue failure, worker success/error, 1 MiB allocation cap, start/read/cancel races, cancellation during environment cleanup, one resolve/reject only, no cross-thread Node-API use, and catch-all boundaries. Test only synthetic payloads and assert no raw payload appears in error values.

- [ ] **Step 2: Run the Node-API host test and verify RED**

```bash
node harmony/tools/test-native-host.mjs --case napi-proxy
```

Expected: the three JS exports/async operations are absent.

- [ ] **Step 3: Extend the async operation model**

Add `PROXY_DELAY_START`, `PROXY_DELAY_SNAPSHOT`, and `PROXY_DELAY_CANCEL` to `AsyncOp`; add one bounded `proxy_delay_job_id` field to `AsyncInput`; and reuse `AsyncResult.string_value`. The worker calls only the public C ABI into a bounded vector, then the environment-thread completion converts the owned UTF-8 JSON string to JavaScript. No Node-API call occurs on the worker thread.

- [ ] **Step 4: Register the JS and TypeScript declarations**

Expose exactly:

```ts
export declare function startProxyDelayTest(context: ProxyQueryContext, groupName: string): Promise<string>;
export declare function readProxyDelayTest(jobId: string): Promise<string>;
export declare function cancelProxyDelayTest(jobId: string): Promise<string>;
```

`js_proxy.cpp` validates arguments synchronously, starts the async job, catches every C++ exception, and maps only closed `CoreError` metadata. `js_core_module.cpp` registers the new functions next to the existing proxy functions.

- [ ] **Step 5: Run Node-API and complete native host gates and verify GREEN**

```bash
node harmony/tools/test-native-host.mjs --case napi-proxy
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/test-native-host.mjs --case napi-tun
node --test \
  harmony/tests/structure/phase1-bridge-contract.test.mjs \
  harmony/tests/structure/plan-b-proxy-contract.test.mjs
```

Expected: every native host binary passes with no leaks, double delivery, or boundary error.

---

## Chunk 3: Strict ArkTS Contract, Shared Routing, Lease, and Mutation Drain

### Task 7: Decode and deep-clone strict Core delay snapshots

**Files:**
- Create: `harmony/shared/src/main/ets/core/CoreProxyDelayModels.ets`
- Modify: `harmony/shared/src/main/ets/core/CoreService.ets`
- Modify: `harmony/shared/Index.ets`
- Create: `harmony/core/src/main/ets/ProxyDelayNativeCodec.ets`
- Modify: `harmony/core/src/main/ets/CoreNativeAdapter.ets`
- Create: `harmony/core/src/test/ProxyDelayNativeCodec.test.ets`
- Modify: `harmony/core/src/test/CoreTunRuntime.test.ets`
- Modify: `harmony/core/src/test/List.test.ets`
- Modify: `harmony/shared/src/test/ProxyModels.test.ets`
- Modify: `harmony/shared/src/test/ProfileManagement.test.ets`
- Modify: `harmony/shared/src/test/LocalRuntimeCoordinator.test.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing Core model/codec/adapter tests**

Test exact schema/kind/keys, 1 MiB raw UTF-8 bound, 32-hex job ID, closed job/node/source enums, nullable source only for `UNSUPPORTED`, exact hash/session/generation/group validation, 1024-node bound, contiguous ordered indexes, state/delay/source/fastest invariants, recomputed counters, one fastest index/flag pair, terminal completeness, unknown/prototype-poisoned payload rejection, deep clones, start expectation matching context/group, and read/cancel expectation matching job ID. Mutating the native request or returned object after invocation must not mutate adapter state/results.

- [ ] **Step 2: Run Core/shared Hypium and verify RED**

```bash
cd harmony
./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: missing delay models/codec/CoreService methods.

- [ ] **Step 3: Implement closed Core models and clone constructors**

Define `CoreProxyDelayJobState`, `CoreProxyDelayNodeState`, `CoreProxyDelayURLSource`, `CoreProxyDelayNodeResult`, and `CoreProxyDelaySnapshot` mirroring the validated Go JSON shape. `CoreService` gains:

```ts
startProxyDelayTest(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyDelaySnapshot>;
readProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot>;
cancelProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot>;
```

Every public constructor/clone allocates a new node array and nested values. Keep this model session-only; add no repository/RDB serializer. Add inert delay methods to the `CoreService` test doubles in `ProfileManagement.test.ets` and `LocalRuntimeCoordinator.test.ets` in the same RED/GREEN task so the shared module remains compilable.

- [ ] **Step 4: Implement the strict JSON codec and native adapter calls**

`ProxyDelayNativeCodec.ets` parses with exact-key plain-object validation modeled on `ProxyNativeCodec.ets`, then independently recomputes every invariant rather than trusting counts. `CoreNativeAdapter` clones inputs, invokes `startProxyDelayTest/readProxyDelayTest/cancelProxyDelayTest` from `libentry.so`, normalizes errors through `wrapNativeAsync`, decodes, verifies the expected request identity/job, and returns another deep clone.

- [ ] **Step 5: Run focused and full Core/shared tests and verify GREEN**

```bash
cd harmony
./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: strict decoder, adapter, existing Core, and shared contract tests pass.

### Task 8: Carry running-session delay commands through the VPN command bus

**Files:**
- Create: `harmony/shared/src/main/ets/proxy/ProxyDelayModels.ets`
- Modify: `harmony/shared/src/main/ets/proxy/ProxyModels.ets`
- Modify: `harmony/shared/src/main/ets/proxy/ProxyPorts.ets`
- Modify: `harmony/shared/src/main/ets/proxy/VpnProxyCommandBus.ets`
- Modify: `harmony/shared/src/main/ets/proxy/VpnProxyRuntimeHandler.ets`
- Modify: `harmony/shared/Index.ets`
- Create: `harmony/shared/src/test/ProxyDelayModels.test.ets`
- Modify: `harmony/shared/src/test/ProxyModels.test.ets`
- Modify: `harmony/shared/src/test/ProxyService.test.ets`
- Modify: `harmony/shared/src/test/VpnProxyCommandBus.test.ets`
- Modify: `harmony/shared/src/test/VpnProxyRuntimeHandler.test.ets`
- Modify: `harmony/shared/src/test/VpnRuntimeCoordinator.test.ets`
- Modify: `harmony/shared/src/test/List.test.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/entry/src/test/VpnExtensionComposition.test.ets`
- Modify: `harmony/entry/src/test/fakes/PresentationFakes.ets`

- [ ] **Step 1: Write failing application-model, command-bus, and handler tests**

Test closed/deep-cloned application snapshots, identity/group/generation/job binding, new rejected codes `PROXY_DELAY_TEST_FAILED` and `PROXY_DELAY_DRAIN_FAILED`, start/read/cancel command clones, missing/stale binding rejection, captured-epoch invalidation, handler Core context hashing, progressive reads, terminal snapshots, idempotent cancel, one running job per handler, and no selection repository reads/writes or selector calls during a delay job.

Lifecycle tests must prove handler activation, invalidation, deactivation, and session replacement directly cancel and await its remembered Core job before clearing active state, even after the command bus has been synchronously invalidated.

- [ ] **Step 2: Run shared tests and verify RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: missing delay application types and bus/handler operations.

- [ ] **Step 3: Add package-neutral delay snapshots and ports**

Define a `ProxyDelaySnapshotResult | ProxyRejectedResult` union. The snapshot contains private in-memory `ProxyRuntimeIdentity`, generation, group name, job ID, counts, fastest index, and ordered node results; it contains no URL, endpoint, credential, provider name, raw failure, repository record, or timestamp. Extend `CoreProxyPort`, `VpnProxyCommandHandler`, and command types with start/read/cancel methods in this task; defer `ProxyApplicationPort` until Task 9, where `ProxyService` and every implementor are updated atomically.

- [ ] **Step 4: Implement command-bus and running handler routing**

Add `submitStartDelayTest`, `submitReadDelayTest`, and `submitCancelDelayTest` to the same serial bus/epoch authority used for query/selection. `VpnProxyRuntimeHandler` derives the exact running Core hashes, stores the returned job ID with the active session, rejects cross-session/job requests, and clears its remembered job only after a terminal snapshot. Extend both production `CoreProxyServiceAdapter` classes and the entry CoreService test doubles in this task, before running `entry@default`. Add:

```ts
cancelAndDrainDelayTest(sessionId: string): Promise<void>;
```

to `VpnProxyRuntimeLifecyclePort`. It calls Core cancel directly through the remembered job handle, validates a terminal result, and throws only a generic closed error on drain failure; it never needs an active command-bus binding. In this same task, add inert/recording implementations to every existing `CoreProxyPort` and `VpnProxyRuntimeLifecyclePort` fake listed above, including `ProxyService.test.ets`, `VpnRuntimeCoordinator.test.ets`, and `VpnExtensionComposition.test.ets`, so both shared and entry regain GREEN before Task 9.

- [ ] **Step 5: Run shared tests and verify GREEN**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: command routing, stale-session rejection, lifecycle drain ordering, clones, and existing proxy selection tests pass.

### Task 9: Retain the stopped-runtime lease for the complete Shared job

**Files:**
- Modify: `harmony/shared/src/main/ets/proxy/ProxyService.ets`
- Modify: `harmony/shared/src/main/ets/proxy/ProxyPorts.ets`
- Modify: `harmony/shared/src/test/ProxyService.test.ets`
- Modify: `harmony/shared/src/test/ProxyModels.test.ets`
- Modify: `harmony/shared/src/main/ets/profile/ProfileApplication.ets`
- Modify: `harmony/shared/src/test/ProfileManagement.test.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnSessionRegistry.ets`
- Modify: `harmony/entry/src/test/VpnSessionRegistry.test.ets`
- Modify: `harmony/entry/src/test/ProxyViewModel.test.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/entry/src/test/fakes/PresentationFakes.ets`
- Modify: `harmony/tests/structure/plan-c-proxy-selection-contract.test.mjs`

- [ ] **Step 1: Write failing stopped/running routing and lease-lifetime tests**

Cover stopped start loading the active committed config, exact hashed context, generation/current-group checks, lease transfer instead of `finally` release, lease held through every running read, exactly-once release on completed/cancelled/failed finalization, start failure release, second start cancel/drain before replacement, user cancel retaining partial results, running route using the command bus without a stopped lease, active-session mismatch rejection, terminal final snapshot cache, and no persistence calls.

Add deadlock tests for public `cancelAndDrainDelayTest()` versus the service's `SerialCommandQueue`: public calls enqueue once, while start/query/select/reconcile use a private already-inside-queue drain helper and never recursively enqueue. A drain failure returns `PROXY_DELAY_DRAIN_FAILED`, preserves the active record/lease for retry, and admits no mutation.

- [ ] **Step 2: Run shared/entry tests and verify RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: `ProxyService` lacks the active job/finalizer and the session-registry lease assertions fail.

- [ ] **Step 3: Implement one exactly-once Shared active-job record**

In the same task, extend `ProxyApplicationPort` exactly with `startDelayTest(groupName, snapshotGeneration)`, `readDelayTest(jobId)`, `cancelDelayTest(jobId)`, and `cancelAndDrainDelayTest(): Promise<ProxyRejectedResult | undefined>`. `ProfileApplication` initially exposes deep-cloning pass-throughs; Task 10 adds mutation admission. Update every listed concrete implementation and fake before the GREEN gate, and update `plan-c-proxy-selection-contract.test.mjs` so the old query/selection surface remains exact while the four delay methods are pinned separately.

Use a private record containing job ID, raw identity, Core hashes, generation, group, route kind, optional `VpnStoppedProxyLease`, last validated snapshot, and finalization state/promise. Stopped start transfers the lease into this record only after Core returns a valid start snapshot. Running start stores the command-bus job without a lease. Every read validates all hashes/session/generation/group/job fields against the record before publishing.

Finalization observes or requests a terminal Core snapshot, stores a final deep clone, marks finalized, releases the lease once, and then clears only the active handle; the final session snapshot remains readable until a new test or identity invalidation. No durable store is introduced.

- [ ] **Step 4: Drain delay work before other proxy operations**

Before stopped `listGroups`, `queryGroup`, `select`, `reconcileActiveSelections`, or any new delay start can load/replace Core state, use the private drain helper. Querying the same group while its test runs is not allowed to race the job; the ViewModel consumes delay snapshots instead. Running selection/query requests likewise cancel/drain first so UI guards are not the only safety boundary.

- [ ] **Step 5: Run lease/routing and full shared/entry tests and verify GREEN**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
cd ..
node --test harmony/tests/structure/plan-c-proxy-selection-contract.test.mjs
```

Expected: lease count remains non-zero for the entire stopped job, reaches zero exactly once after finalization, and all prior proxy/session tests pass.

### Task 10: Gate profile, local runtime, VPN lifecycle, recovery, and disposal mutations

**Files:**
- Modify: `harmony/shared/src/main/ets/profile/ManageProfileUseCases.ets`
- Modify: `harmony/shared/src/main/ets/profile/ProfileApplication.ets`
- Modify: `harmony/shared/src/main/ets/vpn/VpnRuntimeCoordinator.ets`
- Modify: `harmony/shared/src/main/ets/vpn/VpnPorts.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets`
- Modify: `harmony/entry/src/ohosTest/ets/test/Phase3RuntimeFlow.test.ets`
- Modify: `harmony/shared/src/test/ProfileManagement.test.ets`
- Modify: `harmony/shared/src/test/VpnRuntimeCoordinator.test.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/entry/src/test/VpnExtensionComposition.test.ets`
- Modify: `harmony/entry/src/test/fakes/PresentationFakes.ets`
- Modify: `harmony/shared/src/test/ProxyModels.test.ets`

- [ ] **Step 1: Write failing mutation-order and failure-blocking tests**

For refresh, enable, delete, subscription replacement, local start/stop, VPN start/stop, active-selection reconciliation, and application close, assert `cancelAndDrainDelayTest` resolves before the mutation begins. If drain rejects, assert the mutation collaborator is untouched and the API returns a closed retryable failure without raw detail.

For automatic VPN network recovery, terminal cleanup, explicit stop, session rebind, and extension disposal, assert the extension-owned lifecycle drains its Core delay job before closing stale connections, recovering/replacing TUN, deactivating the proxy runtime, closing platform handles, or graph disposal. A drain failure blocks the mutation and publishes only an allowlisted failure code.

- [ ] **Step 2: Run shared/entry tests and verify RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: existing mutation paths proceed without the new drain gate.

- [ ] **Step 3: Add the application-level fail-closed gate**

Before each ProfileApplication mutation listed above, await `proxyService.cancelAndDrainDelayTest()`. Map failure to the operation's existing result family with stable code `CMFA_PROXY_DELAY_DRAIN_FAILED`, retryable true, and resource-backed generic detail. Export a small `createManageProfileFailedResult(AppError)` factory rather than exposing the existing private result class. Add `ProfileApplication.close(): Promise<void>` to drain before synchronous listener/runtime disposal; `ApplicationComposition.closeResources()` awaits it. Keep `dispose()` as a defensive idempotent listener cleanup only, never as completion evidence for an undrained job.

- [ ] **Step 4: Add the extension lifecycle drain gate**

`VpnRuntimeCoordinator` awaits `proxyLifecycle.cancelAndDrainDelayTest(sessionId)` inside queued stop/cleanup and before `runCloseStale` starts recovery. `VpnExtensionComposition.disposeOwnedResources()` drains before deactivate/TUN/graph disposal. The two production `CoreProxyServiceAdapter` implementations were already extended in Task 8; update the remaining ohosTest adapter here before assembling ohosTest.

- [ ] **Step 5: Run complete ArkTS gates and verify GREEN**

```bash
cd harmony
./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

Expected: all module tests compile/pass, ohosTest assembles, drain precedes every mutation, and no stopped lease survives terminal finalization.

---

## Chunk 4: Presentation Polling and Native ArkUI

### Task 11: Extend presentation state without disturbing selection semantics

**Files:**
- Modify: `harmony/entry/src/main/ets/presentation/ProxyPresentationModels.ets`
- Modify: `harmony/entry/src/test/ProxyPresentationModels.test.ets`
- Modify: `harmony/entry/src/test/List.test.ets`

- [ ] **Step 1: Write failing presentation-model tests**

Cover closed delay view states `IDLE | STARTING | RUNNING | COMPLETED | CANCELLED | FAILED`; row outcomes `NONE | WAITING | TESTING | AVAILABLE | TIMEOUT | FAILED | CANCELLED | UNSUPPORTED`; positive delay only for `AVAILABLE`; exactly one fastest row matching the fastest index; delay/count invariants; deep clones; safe integers; and preservation of existing runtime-selected/saved-intent/nested-group fields.

Assert row semantic IDs remain exactly `proxies.node.<index>` and never include a label, job ID, delay, or result state.

- [ ] **Step 2: Run entry tests and verify RED**

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: delay presentation fields/constructors are missing.

- [ ] **Step 3: Add the minimal delay view state**

Extend `ProxyNodeRowState` with `delayStatus`, optional `delayMs`, and `delayFastest`. Extend `ProxyViewState` with delay job state and bounded total/testable/completed/available/timeout/failed/cancelled/unsupported counts plus optional fastest index. Keep the job ID private to `ProxyViewModel`; ArkUI does not need it.

Keep the existing six positional `createProxyNodeRowState` arguments source-compatible and add only a defaulted trailing delay-options object whose default is `NONE`; Task 11 therefore compiles the live `ProxyViewModel.createRows()`/`markSavedRow()` callers before Task 12 changes their behavior. `markSavedRow`, selection updates, error updates, and query refreshes must preserve or deliberately clear delay state rather than accidentally resetting it.

- [ ] **Step 4: Run presentation tests and verify GREEN**

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: presentation tests and all existing entry tests pass.

### Task 12: Implement non-overlapping 250 ms polling and lifecycle cancellation

**Files:**
- Modify: `harmony/entry/src/main/ets/presentation/ProxyViewModel.ets`
- Modify: `harmony/entry/src/test/ProxyViewModel.test.ets`
- Modify: `harmony/entry/src/test/fakes/PresentationFakes.ets`

- [ ] **Step 1: Write failing ViewModel tests with a manual scheduler**

Inject a `ProxyDelaySchedulerPort` whose manual fake records scheduled 250 ms tasks. Cover:

- one action starts the displayed group with its exact query generation;
- a new start clears prior results before awaiting Core;
- one read at a time and the next poll scheduled only after the previous read resolves;
- progressive per-index mapping without reordering rows;
- 250 ms cadence while `RUNNING`, no polling after terminal state;
- second press cancellation, including a press while start is still resolving;
- completed partial results retained after `CANCELLED`;
- fastest marker with lowest-index tie result supplied by Core;
- all outcome/count mappings and `FAILED` as typed inline page error while rows remain;
- stale epoch/job snapshots ignored;
- malformed node count/name/type/index mismatch rejected without merging;
- top-level group switch, nested-group open, reload, back/leave, identity change, and disposal cancel active work and clear results where required;
- selection/group actions ignored while delay state is `STARTING` or `RUNNING`;
- delay tests never call `select` and never move runtime/saved markers.

- [ ] **Step 2: Run focused entry tests and verify RED**

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: scheduler/toggle/polling behavior is absent.

- [ ] **Step 3: Implement the toggle and serial polling loop**

Add `toggleDelayTest()`, a private active job ID, delay epoch, pending-cancel flag, and one cancelable scheduled task. On start, capture displayed group/generation and call `application.startDelayTest`. If the second press arrives before the job ID, record pending cancellation and cancel immediately once start resolves. Otherwise call `cancelDelayTest(jobId)` directly.

Use recursive one-shot scheduling, not `setInterval`: schedule 250 ms, call one `readDelayTest`, validate/merge, then schedule again only if the same epoch/job is still `RUNNING`. Map rows strictly by original index and also require name/type equality with the currently displayed rows. Never sort and never infer delay from mihomo history in ArkTS.

- [ ] **Step 4: Implement lifecycle cancellation/clearing**

Before `load`, top-level `openGroup`, or nested-group navigation, cancel/drain the ViewModel job, invalidate its epoch, cancel the timer, and clear delay presentation. `leave(): Promise<void>` awaits cancel before the route changes. `dispose(): Promise<void>` is idempotent, suppresses listeners immediately, initiates cancellation, and awaits it when the caller owns async cleanup; application-composition close remains the final fail-closed drain authority.

Selection rejection still preserves rows and their completed delay values. A successful selection is impossible while a delay job is live because both ViewModel guards and ArkUI controls reject it.

- [ ] **Step 5: Run ViewModel and entry tests and verify GREEN**

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: scheduler, lifecycle, stale-result, partial-cancel, and existing proxy selection tests pass.

### Task 13: Render the delay action, progress, summary, and row outcomes in ArkUI

**Files:**
- Modify: `harmony/entry/src/main/ets/pages/ProxiesPage.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Modify: `harmony/entry/src/main/resources/base/element/color.json` only if existing success/warning/danger colors cannot express the approved thresholds
- Modify: `harmony/entry/src/ohosTest/ets/test/Phase3UiFlow.test.ets`
- Modify: `harmony/entry/src/test/ProxyViewModel.test.ets`
- Modify: `harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs`

- [ ] **Step 1: Write failing ArkUI/resource/source contracts**

Require resource-backed copy and stable IDs:

```text
proxies.delay-test
proxies.delay-progress
proxies.delay-summary
proxies.node.<index>.delay
proxies.node.<index>.fastest
```

Require the section below group tabs and above nodes; start label `测速全部节点`; running label `取消测速`; `已完成 n / total`; all seven row outcomes; available delay with `ms`; fastest summary; success color for 1-300 ms, warning for 301-800 ms, danger for >800 ms; original order; and no raw label interpolation in IDs. Require group/node buttons disabled for both selection-pending and delay-running states. Require the delay action to have `minHeight: touch_target_min` (48vp), remain keyboard/focus accessible, and expose its current resource-backed start/cancel label as the accessibility name.

- [ ] **Step 2: Run focused structure/entry tests and verify RED**

```bash
node --test harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: delay section, IDs, resources, and callback wiring are absent.

- [ ] **Step 3: Add compact resource-backed delay builders**

Add one action card before the node column. Its button uses `.constraintSize({ minHeight: $r('app.float.touch_target_min') })`, remains focusable, and uses the same current resource-backed start/cancel label for visible and accessibility text. During `STARTING/RUNNING`, render the cancel action, `Progress` with `proxies.delay-progress`, and `已完成 completed / total`. After completion/cancellation, render `proxies.delay-summary` with separate resource-backed segments for available/total, timeout, failed, cancelled, and unsupported counts; omit only zero-valued optional segments. If a fastest index exists, render the visible private node label and delay in the summary.

Each row keeps its existing selection/saved/nested markers and adds `.delay` text plus `.fastest` marker. Use existing `color_status_success`, `color_status_warning`, and `color_status_danger` unless a contrast test proves a new color is necessary. Do not display provider/fallback URLs or low-level failure text.

- [ ] **Step 4: Wire actions and safe route teardown in `Index`**

Pass `onDelayAction` to `ProxiesPage` and invoke `ProxyViewModel.toggleDelayTest()`. Back navigation invokes `leave()` and changes route only after cancellation resolves. Await/ignore `dispose()` explicitly with `void` where synchronous ArkUI lifecycle cannot await; `ProfileApplication.close()` still drains before composition resources close.

- [ ] **Step 5: Run entry, ohosTest assembly, and UI contracts and verify GREEN**

```bash
node --test harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

Expected: UI/resource contracts and entry tests pass; ohosTest assembles with the delay section and stable IDs.

---

## Chunk 5: Privacy Contracts, Fresh Signed HAP, and Physical-device Proof

### Task 14: Lock cross-layer structure, limits, lifecycle, and privacy contracts

**Files:**
- Create: `harmony/tests/structure/proxy-delay-contract.test.mjs`
- Modify: `harmony/tests/structure/phase1-bridge-contract.test.mjs`
- Modify: `harmony/tests/structure/plan-c-proxy-selection-contract.test.mjs`
- Modify: `harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs`
- Modify: `harmony/tests/structure/phase3-layer-boundary.test.mjs`
- Modify: `harmony/tests/structure/phase4-vpn-contract.test.mjs`
- Modify: `harmony/tests/structure/go-ohos-build-contract.test.mjs`
- Modify: `harmony/tests/structure/phase4-package-contract.test.mjs`
- Modify: `harmony/tools/lib/native-provenance.mjs`
- Create: `docs/harmony/proxy-delay-test.md`

- [ ] **Step 1: Write the failing end-to-end source contract**

Pin the exact Go raw exports, public C functions, backend callbacks, Node-API methods, TypeScript declarations, CoreService methods, Core/Shared models, command-bus methods, application methods, resource keys, and ArkUI semantic IDs. Pin the 16-worker ceiling, 5-second node deadline, 250 ms non-overlapping poll, 1024-node/256-byte-name/1 MiB JSON bounds, fallback URL, provider 2xx versus fallback 204 rule, one active job, original order, no auto-selection, and session-only storage.

Source-order contracts require:

- cancel/drain before Go config/local/TUN mutation;
- stopped lease transfer and exactly-once release;
- private non-recursive drain helper inside `ProxyService` queue operations;
- ProfileApplication drain before profile/local/VPN/reconcile/close mutations;
- VPN lifecycle drain before stop, recovery, rebind, TUN cleanup, and graph disposal;
- ViewModel cancellation before top-level/nested group changes, back, and disposal.

- [ ] **Step 2: Add privacy scanners and forbidden-pattern fixtures**

Scan Go/C++/ArkTS/UI/device-runner sources and fail on group/node/provider/URL/endpoint/credential fields in logs, errors, semantic IDs, durable models, RDB codecs, journal records, or proof schemas. Forbid delay snapshot `JSON.stringify` outside the private bridge codec, raw labels in `.id`/`hilog`/`console`/`new Error`, reflection/concrete-provider serialization to recover expected status, and device proof keys containing label/name/url/endpoint/provider/credential/jobId/sessionId/deviceId/layout text.

Allow raw group/node labels only in private in-memory model fields, Core JSON transport, equality validation, and `Text(row.name)`/fastest visible UI rendering. Add synthetic positive and negative fixtures so the scanner itself is tested.

- [ ] **Step 3: Run focused contracts and verify RED then GREEN**

```bash
node --test \
  harmony/tests/structure/proxy-delay-contract.test.mjs \
  harmony/tests/structure/phase1-bridge-contract.test.mjs \
  harmony/tests/structure/plan-c-proxy-selection-contract.test.mjs \
  harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs \
  harmony/tests/structure/phase3-layer-boundary.test.mjs \
  harmony/tests/structure/phase4-vpn-contract.test.mjs \
  harmony/tests/structure/go-ohos-build-contract.test.mjs \
  harmony/tests/structure/phase4-package-contract.test.mjs
```

Expected: RED before all cross-layer inventories/privacy rules are present; GREEN after exact authorities and docs are updated.

- [ ] **Step 4: Document the implemented contract without private runtime data**

`docs/harmony/proxy-delay-test.md` records only versioned APIs, public enums/count bounds, ownership/lifecycle rules, provider expected-status limitation, verification commands, and aggregate test counts. It contains no subscription URL, node/group/provider label, endpoint, device identifier, signing location, raw layout, or live result payload.

### Task 15: Run the complete host gate and build a fresh signed production HAP

**Files:**
- Modify only as test failures require within the files already owned by Tasks 1-14
- Generate ignored: `harmony/artifacts/geodata/geoip.metadb`
- Generate ignored: `harmony/entry/src/main/resources/rawfile/geoip.metadb`
- Generate: `harmony/artifacts/libcmfa_mihomo.so`
- Generate: `harmony/artifacts/phase1-native-provenance.json`
- Generate: `harmony/entry/build/default/outputs/default/entry-default-signed.hap`

- [ ] **Step 1: Run the complete Go/native/structure gate**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go test ./... -count=1
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off \
  go test -race ./internal/proxygroups -run 'TestDelayJob' -count=1

cd "$CMFA_REPO_ROOT"
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/test-native-host.mjs --case napi-proxy
node harmony/tools/test-native-host.mjs --case napi-tun
node --test harmony/tests/structure/*.test.mjs
```

Expected: all Go, native host, and every tracked structure test pass.

- [ ] **Step 2: Run all ArkTS gates and assemble ohosTest**

```bash
cd harmony
./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

Expected: all Hypium suites pass and ohosTest assembly succeeds.

- [ ] **Step 3: Prepare the pinned geodata and restore signing only for the build window**

Run `node harmony/tools/prepare-geodata.mjs` and require the lock-pinned size/SHA-256 verification to pass. If the network cannot finish the canonical asset, preseed the ignored cache from the previously verified canonical copy and rerun the same verifier; never weaken the lock.

Use the exact ignored backup `.codex-secure/harmony-build-profile.signed.json5`. Before applying it, require exactly one matching production `.p12`, `.p7b`, and `.cer` family under `$HOME/.ohos/config/default_harmony_*`, then validate every path referenced by the backup without printing paths, aliases, passwords, or certificate identities. Copy the backup bytes to `harmony/build-profile.json5` only for packaging and restore the file's exact pre-build bytes in `finally`.

If the ignored backup is absent or any referenced material is invalid, stop with fixed code `SIGNING_REQUIRED`; do not guess credentials or reuse the traffic-probe family. Regenerate DevEco automatic signing for the already logged-in production project, save the resulting signed build-profile bytes to that exact ignored backup, restore the tracked build profile, and rerun this step. No signing material enters Git, command output, artifacts, or the plan report.

- [ ] **Step 4: Build and inspect the fresh production package**

```bash
node harmony/tests/bin/build-phase1-native.mjs \
  --out harmony/artifacts/phase1-native-provenance.json
node harmony/tests/bin/build-phase1-native.mjs \
  --validate harmony/artifacts/phase1-native-provenance.json
node harmony/tests/bin/inspect-hap.mjs \
  --hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --manifest harmony/artifacts/phase1-native-provenance.json \
  --build-kind production
```

Expected: provenance and archive inspection pass; the packaged arm64-v8a Core contains all exact raw delay exports, the addon contains only allowed public symbols, and the HAP is signed/installable. Here “production package” means the normal app surface with self-test hooks disabled, built as `entry@default` with `buildMode=debug`; it does not mean a release-mode artifact.

- [ ] **Step 5: Record package handoff facts**

The implementation handoff records variant `entry@default debug`, application version `1.0.0` / version code `1000000`, absolute HAP path, size, SHA-256, provenance result, and whether any tracked release metadata changed. Do not include signing identity/path/material.

### Task 16: Prove complete, cancelled, and VPN-running jobs on the physical phone

**Files:**
- Create: `harmony/tests/bin/run-proxy-delay-device-proof.mjs`
- Create: `harmony/tests/fixtures/proxy-delay-device-proof.schema.json`
- Create: `harmony/tests/fixtures/proxy-delay-device-proof.example.json`
- Create: `harmony/tests/structure/proxy-delay-device-proof-contract.test.mjs`
- Create: `docs/harmony/proxy-delay-device-proof.md`
- Reuse: `harmony/tests/bin/run-phase4-device-proof.mjs` UI/HDC/layout helpers
- Reuse: `harmony/tests/bin/run-plan-d-device-proof.mjs` proxy-page navigation helpers

- [ ] **Step 1: Write the failing strict proof-schema and runner contracts**

The tracked proof permits only:

```text
schemaVersion
result: pass | incomplete
packageSha256
measurement:
  totalCount
  testableCount
  availableCount
  timeoutCount
  failedCount
  minDelayMs
  medianDelayMs
  maxDelayMs
cancellationState: CANCELLED | NOT_PROVEN
```

All counts/delays are bounded non-negative integers; pass requires multiple total/testable nodes, at least one available positive delay, ordered min/median/max, and `CANCELLED`. Reject unknown fields. Do not permit labels, hashes of labels/semantic IDs, job/session/profile/device IDs, URLs, endpoints, provider fields, timestamps, raw layouts, individual node results, or signing facts other than the package hash.

Runner source contracts require one target, signed HAP replacement install, bounded polling, exact semantic IDs, temporary raw-layout handling, remote/local layout deletion in `finally`, safe fixed failure codes, VPN cleanup, and no printing/serializing private UI text.

- [ ] **Step 2: Run the proof contract and verify RED**

```bash
node --test harmony/tests/structure/proxy-delay-device-proof-contract.test.mjs
```

Expected: runner/schema/example are absent.

- [ ] **Step 3: Implement the complete stopped-runtime measurement**

The runner resolves exactly one authorized HDC target, hashes and installs the exact inspected production HAP with replacement, launches `com.github.kr328.clash.harmony`, opens `home.proxy.manage`, and requires multiple `proxies.node.<index>` rows. It snapshots their canonical semantic-index order in memory, clicks `proxies.delay-test`, observes `proxies.delay-progress`, and polls at 250 ms until the action returns to start state and summary appears or a bounded whole-job deadline expires.

Parse only `.delay` text from layouts held under `fs.mkdtemp`; classify all terminal outcomes, extract positive `ms` values, require every testable row terminal, require exactly one `.fastest` marker when any node is available, require the node semantic-index sequence unchanged, and calculate min/median/max in memory. Raw layouts contain private labels, so pull/process them only in the temporary directory, remove the remote dump after every pull, recursively remove the local directory in `finally`, and never include layout text in thrown errors or output.

- [ ] **Step 4: Prove cancellation with retained partial results**

Start a second run, wait until `RUNNING` plus at least one terminal row if timing permits, click `proxies.delay-test` again while it reads `取消测速`, and require terminal `CANCELLED` presentation. Compare completed row results in memory before/after cancellation and require none regress to waiting/testing or disappear. If the entire job wins the race and completes before the cancel tap, retry a bounded maximum of three times; otherwise mark proof incomplete with a fixed code. Persist only `cancellationState: CANCELLED`.

- [ ] **Step 5: Prove the job while VPN/TUN remains safely running**

Navigate home, start VPN through the existing guarded `home.vpn.action` automation (handling the system consent window), and require the runtime evidence journal to contain the safe lifecycle stage `platform-protect-ok` before testing. Force-stop the separate traffic probe and establish a bounded quiet-window baseline from the private runtime journal: highest TUN trace sequence and packet counters.

Reopen the proxy page, run another complete delay job, require at least one available result, then pull the journal again and require zero new TUN trace records and zero TUN packet-counter delta across the delay-test window. Also require the VPN UI/runtime state remains `RUNNING` and no recovery/session replacement occurred. Any unrelated background TUN traffic makes the run incomplete and eligible for a bounded quiet-window retry; it is never ignored. Combined with the process-protection stage, the zero-ingress/delta assertion directly proves the delay-test sockets did not loop through this application's TUN. All journal records, sequences, counters, stage/session/job data remain transient and none enters the proof.

- [ ] **Step 6: Run the tracked physical-device proof**

```bash
node harmony/tests/bin/run-proxy-delay-device-proof.mjs \
  --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --out harmony/artifacts/proxy-delay-device-proof.json
node --test harmony/tests/structure/proxy-delay-device-proof-contract.test.mjs
```

Expected: proof result is `pass`; complete/cancel/VPN-running assertions all passed; the tracked schema contains only the approved aggregate fields.

- [ ] **Step 7: Clean up and write the privacy-safe report**

Stop VPN, force-stop the production app, delete remote layouts/private journals pulled for transient validation, delete all local temporary layouts, and restore signing config bytes in `finally`. `docs/harmony/proxy-delay-device-proof.md` contains only the exact proof-schema fields, commands, package variant/version/path, and a zero-private-data assertion; it contains no node/group/provider data or device/signing identifiers.

---

## Completion Criteria

1. The current displayed group is tested in original order with at most 16 concurrent 5-second checks.
2. Provider health-check URL is preferred with 2xx acceptance; fallback gstatic requires 204.
3. Every row shows waiting/testing/available/timeout/failed/cancelled/unsupported, and one usable fastest row is marked without changing selection.
4. A second press cancels; completed partial results remain visible; no delay data persists across process or identity changes.
5. Stopped jobs retain/release their lease exactly once; every profile/local/VPN/recovery/disposal mutation cancels and drains first.
6. Full Go/native/structure/Core/shared/platform/entry/ohosTest/provenance/HAP gates pass.
7. The fresh signed `entry@default debug` HAP installs on the HarmonyOS 6.x physical phone.
8. Physical-device proof passes complete, cancellation, and VPN-running paths with at least one positive available delay and no private node/provider data in proof/log/temp output.
