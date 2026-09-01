# HarmonyOS One-Click VPN Node Selection Design

Date: 2026-08-24

## Problem

The proxy page currently treats node selection differently depending on runtime state. When neither VPN nor the local proxy is running, selecting a terminal node persists the intent and renders `下次启动生效`; the user must then return to Home and start VPN manually.

The desired interaction is one-click VPN activation: tapping a terminal node must select it and ensure VPN global capture is running with that node. The user remains on the proxy page throughout the flow.

## Goals

- A terminal node tap starts VPN without requiring a separate Home-page action.
- If the local proxy is running, stop it before selecting and starting VPN.
- If VPN is already running, hot-switch the node without restarting or replacing the VPN session.
- Keep the proxy page visible and update the selected row to `当前生效` after success.
- Preserve a successfully saved selection when VPN start fails so another tap can retry.
- Keep nested groups, delay testing, lifecycle draining, and privacy behavior unchanged.

## Non-Goals

- Do not automatically choose the fastest measured node.
- Do not start the local proxy from a node tap.
- Do not change subscription, profile, routing, TUN, or VPN capture configuration.
- Do not add persistent activation diagnostics or record raw node/group labels in logs or proofs.

## Chosen Architecture

### Application-Level Use Case

`ProfileApplication` owns a typed `selectNodeAndEnsureVpn` use case. Presentation code requests one operation instead of sequencing `ProxyViewModel` and `HomeViewModel` actions.

A dedicated presentation-facing port extends the existing proxy query surface without requiring `ProxyService` itself to own VPN lifecycle operations. `ProfileApplication` implements the extended port; `ProxyViewModel` and its fakes depend on it.

The port also exposes a balanced application-scoped progress surface:

```text
currentOneClickVpnOperation(): OneClickVpnOperationSnapshot
subscribeOneClickVpnOperation(listener): subscriptionId
unsubscribeOneClickVpnOperation(subscriptionId): void
```

The snapshot shape is exact:

```text
{
  stage: IDLE | STOPPING_LOCAL | SAVING_SELECTION | STARTING_VPN | SWITCHING_VPN | CONFIRMING_SELECTION,
  busy: boolean,
  outcome: NONE | SUCCEEDED | FAILED
}
```

Every live stage requires `busy=true` and `outcome=NONE`. `IDLE` requires `busy=false` and may expose only the last safe terminal outcome. Starting a new operation clears the outcome to `NONE`; settling publishes `IDLE` plus `SUCCEEDED` or `FAILED`. The snapshot never contains group/node labels, runtime/session IDs, failure codes/details, or raw platform data. `ProfileApplication` publishes progress before each stop/select/start/confirm transition. `ProxyViewModel` combines that safe application progress with its private in-memory activating row index. Page disposal unsubscribes from progress but does not cancel the application operation.

The use case returns a closed `SelectNodeAndEnsureVpnResult` union that distinguishes:

- node already active on a running VPN;
- node applied immediately to a running VPN;
- node saved and VPN started;
- node saved but VPN start failed;
- local stop failed;
- selection failed or became stale;
- operation unavailable because another runtime transition is active.

Errors use existing sanitized application/VPN error types and resource identifiers. Results never expose node labels in logs or durable evidence.

### Public Result Contract

Success variants are exact:

| Kind | Meaning | Saved marker | Runtime marker |
| --- | --- | --- | --- |
| `ALREADY_ACTIVE` | VPN is running and the tapped row is already selected | unchanged | confirmed |
| `APPLIED_TO_RUNNING_VPN` | A running VPN hot-switched successfully | cleared | confirmed |
| `APPLIED_TO_RUNNING_VPN_NOT_PERSISTED` | Hot-switch succeeded but persistence failed | cleared, page warning shown | confirmed |
| `VPN_STARTED` | Selection was persisted, VPN reached `RUNNING`, and replay was confirmed | cleared | confirmed |
| `SAVED_VPN_START_FAILED` | Selection was persisted but VPN did not reach a usable running state | retained | not claimed |

Failure variants use one shape:

```text
{
  kind: FAILED,
  stage: ADMISSION | LOCAL_STOP | SELECTION | VPN_START | VPN_CONFIRMATION,
  code: OneClickVpnFailureCode,
  retryable: boolean,
  resourceId: OneClickVpnErrorResourceId,
  savedForNextStart: boolean
}
```

The closed failure-code/resource mapping is:

| Code | Resource | Retryable | Saved marker |
| --- | --- | --- | --- |
| `OPERATION_BUSY` | `proxies_one_click_busy` | yes | unchanged |
| `LOCAL_STOP_FAILED` | `proxies_one_click_local_stop_failed` | yes | no new marker |
| `PROXY_SELECTION_STALE` | existing stale-selection resource | yes | no new marker |
| `PROXY_SELECTION_FAILED` | existing selection-failed resource | yes | no new marker |
| `PROXY_PERSISTENCE_FAILED` | existing persistence-failed resource | follows source result | no new marker |
| `VPN_PROFILE_UNAVAILABLE` | existing VPN-profile-unavailable resource | no | yes when persistence completed |
| `VPN_PERMISSION_DENIED` | existing VPN-permission-denied resource | yes | yes |
| `VPN_START_FAILED` | existing VPN-start-failed resource | yes | yes |
| `VPN_STOPPED_BEFORE_RUNNING` | existing VPN-start-failed resource | yes | yes |
| `VPN_CONFIRMATION_TIMEOUT` | new proxy VPN-confirmation-timeout resource | yes | yes |
| `VPN_SESSION_CHANGED` | existing proxy-session-changed resource | yes | yes |

`ProxySelectionResult.SAVED_FOR_NEXT_START` feeds the stopped-path persistence success. `APPLIED_NOW` feeds `APPLIED_TO_RUNNING_VPN`. `APPLIED_NOT_PERSISTED` feeds `APPLIED_TO_RUNNING_VPN_NOT_PERSISTED`. `REJECTED`, `LocalRuntimeStopResult.FAILED`, and `VpnControllerStartResult.REJECTED/FAILED/STOPPED` map through the table without copying raw error detail. A post-start query timeout or session change maps to its explicit confirmation code.

## Data Flow

### VPN Already Running

1. Reject a duplicate tap when the row is already `runtimeSelected`.
2. Submit the selected node through the existing running-session proxy command bus.
3. Keep the VPN session alive; do not stop, restart, or replace it.
4. Refresh the displayed group until the selected row is marked `runtimeSelected`, using the existing bounded query/deadline behavior.

### Local Proxy and VPN Both Stopped

1. Validate the displayed group/member and snapshot generation through the existing `ProxyService.select` path.
2. Persist the selection, producing the existing saved-for-next-start record.
3. Start VPN global capture. A `STARTED` return only proves that the system ability launch was accepted; it is not one-click success.
4. Observe the application-owned VPN runtime observation port until the controller/registry reaches `RUNNING`. The observation port exposes a current snapshot plus subscribe/unsubscribe and is injected beside the controller; the use case does not poll UI state.
5. Let the existing VPN activation/replay path apply the saved selection before publishing a stable running state.
6. Query the currently displayed group after `RUNNING` and require the target row to report `runtimeSelected=true` under the active VPN identity.
7. Only after both `RUNNING` and runtime-selection confirmation does the use case return `VPN_STARTED` and the UI render `当前生效`.

If the runtime reaches `STOPPED` before `RUNNING`, return `VPN_STOPPED_BEFORE_RUNNING`. If it reaches `ERROR`, map the sanitized controller failure to `VPN_PERMISSION_DENIED` or `VPN_START_FAILED`. If the bounded runtime/selection confirmation deadline expires, return `VPN_CONFIRMATION_TIMEOUT`. If the running identity/session changes before selection confirmation, return `VPN_SESSION_CHANGED`.

### Local Proxy Running

1. Cancel/drain any active proxy-delay job using existing lifecycle rules.
2. Stop the local proxy and await a stable stopped snapshot.
3. Re-query the displayed group because stopping the local runtime invalidates the old runtime identity/generation.
4. Confirm the selected terminal member still exists in the fresh snapshot.
5. Persist the selection using the fresh generation.
6. Start VPN and refresh the displayed group after activation.

If local stop fails, abort before changing the saved selection.

### Runtime Transition Already Active

VPN `AWAITING_CONSENT`, `STARTING`, `RECOVERING`, or `STOPPING`, and local `STARTING` or `STOPPING`, are busy states. A node tap must not create a second operation.

### Application-Scoped Single Flight

`ProfileApplication` owns the only admission gate for one-click activation. It stores an application-scoped in-flight operation/lease, not a page-scoped flag. Before the operation starts it checks:

- no one-click operation is already unsettled;
- the local runtime is not `STARTING` or `STOPPING` and no conflicting local mutation lease is held;
- VPN is not `AWAITING_CONSENT`, `STARTING`, `RECOVERING`, or `STOPPING` and no conflicting VPN mutation lease is held.

The public local/VPN start/stop entry points observe the same mutation lease. The one-click flow uses private inside-lease helpers for its own stop/select/start sequence so it cannot deadlock by reacquiring its lease. A second node tap or competing Home action returns a typed busy/unavailable result and never starts a second chain.

## Presentation and Interaction

### Activation State

The proxy presentation state adds a closed one-click activation state, sufficient to render:

- idle;
- stopping local proxy;
- saving selection;
- starting VPN;
- switching a running VPN;
- failed.

It also tracks the activating row index without changing semantic IDs. The existing `selectionPending`/interaction guards are reused or deliberately generalized so only one node activation can run.

Application progress is authoritative for `STOPPING_LOCAL`, `SAVING_SELECTION`, `STARTING_VPN`, `SWITCHING_VPN`, and `CONFIRMING_SELECTION`; presentation does not infer these stages from timing or unrelated Home state.

### Row and Page Feedback

- The tapped terminal row renders `正在启动 VPN`, `正在切换到 VPN`, or `切换中` as appropriate.
- Other nodes, group chips, retry actions, and delay testing are disabled during activation.
- On success, the activating row becomes `当前生效`, the saved-only marker is removed, and the page remains on the same top-level or nested group.
- A tap on a nested group only navigates into that group and never starts VPN.
- A tap during a live delay test remains rejected by the existing interaction guard.
- A tap on the current runtime-selected node while VPN is running is an idempotent no-op.
- A tap on a saved node while VPN is stopped still starts VPN.

The system VPN consent dialog remains mandatory on first use. After consent, the same in-flight operation continues.

## Failure Behavior

- Local stop failure: keep the previous selection, do not start VPN, and show a sanitized local-stop error.
- Selection validation/persistence failure: do not start VPN and keep the previous stable state.
- VPN start failure after persistence: retain the selected row as `下次启动生效`, render the sanitized VPN error on the proxy page, and allow a new tap to retry.
- Post-start refresh timeout: keep the VPN state truthful, show a retryable proxy refresh/session error, and never claim `当前生效` without a running snapshot confirming it.
- Duplicate requests collapse or are ignored; no second stop/select/start chain runs concurrently.

The result table above is authoritative for `resourceId`, retryability, and saved-marker behavior. Presentation must not infer these facts from arbitrary `AppError`, `VpnFailure`, or `ProxyRejectedResult` shapes.

No failure message may interpolate group names, node names, endpoints, URLs, credentials, session IDs, or raw platform errors.

## Lifecycle and Ordering

The one-click operation preserves current ownership rules:

- delay cancel/drain precedes local stop, proxy selection, and VPN start mutations;
- local stop reaches terminal state before a fresh group query;
- selection persistence completes before VPN start;
- VPN activation replay applies the saved selection before the UI claims success;
- a running VPN hot-switch does not replace the current VPN session;
- leaving/disposal cancels page-level refresh and rendering waits but does not cancel an admitted application-level operation;
- `ProfileApplication` owns the in-flight operation until it settles at a typed terminal result, even if the original page/`ProxyViewModel` is disposed;
- a newly created `ProxyViewModel` recovers final state through `load()`/`queryGroup()` from the application/runtime source of truth rather than reusing a detached page callback.

## Tests

### Shared/Application Tests

- stopped runtime: save selection, then start VPN in exact order;
- local running: drain, stop local, re-query, save with fresh generation, start VPN;
- local stop failure: no selection write and no VPN start;
- stale/missing member after re-query: no selection write and no VPN start;
- VPN running: select now without start/stop/session replacement;
- VPN start failure: saved selection retained;
- busy runtime states and duplicate calls: no overlapping operation;
- a competing Home runtime action is rejected while the application mutation lease is held;
- `STARTED` before consent/runtime completion does not produce success;
- `RUNNING` without target-row `runtimeSelected` confirmation does not produce success;
- `STOPPED`, `ERROR`, confirmation timeout, and session change map to the exact typed failure contract;
- all typed result/error branches clone and validate safely.

### Presentation Tests

- terminal node tap invokes the one-click application use case;
- nested-group tap remains navigation-only;
- activating row and stage copy are exact and resource-backed;
- all unrelated controls are disabled while activation is live;
- success refreshes the same displayed group and renders `当前生效`;
- failure retains `下次启动生效` when persistence succeeded;
- current-node tap on running VPN is a no-op;
- delay results, group order, runtime marker, and saved marker remain coherent.
- progress subscription is balanced, and page disposal ignores later progress without cancelling the application operation.

### Physical-Device Proof

The privacy-safe proof reuses existing semantic IDs and Phase 4 helpers and verifies:

1. with both runtimes stopped, tapping a terminal node reaches VPN `RUNNING` and the same row becomes runtime-selected;
2. with local proxy running, a node tap stops local and starts VPN;
3. with VPN running, another node tap changes runtime selection without VPN session replacement or traffic-capture interruption;
4. cleanup stops owned VPN work, removes transient layouts/journals, and persists only aggregate/fixed proof fields.

The saved-marker/retryable-error failure path is proven through injectable shared/entry Hypium tests (and may also run inside the ohosTest target), not through a production runtime failure hook. The production physical proof contains no test-only dependency override.

The proof and logs contain no raw group/node labels, endpoints, URLs, credentials, device identifiers, sessions, or layouts.

## Acceptance Criteria

- One tap on a terminal node is sufficient to start VPN and use that node.
- A running local proxy is stopped automatically before VPN activation.
- A running VPN hot-switches nodes without restart.
- Success remains on the proxy page and shows `当前生效` only after confirmation.
- VPN start failure preserves the saved selection and supports tap-to-retry.
- Nested-group and delay-test behavior do not regress.
- Unit, native/structure, ArkTS, packaging, and physical-device proof gates pass.
- The final signed `entry@default debug` HAP installs on HarmonyOS 6.x, and tracked signing configuration is restored to empty afterward.
