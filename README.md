# ClashPow

> macOS 14+ (Apple Silicon) 原生 SwiftUI 代理客户端,直接编排官方 `mihomo` (Clash.Meta) 内核。

ClashPow 已彻底移除自研 Go 引擎,改为「原生编排器」架构:GUI 通过 REST + WebSocket 与官方内核通信,特权操作交给独立签名的 Helper。纯 Swift、零中间层、完全兼容官方内核特性。

## 功能

- **系统代理**:一键设置 / 清除 macOS 系统 HTTP/HTTPS/SOCKS 代理。
- **TUN 模式**:首次开启请求管理员授权安装特权 Helper,内核以 root 重启并接管全局流量(utun + auto-route)。
- **订阅与配置**:多套 YAML profile 管理,远程订阅(URL 存 Keychain),内核侧校验 + 热重载。
- **内核管理**:默认内置官方 mihomo,开箱即用;应用内可从 GitHub 下载/切换版本(stable / alpha),或一键切回内置内核。
- **实时监控**:流量图、连接监控、单遍聚合的仪表盘、分级实时日志(默认 WARN)。
- **安全**:控制面绑回环 + 强随机 secret;Helper XPC 客户端代码签名校验 + 内核路径白名单。

## 架构

三层,详见 [`ARCHITECTURE.md`](ARCHITECTURE.md):

1. **GUI 层**(`Sources/`,全 `@MainActor`):`AppModel` 编排中枢 + `MihomoClient`(REST/WS) + `EngineControl`(内核生命周期) + `ConfigStore`。
2. **特权 Helper 层**(`Sources/Helper/`):独立签名的 LaunchDaemon,经 XPC 提供 `setSystemProxy` / `startMihomo` / `stopMihomo` / `getVersion`。
3. **内核层**:官方 `mihomo`,直接处理网络报文,GUI 仅展示与控制。

## 系统要求

- macOS 14.0+,Apple Silicon (arm64)

## 安装(发布版 DMG)

1. 从 [Releases](https://github.com/framecy/ClashPow/releases) 下载 `ClashPow.dmg`。
2. 打开 DMG,将 `ClashPow` 拖入 `Applications`。
3. **首次打开**(应用为 ad-hoc 签名,无开发者证书):右键点击 ClashPow → 「打开」→ 再次「打开」;或 `xattr -dr com.apple.quarantine /Applications/ClashPow.app`。
4. 内核:**已默认内置官方 mihomo,开箱即用**;如需更新/切换版本,在「设置 → 高级设置 → 内核管理」操作,亦可随时切回内置内核。

DMG 内附 `使用说明.txt` 含完整本地使用与卸载指引。

## 从源码构建

```bash
# 完整打包:编译 Helper → xcodebuild GUI(Release) → 捆绑签名 → 生成 DMG(含 /Applications 软链 + 使用说明)
bash make.sh

# 仅构建 GUI(开发迭代)
xcodebuild -project ClashPow.xcodeproj -scheme ClashPow -configuration Debug build

# 启用 secret 扫描 pre-commit 钩子
git config core.hooksPath .githooks
```

- 部署目标 macOS 14.0,仅 `arm64`,Swift 5,Bundle ID `com.clashpow.app`。
- 内核 external-controller 默认绑 `127.0.0.1`,secret 启动时自动规范化为强随机值。

## 许可 / 免责

仅供学习与个人合法用途。代理 / 节点配置由用户自行提供,本仓库不含任何订阅或节点数据。
