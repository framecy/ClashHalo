# ClashHalo Design System

工程级 UI 规范。实现真相源是 `Sources/UI/DesignTokens.swift` 与共享组件（`PageHead` / `Card` / `ContentUnavailable` / form rows）。本文件描述目标、令牌、组件契约和 Light/Dark 规则。

**目标平台**：macOS 14+，视觉语言对齐现代 macOS 系统风格（macOS 27 一代：语义色、材质分层、连续圆角、工具型密度）。  
**主题**：完美支持 **Light / Dark**，跟随系统 Appearance，禁止页面级 `preferredColorScheme` 硬锁。  
**品牌**：单一 accent（Halo Green），无用户可选主题色。

---

## 1. 产品气质

ClashHalo 是**网络运维工具**，不是营销站点。

| 要 | 不要 |
|---|---|
| 密集、可扫描、状态优先 | 大 hero、装饰插画、营销卡片 |
| 系统控件 + 统一自定义壳 | 每页自创一套圆角/字号/灰阶 |
| 语义色表达状态 | 散落的 `.red` / `.green` / raw RGB |
| Light/Dark 同等可读 | 只调 dark、light 发灰或发白 |
| 8pt 网格 | 随机 5/7/9/11/13 间距 |

信息层级：

1. **系统状态**（核心 / 系统代理 / TUN）
2. **当前任务**（页标题 + 关键动作）
3. **数据面**（表格、列表、图、表单）
4. **辅助说明**（caption / toast / empty）

---

## 2. 表面层级（Surface）

现代 macOS 用“材质 + 实色抬升”表达层级。ClashHalo 固定四层：

| 层级 | Token | 用途 |
|---|---|---|
| L0 Window | `DS.Palette.windowBg` | 主内容底 |
| L1 Sidebar | `DS.Palette.sidebarBg` | 导航栏底（可叠 vibrancy） |
| L2 Elevated | `DS.Palette.cardBg` | Card / 面板 / 表格容器 |
| L3 Control | `DS.Palette.controlBg` | 输入框、chip 内底、选中条 |
| Overlay | `DS.Palette.overlayBg` | Toast、浮层详情卡 |

规则：

- **不要**在 Card 内再嵌套同视觉权重的 Card。
- 列表/表格直接坐在 L0 或 L2，不要额外包装饰壳。
- Light：抬升靠**白卡片 + 细描边 + 极弱阴影**。  
- Dark：抬升靠**更浅的实色表面 + 细亮边**，阴影几乎无效，禁止靠大阴影假分层。

---

## 3. 颜色

### 3.1 原则

1. 所有颜色走 `DS.Palette.*`。
2. 动态色用 `NSColor(name:dynamicProvider:)`，在 light/dark 分别标定，不靠“同一个 opacity 碰运气”。
3. 文本优先系统语义：`Color.primary` / `Color.secondary` / `Color.tertiary`（已自适应）；需要固定对比时用 `DS.Palette.text*`。
4. 状态色必须在 light/dark 都保持可辨，且不只依赖色相（可配合图标/文案）。

### 3.2 品牌与状态

| Token | 语义 | 使用 |
|---|---|---|
| `accent` | 品牌主色 / 主操作 / 选中 | 主按钮 tint、当前节点、TUN on |
| `accentSoft` | 选中底 | 列表选中、chip 选中 fill |
| `accentStrong` | 强调描边/深色文字上的 accent | 少用 |
| `ok` | 成功 / 低延迟 / 在线 | 就绪点、延迟 <100ms |
| `warn` | 警告 / 中延迟 / 需关注 | 冲突、中延迟、升级提示 |
| `error` | 错误 / 高延迟 / 危险操作 | 失败、断开、ERROR 日志 |
| `info` | 中性信息 / 直连 / 冷数据 | 直连分布、信息 chip |
| `upload` | 上传流量 | 仪表盘上传 |
| `download` | 下载流量 | 仪表盘下载（可用 accent） |

### 3.3 网络角色色（网络拓扑）

固定映射，禁止页面内 switch 再写 raw `.cyan/.orange`：

| Kind | Token |
|---|---|
| physical | `rolePhysical` |
| proxyTun | `accent` |
| tailscale | `roleTailscale` |
| zerotier | `roleZerotier` |
| oray | `roleOray` |
| otherTun | `roleOther` |

### 3.4 中性 fill / stroke

| Token | 典型用途 |
|---|---|
| `track` | 进度底条 |
| `fillFaint` | 极浅 hover / 行底 |
| `fill` | 选中段、分段底 |
| `hairline` | chip 底、弱分割 |
| `border` | 控件描边、卡片边 |
| `separator` | Divider 语义色 |

Light 的 border 略深一点保证轮廓；Dark 的 border 用低透明亮边，避免“泥灰块”。

### 3.5 对比要求

- 正文 vs 背景：可轻松阅读，不为了“高级灰”牺牲对比。
- `secondary` 只用于次要信息，不用于主数值。
- 危险按钮：系统 destructive 语义 + `error` 色，不只改文字色。
- Toast：material 背景 + `border`，文字用 primary。

---

## 4. 字体

使用 SF Pro / SF Mono，全部经 `Font.ds*`：

| Token | Size | Weight | 用途 |
|---|---|---|---|
| `dsPageTitle` | 22 | bold | 页标题（工具型，避免过大） |
| `dsSection` | 17 | semibold | 区块/问候 |
| `dsStatValue` | 20 | bold rounded | 仪表数字 |
| `dsLabel` / `dsCardLabel` / `dsLabelBold` | 13 | r/sb/b | 强调标签 |
| `dsBody` 系 | 12 | r/m/sb/b | 默认正文 |
| `dsMono` / `dsMonoBold` | 12 | mono | IP/端口/延迟/日志 |
| `dsCaption` | 11 | regular | 版本号、辅助 |

禁止：

- 页面内 `.font(.system(size: N))`（图标用 `DS.Icon.*` + `.font(.system(size: DS.Icon.x))` 除外，且优先封装）
- 负字距、随视口缩放字号
- 为“好看”把 body 提到 14+ 导致表格密度崩坏

---

## 5. 间距与圆角

### Spacing（8pt 网格）

`xs=4 · s=8 · m=12 · l=16 · xl=20 · xxl=24 · xxxl=32`

页面内容默认：`padding(.horizontal, DS.Spacing.xl)` + bottom `xxl`。  
Card 内边距：`l`。  
表单行垂直：`s`（8）统一，不再写 `padding(.vertical, 5)`。

### Radius

| Token | Value | 用途 |
|---|---|---|
| `chip` | 6 | 小标签 |
| `control` | 8 | 输入/按钮/小卡片 |
| `card` | 10 | 主 Card（≤10，贴合系统设置风格） |
| `panel` | 12 | 侧栏浮层/大面板 |

不要超过 12。不要椭圆大卡片。

### Icon

`sm=14 · md=16 · lg=20 · xl=28 · hero=48`

---

## 6. 组件契约

### 6.1 Shell

- `NavigationSplitView` + sidebar list（系统 sidebar style）
- 侧栏头：App icon + 名称 + 版本
- 侧栏底：系统代理 / TUN 开关 + 核心状态
- 详情区背景：`windowBg`
- Toast：底部居中 capsule + ultraThinMaterial

### 6.2 `PageHead`

- 左：title (`dsPageTitle`) + 可选 desc (`dsBody` + secondary)
- 右：`controlSize(.small)` 动作组
- 不放营销副文案

### 6.3 `Card`

```
[ icon + title (secondary)          actions ]
[ content                                      ]
```

- 背景 `cardBg`，描边 `border`
- Light 可加极弱阴影；Dark 无阴影
- `pad` 控制内容是否自带内边距

### 6.4 Form rows

`NumRow` / `ToggleRow` / `TextRow` / `PickerRow` / `StringListRow`：

- 左 label `dsBody`
- 右控件列宽 `DS.Layout.fieldTrailing`
- 输入统一 `inputStyle()` / `DSTextFieldStyle`
- 变更确认：失焦或「应用」按钮，保持现有交互

### 6.5 Toolbar strip（连接/日志/规则）

统一：

- 控件高度：`DS.Layout.controlHeight = 32`（tab / 按钮 / 搜索框 / 输入框同源）
- 工具栏控件：`dsToolbarControl()`（`.regular` + 固定 32）
- 搜索框：`dsSearchFieldChrome()`（固定 32）
- 高度节奏：vertical padding `s`/`m`
- 背景 `DS.Palette.chromeBg`（轻材质感实色）
- 搜索框：leading magnifyingglass + plain field + `controlBg` 底
- 水平 inset：`DS.Layout.pageContentInset`，Table 用同 token `contentMargins`

### 6.6 Empty

`ContentUnavailable(text, icon)`：居中、弱图标、单行/两行说明，无插画。

### 6.7 Status

- 状态点：6–8pt circle，`ok` / `error` / `warn` / `secondary`
- 延迟：`delayColor()` 已映射到 ok/warn/error
- 开关：系统 `Toggle` + `.switch`，mini/small 按密度选

---

## 7. Light / Dark 验收清单

每个改动的页面至少心中过一遍：

**Light**

- [ ] 卡片与窗口底有清晰分离，不是一片白
- [ ] 边框可见但不脏
- [ ] secondary 文字仍可读
- [ ] accent 按钮对比足够
- [ ] 表格/日志无“发灰看不清”

**Dark**

- [ ] 卡片比窗口底明显抬升一层
- [ ] 无大块纯黑死区与纯白刺眼边
- [ ] 状态色不荧光过曝
- [ ] 选中态 `accentSoft` 可辨
- [ ] 分割线/描边不消失

**交互**

- [ ] 系统切换 Appearance 时即时更新（dynamic color，不缓存 NSColor 静态快照）
- [ ] 无页面强制 dark/light
- [ ] Zashboard 外链 theme 参数跟随 `effectiveAppearance`

---

## 8. 工程落地规则

### 允许

```swift
.foregroundStyle(DS.Palette.accent)
.background(DS.Palette.cardBg)
.font(.dsBody)
.padding(DS.Spacing.l)
.clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
```

### 禁止（pre-commit / review 拦）

```swift
.font(.system(size: 11))                 // 非 DS.Icon 场景
.foregroundColor(.red)                   // 用 DS.Palette.error
Color(red:g:b:)                          // 除 DesignTokens 内
.preferredColorScheme(.dark)
cornerRadius(6)                          // 用 DS.Radius.*
padding(.vertical, 5)                    // 用 DS.Spacing.*
```

### 文件职责

| 文件 | 职责 |
|---|---|
| `Sources/UI/DesignTokens.swift` | 令牌 + 输入样式 + 共享小部件 + Preview |
| `Sources/App/ContentView.swift` | Shell、`PageHead`、`Card` |
| `Sources/UI/**` | 页面只组合令牌与共享组件 |
| `Docs/design.md` | 本规范 |

### 改 UI 的 PR 自检

1. Light + Dark 各看主路径一页
2. `rg "\\.font\\(\\.system\\(size:" Sources/UI Sources/App`
3. `rg "foregroundColor\\(\\.(red|green|orange|cyan|blue|purple)" Sources/UI`
4. Debug build 通过

---

## 9. 布局密度参考

| 区域 | 建议 |
|---|---|
| 主窗口默认 | 1180×780，最小 940×620 |
| 侧栏 | min 200 / ideal 220 / max 260 |
| 仪表盘栅格间距 | `DS.Spacing.l` |
| 统计条高度 | `DS.Layout.statHeight` (64) |
| 表单右列 | `DS.Layout.fieldTrailing` (160) |
| 菜单栏面板 | 紧凑 card 堆叠，宽度约 280–320 |

---

## 10. 动效

- Toast：`spring` 短时出现/消失
- 路由切换：系统默认，不加自定义大动画
- 进度/流量：数据驱动，不装饰性 looping 动画抢注意力

---

## 11. 版本记录

| Date | Note |
|---|---|
| 2026-07-14 | 初版：macOS 27 系统风格、完整 Light/Dark 令牌、工程约束与组件契约 |

实现以代码为准；规范与代码冲突时，先修代码再回写本文。
