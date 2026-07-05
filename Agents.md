# Agents.md

本文件给后续 AI 编码代理使用。进入本仓库后，先读本文件，再按需读 `README.md`、`CHANGELOG.md` 和相关源码。

## 项目概览

这是一个 macOS 14+ 原生 SwiftUI 代理客户端，项目名、Bundle ID、数据目录、Helper 服务和用户可见品牌统一为 **ClashHalo**。旧版 `ClashPow` 只应出现在迁移或清理兼容代码中。

应用直接编排官方 `mihomo` 内核：

- GUI 层：SwiftUI、AppKit、Combine，入口在 `Sources/App/ClashHaloApp.swift`。
- 状态层：`AppModel` 是中心状态和生命周期编排器，扩展文件按领域拆分。
- 内核/API 层：`EngineControl` 管理内核进程、配置文件和 TUN/root 切换；`MihomoClient` 调用 mihomo REST/WebSocket API。
- 特权层：`XPCManager` 与 `Sources/Helper/main.swift` 的 privileged helper 通信，处理系统代理、root 启动 mihomo、网关转发。

项目没有 Swift Package manifest，主要通过 `ClashHalo.xcodeproj` 构建。

## 关键路径

- `Sources/App/`：App 入口、窗口、菜单栏、主路由。
- `Sources/Model/`：核心状态、配置/订阅、连接和代理业务逻辑。
- `Sources/XPC/`：mihomo API、内核控制、Helper XPC、系统代理实现。
- `Sources/Helper/main.swift`：特权 Helper 服务入口和安全校验。
- `Sources/UI/`：SwiftUI 页面与共享组件。
- `Sources/UI/DesignTokens.swift`：设计系统，UI 颜色、字体、间距、圆角应优先从这里取。
- `Sources/Core/RuleValidator/`：规则编辑/校验逻辑。
- `Sources/Core/YamlEditor/`：基于行扫描的 YAML 规则提取/编辑能力。
- `Resources/Panels/zashboard/dist/`：内置 Zashboard 静态资源。
- `Docs/GatewayGuide.md`：局域网网关使用文档。
- `make.sh`：本地 Release 打包主脚本，会自增 build number、构建 Helper/App、内置资源、ad-hoc 签名并生成 DMG。
- `.githooks/pre-commit`：提交前扫描 secret 和 UI 设计系统漂移。

## 构建与验证

常用命令：

```bash
xcodebuild -project ClashHalo.xcodeproj -scheme ClashHalo -configuration Debug build
xcodebuild -project ClashHalo.xcodeproj -scheme ClashHalo -configuration Release -derivedDataPath .build clean build
bash make.sh
```

注意：

- `bash make.sh` 会修改 `ClashHalo.xcodeproj/project.pbxproj` 中的 `CURRENT_PROJECT_VERSION`，不要在普通验证时随手运行。
- `make.sh` 可能访问 GitHub 下载 mihomo，并会把 DMG 复制到 `~/Desktop`。在受限网络或不需要打包时，用 `xcodebuild` 验证即可。
- 项目当前没有专门的 XCTest target。修改核心逻辑后至少跑一次 Debug build；涉及打包、Helper 或 TUN 时再跑 Release/打包流程。
- 运行 App 或安装 Helper 会影响本机系统代理、DNS、LaunchDaemon 和 mihomo 进程。除非任务要求，不要主动安装/卸载 Helper 或打开 TUN。

## 运行时数据与系统影响

应用运行时主要写入：

- `~/Library/Application Support/ClashHalo/config.yaml`
- `~/Library/Application Support/ClashHalo/profiles/`
- `~/Library/Application Support/ClashHalo/bin/mihomo`
- `~/Library/Application Support/ClashHalo/kernels/`

特权安装会涉及：

- `/Library/LaunchDaemons/com.clashhalo.helper.plist`
- `/Library/PrivilegedHelperTools/com.clashhalo.helper`
- `/Library/Logs/ClashHalo/`

退出清理逻辑在 `AppDelegate.performCleanup()`：会 `killall -9 mihomo`、恢复 DNS、清除系统代理。修改这里要非常谨慎，避免用户退出后断网。

## 架构约定

- `AppModel` 标注 `@MainActor`，UI 状态更新应留在主 actor。
- `AppModel.swift` 只放共享状态和生命周期；新业务优先放入已有扩展文件：
  - `AppModel+Config.swift`
  - `AppModel+Proxies.swift`
  - `AppModel+Connections.swift`
- 长耗时内核操作必须通过 `engine.isBusy` 或 `withEngineBusy` 串行化，避免 TUN、重启、配置热加载互相交错。
- `MihomoClient.applyController(fromConfigAt:)` 会从当前 `config.yaml` 发现 controller host/port/secret；配置切换后不要硬编码 `127.0.0.1:9092`。
- 配置编辑大量使用轻量行扫描而不是完整 YAML parser。改动时要保持 `EngineControl.readConfigFile`、`proxyProviders`、`ConfigStore.preview`、`YamlRuleASTEngine` 的行为一致。
- `ConfigStore` 将订阅 URL 存 Keychain，manifest 中会清空 URL。不要把真实订阅、节点、token 写进仓库。

## Helper / TUN 高风险边界

涉及以下文件时，优先做小步、可解释的改动：

- `Sources/XPC/XPCManager.swift`
- `Sources/XPC/EngineControl.swift`
- `Sources/XPC/ProxyManager.swift`
- `Sources/XPC/HelperProtocol.swift`
- `Sources/Helper/main.swift`

必须保留的安全属性：

- Helper 只接受 ClashHalo `.app` 客户端连接；旧 ClashPow 路径只作为迁移兼容保留。
- root 启动 mihomo 时只允许 canonical kernel path。
- `installDaemon()` 生成 LaunchDaemon plist；不要再维护另一个打包时 plist 作为第二真相源。
- `mihomo` 签名不要随意改成 hardened runtime；当前脚本特意避免影响 TUN/utun。
- TUN 是运行时能力，启动时会强制 `tun.enable: false`，只应通过 UI/Helper 流程开启。

## UI 约定

- 优先使用 `DS.Palette`、`DS.Spacing`、`DS.Radius`、`DS.Icon` 和 `Font.ds*`。
- 新页面尽量复用 `PageHead`、`Card` 等现有组件。
- 当前主窗口强制 dark scheme。不要只为单个页面临时引入浅色专用颜色。
- `.githooks/pre-commit` 会警告 UI 中重新引入 raw `.font(.system(size: N))` 或偏离字体阶梯的 semantic font。
- 这是工具型桌面应用，界面应密集、稳定、便于扫描；避免营销页式 hero、装饰性大卡片或与既有风格不一致的视觉重做。

## 打包与发布注意事项

- `make.sh` 是当前更贴近实际的本地打包脚本，产物名使用 ClashHalo。
- `Scripts/package.sh` / `Scripts/notarize.sh` 是通用签名和 notarize 脚本，依赖外部证书和环境变量。
- `make-dmg.sh` 依赖 `.dmg-temp` 目录和 Finder/AppleScript，更多是 DMG 外观处理脚本。
- README 中版本号、CHANGELOG 和 Xcode 工程中的 `MARKETING_VERSION` 可能需要同步，改版本时一起检查。

## 安全与隐私

- 不要提交真实代理节点、订阅 URL、API token、账号密码或私钥。
- `.githooks/pre-commit` 会阻止明显 secret、UUID、私钥等内容；如果命中，不要简单绕过，先确认是否应改成示例值。
- 日志和用户提示可用中文，保持现有风格。

## 修改建议

开始任务前：

1. 用 `rg --files` 和 `rg` 定位相关文件。
2. 先读现有实现，再按当前分层放置改动。
3. 检查是否触及系统代理、DNS、LaunchDaemon、root mihomo 或用户配置文件。

完成任务前：

1. 跑适当的 `xcodebuild` 验证。
2. 若改 UI，检查是否仍使用设计令牌。
3. 若改配置热加载/TUN/Gateway，说明验证范围和未实际操作的系统级步骤。
4. 保持改动聚焦，不做无关重命名、格式化或大规模重构。
