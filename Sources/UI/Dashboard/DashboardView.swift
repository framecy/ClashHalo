// DashboardPage — rich overview (ref-style): greeting, totals, traffic chart,
// memory, distribution, policy-group ranking, hourly timeline, top rules/hosts/
// nodes, client source IPs, target classification. All from live mihomo data.
import SwiftUI
import Charts

struct DashboardPage: View {
    @EnvironmentObject var M: AppModel
    @StateObject private var VM = DashboardViewModel()
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
                        BarStat("总下载", fmtBytes(Double(VM.downloadTotal)), "arrow.down.circle.fill", M.accent)
                            .frame(height: DS.Layout.statHeight)
                            .frame(maxWidth: .infinity)
                        BarStat("总上传", fmtBytes(Double(VM.uploadTotal)), "arrow.up.circle.fill", .red)
                            .frame(height: DS.Layout.statHeight)
                            .frame(maxWidth: .infinity)
                        BarStat("连接数", "\(VM.activeConnectionsCount)", "link.circle.fill", .cyan)
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
                            Card(title: "流量趋势", icon: "chart.xyaxis.line") {
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 18) {
                                        Label(fmtRate(Double(VM.curDown)), systemImage: "arrow.down")
                                            .foregroundColor(.red)
                                            .font(.dsMonoBold)
                                        Label(fmtRate(Double(VM.curUp)), systemImage: "arrow.up")
                                            .foregroundColor(M.accent)
                                            .font(.dsMonoBold)
                                        Spacer()
                                    }.padding(.bottom, 6)
                                    TrafficSparkline(down: VM.downSeries, up: VM.upSeries, accent: M.accent).frame(height: 144)
                                }
                            }
                            .frame(height: 224)
                            .gridCellColumns(3)

                            VStack(spacing: 16) {
                                MiniStat("活跃连接", "\(VM.activeConnectionsCount)", sub: "已关闭 \(VM.closedConns)", icon: "link", color: .cyan)
                                    .frame(height: DS.Layout.statHeight)
                                MiniStat("核心内存", fmtBytes(Double(VM.memory)), sub: nil, icon: "memorychip", color: .purple)
                                    .frame(height: DS.Layout.statHeight)
                                MiniStat("应用内存", String(format: "%.0f MB", VM.appMemoryMB), sub: nil, icon: "app.dashed", color: .orange)
                                    .frame(height: DS.Layout.statHeight)
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
                        .frame(height: DS.Layout.cardRow)
                        .frame(maxWidth: .infinity)

                        Card(title: "策略组排名", icon: "rectangle.3.group.fill") {
                            RankList(rows: policyGroupRows, accent: M.accent, mode: .bytes)
                        }
                        .frame(height: DS.Layout.cardRow)
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
                        .frame(height: DS.Layout.cardRow)
                        .frame(maxWidth: .infinity)

                        Card(title: "热门域名", icon: "globe") {
                            RankList(rows: topHosts, accent: .cyan, mode: .bytes)
                        }
                        .frame(height: DS.Layout.cardRow)
                        .frame(maxWidth: .infinity)
                    }

                    // Row 6: Rank lists (each spans 2, height 208)
                    HStack(spacing: 16) {
                        Card(title: "热门节点", icon: "bolt.horizontal.fill") {
                            RankList(rows: topNodes, accent: .orange, mode: .bytes)
                        }
                        .frame(height: DS.Layout.cardRow)
                        .frame(maxWidth: .infinity)

                        Card(title: "热门进程", icon: "app.badge") {
                            RankList(rows: topProcs, accent: .blue, mode: .bytes)
                        }
                        .frame(height: DS.Layout.cardRow)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, DS.Spacing.l).padding(.bottom, DS.Spacing.l)
            }
        }
        .onAppear { VM.start() }
        .onDisappear { VM.stop() }
    }

    // MARK: aggregations (read precomputed snapshot — no per-render work)

    private var uniqueHosts: Int { VM.dash.uniqueHosts }
    private var policyGroupRows: [Rank] { VM.dash.policyGroups }
    private var topHosts: [Rank] { VM.dash.hosts }
    private var topNodes: [Rank] { VM.dash.nodes }
    private var topProcs: [Rank] { VM.dash.procs }
    private var topRules: [Rank] { VM.dash.rules }

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

        // Traffic categories use the shared semantic palette: direct = info,
        // reject = error; proxy = the dynamic user accent.
        let data: [TrafficSlice] = [
            TrafficSlice(name: "直连", value: Double(direct), color: DS.Palette.info),
            TrafficSlice(name: "代理", value: Double(proxy), color: M.accent),
            TrafficSlice(name: "拦截", value: Double(reject), color: DS.Palette.error)
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
            VStack(spacing: DS.Spacing.l) {
                legendRow("直连", fmtBytes(direct), DS.Palette.info)
                legendRow("代理", fmtBytes(proxy), M.accent)
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
                            Capsule().fill(DS.Palette.track).frame(height: 2)
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
        .frame(height: DS.Layout.statHeight)
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
        .frame(width: 1000, height: 760).preferredColorScheme(.dark)
}

@MainActor final class DashboardViewModel: ObservableObject {
    @Published var downloadTotal: Int64 = 0
    @Published var uploadTotal: Int64 = 0
    @Published var activeConnectionsCount: Int = 0
    @Published var uniqueHosts: Int = 0
    @Published var curDown: Int64 = 0
    @Published var curUp: Int64 = 0
    @Published var memory: Int64 = 0
    @Published var appMemoryMB: Double = 0.0
    @Published var closedConns: Int = 0

    @Published var downSeries: [Double] = Array(repeating: 0, count: 120)
    @Published var upSeries: [Double] = Array(repeating: 0, count: 120)

    @Published var dash = DashStats()

    private var trafficWS: WSHandle?
    private var memWS: WSHandle?
    private var pollTimer: Timer?
    
    private let api = MihomoClient.shared
    
    func start() {
        guard api.reachable else { return }
        
        // 1. WebSocket stream for traffic
        trafficWS = api.stream("/traffic", type: TrafficTick.self) { [weak self] t in
            Task { @MainActor in self?.onTraffic(t) }
        }
        
        // 2. WebSocket stream for memory
        memWS = api.stream("/memory", type: MemoryTick.self) { [weak self] m in
            Task { @MainActor in
                if m.inuse > 0 { self?.memory = m.inuse }
            }
        }
        
        // 3. Regular poll (every 3s) for connections data to compute rankings
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.pollConnections()
            }
        }
        
        // Trigger initial poll immediately
        Task {
            await pollConnections()
        }
    }
    
    func stop() {
        trafficWS?.cancel()
        memWS?.cancel()
        pollTimer?.invalidate()
        
        trafficWS = nil
        memWS = nil
        pollTimer = nil
        
        // Clear memory arrays on exit to ensure physical memory can be reclaimed
        // keepingCapacity: false is crucial here to drop the backing buffer
        downSeries.removeAll(keepingCapacity: false)
        upSeries.removeAll(keepingCapacity: false)
        dash = DashStats()
        
        // Ensure standard initialization values for UI consistency
        downSeries = Array(repeating: 0, count: 120)
        upSeries = Array(repeating: 0, count: 120)
    }
    
    private var lastUIUpdate = Date.distantPast
    
    private func onTraffic(_ t: TrafficTick) {
        // Always update the raw values for labels (minimal impact)
        if t.up != curUp { curUp = t.up }
        if t.down != curDown { curDown = t.down }
        
        // Throttled UI update for the sparkline to reduce Graphics memory churn (RSS optimization)
        // Redrawing a Canvas every 1s is expensive in terms of graphics buffers.
        let now = Date()
        if now.timeIntervalSince(lastUIUpdate) >= 2.0 {
            lastUIUpdate = now
            
            // Aggressively manage the series arrays
            downSeries.append(Double(t.down))
            if downSeries.count > 120 { downSeries.removeFirst() }
            upSeries.append(Double(t.up))
            if upSeries.count > 120 { upSeries.removeFirst() }
        }
    }
    
    private func pollConnections() async {
        guard api.reachable else { return }
        do {
            let s = try await api.fetchConnectionsSnapshot()
            downloadTotal = s.downloadTotal
            uploadTotal = s.uploadTotal
            
            let items = s.connections ?? []
            var next: [Conn] = []
            var activeIDs = Set<String>()
            
            for c in items {
                activeIDs.insert(c.id)
                let conn = Conn(
                    id: c.id,
                    host: c.metadata.host?.isEmpty == false ? c.metadata.host! : (c.metadata.destinationIP ?? "?"),
                    dstIP: c.metadata.destinationIP ?? "?",
                    srcIP: c.metadata.sourceIP ?? "?",
                    port: c.metadata.destinationPort ?? "",
                    network: c.metadata.network.uppercased(),
                    process: c.metadata.process ?? "—",
                    processPath: c.metadata.processPath ?? "—",
                    chain: c.chains.reversed().joined(separator: " → "),
                    group: c.chains.last ?? "?",
                    node: c.chains.first ?? "?",
                    rule: c.rulePayload.isEmpty ? c.rule : "\(c.rule),\(c.rulePayload)",
                    ruleType: c.rule,
                    up: c.upload, down: c.download,
                    upRate: 0, downRate: 0,
                    start: c.start
                )
                next.append(conn)
            }
            
            activeConnectionsCount = activeIDs.count
            dash = AppModel.computeDash(next)
            
            // RSS memory of current app
            appMemoryMB = Double(AppModel.residentMemoryBytes()) / 1_000_000
            
            // closed connections count
            closedConns = max(0, AppModel.shared.totalConnsCount - activeIDs.count)
        } catch {
            // Ignore
        }
    }
}
