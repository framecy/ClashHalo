// DashboardPage — rich overview (ref-style): greeting, totals, traffic chart,
// memory, distribution, policy-group ranking, hourly timeline, top rules/hosts/
// nodes, client source IPs, target classification. All from live mihomo data.
import SwiftUI
import Charts

struct DashboardPage: View {
    @EnvironmentObject var M: AppModel
    enum Range { case today, month }
    @State private var range: Range = .today

    private var rangePicker: some View {
        HStack {
            Picker("", selection: $range) {
                Text("今日").tag(Range.today); Text("本月").tag(Range.month)
            }.pickerStyle(.segmented).labelsHidden()
        }
        .frame(height: 32)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHead(title: "仪表盘", desc: nil) {
                    rangePicker
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text(greeting()).font(.dsSection).padding(.horizontal, DS.Spacing.xs)

                    // Row 1: Top stats bar (4 columns, height 64)
                    HStack(spacing: 16) {
                        BarStat("总下载", fmtBytes(Double(M.downloadTotal)), "arrow.down.circle.fill", M.accent)
                            .frame(height: 64)
                            .frame(maxWidth: .infinity)
                        BarStat("总上传", fmtBytes(Double(M.uploadTotal)), "arrow.up.circle.fill", .red)
                            .frame(height: 64)
                            .frame(maxWidth: .infinity)
                        BarStat("连接数", "\(M.conns.count)", "link.circle.fill", .cyan)
                            .frame(height: 64)
                            .frame(maxWidth: .infinity)
                        BarStat("访问目标", "\(uniqueHosts)", "scope", .orange)
                            .frame(height: 64)
                            .frame(maxWidth: .infinity)
                    }

                    // Row 2: Chart + memory column (height 224 = 64*3+16*2, 3:1 width ratio)
                    // verticalSpacing 0: the empty sizing row below only defines 4 equal
                    // columns; without this, Grid's default row spacing adds a stray gap
                    // between Row 1 and the chart (breaking the 16px rhythm).
                    Grid(horizontalSpacing: 16, verticalSpacing: 0) {
                        GridRow {
                            Color.clear.frame(height: 0).frame(maxWidth: .infinity)
                            Color.clear.frame(height: 0).frame(maxWidth: .infinity)
                            Color.clear.frame(height: 0).frame(maxWidth: .infinity)
                            Color.clear.frame(height: 0).frame(maxWidth: .infinity)
                        }
                        GridRow {
                            Card(title: "流量趋势", icon: "chart.xyaxis.line") {
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 18) {
                                        Label(fmtRate(Double(M.curDown)), systemImage: "arrow.down")
                                            .foregroundColor(.red)
                                            .font(.dsMonoBold)
                                        Label(fmtRate(Double(M.curUp)), systemImage: "arrow.up")
                                            .foregroundColor(M.accent)
                                            .font(.dsMonoBold)
                                        Spacer()
                                    }.padding(.bottom, 6)
                                    TrafficSparkline(down: M.downSeries, up: M.upSeries, accent: M.accent).frame(height: 144)
                                }
                            }
                            .frame(height: 224)
                            .gridCellColumns(3)

                            VStack(spacing: 16) {
                                MiniStat("活跃连接", "\(M.conns.count)", sub: "已关闭 \(M.closedConns)", icon: "link", color: .cyan)
                                    .frame(height: 64)
                                MiniStat("核心内存", fmtBytes(Double(M.memory)), sub: nil, icon: "memorychip", color: .purple)
                                    .frame(height: 64)
                                MiniStat("应用内存", String(format: "%.0f MB", M.appMemoryMB), sub: nil, icon: "app.dashed", color: .orange)
                                    .frame(height: 64)
                            }
                            .frame(height: 224)
                            .gridCellColumns(1)
                        }
                    }

                    // Row 3: Distribution + policy groups (height 208)
                    HStack(spacing: 16) {
                        Card(title: "流量分布", icon: "chart.pie.fill") {
                            distribution
                        }
                        .frame(height: 208)
                        .frame(maxWidth: .infinity)

                        Card(title: "策略组排名", icon: "rectangle.3.group.fill") {
                            RankList(rows: policyGroupRows, accent: M.accent, mode: .bytes)
                        }
                        .frame(height: 208)
                        .frame(maxWidth: .infinity)
                    }

                    // Row 4: Timeline (height 160)
                    Card(title: range == .today ? "流量时间轴 · 今日(每小时)" : "流量时间轴 · 本月(每日)", icon: "chart.bar.fill") {
                        HourlyBars(values: range == .today ? M.history.today.hourlyDown : M.history.monthDailyTotals,
                                   accent: M.accent).frame(height: 110)
                    }
                    .frame(height: 160)

                    // Row 5: Rank lists (each spans 2, height 208)
                    HStack(spacing: 16) {
                        Card(title: "高频规则", icon: "list.number") {
                            RankList(rows: topRules, accent: .red, mode: .count)
                        }
                        .frame(height: 208)
                        .frame(maxWidth: .infinity)

                        Card(title: "热门域名", icon: "globe") {
                            RankList(rows: topHosts, accent: .cyan, mode: .bytes)
                        }
                        .frame(height: 208)
                        .frame(maxWidth: .infinity)
                    }

                    // Row 6: Rank lists (each spans 2, height 208)
                    HStack(spacing: 16) {
                        Card(title: "热门节点", icon: "bolt.horizontal.fill") {
                            RankList(rows: topNodes, accent: .orange, mode: .bytes)
                        }
                        .frame(height: 208)
                        .frame(maxWidth: .infinity)

                        Card(title: "热门进程", icon: "app.badge") {
                            RankList(rows: topProcs, accent: .blue, mode: .bytes)
                        }
                        .frame(height: 208)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, DS.Spacing.l).padding(.bottom, DS.Spacing.l)
            }
        }
    }

    // MARK: aggregations (read precomputed snapshot — no per-render work)

    private var uniqueHosts: Int { M.dash.uniqueHosts }
    private var policyGroupRows: [Rank] { M.dash.policyGroups }
    private var topHosts: [Rank] { M.dash.hosts }
    private var topNodes: [Rank] { M.dash.nodes }
    private var topProcs: [Rank] { M.dash.procs }
    private var topRules: [Rank] { M.dash.rules }

    struct TrafficSlice: Identifiable {
        let name: String
        let value: Double
        let color: Color
        var id: String { name }
    }

    private var distribution: some View {
        let day = range == .today ? M.history.today : M.history.month
        let direct = day.direct
        let proxy  = day.proxy
        let reject = day.reject

        let data: [TrafficSlice] = [
            TrafficSlice(name: "直连", value: Double(direct), color: .cyan),
            TrafficSlice(name: "代理", value: Double(proxy), color: M.accent),
            TrafficSlice(name: "拦截", value: Double(reject), color: .red)
        ]

        return HStack(spacing: 32) {
            // Left side: Donut Chart
            ZStack {
                Chart(data) { slice in
                    SectorMark(
                        angle: .value("Traffic", slice.value),
                        innerRadius: .ratio(0.72),
                        angularInset: 1.5
                    )
                    .foregroundStyle(slice.color)
                    .cornerRadius(4)
                }
                .frame(width: 110, height: 110)

                // Center Text
                VStack(spacing: 2) {
                    Text("总计").font(.dsBody).foregroundColor(.secondary)
                    Text(fmtBytes(direct + proxy + reject))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .padding(.horizontal, 24)
            }
            .frame(width: 120, height: 120) // slight buffer

            // Right side: Legends
            VStack(spacing: 14) {
                legendRow("直连", fmtBytes(direct), .cyan)
                legendRow("代理", fmtBytes(proxy), M.accent)
                legendRow("拦截", fmtBytes(reject), .red)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }

    private func legendRow(_ l: String, _ v: String, _ c: Color) -> some View {
        HStack(spacing: 12) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(l).font(.dsBodyMedium).foregroundColor(.secondary).fixedSize()
            Spacer()
            Text(v).font(.system(size: 14, weight: .bold, design: .monospaced)).fixedSize()
        }
        .frame(maxWidth: .infinity)
    }

    private func greeting() -> String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11: return "早上好，开启美好的一天 ☀️"
        case 11..<14: return "中午好，记得休息一下 🍱"
        case 14..<18: return "下午好，保持专注 ☕️"
        case 18..<23: return "忙碌了一天，好好休息！🌙"
        default: return "夜深了，注意身体 🌌"
        }
    }
}

// MARK: - Components

struct Rank: Identifiable { let id = UUID(); let name: String; let value: Double }

struct DashStats {
    var policyGroups: [Rank] = []
    var hosts: [Rank] = []
    var nodes: [Rank] = []
    var procs: [Rank] = []
    var rules: [Rank] = []
    var directBytes = 0.0, proxyBytes = 0.0, rejectBytes = 0.0
    var uniqueHosts = 0
}

struct RankList: View {
    enum Mode { case bytes, count }
    let rows: [Rank]; let accent: Color; let mode: Mode
    var body: some View {
        let mx = max(rows.first?.value ?? 1, 1)
        VStack(spacing: 10) {
            if rows.isEmpty {
                Text("暂无活跃数据").font(.dsBody).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text("\(i+1)").font(.dsMono).foregroundColor(.secondary).frame(width: 14, alignment: .leading)
                        Text(r.name).font(.dsBody).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(mode == .bytes ? fmtBytes(r.value) : "\(Int(r.value))")
                            .font(.dsMono).foregroundColor(.secondary)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.03)).frame(height: 2)
                            Capsule().fill(accent.opacity(0.6)).frame(width: max(2, g.size.width * r.value/mx), height: 2)
                        }
                    }.frame(height: 2)
                }
            }
        }
    }
}

struct StatBox: View {
    let label, value: String; var unit: String? = nil; let sub: String; var accent = false
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.dsBody).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.dsStatValue)
                    .foregroundColor(accent ? M.accent : .primary)
                if let unit { Text(unit).font(.dsBodySemibold).foregroundColor(.secondary) }
            }
            Text(sub).font(.dsBody).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(accent ? M.accent.opacity(0.3) : DS.Palette.cardBgAlt))
    }
}

struct BarStat: View {
    let label, value, icon: String; let color: Color
    init(_ l: String, _ v: String, _ i: String, _ c: Color) { label = l; value = v; icon = i; color = c }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: DS.Icon.md)).foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.dsBody).foregroundColor(.secondary)
                Text(value).font(.dsStatValue)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Spacing.l)
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Palette.cardBgAlt))
    }
}

struct MiniStat: View {
    let title, value: String; let sub: String?; let icon: String; let color: Color
    init(_ title: String, _ value: String, sub: String?, icon: String, color: Color) {
        self.title = title; self.value = value; self.sub = sub; self.icon = icon; self.color = color
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.dsBody).foregroundColor(color)
                Text(title).font(.dsBodyMedium).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                Text(value).font(.dsStatValue)
                if let sub {
                    Spacer()
                    Text(sub).font(.dsBody).foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.l).padding(.vertical, DS.Spacing.m)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Palette.cardBgAlt))
    }
}

struct HourlyBars: View {
    let values: [Double]; let accent: Color
    var body: some View {
        let mx = max(values.max() ?? 1, 1)
        GeometryReader { g in
            let bw = (g.size.width - CGFloat(values.count - 1) * 4) / CGFloat(values.count)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(values.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [accent, accent.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                        .frame(width: max(2, bw), height: max(2, g.size.height * CGFloat(values[i]/mx)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Traffic sparkline
// Lightweight SwiftUI line chart fed by AppModel's live downSeries/upSeries
// (from the /traffic WebSocket). Replaces the removed mmap-backed Metal chart
// that depended on the old self-built engine's stats producer.

struct TrafficSparkline: View {
    let down: [Double]
    let up: [Double]
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let maxV = max(down.max() ?? 1, up.max() ?? 1, 1)
            ZStack {
                spark(down, size: geo.size, maxV: maxV)
                    .stroke(Color.red.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                spark(up, size: geo.size, maxV: maxV)
                    .stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }

    private func spark(_ data: [Double], size: CGSize, maxV: Double) -> Path {
        Path { p in
            guard data.count > 1, size.width > 0 else { return }
            let stepX = size.width / CGFloat(data.count - 1)
            for (i, v) in data.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height * (1 - CGFloat(min(max(v / maxV, 0), 1)))
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }
}
