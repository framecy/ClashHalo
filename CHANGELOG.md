# Changelog

本项目所有重要变更记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/),版本遵循语义化版本。

## [0.4.4] - 2026-06-05

并发安全:内核操作互斥 + TUN 升级时序竞争修复(功能冲突审查批次)。

### Fixed
- **TUN 升级 helper 时 `isRoot` 时序竞争**:`toggleTUN` 的 `upgradeDaemon` 分支经 XPCManager 直接升级,不设 `engine.isRoot`;升级走 osascript 授权(>2s)期间 `pollStatus`(2s) 在 helper 卸载瞬间把 `isRoot` 置 false,紧接的 `restart`→`ensureRunning` 据此**误以用户态启动内核** → TUN 无法创建 utun。修复:升级确认连通后显式 `engine.isRoot = true`,消除对 pollStatus 异步同步的依赖。

### Added
- **内核操作互斥锁**(`EngineControl.isBusy`):`toggleTUN` / `toggleEngine` / 重启内核 / 切换内核 四个入口在操作进行中互斥,防止长流程(TUN root 切换含多个 await)与另一次启停/切换交错产生竞争。

## [0.4.3] - 2026-06-05

核心稳定性与错误反馈修复:解决"配置错误被误报为权限不足"等一系列误导性故障。

### Fixed
- **配置错误被误报为「权限不足」**:编辑 yaml 引入错误(如 proxy-group 用 `proxies:` 引用了应当用 `use:` 的 provider)使 mihomo 加载失败时,app 笼统报"核心启动超时或权限不足",误导用户去反复重装 helper。新增 `EngineControl.validateConfig()`(跑 `mihomo -t`),启动失败时显示**真实配置错误**;`reloadConfig` 检查 HTTP 响应并抛出 mihomo 的错误消息(`MihomoError.reload`),编辑/切换配置失败时如实反馈。
- **核心停止后 TUN 开关卡在 on**:`reconnect` 与 `toggleEngine` 在核心不可达/停止时复位 `tunOn`,消除状态不一致。
- **系统代理状态不同步**(#4):启动/重连时用 `SCDynamicStoreCopyProxies` 读真实系统代理状态同步开关(GUI 侧内联,无需 root)。
- **手动停核心不清系统代理 → 断网**(#2):停核心后若系统代理开启则一并关闭。
- **停核心 XPC fire-and-forget**(#3):改用 `await engine.stopKernel()` 正确等待 XPC + killall。
- **Helper 进程跟踪失效**(#10):`mihomoProcess` 改 `static` + `NSLock`(NSXPCListener 每连接新建 Helper 实例导致实例变量恒 nil),`stopMihomo` 的 SIGTERM→等待→SIGKILL 现在生效。
- **TUN 升级 Helper 走错路径**(#1):改用 `XPCManager.upgradeDaemon()` 卸载旧 helper + 轮询等待新 helper 上线 + 升级失败 guard。
- **切 profile 不 harden 控制面**(#8):`activateProfile` 在 `setConfig` 前重新 `hardenControllerConfig()`,防止新 profile 暴露 `0.0.0.0` 控制面。
- **reconnect 无限递归**(#5):新增 `reconnectTask`,新重试取消旧重试。
- **ProxyManager 强制解包**(#11):`SCPreferencesCreateWithAuthorization` 改 `guard` 防崩溃。

## [0.4.2] - 2026-06-05

TUN 权限根本原因修复、Helper 自动升级机制、退出清理与网络断开保护。

### Fixed
- **TUN 无权限**（根本原因）:`make.sh` 原用 `--deep --options runtime` 对所有子二进制施加 hardened runtime，阻断了 `AF_SYSTEM` socket 创建（utun 设备）。改为对 `mihomo` 和 `helper` 单独签名（不加 `--options runtime`），仅对 `.app bundle` 施加 runtime。
- **Helper XPC 连通失败**（`isAuthorizedClient` 三层鉴权）：
  - 旧版 `SecCodeCheckValidity(flags:0)` 在部分 macOS 版本下对 ad-hoc 签名失败，导致 helper 拒绝所有来自 App 的 XPC 连接，`verifyConnectivity()` 永远超时。
  - 修复：① `kSecCSBasicValidateOnly`（跳过可执行+资源校验，只验 identifier）② `SecCodeCopyPath` bundle 根路径回退（修正了路径检查条件）③ `proc_pidpath` 直接读进程可执行路径（ad-hoc 必然通过）。
- **安装反馈误导**：移除"已安装，但连通确认超时"提示；osascript 返回 0 即为安装成功（`已安装 ✓`），连通状态由 `pollStatus()` 异步更新。
- **TUN 启动时序竞态**（`toggleTUN`）：硬编码 2s sleep 不足以等待 XPC 回调设置 `runningAsRoot`；改为最多 10s 轮询 `api.reachable && engine.runningAsRoot`。
- **App 重启后 TUN 状态显示 OFF**：`pollStatus()` 和 `ensureRunning()` 增加 `pgrep -u root -x mihomo` 同步 `runningAsRoot` 标志。

### Added
- **Helper 版本自动检测与升级**：`EngineControl.kExpectedHelperVersion`；`AppModel.start()` 启动 4s 后自动检测，版本低于预期时走 `upgradeDaemon()`（先卸载再安装）静默升级。
- **UI 版本升级提示**：「设置→权限」tab 检测到旧版 helper 时显示橙色「更新」按钮，版本行显示 `旧版 → 新版 ⚠️`。
- **Helper `upgradeDaemon()`**（`XPCManager`）：完整的 uninstall → 800ms 间隔 → install 替换流，解决 `installDaemon` 直接覆盖可能遗留旧进程问题。
- **异常退出清理**（`AppDelegate` + SIGTERM/SIGINT）：`killall -9 mihomo` + XPC `setSystemProxy(false)`；一次性 `DispatchSemaphore` 防竞争。
- **网络断开保护**（`NWPathMonitor`）：离线时自动关闭系统代理，防代理指向死内核导致断网。
- **Helper `startMihomo` 防端口占用**：启动前先 `killall -9 mihomo`，清理跨 Helper 实例遗留进程。
- **Helper `stopMihomo` 三段式退出**：SIGTERM → 1.5s 等待 → SIGKILL → killall 最终安全网。
- **日志目录权限修复**（`installDaemon`）：`chmod 755 /Library/Logs/ClashPow` 确保 helper 日志可写。

### Changed
- `make.sh` DMG 输出改为版本化命名（`ClashPow_vX.Y.Z_mac_arm.dmg`）。
- Helper 版本提升至 v1.0.5。
- `waitForHelper()` 轮询窗口扩展至 15s（30 × 500ms），静默等待。

## [0.4.1] - 2026-06-04

继 v0.4.0 的稳定性大修后,完成 Helper 交互、内核管理、功能可用性与界面的一轮打磨。

### Added
- **默认内置官方 mihomo 内核**,开箱即用;内核管理可一键切回内置内核并显示版本。
- 侧栏头部展示 App 版本号。

### Changed
- 概览页顶部三个快捷开关(系统代理/TUN/核心)移除,**统一由侧栏底部控制**,消除重复。
- Helper 安装/卸载增加 loading 态、防重复点击与失败原因提示;关于页版本号动态化、描述更新。
- 规则页改为只读展示内核真实规则,编辑引导至配置 YAML。

### Fixed
- **规则页此前不可用**:从 `/configs` 读规则恒为空、PATCH rules 被内核忽略;改为读 `/rules` 端点(实测 156 条可读)。
- 移除 DNS 页硬编码假统计(平均解析/Fake-IP 池/缓存,无数据源)。
- Helper 日志写入修复(原 fallback 覆盖整文件导致"进程在跑却无日志")。

### Removed
- 死代码清理:`ConfigEditor/Pages.swift`(2144 行)、`EngineStatusRPC`、`RuleEditSheet`、`HeadSwitch`。

### Internal
- 连接监控接入单连接断开;XPC 层(EngineControl/XPCManager)不再引用 `AppModel.shared`,改注入日志通道(降耦合);源码编译 0 警告。

## [0.4.0] - 2026-06-04

原生架构稳定性与安全大修:从严格自测出发,修复内核交互、TUN、Helper 权限三大类严重缺陷,并经 clean 端到端自愈验证。

### Added
- 内核启动前自动发现控制面地址/secret(解析 config.yaml 的 external-controller/secret)。
- 内核缺失时回退到已下载内核(kernel.json / kernels/),并给出可见错误。
- Helper 连通性主动探测(XPC getVersion 握手),取代"plist 存在即可用"的误判。
- 日志订阅级别可配置(默认 WARN),UI 可切换 DEBUG/INFO/WARN/ERROR(服务端过滤)。
- DMG 打包加入 `/Applications` 软链与 `使用说明.txt`(含 Gatekeeper 绕过指引)。

### Fixed
- **内核交互**:连接参数硬编码导致永久重连;内核二进制路径分裂导致静默不启动。
- **TUN**:切换"提示成功实际失败"——升级 root 时旧用户态内核杀不掉、永不以 root 重启;提示不反映真实生效状态。
- **Helper**:`unload -w` 持久禁用服务导致安装后永不启动(launchctl disabled override);改用 `enable` + `bootout`。
- **geox-url 死锁**:失效的 geodata 源使内核 fatal,而修正逻辑依赖 REST → 死锁;改为启动前规范化。
- **打包**:0 字节 geodata 进入产物;增量构建残留;plist 多套不一致。

### Security
- 控制面强制绑回环 `127.0.0.1`,弱 secret 替换为强随机值。
- Helper XPC 增加客户端代码签名校验(`identifier "com.clashpow.app"`)+ 内核路径白名单,封堵任意二进制以 root 执行的本地提权。
- 修正 `SMPrivilegedExecutables` 标识符不一致。

### Changed
- 源码编译警告清零(Swift 6 严格并发就绪)。
- 移除失效的 LaunchDaemon plist,收敛为安装时单一真相源。

## [0.3.1] - 2026-06-02
UI 与稳定性改进。详见 [GitHub Release](https://github.com/framecy/ClashPow/releases/tag/v0.3.1)。

## [0.3.0] - 2026-05-31
原生架构首个版本(移除自研 Go 引擎)。详见 [GitHub Release](https://github.com/framecy/ClashPow/releases/tag/v0.3.0)。
