# HarmonyOS VPN Runtime Bridge Design

## Status

Invalidated experiment. User decision pending on the next RPC architecture.

This file records why the Task9A same-process bridge experiment was reverted while preserving the generic privacy and package-inspection hardening work that landed alongside it.

## Physical Evidence

Fresh signed-phone evidence on August 25, 2026 established all of the following:

- the default UI ability and VPN extension run in separate PIDs on phone hardware;
- an explicit `process` field on the VPN extension is rejected by the Hvigor schema;
- `EntryAbility.process = ":vpn"` plus `CmfaVpnExtensionAbility.extensionProcessMode = "type"` was accepted by source/package inspection and produced the expected packaged aggregate shape;
- the same device proof still reported `samePid=false`;
- fixed-stage timestamps remained current, so this was not a stale-artifact read;
- one-click proof remained incomplete and the delay lane was intentionally not advanced after the same-PID claim failed.

## Conclusion

The existing native snapshot bridge is app-private, process-static, and fail-closed, but a same-process/process-static design is not viable for the HarmonyOS phone, model-independent target:

- it cannot guarantee that the UI sees the extension-owned runtime marker;
- it cannot guarantee truthful hot-switch behavior across the UI boundary;
- packaged process metadata alone is not sufficient proof of runtime co-location.

## What Was Reverted

- `EntryAbility.process = ":vpn"` was removed from `harmony/entry/src/main/module.json5`;
- `CmfaVpnExtensionAbility.extensionProcessMode = "type"` was removed from `harmony/entry/src/main/module.json5`;
- structure/package contracts that treated the packaged co-location shape as a required solution were removed;
- the package-inspection report no longer exports the Task9A-only `vpnTypeProcessCoLocated` aggregate;
- the package inspector no longer supports an `allowUnsigned` bypass and is strict about signed artifacts by default.

## What Was Kept

The following Task9A-adjacent changes remain valid and were intentionally kept:

- the broad-safe JSON5 parsing helper used by structure/package inspection;
- centralized package-inspection error normalization with fixed public messages;
- parse-once, unknown-flag-safe CLI error routing and safe report fallback behavior;
- tightened no-leak assertions for absolute paths, cwd, usernames, raw filesystem errors, stacks, and echoed bad flags.

## Next Architecture Gate

The next required architecture family is true private cross-process RPC.

- AppService RPC is not phone-safe here because current SDK support is enterprise/2in1-only.
- No RPC variant is selected in this document.
- User decision is still pending on the next RPC design to evaluate.
- `ProxyService` does not gain a fallback path;
- bridge fields stay out of public results, logs, docs and proof artifacts.

### Physical Device Acceptance

With a fresh signed HAP on the connected HarmonyOS 6 physical device:

1. stopped runtimes: tap a terminal row, VPN reaches real coordinator `RUNNING`, and the same row becomes runtime-selected;
2. local running: tap another row, local stops automatically, VPN runs, and the row becomes runtime-selected;
3. VPN running: tap another row, the marker changes while the private session identity remains unchanged;
4. app recreation while VPN is running restores the running marker and hot-switch capability;
5. cleanup proves VPN stopped, remote journal absent, both bundles force-stopped and no recent local temp roots;
6. the existing delay proof remains `pass` for the same final HAP.

Before those runtime checks, Task 9 physical acceptance must first verify that the packaged manifest still carries `EntryAbility.process = ":vpn"`, `CmfaVpnExtensionAbility.extensionProcessMode = "type"`, no VPN-extension `process` field, and that physical hilog shows the UI and VPN extension sharing one PID. If any of those checks fail, acceptance fails closed.

## Rejected Alternatives

### Common Events

Bundle-scoped common events can cross ability processes but provide weaker request/response ordering, cancellation and spoof-resistance than this exact state-machine bridge. They also require transient serialization of proxy labels for query/select RPC. Rejected for this fix.

### File, RDB, AppStorage or LocalStorage Status Synchronization

These can copy a status marker but cannot carry the live proxy command handler. They risk making the UI look correct while runtime query/select is disconnected. Rejected.

### Native TUN READY Observation

TUN readiness occurs before proxy replay and notification success. Mapping it to VPN `RUNNING` would create false success. Rejected.

### UI-Side Replay

Calling `VpnProxyRuntimeHandler.activate()` again after extension `RUNNING` would replay and mutate selections twice. The UI mirror is bind-only. Rejected.

### Direct ProxyService Native Fallback

This duplicates running query/select paths and persistence rollback behavior. The mirror-bind gate preserves the existing single authority. Rejected.

### AppService RPC

Current SDK support for `SUPPORT_APP_SERVICE_EXTENSION` is enterprise/2in1-only, so AppService RPC is not a model-independent phone solution here. Cross-process private RPC remains fallback-only if the platform ignores the packaged platform VPN type process routing.

## Delivery Constraints

- HarmonyOS 6.x physical devices, model-independent.
- No new third-party dependencies.
- No commit or push.
- Preserve all unrelated dirty-worktree changes.
- Every implementation task uses TDD, then independent spec and quality review.
- Final delivery requires a fresh signed production HAP, one-click proof pass, delay proof pass and exact restoration of `signingConfigs: []`.
