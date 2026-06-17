# ClashHalo

> macOS 14+ (Apple Silicon) 原生 SwiftUI 代理客户端，直接编排官方 `mihomo` (Clash.Meta) 内核。当前版本 **v0.4.9**。

ClashHalo 是「原生编排器」架构：GUI 通过 REST + WebSocket 与官方内核通信，特权操作交给独立签名的 Helper。纯 Swift、零中间层、完全兼容官方内核特性。

## 功能

- **系统代理**：一键设置 / 清除 macOS 系统 HTTP/HTTPS/SOCKS 代理；网络离线时自动清除，防止流量阻断。
- **TUN 模式**：首次开启请求管理员授权安装特权 Helper，内核以 root 重启并接管全局流量（utun + auto-route）。
- **订阅与配置**：多套 YAML profile 管理，远程订阅（URL 存 Keychain），内核侧校验 + 热重载。订阅页支持 proxy-provider 增删改（写入配置 + 自动 `use:` 引用，备份/校验/失败回滚）。
- **网络聚合页**：入站 / TUN / DNS / 嗅探 / 内核管理 合并为一个带 tab 的「网络」页；侧栏精简为 监控 / 代理 / 配置 三组。
- **内核管理**：默认内置官方 mihomo，开箱即用；应用内可从 GitHub 下载/切换版本（stable / alpha），或一键切回内置内核。
- **网关中枢 (旁路由)**：一键开启局域网底层 IP 转发并接管 53 端口 DNS。自动识别并展示局域网内所有接入设备的 IP、连接数及实时流量趋势。详情请参阅 [`Docs/GatewayGuide.md`](Docs/GatewayGuide.md)。
- **外部面板集成 (Zashboard)**：深度内嵌开箱即用的 Zashboard 外部面板，通过自动注入哈希参数实现与内核免密无缝认证，支持跟随系统的主题自动切换。
- **实时监控**：流量图、连接监控、单遍聚合的仪表盘、分级实时日志（默认 WARN）。
- **菜单栏快捷面板**：开关（系统代理/TUN/网关中枢/核心）、模式、逐策略组节点选择（带延迟）、配置切换与更新订阅、复制终端代理命令、重载/清 DNS、页面导航；开机自启动与显示/隐藏 Dock 图标。
- **安全**：控制面绑回环 + 强随机 secret；Helper XPC 三层客户端鉴权（SecurityFramework / bundle 路径 / proc_pidpath）+ 内核路径白名单。
- **Helper 自动升级**：App 启动后自动检测版本，旧版 Helper 静默完成 uninstall → install 完整升级流；UI 版本过旧时显示橙色「更新」按钮。
- **退出清理**：App 正常退出（`applicationWillTerminate`）或收到 SIGTERM/SIGINT 时，自动 `kill -9 mihomo` 并清除系统代理，避免代理残留。

## 架构

三层，详见 [`ARCHITECTURE.md`](ARCHITECTURE.md)：

1. **GUI 层**（`Sources/`，全 `@MainActor`）：`AppModel` 编排中枢 + `MihomoClient`（REST/WS）+ `EngineControl`（内核生命周期）+ `ConfigStore`。
2. **特权 Helper 层**（`Sources/Helper/`）：独立签名的 LaunchDaemon（v1.0.6），经 XPC 提供 `setSystemProxy` / `startMihomo` / `stopMihomo` / `getVersion`（系统代理用 `networksetup` 落地）。
3. **内核层**：官方 `mihomo`，直接处理网络报文，GUI 仅展示与控制。

## 系统要求

- macOS 14.0+，Apple Silicon (arm64)

## 安装（发布版 DMG）

1. 从 [Releases](https://github.com/framecy/ClashHalo/releases) 下载最新 `ClashHalo_vX.Y.Z_mac_arm.dmg`。
2. 打开 DMG，将 `ClashHalo` 拖入 `Applications`。
3. **首次打开**（应用为 ad-hoc 签名，无开发者证书）：右键点击 ClashHalo → 「打开」→ 再次「打开」；或执行：
   ```bash
   xattr -dr com.apple.quarantine /Applications/ClashHalo.app
   ```
4. 内核：**已默认内置官方 mihomo，开箱即用**；如需更新/切换版本，在「网络 → 内核」操作。
5. **首次开启 TUN**：弹出管理员授权窗口，同意后自动安装 Helper 并重启内核；后续版本升级由 App 静默自动完成。

DMG 内附 `使用说明.txt` 含完整本地使用与卸载指引。

## 从源码构建

```bash
# 完整打包：编译 Helper → xcodebuild GUI(Release) → 捆绑签名 → 生成 DMG
bash make.sh
# 输出：build/ClashHalo_vX.Y.Z_mac_arm.dmg + Desktop 副本

# 仅构建 GUI（开发迭代）
xcodebuild -project ClashHalo.xcodeproj -scheme ClashHalo -configuration Debug build

# 启用 secret 扫描 pre-commit 钩子
git config core.hooksPath .githooks
```

- 部署目标 macOS 14.0，仅 `arm64`，Swift 6，Bundle ID `com.clashhalo.app`。
- 内核 external-controller 默认绑 `127.0.0.1`，secret 启动时自动规范化为强随机值。
- `make.sh` 对各二进制分别签名：`mihomo` 不加 `--options runtime`（hardened runtime 会阻断 TUN 设备创建）。

## 声明 / 免责 (Disclaimer)

本项目（ClashHalo）是一个供学习和交流网络技术的图形化管理工具。项目本身**不内置、不提供、不分发**任何形式的代理服务、节点订阅或 VPN 服务。

- **遵守法规**：用户在使用本项目时，必须严格遵守所在国家或地区的法律法规。严禁将本软件用于任何非法或危害国家安全的行为。
- **免责条款**：因用户个人滥用本软件或提供非法代理服务而引发的一切直接或间接的法律纠纷或后果，由使用者自行承担，开发者不承担任何责任。
- **第三方组件**：本软件的流量处理依赖于开源网络内核（如 `mihomo`）。该内核的知识产权及执行逻辑归属于其原开发者，本应用仅提供界面编排与系统级网络配置调用。
- **隐私保证**：本应用纯本地运行，不包含任何遥测、云端收集或隐蔽分析代码。所有订阅配置、流量日志和代理凭证均仅存放在用户本地设备中。

**当您下载、构建或使用本项目时，即代表您已仔细阅读并完全同意上述免责声明。**
