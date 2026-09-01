# HarmonyOS Fast Startup VPN Mirror Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the HarmonyOS Home route without waiting for the full 15-second VPN-RPC window while keeping all VPN and node operations fail-closed until runtime authority is known.

**Architecture:** Perform one authenticated startup RPC attempt before `READY`. If it fails, publish `READY` with an explicit registry hydration gate and run the unchanged bounded connection in an owned background task; bind the mirror before publishing success, or settle to stopped only after the bounded window exhausts.

**Tech Stack:** HarmonyOS ArkTS, Hypium/Hvigor, Node.js structure tests, LocalSocket RPC, HUKS-backed authentication.

**Worktree rule:** The worktree already contains extensive user-owned changes. Modify only the files named below, never reset/revert unrelated work, and scope diff checks/reviews to this task's touched files plus the temporary signing target. Do not commit or push.

---

## Chunk 1: Fail-closed state and connection policies

### Task 1: Add a runtime-mirror hydration gate to the registry

**Files:**
- Modify: `harmony/entry/src/test/VpnSessionRegistry.test.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnSessionRegistry.ets`

- [ ] **Step 1: Write failing registry tests**

Add tests that `beginRuntimeMirrorHydration()` publishes anonymous `RECOVERING`, blocks `beginPending()`, denies `acquireStoppedProxyLease()`, preserves a known request when applicable, and that authenticated hydration or `completeRuntimeMirrorHydrationUnavailable()` clears the gate.

- [ ] **Step 2: Run entry tests and verify RED**

```sh
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: compile/assertion failure because the gate does not exist.

- [ ] **Step 3: Implement the minimal registry gate**

Add an internal pending flag and the two lifecycle methods. Reuse `RECOVERING`; do not add a new public runtime enum. Ensure every accepted authoritative snapshot/stop/failure path clears the flag, and reject new sessions while the flag is set.

- [ ] **Step 4: Re-run entry tests and verify GREEN**

Expected: `BUILD SUCCESSFUL` with no Hypium failures.

### Task 2: Add one-attempt RPC without downgrading full callers

**Files:**
- Modify: `harmony/shared/src/test/VpnRpcClient.test.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcClient.ets`
- Modify: `harmony/shared/src/test/VpnRpcProxyHandler.test.ets`

- [ ] **Step 1: Write failing connection-policy tests**

Add tests proving refused `connectOnce()` performs one socket call and no backoff, later `connect()` retains bounded retry, full `connect()` racing an in-flight one-shot is not downgraded, and `close()` winning over one-shot leaves `CLOSED`.

- [ ] **Step 2: Run shared tests and verify RED**

```sh
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: compile/assertion failure because `connectOnce()` and policy arbitration do not exist.

- [ ] **Step 3: Implement the minimal shared policy runner**

Add required `connectOnce()` to `VpnRpcClientPort`. Share socket/auth/bootstrap code, branch only at retry scheduling, track the active policy so a full caller retries after a failed in-flight one-shot, and preserve `CLOSED` on late failures. Update the shared fake.

- [ ] **Step 4: Re-run shared tests and verify GREEN**

Expected: `BUILD SUCCESSFUL`; the existing 15-second retry-window test remains unchanged and passing.

## Chunk 2: Two-stage controller orchestration and UI gating

### Task 3: Own background mirror recovery in the controller

**Files:**
- Modify: `harmony/entry/src/test/HarmonyVpnController.test.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets`
- Modify: `harmony/tests/structure/vpn-local-socket-rpc-contract.test.mjs`

- [ ] **Step 1: Add failing source and behavior contracts before production edits**

In the controller fake, split `connectOnceCalls` and `connectCalls` with independently controllable deferred outcomes. Add tests for: immediate success before `READY`; one-shot failure returning while full recovery remains pending and registry is `RECOVERING`; later full success; later full exhaustion; user start remaining on full `connect()`; and dispose preventing late bind/publish.

Also add focused source assertions before production wiring changes: startup uses `connectOnce()`, background/start use `connect()`, and `CoreComposition` still orders mirror initialization before `READY`.

- [ ] **Step 2: Run entry and focused structure tests and verify RED**

```sh
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
cd ..
node --test harmony/tests/structure/vpn-local-socket-rpc-contract.test.mjs harmony/tests/structure/phase4-vpn-contract.test.mjs
```

Expected: routing/behavior assertions fail because startup still awaits full `connect()` and has no hydration gate.

- [ ] **Step 3: Implement two-stage controller recovery**

Add `connectOnce()` to `UnavailableVpnRpcClient`. Make `initializeRuntimeMirror()` begin registry hydration, await the one-attempt probe, and on failure start exactly one caught/stored full recovery promise before returning. Bind/sync the runtime mirror before publishing the authoritative snapshot. On transport-connect bounded exhaustion complete the gate as stopped. Check `disposed` after every background await so close cannot bind or publish late. Leave `runStartConnectFlow()` on `connect()`.

For authenticated transport whose mirror binding fails, retain `RECOVERING`, retry binding at `250/500/1000/2000/4000 ms`, and on exhaustion publish `VPN_PROXY_REPLAY_FAILED` as a stoppable active `ERROR` rather than false `STOPPED`. Apply bind-before-publish to user start and steady runtime-event paths as well as startup hydration.

- [ ] **Step 4: Re-run entry, shared, and focused structure tests and verify GREEN**

Expected: all commands pass with no test failures.

### Task 4: Gate node navigation and make recovery copy truthful

**Files:**
- Modify: `harmony/entry/src/test/HomeViewModel.test.ets`
- Modify: `harmony/entry/src/main/ets/presentation/HomeViewModel.ets`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Modify: `harmony/tests/structure/vpn-local-socket-rpc-contract.test.mjs`
- Modify: `docs/harmony/vpn-runtime-bridge.md`

- [ ] **Step 1: Write failing presentation and documentation contracts**

Assert a READY application with eligible profile plus registry `RECOVERING` has VPN action `BUSY` and `canManageProxies === false`; `STOPPED` and `RUNNING` remain eligible. Pin generic state-restoration copy and document the foreground probe/background bounded recovery split.

- [ ] **Step 2: Run entry and focused structure tests and verify RED**

Use the Task 3 commands. Expected: proxy-management or documentation assertions fail.

- [ ] **Step 3: Implement minimal presentation/doc changes**

Restrict node management to eligible `STOPPED`/`RUNNING` states. Generalize the recovery resource text so it does not falsely claim a network-change cause. Document fail-closed behavior without endpoints, identities, signing data, or private RPC values.

- [ ] **Step 4: Re-run entry and focused structure tests and verify GREEN**

Expected: all focused gates pass.

## Chunk 3: Review, verification, signed package, and device proof

### Task 5: Review and run the complete automated matrix

**Files:**
- Review only the files touched by Tasks 1-4.

- [ ] **Step 1: Run spec-compliance then code-quality review**

Resolve every Critical or Important finding and re-run affected tests. Do not use the dirty worktree's unrelated diff as this task's review range.

- [ ] **Step 2: Run Go and native gates**

```sh
CMFA_TASK_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_TASK_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_TASK_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go test ./... -count=1
GOMODCACHE="$CMFA_TASK_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go test -race ./... -count=1
GOMODCACHE="$CMFA_TASK_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go vet ./...
cd "$CMFA_TASK_ROOT/harmony/core/go/probe"
go test -race -count=1 ./...
cd "$CMFA_TASK_ROOT"
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case tun-contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/test-native-host.mjs --case napi-proxy
node harmony/tools/test-native-host.mjs --case napi-tun
```

- [ ] **Step 3: Run all structure and ArkTS gates**

```sh
node --test harmony/tests/structure/*.test.mjs
cd harmony
./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

- [ ] **Step 4: Check only task-owned text diffs**

Run `git diff --check` with the explicit Task 1-4 file list. Fix only genuine regressions in those files.

### Task 6: Build and install the signed HAP with signing isolation

**Files/Artifacts:**
- Temporarily modify and restore byte-for-byte: `harmony/build-profile.json5`
- Read only: `.codex-secure/harmony-build-profile.signed.json5`
- Generate: `harmony/artifacts/phase1-native-provenance.json`
- Generate: `harmony/entry/build/default/outputs/default/entry-default-signed.hap`

- [ ] **Step 1: Validate the bounded signing window privately**

Require secure directory mode `0700`, signed backup mode `0600`, and the current tracked profile to match `.codex-secure/harmony-build-profile.unsigned-baseline.json5` byte-for-byte. Never print signing-profile contents, paths, aliases, passwords, certificates, or device identity.

- [ ] **Step 2: Build through the existing secure wrapper**

```sh
node .omx/task16-build-signed-production.mjs
```

Require JSON fields `profilePrepared=true`, `buildExit=0`, `unsignedBaselineRestored=true`, `manifestPresent=true`, `result="pass"`, and `stubDetected=false`.

- [ ] **Step 3: Prove baseline restoration and package identity**

```sh
cmp -s harmony/build-profile.json5 .codex-secure/harmony-build-profile.unsigned-baseline.json5
node --test harmony/tests/structure/signing-isolation.test.mjs
node harmony/tests/bin/inspect-hap.mjs --hap harmony/entry/build/default/outputs/default/entry-default-signed.hap --manifest harmony/artifacts/phase1-native-provenance.json --build-kind production
```

Require a non-empty signed `entry` HAP for bundle `com.github.kr328.clash.harmony`, version from `harmony/AppScope/app.json5`, without printing signing data.

- [ ] **Step 4: Install in place**

```sh
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc list targets
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc install -r harmony/entry/build/default/outputs/default/entry-default-signed.hap
```

Require exactly one connected target and successful replacement install. Do not uninstall or clear app data.

### Task 7: Measure Home readiness and verify fail-closed recovery

**Files:**
- Use only protected temporary layout/timing files created with `mktemp -d`; remove remote and local temporary files in `finally`.

- [ ] **Step 1: Define the observable ready signal**

Use the integrated DevEco HDC binary for every command:

```sh
CMFA_HDC_BIN="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
```

Use `$CMFA_HDC_BIN shell uitest dumpLayout -i -p <remote-json>` and poll at bounded intervals. Home is ready only when exactly one visible node with semantic id `home.vpn.action` exists; the loading page does not contain that id. Never match localized text inside the application.

- [ ] **Step 2: Measure three cold launches**

For each sample, run the exact command family:

```sh
"$CMFA_HDC_BIN" shell aa force-stop com.github.kr328.clash.harmony
"$CMFA_HDC_BIN" shell aa start -a EntryAbility -b com.github.kr328.clash.harmony
"$CMFA_HDC_BIN" shell uitest dumpLayout -i -p /data/local/tmp/cmfa-fast-start-layout.json
"$CMFA_HDC_BIN" file recv /data/local/tmp/cmfa-fast-start-layout.json <protected-temp-path>
```

Measure monotonic host time from `aa start` dispatch until the ready id appears, remove the remote layout after every poll, and take the median. Require median `<= 2.5s`; `>= 4.0s` is failure.

- [ ] **Step 3: Measure three warm launches**

For each sample, run `"$CMFA_HDC_BIN" shell uitest uiInput keyEvent Home` to background the app without killing its process, then run `"$CMFA_HDC_BIN" shell aa start -a EntryAbility -b com.github.kr328.clash.harmony` and poll the same semantic id. Record three samples and median.

- [ ] **Step 4: Verify the no-Extension transition**

Immediately after a cold Home appears, require the VPN action and `home.proxy.manage` to be disabled while startup mirror recovery is pending. After the original bounded window exhausts, require the action/navigation to become enabled for an eligible profile.

- [ ] **Step 5: Verify an existing VPN session restoration**

Start VPN through the app's existing semantic UI controls. For app-owned controls, resolve a unique node from the app layout and click its bounds center. Verify the system VPN indicator or ongoing notification by reusing the existing Phase 4 merged system-window/notification-center layout selectors after `uiInput keyEvent Home`; system surfaces are not required to expose app semantic ids. Never use fixed coordinates or language-only matching, and classify missing/ambiguous system selectors as `UI_AUTOMATION_UNSUPPORTED`. Reopen `EntryAbility` without stopping the Extension and require the authoritative running state before VPN/node actions are enabled. Then stop VPN through the app and verify the system indicator disappears. Never print node/provider/session data.

- [ ] **Step 6: Cleanup and report**

Gracefully stop VPN, force-stop the owned app, delete remote layouts and local temporary roots, and confirm `harmony/build-profile.json5` still matches the unsigned baseline. Report changed files, simplifications, test results, package variant/version/path, install result, cold/warm samples and medians, recovery behavior, release-metadata status, and remaining risk. Do not commit or push.
