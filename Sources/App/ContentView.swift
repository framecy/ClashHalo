// ContentView — sidebar shell + content router.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var M: AppModel

    // grouped navigation (matches prototype layout)
    struct Tab { let id, label, icon: String }
    private let dashTabs: [Tab] = [
        .init(id: "dashboard", label: "仪表盘", icon: "gauge"),
    ]
    private let proxyTabs: [Tab] = [
        .init(id: "proxies", label: "代理", icon: "diamond.fill"),
        .init(id: "connections", label: "连接监控", icon: "link"),
        .init(id: "map", label: "SD-WAN 共存", icon: "shareplay"),
    ]
    private let netTabs: [Tab] = [
        .init(id: "dns", label: "DNS 缓存", icon: "server.rack"),
        .init(id: "logs", label: "日志", icon: "doc.plaintext.fill"),
        .init(id: "rules", label: "分流规则", icon: "line.3.horizontal.decrease"),
    ]
    private let configTabs: [Tab] = [
        .init(id: "config", label: "配置编辑", icon: "slider.horizontal.3"),
        .init(id: "general", label: "通用设置", icon: "gearshape.fill"),
    ]

    private let titles: [String: String] = [
        "dashboard":"仪表盘","connections":"连接监控","proxies":"代理","rules":"分流规则",
        "config":"配置编辑","logs":"实时日志","general":"通用设置","network":"网络入站",
        "dns":"DNS 缓存","tun":"TUN 模式","sniffer":"流量嗅探","map":"SD-WAN 共存",
    ]

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        } detail: { detail }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            appHeader
            Divider().opacity(0.4)
            List(selection: $M.route) {
                Section("概览") { rows(dashTabs) }
                Section("代理") { rows(proxyTabs) }
                Section("网络") { rows(netTabs) }
                Section("配置") { rows(configTabs) }
                
                Section("引擎底层") {
                    Label("网络入站", systemImage: "network").tag("network")
                    Label("TUN 模式", systemImage: "shield.lefthalf.filled").tag("tun")
                    Label("流量嗅探", systemImage: "scope").tag("sniffer")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider().opacity(0.4)
            statusFooter
        }
    }

    private func rows(_ tabs: [Tab]) -> some View {
        ForEach(tabs, id: \.id) { t in
            Label(t.label, systemImage: t.icon).tag(t.id)
        }
    }

    private var appHeader: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [M.accent, M.accent.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: "bolt.fill").font(.system(size: 15, weight: .bold)).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 0) {
                Text("ClashPow").font(.system(size: 14, weight: .bold))
                Text(M.reachable ? "mihomo \(M.version)" : "未连接")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var statusFooter: some View {
        VStack(spacing: 8) {
            statusToggle("系统代理", icon: "globe", isOn: Binding(get: { M.systemProxyOn }, set: { _ in M.toggleSystemProxy() }), accent: false)
            statusToggle("TUN 模式", icon: "shield.lefthalf.filled", isOn: Binding(get: { M.tunOn }, set: { _ in M.toggleTUN() }), accent: true)
            
            HStack {
                Circle().fill(M.reachable ? Color.green : Color.red).frame(width: 6, height: 6)
                Text(M.reachable ? "核心已就绪" : "核心已停止").font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                if M.reachable {
                    Text(M.version).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
    }

    private func statusToggle(_ label: String, icon: String, isOn: Binding<Bool>, accent: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(isOn.wrappedValue ? (accent ? M.accent : Color.green) : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(isOn.wrappedValue ? .primary : .secondary)
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
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

// MARK: - Components

struct PageHead<Actions: View>: View {
    let title: String
    let desc: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .bold))
                if let desc {
                    Text(desc).font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                actions()
            }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 16)
    }
}

extension PageHead where Actions == EmptyView {
    init(title: String, desc: String? = nil) {
        self.init(title: title, desc: desc, actions: { EmptyView() })
    }
}

// MARK: - Reusable card container

struct Card<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    var pad = true
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 6) {
                    if let icon { Image(systemName: icon).font(.system(size: 12)).foregroundColor(.secondary) }
                    Text(title).font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, pad ? 16 : 0)
                .padding(.bottom, pad ? 16 : 0)
                .padding(.top, (title == nil && pad) ? 16 : 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0x2A/255.0, green: 0x2A/255.0, blue: 0x2A/255.0)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0x2C/255.0, green: 0x2C/255.0, blue: 0x2C/255.0)))
    }
}
