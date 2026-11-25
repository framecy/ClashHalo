# ClashHalo 优化方案（对标 QiuChen Proxy）

> 编写时间：2026-10-20 · 基准版本：v1.3.8 (build 130) · 内核：mihomo Meta v1.19.32
> 对标对象：`https://qiuchenlyopensource.github.io/Documentaions/zh/network-proxy`（QiuChen Proxy，自研内核，utun L3 透明代理）

## 一、结论先行

ClashHalo 在**系统正确性**上已经比对标产品更深：DNS 重定向记账（`TunnelDNSLedger`）、TUN 数据面探针、僵尸隧道自愈、共存 VPN 路由归属、内核内存看门狗、持久化写入事务化。这些是 QiuChen 文档里完全没出现的能力，不能为了"对标"去动它们。

差距集中在另一面：**从"能跑"到"看得懂、少一步"**。QiuChen 的产品化做得好在四个动作——

1. 把专业概念翻成一条可读链路（连接审查：输入 → 模式 → 命中规则 → 组选路 → 终态）；
2. 把陌生 IP 翻成"谁"（MAC / 厂商 / 设备类型 / App 路径）；
3. 把复杂操作压成一步（右键独立制裁、端口转发增删即生效）；
4. 把首次上手压成三步（导入订阅 → 配规则 → 验证）。

本方案只补这四类，不碰代理内核、不碰 Helper 协议、不碰 TUN/DNS 安全链路。

**最值得先做的一件事**：内核 `/connections` 已经返回 25 个元数据字段，仓库只解码 8 个（`ConnMeta`，`Sources/XPC/MihomoModels.swift`）。其中 `inboundName` / `dnsMode` / `sniffHost` / `providerChains` / `uid` 正是"连接审查"那条链需要的全部证据——数据已经躺在每次 1.5 秒的轮询回包里，只是被丢掉了。这一项零新增权限、零新增配置、零内核交互，收益却是最直观的。

## 〇、执行进度（2026-10-22）

方案里的 7 项已全部落地，逐项落点如下（状态以代码与回归套件为准，不以本表为准）：

| # | 项 | 状态 | 主要落点 | 回归 |
|---|---|---|---|---|
| 1 | 连接详情「决策链」 | 已实现 | `MihomoModels.swift` 补 `inboundName`/`dnsMode`/`sniffHost`/`uid`/`providerChains`/`remoteDestination`；`ConnOrigin.swift`（来源判定纯逻辑）；`ConnDetailCard` 四段式；连接表「来源」列（本机/局域网/外部）。**与原方案的一处偏差**：列是常驻而非「可选、默认关闭」——`TableColumnBuilder` 的条件列要 macOS 14.4+，部署目标 14.0；`TableColumnCustomization` 会多一条表头右键控制路径。列宽压到 88pt 折中 | `connorigin-tests` |
| 2 | 订阅卡协议分布 | 已实现 | `ProviderProtocols.swift`（`summarize`、超 4 种折叠为前 3 + `+N`）；订阅卡渲染 | `providerprotocols-tests` |
| 3 | 空状态三步引导 | 已实现 | `GettingStartedCard.swift`（完成度全部由真实状态推导，无持久化 flag）；配置页与仪表盘共用同一组件 | — |
| 4 | 设备身份（MAC / 厂商 / 类型） | 已实现 | `DeviceIdentity.swift`（`arp -an` 行解析 + 内置常见厂商 OUI 表 + 类型只来自厂商白名单或端口指纹，一律标注「推测」）；`GatewayDevice.identity`，取不到就是「未知」而不是留白 | `deviceidentity-tests` |
| 5 | 一键「独立制裁」 | 已实现 | `QuickRule.swift`（决策纯逻辑：域名/裸 IP 分流、fake-ip 兜底、同匹配替换、isNoop）；连接页右键三项走既有 `applyRuleEditorSave` 事务 | `quickrule-tests` |
| 6 | 端口转发（入站 listeners） | 已实现 | `InboundListener.swift`（块读写 + 三条内核约束：不写 `listen:` 会绑全网卡、`bind-address` 对 listener 无效、`network` 必须是数组）；网络页「入站」卡片，默认只监听 `127.0.0.1` | `inboundlistener-tests` |
| 7 | 订阅引用提示 / TUN 断流预告 | 已实现 | `ProviderUsage.swift`（`use:` 计数，N=0 时警示）+ 订阅卡；`AppModel+Config.swift` 重启路径预告「现有连接会中断」、PATCH 热切换提示「未断流」 | `providerusage-tests` |

**方案之外、本轮顺手补的两处**（都属「表单显示的值与配置真实状态不一致」这一类）：

- 规则编辑弹窗没带入原匹配内容：根因是 `.sheet(isPresented:)` 身份复用 + `@State` 初值只认首次；改用 `.sheet(item:)`（与连接页一致）并加幂等 `onAppear` 兜底。规范写进 `AGENTS.md`「UI 约定」与 `Docs/design.md` §6.4。
- 规则目标存在性校验：引用已被删除的策略组/节点时，内核 reload 会拒绝整份配置、事务回滚只弹一条英文报错；现在保存前用中文拦住并让用户重选。判定权威是**写盘目标文件**（策略组 + 节点 + `config.yaml` 里的组 + 内置策略），内核 `/proxies` 只作其中一半。规范写进 `AGENTS.md`「架构约定」，表单交互写进 `Docs/design.md` §6.4。

**仍未覆盖**（如实保留）：内联映射写法的策略组（`- {name: X, type: …}`）在任何一套行扫描里都取不到名字；`providerChains` 在订阅场景下的真实内容仍未复核，界面只做展示、不当主信息。

## 二、对标拆解与现状证据

### 2.1 QiuChen 的可借鉴点

- **零摩擦开启**：daemon 内置 netproxy 引擎，"即时生效、无需重启、无需输入密码"
- **配置热重载**：JSON 存 `~/.qiuchenly/`，改配置自动生效
- **订阅即策略组**：每个订阅 = 一个策略组；另有内置 SELECT / URL-TEST / FALLBACK
- **协议分布**：订阅卡显示 `VLESS 61 · HYSTERIA2 25 · SS 2`
- **连接审查**：每条连接的进程、目标、出口、走向；本机 / 局域网设备 / 外部 三类归属；完整决策链；右键"独立制裁"（按域名 / IP / 端口 / 进程加规则或拉黑）
- **对外代理两条路**：HTTP/SOCKS5 对外开放；L3 透明转发（与 DHCP 解耦、多网卡自动识别）
- **端口转发**：入站/出站管理，"轻量 frpc"，开关即时生效、不重建其它转发
- **设备身份**：OUI 厂商反查、设备类型分类（手机/电脑/IoT）、App 路径解析
- **ARP 加固**：Gratuitous ARP 防 IP 冲突
- **菜单栏面板**：实时速率 + 当前节点 + 快速切换

### 2.2 ClashHalo 现状（逐条核实过的）

- 侧栏 10 个路由：仪表盘 / 连接 / 日志 / 代理节点 / 规则 / 订阅 / 配置 / 网络（5 个 tab：入站·TUN·DNS·嗅探·内核）/ 网络拓扑 / 设置（`Sources/App/ContentView.swift`、`NetworkHubPage`）
- 连接页 3 个视图（连接中 / 已关闭 / 聚合），表列 = 目标 / 进程 / 规则 / 链路 / ↓ / ↑；右键只有「添加/修改分流规则…」→ 打开规则表单
- 连接详情是扁平 Grid：ID / 域名 / IP / 源 IP / 网络 / 进程 / 规则 / 策略 / 节点 / 上下行 / 时间（`ConnDetailCard`）
- 局域网设备卡片只有 IP + 连接数 + 速率 + 时长（`GatewayDevice`，`Sources/Model/Models.swift`）
- 订阅页显示节点数、订阅流量（Total/Expire）、单条刷新；无协议分布
- 端口转发：**不存在**（全仓搜索无相关实现）
- 设备身份：**不存在**（无 MAC、无厂商、无类型）
- 首次上手：**不存在**引导；配置页空状态只有一句「暂无配置，点击右上角"+"导入」
- 内核能力：`listeners` 7 种类型全部通过 `mihomo -t` 校验；`type: tunnel` 实测转发成功

### 2.3 已实测的关键证据

| 事实 | 验证方式 | 结果 |
| :--- | :--- | :--- |
| `/connections` 元数据字段数 | 读本机运行中内核 `/connections` | 25 个字段，`ConnMeta` 只解码 8 个 |
| `inboundName` 可信 | 同上 | 89 条中 85 条为 `DEFAULT-TUN`，源 IP 为 `198.18.0.0` |
| `providerChains` 存在 | 同上 | 87/89 条非空（当前值多为 `[""]`，需在订阅场景复核） |
| `listeners` 端口转发 | 起本地 http.server + `type: tunnel` 转发 | `curl 18080` 取到目标内容，转发真实生效 |
| 端口转发**免重启** | `PUT /configs?force=true` 改 listener 端口 | HTTP 204；旧端口 CLOSED、新端口 OPEN、PID 未变 |
| ARP 表可读 | `/usr/sbin/arp -an` 无特权 | 返回 IP + MAC + 接口 |
| 规则前插 | 读 `RuleEditorModel.addNode` | `nodes.insert(n, at: 0)`，新规则天然在 MATCH 之前 |

## 三、优化方案

### 第一批：零风险、高感知（建议先做）

#### 1. 连接详情升级为「决策链」——把已丢弃的 16 个字段用起来

**为什么**：QiuChen 的"连接审查"核心不是表格，而是一条人能读的因果链。ClashHalo 现在把链拆成了 5 个不相干的单元格，用户要自己拼。

**怎么改**：

- `ConnMeta` 增加 `inboundName` / `inboundPort` / `dnsMode` / `sniffHost` / `uid` / `providerChains` / `remoteDestination`；`Conn` 增加对应只读字段
- `ConnDetailCard` 改为四段式（每段一行小标题 + 值）：
  1. **来源**：`本机 · Aside Helper` / `局域网 · 192.168.x.x` / `外部 · 经 mixed-port` —— 判据用 `inboundName` + `srcIP`（TUN 下 `srcIP` 恒为 `198.18.0.0`，不能只看它）
  2. **解析**：`fake-ip` / `normal` / `redir-host`，有 `sniffHost` 时显示「嗅探得到真实域名 xxx」
  3. **规则**：`DomainSuffix,usriot.net`（点击跳规则页并定位）
  4. **出口**：`策略组 → 节点`，`DIRECT` / `REJECT` 用状态色区分
- 连接表新增可选列「来源」（`inboundName` 归一化后的中文），默认关闭，避免表格变挤

**风险**：
- `providerChains` 当前实测值多为空串，不能承诺"显示节点来自哪个订阅"——先只做展示，等订阅场景复核后再决定是否用作主信息
- 每条连接没有"建立时的 mode"，`/connections` 不提供；只能用当前全局 `M.mode` 并明确标注「当前模式」，不能假装是历史值
- 连接热路径必须继续包 `autoreleasepool`，新增字段解析不得引入逐行字符串变换

**验收**：TUN 模式下打开连接页选中一条连接，四段信息齐全；`inboundName` 为空的老连接显示「未知来源」而不是空白；1.5 秒轮询下内存无回归（对比改前 RSS）。

#### 2. 订阅卡显示协议分布

**为什么**：QiuChen 用 `VLESS 61 · HYSTERIA2 25 · SS 2` 让用户一眼看出"这份订阅是什么货色"。ClashHalo 的订阅卡只有节点总数。

**怎么改**：`ProviderEntry.proxies` 已带 `type`，在 `SubscriptionsPage.card` 里按 `type` 聚合，渲染成一行等宽小字。超过 4 种协议时折叠为前 3 + `+N`。

**风险**：几乎为零；注意 `proxies` 可能为 `nil`（provider 未下载完），此时不显示而不是显示 `0`。

**验收**：订阅页任一 HTTP 订阅卡出现协议分布，数值之和等于节点数。

#### 3. 空状态三步引导

**为什么**：现在首次安装只看到「暂无配置，点击右上角"+"导入」和三个顶栏按钮，用户不知道导入之后还要干什么。QiuChen 用「三步上手」把这条路铺完。

**怎么改**：
- 配置页空状态（`ConfigPage` 的 `ContentUnavailable`）升级为三步卡片：
  1. 导入订阅（按钮：导入订阅）
  2. 选一个节点（未完成时按钮置灰，提示"导入后可用"）
  3. 开启接管（系统代理 / TUN 二选一，附一句适用差异）
- 每步有完成勾选（按真实状态推导，不新增持久化标志）：有 profile → 第 1 步完成；`M.groups` 里存在被选中的节点 → 第 2 步完成；`systemProxyOn || tunOn` → 第 3 步完成
- 仪表盘在"无配置"时也显示同一张卡（复用同一组件，避免两份文案漂移）

**风险**：仪表的完成判据必须来自真实状态，不能存"我引导过了"的 flag——否则用户删了配置回来还是全勾。

**验收**：清空全部配置 → 重启 App → 三步卡全未完成；导入订阅后第 1 步变勾；按提示开 TUN 后第 3 步变勾。

### 第二批：需要新数据源或新写盘路径

#### 4. 局域网设备"是谁"：MAC + 厂商 + 类型

**为什么**：网关模式下列表全是 `192.168.x.x` 这样的裸 IP。这是"看不懂"和"看得懂"之间最大的一跳——用户要判断"要不要给这台设备放行"，首先得知道它是谁。

**怎么改**：
- 新增 `DeviceIdentity`（纯逻辑、可测）：输入 IP，输出 `(mac, vendor, type)`；MAC 来源 `/usr/sbin/arp -an`（实测无特权可读），厂商查内置 OUI 前缀表
- OUI 表：内置前缀 → 厂商名（IEEE 全量约 3.5 万条，CSV 约 2 MB；建议裁剪成"常见厂商 + 其余归 Unknown"，或 gzip 后解压进内存）。**体积预算必须先测**，超 500 KB 就不该进包体
- 类型判定：先按厂商白名单（Apple 多为手机/电脑，Espressif/TP-Link 多为 IoT），再按连接目标端口指纹（5353/1900 = 家庭设备）兜底；**判不出就显示「未知」，不猜**
- `GatewayDevice` 增加 `mac` / `vendor` / `deviceType`；卡片第一行显示 `iPhone 的可能性` —— 文案要写成「推测」而不是断言
- 设备行加「复制 MAC」「按此 IP 加规则」两个动作

**风险**：
- ARP 表只含同网段最近通信过的设备；跨 VLAN 或三层网关后**拿不到 MAC**，必须如实显示「未知」，不能留空让人以为坏了
- `arp -an` 里 MAC 去前导零（`0:e0:4c:…`），归一化后才能匹配 OUI
- OUI 表是数据资产，需要明确来源与许可，且不随版本频繁更新（建议首版就定，之后刻意少动）

**验收**：网关模式下有设备接入时，能显示至少一台设备的 MAC 与厂商；跨网段设备显示「未知」而不是空白；无设备时不显示空卡片。

#### 5. 一键「独立制裁」：让这条连接直连 / 拉黑 / 按进程分流

**为什么**：QiuChen 在连接上右键就能按 域名 / IP / 端口 / 进程 加规则或拉黑。ClashHalo 右键只有「添加/修改分流规则…」，进去还要自己填类型、匹配值和策略。

**怎么改**：`ConnectionsPage` 的 `contextMenu` 增加三项（复用已有 `RuleEditorModel` + `applyRuleEditorSave` 事务路径）：
- 「让 `<host>` 直连」→ `DOMAIN-SUFFIX,host,DIRECT`
- 「拉黑 `<host>`」→ `DOMAIN-SUFFIX,host,REJECT`
- 「这个 App 走 `<当前策略组>`」→ `PROCESS-NAME,<进程名>,<组>`

三者都走「写规则 → 校验 → reload → 断开该连接」，失败整体回滚。`addNode` 已把新规则插在 index 0，位置天然在 `MATCH` 之前。

**风险**：
- 拉黑一条 CDN 域名会连坐同域其它请求——执行前在按钮上写明「将拉黑该域名下所有连接」，并把受影响连接数（聚合视图里已有 `count`）显示出来
- 进程名为空（`process` 为 `—`）时该动作置灰
- 写盘必须复用现有事务（备份 → `mihomo -t` → reload → 失败还原），不许新写裸保存

**验收**：对一条连接点「拉黑」，规则页出现新规则且排在 MATCH 之前，该连接立即断开、后续同域名连接走 REJECT；写盘失败时界面回到真实状态并报错。

#### 6. 端口转发（入站 listeners）

**为什么**：ClashHalo 完全没有这个能力；QiuChen 把它当卖点（"Mac 上超轻量级的 frpc"）。而内核**已经支持**，不需要自研内核。

**已实测可行性**：

```
listeners:
  - name: fwd-test
    type: tunnel
    port: 18080
    target: 192.168.x.x:8080
    network: [tcp, udp]
```

- `mihomo -t` 校验通过；真实转发 `curl` 取到目标内容
- 改端口后 `PUT /configs?force=true` → 204，旧端口立即 CLOSED、新端口 OPEN，**内核 PID 不变**（无需重启，不打断现有连接）

**怎么改**：
- `EngineControl` 新增 `listeners` 块读写（行扫描，参照 `writeProxyProviders` 的模式；`setTopLevelScalars` 只写顶层标量与一层嵌套，处理不了数组块）
- 新页面或「网络 → 入站」新增卡片：列表（名称 / 协议 / 监听端口 / 目标 / 开关）+ 添加表单
- 保存走完整事务：写盘 → `mihomo -t` → reload → 失败还原
- 流量可观测：`inboundName` 会等于 listener 的 `name`，第一批做完后，连接页「来源」列直接能看出这条流量是从哪个转发进来的——这是两个批次的天然配合

**风险**：
- 监听端口可能被占用，必须明确报错并指出占用者（不要把 500 抛给用户）
- `network: [tcp, udp]` 是**数组**不是字符串（实测：写成 `network: tcp` 会报 `'network' is not a slice`），这是容易踩的坑，写死在生成器里
- 对外开放端口等于给局域网开洞：默认只监听 `0.0.0.0` 需用户显式勾选"允许局域网访问"，默认 `127.0.0.1`
- 不做 UDP 广播/mDNS 特殊处理，首版只做 TCP + 明确的 UDP 单播

**验收**：本机 `curl 127.0.0.1:<监听端口>` 转发到目标成功；改端口即时生效且期间其它转发不中断；端口冲突有中文报错；关闭开关后端口立即释放。

### 第三批：体验打磨

#### 7. 「订阅 → 策略组」的一致性提示

**为什么**：QiuChen 里订阅就是策略组，心智简单。ClashHalo 里订阅是 proxy-provider，还需要被策略组 `use:` 引用才会出现在代理节点页。用户删了引用会看到"订阅有 86 个节点，代理节点页却没有"。

**怎么改**：订阅卡显示「被 N 个策略组引用」；N=0 时显示警告色提示「此订阅尚未被任何策略组使用，节点不会出现在代理节点页」。N 从 `config.yaml` 行扫描统计 `use:` 得到（`writeProxyProviders` 已有同类解析）。

**风险**：行扫描要与 `EngineControl.readConfigFile` 的口径保持一致，不能引入第二套 YAML 理解。

#### 8. TUN 开关的断流预告

**为什么**：QiuChen 的开关是热生效、不断流；ClashHalo 的 TUN 在 PATCH 未生成 utun 时会回退到「持久化 + 重启内核」，期间现有连接全断，而界面只显示"正在开启 TUN 模式…"。

**怎么改**：走重启路径时，忙碌横幅补一句「将重启内核并重建隧道（约数秒），现有连接会中断」；走 PATCH 热切换成功时提示「已热切换，未断流」。

**风险**：只改文案与分支判断，不改时序。

## 四、明确不做（以及为什么）

- **不做 DHCP 服务**。QiuChen 自己在文档里标注「DHCP 功能未完整测试，请不要自行启用」。接管 DHCP 失败会让整个局域网无法恢复，收益远小于风险。ClashHalo 保持"用户手配网关 + 本机做 L3 转发"。
- **不持久化 TUN 开关意图**。QiuChen 支持"重启后保持上一次开关状态"；ClashHalo 启动时强制 `tun.enable: false`、只允许经 UI 开启，这是刻意设计的安全边界（避免残留隧道劫持流量）。**不为对标让步**。
- **不自研代理内核**。QiuChen 的端口转发/任意协议自由度来自自研内核；ClashHalo 的能力边界由 mihomo 定义。实测 mihomo 1.19.32 的 `listeners` 已覆盖端口转发需求，没有自研的必要。
- **不做 Gratuitous ARP 加固**。ClashHalo 不接管 DHCP、不分配地址，"防 IP 冲突"这个问题的前提不存在。

## 五、排序建议（按投入产出）

1. 连接详情用上已丢弃字段（半天，零风险，感知最强）
2. 订阅协议分布（半天）
3. 一键独立制裁（1–2 天，复用现有事务）
4. 空状态三步引导（1–2 天）
5. 局域网设备身份（2–3 天，含 OUI 表体积评估）
6. 端口转发（3–5 天，含新块写入路径与并发/端口冲突处理）
7. 订阅引用提示 / TUN 断流预告（各半天）

前 4 项做完，用户侧可感知的差距基本补齐；第 6 项是唯一"新增能力"，也是最能拉开与其它 mihomo 客户端的差异。

## 六、验证方式（每一项各自独立）

- 纯逻辑半边（设备身份归一化、OUI 匹配、来源判定）**必须**进 `Scripts/run-tests.sh` 的 `add_suite` 登记，直接编译生产源码，不得在测试里复刻逻辑
- 涉及系统级写点（listeners 监听端口）必须在本机实测：转发成功 / 端口冲突 / 关闭释放三种情况各一次
- 内存：连接页新增字段后对比改前 RSS，确认在软档 260 MB 之内
- 深浅色：新增卡片与四段式详情在 Light / Dark 各看一次（`DS.Palette` 令牌，不新造颜色）

## 七、证据附录（本次实际执行）

```
# 内核能力
$ mihomo -t -d /tmp/mh-test -f config.yaml        → listeners.type=tunnel 校验通过
$ curl 127.0.0.1:18080/                            → HELLO-FWD-OK（转发到 18999 的目标）
$ curl -X PUT '127.0.0.1:19090/configs?force=true' → http=204
$ 端口探测 18080 → CLOSED(ConnectionRefused) / 18081 → OPEN；mihomo PID 未变

# 连接字段
GET /connections → conn keys: chains, download, id, metadata, providerChains,
                   rule, rulePayload, start, upload
                   metadata: 25 个字段（含 inboundName / dnsMode / sniffHost / uid）
                   89 条连接中 85 条 inboundName=DEFAULT-TUN，sourceIP=198.18.0.0

# 本地系统
$ /usr/sbin/arp -an → 无特权返回 IP + MAC + en0
```

未验证（需要在实现阶段确认）：`providerChains` 在订阅 provider 场景下的真实内容；OUI 表最终体积；跨 VLAN 设备的 MAC 可达性。
