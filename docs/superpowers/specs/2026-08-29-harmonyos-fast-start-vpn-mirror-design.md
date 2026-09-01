# HarmonyOS Fast Startup VPN Mirror Design

## Context

Clash Meta 的 HarmonyOS UI 冷启动目前约 16 秒，热启动约 1.3 秒。真机日志显示 ArkUI、RDB、HUKS、订阅内容和 native core 初始化都在毫秒级完成；固定延迟来自 `CoreComposition` 在发布 `READY` 前等待 VPN runtime mirror，而 `HarmonyVpnController.initializeRuntimeMirror()` 调用了带 15 秒可用性窗口的 `VpnRpcClient.connect()`。

连接策略混合了两个场景：

- UI 冷启动需要尽快发现已经可连接的 VPN Extension，并恢复权威快照。
- Extension 尚在启动、正在退出，或既有 RPC 连接掉线时，transport 暂时不可达并不等于 VPN 已停止，仍需要完整重试窗口。

代码证明 RPC server 在 VPN coordinator 启动前开始监听，但也存在两个无 server 的过渡窗口：Extension 可能尚未完成 server 初始化；停机时 server 会先关闭，随后才停止 coordinator 和 TUN。因此，单次探测失败不能直接解释为权威 `STOPPED`。

## Goals

- 让首页在普通冷启动时不再被 15 秒 RPC 重试窗口阻塞。
- 在 runtime mirror 仍不确定时明确 fail-close，禁止 VPN 启动、节点切换、节点测速和 stopped-core lease。
- 已可连接的运行会话仍在首个 `READY` 前完成认证、快照恢复和 mirror 绑定。
- Extension 启动/退出窗口继续使用原有 15 秒 bounded retry，期间 UI 可以显示但不能执行冲突操作。
- 保留用户主动启动 VPN 和连接掉线恢复时的完整重试语义。
- 不新增依赖，不修改 Android，不暴露运行态、设备或签名隐私信息。

## Non-goals

- 不把一次 transport failure 当作系统 VPN 已停止的证明。
- 不引入文件、RDB、CommonEvent 或静态 native bridge 作为跨进程状态回退。
- 不改变 LocalSocket 认证、MAC、frame、重放保护或业务协议。
- 不重构节点页面；恢复期间从首页禁止进入，已有深层页面请求仍由 service fail-close。

## Options Considered

### 1. Shorten `connect()` globally

Rejected. `connect()` 也服务于刚启动的 Extension 和断线重连；缩短会破坏真实 VPN 启动容错。

### 2. Use one startup attempt and immediately publish `STOPPED` on failure

Rejected. Extension 启动前段和停机 drain 都可能暂时没有 RPC server，但 VPN lifecycle 尚未终结。此时发布 `STOPPED` 会让 Home、one-click node activation 和 stopped-runtime proxy routing fail-open。

### 3. Move the existing 15-second connect entirely to the background

Safe only with an explicit hydration gate, but unnecessarily delays restoration when an already-running server is immediately available.

### 4. Foreground one-attempt probe plus fail-closed background recovery

Selected. The controller first performs one complete LocalSocket connection, mutual authentication, and bootstrap `GET_SNAPSHOT` before returning from startup hydration. Success preserves mirror-before-`READY`. Failure marks the registry as hydration-pending/`RECOVERING`, starts the existing bounded `connect()` in the background, and returns so the application can publish `READY`. The pending gate remains authoritative until background recovery succeeds or the existing retry window definitively exhausts.

## Architecture

### `VpnRpcClientPort`

Add a required method:

```ts
connectOnce(): Promise<void>;
```

The existing method remains:

```ts
connect(): Promise<void>;
```

- `connectOnce()` performs at most one socket/auth/bootstrap attempt and never schedules connection backoff.
- `connect()` preserves the current bounded retry window.
- Both return immediately when already `READY`.
- If full `connect()` arrives while a one-attempt connection is in flight, it waits for that attempt and, on its failure, starts its own bounded retry. A one-attempt caller may join an already-running bounded connection. This prevents a one-shot promise from silently downgrading a full caller's retry contract.

Both methods delegate to shared transport/auth/bootstrap logic. A failed one-attempt path uses existing cleanup, schedules no `wait()`, returns to `DISCONNECTED` unless `close()` already won, and leaves the client reusable.

### `VpnSessionRegistry`

Add an explicit startup hydration gate with two operations:

```ts
beginRuntimeMirrorHydration(): void;
completeRuntimeMirrorHydrationUnavailable(): void;
```

Beginning hydration publishes a `RECOVERING` snapshot while retaining any known active request. It also records an internal pending flag. While pending:

- `beginPending()` rejects a new VPN session as already live/busy.
- `acquireStoppedProxyLease()` returns no lease.
- Home resolves the primary VPN action as `BUSY`.
- Home does not expose node management.
- Proxy routing sees a non-`STOPPED` snapshot and rejects operations as runtime-not-ready.

An accepted authenticated RPC snapshot clears the pending flag and becomes authoritative. If the bounded background connection exhausts, `completeRuntimeMirrorHydrationUnavailable()` clears the gate and publishes `STOPPED`, matching the prior post-15-second behavior.

### `HarmonyVpnController`

`initializeRuntimeMirror()` becomes a two-stage orchestration:

1. Mark registry hydration pending.
2. If client is already `READY`, synchronize mirror and registry before returning.
3. Otherwise await `connectOnce()`.
4. On one-attempt success, bind/synchronize the runtime mirror and publish the authenticated snapshot before returning.
5. On one-attempt failure, start one owned background `connect()` recovery and return immediately.

Background recovery:

- keeps the registry `RECOVERING` while in flight;
- on success, binds the runtime mirror before publishing the final registry snapshot;
- on retry-window exhaustion, completes the hydration gate as `STOPPED`;
- catches all errors, never creates an unhandled rejection, and never moves the global composition to `ERROR` after `READY`;
- checks the controller disposal token before binding or publishing.

If transport is authenticated but runtime-mirror binding fails, the registry stays `RECOVERING` and the controller retries binding after `250/500/1000/2000/4000 ms`. Exhaustion becomes a safe `ERROR` with `VPN_PROXY_REPLAY_FAILED`, preserving the active request/live owner so Stop remains available; it must never claim `STOPPED` while the VPN may still be alive.

`runStartConnectFlow()` remains on ordinary `connect()`.

### `CoreComposition`

No source-order rewrite is required. It still awaits `initializeRuntimeMirror()` before creating `ProfileApplication` and publishing `READY`. The controller method now returns after either immediate hydration or safe scheduling of owned recovery. Therefore:

- immediately available active sessions remain authoritative before `READY`;
- unavailable transport no longer holds the global loading screen for the full retry window;
- the registry is already `RECOVERING`, not `STOPPED`, when `READY` is published.

### Presentation

`HomeViewModel` allows node management only when the application/profile are eligible and VPN state is exactly `STOPPED` or `RUNNING`. Existing `RECOVERING` handling keeps the main action busy. The recovery copy becomes generic runtime-state restoration copy rather than claiming every recovery is caused by a network change.

No Proxy page API change is required. Home navigation is disabled during startup hydration, and service-layer routing remains fail-closed for any direct or stale page request.

## Failure and Concurrency Semantics

- No Extension: one attempt fails promptly, Home reaches `READY` with registry `RECOVERING`, background retry continues, then registry becomes `STOPPED` after the existing bounded window.
- Stable running Extension: one attempt succeeds and mirror is fully restored before `READY`.
- Extension still starting: one attempt can fail; background retry connects when server begins listening; registry remains fail-closed until then.
- Extension draining: one attempt can fail; registry remains fail-closed throughout the existing retry window rather than claiming early `STOPPED`.
- Invalid handshake/protocol: background bounded behavior remains the same as existing `connect()` and private details remain hidden.
- Mirror binding failure: bounded mirror retries keep actions fail-closed; exhaustion exposes a stoppable `ERROR`, not a false stopped state.
- Close during either connection: `CLOSED` stays authoritative, controller disposal prevents late mirror binding or registry publication, and the owned recovery promise is rejection-safe.
- Full connect racing one-shot: full retry is not downgraded; it continues with a bounded attempt if the one-shot fails.

## Testing

### Registry gate

- Beginning hydration publishes `RECOVERING`, blocks new sessions, and denies stopped leases.
- Authenticated `RUNNING` and `STOPPED` snapshots clear the gate.
- Exhaustion completion publishes `STOPPED` and re-enables the normal stopped paths.

### Shared RPC client

- Refused `connectOnce()` performs one socket call, schedules no backoff, and ends `DISCONNECTED`.
- A later full `connect()` retries and reaches `READY`.
- A concurrent full caller is not downgraded by an in-flight one-shot.
- `close()` winning over one-shot leaves `CLOSED`.
- Existing 15-second exhaustion tests remain unchanged and passing.

### Controller/composition/presentation

- One-shot success hydrates and binds before first `READY`.
- One-shot failure returns startup control while full recovery is still pending and registry is `RECOVERING`.
- Background success publishes `RUNNING`; background exhaustion publishes `STOPPED`.
- Mirror bind retry success publishes only after the latest snapshot/context is stable; retry exhaustion preserves a stoppable active error.
- Dispose prevents a late background success from binding or publishing.
- User start still uses full `connect()`.
- Home VPN action and proxy-management navigation remain disabled during startup hydration.

### Structure and docs

- Contracts pin startup probe to `connectOnce()`, background/start flow to `connect()`, and mirror-before-READY ordering.
- Runtime bridge docs describe the two-stage policy and fail-closed interval without private data.

## Acceptance Criteria

- All shared, entry, structure, native, and Go gates pass.
- A signed debug/default HAP builds and installs on the connected HarmonyOS 6.x device.
- With no active VPN, three forced-stop launches show the Home route with a median at or below 2.5 seconds; 4 seconds or more fails the startup fix.
- During the background retry interval, the Home VPN action and proxy-management entry remain disabled rather than reporting authoritative stopped state.
- After the bounded window exhausts with no Extension, controls become available normally.
- With a running Extension, reopening the UI restores the authoritative runtime before actions are enabled.
- Starting VPN after the stopped state settles retains the original bounded Extension-start retry behavior.
