# ClashHalo

> macOS 14+ 原生 SwiftUI 代理客户端，直接编排官方 `mihomo` (Clash.Meta) 内核。当前版本 **v1.0.1**。

ClashHalo 采用纯 Swift 的原生编排器架构：应用层负责界面与状态管理，独立签名的 Helper 处理特权操作，内核层直接驱动 `mihomo`。目标很明确，少一层中间件，少一层不稳定性。

## 新特性 (v1.0.1)

- **网络与服务自适应激活**：一键开启系统代理或 TUN 模式时自动激活/启动内核；在所有代理服务均关闭时自动关停释放后台资源。
- **亮色/暗色自适应主题**：全面移除强制暗色机制，深度适配系统 Appearance 亮色与暗色模式，重绘高对比度卡片背景。
- **瞬时级响应时延**：使用增量微秒级探测轮询重构 `waitForKernelReady`，网关代理仅下发至活跃物理网卡，核心加载与代理启用时延缩减至 150ms 左右。
- **更新稳定性提升**：添加订阅链接 HTTP 200 与 YAML 结构防空校验，彻底解决订阅更新失败覆盖空白配置的问题。
- **策略组状态呈现**：代理页支持异常面板直观报错，并支持一键重试及自动保存远程订阅链接。

## 主要特性 (v1.1.x)

- **自动更新**: 支持通过 GitHub Releases 自动检查和下载更新
- **Helper 自动升级**: App 升级后自动检测并升级特权服务，无需手动操作
- **UI 优化**: 统一输入框样式，优化设计系统
- **SD-WAN 增强**: UTUN 接口彩色分类，拓扑图和路由表视觉一致性提升

## 你会用到什么

- **系统代理 / TUN**
  - 一键切换系统代理。
  - 通过独立 Helper 启用特权 TUN。
  - App 升级后自动更新 Helper 版本。
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
- **自动更新**
  - 定期检查 GitHub Releases 新版本。
  - 一键下载和安装更新包。

## 运行方式

### 安装

1. 从 [Releases](https://github.com/framecy/ClashHalo/releases) 下载最新 DMG。
2. 拖入 `Applications` 后首次打开。
3. 如果系统拦截，右键应用选择「打开」，或执行：

```bash
xattr -dr com.apple.quarantine /Applications/ClashHalo.app
```

### 自动更新

ClashHalo 支持自动更新检查：

1. 打开"设置 → 关于"
2. 点击"检查更新"查看是否有新版本
3. 如果有更新，点击"下载更新"
4. 下载完成后会自动打开 DMG 安装包

**注意**: 需要网络访问 GitHub API (api.github.com)

### 特权服务 (Helper)

ClashHalo 使用特权服务来管理系统代理和 TUN 模式：

- **自动升级**: App 升级后会自动检测并升级 Helper（启动后约 2 秒）
- **手动管理**: 在"设置 → 权限"可以手动安装/卸载/升级
- **版本检查**: 点击"检查"按钮验证连接状态和版本信息
- **故障恢复**: 如遇问题，可在"设置 → 权限"卸载后重新安装

### 构建

```bash
# 打包生成 DMG
bash make.sh

# 本地调试构建
xcodebuild -project ClashHalo.xcodeproj -scheme ClashHalo -configuration Debug build

# Release 构建
xcodebuild -scheme ClashHalo -configuration Release -derivedDataPath .build clean build
```

## 目录说明

- `README.md`：项目入口与使用说明
- `CHANGELOG.md`：版本变更记录
- `Docs/GatewayGuide.md`：局域网网关配置指南
- `Scripts/`：打包与签名脚本
- `Sources/`：应用源代码
  - `Model/`：数据模型和业务逻辑
  - `UI/`：SwiftUI 界面
  - `XPC/`：Helper 通信和特权操作
  - `Helper/`：特权服务代码

## 架构

应用分为三层：

1. **GUI 层**: SwiftUI 界面与状态驱动
   - AppModel: 应用状态管理
   - DesignTokens: 设计系统和样式
   - 各功能页面: Dashboard, Proxies, Rules, Settings 等

2. **Helper 层**: 特权网络操作与系统级清理
   - XPC 通信安全验证
   - 系统代理设置
   - TUN 模式和网关模式管理
   - 自动版本检测和升级

3. **内核层**: `mihomo` 代理与网络转发
   - 用户模式或 Root 模式运行
   - 配置热重载
   - REST API 交互

## 文档

- [局域网网关中枢配置指南](Docs/GatewayGuide.md)
- [更新记录](CHANGELOG.md)
- [开发总结 (v1.1.0)](../Desktop/ClashHalo_开发总结_2026-07-04.md)

## 技术栈

- **语言**: Swift 6.0+
- **框架**: SwiftUI, Combine, AppKit
- **系统要求**: macOS 14.0+
- **显示器**: 支持所有分辨率 (1080p, 1440p, 4K, 5K)
- **开发工具**: Xcode 16.0+
- **依赖**: 无第三方依赖

## 贡献

欢迎提交 Issue 和 Pull Request！

## 免责声明

本项目仅用于网络技术学习与管理，不内置、不提供、不分发任何形式的代理节点服务。请遵守所在地法律法规。

## 许可证

MIT License

---

**项目主页**: https://github.com/framecy/ClashHalo  
**问题反馈**: https://github.com/framecy/ClashHalo/issues
