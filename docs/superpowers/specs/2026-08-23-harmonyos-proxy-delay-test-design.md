# HarmonyOS Proxy Delay Test Design

**Status:** Design approved in conversation; implementation not started
**Target:** Native HarmonyOS 6.x application
**Scope:** Test all testable nodes in the currently selected proxy group and show progressive delay results in ArkUI

## Goal

Add a Clash Meta-style delay test to the native HarmonyOS proxy page. One action tests every testable terminal node in the current group, updates each row as results arrive, distinguishes usable nodes from failures, and identifies the fastest node without changing the user's selection.

Success requires:

- the current group remains in runtime order;
- up to 16 node checks run concurrently;
- each check has a 5-second timeout;
- the configured provider health-check URL is preferred;
- `https://www.gstatic.com/generate_204` is the fallback URL;
- a second button press cancels the active job;
- completed partial results remain visible after cancellation;
- results live only for the current process and configuration identity;
- the UI shows usable, timeout, failed, cancelled, and unsupported outcomes;
- the fastest usable node is unambiguous;
- no test changes the selected proxy;
- no node label, endpoint, credential, or test URL enters logs, durable storage, or device proofs.

## Non-goals

- Download bandwidth or throughput testing.
- Testing every top-level group from one button.
- Persisting delay results across application restarts.
- Automatically selecting the fastest node.
- Reordering the node list after a test.
- Adding a user-editable test URL in the first version.
- Reusing Android/JNI code in the HarmonyOS build.

## Existing Behavior Used as Reference

The Android implementation sends the active group name to `healthCheck(group)`. Go resolves the group, invokes each associated provider's health check concurrently, and reloads the group when the check completes. Providers test their proxies in parallel using their configured health-check URL and timeout. The UI reads each proxy's latest delay history and can sort by delay.

The HarmonyOS implementation will preserve the important semantics—current-group scope, provider URL preference, per-node delay, and progressive availability—but adds a 16-worker concurrency limit and reliable cancellation.

## Chosen Architecture

Use one generation-bound Core delay-test job. Go/mihomo owns node discovery, URL resolution, concurrency, timeout, cancellation, and aggregation. ArkTS starts the job, polls immutable snapshots, and maps them to presentation state. ArkUI only renders state and forwards user actions.

This avoids dozens of independently coordinated NAPI calls and avoids the unbounded provider concurrency of the Android implementation.

### Component Boundaries

#### Go runtime job manager

Responsibilities:

- permit at most one active delay-test job per Core process;
- resolve the named runtime group against the supplied proxy identity;
- preserve the current group's ordered terminal node list;
- identify the source provider and health-check URL for each node;
- classify unsupported built-in adapters and nested groups without testing them;
- execute at most 16 `Proxy.URLTest` calls concurrently;
- apply a separate 5-second context deadline to every testable node;
- publish immutable snapshots;
- calculate the fastest successful node;
- cancel idempotently;
- stop publishing when configuration, revision, session, group, or generation becomes stale.

#### Fixed C ABI and backend surface

Responsibilities:

- carry strict, bounded start/read/cancel requests;
- return owned JSON buffers with the existing 1 MiB response limit;
- zero public buffers on every failure;
- map only closed status/error codes;
- never emit group names, node names, URLs, or job payloads into native logs.

#### NAPI and Core ArkTS adapter

Responsibilities:

- expose promise-based start/read/cancel functions;
- validate exact object keys, hashes, job IDs, generations, lengths, and result JSON;
- deep-clone every public result;
- reject unknown fields and partial states;
- keep all NAPI calls on the environment thread.

#### Shared application service

Responsibilities:

- resolve stopped versus running routing exactly like proxy query/selection;
- load the active committed configuration when stopped;
- bind the job to profile, revision, and optional VPN session identity;
- retain the stopped-runtime lease for the complete lifetime of a stopped job;
- cancel and drain a job before a profile, local-runtime, or VPN mutation is admitted;
- release the stopped-runtime lease exactly once after terminal snapshot or cancellation drain;
- expose package-neutral start/read/cancel ports to `entry`.

#### ProxyViewModel

Responsibilities:

- start and cancel the current-group job;
- poll every 250 ms while the job is active;
- suppress stale snapshots using a monotonically increasing epoch and job ID;
- merge delay state into rows without changing runtime-selection or saved-intent markers;
- cancel when the group, profile identity, or page lifecycle changes;
- preserve completed partial results after user cancellation;
- clear results on process restart, profile revision change, runtime session change, or a new test.

#### ProxiesPage

Responsibilities:

- render the start/cancel action, progress, summary, and row results;
- disable node selection and group switching during a running job;
- keep the node list in original runtime order;
- show the fastest marker without automatically selecting the node.

## Data Model

### Job state

```text
RUNNING
COMPLETED
CANCELLED
FAILED
```

### Node result state

```text
WAITING
TESTING
AVAILABLE
TIMEOUT
FAILED
CANCELLED
UNSUPPORTED
```

### Snapshot shape

```text
DelayTestSnapshot
  schemaVersion: "1.0.0"
  jobId: opaque bounded identifier
  state: job state
  profileHash: lowercase SHA-256
  revisionHash: lowercase SHA-256
  sessionHash: lowercase SHA-256 or null
  generation: positive safe integer
  groupName: in-memory bridge value
  totalCount: bounded integer
  testableCount: bounded integer
  completedCount: bounded integer
  availableCount: bounded integer
  timeoutCount: bounded integer
  failedCount: bounded integer
  cancelledCount: bounded integer
  unsupportedCount: bounded integer
  fastestNodeIndex: bounded index or null
  nodes: ordered DelayTestNodeResult[]
```

```text
DelayTestNodeResult
  index: original group index
  name: in-memory bridge value
  type: closed proxy type
  state: node result state
  delayMs: positive integer only for AVAILABLE
  source: PROVIDER or FALLBACK for testable nodes; null for UNSUPPORTED
  fastest: boolean
```

No raw endpoint, credential, provider payload, failure text, or test URL appears in the public snapshot. `source` indicates URL selection without exposing the URL; `UNSUPPORTED` nodes use `null` because no URL was selected or requested.

## Core API

The exact names may follow existing repository naming conventions, but the semantic surface is fixed:

```text
startDelayTest(context, groupName) -> DelayTestSnapshot
readDelayTest(jobId) -> DelayTestSnapshot
cancelDelayTest(jobId) -> DelayTestSnapshot
```

Start cancels an older active job before creating a new one. Read is side-effect free. Cancel is idempotent and returns the final partial snapshot.

The likely fixed native exports are:

```text
cmfa_mihomo_proxy_delay_start_v1
cmfa_mihomo_proxy_delay_snapshot_v1
cmfa_mihomo_proxy_delay_cancel_v1
```

They flow through matching C ABI, backend, NAPI, TypeScript declaration, Core adapter, and shared port methods.

## Node Discovery and URL Resolution

The job starts from the exact ordered nodes in the currently queried group.

Rules:

1. Nested proxy groups are `UNSUPPORTED` for this batch. They are not recursively expanded.
2. Built-in non-network adapters such as `Direct`, `Reject`, `RejectDrop`, `Pass`, `PassRule`, `Rematch`, and `Dns` are `UNSUPPORTED`.
3. Duplicate terminal names fail the whole job as a bridge invariant violation; they are not silently merged.
4. A proxy provider containing the node is resolved in group/provider order.
5. A non-empty valid provider `HealthCheckURL()` is preferred.
6. If no provider URL is available, use `https://www.gstatic.com/generate_204`.
7. Provider HTTP or HTTPS URLs are accepted to preserve the existing configuration's intent; the built-in fallback is HTTPS.
8. The pinned mihomo `ProxyProvider` interface exposes `HealthCheckURL()` but does not expose its configured expected-status range. Provider URLs therefore accept normal 2xx responses. The built-in gstatic fallback requires HTTP 204.
9. URL values remain Core-private and never cross the bridge or enter logs.

This expected-status rule is an explicit, stable limitation of the pinned public API. The implementation must not recover it by reflecting concrete provider implementations, serializing provider objects, or rereading private configuration payloads.

## Concurrency, Timeout, and Cancellation

- A fixed worker pool contains 16 workers.
- The queue preserves original node order; completion order may differ.
- Every test uses its own child context with a 5-second deadline.
- One node timeout does not cancel other nodes.
- Cancelling the job cancels the root context, stops queued work, and asks active `URLTest` calls to return.
- Results completed before cancellation remain `AVAILABLE`, `TIMEOUT`, or `FAILED`.
- Queued or interrupted nodes become `CANCELLED`.
- A second cancel returns the same final snapshot.
- No result may be published after the final cancelled snapshot.

When VPN is running, the existing process/socket protection path must prevent health-check sockets from re-entering the application's own TUN.

## Stopped-runtime Lease and Mutation Drain

A stopped-runtime delay test is not an instantaneous query. The `VpnStoppedProxyLease` acquired while resolving the stopped configuration must be transferred to the active delay-job record and held until the job reaches a terminal snapshot.

The shared `ProxyService` owns one active delay-job record containing:

- job ID;
- identity and generation;
- Core job handle;
- optional stopped-runtime lease;
- finalization state.

Finalization is exactly once. It cancels or observes the terminal Core job, waits for active workers to drain, stores the final session-only snapshot, and releases the lease.

Before any operation that may replace or stop the loaded configuration, the application must invoke `cancelAndDrainDelayTest()`:

- profile refresh;
- profile enable, delete, or subscription replacement;
- local proxy start or stop;
- VPN start or stop;
- VPN recovery/rebind;
- active profile reconciliation that reloads Core;
- composition disposal.

The mutation proceeds only after the job is terminal and the stopped lease has been released. A cancellation/drain failure rejects the mutation with a closed retryable error; it must not silently continue with a live delay job.

For a running VPN job, the service holds no stopped lease, but it remains bound to the exact VPN session. VPN stop, recovery, or session replacement cancels and drains the job before runtime lifecycle work continues.

## UI Design

Add a fixed delay-test section below the horizontal group tabs and above the node list.

### Idle

- Button ID: `proxies.delay-test`
- Label: `测速全部节点`
- No progress UI when the current group has no session result.

### Running

- The button becomes `取消测速`.
- Progress ID: `proxies.delay-progress`
- Copy: `已完成 37 / 90`
- A linear progress indicator advances as snapshots arrive.
- Group buttons and node buttons are disabled.
- Rows transition independently from `等待` to `测速中` and then a terminal state.

### Completed or cancelled

- Summary ID: `proxies.delay-summary`
- Summary copy: `可用 73 / 90 · 超时 12 · 不可用 5`
- Fastest copy: `最快：<visible node label> · 86 ms`
- The fastest row receives ID suffix `.fastest` and a resource-backed marker.
- Every row receives ID suffix `.delay` for its delay/outcome text.
- The list remains in original runtime order.
- Results remain until another test starts or identity invalidation clears them.

### Row outcome presentation

| Outcome | UI |
| --- | --- |
| WAITING | 等待 |
| TESTING | 测速中 |
| AVAILABLE 1–300 ms | green delay text |
| AVAILABLE 301–800 ms | warning delay text |
| AVAILABLE >800 ms | danger delay text |
| TIMEOUT | 超时 |
| FAILED | 不可用 |
| CANCELLED | 已取消 |
| UNSUPPORTED | 不支持 |

The fastest summary may render the visible node label because this is private in-memory UI. It must not be serialized into a proof or log.

## Interaction and Lifecycle Rules

- The action always applies to the currently displayed group.
- A second action press cancels the job.
- Back navigation cancels a running job.
- Opening a nested group cancels the parent job and clears its results.
- Switching top-level groups cancels and clears the previous group job.
- Profile/revision/session/generation changes cancel and clear results.
- Application process restart clears all delay state.
- Disposing the ViewModel stops polling and cancels the active job.
- Selection markers and delay markers are independent; testing never moves the runtime checkmark or saved-intent marker.

## Error Handling

Node failures are data, not page-level failures. A timeout or connection failure changes only that row.

The job becomes `FAILED` only for:

- unavailable or stale profile identity;
- unavailable runtime/configuration;
- unknown or malformed group;
- stale generation or VPN session change;
- malformed Core/NAPI payload;
- response-size or invariant violation.

Page-level failures use the existing typed, resource-backed error surface. Low-level error strings are discarded.

## Privacy and Safety

- Never log or persist group names, node names, endpoints, provider URLs, subscription content, or credentials.
- Never include node labels or deterministic label hashes in device proofs.
- Never use raw labels in semantic IDs.
- Delay snapshots may contain labels only across the private in-process bridge needed to render the UI.
- Public proof output may contain only total/testable/available/timeout/failed counts, minimum/median/maximum delay, cancellation state, and package hashes.
- Fixed test limits prevent unbounded arrays, strings, goroutines, and JSON responses.

## Verification Plan

### Go unit tests

- exact 16-worker concurrency ceiling;
- original result ordering despite out-of-order completion;
- per-node 5-second timeout;
- cancellation of queued and active nodes;
- idempotent cancel;
- no publication after final cancellation;
- provider URL preference and fallback;
- unsupported adapter classification;
- nested-group classification;
- fastest-node calculation;
- partial success when other nodes fail;
- identity/session/generation invalidation;
- stopped-runtime lease held for the full job and released exactly once;
- profile/local/VPN mutations cancel and drain before proceeding;
- cancellation/drain failure prevents mutation;
- VPN stop/recovery invalidates a running-session job;
- response and name bounds.

### Real mihomo integration tests

- load a configuration with selector, provider, supported terminal nodes, nested groups, and unsupported built-ins;
- run URL tests against a controlled HTTP(S) server;
- prove usable delays are positive;
- prove testing does not change selector state;
- prove cancellation closes the job.

### C ABI and NAPI tests

- exact exports and struct sizes;
- initialization and backend preconditions;
- strict context/job/group validation;
- fixed JSON bounds and canaries;
- start/read/cancel success;
- malformed snapshot rejection;
- queue and environment cleanup;
- cancellation races;
- zeroed failure outputs.

### ArkTS tests

- snapshot decoding and deep clones;
- polling lifecycle;
- stale job suppression;
- progress and summary mapping;
- fastest marker mapping;
- partial cancellation results;
- group/profile/session invalidation;
- dispose cancellation;
- selection state remains unchanged.

### ArkUI and source contracts

- resource-backed copy;
- stable `proxies.delay-test`, `proxies.delay-progress`, and `proxies.delay-summary` IDs;
- stable `.delay` and `.fastest` row suffixes;
- progress and cancellation behavior;
- delay colors and compact layout;
- no raw labels in IDs, logs, errors, or proof objects.

### Physical-device proof

For the active real subscription:

- the current group contains multiple real nodes;
- one action starts a bounded current-group job;
- all testable nodes reach a terminal state;
- at least one node is `AVAILABLE` with positive delay;
- the fastest result is unique and displayed;
- cancellation works in a second run;
- VPN-running tests do not loop through TUN;
- no private node/provider data remains in logs, temporary layouts, or proof files.

The proof stores only counts and delay distribution, never labels or endpoints.

## Alternatives Considered

### ArkTS worker pool calling a single-node Core API

Rejected because it requires many cross-NAPI calls and makes cancellation, generation binding, and lifecycle races harder to prove.

### Direct reuse of provider `HealthCheck()`

Rejected because provider implementations launch effectively unbounded per-node checks, which conflicts with the chosen 16-worker ceiling and reliable partial cancellation.

### Persisted delay history

Rejected for the first version because stale network results can mislead users after a restart or subscription update and would require schema, expiry, and migration work.
