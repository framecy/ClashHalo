# ClashHalo

> macOS 14+ 原生 SwiftUI 代理客户端，直接编排官方 `mihomo` (Clash.Meta) 内核。当前版本 **v0.5.4**。

ClashHalo 采用纯 Swift 的原生编排器架构：应用层负责界面与状态管理，独立签名的 Helper 处理特权操作，内核层直接驱动 `mihomo`。目标很明确，少一层中间件，少一层不稳定性。

## 你会用到什么

- **系统代理 / TUN**
  - 一键切换系统代理。
  - 通过独立 Helper 启用特权 TUN。
- **配置与订阅**
  - 本地 YAML 配置管理。
  - 远程订阅刷新与热重载。
- **局域网网关**
  - 将 Mac 变成局域网网关和 DNS 接管点。
  - 适合旁路由、家庭设备统一接管场景。
- **网络面板**
  - 内建 Zashboard 外部面板接入。
  - 支持内核面板与运行状态查看。
- **连接与日志**
  - 连接列表、规则、流量与日志统一查看。
  - 支持菜单栏快捷入口。

## 运行方式

### 安装

1. 从 [Releases](https://github.com/framecy/ClashHalo/releases) 下载最新 DMG。
2. 拖入 `Applications` 后首次打开。
3. 如果系统拦截，右键应用选择「打开」，或执行：

```bash
xattr -dr com.apple.quarantine /Applications/ClashHalo.app
```

### 构建

```bash
# 打包生成 DMG
bash make.sh

# 本地调试构建
xcodebuild -project ClashPow.xcodeproj -scheme ClashPow -configuration Debug build
```

## 目录说明

- `README.md`：项目入口与使用说明
- `CHANGELOG.md`：版本变更记录
- `Docs/GatewayGuide.md`：局域网网关配置指南
- `Scripts/`：打包与签名脚本

## 架构

应用分为三层：

1. GUI 层：SwiftUI 界面与状态驱动
2. Helper 层：特权网络操作与系统级清理
3. 内核层：`mihomo` 代理与网络转发

## 文档

- [局域网网关中枢配置指南](Docs/GatewayGuide.md)
- [更新记录](CHANGELOG.md)

## 免责声明

本项目仅用于网络技术学习与管理，不内置、不提供、不分发任何形式的代理节点服务。请遵守所在地法律法规。
