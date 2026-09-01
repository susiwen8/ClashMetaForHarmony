# HarmonyOS 配置编辑与自动刷新设计

## 目标

1. 删除首页“从配置开始”整块说明卡，包括图标、标题、正文和对应资源。
2. 配置详情增加编辑模式，允许修改配置名称；远程配置还可输入新的订阅 URL。
3. 保存新 URL 后自动执行下载、校验和提交，使详情中的代理节点来自新订阅。

## 交互

配置详情在摘要卡下增加“编辑配置”按钮。点击后显示：

- 名称输入框：预填当前名称，必填，去除首尾空白后长度为 1–80；
- 订阅地址输入框：仅远程配置显示；不回显旧 URL，留空表示保持原地址；
- 明确提示“新 URL 保存后会自动重新获取节点”；
- “取消”和“保存并更新”按钮。

保存期间沿用页面级“处理中…”状态并锁住其他 mutation。成功后退出编辑模式并显示“操作已完成”。若代理节点区已经展开，完成后重新加载该配置的代理组和节点。

HTTP URL 继续使用现有确认弹窗；用户取消后保留编辑内容。配置来源损坏且需要修复时，新 URL 必填。

## 数据与隐私边界

完整订阅 URL 只进入临时输入和 HUKS 加密入口，不进入 presentation snapshot、日志、语义 ID、proof 或文档。配置详情仍只显示安全的 host/source display。

`ManageProfileUseCases.updateProfile()` 原子处理名称和可选 URL：

- 先验证名称和远程 URL；
- URL 变化时先生成新的 HUKS secret ref；
- 以一次 repository save 提交新名称、safe source display 和 secret ref；
- save 失败时删除新 secret；
- save 成功后 best-effort 删除旧 secret；删除失败不回滚已经提交的 metadata，也不把成功改成失败，遗留 orphan 交由后续 secret/repository reconcile 清理；
- 返回 `sourceChanged`，由 application facade 决定是否自动 refresh。

`ProfileApplication.updateProfile(profileId, name, sourceUrl?, allowPlainHttp)` 在现有 delay-drain/mutation 边界内保存元数据。HTTP consent 从 ViewModel 明确传到 application，再原样传给 `refresh(profileId, allowPlainHttp)`；未确认的 HTTP URL 在 metadata 保存前 fail closed。

名称单独修改允许在 VPN 运行时保存。URL 修改会改变配置内容：如果系统 VPN 不是 `STOPPED`，application 返回可见的 `RUNTIME_STOP` 错误，要求用户先停止 VPN；不会静默保存 URL 或中断当前 VPN。

`sourceChanged=true` 时 application 立即调用现有 refresh，并返回组合结果：

- `UPDATED`：新 revision 成为 current，节点查询使用新配置；或者名称单独保存且无需刷新；
- `UPDATED_REFRESH_FAILED`：metadata/URL 已保存，但 refresh 结果的 profile 为 `UPDATE_FAILED_USING_VALID` 或带 `lastError`，旧 current revision 被保留；组合结果携带安全 `AppError`；
- `FAILED`：metadata 未保存；
- 名称单独变化：不发起网络请求。

ViewModel 在 `UPDATED` 时退出编辑、清空 draft、发布 `COMPLETED`。`UPDATED_REFRESH_FAILED` 表示名称/URL 已经持久化，因此同样退出编辑并清空 draft，但发布 `ERROR` 而不是 `COMPLETED`；页面从 application snapshot 显示已保存的新名称/safe source display，用户通过现有“重新获取”重试。Index 仅在真正 `SUBMITTING → COMPLETED` 时重载代理面板，因此失败刷新不会把旧节点误报为更新成功。

## UI 状态

`ProfileDetailViewState` 增加：

- `editing`
- `editNameIssue`
- `editUrlIssue`

draft 保留在 `ProfileDetailViewModel`，不会进入公开 snapshot。ViewModel 负责进入/取消编辑、输入校验、HTTP 确认和 update 调用。Index 在 detail 从 `SUBMITTING` 转为 `COMPLETED` 且节点区展开时重新调用 profile-scoped `ProxyViewModel.load(detailProfileId)`。

## 备选方案

- 先改名、再替换 URL、再刷新：实现简单但前两步可能部分成功，拒绝。
- 回显完整旧 URL：编辑方便但会把订阅 token 解密到 UI，拒绝。
- 原子元数据保存后自动刷新：隐私边界清楚、失败语义可解释、复用现有刷新事务，采用。

## 验收

- 首页不再包含 `home_info_*` 资源或“从配置开始”卡片。
- 配置详情能进入/取消编辑；名称、URL 校验可见。
- 名称单独保存不会下载。
- 新 HTTPS URL 保存后严格按 update → refresh 顺序执行。
- HTTP URL 需要确认；取消不保存。
- VPN 运行时名称可保存，但 URL 保存 fail closed 并提示先停止 VPN。
- URL refresh 失败保留旧 current revision，错误可见。
- 展开的节点区在编辑成功后重新加载，不显示旧 snapshot。
- Entry、shared、structure、ohosTest、signed HAP 和真机流程通过；不输出配置名、节点名或 URL。
