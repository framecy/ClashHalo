# AGENTS.md

本文件给后续 AI 编码代理使用。进入本仓库后，先读本文件，再按需读 `README.md`、`CHANGELOG.md` 和相关源码。

当前主干：`main`，产品版本 **v1.3.6**（`MARKETING_VERSION`，与 `Sources/Info.plist` 的 `CFBundleShortVersionString` 同源），Helper **1.0.30**（`kSharedHelperVersion`，`Helper-Info.plist` 的 `CFBundleVersion` 同值）。当前构建号 **126**（`CURRENT_PROJECT_VERSION`，`make.sh` 每次打包自增）。

## 项目概览

这是一个 macOS 14+ 原生 SwiftUI 代理客户端。项目名、Bundle ID、数据目录、Helper 服务和用户可见品牌统一为 **ClashHalo**。旧版 `ClashPow` 只应出现在迁移或清理兼容代码中。

应用直接编排官方 `mihomo` 内核，没有 Swift Package manifest，主要通过 `ClashHalo.xcodeproj` 构建。

分层：

- GUI：SwiftUI / AppKit / Combine，入口 `Sources/App/ClashHaloApp.swift`
- 状态：`AppModel`（`@MainActor`）是中心状态与生命周期编排器，按领域拆扩展文件
- 内核/API：`EngineControl` 管进程、配置、TUN/root；`MihomoClient` 调 mihomo REST/WebSocket
- 特权：`XPCManager` 与 `Sources/Helper/main.swift` 通信，处理系统代理、root 启动 mihomo、网关转发、静态路由与 zombie TUN 物理清理

## 关键路径

- `Sources/App/`：App 入口、窗口、菜单栏、主路由
- `Sources/Model/`：核心状态、配置/订阅、连接和代理业务
  - `AppModel.swift`：共享状态、生命周期（**启动时优先** `checkAndUpgradeHelperIfNeeded`）、网络/睡眠监听、bypass 自愈、TUN/网关健康巡检、自动更新
  - `AppModel+Config.swift`：配置切换、`refreshConfigs`、系统代理/TUN/网关切换、`withEngineBusy`；**网关开关不从 config 推断**
  - `AppModel+Proxies.swift` / `AppModel+Connections.swift`：代理与连接；`updateGatewayDevices` 聚合 LAN 客户端
  - `Models.swift`：`NetScanner`（含 `mihomoTunInterface` / `hasDownedMihomoTun`）
  - `Coexistence.swift`：utun 共存。分层取证检测 VPN 对端（守护进程 + IP 段，未知厂商退化为通用 peer）、`route-exclude-address` 归属追踪（自动条目可撤回，用户手写条目不动）、指纹门控。**`PATCH /configs` 对嵌套对象是整块替换不是深合并**，改 `tun` 任何字段都必须走 `tunPatchBody()` 重述完整块，否则 `enable` 会被打回 false；DNS 层无法安全 PATCH，只经 `dnsAdvice` 写日志。
    **路由采集必须过滤**（`routesByInterface`）：对端的接口作用域路由（`I` 标志）全局不承载流量，把它重装成非作用域静态路由等于凭空制造劫持；链路专用前缀与本机直连网段一律不得指向隧道。判据在 `PeerRouteGuard`（`HelperProtocol.swift`，GUI 与 Helper 共用），Helper 侧二次拦截并回收孤儿路由
  - `ConfigStore.swift`：订阅 manifest；URL 存 Keychain
  - `TunnelDNSLedger.swift`：系统 DNS 重定向的唯一记账属主（纯逻辑、无 MainActor、零 impure 依赖）。`.tun` / `.proxy` 双属主各持独立 service pin + 快照，pending→committed 两段式，恢复失败保留账本；生产适配器 `EngineControlDNSDriver` 在 `EngineControl.swift` 末尾，回归套件 `Tests/DNSLedger`（dnsledger-tests）钉住 5 条不变量；排查用 `grep '\[DNSLedger\]' ~/Library/Logs/ClashHalo/app.log`
- `Sources/XPC/`：
  - `HelperProtocol.swift`：XPC 协议 + 共享常量 `kSharedHelperVersion` / `kProxyBypassDomains`
  - `EngineControl.swift`：内核与配置热补丁、Helper 升级（`runAdmin(prompt:)` 预授权说明）、系统代理/DNS
  - `ProxyManager.swift`：系统代理、exclude routes、`cleanupTUNResidual`
  - `XPCManager.swift`：连接、超时包装、`installDaemon`/`upgradeDaemon` 预检与 stage 安装、`callCleanupTUNResidual`
  - `MihomoClient.swift` / `KernelManager.swift`
- `Sources/Helper/main.swift`：特权 Helper 入口、客户端鉴权、`routesLock` 保护的路由状态
- `Sources/UI/`：SwiftUI 页面；`DesignTokens.swift` 是设计系统真相源；侧栏「网络拓扑」对应 `UI/SDWAN/SdwanPage.swift`
- `Sources/Core/RuleValidator/`、`Sources/Core/YamlEditor/`：规则编辑与行扫描 YAML
- `Resources/Panels/zashboard/dist/`：内置 Zashboard
- `Docs/GatewayGuide.md`：局域网网关文档
- `Scripts/build-debug.sh`：Debug 构建并**嵌入 Helper**（纯 `xcodebuild` Debug 不会带 Helper）
- `make.sh`：本地 Release 打包主脚本（会自增 build、构建 Helper/App、内置资源、ad-hoc 签名、生成 DMG）
- `.githooks/pre-commit`：secret 扫描 + UI 设计系统漂移警告

## 构建与验证

```bash
xcodebuild -project ClashHalo.xcodeproj -scheme ClashHalo -configuration Debug build
xcodebuild -project ClashHalo.xcodeproj -scheme ClashHalo -configuration Release -derivedDataPath .build clean build
bash make.sh
```

注意：

- 不要用 `make.sh` 做普通验证；它会改 `CURRENT_PROJECT_VERSION`，可能拉 mihomo，并把 DMG 拷到 `~/Desktop`
- 没有 XCTest target，但有纯逻辑回归套件（见下）；核心逻辑至少 Debug build，涉及 Helper/TUN/打包再跑 Release
- 除非任务明确要求，不要安装/卸载 Helper，不要打开 TUN，不要改本机系统代理/DNS/LaunchDaemon

### 回归测试

```bash
bash Scripts/run-tests.sh                # 13 套全跑，末尾出矩阵
bash Scripts/run-tests.sh --only tun     # 只跑名字含 tun 的
bash Scripts/restore-tests.sh            # 套件文件缺失时物化
```

原则是**直接编译生产源码**，绝不在测试里重新实现一遍规则——复刻逻辑只会让产品坏掉时测试照样通过。每套是一个独立可执行的 `Tests/<名>/main.swift`，用 `swiftc -O` 连同它要钉住的那几个 `Sources/` 文件编成二进制运行。

- 退出码：全绿 0，任何 FAIL / COMPILE-ERROR / 缺文件都是 1。**一套红了不会中止其余**（旧版 `set -e` 一红全断，"跑过回归"实际只覆盖了排在最前面那套）。
- `Tests/` **不在版本管理里**（`.gitignore`，自 `291a239` 起移出），新克隆的仓库必须先 `restore-tests.sh` 才能跑回归；脚本会明确列出哪些套件连历史里都取不到、只存在于写它的那台机器上。
- 新增可测的纯逻辑半边（无 UI、无进程管理、无 MainActor）时，**必须**在 `Scripts/run-tests.sh` 里 `add_suite` 登记一条：未登记的套件等于不存在的套件。`TUNLoopSentinel` 就长期漏登记、从未被跑过。
- 断言不得依赖开发机的实时状态（网卡、网段、路由、已装应用）。`RouteGuard` 里那条「识别出 en0 的 10.1.1.0/24」曾让整套测试在换网络后必红——测的是笔记本，不是产品。

## 运行时数据与系统影响

运行时写入：

- `~/Library/Application Support/ClashHalo/config.yaml`
- `~/Library/Application Support/ClashHalo/profiles/`
- `~/Library/Application Support/ClashHalo/bin/mihomo`
- `~/Library/Application Support/ClashHalo/kernels/`

特权安装：

- `/Library/LaunchDaemons/com.clashhalo.helper.plist`
- `/Library/PrivilegedHelperTools/com.clashhalo.helper`
- `/Library/Logs/ClashHalo/`

退出清理在 `AppDelegate.performCleanup()`：`killall -9 mihomo`、必要时恢复 DNS、清系统代理。这里改动必须非常克制，避免退出后断网。

## 架构约定

- `AppModel` 是 `@MainActor`；UI 状态更新留在主 actor
- `AppModel.swift` 只放共享状态与生命周期；新业务优先进现有扩展文件
- 用户触发的长耗时内核操作走 `withEngineBusy` / `engine.isBusy` 串行化
- **自动 teardown 例外**：`verifyTUNConfig` 与 `refreshConfigs` 的 TUN 自愈路径必须**手工**持有 `engine.isBusy` + `tunAutoTeardownInFlight`，并用 `defer` 单点复位；不要用 `withEngineBusy`（fire-and-forget 会在 teardown 完成前过早放行用户 toggle）
- 任何 `engine.isBusy = true` 后的 `await` 路径都必须 `defer { engine.isBusy = false }`，防止 `CancellationError` 把锁永久卡死（见 `handleNetworkChange`）
- `MihomoClient.applyController(fromConfigAt:)` 从当前 `config.yaml` 发现 controller；不要硬编码 `127.0.0.1:9092`
- 配置编辑大量使用轻量行扫描，不是完整 YAML parser。改动时保持 `EngineControl.readConfigFile`、`proxyProviders`、`ConfigStore.preview`、`YamlRuleASTEngine` 行为一致
- `ConfigStore` 把订阅 URL 存 Keychain，manifest 会清空 URL。禁止把真实订阅/节点/token 写进仓库

## 性能 / 动效 / 反馈约定

- 动效常量走 `DS.Motion`（`press` / `toast` / `micro` / `toastHold`）；禁止页面内魔法数 duration；禁止装饰性 `repeatForever`
- 路由与 `DSSegmentedControl` 不加自定义大动画 / 弹簧滑块（见 `Docs/design.md` §10 / §6.8）
- Toast 唯一通道：`showToast(_:kind:)`；单条替换 + dismiss Task 取消，防止连弹被旧 timer 清掉
- 主窗口 toast 在 detail overlay；菜单栏顶栏副标题行复用 `AppModel.toast`（主窗口不可见时仍可见）
- `engine.isBusy` 必须可感知：主开关 Toggle busy 时 disabled；不要只靠 toast 解释
- Progress：表单用 `.small`；密集 chrome 用 `.mini` + `DS.Progress.miniScale`
- 前台轮询分层：`refreshConfigs` 事件驱动 + 60s 慢兜底；网关设备 `/connections` 3s（网关设备列表在屏时 1s）；连接页 WebSocket + 5s 兜底 Timer；后台 30s；**禁止** DnsPage 等再起独立连接轮询
- 高频 `@Published` 写入前做等值短路（`mode` / `tunOn` / totals / `gatewayDevices` / `dash` / `activeConnectionsCount` / `closedConns` / `rules` / `version`）
- **App 内存警卫唯一入口是 `enforceAppMemoryGuard()`**（`AppModel+Connections.swift`）：软档 260MB / 硬档 380MB（RSS 口径，按实测 146MB 空载稳态 + 235MB 系统代理峰值校准），内部 15s 限频，徒劳退避（连续 3 次无效即暂停），启动 30s 宽限窗（突发期只观察不裁剪，启动完成时打 RSS 采样日志）。**新增任何连接快照消费方都必须调它**。禁止再写第二份内联阈值判断
- **内核内存看板口径统一用真实 RSS**（`KernelRSS.swift`：`ps` 按可执行路径精确匹配，因为 `proc_pid_rusage` 跨 uid 读 root 内核是 EPERM）。mihomo 的 `/memory` 与 `/connections` 的 `memory` 字段是**同一个值 = Go 堆 inuse**（2026-09-28 同刻三方对拍：`/memory` == `/connections.memory` == `ps` RSS == 273.2 MiB，零差）。它不是假数字，但**在 macOS 内存压缩时会高于常驻**（9-16 实测 Go 堆 363MB 而常驻仅 148MB）。选 RSS 的理由是：看门狗的动作只能影响常驻量，且与活动监视器同口径。内核不可测（重启窗口 `ps` 查不到）时只更新显示、**不进看门狗**，否则 0 会被判成一次有效下降并吞掉待结算判定、打出假日志
- **静默连接判死阈值只写在 `StaleConnectionWatch`**（armed 2h / 绝对 12h，TCP only），**分级只写在 `KernelMemoryGuardPolicy`**（380MB 回收 / 500MB 加清缓存 / 徒劳 3 次暂停）。阈值必须定在**实测地板之上**：TUN 开启的全新内核实测 316~330MB 平稳，首版 320MB 定在地板之下（那是拿 9-16 的 TUN 关闭态 145MB 标定的），结果每次开机空转三轮后暂停、要到 394MB 才重新武装——早期累积阶段恰好最不可用。看门狗**不做自动重启内核**：那是唯一用户会感觉到的动作，兜不住时提示人工处理。2026-09-28 事故：六天待机攒出 1039 条 TCP 尸体（合计只走 1.2MB）撑到 RSS 426MB，根因是设置页「禁用 Keep-Alive」被开（`disable-keep-alive: true`，用户开关不是订阅默认）+ mihomo 对代理 TCP 无空闲超时 + App 从不按年龄回收
- 连接热路径（`onConnections` / `recordHistoryOnly` / `fetchConnectionsSnapshot` 解码）必须包 `autoreleasepool`；`cachedConns` 走 `clampConnectionCaches()` 上限，截断前先按速率排序且 `activeConnectionsCount` 先赋值（计数不受截断影响）
- 流量 sparkline series 仅在 `route == dashboard` 或菜单栏可见时追加；默认 `trafficRefreshInterval = 2s`
- **内核下载/检查必须直连**：`KernelManager` 使用 `connectionProxyDictionary = [:]` 的 ephemeral session，禁止经系统代理访问 GitHub
- **内核切换顺序**：下载解压暂存 → 临时关系统代理 → `stopKernel`（`callStopMihomo` 硬超时）→ 换 bin → 启动 → `waitForKernelReady` → 成功才恢复代理；禁止先停核再下载
- **单一身份内核（v1.1.7）**：Helper 可用时内核**一律以 root 启动**（启动、系统代理、TUN 同一身份）。混用 root/用户态会把数据目录属主撕裂——root 会话留下 `cache.db` / `providers/` / `ruleset/` / `ui/` 归 root（0755），之后用户态内核只能读不能写，导致 `store-selected`、`geo-auto-update`、订阅与规则集刷新**静默失效**
- **启动身份 ≠ 升级重启**：`ensureRunningAsync(preferRoot:allowRootUpgradeRestart:)` 把两者拆开。**冷启动**可以直接以 root 起（廉价）；**把运行中的用户态内核重启成 root** 很贵（全量重载），只有 TUN/网关传 `true`，系统代理传 `false`（它只需 mixed-port，这正是 v1.1.4 修过的「开关卡死」）

## Helper / TUN 高风险边界

涉及这些文件时做小步、可解释改动：

- `Sources/XPC/XPCManager.swift`
- `Sources/XPC/EngineControl.swift`
- `Sources/XPC/ProxyManager.swift`
- `Sources/XPC/HelperProtocol.swift`
- `Sources/Helper/main.swift`
- `Sources/Model/Models.swift`（`NetScanner`）
- `Sources/Model/AppModel.swift` / `AppModel+Config.swift`（自愈与并发）

必须保留的安全与路由规则：

- Helper 只接受 ClashHalo `.app` 客户端；旧 ClashPow 路径仅迁移兼容
- root 启动 mihomo 只允许 canonical kernel path
- `installDaemon()` 生成 LaunchDaemon plist；不要再维护第二份打包时 plist 真相源
- **安装/升级前必须校验 App 内 Helper 源二进制**；`set -e` + stage→bootout→mv，禁止 `cp` 失败后仍 `bootout` 旧服务
- `checkStatus()` 同时要求 plist **与** `/Library/PrivilegedHelperTools/com.clashhalo.helper` 存在；仅 plist 不算已安装
- 升级走原地替换（单次管理员授权），不要再「先卸载再安装」两次密码
- `runAdmin(_:prompt:)` 在系统密码框前展示中文说明；取消说明框不得提权
- `mihomo` 签名不要随意 hardened runtime；会影响 TUN/utun
- TUN 是运行时能力：启动时强制 `tun.enable: false`，只应通过 UI/Helper 流程开启
- **网关开关是用户意图**（`UserDefaults` 镜像 `net.gatewayModeOn`），禁止从 config 残留签名推断开启；开关关时清理残留 `dns.listen: 0.0.0.0:53`
- **系统 DNS 重定向的记账唯一属主是 `TunnelDNSLedger`**：合法写点有两个属主——TUN（fake-ip 网关 198.18.x，pin 服务）与代理 redir-host 模式（127.0.0.1，独立账本）；**fake-ip 下代理模式禁止写系统 DNS**（fake-ip 应答会把不走代理的应用解析到不可路由的 198.18.x 假地址直接断网；`ensureProxyDNS` 的跳过守卫必须保留），此时域名防污染由 sniffer（parse-pure-ip）承担。写入/清账一律走 Ledger API（`redirect` / `restore` / `restoreAll`），禁止直接读写 `kDNS*Key`——共享账本正是 2026-10-14 断网事故的高-1/高-2 根因；快照只在读取成功时落盘（`currentSystemDNS` 三态，nil ≠ Empty），恢复写确认成功才清账，退出路径超时/失败保留账本交下次启动续修
- **系统级网络状态的写点必须自证安全前提**：写 DNS/系统代理/路由/转发前，在写入函数内部断言使该写入成立的事实（fake-ip 网关接口存在、目标端口在监听、状态属主归我），不要只依赖上游调用方的门——门会回归。同理，修复「被下游 bug 掩盖的机制」时必须先审它的设计意图在放行后是否本身有害（归属修复让 fake-ip DNS 重定向驻留进而断网即此类）；全局状态尽量单一属主（如系统 DNS 重定向只归 TUN、bypass 只归 `kProxyBypassDomains`）
- Helper 版本唯一来源是 `kSharedHelperVersion`（`HelperProtocol.swift`），并同步 `Helper-Info.plist` 的 `CFBundleVersion`。需要强制升级旧 Helper 时才 bump
- 系统代理 bypass 唯一来源是 `kProxyBypassDomains`（约 86 条：localhost/mDNS/RFC1918/link-local/CGNAT）。Helper、本地 fallback、`reconcileProxyBypassIfNeeded`、网络拓扑视图都只引用它
- bypass 自愈在 GUI 进程本地写 `networksetup`，不要再经可能过时的 Helper 覆盖

### TUN 自愈链路（v1.0.7 → v1.0.15 → v1.3.4）

判定与清理是分层的，改一处必须想整条链：

1. **识别 mihomo TUN**：`NetScanner.mihomoTunInterface()` 用 `198.18.x.x` 找 `proxyTun` 候选
2. **多候选**：路由表所有权仲裁（`allRoutes()`），选被路由引用的活接口；判 zombie 则走接口丢失自愈
3. **单候选**：保守双判据才判 zombie——`isUp == false` **且** `route -n get 198.18.0.1` 目标接口不是该 utun；否则信任返回（宁可漏关一拍，不误关健康 TUN）
4. **活跃判定三重校验**：配置开启 + root 运行 + 接口真实存在
5. **逻辑关闭**：`refreshConfigs`（约 3s）与 `verifyTUNConfig`（约 30s）两条 auto-teardown 持 `isBusy` + `tunAutoTeardownInFlight`，调用 `applyTUNState(false)` 并恢复 DNS
6. **物理清理兜底**：逻辑关闭后若 `hasDownedMihomoTun()`（`proxyTun && !isUp`）为真，经 XPC 调 `cleanupTUNResidual`（`ifconfig down` + 删 IP + route flush）。门控避免误清仍 UP 的同址段 VPN（如 Shadowrocket）
7. **旧 Helper 共存**：无 `cleanupTUNResidual` 时新鲜连接超时返回 nil，只记日志、不误操作
8. **僵尸巡检（v1.3.4）**：上述防线全部门控在 `tunOn` 上，对「配置关但接口仍 UP 且持路由」失明（2026-09-16 幽灵流量事故）。`sweepZombieTUN` 挂在**前台与后台两条健康巡检**上、首行 `guard !tunOn` 反向门控，判据 `NetScanner.upDetachedMihomoTun()` 严格身份化——只认 pin 住的 `kPinnedTunDevice` 设备名，宁漏不误伤共存 VPN；两击确认 → `healDetachedTUN`（重启内核优先，复用「重启内核」安全时序；仍残留才升级特权清理；3 次熔断 + 冷却，防重启循环）
9. **自循环哨兵（v1.3.4）**：僵尸态的内核 DIRECT 出网会回注同一隧道，单连接下行以链路速率膨胀而物理网卡零流量。`TUNLoopSentinel`（纯状态机）喂自 `recordHistoryOnly` 热路径：DIRECT 链 + 上行静默 + 每拍 ≥25MB + 连续 6 拍才候选，`handleTUNLoopTrip` 再过 `route -n get` 目的地取证（回指隧道才定罪，排除 LAN 直连大流）；按 `tunOn` 意图分派数据面重建或僵尸自愈。新增消费连接快照的热路径必须同步喂哨兵并在快照末尾 `reap`

### TUN 数据面探针（v1.1.12 → v1.1.13）

「接口存在」不等于「数据面活着」：`configd` 在 mihomo 底下重挂 `utun100` 后，接口表与路由表都正常，mihomo 却握着失效 fd。纯逻辑部分在 `Sources/Model/TUNDataPlaneProbe.swift`（无 UI、无进程管理、无 MainActor）：

1. **`DNSProbe`**：向 fake-ip 网关（默认 `198.18.0.1:53`）发最小 UDP DNS 查询，校验 transaction ID / 长度 / QR 位 / RCODE，**只认 NOERROR 算活着**——旧规则「NXDOMAIN/SERVFAIL 格式有效即活」已被真实事故推翻：SERVFAIL 意味着查询到达 mihomo 但解析失败，是断网签名不是健康签名（旧规则让探针在 DNS 全黑洞期间连报 1400 轮假绿灯）。探测主机名选在 fake-ip filter 覆盖内（非 `.local`），健康路径必回 NOERROR；NXDOMAIN 也不接受，防止被规则黑洞的探测主机重新打开同一漏洞
2. **`TUNDataPlaneHealthState` 是滑动窗口，不是连续失败计数**：保留最近 `window`（默认 6）次结果，窗口内失败数达到 `failThreshold`（默认 4）触发自愈。**一次成功不清空窗口**——半死 fd 恰恰是「大部分失败、偶尔成功」，连续计数在这种形态下永远不触发（v1.1.12 的实际漏洞）。**交替形态补触发（2026-10-14）**：严格 F/S 交替会让失败数永远停在 threshold-1，补条件「满窗 + 失败数==threshold-1 + 本条失败 + 闩锁未置位」同一窗口只触发一次，闩锁随 `reset()` 解除
3. **一轮内每次尝试都要记入窗口**：`runTUNDataPlaneProbe` 不得一遇成功就 break；`runTUNDataPlaneProbeCycle` 默认 5 次，只在**首次尝试即刻应答**时短路
4. **调度是合并制、禁止 cancel+重建（2026-10-14）**：`scheduleTUNDataPlaneProbe` 对已在排任务取触发时刻 min(既有, now+delay)——高频事件只能拉早探针、永远推不晚（cancel+重建在事件风暴下会把探针饿死且完全静默）；距上次实际执行超过 2×delay 强制立即排程兜底
5. **`reset()` 只在 `allHealthy`（满窗口全成功）后调用**，别让一次侥幸成功抹掉判定
6. **自愈是整进程重建**，不是 `PATCH tun off/on`——PATCH 不保证重开失效 fd；二次验收仍失败则关 TUN 回退直连，不动用户原本开启的系统代理

### 网络拓扑 / 静态路由绕行

系统存在其他非 `proxyTun` 活跃 `utun`（如 Tailscale）时，`refreshConfigs()` 对齐注入状态，经 Helper 执行 `/sbin/route -n add` 静态路由指回原虚拟接口。关闭 TUN 或客户端 invalidated 时，Helper 必须通过 `addedRoutes` 清空注入路由。

## UI 约定

规范：`Docs/design.md`。实现真相源：`Sources/UI/DesignTokens.swift` + 共享组件（`PageHead` / `Card` / `ContentUnavailable`）。

- 颜色/间距/圆角/图标一律走 `DS.Palette`、`DS.Spacing`、`DS.Radius`、`DS.Icon`、`Font.ds*`
- 品牌 accent：PANTONE Medium Purple U（`#65428A`）；数据可视化用 `upload`/`download`/`info`/`error`，**不要**把图表系列绑到 brand accent
- 表面层级：`windowBg` / `sidebarBg` / `cardBg` / `controlBg` / `chromeBg`；卡片用 `dsCardChrome()`（Light 细阴影，Dark 靠抬升色）
- 主题跟随系统 Appearance，完整 Light/Dark；禁止页面级 `preferredColorScheme`
- 侧栏：自绘导航（不用 `List(.sidebar)`）；图标一律 outline + `monochrome` + 固定 `lg` 槽；导航与 footer 共用 `pageContentInset` + 同结构图标列
- 网络拓扑角色色用 `rolePhysical` / `roleTailscale` / `roleZerotier` / `roleOray` / `roleOther`（`proxyTun` 用 `accent`）
- 复用 `PageHead`、`Card`、form rows；工具型密度，避免营销式 hero
- pre-commit 会警告 raw `.font(.system(size: N))` 与字体阶梯漂移

## 版本与发布

改版本时一起核对：

- `ClashHalo.xcodeproj`：`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
- `Sources/Info.plist`：`CFBundleShortVersionString` 和 `CFBundleVersion` 必须使用 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` 变量，**禁止硬编码版本号**——增量构建时 Xcode 不会重新处理 Info.plist，硬编码值会覆盖 build settings 导致打包产物版本号与源码不一致
- `Sources/XPC/HelperProtocol.swift`：`kSharedHelperVersion`（仅在 Helper 协议/行为需要强制升级时 bump）
- `Helper-Info.plist`：`CFBundleVersion`
- `CHANGELOG.md`、`README.md`、`AGENTS.md`（版本号必须同步）

打包：

- `make.sh`：本地真实打包主路径。**打包后 `make.sh` 会自动验证 App 内部版本号**：读取打包产物的 `CFBundleShortVersionString` / `CFBundleVersion` 与 `pbxproj` 中的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 比对，不一致则 `exit 1` 并提示 clean build。**不要跳过这个检查**
- `Scripts/package.sh` / `Scripts/notarize.sh`：外部证书与环境变量
- `make-dmg.sh`：DMG 外观脚本，依赖 `.dmg-temp` 与 Finder/AppleScript

### 发布检查清单

发布到 GitHub Release 前，**必须**逐项验证：

1. App 内部版本号：`/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' <App>/Contents/Info.plist` 必须与 `MARKETING_VERSION` 一致
2. DMG 内嵌的 App：`hdiutil attach <DMG> && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Volumes/ClashHalo*/ClashHalo.app/Contents/Info.plist` 必须与 Release 标签一致
3. DMG 文件名中的版本号必须与 App 内部版本号一致
4. `make.sh` 输出末尾必须显示 `Version: x.y.z (N) ✓`，不得有 `❌ VERSION MISMATCH`

## 安全与隐私

- 不提交真实代理节点、订阅 URL、API token、账号密码、私钥
- pre-commit 命中 secret/UUID/私钥时不要绕过，先改成示例值
- 日志和用户提示可用中文，保持现有风格

## 修改建议

开始前：

1. `rg --files` / `rg` 定位相关文件
2. 先读现有实现，再按分层落改动
3. 检查是否触及系统代理、DNS、LaunchDaemon、root mihomo、用户配置、路由表

完成前：

1. 跑适当的 `xcodebuild` 验证
2. 改 UI 时确认仍用设计令牌，并检查 light/dark 两端
3. 改配置热加载 / TUN / Gateway / bypass / Helper 协议时，写清验证范围与未实际操作的系统级步骤
4. 改动聚焦；不做无关重命名、格式化或大规模重构
5. 若改 XPC 协议，评估是否需要 bump `kSharedHelperVersion`，以及新旧 Helper 共存行为
