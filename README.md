# ClashHalo

> macOS 14+ 原生 SwiftUI 代理客户端，直接编排官方 `mihomo` (Clash.Meta) 内核。

ClashHalo 采用纯 Swift 的原生编排器架构：应用层负责界面与状态管理，独立签名的 Helper 处理特权操作，内核层直接驱动 `mihomo`。目标很明确，少一层中间件，少一层不稳定性。

## 主要特性

- **系统代理 / TUN**
  - 一键切换系统代理（HTTP/HTTPS/SOCKS）。
  - 通过独立 Helper 启用特权 TUN 虚拟网卡，全局透明代理。
  - 单一身份内核：Helper 可用时内核统一以 root 运行，避免用户态/root 混跑导致的数据目录权限撕裂。
  - TUN 数据面自愈：探测失效文件描述符与拓扑变化后的静默丢包，自动重建或回退直连。
- **局域网网关中枢**
  - 将 Mac 变成局域网网关和 DNS 接管点，适合旁路由、家庭设备统一接管场景。
  - 已接入设备面板，实时速率与流量统计。
- **Tailnet 节点**（「网络 → Tailnet」）
  - 基于 mihomo 内置 `type: tailscale` 出站（tsnet 用户态 + gVisor），无需安装 Tailscale 客户端、不占系统 VPN 插槽。
  - 交互式登录、出口节点点选、设备面板、Headscale 支持。
- **网络拓扑与对端隧道共存**
  - 自动识别 Tailscale、SD-WAN 等对端隧道，注入路由排除，避免相互抢占网段。
  - 定时路由巡检与冲突自动修复，共存冲突只报告不越权处理。
- **配置与订阅**
  - 本地 YAML 配置管理，远程订阅刷新与热重载。
  - 一键清空全部配置（同步关闭系统代理 / TUN、停止内核）。
- **连接、规则与日志**
  - 连接列表（含按域名聚合视图）、规则、流量历史与分级日志统一查看。
  - 内建 Zashboard 外部面板接入。
  - 菜单栏快捷入口：状态查看、开关切换、节点选择。
- **自动更新**
  - 定期检查 GitHub Releases 新版本，一键下载并安装更新包。
  - Helper 版本随 App 自动检测升级，无需手动干预。

## 运行方式

### 安装

1. 从 [Releases](https://github.com/framecy/ClashHalo/releases) 下载最新 DMG。
2. 打开 DMG 后，**先双击「0-重要！请先双击我.command」**一键解除隔离标记（本应用为 ad-hoc 签名，未做 Apple 官方认证，这一步是必须的第一步）。
3. 把 `ClashHalo.app` 拖入「应用程序」文件夹，再打开。
4. 如果没有执行第 2 步导致系统仍然拦截，右键应用选择「打开」→ 再次点「打开」；或执行：

```bash
xattr -dr com.apple.quarantine /Applications/ClashHalo.app
```

### 自动更新

ClashHalo 支持自动更新检查：

1. 打开「设置 → 关于」
2. 点击「检查更新」查看是否有新版本
3. 如果有更新，点击「下载更新」
4. 下载完成后会自动打开 DMG 安装包

**注意**：需要网络访问 GitHub API (api.github.com)

### 特权服务 (Helper)

ClashHalo 使用独立签名的特权服务来管理系统代理和 TUN 模式：

- **自动升级**：App 升级后会自动检测并升级 Helper（启动后约 2 秒）
- **手动管理**：在「设置 → 权限」可以手动安装/卸载/升级
- **版本检查**：点击「检查」按钮验证连接状态和版本信息
- **故障恢复**：如遇问题，可在「设置 → 权限」卸载后重新安装

### 构建

```bash
# 打包生成 DMG（会自增 build 号）
bash make.sh

# 本地调试构建（不 bump build）
bash Scripts/build-debug.sh

# 或直接 xcodebuild
xcodebuild -project ClashHalo.xcodeproj -scheme ClashHalo -configuration Debug build
```

## 目录说明

- `README.md`：项目入口与使用说明
- `CHANGELOG.md`：版本变更记录
- `Docs/design.md`：设计系统规范
- `Docs/GatewayGuide.md`：局域网网关配置指南
- `Agents.md`：给 AI 编码代理的工程约定
- `Scripts/`：打包与签名脚本
- `Sources/`：应用源代码
  - `Model/`：数据模型和业务逻辑
  - `UI/`：SwiftUI 界面
  - `XPC/`：Helper 通信和特权操作
  - `Helper/`：特权服务代码

## 架构

应用分为三层：

1. **GUI 层**：SwiftUI 界面与状态驱动
   - AppModel：应用状态管理
   - DesignTokens：设计系统和样式
   - 各功能页面：Dashboard、Proxies、Rules、Network、Settings 等

2. **Helper 层**：特权网络操作与系统级清理
   - XPC 通信安全验证
   - 系统代理设置
   - TUN 模式和网关模式管理
   - 自动版本检测和升级

3. **内核层**：`mihomo` 代理与网络转发
   - 单一身份运行（Helper 可用时统一为 root）
   - 配置热重载
   - REST API 交互

## 文档

- [设计系统](Docs/design.md)
- [局域网网关中枢配置指南](Docs/GatewayGuide.md)
- [完整版本变更记录](CHANGELOG.md)

## 技术栈

- **语言**：Swift 6.0+
- **框架**：SwiftUI, Combine, AppKit
- **系统要求**：macOS 14.0+
- **显示器**：支持所有分辨率 (1080p, 1440p, 4K, 5K)
- **开发工具**：Xcode 16.0+
- **依赖**：无第三方依赖

## 贡献

欢迎提交 Issue 和 Pull Request！

## 免责声明

本项目仅用于网络技术学习与管理，不内置、不提供、不分发任何形式的代理节点服务。请遵守所在地法律法规。

## 许可证

[GPL-3.0 License](LICENSE)

---

**项目主页**：https://github.com/framecy/ClashHalo
**问题反馈**：https://github.com/framecy/ClashHalo/issues
