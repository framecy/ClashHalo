# Changelog

本项目所有重要变更记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/),版本遵循语义化版本。

## [0.5.1] - 2026-06-18

构建 0.5.1 内核生命周期与网络状态稳定性深度更新。全面修复由竞态条件、网络瞬断和系统睡眠唤醒导致的内核误杀及代理状态异常丢失问题。

### Added
- **自动化集成测试套件**：
  - 新增 `Scripts/integration_test.sh` 端到端 Bash 自动化集成测试脚本，覆盖特权守护进程 Dead Man's Switch (崩溃兜底清场机制)、网络瞬断自动容错、及内核崩溃防死锁恢复测试用例，为内核生命周期管理提供自动化质量保证。

### Fixed
- **启动防误杀与多环境触发重入漏洞**：
  - 修复了 SwiftUI 生命周期（`onAppear` 等）由于多窗口或从后台唤醒导致的多次重新初始化，进而反复触发 `AppModel.start()` 中意外全杀 (`killall -9`) 内核守护进程的漏洞。采用无损探活 (`api.probe()`) 与状态栅栏替换了原有的暴力重启逻辑。
- **配置切换的 TUN 静默丢失问题**：
  - 修复 `activateProfile` 重新应用底层配置时由于隐式调用 `forceTUNDisabled()` 造成 TUN 虚拟网卡丢失的问题，现在会在配置重载后自动保存并恢复先前的 TUN 开关状态。
- **崩溃兜底（Dead Man's Switch）竞态异常与断网死锁修复**：
  - 修复由于强杀客户端进程导致 XPC 连接断开时，底层 Helper 守护进程中的 `kill(clientPid, 0)` 因内核未及时完成孤儿进程回收而错误跳过紧急清场（关闭遗留内核、还原 DNS/代理）的严重问题。现已引入 0.5s 进程异步销毁确认延迟。
- **死循环式系统代理自关闭漏洞修复**：
  - 修复当用户主动关闭内核却单独保留“系统代理”开启时，后台 3 秒一次的探测任务会将“合法离线”误判为“内核崩溃断开”并强制关闭系统代理的智障反馈循环。

## [0.5.0] - 2026-06-17

### Added
- **全新视觉设计与重命名**：
  - 项目正式更名为 **ClashHalo**，以强调光环、轻盈的视觉与体验。
  - 全新设计极简渐变光环应用图标。
  - 内部动态加载系统 `NSApp.applicationIconImage` 并移除了硬编码的闪电图标，状态栏重构为动态小光环 (`circle.inset.filled`)。
- **网关中枢能力 (旁路由) 基础层**：
  - 核心引擎控制类 (`EngineControl`) 及 Helper 特权守护进程 (`XPCManager`) 新增开启系统 IP 转发（`sysctl net.inet.ip.forwarding`）的能力。
  - UI 「网络」面板新增「局域网网关 (旁路由)」卡片，实现了一键将 Mac 变身为同局域网内的设备网关的能力。

### Changed
- **全局文案替换**：
  - 所有的 `Info.plist`、UI 硬编码文案、构建脚本 (`make.sh`) 及日志文件名全面变更为 `ClashHalo`，以适配全新品牌。

### Fixed
- 修复因打包工具链及 App 重命名导致特权守护程序 (`com.clashpow.helper`) 的 `isAuthorizedClient` 路径鉴权失败、拒绝 XPC 握手的问题。通过重写底层路径验证逻辑及重新构建打包脚本予以解决。

## [0.4.9] - 2026-06-17

构建 0.4.9 核心稳定性更新发布。深度修复长效代理、状态死锁与 TUN 接口冲突问题。特权服务 (Helper) 升级至 v1.0.11。

### Fixed
- **启动生命周期与状态流失**：
  - 重构 `AppModel.start()` 启动流水线，全面引入 Swift 并发 (`Task`) 实现**严格串行化**（Strict Serialization）。
  - 彻底修复因 `ensureRunning`、`pollStatus` 与 XPC 通信并发执行而导致的竞态条件和“幽灵内核”（App 无限拉起新内核但代理端口指向旧内核）问题。
- **休眠/断网自愈机制**：
  - 完善 `NWPathMonitor` 断网保护逻辑，在休眠、Wi-Fi 切换等断网瞬间安全卸载系统代理。
  - 结合串行化的 `reconnect()` 流程平滑恢复系统代理与内核连接，修复长时间运行或休眠唤醒后无法代理的假死现象。
- **XPC 长连稳定性**：
  - 强化特权 Helper 与 GUI 之间的 `XPCManager` 连接自愈能力，在每次特权操作前通过 `verifyConnectivity()` 验证连接可用性，根除因内存回收导致的 XPC 连接静默断开问题。
- **TUN 接口冲突与误杀**：
  - 删除了强退时手动清理 `utun` 设备的激进代码。
  - 确认 `mihomo` 底层依赖 macOS `AF_SYSTEM` socket 建立 TUN，当内核异常退出时系统底层会自动回收 utun 并清空路由与 Supplemental DNS。
  - **关键修复**：此改动避免了手动执行 `ifconfig destroy` 对 198.18 频段进行“地毯式清理”从而误杀 Shadowrocket 等其他第三方代理软件的严重兼容性问题。

## [0.4.8] - 2026-06-11

构建 0.4.8 build 7 发布。深度优化图形渲染、增强 UI 交互一致性与网络配置容错率。

### Fixed
- **UI 交互与视图一致性**:
  - **网络与设置页统一**: 重构 `NetworkHubPage` 布局结构，使其与 `GeneralPage` 共享一致的“标题->标签->内容”层级；统一了标签栏的内边距、图标激活态与居中布局。
  - **图标渲染修复**: 修复部分系统图标（如 `network`, `scope`）因强制追加 `.fill` 导致点击选中时图标消失的渲染 Bug。
  - **配置开关防抖**: 为 `NToggle` (多级嵌套开关) 引入「乐观 UI」机制，在发起网络 PATCH 请求前立即更新内存状态，彻底修复“嗅探”等页面开关点击后因高频轮询而导致的自动回弹现象。
- **图形与渲染优化 (RSS 压制)**:
  - 仪表盘流量趋势图更新频率降至 2.0s（原 1.0s），显著降低 `owned unmapped (graphics)` 内存缓冲区的堆积。
  - 在 `refreshProxies` 和 `refreshConfigs` 引入深度内容校验，仅在数据真实变化时触发 `@Published` 更新，消除 90% 以上无效的全局视图 re-evaluation 及其产生的内存波动。
  - 为所有 REST API (Proxies/Configs/Rules) 的 JSON 解码过程强制包裹 `autoreleasepool`。
- **配置与后台逻辑**:
  - 增强 `proxy-provider` 移除逻辑：自动清理配置文件中所有策略组（`proxy-groups`）引用，避免内核级配置回滚。
  - 修复 `YamlRuleASTEngine` 无法正确剥离规则行内 `#` 注释导致匹配失效的 Bug。
  - **Aggressive Reclamation**: 后台静默时显式清空连接缓存字典并丢弃容量。

### Added
- **菜单栏仪表盘**: 在菜单栏下拉面板 (MenuBarPanel) 中新增实时的**“核心内存”与“应用内存”**指标双拼展示卡片。
- **代理规则管理**: 新增独立的代理规则页面 (`RulesPage`) 和规则编辑表单 (`RuleFormView`)，支持查看和编辑代理规则。

## [0.4.8] - 2026-06-12

构建 0.4.8 build 26 发布。引入完全开箱即用的 Zashboard 外部面板，并深度修复底层网络配置的持久化与生效逻辑。

### Added
- **Zashboard 原生集成 (开箱即用)**：
  - 在侧边栏新增「面板」分组，内置完整的 Zashboard 面板（通过 `WebView` 嵌入）。
  - **免密自动连接**：采用哈希路由传参技术 (`#/?hostname=...&secret=...`)，Zashboard 在启动时可瞬间抓取当前内核配置并完成免密鉴权，彻底消除 `e.protocol` 和未授权报错。
  - **全环境兼容**：在 App 内嵌页和「浏览器打开」动作中均统一指向官方稳定的 GitHub Pages 在线版本 (`https://board.zash.run.place/`)，解决跨域与安全策略拦截。
  - **自动更新**：支持 `AppStorage` 旧缓存自动迁移，确保旧版本用户更新后 URL 能正确指向新域名。
- **内核控制面升级**：
  - 「网络」->「内核」页新增 **API 控制 (外部面板)** 卡片。
  - 开放 `external-controller` (API 监听地址) 与 `secret` (API 密钥) 的可视化修改。
  - 更改 API 设置后，App 将自动触发硬重启并智能重连，防止 UI 断联。

### Fixed
- **网络配置无法生效的史诗级 Bug**：
  - 此前修改「入站端口」、「局域网共享」、「DNS」、「TUN」等底层网络栈配置时，App 仅调用了内核的运行时 `PATCH` 接口，而这些参数内核不支持热更新，导致修改在重启后丢失，表现为“点击无反应/无效”。
  - 修复方案：为 `EngineControl` 引入 `setNestedScalars` YAML 解析器。现在所有网络核心开关默认启用 `persistent: true`，修改后直接原子化写入 `config.yaml` 嵌套块并触发内核全量重载，彻底实现**永久生效**。
- **TUN 错误提示误导**：
  - 内核已运行在 Root 权限下却依然提示开启 TUN 失败时，修正了提示语：“可能无管理员权限或路由被其他 VPN 占用冲突”，正确指出 1.0.0.0/8 路由冲突的根本原因。
- **浏览器跳转失效**：
  - 修复 SwiftUI `Link` 组件在处理带 Hash 的链接时被 macOS 安全拦截的问题，改用底层的 `NSWorkspace.shared.open` 强制接管浏览器跳转。

## [0.4.7] - 2026-06-08

### Added
- 构建版本显示: 界面支持显示当前构建版本号。

### Fixed
- TUN 模式下内核重启保活机制。
- 修复切换节点时导致的断连问题。

## [0.4.6] - 2026-06-07

菜单栏快捷面板:不打开主界面即可完成节点切换、配置切换、模式与开关、维护与导航。

### Added
- **菜单栏 ⚡ 面板**(卡片式,全 DesignTokens):
  - 主开关:系统代理 / TUN / 核心运行。
  - 代理卡:全宽模式 tab(规则/全局/直连)+ **逐策略组节点选择**(显示当前节点 +
    延迟色点,点开切换)+ 实时流量 + 全部测速。
  - 配置卡:**行式 profile 列表**(点击切换、选中高亮、来源图标)+ 更新订阅。
  - 快捷动作:复制终端代理命令 / 重载配置 / 清 DNS。
  - 导航:仪表盘 / 连接 / 日志(打开主窗口并跳转)/ 配置目录(Finder)。
- **开机自启动**(`SMAppService`)与**显示/隐藏 Dock 图标**(activationPolicy)。
- 设置→通用新增「菜单栏」卡:可隐藏策略组选择以保持面板紧凑。

### Fixed
- **菜单栏导航唤起多个窗口**:主窗口由 `WindowGroup`(每次 `openWindow` 新建窗口)
  改为单实例 `Window` scene(已存在则前置、已关闭则重建)。
- 菜单栏 tile 由半透明 `fill` 改为与卡片同款实色 `cardBg + border`,消除叠加在
  菜单栏毛玻璃材质上时各块透色不一致的问题。
- 重载配置改为直接热重载内核运行的 `config.yaml`(`/configs?force=true`),
  无托管 profile 时也生效,并回显内核真实校验错误。

### Changed
- App 版本提升至 0.4.6。
- **侧栏精简**:5 组 → 3 组(监控 / 代理 / 配置)。
- **网络域聚合**:新增「网络」聚合页,顶部 tab 切换 **入站 / TUN / DNS / 嗅探 / 内核**;原 5 个独立侧栏项收为 1 个。`DnsPage`/`SnifferPage` 此前实现但不可达(孤儿),现已接回;内核管理去重(唯一入口移至「网络 → 内核」,从设置→高级移除)。
- **SD-WAN 共存** 保留独立侧栏层级。

### Fixed(续)
- **GEO/路由 开关点击无效**:`geodata-mode`/`geo-auto-update`/`unified-delay`/`disable-keep-alive`/`find-process-mode`/`keep-alive-*` 是 mihomo 加载期设置,运行时 `/configs` PATCH 被静默忽略。改为**写入 config.yaml + 热重载**(`patchPersistent`);reload 前回写当前 TUN 运行态以免误关 TUN。

### Added(续)
- **订阅页 proxy-provider 增删改**:新增订阅(名称 + URL)自动写入 `proxy-providers:` 并加入主策略组 `use:` 引用;支持编辑、删除、更新。写入采用**备份 → `mihomo -t` 校验 → 失败自动回滚**的安全流程,绝不破坏可用配置。

## [0.4.5] - 2026-06-05

系统代理彻底修复、TUN 不再自动拉起、启动竞态消除,以及日志展示与 Helper 自动升级时序修复。

### Fixed
- **打开内核后自动启动 TUN**:`config.yaml` 持久化的 `tun.enable: true` 会在每次 `ensureRunning`(通常用户态)启动时被读盘拉起 TUN,而用户态无权创建 utun → 流量黑洞、内核半死。新增 `EngineControl.forceTUNDisabled()`,在 `ensureInstalled()` 与 `setConfig()` 仅改写 `tun:` 块内 `enable:` 标量为 `false`(保留 stack/dns-hijack 等)。TUN 自此**只能经 `toggleTUN` 以 root 在运行时开启**。
- **系统代理设置无效**(三层根因):
  1. 经缓存 XPC 连接 `helper()` 的调用被静默丢弃(helper 收不到)→ 改用全新连接 + 守护 continuation 的 `XPCManager.callSystemProxy`(reply/error/超时只 resume 一次)。
  2. 调用到达 helper 后,**root LaunchDaemon 会话内 `SCPreferences` 不生效**(返回 false、`scutil` 仍 `HTTPEnable:0`)→ `ProxyManager` 改用 `networksetup`,枚举启用的网络服务逐个设/清 web/secure/socks 代理。
  3. Helper 自动升级因 **4s 检查早于首次 `pollStatus`(5s)**,`isRoot`/`helperVersion` 未就绪而被 guard 跳过 → 升级检查内主动 `verifyConnectivity()` + `fetchHelperVersion()`。
- **TUN 启动瞬间「interface not found」**:`auto-route` 劫持默认路由后 `auto-detect-interface` 探测不到物理网卡,出口被黑洞直到路由监视器追上。`toggleTUN` 启用时用 `route -n get default` 探测真实默认网卡并显式 PATCH `interface-name`(关闭时清空)。

### Changed
- **实时日志改为最新在顶部**(`LogsPage` 倒序展示,新日志滚动至顶部)。
- Helper 版本提升至 **v1.0.6**(`kHelperVersion` / `Helper-Info.plist` / `kExpectedHelperVersion` 三处同步)。
- App 版本提升至 0.4.5。

### Design System(UI 统一,第3–5批)
- **全量迁移到 `DesignTokens`**:颜色/间距/圆角/字号刻度集中于 `DS.Palette` / `DS.Spacing` / `DS.Radius` / `DS.Icon` 与 `Font.ds*`,改设计语言只需动一个文件。
- **字号刻度归一**:`system(size:)` 与语义字体(`.callout/.caption/.caption2/.headline/.subheadline/.title2`,共 ~91 处)统一到 24/20/14/12 刻度;离群尺寸(10/15/16/18/22/34/60)snap 到最近档,新增 `DS.Icon`(sm/md/lg/xl/hero)分离图标尺寸,`dsStatValue` 统一仪表盘大数字。
- **间距/圆角/语义色**:on-grid padding → `DS.Spacing.*`;`cornerRadius` → `DS.Radius.card/control`;hairline 与状态色 → `DS.Palette.hairline/ok/warn/error`。
- **网络入站页布局修复**:修正 `VStack` 括号错位导致的卡片间距不一致(仅首卡在容器内);卡片间距统一到 `DS.Spacing.l`;`StringListRow`/`NList` 的已有项改为 chip 背景,与新增输入框明确分隔。

