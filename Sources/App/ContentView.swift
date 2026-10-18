// ContentView — sidebar shell + content router.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var M: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // ⌘W 只收起窗口、不退出应用（见 MainWindowCloseKeepsRunning）：
        // 这个零尺寸探针视图负责把窗口的 close 拦截代理挂上去。
        .background(MainWindowCloseGuard())
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
    //   top chrome 高度 = m + controlHeight + m（唯一实现见 PageToolbar，全部页面共用）
    //   分割线 = 通栏 1pt separator（禁止 inset hairline，否则跨栏无法对齐）
    // 列表分组「监控 / 代理 / 配置」；底 = Proxy / TUN + 内核版本。
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
            // Attention badge: helper installed but below the expected version.
            // Tapping routes to 设置 → 权限 where the one-tap upgrade lives.
            if M.engine.helperNeedsUpdate {
                Button { M.route = "general" } label: {
                    HStack(spacing: DS.Spacing.s) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(DS.Icon.font(DS.Icon.md, weight: .medium))
                            .foregroundStyle(DS.Palette.warn)
                            .frame(width: DS.Icon.lg, height: DS.Icon.lg)
                        Text("特权服务待更新")
                            .font(.dsBodyMedium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.dsCaption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, DS.Spacing.xs)
                    .padding(.horizontal, DS.Spacing.s)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(DS.Palette.warn.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            statusToggle(
                "Proxy",
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
                "TUN",
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

            // Kernel status: tri-state dot + full version. "连接中" (amber) during
            // a busy start/restart is more honest than a bare red "disconnected".
            HStack(spacing: DS.Spacing.s) {
                let connecting = M.engine.isBusy && !M.reachable
                Circle()
                    .fill(M.reachable ? DS.Palette.ok : (connecting ? DS.Palette.warn : DS.Palette.error))
                    .frame(width: 6, height: 6)
                    .frame(width: DS.Icon.lg, height: DS.Icon.lg, alignment: .center)
                Text("内核")
                    .font(.dsBodyMedium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(M.reachable ? (M.version.isEmpty || M.version == "?" ? "—" : M.version)
                                 : (connecting ? "连接中…" : "未连接"))
                    .font(M.reachable ? .dsMono : .dsBody)
                    .foregroundStyle(M.reachable ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
            VStack(spacing: DS.Spacing.s) {
                // Persistent progress banner while a kernel operation runs — the
                // step line survives across the multi-await flow instead of the
                // intermediate toasts flashing past in the 2.4 s window.
                if M.engine.isBusy, let step = M.engine.busyStep {
                    busyBanner(step)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let t = M.toast {
                    toastBanner(t)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, DS.Spacing.xxl)
        }
        .animation(DS.Motion.resolve(DS.Motion.toast, reduce: reduceMotion), value: M.toast)
        .animation(DS.Motion.resolve(DS.Motion.toast, reduce: reduceMotion), value: M.engine.busyStep)
        .animation(DS.Motion.resolve(DS.Motion.toast, reduce: reduceMotion), value: M.engine.isBusy)
    }

    /// In-progress banner: a spinner + the current step text, styled as a quiet
    /// sibling of the toast capsule (accent stroke instead of status color).
    private func busyBanner(_ text: String) -> some View {
        HStack(spacing: DS.Spacing.s) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(DS.Progress.miniScale)
            Text(text)
                .font(.dsBody)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(DS.Palette.accent.opacity(0.35)))
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

/// Page top bar — the **single** chrome contract for every page.
///
/// 结构固定为「标题（可选）→ 页内控件（可选）→ 弹性空白 → 右对齐操作」，高度锁死
/// `m + controlHeight + m`，底部通栏 1pt 分割线，水平内距与侧栏 `appHeader` 共用
/// `pageContentInset`。这套契约此前被手工复制 5 份（Logs / Rules / General / Network
/// 各自手搓顶栏，Dashboard 把标题塞在 ScrollView 里随滚动消失），改一处漏四处。
/// 现在只有这一个实现；零调用点的 `PageHead` 已删除。
///
/// 两种用法：
/// - `PageToolbar { 按钮… }` —— 只有右侧操作（配置 / 策略 / 网络拓扑 / 订阅页）；
/// - `PageToolbar(leading: {…})` / `PageToolbar(leading:actions:)` —— 页内分段器在左
///   （设置 / 日志 / 规则 / 网络）。
struct PageToolbar<Leading: View, Actions: View>: View {
    var title: String?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var actions: () -> Actions

    init(title: String? = nil,
         @ViewBuilder leading: @escaping () -> Leading,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.leading = leading
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.m) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.dsPageTitle)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                if Actions.self != EmptyView.self {
                    // 有右侧操作：页内控件按自身宽度贴左，操作靠右。
                    leading()
                    Spacer(minLength: 0)
                    HStack(spacing: DS.Spacing.s) {
                        actions()
                    }
                } else {
                    // 没有操作：页内控件占满整条（设置/网络页的全宽分段器就是这种形态）。
                    leading()
                }
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

extension PageToolbar where Leading == EmptyView {
    /// 只有右侧操作（尾随闭包永远表示 actions，避免与页内控件槽产生重载歧义）。
    init(title: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: title, leading: { EmptyView() }, actions: actions)
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
