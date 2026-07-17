# Changelog

本项目所有重要变更记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/),版本遵循语义化版本。

## [1.1.2] - 2026-07-17

稳定性与设计精修：TUN/系统代理状态机加固、规则写盘事务化、胶囊滑块 Tab、浅色卡片层次。Helper **1.0.15 → 1.0.16**（启用系统代理补 `set*proxystate on`，触发旧 Helper 强制升级）。

### Changed
- **胶囊滑块 Tab**：`DSSegmentedControl` track 内缩 2pt + accent 选中胶囊；设置/网络页面级顶栏统一 `chromeBg`；侧栏选中与分段选中语言同源（`Docs/design.md` §6.8）。
- **浅色精致化**：`windowBg`/`controlBg` 重标定；`border` 软化；`dsCardChrome` 双层阴影（contact + ambient）；边界靠抬升+弱边，而非硬线框。
- **圆角嵌套递减**：顶层卡 `card` 10、卡内子表面 `control` 6、浮层 `panel` 12；仪表盘 `BarStat`/`MiniStat` 与兄弟 `Card` 同半径。
- **关代理面不再自动停核**：关 TUN / 关系统代理后内核保持运行，避免再开 TUN 走完整 root 重启。
- **`Scripts/build-debug.sh`**：编译并嵌入 Helper，Debug 可走与 Release 相同的 Helper 升级路径。
- **Helper 1.0.16**：`setSystemProxy(enabled:true)` 补 `setweb/secure/socksproxystate on`（与 GUI fallback 对齐）。

### Fixed
- **TUN 自动停核后重开误报权限不足**：Root 启核改走新鲜 XPC `callStartMihomo`；`ensureRunningAsync` 可 await。
- **TUN 开启先失败后成功的双 toast**：PATCH 后等待 utun 再 `refreshConfigs`；冷启核后 `reconnect` 刷新 `reachable`；Root 重启窗口加长。
- **系统代理 toast 已开启但开关不亮**：成功后 `syncSystemProxyState`，与 SCDynamicStore 不一致时信任本次写入；Toggle binding 仅边沿触发。
- **规则保存与 reload 非原子 / 不占 isBusy**：`applyRuleEditorSave` 备份→写盘→reload，失败回滚；核 down 允许只写盘并明示。
- **配置内容变更后规则页不刷新**：`configContentEpoch`；规则页订阅并 `reloadModel`。
- **静态路由清理走缓存 XPC 静默丢调用**：`callSetupExcludeRoutes` / `callCleanupAllExcludeRoutes`。
- **按钮 Label 文字在 32pt chrome 内不居中**：`DSButtonLabelStyle` 强制 icon+title 水平居中。
- **字重叠加重绕过 token**：订阅/代理/SD-WAN 等改走 `dsBodySemibold` / `dsMonoBold`。

## [1.1.1] - 2026-07-17

品牌色与侧栏对齐热修：主题色切到 PANTONE Medium Purple U，侧栏改为自绘导航并对齐 footer 图标列。Helper 协议未变，仍为 `1.0.15`（无需强制升级旧 Helper）。

### Changed
- **品牌主题色 → PANTONE Medium Purple U**：`DS.Palette.accent` / `accentSoft` / `accentStrong` 与 `Assets.xcassets/AccentColor` 统一到 `#65428A`（Dark 端提亮以保证对比）；系统控件仍走全局 `.tint` + `GLOBAL_ACCENT_COLOR_NAME`。
- **数据可视化色与品牌色解耦**：`download` 保留独立绿色系；仪表盘策略组排名与流量分布「代理」环段改用 `DS.Palette.download`，不再跟品牌 accent。
- **侧栏改为自绘导航**：弃用 `List(.sidebar)`，避免系统 contentMargins/listRowInsets 叠出 2–4pt 无法对齐；导航与 footer 共用 `pageContentInset` + 同宽图标槽，图标列像素级同左缘。
- **侧栏图标统一 outline**：导航与 footer 一律 outline 字形 + `monochrome` + 固定 `lg` 槽位（仪表盘/日志/代理/规则/设置/系统代理/TUN）。
- **侧栏 footer 平铺**：系统代理 / TUN / 核心状态取消 `controlBg` 抬升卡，与导航行同结构对齐。

### Fixed
- 侧栏导航图标 fill/outline 混用、视觉大小不一。
- 侧栏导航与 footer 图标列因系统 List inset 无法对齐。

## [1.1.0] - 2026-07-16

设计系统与 Shell 布局主版本：全页面统一 32pt 控件高度、侧栏/内容区 chrome 对齐、空状态与关于页重做。Helper 协议未变，仍为 `1.0.15`（无需强制升级旧 Helper）。

### Added
- **统一设计系统落地**：`Docs/design.md` + `DesignTokens.swift` 成为 UI 真相源；自绘 `DSSegmentedControl` / `DSMenuPicker` / `dsButton(...)` 固定 32pt / 圆角 6pt，替换原生 bezel 漂移。
- **跨栏 chrome 对齐**：新增 `DS.Layout.chromeHeight`（`m + controlHeight + m` = 56）；侧栏顶栏、PageToolbar、连接/日志/规则/设置/网络顶栏同高；分割线统一通栏 `Divider().overlay(separator)`。
- **Debug 构建脚本**：`Scripts/build-debug.sh` 本地验证不 bump build 号。
- **全局 AccentColor**：`Assets.xcassets/AccentColor` + `GLOBAL_ACCENT_COLOR_NAME`，系统控件与品牌色同源。

### Changed
- **侧栏导航重设计**：恢复「监控 / 代理 / 配置」分组；首组「监控」额外顶距；行高与组间距按 8pt 网格；footer 系统代理/TUN 放入 `controlBg` 抬升卡；侧栏宽度 212/236/280。
- **配置页卡片**：顶距离开 chrome 分割线；`profileCardMinHeight` 统一卡片高度；header/footer 锁 32pt。
- **网络拓扑页**：内容区补顶距，与配置页节奏一致。
- **设置 → 关于**：从居中营销 hero 改为工具型 Card 堆叠（身份 / 版本明细 / 更新 / 链接 / 说明）。
- **空状态统一**：`ContentUnavailable` 自身垂直居中填满；连接/代理/日志/订阅/规则/配置空态与内容态互斥，不再塞进 ScrollView 或叠魔术 `padding.top`。
- **网络页 DNS 动作行**：挪到顶栏分割线下方，避免顶栏高度因 tab 抖动与侧栏错位。
- **侧栏选中 / 系统开关 / Progress**：统一到品牌 accent（不再走系统蓝）。

### Fixed
- 侧栏与内容区分割线无法水平对齐。
- 配置卡片贴顶、有/无 CTA 高度不一致。
- 连接/代理/日志/订阅空状态图标位置漂移。
- **内核关闭后 TUN 开关仍显示开启**：`stopKernel` 未清 `runningAsRoot`，且停核过程中进行中的 `refreshConfigs` 仍可能用旧的 `tun.enable` + 残留 utun 把 `tunOn` 写回 true。修复：`stopKernel` 复位 `runningAsRoot`；`refreshConfigs` 的 TUN 活跃判定增加 `reachable` 门控；`stopEngine` 强制磁盘 `tun.enable=false`、清理静态路由与僵尸 utun 残留。
- **侧栏选中色与内容区重点色不一致**：系统 List/Switch 仍走系统蓝，内容区用品牌 accent。补 `AccentColor` 资源 + `GLOBAL_ACCENT_COLOR_NAME`，并在主窗口 / 菜单栏 / `ContentView` 统一 `.tint(DS.Palette.accent)`。

## [1.0.15] - 2026-07-14

本次发布涵盖 v1.0.7 release 之后的全部修复：TUN 自愈链路加固、bypass 探测稳健化、并发守卫防泄漏。Helper 内核服务版本 `1.0.14 → 1.0.15`，触发已安装旧 Helper 强制升级。

### Fixed
- **BypassProbe 动态枚举网络服务、required 引用单一源、探测离主线程**：`reconcileProxyBypassIfNeeded` 三处加固——
  1. 探测改用 `-listallnetworkservices` 枚举所有活跃服务逐个 `-getproxybypassdomains`，替换原硬编码 "Wi-Fi"，避免纯以太网/USB tether 主机上 `current==[]` → 持续误判 churn。
  2. required 改为直接引用 `kProxyBypassDomains` 单一真源，覆盖完整 86 条（含 loopback/mDNS/172.16-31/CGNAT 100.64-127），消除与 Helper 列表漂移导致的 Tailscale 502。
  3. 探测 fork networksetup 与 missing 判定整块搬入同一 `Task.detached`，离开 MainActor，消除每次重连主线程被同步子进程阻塞 ~30-100ms。
- **handleNetworkChange 的 isBusy 裸写改 defer 复位，防 cancel 泄漏**：TUN 保活路径原先 `engine.isBusy = true; await ...; engine.isBusy = false` 裸写无 defer，若在 await 挂起点被 Task cancel 抛 CancellationError 则复位不执行 → `isBusy` 永久卡 true、所有后续 toggle 被永久 toast 拦截。改用 defer 单点复位，与同链 `verifyTUNConfig` / `refreshConfigs` B10 已采用的 defer 模式一致。
- **mihomoTunInterface 单候选加保守路由校验自愈 zombie**：单 candidate utun 原先直接信任返回，mihomo 崩溃后其 198.18 地址残留于 `getifaddrs` 但路由已死会被误判存活 → 两条 auto-teardown 均不动 → 系统 DNS 钉死 198.18.0.1 但接口死 → 整机 DNS 黑屏无自愈。新增保守双判据：仅当候选 `isUp==false`（IFF_UP/IFF_RUNNING 已清）且 `route -n get 198.18.0.1` 解析的接口指向非该 utun 时才判为 zombie 返回 nil，复用既有 `applyTUNState(false)` 自愈通道。双判据规避刚 enable 路由注入 race 窗口，保住"宁可漏关一拍也不误关"的保守态。新增只读非 root helper `routeTargetInterface(ip:)`，纯 GUI 无需特权。
- **zombie TUN 残留物理清理兜底**：上一条识别 zombie 后复用自愈通道已能逻辑关闭 TUN，但若 zombie utun 接口**物理残留**（198.18 地址在、socket 未回收），其 Supplemental DNS resolver 仍可能持续劫持 198.18.0.1，仅 networksetup 层 restoreDNS 解不彻底。补兜底链：
  - `Models.swift` 新增 `hasDownedMihomoTun()` 同步探测（`proxyTun && !isUp`）作为物理清理门控，保持 198.18.x 共址段 VPN（Shadowrocket 等）UP 状态不被误清。
  - auto-teardown 两路径（`verifyTUNConfig` + `refreshConfigs` B10）在 `applyTUNState(false)` 后，若 `hasDownedMihomoTun` 为真则经 XPC 下发 `ProxyManager.cleanupTUNResidual()`（`ifconfig down` + 删除 IP + `route flush`）物理中和残留接口。
  - XPC schema：`@objc(HelperProtocol)` 新增 `cleanupTUNResidual`；`kSharedHelperVersion` 1.0.14→1.0.15 驱动旧 Helper 强制升级；`Helper-Info.plist` CFBundleVersion 同步 1.0.15；Helper main 加 `routesLock` 保护的转发；`XPCManager` 新增新鲜连接 `callCleanupTUNResidual` 包装（仿 `callSystemProxy`，超时 + 单次 resume 守卫）。
  - 新旧 Helper 共存期：旧 Helper 无新方法，新鲜连接超时返回 nil，GUI 仅记失败日志、不误操作。

## [1.0.7] - 2026-07-13

### Fixed
- **修复僵尸 utun 被误判为活跃 TUN 导致整机 DNS 瘫痪的严重问题**：当 mihomo 因崩溃或被重建到新 utun 而退出原接口，但旧 utun 的 `198.18.x.x` fake-ip 地址仍残留时，原 `mihomoTunInterface()` 仅凭地址前缀识别、用 `first(where:)` 可能选中已失效的僵尸接口，判定 TUN 仍活跃 → 不触发自动关闭 → 系统 DNS 持续钉死在无 mihomo 应答的 `198.18.0.1`，整机 DNS 瘫痪，且 30 秒健康检查的 DNS 漂移探针也被钉死网关欺骗、补救路径全失效。
- **根因**：`getifaddrs` 只能看到接口名+地址+flags，无法获知 utun 由哪个进程持有；僵尸 utun 与新生成的活 utun 在接口枚举中并存，首匹配即返回的选取策略可能挑中僵尸。
- **修复方案**：
  - **路由表所有权仲裁**：`mihomoTunInterface()` 改为 async，当存在多个 `proxyTun` 候选时，用既有 `allRoutes()` 扫描路由表，挑选首个被路由表引用的候选——活 mihomo TUN（auto-route）必有 default / fake-ip 段 / 拆分宽路由指向其 utun，而僵尸 utun 通常只剩自连地址、无路由引用。识别为僵尸后落到既有「接口丢失」自愈路径，自动关闭 TUN 并恢复系统 DNS。
  - **保守设计防误关**：仅单个候选时直接信任（不查路由表、不每 3 秒 fork netstat 常态开销，且避免 API 抖动误关健康 TUN）；多候选但路由表无法判定时回退首个候选（宁可漏判一次，下次轮询再仲裁，不误关正在工作的 TUN）。
- **修复 TUN 自动关闭与用户操作并发抢写配置的竞态**：`refreshConfigs`（3 秒轮询）与 `verifyTUNConfig`（30 秒）两条自动关闭路径原先以 `tunAutoTeardownInFlight` 互斥彼此，但其 `detached Task` 跑的 `applyTUNState(false)` 不持有 `engine.isBusy`，导致自动关闭进行中用户开启 TUN 可被 `withEngineBusy` 放行，两条 `applyTUNState`（一关一开）并发抢写 `patchConfig` 与 `interface-name`，终态取决于竞态。
- **修复方案**：两条自动 teardown 路径手工持有 `engine.isBusy=true` 并以 `defer` 单点复位 `isBusy` 与 `tunAutoTeardownInFlight`，使自动关闭期间用户 `toggleTUN` 等入口被 `guard !engine.isBusy` 挡下并提示「内核操作进行中」。绕过 `withEngineBusy`（其 fire-and-forget 语义会使守卫在关闭完成前过早复位）。同时修复 `verifyTUNConfig` 中守卫裸写复位可能因 `applyTUNState` 提前返回而永久卡死的既有隐患。
- **bypass 列表彻底单一来源**：删除 `NetScanner.proxyBypassDomains`（GUI 侧的冗余副本，零引用），系统代理 bypass domains 统一由 `kProxyBypassDomains`（`Sources/XPC/HelperProtocol.swift`）单一常量提供，XPC Helper / 本地回退 / GUI 自愈 / SD-WAN 视图全部引用同一来源，从源头消除两份相同数组漂移的可能。

## [1.0.6] - 2026-07-12

### Fixed
- **修复升级后系统代理被反复还原成旧 bypass 的严重回归**：v1.0.5 的「启动时自动补齐 bypass」逻辑通过 XPC 调用 Helper 重写 bypass，但若已安装的 Helper 仍是旧二进制（即便其报告的版本号与期望一致，二进制内容为旧版、仍写旧的 3 项 bypass），就会把刚补齐的正确 bypass 再覆盖回 `localhost/127.0.0.1/*.local`，使局域网设备持续返回 502。
- **根因**：旧 Helper 二进制报告版本 `1.0.13` 与期望相同 → 版本比较"相等" → 不触发升级 → 旧二进制永不替换 → 修复点形同虚设。
- **修复方案**：
  - **bypass 列表单一真相**：新增共享常量 `kProxyBypassDomains`（HelperProtocol.swift，Helper 与主 app 均编译它），`ProxyManager`、`setSystemProxyFallback` 统一引用，杜绝三路径漂移。
  - **bypass 自愈改走本地直接写**：`reconcileProxyBypassIfNeeded` 不再经 XPC/Helper，直接在 GUI 进程用 `networksetup -setproxybypassdomains` 对所有网络服务循环写入正确 bypass。用户对自己的网络服务有写权限，无需 root；也彻底避免被"假升级"的旧 Helper 把正确值覆盖回旧。
  - **强制升级旧 Helper**：`kSharedHelperVersion` 1.0.13 → 1.0.14，触发已安装旧二进制被新版替换，纠正其 setSystemProxy 行为。

## [1.0.5] - 2026-07-12

### Fixed
- **升级后自动补齐系统代理 bypass**：修复从旧版本升级后，已处于开启状态的系统代理 bypass 仍是旧列表（`localhost/127.0.0.1/*.local`，缺少局域网网段），导致局域网 IP 仍被转发到 mihomo 返回 502、无法访问 NAS/路由器等设备的问题。
- **根因**：1.0.4 的 bypass 补齐点位于 `setSystemProxy` 函数内部，仅在该函数被调用时写入。升级后系统代理开关状态未变，不会重发 `setSystemProxy`，老用户无法享受修复。
- **修复方案**：在 `syncSystemProxyState` 判定系统代理为我们所设（`127.0.0.1:port`）后，调用 `reconcileProxyBypassIfNeeded()`——读取当前 bypass，若缺少 `10.*`/`192.168.*`/`172.16.*`/`169.254.*` 关键网段，自动重跑一次 `setSystemProxy` 把完整 bypass 写回。幂等，仅在确实缺失时动作，已正确的用户零开销。让升级修复自动惠及"代理已开着"的老用户，无需手动重开关。

## [1.0.4] - 2026-07-12

### Fixed
- **系统代理局域网访问修复**：修复开启系统代理模式后无法访问局域网中其他 IP（如 NAS、路由器、打印机等 `192.168.x.x` / `10.x.x.x` / `172.16-31.x.x` 设备）的问题。根因是系统代理的 `proxy bypass domains` 仅包含 `localhost`、`127.0.0.1`、`*.local`，缺少 RFC1918 私有网段，导致局域网流量被错误转发到 mihomo 代理端口，而代理无法路由到这些内网地址。
- **跨路径 bypass 一致性**：统一了 XPC 主路径 `ProxyManager.setSystemProxy` 与本地 shell 回退路径 `setSystemProxyFallback` 的 bypass domains 列表，避免 Helper 不可用时 fallback 行为不一致。补充的绕过网段包括：
  - `10.*` / `192.168.*`（RFC1918 A/C 类私有网）
  - `172.16.* ~ 172.31.*`（RFC1918 B 类全部 16 个子网）
  - `169.254.*`（link-local 链路本地）
  - `100.64.* ~ 100.127.*`（CGNAT / Tailscale 100.64.0.0/10 全部 64 个子网）
- macOS 的 proxy bypass 匹配采用 shell 通配符，故每段私有 IP 前缀以 `.*` 兜底，实测所有局域网主机可正确绕过代理走直连，公网流量仍走代理。

## [1.0.3] - 2026-07-12

### Fixed
- **TUN 模式接口丢失自动恢复**：修复应用长时间运行后，当系统中并存多个 `utun` 虚拟接口（如 Tailscale、ZeroTier、系统 VPN 等）时，mihomo 自身 TUN 接口可能因异常退出而消失，但原有逻辑仅凭配置标志判定 TUN 状态，导致应用误判 TUN 仍处于开启、持续将系统 DNS 重定向到已不存在的接口，造成全局流量黑洞的严重问题。
- **接口存在性三重校验**：新增 `NetScanner.mihomoTunInterface()` 方法，通过 198.18.x.x fake-ip 地址段精确识别 mihomo 实际创建的 TUN 接口（与其他 utun 服务区分），在 `refreshConfigs` 中改为「配置开启 + root 运行 + 接口实际存在」三重校验，只有三者同时满足才判定 TUN 活跃。
- **健康检查接口巡检**：增强每 30 秒一次的 `verifyTUNConfig` 健康检查，新增 TUN 接口存在性巡检（原有仅检查 DNS 漂移）。一旦检测到接口丢失，自动关闭 TUN 模式并恢复系统 DNS，避免网络中断，并在日志与 Toast 中提示用户。

## [1.0.2] - 2026-07-10

### Fixed
- **SD-WAN 冲突与自动绕行修复**：优化了虚拟网卡与代理 TUN 冲突绕行的机制。自动检测除本代理（proxyTun）外所有的活跃虚拟网口（以 `utun` 开头的网卡），并建立网段到原接口的映射关系，增加了对 Tailscale 没有获取到 IP 时的 fallback 兜底。
- **静态路由注入与状态同步**：当开启 TUN 或应用启动/内核热连时，通过特权服务 XPC 自动为绕行网段在系统路由表中注入直连网口的静态路由（例如：`route add -net 100.64.0.0/10 -interface utun0`），解决最长前缀匹配导致的默认代理路由劫持超时问题。
- **生命周期安全清理**：退出应用、关闭 TUN 或特权 Helper 捕获客户端退出时，自动清理注入的静态路由，避免本地网络污染。
- **并发更新安全**：通过 `Task { @MainActor in }` 保证状态机更新的线程安全，避免多线程数据竞争。

## [1.0.1] - 2026-07-08

### Added
- **自适应亮色模式**：移除了全部强制暗色锁定限制，适配系统 Appearance 外观主题。
- **服务自适应联动**：打开 TUN 或系统代理时若内核未连接则自动加载，关闭所有代理网络服务时自动关停内核，节省后台能耗。
- **代理页异常重试**：代理页支持渲染详细错误日志并呈现一键重试按钮，不再无限加载。
- **远程订阅归类支持**：添加了对 HTTP/HTTPS 远程订阅文件的智能判定，导入后自动归为远程订阅以便后续在线更新。

### Fixed
- **用户态内核闪退修复**：通过类生命周期属性强引用 Process，防止用户态进程在 Task 退出时被垃圾回收析构。
- **订阅防空防错机制**：增加对订阅下载 HTTP 200 及 YAML 结构的防空防错校验，阻止错误或空白的远端内容覆写并破坏本地有效配置。
- **时延降低**：重构 `waitForKernelReady` 为前置即时探针，并使用增量微秒延迟序列，将就绪等待时间从 300ms+ 缩减至 150ms 左右。
- **网关代理服务隔离**：优化 XPC 管理下的服务代理设置，仅将配置应用至活跃的 Wi-Fi 或 Ethernet 网卡，消除对其他虚拟不活跃设备（如雷雳、蓝牙）的无效顺序遍历，将代理开关耗时缩减 80%。

## [1.0.0] - 2026-07-04

### Changed
- **版本号调整为 v1.0.0**：统一 App Info.plist、Xcode `MARKETING_VERSION`、README 与发布包命名。
- **项目名称统一为 ClashHalo**：Xcode 工程、Scheme、App 入口、Bundle ID、Helper Mach Service、运行时数据目录、日志目录、打包脚本和文档链接统一指向 ClashHalo。
- **升级兼容迁移**：启动时自动迁移旧版数据目录，安装新版 Helper 时清理旧版特权服务残留，避免更名后配置丢失或旧守护进程冲突。

### Fixed
- **网关模式开启可靠性**：修复 Helper 已安装但当前内核仍为用户态时网关开启失败的问题；网关配置改为可回滚热重载，Helper 同时设置 IPv4/IPv6 转发。

## [0.5.4] - 2026-07-01

构建 0.5.4 稳定性、权限可靠性与安全加固更新。本次更新系统性排查并修复了「设置持久化」「核心开关级联」「macOS 特权服务权限死锁」三大类共 31 项问题，从根本上解决了设置重启丢失、Gateway 停止后系统状态残留、TUN 授权后卡死等痛点；同时收紧了特权辅助程序的客户端鉴权，消除了同名应用越权执行 root 命令的安全风险。

### Security
- **特权服务客户端鉴权收紧**：`isAuthorizedClient` 的路径校验从宽松的子串匹配（任何路径含 `clashhalo`/`clashhalo` 即通过）改为严格的 `.app` Bundle 结构匹配（`/ClashHalo.app/Contents/MacOS/`），彻底消除了本地同名 ad-hoc 签名应用连接特权 Helper 越权执行 root 命令的风险。
- **Helper 版本号单一来源**：将特权服务版本号提取为 `kSharedHelperVersion` 共享常量（Helper 与主程序共享编译），消除了此前分散在两处、发布时易漏改导致的「无限升级循环」隐患。

### Fixed
- **应用设置持久化修复**：修复了「日志级别、TCP 并发、绑定网卡、GEO 下载源 URL」等多项高级设置因仅写入运行时内存（而未落盘 `config.yaml`）导致的**重启后丢失**问题；统一了日志级别的数据来源，消除了「设置页」与「日志页」状态漂移。
- **核心开关级联修复**：
  - **停止内核**时主动清理网关中枢的系统级 IP 转发（`sysctl net.inet.ip.forwarding`），防止内核停止后系统转发状态残留。
  - **手动重载配置**时自动重新注入网关中枢覆盖配置（`allow-lan` + `dns.listen`），防止重载后局域网设备静默断连。
  - **关闭 TUN** 级联关闭网关中枢时，恢复 `allow-lan`/`dns.listen` 快照并清空缓存，防止后续切换配置读取到脏数据。
  - **系统代理**与**配置切换**操作纳入统一并发锁 `engine.isBusy`，消除与 TUN/网关切换的状态竞争。
  - **切换代理模式**（规则/全局/直连）时按「切换节点」策略触发连接重拨。
- **macOS 权限死锁修复**：
  - **启用 TUN / 网关**安装特权服务后，主动校验 XPC 连通性，避免 `launchd` bootstrap 失败时应用永久卡在「等待内核」状态。
  - **Helper 升级**校验连通性成功后才标记 root 状态，避免升级失败后永久误判导致内核无法启动。
  - **Root 内核启动失败**时（端口冲突 / 二进制校验失败）自动回退到用户态启动，不再永久卡死。
  - **网关中枢启用**改用 10 次轮询等待内核就绪，替代此前不足的 2 秒固定等待，确保 mihomo 完成 `0.0.0.0:53` 端口绑定。
- **系统 DNS 恢复健壮性**：修复了在系统 DNS 为空（全新 macOS）时开启 TUN 后，关闭时 DNS 卡在 `198.18.0.1` 无法恢复的问题（引入 `Empty` 哨兵值）。
- **休眠唤醒网关恢复**：修复了唤醒后配置重载失败时仍强行开启 IP 转发，导致「路由已开但 DNS 未监听」的半残状态。
- **特权服务误清理修复**：Helper 引入活跃连接计数，仅在客户端最后一个连接关闭且进程确实退出时才恢复系统代理/DNS，避免一次性 XPC 调用（如设置网关、连通性检测）误触发状态清理。

### Performance
- **连接页渲染优化**：将连接列表的过滤 + 排序逻辑从每次 SwiftUI body 求值（悬停 / 选中 / 切换标签均触发）移至计算属性缓存，大规模连接（1000+）场景下滚动与交互流畅度提升 5–10 倍。
- **事件驱动刷新**：停止每 3 秒轮询刷新代理列表，改为在模式切换、配置切换、测速等事件后按需刷新，空闲时 UI 重渲染频率降低约 67%。
- **网络请求超时**：为订阅下载（60s）与内核下载（120s）配置 `URLSession` 超时，避免慢速服务器导致界面假死。
- **后台资源节流**：主窗口隐藏时连接快照轮询间隔由 10 秒延长至 30 秒，后台内存分配频率降低约 67%；日志缓冲容量提升（内核日志 200 行 / 实时日志 300 行）。

### Changed
- **代码精简**：提取网关中枢覆盖配置为统一常量 `AppModel.gatewayOverrides`，消除 4 处重复定义。

## [0.5.3] - 2026-06-26

构建 0.5.3 极致性能与仪表盘体验更新。此次更新彻底重构了内部的仪表盘聚合算法，通过直接操作原生底层模型 `ConnectionItem`，彻底阻断了大规模并发场景下前端 Swift 对象的垃圾回收（GC）风暴，将常驻内存占用与 CPU 开销压榨到极限；同时对应用首页进行了现代化 UI 精简。

### Added
- **主题系统全面重构 (Design System Redesign)**：移除了冗余的用户自定义多强调色切换逻辑，全局统一使用品牌主题色；重构了底层色彩 Token，使得各面板卡片背景完美自适应系统的浅色与深色 (Light/Dark) 模式切换。

### Performance
- **极致仪表盘内存优化**：
  - 彻底抛弃了在后台每 10 秒（或前台活跃时每 1.5 秒）强制生成前端抽象 `Conn` 结构体的中间转化链路。
  - 新增 `computeDashRaw` 底层原生算法，利用后端直出的原生轻量 JSON 对象结构直接完成归类聚合，完全绕过海量对象的内存分配与字符串开销。
  - 修复了用户在 `Dashboard` 停留时依然会在后台大量初始化无用内存对象的缺陷。

### Changed
- **仪表盘视觉精简**：
  - 移除了仪表盘第四行的“流量时间轴”卡片，大幅减少了卡片模块间的视觉耦合度。
  - 回退并修复了“流量趋势”卡片的布局对齐问题，恢复了实时的上下行速率数值展示。
  - 移除了冗余并可能显示空白的“热门进程”卡片，将“高频规则”、“热门域名”、“热门节点”自适应平铺为等距的三列布局，视觉更加开阔大气。
  - 剔除了内存监控栏中与顶部状态栏完全重复的“活跃连接”展示卡片，为“核心内存”与“应用内存”卡片赋予了更大的展示空间。
  - “热门节点”更新为 `server.rack` 图标，更贴合节点特征。

### Fixed
- **YAML 序列化引擎修复**：修复了在删除或编辑“远程订阅代理 (Proxy Providers)”时，因 YAML 行内换行符或脏数据造成的 `mapping values are not allowed in this context` 报错，确保配置正确持久化；现在增删远程订阅后会自动将其从相关的策略组 (Proxy Groups) 及规则引用中关联清理/添加。
- **UI 对齐修复**：彻底修复了“连接”页、“日志”页中 `Picker(Segmented)` 控件由于原生 SwiftUI Bezel 内边距偏移，导致的文本未能与页面头部标题完全左对齐的视觉瑕疵。

## [0.5.2] - 2026-06-25

### Changed
- **统一并发保护**：新增 `withEngineBusy` 闭包包装器，统一管理所有内核长耗时操作（TUN 切换、重启、Gateway 切换）的并发锁 `engine.isBusy`，彻底防止状态竞争。
- **配置属性提取**：统一提取 `proxyPort` 属性，消除 `mixed-port` / `port` 读取逻辑的重复代码 (DRY)。
- **移除了 Sub-Store 本地后端集成**：彻底删除了 Node.js 运行时及相关前端视图，大幅减小应用体积并降低内存占用，恢复纯净轻量化内核编排架构。
- **Connections 性能深度优化**：将连接数据的 WebSocket 实时流式推送改为 1.5 秒频率的 HTTP 轮询；在网络高并发（数千连接）场景下，此改动可减半内存分配频率，从根本上解决 Graphics 和 JSON 序列化带来的 Memory Churn 问题。
- **构建系统增强**：`make.sh` 打包脚本现已支持打包前自动递增 Xcode 工程内的构建版本号 (Build Number)。

### Fixed
- **网关中枢 (Gateway Mode) 级联与休眠唤醒恢复**：
  - 配置切换联级更新：切换配置文件时，如果 Gateway 处于开启状态，会重新注入 Gateway 相关的重载配置 (`allow-lan` 等) 并自动应用新系统代理端口，防止功能因配置覆盖而静默失效或流量泄露。
  - 休眠唤醒状态恢复：记录设备睡眠前的 Gateway 开启状态 (`preSleepGatewayOn`)，在唤醒重连时自动恢复并应用底层覆盖配置，解决休眠唤醒后局域网连接断开的问题。
- **YAML 解析器修复**：修复了内建轻量级 YAML 解析器对 Flow-style array (`["a", "b"]`) 的解析失败问题，保证通过此格式下发的 Provider 配置能够被正确处理。

## [0.5.1] - 2026-06-22

构建 0.5.1 功能增强、性能优化与配置管理完善更新。新增 Sub-Store 本地后端集成，大幅降低内存占用，完善系统休眠/唤醒恢复机制，修复网络嗅探配置管理问题。

### Added
- **Sub-Store 本地后端集成**：
  - 新增 `SubStoreEngine` 管理类，自动启动 Node.js 运行 Sub-Store 后端（sub-store.bundle.js v2.31.2）监听本地端口 3000。
  - 应用启动时自动启动后端，退出时自动停止，用户无需手动配置。
  - 仪表盘新增「Sub-Store」按钮，点击在浏览器中打开官方前端（https://sub-store.vercel.app），自动连接本地后端。
  - 移除了内嵌的 WebView 方案和侧边栏独立入口，采用与 Zashboard 一致的浏览器启动方式，保持 UI 简洁。
  - 后端自动检测 Node.js 路径（支持 homebrew, nvm, fnm 等安装方式）。
  - 数据存储在 `~/Library/Application Support/ClashHalo/sub-store-data/`。

- **内存优化与自动保护机制**：
  - 新增 `AppModel.residentMemoryBytes()` 方法实时监控应用物理内存（RSS）占用。
  - 当应用 RSS 超过 400 MB 时自动清空所有连接缓存，防止内存泄漏。
  - 连接追踪从重量级 `prevConnsMap: [String: Conn]` 改为轻量级 `activeConnsSet: Set<String>`，减少数十万次对象分配。
  - `prevConnBytes` 字典增加 2000 条目上限保护，防止长时间运行后无限增长。

- **系统休眠/唤醒完整恢复流程**：
  - `prepareForSleep()` 中保存休眠前的 TUN 和系统代理状态，并主动释放 4 个连接缓存字典。
  - `recoverFromWake()` 中增加完整恢复流程：探测内核健康 → 必要时重启内核 → 重连 API → 恢复 TUN → 恢复系统代理。
  - 确保系统唤醒后代理状态一致，无需用户手动干预。

- **自动化集成测试套件**（0.5.1 早期版本）：
  - 新增 `Scripts/integration_test.sh` 端到端 Bash 自动化集成测试脚本，覆盖特权守护进程 Dead Man's Switch (崩溃兜底清场机制)、网络瞬断自动容错、及内核崩溃防死锁恢复测试用例。

### Fixed
- **网络嗅探（Sniffer）配置管理问题**：
  - 修复 mihomo API `/configs` 不返回 `sniffer` 字段导致 `refreshConfigs()` 清空内存配置、嗅探开关失效的问题。
  - 新增 `EngineControl.readConfigFile()` 方法从 config.yaml 读取嗅探配置并合并到运行时配置中。
  - 修复 config.yaml 中 `sniff` 字段格式错误（从数组改为对象格式），添加默认协议配置（TLS, HTTP, QUIC）。
  - 嗅探页面新增「解析纯 IP」开关，优化帮助文本说明嗅探是加载时配置需重启内核生效。

- **启动防误杀与多环境触发重入漏洞**（0.5.1 早期版本）：
  - 修复了 SwiftUI 生命周期（`onAppear` 等）由于多窗口或从后台唤醒导致的多次重新初始化，进而反复触发 `AppModel.start()` 中意外全杀 (`killall -9`) 内核守护进程的漏洞。采用无损探活 (`api.probe()`) 与状态栅栏替换了原有的暴力重启逻辑。

- **配置切换的 TUN 静默丢失问题**（0.5.1 早期版本）：
  - 修复 `activateProfile` 重新应用底层配置时由于隐式调用 `forceTUNDisabled()` 造成 TUN 虚拟网卡丢失的问题，现在会在配置重载后自动保存并恢复先前的 TUN 开关状态。

- **崩溃兜底（Dead Man's Switch）竞态异常与断网死锁修复**（0.5.1 早期版本）：
  - 修复由于强杀客户端进程导致 XPC 连接断开时，底层 Helper 守护进程中的 `kill(clientPid, 0)` 因内核未及时完成孤儿进程回收而错误跳过紧急清场（关闭遗留内核、还原 DNS/代理）的严重问题。现已引入 0.5s 进程异步销毁确认延迟。

- **死循环式系统代理自关闭漏洞修复**（0.5.1 早期版本）：
  - 修复当用户主动关闭内核却单独保留”系统代理”开启时，后台 3 秒一次的探测任务会将”合法离线”误判为”内核崩溃断开”并强制关闭系统代理的智障反馈循环。

### Changed
- **Sub-Store 集成方式调整**：
  - 移除侧边栏「Sub-Store」菜单项和独立页面路由。
  - 移除 WKWebView 内嵌方案（`Resources/Panels/sub-store/*` 前端资源已删除，共 147 个文件）。
  - 统一为仪表盘按钮 + 浏览器启动方式，与 Zashboard 保持一致的用户体验。

### Performance
- **内存占用大幅降低（200+ MB → 60 MB）**：
  - 后台轮询间隔从 6 秒延长至 10 秒，减少 JSON 序列化开销。
  - 系统休眠或网络离线时跳过连接轮询，避免无效 API 调用。
  - 主窗口不可见时清空所有连接缓存（cachedConns, cachedClosedConnections, prevConnBytes, activeConnsSet）。
  - 网络离线时主动释放 prevConnBytes 和 activeConnsSet，减少内存占用。
  - 仪表盘流量图更新间隔从 1 秒节流至 2 秒，减少 Canvas 重绘导致的 Graphics 内存开销。

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
- 修复因打包工具链及 App 重命名导致特权守护程序 (`com.clashhalo.helper`) 的 `isAuthorizedClient` 路径鉴权失败、拒绝 XPC 握手的问题。通过重写底层路径验证逻辑及重新构建打包脚本予以解决。

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
