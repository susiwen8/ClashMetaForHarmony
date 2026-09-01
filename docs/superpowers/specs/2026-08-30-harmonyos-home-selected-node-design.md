# HarmonyOS 首页当前节点展示设计

## 背景

HarmonyOS 首页已经能展示 VPN 全局接管状态，但 VPN 进入 `RUNNING` 后，用户无法在首页确认当前流量实际使用的是哪个代理节点。代理页已有顶层组查询、嵌套组导航和一键切换能力，本功能只补充首页的只读运行态摘要，不改变节点选择、VPN 启停或 RPC wire protocol。

## 目标

VPN 为 `RUNNING` 时，首页的 `RuntimeStatusCard` 显示：

- 主要代理组名称
- 该组当前选择最终解析到的 terminal node 名称

VPN 停止、启动中、恢复中、停止中、等待授权、报错，或代理查询不能得到可信结果时，不显示这两行。节点一键切换成功后，首页自动刷新，无需重启应用或 VPN。

## 非目标

- 不展示服务器地址、端口、订阅地址、group path、profile/revision/session identity。
- 不把节点名称写入日志、设备 proof 或诊断文件。
- 不新增、修改或扩展 VPN RPC wire protocol。
- 不改变代理页默认组、节点切换和延迟测试行为。
- 不处理 Android 版本。

## 主要代理组规则

首页与代理页保持一致：调用 `listGroups()`，以返回列表中的第一个顶层组作为主要代理组。不额外排序，也不另行猜测名为 `GLOBAL`、`Proxy` 或 `Selector` 的组。

如果列表为空或返回 `REJECTED`，本次结果为不可用。

## 最终节点解析

`ProfileApplication` 提供一个只读聚合查询，内部复用现有 `listGroups()` 与 `queryGroup()`：

1. 查询第一个顶层组，并读取 `selectedName`。
2. 在当前组 `nodes` 中精确匹配同名且 `selected === true` 的成员。
3. 如果成员不是组，返回 `{ groupName, nodeName }`；其中 `groupName` 始终是第一层主要组名，`nodeName` 是最终 terminal node 名称。
4. 如果成员仍是组，把组名追加到从顶层开始的包含式 `groupPath`（例如 `[top, child, grandchild]`），并用完整路径查询下一层。

解析最多访问 16 个组，和现有 `cloneVpnProxyGroupPath()` 的 16 segment 上限一致。应用层把“下一层组名已经出现在当前祖先路径中”视为循环候选并 fail-close；这只约束当前单条祖先链，不会把不同父节点下、未出现在同一祖先链上的同名组误判为循环。运行态 catalog 已把真正的 ancestor cycle 折叠为 `CYCLE_UNSUPPORTED` terminal edge；该边无法形成可信 group snapshot 时同样隐藏。发现循环候选、超过深度上限、空选择、选中成员缺失、选中标记不一致、identity 在多次查询间变化、`REJECTED` 或异常时，返回 `undefined`。失败不产生新的用户错误卡，也不记录节点信息。

### 运行态 selected group 兼容

RPC payload 已允许 `VpnRpcGroupNode.kind` 为 `GROUP` 或 `TERMINAL`，并用 `selectedNodeId` 指向唯一的 selected member；wire protocol 无需变化。但当前 `VpnRpcProxyHandler.createGroupSnapshotFromQueryPayload()` 错误地只按 `TERMINAL` 解析 `selectedNodeId`，导致顶层组选中子组时查询失败。

本功能同时修正该本地映射：

- `selectedNodeId` 可以解析为当前 group 的 `GROUP` 或 `TERMINAL` child。
- `CoreProxyNodeSummary.selected` 对两种 kind 都按 child ID 设置。
- 返回的 `selectedName` 使用该 child 的本地名称。
- 仍然要求 payload 中 selected member 唯一、属于当前 group，并与 nodes 列表一致。

该改动只修复 RPC client adapter 的现有模型映射，不改变 payload、codec、server method 或 opaque ID 规则。

### 运行态 session generation 一致性

真机验证发现，现有 `ProxyService` 会为 `listGroups()`、`queryGroup()` 和 selection confirmation 分别递增 generation，但 RPC 协议把 envelope 的 `sessionGeneration` 定义为同一 RUNNING VPN session 内的固定 guard。服务器在第一条正 generation 请求上固化该值，后续不同值必然返回 `SESSION_CHANGED`。因此运行态会出现“第一条 `listGroups` 成功，第二条 `queryGroup` 固定失败”，首页和代理页都无法读取节点。

本功能在 `ProxyService` 修复 generation 分配语义。真机后续回归进一步确认，UI 进程自己的 generation 历史可能已经被停止态查询推进，不能假定它与 VPN Extension 的 RPC session generation 从同一个数值开始。因此跨进程运行态必须以认证 RPC context 为权威：

- `UiVpnRpcRuntimeMirror` 将 `VpnRpcClient.activeContext().sessionGeneration` 随当前完整 `ProxyRuntimeIdentity` 一起绑定到 `VpnProxyCommandBus`；
- `ProxyService` 的 RUNNING query/select/delay 优先复用该权威 generation，不使用停止态查询留下的本地计数；
- command bus 只对完全相同的 profile、revision、revision hash 和 session 暴露该 generation，解绑或 identity 改变后立即失效；
- 没有跨进程 RPC authority 的进程内 handler 继续按完整 RUNNING identity 复用本地 generation。
- STOPPED 本地 core 路径继续逐次递增 generation，保留原有 stale snapshot 保护。
- `VpnRpcPayloads`、codec、client、server 和 wire protocol 不变。

该规则是跨进程协议既有不变量的调用侧修复，不是把 `SESSION_CHANGED` 放宽或吞掉。

## 状态与异步一致性

`HomeViewModel` 是首页状态的唯一生产者：

- 只在应用为 `READY` 且 VPN 为 `RUNNING` 时发起查询。
- 进入任何非 `RUNNING` 状态时，立即清空组名和节点名，并使先前查询失效。
- 以单调递增 epoch 和当前 VPN session ID 校验异步结果。旧请求、已结束会话或已 dispose 的结果不能覆盖当前状态。
- 构造时若已有运行中的 VPN，自动加载一次。
- 订阅 `OneClickVpnOperationSnapshot`；仅当 operation 结束且 `outcome === 'SUCCEEDED'` 时刷新。
- 查询失败或返回 `undefined` 时清空显示字段，但不影响 VPN 状态和控制按钮。

本功能在既有 `HomeViewState` 上只新增两个展示字符串；空字符串表示隐藏。新增字段不承载代理快照、group path 或 runtime identity，既有 `activeProfile` 等首页字段保持不变。

## ArkUI 投影

既有真机验证表明，复合 `@State/@Prop` 可能漏掉部分字段刷新。新字段沿用已经验证的 primitive 投影模式：

- `Index` 保存独立的 `@State string`：主要组名和最终节点名。
- 每次 Home state 发布后显式复制两个字符串。
- 通过 `@Link` 依次传入 `HomePage` 和 `RuntimeStatusCard`。
- `RuntimeStatusCard` 使用组件成员 `@Builder` 渲染动态区域；不使用组件外全局 builder 接收这两个动态字符串。
- 两个字符串都非空时才渲染“代理组”和“当前节点”两行。

## 安全与隐私

当前节点展示模型只允许 `groupName` 和 `nodeName`。测试必须确认这两个新增字段以及 `Index` 的两个局部 primitive state 不携带：

- session ID、profile/revision identity
- group path
- 订阅 URL 或 token
- 本地代理地址和端口

生产代码不得为该查询新增 `hilog`、proof 字段或持久化记录。

## 测试策略

### Shared application 层

- 直接选择 terminal node。
- 选择嵌套组并解析最终 terminal node。
- 循环、超过 16 层、查询拒绝、异常、identity 变化和不一致选中标记均返回 `undefined`。

### Running RPC adapter 层

- `selectedNodeId` 指向 group child 时，返回的 group snapshot 正确标记该 child 为 `isGroup === true` 且 `selected === true`。
- 既有 terminal selection、重复/未知 ID、payload 不一致和 raw-name 隐私合同不回归。

### Running routing generation 层

- 同一 RUNNING identity 的 `listGroups -> queryGroup -> selection confirmation -> select/delay` 使用同一个 generation。
- RUNNING identity 变化后分配新 generation。
- STOPPED query 仍逐次递增。
- 真机上运行态代理页不再显示 `VPN_SESSION_CHANGED`，首页可以继续查询最终节点。

### Presentation 层

- 初始 VPN 已为 `RUNNING` 时自动显示。
- 所有非 `RUNNING` 状态立即隐藏。
- 一键切换成功后刷新；失败不刷新。
- 查询失败隐藏，不生成额外错误卡。
- 旧 session/旧 epoch 的慢结果不能覆盖新状态。
- dispose 后不再发布结果，并解除全部订阅。

### UI 合同

- `Index -> HomePage -> RuntimeStatusCard` 使用两个独立 primitive `@Link`。
- 动态区域是 `RuntimeStatusCard` 的成员 builder。
- 使用资源化标签，不硬编码界面文案。
- 停止态不保留旧节点文本。

## 真机验收

1. 启动 VPN，等待状态进入 `RUNNING`。
2. 首页显示主要代理组和当前最终节点。
3. 进入代理页，选择另一个可用 terminal node，等待一键切换成功。
4. 返回首页，节点名称自动变为新节点。
5. 停止 VPN，两行立即消失。
6. 验收记录只确认“显示值与所选值一致”，不得采集或输出实际节点名称。
