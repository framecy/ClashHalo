# Agents.md

本文件给后续 AI 编码代理使用。进入本仓库后，先读本文件，再按需读 `README.md`、`CHANGELOG.md` 和相关源码。

当前主干：`main`，产品版本 **v1.1.6**（`MARKETING_VERSION`），Helper **1.0.19**（`kSharedHelperVersion`：startMihomo 去固定 sleep 改条件轮询；相对 1.0.18 及更早需强制升级）。打包时 `make.sh` 自增 `CURRENT_PROJECT_VERSION`。

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
  - `ConfigStore.swift`：订阅 manifest；URL 存 Keychain
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
- 没有 XCTest target；核心逻辑至少 Debug build；涉及 Helper/TUN/打包再跑 Release
- 除非任务明确要求，不要安装/卸载 Helper，不要打开 TUN，不要改本机系统代理/DNS/LaunchDaemon

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
- 前台轮询分层：`refreshConfigs` 约 12s；网关设备 `/connections` 3s；连接页 1.5s；后台 30s；**禁止** DnsPage 等再起独立连接轮询
- 高频 `@Published` 写入前做等值短路（`mode` / `tunOn` / totals / `gatewayDevices` / `dash`）
- 流量 sparkline series 仅在 `route == dashboard` 或菜单栏可见时追加；默认 `trafficRefreshInterval = 2s`
- **内核下载/检查必须直连**：`KernelManager` 使用 `connectionProxyDictionary = [:]` 的 ephemeral session，禁止经系统代理访问 GitHub
- **内核切换顺序**：下载解压暂存 → 临时关系统代理 → `stopKernel`（`callStopMihomo` 硬超时）→ 换 bin → 启动 → `waitForKernelReady` → 成功才恢复代理；禁止先停核再下载
- **系统代理启核**：`ensureRunningAsync(preferRoot: false)`，勿为 mixed-port 强制 root 重启

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
- Helper 版本唯一来源是 `kSharedHelperVersion`（`HelperProtocol.swift`），并同步 `Helper-Info.plist` 的 `CFBundleVersion`。需要强制升级旧 Helper 时才 bump
- 系统代理 bypass 唯一来源是 `kProxyBypassDomains`（约 86 条：localhost/mDNS/RFC1918/link-local/CGNAT）。Helper、本地 fallback、`reconcileProxyBypassIfNeeded`、网络拓扑视图都只引用它
- bypass 自愈在 GUI 进程本地写 `networksetup`，不要再经可能过时的 Helper 覆盖

### TUN 自愈链路（v1.0.7 → v1.0.15）

判定与清理是分层的，改一处必须想整条链：

1. **识别 mihomo TUN**：`NetScanner.mihomoTunInterface()` 用 `198.18.x.x` 找 `proxyTun` 候选
2. **多候选**：路由表所有权仲裁（`allRoutes()`），选被路由引用的活接口；判 zombie 则走接口丢失自愈
3. **单候选**：保守双判据才判 zombie——`isUp == false` **且** `route -n get 198.18.0.1` 目标接口不是该 utun；否则信任返回（宁可漏关一拍，不误关健康 TUN）
4. **活跃判定三重校验**：配置开启 + root 运行 + 接口真实存在
5. **逻辑关闭**：`refreshConfigs`（约 3s）与 `verifyTUNConfig`（约 30s）两条 auto-teardown 持 `isBusy` + `tunAutoTeardownInFlight`，调用 `applyTUNState(false)` 并恢复 DNS
6. **物理清理兜底**：逻辑关闭后若 `hasDownedMihomoTun()`（`proxyTun && !isUp`）为真，经 XPC 调 `cleanupTUNResidual`（`ifconfig down` + 删 IP + route flush）。门控避免误清仍 UP 的同址段 VPN（如 Shadowrocket）
7. **旧 Helper 共存**：无 `cleanupTUNResidual` 时新鲜连接超时返回 nil，只记日志、不误操作

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
- `Sources/XPC/HelperProtocol.swift`：`kSharedHelperVersion`（仅在 Helper 协议/行为需要强制升级时 bump）
- `Helper-Info.plist`：`CFBundleVersion`
- `CHANGELOG.md`、`README.md`（README 版本号可能滞后，改发版时同步）

打包：

- `make.sh`：本地真实打包主路径
- `Scripts/package.sh` / `Scripts/notarize.sh`：外部证书与环境变量
- `make-dmg.sh`：DMG 外观脚本，依赖 `.dmg-temp` 与 Finder/AppleScript

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
