# ClashHalo 全量代码审查（2026-11-21）

- **触发任务**：全量审查代码，重点看功能解耦、内核关联、TUN 逻辑。
- **审查方式**：逐文件精读 + 对照 AGENTS.md 已文档化不变量逐一核验 + 35 套回归 + Debug 构建。审查为只读。
- **基线**：`fe0f24b`（v1.5.2 build 140 之后，Helper 1.0.35）。

---

## 一、审查发现

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

---

## 二、已核验不变量（全部通过，抽样证据）

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
