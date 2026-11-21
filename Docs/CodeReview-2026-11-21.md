# ClashHalo 全量代码审查（2026-11-21）

- **触发任务**：① 为 Provider（订阅服务商）的 API KEY 增加每秒 ≤ 9 次的请求频率限制；② 全量审查代码，重点看功能解耦、内核关联、TUN 逻辑。
- **审查方式**：逐文件精读 + 对照 AGENTS.md 已文档化不变量逐一核验 + 36 套回归 + Debug 构建。审查为只读（除频率限制功能本身）。
- **基线**：`fe0f24b`（v1.5.2 build 140 之后，Helper 1.0.35）。

---

## 一、本次功能改动：Provider API 每秒 ≤ 9 次节流闸

**为什么**：订阅服务商（机场面板）按 API key 限频，超发直接 429；旧实现「全部刷新」对多个订阅的下载 / 内核 PUT 是无间隔循环，快响应的服务商在 1 秒内可被打穿。

**实现**（滑动窗口 + 单一漏斗）：

| 文件 | 改动 |
|---|---|
| `Sources/Core/Subscription/ProviderRequestThrottle.swift`（新增） | `ProviderRateWindow`（纯逻辑滑动窗口：任意 <1s 区间同 key ≤9 次，固定窗口的边界尖峰不允许）+ `ProviderThrottlePolicy`（常量 9、键=host:port 归一口径）+ `ProviderRequestGate`（@MainActor 闸门，等待用不可取消定时器——取消不得绕过闸门、已取消任务里 `Task.sleep` 会热自旋） |
| `Sources/Model/ConfigStore.swift` | 新增唯一漏斗 `fetchSubscriptionData`，`download` / `importRemoteDraft` / `updateRemote` 三处直连下载全部经它过闸 |
| `Sources/Model/AppModel+Config.swift` | `refreshProviderNodes` http 分支在 `PUT /providers/proxies/:name` 前过闸——该 PUT 会让 mihomo 携带订阅 URL（内含 key）重新下载 |
| `Tests/ProviderThrottle/` + `Scripts/run-tests.sh` | 21 断言回归套件（滑动窗口语义 / 键口径 / 端到端 ≥0.9s 等待下界），已登记为 `providerthrottle-tests` |
| `ClashHalo.xcodeproj` | 新文件登记（PBXFileReference + BuildFile + group + Sources 四处） |

**键口径**：按 host(:port) 分桶而非完整 URL——同一 API key 常以 `flag=clash` / `flag=singbox` 等参数出现在多条订阅 URL，按完整 URL 分桶会放过「同 key 多 URL」叠加超频；按 host 只会更严不会更松。https 默认 443 / http 默认 80 归一，非 http(s) 与解析失败统一落 "other" 单桶。

**已知边界**（如实记录，非缺陷）：跨 host 共享同一 key（CDN 多子域）URL 侧无法识别，各子域各得一桶；mihomo 按 `interval` 的内核自动更新（分钟级）与健康检查（打 gstatic，不用订阅 key）不在 App 管辖；file 型 provider 的内核刷新只重读本地文件，无网络请求，不过闸。

**验证**：`xcodebuild Debug` exit 0；`bash Scripts/run-tests.sh` 36/36 全绿（35 原有 + 1 新增）。

---

## 二、审查发现

### P2-1 NetworkPages「重启内核」在 UI 层复刻了一遍高危时序

`Sources/UI/Network/NetworkPages.swift:1224-1252`：`关代理 → engine.restart → waitForKernelReady → reconnect → reapplyTUN → restoreSystemProxy` 这套时序整段写在 SwiftUI 按钮闭包里，与 `AppModel.healDetachedTUN`（`AppModel+Config.swift:3216-3250`）、`KernelManager` 切换流（`KernelManager.swift:231-312`）构成**三份近似拷贝**。当前三份都是对的，但任何一步将来要加环节（比如 TUN 回退、DNS 收尾），UI 这份最容易漏改——它不在 Model 层，grep `engine.restart` 审查时也最容易被略过。
**建议**：提一个 `AppModel.restartKernelForUser()`，UI 只调入口；三份时序收敛为一份（或至少 UI 份消失）。

### P3-2 providersourcestore-tests 在汇总里显示「0 断言」

`Tests/ProviderSourceStore/main.swift:33-43` 用 `PASS/FAIL` 输出约定，而 `Scripts/run-tests.sh:353` 用 `grep -c '✓'` 计数——套件本身断言齐全、退出码正确，但汇总行显示 `PASS 0 断言`，长期看像套件失效。
**建议**：把该套件输出统一成 `✓/✗`（或 run-tests.sh 对无 ✓ 套件计数改为按 PASS/FAIL 行）。

### P3-3 MihomoClient.updateProvider 60s 超时与内核实际拉取解耦（预先存在）

`Sources/XPC/MihomoClient.swift:117-128`：PUT 超时后 App 记「失败」，但 mihomo 仍在后台拉订阅且可能成功——用户看到失败 toast、节点却稍后悄悄变化。属于既有 UX 瑕疵，不影响正确性；刷新结果最终由 `refreshProxies` 对账。仅记录。

### P3-4 ensureRunningAsync 单飞失败后的背靠背二次尝试（低置信度）

`Sources/XPC/EngineControl.swift:1141-1156`：多个调用方等同一个单飞任务，若该任务 root 升级失败，每个等待者都会再走一遍 body。实测所有调用方要么持 `isBusy`（toggle/TUN/网关）、要么天然串行（启动/唤醒恢复），失败模式下 body 首步 probe 又会短路，实际不可触发连续双重启。仅作为并发形状记录，不建议现在改。

### 观察项（不算缺陷）

- `SubscriptionsPage.swift:320/337/363` 直接调 `engine.proxyProviders()` / 读 `config.yaml`：只读行扫描，符合 AGENTS.md「配置编辑大量使用轻量行扫描」的既定口径，不改。
- `refreshProviderNodes` 的 file 分支（`AppModel+Config.swift:4596-4619`）PUT 不走节流闸：file 型 provider 的内核刷新只重读本地文件，无网络请求，设计如此。

---

## 三、已核验不变量（全部通过，抽样证据）

| 领域 | 不变量 | 证据 |
|---|---|---|
| isBusy 纪律 | 28 处 `engine.isBusy = true` 全部有 defer 或等价手工复位；fire-and-forget 用 `withEngineBusy`（`AppModel+Config.swift:699-711`），自愈路径按文档例外手工持有 | 逐处核对 |
| TUN 自动拆除 | 双 auto-teardown（refreshConfigs 3s / verifyTUNConfig 30s）共享 `tunAutoTeardownInFlight` + `isBusy` + defer 单点复位 | `AppModel+Config.swift:459-470`、`AppModel.swift:2575-2582` |
| 僵尸巡检 | `!tunOn` 反向门控、两击确认、3 次熔断 + 1800s 冷却、修理槽位在 await 前认领 | `AppModel+Config.swift:3114-3214` |
| 数据面探针 | 合并制调度（min 触发时刻、不 cancel+重建）、滑动窗口 + 交替形态闩锁、`reset()` 仅满窗健康后 | `AppModel+Config.swift:2925-2980`、`TUNDataPlaneProbe.swift` |
| 自愈升级链 | 原地重建半关必升级整进程重建（不停在半关）；恢复入口守卫在同步段内原子认领 | `AppModel+Config.swift:3061-3094`、`3375-3398` |
| fake-ip 守卫 | `ensureProxyDNS`：`!tunOn` 前置 + redir-host 判定 + 残留 restoreAll + 53 端口实测 + reload 后复查 tunOn + 探测应答，五道门齐全 | `AppModel+Config.swift:1072-1141` |
| 身份约定 | 系统代理 `allowRootUpgradeRestart: false`（`AppModel+Config.swift:890-891`）；TUN/网关/自愈显式传 `true`；冷启动默认值只出现在内核已死路径 | 逐调用点核对 |
| 内核切换时序 | 下载期不碰内核（`KernelManager.swift:503`）→ 关代理 → stopKernel → 换 bin → 启动 → waitForKernelReady → 才恢复代理 | `KernelManager.swift:231-312` |
| secret 轮换 | 加密替换后用旧 secret 探活区分「死核」vs「活核但没人知道新 secret」，必要时重启，闭环 | `AppModel.swift:993-1011`、`EngineControl.swift:896-955` |
| Helper 鉴权 | 路径锚定 + identifier 双必经、完整校验 flags 为空、Release 允许根只剩 /Applications 与 /Volumes 一层 | `Sources/Helper/main.swift:21-155` |
| root 启动内核 | 解软链 + console user home 精确全等 + 末段软链拒绝 | `Sources/Helper/main.swift:246-262` |
| 安装/升级 | 预检 App 内 Helper 源二进制、`set -e`、stage→bootout→mv、XPC-2 shellQuote 全转义、升级=原地单次授权 | `XPCManager.swift:379-460` |
| 路由记账 | 撤回失败保留记账（F13）、删除前重验归属、孤儿路由只删非作用域 + 网关列重演接口形状 | `Sources/Helper/main.swift:674-835` |
| 清理自证 | `cleanupTUNResidual` 在 Helper 写点内重读 config.yaml 自证「配置关」 | `Sources/Helper/main.swift:845-871` |
| 快照纪律 | `ruleTargetNames` 只在点开编辑动作那一刻求值进 `RuleEditTarget` / `RuleEditContext` | `RulesPage.swift:89,191`、`ConnectionsPage.swift:456-458` |
| 隐私 | manifest 不留 URL、profile/config.yaml 0600、ProviderOperationError 不透传底层响应 | `ConfigStore.swift:188-231` |
| 内存热路径 | `recordHistoryOnly` 全程 autoreleasepool、每拍喂 TUNLoopSentinel + 末尾 reap、enforceAppMemoryGuard 前置 | `AppModel+Connections.swift:39-106` |

**结论**：架构不变量维护状况显著好于常见水准——文档化约束与代码一一对应，历史事故均有回归套件钉住。本次未发现 P0/P1 级新缺陷；P2-1（重启时序三份拷贝）是唯一建议排期的解耦项。
