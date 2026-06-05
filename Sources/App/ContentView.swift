// ContentView — sidebar shell + content router.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var M: AppModel

    struct Tab { let id, label, icon: String }

    // 监控：实时状态与数据
    private let monitorTabs: [Tab] = [
        .init(id: "dashboard",   label: "仪表盘",   icon: "gauge"),
        .init(id: "connections", label: "连接监控", icon: "link"),
        .init(id: "logs",        label: "日志",     icon: "doc.plaintext.fill"),
    ]
    // 代理：规则与节点
    private let proxyTabs: [Tab] = [
        .init(id: "proxies", label: "代理",     icon: "diamond.fill"),
        .init(id: "rules",   label: "分流规则", icon: "line.3.horizontal.decrease"),
        .init(id: "subscriptions", label: "订阅", icon: "icloud.and.arrow.down"),
    ]
    // 配置：profile 与偏好
    private let configTabs: [Tab] = [
        .init(id: "config",  label: "配置编辑", icon: "slider.horizontal.3"),
        .init(id: "general", label: "通用设置", icon: "gearshape.fill"),
    ]
    // 工具：内核与扩展
    private let toolTabs: [Tab] = [
        .init(id: "kernel", label: "内核管理",  icon: "cpu"),
        .init(id: "map",    label: "SD-WAN 共存", icon: "shareplay"),
    ]
    // 内核底层：网络接入与 TUN
    private let kernelTabs: [Tab] = [
        .init(id: "network", label: "网络入站", icon: "network"),
        .init(id: "tun",     label: "TUN 模式", icon: "shield.lefthalf.filled"),
    ]

    /// App 版本号(随 MARKETING_VERSION),展示于侧栏头部与关于页。
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

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
                Section("监控") { rows(monitorTabs) }
                Section("代理") { rows(proxyTabs) }
                Section("配置") { rows(configTabs) }
                Section("工具") { rows(toolTabs) }
                Section("内核") { rows(kernelTabs) }
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
                .overlay(Image(systemName: "bolt.fill").font(.system(size: DS.Icon.sm, weight: .bold)).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text("ClashPow").font(.dsLabelBold)
                    Text("v\(Self.appVersion)").font(.dsBodyMedium).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, DS.Spacing.l).padding(.vertical, 14)
    }

    private var statusFooter: some View {
        VStack(spacing: 8) {
            statusToggle("核心运行", icon: "bolt.fill", isOn: Binding(get: { M.reachable }, set: { _ in M.toggleEngine() }), accent: false)
            statusToggle("系统代理", icon: "globe", isOn: Binding(get: { M.systemProxyOn }, set: { _ in M.toggleSystemProxy() }), accent: false)
            statusToggle("TUN 模式", icon: "shield.lefthalf.filled", isOn: Binding(get: { M.tunOn }, set: { _ in M.toggleTUN() }), accent: true)
            
            HStack {
                Circle().fill(M.reachable ? DS.Palette.ok : DS.Palette.error).frame(width: 6, height: 6)
                Text(M.reachable ? "核心已就绪" : "核心已停止").font(.dsBody).foregroundColor(.secondary)
                Spacer()
                if M.reachable {
                    Text(M.version).font(.dsMono).foregroundColor(.secondary)
                }
            }
            .padding(.top, DS.Spacing.xs)
        }
        .padding(DS.Spacing.l)
    }

    private func statusToggle(_ label: String, icon: String, isOn: Binding<Bool>, accent: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(isOn.wrappedValue ? (accent ? M.accent : DS.Palette.ok) : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
            Text(label).font(.dsBodyMedium).foregroundColor(isOn.wrappedValue ? .primary : .secondary)
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
                case "subscriptions": SubscriptionsPage()
                case "config": ConfigPage()
                case "logs": LogsPage()
                case "general": GeneralPage()
                case "network": NetworkPage()
                case "tun": TunPage()
                case "map": SdwanPage()
                case "kernel": KernelMgmtPage()
                default: DashboardPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if let t = M.toast {
                Text(t).font(.callout).padding(.horizontal, DS.Spacing.l).padding(.vertical, 9)
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
                Text(title).font(.dsPageTitle)
                if let desc {
                    Text(desc).font(.dsBody).foregroundColor(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                actions()
            }
        }
        .padding(.horizontal, DS.Spacing.l).padding(.top, DS.Spacing.l).padding(.bottom, DS.Spacing.l)
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
                    if let icon { Image(systemName: icon).font(.dsBody).foregroundColor(.secondary) }
                    Text(title).font(.dsBodyBold).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, DS.Spacing.l).padding(.top, DS.Spacing.m).padding(.bottom, DS.Spacing.s)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, pad ? DS.Spacing.l : 0)
                .padding(.bottom, pad ? DS.Spacing.l : 0)
                .padding(.top, (title == nil && pad) ? DS.Spacing.l : 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Palette.cardBgAlt))
    }
}
