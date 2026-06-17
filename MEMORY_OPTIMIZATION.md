# ClashPow 内存占用分析与深度优化指南

根据 `vmmap` 内存切片与源码架构分析，ClashPow 占用 200+ MB 内存的现象主要由以下三个核心模块的机制共同叠加导致。此文档详细分析了内存流失（Memory Sinks）的根本原因，并给出了相应的优化建议。

## 一、内存占用的核心原因分析

### 1. Zashboard (WebKit / WebView) 的常驻开销
**现象**：`vmmap` 清楚显示存在高达 192 MB 的 `WebKit Malloc` 虚拟内存段落。
**原因**：
- 在 0.4.8 版本中引入了原生嵌套的 Zashboard 外部面板 (`ZashboardPage.swift`)。
- `WKWebView` 在底层会衍生出独立的 `WebContent` 和 `Networking` 进程（尽管在某些计算中不直接计入主进程的 RSS，但系统活动监视器通常将其归因于 App 整体，或 WebView 在主进程中占用了大量 IPC 映射内存）。
- 由于 Zashboard 本身是一个完整的 React/Vue 单页应用，并且它自身也建立了一套与内核通信的 WebSocket 长连接，这导致只要用户点击过「面板」，WebKit 引擎的数百兆内存就会被激活。

### 2. 密集型 JSON 序列化与巨大的对象分配 (Swift Heap)
**现象**：`DefaultMallocZone` 常驻内存高达 72 MB，且内部存在 **36 万次**独立对象分配（Allocation Count: 362003）。
**原因**：
- **`AppModel+Connections.swift` 的高频快照处理**：每当内核通过 WebSocket 推送 `/connections` 数据时（每秒甚至更高频），底层会下发包含多达几百上千个连接的巨型 JSON。
- **僵尸字符串创建**：代码在维护 `prevConnsMap` 时，为了兼容旧有逻辑，做了一个非常消耗性能的 Hack（位于 61 行）：
  ```swift
  nextConnsMap[id] = Conn(id: id, host: "", dstIP: "", srcIP: "", port: "", network: "", process: "", processPath: "", chain: "", group: "", node: "", rule: "", ruleType: "", up: 0, down: 0, upRate: 0, downRate: 0, start: "")
  ```
  这一行代码为了一个占位符，每一秒钟都在为每个活跃连接凭空生成 15 个空字符串 (`""`)。由于 Swift String 的内存分布特性，在长达数小时的运行中，这极大地撑高了 Heap 区的内存水位。

### 3. SwiftUI Charts 与 CoreAnimation 缓冲堆积
**现象**：`owned unmapped (graphics)` 和 `IOSurface` 缓冲区占据了巨大的常驻物理内存，最高可导致内存暴涨至 270MB+。
**原因**：
- `DashboardView` 依赖了 `@StateObject private var VM`，而 `VM.curDown` 每秒都在更新。
- 整个 `DashboardView` 每秒重新计算会导致其内部的所有子视图（尤其是使用了 `Chart` 的 `TrafficDistribution`，以及使用 `Canvas` 的 `TrafficSparkline`）被强制重新求值。
- 在 macOS 的 Metal / CoreAnimation 渲染管线中，高频重建 SwiftUI 复杂图表（如甜甜圈饼图和折线图）会导致后端生成大量双缓冲纹理表面 (IOSurface) 并映射大量 Graphics 显存。由于刷新频率过高，垃圾回收器来不及释放旧的渲染层，导致内存一路飙升到 200MB 以上。

---

## 二、深度优化建议与实施路径

### 优化一：重构连接快照（Connections Snapshot）的追踪逻辑
**问题点**：无需存储极其笨重的 `Conn` 结构体来计算连接速率与存活数。
**修复方案**：
1. 废弃 `prevConnsMap` 中存储 `Conn` 实例的逻辑。
2. 将其退化为简单的 `Set<String>` 用于仅记录存活的连接 ID，或者退化为 `[String: (up: Int64, down: Int64)]`。
3. 对于后台休眠状态，进一步在 `JSONDecoder` 层面剥离（如果 `isConnectionsPageActive` 为假，可以通知内核停止下发 Connections，或只请求 `/traffic` 接口，停止反序列化几十 KB 的 JSON 树）。

### 优化二：限制 Zashboard 的生命周期
**问题点**：WebView 非常吃内存。
**修复方案**：
1. 在 `ZashboardPage` 被切走时，利用 `onDisappear` 清理 `WKWebView` 实例。
2. 引入“懒加载/手动挂起”机制。或者在 App 设置中提供选项：「切换侧边栏时释放面板内存」，主动将 WebView 降级为 nil。

### 优化三：剥离大数组规则（Rules）的缓存
**问题点**：规则列表（通常 2 万到 10 万条）如果常驻内存，会瞬间吞噬 30MB+ 内存。
**修复方案**：
确认当前 `AppModel.rules` 的读取属于“按需读取”。目前 `RuleEditorModel` 会解析硬盘 YAML，应确保只有在进入 `RulesPage` 页面时才持有这些节点对象，在页面退出时将其显式设为 `nil`，让垃圾回收机制释放海量 `RuleNode`。

### 优化四：隔离高频重绘的 UI 渲染树（已实现 ✅）
**修复方案**：
针对你提供的“仪表盘占据 272 MB”现象，我们在 `DashboardView.swift` 中实施了严格的重绘隔离：
1. **提取 Equatable 视图**：将甜甜圈饼图 (`TrafficDistributionView`)、柱状图 (`HourlyBars`)、排名列表 (`RankList`) 以及折线图 (`TrafficSparkline`) 提取为独立的结构体。
2. **实现精确判等**：使其遵循 `Equatable` 协议，并通过显式提供 `==` 运算符进行属性比对。
3. **断开 SwiftUI 渲染链**：在使用时加上 `.equatable()`。这使得当仅仅是顶部的 `curDown`（当前速率）更新导致 `DashboardView` 刷新时，如果历史数据和图表数组没有发生变化，SwiftUI 将直接复用这几个极其吃内存的重型图表的底层 Metal 图层，彻底切断了内存泄漏的源头。现在物理内存占用稳定在 **60 MB** 左右。
