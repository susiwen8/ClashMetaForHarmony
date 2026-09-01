# HarmonyOS VPN Notification Traffic Speed Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** VPN 运行时每秒在现有 HarmonyOS 长时任务通知中显示安全的上行、下行速度。

**Architecture:** VPN Extension 通过既有认证 RPC 的 `GET_SNAPSHOT` 暴露累计 `txBytes/rxBytes`，UI Controller 使用独立 coordinator 每秒拉取并以真实时间差计算速率。Platform driver 只要持有 active session 与 `notificationId` 就会尝试用同一 ID 更新 SYSTEM_LIVE_VIEW 通知；start 返回的 slot/content metadata 继续保留用于诊断，但不再作为 publish 前置；所有 per-tick 失败与 VPN fatal lifecycle 隔离。

**Tech Stack:** ArkTS, HarmonyOS 6.x BackgroundTasksKit/NotificationKit, authenticated local-socket RPC, Hypium, Node.js structure tests, Hvigor, HDC

**Constraints:** 不新增依赖；不修改 Android；不输出配置名、节点名、订阅地址或 token；保留工作树既有改动；仅用 `apply_patch` 编辑；不 commit、不 push。

---

## Chunk 1: RPC Counter Contract

### Task 1: TDD 扩展 runtime payload

**Files:**
- Modify: `harmony/shared/src/test/VpnRpcPayloads.test.ets`
- Modify: `harmony/shared/src/test/VpnRpcBodyCodec.test.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcPayloads.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcBodyCodec.ets`

- [ ] **RED:** 在 payload/codec tests 中要求 exact-order JSON 包含 `txBytes`、`rxBytes`，并覆盖 negative/fractional/unsafe/missing/extra/order failure。
- [ ] 运行 shared Hypium，读取 `shared/.test/default/intermediates/test/coverage_data/test_result.txt`，确认失败来自缺少字段。
- [ ] **GREEN:** 给 value/create/clone/encode/decode 增加 safe non-negative byte counters，保持所有既有 guard/hash 约束。
- [ ] 重跑 shared Hypium，确认新增 RPC contract cases 通过。

### Task 2: TDD 实现 server/client 权威拉取

**Files:**
- Modify: `harmony/shared/src/test/VpnRpcServer.test.ets`
- Modify: `harmony/shared/src/test/VpnRpcClient.test.ets`
- Modify: `harmony/shared/src/test/VpnRpcServerSession.test.ets`
- Modify: `harmony/shared/src/test/VpnRpcProxyHandler.test.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcServer.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcClient.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/entry/src/test/HarmonyVpnController.test.ets`
- Modify: `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets`

- [ ] **RED:** server test 要求 GET_SNAPSHOT/RUNTIME_CHANGED 映射 TUN bytes；client test 要求 `refreshTrafficCounters()` 通过 GET_SNAPSHOT 更新并返回复制值、断线/close 清零。
- [ ] 运行 shared Hypium 并确认接口/字段缺失导致预期失败。
- [ ] **GREEN:** server 缺少 TUN 时发 `0/0`；client 增加缓存和 authenticated GET_SNAPSHOT refresh，使用 bootstrap response-envelope 规则而不改变常规 command guard。
- [ ] 更新 shared/entry 中全部 `VpnRpcClientPort` implementers、fakes 与 runtime payload builders；立即重跑 shared 和 entry Hypium，确保 RPC 接口改动在本任务内闭环。

## Chunk 2: Rate and UI Lifecycle

### Task 3: TDD 实现速率跟踪器与通知刷新 coordinator

**Files:**
- Create: `harmony/entry/src/main/ets/vpn/VpnTrafficNotificationCoordinator.ets`
- Create: `harmony/entry/src/test/VpnTrafficNotificationCoordinator.test.ets`
- Modify: `harmony/entry/src/test/List.test.ets`

- [ ] **RED:** 写首样本归零、真实 elapsed 差值、session 改变、counter/time 回退、reset、单 loop、串行 tick、拉取失败归零、下一 tick 重试、stop/dispose cancellation 测试。
- [ ] 运行 entry Hypium，确认缺少 coordinator 导致 RED。
- [ ] **GREEN:** 实现 `VpnTrafficRateTracker` 与 coordinator；下一 tick 只在当前异步 tick 完成后安排；sink error 被隔离。
- [ ] 重跑 entry Hypium，确认新增测试及既有测试通过。

### Task 4: TDD 接入 UIAbility-owned VPN 生命周期

**Files:**
- Modify: `harmony/shared/src/main/ets/vpn/VpnPorts.ets`
- Modify: `harmony/entry/src/main/ets/vpn/UiOwnedVpnExtensionAbilityApi.ets`
- Modify: `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Modify: `harmony/entry/src/test/UiOwnedVpnExtensionAbilityApi.test.ets`
- Modify: `harmony/entry/src/test/HarmonyVpnController.test.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/shared/src/test/VpnRuntimeCoordinator.test.ets`
- Modify: `harmony/entry/src/test/VpnExtensionComposition.test.ets`
- Modify: `harmony/platform/src/main/ets/background/HarmonyVpnNotificationDriver.ets`
- Modify: `harmony/platform/src/test/HarmonyVpnNotificationDriver.test.ets`

- [ ] **RED:** 要求 notification acquire 后 best-effort 发布 `0/0`；Controller 仅在权威 RUNNING 后启动一个 loop，并在 stop、rollback、system revoke、dispose 时取消。
- [ ] 失败隔离断言必须明确覆盖：`lastFailure` 不变、不调用 `stopVpnExtensionAbility()`、不触发 cancellation/`handleExtensionDestroyed()`，也不产生 `VPN_BACKGROUND_TASK_FAILED`、`VPN_STOP_FAILED` 或 `VPN_SYSTEM_REVOKED` 状态转移。
- [ ] 运行 entry/shared/platform Hypium，确认 lifecycle/interface assertions 失败。
- [ ] **GREEN:** 一次性扩展 notification/API 接口，并立即让两个 platform production implementations 与所有 shared/entry/platform fakes 满足新签名；`UiAbilityOwnedContinuousNotificationPort.updateTraffic()` 为逻辑 no-op。
- [ ] 为 traffic loop 使用独立 scheduler/clock dependency，避免污染现有 runtime-mirror retry scheduler；生产 composition 注入系统时钟和 timeout scheduler。
- [ ] 重跑 entry/shared/platform Hypium，确保接口扩展不会把后续 Task 5 前的代码留在不可编译状态。

## Chunk 3: HarmonyOS Live View Notification

### Task 5: TDD 用 NotificationKit 更新同一条系统长时任务通知

**Files:**
- Modify: `harmony/platform/src/main/ets/background/ContinuousTaskDriver.ets`
- Modify: `harmony/platform/src/main/ets/background/HarmonyVpnNotificationDriver.ets`
- Modify: `harmony/platform/src/test/HarmonyVpnNotificationDriver.test.ets`
- Modify: `harmony/platform/Index.ets`
- Modify: `harmony/tests/structure/phase4-platform-boundary.test.mjs`
- Modify: `harmony/tests/structure/phase4-vpn-contract.test.mjs`
- Create: `harmony/tests/structure/vpn-notification-traffic-speed-contract.test.mjs`

- [ ] **RED:** fake driver 捕获 notification update，断言启动返回的 `slotType/contentType` 被透传并校验，原 `notificationId`、固定标题、格式化文案、wrong session/no ID/stop 后 no-op；即使初始 metadata 非 live-view，只要 id-ready 仍必须尝试更新；structure 要求 NotificationKit SDK 隔离及无敏感字段。
- [ ] 显式断言 publish 拒绝不会调用 stop/cancellation，不改变 notification lifecycle ownership；下一次 update 仍可重试。
- [ ] 运行 platform Hypium 与定向 structure，确认缺少 update 接口/SDK 调用导致 RED。
- [ ] **GREEN:** `AbilityKitContinuousTaskDriver.updateNotification()` 使用 `notificationManager.publish()` 构造 SYSTEM_LIVE_VIEW、typeCode 8、LIVE_VIEW、downloadTemplate（`title`、`fileName`、`progressValue` 三字段）、`updateOnly: true`；driver 仅按 session/notification ID 门控，slot/content 元数据继续用于诊断。
- [ ] 重跑 platform Hypium 与定向 structure。

## Chunk 4: Verification and Device Delivery

### Task 6: 全量验证、构建、覆盖安装和真机验收

- [ ] 运行：

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
node --test tests/structure/vpn-notification-traffic-speed-contract.test.mjs tests/structure/phase4-platform-boundary.test.mjs tests/structure/phase4-vpn-contract.test.mjs tests/structure/vpn-local-socket-rpc-contract.test.mjs
node --test tests/structure/*.test.mjs
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
```

- [ ] 对 Hypium 结果文件解析总数/失败数，不能只依赖 Hvigor exit code。
- [ ] 已知 API 23 lock 与本机 API 24 SDK 的环境 gate 单独记录；使用现有可成功的签名 Hvigor lane，不掩盖环境差异。
- [ ] 检查 signed HAP package/version/hash，使用 HDC 覆盖安装到已连接真机。
- [ ] 真机启动 VPN，先确认单一长时任务通知显示 `0 B/s`；制造网络流量后确认上下行数值变化；停止流量后确认回零；停止 VPN 后确认通知消失。
- [ ] 扫描 diff、测试/构建日志和 proof，只允许固定标题、单位、计数和布尔证据，不得包含配置名、节点名、订阅地址或 token。
- [ ] 发起 spec compliance 和 code quality review，修复所有 critical/important 问题后重新运行受影响验证。
