# ClashHalo

> macOS 14+ 原生 SwiftUI 代理客户端，直接编排官方 `mihomo` (Clash.Meta) 内核。当前版本 **v1.1.9**。

ClashHalo 采用纯 Swift 的原生编排器架构：应用层负责界面与状态管理，独立签名的 Helper 处理特权操作，内核层直接驱动 `mihomo`。目标很明确，少一层中间件，少一层不稳定性。

## 新特性 (v1.1.9)

- **修复排除路由会摧毁对端隧道的路由**：拆除时会把从路由表收割来的对端前缀一并删掉（Tailscale 广播的子网因此永久消失且无法自愈）。现在只删除自己真正创建的路由，且删除前重新核验归属。**Helper 1.0.22 → 1.0.23，需一次管理员授权。**
- **修复「一键修复」关闭 `auto-route` 导致 TUN 无网络**：NetworkExtension 形态 VPN 的作用域限定 default、以及 mihomo 自己的 default，此前都会被误判为「劫持全局默认路由」，于是开了 TUN 必然自我误报，点修复就自断路由。
- **对端网段不可达检测**：对端广播了但本机没有对应路由时单列告警——这类故障对路由表扫描天生不可见。
- **固定 TUN 设备名 `utun100`**：不再接受内核分配的「下一个空闲编号」。fake-ip 段 `198.18/15` 是约定而非分配，同类应用的 TUN 也落在这个段里，仅凭地址分不清谁是谁；而 BSD 按创建顺序编号，周围隧道一抖动就改名——这正是手写 `#utunN` 绑定隔夜失效的根因。内核若不认这个字段会自动降级为旧行为，TUN 照常可用。
- **修正路由掩码解析**：`netstat` 的缩写目的地（`192.168.3` = `/24`、`126` = `/8`）此前一律被当成 `/32`，导致对端子网只排除了一个主机地址，且 mihomo 的 `/8` 级聚合被算窄，遮蔽冲突检测近乎失效。
- **系统隧道不再计入共存 peer**：iCloud 私密代理、Wi-Fi 通话等无 IPv4 的系统 utun 不再刷屏（实测 peer 数 9 → 1）。
- **DNS 出口绑定漂移检测**：`nameserver-policy` 里 `#utunN` 与对端实际接口不符时，SD-WAN 页给出显式「修复出口绑定」（改文件 + 重载，先校验后回滚）。
- **清空全部配置**：一键删除全部配置、订阅与派生缓存，并自动关闭系统代理 / TUN、停止内核；重新导入后手动开启即可。

## 新特性 (v1.1.8)

- **控制面密钥不再被自动替换**：此前弱密钥判定按长度/字符类别整形，每次启动都重写 `secret`，你在「API 控制」里设的密钥每次重启都失效，外部面板需反复登录。现在只有空值和出厂占位常量才自动替换。
- **修复局部 PATCH 关掉 TUN**：mihomo 的 `PATCH /configs` 对嵌套对象是整块替换而非深合并，只发 `tun` 的部分字段会让 `enable` 变回 false。共存同步、「一键修复」、TUN 回滚三条路径统一改为重述完整 `tun` 块。
- **utun 共存重构**：VPN 在 TUN 之后连接、对端新增子网或断开，排除路由都会跟随更新；自动注入的条目带归属标记、断开即撤回，用户手写条目全程不动。未知 VPN 退化为通用 peer，同样能拿到完整路由排除。

## 新特性 (v1.1.7)

- **单一身份内核**：Helper 可用时内核一律以 root 运行。此前 root(TUN)/用户态混跑会把数据目录属主撕裂，导致**订阅节点消失、节点选择不保存、geo 数据停更**——且全是静默失效。
- **附带**：内核本就是 root 时，开启 TUN 不再重启内核，退化为一次配置变更。
- **控制面密钥加固**：弱密钥判定由固定黑名单改为形态启发式（长度/字符类别/键盘走位），自动替换为随机密钥。

## 新特性 (v1.1.6)

- **冷启动提速约 10 倍**：内核不再排队等待特权/网络杂务，Helper 检查与残留清理并行。实测内核就绪 **0.31s**、冷启动完成 **1.32s**、热启动 **0.17s**。
- **修复首次开启 TUN 必失败**：根因是 mihomo 对 `PATCH /configs` 先回 200 再决定能否应用，落在刚重启的内核上会被静默丢弃。改为重启前落盘 `tun.enable`，并读回核对而非采信 200。
- **全关时断开既有连接**：TUN 与系统代理都关闭后主动断开残留连接，立即恢复直连（网关中枢开启时不触发）。
- **内核自动托管**：移除内核启停开关，启动即自动拉起，开代理/TUN 按需处理。
- **特权授权弹窗重做**：原生 SwiftUI 设计，含版本迁移与要点说明，替换系统 AppleScript 弹窗。
- **新增 GUI 日志** `~/Library/Logs/ClashHalo/app.log`，与 Helper 日志按时钟对齐，便于排查。

## 新特性 (v1.1.5)

- **内核启停提速**：停核/重启/内核切换走 `pgrep` 确认快路径，跳过多余的 Helper XPC 与 `killall` 兜底。
- **Root 启动去固定等待**：Helper `startMihomo` 由固定 0.8s sleep 改为条件化轮询，TUN / 网关 root 重启显著加快。
- **特权握手缓存**：`verifyConnectivity` 成功结果缓存 2s，一次 TUN 开启少打 1–2 次 XPC 握手。
- **开关反馈更快更明确**：系统代理先设置先反馈，`allow-lan` 后置；失败且内核未运行时不再静默。
- **修复 TUN 开关闪跳**：TUN 拉起瞬间的路径风暴不再误翻开关（开启稳定期 + refreshConfigs 并发合并 + DNS 状态机原子化）。
- **修复强退断网**：Helper 1.0.20 引入客户端死亡 kqueue 监视与僵尸 utun 物理清理，强退 App 后代理/DNS/root 内核可靠回收。

## 新特性 (v1.1.4)

- **系统代理更稳更快**：XPC 超时与 `networksetup` 路径收敛；开 Proxy 不再误强制 root 重启。
- **内核更新不断网**：先下载解压再停核；切换前临时关系统代理，失败不恢复假代理；`stopMihomo` 硬超时。
- **开 Proxy 仍可更新内核**：检查/下载直连 GitHub，不经本机 mixed-port。
- **侧栏精简**：Proxy / TUN / 内核版本（红绿点）。
- **局域网 HTTP 共享**：开系统代理时自动 `allow-lan`，其它设备可指 mixed-port。

## 稳定性 (v1.1.3)

- **冷启动不再误开网关**：网关开关只认用户意图；残留 `dns.listen: 0.0.0.0:53` 自动清理。
- **网关已接入设备列表**：从 `/connections` 的 `sourceIP` 聚合 LAN 客户端。
- **Helper 安装/升级体验**：启动优先检查；密码前中文说明；单次授权原地替换。

## 设计系统 (v1.1.1 / v1.1.0)

- **品牌主题色 Medium Purple U**：`#65428A` 统一 `DS.Palette.accent` 与系统 `AccentColor`。
- **侧栏自绘导航对齐**：导航与 footer 共用 inset / 图标槽；图标 outline + monochrome。
- **统一设计系统**：全页面 32pt 控件、跨栏 chrome 56pt、空状态居中、关于页工具型 Card。
- **Shell 跨栏对齐**：侧栏顶栏与内容区工具栏同高（56pt），分割线通栏对齐；侧栏「监控 / 代理 / 配置」分组。
- **配置卡片统一尺寸**：顶距离开工具栏，有/无 CTA 等高。

## 稳定性 (v1.0.15)

- **TUN 自愈链路加固**：zombie 识别（路由表仲裁 + 单候选保守双判据）→ 逻辑关闭 → 物理清理兜底。
- **bypass 探测稳健化**：动态枚举网络服务、required 引用单一源、探测离主线程。
- **并发守卫防泄漏**：`isBusy` 一律 `defer` 复位，避免 cancel 永久卡死开关。

## 主要特性

- **系统代理 / TUN**
  - 一键切换系统代理。
  - 通过独立 Helper 启用特权 TUN。
  - App 升级后自动更新 Helper 版本。
- **配置与订阅**
  - 本地 YAML 配置管理。
  - 远程订阅刷新与热重载。
  - 一键清空全部配置（同时关闭系统代理 / TUN、停止内核）。
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

1. 打开「设置 → 关于」
2. 点击「检查更新」查看是否有新版本
3. 如果有更新，点击「下载更新」
4. 下载完成后会自动打开 DMG 安装包

**注意**: 需要网络访问 GitHub API (api.github.com)

### 特权服务 (Helper)

ClashHalo 使用特权服务来管理系统代理和 TUN 模式：

- **自动升级**: App 升级后会自动检测并升级 Helper（启动后约 2 秒）
- **手动管理**: 在「设置 → 权限」可以手动安装/卸载/升级
- **版本检查**: 点击「检查」按钮验证连接状态和版本信息
- **故障恢复**: 如遇问题，可在「设置 → 权限」卸载后重新安装

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

- [设计系统](Docs/design.md)
- [局域网网关中枢配置指南](Docs/GatewayGuide.md)
- [更新记录](CHANGELOG.md)

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
