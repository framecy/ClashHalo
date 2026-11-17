# 订阅 · 策略组归属（proxy-provider → proxy-group）功能设计

> 状态：**已实现（2026-11-17）** · 编写：2026-11-17 · 涉及版本：v1.5.0 之后
> 实施记录见 §12；验收中「真机点击」与「刷新哈希实测」未做（本机 `/Applications` 里已有运行中的 App，未覆盖安装）。
> 关键词：订阅 / provider / proxy-groups / `use:` / 多选 · 全选 · 反选 · 至少一个

## 0. 一句话

添加或编辑订阅时，用一份勾选清单决定这份订阅的节点进入哪些策略组；支持全选 / 反选 / 清空、单选或多选、**至少勾一个**；订阅卡片上可随时改归属，改完立即写盘并热重载。

## 1. 现状与问题（已在代码里核实）

1. ClashHalo 的「订阅」是 mihomo 的 `proxy-provider`。节点只有被某个策略组的 `use:` 引用，才会出现在「代理节点」页（`Sources/Model/ProviderUsage.swift:8-13`）。
2. 目前唯一的归属逻辑在 `EngineControl.writeProxyProviders` 第 4 步（`Sources/XPC/EngineControl.swift:783-839`）：只要这次没有删除 provider，就把 **`proxy-groups:` 里的第一个组**的 `use:` 整块重写为「当前全部 provider」。
   - 用户无法指定组；组 A 只用订阅 1、组 B 只用订阅 2 的结构会被静默合并。
   - 手写在第一个组里的 `use:` 顺序/注释被整块覆盖。
3. **改名 bug**：`writeProxyProviders` 只要检测到有 provider 被删（改名也算删旧名），就跳过第 4 步。旧名从各组 `use:` 里被清掉，新名却没有任何地方补回 → 用户改个订阅名，订阅就静默退出所有策略组，卡片变成「未被任何策略组引用」。
4. 订阅卡片只有一句计数和 N=0 警告（`Sources/UI/Subscriptions/SubscriptionsPage.swift:194-208`），没有入口去选组。
5. 本机实测（2026-11-17，仅统计结构、未输出组名）：当前 `config.yaml` 有 **15 个策略组，只有 2 个组带 `use:`**；两种写法在历史配置里都出现过：

   ```yaml
   use:                       # 块状（本机现状）
     - "US-LH"
   use: ["US-LH", "US-BWH"]   # 内联数组
   ```

   → 新增订阅默认全选，影响面是「全部组」而不是旧的「第一个组」，必须在表单里把影响面说清楚（见 4.2）。

## 2. 目标 / 非目标

**目标**

- 新增订阅时选择归属组，默认全选，可一键反选/清空，可勾单个或多个；一个都不勾时保存被拦下。
- 编辑订阅（改 URL）时保留原有归属；在同一弹窗里可改归属。
- **首次订阅成功后，归属可反复二次编辑**：卡片上随时进入「编辑分组」，以磁盘当前状态回显，不要求重新输入 URL。
- **刷新订阅只拉节点，不重新分配组**：单条刷新 / 全部刷新 / 本地订阅刷新都不改 `use:`、不改订阅定义、不重写 `config.yaml`；组归属始终以首次保存（或最近一次显式编辑）写进配置的内容为准。
- 卡片直接显示「进了哪些组」，并提供「编辑分组」入口；N=0 时给出可操作入口而不是死警告。
- 改名时把 `use:` 里的旧名重映射成新名，归属不丢（修 1.3 的 bug）。
- 删除订阅时照旧清理所有组里的引用；删完变空的组自动补 `DIRECT`（已有行为，保留）。

**非目标（本轮不做）**

- 不提供通用的「策略组编辑器」（新建/删除/排序/改类型），**订阅页也不代建策略组**：配置里一个组都没有时明确报错并引导用户先导入/添加策略组（见 4.6）。
- 不改规则、不改内核参数、不动 Helper / TUN / DNS 链路。
- 不做「订阅只下载节点、不进任何组」的旁路模式。
- 不解析 `- {name: X, type: …}` 内联映射写法的组（现有行扫描口径的限制，见 9）。

## 3. 用户流程

### 3.1 新增订阅

1. 订阅页 →「添加订阅」→ 填名称、URL。
2. 「加入策略组」区：默认**全选**当前配置里全部可加入的组；头部显示「已选 15 / 15」。
3. 用户可：单点勾选/取消、`全选`、`反选`、`清空`；组多时可搜索。
4. 勾 0 个 → 底部错误行提示，保存按钮禁用。
5. 保存 → 写盘（备份 → 写 → `mihomo -t` → reload，失败回滚）→ 卡片出现，显示归属组 chips 与「编辑分组」。
6. 首次保存成功后**不锁定**归属：用户可立刻在卡片上进入「编辑分组」二次调整，也可以在「编辑订阅」里连同 URL 一起改（见 3.2）。
7. 若 URL 是 base64 节点订阅（不认给内核），照旧提示「转为本地订阅」；归属组在转换时保持不变。

### 3.2 二次编辑归属（首次订阅成功后）

两个入口，写的是同一份 `use:`：

| 入口 | 打开的内容 | 说明 |
|---|---|---|
| 卡片 chips 旁「编辑分组」 | 只有组清单（名称、URL 以只读摘要展示） | 最常用；不让人误改 URL |
| 卡片铅笔「编辑订阅」 | 名称 / URL / 组清单 | 改名、换订阅地址时用 |

- 弹窗每次打开都**重新读磁盘**当前归属，不用首次保存时的内存快照；外部手改过 `config.yaml` 也能看到真实状态。
- 只改归属也能保存：写盘后 reload，节点立即进/出对应组；其他订阅的归属、组顺序、注释一概不动。
- 归属可反复编辑，没有次数限制；保存后再次打开即最新状态。
- 取消最后一个组时，行内先预告「保存后该组将没有节点来源，会自动补 DIRECT」，不阻塞保存。
- 刷新订阅期间（`busy` / `engine.isBusy`）「编辑分组」与保存置灰，避免边拉节点边改配置。

### 3.3 改名 / 删除

- **改名**：弹窗里改名称 → 保存时把各组 `use:` 里的旧名原位替换为新名，其他 provider 与顺序不动。改成一个已存在的名字 → 保存前用错误行拦住（避免两条订阅并成一条）。
- **删除**：确认框补充「会同时从 N 个策略组移除」；删除逻辑不变（清理 `use:` / `proxies:` / 规则引用 + 空组补 DIRECT）。

### 3.4 刷新订阅（已订阅之后）

三个刷新入口，行为统一为「**只按现有订阅配置重新拉节点，不重新分配组**」：

| 入口 | 现状实现 | 刷新后 |
|---|---|---|
| 卡片 ⟳「刷新节点」 | 内核 `PUT /providers/proxies/{name}`，按 `config.yaml` 里该 provider 的定义（首次保存/最近编辑保存的 `url`、`interval`）重新拉取 | 节点列表更新；`use:` 归属、组顺序、其他订阅、规则、手写注释全部不变 |
| 工具栏「全部刷新节点」 | 逐条调用上面的 `PUT` | 同上；已改为跳过本地 file provider（随本次一起提交） |
| 「刷新本地订阅」 | 从 `provider-sources.json` 里首次订阅保存的源地址重新下载 → 转成节点文件 → 内核重读 | 节点文件更新；`config.yaml` 与 `use:` 不写 |

- **刷新不经过** `saveProxyProviders` / `writeProxyProviders`：没有「备份→写盘→校验」事务，也没有任何 `proxy-groups` 编辑路径。这是硬约束（验收第 9 条用 `config.yaml` 哈希前后一致来钉）。
- 刷新失败：保留原节点列表 + 如实报错（现有行为），不 reload、不写盘、不影响归属。
- 归属的唯一真相是 `config.yaml`：如果用户手动删掉了某个 `use:`，刷新**不会**把它「恢复」成首次订阅时的样子；要恢复只能显式「编辑分组」。
- 订阅内容从标准 provider 变成 base64（或反之）时，刷新只更新节点数据；格式转换仍是用户显式点「转为本地订阅」，本轮不改这条链路。

## 4. 交互设计

### 4.1 弹窗结构（沿用现有 sheet 形态：标签在上、控件整行宽，宽度 520）

```
┌─ 添加订阅 / 编辑订阅 ─────────────────────────────┐
│ （「编辑分组」模式下这两行是只读摘要，不可改）      │
│ 名称   [ US-Premium                        ]      │
│ 订阅链接 [ https://…                        ]      │
│                                                   │
│ 加入策略组                        全选  反选  清空 │
│ 已选 4 / 15                                       │
│ ┌─ 可滚动清单（最高 200pt）────────────────────┐  │
│ │ ☑ 自动选择        已有 2 个订阅             │  │
│ │ ☑ 默认代理                                  │  │
│ │ ☑ 流媒体          include-all-providers    │  │
│ │ …                                           │  │
│ └─────────────────────────────────────────────┘  │
│ 取消后「默认代理」将没有节点来源，保存时自动补 DIRECT │
│                                                   │
│ [取消]                                  [保存]     │
│ 至少选择一个策略组；不选的话节点不会出现在「代理节点」页 │
└───────────────────────────────────────────────────┘
```

- 行：`Toggle` + `.toggleStyle(.checkbox)`；组名 `dsBody`；右侧 caption 说明（已有几个订阅 / include-all-providers）。
- 已勾选的组按文件顺序展示；不排序改写。
- 组数 > 8 时清单顶部出现搜索框（按组名过滤，不影响已勾选项）。
- 错误行固定占位（`Text(errorMessage ?? " ")`，`dsBody` + `error`），出现/消失不改变弹窗高度（`Docs/design.md` §6.4）。
- 按 AGENTS.md「带初值的表单弹窗必须用 `.sheet(item:)`」：弹窗改成 `SubscriptionDraft: Identifiable` 承载初值（模式 `.add / .editFull / .editGroups` / 名称 / URL / 已选组 / 原始组 / 错误），不再用页面级 `@State` + `.sheet(isPresented:)`。
- `.editGroups` 模式：隐藏名称/URL 输入框，改成一行只读摘要（`dsCaption`），底部只保留「取消 / 保存归属」。组清单组件与另外两种模式共用同一个子视图，行为完全一致。

### 4.2 默认值

| 场景 | 默认勾选 |
|---|---|
| 新增订阅 | **全选**（全部可加入的组） |
| 编辑已有订阅 | 按 `config.yaml` 当前 `use:` 回显（`include-all-providers` 组显示为已包含） |
| 保存时名称与现有订阅重名 | 弹窗打开时不知道重名，保存前检查：重名 → 错误行「已存在同名订阅，请改名」 |

> 已确认采用「默认全选」。代价：15 个组会一次全勾上，所以头部必须常驻「已选 N / M」，且反选/清空一键可达。

### 4.3 批量操作

- `全选`：勾上所有可加入的组（`include-all-providers: true` 的组本就是已包含，置灰勾选、不参与可改计数）。
- `反选`：在可加入的组里取反；`include-all-providers` 组保持不变。
- `清空`：清空所有可加入的组；`include-all-providers` 组不变。清空允许发生，但保存被拦下。

### 4.4 每行附加信息

- 组名。
- caption 优先级：`include-all-providers: true` → 「已包含全部订阅」（勾选框 disabled + 勾选态，且不能取消）；`include-all-proxies: true` → 「已包含全部普通节点（不含订阅）」但仍可勾选（订阅节点仍需 `use:` 才会进组）；否则「已有 N 个订阅」；N=0 时留空（不写「0 个订阅」，噪音）。
- 不显示组类型（select/url-test/fallback）：15 行里类型文案会把清单挤成两行，且对「选不选」没有决策价值。

### 4.5 校验（保存时拦，输入时不报错）

| 条件 | 处理 |
|---|---|
| 名称为空 / URL 不以 `http` 开头 | 沿用现有的保存按钮禁用 |
| 可加入组数 > 0，且一个都没勾（且没有 `include-all-providers` 组） | 底部错误行「至少选择一个策略组；不选的话订阅节点不会出现在「代理节点」页。」；保存禁用 |
| 名称与另一条订阅重名 | 错误行「已存在同名订阅「X」，请换个名字」；保存禁用 |
| 组清单在弹窗打开后被外部改动（组被删） | 保存前重读配置：剔除不存在的组；若剔除后为 0 → 错误行「策略组已被删除，请重新选择」 |
| 配置里 0 个策略组 | 组清单为空 + 说明卡片；保存禁用（见 4.6） |

### 4.6 零策略组（已定：不代建组，明确报错）

配置里没有任何 `proxy-groups` 时，「至少勾一个」无法满足。**本轮不代建策略组**，处理方式：

- 组清单区域改为空态说明（不要只留一个空框）：

  > 配置里还没有策略组。订阅节点必须加入至少一个策略组，才能在「代理节点」页使用。
  > 请先导入含 `proxy-groups` 的配置，或在 `config.yaml` 添加策略组后回到本页重试。

- 「保存」按钮禁用；不再继续校验名称/URL（避免用户以为填完就能存）。
- 不提供「+ 新建策略组」按钮，也不写 `proxy-groups`（非目标）。
- 内核在线时同样维持这条规则：宁可拦住，也不替用户生成一个可能不符合其分流结构的组。

### 4.7 订阅卡片

```
icloud  US-Premium  [86 节点] [本地]                ⟳  ⧉  🗑
VLESS 61 · HYSTERIA2 25 · SS 2
策略组  自动选择 · 默认代理 · 流媒体  +2           编辑
[流量进度条]  更新时间 …
```

- 有归属：`策略组` + 最多 3 个组名（`dsCaption`、secondary）+ 其余 `+N`（`.help` 显示完整名单）+ 右侧小按钮「编辑分组」（只改组）。
- 无归属：`warning` 图标 + 「尚未加入任何策略组，节点不会出现在「代理节点」页」+ 「选择策略组」按钮（打开 `.editGroups` 弹窗）。
- 替换现在的 `ProviderUsage.summary(count:)` 一行文案；计数仍可用于 hover 提示，但不再作为主信息。
- 卡片上的 ⟳ 刷新节点、本地订阅刷新、转换、删除按钮不变；刷新不会改动上面的组 chips（除非用户显式编辑）。

### 4.8 保存反馈（toast）

- 新增成功：「已添加订阅「X」，加入 3 个策略组」；仅 `include-all-providers`：「已添加订阅「X」，节点已随 include-all-providers 组生效」。
- 编辑成功：「已保存「X」，加入 2 个策略组」。
- 只改归属成功：「已更新「X」的归属：3 个策略组」／清到只剩 include-all：「「X」的节点已包含在全部策略组中」。
- 刷新成功/失败：沿用现有「内核节点「X」已刷新」/「刷新节点「X」失败，已保留原节点列表」——刷新**不**弹任何归属相关文案（它不改归属）。
- 内核离线：「订阅已保存到配置文件（加入 2 个策略组），内核启动后生效」（沿用现有离线文案分支）。
- 回滚：「配置无效，已回滚：…」/「操作已回滚：策略组「Y」…」（沿用现有事务文案）。

## 5. 写盘逻辑（这是本功能的核心）

### 5.1 单一解析口径

- 组名 / `use:` 的口径继续以 `ProviderUsage` 的行扫描为准（2 空格缩进的 `- name:`；块状与内联两种 `use:`）。
- 新增纯逻辑模块 `ProviderGroupBinding`（无 UI / 无文件 IO / 无 MainActor）负责：
  - 解析组：`name`、`type`、`use:` 条目、`proxies:` 条目数、`include-all*` 真值、组在文件中的行范围；
  - 反查归属：provider → 组名列表（按文件顺序）；
  - 生成新 YAML：`rewrite(yaml:desired:removed:renamed:)`。
- `ProviderUsage.groupReferences` / `groupNames` / `groupsMissingMembers` 保持不动（已有套件钉着）；新模块复用它的扫描口径，不写第三套正则。
- **归属的唯一真相是 `config.yaml` 里的 `use:` 行**：没有额外的「首次订阅快照」文件，也没有内存副本。弹窗每次打开都从磁盘重新求值；刷新路径根本不进入本模块。

### 5.2 目标状态的计算

一次保存的输入 = `providers`（订阅清单）+ `desired: [provider: Set<组名>]`（本次要调整归属的订阅）+ `renamed: [旧名: 新名]`。

对每个组：

```
final = 现有 use 条目
      − removedProviders（本次删除的订阅）
      − renamed.keys（改名前的旧名）
      + renamed[旧名]（按原位置换）
      然后对每个 desired[p]：
        若 p 属于该组 且该组不是 include-all-providers → 确保存在（追加到末尾）
        若 p 不属于该组 且该组不是 include-all-providers → 移除
```

- 未出现在 `desired` 里的 provider：归属不动（避免编辑一条订阅时碰其他订阅）。
- `desired` **只由用户显式保存归属的动作产生**；刷新订阅（3.4）不构造 `desired`，也不调用 `rewrite`。
- `include-all-providers: true` 的组：**不按 `desired` 增删**（全部订阅本来就全含），勾选态只用于展示；但组里若残留显式 `use:`，改名/删除仍要清理（否则旧名悬空会让 `mihomo -t` 拒绝整份配置）。`include-all-proxies` 只含配置里的普通节点，**不**跳过（订阅节点仍需 `use:`）。

### 5.3 两种 `use:` 写法的改写规则

| 现状 | 加 | 删 |
|---|---|---|
| 块状 `use:` + 列表项 | 末尾追加 `      - "名字"`（沿用该块缩进） | 删掉匹配的列表项；删到 0 条时整块 `use:` 删除 |
| 内联 `use: ["A", "B"]` | 重写为 `use: ["A", "B", "新"]`，保留行尾注释 | 重写剩余项；空了就删整行 |
| 没有 `use:` 键 | 在 `type:` 之后插入 `    use:` + 条目（无 `type:` 则在 `name:` 之后；缩进按组内字段 4 空格） | — |
| `use: []` | 直接写内联单元素 | 删整行 |

- 删除/新增都不重排已有条目、不删块内注释；新条目一律加双引号（组名/订阅名可能含中文、空格、`#`）。
- 只改 `proxy-groups:` 块内、当前组行范围内的内容；不碰 `proxies:`、`rules:`、其他顶层键。
- 列表项按 `ProviderUsage.scalar` 去引号后比较，写回时统一 `"名字"`。

### 5.4 空组兜底

- 取消最后一个组 / 删除最后一个 provider 导致某组 `use:` 与 `proxies:` 都空：
  - 沿用 `ProviderUsage.groupsMissingMembers` 预检；
  - 写盘前由现有 `EngineControl.injectDirectFallback` 给该组补 `proxies: [DIRECT]`，配置保持合法；
  - 弹窗行内提前预告（4.1 图示那行）；内核 reload 后该组为 DIRECT，不会整份配置校验失败。
- 这条兜底在删除订阅、取消勾选两条路径上都必须生效。

### 5.5 改名

- 页面在保存时给出 `renamed: [旧名: 新名]`。
- 写 provider 块时按新名重建（保留 `type: file` + `path:` 的本地 provider 定义，已有逻辑）。
- 组归属改写里按 5.2 先换名再按 `desired[新名]` 调整（通常 desired 等于原名下的组）。
- 修复 1.3 的 bug，不再出现「改名即退出全部组」。

### 5.6 刷新路径（只读，不写配置）

- 入口与现状代码：`SubscriptionsPage.update(_:)` / `updateAll()` → `M.api.updateProvider(name)`；本地订阅走 `AppModel.refreshLocalProviders()` → `provider-sources.json` 取源地址 → `store.writeProviderNodes` → `api.updateProvider(name)`。
- **硬规则**：这三条路径都不得调用 `saveProxyProviders` / `writeProxyProviders` / `ProviderGroupBinding.rewrite`，也不得写 `config.yaml`。它们只更新节点数据（http provider 由内核重拉，file provider 重写节点文件后内核重读）。
- 刷新失败：保留原节点列表，不写盘、不 reload（现有行为）；归属不会因为一次失败而变化。
- 转换成本地 provider（`convertProviderToLocalFile`）会改 `proxy-providers` 块里的 `type/path`，但**同样不碰 `use:`**；转换后页面 reload，归属 chips 照旧。
- 为什么强调：旧 `writeProxyProviders` 在没有删除 provider 时会重写第一个组的 `use:`。如果刷新链路误走保存事务，用户点一次「刷新」就可能把归属冲掉——这正是本功能要顺手消灭的风险。

### 5.7 事务与回滚（沿用现有）

`AppModel.saveProxyProviders` 的备份 → 写 → 空组预检 → `mihomo -t` → reload → 失败还原，整条路径不变，只额外接收 `desired` / `renamed`：

```swift
func saveProxyProviders(
    _ providers: [(name: String, url: String)],
    memberships: [String: Set<String>] = [:],
    renamed: [String: String] = [:]
) async -> Bool
```

`EngineControl.writeProxyProviders` 同步扩展签名，并在内部调用 `ProviderGroupBinding.rewrite` 替换旧第 4 步「重写第一个组」的逻辑。任何一步失败都还原备份（含 membership），UI 回到磁盘真值。

只改归属时（订阅清单与 URL 都没变）**不重建 `proxy-providers:` 块**：旧实现按 http 模板重建整块，会丢掉用户手写的 `filter` / `exclude-filter` / 自定义 `health-check`。判断依据是 `proxyProviders()` 的 name+url 与传入清单逐项相等。

### 5.8 离线 / 并发

- 内核未连接：只写盘 + 提示「内核启动后生效」（现有分支），归属照样写入。
- 弹窗打开期间配置被外部改：保存前重读 `config.yaml`，按最新组清单收敛（4.5 表的最后一行）。
- 刷新与归属编辑并发：刷新进行中（`busy` 非空 / `engine.isBusy`）「编辑分组」与归属保存置灰；归属保存进行中不启动刷新。

## 6. 技术落点

| 文件 | 改动 |
|---|---|
| `Sources/Model/ProviderGroupBinding.swift` | **新增**：组解析、归属反查、`rewrite`（纯逻辑，需在 pbxproj 注册；**不做建组**） |
| `Sources/XPC/EngineControl.swift` | `writeProxyProviders(_:memberships:renamed:)`；删掉「重写第一个组」的第 4 步，改为调用 binding；保留 provider 块重建、引用清理、空组兜底 |
| `Sources/Model/AppModel+Config.swift` | `saveProxyProviders` 接收 `memberships` / `renamed`；调用方（订阅页）负责读盘求组清单、改名撞名预检 |
| `Sources/UI/Subscriptions/SubscriptionsPage.swift` | `SubscriptionDraft`（`.add/.editFull/.editGroups`）+ `.sheet(item:)`；组清单 UI；卡片 chips /「编辑分组」/「编辑订阅」；保存时构造 memberships、renamed |
| `Sources/UI/Subscriptions/SubscriptionsPage.swift` 的 `update` / `updateAll`、`AppModel.refreshLocalProviders` | **不改行为**（只按现有守卫置灰）。验收用 `config.yaml` 哈希证明刷新不写盘 |
| `Sources/UI/DesignTokens.swift` | 不改（复用 `DS.*` 与 `Card` / `dsButton` / `dsCaption`） |
| `Docs/design.md` | 实施后补一条：订阅弹窗的多选清单契约（勾选行、批量操作、错误行） |
| `AGENTS.md` | 实施后补：provider→组归属的唯一写盘入口是 `ProviderGroupBinding.rewrite`，不要再在 `writeProxyProviders` 里手写第二套 `use:` 逻辑 |
| `Scripts/run-tests.sh` | 登记 `providergroupbind-tests` |
| `Tests/ProviderGroupBinding/main.swift` | **新增**套件（Tests/ 不入库，见 7 备注） |

## 7. 回归测试（新套件 `providergroupbind-tests`）

纯逻辑，直接编译 `Sources/Model/ProviderGroupBinding.swift` + `ProviderUsage.swift` + `YamlScalar.swift`：

1. 块状 `use:`：新增一条追加在末尾，已有顺序与注释不变。
2. 块状 `use:`：删到 0 条 → 整块 `use:` 移除。
3. 内联 `use: ["A", "B"]`：加/删后重写正确，行尾注释保留。
4. 无 `use:` 的组：新增后 `use:` 插在 `type:` 之后，缩进 4 空格、条目 6 空格。
5. 组内同时有 `proxies:`：只动 `use:`，不碰 `proxies:`。
6. 改名：`use:` 里旧名原位换成新名，其他 provider 不动；跨多个组都生效。
7. 删除 provider：所有组引用清干净，其他 provider 保留。
8. `include-all-providers` 组：`desired` 勾它不写 `use:`，取消也不删任何东西；里残留的显式 `use:` 遇到改名仍原位替换；`include-all-proxies` 组仍正常写 `use:`。
9. `membership(in:)`：块状/内联都认；重复项去重；`rules:`/`proxies:` 里同名文本不算。
10. 幂等：同一 plan 连跑两次，输出与第一次一致。
11. 无关区域零改动：除目标组外逐行 diff 为空（`rules:`、`proxies:`、`proxy-providers:`、其他顶层键、注释都包含在内）。
12. 交叉校验：同一份 yaml 上，`membership(in:)` 得到的组名集合与 `ProviderUsage.groupReferences` 的计数逐项一致（两套解析口径不漂移）。
13. 真实样本形态：拿本机 15 组 2 个带 `use:` 的结构（组名脱敏）跑一遍，除目标组外所有字节不变。
14. 刷新不变性（手工/脚本验收，纯逻辑无法覆盖）：`config.yaml` 的 sha256 在刷新前后一致（见验收 9）。

> `Tests/` 不在版本管理里：套件写在本机，`run-tests.sh` 登记后即本地可跑；新克隆的仓库 `bash Scripts/restore-tests.sh --check` 会明确列出这类从未入库的套件（与其它从未入库的新套件同状态）。

## 8. 验收清单

1. 新增订阅默认全选，头部计数正确；`全选`/`反选`/`清空` 行为正确；`include-all-providers` 组置灰勾选。
2. 清空后保存被拦，底部错误行出现且弹窗高度不变；勾一个即恢复可保存。
3. 新建订阅后 `config.yaml` 里每个被勾组的 `use:` 都出现该订阅；未勾的组不变。
4. 内核在线：reload 成功，代理节点页对应组里能看到节点；内核离线：写盘成功、启动后生效。
5. 编辑归属：取消一个组 → 组内节点消失、组不空时报文正常；取消到组空 → 自动补 DIRECT、toast/行内提示一致。
6. 改名：`use:` 里旧名变新名，卡片归属不变（回归 1.3 的 bug）。
7. 删除：所有组引用清理，删空的组补 DIRECT，不误伤其他订阅。
8. 零策略组配置：组清单显示空态说明、保存禁用、`config.yaml` 不被写（sha256 不变）。
9. 刷新不变性：记下 `config.yaml` 的 sha256 → 单条「刷新节点」+「全部刷新节点」+（有本地订阅时）「刷新本地订阅」→ 哈希一致、组 chips 不变；刷新失败路径同样不写盘。
10. 二次编辑：首次添加成功后点「编辑分组」改两轮，每次打开回显磁盘当前值；reload 后节点在对应组进出正确；「编辑订阅」改名/改 URL 后归属仍按本次勾选。
11. Light / Dark 两端看弹窗与卡片；`bash Scripts/run-tests.sh --only providergroupbind` 全绿；`xcodebuild ... Debug build` 通过。
12. 不触发 TUN / 系统代理 / Helper 变更（本功能只改订阅与 `use:`）。

## 9. 风险与已知限制

- **影响面**：默认全选会把新订阅塞进全部组（本机 15 个）。这是用户明确要求的行为，但需在弹窗里常驻计数与批量操作，避免「一次点保存，所有组都变」的意外。
- **解析限制（沿用现状）**：`- {name: X, type: …}` 内联映射组、`- type:` 在前的组取不到组名，不进入清单；锚点/多行标量不解析。
- **写盘依赖行扫描**：格式特别怪（`use` 与条目同行多值、Tab 缩进、流式 YAML）的配置可能不识别；此时该组不参与归属改写，保存后由 `mihomo -t` 兜底，失败回滚。
- **与现有 `ProviderUsage` 的边界**：统计口径与新模块必须一致；实现时以同一份扫描函数为底座，避免两边漂移（参照 ProviderUsage 的历史教训）。
- **回滚粒度**：整份配置回滚（现有事务），不会出现「订阅写了一半」的中间态。
- **「按首次订阅时的配置」的边界**：归属以 `config.yaml` 的 `use:` 为准，刷新只读；但订阅**源地址**用的是当前配置里记录的值——如果用户后来改过 URL/名称，刷新按最新值拉取，不会回到首次 URL。若要固化源地址，只有本地 provider 的 `provider-sources.json` 会保存一份。
- **零组不可存**：这是有意的硬拦，不给「先存订阅、组以后再说」的旁路；用户需要先有策略组。

## 10. 已确认的决策

- 新增订阅默认全选；`include-all-providers` 组置灰勾选。
- 零策略组不代建、明确报错并引导。
- 首次订阅成功后可反复二次编辑归属：卡片「编辑分组」（只组）+「编辑订阅」（全量）两个入口。
- 刷新按当前配置里的 URL/名称拉取（即首次保存的那条，除非用户后来显式改过），只拉节点、不改归属。
- 组数 > 8 才出现搜索框。

## 11. 实施顺序（确认后）

1. `ProviderGroupBinding` + 回归套件（纯逻辑先钉住，含无关区域零改动、交叉校验）。
2. `EngineControl.writeProxyProviders` 接入 + `AppModel.saveProxyProviders` 传参（含改名修复）。
3. 订阅页弹窗与卡片 UI（`.sheet(item:)` 三模式、组清单、零组空态、编辑分组/编辑订阅）。
4. 刷新路径回归验收（哈希不变）+ 文档（`Docs/design.md`、`AGENTS.md`）、`CHANGELOG.md`、全套回归 + Debug build。

## 12. 实施记录（2026-11-17）

| 文件 | 落地 |
|---|---|
| `Sources/Model/ProviderGroupBinding.swift` | 新增。组解析（含 `- type:` 在前的 F24 组）、归属反查、`rewrite`（块状/内联增删、改名、删除、include-all-providers 清理） |
| `Sources/XPC/EngineControl.swift` | `writeProxyProviders(_:memberships:renamed:)`；删除「重写第一个组」的旧第 4 步，改为调用 binding；改名不再算删除 |
| `Sources/Model/AppModel+Config.swift` | `saveProxyProviders` 接收 `memberships` / `renamed` |
| `Sources/UI/Subscriptions/SubscriptionsPage.swift` | `SubscriptionDraft` + `.sheet(item:)` 三模式；组清单（全选/反选/清空、搜索、include-all 置灰、至少一个、空组预告、零组空态）；卡片归属 chips /「编辑分组」/「编辑订阅」 |
| `Scripts/run-tests.sh` + `Tests/ProviderGroupBinding/main.swift` | `providergroupbind-tests`，35 条断言 |
| `ClashHalo.xcodeproj/project.pbxproj` | 登记新源文件 |
| `Docs/design.md` / `AGENTS.md` / `CHANGELOG.md` | 多选清单契约、归属唯一写盘入口、变更记录 |

验证：

- `bash Scripts/run-tests.sh --only providergroupbind` → PASS 35 断言。
- `xcodebuild -project ClashHalo.xcodeproj -scheme ClashHalo -configuration Debug build` → BUILD SUCCEEDED。
- 全套回归 PASS 25 / FAIL 2 / MISSING 3；两套红（`configwriteaudit-tests` 的 secret 脱敏、`quickrule-tests` 的 v6 /128）与本次改动无交集，属既有未完成项；三套 MISSING 是 `Tests/` 不入库所致。
- 真实配置只读验证（不写盘、不输出组名/URL）：本机 15 个组 / 2 个组带 `use:`；`membership` 与 `ProviderUsage.groupReferences` 逐项一致；目标归属=现状时输出与原文**逐字节相同**；对一个合成 provider 做「加组 → 改名 → 删除」后能还原原文。
- 未做：真机点击验收（本机 `/Applications/ClashHalo.app` 正在运行，未用 Debug 产物覆盖）、刷新前后 `config.yaml` 哈希实测（只审阅代码路径，确认刷新不调用保存事务）。
- 环境假设：按你确认的「零组不代建、刷新用当前配置 URL」实现；真实订阅/节点/组名未写入仓库或文档。
