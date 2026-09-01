# HarmonyOS 第一阶段运行控制与诊断设计

**状态：** 已批准执行
**日期：** 2026-08-31

## 目标

在现有“配置导入、节点选择、系统 VPN/TUN 全局接管”主链不变的前提下，补齐三个日常使用必需能力：真实网络切换恢复、Rule/Global/Direct 当前会话模式控制，以及可过滤、复制、清理和导出的日志中心。

## 范围边界

- 网络恢复必须监听 HarmonyOS 默认网络的可用、丢失和能力变化事件，驱动现有 `VpnRuntimeCoordinator` 的 `RECOVERING` 状态机。
- 模式切换只修改当前 VPN Extension 进程中的 Mihomo tunnel mode。它不改写订阅 YAML，也不创建持久 Override；VPN 下次启动重新采用配置默认模式。
- Go runtime-control setter 在成功写入 Mihomo tunnel mode 后关闭现有 outbound trackers，使后续连接立即按新模式重新决策；RPC 与 UI 不重复承担连接清理。
- 日志只保存产品运行日志，不抓取系统全局 Hilog/Logcat。落盘前必须对 URL、令牌、绝对路径和结构化 secret 字段脱敏。配置名和节点名允许出现在应用私有日志页中，以保留排障价值，但不得写入公共 Hilog、测试证据或最终交付报告。
- 日志历史有明确大小与条数上限，Extension 是唯一写入者，UI 只读取或清理，避免跨进程并发追加损坏。
- 不恢复已删除的 Local proxy UI，不增加 System Proxy、Provider 或高级 Override 设置。

## 架构

### 1. 网络恢复

新增生产 `HarmonyNetworkConnectionDriver`，封装 `@kit.NetworkKit` 的 `connection.getDefaultNet`、`connection.getNetCapabilities` 与 `connection.createNetConnection`。Driver 将系统 `NetHandle.netId` 转换为不含设备信息的字符串 ID，将 `NET_CAPABILITY_INTERNET` 与 `NET_CAPABILITY_VALIDATED` 同时存在视为 usable。

`PlatformFactory.createNetworkRecoveryPort()` 显式注入生产 Driver，不再使用 `HarmonyNetworkMonitor` 的 opaque 默认实现。清单新增普通权限 `ohos.permission.GET_NETWORK_INFO`。现有 monitor 继续负责单注册、多订阅、状态克隆和 dispose；现有 coordinator 继续负责退避与恢复，不复制状态机。

### 2. 当前会话模式

在 Go/Mihomo 边界增加封闭枚举 `RULE | GLOBAL | DIRECT` 的 query/set API，经稳定 C ABI、Node-API、`CoreService` 暴露。非法值在每一层拒绝；set 只在正在运行的 VPN 会话中允许。

认证 LocalSocket RPC 新增 `GET_MODE` 和 `SET_MODE`，并增加严格的 mode payload codec。服务端复用现有 profile/revision/catalog/session guards，避免旧 UI 会话修改新 VPN 会话。UI 端 `RuntimeToolsService` 负责连接、获取 active context、发起请求并返回类型化结果。

首页运行卡显示当前模式；VPN 运行时可点击 Rule、Global、Direct 三个按钮即时切换。请求进行中禁用重复操作，失败保持旧模式并显示脱敏错误。Rule 仅表示执行配置规则，不承诺自动国内直连。

### 3. 日志中心

新增共享日志模型与平台 `HarmonyRuntimeLogStore`。VPN Extension 在创建 CoreService 后立即订阅 `CoreEvent`，只消费 `type: log`，经脱敏、长度限制后串行写入 JSONL。当前文件达到上限后原子轮转为一个 previous 文件，因此历史有界且读取不会看到半写入 JSON。

UI 通过同一应用沙箱中的只读 repository 每 500 ms 刷新。日志页支持：

- All / Debug / Info / Warn / Error 等级筛选；
- 关键字搜索；
- 点击单条复制；
- 手动刷新与清理；
- 通过 `DocumentViewPicker.save()` 导出 UTF-8 文本。

导出内容再次脱敏。文件选择取消不显示错误；真实写入失败显示可重试错误。日志页从首页进入并提供返回首页按钮。

## 错误与生命周期

- 网络权限或注册失败时 monitor 保持 unavailable，不伪造网络可用；VPN 状态机进入可见恢复/错误路径。
- 默认网络事件按 netId 去重；丢失非当前网络不得误判当前网络离线。
- RPC 模式请求必须在 `RUNNING` 状态、正确 generation 和 guards 下执行。
- Extension 停止时先取消 Core log subscription，再等待日志写队列完成，最后释放平台与 Core 资源。
- UI 销毁时停止日志轮询并忽略迟到结果。

## 验收标准

1. 生产构建不再实例化 opaque network driver，并声明 `GET_NETWORK_INFO`。
2. Wi-Fi/热点/蜂窝切换产生 unavailable/usable 事件，现有 coordinator 进入 RECOVERING 并恢复 RUNNING。
3. 首页在 VPN 运行时显示当前模式，三种模式均可即时切换；停止时禁用切换。
4. 模式请求经过认证 RPC，旧会话和非法 mode 均被拒绝。
5. 日志页可实时看到 Extension core 日志，可筛选、搜索、复制、清理与导出。
6. 日志文件和 UI 状态不包含订阅 URL、token、绝对路径或设备标识；配置名和节点名只允许停留在应用私有日志文件/UI，不进入公共日志和测试证据。
7. Go、Core、Shared、Platform、Entry 测试以及结构测试通过，并能产出新签名 HAP。
