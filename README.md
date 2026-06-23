# ClashHalo

> macOS 14+ (Apple Silicon) 原生 SwiftUI 代理客户端，直接编排官方 `mihomo` (Clash.Meta) 内核。当前版本 **v0.5.2**。

ClashHalo 采用「原生编排器」架构，纯 Swift 编写、零中间层，特权操作交由独立签名的 Helper 处理，完全兼容官方内核特性。

## 核心功能

- **双模式接管**：支持一键配置系统代理，或通过独立安装的特权 Helper 开启全局 TUN 模式。
- **配置与订阅**：支持多 YAML 配置文件管理、远程订阅刷新、以及基于本地与远程校验的热重载。
- **网关中枢 (旁路由)**：一键开启底层 IP 转发与局域网 DNS 接管，支持局域网其他设备无缝接入。
- **内嵌控制面板**：深度集成现代化 Zashboard WebUI，支持动态免密认证与无缝切换。
- **原生内核驱动**：开箱内置 `mihomo`，支持一键在应用内下载、更新和切换内核分支。
- **轻量监控与快捷操作**：聚合网络控制台、实时流量与连接数监控，并提供高效率的系统菜单栏快捷面板。
- **纯净安全**：原生的 XPC 鉴权保护，零遥测，应用正常或异常退出时均会自动清理代理残留。

## 架构

本应用分为三层设计（详见 [`ARCHITECTURE.md`](ARCHITECTURE.md)）：
1. **GUI 层**：纯原生 SwiftUI 构建的交互界面。
2. **Helper 层**：独立签名的 LaunchDaemon，用于执行系统网络设定、进程管理等特权操作。
3. **内核层**：直接驱动原版 `mihomo` 处理网络底层报文。

## 系统要求

- macOS 14.0+，Apple Silicon (arm64)

## 安装指引

1. 从 [Releases](https://github.com/framecy/ClashHalo/releases) 下载最新的 DMG 安装包并拖入 `Applications`。
2. **首次打开**：若遇到安全拦截，请右键点击应用选择「打开」，或在终端执行解除隔离命令：
   ```bash
   xattr -dr com.apple.quarantine /Applications/ClashHalo.app
   ```
3. 内核默认已内置，开箱即用；首次开启 TUN 模式时需管理员授权安装 Helper 即可。

## 从源码构建

```bash
# 完整打包并生成 DMG
bash make.sh

# 开发迭代编译 GUI
xcodebuild -project ClashHalo.xcodeproj -scheme ClashHalo -configuration Debug build
```

## 免责声明

本项目仅为网络技术的图形化管理学习工具，**不内置、不提供、不分发**任何形式的代理节点服务。请严格遵守所在国家或地区的法律法规。由使用者滥用导致的任何法律后果开发者概不负责。

本项目 GUI 代码基于 **[GPL-3.0 License](https://opensource.org/licenses/GPL-3.0)** 开源。
