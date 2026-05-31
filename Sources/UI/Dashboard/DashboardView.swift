// DashboardPage — rich overview (ref-style): greeting, totals, traffic chart,
// memory, distribution, policy-group ranking, hourly timeline, top rules/hosts/
// nodes, client source IPs, target classification. All from live mihomo data.
import SwiftUI

struct DashboardPage: View {
    @EnvironmentObject var M: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(greeting()).font(.system(size: 22, weight: .bold)).padding(.top, 2)

                // top stat bar
                HStack(spacing: 12) {
                    BarStat("总下载", fmtBytes(Double(M.downloadTotal)), "arrow.down.circle.fill", M.accent)
                    BarStat("总上传", fmtBytes(Double(M.uploadTotal)), "arrow.up.circle.fill", .red)
                    BarStat("连接数", "\(M.conns.count)", "link.circle.fill", .cyan)
                    BarStat("访问目标", "\(uniqueHosts)", "scope", .orange)
                }

                // chart + memory column
                HStack(alignment: .top, spacing: 14) {
                    Card(title: "流量趋势", icon: "chart.xyaxis.line") {
                        HStack(spacing: 18) {
                            Label(fmtRate(Double(M.curDown)), systemImage: "arrow.down").foregroundColor(.red).font(.headline.monospaced())
                            Label(fmtRate(Double(M.curUp)), systemImage: "arrow.up").foregroundColor(M.accent).font(.headline.monospaced())
                            Spacer()
                        }.padding(.bottom, 4)
                        MetalTrafficView(accent: NSColor(M.accent)).frame(height: 200)
                    }
                    VStack(spacing: 14) {
                        MiniStat("活跃连接", "\(M.conns.count)", sub: "已关闭 \(M.closedConns)", icon: "link", color: .cyan)
                        MiniStat("核心内存", fmtBytes(Double(M.memory)), sub: nil, icon: "memorychip", color: .purple)
                        MiniStat("应用内存", String(format: "%.0f MB", M.appMemoryMB), sub: nil, icon: "app.dashed", color: .orange)
                    }.frame(width: 240)
                }

                // distribution + policy groups
                HStack(alignment: .top, spacing: 14) {
                    Card(title: "流量分布", icon: "chart.pie.fill") { distribution }
                    Card(title: "策略组", icon: "rectangle.3.group.fill") { RankList(rows: policyGroupRows, accent: M.accent, mode: .bytes) }
                }

                // hourly timeline
                Card(title: "流量时间轴", icon: "chart.bar.fill") {
                    HourlyBars(values: M.hourly, accent: M.accent).frame(height: 130)
                }

                // top rules / hosts / nodes
                HStack(alignment: .top, spacing: 14) {
                    Card(title: "高频规则", icon: "list.number") { RankList(rows: topRules, accent: .red, mode: .count) }
                    Card(title: "热门域名", icon: "globe") { RankList(rows: topHosts, accent: .cyan, mode: .bytes) }
                    Card(title: "热门节点", icon: "bolt.horizontal.fill") { RankList(rows: topNodes, accent: .orange, mode: .bytes) }
                }

                // source IPs / processes / target class
                HStack(alignment: .top, spacing: 14) {
                    Card(title: "客户端源 IP", icon: "desktopcomputer") { RankList(rows: topSources, accent: .green, mode: .bytes) }
                    Card(title: "热门进程", icon: "app.badge") { RankList(rows: topProcs, accent: .blue, mode: .bytes) }
                    Card(title: "目标分类", icon: "globe.asia.australia.fill") { RankList(rows: targetClass, accent: .pink, mode: .bytes) }
                }
            }
            .padding(18)
        }
    }

    // MARK: aggregations

    private var uniqueHosts: Int { Set(M.conns.map { $0.host }).count }

    private func agg(_ key: (Conn) -> String, weight: (Conn) -> Double) -> [Rank] {
        var m: [String: Double] = [:]
        for c in M.conns { let k = key(c); if k.isEmpty || k == "?" { continue }; m[k, default: 0] += weight(c) }
        return m.sorted { $0.value > $1.value }.prefix(5).map { Rank(name: $0.key, value: $0.value) }
    }
    private var bytesW: (Conn) -> Double { { Double($0.up + $0.down) } }

    private var policyGroupRows: [Rank] { agg({ $0.group }, weight: bytesW) }
    private var topHosts: [Rank] { agg({ $0.host }, weight: bytesW) }
    private var topNodes: [Rank] { agg({ $0.node }, weight: bytesW) }
    private var topSources: [Rank] { agg({ $0.srcIP }, weight: bytesW) }
    private var topProcs: [Rank] { agg({ $0.process }, weight: bytesW) }
    private var topRules: [Rank] { agg({ $0.ruleType }, weight: { _ in 1 }) }
    private var targetClass: [Rank] {
        agg({ c in
            if c.category == "reject" { return "拦截" }
            if isPrivate(c.dstIP) { return "内网" }
            return "公网"
        }, weight: bytesW)
    }
    private func isPrivate(_ ip: String) -> Bool {
        ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("172.16.") ||
        ip.hasPrefix("198.18.") || ip.hasPrefix("127.") || ip.hasPrefix("fd") || ip == "?"
    }

    private var distribution: some View {
        let direct = M.conns.filter { $0.category == "direct" }.reduce(0.0) { $0 + Double($1.up + $1.down) }
        let proxy  = M.conns.filter { $0.category == "proxy" }.reduce(0.0) { $0 + Double($1.up + $1.down) }
        let reject = M.conns.filter { $0.category == "reject" }.reduce(0.0) { $0 + Double($1.up + $1.down) }
        let total = max(direct + proxy + reject, 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text(fmtBytes(direct + proxy + reject)).font(.system(size: 26, weight: .bold))
            GeometryReader { g in
                HStack(spacing: 2) {
                    Rectangle().fill(Color.cyan).frame(width: g.size.width * direct/total)
                    Rectangle().fill(M.accent).frame(width: g.size.width * proxy/total)
                    Rectangle().fill(Color.red).frame(width: max(2, g.size.width * reject/total))
                }.clipShape(Capsule())
            }.frame(height: 10)
            HStack(spacing: 14) {
                legendDot("直连", fmtBytes(direct), .cyan)
                legendDot("代理", fmtBytes(proxy), M.accent)
                legendDot("拦截", fmtBytes(reject), .red)
            }
        }
    }
    private func legendDot(_ l: String, _ v: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(v).font(.caption.monospaced())
                Text(l).font(.caption2).foregroundColor(.secondary)
            }
        }
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

struct RankList: View {
    enum Mode { case bytes, count }
    let rows: [Rank]; let accent: Color; let mode: Mode
    var body: some View {
        let mx = max(rows.first?.value ?? 1, 1)
        VStack(spacing: 8) {
            if rows.isEmpty { Text("暂无数据").font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Text("\(i+1)").font(.caption2.monospaced()).foregroundColor(.secondary).frame(width: 12)
                        Text(r.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(mode == .bytes ? fmtBytes(r.value) : "\(Int(r.value))")
                            .font(.caption.monospaced()).foregroundColor(.secondary)
                    }
                    GeometryReader { g in
                        Capsule().fill(accent.opacity(0.7)).frame(width: max(3, g.size.width * r.value/mx), height: 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 3)
                }
            }
        }
    }
}

struct BarStat: View {
    let label, value, icon: String; let color: Color
    init(_ l: String, _ v: String, _ i: String, _ c: Color) { label = l; value = v; icon = i; color = c }
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.title2).foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundColor(.secondary)
                Text(value).font(.system(size: 20, weight: .bold, design: .rounded))
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }
}

struct MiniStat: View {
    let title, value: String; let sub: String?; let icon: String; let color: Color
    init(_ title: String, _ value: String, sub: String?, icon: String, color: Color) {
        self.title = title; self.value = value; self.sub = sub; self.icon = icon; self.color = color
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded))
            if let sub { Text(sub).font(.caption2).foregroundColor(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
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
