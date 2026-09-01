# HarmonyOS 配置详情与代理节点管理合并设计

## 目标

删除首页独立的“管理代理节点”入口和独立代理节点路由，把代理组浏览、节点选择、全量测速和一键启动/切换 VPN 合并到当前配置的详情页。用户从“管理配置”进入某个配置后，直接在该配置上下文中管理对应节点。

## 已确认边界

当前代理查询和选择 API 只针对已启用配置的 authoritative Mihomo runtime，不支持在不切换 active profile 的情况下读取任意未启用配置。为避免详情配置与实际节点来源不一致，代理节点区只有在以下条件同时满足时才能展开：

- 详情页配置就是当前 active profile；
- 配置有效且可用于启动；
- VPN 状态是稳定的 `STOPPED` 或 `RUNNING`；
- 应用初始化已完成。

未启用配置仍可查看、刷新、替换来源、删除和执行“启用此配置”，但代理节点区显示“请先启用此配置”的说明，不会偷偷加载其他配置的节点。

## 采用方案：详情页内按需展开

配置详情页在配置操作之后增加“代理节点”卡片：

- 默认收起，不触发代理查询，避免每次打开详情都延长首屏时间；
- 可管理时点击“管理节点”后在同一个详情页滚动区域内展开；
- 展开内容复用既有代理组、节点列表、全量测速、延迟结果、选中状态和一键 VPN 切换逻辑；
- 展开后按钮变为“收起”，收起或离开详情页时调用既有 `ProxyViewModel.leave()`，安全取消未完成测速；
- 节点切换造成 VPN 短暂进入 `STARTING/SWITCHING` 时，已展开内容保持可见，不因临时 eligibility 变化而闪退；只有 active profile 真正变化或详情离开时才关闭。
- 已展开时，卡片标题和按钮始终保持“代理节点 / 收起”语义；同一 profile 的瞬态 VPN 状态不会把卡片替换为“请先启用此配置”提示。

首页仍保留当前配置、当前节点和 VPN 启停状态，但删除独立“管理代理节点”卡片。`AppRoute` 删除 `PROXIES`，代理管理不再是顶层页面。

## 组件与状态

### `Index`

- 继续持有单个 `ProxyViewModel`，避免复制查询、选择和测速生命周期；
- 新增 primitive `@State`：`detailCanManageProxies`、`detailProxyExpanded`；
- eligibility 由 `homeState.canManageProxies` 与详情 profile id/active profile id 的精确相等关系投影；
- 打开详情、home/detail snapshot 更新和 teardown 时显式同步，避免 ArkUI 复合状态漏刷新；
- 负责 expand/load、collapse/leave，以及返回配置列表前完成 proxy leave；
- 手动返回、删除成功 navigation intent、active profile 漂移、切换详情、composition teardown/error 都必须经过同一个受保护的详情代理清理边界；正常路由等待 `leave()`，整体 teardown 使用 `dispose()` 的等价 drain 语义；
- 向 `ProfileDetailPage` 传入代理 snapshot、render version 和现有操作回调。

### `ProfileDetailPage`

- 新增代理节点卡片及资源化说明；
- 管理按钮有独立 semantic id `detail.proxy.toggle`；
- 展开后嵌入代理管理内容，不产生第二层纵向 Scroll；
- 配置 enable/refresh/replace/delete 逻辑保持不变。

### `ProxiesPage`

- 保留现有 standalone 包装能力以降低迁移风险，但增加 `embedded` 渲染模式；
- embedded 模式不渲染返回按钮、独立页面标题、外层纵向 Scroll、页面 padding 和 safe-area padding；
- 代理组、测速、节点列表和错误处理共用同一内容 builder，不复制业务分支。

### `ProxyViewModel`

- `load()` 接收可选的 expected profile id；详情页展开必须传入当前详情 profile id；
- 新 load 开始时先发布空的 `LOADING` snapshot，再执行可能异步的旧 delay lifecycle drain，保证旧 profile 的 groups/nodes 不会短暂串入新详情；
- `listGroups()` 返回的 authoritative profile id 与 expected id 不一致时，发布 `PROXY_PROFILE_UNAVAILABLE`，绝不继续 query 或渲染节点。

### `HomePage`

- 删除 `canManageProxies`、`onManageProxies` 和 `buildManageProxiesCard()`；
- 继续显示 RuntimeStatusCard 中当前代理组/节点信息。

## 备选方案

- **详情页“配置/节点”双 Tab**：层次清楚，但需要新的 Tab 状态、返回语义和两套滚动容器，改动更大，拒绝。
- **详情页始终展开全部节点**：点击更少，但会让所有详情首屏都触发 runtime 查询，并使大量节点淹没配置操作，拒绝。
- **详情页按需展开**：不增加顶层导航、加载成本可控、复用现有代理生命周期，采用。

## 错误和并发

- eligibility 不满足时不调用 `ProxyViewModel.load()`；
- query、selection、one-click VPN、delay test 的错误继续由现有代理视图资源和 retry 逻辑处理；
- 重复展开/收起和返回共用一个 leave promise，避免同时取消测速或重复导航；
- active profile 变化为其他配置时，关闭当前详情的代理区并 leave；
- 展开前清空旧 snapshot；只有 expected detail profile id 与 authoritative list identity 完全相等后才允许显示 groups/nodes；
- 不输出或持久化配置名、节点名、订阅地址或 token 到新增诊断证据。

## 测试与验收

先写 structure contract 并观察 RED，锁定：

- 首页不再包含 `home.proxy.manage`、相关资源或回调；
- `AppRoute` 不再含 `PROXIES`，`Index` 不再构建独立代理路由；
- `Index` 精确投影 detail/active profile eligibility，并把 primitive links 与代理操作传入详情；
- 详情页包含 `detail.proxy.toggle`，不可管理提示资源化；
- embedded 代理内容没有第二层纵向 Scroll 和返回按钮，但保留 group、retry、delay、node 的原有 semantic IDs；
- 收起和返回都等待 `ProxyViewModel.leave()`。
- 手动返回、删除成功、active profile 漂移、切换详情和 teardown 都具有明确的 drain/cleanup contract；
- ineligible detail 的 toggle 不调用 `load()`，active profile 漂移会自动收起并 leave；
- load 开始立即清空旧 groups/nodes，identity 不匹配不会继续 query；

验证顺序：定向 structure RED/GREEN、Entry ArkTS tests、ohosTest 编译、全量 structure、签名 HAP 构建、覆盖安装真机。真机验收从首页进入管理配置和当前配置详情，确认首页无独立入口，详情在单一纵向滚动中可展开节点、横向切换分组、全量测速、选择节点并触发 VPN；节点触发 VPN 瞬态时展开区和“收起”语义保持可见；未启用配置只显示启用提示。三套既有 proxy device-proof runner 和对应 contracts 同步改为经“管理配置 → active profile 详情 → detail.proxy.toggle”进入，不保留不可达的首页 selector。
