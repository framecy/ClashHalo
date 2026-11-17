# Changelog

本项目所有重要变更记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/)，版本遵循语义化版本。

## [Unreleased]

### Added

- **支持 `.txt` + base64 编码的分享链接订阅**：`vless://` / `vmess://` / `trojan://` / `hysteria2://` / `ss://` / `tuic://` 每行一个、整体 base64 编码的订阅（大量面板/机场给的就是 `text/plain` 的 `.txt`）现在可以直接添加，App 会在写盘前把它转换成 mihomo 配置：节点进 `proxies`，同时生成 `PROXY`（select）与「自动选择」（url-test）两个组，规则为 `GEOIP,CN,DIRECT` + `MATCH,PROXY`。转换发生在**存储层**（`ConfigStore.normalizedForProfile`），四个写盘入口统一走它——本地导入、远程导入（同步/异步）、订阅刷新；任何一个漏掉都会把 base64 文本存成 profile，内核 reload 失败而用户只看到「应用订阅失败」。订阅刷新会把源内容重新转换，不会把原始 base64 覆盖回已转换的 profile。跳过的条目（`ssr://`、hysteria v1、字段缺失）带原因进 app.log；导入预览里显示「已从 base64 分享链接转换为 mihomo 配置」以及跳过数。解析器 `Sources/Core/Subscription/NodeSubscription.swift` 是纯逻辑，回归套件 `nodesubscription-tests`（81 条断言）。
- **把 base64 订阅接进现有配置（不换配置）**：配置里 `proxy-providers` 的 http provider 指向 base64 节点订阅时，mihomo 永远解析不出节点（它只接受 `proxies:` 结构），而 `use:` 引用它的策略组随之全空——症状是「订阅加进来了、状态也在拉取，但一个节点都没有」。订阅页现在对每条 http 订阅提供「转为本地订阅」：App 下载并转换成 `provider-files/<name>.yaml`，配置里只把该 provider 改成 `type: file` + `path:`，**provider 名与 `use:` 引用、策略组、规则全部不动**；源 URL 记在 `provider-sources.json`（0600），工具栏的「刷新本地订阅」重新下载转换，内核通过文件监听自动重载。改写逻辑收敛在 `ProviderRewrite`（纯逻辑，回归 `providerrewrite-tests`，32 条断言），三处调用共用同一套块定位——`health-check` 块里也有一个 `url:`，按行删除时若不分缩进会连健康检查地址一起删掉。另修一处会互相踩的坑：`writeProxyProviders` 按 http 模板重建整块，用户在订阅页删/改任何一条都会把已转换的 file provider 还原成 `type: http` + `url: ""`；现在它先读出旧块并原样保留 file 类型的定义。

- **订阅可以按策略组分配**：添加/编辑订阅时用勾选清单决定节点进入哪些策略组，支持全选 / 反选 / 清空、多选、**至少选一个**；首次保存后卡片显示归属组，并可随时「编辑分组」二次调整。旧实现无视用户选择，把第一个策略组的 `use:` 整块重写成「全部 provider」；改名还会静默退出所有组。归属写盘收敛到 `ProviderGroupBinding`（纯逻辑，回归 `providergroupbind-tests` 35 条断言）：块状/内联两种 `use:` 都支持，未受影响的组逐字节不动，`include-all-providers` 组不写 `use:`；只改归属时不重建 `proxy-providers:` 块，用户手写的 `filter` / 自定义 `health-check` 不会被模板冲掉。配置里没有策略组时明确报错、**不代建**（否则「至少一个」会死锁）。刷新订阅只拉节点、不改归属。

### Fixed

- **实机部署追加修复（2026-11-17 续）**：①Helper 行为变更必须随版本号投递——升级判定是语义化版本比较（`installed < expected` 才升级，字节比较只在「装了但连不上」的诊断分支），控制端口统一与鉴权收紧两次改动都因版本号未 bump 而被已装 1.0.32/1.0.33 短路，实测撞到后 bump 至 **1.0.34**（`kSharedHelperVersion` 与 `Helper-Info.plist` 同步）；②`Scripts/build-debug.sh` 的 Helper 手工 swiftc 未定义 DEBUG 编译条件，`#if DEBUG` 门控的「Xcode 产物根」分支被编译剔除，Debug 构建的 Helper 装机后会把 `.build` 产物路径的真客户端拒之门外（实机 `REJECTED 路径未锚定`）——脚本补 `-DDEBUG`，make.sh 的 Release Helper 不受影响。同轮实测确认：P1-1 收紧按设计生效（.build 路径被旧拒绝、/Applications 通过）、优雅退出 teardown 干净（utun100 消失、DNS 还原路由器）、单实例 root 内核冷启动 0.4s。另记录一个自愈型竞态待办：冷启动时存在多路径并发拉起内核的窗口，瞬时用户态内核因端口被 root 占用绑定失败自行退出（未观察到实际损害，属后续加固项）。
- **全量逐行审查修复（2026-11-17）**：对 Sources/ 主干 3.7 万行做四路独立审查后落地 4 个 P1 + 30 个 P2。**P1**：①Helper 客户端鉴权允许根收紧——移除 `~/Applications` 根、Xcode 产物根仅 DEBUG 放行（Release 只认 `/Applications` 与 `/Volumes/<卷>` 一层，保留 DMG 直跑；实机确认 `~/Applications` 无真客户端），威胁模型注释同步，内核二进制哈希校验留作后续立项；②TUN 数据面探针清窗条件从「本轮 cycle 无失败」改为 `allHealthy`——旧条件在首试即答短路（实机 app.log 3600 条探针记录全部走 1/1 短路）下会把仍持有 threshold-1 次失败的窗口整段清零，滑动窗口防「半死 fd 偶尔成功」的设计被编排层绕过；③SDWAN「一键修复」加重入守卫（旧实现连点会并发双写 `tun.route-exclude-address` 与归属记录）；④前台轮询 pollTask 改合并制（活任务不重建）——旧实现每次 route 点击 cancel+重建，把 configDue 打回立即执行（一次完整 refreshConfigs 突发）并把 30s 健康巡检顺延，与文件头自述纪律相悖。**P2 摘要**：Helper 侧 `cleanupTUNResidual` 增加 config.yaml `tun.enable` 写点自证（三态，读不到不清理，宁漏不误伤）；enable 系统代理前自证 `127.0.0.1:port` 监听（Helper 与 GUI 本地回退双写点，POSIX 非阻塞探针）；提权 osascript 前加中文确认框（取消不提权）；uninstallDaemon 路径插值走 shellQuote；MihomoClient 与 stopKernel shutdown 强制直连（`connectionProxyDictionary=[:]`）；callSystemProxy 超时 15s→60s（防 GUI 超时回退与 Helper 并发写 SC 存储）；控制面端口缺省三处统一 9092（避开 Clash 生态 9090 撞端口，`applyController` 发现仍为权威）；`reachable` 等值短路补齐；连接快照失败 30s 限频留痕；入睡竞态三重守卫；app.log 改缓冲写（满 32 行或 0.5s 定界 flush，退出 `flushAppLogNow` 兜底）；NetScanner 缓存与旗标 `@MainActor` 固化（隐含约定变编译期防护）。**UI 层**：连接详情卡与 Tailscale 编辑器 body 热路径 `getifaddrs` 移除（改用缓存/快照）；连接缓存双写者收归 `adoptConnectionSnapshot`（顺序逐条保留）；DateFormatter 静态化；IfaceKind→颜色/图标三份映射去重；ConfigPage 漂移横幅改挂 `configContentEpoch`（页面在屏期间配置一变即重算）；sheet 统一 `.sheet(item:)` 范式；`ForEach` 重复行身份风险加注说明。**纯逻辑层**：审计指纹 16→64bit、审计键剥配对引号（含键内冒号）；QuickRule 严格 IPv4 八位组（拒 `+1`/前导零）；Tailscale 设备拉取复用单一请求构造并加游标分页（≤20 页）；ProviderUsage 只剥首尾配对引号；YamlRuleASTEngine 五处行分割统一 CRLF 归一口径；NodeSubscription 模板不再写死 `external-controller`。回归 **PASS 27 / FAIL 0 / MISSING 3**（3 套 MISSING 为 Tests 不入库所致）——此前登记的两笔套件欠账（configwriteaudit secret 脱敏、quickrule v6 /128）本轮修红转绿，受影响 9 套断言同步更新并新增分页/CRLF/引号用例；Debug 构建嵌入 Helper 1.0.32 通过。
- **装好 Helper 1.0.31 之后所有特权功能失效，而且每次启动都重弹一次管理员授权**：两层根因。**（一）Helper 鉴权死门**——1.0.31 把客户端鉴权改成「路径锚定 + identifier」双必经，其中 identifier 那关把 `kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources` 传给了 `SecCodeCheckValidity`，而对象是**运行中的 SecCode**（不是磁盘上的 SecStaticCode）。这两个 flag 对该组合被系统判为非法，实测 macOS 27.3 恒定返回 `-67070 errSecCSInvalidFlags`，与 requirement 是否匹配毫无关系；1.0.30 及以前「看起来能用」只是因为 identifier 失败后会掉到 Layer2/3 的路径 fallback 放行，双必经把这层 fallback 关掉后就成了死门。现场证据：`helper.log` 454 条 `REJECTED — identifier 检查未通过 (path=/Applications/ClashHalo.app)`、`accepted` 0 条。改为**完整校验**（flags 为空：可执行哈希 + 资源封印 + running-code 一致性），强度高于旧的 metadata-only 检查，ad-hoc 签名不受影响；拒绝日志补上 OSStatus，避免同类问题再靠猜。Helper 版本 **1.0.32**（需强制替换掉 1.0.31）。**（二）App 把「装了但坏了」读成「没装」**——旧实现 `!isRoot` 就无条件走 `installDaemon`，于是「Helper 拒绝本客户端」和「launchd 没加载」得到同一个动作：每次启动弹一次系统授权，而它修不了前者。现在先分辨三种坏法：已安装二进制与本版本不一致 → 更新；文件齐全但 `launchctl print` 查不到服务 → 重装（bootstrap 修这个）；已加载 + 字节一致仍连不上 → **只报告并指向 helper.log，不再弹框**。判据用 `installedHelperMatchesBundle()` 的字节比较——版本号只在握手成功后才拿得到，而那正是不可达时缺的信息。

### 验证

- 真机（本机 /Applications，Release，macOS 27.3）：替换前 `helper.log` 454 REJECTED / 0 accepted；替换后 `isAuthorizedClient: accepted pid 21110: /Applications/ClashHalo.app`，App 日志 `特权服务安装成功 ✓`，`/Library` 与 App 内嵌 helper 的 sha256 一致。
- App 侧新分支实测：启动日志从「未检测到特权服务，开始自动安装…」变为「已安装的特权服务与本版本不一致，正在更新…」，一次授权完成替换。
- 诊断方法可复用：用 `SecCodeCopyGuestWithAttributes(pid)` + `SecCodeCheckValidity(code, flags, req)` 对运行中的 App 逐组合打印 OSStatus，是本轮定位 `-67070` 的直接手段。
- 构建：`xcodebuild -configuration Release` BUILD SUCCEEDED；Helper 同 make.sh 参数编译，minos 14.0，版本 1.0.32 两处一致。
- base64 订阅：用一条真实的 `.txt` 订阅（`text/plain`，488 字节 → vless + hysteria2 两个节点）离线跑转换器，得到 2 个节点、0 跳过；生成配置交给 `mihomo -t` 校验输出 `test is successful`。
- 本地 provider 转换（本机真实配置，1008 行、两个 http provider）：dry-run 改写后 `mihomo -t` 通过；正式转换后 `proxy-providers` 里 `US-LH` 变成 `type: file` + `path: ./provider-files/US-LH-928c1075.yaml`，`health-check` 块完整保留，源 URL 已从配置移除。内核 API 实测：`US-LH vehicleType=File nodes=2`（转换前 0 个节点），同块 `US-BWH vehicleType=HTTP nodes=1` 未受影响；重启 App 后状态保持。改动前已备份原 profile 与 `config.yaml`（`.bak-20261116`，0600）。
- 回归：`bash Scripts/run-tests.sh` → PASS 22 / FAIL 2 / MISSING 3。两套红的是 `configwriteaudit-tests`（secret 脱敏）/ `quickrule-tests`（v6 /128），两者编译的源码与本次改动无交集，属既有未完成项，**未修**；三套 MISSING 是 `Tests/` 不入库所致（`directexclude-tests` / `gatewaydns-tests` / `dnsledger-tests`）。
- 订阅归属：`bash Scripts/run-tests.sh --only providergroupbind` → PASS 35 条断言（块状/内联增删、无 `use:` 插入、改名原位替换、include-all 跳过、无关区域零改动、幂等、与 `ProviderUsage.groupReferences` 交叉校验）；`xcodebuild -project ClashHalo.xcodeproj -scheme ClashHalo -configuration Debug build` → BUILD SUCCEEDED。全套回归 PASS 25 / FAIL 2 / MISSING 3：两套红的是既有未完成项（`configwriteaudit-tests` 的 secret 脱敏、`quickrule-tests` 的 v6 /128），与本次改动无交集，未修；三套 MISSING 是 `Tests/` 不入库所致。
- 未覆盖：订阅弹窗的真机点击验收（本机 `/Applications/ClashHalo.app` 正在运行，未用 Debug 产物覆盖；构建产物已生成但未启动）。刷新不写盘这条只有代码路径审阅（`update` / `updateAll` / `refreshLocalProviders` 均不调用保存事务），未在运行中的内核上做 `config.yaml` 哈希实测。
- 未覆盖：Helper 鉴权没有自动化套件——它依赖运行中进程的 Security 框架行为，写进 `run-tests.sh` 会变成「测 macOS 版本」而不是测产品。这条修复以真机日志为断言。

## [1.5.0] - 2026-11-15

> 三批改动。**（一）启动不再断两次网**：网关 DNS 的监听探针从解析 `netstat` 文本改成真实 UDP 查询，「探测不到」不再允许重载内核，后台自愈在窗口隐藏后真的会跑起来（外加 App Nap 断言）。**（二）直连链路**：把规则判 DIRECT 的 IP 段排除出 TUN，以及让「运行配置偏离 profile」这件事可见。**（三）全量审计修复（2026-11-15）**：独立审计（P0×4 / P1×23 / P2×66 / P3×67）后的集中修复，覆盖发布阻断、本地提权、退出断网、配置数据丢失四类 P0 与全部 P1。**Helper 升级 1.0.31**（第三批鉴权收紧 + 死亡清理补 v6 转发 + 日志尺寸闸；启动时自动升级，单次授权）。前两批未改协议。

### Added

- **直连网段排除（建议 + 显式采纳）**：TUN 设置页新增「直连网段排除」卡片。扫描规则里显式的 `IP-CIDR`/`IP-CIDR6` + DIRECT，逐条给出建议与理由，用户勾选采纳后写进 `tun.route-exclude-address`，这些目标从此不进用户态协议栈。排除**强于所有规则**（该网段上域名/进程/端口规则全部失效），所以不自动注入；规则改动后已不成立的采纳项自动失效。
- **`Scripts/tun-exclusion-test.sh`（L1）**：直接编译生产源码断言多源合并/归属记录，并可 `--apply` 真实 PATCH 一轮验证「排除后走 en0、还原后回 utun100」。首次运行就查出归属记录里有 3 条早已不在运行配置的条目（`10.20.30.0/24` 等），已收敛为「记录 ∩ 运行配置」。
- **配置漂移可见化**：配置页顶部提示「运行配置已偏离当前配置：N 项」，可展开看差异；两个方向都给——「把运行配置存回配置」（回写 profile 并标记已应用）与「以配置为准」（覆盖运行配置）。此前设置页/规则页/DNS 页的改动直接写进运行配置而不回写 profile，实测一台机器上两者差 69 行，重新应用配置会连 API secret 一起覆盖。
- `Docs/PerfRoadmap.md` + `Scripts/perf-ab.sh`：可复现的直连链路测量基线（native vs TUN 同服务对照、逐阶段打点、每连接 CPU）。
- `Sources/Model/GatewayDNSHealth.swift`：网关 DNS 体检的判定半边（纯逻辑）+ 唯一的 socket 半边。`Tests/GatewayDNSHealth`（`gatewaydns-tests`，28 条断言）钉住两件事：**探测不到只报告、不重载**；`allowsKernelReload` 是白名单不是黑名单。
- **隐藏态可观测**：窗口不可见时打一条「后台安全巡检启动」，之后每 15 分钟一条「后台轮询心跳：… 60 s 巡检 N 次，上次网关 DNS 查询 N 秒前」。之所以必须要它：`traffic-history.json` 的 mtime **不能**用来判断巡检有没有跑——`recordHistoryOnly` 为省内存只在 UI 在屏时汇总写盘，文件不动只说明没人在看（2026-11-08 那次排查正是这么误判的）。
- **（审计批次）回归套件补齐 13 套**：loop-sentinel / tundnsaddress / configwriteaudit / applydrift / kernelmemoryguard / connorigin / providerprotocols / quickrule / deviceidentity / inboundlistener / providerusage / emptygroup / rulevalidator——全部直接编译生产源码、合成 fixture、不依赖开发机实时状态，钉住本轮修复点（MATCH 校验、v6 /128、剥端口、内联 rules 拒绝、secret 指纹留痕、include-all: false 空组等）。登记 27 套全部可跑。
- **（审计批次）发布防线**：make.sh 末尾自检 Helper 最低系统版本（>14.0 拦截）；版本自检前移到 DMG 生成之前，失败回滚已自增的 build 号；pre-commit 改扫 staged 内容，订阅 URL / 节点链接 / tskey / YAML 裸值凭据全 BLOCK；最终签名带上 entitlements；安装器检测 App 正在运行、删除失败不再嵌套安装。

### Fixed

- **每次启动都白重载两轮内核、丢掉全部在途连接**：判据是 `netstat -an -f inet -p udp` 的文本匹配找 `*.53`。本机实测（macOS 27.3）从 App 里 fork 出来的 netstat 对这套参数**一个字节都不输出**（同参数在 shell 里有 74 行），于是「53 在监听」被永久判成「没监听」——`app.log` 里 12 次启动对应 12 次「正在重新应用（第 1/2 次）」，而 mihomo 自己在判定前 0.5 s 就打出了 `DNS server(UDP) listening at: [::]:53`。探测改为向本机 53 端口发一次真实 A 查询（`GatewayDNSProbe`，判据复用 `DNSProbe`：只认 NOERROR），一次应答同时证明监听存在、socket 是 DNS、解析路径通。冷启动实测重载 **0 次**（旧版 2 次）。
- **「探测不到监听」不再触发全量重载**：`PUT /configs?force=true` 会重建 DNS、全部 in/outbound 与 TUN，代价是丢掉全部在途连接，而它修不了这件事的三个真实成因（端口被别的 resolver 占、内核刚起没绑完、上游解析失败）。判定收敛到 `GatewayDNSCheck.evaluate`：只有 `declarationDrift`（`allow-lan` 关 / `dns.listen` 不是 `0.0.0.0:53`，典型成因是切订阅）允许重载，其余结论只报告；失败文案区分「回环正常但 LAN 无应答」与「回环也没应答」，并明说重载修不了。
- **假的进程级归因**：`53 端口当前无任何 UDP 监听` 这句结论来自同一个失效的 netstat（同一秒 `dig @127.0.0.1` 正常 NOERROR），该探测已删除。现在的失败文案只陈述实测到的事。
- **放弃复查之后其实没人复查**：旧代码的「每 5 分钟静默复查」挂在一条只在「窗口不可见**且**连接页未激活」才安装的 30 s 定时器上，而连接页的 `onDisappear` 在窗口隐藏时并不保证触发——flag 停在 true，定时器一次都没装上，13:27 隐藏窗口之后整晚没有一次巡检，恢复日志（`网关 DNS 已恢复…`）全日志 0 条。现在：隐藏态无条件起 30 s 轮询；网关体检挂到「不看 UI 也要跑」的 60 s 安全巡检上；两处轮询对「连接页在屏」的豁免补上 `&& isMainWindowVisible`。
- **后台自愈没有 App Nap 断言**：全仓此前没有任何 `beginActivity`（`grep -rn beginActivity Sources` 为空），隐藏窗口的定时器会被系统合并/挂起。现在网关或 TUN 开启期间按住 `.userInitiatedAllowingIdleSystemSleep`（**不**阻止系统空闲睡眠：那是另一个产品决策，笔记本上是实打实的耗电与发热）。
- **启动宽限期**：`kernel ready` 只代表控制 API 起来了，DNS 监听随后才 bind。首次体检推迟 20 s（`kGatewayDNSStartupGrace`），避免把「正在起」读成「没起来」。
- **归属记录在第二次下发时被抹掉**：`commitProvenance` 写的是本轮 `newlyInjected`，第二轮下发时那些条目已经在运行配置里，于是记录变成空——条目被静默升格为「用户手写」，此后任何撤回都删不掉（对端隧道断开后其网段永久留在排除表里）。改为 `nextRecord = (previous ∪ newlyAdded) ∩ desired`。
- **多源排除互相覆盖**：共存与直连共用同一个归属键，各自 commit 会覆盖对方。合并收敛到 `RouteExclusionMerge` 单点，`reconcileCoexistenceIfChanged` / `applyTUNState` / SDWAN「一键修复」三处统一走它。
- **（审计批次 P0）macOS 14~26 装完 TUN 特权功能全废**：Helper 用裸 swiftc 编译没传部署目标，二进制最低系统版本跟着构建机走（实测 27.3），旧系统 dyld 拒载。固定 `-target arm64-apple-macosx14.0`，打包自检拦截。
- **（审计批次 P0）本机任意进程可提权到 root**：Helper 鉴权 identifier 通过即放行，路径锚定层被短路跳过；内核路径只查末段软链、不锚定用户。现在路径锚定与 identifier 双必经，内核路径解析软链并锚定控制台用户 home，挂载卷只认一层。
- **（审计批次 P0）拒装 Helper 的用户退出 App 后断网**：开启侧有本地 networksetup 回退、退出侧没有，代理仍指死端口。退出清理补本地同步关代理（限时 3s、不弹授权框）。
- **（审计批次 P0）编辑活动配置失败后编辑内容丢失**：回滚把旧运行配置写进 profile 文件。现在同 id 失败只还原运行配置，profile 保持用户内容。
- **（审计批次 P1）连接页速率恒 0**：共享字节基线被 recordHistoryOnly 先覆盖，VM 再读它算差恒 0，按速率排序截断随之失效。VM 自持基线先算差再交共享路径。
- **（审计批次 P1）重点击活动配置后内核失联**：短路分支把 profile 原文写盘剥掉加固 secret 又不补加固，下次 reconnect 全量 401。短路后补 hardenControllerConfig。
- **（审计批次 P1）IPv6 断供保护被静默覆盖**：`2000::/3` 排除在多源合并时被覆盖丢失且永不恢复（mini-pro 事故形态）。移到合并之后追加，SDWAN 一键修复同口径。
- **（审计批次 P1）内核假死 + 隧道残留时隐藏态零巡检**：僵尸巡检依赖 reachable，不可达即空转，盲区日志还是死分支。sweep 增加不可达分支（两击确认自愈），隐藏态巡检在不可达时保住，前台循环不再被 reachable 翻转杀掉。
- **（审计批次 P1）端口转发编辑弹窗沿用上次未保存值**：稳定 id + loaded 闩锁复用视图身份（2026-10-20 事故同根因残留）。每次展示新 UUID。
- **（审计批次 P1）本地导入配置点了没反应**：非沙箱 App 的 security-scoped 守卫恒 false 吞掉整个导入分支。移出条件链。
- **（审计批次 P1）连接/日志页内核未就绪打开永久空白**：start 只调一次且 guard reachable。reachable 恢复时补 start。
- **（审计批次 P1）通告子网导入可把本机 LAN 劫进 tailnet**：导入候选无本机网段闸门。过 PeerRouteGuard + fake-ip 双段 + 默认路由拒绝，被拒条目带原因进 warnings；预览计数同口径。
- **（审计批次 P1）TUN 排除表手工编辑固化自动条目**：NList 整块写盘把自动注入条目升格「用户手写」，撤回后从磁盘复活。改走唯一合并入口（用户增删作为一个源）。
- **（审计批次 P1）安装特权服务可被注入 / 替换**：bundle 路径进 root shell 双引号（卷名含 `$(…)` 即注入）；临时 plist 在密码框窗口可被同用户替换。路径单引号转义，plist 改 root script 内 heredoc 生成。
- **（审计批次 P1）写盘失败假成功 / MATCH 校验洞 / v6 前缀 / 内联 rules / 注释误归属**：writeConfig 返回值四处传播；MATCH 只豁免 match 参数、PROXY 目标照校；v6 单 IP 统一 /128、一键制裁剥端口；内联 rules 保存显式报错不再产生重复键；块键带行尾注释不再整段误归属（readConfigFile / proxyProviders / 审计三处同口径）。
- **（审计批次 P1）事务竞态与锁缺口**：设置页事务专用串行队列互斥；heal/reconcile 补 isBusy 入门守卫与 await 后复查；唤醒网关恢复加漂移门、持锁、失败不再抹用户意图。
- **（审计批次 P2 批量）审计日志隐私与权限**：secret 变更留指纹对痕、序列内嵌字段不再泄进扁平视图、内联 provider URL 脱敏；profiles 0600、回滚路径保 0600；Keychain 删除失败不再留可复活镜像。
- **（审计批次 P2 批量）内核切换与更新**：下载补 sha256 校验；临时关代理查返回值失败即中止；切换失败还原 TUN DNS；下载与切换拆锁（下载不持锁、切换持锁）；自动更新改直连不经系统代理。
- **（审计批次 P2 批量）状态与展示**：哨兵后台照喂；「已关闭」计数基线重建；来源列网关 OFF 不再误判；设备身份空闲拍不闪烁；聚合 tab 计数取对源；订阅/日志/仪表盘区分不可达/加载/空态；日志导出失败不再报成功；删规则/删配置加确认；菜单栏面板可滚动；Helper 检查读刷新后状态；TUN/网关开启时拒卸 Helper。
- **（审计批次 P3 批量）**：Helper 日志尺寸闸、死亡清理补关 v6 转发、cleanupTUNResidual 认 198.19 且如实返回、系统代理写超时 5s+重试、DNS 写超时、隐藏态定时器合并制、bypass 挂 60s 巡检、日志锁、死代码清理（NSConnTable 等）、设计令牌漂移收敛、表单回车提交、API 密钥改密码控件、出厂模板 allow-lan:false + 空 secret（启动即加固）。

### 验证

- 回归：`bash Scripts/run-tests.sh` → **PASS 14 / FAIL 0 / MISSING 13**（新登记 `gatewaydns-tests` 28 条、`directexclude-tests` 28 条；`Tests/` 不入库，其余 13 套需 `restore-tests.sh` 物化，本机缺失如实列出）。
- 构建：`bash Scripts/build-debug.sh`（Debug + 内置 Helper）通过。
- 网关 DNS 实测（本机，Debug 版）：冷启动 2 次，`正在重新应用` 增量 **0**（旧版每次 +2）；日志出现 `网关 DNS 监听正常（本机 LAN 地址实测 NOERROR 应答）`；关掉主窗口后 30 s 内出现「后台安全巡检启动」与「后台轮询心跳」。
- 直连链路实测（本机 TUN 开启）：同一家服务 native 首飞 4.0 ms / TUN 14.3 ms；`www.baidu.com` 首飞 45.7 ms、TLS 65.7 ms（TLS 1.2 两个 RTT + 拨号一个 RTT）。
- （审计批次）构建：Debug 与 Release（clean）均 **BUILD SUCCEEDED**；Helper 同 make.sh 新参数独立编译实测 **minos 14.0**（修复前 27.3），版本 1.0.31 两处一致。
- （审计批次）回归：`bash Scripts/run-tests.sh` → **PASS 27 / FAIL 0 / MISSING 0**（1321 条断言；13 套缺失补齐后首次全量可跑）。
- （审计批次）未做：真机 TUN 开/关与 Helper 安装/升级密码框流程、UI 真机截图（宿主无屏幕录制权限）——涉及这些路径的修复为代码级判定 + 回归钉住，发版前需真机过一遍。

## [1.4.2] - 2026-10-29

> 两处「静默把配置写坏」的修复：网关设置里的 `*` 会把整份 `config.yaml` 写成内核解析不了的文件，删订阅会把你按订阅拆分的策略组 `use:` 静默合并。外加删订阅前的空组预检。**Helper 仍为 1.0.30，本次未改协议，无需重装。**

### Fixed

- **应用一次局域网网关设置，之后内核就再也起不来**：`bind-address` 的默认值是 `*`，而裸 `*` 在 YAML 里是别名节点的起始符，属于**语法错误**。`setTopLevelScalars` / `setNestedScalars` 渲染字符串时直接拼裸值，于是每次「应用」都把 `config.yaml` 写成一个连 `mihomo -t` 都读不了的文件——热重载当场失败，之后每次重启内核也一起失败。新增 `quoteYAMLScalarIfNeeded`：首字符命中 YAML indicator（`*`、`&`、`!`、反引号、`#`、引号、方括号/花括号、`-`、`?`、`:` 与空白）、含 `: ` 或 ` #`、以 `:` 结尾、或本身为空串时加双引号，并转义反斜杠与双引号。
- **删一个订阅，其它策略组的 `use:` 被整块重写**：`writeProxyProviders` 的最后一步会无条件把**第一个**策略组的 `use:` 改成「当前全部 provider」，你按订阅拆分的组结构（组 A 只用订阅 1、组 B 只用订阅 2）被静默合并成两组都用全部。现在只在纯新增/编辑路径做同步；删除路径的引用清理本来已由前面按名精确完成，不需要也不应该再动任何组的 `use:`。

### Added

- **删订阅前的空组预检**：删掉最后一个供血 provider 后，策略组会变成没有任何来源的空 `select`，内核只回一句英文语法错，看不出「组空了」才是真正原因。新增 `ProviderUsage.groupsMissingMembers(in:)`——与 `groupReferences` 同一份行扫描口径，不引入第二套 YAML 理解——在写盘之后、内核校验之前先查，命中就整体回滚并用中文列出涉及哪些组。口径：`proxies:` / `use:` 任一有非空条目即有来源；内联数组与块状列表两种写法都认；`include-all` 家族本身就有来源，不认会把合法配置全判死。

### 验证

- 回归：`bash Scripts/run-tests.sh` → 登记 25 套里 **24 套通过**（新登记 `emptygroup-tests`，9 条断言钉住空组口径）；`dnsledger-tests` 的测试源码不在版本库、git 历史里也取不到，本机无法恢复——如实列出，不当成全绿。
- Release 构建通过；`make.sh` 版本自检输出 `Version: 1.4.2 (135) ✓`
- 发版检查：出厂 App、DMG 内嵌 App、DMG 文件名均为 **1.4.2 / build 135**，签名为 ad-hoc。
- **未覆盖**：`quoteYAMLScalarIfNeeded` 位于 `EngineControl.swift`，该文件依赖 SystemConfiguration 与特权路径，现有回归套件都不编译它，所以这条修复没有自动化断言；它也没有在真机网关上跑过一次完整 apply → reload（需要 Helper 与网关硬件）。改的是「写盘时字符串怎么渲染」这一纯函数级行为，尚未被独立测试钉住——下次动它请先补断言。

## [1.4.1] - 2026-10-22

### Added

- **连接表「来源」列**：`本机` / `局域网 · 192.168.1.33` / `外部 · 1.2.3.4` / `未知`，悬停可看完整证据（归属 + 入站名）。判定与连接详情同一套 `ConnOrigin`（TUN 下 `sourceIP` 恒为 fake-ip 网关，不能只看它）。列**常驻**而不是可开关：条件列在 `TableColumnBuilder` 里需要 macOS 14.4+（本工程部署目标 14.0），而 `TableColumnCustomization` 会多出一条「表头右键」控制路径，与自绘开关不同步。
- 本机网卡地址集合收敛为 `AppModel.localIPs`（随连接快照刷新、等值短路），表格逐行判定不再调 `getifaddrs`。

### Changed

- 连接表单元格抽成 `@ViewBuilder` 方法、表格本体抽成独立属性：`Table` 的列构造器是巨型表达式，加到 8 列会触发编译器 `unable to type-check in reasonable time`。行为不变。

## [1.4.0] - 2026-10-22

> 对标优化批次：连接决策链、一键规则、端口转发、设备身份、订阅统计、上手引导，外加两处规则表单修复。**Helper 仍为 1.0.30，本次未改协议，无需重装**。

### Added

- **连接详情四段式决策链**：来源 / 解析 / 规则 / 出口，用上内核 `/connections` 里原本被丢弃的元数据（`inboundName` / `dnsMode` / `sniffHost` / `providerChains` / `uid` / `remoteDestination`）。判定逻辑在 `ConnOrigin`（纯逻辑，`connorigin-tests`）。
- **一键「独立制裁」**：连接右键「让 `<host>` 直连」/「拉黑 `<host>`（显示受影响连接数）」/「这个 App 走当前策略组」，决策在 `QuickRule`，写盘复用既有事务（备份 → `mihomo -t` → reload → 失败整体回滚）。同匹配的旧规则会被替换而不是并列。
- **端口转发（入站 listeners）**：网络 → 入站新增转发管理；默认只监听 `127.0.0.1`（「允许局域网访问」需显式勾选）；改端口走 `PUT /configs?force=true` 热生效，不重启内核、不打断其它转发。写盘约束在 `InboundListener`（`network` 必须是数组、`bind-address` 对 listener 无效、不写 `listen:` 会绑全网卡）。
- **局域网设备身份**：网关设备卡显示 MAC / 厂商 / 推测类型，`arp -an` 取不到或跨网段时显示「未知」而不是留白；类型只来自厂商白名单或端口指纹（`DeviceIdentity`，「推测」措辞写死）。
- **订阅卡协议分布**：`VLESS 61 · HYSTERIA2 25 · SS 2` 形态，超过 4 种折叠为前 3 + `+N`；`proxies` 未下载完时不显示而不是显示 0。
- **订阅被几个策略组引用**：N=0 时警示「节点不会出现在代理节点页」（`ProviderUsage`）。
- **空状态三步引导**：导入订阅 → 选节点 → 开启接管，完成度全部由真实状态推导（无持久化 flag），配置页与仪表盘共用同一组件。
- **规则目标存在性校验**：规则引用的策略组/节点已不存在时，保存前用中文拦住并让用户在标着「（已失效）」的原值上重选，不再写盘 → 内核 reload 拒绝整份配置 → 回滚 → 弹一条英文报错。判定权威是写盘目标文件（策略组 + 节点 + `config.yaml` 里的组 + 内置策略），拿不到数据时放行。

### Changed

- **全站开关统一为 `DSCompactSwitch`（32×18）**：系统 `NSSwitch` 固有 54×24pt 且 `controlSize` 无效，侧栏 / 设置 / 规则 / 网络页全部切换；多选场景（端口转发协议）仍用 checkbox。
- **TUN 断流预告**：走「重启内核重建隧道」路径时提前说清现有连接会中断；PATCH 热切换成功提示「未断流」。
- 表单行、失效提示、错误行按 `Docs/design.md` §6.4 收敛（标签在上、控件整行宽、错误行固定占位）。

### Fixed

- **编辑规则弹窗不带入原匹配内容**：`.sheet(isPresented:)` 复用同一视图身份，而 `@State` 初值只在身份首次出现时生效——第一次开的是「添加」（空值），之后每次「编辑」都沿用空值。改用 `.sheet(item:)`（与连接页一致）+ 幂等 `onAppear` 兜底。

## [1.3.8] - 2026-10-18

> 一次全量代码审查（24 项）的落地版本：把「静默失败」逐条改成「失败可见 + 可回滚」，并修正 ⌘W 语义。**Helper 仍为 1.0.30，无需重装**。

### Added

- **持久化写入事务化**：`patchPersistent` 改为完整事务——备份 → 写盘 → `mihomo -t` 校验 → 重载 → 任何一步失败还原原文件；读不到备份就拒绝写入。11 个 UI 调用点在失败时把输入框/开关弹回真实值，不再「界面写成功、磁盘没变」。
- **`.proxy` DNS 属主补回收路径**：redir-host + 系统代理写下的 `127.0.0.1`，在关掉系统代理后按属主还原，不再残留成解析黑洞。
- **日志级别单一选项源**：设置页与日志页共用一份（含 `SILENT`），日志页不再出现「一个段都不选中」。
- **顶栏收敛**：设置 / 网络 / 日志 / 规则 / 仪表盘 / 连接页统一使用 `PageToolbar`（标题、页内控件、右侧操作、高度、分割线、左缘一致），删除零调用死代码 `PageHead`；仪表盘标题不再随滚动消失。
- **⌘W 只关窗口**：窗口收起后代理与 TUN 继续工作、菜单栏图标仍在；Dock 图标或菜单栏「打开主窗口」唤回（窗口状态保留）。⌘Q 才退出，仍走 TUN 有序收尾。

### Changed

- **探测失败可分辨**：`probe` 区分 401（密钥不匹配）/ 超时 / 连接被拒并把原因写进日志；内核退出时版本号置 `?`，不再是「假在线」。
- **冷启动与唤醒不再一次探测就判死**：任何一次探测失败都补一次 300 ms 后的确认，才进入不可达收尾。
- **两个「更新订阅」说清各自在更新什么**：配置页 = 更新磁盘配置文件，订阅页 = 刷新内核节点。
- **路由注入/清理失败可见**：限流提示，自动重试语义保持不变。

### Fixed

- **写坏的 `config.yaml` 留在磁盘**：校验失败或内核拒绝时回滚，并区分「本次写入导致」与「配置本身不合法」。
- **网关级联的第三份写盘实现**：收敛到同一事务，不再手写 `setTopLevelScalars + reload + 裸 toast`。
- **`refreshConfigs` 失败静默返回**：TUN / 静态路由 / DNS 自愈链会整体停摆且无日志；现在限频记录原因、交 `reconnect()` 统一判死（保留「内核刚死」的 DNS 与系统代理回退）。
- **空路由图冒充「已注入」**：对端 VPN 网段此后永久不再注入绕行路由；改为 30 s 到期复查。
- **前台巡检因内核不可达整体退出**：僵尸 TUN 巡检与内存警卫先于故障停摆；改为廉价重探 + 指数退避（200 ms→2 s）继续巡检。
- **订阅更新失败仍报「已更新」**：`updateProvider` 补 HTTP 状态码检查（此前丢弃响应体），失败如实报错且不假装刷新。
- **退出时清路由的 `nil` 语义**：不再把「Helper 不可达」当成「没有路由要清」，保留标记待续清。
- **`setTunDevice` 静默失败**：读写失败改为返回 Bool 并在 UI 提示（设备名没写进去会让巡检误判「接口丢失」而拆掉隧道）。
- **右键菜单缺 busy 门 / 规则保存永远停在「保存中」**：配置页菜单项统一按 `engine.isBusy` 禁用；抢锁失败时补 `onFinished(false)` 收尾。
- **DNS 监听地址字面量重复 6 处**：收敛为 `systemProxyDNSListen` / `defaultDNSListen` 两个常量。

### Notes

- `NetScanner.tunRoutes()` 保持「全部 utun」口径（SD-WAN 页三处消费者按出口接口分组，Tailscale/ZeroTier/Oray 与本机 TUN 并列展示是刻意设计），归属判定统一走 `ownMihomoTunInterface()`；本次只在类型与调用点写清口径。
- `NText` 类型文档写明：**禁止用于密钥/令牌**（无掩码能力，明文显示 + 明文落盘）。

### 验证

- 回归套件：`bash Scripts/run-tests.sh` → 12 套全绿（另有 5 套源码不在版本库，本机无法恢复）
- Debug / Release 构建通过；真机按键验证 ⌘W 只关窗、Dock/菜单栏唤回、⌘Q 真退出

## [1.3.7] - 2026-10-16

> 1.3.6 发布后复审出的高危项收敛。**本版本必须搭配 Helper 1.0.30**：旧 Helper 会在 DNS 还原失败时回写公共 DNS、用整表 `route -n flush` 清路由，本身就会破坏用户系统配置。

### Added

- **崩溃防护：内核日志改合并刷新**：`logKernel` 每行不再单独触发一次 `@Published` 事务。此前 macOS 26 上一次真实崩溃中，SwiftUI 把高频图事务推迟到协作线程池，与主线程 AppKit 布局竞争，触发 `NSStatusItem setVisible:` / `-[NSMenu itemArray]` 断言中止（两份崩溃报告零应用帧）。文件日志仍逐行同步写，界面日志按 0.3 秒合并。
- **DNS 台账可测化**：`TunnelDNSLedger` 抽出 `DNSLedgerStore` 与 `SystemDNSDriving` 两个协议，回归套件 `Tests/DNSLedger` 直接编译生产源码钉住 5 条不变量（属主隔离、读失败不落快照、pending→committed、恢复失败保留账本、服务漂移自愈）。

### Changed

- **订阅下载强制直连**：订阅请求的 URLSession 由 `.default` 改为 ephemeral + 空代理字典。此前在「切换内核」的 `stopKernel` 窗口里，订阅请求会打到无人监听的 mixed-port 而黑洞，用户感知为「订阅突然坏了」。
- **共存指纹去除接口绑定后缀**：utun 序号随睡眠唤醒 / 隧道重建漂移（utun8→utun9）不再被当作拓扑变化。此前每次漂移都回以整块 `tun` PATCH + 全量静态路由重装——2026-10-14 日志一天出现 6 次假性拓扑变化、路由条数在 7/8/9 振荡、在途连接被反复抖断；而该 PATCH 根本携带不了 DNS 绑定（mihomo 忽略运行时 `dns` PATCH）。
- **TUN-off 拆除重新排序**：静态路由清理与隧道残留物理清理现在跑在 `restoreTunnelDNS()` **之前**。先清路由、后恢复 DNS，缩小断流窗口。
- **默认接口探测改用 `SCDynamicStore`**：`EngineControl.defaultInterface()` 从硬编码 `en0` 改为读 `State:/Network/Global/IPv4 → PrimaryInterface`，读不到时才回退 `en0` 并记日志。
- **`ConfigStore.save()` 返回成功与否**：Keychain 写入失败与 `manifest.json` 落盘失败都进 app.log。此前 `try?` 静默吞掉——manifest 一旦撕裂，`load()` 会静默重建「默认配置」并孤立所有 `profiles/<id>.yaml`。
- **Helper 侧恢复命令超时分层**：`cmdTimeout` 1.2 秒、恢复路径 `restoreCmdTimeout` 5.0 秒；`enabledNetworkServices()` 失败后立即重试一次，两次都失败则记名日志并按空处理。

### Fixed

- **DNS 快照被读取故障洗掉**：`currentSystemDNS(service:)` 改为三态 `[String]?`（`nil` = 读取失败）并加 5 秒超时。旧版错误路径返回 `[]`，会被当成「用户没配 DNS」写进快照，恢复时写回空列表，真实配置就此丢失。
- **`tun.device.pinUnsupported` 无重置点**：该标志此前一旦置位永不复位，一次瞬态失败（utun100 被占用、configd 竞争）就永久放弃 `kPinnedTunDevice`，永久降低身份判定并致盲僵尸巡检。现每次启动重置。
- **严格 F/S 交替形态的半死 TUN 不自愈**：滑动窗口失败数会永远停在 `failThreshold-1`，主条件与 `allHealthy` 都不成立，状态机卡死在「不触发也不清零」。补交替触发判据 + 同窗口只触发一次的闩锁。
- **Helper 残留清理越权**：移除整表 `route -n flush`，改为按接口 `-ifscope` 定向删除，并新增「UP 且不是 pin 住设备即跳过」的资格判据。`flush` 会连用户与其他 VPN 的路由一起清。
- **回环解析器被误判为死**：`isLoopbackDNSLive()` 补 UDP 探测，仅当 TCP 明确拒绝**且** UDP 不响应才判死。此前只看 TCP，把 mihomo 的 UDP 优先监听误判为死并清掉一个活着的监听。
- **残留清理被无关隧道误放行**：`shouldSweepResidueOn` 新增 `residueRoutedIntoOtherTunnel` 参数，改为逐地址取证。旧的 `return !otherTunnelIsUp` 意味着机器上只要有任一条 proxyTun 处于 UP，所有无来源证据的残留就逐轮跳过——用户把默认服务切过去的那一刻全网黑洞。
- **共存网段冲突静默丢弃**：`excludeRouteMap` 从静默改为首赢 + 回调日志，写明「保留谁、忽略谁、取自检测顺序而非仲裁」，被黑洞时可直接定位。

### 已知限制（有意不在本版关闭）

- `RouteTable.drift(expected:in:pinned:)` 的第三接口豁免会吞掉残留载体。
- `cleanupTUNResidual` 的 split 路由残留依赖 `if_down` 清 `RTF_UP` 惰性化，不逐条删除。
- `isAuthorizedClient(_:)` 有意保留 `kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources`，否则 Debug / ad-hoc 构建会被 `SecCodeCheckValidity` 拒绝。

## [1.3.6] - 2026-10-16

### Added

- **TUN 开启时退出是真退出**：开着 TUN 按 ⌘Q（或菜单栏电源键、关闭最后一个窗口）不再取消退出、不再藏进菜单栏，而是先有序拆除——关系统代理、还原系统 DNS、停内核、清隧道残留——完成后进程完整退出。实测拆除约 0.7~1.0 秒，退出后无残留进程、无 DNS 黑洞。
- **DNS 重定向台账 `TunnelDNSLedger`**：系统 DNS 的写入与还原收敛到唯一记账属主，`.tun`（fake-ip 网关）与 `.proxy`（redir-host 回环）各持独立服务 pin 与快照，两属主互不覆盖。
- **配置写入审计**：所有改写 `config.yaml` 的路径落盘到 `~/Library/Logs/ClashHalo/config-writes.log`，配置漂移可追溯到具体写入者。
- **配置漂移检测**：加载 profile 后逐键比对「实际生效配置」与「profile 原文」并告警，区分刻意的运行时覆盖与意外分叉。
- **TUN 数据面探针身份校验**：应答必须落在被探测的隧道地址上（`IP_RECVDSTADDR` 归属判定），杜绝劫持应答被误判为健康。
- **后台安全巡检**：TUN 与系统代理状态的后台守卫，界面关闭时仍持续自愈。
- **sweep 清理门槛可测化**：抽成纯函数 `shouldSweepResidueOn(hasProvenance:isDefaultService:otherTunnelIsUp:)`。

### Changed

- **内核升级至 mihomo v1.19.32**（原 v1.19.29），并修正 v1.19.32 默认 listener TUN 栈为 mips。
- **`make.sh` 内核版本固定**：锁定 `MIHOMO_VERSION` + `MIHOMO_SHA256`，本地副本版本不符即重新下载并校验，破损或哈希不匹配直接中止构建。
- **TUN DNS 网关地址改为观测优先**：以内核实际下发的 `inet4-address` 为准，可达性判据由「主机位是否有效」改为「路由是否指向隧道」。旧判据依赖的「网络地址永不应答」前提经实测证伪——`198.18.0.0` 与 `198.18.0.1` 的行为完全一致。
- **DNS 探针谓词收紧**：只承认 `RCODE=NOERROR`；`SERVFAIL`/`NXDOMAIN` 不再算作数据面存活。旧规则「格式有效即活」让探针在 DNS 全黑洞期间连报假绿灯。
- **残留 DNS 清理覆盖全部网络服务**：候选集从「固定服务 + 当前默认」扩展到系统全部网络服务，修复非默认接口（如 `Ethernet`）上的残留永不被清扫。
- **TUN 数据面探针调度改为合并制**：不再 cancel + 重建，高频网络事件只能把探针拉早、永远推不晚；此前事件风暴会把探针无限顺延且完全静默。距上次实际执行超过 2×delay 强制立即排程兜底。
- **Helper 升级至 1.0.30**：DNS 还原命令加 5 秒超时并去掉 `223.5.5.5` 兜底（还原失败保留原值交 GUI 清扫，不再覆盖用户 DNS）；回环解析器存活探测补 UDP（此前仅 TCP，把 mihomo 的 UDP 优先监听误判为死）；`cleanupTUNResidual` 由整表 `route -n flush` 改为定向删除并经归属预检覆盖全局默认路由；客户端路径校验归一化（`..` 折叠 + 符号链接解析）并锚定安装根白名单；`restoreDNSIfTunnelPinned` 返回逐服务报告，部分失败在 helper.log 可见。

### Fixed

- **退出后系统 DNS 钉在死不掉的解析器上**：Helper 的客户端死亡看门狗会在 GUI 进程消失约 2 秒后无条件停掉 root 内核，而 `performCleanup()` 的关代理与 DNS 还原从未执行——旧版退出 TUN 后整机解析不了域名。现由 `applicationShouldTerminate` 返回 `.terminateLater` 挡住退出，等拆除完成再放行。
- **TUN 关闭后系统 DNS 残留**：旧版本遗留、无标志位、非默认服务上的 fake-ip 残留此前被永久跳过，现按观测到的系统状态清理，并在写入失败时保留重试线索。
- **DNS 还原失败被静默吞掉**：恢复写确认成功才清账，失败保留记录待下一拍重试；退出路径超时或失败保留账本，交下次启动续修。
- **僵尸 TUN 自愈竞态**：`zombieTunRepairInFlight` 置位提前到巡检调用之前，消除同一僵尸事件被重复触发自愈。

## [1.3.5] - 2026-09-26

### Changed

- **AGENTS.md 文件名规范化**：统一 AI 编码代理记忆文件命名。
- **.gitignore 扩展**：压测与监控产物不入库。

## [1.3.4] - 2026-09-16

### Added

- **僵尸 TUN 巡检自愈**：配置关闭 TUN 但接口仍 UP 持路由时自动回收。
- **TUN 自循环哨兵**：识别 DIRECT 链上行静默下行膨胀的自循环指纹。

### Fixed

- **仪表盘幽灵流量统计**：TUN 关闭级联半途失败导致接口残留、计数虚高。

## [1.3.3] - 2026-09-12

### Added

- **内核日志风暴看门狗**：以内核日志增速检测批量读 fd 半死空转，三级处置防重启循环。

### Fixed

- **tun 配置字段漏重述**：PATCH 整块替换语义下部分字段被打回内核默认值。
- **Helper 升级（1.0.29）**：root 启动前修复数据目录属主，内核日志加 50MB 启动尺寸闸。
- **Keychain 重播竞态**：订阅 URL / Tailscale key 旧值复活。

## [1.3.2] - 2026-08-29

### Added

- **TUN IPv6 接管闸门**：物理 v6 断供时自动排除 `2000::/3`，恢复健康后自动解除。
- **WebSocket 心跳**：半开连接从静默停滞变为自动重连。
- **内置 Zashboard 接线**：离线开箱即用，不可达时自动回退外置面板。

### Fixed

- **规则编辑器引擎**：`#` 不再被截断，fence 区原样保留，连接页规则保存改走事务式路径。
- **config.yaml 0600 权限覆盖全部写者**：所有写点收敛到原子写。
- **内核断连不再抹掉网关用户意图**：不再清 `gatewayModeOn`。
- **`stopStreams` 漏 cancel `/memory` 流**：断连后仪表盘内存不再永久卡死。
- **manifest / 流量历史原子写**：crash 不再丢失订阅清单与流量统计。
- **UI 表单失败回灌**：内核拒绝的配置值立即回灌真值。
- **Helper 升级（1.0.28）**：客户端死亡清理识别已死的 DNS 重定向，crash 后不再残留解析黑洞。

### Changed

- **TUN 并发加固**：唤醒恢复路径补持锁，网络变化处理收敛为同步占位。
- **DNS 重定向按服务身份快照/恢复**：网卡切换后旧服务重定向不再残留。
- **前台轮询去重**：didSet 增加同值守卫，高频 `@Published` 补等值短路。
- **网关巡检单飞闸**：并发触发不再各自 reload 掉全部连接。

## [1.3.1] - 2026-08-22

### Fixed

- **系统代理 fake-ip 黑洞**：代理模式不再重定向系统 DNS，TUN 是唯一属主。
- **系统代理服务发现错误**：修复 `networksetup` 解析分支不可达，Helper 与 GUI 统一枚举。
- **三态结果语义**：取代 anyOK 布尔，部分失败点名失败服务。
- **退出/重启竞态误杀新内核**：清理前重查会话接管。
- **仪表盘卡片全 0**：新增 3 秒 dashboard 数据轮询。
- **关闭 TUN 后断网**：补 `restoreTunnelDNS()` 调用。
- **系统代理 DNS 污染**：自动确保 mihomo DNS 监听 `127.0.0.1:53`。
- **Zashboard 面板无法登录**：改为优先打开内置 HTTP 面板。

### Changed

- **Helper 升级（1.0.24 → 1.0.27）**：修复退出/重启竞态，死亡回收按端口限定。
- **系统代理开启耗时优化**：目标服务枚举加缓存，逐服务读回降级为诊断路径。

## [1.3.0] — 2026-08-17

### Fixed

- **内存警卫口径切换**：从 `phys_footprint` 改为 RSS，阈值重新校准，徒劳检测与自我停摆。
- **升级/重装后 Tailscale auth-key 不再丢失**：写入用开放 ACL，数据目录落镜像。
- **auth-key 被 tsnet 静默忽略**：检测日志，UI 一键清除身份并重试。
- **auth-key 路径从未真正注册节点**：统一 `warmUpTailscale()` 拨号唤醒。

### Added

- Tailnet：`ephemeral` / `dialer-proxy` / `ip-version: ipv6-prefer`。
- Tailnet：本机 tailnet 地址展示。
