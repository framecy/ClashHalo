// ContentView — sidebar shell + content router.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var M: AppModel

    // grouped navigation (matches reference layout)
    struct Tab { let id, label, icon: String }
    private let topTabs: [Tab] = [
        .init(id: "dashboard", label: "概览", icon: "square.grid.2x2.fill"),
        .init(id: "connections", label: "连接", icon: "list.bullet.rectangle.fill"),
        .init(id: "proxies", label: "策略", icon: "diamond.fill"),
        .init(id: "rules", label: "规则", icon: "line.3.horizontal.decrease"),
        .init(id: "config", label: "配置", icon: "doc.text.fill"),
        .init(id: "logs", label: "日志", icon: "doc.plaintext.fill"),
    ]
    private let engineTabs: [Tab] = [
        .init(id: "general", label: "通用", icon: "gearshape.fill"),
        .init(id: "network", label: "网络", icon: "network"),
        .init(id: "dns", label: "DNS", icon: "server.rack"),
        .init(id: "tun", label: "TUN", icon: "shield.lefthalf.filled"),
        .init(id: "sniffer", label: "嗅探", icon: "scope"),
    ]
    private let labTabs: [Tab] = [
        .init(id: "map", label: "地图", icon: "map.fill"),
    ]

    private let titles: [String: String] = [
        "dashboard":"概览","connections":"连接","proxies":"策略","rules":"分流规则",
        "config":"配置","logs":"实时日志","general":"通用","network":"网络",
        "dns":"DNS","tun":"TUN","sniffer":"嗅探","map":"网络地图",
    ]

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 208, ideal: 216, max: 240)
        } detail: { detail }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            appHeader
            Divider().opacity(0.5)
            List(selection: $M.route) {
                Section { rows(topTabs) }
                Section("引擎") { rows(engineTabs) }
                Section("实验室") { rows(labTabs) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider().opacity(0.5)
            statusFooter
        }
        .navigationTitle("ClashPow")
    }

    private func rows(_ tabs: [Tab]) -> some View {
        ForEach(tabs, id: \.id) { t in
            Label(t.label, systemImage: t.icon).tag(t.id)
        }
    }

    private var appHeader: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [M.accent, M.accent.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "bolt.fill").font(.system(size: 16, weight: .bold)).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text("ClashPow").font(.system(size: 15, weight: .semibold))
                Text(M.reachable ? "mihomo \(M.version)" : "未连接")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            footerRow("系统代理", on: M.systemProxyOn, accent: false)
            footerRow(M.tunOn ? "TUN 模式" : "增强模式", on: M.tunOn, accent: true)
            HStack(spacing: 6) {
                Circle().fill(M.reachable ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                Text("核心 \(M.reachable ? M.version : "—")").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func footerRow(_ label: String, on: Bool, accent: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(on ? (accent ? M.accent : Color.green) : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11)).foregroundColor(on ? .primary : .secondary)
            Spacer()
        }
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(titles[M.route] ?? "ClashPow").font(.system(size: 17, weight: .semibold))
                Spacer()
                if M.route == "dashboard" || M.route == "proxies" {
                    Picker("", selection: Binding(get: { M.mode }, set: { M.setMode($0) })) {
                        Text("规则").tag("rule"); Text("全局").tag("global"); Text("直连").tag("direct")
                    }.pickerStyle(.segmented).frame(width: 200).labelsHidden()
                }
                // master toggles
                Button { M.toggleSystemProxy() } label: {
                    Image(systemName: "globe").foregroundColor(M.systemProxyOn ? M.accent : .secondary)
                }.help("系统代理").buttonStyle(.borderless)
                Button { M.toggleTUN() } label: {
                    Image(systemName: "shield.lefthalf.filled").foregroundColor(M.tunOn ? M.accent : .secondary)
                }.help("TUN 模式").buttonStyle(.borderless)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.bar)
            Divider()

            Group {
                switch M.route {
                case "connections": ConnectionsPage()
                case "proxies": ProxiesPage()
                case "rules": RulesPage()
                case "config": ConfigPage()
                case "logs": LogsPage()
                case "general": GeneralPage()
                case "network": NetworkPage()
                case "dns": DnsPage()
                case "tun": TunPage()
                case "sniffer": SnifferPage()
                case "map": SdwanPage()
                default: DashboardPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if let t = M.toast {
                Text(t).font(.callout).padding(.horizontal, 16).padding(.vertical, 9)
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
    var icon: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 6) {
                    if let icon { Image(systemName: icon).font(.caption).foregroundColor(.secondary) }
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                    Spacer()
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
