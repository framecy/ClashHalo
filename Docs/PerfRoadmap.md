# 直连链路成本与优化路线（2026-11-01 实测）

> 本文回答一个问题：**为什么规则判 DIRECT 的连接，体感延迟还是 80ms 量级？**
> 结论先行：那 80ms 里只有约 5~8ms 是"直连规则"的成本，其余是「代理拨号多一个 RTT」
> ＋「目标站点的 TLS 轮数」＋「站点离你多远」。真正的杠杆不是换内核，是把 IP 型
> DIRECT 网段排除出 TUN。

## 1. 实测（本机，TUN 开启，utun100 / mixed 栈 / mtu 1500）

同一台机器、同一时刻、交错采样取中位数（curl `--trace-time` 逐阶段打点）：

| 目标 | 路径 | TLS | ClientHello→ServerHello | 说明 |
|---|---|---|---|---|
| `223.5.5.5` | **native**（在 `route-exclude-address` 里，走 en0） | 1.3 | **4.1 ms** | 1 个 RTT，无代理 |
| `223.6.6.6` | TUN（走 utun100） | 1.3 | **14.6 ms** | 同一家服务、同城，差 10.5 ms |
| `www.aliyun.com` | TUN | 1.3 | 16.9 ms | RTT≈4 ms |
| `www.baidu.com` | TUN | **1.2** | **46.8 ms** | RTT≈22 ms，TLS 1.2 = 2 RTT |
| `www.google.com` | 代理（美西节点） | 1.3 | — | TLS 548 ms，TTFB 749 ms |

`www.baidu.com` 整条链路的分解（一次真实 trace）：

```
Connected(本地 SYN-ACK) → ClientHello   0.2 ms
ClientHello → ServerHello              54.8 ms   ← 拨号 1 RTT + 服务器 1 RTT
ClientKeyExchange → ServerFinished     21.8 ms   ← TLS 1.2 第二个 RTT
握手完成 → 首字节                        ~11 ms
合计 TTFB                              82~90 ms  ← 用户看到的"83ms"
```

## 2. 成本模型

对**每一条新建连接**，走 TUN 比走 native 多付：

```
+1 × RTT(目标)      代理拨号：mihomo 先替客户端连服务器，客户端只和本地栈握手
+5 ~ 8 ms           用户态协议栈拷贝与调度（与 RTT 无关的固定项）
```

于是同一个 4 ms 的邻居：4 + 6 ≈ **10 ms**（实测 10.5）。
同一个 22 ms 的国内站点：22 + 6 ≈ **28 ms**（83 → 约 55）。

**这条推翻了两条既有判断：**

1. 会话 613e714a 把 7.7 ms 当成"TUN 的固定成本"。它不是固定的——它随目标 RTT 线性增长。
   7.7 ms 只是拿 4 ms 的 AliDNS 量出来的。国内站点普遍 10~30 ms，真实成本是 15~35 ms。
2. 同一会话提出的 `sniffer.override-destination: false`「省 1 个 RTT」**不成立**。
   无论 mihomo 在 SYN 还是 ClientHello 时刻拨号，客户端发出的第一个字节都必须等
   "拨号完成（1 RTT）"才能被转发；关掉嗅探只是改变决策时刻，不改变这个等待。
   实测也印证：无 SNI 的裸 IP 连接（`https://180.101.51.73`）反而更慢（90.6 ms）。
   **该实验已从计划中删除**——它需要重建 utun100，风险不换收益。

## 3. 规则本身不是成本

- DNS：fake-ip 本地应答 **2.1~2.6 ms**，不是瓶颈。
- 规则匹配：320 条 + 22 个 rule-set，线性扫上限 ~0.06 ms（会话 613e714a 已测）。
- 进程查询：`find-process-mode` 从 always 改 strict 实测无变化——因为规则第 1、2 条
  就是 `PROCESS-NAME,Emulator*`，每条连接都会走到。这是**规则顺序**的代价，不是配置项。

## 4. 优化路线

| 阶段 | 内容 | 收益 | 风险 |
|---|---|---|---|
| **P0** | 固化测量基线 `Scripts/perf-ab.sh` | 让后续每项改动可证伪 | 无 |
| **P1** | 16 个 `classical` rule-set → `domain`；`dns.size` 1500→4096；`nameserver` 加 fallback；节点延迟分档 | 首字节 −100~180 ms（未缓存域名） | 需重载 |
| **P2** | **IP 型 DIRECT 网段排除出 TUN**（建议 + 显式采纳） | 每条直连连接 −1 RTT −6 ms | 中（见 4.1） |
| **P3** | 配置漂移可见化（运行配置 vs profile） | 防止设置被静默覆盖 | 无 |
| **P4** | `stack` 与 `mtu` A/B（sniffer 项已删除） | 未知，≤5 ms | 需重载 |
| 决策门 | NE App Proxy 双引擎 | DIRECT 零拷贝 | 5 个月 + 丢 PROCESS-NAME/网关 |

### 4.1 P2 的语义代价（必须让用户看见）

`tun.route-exclude-address` **强于所有规则**：某网段一旦被排除，域名规则、进程规则、
端口规则对它全部失效——包根本不进 mihomo。所以 P2 只做「建议 + 显式采纳」，不做自动注入：

- 候选只来自显式 `IP-CIDR` / `IP-CIDR6` 且目标是 DIRECT 的规则；
- 硬拒绝：`198.18.0.0/15`（fake-ip）、`/0`、链路专用前缀、本机直连网段、
  以及**更早的 IP 型非 DIRECT 规则**覆盖（顺序语义）；
- 其余（域名/进程/端口规则）无法静态判定，改为「爆炸半径」提示；
- 归属仍由 `CoexistenceProvenance` 单属主记账，撤回只删自己加过的条目。

## 5. 测试方案

| 层 | 内容 | 判据 | 状态 |
|---|---|---|---|
| L0 | `directexclude-tests`（28 断言） | 顺序语义 / 硬拒绝 / 稳定排序 / 多源归属 | ✅ 已跑 |
| L1 | `Scripts/tun-exclusion-test.sh` | 生产源码编译 + 真实 PATCH 一轮 + 记录收敛 | ✅ 已跑（2026-11-01 发现并收敛了 3 条陈旧记录） |
| L2 | 系统验收 | 被排除 IP `route -n get` → en0；还原后回 utunN | ⚠️ 由 L1 脚本代跑，未覆盖网关/LAN 客户端 |
| L3 | 性能验收 | 被排除路径 TLS 落在 native ±20% | ⚠️ 有数字无断言（`perf-ab.sh` 只打印） |

红线：断言不得依赖开发机实时网卡/网段；测量脚本必须备份 → 复原 → `diff` 校验。

## 6. 复现命令

```bash
bash Scripts/perf-ab.sh            # P0：native vs TUN 同服务对照 + 逐阶段打点
bash Scripts/perf-ab.sh --full     # 追加 CPU/连接 与 代理链路对照
```

## 7. 执行记录（2026-11-01）

### 已改（运行时配置，未改 profile）

| 项 | 前 | 后 | 依据 |
|---|---|---|---|
| `tun.stack` | `mixed` | `gvisor` | 交错 3 轮 × 各 7 次：mixed 14.6ms / mips 12.0 / gvisor 12.1（native 对照 4.4）。选 gvisor 而非 mips：握手同速，前者更成熟，网关/UDP 场景更稳 |
| `dns.size` | 1500 | 4096 | 纯缓存容量，不改语义；下一次自然重载生效 |

改后实测：TUN 每连接首飞 **14.6 → 9.7~12.0ms**，`www.aliyun.com` TLS 16.6 → 11.1ms。

> 只改了运行配置（`config.yaml`），**没动 profile**：profile 是 8 月的快照，改它会让
> `appliedHash` 失配、把配置标成「待应用」。差异现在由配置页的漂移横幅显示。

### 没做，以及为什么

1. **16 个 `classical` rule-set → `domain`**：这些 provider 下载下来是 **Clash 规则格式**
   （`DOMAIN-SUFFIX,3.cn`），不是裸域名列表。`behavior: domain` 要求一行一个域名，
   直接改 behavior 会让整份规则变成字面量域名、一条也匹配不上；要转换就得连
   `DOMAIN,` / `DOMAIN-KEYWORD,` 的语义一起丢掉。而实测规则匹配上限 ~0.06ms，
   在 7.7ms 的成本里不值这个风险。
2. **`nameserver` 改直连 + fallback**：配置里已有 `direct-nameserver` +
   `direct-nameserver-follow-policy: true`，DIRECT 域名本来就走国内解析器（实测 2.1ms）。
   把 `nameserver` 也改成国内 DoH 只会改变「代理域名」的污染判定语义，收益存疑、风险实在。
3. **整配置重载**：`stack` 用 `PATCH /configs` 就能改（204，TUN 不重建），
   不必为它冒 utun100 重建的风险。

### 踩到的坑（已写进 `tunPatchBody` 注释）

`GET /configs` 会回显 `processors-per-channel`，但把它原样写回 `PATCH /configs`
会返回 **400 "Body invalid"**（同一 tun 块去掉它 204、带上它 400）。tunPatchBody
的重述表只应收「读回来再写回去仍然合法」的字段。

### 4.2 关键边界：它对 fake-ip 域名流量无效（2026-11-01 实测）

把 `180.101.0.0/16`（百度）临时加进排除表，然后分别测「域名」和「裸 IP」：

| 目标 | 排除前首飞 | 排除后首飞 | 路由 |
|---|---|---|---|
| `https://www.baidu.com`（连到 198.18.0.231） | 40.7 ms | 35.9 ms（噪声） | 仍是 utun100 |
| `https://180.101.51.73`（裸 IP） | 41.1 ms | **28.5 ms** | **en0** |

机制：fake-ip 模式下浏览器拿到的是 198.18.x 假地址，**它连的是假地址**，包必然进 TUN；
排除表里写的是真实目的网段，对它不起作用。所以：

- **有效**：游戏、P2P、自己解析 DNS 的应用、IP 字面量规则、以及 `fake-ip-filter` 里的域名。
- **无效**：浏览器按域名访问的一切——包括国内直连站点。这部分在 TUN 模式下永远是 3 个 RTT。

要连域名也绕开隧道，只有两条路：不用 TUN（系统代理，覆盖不到 UDP/网关/守护进程），
或者换 NE App Proxy（见第 4 节决策门）。这条边界必须写在产品文案里，不能让人以为
「排除几个网段就快了」。

## 8. 已知缺口（2026-11-01 审查）

- **UI 从未渲染**：`TunPage` 的直连网段卡片、`ConfigPage` 的漂移横幅只通过编译；
  已安装的 App 是 v1.4.2（10-29），新代码只在 Debug 产物里。
- **13 套回归缺失**：`Tests/` 不入库，`restore-tests.sh` 只能恢复历史里的 11 套；
  `applydrift-tests` / `configwriteaudit-tests`（P3 依赖）与本次新增的
  `directexclude-tests` 都只存在于写它的机器上。
- **L3 没有阈值断言**：`perf-ab.sh` 只打印数字，"≥5ms 优势"仍靠人读。
- **planner 在当前配置上收益≈0**：4 条候选全是私网段，且本来就在排除表里；
  公共直连流量走 `china_ip` rule-set，静态展开不了。这不是 bug，是能力边界，
  UI 已就此给出说明。
