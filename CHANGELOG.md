# Changelog

本项目所有重要变更记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/)，版本遵循语义化版本。

## [1.4.0] - 2026-10-22

> 对标优化批次：连接决策链、一键规则、端口转发、设备身份、订阅统计、上手引导，外加两处规则表单修复。**Helper 仍为 1.0.30，本次未改协议，无需重装**。

### Added

- **连接详情四段式决策链**：来源 / 解析 / 规则 / 出口，用上内核 `/connections` 里原本被丢弃的元数据（`inboundName` / `dnsMode` / `sniffHost` / `providerChains` / `uid` / `remoteDestination`）。判定逻辑在 `ConnOrigin`（纯逻辑，`connorigin-tests`）。方案里「连接表可选『来源』列」这一小项**未做**，表格列保持不变。
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
