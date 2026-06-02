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
                PageHead(title: "仪表盘", desc: "流量趋势 · 实时统计 · 策略组排行 · 访问目标分析") {
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 8) {
                            HeadSwitch(title: "系统", icon: "globe", isOn: Binding(get: { M.systemProxyOn }, set: { _ in M.toggleSystemProxy() }), accentColor: .blue)
                            HeadSwitch(title: "TUN", icon: "shield.lefthalf.filled", isOn: Binding(get: { M.tunOn }, set: { _ in M.toggleTUN() }), accentColor: M.accent)
                            HeadSwitch(title: "核心", icon: "power", isOn: Binding(get: { M.reachable }, set: { _ in M.toggleEngine() }), accentColor: .green)
                        }
                        rangePicker
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text(greeting()).font(.system(size: 20, weight: .bold)).padding(.horizontal, 4)

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
                    Grid(horizontalSpacing: 16) {
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
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        Label(fmtRate(Double(M.curUp)), systemImage: "arrow.up")
                                            .foregroundColor(M.accent)
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        Spacer()
                                    }.padding(.bottom, 6)
                                    MetalTrafficView(accent: NSColor(M.accent)).frame(height: 144)
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

                        Card(title: "客户端源 IP", icon: "desktopcomputer") {
                            RankList(rows: topSources, accent: .green, mode: .bytes)
                        }
                        .frame(height: 208)
                        .frame(maxWidth: .infinity)
                    }

                    // Row 7: Rank lists (each spans 2, height 208)
                    HStack(spacing: 16) {
                        Card(title: "热门进程", icon: "app.badge") {
                            RankList(rows: topProcs, accent: .blue, mode: .bytes)
                        }
                        .frame(height: 208)
                        .frame(maxWidth: .infinity)

                        Card(title: "目标分类", icon: "globe.asia.australia.fill") {
                            RankList(rows: targetClass, accent: .pink, mode: .bytes)
                        }
                        .frame(height: 208)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
    }

    // MARK: aggregations (read precomputed snapshot — no per-render work)

    private var uniqueHosts: Int { M.dash.uniqueHosts }
    private var policyGroupRows: [Rank] { M.dash.policyGroups }
    private var topHosts: [Rank] { M.dash.hosts }
    private var topNodes: [Rank] { M.dash.nodes }
    private var topSources: [Rank] { M.dash.sources }
    private var topProcs: [Rank] { M.dash.procs }
    private var topRules: [Rank] { M.dash.rules }
    private var targetClass: [Rank] { M.dash.targets }

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
        let total = max(direct + proxy + reject, 1)

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
                    Text("总计").font(.system(size: 11)).foregroundColor(.secondary)
                    Text(fmtBytes(direct + proxy + reject))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
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
            Text(l).font(.system(size: 13, weight: .medium)).foregroundColor(.secondary).fixedSize()
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
    var sources: [Rank] = []
    var procs: [Rank] = []
    var rules: [Rank] = []
    var targets: [Rank] = []
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
                Text("暂无活跃数据").font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text("\(i+1)").font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary).frame(width: 14, alignment: .leading)
                        Text(r.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(mode == .bytes ? fmtBytes(r.value) : "\(Int(r.value))")
                            .font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
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
            Text(label).font(.system(size: 12)).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(accent ? M.accent : .primary)
                if let unit { Text(unit).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary) }
            }
            Text(sub).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0x2A/255.0, green: 0x2A/255.0, blue: 0x2A/255.0)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent ? M.accent.opacity(0.3) : Color(red: 0x2C/255.0, green: 0x2C/255.0, blue: 0x2C/255.0)))
    }
}

struct BarStat: View {
    let label, value, icon: String; let color: Color
    init(_ l: String, _ v: String, _ i: String, _ c: Color) { label = l; value = v; icon = i; color = c }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20)).foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12)).foregroundColor(.secondary)
                Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0x2A/255.0, green: 0x2A/255.0, blue: 0x2A/255.0)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0x2C/255.0, green: 0x2C/255.0, blue: 0x2C/255.0)))
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
                Image(systemName: icon).font(.system(size: 12)).foregroundColor(color)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
                if let sub {
                    Spacer()
                    Text(sub).font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0x2A/255.0, green: 0x2A/255.0, blue: 0x2A/255.0)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0x2C/255.0, green: 0x2C/255.0, blue: 0x2C/255.0)))
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

struct HeadSwitch: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool
    let accentColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(isOn ? accentColor : .secondary)
                .frame(width: 14)
            
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0x2A/255.0, green: 0x2A/255.0, blue: 0x2A/255.0)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1.0))
    }
}
