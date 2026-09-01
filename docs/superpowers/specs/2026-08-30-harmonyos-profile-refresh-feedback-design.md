# HarmonyOS 配置重新获取反馈设计

## 已确认根因

真机上的 `detail.refresh` 按钮可见、enabled、clickable。点击后配置的“最近更新”值发生变化，证明按钮事件、下载、校验和提交链路均已执行成功。

问题在 presentation：`ProfileDetailViewModel` 已发布 `SUBMITTING` 和 `COMPLETED`，但 `ProfileDetailPage` 没有渲染这两个状态。刷新按钮始终显示“重新获取”、始终保持可点击外观，完成后也没有成功提示，因此用户看到的是“点击没反应”。

## 方案

直接投影既有状态，不新增 ViewModel 状态或业务分支。`SUBMITTING` 是启用、重新获取、替换来源和确认删除共用的单命令状态，因此反馈必须是页面级而不是刷新按钮专属：

已有真机经验表明复合 `@State/@Prop` 的部分字段可能漏刷新。`Index` 因此把 detail status 投影成两个独立 primitive：`detailCommandPending` 和 `detailCommandCompleted`。每次 detail state 发布、首次 `current()` 和 teardown reset 都显式同步；通过 `@Link` 传给 `ProfileDetailPage`。详情页的动态反馈使用无参成员 `@Builder` 读取这两个 link，不直接依赖复合 `state.status`。

- `state.status === 'SUBMITTING'` 时：
  - 页面显示资源化的“处理中…”提示，语义 ID 为 `detail.operation.pending`；
  - 统一禁用 enable、refresh、replace 输入框、replace 按钮和 delete 按钮，阻止所有会被 ViewModel 单命令门禁静默忽略的重复操作；
  - 返回按钮保持可用，允许用户离开；dispose/token 逻辑继续阻止晚到结果污染已离开的页面；
  - 现有 ViewModel 单命令门禁继续作为业务层保护。
- `state.status === 'COMPLETED'` 时：
  - 页面显示资源化的通用成功提示“操作已完成”；
  - 语义 ID 为 `detail.operation.completed`，便于自动化与真机验收。
- `ERROR` 继续使用现有 `SafeErrorCard`；`CONFIRMING_HTTP` 和 `CONFIRMING_DELETE` 继续使用现有 Dialog；refresh 返回 `CANCELLED`、`cancelPlainHttpConfirmation()` 或 `cancelDelete()` 时均回到 `IDLE`，不显示成功提示。

成功文案保持通用，因为 `COMPLETED` 同时用于启用配置、重新获取、替换来源和确认删除，页面当前没有操作类型字段。删除成功会立即发布返回导航，所以用户不会停留在详情页看到该提示。其余成功提示保留到下一次命令开始，或 detail ViewModel 被销毁/为其他 profile 重建；当前返回列表不会销毁同一 profile 的 ViewModel，因此重新打开同一 profile 时仍可看到上一次成功确认。这是有意的持久确认反馈，不自动超时，也不承诺离页即清除。

为这次反馈新增操作类型或定时器属于不必要的数据模型扩展。

## 备选与取舍

- 只依赖“最近更新”变化：变化位置不显眼，正是当前问题，拒绝。
- 仅显示 loading：快速请求可能一闪而过，完成后仍没有确定反馈，拒绝。
- Toast：引入一次性 effect 与生命周期处理，现有页面没有该模式，范围更大，拒绝。
- 页面级 processing + 通用完成提示：复用现有状态、覆盖全部 mutation、慢请求和快请求都有反馈，采用。

## 测试与验收

- Structure contract 先锁定并观察 RED：
  - 新资源 `detail_operation_processing`、`detail_operation_completed`；
  - `Index` 持有两个独立 boolean `@State`，在 subscription/current/reset 三处投影，并通过 `$link` 传给详情页；
  - `ProfileDetailPage` 以两个 boolean `@Link` 接收，成员 `@Builder` 渲染反馈；
  - `SUBMITTING` 渲染 `detail.operation.pending`；
  - enable、refresh、replace 输入框/按钮和 delete 均以 `!this.commandPending` 为 enabled 条件；
  - `COMPLETED` 渲染 `detail.operation.completed` 成功提示；
  - ERROR/HTTP/Delete 既有表面不被删除。
- 既有 ViewModel tests 继续验证 `SUBMITTING -> COMPLETED/ERROR/IDLE` 语义；不为纯 UI 映射新增 test-only production API。
- Structure tests 把两个新 semantic ID 纳入生产 UI 合同，并分别锁定 pending/completed 条件渲染和全 mutation disabled 条件。
- 当前 ohosTest fixture 没有稳定的远程详情数据，不能可靠制造长耗时 refresh；真实 UI 验收由已连接真机完成：点击当前订阅后观察到 pending 或最终 completed，“最近更新”继续变化。验收只记录布尔结果，不输出配置名、订阅地址或 URL token。
