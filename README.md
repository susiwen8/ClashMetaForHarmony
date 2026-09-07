# Clash Meta for HarmonyOS

面向 HarmonyOS 6.x 的原生 VPN 客户端，使用 ArkTS / ArkUI、VPN Extension、C++ N-API 和 mihomo Go 核心。

本分支仅保留鸿蒙实现。项目源自 [ClashMetaForAndroid](https://github.com/MetaCubeX/ClashMetaForAndroid)，Android 源码和构建流程仍可在上游及 Git 历史中查阅。

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
