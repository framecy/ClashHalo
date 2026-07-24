// DashboardPage — 总览：实时速率 / 流量趋势 / 出口链路 / 分布与排名。
// 视觉基线：design_handoff_clashpow 01-dashboard。数据全部来自 mihomo 实时接口。
import SwiftUI

struct DashboardPage: View {
    @EnvironmentObject var M: AppModel
    enum Range { case today, month }
    @State private var range: Range = .today

    /// 模式切换 — 原型顶栏 Seg（规则 / 全局 / 直连）。
    private var modePicker: some View {
        DSSegmentedControl(selection: Binding(
            get: { M.mode },
            set: { newValue in
                guard newValue != M.mode else { return }
                M.setMode(newValue)
            }
        ), choices: [
            DSChoice("规则", "rule", systemImage: "arrow.triangle.branch"),
            DSChoice("全局", "global", systemImage: "globe"),
            DSChoice("直连", "direct", systemImage: "arrow.right")
        ])
        // 不写死宽度：228 比三段内容宽，各段居中后轨道尾部会空出一截死区。
        .fixedSize()
    }

    private var rangePicker: some View {
        DSSegmentedControl(selection: $range, choices: [
            DSChoice("今日", Range.today),
            DSChoice("本月", Range.month)
        ])
        .fixedSize()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Layout.gridGutter) {
                PageHead(title: "仪表盘") {
                    modePicker
                    // 采样间隔是页面级设置 —— 放页面顶栏而非流量卡头，
                    // 卡头空间留给图例，窄窗口下不再互相压缩。
                    DSMenuPicker(selection: $M.trafficRefreshInterval, choices: [
                        DSChoice("1s", 1.0),
                        DSChoice("2s", 2.0),
                        DSChoice("3s", 3.0),
                        DSChoice("5s", 5.0),
                        DSChoice("10s", 10.0)
                    ])
                    .frame(width: 76)
                    .fixedSize()
                    Button { M.openZashboard() } label: {
                        Label("面板", systemImage: "safari")
                    }
                    .dsButton()
                }
                .padding(.horizontal, -DS.Layout.pageContentInset)

                // Row 1 — stat 行：4 等分列。
                // 不用 `.adaptive(minimum:)`：它在宽窗口会开出十几条 150pt 轨道，
                // 4 张卡只填前 4 条，右侧留下大片空轨道。窗口最小宽度已保证
                // 4×gridMinStat + gutter 放得下，所以固定 4 列即可。
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: DS.Layout.gridMinStat),
                                                             spacing: DS.Layout.gridGutter),
                                         count: 4),
                          spacing: DS.Layout.gridGutter) {
                    DSStatCard(label: "实时下载",
                               value: rateValue(M.curDown), unit: rateUnit(M.curDown),
                               sub: "▼ \(fmtBytes(Double(M.downloadTotal))) 累计",
                               accent: true)
                    DSStatCard(label: "实时上传",
                               value: rateValue(M.curUp), unit: rateUnit(M.curUp),
                               sub: "▲ \(fmtBytes(Double(M.uploadTotal))) 累计")
                    DSStatCard(label: "活跃连接",
                               value: "\(M.activeConnectionsCount)",
                               sub: "访问目标 \(uniqueHosts)")
                    DSStatCard(label: "核心内存",
                               value: memValue, unit: "MB",
                               sub: String(format: "引擎 %.0f · GUI %.0f", Double(M.memory) / 1_000_000, M.appMemoryMB))
                }

                // Row 2–4 — 原型内容栅格：三列，宽卡跨 2 列表达 `2fr 1fr`。
                // 用 Grid 而不是 HStack，列宽才能跨行对齐。
                // 定高逐 cell 施加：加在 GridRow 上会按 cell 分发且默认垂直居中，
                // 左右列固有高度不同时就会上下错位、超出部分被 Card 裁掉。
                Grid(alignment: .top,
                     horizontalSpacing: DS.Layout.gridGutter,
                     verticalSpacing: DS.Layout.gridGutter) {
                    GridRow {
                        Card(title: "实时流量", icon: "chart.xyaxis.line",
                             height: DS.Layout.cardHeightLg, actions: {
                            HStack(spacing: DS.Spacing.m) {
                                legendDot("下载", DS.Palette.download)
                                legendDot("上传", DS.Palette.upload)
                            }
                            .fixedSize()
                        }) {
                            TrafficSparkline(down: M.downSeries, up: M.upSeries)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .drawingGroup()
                        }
                        .gridCellColumns(2)

                        Card(title: "流量分布", icon: "chart.pie.fill",
                             height: DS.Layout.cardHeightLg, actions: { rangePicker }) {
                            distribution
                        }
                    }

                    GridRow {
                        Card(title: "当前链路", icon: "point.topleft.down.to.point.bottomright.curvepath",
                             height: DS.Layout.cardHeightSm,
                             actions: { DSKindBadge(text: "\(modeLabel(M.mode))模式") }) {
                            ChainView(hops: chainHops)
                        }
                        .gridCellColumns(2)

                        Card(title: "出口流量分布", icon: "server.rack",
                             height: DS.Layout.cardHeightSm) {
                            RankList(rows: topNodes, accent: DS.Palette.download, mode: .bytes).equatable()
                        }
                    }

                    GridRow {
                        Card(title: "高频规则", icon: "list.number",
                             height: DS.Layout.cardHeightMd) {
                            RankList(rows: topRules, accent: DS.Palette.warn, mode: .count).equatable()
                        }
                        Card(title: "热门域名", icon: "globe",
                             height: DS.Layout.cardHeightMd) {
                            RankList(rows: topHosts, accent: DS.Palette.info, mode: .bytes).equatable()
                        }
                        Card(title: "策略组排名", icon: "rectangle.3.group.fill",
                             height: DS.Layout.cardHeightMd) {
                            RankList(rows: policyGroupRows, accent: DS.Palette.accent, mode: .bytes).equatable()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.bottom, 26)
        }
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            DSDot(color: color, size: 6)
            // fixedSize：窄卡头下宁可整体溢出裁切，也不让两字标签竖排折行
            Text(label).font(.dsCaption).foregroundStyle(.secondary).fixedSize()
        }
    }

    // MARK: 数值拆分（值 / 单位分离，供 stat-card 排版）

    private func rateValue(_ b: Int64) -> String {
        let v = Double(b)
        if v >= 1_000_000 { return String(format: "%.1f", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0f", v / 1_000) }
        return String(format: "%.0f", v)
    }

    private func rateUnit(_ b: Int64) -> String {
        let v = Double(b)
        if v >= 1_000_000 { return "MB/s" }
        if v >= 1_000 { return "KB/s" }
        return "B/s"
    }

    private var memValue: String {
        String(format: "%.0f", Double(M.memory) / 1_000_000 + M.appMemoryMB)
    }

    // MARK: aggregations (read precomputed snapshot — no per-render work)

    private var uniqueHosts: Int { M.dash.uniqueHosts }
    private var policyGroupRows: [Rank] { M.dash.policyGroups }
    private var topHosts: [Rank] { M.dash.hosts }
    private var topNodes: [Rank] { M.dash.nodes }
    private var topRules: [Rank] { M.dash.rules }

    /// 当前链路 — 本机 → 策略组 → 出口节点 → 目标。
    /// 取第一个可选择的策略组，逐层解析 `now` 直到落到真实节点。
    private var chainHops: [ChainView.Hop] {
        var hops: [ChainView.Hop] = [.init(label: "本机", kind: .origin)]

        guard let entry = M.groups.first(where: { $0.selectable }) ?? M.groups.first else {
            hops.append(.init(label: "目标", kind: .target))
            return hops
        }
        hops.append(.init(label: entry.name, kind: .group))

        // 逐层下钻：策略组的 now 可能仍是另一个策略组。
        var current = entry.now
        var seen: Set<String> = [entry.name]
        while let nested = M.groups.first(where: { $0.name == current }), !seen.contains(nested.name) {
            seen.insert(nested.name)
            hops.append(.init(label: nested.name, kind: .group))
            current = nested.now
        }

        if !current.isEmpty {
            let node = M.nodes[current]
            hops.append(.init(label: current, kind: .node,
                              region: DSRegionChip.region(from: current),
                              delay: node?.delay))
        }
        hops.append(.init(label: "目标", kind: .target))
        return hops
    }

    private var distribution: some View {
        let day = range == .today ? M.history.today : M.history.month
        // Data-viz colors only (info / download / error) — not brand accent.
        return TrafficDistributionView(
            direct: day.direct,
            proxy: day.proxy,
            reject: day.reject,
            proxyColor: DS.Palette.download
        ).equatable()
    }
}

// MARK: - 当前链路

/// 链路视图 — 原型 `ChainView`：本机 › 策略组 › 节点(地区+延迟) › 目标，chevron 连接。
struct ChainView: View {
    struct Hop: Identifiable {
        enum Kind { case origin, group, node, target }
        let label: String
        let kind: Kind
        var region: String? = nil
        var delay: Int? = nil
        var id: String { "\(label)-\(kind)" }
    }

    let hops: [Hop]

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            ForEach(Array(hops.enumerated()), id: \.element.id) { i, hop in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(DS.Icon.font(10, weight: .semibold))
                        .foregroundStyle(DS.Palette.textFaint)
                }
                hopView(hop)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func hopView(_ hop: Hop) -> some View {
        switch hop.kind {
        case .origin:
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(DS.Icon.font(13, weight: .medium))
                    .foregroundStyle(DS.Palette.accent)
                // fixedSize：「本机」这类两字端点被压缩时会竖排折行
                Text(hop.label).font(.dsBodySemibold).foregroundStyle(.primary).fixedSize()
            }
        case .group:
            Text(hop.label)
                .font(.dsBodySemibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
        case .node:
            HStack(spacing: 6) {
                if let region = hop.region { DSRegionChip(code: region) }
                Text(hop.label)
                    .font(.dsBodySemibold)
                    .foregroundStyle(DS.Palette.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let delay = hop.delay, delay > 0 { DSLatencyBadge(ms: delay) }
            }
        case .target:
            Text(hop.label).font(.dsBody).foregroundStyle(.secondary)
        }
    }
}

struct TrafficDistributionView: View, Equatable {
    let direct: Double
    let proxy: Double
    let reject: Double
    /// Proxy series color — data token, not brand accent.
    let proxyColor: Color

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.direct == rhs.direct && lhs.proxy == rhs.proxy && lhs.reject == rhs.reject && lhs.proxyColor == rhs.proxyColor
    }

    struct TrafficSlice: Identifiable {
        let name: String
        let value: Double
        let color: Color
        var id: String { name }
    }

    private var total: Double { direct + proxy + reject }

    var body: some View {
        let data: [TrafficSlice] = [
            TrafficSlice(name: "直连", value: Double(direct), color: DS.Palette.info),
            TrafficSlice(name: "代理", value: Double(proxy), color: proxyColor),
            TrafficSlice(name: "拦截", value: Double(reject), color: DS.Palette.error)
        ]

        // 卡片高度是跟"实时流量"图表卡对齐定死的（同一 GridRow），但这张卡自己
        // 的内容天生矮得多。旧版内容顶着卡头、下面空一大截；这版一是把内容整体
        // 撑到跟图表卡差不多重（圆环放大 + 每行图例配一条占比条，而不是单薄的
        // 一行文字），二是用上下 Spacer 把内容在剩余高度里居中，不管高度差多少
        // 都不会出现"顶着头、底下空半截"的样子。
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: DS.Spacing.xl) {
                ZStack {
                    Canvas { context, size in
                        guard total > 0 else {
                            var path = Path()
                            let center = CGPoint(x: size.width / 2, y: size.height / 2)
                            let radius = min(size.width, size.height) / 2
                            let lineWidth = radius * 0.24
                            let strokeRadius = radius - lineWidth / 2
                            path.addArc(center: center, radius: strokeRadius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                            context.stroke(path, with: .color(DS.Palette.hairline), style: StrokeStyle(lineWidth: lineWidth))
                            return
                        }
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let radius = min(size.width, size.height) / 2
                        let lineWidth = radius * 0.24
                        let strokeRadius = radius - lineWidth / 2

                        var startAngle = Angle.degrees(-90)
                        for slice in data {
                            guard slice.value > 0 else { continue }
                            let angle = Angle.degrees(360 * (slice.value / total))
                            let endAngle = startAngle + angle
                            var path = Path()
                            path.addArc(center: center, radius: strokeRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                            context.stroke(path, with: .color(slice.color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                            startAngle = endAngle
                        }
                    }
                    .frame(width: 124, height: 124)

                    VStack(spacing: 2) {
                        Text("总计").font(.dsCaption).foregroundColor(.secondary)
                        Text(fmtBytes(total))
                            .font(.dsStatValue)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .padding(.horizontal, DS.Spacing.m)
                }
                .frame(width: 136, height: 136)

                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    legendRow("直连", fmtBytes(direct), direct, DS.Palette.info)
                    legendRow("代理", fmtBytes(proxy), proxy, proxyColor)
                    legendRow("拦截", fmtBytes(reject), reject, DS.Palette.error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    /// 图例行——原来只有一行"点 + 标签 + 数值"，信息密度太低，配不上圆环放大后
    /// 的视觉重量。加一条占比条：既是装饰性的呼吸空间，也多传达了一个真实数据
    /// （占比），不是硬凑的空白。
    private func legendRow(_ l: String, _ v: String, _ raw: Double, _ c: Color) -> some View {
        let frac = total > 0 ? raw / total : 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: DS.Spacing.s) {
                DSDot(color: c)
                Text(l).font(.dsBody).foregroundColor(.secondary).fixedSize()
                Spacer(minLength: DS.Spacing.s)
                Text(v).font(.dsMonoSm).monospacedDigit().fixedSize()
                Text(String(format: "%.0f%%", frac * 100))
                    .font(.dsMonoTiny).monospacedDigit()
                    .foregroundColor(DS.Palette.textFaint)
                    .fixedSize()
            }
            DSBar(progress: frac, tint: c, height: 4)
        }
        // 撑满剩余宽度而不是写死宽度——卡片实际可用宽度取决于运行时的窗口/栅格
        // 尺寸，写死数字在我这没法截图核对的情况下是在瞎猜，容易在别的宽度下
        // 溢出或被裁切。
        .frame(maxWidth: .infinity, alignment: .leading)
    }


}

// MARK: - Components

struct Rank: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let value: Double

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.value == rhs.value
    }
}

struct DashStats: Equatable {
    var policyGroups: [Rank] = []
    var hosts: [Rank] = []
    var nodes: [Rank] = []
    var procs: [Rank] = []
    var rules: [Rank] = []
    var directBytes = 0.0, proxyBytes = 0.0, rejectBytes = 0.0
    var uniqueHosts = 0
}

struct RankList: View, Equatable {
    enum Mode { case bytes, count }
    let rows: [Rank]
    let accent: Color
    let mode: Mode

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows == rhs.rows && lhs.accent == rhs.accent && lhs.mode == rhs.mode
    }

    var body: some View {
        let mx = max(rows.first?.value ?? 1, 1)
        let total = max(rows.reduce(0) { $0 + $1.value }, 1)
        VStack(spacing: DS.Spacing.s + 2) {
            if rows.isEmpty {
                Text("暂无活跃数据").font(.dsBody).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                VStack(spacing: 3) {
                    HStack(spacing: DS.Spacing.s) {
                        Text("\(i+1)")
                            .font(.dsMonoTiny).foregroundColor(DS.Palette.textFaint)
                            .frame(width: 12, alignment: .leading)
                        Text(r.name).font(.dsBody).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: DS.Spacing.s)
                        Text(mode == .bytes ? fmtBytes(r.value) : "\(Int(r.value))")
                            .font(.dsMonoSm).monospacedDigit().foregroundColor(.secondary)
                        Text(String(format: "%.0f%%", r.value / total * 100))
                            .font(.dsMonoTiny).monospacedDigit()
                            .foregroundColor(DS.Palette.textFaint)
                            .frame(width: 30, alignment: .trailing)
                    }
                    // 用 overlay 替代 GeometryReader，避免每行嵌套布局对象
                    Capsule().fill(DS.Palette.track).frame(height: 2)
                        .overlay(alignment: .leading) {
                            GeometryReader { g in
                                Capsule().fill(accent.opacity(0.7))
                                    .frame(width: max(2, g.size.width * r.value / mx), height: 2)
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Traffic chart
// Lightweight SwiftUI line chart fed by AppModel's live downSeries/upSeries
// (from the /traffic WebSocket).
//
// 视觉基线：原型 `TrafficChart` — 双折线 + 线下渐变面积 + 末端圆点 +
// 左侧 4 条速率刻度网格线。

struct TrafficSparkline: View, Equatable {
    let down: [Double]
    let up: [Double]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.down == rhs.down && lhs.up == rhs.up
    }

    /// 刻度线条数（含顶格），与原型一致。
    private let gridLines = 4

    var body: some View {
        Canvas { context, size in
            guard down.count > 1, size.width > 0, size.height > 0 else { return }
            let maxV = max(down.max() ?? 1, up.max() ?? 1, 1)

            // 网格线 + 速率刻度
            for i in 0..<gridLines {
                let ratio = Double(i) / Double(gridLines)
                let y = size.height * CGFloat(ratio)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(DS.Palette.hairline), lineWidth: 0.5)

                let label = fmtRate(maxV * (1 - ratio))
                context.draw(
                    Text(label).font(.dsMonoTiny).foregroundStyle(DS.Palette.textFaint),
                    at: CGPoint(x: 3, y: y + 7), anchor: .topLeading
                )
            }

            series(up, in: size, maxV: maxV, color: DS.Palette.upload, context: context)
            series(down, in: size, maxV: maxV, color: DS.Palette.download, context: context)
        }
    }

    /// 单条序列：渐变面积 + 发光折线 + 末端圆点。
    private func series(_ values: [Double], in size: CGSize, maxV: Double,
                        color: Color, context: GraphicsContext) {
        let stepX = size.width / CGFloat(values.count - 1)
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(i) * stepX,
                    y: size.height * (1 - CGFloat(min(max(values[i] / maxV, 0), 1))))
        }

        var line = Path()
        for i in values.indices {
            let p = point(i)
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }

        var area = line
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(
            Gradient(colors: [color.opacity(0.28), color.opacity(0.0)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
        ))

        var glow = context
        glow.addFilter(.shadow(color: color.opacity(0.55), radius: 6))
        glow.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

        let last = point(values.count - 1)
        context.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)),
                     with: .color(color))
    }
}

#Preview("Dashboard") {
    DashboardPage().environmentObject(AppModel.shared)
        .frame(minWidth: 1000, idealWidth: 1100, maxWidth: 1400, minHeight: 760, idealHeight: 840, maxHeight: 1100)
}
