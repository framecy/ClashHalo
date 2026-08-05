# Changelog

本项目所有重要变更记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/),版本遵循语义化版本。

## [1.1.15] - 2026-08-05

围绕对端隧道共存的一组修复，两条来自一次 6.5 小时不间断运行时监控的实测捕获。Helper 仍为 **1.0.24**，本版**不需要重新授权**。

### Fixed

- **同一次拓扑变化重复下发 `tun` PATCH**：`reconcileCoexistenceIfChanged` 的去重只依赖 `lastCoexistenceFingerprint`，而该值直到 `patchConfig` 与 `callSetupExcludeRoutes` 两次 await 之后才写入。网络路径监视器成簇投递的回调都能通过 fingerprint guard，于是整段流程跑两遍，对内核连发两次 `tun` **整块替换** PATCH。监控在两次真实拓扑变化中均复现：10:34（Tailscale 自更新导致隧道接口 utun4→utun11）与 14:31（第二条隧道 utun10 接入），日志中「检测到网络拓扑变化」与「静态路由同步 成功」成对出现，两次回调相隔 85ms。现加 in-flight 标志；被合流掉的调用无需补跑，`verifyTUNConfig` 每 2 分钟会重新触发一次 reconcile。

- **PATCH 被内核静默丢弃后 reconcile 永久跳过**：`applyTUNState` 在 PATCH 之前就写 `lastCoexistenceFingerprint`，mihomo 丢弃时对端网段会被 auto-route 吞掉，直到拓扑本身再次变化才有机会恢复。fingerprint 现与 provenance 同门控：先 stage，confirm / restart 成功后再 commit，失败保持旧 latch 以便重试。关闭 TUN 时撤回 `route-exclude-address` 改用 `liveTunBlock()`（kernel → config.yaml 两级取值），避免 `configs` 空窗让 withdraw 空转、注入项残留在运行态。

- **系统代理开启时 Tailscale 反复 flap**：`login.tailscale.com` 与 `*.derp.tailscale.com` 经 mihomo 会让 tailscaled 的 QUIC 探路超时（`Connection exceeded max PTO count`）。`kProxyBypassDomains` 追加 `*.tailscale.com` 与 `100.100.100.100`。作用域**仅系统代理**；纯 TUN 路径仍由 `tun.route-exclude-address` 与 `CoexistencePlan.dnsAdvice` 负责，注释已写明以免误当 TUN 修复。已安装的 Helper 编译进的是旧列表，但 `reconcileProxyBypassIfNeeded` 本就绕开 Helper 用 `networksetup` 直写，因此无需重装 Helper 即可生效。

- **`setSystemProxyFallback` 的 shell 注入路径 glob 展开**：`*.local` 等未加引号拼进 shell，CWD 下存在同名文件时会被展开，静默写残 bypass 列表。现对每项做 POSIX 单引号转义。Helper 与 GUI 路径走 argv，本就不受影响。

### Changed

- 预留 Tailscale Keychain 账户名（`kTailscaleAuthKey` / `kTailscaleAPIToken` / `maskTailscaleKey`）与 `TailscaleDevice` 模型，与订阅 URL 共用 `com.clashhalo.secrets` 服务但 account 隔离。本项无调用方，不改变运行时行为。

### Tests

- `Scripts/run-tests.sh` 91/92。唯一失败项 `Tests/RouteGuard` 的 `localAttachedSubnets — 本机实测`，断言运行机器的 en0 上存在 `10.1.1.0/24`；该网段在当前机器上属于 Tailscale 的 utun 接口而非 en0，故不成立。该断言读取实时网卡状态，与本版改动无关——在不含本版任何改动的 v1.1.14 提交上同样失败。

## [1.1.14] - 2026-08-04

启动与开关路径的一组修复，外加一条从真实日志追出来的根因。Helper 仍为 **1.0.24**，本版**不需要重新授权**。

主线是同一个类别的问题：**`PATCH /configs` 对嵌套对象是整块替换而不是深合并**，而 `tunPatchBody` 只重述了 `tun` 块 8 个字段里的 4 个。这条早就写在注释里的约束，实现上一直没有兑现。

### Fixed

- **开机自启后从状态栏开 TUN/系统代理，提示「请先导入配置」**：`model.start()` 只挂在主窗口的 `.onAppear` 上。登录项启动时 App 在后台运行，SwiftUI 不会实例化未上屏的 `Window` 场景内容，于是 `start()` 从不执行、`store.load()` 从不调用；而 MenuBarExtra 从第一帧就可点，两个开关取到空的 `profiles` 便报「请先导入配置」——配置其实好端端躺在磁盘上。改为在 `applicationDidFinishLaunching` 启动（`.onAppear` 保留为幂等兜底）。同一根因还导致内核不自启、不轮询、Dock 策略不生效。

- **App 异常退出后内核无法启动**：强退/崩溃不会执行 `AppDelegate.performCleanup`，mihomo 子进程被 launchd 收养后继续占用 mixed-port 与 external-controller。重启后用户态启动路径直接 spawn，新内核几毫秒内 bind 失败退出，而所有症状（「内核未响应」、就绪超时、开关无反应）都指向别处。新增 `reapOrphanKernels()`：用 `ps -o comm` **按可执行路径**精确识别本 App 管理的内核（不误杀其它客户端的 mihomo），SIGTERM→SIGKILL 回收，root 残留交由 Helper。动手前补一次 2 秒完整探测——原判据是 0.25s/0.3s 短超时，正在初始化的内核（载入 geodata 约 600ms）与死掉的看起来一样，误杀会把慢启动变成重启循环。用户态内核输出改接 `mihomo-user.log`，spawn 后 300ms 检查早退并记录内核自己的报错。

- **`tun` PATCH 静默丢失 `dns-hijack`**：`tunPatchBody` 从不重述该字段，因此每次走 PATCH 路径的 TUN 切换（内核已是 root 时的常规路径）都会把运行态的 `any:53` 劫持清掉。配置文件仍声明着，`/configs` 已经查不到，DNS 从此不再被捕获，直到某次重载文件才恢复。

- **`tun` PATCH 静默清空 `route-exclude-address`**：该字段此前只在检测到对端隧道时才附带。没有对端隧道时整份排除项——私网、组播、链路本地——被整块替换语义清空。

- **冷启动开 TUN 可能换栈**：`stack` 在 `configs` 尚未填充时回落到字面量 `"gvisor"`，会把 `mixed` 的配置悄悄换掉。所有字段改为「内核 → config.yaml」两级取值，不再有字面量兜底。

- **共存条目归属误判，撤回时删掉用户手写的排除项**：Tailscale 厂商条目输出 `100.64.0.0/10`，与 Tailscale 用户手写在 `route-exclude-address` 里的**是同一个字符串**；而 `commitProvenance` 记录的是整份计划，于是一次开启 TUN 就把用户条目改标为「本应用注入」，下一次关闭时 `withdraw` 将其删除——CGNAT 落入 auto-route，Tailscale 流量进错隧道，而配置文件里那行还在。现改为只记录**实际新增**的条目。已有的 `isProtectiveExclusion` 是同类问题（组播）的补丁，这次修的是整类。

- **`readConfigFile` 把行尾注释当作值**：`- 127.0.0.0/8   # 回环` 原样成为值，`mixed-port: 7890  # ...` 解析不出 Int 而回落默认端口。按 YAML 规则处理（只有前置空白的 `#` 才是注释），因此 mihomo 的 `100.100.100.100#utun8`（绑定出口接口）与 `https://dns.google/dns-query#默认代理`（绑定策略组）不受影响——按 `#` 直接切分会破坏这两者。

- **内核停止状态下无法关闭 TUN**：该路径去 PATCH 一个不存在的控制面，失败后 `tunOn` 从未清零、关闭级联也未执行，开关卡在「开」且无法拨动。现就地完成本地侧拆除：落盘 `tun.enable=false`、拆网关、恢复 DNS、清理 Helper 静态路由与残留 utun。

- **内核未运行时开启系统代理指向错误端口**：`proxyPort` 在 `configs` 为空（冷启动或用户停核）时返回硬编码 7890，若订阅使用其它端口即为静默断网。改为先读 config.yaml，内核起来后再复读实际端口。

- **开 TUN / 开网关时系统代理断网**：用户态→root 的内核重启会让 mixed-port 消失数秒，而 macOS 在代理端口无应答时不会回退直连，是硬断网；重启失败则是永久断网。内核切换路径自 v1.0.18 起就括起了这个窗口，TUN 与网关的 root 切换一直没有。新增 `withSystemProxySuspended`，恢复以内核可达为前提。

- **访问控制与局域网网关互相拆台**：两张卡片写同一批 mihomo 字段。`allow-lan: false` 或非通配 `bind-address` 会把 DNS 与 mixed-port 监听从局域网上摘下来，网关开关却仍显示「开启」；`authentication` 要求透明转发流量提供根本无法提供的凭据。现在网关运行期间拒绝前两者并说明原因，`authentication` 自动补齐 `skip-auth-prefixes` 的 RFC1918 网段（只增不删，开启网关时同样生效，两张卡片的使用先后不再影响结果），IP 过滤器只警告不覆盖——那是用户的主权设置。`bind-address` 一并纳入网关的快照与恢复。

- **SD-WAN「修复路由冲突」按钮**：同样省略 `route-exclude-address`，且无论 PATCH 成败都无条件 `commitProvenance`。

### Changed

- **流量历史按轮次批量写入**：此前每个活动连接每轮调用一次 `history.record`，每次都要把整个 `Day`（含 24 元素小时数组）拷出改回，而且它是 `@Published`——繁忙内核上每轮就是上千次数组拷贝加上千次 SwiftUI 失效，只为三个可以先求和的数。连接页 1.5 秒一轮，是最热的调用方。`todayKey` 的 `DateFormatter` 调用同时改为按日缓存。
- **注入 `geodata-loader: memconservative`**：mihomo v1.19.29 起该值已是默认，此项仅在切换到旧内核时兜底。
- `liveTunBlock()` 整块读取 `tun`：按字段读会让 32KB 的 config.yaml 在每个 PATCH body 上重复行扫描十余次。

### Tests

- `Tests/YamlScalar`（19 项）：行尾注释剥离，且 `#utun8` / `#默认代理` 两种绑定语义、引号内的 `#`、流式数组均不受影响。
- `Tests/CoexistenceProvenance`（28 项）：以真实部署的排除项列表为输入，断言开关一轮 TUN 后用户条目全部存活、仅本应用注入的条目被撤回；其中一项专门断言**旧写法确实会删掉用户条目**，防止测试本身失效。
- 为此将 `YamlScalar` 与 `CoexistenceProvenance` 拆为独立文件——按本仓库既有约定，测试编译真实生产源码而非复刻规则，而原文件经 `Models.swift` 牵连到 SwiftUI 无法单独编译。

## [1.1.13] - 2026-07-28

修正 v1.1.12 数据面探针的一个致命盲区：**半死的 TUN fd 永远触发不了自愈**。同时补两处信息密度问题——连接页被单域名的几十条会话淹没，网络拓扑页的接口与路由卡片逐条平铺。Helper 仍为 **1.0.24**，本版**不需要重新授权**。

### Fixed

- **半死 fd 逃过自愈，日志只是一直刷**：macOS 在 mihomo 底下重挂 `utun100` 后，读方向的 goroutine 会拿着失效 fd 持续 `bad file descriptor`，而写方向偶尔仍能把一次探测请求跑通。v1.1.12 的状态机是**连续失败计数**——一次成功就清零，于是「大部分失败、偶尔成功」这种最典型的半死形态永远攒不够连续失败数，内核从来不会被重启，用户看到的就是日志一直刷、网却不通。

  改为**滑动窗口**：`TUNDataPlaneHealthState` 保留最近 `window`（默认 6）次探测结果，窗口内失败数达到 `failThreshold`（默认 4）即触发自愈。一次成功不再清空窗口，只是稀释失败比例。按每轮约 3 秒的重试节奏，半死 fd 在 **约 10 秒**内被判定，而不是拖到下一次 10 分钟巡检、乃至永远不触发。

- **探测提前收工，证据不够定性**：`runTUNDataPlaneProbe` 原本一遇成功就 break，半死 fd 恰好在这一次答上就整轮记成健康。现在一轮内**每次尝试都记入窗口**；`runTUNDataPlaneProbeCycle` 默认跑 5 次，只有**首次尝试即刻应答**才短路返回（健康链路不必浪费几秒）。
- **窗口只在完整健康时清空**：`reset()` 现在要求一整个满窗口全部成功（`allHealthy`）才执行，避免自愈判定被一次侥幸成功抹掉。

### Added

- **连接页「聚合」视图**：iCloud 推送、遥测这类流量会对同一个网关（如 `gateway.icloud.com`）开出几十条独立会话，把连接表整个淹掉。新增第三个 tab，按 **host 聚合**（裸 IP 流量回落到 `dstIP`）：显示会话数量胶囊、上下行速率求和、进程名合并，点击行内展开逐条会话详情。行尾 `⋯` 菜单提供「断开该域名全部」与「添加/修改分流规则」。

  已关闭连接**故意不纳入**聚合——它们速率恒为 0，只会稀释视图。`AppModel.closeConnections(host:)`：mihomo 没有按 host 关闭的接口，实现为枚举缓存中匹配该 host 的活跃连接逐个 `DELETE`。

- **网络拓扑页按出口折叠为 mini-card**：「网络接口拓扑」与「UTUN 路由表」两张卡片此前一条路由一行，单个 utun 承载多个前缀时直接刷屏。现按 **utun 出口分组**（`SdwanRouteGroup` + `aggregateByIface()` / `routeGroupsByIface()`），两张卡共用同一套 role/name 排序键，因此左右互为镜像。
  - 分组头与展开体裹在同一层嵌套控件表面内，点击头部任意位置折叠整组。
  - 角色改由**卡片描边**（1.2pt 着色）承载，不再占一个文字 chip；数量胶囊降级为 14% 着色底 + 着色文字。
  - 叶子出口（不承载任何 tun 路由的物理网卡）不画 chevron，用**虚线描边**表示「终端节点，无下挂」。

### Tests

- `Tests/TUNDataPlaneProbe` 重写为滑动窗口语义：失败累积期间穿插成功仍应触发自愈；失败滚出窗口后计数下降；`allHealthy` 只在满窗口全成功时为真。

## [1.1.12] - 2026-07-27

修复 macOS 网络拓扑变化后 **TUN 接口仍在、路由表也正常，但数据面已经死掉** 的故障：`configd` 重挂载 `utun100` 后，mihomo 可能持有失效的 TUN 文件描述符（`bad file descriptor / file already closed`），现有「接口是否存在」检查发现不了。本版新增本地 DNS 数据面探针与整进程自愈；重建仍失败则关闭 TUN 并恢复直连。Helper 仍为 **1.0.24**，本版**不需要重新授权**。

### Added

- **TUN 数据面 DNS 探针**：向本地 fake-ip 网关（默认 `198.18.0.1:53`）发送最小 UDP DNS 请求，校验 transaction ID、响应长度、QR 位。NXDOMAIN/SERVFAIL 只要格式有效，仍视为数据面存活——问题是「fd 是否还能收发包」，不是「名字是否解析成功」。
- **短窗口连续失败确认**：单次巡检任务内短间隔重试（约 1s / 2s），总检测时间控制在数秒内；不再依赖「连续三轮 10 分钟巡检失败」才行动。
- **整进程自愈**：确认数据面死亡后，`PATCH tun off` → 停止 mihomo → 清理自有 TUN 残留 → root 重启 → 等待控制面与 `utun100` 就绪 → 重新同步共存路由 → 二次 DNS 验收。**不用纯 PATCH 开关 TUN**——PATCH 不能保证重新打开失效的 TUN fd。
- **二次验收失败回退直连**：重建后 2–3 次短间隔探测仍失败，则停止自动循环、关闭 TUN、清理残留、恢复系统 DNS，并给出明确提示。**不关闭用户原本开启的系统代理**。
- **状态机与防抖**：`tunDesired`/settle window/`isBusy`/recovery in-flight/cooldown/用户关 TUN 取消探测。拓扑变化本身不直接重启——正常 `detach/attach` 也会发生，只有探针确认后才重建。一次异常最多一轮自动修复。
- **单元测试** `Tests/TUNDataPlaneProbe`：DNS 响应校验与连续失败状态机，直接编译生产源码。

### Fixed

- **网络切换 / 睡眠唤醒后「看起来正常却上不了网」**：接口表与路由表仍显示 `utun100` UP，但 mihomo 写包命中失效 fd。现由巡检、拓扑变化防抖、开启验收、唤醒恢复四条路径触发数据面探测。
- **自愈不会误伤第三方路由**：残留清理只动本应用 TUN / 自有记账；SD-WAN、Tailscale 既有路由保持不动。

## [1.1.11] - 2026-07-26

修复网关模式下**看直播、刷网页反复中断**的根因：启用网关这一动作会触发应用自己的残留清理，把刚写进去的配置当成上次会话的残渣撤销掉，随后的自愈把内核反复全量重载；同时修正网关「已接入设备」的速率与总量统计——此前的读数取决于你开着哪个页面。Helper 仍为 **1.0.24**，本版**不需要重新授权**。

### Fixed（严重）

- **启用网关会自我撤销，并引发十分钟内九次内核全量重载**：`applyGatewayMode(true)` 先写入 `dns.listen: 0.0.0.0:53` 并重载，再调用 `refreshConfigs()`，而 `gatewayModeOn = true` 要到之后才落定。`refreshConfigs` 的残留清理分支判据是 `!gatewayModeOn && dns.listen == "0.0.0.0:53"`——于是它把**刚刚写进去的配置**认成上次会话的残渣，清回 `127.0.0.1:1053`。接着健康检查发现 53 端口没有监听，开始「修复」，每次修复都是 `PUT /configs?force=true`：重建 DNS 服务器、重建全部 inbound/outbound、重建 TUN 接口、**断掉所有在途连接**。

  实测取证：22:04:55–22:14:05 十分钟内 **9 次全量重载 + 2 次 TUN 重建**，形状两回合完全一致（清理 → 配置丢失 → 两次重试 → 放弃）。这是确定性的，不是竞态。日志里也看不出是自己人干的——清理和修复各打各的日志，没人把两者联系起来。

  修复：新增 `gatewayApplyInFlight` 事务标记，覆盖启用流程的全部提前返回路径（放弃的事务必须让残留检测重新武装，否则半启用的网关永远清理不掉）。

- **开启 TUN 会立即重建一次自己刚建好的隧道**：创建 utun100 并注入排除路由**本身就是一次网络路径变化**，`NWPathMonitor` 在几毫秒后如实上报。处理器把它读成「物理网卡切换了」，于是重建隧道——两次 `PATCH(enable=true)` 相隔 250 毫秒，每次都断掉全部连接。`tunStateSettleUntil`（10 秒稳定期）本来就守着另外四个消费方，唯独漏了这个唯一会用「重建整条隧道」来回应的。

  修复：重建条件加上稳定期守卫，并把 `lastInterface` 的记录移出分支无条件执行——否则稳定期内被跳过的那次变化会留下陈旧值，等窗口一关照样触发重建。代价明说：稳定期内真实的网卡切换（Wi-Fi→有线）会被推迟，由 30 秒巡检在窗口关闭后补上，是延迟不是丢失。

- **网关自愈死循环**：`verifyGatewayConfig` 探测不到 53 端口监听就重载，无上界、无实测判定，并且**无条件**打印「网关配置已自动恢复」（它实际只表示 HTTP 调用返回了）。实测 16:35–19:43 连续 **113 次**，每 63 秒一次。时间关联：19:25:08 重载 → 19:25:16 YouTube DNS 全挂；19:31:23 重载 → 19:31:31 IMAP 超时。

  修复：重载上界 2 次；改为 reload 后重新探测来判定；放弃时用 `udpPort53Bindings()` 报出 53 端口的真实占用情况。配置漂移路径另加指数退避（2/4/8… 分钟，上限 15 分钟）——若配置文件被订阅更新或配置切换持续覆盖，每分钟跟它对打帮不了任何人。

- **网关明明正常却一直报错**：`gatewayRepairAbandoned` 同时关掉了「重载」和「检查」，而只有前者需要关掉。于是监听后来自己恢复了也没人发现，放弃时那条错误信息就永远挂着。实测状态：`netstat` 显示 `udp46 *.53` 已绑定、`dig @<本机局域网IP> example.com` 正常应答、局域网设备代理一切正常，而应用仍显示一小时前的「已停止自动重试」。

  修复：放弃后仍每 5 分钟静默复查，监听恢复即自动解除并记录 `网关 DNS 已恢复在 53 端口监听`。**不再需要手动开关网关模式来复位。**

- **reload 后的监听探测过早**：`PUT /configs?force=true` 返回代表内核**接受**了配置，重建 DNS 服务器、以 root 重新绑定 `0.0.0.0:53` 都在之后。原来在 reload 返回后 **329 毫秒**探测，量到的是重建过程中的空档而非结果，一个其实成功了的修复被记成失败，两次就永久放弃。改为最多等待 8 秒、每 500 毫秒轮询，绑上即返回。

### Fixed（网关已接入设备统计）

- **速率读数取决于你开着哪个页面**：`uploadRate` / `downloadRate` 存的是两次轮询之间的**字节增量**，却按 B/s 显示。而轮询间隔是变的——连接页 1.5 秒、其他页 3 秒、后台 30 秒——同样的流量因此读高 1.5 / 3 / 20 倍。现按实测经过时间做除法。
- **总量显著小于内核**：总量由每次的增量累加而来，新连接第一次采样没有基线故记 0，而局域网流量绝大多数是**在两次轮询之间出生又死掉的短连接**，它们的字节从头到尾一次都没被计入；连接关闭时的尾部字节也直接丢弃。现改为 `Σ 活跃连接绝对字节数`（直接取自 mihomo）**＋** 每设备的已关闭连接累加器：连接关闭时字节从第一项挪到第二项，总量连续、速率不出现假峰。累加器用独立字典而非复用 `prevConnBytes`——后者会被内存守卫裁剪清空，丢一条就等于吞掉一台设备的全部流量。

### Added

- **定时路由巡检与自动修复**：对端隧道（Tailscale、SD-WAN）的网段被本机 utun100 抢占时自动夺回。触发器独立于共存**指纹**——指纹看不见 auto-route 抢占，因为 peer 集合并没有变化。修复走 Helper 既有的 `route delete` / `route add`，**不重载内核、不断连接**，并在「网络拓扑」页展示逐条修复详情（绿 ✓ 已修复 / 橙 ✗ 未生效）。判定以路由表为准而非 Helper 的回复。
- **仪表盘「网关已接入设备」卡片**：按当前速率降序（网络页仍按最近活跃排序）。网关关闭或无设备接入时整张卡片不渲染，版面与原来完全一致。
- **设备列表在屏时提高刷新频率**：网络页或仪表盘可见时 `/connections` 每 **1 秒**拉一次，否则维持 3 秒。轮询循环从「数 tick」改为「按截止时间」——原来的计数器方案一旦提速，30 秒的健康检查会跟着变成 10 秒，网关修复路径的内核重载次数翻三倍，等于用掉线换一个流畅的读数。
- **`RouteTable.drift()`**（`Sources/XPC/HelperProtocol.swift`，GUI 与 Helper 共同编译）与 9 项回归测试，基线取自真实被抢占的路由表。判据刻意窄：被**第三方**接口承载的前缀一律不动——覆盖别人的路由决策正是 v1.1.9 修过的那类伤害；作用域路由先行滤除，它们只对已绑定到该接口的流量生效，从来不是「谁承载这个网段」的答案。
- **`EngineControl.udpPort53Bindings()`**：诊断用，只在失败路径调用。「声明了 `0.0.0.0:53` 却没有监听」有两种完全不同的成因——端口被别的解析器占了，或 mihomo 自己没绑上——此前的修复循环分不出来。

### Changed

- 8 小时实机监测（480 样本）：对端网段被抢占 **0/480**；路由巡检运行 48 次、零漂移零误报（采样脚本独立核验，两个实现互相印证）；应用内存 8 小时呈下降趋势、无泄漏；XPC 连接 **83 次/小时**（v1.1.9 为 720 次/小时）。

> 已知未闭环：路由修复分支（`route delete` 夺回）在真机上仍未被触发过——8 小时零漂移，目前只有单元测试覆盖。另：若你的 `config.yaml` 用的是 `log-level: silent`，内核侧几乎不产生日志（实测 8 小时仅 10 行），建议改为 `warning`，否则下次异常只能靠外部工具反推。

## [1.1.10] - 2026-07-25

修复长时间运行 TUN 后网络变慢、网关模式失效的严重问题：对端隧道的**接口作用域路由**被重装成全局路由，把本机局域网与全部组播劫持进了对端隧道。Helper **1.0.23 → 1.0.24**，升级本版**需要一次管理员授权**。

### Fixed
- **本机局域网与组播被劫持进对端隧道（严重）**：Tailscale 这类对端会把它承载的网段登记为**接口作用域路由**（`RTF_IFSCOPE`）——只对已绑定到该接口的流量生效，全局不承载任何东西，是刻意的良性设计。共存模块采集时未区分作用域，原样交给特权 Helper，Helper 用 `route add -interface` 装成了**非作用域全局路由**，于是一个刻意的空操作被改写成真实劫持。

  实测取证机器：本机局域网 `10.1.1.0/24`、全部 IPv4 组播 `224.0.0.0/4` 被指向 utun8，en0 自己的子网路由被顶掉，`route -n get 224.0.0.251` 返回 `utun8`。
  - **网络变慢**：访问局域网设备（NAS、打印机、路由器）与 mDNS/Bonjour/DHCP/SSDP 发现全部绕行对端隧道，要么经广域网折返，要么黑洞超时。
  - **网关模式失效**：网关模式下给 LAN 客户端的回包按路由表走进隧道而非物理网卡，客户端收不到响应。

- **故障永不自愈的三个机制**：
  - Helper 的自有路由记账是**纯内存**字典。Helper 因应用升级重启后记录随进程消失，这些路由成为无人认领的孤儿（实测存活 16 小时）。现已落盘至 `/Library/Application Support/ClashHalo/added-routes.plist`。
  - `staticRoutesInjected` 是一次性闩锁，TUN 保持开启期间永不重新求值。
  - 重收敛只挂在网络路径变化上，而对端接受/撤销子网**不改变默认路由**，因此从不触发。现接入 30 秒巡检并同时重推静态路由，指纹门控保证拓扑不变时零 PATCH。

- **网关健康检查读错数据源**：`verifyGatewayConfig` 比对 `configs["dns"]["listen"]`，而该键由 `refreshConfigs` 从 config.yaml **磁盘内容**填充（mihomo 的 `GET /configs` 不返回 `dns`），等于拿文件跟自己比。发现不了「文件声明 `0.0.0.0:53`，但 mihomo 绑不上端口、无人应答」这类静默失效。新增 `*:53` 运行时探测（60 秒节流）。

- **冲突检测误报对端作用域路由**：`isNonShadowing` 只用在 TUN 侧未对称用在对端侧，把 Tailscale 的作用域 `255.255.255.255/32` 报成「被 TUN `240.0.0/4` 遮蔽」。作用域路由不参与最长前缀竞争，遮蔽不了。更需警惕的是它会引诱「一键修复」把广播地址喂进排除路径——正是本版修复的那类伤害。

### Added
- **`PeerRouteGuard`**（`Sources/XPC/HelperProtocol.swift`，GUI 与 Helper **共同编译**）：链路专用前缀（回环、链路本地、组播、广播）与**本机直连网段**一律不得指向隧道。GUI 决定请求什么、Helper 决定安装什么，两侧执行同一条规则——规则只在一侧生效就是缺口。实测有效：旧版 GUI 请求三个毒化前缀，新 Helper 全部拒绝。
- **孤儿路由回收**：`reclaimOrphanedPeerRoutes()` 直接以路由表为准，因此也能清理记录已丢失的孤儿。归属判据是 `Gateway` 列重复接口名（`route add -interface` 独有形态，对端自己的指向 `link#32`），且只动**非作用域**路由——不会重蹈 v1.1.9 修过的「摧毁对端隧道路由」。删除后把网段**归还直连网卡**：仅删不补会让局域网彻底没有路由，比劫持更糟。
- **IPv6 守卫**：`IPPrefix` 经 `inet_pton` 解析，跨协议族恒不重叠，v6 链路专用前缀与直连网段纳入判据。用户手写的 `fe80::/10` / `ff00::/8` 因此进入撤回保护。（v6 路由采集与安装未实现，守卫先就位。）
- **回归测试** `Tests/RouteGuard`（83 项）与 `Scripts/run-tests.sh`。直接编译生产源码 `HelperProtocol.swift`，基线用例取自故障机器的真实路由表。

### Changed
- **UI 重绘风暴**：`AppModel` 挂 44 个 `@Published` 且被 12 个视图观察，`ObservableObject` 的语义使流量 WebSocket 每秒一次的推送让整棵视图树重新布局。抽出 `LiveMetrics` 嵌套 `ObservableObject`，消费方直接观察它。**同负载 A/B 实测 GUI CPU 中位 10.4% → 1.7%、均值 11.4% → 3.0%。**
- **特权调用大幅削减**：Helper 状态轮询 5s → 60s（实测四天 6 万次握手，每次含整个 app bundle 的签名校验，未观测到任何状态变化，helper.log 因此涨到 24 MB）；网关 sysctl 改为先用免特权的 `sysctlbyname` 读取再决定是否下发，2 小时 240 次 → 23 次。

> ⚠️ **升级提示**：若你此前运行过 v1.1.8/v1.1.9 并使用 Tailscale 等对端隧道，本机路由表可能残留被劫持的网段。新版 Helper 启动后会自动回收并归还直连网卡，可在 `/Library/Logs/ClashHalo/helper.log` 中搜索 `reclaimOrphanedPeerRoutes` 确认。

## [1.1.9] - 2026-07-23

固定 TUN 设备名，消除与本机其它虚拟接口的身份与命名冲突；修复排除路由会摧毁对端隧道路由、以及「一键修复」会关掉 `auto-route` 导致 TUN 无网络两个严重问题；新增「清空全部配置」与「对端网段不可达」检测。

Helper **1.0.22 → 1.0.23**，升级本版**需要一次管理员授权**。

> ⚠️ 若你已下载过本版早先的 build 63，请更新到 build 64：build 63 含下述「排除路由摧毁对端路由」与「一键修复关闭 auto-route」两个问题。

### Fixed（严重）
- **排除路由的拆除会删掉对端隧道自己的路由**：调用方从路由表收割对端前缀交给 Helper，而 Helper 把「调用方要求的全集」原样记为已安装——`route add` 成功与否不影响记账——拆除时照单全删。收割来的本就是对端自己安装的路由，于是每次关闭 TUN 都在替对端删路由。tailscaled 只在 netmap 变化时重新下发，没有任何东西会把它们放回来；而下一轮检测因为路由已不在表里，连自己毁掉的前缀都看不见了。现场表现为 Tailscale 广播的 `10.1.1.0/24`、`192.168.3.0/24` 永久消失，`ping 10.1.1.1` 走物理网卡，页面却显示「拓扑正常」。

  现在：已存在且出口一致就不碰、不记账；只记录自己真正创建成功的；删除前重新核验路由仍指向当初装的接口；全量清理改为增量 diff。唯一例外是本应用自己的 TUN 抢占了对端前缀——那才是我们该纠正的。
- **「一键修复」会关闭 `auto-route`，导致 TUN 开着却没有网络**：`auto-route` 一关，mihomo 照样建出 utun 却不装任何路由。触发它的两处误判都会自我触发——`hasDefaultViaTun` 见到任何 utun 上的 `default` 就判为劫持，而 NetworkExtension 形态的 VPN（Tailscale 的 macOS app）装的是**作用域限定** default（`RTF_IFSCOPE`），不抢全局；mihomo 自己的 auto-route 同样会装一条 default，于是开了 TUN 必然指控自己。现在只报告「非作用域、且不在本应用 TUN 上」的 default，并且不再提供任何「修复」：抢占方在别的隧道，关自己的 auto-route 不是修复。
- **冲突检测把任何 198.18 接口当成本应用的 TUN**：实测本应用 TUN 关闭时，页面报出 10 条「我们遮蔽了 Tailscale」，实际比较对象是另一个代理应用的 utun。现按固定设备名精确认定。同时把 `default`（前缀 0）与作用域路由排除出遮蔽判定——前者永远不会赢过对端的 /10 或 /24，但会让每一条对端路由都被判为被遮蔽。
- **netstat 接口列取值错误**：带尾部 Expire 列的 ARP 行（`169.254 link#7 UCS en0 !`）会把接口名解析成 `!`，使这些路由静默掉出所有比较。

### Added
- **对端网段不可达检测**：路由表扫描对这类故障天生是盲的——缺失的路由不贡献任何条目，「对端已不可达」与「对端从未广播」同形。改为向 `tailscale status --json` 的 `PrimaryRoutes` 提问，与本机路由表比对后单列一张卡片。**只检测不代为安装**：把对端实际没在承载的网段排除出 TUN 只会让它走物理网卡；代装路由则会与对端的路由管理相互覆盖。

### Fixed
- **netstat 缩写目的地被当成 /32，排除规则过窄、冲突检测近乎失效**：`netstat -rn` 把目的地缩写到掩码覆盖的字节数，只有掩码不是该字节数的自然值时才补 `/len`——`192.168.3` 是 `192.168.3.0/24`（`route -n get 192.168.3.55` 实测 mask `255.255.255.0`），`126` 是 `126.0.0.0/8`。`parseCIDR` 此前对无 `/len` 的形式一律按 `/32` 处理，后果有两处：
  - 对端子网只被排除了一个主机地址。实测线上内核里注入的是 `192.168.3.0/32`，Tailscale 子网路由的其余部分仍被 TUN 抢走。
  - mihomo `auto-route` 下发的 `/8` 级聚合（`1`、`11`、`101`、`126` 等）被算成 `/32`，`conflictingRoutes` 的 `tunPfx <= sdwanPfx` 判据永不成立，**遮蔽冲突检不出来**。带显式 `/len` 的条目（`12/6`、`16/4`）本就正常，故影响面精确限于这批不带前缀的聚合。
- **macOS 系统隧道被当成需要共存的 peer**：`Coexistence.detect()` 只排除自己的 TUN，于是 iCloud 私密代理、Wi-Fi 通话、接力等系统 utun（无 IPv4 地址、无 IPv4 路由，只有链路本地 IPv6）全部变成「虚拟接口 utunN」泛型 peer。它们贡献 0 条排除规则，却随系统服务重连不断增删，把 peer 列表和日志刷满。实测本机由 9 个 peer 降为 1 个（仅 Tailscale）。

### Added
- **固定 TUN 设备名 `utun100`**：内核不再接受「下一个空闲编号」，而是每次都要走同一个名字。解决两类冲突：
  - **身份**：fake-ip 段 `198.18/15` 是约定而非分配，Shadowrocket 等同类应用的 TUN 同样落在 `198.18.0.1`，仅凭地址无法区分自己和别人的接口（实测：mihomo 已停止，仍有一个外部 `utun8` 持有 `198.18.0.1`）。固定名后 `mihomoTunInterface()` 按名精确识别。
  - **命名稳定**：BSD 按创建顺序分配 utun 序号，周围隧道一抖动就改名，这正是 config.yaml 里手写 `#utunN` 绑定隔夜失效的根因。
  
  内核若拒绝或忽略该字段，TUN 会表现为「未出现」；此时自动落 `tun.device.pinUnsupported` 标记、放弃固定名重试一次，最坏退化为旧的内核分配行为，不会开不起来。**实测 mihomo 接受该字段**：`device = 'utun100'`，接口 UP、mtu 9000、53 条路由，回退未触发。
- **DNS 出口绑定漂移检测与修复**：`nameserver-policy` 里 `100.100.100.100#utun0` 这类绑定必须写死接口名（TUN 开启后出口被钉在物理网卡，不限定接口的查询会超时），而接口名会随重启变化。SD-WAN 页现在比对配置中的绑定与对端实际所在接口，漂移时给出「修复出口绑定」——改写 config.yaml 并重载，先备份 + `mihomo -t` 校验，任一步失败整文件回滚。仍是**显式操作**：重载会重启解析并断开连接，不隐式触发。
- **清空全部配置**：配置页工具栏「清空全部」，二次确认后删除所有配置文件、订阅链接（含 Keychain 条目）、生效中的 `config.yaml`，以及由这些配置派生的内核缓存（`providers/`、`ruleset/`、`proxies/`、`cache.db`）。内核二进制、面板资源、geo 数据与流量历史保留。
  
  顺序是**先停运行态、再删文件**：文件先删的话，系统代理会指向死端口、TUN 会替一个没有配置的内核霸占默认路由，两者都是全网断网，而且用户已经没有配置页可以自救。因此先关 TUN（撤回共存排除规则、恢复系统 DNS）→ `stopEngine()`（关网关、关系统代理、清 Helper 静态路由、清 TUN 残留、停内核）→ 才动存储。
  
  root 内核会把 `proxies/` 留成 root 属主，用户态删不掉其中的文件；这种情况会**如实上报**「需管理员权限，已保留」，而不是谎报清空成功——为清缓存给 Helper 开一个「以 root 删除任意路径」的接口不值当，残留也会被下一个内核覆写。

### Changed
- **清空后的三个连带路径**（不改就是死路）：
  - `selectForApply` 原本只会 `reloadConfig`，内核已停时必然失败——清空后导入新配置点「应用」会直接报配置错误。现在检测到内核未运行就改为以新配置启动内核。
  - 启动时若无配置则**不自动拉起内核**。`ensureInstalled()` 见 `config.yaml` 缺失就重建出厂配置，否则清空后重开 App 会凭空起一个跑着占位配置的内核。
  - 新增 `config.wiped` 标记：`load()` 见 manifest 为空会从 `config.yaml` 播种「默认配置」，没有这个标记清空活不过一次重启。任何导入都会清除该标记。
- 无配置时开启系统代理 / TUN 会明确提示「请先导入配置」，而不是让内核启动超时后归咎于权限或路由冲突。

## [1.1.8] - 2026-07-22

修复控制面密钥每次启动被自动替换（外部面板反复要求登录的根因），并重构 utun 共存能力，修复局部 `PATCH` 会把 TUN 关掉。Helper 仍为 **1.0.22**，升级本版**不需要再次输入管理员密码**。

### Fixed
- **控制面密钥每次启动被自动替换**：v1.1.7 引入的 `isWeakSecret()` 按「长度 <16 / 字符类别 <3」整形判弱，而 `hardenControllerConfig` 每次 App 启动都据此重写 `secret`。后果是你在「网络 → 内核 → API 控制」里设的密钥每次重启都被换成新随机值，Zashboard 等外部面板保存的凭据随之失效，表现为**每次开 App 都提示未授权、要重新登录**。
  
  现改为区分两件事：`isReplaceableSecret` 只认空值与出厂占位常量（`clashhalo` / `mihomo` / `admin` 等，且必须完全匹配）——出厂常量人人可知，是真实攻击面；`isWeakSecret` 降级为纯提示，只写日志不再覆盖用户的选择。`configNeedsNormalizing` 同步改用同一判据，否则它会认为仍需规范化，每次启动重跑一遍整份配置的读写。
- **改密钥后不重启内核则不生效**：mihomo 的控制面密钥是进程启动时一次性绑定的，config reload 不会重新绑定，此前在设置里改密钥是个空操作。`hardenControllerConfig` / `ensureInstalled` 现返回被替换掉的旧密钥，供调用方在替换后把新配置推给可能仍存活的旧内核（崩溃 / 强退 / root TUN 跨会话存活），避免文件、内核、客户端三方对密钥各执一词。
- **局部 PATCH 会关闭 TUN**：mihomo 的 `PATCH /configs` 对嵌套对象是**整块替换而非深合并**——只发 `tun:{route-exclude-address:[...]}` 会让 `enable` 变回 false、`device` 清空，即每次共存同步都把 TUN 关掉。新增 `tunPatchBody()` 强制重述完整 `tun` 块，共存同步、SD-WAN 页「一键修复」、TUN 回滚三条路径统一修正。
- **TUN 开启失败后的分裂状态**：内核已接受 `enable=true` 但 utun 未在等待窗口内出现时，此前只改配置文件、不回滚运行中的内核，导致内核仍在跑 TUN 而开关显示关闭，流量被导进不存在的隧道 → 一堆 utun 连接且断网。现在会先自动重试一次「持久化 + 重启」这条已知可靠路径（这正是「第一次点击失败、第二次才成功」的成因），仍失败才完整回滚。
- **无关隧道被误判为 Tailscale**：移除 `sdwanExcludeRoutes` 中「只要存在任意 utun 就断言 `100.64.0.0/10`」的兜底，它会把真实运营商 CGNAT 流量踢出代理。

### Changed
- **重构 utun 共存（新增 `Sources/Model/Coexistence.swift`）**：原实现只在「开启 TUN 的那一刻」把 SD-WAN 前缀并进 `route-exclude-address`，且只增不删、无归属标记；VPN 在 TUN 之后连接、对端新增子网或断开，排除规则都不会更新，断开的前缀永久残留且无法与用户手写条目区分。现在：
  - **分层取证检测**：已知守护进程在跑 + IP 段匹配才认厂商；否则退化为通用 peer，仍从路由表收全前缀——WireGuard、企业 VPN 等不在注册表里也能获得完整路由排除。
  - **归属追踪**：记录上次注入集合，merge 时算出用户手写条目并保留，撤回时精确移除自动条目。`commitProvenance` 只在内核确认接受后调用，PATCH 失败不推进记录，重试仍然有效。
  - **指纹门控**：拓扑未变则完全不发 PATCH。
- **DNS 层只提示不自动改**：经实测确认无法安全自动处理——`PATCH /configs` 对 `dns` 返回 204 但完全不生效，`GET /configs` 又不暴露 `dns`，既写不进也无法安全合并；唯一可行的「改文件 + reload」会重启解析并断开连接，不应隐式触发，更不该静默改写用户自己选择的解析器。因此需要的改动只经 `dnsAdvice` 写进日志，由用户决定是否采纳。
  > Tailscale 主机名解析失败需手动改三处：`fake-ip-filter` 用 `"+.ts.net"`（原 `"*.ts.net"` 只匹配一级标签，对 `<host>.<tailnet>.ts.net` 从不生效）；`nameserver-policy` 下 `"+.ts.net"` 指向 `100.100.100.100#utun0`（必须是 MagicDNS 而非公共 DNS，`#utun0` 不可省，否则查询走物理网卡超时，接口名以本机 `ifconfig` 中带 `100.x` 地址的 utun 为准）。

## [1.1.7] - 2026-07-22

单一身份内核：消除 root/用户态混跑导致的数据目录属主撕裂（订阅、节点选择、geo 更新静默失效的根因）。Helper 仍为 **1.0.22**，升级本版**不需要再次输入管理员密码**。

### Fixed
- **数据目录属主撕裂导致订阅/设置静默失效**：内核此前时而以 root（TUN）、时而以用户（其余场景）运行。一次 root 会话会把 `cache.db`、`providers/`、`ruleset/`、`ui/` 与 geo 数据库留成 root 属主 + 0755，之后用户态内核**能读不能写**，于是：
  - `profile.store-selected` / `store-fake-ip` 不再持久化（实测日志 `[CacheFile] can't open cache file: permission denied`）
  - `geo-auto-update` 无法替换 root 属主的 `.dat`
  - 订阅 / 规则集刷新写不进缓存，provider 卡在 `not updated for a long time, force refresh` 死循环，表现为**订阅节点在 App 里消失**
  
  修复：Helper 可用时内核**一律以 root 启动**，全程单一身份，属主自洽（Helper 不可用才退回用户态）。
- **控制面弱密钥判定过窄**：`hardenControllerConfig` 原本只比对 6 个固定字符串，放过了 `1234qwer` 一类键盘走位密钥。控制面虽绑回环，但**本机任意进程**凭密钥即可完全操控内核。改为形态启发式 `isWeakSecret()`：长度 <16、含常见键盘/产品词、或字符类别少于 3 类即判弱并自动换成随机密钥。
  > ⚠️ 升级后若你的 `secret` 被判弱会被自动替换。App 与内置 Zashboard 入口会自动使用新密钥，但**其它保存了旧密钥的客户端需手动更新**。

### Changed
- **启动身份与升级重启解耦**：新增 `ensureRunningAsync(preferRoot:allowRootUpgradeRestart:)`。冷启动直接以 root 起（廉价）；把**运行中**的用户态内核重启成 root 很贵，故仅 TUN/网关允许，系统代理明确禁止——保住 v1.1.4 修过的「开关卡死」。
- **附带收益**：内核本就是 root 时，开启 TUN 不再需要重启内核，退化为一次配置变更。
- 清理 `hardenControllerConfig` 中只写不读的 `hasExtUI` / `hasExtUIName` 死变量。

## [1.1.6] - 2026-07-21

冷启动提速约 10 倍；修复「首次开启 TUN 必失败」；关闭全部转发面时断开既有连接；特权授权弹窗改为原生设计。Helper **1.0.20 → 1.0.22**（需强制升级）。

### Fixed
- **首次开启 TUN 必失败、第二次才成功**：根因不是等待不够，而是 **mihomo 对 `PATCH /configs` 先回 200、之后才决定能否应用**——当 PATCH 落在刚 root 重启、仍在拉取 proxy provider 的内核上时会被静默丢弃（实测 `tun.enable` 保持 false、utun 永不出现、等满 15s 报「权限不足」）。修复：
  - 需要 root 重启时**先把 `tun.enable: true` 落盘**，让内核在自身初始化阶段建好 TUN，彻底绕开 PATCH 竞态（下次启动的 `forceTUNDisabled()` 仍兜底，不会无授权自动开 TUN）。
  - 新增 `confirmTunFlagApplied()`：PATCH 后**读回 `/configs` 核对**而非采信 200，不一致按 150ms/400ms/800ms/1.5s 退避重发（覆盖内核已是 root、只走 PATCH 的路径）。
  - 开启失败时把 `tun.enable` 写回 false，不留残留。
- **等待逻辑三处缺陷**：`for i in 0..<min(maxAttempts, delays.count)` 使 `maxAttempts` 被静默截断（传 12 实际只等 8 次≈3.2s）；TUN 接口等待预算仅 4.4s；判失败前的「延迟重核对」读的是 1.5s TTL 内刚写入的 `nil` 缓存，**必然得出同样结论**（重试是空转）。已分别改为 backoff 阶梯用尽后重复末位、提高预算、并在决定性复核前 `NetScanner.invalidateTunCache()`。
- **旧会话清理误伤新会话（Helper 1.0.22）**：清理有两个入口，只有 watchdog 做了「新会话接管」检查，连接失效那条没有；且每个连接失效各触发一次（实测同一 pid 跑 2–3 次）。退出后快速重开 App 并开代理时，旧会话的延迟清理会**把新会话刚开的代理关掉**。现 `handleClientExit` 内置两道闸：**每 pid 只执行一次** + **新会话存活则让位**。
- **退出清理用了不可靠的缓存 XPC / 杀不掉 root 内核**：清代理走缓存 `helper()` 代理（本仓库多处记录其会静默丢调用），且 `killall -9` 以用户身份执行**杀不掉 root 拥有的 mihomo**（TUN 模式正是 root）。改为一次性全新连接、经 Helper 停 root 内核，并把顺序改为**先关代理 → 还原 DNS → 停内核**，消除「代理指向已被杀掉的内核」的断网窗口。
- **热启动误关系统代理**：并行化后 `residualCleanup` 可能抢在 probe 前读到过期的 `reachable=false`。改为 probe 完成后按结果分支。

### Changed
- **冷启动提速约 10 倍**：内核原先排在「Helper 握手 → 取版本 → 1s 空 probe → 清残留代理（XPC + 多次 `networksetup` fork）→ 还原 DNS」之后才启动，实测 3s 以上。现内核第一时间拉起，Helper 检查与残留清理并行；probe 超时 1s→0.25s；`ensureInstalled` 的 4 次全量读+解析+写 config 合并为 1 次读判定（稳态直接跳过）。**实测：内核就绪 0.31s，冷启动完成 1.32s，热启动完成 0.17s。**
- **关闭全部转发面时断开既有连接**：TUN 与系统代理都关闭后，已建立在 mihomo 上的 socket 仍会沿老路径继续传输（长连接尤其明显）。现在会主动断开全部连接以立即重新直连；**网关中枢开启时不触发**（那会破坏局域网客户端）。
- **特权授权弹窗重做**：由 AppleScript `display dialog` 换成原生 SwiftUI 面板（DS 令牌），含场景化图标、`v旧 → v新` 版本胶囊、要点列表、「下一步需要管理员密码」预期管理，卸载场景为红色 destructive；系统密码框仍归 OS。同时消除了把用户文案拼进 AppleScript 字面量的转义面。「取消不提权」契约不变。
- **新增 GUI 持久日志** `~/Library/Logs/ClashHalo/app.log`（2MB 滚动），与 Helper 的 `helper.log` 按时钟对齐；TUN 流程带分阶段耗时埋点。
- **菜单栏面板重构**：去掉「打开 ClashHalo」与「内核」开关，保留仪表盘，新增「打开 Zashboard」；空闲状态行显示「已连接 · TUN / 代理 / 网关」。
- **内核改为自动托管**：移除内核启停开关（菜单栏与网络页），启动即自动拉起（用户模式、不路由流量），开代理/TUN 按需自动处理。
- **「重启内核」不再无谓提权**：`restart(preferRoot:)` 按当前模式决定，纯代理会话保持用户态。
- **设计系统收敛**：新增 `DS.Palette.dyn(_:light:dark:)` 工厂收敛 25 处主题色样板（色值零改动）；删除无引用的 `cardBgAlt`；新增 `DS.Motion.resolve(_:reduce:)` 并让主窗口/菜单栏动画尊重系统「减弱动态效果」。
- **交互反馈**：`engine.isBusy` 期间主内容区显示常驻进度条与当前步骤（多步流程的中间提示不再一闪而过）；侧栏内核状态升级为连接中/已连接/未连接三态；新增「特权服务待更新」侧栏徽标。

## [1.1.5] - 2026-07-21

内核调用提速 + 两项修复（同版本号以 build 号重新发布）：TUN 开启后开关闪跳自动关闭；TUN/内核/系统代理开启时强退 App 导致断网。Helper **1.0.18 → 1.0.20**（需强制升级）。

### Fixed
- **强退 App 断网（Helper 1.0.20）**：两处根因——
  1. *客户端死亡感知不可靠*：Helper 的退出清理只在「强退瞬间恰好有 XPC 连接打开」时触发；App 与 Helper 几乎全部走 ~50ms 的一次性连接，强退大概率无连接在线 → 无人清理，root mihomo / 系统代理 / TUN DNS（198.18.x）全部残留，内核一退或重启电脑即断网。现改为 kqueue `NOTE_EXIT` 进程监视：任何 state 变更调用（startMihomo / 开代理 / 开网关 / 注路由）即布防对客户端 PID 的死亡监视，无论何种退出方式都会触发清理；2s 宽限 + 新客户端接管检测（活动连接或 15s 内新 PID 存活则让位，覆盖崩溃自启/覆盖安装场景）。
  2. *清理自身留 DNS 黑洞*：`killall -9` 杀 mihomo 可能留下 DOWN 的僵尸 utun，其 Supplemental DNS resolver 仍把系统 DNS 钉在 198.18.x（GUI 侧 v1.0.15 已修过的同款黑洞，Helper 退出清理路径漏了）。现清理流程加入 `cleanupTUNResidual(downedOnly:)` 物理清理（仅处理已 DOWN 接口，不误伤共用 198.18 段的健康 VPN）。
  - 顺带加固：清理按会话状态门控（没开过的不动，从不再把用户自定义 DNS 清成 Empty）；DNS 恢复仅针对仍钉在隧道网关的服务（`restoreDNSIfTunnelPinned`），不覆盖正常退出时 GUI 已恢复的用户 DNS；正常退出后残留的 root mihomo 同样被监视清理（此前用户态 `killall` 杀不动 root 进程）。
- **TUN 开启后开关闪跳自关**：TUN 拉起瞬间（utun 创建、auto-route 注入、系统 DNS 切换）触发 `NWPathMonitor` 风暴，多个并发 `refreshConfigs` 中任一瞬时假信号即把 `tunOn` 翻 false 并执行关闭级联（重复清理静态路由、撤销隧道 DNS），数秒后信号恢复又翻回 true——用户看到开关自动关闭、DNS 重定向状态脱节（`overridden=1` 但系统 DNS 已被还原）。修复：
  - **开启稳定期**：TUN PATCH 成功后 10s 内 `refreshConfigs` 不得把 `tunOn` 由 true 翻 false（翻 true 不受限）；用户手动关闭、停核、内核确认失联等显式路径不受稳定期限制。`verifyTUNConfig` / 接口丢失自动 teardown 同样尊重稳定期。
  - **refreshConfigs 并发合并**：并发调用合并到单个 in-flight 执行（helper 日志曾出现 3 次重复静态路由清理即为此竞态）。
  - **DNS 重定向状态机原子化**：`enableTunnelDNS` / `restoreTunnelDNS` 仅在 `networksetup` 写入成功后才置位/清位标记，失败保留状态待巡检重试，不再出现「标记已重定向但系统 DNS 未写入」的脱节。
  - **reconnect 瞬断二次确认**：内核上一刻可达时，单次 probe 失败先延迟 300ms 复测再判定失联，避免路径切换瞬间误触发「断连级联」（关 TUN 开关 + 还原 DNS + 关系统代理）。
  - **挂起重连任务清理**：重连成功时取消仍在休眠的旧重试任务，防止它数秒后突袭执行 `stopStreams + probe`。
- **TUN 等待去负缓存**：`waitForTUNInterface` 绕过接口探测的 1.5s 负缓存（utun 出现前一刻的 nil 会被缓存），开启等待不再固定多耗约 1.7s。
- **失败反馈静默**：系统代理 / TUN 操作失败且内核未运行时原本不弹任何提示（只写日志）；现明确提示「…失败（内核未运行）」；TUN 关闭遇内核已停则提示「已随内核停止关闭」。

### Changed
- **停核快路径**：`stopKernel` 在 REST 优雅退出 / SIGTERM 后用 `pgrep` 轮询确认进程已退（≤1.2s），确认后跳过 Helper XPC stop 与 `killall` 兜底及尾部等待；「内核本就未运行」的调用（崩溃后重启、内核切换）几乎零开销。未确认退出时仍走完整兜底路径，行为不变。
- **Helper 1.0.18→1.0.19（启动去固定等待）**：`startMihomo` 原每次 root 启动固定 `sleep 0.5s + 0.3s`；改为条件化轮询——tracked 进程退出按 50ms 轮询（≤0.5s），`killall` 仅在真的杀到进程（退出码 0）时才等待进程表清空（≤0.3s）。干净启动零固定延迟，TUN / 网关 root 重启显著提速。
- **特权连通性握手缓存**：`verifyConnectivity` 成功结果缓存 2s（磁盘安装状态仍每次实检；失败从不缓存；安装/升级/卸载/`resetConnection` 主动失效）。TUN 一次开启流程原本 2–3 次相同 XPC 握手减为 1 次。
- **系统代理开关感知提速**：先设代理、先出结果 toast，`allow-lan` 共享补丁（配置 patch + refresh）后置执行，不再垫在开关反馈前面。

## [1.1.4] - 2026-07-19

系统代理与内核切换可靠性：修 XPC 超时/启核慢、内核更新卡死断网、开 Proxy 后无法检查/下载内核；侧栏状态精简；动效/Toast/轮询分层。Helper **1.0.16 → 1.0.18**（需强制升级）。

### Fixed
- **系统代理 XPC 超时 / 开关巨慢**：`setSystemProxy` 只配置活跃物理服务（跳过 VPN/Shadowrocket 等），最多 2 个服务；单条 `networksetup` 超时 1.2s；`callSystemProxy` 超时 5s→15s。
- **开系统代理误走 root 重启**：`ensureRunningAsync(preferRoot:)`；系统代理路径 `preferRoot: false`，避免无故 root 升级拖死 UI。
- **内核更新切换卡死导致全局断网**：先下载/解压/暂存，再临时关系统代理→停核→换 bin→启动→就绪后恢复代理；`callStopMihomo` 4s 硬超时；Helper stop 异步回复。
- **开系统代理后无法检查/下载内核**：`KernelManager` 使用 ephemeral 直连 `URLSession`（`connectionProxyDictionary = [:]`），不再经 `127.0.0.1:mixed-port`；暴露真实错误；下载不再占满 `isBusy`。
- **内核检查版本误判**：以运行中的 bin 版本为准；已下载未启用显示「启用已下载」。

### Changed
- **侧栏状态精简**：Proxy / TUN / 内核（红绿点 + 完整版本号），去掉「核心已就绪」长文案。
- **开 Proxy 时 ensure allow-lan**：局域网设备可经 mixed-port 使用代理（无需开网关中枢做透明转发）。
- **动效 / 反馈 / 性能**（1.1.3 后合入）：`DS.Motion`、Toast generation+kind、主开关 busy 可感知、菜单栏 toast 副标题、`refreshConfigs` 约 12s 分层、DnsPage 去双拉、series 仅 dashboard。
- **Helper 1.0.17→1.0.18**：`setSystemProxy` 服务筛选；`stopMihomo` 异步 + 更短等待。

## [1.1.3] - 2026-07-18

启动稳定性与网关体验：修复冷启动误开网关中枢导致断网；网关设备列表复活；Helper 安装/升级体验加固（预检、单次授权、更新说明弹窗）。Helper 仍为 **1.0.16**（相对更早版本需升级；1.1.4 起请升到 1.0.18）。

### Fixed
- **冷启动误开网关中枢 / 全局断网**：`refreshConfigs` 不再根据残留 `allow-lan + dns.listen=0.0.0.0:53` 推断 `gatewayModeOn`。网关开关只认用户意图（UserDefaults 镜像）；开关关闭时若发现残留 `0.0.0.0:53` 会自动清回 `127.0.0.1:1053` 并顺带关闭 IP 转发。
- **网关「已接入设备」始终为空**：设备聚合原先只写在 `recordHistoryOnly`，前台 `startPolling` 不拉 `/connections`，连接页也不写 `gatewayDevices`，后台又因 `needDetailedStats=false` 跳过。抽出 `updateGatewayDevices`，连接页与网关开启时的前台轮询共同驱动；过滤 loopback / 本机 IP / fake-ip `198.18.0.0/15`。
- **Helper 安装自毁**：Debug App 未嵌入 Helper 时，`installDaemon` 仍 `bootout` 旧服务，留下 plist 无二进制（launchd `EX_CONFIG`）并刷屏 XPC 错误。安装前校验源二进制；`set -e` + stage→bootout→mv；`checkStatus` 同时要求 plist **与** 二进制存在。
- **Helper 升级双密码弹窗**：升级改为原地替换（单次授权），不再卸载+安装。
- **`verifyGatewayConfig` 刷屏**：Helper 不可达时先探测并 60s 节流失败日志，避免每 30s 打 XPC 错误。

### Changed
- **Helper 强制更新前置**：`AppModel.start()` 在探测内核之前执行 `checkAndUpgradeHelperIfNeeded()`。
- **管理员授权前说明弹窗**：`runAdmin` 支持 `prompt`；安装 / 更新 / 卸载前先展示中文说明，再出系统密码框。
- **文案统一**：用户可见「SD-WAN」统一为「网络拓扑」（侧栏、拓扑页提示、Helper 安装说明）。
- **升级失败日志更准确**：区分「App 未嵌入 Helper」「授权取消 / bootstrap 失败」，不再一律报「授权被拒绝」。

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
