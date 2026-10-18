# Harmony VPN Runtime Bridge

当前实现已经从旧的进程内桥接方案切到真正的 cross-process authenticated RPC。鸿蒙 6 使用 `LocalSocket RPC`，鸿蒙 7 使用 loopback TCP 承载同一个协议。

核心事实：

- HarmonyOS 真机上 UIAbility 和 VPN Extension 仍然是 `two PIDs`。
- UI 只持有 `single shared UI client`，VPN Extension 只持有 `single VPN-extension server`。
- API 20–25 使用原 app-private `LocalSocket RPC`；API 26 起使用仅绑定 `127.0.0.1` 的 TCP RPC。`NetworkKit` socket adapter 只存在于 `platform` 层，按设备 API 选择，不在连接失败后切换传输。
- 密钥材料来自 `HUKS`，根 HMAC key 只生成和使用，不导出。

协议约束：

- 握手是 `mutual authentication`：`serverHello -> clientAuth -> serverAuth`。
- 后续每个 frame 都带 `MAC`，并校验 `sequence`、`clientEpoch`、`requestOrdinal`。
- server 侧有 bounded replay/response cache；旧 ordinal、重复 ordinal、指纹不一致都 fail-close。
- 业务方法和 transport errors 都是 closed enum，不接受 ad-hoc method 或动态错误名。
- public/result/doc/proof 面只允许 `opaque IDs`，不公开业务对象名称、身份值、网络端点、认证载荷或原始调试细节。

运行时职责：

- `VpnExtensionComposition` 是 sole runtime authority：维护真实 VPN state、catalog、proxy command handling、delay state、stop lifecycle。
- `CoreComposition` 在 UI 侧只创建共享 RPC client、runtime mirror 和 `VpnRpcProxyHandler`。
- `CoreComposition` 必须先完成 mirror before READY：先做 startup probe，再允许应用发布 `READY`。
- `ProxyViewModel` / `Index` 只调用 application-owned use cases，不直接接管 VPN runtime。
- reconnect、UI recreation、hot-switch、delay cancel/drain 都必须在 authenticated RPC ready 之后恢复，不允许静态 native fallback。

鸿蒙 7 调试安装兼容：

- 隔离 VPN 进程可能无法在调试数据目录创建或访问 Unix socket。API 26 起使用 loopback TCP，避免依赖目录标签；旧 socket 文件不删除。
- 端口只由 HUKS 派生的不透明地址确定；端口不是认证凭据。端口冲突拒绝启动，不接管其他 listener、不扫描备用端口。
- 仍需双向 HUKS 认证、逐帧 MAC、epoch/sequence 与已有预算。最多保留四个原生连接；已有待鉴权连接时拒绝后续候选，候选三秒超时，不允许陌生连接中断当前已鉴权会话。
- 在创建 TCP listener 前调用 `protectProcessNet()`；现有自包排除规则同时保留。

启动与恢复边界：

- startup probe 只走一次 authenticated `connectOnce`；它用于在 Home 首屏前尽快判断是否已经有可附着的 runtime authority。
- 如果 startup probe 没拿到 authoritative runtime，UI 仍然可以进入 `READY`，但 registry 会先发布 `RECOVERING`，Home 上的 VPN 主按钮保持 `BUSY`，节点管理 fail-close。
- 后台 bounded recovery 走完整 `connect()` 窗口；整个恢复窗口保持 `RECOVERING` 并 fail-close，只有在 authenticated RPC ready 且 runtime mirror 已同步后，才会把 authoritative snapshot hydrate 回 registry。
- mirror bind 本身使用 `250/500/1000/2000/4000` 的 bounded retry；它只影响 mirror 附着，不改变 runtime authority 的归属。
- 如果 mirror bind retries 耗尽，controller 会以 `VPN_PROXY_REPLAY_FAILED` 进入 safe `ERROR`，保留 active request / live owner，并继续让 Home 提供 stop available 的清理路径。
- bounded recovery 耗尽前，状态必须保持 `RECOVERING`；只有完整 `connect()` 失败并耗尽后，才 settle 到 `STOPPED`。
- 上述 mirror bind exhaustion 不能谎报 `STOPPED`；只有 authority 确认不可恢复且无活跃会话时，才允许对外表现为 `STOPPED`。

禁止回退：

- 不再使用旧的进程内静态 bridge 方案。
- 不使用 `CommonEvent`、自定义文件桥、RDB、`AppStorage` 作为 VPN 业务传输回退。API 26 起的 loopback TCP 是明确选择的内部 RPC 传输。
- production docs 不暴露签名材料、test URL、握手材料、proof 原文或运行态内部值。

验证命令：

```sh
node --test harmony/tests/structure/vpn-local-socket-rpc-contract.test.mjs
node --test harmony/tests/structure/phase4-vpn-contract.test.mjs harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs
node --check harmony/tests/bin/run-phase4-device-proof.mjs
node --check harmony/tests/bin/run-proxy-one-click-vpn-device-proof.mjs
node --check harmony/tests/bin/run-proxy-delay-device-proof.mjs
```
