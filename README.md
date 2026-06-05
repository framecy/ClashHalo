# ClashPow

> macOS 14+ (Apple Silicon) 原生 SwiftUI 代理客户端，直接编排官方 `mihomo` (Clash.Meta) 内核。当前版本 **v0.4.5**。

ClashPow 是「原生编排器」架构：GUI 通过 REST + WebSocket 与官方内核通信，特权操作交给独立签名的 Helper。纯 Swift、零中间层、完全兼容官方内核特性。

## 功能

- **系统代理**：一键设置 / 清除 macOS 系统 HTTP/HTTPS/SOCKS 代理；网络离线时自动清除，防止流量阻断。
- **TUN 模式**：首次开启请求管理员授权安装特权 Helper，内核以 root 重启并接管全局流量（utun + auto-route）。
- **订阅与配置**：多套 YAML profile 管理，远程订阅（URL 存 Keychain），内核侧校验 + 热重载。
- **内核管理**：默认内置官方 mihomo，开箱即用；应用内可从 GitHub 下载/切换版本（stable / alpha），或一键切回内置内核。
- **实时监控**：流量图、连接监控、单遍聚合的仪表盘、分级实时日志（默认 WARN）。
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

1. 从 [Releases](https://github.com/framecy/ClashPow/releases) 下载最新 `ClashPow_vX.Y.Z_mac_arm.dmg`。
2. 打开 DMG，将 `ClashPow` 拖入 `Applications`。
3. **首次打开**（应用为 ad-hoc 签名，无开发者证书）：右键点击 ClashPow → 「打开」→ 再次「打开」；或执行：
   ```bash
   xattr -dr com.apple.quarantine /Applications/ClashPow.app
   ```
4. 内核：**已默认内置官方 mihomo，开箱即用**；如需更新/切换版本，在「设置 → 高级设置 → 内核管理」操作。
5. **首次开启 TUN**：弹出管理员授权窗口，同意后自动安装 Helper 并重启内核；后续版本升级由 App 静默自动完成。

DMG 内附 `使用说明.txt` 含完整本地使用与卸载指引。

## 从源码构建

```bash
# 完整打包：编译 Helper → xcodebuild GUI(Release) → 捆绑签名 → 生成 DMG
bash make.sh
# 输出：build/ClashPow_vX.Y.Z_mac_arm.dmg + Desktop 副本

# 仅构建 GUI（开发迭代）
xcodebuild -project ClashPow.xcodeproj -scheme ClashPow -configuration Debug build

# 启用 secret 扫描 pre-commit 钩子
git config core.hooksPath .githooks
```

- 部署目标 macOS 14.0，仅 `arm64`，Swift 6，Bundle ID `com.clashpow.app`。
- 内核 external-controller 默认绑 `127.0.0.1`，secret 启动时自动规范化为强随机值。
- `make.sh` 对各二进制分别签名：`mihomo` 不加 `--options runtime`（hardened runtime 会阻断 TUN 设备创建）。

## 许可 / 免责

仅供学习与个人合法用途。代理 / 节点配置由用户自行提供，本仓库不含任何订阅或节点数据。
