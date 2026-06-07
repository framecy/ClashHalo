# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

ClashPow 是 macOS 14+ (Apple Silicon) 原生 SwiftUI 代理客户端，直接编排官方 `mihomo` (Clash.Meta) 内核：GUI 通过 REST + WebSocket 与内核通信，特权操作交给独立签名的 Helper。纯 Swift，无自研引擎。当前版本 v0.4.7。

## 构建与运行

```bash
# 完整打包：编译 Helper → xcodebuild GUI(Release) → 捆绑 Helper/geodata → ad-hoc 签名 → 生成 DMG
bash make.sh
# 输出：build/ClashPow_vX.Y.Z_mac_arm.dmg + Desktop 副本

# 仅构建 GUI（开发迭代）
xcodebuild -project ClashPow.xcodeproj -scheme ClashPow -configuration Debug build

# 启用 secret 扫描 pre-commit 钩子（仓库自带，非默认路径）
git config core.hooksPath .githooks
```

- 部署目标 macOS 14.0，仅 `arm64`，Swift 6，Bundle ID `com.clashpow.app`。
- `make.sh` 内置 mihomo 内核（从本地缓存或 GitHub 下载），开箱即用；首次启动后复制到 `~/Library/Application Support/ClashPow/bin/mihomo`。也可在「内核管理」手动切换版本。
- 没有测试套件；`make.sh` 是主打包脚本；`Scripts/` 是正式签名+公证脚手架（需 Apple 开发者证书）。

### 签名注意事项（重要）
`make.sh` **不使用 `--deep` 统一签名**，而是对各二进制分别处理：
- `com.clashpow.helper` — `codesign --sign -`（无 runtime）
- `mihomo` — `codesign --sign -`（**故意不加 `--options runtime`**）
  - 原因：hardened runtime 阻断 `AF_SYSTEM` socket 创建，mihomo 无法建立 utun TUN 设备
- `.app bundle` — `codesign --options runtime --sign -`（runtime + entitlements）

## 架构（big picture）

三层，理解任意一层都需跨多个文件：

**1. GUI 层（`Sources/`，全部 `@MainActor`）**
- `AppModel`（`Model/AppModel.swift`）—— 单一真相源 + 编排中枢，`AppModel.shared`。持有 `api`/`engine`/`store`/`history`，驱动所有 UI。
- `AppModel+Config.swift` —— 配置/开关域：`toggleTUN`/`toggleSystemProxy`/`patch`/`activateProfile`。
- `AppModel+Proxies.swift` —— 代理组/节点/延迟测速。
- `AppModel+Connections.swift` —— 连接快照/流量聚合/仪表盘。
- `MihomoClient`（`XPC/MihomoClient.swift`）—— 纯 Swift REST/WS 客户端。`probe()` 探活，`stream()` 订阅 `/traffic`、`/connections`、`/logs`（断线自动重连）。
- `EngineControl`（`XPC/EngineControl.swift`）—— 内核生命周期：`ensureInstalled`/`ensureRunning`/`restart`/`stopKernel`，以及「用户态 ↔ Root 态」切换。`runningAsRoot` 标志当前内核是否经 Helper 以 root 启动。
- `ConfigStore`（`Model/ConfigStore.swift`）—— 多套 YAML profile 管理；远程订阅 URL 存 Keychain，不落盘 manifest。
- UI 按功能分目录于 `Sources/UI/`，路由是 `AppModel.route` 字符串（见 `App/ContentView.swift` 侧栏 tab）。

**2. 特权 Helper 层（`Sources/Helper/main.swift` + `Sources/XPC/`）**
- 独立编译的 LaunchDaemon，Mach service `com.clashpow.helper`，通过 `HelperProtocol`（`XPC/HelperProtocol.swift`）做 XPC。当前版本 `kHelperVersion = "1.0.6"`。
- 4 个 XPC 能力：`getVersion` / `setSystemProxy` / `startMihomo` / `stopMihomo`。
- `XPCManager`（`XPC/XPCManager.swift`）—— GUI 侧连接管理 + `installDaemon()`/`uninstallDaemon()`/`upgradeDaemon()`（先卸载再安装的完整升级流）。
- `ProxyManager`（`XPC/ProxyManager.swift`）—— Helper 内用 `networksetup` 改系统代理（SCPreferences 在 root daemon 会话不生效，已弃用）；状态读取仍用只读 `SCDynamicStoreCopyProxies`。
- **版本管理**：`EngineControl.kExpectedHelperVersion = "1.0.6"`。`AppModel.start()` 启动 4s 后调用 `checkAndUpgradeHelperIfNeeded()`，版本低于预期时自动走 `upgradeDaemon()` 升级，无需用户手动操作。UI「设置→权限」tab 版本过旧时按钮显示「更新」（橙色）。
- **`isAuthorizedClient` 三层鉴权**（`Helper/main.swift`）：
  1. `SecCodeCheckValidity(kSecCSBasicValidateOnly)` —— 跳过可执行+资源校验，仅验 identifier，兼容 ad-hoc 签名
  2. `SecCodeCopyStaticCode` + `SecCodeCopyPath` —— bundle 根路径回退
  3. `proc_pidpath` —— 直接读取进程真实可执行路径，不依赖签名框架；ad-hoc 必然通过

**3. 内核层** —— 官方 `mihomo`。GUI 仅展示与控制，不碰网络报文。

### 关键工作流

**启动：**
`AppModel.start()` → `engine.ensureInstalled()` + `ensureRunning()` → `reconnect()` 轮询 `/version` 握手 → 建 WS 长连 + 3s 轮询 `refreshProxies`/`refreshConfigs`。不可达时每 3s 静默重试。启动 4s 后后台检查 helper 版本并自动升级。

**TUN 开启**（`AppModel.toggleTUN`）：
1. TUN 需 root → 检查 `engine.isRoot` 和 `engine.helperVersion`
2. 未安装 Helper → `installPrivileged()` 弹授权
3. Helper 版本过旧 → `upgradeDaemon()` 自动升级（无需用户手动）
4. 调用 `engine.restart()` 以 root 重启内核（`stopKernel` + `ensureRunning` via helper）
5. **轮询等待**（最多 10s）：`api.reachable && engine.runningAsRoot` 同时为 true
6. `reconnect()` 重建 WS 连接
7. PATCH `tun.enable=true` → `refreshConfigs()` 确认实际状态

**runningAsRoot 同步：**
- `ensureRunning()`：kernel 已在线时用 `pgrep -u root -x mihomo` 判断是否已是 root 进程，避免无谓重启
- `pollStatus()`（每 2s）：helper 活跃 + api 可达 + `runningAsRoot=false` 时同步
- 解决 app 重启后 TUN 开关显示 OFF 的问题

**系统代理**（`toggleSystemProxy`）：优先走 Helper XPC，否则 `setSystemProxyFallback` 用 `networksetup` osascript 兜底。

**配置变更**：统一经 `AppModel.patch()` → mihomo `/configs` PATCH（内核侧校验+回滚）；切换 profile 用 `setConfig` 写文件 + `/configs?force=true` PUT 热重载。

**退出清理**（`AppDelegate` + signal handlers）：
- `applicationWillTerminate` / SIGTERM / SIGINT：`killall -9 mihomo` + helper XPC `setSystemProxy(false)`
- 一次性锁（`DispatchSemaphore`）防 delegate 与 signal handler 竞争

**网络断开保护**（`NWPathMonitor`）：
- 离线时自动关闭系统代理，防止代理指向死内核导致断网

### 默认连接参数
内核 external-controller 默认 `127.0.0.1:9092`，secret `clashpow`（`hardenControllerConfig()` 首次运行时会替换为随机 secret）。数据目录 `~/Library/Application Support/ClashPow`。Helper 日志 `/Library/Logs/ClashPow/helper.log`；mihomo root 模式日志 `/Library/Logs/ClashPow/mihomo-root.log`。

## 性能约定（改 UI/数据流时务必遵守）

- **连接快照单遍聚合**：`AppModel.computeDash` 每个 `/connections` 快照只算一次，结果存 `dash`，UI 直接读——不要在 SwiftUI render 里重新遍历 `conns`。
- **日志批量刷新**：日志先进 `logBuffer`，0.5s 定时器一次性 flush 到 `@Published logs`，避免每行重渲染。
- **traffic 仅在取整速率变化时发布**，减少 view tree 抖动。
- **流量图**：仪表盘 `TrafficSparkline`（`DashboardView.swift`）读 `AppModel.downSeries`/`upSeries`——由 `onTraffic` 维护的滚动窗口（来自 `/traffic` WS）。

## 约束（叠加于全局 CLAUDE.md）

- 改动涉及 XPC 协议、Helper 安装脚本、entitlements（`ClashPow.entitlements`，已关沙盒）、`make.sh` 签名流程时属高风险，先输出 Impact Analysis。
- pre-commit 钩子会 BLOCK 硬编码 secret/token/UUID（疑似节点信息），并对订阅 URL、IP 地址 WARN。勿提交真实订阅/节点数据。
- 项目文件用 Xcode 工程（`ClashPow.xcodeproj`），新增 Swift 文件需加入对应 PBXGroup/Sources phase，否则不参与编译。
- **Helper 版本变更**后需同步更新 `Helper-Info.plist` 的 `CFBundleVersion` 与 `kHelperVersion` 常量，以及 `EngineControl.kExpectedHelperVersion`，三处必须一致。
- **`isAuthorizedClient` 修改**时须保留三层鉴权结构（SecurityFramework → SecCodeCopyPath → proc_pidpath），任何一层都可能是某签名类型的唯一通路。
- **`toggleHelper()` 成功判据**：以 `installPrivileged()` osascript 返回 0 为成功，不依赖 `verifyConnectivity()` 超时；连通状态由 `pollStatus()` 异步更新 `isRoot`。
