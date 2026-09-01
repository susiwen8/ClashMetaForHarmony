# HarmonyOS VPN 通知栏上下行速度设计

## 目标

VPN 系统全局接管进入可用状态后，复用现有 HarmonyOS 长时任务通知，每秒显示当前上行和下行速度：

`↑ 1.2 MiB/s  ↓ 680.0 KiB/s`

通知只显示固定产品标题和流量速度，不显示配置名、节点名、订阅地址、URL token 或其他用户数据。VPN 停止、系统撤销或 UIAbility 释放时停止刷新，不残留第二条普通通知。

## 现有边界

- TUN 累计字节的权威来源位于 VPN Extension 进程，`txBytes` 表示上行累计字节，`rxBytes` 表示下行累计字节。
- 真正的长时任务通知由 UIAbility 中的 `HarmonyVpnNotificationDriver` 持有；VPN Extension 只获得逻辑 notification lease。
- 当前 VPN RPC 的 runtime payload 只传高层状态，故 UI 进程无法读取 TUN 累计字节。
- `VpnExtensionComposition` 会过滤高频 `SNAPSHOT` 事件。直接开放该事件会把底层 250ms TUN 采样放大为跨进程流量，不适合作为一秒通知刷新机制。

## 方案比较

### 方案 A：VPN Extension 计算速率并经 RPC 推送

UI 实现较轻，但采样时钟和展示语义进入 runtime authority；恢复、UI 重建及通知失败会更容易反向耦合 VPN 生命周期。拒绝。

### 方案 B：RPC 传累计字节，UI 每秒拉取并计算

Extension 只暴露原始、单调的累计计数；UI 以通知自己的 1 秒刷新节奏计算差值。职责清楚，失败可隔离，也不需要打开 250ms 高频事件。采用。

### 方案 C：RPC 传累计字节并推送每个 TUN snapshot

无需主动拉取，但会改变现有 event 过滤策略并产生约四次/秒的跨进程事件。收益不足，拒绝。

## 数据合同

`VpnRpcRuntimeSnapshotPayload` 在固定 key 顺序中新增：

- `txBytes`: safe non-negative integer；没有活跃 TUN 时为 `0`；
- `rxBytes`: safe non-negative integer；没有活跃 TUN 时为 `0`。

`VpnRpcServer` 从 `VpnRuntimeSnapshot.tunSnapshot?.counters` 读取两个值。`VpnRpcBodyCodec` 继续执行 exact-key、key-order 和 safe-integer 校验。

`VpnRpcClient.refreshTrafficCounters()` 使用现有认证连接发起 `GET_SNAPSHOT`，以 bootstrap envelope 规则接受当前 session generation 的权威响应，更新本地 runtime/counter cache，并只向调用方返回复制后的 `txBytes/rxBytes`。断线、关闭或 frame 错误时清零 cache，不能继续暴露陈旧速度。

## 速率跟踪与生命周期

UI 进程新增独立的 `VpnTrafficRateTracker` 和 `VpnTrafficNotificationCoordinator`：

- VPN 首次确认 `RUNNING` 后建立 session baseline；首帧为 `0 B/s`；
- 每次成功拉取后按真实时间差计算：`bytesPerSecond = floor(deltaBytes * 1000 / elapsedMs)`；
- session 变化、计数器下降、时间不前进或拉取失败时重建 baseline，并发布 `0 B/s`；
- `RECOVERING`/断线时不得保留旧的非零速度；后续 tick 继续重试；
- 用户停止、系统撤销、start 回滚或 controller dispose 时取消唯一的定时任务并清除 baseline；
- 更新调用串行执行，下一 tick 在本次完成后再安排，避免并发 publish；
- 单次 RPC/通知失败被吞掉并在下一 tick 重试，绝不转换成 `VPN_BACKGROUND_TASK_FAILED` 或 `VPN_STOP_FAILED`。

Coordinator 不得直接调用真实 `Date.now()`、`setInterval()` 或 `setTimeout()`。它显式接收可注入的 `ClockPort` 与单次 `BoundedDelaySchedulerPort`；`HarmonyVpnController` 持有 coordinator，`CoreComposition` 注入系统时钟和 timeout scheduler，测试注入 manual clock/scheduler。Controller 在 stop、rollback、system revoke 和 dispose 时统一取消当前 task。

UIAbility 取得系统通知后立即 best-effort 写入一次 `↑ 0 B/s  ↓ 0 B/s`，因此启动阶段不会长时间只显示系统默认文案。Controller 确认 runtime `RUNNING` 后再启动真实计数轮询。

## HarmonyOS 通知实现

不能另发 BASIC_TEXT 通知。HarmonyOS 6.x SDK 对 `dataTransfer` 长时任务的要求是：

- `startBackgroundRunning(context, ['dataTransfer'], wantAgent)` 返回 `ContinuousTaskNotification.notificationId`；
- 返回对象的 `slotType` 与 `contentType` 也必须透传到 SDK 隔离层，用于诊断系统最初创建的通知类型；
- 第三方应用使用同一 ID 更新系统代理创建的实况窗；
- 更新内容类型必须为 `NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW`；
- slot 必须为 `LIVE_VIEW`；
- `systemLiveView.typeCode` 必须为上传下载类型 `8`；
- template 必须使用 `downloadTemplate`；
- `NotificationRequest.updateOnly = true`，保证 ID 不存在时失败而不是创建第二条通知。

`HarmonyVpnNotificationDriver.updateTraffic()` 通过 SDK 隔离层调用 `notificationManager.publish()`。固定标题为 `Clash Meta VPN`；`systemLiveView.text`、capsule title 和 template file name 使用同一条安全速度文案；template progress 使用中性值 `0`，不伪造一个可完成的下载百分比。

`downloadTemplate.data` 的映射固定为：`title = "Clash Meta VPN"`、`fileName = 安全速度文案`、`progressValue = 0`。Driver tests 和 structure contract 必须锁定三个必填字段。

项目继续使用兼容 API 20 的 `startBackgroundRunning(context, string[], wantAgent)` overload，不切换到 API 21+ 的 `ContinuousTaskRequest`/submode overload。真机证据表明系统可能返回 `id-ready + metadata-non-live-view`，但官方 dataTransfer 更新流程仍要求第三方应用使用返回的 `notificationId` 将系统默认通知更新为 `SYSTEM_LIVE_VIEW`。因此初始 metadata 只作为诊断，不得作为 `publish` 前置；真正的更新 gate 只保留 active session 与 `notificationId`。如果系统异常缺少 ID，动态速度更新才安全降级为 no-op，VPN 与系统默认长时任务通知仍然成功。

速度单位使用 1024 进制：

- `< 1 KiB/s`：整数 `B/s`；
- `KiB/s`、`MiB/s`、`GiB/s`：保留一位小数。

只有成功取得 `notificationId` 且 session 匹配时才允许更新。返回的 slot/content 元数据继续保留用于诊断系统初始通知类型，但不得阻断后续 `publish`。缺少 ID、错误 session、已经 stop 或 cancellation 后的更新均为安全 no-op。

## 接口边界

- `ContinuousNotificationPort.updateTraffic(sessionId, uploadBytesPerSecond, downloadBytesPerSecond)` 只用于 best-effort presentation 更新；runtime coordinator 不调用它，也不把错误纳入 VPN fatal lifecycle。
- `UiOwnedVpnExtensionAbilityApi.updateTraffic()` 把 UI Controller 的刷新请求路由到真实通知 port，并拒绝错误 session。
- `ContinuousTaskDriver.updateNotification(notificationId, title, text)` 保持 NotificationKit 类型和调用只存在于 platform adapter，shared/entry 不直接引用 `@kit.NotificationKit`。
- `VpnExtensionAbilityApi.updateTraffic()` 让 controller 不需要直接持有 platform adapter；系统 delegate 的实现为 no-op，生产 wrapper 才更新通知。

## 测试

1. RPC payload/codec：新增字段的 exact JSON、clone、负数、非整数、unsafe integer、missing/extra/order 校验。
2. RPC server/client：`GET_SNAPSHOT` 返回真实累计字节；client 定时 refresh 更新 cache；断线和关闭清零；不改变 state/context 语义。
3. Rate tracker：首帧、正常差值、非整秒、session 切换、counter 回退、时间回退和 reset。
4. Notification coordinator：单 loop、一秒串行刷新、失败归零、失败后继续、stop/dispose 取消、session 隔离。
5. UI-owned API：通知取得后先显示零速率；更新错误不回滚已启动 VPN；stop 后更新 no-op。
6. Platform driver：透传/记录启动返回的 slot/content 诊断；同 notification ID、SYSTEM_LIVE_VIEW、typeCode 8、LIVE_VIEW、downloadTemplate 三个必填 data 字段、updateOnly、固定安全文案、错误 session/no ID no-op；初始 non-live metadata 不得阻断更新。
7. Structure：NotificationKit 继续只出现在 platform notification driver；不得引入配置名、节点名、URL 或 secret。
8. 集成：shared/platform/entry Hypium、相关 structure、全量 structure、ohosTest 编译、签名 HAP、真机 VPN + 通知展开验证。

## 验收

- VPN 启动通知出现后能看到上行和下行速度，网络活动时数值变化，无流量时回到 `0 B/s`。
- 只存在原有一条 VPN 长时任务通知；点击行为和系统取消行为保持有效。
- 停止 VPN 后不再刷新，状态栏通知按原生命周期消失。
- RPC 或通知更新偶发失败不影响 VPN 连通性，下一 tick 可以恢复。
- 不输出或显示配置名、节点名、订阅地址和 token。
