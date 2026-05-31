// ContentView — sidebar shell + content router.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var M: AppModel

    private let tabs: [(id: String, label: String, icon: String, group: String)] = [
        ("dashboard", "仪表盘", "gauge.with.dots.needle.33percent", "概览"),
        ("proxies", "代理", "globe.asia.australia.fill", "代理"),
        ("connections", "连接", "point.3.connected.trianglepath.dotted", "代理"),
        ("sdwan", "SD‑WAN", "network", "代理"),
        ("rules", "规则", "list.bullet.rectangle", "网络"),
        ("dns", "DNS", "server.rack", "网络"),
        ("logs", "日志", "doc.text.magnifyingglass", "网络"),
        ("subscriptions", "订阅", "icloud.fill", "配置"),
        ("config", "配置", "doc.badge.gearshape", "配置"),
        ("settings", "设置", "gearshape.fill", "配置"),
    ]
    private let titles = ["dashboard":"仪表盘","proxies":"代理","connections":"连接","sdwan":"SD‑WAN 共存","rules":"分流规则","dns":"DNS","logs":"实时日志","subscriptions":"订阅管理","config":"配置","settings":"设置"]

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 208, ideal: 216, max: 240)
        } detail: {
            detail
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $M.route) {
            Section { statusCard }
            ForEach(["概览","代理","网络","配置"], id: \.self) { g in
                Section(g) {
                    ForEach(tabs.filter { $0.group == g }, id: \.id) { t in
                        Label(t.label, systemImage: t.icon).tag(t.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ClashPow")
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(M.reachable ? M.accent : Color.red).frame(width: 7, height: 7)
                Text(M.reachable ? "已连接内核" : "内核未连接")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(modeLabel(M.mode))
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Text(M.currentProxyName())
                .font(.callout).fontWeight(.semibold)
                .foregroundColor(M.accent).lineLimit(1)
            HStack(spacing: 10) {
                Label(fmtRate(Double(M.curDown)), systemImage: "arrow.down")
                    .font(.caption2.monospaced()).foregroundColor(.secondary)
                Label(fmtRate(Double(M.curUp)), systemImage: "arrow.up")
                    .font(.caption2.monospaced()).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(titles[M.route] ?? "ClashPow").font(.title3).fontWeight(.semibold)
                Spacer()
                if M.route == "dashboard" || M.route == "proxies" {
                    Picker("", selection: Binding(get: { M.mode }, set: { M.setMode($0) })) {
                        Text("规则").tag("rule"); Text("全局").tag("global"); Text("直连").tag("direct")
                    }
                    .pickerStyle(.segmented).frame(width: 200).labelsHidden()
                }
                HStack(spacing: 5) {
                    Circle().fill(M.reachable ? Color.green : Color.red).frame(width: 6, height: 6)
                    Text("mihomo \(M.version)").font(.caption2.monospaced()).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.bar)

            Divider()

            Group {
                switch M.route {
                case "proxies": ProxiesPage()
                case "connections": ConnectionsPage()
                case "sdwan": SdwanPage()
                case "rules": RulesPage()
                case "dns": DnsPage()
                case "logs": LogsPage()
                case "subscriptions": SubscriptionsPage()
                case "config": ConfigPage()
                case "settings": SettingsPage()
                default: DashboardPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if let t = M.toast {
                Text(t).font(.caption).padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: M.toast)
    }
}

// MARK: - Reusable card container

struct Card<Content: View>: View {
    var title: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { Text(title).font(.subheadline).fontWeight(.semibold) }
                    Spacer()
                    if let trailing { trailing }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            }
            content().padding(.horizontal, 14).padding(.bottom, 12)
                .padding(.top, title == nil ? 12 : 0)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }
}
