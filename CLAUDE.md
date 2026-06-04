# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

ClashPow 是 macOS 14+ (Apple Silicon) 原生 SwiftUI 代理客户端,直接编排官方 `mihomo` (Clash.Meta) 内核:GUI 通过 REST + WebSocket 与内核通信,特权操作交给独立签名的 Helper。纯 Swift,无自研引擎。

## 构建与运行

```bash
# 完整打包：编译 Helper → xcodebuild GUI(Release) → 捆绑 Helper/geodata → ad-hoc 签名 → 生成 DMG
bash make.sh

# 仅构建 GUI（开发迭代）
xcodebuild -project ClashPow.xcodeproj -scheme ClashPow -configuration Debug build

# 启用 secret 扫描 pre-commit 钩子（仓库自带，非默认路径）
git config core.hooksPath .githooks
```

- 部署目标 macOS 14.0，仅 `arm64`，Swift 5，Bundle ID `com.clashpow.app`。
- 运行前需将官方 `mihomo` (darwin-arm64) 二进制放入 `<App>/Contents/MacOS/mihomo`；首次启动会被复制到 `~/Library/Application Support/ClashPow/bin/mihomo`。也可在应用内「内核管理」从 GitHub 下载（见 `KernelManager`）。
- 没有测试套件；`Scripts/`（build/install/notarize/package/verify_helper）是分发脚本。

## 架构（big picture）

三层，理解任意一层都需跨多个文件：

**1. GUI 层（`Sources/`，全部 `@MainActor`）**
- `AppModel`（`Model/AppModel.swift`）—— 单一真相源 + 编排中枢，`AppModel.shared`。持有 `api`/`engine`/`store`/`history`，驱动所有 UI。
- `MihomoClient`（`XPC/MihomoClient.swift`）—— 纯 Swift REST/WS 客户端。`probe()` 探活，`stream()` 订阅 `/traffic`、`/connections`、`/logs`（断线自动重连），其余方法封装 mihomo REST API。
- `EngineControl`（`XPC/EngineControl.swift`）—— 内核生命周期：`ensureInstalled`/`ensureRunning`/`restart`，以及「用户态 ↔ Root 态」切换。`runningAsRoot` 标志当前内核是否经 Helper 以 root 启动。
- `ConfigStore`（`Model/ConfigStore.swift`）—— 多套 YAML profile 管理；远程订阅 URL 存 Keychain，不落盘 manifest。
- UI 按功能分目录于 `Sources/UI/`，路由是 `AppModel.route` 字符串（见 `App/ContentView.swift` 侧栏 tab）。

**2. 特权 Helper 层（`Sources/Helper/main.swift` + `Sources/XPC/`）**
- 独立编译的 LaunchDaemon，Mach service `com.clashpow.helper`，通过 `HelperProtocol`（`XPC/HelperProtocol.swift`）做 XPC。
- 仅 4 个能力：`getVersion` / `setSystemProxy` / `startMihomo` / `stopMihomo`。
- `XPCManager`（`XPC/XPCManager.swift`）—— GUI 侧连接管理 + `installDaemon()`/`uninstallDaemon()`，安装走 `osascript do shell script ... with administrator privileges`（`EngineControl.runAdmin`）。
- `ProxyManager`（`XPC/ProxyManager.swift`）—— Helper 内用 `SystemConfiguration` 改系统代理。

**3. 内核层** —— 官方 `mihomo`。GUI 仅展示与控制，不碰网络报文。

### 关键工作流
- **启动**：`AppModel.start()` → `engine.ensureInstalled()`+`ensureRunning()` → `reconnect()` 轮询 `/version` 握手 → 建 WS 长连 + 3s 轮询 `refreshProxies`/`refreshConfigs`。不可达时每 3s 静默重试。
- **TUN 开启**（`AppModel.toggleTUN`）：TUN 需 root → 若 Helper 未装先 `installPrivileged()` 弹授权 → `engine.restart()` 以 root 重启内核 → 重连 → PATCH `tun.enable=true`。
- **系统代理**（`toggleSystemProxy`）：优先走 Helper，否则 `setSystemProxyFallback` 用 `networksetup` osascript 兜底。
- **配置变更**：统一经 `AppModel.patch()` → mihomo `/configs` PATCH（内核侧校验+回滚）；切换 profile 用 `setConfig` 写文件 + `/configs?force=true` PUT 热重载。

### 默认连接参数
内核 external-controller 默认 `127.0.0.1:9092`，secret `clashpow`（见 `EngineControl.ensureInstalled` 写出的初始 config.yaml 与 `MihomoClient` 的 `@AppStorage` 默认值）。数据目录 `~/Library/Application Support/ClashPow`。

## 性能约定（改 UI/数据流时务必遵守）

- **连接快照单遍聚合**：`AppModel.computeDash` 每个 `/connections` 快照只算一次，结果存 `dash`，UI 直接读——不要在 SwiftUI render 里重新遍历 `conns`。
- **日志批量刷新**：日志先进 `logBuffer`，0.5s 定时器一次性 flush 到 `@Published logs`，避免每行重渲染。
- **traffic 仅在取整速率变化时发布**，减少 view tree 抖动。
- **流量图**：仪表盘 `TrafficSparkline`（`DashboardView.swift`）读 `AppModel.downSeries`/`upSeries`——由 `onTraffic` 维护的滚动窗口（来自 `/traffic` WS）。旧引擎遗留的 Metal/mmap 流量图已移除。

## 约束（叠加于全局 CLAUDE.md）

- 改动涉及 XPC 协议、Helper 安装脚本、entitlements（`ClashPow.entitlements`，已关沙盒）时属高风险，先输出 Impact Analysis。
- pre-commit 钩子会 BLOCK 硬编码 secret/token/UUID（疑似节点信息），并对订阅 URL、IP 地址 WARN。勿提交真实订阅/节点数据。
- 项目文件用 Xcode 工程（`ClashPow.xcodeproj`），新增 Swift 文件需加入对应 PBXGroup/Sources phase，否则不参与编译。
```
