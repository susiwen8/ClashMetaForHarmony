# Clash Meta for HarmonyOS

面向 HarmonyOS 6.x / 7.x 的原生 VPN 客户端，使用 ArkTS / ArkUI、VPN Extension、C++ N-API 和 mihomo Go 核心。

本分支仅保留鸿蒙实现。项目源自 [ClashMetaForAndroid](https://github.com/MetaCubeX/ClashMetaForAndroid)，Android 源码和构建流程仍可在上游及 Git 历史中查阅。

## 鸿蒙 7 新增支持

- **调试签名安装兼容**：适配鸿蒙 7 对 VPN 扩展进程的隔离限制，解决调试数据目录中的 Unix socket 权限问题导致的 VPN 启动失败，继续支持本地调试签名安装。
- **新的进程间通信通道**：应用界面与 VPN 扩展使用仅绑定 `127.0.0.1` 的 TCP 通道传递内部 RPC。这个通道用于应用内部控制，不是供其他应用使用的 HTTP / SOCKS 代理。
- **保留鉴权与会话保护**：继续使用 HUKS 双向鉴权、逐帧 MAC 和防重放校验；未鉴权连接不能替换当前已鉴权会话，待鉴权连接也有超时和数量限制。

## 鸿蒙 6 与鸿蒙 7 的区别

| 项目 | 鸿蒙 6 | 鸿蒙 7 及后续 API 版本 |
| --- | --- | --- |
| 自动选择条件 | 设备 API 20–25 | 设备 API 26 及以上 |
| 界面与 VPN 扩展通信 | 原有应用私有 LocalSocket | 本机回环 TCP（`127.0.0.1`） |
| 通信鉴权 | HUKS 双向鉴权、消息 MAC、防重放 | 保留同一套协议与校验 |
| 配置与日常操作 | 配置导入、节点测速与切换、VPN 启停 | 操作方式相同，无需手动切换通信方式 |
| 本次验证范围 | 版本分流回归测试通过，尚未实机复测 | Mate 70、HarmonyOS 7.0.0.109（API 26）实机通过 |

应用读取设备实际 API 版本选择通信方式，不依赖系统版本名称；连接失败时不会自动改用另一种传输。构建工程仍保持 target API 24、compatible API 20，不需要为鸿蒙 6、7 分别安装不同的 HAP。

2026-10-18 的鸿蒙 7 实机验证包括：VPN 启动、正常断开后重连、应用前后台切换，以及浏览器加载 Google 首页、Facebook 登录页和 Twitter / X 页面，访问期间 VPN 收发计数增长。该结果验证了本次设备与配置下的网络访问，不代表所有设备、节点或网站登录功能均已验证。实现细节见 [VPN 通信与恢复说明](docs/harmony/vpn-runtime-bridge.md)。

## 使用与开发

- [操作手册](docs/harmony/current-version-vpn-user-guide.md)：配置导入、节点选择、VPN 和诊断。
- [构建与验证](harmony/README.md)：工具链锁定、核心构建、测试和真机验证。
- [第三方声明](harmony/THIRD_PARTY_NOTICES.md)、[许可证](LICENSE) 和 [历史第三方声明](NOTICE)。

使用 DevEco Studio 打开 **`harmony/`**，不要将仓库根目录作为工程。当前锁定 DevEco Studio 6.1.1.300、SDK 6.1.1.125，target API 24、compatible API 20，目标架构 AArch64。以 `harmony/toolchain.lock.json` 为准。

## 目录

| 路径 | 用途 |
| --- | --- |
| `harmony/entry` | 主应用 UI、VPN Extension |
| `harmony/shared`、`harmony/platform` | 共享模型与鸿蒙平台能力 |
| `harmony/core` | N-API 桥接与独立 mihomo Go 模块 |
| `harmony/traffic-probe` | 独立流量验证应用 |
| `harmony/tests`、`harmony/tools` | 回归测试、构建与验证工具 |
| `docs/harmony`、`docs/superpowers` | 使用说明、设计与实施记录 |

## 本地检查

```bash
node --test harmony/tests/structure/*.test.mjs
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
```

首次构建及核心重建请按[完整说明](harmony/README.md)操作。默认输出 `harmony/entry/build/default/outputs/default/entry-default-unsigned.hap`；未签名 HAP 不能直接安装到真机。签名证书、设备注册信息和本地配置不得提交到 Git。

不再需要 Android SDK、Gradle 或 Android mihomo 子模块。鸿蒙核心依赖由 `harmony/core/go/go.mod`、`go.sum` 及上游锁文件管理。

当前仓库不提供公开分发资格保证；开发设备签名不等同于任意设备的正式分发签名。
