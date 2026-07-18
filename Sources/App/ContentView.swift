// ContentView — sidebar shell + content router.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var M: AppModel

    struct Tab { let id, label, icon: String }

    // 侧栏图标约定：一律 outline（非 .fill），相近笔画密度；渲染见 sidebarIcon。
    // 监控：实时状态与数据
    private let monitorTabs: [Tab] = [
        .init(id: "dashboard",   label: "仪表盘",   icon: "gauge.with.dots.needle.67percent"),
        .init(id: "connections", label: "连接",     icon: "link"),
        .init(id: "logs",        label: "日志",     icon: "doc.text"),
    ]
    // 代理：规则与节点
    private let proxyTabs: [Tab] = [
        .init(id: "proxies", label: "代理节点", icon: "diamond"),
        .init(id: "rules",   label: "规则",     icon: "list.bullet.rectangle"),
        .init(id: "subscriptions", label: "订阅", icon: "icloud.and.arrow.down"),
    ]
    // 配置：profile · 网络(入站/TUN/DNS/嗅探/内核) · 网络拓扑 · 偏好
    private let configTabs: [Tab] = [
        .init(id: "config",  label: "配置", icon: "slider.horizontal.3"),
        .init(id: "network", label: "网络", icon: "network"),
        .init(id: "map",     label: "网络拓扑", icon: "point.3.connected.trianglepath.dotted"),
        .init(id: "general", label: "设置", icon: "gearshape"),
    ]

    /// App 版本号(随 MARKETING_VERSION),展示于侧栏头部与关于页。
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    static let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: DS.Layout.sidebarMin, ideal: DS.Layout.sidebarIdeal, max: DS.Layout.sidebarMax)
        } detail: { detail }
        // Force system controls (sidebar selection, switches, progress) onto the
        // brand accent (Medium Purple U). Without this, List(.sidebar) keeps the
        // system blue while content uses DS.Palette.accent.
        .tint(DS.Palette.accent)
        .onAppear { M.isMainWindowVisible = true }
        .onDisappear { M.isMainWindowVisible = false }
        // macOS 最小化不触发 onDisappear，需单独监听窗口通知
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
            M.isMainWindowVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
            M.isMainWindowVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if M.reachable { M.isMainWindowVisible = true }
        }
    }

    // MARK: Sidebar
    //
    // Shell 契约 (Docs/design.md §6.1 / §9)：
    // 侧栏与内容区共用同一 chrome 节奏：
    //   top chrome 高度 = m + controlHeight + m（与 PageToolbar / 连接·日志·规则顶栏一致）
    //   分割线 = 通栏 1pt separator（禁止 inset hairline，否则跨栏无法对齐）
    // 列表分组「监控 / 代理 / 配置」；底 = 系统代理 / TUN + 核心状态。
    //
    // 水平对齐：不用系统 List(.sidebar)（其 contentMargins/listRowInsets 仍会叠 2–4pt
    // 系统内边距，footer 在 List 外永远算不准）。导航与 footer 共用
    // pageContentInset + 同一套 icon 槽 / HStack spacing，像素级同左缘。

    private var sidebar: some View {
        VStack(spacing: 0) {
            appHeader
            Divider().overlay(DS.Palette.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sidebarSection("监控", tabs: monitorTabs, first: true)
                    sidebarSection("代理", tabs: proxyTabs)
                    sidebarSection("配置", tabs: configTabs)
                }
                .padding(.horizontal, DS.Layout.pageContentInset)
                .padding(.bottom, DS.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(DS.Palette.separator)
            statusFooter
        }
        .background(DS.Palette.sidebarBg)
    }

    @ViewBuilder
    private func sidebarSection(_ title: String, tabs: [Tab], first: Bool = false) -> some View {
        Text(title)
            .font(.dsCaption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, first ? DS.Layout.sidebarSectionTop : DS.Spacing.l)
            .padding(.bottom, DS.Spacing.xs)
            .padding(.leading, DS.Spacing.xs)

        ForEach(tabs, id: \.id) { t in
            sidebarNavRow(t)
        }
    }

    /// 导航行：与 statusToggle 同结构（lg 图标槽 + s 间距 + bodyMedium 文案）。
    /// 选中语言与 DSSegmentedControl 同源（design.md §6.1 / §6.8）：
    /// accent 胶囊 + 白字/白 outline 图标；未选透明 + primary。
    private func sidebarNavRow(_ t: Tab) -> some View {
        let selected = M.route == t.id
        return Button {
            M.route = t.id
        } label: {
            HStack(spacing: DS.Spacing.s) {
                sidebarIcon(t.icon)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(t.label)
                    .font(.dsBodyMedium)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, DS.Layout.sidebarRowVInset)
            .padding(.horizontal, DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(selected ? DS.Palette.accent : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 侧栏导航图标：统一 outline 字形、字重、渲染模式与占位框，避免 fill/line 混用导致视觉轻重不一。
    private func sidebarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(DS.Icon.font(DS.Icon.md, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .frame(width: DS.Icon.lg, height: DS.Icon.lg, alignment: .center)
            .contentShape(Rectangle())
    }

    /// 与内容区 PageToolbar / chrome 顶栏同高：m + 32 + m，底部分割线通栏。
    private var appHeader: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: DS.Layout.controlHeight, height: DS.Layout.controlHeight)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("ClashHalo")
                    .font(.dsLabelBold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("v\(Self.appVersion) · \(Self.appBuild)")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        // 水平 inset 与内容区 pageContentInset 同源，跨栏视觉网格一致
        .padding(.horizontal, DS.Layout.pageContentInset)
        .frame(height: DS.Layout.chromeHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.sidebarBg)
    }

    private var statusFooter: some View {
        // 与导航 ScrollView 共用 pageContentInset；行内再 +s，与选中胶囊内图标同起点
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            statusToggle(
                "系统代理",
                icon: "globe",
                isOn: Binding(
                    get: { M.systemProxyOn },
                    set: { newValue in
                        // Ignore no-op / SwiftUI re-entrant sets; only act on edge.
                        guard newValue != M.systemProxyOn else { return }
                        M.toggleSystemProxy()
                    }
                ),
                onColor: DS.Palette.ok
            )
            statusToggle(
                "TUN 模式",
                icon: "shield",
                isOn: Binding(
                    get: { M.tunOn },
                    set: { newValue in
                        guard newValue != M.tunOn else { return }
                        M.toggleTUN()
                    }
                ),
                onColor: DS.Palette.accent
            )

            HStack(spacing: DS.Spacing.s) {
                Circle()
                    .fill(M.reachable ? DS.Palette.ok : DS.Palette.error)
                    .frame(width: 6, height: 6)
                    .frame(width: DS.Icon.lg, height: DS.Icon.lg, alignment: .center)
                Text(M.reachable ? "核心已就绪" : "核心已停止")
                    .font(.dsBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if M.reachable {
                    Text(M.version)
                        .font(.dsMono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, DS.Spacing.xs / 2)
            .padding(.horizontal, DS.Spacing.s)
        }
        .padding(.horizontal, DS.Layout.pageContentInset)
        .padding(.top, DS.Spacing.m)
        .padding(.bottom, DS.Spacing.l)
        .background(DS.Palette.sidebarBg)
    }

    private func statusToggle(_ label: String, icon: String, isOn: Binding<Bool>, onColor: Color) -> some View {
        let busy = M.engine.isBusy
        return HStack(spacing: DS.Spacing.s) {
            // 与导航行共用 md 字号 + monochrome + lg 槽
            Image(systemName: icon)
                .font(DS.Icon.font(DS.Icon.md, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isOn.wrappedValue ? onColor : .secondary)
                .frame(width: DS.Icon.lg, height: DS.Icon.lg, alignment: .center)
            Text(label)
                .font(.dsBodyMedium)
                .foregroundStyle(busy ? .secondary : (isOn.wrappedValue ? .primary : .secondary))
                .lineLimit(1)
            Spacer(minLength: 0)
            if busy {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(DS.Progress.miniScale)
            }
            // 开关是状态控件，不与标准 32pt 按钮/tab 共用尺寸（design.md §6.7）
            // busy 时禁用，避免连点只靠 toast 解释（design.md §10.1）
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(onColor)
                .disabled(busy)
                .opacity(busy ? 0.55 : 1)
        }
        .padding(.vertical, DS.Spacing.xs / 2)
        .padding(.horizontal, DS.Spacing.s)
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
                case "network": NetworkHubPage()
                case "map": SdwanPage()

                default: DashboardPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Palette.windowBg)
        .overlay(alignment: .bottom) {
            if let t = M.toast {
                toastBanner(t)
                    .padding(.bottom, DS.Spacing.xxl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.toast, value: M.toast)
    }

    private func toastBanner(_ t: ToastPayload) -> some View {
        let accent: Color = {
            switch t.kind {
            case .info: return DS.Palette.info
            case .ok: return DS.Palette.ok
            case .warn: return DS.Palette.warn
            case .error: return DS.Palette.error
            }
        }()
        let icon: String = {
            switch t.kind {
            case .info: return "info.circle.fill"
            case .ok: return "checkmark.circle.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }()
        return HStack(spacing: DS.Spacing.s) {
            Image(systemName: icon)
                .font(DS.Icon.font(DS.Icon.sm, weight: .semibold))
                .foregroundStyle(accent)
            Text(t.text)
                .font(.dsBody)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(DS.Palette.border))
    }
}

// MARK: - Components

/// Page top bar. Title/desc are optional — non-dashboard pages pass empty title and only actions.
struct PageHead<Actions: View>: View {
    let title: String
    let desc: String?
    @ViewBuilder var actions: () -> Actions

    private var hasTitle: Bool { !title.isEmpty }
    private var hasActions: Bool { Actions.self != EmptyView.self }

    var body: some View {
        if hasTitle || hasActions {
            HStack(alignment: hasTitle ? .bottom : .center) {
                if hasTitle {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(title)
                            .font(.dsPageTitle)
                            .foregroundColor(.primary)
                        if let desc = desc, !desc.isEmpty {
                            Text(desc)
                                .font(.dsBody)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                }

                if hasActions {
                    HStack(spacing: DS.Spacing.s) {
                        actions()
                    }
                }
            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.top, hasTitle ? DS.Spacing.l : DS.Spacing.m)
            .padding(.bottom, DS.Spacing.m)
        }
    }
}

extension PageHead where Actions == EmptyView {
    init(title: String, desc: String? = nil) {
        self.init(title: title, desc: desc, actions: { EmptyView() })
    }
}

/// Actions-only page toolbar (no title/desc). Prefer this on non-dashboard pages.
/// Matches design.md §6.5 / §6.1: fixed 32pt controls, pageContentInset, chromeBg strip.
/// Height locked to `m + controlHeight + m` so the bottom Divider lines up with the sidebar header.
struct PageToolbar<Actions: View>: View {
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Spacer(minLength: 0)
                actions()
            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.vertical, DS.Spacing.m)
            .frame(height: DS.Layout.chromeHeight, alignment: .center)
            .frame(maxWidth: .infinity)
            .background(DS.Palette.chromeBg)

            Divider().overlay(DS.Palette.separator)
        }
    }
}

// MARK: - Reusable card container

struct Card<Content: View, Actions: View>: View {
    var title: String?
    var icon: String?
    var pad: Bool
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    init(title: String? = nil, icon: String? = nil, pad: Bool = true, @ViewBuilder actions: @escaping () -> Actions, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.pad = pad
        self.actions = actions
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: DS.Spacing.s) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.dsBody)
                            .foregroundColor(.secondary)
                    }
                    Text(title).font(.dsBodyBold).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    actions()
                }
                .padding(.horizontal, DS.Spacing.l)
                .padding(.top, DS.Spacing.m)
                .padding(.bottom, DS.Spacing.s)
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
        .dsCardChrome()
    }
}

extension Card where Actions == EmptyView {
    init(title: String? = nil, icon: String? = nil, pad: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, icon: icon, pad: pad, actions: { EmptyView() }, content: content)
    }
}
