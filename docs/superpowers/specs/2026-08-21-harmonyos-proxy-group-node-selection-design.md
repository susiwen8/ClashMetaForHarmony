# HarmonyOS Proxy Group and Node Selection Design

**Status:** User-approved design, pending implementation planning  
**Date:** 2026-08-21  
**Target:** HarmonyOS 6.x / API 23 on physical phones  
**Milestone:** Browse the active profile's proxy groups and nodes, then apply and persist a selection for VPN  

## 1. Problem

The HarmonyOS application can now decrypt and download the user's subscription,
but the resulting profile remains invalid with `VALIDATION / CMFA_BACKEND_ERROR`.
The downloaded candidate is an 81 KiB UTF-8 Clash YAML document with complete
`proxies`, `proxy-groups`, `rules`, and general configuration. It is neither a
Base64 subscription nor a URI list. Its group and rule references are
structurally complete.

Even after that compatibility failure is repaired, the current Harmony
`CoreService` exposes only configuration validation/loading and runtime start,
stop, and snapshot operations. It cannot query proxy groups, enumerate nodes,
or patch a selector. The ArkUI application therefore has no truthful source of
node state to render.

The Android implementation already owns this behavior through
`queryGroupNames`, `queryGroup`, and `patchSelector`. The Harmony milestone must
recreate that capability through the native Harmony backend instead of parsing
and mutating proxy selections in the UI.

## 2. Confirmed Decisions

| Topic | Decision |
| --- | --- |
| Profile scope | Only the currently enabled profile |
| Node page | Show proxy groups, group members, and current selection |
| Running VPN | A successful selection applies immediately |
| Stopped VPN | Persist the selection and replay it on the next VPN start |
| Source of truth | The loaded mihomo runtime, not an ArkTS YAML parser |
| Validation blocker | Fix the exact backend incompatibility before exposing nodes |
| Sensitive fields | Never expose server, port, UUID, password, token, key, or subscription URL |
| Persistence | Store only profile ID, group name, selected node name, and update metadata |
| First milestone exclusions | No latency tests, search, sorting, provider management, or traffic charts |
| Android maintenance | Out of scope |

## 3. Goals

1. Make the current downloaded full Clash YAML pass the real backend validation
   path without weakening validation or guessing alternate subscription
   encodings.
2. Add a typed, bounded Harmony core contract for querying selectable proxy
   groups and selecting one member.
3. Show the current active profile's groups and nodes in native ArkUI.
4. Apply selections immediately when VPN is running and persist confirmed
   selections for later starts.
5. Keep UI, logs, errors, persistence, and native bridge payloads free of node
   credentials and transport endpoints.
6. Prove on a physical phone that the selected member survives process restart
   and is replayed before the next VPN becomes active.

## 4. Non-Goals

1. Browsing inactive or invalid profiles.
2. Editing proxy definitions or subscription contents.
3. Latency tests, health checks, search, sorting, favorites, or batch actions.
4. Proxy/rule provider browsing or updates.
5. Automatically selecting the fastest node.
6. Exposing raw node JSON/YAML or connection credentials.
7. Reworking VPN authorization, TUN ownership, routing, DNS, or notification
   behavior.
8. Treating a failed candidate as usable by bypassing core validation.

## 5. Validation Compatibility Gate

Node browsing begins only after the active profile has a valid committed
revision. The existing failed candidate must first be replayed through the same
`mihomoexecutor.ParseWithBytes` seam used by production.

This gate is a separate tracer-bullet plan. It must produce
`docs/harmony/subscription-validation-compatibility.md` before any proxy query,
selection, persistence, or UI plan begins. That report must identify the exact
rejected field or field combination, the upstream/runtime behavior that rejects
it, the minimized non-secret fixture shape, the selected fix, and a regression
test that fails before the fix and passes after it. “Unknown parser problem” is
not an acceptable gate result.

The validation plan sequence is:

1. Reproduce the candidate failure through a deterministic, local test or
   replay harness that never checks the sensitive fixture into source control.
2. Preserve a redacted parser failure category, field path, and line number
   when mihomo supplies them. Node names, addresses, credentials, and paths are
   removed before the error crosses the Go boundary.
3. Minimize the candidate by removing one top-level section or proxy field at a
   time until the rejected field or combination is isolated.
4. Fix the compatibility problem at the core/parser boundary or update the
   pinned parser when that is the verified cause.
5. Convert the real candidate from `failedCandidate` to `currentRevision` only
   after the unchanged production validator accepts it.

The downloader must not add Base64 or URI-list heuristics for this candidate;
evidence already rules those formats out.

## 5.1 Gated implementation slices

This design is implemented through four separate plans, in order:

1. **Plan A — Validation compatibility:** identify and fix the exact current
   YAML rejection, producing the required compatibility report and valid
   committed profile.
2. **Plan B — Native proxy contract:** add bounded Go/C++/Node-API/ArkTS query
   and selector-patch contracts with no UI or persistence.
3. **Plan C — Selection service and replay:** add the cross-runtime command bus,
   repository, running/stopped semantics, rollback, and VPN-start replay.
4. **Plan D — ArkUI and device proof:** add the page, navigation, presentation
   states, and physical-device acceptance flow.

Plan B cannot start until Plan A passes on the current subscription. Plan C
cannot start until Plan B has host and packaged-native contract evidence. Plan D
cannot start until Plan C proves running and stopped selections without ArkUI.

## 6. Architecture

```text
ProxiesPage / ProxyViewModel
          │
          ▼
shared ProxyService ───────> ProxySelectionRepository
          │
          ▼
shared CoreProxyPort / CoreService
          │
          ▼
core ArkTS adapter → Node-API → C++ ABI → Go/mihomo runtime
          │
          └───────────────> active VPN runtime selector
```

`shared` owns proxy snapshots, selection commands, ports, validation, and
serial command policy. `core` implements runtime queries and selector patches.
`platform` stores confirmed selections. `entry` owns presentation and native
ArkUI only.

The current VPN extension and application runtime share the packaged native
core and the installed `VpnSessionRegistry` in the present process model. A new
`VpnProxyCommandBus` is installed beside that registry through the same
production composition factory:

- ArkUI/`ProxyService` submits commands to the bus;
- `VpnExtensionComposition` binds one handler only while its matching session
  owns a loaded running core;
- the bus requires exact session ID, profile ID, and revision ID matches;
- the extension handler serializes patches against start, recovery, and stop;
- stopping/unbinding rejects pending commands with `VPN_SESSION_CHANGED`;
- the response returns to the caller as a typed result.

The UI never calls a process-global native selector directly. A future
separate-process VPN implementation may replace the same bus with IPC without
changing ViewModels or domain rules.

## 7. Domain Models and Ports

### 7.1 Models

`ProxyNodeSummary` contains only:

- `name`: user-visible mihomo proxy name;
- `type`: allowlisted protocol or group type;
- `isGroup`: whether selecting it navigates into another group;
- `selected`: whether it is the group's confirmed current member.

`ProxyGroupSnapshot` contains:

- `profileId` and active revision ID;
- group `name` and group `type`;
- current `selectedName`;
- ordered `nodes`;
- snapshot generation/version used to reject stale taps.

`ProxyGroupSnapshot` has these bridge limits: at most 128 groups, at most 1,024
members per group, at most 256 UTF-8 bytes per name, and at most 1 MiB of native
JSON per response. Exceeding a limit fails closed instead of truncating a
selection surface.

`ProxySelectionRecord` contains:

- profile ID;
- group name;
- selected node name;
- active revision ID at confirmation time;
- update timestamp.

None of these models contains server address, port, UUID, password, transport
options, certificates, private keys, or subscription credentials.

`ProxySelectionResult` is a closed union:

- `APPLIED_NOW`: matching profile/revision/session, confirmed post-patch group
  snapshot, and confirmation timestamp;
- `SAVED_FOR_NEXT_START`: matching profile/revision, saved group/node names,
  and save timestamp; it explicitly contains no runtime-confirmed snapshot;
- `APPLIED_NOT_PERSISTED`: matching running session and confirmed runtime
  snapshot plus the typed persistence/rollback failure;
- `REJECTED`: allowlisted error code, retryable flag, and timestamp, with no raw
  mihomo message.

The names in these results remain application-private and are never written to
logs or proof artifacts.

`ProxyQueryResult` is a separate closed union:

- `SNAPSHOT`: matching profile/revision, optional matching running session,
  query generation, and one or more bounded `ProxyGroupSnapshot` values;
- `REJECTED`: allowlisted query error, retryable flag, and timestamp.

Query results never reuse selection result kinds.

### 7.2 Core contract

The typed core boundary adds equivalents of the Android behavior:

- `queryProxyGroupNames(excludeNotSelectable: boolean): Promise<string[]>`
- `queryProxyGroup(name: string): Promise<ProxyGroupSnapshot>`
- `selectProxy(groupName: string, nodeName: string): Promise<ProxySelectionResult>`

Names are normalized as bounded UTF-8 values. Empty names, control characters,
oversized lists, duplicate members, unknown types, and malformed native JSON
fail closed with typed core errors.

### 7.3 Application ports

- `ActiveProfileProxyPort`: returns the active valid profile and revision.
- `CoreProxyPort`: queries the loaded runtime and patches a selector.
- `ProxySelectionRepository`: reads, transactionally upserts, deletes, and
  reconciles confirmed selections by profile/group.
- `VpnProxyRuntimePort`: reports whether the matching VPN session is active and
  applies the selector to that runtime.
- `VpnProxyCommandBus`: carries one serialized session/profile/revision-bound
  query or patch command from the UI-owned service to the active extension
  handler. Query commands return `ProxyQueryResult`; patch commands return
  `ProxySelectionResult`.

`ProxyService` is the only unit allowed to coordinate these ports.

## 8. Native Runtime Contract

The Go implementation reuses the Android semantics against mihomo's active
proxy registry:

1. Query selectable group names from the loaded runtime.
2. Resolve one group and return its ordered members plus the current member.
3. Reject a selector patch unless both the group and member exist in the same
   runtime snapshot.
4. Patch the mihomo selector and close only stale connections owned by that
   group when required by the runtime API.
5. Return a confirmed post-patch snapshot rather than assuming success.

The C++/Node-API layer returns bounded JSON with names, types, selection state,
and error codes only. It must reject unknown fields and oversized responses.
Native errors are mapped to allowlisted ArkTS error codes; raw mihomo messages
are redacted before crossing the boundary.

The Go/C++ result schema uses explicit `schemaVersion`, `kind`, profile/revision
identity hashes, optional session identity hash, group snapshot, and allowlisted
error fields. A response with an unknown schema version, result kind, field,
type, or duplicated member is rejected by ArkTS decoding.

## 9. Query and Selection Flows

### 9.1 Open the node page

1. The ViewModel asks `ProxyService` for the active profile snapshot.
2. The service rejects absent, invalid, or revision-mismatched active profiles.
3. If a matching VPN session is running, every group/member/current-selection
   read goes through `VpnProxyCommandBus` to the extension-owned runtime. The UI
   must not merge or compare it with an app-owned core snapshot.
4. If no matching VPN session is running, reads come from the app-owned loaded
   core for the active revision.
5. The authoritative runtime returns selectable group names.
6. The service fetches the initial group and publishes an immutable view state.
7. Switching groups cancels or supersedes an older in-flight group query.

### 9.2 Select while VPN is running

1. The command is serialized and carries profile, revision, group, node, and
   snapshot generation.
2. `ProxyService` re-queries the group and rejects a stale or missing member.
3. `ProxyService` submits a session/profile/revision-bound command through
   `VpnProxyCommandBus`.
4. The handler bound by `VpnExtensionComposition` rechecks the active session
   and serializes the patch against recovery/stop.
5. `VpnProxyRuntimePort` patches the active matching VPN runtime.
6. The handler queries the group again and requires the selected member to
   match the command.
7. Only after runtime confirmation does the repository persist the selection.
8. UI publishes `APPLIED_NOW` and the confirmed snapshot. A rejected patch leaves persistence
   and presentation on the prior selection.

If persistence fails after the runtime patch, the handler attempts to patch the
previous member back and confirms the rollback. Confirmed rollback returns
`REJECTED` and keeps the prior UI/persistence state. If rollback also fails, the
result is `APPLIED_NOT_PERSISTED`; UI shows the runtime-confirmed member with a
warning that it will not survive restart. The system never claims startup can
repair a selection that was never durably recorded.

### 9.3 Select while VPN is stopped

1. The loaded active configuration still validates the group/member pair.
2. The service persists the confirmed intent for the active revision.
3. UI publishes `SAVED_FOR_NEXT_START`. The saved member uses a distinct
   “下次启动 VPN 时应用” indicator; it does not receive the current-runtime
   checkmark.
4. On the next VPN start, selections are replayed after configuration load and
   before the coordinator publishes `RUNNING`.
5. Each replay is post-query confirmed. Once the VPN reports `RUNNING`, UI
   converts the saved indicator into the runtime-confirmed checkmark.
6. A missing group/member is removed from persistence and the configuration's
   default selection remains active.

If the stopped-state persistence write fails, no runtime state has changed and
the result is `REJECTED`; UI remains on the prior confirmed/default selection.

### 9.4 Subscription update

After a new revision is committed and loaded, `ProxyService` reconciles stored
records against the new runtime groups. Existing group/member pairs are kept;
stale records are deleted. Reconciliation never changes the profile revision
or subscription contents.

## 10. Persistence

RDB adds a versioned selection table keyed by `(profile_id, group_name)` with:

- selected node name;
- confirmed revision ID;
- update timestamp.

The repository transaction rejects blank/oversized fields and unknown profile
IDs. Deleting a profile deletes its selections transactionally. Selection
records are metadata, but group/node names are still treated as private:
diagnostics use counts and hashes rather than raw names.

The dedicated selection table is the only durable location allowed to contain
raw group/node names. All other RDB tables, logs, exported diagnostics, proof
artifacts, and error details contain counts or hashes only. Endpoint and
credential fields are forbidden everywhere outside the encrypted/full profile
revision already owned by `ProfileContentStore`.

## 11. ArkUI Experience

The home page adds a `home.proxy.manage` entry labeled “代理节点”. It is:

- enabled only when an active valid profile exists and core state is ready;
- disabled with a resource-backed explanation otherwise.

`ProxiesPage` provides:

- a group selector at the top;
- an ordered node list;
- protocol/group type labels;
- a checkmark for the confirmed member;
- a separate “下次启动 VPN 时应用” marker for a stopped-state saved intent;
- bounded loading state;
- empty, invalid-profile, core-not-ready, and typed failure states.

A node tap is non-destructive and requires no confirmation dialog. While the
selection command is running, duplicate taps are ignored and the prior
confirmed selection stays visible. Nested group members navigate to that group
rather than being sent as a terminal selector choice.

The checkmark always means “confirmed by the current loaded runtime.” It never
represents a stopped-state saved intent. `APPLIED_NOT_PERSISTED` shows the
runtime checkmark plus a restart-persistence warning until another confirmed
selection or VPN restart resolves the difference.

The UI never renders endpoints or credentials, and copied error details remain
pre-sanitized.

## 12. Error Handling and Privacy

- No active profile: `PROXY_PROFILE_UNAVAILABLE`.
- Active revision not loaded: `PROXY_RUNTIME_NOT_READY`.
- Missing/stale group or node: `PROXY_SELECTION_STALE`.
- Native query rejected: `PROXY_QUERY_FAILED`.
- Runtime patch rejected: `PROXY_SELECTION_FAILED`.
- Persistence failed after a running-runtime patch: report a reconciliation
  error, attempt confirmed runtime rollback, and return `APPLIED_NOT_PERSISTED`
  only when rollback fails. Do not promise later reconciliation without a
  durable record.

Logs and evidence may include operation, result code, group/node counts,
revision hash, and duration. They must not include raw group/node names,
endpoints, credentials, subscription data, or configuration paths.

## 13. Testing

### 13.1 Go/core

- Replay and minimize the current validation failure at the production parser
  seam.
- Query group names, group members, current selection, nested groups, missing
  groups, and malformed runtime state.
- Patch a selector, reject missing members, and confirm post-patch state.
- Enforce response/name/count bounds and error redaction.

### 13.2 Shared/platform

- Serialize concurrent group queries and selection commands.
- Reject inactive profiles, revision drift, stale snapshots, and unknown
  members.
- Persist only after a confirmed running-runtime patch.
- Replay stopped-runtime selections before VPN `RUNNING`.
- Reconcile selections after profile updates and delete them with profiles.
- Roll back or surface partial failure without inventing success.

### 13.3 Entry

- Home entry enabled/disabled states.
- Group switching, node rows, selected checkmark, nested navigation, loading,
  empty, and error states.
- Repeated taps issue one selection command.
- Presentation serialization contains no endpoint or credential fields.

### 13.4 Physical device

1. Import and enable the current subscription after the compatibility fix.
2. Start VPN and open the node page.
3. Observe multiple groups/nodes from the active mihomo runtime.
4. Select another terminal node and confirm the runtime reports it selected.
5. Send an HTTPS request through VPN after selection.
6. Stop VPN, select a different node, and confirm the UI shows only the
   “下次启动 VPN 时应用” saved-intent marker, not the runtime checkmark.
7. Start VPN and confirm replay succeeds before `RUNNING`; once running, query
   through the extension-owned runtime and confirm the saved marker changes to
   the runtime checkmark.
8. Force-stop/relaunch, start VPN again, and confirm the persisted selection is
   replayed before `RUNNING`.
9. Update the profile and confirm stale selections are removed without exposing
   node details in logs/evidence.

## 14. Acceptance Criteria

1. The current subscription becomes a valid committed profile through the real
   parser, not a validation bypass.
2. The node page is unavailable for inactive or invalid profiles.
3. The active valid profile shows selectable proxy groups and multiple nodes.
4. Node names/types/current selection match the active mihomo runtime.
5. Selecting a terminal node while VPN runs changes the runtime immediately.
6. Only confirmed selections are persisted, and they replay on the next VPN
   start.
7. Selecting while VPN is stopped shows a saved-intent marker; starting VPN
   replays it before `RUNNING` and replaces that marker with a runtime-confirmed
   checkmark.
8. A failed or stale selection leaves the previous runtime/persisted selection
   unchanged.
9. A real HTTPS request succeeds through VPN after node selection.
10. The dedicated selection table contains only profile ID, group name, selected
   node name, revision ID, and timestamp. No endpoint, credential, subscription
   value, or signing material is written there; logs, other RDB tables, UI state
   serialization, and proof artifacts use no raw group/node names.
11. Platform/core/entry tests and signed HAP/package inspection pass with no
    new failures beyond explicitly documented pre-existing baseline errors.
