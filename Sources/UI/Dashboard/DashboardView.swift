// DashboardPage — rich overview (ref-style): greeting, totals, traffic chart,
// memory, distribution, policy-group ranking, hourly timeline, top rules/hosts/
// nodes, client source IPs, target classification. All from live mihomo data.
import SwiftUI

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

    private var zashboardButton: some View {
        Button {
            let host = M.api.host
            let port = String(M.api.port)
            let secret = M.api.secret
            let isDark = NSApp.effectiveAppearance.name == .darkAqua || NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var baseString = M.zashboardURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !baseString.hasSuffix("/") && !baseString.hasSuffix("index.html") { baseString += "/" }
            var urlString = baseString + "#/?"
            urlString += "hostname=\(host)&port=\(port)&secret=\(secret)&https=false&theme=\(isDark ? "dark" : "light")"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label("面板", systemImage: "safari")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHead(title: "仪表盘", desc: nil) {
                    HStack {
                        zashboardButton
                        rangePicker
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text(greeting()).font(.dsSection).padding(.horizontal, DS.Spacing.xs)

                    // Row 1: Top stats bar (4 columns, height 64)
                    HStack(spacing: 16) {
                        BarStat("总下载", fmtBytes(Double(M.downloadTotal)), "arrow.down.circle.fill", DS.Palette.accent)
                            .frame(height: DS.Layout.statHeight)
                            .frame(maxWidth: .infinity)
                        BarStat("总上传", fmtBytes(Double(M.uploadTotal)), "arrow.up.circle.fill", .red)
                            .frame(height: DS.Layout.statHeight)
                            .frame(maxWidth: .infinity)
                        BarStat("连接数", "\(M.activeConnectionsCount)", "link.circle.fill", .cyan)
                            .frame(height: DS.Layout.statHeight)
                            .frame(maxWidth: .infinity)
                        BarStat("访问目标", "\(uniqueHosts)", "scope", .orange)
                            .frame(height: DS.Layout.statHeight)
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
                            Card(title: "流量趋势", icon: "chart.xyaxis.line", actions: {
                                Picker("", selection: $M.trafficRefreshInterval) {
                                    Text("1s").tag(1.0)
                                    Text("3s").tag(3.0)
                                    Text("5s").tag(5.0)
                                    Text("10s").tag(10.0)
                                }.pickerStyle(.menu)
                                    .frame(width: 72, height: 28)
                                    .controlSize(.small)
                            }) {
                                VStack(spacing: 0) {
                                    HStack(spacing: 18) {
                                        Label(fmtRate(Double(M.curDown)), systemImage: "arrow.down")
                                            .foregroundColor(.red)
                                            .font(.dsMonoBold)
                                        Label(fmtRate(Double(M.curUp)), systemImage: "arrow.up")
                                            .foregroundColor(DS.Palette.accent)
                                            .font(.dsMonoBold)
                                        Spacer()
                                    }.padding(.bottom, 6)
                                    TrafficSparkline(down: M.downSeries, up: M.upSeries, accent: DS.Palette.accent)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .drawingGroup()
                                }
                            }
                            .frame(height: DS.Layout.cardRow)
                            .gridCellColumns(3)

                            VStack(spacing: 16) {
                                MiniStat("核心内存", fmtBytes(Double(M.memory)), sub: nil, icon: "memorychip", color: .purple)
                                    .frame(maxHeight: .infinity)
                                MiniStat("应用内存", String(format: "%.0f MB", M.appMemoryMB), sub: nil, icon: "app.dashed", color: .orange)
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(height: DS.Layout.cardRow)
                            .gridCellColumns(1)
                        }
                    }

                    // Row 3: Distribution + policy groups (height 208)
                    HStack(spacing: 16) {
                        Card(title: "流量分布", icon: "chart.pie.fill") {
                            distribution
                        }
                        .frame(height: DS.Layout.cardRow)
                        .frame(maxWidth: .infinity)

                        Card(title: "策略组排名", icon: "rectangle.3.group.fill") {
                            RankList(rows: policyGroupRows, accent: DS.Palette.accent, mode: .bytes).equatable()
                        }
                        .frame(height: DS.Layout.cardRow)
                        .frame(maxWidth: .infinity)
                    }


                    // Row 5: Rank lists (3 columns, height 208)
                    HStack(spacing: 16) {
                        Card(title: "高频规则", icon: "list.number") {
                            RankList(rows: topRules, accent: .red, mode: .count).equatable()
                        }
                        .frame(height: DS.Layout.cardRow)
                        .frame(maxWidth: .infinity)

                        Card(title: "热门域名", icon: "globe") {
                            RankList(rows: topHosts, accent: .cyan, mode: .bytes).equatable()
                        }
                        .frame(height: DS.Layout.cardRow)
                        .frame(maxWidth: .infinity)
                        
                        Card(title: "热门节点", icon: "server.rack") {
                            RankList(rows: topNodes, accent: .orange, mode: .bytes).equatable()
                        }
                        .frame(height: DS.Layout.cardRow)
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
    private var topRules: [Rank] { M.dash.rules }

    private var distribution: some View {
        let day = range == .today ? M.history.today : M.history.month
        return TrafficDistributionView(
            direct: day.direct,
            proxy: day.proxy,
            reject: day.reject,
            accent: DS.Palette.accent
        ).equatable()
    }

    private func greeting() -> String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11: return "早上好，开启美好的一天 ☀️"
        case 11..<14: return "中午好，记得休息一下 🍱"
        case 14..<18: return "下午好，保持专注 ☕"
        case 18..<22: return "晚上好，放松心情 🌙"
        default: return "夜深了，注意身体 🦉"
        }
    }
}

struct TrafficDistributionView: View, Equatable {
    let direct: Double
    let proxy: Double
    let reject: Double
    let accent: Color
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.direct == rhs.direct && lhs.proxy == rhs.proxy && lhs.reject == rhs.reject && lhs.accent == rhs.accent
    }
    
    struct TrafficSlice: Identifiable {
        let name: String
        let value: Double
        let color: Color
        var id: String { name }
    }
    
    var body: some View {
        let data: [TrafficSlice] = [
            TrafficSlice(name: "直连", value: Double(direct), color: DS.Palette.info),
            TrafficSlice(name: "代理", value: Double(proxy), color: accent),
            TrafficSlice(name: "拦截", value: Double(reject), color: DS.Palette.error)
        ]
        
        return HStack(spacing: 32) {
            ZStack {
                Canvas { context, size in
                    let total = direct + proxy + reject
                    guard total > 0 else {
                        // Draw empty placeholder ring
                        var path = Path()
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let radius = min(size.width, size.height) / 2
                        let lineWidth = radius * 0.28
                        let strokeRadius = radius - lineWidth / 2
                        path.addArc(center: center, radius: strokeRadius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                        context.stroke(path, with: .color(Color.secondary.opacity(0.2)), style: StrokeStyle(lineWidth: lineWidth))
                        return
                    }
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let radius = min(size.width, size.height) / 2
                    let lineWidth = radius * 0.28
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
                .frame(width: 110, height: 110)

                VStack(spacing: 2) {
                    Text("总计").font(.dsBody).foregroundColor(.secondary)
                    Text(fmtBytes(direct + proxy + reject))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .padding(.horizontal, 24)
            }
            .frame(width: 120, height: 120)

            VStack(spacing: DS.Spacing.l) {
                legendRow("直连", fmtBytes(direct), DS.Palette.info)
                legendRow("代理", fmtBytes(proxy), accent)
                legendRow("拦截", fmtBytes(reject), DS.Palette.error)
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

struct DashStats {
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
        VStack(spacing: 10) {
            if rows.isEmpty {
                Text("暂无活跃数据").font(.dsBody).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text("\(i+1)").font(.dsMono).foregroundColor(.secondary).frame(width: 14, alignment: .leading)
                        Text(r.name).font(.dsBody).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(mode == .bytes ? fmtBytes(r.value) : "\(Int(r.value))")
                            .font(.dsMono).foregroundColor(.secondary)
                    }
                    // 用 overlay 替代 GeometryReader，避免每行嵌套布局对象
                    Capsule().fill(DS.Palette.track).frame(height: 2)
                        .overlay(alignment: .leading) {
                            GeometryReader { g in
                                Capsule().fill(accent.opacity(0.6))
                                    .frame(width: max(2, g.size.width * r.value / mx), height: 2)
                            }
                        }
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
                    .foregroundColor(accent ? DS.Palette.accent : .primary)
                if let unit { Text(unit).font(.dsBodySemibold).foregroundColor(.secondary) }
            }
            Text(sub).font(.dsBody).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(accent ? DS.Palette.accent.opacity(0.3) : DS.Palette.cardBgAlt))
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
        .frame(height: DS.Layout.statHeight)
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
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Palette.cardBgAlt))
    }
}

struct HourlyBars: View, Equatable {
    let values: [Double]
    let accent: Color
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.values == rhs.values && lhs.accent == rhs.accent
    }
    
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

struct TrafficSparkline: View, Equatable {
    let down: [Double]
    let up: [Double]
    let accent: Color
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.down == rhs.down && lhs.up == rhs.up && lhs.accent == rhs.accent
    }

    var body: some View {
        Canvas { context, size in
            guard down.count > 1, size.width > 0 else { return }
            let maxV = max(down.max() ?? 1, up.max() ?? 1, 1)
            let stepX = size.width / CGFloat(down.count - 1)
            
            // Draw download line (red)
            var downPath = Path()
            for (i, v) in down.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height * (1 - CGFloat(min(max(v / maxV, 0), 1)))
                if i == 0 { downPath.move(to: CGPoint(x: x, y: y)) } else { downPath.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(downPath, with: .color(Color.red.opacity(0.9)), lineWidth: 1.5)
            
            // Draw upload line (accent)
            var upPath = Path()
            for (i, v) in up.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height * (1 - CGFloat(min(max(v / maxV, 0), 1)))
                if i == 0 { upPath.move(to: CGPoint(x: x, y: y)) } else { upPath.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(upPath, with: .color(accent), lineWidth: 1.5)
        }
    }
}

#Preview("Dashboard") {
    DashboardPage().environmentObject(AppModel.shared)
        .frame(minWidth: 1000, idealWidth: 1100, maxWidth: 1400, minHeight: 760, idealHeight: 840, maxHeight: 1100).preferredColorScheme(.dark)
}
